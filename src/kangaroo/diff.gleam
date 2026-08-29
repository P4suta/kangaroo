import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// A line-oriented diff between two texts, rendered as a unified-style
/// patch with `-` and `+` prefixes.
///
/// Returns `None` when the texts are identical or the diff is not useful
/// (e.g. both texts are a single line; the caller should show the values
/// themselves instead).
pub fn diff_lines(expected: String, actual: String) -> Option(String) {
  let expected_lines = lines(expected)
  let actual_lines = lines(actual)

  case expected_lines == actual_lines {
    True -> None
    False ->
      case list.length(expected_lines) < 2 && list.length(actual_lines) < 2 {
        True -> None
        False -> lines_diff(expected_lines, actual_lines)
      }
  }
}

fn lines(text: String) -> List(String) {
  let split = string.split(text, "\n")
  let reversed = list.reverse(split)

  case reversed {
    ["", ..rest] -> list.reverse(rest)
    _ -> split
  }
}

type Operation {
  Keep(String)
  Remove(String)
  Add(String)
}

/// A single line of a numbered diff: context lines carry the expected line
/// number, removed lines the expected line number, and added lines the
/// actual line number.
pub type DiffLine {
  Kept(number: Int, text: String)
  Removed(number: Int, text: String)
  Added(number: Int, text: String)
}

/// Like [`diff_lines`](#diff_lines), but keeps context lines and the
/// original line numbers so renderers can present a unified-style view.
/// Returns `None` when the texts are identical or both are a single line.
pub fn diff_lines_numbered(
  expected: String,
  actual: String,
) -> Option(List(DiffLine)) {
  let expected_lines = lines(expected)
  let actual_lines = lines(actual)

  case expected_lines == actual_lines {
    True -> None
    False ->
      case list.length(expected_lines) < 2 && list.length(actual_lines) < 2 {
        True -> None
        False -> lines_diff_numbered(expected_lines, actual_lines)
      }
  }
}

fn lines_diff_numbered(
  expected: List(String),
  actual: List(String),
) -> Option(List(DiffLine)) {
  let table = build_table(expected, actual)
  let expected_len = list.length(expected)
  let actual_len = list.length(actual)

  let operations =
    backtrace(table, expected, actual, expected_len, actual_len)
    |> list.reverse

  case operations {
    [] -> None
    _ -> Some(numbered(operations))
  }
}

/// Assigns the original line numbers to a list of operations in textual
/// order.
fn numbered(operations: List(Operation)) -> List(DiffLine) {
  let #(_, _, lines) =
    list.fold(operations, #(0, 0, []), fn(state, operation) {
      let #(expected, actual, acc) = state
      case operation {
        Keep(text) -> #(expected + 1, actual + 1, [
          Kept(expected + 1, text),
          ..acc
        ])
        Remove(text) -> #(expected + 1, actual, [
          Removed(expected + 1, text),
          ..acc
        ])
        Add(text) -> #(expected, actual + 1, [Added(actual + 1, text), ..acc])
      }
    })
  list.reverse(lines)
}

fn lines_diff(expected: List(String), actual: List(String)) -> Option(String) {
  let table = build_table(expected, actual)
  let expected_len = list.length(expected)
  let actual_len = list.length(actual)

  // The backtrace walks the table from the end of the texts towards the
  // beginning, so the operations come out in reverse textual order.
  let operations =
    backtrace(table, expected, actual, expected_len, actual_len)
    |> list.reverse

  case operations {
    [] -> None
    _ -> Some(render(operations))
  }
}

/// The dynamic programming table for the longest common subsequence of the
/// two line lists. `table[i][j]` is the length of the LCS of the first `i`
/// expected lines and the first `j` actual lines.
fn build_table(
  expected: List(String),
  actual: List(String),
) -> List(List(Int)) {
  let initial_row = list.repeat(0, list.length(actual) + 1)

  list.fold(expected, [initial_row], fn(rows, expected_line) {
    let previous_row = case rows {
      [first, ..] -> first
      [] -> initial_row
    }

    let reversed_row =
      list.index_fold(actual, [0], fn(reversed, actual_line, j) {
        let left = case reversed {
          [first, ..] -> first
          [] -> 0
        }

        let value = case expected_line == actual_line {
          True -> 1 + at(previous_row, j)
          False -> {
            let above = at(previous_row, j + 1)
            case left > above {
              True -> left
              False -> above
            }
          }
        }

        [value, ..reversed]
      })

    [list.reverse(reversed_row), ..rows]
  })
  |> list.reverse
}

fn at(row: List(Int), index: Int) -> Int {
  case nth(row, index) {
    Ok(value) -> value
    Error(_) -> 0
  }
}

fn nth(list: List(a), index: Int) -> Result(a, Nil) {
  case index, list {
    0, [first, ..] -> Ok(first)
    i, [_, ..rest] -> nth(rest, i - 1)
    _, [] -> Error(Nil)
  }
}

fn backtrace(
  table: List(List(Int)),
  expected: List(String),
  actual: List(String),
  i: Int,
  j: Int,
) -> List(Operation) {
  case i, j {
    0, 0 -> []
    _, 0 -> [
      Remove(expect_line(expected, i - 1)),
      ..backtrace(table, expected, actual, i - 1, 0)
    ]
    0, _ -> [
      Add(expect_line(actual, j - 1)),
      ..backtrace(table, expected, actual, 0, j - 1)
    ]
    _, _ -> {
      let expected_line = expect_line(expected, i - 1)
      let actual_line = expect_line(actual, j - 1)
      let current = at(expect_row(table, i), j)
      let diagonal = at(expect_row(table, i - 1), j - 1)

      case expected_line, actual_line, diagonal + 1 == current {
        a, b, True if a == b -> [
          Keep(a),
          ..backtrace(table, expected, actual, i - 1, j - 1)
        ]
        _, _, _ -> {
          let above = at(expect_row(table, i - 1), j)
          let left = at(expect_row(table, i), j - 1)

          case above > left {
            True -> [
              Remove(expected_line),
              ..backtrace(table, expected, actual, i - 1, j)
            ]
            False -> [
              Add(actual_line),
              ..backtrace(table, expected, actual, i, j - 1)
            ]
          }
        }
      }
    }
  }
}

fn expect_line(lines: List(String), index: Int) -> String {
  case nth(lines, index) {
    Ok(line) -> line
    Error(_) -> panic as "index out of bounds in diff"
  }
}

fn expect_row(table: List(List(Int)), index: Int) -> List(Int) {
  case nth(table, index) {
    Ok(row) -> row
    Error(_) -> panic as "index out of bounds in diff"
  }
}

fn render(operations: List(Operation)) -> String {
  operations
  |> list.filter_map(fn(operation) {
    case operation {
      Keep(_) -> Error(Nil)
      Remove(line) -> Ok("- " <> line)
      Add(line) -> Ok("+ " <> line)
    }
  })
  |> string.join("\n")
}
