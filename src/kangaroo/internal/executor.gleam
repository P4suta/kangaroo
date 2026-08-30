import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import kangaroo/encode
import kangaroo/event.{
  type Event, CaseFinished, CaseOutput, CaseStarted, RunFinished, RunStarted,
  SuiteFinished, SuiteStarted,
}
import kangaroo/failure.{
  type Failure, type Outcome, AssertionFailed, EqualityMismatch, Failed, Flaky,
  Passed, Skipped, SkippedWithReason, UnexpectedError,
}
import kangaroo/internal/event_buffer
import kangaroo/internal/index.{type IndexedTest}
import kangaroo/internal/runtime
import kangaroo/internal/scheduler.{type Batch, type Wave}
import kangaroo/internal/vm
import kangaroo/isolate.{
  type Isolated, CapturedIsolation, Completed, Crashed, SkippedIsolation,
  isolate_captured,
}
import kangaroo/report.{type CaseResult, type Report, CaseResult, Report}
import kangaroo/sys

const max_captured_output_bytes = 16_777_216

type ResolvedTest {
  ResolvedTest(index: IndexedTest, body: fn() -> Nil)
}

/// Resolves and executes a deterministic set of indexed tests.
///
/// Tests stay serial within a source module. The module grouping boundary is
/// explicit here so the scheduler can run those groups concurrently without
/// ever reordering functions inside a module.
pub fn run(
  tests: List(IndexedTest),
  sink: fn(Event) -> Nil,
  default_timeout_ms: Int,
  fail_fast: Bool,
) -> Result(Report, String) {
  run_with_options(tests, sink, default_timeout_ms, fail_fast, 0)
}

pub fn run_with_options(
  tests: List(IndexedTest),
  sink: fn(Event) -> Nil,
  default_timeout_ms: Int,
  fail_fast: Bool,
  retry: Int,
) -> Result(Report, String) {
  use _ <- result.try(
    runtime.prepare_modules(list.map(tests, fn(indexed) { indexed.module })),
  )
  use resolved <- result.try(list.try_map(tests, resolve))
  Ok(execute(resolved, sink, default_timeout_ms, fail_fast, retry))
}

/// Runs modules according to deterministic scheduler waves. Each module is a
/// single batch, preserving its source order. BEAM evaluates batches in a
/// wave in separate processes; presentations receive one outer event stream.
pub fn run_scheduled(
  tests: List(IndexedTest),
  sink: fn(Event) -> Nil,
  default_timeout_ms: Int,
  fail_fast: Bool,
  retry: Int,
  workers: Int,
  serial_tags: List(String),
) -> Result(Report, String) {
  run_scheduled_seeded(
    tests,
    sink,
    default_timeout_ms,
    fail_fast,
    retry,
    workers,
    serial_tags,
    None,
  )
}

pub fn run_scheduled_seeded(
  tests: List(IndexedTest),
  sink: fn(Event) -> Nil,
  default_timeout_ms: Int,
  fail_fast: Bool,
  retry: Int,
  workers: Int,
  serial_tags: List(String),
  shuffle_seed: Option(Int),
) -> Result(Report, String) {
  use _ <- result.try(
    runtime.prepare_modules(list.map(tests, fn(indexed) { indexed.module })),
  )
  let effective_workers = case fail_fast {
    True -> 1
    False -> workers
  }
  let waves =
    scheduler.plan_seeded(tests, effective_workers, serial_tags, shuffle_seed)
  let run_id = sys.now_ms()
  let started = sys.now_ms()
  sink(RunStarted(run_id, list.length(tests)))
  case
    run_waves(waves, default_timeout_ms, fail_fast, retry, sink, Report([]))
  {
    Ok(final_report) -> {
      sink(RunFinished(
        run_id,
        report.summary(final_report, sys.now_ms() - started),
      ))
      Ok(final_report)
    }
    Error(message) -> {
      sink(RunFinished(
        run_id,
        report.summary(Report([]), sys.now_ms() - started),
      ))
      Error(message)
    }
  }
}

fn run_waves(
  waves: List(Wave),
  default_timeout_ms: Int,
  fail_fast: Bool,
  retry: Int,
  sink: fn(Event) -> Nil,
  accumulated: Report,
) -> Result(Report, String) {
  case waves {
    [] -> Ok(accumulated)
    [scheduler.Wave(batches), ..rest] -> {
      use completed <- result.try(run_wave_batches(
        batches,
        default_timeout_ms,
        fail_fast,
        retry,
      ))
      completed
      |> list.flat_map(fn(batch) { without_run_brackets(batch.events) })
      |> list.each(sink)
      let accumulated =
        list.fold(completed, accumulated, fn(report, batch) {
          merge_reports(report, batch.report)
        })
      case fail_fast && report.has_failures(accumulated) {
        True -> Ok(skip_remaining(rest, sink, accumulated))
        False ->
          run_waves(
            rest,
            default_timeout_ms,
            fail_fast,
            retry,
            sink,
            accumulated,
          )
      }
    }
  }
}

