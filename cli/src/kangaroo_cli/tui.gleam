import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import kangaroo/event.{
  type Event, CaseFinished, CaseStarted, RunFinished, RunStarted, SuiteFinished,
  SuiteStarted,
}
import kangaroo/failure.{
  type Failure, type Outcome, AssertionFailed, EqualityMismatch,
  Failed as FailureFailed, Passed as FailurePassed, Skipped as FailureSkipped,
  UnexpectedError,
}
import kangaroo/format
import kangaroo/location.{type Location}
import kangaroo/report.{type Summary}

/// The status of a single case in the TUI.
pub type CaseStatus {
  Pending
  Running
  Passed
  Failed(failures: List(Failure))
  Skipped
}

pub type UiCase {
  UiCase(name: String, status: CaseStatus, duration_ms: Int)
}

pub type UiSuite {
  UiSuite(name: String, cases: List(UiCase), hook_failures: List(Failure))
}

/// The full state of the terminal UI, derived purely from events plus the
/// watch-session information attached by the CLI.
pub type UiState {
  UiState(
    suites: List(UiSuite),
    summary: Option(Summary),
    run_info: Option(RunInfo),
  )
}

/// Watch-session information about the most recent run: how many files
/// changed and how many test modules were affected (`None` means a full
/// run).
pub type RunInfo {
  RunInfo(changed: Int, affected: Option(Int))
}

pub fn initial() -> UiState {
  UiState([], None, None)
}

/// Records the watch-session information of the most recent run.
pub fn with_run_info(state: UiState, info: RunInfo) -> UiState {
  UiState(state.suites, state.summary, Some(info))
}

/// Applies a runner event to the UI state.
pub fn apply(state: UiState, event: Event) -> UiState {
  case event {
    RunStarted(_, _) -> UiState([], None, state.run_info)
    CaseStarted(suite_name, case_name) ->
      upsert_case(state, suite_name, case_name, Running, 0)
    CaseFinished(suite_name, case_name, outcome, duration_ms) ->
      upsert_case(state, suite_name, case_name, status_of(outcome), duration_ms)
    SuiteStarted(suite_name) -> ensure_suite(state, suite_name)
    SuiteFinished(suite_name, outcome) ->
      set_suite_failures(state, suite_name, hook_failures_of(outcome))
    RunFinished(_, summary) ->
      UiState(state.suites, Some(summary), state.run_info)
  }
}

fn hook_failures_of(outcome: Outcome) -> List(Failure) {
  case outcome {
    FailurePassed -> []
    FailureSkipped -> []
    FailureFailed(failures) -> failures
  }
}

fn ensure_suite(state: UiState, suite_name: String) -> UiState {
  case list.any(state.suites, fn(suite) { suite.name == suite_name }) {
    True -> state
    False ->
      UiState(
        list.append(state.suites, [UiSuite(suite_name, [], [])]),
        state.summary,
        state.run_info,
      )
  }
}

fn set_suite_failures(
  state: UiState,
  suite_name: String,
  failures: List(Failure),
) -> UiState {
  let suites =
    list.map(state.suites, fn(suite) {
      case suite.name == suite_name {
        True -> UiSuite(suite.name, suite.cases, failures)
        False -> suite
      }
    })
  UiState(suites, state.summary, state.run_info)
}

fn status_of(outcome: Outcome) -> CaseStatus {
  case outcome {
    FailurePassed -> Passed
    FailureFailed(failures) -> Failed(failures)
    FailureSkipped -> Skipped
  }
}

fn upsert_case(
  state: UiState,
  suite_name: String,
  case_name: String,
  status: CaseStatus,
  duration_ms: Int,
) -> UiState {
  let suites =
    upsert_suite(state.suites, suite_name, case_name, status, duration_ms)
  UiState(suites, state.summary, state.run_info)
}

fn upsert_suite(
  suites: List(UiSuite),
  suite_name: String,
  case_name: String,
  status: CaseStatus,
  duration_ms: Int,
) -> List(UiSuite) {
  case suites {
    [] -> [UiSuite(suite_name, [UiCase(case_name, status, duration_ms)], [])]
    [first, ..rest] if first.name == suite_name -> [
      UiSuite(
        first.name,
        upsert_case_in(first.cases, case_name, status, duration_ms),
        first.hook_failures,
      ),
      ..rest
    ]
    [first, ..rest] -> [
      first,
      ..upsert_suite(rest, suite_name, case_name, status, duration_ms)
    ]
  }
}

fn upsert_case_in(
  cases: List(UiCase),
  case_name: String,
  status: CaseStatus,
  duration_ms: Int,
) -> List(UiCase) {
  case cases {
    [] -> [UiCase(case_name, status, duration_ms)]
    [first, ..rest] if first.name == case_name -> [
      UiCase(case_name, status, duration_ms),
      ..rest
    ]
    [first, ..rest] -> [
      first,
      ..upsert_case_in(rest, case_name, status, duration_ms)
    ]
  }
}

/// What the TUI should show.
pub type View {
  /// Every case.
  All
  /// Only cases that failed (or are still running).
  FailuresOnly
}

