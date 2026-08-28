import gleam/list
import gleam/option.{None}
import gleam/string
import kangaroo/event.{CaseFinished, CaseStarted, RunFinished, RunStarted}
import kangaroo/expect.{expect, to_equal}
import kangaroo/failure.{EqualityMismatch, Failed, Passed, Skipped}
import kangaroo/report.{Summary}
import kangaroo/suite.{it, suite}
import kangaroo_cli/tui

pub fn suites() {
  [
    suite("tui", [
      it("starts empty", fn() {
        expect(tui.initial()) |> to_equal(tui.UiState([], None))
      }),
      it("tracks case statuses through a run", fn() {
        let state =
          tui.initial()
          |> tui.apply(RunStarted(1, 2))
          |> tui.apply(CaseStarted("math", "adds"))
          |> tui.apply(CaseFinished("math", "adds", Passed, 3))
          |> tui.apply(CaseStarted("math", "subs"))
          |> tui.apply(CaseFinished(
            "math",
            "subs",
            Failed([EqualityMismatch("2", "1", None)]),
            1,
          ))
          |> tui.apply(RunFinished(1, Summary(1, 1, 0, 5)))
        case state.suites {
          [math] -> {
            expect(math.name) |> to_equal("math")
            expect(list.length(math.cases)) |> to_equal(2)
            case math.cases {
              [adds, subs] -> {
                expect(adds.name) |> to_equal("adds")
                expect(adds.status) |> to_equal(tui.Passed)
                expect(subs.status)
                |> to_equal(tui.Failed([EqualityMismatch("2", "1", None)]))
              }
              _ -> panic as "expected two cases"
            }
          }
          _ -> panic as "expected one suite"
        }
      }),
      it("resets on a new run", fn() {
        let state =
          tui.initial()
          |> tui.apply(RunStarted(1, 1))
          |> tui.apply(CaseStarted("math", "adds"))
          |> tui.apply(CaseFinished("math", "adds", Passed, 1))
          |> tui.apply(RunStarted(2, 1))
        expect(state.suites) |> to_equal([])
      }),
      it("renders suite names and case marks", fn() {
        let state =
          tui.initial()
          |> tui.apply(RunStarted(1, 2))
          |> tui.apply(CaseFinished("math", "adds", Passed, 3))
          |> tui.apply(CaseFinished(
            "math",
            "subs",
            Failed([EqualityMismatch("2", "1", None)]),
            1,
          ))
          |> tui.apply(RunFinished(1, Summary(1, 1, 0, 5)))
        let rendered = tui.render(state)
        string.contains(rendered, "math") |> expect |> to_equal(True)
        string.contains(rendered, "✓ adds") |> expect |> to_equal(True)
        string.contains(rendered, "✗ subs") |> expect |> to_equal(True)
        string.contains(rendered, "1 passed, 1 failed")
        |> expect
        |> to_equal(True)
        string.contains(rendered, "expected:") |> expect |> to_equal(True)
      }),
      it("renders running and skipped markers", fn() {
        let state =
          tui.initial()
          |> tui.apply(RunStarted(1, 2))
          |> tui.apply(CaseStarted("math", "slow"))
          |> tui.apply(CaseFinished("math", "unfinished", Skipped, 0))
        let rendered = tui.render(state)
        string.contains(rendered, "▶ slow") |> expect |> to_equal(True)
        string.contains(rendered, "⊘ unfinished") |> expect |> to_equal(True)
      }),
    ]),
  ]
}
