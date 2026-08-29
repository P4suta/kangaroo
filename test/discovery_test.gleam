import gleam/list
import kangaroo/internal/discovery.{Discovery}
import kangaroo/internal/legacy/expect.{expect, to_be_true, to_equal}
import kangaroo/internal/legacy/suite.{it, suite}

pub fn suites() {
  [
    suite("discovery", [
      it("orders tests by normalised path then source definition order", fn() {
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
        expect(list.map(tests, fn(indexed) { indexed.id }))
        |> to_equal([
          "test/a_test.gleam::second_test",
          "test/a_test.gleam::first_test",
          "test/z_test.gleam::z_test",
        ])
      }),
      it("returns every parse error and no partial runnable index", fn() {
        let result =
          discovery.from_sources(
            [
              #("test/good.gleam", "pub fn good_test() { Nil }"),
              #("test/bad.gleam", "pub fn bad_test( {"),
            ],
            ["test"],
          )
        case result {
          Error([_]) -> Nil
          _ -> panic as "expected one discovery error"
        }
      }),
      it("applies exclude globs before parsing", fn() {
        let assert Ok(found) =
          discovery.from_sources_with_excludes(
            [
              #("test/good.gleam", "pub fn good_test() { Nil }"),
              #("test/generated/bad.gleam", "pub fn bad_test( {"),
            ],
            ["test"],
            ["test/generated/**"],
          )
        expect(list.map(found.tests, fn(indexed) { indexed.id }))
        |> to_equal(["test/good.gleam::good_test"])
      }),
      it("discovers the repository test tree through the filesystem port", fn() {
        let assert Ok(found) = discovery.discover(".", ["test"])
        expect(
          list.any(found.tests, fn(indexed) {
            indexed.id == "test/runtime_fixture.gleam::passing_test"
          }),
        )
        |> to_be_true()
      }),
    ]),
  ]
}
