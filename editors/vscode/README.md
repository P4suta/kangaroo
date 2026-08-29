# kangaroo for VS Code

Continuous Gleam test results in VS Code: the extension runs
`kangaroo_cli watch --json` in the background and surfaces failures as
diagnostics (the Problems panel) with a status bar summary.

## Install

```sh
cd editors/vscode
npm install -g @vscode/vsce
vsce package
code --install-extension kangaroo-0.1.0.vsix
```

## Usage

- `Kangaroo: Start watching tests` starts the watcher for the workspace.
- `Kangaroo: Stop watching` stops it.
- `kangaroo.gleamPath` configures the `gleam` executable when it is not
  on `PATH`.
