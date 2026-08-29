import { hit } from "./kangaroo_coverage_probe_ffi.mjs";

export function hit_unwritable_target() {
  const original = globalThis.process.env.KANGAROO_COVERAGE_FILE;
  globalThis.process.env.KANGAROO_COVERAGE_FILE = ".";
  try {
    hit("src/example.gleam", 1);
  } finally {
    if (original === undefined) {
      delete globalThis.process.env.KANGAROO_COVERAGE_FILE;
    } else {
      globalThis.process.env.KANGAROO_COVERAGE_FILE = original;
    }
  }
}
