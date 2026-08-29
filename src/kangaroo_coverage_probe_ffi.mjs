import { openSync, writeSync } from "node:fs";

const batchSize = 128;
let initialised = false;
let descriptor;
let records = [];

function initialise() {
  if (initialised) return;
  initialised = true;
  const file = globalThis.process?.env?.KANGAROO_COVERAGE_FILE;
  if (!file) return;
  try {
    descriptor = openSync(file, "a");
  } catch {
    descriptor = undefined;
  }
}

export function hit(path, line) {
  initialise();
  if (descriptor === undefined) return;
  records.push(`${String(path)}\t${Number(line)}\n`);
  if (records.length >= batchSize) flush();
}

export function flush() {
  if (descriptor === undefined || records.length === 0) return;
  const contents = records.join("");
  records = [];
  try {
    writeSync(descriptor, contents);
  } catch {
    // Coverage is best effort and must never change the test outcome.
  }
}
