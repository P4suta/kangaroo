%% Resolves indexed Gleam test functions without turning arbitrary source
%% names into executable expressions. Module/function atoms come only from
%% compiler-validated source indexes.
-module(kangaroo_runtime_ffi).
-export([resolve_export/2]).

resolve_export(ModuleName, FunctionName) ->
    Module = module_atom(ModuleName),
    Function = binary_to_atom(FunctionName, utf8),
    %% Watch builds replace beam files in place. Reload between generations
    %% once no previous test process is using the module.
    _ = code:soft_purge(Module),
    Loaded = case code:load_file(Module) of
                 {module, Module} = Success -> Success;
                 _ -> code:ensure_loaded(Module)
             end,
    case Loaded of
        {module, Module} ->
            case erlang:function_exported(Module, Function, 0) of
                true -> {ok, fun() -> erlang:apply(Module, Function, []) end};
                false -> {error, <<"not_exported">>}
            end;
        _ ->
            {error, <<"module_not_loaded">>}
    end.

module_atom(Name) when is_binary(Name) ->
    binary_to_atom(binary:replace(Name, <<"/">>, <<"@">>, [global]), utf8).
