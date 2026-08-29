# Troubleshooting

Start with:

```sh
gleam run -m kangaroo -- doctor
```

Doctor exits 2 for an unsupported toolchain, discovery/configuration problem,
or source that cannot be instrumented exactly.

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

## Watch appears stale

Kangaroo cancels old generations and publishes only the newest. Compiler output
for an invalid save is written to stderr. Ensure edited generated/config files
outside the defaults are listed in `[tools.kangaroo.watch].extra_paths`.
Changing `gleam.toml` refreshes roots automatically.

On Windows, allow the terminal/editor to terminate child process trees. A
security product that blocks descendant termination can make cancellation
exceed its 250 ms contract.

## Deno permission denied

Use the `[javascript.deno]` capability table in
[runtimes.md](runtimes.md). Kangaroo does not silently broaden Deno authority.

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

## Editor tree or diagnostics are stale

Run the editor's refresh command. Both official clients end active operations,
clear prior diagnostics, restart a crashed daemon, and rediscover. In a
monorepo, verify that each package directory has its own `gleam.toml` and
Kangaroo development dependency.

## Reporting a reproducible problem

Include `doctor --reporter ndjson`, target/runtime versions, operating system,
the smallest fixture, and whether the failure occurs in one-shot, watch, daemon,
or coverage mode. Remove secrets and private source before opening an issue.
