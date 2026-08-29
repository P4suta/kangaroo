import gleam/list
import gleam/option.{None}
import kangaroo/internal/dependencies.{All, Selected}
import kangaroo/internal/index.{IndexedModule, IndexedTest}
import kangaroo/internal/legacy/expect.{expect, to_equal}
import kangaroo/internal/legacy/suite.{it, suite}

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

pub fn suites() {
  [
    suite("dependency selection", [
      it("selects transitive dependants in stable source order", fn() {
        let assert Selected(tests) =
          dependencies.affected(graph(), ["src/app/math.gleam"])
        expect(list.map(tests, fn(indexed) { indexed.id }))
        |> to_equal([
          "test/math_test.gleam::unit_test",
          "test/service_test.gleam::first_test",
          "test/service_test.gleam::second_test",
        ])
      }),
      it("selects only a changed test module", fn() {
        let assert Selected(tests) =
          dependencies.affected(graph(), ["test/other_test.gleam"])
        expect(list.map(tests, fn(indexed) { indexed.id }))
        |> to_equal(["test/other_test.gleam::other_test"])
      }),
      it("falls back to all tests for FFI config and unknown changes", fn() {
        expect(dependencies.affected(graph(), ["src/app_ffi.erl"]))
        |> to_equal(All)
        expect(dependencies.affected(graph(), ["gleam.toml"]))
        |> to_equal(All)
        expect(dependencies.affected(graph(), ["priv/data.txt"]))
        |> to_equal(All)
      }),
    ]),
  ]
}
