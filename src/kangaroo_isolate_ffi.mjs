// Runs a test case body in isolation, catching any error it raises and
// reporting the matcher failures it recorded. The previous failure context
// is saved and restored so that nested runs (cases that themselves run
// cases) stay isolated from each other.
import {
  CapturedIsolation,
  CaughtError,
  Completed,
  Crashed,
  SkippedIsolation,
} from "./kangaroo/isolate.mjs";
import {
  AssertionFailed,
  EqualityMismatch,
  UnexpectedError,
} from "./kangaroo/failure.mjs";
import { Location, from_js_stack } from "./kangaroo/location.mjs";
import { collect, restore, save } from "./kangaroo_context_ffi.mjs";
import { Worker } from "node:worker_threads";
import { format as formatValue } from "node:util";
import { execFileSync } from "node:child_process";
import { toList } from "./gleam.mjs";
import {
  Option$None$const,
  Some,
} from "../gleam_stdlib/gleam/option.mjs";

const workerUrl = new URL("./kangaroo_test_worker.mjs", import.meta.url);
const workerBufferBytes = 1024 * 1024;
const childPidCapacity = 4096;

export function isolate_captured(body, timeout_ms) {
  if (body && body.kangarooModulePath && body.kangarooFunctionName) {
    return isolateWorker(body, timeout_ms);
  }
  const output = captureOutput();
  const previous = save();
  let result;
  try {
    body();
    result = new Completed(collect());
  } catch (error) {
    if (error && error.kangaroo_skip === true) {
      result = new SkippedIsolation(String(error.reason || "skipped"));
    } else {
      const name =
        error && error.gleam_error === "panic"
          ? "panic"
          : error && error.name
            ? String(error.name)
            : "error";
      const message =
        error && error.message ? String(error.message) : String(error);
      const stack = error && error.stack ? String(error.stack) : "";
      result = new Crashed(
        new CaughtError(
          name,
          message,
          from_js_stack(stack),
          Option$None$const,
          Option$None$const,
          Option$None$const,
        ),
      );
    }
  } finally {
    restore(previous);
    output.restore();
  }
  return new CapturedIsolation(result, output.stdout(), output.stderr());
}

function isolateWorker(body, timeoutOption) {
  const timeoutMs =
    timeoutOption && typeof timeoutOption[0] === "number"
      ? timeoutOption[0]
      : 30_000;
  const controlBuffer = new SharedArrayBuffer(Int32Array.BYTES_PER_ELEMENT * 7);
  const dataBuffer = new SharedArrayBuffer(workerBufferBytes);
  const stdoutBuffer = new SharedArrayBuffer(workerBufferBytes);
  const stderrBuffer = new SharedArrayBuffer(workerBufferBytes);
  const childPidBuffer = new SharedArrayBuffer(
    Int32Array.BYTES_PER_ELEMENT * (childPidCapacity + 1),
  );
  const control = new Int32Array(controlBuffer);
  const data = new Uint8Array(dataBuffer);
  const stdoutData = new Uint8Array(stdoutBuffer);
  const stderrData = new Uint8Array(stderrBuffer);
  const childPids = new Int32Array(childPidBuffer);
  const worker = new Worker(workerUrl, {
    workerData: {
      modulePath: body.kangarooModulePath,
      functionName: body.kangarooFunctionName,
      controlBuffer,
      dataBuffer,
      stdoutBuffer,
      stderrBuffer,
      childPidBuffer,
    },
  });

  const startupWait = Atomics.wait(control, 5, 0, 30_000);
  if (startupWait === "timed-out") {
    terminateRegisteredChildren(childPids, true);
    void worker.terminate();
    return new CapturedIsolation(
      new Crashed(
        new CaughtError(
          "infrastructure",
          "JavaScript test worker did not start within 30000 ms",
          from_js_stack(""),
          Option$None$const,
          Option$None$const,
          Option$None$const,
        ),
      ),
      sharedOutput(control, 3, stdoutData),
      sharedOutput(control, 4, stderrData),
    );
  }
  const wait = Atomics.load(control, 0) === 1
    ? "ok"
    : Atomics.wait(control, 0, 0, timeoutMs);
  if (wait === "timed-out") {
    const stdout = sharedOutput(control, 3, stdoutData);
    const stderr = sharedOutput(control, 4, stderrData);
    requestWorkerCancellation(worker, control, () => {
      terminateRegisteredChildren(childPids);
    });
    terminateRegisteredChildren(childPids, true);
    void worker.terminate();
    return new CapturedIsolation(
      new Crashed(
        new CaughtError(
          "timeout",
          `Test case timed out after ${timeoutMs} ms`,
          from_js_stack(""),
          Option$None$const,
          Option$None$const,
          Option$None$const,
        ),
      ),
      stdout,
      stderr,
    );
  }

  const status = Atomics.load(control, 1);
  const length = Atomics.load(control, 2);
  const payload = JSON.parse(
    new TextDecoder().decode(data.subarray(0, Math.max(0, length))),
  );
  terminateRegisteredChildren(childPids);
  void worker.terminate();

  let result;
  if (status === 1) {
    result = new Completed(deserialiseFailures(payload.failures));
  } else if (status === 2) {
    result = new SkippedIsolation(payload.reason || "skipped");
  } else {
    result = new Crashed(
      new CaughtError(
        payload.name || "error",
        payload.message || "JavaScript test failed",
        from_js_stack(payload.stack || ""),
        optional(payload.expected),
        optional(payload.actual),
        optional(payload.diff),
      ),
    );
  }
  return new CapturedIsolation(
    result,
    sharedOutput(control, 3, stdoutData),
    sharedOutput(control, 4, stderrData),
  );
}

