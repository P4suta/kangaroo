import kangaroo/failure.{type Failure}

/// Records a failure into the context of the currently running test case.
///
/// On the Erlang target each case runs in its own process, so the process
/// dictionary is the natural per-case storage. On JavaScript the failures
/// live in a module-level array that is reset before each isolated case.
@external(erlang, "kangaroo_context_ffi", "record")
@external(javascript, "../kangaroo_context_ffi.mjs", "record")
pub fn record(failure: Failure) -> Nil

/// Collects the failures recorded so far, in the order they were recorded.
@external(erlang, "kangaroo_context_ffi", "collect")
@external(javascript, "../kangaroo_context_ffi.mjs", "collect")
pub fn collect() -> List(Failure)
