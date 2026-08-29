-module(kangaroo_process_ffi).
-export([run/5, run_inherited/5, start/5, poll/1, cancel/1, write/2]).

start(Directory, Executable, Arguments, Environment, TimeoutMs) ->
    case executable_path(Executable) of
        {error, _} = Error -> Error;
        {ok, Path} ->
            Id = erlang:unique_integer([positive, monotonic]),
            Parent = self(),
            Pid = spawn(fun() ->
                async_run(Parent, Id, Directory, Path, Arguments,
                          Environment, TimeoutMs)
            end),
            put({kangaroo_process, Id}, Pid),
            {ok, Id}
    end.

poll(Id) ->
    receive
        {kangaroo_process, Id, {output, Output}} ->
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
        Pid -> Pid ! cancel
    end,
    nil.

write(Id, Input) ->
    case get({kangaroo_process, Id}) of
        undefined -> ok;
        Pid -> Pid ! {input, Input}
    end,
    nil.

run(Directory, Executable, Arguments, Environment, TimeoutMs) ->
    case executable_path(Executable) of
        {error, _} = Error -> Error;
        {ok, Path} ->
            Port = open_port(
                     {spawn_executable, Path},
                     [binary, use_stdio, stderr_to_stdout, exit_status,
                      {cd, to_list(Directory)},
                      {args, [to_list(Argument) || Argument <- Arguments]},
                      {env, [{to_list(Key), to_list(Value)}
                             || {Key, Value} <- Environment]}]),
            Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
            collect(Port, [], Deadline)
    end.

run_inherited(Directory, Executable, Arguments, Environment, TimeoutMs) ->
    case executable_path(Executable) of
        {error, _} = Error -> Error;
        {ok, Path} ->
            Port = open_port(
                     {spawn_executable, Path},
                     [nouse_stdio, exit_status,
                      {cd, to_list(Directory)},
                      {args, [to_list(Argument) || Argument <- Arguments]},
                      {env, [{to_list(Key), to_list(Value)}
                             || {Key, Value} <- Environment]}]),
            Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
            collect_inherited(Port, Deadline)
    end.

collect_inherited(Port, Deadline) ->
    Remaining = erlang:max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {exit_status, Code}} ->
            {ok, {process_result, Code, <<>>}};
        {Port, {data, _Data}} ->
            collect_inherited(Port, Deadline)
    after Remaining ->
        close_port(Port),
        {error, <<"process timed out">>}
    end.

async_run(Parent, Id, Directory, Path, Arguments, Environment, TimeoutMs) ->
    try
        Port = open_port(
                 {spawn_executable, Path},
                 [binary, use_stdio, stderr_to_stdout, exit_status,
                  {cd, to_list(Directory)},
                  {args, [to_list(Argument) || Argument <- Arguments]},
                  {env, [{to_list(Key), to_list(Value)}
                         || {Key, Value} <- Environment]}]),
        Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
        async_collect(Parent, Id, Port, [], Deadline)
    catch
        Class:Reason ->
            Parent ! {kangaroo_process, Id,
                      {failed, format_exception(Class, Reason)}}
    end.

async_collect(Parent, Id, Port, Output, Deadline) ->
    Remaining = erlang:max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, Data}} ->
            Parent ! {kangaroo_process, Id, {output, Data}},
            async_collect(Parent, Id, Port, [Data | Output], Deadline);
        {Port, {exit_status, Code}} ->
            Parent ! {kangaroo_process, Id,
                      {finished, {process_result, Code,
                                  iolist_to_binary(lists:reverse(Output))}}};
        {input, Input} ->
            try port_command(Port, Input)
            catch _:_ -> ok
            end,
            async_collect(Parent, Id, Port, Output, Deadline);
        cancel ->
            case start_windows_taskkill(Port) of
                {ok, Killer, OsPid} ->
                    %% The OS owns an active tree-termination request before
                    %% cancellation is acknowledged. This keeps the caller's
                    %% response under 250 ms without abandoning cleanup.
                    Parent ! {kangaroo_process, Id, cancelled},
                    finish_windows_cancellation(Port, Killer, OsPid);
                unavailable ->
                    close_port(Port),
                    Parent ! {kangaroo_process, Id, cancelled}
            end
    after Remaining ->
        close_port(Port),
        Parent ! {kangaroo_process, Id, {failed, <<"process timed out">>}}
    end.

