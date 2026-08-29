import kangaroo/event.{type Event}
import kangaroo_cli/session.{type SessionEvent}

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

/// A per-run buffer of session events (compile phases), kept separate
/// from the runner events.
@external(erlang, "kangaroo_cli_ffi", "event_buffer_append_session")
@external(javascript, "../kangaroo_cli_ffi.mjs", "event_buffer_append_session")
pub fn append_session(event: SessionEvent) -> Nil

/// Returns all buffered session events in order and clears the buffer.
@external(erlang, "kangaroo_cli_ffi", "event_buffer_take_session")
@external(javascript, "../kangaroo_cli_ffi.mjs", "event_buffer_take_session")
pub fn take_session() -> List(SessionEvent)
