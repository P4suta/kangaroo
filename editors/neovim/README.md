# kangaroo.nvim

Continuous test results in Neovim. The plugin runs
`kangaroo_cli watch --json` in the background, parses the editor protocol
stream, and surfaces failures as diagnostics and a quickfix list.

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "yasunobu/kangaroo",
  ft = "gleam",
  build = "cd cli && gleam build",
  config = function() require("kangaroo").start() end,
}
```

The CLI must be reachable: add the `cli` directory of this repository to
your `PATH`, or run the plugin from a project that has `kangaroo_cli`
installed.

## Commands

| command | effect |
| --- | --- |
| `:Kangaroo` | toggle the watcher |
| `:KangarooStart` | start watching the current directory |
| `:KangarooStop` | stop and clear diagnostics |
| `:KangarooQuickfix` | open the failures in the quickfix list |
| `:KangarooStatus` | show the last run's summary |

Failures are also shown inline as diagnostics at their source location
(`file:line:column`).
