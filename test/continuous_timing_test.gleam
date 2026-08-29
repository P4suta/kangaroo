import kangaroo/internal/continuous
import kangaroo/internal/daemon

pub fn idle_scan_interval_balances_latency_and_cpu_test() {
  assert continuous.scan_interval(0) == 1
  assert continuous.scan_interval(10) == 20
  assert continuous.scan_interval(50) == 100
  assert continuous.scan_interval(250) == 500
  assert continuous.scan_interval(50) + daemon.poll_interval_ms() <= 140
}
