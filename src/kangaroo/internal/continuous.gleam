import gleam/dict.{type Dict}
import gleam/result
import kangaroo/internal/fs
import kangaroo/internal/process
import kangaroo/internal/vm
import kangaroo/internal/watcher.{type Change}
import kangaroo/sys

const compile_timeout_ms = 120_000

const process_poll_ms = 10

const cancellation_timeout_ms = 250

const run_timeout_ms = 86_400_000

pub type CompileOutcome {
  Compiled
  CompileFailed(output: String)
  Superseded
}

pub type ObservedCompileOutcome {
  ObservedCompiled
  ObservedCompileFailed(output: String)
  ObservedCompileSuperseded(
    changes: List(Change),
    snapshot: Dict(String, String),
  )
}

pub type ControlledCompileOutcome(state) {
  ControlledCompiled(state: state)
  ControlledCompileFailed(output: String, state: state)
  ControlledCompileSuperseded(state: state)
  ControlledCompileCancelled(state: state)
}

pub type RunOutcome {
  ChildCompleted(result: process.ProcessResult)
  ChildSuperseded
}

pub type ObservedRunOutcome {
  ObservedChildCompleted(result: process.ProcessResult)
  ObservedChildSuperseded(changes: List(Change), snapshot: Dict(String, String))
}

pub type ActiveControl(state) {
  ActiveContinue(state)
  ActiveCancel(state)
}

pub type ActiveOutcome(state) {
  ActiveCompleted(result: process.ProcessResult, state: state)
  ActiveCancelled(state: state)
}

pub type ControlledRunOutcome(state) {
  ControlledChildCompleted(result: process.ProcessResult, state: state)
  ControlledChildSuperseded(state: state)
  ControlledChildCancelled(state: state)
}

/// State returned by a dynamic watch callback. Roots and baseline move
/// together so configuration changes never compare snapshots captured from
/// different watch sets.
pub type WatchContinuation(state) {
  WatchContinuation(
    state: state,
    roots: List(String),
    baseline: Dict(String, String),
  )
}

pub type IdleControl(state) {
  IdleContinue(state)
  IdleRefresh(state)
  IdleStop(state)
}

/// Compiles without executing the test entry point. This keeps the watch
/// coordinator alive across compile errors and lets it run only the newest
/// settled source snapshot.
pub fn compile(project_dir: String) -> Result(Nil, String) {
  use completed <- result.try(process.run(
    project_dir,
    "gleam",
    watcher.compile_arguments(vm.target()),
    [],
    compile_timeout_ms,
  ))
  case completed.exit_code {
    0 -> Ok(Nil)
    _ -> Error(completed.output)
  }
}

/// Compiles one immutable snapshot and cancels its entire child process tree
/// as soon as a newer snapshot appears. A superseded generation never reaches
/// the execution/reporting layer.
pub fn compile_until_change(
  project_dir: String,
  roots: List(String),
  baseline: Dict(String, String),
) -> Result(CompileOutcome, String) {
  use outcome <- result.try(
    compile_until_change_observed(project_dir, roots, baseline, fn(_) { Nil }),
  )
  Ok(case outcome {
    ObservedCompiled -> Compiled
    ObservedCompileFailed(output) -> CompileFailed(output)
    ObservedCompileSuperseded(..) -> Superseded
  })
}

/// Compile variant that reports the first observed filesystem difference
/// before waiting for the superseded process tree to terminate.
pub fn compile_until_change_observed(
  project_dir: String,
  roots: List(String),
  baseline: Dict(String, String),
  on_detect: fn(List(Change)) -> Nil,
) -> Result(ObservedCompileOutcome, String) {
  use handle <- result.try(process.start(
    project_dir,
    "gleam",
    watcher.compile_arguments(vm.target()),
    [],
    compile_timeout_ms,
  ))
  poll_compile(project_dir, roots, baseline, handle, on_detect)
}

