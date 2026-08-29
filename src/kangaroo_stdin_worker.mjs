import { createReadStream, fstatSync } from "node:fs";
import { Socket } from "node:net";
import { ReadStream as TtyReadStream, isatty } from "node:tty";
import { workerData } from "node:worker_threads";

const port = workerData.port;
const control = new Int32Array(workerData.controlBuffer);

function send(message) {
  port.postMessage(message);
  Atomics.add(control, 0, 1);
  Atomics.notify(control, 0);
}

let buffer = "";
let ended = false;
let input;
let bunReader;
if (typeof globalThis.Bun !== "undefined") {
  bunReader = globalThis.Bun.stdin.stream().getReader();
  void readBunInput();
} else {
  input = stdinStream();
  input.setEncoding("utf8");
  input.on("data", acceptChunk);
  input.once("end", finish);
  input.once("error", finish);
}

function stdinStream() {
  if (isatty(0)) return new TtyReadStream(0);
  try {
    const stat = fstatSync(0);
    if (stat.isFIFO() || stat.isSocket() || stat.isCharacterDevice()) {
      return new Socket({ fd: 0, readable: true, writable: false });
    }
  } catch {
    // Let createReadStream report the inaccessible descriptor as InputEnd.
  }
  return createReadStream("", { fd: 0, autoClose: false });
}

function finish() {
  if (ended) return;
  ended = true;
  if (buffer.length > 0) send({ type: "line", value: trimCr(buffer) });
  send({ type: "end" });
  port.close();
}

function stop() {
  if (!ended) {
    ended = true;
    if (bunReader) void bunReader.cancel();
    else input.destroy();
  }
  Atomics.store(control, 1, 1);
  Atomics.notify(control, 1);
  port.close();
  globalThis.process.exit(0);
}

function trimCr(value) {
  return value.endsWith("\r") ? value.slice(0, -1) : value;
}

function acceptChunk(chunk) {
  buffer += String(chunk);
  while (true) {
    const newline = buffer.indexOf("\n");
    if (newline < 0) return;
    send({ type: "line", value: trimCr(buffer.slice(0, newline)) });
    buffer = buffer.slice(newline + 1);
  }
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
    // An inaccessible or cancelled stdin is an ordinary protocol EOF.
  }
  finish();
}

port.on("message", (message) => {
  if (message?.type === "stop") stop();
});
