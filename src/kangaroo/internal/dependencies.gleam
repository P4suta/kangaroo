import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set.{type Set}
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
      let reverse = reverse_dependencies(modules)
      let affected = reachable(reverse, changed, set.new())
      let tests =
        modules
        |> list.flat_map(fn(module) {
          case module.tests, set.contains(affected, module.module) {
            [], _ -> []
            tests, True -> tests
            _, False -> []
          }
        })
      Selected(tests)
    }
  }
}

fn reverse_dependencies(
  modules: List(IndexedModule),
) -> Dict(String, List(String)) {
  list.fold(modules, dict.new(), fn(reverse, module) {
    list.fold(module.imports, reverse, fn(reverse, imported) {
      dict.upsert(reverse, imported, fn(dependants) {
        case dependants {
          None -> [module.module]
          Some(dependants) -> [module.module, ..dependants]
        }
      })
    })
  })
}

fn reachable(
  reverse: Dict(String, List(String)),
  pending: List(String),
  visited: Set(String),
) -> Set(String) {
  case pending {
    [] -> visited
    [module, ..rest] ->
      case set.contains(visited, module) {
        True -> reachable(reverse, rest, visited)
        False -> {
          let dependants = dict.get(reverse, module) |> result.unwrap([])
          reachable(
            reverse,
            list.append(dependants, rest),
            set.insert(visited, module),
          )
        }
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
