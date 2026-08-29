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

export function spawn_descendant() {
  const code = `setTimeout(() => require("node:fs").writeFileSync(${JSON.stringify(descendantMarker)}, "survived"), 100);`;
  const denoCode = `await new Promise(resolve => setTimeout(resolve, 100)); await Deno.writeTextFile(${JSON.stringify(descendantMarker)}, "survived");`;
  const deno = typeof globalThis.Deno !== "undefined";
  spawn(globalThis.process.execPath, deno ? ["eval", denoCode] : ["-e", code], {
    stdio: "ignore",
  });
}

export function reset_descendant_marker() {
  if (existsSync(descendantMarker)) unlinkSync(descendantMarker);
}

export function descendant_marker_exists() {
  return existsSync(descendantMarker);
}
