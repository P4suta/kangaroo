import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { delimiter, join, resolve } from "node:path";
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
const preparedKey = Symbol.for("kangaroo.windowsJobPrepared.v6.20260831");
const temporaryDirectory = [
  globalThis.process.env.TEMP,
  globalThis.process.env.TMP,
  globalThis.process.env.TMPDIR,
].find((value) => value !== undefined && String(value).trim() !== "") || ".";
const cachedExecutable = join(
  resolve(temporaryDirectory),
  "kangaroo",
  "windows-job-v6-20260831.exe",
);

function executableOnPath(name) {
  const path = String(globalThis.process.env.PATH || "");
  for (const rawDirectory of path.split(delimiter)) {
    const directory = rawDirectory.replace(/^"|"$/g, "");
    const candidate = join(directory, name);
    if (directory && existsSync(candidate)) return candidate;
  }
  return null;
}

function findPowerShell() {
  return executableOnPath("powershell.exe") ||
    executableOnPath("pwsh.exe") ||
    "powershell.exe";
}

export function ensureWindowsJobHelper() {
  if (globalThis.process.platform !== "win32") return;
  if (globalThis[preparedKey] === true && existsSync(cachedExecutable)) return;
  if (!existsSync(cachedExecutable)) {
    prepareWindowsJob(
      findPowerShell(),
      [
        ...powershellArguments,
        "-Prepare",
      ],
      {
        env: globalThis.process.env,
        stdio: "pipe",
        timeout: 60_000,
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
    [variableName("ENVIRONMENT_COUNT")]: encode(0),
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
  // The helper itself may already be spawned with options.cwd. Resolve from
  // the calling process before that happens so CreateProcess does not apply a
  // relative directory a second time (fixture/fixture on Windows).
  const workingDirectory = resolve(pathValue(directory));
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
    arguments: ["--kangaroo-job-helper"],
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
    args: [cachedExecutable, "--kangaroo-job-helper"],
    envPairs: environmentPairs,
    windowsVerbatimArguments: false,
  };
}
