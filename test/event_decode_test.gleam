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
