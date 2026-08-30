# Kangaroo for VS Code

The extension finds every `gleam.toml` below each workspace folder and starts
one Kangaroo protocol-v1 daemon per package. Public `*_test` functions appear
in VS Code's Testing view and can be run individually, by file, for the whole
package, or continuously. Testing API exclusions are preserved.

Failures are published both as Testing API messages and Problems diagnostics.
Every new run clears stale diagnostics, and an unexpected daemon exit ends the
active run, clears stale state, restarts the daemon, and rediscovers tests.
Cancelling a run ends its Testing API session immediately and invalidates its
generation, so an acknowledgement race cannot republish stale results.

## Requirements

- Gleam 1.18 or newer
- The project depends on `kangaroo` 1.x
- `gleam` is on `PATH`, or `kangaroo.gleamPath` points to it

Kangaroo is disabled in VS Code Restricted Mode because it executes the
workspace's tests and configured toolchain. It also requires a
filesystem-backed workspace rather than a virtual filesystem.

For a JavaScript-target package, set the resource-scoped
`kangaroo.javascriptRuntime` setting to `nodejs` (the default), `bun`, or
`deno`. The same runtime is used by discovery, run/watch, and coverage, and a
configuration change restarts only the affected package daemon.

No standalone CLI is required. The extension invokes the package's unified
entry point:

```sh
gleam run --target javascript --runtime bun -m kangaroo -- daemon
```

Multi-root workspaces and monorepos are supported; creating, changing, or
deleting a `gleam.toml` adds, restarts, or removes the corresponding
independent test tree and daemon lifecycle. A nested `gleam.toml` activates
the extension even before a Gleam source file is opened.

Only the newest discovery response may replace a package's Testing tree.
If discovery fails or its daemon exits, stale test IDs are removed until a
fresh discovery succeeds.
Every completed watch generation refreshes discovery, while unchanged tests
retain their Testing API identity. Added and removed tests therefore converge
without a manual refresh.
Shutdown first asks the daemon to exit cleanly, then force-stops its complete
process tree if it does not respond. Manifest and package-setting restarts do
not launch a replacement until the old daemon and any cancelling coverage
process have actually exited.

Daemon stdout is decoded incrementally with a 128 MiB per-record ceiling,
large enough for the maximum escaped captured-output event. An oversized or
schema-invalid protocol-v1 record terminates and restarts the daemon instead
of leaving a run pending; records with a different integer protocol version
are ignored for forward compatibility. Coverage is package-serial: cancelling
ends its Testing API run immediately, but a replacement is refused until the
old process has actually exited and released ownership. If a newer test
generation takes ownership while coverage is running or reading LCOV, the
older coverage snapshot is reported as superseded and is not published.

## Development

```sh
npm ci
npm test
npm run test:integration
npm run package
```

The integration suite runs inside the official VS Code Extension Development
Host against a real Gleam fixture. On Linux it needs an available display;
CI invokes it through `xvfb-run`.

`Kangaroo: Refresh tests` forces rediscovery. `Kangaroo: Stop` shuts down all
workspace daemons and removes their diagnostics.
