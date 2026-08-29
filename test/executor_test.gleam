import gleam/list
import gleam/option.{None, Some}
import gleam/string
import kangaroo/event.{type Event, RunFinished, RunStarted}
import kangaroo/failure.{
  EqualityMismatch, Failed, Passed, Skipped, SkippedWithReason, UnexpectedError,
}
import kangaroo/internal/event_buffer
import kangaroo/internal/executor
import kangaroo/internal/index.{type IndexedTest, IndexedTest}
import kangaroo/internal/legacy/expect.{
  expect, to_be_false, to_be_true, to_equal,
}
import kangaroo/internal/legacy/suite.{it, suite}
import kangaroo/report

fn fixture(name: String) -> IndexedTest {
  IndexedTest(
    id: "test/runtime_fixture.gleam::" <> name,
    name:,
    path: "test/runtime_fixture.gleam",
    module: "runtime_fixture",
    line: 1,
    column: 1,
    end_line: 1,
    end_column: 1,
    tags: [],
    timeout_ms: None,
    serial: False,
    skip: None,
  )
}

fn second_fixture(name: String) -> IndexedTest {
  IndexedTest(
    ..fixture(name),
    id: "test/runtime_fixture_two.gleam::" <> name,
    path: "test/runtime_fixture_two.gleam",
    module: "runtime_fixture_two",
  )
}

fn discard(_event: Event) {
  Nil
}

pub fn suites() {
  [
    suite("indexed executor", [
      it("runs indexed tests and identifies results by stable id", fn() {
        let assert Ok(result) =
          executor.run([fixture("passing_test")], discard, 30_000, False)
        expect(report.has_failures(result)) |> to_be_false()
        case result.cases {
          [case_result] -> {
            expect(case_result.case_name)
            |> to_equal("test/runtime_fixture.gleam::passing_test")
            expect(case_result.outcome) |> to_equal(Passed)
          }
          _ -> panic as "expected one result"
        }
      }),
      it("normalises native panics into the common failure model", fn() {
        let assert Ok(result) =
          executor.run([fixture("panic_fixture")], discard, 30_000, False)
        case result.cases {
          [case_result] ->
            case case_result.outcome {
              Failed([UnexpectedError(_, message, _)]) ->
                expect(string.contains(message, "fixture exploded"))
                |> to_be_true()
              _ -> panic as "expected a panic failure"
            }
          _ -> panic as "expected one result"
        }
      }),
      it("normalises standard equality asserts with both operand values", fn() {
        let assert Ok(result) =
          executor.run(
            [fixture("equality_assert_fixture")],
            discard,
            30_000,
            False,
          )
        case result.cases {
          [case_result] ->
            case case_result.outcome {
              Failed([EqualityMismatch("2", "1", _, Some(location))]) -> {
                expect(location.file) |> to_equal("test/runtime_fixture.gleam")
                expect(location.line) |> to_equal(34)
              }
              _ -> panic as "expected a structured equality mismatch"
            }
          _ -> panic as "expected one assertion result"
        }
      }),
      it("retains a useful multiline String diff from standard assert", fn() {
        let assert Ok(result) =
          executor.run(
            [fixture("string_assert_fixture")],
            discard,
            30_000,
            False,
          )
        case result.cases {
          [case_result] ->
            case case_result.outcome {
              Failed([EqualityMismatch(_, _, Some(diff), _)]) -> {
                expect(string.contains(diff, "- new")) |> to_be_true()
                expect(string.contains(diff, "+ old")) |> to_be_true()
              }
              _ -> panic as "expected a multiline assertion diff"
            }
          _ -> panic as "expected one assertion result"
        }
      }),
      it("reports static skips without resolving or invoking the export", fn() {
        let skipped =
          IndexedTest(
            ..fixture("missing_fixture"),
            skip: Some("not on this platform"),
          )
        let assert Ok(result) = executor.run([skipped], discard, 30_000, False)
        case result.cases {
          [case_result] ->
            expect(case_result.outcome)
            |> to_equal(SkippedWithReason("not on this platform"))
          _ -> panic as "expected one result"
        }
      }),
      it("treats stale or missing exports as infrastructure errors", fn() {
        expect(executor.run(
          [fixture("missing_fixture")],
          discard,
          30_000,
          False,
        ))
        |> to_equal(Error(
          "test/runtime_fixture.gleam::missing_fixture is not an exported zero-argument function",
        ))
      }),
      it("closes the scheduled event stream after resolution fails", fn() {
        event_buffer.take()
        expect(
          executor.run_scheduled(
            [fixture("missing_fixture")],
            event_buffer.append,
            30_000,
            False,
            0,
            1,
            [],
          ),
        )
        |> to_equal(Error(
          "test/runtime_fixture.gleam::missing_fixture is not an exported zero-argument function",
        ))
        let events = event_buffer.take()
        expect(
          list.count(events, fn(event) {
            case event {
              RunStarted(..) -> True
              _ -> False
            }
          }),
        )
        |> to_equal(1)
        expect(
          list.count(events, fn(event) {
            case event {
              RunFinished(..) -> True
              _ -> False
            }
          }),
        )
        |> to_equal(1)
      }),
      it("emits one deterministic run around scheduled module batches", fn() {
        event_buffer.take()
        let assert Ok(result) =
          executor.run_scheduled(
            [fixture("passing_test"), second_fixture("passing_fixture")],
            event_buffer.append,
            30_000,
            False,
            0,
            2,
            [],
          )
        expect(list.map(result.cases, fn(case_) { case_.case_name }))
        |> to_equal([
          "test/runtime_fixture.gleam::passing_test",
          "test/runtime_fixture_two.gleam::passing_fixture",
        ])
        let events = event_buffer.take()
        expect(
          list.count(events, fn(event) {
            case event {
              RunStarted(..) -> True
              _ -> False
            }
          }),
        )
        |> to_equal(1)
        expect(
          list.count(events, fn(event) {
            case event {
              RunFinished(..) -> True
              _ -> False
            }
          }),
        )
        |> to_equal(1)
      }),
      it("fail-fast skips every module after the first failing batch", fn() {
        let assert Ok(result) =
          executor.run_scheduled(
            [fixture("panic_fixture"), second_fixture("passing_fixture")],
            discard,
            30_000,
            True,
            0,
            4,
            [],
          )
        case result.cases {
          [first, second] -> {
            case first.outcome {
              Failed(_) -> Nil
              _ -> panic as "expected first module to fail"
            }
            expect(second.outcome) |> to_equal(Skipped)
          }
          _ -> panic as "expected both selected tests in the report"
        }
      }),
    ]),
  ]
}
