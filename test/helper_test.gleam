import gleam/option.{None, Some}
import gleam/string
import kangaroo
import kangaroo/internal/fs
import kangaroo/internal/index.{type IndexedTest, IndexedTest}
import kangaroo/internal/runtime
import kangaroo/internal/vm
import kangaroo/isolate.{CapturedIsolation, Completed, Crashed, SkippedIsolation}
import kangaroo/sys

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

@external(erlang, "runtime_fixture_ffi", "run_all_crash_cancels_sibling")
@external(javascript, "./runtime_fixture_ffi.mjs", "run_all_crash_cancels_sibling")
fn run_all_crash_cancels_sibling() -> Bool

pub fn descendant_timeout_cleanup_test() {
  kangaroo.serial()
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

pub fn crashed_beam_batch_cancels_concurrent_siblings_test() {
  case vm.target() {
    "erlang" -> {
      assert run_all_crash_cancels_sibling()
    }
    _ -> Nil
  }
}

pub fn stopped_output_collector_is_an_infrastructure_failure_test() {
  case vm.target() {
    "erlang" -> {
      let assert Ok(loaded) =
        runtime.resolve(fixture("output_collector_failure_fixture"))
      let assert CapturedIsolation(Crashed(error), "", "") =
        runtime.run_captured(loaded, None)
      assert error.name == "infrastructure"
      assert string.contains(error.message, "output collector stopped")
    }
    _ -> Nil
  }
}

pub fn killed_beam_test_owner_is_reported_without_waiting_for_timeout_test() {
  case vm.target() {
    "erlang" -> {
      let assert Ok(loaded) =
        runtime.resolve(fixture("killed_test_owner_fixture"))
      let started = sys.now_ms()
      let assert Crashed(error) = runtime.run(loaded, Some(1000))
      assert error.name == "exit"
      assert string.contains(error.message, "before publishing a result")
      assert sys.now_ms() - started < 500
    }
    _ -> Nil
  }
}

pub fn exited_node_test_worker_is_reported_without_waiting_for_timeout_test() {
  case vm.target(), vm.runtime_name() {
    "javascript", "node" -> {
      let assert Ok(loaded) =
        runtime.resolve(fixture("exited_test_worker_fixture"))
      let started = sys.now_ms()
      let assert Crashed(error) = runtime.run(loaded, Some(1000))
      assert error.name == "infrastructure"
      assert string.contains(error.message, "before publishing a result")
      assert sys.now_ms() - started < 500
    }
    _, _ -> Nil
  }
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
  assert runtime.run(loaded, Some(functional_isolation_timeout_ms()))
    == Completed
}

pub fn rejected_promise_uses_the_common_failure_model_test() {
  let assert Ok(loaded) = runtime.resolve(fixture("promise_reject_fixture"))
  let assert Crashed(error) =
    runtime.run(loaded, Some(functional_isolation_timeout_ms()))
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
  kangaroo.serial()
  reset_descendant_marker()
  let assert Ok(loaded) = runtime.resolve(fixture("descendant_fixture"))
  assert runtime.run(loaded, Some(functional_isolation_timeout_ms()))
    == Completed
  fs.sleep(200)
  let survived = descendant_marker_exists()
  reset_descendant_marker()
  assert !survived
}

pub fn descendant_fork_during_cleanup_is_reaped_test() {
  case vm.target() {
    "erlang" -> {
      kangaroo.serial()
      reset_descendant_marker()
      run_cleanup_race_fixtures(25)
      fs.sleep(100)
      let survived = descendant_marker_exists()
      reset_descendant_marker()
      assert !survived
    }
    _ -> Nil
  }
}

pub fn exited_child_process_group_remains_owned_until_cleanup_test() {
  kangaroo.serial()
  reset_descendant_marker()
  let assert Ok(loaded) = runtime.resolve(fixture("orphan_descendant_fixture"))
  assert runtime.run(loaded, Some(functional_isolation_timeout_ms()))
    == Completed
  fs.sleep(case vm.target() {
    "javascript" -> 700
    _ -> 200
  })
  let survived = descendant_marker_exists()
  reset_descendant_marker()
  assert !survived
}

pub fn exited_native_child_process_group_remains_owned_until_cleanup_test() {
  case vm.target(), vm.runtime_name(), vm.operating_system() {
    "javascript", "bun", operating_system
    | "javascript", "deno", operating_system
      if operating_system != "windows"
    -> {
      kangaroo.serial()
      reset_descendant_marker()
      let assert Ok(loaded) =
        runtime.resolve(fixture("native_orphan_descendant_fixture"))
      assert runtime.run(loaded, Some(functional_isolation_timeout_ms()))
        == Completed
      fs.sleep(200)
      let survived = descendant_marker_exists()
      reset_descendant_marker()
      assert !survived
    }
    _, _, _ -> Nil
  }
}

pub fn beam_port_descendants_are_owned_until_test_cleanup_test() {
  case vm.target() {
    "erlang" -> {
      kangaroo.serial()
      reset_descendant_marker()
      let assert Ok(loaded) =
        runtime.resolve(fixture("port_orphan_descendant_fixture"))
      assert runtime.run(loaded, Some(functional_isolation_timeout_ms()))
        == Completed
      fs.sleep(700)
      let survived = descendant_marker_exists()
      reset_descendant_marker()
      assert !survived
    }
    _ -> Nil
  }
}

fn run_cleanup_race_fixtures(remaining: Int) {
  case remaining <= 0 {
    True -> Nil
    False -> {
      let assert Ok(loaded) = runtime.resolve(fixture("cleanup_race_fixture"))
      assert runtime.run(loaded, Some(functional_isolation_timeout_ms()))
        == Completed
      run_cleanup_race_fixtures(remaining - 1)
    }
  }
}

pub fn native_runtime_processes_are_cleaned_after_a_test_test() {
  kangaroo.serial()
  reset_descendant_marker()
  let assert Ok(loaded) = runtime.resolve(fixture("native_descendant_fixture"))
  assert runtime.run(loaded, Some(functional_isolation_timeout_ms()))
    == Completed
  fs.sleep(200)
  let survived = descendant_marker_exists()
  reset_descendant_marker()
  assert !survived
}

pub fn synchronous_process_descendants_are_cleaned_after_a_test_test() {
  kangaroo.serial()
  reset_descendant_marker()
  let assert Ok(loaded) =
    runtime.resolve(fixture("synchronous_descendant_fixture"))
  let outcome = runtime.run(loaded, Some(functional_isolation_timeout_ms()))
  case vm.target(), vm.runtime_name(), vm.operating_system() {
    "javascript", "bun", _
    | "javascript", "deno", _
    | "javascript", _, "windows"
    -> {
      let assert Crashed(error) = outcome
      assert string.contains(
        error.message,
        "use an asynchronous subprocess API",
      )
    }
    _, _, _ -> {
      assert outcome == Completed
    }
  }
  fs.sleep(200)
  let survived = descendant_marker_exists()
  reset_descendant_marker()
  assert !survived
}

// These cases assert cleanup semantics rather than latency. Leave expected
// timeout/cancellation tests at their short limits, while allowing a loaded CI
// host to schedule a successful isolation worker and its descendant reaper.
fn functional_isolation_timeout_ms() -> Int {
  5000
}

pub fn native_runtime_output_is_cancelled_at_the_test_timeout_test() {
  kangaroo.serial()
  reset_descendant_marker()
  let assert Ok(loaded) =
    runtime.resolve(fixture("native_output_timeout_fixture"))
  let assert Crashed(error) = runtime.run(loaded, Some(40))
  assert error.name == "timeout"
  fs.sleep(250)
  let survived = descendant_marker_exists()
  reset_descendant_marker()
  assert !survived
}

pub fn synchronous_process_is_bounded_or_rejected_before_it_can_leak_test() {
  kangaroo.serial()
  reset_descendant_marker()
  let assert Ok(loaded) =
    runtime.resolve(fixture("synchronous_timeout_fixture"))
  let assert Crashed(error) = runtime.run(loaded, Some(40))
  case vm.target(), vm.runtime_name(), vm.operating_system() {
    "javascript", "bun", _
    | "javascript", "deno", _
    | "javascript", _, "windows"
    -> {
      assert string.contains(
        error.message,
        "use an asynchronous subprocess API",
      )
    }
    _, _, _ -> {
      assert error.name == "timeout"
    }
  }
  fs.sleep(250)
  let survived = descendant_marker_exists()
  reset_descendant_marker()
  assert !survived
}
