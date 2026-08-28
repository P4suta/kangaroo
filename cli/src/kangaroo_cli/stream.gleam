import gleam/dynamic/decode as decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import kangaroo/event.{
  CaseFinished,
  CaseStarted,
  RunFinished,
  RunStarted,
  type Event,
}
import kangaroo/failure.{
  AssertionFailed,
  EqualityMismatch,
  Failed,
  Passed,
  Skipped,
  UnexpectedError,
  type Failure,
  type Outcome,
}
import kangaroo/report.{Summary, type Summary}

/// Parses the newline-delimited JSON events emitted by the test runner into
/// typed events. Blank and malformed lines are skipped.
pub fn parse_events(output: String) -> List(Event) {
  output
  |> string.split("\n")
  |> list.filter_map(parse_line)
}

fn parse_line(line: String) -> Result(Event, Nil) {
  let trimmed = string.trim(line)
  case trimmed {
    "" -> Error(Nil)
    _ ->
      json.parse(trimmed, using: event_decoder())
      |> result.map_error(fn(_) { Nil })
  }
}

fn event_decoder() -> decode.Decoder(Event) {
  decode.field("type", decode.string, fn(event_type) {
    case event_type {
      "run_started" ->
        decode.field("run_id", decode.int, fn(run_id) {
          decode.field("case_count", decode.int, fn(count) {
            decode.success(RunStarted(run_id, count))
          })
        })
      "case_started" ->
        decode.field("suite", decode.string, fn(suite) {
          decode.field("case", decode.string, fn(case_name) {
            decode.success(CaseStarted(suite, case_name))
          })
        })
      "case_finished" -> case_finished_decoder()
      "run_finished" ->
        decode.field("run_id", decode.int, fn(run_id) {
          decode.field("summary", summary_decoder(), fn(summary) {
            decode.success(RunFinished(run_id, summary))
          })
        })
      _ -> decode.failure(RunStarted(-1, -1), "known event type")
    }
  })
}

fn case_finished_decoder() -> decode.Decoder(Event) {
  decode.field("suite", decode.string, fn(suite) {
    decode.field("case", decode.string, fn(case_name) {
      decode.field("outcome", outcome_decoder(), fn(outcome) {
        decode.field("duration_ms", decode.int, fn(duration_ms) {
          decode.success(CaseFinished(suite, case_name, outcome, duration_ms))
        })
      })
    })
  })
}

fn outcome_decoder() -> decode.Decoder(Outcome) {
  decode.field("kind", decode.string, fn(kind) {
    case kind {
      "passed" -> decode.success(Passed)
      "skipped" -> decode.success(Skipped)
      "failed" ->
        decode.field("failures", decode.list(failure_decoder()), fn(failures) {
          decode.success(Failed(failures))
        })
      _ -> decode.failure(Passed, "known outcome kind")
    }
  })
}

fn failure_decoder() -> decode.Decoder(Failure) {
  decode.field("kind", decode.string, fn(kind) {
    case kind {
      "equality_mismatch" ->
        decode.field("expected", decode.string, fn(expected) {
          decode.field("actual", decode.string, fn(actual) {
            decode.field("diff", decode.optional(decode.string), fn(diff) {
              decode.success(EqualityMismatch(expected, actual, diff))
            })
          })
        })
      "assertion_failed" ->
        decode.field("message", decode.string, fn(message) {
          decode.success(AssertionFailed(message))
        })
      "unexpected_error" ->
        decode.field("name", decode.string, fn(name) {
          decode.field("message", decode.string, fn(message) {
            decode.success(UnexpectedError(name, message))
          })
        })
      _ -> decode.failure(AssertionFailed("unknown failure"), "known failure kind")
    }
  })
}

fn summary_decoder() -> decode.Decoder(Summary) {
  decode.field("passed", decode.int, fn(passed) {
    decode.field("failed", decode.int, fn(failed) {
      decode.field("skipped", decode.int, fn(skipped) {
        decode.field("duration_ms", decode.int, fn(duration_ms) {
          decode.success(Summary(passed, failed, skipped, duration_ms))
        })
      })
    })
  })
}
