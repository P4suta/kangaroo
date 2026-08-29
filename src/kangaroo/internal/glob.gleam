import gleam/list
import gleam/string

/// Matches a normalised project-relative path against a small, portable glob
/// dialect. `**` spans path segments; `*` and `?` never cross `/`.
pub fn matches(pattern: String, path: String) -> Bool {
  match_segments(segments(pattern), segments(path))
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

fn match_segments(pattern: List(String), path: List(String)) -> Bool {
  case pattern, path {
    [], [] -> True
    [], _ -> False
    ["**", ..rest], [] -> match_segments(rest, [])
    ["**", ..rest] as whole, [_, ..path_rest] ->
      match_segments(rest, path) || match_segments(whole, path_rest)
    [pattern, ..pattern_rest], [value, ..path_rest] ->
      match_segment(string.to_graphemes(pattern), string.to_graphemes(value))
      && match_segments(pattern_rest, path_rest)
    _, _ -> False
  }
}

fn match_segment(pattern: List(String), value: List(String)) -> Bool {
  case pattern, value {
    [], [] -> True
    [], _ -> False
    ["*", ..rest], [] -> match_segment(rest, [])
    ["*", ..rest] as whole, [_, ..value_rest] ->
      match_segment(rest, value) || match_segment(whole, value_rest)
    ["?", ..pattern_rest], [_, ..value_rest] ->
      match_segment(pattern_rest, value_rest)
    [expected, ..pattern_rest], [actual, ..value_rest] if expected == actual ->
      match_segment(pattern_rest, value_rest)
    _, _ -> False
  }
}
