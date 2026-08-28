import kangaroo/event.{type Event}

/// A per-run buffer of events, used to hand events from the runner's sink
/// back to the watch loop so it can update its UI state. The buffer is
/// drained after every run, so it needs no clearing between runs.
@external(erlang, "kangaroo_cli_ffi", "event_buffer_append")
@external(javascript, "../kangaroo_cli_ffi.mjs", "event_buffer_append")
pub fn append(event: Event) -> Nil

/// Returns all buffered events in order and clears the buffer.
@external(erlang, "kangaroo_cli_ffi", "event_buffer_take")
@external(javascript, "../kangaroo_cli_ffi.mjs", "event_buffer_take")
pub fn take() -> List(Event)
