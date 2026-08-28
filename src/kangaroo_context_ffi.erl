%% Collects matcher failures for the currently running test case.
%%
%% On Erlang each test case runs in its own freshly spawned process, so the
%% process dictionary provides a natural per-case storage.
-module(kangaroo_context_ffi).
-export([record/1, collect/0]).

-define(KEY, kangaroo_failures).

record(Failure) ->
    Failures = case get(?KEY) of
                   undefined -> [];
                   Existing -> Existing
               end,
    put(?KEY, [Failure | Failures]),
    ok.

%% Collects the failures recorded so far, clearing the storage. Draining
%% keeps nested runs (e.g. a case that itself runs cases) from leaking
%% failures into the outer context.
collect() ->
    Failures = case get(?KEY) of
                   undefined -> [];
                   Existing -> Existing
               end,
    erase(?KEY),
    lists:reverse(Failures).