function deserialiseFailures(failures) {
  if (!Array.isArray(failures)) return toList([]);
  return toList(failures.map((failure) => {
    const location = deserialiseLocation(failure.location);
    if (failure.type === "equality") {
      return new EqualityMismatch(
        String(failure.expected),
        String(failure.actual),
        optional(failure.diff),
        location,
      );
    }
    if (failure.type === "assertion") {
      return new AssertionFailed(String(failure.message), location);
    }
    return new UnexpectedError(
      String(failure.name || "error"),
      String(failure.message || "test failed"),
      location,
    );
  }));
}

function deserialiseLocation(location) {
  if (!location || typeof location.file !== "string") return Option$None$const;
  return new Some(new Location(
    location.file,
    Number(location.line),
    typeof location.column === "number"
      ? new Some(location.column)
      : Option$None$const,
  ));
}

function requestWorkerCancellation(worker, control, onRequested) {
  try {
    Atomics.store(control, 6, 1);
    Atomics.notify(control, 6, 1);
    worker.postMessage({ type: "cancel" });
    onRequested();
    Atomics.wait(control, 6, 1, 250);
  } catch {
    // A worker which already exited needs no cooperative cleanup.
  }
}

function terminateRegisteredChildren(registry, awaitPublication = false) {
  scanRegisteredChildren(registry);
  if (awaitPublication) {
    const highWater = Atomics.load(registry, 0);
    Atomics.wait(registry, 0, highWater, 1);
    scanRegisteredChildren(registry);
  }
}

function scanRegisteredChildren(registry) {
  const highWater = Math.max(
    1,
    Math.min(Atomics.load(registry, 0) + 1, registry.length - 1),
  );
  for (let index = 1; index <= highWater; index += 1) {
    const pid = Atomics.exchange(registry, index, 0);
    terminateProcessTree(pid);
  }
}

function terminateProcessTree(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return;
  if (globalThis.process.platform === "win32") {
    // Terminate the directly registered child through the native process API
    // first. Starting taskkill can take long enough on a busy Windows host
    // for a short-lived child to perform work before the tree walk begins.
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
  let output;
  try {
    if (globalThis.process.platform === "win32") {
      output = execFileSync(
        "powershell.exe",
        [
          "-NoProfile",
          "-Command",
          "Get-CimInstance Win32_Process | ForEach-Object { \"$($_.ProcessId) $($_.ParentProcessId)\" }",
        ],
        { encoding: "utf8", windowsHide: true },
      );
    } else {
      output = execFileSync("ps", ["-eo", "pid=,ppid="], {
        encoding: "utf8",
      });
    }
  } catch {
    return [];
  }
  const children = new Map();
  for (const row of output.trim().split("\n")) {
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

function sharedOutput(control, index, data) {
  const length = Math.max(0, Math.min(Atomics.load(control, index), data.length));
  return new TextDecoder().decode(data.subarray(0, length));
}

function captureOutput() {
  const stdout = [];
  const stderr = [];
  const original = {
    log: console.log,
    error: console.error,
    warn: console.warn,
    stdoutWrite: globalThis.process?.stdout?.write,
    stderrWrite: globalThis.process?.stderr?.write,
  };
  console.log = (...values) => stdout.push(formatValue(...values) + "\n");
  console.error = (...values) => stderr.push(formatValue(...values) + "\n");
  console.warn = (...values) => stderr.push(formatValue(...values) + "\n");
  if (globalThis.process?.stdout?.write) {
    globalThis.process.stdout.write = (chunk, ...rest) => {
      stdout.push(chunkText(chunk));
      callWriteCallback(rest);
      return true;
    };
  }
  if (globalThis.process?.stderr?.write) {
    globalThis.process.stderr.write = (chunk, ...rest) => {
      stderr.push(chunkText(chunk));
      callWriteCallback(rest);
      return true;
    };
  }
  return {
    stdout: () => stdout.join(""),
    stderr: () => stderr.join(""),
    restore: () => {
      console.log = original.log;
      console.error = original.error;
      console.warn = original.warn;
      if (original.stdoutWrite) globalThis.process.stdout.write = original.stdoutWrite;
      if (original.stderrWrite) globalThis.process.stderr.write = original.stderrWrite;
    },
  };
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

function optional(value) {
  return value === undefined || value === null
    ? Option$None$const
    : new Some(String(value));
}
