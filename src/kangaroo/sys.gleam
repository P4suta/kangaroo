import gleam/option.{type Option}

/// The current monotonic clock time in milliseconds. Only differences are
/// meaningful.
@external(erlang, "kangaroo_sys_ffi", "now_ms")
@external(javascript, "../kangaroo_sys_ffi.mjs", "now_ms")
pub fn now_ms() -> Int

/// Reads an environment variable.
@external(erlang, "kangaroo_sys_ffi", "env")
@external(javascript, "../kangaroo_sys_ffi.mjs", "env")
pub fn env(name: String) -> Option(String)

/// Terminates the process with the given exit code.
@external(erlang, "kangaroo_sys_ffi", "halt")
@external(javascript, "../kangaroo_sys_ffi.mjs", "halt")
pub fn halt(code: Int) -> Nil
