import gleam/string
import kangaroo/internal/fs
import kangaroo/internal/process.{
  ProcessCancelled, ProcessFailed, ProcessFinished, ProcessOutput,
  ProcessRunning,
}
import kangaroo/internal/vm
import kangaroo/sys

@external(erlang, "kangaroo_cli_test_ffi", "sleeper_executable")
@external(javascript, "./kangaroo_cli_test_ffi.mjs", "sleeper_executable")
fn sleeper_executable() -> String

@external(erlang, "kangaroo_cli_test_ffi", "sleeper_arguments")
@external(javascript, "./kangaroo_cli_test_ffi.mjs", "sleeper_arguments")
fn sleeper_arguments(milliseconds: Int) -> List(String)

@external(erlang, "kangaroo_cli_test_ffi", "echo_arguments")
@external(javascript, "./kangaroo_cli_test_ffi.mjs", "echo_arguments")
fn echo_arguments() -> List(String)

@external(erlang, "kangaroo_cli_test_ffi", "argument_echo_arguments")
@external(javascript, "./kangaroo_cli_test_ffi.mjs", "argument_echo_arguments")
fn argument_echo_arguments(value: String) -> List(String)

@external(erlang, "kangaroo_cli_test_ffi", "split_utf8_arguments")
@external(javascript, "./kangaroo_cli_test_ffi.mjs", "split_utf8_arguments")
fn split_utf8_arguments() -> List(String)

@external(erlang, "kangaroo_cli_test_ffi", "invalid_utf8_arguments")
@external(javascript, "./kangaroo_cli_test_ffi.mjs", "invalid_utf8_arguments")
fn invalid_utf8_arguments() -> List(String)

@external(erlang, "kangaroo_cli_test_ffi", "tree_marker")
@external(javascript, "./kangaroo_cli_test_ffi.mjs", "tree_marker")
fn tree_marker() -> String

@external(erlang, "kangaroo_cli_test_ffi", "tree_arguments")
@external(javascript, "./kangaroo_cli_test_ffi.mjs", "tree_arguments")
fn tree_arguments(marker: String) -> List(String)

@external(erlang, "kangaroo_cli_test_ffi", "cleanup_active_processes")
@external(javascript, "./kangaroo_cli_test_ffi.mjs", "cleanup_active_processes")
fn cleanup_active_processes() -> Nil

@external(erlang, "kangaroo_cli_test_ffi", "orphan_tree_arguments")
@external(javascript, "./kangaroo_cli_test_ffi.mjs", "orphan_tree_arguments")
fn orphan_tree_arguments(marker: String) -> List(String)

@external(erlang, "kangaroo_cli_test_ffi", "orphan_tree_executable")
@external(javascript, "./kangaroo_cli_test_ffi.mjs", "orphan_tree_executable")
fn orphan_tree_executable() -> String

@external(erlang, "kangaroo_cli_test_ffi", "closed_stdin_tree_arguments")
@external(javascript, "./kangaroo_cli_test_ffi.mjs", "closed_stdin_tree_arguments")
fn closed_stdin_tree_arguments(marker: String) -> List(String)

@external(erlang, "kangaroo_cli_test_ffi", "closed_stdin_executable")
@external(javascript, "./kangaroo_cli_test_ffi.mjs", "closed_stdin_executable")
fn closed_stdin_executable() -> String

@external(erlang, "kangaroo_cli_test_ffi", "streaming_output_arguments")
@external(javascript, "./kangaroo_cli_test_ffi.mjs", "streaming_output_arguments")
fn streaming_output_arguments() -> List(String)

@external(erlang, "kangaroo_cli_test_ffi", "internal_windows_job_name")
@external(javascript, "./kangaroo_cli_test_ffi.mjs", "internal_windows_job_name")
fn internal_windows_job_name(name: String) -> Bool

pub fn windows_job_environment_namespace_is_case_insensitive_test() {
  assert internal_windows_job_name(
    "__KANGAROO_INTERNAL_WINDOWS_JOB_V1_EXECUTABLE",
  )
  assert internal_windows_job_name(
    "__kangaroo_internal_windows_job_v1_argument_000001",
  )
  assert !internal_windows_job_name("KANGAROO_PROCESS_TEST_ENV")
}

