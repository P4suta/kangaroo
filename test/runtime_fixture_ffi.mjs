import { Error as GleamError } from "./gleam.mjs";
import { existsSync, unlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn, spawnSync } from "node:child_process";

const descendantMarker = join(
  tmpdir(),
  `kangaroo-isolate-descendant-${globalThis.process.pid}.marker`,
);
const parallelBarrierPrefix = join(
  tmpdir(),
  `kangaroo-parallel-batch-${globalThis.process.pid}`,
);

function parallelMarker(side) {
  return `${parallelBarrierPrefix}-${side}.marker`;
}

export function reset_parallel_barrier() {
  for (const side of ["left", "right"]) {
    const marker = parallelMarker(side);
    if (existsSync(marker)) unlinkSync(marker);
  }
}

export async function parallel_barrier(side) {
  const other = side === "left" ? "right" : "left";
  writeFileSync(parallelMarker(side), "ready");
  const deadline = Date.now() + 5000;
  while (!existsSync(parallelMarker(other))) {
    if (Date.now() >= deadline) {
      throw new Error("scheduled JavaScript modules did not overlap");
    }
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}

export function promise_pass() {
  return Promise.resolve(undefined);
}

export function promise_reject() {
  return Promise.reject(new Error("async rejected"));
}

export function promise_never() {
  return new Promise(() => {});
}

export function left_value() {
  return 1;
}

export function right_value() {
  return 2;
}

export function error_result() {
  return new GleamError("not an integer");
}

export function left_string() {
  return "same\nold";
}

export function right_string() {
  return "same\nnew";
}

export function non_binary_assert() {
  const error = new Error("synthetic non-binary assert");
  error.gleam_error = "assert";
  error.kind = "guard";
  error.left = { value: 1 };
  error.right = { value: 2 };
  throw error;
}

export function spawn_descendant() {
  const code = `setTimeout(() => require("node:fs").writeFileSync(${JSON.stringify(descendantMarker)}, "survived"), 100);`;
  const parentCode = `const { spawn } = require("node:child_process"); spawn(process.execPath, ["-e", ${JSON.stringify(code)}], { stdio: "ignore" }); setTimeout(() => {}, 1000);`;
  const denoCode = `await new Promise(resolve => setTimeout(resolve, 100)); await Deno.writeTextFile(${JSON.stringify(descendantMarker)}, "survived");`;
  const denoParentCode = `new Deno.Command(Deno.execPath(), { args: ["eval", ${JSON.stringify(denoCode)}], stdout: "null", stderr: "null" }).spawn(); await new Promise(resolve => setTimeout(resolve, 1000));`;
  const deno = typeof globalThis.Deno !== "undefined";
  spawn(
    globalThis.process.execPath,
    deno ? ["eval", denoParentCode] : ["-e", parentCode],
    { stdio: "ignore" },
  );
}

export function spawn_cleanup_race() {
  spawn_descendant();
}

export function spawn_orphan_descendant() {
  const deno = typeof globalThis.Deno !== "undefined";
  const writer = deno
    ? `await new Promise(resolve => setTimeout(resolve, 400)); await Deno.writeTextFile(${JSON.stringify(descendantMarker)}, "survived");`
    : `setTimeout(() => require("node:fs").writeFileSync(${JSON.stringify(descendantMarker)}, "survived"), 400);`;
  const parent = deno
    ? `new Deno.Command(Deno.execPath(), { args: ["eval", ${JSON.stringify(writer)}], stdout: "null", stderr: "null" }).spawn().unref();`
    : `require("node:child_process").spawn(process.execPath, ["-e", ${JSON.stringify(writer)}], { stdio: "ignore" }).unref();`;
  return new Promise((resolve, reject) => {
    const child = spawn(
      globalThis.process.execPath,
      deno ? ["eval", parent] : ["-e", parent],
      { stdio: "ignore" },
    );
    child.once("error", reject);
    child.once("close", resolve);
  });
}

export function spawn_native_orphan_descendant() {
  if (typeof globalThis.Deno !== "undefined") {
    const writer = `await new Promise(resolve => setTimeout(resolve, 100)); await Deno.writeTextFile(${JSON.stringify(descendantMarker)}, "survived");`;
    const parent = `new Deno.Command(Deno.execPath(), { args: ["eval", ${JSON.stringify(writer)}], stdout: "null", stderr: "null" }).spawn().unref();`;
    return new globalThis.Deno.Command(globalThis.Deno.execPath(), {
      args: ["eval", parent],
      stdout: "null",
      stderr: "null",
    }).output();
  }
  if (typeof globalThis.Bun !== "undefined") {
    const writer = `setTimeout(() => require("node:fs").writeFileSync(${JSON.stringify(descendantMarker)}, "survived"), 100);`;
    const parent = `Bun.spawn([process.execPath, "-e", ${JSON.stringify(writer)}], { stdout: "ignore", stderr: "ignore" }).unref();`;
    return globalThis.Bun.spawn(
      [globalThis.process.execPath, "-e", parent],
      { stdout: "ignore", stderr: "ignore" },
    ).exited;
  }
  return Promise.resolve(undefined);
}

export function spawn_port_orphan_descendant() {
  return undefined;
}

export function kill_output_collector() {}

export function kill_test_owner_from_link() {}

export function exit_test_worker() {
  globalThis.process.exit(7);
}

export function spawn_native_descendant() {
  const code = `setTimeout(() => require("node:fs").writeFileSync(${JSON.stringify(descendantMarker)}, "survived"), 100);`;
  if (typeof globalThis.Bun !== "undefined") {
    globalThis.Bun.spawn([globalThis.process.execPath, "-e", code], {
      stdout: "ignore",
      stderr: "ignore",
    });
    return;
  }
  if (typeof globalThis.Deno !== "undefined") {
    const denoCode = `await new Promise(resolve => setTimeout(resolve, 100)); await Deno.writeTextFile(${JSON.stringify(descendantMarker)}, "survived");`;
    new globalThis.Deno.Command(globalThis.Deno.execPath(), {
      args: ["eval", denoCode],
      stdout: "null",
      stderr: "null",
    }).spawn();
    return;
  }
  spawn(globalThis.process.execPath, ["-e", code], { stdio: "ignore" });
}

export function complete_native_child() {
  const code = `require("node:fs").writeFileSync(${JSON.stringify(descendantMarker)}, "completed");`;
  if (typeof globalThis.Bun !== "undefined") {
    return globalThis.Bun.spawn([globalThis.process.execPath, "-e", code], {
      stdin: "ignore",
      stdout: "ignore",
      stderr: "ignore",
    }).exited;
  }
  if (typeof globalThis.Deno !== "undefined") {
    const denoCode = `await Deno.writeTextFile(${JSON.stringify(descendantMarker)}, "completed");`;
    return new globalThis.Deno.Command(globalThis.Deno.execPath(), {
      args: ["eval", denoCode],
      stdin: "null",
      stdout: "null",
      stderr: "null",
    }).output();
  }
  return new Promise((resolve, reject) => {
    const child = spawn(globalThis.process.execPath, ["-e", code], {
      stdio: "ignore",
    });
    child.once("error", reject);
    child.once("exit", code => code === 0
      ? resolve()
      : reject(new Error(`native child exited ${code}`)));
  });
}

export function spawn_synchronous_descendant() {
  if (typeof globalThis.Deno !== "undefined") {
    const writer = `await new Promise(resolve => setTimeout(resolve, 100)); await Deno.writeTextFile(${JSON.stringify(descendantMarker)}, "survived");`;
    const parent = `new Deno.Command(Deno.execPath(), { args: ["eval", ${JSON.stringify(writer)}], stdout: "null", stderr: "null" }).spawn();`;
    new globalThis.Deno.Command(globalThis.Deno.execPath(), {
      args: ["eval", parent],
      stdout: "null",
      stderr: "null",
    }).outputSync();
    return;
  }
  const writer = `setTimeout(() => require("node:fs").writeFileSync(${JSON.stringify(descendantMarker)}, "survived"), 100);`;
  const parent = `require("node:child_process").spawn(process.execPath, ["-e", ${JSON.stringify(writer)}], { stdio: "ignore" }).unref();`;
  if (typeof globalThis.Bun !== "undefined") {
    globalThis.Bun.spawnSync([globalThis.process.execPath, "-e", parent], {
      stdout: "ignore",
      stderr: "ignore",
    });
    return;
  }
  spawnSync(globalThis.process.execPath, ["-e", parent], { stdio: "ignore" });
}

export function native_output_timeout() {
  const nodeCode = `setTimeout(() => require("node:fs").writeFileSync(${JSON.stringify(descendantMarker)}, "survived"), 200);`;
  if (typeof globalThis.Deno !== "undefined") {
    const denoCode = `await new Promise(resolve => setTimeout(resolve, 200)); await Deno.writeTextFile(${JSON.stringify(descendantMarker)}, "survived");`;
    return new globalThis.Deno.Command(globalThis.Deno.execPath(), {
      args: ["eval", denoCode],
      stdout: "null",
      stderr: "null",
    }).output();
  }
  if (typeof globalThis.Bun !== "undefined") {
    return globalThis.Bun.spawn(
      [globalThis.process.execPath, "-e", nodeCode],
      { stdout: "ignore", stderr: "ignore" },
    ).exited;
  }
  return new Promise((resolve, reject) => {
    const child = spawn(globalThis.process.execPath, ["-e", nodeCode], {
      stdio: "ignore",
    });
    child.once("error", reject);
    child.once("exit", resolve);
  });
}

export function synchronous_timeout() {
  if (typeof globalThis.Deno !== "undefined") {
    new globalThis.Deno.Command(globalThis.Deno.execPath(), {
      args: [
        "eval",
        `await new Promise(resolve => setTimeout(resolve, 200)); await Deno.writeTextFile(${JSON.stringify(descendantMarker)}, "survived");`,
      ],
      stdout: "null",
      stderr: "null",
    }).outputSync();
    return;
  }
  const code = `setTimeout(() => require("node:fs").writeFileSync(${JSON.stringify(descendantMarker)}, "survived"), 200);`;
  if (typeof globalThis.Bun !== "undefined") {
    globalThis.Bun.spawnSync([globalThis.process.execPath, "-e", code], {
      stdout: "ignore",
      stderr: "ignore",
    });
    return;
  }
  spawnSync(globalThis.process.execPath, ["-e", code], { stdio: "ignore" });
}

export function reset_descendant_marker() {
  if (existsSync(descendantMarker)) unlinkSync(descendantMarker);
}

export function descendant_marker_exists() {
  return existsSync(descendantMarker);
}

export function run_all_crash_cancels_sibling() {
  return true;
}
