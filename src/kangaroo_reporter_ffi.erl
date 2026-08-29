-module(kangaroo_reporter_ffi).
-export([append/1, take/0, append_output/3, take_output/0]).

-define(KEY, kangaroo_reporter_cases).
-define(OUTPUT_KEY, kangaroo_reporter_output).

append(Case) ->
    Existing = case get(?KEY) of undefined -> []; Cases -> Cases end,
    put(?KEY, [Case | Existing]),
    nil.

take() ->
    Cases = case get(?KEY) of undefined -> []; Existing -> lists:reverse(Existing) end,
    erase(?KEY),
    Cases.

append_output(CaseName, Stdout, Stderr) ->
    Existing = case get(?OUTPUT_KEY) of undefined -> []; Output -> Output end,
    put(?OUTPUT_KEY, [{CaseName, Stdout, Stderr} | Existing]),
    nil.

take_output() ->
    Output = case get(?OUTPUT_KEY) of
                 undefined -> [];
                 Existing -> lists:reverse(Existing)
             end,
    erase(?OUTPUT_KEY),
    Output.
