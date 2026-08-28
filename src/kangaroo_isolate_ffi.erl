%% Runs a test case body in a freshly spawned process so that panics and
%% stray processes cannot take down the runner, then reports the collected
%% matcher failures (or the error that was raised).
-module(kangaroo_isolate_ffi).
-export([isolate/1]).

-define(TIMEOUT_MS, 30000).

isolate(Body) ->
    Parent = self(),
    Pid = spawn(fun() ->
                        try
                            Body(),
                            Parent ! {kangaroo_done,
                                      kangaroo_context_ffi:collect()}
                        catch
                            Class:Reason:Stack ->
                                Parent ! {kangaroo_crashed, Class, Reason,
                                          Stack}
                        end
                end),
    receive
        {kangaroo_done, Failures} ->
            {completed, Failures};
        {kangaroo_crashed, _Class, Reason, Stack} ->
            {crashed, {caught_error, panic_name(Reason),
                       error_message(Reason, Stack)}}
    after ?TIMEOUT_MS ->
        exit(Pid, kill),
        {crashed, {caught_error, <<"timeout">>,
                   <<"Test case timed out after 30 seconds">>}}
    end.

panic_name(#{gleam_error := panic}) ->
    <<"panic">>;
panic_name(_Reason) ->
    <<"error">>.

error_message(#{message := Message}, _Stack) ->
    to_binary(Message);
error_message(Reason, Stack) ->
    to_binary(io_lib:format("~0p ~p", [Reason, Stack])).

to_binary(Value) when is_binary(Value) ->
    Value;
to_binary(Value) when is_list(Value) ->
    unicode:characters_to_binary(Value);
to_binary(Value) ->
    unicode:characters_to_binary(io_lib:format("~0p", [Value])).
