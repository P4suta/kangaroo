import gleam/int
import gleam/string
import kangaroo/internal/fs
import kangaroo/internal/process.{
  ProcessCancelled, ProcessFailed, ProcessFinished, ProcessOutput,
  ProcessRunning,
}
import kangaroo/sys

const streaming_chunk_bytes = 1_048_576

const streaming_rounds = 17

@external(erlang, "kangaroo_cli_test_ffi", "oversized_output_arguments")
@external(javascript, "./kangaroo_cli_test_ffi.mjs", "oversized_output_arguments")
fn oversized_output_arguments() -> List(String)

@external(erlang, "kangaroo_cli_test_ffi", "oversized_split_output_arguments")
@external(javascript, "./kangaroo_cli_test_ffi.mjs", "oversized_split_output_arguments")
fn oversized_split_output_arguments() -> List(String)

@external(erlang, "kangaroo_cli_test_ffi", "invalid_utf8_expansion_arguments")
@external(javascript, "./kangaroo_cli_test_ffi.mjs", "invalid_utf8_expansion_arguments")
fn invalid_utf8_expansion_arguments() -> List(String)

@external(erlang, "kangaroo_cli_test_ffi", "streaming_handshake_arguments")
@external(javascript, "./kangaroo_cli_test_ffi.mjs", "streaming_handshake_arguments")
fn streaming_handshake_arguments() -> List(String)

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

pub fn consumed_daemon_stream_can_exceed_the_lifetime_capture_limit_test() {
  let assert Ok(handle) =
    process.start_streaming(
      ".",
      sleeper_executable(),
      streaming_handshake_arguments(),
      [],
      30_000,
    )
  consume_stream(handle, streaming_rounds, sys.now_ms())
  process.write(handle, "done\n")
  let assert ProcessFinished(completed) = await_terminal(handle, sys.now_ms())
  assert completed.exit_code == 0
  assert completed.output == ""
}

pub fn unconsumed_daemon_stream_still_respects_the_memory_limit_test() {
  let assert Ok(handle) =
    process.start_streaming(
      ".",
      sleeper_executable(),
      oversized_output_arguments(),
      [],
      10_000,
    )
  // Do not acknowledge any output until the producer has crossed the bound.
  fs.sleep(1000)
  assert await_terminal(handle, sys.now_ms())
    == ProcessFailed("process output exceeded 16777216 bytes")
}

fn consume_stream(handle: Int, remaining: Int, started: Int) -> Nil {
  case remaining {
    0 -> Nil
    _ -> {
      process.write(handle, "next\n")
      consume_stream_chunk(handle, remaining, 0, started)
    }
  }
}

fn consume_stream_chunk(
  handle: Int,
  remaining: Int,
  received: Int,
  started: Int,
) -> Nil {
  case process.poll(handle) {
    ProcessOutput(chunk) -> {
      let received = received + string.byte_size(chunk)
      case received == streaming_chunk_bytes {
        True -> consume_stream(handle, remaining - 1, started)
        False if received < streaming_chunk_bytes ->
          consume_stream_chunk(handle, remaining, received, started)
        False -> panic as "streaming child emitted an oversized handshake chunk"
      }
    }
    ProcessRunning ->
      case sys.now_ms() - started < 30_000 {
        True -> {
          fs.sleep(1)
          consume_stream_chunk(handle, remaining, received, started)
        }
        False -> panic as "streaming output test timed out"
      }
    ProcessFinished(completed) -> {
      let message =
        "streaming child exited before all rounds with "
        <> int.to_string(completed.exit_code)
        <> " (remaining "
        <> int.to_string(remaining)
        <> ", received "
        <> int.to_string(received)
        <> ")"
        <> ": "
        <> completed.output
      panic as message
    }
    ProcessCancelled -> panic as "streaming child was cancelled"
    ProcessFailed(message) -> panic as message
  }
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
