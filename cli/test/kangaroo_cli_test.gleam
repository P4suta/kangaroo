import affected_test.{suites as affected_suites}
import collect_test.{suites as collect_suites}
import coverage_test.{suites as coverage_suites}
import gleam/list
import graph_test.{suites as graph_suites}
import integration_test.{suites as integration_suites}
import jscoverage_test.{suites as jscoverage_suites}
import kangaroo
import kangaroo/suite.{type Suite}
import keys_test.{suites as keys_suites}
import stream_test.{suites as stream_suites}
import tui_test.{suites as tui_suites}
import watcher_test.{suites as watcher_suites}

pub fn main() {
  kangaroo.main(suites())
}

/// Every suite in the CLI package, in execution order.
pub fn suites() -> List(Suite) {
  list.flatten([
    graph_suites(),
    affected_suites(),
    collect_suites(),
    coverage_suites(),
    watcher_suites(),
    stream_suites(),
    tui_suites(),
    integration_suites(),
    jscoverage_suites(),
    keys_suites(),
  ])
}
