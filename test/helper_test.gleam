import gleam/option.{None, Some}
import gleam/string
import kangaroo/internal/fs
import kangaroo/internal/index.{type IndexedTest, IndexedTest}
import kangaroo/internal/runtime
import kangaroo/isolate.{CapturedIsolation, Completed, Crashed, SkippedIsolation}

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

@external(erlang, "runtime_fixture_ffi", "reset_descendant_marker")
@external(javascript, "./runtime_fixture_ffi.mjs", "reset_descendant_marker")
fn reset_descendant_marker() -> Nil

@external(erlang, "runtime_fixture_ffi", "descendant_marker_exists")
@external(javascript, "./runtime_fixture_ffi.mjs", "descendant_marker_exists")
fn descendant_marker_exists() -> Bool

pub fn descendant_timeout_cleanup_test() {
  reset_descendant_marker()
  let assert Ok(loaded) = runtime.resolve(fixture("descendant_timeout_fixture"))
  case runtime.run(loaded, Some(10)) {
    Crashed(error) -> {
      assert error.name == "timeout"
    }
    _ -> panic as "expected timeout"
  }
  fs.sleep(200)
  let survived = descendant_marker_exists()
  reset_descendant_marker()
  assert !survived
}

pub fn dynamic_skip_becomes_an_isolated_skipped_result_test() {
  let assert Ok(loaded) = runtime.resolve(fixture("dynamic_skip_fixture"))
  assert runtime.run(loaded, None) == SkippedIsolation("windows only")
}

pub fn fixture_retains_body_and_teardown_failures_test() {
  let assert Ok(loaded) = runtime.resolve(fixture("fixture_double_failure"))
  let assert Crashed(error) = runtime.run(loaded, None)
  assert string.contains(error.message, "body exploded")
  assert string.contains(error.message, "cleanup exploded")
}

pub fn javascript_promise_result_is_awaited_test() {
  let assert Ok(loaded) = runtime.resolve(fixture("promise_pass_fixture"))
  assert runtime.run(loaded, Some(1000)) == Completed
}

pub fn rejected_promise_uses_the_common_failure_model_test() {
  let assert Ok(loaded) = runtime.resolve(fixture("promise_reject_fixture"))
  let assert Crashed(error) = runtime.run(loaded, Some(1000))
  assert string.contains(error.message, "async rejected")
}

pub fn unresolved_promise_is_interrupted_at_timeout_test() {
  let assert Ok(loaded) = runtime.resolve(fixture("promise_timeout_fixture"))
  let assert Crashed(error) = runtime.run(loaded, Some(10))
  assert error.name == "timeout"
}

pub fn output_before_timeout_is_retained_test() {
  let assert Ok(loaded) = runtime.resolve(fixture("output_timeout_fixture"))
  let assert CapturedIsolation(Crashed(error), stdout, _) =
    runtime.run_captured(loaded, Some(10))
  assert error.name == "timeout"
  assert stdout == "before timeout\n"
}

pub fn isolated_test_termination_cleans_descendants_test() {
  reset_descendant_marker()
  let assert Ok(loaded) = runtime.resolve(fixture("descendant_fixture"))
  assert runtime.run(loaded, Some(1000)) == Completed
  fs.sleep(200)
  let survived = descendant_marker_exists()
  reset_descendant_marker()
  assert !survived
}
