%% Test-only stdout capture. The CLI is synchronous, so capturing what the
%% current process writes to stdout while a run happens in the same VM comes
%% down to replacing its group leader with this io service: gleam/io writes
%% are requests to the group leader, and the collector answers every request
%% while accumulating the written chunks. Tests use it to assert that the
%% JSON protocol stream is the only thing ever written to stdout.
-module(kangaroo_cli_test_ffi).
-export([capture_stdout/1]).

capture_stdout(Fun) ->
    Parent = self(),
    Collector = spawn(fun() -> collector(Parent, []) end),
    Old = group_leader(),
    group_leader(Collector, self()),
    try
        _ = Fun(),
        group_leader(Old, self()),
        Collector ! done,
        receive
            {captured, Chunks} ->
                unicode:characters_to_binary(lists:reverse(Chunks))
        end
    catch
        Class:Reason ->
            group_leader(Old, self()),
            Collector ! done,
            receive
                {captured, _} -> ok
            end,
            erlang:raise(Class, Reason, [])
    end.

collector(Parent, Acc) ->
    receive
        done ->
            Parent ! {captured, Acc};
        {io_request, From, ReplyAs, Request} ->
            From ! {io_reply, ReplyAs, reply(Request)},
            collector(Parent, accumulate(Request, Acc))
    end.

reply({put_chars, _, _}) -> ok;
reply({put_chars, _, _, _, _}) -> ok;
reply({get_line, _, _}) -> eof;
reply({get_chars, _, _, _}) -> eof;
reply({get_until, _, _, _}) -> eof;
reply({get_geometry, _}) -> {error, einval};
reply(_) -> ok.

accumulate({put_chars, _, Chars}, Acc) when is_binary(Chars) ->
    [Chars | Acc];
accumulate({put_chars, _, Chars}, Acc) ->
    [unicode:characters_to_binary(Chars) | Acc];
accumulate({put_chars, _, Mod, Fun, Args}, Acc) ->
    try [unicode:characters_to_binary(apply(Mod, Fun, Args)) | Acc]
    catch
        _:_ -> Acc
    end;
accumulate(_, Acc) ->
    Acc.
