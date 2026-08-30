import gleam/list
import gleam/option.{None, Some}
import kangaroo/encode
import kangaroo/event.{
  type Event, CaseFinished, CaseOutput, CaseStarted, RunFinished, RunStarted,
  SuiteFinished, SuiteStarted,
}
import kangaroo/failure.{
  AssertionFailed, EqualityMismatch, Failed, Flaky, Passed, SkippedWithReason,
  UnexpectedError,
}
import kangaroo/location.{Location}
import kangaroo/report.{Summary}

pub fn event_codec_round_trips_every_shape_test() {
  let location = Some(Location("test/math.gleam", 7, Some(3)))
  let events: List(Event) = [
    RunStarted(42, 2),
    SuiteStarted("math"),
    CaseStarted("math", "test/math.gleam::addition_test"),
    CaseOutput(
      "math",
      "test/math.gleam::addition_test",
      "stdout\n",
      "stderr\n",
      Failed([EqualityMismatch("2", "1", Some("-1\n+2"), location)]),
    ),
    CaseFinished(
      "math",
      "test/math.gleam::addition_test",
      Flaky([AssertionFailed("not equal", location)], 2),
      9,
    ),
    CaseFinished(
      "math",
      "test/math.gleam::windows_test",
      SkippedWithReason("windows only"),
      0,
    ),
    SuiteFinished("math", Failed([UnexpectedError("panic", "boom", None)])),
    SuiteFinished("other", Passed),
    RunFinished(42, Summary(0, 2, 1, 12)),
  ]

  events
  |> list.each(fn(event) {
    assert encode.decode(encode.encode(event)) == Ok(event)
  })
}

pub fn event_codec_rejects_non_event_ndjson_test() {
  assert encode.decode("{\"type\":\"compile_started\"}")
    == Error("invalid kangaroo event")
  assert encode.decode("not json") == Error("invalid kangaroo event")
}

pub fn event_codec_rejects_values_outside_the_protocol_schema_test() {
  let invalid = [
    "{\"type\":\"run_started\",\"run_id\":1,\"case_count\":-1}",
    "{\"type\":\"run_started\",\"run_id\":1,\"case_count\":1,\"extra\":true}",
    "{\"type\":\"case_finished\",\"suite\":\"math\",\"case\":\"case\",\"outcome\":{\"kind\":\"passed\"},\"duration_ms\":-1}",
    "{\"type\":\"case_finished\",\"suite\":\"math\",\"case\":\"case\",\"outcome\":{\"kind\":\"flaky\",\"attempts\":1,\"failures\":[]},\"duration_ms\":0}",
    "{\"type\":\"case_finished\",\"suite\":\"math\",\"case\":\"case\",\"outcome\":{\"kind\":\"skipped\",\"reason\":null},\"duration_ms\":0}",
    "{\"type\":\"case_finished\",\"suite\":\"math\",\"case\":\"case\",\"outcome\":{\"kind\":\"passed\",\"extra\":true},\"duration_ms\":0}",
    "{\"type\":\"case_finished\",\"suite\":\"math\",\"case\":\"case\",\"outcome\":{\"kind\":\"failed\",\"failures\":[{\"kind\":\"assertion_failed\",\"message\":\"bad\",\"location\":null,\"extra\":true}]},\"duration_ms\":0}",
    "{\"type\":\"run_finished\",\"run_id\":1,\"summary\":{\"passed\":-1,\"failed\":0,\"skipped\":0,\"duration_ms\":0}}",
    "{\"type\":\"run_finished\",\"run_id\":1,\"summary\":{\"passed\":1,\"failed\":0,\"skipped\":0,\"duration_ms\":0,\"extra\":true}}",
    "{\"type\":\"case_finished\",\"suite\":\"math\",\"case\":\"case\",\"outcome\":{\"kind\":\"failed\",\"failures\":[{\"kind\":\"assertion_failed\",\"message\":\"bad\",\"location\":{\"file\":\"test/math.gleam\",\"line\":0,\"column\":null}}]},\"duration_ms\":0}",
    "{\"type\":\"case_finished\",\"suite\":\"math\",\"case\":\"case\",\"outcome\":{\"kind\":\"failed\",\"failures\":[{\"kind\":\"assertion_failed\",\"message\":\"bad\",\"location\":{\"file\":\"test/math.gleam\",\"line\":1,\"column\":null,\"extra\":true}}]},\"duration_ms\":0}",
  ]
  assert list.all(invalid, fn(source) {
    encode.decode(source) == Error("invalid kangaroo event")
  })
}
