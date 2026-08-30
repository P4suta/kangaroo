# Kangaroo daemon protocol v1

Start the daemon in a Gleam package root:

```sh
gleam run -m kangaroo -- daemon
```

The protocol is bidirectional newline-delimited JSON (NDJSON). A client writes
one request per stdin line and reads one response/event per stdout line.
Stdout is protocol-only; compiler output and logs are written to stderr.
Each request line is limited to 1 MiB of UTF-8. An overlong line produces one
`error` record with an empty request ID, is discarded through its newline, and
does not poison later requests on the same daemon.

Every record has `"protocol_version": 1`. Unknown versions and commands return
an `error` response. Request IDs are client-selected non-blank strings and
correlate all operation records. Selector and tag array entries must also be
non-blank. Paths are `/`-normalised and project-relative. Lines and columns are
one-based; discovered end positions are exclusive.

The machine-readable schema is
[`protocol-v1.schema.json`](protocol-v1.schema.json).

## Requests

Discover the current index:

```json
{"protocol_version":1,"id":"discover-1","command":"discover"}
```

Run once or start a continuous operation. Omitted selector/tag arrays default
to empty arrays:

```json
{"protocol_version":1,"id":"run-1","command":"run","selectors":["test/math_test.gleam::addition_test"],"include_tags":["unit"],"exclude_tags":["slow"]}
{"protocol_version":1,"id":"watch-1","command":"watch","selectors":[]}
```

Multiple selectors form a union; include tags are ORed and excludes win. The
request `id` is also the operation ID in v1 and must be unique while active.
The daemon accepts at most 32 concurrent run/watch operations; an excess
request receives an `error` response without starting a child process.

Cancel an active operation:

```json
{"protocol_version":1,"id":"cancel-1","command":"cancel","operation_id":"watch-1"}
```

Shut down after terminating every active child process tree:

```json
{"protocol_version":1,"id":"shutdown-1","command":"shutdown"}
```

## Discovery response

```json
{"protocol_version":1,"type":"discovered","request_id":"discover-1","tests":[{"id":"test/math_test.gleam::addition_test","name":"addition_test","path":"test/math_test.gleam","module":"math_test","line":4,"column":1,"end_line":6,"end_column":2,"tags":["unit"],"timeout_ms":null,"serial":false}]}
```

Tests are in file-path and source-definition order. The stable `id`, not the
display name, is the identity editors should persist.

## Operation lifecycle

An accepted run/watch request first emits:

```json
{"protocol_version":1,"type":"started","request_id":"run-1","operation_id":"run-1","operation":"run"}
```

Each runner event is wrapped without changing its payload:

```json
{"protocol_version":1,"type":"event","request_id":"run-1","event":{"type":"run_started","run_id":42,"case_count":1}}
{"protocol_version":1,"type":"event","request_id":"run-1","event":{"type":"case_started","suite":"math_test","case":"test/math_test.gleam::addition_test"}}
{"protocol_version":1,"type":"event","request_id":"run-1","event":{"type":"case_finished","suite":"math_test","case":"test/math_test.gleam::addition_test","outcome":{"kind":"passed"},"duration_ms":1}}
{"protocol_version":1,"type":"event","request_id":"run-1","event":{"type":"run_finished","run_id":42,"summary":{"passed":1,"failed":0,"skipped":0,"duration_ms":4}}}
```

Other event payloads are `suite_started`, `suite_finished`, and `case_output`.
The `suite_finished.outcome` aggregates that module's selected cases, so a
failed or flaky case can never produce a passing suite record.
`case_output` carries captured `stdout`, `stderr`, and the case outcome.

Outcomes are:

```json
{"kind":"passed"}
{"kind":"skipped","reason":"not supported on this platform"}
{"kind":"flaky","attempts":2,"failures":[]}
{"kind":"failed","failures":[]}
```

Failures have kind `equality_mismatch`, `assertion_failed`, or
`unexpected_error`. Locations are nullable and otherwise use this shape:

```json
{"file":"test/math_test.gleam","line":5,"column":3}
```

A finite run ends with its process exit status:

```json
{"protocol_version":1,"type":"completed","request_id":"run-1","exit_code":0}
```

Watch operations remain active until cancellation, shutdown, daemon exit, or
an infrastructure error. A run or watch may stream more than 16 MiB over its
lifetime when the client keeps up. Output waiting at either the child bridge or
the daemon delivery buffer is independently limited to 16 MiB; exceeding a
live buffer is an infrastructure error. A successful cancellation responds to
the cancel request:

```json
{"protocol_version":1,"type":"cancelled","request_id":"cancel-1","operation_id":"watch-1"}
```

Shutdown acknowledgement:

```json
{"protocol_version":1,"type":"shutdown","request_id":"shutdown-1"}
```

Errors are non-terminal unless they belong to an active operation:

```json
{"protocol_version":1,"type":"error","request_id":"run-1","message":"description"}
```

## Client invariants

- Parse stdout by complete lines and retain an incomplete trailing chunk.
- Bound retained protocol lines above the maximum valid escaped event size and
  restart fail-closed after malformed or oversized daemon stdout.
- Ignore records whose protocol version is unsupported.
- Clear diagnostics at `run_started`, then rebuild them from the matching
  generation only.
- End the editor run immediately after requesting cancellation and ignore any
  late child output for that operation; the daemon retains process ownership
  until its child reaches a terminal state.
- On daemon exit, end active editor runs, clear stale diagnostics, restart the
  package daemon, and rediscover the test tree.
- Rediscover after a completed watch generation so added and removed test IDs
  converge in long-lived clients.
