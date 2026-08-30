import { spawn } from "node:child_process";
import { Buffer } from "node:buffer";
import { writeSync } from "node:fs";
import { StringDecoder } from "node:string_decoder";
import { workerData } from "node:worker_threads";
import {
  freezeProcessTree,
  terminateRemainingProcessGroup,
  terminateProcessTree,
} from "./kangaroo_process_tree.mjs";
import { windowsJobLaunch } from "./kangaroo_windows_job.mjs";

const port = workerData.port;
const startup = new Int32Array(workerData.startupBuffer);
const activity = new Int32Array(workerData.activityBuffer);
let terminal = false;
let timeout;
let terminating = false;
let pendingTermination = null;
let stdinClosed = false;
let inputRequested = false;
let terminationPids = [];
let outputBytes = 0;
const terminationPause = new Int32Array(new SharedArrayBuffer(4));
// Bun 1.4 needs its native FileSink bridge on Unix, while its Windows
// node:child_process compatibility stream is the only variant that exposes a
// stable writable pipe contract. Both paths still launch the same Job helper.
const usingBunSpawn =
  typeof globalThis.Bun !== "undefined" &&
  globalThis.process.platform !== "win32";
const inherited = workerData.inherited === true;
const streaming = workerData.streaming === true;

function commandLaunch() {
  if (globalThis.process.platform !== "win32") {
    return {
      executable: workerData.executable,
      arguments: workerData.arguments,
      environment: workerData.environment,
    };
  }

  return windowsJobLaunch(
    workerData.executable,
    workerData.arguments,
    workerData.directory,
    workerData.environment,
  );
}

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

function publishChildPid() {
  if (Number.isInteger(child?.pid) && child.pid > 0) {
    Atomics.store(startup, 1, child.pid);
    Atomics.notify(startup, 1, 1);
  }
}

function finish(message) {
  if (terminal) return;
  terminal = true;
  clearTimeout(timeout);
  Atomics.store(startup, 1, 0);
  try {
    publish(message);
  } catch {
    // The synchronous coordinator cannot consume Worker error events while it
    // polls. Publish a shared terminal sentinel so it never reports this
    // Worker as running until the command's multi-day timeout.
    Atomics.store(startup, 0, 3);
    Atomics.notify(startup, 0);
  }
  port.close();
}

function finishCompleted(exitCode) {
  terminateRemainingProcessGroup(child?.pid);
  finish({ type: "finished", exitCode: exitCode ?? 2 });
}

function publishOutput(chunk) {
  if (!chunk || terminal || terminating) return;
  const bytes = Buffer.byteLength(chunk, "utf8");
  if (outputBytes + bytes > workerData.maxOutputBytes) {
    fail(new Error(
      `process output exceeded ${workerData.maxOutputBytes} bytes`,
    ));
    return;
  }
  outputBytes += bytes;
  publish({ type: "output", data: chunk });
}

function fail(error) {
  if (!terminating && !terminal) {
    terminateTree({
      type: "failed",
      message: String(error && error.message ? error.message : error),
    });
  }
}

function finishTermination() {
  if (terminal || !terminating || pendingTermination === null) return;
  // A ChildProcess close (or Bun's equivalent exited-and-drained promise)
  // proves that the root has exited and its stdio handles are closed. Keep the
  // existing bounded settle period after that proof so a caller never starts
  // a replacement while the killed group is still releasing OS resources.
  Atomics.wait(terminationPause, 0, 0, 10);
  const message = pendingTermination;
  pendingTermination = null;
  finish(message);
}

globalThis.process?.on?.("uncaughtException", fail);
globalThis.process?.on?.("unhandledRejection", fail);

function writeBunInput(value) {
  // Bun 1.4.0's FileSink.flush() can fail with EPERM even though the pipe's
  // descriptor remains writable. The descriptor path uses the same blocking
  // write contract as the Node worker and avoids silently dropping daemon
  // request lines. Keep the public FileSink path as a forward-compatible
  // fallback for runtimes which do not expose the descriptor bridge.
  if (typeof child.stdin?._getFd === "function") {
    const bytes = Buffer.from(value, "utf8");
    const descriptor = child.stdin._getFd();
    if (Number.isInteger(descriptor) && descriptor >= 0) {
      const deadline = Date.now() + 1000;
      let offset = 0;
      while (offset < bytes.length) {
        let written;
        try {
          written = writeSync(
            descriptor,
            bytes,
            offset,
            bytes.length - offset,
          );
        } catch (error) {
          if (
            ["EAGAIN", "EWOULDBLOCK", "EINTR"].includes(error?.code) &&
            Date.now() < deadline
          ) {
            Atomics.wait(terminationPause, 0, 0, 1);
            continue;
          }
          throw error;
        }
        if (written <= 0) {
          throw new Error("process stdin write made no progress");
        }
        offset += written;
      }
      return;
    }
  }
  child.stdin.write(value);
  const flushed = child.stdin.flush();
  if (flushed && typeof flushed.then === "function") {
    void flushed.catch(fail);
  }
}

