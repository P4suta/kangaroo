import gleam/list
import kangaroo/failure.{
  type Counts, type Failure, type Outcome, Counts, Failed, count,
}

/// The result of a single test case run.
pub type CaseResult {
  CaseResult(
    suite: String,
    case_name: String,
    outcome: Outcome,
    duration_ms: Int,
  )
}

/// The full result of running a set of suites: the per-case results plus
/// the failures of any suite-level hooks (`before_all` / `after_all`).
pub type Report {
  Report(
    cases: List(CaseResult),
    suite_failures: List(#(String, List(Failure))),
  )
}

/// A roll-up of how many cases passed, failed and were skipped, plus the
/// total wall-clock duration of the run in milliseconds. Suite-level hook
/// failures count towards `failed`.
pub type Summary {
  Summary(passed: Int, failed: Int, skipped: Int, duration_ms: Int)
}

pub fn empty() -> Report {
  Report([], [])
}

pub fn append(report: Report, result: CaseResult) -> Report {
  Report(list.append(report.cases, [result]), report.suite_failures)
}

pub fn case_count(report: Report) -> Int {
  list.length(report.cases)
}

pub fn has_failures(report: Report) -> Bool {
  list.any(report.cases, fn(result) {
    case result.outcome {
      Failed(_) -> True
      _ -> False
    }
  })
  || list.any(report.suite_failures, fn(entry) { entry.1 != [] })
}

pub fn summary(report: Report, duration_ms: Int) -> Summary {
  let counts = count(list.map(report.cases, fn(result) { result.outcome }))
  let suite_failed =
    list.length(
      list.filter(report.suite_failures, fn(entry) { entry.1 != [] }),
    )
  summarize_counts(
    Counts(counts.passed, counts.failed + suite_failed, counts.skipped),
    duration_ms,
  )
}

pub fn summarize_counts(counts: Counts, duration_ms: Int) -> Summary {
  Summary(
    passed: counts.passed,
    failed: counts.failed,
    skipped: counts.skipped,
    duration_ms: duration_ms,
  )
}
