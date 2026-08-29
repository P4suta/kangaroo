import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import kangaroo/internal/app
import kangaroo/internal/command.{Ndjson, RunOptions}
import kangaroo/internal/discovery
import kangaroo/internal/fs
import kangaroo/internal/operations.{RunOperation, WatchOperation}
import kangaroo/internal/process
import kangaroo/internal/protocol.{
  CancelRequest, DiscoverRequest, RunRequest, ShutdownRequest, WatchRequest,
}
import kangaroo/internal/selector
import kangaroo/internal/vm
import kangaroo/internal/watcher
import kangaroo/sys

const erlang_input_poll_ms = 35

const javascript_input_poll_ms = 100

const operation_timeout_ms = 604_800_000

const cancellation_timeout_ms = 250

const erlang_watch_eval = "code:add_paths(filelib:wildcard(\"build/dev/erlang/*/ebin\")), kangaroo:main()."

pub fn poll_interval_ms() -> Int {
  poll_interval_for(vm.target())
}

pub fn poll_interval_for(target: String) -> Int {
  case target {
    "javascript" -> javascript_input_poll_ms
    _ -> erlang_input_poll_ms
  }
}

type State {
  State(operations: operations.State, discovery_cache: discovery.Cache)
}

pub fn operation_arguments(
  kind: operations.Kind,
  target: String,
  runtime: String,
  run_arguments: List(String),
) -> List(String) {
  case kind, target {
    RunOperation, _ -> watcher.run_arguments_for(target, runtime, run_arguments)
    WatchOperation, "erlang" -> [
      "-noshell",
      "-eval",
      erlang_watch_eval,
      "-extra",
      "watch",
      ..run_arguments
    ]
    WatchOperation, "javascript" ->
      javascript_watch_arguments(
        runtime,
        vm.daemon_runner_path(),
        run_arguments,
      )
    WatchOperation, _ ->
      watcher.coordinator_arguments_for(target, runtime, [
        "watch",
        ..run_arguments
      ])
  }
}

pub fn javascript_watch_arguments(
  runtime: String,
  runner: String,
  run_arguments: List(String),
) -> List(String) {
  case runtime {
    "deno" -> [
      "run",
      "--allow-env",
      "--allow-read",
      "--allow-run",
      "--allow-sys",
      "--allow-write",
      runner,
      "watch",
      ..run_arguments
    ]
    _ -> [runner, "watch", ..run_arguments]
  }
}

/// JavaScript watch coordinators run their built module directly. Gleam's
/// JavaScript launcher retains a long-lived child's output until it exits,
/// which would prevent a daemon watch from streaming protocol events.
pub fn operation_executable(
  kind: operations.Kind,
  target: String,
  runtime: String,
) -> String {
  case kind, target, runtime {
    WatchOperation, "erlang", _ -> "erl"
    WatchOperation, "javascript", "node" -> "node"
    WatchOperation, "javascript", "bun" -> "bun"
    WatchOperation, "javascript", "deno" -> "deno"
    WatchOperation, "javascript", runtime -> runtime
    _, _, _ -> "gleam"
  }
}

/// Runs the protocol-v1 stdin/stdout loop. Stdout is protocol-only; callers
/// must send operational logs to stderr.
pub fn run(project_dir: String) -> Nil {
  loop(project_dir, State(operations.empty(), discovery.empty_cache()))
  fs.close_input()
}

fn loop(project_dir: String, state: State) -> Nil {
  let state = State(..state, operations: drain_operations(state.operations))
  case fs.read_line_timeout(poll_interval_ms()) {
    fs.InputPending -> loop(project_dir, state)
    fs.InputEnd -> stop_operations(state.operations)
    fs.InputLine(line) -> {
      let #(state, continue) = case string.trim(line) {
        "" -> #(state, True)
        line -> handle(project_dir, state, protocol.decode_request(line))
      }
      case continue {
        True -> loop(project_dir, state)
        False -> stop_operations(state.operations)
      }
    }
  }
}

fn handle(
  project_dir: String,
  state: State,
  decoded: Result(protocol.Request, String),
) -> #(State, Bool) {
  case decoded {
    Error(message) -> {
      fs.write_stdout_line(protocol.encode_error("", message))
      #(state, True)
    }
    Ok(DiscoverRequest(id)) -> {
      let started = sys.now_ms()
      case
        app.list_configured_project_cached(
          project_dir,
          state.discovery_cache,
          [],
          [],
          [],
        )
      {
        Ok(discovered) -> {
          trace_benchmark("discover.index", started)
          let encoding_started = sys.now_ms()
          let response = protocol.encode_discovered(id, discovered.tests)
          trace_benchmark("discover.encode", encoding_started)
          let write_started = sys.now_ms()
          fs.write_stdout_line(response)
          trace_benchmark("discover.write", write_started)
          #(State(..state, discovery_cache: discovered.cache), True)
        }
        Error(message) -> {
          fs.write_stdout_line(protocol.encode_error(id, message))
          #(state, True)
        }
      }
    }
    Ok(RunRequest(id, raw, include_tags, exclude_tags)) -> {
      #(
        State(
          ..state,
          operations: start_operation(
            project_dir,
            state.operations,
            id,
            raw,
            include_tags,
            exclude_tags,
            RunOperation,
          ),
        ),
        True,
      )
    }
    Ok(WatchRequest(id, raw, include_tags, exclude_tags)) -> {
      #(
        State(
          ..state,
          operations: start_operation(
            project_dir,
            state.operations,
            id,
            raw,
            include_tags,
            exclude_tags,
            WatchOperation,
          ),
        ),
        True,
      )
    }
    Ok(CancelRequest(id, operation_id)) -> {
      let #(operations, handle) =
        operations.cancel(state.operations, operation_id)
      case handle {
        None ->
          fs.write_stdout_line(protocol.encode_error(
            id,
            "operation `" <> operation_id <> "` is not active",
          ))
        Some(handle) -> {
          process.cancel(handle)
          await_cancellation(handle, sys.now_ms())
          fs.write_stdout_line(protocol.encode_cancelled(id, operation_id))
        }
      }
      #(State(..state, operations:), True)
    }
    Ok(ShutdownRequest(id)) -> {
      fs.write_stdout_line(protocol.encode_ok(id, "shutdown"))
      #(state, False)
    }
  }
}

