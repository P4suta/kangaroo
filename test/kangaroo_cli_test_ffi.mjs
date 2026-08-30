import { toList } from "./gleam.mjs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn } from "node:child_process";
import { existsSync, symlinkSync, unlinkSync, writeFileSync } from "node:fs";
import { terminate_active_processes } from "./kangaroo_process_ffi.mjs";
import { isInternalName } from "./kangaroo_windows_job.mjs";

let markerId = 0;
const flakyMarker = join(
  tmpdir(),
  `kangaroo-flaky-${globalThis.process.pid}.marker`,
);

export function reset_flaky() {
  if (existsSync(flakyMarker)) unlinkSync(flakyMarker);
}

export function fail_once() {
  if (!existsSync(flakyMarker)) {
    writeFileSync(flakyMarker, "failed once");
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
  const code = `require("node:fs").writeSync(1, "ready"); setTimeout(() => {}, ${milliseconds});`;
  const args =
    typeof globalThis.Deno !== "undefined"
      ? ["eval", `Deno.stdout.writeSync(new TextEncoder().encode("ready")); await new Promise(resolve => setTimeout(resolve, ${milliseconds}));`]
      : ["-e", code];
  return toList(args);
}

export function echo_arguments() {
  if (typeof globalThis.Deno !== "undefined") {
    return toList([
      "eval",
      "const bytes = new Uint8Array(1024); const count = await Deno.stdin.read(bytes); if (count === null) Deno.exit(2); Deno.stdout.writeSync(bytes.subarray(0, count));",
    ]);
  }
  return toList([
    "-e",
    "const fs = require('node:fs'); const bytes = Buffer.alloc(1024); const count = fs.readSync(0, bytes, 0, bytes.length, null); if (count === 0) process.exit(2); fs.writeSync(1, bytes, 0, count);",
  ]);
}

export function argument_echo_arguments(value) {
  if (typeof globalThis.Deno !== "undefined") {
    return toList([
      "eval",
      "Deno.stdout.writeSync(new TextEncoder().encode(Deno.args[0] + '|' + Deno.env.get('KANGAROO_PROCESS_TEST_ENV')));",
      value,
    ]);
  }
  return toList([
    "-e",
    "require('node:fs').writeSync(1, process.argv[1] + '|' + process.env.KANGAROO_PROCESS_TEST_ENV);",
    value,
  ]);
}

export function split_utf8_arguments() {
  const first = "new Uint8Array([65, 240, 159])";
  const second = "new Uint8Array([166, 152, 66])";
  if (typeof globalThis.Deno !== "undefined") {
    return toList([
      "eval",
      `Deno.stdout.writeSync(${first}); await new Promise(resolve => setTimeout(resolve, 40)); Deno.stdout.writeSync(${second}); await new Promise(resolve => setTimeout(resolve, 20));`,
    ]);
  }
  return toList([
    "-e",
    `const fs = require("node:fs"); fs.writeSync(1, ${first}); setTimeout(() => { fs.writeSync(1, ${second}); }, 40); setTimeout(() => {}, 60);`,
  ]);
}

export function invalid_utf8_arguments() {
  const bytes = "new Uint8Array([65, 255, 66])";
  if (typeof globalThis.Deno !== "undefined") {
    return toList(["eval", `Deno.stdout.writeSync(${bytes});`]);
  }
  return toList([
    "-e",
    `require("node:fs").writeSync(1, ${bytes});`,
  ]);
}

export function oversized_output_arguments() {
  if (typeof globalThis.Deno !== "undefined") {
    return toList([
      "eval",
      "const chunk = new Uint8Array(16384).fill(97); for (let index = 0; index < 1024; index += 1) Deno.stdout.writeSync(chunk); Deno.stdout.writeSync(new Uint8Array([97]));",
    ]);
  }
  return toList([
    "-e",
    "const fs = require('node:fs'); const chunk = Buffer.alloc(16384, 97); for (let index = 0; index < 1024; index += 1) fs.writeSync(1, chunk); fs.writeSync(1, Buffer.from([97]));",
  ]);
}

export function oversized_split_output_arguments() {
  if (typeof globalThis.Deno !== "undefined") {
    return toList([
      "eval",
      "const chunk = new Uint8Array(16384).fill(97); for (let index = 0; index < 512; index += 1) { Deno.stdout.writeSync(chunk); Deno.stderr.writeSync(chunk); } Deno.stdout.writeSync(new Uint8Array([97]));",
    ]);
  }
  return toList([
    "-e",
    "const fs = require('node:fs'); const chunk = Buffer.alloc(16384, 97); for (let index = 0; index < 512; index += 1) { fs.writeSync(1, chunk); fs.writeSync(2, chunk); } fs.writeSync(1, Buffer.from([97]));",
  ]);
}

export function invalid_utf8_expansion_arguments() {
  const deno = typeof globalThis.Deno !== "undefined";
  const write = deno
    ? "Deno.stdout.writeSync(chunk)"
    : "require('node:fs').writeSync(1, chunk)";
  const chunk = deno
    ? "new Uint8Array(65536).fill(255)"
    : "Buffer.alloc(65536, 255)";
  const code = `const chunk = ${chunk}; for (let index = 0; index < 86; index += 1) ${write};`;
  return toList(deno ? ["eval", code] : ["-e", code]);
}

export function streaming_output_arguments() {
  if (typeof globalThis.Deno !== "undefined") {
    return toList([
      "eval",
      "const chunk = new Uint8Array(1024).fill(97); while (true) { Deno.stdout.writeSync(chunk); await new Promise(resolve => setTimeout(resolve, 1)); }",
    ]);
  }
  return toList([
    "-e",
    "const fs = require('node:fs'); const chunk = Buffer.alloc(1024, 97); const timer = setInterval(() => fs.writeSync(1, chunk), 1); process.stdout.on('error', () => clearInterval(timer));",
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
    const outer = `const { spawn } = await import("node:child_process"); spawn(Deno.execPath(), ["eval", ${JSON.stringify(child)}], { stdio: "ignore" }); Deno.stdout.writeSync(new TextEncoder().encode("ready")); await new Promise(resolve => setTimeout(resolve, 5000));`;
    return toList(["eval", outer]);
  }
  const child = `setTimeout(() => require("node:fs").writeFileSync(${JSON.stringify(marker)}, "survived"), 400);`;
  const outer = `const fs = require("node:fs"); require("node:child_process").spawn(process.execPath, ["-e", ${JSON.stringify(child)}], { stdio: "ignore" }); fs.writeSync(1, "ready"); setTimeout(() => {}, 5000);`;
  return toList(["-e", outer]);
}

export function cleanup_active_processes() {
  terminate_active_processes();
}

export function internal_windows_job_name(name) {
  return isInternalName(name);
}

export function orphan_tree_arguments(marker) {
  if (typeof globalThis.Deno !== "undefined") {
    const child = `await new Promise(resolve => setTimeout(resolve, 1200)); await Deno.writeTextFile(${JSON.stringify(marker)}, "survived");`;
    const outer = `new Deno.Command(Deno.execPath(), { args: ["eval", ${JSON.stringify(child)}], stdin: "null", stdout: "null", stderr: "null" }).spawn(); Deno.exit(0);`;
    return toList(["eval", outer]);
  }
  const child = `setTimeout(() => require("node:fs").writeFileSync(${JSON.stringify(marker)}, "survived"), 1200);`;
  const outer = `require("node:child_process").spawn(process.execPath, ["-e", ${JSON.stringify(child)}], { stdio: "ignore" }); process.exit(0);`;
  return toList(["-e", outer]);
}

export function orphan_tree_executable() {
  return sleeper_executable();
}

export function closed_stdin_tree_arguments(marker) {
  if (typeof globalThis.Deno !== "undefined") {
    const child = `await new Promise(resolve => setTimeout(resolve, 400)); await Deno.writeTextFile(${JSON.stringify(marker)}, "survived");`;
    const outer = `Deno.stdin.close(); new Deno.Command(Deno.execPath(), { args: ["eval", ${JSON.stringify(child)}], stdout: "null", stderr: "null" }).spawn(); Deno.stdout.writeSync(new TextEncoder().encode("ready")); await new Promise(resolve => setTimeout(resolve, 5000));`;
    return toList(["eval", outer]);
  }
  // Windows does not consistently report EPIPE when this process closes the
  // read end. Delay the marker past the process timeout so the test can verify
  // that the timeout fallback still terminates the complete taskkill tree.
  const markerDelay = globalThis.process.platform === "win32" ? 3500 : 400;
  const child = `setTimeout(() => require("node:fs").writeFileSync(${JSON.stringify(marker)}, "survived"), ${markerDelay});`;
  const outer = `const fs = require("node:fs"); const input = process.stdin; input.once("close", () => { const child = require("node:child_process").spawn(process.execPath, ["-e", ${JSON.stringify(child)}], { detached: true, stdio: "ignore" }); child.unref(); fs.writeSync(1, "re"); setTimeout(() => fs.writeSync(1, "ady"), 20); setTimeout(() => {}, 5000); }); input.destroy(); fs.closeSync(0);`;
  return toList(["-e", outer]);
}

export function closed_stdin_executable() {
  return sleeper_executable();
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
  const child = spawn(sleeper_executable(), args, { stdio: "ignore" });
  child.on("error", () => {});
  child.unref?.();
}

export function make_directory_symlink(target, link) {
  try {
    symlinkSync(target, link, "dir");
    return true;
  } catch {
    return false;
  }
}

export function kill_stderr_proxy() {}
