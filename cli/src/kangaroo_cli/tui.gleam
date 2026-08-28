import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import kangaroo/event.{
  type Event, CaseFinished, CaseStarted, RunFinished, RunStarted,
}
import kangaroo/failure.{
  type Failure, type Outcome, AssertionFailed, EqualityMismatch,
  Failed as FailureFailed, Passed as FailurePassed, Skipped as FailureSkipped,
  UnexpectedError,
}
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
  UiSuite(name: String, cases: List(UiCase))
}

/// The full state of the terminal UI, derived purely from events.
pub type UiState {
  UiState(suites: List(UiSuite), summary: Option(Summary))
}

pub fn initial() -> UiState {
  UiState([], None)
}

/// Applies a runner event to the UI state.
pub fn apply(state: UiState, event: Event) -> UiState {
  case event {
    RunStarted(_, _) -> UiState([], None)
    CaseStarted(suite_name, case_name) ->
      upsert_case(state, suite_name, case_name, Running, 0)
    CaseFinished(suite_name, case_name, outcome, duration_ms) ->
      upsert_case(state, suite_name, case_name, status_of(outcome), duration_ms)
    RunFinished(_, summary) -> UiState(state.suites, Some(summary))
  }
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
  UiState(suites, state.summary)
}

fn upsert_suite(
  suites: List(UiSuite),
  suite_name: String,
  case_name: String,
  status: CaseStatus,
  duration_ms: Int,
) -> List(UiSuite) {
  case suites {
    [] -> [UiSuite(suite_name, [UiCase(case_name, status, duration_ms)])]
    [first, ..rest] if first.name == suite_name -> [
      UiSuite(
        first.name,
        upsert_case_in(first.cases, case_name, status, duration_ms),
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

/// Renders the current state as an ANSI screen. The screen is cleared and
/// the cursor is placed at the top before drawing.
pub fn render(state: UiState, view: View) -> String {
  clear_screen()
  <> header()
  <> suites_section(visible_suites(state.suites, view))
  <> summary_section(state.summary)
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
        )
      })
      |> list.filter(fn(suite) { suite.cases != [] })
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
    let cases = suite.cases
    case cases {
      [] -> ""
      _ -> {
        let rendered_cases = cases |> list.map(render_case) |> string.join("\n")
        "\n" <> bold <> suite.name <> reset <> "\n" <> rendered_cases <> "\n"
      }
    }
  })
  |> string.join("")
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
    EqualityMismatch(expected, actual, diff) ->
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
        Some(diff) -> "\n      diff:\n" <> indent(diff, 8)
      }
    AssertionFailed(message) -> "      " <> red <> message <> reset
    UnexpectedError(name, message) ->
      "      " <> red <> "error (" <> name <> ")" <> reset <> ": " <> message
  }
}

fn indent(text: String, spaces: Int) -> String {
  let prefix = string.repeat(" ", spaces)
  text
  |> string.split("\n")
  |> list.map(fn(line) { prefix <> line })
  |> string.join("\n")
}

fn summary_section(summary: Option(Summary)) -> String {
  case summary {
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
      "\n"
      <> case summary.failed {
        0 -> green <> with_skipped <> reset
        _ -> red <> with_skipped <> reset
      }
    }
  }
}
