import gleam/dict
import gleam/option.{None, Some}
import gleam/string
import kangaroo/event.{type Event}
import kangaroo/expect.{
  expect, to_be_close_to, to_be_empty, to_be_false, to_be_greater_than,
  to_be_less_than, to_be_none, to_be_some, to_be_true, to_contain,
  to_contain_key, to_contain_text, to_end_with, to_equal, to_have_length,
  to_raise, to_raise_containing, to_start_with,
}
import kangaroo/failure.{
  type Failure, type Outcome, AssertionFailed, EqualityMismatch, Failed, Passed,
}
import kangaroo/runner
import kangaroo/suite.{it, suite}

fn outcome_of(body: fn() -> Nil) -> Outcome {
  let r = runner.run([suite("t", [it("t", body)])], fn(_event: Event) { Nil })
  case r.cases {
    [first] -> first.outcome
    _ -> panic as "expected one result"
  }
}

fn failure_of(outcome: Outcome) -> Failure {
  case outcome {
    Failed([failure]) -> failure
    _ -> panic as "expected exactly one failure"
  }
}

pub fn suites() {
  [
    suite("matchers", [
      it("passes when to_equal matches", fn() {
        let outcome = outcome_of(fn() { expect(1 + 1) |> to_equal(2) })
        expect(outcome) |> to_equal(Passed)
      }),
      it("records an equality mismatch with printed values", fn() {
        let outcome = outcome_of(fn() { expect(1 + 1) |> to_equal(3) })
        case failure_of(outcome) {
          EqualityMismatch(expected, actual, diff, _) -> {
            expect(expected) |> to_equal("3")
            expect(actual) |> to_equal("2")
            expect(diff) |> to_equal(None)
          }
          _ -> panic as "expected an equality mismatch"
        }
      }),
      it("attaches a line diff for multi-line values", fn() {
        let outcome = outcome_of(fn() { expect("a\nb") |> to_equal("a\nc") })
        case failure_of(outcome) {
          EqualityMismatch(_, _, Some(diff), _) ->
            expect(diff) |> to_equal("- c\n+ b")
          _ -> panic as "expected a diff"
        }
      }),
      it("attaches a location to matcher failures", fn() {
        let outcome = outcome_of(fn() { expect(False) |> to_be_true() })
        case failure_of(outcome) {
          AssertionFailed(_, Some(location)) -> {
            expect(location.line > 0) |> to_be_true()
            expect(location.file |> string.contains("_test")) |> to_be_true()
          }
          _ -> panic as "expected an assertion failure with location"
        }
      }),
      it("passes when to_be_true holds", fn() {
        let outcome = outcome_of(fn() { expect(True) |> to_be_true() })
        expect(outcome) |> to_equal(Passed)
      }),
      it("fails when to_be_true does not hold", fn() {
        let outcome = outcome_of(fn() { expect(False) |> to_be_true() })
        case failure_of(outcome) {
          AssertionFailed(message, _) -> expect(message) |> to_equal("expected True")
          _ -> panic as "expected an assertion failure"
        }
      }),
      it("passes when to_be_false holds", fn() {
        let outcome = outcome_of(fn() { expect(False) |> to_be_false() })
        expect(outcome) |> to_equal(Passed)
      }),
      it("passes when to_be_none holds", fn() {
        let outcome = outcome_of(fn() { expect(None) |> to_be_none() })
        expect(outcome) |> to_equal(Passed)
      }),
      it("passes when to_be_some holds", fn() {
        let outcome = outcome_of(fn() { expect(Some(1)) |> to_be_some() })
        expect(outcome) |> to_equal(Passed)
      }),
      it("passes when to_be_empty holds", fn() {
        let outcome = outcome_of(fn() { expect([]) |> to_be_empty() })
        expect(outcome) |> to_equal(Passed)
      }),
      it("passes when to_contain holds", fn() {
        let outcome = outcome_of(fn() { expect([1, 2]) |> to_contain(2) })
        expect(outcome) |> to_equal(Passed)
      }),
      it("fails when to_contain does not hold", fn() {
        let outcome = outcome_of(fn() { expect([1, 2]) |> to_contain(3) })
        case failure_of(outcome) {
          AssertionFailed(message, _) ->
            expect(message) |> to_equal("expected list to contain 3")
          _ -> panic as "expected an assertion failure"
        }
      }),
      it("passes when to_contain_text holds", fn() {
        let outcome =
          outcome_of(fn() { expect("hello world") |> to_contain_text("world") })
        expect(outcome) |> to_equal(Passed)
      }),
      it("passes when to_raise holds", fn() {
        let outcome =
          outcome_of(fn() { expect(fn() { panic as "boom" }) |> to_raise() })
        expect(outcome) |> to_equal(Passed)
      }),
      it("fails when to_raise does not hold", fn() {
        let outcome = outcome_of(fn() { expect(fn() { Nil }) |> to_raise() })
        case failure_of(outcome) {
          AssertionFailed(message, _) ->
            expect(message)
            |> to_equal("expected the function to raise an error")
          _ -> panic as "expected an assertion failure"
        }
      }),
      it("passes when to_be_close_to holds", fn() {
        let outcome =
          outcome_of(fn() { expect(1.5) |> to_be_close_to(1.6, 0.2) })
        expect(outcome) |> to_equal(Passed)
      }),
      it("fails when to_be_close_to does not hold", fn() {
        let outcome =
          outcome_of(fn() { expect(1.0) |> to_be_close_to(2.0, 0.1) })
        case failure_of(outcome) {
          AssertionFailed(message, _) ->
            expect(message) |> to_equal("expected 1.0 to be close to 2.0")
          _ -> panic as "expected an assertion failure"
        }
      }),
      it("passes when to_be_less_than holds", fn() {
        let outcome = outcome_of(fn() { expect(1) |> to_be_less_than(2) })
        expect(outcome) |> to_equal(Passed)
      }),
      it("fails when to_be_less_than does not hold", fn() {
        let outcome = outcome_of(fn() { expect(2) |> to_be_less_than(2) })
        case failure_of(outcome) {
          AssertionFailed(message, _) ->
            expect(message) |> to_equal("expected 2 to be less than 2")
          _ -> panic as "expected an assertion failure"
        }
      }),
      it("passes when to_be_greater_than holds", fn() {
        let outcome = outcome_of(fn() { expect(2) |> to_be_greater_than(1) })
        expect(outcome) |> to_equal(Passed)
      }),
      it("fails when to_be_greater_than does not hold", fn() {
        let outcome = outcome_of(fn() { expect(1) |> to_be_greater_than(2) })
        case failure_of(outcome) {
          AssertionFailed(message, _) ->
            expect(message) |> to_equal("expected 1 to be greater than 2")
          _ -> panic as "expected an assertion failure"
        }
      }),
      it("passes when to_have_length holds", fn() {
        let outcome = outcome_of(fn() { expect([1, 2, 3]) |> to_have_length(3) })
        expect(outcome) |> to_equal(Passed)
      }),
      it("fails when to_have_length does not hold", fn() {
        let outcome = outcome_of(fn() { expect([1, 2]) |> to_have_length(3) })
        case failure_of(outcome) {
          AssertionFailed(message, _) ->
            expect(message) |> to_equal("expected a list of length 3, got 2")
          _ -> panic as "expected an assertion failure"
        }
      }),
      it("passes when to_contain_key holds", fn() {
        let outcome =
          outcome_of(fn() {
            expect(dict.from_list([#("a", 1)])) |> to_contain_key("a")
          })
        expect(outcome) |> to_equal(Passed)
      }),
      it("fails when to_contain_key does not hold", fn() {
        let outcome =
          outcome_of(fn() {
            expect(dict.from_list([#("a", 1)])) |> to_contain_key("b")
          })
        case failure_of(outcome) {
          AssertionFailed(message, _) ->
            expect(message) |> to_equal("expected the dictionary to contain key \"b\"")
          _ -> panic as "expected an assertion failure"
        }
      }),
      it("passes when to_start_with holds", fn() {
        let outcome = outcome_of(fn() { expect("hello") |> to_start_with("he") })
        expect(outcome) |> to_equal(Passed)
      }),
      it("fails when to_start_with does not hold", fn() {
        let outcome = outcome_of(fn() { expect("hello") |> to_start_with("lo") })
        case failure_of(outcome) {
          AssertionFailed(message, _) ->
            expect(message) |> to_equal("expected \"hello\" to start with \"lo\"")
          _ -> panic as "expected an assertion failure"
        }
      }),
      it("passes when to_end_with holds", fn() {
        let outcome = outcome_of(fn() { expect("hello") |> to_end_with("lo") })
        expect(outcome) |> to_equal(Passed)
      }),
      it("fails when to_end_with does not hold", fn() {
        let outcome = outcome_of(fn() { expect("hello") |> to_end_with("he") })
        case failure_of(outcome) {
          AssertionFailed(message, _) ->
            expect(message) |> to_equal("expected \"hello\" to end with \"he\"")
          _ -> panic as "expected an assertion failure"
        }
      }),
      it("passes when to_raise_containing holds", fn() {
        let outcome =
          outcome_of(fn() {
            expect(fn() { panic as "boom happened" })
            |> to_raise_containing("boom")
          })
        expect(outcome) |> to_equal(Passed)
      }),
      it("fails when to_raise_containing does not hold", fn() {
        let outcome =
          outcome_of(fn() {
            expect(fn() { panic as "other message" })
            |> to_raise_containing("boom")
          })
        case failure_of(outcome) {
          AssertionFailed(message, _) ->
            expect(message)
            |> to_equal("expected the error message to contain \"boom\"")
          _ -> panic as "expected an assertion failure"
        }
      }),
    ]),
  ]
}
