import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import kangaroo/event.{type Event, CaseFinished, RunFinished, RunStarted}
import kangaroo/failure.{Skipped as SkippedOutcome}
import kangaroo/internal/event_buffer
import kangaroo/internal/index.{type IndexedTest}
import kangaroo/internal/legacy/suite.{
  type Case, Case, Normal, Skipped, Suite, no_hooks,
}
import kangaroo/internal/runtime
import kangaroo/internal/scheduler.{type Wave}
import kangaroo/internal/vm
import kangaroo/report.{type Report, CaseResult, Report}
import kangaroo/runner
import kangaroo/sys

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
  use resolved <- result.try(list.try_map(tests, resolve))
  let suites = to_suites(resolved)
  Ok(runner.run_with_retries(
    suites,
    sink,
    runner.Config(Some(default_timeout_ms), fail_fast),
    retry,
  ))
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
  let effective_workers = case fail_fast {
    True -> 1
    False -> workers
  }
  let waves =
    scheduler.plan_seeded(tests, effective_workers, serial_tags, shuffle_seed)
  let run_id = sys.now_ms()
  let started = sys.now_ms()
  sink(RunStarted(run_id, list.length(tests)))
  use final_report <- result.try(run_waves(
    waves,
    default_timeout_ms,
    fail_fast,
    retry,
    sink,
    Report([], []),
  ))
  sink(RunFinished(run_id, report.summary(final_report, sys.now_ms() - started)))
  Ok(final_report)
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
      let tasks =
        list.map(batches, fn(batch) {
          fn() { run_batch(batch.tests, default_timeout_ms, fail_fast, retry) }
        })
      use completed <- result.try(
        vm.run_all(tasks)
        |> list.try_map(fn(item) { item }),
      )
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
    runner.run_with_retries(
      to_suites(resolved),
      event_buffer.append_batch,
      runner.Config(Some(default_timeout_ms), fail_fast),
      retry,
    )
  Ok(BatchExecution(report, event_buffer.take_batch()))
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
  Report(
    list.append(first.cases, second.cases),
    list.append(first.suite_failures, second.suite_failures),
  )
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
  let skipped =
    list.map(tests, fn(indexed) {
      sink(CaseFinished(indexed.module, indexed.id, SkippedOutcome, 0))
      CaseResult(indexed.module, indexed.id, SkippedOutcome, 0)
    })
  Report(list.append(accumulated.cases, skipped), accumulated.suite_failures)
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

fn to_suites(tests: List(ResolvedTest)) -> List(suite.Suite) {
  tests
  |> list.fold([], fn(groups, indexed_test) {
    append_test(groups, indexed_test)
  })
  |> list.map(fn(group) { Suite(group.0, group.1, no_hooks()) })
}

fn append_test(
  groups: List(#(String, List(Case))),
  indexed_test: ResolvedTest,
) -> List(#(String, List(Case))) {
  let mode = case indexed_test.index.skip {
    Some(_) -> Skipped
    None -> Normal
  }
  let case_ =
    Case(
      name: indexed_test.index.id,
      body: indexed_test.body,
      mode:,
      timeout_ms: indexed_test.index.timeout_ms,
      skip_reason: indexed_test.index.skip,
    )
  append_case(groups, indexed_test.index.module, case_)
}

fn append_case(
  groups: List(#(String, List(Case))),
  module_name: String,
  case_: Case,
) -> List(#(String, List(Case))) {
  case groups {
    [] -> [#(module_name, [case_])]
    [group, ..rest] if group.0 == module_name -> [
      #(group.0, list.append(group.1, [case_])),
      ..rest
    ]
    [group, ..rest] -> [group, ..append_case(rest, module_name, case_)]
  }
}
