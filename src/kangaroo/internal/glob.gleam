import gleam/int
import gleam/list
import gleam/set.{type Set}
import gleam/string

/// Matches a normalised project-relative path against a small, portable glob
/// dialect. `**` spans path segments; `*` and `?` never cross `/`.
pub fn matches(pattern: String, path: String) -> Bool {
  let #(matched, _) =
    match_segments(segments(pattern), segments(path), 0, 0, set.new())
  matched
}

pub fn matches_any(patterns: List(String), path: String) -> Bool {
  list.any(patterns, fn(pattern) { matches(pattern, path) })
}

fn segments(path: String) -> List(String) {
  path
  |> string.replace(each: "\\", with: "/")
  |> string.remove_prefix("./")
  |> string.split("/")
  |> list.filter(fn(segment) { segment != "" })
}

fn match_segments(
  pattern: List(String),
  path: List(String),
  pattern_index: Int,
  path_index: Int,
  failed: Set(String),
) -> #(Bool, Set(String)) {
  let key = state_key(pattern_index, path_index)
  case set.contains(failed, key) {
    True -> #(False, failed)
    False -> {
      let result = case pattern, path {
        [], [] -> #(True, failed)
        [], _ -> #(False, failed)
        ["**", ..rest], [] ->
          match_segments(rest, [], pattern_index + 1, path_index, failed)
        ["**", ..rest] as whole, [_, ..path_rest] -> {
          let #(without_segment, failed) =
            match_segments(rest, path, pattern_index + 1, path_index, failed)
          case without_segment {
            True -> #(True, failed)
            False ->
              match_segments(
                whole,
                path_rest,
                pattern_index,
                path_index + 1,
                failed,
              )
          }
        }
        [pattern, ..pattern_rest], [value, ..path_rest] ->
          case
            match_segment(
              string.to_graphemes(pattern),
              string.to_graphemes(value),
            )
          {
            True ->
              match_segments(
                pattern_rest,
                path_rest,
                pattern_index + 1,
                path_index + 1,
                failed,
              )
            False -> #(False, failed)
          }
        _, _ -> #(False, failed)
      }
      remember_failure(result, key)
    }
  }
}

fn match_segment(pattern: List(String), value: List(String)) -> Bool {
  let #(matched, _) = match_segment_cached(pattern, value, 0, 0, set.new())
  matched
}

fn match_segment_cached(
  pattern: List(String),
  value: List(String),
  pattern_index: Int,
  value_index: Int,
  failed: Set(String),
) -> #(Bool, Set(String)) {
  let key = state_key(pattern_index, value_index)
  case set.contains(failed, key) {
    True -> #(False, failed)
    False -> {
      let result = case pattern, value {
        [], [] -> #(True, failed)
        [], _ -> #(False, failed)
        ["*", ..rest], [] ->
          match_segment_cached(rest, [], pattern_index + 1, value_index, failed)
        ["*", ..rest] as whole, [_, ..value_rest] -> {
          let #(without_character, failed) =
            match_segment_cached(
              rest,
              value,
              pattern_index + 1,
              value_index,
              failed,
            )
          case without_character {
            True -> #(True, failed)
            False ->
              match_segment_cached(
                whole,
                value_rest,
                pattern_index,
                value_index + 1,
                failed,
              )
          }
        }
        ["?", ..pattern_rest], [_, ..value_rest] ->
          match_segment_cached(
            pattern_rest,
            value_rest,
            pattern_index + 1,
            value_index + 1,
            failed,
          )
        [expected, ..pattern_rest], [actual, ..value_rest]
          if expected == actual
        ->
          match_segment_cached(
            pattern_rest,
            value_rest,
            pattern_index + 1,
            value_index + 1,
            failed,
          )
        _, _ -> #(False, failed)
      }
      remember_failure(result, key)
    }
  }
}

fn remember_failure(
  result: #(Bool, Set(String)),
  key: String,
) -> #(Bool, Set(String)) {
  case result.0 {
    True -> result
    False -> #(False, set.insert(result.1, key))
  }
}

fn state_key(first: Int, second: Int) -> String {
  int.to_string(first) <> ":" <> int.to_string(second)
}
