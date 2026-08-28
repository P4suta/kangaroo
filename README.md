# kangaroo

[![Package Version](https://img.shields.io/hexpm/v/kangaroo)](https://hex.pm/packages/kangaroo)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/kangaroo/)

A next-generation continuous test runner for Gleam, inspired by
[Wallaby.js](https://wallabyjs.com/): a self-hosting test framework whose
events power a watch-mode daemon that re-runs **only the tests affected by
your changes** — in a hot-reloading Erlang VM — and presents the results in
a rich terminal UI or a machine-readable stream for editors.

## Features

- **Test framework**: `suite` / `it` DSL with matchers, `before_each` /
  `after_each` hooks, `focus` / `skip`, and line-oriented diffs
- **Self-hosting**: kangaroo tests itself — 90+ tests across Erlang and
  JavaScript
- **Continuous runner** (`kangaroo_cli`): watches `src` and `test`, computes
  the affected test modules from the import graph, and re-runs only those
- **Hot reloading** (Erlang): the daemon executes tests in its own VM with
  `code:load_file`, so re-runs never restart the runtime
- **Coverage** (Erlang): line coverage via the `cover` tool, mapped back to
  `.gleam` sources
- **Rich TUI**: full-screen ANSI rendering with per-case status marks
- **Editor protocol**: newline-delimited JSON events for editors and CI

## Installation

```sh
gleam add kangaroo --dev
gleam add kangaroo_cli --dev
```

## Writing tests

Test files export a `suites` function; the main test module aggregates
them:

```gleam
// test/myapp_test.gleam
import gleam/list
import kangaroo
import kangaroo/expect.{expect, to_equal, to_be_true}
import kangaroo/suite.{it, suite}
import myapp/calculator
import math_test.{suites as math_suites}

pub fn main() {
  kangaroo.main(suites())
}

pub fn suites() {
  list.flatten([
    [
      suite("calculator", [
        it("adds two numbers", fn() {
          expect(calculator.add(1, 2)) |> to_equal(3)
        }),
        it("throws on division by zero", fn() {
          expect(fn() { calculator.divide(1, 0) }) |> to_raise()
        }),
        it_focused("only this runs for now", fn() {
          expect(calculator.add(2, 2)) |> to_equal(4)
        }),
        it_skipped("not ready yet", fn() {
          expect(calculator.add(1, 1)) |> to_equal(3)
        }),
      ]),
      suite_with_hooks(
        "database",
        [it("queries", fn() { query() |> to_be_true() })],
        hooks(Some(open_connection), Some(close_connection)),
      ),
    ],
    math_suites(),
  ])
}
```

Suites run under `gleam test` too, so CI keeps working unchanged.

### Matchers

`expect(value) |> matcher()` records failures without stopping the case,
so every assertion in a body is reported:

- `to_equal(expected)` — with a line-oriented diff for multi-line values
- `to_be_true()` / `to_be_false()`
- `to_be_none()` / `to_be_some()`
- `to_be_empty()`
- `to_contain(element)` / `to_contain_text(substring)`
- `to_raise()` — asserts the function raises an error

## Continuous testing

```sh
gleam run -m kangaroo_cli            # watch mode with TUI
gleam run -m kangaroo_cli -- watch --no-tui   # streaming output
gleam run -m kangaroo_cli -- watch --json     # editor protocol
gleam run -m kangaroo_cli -- run              # run once
gleam run -m kangaroo_cli -- run --coverage   # run once with coverage
```

On Erlang, the runner compiles the project with a fast compile-only
subprocess and then executes only the affected test modules in its own VM
with hot module reloading. On JavaScript it falls back to `gleam test`
subprocesses.

## Editor protocol

`kangaroo_cli watch --json` emits one JSON object per line:

```json
{"type":"run_started","run_id":...}
{"type":"case_started","suite":"math","case":"adds"}
{"type":"case_finished","suite":"math","case":"adds","outcome":{"kind":"passed"},"duration_ms":1}
{"type":"run_finished","run_id":...,"summary":{"passed":1,"failed":0,"skipped":0,"duration_ms":5}}
```

Failed cases carry their failures:

```json
{"type":"case_finished","suite":"math","case":"adds","outcome":{"kind":"failed","failures":[{"kind":"equality_mismatch","expected":"2","actual":"1","diff":null}]},"duration_ms":2}
```

See [docs/protocol.md](docs/protocol.md) for the full schema.

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for the design: a pure event-driven
core with ports for isolation, filesystem access, the Erlang VM, and
coverage, and the CLI as a thin application layer.

## Development

```sh
gleam test                      # kangaroo framework (both targets)
cd cli && gleam test            # CLI, including integration tests
```
