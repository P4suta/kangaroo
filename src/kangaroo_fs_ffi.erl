-module(kangaroo_fs_ffi).
-export([list_files_recursive/1, list_workspace_files_recursive/1,
         list_source_files_recursive/1,
         read_file/1, current_dir/0, args/0, halt/1,
         read_line/0, exists/1, write_exclusive/2, replace_if_unchanged/3,
         is_directory/1, sleep/1, remove_file/1, read_line_timeout/1,
         close_input/0, write_stdout/1, write_stdout_line/1,
         write_stderr/1, write_stderr_line/1,
         copy_to_temporary_workspace/1, workspace_entry_excluded/1,
         remove_tree/1, write_file/2, project_file_path/2,
         input_line_until/3]).
-include_lib("kernel/include/file.hrl").
-define(MAX_DAEMON_LINE_BYTES, 1048576).

write_stdout_line(Line) ->
    io:put_chars(standard_io, [Line, <<"\n">>]),
    nil.

write_stdout(Contents) ->
    io:put_chars(standard_io, Contents),
    nil.

write_stderr_line(Line) ->
    io:put_chars(standard_error, [Line, <<"\n">>]),
    nil.

write_stderr(Contents) ->
    io:put_chars(standard_error, Contents),
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
    list_workspace_files_recursive(Directory, true).

list_workspace_files_recursive(Directory, WorkspaceRoot) ->
    case file:list_dir(Directory) of
        {ok, Entries} ->
            PackageRoot = WorkspaceRoot orelse package_root(Directory),
            case collect_workspace(Directory, Entries, [], PackageRoot) of
                {ok, Files} -> {ok, lists:sort(Files)};
                Error -> Error
            end;
        {error, Reason} -> {error, format_error(Reason)}
    end.

list_source_files_recursive(Directory) ->
    case file:list_dir(Directory) of
        {ok, Entries} ->
            case collect_source(Directory, Entries, [],
                                package_root(Directory)) of
                {ok, Files} -> {ok, lists:sort(Files)};
                Error -> Error
            end;
        {error, Reason} -> {error, format_error(Reason)}
    end.

collect_workspace(_Directory, [], Files, _PackageRoot) ->
    {ok, Files};
