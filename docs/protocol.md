# The kangaroo editor protocol

`kangaroo_cli watch --json` and the `KANGAROO_JSON` environment variable
make the test runner emit a newline-delimited JSON stream. Each line is one
event object. Consumers (editors, CI tooling, agents) parse the stream and
receive every run of the test suite in real time.

The test runner itself uses the same protocol: setting `KANGAROO_JSON=1`
when running `gleam test` produces the identical event stream.

`kangaroo_cli run --json` runs once and emits the same stream, which makes
it suitable for CI.

## Events

### Changed (watch mode only)

Emitted by `kangaroo_cli watch --json` before a run that was triggered by
file changes.

```json
{"type": "changed", "files": ["src/myapp.gleam"], "affected": 2}
```

- `files` lists the files that changed since the last poll.
- `affected` is the number of test modules affected by the changes. It is
  `null` when the affected computation failed.

### CompileStarted / CompileFinished

Emitted around the compile-only step that precedes every run, so editors
can show progress while the project compiles. They appear on the same
stream as the runner events, before `RunStarted`.

```json
{"type": "compile_started"}
{"type": "compile_finished"}
```

A failed compile emits `compile_started` but no `compile_finished` and no
run events.

### RunStarted

Emitted once per run.

```json
{"type": "run_started", "run_id": 1733279400000, "case_count": 2}
```

- `run_id` correlates the events of one run (a monotonic millisecond clock
  value).
- `case_count` is the total number of selected cases, skipped cases
  included.

### SuiteStarted

Emitted when a suite begins running, before its first `CaseStarted`.
Suites without any runnable cases (e.g. all cases skipped or filtered out)
never emit this. Suite-level hooks (`before_all` / `after_all`) run inside
this window.

```json
{"type": "suite_started", "suite": "math"}
```

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
| `equality_mismatch` | `expected`, `actual`, `diff`, `location` | values did not match; `diff` is a line diff when useful |
| `assertion_failed` | `message`, `location` | a boolean condition was false |
| `unexpected_error` | `name`, `message`, `location` | the case panicked or timed out |

`location` is either `null` or an object of the form
`{"file": "test/foo_test.gleam", "line": 42, "column": null}`, pointing at
the failure site in the source. `column` is a number when the platform
reports it (JavaScript stacks do; Erlang stack traces carry only the
line). Editors can use it to jump to the failing assertion.

### SuiteFinished

Emitted when a suite finishes, after its last `CaseFinished`. The outcome
reflects the suite's `before_all` / `after_all` hooks: when a hook fails,
the suite's cases are reported as `skipped` (before-all failure) or run
normally (after-all failure), and the hook failures appear here.

```json
{"type": "suite_finished", "suite": "math", "outcome": {"kind": "passed"}}
```

### RunFinished

Emitted once per run, after the last `SuiteFinished` / `CaseFinished`.

```json
{"type": "run_finished", "run_id": 1733279400000, "summary": {"passed": 1, "failed": 1, "skipped": 0, "duration_ms": 42}}
```

Suite-level hook failures count towards `summary.failed`.

## Invariants

- Events for one run share a single `run_id`.
- `RunStarted` and `RunFinished` bracket every run.
- `SuiteStarted(s)` precedes every `CaseStarted(s, ...)` of that suite and
  `SuiteFinished(s)` follows them.
- `CaseStarted(s, c)` always precedes `CaseFinished(s, c, ...)` with the
  same suite and case names.
- `summary.passed + summary.failed + summary.skipped == case_count` from
  `RunStarted`.
