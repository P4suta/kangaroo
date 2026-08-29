import { toList } from "./gleam.mjs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn } from "node:child_process";

let flakyAttempt = 0;
let markerId = 0;

export function reset_flaky() {
  flakyAttempt = 0;
}

export function fail_once() {
  flakyAttempt += 1;
  if (flakyAttempt === 1) {
    const error = new Error("first attempt failed");
    error.gleam_error = "panic";
    throw error;
  }
}

export function sleeper_executable() {
  if (typeof globalThis.Deno !== "undefined") return globalThis.Deno.execPath();
  return globalThis.process.execPath;
}

export function sleeper_arguments(milliseconds) {
  const code = `process.stdout.write("ready"); setTimeout(() => {}, ${milliseconds});`;
  const args =
    typeof globalThis.Deno !== "undefined"
      ? ["eval", `await Deno.stdout.write(new TextEncoder().encode("ready")); await new Promise(resolve => setTimeout(resolve, ${milliseconds}));`]
      : ["-e", code];
  return toList(args);
}

export function echo_arguments() {
  if (typeof globalThis.Deno !== "undefined") {
    return toList([
      "eval",
      "const bytes = new Uint8Array(1024); const count = await Deno.stdin.read(bytes); if (count === null) Deno.exit(2); await Deno.stdout.write(bytes.subarray(0, count));",
    ]);
  }
  return toList([
    "-e",
    "process.stdin.once('data', value => { process.stdout.write(value); process.exit(0); });",
  ]);
}

export function silent_exit_arguments(code) {
  if (typeof globalThis.Deno !== "undefined") {
    return toList(["eval", `Deno.exit(${Number(code)});`]);
  }
  return toList(["-e", `process.exit(${Number(code)});`]);
}

export function tree_marker() {
  markerId += 1;
  return join(
    tmpdir(),
    `kangaroo-tree-${globalThis.process.pid}-${Date.now()}-${markerId}.marker`,
  );
}

export function tree_arguments(marker) {
  if (typeof globalThis.Deno !== "undefined") {
    const child = `await new Promise(resolve => setTimeout(resolve, 400)); await Deno.writeTextFile(${JSON.stringify(marker)}, "survived");`;
    const outer = `const { spawn } = await import("node:child_process"); spawn(Deno.execPath(), ["eval", ${JSON.stringify(child)}], { stdio: "ignore" }); await new Promise(resolve => setTimeout(resolve, 5000));`;
    return toList(["eval", outer]);
  }
  const child = `setTimeout(() => require("node:fs").writeFileSync(${JSON.stringify(marker)}, "survived"), 400);`;
  const outer = `require("node:child_process").spawn(process.execPath, ["-e", ${JSON.stringify(child)}], { stdio: "ignore" }); setTimeout(() => {}, 5000);`;
  return toList(["-e", outer]);
}

export function schedule_replace(path, expected, replacement, delay) {
  const script = `;(async () => {
    const path = ${JSON.stringify(path)};
    const expected = ${JSON.stringify(expected)};
    const replacement = ${JSON.stringify(replacement)};
    await new Promise(resolve => setTimeout(resolve, ${Number(delay)}));
    if (typeof Deno !== "undefined") {
      if (await Deno.readTextFile(path) === expected) await Deno.writeTextFile(path, replacement);
    } else {
      const fs = await import("node:fs");
      if (fs.readFileSync(path, "utf8") === expected) fs.writeFileSync(path, replacement);
    }
  })();`;
  const args =
    typeof globalThis.Deno !== "undefined"
      // Deno 2.9 `eval` has implicit permissions and does not accept the
      // `run` subcommand's --allow-read/--allow-write flags.
      ? ["eval", script]
      : ["-e", script];
  spawn(sleeper_executable(), args, { stdio: "ignore" });
}
