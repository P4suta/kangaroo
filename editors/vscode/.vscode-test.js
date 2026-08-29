"use strict";

const { defineConfig } = require("@vscode/test-cli");

module.exports = defineConfig({
  files: "test/integration/**/*.test.js",
  workspaceFolder: "test/workspace",
  launchArgs: [
    "--disable-extensions",
    "--disable-workspace-trust",
    "--skip-welcome",
    "--skip-release-notes",
  ],
  mocha: {
    timeout: 60_000,
  },
});
