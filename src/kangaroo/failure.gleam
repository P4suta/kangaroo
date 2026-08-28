import gleam/list
import gleam/option.{type Option}

/// A failure recorded by a matcher or caused by an unexpected error while a
/// test case was running.
pub type Failure {
  /// The actual value did not equal the expected one. `diff` is a
  /// line-oriented diff of their printed representations, when useful.
  EqualityMismatch(expected: String, actual: String, diff: Option(String))
  /// A boolean condition evaluated to `False`.
  AssertionFailed(message: String)
  /// The case body panicked (or timed out).
  UnexpectedError(name: String, message: String)
}

/// The outcome of a single test case.
pub type Outcome {
  Passed
  Failed(failures: List(Failure))
  Skipped
}

/// Counts a list of outcomes.
pub fn count(outcomes: List(Outcome)) -> Counts {
  list.fold(outcomes, Counts(0, 0, 0), fn(counts, outcome) {
    case outcome {
      Passed -> Counts(counts.passed + 1, counts.failed, counts.skipped)
      Failed(_) -> Counts(counts.passed, counts.failed + 1, counts.skipped)
      Skipped -> Counts(counts.passed, counts.failed, counts.skipped + 1)
    }
  })
}

pub type Counts {
  Counts(passed: Int, failed: Int, skipped: Int)
}
