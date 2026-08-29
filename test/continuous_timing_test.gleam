import kangaroo/internal/continuous

pub fn idle_scan_interval_is_twice_the_settle_debounce_test() {
  assert continuous.scan_interval(0) == 1
  assert continuous.scan_interval(10) == 20
  assert continuous.scan_interval(50) == 100
  assert continuous.scan_interval(250) == 500
}
