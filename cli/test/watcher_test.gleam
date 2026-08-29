import gleam/dict
import gleam/list
import kangaroo/expect.{expect, to_be_true, to_equal}
import kangaroo/suite.{it, suite}
import kangaroo_cli/watcher.{
  type DirEntry, type FileMeta, Added, DirEntry, FileMeta, Modified, Removed,
  diff, diff_contents, insert, snapshot, walk, walk_advance, walk_files,
}

fn meta(mtime: Int, size: Int) -> FileMeta {
  FileMeta(mtime, size)
}

fn entry(name: String, is_dir: Bool) -> DirEntry {
  DirEntry(name, is_dir)
}

fn file(name: String) -> DirEntry {
  entry(name, False)
}

fn dir(name: String) -> DirEntry {
  entry(name, True)
}

/// A fake filesystem for the walk tests: directory mtimes and listings.
fn fake_fs(
  dirs: List(#(String, Int)),
  listings: List(#(String, List(DirEntry))),
) -> #(
  fn(String) -> Result(Int, Nil),
  fn(String) -> Result(List(DirEntry), Nil),
) {
  let dir_mtimes = dict.from_list(dirs)
  let listings = dict.from_list(listings)
  #(
    fn(path) {
      case dict.get(dir_mtimes, path) {
        Ok(mtime) -> Ok(mtime)
        Error(_) -> Error(Nil)
      }
    },
    fn(path) {
      case dict.get(listings, path) {
        Ok(entries) -> Ok(entries)
        Error(_) -> Error(Nil)
      }
    },
  )
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
      it("seeds a walk with its directories", fn() {
        let #(_, _) = fake_fs([#("src", 1), #("test", 2)], [])
        let walk = walk(["src", "test"])
        expect(walk_files(walk)) |> to_equal([])
      }),
      it("discovers files when a directory changes", fn() {
        let #(mtime, list) =
          fake_fs([#("src", 1)], [#("src", [file("a.gleam")])])
        let walk = walk(["src"])
        let #(next, changes) = walk_advance(walk, mtime, list)
        expect(changes) |> to_equal([Added("src/a.gleam")])
        expect(walk_files(next)) |> to_equal(["src/a.gleam"])
      }),
      it("does not re-list unchanged directories", fn() {
        let #(mtime, list) =
          fake_fs([#("src", 1)], [#("src", [file("a.gleam")])])
        let walk = walk(["src"])
        let #(next, _) = walk_advance(walk, mtime, list)
        // An unchanged directory is not listed again: the listing function
        // is only called for directories whose mtime advanced.
        let #(again, changes) = walk_advance(next, mtime, list)
        expect(changes) |> to_equal([])
        expect(walk_files(again)) |> to_equal(["src/a.gleam"])
      }),
      it("reports removed files when a directory changes", fn() {
        let #(mtime, list) =
          fake_fs([#("src", 1)], [#("src", [file("a.gleam")])])
        let walk = walk(["src"])
        let #(next, _) = walk_advance(walk, mtime, list)
        let #(mtime2, list2) = fake_fs([#("src", 2)], [#("src", [])])
        let #(final, changes) = walk_advance(next, mtime2, list2)
        expect(changes) |> to_equal([Removed("src/a.gleam")])
        expect(walk_files(final)) |> to_equal([])
      }),
      it("lists newly created subdirectories on the next step", fn() {
        let #(mtime, list) = fake_fs([#("src", 1)], [#("src", [dir("sub")])])
        let walk = walk(["src"])
        let #(next, changes) = walk_advance(walk, mtime, list)
        expect(changes) |> to_equal([])
        // The subdirectory is now known; when its own contents appear
        // (its mtime advances) its entries are discovered.
        let #(mtime2, list2) =
          fake_fs([#("src", 1), #("src/sub", 2)], [
            #("src", [dir("sub")]),
            #("src/sub", [file("b.gleam")]),
          ])
        let #(final, changes2) = walk_advance(next, mtime2, list2)
        expect(changes2) |> to_equal([Added("src/sub/b.gleam")])
        expect(walk_files(final)) |> to_equal(["src/sub/b.gleam"])
      }),
      it("does not report files of subdirectories as removed", fn() {
        // Re-listing a directory must only compare its direct children:
        // files under its subdirectories are not entries of the parent.
        let #(mtime, list) =
          fake_fs([#("src", 1), #("src/sub", 1)], [
            #("src", [dir("sub"), file("top.gleam")]),
            #("src/sub", [file("b.gleam")]),
          ])
        let walk = walk(["src", "src/sub"])
        let #(next, _) = walk_advance(walk, mtime, list)
        expect(walk_files(next))
        |> to_equal(["src/sub/b.gleam", "src/top.gleam"])
        // The parent directory advances but its entries are unchanged:
        // the subdirectory's file must stay known.
        let #(mtime2, list2) =
          fake_fs([#("src", 2), #("src/sub", 1)], [
            #("src", [dir("sub"), file("top.gleam")]),
            #("src/sub", [file("b.gleam")]),
          ])
        let #(final, changes) = walk_advance(next, mtime2, list2)
        expect(changes) |> to_equal([])
        expect(walk_files(final))
        |> to_equal(["src/sub/b.gleam", "src/top.gleam"])
      }),
      it("drops removed directories and their files", fn() {
        let #(mtime, list) =
          fake_fs([#("src", 1), #("src/sub", 1)], [
            #("src", [dir("sub")]),
            #("src/sub", [file("b.gleam")]),
          ])
        let walk = walk(["src", "src/sub"])
        let #(next, _) = walk_advance(walk, mtime, list)
        expect(walk_files(next)) |> to_equal(["src/sub/b.gleam"])
        // The subdirectory disappears from its parent listing.
        let #(mtime2, list2) =
          fake_fs([#("src", 2)], [#("src", []), #("src/sub", [])])
        let #(final, changes) = walk_advance(next, mtime2, list2)
        expect(changes) |> to_equal([Removed("src/sub/b.gleam")])
        expect(walk_files(final)) |> to_equal([])
      }),
    ]),
  ]
}
