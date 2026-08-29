import { toList } from "./gleam.mjs";

let cases = [];
let output = [];

export function append(value) {
  cases.push(value);
}

export function take() {
  const result = toList(cases);
  cases = [];
  return result;
}

export function append_output(caseName, stdout, stderr) {
  output.push([caseName, stdout, stderr]);
}

export function take_output() {
  const result = toList(output);
  output = [];
  return result;
}
