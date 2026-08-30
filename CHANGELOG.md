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
  cancellation, incremental UTF-8 decoding, bounded child output, and one
  panic/rejection/timeout failure model.
- `watch`, `coverage`, `list`, `init`, `doctor`, and protocol-v1 `daemon`
  commands in the main package.
- Pretty, dot, NDJSON, and JUnit reporters; terminal, LCOV, and Cobertura
  coverage reporters with aggregate and per-file thresholds.
- Runtime-independent, exact Gleam source instrumentation for Erlang, Node.js,
  Bun, and Deno coverage.
- VS Code Testing API and Neovim integrations with per-package daemon
  lifecycles, generation-safe diagnostics/coverage, bounded discovery, and
  stale-state cleanup.

### Changed

- Consolidated the project into the single Hex package `kangaroo`.
- Matched the documented `fixture(setup:, teardown:, body:)` labels in the
  published Gleam interface.
- Made ordinary Gleam test functions and built-in `assert`/`let assert` the
  complete assertion model.
- Moved all configuration to `[tools.kangaroo]`, rejecting unknown keys,
  empty paths, absolute paths, and parent traversal instead of silently
  ignoring mistakes or allowing cleanup outside the package.
- Exposed only `kangaroo` plus the instrumentation-only
  `kangaroo/coverage_probe` tooling ABI from the Hex package.
- Scoped CLI flags and reporters per command, added command-specific help, and
  made release publishing independently rerunnable per registry.
- Added a Bun-native process backend with a complete descriptor-write fallback
  for Bun 1.4.0 piped-stdin failures, and made coverage clones reuse nested
  dependency caches for offline builds.
- Reported a closed Erlang command stdin pipe immediately and terminated its
  complete live tree instead of discarding the write error and waiting for the
  command timeout.
- Preserved UTF-8 command arguments, environment values, executables, and
  working directories at the Erlang port boundary instead of double-encoding
  non-ASCII text.
- Made cancellation fail closed, terminate Unix process groups, and retain
  daemon operation ownership until cancellation reaches a terminal state.
- Delayed JavaScript cancellation acknowledgement until the killed child had
  closed and its streams had drained, and reported hard cleanup deadlines as
  failures instead of allowing a replacement process to overlap.
- Tracked test-owned Node, Bun, and Deno subprocesses across completion and
  timeout, bounded safe Node.js synchronous calls on Unix, and rejected Bun,
  Deno, and Windows sync boundaries that cannot expose a live tree before
  launching them.
- Bound per-test captured output and external command output to 16 MiB, and
  daemon request lines to 1 MiB, and concurrent daemon operations to 32,
  returning explicit infrastructure errors so malformed clients and noisy
  tools cannot grow memory without limit.
- Required a path-bound ownership marker before deleting a disposable coverage
  clone, including symlink-safe validation on every runtime.
- Made editor results operation-generation aware, invalidated cancelled runs
  before acknowledgement, restarted package daemons after manifest changes,
  bounded stalled discovery before recovery, and rejected stale discovery
  responses and test IDs after discovery failure or daemon exit.
- Made both editor integrations preserve a package's selected JavaScript
  runtime for daemon and coverage commands, validate runtime configuration,
  and force-stop unresponsive process trees during final cleanup.
- Made official editor protocol decoders linear-time and bounded at 128 MiB,
  failed closed on malformed daemon stdout, refreshed discovery after each
  watch generation, and preserved stable VS Code TestItem identities.
- Activated VS Code for workspaces containing only nested Gleam packages,
  bound in-flight results to their run's TestItem snapshot, and cleared
  Neovim-owned coverage signs when its package session stops.
- Kept editor coverage package-serial until the prior process reaches a
  terminal state, ignored all late cancelled output, and stopped Neovim from
  retaining an entire coverage command's stdout and stderr in memory.
- Serialized editor manifest and configuration restarts behind the old
  daemon and coverage process exits so replacement compiler trees cannot
  overlap in one package.
- Kept the Gleam, VS Code manifest, and both package-lock versions synchronized
  in release PRs, verified the exact Hex tarball lifecycle offline before
  upload, and made registry publication safe to retry independently.
- Made the performance harness force-stop its detached daemon process tree on
  every abnormal cleanup path so a failed gate cannot leak benchmark workers.
- Normalized equivalent and overlapping test roots without duplicate runs,
  made suite outcomes reflect their cases, and emitted valid JUnit XML even
  when captured output contains ANSI or other forbidden control characters.
