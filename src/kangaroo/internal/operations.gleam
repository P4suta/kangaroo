import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Kind {
  RunOperation
  WatchOperation
}

pub type Entry {
  Entry(
    id: String,
    handle: Int,
    kind: Kind,
    buffer: String,
    pending_fragments: List(String),
    buffered_bytes: Int,
    terminal_error: Option(String),
  )
}

pub type State {
  State(entries: List(Entry))
}

const max_active_operations = 32

const max_buffered_output_bytes = 16_777_216

pub fn empty() -> State {
  State([])
}

pub fn entries(state: State) -> List(Entry) {
  state.entries
}

pub fn has(state: State, id: String) -> Bool {
  list.any(state.entries, fn(entry) { entry.id == id })
}

/// Looks up an operation without relinquishing ownership. Cancellation keeps
/// the entry until the child reaches a terminal state, so a timeout cannot
/// turn a still-running process into an untracked stale operation.
pub fn handle(state: State, id: String) -> Option(Int) {
  case list.find(state.entries, fn(entry) { entry.id == id }) {
    Ok(entry) -> Some(entry.handle)
    Error(_) -> None
  }
}

pub fn start(
  state: State,
  id: String,
  handle: Int,
  kind: Kind,
) -> Result(State, String) {
  use _ <- result.try(can_start(state, id))
  Ok(
    State(
      list.append(state.entries, [
        Entry(id, handle, kind, "", [], 0, None),
      ]),
    ),
  )
}

/// Checks daemon capacity before a child process is spawned.
pub fn can_start(state: State, id: String) -> Result(Nil, String) {
  case has(state, id), list.length(state.entries) >= max_active_operations {
    True, _ -> Error("operation `" <> id <> "` is already active")
    _, True -> Error("daemon supports at most 32 active operations")
    False, False -> Ok(Nil)
  }
}

/// Appends a process chunk while bounding output already accepted by the
/// daemon but not yet written to its client. Streaming-process acknowledgments
/// move memory ownership into this buffer, so both sides enforce the same
/// limit independently.
pub fn append_output_checked(
  state: State,
  id: String,
  chunk: String,
) -> Result(State, String) {
  append_output_with_limit(state, id, chunk, max_buffered_output_bytes)
}

pub fn append_output_with_limit(
  state: State,
  id: String,
  chunk: String,
  limit: Int,
) -> Result(State, String) {
  case list.find(state.entries, fn(entry) { entry.id == id }) {
    Error(_) -> Ok(state)
    Ok(found) -> {
      let buffered_bytes = found.buffered_bytes + string.byte_size(chunk)
      case buffered_bytes > limit {
        True -> Error("process output exceeded 16777216 bytes")
        False ->
          Ok(
            State(
              list.map(state.entries, fn(entry) {
                case entry.id == id {
                  True ->
                    case string.contains(chunk, "\n") {
                      True ->
                        Entry(
                          ..entry,
                          buffer: join_fragments(
                            found.buffer,
                            found.pending_fragments,
                            chunk,
                          ),
                          pending_fragments: [],
                          buffered_bytes:,
                        )
                      False ->
                        Entry(
                          ..entry,
                          pending_fragments: [chunk, ..found.pending_fragments],
                          buffered_bytes:,
                        )
                    }
                  False -> entry
                }
              }),
            ),
          )
      }
    }
  }
}

pub fn fail(state: State, id: String, message: String) -> State {
  State(
    list.map(state.entries, fn(entry) {
      case entry.id == id {
        True -> Entry(..entry, terminal_error: Some(message))
        False -> entry
      }
    }),
  )
}

/// Removes at most `limit` complete lines from an operation's buffered output.
/// The unsplit suffix stays raw so one large process chunk cannot allocate and
/// synchronously emit an unbounded list before the daemon reads stdin again.
pub fn take_output_lines(
  state: State,
  id: String,
  limit: Int,
) -> #(State, List(String)) {
  case list.find(state.entries, fn(entry) { entry.id == id }) {
    Error(_) -> #(state, [])
    Ok(found) -> {
      let #(remainder, lines) = take_lines(found.buffer, limit, [])
      let consumed_bytes =
        string.byte_size(found.buffer) - string.byte_size(remainder)
      #(
        State(
          list.map(state.entries, fn(entry) {
            case entry.id == id {
              True ->
                Entry(
                  ..entry,
                  buffer: remainder,
                  buffered_bytes: int.max(
                    0,
                    found.buffered_bytes - consumed_bytes,
                  ),
                )
              False -> entry
            }
          }),
        ),
        lines,
      )
    }
  }
}

fn take_lines(buffer: String, remaining: Int, found: List(String)) {
  case remaining <= 0 {
    True -> #(buffer, list.reverse(found))
    False ->
      case string.split_once(buffer, on: "\n") {
        Error(_) -> #(buffer, list.reverse(found))
        Ok(#(line, rest)) ->
          take_lines(rest, remaining - 1, [string.trim_end(line), ..found])
      }
  }
}

pub fn finish_output(state: State, id: String) -> #(State, Option(String)) {
  case list.find(state.entries, fn(entry) { entry.id == id }) {
    Error(_) -> #(state, None)
    Ok(found) -> {
      let combined = join_fragments(found.buffer, found.pending_fragments, "")
      let output = case combined {
        "" -> None
        value -> Some(value)
      }
      #(
        State(
          list.map(state.entries, fn(entry) {
            case entry.id == id {
              True ->
                Entry(
                  ..entry,
                  buffer: "",
                  pending_fragments: [],
                  buffered_bytes: 0,
                )
              False -> entry
            }
          }),
        ),
        output,
      )
    }
  }
}

fn join_fragments(
  buffer: String,
  pending_fragments: List(String),
  final: String,
) -> String {
  string.concat([buffer, ..list.reverse([final, ..pending_fragments])])
}

pub fn cancel(state: State, id: String) -> #(State, Option(Int)) {
  remove(state, id)
}

pub fn complete(state: State, id: String) -> #(State, Bool) {
  let #(state, handle) = remove(state, id)
  case handle {
    Some(_) -> #(state, True)
    None -> #(state, False)
  }
}

pub fn shutdown(state: State) -> #(State, List(Int)) {
  #(empty(), list.map(state.entries, fn(entry) { entry.handle }))
}

fn remove(state: State, id: String) -> #(State, Option(Int)) {
  let #(remaining, handle) =
    list.fold(state.entries, #([], None), fn(found, entry) {
      let #(remaining, handle) = found
      case entry.id == id, handle {
        True, None -> #(remaining, Some(entry.handle))
        _, _ -> #(list.append(remaining, [entry]), handle)
      }
    })
  #(State(remaining), handle)
}
