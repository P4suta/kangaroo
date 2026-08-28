import kangaroo/expect.{expect, to_be_false, to_be_true, to_equal}
import kangaroo/failure.{Counts, Failed, Passed, Skipped}
import kangaroo/report.{CaseResult, has_failures, summarize_counts, summary}
import kangaroo/suite.{it, suite}

pub fn suites() {
  [
    suite("report", [
      it("starts empty", fn() {
        let r = report.empty()
        expect(report.case_count(r)) |> to_equal(0)
      }),
      it("summarises results", fn() {
        let r =
          report.empty()
          |> report.append(CaseResult("s", "passes", Passed, 1))
          |> report.append(CaseResult("s", "fails", Failed([]), 2))
          |> report.append(CaseResult("s", "skips", Skipped, 0))

        let s = summary(r, 10)
        expect(s.passed) |> to_equal(1)
        expect(s.failed) |> to_equal(1)
        expect(s.skipped) |> to_equal(1)
        expect(s.duration_ms) |> to_equal(10)
      }),
      it("detects failures", fn() {
        let r =
          report.empty()
          |> report.append(CaseResult("s", "a", Passed, 1))
          |> report.append(CaseResult("s", "b", Failed([]), 1))
        expect(has_failures(r)) |> to_be_true()
      }),
      it("is clean when nothing failed", fn() {
        let r =
          report.empty()
          |> report.append(CaseResult("s", "a", Passed, 1))
          |> report.append(CaseResult("s", "b", Skipped, 0))
        expect(has_failures(r)) |> to_be_false()
      }),
      it("rolls up counts", fn() {
        let s = summarize_counts(Counts(3, 2, 1), 42)
        expect(s.passed) |> to_equal(3)
        expect(s.failed) |> to_equal(2)
        expect(s.skipped) |> to_equal(1)
        expect(s.duration_ms) |> to_equal(42)
      }),
    ]),
  ]
}
