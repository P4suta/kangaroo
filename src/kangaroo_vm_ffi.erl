-module(kangaroo_vm_ffi).
-export([run_all/1, worker_count/0, target/0, runtime_name/0,
         runtime_version/0, operating_system/0, daemon_runner_path/0,
         shuffle_seed/0]).

run_all(Funs) ->
    Parent = self(),
    Workers = [begin
                   {Pid, Ref} = spawn_monitor(fun() ->
                       Parent ! {kangaroo_worker, self(), F()}
                   end),
                   {Pid, Ref}
               end || F <- Funs],
    collect(Workers, []).

collect([], Results) ->
    lists:reverse(Results);
collect([{Pid, Ref} | Rest], Results) ->
    receive
        {kangaroo_worker, Pid, Result} ->
            erlang:demonitor(Ref, [flush]),
            collect(Rest, [Result | Results]);
        {'DOWN', Ref, process, Pid, Reason} ->
            erlang:error({kangaroo_worker_crashed, Reason})
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
    erlang:unique_integer([positive, monotonic]).
