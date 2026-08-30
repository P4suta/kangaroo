import { parentPort, workerData } from "node:worker_threads";
import { pathToFileURL } from "node:url";
import { readFileSync } from "node:fs";
import { format as formatValue } from "node:util";
import { createRequire, syncBuiltinESMExports } from "node:module";
import { inspect as inspectValue } from "../gleam_stdlib/gleam/string.mjs";
import { flush as flushCoverage } from "./kangaroo_coverage_probe_ffi.mjs";
import { diff_lines as diffLines } from "./kangaroo/diff.mjs";
import { terminateProcessTree } from "./kangaroo_process_tree.mjs";
import {
  windowsJobLaunch,
  windowsJobSpawnOptions,
} from "./kangaroo_windows_job.mjs";

const require = createRequire(import.meta.url);
const childProcess = require("node:child_process");
const childProcesses = new Set();
const childPids = new Int32Array(workerData.childPidBuffer);
const control = new Int32Array(workerData.controlBuffer);
const data = new Uint8Array(workerData.dataBuffer);
const stdoutData = new Uint8Array(workerData.stdoutBuffer);
const stderrData = new Uint8Array(workerData.stderrBuffer);
const synchronousCleanupMarginMs = 25;
let testDeadline = Number.POSITIVE_INFINITY;
let finishing = false;

function publishPrematureExit(code) {
  if (Atomics.load(control, 0) !== 0) return;
  signalStarted();
  const encoded = new TextEncoder().encode(JSON.stringify({
    name: "infrastructure",
    message: `JavaScript test worker exited with code ${Number(code)}` +
      " before publishing a result",
    stack: "",
  }));
  data.set(encoded);
  Atomics.store(control, 1, 3);
  Atomics.store(control, 2, encoded.length);
  Atomics.store(control, 0, 1);
  Atomics.notify(control, 0, 1);
}

globalThis.process?.once?.("exit", publishPrematureExit);

// Node 24 on Windows can terminate the complete host when process.exit() is
// called by a nested Worker. Publish the isolated failure ourselves and park
// this Worker until its owner terminates it, preserving process.exit's
// non-returning contract without risking the test runner process.
if (globalThis.process && typeof globalThis.process.exit === "function") {
  globalThis.process.exit = (code = 0) => {
    finishing = true;
    clearInterval(cancellationPoll);
    publishPrematureExit(code);
    Atomics.wait(control, 0, 1);
  };
}

function claimPidSlot(pid) {
  for (let index = 1; index < childPids.length; index += 1) {
    if (Atomics.compareExchange(childPids, index, 0, pid) !== 0) continue;
    let highWater = Atomics.load(childPids, 0);
    while (
      highWater < index &&
      Atomics.compareExchange(childPids, 0, highWater, index) !== highWater
    ) {
      highWater = Atomics.load(childPids, 0);
    }
    Atomics.notify(childPids, 0, 1);
    return index;
  }
  return 0;
}

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
    pidValue = child.pid;
    pidIndex = claimPidSlot(pidValue);
    if (pidIndex === 0) {
      childProcesses.delete(child);
      terminateProcessTree(pidValue);
      throw new Error(
        `test exceeded the ${childPids.length - 1} concurrent child process limit`,
      );
    }
    // A short test timeout can expire while a runtime's spawn() call is still
    // blocked. Observe the shared cancellation flag before returning to test
    // code so a newly published process group is stopped immediately instead
    // of waiting for the Worker's event loop to run its cancellation handler.
    if (Atomics.load(control, 6) === 1 || finishing) {
      terminateProcessTree(pidValue);
    }
  };
  registerPid();
  // Deno's node:child_process compatibility layer can assign the pid only
  // after spawn() returns. Keep the child tracked immediately and publish its
  // pid as soon as the runtime reports that the process started.
  child.once?.("spawn", registerPid);
  const unregister = () => {
    childProcesses.delete(child);
    if (pidIndex > 0 && globalThis.process.platform === "win32") {
      // The ChildProcess still owns its native handle while the exit callback
      // runs. Terminate any recorded descendants now; retaining the numeric
      // PID until test completion would risk acting on a reused PID later.
      terminateProcessTree(pidValue);
      Atomics.compareExchange(childPids, pidIndex, pidValue, 0);
      return;
    }
    // The group leader can exit after starting a grandchild. Keep its process
    // group id and shared registry slot until test cleanup; Unix may reparent
    // the survivor before the test function itself returns.
    if (
      pidIndex > 0 &&
      persistentProcessGroup(pidValue)
    ) {
      childProcesses.add({ pid: pidValue });
      return;
    }
    if (pidIndex > 0) {
      Atomics.compareExchange(childPids, pidIndex, pidValue, 0);
    }
  };
  if (typeof child.once === "function") {
    child.once("exit", unregister);
  } else if (child.exited && typeof child.exited.then === "function") {
    void child.exited.then(unregister, unregister);
  } else if (child.status && typeof child.status.then === "function") {
    void child.status.then(unregister, unregister);
  }
  return child;
}

