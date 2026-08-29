import gleam/list
import gleam/option.{type Option, Some}
import kangaroo/location.{type Location}

/// A failure recorded by a matcher or caused by an unexpected error while a
/// test case was running. `location` is the source position the failure
/// originates from, when it can be determined.
pub type Failure {
  /// The actual value did not equal the expected one. `diff` is a
  /// line-oriented diff of their printed representations, when useful.
  EqualityMismatch(
    expected: String,
    actual: String,
    diff: Option(String),
    location: Option(Location),
  )
  /// A boolean condition evaluated to `False`.
  AssertionFailed(message: String, location: Option(Location))
  /// The case body panicked (or timed out).
  UnexpectedError(
    name: String,
    message: String,
    location: Option(Location),
  )
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

/// Returns the failure with the given source location attached, keeping all
/// other fields unchanged.
pub fn attach(failure: Failure, location: Location) -> Failure {
  case failure {
    EqualityMismatch(expected, actual, diff, _) ->
      EqualityMismatch(expected, actual, diff, Some(location))
    AssertionFailed(message, _) -> AssertionFailed(message, Some(location))
    UnexpectedError(name, message, _) ->
      UnexpectedError(name, message, Some(location))
  }
}

pub type Counts {
  Counts(passed: Int, failed: Int, skipped: Int)
}
