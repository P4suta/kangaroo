# Kangaroo for VS Code

The extension finds every `gleam.toml` below each workspace folder and starts
one Kangaroo protocol-v1 daemon per package. Public `*_test` functions appear
in VS Code's Testing view and can be run individually, by file, for the whole
package, or continuously. Testing API exclusions are preserved.

Failures are published both as Testing API messages and Problems diagnostics.
Every new run clears stale diagnostics, and an unexpected daemon exit ends the
active run, clears stale state, restarts the daemon, and rediscovers tests.

## Requirements

- Gleam 1.18 or newer
- The project depends on `kangaroo` 1.x
- `gleam` is on `PATH`, or `kangaroo.gleamPath` points to it

No standalone CLI is required. The extension invokes the package's unified
entry point:

```sh
gleam run -m kangaroo -- daemon
```

Multi-root workspaces and monorepos are supported; creating or deleting a
`gleam.toml` adds or removes the corresponding independent test tree and
daemon lifecycle.

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
