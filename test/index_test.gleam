import gleam/option.{None, Some}
import gleam/string
import kangaroo/internal/index.{IndexedModule, IndexedTest}

pub fn underscored_timeout_literal_test() {
  let source =
    "import kangaroo\npub fn slow_test() { kangaroo.timeout(120_000) }"
  let assert Ok(IndexedModule(tests: [indexed], ..)) =
    index.index("test/slow_test.gleam", source, ["test"])
  assert indexed.timeout_ms == Some(120_000)
}

pub fn only_public_zero_argument_test_functions_are_discovered_test() {
  let source =
    "import app/math\n\nfn private_test() { Nil }\n\npub fn takes_an_argument_test(value: Int) { value }\n\npub fn first_test() { assert 1 == 1 }\n\npub fn helper() { Nil }\n\npub fn second_test() { Nil }\n"
  let assert Ok(IndexedModule(
    module: "unit/math_test",
    imports: ["app/math"],
    tests: tests,
    ..,
  )) = index.index("test/unit/math_test.gleam", source, ["test"])

  assert tests
    == [
      IndexedTest(
        id: "test/unit/math_test.gleam::first_test",
        name: "first_test",
        path: "test/unit/math_test.gleam",
        module: "unit/math_test",
        line: 7,
        column: 1,
        end_line: 7,
        end_column: 38,
        tags: [],
        timeout_ms: None,
        serial: False,
        skip: None,
      ),
      IndexedTest(
        id: "test/unit/math_test.gleam::second_test",
        name: "second_test",
        path: "test/unit/math_test.gleam",
        module: "unit/math_test",
        line: 11,
        column: 1,
        end_line: 11,
        end_column: 29,
        tags: [],
        timeout_ms: None,
        serial: False,
        skip: None,
      ),
    ]
}

pub fn literal_metadata_is_extracted_from_the_function_ast_test() {
  let source =
    "import kangaroo as k\n\npub fn database_test() {\n  k.tag(\"database\")\n  k.tags([\"integration\", \"slow\"])\n  k.timeout(250)\n  k.serial()\n  k.skip(\"waiting for postgres\")\n}\n"
  let assert Ok(IndexedModule(tests: [indexed_test], ..)) =
    index.index("test/database.gleam", source, ["test"])

  assert indexed_test.tags == ["database", "integration", "slow"]
  assert indexed_test.timeout_ms == Some(250)
  assert indexed_test.serial
  assert indexed_test.skip == Some("waiting for postgres")
}

pub fn dynamic_metadata_is_rejected_test() {
  let tag_source = "import kangaroo\npub fn bad_test() { kangaroo.tag(label) }"
  let timeout_source =
    "import kangaroo\npub fn bad_test() { kangaroo.timeout(limit) }"
  let serial_source =
    "import kangaroo\npub fn bad_test() { kangaroo.serial(enabled) }"
  let skip_source =
    "import kangaroo\npub fn bad_test() { kangaroo.skip(reason) }"

  assert index.index("test/bad.gleam", tag_source, ["test"])
    == Error(index.InvalidMetadata(
      id: "test/bad.gleam::bad_test",
      line: 2,
      message: "tag must be a string literal",
    ))
  assert index.index("test/bad.gleam", timeout_source, ["test"])
    == Error(index.InvalidMetadata(
      id: "test/bad.gleam::bad_test",
      line: 2,
      message: "timeout must be a positive integer literal",
    ))
  assert index.index("test/bad.gleam", serial_source, ["test"])
    == Error(index.InvalidMetadata(
      id: "test/bad.gleam::bad_test",
      line: 2,
      message: "serial takes no arguments",
    ))
  assert index.index("test/bad.gleam", skip_source, ["test"])
    == Error(index.InvalidMetadata(
      id: "test/bad.gleam::bad_test",
      line: 2,
      message: "skip must be a string literal",
    ))
}

pub fn windows_paths_use_the_longest_test_root_test() {
  let source = "pub fn path_test() { Nil }"
  let assert Ok(IndexedModule(path: path, module: module, ..)) =
    index.index("spec\\integration\\path_test.gleam", source, [
      "spec",
      "spec/integration",
    ])
  assert path == "spec/integration/path_test.gleam"
  assert module == "path_test"
}

pub fn content_hash_is_stable_and_changes_with_content_test() {
  let assert Ok(first) =
    index.index("test/hash_test.gleam", "pub fn hash_test() { Nil }", [
      "test",
    ])
  let assert Ok(same) =
    index.index("test/hash_test.gleam", "pub fn hash_test() { Nil }", [
      "test",
    ])
  let assert Ok(changed) =
    index.index("test/hash_test.gleam", "pub fn hash_test() { 1 }", ["test"])
  assert first.content_hash == same.content_hash
  assert first.content_hash != changed.content_hash
  assert index.source_hash(string.repeat("kangaroo🦘", 1000)) == "2DB7554B"
}

pub fn parse_errors_are_located_without_a_partial_index_test() {
  let result =
    index.index("test/broken_test.gleam", "pub fn broken_test( {", ["test"])
  let assert Error(index.ParseError(path, line, _)) = result
  assert path == "test/broken_test.gleam"
  assert line > 0
}
