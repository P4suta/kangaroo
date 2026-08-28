import gleam/list
import gleam/option.{None, Some}
import kangaroo/event.{
  type Event, CaseFinished, CaseStarted, RunFinished, RunStarted,
}
import kangaroo/failure.{type Outcome, Failed, Passed, Skipped, UnexpectedError}
import kangaroo/isolate.{Completed, Crashed}
import kangaroo/report.{type Report, CaseResult, Report, summary}
import kangaroo/suite.{type Case, type Suite}
import kangaroo/sys

pub type Selected {
  Selected(to_run: List(#(Suite, Case)), skipped: List(#(Suite, Case)))
}

/// Runs the given suites, emitting events to the sink as the run progresses.
///
/// Execution is sequential and each case body is isolated: panics and
/// matcher failures are captured without taking down the run. Focused cases
/// take priority when present; skipped cases are counted but not executed.
pub fn run(suites: List(Suite), sink: fn(Event) -> Nil) -> Report {
  let run_id = sys.now_ms()
  let selected = select(suites)
  let total = list.length(selected.to_run) + list.length(selected.skipped)

  sink(RunStarted(run_id, total))

  let start = sys.now_ms()

  let run_results =
    list.fold(selected.to_run, [], fn(results, entry) {
      let #(suite, c) = entry
      sink(CaseStarted(suite.name, c.name))
      let case_start = sys.now_ms()
      let isolated = isolate.isolate(body_for(suite, c))
      let duration = sys.now_ms() - case_start
      let outcome = outcome_of(isolated)
      sink(CaseFinished(suite.name, c.name, outcome, duration))
      [CaseResult(suite.name, c.name, outcome, duration), ..results]
    })

  let skipped_results =
    list.map(selected.skipped, fn(entry) {
      let #(suite, c) = entry
      let result = CaseResult(suite.name, c.name, Skipped, 0)
      sink(CaseFinished(suite.name, c.name, Skipped, 0))
      result
    })

  let report = Report(list.reverse(run_results) |> list.append(skipped_results))
  let duration = sys.now_ms() - start
  sink(RunFinished(run_id, summary(report, duration)))
  report
}

fn outcome_of(isolated: isolate.Isolated) -> Outcome {
  case isolated {
    Completed([]) -> Passed
    Completed(failures) -> Failed(failures)
    Crashed(error) -> Failed([UnexpectedError(error.name, error.message)])
  }
}

/// Decides which cases will run: focused cases when any exist, otherwise all
/// non-skipped cases. Skipped cases are reported but never executed.
fn select(suites: List(Suite)) -> Selected {
  let focus = suite_has_focus(suites)

  list.fold(suites, Selected([], []), fn(selected, s) {
    let all = list.map(s.cases, fn(c) { #(s, c) })
    let skipped = list.filter(all, fn(entry) { entry.1.mode == suite.Skipped })
    let runnable = list.filter(all, fn(entry) { entry.1.mode != suite.Skipped })
    let runnable = case focus {
      True -> list.filter(runnable, fn(entry) { entry.1.mode == suite.Focused })
      False -> runnable
    }
    Selected(
      list.append(selected.to_run, runnable),
      list.append(selected.skipped, skipped),
    )
  })
}

fn suite_has_focus(suites: List(Suite)) -> Bool {
  list.any(suites, fn(s) {
    list.any(s.cases, fn(c) { c.mode == suite.Focused })
  })
}

/// Wraps the case body with the suite's before/after hooks, so they run in
/// the same isolated execution as the case itself.
fn body_for(suite: Suite, c: Case) -> fn() -> Nil {
  let with_before = case suite.hooks.before_each {
    None -> c.body
    Some(before) -> fn() {
      before()
      c.body()
    }
  }
  case suite.hooks.after_each {
    None -> with_before
    Some(after) -> fn() {
      with_before()
      after()
    }
  }
}
