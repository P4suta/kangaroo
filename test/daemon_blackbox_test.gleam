import gleam/list
import gleam/string
import kangaroo/internal/fs
import kangaroo/internal/process
import kangaroo/internal/vm
import kangaroo/internal/watcher
import kangaroo/sys

pub fn completed_record_matching_allows_a_trailing_fragment_test() {
  assert completed_output_contains(
    "{\"type\":\"discovered\"}\n{\"type\":\"part",
    "\"type\":\"discovered\"",
  )
  assert !completed_output_contains("{\"type\":\"part", "\"type\":\"part")
}

fn completed_output_contains(output: String, expected: String) -> Bool {
  let lines = string.split(output, "\n")
  lines
  |> list.take(list.length(lines) - 1)
  |> list.any(fn(line) { string.contains(line, expected) })
}

pub fn daemon_bidirectional_protocol_and_cancellation_test() {
  let root_build = "build/dev/" <> vm.target()
  assert fs.is_directory(root_build)
  let assert Ok(handle) =
    process.start(
      "fixtures/coverage_project",
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
    await_contains(handle, "\"type\":\"discovered\"", 15_000, "")
  assert string.contains(
    discovery,
    "test/kangaroo_coverage_fixture_test.gleam::covered_test",
  )
  assert string.contains(discovery, "\"line\":8")

  process.write(
    handle,
    "{\"protocol_version\":1,\"id\":\"run-1\",\"command\":\"run\",\"selectors\":[\"test/kangaroo_coverage_fixture_test.gleam::covered_test\"]}\n",
  )
  let assert Ok(run_output) =
    await_contains(
      handle,
      "\"type\":\"completed\",\"request_id\":\"run-1\"",
      // This is a functional protocol assertion. The child compile/run can
      // share a constrained host with the process stress cases; cancellation
      // latency is asserted independently below and in the benchmark gate.
      30_000,
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
  // The nested compiler belongs to the fixture project. It must never clean
  // or replace the outer test runner's live module tree.
  assert fs.is_directory(root_build)
}

pub fn overlong_fragmented_request_is_rejected_without_poisoning_daemon_test() {
  let assert Ok(handle) =
    process.start(
      "fixtures/coverage_project",
      "gleam",
      watcher.coordinator_arguments_for(vm.target(), vm.runtime_name(), [
        "daemon",
      ]),
      [],
      30_000,
    )

  // Do not charge compiler/runtime startup to the bounded-input response
  // deadline. The first complete protocol response proves that the daemon's
  // stdin reader and coordinator loop are ready before the large write.
  process.write(
    handle,
    "{\"protocol_version\":1,\"id\":\"ready-limit\",\"command\":\"discover\"}\n",
  )
  let assert Ok(_) =
    await_contains(handle, "\"type\":\"discovered\"", 15_000, "")

  process.write(handle, string.repeat("x", 1_048_577) <> "\n")
  let assert Ok(output) =
    await_contains(
      handle,
      "daemon request line exceeded 1048576 bytes",
      5000,
      "",
    )
  assert string.contains(output, "\"type\":\"error\"")

  process.write(
    handle,
    "{\"protocol_version\":1,\"id\":\"shutdown-after-limit\",\"command\":\"shutdown\"}\n",
  )
  let assert Ok(completed) = await_completion(handle, 5000, output)
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
  // A pipe read may stop halfway through one NDJSON object, notably on
  // Windows. Only inspect protocol output after its terminating newline has
  // arrived so assertions never observe a partial discovery response.
  case completed_output_contains(output, expected) {
    True -> Ok(output)
    False ->
      case sys.now_ms() - started < timeout_ms {
        False -> Error("timed out waiting for " <> expected <> ":\n" <> output)
        True ->
          case process.poll(handle) {
            process.ProcessOutput(chunk) ->
              await_contains_until(
                handle,
                expected,
                started,
                timeout_ms,
                output <> chunk,
              )
            process.ProcessRunning -> {
              fs.sleep(5)
              await_contains_until(
                handle,
                expected,
                started,
                timeout_ms,
                output,
              )
            }
            process.ProcessFinished(completed) ->
              Error(
                "daemon exited before " <> expected <> ":\n" <> completed.output,
              )
            process.ProcessCancelled -> Error("daemon was cancelled")
            process.ProcessFailed(message) -> Error(message)
          }
      }
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
  case sys.now_ms() - started < timeout_ms {
    False -> Error("daemon shutdown timed out:\n" <> output)
    True ->
      case process.poll(handle) {
        process.ProcessRunning -> {
          fs.sleep(5)
          await_completion_until(handle, started, timeout_ms, output)
        }
        process.ProcessOutput(chunk) ->
          await_completion_until(handle, started, timeout_ms, output <> chunk)
        process.ProcessFinished(completed) -> Ok(completed)
        process.ProcessCancelled -> Error("daemon was unexpectedly cancelled")
        process.ProcessFailed(message) ->
          Error("daemon process failed: " <> message <> "\n" <> output)
      }
  }
}
