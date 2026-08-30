import kangaroo/internal/fs
import kangaroo/internal/process.{
  ProcessCancelled, ProcessFailed, ProcessFinished, ProcessOutput,
  ProcessRunning,
}
import kangaroo/sys

@external(erlang, "kangaroo_cli_test_ffi", "oversized_output_arguments")
@external(javascript, "./kangaroo_cli_test_ffi.mjs", "oversized_output_arguments")
fn oversized_output_arguments() -> List(String)

@external(erlang, "kangaroo_cli_test_ffi", "oversized_split_output_arguments")
@external(javascript, "./kangaroo_cli_test_ffi.mjs", "oversized_split_output_arguments")
fn oversized_split_output_arguments() -> List(String)

@external(erlang, "kangaroo_cli_test_ffi", "invalid_utf8_expansion_arguments")
@external(javascript, "./kangaroo_cli_test_ffi.mjs", "invalid_utf8_expansion_arguments")
fn invalid_utf8_expansion_arguments() -> List(String)

@external(erlang, "kangaroo_cli_test_ffi", "sleeper_executable")
@external(javascript, "./kangaroo_cli_test_ffi.mjs", "sleeper_executable")
fn sleeper_executable() -> String

pub fn foreground_process_rejects_output_above_the_memory_limit_test() {
  assert process.run(
      ".",
      sleeper_executable(),
      oversized_output_arguments(),
      [],
      10_000,
    )
    == Error("process output exceeded 16777216 bytes")
}

pub fn streaming_process_rejects_output_above_the_memory_limit_test() {
  let assert Ok(handle) =
    process.start(
      ".",
      sleeper_executable(),
      oversized_output_arguments(),
      [],
      10_000,
    )
  assert await_terminal(handle, sys.now_ms())
    == ProcessFailed("process output exceeded 16777216 bytes")
}

pub fn foreground_limit_counts_stdout_and_stderr_together_test() {
  assert process.run(
      ".",
      sleeper_executable(),
      oversized_split_output_arguments(),
      [],
      10_000,
    )
    == Error("process output exceeded 16777216 bytes")
}

pub fn foreground_limit_counts_utf8_replacement_expansion_test() {
  assert process.run(
      ".",
      sleeper_executable(),
      invalid_utf8_expansion_arguments(),
      [],
      10_000,
    )
    == Error("process output exceeded 16777216 bytes")
}

pub fn streaming_limit_counts_utf8_replacement_expansion_test() {
  let assert Ok(handle) =
    process.start(
      ".",
      sleeper_executable(),
      invalid_utf8_expansion_arguments(),
      [],
      10_000,
    )
  assert await_terminal(handle, sys.now_ms())
    == ProcessFailed("process output exceeded 16777216 bytes")
}

fn await_terminal(handle: Int, started: Int) -> process.ProcessPoll {
  case process.poll(handle) {
    ProcessRunning ->
      case sys.now_ms() - started < 10_000 {
        True -> {
          fs.sleep(5)
          await_terminal(handle, started)
        }
        False -> ProcessFailed("output limit test timed out")
      }
    ProcessOutput(_) -> await_terminal(handle, started)
    ProcessFinished(result) -> ProcessFinished(result)
    ProcessCancelled -> ProcessCancelled
    ProcessFailed(message) -> ProcessFailed(message)
  }
}