function terminateTree(message) {
  if (terminal || terminating) return;
  terminating = true;
  pendingTermination = message;
  terminationPids = freezeProcessTree(child?.pid);
  terminateProcessTree(child?.pid, {
    knownDescendants: terminationPids,
    alreadyFrozen: true,
  });
}

let child;
try {
  const launch = commandLaunch();
  if (usingBunSpawn) {
    child = globalThis.Bun.spawn(
      [launch.executable, ...launch.arguments],
      {
        cwd: workerData.directory,
        env: launch.environment,
        windowsHide: true,
        detached: globalThis.process.platform !== "win32",
        stdin: inherited ? "inherit" : "pipe",
        stdout: inherited ? "inherit" : "pipe",
        stderr: inherited ? "inherit" : "pipe",
      },
    );
    publishChildPid();
    signalStarted();
    const pump = async (stream) => {
      const decoder = new TextDecoder();
      for await (const bytes of stream) {
        publishOutput(decoder.decode(bytes, { stream: true }));
      }
      publishOutput(decoder.decode());
    };
    const stdout = inherited ? Promise.resolve() : pump(child.stdout);
    const stderr = inherited ? Promise.resolve() : pump(child.stderr);
    void Promise.all([stdout, stderr, child.exited])
      .then(([, , exitCode]) => {
        if (terminating) {
          finishTermination();
        } else {
          finishCompleted(exitCode);
        }
      })
      .catch(fail);
  } else {
    child = spawn(launch.executable, launch.arguments, {
      cwd: workerData.directory,
      env: launch.environment,
      windowsHide: true,
      detached: globalThis.process.platform !== "win32",
      stdio: inherited ? "inherit" : ["pipe", "pipe", "pipe"],
    });
    publishChildPid();
    signalStarted();
    if (!inherited) {
      const stdoutDecoder = new StringDecoder("utf8");
      const stderrDecoder = new StringDecoder("utf8");
      child.stdout.on("data", (data) => publishOutput(stdoutDecoder.write(data)));
      child.stdout.on("end", () => publishOutput(stdoutDecoder.end()));
      child.stderr.on("data", (data) => publishOutput(stderrDecoder.write(data)));
      child.stderr.on("end", () => publishOutput(stderrDecoder.end()));
      child.stdin.on("error", fail);
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
    }
    child.on("error", (error) => {
      if (!terminating) {
        finish({ type: "failed", message: String(error.message || error) });
      }
    });
    child.on("close", (exitCode) => {
      if (terminating) {
        finishTermination();
      } else {
        finishCompleted(exitCode);
      }
    });
  }
} catch (error) {
  signalStarted(2);
  finish({ type: "failed", message: String(error.message || error) });
}

port.on("message", (message) => {
  if (message && message.type === "consumed" && streaming && !terminal) {
    const bytes = Number(message.bytes);
    if (Number.isFinite(bytes) && bytes > 0) {
      outputBytes = Math.max(0, outputBytes - bytes);
    }
    return;
  }
  if (message && message.type === "input" && !terminal) {
    inputRequested = true;
    if (
      stdinClosed ||
      !child?.stdin ||
      (!usingBunSpawn && !child.stdin.writable)
    ) {
      terminateTree({ type: "failed", message: "process stdin is not writable" });
      return;
    }
    try {
      if (usingBunSpawn) {
        writeBunInput(String(message.data || ""));
      } else {
        child.stdin.write(String(message.data || ""), (error) => {
          if (error) fail(error);
        });
      }
    } catch (error) {
      fail(error);
    }
    return;
  }
  if (message && message.type === "cancel" && !terminal) {
    terminateTree({ type: "cancelled" });
  }
});

timeout = setTimeout(() => {
  if (!terminal) {
    terminateTree({ type: "failed", message: "process timed out" });
  }
}, Math.max(1, Number(workerData.timeoutMs || 1)));
