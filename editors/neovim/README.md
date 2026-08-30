# kangaroo.nvim

Kangaroo's Neovim plugin starts a protocol-v1 daemon automatically when a
Gleam buffer is opened. Each `gleam.toml` root gets its own daemon, so
monorepos work without additional configuration.

## Installation

With lazy.nvim:

```lua
{
  "P4suta/kangaroo",
  config = function(plugin)
    vim.opt.rtp:append(plugin.dir .. "/editors/neovim")
    require("kangaroo").setup({
      gleam_path = "gleam",
      javascript_runtime = "nodejs", -- or "bun" / "deno"
    })
  end,
}
```

The plugin uses the configured `gleam_path` and the project's `kangaroo` 1.x
dependency. For a JavaScript-target package, discovery, watch, run, and
coverage all use `javascript_runtime`. There is no separate CLI package or
build step. Unknown options, empty executable paths, and unsupported runtimes
are reported during setup instead of being ignored.

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

`:KangarooRun` without an argument requires the cursor to be inside a
discovered test. If it is not, the command reports that no test was selected
instead of silently broadening the request to the whole package.

Diagnostics use the protocol's one-based source positions and are converted
to Neovim's zero-based API exactly once. A new run and a daemon crash both
clear all diagnostics from the previous generation. A daemon crash schedules
an automatic restart and fresh discovery. Rapid crash loops use exponential
backoff and stop after five attempts; `:KangarooStart` explicitly retries.
Cancelling an operation immediately invalidates and removes its editor-side
generation, so late output cannot restore stale diagnostics or status.
Discovery that does not complete within 60 seconds force-stops the process tree
and restarts the daemon instead of leaving the editor request pending forever.
Saving `gleam.toml` restarts that package daemon so target changes take effect.
The replacement waits for the old daemon and any cancelling coverage process
to exit, preventing two compiler trees from sharing the package at once.
Only the newest discovery response may replace the package's test list.
Discovery failure and daemon exit clear stale test IDs until rediscovery.
Every completed watch generation requests fresh discovery, so added and
removed tests converge without restarting the plugin.
Each coverage refresh also removes signs for files omitted by the new LCOV
report, and stopping the plugin clears its owned coverage signs. Coverage is
package-serial: another refresh is refused while the prior
process is running or stopping, and its command output is discarded except for
a bounded error tail because the LCOV file is the source of coverage data.
Exit 1 still publishes the complete LCOV result while warning about test,
flaky, or threshold failures; infrastructure exit 2 leaves the prior result
unchanged.
Daemon stdout is decoded incrementally with a 128 MiB per-record ceiling; an
oversized or schema-invalid protocol-v1 record force-stops and restarts the
daemon. Records with a different integer protocol version are ignored for
forward compatibility.

## Headless test

```sh
nvim --headless -u NONE -l test/headless.lua
```

CI runs this lifecycle test on the current stable Neovim release, including
daemon crash recovery, operation tracking, Windows path normalization, and
stale diagnostic/coverage cleanup.
