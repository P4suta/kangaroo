-module(kangaroo_cli_test_ffi).
-export([reset_flaky/0, fail_once/0, sleeper_executable/0,
         sleeper_arguments/1, tree_marker/0, tree_arguments/1,
         orphan_tree_executable/0, orphan_tree_arguments/1,
         echo_arguments/0, argument_echo_arguments/1,
         split_utf8_arguments/0,
         invalid_utf8_arguments/0,
         oversized_output_arguments/0,
         oversized_split_output_arguments/0,
         invalid_utf8_expansion_arguments/0,
         streaming_handshake_arguments/0,
         streaming_output_arguments/0,
         closed_stdin_executable/0, closed_stdin_tree_arguments/1,
         silent_exit_arguments/1, schedule_replace/4,
         kill_stderr_proxy/0, make_directory_symlink/2,
         cleanup_active_processes/0, internal_windows_job_name/1]).

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

argument_echo_arguments(Value) ->
    [<<"-noshell">>, <<"-eval">>,
     <<"[Argument]=init:get_plain_arguments(), "
       "io:put_chars([Argument,\"|\",os:getenv(\"KANGAROO_PROCESS_TEST_ENV\")]), "
       "halt().">>,
     <<"-extra">>, Value].

split_utf8_arguments() ->
    [<<"-noshell">>, <<"-eval">>,
     <<"P=open_port({fd,0,1},[out,binary]), "
       "true=port_command(P,<<65,240,159>>), timer:sleep(40), "
       "true=port_command(P,<<166,152,66>>), timer:sleep(20), halt().">>].

invalid_utf8_arguments() ->
    [<<"-noshell">>, <<"-eval">>,
     <<"P=open_port({fd,0,1},[out,binary]), "
       "true=port_command(P,<<65,255,66>>), halt().">>].

oversized_output_arguments() ->
    [<<"-noshell">>, <<"-eval">>,
     <<"P=open_port({fd,0,1},[out,binary]), "
       "Chunk=binary:copy(<<97>>,16384), "
       "lists:foreach(fun(_) -> true=port_command(P,Chunk) end, "
       "lists:seq(1,1024)), true=port_command(P,<<97>>), halt().">>].

oversized_split_output_arguments() ->
    [<<"-noshell">>, <<"-eval">>,
     <<"Out=open_port({fd,0,1},[out,binary]), "
       "Err=open_port({fd,0,2},[out,binary]), "
       "Chunk=binary:copy(<<97>>,16384), "
       "lists:foreach(fun(_) -> true=port_command(Out,Chunk), "
       "true=port_command(Err,Chunk) end, lists:seq(1,512)), "
       "true=port_command(Out,<<97>>), halt().">>].

invalid_utf8_expansion_arguments() ->
    [<<"-noshell">>, <<"-eval">>,
     <<"P=open_port({fd,0,1},[out,binary]), "
       "Chunk=binary:copy(<<255>>,65536), "
       "lists:foreach(fun(_) -> true=port_command(P,Chunk) end, "
       "lists:seq(1,86)), halt().">>].

streaming_handshake_arguments() ->
    [<<"-noshell">>, <<"-eval">>,
     <<"Chunk=binary:copy(<<97>>,1048576), "
       "Loop=fun Self() -> case io:get_line(\"\") of "
       "\"next\\n\" -> io:put_chars(Chunk), Self(); "
       "\"done\\n\" -> halt(0); eof -> halt(2); _ -> halt(3) end end, "
       "Loop().">>].

streaming_output_arguments() ->
    [<<"-noshell">>, <<"-eval">>,
     <<"P=open_port({fd,0,1},[out,binary]), Chunk=binary:copy(<<97>>,1024), "
       "F=fun Self() -> true=port_command(P,Chunk), timer:sleep(1), Self() end, "
       "F().">>].

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

orphan_tree_arguments(Marker) ->
    case os:type() of
        {win32, _} ->
            Erl = os:find_executable("erl"),
            Inner = lists:flatten(io_lib:format(
                "timer:sleep(1200), file:write_file(~p, "
                "<<\"survived\">>), halt().",
                [binary_to_list(Marker)])),
            Outer = lists:flatten(io_lib:format(
                "E=~p, C=~p, open_port({spawn_executable,E}, "
                "[exit_status,{args,[\"-noshell\",\"-eval\",C]}]), halt().",
                [Erl, Inner])),
            [<<"-noshell">>, <<"-eval">>,
             unicode:characters_to_binary(Outer)];
        _ ->
            [<<"-c">>,
             <<"(sleep 1; printf survived > \"$1\") "
               ">/dev/null 2>&1 </dev/null & exit 0">>,
             <<"kangaroo-orphan">>, Marker]
    end.

orphan_tree_executable() ->
    case os:type() of
        {win32, _} -> sleeper_executable();
        _ -> unicode:characters_to_binary(os:find_executable("sh"))
    end.

closed_stdin_executable() ->
    case os:type() of
        {win32, _} -> sleeper_executable();
        _ -> unicode:characters_to_binary(os:find_executable("sh"))
    end.

closed_stdin_tree_arguments(Marker) ->
    case os:type() of
        {win32, _} -> [];
        _ ->
            [<<"-c">>,
             %% Close the root's input before forking the marker process.
             %% Forking first leaves a brief reader alive until the child's
             %% /dev/null redirection completes, making a write legitimately
             %% succeed even though the shell has already printed `ready`.
             <<"exec 0<&-; "
               "(sleep 0.4; printf survived > \"$1\") "
               ">/dev/null 2>&1 </dev/null & "
               "printf ready; sleep 5">>,
             <<"kangaroo-closed-stdin">>, Marker]
    end.

schedule_replace(Path, Expected, Replacement, Delay) ->
    spawn(fun() ->
        timer:sleep(Delay),
        case file:read_file(Path) of
            {ok, Expected} -> file:write_file(Path, Replacement);
            _ -> ok
        end
    end),
    nil.

make_directory_symlink(Target, Link) ->
    case file:make_symlink(Target, Link) of
        ok -> true;
        _ -> false
    end.

kill_stderr_proxy() ->
    case persistent_term:get({kangaroo_isolate_ffi, stderr_proxy}, undefined) of
        Proxy when is_pid(Proxy) ->
            exit(Proxy, kill),
            wait_until_dead(Proxy, 100);
        _ -> ok
    end,
    nil.

cleanup_active_processes() -> nil.

internal_windows_job_name(Name) ->
    kangaroo_process_ffi:internal_windows_job_name(Name).

wait_until_dead(_Pid, 0) -> ok;
wait_until_dead(Pid, Remaining) ->
    case is_process_alive(Pid) of
        false -> ok;
        true ->
            timer:sleep(1),
            wait_until_dead(Pid, Remaining - 1)
    end.
