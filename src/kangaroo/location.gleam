import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// A source location inside a test or library module, derived from the
/// stack of a failed case. `column` is present when the platform reports
/// it (JavaScript does; Erlang stack traces carry only the line).
pub type Location {
  Location(file: String, line: Int, column: Option(Int))
}

/// Captures the location of the caller at the moment of the call, if it can
/// be determined. Erlang derives it from the stack of a synthetic throw;
/// JavaScript from `Error().stack`. Returns `None` when the caller is
/// framework code or the location cannot be parsed.
@external(erlang, "kangaroo_location_ffi", "capture")
@external(javascript, "../kangaroo_location_ffi.mjs", "capture")
pub fn capture() -> Option(Location)

/// Whether a stack frame belongs to the kangaroo framework (or the Gleam
/// runtime) rather than to the user's code. Framework frames are skipped
/// when locating the most relevant failure site.
///
/// The framework's modules can appear in stacks in two forms. When the
/// project runs its own tests, the `.gleam` sources are in the trace.
/// When the CLI executes the project's tests in its own VM, the framework
/// modules are loaded from the CLI's build — Gleam emits the `-file`
/// source attributes only for the main package, so those frames carry the
/// compiled `_gleam_artefacts/*.erl` paths instead.
pub fn is_framework_file(file: String) -> Bool {
  let file = normalise_path(file)
  string.starts_with(file, "src/kangaroo")
  || string.contains(file, "/src/kangaroo/")
  || string.ends_with(file, "/src/kangaroo.gleam")
  || string.starts_with(file, "src/gleam/")
  || string.starts_with(file, "gleam/")
  || string.starts_with(file, "node:")
  || !string.contains(file, "/")
  || string.contains(file, "gleam_stdlib")
  || string.contains(file, "gleam_erlang")
  || string.contains(file, "gleam_javascript")
  || string.contains(file, "gleam_json")
  || string.contains(file, "gleeunit")
  || string.contains(file, "prelude.mjs")
  || string.contains(file, "/build/dev/javascript/kangaroo/kangaroo/")
  || string.contains(file, "kangaroo_isolate_ffi")
  || string.contains(file, "kangaroo_context_ffi")
  || string.contains(file, "kangaroo_location_ffi")
  || string.contains(file, "kangaroo_print_ffi")
  || string.contains(file, "kangaroo_sys_ffi")
  || string.contains(file, "kangaroo_cli_ffi")
  // The compiled artefact form of the framework's own modules: the
  // module name itself (`kangaroo@...`, `kangaroo_cli@...`).
  || string.contains(file, "kangaroo@")
  || string.contains(file, "kangaroo_cli@")
  || string.contains(file, "/node_modules/")
}

/// The most relevant location from an Erlang stack trace text. Each line
/// has the form `file:line`; framework frames are skipped.
pub fn from_erlang_stack(stack: String) -> Option(Location) {
  first_user_frame(stack |> parse_locations(parse_file_line))
}

/// The most relevant location from a JavaScript stack trace text, as
/// produced by `Error.prototype.stack`. Framework frames are skipped.
pub fn from_js_stack(stack: String) -> Option(Location) {
  first_user_frame(stack |> parse_locations(js_frame_line))
}

fn parse_locations(
  stack: String,
  parse: fn(String) -> Result(Location, Nil),
) -> List(Location) {
  stack
  |> string.split("\n")
  |> list.filter_map(parse)
}

fn first_user_frame(locations: List(Location)) -> Option(Location) {
  case
    locations
    |> list.filter(fn(location) { !is_framework_file(location.file) })
  {
    [first, ..] -> Some(first)
    [] -> None
  }
}

/// Parses a line of the form `file:line:column` (or `file:line`) into a
/// location. The trailing column is kept when present.
fn parse_file_line(line: String) -> Result(Location, Nil) {
  let trimmed = string.trim(line)
  case string.split(trimmed, ":") {
    [] -> Error(Nil)
    [_] -> Error(Nil)
    parts ->
      case list.reverse(parts) {
        [column_text, line_text, ..rest] ->
          case int.parse(column_text), int.parse(line_text) {
            // A trailing column: the line number is the previous part.
            Ok(column), Ok(line) -> {
              let file = list.reverse(rest) |> string.join(":") |> string.trim
              valid_location(file, line, Some(column))
            }
            // A single trailing number is the line number itself.
            Ok(line), Error(_) -> {
              let file =
                parts
                |> list.take(list.length(parts) - 1)
                |> string.join(":")
                |> string.trim
              valid_location(file, line, None)
            }
            _, _ -> Error(Nil)
          }
        [line_text, ..] ->
          case int.parse(line_text) {
            Ok(line) -> {
              let file =
                parts
                |> list.take(list.length(parts) - 1)
                |> string.join(":")
                |> string.trim
              valid_location(file, line, None)
            }
            Error(_) -> Error(Nil)
          }
        _ -> Error(Nil)
      }
  }
}

/// Builds a location, rejecting empty files and non-positive lines (some
/// instrumentation reports line 0).
fn valid_location(
  file: String,
  line: Int,
  column: Option(Int),
) -> Result(Location, Nil) {
  let file = normalise_path(file)
  case file != "" && line > 0 {
    True -> Ok(Location(file, line, column))
    False -> Error(Nil)
  }
}

fn normalise_path(path: String) -> String {
  string.replace(path, each: "\\", with: "/")
}

/// Parses one frame of a JavaScript stack: a line like
/// `at functionName (file:line:column)` or `at file:line:column`.
fn js_frame_line(line: String) -> Result(Location, Nil) {
  let trimmed = string.trim(line)
  case string.starts_with(trimmed, "at ") {
    False -> Error(Nil)
    True -> {
      let rest = string.drop_start(trimmed, 3) |> string.trim
      let inside = case string.split(rest, "(") {
        [_, tail] ->
          case string.split(tail, ")") {
            [content, ..] -> string.trim(content)
            _ -> rest
          }
        _ -> rest
      }
      let file = case string.starts_with(inside, "file://") {
        True -> string.drop_start(inside, 7)
        False -> inside
      }
      parse_file_line(file)
    }
  }
}
