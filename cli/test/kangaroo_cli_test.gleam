import gleam/list
import kangaroo
import kangaroo/suite.{type Suite}
import graph_test.{suites as graph_suites}
import affected_test.{suites as affected_suites}
import collect_test.{suites as collect_suites}
import watcher_test.{suites as watcher_suites}
import integration_test.{suites as integration_suites}
import stream_test.{suites as stream_suites}

pub fn main() {
  kangaroo.main(suites())
}

/// Every suite in the CLI package, in execution order.
pub fn suites() -> List(Suite) {
  list.flatten([
    graph_suites(),
    affected_suites(),
    collect_suites(),
    watcher_suites(),
    stream_suites(),
    integration_suites(),
  ])
}
