-module(kangaroo_watch_fixture_ffi).
-export([delay/0]).

delay() ->
    timer:sleep(5000),
    nil.
