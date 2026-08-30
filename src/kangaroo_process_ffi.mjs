import {
  MessageChannel,
  Worker,
  receiveMessageOnPort,
} from "node:worker_threads";
import { Empty, Error as GleamError, Ok } from "./gleam.mjs";
import {
  terminateProcessTree,
  terminateRemainingProcessGroup,
} from "./kangaroo_process_tree.mjs";
import { ensureWindowsJobHelper } from "./kangaroo_windows_job.mjs";
import {
  ProcessCancelled,
  ProcessFailed,
  ProcessFinished,
  ProcessOutput,
  ProcessResult,
  ProcessRunning,
} from "./kangaroo/internal/process.mjs";

const processWorkerUrl = new URL("./kangaroo_process_worker.mjs", import.meta.url);
const maxOutputBytes = 16 * 1024 * 1024;
const activityBufferKey = Symbol.for("kangaroo.activityBuffer");
const activityBuffer =
  globalThis[activityBufferKey] ||
  new SharedArrayBuffer(Int32Array.BYTES_PER_ELEMENT);
globalThis[activityBufferKey] = activityBuffer;
const processes = new Map();
let nextProcessId = 1;
const workerStartupTimeoutMs = 10_000;

// Workers and command groups are deliberately detached so a watch coordinator
// can poll them synchronously. If that coordinator exits unexpectedly, it must
// still release every command group it owns.
export function terminate_active_processes() {
  for (const active of processes.values()) {
    const pid = Atomics.load(active.startup, 1);
    if (globalThis.process.platform === "win32") {
      terminateProcessTree(pid);
    } else {
      terminateRemainingProcessGroup(pid);
    }
    active.port.close();
  }
  processes.clear();
}

globalThis.process?.once?.("exit", terminate_active_processes);

function listToArray(list) {
  const values = [];
  for (let node = list; node && !(node instanceof Empty); node = node.tail) {
    values.push(node.head);
  }
  return values;
}

export function run(directory, executable, argumentList, environment, timeoutMs) {
  try {
    const id = createProcess(
      directory,
      executable,
      argumentList,
      environment,
      timeoutMs,
      false,
    );
    return waitForProcess(id, timeoutMs);
  } catch (error) {
    return new GleamError(String(error && error.message ? error.message : error));
  }
}

export function run_inherited(
  directory,
  executable,
  argumentList,
  environment,
  timeoutMs,
) {
  try {
    const id = createProcess(
      directory,
      executable,
      argumentList,
      environment,
      timeoutMs,
      true,
    );
    return waitForProcess(id, timeoutMs);
  } catch (error) {
    return new GleamError(errorMessage(error));
  }
}

export function start(directory, executable, argumentList, environment, timeoutMs) {
  try {
    return new Ok(createProcess(
      directory,
      executable,
      argumentList,
      environment,
      timeoutMs,
      false,
    ));
  } catch (error) {
    return new GleamError(errorMessage(error));
  }
}

function createProcess(
  directory,
  executable,
  argumentList,
  environment,
  timeoutMs,
  inherited,
) {
  ensureWindowsJobHelper();
  const id = nextProcessId++;
  const env = { ...globalThis.process.env };
  for (const pair of listToArray(environment)) env[pair[0]] = pair[1];
  const { port1, port2 } = new MessageChannel();
  // Give an already-hot Worker a brief chance to launch, but never make the
  // watch coordinator blind to saves while a cold Worker imports modules.
  // Port messages (including cancellation) remain queued until it is ready.
  const startupBuffer = new SharedArrayBuffer(Int32Array.BYTES_PER_ELEMENT * 2);
  const startup = new Int32Array(startupBuffer);
  const worker = new Worker(processWorkerUrl, {
    workerData: {
      port: port2,
      startupBuffer,
      activityBuffer,
      directory,
      executable,
      arguments: listToArray(argumentList),
      environment: env,
      timeoutMs,
      maxOutputBytes,
      inherited,
    },
    transferList: [port2],
  });
  // Gleam polls this channel synchronously, so neither side of the
  // coordinator bridge should keep a completed CLI/daemon alive while a
  // Worker exit event is waiting for the JavaScript event loop.
  worker.unref?.();
  port1.unref?.();
  processes.set(id, {
    worker,
    port: port1,
    output: [],
    startup,
    startupDeadline: Date.now() + workerStartupTimeoutMs,
    cancellationStarted: 0,
  });
  Atomics.wait(startup, 0, 0, 25);
  return id;
}

