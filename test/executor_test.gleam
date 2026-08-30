import gleam/list
import gleam/option.{None, Some}
import gleam/string
import kangaroo/event.{
  type Event, CaseOutput, RunFinished, RunStarted, SuiteFinished,
}
import kangaroo/failure.{
  EqualityMismatch, Failed, Flaky, Passed, Skipped, SkippedWithReason,
  UnexpectedError,
}
import kangaroo/internal/event_buffer
import kangaroo/internal/executor
import kangaroo/internal/index.{type IndexedTest, IndexedTest}
import kangaroo/internal/vm
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

@external(erlang, "kangaroo_cli_test_ffi", "reset_flaky")
@external(javascript, "./kangaroo_cli_test_ffi.mjs", "reset_flaky")
fn reset_flaky() -> Nil

@external(erlang, "runtime_fixture_ffi", "reset_parallel_barrier")
@external(javascript, "./runtime_fixture_ffi.mjs", "reset_parallel_barrier")
fn reset_parallel_barrier() -> Nil

pub fn indexed_results_use_stable_ids_test() {
  let assert Ok(result) =
    executor.run([fixture("passing_test")], discard, 30_000, False)
  assert !report.has_failures(result)
  let assert [case_result] = result.cases
  assert case_result.case_name == "test/runtime_fixture.gleam::passing_test"
  assert case_result.outcome == Passed
}

pub fn native_panics_use_the_common_failure_model_test() {
  let assert Ok(result) =
    executor.run([fixture("panic_fixture")], discard, 30_000, False)
  let assert [case_result] = result.cases
  let assert Failed([UnexpectedError(_, message, _)]) = case_result.outcome
  assert string.contains(message, "fixture exploded")
}

pub fn suite_finished_reflects_the_module_outcome_test() {
  event_buffer.take()
  let assert Ok(_) =
    executor.run([fixture("panic_fixture")], event_buffer.append, 30_000, False)
  let outcomes =
    event_buffer.take()
    |> list.filter_map(fn(event) {
      case event {
        SuiteFinished("runtime_fixture", outcome) -> Ok(outcome)
        _ -> Error(Nil)
      }
    })
  let assert [Failed(_)] = outcomes
}

pub fn equality_asserts_include_both_operands_test() {
  let assert Ok(result) =
    executor.run([fixture("equality_assert_fixture")], discard, 30_000, False)
  let assert [case_result] = result.cases
  let assert Failed([EqualityMismatch("2", "1", _, Some(location))]) =
    case_result.outcome
  assert location.file == "test/runtime_fixture.gleam"
  assert location.line == 47
}

pub fn multiline_string_assert_has_a_useful_diff_test() {
  let assert Ok(result) =
    executor.run([fixture("string_assert_fixture")], discard, 30_000, False)
  let assert [case_result] = result.cases
  let assert Failed([EqualityMismatch(_, _, Some(diff), _)]) =
    case_result.outcome
  assert string.contains(diff, "- new")
  assert string.contains(diff, "+ old")
}

pub fn static_skips_do_not_resolve_or_invoke_exports_test() {
  let skipped =
    IndexedTest(
      ..fixture("missing_fixture"),
      skip: Some("not on this platform"),
    )
  let assert Ok(result) = executor.run([skipped], discard, 30_000, False)
  let assert [case_result] = result.cases
  assert case_result.outcome == SkippedWithReason("not on this platform")
}

pub fn missing_exports_are_infrastructure_errors_test() {
  assert executor.run([fixture("missing_fixture")], discard, 30_000, False)
    == Error(
      "test/runtime_fixture.gleam::missing_fixture is not an exported zero-argument function",
    )
}

pub fn resolution_failure_closes_the_scheduled_event_stream_test() {
  event_buffer.take()
  assert executor.run_scheduled(
      [fixture("missing_fixture")],
      event_buffer.append,
      30_000,
      False,
      0,
      1,
      [],
    )
    == Error(
      "test/runtime_fixture.gleam::missing_fixture is not an exported zero-argument function",
    )
  let events = event_buffer.take()
  assert count_run_started(events) == 1
  assert count_run_finished(events) == 1
}

pub fn scheduled_modules_emit_one_deterministic_run_test() {
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
  assert list.map(result.cases, fn(case_) { case_.case_name })
    == [
      "test/runtime_fixture.gleam::passing_test",
      "test/runtime_fixture_two.gleam::passing_fixture",
    ]
  let events = event_buffer.take()
  assert count_run_started(events) == 1
  assert count_run_finished(events) == 1
}

pub fn javascript_worker_limit_runs_module_batches_concurrently_test() {
  case vm.target() {
    "javascript" -> {
      reset_parallel_barrier()
      let result =
        executor.run_scheduled(
          [
            fixture("parallel_left_fixture"),
            second_fixture("parallel_right_fixture"),
          ],
          discard,
          10_000,
          False,
          0,
          2,
          [],
        )
      reset_parallel_barrier()
      let assert Ok(report) = result
      assert !report.has_failures(report)
    }
    _ -> Nil
  }
}

pub fn fail_fast_skips_modules_after_the_first_failing_batch_test() {
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
  let assert [first, second] = result.cases
  let assert Failed(_) = first.outcome
  assert second.outcome == Skipped
}

pub fn passing_after_retry_is_classified_as_flaky_test() {
  reset_flaky()
  let assert Ok(result) =
    executor.run_with_options(
      [fixture("flaky_fixture")],
      discard,
      30_000,
      False,
      1,
    )
  let assert [case_result] = result.cases
  let assert Flaky(attempts: 2, ..) = case_result.outcome
  assert report.has_failures(result)
}

pub fn exhausted_retries_retain_every_failure_test() {
  let assert Ok(result) =
    executor.run_with_options(
      [fixture("panic_fixture")],
      discard,
      30_000,
      False,
      1,
    )
  let assert [case_result] = result.cases
  let assert Failed(failures) = case_result.outcome
  assert list.length(failures) == 2
}

pub fn a_skip_after_a_failed_attempt_cannot_turn_the_run_green_test() {
  reset_flaky()
  let assert Ok(result) =
    executor.run_with_options(
      [fixture("fail_then_skip_fixture")],
      discard,
      30_000,
      False,
      1,
    )
  let assert [case_result] = result.cases
  let assert Failed([_]) = case_result.outcome
  assert report.has_failures(result)
}

pub fn retry_output_budget_is_combined_across_streams_and_attempts_test() {
  assert executor.append_captured_output("123", "45", "6", "7", 6)
    == Error("test output exceeded 6 bytes")
  assert executor.append_captured_output("🦘", "", "a", "", 5) == Ok(#("🦘a", ""))
}

pub fn captured_output_is_emitted_with_the_case_outcome_test() {
  event_buffer.take()
  let assert Ok(_) =
    executor.run(
      [fixture("output_fixture")],
      event_buffer.append,
      30_000,
      False,
    )
  let output =
    event_buffer.take()
    |> list.filter_map(fn(event) {
      case event {
        CaseOutput(_, _, stdout, stderr, outcome) ->
          Ok(#(stdout, stderr, outcome))
        _ -> Error(Nil)
      }
    })
  assert output == [#("captured stdout\n", "captured stderr\n", Passed)]
}

fn count_run_started(events: List(Event)) -> Int {
  list.count(events, fn(event) {
    case event {
      RunStarted(..) -> True
      _ -> False
    }
  })
}

fn count_run_finished(events: List(Event)) -> Int {
  list.count(events, fn(event) {
    case event {
      RunFinished(..) -> True
      _ -> False
    }
  })
}
