"use strict";

const path = require("node:path");
const { spawn } = require("node:child_process");
const { readFileSync } = require("node:fs");
const { readFile } = require("node:fs/promises");
const {
  coverageArguments,
  LineDecoder,
  parseLcov,
  PROTOCOL_VERSION,
  RunState,
  daemonArguments,
  failuresFor,
  projectTarget,
  protocolRequest,
  resolveGleamExecutable,
  subprocessEnvironment,
  zeroBasedRange,
} = require("./core");

let activeExtension;

class DaemonClient {
  constructor({
    cwd,
    executable,
    onMessage,
    onLog,
    onExit,
    spawnProcess = spawn,
    schedule = setTimeout,
    cancelSchedule = clearTimeout,
    discoveryTimeoutMs = 60_000,
    terminateProcess = terminateProcessTree,
    target,
  }) {
    this.cwd = cwd;
    this.executable = executable;
    this.onMessage = onMessage;
    this.onLog = onLog;
    this.onExit = onExit;
    this.spawnProcess = spawnProcess;
    this.schedule = schedule;
    this.cancelSchedule = cancelSchedule;
    this.discoveryTimeoutMs = discoveryTimeoutMs;
    this.terminateProcess = terminateProcess;
    this.target = target;
    this.logHistory = [];
    this.pendingDiscoveries = new Map();
    this.process = null;
    this.finishProcess = null;
    this.stopping = false;
  }

  start() {
    if (this.process) return true;
    this.stopping = false;
    let child;
    try {
      child = this.spawnProcess(this.executable, daemonArguments(this.target), {
        cwd: this.cwd,
        stdio: ["pipe", "pipe", "pipe"],
        windowsHide: true,
        detached: globalThis.process.platform !== "win32",
        env: subprocessEnvironment(),
      });
    } catch (error) {
      this.log(`daemon error: ${error.message}`);
      this.onExit({ code: null, signal: null, expected: false });
      return false;
    }
    this.process = child;
    let finished = false;
    const finish = (code, signal) => {
      if (finished) return;
      finished = true;
      this.clearPendingDiscoveries();
      if (this.process === child) this.process = null;
      if (this.finishProcess === finish) this.finishProcess = null;
      this.onExit({ code, signal, expected: this.stopping });
    };
    this.finishProcess = finish;
    const decoder = new LineDecoder();
    child.stdout.setEncoding?.("utf8");
    child.stderr.setEncoding?.("utf8");
    child.stdout.on("data", (chunk) => {
      for (const line of decoder.push(chunk)) {
        try {
          const message = JSON.parse(line);
          if (message.protocol_version === PROTOCOL_VERSION) {
            this.acknowledgeDiscovery(message.request_id);
            this.onMessage(message);
          }
          else this.log(`unsupported daemon message: ${line}`);
        } catch {
          this.log(`invalid daemon stdout: ${line}`);
        }
      }
    });
    child.stderr.on("data", (chunk) => this.log(String(chunk)));
    child.stdin.on?.("error", (error) => {
      this.handleStdinFailure(error, child);
    });
    child.on("error", (error) => {
      this.log(`daemon error: ${error.message}`);
      finish(null, null);
    });
    child.on("exit", finish);
    return true;
  }

  send(message) {
    if (!this.process || !this.process.stdin.writable) return false;
    const child = this.process;
    try {
      child.stdin.write(`${JSON.stringify(message)}\n`);
    } catch (error) {
      this.handleStdinFailure(error, child);
      return false;
    }
    if (message.command === "discover" && typeof message.id === "string") {
      this.watchDiscovery(message.id, child);
    }
    return true;
  }

  log(message) {
    const rendered = String(message);
    this.logHistory.push(rendered);
    if (this.logHistory.length > 100) this.logHistory.shift();
    this.onLog(rendered);
  }

  diagnosticLog() {
    return this.logHistory.join("").slice(-65_536).trim();
  }

  handleStdinFailure(error, child) {
    if (!child || this.process !== child) return;
    this.log(`daemon stdin error: ${error.code || error.message}`);
    this.terminateProcess(child);
    this.finishProcess?.(null, null);
  }

