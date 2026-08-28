import gleam/dict
import gleam/list
import kangaroo/expect.{expect, to_be_true, to_equal}
import kangaroo/suite.{it, suite}
import kangaroo_cli/watcher.{Added, Modified, Removed, diff}

pub fn suites() {
  [
    suite("watcher", [
      it("detects added files", fn() {
        let changes = diff(dict.new(), dict.from_list([#("src/a.gleam", 10)]))
        expect(changes) |> to_equal([Added("src/a.gleam")])
      }),
      it("detects modified files", fn() {
        let previous = dict.from_list([#("src/a.gleam", 10)])
        let current = dict.from_list([#("src/a.gleam", 11)])
        expect(diff(previous, current)) |> to_equal([Modified("src/a.gleam")])
      }),
      it("detects removed files", fn() {
        let previous = dict.from_list([#("src/a.gleam", 10)])
        let current = dict.new()
        expect(diff(previous, current)) |> to_equal([Removed("src/a.gleam")])
      }),
      it("ignores unchanged files", fn() {
        let previous = dict.from_list([#("src/a.gleam", 10)])
        let current = dict.from_list([#("src/a.gleam", 10)])
        expect(diff(previous, current)) |> to_equal([])
      }),
      it("detects mixed changes", fn() {
        let previous =
          dict.from_list([
            #("src/a.gleam", 10),
            #("src/b.gleam", 20),
            #("src/c.gleam", 30),
          ])
        let current =
          dict.from_list([
            #("src/a.gleam", 11),
            #("src/b.gleam", 20),
            #("src/d.gleam", 40),
          ])
        let changes = diff(previous, current)
        expect(changes |> list.contains(Modified("src/a.gleam")))
        |> to_be_true()
        expect(changes |> list.contains(Removed("src/c.gleam"))) |> to_be_true()
        expect(changes |> list.contains(Added("src/d.gleam"))) |> to_be_true()
        expect(list.length(changes)) |> to_equal(3)
      }),
    ]),
  ]
}