fn trace_benchmark(label: String, started: Int) -> Nil {
  case sys.env("KANGAROO_BENCHMARK_TRACE") {
    Some(_) ->
      fs.write_stderr_line(
        "kangaroo benchmark: "
        <> label
        <> " "
        <> int.to_string(sys.now_ms() - started)
        <> "ms",
      )
    None -> Nil
  }
}

fn start_operation(
  project_dir: String,
  state: operations.State,
  id: String,
  raw_selectors: List(String),
  include_tags: List(String),
  exclude_tags: List(String),
  kind: operations.Kind,
) -> operations.State {
  case operations.has(state, id) {
    True -> {
      fs.write_stdout_line(protocol.encode_error(
        id,
        "operation `" <> id <> "` is already active",
      ))
      state
    }
    False ->
      case list.try_map(raw_selectors, selector.parse) {
        Error(message) -> {
          fs.write_stdout_line(protocol.encode_error(id, message))
          state
        }
        Ok(_) -> {
          let options =
            RunOptions(
              ..command.default_run_options(),
              selectors: raw_selectors,
              include_tags:,
              exclude_tags:,
              reporter: Ndjson,
            )
          let run_arguments = command.run_arguments(options, raw_selectors)
          let executable =
            operation_executable(kind, vm.target(), vm.runtime_name())
          let arguments =
            operation_arguments(
              kind,
              vm.target(),
              vm.runtime_name(),
              run_arguments,
            )
          case
            process.start(
              project_dir,
              executable,
              arguments,
              [#("KANGAROO_PROTOCOL_REQUEST_ID", id)],
              operation_timeout_ms,
            )
          {
            Error(message) -> {
              fs.write_stdout_line(protocol.encode_error(id, message))
              state
            }
            Ok(handle) ->
              case operations.start(state, id, handle, kind) {
                Error(message) -> {
                  process.cancel(handle)
                  fs.write_stdout_line(protocol.encode_error(id, message))
                  state
                }
                Ok(state) -> {
                  fs.write_stdout_line(
                    protocol.encode_started(id, id, case kind {
                      RunOperation -> "run"
                      WatchOperation -> "watch"
                    }),
                  )
                  state
                }
              }
          }
        }
      }
  }
}

fn drain_operations(state: operations.State) -> operations.State {
  list.fold(operations.entries(state), state, fn(state, entry) {
    drain_operation(state, entry)
  })
}

// Child output commonly arrives as one port message per reporter event. Drain
// every message already waiting before the daemon sleeps again so a large
// event burst cannot delay later change or cancellation notifications by one
// full protocol poll per line.
fn drain_operation(state: operations.State, entry: operations.Entry) {
  case process.poll(entry.handle) {
    process.ProcessRunning -> state
    process.ProcessOutput(output) -> {
      let #(state, lines) = operations.append_output(state, entry.id, output)
      emit_lines(entry.id, lines)
      drain_operation(state, entry)
    }
    process.ProcessFinished(completed) -> {
      let #(state, remainder) = operations.finish_output(state, entry.id)
      case remainder {
        Some(line) -> emit_line(entry.id, line)
        None -> Nil
      }
      let #(state, publish) = operations.complete(state, entry.id)
      case publish {
        True ->
          fs.write_stdout_line(protocol.encode_completed(
            entry.id,
            completed.exit_code,
          ))
        False -> Nil
      }
      state
    }
    process.ProcessFailed(message) -> {
      let #(state, remainder) = operations.finish_output(state, entry.id)
      case remainder {
        Some(line) -> emit_line(entry.id, line)
        None -> Nil
      }
      let #(state, publish) = operations.complete(state, entry.id)
      case publish {
        True -> fs.write_stdout_line(protocol.encode_error(entry.id, message))
        False -> Nil
      }
      state
    }
    process.ProcessCancelled -> {
      let #(state, _) = operations.complete(state, entry.id)
      state
    }
  }
}

fn emit_lines(operation_id: String, lines: List(String)) -> Nil {
  list.each(lines, fn(line) { emit_line(operation_id, line) })
}

fn emit_line(operation_id: String, line: String) -> Nil {
  let line = string.trim(line)
  case line {
    "" -> Nil
    _ ->
      case protocol.forwardable_event(line, operation_id) {
        True -> fs.write_stdout_line(line)
        False -> fs.write_stderr_line(line)
      }
  }
}

fn stop_operations(state: operations.State) -> Nil {
  let #(_, handles) = operations.shutdown(state)
  list.each(handles, fn(handle) { process.cancel(handle) })
  list.each(handles, fn(handle) { await_cancellation(handle, sys.now_ms()) })
}

fn await_cancellation(handle: Int, started: Int) -> Nil {
  case process.poll(handle) {
    process.ProcessRunning | process.ProcessOutput(_) ->
      case sys.now_ms() - started < cancellation_timeout_ms {
        True -> {
          fs.sleep(5)
          await_cancellation(handle, started)
        }
        False -> Nil
      }
    _ -> Nil
  }
}
