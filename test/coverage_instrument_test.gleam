import gleam/string
import kangaroo/internal/coverage_instrument

pub fn coverage_instruments_executable_statements_with_one_based_lines_test() {
  let source =
    "pub fn answer() {\n" <> "  let value = 40\n" <> "  value + 2\n" <> "}\n"
  let assert Ok(instrumented) =
    coverage_instrument.instrument("src/demo.gleam", source)
  assert instrumented.executable_lines == [2, 3]
  assert string.contains(
    instrumented.source,
    "kangaroo_coverage_probe.hit(\"src/demo.gleam\", 2)",
  )
  assert string.contains(
    instrumented.source,
    "kangaroo_coverage_probe.hit(\"src/demo.gleam\", 3)",
  )
}

pub fn coverage_wraps_single_expression_case_branches_test() {
  let source =
    "pub fn choose(value) {\n"
    <> "  case value {\n"
    <> "    True -> 1\n"
    <> "    False -> 2\n"
    <> "  }\n"
    <> "}\n"
  let assert Ok(instrumented) =
    coverage_instrument.instrument("src/choose.gleam", source)
  assert instrumented.executable_lines == [2, 3, 4]
  assert string.contains(
    instrumented.source,
    "True -> { kangaroo_coverage_probe.hit(\"src/choose.gleam\", 3)",
  )
}

pub fn coverage_uses_ast_offsets_without_corrupting_unicode_test() {
  let source = "const mascot = \"カンガルー\"\n\npub fn mascot() {\n  mascot\n}\n"
  let assert Ok(instrumented) =
    coverage_instrument.instrument("src/mascot.gleam", source)
  assert instrumented.executable_lines == [4]
  assert string.contains(instrumented.source, "\"カンガルー\"")
  assert string.contains(instrumented.source, "mascot\n}")
}

pub fn coverage_preserves_astral_unicode_at_native_ast_offsets_test() {
  let source = "const mascot = \"🦘\"\n\npub fn answer() {\n  42\n}\n"
  let assert Ok(instrumented) =
    coverage_instrument.instrument("src/emoji.gleam", source)
  assert instrumented.executable_lines == [4]
  assert string.contains(instrumented.source, "\"🦘\"")
  assert string.contains(
    instrumented.source,
    "kangaroo_coverage_probe.hit(\"src/emoji.gleam\", 4)\n42",
  )
}

pub fn coverage_probe_alias_does_not_shadow_user_source_test() {
  let source =
    "import gleam/io as kangaroo_coverage_probe\n\n"
    <> "pub fn answer() {\n"
    <> "  kangaroo_coverage_probe.println(\"user import\")\n"
    <> "}\n"
  let assert Ok(instrumented) =
    coverage_instrument.instrument("src/collision.gleam", source)
  assert string.starts_with(
    instrumented.source,
    "import kangaroo/coverage_probe as kangaroo_coverage_probe_\n",
  )
  assert string.contains(
    instrumented.source,
    "kangaroo_coverage_probe_.hit(\"src/collision.gleam\", 4)",
  )
  assert string.contains(
    instrumented.source,
    "kangaroo_coverage_probe.println(\"user import\")",
  )
}

pub fn coverage_keeps_module_docs_before_injected_import_test() {
  let source =
    "//// Calculator helpers.\n"
    <> "//// These docs must remain first.\n\n"
    <> "pub fn answer() {\n"
    <> "  42\n"
    <> "}\n"
  let assert Ok(instrumented) =
    coverage_instrument.instrument("src/documented.gleam", source)
  assert string.starts_with(
    instrumented.source,
    "//// Calculator helpers.\n"
      <> "//// These docs must remain first.\n"
      <> "import kangaroo/coverage_probe as kangaroo_coverage_probe\n\n",
  )
}

pub fn coverage_rejects_malformed_source_without_partial_result_test() {
  let assert Error(message) =
    coverage_instrument.instrument("src/broken.gleam", "pub fn broken( {")
  assert string.contains(message, "src/broken.gleam")
}
