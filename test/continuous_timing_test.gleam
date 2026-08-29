import kangaroo/internal/continuous

pub fn idle_scan_interval_balances_latency_and_cpu_test() {
  assert continuous.scan_interval(0) == 1
  assert continuous.scan_interval(10) == 30
  assert continuous.scan_interval(50) == 150
  assert continuous.scan_interval(250) == 750
}
