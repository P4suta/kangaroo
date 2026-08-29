import gleam/string
import kangaroo/internal/fs
import kangaroo/internal/legacy/expect.{expect, to_be_true, to_equal}
import kangaroo/internal/legacy/suite.{it, suite}
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

@external(erlang, "kangaroo_cli_test_ffi", "tree_marker")
@external(javascript, "./kangaroo_cli_test_ffi.mjs", "tree_marker")
fn tree_marker() -> String

@external(erlang, "kangaroo_cli_test_ffi", "tree_arguments")
@external(javascript, "./kangaroo_cli_test_ffi.mjs", "tree_arguments")
fn tree_arguments(marker: String) -> List(String)

@external(erlang, "kangaroo_cli_test_ffi", "closed_stdin_tree_arguments")
@external(javascript, "./kangaroo_cli_test_ffi.mjs", "closed_stdin_tree_arguments")
fn closed_stdin_tree_arguments(marker: String) -> List(String)

pub fn closed_stdin_terminates_process_tree_test() {
  case vm.runtime_name() {
    "node" -> {
      let marker = tree_marker()
      let windows = vm.operating_system() == "windows"
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
          sleeper_executable(),
          closed_stdin_tree_arguments(marker),
          [],
          process_timeout,
        )
      let assert Ok(output) = await_output_containing(handle, "ready", 2000)
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
    _ -> Nil
  }
}

pub fn suites() {
  [
    suite("cancellable child processes", [
      it("polls a process to completion and captures output", fn() {
        let assert Ok(handle) =
          process.start(
            ".",
            sleeper_executable(),
            sleeper_arguments(10),
            [],
            2000,
          )
        let assert ProcessFinished(completed) = await_terminal(handle, 2000)
        expect(completed.exit_code) |> to_equal(0)
        expect(completed.output) |> to_equal("ready")
      }),
      it("cancels a running process without publishing completion", fn() {
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
        expect(await_terminal(handle, 1000)) |> to_equal(ProcessCancelled)
        expect(sys.now_ms() - started < 1000) |> to_be_true()
      }),
      it("streams output before the child process completes", fn() {
        let assert Ok(handle) =
          process.start(
            ".",
            sleeper_executable(),
            sleeper_arguments(2000),
            [],
            5000,
          )
        let assert ProcessOutput(output) = await_output(handle, 2000)
        expect(output) |> to_equal("ready")
        process.cancel(handle)
        let assert ProcessCancelled = await_terminal(handle, 1000)
        Nil
      }),
      it(
        "writes stdin to a running child without closing its process tree",
        fn() {
          let assert Ok(handle) =
            process.start(".", sleeper_executable(), echo_arguments(), [], 2000)
          process.write(handle, "kangaroo protocol\n")
          let assert ProcessFinished(completed) = await_terminal(handle, 2000)
          expect(completed.exit_code) |> to_equal(0)
          expect(completed.output) |> to_equal("kangaroo protocol\n")
        },
      ),
      it("cancels descendants in the same process tree", fn() {
        let marker = tree_marker()
        let assert Ok(handle) =
          process.start(
            ".",
            sleeper_executable(),
            tree_arguments(marker),
            [],
            10_000,
          )
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
        expect(survived) |> to_equal(False)
      }),
    ]),
  ]
}

fn await_terminal(handle: Int, timeout_ms: Int) -> process.ProcessPoll {
  let started = sys.now_ms()
  await_until(handle, started, timeout_ms)
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
