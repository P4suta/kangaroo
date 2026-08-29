import { createReadStream, fstatSync } from "node:fs";
import { Socket } from "node:net";
import { ReadStream as TtyReadStream, isatty } from "node:tty";
import { workerData } from "node:worker_threads";

const port = workerData.port;
const control = new Int32Array(workerData.controlBuffer);
let ended = false;
let input;
let bunReader;

function send(message) {
  port.postMessage(message);
  Atomics.add(control, 0, 1);
  Atomics.notify(control, 0);
}

function acceptChunk(chunk) {
  const value = String(chunk);
  if (value.length > 0) send({ type: "key", value });
}

function stdinStream() {
  if (isatty(0)) return new TtyReadStream(0);
  try {
    const stat = fstatSync(0);
    if (stat.isFIFO() || stat.isSocket() || stat.isCharacterDevice()) {
      return new Socket({ fd: 0, readable: true, writable: false });
    }
  } catch {
    // Let createReadStream report the inaccessible descriptor as end-of-input.
  }
  return createReadStream("", { fd: 0, autoClose: false });
}

function finish() {
  if (ended) return;
  ended = true;
  send({ type: "end" });
  port.close();
}

function stop() {
  if (!ended) {
    ended = true;
    if (bunReader) void bunReader.cancel();
    else {
      input.pause?.();
      input.removeAllListeners?.();
    }
  }
  Atomics.store(control, 1, 1);
  Atomics.notify(control, 1);
  port.close();
  globalThis.process.exit(0);
}

async function readBunInput() {
  const decoder = new TextDecoder();
  try {
    while (!ended) {
      const { done, value } = await bunReader.read();
      if (done) break;
      acceptChunk(decoder.decode(value, { stream: true }));
    }
    if (!ended) acceptChunk(decoder.decode());
  } catch {
    // An inaccessible or cancelled stdin is ordinary end-of-input.
  }
  finish();
}

if (typeof globalThis.Bun !== "undefined") {
  bunReader = globalThis.Bun.stdin.stream().getReader();
  void readBunInput();
} else {
  input = stdinStream();
  input.setEncoding("utf8");
  input.on("data", acceptChunk);
  input.once("end", finish);
  input.once("error", finish);
  input.resume?.();
}

port.on("message", (message) => {
  if (message?.type === "stop") stop();
});
