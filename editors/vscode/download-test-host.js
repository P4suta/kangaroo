"use strict";

const { setTimeout: delay } = require("node:timers/promises");
const { downloadAndUnzipVSCode } = require("@vscode/test-electron");

const VERSION = "1.95.3";
const ATTEMPTS = 3;

async function main() {
  for (let attempt = 1; attempt <= ATTEMPTS; attempt += 1) {
    try {
      const executable = await downloadAndUnzipVSCode({
        version: VERSION,
        timeout: 60_000,
      });
      console.log(`VS Code ${VERSION} test host: ${executable}`);
      return;
    } catch (error) {
      if (attempt === ATTEMPTS) {
        throw error;
      }
      console.error(
        `VS Code ${VERSION} download attempt ${attempt}/${ATTEMPTS} failed; retrying`,
        error,
      );
      await delay(attempt * 2_000);
    }
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
