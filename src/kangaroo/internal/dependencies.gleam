import gleam/list
import gleam/string
import kangaroo/internal/index.{type IndexedModule, type IndexedTest}

pub type Selection {
  /// The change cannot be represented safely in the Gleam import graph.
  All
  Selected(tests: List(IndexedTest))
}

/// Selects tests importing any changed Gleam module, directly or
/// transitively. FFI, configuration and unknown paths deliberately request a
/// full run because source imports cannot prove their impact.
pub fn affected(
  modules: List(IndexedModule),
  changed_paths: List(String),
) -> Selection {
  case list.try_map(changed_paths, changed_module) {
    Error(_) -> All
    Ok(changed) -> {
      let tests =
        modules
        |> list.flat_map(fn(module) {
          case module.tests, module_is_affected(module, modules, changed) {
            [], _ -> []
            tests, True -> tests
            _, False -> []
          }
        })
      Selected(tests)
    }
  }
}

fn module_is_affected(
  module: IndexedModule,
  modules: List(IndexedModule),
  changed: List(String),
) -> Bool {
  list.contains(changed, module.module)
  || list.any(changed, fn(target) {
    imports(module.module, target, modules, [])
  })
}

fn imports(
  module_name: String,
  target: String,
  modules: List(IndexedModule),
  visited: List(String),
) -> Bool {
  case list.contains(visited, module_name) {
    True -> False
    False ->
      case list.find(modules, fn(module) { module.module == module_name }) {
        Error(_) -> False
        Ok(module) ->
          list.contains(module.imports, target)
          || list.any(module.imports, fn(imported) {
            imports(imported, target, modules, [module_name, ..visited])
          })
      }
  }
}

fn changed_module(path: String) -> Result(String, Nil) {
  let path = string.replace(path, each: "\\", with: "/")
  case path {
    "src/" <> relative -> gleam_module(relative)
    "test/" <> relative -> gleam_module(relative)
    _ -> Error(Nil)
  }
}

fn gleam_module(relative: String) -> Result(String, Nil) {
  case string.ends_with(relative, ".gleam") {
    False -> Error(Nil)
    True -> {
      let module = string.remove_suffix(relative, ".gleam")
      case module {
        "" -> Error(Nil)
        _ -> Ok(module)
      }
    }
  }
}
