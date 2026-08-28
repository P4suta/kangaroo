import gleam/list
import kangaroo/expect.{expect, to_equal}
import kangaroo/suite.{it, suite}
import kangaroo_cli/affected.{affected_tests}
import kangaroo_cli/graph.{module_name, module_name_string}

pub fn suites() {
  [
    suite("affected", [
      it("finds directly affected tests", fn() {
        let graph = [
          #(module_name(["math"]), []),
          #(module_name(["math_test"]), [module_name(["math"])]),
          #(module_name(["foo"]), []),
          #(module_name(["foo_test"]), [module_name(["foo"])]),
        ]
        let affected =
          affected_tests(
            graph,
            [module_name(["math_test"]), module_name(["foo_test"])],
            [module_name(["math"])],
          )
          |> list.map(module_name_string)
        expect(affected) |> to_equal(["math_test"])
      }),
      it("finds transitively affected tests", fn() {
        let graph = [
          #(module_name(["database"]), []),
          #(module_name(["user"]), [module_name(["database"])]),
          #(module_name(["user_test"]), [module_name(["user"])]),
          #(module_name(["unrelated"]), []),
          #(module_name(["unrelated_test"]), [module_name(["unrelated"])]),
        ]
        let affected =
          affected_tests(
            graph,
            [module_name(["user_test"]), module_name(["unrelated_test"])],
            [module_name(["database"])],
          )
          |> list.map(module_name_string)
        expect(affected) |> to_equal(["user_test"])
      }),
      it("marks a test module itself as affected", fn() {
        let graph = [
          #(module_name(["foo"]), []),
          #(module_name(["foo_test"]), [module_name(["foo"])]),
        ]
        let affected =
          affected_tests(graph, [module_name(["foo_test"])], [
            module_name(["foo_test"]),
          ])
          |> list.map(module_name_string)
        expect(affected) |> to_equal(["foo_test"])
      }),
      it("returns nothing when nothing changed", fn() {
        let graph = [
          #(module_name(["math"]), []),
          #(module_name(["math_test"]), [module_name(["math"])]),
        ]
        let affected =
          affected_tests(graph, [module_name(["math_test"])], [
            module_name(["other"]),
          ])
          |> list.map(module_name_string)
        expect(affected) |> to_equal([])
      }),
      it("handles tests with no imports", fn() {
        let graph = [
          #(module_name(["empty_test"]), []),
          #(module_name(["anything"]), []),
        ]
        let affected =
          affected_tests(graph, [module_name(["empty_test"])], [
            module_name(["anything"]),
          ])
          |> list.map(module_name_string)
        expect(affected) |> to_equal([])
      }),
      it("handles cycles in the import graph", fn() {
        let graph = [
          #(module_name(["a"]), [module_name(["b"])]),
          #(module_name(["b"]), [module_name(["a"])]),
          #(module_name(["a_test"]), [module_name(["a"])]),
        ]
        let affected =
          affected_tests(graph, [module_name(["a_test"])], [module_name(["b"])])
          |> list.map(module_name_string)
        expect(affected) |> to_equal(["a_test"])
      }),
    ]),
  ]
}
