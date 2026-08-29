import gleam/option.{type Option}
import kangaroo/failure.{type Failure}
import kangaroo/location.{type Location}

/// The error raised by a test case body, with a best-effort name, message
/// and source location.
pub type CaughtError {
  CaughtError(name: String, message: String, location: Option(Location))
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
/// return value is discarded. `timeout_ms` bounds the execution on Erlang;
/// it is ignored on JavaScript, where a synchronous body cannot be
/// interrupted.
@external(erlang, "kangaroo_isolate_ffi", "isolate")
@external(javascript, "../kangaroo_isolate_ffi.mjs", "isolate")
pub fn isolate(body: fn() -> a, timeout_ms: Option(Int)) -> Isolated
