import gleam/option.{None}
import kangaroo/event.{type Event, CaseOutput, RunStarted}
import kangaroo/failure.{Failed, Passed, UnexpectedError}
import kangaroo/internal/app.{Success}
import kangaroo/internal/config.{Always, Failures, Never}
import kangaroo/internal/legacy/expect.{expect, to_equal}
import kangaroo/internal/legacy/suite.{it, suite}

fn discard(_event: Event) {
  Nil
}

pub fn suites() {
  [
    suite("v1 application", [
      it("discovers and runs a project test root end to end", fn() {
        expect(app.run_project(".", ["test/v1"], discard))
        |> to_equal(Success)
      }),
      it("classifies an empty selection as an infrastructure error", fn() {
        case app.run_sources([], ["test"], discard) {
          app.InfrastructureFailure("no tests found") -> Nil
          _ -> panic as "expected no-tests infrastructure failure"
        }
      }),
      it("applies show_output only to captured output events", fn() {
        let passing = CaseOutput("math", "pass", "out", "", Passed)
        let failing =
          CaseOutput(
            "math",
            "fail",
            "out",
            "err",
            Failed([UnexpectedError("panic", "boom", None)]),
          )
        expect(app.include_event(Failures, passing)) |> to_equal(False)
        expect(app.include_event(Failures, failing)) |> to_equal(True)
        expect(app.include_event(Always, passing)) |> to_equal(True)
        expect(app.include_event(Never, failing)) |> to_equal(False)
        expect(app.include_event(Never, RunStarted(1, 1))) |> to_equal(True)
      }),
    ]),
  ]
}
