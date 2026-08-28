import gleam/list
import kangaroo/expect.{expect, to_equal}
import kangaroo/suite.{it, suite}
import kangaroo_cli/collect.{collect_suites}

fn empty_body() {
  Nil
}

pub fn suites() {
  [
    suite("collect", [
      it("merges suites from several modules", fn() {
        let modules = [
          [suite("math", [it("adds", empty_body)])],
          [suite("strings", [it("uppercases", empty_body)])],
        ]
        let collected = collect_suites(modules)
        case collected {
          [math, strings] -> {
            expect(math.name) |> to_equal("math")
            expect(strings.name) |> to_equal("strings")
          }
          _ -> panic as "expected two suites"
        }
      }),
      it("deduplicates cases with the same name", fn() {
        let modules = [
          [suite("math", [it("adds", empty_body), it("subs", empty_body)])],
          [suite("math", [it("adds", empty_body)])],
        ]
        let collected = collect_suites(modules)
        case collected {
          [math] -> expect(list.length(math.cases)) |> to_equal(2)
          _ -> panic as "expected one suite"
        }
      }),
      it("preserves case order", fn() {
        let modules = [
          [suite("math", [it("one", empty_body)])],
          [suite("math", [it("two", empty_body), it("three", empty_body)])],
        ]
        let collected = collect_suites(modules)
        case collected {
          [math] ->
            expect(list.map(math.cases, fn(c) { c.name }))
            |> to_equal(["one", "two", "three"])
          _ -> panic as "expected one suite"
        }
      }),
    ]),
  ]
}
