# Changelog

All notable changes are documented here. This project follows semantic
versioning.

## 1.0.0

### Added

- Automatic AST discovery of public zero-argument `*_test` functions, stable
  IDs, literal metadata, source ranges, and incremental dependency indexing.
- Deterministic module scheduling, serial groups, tags, selectors, fail-fast,
  retry/flaky classification, timeouts, output capture, dynamic skipping, and
  teardown-safe fixtures.
- Isolated Erlang and JavaScript execution with Promise awaiting, process-tree
  cancellation, and one panic/rejection/timeout failure model.
- `watch`, `coverage`, `list`, `init`, `doctor`, and protocol-v1 `daemon`
  commands in the main package.
- Pretty, dot, NDJSON, and JUnit reporters; terminal, LCOV, and Cobertura
  coverage reporters with aggregate and per-file thresholds.
- Runtime-independent, exact Gleam source instrumentation for Erlang, Node.js,
  Bun, and Deno coverage.
- VS Code Testing API and Neovim integrations with per-package daemon
  lifecycles and stale-diagnostic cleanup.

### Changed

- Consolidated the project into the single Hex package `kangaroo`.
- Made ordinary Gleam test functions and built-in `assert`/`let assert` the
  complete assertion model.
- Moved all configuration to `[tools.kangaroo]` and reserved only the root
  `kangaroo` module as stable public API.

### Removed

- The pre-release suite/case/matcher DSL and its separate command package.
- Compatibility aliases for unpublished 0.x APIs.

The 0.1 release candidate was not published. Version 1.0.0 is the first public
contract.
