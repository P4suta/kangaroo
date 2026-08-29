import gleam/option.{None}
import kangaroo/internal/index.{type IndexedTest, IndexedTest}
import kangaroo/internal/legacy/expect.{expect, to_equal}
import kangaroo/internal/legacy/suite.{it, suite}
import kangaroo/internal/selector.{Id, Location, Path, Tag}

fn indexed(
  path: String,
  name: String,
  line: Int,
  end_line: Int,
  tags: List(String),
) -> IndexedTest {
  IndexedTest(
    id: path <> "::" <> name,
    name:,
    path:,
    module: path,
    line:,
    column: 1,
    end_line:,
    end_column: 1,
    tags:,
    timeout_ms: None,
    serial: False,
    skip: None,
  )
}

fn tests() {
  [
    indexed("test/a_test.gleam", "first_test", 2, 5, ["unit", "fast"]),
    indexed("test/a_test.gleam", "second_test", 8, 10, ["database"]),
    indexed("test/b_test.gleam", "third_test", 3, 4, ["unit", "slow"]),
  ]
}

pub fn suites() {
  [
    suite("selectors", [
      it("parses ids tags files and file locations", fn() {
        expect(selector.parse("test/a_test.gleam::first_test"))
        |> to_equal(Ok(Id("test/a_test.gleam::first_test")))
        expect(selector.parse("tag:unit")) |> to_equal(Ok(Tag("unit")))
        expect(selector.parse("test\\a_test.gleam"))
        |> to_equal(Ok(Path("test/a_test.gleam")))
        expect(selector.parse("test/a_test.gleam:9"))
        |> to_equal(Ok(Location("test/a_test.gleam", 9)))
      }),
      it("uses the union of multiple selectors without reordering", fn() {
        let assert [_, second, third] = tests()
        let selected =
          selector.select(
            tests(),
            [Location("test/a_test.gleam", 9), Tag("slow")],
            [],
            [],
          )
        expect(selected)
        |> to_equal([second, third])
      }),
      it("matches a file selector to all tests in that file", fn() {
        let assert [first, second, third] = tests()
        expect(selector.select(tests(), [Path("test/a_test.gleam")], [], []))
        |> to_equal([first, second])
        expect(selector.select(tests(), [Path("test/")], [], []))
        |> to_equal([first, second, third])
      }),
      it("treats include tags as OR and lets excludes win", fn() {
        let assert [first, second, third] = tests()
        expect(selector.select(tests(), [], ["unit", "database"], ["slow"]))
        |> to_equal([first, second])
        expect(selector.select(tests(), [Id(third.id)], [], ["slow"]))
        |> to_equal([])
      }),
      it("selects all tests when no selectors or tag filters are present", fn() {
        expect(selector.select(tests(), [], [], [])) |> to_equal(tests())
      }),
    ]),
  ]
}
