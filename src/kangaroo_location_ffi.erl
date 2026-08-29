%% Captures the source location of the caller by throwing a synthetic
%% exception and parsing its stack. The relevant frame is picked by the
%% pure `kangaroo@location` module.
-module(kangaroo_location_ffi).
-export([capture/0]).

capture() ->
    Stack = try throw(location_capture) of
                _ -> []
            catch
                throw:location_capture:Trace -> Trace
            end,
    Text = stack_text(Stack),
    kangaroo@location:from_erlang_stack(Text).

%% Serializes the structured stack into one `file:line` line per frame, the
%% textual format consumed by `kangaroo@location:from_erlang_stack/1`.
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
