# Contributing

Thank you for improving Kangaroo. By participating, you agree to the
[Code of Conduct](CODE_OF_CONDUCT.md), and contributions are licensed under
Apache-2.0.

## Test-first workflow

Every behaviour change starts with a focused failing test:

1. Add the smallest unit, fixture, protocol golden, or editor regression that
   demonstrates the desired public outcome.
2. Run it and record the expected failure (red).
3. Implement the coherent minimum that makes it pass (green).
4. Refactor while keeping the focused test green.
5. Run formatting, warning checks, every available runtime, and affected
   editor tests before opening a pull request.

Bug fixes without a regression test are incomplete unless the failure cannot
be reproduced deterministically; explain such exceptions in the pull request.

## Local checks

```sh
gleam deps download
gleam format --check src test
gleam build --target erlang --warnings-as-errors
gleam build --target javascript --warnings-as-errors
gleam test --target erlang
gleam test --target javascript --runtime nodejs
gleam test --target javascript --runtime bun
gleam test --target javascript --runtime deno
(cd editors/vscode && npm test)
nvim --headless -u NONE -l editors/neovim/test/headless.lua
```

Use `gleam export package-interface` after public-module changes; its module
list must contain only `kangaroo`. Do not commit generated `build/`, `coverage/`,
`.vsix`, or temporary coverage workspaces.

## Changes and reviews

Keep commits scoped and use a clear imperative subject. Pull requests should
state the user-visible outcome, the red test, supported backends exercised, and
any protocol/schema or migration impact. A protocol change requires golden
tests, schema/docs updates, and either backward compatibility within v1 or a
new protocol version.

Never include secrets, production data, or generated dependency caches.
