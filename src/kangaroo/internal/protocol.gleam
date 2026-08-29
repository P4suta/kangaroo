import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import kangaroo/encode
import kangaroo/event.{type Event}
import kangaroo/internal/index.{type IndexedTest}

pub const version = 1

pub type Request {
  DiscoverRequest(id: String)
  RunRequest(
    id: String,
    selectors: List(String),
    include_tags: List(String),
    exclude_tags: List(String),
  )
  WatchRequest(
    id: String,
    selectors: List(String),
    include_tags: List(String),
    exclude_tags: List(String),
  )
  CancelRequest(id: String, operation_id: String)
  ShutdownRequest(id: String)
}

type Envelope {
  Envelope(
    protocol_version: Int,
    id: String,
    command: String,
    selectors: List(String),
    include_tags: List(String),
    exclude_tags: List(String),
    operation_id: String,
  )
}

type ChildEnvelope {
  ChildEnvelope(protocol_version: Int, message_type: String, request_id: String)
}

pub fn decode_request(line: String) -> Result(Request, String) {
  use fields <- result.try(
    json.parse(line, using: decode.dict(decode.string, decode.dynamic))
    |> result.map_error(fn(_) { "invalid daemon protocol request" }),
  )
  use envelope <- result.try(
    json.parse(line, using: envelope_decoder())
    |> result.map_error(fn(_) { "invalid daemon protocol request" }),
  )
  use _ <- result.try(validate_fields(dict.keys(fields), envelope.command))
  case envelope.protocol_version {
    1 -> request(envelope)
    unsupported ->
      Error(
        "unsupported protocol_version "
        <> int.to_string(unsupported)
        <> "; expected 1",
      )
  }
}

fn validate_fields(
  fields: List(String),
  command: String,
) -> Result(Nil, String) {
  let allowed = case command {
    "run" | "watch" -> [
      "protocol_version",
      "id",
      "command",
      "selectors",
      "include_tags",
      "exclude_tags",
    ]
    "cancel" -> ["protocol_version", "id", "command", "operation_id"]
    _ -> ["protocol_version", "id", "command"]
  }
  let unexpected =
    fields
    |> list.filter(fn(field) { !list.contains(allowed, field) })
    |> list.sort(string.compare)
  case unexpected {
    [] -> Ok(Nil)
    [field, ..] ->
      Error(
        "unexpected field `" <> field <> "` for command `" <> command <> "`",
      )
  }
}

/// Validates the only stdout records a daemon may forward from a child test
/// generation. Compiler logs and forged lifecycle messages are kept off the
/// protocol stream.
pub fn forwardable_event(line: String, request_id: String) -> Bool {
  case json.parse(line, using: child_envelope_decoder()) {
    Ok(ChildEnvelope(1, "event", child_request_id)) ->
      child_request_id == request_id
    _ -> False
  }
}

fn child_envelope_decoder() -> decode.Decoder(ChildEnvelope) {
  decode.field("protocol_version", decode.int, fn(protocol_version) {
    decode.field("type", decode.string, fn(message_type) {
      decode.field("request_id", decode.string, fn(request_id) {
        decode.success(ChildEnvelope(protocol_version, message_type, request_id))
      })
    })
  })
}

fn request(envelope: Envelope) -> Result(Request, String) {
  case envelope.command {
    "discover" -> Ok(DiscoverRequest(envelope.id))
    "run" ->
      Ok(RunRequest(
        envelope.id,
        envelope.selectors,
        envelope.include_tags,
        envelope.exclude_tags,
      ))
    "watch" ->
      Ok(WatchRequest(
        envelope.id,
        envelope.selectors,
        envelope.include_tags,
        envelope.exclude_tags,
      ))
    "cancel" ->
      case envelope.operation_id {
        "" -> Error("cancel requires operation_id")
        operation_id -> Ok(CancelRequest(envelope.id, operation_id))
      }
    "shutdown" -> Ok(ShutdownRequest(envelope.id))
    unknown -> Error("unknown daemon command `" <> unknown <> "`")
  }
}

