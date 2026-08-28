// Collects matcher failures for the currently running test case.
//
// On JavaScript there is no per-process storage, so the isolate module
// saves and restores this array around each case execution. Lists in the
// Gleam runtime are linked lists, so collected failures are converted with
// `toList`.
import { toList } from "./gleam.mjs";

let failures = [];

export function record(failure) {
  failures.push(failure);
  return undefined;
}

// Returns the collected failures as a Gleam list and clears the storage.
export function collect() {
  const collected = toList(failures);
  failures = [];
  return collected;
}

// Returns a copy of the current failures. The isolate module saves this
// before running a case and restores it afterwards; copying is essential
// because recording mutates the shared array.
export function save() {
  return failures.slice();
}

export function restore(previous) {
  failures = previous;
  return undefined;
}
