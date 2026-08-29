import { spawn } from "node:child_process";
import { workerData } from "node:worker_threads";
import {
  freezeProcessTree,
  terminateProcessTree,
} from "./kangaroo_process_tree.mjs";

const port = workerData.port;
const startup = new Int32Array(workerData.startupBuffer);
const activity = new Int32Array(workerData.activityBuffer);
let terminal = false;
let cancelled = false;
let timeout;
let terminating = false;
let stdinClosed = false;
let inputRequested = false;
let terminationPids = [];
let output = "";
const terminationPause = new Int32Array(new SharedArrayBuffer(4));

function publish(message) {
  port.postMessage(message);
  Atomics.add(activity, 0, 1);
  Atomics.notify(activity, 0);
}

function signalStarted(status = 1) {
  if (Atomics.compareExchange(startup, 0, 0, status) === 0) {
    Atomics.notify(startup, 0);
  }
}

function finish(message) {
  if (terminal) return;
  terminal = true;
  clearTimeout(timeout);
  publish(message);
  port.close();
}

function terminateTree(message) {
  if (terminal || terminating) return;
  terminating = true;
  terminationPids = freezeProcessTree(child?.pid);
  terminateProcessTree(child?.pid, {
    knownDescendants: terminationPids,
    alreadyFrozen: true,
  });
  // Signal delivery is asynchronous. Do not acknowledge cancellation while a
  // just-killed compiler can still finish a filesystem syscall in the
  // workspace that the caller is about to replace or remove.
  Atomics.wait(terminationPause, 0, 0, 10);
  finish(message);
}

let child;
try {
  child = spawn(workerData.executable, workerData.arguments, {
    cwd: workerData.directory,
    env: workerData.environment,
    windowsHide: true,
    detached: globalThis.process.platform !== "win32",
    stdio: ["pipe", "pipe", "pipe"],
  });
  signalStarted();
  child.stdout.on("data", (data) => {
    const chunk = data.toString("utf8");
    output += chunk;
    publish({ type: "output", data: chunk });
  });
  child.stderr.on("data", (data) => {
    const chunk = data.toString("utf8");
    output += chunk;
    publish({ type: "output", data: chunk });
  });
  child.stdin.on("error", (error) => {
    if (!terminating) {
      terminateTree({ type: "failed", message: String(error.message || error) });
    }
  });
  child.stdin.on("close", () => {
    stdinClosed = true;
    // On Windows a write can be accepted into libuv's pipe buffer after the
    // remote end has closed, so its callback may report success. Pair the
    // close notification with the write request and fail while the child is
    // still alive; a normal child exit sets exitCode before stdio closes.
    if (
      inputRequested &&
      !terminating &&
      !terminal &&
      child.exitCode === null &&
      child.signalCode === null
    ) {
      terminateTree({
        type: "failed",
        message: "process stdin closed while child was running",
      });
    }
  });
  child.on("error", (error) => {
    if (!terminating) {
      finish({ type: "failed", message: String(error.message || error) });
    }
  });
  child.on("close", (exitCode) => {
    if (cancelled) {
      terminateTree({ type: "cancelled" });
    } else if (!terminating) {
      finish({ type: "finished", exitCode: exitCode ?? 2, output });
    }
  });
} catch (error) {
  signalStarted(2);
  finish({ type: "failed", message: String(error.message || error) });
}

port.on("message", (message) => {
  if (message && message.type === "input" && !terminal) {
    inputRequested = true;
    if (stdinClosed || !child?.stdin?.writable) {
      terminateTree({ type: "failed", message: "process stdin is not writable" });
      return;
    }
    try {
      child.stdin.write(String(message.data || ""), (error) => {
        if (error && !terminal && !terminating) {
          terminateTree({
            type: "failed",
            message: String(error.message || error),
          });
        }
      });
    } catch (error) {
      terminateTree({ type: "failed", message: String(error.message || error) });
    }
    return;
  }
  if (message && message.type === "cancel" && !terminal) {
    cancelled = true;
    terminateTree({ type: "cancelled" });
  }
});

timeout = setTimeout(() => {
  if (!terminal) {
    terminateTree({ type: "failed", message: "process timed out" });
  }
}, Math.max(1, Number(workerData.timeoutMs || 1)));
