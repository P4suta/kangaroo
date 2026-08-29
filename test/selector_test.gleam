import gleam/option.{None}
import kangaroo/internal/index.{type IndexedTest, IndexedTest}
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

pub fn selector_parses_ids_tags_files_and_locations_test() {
  assert selector.parse("test/a_test.gleam::first_test")
    == Ok(Id("test/a_test.gleam::first_test"))
  assert selector.parse("tag:unit") == Ok(Tag("unit"))
  assert selector.parse("test\\a_test.gleam") == Ok(Path("test/a_test.gleam"))
  assert selector.parse("test/a_test.gleam:9")
    == Ok(Location("test/a_test.gleam", 9))
}

pub fn selector_uses_union_without_reordering_test() {
  let assert [_, second, third] = tests()
  let selected =
    selector.select(
      tests(),
      [Location("test/a_test.gleam", 9), Tag("slow")],
      [],
      [],
    )
  assert selected == [second, third]
}

pub fn file_selector_matches_all_tests_in_file_test() {
  let assert [first, second, third] = tests()
  assert selector.select(tests(), [Path("test/a_test.gleam")], [], [])
    == [first, second]
  assert selector.select(tests(), [Path("test/")], [], [])
    == [first, second, third]
}

pub fn tag_selector_uses_include_or_and_exclude_precedence_test() {
  let assert [first, second, third] = tests()
  assert selector.select(tests(), [], ["unit", "database"], ["slow"])
    == [first, second]
  assert selector.select(tests(), [Id(third.id)], [], ["slow"]) == []
}

pub fn empty_selector_and_tags_select_all_tests_test() {
  assert selector.select(tests(), [], [], []) == tests()
}
