-module(kangaroo_fs_ffi).
-export([list_files_recursive/1, list_workspace_files_recursive/1,
         read_file/1, current_dir/0, args/0, halt/1,
         read_line/0, exists/1, write_exclusive/2, replace_if_unchanged/3,
         is_directory/1, sleep/1, remove_file/1, read_line_timeout/1,
         close_input/0, write_stdout_line/1, write_stderr_line/1,
         copy_to_temporary_workspace/1, workspace_entry_excluded/1,
         remove_tree/1, write_file/2]).
-include_lib("kernel/include/file.hrl").

write_stdout_line(Line) ->
    io:put_chars(standard_io, [Line, <<"\n">>]),
    nil.

write_stderr_line(Line) ->
    io:put_chars(standard_error, [Line, <<"\n">>]),
    nil.

list_files_recursive(Directory) ->
    case file:list_dir(Directory) of
        {ok, Entries} ->
            case collect(Directory, Entries, []) of
                {ok, Files} -> {ok, lists:sort(Files)};
                Error -> Error
            end;
        {error, Reason} -> {error, format_error(Reason)}
    end.

list_workspace_files_recursive(Directory) ->
    case file:list_dir(Directory) of
        {ok, Entries} ->
            case collect_workspace(Directory, Entries, []) of
                {ok, Files} -> {ok, lists:sort(Files)};
                Error -> Error
            end;
        {error, Reason} -> {error, format_error(Reason)}
    end.

collect_workspace(_Directory, [], Files) ->
    {ok, Files};