pub fn compile_until_change_controlled(
  project_dir: String,
  roots: List(String),
  baseline: Dict(String, String),
  initial_state: state,
  on_control: fn(state) -> ActiveControl(state),
) -> Result(ControlledCompileOutcome(state), String) {
  use handle <- result.try(process.start(
    project_dir,
    "gleam",
    watcher.compile_arguments(vm.target()),
    [],
    compile_timeout_ms,
  ))
  poll_controlled_compile(
    project_dir,
    roots,
    baseline,
    handle,
    initial_state,
    on_control,
  )
}

fn poll_controlled_compile(
  project_dir,
  roots,
  baseline,
  handle,
  state,
  on_control,
) {
  case watcher.snapshot_project(project_dir, roots) {
    Error(message) -> {
      process.cancel(handle)
      let _ = drain_controlled_cancellation(handle, sys.now_ms())
      Error(message)
    }
    Ok(current) ->
      case watcher.diff(baseline, current) {
        [_, ..] -> {
          process.cancel(handle)
          use _ <- result.try(drain_controlled_cancellation(
            handle,
            sys.now_ms(),
          ))
          Ok(ControlledCompileSuperseded(state))
        }
        [] ->
          case process.poll(handle) {
            process.ProcessRunning | process.ProcessOutput(_) ->
              case on_control(state) {
                ActiveCancel(state) -> {
                  process.cancel(handle)
                  use _ <- result.try(drain_controlled_cancellation(
                    handle,
                    sys.now_ms(),
                  ))
                  Ok(ControlledCompileCancelled(state))
                }
                ActiveContinue(state) -> {
                  fs.sleep(process_poll_ms)
                  poll_controlled_compile(
                    project_dir,
                    roots,
                    baseline,
                    handle,
                    state,
                    on_control,
                  )
                }
              }
            process.ProcessFinished(completed) ->
              case completed.exit_code {
                0 -> Ok(ControlledCompiled(state))
                _ -> Ok(ControlledCompileFailed(completed.output, state))
              }
            process.ProcessCancelled -> Ok(ControlledCompileCancelled(state))
            process.ProcessFailed(message) -> Error(message)
          }
      }
  }
}

fn poll_compile(project_dir, roots, baseline, handle, on_detect) {
  case watcher.snapshot_project(project_dir, roots) {
    Error(message) -> {
      process.cancel(handle)
      drain_cancellation(handle, sys.now_ms())
      Error(message)
    }
    Ok(current) ->
      case watcher.diff(baseline, current) {
        [_, ..] as changes -> {
          on_detect(changes)
          process.cancel(handle)
          drain_cancellation(handle, sys.now_ms())
          Ok(ObservedCompileSuperseded(changes, current))
        }
        [] ->
          case process.poll(handle) {
            process.ProcessRunning -> {
              fs.sleep(process_poll_ms)
              poll_compile(project_dir, roots, baseline, handle, on_detect)
            }
            process.ProcessOutput(_) ->
              poll_compile(project_dir, roots, baseline, handle, on_detect)
            process.ProcessFinished(completed) ->
              case completed.exit_code {
                0 -> Ok(ObservedCompiled)
                _ -> Ok(ObservedCompileFailed(completed.output))
              }
            process.ProcessCancelled ->
              Ok(ObservedCompileSuperseded([], baseline))
            process.ProcessFailed(message) -> Error(message)
          }
      }
  }
}

/// Runs one test generation in a child process so saves can interrupt test
/// bodies, runtime workers, and their descendants as one process tree.
pub fn run_until_change(
  project_dir: String,
  roots: List(String),
  baseline: Dict(String, String),
  arguments: List(String),
) -> Result(RunOutcome, String) {
  use outcome <- result.try(
    run_until_change_observed(project_dir, roots, baseline, arguments, fn(_) {
      Nil
    }),
  )
  Ok(case outcome {
    ObservedChildCompleted(result) -> ChildCompleted(result)
    ObservedChildSuperseded(..) -> ChildSuperseded
  })
}

