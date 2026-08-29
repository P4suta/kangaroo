import kangaroo/failure.{type Outcome}
import kangaroo/report.{type Summary}

/// Events emitted by the runner as a test run progresses. These are the
/// single source of truth consumed by every presentation layer: the terminal
/// formatter, the continuous runner's stream, and the editor protocol.
pub type Event {
  /// The run has started. `run_id` correlates all events of this run and
  /// `case_count` is the total number of selected cases (skipped cases
  /// included).
  RunStarted(run_id: Int, case_count: Int)
  /// A single case has started executing.
  CaseStarted(suite: String, case_name: String)
  /// A single case has finished. Skipped cases do not emit `CaseStarted` but
  /// do emit this event with the `Skipped` outcome.
  CaseFinished(
    suite: String,
    case_name: String,
    outcome: Outcome,
    duration_ms: Int,
  )
  /// A suite has started running its cases, emitted for every suite that
  /// has at least one runnable case. Suite hooks run inside this window.
  SuiteStarted(suite: String)
  /// A suite finished. The outcome reflects its `before_all` / `after_all`
  /// hooks, which run once per suite; per-case outcomes arrive as
  /// `CaseFinished` events.
  SuiteFinished(suite: String, outcome: Outcome)
  /// The run has finished with an overall summary.
  RunFinished(run_id: Int, summary: Summary)
}
