-module(kangaroo_process_ffi).
-export([run/5, run_inherited/5, start/5, start_streaming/5, poll/1, cancel/1, write/2,
         terminate_port/1, internal_windows_job_name/1]).
-define(MAX_OUTPUT_BYTES, 16777216).
-define(WINDOWS_JOB_PREFIX, "__KANGAROO_INTERNAL_WINDOWS_JOB_V1_").

start(Directory, Executable, Arguments, Environment, TimeoutMs) ->
    start_with_mode(Directory, Executable, Arguments, Environment, TimeoutMs,
                    false).

start_streaming(Directory, Executable, Arguments, Environment, TimeoutMs) ->
    start_with_mode(Directory, Executable, Arguments, Environment, TimeoutMs,
                    true).

start_with_mode(Directory, Executable, Arguments, Environment, TimeoutMs,
                Streaming) ->
    case executable_path(Executable) of
        {error, _} = Error -> Error;
        {ok, Path} ->
            case ensure_windows_job_helper() of
                {error, _} = Error -> Error;
                ok ->
                    Id = erlang:unique_integer([positive, monotonic]),
                    Parent = self(),
                    Pid = spawn(fun() ->
                        async_run(Parent, Id, Directory, Path, Arguments,
                                  Environment, TimeoutMs, Streaming)
                    end),
                    put({kangaroo_process, Id}, {Pid, Streaming}),
                    {ok, Id}
            end
    end.

poll(Id) ->
    receive
        {kangaroo_process, Id, {output, Output}} ->
            acknowledge_output(Id, Output),
            {process_output, Output};
        {kangaroo_process, Id, {finished, Result}} ->
            erase({kangaroo_process, Id}),
            {process_finished, Result};
        {kangaroo_process, Id, cancelled} ->
            erase({kangaroo_process, Id}),
            process_cancelled;
        {kangaroo_process, Id, {failed, Message}} ->
            erase({kangaroo_process, Id}),
            {process_failed, Message}
    after 0 ->
        case get({kangaroo_process, Id}) of
            undefined -> {process_failed, <<"unknown process handle">>};
            _ -> process_running
        end
    end.

cancel(Id) ->
    case get({kangaroo_process, Id}) of
        undefined -> ok;
        {Pid, _Streaming} -> Pid ! cancel
    end,
    nil.

write(Id, Input) ->
    case get({kangaroo_process, Id}) of
        undefined -> ok;
        {Pid, _Streaming} -> Pid ! {input, Input}
    end,
    nil.

run(Directory, Executable, Arguments, Environment, TimeoutMs) ->
    case executable_path(Executable) of
        {error, _} = Error -> Error;
        {ok, Path} ->
            case ensure_windows_job_helper() of
                {error, _} = Error -> Error;
                ok -> run_captured_port(
                        Directory, Path, Arguments, Environment, TimeoutMs)
            end
    end.

run_captured_port(Directory, Path, Arguments, Environment, TimeoutMs) ->
    try open_process_port(Directory, Path, Arguments, Environment, captured) of
        Port ->
            try
                OsPid = port_os_pid(Port),
                Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
                collect(Port, OsPid, [], <<>>, 0, Deadline)
            catch
                Class:Reason:Stack ->
                    safe_close_port(Port),
                    {error, format_exception(Class, Reason, Stack)}
            end
    catch
        Class:Reason:Stack -> {error, format_exception(Class, Reason, Stack)}
    end.

run_inherited(Directory, Executable, Arguments, Environment, TimeoutMs) ->
    case executable_path(Executable) of
        {error, _} = Error -> Error;
        {ok, Path} ->
            case ensure_windows_job_helper() of
                {error, _} = Error -> Error;
                ok -> run_inherited_port(
                        Directory, Path, Arguments, Environment, TimeoutMs)
            end
    end.

run_inherited_port(Directory, Path, Arguments, Environment, TimeoutMs) ->
    try open_process_port(Directory, Path, Arguments, Environment, inherited) of
        Port ->
            try
                OsPid = port_os_pid(Port),
                Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
                collect_inherited(Port, OsPid, Deadline)
            catch
                Class:Reason:Stack ->
                    safe_close_port(Port),
                    {error, format_exception(Class, Reason, Stack)}
            end
    catch
        Class:Reason:Stack -> {error, format_exception(Class, Reason, Stack)}
    end.

