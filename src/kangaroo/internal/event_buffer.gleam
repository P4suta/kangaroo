import kangaroo/event.{type Event}

/// Process-local on BEAM and turn-local on JavaScript. Scheduled workers use
/// it to return an ordered event batch without writing to the shared sink.
@external(erlang, "kangaroo_event_buffer_ffi", "append")
@external(javascript, "../../kangaroo_event_buffer_ffi.mjs", "append")
pub fn append(event: Event) -> Nil

@external(erlang, "kangaroo_event_buffer_ffi", "take")
@external(javascript, "../../kangaroo_event_buffer_ffi.mjs", "take")
pub fn take() -> List(Event)

@external(erlang, "kangaroo_event_buffer_ffi", "append_batch")
@external(javascript, "../../kangaroo_event_buffer_ffi.mjs", "append_batch")
pub fn append_batch(event: Event) -> Nil

@external(erlang, "kangaroo_event_buffer_ffi", "take_batch")
@external(javascript, "../../kangaroo_event_buffer_ffi.mjs", "take_batch")
pub fn take_batch() -> List(Event)
