import gleam/int
import gleam/list
import gleam/string
import kangaroo/internal/index.{type IndexedTest}

pub type Selector {
  Path(path: String)
  Location(path: String, line: Int)
  Id(id: String)
  Tag(name: String)
}

/// Parses the stable selector syntax accepted by the CLI and daemon.
pub fn parse(value: String) -> Result(Selector, String) {
  let value = normalise(value)
  case string.trim(value) == "" {
    True -> Error("selector cannot be empty")
    False ->
      case string.starts_with(value, "-"), value {
        True, _ -> Error("selector cannot start with '-'")
        _, "tag:" -> Error("tag selector cannot be empty")
        _, "tag:" <> name ->
          case string.trim(name) == "" {
            True -> Error("tag selector cannot be empty")
            False -> Ok(Tag(name))
          }
        _, _ ->
          case string.contains(value, "::") {
            True -> Ok(Id(value))
            False -> parse_path_or_location(value)
          }
      }
  }
}

fn parse_path_or_location(value: String) -> Result(Selector, String) {
  case value |> string.split(":") |> list.reverse {
    [line, ..reversed_path] if reversed_path != [] ->
      case int.parse(line) {
        Ok(line) if line > 0 -> {
          let path = reversed_path |> list.reverse |> string.join(":")
          Ok(Location(path, line))
        }
        _ -> Ok(Path(value))
      }
    _ -> Ok(Path(value))
  }
}

/// Selects tests while preserving the discovery order.
///
/// Explicit selectors and include tags are each OR sets. When both are
/// supplied a test must satisfy both groups. Any excluded tag wins over every
/// include or explicit selector.
pub fn select(
  tests: List(IndexedTest),
  selectors: List(Selector),
  include_tags: List(String),
  exclude_tags: List(String),
) -> List(IndexedTest) {
  list.filter(tests, fn(indexed) {
    let selected = case selectors {
      [] -> True
      _ -> list.any(selectors, fn(selector) { matches(indexed, selector) })
    }
    let included = case include_tags {
      [] -> True
      _ -> has_any_tag(indexed, include_tags)
    }
    let excluded = has_any_tag(indexed, exclude_tags)
    selected && included && !excluded
  })
}

fn matches(indexed: IndexedTest, selector: Selector) -> Bool {
  case selector {
    Id(id) -> indexed.id == id
    Tag(name) -> list.contains(indexed.tags, name)
    Location(path, line) ->
      indexed.path == normalise(path)
      && line >= indexed.line
      && line <= indexed.end_line
    Path(path) -> {
      let path = normalise(path)
      indexed.path == path
      || {
        !string.ends_with(path, ".gleam")
        && string.starts_with(indexed.path, string.trim_end(path) <> "/")
      }
    }
  }
}

fn has_any_tag(indexed: IndexedTest, tags: List(String)) -> Bool {
  list.any(tags, fn(tag) { list.contains(indexed.tags, tag) })
}

fn normalise(value: String) -> String {
  value
  |> string.replace(each: "\\", with: "/")
  |> string.remove_prefix("./")
  |> trim_trailing_slashes
}

fn trim_trailing_slashes(path: String) -> String {
  case path {
    "" | "/" -> path
    _ ->
      case string.ends_with(path, "/") {
        True -> trim_trailing_slashes(string.remove_suffix(path, "/"))
        False -> path
      }
  }
}