  watchDiscovery(id, child) {
    this.acknowledgeDiscovery(id);
    const timer = this.schedule(() => {
      if (this.pendingDiscoveries.get(id) !== timer) return;
      this.log(`kangaroo: discovery timed out after ${this.discoveryTimeoutMs}ms; restarting daemon\n`);
      this.terminateProcess(child);
    }, this.discoveryTimeoutMs);
    timer.unref?.();
    this.pendingDiscoveries.set(id, timer);
  }

  acknowledgeDiscovery(id) {
    if (typeof id !== "string") return;
    const timer = this.pendingDiscoveries.get(id);
    if (!timer) return;
    this.cancelSchedule(timer);
    this.pendingDiscoveries.delete(id);
  }

  clearPendingDiscoveries() {
    for (const timer of this.pendingDiscoveries.values()) {
      this.cancelSchedule(timer);
    }
    this.pendingDiscoveries.clear();
  }

  stop() {
    this.stopping = true;
    this.clearPendingDiscoveries();
    const child = this.process;
    if (!child) return;
    this.send(protocolRequest("extension-shutdown", "shutdown"));
    const timer = setTimeout(() => {
      if (this.process === child) this.terminateProcess(child);
    }, 250);
    timer.unref?.();
  }
}

class WorkspaceSession {
  constructor(
    vscode,
    folder,
    shared,
    spawnProcess = spawn,
    readCoverageFile = readFile,
    schedule = setTimeout,
  ) {
    this.vscode = vscode;
    this.folder = folder;
    this.shared = shared;
    this.spawnProcess = spawnProcess;
    this.readCoverageFile = readCoverageFile;
    this.schedule = schedule;
    this.disposed = false;
    this.restartAttempt = 0;
    this.restartTimer = null;
    this.requestNumber = 0;
    this.items = new Map();
    this.files = new Map();
    this.activeRuns = new Map();
    this.runState = new RunState();
    this.diagnosticUris = new Set();
    this.coverageDetails = new WeakMap();
    this.coverageProcesses = new Set();
    try {
      this.target = projectTarget(readFileSync(
        path.join(this.folder.uri.fsPath, "gleam.toml"),
        "utf8",
      ));
    } catch {
      this.target = undefined;
    }
    const suffix = Buffer.from(folder.uri.toString()).toString("base64url");
    this.controller = vscode.tests.createTestController(
      `kangaroo-${suffix}`,
      `Kangaroo (${folder.name})`,
    );
    this.controller.refreshHandler = () => this.discover();
    this.createProfiles();
    this.client = this.createClient();
  }

  createClient() {
    const configured = this.vscode.workspace
      .getConfiguration("kangaroo", this.folder.uri)
      .get("gleamPath", "gleam");
    const executable = resolveGleamExecutable(configured);
    return new DaemonClient({
      cwd: this.folder.uri.fsPath,
      executable,
      target: this.target,
      spawnProcess: this.spawnProcess,
      onMessage: (message) => this.handleMessage(message),
      onLog: (message) => this.shared.output.append(message),
      onExit: (exit) => this.handleExit(exit),
    });
  }

  createProfiles() {
    const { TestRunProfileKind } = this.vscode;
    this.controller.createRunProfile(
      "Run",
      TestRunProfileKind.Run,
      (request, token) => this.startOperation("run", request, token),
      true,
    );
    const watch = this.controller.createRunProfile(
      "Watch",
      TestRunProfileKind.Run,
      (request, token) => this.startOperation("watch", request, token),
      false,
    );
    watch.supportsContinuousRun = true;
    const coverage = this.controller.createRunProfile(
      "Coverage",
      TestRunProfileKind.Coverage,
      (request, token) => this.runCoverage(request, token),
      true,
    );
    coverage.loadDetailedCoverage = (_run, fileCoverage) =>
      Promise.resolve(this.coverageDetails.get(fileCoverage) || []);
  }

  start() {
    this.client.start();
    this.discover();
  }

  discover() {
    if (!this.client.process) this.client.start();
    this.client.send(protocolRequest(this.nextId("discover"), "discover"));
  }

