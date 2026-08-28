// Human-readable representation of a value for failure messages.
// Strings are shown raw so multi-line diffs work; other values are
// inspected using the Gleam runtime's inspector.
import { inspect } from "../gleam_stdlib/gleam_stdlib.mjs";

export function to_string(value) {
  if (typeof value === "string") {
    return value;
  }
  return inspect(value);
}
