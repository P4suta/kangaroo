# Troubleshooting

Start with:

```sh
gleam run -m kangaroo -- doctor
```

Doctor exits 2 for an unsupported toolchain, discovery/configuration problem,
or source that cannot be instrumented exactly.

Kangaroo rejects unknown keys below `[tools.kangaroo]` and empty entries in
path or tag arrays. Use the fully qualified key in the error to correct
spelling or move the setting to its documented `watch` or `coverage` table.

## No tests matched

Only public, zero-argument functions ending in `_test` below `test_paths` are
discovered. Check the exact inventory with:

```sh
gleam run -m kangaroo -- list
gleam run -m kangaroo -- list --reporter ndjson
```

Selectors use project-relative `/` paths. Quote stable IDs in shells where
`::` has special meaning. Exclude tags take precedence over every selector.

## Metadata error

`tag`, `tags`, and `timeout` must use literals and `serial()` accepts no
arguments. Dynamic decisions belong in `skip_if`; dynamic scheduling metadata
would make discovery nondeterministic and is rejected with a source line.
Configuration paths and globs are project-relative; absolute paths and `..`
components are rejected rather than allowing a watch or cleanup to escape the
package root. `test_paths` must be inside Gleam's compiled `src`, `dev`, or
`test` directories; use a narrower path such as `test/integration` when needed.

## Watch appears stale

Kangaroo cancels old generations and publishes only the newest. Compiler output
for an invalid save is written to stderr. The complete `src`, `dev`, and `test`
trees are watched even when `test_paths` narrows discovery, so imported helper
changes cannot leave stale results. Excluding a helper from test discovery
does not remove its import edges from watch planning. Ensure edited
generated/config files outside those roots are listed in
`[tools.kangaroo.watch].extra_paths`. Changing
`gleam.toml` refreshes extra roots automatically.

On Windows, allow the terminal/editor to terminate child process trees. A
security product that blocks descendant termination can make cancellation
exceed the 2 second Windows performance budget. The Unix budget is 250 ms.
Kangaroo reports a JavaScript hard-cleanup deadline as an infrastructure error
instead of treating it as a completed cancellation.

## Deno permission denied

Use the `[javascript.deno]` capability table in
[runtimes.md](runtimes.md). Kangaroo does not silently broaden Deno authority.

If a JavaScript FFI test reports that a synchronous subprocess cannot be
safely isolated, replace a Bun/Deno synchronous subprocess or a Windows sync
child call with its asynchronous form. Kangaroo rejects the call before launch
rather than letting a timed-out test leave a process behind.

## Coverage failed before reporting

Coverage never prints approximate values. Fix the located parse or
instrumentation error from `doctor`. Ensure `coverage.include` matches at least
one Gleam source. The original checkout should not contain injected probe calls;
if it does, stop and report a bug with the relevant source and command.

LCOV and Cobertura files are created only when those reporters are configured:

```toml
[tools.kangaroo.coverage]
reporters = ["terminal", "lcov", "cobertura"]
```

When the test reporter is NDJSON, the terminal coverage table and compiler
logs intentionally use stderr so every stdout line remains machine-readable.

## Editor tree or diagnostics are stale

Both official clients rediscover after each completed watch generation, end
active operations after a daemon failure, clear prior diagnostics, and restart
the crashed daemon. If a tree still cannot converge, run the editor's refresh
command and inspect the Kangaroo output for a discovery or protocol error. In a
monorepo, verify that each package directory has its own `gleam.toml` and
Kangaroo development dependency.

Discovery that produces no complete response within 60 seconds is treated as
a stalled daemon and restarted. If this repeats, run `doctor` in that package
root and inspect compiler output on stderr.

## Reporting a reproducible problem

Include `doctor --reporter ndjson`, target/runtime versions, operating system,
the smallest fixture, and whether the failure occurs in one-shot, watch, daemon,
or coverage mode. Remove secrets and private source before opening an issue.