collect_workspace(Directory, [Entry | Rest], Files, PackageRoot) ->
    case workspace_entry_excluded_at(Entry, PackageRoot) of
        true -> collect_workspace(Directory, Rest, Files, PackageRoot);
        false ->
            Path = filename:join(Directory, Entry),
            case file:read_link_info(Path) of
                {ok, #file_info{type = directory}} ->
                    case list_workspace_files_recursive(Path, false) of
                        {ok, Children} ->
                            collect_workspace(Directory, Rest,
                                              Children ++ Files,
                                              PackageRoot);
                        Error -> Error
                    end;
                {ok, #file_info{type = regular}} ->
                    collect_workspace(
                      Directory, Rest,
                      [unicode:characters_to_binary(Path) | Files],
                      PackageRoot);
                {ok, #file_info{type = symlink}} ->
                    collect_workspace(Directory, Rest, Files, PackageRoot);
                {ok, _Other} ->
                    collect_workspace(Directory, Rest, Files, PackageRoot);
                {error, Reason} -> {error, format_error(Reason)}
            end
    end.

collect_source(_Directory, [], Files, _PackageRoot) ->
    {ok, Files};
collect_source(Directory, [Entry | Rest], Files, PackageRoot) ->
    case workspace_entry_excluded_at(Entry, PackageRoot) of
        true -> collect_source(Directory, Rest, Files, PackageRoot);
        false ->
            Path = filename:join(Directory, Entry),
            case file:read_link_info(Path) of
                {ok, #file_info{type = directory}} ->
                    case file:list_dir(Path) of
                        {ok, Children} ->
                            case collect_source(Path, Children, [],
                                                package_root(Path)) of
                                {ok, Found} ->
                                    collect_source(Directory, Rest,
                                                   Found ++ Files,
                                                   PackageRoot);
                                Error -> Error
                            end;
                        {error, Reason} -> {error, format_error(Reason)}
                    end;
                {ok, #file_info{type = regular}} ->
                    collect_source(
                      Directory, Rest,
                      [unicode:characters_to_binary(Path) | Files],
                      PackageRoot);
                {ok, #file_info{type = symlink}} ->
                    collect_source(Directory, Rest, Files, PackageRoot);
                {ok, _Other} ->
                    collect_source(Directory, Rest, Files, PackageRoot);
                {error, Reason} -> {error, format_error(Reason)}
            end
    end.

collect(_Directory, [], Files) ->
    {ok, Files};
collect(Directory, [Entry | Rest], Files) ->
    Path = filename:join(Directory, Entry),
    case file:read_link_info(Path) of
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
        {ok, _Other} ->
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
                    copy_cleanup_error(
                      Reason, remove_tree(Destination))
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
        ok ->
            case write_workspace_owner(Destination) of
                ok -> {ok, Destination};
                Error ->
                    %% The ownership marker was not committed, so only remove
                    %% the still-empty directory. Recursive deletion is never
                    %% permitted without validated ownership.
                    _ = file:del_dir(Destination),
                    Error
            end;
        {error, eexist} -> make_workspace(Parent, Attempt + 1);
        Error -> Error
    end.

copy_cleanup_error(Reason, {ok, nil}) -> {error, format_error(Reason)};
copy_cleanup_error(Reason, {error, Cleanup}) ->
    {error, <<(format_error(Reason))/binary,
              "\ncould not remove coverage workspace: ", Cleanup/binary>>}.

write_workspace_owner(Destination) ->
    Marker = filename:join(Destination, ".kangaroo-coverage-owner"),
    file:write_file(
      Marker,
      unicode:characters_to_binary(normalise_absolute(Destination)),
      [binary, exclusive]).

copy_workspace_directory(Source, Destination) ->
    case file:list_dir(Source) of
        {ok, Entries} ->
            copy_entries(Source, Destination, Entries, true, true);
        Error -> Error
    end.

copy_directory(Source, Destination, IncludeDependencyCache) ->
    case file:list_dir(Source) of
        {ok, Entries} ->
            copy_entries(Source, Destination, Entries,
                         IncludeDependencyCache, package_root(Source));
        Error -> Error
    end.

copy_entries(_Source, _Destination, [], _IncludeDependencyCache,
             _PackageRoot) -> ok;
copy_entries(Source, Destination, [Name | Rest], IncludeDependencyCache,
             PackageRoot) ->
    case {Name, IncludeDependencyCache, PackageRoot} of
        {"build", true, true} ->
            case copy_dependency_cache(Source, Destination) of
                ok -> copy_entries(Source, Destination, Rest, true,
                                   PackageRoot);
                Error -> Error
            end;
        _ -> copy_entry(Source, Destination, Name, Rest,
                        IncludeDependencyCache, PackageRoot)
    end.

copy_entry(Source, Destination, Name, Rest, IncludeDependencyCache,
           PackageRoot) ->
    case workspace_entry_excluded_at(Name, PackageRoot) of
        true -> copy_entries(Source, Destination, Rest,
                             IncludeDependencyCache, PackageRoot);
        false ->
            From = filename:join(Source, Name),
            To = filename:join(Destination, Name),
            case file:read_link_info(From) of
                {ok, #file_info{type = directory, mode = Mode}} ->
                    case file:make_dir(To) of
                        ok ->
                            _ = file:change_mode(To, Mode),
                            case copy_directory(From, To,
                                                IncludeDependencyCache) of
                                ok -> copy_entries(Source, Destination, Rest,
                                                   IncludeDependencyCache,
                                                   PackageRoot);
                                Error -> Error
                            end;
                        Error -> Error
                    end;
                {ok, #file_info{type = regular, mode = Mode}} ->
                    case file:copy(From, To) of
                        {ok, _} ->
                            _ = file:change_mode(To, Mode),
                            copy_entries(Source, Destination, Rest,
                                         IncludeDependencyCache,
                                         PackageRoot);
                        Error -> Error
                    end;
                {ok, #file_info{type = symlink}} ->
                    %% Do not let a coverage clone escape through a source
                    %% tree symlink. The normal discovery walker has the same
                    %% rule.
                    copy_entries(Source, Destination, Rest,
                                 IncludeDependencyCache, PackageRoot);
                {ok, _Other} -> copy_entries(Source, Destination, Rest,
                                             IncludeDependencyCache,
                                             PackageRoot);
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
                            copy_directory(FromPackages, ToPackages, false);
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
    workspace_entry_excluded_at(Name, true).

workspace_entry_excluded_at(Name, PackageRoot) ->
    Value = path_to_list(Name),
    lists:member(Value, [".git", ".kangaroo", ".vscode-test",
                         "node_modules"])
        orelse (PackageRoot
                andalso lists:member(Value, ["build", "coverage"]))
        orelse lists:prefix(".kangaroo-coverage-", Value).

package_root(Directory) ->
    case file:read_link_info(filename:join(Directory, "gleam.toml")) of
        {ok, #file_info{type = regular}} -> true;
        _ -> false
    end.

remove_tree(Path) ->
    Value = normalise_absolute(path_to_list(Path)),
    case lists:prefix(".kangaroo-coverage-", filename:basename(Value)) of
        false -> {error, <<"refusing to remove a non-coverage workspace">>};
        true ->
            case validate_workspace_owner(Value) of
                missing -> {ok, nil};
                {error, Message} -> {error, Message};
                ok ->
                    case remove_directory(Value) of
                        ok -> {ok, nil};
                        {error, {enoent, _FailedPath}} -> {ok, nil};
                        {error, {Reason, FailedPath}} ->
                            {error, format_remove_error(Reason, FailedPath)}
                    end
            end
    end.

validate_workspace_owner(Path) ->
    Marker = filename:join(Path, ".kangaroo-coverage-owner"),
    case file:read_link_info(Path) of
        {error, enoent} -> missing;
        {ok, #file_info{type = directory}} ->
            case {file:read_link_info(Marker), file:read_file(Marker)} of
                {{ok, #file_info{type = regular}}, {ok, Owner}} ->
                    Expected = unicode:characters_to_binary(Path),
                    case Owner =:= Expected of
                        true -> ok;
                        false -> invalid_workspace_owner()
                    end;
                _ -> invalid_workspace_owner()
            end;
        _ -> invalid_workspace_owner()
    end.

invalid_workspace_owner() ->
    {error, <<"refusing to remove a coverage workspace without its ownership marker">>}.

remove_directory(Path) ->
    remove_directory(Path, 0).

remove_directory(Path, Attempt) when Attempt >= 50 ->
    {error, {eexist, Path}};
remove_directory(Path, Attempt) ->
    case file:list_dir(Path) of
        {ok, Entries} ->
            case remove_entries(Path, Entries) of
                ok ->
                    remove_empty_directory(Path, Attempt, 0);
                Error -> Error
            end;
        {error, enoent} -> ok;
        {error, Reason} -> {error, {Reason, Path}}
    end.

remove_entries(_Path, []) -> ok;
remove_entries(Path, [Name | Rest]) ->
    Child = filename:join(Path, Name),
    Result = case file:read_link_info(Child) of
        {ok, #file_info{type = directory}} -> remove_directory(Child);
        {ok, #file_info{type = symlink}} -> remove_link(Child);
        {ok, _} -> remove_file_entry(Child, 0);
        {error, enoent} -> ok;
        {error, Reason} -> {error, {Reason, Child}}
    end,
    case Result of
        ok -> remove_entries(Path, Rest);
        RemoveError -> RemoveError
    end.

remove_empty_directory(Path, TreeAttempt, AccessAttempt) ->
    case file:del_dir(Path) of
        {error, Reason}
          when (Reason =:= eperm orelse Reason =:= eacces),
               AccessAttempt < 500 ->
            %% Retry the same closed-handle operation. Reopening list_dir/1 on
            %% every attempt can keep an OTP 27 Windows enumeration handle
            %% alive and prevent removal of the directory being observed.
            timer:sleep(20),
            remove_empty_directory(Path, TreeAttempt, AccessAttempt + 1);
        {error, eexist} ->
            timer:sleep(5),
            remove_directory(Path, TreeAttempt + 1);
        {error, enotempty} ->
            timer:sleep(5),
            remove_directory(Path, TreeAttempt + 1);
        ok -> ok;
        {error, Reason} -> {error, {Reason, Path}}
    end.

remove_file_entry(Path, Attempt) ->
    case file:delete(Path) of
        {error, Reason}
          when (Reason =:= eperm orelse Reason =:= eacces), Attempt < 500 ->
            timer:sleep(20),
            remove_file_entry(Path, Attempt + 1);
        ok -> ok;
        {error, Reason} -> {error, {Reason, Path}}
    end.

remove_link(Path) ->
    %% On Windows, directory symlinks are removed with RemoveDirectoryW,
    %% exposed by file:del_dir/1. file:delete/1 maps to DeleteFileW and returns
    %% eperm for the same link. Never recurse here: the target is user source.
    case {os:type(), file:read_file_info(Path)} of
        {{win32, _}, {ok, #file_info{type = directory}}} ->
            remove_directory_link(Path, 0);
        _ ->
            remove_file_entry(Path, 0)
    end.

remove_directory_link(Path, Attempt) ->
    case file:del_dir(Path) of
        {error, Reason}
          when (Reason =:= eperm orelse Reason =:= eacces), Attempt < 500 ->
            timer:sleep(20),
            remove_directory_link(Path, Attempt + 1);
        ok -> ok;
        {error, Reason} -> {error, {Reason, Path}}
    end.

write_exclusive(Path, Contents) ->
    case filelib:ensure_dir(Path) of
        ok -> write_exclusive_file(Path, Contents);
        {error, Reason} -> {error, format_error(Reason)}
    end.

write_exclusive_file(Path, Contents) ->
    case file:open(Path, [write, exclusive, binary]) of
        {ok, Device} ->
            Result = file:write(Device, Contents),
            Close = file:close(Device),
            case {Result, Close} of
                {ok, ok} -> {ok, nil};
                {{error, Reason}, _} -> {error, format_error(Reason)};
                {_, {error, Reason}} -> {error, format_error(Reason)}
            end;
        {error, Reason} -> {error, format_error(Reason)}
    end.

write_file(Path, Contents) ->
    case filelib:ensure_dir(Path) of
        ok ->
            case file:write_file(Path, Contents, [binary]) of
                ok -> {ok, nil};
                {error, Reason} -> {error, format_error(Reason)}
            end;
        {error, Reason} -> {error, format_error(Reason)}
    end.

project_file_path(ProjectDir, RelativePath) ->
    Root = normalise_absolute(path_to_list(ProjectDir)),
    Relative = lists:flatten(
      string:replace(path_to_list(RelativePath), "\\", "/", all)),
    Components = string:split(Relative, "/", all),
    case safe_project_components(Relative, Components) of
        false -> {error, <<"project output path must be a safe relative path">>};
        true ->
            Candidate = normalise_absolute(filename:join([Root | Components])),
            case path_below_root(Root, Candidate) of
                false -> {error, <<"project output path escapes the project directory">>};
                true ->
                    case no_symlink_components(Root, Components) of
                        ok -> {ok, unicode:characters_to_binary(Candidate)};
                        {error, Reason} when is_binary(Reason) -> {error, Reason};
                        {error, Reason} -> {error, format_error(Reason)}
                    end
            end
    end.

safe_project_components(Relative, Components) ->
    Relative =/= []
        andalso filename:pathtype(Relative) =:= relative
        andalso re:run(Relative, "^[A-Za-z]:", [{capture, none}]) =:= nomatch
        andalso lists:all(
          fun(Component) ->
              Component =/= []
                  andalso Component =/= "."
                  andalso Component =/= ".."
          end,
          Components).

path_below_root(Root, Candidate) ->
    RootParts = filename:split(Root),
    CandidateParts = filename:split(Candidate),
    lists:prefix(RootParts, CandidateParts) andalso RootParts =/= CandidateParts.

no_symlink_components(Root, Components) ->
    case file:read_link_info(Root) of
        {ok, #file_info{type = directory}} ->
            no_symlink_components_from(Root, Components);
        {ok, _} -> {error, <<"project directory must be a real directory">>};
        Error -> Error
    end.

no_symlink_components_from(_Current, []) -> ok;
no_symlink_components_from(Current, [Component | Rest]) ->
    Path = filename:join(Current, Component),
    case file:read_link_info(Path) of
        {error, enoent} -> ok;
        {ok, #file_info{type = symlink}} ->
            {error, <<"refusing to write through a symbolic link">>};
        {ok, #file_info{type = directory}} ->
            no_symlink_components_from(Path, Rest);
        {ok, #file_info{type = regular}} when Rest =:= [] -> ok;
        {ok, _} when Rest =:= [] -> ok;
        {ok, _} -> {error, <<"project output parent is not a directory">>};
        Error -> Error
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
            acknowledge_input_reader(),
            {input_line, Line};
        {kangaroo_input, {error, Message}} ->
            acknowledge_input_reader(),
            {input_error, Message};
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

acknowledge_input_reader() ->
    case get(kangaroo_input_reader) of
        {Reader, _Ref} when is_pid(Reader) ->
            Reader ! {kangaroo_input_continue, self()};
        _ -> ok
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
    Request = {get_until, unicode, "", ?MODULE, input_line_until,
               [?MAX_DAEMON_LINE_BYTES]},
    case io:request(standard_io, Request) of
        eof -> Parent ! {kangaroo_input, eof};
        {kangaroo_input_error, Message} ->
            Parent ! {kangaroo_input, {error, Message}},
            await_input_continue(Parent),
            input_reader(Parent);
        {kangaroo_input_line, Line} ->
            Parent ! {kangaroo_input, {line, Line}},
            await_input_continue(Parent),
            input_reader(Parent);
        {error, Reason} ->
            Parent ! {kangaroo_input, {error, format_error(Reason)}}
    end.

await_input_continue(Parent) ->
    receive
        {kangaroo_input_continue, Parent} -> ok
    end.

%% get_until callbacks receive bounded chunks from the IO server. Stop
%% retaining characters as soon as the UTF-8 byte limit is crossed, discard
%% through the terminating newline, and leave any following request in the IO
%% server's buffer. This applies the daemon boundary while data is read rather
%% than after io:get_line/2 has allocated an arbitrarily large line.
input_line_until([], eof, _Limit) ->
    {done, eof, []};
input_line_until({collect, Characters, _Bytes}, eof, _Limit) ->
    {done, {kangaroo_input_line, encode_input_line(Characters)}, []};
input_line_until(discard, eof, _Limit) ->
    {done, overlong_input_error(), []};
input_line_until([], Characters, Limit) ->
    consume_input_characters({collect, [], 0}, Characters, Limit);
input_line_until(State, Characters, Limit) ->
    consume_input_characters(State, Characters, Limit).

consume_input_characters(State, [], _Limit) ->
    {more, State};
consume_input_characters(discard, [$\n | Rest], _Limit) ->
    {done, overlong_input_error(), Rest};
consume_input_characters(discard, [_Character | Rest], Limit) ->
    consume_input_characters(discard, Rest, Limit);
consume_input_characters({collect, Characters, _Bytes}, [$\n | Rest],
                         _Limit) ->
    {done, {kangaroo_input_line, encode_input_line(Characters)}, Rest};
consume_input_characters({collect, Characters, Bytes}, [Character | Rest],
                         Limit) ->
    NextBytes = Bytes + utf8_character_bytes(Character),
    case NextBytes > Limit of
        true -> consume_input_characters(discard, Rest, Limit);
        false ->
            consume_input_characters(
              {collect, [Character | Characters], NextBytes}, Rest, Limit)
    end.

encode_input_line([$\r | Reversed]) ->
    unicode:characters_to_binary(lists:reverse(Reversed));
encode_input_line(Reversed) ->
    unicode:characters_to_binary(lists:reverse(Reversed)).

utf8_character_bytes(Character) when Character =< 16#7F -> 1;
utf8_character_bytes(Character) when Character =< 16#7FF -> 2;
utf8_character_bytes(Character) when Character =< 16#FFFF -> 3;
utf8_character_bytes(_Character) -> 4.

overlong_input_error() ->
    {kangaroo_input_error,
     <<"daemon request line exceeded 1048576 bytes">>}.

halt(Code) -> erlang:halt(Code).

format_error(Reason) ->
    unicode:characters_to_binary(io_lib:format("~0p", [Reason])).

format_remove_error(Reason, Path) ->
    ReasonText = format_error(Reason),
    PathText = unicode:characters_to_binary(Path),
    Details = case file:read_link_info(Path) of
        {ok, #file_info{type = Type, mode = Mode}} ->
            unicode:characters_to_binary(
              io_lib:format(" (type=~0p, mode=~.8B, link=~0p)",
                            [Type, Mode, file:read_link_all(Path)]));
        Missing ->
            unicode:characters_to_binary(
              io_lib:format(" (info=~0p)", [Missing]))
    end,
    <<ReasonText/binary, " while removing ", PathText/binary,
      Details/binary>>.

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
