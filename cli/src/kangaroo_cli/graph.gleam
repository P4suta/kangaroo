import gleam/list
import gleam/option.{None, Some, type Option}
import gleam/string

/// A Gleam module path such as `"gleam/list"` or `"myapp/foo"`.
pub type ModuleName {
  ModuleName(parts: List(String))
}

pub fn module_name(parts: List(String)) -> ModuleName {
  ModuleName(parts)
}

pub fn module_name_string(module: ModuleName) -> String {
  string.join(module.parts, "/")
}

pub fn module_name_of_file(path: String, extension: String) -> Option(ModuleName)
{
  case ends_with(path, extension) {
    False -> None
    True -> {
      let stem = string.slice(path, 0, string.length(path) - string.length(extension))
      let parts = string.split(stem, "/") |> list.filter(fn(p) { p != "" })
      case parts {
        ["src", ..rest] -> Some(ModuleName(rest))
        ["test", ..rest] -> Some(ModuleName(rest))
        _ -> Some(ModuleName(parts))
      }
    }
  }
}

fn ends_with(text: String, suffix: String) -> Bool {
  let text_len = string.length(text)
  let suffix_len = string.length(suffix)
  case text_len >= suffix_len {
    False -> False
    True ->
      string.slice(text, text_len - suffix_len, text_len) == suffix
  }
}

/// The modules a Gleam source file imports.
pub fn imports(source: String) -> List(ModuleName) {
  source
  |> string.split("\n")
  |> list.filter_map(import_line)
}

/// The source file (relative to the project root) of a module.
pub fn source_path(module: ModuleName, directory: String) -> String {
  let base = module_name_string(module)
  case directory {
    "src" -> "src/" <> base <> ".gleam"
    _ -> directory <> "/" <> base <> ".gleam"
  }
}

fn trim_braces(name: String) -> String {
  case string.split(name, "{") {
    [name, ..] ->
      name
      |> string.trim
      |> drop_trailing_dot
    [] -> name
  }
}

fn drop_trailing_dot(name: String) -> String {
  let len = string.length(name)
  case len > 0 && string.slice(name, len - 1, len) == "." {
    True -> string.slice(name, 0, len - 1)
    False -> name
  }
}

fn import_line(line: String) -> Result(ModuleName, Nil) {
  let trimmed = string.trim(line)
  case string.split(trimmed, " ") {
    ["import", module, ..] -> {
      let name = module
      |> string.trim
      |> trim_braces
      case string.starts_with(name, "gleam") {
        True -> Error(Nil)
        False -> {
          let name = case string.contains(name, "/") {
            False -> Error(Nil)
            True -> {
              let parts = string.split(name, "/")
              case list.all(parts, fn(p) { p != "" }) {
                True -> Ok(ModuleName(parts))
                False -> Error(Nil)
              }
            }
          }
          name
        }
      }
    }
    _ -> Error(Nil)
  }
}
