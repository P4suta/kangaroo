"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const manifest = require("../package.json");
const {
  coverageArguments,
  LineDecoder,
  parseLcov,
  projectTarget,
  protocolResponse,
  RunState,
  daemonArguments,
  failuresFor,
  javascriptRuntime,
  protocolRequest,
  resolveGleamExecutable,
  subprocessEnvironment,
  zeroBasedRange,
} = require("../core");

test("validates daemon responses against every protocol-v1 record shape", () => {
  const records = [
    {
      protocol_version: 1,
      type: "discovered",
      request_id: "discover-1",
      tests: [{
        id: "test/math.gleam::addition_test",
        name: "addition_test",
        path: "test/math.gleam",
        module: "math",
        line: 1,
        column: 1,
        end_line: 2,
        end_column: 2,
        tags: ["unit"],
        timeout_ms: null,
        serial: false,
      }],
    },
    {
      protocol_version: 1,
      type: "started",
      request_id: "run-1",
      operation_id: "run-1",
      operation: "run",
    },
    {
      protocol_version: 1,
      type: "event",
      request_id: "run-1",
      event: { type: "run_started", run_id: 1, case_count: 1 },
    },
    {
      protocol_version: 1,
      type: "event",
      request_id: "run-1",
      event: {
        type: "case_output",
        suite: "math",
        case: "test/math.gleam::addition_test",
        stdout: "",
        stderr: "",
        outcome: {
          kind: "failed",
          failures: [{
            kind: "equality_mismatch",
            expected: "1",
            actual: "2",
            diff: null,
            location: { file: "test/math.gleam", line: 1, column: null },
          }],
        },
      },
    },
    {
      protocol_version: 1,
      type: "event",
      request_id: "run-1",
      event: {
        type: "case_finished",
        suite: "math",
        case: "test/math.gleam::addition_test",
        outcome: {
          kind: "flaky",
          attempts: 2,
          failures: [{
            kind: "assertion_failed",
            message: "not equal",
            location: null,
          }],
        },
        duration_ms: 1,
      },
    },
    {
      protocol_version: 1,
      type: "event",
      request_id: "run-1",
      event: {
        type: "suite_finished",
        suite: "math",
        outcome: {
          kind: "failed",
          failures: [{
            kind: "unexpected_error",
            name: "panic",
            message: "boom",
            location: null,
          }],
        },
      },
    },
    {
      protocol_version: 1,
      type: "event",
      request_id: "run-1",
      event: {
        type: "run_finished",
        run_id: 1,
        summary: { passed: 1, failed: 0, skipped: 0, duration_ms: 1 },
      },
    },
    {
      protocol_version: 1,
      type: "completed",
      request_id: "run-1",
      exit_code: 0,
    },
    {
      protocol_version: 1,
      type: "cancelled",
      request_id: "cancel-1",
      operation_id: "watch-1",
    },
    {
      protocol_version: 1,
      type: "error",
      request_id: "bad-1",
      message: "bad request",
    },
    { protocol_version: 1, type: "shutdown", request_id: "shutdown-1" },
  ];
  assert.ok(records.every(protocolResponse));
});

test("rejects records outside the protocol-v1 response schema", () => {
  const invalid = [
    null,
    [],
    { protocol_version: 1, type: "unknown", request_id: "x" },
    {
      protocol_version: 1,
      type: "discovered",
      request_id: "x",
      tests: "not-an-array",
    },
    {
      protocol_version: 1,
      type: "completed",
      request_id: "x",
      exit_code: 3,
    },
    {
      protocol_version: 1,
      type: "event",
      request_id: "x",
      event: {
        type: "run_finished",
        run_id: 1,
        summary: { passed: -1, failed: 0, skipped: 0, duration_ms: 1 },
      },
    },
    {
      protocol_version: 1,
      type: "shutdown",
      request_id: "x",
      extra: true,
    },
  ];
  assert.ok(invalid.every((record) => !protocolResponse(record)));
});

test("requests an LCOV report for exactly the selected stable ids", () => {
  assert.deepEqual(coverageArguments(
    ["test/math.gleam::addition_test"],
    "javascript",
    "bun",
  ), [
    "run",
    "--target",
    "javascript",
    "--runtime",
    "bun",
    "-m",
    "kangaroo",
    "--",
    "coverage",
    "test/math.gleam::addition_test",
    "--reporter",
    "ndjson",
    "--coverage-reporter",
    "lcov",
  ]);
});

test("parses LCOV into normalised one-based Gleam line details", () => {
  assert.deepEqual(parseLcov([
    "TN:",
    "SF:src/math.gleam",
    "DA:2,3",
    "DA:7,0",
    "LF:2",
    "LH:1",
    "end_of_record",
    "",
  ].join("\n")), [{
    path: "src/math.gleam",
    covered: 1,
    total: 2,
    lines: [{ line: 2, hits: 3 }, { line: 7, hits: 0 }],
  }]);
});

test("normalises Windows LCOV paths", () => {
  assert.equal(
    parseLcov("SF:src\\math.gleam\nDA:1,1\nend_of_record\n")[0].path,
    "src/math.gleam",
  );
});

