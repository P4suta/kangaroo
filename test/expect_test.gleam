import gleam/option.{None, Some}
import kangaroo/event.{type Event}
import kangaroo/expect.{
  expect, to_be_empty, to_be_false, to_be_none, to_be_some, to_be_true,
  to_contain, to_contain_text, to_equal, to_raise,
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
          EqualityMismatch(expected, actual, diff) -> {
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
          EqualityMismatch(_, _, Some(diff)) ->
            expect(diff) |> to_equal("- c\n+ b")
          _ -> panic as "expected a diff"
        }
      }),
      it("passes when to_be_true holds", fn() {
        let outcome = outcome_of(fn() { expect(True) |> to_be_true() })
        expect(outcome) |> to_equal(Passed)
      }),
      it("fails when to_be_true does not hold", fn() {
        let outcome = outcome_of(fn() { expect(False) |> to_be_true() })
        expect(outcome) |> to_equal(Failed([AssertionFailed("expected True")]))
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
        expect(outcome)
        |> to_equal(Failed([AssertionFailed("expected list to contain 3")]))
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
        expect(outcome)
        |> to_equal(
          Failed([AssertionFailed("expected the function to raise an error")]),
        )
      }),
    ]),
  ]
}
