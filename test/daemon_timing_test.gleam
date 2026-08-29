import kangaroo/internal/daemon

pub fn daemon_poll_interval_balances_idle_cpu_and_protocol_latency_test() {
  assert daemon.poll_interval_ms() == 25
  assert daemon.poll_interval_ms() < 250
}
