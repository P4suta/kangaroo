import gleam/option.{None, Some}
import gleam/string
import kangaroo/encode
import kangaroo/event.{CaseFinished, CaseStarted, RunFinished, RunStarted}
import kangaroo/failure.{AssertionFailed, Failed, Passed, SkippedWithReason}
import kangaroo/internal/tui
import kangaroo/location.{Location}
import kangaroo/report.{Summary}

pub fn tui_reduces_events_and_filters_failures_test() {
  let state =
    tui.initial()
    |> tui.apply(RunStarted(1, 2))
    |> tui.apply(CaseStarted("math", "test/math.gleam::passing_test"))
    |> tui.apply(CaseFinished(
      "math",
      "test/math.gleam::passing_test",
      Passed,
      2,
    ))
    |> tui.apply(CaseFinished(
      "math",
      "test/math.gleam::failing_test",
      Failed([
        AssertionFailed(
          "expected truth",
          Some(Location("test/math.gleam", 9, None)),
        ),
      ]),
      3,
    ))
    |> tui.apply(RunFinished(1, Summary(1, 1, 0, 5)))

  let all = tui.render(state, 100, 30, False)
  let failures = state |> tui.toggle_failures |> tui.render(100, 30, False)
  assert string.contains(all, "passing_test")
  assert string.contains(all, "failing_test")
  assert !string.contains(failures, "passing_test")
  assert string.contains(failures, "expected truth")
  assert string.contains(failures, "test/math.gleam:9")
}

pub fn tui_search_and_key_actions_test() {
  let state =
    tui.initial()
    |> tui.apply(CaseFinished(
      "math",
      "test/math.gleam::addition_test",
      Passed,
      1,
    ))
    |> tui.apply(CaseFinished(
      "strings",
      "test/string.gleam::uppercase_test",
      SkippedWithReason("pending"),
      0,
    ))
    |> tui.begin_search
    |> tui.search_key("u")
    |> tui.search_key("p")
    |> tui.search_key("\r")

  let rendered = tui.render(state, 100, 30, False)
  assert !string.contains(rendered, "addition_test")
  assert string.contains(rendered, "uppercase_test")
  assert tui.key_action("r", False) == tui.Rerun
  assert tui.key_action("c", False) == tui.Coverage
  assert tui.key_action("b", False) == tui.Birdie
  assert tui.key_action("f", False) == tui.ToggleFailures
  assert tui.key_action("/", False) == tui.Search
  assert tui.key_action("q", False) == tui.Quit
  assert tui.key_action("x", True) == tui.SearchInput("x")
}

pub fn tui_renders_narrow_terminal_without_colour_test() {
  let state =
    tui.initial()
    |> tui.with_status("watching 2 paths")
    |> tui.apply(CaseFinished("math", "test/math.gleam::tiny_test", Passed, 1))
  let rendered = tui.render(state, 24, 5, False)

  assert string.contains(rendered, "kangaroo")
  assert string.contains(rendered, "r rerun")
  assert !string.contains(rendered, "\u{1b}[32m")
  assert list_length(string.split(rendered, "\n")) <= 5
}

pub fn tui_accepts_only_complete_event_lines_from_child_output_test() {
  let output =
    "Compiling project\n"
    <> encode.encode(RunStarted(7, 1))
    <> "\n"
    <> "not json\n"
    <> encode.encode(CaseFinished(
      "math",
      "test/math.gleam::child_test",
      Passed,
      1,
    ))
    <> "\n"
    <> encode.encode(RunFinished(7, Summary(1, 0, 0, 1)))
    <> "\n"
  let rendered =
    tui.initial() |> tui.apply_output(output) |> tui.render(80, 20, False)

  assert string.contains(rendered, "child_test")
  assert string.contains(rendered, "1 passed, 0 failed")
  assert !string.contains(rendered, "Compiling project")
}

pub fn tui_buffers_ndjson_split_across_process_chunks_test() {
  let first =
    "{\"type\":\"case_finished\",\"suite\":\"math\",\"case\":\"test/math.gleam::child"
  let second = "_test\",\"outcome\":{\"kind\":\"passed\"},\"duration_ms\":1}\n"
  let partial = tui.initial() |> tui.apply_chunk(first)

  assert !string.contains(tui.render(partial, 80, 20, False), "child_test")

  let completed = partial |> tui.apply_chunk(second)
  assert string.contains(tui.render(completed, 80, 20, False), "child_test")
}

fn list_length(items: List(a)) -> Int {
  case items {
    [] -> 0
    [_, ..rest] -> 1 + list_length(rest)
  }
}
