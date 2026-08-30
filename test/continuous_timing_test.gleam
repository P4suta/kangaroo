import gleam/dict
import gleam/option.{None, Some}
import kangaroo/internal/continuous
import kangaroo/internal/daemon
import kangaroo/internal/vm
import kangaroo/internal/watcher.{Modified}

pub fn idle_scan_interval_balances_latency_and_cpu_test() {
  assert continuous.scan_interval(0) == 1
  assert continuous.scan_interval(10) == 20
  assert continuous.scan_interval(50) == 120
  assert continuous.scan_interval(250) == 120
  // JavaScript process output wakes the daemon through the shared activity
  // signal, so the safety poll does not add to the watch scan interval.
  assert continuous.scan_interval(50) <= 120
  assert daemon.poll_interval_ms() <= 150
}

pub fn process_tree_cancellation_budget_is_platform_specific_test() {
  assert vm.process_cancellation_budget_for("linux") == 250
  assert vm.process_cancellation_budget_for("macos") == 250
  assert vm.process_cancellation_budget_for("windows") == 2000
}

pub fn process_cleanup_timeout_is_separate_from_the_performance_budget_test() {
  assert vm.process_cleanup_timeout_for("linux") == 1000
  assert vm.process_cleanup_timeout_for("macos") == 1000
  assert vm.process_cleanup_timeout_for("windows") == 5000
}

pub fn cleanup_deadline_never_silently_succeeds_after_expiry_test() {
  assert vm.cleanup_wait_result(999, 1000) == Ok(Nil)
  assert vm.cleanup_wait_result(1000, 1000)
    == Error("process cancellation exceeded 1000 ms")
}

pub fn stale_generation_output_is_not_folded_test() {
  let baseline = dict.from_list([#("test/example.gleam", "before")])
  let changed = dict.from_list([#("test/example.gleam", "after")])
  assert continuous.fold_output_if_current(
      baseline,
      baseline,
      "",
      "current",
      fn(output, chunk) { output <> chunk },
    )
    == Some("current")
  assert continuous.fold_output_if_current(
      baseline,
      changed,
      "unchanged",
      "stale",
      fn(_, _) { panic as "stale output callback must not run" },
    )
    == None
}

pub fn completed_generation_is_rechecked_against_the_latest_snapshot_test() {
  let baseline = dict.from_list([#("test/example.gleam", "before")])
  let changed = dict.from_list([#("test/example.gleam", "after")])
  assert continuous.completion_if_current(baseline, baseline, "current")
    == continuous.CurrentCompletion("current")
  assert continuous.completion_if_current(baseline, changed, "stale")
    == continuous.SupersededCompletion(
      [Modified("test/example.gleam")],
      changed,
    )
}

pub fn shuffle_seed_uses_wall_clock_entropy_test() {
  assert vm.shuffle_seed() > 1_000_000_000_000
}
