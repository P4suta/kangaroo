/// Filesystem access for the CLI. Everything is relative to the project
/// root, and errors are reported as human-readable messages.
/// Recursively lists all regular files under a directory.
@external(erlang, "kangaroo_cli_ffi", "list_files_recursive")
@external(javascript, "../kangaroo_cli_ffi.mjs", "list_files_recursive")
pub fn list_files_recursive(directory: String) -> Result(List(String), String)

/// Reads a text file as UTF-8.
@external(erlang, "kangaroo_cli_ffi", "read_file")
@external(javascript, "../kangaroo_cli_ffi.mjs", "read_file")
pub fn read_file(path: String) -> Result(String, String)

/// The modification time of a file in milliseconds.
@external(erlang, "kangaroo_cli_ffi", "mtime_ms")
@external(javascript, "../kangaroo_cli_ffi.mjs", "mtime_ms")
pub fn mtime_ms(path: String) -> Result(Int, String)

/// Blocks for the given number of milliseconds.
@external(erlang, "kangaroo_cli_ffi", "sleep")
@external(javascript, "../kangaroo_cli_ffi.mjs", "sleep")
pub fn sleep(ms: Int) -> Nil

/// The current monotonic clock time in milliseconds.
@external(erlang, "kangaroo_cli_ffi", "now_ms")
@external(javascript, "../kangaroo_cli_ffi.mjs", "now_ms")
pub fn now_ms() -> Int

/// The path to the `gleam` executable, or an error if it is not on PATH.
@external(erlang, "kangaroo_cli_ffi", "gleam_executable")
@external(javascript, "../kangaroo_cli_ffi.mjs", "gleam_executable")
pub fn gleam_executable() -> Result(String, String)

/// Removes a directory tree, ignoring missing directories.
@external(erlang, "kangaroo_cli_ffi", "remove_dir")
@external(javascript, "../kangaroo_cli_ffi.mjs", "remove_dir")
pub fn remove_dir(path: String) -> Result(Nil, String)

/// The current working directory.
@external(erlang, "kangaroo_cli_ffi", "current_dir")
@external(javascript, "../kangaroo_cli_ffi.mjs", "current_dir")
pub fn current_dir() -> Result(String, String)

/// The command line arguments after the program name.
@external(erlang, "kangaroo_cli_ffi", "args")
@external(javascript, "../kangaroo_cli_ffi.mjs", "args")
pub fn args() -> List(String)

/// Terminates the process with the given exit code.
@external(erlang, "kangaroo_cli_ffi", "halt")
@external(javascript, "../kangaroo_cli_ffi.mjs", "halt")
pub fn halt(code: Int) -> Nil

/// The result of running a subprocess.
pub type ProcessResult {
  ProcessResult(exit_code: Int, output: String)
}

/// Runs `gleam test` in the given project directory with `KANGAROO_JSON=1`,
/// capturing all output and the exit code.
@external(erlang, "kangaroo_cli_ffi", "run_gleam_test")
@external(javascript, "../kangaroo_cli_ffi.mjs", "run_gleam_test")
pub fn run_gleam_test(
  project_dir: String,
  extra_env: List(#(String, String)),
  timeout_ms: Int,
) -> Result(ProcessResult, String)

/// Runs `gleam` with explicit arguments in the given project directory,
/// with `KANGAROO_JSON=1` and any extra environment variables.
@external(erlang, "kangaroo_cli_ffi", "run_gleam_test_with")
@external(javascript, "../kangaroo_cli_ffi.mjs", "run_gleam_test_with")
pub fn run_gleam_test_with(
  project_dir: String,
  args: List(String),
  extra_env: List(#(String, String)),
  timeout_ms: Int,
) -> Result(ProcessResult, String)