fn envelope_decoder() -> decode.Decoder(Envelope) {
  decode.field("protocol_version", decode.int, fn(protocol_version) {
    decode.field("id", decode.string, fn(id) {
      decode.field("command", decode.string, fn(command) {
        decode.optional_field(
          "selectors",
          [],
          decode.list(decode.string),
          fn(selectors) {
            decode.optional_field(
              "include_tags",
              [],
              decode.list(decode.string),
              fn(include_tags) {
                decode.optional_field(
                  "exclude_tags",
                  [],
                  decode.list(decode.string),
                  fn(exclude_tags) {
                    decode.optional_field(
                      "operation_id",
                      "",
                      decode.string,
                      fn(operation_id) {
                        decode.success(Envelope(
                          protocol_version:,
                          id:,
                          command:,
                          selectors:,
                          include_tags:,
                          exclude_tags:,
                          operation_id:,
                        ))
                      },
                    )
                  },
                )
              },
            )
          },
        )
      })
    })
  })
}

pub fn encode_discovered(
  request_id: String,
  tests: List(IndexedTest),
) -> String {
  json.object([
    #("protocol_version", json.int(version)),
    #("type", json.string("discovered")),
    #("request_id", json.string(request_id)),
    #("tests", json.array(tests, encode_test)),
  ])
  |> json.to_string
}

pub fn encode_ok(request_id: String, event_type: String) -> String {
  json.object([
    #("protocol_version", json.int(version)),
    #("type", json.string(event_type)),
    #("request_id", json.string(request_id)),
  ])
  |> json.to_string
}

pub fn encode_started(
  request_id: String,
  operation_id: String,
  operation: String,
) -> String {
  json.object([
    #("protocol_version", json.int(version)),
    #("type", json.string("started")),
    #("request_id", json.string(request_id)),
    #("operation_id", json.string(operation_id)),
    #("operation", json.string(operation)),
  ])
  |> json.to_string
}

pub fn encode_cancelled(request_id: String, operation_id: String) -> String {
  json.object([
    #("protocol_version", json.int(version)),
    #("type", json.string("cancelled")),
    #("request_id", json.string(request_id)),
    #("operation_id", json.string(operation_id)),
  ])
  |> json.to_string
}

pub fn encode_error(request_id: String, message: String) -> String {
  json.object([
    #("protocol_version", json.int(version)),
    #("type", json.string("error")),
    #("request_id", json.string(request_id)),
    #("message", json.string(message)),
  ])
  |> json.to_string
}

pub fn encode_event(request_id: String, event: Event) -> String {
  json.object([
    #("protocol_version", json.int(version)),
    #("type", json.string("event")),
    #("request_id", json.string(request_id)),
    #("event", encode.json(event)),
  ])
  |> json.to_string
}

pub fn encode_completed(request_id: String, exit_code: Int) -> String {
  json.object([
    #("protocol_version", json.int(version)),
    #("type", json.string("completed")),
    #("request_id", json.string(request_id)),
    #("exit_code", json.int(exit_code)),
  ])
  |> json.to_string
}

fn encode_test(indexed: IndexedTest) -> json.Json {
  json.object([
    #("id", json.string(indexed.id)),
    #("name", json.string(indexed.name)),
    #("path", json.string(indexed.path)),
    #("module", json.string(indexed.module)),
    #("line", json.int(indexed.line)),
    #("column", json.int(indexed.column)),
    #("end_line", json.int(indexed.end_line)),
    #("end_column", json.int(indexed.end_column)),
    #("tags", json.array(indexed.tags, json.string)),
    #("timeout_ms", case indexed.timeout_ms {
      Some(value) -> json.int(value)
      None -> json.null()
    }),
    #("serial", json.bool(indexed.serial)),
  ])
}
