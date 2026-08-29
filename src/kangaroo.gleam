import gleam/io
import gleam/option.{None, Some}
import kangaroo/internal/cli
import kangaroo/internal/command
import kangaroo/internal/fs
import kangaroo/sys

/// Discovers and runs every public, zero-argument function ending in `_test`
/// below the configured test roots.
///
/// A project's complete test entry point is:
///
/// ```gleam
/// import kangaroo
///
/// pub fn main() {
///   kangaroo.main()
/// }
///
/// pub fn addition_test() {
///   assert 1 + 1 == 2
/// }
/// ```
///
/// `gleam test` remains the one-shot command. Continuous and integration
/// commands are selected from this same module with
/// `gleam run -m kangaroo -- <command>`.
pub fn main() -> Nil {
  case sys.env("KANGAROO_COMPILE_ONLY") {
    Some(_) -> fs.halt(0)
    None -> dispatch(fs.args())
  }
}

fn dispatch(args: List(String)) -> Nil {
  case command.parse(args), fs.current_dir() {
    Error(message), _ | _, Error(message) -> {
      io.println_error(message)
      fs.halt(2)
    }
    Ok(command), Ok(project_dir) ->
      case cli.execute(project_dir, command) {
        Ok(code) -> fs.halt(code)
        Error(message) -> {
          io.println_error("kangaroo: " <> message)
          fs.halt(2)
        }
      }
  }
}

/// Associates a literal tag with the containing test during source indexing.
/// At runtime it is intentionally a no-op.
@external(erlang, "kangaroo_helper_ffi", "metadata")
@external(javascript, "./kangaroo_helper_ffi.mjs", "metadata")
pub fn tag(name: String) -> Nil

/// Associates literal tags with the containing test during source indexing.
@external(erlang, "kangaroo_helper_ffi", "metadata")
@external(javascript, "./kangaroo_helper_ffi.mjs", "metadata")
pub fn tags(names: List(String)) -> Nil

/// Overrides the containing test's timeout during source indexing.
@external(erlang, "kangaroo_helper_ffi", "metadata")
@external(javascript, "./kangaroo_helper_ffi.mjs", "metadata")
pub fn timeout(milliseconds: Int) -> Nil

/// Marks the containing test as requiring serial scheduling.
@external(erlang, "kangaroo_helper_ffi", "serial")
@external(javascript, "./kangaroo_helper_ffi.mjs", "serial")
pub fn serial() -> Nil

/// Skips the containing test. Literal calls are handled without invocation by
/// source discovery; dynamic calls use a platform marker caught by isolation.
@external(erlang, "kangaroo_helper_ffi", "skip")
@external(javascript, "./kangaroo_helper_ffi.mjs", "skip")
pub fn skip(reason: String) -> a

/// Conditionally skips a test at runtime.
pub fn skip_if(condition: Bool, reason: String) -> Nil {
  case condition {
    True -> skip(reason)
    False -> Nil
  }
}

/// Acquires a resource, runs a body, and guarantees teardown after every body
/// outcome. If both body and teardown fail, the resulting failure retains both
/// causes.
@external(erlang, "kangaroo_helper_ffi", "fixture")
@external(javascript, "./kangaroo_helper_ffi.mjs", "fixture")
pub fn fixture(
  setup: fn() -> resource,
  teardown: fn(resource) -> Nil,
  body: fn(resource) -> result,
) -> result