collect_workspace(Directory, [Entry | Rest], Files) ->
    case workspace_entry_excluded(Entry) of
        true -> collect_workspace(Directory, Rest, Files);
        false ->
            Path = filename:join(Directory, Entry),
            case file:read_link_info(Path) of
                {ok, #file_info{type = directory}} ->
                    case list_workspace_files_recursive(Path) of
                        {ok, Children} ->
                            collect_workspace(Directory, Rest,
                                              Children ++ Files);
                        Error -> Error
                    end;
                {ok, #file_info{type = regular}} ->
                    collect_workspace(
                      Directory, Rest,
                      [unicode:characters_to_binary(Path) | Files]);
                {ok, #file_info{type = symlink}} ->
                    collect_workspace(Directory, Rest, Files);
                {ok, _Other} -> collect_workspace(Directory, Rest, Files);
                {error, Reason} -> {error, format_error(Reason)}
            end
    end.

collect(_Directory, [], Files) ->
    {ok, Files};
collect(Directory, [Entry | Rest], Files) ->
    Path = filename:join(Directory, Entry),
    case file:read_file_info(Path) of
        {ok, #file_info{type = directory}} ->
            case list_files_recursive(Path) of
                {ok, Children} -> collect(Directory, Rest, Children ++ Files);
                Error -> Error
            end;
        {ok, #file_info{type = regular}} ->
            collect(Directory, Rest,
                    [unicode:characters_to_binary(Path) | Files]);
        {ok, #file_info{type = symlink}} ->
            %% Symlinks are deliberately not followed during recursive
            %% discovery, preventing directory cycles and root escapes.
            collect(Directory, Rest, Files);
        {error, Reason} ->
            {error, format_error(Reason)}
    end.

read_file(Path) ->
    case file:read_file(Path) of
        {ok, Contents} -> {ok, Contents};
        {error, Reason} -> {error, format_error(Reason)}
    end.

exists(Path) ->
    filelib:is_file(Path).

is_directory(Path) ->
    filelib:is_dir(Path).

sleep(Milliseconds) ->
    timer:sleep(Milliseconds),
    nil.

remove_file(Path) ->
    case file:delete(Path) of
        ok -> {ok, nil};
        {error, enoent} -> {ok, nil};
        {error, Reason} -> {error, format_error(Reason)}
    end.

copy_to_temporary_workspace(ProjectDir) ->
    Source = normalise_absolute(path_to_list(ProjectDir)),
    Parent = filename:dirname(Source),
    Workspace = case make_workspace(Parent, 0) of
        {error, eacces} -> make_workspace(system_temp_dir(), 0);
        {error, erofs} -> make_workspace(system_temp_dir(), 0);
        Result -> Result
    end,
    case Workspace of
        {ok, Destination} ->
            case copy_workspace_directory(Source, Destination) of
                ok -> {ok, unicode:characters_to_binary(Destination)};
                {error, Reason} ->
                    _ = remove_directory(Destination),
                    {error, format_error(Reason)}
            end;
        {error, Reason} -> {error, format_error(Reason)}
    end.

system_temp_dir() ->
    case os:getenv("TMPDIR") of
        false ->
            case os:getenv("TEMP") of
                false -> "/tmp";
                Value -> Value
            end;
        Value -> Value
    end.

make_workspace(_Parent, Attempt) when Attempt >= 100 ->
    {error, eexist};
make_workspace(Parent, Attempt) ->
    Id = integer_to_list(erlang:unique_integer([positive, monotonic])),
    Destination = filename:join(Parent, ".kangaroo-coverage-" ++ Id),
    case file:make_dir(Destination) of
        ok -> {ok, Destination};
        {error, eexist} -> make_workspace(Parent, Attempt + 1);
        Error -> Error
    end.

copy_workspace_directory(Source, Destination) ->
    case file:list_dir(Source) of
        {ok, Entries} -> copy_entries(Source, Destination, Entries, true);
        Error -> Error
    end.

copy_directory(Source, Destination) ->
    case file:list_dir(Source) of
        {ok, Entries} -> copy_entries(Source, Destination, Entries, false);
        Error -> Error
    end.

copy_entries(_Source, _Destination, [], _IncludeDependencyCache) -> ok;
copy_entries(Source, Destination, ["build" | Rest], true) ->
    case copy_dependency_cache(Source, Destination) of
        ok -> copy_entries(Source, Destination, Rest, true);
        Error -> Error
    end;
copy_entries(Source, Destination, [Name | Rest], IncludeDependencyCache) ->
    case workspace_entry_excluded(Name) of
        true -> copy_entries(Source, Destination, Rest,
                             IncludeDependencyCache);
        false ->
            From = filename:join(Source, Name),
            To = filename:join(Destination, Name),
            case file:read_link_info(From) of
                {ok, #file_info{type = directory, mode = Mode}} ->
                    case file:make_dir(To) of
                        ok ->
                            _ = file:change_mode(To, Mode),
                            case copy_directory(From, To) of
                                ok -> copy_entries(Source, Destination, Rest,
                                                   IncludeDependencyCache);
                                Error -> Error
                            end;
                        Error -> Error
                    end;
                {ok, #file_info{type = regular, mode = Mode}} ->
                    case file:copy(From, To) of
                        {ok, _} ->
                            _ = file:change_mode(To, Mode),
                            copy_entries(Source, Destination, Rest,
                                         IncludeDependencyCache);
                        Error -> Error
                    end;
                {ok, #file_info{type = symlink}} ->
                    %% Do not let a coverage clone escape through a source
                    %% tree symlink. The normal discovery walker has the same
                    %% rule.
                    copy_entries(Source, Destination, Rest,
                                 IncludeDependencyCache);
                {ok, _Other} -> copy_entries(Source, Destination, Rest,
                                             IncludeDependencyCache);
                Error -> Error
            end
    end.

copy_dependency_cache(Source, Destination) ->
    FromBuild = filename:join(Source, "build"),
    FromPackages = filename:join(FromBuild, "packages"),
    case file:read_link_info(FromPackages) of
        {ok, #file_info{type = directory, mode = PackagesMode}} ->
            ToBuild = filename:join(Destination, "build"),
            ToPackages = filename:join(ToBuild, "packages"),
            case file:make_dir(ToBuild) of
                ok ->
                    _ = copy_mode(FromBuild, ToBuild),
                    case file:make_dir(ToPackages) of
                        ok ->
                            _ = file:change_mode(ToPackages, PackagesMode),
                            copy_directory(FromPackages, ToPackages);
                        Error -> Error
                    end;
                Error -> Error
            end;
        {ok, _NotDirectory} -> ok;
        {error, enoent} -> ok;
        Error -> Error
    end.

copy_mode(From, To) ->
    case file:read_link_info(From) of
        {ok, #file_info{mode = Mode}} -> file:change_mode(To, Mode);
        Error -> Error
    end.

workspace_entry_excluded(Name) ->
    Value = path_to_list(Name),
    lists:member(Value, [".git", "build", ".kangaroo", ".vscode-test",
                         "coverage", "node_modules"])
        orelse lists:prefix(".kangaroo-coverage-", Value).

remove_tree(Path) ->
    Value = normalise_absolute(path_to_list(Path)),
    case lists:prefix(".kangaroo-coverage-", filename:basename(Value)) of
        false -> {error, <<"refusing to remove a non-coverage workspace">>};
        true ->
            case remove_directory_retry(Value, 0) of
                ok -> {ok, nil};
                {error, enoent} -> {ok, nil};
                {error, Reason} -> {error, format_error(Reason)}
            end
    end.

remove_directory_retry(Path, Attempt) ->
    case remove_directory(Path) of
        {error, Reason}
          when (Reason =:= eperm orelse Reason =:= eacces),
               Attempt < 500 ->
            %% Windows can retain executable and build artefact handles for a
            %% short period after taskkill has returned. Retrying the exact
            %% guarded temporary workspace keeps cleanup deterministic without
            %% broadening what this function is allowed to remove. The ten
            %% second ceiling covers slow hosted Windows filesystem filters.
            timer:sleep(20),
            remove_directory_retry(Path, Attempt + 1);
        Result -> Result
    end.

remove_directory(Path) ->
    remove_directory(Path, 0).

remove_directory(_Path, Attempt) when Attempt >= 50 ->
    {error, eexist};
remove_directory(Path, Attempt) ->
    case file:list_dir(Path) of
        {ok, Entries} ->
            case remove_entries(Path, Entries) of
                ok ->
                    case file:del_dir(Path) of
                        {error, eexist} ->
                            timer:sleep(5),
                            remove_directory(Path, Attempt + 1);
                        {error, enotempty} ->
                            timer:sleep(5),
                            remove_directory(Path, Attempt + 1);
                        Result -> Result
                    end;
                Error -> Error
            end;
        {error, enoent} -> ok;
        Error -> Error
    end.

remove_entries(_Path, []) -> ok;
remove_entries(Path, [Name | Rest]) ->
    Child = filename:join(Path, Name),
    Result = case file:read_link_info(Child) of
        {ok, #file_info{type = directory}} -> remove_directory(Child);
        {ok, _} -> file:delete(Child);
        {error, enoent} -> ok;
        ReadError -> ReadError
    end,
    case Result of
        ok -> remove_entries(Path, Rest);
        RemoveError -> RemoveError
    end.

write_exclusive(Path, Contents) ->
    ok = filelib:ensure_dir(Path),
    case file:open(Path, [write, exclusive, binary]) of
        {ok, Device} ->
            Result = file:write(Device, Contents),
            ok = file:close(Device),
            case Result of
                ok -> {ok, nil};
                {error, Reason} -> {error, format_error(Reason)}
            end;
        {error, Reason} -> {error, format_error(Reason)}
    end.

write_file(Path, Contents) ->
    ok = filelib:ensure_dir(Path),
    case file:write_file(Path, Contents, [binary]) of
        ok -> {ok, nil};
        {error, Reason} -> {error, format_error(Reason)}
    end.

replace_if_unchanged(Path, Expected, Contents) ->
    case file:read_file(Path) of
        {ok, Expected} ->
            Temp = temp_path(Path),
            case file:write_file(Temp, Contents, [binary, exclusive]) of
                ok ->
                    case file:rename(Temp, Path) of
                        ok -> {ok, true};
                        {error, Reason} ->
                            _ = file:delete(Temp),
                            {error, format_error(Reason)}
                    end;
                {error, Reason} -> {error, format_error(Reason)}
            end;
        {ok, _Changed} -> {ok, false};
        {error, Reason} -> {error, format_error(Reason)}
    end.

temp_path(Path) ->
    Suffix = integer_to_binary(erlang:unique_integer([positive, monotonic])),
    <<(unicode:characters_to_binary(Path))/binary,
      ".kangaroo.", Suffix/binary, ".tmp">>.

current_dir() ->
    case file:get_cwd() of
        {ok, Directory} -> {ok, unicode:characters_to_binary(Directory)};
        {error, Reason} -> {error, format_error(Reason)}
    end.

args() ->
    [unicode:characters_to_binary(Arg) || Arg <- init:get_plain_arguments()].

read_line() ->
    case io:get_line(standard_io, "") of
        eof -> none;
        {error, _} -> none;
        Line -> {some, unicode:characters_to_binary(string:trim(Line, trailing))}
    end.

read_line_timeout(Milliseconds) ->
    ensure_input_reader(),
    receive
        {kangaroo_input, {line, Line}} ->
            {input_line, Line};
        {kangaroo_input, eof} ->
            erase(kangaroo_input_reader),
            input_end;
        {'DOWN', Ref, process, _Pid, _Reason} ->
            case get(kangaroo_input_reader) of
                {_Reader, Ref} ->
                    erase(kangaroo_input_reader),
                    input_end;
                _ -> read_line_timeout(0)
            end
    after erlang:max(0, Milliseconds) ->
        input_pending
    end.

close_input() ->
    case erase(kangaroo_input_reader) of
        {Pid, Ref} when is_pid(Pid) ->
            demonitor(Ref, [flush]),
            exit(Pid, kill);
        _ -> ok
    end,
    nil.

ensure_input_reader() ->
    case get(kangaroo_input_reader) of
        {Pid, _Ref} when is_pid(Pid) -> ok;
        _ ->
            Parent = self(),
            {Pid, Ref} = spawn_monitor(fun() -> input_reader(Parent) end),
            put(kangaroo_input_reader, {Pid, Ref}),
            ok
    end.

input_reader(Parent) ->
    case io:get_line(standard_io, "") of
        eof -> Parent ! {kangaroo_input, eof};
        {error, _} -> Parent ! {kangaroo_input, eof};
        Line ->
            Value = string:trim(Line, trailing, "\r\n"),
            Parent ! {kangaroo_input,
                      {line, unicode:characters_to_binary(Value)}},
            input_reader(Parent)
    end.

halt(Code) -> erlang:halt(Code).

format_error(Reason) ->
    unicode:characters_to_binary(io_lib:format("~0p", [Reason])).

path_to_list(Value) when is_binary(Value) -> unicode:characters_to_list(Value);
path_to_list(Value) when is_list(Value) -> Value.

normalise_absolute(Path) ->
    filename:join(normalise_components(filename:split(filename:absname(Path)), [])).

normalise_components([], Acc) -> lists:reverse(Acc);
normalise_components(["." | Rest], Acc) ->
    normalise_components(Rest, Acc);
normalise_components([".." | Rest], [Current | Acc])
  when Current =/= "/" ->
    normalise_components(Rest, Acc);
normalise_components([".." | Rest], Acc) ->
    normalise_components(Rest, Acc);
normalise_components([Part | Rest], Acc) ->
    normalise_components(Rest, [Part | Acc]).
