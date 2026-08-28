import gleam/list
import kangaroo/suite.{type Case, type Suite, Suite}

/// Collects suites from multiple test modules, de-duplicating cases by
/// suite name and case name. This lets the in-VM executor load suites from
/// every test module, including aggregator modules, without running the
/// same case twice.
pub fn collect_suites(modules: List(List(Suite))) -> List(Suite) {
  modules
  |> list.flatten
  |> list.fold([], fn(acc, suite) { merge_suite(acc, suite) })
}

fn merge_suite(suites: List(Suite), suite: Suite) -> List(Suite) {
  case suites {
    [] -> [suite]
    [existing, ..rest] if existing.name == suite.name -> [
      Suite(
        existing.name,
        merge_cases(existing.cases, suite.cases),
        existing.hooks,
      ),
      ..rest
    ]
    [first, ..rest] -> [first, ..merge_suite(rest, suite)]
  }
}

fn merge_cases(existing: List(Case), additional: List(Case)) -> List(Case) {
  list.fold(additional, existing, fn(cases, c) {
    case list.any(cases, fn(other) { other.name == c.name }) {
      True -> cases
      False -> list.append(cases, [c])
    }
  })
}