pub fn closed_stdin_terminates_process_tree_test() {
  case vm.target(), vm.runtime_name(), vm.operating_system() {
    "javascript", "node", operating_system -> {
      let marker = tree_marker()
      let windows = operating_system == "windows"
      // Windows named pipes can accept a write after the reader has closed
      // without reporting EPIPE. The bounded process timeout is the portable
      // fallback there; Unix runtimes must still report the closed pipe
      // immediately.
      let process_timeout = case windows {
        True -> 2000
        False -> 10_000
      }
      let assert Ok(handle) =
        process.start(
          ".",
          closed_stdin_executable(),
          closed_stdin_tree_arguments(marker),
          [],
          process_timeout,
        )
      let assert Ok(output) =
        await_output_containing(handle, "ready", launch_poll_timeout_ms())
      assert string.contains(output, "ready")
      process.write(handle, "must fail\n")
      let assert ProcessFailed(message) = await_terminal(handle, 2500)
      case windows {
        True -> {
          assert message == "process timed out"
        }
        False ->
          case string.contains(message, "test polling timed out") {
            True -> panic as message
            False -> Nil
          }
      }
      fs.sleep(case windows {
        True -> 1800
        False -> 700
      })
      let survived = fs.exists(marker)
      case survived {
        True -> {
          let _ = fs.remove_file(marker)
          Nil
        }
        False -> Nil
      }
      assert survived == False
    }
    "erlang", _, operating_system if operating_system != "windows" -> {
      let marker = tree_marker()
      let assert Ok(handle) =
        process.start(
          ".",
          closed_stdin_executable(),
          closed_stdin_tree_arguments(marker),
          [],
          10_000,
        )
      let assert Ok(output) =
        await_output_containing(handle, "ready", launch_poll_timeout_ms())
      assert string.contains(output, "ready")
      process.write(handle, "must fail\n")
      let started = sys.now_ms()
      let assert ProcessFailed(message) = await_terminal(handle, 1000)
      assert message == "process stdin is not writable"
      assert sys.now_ms() - started < 1000
      fs.sleep(700)
      let survived = fs.exists(marker)
      case survived {
        True -> {
          let _ = fs.remove_file(marker)
          Nil
        }
        False -> Nil
      }
      assert !survived
    }
    _, _, _ -> Nil
  }
}

pub fn child_process_completion_captures_output_test() {
  let assert Ok(handle) =
    process.start(".", sleeper_executable(), sleeper_arguments(10), [], 2000)
  let assert ProcessFinished(completed) =
    await_terminal(handle, launch_poll_timeout_ms())
  assert completed.exit_code == 0
  assert completed.output == "ready"
}

pub fn foreground_process_timeout_terminates_descendants_test() {
  let marker = tree_marker()
  assert process.run(".", sleeper_executable(), tree_arguments(marker), [], 100)
    == Error("process timed out")
  fs.sleep(700)
  let survived = fs.exists(marker)
  case survived {
    True -> {
      let _ = fs.remove_file(marker)
      Nil
    }
    False -> Nil
  }
  assert !survived
}

pub fn successful_process_completion_reaps_its_remaining_group_test() {
  let marker = tree_marker()
  let assert Ok(completed) =
    process.run(
      ".",
      orphan_tree_executable(),
      orphan_tree_arguments(marker),
      [],
      5000,
    )
  assert completed.exit_code == 0
  fs.sleep(1500)
  let survived = fs.exists(marker)
  case survived {
    True -> {
      let _ = fs.remove_file(marker)
      Nil
    }
    False -> Nil
  }
  assert !survived
}

pub fn child_process_cancellation_does_not_publish_completion_test() {
  let assert Ok(handle) =
    process.start(
      ".",
      sleeper_executable(),
      sleeper_arguments(5000),
      [],
      10_000,
    )
  fs.sleep(25)
  let started = sys.now_ms()
  process.cancel(handle)
  assert await_terminal(handle, 1000) == ProcessCancelled
  assert sys.now_ms() - started < 1000
}

pub fn cancellation_is_not_starved_by_streaming_output_test() {
  let assert Ok(handle) =
    process.start(
      ".",
      sleeper_executable(),
      streaming_output_arguments(),
      [],
      10_000,
    )
  let assert ProcessOutput(_) = await_output(handle, launch_poll_timeout_ms())
  let started = sys.now_ms()
  process.cancel(handle)
  assert await_terminal(handle, vm.process_cleanup_timeout_ms())
    == ProcessCancelled
  assert sys.now_ms() - started < vm.process_cleanup_timeout_ms()
}

pub fn child_process_streams_output_before_completion_test() {
  let assert Ok(handle) =
    process.start(".", sleeper_executable(), sleeper_arguments(2000), [], 5000)
  let assert ProcessOutput(output) =
    await_output(handle, launch_poll_timeout_ms())
  assert output == "ready"
  process.cancel(handle)
  let assert ProcessCancelled = await_terminal(handle, 1000)
}

