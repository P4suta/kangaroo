%% Runs a test case body in a freshly spawned process so that panics and
%% stray processes cannot take down the runner, then reports the collected
%% matcher failures (or the error that was raised). The source location of
%% a crash is derived from its stack by the pure `kangaroo@location` module.
-module(kangaroo_isolate_ffi).
-export([isolate/2]).

-define(DEFAULT_TIMEOUT_MS, 30000).

isolate(Body, Timeout) ->
    TimeoutMs = case Timeout of
                    {some, Ms} -> Ms;
                    none -> ?DEFAULT_TIMEOUT_MS
                end,
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
                       error_message(Reason, Stack),
                       error_location(Stack)}}
    after TimeoutMs ->
        exit(Pid, kill),
        {crashed, {caught_error, <<"timeout">>,
                   <<"Test case timed out after ",
                     (integer_to_binary(TimeoutMs))/binary, " ms">>, none}}
    end.

panic_name(#{gleam_error := panic}) ->
    <<"panic">>;
panic_name(_Reason) ->
    <<"error">>.

error_message(#{message := Message}, _Stack) ->
    to_binary(Message);
error_message(Reason, Stack) ->
    to_binary(io_lib:format("~0p ~p", [Reason, Stack])).

error_location(Stack) ->
    kangaroo@location:from_erlang_stack(stack_text(Stack)).

stack_text(Stack) ->
    Lines = [frame_line(F) || F <- Stack],
    NonEmpty = [L || L <- Lines, L =/= <<>>],
    iolist_to_binary(lists:join(<<"\n">>, NonEmpty)).

frame_line({_Module, _Function, _Arity, Info}) when is_list(Info) ->
    case lists:keyfind(file, 1, Info) of
        {file, File} ->
            Line = case lists:keyfind(line, 1, Info) of
                       {line, L} -> L;
                       false -> 1
                   end,
            unicode:characters_to_binary(
                io_lib:format("~ts:~p", [to_binary(File), Line]));
        false ->
            <<>>
    end;
frame_line(_) ->
    <<>>.

to_binary(Value) when is_binary(Value) ->
    Value;
to_binary(Value) when is_list(Value) ->
    unicode:characters_to_binary(Value);
to_binary(Value) ->
    unicode:characters_to_binary(io_lib:format("~0p", [Value])).
