import { parentPort, workerData } from "node:worker_threads";
import { pathToFileURL } from "node:url";
import { readFileSync } from "node:fs";
import { format as formatValue } from "node:util";
import { createRequire, syncBuiltinESMExports } from "node:module";
import { execFileSync } from "node:child_process";
import { inspect as inspectValue } from "../gleam_stdlib/gleam/string.mjs";
import { collect as collectMatcherFailures } from "./kangaroo_context_ffi.mjs";

const require = createRequire(import.meta.url);
const childProcess = require("node:child_process");
const childProcesses = new Set();
const childPids = new Int32Array(workerData.childPidBuffer);
let nextChildPidIndex = 1;

function registerChild(child) {
  if (!child || childProcesses.has(child)) {
    return child;
  }
  childProcesses.add(child);
  let registeredPid = false;
  let pidIndex = 0;
  let pidValue = 0;
  const registerPid = () => {
    if (registeredPid || typeof child.pid !== "number") return;
    registeredPid = true;
    const index = nextChildPidIndex;
    nextChildPidIndex += 1;
    if (index < childPids.length) {
      pidIndex = index;
      pidValue = child.pid;
      // Publish the PID before the high-water mark. The parent scans one slot
      // beyond that mark, so timeout cannot observe a count whose slot is
      // still empty.
      Atomics.store(childPids, index, pidValue);
      Atomics.store(childPids, 0, index);
    }
    // A short test timeout can expire while a runtime's spawn() call is still
    // blocked. Observe the shared cancellation flag before returning to test
    // code so a newly published process group is stopped immediately instead
    // of waiting for the Worker's event loop to run its cancellation handler.
    if (Atomics.load(control, 6) === 1) {
      terminateProcessTree(pidValue);
    }
  };
  registerPid();
  // Deno's node:child_process compatibility layer can assign the pid only
  // after spawn() returns. Keep the child tracked immediately and publish its
  // pid as soon as the runtime reports that the process started.
  child.once?.("spawn", registerPid);
  child.once?.("exit", () => {
    childProcesses.delete(child);
    if (pidIndex > 0) {
      Atomics.compareExchange(childPids, pidIndex, pidValue, 0);
    }
  });
  return child;
}

// Patching ChildProcess.prototype also covers runtimes such as Bun which do
// not mirror syncBuiltinESMExports() changes into an already-created named
// `spawn` binding.
const childProcessPrototype = childProcess.ChildProcess?.prototype;
if (childProcessPrototype?.spawn) {
  const originalPrototypeSpawn = childProcessPrototype.spawn;
  childProcessPrototype.spawn = function trackedPrototypeSpawn(...arguments_) {
    if (
      globalThis.process.platform !== "win32" &&
      arguments_[0] &&
      typeof arguments_[0] === "object"
    ) {
      // Give every test-owned subprocess its own process group. Timeout and
      // cancellation can then freeze the complete group before a slower OS
      // process-tree snapshot lets a descendant perform late work.
      arguments_[0] = { ...arguments_[0], detached: true };
    }
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
    finish(1, { failures: serialiseMatcherFailures() });
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
    const expressionValue =
      Object.prototype.hasOwnProperty.call(error, "value")
        ? error.value
        : error.expression &&
            Object.prototype.hasOwnProperty.call(error.expression, "value")
          ? error.expression.value
          : undefined;
    if (expressionValue !== undefined) {
      return {
        message: withExpression(
          `assert ${inspectValue(expressionValue)}\nAssertion failed`,
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

function serialiseMatcherFailures() {
  return Array.from(collectMatcherFailures(), (failure) => {
    const type = failure?.constructor?.name;
    if (type === "EqualityMismatch") {
      return {
        type: "equality",
        expected: String(failure.expected),
        actual: String(failure.actual),
        diff: optionValue(failure.diff),
        location: serialiseLocation(failure.location),
      };
    }
    if (type === "AssertionFailed") {
      return {
        type: "assertion",
        message: String(failure.message),
        location: serialiseLocation(failure.location),
      };
    }
    return {
      type: "unexpected",
      name: String(failure?.name || type || "error"),
      message: String(failure?.message || inspectValue(failure)),
      location: serialiseLocation(failure?.location),
    };
  });
}

function optionValue(option) {
  return option && Object.prototype.hasOwnProperty.call(option, "0")
    ? option[0]
    : null;
}

function serialiseLocation(option) {
  const location = optionValue(option);
  if (!location) return null;
  return {
    file: String(location.file),
    line: Number(location.line),
    column: optionValue(location.column),
  };
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
    // Freeze and enumerate the tree before terminating its registered root.
    // Killing the root first can reparent descendants and make them invisible
    // to the subsequent process-tree walk on Deno and other Unix runtimes.
    terminateProcessTree(child.pid);
    try {
      child.kill("SIGKILL");
    } catch {
      // The process may already have exited.
    }
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
    try {
      globalThis.process.kill(-pid, "SIGSTOP");
    } catch {
      globalThis.process.kill(pid, "SIGSTOP");
    }
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
    try {
      globalThis.process.kill(-pid, "SIGKILL");
    } catch {
      globalThis.process.kill(pid, "SIGKILL");
    }
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
