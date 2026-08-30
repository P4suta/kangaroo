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
  javascriptRuntime,
  projectTarget,
  protocolRequest,
  protocolResponse,
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
    maxProtocolLineBytes = 128 * 1024 * 1024,
    terminateProcess = terminateProcessTree,
    target,
    runtime,
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
    this.maxProtocolLineBytes = maxProtocolLineBytes;
    this.terminateProcess = terminateProcess;
    this.target = target;
    this.runtime = javascriptRuntime(runtime);
    this.logHistory = "";
    this.pendingDiscoveries = new Map();
    this.process = null;
    this.activeProcess = null;
    this.activeProcessExit = Promise.resolve();
    this.stopping = false;
  }

  start() {
    if (this.process) return true;
    if (this.activeProcess) return false;
    this.stopping = false;
    let child;
    try {
      child = this.spawnProcess(
        this.executable,
        daemonArguments(this.target, this.runtime),
        {
          cwd: this.cwd,
          stdio: ["pipe", "pipe", "pipe"],
          windowsHide: true,
          detached: globalThis.process.platform !== "win32",
          env: subprocessEnvironment(),
        },
      );
    } catch (error) {
      this.log(`daemon error: ${error.message}`);
      this.onExit({ code: null, signal: null, expected: false });
      return false;
    }
    this.process = child;
    this.activeProcess = child;
    let resolveProcessExit;
    const processExit = new Promise((resolve) => {
      resolveProcessExit = resolve;
    });
    this.activeProcessExit = processExit;
    let finished = false;
    const finish = (code, signal) => {
      if (finished) return;
      finished = true;
      this.clearPendingDiscoveries();
      if (this.process === child) this.process = null;
      if (this.activeProcess === child) {
        this.activeProcess = null;
        this.activeProcessExit = Promise.resolve();
      }
      resolveProcessExit();
      this.onExit({ code, signal, expected: this.stopping });
    };
    const decoder = new LineDecoder(this.maxProtocolLineBytes);
    child.stdout.setEncoding?.("utf8");
    child.stderr.setEncoding?.("utf8");
    child.stdout.on("data", (chunk) => {
      if (this.process !== child) return;
      let lines;
      try {
        lines = decoder.push(chunk);
      } catch (error) {
        this.log(`daemon stdout error: ${error.message}\n`);
        this.retireProcess(child);
        return;
      }
      for (const line of lines) {
        try {
          const message = JSON.parse(line);
          if (message.protocol_version === PROTOCOL_VERSION) {
            if (!protocolResponse(message)) {
              throw new Error("invalid daemon stdout record");
            }
            this.acknowledgeDiscovery(message.request_id);
            this.onMessage(message);
          }
          else if (Number.isInteger(message?.protocol_version)) {
            this.log("unsupported daemon protocol version\n");
          }
          else throw new Error("invalid daemon stdout record");
        } catch {
          this.log("invalid daemon stdout record\n");
          this.retireProcess(child);
          return;
        }
      }
    });
    child.stderr.on("data", (chunk) => {
      if (this.process === child) this.log(String(chunk));
    });
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
    if (!this.process) return false;
    const child = this.process;
    if (!child.stdin.writable) {
      this.handleStdinFailure(new Error("daemon stdin is not writable"), child);
      return false;
    }
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
    this.logHistory = (this.logHistory + rendered).slice(-65_536);
    this.onLog(rendered);
  }

  diagnosticLog() {
    return this.logHistory.trim();
  }

  handleStdinFailure(error, child) {
    if (!child || this.process !== child) return;
    this.log(`daemon stdin error: ${error.code || error.message}`);
    this.retireProcess(child);
  }

  retireProcess(child) {
    if (!child || this.activeProcess !== child) return;
    this.clearPendingDiscoveries();
    if (this.process === child) this.process = null;
    this.terminateProcess(child);
  }

  watchDiscovery(id, child) {
    this.acknowledgeDiscovery(id);
    const timer = this.schedule(() => {
      if (this.pendingDiscoveries.get(id) !== timer) return;
      this.log(`kangaroo: discovery timed out after ${this.discoveryTimeoutMs}ms; restarting daemon\n`);
      this.retireProcess(child);
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
    const child = this.activeProcess;
    if (!child) return Promise.resolve();
    if (this.process === child) {
      this.send(protocolRequest("extension-shutdown", "shutdown"));
    }
    const timer = setTimeout(() => {
      if (this.activeProcess === child) this.retireProcess(child);
    }, 250);
    timer.unref?.();
    return this.activeProcessExit;
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
    now = Date.now,
  ) {
    this.vscode = vscode;
    this.folder = folder;
    this.shared = shared;
    this.spawnProcess = spawnProcess;
    this.readCoverageFile = readCoverageFile;
    this.schedule = schedule;
    this.now = now;
    this.disposed = false;
    this.restartAttempt = 0;
    this.restartTimer = null;
    this.daemonStartedAt = null;
    this.stableDaemonMs = 10_000;
    this.requestNumber = 0;
    this.latestDiscoveryId = null;
    this.items = new Map();
    this.files = new Map();
    this.activeRuns = new Map();
    this.runState = new RunState();
    this.latestRunGeneration = 0;
    this.diagnosticUris = new Set();
    this.coverageDetails = new WeakMap();
    this.coverageProcesses = new Map();
    this.disposePromise = null;
    const configuration = this.vscode.workspace
      .getConfiguration("kangaroo", this.folder.uri);
    this.javascriptRuntime = javascriptRuntime(
      configuration.get("javascriptRuntime", "nodejs"),
    );
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
      runtime: this.javascriptRuntime,
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
    this.controller.createRunProfile(
      "Watch",
      TestRunProfileKind.Run,
      (request, token) => this.startOperation("watch", request, token),
      false,
      undefined,
      true,
    );
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
    this.discover();
  }

  discover() {
    if (!this.ensureClient()) return;
    const id = this.nextId("discover");
    this.latestDiscoveryId = id;
    if (!this.client.send(protocolRequest(id, "discover"))) {
      if (this.latestDiscoveryId === id) this.latestDiscoveryId = null;
    }
  }

  ensureClient() {
    if (this.client.process) return true;
    const started = this.client.start();
    if (started && this.client.process) this.daemonStartedAt = this.now();
    return started;
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

  prepareRun(request, label) {
    const run = this.controller.createTestRun(request, label);
    const selectors = this.selectorsFor(request);
    const explicitSelection = (request.include?.length || 0) > 0 ||
      (request.exclude?.length || 0) > 0;
    const selected = selectors.length === 0 && !explicitSelection
      ? Array.from(this.items.values())
      : selectors.map((selector) => this.items.get(selector)).filter(Boolean);
    selected.forEach((item) => run.enqueued(item));
    if (selected.length === 0 && explicitSelection) {
      run.end();
      return { run, selectors, runnable: false };
    }
    return { run, selectors, runnable: true };
  }

  startOperation(command, request, token) {
    const id = this.nextId(command);
    const { run, selectors, runnable } = this.prepareRun(
      request,
      `Kangaroo ${command}`,
    );
    if (!runnable) return;
    const context = {
      run,
      command,
      state: new RunState(),
      items: new Map(this.items),
      generation: 0,
      receivedRunStarted: false,
    };
    this.activeRuns.set(id, context);
    this.beginRunGeneration(context);
    const sent = this.ensureClient() &&
      this.client.send(protocolRequest(id, command, { selectors }));
    if (!sent) {
      run.appendOutput("kangaroo daemon is not running\r\n");
      run.end();
      this.activeRuns.delete(id);
      this.scheduleRestart();
      return;
    }
    token.onCancellationRequested(() => {
      if (context.cancelled) return;
      context.cancelled = true;
      context.state.beginRun();
      if (context.generation === this.latestRunGeneration) {
        this.latestRunGeneration += 1;
        this.clearDiagnostics();
      }
      context.run.end();
      this.activeRuns.delete(id);
      this.client.send(protocolRequest(this.nextId("cancel"), "cancel", {
        operation_id: id,
      }));
    });
  }

  runCoverage(request, token) {
    const { run, selectors, runnable } = this.prepareRun(
      request,
      "Kangaroo coverage",
    );
    if (!runnable) return Promise.resolve();
    if (this.coverageProcesses.size > 0) {
      run.appendOutput(
        "kangaroo coverage is already running or stopping for this package\r\n",
      );
      run.end();
      return Promise.resolve();
    }
    const configured = this.vscode.workspace
      .getConfiguration("kangaroo", this.folder.uri)
      .get("gleamPath", "gleam");
    const executable = resolveGleamExecutable(configured);

    return new Promise((resolve) => {
      let child;
      let cancelled = false;
      let terminal = false;
      let completed = false;
      const decoder = new LineDecoder();
      const coverageContext = {
        run,
        state: new RunState(),
        items: new Map(this.items),
        generation: 0,
        receivedRunStarted: false,
      };
      this.beginRunGeneration(coverageContext);
      const finishOperation = () => {
        if (completed) return false;
        completed = true;
        run.end();
        resolve();
        return true;
      };
      const claimTerminal = () => {
        if (terminal) return false;
        terminal = true;
        return true;
      };
      const cancelCoverage = () => {
        if (cancelled || completed) return;
        cancelled = true;
        coverageContext.cancelled = true;
        coverageContext.state.beginRun();
        if (coverageContext.generation === this.latestRunGeneration) {
          this.latestRunGeneration += 1;
          this.clearDiagnostics();
        }
        if (!terminal) terminateProcessTree(child);
        finishOperation();
      };
      try {
        child = this.spawnProcess(
          executable,
          coverageArguments(
            selectors,
            this.target,
            this.javascriptRuntime,
          ),
          {
            cwd: this.folder.uri.fsPath,
            stdio: ["ignore", "pipe", "pipe"],
            windowsHide: true,
            detached: globalThis.process.platform !== "win32",
            env: subprocessEnvironment(),
          },
        );
        let resolveProcessExit;
        const processExit = new Promise((resolveExit) => {
          resolveProcessExit = resolveExit;
        });
        const coverageProcess = {
          cancel: cancelCoverage,
          exited: processExit,
          resolveExit: resolveProcessExit,
        };
        this.coverageProcesses.set(child, coverageProcess);
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
            this.handleEvent(run, event, coverageContext);
            return;
          }
        } catch {
          // Compiler and runtime diagnostics are still useful test output.
        }
        run.appendOutput(`${line}\r\n`);
      };
      child.stdout.on("data", (chunk) => {
        if (cancelled || completed) return;
        try {
          decoder.push(chunk).forEach(consume);
        } catch (error) {
          run.appendOutput(`coverage output failed: ${error.message}\r\n`);
          cancelCoverage();
        }
      });
      child.stderr.on("data", (chunk) => {
        if (cancelled || completed) return;
        run.appendOutput(String(chunk).replace(/(?<!\r)\n/g, "\r\n"));
      });
      child.on("error", (error) => {
        if (!claimTerminal()) return;
        const process = this.coverageProcesses.get(child);
        this.coverageProcesses.delete(child);
        process?.resolveExit();
        if (!cancelled) {
          run.appendOutput(`coverage process failed: ${error.message}\r\n`);
        }
        finishOperation();
      });
      child.on("exit", async (code, signal) => {
        if (!claimTerminal()) return;
        const process = this.coverageProcesses.get(child);
        process?.resolveExit();
        try {
          if (!cancelled && decoder.remainder()) consume(decoder.remainder());
          if (!cancelled && !this.disposed && !signal && code !== null && code < 2) {
            const lcov = await this.readCoverageFile(
              path.join(this.folder.uri.fsPath, "coverage", "lcov.info"),
              "utf8",
            );
            if (!cancelled && !this.disposed) {
              this.publishCoverage(run, parseLcov(lcov));
            }
          }
          if (!completed && signal) {
            run.appendOutput(`coverage cancelled (${signal})\r\n`);
          }
        } catch (error) {
          if (!cancelled && !this.disposed) {
            run.appendOutput(`could not read coverage/lcov.info: ${error.message}\r\n`);
          }
        } finally {
          this.coverageProcesses.delete(child);
          finishOperation();
        }
      });
      token.onCancellationRequested(cancelCoverage);
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
    if (this.disposed) return;
    if (message.type === "discovered") {
      if (
        this.latestDiscoveryId !== null &&
        message.request_id !== this.latestDiscoveryId
      ) return;
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
      active.state ||= new RunState();
      active.generation ||= 0;
      this.handleEvent(active.run, message.event || {}, active);
    } else if (message.type === "completed" && active) {
      active.run.end();
      this.activeRuns.delete(message.request_id);
    } else if (message.type === "error") {
      if (message.request_id === this.latestDiscoveryId) {
        this.replaceTests([]);
        this.shared.status.text = "Kangaroo: $(warning) discovery failed";
        this.shared.status.show();
      }
      if (active) {
        active.run.appendOutput(`${message.message}\r\n`);
        active.run.end();
        this.activeRuns.delete(message.request_id);
      }
      this.shared.output.appendLine(`kangaroo: ${message.message}`);
    }
  }

  replaceTests(tests) {
    const previousItems = this.items;
    const previousFiles = this.files;
    const items = new Map();
    const files = new Map();
    const children = new Map();
    for (const test of tests) {
      let fileItem = files.get(test.path);
      if (!fileItem) {
        fileItem = previousFiles.get(test.path);
        if (!fileItem) {
          const uri = this.vscode.Uri.joinPath(this.folder.uri, test.path);
          fileItem = this.controller.createTestItem(
            `file:${test.path}`,
            path.basename(test.path),
            uri,
          );
        }
        files.set(test.path, fileItem);
        children.set(test.path, []);
      }
      let item = previousItems.get(test.id);
      if (!item || item.uri.toString() !== fileItem.uri.toString()) {
        item = this.controller.createTestItem(test.id, test.name, fileItem.uri);
      }
      item.label = test.name;
      const range = zeroBasedRange(test);
      item.range = new this.vscode.Range(
        range.start.line,
        range.start.column,
        range.end.line,
        range.end.column,
      );
      item.tags = (test.tags || []).map((tag) => new this.vscode.TestTag(tag));
      children.get(test.path).push(item);
      items.set(test.id, item);
    }
    for (const [testPath, fileItem] of files) {
      fileItem.children.replace(children.get(testPath));
    }
    this.controller.items.replace(Array.from(files.values()));
    this.items = items;
    this.files = files;
  }

  handleEvent(run, event, context) {
    if (context?.cancelled) return;
    const state = context?.state || this.runState;
    const item = context?.items?.get(event.case) || this.items.get(event.case);
    if (event.type === "run_started") {
      if (context) context.items = new Map(this.items);
      if (
        context && context.generation > 0 && !context.receivedRunStarted
      ) {
        context.receivedRunStarted = true;
        state.beginRun();
        if (context.generation === this.latestRunGeneration) {
          this.clearDiagnostics();
        }
      } else {
        this.beginRunGeneration(context);
        if (context) context.receivedRunStarted = true;
      }
    } else if (event.type === "case_started" && item) {
      run.started(item);
    } else if (event.type === "case_finished" && item) {
      this.finishItem(run, item, event, state);
    } else if (event.type === "case_output") {
      if (event.stdout) run.appendOutput(event.stdout.replace(/\n/g, "\r\n"), undefined, item);
      if (event.stderr) run.appendOutput(event.stderr.replace(/\n/g, "\r\n"), undefined, item);
    } else if (event.type === "run_finished") {
      if (context && context.generation !== this.latestRunGeneration) return;
      const summary = event.summary || {};
      const icon = summary.failed > 0 ? "$(error)" : "$(check)";
      this.shared.status.text =
        `Kangaroo: ${icon} ${summary.passed || 0} passed, ${summary.failed || 0} failed`;
      this.shared.status.show();
      this.rebuildDiagnostics(state);
      if (context?.command === "watch") this.discover();
    }
  }

  beginRunGeneration(context) {
    const state = context?.state || this.runState;
    state.beginRun();
    const generation = ++this.latestRunGeneration;
    if (context) context.generation = generation;
    this.clearDiagnostics();
  }

  finishItem(run, item, event, state = this.runState) {
    const outcome = event.outcome || {};
    const duration = event.duration_ms;
    const failures = failuresFor(event);
    state.record(event.case, failures);
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

  rebuildDiagnostics(state = this.runState) {
    this.clearDiagnostics();
    const byFile = new Map();
    for (const diagnostic of state.diagnostics()) {
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
      this.replaceTests([]);
      if (
        this.daemonStartedAt !== null &&
        this.now() - this.daemonStartedAt >= this.stableDaemonMs
      ) {
        this.restartAttempt = 0;
      }
      this.daemonStartedAt = null;
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
      this.discover();
    }, delay);
    this.restartTimer = timer;
    timer.unref?.();
  }

  dispose() {
    if (this.disposed) return this.disposePromise || Promise.resolve();
    this.disposed = true;
    this.latestRunGeneration += 1;
    for (const { run } of this.activeRuns.values()) run.end?.();
    this.activeRuns.clear();
    this.runState.beginRun();
    const coverageExits = [];
    for (const coverageProcess of Array.from(this.coverageProcesses.values())) {
      coverageProcess.cancel();
      coverageExits.push(coverageProcess.exited);
    }
    const daemonExit = this.client.stop();
    this.clearDiagnostics();
    this.controller.dispose();
    this.disposePromise = Promise.all([daemonExit, ...coverageExits]);
    return this.disposePromise;
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

function terminateProcessTree(child, dependencies = {}) {
  if (!child) return;
  const platform = dependencies.platform || globalThis.process.platform;
  const spawnProcess = dependencies.spawnProcess || spawn;
  const killProcess = dependencies.killProcess || globalThis.process.kill;
  const forceChild = () => child.kill?.("SIGKILL");
  if (platform === "win32" && child.pid) {
    try {
      const killer = spawnProcess(
        "taskkill",
        ["/pid", String(child.pid), "/T", "/F"],
        { stdio: "ignore", windowsHide: true },
      );
      let settled = false;
      const fallback = () => {
        if (settled) return;
        settled = true;
        forceChild();
      };
      killer.on?.("error", fallback);
      killer.on?.("exit", (code) => {
        if (settled) return;
        settled = true;
        if (code !== 0) forceChild();
      });
      killer.unref?.();
      return;
    } catch {
      forceChild();
      return;
    }
  }
  if (child.pid) {
    try {
      killProcess(-child.pid, "SIGKILL");
      return;
    } catch {
      // A mocked or already-exited process may not own a process group.
    }
  }
  forceChild();
}

function createExtension(vscode, spawnProcess = spawn) {
  const sessions = new Map();
  const stoppingSessions = new Map();
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

  function stopSession(key, session) {
    sessions.delete(key);
    const stopped = Promise.resolve(session.dispose()).finally(() => {
      if (stoppingSessions.get(key) === stopped) stoppingSessions.delete(key);
    });
    stoppingSessions.set(key, stopped);
    return stopped;
  }

  function stopAllSessions() {
    const stopped = [];
    for (const [key, session] of sessions) {
      stopped.push(stopSession(key, session));
    }
    return Promise.all(stopped);
  }

  async function refreshPackages({ restartKey, restartKeys } = {}) {
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
    const stopping = new Set();
    for (const [key, session] of sessions) {
      if (!desired.has(key) || key === restartKey || restartKeys?.has(key)) {
        stopping.add(stopSession(key, session));
      }
    }
    for (const key of desired.keys()) {
      const barrier = stoppingSessions.get(key);
      if (barrier) stopping.add(barrier);
    }
    await Promise.all(stopping);
    if (!enabled || generation !== refreshGeneration) return;
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
        manifestWatcher.onDidChange((manifest) => {
          const packageUri =
            typeof manifest.with === "function" && typeof manifest.path === "string"
              ? manifest.with({ path: path.posix.dirname(manifest.path) })
              : vscode.Uri.file(path.dirname(manifest.fsPath));
          return refreshPackages({ restartKey: packageUri.toString() });
        }),
        manifestWatcher.onDidCreate(() => refreshPackages()),
        manifestWatcher.onDidDelete(() => refreshPackages()),
      );
    }
    const configurationSubscription =
      vscode.workspace.onDidChangeConfiguration?.(async (event) => {
        const affected = [];
        for (const [key, session] of sessions) {
          if (event.affectsConfiguration("kangaroo", session.folder.uri)) {
            affected.push(key);
          }
        }
        if (affected.length === 0) return;
        await refreshPackages({ restartKeys: new Set(affected) });
      });
    if (configurationSubscription) {
      context.subscriptions.push(configurationSubscription);
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
        const stopped = stopAllSessions();
        shared.diagnostics.clear();
        shared.status.text = "Kangaroo: stopped";
        return stopped;
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
    const stopped = stopAllSessions();
    shared?.diagnostics.clear();
    return stopped;
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
  const stopped = activeExtension?.deactivate();
  activeExtension = undefined;
  return stopped;
}

module.exports = {
  DaemonClient,
  WorkspaceSession,
  activate,
  createExtension,
  deactivate,
  discoverPackageFolders,
  terminateProcessTree,
};
