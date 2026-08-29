import gleam/dict
import gleam/list
import kangaroo/expect.{expect, to_be_true, to_equal}
import kangaroo/suite.{it, suite}
import kangaroo_cli/watcher.{
  type FileMeta, Added, FileMeta, Modified, Removed, diff, diff_contents, insert,
  snapshot,
}

fn meta(mtime: Int, size: Int) -> FileMeta {
  FileMeta(mtime, size)
}

pub fn suites() {
  [
    suite("watcher", [
      it("detects added files", fn() {
        let current = snapshot() |> insert("src/a.gleam", meta(10, 5))
        expect(diff(snapshot(), current)) |> to_equal([Added("src/a.gleam")])
      }),
      it("detects modified files", fn() {
        let previous = snapshot() |> insert("src/a.gleam", meta(10, 5))
        let current = snapshot() |> insert("src/a.gleam", meta(11, 5))
        expect(diff(previous, current))
        |> to_equal([Modified("src/a.gleam")])
      }),
      it("detects size-only changes", fn() {
        let previous = snapshot() |> insert("src/a.gleam", meta(10, 5))
        let current = snapshot() |> insert("src/a.gleam", meta(10, 6))
        expect(diff(previous, current))
        |> to_equal([Modified("src/a.gleam")])
      }),
      it("detects removed files", fn() {
        let previous = snapshot() |> insert("src/a.gleam", meta(10, 5))
        expect(diff(previous, snapshot()))
        |> to_equal([Removed("src/a.gleam")])
      }),
      it("ignores unchanged files", fn() {
        let previous = snapshot() |> insert("src/a.gleam", meta(10, 5))
        let current = snapshot() |> insert("src/a.gleam", meta(10, 5))
        expect(diff(previous, current)) |> to_equal([])
      }),
      it("detects mixed changes", fn() {
        let previous =
          snapshot()
          |> insert("src/a.gleam", meta(10, 5))
          |> insert("src/b.gleam", meta(20, 5))
          |> insert("src/c.gleam", meta(30, 5))
        let current =
          snapshot()
          |> insert("src/a.gleam", meta(11, 5))
          |> insert("src/b.gleam", meta(20, 5))
          |> insert("src/d.gleam", meta(40, 5))
        let changes = diff(previous, current)
        expect(changes |> list.contains(Modified("src/a.gleam")))
        |> to_be_true()
        expect(changes |> list.contains(Removed("src/c.gleam"))) |> to_be_true()
        expect(changes |> list.contains(Added("src/d.gleam"))) |> to_be_true()
        expect(list.length(changes)) |> to_equal(3)
      }),
      it("detects content changes", fn() {
        let previous = dict.from_list([#("src/a.gleam", "one")])
        let current = dict.from_list([#("src/a.gleam", "two")])
        expect(diff_contents(previous, current))
        |> to_equal([Modified("src/a.gleam")])
      }),
      it("detects added and removed contents", fn() {
        let previous = dict.from_list([#("src/a.gleam", "one")])
        let current = dict.from_list([#("src/b.gleam", "one")])
        let changes = diff_contents(previous, current)
        expect(list.length(changes)) |> to_equal(2)
        expect(changes |> list.contains(Removed("src/a.gleam")))
        |> to_be_true()
        expect(changes |> list.contains(Added("src/b.gleam"))) |> to_be_true()
      }),
      it("ignores unchanged contents", fn() {
        let previous = dict.from_list([#("src/a.gleam", "one")])
        let current = dict.from_list([#("src/a.gleam", "one")])
        expect(diff_contents(previous, current)) |> to_equal([])
      }),
    ]),
  ]
}
