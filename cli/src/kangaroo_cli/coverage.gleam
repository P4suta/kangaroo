import gleam/int
import gleam/list
import gleam/string

/// Line coverage for a single module.
pub type ModuleCoverage {
  ModuleCoverage(module: String, covered: Int, total: Int)
}

/// Summarises raw `cover` line hits for one module.
///
/// `lines_in_file` is the number of lines in the `.gleam` source; hits
/// beyond it come from generated code and are ignored.
pub fn summarise(
  module: String,
  lines_in_file: Int,
  hits: List(#(Int, Int)),
) -> ModuleCoverage {
  let within = list.filter(hits, fn(hit) { hit.0 <= lines_in_file })
  let total = list.length(within)
  let covered = list.count(within, fn(hit) { hit.1 > 0 })
  ModuleCoverage(module, covered, total)
}

/// The percentage of covered lines across modules, rounded down.
pub fn percentage(modules: List(ModuleCoverage)) -> Int {
  let total = list.fold(modules, 0, fn(acc, m) { acc + m.total })
  let covered = list.fold(modules, 0, fn(acc, m) { acc + m.covered })
  case total {
    0 -> 100
    _ -> covered * 100 / total
  }
}

/// A table row for the terminal output.
pub fn table_row(module: ModuleCoverage) -> String {
  let percent = case module.total {
    0 -> 100
    _ -> module.covered * 100 / module.total
  }
  module.module
  <> "  "
  <> int.to_string(percent)
  <> "% ("
  <> int.to_string(module.covered)
  <> "/"
  <> int.to_string(module.total)
  <> " lines)"
}

/// The number of lines in a source file.
pub fn line_count(source: String) -> Int {
  case source {
    "" -> 0
    _ -> string.split(source, "\n") |> list.length
  }
}
