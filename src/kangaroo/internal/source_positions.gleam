import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/string

pub type Position {
  Position(line: Int, column: Int)
}

/// Locates sorted or unsorted UTF-8 byte offsets with one traversal of the
/// source. Offsets outside the source are clamped to its nearest endpoint.
pub fn locate(source: String, byte_offsets: List(Int)) -> Dict(Int, Position) {
  let targets =
    byte_offsets
    |> list.sort(int.compare)
    |> list.unique
  locate_loop(string.to_utf_codepoints(source), targets, 0, 1, 1, dict.new())
}

fn locate_loop(codepoints, targets, offset, line, column, positions) {
  case targets {
    [] -> positions
    [target, ..rest] if offset >= target ->
      locate_loop(
        codepoints,
        rest,
        offset,
        line,
        column,
        dict.insert(positions, target, Position(line, column)),
      )
    [_, ..] ->
      case codepoints {
        [] ->
          list.fold(targets, positions, fn(positions, target) {
            dict.insert(positions, target, Position(line, column))
          })
        [codepoint, ..rest] -> {
          let value = string.utf_codepoint_to_int(codepoint)
          let offset = offset + utf8_size(value)
          case value == 10 {
            True -> locate_loop(rest, targets, offset, line + 1, 1, positions)
            False ->
              locate_loop(rest, targets, offset, line, column + 1, positions)
          }
        }
      }
  }
}

fn utf8_size(codepoint: Int) -> Int {
  case codepoint {
    value if value <= 0x7f -> 1
    value if value <= 0x7ff -> 2
    value if value <= 0xffff -> 3
    _ -> 4
  }
}
