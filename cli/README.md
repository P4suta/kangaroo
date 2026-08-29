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
gleam run -m kangaroo_cli -- --help           # usage
gleam run -m kangaroo_cli -- --version        # version
```

The runner compiles the project and executes the affected test modules in
its own VM on both targets — hot-loading beams with `code:load_file` on
Erlang, loading the compiled `.mjs` files on JavaScript. When in-VM
execution is not possible it falls back to a `gleam test` subprocess.

See the [kangaroo README](../README.md) for the full documentation.
