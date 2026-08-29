import kangaroo/internal/benchmark

pub fn p95_uses_nearest_rank_independent_of_input_order_test() {
  let samples = [
    20,
    1,
    7,
    14,
    2,
    19,
    5,
    11,
    3,
    18,
    6,
    13,
    4,
    17,
    8,
    16,
    9,
    15,
    10,
    12,
  ]
  assert benchmark.p95(samples) == Ok(19)
  assert benchmark.p95([42]) == Ok(42)
  assert benchmark.p95([]) == Error("p95 requires at least one sample")
}

pub fn hard_limit_includes_the_boundary_test() {
  assert benchmark.within_limit(150, 150)
  assert !benchmark.within_limit(151, 150)
  assert !benchmark.within_limit(-1, 150)
  assert !benchmark.within_limit(1, -1)
}

pub fn regression_gate_rejects_more_than_fifteen_percent_test() {
  assert benchmark.within_regression(115, 100, 15)
  assert !benchmark.within_regression(116, 100, 15)
  assert benchmark.within_regression(0, 0, 15)
  assert !benchmark.within_regression(1, 0, 15)
  assert !benchmark.within_regression(-1, 100, 15)
  assert !benchmark.within_regression(100, -1, 15)
  assert !benchmark.within_regression(100, 100, -1)
}
