import gleam/option.{None, Some}
import kangaroo/internal/daemon
import kangaroo/internal/legacy/expect.{expect, to_equal}
import kangaroo/internal/legacy/suite.{it, suite}
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

pub fn suites() {
  [
    suite("daemon operation registry", [
      it("rejects duplicate active operation ids", fn() {
        let assert Ok(state) =
          operations.start(operations.empty(), "run-1", 10, RunOperation)
        expect(operations.start(state, "run-1", 11, RunOperation))
        |> to_equal(Error("operation `run-1` is already active"))
      }),
      it("returns exactly one handle for cancellation", fn() {
        let assert Ok(state) =
          operations.start(operations.empty(), "watch-1", 42, WatchOperation)
        let #(cancelled, handle) = operations.cancel(state, "watch-1")
        expect(handle) |> to_equal(Some(42))
        expect(operations.cancel(cancelled, "watch-1").1) |> to_equal(None)
      }),
      it("ignores stale completion after cancellation", fn() {
        let assert Ok(state) =
          operations.start(operations.empty(), "run-1", 7, RunOperation)
        let #(cancelled, _) = operations.cancel(state, "run-1")
        let #(unchanged, publish) = operations.complete(cancelled, "run-1")
        expect(publish) |> to_equal(False)
        expect(unchanged) |> to_equal(cancelled)
      }),
      it("returns all handles on shutdown in registration order", fn() {
        let assert Ok(first) =
          operations.start(operations.empty(), "a", 1, RunOperation)
        let assert Ok(second) = operations.start(first, "b", 2, WatchOperation)
        let #(empty, handles) = operations.shutdown(second)
        expect(handles) |> to_equal([1, 2])
        expect(operations.entries(empty)) |> to_equal([])
      }),
      it("reassembles streamed protocol lines across arbitrary chunks", fn() {
        let assert Ok(state) =
          operations.start(operations.empty(), "run-1", 9, RunOperation)
        let #(state, first_lines) =
          operations.append_output(state, "run-1", "{\"type\":\"ev")
        expect(first_lines) |> to_equal([])
        let #(state, lines) =
          operations.append_output(
            state,
            "run-1",
            "ent\"}\ncompiler log\npartial",
          )
        expect(lines) |> to_equal(["{\"type\":\"event\"}", "compiler log"])
        let #(state, remainder) = operations.finish_output(state, "run-1")
        expect(remainder) |> to_equal(Some("partial"))
        case operations.entries(state) {
          [_] -> Nil
          _ -> panic as "finishing output must not remove the operation"
        }
      }),
      it("uses a public coordinator process only for daemon watch", fn() {
        expect(
          daemon.operation_arguments(RunOperation, "javascript", "bun", [
            "--reporter",
            "ndjson",
          ]),
        )
        |> to_equal([
          "test",
          "--target",
          "javascript",
          "--runtime",
          "bun",
          "--",
          "--reporter",
          "ndjson",
        ])
        expect(
          daemon.operation_arguments(WatchOperation, "erlang", "erlang", [
            "--reporter",
            "ndjson",
          ]),
        )
        |> to_equal([
          "run",
          "--target",
          "erlang",
          "-m",
          "kangaroo",
          "--",
          "watch",
          "--reporter",
          "ndjson",
        ])
      }),
    ]),
  ]
}
