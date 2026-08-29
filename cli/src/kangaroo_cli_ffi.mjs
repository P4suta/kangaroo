// Platform services for the Kangaroo CLI: file access, subprocess
// execution of `gleam test`, and a monotonic clock for the watch loop.
import { readdirSync, readFileSync, rmSync, statSync, existsSync } from "node:fs";
import { join, relative, sep } from "node:path";
import { createRequire } from "node:module";
import { spawnSync } from "node:child_process";
import { Empty, Error as GleamError, Ok, toList } from "./gleam.mjs";
import { Option$None$const, Some } from "../gleam_stdlib/gleam/option.mjs";
import * as $suite from "../kangaroo/kangaroo/suite.mjs";
import { ProcessResult } from "./kangaroo_cli/fs.mjs";

const require = createRequire(import.meta.url);

export function list_files_recursive(directory) {
  try {
    const files = [];
    const walk = (dir) => {
      for (const entry of readdirSync(dir, { withFileTypes: true })) {
        const path = join(dir, entry.name);
        if (entry.isDirectory()) {
          walk(path);
        } else if (entry.isFile()) {
          files.push(path);
        }
      }
    };
    walk(directory);
    files.sort();
    return new Ok(toList(files));
  } catch (error) {
    return new GleamError(String(error.message || error));
  }
}

export function read_file(path) {
  try {
    return new Ok(readFileSync(path, "utf8"));
  } catch (error) {
    return new GleamError(String(error.message || error));
  }
}

export function mtime_ms(path) {
  try {
    return new Ok(Math.floor(statSync(path).mtimeMs));
  } catch (error) {
    return new GleamError(String(error.message || error));
  }
}

export function file_size(path) {
  try {
    return new Ok(statSync(path).size);
  } catch (error) {
    return new GleamError(String(error.message || error));
  }
}

export function exists(path) {
  try {
    statSync(path);
    return true;
  } catch {
    return false;
  }
}

export function sleep(ms) {
  // synchronous sleep keeps the watch loop simple and portable
  const end = Date.now() + ms;
  while (Date.now() < end) {
    /* spin */
  }
  return undefined;
}

export function now_ms() {
  return Date.now();
}

export function current_dir() {
  try {
    return new Ok(process.cwd());
  } catch (error) {
    return new GleamError(String(error.message || error));
  }
}

export function args() {
  return toList(process.argv.slice(2));
}

export function halt(code) {
  process.exit(code);
  return undefined;
}

export function remove_dir(path) {
  try {
    rmSync(path, { recursive: true, force: true });
    return new Ok(undefined);
  } catch (error) {
    return new GleamError(String(error.message || error));
  }
}

export function gleam_executable() {
  // spawnSync resolves executables through PATH on all platforms
  return new Ok("gleam");
}

export function is_erlang() {
  return false;
}

// The in-VM execution engine only exists on Erlang.
export function not_supported(_arg) {
  return new GleamError("in-VM execution is not supported on JavaScript");
}

// In-VM execution on JavaScript loads the compiled `.mjs` test modules into
// this process with `require(esm)`, avoiding a `gleam test` subprocess on
// every run. The compiled modules import each other with relative paths, so
// loaded modules share the module instances (and types) of the CLI itself as
// long as the CLI runs from the project's own build (i.e. as a dev
// dependency). Only the project's own package is purged from the require
// cache before loading, so re-runs see fresh project code while the kangaroo
// runtime keeps its identity.

const loadedModules = new Map();

export function load_js(path) {
  try {
    const marker = "/build/dev/javascript/";
    const index = path.indexOf(marker);
    if (index < 0) {
      return new GleamError(`not a compiled javascript module: ${path}`);
    }
    const base = path.slice(0, index) + marker;
    const packageDir = base + path.slice(index + marker.length, path.indexOf("/", index + marker.length));
    for (const key of Object.keys(require.cache)) {
      if (key.startsWith(packageDir) && key.length > packageDir.length) {
        delete require.cache[key];
      }
    }
    const mod = require(path);
    const moduleName = relative(packageDir, path).replace(/\.mjs$/, "");
    loadedModules.set(moduleName, mod);
    return new Ok(undefined);
  } catch (error) {
    return new GleamError(String(error.message || error));
  }
}

