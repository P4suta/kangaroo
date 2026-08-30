import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import kangaroo/encode
import kangaroo/event.{type Event}
import kangaroo/internal/index.{type IndexedTest}

pub const version = 1

const child_mode_token = "kangaroo-daemon-child-v1"

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
  ChildEnvelope(
    protocol_version: Int,
    message_type: String,
    request_id: String,
    event: Event,
  )
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
  let exact_fields = case
    json.parse(line, using: decode.dict(decode.string, decode.dynamic))
  {
    Ok(fields) ->
      list.all(dict.keys(fields), fn(field) {
        list.contains(
          ["protocol_version", "type", "request_id", "event"],
          field,
        )
      })
    Error(_) -> False
  }
  case exact_fields, json.parse(line, using: child_envelope_decoder()) {
    True, Ok(ChildEnvelope(1, "event", child_request_id, _)) ->
      child_request_id == request_id
    _, _ -> False
  }
}

fn child_envelope_decoder() -> decode.Decoder(ChildEnvelope) {
  decode.field("protocol_version", decode.int, fn(protocol_version) {
    decode.field("type", decode.string, fn(message_type) {
      decode.field("request_id", decode.string, fn(request_id) {
        decode.field("event", encode.decoder(), fn(event) {
          decode.success(ChildEnvelope(
            protocol_version,
            message_type,
            request_id,
            event,
          ))
        })
      })
    })
  })
}

fn request(envelope: Envelope) -> Result(Request, String) {
  use _ <- result.try(require_non_empty(
    envelope.id,
    "request id cannot be empty",
  ))
  case envelope.command {
    "discover" -> Ok(DiscoverRequest(envelope.id))
    "run" -> {
      use _ <- result.try(validate_filters(envelope))
      Ok(RunRequest(
        envelope.id,
        envelope.selectors,
        envelope.include_tags,
        envelope.exclude_tags,
      ))
    }
    "watch" -> {
      use _ <- result.try(validate_filters(envelope))
      Ok(WatchRequest(
        envelope.id,
        envelope.selectors,
        envelope.include_tags,
        envelope.exclude_tags,
      ))
    }
    "cancel" -> {
      use _ <- result.try(require_non_empty(
        envelope.operation_id,
        "cancel requires operation_id",
      ))
      Ok(CancelRequest(envelope.id, envelope.operation_id))
    }
    "shutdown" -> Ok(ShutdownRequest(envelope.id))
    unknown -> Error("unknown daemon command `" <> unknown <> "`")
  }
}

fn validate_filters(envelope: Envelope) -> Result(Nil, String) {
  use _ <- result.try(validate_values(
    envelope.selectors,
    "selector cannot be empty",
  ))
  use _ <- result.try(validate_values(
    envelope.include_tags,
    "include_tags cannot contain an empty value",
  ))
  validate_values(
    envelope.exclude_tags,
    "exclude_tags cannot contain an empty value",
  )
}

fn validate_values(
  values: List(String),
  message: String,
) -> Result(Nil, String) {
  case list.any(values, fn(value) { string.trim(value) == "" }) {
    True -> Error(message)
    False -> Ok(Nil)
  }
}

fn require_non_empty(value: String, message: String) -> Result(Nil, String) {
  case string.trim(value) == "" {
    True -> Error(message)
    False -> Ok(Nil)
  }
}

/// Private environment handshake used between the daemon and a child runner.
/// Requiring both fields prevents an unrelated inherited request-id variable
/// from silently changing an ordinary `--reporter ndjson` stream.
pub fn child_environment(request_id: String) -> List(#(String, String)) {
  [
    #("KANGAROO_PROTOCOL_MODE", child_mode_token),
    #("KANGAROO_PROTOCOL_REQUEST_ID", request_id),
  ]
}

pub fn child_request_id(
  mode: Option(String),
  request_id: Option(String),
) -> Option(String) {
  case mode, request_id {
    Some(token), Some(request_id) if token == child_mode_token ->
      case string.trim(request_id) == "" {
        True -> None
        False -> Some(request_id)
      }
    _, _ -> None
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
    #("exit_code", json.int(protocol_exit_code(exit_code))),
  ])
  |> json.to_string
}

fn protocol_exit_code(exit_code: Int) -> Int {
  case exit_code {
    0 -> 0
    1 -> 1
    2 -> 2
    _ -> 2
  }
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
