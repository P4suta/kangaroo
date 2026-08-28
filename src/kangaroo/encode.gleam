import gleam/io
import gleam/json
import kangaroo/event.{
  type Event, CaseFinished, CaseStarted, RunFinished, RunStarted,
}
import kangaroo/failure.{
  type Failure, type Outcome, AssertionFailed, EqualityMismatch, Failed, Passed,
  Skipped, UnexpectedError,
}
import kangaroo/report.{type Summary}

/// The sink used for machine-readable output: every event is printed as a
/// single JSON object on its own line. Enabled by setting the `KANGAROO_JSON`
/// environment variable.
pub fn json_sink(event: Event) -> Nil {
  io.println(encode(event))
}

pub fn encode(event: Event) -> String {
  let json = case event {
    RunStarted(run_id, case_count) ->
      json.object([
        #("type", json.string("run_started")),
        #("run_id", json.int(run_id)),
        #("case_count", json.int(case_count)),
      ])
    CaseStarted(suite, case_name) ->
      json.object([
        #("type", json.string("case_started")),
        #("suite", json.string(suite)),
        #("case", json.string(case_name)),
      ])
    CaseFinished(suite, case_name, outcome, duration_ms) ->
      json.object([
        #("type", json.string("case_finished")),
        #("suite", json.string(suite)),
        #("case", json.string(case_name)),
        #("outcome", outcome_json(outcome)),
        #("duration_ms", json.int(duration_ms)),
      ])
    RunFinished(run_id, summary) ->
      json.object([
        #("type", json.string("run_finished")),
        #("run_id", json.int(run_id)),
        #("summary", summary_json(summary)),
      ])
  }
  json.to_string(json)
}

fn outcome_json(outcome: Outcome) -> json.Json {
  case outcome {
    Passed -> json.object([#("kind", json.string("passed"))])
    Skipped -> json.object([#("kind", json.string("skipped"))])
    Failed(failures) ->
      json.object([
        #("kind", json.string("failed")),
        #("failures", json.array(failures, failure_json)),
      ])
  }
}

fn failure_json(failure: Failure) -> json.Json {
  case failure {
    EqualityMismatch(expected, actual, diff) ->
      json.object([
        #("kind", json.string("equality_mismatch")),
        #("expected", json.string(expected)),
        #("actual", json.string(actual)),
        #("diff", json.nullable(diff, json.string)),
      ])
    AssertionFailed(message) ->
      json.object([
        #("kind", json.string("assertion_failed")),
        #("message", json.string(message)),
      ])
    UnexpectedError(name, message) ->
      json.object([
        #("kind", json.string("unexpected_error")),
        #("name", json.string(name)),
        #("message", json.string(message)),
      ])
  }
}

fn summary_json(summary: Summary) -> json.Json {
  json.object([
    #("passed", json.int(summary.passed)),
    #("failed", json.int(summary.failed)),
    #("skipped", json.int(summary.skipped)),
    #("duration_ms", json.int(summary.duration_ms)),
  ])
}
