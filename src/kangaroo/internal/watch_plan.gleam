import gleam/dict.{type Dict}
import gleam/list
import gleam/result
import gleam/string
import kangaroo/internal/dependencies.{type Selection, All, Selected}
import kangaroo/internal/glob
import kangaroo/internal/index.{
  type IndexError, type IndexedModule, IndexedModule,
}
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

/// Starts a watch generation without a previously valid source index. This is
/// used only when the source present at coordinator startup cannot be indexed;
/// a later valid save rebuilds the complete cache through `refresh`.
pub fn empty() -> State {
  State(cache: index_cache.empty(), modules: [])
}

/// Converts a complete watch snapshot into the deterministic source set used
/// by the AST cache. FFI and configuration files remain watch events but are
/// not Gleam modules, and configured exclusions never enter the runnable set.
pub fn sources(snapshot: Dict(String, String)) -> List(#(String, String)) {
  snapshot
  |> dict.to_list
  |> list.map(fn(entry) { #(watcher.normalise_path(entry.0), entry.1) })
  |> list.filter(fn(entry) { string.ends_with(entry.0, ".gleam") })
  |> list.sort(fn(left, right) { string.compare(left.0, right.0) })
}

pub fn initialise(
  sources: List(#(String, String)),
  test_paths: List(String),
  exclude: List(String),
) -> Result(State, List(IndexError)) {
  use updated <- result.try(index_cache.update(
    index_cache.empty(),
    sources,
    test_paths,
  ))
  Ok(State(
    cache: updated.cache,
    modules: runnable_modules(updated.modules, exclude),
  ))
}

/// Refreshes the exact-source index and produces the smallest safe execution
/// selection. Modules removed in this generation remain in the dependency
/// graph for this decision so their former dependants are still rerun.
pub fn refresh(
  state: State,
  sources: List(#(String, String)),
  test_paths: List(String),
  exclude: List(String),
  event_paths: List(String),
) -> Result(Refresh, List(IndexError)) {
  use updated <- result.try(index_cache.update(state.cache, sources, test_paths))
  let current_modules = runnable_modules(updated.modules, exclude)
  let planning_modules =
    list.append(
      current_modules,
      list.filter(state.modules, fn(previous) {
        !list.any(current_modules, fn(current) { current.path == previous.path })
      }),
    )
  let selection = case dependencies.affected(planning_modules, event_paths) {
    All -> All
    Selected(candidates) -> {
      let ids = list.map(candidates, fn(indexed) { indexed.id })
      let current =
        current_modules
        |> list.flat_map(fn(indexed_module) { indexed_module.tests })
        |> list.filter(fn(indexed) { list.contains(ids, indexed.id) })
      Selected(current)
    }
  }
  Ok(Refresh(
    state: State(cache: updated.cache, modules: current_modules),
    selection:,
    changed_paths: updated.changed_paths,
    reused: updated.reused,
  ))
}

// Exclusion controls runnable tests, not the import graph. Retaining an
// excluded helper module's imports is required to propagate a transitive
// source change to tests which depend on that helper.
fn runnable_modules(
  modules: List(IndexedModule),
  exclude: List(String),
) -> List(IndexedModule) {
  list.map(modules, fn(indexed) {
    case glob.matches_any(exclude, indexed.path) {
      True -> IndexedModule(..indexed, tests: [])
      False -> indexed
    }
  })
}
