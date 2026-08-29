import gleam/string
import kangaroo/internal/fs
import kangaroo/internal/process
import kangaroo/internal/vm
import kangaroo/internal/watcher
import kangaroo/sys

pub fn daemon_bidirectional_protocol_and_cancellation_test() {
  let assert Ok(handle) =
    process.start(
      ".",
      "gleam",
      watcher.coordinator_arguments_for(vm.target(), vm.runtime_name(), [
        "daemon",
      ]),
      [],
      30_000,
    )

  process.write(
    handle,
    "{\"protocol_version\":1,\"id\":\"discover-1\",\"command\":\"discover\"}\n",
  )
  let assert Ok(discovery) =
    await_contains(handle, "\"type\":\"discovered\"", 5000, "")
  assert string.contains(discovery, "test/v1/passing.gleam::fixture_test")
  assert string.contains(discovery, "\"line\":1")

  process.write(
    handle,
    "{\"protocol_version\":1,\"id\":\"run-1\",\"command\":\"run\",\"selectors\":[\"test/v1/passing.gleam::fixture_test\"]}\n",
  )
  let assert Ok(run_output) =
    await_contains(
      handle,
      "\"type\":\"completed\",\"request_id\":\"run-1\"",
      10_000,
      "",
    )
  assert string.contains(run_output, "\"type\":\"started\"")
  assert string.contains(run_output, "\"type\":\"event\"")
  assert string.contains(run_output, "\"exit_code\":0")

  process.write(
    handle,
    "{\"protocol_version\":1,\"id\":\"watch-1\",\"command\":\"watch\"}\n",
  )
  let assert Ok(_) = await_contains(handle, "\"operation\":\"watch\"", 5000, "")
  let cancellation_started = sys.now_ms()
  process.write(
    handle,
    "{\"protocol_version\":1,\"id\":\"cancel-1\",\"command\":\"cancel\",\"operation_id\":\"watch-1\"}\n",
  )
  let assert Ok(cancelled) =
    await_contains(handle, "\"type\":\"cancelled\"", 1000, "")
  assert string.contains(cancelled, "\"operation_id\":\"watch-1\"")
  assert sys.now_ms() - cancellation_started < 500

  process.write(
    handle,
    "{\"protocol_version\":1,\"id\":\"shutdown-1\",\"command\":\"shutdown\"}\n",
  )
  let assert Ok(completed) = await_completion(handle, 5000, "")
  assert completed.exit_code == 0
  assert string.contains(completed.output, "\"type\":\"shutdown\"")
}

fn await_contains(
  handle: Int,
  expected: String,
  timeout_ms: Int,
  output: String,
) -> Result(String, String) {
  let started = sys.now_ms()
  await_contains_until(handle, expected, started, timeout_ms, output)
}

fn await_contains_until(handle, expected, started, timeout_ms, output) {
  case process.poll(handle) {
    process.ProcessOutput(chunk) -> {
      let output = output <> chunk
      case string.contains(output, expected) {
        True -> Ok(output)
        False ->
          await_contains_until(handle, expected, started, timeout_ms, output)
      }
    }
    process.ProcessRunning ->
      case sys.now_ms() - started < timeout_ms {
        True -> {
          fs.sleep(5)
          await_contains_until(handle, expected, started, timeout_ms, output)
        }
        False -> Error("timed out waiting for " <> expected <> ":\n" <> output)
      }
    process.ProcessFinished(completed) ->
      Error("daemon exited before " <> expected <> ":\n" <> completed.output)
    process.ProcessCancelled -> Error("daemon was cancelled")
    process.ProcessFailed(message) -> Error(message)
  }
}

fn await_completion(
  handle: Int,
  timeout_ms: Int,
  output: String,
) -> Result(process.ProcessResult, String) {
  let started = sys.now_ms()
  await_completion_until(handle, started, timeout_ms, output)
}

fn await_completion_until(handle, started, timeout_ms, output) {
  case process.poll(handle) {
    process.ProcessRunning ->
      case sys.now_ms() - started < timeout_ms {
        True -> {
          fs.sleep(5)
          await_completion_until(handle, started, timeout_ms, output)
        }
        False -> Error("daemon shutdown timed out:\n" <> output)
      }
    process.ProcessOutput(chunk) ->
      await_completion_until(handle, started, timeout_ms, output <> chunk)
    process.ProcessFinished(completed) -> Ok(completed)
    process.ProcessCancelled -> Error("daemon was unexpectedly cancelled")
    process.ProcessFailed(message) ->
      Error("daemon process failed: " <> message <> "\n" <> output)
  }
}
