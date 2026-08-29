/// Records one executable Gleam source line when coverage instrumentation is
/// active. Outside `kangaroo coverage` this is a no-op.
@external(erlang, "kangaroo_coverage_probe_ffi", "hit")
@external(javascript, "../../kangaroo_coverage_probe_ffi.mjs", "hit")
pub fn hit(path: String, line: Int) -> Nil
