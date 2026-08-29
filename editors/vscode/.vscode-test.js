"use strict";

const path = require("node:path");
const { defineConfig } = require("@vscode/test-cli");

const setupBeamRoot = process.env.INSTALL_DIR_FOR_GLEAM;
const setupBeamGleam = setupBeamRoot
  ? path.join(
    setupBeamRoot,
    "bin",
    process.platform === "win32" ? "gleam.exe" : "gleam",
  )
  : undefined;

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
  env: {
    KANGAROO_GLEAM_PATH: process.env.KANGAROO_GLEAM_PATH || setupBeamGleam,
    KANGAROO_VSCODE_TOOL_PATH: process.env.PATH,
  },
});
