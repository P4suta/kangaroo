import gleam/option.{type Option, None, Some}

pub type State {
  State(next: Int, active: Option(Int))
}

pub type Action {
  Start(id: Int)
  Cancel(id: Int)
  Publish(id: Int)
}

pub fn idle() -> State {
  State(next: 1, active: None)
}

/// Begins the next immutable source generation. Cancellation is ordered
/// before start so a coordinator can never have two publishable generations.
pub fn changed(state: State) -> #(State, List(Action)) {
  let id = state.next
  let cancellation = case state.active {
    Some(active) -> [Cancel(active)]
    None -> []
  }
  #(
    State(next: id + 1, active: Some(id)),
    list_append(cancellation, [Start(id)]),
  )
}

/// Only the active generation may publish. Late completion from a cancelled
/// generation is ignored without changing state.
pub fn finished(state: State, id: Int) -> #(State, List(Action)) {
  case state.active {
    Some(active) if active == id -> #(State(..state, active: None), [Publish(id)])
    _ -> #(state, [])
  }
}

pub fn active(state: State) -> Option(Int) {
  state.active
}

fn list_append(first: List(a), second: List(a)) -> List(a) {
  case first {
    [] -> second
    [item, ..rest] -> [item, ..list_append(rest, second)]
  }
}
