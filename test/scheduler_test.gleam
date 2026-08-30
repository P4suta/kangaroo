import gleam/list
import gleam/option.{None, Some}
import kangaroo/internal/index.{IndexedTest}
import kangaroo/internal/scheduler.{type Batch, Wave}

fn indexed(module: String, name: String, tags: List(String), serial: Bool) {
  IndexedTest(
    id: "test/" <> module <> ".gleam::" <> name,
    name:,
    path: "test/" <> module <> ".gleam",
    module:,
    line: 1,
    column: 1,
    end_line: 1,
    end_column: 1,
    tags:,
    timeout_ms: None,
    serial:,
    skip: None,
  )
}

fn ids(batch: Batch) {
  list.map(batch.tests, fn(indexed) { indexed.id })
}

pub fn scheduler_keeps_module_serial_in_definition_order_test() {
  let tests = [
    indexed("a_test", "first_test", [], False),
    indexed("a_test", "second_test", [], False),
    indexed("b_test", "third_test", [], False),
  ]
  let assert [a, b, c] = tests
  let assert [Wave([first, second])] = scheduler.plan(tests, 2, [])
  assert ids(first) == [a.id, b.id]
  assert ids(second) == [c.id]
}

pub fn scheduler_caps_normal_waves_at_worker_count_test() {
  let tests = [
    indexed("a", "a_test", [], False),
    indexed("b", "b_test", [], False),
    indexed("c", "c_test", [], False),
  ]
  let waves = scheduler.plan(tests, 2, [])
  assert list.map(waves, fn(wave) { list.length(wave.batches) }) == [2, 1]
}

pub fn scheduler_runs_explicit_and_tag_serial_batches_alone_test() {
  let tests = [
    indexed("a", "a_test", [], False),
    indexed("b", "b_test", ["database"], False),
    indexed("c", "c_test", [], True),
    indexed("d", "d_test", [], False),
  ]
  let waves = scheduler.plan(tests, 4, ["database"])
  assert list.map(waves, fn(wave) {
      list.map(wave.batches, fn(batch) { batch.module })
    })
    == [["a"], ["b"], ["c"], ["d"]]
}

pub fn scheduler_shuffles_reproducibly_without_reordering_module_test() {
  let tests = [
    indexed("a", "first_test", [], False),
    indexed("a", "second_test", [], False),
    indexed("b", "third_test", [], False),
    indexed("c", "fourth_test", [], False),
    indexed("d", "fifth_test", [], False),
  ]
  let first = scheduler.plan_seeded(tests, 4, [], Some(73))
  let again = scheduler.plan_seeded(tests, 4, [], Some(73))
  assert first == again
  let modules =
    first
    |> list.flat_map(fn(wave) {
      list.map(wave.batches, fn(batch) { batch.module })
    })
  assert modules != ["a", "b", "c", "d"]
  let a =
    first
    |> list.flat_map(fn(wave) { wave.batches })
    |> list.filter(fn(batch) { batch.module == "a" })
  let assert [a] = a
  assert ids(a) == ["test/a.gleam::first_test", "test/a.gleam::second_test"]
}
