import { workerData } from "node:worker_threads";
import { existsSync, readFileSync, unlinkSync } from "node:fs";
import { toList } from "./gleam.mjs";
import {
  Option$None$const,
  Some,
} from "../gleam_stdlib/gleam/option.mjs";
import { IndexedTest } from "./kangaroo/internal/index.mjs";
import { run_batch_wire as runBatchWire } from "./kangaroo/internal/executor.mjs";

const port = workerData.port;
const control = new Int32Array(workerData.controlBuffer);
const activity = new Int32Array(workerData.activityBuffer);

function option(value) {
  return value === null ? Option$None$const : new Some(value);
}

function indexedTest(test) {
  return new IndexedTest(
    test.id,
    test.name,
    test.path,
    test.module,
    test.line,
    test.column,
    test.endLine,
    test.endColumn,
    toList(test.tags),
    option(test.timeoutMs),
    test.serial,
    option(test.skip),
  );
}

function notify(status) {
  Atomics.store(control, 0, status);
  Atomics.add(activity, 0, 1);
  Atomics.notify(activity, 0);
}

globalThis.process?.once?.("exit", () => {
  if (Atomics.load(control, 0) < 2) notify(-1);
});

notify(1);
let wire;
let coverage = "";
try {
  if (workerData.coverageFile !== null) {
    globalThis.process.env.KANGAROO_COVERAGE_FILE = workerData.coverageFile;
    if (existsSync(workerData.coverageFile)) unlinkSync(workerData.coverageFile);
  }
  wire = runBatchWire(
    toList(workerData.tests.map(indexedTest)),
    workerData.defaultTimeoutMs,
    workerData.failFast,
    workerData.retry,
  );
  if (workerData.coverageFile !== null && existsSync(workerData.coverageFile)) {
    try {
      coverage = readFileSync(workerData.coverageFile, "utf8");
    } finally {
      try {
        unlinkSync(workerData.coverageFile);
      } catch {
        // The disposable coverage workspace owns any file which raced cleanup.
      }
    }
  }
} catch (error) {
  wire = `error\n${String(error && error.stack ? error.stack : error)}`;
}
try {
  port.postMessage({ wire, coverage });
  port.close();
  notify(2);
} catch {
  notify(-1);
}