/// Run variant that publishes save detection before cancellation latency.
pub fn run_until_change_observed(
  project_dir: String,
  roots: List(String),
  baseline: Dict(String, String),
  arguments: List(String),
  on_detect: fn(List(Change)) -> Nil,
) -> Result(ObservedRunOutcome, String) {
  use handle <- result.try(process.start(
    project_dir,
    "gleam",
    watcher.run_arguments_for(vm.target(), vm.runtime_name(), arguments),
    [],
    run_timeout_ms,
  ))
  poll_run(project_dir, roots, baseline, handle, on_detect)
}

/// Interactive variant of `run_until_change`. Output is delivered as it is
/// produced and caller control is polled while still preserving the rule that
/// a changed snapshot supersedes the active generation before stale output is
/// published.
pub fn run_until_change_controlled(
  project_dir: String,
  roots: List(String),
  baseline: Dict(String, String),
  arguments: List(String),
  initial_state: state,
  on_output: fn(state, String) -> state,
  on_control: fn(state) -> ActiveControl(state),
) -> Result(ControlledRunOutcome(state), String) {
  use handle <- result.try(process.start(
    project_dir,
    "gleam",
    watcher.run_arguments_for(vm.target(), vm.runtime_name(), arguments),
    [],
    run_timeout_ms,
  ))
  poll_controlled_run(
    project_dir,
    roots,
    baseline,
    handle,
    initial_state,
    on_output,
    on_control,
  )
}

fn poll_controlled_run(
  project_dir,
  roots,
  baseline,
  handle,
  state,
  on_output,
  on_control,
) {
  case watcher.snapshot_project(project_dir, roots) {
    Error(message) -> {
      process.cancel(handle)
      let _ = drain_controlled_cancellation(handle, sys.now_ms())
      Error(message)
    }
    Ok(current) ->
      case watcher.diff(baseline, current) {
        [_, ..] -> {
          process.cancel(handle)
          use _ <- result.try(drain_controlled_cancellation(
            handle,
            sys.now_ms(),
          ))
          Ok(ControlledChildSuperseded(state))
        }
        [] ->
          case process.poll(handle) {
            process.ProcessOutput(chunk) ->
              controlled_run_decide(
                project_dir,
                roots,
                baseline,
                handle,
                on_output(state, chunk),
                on_output,
                on_control,
              )
            process.ProcessRunning ->
              controlled_run_decide(
                project_dir,
                roots,
                baseline,
                handle,
                state,
                on_output,
                on_control,
              )
            process.ProcessFinished(completed) ->
              Ok(ControlledChildCompleted(completed, state))
            process.ProcessCancelled -> Ok(ControlledChildCancelled(state))
            process.ProcessFailed(message) -> Error(message)
          }
      }
  }
}

fn controlled_run_decide(
  project_dir,
  roots,
  baseline,
  handle,
  state,
  on_output,
  on_control,
) {
  case on_control(state) {
    ActiveCancel(state) -> {
      process.cancel(handle)
      use _ <- result.try(drain_controlled_cancellation(handle, sys.now_ms()))
      Ok(ControlledChildCancelled(state))
    }
    ActiveContinue(state) -> {
      fs.sleep(process_poll_ms)
      poll_controlled_run(
        project_dir,
        roots,
        baseline,
        handle,
        state,
        on_output,
        on_control,
      )
    }
  }
}

/// Folds streamed output into caller-owned state while a process is active.
/// The control callback runs at least every poll interval, allowing an
/// interactive caller to cancel without waiting for the child to finish.
pub fn control_process(
  handle: Int,
  initial_state: state,
  on_output: fn(state, String) -> state,
  on_control: fn(state) -> ActiveControl(state),
) -> Result(ActiveOutcome(state), String) {
  control_process_loop(handle, initial_state, on_output, on_control)
}

