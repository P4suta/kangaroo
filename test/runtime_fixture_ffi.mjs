import { Error as GleamError } from "./gleam.mjs";
import { existsSync, unlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn } from "node:child_process";

const descendantMarker = join(
  tmpdir(),
  `kangaroo-isolate-descendant-${globalThis.process.pid}.marker`,
);

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

export function reset_descendant_marker() {
  if (existsSync(descendantMarker)) unlinkSync(descendantMarker);
}

export function descendant_marker_exists() {
  return existsSync(descendantMarker);
}