/// The slowest completed case across every suite, when any case has a
/// measurable duration.
pub fn slowest(suites: List(UiSuite)) -> Option(#(String, Int)) {
  suites
  |> list.map(fn(suite) { suite.cases })
  |> list.flatten
  |> list.fold(None, fn(best, item) {
    case item.duration_ms {
      0 -> best
      _ ->
        case best {
          None -> Some(#(item.name, item.duration_ms))
          Some(#(_, current)) if item.duration_ms > current ->
            Some(#(item.name, item.duration_ms))
          _ -> best
        }
    }
  })
}

/// Renders the current state as an ANSI screen. The screen is cleared and
/// the cursor is placed at the top before drawing.
pub fn render(state: UiState, view: View) -> String {
  clear_screen()
  <> header()
  <> suites_section(visible_suites(state.suites, view))
  <> summary_section(state)
}

fn visible_suites(suites: List(UiSuite), view: View) -> List(UiSuite) {
  case view {
    All -> suites
    FailuresOnly ->
      suites
      |> list.map(fn(suite) {
        UiSuite(
          suite.name,
          list.filter(suite.cases, fn(c) {
            case c.status {
              Failed(_) -> True
              Running -> True
              _ -> False
            }
          }),
          suite.hook_failures,
        )
      })
      |> list.filter(fn(suite) {
        suite.cases != [] || suite.hook_failures != []
      })
  }
}

fn clear_screen() -> String {
  "\u{1b}[2J\u{1b}[H"
}

const bold = "\u{1b}[1m"

const green = "\u{1b}[32m"

const red = "\u{1b}[31m"

const yellow = "\u{1b}[33m"

const dim = "\u{1b}[2m"

const reset = "\u{1b}[0m"

fn header() -> String {
  bold
  <> "kangaroo"
  <> reset
  <> " — continuous test runner\n"
  <> dim
  <> "Ctrl+C to quit"
  <> reset
  <> "\n"
}

fn suites_section(suites: List(UiSuite)) -> String {
  suites
  |> list.map(fn(suite) {
    case suite.cases != [] || suite.hook_failures != [] {
      False -> ""
      True -> {
        let rendered_cases =
          suite.cases
          |> list.map(render_case)
          |> list.append(render_hook_failures(suite))
          |> string.join("\n")
        "\n" <> bold <> suite.name <> reset <> "\n" <> rendered_cases <> "\n"
      }
    }
  })
  |> string.join("")
}

fn render_hook_failures(suite: UiSuite) -> List(String) {
  case suite.hook_failures {
    [] -> []
    failures ->
      [red <> "  ⚠ suite hooks" <> reset]
      |> list.append(
        list.map(failures, fn(failure) { "  " <> render_failure(failure) }),
      )
  }
}

fn render_case(c: UiCase) -> String {
  let duration = c.duration_ms
  let duration_text = case duration {
    0 -> ""
    _ -> dim <> " (" <> int.to_string(duration) <> "ms)" <> reset
  }
  case c.status {
    Pending -> "  " <> dim <> "· " <> c.name <> reset
    Running -> "  " <> yellow <> "▶ " <> c.name <> reset
    Passed -> "  " <> green <> "✓ " <> c.name <> reset <> duration_text
    Failed(failures) -> {
      let rendered_failures =
        failures |> list.map(render_failure) |> string.join("\n")
      "  "
      <> red
      <> "✗ "
      <> c.name
      <> reset
      <> duration_text
      <> "\n"
      <> rendered_failures
    }
    Skipped -> "  " <> dim <> "⊘ " <> c.name <> reset
  }
}

fn render_failure(failure: Failure) -> String {
  case failure {
    EqualityMismatch(expected, actual, diff, location) ->
      "      "
      <> red
      <> "expected: "
      <> reset
      <> expected
      <> "\n"
      <> "      "
      <> red
      <> "actual:   "
      <> reset
      <> actual
      <> case diff {
        None -> ""
        Some(_) -> "\n" <> indent(format.render_diff(expected, actual), 4)
      }
      <> location_line(location)
    AssertionFailed(message, location) ->
      "      " <> red <> message <> reset <> location_line(location)
    UnexpectedError(name, message, location) ->
      "      "
      <> red
      <> "error ("
      <> name
      <> ")"
      <> reset
      <> ": "
      <> message
      <> location_line(location)
  }
}

fn location_line(location: Option(Location)) -> String {
  case location {
    None -> ""
    Some(location) ->
      "\n      "
      <> dim
      <> "at "
      <> location.file
      <> ":"
      <> int.to_string(location.line)
      <> reset
  }
}

fn indent(text: String, spaces: Int) -> String {
  let prefix = string.repeat(" ", spaces)
  text
  |> string.split("\n")
  |> list.map(fn(line) { prefix <> line })
  |> string.join("\n")
}

fn summary_section(state: UiState) -> String {
  case state.summary {
    None -> ""
    Some(summary) -> {
      let line =
        int.to_string(summary.passed)
        <> " passed, "
        <> int.to_string(summary.failed)
        <> " failed"
      let with_skipped = case summary.skipped {
        0 -> line
        _ -> line <> ", " <> int.to_string(summary.skipped) <> " skipped"
      }
      let counts = case summary.failed {
        0 -> green <> with_skipped <> reset
        _ -> red <> with_skipped <> reset
      }
      "\n"
      <> counts
      <> run_info_suffix(state.run_info)
      <> slowest_suffix(state.suites)
    }
  }
}

fn run_info_suffix(info: Option(RunInfo)) -> String {
  case info {
    None -> ""
    Some(info) ->
      " · "
      <> dim
      <> int.to_string(info.changed)
      <> " file(s) changed, "
      <> case info.affected {
        None -> "full run"
        Some(affected) -> int.to_string(affected) <> " affected test module(s)"
      }
      <> reset
  }
}

fn slowest_suffix(suites: List(UiSuite)) -> String {
  case slowest(suites) {
    None -> ""
    Some(#(name, duration)) ->
      " · "
      <> dim
      <> "slowest: "
      <> name
      <> " ("
      <> int.to_string(duration)
      <> "ms)"
      <> reset
  }
}