fn control_process_loop(handle, state, on_output, on_control) {
  case process.poll(handle) {
    process.ProcessOutput(chunk) ->
      control_process_decide(
        handle,
        on_output(state, chunk),
        on_output,
        on_control,
      )
    process.ProcessRunning ->
      control_process_decide(handle, state, on_output, on_control)
    process.ProcessFinished(completed) -> Ok(ActiveCompleted(completed, state))
    process.ProcessCancelled -> Ok(ActiveCancelled(state))
    process.ProcessFailed(message) -> Error(message)
  }
}

fn control_process_decide(handle, state, on_output, on_control) {
  case on_control(state) {
    ActiveContinue(state) -> {
      fs.sleep(process_poll_ms)
      control_process_loop(handle, state, on_output, on_control)
    }
    ActiveCancel(state) -> {
      process.cancel(handle)
      use _ <- result.try(drain_controlled_cancellation(handle, sys.now_ms()))
      Ok(ActiveCancelled(state))
    }
  }
}

fn drain_controlled_cancellation(
  handle: Int,
  started: Int,
) -> Result(Nil, String) {
  case process.poll(handle) {
    process.ProcessRunning | process.ProcessOutput(_) ->
      case sys.now_ms() - started < cancellation_timeout_ms {
        True -> {
          fs.sleep(5)
          drain_controlled_cancellation(handle, started)
        }
        False -> Error("process cancellation exceeded 250 ms")
      }
    process.ProcessCancelled | process.ProcessFinished(_) -> Ok(Nil)
    process.ProcessFailed(message) -> Error(message)
  }
}

fn poll_run(project_dir, roots, baseline, handle, on_detect) {
  case watcher.snapshot_project(project_dir, roots) {
    Error(message) -> {
      process.cancel(handle)
      drain_cancellation(handle, sys.now_ms())
      Error(message)
    }
    Ok(current) ->
      case watcher.diff(baseline, current) {
        [_, ..] as changes -> {
          on_detect(changes)
          process.cancel(handle)
          drain_cancellation(handle, sys.now_ms())
          Ok(ObservedChildSuperseded(changes, current))
        }
        [] ->
          case process.poll(handle) {
            process.ProcessRunning -> {
              fs.sleep(process_poll_ms)
              poll_run(project_dir, roots, baseline, handle, on_detect)
            }
            process.ProcessOutput(_) ->
              poll_run(project_dir, roots, baseline, handle, on_detect)
            process.ProcessFinished(completed) ->
              Ok(ObservedChildCompleted(completed))
            process.ProcessCancelled ->
              Ok(ObservedChildSuperseded([], baseline))
            process.ProcessFailed(message) -> Error(message)
          }
      }
  }
}

fn drain_cancellation(handle: Int, started: Int) -> Nil {
  case process.poll(handle) {
    process.ProcessRunning ->
      case sys.now_ms() - started < cancellation_timeout_ms {
        True -> {
          fs.sleep(5)
          drain_cancellation(handle, started)
        }
        False -> Nil
      }
    process.ProcessOutput(_) -> drain_cancellation(handle, started)
    _ -> Nil
  }
}

/// Watches content snapshots forever. A burst of atomic renames/writes is
/// settled into one callback and changes that preserve mtime/size remain
/// visible because snapshot equality is content based.
pub fn forever(
  project_dir: String,
  roots: List(String),
  debounce_ms: Int,
  on_change: fn(List(Change)) -> Nil,
) -> Result(Nil, String) {
  forever_with_state(project_dir, roots, debounce_ms, Nil, fn(_, changes) {
    on_change(changes)
    Nil
  })
}

