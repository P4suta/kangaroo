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

pub fn cancellation_returns_exactly_one_handle_test() {
  let assert Ok(state) =
    operations.start(operations.empty(), "watch-1", 42, WatchOperation)
  let #(cancelled, handle) = operations.cancel(state, "watch-1")
  assert handle == Some(42)
  assert operations.cancel(cancelled, "watch-1").1 == None
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
  let #(state, first_lines) =
    operations.append_output(state, "run-1", "{\"type\":\"ev")
  assert first_lines == []
  let #(state, lines) =
    operations.append_output(state, "run-1", "ent\"}\ncompiler log\npartial")
  assert lines == ["{\"type\":\"event\"}", "compiler log"]
  let #(state, remainder) = operations.finish_output(state, "run-1")
  assert remainder == Some("partial")
  let assert [_] = operations.entries(state)
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
