# kangaroo_cli

The continuous test runner for
[kangaroo](https://hex.pm/packages/kangaroo): watches `src` and `test`,
re-runs only the affected tests, and presents the results in a rich TUI or
a machine-readable event stream.

## Usage

```sh
gleam run -m kangaroo_cli              # watch mode with TUI
gleam run -m kangaroo_cli -- watch --no-tui   # streaming output
gleam run -m kangaroo_cli -- watch --json     # editor protocol (NDJSON)
gleam run -m kangaroo_cli -- run              # run the tests once
gleam run -m kangaroo_cli -- run --coverage   # run once with line coverage
```

On Erlang, the runner executes the affected test modules in its own VM
with hot module reloading and line coverage via `cover`. On JavaScript it
runs `gleam test` subprocesses.

See the [kangaroo README](../README.md) for the full documentation.
