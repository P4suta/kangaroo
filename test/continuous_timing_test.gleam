import kangaroo/internal/continuous
import kangaroo/internal/daemon
import kangaroo/internal/vm

pub fn idle_scan_interval_balances_latency_and_cpu_test() {
  assert continuous.scan_interval(0) == 1
  assert continuous.scan_interval(10) == 20
  assert continuous.scan_interval(50) == 100
  assert continuous.scan_interval(250) == 500
  // JavaScript process output wakes the daemon through the shared activity
  // signal, so the safety poll does not add to the watch scan interval.
  assert continuous.scan_interval(50) <= 100
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
