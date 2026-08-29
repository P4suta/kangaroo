import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
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
import kangaroo/location.{type Location}
import kangaroo/report.{type Summary}

pub type View {
  All
  FailuresOnly
}

pub type KeyAction {
  Nothing
  Rerun
  Coverage
  Birdie
  ToggleFailures
  Search
  Quit
  SearchInput(value: String)
  SearchBackspace
  SearchCommit
  SearchCancel
}

pub type CaseStatus {
  Running
  Finished(outcome: Outcome, duration_ms: Int)
}

pub type UiCase {
  UiCase(module: String, id: String, status: CaseStatus)
}

/// Pure state shared by the terminal renderer and its tests. It contains no
/// terminal handles, processes, or clocks, so stale generations can be
/// discarded before they ever mutate the visible screen.
pub type State {
  State(
    cases: List(UiCase),
    summary: Option(Summary),
    status: String,
    compile_error: Option(String),
    view: View,
    query: String,
    searching: Bool,
    output_buffer: String,
  )
}

pub fn initial() -> State {
  State([], None, "starting", None, All, "", False, "")
}

pub fn with_status(state: State, status: String) -> State {
  State(..state, status:)
}

pub fn with_compile_error(state: State, output: String) -> State {
  State(..state, status: "compile failed", compile_error: Some(output))
}

pub fn toggle_failures(state: State) -> State {
  State(..state, view: case state.view {
    All -> FailuresOnly
    FailuresOnly -> All
  })
}

pub fn begin_search(state: State) -> State {
  State(..state, searching: True)
}

pub fn search_key(state: State, key: String) -> State {
  case key {
    "\r" | "\n" -> State(..state, searching: False)
    "\u{1b}" -> State(..state, query: "", searching: False)
    "\u{8}" | "\u{7f}" -> State(..state, query: string.drop_end(state.query, 1))
    value -> State(..state, query: state.query <> value)
  }
}

pub fn key_action(key: String, searching: Bool) -> KeyAction {
  case searching, key {
    True, "\r" | True, "\n" -> SearchCommit
    True, "\u{1b}" -> SearchCancel
    True, "\u{8}" | True, "\u{7f}" -> SearchBackspace
    True, value -> SearchInput(value)
    False, "r" -> Rerun
    False, "c" -> Coverage
    False, "b" -> Birdie
    False, "f" -> ToggleFailures
    False, "/" -> Search
    False, "q" | False, "\u{3}" -> Quit
    False, _ -> Nothing
  }
}

pub fn apply(state: State, event: Event) -> State {
  case event {
    RunStarted(_, _) ->
      State(
        ..state,
        cases: [],
        summary: None,
        status: "running",
        compile_error: None,
      )
    CaseStarted(module, id) -> upsert(state, module, id, Running)
    CaseFinished(module, id, outcome, duration_ms) ->
      upsert(state, module, id, Finished(outcome, duration_ms))
    RunFinished(_, summary) ->
      State(..state, summary: Some(summary), status: "watching")
    CaseOutput(..) | SuiteStarted(..) | SuiteFinished(..) -> state
  }
}

pub fn apply_output(state: State, output: String) -> State {
  state |> apply_chunk(output) |> finish_output
}

pub fn finish_output(state: State) -> State {
  case state.output_buffer {
    "" -> state
    line -> apply_line(State(..state, output_buffer: ""), line)
  }
}

/// Applies only complete NDJSON records and retains a trailing partial record
/// for the next process chunk.
pub fn apply_chunk(state: State, chunk: String) -> State {
  let output = state.output_buffer <> chunk
  let parts =
    output
    |> string.split("\n")
    |> list.reverse
  let #(remainder, lines) = case parts {
    [] -> #("", [])
    [remainder, ..complete] -> #(remainder, list.reverse(complete))
  }
  lines
  |> list.fold(State(..state, output_buffer: remainder), fn(state, line) {
    apply_line(state, string.trim_end(line))
  })
}

fn apply_line(state: State, line: String) -> State {
  case encode.decode(line) {
    Ok(event) -> apply(state, event)
    Error(_) -> state
  }
}

fn upsert(
  state: State,
  module: String,
  id: String,
  status: CaseStatus,
) -> State {
  State(..state, cases: upsert_case(state.cases, module, id, status))
}

fn upsert_case(
  cases: List(UiCase),
  module: String,
  id: String,
  status: CaseStatus,
) -> List(UiCase) {
  case cases {
    [] -> [UiCase(module, id, status)]
    [first, ..rest] if first.id == id -> [UiCase(module, id, status), ..rest]
    [first, ..rest] -> [first, ..upsert_case(rest, module, id, status)]
  }
}

/// Renders at most `height` lines. Narrow terminals retain the live state and
/// primary controls while omitting verbose secondary controls.
pub fn render(state: State, width: Int, height: Int, colour: Bool) -> String {
  let width = int.max(width, 1)
  let height = int.max(height, 3)
  let header =
    "\u{1b}[2J\u{1b}[H"
    <> style(colour, "1", "kangaroo")
    <> case width < 40 {
      True -> " · " <> state.status
      False -> " — continuous tests · " <> state.status
    }
  let status = case state.searching, state.query {
    True, query -> "/" <> query <> "_"
    False, "" -> summary_line(state.summary, colour)
    False, query -> "search: " <> query
  }
  let body = case state.compile_error {
    Some(output) -> [
      style(colour, "31", "compile failed"),
      ..error_lines(output)
    ]
    None ->
      visible_cases(state)
      |> list.flat_map(fn(item) { render_case(item, width, colour) })
  }
  let footer = case width < 52 {
    True -> "r rerun · f · / · q"
    False -> "r rerun · f failures · / search · c coverage · b Birdie · q quit"
  }
  let fixed = case status {
    "" -> [header]
    status -> [header, status]
  }
  let available = int.max(0, height - list.length(fixed) - 1)
  list.append(fixed, list.take(body, available))
  |> list.append([style(colour, "2", footer)])
  |> list.map(fn(line) { fit_line(line, width, colour) })
  |> string.join("\n")
}

