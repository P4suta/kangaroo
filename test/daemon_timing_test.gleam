import kangaroo/internal/daemon
import kangaroo/internal/vm

pub fn daemon_poll_interval_balances_idle_cpu_and_protocol_latency_test() {
  assert daemon.poll_interval_for("javascript") == 150
  assert daemon.poll_interval_for("erlang") == 35
  assert daemon.poll_interval_ms() == daemon.poll_interval_for(vm.target())
  assert daemon.poll_interval_ms() < 250
}