collect_inherited(Port, OsPid, Deadline) ->
    Remaining = erlang:max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {exit_status, Code}} ->
            terminate_remaining_process_group(OsPid),
            {ok, {process_result, Code, <<>>}};
        {Port, {data, _Data}} ->
            collect_inherited(Port, OsPid, Deadline)
    after Remaining ->
        close_port(Port),
        {error, <<"process timed out">>}
    end.

acknowledge_output(Id, Output) ->
    case get({kangaroo_process, Id}) of
        {Pid, true} -> Pid ! {consumed, byte_size(Output)};
        _ -> ok
    end.

async_run(Parent, Id, Directory, Path, Arguments, Environment, TimeoutMs,
          Streaming) ->
    process_flag(trap_exit, true),
    try open_process_port(Directory, Path, Arguments, Environment, captured) of
        Port -> async_run_port(Parent, Id, Port, TimeoutMs, Streaming)
    catch
        Class:Reason:Stack ->
            Parent ! {kangaroo_process, Id,
                      {failed, format_exception(Class, Reason, Stack)}}
    end.

async_run_port(Parent, Id, Port, TimeoutMs, Streaming) ->
    try
        OsPid = port_os_pid(Port),
        Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
        async_collect(Parent, Id, Port, OsPid, [], <<>>, 0, Deadline,
                      Streaming)
    catch
        Class:Reason:Stack ->
            safe_close_port(Port),
            Parent ! {kangaroo_process, Id,
                      {failed, format_exception(Class, Reason, Stack)}}
    end.

open_process_port(Directory, Path, Arguments, Environment, Mode) ->
    {LaunchDirectory, LaunchPath, LaunchArguments, LaunchEnvironment} =
        process_launch(Directory, Path, Arguments, Environment),
    Stdio = case Mode of
        captured -> [binary, use_stdio, stderr_to_stdout];
        inherited -> [nouse_stdio]
    end,
    open_port(
      {spawn_executable, LaunchPath},
      Stdio ++ [exit_status,
                {cd, to_list(LaunchDirectory)},
                {args, [to_list(Argument)
                        || Argument <- LaunchArguments]},
                {env, [port_environment_pair(Pair)
                       || Pair <- LaunchEnvironment]}]).

port_environment_pair({Key, false}) -> {to_list(Key), false};
port_environment_pair({Key, Value}) -> {to_list(Key), to_list(Value)}.

process_launch(Directory, Path, Arguments, Environment) ->
    case os:type() of
        {win32, _} ->
            windows_job_launch(Directory, Path, Arguments, Environment);
        _ -> {Directory, Path, Arguments, Environment}
    end.

windows_job_launch(Directory, Path, Arguments, Environment) ->
    Launcher = windows_job_launcher(),
    {ok, CommandProcessor} = windows_command_processor(),
    WorkingDirectory = filename:absname(to_list(Directory)),
    CleanEnvironment = [
        {Key, Value} || {Key, Value} <- Environment,
        not internal_windows_job_name(Key)
    ],
    ArgumentEnvironment = lists:zipwith(fun(Index, Argument) ->
        Name = ?WINDOWS_JOB_PREFIX ++ "ARGUMENT_" ++
               lists:flatten(io_lib:format("~6..0B", [Index])),
        {Name, encode_windows_job_value(Argument)}
    end, lists:seq(0, length(Arguments) - 1), Arguments),
    EnvironmentEnvironment = lists:flatmap(fun({Index, {Key, Value}}) ->
        Suffix = lists:flatten(io_lib:format("~6..0B", [Index])),
        [
            {?WINDOWS_JOB_PREFIX ++ "ENVIRONMENT_NAME_" ++ Suffix,
             encode_windows_job_value(Key)},
            {?WINDOWS_JOB_PREFIX ++ "ENVIRONMENT_VALUE_" ++ Suffix,
             encode_windows_job_value(Value)}
        ]
    end, lists:enumerate(0, CleanEnvironment)),
    InternalEnvironment = [
        {?WINDOWS_JOB_PREFIX ++ "EXECUTABLE", encode_windows_job_value(Path)},
        {?WINDOWS_JOB_PREFIX ++ "DIRECTORY",
         encode_windows_job_value(WorkingDirectory)},
        {?WINDOWS_JOB_PREFIX ++ "ARGV0", encode_windows_job_value(Path)},
        {?WINDOWS_JOB_PREFIX ++ "ARGUMENT_COUNT",
         encode_windows_job_value(integer_to_list(length(Arguments)))},
        {?WINDOWS_JOB_PREFIX ++ "ENVIRONMENT_COUNT",
         encode_windows_job_value(integer_to_list(length(CleanEnvironment)))}
        | ArgumentEnvironment ++ EnvironmentEnvironment
    ],
    %% spawn_executable accepts cmd.exe but rejects both the managed helper
    %% image and .cmd files on supported Windows OTP releases. Keep cmd's
    %% command string to an immutable basename in its own working directory;
    %% no user-controlled value is ever parsed by the command processor.
    {filename:dirname(Launcher), CommandProcessor,
     ["/D", "/Q", "/C", filename:basename(Launcher)],
     InternalEnvironment}.

