"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { EventEmitter } = require("node:events");
const {
  DaemonClient,
  WorkspaceSession,
  createExtension,
} = require("../extension");
const { protocolRequest } = require("../core");

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
  child.kill = () => { child.killed = true; };
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
  });
  client.start();
  assert.deepEqual(calls[0][1], ["run", "-m", "kangaroo", "--", "daemon"]);
  assert.equal(calls[0][2].detached, globalThis.process.platform !== "win32");
  assert.equal(child.stdout.encoding, "utf8");
  assert.equal(child.stderr.encoding, "utf8");
  child.stderr.emit("data", "compiler diagnostic\n");
  assert.match(client.diagnosticLog(), /compiler diagnostic/);
  child.stdout.emit("data", '{"protocol_version":1,"type":"shutdown"}\nnoise\n');
  assert.equal(messages.length, 1);
  assert.match(logs.at(-1), /invalid daemon stdout/);
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
  assert.equal(exits.length, 1);
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
  assert.equal(exits.length, 1);
  assert.match(logs[0], /stdin.*EPIPE/);
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

function fakeVscode() {
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
      getConfiguration: () => ({ get: (_key, fallback) => fallback }),
    },
    controller,
  };
}

function fakeExtensionHostVscode(workspaceFolders, manifests) {
  const vscode = fakeVscode();
  const controllers = [];
  const workspaceListeners = [];
  const watcherListeners = { create: [], delete: [] };
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
  vscode.workspace.findFiles = async (pattern) => {
    const root = pattern.base.uri.fsPath.replaceAll("\\", "/");
    return manifests
      .filter((manifest) => manifest.replaceAll("\\", "/").startsWith(`${root}/`))
      .map((manifest) => vscode.Uri.file(manifest));
  };
  vscode.workspace.onDidChangeWorkspaceFolders = (listener) => {
    workspaceListeners.push(listener);
    return disposable();
  };
  vscode.workspace.createFileSystemWatcher = () => ({
    onDidCreate(listener) { watcherListeners.create.push(listener); return disposable(); },
    onDidDelete(listener) { watcherListeners.delete.push(listener); return disposable(); },
    dispose() {},
  });
  vscode.workspaceListeners = workspaceListeners;
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
  child.emit("exit", 0, null);
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
    session.activeRuns.set("watch-1", { run, command: "watch" });
    session.diagnosticUris.add("/project/test/math.gleam");

    children[0].emit("exit", 1, null);

    assert.equal(run.ended, true);
    assert.match(run.output, /restarting/);
    assert.equal(diagnostics.values.size, 0);
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

test("cancel acknowledgement ends the matching continuous test run", () => {
  const vscode = fakeVscode();
  const child = fakeChild();
  const run = {
    ended: false,
    enqueued() {},
    appendOutput() {},
    end() { this.ended = true; },
  };
  vscode.controller.createTestRun = () => run;
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
  let cancel;
  try {
    session.start();
    session.startOperation("watch", { include: [] }, {
      onCancellationRequested(callback) { cancel = callback; },
    });
    const operationId = Array.from(session.activeRuns.keys())[0];
    cancel();
    const cancelRequest = JSON.parse(child.stdin.writes.at(-1));
    assert.equal(cancelRequest.command, "cancel");
    assert.equal(cancelRequest.operation_id, operationId);

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
  const extension = createExtension(vscode, (_executable, _arguments, options) => {
    starts.push(options.cwd);
    return fakeChild();
  });
  try {
    await extension.activate({ subscriptions: [] });
    manifests.splice(0, 1);
    await vscode.watcherListeners.delete[0]();
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
