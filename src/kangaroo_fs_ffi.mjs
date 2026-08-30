import {
  existsSync,
  copyFileSync,
  chmodSync,
  lstatSync,
  mkdtempSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  readSync,
  renameSync,
  rmdirSync,
  rmSync,
  statSync,
  writeFileSync,
  writeSync,
} from "node:fs";
import {
  basename,
  dirname,
  isAbsolute,
  join,
  relative,
  resolve,
  sep,
} from "node:path";
import { tmpdir } from "node:os";
import { Error as GleamError, Ok, toList } from "./gleam.mjs";
import { Option$None$const, Some } from "../gleam_stdlib/gleam/option.mjs";
import {
  InputEnd,
  InputError,
  InputLine,
  InputPending,
} from "./kangaroo/internal/fs.mjs";
import {
  MessageChannel,
  Worker,
  receiveMessageOnPort,
} from "node:worker_threads";

let inputEnded = false;
let inputReader;
const inputWorkerUrl = new URL("./kangaroo_stdin_worker.mjs", import.meta.url);
const activityBufferKey = Symbol.for("kangaroo.activityBuffer");
const activityBuffer =
  globalThis[activityBufferKey] ||
  new SharedArrayBuffer(Int32Array.BYTES_PER_ELEMENT);
globalThis[activityBufferKey] = activityBuffer;
const activity = new Int32Array(activityBuffer);
let observedActivity = Atomics.load(activity, 0);
const coverageOwnerMarker = ".kangaroo-coverage-owner";

export function list_files_recursive(directory) {
  try {
    const files = [];
    const walk = (dir) => {
      for (const entry of readdirSync(dir, { withFileTypes: true })) {
        const path = join(dir, entry.name);
        if (entry.isDirectory()) walk(path);
        else if (entry.isFile()) files.push(path);
      }
    };
    walk(directory);
    files.sort();
    return new Ok(toList(files));
  } catch (error) {
    return new GleamError(String(error && error.message ? error.message : error));
  }
}

export function list_workspace_files_recursive(directory) {
  try {
    const files = [];
    const walk = (dir, workspaceRoot = false) => {
      const packageRoot = workspaceRoot || isPackageRoot(dir);
      for (const entry of readdirSync(dir, { withFileTypes: true })) {
        if (workspaceEntryExcludedAt(entry.name, packageRoot)) continue;
        const path = join(dir, entry.name);
        if (entry.isDirectory()) walk(path);
        else if (entry.isFile()) files.push(path);
      }
    };
    walk(directory, true);
    files.sort();
    return new Ok(toList(files));
  } catch (error) {
    return new GleamError(String(error && error.message ? error.message : error));
  }
}

export function list_source_files_recursive(directory) {
  try {
    const files = [];
    const walk = (dir) => {
      const packageRoot = isPackageRoot(dir);
      for (const entry of readdirSync(dir, { withFileTypes: true })) {
        if (workspaceEntryExcludedAt(entry.name, packageRoot)) continue;
        const path = join(dir, entry.name);
        if (entry.isDirectory()) walk(path);
        else if (entry.isFile()) files.push(path);
      }
    };
    walk(directory);
    files.sort();
    return new Ok(toList(files));
  } catch (error) {
    return new GleamError(String(error && error.message ? error.message : error));
  }
}

export function read_file(path) {
  try {
    return new Ok(readFileSync(path, "utf8"));
  } catch (error) {
    return new GleamError(String(error && error.message ? error.message : error));
  }
}

export function exists(path) {
  return existsSync(path);
}

export function is_directory(path) {
  try {
    return statSync(path).isDirectory();
  } catch {
    return false;
  }
}

export function sleep(milliseconds) {
  const buffer = new SharedArrayBuffer(Int32Array.BYTES_PER_ELEMENT);
  Atomics.wait(new Int32Array(buffer), 0, 0, Math.max(0, milliseconds));
}

export function remove_file(path) {
  try {
    rmSync(path, { force: true });
    return new Ok(undefined);
  } catch (error) {
    return new GleamError(String(error && error.message ? error.message : error));
  }
}

