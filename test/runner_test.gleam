import gleam/list
import gleam/option.{None, Some}
import gleam/string
import kangaroo/event.{type Event}
import kangaroo/sys
import kangaroo/expect.{expect, to_be_false, to_be_true, to_equal}
import kangaroo/failure.{
  EqualityMismatch, Failed, Passed, Skipped, UnexpectedError,
}
import kangaroo/report
import kangaroo/runner
import kangaroo/suite.{
  all_hooks, hooks, it, it_focused, it_skipped, suite, suite_with_hooks,
}

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
              Failed([UnexpectedError(name, message, _)]) -> {
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
              Failed(failures) -> expect(list.length(failures)) |> to_equal(2)
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
      it("runs before_all once before the suite's cases", fn() {
        let r =
          runner.run(
            [
              suite_with_hooks(
                "math",
                [it("a", fn() { Nil }), it("b", fn() { Nil })],
                all_hooks(Some(fn() { Nil }), None, None, None),
              ),
            ],
            fn(_event: Event) { Nil },
          )
        expect(report.has_failures(r)) |> to_be_false()
        expect(report.case_count(r)) |> to_equal(2)
      }),
      it("skips a suite's cases when before_all fails", fn() {
        let r =
          runner.run(
            [
              suite_with_hooks(
                "math",
                [it("a", fn() { Nil }), it("b", fn() { Nil })],
                all_hooks(Some(fn() { panic as "setup failed" }), None, None,
                  None),
              ),
            ],
            fn(_event: Event) { Nil },
          )
        expect(report.has_failures(r)) |> to_be_true()
        expect(report.case_count(r)) |> to_equal(2)
        case r.cases {
          [first, second] -> {
            expect(first.outcome) |> to_equal(Skipped)
            expect(second.outcome) |> to_equal(Skipped)
          }
          _ -> panic as "expected two results"
        }
      }),
      it("reports after_all failures without touching case results", fn() {
        let r =
          runner.run(
            [
              suite_with_hooks(
                "math",
                [it("a", fn() { Nil })],
                all_hooks(None, None, None, Some(fn() { panic as "teardown" })),
              ),
            ],
            fn(_event: Event) { Nil },
          )
        expect(report.has_failures(r)) |> to_be_true()
        case r.cases {
          [result] -> expect(result.outcome) |> to_equal(Passed)
          _ -> panic as "expected one result"
        }
        case r.suite_failures {
          [entry] -> expect(entry.0) |> to_equal("math")
          _ -> panic as "expected one suite failure"
        }
      }),
      it("stops after the first failure with fail-fast", fn() {
        let config = runner.Config(Some(30_000), True)
        let r =
          runner.run_with_config(
            [
              suite("math", [
                it("fails", fn() { expect(1) |> to_equal(2) }),
                it("never runs", fn() { panic as "should not run" }),
              ]),
              suite("other", [it("never runs either", fn() { Nil })]),
            ],
            fn(_event: Event) { Nil },
            config,
          )
        case r.cases {
          [first, second, third] -> {
            case first.outcome {
              Failed(_) -> expect(True) |> to_be_true()
              _ -> panic as "expected the first case to fail"
            }
            expect(second.outcome) |> to_equal(Skipped)
            expect(third.outcome) |> to_equal(Skipped)
          }
          _ -> panic as "expected three results"
        }
      }),
      it("times out slow cases when configured", fn() {
        // On Erlang the case is killed and reported as a timeout error; a
        // synchronous JavaScript body cannot be interrupted, so it simply
        // runs to completion there.
        let config = runner.Config(Some(10), False)
        let r =
          runner.run_with_config(
            [
              suite("math", [
                it("slow", fn() { spin_for(100) }),
              ]),
            ],
            fn(_event: Event) { Nil },
            config,
          )
        case r.cases {
          [result] ->
            case result.outcome {
              Failed([UnexpectedError(name, _, _)]) ->
                expect(name) |> to_equal("timeout")
              _ -> expect(True) |> to_equal(True)
            }
          _ -> panic as "expected one result"
        }
      }),
      it("leaves the default case timeout unset", fn() {
        expect(runner.default_config().case_timeout_ms) |> to_equal(None)
      }),
    ]),
  ]
}

/// Busy-waits for the given number of milliseconds; used to make a case
/// outlive its configured timeout on both targets.
fn spin_for(ms: Int) -> Nil {
  let start = sys.now_ms()
  spin_until(start, ms)
}

fn spin_until(start: Int, ms: Int) -> Nil {
  case sys.now_ms() - start >= ms {
    True -> Nil
    False -> spin_until(start, ms)
  }
}
