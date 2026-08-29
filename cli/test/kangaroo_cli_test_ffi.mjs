// Test-only stdout capture: gleam/io.println writes through console.log on
// JavaScript, so both console.log and process.stdout.write are replaced for
// the duration of the call. Tests use it to assert the JSON protocol stream
// is the only thing ever written to stdout.
export function capture_stdout(fun) {
  const chunks = [];
  const originalLog = console.log;
  const originalWrite = process.stdout.write;
  console.log = (term) => {
    chunks.push(String(term) + "\n");
  };
  process.stdout.write = (chunk, ...rest) => {
    chunks.push(String(chunk));
    return true;
  };
  try {
    fun();
  } finally {
    console.log = originalLog;
    process.stdout.write = originalWrite;
  }
  return chunks.join("");
}
