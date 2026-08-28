import gleam/list
import gleam/option.{None, Some}
import gleam/string
import kangaroo/event.{type Event}
import kangaroo/expect.{
  expect,
  to_be_false,
  to_be_true,
  to_equal,
}
import kangaroo/failure.{
  EqualityMismatch,
  Failed,
  Passed,
  Skipped,
  UnexpectedError,
}
import kangaroo/report
import kangaroo/runner
import kangaroo/suite.{it, it_focused, it_skipped, hooks, suite, suite_with_hooks}

pub fn suites() {
  [
    suite("runner", [
      it("reports a passing case", fn() {
        let r =
          runner.run(
            [
              suite("math", [
                it("adds", fn() { expect(1 + 1) |> to_equal(2) }),
              ]),
            ],
            fn(_event: Event) { Nil },
          )
        expect(report.has_failures(r)) |> to_be_false()
        expect(report.case_count(r)) |> to_equal(1)
      }),
      it("reports a failing case with details", fn() {
        let r =
          runner.run(
            [
              suite("math", [
                it("adds", fn() { expect(1 + 1) |> to_equal(3) }),
              ]),
            ],
            fn(_event: Event) { Nil },
          )
        expect(report.has_failures(r)) |> to_be_true()
        case r.cases {
          [result] -> {
            expect(result.case_name) |> to_equal("adds")
            case result.outcome {
              Failed([EqualityMismatch(..)]) -> expect(True) |> to_be_true()
              _ -> panic as "expected an equality mismatch"
            }
          }
          _ -> panic as "expected one result"
        }
      }),
      it("reports panicking cases as errors", fn() {
        let r =
          runner.run(
            [suite("boom", [it("explodes", fn() { panic as "kaboom" })])],
            fn(_event: Event) { Nil },
          )
        case r.cases {
          [result] ->
            case result.outcome {
              Failed([UnexpectedError(name, message)]) -> {
                expect(name) |> to_equal("panic")
                expect(string.contains(message, "kaboom")) |> to_be_true()
              }
              _ -> panic as "expected unexpected error"
            }
          _ -> panic as "expected one result"
        }
      }),
      it("collects every recorded failure", fn() {
        let r =
          runner.run(
            [
              suite("math", [
                it("checks a few things", fn() {
                  expect(1) |> to_equal(2)
                  expect(False) |> to_be_true()
                }),
              ]),
            ],
            fn(_event: Event) { Nil },
          )
        case r.cases {
          [result] ->
            case result.outcome {
              Failed(failures) ->
                expect(list.length(failures)) |> to_equal(2)
              _ -> panic as "expected failure"
            }
          _ -> panic as "expected one result"
        }
      }),
      it("counts but never runs skipped cases", fn() {
        let r =
          runner.run(
            [
              suite("math", [
                it("runs", fn() { Nil }),
                it_skipped("skips", fn() { panic as "should not run" }),
              ]),
            ],
            fn(_event: Event) { Nil },
          )
        case r.cases {
          [first, second] -> {
            expect(first.outcome) |> to_equal(Passed)
            expect(second.outcome) |> to_equal(Skipped)
          }
          _ -> panic as "expected two results"
        }
      }),
      it("runs only focused cases when present", fn() {
        let r =
          runner.run(
            [
              suite("math", [
                it("ignored", fn() { panic as "should not run" }),
                it_focused("focused", fn() { Nil }),
              ]),
            ],
            fn(_event: Event) { Nil },
          )
        expect(report.case_count(r)) |> to_equal(1)
        case r.cases {
          [result] -> expect(result.case_name) |> to_equal("focused")
          _ -> panic as "expected one result"
        }
      }),
      it("runs hooks around each case", fn() {
        let r =
          runner.run(
            [
              suite_with_hooks(
                "math",
                [it("a", fn() { Nil }), it("b", fn() { Nil })],
                hooks(Some(fn() { Nil }), Some(fn() { Nil })),
              ),
            ],
            fn(_event: Event) { Nil },
          )
        expect(report.case_count(r)) |> to_equal(2)
      }),
      it("fails a case when its before hook panics", fn() {
        let r =
          runner.run(
            [
              suite_with_hooks(
                "math",
                [it("a", fn() { Nil })],
                hooks(Some(fn() { panic as "setup failed" }), None),
              ),
            ],
            fn(_event: Event) { Nil },
          )
        expect(report.has_failures(r)) |> to_be_true()
      }),
      it("preserves suite order", fn() {
        let r =
          runner.run(
            [
              suite("first", [it("one", fn() { Nil })]),
              suite("second", [it("two", fn() { Nil })]),
            ],
            fn(_event: Event) { Nil },
          )
        case r.cases {
          [one, two] -> {
            expect(one.suite) |> to_equal("first")
            expect(two.suite) |> to_equal("second")
          }
          _ -> panic as "expected two results"
        }
      }),
    ]),
  ]
}
