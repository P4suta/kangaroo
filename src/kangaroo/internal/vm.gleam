/// Runs closures concurrently on BEAM and collects their values in input
/// order. JavaScript executes closures in order; each indexed test itself is
/// still isolated in a fresh runtime Worker.
@external(erlang, "kangaroo_vm_ffi", "run_all")
@external(javascript, "../../kangaroo_vm_ffi.mjs", "run_all")
pub fn run_all(functions: List(fn() -> value)) -> List(value)

@external(erlang, "kangaroo_vm_ffi", "worker_count")
@external(javascript, "../../kangaroo_vm_ffi.mjs", "worker_count")
pub fn worker_count() -> Int

@external(erlang, "kangaroo_vm_ffi", "target")
@external(javascript, "../../kangaroo_vm_ffi.mjs", "target")
pub fn target() -> String

@external(erlang, "kangaroo_vm_ffi", "runtime_name")
@external(javascript, "../../kangaroo_vm_ffi.mjs", "runtime_name")
pub fn runtime_name() -> String

@external(erlang, "kangaroo_vm_ffi", "runtime_version")
@external(javascript, "../../kangaroo_vm_ffi.mjs", "runtime_version")
pub fn runtime_version() -> String

@external(erlang, "kangaroo_vm_ffi", "operating_system")
@external(javascript, "../../kangaroo_vm_ffi.mjs", "operating_system")
pub fn operating_system() -> String

/// Absolute JavaScript entry point used by daemon watch children. Resolving
/// it beside the running package keeps embedded/editor daemons independent of
/// whether the project under test already has compiled output.
@external(erlang, "kangaroo_vm_ffi", "daemon_runner_path")
@external(javascript, "../../kangaroo_vm_ffi.mjs", "daemon_runner_path")
pub fn daemon_runner_path() -> String

/// A process-local seed used only when shuffle is explicitly enabled.
@external(erlang, "kangaroo_vm_ffi", "shuffle_seed")
@external(javascript, "../../kangaroo_vm_ffi.mjs", "shuffle_seed")
pub fn shuffle_seed() -> Int
