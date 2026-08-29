import gleam/option.{None, Some}
import kangaroo/internal/index.{IndexedModule, IndexedTest}
import kangaroo/internal/legacy/expect.{expect, to_equal}
import kangaroo/internal/legacy/suite.{it, suite}

pub fn underscored_timeout_literal_test() {
  let source =
    "import kangaroo\npub fn slow_test() { kangaroo.timeout(120_000) }"
  let assert Ok(IndexedModule(tests: [indexed], ..)) =
    index.index("test/slow_test.gleam", source, ["test"])
  assert indexed.timeout_ms == Some(120_000)
}

pub fn suites() {
  [
    suite("source index", [
      it("discovers only public zero-argument *_test functions", fn() {
        let source =
          "import app/math\n\nfn private_test() { Nil }\n\npub fn takes_an_argument_test(value: Int) { value }\n\npub fn first_test() { assert 1 == 1 }\n\npub fn helper() { Nil }\n\npub fn second_test() { Nil }\n"
        let assert Ok(IndexedModule(
          module: "unit/math_test",
          imports: ["app/math"],
          tests: tests,
          ..,
        )) = index.index("test/unit/math_test.gleam", source, ["test"])

        expect(tests)
        |> to_equal([
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
        ])
      }),
      it("extracts literal metadata from the function AST", fn() {
        let source =
          "import kangaroo as k\n\npub fn database_test() {\n  k.tag(\"database\")\n  k.tags([\"integration\", \"slow\"])\n  k.timeout(250)\n  k.serial()\n  k.skip(\"waiting for postgres\")\n}\n"
        let assert Ok(IndexedModule(tests: [indexed_test], ..)) =
          index.index("test/database.gleam", source, ["test"])

        expect(indexed_test.tags)
        |> to_equal(["database", "integration", "slow"])
        expect(indexed_test.timeout_ms) |> to_equal(Some(250))
        expect(indexed_test.serial) |> to_equal(True)
        expect(indexed_test.skip) |> to_equal(Some("waiting for postgres"))
      }),
      it("rejects dynamic tag timeout and serial metadata", fn() {
        let tag_source =
          "import kangaroo\npub fn bad_test() { kangaroo.tag(label) }"
        let timeout_source =
          "import kangaroo\npub fn bad_test() { kangaroo.timeout(limit) }"
        let serial_source =
          "import kangaroo\npub fn bad_test() { kangaroo.serial(enabled) }"

        expect(index.index("test/bad.gleam", tag_source, ["test"]))
        |> to_equal(
          Error(index.InvalidMetadata(
            id: "test/bad.gleam::bad_test",
            line: 2,
            message: "tag must be a string literal",
          )),
        )
        expect(index.index("test/bad.gleam", timeout_source, ["test"]))
        |> to_equal(
          Error(index.InvalidMetadata(
            id: "test/bad.gleam::bad_test",
            line: 2,
            message: "timeout must be a positive integer literal",
          )),
        )
        expect(index.index("test/bad.gleam", serial_source, ["test"]))
        |> to_equal(
          Error(index.InvalidMetadata(
            id: "test/bad.gleam::bad_test",
            line: 2,
            message: "serial takes no arguments",
          )),
        )
      }),
      it("normalises windows paths and selects the longest test root", fn() {
        let source = "pub fn path_test() { Nil }"
        let assert Ok(IndexedModule(path: path, module: module, ..)) =
          index.index("spec\\integration\\path_test.gleam", source, [
            "spec",
            "spec/integration",
          ])
        expect(path) |> to_equal("spec/integration/path_test.gleam")
        expect(module) |> to_equal("path_test")
      }),
      it("uses a stable content hash that changes with content", fn() {
        let assert Ok(first) =
          index.index("test/hash_test.gleam", "pub fn hash_test() { Nil }", [
            "test",
          ])
        let assert Ok(same) =
          index.index("test/hash_test.gleam", "pub fn hash_test() { Nil }", [
            "test",
          ])
        let assert Ok(changed) =
          index.index("test/hash_test.gleam", "pub fn hash_test() { 1 }", [
            "test",
          ])
        expect(first.content_hash == same.content_hash) |> to_equal(True)
        expect(first.content_hash == changed.content_hash) |> to_equal(False)
      }),
      it("returns a located parse error instead of a partial index", fn() {
        let result =
          index.index("test/broken_test.gleam", "pub fn broken_test( {", [
            "test",
          ])
        case result {
          Error(index.ParseError(path, line, _)) -> {
            expect(path) |> to_equal("test/broken_test.gleam")
            expect(line > 0) |> to_equal(True)
          }
          _ -> panic as "expected a parse error"
        }
      }),
    ]),
  ]
}
