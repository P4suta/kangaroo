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
  /// Output captured from one case. It is emitted after `CaseFinished` and
  /// carries the outcome so presentation layers can apply `show_output`
  /// without keeping mutable case state.
  CaseOutput(
    suite: String,
    case_name: String,
    stdout: String,
    stderr: String,
    outcome: Outcome,
  )
  /// A single case has finished. Skipped cases do not emit `CaseStarted` but
  /// do emit this event with the `Skipped` outcome.
  CaseFinished(
    suite: String,
    case_name: String,
    outcome: Outcome,
    duration_ms: Int,
  )
  /// A source module has started running its selected tests.
  SuiteStarted(suite: String)
  /// A source module finished. Per-test outcomes arrive as `CaseFinished`
  /// events; `suite` is retained as the protocol v1 field name.
  SuiteFinished(suite: String, outcome: Outcome)
  /// The run has finished with an overall summary.
  RunFinished(run_id: Int, summary: Summary)
}
