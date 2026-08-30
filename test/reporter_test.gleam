import gleam/option.{None}
import gleam/string
import kangaroo/failure.{Failed, Passed, Skipped, UnexpectedError}
import kangaroo/internal/reporter
import kangaroo/report.{CaseResult, Report}

fn sample_report() {
  Report(cases: [
    CaseResult("math", "test/math.gleam::passes_test", Passed, 5),
    CaseResult(
      "math",
      "test/math.gleam::fails_test",
      Failed([UnexpectedError("panic", "a < b & c", None)]),
      10,
    ),
    CaseResult("io", "test/io.gleam::skip_test", Skipped, 0),
  ])
}

pub fn dot_reporter_maps_outcomes_to_compact_symbols_test() {
  assert reporter.dot(Passed) == "."
  assert reporter.dot(Failed([])) == "F"
  assert reporter.dot(Skipped) == "S"
}

pub fn junit_reporter_escapes_testcase_outcomes_test() {
  let xml = reporter.junit(sample_report(), 15)
  assert string.starts_with(xml, "<?xml version=\"1.0\"")
  assert string.contains(xml, "tests=\"3\" failures=\"1\" skipped=\"1\"")
  assert string.contains(xml, "a &lt; b &amp; c")
  assert string.contains(xml, "<skipped/>")
}

pub fn reporter_derives_path_and_function_from_stable_id_test() {
  assert reporter.id_parts("test/unit/math.gleam::addition_test")
    == #("test/unit/math.gleam", "addition_test")
}

pub fn junit_reporter_retains_escaped_stdout_and_stderr_test() {
  let xml =
    reporter.junit_with_output(
      sample_report(),
      [
        reporter.CaseCapture(
          "test/math.gleam::passes_test",
          "hello <world>\n",
          "warning & detail\n",
        ),
      ],
      15,
    )
  assert string.contains(xml, "<system-out>hello &lt;world&gt;\n</system-out>")
  assert string.contains(xml, "<system-err>warning &amp; detail\n</system-err>")
}
