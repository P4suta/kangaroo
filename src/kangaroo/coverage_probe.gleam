/// Records one executable Gleam source line for Kangaroo's coverage collector.
///
/// This module is public only because disposable, instrumented downstream
/// source must be able to import it across the package boundary. It is a
/// tooling ABI; application and test code should not call it directly.
@external(erlang, "kangaroo_coverage_probe_ffi", "hit")
@external(javascript, "../kangaroo_coverage_probe_ffi.mjs", "hit")
pub fn hit(path: String, line: Int) -> Nil
