%% Resolves indexed Gleam test functions without turning arbitrary source
%% names into executable expressions. Module/function atoms come only from
%% compiler-validated source indexes.
-module(kangaroo_runtime_ffi).
-export([resolve_export/2, reload_modules/1]).

reload_modules(ModuleNames) ->
    reload_module_list(ModuleNames).

reload_module_list([]) -> {ok, nil};
reload_module_list([ModuleName | Rest]) ->
    Module = module_atom(ModuleName),
    _ = code:soft_purge(Module),
    Loaded = case code:load_file(Module) of
                 {module, Module} = Success -> Success;
                 _ -> code:ensure_loaded(Module)
    end,
    case Loaded of
        {module, Module} -> reload_module_list(Rest);
        _ -> {error, <<"module_not_loaded">>}
    end.

resolve_export(ModuleName, FunctionName) ->
    Module = module_atom(ModuleName),
    Function = binary_to_atom(FunctionName, utf8),
    Loaded = code:ensure_loaded(Module),
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
