import gleam/list
import kangaroo/expect.{expect, to_be_false, to_be_true, to_equal}
import kangaroo/suite.{it, it_focused, it_skipped, no_hooks, suite}

fn empty_body() {
  Nil
}

pub fn suites() {
  [
    suite("suite", [
      it("creates normal cases", fn() {
        let c = it("a case", empty_body)
        expect(c.name) |> to_equal("a case")
        expect(c.mode) |> to_equal(suite.Normal)
      }),
      it("marks skipped cases", fn() {
        let c = it_skipped("a skipped case", empty_body)
        expect(c.mode) |> to_equal(suite.Skipped)
      }),
      it("marks focused cases", fn() {
        let c = it_focused("a focused case", empty_body)
        expect(c.mode) |> to_equal(suite.Focused)
      }),
      it("has no hooks by default", fn() {
        let s = suite("math", [])
        expect(s.hooks) |> to_equal(no_hooks())
        expect(s.name) |> to_equal("math")
      }),
      it("detects the absence of focused cases", fn() {
        let suites = [suite("a", [it("x", empty_body)])]
        expect(suite.has_focused(suites)) |> to_be_false()
      }),
      it("detects focused cases", fn() {
        let suites = [
          suite("a", [it("x", empty_body), it_focused("y", empty_body)]),
        ]
        expect(suite.has_focused(suites)) |> to_be_true()
      }),
      it("keeps only focused cases", fn() {
        let suites = [
          suite("a", [it("x", empty_body), it_focused("y", empty_body)]),
        ]
        let focused = suite.keep_focused(suites)
        case focused {
          [s] -> expect(list.map(s.cases, fn(c) { c.name })) |> to_equal(["y"])
          _ -> panic as "expected one suite"
        }
      }),
      it("drops skipped cases", fn() {
        let suites = [
          suite("a", [it("x", empty_body), it_skipped("y", empty_body)]),
        ]
        let dropped = suite.drop_skipped(suites)
        case dropped {
          [s] -> expect(list.map(s.cases, fn(c) { c.name })) |> to_equal(["x"])
          _ -> panic as "expected one suite"
        }
      }),
    ]),
  ]
}