function synchronousIsolationError(api) {
  return new Error(
    `${api} cannot be safely isolated on ${globalThis.process.platform}` +
      "; use an asynchronous subprocess API",
  );
}

function isolatedAsynchronousOptions(options = {}) {
  return globalThis.process.platform === "win32"
    ? options
    : { ...options, detached: true };
}

function boundedSynchronousOptions(options = {}) {
  const remaining = Math.max(
    1,
    Math.floor(testDeadline - Date.now() - synchronousCleanupMarginMs),
  );
  const requested = Number(options.timeout);
  const requestedTimeout = Number.isFinite(requested) && requested > 0
    ? requested
    : Number.POSITIVE_INFINITY;
  const deadlineLimited = remaining <= requestedTimeout;
  return {
    options: {
      ...options,
      detached: globalThis.process.platform !== "win32",
      timeout: Math.min(remaining, requestedTimeout),
      ...(deadlineLimited ? { killSignal: "SIGKILL" } : {}),
    },
    deadlineLimited,
  };
}

function persistentProcessGroup(pid) {
  if (!Number.isInteger(pid) || pid <= 0 || globalThis.process.platform === "win32") {
    return false;
  }
  try {
    globalThis.process.kill(-pid, 0);
    return true;
  } catch {
    return false;
  }
}

function trackSynchronousGroup(pid) {
  if (persistentProcessGroup(pid)) registerChild({ pid });
}

const originalNodeSpawnSync = childProcess.spawnSync;

function trackedNodeSpawnSync(command, arguments_ = [], options = {}) {
  if (
    globalThis.process.platform === "win32" ||
    typeof globalThis.Bun !== "undefined" ||
    typeof globalThis.Deno !== "undefined"
  ) {
    throw synchronousIsolationError("node:child_process synchronous APIs");
  }
  const bounded = boundedSynchronousOptions(options);
  const result = originalNodeSpawnSync(command, arguments_, bounded.options);
  trackSynchronousGroup(result?.pid);
  if (bounded.deadlineLimited && result?.error?.code === "ETIMEDOUT") {
    const timeout = new Error(
      `Test case timed out after ${Math.max(1, Number(workerData.timeoutMs || 1))} ms`,
    );
    timeout.name = "timeout";
    throw timeout;
  }
  return result;
}

function normaliseNodeSpawnSyncArguments(values) {
  if (Array.isArray(values[1])) {
    return [values[0], values[1], values[2] || {}];
  }
  return [values[0], [], values[1] || {}];
}

function execResult(result, command) {
  if (result.error) {
    Object.assign(result.error, result);
    throw result.error;
  }
  if (result.status !== 0) {
    const error = new Error(`Command failed: ${command}`);
    Object.assign(error, result);
    throw error;
  }
  return result.stdout;
}

childProcess.spawnSync = function trackedSpawnSync(...values) {
  return trackedNodeSpawnSync(...normaliseNodeSpawnSyncArguments(values));
};

childProcess.execFileSync = function trackedExecFileSync(
  file,
  argumentsOrOptions,
  maybeOptions,
) {
  const arguments_ = Array.isArray(argumentsOrOptions) ? argumentsOrOptions : [];
  const options = Array.isArray(argumentsOrOptions)
    ? maybeOptions || {}
    : argumentsOrOptions || {};
  const result = trackedNodeSpawnSync(file, arguments_, options);
  return execResult(result, [file, ...arguments_].join(" "));
};

childProcess.execSync = function trackedExecSync(command, options = {}) {
  const result = trackedNodeSpawnSync(command, [], { ...options, shell: true });
  return execResult(result, command);
};

