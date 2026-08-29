import { availableParallelism } from "node:os";
import { Empty, toList } from "./gleam.mjs";

function listToArray(list) {
  const values = [];
  for (let node = list; node && !(node instanceof Empty); node = node.tail) {
    values.push(node.head);
  }
  return values;
}

export function run_all(functions) {
  return toList(listToArray(functions).map((fun) => fun()));
}

export function worker_count() {
  return Math.max(1, availableParallelism());
}

export function target() {
  return "javascript";
}

export function runtime_name() {
  if (typeof globalThis.Bun !== "undefined") return "bun";
  if (typeof globalThis.Deno !== "undefined") return "deno";
  return "node";
}

export function runtime_version() {
  if (typeof globalThis.Bun !== "undefined") return String(globalThis.Bun.version);
  if (typeof globalThis.Deno !== "undefined") return String(globalThis.Deno.version.deno);
  return String(globalThis.process.versions.node);
}

export function operating_system() {
  const platform = globalThis.process.platform;
  if (platform === "win32") return "windows";
  if (platform === "darwin") return "macos";
  if (platform === "linux") return "linux";
  return String(platform);
}

export function shuffle_seed() {
  return Date.now();
}
