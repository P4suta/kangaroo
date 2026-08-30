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
- Erlang/OTP 27–29, Node.js 22.12+/24/26, Bun 1.4.0 or newer, or Deno 2.9 or newer
- Linux, macOS, or Windows

Add Kangaroo as a development dependency:

```sh
gleam add --dev kangaroo
gleam run -m kangaroo -- init
```

`init` creates the package test entry point when it is absent. It replaces only
an exact generated gleeunit or unitest entry point; custom files are never
overwritten: the suggested contents are printed and `init` exits 2 so setup
automation cannot mistake an unchanged custom entry point for success.

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

Retries retain every failed attempt and its captured output. A later dynamic
skip cannot erase an earlier failure; only an otherwise passing retry is
reported as `flaky`.

## Selection and reporting

Selectors can be mixed; their result is a union in discovery order:

```sh
gleam test -- test/math_test.gleam
gleam test -- test/math_test.gleam:24
gleam test -- 'test/math_test.gleam::addition_test'
gleam test -- tag:unit
gleam run -m kangaroo -- watch test/math_test.gleam --tag fast
```

Repeated `--tag` values are ORed and filter the union of explicit selectors;
use `tag:name` when a tag itself should be part of that selector union.
`--exclude-tag` always wins. Other execution options are `--workers N`,
`--timeout MS`, `--retry N`, `--shuffle`,
`--no-shuffle`, and `--fail-fast`. CLI values override `gleam.toml`.

Pretty output is the default. One-shot `run` supports `pretty`, `dot`,
`ndjson`, and `junit`; `watch` and `coverage` support `pretty`, `dot`, and
`ndjson`; `list` and `doctor` support `pretty` and `ndjson`. Captured stdout
and stderr follow the configured `show_output` policy. Each test's captured
output and each finite captured child command's combined stdout and stderr are
limited to 16 MiB. Daemon operations may stream more than 16 MiB over their
lifetime, but both output awaiting consumption and output awaiting delivery to
the client retain independent 16 MiB limits. Exceeding a live memory boundary
is an infrastructure error instead of allowing an unbounded runner process.

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

Unknown keys and empty path or tag entries are errors, so misspelled
configuration is never silently ignored. Test-root spellings such as `test`,
`test/`, and `./test` are equivalent; overlapping roots never duplicate a test.
Every configured path or glob is project-relative. Absolute paths,
Windows drive-qualified paths such as `C:outside`, and `..`
components are rejected before discovery, watching, or build-cache cleanup.
Test roots must be inside Gleam's compiled `src`, `dev`, or `test` source
directories; narrower roots such as `test/integration` are supported.

Coverage reporters are `terminal`, `lcov`, and `cobertura`. LCOV is written to
`coverage/lcov.info`; Cobertura XML is written to
`coverage/cobertura.xml`. Unexecuted selected sources are included at 0%.
With `--reporter ndjson`, stdout contains protocol events only; compiler logs
and a requested terminal coverage table are written to stderr.

## Commands

```sh
gleam run -m kangaroo -- run [selectors] [options]
gleam run -m kangaroo -- watch [selectors] [options]
gleam run -m kangaroo -- coverage [selectors] [options]
gleam run -m kangaroo -- list [selectors] [options]
gleam run -m kangaroo -- doctor [--reporter pretty|ndjson]
gleam run -m kangaroo -- init
gleam run -m kangaroo -- daemon
```

Use `gleam run -m kangaroo -- COMMAND --help` for the exact options accepted by
each command. `--coverage-reporter` is accepted only by `coverage`.

`doctor` validates the compiler/runtime, discovery, platform, and exact
coverage instrumentation path. `daemon` is the protocol-v1 integration entry
point; stdout is NDJSON only, operational logs go to stderr, request lines are
limited to 1 MiB, and at most 32 run/watch operations may be active.

## Editors and integrations

- [VS Code](https://github.com/P4suta/kangaroo/blob/main/editors/vscode/README.md): Testing API tree, individual/file/all
  runs, continuous runs, diagnostics, status, coverage command, and multi-root
  daemon lifecycles.
- [Neovim](https://github.com/P4suta/kangaroo/blob/main/editors/neovim/README.md): automatic per-package daemon,
  diagnostics, quickfix/test picker, individual/file runs, and LCOV signs.
- [Protocol v1](https://github.com/P4suta/kangaroo/blob/main/docs/protocol.md): bidirectional NDJSON for other tools.
- [Birdie and qcheck](https://github.com/P4suta/kangaroo/blob/main/docs/integrations.md): preserving snapshot and
  property-test diagnostics.

See the [runtime and Deno permission guide](https://github.com/P4suta/kangaroo/blob/main/docs/runtimes.md),
[gleeunit migration guide](https://github.com/P4suta/kangaroo/blob/main/docs/migration-from-gleeunit.md), and
[troubleshooting guide](https://github.com/P4suta/kangaroo/blob/main/docs/troubleshooting.md).

## Development

The project is developed test-first. Keep the failing regression focused,
implement the smallest coherent behaviour, then run every supported backend
before refactoring.

```sh
gleam format --check src dev test fixtures
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

The internal design is described in [ARCHITECTURE.md](https://github.com/P4suta/kangaroo/blob/main/ARCHITECTURE.md).

## Licence

Apache-2.0. See [LICENSE](https://github.com/P4suta/kangaroo/blob/main/LICENSE).