windows_command_processor() ->
    case os:find_executable("cmd.exe") of
        false -> {error, <<"could not find executable: cmd.exe">>};
        Path -> {ok, Path}
    end.

internal_windows_job_name(Name) ->
    lists:prefix(
      ?WINDOWS_JOB_PREFIX,
      string:uppercase(to_list(Name))).

windows_priv_directory() ->
    case code:priv_dir(kangaroo) of
        Directory when is_list(Directory) -> Directory;
        {error, _} ->
            Beam = code:which(?MODULE),
            filename:join(filename:dirname(filename:dirname(Beam)), "priv")
    end.

encode_windows_job_value(Value) ->
    base64:encode(unicode:characters_to_binary(to_list(Value))).

ensure_windows_job_helper() ->
    case os:type() of
        {win32, _} ->
            case windows_command_processor() of
                {error, _} = Error -> Error;
                {ok, _} ->
                    Key = {?MODULE, windows_job_helper_prepared},
                    case persistent_term:get(Key, false) of
                        true -> ok;
                        false ->
                            case prepare_windows_job_helper() of
                                ok -> persistent_term:put(Key, true), ok;
                                {error, _} = Error -> Error
                            end
                    end
            end;
        _ -> ok
    end.

prepare_windows_job_helper() ->
    Parent = self(),
    Reference = make_ref(),
    {Pid, Monitor} = spawn_monitor(fun() ->
        Parent ! {Reference, prepare_windows_job_helper_worker()}
    end),
    receive
        {Reference, Result} ->
            erlang:demonitor(Monitor, [flush]),
            Result;
        {'DOWN', Monitor, process, Pid, Reason} ->
            {error, unicode:characters_to_binary(
                      io_lib:format(
                        "Windows process isolation preparation failed: ~tp",
                        [Reason]))}
    after 17000 ->
        exit(Pid, kill),
        erlang:demonitor(Monitor, [flush]),
        {error, <<"Windows process isolation preparation timed out">>}
    end.

prepare_windows_job_helper_worker() ->
    process_flag(trap_exit, true),
    case os:find_executable("powershell.exe") of
        false -> {error, <<"could not find executable: powershell.exe">>};
        PowerShell ->
            Helper = windows_job_executable(),
            Arguments = [
                "-NoLogo", "-NoProfile", "-NonInteractive",
                "-ExecutionPolicy", "Bypass", "-File",
                filename:join(windows_priv_directory(),
                              "kangaroo_windows_job.ps1"),
                "-Prepare"
            ],
            try open_port(
                  {spawn_executable, PowerShell},
                  [binary, use_stdio, stderr_to_stdout, exit_status,
                   {args, Arguments}]) of
                Port -> collect_windows_job_preparation(
                          Port, [], erlang:monotonic_time(millisecond) + 15000,
                          Helper)
            catch
                Class:Reason:Stack ->
                    {error, format_exception(Class, Reason, Stack)}
            end
    end.

collect_windows_job_preparation(Port, Output, Deadline, Helper) ->
    Remaining = erlang:max(
        0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, Data}} ->
            Next = [Data | Output],
            case iolist_size(Next) > 1048576 of
                true ->
                    close_port(Port),
                    {error, <<"Windows process isolation preparation output "
                              "exceeded 1048576 bytes">>};
                false ->
                    collect_windows_job_preparation(
                      Port, Next, Deadline, Helper)
            end;
        {Port, {exit_status, 0}} ->
            Launcher = filename:rootname(Helper) ++ ".cmd",
            case {filelib:is_regular(Helper),
                  filelib:is_regular(Launcher)} of
                {true, true} -> ok;
                {false, false} ->
                    {error, <<"Windows process helper and launcher were not "
                              "created">>};
                {false, true} ->
                    {error, <<"Windows process helper was not created">>};
                {true, false} ->
                    {error, <<"Windows process launcher was not created">>}
            end;
        {Port, {exit_status, Code}} ->
            Message = iolist_to_binary(lists:reverse(Output)),
            {error, <<"Windows process isolation preparation exited ",
                      (integer_to_binary(Code))/binary, ": ", Message/binary>>};
        {'EXIT', Port, Reason} ->
            {error, unicode:characters_to_binary(
                      io_lib:format(
                        "Windows process isolation preparation failed: ~tp",
                        [Reason]))}
    after Remaining ->
        close_port(Port),
        {error, <<"Windows process isolation preparation timed out">>}
    end.

