import app_test.{suites as app_suites}
import command_test.{suites as command_suites}
import config_test.{suites as config_suites}
import coverage_instrument_test.{suites as coverage_instrument_suites}
import coverage_test.{suites as coverage_suites}
import dependency_test.{suites as dependency_suites}
import diff_test.{suites as diff_suites}
import discovery_test.{suites as discovery_suites}
import doctor_test.{suites as doctor_suites}
import encode_test.{suites as encode_suites}
import executor_test.{suites as executor_suites}
import expect_test.{suites as expect_suites}
import format_test.{suites as format_suites}
import generation_test.{suites as generation_suites}
import gleam/list
import gleam/string
import glob_test.{suites as glob_suites}
import helper_test.{suites as helper_suites}
import index_cache_test.{suites as index_cache_suites}
import index_test.{suites as index_suites}
import init_test.{suites as init_suites}
import kangaroo
import kangaroo/event.{type Event}
import kangaroo/internal/legacy/suite.{type Suite}
import kangaroo/report
import kangaroo/runner
import location_test.{suites as location_suites}
import operations_test.{suites as operations_suites}
import process_test.{suites as process_suites}
import protocol_v1_test.{suites as protocol_v1_suites}
import report_test.{suites as report_suites}
import reporter_test.{suites as reporter_suites}
import runner_test.{suites as runner_suites}
import runtime_test.{suites as runtime_suites}
import scheduler_test.{suites as scheduler_suites}
import selector_test.{suites as selector_suites}
import suite_test.{suites as suite_suites}
import terminal_test.{suites as terminal_suites}
import watch_initial_test.{suites as watch_initial_suites}
import watch_plan_test.{suites as watch_plan_suites}
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
    diff_suites(),
    dependency_suites(),
    suite_suites(),
    terminal_suites(),
    report_suites(),
    runner_suites(),
    expect_suites(),
    encode_suites(),
    location_suites(),
    operations_suites(),
    format_suites(),
    generation_suites(),
    index_suites(),
    index_cache_suites(),
    runtime_suites(),
    discovery_suites(),
    doctor_suites(),
    executor_suites(),
    app_suites(),
    config_suites(),
    coverage_suites(),
    coverage_instrument_suites(),
    selector_suites(),
    glob_suites(),
    scheduler_suites(),
    helper_suites(),
    command_suites(),
    reporter_suites(),
    protocol_v1_suites(),
    process_suites(),
    init_suites(),
    watcher_suites(),
    watch_initial_suites(),
    watch_plan_suites(),
  ])
}
