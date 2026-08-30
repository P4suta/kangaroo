"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { EventEmitter } = require("node:events");
const {
  DaemonClient,
  WorkspaceSession,
  createExtension,
  terminateProcessTree,
} = require("../extension");
const { protocolRequest, RunState } = require("../core");

function fakeChild() {
  const child = new EventEmitter();
  child.stdout = new EventEmitter();
  child.stderr = new EventEmitter();
  child.stdout.setEncoding = (encoding) => { child.stdout.encoding = encoding; };
  child.stderr.setEncoding = (encoding) => { child.stderr.encoding = encoding; };
  child.stdin = new EventEmitter();
  child.stdin.writable = true;
  child.stdin.writes = [];
  child.stdin.write = function write(value) { this.writes.push(value); };
  child.kill = (signal) => {
    child.killed = true;
    child.killSignal = signal;
  };
  return child;
}

test("daemon client keeps stdout protocol-only and uses the unified module", () => {
  const child = fakeChild();
  const calls = [];
  const messages = [];
  const logs = [];
  const client = new DaemonClient({
    cwd: "/project",
    executable: "gleam",
    spawnProcess: (...arguments_) => {
      calls.push(arguments_);
      return child;
    },
    onMessage: (message) => messages.push(message),
    onLog: (message) => logs.push(message),
    onExit: () => {},
    terminateProcess: (process) => { process.killed = true; },
  });
  client.start();
  assert.deepEqual(calls[0][1], ["run", "-m", "kangaroo", "--", "daemon"]);
  assert.equal(calls[0][2].detached, globalThis.process.platform !== "win32");
  assert.equal(child.stdout.encoding, "utf8");
  assert.equal(child.stderr.encoding, "utf8");
  child.stderr.emit("data", "compiler diagnostic\n");
  assert.match(client.diagnosticLog(), /compiler diagnostic/);
  child.stdout.emit("data", '{"protocol_version":1,"type":"shutdown","request_id":"shutdown-1"}\nnoise\n');
  assert.equal(messages.length, 1);
  assert.match(logs.at(-1), /invalid daemon stdout/);
  assert.equal(child.killed, true);
  assert.equal(client.process, null);
});

test("daemon client fails closed on a schema-invalid version-1 record", () => {
  const child = fakeChild();
  const messages = [];
  const logs = [];
  const client = new DaemonClient({
    cwd: "/project",
    executable: "gleam",
    spawnProcess: () => child,
    onMessage: (message) => messages.push(message),
    onLog: (message) => logs.push(message),
    onExit() {},
    terminateProcess: (process) => { process.killed = true; },
  });
  client.start();
  child.stdout.emit("data", '{"protocol_version":1,"type":"discovered","request_id":"discover-1","tests":"invalid"}\n');
  assert.deepEqual(messages, []);
  assert.match(logs.at(-1), /invalid daemon stdout record/);
  assert.equal(child.killed, true);
  assert.equal(client.process, null);
});

test("daemon diagnostic history is bounded by content size", () => {
  const client = new DaemonClient({
    cwd: "/project",
    executable: "gleam",
    onMessage() {},
    onLog() {},
    onExit() {},
  });
  for (let index = 0; index < 100; index += 1) {
    client.log(`${index}:`.padEnd(10_000, "x"));
  }
  assert.equal(typeof client.logHistory, "string");
  assert.ok(client.logHistory.length <= 65_536);
  assert.match(client.diagnosticLog(), /^x/);
  assert.match(client.diagnosticLog(), /99:x+$/);
});

test("daemon client fails closed on an oversized unterminated stdout record", () => {
  const child = fakeChild();
  const exits = [];
  const logs = [];
  const client = new DaemonClient({
    cwd: "/project",
    executable: "gleam",
    spawnProcess: () => child,
    onMessage() {},
    onLog: (message) => logs.push(message),
    onExit: (exit) => exits.push(exit),
    maxProtocolLineBytes: 8,
    terminateProcess: (process) => { process.killed = true; },
  });
  client.start();
  child.stdout.emit("data", "12345");
  child.stdout.emit("data", "6789");
  assert.equal(child.killed, true);
  assert.equal(client.process, null);
  assert.equal(exits.length, 0);
  child.emit("exit", null, "SIGKILL");
  assert.equal(exits.length, 1);
  assert.match(logs.at(-1), /stdout.*exceeded 8 bytes/);
});

test("daemon client turns a broken stdin pipe into one recoverable exit", () => {
  const child = fakeChild();
  const exits = [];
  const logs = [];
  const client = new DaemonClient({
    cwd: "/project",
    executable: "gleam",
    spawnProcess: () => child,
    onMessage() {},
    onLog: (message) => logs.push(message),
    onExit: (exit) => exits.push(exit),
    terminateProcess: (process) => { process.killed = true; },
  });
  client.start();

  assert.doesNotThrow(() => child.stdin.emit("error", Object.assign(
    new Error("write EPIPE"),
    { code: "EPIPE" },
  )));
  assert.equal(client.process, null);
  assert.equal(child.killed, true);
  assert.equal(exits.length, 0);
  assert.match(logs[0], /stdin.*EPIPE/);

  child.emit("exit", null, "SIGKILL");
  assert.equal(exits.length, 1);
});

test("daemon client contains a synchronous stdin write failure", () => {
  const child = fakeChild();
  const exits = [];
  const logs = [];
  child.stdin.write = () => {
    throw Object.assign(new Error("write EPIPE"), { code: "EPIPE" });
  };
  const client = new DaemonClient({
    cwd: "/project",
    executable: "gleam",
    spawnProcess: () => child,
    onMessage() {},
    onLog: (message) => logs.push(message),
    onExit: (exit) => exits.push(exit),
    terminateProcess: (process) => { process.killed = true; },
  });
  client.start();

  assert.doesNotThrow(() => {
    assert.equal(client.send(protocolRequest("run-1", "run")), false);
  });
  assert.equal(client.process, null);
  assert.equal(child.killed, true);
  assert.equal(exits.length, 0);
  child.emit("exit", null, "SIGKILL");
  assert.equal(exits.length, 1);
  assert.match(logs[0], /stdin.*EPIPE/);
});

test("daemon client terminates a process whose stdin is no longer writable", () => {
  const child = fakeChild();
  child.stdin.writable = false;
  const exits = [];
  const client = new DaemonClient({
    cwd: "/project",
    executable: "gleam",
    spawnProcess: () => child,
    onMessage() {},
    onLog() {},
    onExit: (exit) => exits.push(exit),
    terminateProcess: (process) => { process.killed = true; },
  });
  client.start();

  assert.equal(client.send(protocolRequest("run-1", "run")), false);
  assert.equal(child.killed, true);
  assert.equal(client.process, null);
  assert.equal(exits.length, 0);
  child.emit("exit", null, "SIGKILL");
  assert.equal(exits.length, 1);
});