  nextId(prefix) {
    this.requestNumber += 1;
    return `${prefix}-${this.requestNumber}`;
  }

  selectorsFor(request) {
    const selectors = new Set();
    const collect = (target) => (item) => {
      if (this.items.has(item.id)) target.add(item.id);
      item.children?.forEach(collect(target));
    };
    const included = request.include || [];
    const excluded = request.exclude || [];
    if (included.length === 0 && excluded.length === 0) return [];
    if (included.length === 0) {
      for (const id of this.items.keys()) selectors.add(id);
    } else {
      included.forEach(collect(selectors));
    }
    const excludedIds = new Set();
    excluded.forEach(collect(excludedIds));
    for (const id of excludedIds) selectors.delete(id);
    return Array.from(selectors);
  }

  startOperation(command, request, token) {
    const id = this.nextId(command);
    const run = this.controller.createTestRun(request, `Kangaroo ${command}`);
    const selectors = this.selectorsFor(request);
    const explicitSelection = (request.include?.length || 0) > 0 ||
      (request.exclude?.length || 0) > 0;
    const selected = selectors.length === 0 && !explicitSelection
      ? Array.from(this.items.values())
      : selectors.map((selector) => this.items.get(selector)).filter(Boolean);
    selected.forEach((item) => run.enqueued(item));
    if (selected.length === 0 && explicitSelection) {
      run.end();
      return;
    }
    this.activeRuns.set(id, { run, command });
    const sent = this.client.send(protocolRequest(id, command, { selectors }));
    if (!sent) {
      run.appendOutput("kangaroo daemon is not running\r\n");
      run.end();
      this.activeRuns.delete(id);
      this.scheduleRestart();
      return;
    }
    token.onCancellationRequested(() => {
      this.client.send(protocolRequest(this.nextId("cancel"), "cancel", {
        operation_id: id,
      }));
    });
  }

  runCoverage(request, token) {
    const run = this.controller.createTestRun(request, "Kangaroo coverage");
    const selectors = this.selectorsFor(request);
    const explicitSelection = (request.include?.length || 0) > 0 ||
      (request.exclude?.length || 0) > 0;
    const selected = selectors.length === 0 && !explicitSelection
      ? Array.from(this.items.values())
      : selectors.map((selector) => this.items.get(selector)).filter(Boolean);
    selected.forEach((item) => run.enqueued(item));
    if (selected.length === 0 && explicitSelection) {
      run.end();
      return Promise.resolve();
    }
    const configured = this.vscode.workspace
      .getConfiguration("kangaroo", this.folder.uri)
      .get("gleamPath", "gleam");
    const executable = resolveGleamExecutable(configured);

    return new Promise((resolve) => {
      let child;
      let finished = false;
      const decoder = new LineDecoder();
      const end = () => {
        if (finished) return false;
        finished = true;
        if (child) this.coverageProcesses.delete(child);
        return true;
      };
      try {
        child = this.spawnProcess(
          executable,
          coverageArguments(selectors, this.target),
          {
            cwd: this.folder.uri.fsPath,
            stdio: ["ignore", "pipe", "pipe"],
            windowsHide: true,
            detached: globalThis.process.platform !== "win32",
            env: subprocessEnvironment(),
          },
        );
        this.coverageProcesses.add(child);
      } catch (error) {
        run.appendOutput(`could not start coverage: ${error.message}\r\n`);
        run.end();
        resolve();
        return;
      }

      child.stdout.setEncoding?.("utf8");
      child.stderr.setEncoding?.("utf8");

      const consume = (line) => {
        try {
          const event = JSON.parse(line);
          if (event && typeof event.type === "string") {
            this.handleEvent(run, event);
            return;
          }
        } catch {
          // Compiler and runtime diagnostics are still useful test output.
        }
        run.appendOutput(`${line}\r\n`);
      };
      child.stdout.on("data", (chunk) => {
        decoder.push(chunk).forEach(consume);
      });
      child.stderr.on("data", (chunk) => {
        run.appendOutput(String(chunk).replace(/(?<!\r)\n/g, "\r\n"));
      });
      child.on("error", (error) => {
        if (!end()) return;
        run.appendOutput(`coverage process failed: ${error.message}\r\n`);
        run.end();
        resolve();
      });
      child.on("exit", async (code, signal) => {
        if (!end()) return;
        if (decoder.remainder()) consume(decoder.remainder());
        try {
          const lcov = await this.readCoverageFile(
            path.join(this.folder.uri.fsPath, "coverage", "lcov.info"),
            "utf8",
          );
          this.publishCoverage(run, parseLcov(lcov));
        } catch (error) {
          if (code !== null && code < 2) {
            run.appendOutput(`could not read coverage/lcov.info: ${error.message}\r\n`);
          }
        }
        if (signal) run.appendOutput(`coverage cancelled (${signal})\r\n`);
        run.end();
        resolve();
      });
      token.onCancellationRequested(() => terminateProcessTree(child));
    });
  }

