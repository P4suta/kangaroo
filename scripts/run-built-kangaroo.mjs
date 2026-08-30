#!/usr/bin/env node

// Benchmark helper: run the already-built package while preserving the
// caller's working directory as the project under test.
import { main } from "../build/dev/javascript/kangaroo/kangaroo.mjs";

main();
