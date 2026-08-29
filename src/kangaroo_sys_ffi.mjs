// Small platform services: monotonic clock, environment access, exit.
// `Option$None$const` is the shared None instance; the `None` export is the
// class itself, which must not be returned as a value.
import { Option$None$const, Some } from "../gleam_stdlib/gleam/option.mjs";

export function now_ms() {
  return Date.now();
}

export function env(name) {
  if (typeof process !== "undefined" && process.env) {
    const value = process.env[name];
    return value === undefined ? Option$None$const : new Some(value);
  }
  return Option$None$const;
}

export function halt(code) {
  if (typeof process !== "undefined" && typeof process.exit === "function") {
    process.exit(code);
  }
  return undefined;
}
