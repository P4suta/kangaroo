-module(coverage_probe_test_ffi).
-export([hit_unwritable_target/0]).

hit_unwritable_target() ->
    Original = os:getenv("KANGAROO_COVERAGE_FILE"),
    true = os:putenv("KANGAROO_COVERAGE_FILE", "."),
    try kangaroo_coverage_probe_ffi:hit(<<"src/example.gleam">>, 1)
    after restore("KANGAROO_COVERAGE_FILE", Original)
    end.

restore(Name, false) -> os:unsetenv(Name);
restore(Name, Value) -> os:putenv(Name, Value).
