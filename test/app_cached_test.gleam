import gleam/list
import kangaroo/internal/app.{CachedList}
import kangaroo/internal/discovery

pub fn configured_cached_list_reuses_daemon_generation_test() {
  let assert Ok(first) =
    app.list_configured_project_cached(
      "fixtures/watch_project",
      discovery.empty_cache(),
      [],
      [],
      [],
    )
  assert first.reused == 0
  assert first.tests |> list.length == 1

  let assert Ok(CachedList(tests:, reused: 1, ..)) =
    app.list_configured_project_cached(
      "fixtures/watch_project",
      first.cache,
      [],
      [],
      [],
    )
  let assert [indexed] = tests
  assert indexed.id
    == "test/kangaroo_watch_fixture_test.gleam::cancellable_test"
}
