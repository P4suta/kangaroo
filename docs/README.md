# Kangaroo guide

Kangaroo provides a Gleam test framework and a continuous runner.
The framework emits events for assertions, cases, suites, and completed runs.
The CLI watches source files and selects affected test modules through their import dependencies.

## Use the source checkout

Install Gleam and Erlang/OTP using the [official installation instructions](https://gleam.run/install/).
The repository's CI uses Gleam 1.18.1 and Erlang/OTP 29.

The repository contains the `kangaroo` package at its root and `kangaroo_cli` in `cli`.
The CLI depends on the framework through the local path `..`.
Keep both directories together when working from source.

From `cli`, inspect the available commands:

```sh
gleam run -m kangaroo_cli -- --help
```

To use the checkout from another Gleam project, add local development dependencies.
For a project beside a directory named `kangaroo`, the entries in `gleam.toml` are:

```toml
[dev_dependencies]
kangaroo = { path = "../kangaroo" }
kangaroo_cli = { path = "../kangaroo/cli" }
```

The command examples below run from the test project's root.

## Write tests

Expose test suites through a public `suites` function and call `kangaroo.main` from the project's main test module.
The example imports every function it uses:

```gleam
import kangaroo
import kangaroo/expect.{expect, to_equal}
import kangaroo/suite.{type Suite, it, suite}

pub fn main() {
  kangaroo.main(suites())
}

pub fn suites() -> List(Suite) {
  [
    suite("arithmetic", [
      it("adds two numbers", fn() {
        expect(1 + 1) |> to_equal(2)
      }),
    ]),
  ]
}
```

Run the main test module with `gleam test`.
To combine test modules, import their `suites` functions and join their results with `gleam/list.flatten`.
Each test module that the continuous runner discovers must expose its own `suites` function.

Matchers record failures without stopping the case at the first failed assertion.
`to_equal` compares values and includes a line-oriented diff when their printed forms contain line breaks.
The [matcher source](../src/kangaroo/expect.gleam) also provides assertions for booleans, options, results, collections, strings, numbers, and raised errors.

`it_focused` selects a case for a focused run, and `it_skipped` keeps a case without executing its body.
`suite_with_hooks` accepts `hooks` for setup and cleanup around each case, or `all_hooks` for hooks around both suites and cases.
Erlang isolates case execution in a process and enforces the configured timeout.
JavaScript can't interrupt a synchronous case body, so the timeout doesn't apply on that target.

## Run continuously

Start watch mode from the test project:

```sh
gleam run -m kangaroo_cli -- watch
```

With no command, the CLI also starts watch mode.
It chooses the terminal UI when standard output is a terminal and text output otherwise.
The `watch` flags `--tui`, `--no-tui`, and `--json` select a presentation explicitly.
In the terminal UI, `r` requests a full run, `f` toggles the failures-only view, and `q` or Ctrl+C exits.

Use `run` for one execution.
Its `--name` option matches suite or case names by substring, `--json` selects event output, and `--fail-fast` stops after a failing case.
`run --coverage` requests line coverage through Erlang's `cover` tool or Node's V8 coverage, depending on the target.
Watch mode also accepts `--coverage`, but watch coverage requires Erlang.
`--version` prints the CLI version.

The watch loop monitors source files, test files, and project configuration files.
It computes affected modules from the import graph.
It compiles before loading test modules into the running VM.
When loading modules into the VM is unavailable, the runner falls back to a `gleam test` subprocess.
The [architecture](../ARCHITECTURE.md) describes module loading, file-change detection, isolation, and coverage adapters.

## Consume editor events

`watch --json` and `run --json` emit newline-delimited JSON.
Setting `KANGAROO_JSON=1` also selects JSON events for the framework's test entry point.
Each line is a separate JSON object.
For example, a passing case produces an event with the following shape:

```json
{"type":"case_finished","suite":"arithmetic","case":"adds two numbers","outcome":{"kind":"passed"},"duration_ms":1}
```

Watch mode reports changed files and compilation progress before test events.
Failure events include assertion details and source locations when available.
The [editor protocol](protocol.md) defines event fields and run boundaries.
The repository also contains editor integrations under `editors/vscode` and `editors/neovim`.

## Development

The existing CI uses Gleam 1.18.1 and Erlang/OTP 29.
It tests both packages on Erlang and JavaScript, using Bun for the JavaScript tests.
Run the framework commands from the repository root:

```sh
gleam deps download
gleam test -t erlang
gleam test -t javascript --runtime bun
gleam format --check src test
```

Run the same commands from `cli` to check the CLI package.
The CLI tests include integration cases that invoke the framework's executor.
The CI also checks the VS Code extension's JavaScript syntax and the editor integration files.
The [test workflow](../.github/workflows/test.yml) contains the complete command sequence.
