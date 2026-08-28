import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import kangaroo/event.{type Event, CaseFinished, RunFinished}
import kangaroo/failure.{
  type Failure, AssertionFailed, EqualityMismatch, Failed, UnexpectedError,
}
import kangaroo/report.{type CaseResult, type Summary}

const green = "\u{1b}[32m"

const red = "\u{1b}[31m"

const reset = "\u{1b}[0m"

/// The sink used for plain terminal output: prints failures as they happen
/// and the summary when the run finishes.
pub fn print_sink(event: Event) -> Nil {
  case event {
    CaseFinished(_, _, Failed(failures), _) ->
      failures |> list.each(failure_line)
    RunFinished(_, summary) -> io.println(summary_line(summary))
    _ -> Nil
  }
}

/// A single line summarising the outcome of a run.
pub fn summary_line(summary: Summary) -> String {
  let base =
    int.to_string(summary.passed)
    <> " passed, "
    <> int.to_string(summary.failed)
    <> " failed"
  let with_skipped = case summary.skipped {
    0 -> base
    _ -> base <> ", " <> int.to_string(summary.skipped) <> " skipped"
  }
  let colored = case summary.failed {
    0 -> green <> with_skipped <> reset
    _ -> red <> with_skipped <> reset
  }
  colored <> " (in " <> int.to_string(summary.duration_ms) <> "ms)"
}

/// The human-readable lines describing a single case failure.
pub fn failure_lines(result: CaseResult) -> List(String) {
  case result.outcome {
    Failed(failures) ->
      [red <> "  ✗ " <> result.case_name <> reset]
      |> list.append(failures |> list.map(failure_body))
    _ -> []
  }
}

fn failure_line(failure: Failure) -> Nil {
  failure_body(failure) |> io.println
}

fn failure_body(failure: Failure) -> String {
  case failure {
    EqualityMismatch(expected, actual, diff) ->
      "    expected: "
      <> expected
      <> "\n    actual:   "
      <> actual
      <> case diff {
        None -> ""
        Some(diff) -> "\n    diff:\n" <> indent(diff)
      }
    AssertionFailed(message) -> "    " <> message
    UnexpectedError(name, message) ->
      "    " <> red <> "error (" <> name <> ")" <> reset <> ": " <> message
  }
}

fn indent(text: String) -> String {
  text
  |> string.split("\n")
  |> list.map(fn(line) { "      " <> line })
  |> string.join("\n")
}
