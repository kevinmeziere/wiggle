%% Feel free to use, reuse and abuse the code in this file.

%% @doc Hello world handler.

-module(wiggle_vm_handler).

-include("wiggle.hrl").

-export([allowed_methods/3,
         get/1,
         permission_required/1,
         handle_request/2,
         create_path/3,
         handle_write/3,
         delete_resource/2]).

-ignore_xref([allowed_methods/3,
              get/1,
              permission_required/1,
              handle_request/2,
              create_path/3,
              handle_write/3,
              delete_resource/2]).

allowed_methods(_Version, _Token, []) ->
    [<<"GET">>, <<"POST">>];

allowed_methods(_Version, _Token, [_Vm]) ->
    [<<"GET">>, <<"PUT">>, <<"DELETE">>];

allowed_methods(_Version, _Token, [_Vm, <<"metadata">>|_]) ->
    [<<"PUT">>, <<"DELETE">>];

allowed_methods(_Version, _Token, [_Vm, <<"snapshots">>, _ID]) ->
    [<<"GET">>, <<"PUT">>, <<"DELETE">>];

allowed_methods(_Version, _Token, [_Vm, <<"snapshots">>]) ->
    [<<"GET">>, <<"POST">>].

get(#state{path = [Vm, <<"snapshots">>, Snap]}) ->
    case get(State#state{path=[Vm]}) of
        {ok, Obj} ->
            case jsxd:get([<<"snapshots">>, Snap], Obj) of
                undefined -> not_found;
                {ok, _} -> Obj
            end;
    end;

get(#state{path = [Vm | _]}) ->
    Start = now(),
    R = libsniffle:vm_get(Vm),
    ?MSniffle(?P(State), Start),
    R.

permission_required(Req, State = #state{method = <<"GET">>, path = []}) ->
    {ok, [<<"cloud">>, <<"vms">>, <<"list">>]};

permission_requried(#state{method = <<"POST">>, path = []}) ->
    {ok, [<<"cloud">>, <<"vms">>, <<"create">>]};

permission_requried(#state{method = <<"GET">>, path = [Vm]}) ->
    {ok, [<<"vms">>, Vm, <<"get">>]};

permission_requried(#state{method = <<"DELETE">>, path = [Vm]}) ->
    {ok, [<<"vms">>, Vm, <<"delete">>]), Req, State};

permission_requried(#state{method = <<"GET">>, path = [Vm, <<"snapshots">>]}) ->
    {ok, [<<"vms">>, Vm, <<"get">>]};

permission_requried(#state{method = <<"POST">>, path = [Vm, <<"snapshots">>]}) ->
    {ok, [<<"vms">>, Vm, <<"snapshot">>]};

permission_requried(#state{method = <<"GET">>, path = [Vm, <<"snapshots">>, _Snap]}) ->
    {ok, [<<"vms">>, Vm, <<"get">>]};

permission_requried(#state{method = <<"PUT">>,
                           body = undefiend}) ->
    {error, needs_decode};

permission_requried(#state{method = <<"PUT">>,
                           body = Decoded,
                           path = [Vm]}) ->
    case Decoded of
        [{<<"action">>, <<"start">>}] ->
            {ok, [<<"vms">>, Vm, <<"start">>]};
        [{<<"action">>, <<"stop">>}|_] ->
            {ok, [<<"vms">>, Vm, <<"stop">>]};
        [{<<"action">>, <<"reboot">>}|_] ->
            {ok, [<<"vms">>, Vm, <<"reboot">>]};
        _ ->
            {ok, [<<"vms">>, Vm, <<"edit">>]}
    end;

permission_requried(#state{method = <<"PUT">>,
                           body = Decoded,
                           path = [Vm, <<"snapshots">>, _Snap]}) ->
    case Decoded of
        [{<<"action">>, <<"rollback">>}] ->
            {ok, [<<"vms">>, Vm, <<"rollback">>]};
        _ ->
            {ok, [<<"vms">>, Vm, <<"edit">>]}
    end;

permission_requried(#state{method = <<"PUT">>,
                           body = Decoded,
                           path = [Vm, <<"metadata">> | _]}) ->
    {ok, [<<"vms">>, Vm, <<"edit">>]), Req1, State#state{body=Decoded}};

permission_requried(#state{method = <<"DELETE">>, path = [Vm, <<"snapshots">>, _Snap]}) ->
    {ok, [<<"vms">>, Vm, <<"snapshot_delete">>]};

permission_requried(#state{method = <<"DELETE">>, path = [Vm, <<"metadata">> | _]}) ->
    {ok, [<<"vms">>, Vm, <<"edit">>]};

permission_requried(State) ->
    undefined.

%%--------------------------------------------------------------------
%% GET
%%--------------------------------------------------------------------


handle_request(Req, State = #state{token = Token, path = []}) ->
    Start = now(),
    {ok, Permissions} = libsnarl:user_cache({token, Token}),
    ?MSnarl(?P(State), Start),
    Start1 = now(),
    {ok, Res} = libsniffle:vm_list([{must, 'allowed', [<<"vms">>, {<<"res">>, <<"uuid">>}, <<"get">>], Permissions}]),
    ?MSniffle(?P(State), Start1),
    {lists:map(fun ({E, _}) -> E end,  Res), Req, State};

handle_request(Req, State = #state{path = [_Vm, <<"snapshots">>], obj = Obj}) ->
    Snaps = jsxd:fold(fun(UUID, Snap, Acc) ->
                              [jsxd:set(<<"uuid">>, UUID, Snap) | Acc]
                      end, [], jsxd:get(<<"snapshots">>, [], Obj)),
    {Snaps, Req, State};

handle_request(Req, State = #state{path = [_Vm, <<"snapshots">>, Snap], obj = Obj}) ->
    {jsxd:get([<<"snapshots">>, Snap], null, Obj), Req, State};

handle_request(Req, State = #state{path = [_Vm], obj = Obj}) ->
    {Obj, Req, State}.


%%--------------------------------------------------------------------
%% PUT
%%--------------------------------------------------------------------

create_path(Req, State = #state{path = [], version = Version, token = Token}, Decoded) ->
    try
        {ok, Dataset} = jsxd:get(<<"dataset">>, Decoded),
        {ok, Package} = jsxd:get(<<"package">>, Decoded),
        {ok, Config} = jsxd:get(<<"config">>, Decoded),
        try
            {ok, User} = libsnarl:user_get({token, Token}),
            {ok, Owner} = jsxd:get(<<"uuid">>, User),
            Start = now(),
            {ok, UUID} = libsniffle:create(Package, Dataset, jsxd:set(<<"owner">>, Owner, Config)),
            ?MSniffle(?P(State), Start),
            {<<"/api/", Version/binary, "/vms/", UUID/binary>>, Req1, State#state{body = Decoded}}
        catch
            G:E ->
                lager:error("Error creating VM(~p): ~p / ~p", [Decoded, G, E]),
                {ok, Req2} = cowboy_req:reply(500, Req1),
                {halt, Req2, State}
        end
    catch
        G1:E1 ->
            lager:error("Error creating VM(~p): ~p / ~p", [Decoded, G1, E1]),
            {ok, Req3} = cowboy_req:reply(400, Req1),
            {halt, Req3, State}
    end;

create_path(Req, State = #state{path = [Vm, <<"snapshots">>], version = Version}, Decoded) ->
    Comment = jsxd:get(<<"comment">>, <<"">>, Decoded),
    Start = now(),
    {ok, UUID} = libsniffle:vm_snapshot(Vm, Comment),
    ?MSniffle(?P(State), Start),
    {<<"/api/", Version/binary, "/vms/", Vm/binary, "/snapshots/", UUID/binary>>, Req1, State#state{body = Decoded}}.

handle_write(Req, State = #state{path = [Vm, <<"metadata">> | Path]}, [{K, V}]) ->
    Start = now(),
    libsniffle:vm_set(Vm, [<<"metadata">> | Path] ++ [K], jsxd:from_list(V)),
    ?MSniffle(?P(State), Start),
    {true, Req, State};

handle_write(Req, State = #state{path = [Vm]}, [{<<"action">>, <<"start">>}]) ->
    Start = now(),
    libsniffle:vm_start(Vm),
    ?MSniffle(?P(State), Start),
    {true, Req, State};

handle_write(Req, State = #state{path = [Vm]}, [{<<"action">>, <<"stop">>}]) ->
    Start = now(),
    libsniffle:vm_stop(Vm),
    ?MSniffle(?P(State), Start),
    {true, Req, State};

handle_write(Req, State = #state{path = [Vm]}, [{<<"action">>, <<"stop">>}, {<<"force">>, true}]) ->
    Start = now(),
    libsniffle:vm_stop(Vm, [force]),
    ?MSniffle(?P(State), Start),
    {true, Req, State};

handle_write(Req, State = #state{path = [Vm]}, [{<<"action">>, <<"reboot">>}]) ->
    Start = now(),
    libsniffle:vm_reboot(Vm),
    ?MSniffle(?P(State), Start),
    {true, Req, State};

handle_write(Req, State = #state{path = [Vm]}, [{<<"action">>, <<"reboot">>}, {<<"force">>, true}]) ->
    Start = now(),
    libsniffle:vm_reboot(Vm, [force]),
    ?MSniffle(?P(State), Start),
    {true, Req, State};

handle_write(Req, State = #state{path = [Vm]}, [{<<"config">>, Config},
                                                {<<"package">>, Package}]) ->
    Start = now(),
    libsniffle:vm_update(Vm, Package, Config),
    ?MSniffle(?P(State), Start),
    {true, Req, State};

handle_write(Req, State = #state{path = [Vm]}, [{<<"config">>, Config}]) ->
    Start = now(),
    libsniffle:vm_update(Vm, undefined, Config),
    ?MSniffle(?P(State), Start),
    {true, Req, State};

handle_write(Req, State = #state{path = [Vm]}, [{<<"package">>, Package}]) ->
    Start = now(),
    libsniffle:vm_update(Vm, Package, []),
    ?MSniffle(?P(State), Start),
    {true, Req, State};

handle_write(Req, State = #state{path = []}, _Body) ->
    {true, Req, State};

handle_write(Req, State = #state{path = [_Vm, <<"snapshots">>]}, _Body) ->
    {true, Req, State};

handle_write(Req, State = #state{path = [Vm, <<"snapshots">>, UUID]}, [{<<"action">>, <<"rollback">>}]) ->
    Start = now(),
    ok = libsniffle:vm_rollback_snapshot(Vm, UUID),
    ?MSniffle(?P(State), Start),
    {true, Req, State};

handle_write(Req, State, _Body) ->
    lager:error("Unknown PUT request: ~p~n.", [State]),
    {false, Req, State}.

%%--------------------------------------------------------------------
%% DEETE
%%--------------------------------------------------------------------

delete_resource(Req, State = #state{path = [Vm, <<"snapshots">>, UUID]}) ->
    Start = now(),
    ok = libsniffle:vm_delete_snapshot(Vm, UUID),
    ?MSniffle(?P(State), Start),
    {true, Req, State};

delete_resource(Req, State = #state{path = [Vm]}) ->
    Start = now(),
    ok = libsniffle:vm_delete(Vm),
    ?MSniffle(?P(State), Start),
    {true, Req, State};

delete_resource(Req, State = #state{path = [Vm, <<"metadata">> | Path]}) ->
    Start = now(),
    libsniffle:vm_set(Vm, [<<"metadata">> | Path], delete),
    ?MSniffle(?P(State), Start),
    {true, Req, State}.
