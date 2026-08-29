import { read } from "node:fs";
import { parentPort, workerData } from "node:worker_threads";

const port = workerData.port;
const control = new Int32Array(workerData.controlBuffer);

globalThis.process.once?.("exit", () => {
  Atomics.store(control, 1, 2);
  Atomics.notify(control, 1);
});

function send(message) {
  port.postMessage(message);
  Atomics.add(control, 0, 1);
  Atomics.notify(control, 0);
}

let buffer = "";
let ended = false;
let waitingForContinue = false;
let readPending = false;
const readBuffer = new Uint8Array(64 * 1024);
const nodeDecoder = new TextDecoder();
let bunReader;
let resumeBunRead;
if (typeof globalThis.Bun !== "undefined") {
  bunReader = globalThis.Bun.stdin.stream().getReader();
  void readBunInput();
} else {
  readNextChunk();
}

function finish() {
  if (ended) return;
  ended = true;
  if (buffer.length > 0) send({ type: "line", value: trimCr(buffer) });
  send({ type: "end" });
  port.close();
  parentPort?.close?.();
}

function stop() {
  if (!ended) {
    ended = true;
    if (bunReader) void bunReader.cancel();
  }
  Atomics.store(control, 1, 1);
  Atomics.notify(control, 1);
  port.close();
  parentPort?.close?.();
}

function trimCr(value) {
  return value.endsWith("\r") ? value.slice(0, -1) : value;
}

function acceptChunk(chunk) {
  buffer += String(chunk);
  deliverBufferedLine();
}

function deliverBufferedLine() {
  if (waitingForContinue) return false;
  const newline = buffer.indexOf("\n");
  if (newline < 0) return false;
  const line = trimCr(buffer.slice(0, newline));
  buffer = buffer.slice(newline + 1);
  waitingForContinue = true;
  send({ type: "line", value: line });
  return true;
}

function continueReading() {
  if (ended) return;
  waitingForContinue = false;
  deliverBufferedLine();
  if (bunReader) {
    const resume = resumeBunRead;
    resumeBunRead = undefined;
    resume?.();
  } else if (!waitingForContinue) {
    readNextChunk();
  }
}

function readNextChunk() {
  if (ended || waitingForContinue || readPending) return;
  readPending = true;
  read(0, readBuffer, 0, readBuffer.length, null, (error, count) => {
    readPending = false;
    if (ended) return;
    if (error) {
      finish();
      return;
    }
    if (count === 0) {
      acceptChunk(nodeDecoder.decode());
      finish();
      return;
    }
    acceptChunk(
      nodeDecoder.decode(readBuffer.subarray(0, count), { stream: true }),
    );
    if (!waitingForContinue) readNextChunk();
  });
}

async function readBunInput() {
  const decoder = new TextDecoder();
  try {
    while (!ended) {
      const { done, value } = await bunReader.read();
      if (done) break;
      acceptChunk(decoder.decode(value, { stream: true }));
      while (!ended && waitingForContinue) {
        await new Promise((resolve) => {
          resumeBunRead = resolve;
        });
      }
    }
    if (!ended) acceptChunk(decoder.decode());
  } catch {
    // An inaccessible or cancelled stdin is an ordinary protocol EOF.
  }
  finish();
}

port.on("message", (message) => {
  if (message?.type === "stop") stop();
  if (message?.type === "continue") continueReading();
});
