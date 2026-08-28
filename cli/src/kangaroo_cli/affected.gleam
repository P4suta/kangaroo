import gleam/dict.{type Dict}
import gleam/list
import kangaroo_cli/graph.{type ModuleName}

/// Returns the test modules that are affected by the given changes: either
/// the test module itself changed, or one of its transitive imports changed.
///
/// `graph` maps every module in the project to the modules it imports.
pub fn affected_tests(
  graph: List(#(ModuleName, List(ModuleName))),
  tests: List(ModuleName),
  changed: List(ModuleName),
) -> List(ModuleName) {
  let graph = dict.from_list(graph)
  let changed = dict.from_list(list.map(changed, fn(m) { #(m, Nil) }))

  list.filter_map(tests, fn(t) {
    case dict.has_key(changed, t) || imports_any_changed(t, graph, changed, []) {
      True -> Ok(t)
      False -> Error(Nil)
    }
  })
}

fn imports_any_changed(
  module: ModuleName,
  graph: Dict(ModuleName, List(ModuleName)),
  changed: Dict(ModuleName, Nil),
  visited: List(ModuleName),
) -> Bool {
  let imports = case dict.get(graph, module) {
    Ok(imports) -> imports
    Error(_) -> []
  }

  list.any(imports, fn(imported) {
    case dict.has_key(changed, imported) {
      True -> True
      False ->
        case list.contains(visited, imported) {
          True -> False
          False ->
            imports_any_changed(imported, graph, changed, [module, ..visited])
        }
    }
  })
}
