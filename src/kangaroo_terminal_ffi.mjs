import { readSync } from "node:fs";
import { Option$None$const, Some } from "../gleam_stdlib/gleam/option.mjs";

let uiActive = false;

function runtimeProcess() {
  return typeof globalThis.process === "object" ? globalThis.process : undefined;
}

export function stdout_is_terminal() {
  const process = runtimeProcess();
  if (process?.stdout) return process.stdout.isTTY === true;
  if (typeof globalThis.Deno === "object" && globalThis.Deno.stdout?.isTerminal) {
    return globalThis.Deno.stdout.isTerminal();
  }
  return false;
}

export function interactive_terminal() {
  const process = runtimeProcess();
  if (process?.stdin && process?.stdout) {
    return process.stdin.isTTY === true && process.stdout.isTTY === true;
  }
  return false;
}

export function dimensions() {
  const process = runtimeProcess();
  return [
    Number(process?.stdout?.columns || 80),
    Number(process?.stdout?.rows || 24),
  ];
}

function rawMode(on) {
  if (!interactive_terminal()) return;
  const process = runtimeProcess();
  process.stdin.setRawMode?.(Boolean(on));
  if (on) process.stdin.resume?.();
  process.stdout.write(on ? "\u001b[?1049h" : "\u001b[?1049l");
  uiActive = Boolean(on);
}

export function with_ui(body) {
  if (!interactive_terminal()) return body();
  const process = runtimeProcess();
  const restore = () => rawMode(false);
  process.once("exit", restore);
  rawMode(true);
  try {
    return body();
  } finally {
    rawMode(false);
    process.removeListener("exit", restore);
  }
}

export function suspend(body) {
  if (!uiActive) return body();
  rawMode(false);
  try {
    return body();
  } finally {
    rawMode(true);
  }
}

export function poll_key() {
  if (!uiActive) return Option$None$const;
  const buffer = Buffer.alloc(4);
  try {
    const read = readSync(0, buffer, 0, 4, null);
    if (read > 0) return new Some(buffer.subarray(0, read).toString("utf8"));
  } catch {
    // EAGAIN means no key is currently waiting.
  }
  return Option$None$const;
}