/// Stateful watch loop used by the incremental AST index. The callback's
/// returned state becomes the next generation without global mutable state.
pub fn forever_with_state(
  project_dir: String,
  roots: List(String),
  debounce_ms: Int,
  initial_state: state,
  on_change: fn(state, List(Change)) -> state,
) -> Result(Nil, String) {
  forever_with_snapshot(
    project_dir,
    roots,
    debounce_ms,
    initial_state,
    fn(state, changes, _snapshot) { on_change(state, changes) },
  )
}

/// Snapshot-aware watch loop used when the callback must prove that the work
/// it starts still belongs to the latest settled source generation.
pub fn forever_with_snapshot(
  project_dir: String,
  roots: List(String),
  debounce_ms: Int,
  initial_state: state,
  on_change: fn(state, List(Change), Dict(String, String)) -> state,
) -> Result(Nil, String) {
  use initial <- result.try(watcher.snapshot_project(project_dir, roots))
  forever_from_snapshot(
    project_dir,
    roots,
    debounce_ms,
    initial,
    initial_state,
    on_change,
  )
}

/// Starts a snapshot-aware watch loop from a baseline captured before an
/// initial cancellable generation. If that generation is superseded, the
/// save remains visible to the first loop iteration instead of being lost
/// between process cancellation and watcher startup.
pub fn forever_from_snapshot(
  project_dir: String,
  roots: List(String),
  debounce_ms: Int,
  initial: Dict(String, String),
  initial_state: state,
  on_change: fn(state, List(Change), Dict(String, String)) -> state,
) -> Result(Nil, String) {
  forever_dynamic_from_snapshot(
    project_dir,
    roots,
    debounce_ms,
    initial,
    initial_state,
    fn(state, changes, snapshot, roots) {
      WatchContinuation(on_change(state, changes, snapshot), roots, snapshot)
    },
  )
}

/// Dynamic variant used when `gleam.toml` changes test or extra watch roots.
/// The callback supplies the exact watch set and matching snapshot for the
/// next generation.
pub fn forever_dynamic_from_snapshot(
  project_dir: String,
  roots: List(String),
  debounce_ms: Int,
  initial: Dict(String, String),
  initial_state: state,
  on_change: fn(state, List(Change), Dict(String, String), List(String)) ->
    WatchContinuation(state),
) -> Result(Nil, String) {
  forever_dynamic_observed_from_snapshot(
    project_dir,
    roots,
    debounce_ms,
    initial,
    initial_state,
    fn(state, _) { state },
    on_change,
  )
}

/// Dynamic watch loop with an immediate detection signal. Work still starts
/// only after the configured debounce has settled, while callers can report
/// save detection independently from compile time.
pub fn forever_dynamic_observed_from_snapshot(
  project_dir: String,
  roots: List(String),
  debounce_ms: Int,
  initial: Dict(String, String),
  initial_state: state,
  on_detect: fn(state, List(Change)) -> state,
  on_change: fn(state, List(Change), Dict(String, String), List(String)) ->
    WatchContinuation(state),
) -> Result(Nil, String) {
  dynamic_loop(
    project_dir,
    roots,
    scan_interval(debounce_ms),
    positive_delay(debounce_ms),
    initial,
    initial_state,
    on_detect,
    on_change,
  )
}

/// Dynamic watch loop with an idle hook for terminal input. `IdleRefresh`
/// invokes the normal generation callback with no filesystem changes, which
/// is how the TUI requests an explicit full run, coverage, or review action.
pub fn forever_interactive_from_snapshot(
  project_dir: String,
  roots: List(String),
  debounce_ms: Int,
  initial: Dict(String, String),
  initial_state: state,
  on_idle: fn(state) -> IdleControl(state),
  on_change: fn(state, List(Change), Dict(String, String), List(String)) ->
    WatchContinuation(state),
) -> Result(Nil, String) {
  interactive_loop(
    project_dir,
    roots,
    scan_interval(debounce_ms),
    positive_delay(debounce_ms),
    initial,
    initial_state,
    on_idle,
    on_change,
  )
}

