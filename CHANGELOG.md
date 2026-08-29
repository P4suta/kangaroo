# Changelog

## 1.0.0 (2026-08-29)


### Features

* **cli:** in-VM test execution with hot module reloading ([ce45b8b](https://github.com/P4suta/kangaroo/commit/ce45b8ba2340bf3dcff347c24009fc9c992c26e0))
* **cli:** incremental directory walk and fast settled polling ([6155478](https://github.com/P4suta/kangaroo/commit/6155478ba90c7b9185429dc7a6e107774bb4457f))
* **cli:** line coverage with Erlang cover ([4aabbe7](https://github.com/P4suta/kangaroo/commit/4aabbe729f6da5791c2a8e11c8b3315d441a4524))
* **cli:** rich TUI and JSON editor protocol ([736135e](https://github.com/P4suta/kangaroo/commit/736135e9f471086ddfbfd4945a8d6aa6bbd6b3b8))
* **cli:** run suites concurrently across BEAM schedulers ([3e276e5](https://github.com/P4suta/kangaroo/commit/3e276e50ed176774ba2aad1b8f0a5df54004f4da))
* **cli:** TUI keyboard input and TTY detection ([51da300](https://github.com/P4suta/kangaroo/commit/51da3003d922bc5f2a0459583fd0723dd787d2e1))
* **cli:** TUI run duration and alternate screen buffer ([08b5576](https://github.com/P4suta/kangaroo/commit/08b5576d90a30029bad1d5267ba1a2daaa57461d))
* **cli:** V8 coverage on JavaScript ([5a506e7](https://github.com/P4suta/kangaroo/commit/5a506e70dd1e856cff502ef3b66ccbdb38625677))
* **cli:** watch --coverage and compile phase events in the protocol ([9301536](https://github.com/P4suta/kangaroo/commit/930153661a918ef9dc1dfbb0c749cfdf8cd884ce))
* **cli:** watch/run dispatch as a pure command parser, --help and --version ([3ce81ad](https://github.com/P4suta/kangaroo/commit/3ce81adf1a916c8c4e8e3cb7d077afc13a2fa373))
* **editors:** Neovim plugin and VS Code extension ([1785683](https://github.com/P4suta/kangaroo/commit/1785683d6086912dd6197d0098e95bb411e4d31b))
* failure locations, suite lifecycle events, and run flags ([df4a9ef](https://github.com/P4suta/kangaroo/commit/df4a9ef164663fdba0c61b6eeb62191df21bec2d))
* kangaroo test framework and continuous test runner ([b81fbe1](https://github.com/P4suta/kangaroo/commit/b81fbe11db7ffe7658c12a1ce320d1ea53a9f8aa))
* Result matchers and source columns ([fb4143b](https://github.com/P4suta/kangaroo/commit/fb4143bd226c39fe5229eb30f777100b87a6525e))


### Bug Fixes

* **cli:** keep the JSON protocol stream pure on stdout ([a1998cd](https://github.com/P4suta/kangaroo/commit/a1998cd11cfb8fe7a2ad245f0a356a72e17589e3))
* **cli:** show compile failures in the TUI and fix in-VM locations ([8bbc8b8](https://github.com/P4suta/kangaroo/commit/8bbc8b821d33464a420b36de30933a666d55a489))
* don't mistake a checkout directory for framework code ([#4](https://github.com/P4suta/kangaroo/issues/4)) ([068bb69](https://github.com/P4suta/kangaroo/commit/068bb6989ec0977003215e204439f3da55363ded))
* start release-please from 0.0.0 so the first release is 0.1.0 ([#8](https://github.com/P4suta/kangaroo/issues/8)) ([83df6e7](https://github.com/P4suta/kangaroo/commit/83df6e7ca2d7aef02d55c36e5ecff5e7420a12c6))

## Changelog

All notable changes to this project are documented in this file.

## Unreleased

### Added

- `to_be_ok` / `to_be_error` Result matchers, naming the unexpected value
- Source `column` in failure locations (JavaScript stacks); the editor
  protocol carries it as an optional field
- CLI commands: `--help`, `--version`, pure command-line parsing
- Compile-failure screen in the TUI (with the truncated compiler report,
  `r` to retry)
- Suite-level parallelism: suites run concurrently across BEAM
  schedulers (Erlang); a single run bracket and cross-group summary
- Editor consumers: Neovim plugin (`editors/neovim`) and VS Code
  extension (`editors/vscode`)
- Watch latency benchmark (`cli/scripts/bench.sh`)

### Changed

- Watch loop reworked: incremental directory walk, 50 ms polling,
  adaptive settle — typical save-to-run latency ~120 ms (previously
  ~400 ms)
- JSON protocol purity: status and diagnostics go to stderr, so
  `--json` output is a clean NDJSON stream
- The in-VM runner pre-loads every test module before collecting
  suites, skips deleted test files, and no longer purges loaded modules
  up front (loading the same version is a no-op)
- The TUI renders on the terminal's alternate screen buffer and shows
  the run duration

### Fixed

- In-VM failure locations pointed at the compiled framework instead of
  the test body when the CLI ran a project that depends on kangaroo;
  the compiled artefact form of framework frames is now recognised
- The deep content check compared different file sets (`.gleam` only vs
  everything watched), reporting config and ffi files as removed on
  every deep check
- Re-listing a directory reported files under its subdirectories as
  removed
- Deleted test files left stale beams that kept being executed
