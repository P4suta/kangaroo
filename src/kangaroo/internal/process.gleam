pub type ProcessResult {
  ProcessResult(exit_code: Int, output: String)
}

pub type ProcessPoll {
  ProcessRunning
  ProcessOutput(output: String)
  ProcessFinished(result: ProcessResult)
  ProcessCancelled
  ProcessFailed(message: String)
}

@external(erlang, "kangaroo_process_ffi", "run")
@external(javascript, "../../kangaroo_process_ffi.mjs", "run")
pub fn run(
  directory: String,
  executable: String,
  arguments: List(String),
  environment: List(#(String, String)),
  timeout_ms: Int,
) -> Result(ProcessResult, String)

/// Runs a foreground command with the caller's stdin, stdout, and stderr.
/// Interactive integrations use this only while the TUI is suspended.
@external(erlang, "kangaroo_process_ffi", "run_inherited")
@external(javascript, "../../kangaroo_process_ffi.mjs", "run_inherited")
pub fn run_inherited(
  directory: String,
  executable: String,
  arguments: List(String),
  environment: List(#(String, String)),
  timeout_ms: Int,
) -> Result(ProcessResult, String)

/// Starts a process in a separately cancellable process tree. The returned
/// integer is local to this coordinator process and must be polled until a
/// terminal `ProcessPoll` is returned.
@external(erlang, "kangaroo_process_ffi", "start")
@external(javascript, "../../kangaroo_process_ffi.mjs", "start")
pub fn start(
  directory: String,
  executable: String,
  arguments: List(String),
  environment: List(#(String, String)),
  timeout_ms: Int,
) -> Result(Int, String)

@external(erlang, "kangaroo_process_ffi", "poll")
@external(javascript, "../../kangaroo_process_ffi.mjs", "poll")
pub fn poll(handle: Int) -> ProcessPoll

@external(erlang, "kangaroo_process_ffi", "cancel")
@external(javascript, "../../kangaroo_process_ffi.mjs", "cancel")
pub fn cancel(handle: Int) -> Nil

/// Writes bytes to a live child stdin stream. Daemon integrations keep the
/// stream open across multiple NDJSON request lines.
@external(erlang, "kangaroo_process_ffi", "write")
@external(javascript, "../../kangaroo_process_ffi.mjs", "write")
pub fn write(handle: Int, input: String) -> Nil
