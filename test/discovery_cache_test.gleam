import kangaroo/internal/discovery.{CachedDiscovery}

const sources = [
  #("test/a_test.gleam", "pub fn one_test() { Nil }"),
  #("test/b_test.gleam", "pub fn two_test() { Nil }"),
]

pub fn cached_discovery_reuses_unchanged_modules_test() {
  let assert Ok(first) =
    discovery.from_sources_cached(
      discovery.empty_cache(),
      sources,
      ["test"],
      [],
    )
  assert first.reused == 0
  assert first.changed_paths == ["test/a_test.gleam", "test/b_test.gleam"]

  let assert Ok(second) =
    discovery.from_sources_cached(first.cache, sources, ["test"], [])
  assert second.reused == 2
  assert second.changed_paths == []
  assert second.discovery.tests == first.discovery.tests
}

pub fn cached_discovery_updates_only_changed_modules_test() {
  let assert Ok(first) =
    discovery.from_sources_cached(
      discovery.empty_cache(),
      sources,
      ["test"],
      [],
    )
  let changed = [
    #("test/a_test.gleam", "pub fn changed_test() { Nil }"),
    #("test/b_test.gleam", "pub fn two_test() { Nil }"),
  ]
  let assert Ok(CachedDiscovery(
    discovery: result,
    reused: 1,
    changed_paths: ["test/a_test.gleam"],
    ..,
  )) = discovery.from_sources_cached(first.cache, changed, ["test"], [])
  let assert [changed_test, ..] = result.tests
  assert changed_test.id == "test/a_test.gleam::changed_test"
}

pub fn cached_discovery_rejects_bad_generation_without_mutating_cache_test() {
  let assert Ok(first) =
    discovery.from_sources_cached(
      discovery.empty_cache(),
      sources,
      ["test"],
      [],
    )
  let assert Error(_) =
    discovery.from_sources_cached(
      first.cache,
      [#("test/a_test.gleam", "pub fn broken( {")],
      ["test"],
      [],
    )

  let assert Ok(recovered) =
    discovery.from_sources_cached(first.cache, sources, ["test"], [])
  assert recovered.reused == 2
  assert recovered.changed_paths == []
}
