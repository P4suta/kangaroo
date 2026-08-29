-module(kangaroo_coverage_probe_ffi).
-export([hit/2, flush/0, ensure_started/0]).

-define(WRITER, kangaroo_coverage_probe_writer).
-define(BATCH_SIZE, 128).

hit(Path, Line) ->
    case writer() of
        undefined -> ok;
        Writer ->
            Writer ! {hit, [Path, <<"\t">>, integer_to_binary(Line), <<"\n">>]}
    end,
    nil.

ensure_started() ->
    _ = writer(),
    nil.

flush() ->
    case whereis(?WRITER) of
        undefined -> nil;
        Writer ->
            Reference = make_ref(),
            Writer ! {flush, self(), Reference},
            receive
                {Reference, flushed} -> nil
            after 1000 -> nil
            end
    end.

writer() ->
    case whereis(?WRITER) of
        undefined -> start_writer();
        Writer -> Writer
    end.

start_writer() ->
    Parent = self(),
    Candidate = spawn(fun() -> initialise_writer(Parent) end),
    receive
        {Candidate, ready} -> Candidate;
        {Candidate, existing, Existing} -> Existing
    after 1000 -> undefined
    end.

initialise_writer(Parent) ->
    try register(?WRITER, self()) of
        true ->
            Device = case os:getenv("KANGAROO_COVERAGE_FILE") of
                false -> undefined;
                File ->
                    case file:open(File, [append, raw, binary]) of
                        {ok, Opened} -> Opened;
                        {error, _} -> undefined
                    end
            end,
            Parent ! {self(), ready},
            writer_loop(Device, [], 0)
    catch
        error:badarg ->
            Parent ! {self(), existing, whereis(?WRITER)}
    end.

writer_loop(Device, Records, Count) ->
    receive
        {hit, Record} when Count + 1 >= ?BATCH_SIZE ->
            write_records(Device, lists:reverse([Record | Records])),
            writer_loop(Device, [], 0);
        {hit, Record} ->
            writer_loop(Device, [Record | Records], Count + 1);
        {flush, From, Reference} ->
            write_records(Device, lists:reverse(Records)),
            From ! {Reference, flushed},
            writer_loop(Device, [], 0)
    end.

write_records(undefined, _Records) -> ok;
write_records(_Device, []) -> ok;
write_records(Device, Records) ->
    _ = file:write(Device, Records),
    ok.
