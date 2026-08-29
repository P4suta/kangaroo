# Changelog

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
