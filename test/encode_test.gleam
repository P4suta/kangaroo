import gleam/option.{None, Some}
import kangaroo/encode
import kangaroo/event.{
  CaseFinished, CaseStarted, RunFinished, RunStarted, SuiteFinished,
  SuiteStarted,
}
import kangaroo/expect.{expect, to_equal}
import kangaroo/failure.{EqualityMismatch, Failed, Passed, Skipped}
import kangaroo/location.{Location}
import kangaroo/report.{Summary}
import kangaroo/suite.{it, suite}

pub fn suites() {
  [
    suite("encode", [
      it("encodes run started", fn() {
        expect(encode.encode(RunStarted(7, 3)))
        |> to_equal("{\"type\":\"run_started\",\"run_id\":7,\"case_count\":3}")
      }),
      it("encodes case started", fn() {
        expect(encode.encode(CaseStarted("math", "adds")))
        |> to_equal(
          "{\"type\":\"case_started\",\"suite\":\"math\",\"case\":\"adds\"}",
        )
      }),
      it("encodes a passed case", fn() {
        expect(encode.encode(CaseFinished("math", "adds", Passed, 5)))
        |> to_equal(
          "{\"type\":\"case_finished\",\"suite\":\"math\",\"case\":\"adds\",\"outcome\":{\"kind\":\"passed\"},\"duration_ms\":5}",
        )
      }),
      it("encodes a skipped case", fn() {
        expect(encode.encode(CaseFinished("math", "skips", Skipped, 0)))
        |> to_equal(
          "{\"type\":\"case_finished\",\"suite\":\"math\",\"case\":\"skips\",\"outcome\":{\"kind\":\"skipped\"},\"duration_ms\":0}",
        )
      }),
      it("encodes a failed case with failures", fn() {
        expect(
          encode.encode(CaseFinished(
            "math",
            "adds",
            Failed([EqualityMismatch("2", "3", None, None)]),
            5,
          )),
        )
        |> to_equal(
          "{\"type\":\"case_finished\",\"suite\":\"math\",\"case\":\"adds\",\"outcome\":{\"kind\":\"failed\",\"failures\":[{\"kind\":\"equality_mismatch\",\"expected\":\"2\",\"actual\":\"3\",\"diff\":null,\"location\":null}]},\"duration_ms\":5}",
        )
      }),
      it("encodes a failure location", fn() {
        let location = Some(Location("test/foo_test.gleam", 42, None))
        expect(
          encode.encode(CaseFinished(
            "math",
            "adds",
            Failed([EqualityMismatch("2", "3", None, location)]),
            5,
          )),
        )
        |> to_equal(
          "{\"type\":\"case_finished\",\"suite\":\"math\",\"case\":\"adds\",\"outcome\":{\"kind\":\"failed\",\"failures\":[{\"kind\":\"equality_mismatch\",\"expected\":\"2\",\"actual\":\"3\",\"diff\":null,\"location\":{\"file\":\"test/foo_test.gleam\",\"line\":42,\"column\":null}}]},\"duration_ms\":5}",
        )
      }),
      it("encodes a location column", fn() {
        let location = Some(Location("test/foo_test.gleam", 42, Some(9)))
        expect(
          encode.encode(CaseFinished(
            "math",
            "adds",
            Failed([EqualityMismatch("2", "3", None, location)]),
            5,
          )),
        )
        |> to_equal(
          "{\"type\":\"case_finished\",\"suite\":\"math\",\"case\":\"adds\",\"outcome\":{\"kind\":\"failed\",\"failures\":[{\"kind\":\"equality_mismatch\",\"expected\":\"2\",\"actual\":\"3\",\"diff\":null,\"location\":{\"file\":\"test/foo_test.gleam\",\"line\":42,\"column\":9}}]},\"duration_ms\":5}",
        )
      }),
      it("encodes suite events", fn() {
        expect(encode.encode(SuiteStarted("math")))
        |> to_equal("{\"type\":\"suite_started\",\"suite\":\"math\"}")
        expect(encode.encode(SuiteFinished("math", Passed)))
        |> to_equal(
          "{\"type\":\"suite_finished\",\"suite\":\"math\",\"outcome\":{\"kind\":\"passed\"}}",
        )
      }),
      it("encodes a suite failure", fn() {
        expect(
          encode.encode(SuiteFinished(
            "math",
            Failed([EqualityMismatch("a", "b", None, None)]),
          )),
        )
        |> to_equal(
          "{\"type\":\"suite_finished\",\"suite\":\"math\",\"outcome\":{\"kind\":\"failed\",\"failures\":[{\"kind\":\"equality_mismatch\",\"expected\":\"a\",\"actual\":\"b\",\"diff\":null,\"location\":null}]}}",
        )
      }),
      it("encodes run finished with summary", fn() {
        expect(encode.encode(RunFinished(7, Summary(2, 1, 1, 42))))
        |> to_equal(
          "{\"type\":\"run_finished\",\"run_id\":7,\"summary\":{\"passed\":2,\"failed\":1,\"skipped\":1,\"duration_ms\":42}}",
        )
      }),
    ]),
  ]
}
