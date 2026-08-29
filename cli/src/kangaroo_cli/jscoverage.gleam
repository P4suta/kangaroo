import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import kangaroo_cli/coverage.{type ModuleCoverage, ModuleCoverage, line_count}

/// V8 coverage (`NODE_V8_COVERAGE`) support for the JavaScript target.
///
/// Coverage files report character offsets within the generated `.mjs`
/// files; these are mapped back to line numbers, and modules are derived
/// from the script URLs. Line offsets are counted in graphemes, which
/// matches V8's UTF-16 code units for most sources.
/// A decoded coverage script: its URL and its counted ranges
/// `#(start, end, count)` in character offsets.
pub type Script {
  Script(url: String, ranges: List(#(Int, Int, Int)))
}

/// Decodes one V8 coverage JSON document.
pub fn decode_coverage(contents: String) -> Result(List(Script), String) {
  json.parse(contents, using: coverage_decoder())
  |> result.map_error(fn(_) { "could not parse V8 coverage output" })
}

fn coverage_decoder() -> decode.Decoder(List(Script)) {
  decode.field("result", decode.list(script_decoder()), fn(scripts) {
    decode.success(scripts)
  })
}

fn script_decoder() -> decode.Decoder(Script) {
  decode.field("url", decode.string, fn(url) {
    decode.field("functions", decode.list(ranges_of_decoder()), fn(lists) {
      decode.success(Script(url, list.flatten(lists)))
    })
  })
}

fn ranges_of_decoder() -> decode.Decoder(List(#(Int, Int, Int))) {
  decode.field("ranges", decode.list(range_decoder()), fn(ranges) {
    decode.success(ranges)
  })
}

fn range_decoder() -> decode.Decoder(#(Int, Int, Int)) {
  decode.field("startOffset", decode.int, fn(start) {
    decode.field("endOffset", decode.int, fn(end) {
      decode.field("count", decode.int, fn(count) {
        decode.success(#(start, end, count))
      })
    })
  })
}

/// The character offset of the start of every line (1-based line numbers).
pub fn line_starts(source: String) -> List(Int) {
  let final =
    list.fold(string.to_graphemes(source), #(0, [0]), fn(acc, g) {
      let #(offset, lines) = acc
      case g {
        "\n" -> #(offset + 1, [offset + 1, ..lines])
        _ -> #(offset + 1, lines)
      }
    })
  list.reverse(final.1)
}

/// The 1-based line numbers of `source` that fall inside at least one
/// counted range.
pub fn covered_lines(
  source: String,
  ranges: List(#(Int, Int, Int)),
) -> List(Int) {
  let starts = line_starts(source)
  let counted = list.filter(ranges, fn(r) { r.2 > 0 })

  let lines =
    list.index_fold(starts, [], fn(acc, start, index) {
      let line = index + 1
      let end = case nth(starts, index + 1) {
        Ok(end) -> end
        Error(_) -> string.length(source)
      }
      case list.any(counted, fn(r) { r.0 < end && r.1 > start }) {
        True -> [line, ..acc]
        False -> acc
      }
    })
  list.reverse(lines)
}

/// The module name for a coverage script URL: the path after
/// `build/dev/javascript/` without the `.mjs` extension. Returns `None`
/// for scripts outside the project's build output.
pub fn module_from_url(url: String) -> Option(String) {
  let marker = "build/dev/javascript/"
  case string.split(url, marker) {
    [_, path] -> {
      let module = drop_suffix(path, ".mjs")
      case module {
        "" -> None
        _ -> Some(module)
      }
    }
    _ -> None
  }
}

/// Summarises coverage for a module.
pub fn summarise(
  module: String,
  source: String,
  ranges: List(#(Int, Int, Int)),
) -> ModuleCoverage {
  ModuleCoverage(
    module,
    list.length(covered_lines(source, ranges)),
    line_count(source),
  )
}

/// Whether the script lives in the project's own build directory, i.e. the
/// first path segment after `build/dev/javascript/` is the package name.
pub fn in_project(url: String, package: String) -> Bool {
  let marker = "build/dev/javascript/"
  case string.split(url, marker) {
    [_, path] ->
      case string.split(path, "/") {
        [first, ..] -> first == package
        [] -> False
      }
    _ -> False
  }
}

/// The local filesystem path of a script URL.
pub fn local_path(url: String) -> String {
  case string.starts_with(url, "file://") {
    True -> string.slice(url, 7, string.length(url) - 7)
    False -> url
  }
}

fn drop_suffix(text: String, suffix: String) -> String {
  let text_len = string.length(text)
  let suffix_len = string.length(suffix)
  case
    text_len >= suffix_len
    && string.slice(text, text_len - suffix_len, suffix_len) == suffix
  {
    True -> string.slice(text, 0, text_len - suffix_len)
    False -> text
  }
}

fn nth(list: List(a), index: Int) -> Result(a, Nil) {
  case index, list {
    0, [first, ..] -> Ok(first)
    i, [_, ..rest] -> nth(rest, i - 1)
    _, [] -> Error(Nil)
  }
}
