import gleam/option.{type Option, None, Some}
import gleam/string
import kangaroo
import kangaroo/internal/index.{type IndexedTest, IndexedTest}
import kangaroo/internal/runtime
import kangaroo/isolate.{
  type CapturedIsolation, CapturedIsolation, Completed, Crashed,
}

@external(erlang, "kangaroo_cli_test_ffi", "kill_stderr_proxy")
@external(javascript, "./kangaroo_cli_test_ffi.mjs", "kill_stderr_proxy")
fn kill_stderr_proxy() -> Nil

@external(erlang, "kangaroo_isolate_ffi", "isolate_captured_with_limit")
@external(javascript, "./kangaroo_isolate_ffi.mjs", "isolate_captured_with_limit")
fn isolate_captured_with_limit(
  body: fn() -> Nil,
  timeout_ms: Option(Int),
  output_limit: Int,
) -> CapturedIsolation

fn fixture(name: String) -> IndexedTest {
  IndexedTest(
    id: "test/runtime_fixture.gleam::" <> name,
    name:,
    path: "test/runtime_fixture.gleam",
    module: "runtime_fixture",
    line: 1,
    column: 1,
    end_line: 1,
    end_column: 1,
    tags: [],
    timeout_ms: None,
    serial: False,
    skip: None,
  )
}

pub fn non_binary_assert_payload_test() {
  let assert Ok(loaded) = runtime.resolve(fixture("non_binary_assert_fixture"))
  let assert Crashed(error) = runtime.run(loaded, None)
  assert error.expected == None
  assert error.actual == None
  assert error.diff == None
}

pub fn plain_assert_includes_the_source_expression_test() {
  let assert Ok(loaded) = runtime.resolve(fixture("plain_assert_fixture"))
  let assert Crashed(error) = runtime.run(loaded, None)
  assert string.contains(error.message, "expression: condition")
}

pub fn multiline_assert_uses_the_shared_diff_test() {
  let assert Ok(loaded) = runtime.resolve(fixture("string_assert_fixture"))
  let assert Crashed(error) = runtime.run(loaded, None)
  assert error.diff == Some("- new\n+ old")
}

pub fn runtime_prepares_each_generation_module_once_test() {
  assert runtime.prepare_modules(["runtime_fixture", "runtime_fixture"])
    == Ok(Nil)
}

pub fn stderr_proxy_recovers_after_restart_test() {
  kangaroo.serial()
  kill_stderr_proxy()
  let assert Ok(loaded) = runtime.resolve(fixture("output_fixture"))
  assert runtime.run_captured(loaded, None)
    == CapturedIsolation(Completed, "captured stdout\n", "captured stderr\n")
}

pub fn compiled_public_zero_argument_function_is_invoked_test() {
  let assert Ok(loaded) = runtime.resolve(fixture("passing_test"))
  assert runtime.run(loaded, None) == Completed
}

pub fn native_gleam_panic_becomes_a_test_failure_test() {
  let assert Ok(loaded) = runtime.resolve(fixture("panic_fixture"))
  let assert Crashed(error) = runtime.run(loaded, None)
  assert string.contains(error.message, "fixture exploded")
}

pub fn missing_and_argument_exports_are_rejected_test() {
  assert runtime.resolve(fixture("missing_fixture"))
    == Error(
      "test/runtime_fixture.gleam::missing_fixture is not an exported zero-argument function",
    )
  assert runtime.resolve(fixture("argument_fixture"))
    == Error(
      "test/runtime_fixture.gleam::argument_fixture is not an exported zero-argument function",
    )
}

pub fn standard_assert_operands_and_operator_are_recovered_test() {
  let assert Ok(loaded) = runtime.resolve(fixture("equality_assert_fixture"))
  let assert Crashed(error) = runtime.run(loaded, None)
  assert string.contains(error.message, "1 == 2")
  assert error.location != None
}

pub fn standard_let_assert_unmatched_value_is_recovered_test() {
  let assert Ok(loaded) = runtime.resolve(fixture("let_assert_fixture"))
  let assert Crashed(error) = runtime.run(loaded, None)
  assert string.contains(error.message, "not an integer")
}

pub fn unicode_prefix_preserves_compiler_byte_offsets_test() {
  let assert Ok(loaded) =
    runtime.resolve(fixture("unicode_offset_assert_fixture"))
  let assert Crashed(error) = runtime.run(loaded, None)
  assert string.contains(error.message, "expression: mascot == \"kangaroo\"")
}

pub fn stdout_and_stderr_are_captured_without_leaking_test() {
  let assert Ok(loaded) = runtime.resolve(fixture("output_fixture"))
  assert runtime.run_captured(loaded, None)
    == CapturedIsolation(Completed, "captured stdout\n", "captured stderr\n")
}

pub fn combined_captured_output_above_the_limit_is_an_error_test() {
  kangaroo.serial()
  let assert Ok(loaded) =
    runtime.resolve(fixture("oversized_captured_output_fixture"))
  let assert CapturedIsolation(Crashed(error), stdout, stderr) =
    isolate_captured_with_limit(loaded.body, None, 1024)
  assert error.name == "infrastructure"
  assert error.message == "test output exceeded 1024 bytes"
  assert stdout == ""
  assert stderr == ""
}
