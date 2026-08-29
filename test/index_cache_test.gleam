import gleam/list
import kangaroo/internal/index_cache.{Updated}
import kangaroo/internal/legacy/expect.{expect, to_equal}
import kangaroo/internal/legacy/suite.{it, suite}

pub fn suites() {
  [
    suite("incremental source index", [
      it("reuses unchanged modules by content hash", fn() {
        let sources = [
          #("src/app.gleam", "pub fn value() { 1 }"),
          #("test/app_test.gleam", "pub fn value_test() { Nil }"),
        ]
        let assert Ok(first) =
          index_cache.update(index_cache.empty(), sources, ["test"])
        expect(first.reused) |> to_equal(0)
        let assert Ok(second) =
          index_cache.update(first.cache, sources, ["test"])
        expect(second.reused) |> to_equal(2)
        expect(second.changed_paths) |> to_equal([])
      }),
      it("reindexes changed files and removes deleted files", fn() {
        let assert Ok(first) =
          index_cache.update(
            index_cache.empty(),
            [
              #("src/a.gleam", "pub fn a() { 1 }"),
              #("src/b.gleam", "pub fn b() { 2 }"),
            ],
            ["test"],
          )
        let assert Ok(Updated(modules: modules, changed_paths: changed, ..)) =
          index_cache.update(
            first.cache,
            [#("src/a.gleam", "pub fn a() { 3 }")],
            ["test"],
          )
        expect(list.map(modules, fn(module) { module.path }))
        |> to_equal(["src/a.gleam"])
        expect(changed) |> to_equal(["src/a.gleam", "src/b.gleam"])
      }),
      it(
        "rejects the complete update when any changed module cannot parse",
        fn() {
          let result =
            index_cache.update(
              index_cache.empty(),
              [#("test/broken.gleam", "pub fn broken( {")],
              ["test"],
            )
          case result {
            Error([_]) -> Nil
            _ -> panic as "expected an atomic index error"
          }
        },
      ),
    ]),
  ]
}
