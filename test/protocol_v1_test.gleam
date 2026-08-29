import gleam/option.{None}
import gleam/string
import kangaroo/internal/index.{IndexedTest}
import kangaroo/internal/legacy/expect.{expect, to_be_true, to_equal}
import kangaroo/internal/legacy/suite.{it, suite}
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

pub fn suites() {
  [
    suite("protocol v1", [
      it("decodes every daemon request with defaults", fn() {
        expect(protocol.decode_request(
          "{\"protocol_version\":1,\"id\":\"a\",\"command\":\"discover\"}",
        ))
        |> to_equal(Ok(DiscoverRequest("a")))
        expect(protocol.decode_request(
          "{\"protocol_version\":1,\"id\":\"b\",\"command\":\"run\",\"selectors\":[\"tag:unit\"],\"include_tags\":[\"fast\"]}",
        ))
        |> to_equal(Ok(RunRequest("b", ["tag:unit"], ["fast"], [])))
        expect(protocol.decode_request(
          "{\"protocol_version\":1,\"id\":\"c\",\"command\":\"watch\"}",
        ))
        |> to_equal(Ok(WatchRequest("c", [], [], [])))
        expect(protocol.decode_request(
          "{\"protocol_version\":1,\"id\":\"d\",\"command\":\"cancel\",\"operation_id\":\"b\"}",
        ))
        |> to_equal(Ok(CancelRequest("d", "b")))
        expect(protocol.decode_request(
          "{\"protocol_version\":1,\"id\":\"e\",\"command\":\"shutdown\"}",
        ))
        |> to_equal(Ok(ShutdownRequest("e")))
      }),
      it("rejects unsupported protocol versions and commands", fn() {
        expect(protocol.decode_request(
          "{\"protocol_version\":2,\"id\":\"a\",\"command\":\"discover\"}",
        ))
        |> to_equal(Error("unsupported protocol_version 2; expected 1"))
        expect(protocol.decode_request(
          "{\"protocol_version\":1,\"id\":\"a\",\"command\":\"erase\"}",
        ))
        |> to_equal(Error("unknown daemon command `erase`"))
      }),
      it("encodes discovered tests with normalised one-based ranges", fn() {
        let line = protocol.encode_discovered("req-1", [indexed()])
        expect(string.contains(line, "\"protocol_version\":1"))
        |> to_be_true()
        expect(string.contains(line, "\"request_id\":\"req-1\""))
        |> to_be_true()
        expect(string.contains(line, "\"line\":7")) |> to_be_true()
        expect(string.contains(line, "\"end_line\":9")) |> to_be_true()
        expect(string.contains(line, "test/math.gleam::addition_test"))
        |> to_be_true()
      }),
      it("encodes operation lifecycle messages with stable ids", fn() {
        let started = protocol.encode_started("request-1", "run-1", "run")
        expect(string.contains(started, "\"type\":\"started\""))
        |> to_be_true()
        expect(string.contains(started, "\"operation_id\":\"run-1\""))
        |> to_be_true()
        expect(string.contains(started, "\"operation\":\"run\""))
        |> to_be_true()
        let cancelled = protocol.encode_cancelled("request-2", "run-1")
        expect(string.contains(cancelled, "\"type\":\"cancelled\""))
        |> to_be_true()
        expect(string.contains(cancelled, "\"operation_id\":\"run-1\""))
        |> to_be_true()
      }),
      it("forwards only validated event envelopes from daemon children", fn() {
        expect(protocol.forwardable_event(
          "{\"protocol_version\":1,\"type\":\"event\",\"request_id\":\"run-1\",\"event\":{}}",
          "run-1",
        ))
        |> to_equal(True)
        expect(protocol.forwardable_event("Compiling project", "run-1"))
        |> to_equal(False)
        expect(protocol.forwardable_event(
          "{\"protocol_version\":1,\"type\":\"completed\",\"request_id\":\"run-1\"}",
          "run-1",
        ))
        |> to_equal(False)
        expect(protocol.forwardable_event(
          "{\"protocol_version\":1,\"type\":\"event\",\"request_id\":\"other\",\"event\":{}}",
          "run-1",
        ))
        |> to_equal(False)
      }),
    ]),
  ]
}
