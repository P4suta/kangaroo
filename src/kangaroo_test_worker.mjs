import { parentPort, workerData } from "node:worker_threads";
import { pathToFileURL } from "node:url";
import { readFileSync } from "node:fs";
import { format as formatValue } from "node:util";
import { createRequire, syncBuiltinESMExports } from "node:module";
import { execFileSync } from "node:child_process";

const require = createRequire(import.meta.url);
const childProcess = require("node:child_process");
const childProcesses = new Set();
const childPids = new Int32Array(workerData.childPidBuffer);

function registerChild(child) {
  if (!child || typeof child.pid !== "number" || childProcesses.has(child)) {
    return child;
  }
  childProcesses.add(child);
  const index = Atomics.add(childPids, 0, 1) + 1;
  if (index < childPids.length) Atomics.store(childPids, index, child.pid);
  child.once?.("exit", () => childProcesses.delete(child));
  return child;
}

// Patching ChildProcess.prototype also covers runtimes such as Bun which do
// not mirror syncBuiltinESMExports() changes into an already-created named
// `spawn` binding.
const childProcessPrototype = childProcess.ChildProcess?.prototype;
if (childProcessPrototype?.spawn) {
  const originalPrototypeSpawn = childProcessPrototype.spawn;
  childProcessPrototype.spawn = function trackedPrototypeSpawn(...arguments_) {
    const result = originalPrototypeSpawn.apply(this, arguments_);
    registerChild(this);
    return result;
  };
}

for (const name of ["spawn", "exec", "execFile", "fork"]) {
  const original = childProcess[name];
  childProcess[name] = function trackedChildProcess(...arguments_) {
    const child = original.apply(this, arguments_);
    return registerChild(child);
  };
}
syncBuiltinESMExports();

const control = new Int32Array(workerData.controlBuffer);
const data = new Uint8Array(workerData.dataBuffer);
const stdoutData = new Uint8Array(workerData.stdoutBuffer);
const stderrData = new Uint8Array(workerData.stderrBuffer);
const cancellationPoll = setInterval(() => {
  if (Atomics.load(control, 6) === 1) acknowledgeCancellation();
}, 1);
cancellationPoll.unref?.();

console.log = (...values) => writeOutput(stdoutData, 3, formatValue(...values) + "\n");
console.error = (...values) => writeOutput(stderrData, 4, formatValue(...values) + "\n");
console.warn = (...values) => writeOutput(stderrData, 4, formatValue(...values) + "\n");
if (globalThis.process?.stdout?.write) {
  globalThis.process.stdout.write = (chunk, ...rest) => {
    writeOutput(stdoutData, 3, chunkText(chunk));
    callWriteCallback(rest);
    return true;
  };
}
if (globalThis.process?.stderr?.write) {
  globalThis.process.stderr.write = (chunk, ...rest) => {
    writeOutput(stderrData, 4, chunkText(chunk));
    callWriteCallback(rest);
    return true;
  };
}

async function execute() {
  try {
    const url = pathToFileURL(workerData.modulePath).href;
    const module = await import(url);
    const fun = module[workerData.functionName];
    if (typeof fun !== "function" || fun.length !== 0) {
      throw new Error("test export is missing or has arguments");
    }
    signalStarted();
    await fun();
    finish(1, { ok: true });
  } catch (error) {
    if (error && error.kangaroo_skip === true) {
      finish(2, { reason: String(error.reason || "skipped") });
    } else {
      finish(3, serialiseError(error));
    }
  }
}

function serialiseError(error) {
  const variant = error && error.gleam_error;
  const details = structuredDetails(error);
  const source =
    error && error.file && error.line
      ? `at ${String(error.file)}:${Number(error.line)}:1\n`
      : "";
  return {
    name: variant
      ? String(variant)
      : error && error.name
        ? String(error.name)
        : "error",
    message: details.message,
    expected: details.expected,
    actual: details.actual,
    diff: details.diff,
    stack: source + (error && error.stack ? String(error.stack) : ""),
  };
}

function structuredDetails(error) {
  if (error && error.gleam_error === "assert") {
    if (
      error.kind === "binary_operator" &&
      error.left &&
      error.right &&
      "value" in error.left &&
      "value" in error.right
    ) {
      const actualValue = error.left.value;
      const expectedValue = error.right.value;
      return {
        message: withExpression(
          `${inspectValue(actualValue)} ${String(error.operator)} ${inspectValue(expectedValue)}\nAssertion failed`,
          error,
        ),
        expected: inspectValue(expectedValue),
        actual: inspectValue(actualValue),
        diff: valueDiff(expectedValue, actualValue),
      };
    }
    if ("value" in error) {
      return {
        message: withExpression(
          `assert ${inspectValue(error.value)}\nAssertion failed`,
          error,
        ),
      };
    }
  }
  if (error && error.gleam_error === "let_assert" && "value" in error) {
    return {
      message: withExpression(
        `let assert did not match: ${inspectValue(error.value)}`,
        error,
      ),
    };
  }
  return {
    message: error && error.message ? String(error.message) : String(error),
  };
}

