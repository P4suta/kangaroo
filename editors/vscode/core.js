"use strict";

const PROTOCOL_VERSION = 1;

function targetArguments(target) {
  return target === "erlang" || target === "javascript"
    ? ["--target", target]
    : [];
}

function javascriptRuntime(runtime) {
  return ["nodejs", "bun", "deno"].includes(runtime) ? runtime : "nodejs";
}

function runtimeArguments(target, runtime) {
  return target === "javascript"
    ? ["--runtime", javascriptRuntime(runtime)]
    : [];
}

function daemonArguments(target, runtime) {
  return [
    "run",
    ...targetArguments(target),
    ...runtimeArguments(target, runtime),
    "-m",
    "kangaroo",
    "--",
    "daemon",
  ];
}

function resolveGleamExecutable(configured, environment = process.env) {
  if (configured !== "gleam") return configured;
  const injected = environment.KANGAROO_GLEAM_PATH;
  return typeof injected === "string" && injected.length > 0
    ? injected
    : configured;
}

function subprocessEnvironment(
  environment = process.env,
  platform = process.platform,
) {
  const inherited = { ...environment };
  const toolPath = environment.KANGAROO_VSCODE_TOOL_PATH;
  if (typeof toolPath === "string" && toolPath.length > 0) {
    const pathKey = platform === "win32"
      ? Object.keys(inherited).find((key) => key.toLowerCase() === "path") || "Path"
      : "PATH";
    for (const key of Object.keys(inherited)) {
      if (key !== pathKey && key.toLowerCase() === "path") delete inherited[key];
    }
    inherited[pathKey] = toolPath;
  }
  return inherited;
}

function coverageArguments(selectors = [], target, runtime) {
  return [
    "run",
    ...targetArguments(target),
    ...runtimeArguments(target, runtime),
    "-m",
    "kangaroo",
    "--",
    "coverage",
    ...selectors,
    "--reporter",
    "ndjson",
    "--coverage-reporter",
    "lcov",
  ];
}

