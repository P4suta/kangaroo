// Human-readable representation of a value for failure messages.
// Strings are shown raw so multi-line diffs work; other values are
// inspected using the Gleam runtime's inspector. Long values are truncated
// so that a single failure cannot flood the terminal.
import { inspect } from "../gleam_stdlib/gleam_stdlib.mjs";

const MAX_CHARS = 1000;

export function to_string(value) {
  const text = typeof value === "string" ? value : inspect(value);
  if (text.length <= MAX_CHARS) {
    return text;
  }
  return text.slice(0, MAX_CHARS) + `\n... (${text.length - MAX_CHARS} more characters)`;
}
