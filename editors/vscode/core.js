"use strict";

const PROTOCOL_VERSION = 1;

function targetArguments(target) {
  return target === "erlang" || target === "javascript"
    ? ["--target", target]
    : [];
}

function daemonArguments(target) {
  return ["run", ...targetArguments(target), "-m", "kangaroo", "--", "daemon"];
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

function coverageArguments(selectors = [], target) {
  return [
    "run",
    ...targetArguments(target),
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

class LineDecoder {
  constructor() {
    this.buffer = "";
  }

  push(chunk) {
    this.buffer += String(chunk);
    const lines = this.buffer.split("\n");
    this.buffer = lines.pop();
    return lines.map((line) => line.replace(/\r$/, "")).filter(Boolean);
  }

  remainder() {
    return this.buffer;
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
  parseLcov,
  projectTarget,
  protocolRequest,
  resolveGleamExecutable,
  subprocessEnvironment,
  zeroBasedRange,
};
