import gleam/option.{None, Some}
import gleam/string
import kangaroo/internal/fs
import kangaroo/internal/index.{type IndexedTest, IndexedTest}
import kangaroo/internal/legacy/expect.{expect, to_be_true, to_equal}
import kangaroo/internal/legacy/suite.{it, suite}
import kangaroo/internal/runtime
import kangaroo/isolate.{CapturedIsolation, Completed, Crashed, SkippedIsolation}

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

@external(erlang, "runtime_fixture_ffi", "reset_descendant_marker")
@external(javascript, "./runtime_fixture_ffi.mjs", "reset_descendant_marker")
fn reset_descendant_marker() -> Nil

@external(erlang, "runtime_fixture_ffi", "descendant_marker_exists")
@external(javascript, "./runtime_fixture_ffi.mjs", "descendant_marker_exists")
fn descendant_marker_exists() -> Bool

pub fn suites() {
  [
    suite("helpers", [
      it("turns a dynamic skip into an isolated skipped result", fn() {
        let assert Ok(loaded) = runtime.resolve(fixture("dynamic_skip_fixture"))
        expect(runtime.run(loaded, None))
        |> to_equal(SkippedIsolation("windows only"))
      }),
      it("runs teardown and retains both body and teardown failures", fn() {
        let assert Ok(loaded) =
          runtime.resolve(fixture("fixture_double_failure"))
        case runtime.run(loaded, None) {
          Crashed(error) -> {
            expect(string.contains(error.message, "body exploded"))
            |> to_be_true()
            expect(string.contains(error.message, "cleanup exploded"))
            |> to_be_true()
          }
          _ -> panic as "expected the fixture to fail"
        }
      }),
      it("awaits a promise returned by a JavaScript test", fn() {
        let assert Ok(loaded) = runtime.resolve(fixture("promise_pass_fixture"))
        expect(runtime.run(loaded, Some(1000))) |> to_equal(Completed([]))
      }),
      it("converts a rejected promise to the common failure model", fn() {
        let assert Ok(loaded) =
          runtime.resolve(fixture("promise_reject_fixture"))
        case runtime.run(loaded, Some(1000)) {
          Crashed(error) ->
            expect(string.contains(error.message, "async rejected"))
            |> to_be_true()
          _ -> panic as "expected rejected promise failure"
        }
      }),
      it("interrupts an unresolved promise at the test timeout", fn() {
        let assert Ok(loaded) =
          runtime.resolve(fixture("promise_timeout_fixture"))
        case runtime.run(loaded, Some(10)) {
          Crashed(error) -> expect(error.name) |> to_equal("timeout")
          _ -> panic as "expected timeout"
        }
      }),
      it("retains output written before a timeout", fn() {
        let assert Ok(loaded) =
          runtime.resolve(fixture("output_timeout_fixture"))
        case runtime.run_captured(loaded, Some(10)) {
          CapturedIsolation(Crashed(error), stdout, _) -> {
            expect(error.name) |> to_equal("timeout")
            expect(stdout) |> to_equal("before timeout\n")
          }
          _ -> panic as "expected captured timeout"
        }
      }),
      it("terminates descendant work when an isolated test ends", fn() {
        reset_descendant_marker()
        let assert Ok(loaded) = runtime.resolve(fixture("descendant_fixture"))
        expect(runtime.run(loaded, Some(1000))) |> to_equal(Completed([]))
        fs.sleep(200)
        let survived = descendant_marker_exists()
        reset_descendant_marker()
        expect(survived) |> to_equal(False)
      }),
      it("terminates descendant work when an isolated test times out", fn() {
        reset_descendant_marker()
        let assert Ok(loaded) =
          runtime.resolve(fixture("descendant_timeout_fixture"))
        case runtime.run(loaded, Some(10)) {
          Crashed(error) -> expect(error.name) |> to_equal("timeout")
          _ -> panic as "expected timeout"
        }
        fs.sleep(200)
        let survived = descendant_marker_exists()
        reset_descendant_marker()
        expect(survived) |> to_equal(False)
      }),
    ]),
  ]
}