- Watched all standard Gleam source roots while keeping narrowed test-path
  discovery exact, and made cached indexes account for nested packages,
  development modules, and root-set configuration changes.
- Retained excluded helper modules in the watch dependency graph while
  removing only their tests from the runnable set, preserving transitive
  invalidation without executing excluded cases.
- Made glob matching linear in repeated wildcard states, required an exact
  compile-only handshake, and ordered BEAM coverage flushes causally before
  publishing isolated test results.
- Reaped BEAM descendants to a monitored fixed point so processes that fork
  concurrently with test cleanup cannot escape isolation.
- Monitored the BEAM test owner itself so an untrappable linked-process exit is
  reported immediately as an exit failure instead of being misclassified as a
  test timeout after the full deadline.
- Published an emergency infrastructure result when a Node test Worker exits
  directly, allowing its registered child trees to be cleaned without waiting
  for the test timeout.
- Kept BEAM test owners alive through a trace-delivery barrier and reaped both
  spawned processes and executable ports before publishing a result; cleanup
  failures now become explicit infrastructure failures.
- Reaped inherited command groups after successful completion, terminated
  active JavaScript commands if their coordinator exits, and cleared shared
  PID ownership before numeric identifiers can be reused.
- Assigned every Windows command and test-owned asynchronous subprocess to a
  kill-on-close Job Object before its first instruction runs, and waited for
  that object to drain before reporting completion, so successful, cancelled,
  and timed-out work cannot leave descendants behind.
- Compiled the Windows Job Object launcher once and executed it directly from
  JavaScript runtimes. Erlang opens native `cmd.exe` with AutoRun disabled and
  runs a fixed, argument-free batch trampoline from its own directory for
  OTP's managed-executable boundary while still preserving redirected
  stdin/stdout and child exit status. The command processor sees only the
  immutable trampoline basename. Unicode environment overrides travel as
  private base64 metadata for the helper to restore without exposing them to
  OTP's port options or the command interpreter.
- Made daemon output draining fair to stdin across both large chunks and line
  bursts, retained unterminated output as linear-time fragments, and bounded
  Erlang request allocation while discarding an overlong line; both stdin
  readers now hand off at most one pending request record to the daemon loop.
- Stopped and joined the BEAM TUI keyboard reader while an inherited
  interactive command owns the terminal, then restarted it only after the
  child relinquishes stdin.
- Decoded invalid process output incrementally with ordered UTF-8 replacement,
  applied the 16 MiB limit after replacement expansion, and cancelled sibling
  BEAM workers immediately when a concurrent batch worker crashes.
- Failed coverage explicitly when its probe file cannot be opened, completely
  written, or flushed, instead of publishing a plausible but incomplete
  report after silently discarding persistence errors.
- Preserved the original checksummed release artifact across registry retries,
  refused ambiguous or regenerated publication bytes, and restored HexDocs
  publication without rebuilding the Hex package tarball.
- Made GitHub Release retries verify existing assets byte-for-byte, upload only
  missing assets, and refuse to overwrite a different same-named artifact.
- Limited generated `build` and `coverage` directory pruning to package roots,
  so valid source modules with either name are discovered, watched, and copied
  into coverage workspaces instead of producing a false green run.
- Revalidated source ownership after watch compile and run children reached a
  terminal state, preventing a save in the final poll window from publishing
  a stale generation.
- Validated every protocol-v1 response shape in both official editor clients,
  including nested events and failures, and restarted fail-closed instead of
  accepting schema-invalid daemon output.
- Removed inherited Windows Job Object wrapper variables case-insensitively on
  both targets, preventing differently cased environment entries from
  changing or leaking private launch metadata.
- Kept Neovim coverage signs usable for complete exit-1 reports, matching the
  CLI and VS Code contract for test, flaky, and threshold failures while still
  rejecting infrastructure exit 2.
- Declared that the VS Code extension requires Workspace Trust and a
  filesystem-backed workspace before it can execute package toolchains.
- Kept the quick performance smoke test's idle-CPU window at ten seconds so
  Linux scheduler-tick quantization cannot create a false regression failure.

### Removed

- The pre-release suite/case/matcher DSL and its separate command package.
- Compatibility aliases for unpublished 0.x APIs.

The 0.1 release candidate was not published. Version 1.0.0 is the first public
contract.
