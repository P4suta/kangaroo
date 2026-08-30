#!/usr/bin/env escript
%%! -noshell

main(_Arguments) ->
    case os:type() of
        {win32, _} ->
            CommandProcessor = require_executable("cmd.exe"),
            Directory = filename:absname("."),
            CommandArguments = ["/D", "/Q", "/C", "exit", "0"],
            Base = [binary, use_stdio, stderr_to_stdout, exit_status,
                    {args, CommandArguments}],
            InternalEnvironment = internal_environment(Directory),
            Results = [
                probe("base", CommandProcessor, Base),
                probe("working directory", CommandProcessor,
                      Base ++ [{cd, Directory}]),
                probe("list environment", CommandProcessor,
                      Base ++ [{env, [{"KANGAROO_PORT_SMOKE", "1"}]}]),
                probe("internal list environment", CommandProcessor,
                      Base ++ [{env, InternalEnvironment}]),
                probe_helper_preparation()
            ],
            case lists:all(fun(Result) -> Result =:= ok end, Results) of
                true -> halt(0);
                false -> halt(1)
            end;
        _ ->
            io:format("Windows open_port smoke test skipped~n"),
            halt(0)
    end.

require_executable(Name) ->
    case os:find_executable(Name) of
        false -> erlang:error({missing_executable, Name});
        Path -> Path
    end.

internal_environment(Directory) ->
    Executable = require_executable("cmd.exe"),
    Arguments = ["/D", "/Q", "/C", "exit", "0"],
    Values = [
        {"EXECUTABLE", Executable},
        {"DIRECTORY", Directory},
        {"ARGV0", Executable},
        {"ARGUMENT_COUNT", integer_to_list(length(Arguments))},
        {"ENVIRONMENT_COUNT", "0"}
    ] ++ [{"ARGUMENT_" ++ lists:flatten(
                         io_lib:format("~6..0B", [Index])), Argument}
          || {Index, Argument} <- lists:enumerate(0, Arguments)],
    [{"__KANGAROO_INTERNAL_WINDOWS_JOB_V1_" ++ Name,
      encoded(Value)} || {Name, Value} <- Values].

encoded(Value) ->
    binary_to_list(base64:encode(unicode:characters_to_binary(Value))).

probe(Label, Executable, Options) ->
    probe(Label, Executable, Options, 5000).

probe(Label, Executable, Options, Timeout) ->
    try open_port({spawn_executable, Executable}, Options) of
        Port ->
            wait_for_exit(
              Label, Port, erlang:monotonic_time(millisecond) + Timeout)
    catch
        Class:Reason:Stack ->
            io:format(
              "open_port ~s: ~tp:~tp ~tp~n",
              [Label, Class, Reason, Stack]),
            error
    end.

wait_for_exit(Label, Port, Deadline) ->
    Remaining = erlang:max(
      0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, _Output}} ->
            wait_for_exit(Label, Port, Deadline);
        {Port, {exit_status, 0}} ->
            io:format("open_port ~s: ok~n", [Label]),
            ok;
        {Port, {exit_status, Code}} ->
            io:format("open_port ~s: exit ~B~n", [Label, Code]),
            error
    after Remaining ->
        safe_close(Port),
        io:format("open_port ~s: timeout~n", [Label]),
        error
    end.

