import gleam/option.{None, Some}
import kangaroo/internal/init.{AlreadyConfigured, Create, ReplaceKnown, Suggest}
import kangaroo/internal/legacy/expect.{expect, to_equal}
import kangaroo/internal/legacy/suite.{it, suite}

pub fn annotated_known_runner_test() {
  let unitest =
    "import unitest\n\npub fn main() -> Nil {\n  unitest.main()\n}\n"
  assert init.plan("my_app", Some(unitest))
    == ReplaceKnown(
      "test/my_app_test.gleam",
      unitest,
      "import kangaroo\n\npub fn main() {\n  kangaroo.main()\n}\n",
    )
}

pub fn suites() {
  [
    suite("init", [
      it("creates the package test main only when it is absent", fn() {
        expect(init.plan("my_app", None))
        |> to_equal(Create(
          "test/my_app_test.gleam",
          "import kangaroo\n\npub fn main() {\n  kangaroo.main()\n}\n",
        ))
      }),
      it("recognises an existing kangaroo main", fn() {
        expect(init.plan(
          "my_app",
          Some("import kangaroo\npub fn main() { kangaroo.main() }"),
        ))
        |> to_equal(AlreadyConfigured)
      }),
      it("only auto-replaces a known gleeunit or unitest main", fn() {
        let gleeunit =
          "import gleeunit\n\npub fn main() {\n  gleeunit.main()\n}\n"
        expect(init.plan("my_app", Some(gleeunit)))
        |> to_equal(ReplaceKnown(
          "test/my_app_test.gleam",
          gleeunit,
          "import kangaroo\n\npub fn main() {\n  kangaroo.main()\n}\n",
        ))
      }),
      it("returns a diff suggestion for custom existing files", fn() {
        case init.plan("my_app", Some("pub fn main() { custom() }")) {
          Suggest(path, suggestion) -> {
            expect(path) |> to_equal("test/my_app_test.gleam")
            expect(suggestion)
            |> to_equal(
              "import kangaroo\n\npub fn main() {\n  kangaroo.main()\n}\n",
            )
          }
          _ -> panic as "expected a suggestion"
        }
      }),
    ]),
  ]
}
