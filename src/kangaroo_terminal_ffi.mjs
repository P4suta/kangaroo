import { Option$None$const, Some } from "../gleam_stdlib/gleam/option.mjs";
import {
  MessageChannel,
  Worker,
  receiveMessageOnPort,
} from "node:worker_threads";

let uiActive = false;
let keyReader;
const keyWorkerUrl = new URL("./kangaroo_key_worker.mjs", import.meta.url);

function runtimeProcess() {
  return typeof globalThis.process === "object" ? globalThis.process : undefined;
}

export function stdout_is_terminal() {
  const process = runtimeProcess();
  if (process?.stdout) return process.stdout.isTTY === true;
  if (typeof globalThis.Deno === "object" && globalThis.Deno.stdout?.isTerminal) {
    return globalThis.Deno.stdout.isTerminal();
  }
  return false;
}

export function interactive_terminal() {
  const process = runtimeProcess();
  if (process?.stdin && process?.stdout) {
    return process.stdin.isTTY === true && process.stdout.isTTY === true;
  }
  return false;
}

export function dimensions() {
  const process = runtimeProcess();
  return [
    Number(process?.stdout?.columns || 80),
    Number(process?.stdout?.rows || 24),
  ];
}

function rawMode(on) {
  if (!interactive_terminal()) return;
  const process = runtimeProcess();
  process.stdin.setRawMode?.(Boolean(on));
  process.stdin.pause?.();
  if (on) startKeyReader();
  else stopKeyReader();
  process.stdout.write(on ? "\u001b[?1049h" : "\u001b[?1049l");
  uiActive = Boolean(on);
}

function startKeyReader() {
  if (keyReader) return;
  try {
    const controlBuffer = new SharedArrayBuffer(
      Int32Array.BYTES_PER_ELEMENT * 2,
    );
    const control = new Int32Array(controlBuffer);
    const { port1, port2 } = new MessageChannel();
    const worker = new Worker(keyWorkerUrl, {
      workerData: { port: port2, controlBuffer },
      transferList: [port2],
    });
    worker.on?.("error", () => {});
    worker.unref?.();
    port1.unref?.();
    keyReader = { control, port: port1, worker, ended: false };
  } catch {
    keyReader = undefined;
  }
}

function stopKeyReader() {
  const reader = keyReader;
  keyReader = undefined;
  if (!reader) return;
  if (!reader.ended) {
    reader.port.postMessage({ type: "stop" });
    Atomics.wait(reader.control, 1, 0, 250);
  }
  reader.port.close();
  reader.worker.unref?.();
  void reader.worker.terminate();
}

export function with_ui(body) {
  if (!interactive_terminal()) return body();
  const process = runtimeProcess();
  const restore = () => rawMode(false);
  process.once("exit", restore);
  rawMode(true);
  try {
    return body();
  } finally {
    rawMode(false);
    process.removeListener("exit", restore);
  }
}

export function suspend(body) {
  if (!uiActive) return body();
  rawMode(false);
  try {
    return body();
  } finally {
    rawMode(true);
  }
}

export function poll_key() {
  if (!uiActive || !keyReader || keyReader.ended) return Option$None$const;
  const received = receiveMessageOnPort(keyReader.port);
  if (!received) return Option$None$const;
  if (received.message?.type === "key") {
    return new Some(String(received.message.value || ""));
  }
  if (received.message?.type === "end") keyReader.ended = true;
  return Option$None$const;
}
