import kangaroo/failure.{type Failure}

/// The error raised by a test case body, with a best-effort name and message.
pub type CaughtError {
  CaughtError(name: String, message: String)
}

/// The result of executing a test case body in isolation.
pub type Isolated {
  /// The body completed. `failures` are the matcher failures it recorded.
  Completed(failures: List(Failure))
  /// The body raised an error (or timed out).
  Crashed(error: CaughtError)
}

/// Runs a test case body in isolation: panics are caught, matcher failures
/// are collected, and the body cannot take down the caller. The body's
/// return value is discarded.
@external(erlang, "kangaroo_isolate_ffi", "isolate")
@external(javascript, "../kangaroo_isolate_ffi.mjs", "isolate")
pub fn isolate(body: fn() -> a) -> Isolated
