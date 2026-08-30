import gleam/option.{type Option}

pub type LineRead {
  InputLine(value: String)
  InputError(message: String)
  InputPending
  InputEnd
}

/// Recursively lists regular files below a directory in lexical order.
@external(erlang, "kangaroo_fs_ffi", "list_files_recursive")
@external(javascript, "../../kangaroo_fs_ffi.mjs", "list_files_recursive")
pub fn list_files_recursive(directory: String) -> Result(List(String), String)

/// Recursively lists source workspace files while pruning generated trees.
@external(erlang, "kangaroo_fs_ffi", "list_workspace_files_recursive")
@external(javascript, "../../kangaroo_fs_ffi.mjs", "list_workspace_files_recursive")
pub fn list_workspace_files_recursive(
  directory: String,
) -> Result(List(String), String)

@external(erlang, "kangaroo_fs_ffi", "list_source_files_recursive")
@external(javascript, "../../kangaroo_fs_ffi.mjs", "list_source_files_recursive")
pub fn list_source_files_recursive(
  directory: String,
) -> Result(List(String), String)

@external(erlang, "kangaroo_fs_ffi", "read_file")
@external(javascript, "../../kangaroo_fs_ffi.mjs", "read_file")
pub fn read_file(path: String) -> Result(String, String)

@external(erlang, "kangaroo_fs_ffi", "current_dir")
@external(javascript, "../../kangaroo_fs_ffi.mjs", "current_dir")
pub fn current_dir() -> Result(String, String)

@external(erlang, "kangaroo_fs_ffi", "args")
@external(javascript, "../../kangaroo_fs_ffi.mjs", "args")
pub fn args() -> List(String)

@external(erlang, "kangaroo_fs_ffi", "read_line")
@external(javascript, "../../kangaroo_fs_ffi.mjs", "read_line")
pub fn read_line() -> Option(String)

/// Reads one stdin line without preventing daemon operations from being
/// polled. `InputError` reports a rejected bounded line while keeping the
/// reader usable, `InputPending` means the timeout elapsed, and `InputEnd` is
/// permanent EOF.
@external(erlang, "kangaroo_fs_ffi", "read_line_timeout")
@external(javascript, "../../kangaroo_fs_ffi.mjs", "read_line_timeout")
pub fn read_line_timeout(milliseconds: Int) -> LineRead

/// Stops the background stdin reader created by `read_line_timeout`.
/// Long-lived protocol loops must call this before returning so JavaScript
/// Worker threads cannot keep the coordinator process alive after shutdown.
@external(erlang, "kangaroo_fs_ffi", "close_input")
@external(javascript, "../../kangaroo_fs_ffi.mjs", "close_input")
pub fn close_input() -> Nil

/// Writes one complete protocol line synchronously. Long-lived JavaScript
/// coordinators cannot rely on event-loop-driven stdout flushing while their
/// poll loop is intentionally blocking.
@external(erlang, "kangaroo_fs_ffi", "write_stdout_line")
@external(javascript, "../../kangaroo_fs_ffi.mjs", "write_stdout_line")
pub fn write_stdout_line(line: String) -> Nil

/// Writes bytes to stdout synchronously without adding a newline.
@external(erlang, "kangaroo_fs_ffi", "write_stdout")
@external(javascript, "../../kangaroo_fs_ffi.mjs", "write_stdout")
pub fn write_stdout(contents: String) -> Nil

@external(erlang, "kangaroo_fs_ffi", "write_stderr_line")
@external(javascript, "../../kangaroo_fs_ffi.mjs", "write_stderr_line")
pub fn write_stderr_line(line: String) -> Nil

/// Writes bytes to stderr synchronously without adding a newline.
@external(erlang, "kangaroo_fs_ffi", "write_stderr")
@external(javascript, "../../kangaroo_fs_ffi.mjs", "write_stderr")
pub fn write_stderr(contents: String) -> Nil

@external(erlang, "kangaroo_fs_ffi", "halt")
@external(javascript, "../../kangaroo_fs_ffi.mjs", "halt")
pub fn halt(code: Int) -> Nil

@external(erlang, "kangaroo_fs_ffi", "exists")
@external(javascript, "../../kangaroo_fs_ffi.mjs", "exists")
pub fn exists(path: String) -> Bool

@external(erlang, "kangaroo_fs_ffi", "write_exclusive")
@external(javascript, "../../kangaroo_fs_ffi.mjs", "write_exclusive")
pub fn write_exclusive(path: String, contents: String) -> Result(Nil, String)

@external(erlang, "kangaroo_fs_ffi", "write_file")
@external(javascript, "../../kangaroo_fs_ffi.mjs", "write_file")
pub fn write_file(path: String, contents: String) -> Result(Nil, String)

/// Resolves a project-relative output path after rejecting traversal and every
/// existing symbolic-link component. Call this immediately before writes that
/// originate from repository configuration or fixed report destinations.
@external(erlang, "kangaroo_fs_ffi", "project_file_path")
@external(javascript, "../../kangaroo_fs_ffi.mjs", "project_file_path")
pub fn project_file_path(
  project_dir: String,
  relative: String,
) -> Result(String, String)

@external(erlang, "kangaroo_fs_ffi", "replace_if_unchanged")
@external(javascript, "../../kangaroo_fs_ffi.mjs", "replace_if_unchanged")
pub fn replace_if_unchanged(
  path: String,
  expected: String,
  contents: String,
) -> Result(Bool, String)

@external(erlang, "kangaroo_fs_ffi", "is_directory")
@external(javascript, "../../kangaroo_fs_ffi.mjs", "is_directory")
pub fn is_directory(path: String) -> Bool

@external(erlang, "kangaroo_fs_ffi", "sleep")
@external(javascript, "../../kangaroo_fs_ffi.mjs", "sleep")
pub fn sleep(milliseconds: Int) -> Nil

@external(erlang, "kangaroo_fs_ffi", "remove_file")
@external(javascript, "../../kangaroo_fs_ffi.mjs", "remove_file")
pub fn remove_file(path: String) -> Result(Nil, String)

/// Copies a project to a unique temporary directory for source
/// instrumentation. A sibling is preferred so relative dependencies retain
/// their meaning; the operating-system temp directory is the safe fallback.
/// Cached dependency sources are retained for deterministic offline builds;
/// compiled products, VCS data, and generated output are not copied.
@external(erlang, "kangaroo_fs_ffi", "copy_to_temporary_workspace")
@external(javascript, "../../kangaroo_fs_ffi.mjs", "copy_to_temporary_workspace")
pub fn copy_to_temporary_workspace(
  project_dir: String,
) -> Result(String, String)

/// Uses the same generated-directory policy on every backend before copying a
/// coverage workspace.
@external(erlang, "kangaroo_fs_ffi", "workspace_entry_excluded")
@external(javascript, "../../kangaroo_fs_ffi.mjs", "workspace_entry_excluded")
pub fn workspace_entry_excluded(name: String) -> Bool

/// Removes only directories created by `copy_to_temporary_workspace`.
@external(erlang, "kangaroo_fs_ffi", "remove_tree")
@external(javascript, "../../kangaroo_fs_ffi.mjs", "remove_tree")
pub fn remove_tree(path: String) -> Result(Nil, String)
