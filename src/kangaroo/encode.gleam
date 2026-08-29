import gleam/dynamic/decode as dynamic_decode
import gleam/json
import gleam/option.{None, Some}
import gleam/result
import kangaroo/event.{
  type Event, CaseFinished, CaseOutput, CaseStarted, RunFinished, RunStarted,
  SuiteFinished, SuiteStarted,
}
import kangaroo/failure.{
  type Failure, type Outcome, AssertionFailed, EqualityMismatch, Failed, Flaky,
  Passed, Skipped, SkippedWithReason, UnexpectedError,
}
import kangaroo/internal/fs
import kangaroo/location.{type Location, Location}
import kangaroo/report.{type Summary, Summary}

/// The sink used for machine-readable output: every event is printed as a
/// single JSON object on its own line. Enabled by setting the `KANGAROO_JSON`
/// environment variable.
pub fn json_sink(event: Event) -> Nil {
  fs.write_stdout_line(encode(event))
}

pub fn encode(event: Event) -> String {
  json.to_string(json(event))
}

/// Decodes the event format emitted by `encode`. Watch/TUI consumers use this
/// strict boundary to ignore compiler logs and malformed child output.
pub fn decode(source: String) -> Result(Event, String) {
  json.parse(source, using: event_decoder())
  |> result.map_error(fn(_) { "invalid kangaroo event" })
}

pub fn json(event: Event) -> json.Json {
  case event {
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
    CaseOutput(suite, case_name, stdout, stderr, outcome) ->
      json.object([
        #("type", json.string("case_output")),
        #("suite", json.string(suite)),
        #("case", json.string(case_name)),
        #("stdout", json.string(stdout)),
        #("stderr", json.string(stderr)),
        #("outcome", outcome_json(outcome)),
      ])
    CaseFinished(suite, case_name, outcome, duration_ms) ->
      json.object([
        #("type", json.string("case_finished")),
        #("suite", json.string(suite)),
        #("case", json.string(case_name)),
        #("outcome", outcome_json(outcome)),
        #("duration_ms", json.int(duration_ms)),
      ])
    SuiteStarted(suite) ->
      json.object([
        #("type", json.string("suite_started")),
        #("suite", json.string(suite)),
      ])
    SuiteFinished(suite, outcome) ->
      json.object([
        #("type", json.string("suite_finished")),
        #("suite", json.string(suite)),
        #("outcome", outcome_json(outcome)),
      ])
    RunFinished(run_id, summary) ->
      json.object([
        #("type", json.string("run_finished")),
        #("run_id", json.int(run_id)),
        #("summary", summary_json(summary)),
      ])
  }
}