fn run_wave_batches(
  batches: List(Batch),
  default_timeout_ms: Int,
  fail_fast: Bool,
  retry: Int,
) -> Result(List(BatchExecution), String) {
  case vm.target(), batches {
    "javascript", [_, _, ..] ->
      vm.run_batches(batches, default_timeout_ms, fail_fast, retry)
      |> list.try_map(decode_batch_wire)
    _, _ -> {
      let tasks =
        list.map(batches, fn(batch) {
          fn() { run_batch(batch.tests, default_timeout_ms, fail_fast, retry) }
        })
      vm.run_all(tasks)
      |> list.try_map(fn(item) { item })
    }
  }
}

type BatchExecution {
  BatchExecution(report: Report, events: List(Event))
}

fn run_batch(
  tests: List(IndexedTest),
  default_timeout_ms: Int,
  fail_fast: Bool,
  retry: Int,
) -> Result(BatchExecution, String) {
  event_buffer.take_batch()
  use resolved <- result.try(list.try_map(tests, resolve))
  let report =
    execute(
      resolved,
      event_buffer.append_batch,
      default_timeout_ms,
      fail_fast,
      retry,
    )
  Ok(BatchExecution(report, event_buffer.take_batch()))
}

/// Executes one JavaScript module batch in an outer runtime Worker and returns
/// an internal, line-safe event envelope. The parent decodes every event with
/// the same strict codec used by watch and daemon boundaries.
pub fn run_batch_wire(
  tests: List(IndexedTest),
  default_timeout_ms: Int,
  fail_fast: Bool,
  retry: Int,
) -> String {
  case run_batch(tests, default_timeout_ms, fail_fast, retry) {
    Error(message) -> "error\n" <> message
    Ok(BatchExecution(_, events)) ->
      "ok\n" <> string.join(list.map(events, encode.encode), "\n")
  }
}

