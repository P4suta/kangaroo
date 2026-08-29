import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import kangaroo/event.{
  type Event, CaseFinished, CaseOutput, CaseStarted, RunFinished, RunStarted,
  SuiteFinished, SuiteStarted,
}
import kangaroo/failure.{
  type Failure, type Outcome, AssertionFailed, EqualityMismatch, Failed, Flaky,
  Passed, Skipped, SkippedWithReason, UnexpectedError,
}
import kangaroo/internal/legacy/suite.{type Case, type Suite}
import kangaroo/isolate.{
  type Isolated, CapturedIsolation, Completed, Crashed, SkippedIsolation,
  isolate, isolate_captured,
}
import kangaroo/report.{
  type CaseResult, type Report, CaseResult, Report, summary,
}
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
  run_with_retries(suites, sink, config, 0)
}

/// Runs with an explicit retry budget. Passing after any failed attempt is
/// classified as flaky rather than passed.
pub fn run_with_retries(
  suites: List(Suite),
  sink: fn(Event) -> Nil,
  config: Config,
  retries: Int,
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
            run_suite(suite, cases, config, retries, sink)
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
  retries: Int,
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
              let result = run_case(suite, c, config, retries, sink)
              let stopped =
                config.stop_on_first_failure
                && case result.outcome {
                  Failed(_) -> True
                  Flaky(_, _) -> True
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
  retries: Int,
  sink: fn(Event) -> Nil,
) -> CaseResult {
  sink(CaseStarted(suite.name, c.name))
  let case_start = sys.now_ms()
  let timeout = case c.timeout_ms {
    Some(timeout) -> Some(timeout)
    None -> config.case_timeout_ms
  }
  let AttemptResult(outcome, stdout, stderr) =
    retry(body_for(suite, c), timeout, retries, 1, [], "", "")
  let duration = sys.now_ms() - case_start
  sink(CaseFinished(suite.name, c.name, outcome, duration))
  case stdout == "" && stderr == "" {
    True -> Nil
    False -> sink(CaseOutput(suite.name, c.name, stdout, stderr, outcome))
  }
  CaseResult(suite.name, c.name, outcome, duration)
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
  let stdout = previous_stdout <> stdout
  let stderr = previous_stderr <> stderr
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
    outcome, _, _ -> AttemptResult(outcome, stdout, stderr)
  }
}

fn skip_case(suite: Suite, c: Case, sink: fn(Event) -> Nil) -> CaseResult {
  let outcome = case c.skip_reason {
    Some(reason) -> SkippedWithReason(reason)
    None -> Skipped
  }
  let result = CaseResult(suite.name, c.name, outcome, 0)
  sink(CaseFinished(suite.name, c.name, outcome, 0))
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
        SkippedIsolation(reason) -> [
          UnexpectedError("skip", reason, None),
        ]
      }
  }
}

fn outcome_of(isolated: Isolated) -> Outcome {
  case isolated {
    Completed([]) -> Passed
    Completed(failures) -> Failed(failures)
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