test("daemon client treats spawn errors as one terminal exit", () => {
  const child = fakeChild();
  const exits = [];
  const logs = [];
  const client = new DaemonClient({
    cwd: "/project",
    executable: "missing-gleam",
    spawnProcess: () => child,
    onMessage() {},
    onLog: (message) => logs.push(message),
    onExit: (exit) => exits.push(exit),
  });
  client.start();
  child.emit("error", new Error("spawn missing-gleam ENOENT"));
  assert.equal(client.process, null);
  assert.equal(exits.length, 1);
  assert.equal(exits[0].expected, false);
  assert.match(logs[0], /ENOENT/);
  child.emit("exit", null, null);
  assert.equal(exits.length, 1);
});

test("daemon client ignores stdout from a replaced process generation", () => {
  const first = fakeChild();
  const second = fakeChild();
  const children = [first, second];
  const messages = [];
  const client = new DaemonClient({
    cwd: "/project",
    executable: "gleam",
    spawnProcess: () => children.shift(),
    onMessage: (message) => messages.push(message),
    onLog() {},
    onExit() {},
  });

  client.start();
  first.emit("error", new Error("old daemon failed"));
  client.start();
  first.stdout.emit("data", '{"protocol_version":1,"type":"discovered","request_id":"old","tests":[]}\n');
  assert.equal(messages.length, 0);
  second.stdout.emit("data", '{"protocol_version":1,"type":"discovered","request_id":"new","tests":[]}\n');
  assert.equal(messages.length, 1);
  assert.equal(messages[0].request_id, "new");
});

test("daemon client reports a synchronous spawn failure without escaping activation", () => {
  const exits = [];
  const logs = [];
  const client = new DaemonClient({
    cwd: "/project",
    executable: "gleam",
    spawnProcess: () => { throw new Error("process limit reached"); },
    onMessage() {},
    onLog: (message) => logs.push(message),
    onExit: (exit) => exits.push(exit),
  });
  assert.doesNotThrow(() => client.start());
  assert.equal(client.process, null);
  assert.equal(exits.length, 1);
  assert.match(logs[0], /process limit reached/);
});

test("daemon client terminates an unresponsive discovery so it can restart", () => {
  const child = fakeChild();
  child.pid = 42;
  const scheduled = [];
  const cancelled = [];
  const logs = [];
  const client = new DaemonClient({
    cwd: "/project",
    executable: "gleam",
    spawnProcess: () => child,
    onMessage() {},
    onLog: (message) => logs.push(message),
    onExit() {},
    schedule(callback, delay) {
      const timer = { callback, delay, unref() {} };
      scheduled.push(timer);
      return timer;
    },
    cancelSchedule: (timer) => cancelled.push(timer),
    discoveryTimeoutMs: 60_000,
    terminateProcess: (process) => { process.killed = true; },
  });

  client.start();
  assert.equal(client.send(protocolRequest("discover-1", "discover")), true);
  assert.equal(scheduled.length, 1);
  assert.equal(scheduled[0].delay, 60_000);
  scheduled[0].callback();
  assert.equal(child.killed, true);
  assert.match(logs[0], /discovery timed out/);

  child.emit("exit", null, "SIGKILL");
  assert.equal(cancelled.length, 1);
});

function collection() {
  const values = new Map();
  return {
    add(item) { values.set(item.id, item); },
    forEach(fn) { values.forEach(fn); },
    replace(items) {
      values.clear();
      items.forEach((item) => values.set(item.id, item));
    },
    values,
  };
}

function fakeVscode(settings = {}) {
  class Uri {
    constructor(value) { this.value = value; this.fsPath = value; }
    toString() { return this.value; }
    static joinPath(base, relative) { return new Uri(`${base.value}/${relative}`); }
    static parse(value) { return new Uri(value); }
    static file(value) { return new Uri(value); }
  }
  class Range {
    constructor(startLine, startColumn, endLine, endColumn) {
      Object.assign(this, { startLine, startColumn, endLine, endColumn });
    }
  }
  const controller = {
    items: collection(),
    profiles: [],
    createRunProfile(...arguments_) {
      const profile = { arguments_ };
      this.profiles.push(profile);
      return profile;
    },
    createTestItem(id, label, uri) {
      return { id, label, uri, children: collection(), tags: [] };
    },
    createTestRun() { throw new Error("not used"); },
    dispose() {},
  };
  return {
    Uri,
    Range,
    Position: class Position {
      constructor(line, character) { Object.assign(this, { line, character }); }
    },
    Location: class Location {},
    TestMessage: class TestMessage {},
    TestTag: class TestTag { constructor(id) { this.id = id; } },
    FileCoverage: class FileCoverage {
      constructor(uri, statementCoverage) {
        Object.assign(this, { uri, statementCoverage });
      }
    },
    StatementCoverage: class StatementCoverage {
      constructor(executed, location) { Object.assign(this, { executed, location }); }
    },
    TestRunProfileKind: { Run: 1, Coverage: 2 },
    Diagnostic: class Diagnostic {
      constructor(range, message, severity) { Object.assign(this, { range, message, severity }); }
    },
    DiagnosticSeverity: { Error: 1 },
    tests: { createTestController: () => controller },
    workspace: {
      getConfiguration: () => ({
        get: (key, fallback) => settings[key] ?? fallback,
      }),
    },
    controller,
  };
}

test("force termination kills the whole Unix process group", () => {
  const child = fakeChild();
  child.pid = 42;
  const calls = [];
  terminateProcessTree(child, {
    platform: "linux",
    killProcess(pid, signal) { calls.push([pid, signal]); },
  });
  assert.deepEqual(calls, [[-42, "SIGKILL"]]);
  assert.equal(child.killed, undefined);
});

test("force termination falls back to SIGKILL when no process group exists", () => {
  const child = fakeChild();
  child.pid = 42;
  terminateProcessTree(child, {
    platform: "darwin",
    killProcess() { throw new Error("ESRCH"); },
  });
  assert.equal(child.killSignal, "SIGKILL");
});

test("force termination uses recursive taskkill on Windows", () => {
  const child = fakeChild();
  child.pid = 42;
  const calls = [];
  const killer = new EventEmitter();
  killer.unref = () => { killer.unrefed = true; };
  terminateProcessTree(child, {
    platform: "win32",
    spawnProcess(...arguments_) {
      calls.push(arguments_);
      return killer;
    },
  });
  assert.deepEqual(calls[0].slice(0, 2), [
    "taskkill",
    ["/pid", "42", "/T", "/F"],
  ]);
  assert.equal(killer.unrefed, true);
  killer.emit("exit", 0);
  assert.equal(child.killSignal, undefined);
});

test("failed Windows taskkill falls back to direct SIGKILL", () => {
  const child = fakeChild();
  child.pid = 42;
  const killer = new EventEmitter();
  killer.unref = () => {};
  terminateProcessTree(child, {
    platform: "win32",
    spawnProcess() { return killer; },
  });
  killer.emit("exit", 1);
  assert.equal(child.killSignal, "SIGKILL");
});

