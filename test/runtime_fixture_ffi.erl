-module(runtime_fixture_ffi).
-export([promise_pass/0, promise_reject/0, promise_never/0,
         left_value/0, right_value/0, error_result/0,
         left_string/0, right_string/0, non_binary_assert/0, spawn_descendant/0,
         spawn_cleanup_race/0, spawn_orphan_descendant/0,
         spawn_native_orphan_descendant/0,
         spawn_port_orphan_descendant/0,
         kill_output_collector/0,
         kill_test_owner_from_link/0,
         exit_test_worker/0,
         spawn_native_descendant/0, complete_native_child/0,
         spawn_synchronous_descendant/0,
         native_output_timeout/0, synchronous_timeout/0,
         reset_descendant_marker/0, descendant_marker_exists/0,
         run_all_crash_cancels_sibling/0]).

promise_pass() -> nil.
promise_reject() -> erlang:error(<<"async rejected">>).
promise_never() -> timer:sleep(100), nil.
left_value() -> 1.
right_value() -> 2.
error_result() -> {error, <<"not an integer">>}.
left_string() -> <<"same\nold">>.
right_string() -> <<"same\nnew">>.
non_binary_assert() ->
    erlang:error(#{gleam_error => assert,
                   kind => guard,
                   left => #{value => 1},
                   right => #{value => 2},
                   message => <<"synthetic non-binary assert">>}).

spawn_descendant() ->
    Marker = descendant_marker(),
    spawn(fun() ->
              timer:sleep(100),
              file:write_file(Marker, <<"survived">>)
          end),
    nil.

spawn_cleanup_race() ->
    Marker = descendant_marker(),
    Root = self(),
    spawn_opt(fun() ->
        Reference = erlang:monitor(process, Root),
        receive
            {'DOWN', Reference, process, Root, _Reason} ->
                spawn(fun() ->
                    timer:sleep(50),
                    file:write_file(Marker, <<"survived">>)
                end)
        after 1000 ->
            ok
        end
    end, [{priority, high}]),
    nil.

spawn_orphan_descendant() ->
    Marker = descendant_marker(),
    {_Parent, Reference} = spawn_monitor(fun() ->
        spawn(fun() ->
            timer:sleep(100),
            file:write_file(Marker, <<"survived">>)
        end)
    end),
    receive
        {'DOWN', Reference, process, _Pid, _Reason} -> nil
    after 1000 ->
        erlang:error(orphan_parent_did_not_exit)
    end.

spawn_native_orphan_descendant() -> spawn_orphan_descendant().

spawn_port_orphan_descendant() ->
    Marker = descendant_marker(),
    Erl = os:find_executable("erl"),
    Inner = lists:flatten(io_lib:format(
        "timer:sleep(400), file:write_file(~p, <<\"survived\">>), halt().",
        [Marker])),
    open_port({spawn_executable, Erl},
              [exit_status,
               {args, ["-noshell", "-eval", Inner]}]),
    nil.

kill_output_collector() ->
    exit(group_leader(), kill),
    nil.

kill_test_owner_from_link() ->
    spawn_link(fun() -> exit(kill) end),
    receive after 1000 -> nil end.

exit_test_worker() -> nil.

spawn_native_descendant() -> spawn_descendant().

complete_native_child() ->
    file:write_file(descendant_marker(), <<"completed">>),
    nil.

spawn_synchronous_descendant() -> spawn_descendant().

native_output_timeout() ->
    %% Keep the side effect well beyond the 40 ms isolation timeout. A loaded
    %% scheduler can start this descendant late; the assertion must prove it
    %% was killed, not depend on it writing inside a narrow 210 ms window.
    Marker = descendant_marker(),
    spawn(fun() ->
              timer:sleep(1000),
              file:write_file(Marker, <<"survived">>)
          end),
    timer:sleep(1000),
    nil.

synchronous_timeout() -> native_output_timeout().

reset_descendant_marker() ->
    file:delete(descendant_marker()),
    nil.

descendant_marker_exists() ->
    filelib:is_file(descendant_marker()).

run_all_crash_cancels_sibling() ->
    Caller = self(),
    try
        kangaroo_vm_ffi:run_all([
            fun() -> exit(synthetic_worker_crash) end,
            fun() ->
                timer:sleep(100),
                Caller ! kangaroo_sibling_survived,
                nil
            end
        ])
    catch
        error:{kangaroo_worker_crashed, _Reason} -> ok
    end,
    timer:sleep(150),
    receive
        kangaroo_sibling_survived -> false
    after 0 ->
        true
    end.

descendant_marker() ->
    Temp = temporary_directory(),
    filename:join(Temp, "kangaroo-isolate-descendant-" ++ os:getpid() ++ ".marker").

temporary_directory() ->
    case os:getenv("TMPDIR") of
        false ->
            case os:getenv("TEMP") of
                false ->
                    case os:getenv("TMP") of
                        false -> "/tmp";
                        Value -> Value
                    end;
                Value -> Value
            end;
        Value -> Value
    end.