windows_job_executable() ->
    Temp = case os:getenv("TEMP") of
        false ->
            case os:getenv("TMP") of
                false ->
                    case os:getenv("TMPDIR") of
                        false -> ".";
                        Value -> Value
                    end;
                Value -> Value
            end;
        Value -> Value
    end,
    filename:join([Temp, "kangaroo", "windows-job-v5-20260831.exe"]).

windows_job_launcher() ->
    filename:rootname(windows_job_executable()) ++ ".cmd".

async_collect(Parent, Id, Port, OsPid, Output, PendingUtf8, OutputBytes,
              Deadline, Streaming) ->
    %% A full output pipe can enqueue many port messages ahead of a caller's
    %% cancellation request. Selectively check the control message first so
    %% cancellation latency does not depend on draining captured output.
    receive
        cancel ->
            close_port(Port),
            Parent ! {kangaroo_process, Id, cancelled};
        {'EXIT', Port, epipe} ->
            terminate_process_tree(OsPid),
            safe_close_port(Port),
            Parent ! {kangaroo_process, Id,
                      {failed, <<"process stdin is not writable">>}};
        {'EXIT', Port, normal} ->
            async_collect(Parent, Id, Port, OsPid, Output, PendingUtf8,
                          OutputBytes, Deadline, Streaming);
        {'EXIT', Port, Reason} ->
            terminate_process_tree(OsPid),
            safe_close_port(Port),
            Parent ! {kangaroo_process, Id,
                      {failed, port_failure_message(Reason)}}
    after 0 ->
        async_collect_wait(Parent, Id, Port, OsPid, Output, PendingUtf8,
                           OutputBytes, Deadline, Streaming)
    end.

async_collect_wait(Parent, Id, Port, OsPid, Output, PendingUtf8,
                   OutputBytes, Deadline, Streaming) ->
    Remaining = erlang:max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, Data}} ->
            {Text, Pending} =
                decode_utf8(<<PendingUtf8/binary, Data/binary>>),
            NextBytes = OutputBytes + byte_size(Text),
            case NextBytes > ?MAX_OUTPUT_BYTES of
                true ->
                    close_port(Port),
                    Parent ! {kangaroo_process, Id,
                              {failed, output_limit_message()}};
                false ->
                    send_output(Parent, Id, Text),
                    NextOutput = case Streaming of
                        true -> Output;
                        false -> prepend_nonempty(Text, Output)
                    end,
                    async_collect(Parent, Id, Port, OsPid, NextOutput,
                                  Pending, NextBytes, Deadline, Streaming)
            end;
        {Port, {exit_status, Code}} ->
            terminate_remaining_process_group(OsPid),
            Final = finish_utf8(PendingUtf8),
            case OutputBytes + byte_size(Final) > ?MAX_OUTPUT_BYTES of
                true ->
                    Parent ! {kangaroo_process, Id,
                              {failed, output_limit_message()}};
                false ->
                    send_output(Parent, Id, Final),
                    CompleteOutput = case Streaming of
                        true -> <<>>;
                        false -> iolist_to_binary(
                                   lists:reverse(
                                     prepend_nonempty(Final, Output)))
                    end,
                    Parent ! {kangaroo_process, Id,
                              {finished, {process_result, Code,
                                          CompleteOutput}}}
            end;
        {consumed, Bytes} when Streaming =:= true, is_integer(Bytes),
                               Bytes > 0 ->
            async_collect(Parent, Id, Port, OsPid, Output, PendingUtf8,
                          erlang:max(0, OutputBytes - Bytes), Deadline,
                          Streaming);
        {input, Input} ->
            case write_port(Port, Input) of
                ok ->
                    async_collect(Parent, Id, Port, OsPid, Output,
                                  PendingUtf8, OutputBytes, Deadline,
                                  Streaming);
                {error, Message} ->
                    close_port(Port),
                    Parent ! {kangaroo_process, Id, {failed, Message}}
            end;
        cancel ->
            close_port(Port),
            Parent ! {kangaroo_process, Id, cancelled};
        {'EXIT', Port, epipe} ->
            terminate_process_tree(OsPid),
            safe_close_port(Port),
            Parent ! {kangaroo_process, Id,
                      {failed, <<"process stdin is not writable">>}};
        {'EXIT', Port, normal} ->
            async_collect(Parent, Id, Port, OsPid, Output, PendingUtf8,
                          OutputBytes, Deadline, Streaming);
        {'EXIT', Port, Reason} ->
            terminate_process_tree(OsPid),
            safe_close_port(Port),
            Parent ! {kangaroo_process, Id,
                      {failed, port_failure_message(Reason)}}
    after Remaining ->
        close_port(Port),
        Parent ! {kangaroo_process, Id, {failed, <<"process timed out">>}}
    end.

