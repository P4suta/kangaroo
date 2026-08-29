%% Runs a test case body in a freshly spawned process so that panics and
%% stray processes cannot take down the runner, then reports the collected
%% matcher failures (or the error that was raised). The source location of
%% a crash is derived from its stack by the pure `kangaroo@location` module.
-module(kangaroo_isolate_ffi).
-export([isolate/2, isolate_captured/2]).

-define(DEFAULT_TIMEOUT_MS, 30000).

isolate(Body, Timeout) ->
    {captured_isolation, Result, _Stdout, _Stderr} =
        isolate_captured(Body, Timeout),
    Result.

isolate_captured(Body, Timeout) ->
    TimeoutMs = case Timeout of
                    {some, Ms} -> Ms;
                    none -> ?DEFAULT_TIMEOUT_MS
                end,
    ensure_stderr_proxy(),
    Collector = spawn(fun() -> output_collector([], []) end),
    true = ets:insert(kangaroo_output_collectors, {Collector}),
    Parent = self(),
    Pid = spawn(fun() ->
                        receive
                            kangaroo_start ->
                                group_leader(Collector, self()),
                                try
                                    Body(),
                                    Parent ! {kangaroo_done,
                                              kangaroo_context_ffi:collect()}
                                catch
                                    error:#{kangaroo_error := skip,
                                            reason := SkipReason}:_Stack ->
                                        Parent ! {kangaroo_skipped, SkipReason};
                                    Class:Reason:Stack ->
                                        Parent ! {kangaroo_crashed, Class,
                                                  Reason, Stack}
                                end
                        end
                end),
    disable_trace(Pid),
    1 = erlang:trace(Pid, true, [procs, set_on_spawn]),
    Pid ! kangaroo_start,
    receive
        {kangaroo_done, Failures} ->
            cleanup_descendants(Pid),
            finish_capture(Collector, {completed, Failures});
        {kangaroo_crashed, _Class, Reason, Stack} ->
            cleanup_descendants(Pid),
            {Expected, Actual, Diff} = assertion_fields(Reason),
            finish_capture(
              Collector,
              {crashed, {caught_error, panic_name(Reason),
                         error_message(Reason, Stack),
                         error_location(Reason, Stack),
                         Expected, Actual, Diff}});
        {kangaroo_skipped, Reason} ->
            cleanup_descendants(Pid),
            finish_capture(Collector, {skipped_isolation, Reason})
    after TimeoutMs ->
        exit(Pid, kill),
        cleanup_descendants(Pid),
        finish_capture(
          Collector,
          {crashed, {caught_error, <<"timeout">>,
                     <<"Test case timed out after ",
                       (integer_to_binary(TimeoutMs))/binary, " ms">>,
                     none, none, none, none}})
    end.

cleanup_descendants(Root) ->
    disable_trace(Root),
    Descendants = collect_descendants(Root, []),
    lists:foreach(fun(Pid) -> exit(Pid, kill) end,
                  lists:usort(Descendants)),
    ok.

disable_trace(Pid) ->
    try
        erlang:trace(Pid, false, [all]),
        ok
    catch
        error:badarg -> ok
    end.

collect_descendants(Root, Descendants) ->
    receive
        {trace, _Parent, spawn, Child, _Mfa} when Child =/= Root ->
            collect_descendants(Root, [Child | Descendants]);
        {trace, Child, spawned, _Parent, _Mfa} when Child =/= Root ->
            collect_descendants(Root, [Child | Descendants]);
        {trace, _Pid, _Event, _Detail} ->
            collect_descendants(Root, Descendants);
        {trace, _Pid, _Event} ->
            collect_descendants(Root, Descendants)
    after 0 ->
        Descendants
    end.

finish_capture(Collector, Result) ->
    Reference = make_ref(),
    Collector ! {kangaroo_take_output, self(), Reference},
    receive
        {Reference, Stdout, Stderr} ->
            delete_collector(Collector),
            Collector ! kangaroo_stop,
            {captured_isolation, Result, Stdout, Stderr}
    after 1000 ->
        delete_collector(Collector),
        exit(Collector, kill),
        {captured_isolation, Result, <<>>, <<>>}
    end.

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
                              ets:new(kangaroo_output_collectors,
                                      [named_table, public, set,
                                       {read_concurrency, true}]),
                              Installer ! {kangaroo_stderr_table_ready, self()},
                              stderr_proxy(Original)
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
                    unregister_stderr_installer(self())
            after 4000 ->
                exit(Proxy, kill),
                Parent ! {kangaroo_stderr_install_failed, self(),
                          kangaroo_stderr_table_timeout},
                unregister_stderr_installer(self())
            end
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

output_collector(Stdout, Stderr) ->
    receive
        {io_request, From, ReplyAs, Request} ->
            {Reply, Text} = render_io_request(Request),
            From ! {io_reply, ReplyAs, Reply},
            output_collector(append_output(Text, Stdout), Stderr);
        {kangaroo_stderr_request, From, ReplyAs, Request} ->
            {Reply, Text} = render_io_request(Request),
            From ! {io_reply, ReplyAs, Reply},
            output_collector(Stdout, append_output(Text, Stderr));
        {kangaroo_take_output, From, Reference} ->
            From ! {Reference, combine_output(Stdout), combine_output(Stderr)},
            output_collector(Stdout, Stderr);
        kangaroo_stop ->
            ok;
        _Other ->
            output_collector(Stdout, Stderr)
    end.

append_output(<<>>, Output) -> Output;
append_output(Text, Output) -> [Text | Output].

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
