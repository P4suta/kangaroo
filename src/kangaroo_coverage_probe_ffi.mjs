import { appendFileSync } from "node:fs";

export function hit(path, line) {
  const file = globalThis.process?.env?.KANGAROO_COVERAGE_FILE;
  if (file) appendFileSync(file, `${String(path)}\t${Number(line)}\n`);
}
