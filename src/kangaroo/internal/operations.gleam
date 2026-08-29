import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub type Kind {
  RunOperation
  WatchOperation
}

pub type Entry {
  Entry(id: String, handle: Int, kind: Kind, buffer: String)
}

pub type State {
  State(entries: List(Entry))
}

pub fn empty() -> State {
  State([])
}

pub fn entries(state: State) -> List(Entry) {
  state.entries
}

pub fn has(state: State, id: String) -> Bool {
  list.any(state.entries, fn(entry) { entry.id == id })
}

pub fn start(
  state: State,
  id: String,
  handle: Int,
  kind: Kind,
) -> Result(State, String) {
  case list.any(state.entries, fn(entry) { entry.id == id }) {
    True -> Error("operation `" <> id <> "` is already active")
    False ->
      Ok(State(list.append(state.entries, [Entry(id, handle, kind, "")])))
  }
}

pub fn append_output(
  state: State,
  id: String,
  chunk: String,
) -> #(State, List(String)) {
  case list.find(state.entries, fn(entry) { entry.id == id }) {
    Error(_) -> #(state, [])
    Ok(found) -> {
      let parts = string.split(found.buffer <> chunk, "\n") |> list.reverse
      let #(remainder, lines) = case parts {
        [] -> #("", [])
        [remainder, ..complete] -> #(
          remainder,
          complete
            |> list.reverse
            |> list.map(fn(line) { string.trim_end(line) }),
        )
      }
      #(
        State(
          list.map(state.entries, fn(entry) {
            case entry.id == id {
              True -> Entry(..entry, buffer: remainder)
              False -> entry
            }
          }),
        ),
        lines,
      )
    }
  }
}

pub fn finish_output(state: State, id: String) -> #(State, Option(String)) {
  case list.find(state.entries, fn(entry) { entry.id == id }) {
    Error(_) -> #(state, None)
    Ok(found) -> {
      let output = case found.buffer {
        "" -> None
        value -> Some(value)
      }
      #(
        State(
          list.map(state.entries, fn(entry) {
            case entry.id == id {
              True -> Entry(..entry, buffer: "")
              False -> entry
            }
          }),
        ),
        output,
      )
    }
  }
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