function fakeExtensionHostVscode(workspaceFolders, manifests, settings = {}) {
  const vscode = fakeVscode(settings);
  const controllers = [];
  const findFileExcludes = [];
  const workspaceListeners = [];
  const configurationListeners = [];
  const watcherListeners = { change: [], create: [], delete: [] };
  const disposable = () => ({ dispose() {} });
  const makeController = () => ({
    items: collection(),
    profiles: [],
    createRunProfile(...arguments_) {
      const profile = { arguments_ };
      this.profiles.push(profile);
      return profile;
    },
    createTestItem(id, label, uri) {
      return { id, label, uri, children: collection(), tags: [] };
    },
    createTestRun() { throw new Error("not used"); },
    dispose() {},
  });
  vscode.tests.createTestController = () => {
    const controller = makeController();
    controllers.push(controller);
    return controller;
  };
  vscode.controllers = controllers;
  vscode.RelativePattern = class RelativePattern {
    constructor(base, pattern) { Object.assign(this, { base, pattern }); }
  };
  vscode.workspace.workspaceFolders = workspaceFolders;
  vscode.workspace.findFiles = async (pattern, exclude) => {
    const root = pattern.base.uri.fsPath.replaceAll("\\", "/");
    findFileExcludes.push(exclude);
    return manifests
      .filter((manifest) => manifest.replaceAll("\\", "/").startsWith(`${root}/`))
      .filter((manifest) =>
        !String(exclude).includes(".kangaroo-coverage-*") ||
        !manifest.replaceAll("\\", "/").split("/").some((part) =>
          part.startsWith(".kangaroo-coverage-")))
      .map((manifest) => vscode.Uri.file(manifest));
  };
  vscode.findFileExcludes = findFileExcludes;
  vscode.workspace.onDidChangeWorkspaceFolders = (listener) => {
    workspaceListeners.push(listener);
    return disposable();
  };
  vscode.workspace.onDidChangeConfiguration = (listener) => {
    configurationListeners.push(listener);
    return disposable();
  };
  vscode.workspace.createFileSystemWatcher = () => ({
    onDidChange(listener) { watcherListeners.change.push(listener); return disposable(); },
    onDidCreate(listener) { watcherListeners.create.push(listener); return disposable(); },
    onDidDelete(listener) { watcherListeners.delete.push(listener); return disposable(); },
    dispose() {},
  });
  vscode.workspaceListeners = workspaceListeners;
  vscode.configurationListeners = configurationListeners;
  vscode.watcherListeners = watcherListeners;
  vscode.languages = {
    createDiagnosticCollection: () => ({
      clear() {}, delete() {}, dispose() {}, set() {},
    }),
  };
  vscode.window = {
    createOutputChannel: () => ({ append() {}, appendLine() {}, dispose() {} }),
    createStatusBarItem: () => ({ dispose() {}, show() {}, text: "" }),
  };
  vscode.StatusBarAlignment = { Left: 1 };
  vscode.commands = { registerCommand: () => disposable() };
  return vscode;
}

test("workspace test tree uses stable ids and clears stale diagnostics", () => {
  const vscode = fakeVscode();
  const diagnostics = {
    values: new Map(),
    set(uri, values) { this.values.set(uri.toString(), values); },
    delete(uri) { this.values.delete(uri.toString()); },
  };
  const shared = {
    diagnostics,
    output: { append() {}, appendLine() {} },
    status: { text: "", show() {} },
  };
  const folder = { name: "project", uri: new vscode.Uri("/project") };
  const session = new WorkspaceSession(vscode, folder, shared, () => fakeChild());
  const watchProfile = vscode.controller.profiles[1].arguments_;
  assert.equal(typeof watchProfile[2], "function");
  assert.equal(watchProfile[3], false);
  assert.equal(watchProfile[5], true);
  session.replaceTests([{
    id: "test/math.gleam::addition_test",
    name: "addition_test",
    path: "test/math.gleam",
    line: 4,
    column: 1,
    end_line: 6,
    end_column: 2,
    tags: ["unit"],
  }]);
  const item = session.items.get("test/math.gleam::addition_test");
  assert.equal(item.range.startLine, 3);
  session.replaceTests([{
    id: "test/math.gleam::addition_test",
    name: "renamed_addition_test",
    path: "test/math.gleam",
    line: 5,
    column: 1,
    end_line: 7,
    end_column: 2,
    tags: ["fast"],
  }]);
  assert.equal(session.items.get(item.id), item);
  assert.equal(item.label, "renamed_addition_test");
  assert.equal(item.range.startLine, 4);
  const run = {
    started() {}, passed() {}, skipped() {}, failed() {}, appendOutput() {},
  };
  session.handleEvent(run, { type: "run_started" });
  session.handleEvent(run, {
    type: "case_finished",
    case: item.id,
    duration_ms: 1,
    outcome: {
      kind: "failed",
      failures: [{
        message: "boom",
        location: { file: "test/math.gleam", line: 5, column: 2 },
      }],
    },
  });
  session.handleEvent(run, {
    type: "run_finished",
    summary: { passed: 0, failed: 1, skipped: 0 },
  });
  assert.equal(diagnostics.values.size, 1);
  session.handleEvent(run, { type: "run_started" });
  assert.equal(diagnostics.values.size, 0);
  session.dispose();
});

test("an in-flight run keeps its item snapshot across rediscovery", () => {
  const vscode = fakeVscode();
  const session = new WorkspaceSession(
    vscode,
    { name: "project", uri: new vscode.Uri("/project") },
    {
      diagnostics: { set() {}, delete() {} },
      output: { append() {}, appendLine() {} },
      status: { text: "", show() {} },
    },
    () => fakeChild(),
  );
  const id = "test/math.gleam::addition_test";
  session.replaceTests([{
    id,
    name: "addition_test",
    path: "test/math.gleam",
    line: 1,
    column: 1,
    tags: [],
  }]);
  const original = session.items.get(id);
  const context = {
    state: new RunState(),
    items: new Map(session.items),
    generation: 1,
    receivedRunStarted: true,
  };
  session.latestRunGeneration = 1;

  session.replaceTests([{
    id,
    name: "addition_test",
    path: "test/moved.gleam",
    line: 1,
    column: 1,
    tags: [],
  }]);
  const replacement = session.items.get(id);
  assert.notEqual(replacement, original);
  let passedItem;
  session.handleEvent({
    passed(item) { passedItem = item; },
  }, {
    type: "case_finished",
    case: id,
    duration_ms: 1,
    outcome: { kind: "passed" },
  }, context);

  assert.equal(passedItem, original);
  session.dispose();
});

