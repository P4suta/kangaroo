// Small platform services: monotonic clock, environment access, exit.
import { None, Some } from "../gleam_stdlib/gleam/option.mjs";

export function now_ms() {
  return Date.now();
}

export function env(name) {
  if (typeof process !== "undefined" && process.env) {
    const value = process.env[name];
    return value === undefined ? { tag: "None" } : new Some(value);
  }
  return { tag: "None" };
}

export function halt(code) {
  if (typeof process !== "undefined" && typeof process.exit === "function") {
    process.exit(code);
  }
  return undefined;
}
