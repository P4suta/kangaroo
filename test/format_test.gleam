import gleam/option.{None, Some}
import gleam/string
import kangaroo/event.{CaseOutput}
import kangaroo/failure.{EqualityMismatch, Failed, Passed}
import kangaroo/format
import kangaroo/isolate.{CapturedIsolation, Completed, isolate_captured}
import kangaroo/location.{Location}
import kangaroo/report.{CaseResult}

pub fn empty_case_output_does_not_print_a_blank_line_test() {
  assert format.case_output_text("case", "", "", Passed) == None
  let assert CapturedIsolation(Completed, stdout, stderr) =
    isolate_captured(
      fn() { format.print_sink(CaseOutput("suite", "case", "", "", Passed)) },
      None,
    )
  assert stdout == ""
  assert stderr == ""
}

pub fn format_renders_coloured_numbered_diff_test() {
  let rendered = format.render_diff("a\nb\nc", "a\nx\nc")
  assert string.contains(rendered, "\u{1b}[31m")
  assert string.contains(rendered, "\u{1b}[32m")
  assert string.contains(rendered, "-2 b")
  assert string.contains(rendered, "+2 x")
  assert string.contains(rendered, "1 a")
}

pub fn format_renders_nothing_for_identical_text_test() {
  assert format.render_diff("a\nb", "a\nb") == ""
}

pub fn format_omits_diff_for_single_lines_test() {
  assert format.render_diff("x", "y") == ""
}

pub fn format_renders_location_line_test() {
  let rendered =
    format.location_line(Some(Location("test/foo_test.gleam", 7, None)))
  assert string.contains(rendered, "at test/foo_test.gleam:7")
}

pub fn format_omits_unknown_location_line_test() {
  assert format.location_line(None) == ""
}

pub fn format_uses_structural_diff_for_one_line_values_test() {
  let lines =
    format.failure_lines(CaseResult(
      "suite",
      "list assertion",
      Failed([
        EqualityMismatch("[1, 3]", "[1, 2]", Some("  1\n- 3\n+ 2"), None),
      ]),
      1,
    ))
  let rendered = string.join(lines, "\n")
  assert string.contains(rendered, "- 3")
  assert string.contains(rendered, "+ 2")
}

pub fn format_labels_captured_stdout_and_stderr_test() {
  assert format.output_text(
      "test/math.gleam::prints_test",
      "hello\n",
      "warning\n",
      Passed,
    )
    == "    stdout (test/math.gleam::prints_test):\n      hello\n    stderr (test/math.gleam::prints_test):\n      warning"
}
