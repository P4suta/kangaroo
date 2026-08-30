%% Runs a test case body in a freshly spawned process so that panics and
%% stray processes cannot take down the runner. The source location of a
%% crash is derived from its stack by the pure `kangaroo@location` module.
-module(kangaroo_isolate_ffi).
-export([isolate/2, isolate_captured/2, isolate_captured_with_limit/3]).

-define(DEFAULT_TIMEOUT_MS, 30000).
-define(MAX_CAPTURED_OUTPUT_BYTES, 16777216).
-define(DESCENDANT_CLEANUP_TIMEOUT_MS, 1000).

isolate(Body, Timeout) ->
    {captured_isolation, Result, _Stdout, _Stderr} =
        isolate_captured(Body, Timeout),
    Result.

isolate_captured(Body, Timeout) ->
    isolate_captured_with_limit(Body, Timeout, ?MAX_CAPTURED_OUTPUT_BYTES).

isolate_captured_with_limit(Body, Timeout, OutputLimit) ->
    TimeoutMs = case Timeout of
                    {some, Ms} -> Ms;
                    none -> ?DEFAULT_TIMEOUT_MS
                end,
    ensure_stderr_proxy(),
    kangaroo_coverage_probe_ffi:ensure_started(),
    Collector = spawn(fun() ->
        output_collector([], [], 0, false, OutputLimit)
    end),
    true = ets:insert(kangaroo_output_collectors, {Collector}),
    Parent = self(),
    Pid = spawn(fun() ->
                        receive
                            kangaroo_start ->
                                group_leader(Collector, self()),
                                try
                                    Body(),
                                    notify_after_coverage(Parent,
                                                          kangaroo_done)
                                catch
                                    error:#{kangaroo_error := skip,
                                            reason := SkipReason}:_Stack ->
                                        notify_after_coverage(
                                          Parent,
                                          {kangaroo_skipped, SkipReason});
                                    Class:Reason:Stack ->
                                        notify_after_coverage(
                                          Parent,
                                          {kangaroo_crashed, Class,
                                           Reason, Stack})
                                end
                        end
                end),
    OwnerMonitor = erlang:monitor(process, Pid),
    disable_trace(Pid),
    %% Track both BEAM descendants and executable ports opened by any traced
    %% descendant. Closing only the owner process can leave an external port
    %% program alive long enough to escape and mutate the workspace later.
    1 = erlang:trace(Pid, true, [procs, ports, set_on_spawn]),
    Pid ! kangaroo_start,
    receive
        kangaroo_done ->
            finish_isolation(
              Collector, Pid, OwnerMonitor, completed, OutputLimit);
        {kangaroo_crashed, _Class, Reason, Stack} ->
            {Expected, Actual, Diff} = assertion_fields(Reason),
            Result =
              {crashed, {caught_error, panic_name(Reason),
                         error_message(Reason, Stack),
                         error_location(Reason, Stack),
                         Expected, Actual, Diff}},
            finish_isolation(
              Collector, Pid, OwnerMonitor, Result, OutputLimit);
        {kangaroo_skipped, Reason} ->
            finish_isolation(
              Collector, Pid, OwnerMonitor,
              {skipped_isolation, Reason}, OutputLimit);
        {kangaroo_coverage_failed, Message} ->
            finish_isolation(
              Collector, Pid, OwnerMonitor,
              coverage_failure_result(Message), OutputLimit);
        {'DOWN', OwnerMonitor, process, Pid, Reason} ->
            finish_isolation(
              Collector, Pid, OwnerMonitor,
              owner_terminated_result(Reason), OutputLimit)
    after TimeoutMs ->
        %% Keep the owner alive until cleanup has established its
        %% trace-delivery barrier. Killing it here can let the monitor DOWN
        %% overtake a preceding spawn trace, causing cleanup to return before
        %% it learns about a test-owned descendant.
        Result =
          {crashed, {caught_error, <<"timeout">>,
                     <<"Test case timed out after ",
                       (integer_to_binary(TimeoutMs))/binary, " ms">>,
                     none, none, none, none}},
        finish_isolation(
          Collector, Pid, OwnerMonitor, Result, OutputLimit)
    end.

finish_isolation(Collector, Pid, OwnerMonitor, Result, OutputLimit) ->
    Cleanup = cleanup_descendants(Pid),
    erlang:demonitor(OwnerMonitor, [flush]),
    finish_capture(
      Collector, cleanup_result(Cleanup, Result), OutputLimit).

