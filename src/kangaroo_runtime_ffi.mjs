// Resolves a compiled Gleam export for the JavaScript runtimes. Node's module
// compatibility API is also implemented by supported Bun and Deno releases.
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { join } from "node:path";
import { Error as GleamError, Ok } from "./gleam.mjs";

const require = createRequire(import.meta.url);

function packageName(projectDir) {
  const toml = readFileSync(join(projectDir, "gleam.toml"), "utf8");
  const match = toml.match(/^\s*name\s*=\s*"([^"]+)"/m);
  if (!match) throw new Error("could not find package name in gleam.toml");
  return match[1];
}

export function resolve_export(moduleName, functionName) {
  try {
    const projectDir = process.cwd();
    const packageDir = join(
      projectDir,
      "build",
      "dev",
      "javascript",
      packageName(projectDir),
    );
    const path = join(packageDir, ...String(moduleName).split("/")) + ".mjs";
    const module = require(path);
    const fun = module[functionName];
    if (typeof fun !== "function" || fun.length !== 0) {
      return new GleamError("not_exported");
    }
    const callable = () => fun();
    Object.defineProperties(callable, {
      kangarooModulePath: { value: path },
      kangarooFunctionName: { value: String(functionName) },
    });
    return new Ok(callable);
  } catch (error) {
    return new GleamError(String(error && error.message ? error.message : error));
  }
}
