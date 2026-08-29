// Kangaroo for VS Code: runs `kangaroo_cli watch --json` and surfaces
// test failures as diagnostics (the Problems panel) with a status bar
// summary.
"use strict";

const vscode = require("vscode");
const { spawn } = require("child_process");

/** @type {import("child_process").ChildProcess | null} */
let child = null;

/** @type {Map<string, vscode.Diagnostic[]>} */
let failuresByFile = new Map();

const diagnosticCollection =
  vscode.languages.createDiagnosticCollection("kangaroo");

/** @type {vscode.StatusBarItem} */
let statusBar;

function deactivate() {
  stop();
}

function stop() {
  if (child) {
    child.kill();
    child = null;
  }
  failuresByFile.clear();
  diagnosticCollection.clear();
  if (statusBar) statusBar.text = "kangaroo: stopped";
}

/** Parses one protocol line into a diagnostics entry list. */
function failuresFor(event) {
  const outcome = event.outcome;
  if (!outcome || outcome.kind !== "failed") return [];
  const entries = [];
  for (const failure of outcome.failures || []) {
    const location = failure.location;
    if (!location || !location.file) continue;
    entries.push({
      file: location.file,
      line: (location.line || 1) - 1,
      column: (location.column || 1) - 1,
      message:
        failure.message ||
        `expected: ${failure.expected}, actual: ${failure.actual}`,
    });
  }
  return entries;
}

function rebuildDiagnostics() {
  const perFile = new Map();
  for (const entry of failuresByFile.values()) {
    for (const failure of entry) {
      if (!perFile.has(failure.file)) perFile.set(failure.file, []);
      perFile.get(failure.file).push(
        new vscode.Diagnostic(
          new vscode.Range(failure.line, failure.column, failure.line, failure.column + 1),
          failure.message,
          vscode.DiagnosticSeverity.Error
        )
      );
    }
  }
  const entries = [];
  for (const [file, diagnostics] of perFile) {
    const uri = vscode.Uri.file(vscode.workspace.rootPath + "/" + file);
    diagnosticCollection.set(uri, diagnostics);
    entries.push([uri, diagnostics]);
  }
  return entries;
}

function handle(event) {
  if (event.type === "run_started") {
    failuresByFile.clear();
  } else if (event.type === "case_finished") {
    const entries = failuresFor(event);
    if (entries.length > 0) failuresByFile.set(event.suite + "/" + event.case, entries);
  } else if (event.type === "run_finished") {
    rebuildDiagnostics();
    const s = event.summary;
    const color = s.failed > 0 ? "$(error)" : "$(check)";
    statusBar.text = `kangaroo: ${color} ${s.passed} passed, ${s.failed} failed, ${s.skipped} skipped`;
    statusBar.show();
  }
}

function start() {
  if (child) return;
  const cwd = vscode.workspace.rootPath;
  if (!cwd) {
    vscode.window.showErrorMessage("kangaroo: no workspace folder open");
    return;
  }
  const gleam = vscode.workspace.getConfiguration("kangaroo").get("gleamPath", "gleam");
  child = spawn(gleam, ["run", "-m", "kangaroo_cli", "--", "watch", "--json"], {
    cwd,
  });

  let buffer = "";
  child.stdout.on("data", (chunk) => {
    buffer += chunk.toString();
    let index;
    while ((index = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, index).trim();
      buffer = buffer.slice(index + 1);
      if (!line) continue;
      try {
        handle(JSON.parse(line));
      } catch {
        // not a protocol line
      }
    }
  });

  child.on("exit", () => {
    child = null;
    statusBar.text = "kangaroo: stopped";
  });
}

function activate(context) {
  statusBar = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left);
  statusBar.text = "kangaroo: idle";
  context.subscriptions.push(statusBar);

  context.subscriptions.push(
    vscode.commands.registerCommand("kangaroo.start", start),
    vscode.commands.registerCommand("kangaroo.stop", stop),
    vscode.workspace.onDidCloseTextDocument((document) => {
      diagnosticCollection.delete(document.uri);
    })
  );

  const watcher = vscode.workspace.createFileSystemWatcher("**/*.gleam");
  context.subscriptions.push(watcher);
}

module.exports = { activate, deactivate };
