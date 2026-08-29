-module(kangaroo_terminal_ffi).
-export([stdout_is_terminal/0, interactive_terminal/0, dimensions/0,
         with_ui/1, suspend/1, poll_key/0]).

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
            Main = self(),
            Reader = spawn(fun() -> keyboard_loop(Main) end),
            try Body()
            after
                exit(Reader, kill),
                raw_mode(false)
            end
    end.

suspend(Body) ->
    case interactive_terminal() of
        false -> Body();
        true ->
            raw_mode(false),
            try Body()
            after raw_mode(true)
            end
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
            Main ! {kangaroo_key, Char},
            keyboard_loop(Main);
        <<>> -> keyboard_loop(Main);
        <<Char, _/binary>> ->
            Main ! {kangaroo_key, Char},
            keyboard_loop(Main)
    end.

poll_key() ->
    receive
        {kangaroo_key, Char} ->
            {some, unicode:characters_to_binary([Char])}
    after 0 ->
        none
    end.
