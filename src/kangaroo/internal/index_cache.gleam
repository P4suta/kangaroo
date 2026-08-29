import gleam/dict.{type Dict}
import gleam/list
import gleam/string
import kangaroo/internal/index.{type IndexError, type IndexedModule}

pub type IndexCache {
  IndexCache(modules: Dict(String, IndexedModule))
}

pub type Update {
  Updated(
    cache: IndexCache,
    modules: List(IndexedModule),
    changed_paths: List(String),
    reused: Int,
  )
}

pub fn empty() -> IndexCache {
  IndexCache(dict.new())
}

/// Atomically refreshes an index. Unchanged content reuses its parsed AST
/// result; a single parse error rejects the entire candidate generation.
pub fn update(
  cache: IndexCache,
  sources: List(#(String, String)),
  test_paths: List(String),
) -> Result(Update, List(IndexError)) {
  let sources =
    sources
    |> list.map(fn(source) { #(normalise(source.0), source.1) })
    |> list.sort(fn(left, right) { string.compare(left.0, right.0) })
  let current_paths = list.map(sources, fn(source) { source.0 })
  let removed =
    dict.keys(cache.modules)
    |> list.filter(fn(path) { !list.contains(current_paths, path) })
    |> list.sort(string.compare)
  let initial = #(dict.new(), [], [], 0, [])
  let #(modules_by_path, modules, changed, reused, errors) =
    list.fold(sources, initial, fn(state, source) {
      let #(by_path, modules, changed, reused, errors) = state
      let #(path, contents) = source
      let hash = index.source_hash(contents)
      case dict.get(cache.modules, path) {
        Ok(module) if module.content_hash == hash -> #(
          dict.insert(by_path, path, module),
          list.append(modules, [module]),
          changed,
          reused + 1,
          errors,
        )
        _ ->
          case index.index(path, contents, test_paths) {
            Ok(module) -> #(
              dict.insert(by_path, path, module),
              list.append(modules, [module]),
              list.append(changed, [path]),
              reused,
              errors,
            )
            Error(error) -> #(
              by_path,
              modules,
              list.append(changed, [path]),
              reused,
              list.append(errors, [error]),
            )
          }
      }
    })
  case errors {
    [] ->
      Ok(Updated(
        cache: IndexCache(modules_by_path),
        modules:,
        changed_paths: list.append(changed, removed)
          |> list.sort(string.compare),
        reused:,
      ))
    _ -> Error(errors)
  }
}

fn normalise(path: String) -> String {
  path
  |> string.replace(each: "\\", with: "/")
  |> string.remove_prefix("./")
}
