# kangaroo.nvim

Kangaroo's Neovim plugin starts a protocol-v1 daemon automatically when a
Gleam buffer is opened. Each `gleam.toml` root gets its own daemon, so
monorepos work without additional configuration.

## Installation

With lazy.nvim:

```lua
{ "P4suta/kangaroo", subdir = "editors/neovim" }
```

The plugin uses the `gleam` executable and the project's `kangaroo` 1.x
dependency. There is no separate CLI package or build step.

## Commands

| Command | Action |
| --- | --- |
| `:KangarooRun [selector]` | Run the selector or the test under the cursor |
| `:KangarooRunFile` | Run the current test file |
| `:KangarooCancel` | Cancel the newest active run or watch operation |
| `:KangarooTests` | Pick and run a discovered test |
| `:KangarooQuickfix` | Open current failures in quickfix |
| `:KangarooCoverage` | Run full coverage and add line signs from LCOV |
| `:KangarooBirdie` | Open Birdie's interactive review in a terminal split |
| `:KangarooStart` / `:KangarooStop` | Start or stop the current package daemon |
| `:KangarooStatus` | Show the latest summary |

Diagnostics use the protocol's one-based source positions and are converted
to Neovim's zero-based API exactly once. A new run and a daemon crash both
clear all diagnostics from the previous generation. A daemon crash schedules
an automatic restart and fresh discovery. Each coverage refresh also removes
signs for files omitted by the new LCOV report.

## Headless test

```sh
nvim --headless -u NONE -l test/headless.lua
```

CI runs this lifecycle test on the current stable Neovim release, including
daemon crash recovery, operation tracking, Windows path normalization, and
stale diagnostic/coverage cleanup.
