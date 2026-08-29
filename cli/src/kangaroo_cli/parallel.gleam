import gleam/list
import kangaroo/event.{type Event, RunFinished, RunStarted}
import kangaroo/report.{type Report, Report, empty, has_failures, summary}
import kangaroo/runner
import kangaroo/suite.{type Suite}
import kangaroo_cli/event_buffer

/// The result of running one group: the report and the events it
/// emitted, including its own run brackets.
pub type GroupResult {
  GroupResult(report: Report, events: List(Event))
}

/// Splits the suites into groups of at most `size`, so they can run
/// concurrently without splitting a suite (its hooks must stay inside one
/// execution).
pub fn chunk_suites(suites: List(Suite), size: Int) -> List(List(Suite)) {
  let groups =
    list.fold(suites, [], fn(acc, suite) {
      case acc {
        [] -> [[suite]]
        [current, ..rest] ->
          case list.length(current) < size {
            True -> [list.append(current, [suite]), ..rest]
            False -> [[suite], ..acc]
          }
      }
    })
  list.reverse(groups)
}

/// Runs the groups with suite-level parallelism. `run_all_in_process`
/// starts every group's work and collects the results — spawning a
/// process per group on Erlang (true parallelism), running them inline on
/// JavaScript — and `now` provides the clock. A single
/// `RunStarted`/`RunFinished` bracket is emitted around every group's
/// events, with the summary spanning all groups.
pub fn run_groups(
  groups: List(List(Suite)),
  config: runner.Config,
  sink: fn(Event) -> Nil,
  run_all_in_process: fn(List(fn() -> GroupResult)) -> List(GroupResult),
  now: fn() -> Int,
) -> Bool {
  let run_id = now()
  let workers =
    list.map(groups, fn(group) { fn() { run_group(group, config) } })
  let results = run_all_in_process(workers)
  let report = combine_reports(list.map(results, fn(result) { result.report }))
  let duration = now() - run_id

  // The bracket is emitted after the workers finish: the worker buffer is
  // process-local on Erlang and the shared buffer on inline runs, and
  // either way the workers must not drain the bracket events.
  sink(RunStarted(run_id, total_cases(groups)))
  results
  |> list.map(fn(result) { result.events })
  |> list.flatten
  |> without_brackets
  |> list.each(sink)
  sink(RunFinished(run_id, summary(report, duration)))
  has_failures(report)
}

/// Runs one group's suites with the group's events buffered.
fn run_group(group: List(Suite), config: runner.Config) -> GroupResult {
  let report = runner.run_with_config(group, event_buffer.append, config)
  GroupResult(report, event_buffer.take())
}

fn without_brackets(events: List(Event)) -> List(Event) {
  list.filter(events, fn(event) {
    case event {
      RunStarted(_, _) -> False
      RunFinished(_, _) -> False
      _ -> True
    }
  })
}

fn combine_reports(reports: List(Report)) -> Report {
  list.fold(reports, empty(), fn(acc, report) {
    Report(
      list.append(acc.cases, report.cases),
      list.append(acc.suite_failures, report.suite_failures),
    )
  })
}

fn total_cases(groups: List(List(Suite))) -> Int {
  list.fold(groups, 0, fn(total, group) {
    total
    + list.length(list.flatten(list.map(group, fn(suite) { suite.cases })))
  })
}
