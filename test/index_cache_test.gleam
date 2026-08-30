import gleam/list
import kangaroo/internal/index
import kangaroo/internal/index_cache.{Updated}

pub fn index_cache_reuses_only_byte_identical_modules_test() {
  let sources = [
    #("src/app.gleam", "pub fn value() { 1 }"),
    #("test/app_test.gleam", "pub fn value_test() { Nil }"),
  ]
  let assert Ok(first) =
    index_cache.update(index_cache.empty(), sources, ["test"])
  assert first.reused == 0
  let assert Ok(second) = index_cache.update(first.cache, sources, ["test"])
  assert second.reused == 2
  assert second.changed_paths == []
}

pub fn index_cache_never_reuses_a_colliding_source_hash_test() {
  let first_source = "pub fn collision_1220_test() { Nil }"
  let second_source = "pub fn collision_6aas_test() { Nil }"
  assert first_source != second_source
  assert index.source_hash(first_source) == index.source_hash(second_source)

  let path = "test/collision_test.gleam"
  let assert Ok(first) =
    index_cache.update(index_cache.empty(), [#(path, first_source)], ["test"])
  let assert Ok(second) =
    index_cache.update(first.cache, [#(path, second_source)], ["test"])

  assert second.reused == 0
  assert second.changed_paths == [path]
  assert list.map(second.modules, fn(module) {
      list.map(module.tests, fn(indexed) { indexed.id })
    })
    == [["test/collision_test.gleam::collision_6aas_test"]]
}

pub fn index_cache_reindexes_when_source_roots_change_test() {
  let path = "spec/integration/cache_test.gleam"
  let source = "pub fn cache_test() { Nil }"
  let assert Ok(first) =
    index_cache.update(index_cache.empty(), [#(path, source)], ["spec"])
  let assert [first_module] = first.modules
  assert first_module.module == "integration/cache_test"

  let assert Ok(second) =
    index_cache.update(first.cache, [#(path, source)], ["spec/integration"])
  let assert [second_module] = second.modules
  assert second.reused == 0
  assert second.changed_paths == [path]
  assert second_module.module == "cache_test"
}

pub fn index_cache_reindexes_changes_and_removes_deleted_files_test() {
  let assert Ok(first) =
    index_cache.update(
      index_cache.empty(),
      [
        #("src/a.gleam", "pub fn a() { 1 }"),
        #("src/b.gleam", "pub fn b() { 2 }"),
      ],
      ["test"],
    )
  let assert Ok(Updated(modules: modules, changed_paths: changed, ..)) =
    index_cache.update(first.cache, [#("src/a.gleam", "pub fn a() { 3 }")], [
      "test",
    ])
  assert list.map(modules, fn(module) { module.path }) == ["src/a.gleam"]
  assert changed == ["src/a.gleam", "src/b.gleam"]
}

pub fn index_cache_rejects_atomic_update_when_changed_module_cannot_parse_test() {
  let result =
    index_cache.update(
      index_cache.empty(),
      [#("test/broken.gleam", "pub fn broken( {")],
      ["test"],
    )
  let assert Error([_]) = result
}