const workspaceUniversalExcludes = new Set([
  ".git",
  ".kangaroo",
  ".vscode-test",
  "node_modules",
]);
const workspacePackageExcludes = new Set(["build", "coverage"]);

export function workspace_entry_excluded(name) {
  return workspaceEntryExcludedAt(name, true);
}

function workspaceEntryExcludedAt(name, packageRoot) {
  const value = String(name);
  return workspaceUniversalExcludes.has(value) ||
    (packageRoot && workspacePackageExcludes.has(value)) ||
    value.startsWith(".kangaroo-coverage-");
}

function isPackageRoot(directory) {
  try {
    const info = lstatSync(join(directory, "gleam.toml"));
    return info.isFile() && !info.isSymbolicLink();
  } catch {
    return false;
  }
}

export function copy_to_temporary_workspace(projectDir) {
  let destination;
  let ownerWritten = false;
  try {
    const source = resolve(String(projectDir));
    try {
      destination = mkdtempSync(join(dirname(source), ".kangaroo-coverage-"));
    } catch (error) {
      if (error?.code !== "EACCES" && error?.code !== "EROFS") throw error;
      destination = mkdtempSync(join(tmpdir(), ".kangaroo-coverage-"));
    }
    writeFileSync(join(destination, coverageOwnerMarker), destination, {
      encoding: "utf8",
      flag: "wx",
    });
    ownerWritten = true;
    copyDirectory(source, destination, true, true);
    return new Ok(destination);
  } catch (error) {
    const primary = String(error && error.message ? error.message : error);
    if (!destination) return new GleamError(primary);
    try {
      // Before ownership is recorded, only an empty directory can safely be
      // removed. Afterwards use the same marker validation as public cleanup
      // so an externally replaced path can never redirect recursive deletion.
      if (ownerWritten) removeOwnedCoverageWorkspace(destination);
      else rmdirSync(destination);
      return new GleamError(primary);
    } catch (cleanupError) {
      const cleanup = String(
        cleanupError && cleanupError.message
          ? cleanupError.message
          : cleanupError,
      );
      return new GleamError(
        `${primary}\ncould not remove coverage workspace: ${cleanup}`,
      );
    }
  }
}

function copyDirectory(
  source,
  destination,
  includeDependencyCache = false,
  workspaceRoot = false,
) {
  const packageRoot = workspaceRoot || isPackageRoot(source);
  for (const entry of readdirSync(source, { withFileTypes: true })) {
    if (includeDependencyCache && packageRoot && entry.name === "build") {
      copyDependencyCache(source, destination);
      continue;
    }
    if (workspaceEntryExcludedAt(entry.name, packageRoot)) continue;
    const from = join(source, entry.name);
    const to = join(destination, entry.name);
    const info = lstatSync(from);
    if (info.isSymbolicLink()) continue;
    if (info.isDirectory()) {
      mkdirSync(to);
      chmodSync(to, info.mode);
      copyDirectory(from, to, includeDependencyCache);
    } else if (info.isFile()) {
      copyFileSync(from, to);
      chmodSync(to, info.mode);
    }
  }
}

function copyDependencyCache(source, destination) {
  const sourceBuild = join(source, "build");
  const from = join(sourceBuild, "packages");
  let info;
  try {
    info = lstatSync(from);
  } catch (error) {
    if (error?.code === "ENOENT") return;
    throw error;
  }
  if (info.isSymbolicLink() || !info.isDirectory()) return;

  const toBuild = join(destination, "build");
  const to = join(toBuild, "packages");
  mkdirSync(toBuild);
  chmodSync(toBuild, lstatSync(sourceBuild).mode);
  mkdirSync(to);
  chmodSync(to, info.mode);
  copyDirectory(from, to, false);
}

export function remove_tree(path) {
  try {
    removeOwnedCoverageWorkspace(resolve(String(path)));
    return new Ok(undefined);
  } catch (error) {
    return new GleamError(String(error && error.message ? error.message : error));
  }
}

