import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import kangaroo/diff.{
  type DiffLine, Added, Kept, Removed, diff_lines_numbered,
}
import kangaroo/event.{type Event, CaseFinished, RunFinished}
import kangaroo/failure.{
  type Failure, AssertionFailed, EqualityMismatch, Failed, UnexpectedError,
}
import kangaroo/location
import kangaroo/report.{type CaseResult, type Summary}

const green = "\u{1b}[32m"

const red = "\u{1b}[31m"

const dim = "\u{1b}[2m"

const reset = "\u{1b}[0m"

/// The sink used for plain terminal output: prints failures as they happen
/// and the summary when the run finishes.
pub fn print_sink(event: Event) -> Nil {
  case event {
    CaseFinished(suite, case_name, Failed(failures), _) -> {
      io.println(red <> "  ✗ " <> suite <> " " <> case_name <> reset)
      failures |> list.each(failure_line)
    }
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

/// The source location line shown under a failure, when known.
pub fn location_line(location: Option(location.Location)) -> String {
  case location {
    None -> ""
    Some(loc) ->
      "\n    "
      <> dim
      <> "at "
      <> loc.file
      <> ":"
      <> int.to_string(loc.line)
      <> reset
  }
}

/// A colored, numbered unified diff of the expected and actual texts.
/// Falls back to the plain diff text when the texts cannot be rendered.
pub fn render_diff(expected: String, actual: String) -> String {
  case diff_lines_numbered(expected, actual) {
    None -> ""
    Some(lines) -> {
      let width = width_of(lines)
      lines
      |> list.map(fn(line) { render_diff_line(line, width) })
      |> string.join("\n")
    }
  }
}

fn width_of(lines: List(DiffLine)) -> Int {
  lines
  |> list.fold(1, fn(width, line) {
    let digits = string.length(int.to_string(number_of(line)))
    case digits > width {
      True -> digits
      False -> width
    }
  })
}

fn number_of(line: DiffLine) -> Int {
  case line {
    Kept(number, _) -> number
    Removed(number, _) -> number
    Added(number, _) -> number
  }
}

fn render_diff_line(line: DiffLine, width: Int) -> String {
  let padded = fn(number) {
    string.pad_start(int.to_string(number), width, " ")
  }
  case line {
    Kept(number, text) ->
      "    " <> dim <> " " <> padded(number) <> " " <> text <> reset
    Removed(number, text) ->
      "    " <> red <> "-" <> padded(number) <> " " <> text <> reset
    Added(number, text) ->
      "    " <> green <> "+" <> padded(number) <> " " <> text <> reset
  }
}

fn failure_line(failure: Failure) -> Nil {
  failure_body(failure) |> io.println
}

fn failure_body(failure: Failure) -> String {
  case failure {
    EqualityMismatch(expected, actual, diff, location) ->
      "    expected: "
      <> expected
      <> "\n    actual:   "
      <> actual
      <> case diff {
        None -> ""
        Some(_) -> "\n    diff:\n" <> render_diff(expected, actual)
      }
      <> location_line(location)
    AssertionFailed(message, location) ->
      "    " <> message <> location_line(location)
    UnexpectedError(name, message, location) ->
      "    "
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
