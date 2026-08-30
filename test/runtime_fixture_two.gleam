pub fn passing_fixture() -> Nil {
  Nil
}

@external(erlang, "runtime_fixture_ffi", "parallel_barrier")
@external(javascript, "./runtime_fixture_ffi.mjs", "parallel_barrier")
fn parallel_barrier(side: String) -> Nil

pub fn parallel_right_fixture() -> Nil {
  parallel_barrier("right")
}