function inspectValue(value) {
  if (typeof value === "string") return JSON.stringify(value);
  if (value === null) return "Nil";
  if (value === undefined) return "Nil";
  if (typeof value !== "object") return String(value);
  if (Array.isArray(value)) {
    return `[${value.map(inspectValue).join(", ")}]`;
  }
  if (typeof value[Symbol.iterator] === "function") {
    return `[${Array.from(value, inspectValue).join(", ")}]`;
  }
  const fields = Object.keys(value)
    .filter((key) => /^\d+$/.test(key))
    .sort((left, right) => Number(left) - Number(right))
    .map((key) => inspectValue(value[key]));
  const name = value.constructor && value.constructor.name;
  if (name && name !== "Object") return `${name}(${fields.join(", ")})`;
  try {
    return JSON.stringify(value);
  } catch {
    return String(value);
  }
}

function withExpression(message, error) {
  const expression = sourceExpression(error);
  return expression ? `${message}\nexpression: ${expression}` : message;
}

function sourceExpression(error) {
  try {
    if (
      !error ||
      typeof error.file !== "string" ||
      typeof error.start !== "number" ||
      typeof error.end !== "number"
    ) return "";
    const start =
      typeof error.expression_start === "number"
        ? error.expression_start
        : error.start;
    const source = readFileSync(error.file);
    return source.subarray(start, error.end).toString("utf8").trim();
  } catch {
    return "";
  }
}

function valueDiff(expected, actual) {
  let expectedLines;
  let actualLines;
  if (typeof expected === "string" && typeof actual === "string") {
    expectedLines = expected.split("\n");
    actualLines = actual.split("\n");
  } else if (
    expected && actual &&
    typeof expected[Symbol.iterator] === "function" &&
    typeof actual[Symbol.iterator] === "function"
  ) {
    expectedLines = Array.from(expected, inspectValue);
    actualLines = Array.from(actual, inspectValue);
  } else {
    return undefined;
  }
  if (expectedLines.length < 2 && actualLines.length < 2) return undefined;
  return [
    ...expectedLines.map((line) => `- ${line}`),
    ...actualLines.map((line) => `+ ${line}`),
  ].join("\n");
}

function finish(status, payload) {
  signalStarted();
  clearInterval(cancellationPoll);
  terminateChildProcesses();
  let encoded = new TextEncoder().encode(JSON.stringify(payload));
  if (encoded.length > data.length) {
    encoded = new TextEncoder().encode(
      JSON.stringify({
        name: "error",
        message: "test failure exceeded the worker message limit",
        stack: "",
      }),
    );
    status = 3;
  }
  data.set(encoded);
  Atomics.store(control, 1, status);
  Atomics.store(control, 2, encoded.length);
  Atomics.store(control, 0, 1);
  Atomics.notify(control, 0, 1);
  // Deno's node:worker_threads compatibility object can deliver the shared
  // memory notification without exposing MessagePort.close().
  parentPort?.close?.();
}

function terminateChildProcesses() {
  for (const child of childProcesses) {
    try {
      child.kill("SIGKILL");
    } catch {
      // The process may already have exited.
    }
    terminateProcessTree(child.pid);
  }
  childProcesses.clear();
}

function acknowledgeCancellation() {
  if (Atomics.load(control, 6) === 2) return;
  terminateChildProcesses();
  Atomics.store(control, 6, 2);
  Atomics.notify(control, 6, 1);
}

parentPort?.on?.("message", (message) => {
  if (message?.type !== "cancel") return;
  acknowledgeCancellation();
});

function terminateProcessTree(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return;
  if (globalThis.process.platform === "win32") {
    try {
      globalThis.process.kill(pid, "SIGKILL");
    } catch {
      // The process may already have exited.
    }
    try {
      execFileSync("taskkill", ["/PID", String(pid), "/T", "/F"], {
        stdio: "ignore",
      });
    } catch {
      // The process may already have exited.
    }
    return;
  }
  let descendants = [];
  try {
    globalThis.process.kill(pid, "SIGSTOP");
    descendants = processDescendants(pid);
  } catch {
    // The process may already have exited.
  }
  for (const descendant of descendants.reverse()) {
    try {
      globalThis.process.kill(descendant, "SIGKILL");
    } catch {
      // The process may already have exited.
    }
  }
  try {
    globalThis.process.kill(pid, "SIGKILL");
  } catch {
    // The process may already have exited.
  }
}

function processDescendants(rootPid) {
  const rows = execFileSync("ps", ["-eo", "pid=,ppid="], {
    encoding: "utf8",
  }).trim().split("\n");
  const children = new Map();
  for (const row of rows) {
    const [pidText, parentText] = row.trim().split(/\s+/);
    const pid = Number(pidText);
    const parent = Number(parentText);
    if (!children.has(parent)) children.set(parent, []);
    children.get(parent).push(pid);
  }
  const found = [];
  const pending = [rootPid];
  while (pending.length > 0) {
    const parent = pending.shift();
    for (const child of children.get(parent) || []) {
      found.push(child);
      pending.push(child);
    }
  }
  return found;
}

function signalStarted() {
  if (Atomics.compareExchange(control, 5, 0, 1) === 0) {
    Atomics.notify(control, 5, 1);
  }
}

function writeOutput(target, lengthIndex, value) {
  const encoded = new TextEncoder().encode(value);
  const start = Atomics.load(control, lengthIndex);
  const length = Math.max(0, Math.min(encoded.length, target.length - start));
  if (length === 0) return;
  target.set(encoded.subarray(0, length), start);
  Atomics.store(control, lengthIndex, start + length);
}

function chunkText(chunk) {
  if (typeof chunk === "string") return chunk;
  if (chunk instanceof Uint8Array) return new TextDecoder().decode(chunk);
  return String(chunk);
}

function callWriteCallback(values) {
  const callback = values.find((value) => typeof value === "function");
  if (callback) callback();
}

execute();
