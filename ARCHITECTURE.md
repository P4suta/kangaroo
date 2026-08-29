# Architecture

Kangaroo 1.x is one Gleam package with one stable public module,
`kangaroo`. Implementation modules match the `kangaroo/*` internal-module
glob, so the compiler-generated package interface cannot accidentally turn a
runner detail into a compatibility promise.

## Data flow

```text
test/**/*.gleam
      │
      ▼
AST source index ──► dependency graph ──► selector ──► module scheduler
      │                                        │             │
      └── stable IDs, ranges, metadata          │             ▼
                                               │      isolated executor
                                               │             │
                                               └─────────────▼
                                                      event stream
                                                 ┌──────┼───────┐
                                                 ▼      ▼       ▼
                                              terminal NDJSON  JUnit
                                                        │
                                                daemon / editors
```

The index uses a Gleam AST, not regular expressions. It records functions,
one-based source ranges, imports, literal tags/timeouts, serial markers, and a
content hash. Invalid syntax or dynamic metadata produces a located error and
no partial runnable index. Watch generations reuse unchanged index entries and
fall back to the complete suite when a changed FFI/config/manifest file cannot
be mapped safely.

## Scheduling and isolation

The scheduler groups tests by module. Groups run in deterministic waves up to
the configured worker limit, while functions inside a module remain serial and
in definition order. An explicit `serial()` marker or configured serial tag
runs its group alone. Optional shuffling reorders groups from a reproducible
seed and never reorders functions inside a group.

Every test crosses one isolation boundary:

- Erlang runs it in a fresh process and terminates descendant processes at the
  end of the test or timeout.
- JavaScript runs each generation through a Worker and awaits a returned
  Promise. Rejection, panic, and timeout are converted to the same outcome.

Both adapters capture stdout and stderr without allowing one test's state to
leak into another. A teardown is attempted after every fixture body outcome;
double failures retain both causes.

## Failures and events

The runtime adapter recovers structured Gleam panic information from ordinary
`assert` and `let assert`: expression, operand values or unmatched value,
source snippet, useful String/List differences, and user stack location.
Platform paths are normalised before they enter the core.

`kangaroo/event.gleam` is the single presentation boundary. Pretty, dot,
NDJSON, JUnit, daemon, and editor consumers observe the same ordered events.
This prevents terminal and editor results from assigning different outcomes to
one execution.

## Continuous generations

Watch snapshots cover configured roots plus Gleam FFI, `gleam.toml`, and the
manifest. Content hashes supplement metadata, so equal-mtime writes, atomic
renames, additions, and removals are observable. Roots are refreshed after a
configuration change.

The initial and later runs are child process trees. When another save arrives,
the active compile/run is cancelled before the new generation starts. Only the
latest generation may publish completion. The previous dependency graph is
retained long enough to calculate dependants of a deleted module.

## Coverage

Coverage operates in a disposable project clone. Selected Gleam AST statement
locations receive collision-free source probes; the original checkout is
never modified. All four runtimes write the same project-relative, one-based
line-hit stream. This makes terminal, LCOV, and Cobertura output independent of
generated Erlang or JavaScript line layouts and includes unexecuted source at
zero hits.

Instrumentation is all-or-nothing. If a source cannot be mapped exactly,
coverage returns an infrastructure error instead of an approximate percentage.
`doctor` exercises the identical transform in memory so the repair can happen
before a coverage run.

## Daemon and editors

The daemon is a bidirectional NDJSON loop. It discovers in-process and starts
run/watch operations in cancellable child process trees. Stdout is reserved for
validated protocol-v1 records; compiler and operational output is sent to
stderr. Operation IDs prevent stale completions after cancellation.

VS Code and Neovim start one daemon per Gleam package root. This is also the
monorepo model: packages remain independent, while the editor owns discovery,
restart, and complete removal of diagnostics from obsolete generations.

## Test strategy

Pure indexing, configuration, selection, dependency, scheduling, protocol,
reporting, and coverage logic use unit tests. Fixture projects exercise real
compilers, processes, cancellation, Promise failures, teardown failures, and
coverage. CI then runs those tests on Linux, macOS, and Windows across Erlang,
Node.js, Bun, and Deno. Protocol/schema, package-interface, Hex-tarball, editor,
format, and warning checks are release gates.
