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

const javascript_input_poll_ms = 150

const operation_timeout_ms = 604_800_000

const max_output_work_per_operation_poll = 64

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

type CancellationOutcome {
  CancellationSettled
  CancellationTimedOut(message: String)
  CancellationFailed(message: String)
}

pub fn operation_arguments(
  kind: operations.Kind,
  target: String,
  runtime: String,
  run_arguments: List(String),
) -> List(String) {
  case kind, target {
    RunOperation, _ ->
      watcher.run_arguments_for(target, runtime, ["run", ..run_arguments])
    WatchOperation, "erlang" ->
      watcher.erlang_runtime_arguments(["watch", ..run_arguments])
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
    fs.InputError(message) -> {
      fs.write_stdout_line(protocol.encode_error("", message))
      loop(project_dir, state)
    }
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
      case operations.handle(state.operations, operation_id) {
        None -> {
          fs.write_stdout_line(protocol.encode_error(
            id,
            "operation `" <> operation_id <> "` is not active",
          ))
          #(state, True)
        }
        Some(handle) -> {
          process.cancel(handle)
          case await_cancellation(handle, sys.now_ms()) {
            CancellationSettled -> {
              let #(operations, _) =
                operations.cancel(state.operations, operation_id)
              fs.write_stdout_line(protocol.encode_cancelled(id, operation_id))
              #(State(..state, operations:), True)
            }
            CancellationFailed(message) -> {
              let #(operations, _) =
                operations.cancel(state.operations, operation_id)
              fs.write_stdout_line(protocol.encode_error(id, message))
              #(State(..state, operations:), True)
            }
            CancellationTimedOut(message) -> {
              fs.write_stdout_line(protocol.encode_error(id, message))
              #(state, True)
            }
          }
        }
      }
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
  case operations.can_start(state, id) {
    Error(message) -> {
      fs.write_stdout_line(protocol.encode_error(id, message))
      state
    }
    Ok(_) ->
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
            process.start_streaming(
              project_dir,
              executable,
              arguments,
              protocol.child_environment(id),
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
// a bounded burst before reading stdin again. Both complete lines and chunks
// without a newline consume this budget, so adversarial output cannot starve a
// later cancellation or shutdown request.
fn drain_operation(state: operations.State, entry: operations.Entry) {
  drain_operation_output(state, entry, max_output_work_per_operation_poll)
}

fn drain_operation_output(
  state: operations.State,
  entry: operations.Entry,
  remaining: Int,
) {
  let #(state, lines) = operations.take_output_lines(state, entry.id, remaining)
  emit_lines(entry.id, lines)
  let remaining = remaining - list.length(lines)
  case remaining <= 0 {
    True -> state
    False ->
      case process.poll(entry.handle) {
        process.ProcessRunning -> state
        process.ProcessOutput(output) ->
          case operations.append_output_checked(state, entry.id, output) {
            Ok(state) -> drain_operation_output(state, entry, remaining - 1)
            Error(message) -> {
              process.cancel(entry.handle)
              operations.fail(state, entry.id, message)
            }
          }
        process.ProcessFinished(completed) -> {
          case entry.terminal_error {
            Some(message) -> complete_with_error(state, entry.id, message)
            None -> {
              let #(state, remainder) =
                operations.finish_output(state, entry.id)
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
          }
        }
        process.ProcessFailed(message) -> {
          case entry.terminal_error {
            Some(primary) -> complete_with_error(state, entry.id, primary)
            None -> {
              let #(state, remainder) =
                operations.finish_output(state, entry.id)
              case remainder {
                Some(line) -> emit_line(entry.id, line)
                None -> Nil
              }
              complete_with_error(state, entry.id, message)
            }
          }
        }
        process.ProcessCancelled ->
          case entry.terminal_error {
            Some(message) -> complete_with_error(state, entry.id, message)
            None -> operations.complete(state, entry.id).0
          }
      }
  }
}

fn complete_with_error(
  state: operations.State,
  operation_id: String,
  message: String,
) -> operations.State {
  let #(state, publish) = operations.complete(state, operation_id)
  case publish {
    True -> fs.write_stdout_line(protocol.encode_error(operation_id, message))
    False -> Nil
  }
  state
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
  let started = sys.now_ms()
  list.each(handles, fn(handle) {
    case await_cancellation(handle, started) {
      CancellationSettled -> Nil
      CancellationTimedOut(message) | CancellationFailed(message) ->
        fs.write_stderr_line("kangaroo: " <> message)
    }
  })
}

fn await_cancellation(handle: Int, started: Int) -> CancellationOutcome {
  case process.poll(handle) {
    process.ProcessRunning | process.ProcessOutput(_) ->
      case
        vm.cleanup_wait_result(
          sys.now_ms() - started,
          vm.process_cleanup_timeout_ms(),
        )
      {
        Ok(_) -> {
          fs.sleep(5)
          await_cancellation(handle, started)
        }
        Error(message) -> CancellationTimedOut(message)
      }
    process.ProcessCancelled | process.ProcessFinished(_) -> CancellationSettled
    process.ProcessFailed(message) -> CancellationFailed(message)
  }
}
