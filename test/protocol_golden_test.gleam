import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import kangaroo/event.{CaseFinished}
import kangaroo/failure.{Passed}
import kangaroo/internal/fs
import kangaroo/internal/index.{type IndexedTest, IndexedTest}
import kangaroo/internal/protocol

pub fn protocol_v1_output_matches_golden_test() {
  let assert Ok(golden) = fs.read_file("test/golden/protocol-v1.ndjson")
  let golden = string.replace(golden, each: "\r\n", with: "\n")
  let actual =
    [
      protocol.encode_discovered("discover-1", [indexed_test()]),
      protocol.encode_started("run-1", "run-1", "run"),
      protocol.encode_event(
        "run-1",
        CaseFinished("math", "test/math.gleam::addition_test", Passed, 4),
      ),
      protocol.encode_completed("run-1", 0),
      protocol.encode_cancelled("cancel-1", "watch-1"),
      protocol.encode_error("bad-1", "invalid \"request\""),
      protocol.encode_ok("shutdown-1", "shutdown"),
    ]
    |> string.join("\n")
    |> string.append("\n")
  assert actual == golden
}

pub fn protocol_v1_rejects_malformed_fuzz_corpus_test() {
  let malformed = [
    "",
    "{",
    "null",
    "[]",
    "{}",
    "{\"protocol_version\":1,\"id\":\"x\"}",
    "{\"protocol_version\":1,\"command\":\"discover\"}",
    "{\"id\":\"x\",\"command\":\"discover\"}",
    "{\"protocol_version\":\"1\",\"id\":\"x\",\"command\":\"discover\"}",
    "{\"protocol_version\":0,\"id\":\"x\",\"command\":\"discover\"}",
    "{\"protocol_version\":2,\"id\":\"x\",\"command\":\"discover\"}",
    "{\"protocol_version\":1,\"id\":1,\"command\":\"discover\"}",
    "{\"protocol_version\":1,\"id\":\"x\",\"command\":1}",
    "{\"protocol_version\":1,\"id\":\"x\",\"command\":\"erase\"}",
    "{\"protocol_version\":1,\"id\":\"x\",\"command\":\"run\",\"selectors\":\"all\"}",
    "{\"protocol_version\":1,\"id\":\"x\",\"command\":\"watch\",\"include_tags\":[1]}",
    "{\"protocol_version\":1,\"id\":\"x\",\"command\":\"run\",\"exclude_tags\":null}",
    "{\"protocol_version\":1,\"id\":\"x\",\"command\":\"cancel\"}",
    "{\"protocol_version\":1,\"id\":\"x\",\"command\":\"cancel\",\"operation_id\":\"\"}",
    "{\"protocol_version\":1,\"id\":\"x\",\"command\":\"cancel\",\"operation_id\":1}",
    "{\"protocol_version\":1,\"id\":\"x\",\"command\":\"discover\",\"extra\":true}",
    "{\"protocol_version\":1,\"id\":\"x\",\"command\":\"discover\",\"selectors\":[]}",
    "{\"protocol_version\":1,\"id\":\"x\",\"command\":\"run\",\"operation_id\":\"other\"}",
  ]
  assert list.all(malformed, fn(line) {
    result.is_error(protocol.decode_request(line))
  })
}

pub fn protocol_v1_preserves_large_selector_arrays_test() {
  let selectors = list.repeat("test/large.gleam::case_test", times: 2048)
  let line =
    json.object([
      #("protocol_version", json.int(1)),
      #("id", json.string("large-1")),
      #("command", json.string("run")),
      #("selectors", json.array(selectors, json.string)),
    ])
    |> json.to_string
  let assert Ok(protocol.RunRequest(_, decoded, [], [])) =
    protocol.decode_request(line)
  assert list.length(decoded) == 2048
}

fn indexed_test() -> IndexedTest {
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
