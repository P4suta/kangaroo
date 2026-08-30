export function insert_at_offset(source, position, insertion) {
  // Glance/glexer positions follow the backend's native String indexing:
  // UTF-8 bytes on Erlang and UTF-16 code units on JavaScript. Using Buffer
  // offsets here would therefore drift after non-ASCII text on JS.
  const input = String(source);
  const offset = Math.max(0, Math.min(Number(position), input.length));
  return input.slice(0, offset) + String(insertion) + input.slice(offset);
}

export function line_at_offset(source, position) {
  const input = String(source);
  const offset = Math.max(0, Math.min(Number(position), input.length));
  let line = 1;
  for (let index = 0; index < offset; index += 1) {
    if (input.charCodeAt(index) === 10) line += 1;
  }
  return line;
}