function projectTarget(contents) {
  for (const rawLine of String(contents).split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    if (line.startsWith("[")) break;
    const match = line.match(
      /^target\s*=\s*(["'])(erlang|javascript)\1(?:\s*#.*)?$/,
    );
    if (match) return match[2];
  }
  return undefined;
}

function parseLcov(contents) {
  const files = [];
  let path;
  let lines = [];
  const finish = () => {
    if (!path) return;
    const normalised = Array.from(
      new Map(lines.map((line) => [line.line, line])).values(),
    ).sort((left, right) => left.line - right.line);
    files.push({
      path: path.replaceAll("\\", "/"),
      covered: normalised.filter((line) => line.hits > 0).length,
      total: normalised.length,
      lines: normalised,
    });
    path = undefined;
    lines = [];
  };
  for (const raw of String(contents).split(/\r?\n/)) {
    if (raw.startsWith("SF:")) {
      finish();
      path = raw.slice(3);
    } else if (raw.startsWith("DA:") && path) {
      const [line, hits] = raw.slice(3).split(",", 2).map(Number);
      if (Number.isInteger(line) && line > 0 && Number.isFinite(hits)) {
        lines.push({ line, hits });
      }
    } else if (raw === "end_of_record") {
      finish();
    }
  }
  finish();
  return files;
}

function protocolRequest(id, command, fields = {}) {
  return { protocol_version: PROTOCOL_VERSION, id, command, ...fields };
}

function objectRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function exactFields(value, required, optional = []) {
  if (!objectRecord(value)) return false;
  const allowed = new Set([...required, ...optional]);
  return required.every((field) => Object.hasOwn(value, field)) &&
    Object.keys(value).every((field) => allowed.has(field));
}

function integerAtLeast(value, minimum) {
  return Number.isInteger(value) && value >= minimum;
}

function protocolLocation(value) {
  return exactFields(value, ["file", "line", "column"]) &&
    typeof value.file === "string" &&
    integerAtLeast(value.line, 1) &&
    (value.column === null || integerAtLeast(value.column, 1));
}

function nullableLocation(value) {
  return value === null || protocolLocation(value);
}

function protocolFailure(value) {
  if (!objectRecord(value) || typeof value.kind !== "string") return false;
  if (value.kind === "equality_mismatch") {
    return exactFields(
      value,
      ["kind", "expected", "actual", "diff", "location"],
    ) && typeof value.expected === "string" &&
      typeof value.actual === "string" &&
      (value.diff === null || typeof value.diff === "string") &&
      nullableLocation(value.location);
  }
  if (value.kind === "assertion_failed") {
    return exactFields(value, ["kind", "message", "location"]) &&
      typeof value.message === "string" && nullableLocation(value.location);
  }
  if (value.kind === "unexpected_error") {
    return exactFields(value, ["kind", "name", "message", "location"]) &&
      typeof value.name === "string" && typeof value.message === "string" &&
      nullableLocation(value.location);
  }
  return false;
}

function protocolFailures(value) {
  return Array.isArray(value) && value.every(protocolFailure);
}

function protocolOutcome(value) {
  if (!objectRecord(value) || typeof value.kind !== "string") return false;
  if (value.kind === "passed") return exactFields(value, ["kind"]);
  if (value.kind === "skipped") {
    return exactFields(value, ["kind"], ["reason"]) &&
      (value.reason === undefined || typeof value.reason === "string");
  }
  if (value.kind === "flaky") {
    return exactFields(value, ["kind", "attempts", "failures"]) &&
      integerAtLeast(value.attempts, 2) && protocolFailures(value.failures);
  }
  if (value.kind === "failed") {
    return exactFields(value, ["kind", "failures"]) &&
      protocolFailures(value.failures);
  }
  return false;
}

function protocolSummary(value) {
  return exactFields(
    value,
    ["passed", "failed", "skipped", "duration_ms"],
  ) && integerAtLeast(value.passed, 0) &&
    integerAtLeast(value.failed, 0) &&
    integerAtLeast(value.skipped, 0) &&
    integerAtLeast(value.duration_ms, 0);
}

function protocolEvent(value) {
  if (!objectRecord(value) || typeof value.type !== "string") return false;
  if (value.type === "run_started") {
    return exactFields(value, ["type", "run_id", "case_count"]) &&
      Number.isInteger(value.run_id) && integerAtLeast(value.case_count, 0);
  }
  if (value.type === "case_started") {
    return exactFields(value, ["type", "suite", "case"]) &&
      typeof value.suite === "string" && typeof value.case === "string";
  }
  if (value.type === "case_output") {
    return exactFields(
      value,
      ["type", "suite", "case", "stdout", "stderr", "outcome"],
    ) && typeof value.suite === "string" &&
      typeof value.case === "string" && typeof value.stdout === "string" &&
      typeof value.stderr === "string" && protocolOutcome(value.outcome);
  }
  if (value.type === "case_finished") {
    return exactFields(
      value,
      ["type", "suite", "case", "outcome", "duration_ms"],
    ) && typeof value.suite === "string" &&
      typeof value.case === "string" && protocolOutcome(value.outcome) &&
      integerAtLeast(value.duration_ms, 0);
  }
  if (value.type === "suite_started") {
    return exactFields(value, ["type", "suite"]) &&
      typeof value.suite === "string";
  }
  if (value.type === "suite_finished") {
    return exactFields(value, ["type", "suite", "outcome"]) &&
      typeof value.suite === "string" && protocolOutcome(value.outcome);
  }
  if (value.type === "run_finished") {
    return exactFields(value, ["type", "run_id", "summary"]) &&
      Number.isInteger(value.run_id) && protocolSummary(value.summary);
  }
  return false;
}

function protocolTest(value) {
  const fields = [
    "id",
    "name",
    "path",
    "module",
    "line",
    "column",
    "end_line",
    "end_column",
    "tags",
    "timeout_ms",
    "serial",
  ];
  return exactFields(value, fields) &&
    [value.id, value.name, value.path, value.module].every(
      (field) => typeof field === "string",
    ) &&
    [value.line, value.column, value.end_line, value.end_column].every(
      (field) => integerAtLeast(field, 1),
    ) &&
    Array.isArray(value.tags) &&
    value.tags.every((tag) => typeof tag === "string" && /\S/.test(tag)) &&
    (value.timeout_ms === null || integerAtLeast(value.timeout_ms, 1)) &&
    typeof value.serial === "boolean";
}

function protocolResponse(value) {
  if (!objectRecord(value) || value.protocol_version !== PROTOCOL_VERSION ||
    typeof value.type !== "string") return false;
  if (value.type === "discovered") {
    return exactFields(
      value,
      ["protocol_version", "type", "request_id", "tests"],
    ) && typeof value.request_id === "string" && Array.isArray(value.tests) &&
      value.tests.every(protocolTest);
  }
  if (value.type === "started") {
    return exactFields(
      value,
      [
        "protocol_version",
        "type",
        "request_id",
        "operation_id",
        "operation",
      ],
    ) && typeof value.request_id === "string" &&
      typeof value.operation_id === "string" &&
      ["run", "watch"].includes(value.operation);
  }
  if (value.type === "event") {
    return exactFields(
      value,
      ["protocol_version", "type", "request_id", "event"],
    ) && typeof value.request_id === "string" && protocolEvent(value.event);
  }
  if (value.type === "completed") {
    return exactFields(
      value,
      ["protocol_version", "type", "request_id", "exit_code"],
    ) && typeof value.request_id === "string" &&
      integerAtLeast(value.exit_code, 0) && value.exit_code <= 2;
  }
  if (value.type === "cancelled") {
    return exactFields(
      value,
      ["protocol_version", "type", "request_id", "operation_id"],
    ) && typeof value.request_id === "string" &&
      typeof value.operation_id === "string";
  }
  if (value.type === "shutdown") {
    return exactFields(
      value,
      ["protocol_version", "type", "request_id"],
    ) && typeof value.request_id === "string";
  }
  if (value.type === "error") {
    return exactFields(
      value,
      ["protocol_version", "type", "request_id", "message"],
    ) && typeof value.request_id === "string" &&
      typeof value.message === "string";
  }
  return false;
}

class LineDecoder {
  constructor(maxLineBytes = 128 * 1024 * 1024) {
    this.maxLineBytes = Math.max(1, Number(maxLineBytes));
    this.fragments = [];
    this.bytes = 0;
  }

  push(chunk) {
    const value = String(chunk);
    const lines = [];
    let start = 0;
    while (true) {
      const newline = value.indexOf("\n", start);
      if (newline < 0) break;
      this.append(value.slice(start, newline));
      const line = this.fragments.join("").replace(/\r$/, "");
      this.fragments = [];
      this.bytes = 0;
      if (line) lines.push(line);
      start = newline + 1;
    }
    this.append(value.slice(start));
    return lines;
  }

  remainder() {
    return this.fragments.join("");
  }

  append(fragment) {
    if (!fragment) return;
    this.bytes += Buffer.byteLength(fragment, "utf8");
    if (this.bytes > this.maxLineBytes) {
      throw new Error(
        `daemon protocol line exceeded ${this.maxLineBytes} bytes`,
      );
    }
    this.fragments.push(fragment);
  }
}

function oneBased(value) {
  return Math.max(0, Number(value || 1) - 1);
}

function zeroBasedRange(location) {
  return {
    start: {
      line: oneBased(location.line),
      column: oneBased(location.column),
    },
    end: {
      line: oneBased(location.end_line || location.line),
      column: oneBased(location.end_column || location.column),
    },
  };
}

function failureMessage(failure) {
  if (failure.message) return String(failure.message);
  if (failure.expected !== undefined || failure.actual !== undefined) {
    return `expected: ${failure.expected ?? "?"}, actual: ${failure.actual ?? "?"}`;
  }
  return failure.name ? `${failure.name}: test failed` : "test failed";
}

function failuresFor(event) {
  const outcome = event && event.outcome;
  if (!outcome || (outcome.kind !== "failed" && outcome.kind !== "flaky")) {
    return [];
  }
  const entries = [];
  for (const failure of outcome.failures || []) {
    const location = failure.location;
    if (!location || !location.file) continue;
    entries.push({
      testId: event.case,
      file: location.file,
      line: oneBased(location.line),
      column: oneBased(location.column),
      message: failureMessage(failure),
    });
  }
  return entries;
}

class RunState {
  constructor() {
    this.byTest = new Map();
  }

  beginRun() {
    this.byTest.clear();
  }

  record(testId, diagnostics) {
    if (diagnostics.length > 0) this.byTest.set(testId, diagnostics);
    else this.byTest.delete(testId);
  }

  diagnostics() {
    return Array.from(this.byTest.values()).flat();
  }
}

module.exports = {
  coverageArguments,
  LineDecoder,
  PROTOCOL_VERSION,
  RunState,
  daemonArguments,
  failuresFor,
  javascriptRuntime,
  parseLcov,
  projectTarget,
  protocolRequest,
  protocolResponse,
  resolveGleamExecutable,
  subprocessEnvironment,
  zeroBasedRange,
};
