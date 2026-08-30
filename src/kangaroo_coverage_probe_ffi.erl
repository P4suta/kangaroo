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
        undefined ->
            case os:getenv("KANGAROO_COVERAGE_FILE") of
                false -> nil;
                _ -> {error, <<"coverage probe writer is unavailable">>}
            end;
        Writer ->
            Reference = make_ref(),
            Writer ! {flush, self(), Reference},
            receive
                {Reference, flushed} -> nil;
                {Reference, {failed, Message}} -> {error, Message}
            after 1000 ->
                {error, <<"coverage probe flush timed out after 1000 ms">>}
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
                false -> disabled;
                File ->
                    case file:open(File, [append, raw, binary]) of
                        {ok, Opened} -> {open, Opened};
                        {error, Reason} ->
                            {failed, persistence_error("open", Reason)}
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
            NextDevice =
                write_records(Device, lists:reverse([Record | Records])),
            writer_loop(NextDevice, [], 0);
        {hit, Record} ->
            writer_loop(Device, [Record | Records], Count + 1);
        {flush, From, Reference} ->
            NextDevice = write_records(Device, lists:reverse(Records)),
            Reply = case NextDevice of
                {failed, Message} -> {failed, Message};
                _ -> flushed
            end,
            From ! {Reference, Reply},
            writer_loop(NextDevice, [], 0)
    end.

write_records(disabled, _Records) -> disabled;
write_records({failed, _} = Failed, _Records) -> Failed;
write_records(Device, []) -> Device;
write_records({open, Device} = Open, Records) ->
    case file:write(Device, Records) of
        ok -> Open;
        {error, Reason} ->
            _ = file:close(Device),
            {failed, persistence_error("write", Reason)}
    end.

persistence_error(Action, Reason) ->
    unicode:characters_to_binary(
      io_lib:format("could not ~s coverage probe file: ~tp",
                    [Action, Reason])).