test("a completed watch generation refreshes the test tree", () => {
  const vscode = fakeVscode();
  const shared = {
    diagnostics: { delete() {} },
    output: { append() {}, appendLine() {} },
    status: { text: "", show() {} },
  };
  const session = new WorkspaceSession(
    vscode,
    { name: "project", uri: new vscode.Uri("/project") },
    shared,
    () => fakeChild(),
  );
  let discoveries = 0;
  session.discover = () => { discoveries += 1; };
  const context = {
    command: "watch",
    state: new RunState(),
    generation: session.latestRunGeneration,
    receivedRunStarted: true,
  };
  session.handleEvent({ end() {} }, {
    type: "run_finished",
    summary: { passed: 1, failed: 0, skipped: 0, duration_ms: 1 },
  }, context);
  assert.equal(discoveries, 1);
  session.dispose();
});

test("disposed workspace sessions ignore late daemon discovery", () => {
  const vscode = fakeVscode();
  const shared = {
    diagnostics: { delete() {} },
    output: { append() {}, appendLine() {} },
    status: { text: "unchanged", show() {} },
  };
  const session = new WorkspaceSession(
    vscode,
    { name: "project", uri: new vscode.Uri("/project") },
    shared,
    () => fakeChild(),
  );
  session.replaceTests([{
    id: "test/original.gleam::original_test",
    name: "original_test",
    path: "test/original.gleam",
    line: 1,
    column: 1,
    tags: [],
  }]);
  session.dispose();
  session.handleMessage({
    protocol_version: 1,
    type: "discovered",
    request_id: "late",
    tests: [{
      id: "test/late.gleam::late_test",
      name: "late_test",
      path: "test/late.gleam",
      line: 1,
      column: 1,
      tags: [],
    }],
  });
  assert.deepEqual(Array.from(session.items.keys()), [
    "test/original.gleam::original_test",
  ]);
  assert.equal(shared.status.text, "unchanged");
});

test("an older discovery response cannot replace the newest test tree", () => {
  const vscode = fakeVscode();
  const child = fakeChild();
  const session = new WorkspaceSession(
    vscode,
    { name: "project", uri: new vscode.Uri("/project") },
    {
      diagnostics: { delete() {} },
      output: { append() {}, appendLine() {} },
      status: { text: "", show() {} },
    },
    () => child,
  );
  try {
    session.discover();
    session.discover();
    const discoveries = child.stdin.writes
      .map((line) => JSON.parse(line))
      .filter((request) => request.command === "discover");
    const [older, newest] = discoveries;
    session.handleMessage({
      protocol_version: 1,
      type: "discovered",
      request_id: newest.id,
      tests: [{
        id: "test/new.gleam::new_test",
        name: "new_test",
        path: "test/new.gleam",
        line: 1,
        column: 1,
        tags: [],
      }],
    });
    session.handleMessage({
      protocol_version: 1,
      type: "discovered",
      request_id: older.id,
      tests: [{
        id: "test/old.gleam::old_test",
        name: "old_test",
        path: "test/old.gleam",
        line: 1,
        column: 1,
        tags: [],
      }],
    });
    assert.deepEqual(Array.from(session.items.keys()), [
      "test/new.gleam::new_test",
    ]);
  } finally {
    session.dispose();
  }
});

test("a failed latest discovery clears stale test ids", () => {
  const vscode = fakeVscode();
  const child = fakeChild();
  const shared = {
    diagnostics: { delete() {} },
    output: { append() {}, appendLine() {} },
    status: { text: "", show() {} },
  };
  const session = new WorkspaceSession(
    vscode,
    { name: "project", uri: new vscode.Uri("/project") },
    shared,
    () => child,
  );
  try {
    session.replaceTests([{
      id: "test/stale.gleam::stale_test",
      name: "stale_test",
      path: "test/stale.gleam",
      line: 1,
      column: 1,
      tags: [],
    }]);
    session.discover();
    session.handleMessage({
      protocol_version: 1,
      type: "error",
      request_id: session.latestDiscoveryId,
      message: "source could not be parsed",
    });
    assert.equal(session.items.size, 0);
    assert.match(shared.status.text, /discovery failed/);
  } finally {
    session.dispose();
  }
});

test("an older operation cannot publish diagnostics or status over a newer run", () => {
  const vscode = fakeVscode();
  const diagnostics = {
    values: new Map(),
    set(uri, values) { this.values.set(uri.toString(), values); },
    delete(uri) { this.values.delete(uri.toString()); },
  };
  const shared = {
    diagnostics,
    output: { append() {}, appendLine() {} },
    status: { text: "unchanged", show() {} },
  };
  const session = new WorkspaceSession(
    vscode,
    { name: "project", uri: new vscode.Uri("/project") },
    shared,
    () => fakeChild(),
  );
  session.replaceTests([{
    id: "test/math.gleam::addition_test",
    name: "addition_test",
    path: "test/math.gleam",
    line: 1,
    column: 1,
    end_line: 1,
    end_column: 2,
    tags: [],
  }]);
  const run = {
    started() {}, passed() {}, skipped() {}, failed() {}, appendOutput() {},
  };
  session.activeRuns.set("old", { run, command: "watch" });
  session.activeRuns.set("new", { run, command: "run" });
  const event = (requestId, value) => session.handleMessage({
    protocol_version: 1,
    type: "event",
    request_id: requestId,
    event: value,
  });

  event("old", { type: "run_started" });
  event("old", {
    type: "case_finished",
    case: "test/math.gleam::addition_test",
    duration_ms: 1,
    outcome: {
      kind: "failed",
      failures: [{
        message: "old failure",
        location: { file: "test/math.gleam", line: 1, column: 1 },
      }],
    },
  });
  event("new", { type: "run_started" });
  event("old", {
    type: "run_finished",
    summary: { passed: 0, failed: 1, skipped: 0, duration_ms: 1 },
  });
  assert.equal(shared.status.text, "unchanged");
  assert.equal(diagnostics.values.size, 0);

  event("new", {
    type: "run_finished",
    summary: { passed: 1, failed: 0, skipped: 0, duration_ms: 1 },
  });
  assert.match(shared.status.text, /1 passed, 0 failed/);
  session.dispose();
});

test("a delayed first run_started cannot reclaim the newest request generation", () => {
  const vscode = fakeVscode();
  const shared = {
    diagnostics: { set() {}, delete() {} },
    output: { append() {}, appendLine() {} },
    status: { text: "unchanged", show() {} },
  };
  const session = new WorkspaceSession(
    vscode,
    { name: "project", uri: new vscode.Uri("/project") },
    shared,
    () => fakeChild(),
  );
  const run = {
    started() {}, passed() {}, skipped() {}, failed() {}, appendOutput() {},
  };
  const context = () => ({
    run,
    state: new RunState(),
    generation: 0,
    receivedRunStarted: false,
  });
  const older = context();
  const newest = context();
  session.beginRunGeneration(older);
  session.beginRunGeneration(newest);

  session.handleEvent(run, { type: "run_started" }, older);
  session.handleEvent(run, {
    type: "run_finished",
    summary: { passed: 0, failed: 1, skipped: 0, duration_ms: 1 },
  }, older);
  assert.equal(shared.status.text, "unchanged");

  session.handleEvent(run, { type: "run_started" }, newest);
  session.handleEvent(run, {
    type: "run_finished",
    summary: { passed: 1, failed: 0, skipped: 0, duration_ms: 1 },
  }, newest);
  assert.match(shared.status.text, /1 passed, 0 failed/);
  session.dispose();
});