  publishCoverage(run, files) {
    for (const file of files) {
      const uri = this.vscode.Uri.joinPath(this.folder.uri, file.path);
      const details = file.lines.map((line) =>
        new this.vscode.StatementCoverage(
          line.hits,
          new this.vscode.Position(Math.max(0, line.line - 1), 0),
        ));
      const summary = new this.vscode.FileCoverage(uri, {
        covered: file.covered,
        total: file.total,
      });
      this.coverageDetails.set(summary, details);
      run.addCoverage(summary);
    }
  }

  handleMessage(message) {
    this.restartAttempt = 0;
    if (message.type === "discovered") {
      this.replaceTests(message.tests || []);
      this.shared.status.text = `Kangaroo: $(beaker) ${this.items.size} tests`;
      this.shared.status.show();
      return;
    }
    if (message.type === "cancelled") {
      const cancelled = this.activeRuns.get(message.operation_id);
      if (cancelled) {
        cancelled.run.end();
        this.activeRuns.delete(message.operation_id);
      }
      return;
    }
    const active = this.activeRuns.get(message.request_id);
    if (message.type === "event" && active) {
      this.handleEvent(active.run, message.event || {});
    } else if (message.type === "completed" && active) {
      active.run.end();
      this.activeRuns.delete(message.request_id);
    } else if (message.type === "error") {
      if (active) {
        active.run.appendOutput(`${message.message}\r\n`);
        active.run.end();
        this.activeRuns.delete(message.request_id);
      }
      this.shared.output.appendLine(`kangaroo: ${message.message}`);
    }
  }

  replaceTests(tests) {
    this.items.clear();
    this.files.clear();
    this.controller.items.replace([]);
    for (const test of tests) {
      let fileItem = this.files.get(test.path);
      if (!fileItem) {
        const uri = this.vscode.Uri.joinPath(this.folder.uri, test.path);
        fileItem = this.controller.createTestItem(
          `file:${test.path}`,
          path.basename(test.path),
          uri,
        );
        this.files.set(test.path, fileItem);
        this.controller.items.add(fileItem);
      }
      const item = this.controller.createTestItem(test.id, test.name, fileItem.uri);
      const range = zeroBasedRange(test);
      item.range = new this.vscode.Range(
        range.start.line,
        range.start.column,
        range.end.line,
        range.end.column,
      );
      item.tags = (test.tags || []).map((tag) => new this.vscode.TestTag(tag));
      fileItem.children.add(item);
      this.items.set(test.id, item);
    }
  }

  handleEvent(run, event) {
    const item = this.items.get(event.case);
    if (event.type === "run_started") {
      this.runState.beginRun();
      this.clearDiagnostics();
    } else if (event.type === "case_started" && item) {
      run.started(item);
    } else if (event.type === "case_finished" && item) {
      this.finishItem(run, item, event);
    } else if (event.type === "case_output") {
      if (event.stdout) run.appendOutput(event.stdout.replace(/\n/g, "\r\n"), undefined, item);
      if (event.stderr) run.appendOutput(event.stderr.replace(/\n/g, "\r\n"), undefined, item);
    } else if (event.type === "run_finished") {
      const summary = event.summary || {};
      const icon = summary.failed > 0 ? "$(error)" : "$(check)";
      this.shared.status.text =
        `Kangaroo: ${icon} ${summary.passed || 0} passed, ${summary.failed || 0} failed`;
      this.shared.status.show();
      this.rebuildDiagnostics();
    }
  }

