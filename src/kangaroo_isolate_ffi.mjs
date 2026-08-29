// Runs a test case body in isolation, catching any error it raises and
// reporting the matcher failures it recorded. The previous failure context
// is saved and restored so that nested runs (cases that themselves run
// cases) stay isolated from each other.
import { CaughtError, Completed, Crashed } from "./kangaroo/isolate.mjs";
import { from_js_stack } from "./kangaroo/location.mjs";
import { collect, restore, save } from "./kangaroo_context_ffi.mjs";

export function isolate(body, timeout_ms) {
  const previous = save();
  try {
    body();
    return new Completed(collect());
  } catch (error) {
    const name =
      error && error.gleam_error === "panic"
        ? "panic"
        : error && error.name
          ? String(error.name)
          : "error";
    const message =
      error && error.message ? String(error.message) : String(error);
    const stack = error && error.stack ? String(error.stack) : "";
    return new Crashed(new CaughtError(name, message, from_js_stack(stack)));
  } finally {
    restore(previous);
  }
}