test("a requested operation clears diagnostics before compilation can fail", () => {
  const vscode = fakeVscode();
  const diagnostics = {
    values: new Map([["/project/test/stale.gleam", [{}]]]),
    set(uri, values) { this.values.set(uri.toString(), values); },
    delete(uri) { this.values.delete(uri.toString()); },
  };
  const child = fakeChild();
  const session = new WorkspaceSession(
    vscode,
    { name: "project", uri: new vscode.Uri("/project") },
    {
      diagnostics,
      output: { append() {}, appendLine() {} },
      status: { text: "", show() {} },
    },
    () => child,
  );
  session.diagnosticUris.add("/project/test/stale.gleam");
  session.client.start();
  vscode.controller.createTestRun = () => ({
    enqueued() {}, appendOutput() {}, end() {},
  });

  session.startOperation("run", { include: [], exclude: [] }, {
    onCancellationRequested() {},
  });
  assert.equal(diagnostics.values.size, 0);
  const [operationId] = session.activeRuns.keys();
  session.handleMessage({
    type: "error",
    request_id: operationId,
    message: "compile failed",
  });
  assert.equal(diagnostics.values.size, 0);
  session.dispose();
});

test("a requested operation restarts a missing daemon before it is sent", () => {
  const vscode = fakeVscode();
  const children = [];
  const run = {
    ended: false,
    enqueued() {},
    appendOutput() {},
    end() { this.ended = true; },
  };
  vscode.controller.createTestRun = () => run;
  const session = new WorkspaceSession(
    vscode,
    { name: "project", uri: new vscode.Uri("/project") },
    {
      diagnostics: { delete() {} },
      output: { append() {}, appendLine() {} },
      status: { text: "", show() {} },
    },
    () => {
      const child = fakeChild();
      children.push(child);
      return child;
    },
  );
  try {
    session.startOperation("run", { include: [], exclude: [] }, {
      onCancellationRequested() {},
    });
    assert.equal(children.length, 1);
    assert.equal(run.ended, false);
    assert.equal(JSON.parse(children[0].stdin.writes.at(-1)).command, "run");
  } finally {
    session.dispose();
  }
});

test("Testing API exclusions are preserved when a file or full suite is run", () => {
  const vscode = fakeVscode();
  const child = fakeChild();
  const shared = {
    diagnostics: { delete() {} },
    output: { append() {}, appendLine() {} },
    status: { text: "", show() {} },
  };
  const session = new WorkspaceSession(
    vscode,
    { name: "project", uri: new vscode.Uri("/project") },
    shared,
    () => child,
  );
  session.replaceTests([
    {
      id: "test/math.gleam::first_test",
      name: "first_test",
      path: "test/math.gleam",
      line: 1,
      column: 1,
      end_line: 2,
      end_column: 1,
      tags: [],
    },
    {
      id: "test/math.gleam::second_test",
      name: "second_test",
      path: "test/math.gleam",
      line: 4,
      column: 1,
      end_line: 5,
      end_column: 1,
      tags: [],
    },
  ]);
  const file = session.files.get("test/math.gleam");
  const excluded = session.items.get("test/math.gleam::second_test");
  assert.deepEqual(session.selectorsFor({ include: [file], exclude: [excluded] }), [
    "test/math.gleam::first_test",
  ]);
  assert.deepEqual(session.selectorsFor({ include: [], exclude: [excluded] }), [
    "test/math.gleam::first_test",
  ]);
  const run = {
    ended: false,
    enqueued() {},
    appendOutput() {},
    end() { this.ended = true; },
  };
  vscode.controller.createTestRun = () => run;
  session.start();
  const writesBefore = child.stdin.writes.length;
  session.startOperation("run", {
    include: [file],
    exclude: Array.from(session.items.values()),
  }, { onCancellationRequested() {} });
  assert.equal(run.ended, true);
  assert.equal(child.stdin.writes.length, writesBefore);
  session.dispose();
});

test("coverage profile publishes summaries and one-based LCOV details", async () => {
  const vscode = fakeVscode();
  const child = fakeChild();
  child.pid = 42;
  const run = {
    coverage: [],
    ended: false,
    enqueued() {},
    started() {},
    passed() {},
    skipped() {},
    failed() {},
    appendOutput() {},
    addCoverage(value) { this.coverage.push(value); },
    end() { this.ended = true; },
  };
  vscode.controller.createTestRun = () => run;
  const diagnostics = { set() {}, delete() {} };
  const shared = {
    diagnostics,
    output: { append() {}, appendLine() {} },
    status: { text: "", show() {} },
  };
  const folder = { name: "project", uri: new vscode.Uri("/project") };
  const calls = [];
  const session = new WorkspaceSession(
    vscode,
    folder,
    shared,
    (...arguments_) => {
      calls.push(arguments_);
      return child;
    },
    async () => "SF:src/math.gleam\nDA:2,3\nDA:7,0\nend_of_record\n",
  );
  session.replaceTests([{
    id: "test/math.gleam::addition_test",
    name: "addition_test",
    path: "test/math.gleam",
    line: 1,
    column: 1,
    end_line: 1,
    end_column: 2,
    tags: [],
  }]);
  const request = {
    include: [session.items.get("test/math.gleam::addition_test")],
  };
  const token = { onCancellationRequested() {} };
  const completed = session.runCoverage(request, token);
  assert.deepEqual(calls[0][1], [
    "run", "-m", "kangaroo", "--", "coverage",
    "test/math.gleam::addition_test",
    "--reporter", "ndjson",
    "--coverage-reporter", "lcov",
  ]);
  child.emit("close", 0, null);
  await completed;

  assert.equal(run.ended, true);
  assert.equal(run.coverage.length, 1);
  assert.deepEqual(run.coverage[0].statementCoverage, { covered: 1, total: 2 });
  const profile = vscode.controller.profiles[2];
  const details = await profile.loadDetailedCoverage(undefined, run.coverage[0]);
  assert.equal(details[0].executed, 3);
  assert.equal(details[0].location.line, 1);
  assert.equal(details[1].executed, 0);
  session.dispose();
});

