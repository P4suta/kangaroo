-module(kangaroo_event_buffer_ffi).
-export([append/1, take/0, append_batch/1, take_batch/0]).

-define(KEY, kangaroo_scheduled_events).
-define(BATCH_KEY, kangaroo_batch_events).

append(Event) ->
    Existing = case get(?KEY) of undefined -> []; Events -> Events end,
    put(?KEY, [Event | Existing]),
    nil.

take() ->
    Events = case get(?KEY) of
                 undefined -> [];
                 Existing -> lists:reverse(Existing)
             end,
    erase(?KEY),
    Events.

append_batch(Event) ->
    Existing = case get(?BATCH_KEY) of undefined -> []; Events -> Events end,
    put(?BATCH_KEY, [Event | Existing]),
    nil.

take_batch() ->
    Events = case get(?BATCH_KEY) of
                 undefined -> [];
                 Existing -> lists:reverse(Existing)
             end,
    erase(?BATCH_KEY),
    Events.
