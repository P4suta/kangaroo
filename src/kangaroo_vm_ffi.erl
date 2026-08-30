-module(kangaroo_vm_ffi).
-export([run_all/1, run_batches/4, worker_count/0, target/0, runtime_name/0,
         runtime_version/0, operating_system/0, daemon_runner_path/0,
         shuffle_seed/0]).

run_all(Funs) ->
    Parent = self(),
    Workers = [begin
                   {Pid, Ref} = spawn_monitor(fun() ->
                       Parent ! {kangaroo_worker, self(), Index, F()}
                   end),
                   {Index, Pid, Ref}
               end || {Index, F} <- lists:enumerate(Funs)],
    collect(Workers, #{}).

%% JavaScript alone uses its serialisation-aware outer Worker implementation.
%% The executor keeps BEAM on run_all/1, where closures are native values.
run_batches(_Batches, _DefaultTimeout, _FailFast, _Retry) -> [].

collect([], Results) ->
    [maps:get(Index, Results)
     || Index <- lists:seq(1, map_size(Results))];
collect(Workers, Results) ->
    receive
        {kangaroo_worker, Pid, Index, Result} ->
            case take_worker_by_pid(Pid, Workers) of
                {ok, {_ExpectedIndex, Pid, Ref}, Rest} ->
                    erlang:demonitor(Ref, [flush]),
                    collect(Rest, maps:put(Index, Result, Results));
                error ->
                    collect(Workers, Results)
            end;
        {'DOWN', Ref, process, Pid, Reason} ->
            case take_worker_by_ref(Ref, Workers) of
                {ok, {_Index, Pid, Ref}, Rest} ->
                    stop_workers(Rest),
                    erlang:error({kangaroo_worker_crashed, Reason});
                error ->
                    collect(Workers, Results)
            end
    end.

take_worker_by_pid(Pid, Workers) ->
    take_worker(fun({_Index, Worker, _Ref}) -> Worker =:= Pid end,
                Workers, []).

take_worker_by_ref(Ref, Workers) ->
    take_worker(fun({_Index, _Pid, Monitor}) -> Monitor =:= Ref end,
                Workers, []).

take_worker(_Matches, [], _Before) -> error;
take_worker(Matches, [Worker | Rest], Before) ->
    case Matches(Worker) of
        true -> {ok, Worker, lists:reverse(Before) ++ Rest};
        false -> take_worker(Matches, Rest, [Worker | Before])
    end.

stop_workers(Workers) ->
    lists:foreach(fun({_Index, Pid, _Ref}) -> exit(Pid, kill) end, Workers),
    Deadline = erlang:monotonic_time(millisecond) + 1000,
    await_stopped_workers(Workers, Deadline).

await_stopped_workers([], _Deadline) -> ok;
await_stopped_workers(Workers, Deadline) ->
    Remaining = erlang:max(
        0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {'DOWN', Ref, process, Pid, _Reason} ->
            case take_worker_by_ref(Ref, Workers) of
                {ok, {_Index, Pid, Ref}, Rest} ->
                    await_stopped_workers(Rest, Deadline);
                error ->
                    await_stopped_workers(Workers, Deadline)
            end
    after Remaining ->
        lists:foreach(fun({_Index, _Pid, Ref}) ->
            erlang:demonitor(Ref, [flush])
        end, Workers),
        ok
    end.

worker_count() ->
    erlang:system_info(schedulers_online).

target() ->
    <<"erlang">>.

runtime_name() ->
    <<"erlang">>.

runtime_version() ->
    unicode:characters_to_binary(erlang:system_info(otp_release)).

operating_system() ->
    case os:type() of
        {win32, _} -> <<"windows">>;
        {unix, darwin} -> <<"macos">>;
        {unix, linux} -> <<"linux">>;
        {Family, Name} ->
            unicode:characters_to_binary(
              io_lib:format("~0p/~0p", [Family, Name]))
    end.

daemon_runner_path() ->
    <<"build/dev/javascript/kangaroo/kangaroo_daemon_child.mjs">>.

shuffle_seed() ->
    erlang:system_time(millisecond).
