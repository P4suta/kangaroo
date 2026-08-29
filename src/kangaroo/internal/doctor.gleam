import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Status {
  Passed
  Warning
  Failed
}

pub type Check {
  Check(name: String, status: Status, detail: String, fix: Option(String))
}

pub fn version_at_least(actual: String, minimum: String) -> Bool {
  case version(actual), version(minimum) {
    Ok(actual), Ok(minimum) -> compare_version(actual, minimum)
    _, _ -> False
  }
}

pub fn minimum_runtime_version(name: String) -> String {
  case name {
    "erlang" -> "27.0.0"
    // Loading generated `.mjs` exports synchronously is enabled by default
    // from Node 22.12 onward.
    "node" -> "22.12.0"
    "bun" -> "1.4.0"
    "deno" -> "2.9.0"
    _ -> "999.0.0"
  }
}

pub fn render(checks: List(Check)) -> String {
  checks
  |> list.map(fn(check) {
    let line =
      status_name(check.status) <> " " <> check.name <> ": " <> check.detail
    case check.fix {
      Some(fix) -> line <> "\n  fix: " <> fix
      None -> line
    }
  })
  |> string.join("\n")
}

pub fn exit_code(checks: List(Check)) -> Int {
  case list.any(checks, fn(check) { check.status == Failed }) {
    True -> 2
    False -> 0
  }
}

/// Turns the read-only coverage source validation into a doctor check. The
/// reported line locations come directly from the Gleam AST, so this does not
/// depend on target-specific generated-code mappings.
pub fn coverage_instrumentation_check(
  validation: Result(Int, String),
) -> Check {
  case validation {
    Ok(count) ->
      Check(
        "coverage instrumentation",
        Passed,
        int.to_string(count)
          <> " Gleam source files can be instrumented exactly",
        None,
      )
    Error(message) ->
      Check(
        "coverage instrumentation",
        Failed,
        message,
        Some("fix the reported Gleam source before running coverage"),
      )
  }
}

fn status_name(status: Status) -> String {
  case status {
    Passed -> "PASS"
    Warning -> "WARN"
    Failed -> "FAIL"
  }
}

fn version(value: String) -> Result(#(Int, Int, Int), Nil) {
  let numeric =
    value
    |> string.to_graphemes
    |> drop_until_digit
    |> string.concat
  let components = string.split(numeric, ".")
  use major <- result_int(component(components, 0))
  let minor = component(components, 1) |> result.unwrap(0)
  let patch = component(components, 2) |> result.unwrap(0)
  Ok(#(major, minor, patch))
}

fn component(parts: List(String), index: Int) -> Result(Int, Nil) {
  use part <- result.try(nth(parts, index))
  part
  |> string.to_graphemes
  |> take_digits
  |> string.concat
  |> int.parse
  |> result.map_error(fn(_) { Nil })
}

fn nth(values: List(a), index: Int) -> Result(a, Nil) {
  case values, index {
    [first, ..], 0 -> Ok(first)
    [_, ..rest], index if index > 0 -> nth(rest, index - 1)
    _, _ -> Error(Nil)
  }
}

fn result_int(
  result: Result(Int, Nil),
  next: fn(Int) -> Result(a, Nil),
) -> Result(a, Nil) {
  case result {
    Ok(value) -> next(value)
    Error(_) -> Error(Nil)
  }
}

fn drop_until_digit(graphemes: List(String)) -> List(String) {
  case graphemes {
    [] -> []
    [first, ..rest] ->
      case int.parse(first) {
        Ok(_) -> graphemes
        Error(_) -> drop_until_digit(rest)
      }
  }
}

fn take_digits(graphemes: List(String)) -> List(String) {
  case graphemes {
    [] -> []
    [first, ..rest] ->
      case int.parse(first) {
        Ok(_) -> [first, ..take_digits(rest)]
        Error(_) -> []
      }
  }
}

fn compare_version(
  actual: #(Int, Int, Int),
  minimum: #(Int, Int, Int),
) -> Bool {
  actual.0 > minimum.0
  || {
    actual.0 == minimum.0
    && {
      actual.1 > minimum.1 || { actual.1 == minimum.1 && actual.2 >= minimum.2 }
    }
  }
}
