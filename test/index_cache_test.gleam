import gleam/list
import kangaroo/internal/index_cache.{Updated}

pub fn index_cache_reuses_unchanged_modules_by_content_hash_test() {
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
