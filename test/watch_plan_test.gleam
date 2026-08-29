import gleam/dict
import gleam/list
import kangaroo/internal/dependencies.{All, Selected}
import kangaroo/internal/legacy/expect.{expect, to_equal}
import kangaroo/internal/legacy/suite.{it, suite}
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

pub fn suites() {
  [
    suite("watch execution planning", [
      it("extracts only included Gleam modules from a watch snapshot", fn() {
        let snapshot =
          dict.from_list([
            #("gleam.toml", "name = \"demo\""),
            #("src/app.gleam", "pub fn app() { Nil }"),
            #("src/app_ffi.erl", "-module(app_ffi)."),
            #("test/app_test.gleam", "pub fn app_test() { Nil }"),
            #(
              "test/generated/ignored_test.gleam",
              "pub fn ignored_test() { Nil }",
            ),
          ])
        expect(watch_plan.sources(snapshot, ["test/generated/**"]))
        |> to_equal([
          #("src/app.gleam", "pub fn app() { Nil }"),
          #("test/app_test.gleam", "pub fn app_test() { Nil }"),
        ])
      }),
      it("selects current tests transitively affected by a source edit", fn() {
        let assert Ok(state) =
          watch_plan.initialise(initial_sources(), ["test"])
        let changed =
          initial_sources()
          |> list.map(fn(source) {
            case source.0 {
              "src/app/math.gleam" -> #(source.0, source.1 <> "\n")
              _ -> source
            }
          })
        let assert Ok(refresh) =
          watch_plan.refresh(state, changed, ["test"], ["src/app/math.gleam"])
        let assert Selected(tests) = refresh.selection
        expect(list.map(tests, fn(indexed) { indexed.id }))
        |> to_equal([
          "test/math_test.gleam::addition_test",
          "test/service_test.gleam::answer_test",
        ])
      }),
      it("retains the old graph while planning a deleted dependency", fn() {
        let assert Ok(state) =
          watch_plan.initialise(initial_sources(), ["test"])
        let remaining =
          initial_sources()
          |> list.filter(fn(source) { source.0 != "src/app/math.gleam" })
        let assert Ok(refresh) =
          watch_plan.refresh(state, remaining, ["test"], ["src/app/math.gleam"])
        let assert Selected(tests) = refresh.selection
        expect(list.map(tests, fn(indexed) { indexed.id }))
        |> to_equal([
          "test/math_test.gleam::addition_test",
          "test/service_test.gleam::answer_test",
        ])
      }),
      it("requests a safe full run for config and FFI changes", fn() {
        let assert Ok(state) =
          watch_plan.initialise(initial_sources(), ["test"])
        let assert Ok(config_refresh) =
          watch_plan.refresh(state, initial_sources(), ["test"], ["gleam.toml"])
        expect(config_refresh.selection) |> to_equal(All)
        let assert Ok(ffi_refresh) =
          watch_plan.refresh(state, initial_sources(), ["test"], [
            "src/app_ffi.erl",
          ])
        expect(ffi_refresh.selection) |> to_equal(All)
      }),
      it("does not schedule tests for an unrelated source edit", fn() {
        let sources = [
          #("src/unrelated.gleam", "pub fn value() { 1 }"),
          ..initial_sources()
        ]
        let assert Ok(state) = watch_plan.initialise(sources, ["test"])
        let assert Ok(refresh) =
          watch_plan.refresh(state, sources, ["test"], ["src/unrelated.gleam"])
        let assert Selected(tests) = refresh.selection
        expect(tests) |> to_equal([])
      }),
    ]),
  ]
}