test("starts the unified protocol-v1 daemon", () => {
  assert.deepEqual(daemonArguments(), [
    "run",
    "-m",
    "kangaroo",
    "--",
    "daemon",
  ]);
  assert.deepEqual(protocolRequest("req-1", "discover"), {
    protocol_version: 1,
    id: "req-1",
    command: "discover",
  });
  assert.deepEqual(daemonArguments("javascript"), [
    "run",
    "--target",
    "javascript",
    "--runtime",
    "nodejs",
    "-m",
    "kangaroo",
    "--",
    "daemon",
  ]);
  assert.deepEqual(daemonArguments("javascript", "deno"), [
    "run",
    "--target",
    "javascript",
    "--runtime",
    "deno",
    "-m",
    "kangaroo",
    "--",
    "daemon",
  ]);
  assert.equal(javascriptRuntime("not-a-runtime"), "nodejs");
});

test("reads only the top-level Gleam project target", () => {
  assert.equal(projectTarget([
    'name = "demo"',
    'target = "javascript" # run without Erlang',
    "",
    "[tools.kangaroo]",
  ].join("\n")), "javascript");
  assert.equal(projectTarget([
    'name = "demo"',
    "",
    "[javascript]",
    'target = "javascript"',
  ].join("\n")), undefined);
  assert.equal(projectTarget('name = "demo"\n'), undefined);
});

test("resolves the Gleam executable without overriding explicit settings", () => {
  assert.equal(
    resolveGleamExecutable("/tools/custom-gleam", {
      KANGAROO_GLEAM_PATH: "/ci/gleam",
    }),
    "/tools/custom-gleam",
  );
  assert.equal(
    resolveGleamExecutable("gleam", {
      KANGAROO_GLEAM_PATH: "/ci/gleam",
    }),
    "/ci/gleam",
  );
  assert.equal(resolveGleamExecutable("gleam", {}), "gleam");
});

test("Gleam executable configuration is scoped to each package resource", () => {
  assert.equal(
    manifest.contributes.configuration.properties["kangaroo.gleamPath"].scope,
    "resource",
  );
  const runtime = manifest.contributes.configuration.properties[
    "kangaroo.javascriptRuntime"
  ];
  assert.equal(runtime.scope, "resource");
  assert.deepEqual(runtime.enum, ["nodejs", "bun", "deno"]);
  assert.equal(runtime.default, "nodejs");
});

test("nested Gleam packages activate the extension before a file is opened", () => {
  assert.ok(manifest.activationEvents.includes("workspaceContains:**/gleam.toml"));
});

test("workspace execution requires trust and a filesystem-backed package", () => {
  assert.equal(manifest.capabilities.untrustedWorkspaces.supported, false);
  assert.equal(manifest.capabilities.virtualWorkspaces.supported, false);
});

test("restores the launcher tool PATH for extension subprocesses", () => {
  const source = {
    PATH: "/login-shell/bin",
    KANGAROO_VSCODE_TOOL_PATH: "/setup-gleam/bin:/setup-node/bin",
    KEEP: "value",
  };
  assert.deepEqual(subprocessEnvironment(source), {
    PATH: "/setup-gleam/bin:/setup-node/bin",
    KANGAROO_VSCODE_TOOL_PATH: "/setup-gleam/bin:/setup-node/bin",
    KEEP: "value",
  });
  assert.equal(source.PATH, "/login-shell/bin");
  assert.deepEqual(subprocessEnvironment({ PATH: "/normal/bin" }), {
    PATH: "/normal/bin",
  });
  assert.deepEqual(subprocessEnvironment({
    Path: "C:\\login-shell",
    KANGAROO_VSCODE_TOOL_PATH: "C:\\setup-gleam;C:\\setup-node",
  }, "win32"), {
    Path: "C:\\setup-gleam;C:\\setup-node",
    KANGAROO_VSCODE_TOOL_PATH: "C:\\setup-gleam;C:\\setup-node",
  });
});

test("reassembles arbitrary NDJSON chunks", () => {
  const decoder = new LineDecoder();
  assert.deepEqual(decoder.push('{"a":1}\n{"b"'), ['{"a":1}']);
  assert.deepEqual(decoder.push(':2}\n'), ['{"b":2}']);
  assert.equal(decoder.remainder(), "");
});

test("bounds an unterminated protocol line without quadratic concatenation", () => {
  const decoder = new LineDecoder(8);
  assert.deepEqual(decoder.push("12"), []);
  assert.deepEqual(decoder.push("34"), []);
  assert.equal(decoder.remainder(), "1234");
  assert.throws(() => decoder.push("56789"), /exceeded 8 bytes/);
});

test("converts protocol ranges from one-based to zero-based", () => {
  assert.deepEqual(zeroBasedRange({
    line: 7,
    column: 3,
    end_line: 9,
    end_column: 2,
  }), {
    start: { line: 6, column: 2 },
    end: { line: 8, column: 1 },
  });
});

test("extracts failed and flaky diagnostics", () => {
  const event = {
    type: "case_finished",
    case: "test/math.gleam::addition_test",
    outcome: {
      kind: "flaky",
      failures: [{
        kind: "assertion_failed",
        message: "1 was not 2",
        location: { file: "test/math.gleam", line: 4, column: 1 },
      }],
    },
  };
  assert.deepEqual(failuresFor(event), [{
    testId: "test/math.gleam::addition_test",
    file: "test/math.gleam",
    line: 3,
    column: 0,
    message: "1 was not 2",
  }]);
});

test("a new run completely removes stale diagnostics", () => {
  const state = new RunState();
  state.record("old", [{ file: "test/old.gleam" }]);
  assert.equal(state.diagnostics().length, 1);
  state.beginRun();
  assert.deepEqual(state.diagnostics(), []);
});
