-module(kangaroo_cli_test_ffi).
-export([reset_flaky/0, fail_once/0, sleeper_executable/0,
         sleeper_arguments/1, tree_marker/0, tree_arguments/1,
         echo_arguments/0, closed_stdin_tree_arguments/1,
         silent_exit_arguments/1, schedule_replace/4,
         kill_stderr_proxy/0]).

reset_flaky() ->
    persistent_term:put({?MODULE, flaky_attempt}, 0),
    nil.

fail_once() ->
    Attempt = persistent_term:get({?MODULE, flaky_attempt}, 0),
    persistent_term:put({?MODULE, flaky_attempt}, Attempt + 1),
    case Attempt of
        0 -> erlang:error(#{gleam_error => panic,
                            message => <<"first attempt failed">>});
        _ -> nil
    end.

sleeper_executable() ->
    unicode:characters_to_binary(os:find_executable("erl")).

sleeper_arguments(Milliseconds) ->
    Code = iolist_to_binary([
        "io:format(\"ready\"), timer:sleep(",
        integer_to_binary(Milliseconds),
        "), halt()."
    ]),
    [<<"-noshell">>, <<"-eval">>, Code].

echo_arguments() ->
    [<<"-noshell">>, <<"-eval">>,
     <<"case io:get_line(\"\") of eof -> halt(2); Line -> io:put_chars(Line), halt() end.">>].

silent_exit_arguments(Code) ->
    Expression = iolist_to_binary(["halt(", integer_to_binary(Code), ")."]),
    [<<"-noshell">>, <<"-eval">>, Expression].

tree_marker() ->
    Temp = case os:getenv("TMPDIR") of
               false ->
                   case os:getenv("TEMP") of
                       false -> "/tmp";
                       Value -> Value
                   end;
               Value -> Value
           end,
    Name = "kangaroo-tree-" ++
           integer_to_list(erlang:unique_integer([positive, monotonic])) ++
           ".marker",
    unicode:characters_to_binary(filename:join(Temp, Name)).

tree_arguments(Marker) ->
    Erl = os:find_executable("erl"),
    Inner = lists:flatten(io_lib:format(
        "timer:sleep(400), file:write_file(~p, <<\"survived\">>), halt().",
        [binary_to_list(Marker)])),
    Outer = lists:flatten(io_lib:format(
        "E=~p, C=~p, open_port({spawn_executable,E}, "
        "[exit_status,{args,[\"-noshell\",\"-eval\",C]}]), "
        "timer:sleep(5000), halt().",
        [Erl, Inner])),
    [<<"-noshell">>, <<"-eval">>, unicode:characters_to_binary(Outer)].

closed_stdin_tree_arguments(_Marker) ->
    [].

schedule_replace(Path, Expected, Replacement, Delay) ->
    spawn(fun() ->
        timer:sleep(Delay),
        case file:read_file(Path) of
            {ok, Expected} -> file:write_file(Path, Replacement);
            _ -> ok
        end
    end),
    nil.

kill_stderr_proxy() ->
    case persistent_term:get({kangaroo_isolate_ffi, stderr_proxy}, undefined) of
        Proxy when is_pid(Proxy) ->
            exit(Proxy, kill),
            wait_until_dead(Proxy, 100);
        _ -> ok
    end,
    nil.

wait_until_dead(_Pid, 0) -> ok;
wait_until_dead(Pid, Remaining) ->
    case is_process_alive(Pid) of
        false -> ok;
        true ->
            timer:sleep(1),
            wait_until_dead(Pid, Remaining - 1)
    end.