collect(Port, OsPid, Output, PendingUtf8, OutputBytes, Deadline) ->
    Remaining = erlang:max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, Data}} ->
            {Text, Pending} =
                decode_utf8(<<PendingUtf8/binary, Data/binary>>),
            NextBytes = OutputBytes + byte_size(Text),
            case NextBytes > ?MAX_OUTPUT_BYTES of
                true ->
                    close_port(Port),
                    {error, output_limit_message()};
                false ->
                    collect(Port, OsPid, prepend_nonempty(Text, Output),
                            Pending, NextBytes, Deadline)
            end;
        {Port, {exit_status, Code}} ->
            terminate_remaining_process_group(OsPid),
            Final = finish_utf8(PendingUtf8),
            case OutputBytes + byte_size(Final) > ?MAX_OUTPUT_BYTES of
                true -> {error, output_limit_message()};
                false ->
                    Text = iolist_to_binary(
                      lists:reverse(prepend_nonempty(Final, Output))),
                    {ok, {process_result, Code, Text}}
            end
    after Remaining ->
        close_port(Port),
        {error, <<"process timed out">>}
    end.

output_limit_message() ->
    <<"process output exceeded 16777216 bytes">>.

write_port(Port, Input) ->
    try port_command(Port, Input) of
        true -> ok;
        false -> {error, <<"process stdin is not writable">>}
    catch
        _:_ -> {error, <<"process stdin is not writable">>}
    end.

port_failure_message(Reason) ->
    unicode:characters_to_binary(
      io_lib:format("process port failed: ~tp", [Reason])).

send_output(_Parent, _Id, <<>>) -> ok;
send_output(Parent, Id, Text) ->
    Parent ! {kangaroo_process, Id, {output, Text}},
    ok.

prepend_nonempty(<<>>, Output) -> Output;
prepend_nonempty(Text, Output) -> [Text | Output].

decode_utf8(Bytes) ->
    decode_utf8(Bytes, []).

