import gleam/option.{type Option}
import kangaroo/failure.{type Failure}
import kangaroo/location.{type Location}

/// The error raised by a test case body, with a best-effort name, message
/// and source location.
pub type CaughtError {
  CaughtError(
    name: String,
    message: String,
    location: Option(Location),
    expected: Option(String),
    actual: Option(String),
    diff: Option(String),
  )
}

/// The result of executing a test case body in isolation.
pub type Isolated {
  /// The body completed. `failures` are the matcher failures it recorded.
  Completed(failures: List(Failure))
  /// The body raised an error (or timed out).
  Crashed(error: CaughtError)
  /// The body requested a runtime skip with a reason.
  SkippedIsolation(reason: String)
}

/// An isolation result together with output written while the test was
/// running. Keeping output outside `Isolated` preserves the small result
/// model for callers that do not need presentation data.
pub type CapturedIsolation {
  CapturedIsolation(result: Isolated, stdout: String, stderr: String)
}

/// Runs a test case body in isolation: panics are caught, matcher failures
/// are collected, and the body cannot take down the caller. The body's
/// return value is discarded. `timeout_ms` bounds the execution on Erlang;
/// it is ignored on JavaScript, where a synchronous body cannot be
/// interrupted.
pub fn isolate(body: fn() -> a, timeout_ms: Option(Int)) -> Isolated {
  isolate_captured(body, timeout_ms).result
}

/// Runs a test in isolation and returns its stdout and stderr without writing
/// either stream to the runner's own terminal.
@external(erlang, "kangaroo_isolate_ffi", "isolate_captured")
@external(javascript, "../kangaroo_isolate_ffi.mjs", "isolate_captured")
pub fn isolate_captured(
  body: fn() -> a,
  timeout_ms: Option(Int),
) -> CapturedIsolation
