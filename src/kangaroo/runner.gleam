import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import kangaroo/event.{
  type Event, CaseFinished, CaseStarted, RunFinished, RunStarted, SuiteFinished,
  SuiteStarted,
}
import kangaroo/failure.{
  type Failure, type Outcome, Failed, Passed, Skipped, UnexpectedError,
}
import kangaroo/isolate.{type Isolated, Completed, Crashed, isolate}
import kangaroo/report.{
  type CaseResult, type Report, CaseResult, Report, summary,
}
import kangaroo/suite.{type Case, type Suite}
import kangaroo/sys

/// The runner configuration.
pub type Config {
  Config(case_timeout_ms: Option(Int), stop_on_first_failure: Bool)
}

/// The default configuration. The per-case timeout comes from the
/// `KANGAROO_CASE_TIMEOUT_MS` environment variable when set (Erlang only);
/// `stop_on_first_failure` is off.
pub fn default_config() -> Config {
  Config(timeout_from_env(), False)
}

fn timeout_from_env() -> Option(Int) {
  case sys.env("KANGAROO_CASE_TIMEOUT_MS") {
    None -> None
    Some(value) ->
      case int.parse(value) {
        Ok(ms) if ms > 0 -> Some(ms)
        _ -> None
      }
  }
}

pub type Selected {
  Selected(to_run: List(#(Suite, Case)), skipped: List(#(Suite, Case)))
}

/// Runs the given suites with the default configuration, emitting events to
/// the sink as the run progresses.
///
/// Execution is sequential and each case body is isolated: panics and
/// matcher failures are captured without taking down the run. Focused cases
/// take priority when present; skipped cases are counted but not executed.
pub fn run(suites: List(Suite), sink: fn(Event) -> Nil) -> Report {
  run_with_config(suites, sink, default_config())
}

/// Runs the given suites with an explicit configuration.
pub fn run_with_config(
  suites: List(Suite),
  sink: fn(Event) -> Nil,
  config: Config,
) -> Report {
  let run_id = sys.now_ms()
  let selected = select(suites)
  let total = list.length(selected.to_run) + list.length(selected.skipped)

  sink(RunStarted(run_id, total))

  let start = sys.now_ms()

  let #(results, suite_failures) =
    list.fold(group(selected.to_run), #([], [], False), fn(state, entry) {
      let #(results, suite_failures, stopped) = state
      let #(suite, cases) = entry
      case stopped {
        True -> {
          // Fail-fast: every remaining case is reported as skipped.
          let skipped = list.map(cases, fn(c) { skip_case(suite, c, sink) })
          #(list.append(results, skipped), suite_failures, True)
        }
        False -> {
          let #(suite_results, suite_outcome, stopped) =
            run_suite(suite, cases, config, sink)
          let suite_failures = case suite_outcome {
            None -> suite_failures
            Some(failures) -> [#(suite.name, failures), ..suite_failures]
          }
          #(list.append(results, suite_results), suite_failures, stopped)
        }
      }
    })
    |> drop_stopped

  let skipped_results =
    list.map(selected.skipped, fn(entry) {
      let #(suite, c) = entry
      skip_case(suite, c, sink)
    })

  let report =
    Report(list.append(results, skipped_results), list.reverse(suite_failures))
  let duration = sys.now_ms() - start
  sink(RunFinished(run_id, summary(report, duration)))
  report
}

fn drop_stopped(
  state: #(List(CaseResult), List(#(String, List(Failure))), Bool),
) -> #(List(CaseResult), List(#(String, List(Failure)))) {
  #(state.0, state.1)
}

/// Groups the cases to run by suite, preserving order.
fn group(to_run: List(#(Suite, Case))) -> List(#(Suite, List(Case))) {
  let initial: List(#(Suite, List(Case))) = []
  to_run
  |> list.fold(initial, fn(groups, entry) {
    let #(suite, c) = entry
    case groups {
      [] -> [#(suite, [c])]
      [first, ..rest] ->
        case first.0.name == suite.name {
          True -> [#(first.0, [c, ..first.1]), ..rest]
          False -> [#(suite, [c]), ..groups]
        }
    }
  })
  |> list.map(fn(entry) { #(entry.0, list.reverse(entry.1)) })
  |> list.reverse
}

/// Runs one suite: its `before_all` hook, then its cases, then its
/// `after_all` hook. Returns the case results, the suite-level hook
/// failures (if any), and whether fail-fast stopped the suite.
fn run_suite(
  suite: Suite,
  cases: List(Case),
  config: Config,
  sink: fn(Event) -> Nil,
) -> #(List(CaseResult), Option(List(Failure)), Bool) {
  sink(SuiteStarted(suite.name))

  let before_failures = run_hook(suite.hooks.before_all, config)
  case before_failures {
    [] -> {
      let #(results, stopped) =
        list.fold(cases, #([], False), fn(state, c) {
          let #(acc, stopped) = state
          case stopped {
            True -> #([skip_case(suite, c, sink), ..acc], True)
            False -> {
              let result = run_case(suite, c, config, sink)
              let stopped =
                config.stop_on_first_failure
                && case result.outcome {
                  Failed(_) -> True
                  _ -> False
                }
              #([result, ..acc], stopped)
            }
          }
        })

      let after_failures = run_hook(suite.hooks.after_all, config)
      let outcome = case after_failures {
        [] -> None
        _ -> Some(after_failures)
      }
      let stopped =
        stopped || { config.stop_on_first_failure && after_failures != [] }
      sink(
        SuiteFinished(suite.name, case outcome {
          None -> Passed
          Some(failures) -> Failed(failures)
        }),
      )
      #(list.reverse(results), outcome, stopped)
    }
    _ -> {
      let results = list.map(cases, fn(c) { skip_case(suite, c, sink) })
      let outcome = Some(before_failures)
      sink(SuiteFinished(suite.name, Failed(before_failures)))
      #(results, outcome, config.stop_on_first_failure)
    }
  }
}

fn run_case(
  suite: Suite,
  c: Case,
  config: Config,
  sink: fn(Event) -> Nil,
) -> CaseResult {
  sink(CaseStarted(suite.name, c.name))
  let case_start = sys.now_ms()
  let isolated = isolate(body_for(suite, c), config.case_timeout_ms)
  let duration = sys.now_ms() - case_start
  let outcome = outcome_of(isolated)
  sink(CaseFinished(suite.name, c.name, outcome, duration))
  CaseResult(suite.name, c.name, outcome, duration)
}

fn skip_case(suite: Suite, c: Case, sink: fn(Event) -> Nil) -> CaseResult {
  let result = CaseResult(suite.name, c.name, Skipped, 0)
  sink(CaseFinished(suite.name, c.name, Skipped, 0))
  result
}

/// Runs a suite-level hook in isolation and returns the failures it
/// recorded (an empty list when the hook is absent or passed).
fn run_hook(hook: Option(fn() -> Nil), config: Config) -> List(Failure) {
  case hook {
    None -> []
    Some(hook) ->
      case isolate(hook, config.case_timeout_ms) {
        Completed(failures) -> failures
        Crashed(error) -> [
          UnexpectedError(error.name, error.message, error.location),
        ]
      }
  }
}

fn outcome_of(isolated: Isolated) -> Outcome {
  case isolated {
    Completed([]) -> Passed
    Completed(failures) -> Failed(failures)
    Crashed(error) ->
      Failed([UnexpectedError(error.name, error.message, error.location)])
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
