import command_test.{suites as command_suites}
import coverage_test.{suites as coverage_suites}
import encode_test.{suites as encode_suites}
import executor_test.{suites as executor_suites}
import expect_test.{suites as expect_suites}
import gleam/list
import gleam/string
import helper_test.{suites as helper_suites}
import index_test.{suites as index_suites}
import kangaroo
import kangaroo/event.{type Event}
import kangaroo/internal/legacy/suite.{type Suite}
import kangaroo/report
import kangaroo/runner
import location_test.{suites as location_suites}
import operations_test.{suites as operations_suites}
import runner_test.{suites as runner_suites}
import runtime_test.{suites as runtime_suites}
import suite_test.{suites as suite_suites}
import watcher_test.{suites as watcher_suites}

pub fn main() {
  kangaroo.main()
}

/// Runs the pre-v1 core tests as one ordinary v1 test while the implementation
/// is migrated away from the old internal suite representation.
pub fn legacy_regression_test() {
  kangaroo.serial()
  kangaroo.timeout(120_000)
  let result = runner.run(suites(), fn(_event: Event) { Nil })
  case report.has_failures(result) {
    False -> Nil
    True -> panic as string.inspect(result)
  }
}

/// Every suite in the project, in execution order.
pub fn suites() -> List(Suite) {
  list.flatten([
    suite_suites(),
    runner_suites(),
    expect_suites(),
    encode_suites(),
    location_suites(),
    operations_suites(),
    index_suites(),
    runtime_suites(),
    executor_suites(),
    coverage_suites(),
    helper_suites(),
    command_suites(),
    watcher_suites(),
  ])
}