pub fn child_process_decodes_utf8_across_output_chunks_test() {
  let assert Ok(handle) =
    process.start(".", sleeper_executable(), split_utf8_arguments(), [], 2000)
  await_utf8_terminal(handle, sys.now_ms(), launch_poll_timeout_ms(), "")
}

pub fn foreground_process_replaces_invalid_utf8_in_order_test() {
  let assert Ok(completed) =
    process.run(".", sleeper_executable(), invalid_utf8_arguments(), [], 2000)
  assert completed.output == "A�B"
}

pub fn child_process_replaces_invalid_utf8_in_order_test() {
  let assert Ok(handle) =
    process.start(".", sleeper_executable(), invalid_utf8_arguments(), [], 2000)
  await_invalid_utf8_terminal(
    handle,
    sys.now_ms(),
    launch_poll_timeout_ms(),
    "",
  )
}

pub fn child_process_accepts_stdin_without_closing_its_tree_test() {
  let assert Ok(handle) =
    process.start(".", sleeper_executable(), echo_arguments(), [], 2000)
  process.write(handle, "kangaroo protocol\n")
  // Erlang schedules port creation in the process worker after start returns.
  // Keep the child itself bounded by the 2 second product timeout above, but
  // allow the black-box poller enough launch-scheduling margin to observe its
  // terminal result on a loaded host. A broken stdin path still reports
  // ProcessFailed("process timed out") and fails this assertion.
  let assert ProcessFinished(completed) =
    await_terminal(handle, launch_poll_timeout_ms())
  assert completed.exit_code == 0
  assert completed.output == "kangaroo protocol\n"
}

