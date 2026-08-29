import { spawn, spawnSync } from "node:child_process";
import { workerData } from "node:worker_threads";

const port = workerData.port;
const startup = new Int32Array(workerData.startupBuffer);
let terminal = false;
let cancelled = false;
let timeout;
let terminating = false;
let terminationPids = [];
let output = "";

function signalStarted(status = 1) {
  if (Atomics.compareExchange(startup, 0, 0, status) === 0) {
    Atomics.notify(startup, 0);
  }
}

function finish(message) {
  if (terminal) return;
  terminal = true;
  clearTimeout(timeout);
  port.postMessage(message);
  port.close();
}

function descendants(rootPid) {
  try {
    const listing = spawnSync("ps", ["-eo", "pid=,ppid="], {
      encoding: "utf8",
      windowsHide: true,
    });
    if (listing.error || listing.status !== 0) return [];
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
  terminationPids = descendants(child?.pid);
  killTree(child, "SIGTERM", terminationPids, false);
  terminationPids = [
    ...new Set([...terminationPids, ...descendants(child?.pid)]),
  ];
  killTree(child, "SIGKILL", terminationPids, false);
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
    port.postMessage({ type: "output", data: chunk });
  });
  child.stderr.on("data", (data) => {
    const chunk = data.toString("utf8");
    output += chunk;
    port.postMessage({ type: "output", data: chunk });
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
    child?.stdin?.write(String(message.data || ""));
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
