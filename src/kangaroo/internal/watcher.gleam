import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import kangaroo/internal/config
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

/// Compiles the project test entrypoint in a short-lived runtime. The
/// `KANGAROO_COMPILE_ONLY` guard makes `kangaroo.main` exit before discovery
/// or execution, while `gleam test` still asks the compiler to emit every
/// module below `test/`.
pub fn compile_arguments(target: String, runtime: String) -> List(String) {
  case target {
    "javascript" -> [
      "test",
      "--target",
      target,
      "--runtime",
      case runtime {
        "node" -> "nodejs"
        value -> value
      },
    ]
    _ -> ["test", "--target", target]
  }
}

pub fn compile_environment() -> List(#(String, String)) {
  [#("KANGAROO_COMPILE_ONLY", "1")]
}

/// Returns compiler products whose timestamp-only cache keys can be stale
/// after an atomic save. Gleam source modules need only lose their metadata;
/// the compiler then recompiles the module and its affected dependants. Native
/// files are copied separately, so their target copy is removed as well.
pub fn stale_build_files(
  project_dir: String,
  package_name: String,
  target: String,
  changes: List(Change),
) -> List(String) {
  let package = join(project_dir, "build/dev/" <> target <> "/" <> package_name)
  changes
  |> list.flat_map(fn(change) {
    stale_files_for_change(package, target, change)
  })
  |> list.unique
}

/// Invalidates the narrow compiler cache boundary before a settled watch
/// generation is compiled. This leaves dependency builds intact and never
/// changes user source metadata.
pub fn invalidate_stale_build_files(
  project_dir: String,
  target: String,
  changes: List(Change),
) -> Result(Nil, String) {
  use source <- result.try(fs.read_file(join(project_dir, "gleam.toml")))
  use package_name <- result.try(config.package_name(source))
  stale_build_files(project_dir, package_name, target, changes)
  |> list.try_each(fs.remove_file)
}

fn stale_files_for_change(
  package: String,
  target: String,
  change: Change,
) -> List(String) {
  let path = change |> path |> normalise_path
  case source_relative(path), native_relative(path, target), change {
    Some(relative), _, Modified(_) -> [module_metadata(package, relative)]
    Some(relative), _, Removed(_) ->
      removed_module_files(package, target, relative)
    _, Some(relative), Modified(_) | _, Some(relative), Removed(_) -> [
      join(package, relative),
    ]
    _, _, _ -> []
  }
}

fn source_relative(path: String) -> Option(String) {
  case path {
    "src/" <> relative | "test/" <> relative ->
      case string.ends_with(relative, ".gleam") {
        True -> Some(relative)
        False -> None
      }
    _ -> None
  }
}

fn native_relative(path: String, target: String) -> Option(String) {
  let relative = case path {
    "src/" <> relative | "test/" <> relative -> Some(relative)
    _ -> None
  }
  case relative, target {
    Some(relative), "javascript" ->
      case
        string.ends_with(relative, ".mjs")
        || string.ends_with(relative, ".js")
        || string.ends_with(relative, ".ts")
      {
        True -> Some(relative)
        False -> None
      }
    Some(relative), "erlang" ->
      case string.ends_with(relative, ".erl") {
        True -> Some(relative)
        False -> None
      }
    _, _ -> None
  }
}

fn module_metadata(package: String, relative: String) -> String {
  join(
    package,
    "_gleam_artefacts/" <> module_artifact(relative) <> ".cache_meta",
  )
}

fn removed_module_files(
  package: String,
  target: String,
  relative: String,
) -> List(String) {
  let artifact = module_artifact(relative)
  let metadata = join(package, "_gleam_artefacts/" <> artifact)
  case target {
    "javascript" -> [
      metadata <> ".cache_meta",
      metadata <> ".cache",
      join(package, string.remove_suffix(relative, ".gleam") <> ".mjs"),
    ]
    _ -> [
      metadata <> ".cache_meta",
      metadata <> ".cache",
      metadata <> ".erl",
      join(package, "ebin/" <> artifact <> ".beam"),
    ]
  }
}

fn module_artifact(relative: String) -> String {
  relative
  |> string.remove_suffix(".gleam")
  |> string.replace(each: "/", with: "@")
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

const erlang_runtime_eval = "code:add_paths(filelib:wildcard(\"build/dev/erlang/*/ebin\")), kangaroo:main()."

/// Chooses the process boundary for an already-compiled watch generation.
/// Erlang runs the BEAM directly so a finished launcher cannot leave an
/// orphaned runtime holding the project directory open on Windows.
pub fn generation_executable(target: String) -> String {
  case target {
    "erlang" -> "erl"
    _ -> "gleam"
  }
}

pub fn generation_arguments_for(
  target: String,
  runtime: String,
  arguments: List(String),
) -> List(String) {
  case target {
    "erlang" -> erlang_runtime_arguments(arguments)
    _ -> run_arguments_for(target, runtime, arguments)
  }
}

pub fn erlang_runtime_arguments(arguments: List(String)) -> List(String) {
  ["-noshell", "-eval", erlang_runtime_eval, "-extra", ..arguments]
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
