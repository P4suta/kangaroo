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
                      Base ++ [{env, InternalEnvironment}])
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
    try open_port({spawn_executable, Executable}, Options) of
        Port ->
            receive
                {Port, {exit_status, 0}} ->
                    io:format("open_port ~s: ok~n", [Label]),
                    ok;
                {Port, {exit_status, Code}} ->
                    io:format("open_port ~s: exit ~B~n", [Label, Code]),
                    error
            after 5000 ->
                safe_close(Port),
                io:format("open_port ~s: timeout~n", [Label]),
                error
            end
    catch
        Class:Reason:Stack ->
            io:format(
              "open_port ~s: ~tp:~tp ~tp~n",
              [Label, Class, Reason, Stack]),
            error
    end.

safe_close(Port) ->
    try port_close(Port) of
        true -> ok
    catch
        _:_ -> ok
    end.