test("coverage waits for stdout to close before publishing its final result", async () => {
  const vscode = fakeVscode();
  const child = fakeChild();
  const run = {
    ended: false,
    passedCount: 0,
    enqueued() {}, started() {}, skipped() {}, failed() {}, appendOutput() {},
    passed() { this.passedCount += 1; },
    addCoverage() {},
    end() { this.ended = true; },
  };
  vscode.controller.createTestRun = () => run;
  const session = new WorkspaceSession(
    vscode,
    { name: "project", uri: new vscode.Uri("/project") },
    {
      diagnostics: { set() {}, delete() {} },
      output: { append() {}, appendLine() {} },
      status: { text: "", show() {} },
    },
    () => child,
    async () => "",
  );
  session.replaceTests([{
    id: "test/math.gleam::addition_test",
    name: "addition_test",
    path: "test/math.gleam",
    line: 1,
    column: 1,
    end_line: 1,
    end_column: 2,
    tags: [],
  }]);

  const completed = session.runCoverage({ include: [] }, {
    onCancellationRequested() {},
  });
  child.emit("exit", 0, null);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(run.ended, false);
  child.stdout.emit("data", `${JSON.stringify({
    type: "case_finished",
    suite: "math",
    case: "test/math.gleam::addition_test",
    outcome: { kind: "passed" },
    duration_ms: 1,
  })}\n`);
  child.emit("close", 0, null);
  await completed;

  assert.equal(run.passedCount, 1);
  assert.equal(run.ended, true);
  session.dispose();
});

test("cancelled coverage never republishes an older LCOV file", async () => {
  const vscode = fakeVscode();
  const child = fakeChild();
  child.pid = 42;
  const run = {
    coverage: [],
    output: [],
    enqueued() {}, started() {}, passed() {}, skipped() {}, failed() {},
    appendOutput(value) { this.output.push(value); },
    addCoverage(value) { this.coverage.push(value); },
    end() {},
  };
  vscode.controller.createTestRun = () => run;
  const session = new WorkspaceSession(
    vscode,
    { name: "project", uri: new vscode.Uri("/project") },
    {
      diagnostics: { set() {}, delete() {} },
      output: { append() {}, appendLine() {} },
      status: { text: "", show() {} },
    },
    () => child,
    async () => "SF:src/stale.gleam\nDA:1,1\nend_of_record\n",
  );
  let cancel;
  const completed = session.runCoverage({ include: [] }, {
    onCancellationRequested(callback) { cancel = callback; },
  });
  cancel();
  assert.equal(session.coverageProcesses.size, 1);
  const outputCount = run.output.length;
  child.stdout.emit("data", '{"type":"run_finished"}\n');
  child.stderr.emit("data", "late compiler output\n");
  assert.equal(run.output.length, outputCount);
  // Windows taskkill reports a normal non-zero exit without a signal. The
  // cancellation flag, not the platform-specific exit shape, must suppress
  // the previous LCOV file.
  child.emit("close", 1, null);
  await completed;
  assert.equal(run.coverage.length, 0);
  assert.equal(session.coverageProcesses.size, 0);
  session.dispose();
});

test("a newer test generation suppresses completed stale coverage", async () => {
  const vscode = fakeVscode();
  const child = fakeChild();
  child.pid = 42;
  const run = {
    coverage: [],
    output: [],
    enqueued() {}, started() {}, passed() {}, skipped() {}, failed() {},
    appendOutput(value) { this.output.push(value); },
    addCoverage(value) { this.coverage.push(value); },
    end() {},
  };
  vscode.controller.createTestRun = () => run;
  const session = new WorkspaceSession(
    vscode,
    { name: "project", uri: new vscode.Uri("/project") },
    {
      diagnostics: { set() {}, delete() {} },
      output: { append() {}, appendLine() {} },
      status: { text: "", show() {} },
    },
    () => child,
    async () => "SF:src/stale.gleam\nDA:1,1\nend_of_record\n",
  );
  const completed = session.runCoverage({ include: [] }, {
    onCancellationRequested() {},
  });

  session.beginRunGeneration({
    state: { beginRun() {} },
    generation: 0,
  });
  child.emit("close", 0, null);
  await completed;

  assert.equal(run.coverage.length, 0);
  assert.match(run.output.join(""), /coverage superseded/);
  session.dispose();
});

test("coverage runs are package-serial until prior process ownership ends", async () => {
  const vscode = fakeVscode();
  const child = fakeChild();
  child.pid = 42;
  const runs = [];
  vscode.controller.createTestRun = () => {
    const run = {
      output: [],
      ended: false,
      enqueued() {}, started() {}, passed() {}, skipped() {}, failed() {},
      appendOutput(value) { this.output.push(value); },
      addCoverage() {},
      end() { this.ended = true; },
    };
    runs.push(run);
    return run;
  };
  let spawnCount = 0;
  const session = new WorkspaceSession(
    vscode,
    { name: "project", uri: new vscode.Uri("/project") },
    {
      diagnostics: { set() {}, delete() {} },
      output: { append() {}, appendLine() {} },
      status: { text: "", show() {} },
    },
    () => {
      spawnCount += 1;
      return child;
    },
  );
  let cancel;
  const first = session.runCoverage({ include: [] }, {
    onCancellationRequested(callback) { cancel = callback; },
  });
  await session.runCoverage({ include: [] }, {
    onCancellationRequested() {},
  });
  assert.equal(spawnCount, 1);
  assert.equal(runs[1].ended, true);
  assert.match(runs[1].output[0], /already running or stopping/);
  cancel();
  assert.equal(session.coverageProcesses.size, 1);
  child.emit("close", 1, null);
  await first;
  assert.equal(session.coverageProcesses.size, 0);
  session.dispose();
});

test("coverage remains cancellable while the LCOV file is being read", async () => {
  const vscode = fakeVscode();
  const child = fakeChild();
  child.pid = 42;
  let finishRead;
  const run = {
    coverage: [],
    endCount: 0,
    enqueued() {}, started() {}, passed() {}, skipped() {}, failed() {},
    appendOutput() {},
    addCoverage(value) { this.coverage.push(value); },
    end() { this.endCount += 1; },
  };
  vscode.controller.createTestRun = () => run;
  const session = new WorkspaceSession(
    vscode,
    { name: "project", uri: new vscode.Uri("/project") },
    {
      diagnostics: { set() {}, delete() {} },
      output: { append() {}, appendLine() {} },
      status: { text: "", show() {} },
    },
    () => child,
    () => new Promise((resolve) => { finishRead = resolve; }),
  );
  let cancel;
  const completed = session.runCoverage({ include: [] }, {
    onCancellationRequested(callback) { cancel = callback; },
  });

  child.emit("close", 0, null);
  assert.equal(typeof finishRead, "function");
  cancel();
  finishRead("SF:src/stale.gleam\nDA:1,1\nend_of_record\n");
  await completed;

  assert.equal(run.coverage.length, 0);
  assert.equal(run.endCount, 1);
  session.dispose();
});

