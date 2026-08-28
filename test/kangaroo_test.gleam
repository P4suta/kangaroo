import gleam/list
import kangaroo
import kangaroo/suite.{type Suite}
import diff_test.{suites as diff_suites}
import encode_test.{suites as encode_suites}
import expect_test.{suites as expect_suites}
import report_test.{suites as report_suites}
import runner_test.{suites as runner_suites}
import suite_test.{suites as suite_suites}

pub fn main() {
  kangaroo.main(suites())
}

/// Every suite in the project, in execution order.
pub fn suites() -> List(Suite) {
  list.flatten([
    diff_suites(),
    suite_suites(),
    report_suites(),
    runner_suites(),
    expect_suites(),
    encode_suites(),
  ])
}
