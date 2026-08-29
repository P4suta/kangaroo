import gleam/dict.{type Dict}
import gleam/list
import gleam/result
import gleam/string
import kangaroo/internal/dependencies.{type Selection, All, Selected}
import kangaroo/internal/glob
import kangaroo/internal/index.{type IndexError, type IndexedModule}
import kangaroo/internal/index_cache.{type IndexCache}
import kangaroo/internal/watcher

pub type State {
  State(cache: IndexCache, modules: List(IndexedModule))
}

pub type Refresh {
  Refresh(
    state: State,
    selection: Selection,
    changed_paths: List(String),
    reused: Int,
  )
}

/// Converts a complete watch snapshot into the deterministic source set used
/// by the AST cache. FFI and configuration files remain watch events but are
/// not Gleam modules, and configured exclusions never enter the runnable set.
pub fn sources(
  snapshot: Dict(String, String),
  exclude: List(String),
) -> List(#(String, String)) {
  snapshot
  |> dict.to_list
  |> list.map(fn(entry) { #(watcher.normalise_path(entry.0), entry.1) })
  |> list.filter(fn(entry) {
    string.ends_with(entry.0, ".gleam") && !glob.matches_any(exclude, entry.0)
  })
  |> list.sort(fn(left, right) { string.compare(left.0, right.0) })
}

pub fn initialise(
  sources: List(#(String, String)),
  test_paths: List(String),
) -> Result(State, List(IndexError)) {
  use updated <- result.try(index_cache.update(
    index_cache.empty(),
    sources,
    test_paths,
  ))
  Ok(State(cache: updated.cache, modules: updated.modules))
}

/// Refreshes the content-hash index and produces the smallest safe execution
/// selection. Modules removed in this generation remain in the dependency
/// graph for this decision so their former dependants are still rerun.
pub fn refresh(
  state: State,
  sources: List(#(String, String)),
  test_paths: List(String),
  event_paths: List(String),
) -> Result(Refresh, List(IndexError)) {
  use updated <- result.try(index_cache.update(state.cache, sources, test_paths))
  let planning_modules =
    list.append(
      updated.modules,
      list.filter(state.modules, fn(previous) {
        !list.any(updated.modules, fn(current) { current.path == previous.path })
      }),
    )
  let selection = case dependencies.affected(planning_modules, event_paths) {
    All -> All
    Selected(candidates) -> {
      let ids = list.map(candidates, fn(indexed) { indexed.id })
      let current =
        updated.modules
        |> list.flat_map(fn(indexed_module) { indexed_module.tests })
        |> list.filter(fn(indexed) { list.contains(ids, indexed.id) })
      Selected(current)
    }
  }
  Ok(Refresh(
    state: State(cache: updated.cache, modules: updated.modules),
    selection:,
    changed_paths: updated.changed_paths,
    reused: updated.reused,
  ))
}