test("unexpected daemon exit clears state, ends runs, and deterministically rediscovers", () => {
  const vscode = fakeVscode();
  const children = [];
  const scheduled = [];
  const diagnostics = {
    values: new Map([["/project/test/math.gleam", [{}]]]),
    delete(uri) { this.values.delete(uri.toString()); },
  };
  const shared = {
    diagnostics,
    output: { append() {}, appendLine() {} },
    status: { text: "", show() {} },
  };
  const folder = { name: "project", uri: new vscode.Uri("/project") };
  const run = {
    ended: false,
    output: "",
    appendOutput(value) { this.output += value; },
    end() { this.ended = true; },
  };
  const session = new WorkspaceSession(
    vscode,
    folder,
    shared,
    () => {
      const child = fakeChild();
      children.push(child);
      return child;
    },
    async () => "",
    (callback, delay) => {
      scheduled.push({ callback, delay });
      return { unref() {} };
    },
  );
  try {
    session.start();
    session.replaceTests([{
      id: "test/stale.gleam::stale_test",
      name: "stale_test",
      path: "test/stale.gleam",
      line: 1,
      column: 1,
      tags: [],
    }]);
    session.activeRuns.set("watch-1", { run, command: "watch" });
    session.diagnosticUris.add("/project/test/math.gleam");

    children[0].emit("exit", 1, null);

    assert.equal(run.ended, true);
    assert.match(run.output, /restarting/);
    assert.equal(diagnostics.values.size, 0);
    assert.equal(session.items.size, 0);
    assert.match(shared.status.text, /restarting/);
    assert.equal(scheduled.length, 1);
    assert.equal(scheduled[0].delay, 100);

    scheduled[0].callback();
    assert.equal(children.length, 2);
    const requests = children[1].stdin.writes.map((line) => JSON.parse(line));
    assert.equal(requests.at(-1).command, "discover");
  } finally {
    session.dispose();
  }
});

test("short-lived daemon messages do not reset exponential restart backoff", () => {
  const vscode = fakeVscode();
  const children = [];
  const scheduled = [];
  let clock = 0;
  const session = new WorkspaceSession(
    vscode,
    { name: "project", uri: new vscode.Uri("/project") },
    {
      diagnostics: { delete() {} },
      output: { append() {}, appendLine() {} },
      status: { text: "", show() {} },
    },
    () => {
      const child = fakeChild();
      children.push(child);
      return child;
    },
    async () => "",
    (callback, delay) => {
      const timer = { callback, delay, unref() {} };
      scheduled.push(timer);
      return timer;
    },
    () => clock,
  );
  try {
    session.start();
    session.handleMessage({
      type: "discovered",
      request_id: session.latestDiscoveryId,
      tests: [],
    });
    children[0].emit("exit", 1, null);
    assert.equal(scheduled[0].delay, 100);

    clock = 100;
    scheduled[0].callback();
    session.handleMessage({
      type: "discovered",
      request_id: session.latestDiscoveryId,
      tests: [],
    });
    children[1].emit("exit", 1, null);
    assert.equal(scheduled[1].delay, 200);

    clock = 200;
    scheduled[1].callback();
    clock = 10_300;
    session.handleMessage({
      type: "discovered",
      request_id: session.latestDiscoveryId,
      tests: [],
    });
    children[2].emit("exit", 1, null);
    assert.equal(scheduled[2].delay, 100);
  } finally {
    session.dispose();
  }
});

test("cancel acknowledgement ends the matching continuous test run", () => {
  const vscode = fakeVscode();
  const child = fakeChild();
  const run = {
    ended: false,
    failedCount: 0,
    enqueued() {},
    started() {},
    passed() {},
    skipped() {},
    failed() { this.failedCount += 1; },
    appendOutput() {},
    end() { this.ended = true; },
  };
  vscode.controller.createTestRun = () => run;
  const diagnosticValues = new Map();
  const shared = {
    diagnostics: {
      set(uri, values) { diagnosticValues.set(uri.toString(), values); },
      delete(uri) { diagnosticValues.delete(uri.toString()); },
    },
    output: { append() {}, appendLine() {} },
    status: { text: "unchanged", show() {} },
  };
  const session = new WorkspaceSession(
    vscode,
    { name: "project", uri: new vscode.Uri("/project") },
    shared,
    () => child,
  );
  let cancel;
  try {
    session.start();
    session.replaceTests([{
      id: "test/math.gleam::addition_test",
      name: "addition_test",
      path: "test/math.gleam",
      line: 1,
      column: 1,
      end_line: 1,
      end_column: 2,
      tags: [],
    }]);
    session.startOperation("watch", { include: [] }, {
      onCancellationRequested(callback) { cancel = callback; },
    });
    const operationId = Array.from(session.activeRuns.keys())[0];
    cancel();
    const cancelRequest = JSON.parse(child.stdin.writes.at(-1));
    assert.equal(cancelRequest.command, "cancel");
    assert.equal(cancelRequest.operation_id, operationId);
    assert.equal(run.ended, true);
    assert.equal(session.activeRuns.size, 0);

    session.handleMessage({
      protocol_version: 1,
      type: "event",
      request_id: operationId,
      event: {
        type: "case_finished",
        case: "test/math.gleam::addition_test",
        outcome: {
          kind: "failed",
          failures: [{
            message: "cancelled result",
            location: { file: "test/math.gleam", line: 1, column: 1 },
          }],
        },
      },
    });
    session.handleMessage({
      protocol_version: 1,
      type: "event",
      request_id: operationId,
      event: {
        type: "run_finished",
        summary: { passed: 0, failed: 1, skipped: 0, duration_ms: 1 },
      },
    });
    assert.equal(run.failedCount, 0);
    assert.equal(shared.status.text, "unchanged");
    assert.equal(diagnosticValues.size, 0);

    session.handleMessage({
      protocol_version: 1,
      type: "cancelled",
      request_id: cancelRequest.id,
      operation_id: operationId,
    });
    assert.equal(run.ended, true);
    assert.equal(session.activeRuns.size, 0);
  } finally {
    session.dispose();
  }
});

test("disposing waits for both daemon and coverage process exits", async () => {
  const vscode = fakeVscode();
  const daemon = fakeChild();
  const coverage = fakeChild();
  const runs = [];
  vscode.controller.createTestRun = () => {
    const run = {
      ended: false,
      enqueued() {},
      appendOutput() {},
      end() { this.ended = true; },
    };
    runs.push(run);
    return run;
  };
  const children = [daemon, coverage];
  const session = new WorkspaceSession(
    vscode,
    { name: "project", uri: new vscode.Uri("/project") },
    {
      diagnostics: { delete() {} },
      output: { append() {}, appendLine() {} },
      status: { text: "", show() {} },
    },
    () => children.shift(),
  );
  try {
    session.start();
    session.startOperation("watch", { include: [], exclude: [] }, {
      onCancellationRequested() {},
    });
    const coverageFinished = session.runCoverage(
      { include: [], exclude: [] },
      { onCancellationRequested() {} },
    );
    assert.equal(runs.length, 2);

    let disposed = false;
    const disposal = session.dispose().then(() => { disposed = true; });

    assert.equal(runs[0].ended, true);
    assert.equal(runs[1].ended, true);
    assert.equal(session.activeRuns.size, 0);
    await coverageFinished;
    assert.equal(disposed, false);
    daemon.emit("exit", 0, null);
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(disposed, false);
    coverage.emit("close", 1, null);
    await disposal;
    assert.equal(disposed, true);
  } finally {
    session.dispose();
  }
});

