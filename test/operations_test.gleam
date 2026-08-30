import gleam/int
import gleam/option.{None, Some}
import kangaroo/internal/daemon
import kangaroo/internal/operations.{RunOperation, WatchOperation}

pub fn javascript_daemon_watch_uses_streaming_runtime_entrypoint_test() {
  let runner = "build/dev/javascript/kangaroo/kangaroo_daemon_child.mjs"

  assert daemon.operation_executable(WatchOperation, "javascript", "node")
    == "node"
  assert daemon.javascript_watch_arguments("node", runner, [
      "--reporter",
      "ndjson",
    ])
    == [runner, "watch", "--reporter", "ndjson"]

  assert daemon.operation_executable(WatchOperation, "javascript", "bun")
    == "bun"
  assert daemon.javascript_watch_arguments("bun", runner, [])
    == [runner, "watch"]

  assert daemon.operation_executable(WatchOperation, "javascript", "deno")
    == "deno"
  assert daemon.javascript_watch_arguments("deno", runner, [])
    == [
      "run",
      "--allow-env",
      "--allow-read",
      "--allow-run",
      "--allow-sys",
      "--allow-write",
      runner,
      "watch",
    ]
}

pub fn erlang_daemon_watch_uses_direct_runtime_entrypoint_test() {
  assert daemon.operation_executable(WatchOperation, "erlang", "erlang")
    == "erl"
  assert daemon.operation_arguments(WatchOperation, "erlang", "erlang", [
      "--reporter",
      "ndjson",
    ])
    == [
      "-noshell",
      "-eval",
      "code:add_paths(filelib:wildcard(\"build/dev/erlang/*/ebin\")), kangaroo:main().",
      "-extra",
      "watch",
      "--reporter",
      "ndjson",
    ]
}

pub fn duplicate_active_operation_ids_are_rejected_test() {
  let assert Ok(state) =
    operations.start(operations.empty(), "run-1", 10, RunOperation)
  assert operations.start(state, "run-1", 11, RunOperation)
    == Error("operation `run-1` is already active")
}

pub fn daemon_operation_limit_is_checked_before_spawning_test() {
  let state = fill_operations(operations.empty(), 1)
  assert operations.can_start(state, "overflow")
    == Error("daemon supports at most 32 active operations")
  assert operations.start(state, "overflow", 99, RunOperation)
    == Error("daemon supports at most 32 active operations")
}

fn fill_operations(state: operations.State, number: Int) -> operations.State {
  case number > 32 {
    True -> state
    False -> {
      let assert Ok(state) =
        operations.start(
          state,
          "run-" <> int.to_string(number),
          number,
          RunOperation,
        )
      fill_operations(state, number + 1)
    }
  }
}

pub fn cancellation_returns_exactly_one_handle_test() {
  let assert Ok(state) =
    operations.start(operations.empty(), "watch-1", 42, WatchOperation)
  let #(cancelled, handle) = operations.cancel(state, "watch-1")
  assert handle == Some(42)
  assert operations.cancel(cancelled, "watch-1").1 == None
}

pub fn cancellation_lookup_retains_operation_until_cleanup_succeeds_test() {
  let assert Ok(state) =
    operations.start(operations.empty(), "watch-1", 42, WatchOperation)
  assert operations.handle(state, "watch-1") == Some(42)
  assert operations.has(state, "watch-1")
}

pub fn stale_completion_after_cancellation_is_ignored_test() {
  let assert Ok(state) =
    operations.start(operations.empty(), "run-1", 7, RunOperation)
  let #(cancelled, _) = operations.cancel(state, "run-1")
  let #(unchanged, publish) = operations.complete(cancelled, "run-1")
  assert !publish
  assert unchanged == cancelled
}

pub fn shutdown_returns_handles_in_registration_order_test() {
  let assert Ok(first) =
    operations.start(operations.empty(), "a", 1, RunOperation)
  let assert Ok(second) = operations.start(first, "b", 2, WatchOperation)
  let #(empty, handles) = operations.shutdown(second)
  assert handles == [1, 2]
  assert operations.entries(empty) == []
}

