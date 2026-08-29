import gleam/list
import gleam/option.{None, Some}
import kangaroo/internal/index.{IndexedTest}
import kangaroo/internal/legacy/expect.{expect, to_equal}
import kangaroo/internal/legacy/suite.{it, suite}
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

pub fn suites() {
  [
    suite("scheduler", [
      it("keeps tests in one module serial and in definition order", fn() {
        let tests = [
          indexed("a_test", "first_test", [], False),
          indexed("a_test", "second_test", [], False),
          indexed("b_test", "third_test", [], False),
        ]
        let assert [a, b, c] = tests
        let assert [Wave([first, second])] = scheduler.plan(tests, 2, [])
        expect(ids(first)) |> to_equal([a.id, b.id])
        expect(ids(second)) |> to_equal([c.id])
      }),
      it("caps normal waves at the configured worker count", fn() {
        let tests = [
          indexed("a", "a_test", [], False),
          indexed("b", "b_test", [], False),
          indexed("c", "c_test", [], False),
        ]
        let waves = scheduler.plan(tests, 2, [])
        expect(list.map(waves, fn(wave) { list.length(wave.batches) }))
        |> to_equal([2, 1])
      }),
      it("runs explicit and tag-derived serial batches alone", fn() {
        let tests = [
          indexed("a", "a_test", [], False),
          indexed("b", "b_test", ["database"], False),
          indexed("c", "c_test", [], True),
          indexed("d", "d_test", [], False),
        ]
        let waves = scheduler.plan(tests, 4, ["database"])
        expect(
          list.map(waves, fn(wave) {
            list.map(wave.batches, fn(batch) { batch.module })
          }),
        )
        |> to_equal([["a"], ["b"], ["c"], ["d"]])
      }),
      it(
        "shuffles module batches reproducibly without reordering a module",
        fn() {
          let tests = [
            indexed("a", "first_test", [], False),
            indexed("a", "second_test", [], False),
            indexed("b", "third_test", [], False),
            indexed("c", "fourth_test", [], False),
            indexed("d", "fifth_test", [], False),
          ]
          let first = scheduler.plan_seeded(tests, 4, [], Some(73))
          let again = scheduler.plan_seeded(tests, 4, [], Some(73))
          expect(first) |> to_equal(again)
          let modules =
            first
            |> list.flat_map(fn(wave) {
              list.map(wave.batches, fn(batch) { batch.module })
            })
          expect(modules == ["a", "b", "c", "d"]) |> to_equal(False)
          let a =
            first
            |> list.flat_map(fn(wave) { wave.batches })
            |> list.filter(fn(batch) { batch.module == "a" })
          let assert [a] = a
          expect(ids(a))
          |> to_equal([
            "test/a.gleam::first_test",
            "test/a.gleam::second_test",
          ])
        },
      ),
    ]),
  ]
}
