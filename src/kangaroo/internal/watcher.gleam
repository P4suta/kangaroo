import gleam/dict.{type Dict}
import gleam/list
import gleam/result
import gleam/string
import kangaroo/internal/fs

pub type Change {
  Added(path: String)
  Modified(path: String)
  Removed(path: String)
}

/// Compares content snapshots, so a write is detected even when its mtime and
/// byte length are unchanged. Results use normalised relative paths and are
/// lexical for reproducible watch/protocol output.
pub fn diff(
  previous: Dict(String, String),
  current: Dict(String, String),
) -> List(Change) {
  let previous = normalise(previous)
  let current = normalise(current)
  dict.keys(previous)
  |> list.append(dict.keys(current))
  |> list.unique
  |> list.sort(string.compare)
  |> list.filter_map(fn(path) {
    case dict.get(previous, path), dict.get(current, path) {
      Error(_), Ok(_) -> Ok(Added(path))
      Ok(old), Ok(new) if old != new -> Ok(Modified(path))
      Ok(_), Error(_) -> Ok(Removed(path))
      _, _ -> Error(Nil)
    }
  })
}

pub fn path(change: Change) -> String {
  case change {
    Added(path) | Modified(path) | Removed(path) -> path
  }
}

pub fn is_watched(path: String) -> Bool {
  let path = normalise_path(path)
  path == "gleam.toml"
  || path == "manifest.toml"
  || string.ends_with(path, ".gleam")
  || string.ends_with(path, ".erl")
  || string.ends_with(path, ".mjs")
  || string.ends_with(path, ".js")
  || string.ends_with(path, ".ts")
}

pub fn roots(
  test_paths: List(String),
  extra_paths: List(String),
) -> List(String) {
  ["src", ..list.append(test_paths, extra_paths)]
  |> list.map(normalise_path)
  |> list.filter(fn(path) { path != "" })
  |> list.unique
}

pub fn compile_arguments(target: String) -> List(String) {
  ["build", "--target", target]
}

pub fn run_arguments(target: String, arguments: List(String)) -> List(String) {
  list.append(["test", "--target", target, "--"], arguments)
}

/// Builds a child-generation command without silently switching JavaScript
/// runtimes. Gleam names Node `nodejs`, while runtime detection reports
/// `node`, so the spelling is normalised at this boundary.
pub fn run_arguments_for(
  target: String,
  runtime: String,
  arguments: List(String),
) -> List(String) {
  let prefix = case target {
    "javascript" -> [
      "test",
      "--target",
      target,
      "--runtime",
      case runtime {
        "node" -> "nodejs"
        value -> value
      },
      "--",
    ]
    _ -> ["test", "--target", target, "--"]
  }
  list.append(prefix, arguments)
}

/// Starts the long-lived coordinator through the public package module. Test
/// generations themselves use `gleam test`, but the coordinator must not be a
/// test command or it can retain the build lock needed by its child runs.
pub fn coordinator_arguments_for(
  target: String,
  runtime: String,
  arguments: List(String),
) -> List(String) {
  let runtime_arguments = case target {
    "javascript" -> [
      "--runtime",
      case runtime {
        "node" -> "nodejs"
        value -> value
      },
    ]
    _ -> []
  }
  ["run", "--target", target]
  |> list.append(runtime_arguments)
  |> list.append(["-m", "kangaroo", "--"])
  |> list.append(arguments)
}

/// Reads a complete content snapshot of watched roots. Content, rather than
/// timestamps, is the correctness boundary for atomic saves and coarse-mtime
/// filesystems.
pub fn snapshot_project(
  project_dir: String,
  roots: List(String),
) -> Result(Dict(String, String), String) {
  use files <- result.try(
    list.try_fold(roots, [], fn(files, root) {
      let absolute = join(project_dir, root)
      case fs.is_directory(absolute), fs.exists(absolute) {
        True, _ ->
          fs.list_files_recursive(absolute)
          |> result.map(fn(found) { list.append(files, found) })
        False, True -> Ok(list.append(files, [absolute]))
        False, False -> Ok(files)
      }
    }),
  )
  let config_files = ["gleam.toml", "manifest.toml"]
  let files =
    list.append(
      files,
      config_files
        |> list.map(fn(path) { join(project_dir, path) })
        |> list.filter(fs.exists),
    )
  files
  |> list.unique
  |> list.fold(Ok(dict.new()), fn(snapshot, absolute) {
    use snapshot <- result.try(snapshot)
    let relative = relative_to(project_dir, absolute)
    case is_watched(relative), fs.read_file(absolute) {
      True, Ok(contents) -> Ok(dict.insert(snapshot, relative, contents))
      True, Error(_) -> Ok(snapshot)
      False, _ -> Ok(snapshot)
    }
  })
}

pub fn normalise_path(path: String) -> String {
  path
  |> string.replace(each: "\\", with: "/")
  |> drop_dot
  |> collapse_slashes
}

fn normalise(snapshot: Dict(String, String)) -> Dict(String, String) {
  snapshot
  |> dict.to_list
  |> list.fold(dict.new(), fn(acc, entry) {
    dict.insert(acc, normalise_path(entry.0), entry.1)
  })
}

fn drop_dot(path: String) -> String {
  case string.starts_with(path, "./") {
    True -> drop_dot(string.drop_start(path, 2))
    False -> path
  }
}

fn collapse_slashes(path: String) -> String {
  case string.contains(path, "//") {
    True -> collapse_slashes(string.replace(path, each: "//", with: "/"))
    False -> path
  }
}

fn join(base: String, path: String) -> String {
  let base = trim_trailing_slashes(base)
  let path = normalise_path(path) |> trim_leading_slashes
  base <> "/" <> path
}

fn relative_to(project_dir: String, path: String) -> String {
  let project_dir = normalise_path(project_dir) |> trim_trailing_slashes
  let path = normalise_path(path)
  case string.starts_with(path, project_dir <> "/") {
    True -> string.drop_start(path, string.length(project_dir) + 1)
    False -> path
  }
}

fn trim_trailing_slashes(path: String) -> String {
  case string.ends_with(path, "/") {
    True ->
      path
      |> string.drop_end(1)
      |> trim_trailing_slashes
    False -> path
  }
}

fn trim_leading_slashes(path: String) -> String {
  case string.starts_with(path, "/") {
    True -> path |> string.drop_start(1) |> trim_leading_slashes
    False -> path
  }
}
