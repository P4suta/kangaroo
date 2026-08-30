import { availableParallelism } from "node:os";
import { fileURLToPath } from "node:url";
import { appendFileSync } from "node:fs";
import {
  MessageChannel,
  Worker,
  receiveMessageOnPort,
} from "node:worker_threads";
import { Empty, toList } from "./gleam.mjs";

const batchWorkerUrl = new URL("./kangaroo_batch_worker.mjs", import.meta.url);
let nextBatchRun = 1;

function listToArray(list) {
  const values = [];
  for (let node = list; node && !(node instanceof Empty); node = node.tail) {
    values.push(node.head);
  }
  return values;
}

export function run_all(functions) {
  return toList(listToArray(functions).map((fun) => fun()));
}

function optionValue(option) {
  return option && Object.hasOwn(option, 0) ? option[0] : null;
}

function plainTest(test) {
  return {
    id: test.id,
    name: test.name,
    path: test.path,
    module: test.module,
    line: test.line,
    column: test.column,
    endLine: test.end_line,
    endColumn: test.end_column,
    tags: listToArray(test.tags),
    timeoutMs: optionValue(test.timeout_ms),
    serial: test.serial,
    skip: optionValue(test.skip),
  };
}

function errorText(error) {
  return String(error && error.stack ? error.stack : error);
}

function runtimeBudget(tests, defaultTimeoutMs, retry) {
  const attempts = Math.max(1, Number(retry) + 1);
  return tests.reduce((total, test) => {
    const timeout = Number(test.timeoutMs ?? defaultTimeoutMs);
    // Each isolated test has a separate 30 second Worker-start guard before
    // its requested body timeout begins.
    return total + (Math.max(1, timeout) * attempts) + 30_000;
  }, 30_000);
}

export function run_batches(
  batches,
  defaultTimeoutMs,
  failFast,
  retry,
) {
  const values = listToArray(batches).map((batch) => ({
    tests: listToArray(batch.tests).map(plainTest),
  }));
  const coverageFile = globalThis.process.env.KANGAROO_COVERAGE_FILE || null;
  const batchRun = nextBatchRun++;
  const activity = new Int32Array(new SharedArrayBuffer(4));
  const active = [];
  try {
    values.forEach((batch, index) => {
      const { port1, port2 } = new MessageChannel();
      const control = new Int32Array(new SharedArrayBuffer(4));
      const worker = new Worker(batchWorkerUrl, {
        workerData: {
          port: port2,
          controlBuffer: control.buffer,
          activityBuffer: activity.buffer,
          tests: batch.tests,
          defaultTimeoutMs,
          failFast,
          retry,
          coverageFile: coverageFile === null
            ? null
            : `${coverageFile}.batch-${globalThis.process.pid}-${batchRun}-${index}`,
        },
        transferList: [port2],
      });
      active.push({ index, worker, port: port1, control, wire: null });
    });
  } catch (error) {
    for (const entry of active) {
      entry.port.close();
      void entry.worker.terminate();
    }
    return toList(values.map(() => `error\n${errorText(error)}`));
  }

  const startupDeadline = Date.now() + 30_000;
  const maximumRuntime = Math.max(
    1,
    ...values.map((batch) =>
      runtimeBudget(batch.tests, defaultTimeoutMs, retry)),
  );
  let executionDeadline = null;
  let remaining = active.length;
  let observedActivity = Atomics.load(activity, 0);
  let failure = null;
  while (remaining > 0 && failure === null) {
    for (const entry of active) {
      if (entry.wire !== null) continue;
      const received = receiveMessageOnPort(entry.port);
      if (!received) continue;
      const message = received.message;
      entry.wire = typeof message?.wire === "string"
        ? message.wire
        : "error\nparallel JavaScript batch returned an invalid message";
      entry.coverage = typeof message?.coverage === "string"
        ? message.coverage
        : "";
      entry.port.close();
      void entry.worker.terminate();
      remaining -= 1;
    }
    if (remaining === 0) break;
    const now = Date.now();
    const stopped = active.find((entry) => Atomics.load(entry.control, 0) < 0);
    if (stopped) {
      failure = `parallel JavaScript batch Worker ${stopped.index + 1}` +
        " exited before publishing a result";
      break;
    }
    const allStarted = active.every((entry) => Atomics.load(entry.control, 0) > 0);
    if (!allStarted && now >= startupDeadline) {
      failure = "parallel JavaScript batch Worker did not start within 30000 ms";
      break;
    }
    if (allStarted && executionDeadline === null) {
      executionDeadline = now + maximumRuntime;
    }
    if (executionDeadline !== null && now >= executionDeadline) {
      failure = "parallel JavaScript batch Worker exceeded its execution deadline";
      break;
    }
    Atomics.wait(activity, 0, observedActivity, 25);
    observedActivity = Atomics.load(activity, 0);
  }

  if (failure !== null) {
    for (const entry of active) {
      entry.port.close();
      void entry.worker.terminate();
    }
    return toList(values.map(() => `error\n${failure}`));
  }
  if (coverageFile !== null) {
    try {
      appendFileSync(
        coverageFile,
        active
          .sort((left, right) => left.index - right.index)
          .map((entry) => entry.coverage)
          .join(""),
        "utf8",
      );
    } catch (error) {
      return toList(values.map(() =>
        `error\ncould not merge parallel coverage probes: ${errorText(error)}`));
    }
  }
  return toList(active
    .sort((left, right) => left.index - right.index)
    .map((entry) => entry.wire));
}

export function worker_count() {
  return Math.max(1, availableParallelism());
}

export function target() {
  return "javascript";
}

export function runtime_name() {
  if (typeof globalThis.Bun !== "undefined") return "bun";
  if (typeof globalThis.Deno !== "undefined") return "deno";
  return "node";
}

export function runtime_version() {
  if (typeof globalThis.Bun !== "undefined") return String(globalThis.Bun.version);
  if (typeof globalThis.Deno !== "undefined") return String(globalThis.Deno.version.deno);
  return String(globalThis.process.versions.node);
}

export function operating_system() {
  const platform = globalThis.process.platform;
  if (platform === "win32") return "windows";
  if (platform === "darwin") return "macos";
  if (platform === "linux") return "linux";
  return String(platform);
}

export function daemon_runner_path() {
  return fileURLToPath(new URL("./kangaroo_daemon_child.mjs", import.meta.url));
}

export function shuffle_seed() {
  return Date.now();
}