  finishItem(run, item, event) {
    const outcome = event.outcome || {};
    const duration = event.duration_ms;
    const failures = failuresFor(event);
    this.runState.record(event.case, failures);
    if (outcome.kind === "passed") {
      run.passed(item, duration);
    } else if (outcome.kind === "skipped") {
      run.skipped(item);
    } else {
      const messages = (outcome.failures || []).map((failure) => {
        const text = failure.message ||
          `expected: ${failure.expected ?? "?"}, actual: ${failure.actual ?? "?"}`;
        const message = new this.vscode.TestMessage(text);
        if (failure.location?.file) {
          const uri = this.vscode.Uri.joinPath(this.folder.uri, failure.location.file);
          message.location = new this.vscode.Location(
            uri,
            new this.vscode.Position(
              Math.max(0, Number(failure.location.line || 1) - 1),
              Math.max(0, Number(failure.location.column || 1) - 1),
            ),
          );
        }
        return message;
      });
      run.failed(item, messages, duration);
    }
  }

  rebuildDiagnostics() {
    this.clearDiagnostics();
    const byFile = new Map();
    for (const diagnostic of this.runState.diagnostics()) {
      if (!byFile.has(diagnostic.file)) byFile.set(diagnostic.file, []);
      byFile.get(diagnostic.file).push(diagnostic);
    }
    for (const [file, diagnostics] of byFile) {
      const uri = this.vscode.Uri.joinPath(this.folder.uri, file);
      const rendered = diagnostics.map((entry) => new this.vscode.Diagnostic(
        new this.vscode.Range(entry.line, entry.column, entry.line, entry.column + 1),
        entry.message,
        this.vscode.DiagnosticSeverity.Error,
      ));
      this.shared.diagnostics.set(uri, rendered);
      this.diagnosticUris.add(uri.toString());
    }
  }

  clearDiagnostics() {
    for (const value of this.diagnosticUris) {
      this.shared.diagnostics.delete(this.vscode.Uri.parse(value));
    }
    this.diagnosticUris.clear();
  }

  handleExit(exit) {
    for (const { run } of this.activeRuns.values()) {
      run.appendOutput("kangaroo daemon exited; restarting\r\n");
      run.end();
    }
    this.activeRuns.clear();
    this.runState.beginRun();
    this.clearDiagnostics();
    if (!exit.expected && !this.disposed) {
      this.shared.status.text = "Kangaroo: $(warning) daemon restarting";
      this.shared.status.show();
      this.scheduleRestart();
    }
  }

  scheduleRestart() {
    if (this.disposed || this.restartTimer) return;
    const delay = Math.min(2000, 100 * (2 ** this.restartAttempt));
    this.restartAttempt += 1;
    const timer = this.schedule(() => {
      this.restartTimer = null;
      if (this.disposed || this.client.process) return;
      this.client.start();
      this.discover();
    }, delay);
    this.restartTimer = timer;
    timer.unref?.();
  }

  dispose() {
    this.disposed = true;
    for (const child of this.coverageProcesses) terminateProcessTree(child);
    this.coverageProcesses.clear();
    this.client.stop();
    this.clearDiagnostics();
    this.controller.dispose();
  }
}

async function discoverPackageFolders(vscode, workspaceFolder) {
  if (!vscode.workspace.findFiles || !vscode.RelativePattern) {
    return [workspaceFolder];
  }
  const pattern = new vscode.RelativePattern(workspaceFolder, "**/gleam.toml");
  const manifests = await vscode.workspace.findFiles(
    pattern,
    "**/{.git,build,node_modules}/**",
    10_000,
  );
  const packages = new Map();
  for (const manifest of manifests) {
    const packagePath = path.dirname(manifest.fsPath);
    const uri = typeof manifest.with === "function" && typeof manifest.path === "string"
      ? manifest.with({ path: path.posix.dirname(manifest.path) })
      : vscode.Uri.file(packagePath);
    const key = uri.toString();
    packages.set(key, {
      name: path.basename(packagePath) || workspaceFolder.name,
      uri,
      index: workspaceFolder.index,
    });
  }
  return Array.from(packages.values()).sort((left, right) =>
    left.uri.toString().localeCompare(right.uri.toString()));
}

