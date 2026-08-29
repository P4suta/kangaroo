import gleam/list
import gleam/option.{None}
import kangaroo/internal/dependencies.{All, Selected}
import kangaroo/internal/index.{IndexedModule, IndexedTest}

fn module(
  path: String,
  name: String,
  imports: List(String),
  tests: List(String),
) {
  IndexedModule(
    path:,
    module: name,
    content_hash: "hash",
    imports:,
    tests: list.map(tests, fn(test_name) {
      IndexedTest(
        id: path <> "::" <> test_name,
        name: test_name,
        path:,
        module: name,
        line: 1,
        column: 1,
        end_line: 1,
        end_column: 2,
        tags: [],
        timeout_ms: None,
        serial: False,
        skip: None,
      )
    }),
  )
}

fn graph() {
  [
    module("src/app/math.gleam", "app/math", [], []),
    module("src/app/service.gleam", "app/service", ["app/math"], []),
    module("test/math_test.gleam", "math_test", ["app/math"], ["unit_test"]),
    module("test/service_test.gleam", "service_test", ["app/service"], [
      "first_test",
      "second_test",
    ]),
    module("test/other_test.gleam", "other_test", [], ["other_test"]),
  ]
}

pub fn dependency_selection_finds_transitive_dependants_in_source_order_test() {
  let assert Selected(tests) =
    dependencies.affected(graph(), ["src/app/math.gleam"])
  assert list.map(tests, fn(indexed) { indexed.id })
    == [
      "test/math_test.gleam::unit_test",
      "test/service_test.gleam::first_test",
      "test/service_test.gleam::second_test",
    ]
}

pub fn dependency_selection_limits_changed_test_module_test() {
  let assert Selected(tests) =
    dependencies.affected(graph(), ["test/other_test.gleam"])
  assert list.map(tests, fn(indexed) { indexed.id })
    == ["test/other_test.gleam::other_test"]
}

pub fn dependency_selection_falls_back_for_ffi_config_and_unknown_changes_test() {
  assert dependencies.affected(graph(), ["src/app_ffi.erl"]) == All
  assert dependencies.affected(graph(), ["gleam.toml"]) == All
  assert dependencies.affected(graph(), ["priv/data.txt"]) == All
}
