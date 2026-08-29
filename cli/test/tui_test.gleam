import gleam/list
import gleam/option.{None, Some}
import gleam/string

import kangaroo/event.{
  CaseFinished, CaseStarted, RunFinished, RunStarted, SuiteFinished,
  SuiteStarted,
}
import kangaroo/expect.{expect, to_equal}
import kangaroo/failure.{AssertionFailed, EqualityMismatch, Failed, Passed, Skipped}
import kangaroo/report.{Summary}
import kangaroo/suite.{it, suite}
import kangaroo_cli/tui

pub fn suites() {
  [
    suite("tui", [
      it("starts empty", fn() {
        expect(tui.initial()) |> to_equal(tui.UiState([], None, None))
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
            Failed([EqualityMismatch("2", "1", None, None)]),
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
                |> to_equal(tui.Failed([EqualityMismatch("2", "1", None, None)]))
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
            Failed([EqualityMismatch("2", "1", None, None)]),
            1,
          ))
          |> tui.apply(RunFinished(1, Summary(1, 1, 0, 5)))
        let rendered = tui.render(state, tui.All)
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
        let rendered = tui.render(state, tui.All)
        string.contains(rendered, "▶ slow") |> expect |> to_equal(True)
        string.contains(rendered, "⊘ unfinished") |> expect |> to_equal(True)
      }),
      it("filters to failures only when asked", fn() {
        let state =
          tui.initial()
          |> tui.apply(RunStarted(1, 3))
          |> tui.apply(CaseFinished("math", "adds", Passed, 1))
          |> tui.apply(CaseFinished(
            "math",
            "subs",
            Failed([EqualityMismatch("2", "1", None, None)]),
            1,
          ))
        let rendered = tui.render(state, tui.FailuresOnly)
        string.contains(rendered, "✗ subs") |> expect |> to_equal(True)
        string.contains(rendered, "✓ adds") |> expect |> to_equal(False)
      }),
      it("renders watch session information", fn() {
        let state =
          tui.initial()
          |> tui.apply(RunStarted(1, 1))
          |> tui.apply(CaseFinished("math", "adds", Passed, 3))
          |> tui.apply(RunFinished(1, Summary(1, 0, 0, 5)))
          |> tui.with_run_info(tui.RunInfo(2, Some(3)))
        let rendered = tui.render(state, tui.All)
        string.contains(rendered, "2 file(s) changed") |> expect |> to_equal(True)
        string.contains(rendered, "3 affected test module(s)")
        |> expect
        |> to_equal(True)
      }),
      it("renders a full run when the affected count is unknown", fn() {
        let state =
          tui.initial()
          |> tui.apply(RunStarted(1, 1))
          |> tui.apply(CaseFinished("math", "adds", Passed, 3))
          |> tui.apply(RunFinished(1, Summary(1, 0, 0, 5)))
          |> tui.with_run_info(tui.RunInfo(0, None))
        let rendered = tui.render(state, tui.All)
        string.contains(rendered, "full run") |> expect |> to_equal(True)
      }),
      it("finds the slowest case", fn() {
        let state =
          tui.initial()
          |> tui.apply(RunStarted(1, 2))
          |> tui.apply(CaseFinished("math", "fast", Passed, 1))
          |> tui.apply(CaseFinished("math", "slow", Passed, 9))
          |> tui.apply(RunFinished(1, Summary(2, 0, 0, 10)))
        let rendered = tui.render(state, tui.All)
        string.contains(rendered, "slowest: slow (9ms)")
        |> expect
        |> to_equal(True)
      }),
      it("renders suite hook failures", fn() {
        let state =
          tui.initial()
          |> tui.apply(RunStarted(1, 1))
          |> tui.apply(SuiteStarted("math"))
          |> tui.apply(SuiteFinished(
            "math",
            Failed([AssertionFailed("setup failed", None)]),
          ))
          |> tui.apply(RunFinished(1, Summary(0, 1, 0, 5)))
        let rendered = tui.render(state, tui.All)
        string.contains(rendered, "suite hooks") |> expect |> to_equal(True)
        string.contains(rendered, "setup failed") |> expect |> to_equal(True)
      }),
      it("shows suites with hook failures in the failures view", fn() {
        let state =
          tui.initial()
          |> tui.apply(RunStarted(1, 1))
          |> tui.apply(SuiteStarted("math"))
          |> tui.apply(SuiteFinished(
            "math",
            Failed([AssertionFailed("boom", None)]),
          ))
        let rendered = tui.render(state, tui.FailuresOnly)
        string.contains(rendered, "math") |> expect |> to_equal(True)
      }),
      it("hides suites with no failures in the failures view", fn() {
        let state =
          tui.initial()
          |> tui.apply(RunStarted(1, 2))
          |> tui.apply(CaseFinished("math", "adds", Passed, 1))
        let rendered = tui.render(state, tui.FailuresOnly)
        string.contains(rendered, "math") |> expect |> to_equal(False)
      }),
    ]),
  ]
}
