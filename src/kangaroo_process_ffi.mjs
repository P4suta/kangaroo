import { spawnSync } from "node:child_process";
import {
  MessageChannel,
  Worker,
  receiveMessageOnPort,
} from "node:worker_threads";
import { Empty, Error as GleamError, Ok } from "./gleam.mjs";
import {
  ProcessCancelled,
  ProcessFailed,
  ProcessFinished,
  ProcessOutput,
  ProcessResult,
  ProcessRunning,
} from "./kangaroo/internal/process.mjs";

const processWorkerUrl = new URL("./kangaroo_process_worker.mjs", import.meta.url);
const activityBufferKey = Symbol.for("kangaroo.activityBuffer");
const activityBuffer =
  globalThis[activityBufferKey] ||
  new SharedArrayBuffer(Int32Array.BYTES_PER_ELEMENT);
globalThis[activityBufferKey] = activityBuffer;
const processes = new Map();
let nextProcessId = 1;

function listToArray(list) {
  const values = [];
  for (let node = list; node && !(node instanceof Empty); node = node.tail) {
    values.push(node.head);
  }
  return values;
}

export function run(directory, executable, argumentList, environment, timeoutMs) {
  try {
    const env = { ...globalThis.process.env };
    for (const pair of listToArray(environment)) env[pair[0]] = pair[1];
    const child = spawnSync(executable, listToArray(argumentList), {
      cwd: directory,
      env,
      encoding: "utf8",
      windowsHide: true,
      timeout: timeoutMs,
      maxBuffer: 16 * 1024 * 1024,
    });
    // Node may attach an EPERM diagnostic to an otherwise successful
    // spawnSync result in a restricted process namespace. A concrete status
    // means the child did run, so preserve that authoritative result.
    if (child.error && child.status === null) throw child.error;
    const output = `${child.stdout || ""}${child.stderr || ""}`;
    return new Ok(new ProcessResult(child.status ?? 2, output));
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
    const env = { ...globalThis.process.env };
    for (const pair of listToArray(environment)) env[pair[0]] = pair[1];
    const child = spawnSync(executable, listToArray(argumentList), {
      cwd: directory,
      env,
      stdio: "inherit",
      windowsHide: false,
      timeout: timeoutMs,
    });
    if (child.error && child.status === null) throw child.error;
    return new Ok(new ProcessResult(child.status ?? 2, ""));
  } catch (error) {
    return new GleamError(errorMessage(error));
  }
}

export function start(directory, executable, argumentList, environment, timeoutMs) {
  try {
    const id = nextProcessId++;
    const env = { ...globalThis.process.env };
    for (const pair of listToArray(environment)) env[pair[0]] = pair[1];
    const { port1, port2 } = new MessageChannel();
    // Give an already-hot Worker a brief chance to launch, but never make the
    // watch coordinator blind to saves while a cold Worker imports modules.
    // Port messages (including cancellation) remain queued until it is ready.
    const startupBuffer = new SharedArrayBuffer(Int32Array.BYTES_PER_ELEMENT);
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
      },
      transferList: [port2],
    });
    // Gleam polls this channel synchronously, so neither side of the
    // coordinator bridge should keep a completed CLI/daemon alive while a
    // Worker exit event is waiting for the JavaScript event loop.
    worker.unref?.();
    port1.unref?.();
    processes.set(id, { worker, port: port1, output: "" });
    Atomics.wait(startup, 0, 0, 25);
    return new Ok(id);
  } catch (error) {
    return new GleamError(errorMessage(error));
  }
}

export function poll(id) {
  const active = processes.get(id);
  if (!active) return new ProcessFailed("unknown process handle");
  while (true) {
    const received = receiveMessageOnPort(active.port);
    if (!received) return new ProcessRunning();
    const message = received.message;
    if (message.type === "output") {
      active.output += String(message.data || "");
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
      typeof message.output === "string" ? message.output : active.output;
    return new ProcessFinished(
      new ProcessResult(Number(message.exitCode ?? 2), completeOutput),
    );
  }
}

export function cancel(id) {
  const active = processes.get(id);
  if (active) active.port.postMessage({ type: "cancel" });
}

export function write(id, input) {
  const active = processes.get(id);
  if (active) active.port.postMessage({ type: "input", data: String(input) });
}

function errorMessage(error) {
  return String(error && error.message ? error.message : error);
}
