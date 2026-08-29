// Captures the source location of the caller from `Error().stack`. The
// relevant frame is picked by the pure `location` module.
import { from_js_stack } from "./kangaroo/location.mjs";

export function capture() {
  return from_js_stack(new Error().stack || "");
}
