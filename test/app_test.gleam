import gleam/option.{None}
import kangaroo/event.{type Event, CaseOutput, RunStarted}
import kangaroo/failure.{Failed, Passed, UnexpectedError}
import kangaroo/internal/app.{InfrastructureFailure, Success, TestFailure}
import kangaroo/internal/config.{Always, Failures, Never}
import kangaroo/report.{CaseResult, Report}

fn discard(_event: Event) {
  Nil
}

pub fn project_test_root_runs_end_to_end_test() {
  assert app.run_project(".", ["test/v1"], discard) == Success
}

pub fn project_dev_root_runs_end_to_end_test() {
  assert app.run_project(".", ["dev/integration"], discard) == Success
}

pub fn empty_selection_is_an_infrastructure_error_test() {
  let assert app.InfrastructureFailure("no tests found") =
    app.run_sources([], ["test"], discard)
}

pub fn show_output_applies_only_to_captured_output_events_test() {
  let passing = CaseOutput("math", "pass", "out", "", Passed)
  let failing =
    CaseOutput(
      "math",
      "fail",
      "out",
      "err",
      Failed([UnexpectedError("panic", "boom", None)]),
    )
  assert !app.include_event(Failures, passing)
  assert app.include_event(Failures, failing)
  assert app.include_event(Always, passing)
  assert !app.include_event(Never, failing)
  assert app.include_event(Never, RunStarted(1, 1))
}

pub fn runner_infrastructure_outcomes_use_exit_two_classification_test() {
  let infrastructure =
    Report([
      CaseResult(
        "runtime_fixture",
        "test/runtime_fixture.gleam::noisy_test",
        Failed([
          UnexpectedError(
            "infrastructure",
            "test output exceeded 16777216 bytes",
            None,
          ),
        ]),
        1,
      ),
    ])
  assert app.exit_from_report(infrastructure)
    == InfrastructureFailure("test output exceeded 16777216 bytes")

  let ordinary =
    Report([
      CaseResult(
        "runtime_fixture",
        "test/runtime_fixture.gleam::panic_test",
        Failed([UnexpectedError("panic", "boom", None)]),
        1,
      ),
    ])
  assert app.exit_from_report(ordinary) == TestFailure
}
