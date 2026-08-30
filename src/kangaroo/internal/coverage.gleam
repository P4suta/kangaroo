import gleam/float
import gleam/int
import gleam/list
import gleam/string

/// Normalised Gleam source coverage. Both line lists are one-based and the
/// covered lines must be a subset of executable lines.
pub type FileCoverage {
  FileCoverage(
    path: String,
    executable_lines: List(Int),
    covered_lines: List(Int),
  )
}

pub fn module_for_path(path: String) -> Result(String, String) {
  let path = string.replace(path, each: "\\", with: "/")
  case path {
    "src/" <> relative -> {
      case string.ends_with(relative, ".gleam") {
        False -> Error("coverage source must be below src and end in .gleam")
        True -> {
          let module = string.remove_suffix(relative, ".gleam")
          case module {
            "" -> Error("coverage source path has no module name")
            _ -> Ok(module)
          }
        }
      }
    }
    _ -> Error("coverage source must be below src and end in .gleam")
  }
}

pub fn from_hits(path: String, hits: List(#(Int, Int))) -> FileCoverage {
  let executable = hits |> list.map(fn(hit) { hit.0 }) |> normalise_lines
  let covered =
    hits
    |> list.filter_map(fn(hit) {
      case hit.0 > 0 && hit.1 > 0 {
        True -> Ok(hit.0)
        False -> Error(Nil)
      }
    })
  FileCoverage(path, executable, normalise_lines(covered))
}

/// Decodes the append-only probe stream written by isolated runtime workers.
/// Duplicate hits are retained here and normalised only when building the
/// final file report, keeping parsing independent from aggregation.
pub fn parse_hits(contents: String) -> Result(List(#(String, Int)), String) {
  contents
  |> string.split("\n")
  |> parse_hit_lines(1, [])
}

fn parse_hit_lines(
  lines: List(String),
  line_number: Int,
  hits: List(#(String, Int)),
) -> Result(List(#(String, Int)), String) {
  case lines {
    [] -> Ok(list.reverse(hits))
    ["", ..rest] -> parse_hit_lines(rest, line_number + 1, hits)
    [record, ..rest] ->
      case string.split(record, "\t") {
        [path, raw_line] if path != "" ->
          case int.parse(raw_line) {
            Ok(line) if line > 0 ->
              parse_hit_lines(rest, line_number + 1, [#(path, line), ..hits])
            _ -> invalid_hit(line_number)
          }
        _ -> invalid_hit(line_number)
      }
  }
}

fn invalid_hit(line: Int) -> Result(a, String) {
  Error("invalid coverage probe record on line " <> int.to_string(line))
}

/// Applies runtime hits to the complete executable-source inventory. Unknown
/// paths and non-executable lines are intentionally ignored.
pub fn with_hits(
  files: List(FileCoverage),
  hits: List(#(String, Int)),
) -> List(FileCoverage) {
  list.map(files, fn(file) {
    let covered =
      hits
      |> list.filter_map(fn(hit) {
        case hit.0 == file.path && list.contains(file.executable_lines, hit.1) {
          True -> Ok(hit.1)
          False -> Error(Nil)
        }
      })
    FileCoverage(
      path: file.path,
      executable_lines: normalise_lines(file.executable_lines),
      covered_lines: normalise_lines(covered),
    )
  })
}

pub fn file_percentage(file: FileCoverage) -> Int {
  let executable = normalise_lines(file.executable_lines)
  let covered = covered_executable(file)
  case list.length(executable) {
    0 -> 100
    total -> list.length(covered) * 100 / total
  }
}

pub fn percentage(files: List(FileCoverage)) -> Int {
  let total =
    list.fold(files, 0, fn(total, file) {
      total + list.length(normalise_lines(file.executable_lines))
    })
  let covered =
    list.fold(files, 0, fn(total, file) {
      total + list.length(covered_executable(file))
    })
  case total {
    0 -> 100
    _ -> covered * 100 / total
  }
}

pub fn violations(
  files: List(FileCoverage),
  minimum: Int,
  minimum_per_file: Int,
) -> List(String) {
  let overall = percentage(files)
  let overall_failures = case overall < minimum {
    True -> [
      "overall coverage "
      <> int.to_string(overall)
      <> "% is below "
      <> int.to_string(minimum)
      <> "%",
    ]
    False -> []
  }
  list.fold(files, overall_failures, fn(failures, file) {
    let actual = file_percentage(file)
    case actual < minimum_per_file {
      True ->
        list.append(failures, [
          file.path
          <> " coverage "
          <> int.to_string(actual)
          <> "% is below "
          <> int.to_string(minimum_per_file)
          <> "%",
        ])
      False -> failures
    }
  })
}

pub fn terminal(files: List(FileCoverage)) -> String {
  let rows =
    list.map(files, fn(file) {
      let executable = list.length(normalise_lines(file.executable_lines))
      let covered = list.length(covered_executable(file))
      file.path
      <> "  "
      <> int.to_string(file_percentage(file))
      <> "% ("
      <> int.to_string(covered)
      <> "/"
      <> int.to_string(executable)
      <> " lines)"
    })
  string.join(
    list.append(rows, ["TOTAL  " <> int.to_string(percentage(files)) <> "%"]),
    "\n",
  )
}

pub fn lcov(files: List(FileCoverage)) -> String {
  files
  |> list.map(fn(file) {
    let executable = normalise_lines(file.executable_lines)
    let covered = covered_executable(file)
    let records =
      executable
      |> list.map(fn(line) {
        "DA:"
        <> int.to_string(line)
        <> ","
        <> case list.contains(covered, line) {
          True -> "1"
          False -> "0"
        }
      })
    "TN:\nSF:"
    <> file.path
    <> "\n"
    <> string.join(records, "\n")
    <> case records {
      [] -> ""
      _ -> "\n"
    }
    <> "LF:"
    <> int.to_string(list.length(executable))
    <> "\nLH:"
    <> int.to_string(list.length(covered))
    <> "\nend_of_record"
  })
  |> string.join("\n")
  |> fn(output) { output <> "\n" }
}

pub fn cobertura(files: List(FileCoverage)) -> String {
  let total_lines =
    list.fold(files, 0, fn(total, file) {
      total + list.length(normalise_lines(file.executable_lines))
    })
  let covered_lines =
    list.fold(files, 0, fn(total, file) {
      total + list.length(covered_executable(file))
    })
  let classes = files |> list.map(cobertura_class) |> string.join("\n")
  "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
  <> "<coverage line-rate=\""
  <> rate(covered_lines, total_lines)
  <> "\" lines-covered=\""
  <> int.to_string(covered_lines)
  <> "\" lines-valid=\""
  <> int.to_string(total_lines)
  <> "\" version=\"kangaroo-1\">\n"
  <> "  <sources><source>.</source></sources>\n"
  <> "  <packages><package name=\"gleam\" line-rate=\""
  <> rate(covered_lines, total_lines)
  <> "\"><classes>\n"
  <> classes
  <> "\n  </classes></package></packages>\n</coverage>\n"
}

fn cobertura_class(file: FileCoverage) -> String {
  let executable = normalise_lines(file.executable_lines)
  let covered = covered_executable(file)
  let lines =
    executable
    |> list.map(fn(line) {
      "        <line number=\""
      <> int.to_string(line)
      <> "\" hits=\""
      <> case list.contains(covered, line) {
        True -> "1"
        False -> "0"
      }
      <> "\"/>"
    })
  "      <class name=\""
  <> xml(file.path)
  <> "\" filename=\""
  <> xml(file.path)
  <> "\" line-rate=\""
  <> rate(list.length(covered), list.length(executable))
  <> "\"><methods/><lines>\n"
  <> string.join(lines, "\n")
  <> "\n      </lines></class>"
}

fn covered_executable(file: FileCoverage) -> List(Int) {
  let executable = normalise_lines(file.executable_lines)
  file.covered_lines
  |> normalise_lines
  |> list.filter(fn(line) { list.contains(executable, line) })
}

fn normalise_lines(lines: List(Int)) -> List(Int) {
  lines
  |> list.filter(fn(line) { line > 0 })
  |> list.unique
  |> list.sort(int.compare)
}

fn rate(covered: Int, total: Int) -> String {
  case total {
    0 -> "1.0"
    _ ->
      covered
      |> int.to_float
      |> fn(value) { value /. int.to_float(total) }
      |> float.to_string
  }
}

fn xml(value: String) -> String {
  value
  |> string.replace(each: "&", with: "&amp;")
  |> string.replace(each: "<", with: "&lt;")
  |> string.replace(each: ">", with: "&gt;")
  |> string.replace(each: "\"", with: "&quot;")
  |> string.replace(each: "'", with: "&apos;")
}
