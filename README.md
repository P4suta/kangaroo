# Kangaroo

Kangaroo is a continuous test runner for Gleam. Tests are ordinary public
functions, failures use Gleam's built-in `assert` and `let assert`, and the
same package runs on Erlang, Node.js, Bun, and Deno.

```gleam
import kangaroo

pub fn main() {
  kangaroo.main()
}

pub fn addition_test() {
  assert 1 + 1 == 2
}
```

Run once with the standard Gleam command:

```sh
gleam test
```

Keep the latest saved source under test:

```sh
gleam run -m kangaroo -- watch
```

Kangaroo 1.x is one Hex package. It does not require a separate executable or
CLI package.

## Requirements and installation

- Gleam 1.18 or newer
- Erlang/OTP 27–29, Node.js 22.12+/24/26, Bun 1.4 or newer, or Deno 2.9 or newer
- Linux, macOS, or Windows

Add Kangaroo as a development dependency:

```sh
gleam add --dev kangaroo
gleam run -m kangaroo -- init
```

`init` creates the package test entry point when it is absent. It replaces only
an exact generated gleeunit or unitest entry point; custom files are never
overwritten and receive a suggested diff instead.

## Discovery and ordering

Kangaroo discovers public, zero-argument functions whose names end in `_test`
below the configured test roots. A stable test ID is
`test/path.gleam::function_test`.

Files are ordered by normalised project-relative path and functions retain
source definition order. Different modules may run concurrently; tests in one
module always run in definition order. JavaScript Promise results are awaited.
Panics, rejected Promises, and timeouts use one failure model.

Tests can use source-indexed metadata and lifecycle helpers:

```gleam
import kangaroo

pub fn database_test() {
  kangaroo.tags(["integration", "database"])
  kangaroo.timeout(5_000)
  kangaroo.serial()

  kangaroo.fixture(
    setup: open_database,
    teardown: close_database,
    body: fn(database) {
      let assert Ok(account) = find_account(database, 42)
      assert account.active
    },
  )
}
```

`tag`, `tags`, and `timeout` require literals; `serial` takes no arguments.
This keeps scheduling and filtering available before a test is loaded.
`skip("reason")` is indexed when literal and `skip_if(condition, "reason")`
supports runtime decisions. `fixture` always attempts teardown and retains both
failures if the body and teardown fail.

## Selection and reporting

Selectors can be mixed; their result is a union in discovery order:

```sh
gleam test -- test/math_test.gleam
gleam test -- test/math_test.gleam:24
gleam test -- 'test/math_test.gleam::addition_test'
gleam test -- tag:unit
gleam run -m kangaroo -- watch test/math_test.gleam --tag fast
```

Repeated `--tag` values are ORed. `--exclude-tag` always wins. Other execution
options are `--workers N`, `--timeout MS`, `--retry N`, `--shuffle`,
`--no-shuffle`, and `--fail-fast`. CLI values override `gleam.toml`.

Pretty output is the default. `--reporter dot`, `ndjson`, or `junit` selects a
different consumer of the same event stream. Captured stdout and stderr follow
the configured `show_output` policy.

Exit status is 0 for a clean run, including an all-skipped selection; 1 for a
test failure, a retry that passes only after failing (`flaky`), or an unmet
coverage threshold; and 2 for invalid configuration, no matched tests, compile
errors, and runner infrastructure failures.

## Configuration

All configuration lives in Gleam's external-tool namespace:

```toml
[tools.kangaroo]
test_paths = ["test"]
exclude = []
workers = "auto"
timeout_ms = 30000
ignored_tags = []
serial_tags = []
retry = 0
shuffle = false
show_output = "failures"

[tools.kangaroo.watch]
extra_paths = []
debounce_ms = 50

[tools.kangaroo.coverage]
include = ["src/**/*.gleam"]
exclude = []
minimum = 0
minimum_per_file = 0
reporters = ["terminal"]
```

Coverage reporters are `terminal`, `lcov`, and `cobertura`. LCOV is written to
`coverage/lcov.info`; Cobertura XML is written to
`coverage/cobertura.xml`. Unexecuted selected sources are included at 0%.

## Commands

```sh
gleam run -m kangaroo -- watch [selectors] [options]
gleam run -m kangaroo -- coverage [selectors] [options]
gleam run -m kangaroo -- list [selectors] [options]
gleam run -m kangaroo -- doctor [--reporter pretty|ndjson]
gleam run -m kangaroo -- init
gleam run -m kangaroo -- daemon
```

`doctor` validates the compiler/runtime, discovery, platform, and exact
coverage instrumentation path. `daemon` is the protocol-v1 integration entry
point; stdout is NDJSON only and operational logs go to stderr.

## Editors and integrations

- [VS Code](editors/vscode/README.md): Testing API tree, individual/file/all
  runs, continuous runs, diagnostics, status, coverage command, and multi-root
  daemon lifecycles.
- [Neovim](editors/neovim/README.md): automatic per-package daemon,
  diagnostics, quickfix/test picker, individual/file runs, and LCOV signs.
- [Protocol v1](docs/protocol.md): bidirectional NDJSON for other tools.
- [Birdie and qcheck](docs/integrations.md): preserving snapshot and
  property-test diagnostics.

See the [runtime and Deno permission guide](docs/runtimes.md),
[gleeunit migration guide](docs/migration-from-gleeunit.md), and
[troubleshooting guide](docs/troubleshooting.md).

## Development

The project is developed test-first. Keep the failing regression focused,
implement the smallest coherent behaviour, then run every supported backend
before refactoring.

```sh
gleam format --check src test
gleam build --target erlang --warnings-as-errors
gleam build --target javascript --warnings-as-errors
gleam test --target erlang
gleam test --target javascript --runtime nodejs
gleam test --target javascript --runtime bun
gleam test --target javascript --runtime deno
(cd editors/vscode && npm test)
(cd editors/vscode && npm run test:integration)
nvim --headless -u NONE -l editors/neovim/test/headless.lua
```

The internal design is described in [ARCHITECTURE.md](ARCHITECTURE.md).

## Licence

Apache-2.0. See [LICENSE](LICENSE).
