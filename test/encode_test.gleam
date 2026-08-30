import gleam/option.{None, Some}
import kangaroo/encode
import kangaroo/event.{
  CaseFinished, CaseOutput, CaseStarted, RunFinished, RunStarted, SuiteFinished,
  SuiteStarted,
}
import kangaroo/failure.{
  EqualityMismatch, Failed, Passed, Skipped, SkippedWithReason,
}
import kangaroo/location.{Location}
import kangaroo/report.{Summary}

pub fn run_started_is_encoded_test() {
  assert encode.encode(RunStarted(7, 3))
    == "{\"type\":\"run_started\",\"run_id\":7,\"case_count\":3}"
}

pub fn case_started_is_encoded_test() {
  assert encode.encode(CaseStarted("math", "adds"))
    == "{\"type\":\"case_started\",\"suite\":\"math\",\"case\":\"adds\"}"
}

pub fn captured_case_output_is_encoded_test() {
  assert encode.encode(CaseOutput(
      "math",
      "adds",
      "hello\n",
      "warning\n",
      Passed,
    ))
    == "{\"type\":\"case_output\",\"suite\":\"math\",\"case\":\"adds\",\"stdout\":\"hello\\n\",\"stderr\":\"warning\\n\",\"outcome\":{\"kind\":\"passed\"}}"
}

pub fn passed_case_is_encoded_test() {
  assert encode.encode(CaseFinished("math", "adds", Passed, 5))
    == "{\"type\":\"case_finished\",\"suite\":\"math\",\"case\":\"adds\",\"outcome\":{\"kind\":\"passed\"},\"duration_ms\":5}"
}

pub fn skipped_case_is_encoded_test() {
  assert encode.encode(CaseFinished("math", "skips", Skipped, 0))
    == "{\"type\":\"case_finished\",\"suite\":\"math\",\"case\":\"skips\",\"outcome\":{\"kind\":\"skipped\"},\"duration_ms\":0}"
}

pub fn skip_reason_is_encoded_for_clients_test() {
  assert encode.encode(CaseFinished(
      "math",
      "platform",
      SkippedWithReason("windows only"),
      0,
    ))
    == "{\"type\":\"case_finished\",\"suite\":\"math\",\"case\":\"platform\",\"outcome\":{\"kind\":\"skipped\",\"reason\":\"windows only\"},\"duration_ms\":0}"
}

pub fn failed_case_is_encoded_test() {
  assert encode.encode(CaseFinished(
      "math",
      "adds",
      Failed([EqualityMismatch("2", "3", None, None)]),
      5,
    ))
    == "{\"type\":\"case_finished\",\"suite\":\"math\",\"case\":\"adds\",\"outcome\":{\"kind\":\"failed\",\"failures\":[{\"kind\":\"equality_mismatch\",\"expected\":\"2\",\"actual\":\"3\",\"diff\":null,\"location\":null}]},\"duration_ms\":5}"
}

pub fn failure_location_is_encoded_test() {
  let location = Some(Location("test/foo_test.gleam", 42, None))
  assert encode.encode(CaseFinished(
      "math",
      "adds",
      Failed([EqualityMismatch("2", "3", None, location)]),
      5,
    ))
    == "{\"type\":\"case_finished\",\"suite\":\"math\",\"case\":\"adds\",\"outcome\":{\"kind\":\"failed\",\"failures\":[{\"kind\":\"equality_mismatch\",\"expected\":\"2\",\"actual\":\"3\",\"diff\":null,\"location\":{\"file\":\"test/foo_test.gleam\",\"line\":42,\"column\":null}}]},\"duration_ms\":5}"
}

pub fn location_column_is_encoded_test() {
  let location = Some(Location("test/foo_test.gleam", 42, Some(9)))
  assert encode.encode(CaseFinished(
      "math",
      "adds",
      Failed([EqualityMismatch("2", "3", None, location)]),
      5,
    ))
    == "{\"type\":\"case_finished\",\"suite\":\"math\",\"case\":\"adds\",\"outcome\":{\"kind\":\"failed\",\"failures\":[{\"kind\":\"equality_mismatch\",\"expected\":\"2\",\"actual\":\"3\",\"diff\":null,\"location\":{\"file\":\"test/foo_test.gleam\",\"line\":42,\"column\":9}}]},\"duration_ms\":5}"
}

pub fn suite_events_are_encoded_test() {
  assert encode.encode(SuiteStarted("math"))
    == "{\"type\":\"suite_started\",\"suite\":\"math\"}"
  assert encode.encode(SuiteFinished("math", Passed))
    == "{\"type\":\"suite_finished\",\"suite\":\"math\",\"outcome\":{\"kind\":\"passed\"}}"
}

pub fn suite_failure_is_encoded_test() {
  assert encode.encode(SuiteFinished(
      "math",
      Failed([EqualityMismatch("a", "b", None, None)]),
    ))
    == "{\"type\":\"suite_finished\",\"suite\":\"math\",\"outcome\":{\"kind\":\"failed\",\"failures\":[{\"kind\":\"equality_mismatch\",\"expected\":\"a\",\"actual\":\"b\",\"diff\":null,\"location\":null}]}}"
}

pub fn run_finished_summary_is_encoded_test() {
  assert encode.encode(RunFinished(7, Summary(2, 1, 1, 42)))
    == "{\"type\":\"run_finished\",\"run_id\":7,\"summary\":{\"passed\":2,\"failed\":1,\"skipped\":1,\"duration_ms\":42}}"
}
