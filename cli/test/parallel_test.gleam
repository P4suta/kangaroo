import gleam/list
import gleam/option.{None}
import kangaroo/event.{
  type Event, CaseFinished, RunFinished, RunStarted, SuiteStarted,
}
import kangaroo/expect.{expect, to_equal}
import kangaroo/report.{Summary}
import kangaroo/runner
import kangaroo/suite.{type Case, type Suite, it, suite}
import kangaroo_cli/event_buffer
import kangaroo_cli/parallel.{chunk_suites, run_groups}

/// Runs groups inline (no real process spawning) so the orchestration
/// logic is exercised deterministically.
fn inline_all(funs: List(fn() -> a)) -> List(a) {
  list.map(funs, fn(fun) { fun() })
}

fn config() -> runner.Config {
  runner.Config(None, False)
}

fn passing_case(name: String) -> Case {
  it(name, fn() { Nil })
}

fn failing_case(name: String) -> Case {
  it(name, fn() { expect(1) |> to_equal(2) })
}

fn groups() -> List(List(Suite)) {
  [
    [suite("math", [passing_case("adds"), passing_case("subs")])],
    [suite("db", [failing_case("queries")])],
  ]
}

pub fn suites() {
  [
    suite("parallel", [
      it("chunks suites into groups of the given size", fn() {
        let suites = [
          suite("a", []),
          suite("b", []),
          suite("c", []),
          suite("d", []),
          suite("e", []),
        ]
        let groups = chunk_suites(suites, 2)
        expect(list.length(groups)) |> to_equal(3)
        case groups {
          [one, two, three] -> {
            expect(list.length(one)) |> to_equal(2)
            expect(list.length(two)) |> to_equal(2)
            expect(list.length(three)) |> to_equal(1)
          }
          _ -> panic as "expected three groups"
        }
      }),
      it("keeps a whole suite inside one chunk", fn() {
        let suites = [
          suite("big", [passing_case("one"), passing_case("two")]),
          suite("small", [passing_case("three")]),
        ]
        let groups = chunk_suites(suites, 2)
        expect(list.length(groups)) |> to_equal(1)
      }),
      it("emits one run bracket around every group's events", fn() {
        let _ =
          run_groups(groups(), config(), event_buffer.append, inline_all, fn() {
            1
          })
        let events = event_buffer.take()
        case events {
          [RunStarted(_, 3), ..middle] ->
            case list.reverse(middle) {
              [RunFinished(_, _), ..rest] -> {
                // per group: SuiteStarted + 2*CaseStarted/Finished +
                // SuiteFinished, with the group's own brackets stripped.
                expect(list.length(rest)) |> to_equal(10)
                let brackets =
                  list.length(
                    list.filter(rest, fn(event: Event) {
                      case event {
                        RunStarted(..) -> True
                        RunFinished(..) -> True
                        _ -> False
                      }
                    }),
                  )
                expect(brackets) |> to_equal(0)
              }
              _ -> panic as "expected RunFinished at the end"
            }
          _ -> panic as "expected RunStarted at the start"
        }
      }),
      it("keeps suite events together", fn() {
        let _ =
          run_groups(groups(), config(), event_buffer.append, inline_all, fn() {
            1
          })
        let events = event_buffer.take()
        let suite_starts =
          list.filter(events, fn(event: Event) {
            case event {
              SuiteStarted(_) -> True
              _ -> False
            }
          })
        expect(list.length(suite_starts)) |> to_equal(2)
      }),
      it("summarises across groups", fn() {
        let _ =
          run_groups(groups(), config(), event_buffer.append, inline_all, fn() {
            100
          })
        let events = event_buffer.take()
        case list.reverse(events) {
          [RunFinished(_, Summary(2, 1, 0, _)), ..] -> Nil
          _ -> panic as "expected the run finished summary"
        }
      }),
      it("reports failures from any group", fn() {
        let has_failures =
          run_groups(groups(), config(), event_buffer.append, inline_all, fn() {
            1
          })
        event_buffer.take()
        expect(has_failures) |> to_equal(True)
      }),
      it("reports a clean run", fn() {
        let clean = [[suite("math", [passing_case("adds")])]]
        let has_failures =
          run_groups(clean, config(), event_buffer.append, inline_all, fn() {
            1
          })
        event_buffer.take()
        expect(has_failures) |> to_equal(False)
      }),
      it("handles an empty group list", fn() {
        let has_failures =
          run_groups([], config(), event_buffer.append, inline_all, fn() { 1 })
        let events = event_buffer.take()
        expect(has_failures) |> to_equal(False)
        expect(list.length(events)) |> to_equal(2)
        case events {
          [RunStarted(_, 0), RunFinished(_, Summary(0, 0, 0, _))] -> Nil
          _ -> panic as "expected an empty run bracket"
        }
      }),
      it("emits every case event without per-group brackets", fn() {
        let _ =
          run_groups(groups(), config(), event_buffer.append, inline_all, fn() {
            1
          })
        let events = event_buffer.take()
        let finished =
          list.length(
            list.filter(events, fn(event: Event) {
              case event {
                CaseFinished(..) -> True
                _ -> False
              }
            }),
          )
        expect(finished) |> to_equal(3)
      }),
    ]),
  ]
}