probe_helper_preparation() ->
    PowerShell = require_powershell(),
    Script = filename:absname("priv/kangaroo_windows_job.ps1"),
    Helper = default_helper_path(),
    Probe = filename:join(
      filename:dirname(Script), "kangaroo_windows_prepare_probe.txt"),
    _ = safe_delete(Probe),
    Arguments = [
        "-NoLogo", "-NoProfile", "-NonInteractive",
        "-ExecutionPolicy", "Bypass", "-File", Script,
        "-Prepare", "-ProbePreparation"
    ],
    Result = prepare_helper_path(PowerShell, Arguments, Helper, 60000),
    report_preparation_probe(Probe),
    _ = safe_delete(Probe),
    case Result of
        ok ->
            try
                case filelib:is_regular(Helper) of
                    true ->
                        io:format("open_port helper preparation: ok~n"),
                        io:format("open_port helper artifact: ok~n"),
                        probe(
                          "production helper execution",
                          require_executable("cmd.exe"),
                          [binary, use_stdio, stderr_to_stdout, exit_status,
                           {cd, filename:dirname(Helper)},
                           {args, ["/D", "/Q", "/C",
                                   filename:basename(Helper),
                                   "--kangaroo-job-helper"]},
                           {env, internal_environment(filename:absname("."))}],
                          5000);
                    false ->
                        io:format("open_port helper artifact: missing~n"),
                        error
                end
            after
                safe_delete(Helper)
            end;
        error -> error
    end.

report_preparation_probe(Probe) ->
    case file:read_file(Probe) of
        {ok, Contents} ->
            io:format("open_port helper preparation probe: ~ts~n", [Contents]);
        {error, Reason} ->
            io:format("open_port helper preparation probe: missing (~tp)~n",
                      [Reason])
    end.

prepare_helper_path(PowerShell, Arguments, Helper, Timeout) ->
    case filelib:ensure_dir(Helper) of
        {error, Reason} ->
            io:format("open_port helper cache: ~tp~n", [Reason]),
            error;
        ok ->
            try open_port(
                  {spawn_executable, PowerShell},
                  [binary, use_stdio, stderr_to_stdout, exit_status,
                   {cd, filename:dirname(Helper)},
                   {args, Arguments}]) of
                Port ->
                    wait_for_helper_path(
                      Port, Helper, [],
                      erlang:monotonic_time(millisecond) + Timeout)
            catch
                Class:Reason:Stack ->
                    io:format(
                      "open_port helper preparation: ~tp:~tp ~tp~n",
                      [Class, Reason, Stack]),
                    error
            end
    end.

wait_for_helper_path(Port, Helper, Output, Deadline) ->
    Remaining = erlang:max(
      0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, Data}} ->
            Next = [Data | Output],
            case iolist_size(Next) > 1048576 of
                true ->
                    safe_close(Port),
                    io:format("open_port helper preparation: output limit~n"),
                    error;
                false -> wait_for_helper_path(Port, Helper, Next, Deadline)
            end;
        {Port, {exit_status, 0}} ->
            case filelib:is_regular(Helper) of
                true -> ok;
                false ->
                    io:format(
                      "open_port helper preparation: artifact missing ~ts~n",
                      [iolist_to_binary(lists:reverse(Output))]),
                    error
            end;
        {Port, {exit_status, Code}} ->
            io:format(
              "open_port helper preparation: exit ~B ~ts~n",
              [Code, iolist_to_binary(lists:reverse(Output))]),
            error
    after Remaining ->
        safe_close(Port),
        io:format("open_port helper preparation: timeout~n"),
        error
    end.

default_helper_path() ->
    Temp = first_nonempty_environment(["TEMP", "TMP", "TMPDIR"], "."),
    filename:absname(
      filename:join([Temp, "kangaroo", "windows-job-v6-20260831.exe"])).

first_nonempty_environment([], Fallback) -> Fallback;
first_nonempty_environment([Name | Rest], Fallback) ->
    case os:getenv(Name) of
        false -> first_nonempty_environment(Rest, Fallback);
        Value ->
            case string:trim(Value) of
                [] -> first_nonempty_environment(Rest, Fallback);
                _ -> Value
            end
    end.

require_powershell() ->
    case os:find_executable("powershell.exe") of
        false -> require_executable("pwsh.exe");
        Path -> Path
    end.

safe_delete(Path) ->
    case file:delete(Path) of
        ok -> ok;
        {error, enoent} -> ok;
        {error, _} -> error
    end.

safe_close(Port) ->
    try port_close(Port) of
        true -> ok
    catch
        _:_ -> ok
    end.
