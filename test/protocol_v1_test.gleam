import gleam/option.{None, Some}
import gleam/string
import kangaroo/internal/index.{IndexedTest}
import kangaroo/internal/protocol.{
  CancelRequest, DiscoverRequest, RunRequest, ShutdownRequest, WatchRequest,
}

fn indexed() {
  IndexedTest(
    id: "test/math.gleam::addition_test",
    name: "addition_test",
    path: "test/math.gleam",
    module: "math",
    line: 7,
    column: 1,
    end_line: 9,
    end_column: 2,
    tags: ["unit"],
    timeout_ms: None,
    serial: False,
    skip: None,
  )
}

pub fn protocol_decodes_every_daemon_request_with_defaults_test() {
  assert protocol.decode_request(
      "{\"protocol_version\":1,\"id\":\"a\",\"command\":\"discover\"}",
    )
    == Ok(DiscoverRequest("a"))
  assert protocol.decode_request(
      "{\"protocol_version\":1,\"id\":\"b\",\"command\":\"run\",\"selectors\":[\"tag:unit\"],\"include_tags\":[\"fast\"]}",
    )
    == Ok(RunRequest("b", ["tag:unit"], ["fast"], []))
  assert protocol.decode_request(
      "{\"protocol_version\":1,\"id\":\"c\",\"command\":\"watch\"}",
    )
    == Ok(WatchRequest("c", [], [], []))
  assert protocol.decode_request(
      "{\"protocol_version\":1,\"id\":\"d\",\"command\":\"cancel\",\"operation_id\":\"b\"}",
    )
    == Ok(CancelRequest("d", "b"))
  assert protocol.decode_request(
      "{\"protocol_version\":1,\"id\":\"e\",\"command\":\"shutdown\"}",
    )
    == Ok(ShutdownRequest("e"))
}

pub fn protocol_rejects_unsupported_versions_and_commands_test() {
  assert protocol.decode_request(
      "{\"protocol_version\":2,\"id\":\"a\",\"command\":\"discover\"}",
    )
    == Error("unsupported protocol_version 2; expected 1")
  assert protocol.decode_request(
      "{\"protocol_version\":1,\"id\":\"a\",\"command\":\"erase\"}",
    )
    == Error("unknown daemon command `erase`")
}

pub fn protocol_rejects_empty_identity_and_filter_values_test() {
  assert protocol.decode_request(
      "{\"protocol_version\":1,\"id\":\"\",\"command\":\"discover\"}",
    )
    == Error("request id cannot be empty")
  assert protocol.decode_request(
      "{\"protocol_version\":1,\"id\":\"run-1\",\"command\":\"run\",\"selectors\":[\"\"]}",
    )
    == Error("selector cannot be empty")
  assert protocol.decode_request(
      "{\"protocol_version\":1,\"id\":\"run-1\",\"command\":\"run\",\"include_tags\":[\"\"]}",
    )
    == Error("include_tags cannot contain an empty value")
  assert protocol.decode_request(
      "{\"protocol_version\":1,\"id\":\"watch-1\",\"command\":\"watch\",\"exclude_tags\":[\"\"]}",
    )
    == Error("exclude_tags cannot contain an empty value")
  assert protocol.decode_request(
      "{\"protocol_version\":1,\"id\":\"  \",\"command\":\"discover\"}",
    )
    == Error("request id cannot be empty")
  assert protocol.decode_request(
      "{\"protocol_version\":1,\"id\":\"run-1\",\"command\":\"run\",\"include_tags\":[\" \"]}",
    )
    == Error("include_tags cannot contain an empty value")
  assert protocol.decode_request(
      "{\"protocol_version\":1,\"id\":\"cancel-1\",\"command\":\"cancel\",\"operation_id\":\" \"}",
    )
    == Error("cancel requires operation_id")
}

pub fn daemon_child_protocol_requires_the_private_mode_handshake_test() {
  assert protocol.child_environment("run-1")
    == [
      #("KANGAROO_PROTOCOL_MODE", "kangaroo-daemon-child-v1"),
      #("KANGAROO_PROTOCOL_REQUEST_ID", "run-1"),
    ]
  assert protocol.child_request_id(
      Some("kangaroo-daemon-child-v1"),
      Some("run-1"),
    )
    == Some("run-1")
  assert protocol.child_request_id(None, Some("run-1")) == None
  assert protocol.child_request_id(Some("unrelated"), Some("run-1")) == None
  assert protocol.child_request_id(Some("kangaroo-daemon-child-v1"), Some(" "))
    == None
}

pub fn protocol_encodes_discovery_with_one_based_ranges_test() {
  let line = protocol.encode_discovered("req-1", [indexed()])
  assert string.contains(line, "\"protocol_version\":1")
  assert string.contains(line, "\"request_id\":\"req-1\"")
  assert string.contains(line, "\"line\":7")
  assert string.contains(line, "\"end_line\":9")
  assert string.contains(line, "test/math.gleam::addition_test")
}

pub fn protocol_encodes_operation_lifecycle_with_stable_ids_test() {
  let started = protocol.encode_started("request-1", "run-1", "run")
  assert string.contains(started, "\"type\":\"started\"")
  assert string.contains(started, "\"operation_id\":\"run-1\"")
  assert string.contains(started, "\"operation\":\"run\"")
  let cancelled = protocol.encode_cancelled("request-2", "run-1")
  assert string.contains(cancelled, "\"type\":\"cancelled\"")
  assert string.contains(cancelled, "\"operation_id\":\"run-1\"")
}

pub fn protocol_normalises_unexpected_child_status_to_infrastructure_test() {
  assert protocol.encode_completed("run-1", 137)
    == "{\"protocol_version\":1,\"type\":\"completed\",\"request_id\":\"run-1\",\"exit_code\":2}"
  assert protocol.encode_completed("run-1", -1)
    == "{\"protocol_version\":1,\"type\":\"completed\",\"request_id\":\"run-1\",\"exit_code\":2}"
}

pub fn protocol_forwards_only_validated_child_event_envelopes_test() {
  assert protocol.forwardable_event(
    "{\"protocol_version\":1,\"type\":\"event\",\"request_id\":\"run-1\",\"event\":{\"type\":\"run_started\",\"run_id\":1,\"case_count\":1}}",
    "run-1",
  )
  assert !protocol.forwardable_event(
    "{\"protocol_version\":1,\"type\":\"event\",\"request_id\":\"run-1\",\"event\":{}}",
    "run-1",
  )
  assert !protocol.forwardable_event(
    "{\"protocol_version\":1,\"type\":\"event\",\"request_id\":\"run-1\",\"event\":{\"type\":\"case_finished\",\"suite\":\"math\",\"case\":\"addition\",\"outcome\":{\"kind\":\"passed\"},\"duration_ms\":\"fast\"}}",
    "run-1",
  )
  assert !protocol.forwardable_event("Compiling project", "run-1")
  assert !protocol.forwardable_event(
    "{\"protocol_version\":1,\"type\":\"completed\",\"request_id\":\"run-1\"}",
    "run-1",
  )
  assert !protocol.forwardable_event(
    "{\"protocol_version\":1,\"type\":\"event\",\"request_id\":\"other\",\"event\":{}}",
    "run-1",
  )
  assert !protocol.forwardable_event(
    "{\"protocol_version\":1,\"type\":\"event\",\"request_id\":\"run-1\",\"event\":{\"type\":\"run_started\",\"run_id\":1,\"case_count\":1},\"extra\":true}",
    "run-1",
  )
}
