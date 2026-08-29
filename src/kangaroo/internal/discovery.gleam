import gleam/list
import gleam/result
import gleam/string
import kangaroo/internal/fs
import kangaroo/internal/glob
import kangaroo/internal/index.{
  type IndexError, type IndexedModule, type IndexedTest,
}
import kangaroo/internal/index_cache.{type IndexCache, Updated}

pub type Discovery {
  Discovery(modules: List(IndexedModule), tests: List(IndexedTest))
}

/// A content-addressed index retained for the lifetime of a watcher or daemon.
pub type Cache {
  Cache(index: IndexCache)
}

pub type CachedDiscovery {
  CachedDiscovery(
    cache: Cache,
    discovery: Discovery,
    changed_paths: List(String),
    reused: Int,
  )
}

pub fn empty_cache() -> Cache {
  Cache(index_cache.empty())
}

/// Builds a deterministic index from already-read sources.
///
/// This is the pure discovery core used by unit tests and by the incremental
/// watcher. A parse or metadata error rejects the complete snapshot: callers
/// never execute a misleading partial set of tests.
pub fn from_sources(
  sources: List(#(String, String)),
  test_paths: List(String),
) -> Result(Discovery, List(IndexError)) {
  from_sources_with_excludes(sources, test_paths, [])
}

pub fn from_sources_with_excludes(
  sources: List(#(String, String)),
  test_paths: List(String),
  exclude: List(String),
) -> Result(Discovery, List(IndexError)) {
  let #(modules, errors) =
    sources
    |> list.filter(fn(source) {
      in_test_paths(source.0, test_paths)
      && !glob.matches_any(exclude, normalise(source.0))
    })
    |> list.sort(fn(a, b) { string.compare(normalise(a.0), normalise(b.0)) })
    |> list.fold(#([], []), fn(state, source) {
      let #(modules, errors) = state
      case index.index(source.0, source.1, test_paths) {
        Ok(module) -> #(list.append(modules, [module]), errors)
        Error(error) -> #(modules, list.append(errors, [error]))
      }
    })

  case errors {
    [] ->
      Ok(Discovery(
        modules:,
        tests: modules |> list.map(fn(module) { module.tests }) |> list.flatten,
      ))
    _ -> Error(errors)
  }
}

/// Builds a discovery generation while reusing ASTs whose content hash is
/// unchanged. Parse failures do not return a replacement cache, so callers
/// retain the last complete generation.
pub fn from_sources_cached(
  cache: Cache,
  sources: List(#(String, String)),
  test_paths: List(String),
  exclude: List(String),
) -> Result(CachedDiscovery, List(IndexError)) {
  let sources =
    sources
    |> list.filter(fn(source) {
      in_test_paths(source.0, test_paths)
      && !glob.matches_any(exclude, normalise(source.0))
    })
  use update <- result.try(index_cache.update(cache.index, sources, test_paths))
  let Updated(cache: next_index, modules:, changed_paths:, reused:) = update
  let discovery =
    Discovery(
      modules:,
      tests: modules |> list.map(fn(module) { module.tests }) |> list.flatten,
    )
  Ok(CachedDiscovery(
    cache: Cache(next_index),
    discovery:,
    changed_paths:,
    reused:,
  ))
}

/// Reads configured test roots and builds a source index.
pub fn discover(
  project_dir: String,
  test_paths: List(String),
) -> Result(Discovery, List(IndexError)) {
  discover_with_excludes(project_dir, test_paths, [])
}

pub fn discover_with_excludes(
  project_dir: String,
  test_paths: List(String),
  exclude: List(String),
) -> Result(Discovery, List(IndexError)) {
  use sources <- result.try(read_sources(project_dir, test_paths))
  from_sources_with_excludes(sources, test_paths, exclude)
}

/// Filesystem-backed incremental discovery for long-lived processes.
pub fn discover_cached(
  cache: Cache,
  project_dir: String,
  test_paths: List(String),
  exclude: List(String),
) -> Result(CachedDiscovery, List(IndexError)) {
  use sources <- result.try(read_sources(project_dir, test_paths))
  from_sources_cached(cache, sources, test_paths, exclude)
}

fn read_sources(
  project_dir: String,
  test_paths: List(String),
) -> Result(List(#(String, String)), List(IndexError)) {
  use nested_files <- result.try(
    list.try_map(test_paths, fn(root) {
      let directory = join(project_dir, root)
      fs.list_files_recursive(directory)
      |> result.map_error(fn(message) {
        [index.ParseError(normalise(root), 1, message)]
      })
    }),
  )
  let files =
    nested_files
    |> list.flatten
    |> list.filter(fn(path) { string.ends_with(path, ".gleam") })
    |> list.sort(string.compare)

  use sources <- result.try(
    list.try_map(files, fn(path) {
      fs.read_file(path)
      |> result.map(fn(source) { #(relative(project_dir, path), source) })
      |> result.map_error(fn(message) {
        [index.ParseError(relative(project_dir, path), 1, message)]
      })
    }),
  )
  Ok(sources)
}

fn in_test_paths(path: String, test_paths: List(String)) -> Bool {
  let path = normalise(path)
  list.any(test_paths, fn(root) {
    let root = normalise(root)
    path == root || string.starts_with(path, root <> "/")
  })
}

fn relative(project_dir: String, path: String) -> String {
  let project = normalise(project_dir)
  let path = normalise(path)
  case project == "." {
    True -> string.remove_prefix(path, "./")
    False -> string.remove_prefix(path, project <> "/")
  }
}

fn join(left: String, right: String) -> String {
  case left {
    "." -> "./" <> right
    _ -> string.trim_end(left) <> "/" <> right
  }
}

fn normalise(path: String) -> String {
  string.replace(path, each: "\\", with: "/")
}