test("one workspace folder starts one daemon per nested Gleam package", async () => {
  const root = { name: "repo", uri: fakeVscode().Uri.file("/repo") };
  const vscode = fakeExtensionHostVscode([root], [
    "/repo/packages/alpha/gleam.toml",
    "/repo/packages/beta/gleam.toml",
  ]);
  // Use this host's Uri class for all workspace records.
  vscode.workspace.workspaceFolders = [
    { name: "repo", uri: vscode.Uri.file("/repo") },
  ];
  const starts = [];
  const extension = createExtension(vscode, (_executable, _arguments, options) => {
    starts.push(options.cwd);
    return fakeChild();
  });
  const context = { subscriptions: [] };
  try {
    const api = await extension.activate(context);
    assert.equal(api, extension);
    assert.deepEqual(Array.from(extension.sessions.keys()).sort(), [
      "/repo/packages/alpha",
      "/repo/packages/beta",
    ]);
    assert.deepEqual(starts.sort(), [
      "/repo/packages/alpha",
      "/repo/packages/beta",
    ]);
  } finally {
    extension.deactivate();
  }
});

test("temporary coverage clones are excluded from monorepo package discovery", async () => {
  const seed = fakeVscode();
  const vscode = fakeExtensionHostVscode(
    [{ name: "repo", uri: seed.Uri.file("/repo") }],
    [
      "/repo/packages/alpha/gleam.toml",
      "/repo/packages/.kangaroo-coverage-123/gleam.toml",
    ],
  );
  vscode.workspace.workspaceFolders = [
    { name: "repo", uri: vscode.Uri.file("/repo") },
  ];
  const starts = [];
  const extension = createExtension(vscode, (_executable, _arguments, options) => {
    starts.push(options.cwd);
    return fakeChild();
  });
  try {
    await extension.activate({ subscriptions: [] });
    assert.deepEqual(Array.from(extension.sessions.keys()), [
      "/repo/packages/alpha",
    ]);
    assert.deepEqual(starts, ["/repo/packages/alpha"]);
    assert.match(vscode.findFileExcludes.at(-1), /\.kangaroo-coverage-\*/);
  } finally {
    extension.deactivate();
  }
});

test("manifest watcher removes deleted packages and starts newly added packages", async () => {
  const manifests = ["/repo/alpha/gleam.toml", "/repo/beta/gleam.toml"];
  const seed = fakeVscode();
  const vscode = fakeExtensionHostVscode(
    [{ name: "repo", uri: seed.Uri.file("/repo") }],
    manifests,
  );
  vscode.workspace.workspaceFolders = [
    { name: "repo", uri: vscode.Uri.file("/repo") },
  ];
  const starts = [];
  const children = new Map();
  const extension = createExtension(vscode, (_executable, _arguments, options) => {
    starts.push(options.cwd);
    const child = fakeChild();
    children.set(options.cwd, child);
    return child;
  });
  try {
    await extension.activate({ subscriptions: [] });
    manifests.splice(0, 1);
    const removed = vscode.watcherListeners.delete[0]();
    await new Promise((resolve) => setImmediate(resolve));
    children.get("/repo/alpha").emit("exit", 0, null);
    await removed;
    assert.deepEqual(Array.from(extension.sessions.keys()), ["/repo/beta"]);

    manifests.push("/repo/gamma/gleam.toml");
    await vscode.watcherListeners.create[0]();
    assert.deepEqual(Array.from(extension.sessions.keys()).sort(), [
      "/repo/beta",
      "/repo/gamma",
    ]);
    assert.deepEqual(starts.sort(), ["/repo/alpha", "/repo/beta", "/repo/gamma"]);
  } finally {
    extension.deactivate();
  }
});

test("changing a manifest waits for the old daemon to exit before restarting", async () => {
  const seed = fakeVscode();
  const vscode = fakeExtensionHostVscode(
    [{ name: "repo", uri: seed.Uri.file("/repo") }],
    ["/repo/gleam.toml"],
  );
  vscode.workspace.workspaceFolders = [
    { name: "repo", uri: vscode.Uri.file("/repo") },
  ];
  const children = [];
  const extension = createExtension(vscode, () => {
    const child = fakeChild();
    children.push(child);
    return child;
  });
  try {
    await extension.activate({ subscriptions: [] });
    const before = extension.sessions.get("/repo");
    const restart = vscode.watcherListeners.change[0](
      vscode.Uri.file("/repo/gleam.toml"),
    );
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(children.length, 1);
    children[0].emit("exit", 0, null);
    await restart;
    const after = extension.sessions.get("/repo");
    assert.notEqual(after, before);
    assert.equal(children.length, 2);
  } finally {
    extension.deactivate();
  }
});

test("changing package-scoped settings restarts the affected daemon", async () => {
  const settings = { gleamPath: "/tools/gleam-one" };
  const seed = fakeVscode();
  const vscode = fakeExtensionHostVscode(
    [{ name: "repo", uri: seed.Uri.file("/repo") }],
    ["/repo/gleam.toml"],
    settings,
  );
  vscode.workspace.workspaceFolders = [
    { name: "repo", uri: vscode.Uri.file("/repo") },
  ];
  const executables = [];
  const children = [];
  const extension = createExtension(vscode, (executable) => {
    executables.push(executable);
    const child = fakeChild();
    children.push(child);
    return child;
  });
  try {
    await extension.activate({ subscriptions: [] });
    settings.gleamPath = "/tools/gleam-two";
    const restart = vscode.configurationListeners[0]({
      affectsConfiguration(section, uri) {
        return section === "kangaroo" && uri.toString() === "/repo";
      },
    });
    await new Promise((resolve) => setImmediate(resolve));
    assert.deepEqual(executables, ["/tools/gleam-one"]);
    children[0].emit("exit", 0, null);
    await restart;
    assert.deepEqual(executables, ["/tools/gleam-one", "/tools/gleam-two"]);
  } finally {
    extension.deactivate();
  }
});

test("extension deactivation waits for package daemon exit", async () => {
  const seed = fakeVscode();
  const vscode = fakeExtensionHostVscode(
    [{ name: "repo", uri: seed.Uri.file("/repo") }],
    ["/repo/gleam.toml"],
  );
  vscode.workspace.workspaceFolders = [
    { name: "repo", uri: vscode.Uri.file("/repo") },
  ];
  const child = fakeChild();
  const extension = createExtension(vscode, () => child);
  await extension.activate({ subscriptions: [] });

  let stopped = false;
  const deactivation = extension.deactivate().then(() => { stopped = true; });
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(stopped, false);
  child.emit("exit", 0, null);
  await deactivation;
  assert.equal(stopped, true);
});
