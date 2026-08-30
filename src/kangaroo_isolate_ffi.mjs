// Runs a test case body in isolation and catches any error it raises.
import {
  CapturedIsolation,
  CaughtError,
  Completed,
  Crashed,
  SkippedIsolation,
} from "./kangaroo/isolate.mjs";
import { from_js_stack } from "./kangaroo/location.mjs";
import { Worker } from "node:worker_threads";
import { format as formatValue } from "node:util";
import { terminateProcessTree } from "./kangaroo_process_tree.mjs";
import { ensureWindowsJobHelper } from "./kangaroo_windows_job.mjs";
import {
  Option$None$const,
  Some,
} from "../gleam_stdlib/gleam/option.mjs";

const workerUrl = new URL("./kangaroo_test_worker.mjs", import.meta.url);
const workerMessageBytes = 1024 * 1024;
const defaultCapturedOutputBytes = 16 * 1024 * 1024;
const childPidCapacity = 4096;

export function isolate_captured(body, timeout_ms) {
  return isolateCaptured(body, timeout_ms, defaultCapturedOutputBytes);
}

export function isolate_captured_with_limit(body, timeout_ms, outputLimit) {
  return isolateCaptured(body, timeout_ms, Math.max(1, Number(outputLimit)));
}

function isolateCaptured(body, timeout_ms, outputLimit) {
  if (body && body.kangarooModulePath && body.kangarooFunctionName) {
    try {
      ensureWindowsJobHelper();
    } catch (error) {
      return new CapturedIsolation(
        new Crashed(
          new CaughtError(
            "infrastructure",
            `could not prepare Windows process isolation: ${errorMessage(error)}`,
            from_js_stack(""),
            Option$None$const,
            Option$None$const,
            Option$None$const,
          ),
        ),
        "",
        "",
      );
    }
    return isolateWorker(body, timeout_ms, outputLimit);
  }
  const output = captureOutput();
  let result;
  try {
    body();
    result = new Completed();
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
    output.restore();
  }
  return new CapturedIsolation(result, output.stdout(), output.stderr());
}

function errorMessage(error) {
  return String(error && error.message ? error.message : error);
}

function isolateWorker(body, timeoutOption, outputLimit) {
  const timeoutMs =
    timeoutOption && typeof timeoutOption[0] === "number"
      ? timeoutOption[0]
      : 30_000;
  const controlBuffer = new SharedArrayBuffer(Int32Array.BYTES_PER_ELEMENT * 8);
  const dataBuffer = new SharedArrayBuffer(workerMessageBytes);
  const stdoutBuffer = new SharedArrayBuffer(outputLimit);
  const stderrBuffer = new SharedArrayBuffer(outputLimit);
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
      maxCapturedOutputBytes: outputLimit,
      timeoutMs,
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
    const outputExceeded = Atomics.load(control, 7) === 1;
    const stdout = outputExceeded ? "" : sharedOutput(control, 3, stdoutData);
    const stderr = outputExceeded ? "" : sharedOutput(control, 4, stderrData);
    requestWorkerCancellation(worker, control, () => {
      terminateRegisteredChildren(childPids);
    });
    terminateRegisteredChildren(childPids, true);
    void worker.terminate();
    if (outputExceeded) return outputLimitIsolation(outputLimit);
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
    result = new Completed();
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

function outputLimitIsolation(outputLimit) {
  return new CapturedIsolation(
    new Crashed(
      new CaughtError(
        "infrastructure",
        `test output exceeded ${outputLimit} bytes`,
        from_js_stack(""),
        Option$None$const,
        Option$None$const,
        Option$None$const,
      ),
    ),
    "",
    "",
  );
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
  console.log = (...values) => pushOutput(stdout, formatValue(...values) + "\n");
  console.error = (...values) => pushOutput(stderr, formatValue(...values) + "\n");
  console.warn = (...values) => pushOutput(stderr, formatValue(...values) + "\n");
  if (globalThis.process?.stdout?.write) {
    globalThis.process.stdout.write = (chunk, ...rest) => {
      pushOutput(stdout, chunk);
      callWriteCallback(rest);
      return true;
    };
  }
  if (globalThis.process?.stderr?.write) {
    globalThis.process.stderr.write = (chunk, ...rest) => {
      pushOutput(stderr, chunk);
      callWriteCallback(rest);
      return true;
    };
  }
  return {
    stdout: () => decodeOutput(stdout),
    stderr: () => decodeOutput(stderr),
    restore: () => {
      console.log = original.log;
      console.error = original.error;
      console.warn = original.warn;
      if (original.stdoutWrite) globalThis.process.stdout.write = original.stdoutWrite;
      if (original.stderrWrite) globalThis.process.stderr.write = original.stderrWrite;
    },
  };
}

function pushOutput(chunks, chunk) {
  const bytes = chunk instanceof Uint8Array
    ? chunk
    : new TextEncoder().encode(
      typeof chunk === "string" ? chunk : String(chunk),
    );
  chunks.push(bytes.slice());
}

function decodeOutput(chunks) {
  const length = chunks.reduce((total, chunk) => total + chunk.length, 0);
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.length;
  }
  return new TextDecoder().decode(bytes);
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
