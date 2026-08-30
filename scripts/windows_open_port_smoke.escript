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
    Values = [
        {"EXECUTABLE", Executable},
        {"DIRECTORY", Directory},
        {"ARGV0", Executable},
        {"ARGUMENT_COUNT", "0"},
        {"ENVIRONMENT_COUNT", "0"}
    ],
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
    PowerShell = require_executable("powershell.exe"),
    Script = filename:absname("priv/kangaroo_windows_job.ps1"),
    CacheDirectory = filename:join(
      temporary_directory(),
      "kangaroo-port-smoke-" ++
      integer_to_list(erlang:unique_integer([positive, monotonic]))),
    case file:make_dir(CacheDirectory) of
        ok ->
            Helper = filename:join(
              CacheDirectory, "windows-job-v5-20260831.exe"),
            Launcher = filename:rootname(Helper) ++ ".cmd",
            Arguments = [
                "-NoLogo", "-NoProfile", "-NonInteractive",
                "-ExecutionPolicy", "Bypass", "-File", Script,
                "-Prepare", "-EncodedHelperPath", encoded(Helper)
            ],
            Result = try
                case probe(
                       "encoded helper preparation", PowerShell,
                       [binary, use_stdio, stderr_to_stdout, exit_status,
                        {args, Arguments}],
                       20000) of
                    ok ->
                        case {filelib:is_regular(Helper),
                              filelib:is_regular(Launcher)} of
                            {true, true} ->
                                io:format(
                                  "open_port helper artifacts: ok~n"),
                                ok;
                            State ->
                                io:format(
                                  "open_port helper artifacts: missing ~tp~n",
                                  [State]),
                                error
                        end;
                    error -> error
                end
            after
                safe_delete(Helper),
                safe_delete(Launcher),
                _ = file:del_dir(CacheDirectory)
            end,
            Result;
        {error, Reason} ->
            io:format(
              "open_port helper cache: ~tp~n", [Reason]),
            error
    end.

temporary_directory() ->
    case os:getenv("TEMP") of
        false ->
            case os:getenv("TMP") of
                false -> ".";
                Value -> Value
            end;
        Value -> Value
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
