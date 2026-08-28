%% Human-readable representation of a value for failure messages.
%% Strings are shown raw so multi-line diffs work; other values are
%% printed in Erlang term syntax.
-module(kangaroo_print_ffi).
-export([to_string/1]).

to_string(Value) when is_binary(Value) ->
    Value;
to_string(Value) ->
    unicode:characters_to_binary(io_lib:format("~0p", [Value])).
