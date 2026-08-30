import kangaroo/failure.{Counts, Failed, Passed, Skipped}
import kangaroo/report.{CaseResult, has_failures, summarize_counts, summary}

pub fn report_starts_empty_test() {
  assert report.case_count(report.empty()) == 0
}

pub fn report_summarises_results_test() {
  let report =
    report.empty()
    |> report.append(CaseResult("s", "passes", Passed, 1))
    |> report.append(CaseResult("s", "fails", Failed([]), 2))
    |> report.append(CaseResult("s", "skips", Skipped, 0))

  let summary = summary(report, 10)
  assert summary.passed == 1
  assert summary.failed == 1
  assert summary.skipped == 1
  assert summary.duration_ms == 10
}

pub fn report_detects_failures_test() {
  let report =
    report.empty()
    |> report.append(CaseResult("s", "a", Passed, 1))
    |> report.append(CaseResult("s", "b", Failed([]), 1))
  assert has_failures(report)
}

pub fn report_without_failures_is_clean_test() {
  let report =
    report.empty()
    |> report.append(CaseResult("s", "a", Passed, 1))
    |> report.append(CaseResult("s", "b", Skipped, 0))
  assert !has_failures(report)
}

pub fn report_rolls_up_counts_test() {
  let summary = summarize_counts(Counts(3, 2, 1), 42)
  assert summary.passed == 3
  assert summary.failed == 2
  assert summary.skipped == 1
  assert summary.duration_ms == 42
}
