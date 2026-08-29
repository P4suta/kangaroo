import gleam/option.{None, Some}
import kangaroo/internal/generation.{Cancel, Publish, Start}
import kangaroo/internal/legacy/expect.{expect, to_equal}
import kangaroo/internal/legacy/suite.{it, suite}

pub fn suites() {
  [
    suite("watch generations", [
      it("cancels an active generation before starting the next", fn() {
        let #(first, first_actions) = generation.changed(generation.idle())
        expect(first_actions) |> to_equal([Start(1)])
        let #(second, second_actions) = generation.changed(first)
        expect(second_actions) |> to_equal([Cancel(1), Start(2)])
        expect(generation.active(second)) |> to_equal(Some(2))
      }),
      it("never publishes a stale generation result", fn() {
        let #(first, _) = generation.changed(generation.idle())
        let #(second, _) = generation.changed(first)
        let #(unchanged, stale_actions) = generation.finished(second, 1)
        expect(stale_actions) |> to_equal([])
        expect(unchanged) |> to_equal(second)
        let #(done, latest_actions) = generation.finished(second, 2)
        expect(latest_actions) |> to_equal([Publish(2)])
        expect(generation.active(done)) |> to_equal(None)
      }),
      it("ignores duplicate completion after publication", fn() {
        let #(running, _) = generation.changed(generation.idle())
        let #(done, _) = generation.finished(running, 1)
        let #(same, actions) = generation.finished(done, 1)
        expect(actions) |> to_equal([])
        expect(same) |> to_equal(done)
      }),
    ]),
  ]
}
