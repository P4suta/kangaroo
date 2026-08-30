import gleam/list
import kangaroo/failure.{type Counts, type Outcome, Failed, Flaky, count}

/// The result of a single test case run.
pub type CaseResult {
  CaseResult(
    suite: String,
    case_name: String,
    outcome: Outcome,
    duration_ms: Int,
  )
}

/// The full result of running the selected tests.
pub type Report {
  Report(cases: List(CaseResult))
}

/// A roll-up of how many cases passed, failed and were skipped, plus the
/// total wall-clock duration of the run in milliseconds.
pub type Summary {
  Summary(passed: Int, failed: Int, skipped: Int, duration_ms: Int)
}

pub fn empty() -> Report {
  Report([])
}

pub fn append(report: Report, result: CaseResult) -> Report {
  Report(list.append(report.cases, [result]))
}

pub fn case_count(report: Report) -> Int {
  list.length(report.cases)
}

pub fn has_failures(report: Report) -> Bool {
  list.any(report.cases, fn(result) {
    case result.outcome {
      Failed(_) -> True
      Flaky(_, _) -> True
      _ -> False
    }
  })
}

pub fn summary(report: Report, duration_ms: Int) -> Summary {
  let counts = count(list.map(report.cases, fn(result) { result.outcome }))
  summarize_counts(counts, duration_ms)
}

pub fn summarize_counts(counts: Counts, duration_ms: Int) -> Summary {
  Summary(
    passed: counts.passed,
    failed: counts.failed,
    skipped: counts.skipped,
    duration_ms: duration_ms,
  )
}
