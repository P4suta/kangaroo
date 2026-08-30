import gleam/dict
import gleam/list
import kangaroo/internal/dependencies.{All, Selected}
import kangaroo/internal/watch_plan

fn initial_sources() {
  [
    #("src/app/math.gleam", "pub fn add(a, b) { a + b }"),
    #(
      "src/app/service.gleam",
      "import app/math\npub fn answer() { math.add(40, 2) }",
    ),
    #(
      "test/math_test.gleam",
      "import app/math\npub fn addition_test() { assert math.add(1, 1) == 2 }",
    ),
    #(
      "test/service_test.gleam",
      "import app/service\npub fn answer_test() { assert service.answer() == 42 }",
    ),
    #("test/other_test.gleam", "pub fn other_test() { assert True }"),
  ]
}

pub fn watch_plan_extracts_every_gleam_module_for_dependencies_test() {
  let snapshot =
    dict.from_list([
      #("gleam.toml", "name = \"demo\""),
      #("src/app.gleam", "pub fn app() { Nil }"),
      #("src/app_ffi.erl", "-module(app_ffi)."),
      #("test/app_test.gleam", "pub fn app_test() { Nil }"),
      #("test/generated/ignored_test.gleam", "pub fn ignored_test() { Nil }"),
    ])
  assert watch_plan.sources(snapshot)
    == [
      #("src/app.gleam", "pub fn app() { Nil }"),
      #("test/app_test.gleam", "pub fn app_test() { Nil }"),
      #("test/generated/ignored_test.gleam", "pub fn ignored_test() { Nil }"),
    ]
}

pub fn watch_plan_selects_transitively_affected_current_tests_test() {
  let assert Ok(state) = watch_plan.initialise(initial_sources(), ["test"], [])
  let changed =
    initial_sources()
    |> list.map(fn(source) {
      case source.0 {
        "src/app/math.gleam" -> #(source.0, source.1 <> "\n")
        _ -> source
      }
    })
  let assert Ok(refresh) =
    watch_plan.refresh(state, changed, ["test"], [], ["src/app/math.gleam"])
  let assert Selected(tests) = refresh.selection
  assert list.map(tests, fn(indexed) { indexed.id })
    == [
      "test/math_test.gleam::addition_test",
      "test/service_test.gleam::answer_test",
    ]
}

pub fn watch_plan_retains_old_graph_for_deleted_dependency_test() {
  let assert Ok(state) = watch_plan.initialise(initial_sources(), ["test"], [])
  let remaining =
    initial_sources()
    |> list.filter(fn(source) { source.0 != "src/app/math.gleam" })
  let assert Ok(refresh) =
    watch_plan.refresh(state, remaining, ["test"], [], ["src/app/math.gleam"])
  let assert Selected(tests) = refresh.selection
  assert list.map(tests, fn(indexed) { indexed.id })
    == [
      "test/math_test.gleam::addition_test",
      "test/service_test.gleam::answer_test",
    ]
}

pub fn watch_plan_requests_full_run_for_config_and_ffi_changes_test() {
  let assert Ok(state) = watch_plan.initialise(initial_sources(), ["test"], [])
  let assert Ok(config_refresh) =
    watch_plan.refresh(state, initial_sources(), ["test"], [], ["gleam.toml"])
  assert config_refresh.selection == All
  let assert Ok(ffi_refresh) =
    watch_plan.refresh(state, initial_sources(), ["test"], [], [
      "src/app_ffi.erl",
    ])
  assert ffi_refresh.selection == All
}

pub fn watch_plan_ignores_unrelated_source_edit_test() {
  let sources = [
    #("src/unrelated.gleam", "pub fn value() { 1 }"),
    ..initial_sources()
  ]
  let assert Ok(state) = watch_plan.initialise(sources, ["test"], [])
  let assert Ok(refresh) =
    watch_plan.refresh(state, sources, ["test"], [], ["src/unrelated.gleam"])
  let assert Selected(tests) = refresh.selection
  assert tests == []
}

pub fn watch_plan_tracks_dev_helpers_without_running_out_of_root_tests_test() {
  let sources = [
    #("dev/support.gleam", "pub fn value() { 1 }"),
    #(
      "test/unit/uses_support_test.gleam",
      "import support\npub fn uses_support_test() { assert support.value() == 1 }",
    ),
    #(
      "test/integration/outside_test.gleam",
      "import support\npub fn outside_test() { assert support.value() == 1 }",
    ),
  ]
  let assert Ok(state) = watch_plan.initialise(sources, ["test/unit"], [])
  let assert Ok(refresh) =
    watch_plan.refresh(state, sources, ["test/unit"], [], ["dev/support.gleam"])
  let assert Selected(tests) = refresh.selection
  assert list.map(tests, fn(indexed) { indexed.id })
    == ["test/unit/uses_support_test.gleam::uses_support_test"]
}

pub fn excluded_helper_retains_transitive_watch_dependencies_test() {
  let exclude = ["test/helpers/**"]
  let snapshot =
    dict.from_list([
      #("src/core.gleam", "pub fn value() { 1 }"),
      #(
        "test/helpers/support.gleam",
        "import core\npub fn value() { core.value() }\npub fn ignored_test() { Nil }",
      ),
      #(
        "test/active_test.gleam",
        "import helpers/support\npub fn active_test() { assert support.value() == 1 }",
      ),
    ])
  let sources = watch_plan.sources(snapshot)
  let assert Ok(state) = watch_plan.initialise(sources, ["test"], exclude)
  let assert Ok(refresh) =
    watch_plan.refresh(state, sources, ["test"], exclude, ["src/core.gleam"])
  let assert Selected(tests) = refresh.selection
  assert list.map(tests, fn(indexed) { indexed.id })
    == ["test/active_test.gleam::active_test"]
}