// Patching ChildProcess.prototype also covers runtimes such as Bun which do
// not mirror syncBuiltinESMExports() changes into an already-created named
// `spawn` binding.
const childProcessPrototype = childProcess.ChildProcess?.prototype;
if (childProcessPrototype?.spawn) {
  const originalPrototypeSpawn = childProcessPrototype.spawn;
  childProcessPrototype.spawn = function trackedPrototypeSpawn(...arguments_) {
    if (arguments_[0] && typeof arguments_[0] === "object") {
      // Give every test-owned subprocess its own process group. Timeout and
      // cancellation can then freeze the complete group before a slower OS
      // process-tree snapshot lets a descendant perform late work.
      arguments_[0] = globalThis.process.platform === "win32"
        ? windowsJobSpawnOptions(arguments_[0])
        : { ...arguments_[0], detached: true };
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

if (typeof globalThis.Bun?.spawn === "function") {
  const originalBunSpawn = globalThis.Bun.spawn.bind(globalThis.Bun);
  globalThis.Bun.spawn = (commandOrOptions, maybeOptions) => {
    const objectForm = !Array.isArray(commandOrOptions);
    const command = objectForm ? commandOrOptions?.cmd : commandOrOptions;
    const options = objectForm ? commandOrOptions : maybeOptions || {};
    let child;
    if (
      globalThis.process.platform === "win32" &&
      Array.isArray(command) &&
      command.length > 0
    ) {
      const baseEnvironment = options.env ?? globalThis.process.env;
      const launch = windowsJobLaunch(
        command[0],
        command.slice(1),
        options.cwd ?? globalThis.process.cwd(),
        baseEnvironment,
        options.argv0 ?? command[0],
      );
      const wrappedCommand = [launch.executable, ...launch.arguments];
      child = objectForm
        ? originalBunSpawn({
          ...options,
          cmd: wrappedCommand,
          env: launch.environment,
        })
        : originalBunSpawn(wrappedCommand, {
          ...options,
          env: launch.environment,
        });
    } else {
      child = objectForm
        ? originalBunSpawn(isolatedAsynchronousOptions(commandOrOptions))
        : originalBunSpawn(
          commandOrOptions,
          isolatedAsynchronousOptions(options),
        );
    }
    return registerChild(child);
  };

  globalThis.Bun.spawnSync = (commandOrOptions, maybeOptions = {}) => {
    if (globalThis.process.platform === "win32") {
      throw synchronousIsolationError("Bun.spawnSync");
    }
    const objectForm = !Array.isArray(commandOrOptions);
    const command = objectForm ? commandOrOptions?.cmd : commandOrOptions;
    const options = objectForm
      ? { ...commandOrOptions, cmd: undefined }
      : maybeOptions;
    if (!Array.isArray(command) || command.length === 0) {
      throw new TypeError("Bun.spawnSync requires a non-empty command array");
    }
    const stdio = options.stdio || [options.stdin, options.stdout, options.stderr];
    const normaliseStdio = (value, fallback) => {
      if (value === undefined) return fallback;
      if (["pipe", "inherit", "ignore"].includes(value) || value === null) {
        return value === null ? "ignore" : value;
      }
      if (typeof value === "number") return value;
      throw synchronousIsolationError("Bun.spawnSync custom stdio");
    };
    const result = trackedNodeSpawnSync(command[0], command.slice(1), {
      cwd: options.cwd,
      env: options.env,
      uid: options.uid,
      gid: options.gid,
      argv0: options.argv0,
      windowsHide: options.windowsHide,
      windowsVerbatimArguments: options.windowsVerbatimArguments,
      timeout: options.timeout,
      killSignal: options.killSignal,
      maxBuffer: options.maxBuffer,
      stdio: [
        normaliseStdio(stdio[0], "pipe"),
        normaliseStdio(stdio[1], "pipe"),
        normaliseStdio(stdio[2], "pipe"),
      ],
    });
    return {
      stdout: result.stdout ?? undefined,
      stderr: result.stderr ?? undefined,
      exitCode: result.status ?? 1,
      success: result.status === 0,
      resourceUsage: globalThis.process.resourceUsage?.(),
      signalCode: result.signal ?? undefined,
      pid: result.pid,
      ...(result.error?.code === "ETIMEDOUT" ? { exitedDueToTimeout: true } : {}),
    };
  };
}

if (typeof globalThis.Deno?.Command === "function") {
  const OriginalDenoCommand = globalThis.Deno.Command;
  const commandState = new WeakMap();
  globalThis.Deno.Command = class TrackedDenoCommand extends OriginalDenoCommand {
    constructor(command, options = {}) {
      const isolatedOptions = isolatedAsynchronousOptions(options);
      if (globalThis.process.platform === "win32") {
        const baseEnvironment = options.clearEnv
          ? { ...(options.env || {}) }
          : { ...globalThis.process.env, ...(options.env || {}) };
        const launch = windowsJobLaunch(
          command,
          options.args || [],
          options.cwd ?? globalThis.process.cwd(),
          baseEnvironment,
        );
        const wrappedOptions = {
          ...isolatedOptions,
          args: launch.arguments,
          env: launch.environment,
          clearEnv: true,
        };
        super(launch.executable, wrappedOptions);
        commandState.set(this, {
          command: launch.executable,
          options: wrappedOptions,
        });
      } else {
        super(command, isolatedOptions);
        commandState.set(this, { command, options: isolatedOptions });
      }
    }

    spawn() {
      return registerChild(super.spawn());
    }

    async output() {
      const { command, options } = commandState.get(this);
      if (options.stdin === "piped") {
        throw new TypeError("Deno.Command.output() does not support piped stdin");
      }
      const stdoutMode = options.stdout ?? "piped";
      const stderrMode = options.stderr ?? "piped";
      const child = registerChild(
        new OriginalDenoCommand(command, {
          ...options,
          stdout: stdoutMode,
          stderr: stderrMode,
        }).spawn(),
      );
      const empty = () => new Uint8Array();
      const read = (stream) => new Response(stream)
        .arrayBuffer()
        .then((value) => new Uint8Array(value));
      const [status, stdout, stderr] = await Promise.all([
        child.status,
        stdoutMode === "piped" ? read(child.stdout) : Promise.resolve(empty()),
        stderrMode === "piped" ? read(child.stderr) : Promise.resolve(empty()),
      ]);
      return { ...status, stdout, stderr };
    }

    outputSync() {
      throw synchronousIsolationError("Deno.Command.outputSync");
    }
  };
}
syncBuiltinESMExports();
const cancellationPoll = setInterval(() => {
  if (Atomics.load(control, 6) === 1) acknowledgeCancellation();
}, 1);
cancellationPoll.unref?.();

console.log = (...values) => writeOutput(stdoutData, 3, formatValue(...values) + "\n");
console.error = (...values) => writeOutput(stderrData, 4, formatValue(...values) + "\n");
console.warn = (...values) => writeOutput(stderrData, 4, formatValue(...values) + "\n");
if (globalThis.process?.stdout?.write) {
  globalThis.process.stdout.write = (chunk, ...rest) => {
    writeOutput(stdoutData, 3, chunk);
    callWriteCallback(rest);
    return true;
  };
}
if (globalThis.process?.stderr?.write) {
  globalThis.process.stderr.write = (chunk, ...rest) => {
    writeOutput(stderrData, 4, chunk);
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
    finish(1, {});
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

function optionValue(option) {
  return option && Object.prototype.hasOwnProperty.call(option, "0")
    ? option[0]
    : null;
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
  let expectedText;
  let actualText;
  if (typeof expected === "string" && typeof actual === "string") {
    expectedText = expected;
    actualText = actual;
  } else if (
    expected && actual &&
    typeof expected[Symbol.iterator] === "function" &&
    typeof actual[Symbol.iterator] === "function"
  ) {
    expectedText = Array.from(expected, inspectValue).join("\n");
    actualText = Array.from(actual, inspectValue).join("\n");
  } else {
    return undefined;
  }
  return optionValue(diffLines(expectedText, actualText)) ?? undefined;
}

function finish(status, payload) {
  finishing = true;
  signalStarted();
  clearInterval(cancellationPoll);
  terminateChildProcesses();
  const coverageFailure = flushCoverage();
  if (coverageFailure) {
    status = 3;
    payload = {
      name: "infrastructure",
      message: `coverage persistence failed: ${coverageFailure}`,
      stack: "",
    };
  }
  if (Atomics.load(control, 7) === 1) {
    status = 3;
    payload = {
      name: "infrastructure",
      message: `test output exceeded ${workerData.maxCapturedOutputBytes} bytes`,
      stack: "",
    };
    Atomics.store(control, 3, 0);
    Atomics.store(control, 4, 0);
  }
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
  }
  childProcesses.clear();
  // The owning Worker has synchronously signalled every registered tree. Do
  // not leave positive PIDs for the parent to act on after a normal result,
  // when the OS may already have reused a former group leader's number.
  const highWater = Math.min(
    Atomics.load(childPids, 0),
    childPids.length - 1,
  );
  for (let index = 1; index <= highWater; index += 1) {
    Atomics.store(childPids, index, 0);
  }
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

function signalStarted() {
  if (Atomics.compareExchange(control, 5, 0, 1) === 0) {
    testDeadline = Date.now() + Math.max(1, Number(workerData.timeoutMs || 1));
    Atomics.notify(control, 5, 1);
  }
}

function writeOutput(target, lengthIndex, value) {
  if (Atomics.load(control, 7) === 1) return;
  const encoded = outputBytes(value);
  const start = Atomics.load(control, lengthIndex);
  const otherLength = Atomics.load(control, lengthIndex === 3 ? 4 : 3);
  if (
    encoded.length > target.length - start ||
    encoded.length > workerData.maxCapturedOutputBytes - start - otherLength
  ) {
    Atomics.store(control, 7, 1);
    return;
  }
  if (encoded.length === 0) return;
  target.set(encoded, start);
  Atomics.store(control, lengthIndex, start + encoded.length);
}

function outputBytes(chunk) {
  if (chunk instanceof Uint8Array) return chunk;
  return new TextEncoder().encode(
    typeof chunk === "string" ? chunk : String(chunk),
  );
}

function callWriteCallback(values) {
  const callback = values.find((value) => typeof value === "function");
  if (callback) callback();
}

execute();
