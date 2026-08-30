import gleam/io
import gleam/option.{None}
import gleam/string
import kangaroo
import kangaroo/failure.{Failed, Passed, Skipped, UnexpectedError}
import kangaroo/internal/process
import kangaroo/internal/reporter
import kangaroo/internal/vm
import kangaroo/internal/watcher
import kangaroo/report.{CaseResult, Report}
import kangaroo/sys

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

pub fn dot_reporter_retains_failure_details_and_captured_output_test() {
  kangaroo.serial()
  kangaroo.timeout(120_000)
  let selection = "test/reporter_test.gleam::dot_reporter_failure_fixture_test"
  let assert Ok(completed) =
    process.run(
      ".",
      "gleam",
      watcher.run_arguments_for(vm.target(), vm.runtime_name(), [
        "--reporter",
        "dot",
        selection,
      ]),
      [#("KANGAROO_DOT_REPORTER_FIXTURE", "1")],
      90_000,
    )
  assert completed.exit_code == 1
  assert string.contains(completed.output, "F")
  assert string.contains(completed.output, "dot fixture failure detail")
  assert string.contains(
    completed.output,
    "stdout (" <> selection <> "):\n      dot fixture stdout",
  )
  assert string.contains(
    completed.output,
    "stderr (" <> selection <> "):\n      dot fixture stderr",
  )
  assert string.contains(completed.output, "0 passed, 1 failed, 0 skipped")
}

pub fn dot_reporter_failure_fixture_test() {
  case sys.env("KANGAROO_DOT_REPORTER_FIXTURE") {
    None -> Nil
    _ -> {
      io.println("dot fixture stdout")
      io.println_error("dot fixture stderr")
      panic as "dot fixture failure detail"
    }
  }
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

pub fn junit_reporter_removes_xml_forbidden_control_characters_test() {
  let xml =
    reporter.junit_with_output(
      sample_report(),
      [
        reporter.CaseCapture(
          "test/math.gleam::passes_test",
          "before\u{1b}[31mred\u{0}after\t🦘",
          "",
        ),
      ],
      15,
    )
  assert !string.contains(xml, "\u{1b}")
  assert !string.contains(xml, "\u{0}")
  assert string.contains(xml, "before[31mredafter\t🦘")
}
