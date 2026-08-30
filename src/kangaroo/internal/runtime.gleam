import gleam/list
import gleam/option.{type Option}
import kangaroo/internal/index.{type IndexedTest}
import kangaroo/isolate.{
  type CapturedIsolation, type Isolated, isolate, isolate_captured,
}

pub type LoadedTest {
  LoadedTest(index: IndexedTest, body: fn() -> Nil)
}

/// Reloads every compiled module once at the execution-generation boundary.
/// Individual export resolution then performs only an arity/publicity check.
pub fn prepare_modules(modules: List(String)) -> Result(Nil, String) {
  reload_modules(list.unique(modules))
}

/// Resolves an indexed test against its compiled module.
///
/// Resolution checks both publicity and arity. Keeping this check separate
/// from source discovery makes stale or mismatched build artefacts a clear
/// infrastructure error instead of a silently skipped test.
pub fn resolve(indexed: IndexedTest) -> Result(LoadedTest, String) {
  case resolve_export(indexed.module, indexed.name) {
    Ok(body) -> Ok(LoadedTest(index: indexed, body:))
    Error(_) ->
      Error(indexed.id <> " is not an exported zero-argument function")
  }
}

/// Executes one loaded function through the platform isolation boundary.
pub fn run(loaded: LoadedTest, timeout_ms: Option(Int)) -> Isolated {
  isolate(loaded.body, timeout_ms)
}

/// Executes one loaded function and captures its stdout and stderr.
pub fn run_captured(
  loaded: LoadedTest,
  timeout_ms: Option(Int),
) -> CapturedIsolation {
  isolate_captured(loaded.body, timeout_ms)
}

@external(erlang, "kangaroo_runtime_ffi", "resolve_export")
@external(javascript, "../../kangaroo_runtime_ffi.mjs", "resolve_export")
fn resolve_export(
  module: String,
  function: String,
) -> Result(fn() -> Nil, String)

@external(erlang, "kangaroo_runtime_ffi", "reload_modules")
@external(javascript, "../../kangaroo_runtime_ffi.mjs", "reload_modules")
fn reload_modules(modules: List(String)) -> Result(Nil, String)
