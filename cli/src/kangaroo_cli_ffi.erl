%% Platform services for the Kangaroo CLI: file access, subprocess
%% execution of `gleam test`, and a monotonic clock for the watch loop.
-module(kangaroo_cli_ffi).
-export([list_files_recursive/1, read_file/1, mtime_ms/1, sleep/1,
         gleam_executable/0, run_gleam_test/3, now_ms/0, current_dir/0,
         args/0, halt/1, is_erlang/0, add_code_path/1, add_project_paths/1,
         load_module/1, call_suites/1, list_test_modules/1, cover_start/0,
         cover_compile_beams/1, cover_analyse/1]).
-include_lib("kernel/include/file.hrl").

is_erlang() ->
    true.

add_code_path(Directory) ->
    code:add_patha(Directory),
    {ok, nil}.

%% Adds every package ebin under the project's build directory to the code
%% path, with the project's own package taking priority.
add_project_paths(ProjectDir) ->
    Base = filename:join([ProjectDir, "build", "dev", "erlang"]),
    case file:list_dir(Base) of
        {error, Reason} ->
            {error, format_error(Reason)};
        {ok, Packages} ->
            lists:foreach(
              fun(P) ->
                      Ebin = filename:join([Base, P, "ebin"]),
                      case filelib:is_dir(Ebin) of
                          true -> code:add_pathz(to_list(Ebin));
                          false -> ok
                      end
              end, Packages),
            case package_name(ProjectDir) of
                {ok, Name} ->
                    Own = filename:join([Base, Name, "ebin"]),
                    code:add_patha(to_list(Own));
                {error, _} ->
                    ok
            end,
            {ok, nil}
    end.

load_module(Name) ->
    Atom = module_atom(Name),
    case code:purge(Atom) of
        _ ->
            case code:load_file(Atom) of
                {module, Atom} -> {ok, nil};
                {error, Reason} -> {error, format_error(Reason)};
                Error -> {error, format_error(Error)}
            end
    end.

call_suites(Module) ->
    Atom = module_atom(Module),
    case erlang:function_exported(Atom, suites, 0) of
        false ->
            {error, <<"module does not export a `suites` function: ",
                      Module/binary>>};
        true ->
            {ok, erlang:apply(Atom, suites, [])}
    end.

list_test_modules(ProjectDir) ->
    case package_name(ProjectDir) of
        {error, Reason} -> {error, Reason};
        {ok, Name} ->
            Ebin = filename:join([ProjectDir, "build", "dev", "erlang", Name,
                                  "ebin"]),
            case file:list_dir(Ebin) of
                {ok, Entries} ->
                    Tests = [module_of(F)
                             || F <- Entries,
                                lists:suffix("_test.beam", F)],
                    {ok, lists:sort(Tests)};
                {error, Reason2} ->
                    {error, format_error(Reason2)}
            end
    end.

module_of(FileName) ->
    Base = lists:sublist(FileName, length(FileName) - 5),
    list_to_binary(string:replace(Base, "@", "/", all)).

package_name(ProjectDir) ->
    Path = filename:join(ProjectDir, "gleam.toml"),
    case file:read_file(Path) of
        {error, Reason} -> {error, format_error(Reason)};
        {ok, Contents} ->
            Lines = binary:split(Contents, <<"\n">>, [global]),
            case find_name(Lines) of
                {ok, Name} -> {ok, Name};
                error -> {error, <<"no package name in gleam.toml">>}
            end
    end.

find_name([]) ->
    error;
find_name([Line | Rest]) ->
    Trimmed = string:trim(Line),
    case binary:split(Trimmed, <<"=">>) of
        [Key, Value] ->
            case string:trim(Key) of
                <<"name">> -> {ok, strip_quotes(string:trim(Value))};
                _ -> find_name(Rest)
            end;
        _ ->
            find_name(Rest)
    end.

strip_quotes(Value) ->
    case binary:split(Value, <<"\"">>, [global]) of
        [<<>>, Core, <<>>] -> Core;
        _ -> Value
    end.

module_atom(Name) when is_binary(Name) ->
    binary_to_atom(binary:replace(Name, <<"/">>, <<"@">>, [global])).

%% Coverage support. Instruments every beam in the project's ebin directory
%% with the `cover` tool, so that subsequent in-VM runs record line hits.

cover_start() ->
    case cover:start() of
        {ok, _Pid} -> {ok, nil};
        {error, {already_started, _}} -> {ok, nil};
        {error, Reason} -> {error, format_error(Reason)}
    end.

cover_compile_beams(EbinDir) ->
    case file:list_dir(EbinDir) of
        {error, Reason} ->
            {error, format_error(Reason)};
        {ok, Entries} ->
            Beams = [filename:join(EbinDir, F)
                     || F <- Entries, lists:suffix(".beam", F)],
            case compile_beams(Beams) of
                ok -> {ok, nil};
                {error, _} = Error -> Error
            end
    end.

compile_beams([]) ->
    ok;
compile_beams([Beam | Rest]) ->
    case cover:compile_beam(to_list(Beam)) of
        {ok, _Mod} -> compile_beams(Rest);
        {ok, _Mod} -> compile_beams(Rest);
        {error, Reason} -> {error, format_error(Reason)};
        Other -> {error, format_error(Other)}
    end.

cover_analyse(Module) ->
    Mod = module_atom(Module),
    case cover:analyse(Mod, coverage, line) of
        {ok, Hits} ->
            {ok, [{Line, Count} || {{_M, Line}, Count} <- Hits]};
        {error, Reason} ->
            {error, format_error(Reason)}
    end.

current_dir() ->
    case file:get_cwd() of
        {ok, Dir} -> {ok, unicode:characters_to_binary(Dir)};
        {error, Reason} -> {error, format_error(Reason)}
    end.

args() ->
    [unicode:characters_to_binary(A) || A <- init:get_plain_arguments()].

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
            Env = [{"KANGAROO_JSON", "1"}
                   | [{to_list(K), to_list(V)} || {K, V} <- ExtraEnv]],
            Port = open_port({spawn_executable, Gleam},
                             [binary, use_stdio, stderr_to_stdout,
                              exit_status,
                              {cd, ProjectDir},
                              {args, ["test"]},
                              {env, Env}]),
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

to_list(Value) when is_binary(Value) ->
    binary_to_list(Value);
to_list(Value) when is_list(Value) ->
    Value;
to_list(Value) ->
    binary_to_list(unicode:characters_to_binary(io_lib:format("~0p", [Value]))).

format_error(Reason) ->
    unicode:characters_to_binary(io_lib:format("~0p", [Reason])).
