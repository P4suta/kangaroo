import gleam/list
import kangaroo/internal/discovery.{Discovery}

pub fn discovery_orders_by_normalised_path_then_source_order_test() {
  let sources = [
    #("test/z_test.gleam", "pub fn z_test() { Nil }"),
    #(
      "test/a_test.gleam",
      "pub fn second_test() { Nil }\npub fn first_test() { Nil }",
    ),
    #("src/not_a_test.gleam", "pub fn ignored_test() { Nil }"),
  ]
  let assert Ok(Discovery(tests: tests, ..)) =
    discovery.from_sources(sources, ["test"])
  assert list.map(tests, fn(indexed) { indexed.id })
    == [
      "test/a_test.gleam::second_test",
      "test/a_test.gleam::first_test",
      "test/z_test.gleam::z_test",
    ]
}

pub fn discovery_normalises_common_test_root_spellings_test() {
  let sources = [#("test/example.gleam", "pub fn example_test() { Nil }")]
  ["test/", "./test", "./test/", "."]
  |> list.each(fn(root) {
    let assert Ok(Discovery(tests: [indexed], ..)) =
      discovery.from_sources(sources, [root])
    assert indexed.id == "test/example.gleam::example_test"
  })
}

pub fn discovery_returns_all_parse_errors_without_partial_index_test() {
  let result =
    discovery.from_sources(
      [
        #("test/good.gleam", "pub fn good_test() { Nil }"),
        #("test/bad.gleam", "pub fn bad_test( {"),
      ],
      ["test"],
    )
  let assert Error([_]) = result
}

pub fn discovery_applies_exclude_globs_before_parsing_test() {
  let assert Ok(found) =
    discovery.from_sources_with_excludes(
      [
        #("test/good.gleam", "pub fn good_test() { Nil }"),
        #("test/generated/bad.gleam", "pub fn bad_test( {"),
      ],
      ["test"],
      ["test/generated/**"],
    )
  assert list.map(found.tests, fn(indexed) { indexed.id })
    == ["test/good.gleam::good_test"]
}

pub fn discovery_reads_repository_tree_through_filesystem_port_test() {
  let assert Ok(found) = discovery.discover(".", ["test"])
  assert list.any(found.tests, fn(indexed) {
    indexed.id == "test/runtime_fixture.gleam::passing_test"
  })
}

pub fn discovery_does_not_prune_valid_build_or_coverage_modules_test() {
  let assert Ok(found) = discovery.discover("fixtures/source_names", ["test"])
  assert list.map(found.tests, fn(indexed) { indexed.id })
    == [
      "test/build/legitimate.gleam::build_directory_test",
      "test/coverage/legitimate.gleam::coverage_directory_test",
    ]
}

pub fn overlapping_test_roots_do_not_duplicate_stable_ids_test() {
  let assert Ok(found) = discovery.discover(".", ["test", "test/"])
  assert list.count(found.tests, fn(indexed) {
      indexed.id == "test/runtime_fixture.gleam::passing_test"
    })
    == 1
}
