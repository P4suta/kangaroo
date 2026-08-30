-module(kangaroo_terminal_ffi).
-export([stdout_is_terminal/0, interactive_terminal/0, dimensions/0,
         with_ui/1, suspend/1, poll_key/0]).

-define(KEYBOARD_READER, kangaroo_keyboard_reader).
-define(KEYBOARD_AWAITING, kangaroo_keyboard_awaiting_continue).

stdout_is_terminal() ->
    case os:type() of
        {win32, _} ->
            case io:columns() of
                {ok, _Columns} -> true;
                _ -> false
            end;
        _ -> terminal_fd(1)
    end.

interactive_terminal() ->
    case os:type() of
        {win32, _} -> stdout_is_terminal();
        _ -> terminal_fd(0) andalso terminal_fd(1)
    end.

dimensions() ->
    Columns = case io:columns() of {ok, C} -> C; _ -> 80 end,
    Rows = case io:rows() of {ok, R} -> R; _ -> 24 end,
    {Columns, Rows}.

with_ui(Body) ->
    case interactive_terminal() of
        false -> Body();
        true ->
            raw_mode(true),
            start_keyboard_reader(),
            try Body()
            after
                stop_keyboard_reader(),
                raw_mode(false)
            end
    end.

suspend(Body) ->
    case interactive_terminal() of
        false -> Body();
        true ->
            stop_keyboard_reader(),
            raw_mode(false),
            try Body()
            after
                raw_mode(true),
                start_keyboard_reader()
            end
    end.

start_keyboard_reader() ->
    case get(?KEYBOARD_READER) of
        undefined ->
            Main = self(),
            {Reader, Ref} = spawn_monitor(fun() -> keyboard_loop(Main) end),
            put(?KEYBOARD_READER, {Reader, Ref}),
            put(?KEYBOARD_AWAITING, false),
            ok;
        _ -> ok
    end.

stop_keyboard_reader() ->
    erase(?KEYBOARD_AWAITING),
    case erase(?KEYBOARD_READER) of
        {Reader, Ref} when is_pid(Reader) ->
            exit(Reader, kill),
            receive
                {'DOWN', Ref, process, Reader, _Reason} -> ok
            after 250 ->
                erlang:demonitor(Ref, [flush])
            end;
        _ -> ok
    end,
    discard_pending_keys().

discard_pending_keys() ->
    receive
        {kangaroo_key, _Char} -> discard_pending_keys()
    after 0 ->
        ok
    end.

raw_mode(true) ->
    io:put_chars("\e[?1049h"),
    case os:type() of
        {win32, _} -> safe_io_options([{echo, false}]);
        _ -> run_stty(["raw", "-echo"])
    end,
    ok;
raw_mode(false) ->
    case os:type() of
        {win32, _} -> safe_io_options([{echo, true}]);
        _ -> run_stty(["sane"])
    end,
    io:put_chars("\e[?1049l"),
    ok.

run_stty(Arguments) ->
    case os:find_executable("stty") of
        false -> false;
        Path -> run_inherited(Path, Arguments)
    end.

terminal_fd(Fd) ->
    case os:find_executable("test") of
        false -> false;
        Path -> run_inherited(Path, ["-t", integer_to_list(Fd)])
    end.

run_inherited(Path, Arguments) ->
    try
        Port = open_port(
                 {spawn_executable, Path},
                 [nouse_stdio, exit_status, {args, Arguments}]),
        receive
            {Port, {exit_status, 0}} -> true;
            {Port, {exit_status, _}} -> false
        after 1000 ->
            try port_close(Port) catch _:_ -> ok end,
            false
        end
    catch
        _:_ -> false
    end.

safe_io_options(Options) ->
    try io:setopts(standard_io, Options)
    catch _:_ -> ok
    end.

keyboard_loop(Main) ->
    case io:get_chars(standard_io, "", 1) of
        eof -> ok;
        {error, _} -> ok;
        [] -> keyboard_loop(Main);
        [Char | _] ->
            Main ! {kangaroo_key, unicode:characters_to_binary([Char])},
            await_keyboard_continue(Main),
            keyboard_loop(Main);
        <<>> -> keyboard_loop(Main);
        Binary when is_binary(Binary) ->
            case unicode:characters_to_list(Binary) of
                [Char | _] ->
                    Main ! {kangaroo_key,
                            unicode:characters_to_binary([Char])},
                    await_keyboard_continue(Main);
                _ -> ok
            end,
            keyboard_loop(Main)
    end.

await_keyboard_continue(Main) ->
    receive
        {kangaroo_keyboard_continue, Main} -> ok
    end.

continue_keyboard_reader() ->
    case {get(?KEYBOARD_AWAITING), get(?KEYBOARD_READER)} of
        {true, {Reader, _Ref}} when is_pid(Reader) ->
            Reader ! {kangaroo_keyboard_continue, self()},
            put(?KEYBOARD_AWAITING, false);
        _ -> ok
    end.

poll_key() ->
    continue_keyboard_reader(),
    receive
        {kangaroo_key, Char} ->
            put(?KEYBOARD_AWAITING, true),
            {some, unicode:characters_to_binary(Char)}
    after 0 ->
        none
    end.
