// Pre-v1 suite model retained only for the repository's migration tests.
import gleam/list
import gleam/option.{type Option, None}
import gleam/string

/// A single test case within a suite.
pub type Case {
  Case(
    name: String,
    body: fn() -> Nil,
    mode: CaseMode,
    timeout_ms: Option(Int),
    skip_reason: Option(String),
  )
}

pub type CaseMode {
  Normal
  Focused
  Skipped
}

/// Per-suite hooks. `before_all` runs once before the suite's cases,
/// `before_each` before every case, `after_each` after it, and `after_all`
/// once after the suite. Per-case hooks run within the same isolated
/// execution as the case; suite-level hooks run in their own.
pub type Hooks {
  Hooks(
    before_all: Option(fn() -> Nil),
    before_each: Option(fn() -> Nil),
    after_each: Option(fn() -> Nil),
    after_all: Option(fn() -> Nil),
  )
}

/// A named collection of test cases.
pub type Suite {
  Suite(name: String, cases: List(Case), hooks: Hooks)
}

pub fn it(name: String, body: fn() -> Nil) -> Case {
  Case(name, body, Normal, None, None)
}

pub fn it_skipped(name: String, body: fn() -> Nil) -> Case {
  Case(name, body, Skipped, None, None)
}

pub fn it_focused(name: String, body: fn() -> Nil) -> Case {
  Case(name, body, Focused, None, None)
}

pub fn no_hooks() -> Hooks {
  Hooks(None, None, None, None)
}

pub fn hooks(
  before_each: Option(fn() -> Nil),
  after_each: Option(fn() -> Nil),
) -> Hooks {
  Hooks(None, before_each, after_each, None)
}

/// Hooks with optional `before_all` and `after_all` runs.
pub fn all_hooks(
  before_all: Option(fn() -> Nil),
  before_each: Option(fn() -> Nil),
  after_each: Option(fn() -> Nil),
  after_all: Option(fn() -> Nil),
) -> Hooks {
  Hooks(before_all, before_each, after_each, after_all)
}

pub fn suite(name: String, cases: List(Case)) -> Suite {
  Suite(name, cases, no_hooks())
}

pub fn suite_with_hooks(
  name: String,
  cases: List(Case),
  suite_hooks: Hooks,
) -> Suite {
  Suite(name, cases, suite_hooks)
}

/// Returns `True` if any case in any suite is focused. When a focused case
/// exists, only focused cases should be run.
pub fn has_focused(suites: List(Suite)) -> Bool {
  list.any(suites, fn(suite) {
    list.any(suite.cases, fn(c) { c.mode == Focused })
  })
}

/// Keeps only the focused cases of each suite. Suites without focused cases
/// become empty.
pub fn keep_focused(suites: List(Suite)) -> List(Suite) {
  list.map(suites, fn(suite) {
    Suite(
      suite.name,
      list.filter(suite.cases, fn(c) { c.mode == Focused }),
      suite.hooks,
    )
  })
}

/// Removes skipped cases from every suite.
pub fn drop_skipped(suites: List(Suite)) -> List(Suite) {
  list.map(suites, fn(suite) {
    Suite(
      suite.name,
      list.filter(suite.cases, fn(c) { c.mode != Skipped }),
      suite.hooks,
    )
  })
}

/// Keeps only the suites and cases whose names contain the given
/// substring. A suite whose own name matches keeps every case; otherwise
/// only matching cases remain, and suites left empty are dropped.
pub fn filter_by_name(suites: List(Suite), substring: String) -> List(Suite) {
  list.filter_map(suites, fn(suite) {
    case string.contains(suite.name, substring) {
      True -> Ok(suite)
      False -> {
        let cases =
          list.filter(suite.cases, fn(c) { string.contains(c.name, substring) })
        case cases {
          [] -> Error(Nil)
          _ -> Ok(Suite(suite.name, cases, suite.hooks))
        }
      }
    }
  })
}
