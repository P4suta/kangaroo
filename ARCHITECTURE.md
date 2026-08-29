# Architecture

Kangaroo is a hexagonal design in two packages. All decision logic is pure
Gleam; every operating-system capability lives behind a tiny port, with
Erlang and JavaScript implementations.

```
┌────────────────────────────────────────────────────────────┐
│  DOMAIN CORE — kangaroo (pure, platform-independent)        │
│  suite / it / expect / matchers / diff / failure / report   │
│  event (the single source of truth)                         │
│  runner:  suites -> events + Report                         │
├────────────────────────────────────────────────────────────┤
│  APPLICATION — kangaroo_cli (pure, testable)                │
│  graph / affected / watcher / stream / collect / tui        │
│  coverage (report logic) / app (orchestration)             │
├────────────────────────────────────────────────────────────┤
│  PORTS — thin modules with @external pairs                  │
│  context    (per-case failure storage)                      │
│  isolate    (run a body in isolation, catch panics)         │
│  sys        (clock, env, halt)                              │
│  print      (failure message formatting)                    │
│  fs         (files, subprocess, args, event buffer)         │
│  vm         (code loading, suites(), cover)                 │
├────────────────────────────────────────────────────────────┤
│  ADAPTERS                                                    │
│  src/kangaroo_*_ffi.erl / .mjs                              │
│  src/kangaroo_cli_ffi.erl / .mjs                            │
└────────────────────────────────────────────────────────────┘
```

## The event model

`kangaroo/event.gleam` defines the entire observable behaviour of a run:

- `RunStarted(run_id, case_count)`
- `CaseStarted(suite, case_name)`
- `CaseFinished(suite, case_name, outcome, duration_ms)`
- `RunFinished(run_id, summary)`

Every presentation layer is a fold over this stream: the terminal
formatter (`format.print_sink`), the TUI (`tui.apply`), and the editor
protocol (`encode.encode`). Adding a new consumer never touches the runner.

## Isolation

Each case body runs through `isolate`, the single execution primitive:

- **Erlang**: a freshly spawned process with the process dictionary as
  per-case storage; panics are caught and reported with the stack trace.
- **JavaScript**: a module-global failure array, saved and restored around
  each body so nested runs cannot leak failures into each other.

The context port (`record` / `collect`) is drained after every case; on
Erlang each spawned process has its own dictionary, and on JavaScript the
isolate saves and restores the shared array.

## Continuous running

`kangaroo_cli` orchestrates a compile-run loop:

1. **Watch** — `src` and `test` are polled every 250 ms; a snapshot diff
   produces added/modified/removed files.
2. **Graph** — every `.gleam` file's imports are parsed into a module
   graph.
3. **Affected** — the transitive import closure of each test module is
   checked against the changed modules; cycles are handled with a visited
   set.
4. **Compile** — `gleam test` runs with `KANGAROO_COMPILE_ONLY=1`, a
   fast compile-only mode that never executes tests.
5. **Run** — on Erlang the affected `*_test` modules are loaded into the
   daemon's own VM (`code:purge` + `code:load_file`) and their `suites()`
   are executed by the framework's runner. JavaScript uses a `gleam test`
   subprocess and parses the NDJSON output.
6. **Present** — events are folded into the TUI, printed as text, or
   streamed as JSON.

## Coverage

`run --coverage` has one flow per target:

- **Erlang** instruments every beam of the project's ebin with `cover`,
  runs all tests in-VM, and reads per-line hit counts. Gleam's generated
  abstract code carries `.gleam` source line numbers, so cover's lines map
  directly back to the sources; lines beyond the file are generated code
  and are ignored.
- **JavaScript** runs the tests under Node with `NODE_V8_COVERAGE`. The
  coverage files report character offsets within the generated `.mjs`
  files; `jscoverage` maps offsets back to lines and derives module names
  from the script URLs, reporting per-module coverage of the project's own
  package.

## Terminal input

The TUI reads keys through a background reader process (`io:get_chars`)
while the terminal is in raw mode. Raw mode disables ISIG, so Ctrl+C
arrives as the byte 0x03 and is handled like `q`: restore the terminal,
then exit. `is_tty` inspects the VM's own stdout (`/proc/self/fd/1`) so
the TUI is only chosen when stdout is a terminal. Keyboard input is
Erlang-only; the JavaScript TUI renders but does not read keys.

## Testing

Kangaroo tests itself. The framework's tests are written with the
framework; the CLI's tests cover the pure logic (graph, affected,
watcher, stream, collect, coverage, TUI) plus integration tests that run
the real executor against the `kangaroo` package itself — spawning
`gleam test`, loading its modules in-VM, and measuring its coverage.
