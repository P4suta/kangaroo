import gleam/option.{None, Some}
import gleam/string
import kangaroo
import kangaroo/failure.{EqualityMismatch}
import kangaroo/internal/index.{type IndexedTest, IndexedTest}
import kangaroo/internal/legacy/expect.{expect, to_be_true, to_equal}
import kangaroo/internal/legacy/suite.{it, suite}
import kangaroo/internal/runtime
import kangaroo/isolate.{CapturedIsolation, Completed, Crashed}

@external(erlang, "kangaroo_cli_test_ffi", "kill_stderr_proxy")
@external(javascript, "./kangaroo_cli_test_ffi.mjs", "kill_stderr_proxy")
fn kill_stderr_proxy() -> Nil

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

pub fn worker_returns_matcher_failures_test() {
  let assert Ok(loaded) = runtime.resolve(fixture("matcher_failure_fixture"))
  let assert Completed([EqualityMismatch(expected, actual, ..)]) =
    runtime.run(loaded, None)
  assert expected == "2"
  assert actual == "1"
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
    == CapturedIsolation(
      Completed([]),
      "captured stdout\n",
      "captured stderr\n",
    )
}

pub fn suites() {
  [
    suite("runtime", [
      it("resolves and invokes a compiled public zero-argument function", fn() {
        let assert Ok(loaded) = runtime.resolve(fixture("passing_test"))
        expect(runtime.run(loaded, None)) |> to_equal(Completed([]))
      }),
      it(
        "lets isolation convert a native Gleam panic into a test failure",
        fn() {
          let assert Ok(loaded) = runtime.resolve(fixture("panic_fixture"))
          case runtime.run(loaded, None) {
            Crashed(error) -> {
              expect(string.contains(error.message, "fixture exploded"))
              |> to_be_true()
            }
            _ -> panic as "expected the fixture to crash"
          }
        },
      ),
      it("rejects missing and non-zero-argument exports", fn() {
        expect(runtime.resolve(fixture("missing_fixture")))
        |> to_equal(Error(
          "test/runtime_fixture.gleam::missing_fixture is not an exported zero-argument function",
        ))
        expect(runtime.resolve(fixture("argument_fixture")))
        |> to_equal(Error(
          "test/runtime_fixture.gleam::argument_fixture is not an exported zero-argument function",
        ))
      }),
      it("recovers standard assert operands and operator from the panic", fn() {
        let assert Ok(loaded) =
          runtime.resolve(fixture("equality_assert_fixture"))
        case runtime.run(loaded, None) {
          Crashed(error) -> {
            expect(string.contains(error.message, "1 == 2")) |> to_be_true()
            expect(error.location != None) |> to_be_true()
          }
          _ -> panic as "expected assert to crash"
        }
      }),
      it("recovers the unmatched value from a standard let assert", fn() {
        let assert Ok(loaded) = runtime.resolve(fixture("let_assert_fixture"))
        case runtime.run(loaded, None) {
          Crashed(error) ->
            expect(string.contains(error.message, "not an integer"))
            |> to_be_true()
          _ -> panic as "expected let assert to crash"
        }
      }),
      it("slices compiler byte offsets correctly after Unicode text", fn() {
        let assert Ok(loaded) =
          runtime.resolve(fixture("unicode_offset_assert_fixture"))
        case runtime.run(loaded, None) {
          Crashed(error) ->
            expect(string.contains(
              error.message,
              "expression: mascot == \"kangaroo\"",
            ))
            |> to_be_true()
          _ -> panic as "expected Unicode assertion to crash"
        }
      }),
      it("captures stdout and stderr without leaking them", fn() {
        let assert Ok(loaded) = runtime.resolve(fixture("output_fixture"))
        expect(runtime.run_captured(loaded, None))
        |> to_equal(CapturedIsolation(
          Completed([]),
          "captured stdout\n",
          "captured stderr\n",
        ))
      }),
    ]),
  ]
}
