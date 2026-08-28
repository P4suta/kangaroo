import gleam/list
import gleam/option.{type Option, None}

/// A single test case within a suite.
pub type Case {
  Case(name: String, body: fn() -> Nil, mode: CaseMode)
}

pub type CaseMode {
  Normal
  Focused
  Skipped
}

/// Per-suite hooks. `before_each` runs before every case in the suite and
/// `after_each` runs after it, within the same isolated execution.
pub type Hooks {
  Hooks(before_each: Option(fn() -> Nil), after_each: Option(fn() -> Nil))
}

/// A named collection of test cases.
pub type Suite {
  Suite(name: String, cases: List(Case), hooks: Hooks)
}

pub fn it(name: String, body: fn() -> Nil) -> Case {
  Case(name, body, Normal)
}

pub fn it_skipped(name: String, body: fn() -> Nil) -> Case {
  Case(name, body, Skipped)
}

pub fn it_focused(name: String, body: fn() -> Nil) -> Case {
  Case(name, body, Focused)
}

pub fn no_hooks() -> Hooks {
  Hooks(None, None)
}

pub fn hooks(
  before_each: Option(fn() -> Nil),
  after_each: Option(fn() -> Nil),
) -> Hooks {
  Hooks(before_each, after_each)
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