function terminateProcessTree(child) {
  if (!child) return;
  if (globalThis.process.platform === "win32" && child.pid) {
    const killer = spawn(
      "taskkill",
      ["/pid", String(child.pid), "/T", "/F"],
      { stdio: "ignore", windowsHide: true },
    );
    killer.unref?.();
    return;
  }
  if (child.pid) {
    try {
      globalThis.process.kill(-child.pid, "SIGTERM");
      return;
    } catch {
      // A mocked or already-exited process may not own a process group.
    }
  }
  child.kill?.();
}

function createExtension(vscode, spawnProcess = spawn) {
  const sessions = new Map();
  let shared;
  let enabled = false;
  let refreshGeneration = 0;

  function addFolder(folder) {
    const key = folder.uri.toString();
    if (sessions.has(key)) return;
    const session = new WorkspaceSession(vscode, folder, shared, spawnProcess);
    sessions.set(key, session);
    session.start();
  }

  async function refreshPackages() {
    if (!enabled) return;
    const generation = ++refreshGeneration;
    const discovered = await Promise.all(
      (vscode.workspace.workspaceFolders || []).map((folder) =>
        discoverPackageFolders(vscode, folder)),
    );
    if (!enabled || generation !== refreshGeneration) return;
    const desired = new Map();
    for (const packages of discovered) {
      for (const folder of packages) desired.set(folder.uri.toString(), folder);
    }
    for (const [key, session] of sessions) {
      if (!desired.has(key)) {
        session.dispose();
        sessions.delete(key);
      }
    }
    for (const folder of desired.values()) addFolder(folder);
  }

  function activate(context) {
    enabled = true;
    shared = {
      diagnostics: vscode.languages.createDiagnosticCollection("kangaroo"),
      output: vscode.window.createOutputChannel("Kangaroo"),
      status: vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left),
    };
    shared.status.text = "Kangaroo: starting";
    context.subscriptions.push(shared.diagnostics, shared.output, shared.status);
    const manifestWatcher = vscode.workspace.createFileSystemWatcher?.(
      "**/gleam.toml",
    );
    if (manifestWatcher) {
      context.subscriptions.push(
        manifestWatcher,
        manifestWatcher.onDidCreate(() => refreshPackages()),
        manifestWatcher.onDidDelete(() => refreshPackages()),
      );
    }
    context.subscriptions.push(
      vscode.workspace.onDidChangeWorkspaceFolders(() => refreshPackages()),
      vscode.commands.registerCommand("kangaroo.start", async () => {
        enabled = true;
        await refreshPackages();
        for (const session of sessions.values()) session.start();
      }),
      vscode.commands.registerCommand("kangaroo.stop", () => {
        enabled = false;
        refreshGeneration += 1;
        for (const session of sessions.values()) session.dispose();
        sessions.clear();
        shared.diagnostics.clear();
        shared.status.text = "Kangaroo: stopped";
      }),
      vscode.commands.registerCommand("kangaroo.refresh", () => {
        for (const session of sessions.values()) session.discover();
      }),
    );
    return refreshPackages().then(() => api);
  }

  function deactivate() {
    enabled = false;
    refreshGeneration += 1;
    for (const session of sessions.values()) session.dispose();
    sessions.clear();
    shared?.diagnostics.clear();
  }

  const api = { activate, deactivate, refreshPackages, sessions };
  return api;
}

async function activate(context) {
  const vscode = require("vscode");
  activeExtension = createExtension(vscode);
  await activeExtension.activate(context);
  return activeExtension;
}

function deactivate() {
  activeExtension?.deactivate();
  activeExtension = undefined;
}

module.exports = {
  DaemonClient,
  WorkspaceSession,
  activate,
  createExtension,
  deactivate,
  discoverPackageFolders,
};
