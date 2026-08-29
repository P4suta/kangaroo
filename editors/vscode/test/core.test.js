"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const manifest = require("../package.json");
const {
  coverageArguments,
  LineDecoder,
  parseLcov,
  RunState,
  daemonArguments,
  failuresFor,
  protocolRequest,
  resolveGleamExecutable,
  zeroBasedRange,
} = require("../core");

test("requests an LCOV report for exactly the selected stable ids", () => {
  assert.deepEqual(coverageArguments([
    "test/math.gleam::addition_test",
  ]), [
    "run",
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
});

test("reassembles arbitrary NDJSON chunks", () => {
  const decoder = new LineDecoder();
  assert.deepEqual(decoder.push('{"a":1}\n{"b"'), ['{"a":1}']);
  assert.deepEqual(decoder.push(':2}\n'), ['{"b":2}']);
  assert.equal(decoder.remainder(), "");
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
