import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/string
import kangaroo/context
import kangaroo/diff
import kangaroo/failure.{type Failure, AssertionFailed, EqualityMismatch}
import kangaroo/isolate
import kangaroo/location.{type Location}
import kangaroo/print

/// The value being asserted on, created by [`expect`](#expect).
///
/// Matchers are methods on this type that record a failure through the
/// per-case test context when the assertion does not hold. The source
/// location of the [`expect`](#expect) call is captured eagerly: matchers
/// are often the last call in a test body, so a stack walk at failure time
/// would already have lost the caller's frame.
pub type Expectation(a) {
  Expectation(actual: a, location: Option(Location))
}

pub fn expect(actual: a) -> Expectation(a) {
  Expectation(actual, location.capture())
}

/// Records a failure through the per-case context, attaching the source
/// location of the original [`expect`](#expect) call when known.
fn fail(recorded: Failure, at: Option(Location)) -> Nil {
  let recorded = case at {
    None -> recorded
    Some(captured) -> failure.attach(recorded, captured)
  }
  context.record(recorded)
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
      fail(
        EqualityMismatch(
          expected: expected_text,
          actual: actual_text,
          diff: diff.diff_lines(expected_text, actual_text),
          location: None,
        ),
        expectation.location,
      )
    }
  }
}

/// Asserts that the value is `True`.
pub fn to_be_true(expectation: Expectation(Bool)) -> Nil {
  case expectation.actual {
    True -> Nil
    False -> fail(AssertionFailed("expected True", None), expectation.location)
  }
}

/// Asserts that the value is `False`.
pub fn to_be_false(expectation: Expectation(Bool)) -> Nil {
  case expectation.actual {
    False -> Nil
    True -> fail(AssertionFailed("expected False", None), expectation.location)
  }
}

/// Asserts that the value is `None`.
pub fn to_be_none(expectation: Expectation(Option(a))) -> Nil {
  case expectation.actual {
    None -> Nil
    Some(_) ->
      fail(AssertionFailed("expected None", None), expectation.location)
  }
}

/// Asserts that the value is `Some`.
pub fn to_be_some(expectation: Expectation(Option(a))) -> Nil {
  case expectation.actual {
    Some(_) -> Nil
    None -> fail(AssertionFailed("expected Some", None), expectation.location)
  }
}

/// Asserts that the value is the empty list.
pub fn to_be_empty(expectation: Expectation(List(a))) -> Nil {
  case expectation.actual {
    [] -> Nil
    _ ->
      fail(
        AssertionFailed("expected an empty list", None),
        expectation.location,
      )
  }
}

/// Asserts that the list contains the given element.
pub fn to_contain(expectation: Expectation(List(a)), element: a) -> Nil {
  case list.contains(expectation.actual, element) {
    True -> Nil
    False ->
      fail(
        AssertionFailed(
          "expected list to contain " <> string.inspect(element),
          None,
        ),
        expectation.location,
      )
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
      fail(
        AssertionFailed(
          "expected "
            <> string.inspect(expectation.actual)
            <> " to contain "
            <> string.inspect(substring),
          None,
        ),
        expectation.location,
      )
  }
}

/// Asserts that the function raises an error when called.
pub fn to_raise(expectation: Expectation(fn() -> a)) -> Nil {
  case isolate.isolate(expectation.actual, None) {
    isolate.Crashed(_) -> Nil
    isolate.Completed(_) ->
      fail(
        AssertionFailed("expected the function to raise an error", None),
        expectation.location,
      )
  }
}

/// Asserts that a float is within `tolerance` of the expected value.
pub fn to_be_close_to(
  expectation: Expectation(Float),
  expected: Float,
  tolerance: Float,
) -> Nil {
  let distance = float.absolute_value(expectation.actual -. expected)
  case float.compare(distance, tolerance) {
    order.Gt -> {
      fail(
        AssertionFailed(
          "expected "
            <> float.to_string(expectation.actual)
            <> " to be close to "
            <> float.to_string(expected),
          None,
        ),
        expectation.location,
      )
    }
    _ -> Nil
  }
}

/// Asserts that an integer is strictly less than the expected value.
pub fn to_be_less_than(expectation: Expectation(Int), expected: Int) -> Nil {
  case expectation.actual < expected {
    True -> Nil
    False ->
      fail(
        AssertionFailed(
          "expected "
            <> int.to_string(expectation.actual)
            <> " to be less than "
            <> int.to_string(expected),
          None,
        ),
        expectation.location,
      )
  }
}

/// Asserts that an integer is strictly greater than the expected value.
pub fn to_be_greater_than(expectation: Expectation(Int), expected: Int) -> Nil {
  case expectation.actual > expected {
    True -> Nil
    False ->
      fail(
        AssertionFailed(
          "expected "
            <> int.to_string(expectation.actual)
            <> " to be greater than "
            <> int.to_string(expected),
          None,
        ),
        expectation.location,
      )
  }
}

/// Asserts that the list has the given length.
pub fn to_have_length(expectation: Expectation(List(a)), length: Int) -> Nil {
  let actual = list.length(expectation.actual)
  case actual == length {
    True -> Nil
    False ->
      fail(
        AssertionFailed(
          "expected a list of length "
            <> int.to_string(length)
            <> ", got "
            <> int.to_string(actual),
          None,
        ),
        expectation.location,
      )
  }
}

/// Asserts that the dictionary contains the given key.
pub fn to_contain_key(expectation: Expectation(Dict(k, v)), key: k) -> Nil {
  case dict.has_key(expectation.actual, key) {
    True -> Nil
    False ->
      fail(
        AssertionFailed(
          "expected the dictionary to contain key " <> string.inspect(key),
          None,
        ),
        expectation.location,
      )
  }
}

/// Asserts that the string starts with the given prefix.
pub fn to_start_with(expectation: Expectation(String), prefix: String) -> Nil {
  case string.starts_with(expectation.actual, prefix) {
    True -> Nil
    False ->
      fail(
        AssertionFailed(
          "expected "
            <> string.inspect(expectation.actual)
            <> " to start with "
            <> string.inspect(prefix),
          None,
        ),
        expectation.location,
      )
  }
}

/// Asserts that the string ends with the given suffix.
pub fn to_end_with(expectation: Expectation(String), suffix: String) -> Nil {
  case string.ends_with(expectation.actual, suffix) {
    True -> Nil
    False ->
      fail(
        AssertionFailed(
          "expected "
            <> string.inspect(expectation.actual)
            <> " to end with "
            <> string.inspect(suffix),
          None,
        ),
        expectation.location,
      )
  }
}

/// Asserts that the function raises an error whose message contains the
/// given substring.
pub fn to_raise_containing(
  expectation: Expectation(fn() -> a),
  substring: String,
) -> Nil {
  case isolate.isolate(expectation.actual, None) {
    isolate.Crashed(error) ->
      case string.contains(error.message, substring) {
        True -> Nil
        False ->
          fail(
            AssertionFailed(
              "expected the error message to contain "
                <> string.inspect(substring),
              None,
            ),
            expectation.location,
          )
      }
    isolate.Completed(_) ->
      fail(
        AssertionFailed(
          "expected the function to raise an error containing "
            <> string.inspect(substring),
          None,
        ),
        expectation.location,
      )
  }
}
