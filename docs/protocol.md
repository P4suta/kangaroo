# The kangaroo editor protocol

`kangaroo_cli watch --json` and the `KANGAROO_JSON` environment variable
make the test runner emit a newline-delimited JSON stream. Each line is one
event object. Consumers (editors, CI tooling, agents) parse the stream and
receive every run of the test suite in real time.

The test runner itself uses the same protocol: setting `KANGAROO_JSON=1`
when running `gleam test` produces the identical event stream.

## Events

### RunStarted

Emitted once per run.

```json
{"type": "run_started", "run_id": 1733279400000, "case_count": 2}
```

- `run_id` correlates the events of one run (a monotonic millisecond clock
  value).
- `case_count` is the total number of selected cases, skipped cases
  included.

### CaseStarted

Emitted when a case begins executing. Skipped cases never emit this.

```json
{"type": "case_started", "suite": "math", "case": "adds numbers"}
```

### CaseFinished

Emitted when a case finishes.

```json
{"type": "case_finished", "suite": "math", "case": "adds numbers", "outcome": {"kind": "passed"}, "duration_ms": 1}
```

`outcome` has one of three shapes:

```json
{"kind": "passed"}
{"kind": "skipped"}
{"kind": "failed", "failures": [ ... ]}
```

Failure kinds:

| kind | fields | meaning |
| --- | --- | --- |
| `equality_mismatch` | `expected`, `actual`, `diff` | values did not match; `diff` is a line diff when useful |
| `assertion_failed` | `message` | a boolean condition was false |
| `unexpected_error` | `name`, `message` | the case panicked or timed out |

### RunFinished

Emitted once per run, after the last `CaseFinished`.

```json
{"type": "run_finished", "run_id": 1733279400000, "summary": {"passed": 1, "failed": 1, "skipped": 0, "duration_ms": 42}}
```

## Invariants

- Events for one run share a single `run_id`.
- `RunStarted` and `RunFinished` bracket every run.
- `CaseStarted(s, c)` always precedes `CaseFinished(s, c, ...)` with the
  same suite and case names.
- `summary.passed + summary.failed + summary.skipped == case_count` from
  `RunStarted`.
