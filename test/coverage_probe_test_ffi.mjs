import { readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

let captureOriginal;

export function begin_unwritable_probe_capture() {
  captureOriginal = globalThis.process.env.KANGAROO_COVERAGE_FILE;
  globalThis.process.env.KANGAROO_COVERAGE_FILE = ".";
}

export function complete_unwritable_probe_capture() {
  if (captureOriginal === undefined) {
    delete globalThis.process.env.KANGAROO_COVERAGE_FILE;
  } else {
    globalThis.process.env.KANGAROO_COVERAGE_FILE = captureOriginal;
  }
  captureOriginal = undefined;
}

export function begin_probe_capture() {
  captureOriginal = globalThis.process.env.KANGAROO_COVERAGE_FILE;
  const path = join(
    tmpdir(),
    `kangaroo-probe-causal-${globalThis.process.pid}-${Date.now()}-${Math.random()}`,
  );
  writeFileSync(path, "");
  globalThis.process.env.KANGAROO_COVERAGE_FILE = path;
  return path;
}

export function complete_probe_capture(path) {
  const contents = readFileSync(path, "utf8");
  unlinkSync(path);
  if (captureOriginal === undefined) {
    delete globalThis.process.env.KANGAROO_COVERAGE_FILE;
  } else {
    globalThis.process.env.KANGAROO_COVERAGE_FILE = captureOriginal;
  }
  captureOriginal = undefined;
  return contents;
}
