import { execFileSync } from "node:child_process";

function terminateWindowsTree(pid) {
  // taskkill must observe the tree while its root still exists. Killing the
  // root first can reparent descendants and let them outlive cancellation.
  try {
    execFileSync("taskkill", ["/PID", String(pid), "/T", "/F"], {
      stdio: "ignore",
      windowsHide: true,
    });
    return;
  } catch {
    // Fall back to the directly registered process when taskkill is missing
    // or the process already disappeared during the tree operation.
  }
  try {
    globalThis.process.kill(pid, "SIGKILL");
  } catch {
    // The process may already have exited.
  }
}

function signalPidOrGroup(pid, signal) {
  try {
    globalThis.process.kill(-pid, signal);
  } catch {
    try {
      globalThis.process.kill(pid, signal);
    } catch {
      // The process may already have exited.
    }
  }
}

function processTable() {
  try {
    return String(execFileSync("ps", ["-eo", "pid=,ppid="], {
      encoding: "utf8",
      windowsHide: true,
    }));
  } catch (error) {
    // Some restricted Node hosts attach an EPERM diagnostic after returning
    // a complete process table. Retain that authoritative stdout when it is
    // available; otherwise cancellation still terminates the process group.
    return error && error.stdout ? String(error.stdout) : "";
  }
}

export function processDescendants(rootPid) {
  if (
    !Number.isInteger(rootPid) ||
    rootPid <= 0 ||
    globalThis.process.platform === "win32"
  ) return [];
  const children = new Map();
  for (const row of processTable().split("\n")) {
    const match = row.trim().match(/^(\d+)\s+(\d+)$/);
    if (!match) continue;
    const pid = Number(match[1]);
    const parent = Number(match[2]);
    const entries = children.get(parent) || [];
    entries.push(pid);
    children.set(parent, entries);
  }
  const found = [];
  const seen = new Set([rootPid]);
  const pending = [...(children.get(rootPid) || [])];
  while (pending.length > 0) {
    const pid = pending.shift();
    if (seen.has(pid)) continue;
    seen.add(pid);
    found.push(pid);
    pending.push(...(children.get(pid) || []));
  }
  return found;
}

export function freezeProcessTree(pid) {
  if (
    !Number.isInteger(pid) ||
    pid <= 0 ||
    globalThis.process.platform === "win32"
  ) return [];
  // The registered root is a process-group leader. Stop it before walking
  // the process table so it cannot create or reparent children mid-snapshot.
  signalPidOrGroup(pid, "SIGSTOP");
  const descendants = processDescendants(pid);
  for (const descendant of descendants) {
    signalPidOrGroup(descendant, "SIGSTOP");
  }
  return descendants;
}

export function terminateProcessTree(
  pid,
  { knownDescendants, alreadyFrozen = false, signal = "SIGKILL" } = {},
) {
  if (!Number.isInteger(pid) || pid <= 0) return;
  if (globalThis.process.platform === "win32") {
    terminateWindowsTree(pid);
    return;
  }
  const descendants = Array.isArray(knownDescendants)
    ? [...new Set(knownDescendants)]
    : alreadyFrozen
      ? []
      : freezeProcessTree(pid);
  for (const descendant of descendants.reverse()) {
    signalPidOrGroup(descendant, signal);
  }
  signalPidOrGroup(pid, signal);
}
