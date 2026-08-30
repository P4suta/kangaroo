import { toList } from "./gleam.mjs";

let events = [];
let batchEvents = [];

export function append(event) {
  events.push(event);
}

export function take() {
  const result = toList(events);
  events = [];
  return result;
}

export function append_batch(event) {
  batchEvents.push(event);
}

export function take_batch() {
  const result = toList(batchEvents);
  batchEvents = [];
  return result;
}
