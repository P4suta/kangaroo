import { openSync, writeSync } from "node:fs";
import { Buffer } from "node:buffer";

const batchSize = 128;
let initialised = false;
let descriptor;
let records = [];
let failure;

function errorMessage(action, error) {
  const detail = error && error.message ? error.message : String(error);
  return `could not ${action} coverage probe file: ${detail}`;
}

function initialise() {
  if (initialised) return;
  initialised = true;
  const file = globalThis.process?.env?.KANGAROO_COVERAGE_FILE;
  if (!file) return;
  try {
    descriptor = openSync(file, "a");
  } catch (error) {
    descriptor = undefined;
    failure = errorMessage("open", error);
  }
}

export function hit(path, line) {
  initialise();
  if (descriptor === undefined) return;
  records.push(`${String(path)}\t${Number(line)}\n`);
  if (records.length >= batchSize) flush();
}

export function flush() {
  initialise();
  if (failure) return failure;
  if (descriptor === undefined || records.length === 0) return undefined;
  const contents = Buffer.from(records.join(""), "utf8");
  try {
    let offset = 0;
    while (offset < contents.length) {
      const written = writeSync(
        descriptor,
        contents,
        offset,
        contents.length - offset,
      );
      if (written <= 0) throw new Error("write made no progress");
      offset += written;
    }
    records = [];
    return undefined;
  } catch (error) {
    records = [];
    failure = errorMessage("write", error);
    return failure;
  }
}
