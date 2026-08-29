import { spawn, spawnSync } from "node:child_process";
import { workerData } from "node:worker_threads";

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

function descendants(rootPid) {
  if (
    !Number.isInteger(rootPid) ||
    rootPid <= 0 ||
    globalThis.process.platform === "win32"
  ) return [];
  try {
    const listing = spawnSync("ps", ["-eo", "pid=,ppid="], {
      encoding: "utf8",
      windowsHide: true,
    });
    // Node can report an EPERM diagnostic alongside a successful status and
    // complete stdout in restricted process namespaces. The listing remains
    // authoritative in that case; discard it only when ps itself failed.
    if (listing.status !== 0 || !listing.stdout) return [];
    const children = new Map();
    for (const line of String(listing.stdout || "").split("\n")) {
      const match = line.trim().match(/^(\d+)\s+(\d+)$/);
      if (!match) continue;
      const pid = Number(match[1]);
      const parent = Number(match[2]);
      const entries = children.get(parent) || [];
      entries.push(pid);
      children.set(parent, entries);
    }
    const found = [];
    const pending = [...(children.get(rootPid) || [])];
    while (pending.length > 0) {
      const pid = pending.shift();
      found.push(pid);
      pending.push(...(children.get(pid) || []));
    }
    return found;
  } catch {
    return [];
  }
}

function signalPidOrGroup(pid, signal) {
  try {
    globalThis.process.kill(-pid, signal);
  } catch {
    try {
      globalThis.process.kill(pid, signal);
    } catch {
      // The process already exited.
    }
  }
}

function killTree(
  child,
  signal = "SIGTERM",
  knownDescendants = [],
  refreshDescendants = true,
) {
  if (!child || child.pid === undefined) return;
  try {
    if (globalThis.process.platform === "win32") {
      spawnSync("taskkill", ["/pid", String(child.pid), "/T", "/F"], {
        windowsHide: true,
        stdio: "ignore",
      });
    } else {
      const targets = [
        ...new Set([
          ...knownDescendants,
          ...(refreshDescendants ? descendants(child.pid) : []),
        ]),
      ].reverse();
      for (const pid of targets) signalPidOrGroup(pid, signal);
      signalPidOrGroup(child.pid, signal);
    }
  } catch {
    try {
      child.kill("SIGKILL");
    } catch {
      // The process already exited.
    }
  }
}

function terminateTree(message) {
  if (terminal || terminating) return;
  terminating = true;
  terminationPids = freezeTree(child);
  killTree(child, "SIGKILL", terminationPids, false);
  // Signal delivery is asynchronous. Do not acknowledge cancellation while a
  // just-killed compiler can still finish a filesystem syscall in the
  // workspace that the caller is about to replace or remove.
  Atomics.wait(terminationPause, 0, 0, 10);
  finish(message);
}

function freezeTree(child) {
  if (
    !child ||
    child.pid === undefined ||
    globalThis.process.platform === "win32"
  ) return descendants(child?.pid);
  const rootPid = child.pid;
  // The spawned root is a process-group leader. Stop the whole group before
  // walking the process table so normal descendants cannot race the snapshot.
  // A single walk is then sufficient to find children that deliberately
  // detached into a different group, keeping cancellation within 250 ms even
  // when a hosted macOS runner is under load.
  signalPidOrGroup(rootPid, "SIGSTOP");
  const known = descendants(rootPid);
  for (const pid of known) signalPidOrGroup(pid, "SIGSTOP");
  return known;
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
