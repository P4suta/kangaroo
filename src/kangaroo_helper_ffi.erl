-module(kangaroo_helper_ffi).
-export([metadata/1, serial/0, skip/1, fixture/3]).

metadata(_Value) -> nil.

serial() -> nil.

skip(Reason) ->
    erlang:error(#{kangaroo_error => skip, reason => Reason}).

fixture(Setup, Teardown, Body) ->
    case capture(Setup) of
        {error, Class, Reason, Stack} ->
            erlang:raise(Class, Reason, Stack);
        {ok, Resource} ->
            BodyResult = capture(fun() -> Body(Resource) end),
            TeardownResult = capture(fun() -> Teardown(Resource) end),
            combine(BodyResult, TeardownResult)
    end.

capture(Fun) ->
    try {ok, Fun()}
    catch Class:Reason:Stack -> {error, Class, Reason, Stack}
    end.

combine({ok, Value}, {ok, _}) ->
    Value;
combine({error, Class, Reason, Stack}, {ok, _}) ->
    erlang:raise(Class, Reason, Stack);
combine({ok, _}, {error, Class, Reason, Stack}) ->
    erlang:raise(Class, Reason, Stack);
combine({error, _BodyClass, BodyReason, BodyStack},
        {error, _CleanupClass, CleanupReason, CleanupStack}) ->
    Message = iolist_to_binary([
        <<"fixture body failed: ">>, reason_text(BodyReason),
        <<"; teardown failed: ">>, reason_text(CleanupReason)
    ]),
    erlang:error(#{gleam_error => panic,
                   message => Message,
                   body_reason => BodyReason,
                   body_stack => BodyStack,
                   teardown_reason => CleanupReason,
                   teardown_stack => CleanupStack}).

reason_text(#{message := Message}) -> to_binary(Message);
reason_text(Reason) -> to_binary(io_lib:format("~0p", [Reason])).

to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
to_binary(Value) -> unicode:characters_to_binary(io_lib:format("~0p", [Value])).
