-module(coverage_probe_test_ffi).
-export([begin_unwritable_probe_capture/0,
         complete_unwritable_probe_capture/0,
         begin_probe_capture/0, complete_probe_capture/1]).

begin_unwritable_probe_capture() ->
    stop_writer(),
    Original = os:getenv("KANGAROO_COVERAGE_FILE"),
    put(kangaroo_unwritable_probe_original_environment, Original),
    true = os:putenv("KANGAROO_COVERAGE_FILE", "."),
    nil.

complete_unwritable_probe_capture() ->
    stop_writer(),
    restore("KANGAROO_COVERAGE_FILE",
            erase(kangaroo_unwritable_probe_original_environment)),
    nil.

begin_probe_capture() ->
    stop_writer(),
    Original = os:getenv("KANGAROO_COVERAGE_FILE"),
    put(kangaroo_probe_original_environment, Original),
    Temp = case os:getenv("TMPDIR") of false -> "/tmp"; Value -> Value end,
    Path = filename:join(
             Temp,
             "kangaroo-probe-causal-" ++
             integer_to_list(erlang:unique_integer([positive, monotonic]))),
    ok = file:write_file(Path, <<>>),
    true = os:putenv("KANGAROO_COVERAGE_FILE", Path),
    unicode:characters_to_binary(Path).

complete_probe_capture(Path) ->
    stop_writer(),
    Contents = case file:read_file(Path) of
                   {ok, Value} -> Value;
                   {error, Reason} -> erlang:error(Reason)
               end,
    restore("KANGAROO_COVERAGE_FILE",
            erase(kangaroo_probe_original_environment)),
    ok = file:delete(Path),
    Contents.

stop_writer() ->
    case whereis(kangaroo_coverage_probe_writer) of
        undefined -> ok;
        Writer ->
            exit(Writer, kill),
            wait_for_writer(Writer, 1000)
    end.

wait_for_writer(_Writer, 0) -> ok;
wait_for_writer(Writer, Remaining) ->
    case is_process_alive(Writer) of
        false -> ok;
        true -> timer:sleep(1), wait_for_writer(Writer, Remaining - 1)
    end.

restore(Name, false) -> os:unsetenv(Name);
restore(Name, Value) -> os:putenv(Name, Value).
