# kangaroo

[![Package Version](https://img.shields.io/hexpm/v/kangaroo)](https://hex.pm/packages/kangaroo)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/kangaroo/)

A next-generation continuous test runner for Gleam, inspired by
[Wallaby.js](https://wallabyjs.com/): a self-hosting test framework whose
events power a watch-mode daemon that re-runs **only the tests affected by
your changes** — in a hot-reloading Erlang VM — and presents the results in
a rich terminal UI or a machine-readable stream for editors.

## Features

- **Test framework**: `suite` / `it` DSL with matchers, `before_all` /
  `before_each` / `after_each` / `after_all` hooks, `focus` / `skip`,
  per-case timeouts, and line-oriented diffs
- **Failure locations**: matcher failures and panics carry the source
  `file:line` they originate from (parsed from the stack, `.gleam` paths on
  Erlang), shown in the terminal and streamed in the editor protocol
- **Self-hosting**: kangaroo tests itself — 100+ tests across Erlang and
  JavaScript
- **Continuous runner** (`kangaroo_cli`): watches `src` and `test`, computes
  the affected test modules from the import graph, and re-runs only those
- **Hot reloading**: the daemon executes tests in its own VM — `code:load_file`
  on Erlang, `require(esm)` on JavaScript — so re-runs never restart the
  runtime
- **Coverage**: line coverage on both targets — the Erlang `cover` tool
  mapped back to `.gleam` sources, and V8 coverage (`NODE_V8_COVERAGE`)
  on JavaScript
- **Rich TUI**: full-screen ANSI rendering with per-case status marks,
  colored numbered diffs, failure locations, run statistics (changed files,
  affected modules, slowest case), and keyboard control (`r` rerun, `f`
  failures-only, `q` / Ctrl+C quit) on both targets
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
- `to_be_ok()` / `to_be_error()` — Result matchers that name the
  unexpected value
- `to_be_empty()`
- `to_contain(element)` / `to_contain_text(substring)`
- `to_contain_key(key)`
- `to_be_close_to(expected, tolerance)`
- `to_be_less_than(n)` / `to_be_greater_than(n)`
- `to_have_length(n)`
- `to_start_with(prefix)` / `to_end_with(suffix)`
- `to_raise()` / `to_raise_containing(substring)`

## Continuous testing

```sh
gleam run -m kangaroo_cli            # watch mode: TUI on a terminal, streaming otherwise
gleam run -m kangaroo_cli -- watch --tui       # force the TUI
gleam run -m kangaroo_cli -- watch --no-tui    # streaming output
gleam run -m kangaroo_cli -- watch --json      # editor protocol
gleam run -m kangaroo_cli -- watch --coverage  # report line coverage after every run (Erlang)
gleam run -m kangaroo_cli -- run               # run once
gleam run -m kangaroo_cli -- run --name <substring>   # run matching tests only
gleam run -m kangaroo_cli -- run --json              # run once, editor protocol (CI)
gleam run -m kangaroo_cli -- run --fail-fast         # stop at the first failure
gleam run -m kangaroo_cli -- run --coverage          # run once with coverage
gleam run -m kangaroo_cli -- --help                  # usage
gleam run -m kangaroo_cli -- --version               # version
```

In the TUI, `r` forces a full re-run, `f` toggles the failures-only view,
and `q` (or Ctrl+C) quits, restoring the terminal. Keyboard input works on
both Erlang and JavaScript. When a run fails to compile, the TUI shows the
compiler's report instead of the stale results, with `r` to retry.

The runner compiles the project with a fast compile-only subprocess for the
current target and then executes only the affected test modules in its own
VM with hot module reloading — `code:load_file` on Erlang, loading the
compiled `.mjs` files on JavaScript (when the CLI runs from the project's
own build, i.e. as a dev dependency). When in-VM execution is not possible
it falls back to a `gleam test` subprocess. Changes are detected from file
metadata plus periodic content comparison, and rapid saves are debounced;
test modules whose source files have been deleted are not re-run.
Coverage uses Erlang's `cover` (mapped back to `.gleam` lines) or, on
JavaScript, Node's V8 coverage of the generated `.mjs` files, reported per
module.

## Editor protocol

`kangaroo_cli watch --json` emits one JSON object per line. The compile
phase is reported too, so editors can show progress while the project
compiles:

```json
{"type":"changed","files":["src/myapp.gleam"],"affected":2}
{"type":"compile_started"}
{"type":"compile_finished"}
{"type":"run_started","run_id":...}
{"type":"case_started","suite":"math","case":"adds"}
{"type":"case_finished","suite":"math","case":"adds","outcome":{"kind":"passed"},"duration_ms":1}
{"type":"run_finished","run_id":...,"summary":{"passed":1,"failed":0,"skipped":0,"duration_ms":5}}
```

Failed cases carry their failures, with a source location for editors:

```json
{"type":"case_finished","suite":"math","case":"adds","outcome":{"kind":"failed","failures":[{"kind":"equality_mismatch","expected":"2","actual":"1","diff":null,"location":{"file":"test/foo_test.gleam","line":42,"column":null}}]},"duration_ms":2}
```

Watch runs also emit `changed` events describing the files that triggered a
run. See [docs/protocol.md](docs/protocol.md) for the full schema.

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for the design: a pure event-driven
core with ports for isolation, filesystem access, the Erlang VM, and
coverage, and the CLI as a thin application layer.

## Development

```sh
gleam test                      # kangaroo framework (both targets)
cd cli && gleam test            # CLI, including integration tests
```
