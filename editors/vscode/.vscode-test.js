"use strict";

const path = require("node:path");
const { defineConfig } = require("@vscode/test-cli");

module.exports = defineConfig({
  files: "test/integration/**/*.test.js",
  workspaceFolder: path.join(__dirname, "test", "workspace"),
  launchArgs: [
    "--disable-extensions",
    "--disable-workspace-trust",
    "--skip-welcome",
    "--skip-release-notes",
  ],
  mocha: {
    timeout: 120_000,
  },
});