function waitForProcess(id, timeoutMs) {
  // The child Worker owns the exact command timeout. This outer deadline only
  // protects against a Worker startup/runtime failure which cannot publish a
  // terminal protocol message.
  const deadline = Date.now() + Math.max(1, Number(timeoutMs)) + 1000;
  let observedActivity = Atomics.load(new Int32Array(activityBuffer), 0);
  while (true) {
    const state = poll(id);
    if (state instanceof ProcessOutput) continue;
    if (state instanceof ProcessFinished) return new Ok(state.result);
    if (state instanceof ProcessFailed) return new GleamError(state.message);
    if (state instanceof ProcessCancelled) {
      return new GleamError("process was cancelled");
    }
    const remaining = deadline - Date.now();
    if (remaining <= 0) {
      const active = processes.get(id);
      if (active) {
        active.port.postMessage({ type: "cancel" });
        forceCancel(id, active);
      }
      return new GleamError("process timed out");
    }
    const activity = new Int32Array(activityBuffer);
    Atomics.wait(activity, 0, observedActivity, Math.min(remaining, 50));
    observedActivity = Atomics.load(activity, 0);
  }
}

export function poll(id) {
  const active = processes.get(id);
  if (!active) return new ProcessFailed("unknown process handle");
  if (
    active.cancellationStarted > 0 &&
    Date.now() - active.cancellationStarted >= hardCancellationDelayMs()
  ) {
    const delay = hardCancellationDelayMs();
    forceCancel(id, active);
    return new ProcessFailed(
      `process cancellation did not settle within ${delay} ms`,
    );
  }
  while (true) {
    const received = receiveMessageOnPort(active.port);
    if (!received) {
      const startupStatus = Atomics.load(active.startup, 0);
      if (startupStatus === 3) {
        forceCancel(id, active);
        return new ProcessFailed(
          "process worker stopped before publishing a result",
        );
      }
      if (startupStatus === 0 && Date.now() >= active.startupDeadline) {
        forceCancel(id, active);
        return new ProcessFailed(
          `process worker did not start within ${workerStartupTimeoutMs} ms`,
        );
      }
      return new ProcessRunning();
    }
    const message = received.message;
    if (message.type === "output") {
      active.output.push(String(message.data || ""));
      return new ProcessOutput(String(message.data || ""));
    }
    processes.delete(id);
    active.port.close();
    void active.worker.terminate();
    if (message.type === "cancelled") return new ProcessCancelled();
    if (message.type === "failed") {
      return new ProcessFailed(String(message.message || "process failed"));
    }
    const completeOutput =
      typeof message.output === "string" ? message.output : active.output.join("");
    return new ProcessFinished(
      new ProcessResult(Number(message.exitCode ?? 2), completeOutput),
    );
  }
}

export function cancel(id) {
  const active = processes.get(id);
  if (active) {
    if (active.cancellationStarted === 0) {
      active.cancellationStarted = Date.now();
    }
    active.port.postMessage({ type: "cancel" });
  }
}

export function write(id, input) {
  const active = processes.get(id);
  if (active) active.port.postMessage({ type: "input", data: String(input) });
}

function errorMessage(error) {
  return String(error && error.message ? error.message : error);
}

function hardCancellationDelayMs() {
  return globalThis.process.platform === "win32" ? 4500 : 750;
}

function forceCancel(id, active) {
  const pid = Atomics.load(active.startup, 1);
  terminateProcessTree(pid);
  active.port.close();
  void active.worker.terminate();
  processes.delete(id);
}
