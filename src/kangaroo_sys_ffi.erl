%% Small platform services used by the runner: monotonic clock, environment
%% access, and process exit.
-module(kangaroo_sys_ffi).
-export([now_ms/0, env/1, halt/1]).

now_ms() ->
    erlang:monotonic_time(millisecond).

env(Name) when is_binary(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> none;
        Value -> {some, list_to_binary(Value)}
    end.

halt(Code) ->
    erlang:halt(Code).