function removeOwnedCoverageWorkspace(value) {
  if (!basename(value).startsWith(".kangaroo-coverage-")) {
    throw new Error("refusing to remove a non-coverage workspace");
  }
  let workspaceInfo;
  try {
    workspaceInfo = lstatSync(value);
  } catch (error) {
    if (error?.code === "ENOENT") return;
    throw error;
  }
  const marker = join(value, coverageOwnerMarker);
  let markerInfo;
  try {
    markerInfo = lstatSync(marker);
  } catch {
    throw new Error(
      "refusing to remove a coverage workspace without its ownership marker",
    );
  }
  if (
    !workspaceInfo.isDirectory() ||
    workspaceInfo.isSymbolicLink() ||
    !markerInfo.isFile() ||
    markerInfo.isSymbolicLink() ||
    readFileSync(marker, "utf8") !== value
  ) {
    throw new Error(
      "refusing to remove a coverage workspace without its ownership marker",
    );
  }
  rmSync(value, { recursive: true, force: true });
}

export function write_exclusive(path, contents) {
  try {
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, contents, { encoding: "utf8", flag: "wx" });
    return new Ok(undefined);
  } catch (error) {
    return new GleamError(String(error && error.message ? error.message : error));
  }
}

export function write_file(path, contents) {
  try {
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, contents, { encoding: "utf8" });
    return new Ok(undefined);
  } catch (error) {
    return new GleamError(String(error && error.message ? error.message : error));
  }
}

export function project_file_path(projectDir, relativePath) {
  try {
    const root = resolve(String(projectDir));
    const raw = String(relativePath).replaceAll("\\", "/");
    const components = raw.split("/");
    if (
      !raw ||
      isAbsolute(raw) ||
      /^[A-Za-z]:/.test(raw) ||
      components.some((component) =>
        component === "" || component === "." || component === ".."
      )
    ) {
      throw new Error("project output path must be a safe relative path");
    }
    const candidate = resolve(root, ...components);
    const fromRoot = relative(root, candidate);
    if (!fromRoot || fromRoot === ".." || fromRoot.startsWith(`..${sep}`) || isAbsolute(fromRoot)) {
      throw new Error("project output path escapes the project directory");
    }
    assertNoSymlinkComponents(root, components);
    return new Ok(candidate);
  } catch (error) {
    return new GleamError(String(error && error.message ? error.message : error));
  }
}

function assertNoSymlinkComponents(root, components) {
  let current = root;
  const rootInfo = lstatSync(root);
  if (rootInfo.isSymbolicLink() || !rootInfo.isDirectory()) {
    throw new Error("project directory must be a real directory");
  }
  for (let index = 0; index < components.length; index += 1) {
    current = join(current, components[index]);
    let info;
    try {
      info = lstatSync(current);
    } catch (error) {
      if (error?.code === "ENOENT") return;
      throw error;
    }
    if (info.isSymbolicLink()) {
      throw new Error("refusing to write through a symbolic link");
    }
    if (index < components.length - 1 && !info.isDirectory()) {
      throw new Error("project output parent is not a directory");
    }
  }
}

export function replace_if_unchanged(path, expected, contents) {
  try {
    if (readFileSync(path, "utf8") !== expected) return new Ok(false);
    const temporary = `${path}.kangaroo.${process.pid}.${Date.now()}.tmp`;
    writeFileSync(temporary, contents, { encoding: "utf8", flag: "wx" });
    try {
      renameSync(temporary, path);
    } catch (error) {
      rmSync(temporary, { force: true });
      throw error;
    }
    return new Ok(true);
  } catch (error) {
    return new GleamError(String(error && error.message ? error.message : error));
  }
}

export function current_dir() {
  return new Ok(process.cwd());
}

export function args() {
  return toList(process.argv.slice(2));
}

export function read_line() {
  if (inputEnded) return Option$None$const;
  const bytes = [];
  const buffer = Buffer.alloc(1);
  while (true) {
    const count = readSync(0, buffer, 0, 1, null);
    if (count === 0) {
      inputEnded = true;
      return bytes.length === 0
        ? Option$None$const
        : new Some(Buffer.from(bytes).toString("utf8"));
    }
    if (buffer[0] === 10) return new Some(Buffer.from(bytes).toString("utf8"));
    if (buffer[0] !== 13) bytes.push(buffer[0]);
  }
}

