-module(runtime_fixture_ffi).
-export([promise_pass/0, promise_reject/0, promise_never/0,
         left_value/0, right_value/0, error_result/0,
         left_string/0, right_string/0, non_binary_assert/0, spawn_descendant/0,
         reset_descendant_marker/0, descendant_marker_exists/0]).

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

reset_descendant_marker() ->
    file:delete(descendant_marker()),
    nil.

descendant_marker_exists() ->
    filelib:is_file(descendant_marker()).

descendant_marker() ->
    Temp = case os:getenv("TMPDIR") of false -> "/tmp"; Value -> Value end,
    filename:join(Temp, "kangaroo-isolate-descendant-" ++ os:getpid() ++ ".marker").
