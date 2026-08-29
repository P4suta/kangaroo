import gleam/dynamic/decode
import gleam/json
import gleam/result

/// CLI-level events about the machinery around a run — the compile phase
/// — distinct from the runner's `kangaroo/event` stream. They are emitted
/// on the same protocol stream in watch/json mode so editors can show
/// progress while the project compiles.
pub type SessionEvent {
  /// The compile-only subprocess was started.
  CompileStarted
  /// The compile-only subprocess finished.
  CompileFinished
}

/// Encodes a session event as its protocol line.
pub fn encode(event: SessionEvent) -> String {
  let body = case event {
    CompileStarted -> json.object([#("type", json.string("compile_started"))])
    CompileFinished -> json.object([#("type", json.string("compile_finished"))])
  }
  json.to_string(body)
}

/// Decodes one protocol line into a session event, or fails when the
/// line is not a session event.
pub fn decode(line: String) -> Result(SessionEvent, Nil) {
  json.parse(
    line,
    using: decode.field("type", decode.string, fn(event_type) {
      case event_type {
        "compile_started" -> decode.success(CompileStarted)
        "compile_finished" -> decode.success(CompileFinished)
        _ -> decode.failure(CompileStarted, "known session event type")
      }
    }),
  )
  |> result.map_error(fn(_) { Nil })
}