fn outcome_json(outcome: Outcome) -> json.Json {
  case outcome {
    Passed -> json.object([#("kind", json.string("passed"))])
    Skipped -> json.object([#("kind", json.string("skipped"))])
    SkippedWithReason(reason) ->
      json.object([
        #("kind", json.string("skipped")),
        #("reason", json.string(reason)),
      ])
    Flaky(failures, attempts) ->
      json.object([
        #("kind", json.string("flaky")),
        #("attempts", json.int(attempts)),
        #("failures", json.array(failures, failure_json)),
      ])
    Failed(failures) ->
      json.object([
        #("kind", json.string("failed")),
        #("failures", json.array(failures, failure_json)),
      ])
  }
}

fn failure_json(failure: Failure) -> json.Json {
  case failure {
    EqualityMismatch(expected, actual, diff, location) ->
      json.object([
        #("kind", json.string("equality_mismatch")),
        #("expected", json.string(expected)),
        #("actual", json.string(actual)),
        #("diff", json.nullable(diff, json.string)),
        #("location", json.nullable(location, location_json)),
      ])
    AssertionFailed(message, location) ->
      json.object([
        #("kind", json.string("assertion_failed")),
        #("message", json.string(message)),
        #("location", json.nullable(location, location_json)),
      ])
    UnexpectedError(name, message, location) ->
      json.object([
        #("kind", json.string("unexpected_error")),
        #("name", json.string(name)),
        #("message", json.string(message)),
        #("location", json.nullable(location, location_json)),
      ])
  }
}

fn location_json(location: Location) -> json.Json {
  json.object([
    #("file", json.string(location.file)),
    #("line", json.int(location.line)),
    #("column", json.nullable(location.column, json.int)),
  ])
}

fn summary_json(summary: Summary) -> json.Json {
  json.object([
    #("passed", json.int(summary.passed)),
    #("failed", json.int(summary.failed)),
    #("skipped", json.int(summary.skipped)),
    #("duration_ms", json.int(summary.duration_ms)),
  ])
}

fn event_decoder() -> dynamic_decode.Decoder(Event) {
  dynamic_decode.field("type", dynamic_decode.string, fn(event_type) {
    case event_type {
      "run_started" ->
        dynamic_decode.field("run_id", dynamic_decode.int, fn(run_id) {
          dynamic_decode.field("case_count", dynamic_decode.int, fn(case_count) {
            dynamic_decode.success(RunStarted(run_id, case_count))
          })
        })
      "case_started" ->
        dynamic_decode.field("suite", dynamic_decode.string, fn(suite) {
          dynamic_decode.field("case", dynamic_decode.string, fn(case_name) {
            dynamic_decode.success(CaseStarted(suite, case_name))
          })
        })
      "case_output" ->
        dynamic_decode.field("suite", dynamic_decode.string, fn(suite) {
          dynamic_decode.field("case", dynamic_decode.string, fn(case_name) {
            dynamic_decode.field("stdout", dynamic_decode.string, fn(stdout) {
              dynamic_decode.field("stderr", dynamic_decode.string, fn(stderr) {
                dynamic_decode.field("outcome", outcome_decoder(), fn(outcome) {
                  dynamic_decode.success(CaseOutput(
                    suite,
                    case_name,
                    stdout,
                    stderr,
                    outcome,
                  ))
                })
              })
            })
          })
        })
      "case_finished" ->
        dynamic_decode.field("suite", dynamic_decode.string, fn(suite) {
          dynamic_decode.field("case", dynamic_decode.string, fn(case_name) {
            dynamic_decode.field("outcome", outcome_decoder(), fn(outcome) {
              dynamic_decode.field(
                "duration_ms",
                dynamic_decode.int,
                fn(duration_ms) {
                  dynamic_decode.success(CaseFinished(
                    suite,
                    case_name,
                    outcome,
                    duration_ms,
                  ))
                },
              )
            })
          })
        })
      "suite_started" ->
        dynamic_decode.field("suite", dynamic_decode.string, fn(suite) {
          dynamic_decode.success(SuiteStarted(suite))
        })
      "suite_finished" ->
        dynamic_decode.field("suite", dynamic_decode.string, fn(suite) {
          dynamic_decode.field("outcome", outcome_decoder(), fn(outcome) {
            dynamic_decode.success(SuiteFinished(suite, outcome))
          })
        })
      "run_finished" ->
        dynamic_decode.field("run_id", dynamic_decode.int, fn(run_id) {
          dynamic_decode.field("summary", summary_decoder(), fn(summary) {
            dynamic_decode.success(RunFinished(run_id, summary))
          })
        })
      _ -> dynamic_decode.failure(RunStarted(0, 0), "known event type")
    }
  })
}

fn outcome_decoder() -> dynamic_decode.Decoder(Outcome) {
  dynamic_decode.field("kind", dynamic_decode.string, fn(kind) {
    case kind {
      "passed" -> dynamic_decode.success(Passed)
      "skipped" ->
        dynamic_decode.optional_field(
          "reason",
          None,
          dynamic_decode.optional(dynamic_decode.string),
          fn(reason) {
            dynamic_decode.success(case reason {
              Some(reason) -> SkippedWithReason(reason)
              None -> Skipped
            })
          },
        )
      "failed" ->
        dynamic_decode.field(
          "failures",
          dynamic_decode.list(failure_decoder()),
          fn(failures) { dynamic_decode.success(Failed(failures)) },
        )
      "flaky" ->
        dynamic_decode.field(
          "failures",
          dynamic_decode.list(failure_decoder()),
          fn(failures) {
            dynamic_decode.field("attempts", dynamic_decode.int, fn(attempts) {
              dynamic_decode.success(Flaky(failures, attempts))
            })
          },
        )
      _ -> dynamic_decode.failure(Passed, "known outcome kind")
    }
  })
}

fn failure_decoder() -> dynamic_decode.Decoder(Failure) {
  dynamic_decode.field("kind", dynamic_decode.string, fn(kind) {
    case kind {
      "equality_mismatch" ->
        dynamic_decode.field("expected", dynamic_decode.string, fn(expected) {
          dynamic_decode.field("actual", dynamic_decode.string, fn(actual) {
            dynamic_decode.field(
              "diff",
              dynamic_decode.optional(dynamic_decode.string),
              fn(diff) {
                dynamic_decode.field(
                  "location",
                  dynamic_decode.optional(location_decoder()),
                  fn(location) {
                    dynamic_decode.success(EqualityMismatch(
                      expected,
                      actual,
                      diff,
                      location,
                    ))
                  },
                )
              },
            )
          })
        })
      "assertion_failed" ->
        dynamic_decode.field("message", dynamic_decode.string, fn(message) {
          dynamic_decode.field(
            "location",
            dynamic_decode.optional(location_decoder()),
            fn(location) {
              dynamic_decode.success(AssertionFailed(message, location))
            },
          )
        })
      "unexpected_error" ->
        dynamic_decode.field("name", dynamic_decode.string, fn(name) {
          dynamic_decode.field("message", dynamic_decode.string, fn(message) {
            dynamic_decode.field(
              "location",
              dynamic_decode.optional(location_decoder()),
              fn(location) {
                dynamic_decode.success(UnexpectedError(name, message, location))
              },
            )
          })
        })
      _ ->
        dynamic_decode.failure(AssertionFailed("", None), "known failure kind")
    }
  })
}

fn location_decoder() -> dynamic_decode.Decoder(Location) {
  dynamic_decode.field("file", dynamic_decode.string, fn(file) {
    dynamic_decode.field("line", dynamic_decode.int, fn(line) {
      dynamic_decode.field(
        "column",
        dynamic_decode.optional(dynamic_decode.int),
        fn(column) { dynamic_decode.success(Location(file, line, column)) },
      )
    })
  })
}

fn summary_decoder() -> dynamic_decode.Decoder(Summary) {
  dynamic_decode.field("passed", dynamic_decode.int, fn(passed) {
    dynamic_decode.field("failed", dynamic_decode.int, fn(failed) {
      dynamic_decode.field("skipped", dynamic_decode.int, fn(skipped) {
        dynamic_decode.field("duration_ms", dynamic_decode.int, fn(duration_ms) {
          dynamic_decode.success(Summary(passed, failed, skipped, duration_ms))
        })
      })
    })
  })
}