pub fn process_preserves_unicode_quotes_and_environment_test() {
  let argument = "space \"quote\" trailing\\ 🦘"
  let environment = "environment value 🦘"
  let assert Ok(completed) =
    process.run(
      ".",
      sleeper_executable(),
      argument_echo_arguments(argument),
      [#("KANGAROO_PROCESS_TEST_ENV", environment)],
      5000,
    )
  assert completed.exit_code == 0
  assert completed.output == argument <> "|" <> environment
}

pub fn child_process_cancellation_terminates_descendants_test() {
  let marker = tree_marker()
  let assert Ok(handle) =
    process.start(".", sleeper_executable(), tree_arguments(marker), [], 10_000)
  fs.sleep(150)
  process.cancel(handle)
  let assert ProcessCancelled = await_terminal(handle, 1000)
  fs.sleep(700)
  let survived = fs.exists(marker)
  case survived {
    True -> {
      let _ = fs.remove_file(marker)
      Nil
    }
    False -> Nil
  }
  assert survived == False
}

pub fn javascript_coordinator_exit_terminates_active_process_groups_test() {
  case vm.target() {
    "javascript" -> {
      let marker = tree_marker()
      let assert Ok(handle) =
        process.start(
          ".",
          sleeper_executable(),
          tree_arguments(marker),
          [],
          10_000,
        )
      let assert Ok(_) =
        await_output_containing(handle, "ready", launch_poll_timeout_ms())
      cleanup_active_processes()
      fs.sleep(700)
      let survived = fs.exists(marker)
      case survived {
        True -> {
          let _ = fs.remove_file(marker)
          Nil
        }
        False -> Nil
      }
      assert !survived
    }
    _ -> Nil
  }
}

pub fn cancellation_freezes_descendants_before_they_can_fork_test() {
  case vm.operating_system() {
    "windows" -> Nil
    _ -> {
      let marker = tree_marker()
      let assert Ok(handle) =
        process.start(
          ".",
          "sh",
          ["test/fixtures/cancellation_race.sh", marker],
          [],
          10_000,
        )
      let assert Ok(_) =
        await_output_containing(handle, "ready", launch_poll_timeout_ms())
      process.cancel(handle)
      let assert ProcessCancelled = await_terminal(handle, 1000)
      fs.sleep(350)
      let survived = fs.exists(marker)
      case survived {
        True -> {
          let _ = fs.remove_file(marker)
          Nil
        }
        False -> Nil
      }
      assert survived == False
    }
  }
}

fn await_terminal(handle: Int, timeout_ms: Int) -> process.ProcessPoll {
  let started = sys.now_ms()
  await_until(handle, started, timeout_ms)
}

// start() creates the captured port in a background worker. Functional tests
// allow that worker to be scheduled alongside the other process-heavy cases;
// product timeouts passed to process.start remain unchanged, and latency has
// dedicated cancellation assertions and benchmark gates.
fn launch_poll_timeout_ms() -> Int {
  5000
}

fn await_utf8_terminal(
  handle: Int,
  started: Int,
  timeout_ms: Int,
  streamed: String,
) -> Nil {
  case process.poll(handle) {
    ProcessRunning ->
      case sys.now_ms() - started < timeout_ms {
        True -> {
          fs.sleep(5)
          await_utf8_terminal(handle, started, timeout_ms, streamed)
        }
        False -> panic as "test UTF-8 polling timed out"
      }
    ProcessOutput(chunk) -> {
      // Each public String event must be valid UTF-8 even when the operating
      // system splits a codepoint across two pipe reads.
      let _ = string.to_graphemes(chunk)
      case chunk == "A" || chunk == "🦘B" || chunk == "A🦘B" {
        True -> Nil
        False -> {
          let message = "unexpected UTF-8 chunk: " <> chunk
          panic as message
        }
      }
      await_utf8_terminal(handle, started, timeout_ms, streamed <> chunk)
    }
    ProcessFinished(completed) -> {
      assert streamed == "A🦘B"
      assert completed.output == "A🦘B"
    }
    ProcessCancelled -> panic as "UTF-8 child was cancelled"
    ProcessFailed(message) -> panic as message
  }
}

fn await_invalid_utf8_terminal(
  handle: Int,
  started: Int,
  timeout_ms: Int,
  streamed: String,
) -> Nil {
  case process.poll(handle) {
    ProcessRunning ->
      case sys.now_ms() - started < timeout_ms {
        True -> {
          fs.sleep(5)
          await_invalid_utf8_terminal(handle, started, timeout_ms, streamed)
        }
        False -> panic as "test invalid UTF-8 polling timed out"
      }
    ProcessOutput(chunk) -> {
      let _ = string.to_graphemes(chunk)
      await_invalid_utf8_terminal(
        handle,
        started,
        timeout_ms,
        streamed <> chunk,
      )
    }
    ProcessFinished(completed) -> {
      assert streamed == "A�B"
      assert completed.output == "A�B"
    }
    ProcessCancelled -> panic as "invalid UTF-8 child was cancelled"
    ProcessFailed(message) -> panic as message
  }
}

fn await_until(
  handle: Int,
  started: Int,
  timeout_ms: Int,
) -> process.ProcessPoll {
  case process.poll(handle) {
    ProcessRunning ->
      case sys.now_ms() - started < timeout_ms {
        True -> {
          fs.sleep(5)
          await_until(handle, started, timeout_ms)
        }
        False -> ProcessFailed("test polling timed out")
      }
    ProcessOutput(_) -> await_until(handle, started, timeout_ms)
    finished -> finished
  }
}

fn await_output(handle: Int, timeout_ms: Int) -> process.ProcessPoll {
  let started = sys.now_ms()
  await_output_until(handle, started, timeout_ms)
}

fn await_output_containing(
  handle: Int,
  expected: String,
  timeout_ms: Int,
) -> Result(String, String) {
  await_output_containing_until(handle, expected, sys.now_ms(), timeout_ms, "")
}

fn await_output_containing_until(
  handle: Int,
  expected: String,
  started: Int,
  timeout_ms: Int,
  output: String,
) -> Result(String, String) {
  case process.poll(handle) {
    ProcessOutput(chunk) -> {
      let output = output <> chunk
      case string.contains(output, expected) {
        True -> Ok(output)
        False ->
          await_output_containing_until(
            handle,
            expected,
            started,
            timeout_ms,
            output,
          )
      }
    }
    ProcessRunning ->
      case sys.now_ms() - started < timeout_ms {
        True -> {
          fs.sleep(5)
          await_output_containing_until(
            handle,
            expected,
            started,
            timeout_ms,
            output,
          )
        }
        False -> Error("test output polling timed out: " <> output)
      }
    ProcessFinished(completed) ->
      case string.contains(completed.output, expected) {
        True -> Ok(completed.output)
        False ->
          Error("process exited before expected output: " <> completed.output)
      }
    ProcessCancelled -> Error("process was cancelled before expected output")
    ProcessFailed(message) -> Error(message)
  }
}

fn await_output_until(
  handle: Int,
  started: Int,
  timeout_ms: Int,
) -> process.ProcessPoll {
  case process.poll(handle) {
    ProcessRunning ->
      case sys.now_ms() - started < timeout_ms {
        True -> {
          fs.sleep(5)
          await_output_until(handle, started, timeout_ms)
        }
        False -> ProcessFailed("test output polling timed out")
      }
    output -> output
  }
}
