// Gleam's JavaScript launcher buffers a long-lived program's output. Daemon
// watch operations execute this built entry point directly so NDJSON remains
// available while the coordinator is still running.
import { main } from "./kangaroo.mjs";

main();
