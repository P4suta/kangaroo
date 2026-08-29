import gleam/io
import kangaroo

pub fn passing_test() {
  assert 1 + 1 == 2
}

pub fn panic_fixture() {
  panic as "fixture exploded"
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

pub fn output_fixture() {
  io.println("captured stdout")
  io.println_error("captured stderr")
}

@external(erlang, "runtime_fixture_ffi", "spawn_descendant")
@external(javascript, "./runtime_fixture_ffi.mjs", "spawn_descendant")
pub fn descendant_fixture() -> Nil

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

pub fn output_timeout_fixture() {
  io.println("before timeout")
  promise_timeout_fixture()
}

pub fn descendant_timeout_fixture() {
  descendant_fixture()
  promise_timeout_fixture()
}