fn dynamic_loop(
  project_dir,
  roots,
  scan_delay,
  settle_delay,
  previous,
  state,
  on_detect,
  on_change,
) {
  fs.sleep(scan_delay)
  case watcher.snapshot_project(project_dir, roots) {
    Error(message) -> {
      fs.write_stderr_line("kangaroo: watch scan failed: " <> message)
      dynamic_loop(
        project_dir,
        roots,
        scan_delay,
        settle_delay,
        previous,
        state,
        on_detect,
        on_change,
      )
    }
    Ok(current) ->
      case watcher.diff(previous, current) {
        [] ->
          dynamic_loop(
            project_dir,
            roots,
            scan_delay,
            settle_delay,
            previous,
            state,
            on_detect,
            on_change,
          )
        detected -> {
          let state = on_detect(state, detected)
          let settled = settle(project_dir, roots, settle_delay, current)
          let changes = watcher.diff(previous, settled)
          let continuation = case changes {
            [] -> WatchContinuation(state, roots, settled)
            _ -> on_change(state, changes, settled, roots)
          }
          dynamic_loop(
            project_dir,
            continuation.roots,
            scan_delay,
            settle_delay,
            continuation.baseline,
            continuation.state,
            on_detect,
            on_change,
          )
        }
      }
  }
}

fn interactive_loop(
  project_dir: String,
  roots: List(String),
  scan_delay: Int,
  settle_delay: Int,
  previous: Dict(String, String),
  state: state,
  on_idle: fn(state) -> IdleControl(state),
  on_change: fn(state, List(Change), Dict(String, String), List(String)) ->
    WatchContinuation(state),
) -> Result(Nil, String) {
  fs.sleep(scan_delay)
  case watcher.snapshot_project(project_dir, roots) {
    Error(message) -> {
      fs.write_stderr_line("kangaroo: watch scan failed: " <> message)
      interactive_loop(
        project_dir,
        roots,
        scan_delay,
        settle_delay,
        previous,
        state,
        on_idle,
        on_change,
      )
    }
    Ok(current) ->
      case watcher.diff(previous, current) {
        [] ->
          case on_idle(state) {
            IdleContinue(state) ->
              interactive_loop(
                project_dir,
                roots,
                scan_delay,
                settle_delay,
                previous,
                state,
                on_idle,
                on_change,
              )
            IdleRefresh(state) -> {
              let continuation = on_change(state, [], current, roots)
              interactive_loop(
                project_dir,
                continuation.roots,
                scan_delay,
                settle_delay,
                continuation.baseline,
                continuation.state,
                on_idle,
                on_change,
              )
            }
            IdleStop(_) -> Ok(Nil)
          }
        _ -> {
          let settled = settle(project_dir, roots, settle_delay, current)
          let changes = watcher.diff(previous, settled)
          let continuation = case changes {
            [] -> WatchContinuation(state, roots, settled)
            _ -> on_change(state, changes, settled, roots)
          }
          interactive_loop(
            project_dir,
            continuation.roots,
            scan_delay,
            settle_delay,
            continuation.baseline,
            continuation.state,
            on_idle,
            on_change,
          )
        }
      }
  }
}

fn settle(project_dir, roots, delay, previous) {
  fs.sleep(delay)
  case watcher.snapshot_project(project_dir, roots) {
    Error(_) -> previous
    Ok(current) ->
      case watcher.diff(previous, current) {
        [] -> current
        _ -> settle(project_dir, roots, delay, current)
      }
  }
}

fn positive_delay(milliseconds: Int) -> Int {
  case milliseconds > 0 {
    True -> milliseconds
    False -> 1
  }
}

/// Idle scans are deliberately less frequent than the settle debounce. Save
/// detection is reported on the first scan, while compilation waits for the
/// debounce window to become stable.
pub fn scan_interval(debounce_ms: Int) -> Int {
  case debounce_ms > 0 {
    True -> debounce_ms * 5 / 2
    False -> 1
  }
}
