import { Buffer } from "node:buffer";
import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const prefix = "__KANGAROO_INTERNAL_WINDOWS_JOB_V1_";
const script = fileURLToPath(
  new URL("./priv/kangaroo_windows_job.ps1", import.meta.url),
);
const powershellArguments = [
  "-NoLogo",
  "-NoProfile",
  "-NonInteractive",
  "-ExecutionPolicy",
  "Bypass",
  "-File",
  script,
];
const prepareWindowsJob = execFileSync;
const preparedKey = Symbol.for("kangaroo.windowsJobPrepared.v2.20260831");
const cachedExecutable = join(
  tmpdir(),
  "kangaroo",
  "windows-job-v2-20260831.exe",
);

export function ensureWindowsJobHelper() {
  if (globalThis.process.platform !== "win32") return;
  if (globalThis[preparedKey] === true && existsSync(cachedExecutable)) return;
  if (!existsSync(cachedExecutable)) {
    prepareWindowsJob(
      "powershell.exe",
      [...powershellArguments, "-Prepare"],
      {
        env: {
          ...globalThis.process.env,
          [variableName("HELPER_PATH")]: encode(cachedExecutable),
        },
        stdio: "ignore",
        timeout: 15_000,
        windowsHide: true,
      },
    );
  }
  if (!existsSync(cachedExecutable)) {
    throw new Error("Windows process helper was not created");
  }
  globalThis[preparedKey] = true;
}

function encode(value) {
  return Buffer.from(String(value), "utf8").toString("base64");
}

function pathValue(value) {
  return value instanceof URL && value.protocol === "file:"
    ? fileURLToPath(value)
    : String(value);
}

function variableName(name) {
  return `${prefix}${name}`;
}

function internalVariables(executable, arguments_, directory, argv0) {
  const variables = {
    [variableName("EXECUTABLE")]: encode(executable),
    [variableName("DIRECTORY")]: encode(directory),
    [variableName("ARGV0")]: encode(argv0),
    [variableName("ARGUMENT_COUNT")]: encode(arguments_.length),
  };
  arguments_.forEach((argument, index) => {
    const suffix = String(index).padStart(6, "0");
    variables[variableName(`ARGUMENT_${suffix}`)] = encode(argument);
  });
  return variables;
}

export function isInternalName(name) {
  return String(name).toUpperCase().startsWith(prefix);
}

export function windowsJobLaunch(
  executable,
  arguments_,
  directory,
  environment,
  argv0 = executable,
) {
  const executablePath = pathValue(executable);
  const workingDirectory = pathValue(directory);
  const argumentZero = pathValue(argv0);
  const cleanEnvironment = {};
  for (const [name, value] of Object.entries(environment || {})) {
    if (!isInternalName(name)) cleanEnvironment[name] = value;
  }
  Object.assign(
    cleanEnvironment,
    internalVariables(
      executablePath,
      arguments_.map(String),
      workingDirectory,
      argumentZero,
    ),
  );
  return {
    executable: cachedExecutable,
    arguments: [],
    environment: cleanEnvironment,
  };
}

// ChildProcess.prototype receives Node's fully normalised spawn options. Wrap
// at that common boundary so spawn, exec, execFile, fork, shell commands, and
// ESM named imports all acquire the same Job Object before user code runs.
export function windowsJobSpawnOptions(options) {
  const executable = String(options.file);
  const originalArguments = Array.isArray(options.args)
    ? options.args.map(String)
    : [executable];
  const argv0 = originalArguments[0] || executable;
  const arguments_ = originalArguments.slice(1);
  const directory = options.cwd === undefined
    ? globalThis.process.cwd()
    : String(options.cwd);
  const environmentPairs = Array.isArray(options.envPairs)
    ? options.envPairs.filter((pair) => {
      const separator = String(pair).indexOf("=");
      const name = separator < 0 ? pair : String(pair).slice(0, separator);
      return !isInternalName(name);
    })
    : [];
  const variables = internalVariables(
    executable,
    arguments_,
    directory,
    argv0,
  );
  for (const [name, value] of Object.entries(variables)) {
    environmentPairs.push(`${name}=${value}`);
  }
  return {
    ...options,
    file: cachedExecutable,
    args: [cachedExecutable],
    envPairs: environmentPairs,
    windowsVerbatimArguments: false,
  };
}
