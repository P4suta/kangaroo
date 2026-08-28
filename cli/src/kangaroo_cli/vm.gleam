import gleam/list
import gleam/result
import gleam/string
import kangaroo/suite.{type Suite}
import kangaroo_cli/fs

/// Erlang-only execution engine. On JavaScript every function returns an
/// error and the CLI falls back to running `gleam test` as a subprocess.

/// Whether this build of the CLI runs on Erlang.
@external(erlang, "kangaroo_cli_ffi", "is_erlang")
@external(javascript, "../kangaroo_cli_ffi.mjs", "is_erlang")
pub fn is_erlang() -> Bool

/// Adds a directory to the Erlang code path.
@external(erlang, "kangaroo_cli_ffi", "add_code_path")
@external(javascript, "../kangaroo_cli_ffi.mjs", "not_supported")
pub fn add_code_path(directory: String) -> Result(Nil, String)

/// Adds every package ebin under the project's build directory to the code
/// path, with the project's own package taking priority.
@external(erlang, "kangaroo_cli_ffi", "add_project_paths")
@external(javascript, "../kangaroo_cli_ffi.mjs", "not_supported")
pub fn add_project_paths(project_dir: String) -> Result(Nil, String)

/// Loads a compiled module (by name, e.g. `"foo_test"` or `"a/b"`),
/// purging any previous version first.
@external(erlang, "kangaroo_cli_ffi", "load_module")
@external(javascript, "../kangaroo_cli_ffi.mjs", "not_supported")
pub fn load_module(name: String) -> Result(Nil, String)

/// Calls `suites()` on a loaded test module, returning its suites.
@external(erlang, "kangaroo_cli_ffi", "call_suites")
@external(javascript, "../kangaroo_cli_ffi.mjs", "not_supported")
pub fn call_suites(module: String) -> Result(List(Suite), String)

/// Lists the `*_test` modules compiled into a project's ebin directory.
@external(erlang, "kangaroo_cli_ffi", "list_test_modules")
@external(javascript, "../kangaroo_cli_ffi.mjs", "not_supported")
pub fn list_test_modules(project_dir: String) -> Result(List(String), String)

/// The project's own ebin directory under `build/dev/erlang/<name>`.
pub fn ebin_dir(project_dir: String) -> Result(String, String) {
  use name <- result.try(package_name(project_dir))
  Ok(project_dir <> "/build/dev/erlang/" <> name <> "/ebin")
}

/// The project's package name, read from `gleam.toml`.
pub fn package_name(project_dir: String) -> Result(String, String) {
  use contents <- result.try(fs.read_file(project_dir <> "/gleam.toml"))
  parse_name(contents)
}

fn parse_name(toml: String) -> Result(String, String) {
  toml
  |> string.split("\n")
  |> list.find_map(fn(line) {
    case line |> string.trim |> string.split("=") {
      ["name", value] -> {
        let value = value |> string.trim |> trim_quotes
        case value {
          "" -> Error(Nil)
          _ -> Ok(value)
        }
      }
      _ -> Error(Nil)
    }
  })
  |> result.map_error(fn(_) { "could not find a package name in gleam.toml" })
}

fn trim_quotes(value: String) -> String {
  let value = string.trim(value)
  let len = string.length(value)
  case len >= 2 && string.slice(value, 0, 1) == "\"" {
    True -> string.slice(value, 1, len - 1)
    False -> value
  }
}