decode_utf8(Bytes, Output) ->
    case unicode:characters_to_binary(Bytes, utf8, utf8) of
        Text when is_binary(Text) ->
            {iolist_to_binary(lists:reverse(prepend_nonempty(Text, Output))),
             <<>>};
        {incomplete, Text, Pending} ->
            {iolist_to_binary(lists:reverse(prepend_nonempty(Text, Output))),
             Pending};
        {error, Text, <<_Invalid, Rest/binary>>} ->
            decode_utf8(Rest, [<<16#EF, 16#BF, 16#BD>>, Text | Output])
    end.

finish_utf8(<<>>) -> <<>>;
finish_utf8(Pending) ->
    {Text, Rest} = decode_utf8(Pending),
    case Rest of
        <<>> -> Text;
        _ -> <<Text/binary, 16#EF, 16#BF, 16#BD>>
    end.

close_port(Port) ->
    case erlang:port_info(Port, os_pid) of
        {os_pid, OsPid} -> terminate_process_tree(OsPid);
        _ -> ok
    end,
    try port_close(Port)
        catch
        _:_ -> ok
    end,
    %% taskkill and SIGKILL are synchronous requests, but Windows can retain
    %% file handles for a brief moment while the terminated process is being
    %% reaped. Keep this bounded quiet period below the cancellation budget;
    %% repeatedly launching a process-table command here makes cancellation
    %% take seconds on Windows and macOS.
    timer:sleep(process_cleanup_settle_ms()).

safe_close_port(Port) ->
    try close_port(Port)
    catch _:_ -> ok
    end.

%% Test isolation uses the same bounded tree cleanup for executable ports
%% opened directly by a test body.
terminate_port(Port) ->
    close_port(Port),
    nil.

port_os_pid(Port) ->
    case erlang:port_info(Port, os_pid) of
        {os_pid, OsPid} -> OsPid;
        _ -> undefined
    end.

terminate_remaining_process_group(undefined) -> ok;
terminate_remaining_process_group(OsPid) ->
    case os:type() of
        {win32, _} -> ok;
        _ ->
            %% The leader has already exited, so never fall back to signalling
            %% its positive PID; it may have been reused. Any inherited group
            %% members are still safely addressable by the negative PGID.
            signal_process_group(OsPid, "-STOP"),
            signal_process_group(OsPid, "-KILL"),
            timer:sleep(process_cleanup_settle_ms())
    end.

terminate_process_tree(OsPid) ->
    case os:type() of
        {win32, _} ->
            taskkill(OsPid),
            ok;
        _ ->
            %% OTP launches an executable port as a process-group leader on
            %% Unix. Freeze that whole group before inspecting it: stopping
            %% only the root lets a signal handler in a descendant fork after
            %% the process-table snapshot and escape cancellation.
            signal_process_group(OsPid, "-STOP"),
            signal_processes([OsPid], "-STOP"),
            Processes = process_table(),
            Descendants = descendants(OsPid, Processes),
            %% Retain a PID fallback for hosts where process groups are not
            %% exposed as expected. These processes remain stopped until the
            %% unconditional kill below.
            signal_processes(Descendants, "-STOP"),
            Targets = Descendants ++ [OsPid],
            signal_process_group(OsPid, "-KILL"),
            signal_processes(Targets, "-KILL"),
            ok
    end.

process_cleanup_settle_ms() ->
    case os:type() of
        {win32, _} -> 50;
        _ -> 20
    end.

taskkill(Pid) ->
    _ = os:cmd("taskkill /PID " ++ integer_to_list(Pid) ++
               " /T /F >NUL 2>&1"),
    ok.

process_table() ->
    Lines = string:split(os:cmd("ps -e -o pid= -o ppid="), "\n", all),
    lists:filtermap(fun(Line) ->
        case string:tokens(Line, " \t\r") of
            [Pid, Parent] ->
                try {true, {list_to_integer(Pid), list_to_integer(Parent)}}
                catch
                    _:_ -> false
                end;
            _ -> false
        end
    end, Lines).

descendants(Parent, Processes) ->
    Children = [Pid || {Pid, ParentPid} <- Processes,
                       ParentPid =:= Parent],
    lists:flatmap(fun(Child) ->
        descendants(Child, Processes) ++ [Child]
    end, Children).

signal_processes([], _Signal) -> ok;
signal_processes(Pids, Signal) ->
    Numbers = string:join([integer_to_list(Pid) || Pid <- Pids], " "),
    _ = os:cmd("kill " ++ Signal ++ " " ++ Numbers ++ " 2>/dev/null"),
    ok.

signal_process_group(Pid, Signal) ->
    _ = os:cmd("kill " ++ Signal ++ " -" ++ integer_to_list(Pid) ++
               " 2>/dev/null"),
    ok.

executable_path(Executable) ->
    Value = to_list(Executable),
    case os:find_executable(Value) of
        false ->
            case filelib:is_regular(Value) of
                true -> {ok, Value};
                false ->
                    {error, <<"could not find executable: ", Executable/binary>>}
            end;
        Path -> {ok, Path}
    end.

format_exception(Class, Reason, Stack) ->
    Base = io_lib:format("~0p: ~0p", [Class, Reason]),
    Context = exception_context(Stack),
    unicode:characters_to_binary([Base, Context]).

%% Preserve the failing operation and OTP's non-sensitive error category while
%% omitting stack arguments: process environments can contain credentials and
%% must never be copied into CLI diagnostics.
exception_context([{Module, Function, Arguments, Details} | _]) ->
    Arity = case Arguments of
        Values when is_list(Values) -> length(Values);
        Value when is_integer(Value) -> Value;
        _ -> 0
    end,
    ErrorInfo = proplists:get_value(error_info, Details, #{}),
    Cause = case is_map(ErrorInfo) of
        true -> maps:get(cause, ErrorInfo, undefined);
        false -> undefined
    end,
    case Cause of
        undefined -> io_lib:format(" at ~0p:~0p/~B", [Module, Function, Arity]);
        _ -> io_lib:format(
               " at ~0p:~0p/~B (~0p)",
               [Module, Function, Arity, Cause])
    end;
exception_context(_) -> [].

to_list(Value) when is_binary(Value) -> unicode:characters_to_list(Value);
to_list(Value) when is_list(Value) -> Value.