collect(Port, Output, Deadline) ->
    Remaining = erlang:max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, Data}} ->
            collect(Port, [Data | Output], Deadline);
        {Port, {exit_status, Code}} ->
            {ok, {process_result, Code,
                  iolist_to_binary(lists:reverse(Output))}}
    after Remaining ->
        close_port(Port),
        {error, <<"process timed out">>}
    end.

close_port(Port) ->
    Processes = case erlang:port_info(Port, os_pid) of
        {os_pid, OsPid} -> terminate_process_tree(OsPid);
        _ -> []
    end,
    try port_close(Port)
    catch
        _:_ -> ok
    end,
    wait_for_processes(Processes,
                       erlang:monotonic_time(millisecond) + 200).

start_windows_taskkill(Port) ->
    case {os:type(), erlang:port_info(Port, os_pid),
          os:find_executable("taskkill")} of
        {{win32, _}, {os_pid, OsPid}, Taskkill} when Taskkill =/= false ->
            try
                Killer = open_port(
                           {spawn_executable, Taskkill},
                           [binary, use_stdio, stderr_to_stdout, exit_status,
                            hide,
                            {args, ["/PID", integer_to_list(OsPid),
                                    "/T", "/F"]}]),
                {ok, Killer, OsPid}
            catch
                _:_ -> unavailable
            end;
        _ -> unavailable
    end.

finish_windows_cancellation(Port, Killer, OsPid) ->
    case await_taskkill(Killer,
                        erlang:monotonic_time(millisecond) + 5000) of
        0 -> ok;
        _ -> terminate_process_tree(OsPid)
    end,
    try port_close(Port)
    catch
        _:_ -> ok
    end.

await_taskkill(Killer, Deadline) ->
    Remaining = erlang:max(0, Deadline -
                              erlang:monotonic_time(millisecond)),
    receive
        {Killer, {data, _Data}} -> await_taskkill(Killer, Deadline);
        {Killer, {exit_status, Code}} -> Code
    after Remaining ->
        try port_close(Killer)
        catch
            _:_ -> ok
        end,
        timeout
    end.

terminate_process_tree(OsPid) ->
    case os:type() of
        {win32, _} ->
            _ = os:cmd("taskkill /PID " ++ integer_to_list(OsPid) ++
                       " /T /F >NUL 2>&1"),
            [];
        _ ->
            %% Freeze the root first so it cannot create a child between the
            %% process-table snapshot and termination.
            signal_processes([OsPid], "-STOP"),
            Processes = process_table(),
            Descendants = descendants(OsPid, Processes),
            signal_processes(Descendants, "-TERM"),
            timer:sleep(20),
            Targets = Descendants ++ [OsPid],
            signal_processes(Targets, "-KILL"),
            Targets
    end.

wait_for_processes([], _Deadline) -> ok;
wait_for_processes(Targets, Deadline) ->
    Running = [Pid || {Pid, _} <- process_table(),
                      lists:member(Pid, Targets)],
    case {Running, erlang:monotonic_time(millisecond) < Deadline} of
        {[], _} -> ok;
        {_, true} ->
            timer:sleep(5),
            wait_for_processes(Running, Deadline);
        {_, false} -> ok
    end.

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

format_exception(Class, Reason) ->
    unicode:characters_to_binary(
      io_lib:format("~0p: ~0p", [Class, Reason])).

to_list(Value) when is_binary(Value) -> binary_to_list(Value);
to_list(Value) when is_list(Value) -> Value.
