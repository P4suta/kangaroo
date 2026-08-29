# Architecture

Kangaroo is a hexagonal design in two packages. All decision logic is pure
Gleam; every operating-system capability lives behind a tiny port, with
Erlang and JavaScript implementations.

```
┌────────────────────────────────────────────────────────────┐
│  DOMAIN CORE — kangaroo (pure, platform-independent)        │
│  suite / it / expect / matchers / diff / failure / report   │
│  location (stack parsing) / event (single source of truth)  │
│  runner:  suites + Config -> events + Report                │
├────────────────────────────────────────────────────────────┤
│  APPLICATION — kangaroo_cli (pure, testable)                │
│  graph / affected / watcher / stream / collect / tui        │
│  coverage (report logic) / app (orchestration)             │
├────────────────────────────────────────────────────────────┤
│  PORTS — thin modules with @external pairs                  │
│  context    (per-case failure storage)                      │
│  isolate    (run a body in isolation, catch panics, timeout)│
│  location   (capture the caller's source position)          │
│  sys        (clock, env, halt)                              │
│  print      (failure message formatting, truncation)        │
│  fs         (files, subprocess, args, event buffer)         │
│  vm         (code loading, suites(), cover; Erlang + JS)    │
├────────────────────────────────────────────────────────────┤
│  ADAPTERS                                                    │
│  src/kangaroo_*_ffi.erl / .mjs                              │
│  src/kangaroo_cli_ffi.erl / .mjs                            │
└────────────────────────────────────────────────────────────┘
```

## The event model

`kangaroo/event.gleam` defines the entire observable behaviour of a run:

- `RunStarted(run_id, case_count)`
- `SuiteStarted(suite)` / `SuiteFinished(suite, outcome)`
- `CaseStarted(suite, case_name)`
- `CaseFinished(suite, case_name, outcome, duration_ms)`
- `RunFinished(run_id, summary)`

Every presentation layer is a fold over this stream: the terminal
formatter (`format.print_sink`), the TUI (`tui.apply`), and the editor
protocol (`encode.encode`). Adding a new consumer never touches the runner.
Suite-level hook failures surface as `SuiteFinished` outcomes and count
towards the summary.

## Isolation

Each case body runs through `isolate`, the single execution primitive:

- **Erlang**: a freshly spawned process with the process dictionary as
  per-case storage; panics are caught and reported with the stack trace.
  The configured timeout bounds the execution.
- **JavaScript**: a module-global failure array, saved and restored around
  each body so nested runs cannot leak failures into each other. A
  synchronous body cannot be interrupted, so timeouts do not apply.

The context port (`record` / `collect`) is drained after every case; on
Erlang each spawned process has its own dictionary, and on JavaScript the
isolate saves and restores the shared array.

## Failure locations

Matcher failures and panics carry the source position they originate from:

- `location.capture()` derives the caller's `file:line` from the stack.
  The pure `kangaroo/location` module parses both Erlang stack text
  (`file:line` lines, with `.gleam` paths thanks to Gleam's `-file`
  attributes) and JavaScript `Error().stack`, skipping framework frames.
  Framework frames are recognised in two forms: the `.gleam` source paths
  of a self-run, and the compiled `_gleam_artefacts/*.erl` paths the
  framework's own modules carry when the CLI executes the project's tests
  in its own VM (Gleam emits the `-file` source attributes only for the
  main package).
- Matchers capture the location eagerly in `expect()`, because matchers are
  usually the last call in a test body and Erlang's tail-call optimisation
  would erase the caller's frame by the time the failure is recorded.
- Panics are located from the crash stack inside the isolate port.

## Continuous running

`kangaroo_cli` orchestrates a compile-run loop:

1. **Watch** — `src`, `test` and the project config files are polled every
   250 ms. File metadata (mtime + size) is compared, and every few polls
   the full contents are compared too, so edits that keep both unchanged
   are still seen. When metadata changes are detected, only the changed
   files are re-read into the content cache. Detected changes are
   debounced (150 ms) and the snapshot is re-read so rapid saves coalesce
   into one run.
2. **Graph** — every `.gleam` file's imports are parsed into a module
   graph.
3. **Affected** — the transitive import closure of each test module is
   checked against the changed modules; cycles are handled with a visited
   set.
4. **Compile** — `gleam test -t <target>` runs with `KANGAROO_COMPILE_ONLY=1`,
   a fast compile-only mode that never executes tests and only builds the
   current target.
5. **Run** — the affected `*_test` modules are loaded into the daemon's own
   VM and their `suites()` are executed by the framework's runner. Erlang
   hot-loads beams with `code:purge` + `code:load_file`. JavaScript loads
   the compiled `.mjs` files with synchronous `require(esm)`, purging only
   the project's own package from the require cache so the kangaroo runtime
   keeps its module identity (required for `instanceof`-based type
   matching); the loader rejects incompatible modules so the CLI falls back
   to a `gleam test` subprocess instead of silently passing. Test modules
   whose source files no longer exist are skipped: the compiler leaves
   stale beams behind when a test file is deleted, so the module list is
   filtered against the sources before running.
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
the TUI is only chosen when stdout is a terminal. On JavaScript keys are
read synchronously from the (non-blocking) terminal file descriptor, so the
watch loop stays synchronous; a SIGINT handler restores the terminal.

## Testing

Kangaroo tests itself. The framework's tests are written with the
framework; the CLI's tests cover the pure logic (graph, affected,
watcher, stream, collect, coverage, TUI, flags) plus integration tests that
run the real executor against the `kangaroo` package itself — spawning
`gleam test`, loading its modules in-VM (hot-reloading beams on Erlang and
`.mjs` files on JavaScript), and measuring its coverage.
