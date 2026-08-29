import gleam/option.{None, Some}
import kangaroo/event.{
  CaseFinished, CaseStarted, RunFinished, RunStarted, SuiteFinished,
  SuiteStarted,
}
import kangaroo/expect.{expect, to_equal}
import kangaroo/failure.{
  AssertionFailed, EqualityMismatch, Failed, Passed, Skipped, UnexpectedError,
}
import kangaroo/location.{Location}
import kangaroo/report.{Summary}
import kangaroo/suite.{it, suite}
import kangaroo_cli/stream

pub fn suites() {
  [
    suite("stream", [
      it("parses a full run of events", fn() {
        let output =
          "{\"type\":\"run_started\",\"run_id\":1,\"case_count\":2}\n"
          <> "{\"type\":\"case_started\",\"suite\":\"math\",\"case\":\"adds\"}\n"
          <> "{\"type\":\"case_finished\",\"suite\":\"math\",\"case\":\"adds\",\"outcome\":{\"kind\":\"passed\"},\"duration_ms\":1}\n"
          <> "{\"type\":\"case_finished\",\"suite\":\"math\",\"case\":\"fails\",\"outcome\":{\"kind\":\"failed\",\"failures\":[{\"kind\":\"equality_mismatch\",\"expected\":\"2\",\"actual\":\"1\",\"diff\":null}]},\"duration_ms\":2}\n"
          <> "{\"type\":\"run_finished\",\"run_id\":1,\"summary\":{\"passed\":1,\"failed\":1,\"skipped\":0,\"duration_ms\":5}}\n"
        let events = stream.parse_events(output)
        expect(events)
        |> to_equal([
          RunStarted(1, 2),
          CaseStarted("math", "adds"),
          CaseFinished("math", "adds", Passed, 1),
          CaseFinished(
            "math",
            "fails",
            Failed([EqualityMismatch("2", "1", None, None)]),
            2,
          ),
          RunFinished(1, Summary(1, 1, 0, 5)),
        ])
      }),
      it("skips blank and malformed lines", fn() {
        let output =
          "{\"type\":\"run_started\",\"run_id\":1,\"case_count\":1}\n"
          <> "\n"
          <> "not json\n"
          <> "{\"type\":\"run_finished\",\"run_id\":1,\"summary\":{\"passed\":0,\"failed\":0,\"skipped\":0,\"duration_ms\":1}}\n"
        let events = stream.parse_events(output)
        expect(events)
        |> to_equal([RunStarted(1, 1), RunFinished(1, Summary(0, 0, 0, 1))])
      }),
      it("parses a diff inside a failure", fn() {
        let output =
          "{\"type\":\"case_finished\",\"suite\":\"s\",\"case\":\"c\",\"outcome\":{\"kind\":\"failed\",\"failures\":[{\"kind\":\"equality_mismatch\",\"expected\":\"a\\nb\",\"actual\":\"a\\nc\",\"diff\":\"- b\\n+ c\"}]},\"duration_ms\":0}\n"
        let events = stream.parse_events(output)
        expect(events)
        |> to_equal([
          CaseFinished(
            "s",
            "c",
            Failed([EqualityMismatch("a\nb", "a\nc", Some("- b\n+ c"), None)]),
            0,
          ),
        ])
      }),
      it("parses a failure location", fn() {
        let output =
          "{\"type\":\"case_finished\",\"suite\":\"s\",\"case\":\"c\",\"outcome\":{\"kind\":\"failed\",\"failures\":[{\"kind\":\"unexpected_error\",\"name\":\"panic\",\"message\":\"boom\",\"location\":{\"file\":\"test/foo_test.gleam\",\"line\":7}}]},\"duration_ms\":0}\n"
        let events = stream.parse_events(output)
        expect(events)
        |> to_equal([
          CaseFinished(
            "s",
            "c",
            Failed([UnexpectedError(
              "panic",
              "boom",
              Some(Location("test/foo_test.gleam", 7)),
            )]),
            0,
          ),
        ])
      }),
      it("parses assertion and error failures", fn() {
        let output =
          "{\"type\":\"case_finished\",\"suite\":\"s\",\"case\":\"a\",\"outcome\":{\"kind\":\"failed\",\"failures\":[{\"kind\":\"assertion_failed\",\"message\":\"expected True\"},{\"kind\":\"unexpected_error\",\"name\":\"panic\",\"message\":\"boom\"}]},\"duration_ms\":0}\n"
        let events = stream.parse_events(output)
        expect(events)
        |> to_equal([
          CaseFinished(
            "s",
            "a",
            Failed([
              AssertionFailed("expected True", None),
              UnexpectedError("panic", "boom", None),
            ]),
            0,
          ),
        ])
      }),
      it("parses suite events", fn() {
        let output =
          "{\"type\":\"suite_started\",\"suite\":\"math\"}\n"
          <> "{\"type\":\"suite_finished\",\"suite\":\"math\",\"outcome\":{\"kind\":\"passed\"}}\n"
          <> "{\"type\":\"suite_finished\",\"suite\":\"broken\",\"outcome\":{\"kind\":\"failed\",\"failures\":[{\"kind\":\"assertion_failed\",\"message\":\"boom\",\"location\":null}]}}\n"
        let events = stream.parse_events(output)
        expect(events)
        |> to_equal([
          SuiteStarted("math"),
          SuiteFinished("math", Passed),
          SuiteFinished("broken", Failed([AssertionFailed("boom", None)])),
        ])
      }),
      it("parses skipped outcomes", fn() {
        let output =
          "{\"type\":\"case_finished\",\"suite\":\"s\",\"case\":\"c\",\"outcome\":{\"kind\":\"skipped\"},\"duration_ms\":0}\n"
        let events = stream.parse_events(output)
        expect(events) |> to_equal([CaseFinished("s", "c", Skipped, 0)])
      }),
    ]),
  ]
}