export function call_suites(module) {
  const mod = loadedModules.get(module);
  if (!mod) {
    return new GleamError(`module not loaded: ${module}`);
  }
  if (typeof mod.suites !== "function") {
    return new GleamError(`module does not export a suites function: ${module}`);
  }
  const suites = mod.suites();
  // The suites must share the CLI's kangaroo module instances for type
  // matching to work. A project compiled into a different build tree (or a
  // stale cache) would otherwise make every case silently pass.
  if (!(suites && suites.head instanceof $suite.Suite)) {
    return new GleamError(
      "loaded modules are not compatible with this CLI build",
    );
  }
  return new Ok(suites);
}

export function list_test_modules_js(packageDir) {
  try {
    const modules = [];
    const walk = (dir) => {
      for (const entry of readdirSync(dir, { withFileTypes: true })) {
        const path = join(dir, entry.name);
        if (entry.isDirectory()) {
          walk(path);
        } else if (entry.isFile() && entry.name.endsWith("_test.mjs")) {
          modules.push(relative(packageDir, path).replace(/\.mjs$/, ""));
        }
      }
    };
    if (existsSync(packageDir)) {
      walk(packageDir);
    }
    modules.sort();
    return new Ok(toList(modules));
  } catch (error) {
    return new GleamError(String(error.message || error));
  }
}

// A per-run buffer of runner events.
let events = [];
export function event_buffer_append(event) {
  events.push(event);
  return undefined;
}
export function event_buffer_take() {
  const taken = toList(events);
  events = [];
  return taken;
}

// Terminal access for the TUI. The watch loop is synchronous on
// JavaScript, so keys are read directly from the (non-blocking) terminal
// file descriptor instead of through events.
import { readSync } from "node:fs";

export function is_tty() {
  return Boolean(process.stdin && process.stdin.isTTY);
}
export function raw_mode(on) {
  if (process.stdin && process.stdin.isTTY) {
    process.stdin.setRawMode(Boolean(on));
    process.stdin.resume();
  }
  return undefined;
}
export function init_keyboard() {
  if (process.stdin && process.stdin.isTTY) {
    process.stdin.setRawMode(true);
    process.stdin.resume();
  }
  process.on("SIGINT", () => {
    if (process.stdin && process.stdin.isTTY) process.stdin.setRawMode(false);
    process.exit(130);
  });
  process.on("exit", () => {
    if (process.stdin && process.stdin.isTTY) process.stdin.setRawMode(false);
  });
  return undefined;
}
export function poll_key() {
  const buffer = Buffer.alloc(1);
  try {
    const read = readSync(0, buffer, 0, 1, null);
    if (read > 0) {
      return new Some(buffer.toString("utf8"));
    }
  } catch (error) {
    // EAGAIN means no key is waiting; any other failure is ignored.
  }
  return Option$None$const;
}

export function run_gleam_test(projectDir, extraEnv, timeoutMs) {
  return run_gleam_test_with(projectDir, toList(["test"]), extraEnv, timeoutMs);
}

// Converts a Gleam linked list to a plain JavaScript array.
function listToArray(list) {
  const result = [];
  let current = list;
  while (current !== null && !(current instanceof Empty)) {
    result.push(current.head);
    current = current.tail;
  }
  return result;
}

export function run_gleam_test_with(projectDir, args, extraEnv, timeoutMs) {
  const env = { ...process.env, KANGAROO_JSON: "1" };
  for (const [key, value] of extraEnv) {
    env[key] = value;
  }
  const result = spawnSync("gleam", listToArray(args), {
    cwd: projectDir,
    env,
    encoding: "utf8",
    timeout: timeoutMs,
  });
  if (result.error) {
    return new GleamError(String(result.error.message || result.error));
  }
  const output = (result.stdout || "") + (result.stderr || "");
  return new Ok(
    new ProcessResult(result.status === null ? -1 : result.status, output),
  );
}
