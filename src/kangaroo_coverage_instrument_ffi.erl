-module(kangaroo_coverage_instrument_ffi).
-export([insert_at_offset/3, line_at_offset/2]).

insert_at_offset(Source, Position, Insertion) ->
    Safe = erlang:max(0, erlang:min(Position, byte_size(Source))),
    <<Before:Safe/binary, After/binary>> = Source,
    <<Before/binary, Insertion/binary, After/binary>>.

line_at_offset(Source, Position) ->
    Safe = erlang:max(0, erlang:min(Position, byte_size(Source))),
    Prefix = binary:part(Source, 0, Safe),
    length(binary:matches(Prefix, <<"\n">>)) + 1.