fn decode_batch_wire(source: String) -> Result(BatchExecution, String) {
  case string.split_once(source, on: "\n") {
    Ok(#("error", message)) -> Error(message)
    Ok(#("ok", payload)) -> {
      use events <- result.try(
        payload
        |> string.split("\n")
        |> list.filter(fn(line) { line != "" })
        |> list.try_map(encode.decode),
      )
      let cases =
        list.filter_map(events, fn(event) {
          case event {
            CaseFinished(suite, case_name, outcome, duration_ms) ->
              Ok(CaseResult(suite, case_name, outcome, duration_ms))
            _ -> Error(Nil)
          }
        })
      Ok(BatchExecution(Report(cases), events))
    }
    _ -> Error("parallel JavaScript batch returned an invalid result")
  }
}

fn without_run_brackets(events: List(Event)) -> List(Event) {
  list.filter(events, fn(event) {
    case event {
      RunStarted(..) | RunFinished(..) -> False
      _ -> True
    }
  })
}

fn merge_reports(first: Report, second: Report) -> Report {
  Report(list.append(first.cases, second.cases))
}

fn skip_remaining(
  waves: List(Wave),
  sink: fn(Event) -> Nil,
  accumulated: Report,
) -> Report {
  let tests =
    waves
    |> list.flat_map(fn(wave) {
      wave.batches |> list.flat_map(fn(batch) { batch.tests })
    })
  let skipped = list.map(tests, fn(indexed) { skip_indexed(indexed, sink) })
  Report(list.append(accumulated.cases, skipped))
}

fn resolve(indexed: IndexedTest) -> Result(ResolvedTest, String) {
  case indexed.skip {
    Some(_) -> Ok(ResolvedTest(indexed, fn() { Nil }))
    None -> {
      use loaded <- result.try(runtime.resolve(indexed))
      Ok(ResolvedTest(indexed, loaded.body))
    }
  }
}

fn execute(
  tests: List(ResolvedTest),
  sink: fn(Event) -> Nil,
  default_timeout_ms: Int,
  fail_fast: Bool,
  retries: Int,
) -> Report {
  let run_id = sys.now_ms()
  let started = sys.now_ms()
  sink(RunStarted(run_id, list.length(tests)))
  let state =
    list.fold(group_by_module(tests), Execution([], False), fn(state, group) {
      case state.stopped {
        True ->
          Execution(
            list.append(
              state.results,
              list.map(group.1, fn(resolved) { skip_resolved(resolved, sink) }),
            ),
            True,
          )
        False ->
          run_module(
            group.0,
            group.1,
            sink,
            default_timeout_ms,
            fail_fast,
            retries,
            state.results,
          )
      }
    })
  let report = Report(state.results)
  sink(RunFinished(run_id, report.summary(report, sys.now_ms() - started)))
  report
}

type Execution {
  Execution(results: List(CaseResult), stopped: Bool)
}

fn run_module(
  module_name: String,
  tests: List(ResolvedTest),
  sink: fn(Event) -> Nil,
  default_timeout_ms: Int,
  fail_fast: Bool,
  retries: Int,
  previous: List(CaseResult),
) -> Execution {
  sink(SuiteStarted(module_name))
  let module_state =
    list.fold(tests, Execution([], False), fn(state, resolved) {
      case state.stopped {
        True ->
          Execution(
            list.append(state.results, [skip_resolved(resolved, sink)]),
            True,
          )
        False -> {
          let result = run_resolved(resolved, sink, default_timeout_ms, retries)
          Execution(
            list.append(state.results, [result]),
            fail_fast && outcome_failed(result.outcome),
          )
        }
      }
    })
  sink(SuiteFinished(module_name, suite_outcome(module_state.results)))
  Execution(list.append(previous, module_state.results), module_state.stopped)
}

fn suite_outcome(results: List(CaseResult)) -> Outcome {
  let outcomes = list.map(results, fn(result) { result.outcome })
  let failures =
    outcomes
    |> list.flat_map(fn(outcome) {
      case outcome {
        Failed(failures) | Flaky(failures, _) -> failures
        _ -> []
      }
    })
  case
    list.any(outcomes, fn(outcome) {
      case outcome {
        Failed(_) -> True
        _ -> False
      }
    })
  {
    True -> Failed(failures)
    False ->
      case
        list.filter_map(outcomes, fn(outcome) {
          case outcome {
            Flaky(_, attempts) -> Ok(attempts)
            _ -> Error(Nil)
          }
        })
      {
        [attempts, ..rest] ->
          Flaky(
            failures,
            list.fold(rest, attempts, fn(highest, value) {
              case value > highest {
                True -> value
                False -> highest
              }
            }),
          )
        [] ->
          case outcomes {
            [] -> Passed
            _ ->
              case
                list.all(outcomes, fn(outcome) {
                  case outcome {
                    Skipped | SkippedWithReason(_) -> True
                    _ -> False
                  }
                })
              {
                True -> Skipped
                False -> Passed
              }
          }
      }
  }
}

fn run_resolved(
  resolved: ResolvedTest,
  sink: fn(Event) -> Nil,
  default_timeout_ms: Int,
  retries: Int,
) -> CaseResult {
  case resolved.index.skip {
    Some(_) -> skip_resolved(resolved, sink)
    None -> {
      sink(CaseStarted(resolved.index.module, resolved.index.id))
      let started = sys.now_ms()
      let timeout = case resolved.index.timeout_ms {
        Some(milliseconds) -> Some(milliseconds)
        None -> Some(default_timeout_ms)
      }
      let AttemptResult(outcome, stdout, stderr) =
        retry(resolved.body, timeout, retries, 1, [], "", "")
      let duration = sys.now_ms() - started
      sink(CaseFinished(
        resolved.index.module,
        resolved.index.id,
        outcome,
        duration,
      ))
      case stdout == "" && stderr == "" {
        True -> Nil
        False ->
          sink(CaseOutput(
            resolved.index.module,
            resolved.index.id,
            stdout,
            stderr,
            outcome,
          ))
      }
      CaseResult(resolved.index.module, resolved.index.id, outcome, duration)
    }
  }
}

type AttemptResult {
  AttemptResult(outcome: Outcome, stdout: String, stderr: String)
}

fn retry(
  body: fn() -> Nil,
  timeout: Option(Int),
  retries_left: Int,
  attempt: Int,
  previous_failures: List(Failure),
  previous_stdout: String,
  previous_stderr: String,
) -> AttemptResult {
  let CapturedIsolation(isolated, stdout, stderr) =
    isolate_captured(body, timeout)
  let outcome = outcome_of(isolated)
  case
    append_captured_output(
      previous_stdout,
      previous_stderr,
      stdout,
      stderr,
      max_captured_output_bytes,
    )
  {
    Error(message) ->
      AttemptResult(
        Failed([UnexpectedError("infrastructure", message, None)]),
        "",
        "",
      )
    Ok(#(stdout, stderr)) ->
      case infrastructure_outcome(outcome) {
        True -> AttemptResult(outcome, stdout, stderr)
        False ->
          case outcome, retries_left, previous_failures {
            Failed(failures), retries, _ if retries > 0 ->
              retry(
                body,
                timeout,
                retries - 1,
                attempt + 1,
                list.append(previous_failures, failures),
                stdout,
                stderr,
              )
            Passed, _, [] -> AttemptResult(Passed, stdout, stderr)
            Passed, _, failures ->
              AttemptResult(Flaky(failures, attempt), stdout, stderr)
            Skipped, _, [] -> AttemptResult(Skipped, stdout, stderr)
            SkippedWithReason(reason), _, [] ->
              AttemptResult(SkippedWithReason(reason), stdout, stderr)
            Skipped, _, failures | SkippedWithReason(_), _, failures ->
              AttemptResult(Failed(failures), stdout, stderr)
            Failed(failures), _, previous ->
              AttemptResult(
                Failed(list.append(previous, failures)),
                stdout,
                stderr,
              )
            Flaky(failures, attempts), _, previous ->
              AttemptResult(
                Flaky(list.append(previous, failures), attempts),
                stdout,
                stderr,
              )
          }
      }
  }
}

/// Applies the per-test output budget across both streams and every retry.
/// The size check happens before concatenation so an over-budget attempt does
/// not transiently allocate the unbounded combined string.
pub fn append_captured_output(
  previous_stdout: String,
  previous_stderr: String,
  stdout: String,
  stderr: String,
  limit: Int,
) -> Result(#(String, String), String) {
  let bytes =
    string.byte_size(previous_stdout)
    + string.byte_size(previous_stderr)
    + string.byte_size(stdout)
    + string.byte_size(stderr)
  case bytes > limit {
    True -> Error("test output exceeded " <> int.to_string(limit) <> " bytes")
    False -> Ok(#(previous_stdout <> stdout, previous_stderr <> stderr))
  }
}

fn infrastructure_outcome(outcome: Outcome) -> Bool {
  let failures = case outcome {
    Failed(failures) | Flaky(failures, _) -> failures
    _ -> []
  }
  list.any(failures, fn(failure) {
    case failure {
      UnexpectedError("infrastructure", _, _) -> True
      _ -> False
    }
  })
}

fn outcome_of(isolated: Isolated) -> Outcome {
  case isolated {
    Completed -> Passed
    Crashed(error) ->
      case error.expected, error.actual {
        Some(expected), Some(actual) ->
          Failed([
            EqualityMismatch(expected, actual, error.diff, error.location),
          ])
        _, _ if error.name == "assert" || error.name == "let_assert" ->
          Failed([AssertionFailed(error.message, error.location)])
        _, _ ->
          Failed([UnexpectedError(error.name, error.message, error.location)])
      }
    SkippedIsolation(reason) -> SkippedWithReason(reason)
  }
}

fn outcome_failed(outcome: Outcome) -> Bool {
  case outcome {
    Failed(_) | Flaky(_, _) -> True
    _ -> False
  }
}

fn skip_resolved(resolved: ResolvedTest, sink: fn(Event) -> Nil) -> CaseResult {
  skip_indexed(resolved.index, sink)
}

fn skip_indexed(indexed: IndexedTest, sink: fn(Event) -> Nil) -> CaseResult {
  let outcome = case indexed.skip {
    Some(reason) -> SkippedWithReason(reason)
    None -> Skipped
  }
  sink(CaseFinished(indexed.module, indexed.id, outcome, 0))
  CaseResult(indexed.module, indexed.id, outcome, 0)
}

fn group_by_module(
  tests: List(ResolvedTest),
) -> List(#(String, List(ResolvedTest))) {
  list.fold(tests, [], fn(groups, resolved) {
    append_to_group(groups, resolved)
  })
}

fn append_to_group(
  groups: List(#(String, List(ResolvedTest))),
  resolved: ResolvedTest,
) -> List(#(String, List(ResolvedTest))) {
  case groups {
    [] -> [#(resolved.index.module, [resolved])]
    [group, ..rest] if group.0 == resolved.index.module -> [
      #(group.0, list.append(group.1, [resolved])),
      ..rest
    ]
    [group, ..rest] -> [group, ..append_to_group(rest, resolved)]
  }
}