owner_terminated_result(Reason) ->
    Message = unicode:characters_to_binary(
      io_lib:format("Test process exited before publishing a result: ~tp",
                    [Reason])),
    {crashed,
     {caught_error, <<"exit">>, Message,
      none, none, none, none}}.

%% Hits and this flush originate from the same isolated process, so Erlang's
%% signal ordering guarantees that the writer persists every preceding hit
%% before the parent is allowed to publish the test result. Flushing from the
%% parent alone would use a different sender and could overtake hit messages.
notify_after_coverage(Parent, Message) ->
    Notification = case kangaroo_coverage_probe_ffi:flush() of
        nil -> Message;
        {error, Failure} -> {kangaroo_coverage_failed, Failure}
    end,
    Parent ! Notification,
    %% Keep the owner alive until its tracer has consumed every port-open and
    %% spawn event preceding the result. The parent normally kills this process
    %% during cleanup; the timeout is only a bounded fallback if the parent dies.
    receive
        kangaroo_cleanup -> ok
    after ?DESCENDANT_CLEANUP_TIMEOUT_MS * 5 ->
        ok
    end.

cleanup_descendants(Root) ->
    Deadline = erlang:monotonic_time(millisecond) +
        ?DESCENDANT_CLEANUP_TIMEOUT_MS,
    {InitialPending, InitialSeen} =
        await_initial_trace_delivery(Root, Deadline),
    {Pending, Seen} = track_and_kill(Root, InitialPending, InitialSeen),
    await_descendant_cleanup(Pending, Seen, Deadline).

