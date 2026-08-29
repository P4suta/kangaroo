@external(erlang, "coverage_probe_test_ffi", "hit_unwritable_target")
@external(javascript, "./coverage_probe_test_ffi.mjs", "hit_unwritable_target")
fn hit_unwritable_target() -> Nil

pub fn coverage_probe_write_error_does_not_fail_the_test_test() {
  hit_unwritable_target()
}
