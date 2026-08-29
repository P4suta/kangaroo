import gleam/string
import kangaroo/internal/coverage_instrument
import kangaroo/internal/legacy/expect.{expect, to_be_true, to_equal}
import kangaroo/internal/legacy/suite.{it, suite}

pub fn suites() {
  [
    suite("coverage instrumentation", [
      it("instruments executable statements with one-based Gleam lines", fn() {
        let source =
          "pub fn answer() {\n"
          <> "  let value = 40\n"
          <> "  value + 2\n"
          <> "}\n"
        let assert Ok(instrumented) =
          coverage_instrument.instrument("src/demo.gleam", source)
        expect(instrumented.executable_lines) |> to_equal([2, 3])
        expect(string.contains(
          instrumented.source,
          "kangaroo_coverage_probe.hit(\"src/demo.gleam\", 2)",
        ))
        |> to_be_true()
        expect(string.contains(
          instrumented.source,
          "kangaroo_coverage_probe.hit(\"src/demo.gleam\", 3)",
        ))
        |> to_be_true()
      }),
      it("wraps single-expression case branches as independent lines", fn() {
        let source =
          "pub fn choose(value) {\n"
          <> "  case value {\n"
          <> "    True -> 1\n"
          <> "    False -> 2\n"
          <> "  }\n"
          <> "}\n"
        let assert Ok(instrumented) =
          coverage_instrument.instrument("src/choose.gleam", source)
        expect(instrumented.executable_lines) |> to_equal([2, 3, 4])
        expect(string.contains(
          instrumented.source,
          "True -> { kangaroo_coverage_probe.hit(\"src/choose.gleam\", 3)",
        ))
        |> to_be_true()
      }),
      it("uses AST offsets without corrupting Unicode source", fn() {
        let source =
          "const mascot = \"カンガルー\"\n\npub fn mascot() {\n  mascot\n}\n"
        let assert Ok(instrumented) =
          coverage_instrument.instrument("src/mascot.gleam", source)
        expect(instrumented.executable_lines) |> to_equal([4])
        expect(string.contains(instrumented.source, "\"カンガルー\""))
        |> to_be_true()
        expect(string.contains(instrumented.source, "mascot\n}"))
        |> to_be_true()
      }),
      it("preserves astral Unicode at backend-native AST offsets", fn() {
        let source = "const mascot = \"🦘\"\n\npub fn answer() {\n  42\n}\n"
        let assert Ok(instrumented) =
          coverage_instrument.instrument("src/emoji.gleam", source)
        expect(instrumented.executable_lines) |> to_equal([4])
        expect(string.contains(instrumented.source, "\"🦘\""))
        |> to_be_true()
        expect(string.contains(
          instrumented.source,
          "kangaroo_coverage_probe.hit(\"src/emoji.gleam\", 4)\n42",
        ))
        |> to_be_true()
      }),
      it("chooses a probe alias that cannot shadow user source", fn() {
        let source =
          "import gleam/io as kangaroo_coverage_probe\n\n"
          <> "pub fn answer() {\n"
          <> "  kangaroo_coverage_probe.println(\"user import\")\n"
          <> "}\n"
        let assert Ok(instrumented) =
          coverage_instrument.instrument("src/collision.gleam", source)
        expect(string.starts_with(
          instrumented.source,
          "import kangaroo/coverage_probe as kangaroo_coverage_probe_\n",
        ))
        |> to_be_true()
        expect(string.contains(
          instrumented.source,
          "kangaroo_coverage_probe_.hit(\"src/collision.gleam\", 4)",
        ))
        |> to_be_true()
        expect(string.contains(
          instrumented.source,
          "kangaroo_coverage_probe.println(\"user import\")",
        ))
        |> to_be_true()
      }),
      it("keeps leading module documentation before the injected import", fn() {
        let source =
          "//// Calculator helpers.\n"
          <> "//// These docs must remain first.\n\n"
          <> "pub fn answer() {\n"
          <> "  42\n"
          <> "}\n"
        let assert Ok(instrumented) =
          coverage_instrument.instrument("src/documented.gleam", source)
        expect(string.starts_with(
          instrumented.source,
          "//// Calculator helpers.\n"
            <> "//// These docs must remain first.\n"
            <> "import kangaroo/coverage_probe as kangaroo_coverage_probe\n\n",
        ))
        |> to_be_true()
      }),
      it("rejects malformed source instead of returning partial coverage", fn() {
        case
          coverage_instrument.instrument("src/broken.gleam", "pub fn broken( {")
        {
          Error(message) ->
            expect(string.contains(message, "src/broken.gleam"))
            |> to_be_true()
          Ok(_) -> panic as "expected instrumentation failure"
        }
      }),
    ]),
  ]
}