await_initial_trace_delivery(Root, Deadline) ->
    try erlang:trace_delivered(Root) of
        Reference ->
            await_trace_delivery(Root, Reference, #{}, #{}, Deadline)
    catch
        error:badarg -> {#{}, #{}}
    end.

await_trace_delivery(Root, Reference, Pending, Seen, Deadline) ->
    Remaining = erlang:max(
        0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {trace_delivered, Root, Reference} -> {Pending, Seen};
        {trace, _Parent, spawn, Child, _Mfa} ->
            {NextPending, NextSeen} =
                track_and_kill(Child, Pending, Seen),
            await_trace_delivery(
              Root, Reference, NextPending, NextSeen, Deadline);
        {trace, Child, spawned, _Parent, _Mfa} ->
            {NextPending, NextSeen} =
                track_and_kill(Child, Pending, Seen),
            await_trace_delivery(
              Root, Reference, NextPending, NextSeen, Deadline);
        {trace, _Owner, link, Port} when is_port(Port) ->
            {NextPending, NextSeen} =
                track_and_close_port(Port, Pending, Seen),
            await_trace_delivery(
              Root, Reference, NextPending, NextSeen, Deadline);
        {trace, Port, open, _Owner, _Driver} when is_port(Port) ->
            {NextPending, NextSeen} =
                track_and_close_port(Port, Pending, Seen),
            await_trace_delivery(
              Root, Reference, NextPending, NextSeen, Deadline);
        {'DOWN', DownReference, process, _Pid, _Reason}
          when is_map_key(DownReference, Pending) ->
            await_trace_delivery(
              Root, Reference, maps:remove(DownReference, Pending), Seen,
              Deadline);
        {'DOWN', DownReference, port, _Port, _Reason}
          when is_map_key(DownReference, Pending) ->
            await_trace_delivery(
              Root, Reference, maps:remove(DownReference, Pending), Seen,
              Deadline);
        {trace, _Tracee, _Event, _Detail, _Extra} ->
            await_trace_delivery(Root, Reference, Pending, Seen, Deadline);
        {trace, _Tracee, _Event, _Detail} ->
            await_trace_delivery(Root, Reference, Pending, Seen, Deadline);
        {trace, _Tracee, _Event} ->
            await_trace_delivery(Root, Reference, Pending, Seen, Deadline)
    after Remaining ->
        {Pending, Seen}
    end.

track_and_kill(Pid, Pending, Seen) ->
    case maps:is_key(Pid, Seen) of
        true -> {Pending, Seen};
        false ->
            Reference = erlang:monitor(process, Pid),
            exit(Pid, kill),
            {maps:put(Reference, Pid, Pending), maps:put(Pid, true, Seen)}
    end.

track_and_close_port(Port, Pending, Seen) ->
    case maps:is_key(Port, Seen) of
        true -> {Pending, Seen};
        false ->
            try
                Reference = erlang:monitor(port, Port),
                kangaroo_process_ffi:terminate_port(Port),
                {maps:put(Reference, Port, Pending),
                 maps:put(Port, true, Seen)}
            catch
                error:badarg -> {Pending, maps:put(Port, true, Seen)}
            end
    end.

await_descendant_cleanup(Pending, Seen, Deadline) ->
    Remaining = erlang:max(
        0, Deadline - erlang:monotonic_time(millisecond)),
    Wait = case map_size(Pending) of 0 -> 0; _ -> Remaining end,
    receive
        {trace, _Parent, spawn, Child, _Mfa} ->
            {NextPending, NextSeen} =
                track_and_kill(Child, Pending, Seen),
            await_descendant_cleanup(NextPending, NextSeen, Deadline);
        {trace, Child, spawned, _Parent, _Mfa} ->
            {NextPending, NextSeen} =
                track_and_kill(Child, Pending, Seen),
            await_descendant_cleanup(NextPending, NextSeen, Deadline);
        {trace, _Owner, link, Port} when is_port(Port) ->
            {NextPending, NextSeen} =
                track_and_close_port(Port, Pending, Seen),
            await_descendant_cleanup(NextPending, NextSeen, Deadline);
        {trace, Port, open, _Owner, _Driver} when is_port(Port) ->
            {NextPending, NextSeen} =
                track_and_close_port(Port, Pending, Seen),
            await_descendant_cleanup(NextPending, NextSeen, Deadline);
        {'DOWN', Reference, process, _Pid, _Reason}
          when is_map_key(Reference, Pending) ->
            await_descendant_cleanup(
              maps:remove(Reference, Pending), Seen, Deadline);
        {'DOWN', Reference, port, _Port, _Reason}
          when is_map_key(Reference, Pending) ->
            await_descendant_cleanup(
              maps:remove(Reference, Pending), Seen, Deadline);
        {trace, _Port, _Event, _Detail, _Extra} ->
            await_descendant_cleanup(Pending, Seen, Deadline);
        {trace, _Pid, _Event, _Detail} ->
            await_descendant_cleanup(Pending, Seen, Deadline);
        {trace, _Pid, _Event} ->
            await_descendant_cleanup(Pending, Seen, Deadline)
    after Wait ->
        case map_size(Pending) of
            0 -> ok;
            _ -> abandon_descendant_cleanup(Pending, Seen)
        end
    end.

abandon_descendant_cleanup(Pending, Seen) ->
    maps:foreach(fun(Reference, _Pid) ->
        erlang:demonitor(Reference, [flush])
    end, Pending),
    maps:foreach(fun(Tracee, _Present) ->
        disable_trace(Tracee),
        exit(Tracee, kill)
    end, Seen),
    {error, descendant_cleanup_timeout}.

cleanup_result(ok, Result) -> Result;
cleanup_result({error, descendant_cleanup_timeout}, _Result) ->
    {crashed,
     {caught_error, <<"infrastructure">>,
      <<"test process cleanup did not settle within 1000 ms">>,
      none, none, none, none}}.

disable_trace(Pid) ->
    try
        erlang:trace(Pid, false, [all]),
        ok
    catch
        error:badarg -> ok
    end.

finish_capture(Collector, Result, OutputLimit) ->
    FinalResult = case kangaroo_coverage_probe_ffi:flush() of
        nil -> Result;
        {error, Failure} -> coverage_failure_result(Failure)
    end,
    Reference = make_ref(),
    Collector ! {kangaroo_take_output, self(), Reference},
    receive
        {Reference, _Stdout, _Stderr, true} ->
            delete_collector(Collector),
            Collector ! kangaroo_stop,
            {captured_isolation, output_limit_result(OutputLimit), <<>>, <<>>};
        {Reference, Stdout, Stderr, false} ->
            delete_collector(Collector),
            Collector ! kangaroo_stop,
            {captured_isolation, FinalResult, Stdout, Stderr}
    after 1000 ->
        delete_collector(Collector),
        exit(Collector, kill),
        {captured_isolation, collector_failure_result(), <<>>, <<>>}
    end.

coverage_failure_result(Message) ->
    {crashed,
     {caught_error, <<"infrastructure">>,
      <<"coverage persistence failed: ", Message/binary>>,
      none, none, none, none}}.

collector_failure_result() ->
    {crashed,
     {caught_error, <<"infrastructure">>,
      <<"test output collector stopped before publishing captured output">>,
      none, none, none, none}}.

output_limit_result(OutputLimit) ->
    {crashed,
     {caught_error, <<"infrastructure">>,
      <<"test output exceeded ", (integer_to_binary(OutputLimit))/binary,
        " bytes">>,
      none, none, none, none}}.

delete_collector(Collector) ->
    try ets:delete(kangaroo_output_collectors, Collector)
    catch error:badarg -> false
    end,
    ok.

ensure_stderr_proxy() ->
    Key = {?MODULE, stderr_proxy},
    case persistent_term:get(Key, undefined) of
        Proxy when is_pid(Proxy) ->
            case stderr_proxy_healthy(Proxy) of
                true -> ok;
                false ->
                    persistent_term:erase(Key),
                    install_stderr_proxy(Key)
            end;
        _ -> install_stderr_proxy(Key)
    end.

stderr_proxy_healthy(Proxy) ->
    is_process_alive(Proxy)
        andalso whereis(standard_error) =:= Proxy
        andalso ets:whereis(kangaroo_output_collectors) =/= undefined.

install_stderr_proxy(Key) ->
    Parent = self(),
    Installer = spawn(fun stderr_proxy_installer/0),
    Registration =
        try register(kangaroo_stderr_proxy_installer, Installer)
        catch error:badarg -> false
        end,
    case Registration of
        true ->
            Installer ! {kangaroo_install, Parent, Key},
            receive
                {kangaroo_stderr_installed, Installer} -> ok;
                {kangaroo_stderr_install_failed, Installer, Reason} ->
                    erlang:error(Reason)
            after 5000 ->
                exit(Installer, kill),
                unregister_stderr_installer(Installer),
                erlang:error(kangaroo_stderr_install_timeout)
            end;
        _ ->
            exit(Installer, kill),
            wait_for_stderr_proxy(Key, 5000)
    end.

stderr_proxy_installer() ->
    receive
        {kangaroo_install, Parent, Key} ->
            OriginalKey = {?MODULE, stderr_original},
            Original = case persistent_term:get(OriginalKey, undefined) of
                Stored when is_pid(Stored); is_port(Stored) -> Stored;
                _ -> whereis(standard_error)
            end,
            Installer = self(),
            Proxy = spawn(fun() ->
                              case ensure_output_collectors_table(4000) of
                                  ok ->
                                      Installer !
                                        {kangaroo_stderr_table_ready, self()},
                                      stderr_proxy(Original);
                                  {error, Reason} ->
                                      Installer !
                                        {kangaroo_stderr_table_failed,
                                         self(), Reason}
                              end
                          end),
            receive
                {kangaroo_stderr_table_ready, Proxy} ->
                    case whereis(standard_error) of
                        undefined -> ok;
                        _ -> true = unregister(standard_error)
                    end,
                    true = register(standard_error, Proxy),
                    persistent_term:put(OriginalKey, Original),
                    persistent_term:put(Key, Proxy),
                    Parent ! {kangaroo_stderr_installed, self()},
                    unregister_stderr_installer(self());
                {kangaroo_stderr_table_failed, Proxy, Reason} ->
                    Parent ! {kangaroo_stderr_install_failed, self(), Reason},
                    unregister_stderr_installer(self())
            after 4000 ->
                exit(Proxy, kill),
                Parent ! {kangaroo_stderr_install_failed, self(),
                          kangaroo_stderr_table_timeout},
                unregister_stderr_installer(self())
            end
    end.

ensure_output_collectors_table(Remaining) when Remaining =< 0 ->
    {error, kangaroo_stderr_table_timeout};
ensure_output_collectors_table(Remaining) ->
    case ets:whereis(kangaroo_output_collectors) of
        undefined ->
            try
                _ = ets:new(kangaroo_output_collectors,
                            [named_table, public, set,
                             {read_concurrency, true}]),
                ok
            catch
                error:badarg ->
                    receive after 1 -> ok end,
                    ensure_output_collectors_table(Remaining - 1)
            end;
        Table ->
            case ets:info(Table, owner) of
                Owner when is_pid(Owner), Owner =/= self() ->
                    exit(Owner, kill);
                _ -> ok
            end,
            receive after 1 -> ok end,
            ensure_output_collectors_table(Remaining - 1)
    end.

unregister_stderr_installer(Installer) ->
    case whereis(kangaroo_stderr_proxy_installer) of
        Installer ->
            try unregister(kangaroo_stderr_proxy_installer)
            catch error:badarg -> false
            end;
        _ -> false
    end,
    ok.

wait_for_stderr_proxy(_Key, Remaining) when Remaining =< 0 ->
    erlang:error(kangaroo_stderr_install_timeout);
wait_for_stderr_proxy(Key, Remaining) ->
    case persistent_term:get(Key, undefined) of
        Proxy when is_pid(Proxy) ->
            case stderr_proxy_healthy(Proxy) of
                true -> ok;
                false ->
                    receive after 1 -> ok end,
                    wait_for_stderr_proxy(Key, Remaining - 1)
            end;
        _ ->
            receive after 1 -> ok end,
            wait_for_stderr_proxy(Key, Remaining - 1)
    end.

stderr_proxy(Original) ->
    receive
        Request = {io_request, From, ReplyAs, IoRequest}
          when is_pid(From) ->
            Leader = case process_info(From, group_leader) of
                         {group_leader, Value} -> Value;
                         _ -> undefined
                     end,
            case is_pid(Leader)
                 andalso ets:member(kangaroo_output_collectors, Leader) of
                true ->
                    Leader ! {kangaroo_stderr_request, From, ReplyAs,
                              IoRequest};
                false when is_pid(Original); is_port(Original) ->
                    Original ! Request;
                false ->
                    From ! {io_reply, ReplyAs, {error, terminated}}
            end,
            stderr_proxy(Original);
        Request ->
            case is_pid(Original) orelse is_port(Original) of
                true -> Original ! Request;
                false -> ok
            end,
            stderr_proxy(Original)
    end.

output_collector(Stdout, Stderr, Bytes, Exceeded, OutputLimit) ->
    receive
        {io_request, From, ReplyAs, Request} ->
            {Reply, Text} = render_io_request(Request),
            From ! {io_reply, ReplyAs, Reply},
            {NextStdout, NextBytes, NextExceeded} =
                capture_output(Text, Stdout, Bytes, Exceeded, OutputLimit),
            output_collector(NextStdout, Stderr,
                             NextBytes, NextExceeded, OutputLimit);
        {kangaroo_stderr_request, From, ReplyAs, Request} ->
            {Reply, Text} = render_io_request(Request),
            From ! {io_reply, ReplyAs, Reply},
            {NextStderr, NextBytes, NextExceeded} =
                capture_output(Text, Stderr, Bytes, Exceeded, OutputLimit),
            output_collector(Stdout, NextStderr,
                             NextBytes, NextExceeded, OutputLimit);
        {kangaroo_take_output, From, Reference} ->
            From ! {Reference, combine_output(Stdout), combine_output(Stderr),
                    Exceeded},
            output_collector(Stdout, Stderr, Bytes, Exceeded, OutputLimit);
        kangaroo_stop ->
            ok;
        _Other ->
            output_collector(Stdout, Stderr, Bytes, Exceeded, OutputLimit)
    end.

capture_output(_Text, Output, Bytes, true, _OutputLimit) ->
    {Output, Bytes, true};
capture_output(<<>>, Output, Bytes, false, _OutputLimit) ->
    {Output, Bytes, false};
capture_output(Text, Output, Bytes, false, OutputLimit) ->
    NextBytes = Bytes + byte_size(Text),
    case NextBytes =< OutputLimit of
        true -> {[Text | Output], NextBytes, false};
        false -> {Output, Bytes, true}
    end.

combine_output(Output) ->
    iolist_to_binary(lists:reverse(Output)).

render_io_request({put_chars, _Encoding, Characters}) ->
    {ok, characters_to_binary(Characters)};
render_io_request({put_chars, _Encoding, Module, Function, Arguments}) ->
    try {ok, characters_to_binary(apply(Module, Function, Arguments))}
    catch _:_ -> {{error, request}, <<>>}
    end;
render_io_request({put_chars, Characters}) ->
    {ok, characters_to_binary(Characters)};
render_io_request({requests, Requests}) ->
    render_io_requests(Requests, []);
render_io_request(_Request) ->
    {{error, enotsup}, <<>>}.

render_io_requests([], Output) ->
    {ok, iolist_to_binary(lists:reverse(Output))};
render_io_requests([Request | Rest], Output) ->
    case render_io_request(Request) of
        {ok, Text} -> render_io_requests(Rest, [Text | Output]);
        {Error, _} -> {Error, <<>>}
    end.

characters_to_binary(Characters) ->
    try unicode:characters_to_binary(Characters)
    catch _:_ -> iolist_to_binary(Characters)
    end.

panic_name(#{gleam_error := panic}) ->
    <<"panic">>;
panic_name(#{gleam_error := assert}) ->
    <<"assert">>;
panic_name(#{gleam_error := let_assert}) ->
    <<"let_assert">>;
panic_name(_Reason) ->
    <<"error">>.

error_message(Reason = #{gleam_error := assert,
                         kind := binary_operator,
                         operator := Operator,
                         left := #{value := Left},
                         right := #{value := Right}}, _Stack) ->
    append_expression(
      <<(inspect(Left))/binary, " ", (atom_to_binary(Operator, utf8))/binary,
        " ", (inspect(Right))/binary, "\nAssertion failed">>,
      source_expression(Reason));
error_message(Reason = #{gleam_error := assert,
                         value := Value}, _Stack) ->
    append_expression(
      <<"assert ", (inspect(Value))/binary, "\nAssertion failed">>,
      source_expression(Reason));
error_message(Reason = #{gleam_error := assert,
                         expression := #{value := Value}}, _Stack) ->
    append_expression(
      <<"assert ", (inspect(Value))/binary, "\nAssertion failed">>,
      source_expression(Reason));
error_message(Reason = #{gleam_error := let_assert,
                         value := Value}, _Stack) ->
    append_expression(
      <<"let assert did not match: ", (inspect(Value))/binary>>,
      source_expression(Reason));
error_message(#{message := Message}, _Stack) ->
    to_binary(Message);
error_message(Reason, Stack) ->
    to_binary(io_lib:format("~0p ~p", [Reason, Stack])).

error_location(#{file := File, line := Line}, Stack)
  when is_integer(Line), Line > 0 ->
    Prefix = <<(to_binary(File))/binary, ":", (integer_to_binary(Line))/binary>>,
    kangaroo@location:from_erlang_stack(
      <<Prefix/binary, "\n", (stack_text(Stack))/binary>>);
error_location(_Reason, Stack) ->
    kangaroo@location:from_erlang_stack(stack_text(Stack)).

inspect(Value) ->
    gleam@string:inspect(Value).

assertion_fields(#{gleam_error := assert,
                   kind := binary_operator,
                   left := #{value := Left},
                   right := #{value := Right}}) ->
    {{some, inspect(Right)}, {some, inspect(Left)}, assertion_diff(Right, Left)};
assertion_fields(_) ->
    {none, none, none}.

assertion_diff(Expected, Actual) when is_binary(Expected), is_binary(Actual) ->
    kangaroo@diff:diff_lines(Expected, Actual);
assertion_diff(Expected, Actual) when is_list(Expected), is_list(Actual) ->
    kangaroo@diff:diff_lines(list_lines(Expected), list_lines(Actual));
assertion_diff(_, _) ->
    none.

list_lines(Values) ->
    iolist_to_binary(lists:join(<<"\n">>, [inspect(Value) || Value <- Values])).

source_expression(Reason = #{file := File, start := DefaultStart, 'end' := End})
  when is_integer(DefaultStart), is_integer(End), End >= DefaultStart ->
    try
        Start = maps:get(expression_start, Reason, DefaultStart),
        case file:read_file(File) of
            {ok, Source}
              when is_integer(Start), Start >= 0, End >= Start,
                   End =< byte_size(Source) ->
                string:trim(binary:part(Source, Start, End - Start));
            _ -> <<>>
        end
    catch
        _:_ -> <<>>
    end;
source_expression(_) ->
    <<>>.

append_expression(Message, <<>>) -> Message;
append_expression(Message, Expression) ->
    <<Message/binary, "\nexpression: ", Expression/binary>>.

stack_text(Stack) ->
    Lines = [frame_line(F) || F <- Stack],
    NonEmpty = [L || L <- Lines, L =/= <<>>],
    iolist_to_binary(lists:join(<<"\n">>, NonEmpty)).

frame_line({_Module, _Function, _Arity, Info}) when is_list(Info) ->
    case lists:keyfind(file, 1, Info) of
        {file, File} ->
            Line = case lists:keyfind(line, 1, Info) of
                       {line, L} -> L;
                       false -> 1
                   end,
            unicode:characters_to_binary(
                io_lib:format("~ts:~p", [to_binary(File), Line]));
        false ->
            <<>>
    end;
frame_line(_) ->
    <<>>.

to_binary(Value) when is_binary(Value) ->
    Value;
to_binary(Value) when is_list(Value) ->
    unicode:characters_to_binary(Value);
to_binary(Value) ->
    unicode:characters_to_binary(io_lib:format("~0p", [Value])).
