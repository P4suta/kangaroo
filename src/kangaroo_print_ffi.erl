%% Human-readable representation of a value for failure messages.
%% Strings are shown raw so multi-line diffs work; other values are
%% printed in Erlang term syntax. Long values are truncated so that a
%% single failure cannot flood the terminal.
-module(kangaroo_print_ffi).
-export([to_string/1]).

-define(MAX_CHARS, 1000).

to_string(Value) when is_binary(Value) ->
    truncate(Value);
to_string(Value) ->
    truncate(unicode:characters_to_binary(io_lib:format("~0p", [Value]))).

truncate(Bin) when byte_size(Bin) =< ?MAX_CHARS ->
    Bin;
truncate(Bin) ->
    Head = binary:part(Bin, 0, ?MAX_CHARS),
    More = byte_size(Bin) - ?MAX_CHARS,
    <<Head/binary,
      "\n... (", (integer_to_binary(More))/binary,
      " more characters)">>.
