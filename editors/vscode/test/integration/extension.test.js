"use strict";

const assert = require("node:assert/strict");
const vscode = require("vscode");

async function waitFor(description, predicate, timeoutMs = 30_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const value = predicate();
    if (value) return value;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error(`timed out waiting for ${description}`);
}

suite("Kangaroo extension host", () => {
  test("discovers tests and recovers from a daemon crash without stale diagnostics", async () => {
    const extension = vscode.extensions.getExtension("yasunobu.kangaroo");
    assert.ok(extension, "the Kangaroo development extension must be installed");
    const api = await extension.activate();
    assert.equal(api.sessions.size, 1);
    const session = Array.from(api.sessions.values())[0];
    const testId = "test/editor_test.gleam::editor_integration_test";
    const item = await waitFor("Kangaroo test discovery", () =>
      session.items.get(testId));
    assert.equal(item.range.start.line, 2);

    const run = {
      appendOutput() {},
      failed() {},
      passed() {},
      skipped() {},
      started() {},
    };
    session.handleEvent(run, { type: "run_started" });
    session.handleEvent(run, {
      type: "case_finished",
      case: testId,
      duration_ms: 1,
      outcome: {
        kind: "failed",
        failures: [{
          message: "integration failure",
          location: { file: "test/editor_test.gleam", line: 4, column: 3 },
        }],
      },
    });
    session.handleEvent(run, {
      type: "run_finished",
      summary: { passed: 0, failed: 1, skipped: 0, duration_ms: 1 },
    });
    const testUri = vscode.Uri.joinPath(
      vscode.workspace.workspaceFolders[0].uri,
      "test/editor_test.gleam",
    );
    const diagnostics = vscode.languages.getDiagnostics(testUri);
    assert.equal(diagnostics.length, 1);
    assert.equal(diagnostics[0].range.start.line, 3);
    assert.equal(diagnostics[0].range.start.character, 2);

    const crashed = session.client.process;
    const requestNumber = session.requestNumber;
    assert.equal(crashed.kill("SIGKILL"), true);
    await waitFor("daemon restart", () =>
      session.client.process && session.client.process !== crashed);
    await waitFor("daemon rediscovery request", () =>
      session.requestNumber > requestNumber);
    assert.equal(vscode.languages.getDiagnostics(testUri).length, 0);
    assert.ok(session.items.has(testId));

    await vscode.commands.executeCommand("kangaroo.stop");
    assert.equal(api.sessions.size, 0);
  });
});