fn fit_line(line: String, width: Int, colour: Bool) -> String {
  fit_graphemes(string.to_graphemes(line), int.max(width, 1), False, colour)
}

fn fit_graphemes(
  graphemes: List(String),
  remaining: Int,
  ansi: Bool,
  colour: Bool,
) -> String {
  case graphemes, remaining, ansi {
    [], _, _ -> ""
    _, 0, _ ->
      case colour {
        True -> "\u{1b}[0m"
        False -> ""
      }
    ["\u{1b}", ..rest], _, False ->
      "\u{1b}" <> fit_graphemes(rest, remaining, True, colour)
    [grapheme, ..rest], _, True ->
      grapheme
      <> fit_graphemes(
        rest,
        remaining,
        !list.contains(["m", "J", "H"], grapheme),
        colour,
      )
    [grapheme, ..rest], _, False ->
      grapheme <> fit_graphemes(rest, remaining - 1, False, colour)
  }
}

fn visible_cases(state: State) -> List(UiCase) {
  state.cases
  |> list.filter(fn(item) {
    let view_matches = case state.view, item.status {
      All, _ -> True
      FailuresOnly, Running -> True
      FailuresOnly, Finished(Failed(_), _) -> True
      FailuresOnly, Finished(Flaky(_, _), _) -> True
      FailuresOnly, _ -> False
    }
    view_matches && query_matches(item, state.query)
  })
}

fn query_matches(item: UiCase, query: String) -> Bool {
  case string.lowercase(query) {
    "" -> True
    query ->
      string.contains(
        string.lowercase(
          item.module <> " " <> item.id <> " " <> status_text(item.status),
        ),
        query,
      )
  }
}

fn status_text(status: CaseStatus) -> String {
  case status {
    Running -> "running"
    Finished(Passed, _) -> "passed"
    Finished(Skipped, _) | Finished(SkippedWithReason(_), _) -> "skipped"
    Finished(Flaky(_, _), _) -> "flaky"
    Finished(Failed(_), _) -> "failed"
  }
}

fn render_case(item: UiCase, width: Int, colour: Bool) -> List(String) {
  let label = case width < 52 {
    True -> short_name(item.id)
    False -> item.id
  }
  case item.status {
    Running -> [style(colour, "33", "▶ " <> label)]
    Finished(Passed, duration) -> [
      style(colour, "32", "✓ " <> label) <> duration_text(duration),
    ]
    Finished(Skipped, _) -> [style(colour, "2", "⊘ " <> label)]
    Finished(SkippedWithReason(reason), _) -> [
      style(colour, "2", "⊘ " <> label <> " — " <> reason),
    ]
    Finished(Flaky(failures, attempts), duration) -> [
      style(
        colour,
        "33",
        "↻ " <> label <> " (flaky after " <> int.to_string(attempts) <> ")",
      )
        <> duration_text(duration),
      ..failure_lines(failures, colour)
    ]
    Finished(Failed(failures), duration) -> [
      style(colour, "31", "✗ " <> label) <> duration_text(duration),
      ..failure_lines(failures, colour)
    ]
  }
}

fn short_name(id: String) -> String {
  case string.split(id, "::") {
    [_, name] -> name
    _ -> id
  }
}

fn duration_text(duration: Int) -> String {
  case duration {
    0 -> ""
    duration -> " (" <> int.to_string(duration) <> "ms)"
  }
}

fn failure_lines(failures: List(Failure), colour: Bool) -> List(String) {
  list.map(failures, fn(failure) {
    "  " <> style(colour, "31", failure_text(failure))
  })
}

fn failure_text(failure: Failure) -> String {
  case failure {
    AssertionFailed(message, location) -> message <> location_text(location)
    UnexpectedError(name, message, location) ->
      name <> ": " <> message <> location_text(location)
    EqualityMismatch(expected, actual, _, location) ->
      "expected " <> expected <> ", got " <> actual <> location_text(location)
  }
}

fn location_text(location: Option(Location)) -> String {
  case location {
    None -> ""
    Some(location) ->
      " · " <> location.file <> ":" <> int.to_string(location.line)
  }
}

fn error_lines(output: String) -> List(String) {
  output |> string.trim |> string.split("\n")
}

fn summary_line(summary: Option(Summary), colour: Bool) -> String {
  case summary {
    None -> ""
    Some(summary) -> {
      let line =
        int.to_string(summary.passed)
        <> " passed, "
        <> int.to_string(summary.failed)
        <> " failed, "
        <> int.to_string(summary.skipped)
        <> " skipped · "
        <> int.to_string(summary.duration_ms)
        <> "ms"
      case summary.failed {
        0 -> style(colour, "32", line)
        _ -> style(colour, "31", line)
      }
    }
  }
}

fn style(enabled: Bool, code: String, text: String) -> String {
  case enabled {
    True -> "\u{1b}[" <> code <> "m" <> text <> "\u{1b}[0m"
    False -> text
  }
}
