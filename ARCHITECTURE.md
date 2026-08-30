# Architecture

Kangaroo 1.x is one Gleam package. `kangaroo` is its stable user-facing public
module. `kangaroo/coverage_probe` is a second public module only because the
disposable instrumentation clone must import it across the downstream package
boundary; it is a tooling ABI, not an application API. Every other module is
listed as internal, so the compiler-generated package interface cannot
accidentally turn a runner detail into a compatibility promise.

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
no partial runnable index. Cache reuse requires exact source bytes and the same
source-root configuration, so a hash collision cannot publish a stale tree.
Watch generations reuse unchanged index entries and fall back to the complete
suite when a changed FFI/config/manifest file cannot be mapped safely.

## Scheduling and isolation

The scheduler groups tests by module. Groups run in deterministic waves up to
the configured worker limit, while functions inside a module remain serial and
in definition order. An explicit `serial()` marker or configured serial tag
runs its group alone. Optional shuffling reorders groups from a reproducible
seed and never reorders functions inside a group.

Every test crosses one isolation boundary:

- Erlang runs it in a fresh process and terminates descendant processes at the
  end of the test or timeout.
- JavaScript runs each test through a Worker and awaits a returned
  Promise. Rejection, panic, and timeout are converted to the same outcome.

Both adapters capture stdout and stderr without allowing one test's state to
leak into another. Combined child output is capped at 16 MiB and becomes an
infrastructure error at the boundary, before an untrusted compiler or test can
grow the runner indefinitely. A teardown is attempted after every fixture body
outcome; double failures retain both causes.

Test-owned asynchronous subprocesses are registered in shared memory before
control returns to the test. Timeout cleanup can therefore freeze and kill the
tree even while the runtime Worker is unresponsive. Safe Unix synchronous
calls receive an earlier bounded deadline and their process group remains
registered through test completion; unsupported synchronous boundaries are
rejected before launch.

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

Watch snapshots always cover Gleam's complete `src`, `dev`, and `test`
development roots, plus configured extra paths, Gleam FFI, `gleam.toml`, and
the manifest. Discovery still runs tests only below configured `test_paths`;
the broader snapshot keeps imported helpers from producing stale results.
Content equality makes equal-mtime writes, atomic renames, additions, and
removals observable. Extra roots are refreshed after a configuration change.

The initial and later runs are child process trees. When another save arrives,
the active compile/run is cancelled before the new generation starts. Only the
latest generation may publish completion; both compile and run re-read the
source snapshot after their child reaches a terminal state to close the final
poll-to-publication race. The previous dependency graph is
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

Cleanup accepts only a real directory whose ownership marker contains that
directory's exact path. A prefix-like name, missing or forged marker, and
symlink are all rejected before recursive deletion.

## Daemon and editors

The daemon is a bidirectional NDJSON loop. It discovers in-process and starts
run/watch operations in cancellable child process trees. Stdout is reserved for
validated protocol-v1 records; compiler and operational output is sent to
stderr. Operation IDs prevent stale completions after cancellation, and the
daemon accepts at most 32 concurrent operations. Its stdin reader bounds an
individual request at 1 MiB and discards an overlong fragmented line without
ending or desynchronising the stream.

VS Code and Neovim start one daemon per Gleam package root. This is also the
monorepo model: packages remain independent, while the editor owns discovery,
restart, and complete removal of diagnostics from obsolete generations. Each
client assigns a monotonically increasing generation to operations and
coverage refreshes, so a late event or filesystem read cannot overwrite newer
editor state. Discovery has a bounded deadline and restarts an unresponsive
daemon.

Each editor reads the package target and passes the configured JavaScript
runtime to both daemon and coverage invocations. Discovery responses are
generation-bound: an older refresh can never replace the newest test tree.
The clients retain fragmented protocol records in linear-time buffers with a
128 MiB ceiling, validate complete protocol-v1 response shapes, and restart
fail-closed after schema-invalid or oversized stdout.
Watch completion triggers discovery, and VS Code reconciles stable TestItem
objects instead of replacing an unchanged tree. Coverage ownership remains
package-serial until the old process is terminal, even when its UI run has
already been cancelled.
Editor shutdown first uses the protocol and then force-stops the detached
process tree when the graceful deadline expires.

## Test strategy

Pure indexing, configuration, selection, dependency, scheduling, protocol,
reporting, and coverage logic use unit tests. Fixture projects exercise real
compilers, processes, cancellation, Promise failures, teardown failures, and
coverage. CI then runs those tests on Linux, macOS, and Windows across Erlang,
Node.js, Bun, and Deno. Protocol/schema, package-interface, Hex-tarball, editor,
format, and warning checks are release gates.