export function read_line_timeout(milliseconds) {
  if (!inputReader) {
    const controlBuffer = new SharedArrayBuffer(
      Int32Array.BYTES_PER_ELEMENT * 2,
    );
    const control = new Int32Array(controlBuffer);
    const { port1, port2 } = new MessageChannel();
    const worker = new Worker(inputWorkerUrl, {
      workerData: { port: port2, controlBuffer, activityBuffer },
      transferList: [port2],
    });
    // A reader blocked in readSync(0) cannot always be interrupted promptly by
    // Worker.terminate(). The protocol loop itself owns liveness, so stdin
    // observation must never keep an otherwise completed daemon alive.
    worker.unref?.();
    port1.unref?.();
    inputReader = {
      control,
      port: port1,
      worker,
      ended: false,
      awaitingResume: false,
    };
  }
  if (inputReader.ended) return new InputEnd();
  if (inputReader.awaitingResume) {
    inputReader.awaitingResume = false;
    inputReader.port.postMessage({ type: "continue" });
  }
  let received = receiveMessageOnPort(inputReader.port);
  if (!received && milliseconds > 0) {
    const sequence = Atomics.load(activity, 0);
    if (sequence === observedActivity) {
      Atomics.wait(activity, 0, sequence, Math.max(0, milliseconds));
    }
    observedActivity = Atomics.load(activity, 0);
    received = receiveMessageOnPort(inputReader.port);
  }
  observedActivity = Atomics.load(activity, 0);
  if (!received) return new InputPending();
  if (received.message.type === "end") {
    inputReader.ended = true;
    inputReader.port.unref?.();
    inputReader.worker.unref?.();
    return new InputEnd();
  }
  inputReader.awaitingResume = true;
  if (received.message.type === "error") {
    return new InputError(String(received.message.value || "stdin error"));
  }
  return new InputLine(String(received.message.value || ""));
}

export function close_input() {
  if (inputReader) {
    if (!inputReader.ended) {
      inputReader.port.postMessage({ type: "stop" });
      Atomics.wait(inputReader.control, 1, 0, 250);
      if (Atomics.load(inputReader.control, 1) === 1) {
        Atomics.wait(inputReader.control, 1, 1, 250);
      }
    }
    inputReader.ended = true;
    inputReader.port.close();
    inputReader.port.unref?.();
    inputReader.worker.unref?.();
    inputReader = undefined;
  }
  inputEnded = true;
}

export function write_stdout_line(line) {
  writeAll(1, `${String(line)}\n`);
}

export function write_stdout(contents) {
  writeAll(1, contents);
}

export function write_stderr_line(line) {
  writeAll(2, `${String(line)}\n`);
}

export function write_stderr(contents) {
  writeAll(2, contents);
}

const writePause = new Int32Array(new SharedArrayBuffer(4));

function writeAll(fileDescriptor, value) {
  const contents = Buffer.from(String(value), "utf8");
  let offset = 0;
  while (offset < contents.length) {
    try {
      const written = writeSync(
        fileDescriptor,
        contents,
        offset,
        contents.length - offset,
      );
      if (written <= 0) throw new Error("stdout accepted zero bytes");
      offset += written;
    } catch (error) {
      if (error?.code === "EPIPE") exitAfterClosedOutput();
      if (error?.code !== "EAGAIN" && error?.code !== "EWOULDBLOCK") {
        throw error;
      }
      Atomics.wait(writePause, 0, 0, 1);
    }
  }
}

function exitAfterClosedOutput() {
  // A downstream command such as `head` has accepted all the output it needs.
  // Exit synchronously so no later framework write exposes a runtime stack.
  if (typeof globalThis.Deno?.exit === "function") globalThis.Deno.exit(0);
  globalThis.process.exit(0);
}

export function halt(code) {
  // Framework output is synchronous and the stdin reader is quiescent before
  // this boundary, so the event loop can terminate without dropping output.
  process.exitCode = Number(code);
}
