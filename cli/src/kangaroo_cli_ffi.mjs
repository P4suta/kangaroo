// Platform services for the Kangaroo CLI: file access, subprocess
// execution of `gleam test`, and a monotonic clock for the watch loop.
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { Error as GleamError, Ok, toList } from "./gleam.mjs";
import { ProcessResult } from "./kangaroo_cli/fs.mjs";

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
// JavaScript, so keyboard input is not supported yet.
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
  return undefined;
}
export function poll_key() {
  return { tag: "None" };
}

export function run_gleam_test(projectDir, extraEnv, timeoutMs) {
  const env = { ...process.env, KANGAROO_JSON: "1" };
  for (const [key, value] of extraEnv) {
    env[key] = value;
  }
  const result = spawnSync("gleam", ["test"], {
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
