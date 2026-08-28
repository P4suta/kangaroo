%% Platform services for the Kangaroo CLI: file access, subprocess
%% execution of `gleam test`, and a monotonic clock for the watch loop.
-module(kangaroo_cli_ffi).
-export([list_files_recursive/1, read_file/1, mtime_ms/1, sleep/1,
         gleam_executable/0, run_gleam_test/3, now_ms/0, current_dir/0,
         halt/1]).
-include_lib("kernel/include/file.hrl").

current_dir() ->
    case file:get_cwd() of
        {ok, Dir} -> {ok, unicode:characters_to_binary(Dir)};
        {error, Reason} -> {error, format_error(Reason)}
    end.

halt(Code) ->
    erlang:halt(Code).

%% Recursively lists all regular files under a directory, as paths relative
%% to it. Returns `{ok, [Path]}` or `{error, Message}`.
list_files_recursive(Directory) ->
    case file:list_dir(Directory) of
        {ok, Entries} ->
            case collect(Directory, Entries) of
                {ok, Files} -> {ok, lists:sort(Files)};
                {error, Reason} -> {error, format_error(Reason)}
            end;
        {error, Reason} ->
            {error, format_error(Reason)}
    end.

collect(Directory, Entries) ->
    lists:foldl(fun(Entry, Acc) ->
                        case Acc of
                            {error, _} -> Acc;
                            {ok, Files} ->
                                Path = filename:join(Directory, Entry),
                                case file:read_file_info(Path) of
                                    {ok, #file_info{type = directory}} ->
                                        case list_files_recursive(Path) of
                                            {ok, Sub} ->
                                                {ok, Files ++ Sub};
                                            {error, Reason} ->
                                                {error, Reason}
                                        end;
                                    {ok, #file_info{type = regular}} ->
                                        {ok, [Path | Files]};
                                    _ ->
                                        Acc
                                end
                        end
                end, {ok, []}, Entries).

read_file(Path) ->
    case file:read_file(Path) of
        {ok, Contents} -> {ok, Contents};
        {error, Reason} -> {error, format_error(Reason)}
    end.

mtime_ms(Path) ->
    case file:read_file_info(Path) of
        {ok, Info} ->
            Mtime = Info#file_info.mtime,
            Seconds = calendar:datetime_to_gregorian_seconds(Mtime),
            {ok, Seconds * 1000};
        {error, Reason} ->
            {error, format_error(Reason)}
    end.

sleep(Ms) ->
    timer:sleep(Ms).

now_ms() ->
    erlang:monotonic_time(millisecond).

gleam_executable() ->
    case os:find_executable("gleam") of
        false -> {error, <<"Could not find the `gleam` executable on PATH">>};
        Path -> {ok, Path}
    end.

%% Runs `gleam test` in the given directory with `KANGAROO_JSON=1` and any
%% extra environment variables, capturing stdout/stderr and the exit code.
run_gleam_test(ProjectDir, ExtraEnv, TimeoutMs) ->
    case os:find_executable("gleam") of
        false ->
            {error, <<"Could not find the `gleam` executable on PATH">>};
        Gleam ->
            Port = open_port({spawn_executable, Gleam},
                             [binary, use_stdio, stderr_to_stdout,
                              exit_status,
                              {cd, ProjectDir},
                              {args, ["test"]},
                              {env, [{"KANGAROO_JSON", "1"} | ExtraEnv]}]),
            collect_output(Port, [], TimeoutMs)
    end.

collect_output(Port, Acc, TimeoutMs) ->
    receive
        {Port, {data, Data}} ->
            collect_output(Port, [Data | Acc], TimeoutMs);
        {Port, {exit_status, Code}} ->
            {ok, {process_result, Code,
                  iolist_to_binary(lists:reverse(Acc))}}
    after TimeoutMs ->
        port_close(Port),
        {error, <<"`gleam test` timed out">>}
    end.

format_error(Reason) ->
    unicode:characters_to_binary(io_lib:format("~0p", [Reason])).
