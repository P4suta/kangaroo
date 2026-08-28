import gleam/list
import gleam/string
import gleam/option.{None, Some, type Option}
import kangaroo/context
import kangaroo/diff
import kangaroo/failure.{AssertionFailed, EqualityMismatch}
import kangaroo/isolate
import kangaroo/print

/// The value being asserted on, created by [`expect`](#expect).
///
/// Matchers are methods on this type that record a failure through the
/// per-case test context when the assertion does not hold.
pub type Expectation(a) {
  Expectation(actual: a)
}

pub fn expect(actual: a) -> Expectation(a) {
  Expectation(actual)
}

/// Asserts that the actual value equals the expected one.
///
/// On failure a line-oriented diff of the printed representations is
/// attached, when the printed forms span multiple lines.
pub fn to_equal(expectation: Expectation(a), expected: a) -> Nil {
  case expectation.actual == expected {
    True -> Nil
    False -> {
      let expected_text = print.to_string(expected)
      let actual_text = print.to_string(expectation.actual)
      context.record(EqualityMismatch(
        expected: expected_text,
        actual: actual_text,
        diff: diff.diff_lines(expected_text, actual_text),
      ))
    }
  }
}

/// Asserts that the value is `True`.
pub fn to_be_true(expectation: Expectation(Bool)) -> Nil {
  case expectation.actual {
    True -> Nil
    False -> context.record(AssertionFailed("expected True"))
  }
}

/// Asserts that the value is `False`.
pub fn to_be_false(expectation: Expectation(Bool)) -> Nil {
  case expectation.actual {
    False -> Nil
    True -> context.record(AssertionFailed("expected False"))
  }
}

/// Asserts that the value is `None`.
pub fn to_be_none(expectation: Expectation(Option(a))) -> Nil {
  case expectation.actual {
    None -> Nil
    Some(_) -> context.record(AssertionFailed("expected None"))
  }
}

/// Asserts that the value is `Some`.
pub fn to_be_some(expectation: Expectation(Option(a))) -> Nil {
  case expectation.actual {
    Some(_) -> Nil
    None -> context.record(AssertionFailed("expected Some"))
  }
}

/// Asserts that the value is the empty list.
pub fn to_be_empty(expectation: Expectation(List(a))) -> Nil {
  case expectation.actual {
    [] -> Nil
    _ -> context.record(AssertionFailed("expected an empty list"))
  }
}

/// Asserts that the list contains the given element.
pub fn to_contain(expectation: Expectation(List(a)), element: a) -> Nil {
  case list.contains(expectation.actual, element) {
    True -> Nil
    False ->
      context.record(AssertionFailed(
        "expected list to contain " <> string.inspect(element),
      ))
  }
}

/// Asserts that the string contains the given substring.
pub fn to_contain_text(
  expectation: Expectation(String),
  substring: String,
) -> Nil {
  case string.contains(expectation.actual, substring) {
    True -> Nil
    False ->
      context.record(AssertionFailed(
        "expected "
        <> string.inspect(expectation.actual)
        <> " to contain "
        <> string.inspect(substring),
      ))
  }
}

/// Asserts that the function raises an error when called.
pub fn to_raise(expectation: Expectation(fn() -> a)) -> Nil {
  case isolate.isolate(expectation.actual) {
    isolate.Crashed(_) -> Nil
    isolate.Completed(_) ->
      context.record(AssertionFailed("expected the function to raise an error"))
  }
}
