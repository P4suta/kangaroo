%% Platform services for the Kangaroo CLI: file access, subprocess
%% execution of `gleam test`, and a monotonic clock for the watch loop.
-module(kangaroo_cli_ffi).
-export([list_files_recursive/1, list_directory/1, read_file/1, mtime_ms/1,
         file_size/1, exists/1, sleep/1, gleam_executable/0,
         run_gleam_test/3, now_ms/0, current_dir/0, args/0, halt/1,
         is_erlang/0, add_code_path/1, add_project_paths/1, load_module/1,
         call_suites/1, list_test_modules/1, cover_start/0,
         cover_compile_beams/1, cover_analyse/1, event_buffer_append/1,
         event_buffer_take/0, is_tty/0, raw_mode/1, init_keyboard/0,
         poll_key/0, run_gleam_test_with/4, remove_dir/1,
         run_all_in_process/1]).
-include_lib("kernel/include/file.hrl").

is_erlang() ->
    true.

%% Runs each function in a fresh process and collects the results in
%% order, so the work runs in parallel across BEAM schedulers.
run_all_in_process(Funs) ->
    Parent = self(),
    Pids = [spawn(fun() ->
                          try
                              Parent ! {self(), {ok, F()}}
                          catch
                              Class:Reason:Stack ->
                                  Parent ! {self(), {crash, Class, Reason, Stack}}
                          end
                  end) || F <- Funs],
    collect_workers(Pids, []).

collect_workers([], Acc) ->
    lists:reverse(Acc);
collect_workers([Pid | Rest], Acc) ->
    receive
        {Pid, {ok, Result}} ->
            collect_workers(Rest, [Result | Acc]);
        {Pid, {crash, Class, Reason, Stack}} ->
            io:format(standard_error,
                      "worker ~p crashed: ~p:~p~n  ~p~n",
                      [Pid, Class, Reason, Stack]),
            erlang:raise(Class, Reason, Stack)
    after 60000 ->
        io:format(standard_error, "worker ~p timed out~n", [Pid]),
        io:format(standard_error, "  current: ~p~n",
                  [process_info(Pid, current_function)]),
        io:format(standard_error, "  stack: ~p~n",
                  [process_info(Pid, current_stacktrace)]),
        [io:format(standard_error, "  other ~p: ~p~n",
                   [Other, process_info(Other, current_function)])
         || Other <- [Pid | Rest]],
        exit(Pid, kill),
        erlang:error(timeout)
    end.

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

%% Loads a compiled module (by name, e.g. "foo_test" or "a/b"), replacing
%% any previous version. Loading the same version is a no-op, so
%% concurrent in-VM runs that reload the same modules do not race. When
%% the module has a live old version (e.g. cover re-instrumented it) the
%% load reports not_purged; the old version is then purged and the load
%% retried.
load_module(Name) ->
    Atom = module_atom(Name),
    case code:load_file(Atom) of
        {module, Atom} ->
            {ok, nil};
        {error, not_purged} ->
            _ = code:purge(Atom),
            case code:load_file(Atom) of
                {module, Atom} -> {ok, nil};
                Other -> {error, format_error(Other)}
            end;
        {error, Reason} ->
            {error, format_error(Reason)};
        Other ->
            {error, format_error(Other)}
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
            Ebin0 = filename:join([ProjectDir, "build", "dev", "erlang",
                                   to_list(Name), "ebin"]),
            %% beam_lib requires a string path; keep it a list even when the
            %% input components are binaries.
            Ebin = unicode:characters_to_list(Ebin0),
            case file:list_dir(Ebin) of
                {ok, Entries} ->
                    Beams = [filename:join(Ebin, F)
                             || F <- Entries,
                                lists:suffix("_test.beam", F)],
                    Tests = [module_of(filename:basename(B))
                             || B <- Beams, exports_suites(B)],
                    {ok, lists:sort(Tests)};
                {error, Reason2} ->
                    {error, format_error(Reason2)}
            end
    end.

%% Only modules that actually export a `suites` function are runnable test
%% modules. Gleam can emit empty stub modules for names it knows without
%% sources, and loading one would purge the real module from the VM.
exports_suites(BeamPath) ->

    case beam_lib:chunks(BeamPath, [exports]) of
        {ok, {_, [{exports, Exports}]}} ->
            R = lists:keymember(suites, 1, Exports),

            R;
        _ ->

            false
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

