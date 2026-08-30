import gleam/io
import gleam/string
import kangaroo
import kangaroo/coverage_probe

pub fn passing_test() {
  assert 1 + 1 == 2
}

pub fn coverage_hit_fixture() {
  coverage_probe.hit("src/causal.gleam", 7)
}

pub fn panic_fixture() {
  panic as "fixture exploded"
}

@external(erlang, "kangaroo_cli_test_ffi", "fail_once")
@external(javascript, "./kangaroo_cli_test_ffi.mjs", "fail_once")
fn fail_once() -> Nil

pub fn flaky_fixture() {
  fail_once()
}

@external(erlang, "runtime_fixture_ffi", "left_value")
@external(javascript, "./runtime_fixture_ffi.mjs", "left_value")
fn left_value() -> Int

@external(erlang, "runtime_fixture_ffi", "right_value")
@external(javascript, "./runtime_fixture_ffi.mjs", "right_value")
fn right_value() -> Int

@external(erlang, "runtime_fixture_ffi", "error_result")
@external(javascript, "./runtime_fixture_ffi.mjs", "error_result")
fn error_result() -> Result(Int, String)

@external(erlang, "runtime_fixture_ffi", "left_string")
@external(javascript, "./runtime_fixture_ffi.mjs", "left_string")
fn left_string() -> String

@external(erlang, "runtime_fixture_ffi", "right_string")
@external(javascript, "./runtime_fixture_ffi.mjs", "right_string")
fn right_string() -> String

pub fn equality_assert_fixture() {
  assert left_value() == right_value()
}

pub fn let_assert_fixture() {
  let assert Ok(_value) = error_result()
  Nil
}

pub fn string_assert_fixture() {
  assert left_string() == right_string()
}

pub fn unicode_offset_assert_fixture() {
  let mascot = "🦘"
  assert mascot == "kangaroo"
}

@external(erlang, "runtime_fixture_ffi", "non_binary_assert")
@external(javascript, "./runtime_fixture_ffi.mjs", "non_binary_assert")
fn non_binary_assert() -> Nil

pub fn non_binary_assert_fixture() {
  non_binary_assert()
}

pub fn plain_assert_fixture() {
  let condition = False
  assert condition
}

pub fn output_fixture() {
  io.println("captured stdout")
  io.println_error("captured stderr")
}

pub fn oversized_captured_output_fixture() {
  io.println(string.repeat("x", 511))
  io.println_error(string.repeat("y", 512))
}

@external(erlang, "runtime_fixture_ffi", "spawn_descendant")
@external(javascript, "./runtime_fixture_ffi.mjs", "spawn_descendant")
pub fn descendant_fixture() -> Nil

@external(erlang, "runtime_fixture_ffi", "spawn_cleanup_race")
@external(javascript, "./runtime_fixture_ffi.mjs", "spawn_cleanup_race")
pub fn cleanup_race_fixture() -> Nil

@external(erlang, "runtime_fixture_ffi", "spawn_orphan_descendant")
@external(javascript, "./runtime_fixture_ffi.mjs", "spawn_orphan_descendant")
pub fn orphan_descendant_fixture() -> Nil

@external(erlang, "runtime_fixture_ffi", "spawn_native_orphan_descendant")
@external(javascript, "./runtime_fixture_ffi.mjs", "spawn_native_orphan_descendant")
pub fn native_orphan_descendant_fixture() -> Nil

@external(erlang, "runtime_fixture_ffi", "spawn_port_orphan_descendant")
@external(javascript, "./runtime_fixture_ffi.mjs", "spawn_port_orphan_descendant")
pub fn port_orphan_descendant_fixture() -> Nil

@external(erlang, "runtime_fixture_ffi", "kill_test_owner_from_link")
@external(javascript, "./runtime_fixture_ffi.mjs", "kill_test_owner_from_link")
pub fn killed_test_owner_fixture() -> Nil

@external(erlang, "runtime_fixture_ffi", "exit_test_worker")
@external(javascript, "./runtime_fixture_ffi.mjs", "exit_test_worker")
pub fn exited_test_worker_fixture() -> Nil

@external(erlang, "runtime_fixture_ffi", "kill_output_collector")
@external(javascript, "./runtime_fixture_ffi.mjs", "kill_output_collector")
pub fn output_collector_failure_fixture() -> Nil

pub fn argument_fixture(_value: Int) {
  Nil
}

pub fn dynamic_skip_fixture() {
  kangaroo.skip_if(True, "windows only")
}

pub fn fixture_double_failure() {
  use _resource <- kangaroo.fixture(fn() { Nil }, fn(_) {
    panic as "cleanup exploded"
  })
  panic as "body exploded"
}

@external(erlang, "runtime_fixture_ffi", "promise_pass")
@external(javascript, "./runtime_fixture_ffi.mjs", "promise_pass")
pub fn promise_pass_fixture() -> Nil

@external(erlang, "runtime_fixture_ffi", "promise_reject")
@external(javascript, "./runtime_fixture_ffi.mjs", "promise_reject")
pub fn promise_reject_fixture() -> Nil

@external(erlang, "runtime_fixture_ffi", "promise_never")
@external(javascript, "./runtime_fixture_ffi.mjs", "promise_never")
pub fn promise_timeout_fixture() -> Nil

@external(erlang, "runtime_fixture_ffi", "parallel_barrier")
@external(javascript, "./runtime_fixture_ffi.mjs", "parallel_barrier")
fn parallel_barrier(side: String) -> Nil

pub fn parallel_left_fixture() -> Nil {
  parallel_barrier("left")
}

pub fn output_timeout_fixture() {
  io.println("before timeout")
  promise_timeout_fixture()
}

pub fn descendant_timeout_fixture() {
  descendant_fixture()
  promise_timeout_fixture()
}

pub fn fail_then_skip_fixture() {
  fail_once()
  kangaroo.skip("retry became inapplicable")
}

@external(erlang, "runtime_fixture_ffi", "spawn_native_descendant")
@external(javascript, "./runtime_fixture_ffi.mjs", "spawn_native_descendant")
pub fn native_descendant_fixture() -> Nil

@external(erlang, "runtime_fixture_ffi", "complete_native_child")
@external(javascript, "./runtime_fixture_ffi.mjs", "complete_native_child")
pub fn native_child_completion_fixture() -> Nil

@external(erlang, "runtime_fixture_ffi", "spawn_synchronous_descendant")
@external(javascript, "./runtime_fixture_ffi.mjs", "spawn_synchronous_descendant")
pub fn synchronous_descendant_fixture() -> Nil

@external(erlang, "runtime_fixture_ffi", "native_output_timeout")
@external(javascript, "./runtime_fixture_ffi.mjs", "native_output_timeout")
pub fn native_output_timeout_fixture() -> Nil

@external(erlang, "runtime_fixture_ffi", "synchronous_timeout")
@external(javascript, "./runtime_fixture_ffi.mjs", "synchronous_timeout")
pub fn synchronous_timeout_fixture() -> Nil
