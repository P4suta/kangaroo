import gleam/option.{None}
import gleam/string
import kangaroo
import kangaroo/internal/index.{type IndexedTest, IndexedTest}
import kangaroo/internal/runtime
import kangaroo/isolate.{Completed, Crashed}

@external(erlang, "coverage_probe_test_ffi", "begin_unwritable_probe_capture")
@external(javascript, "./coverage_probe_test_ffi.mjs", "begin_unwritable_probe_capture")
fn begin_unwritable_probe_capture() -> Nil

@external(erlang, "coverage_probe_test_ffi", "complete_unwritable_probe_capture")
@external(javascript, "./coverage_probe_test_ffi.mjs", "complete_unwritable_probe_capture")
fn complete_unwritable_probe_capture() -> Nil

@external(erlang, "coverage_probe_test_ffi", "begin_probe_capture")
@external(javascript, "./coverage_probe_test_ffi.mjs", "begin_probe_capture")
fn begin_probe_capture() -> String

@external(erlang, "coverage_probe_test_ffi", "complete_probe_capture")
@external(javascript, "./coverage_probe_test_ffi.mjs", "complete_probe_capture")
fn complete_probe_capture(path: String) -> String

pub fn coverage_probe_write_error_is_an_infrastructure_failure_test() {
  kangaroo.serial()
  begin_unwritable_probe_capture()
  let assert Ok(loaded) = runtime.resolve(coverage_fixture())
  let outcome = runtime.run(loaded, None)
  complete_unwritable_probe_capture()

  let assert Crashed(error) = outcome
  assert error.name == "infrastructure"
  assert string.contains(error.message, "coverage persistence failed")
}

pub fn coverage_hits_are_flushed_before_an_isolated_result_is_published_test() {
  kangaroo.serial()
  let path = begin_probe_capture()
  let indexed = coverage_fixture()
  let assert Ok(loaded) = runtime.resolve(indexed)
  let outcome = runtime.run(loaded, None)
  let contents = complete_probe_capture(path)
  assert outcome == Completed
  assert contents == "src/causal.gleam\t7\n"
}

fn coverage_fixture() -> IndexedTest {
  IndexedTest(
    id: "test/runtime_fixture.gleam::coverage_hit_fixture",
    name: "coverage_hit_fixture",
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
