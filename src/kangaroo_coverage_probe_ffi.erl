-module(kangaroo_coverage_probe_ffi).
-export([hit/2]).

hit(Path, Line) ->
    case os:getenv("KANGAROO_COVERAGE_FILE") of
        false -> ok;
        File ->
            Record = [Path, <<"\t">>, integer_to_binary(Line), <<"\n">>],
            _ = file:write_file(File, Record, [append, raw]),
            ok
    end,
    nil.