pub fn streamed_protocol_lines_are_reassembled_across_chunks_test() {
  let assert Ok(state) =
    operations.start(operations.empty(), "run-1", 9, RunOperation)
  let assert Ok(state) =
    operations.append_output_checked(state, "run-1", "{\"type\":\"ev")
  let #(state, first_lines) = operations.take_output_lines(state, "run-1", 64)
  assert first_lines == []
  let assert Ok(state) =
    operations.append_output_checked(
      state,
      "run-1",
      "ent\"}\ncompiler log\npartial",
    )
  let #(state, lines) = operations.take_output_lines(state, "run-1", 64)
  assert lines == ["{\"type\":\"event\"}", "compiler log"]
  let #(state, remainder) = operations.finish_output(state, "run-1")
  assert remainder == Some("partial")
  let assert [_] = operations.entries(state)
}

pub fn buffered_output_is_taken_with_a_bounded_line_budget_test() {
  let assert Ok(state) =
    operations.start(operations.empty(), "run-1", 9, RunOperation)
  let assert Ok(state) =
    operations.append_output_checked(
      state,
      "run-1",
      "one\ntwo\nthree\nfour\nfive\ntrailing",
    )
  let #(state, first) = operations.take_output_lines(state, "run-1", 2)
  assert first == ["one", "two"]
  let #(state, second) = operations.take_output_lines(state, "run-1", 2)
  assert second == ["three", "four"]
  let #(state, third) = operations.take_output_lines(state, "run-1", 2)
  assert third == ["five"]
  let #(_, remainder) = operations.finish_output(state, "run-1")
  assert remainder == Some("trailing")
}

pub fn unterminated_output_fragments_preserve_order_without_repeated_joining_test() {
  let assert Ok(state) =
    operations.start(operations.empty(), "run-1", 9, RunOperation)
  let assert Ok(state) = operations.append_output_checked(state, "run-1", "one")
  let assert Ok(state) = operations.append_output_checked(state, "run-1", "two")
  let #(state, lines) = operations.take_output_lines(state, "run-1", 64)
  assert lines == []
  let assert Ok(state) =
    operations.append_output_checked(state, "run-1", "three\ntrailing")
  let #(state, lines) = operations.take_output_lines(state, "run-1", 64)
  assert lines == ["onetwothree"]
  let #(_, remainder) = operations.finish_output(state, "run-1")
  assert remainder == Some("trailing")
}

pub fn daemon_stream_buffer_is_bounded_after_consumed_lines_are_released_test() {
  let assert Ok(state) =
    operations.start(operations.empty(), "run-1", 9, RunOperation)
  let assert Ok(state) =
    operations.append_output_with_limit(state, "run-1", "one\npending", 11)
  let #(state, lines) = operations.take_output_lines(state, "run-1", 1)
  assert lines == ["one"]
  let assert Ok(state) =
    operations.append_output_with_limit(state, "run-1", "123", 10)
  assert operations.append_output_with_limit(state, "run-1", "x", 10)
    == Error("process output exceeded 16777216 bytes")

  let failed = operations.fail(state, "run-1", "buffer limit")
  let assert [entry] = operations.entries(failed)
  assert entry.terminal_error == Some("buffer limit")
}

pub fn operations_are_routed_to_runtime_commands_test() {
  assert daemon.operation_arguments(RunOperation, "javascript", "bun", [
      "--reporter",
      "ndjson",
    ])
    == [
      "test",
      "--target",
      "javascript",
      "--runtime",
      "bun",
      "--",
      "run",
      "--reporter",
      "ndjson",
    ]
  assert daemon.operation_arguments(WatchOperation, "erlang", "erlang", [
      "--reporter",
      "ndjson",
    ])
    == [
      "-noshell",
      "-eval",
      "code:add_paths(filelib:wildcard(\"build/dev/erlang/*/ebin\")), kangaroo:main().",
      "-extra",
      "watch",
      "--reporter",
      "ndjson",
    ]
}