%% Lists the entries of a directory as `{Name, IsDirectory}` pairs. The
%% entry names are converted to binaries: `file:list_dir/1` always returns
%% string lists, even for binary input paths.
list_directory(Directory) ->
    case file:list_dir(Directory) of
        {ok, Entries} ->
            Entries2 = lists:map(fun(Name) ->
                                         Path = filename:join(Directory, Name),
                                         {unicode:characters_to_binary(Name),
                                          filelib:is_dir(Path)}
                                 end, Entries),
            {ok, Entries2};
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

file_size(Path) ->
    case file:read_file_info(Path) of
        {ok, Info} ->
            {ok, Info#file_info.size};
        {error, Reason} ->
            {error, format_error(Reason)}
    end.

exists(Path) ->
    filelib:is_file(Path).

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
    run_gleam_test_with(ProjectDir, ["test"], ExtraEnv, TimeoutMs).

run_gleam_test_with(ProjectDir, Args, ExtraEnv, TimeoutMs) ->
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
                              {args, [to_list(A) || A <- Args]},
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

%% A per-run buffer of runner events, stored in the process dictionary of
%% the CLI process.
-define(EVENT_KEY, kangaroo_events).

event_buffer_append(Event) ->
    Existing = case get(?EVENT_KEY) of
                   undefined -> [];
                   Events -> Events
               end,
    put(?EVENT_KEY, [Event | Existing]),
    ok.

event_buffer_take() ->
    Events = case get(?EVENT_KEY) of
                 undefined -> [];
                 Existing -> lists:reverse(Existing)
             end,
    erase(?EVENT_KEY),
    Events.

%% Terminal access for the TUI.

is_tty() ->
    %% On Linux the VM's own stdout can be inspected directly; the shell
    %% fallback covers platforms without /proc.
    case file:read_link("/proc/self/fd/1") of
        {ok, Target} -> is_tty_target(Target);
        _ -> string:trim(os:cmd("test -t 1 && echo tty")) =:= "tty"
    end.

is_tty_target("/dev/tty") ->
    true;
is_tty_target("/dev/console") ->
    true;
is_tty_target(<<"/dev/pts/", _/binary>>) ->
    true;
is_tty_target(<<"/dev/pty/", _/binary>>) ->
    true;
is_tty_target(Other) when is_list(Other) ->
    is_tty_target(unicode:characters_to_binary(Other));
is_tty_target(_) ->
    false.

raw_mode(True) ->
    %% Raw mode disables ISIG, so Ctrl+C arrives as a byte (0x03) that the
    %% key reader turns into a quit, letting us restore the terminal first.
    %% The os:cmd shell has no controlling terminal of its own, so the tty
    %% must be addressed explicitly.
    os:cmd("stty raw < /dev/tty"),
    ok;
raw_mode(False) ->
    os:cmd("stty sane < /dev/tty"),
    ok.

init_keyboard() ->
    Main = self(),
    spawn(fun() -> keyboard_loop(Main) end),
    ok.

keyboard_loop(Main) ->
    case io:get_chars(standard_io, "", 1) of
        eof ->
            ok;
        {error, _Reason} ->
            ok;
        Chars when is_list(Chars) ->
            case Chars of
                [] ->
                    keyboard_loop(Main);
                [Char | _] ->
                    Main ! {kangaroo_key, Char},
                    keyboard_loop(Main)
            end;
        Bin when is_binary(Bin) ->
            case Bin of
                <<>> ->
                    keyboard_loop(Main);
                <<Char, _/binary>> ->
                    Main ! {kangaroo_key, Char},
                    keyboard_loop(Main)
            end
    end.

poll_key() ->
    receive
        {kangaroo_key, Char} ->
            {some, unicode:characters_to_binary([Char])}
    after 0 ->
        none
    end.

remove_dir(Path) ->
    case file:del_dir_r(Path) of
        ok -> {ok, nil};
        {error, enoent} -> {ok, nil};
        {error, Reason} -> {error, format_error(Reason)}
    end.

format_error(Reason) ->
    unicode:characters_to_binary(io_lib:format("~0p", [Reason])).
