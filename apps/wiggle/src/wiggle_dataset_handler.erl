%% Feel free to use, reuse and abuse the code in this file.

%% @doc Hello world handler.
-module(wiggle_dataset_handler).

-include("wiggle.hrl").

-export([init/3,
         rest_init/2]).

-export([content_types_provided/2,
         content_types_accepted/2,
         allowed_methods/2,
         resource_exists/2,
         delete_resource/2,
         forbidden/2,
         options/2,
         post_is_create/2,
         create_path/2,
         service_available/2,
         is_authorized/2,
         rest_terminate/2]).

-export([to_json/2,
         from_json/2,
         to_msgpack/2,
         from_msgpack/2]).

-ignore_xref([to_json/2,
              from_json/2,
              from_msgpack/2,
              to_msgpack/2,
              allowed_methods/2,
              content_types_accepted/2,
              content_types_provided/2,
              delete_resource/2,
              forbidden/2,
              init/3,
              post_is_create/2,
              create_path/2,
              is_authorized/2,
              options/2,
              service_available/2,
              resource_exists/2,
              rest_init/2,
              rest_terminate/2]).

init(_Transport, _Req, []) ->
    {upgrade, protocol, cowboy_rest}.

rest_init(Req, _) ->
    wiggle_handler:initial_state(Req).

rest_terminate(_Req, State) ->
    ?M(?P(State), State#state.start),
    ok.

service_available(Req, State) ->
    case {libsniffle:servers(), libsnarl:servers()} of
        {[], _} ->
            {false, Req, State};
        {_, []} ->
            {false, Req, State};
        _ ->
            {true, Req, State}
    end.

options(Req, State) ->
    Methods = allowed_methods(State#state.version, State#state.token, State#state.path),
    Req1 = cowboy_req:set_resp_header(
             <<"access-control-allow-methods">>,
             string:join(
               lists:map(fun erlang:binary_to_list/1,
                         [<<"HEAD">>, <<"OPTIONS">> | Methods]), ", "), Req),
    {ok, Req1, State}.

post_is_create(Req, State) ->
    {true, Req, State}.

content_types_provided(Req, State) ->
    {[
      {<<"application/json">>, to_json},
      {<<"application/x-msgpack">>, to_msgpack}
     ], Req, State}.

content_types_accepted(Req, State) ->
    {wiggle_handler:accepted(), Req, State}.

allowed_methods(Req, State) ->
    {[<<"HEAD">>, <<"OPTIONS">> | allowed_methods(State#state.version, State#state.token, State#state.path)], Req, State}.

allowed_methods(_Version, _Token, []) ->
    [<<"GET">>, <<"POST">>];

allowed_methods(_Version, _Token, [_Dataset]) ->
    [<<"GET">>, <<"DELETE">>, <<"PUT">>];

allowed_methods(_Version, _Token, [_Dataset, <<"metadata">>|_]) ->
    [<<"PUT">>, <<"DELETE">>].

resource_exists(Req, State = #state{path = []}) ->
    {true, Req, State};

resource_exists(Req, State = #state{path = [Dataset | _]}) ->
    Start = now(),
    case libsniffle:dataset_get(Dataset) of
        not_found ->
            ?MSniffle(?P(State), Start),
            {false, Req, State};
        {ok, Obj} ->
            ?MSniffle(?P(State), Start),
            {true, Req, State#state{obj = Obj}}
    end.

is_authorized(Req, State = #state{method = <<"OPTIONS">>}) ->
    {true, Req, State};

is_authorized(Req, State = #state{token = undefined}) ->
    {{false, <<"x-snarl-token">>}, Req, State};

is_authorized(Req, State) ->
    {true, Req, State}.

forbidden(Req, State = #state{method = <<"OPTIONS">>}) ->
    {false, Req, State};

forbidden(Req, State = #state{token = undefined}) ->
    {true, Req, State};

forbidden(Req, State = #state{method = <<"POST">>, path = []}) ->
    {wiggle_handler:allowed(State, [<<"cloud">>, <<"datasets">>, <<"create">>]), Req, State};

forbidden(Req, State = #state{path = []}) ->
    {wiggle_handler:allowed(State, [<<"cloud">>, <<"datasets">>, <<"list">>]), Req, State};


forbidden(Req, State = #state{method = <<"GET">>, path = [Dataset]}) ->
    {wiggle_handler:allowed(State, [<<"datasets">>, Dataset, <<"get">>]), Req, State};

forbidden(Req, State = #state{method = <<"PUT">>, path = [Dataset]}) ->
    {wiggle_handler:allowed(State, [<<"datasets">>, Dataset, <<"edit">>]), Req, State};

forbidden(Req, State = #state{method = <<"DELETE">>, path = [Dataset]}) ->
    {wiggle_handler:allowed(State, [<<"datasets">>, Dataset, <<"delete">>]), Req, State};

forbidden(Req, State = #state{method = <<"PUT">>, path = [Dataset, <<"metadata">> | _]}) ->
    {wiggle_handler:allowed(State, [<<"datasets">>, Dataset, <<"edit">>]), Req, State};

forbidden(Req, State = #state{method = <<"DELETE">>, path = [Dataset, <<"metadata">> | _]}) ->
    {wiggle_handler:allowed(State, [<<"datasets">>, Dataset, <<"edit">>]), Req, State};

forbidden(Req, State) ->
    {true, Req, State}.

%%--------------------------------------------------------------------
%% GET
%%--------------------------------------------------------------------

to_json(Req, State) ->
    {Reply, Req1, State1} = handle_request(Req, State),
    {jsx:encode(Reply), Req1, State1}.

to_msgpack(Req, State) ->
    {Reply, Req1, State1} = handle_request(Req, State),
    {msgpack:pack(Reply, [jsx]), Req1, State1}.

handle_request(Req, State = #state{token = Token, path = []}) ->
    Start = now(),
    {ok, Permissions} = libsnarl:user_cache({token, Token}),
    ?MSnarl(?P(State), Start),
    Start1 = now(),
    {ok, Res} = libsniffle:dataset_list([{must, 'allowed', [<<"datasets">>, {<<"res">>, <<"dataset">>}, <<"get">>], Permissions}]),
    ?MSniffle(?P(State), Start1),
    {lists:map(fun ({E, _}) -> E end,  Res), Req, State};

handle_request(Req, State = #state{path = [_Dataset], obj = Obj}) ->
    {Obj, Req, State}.

%%--------------------------------------------------------------------
%% PUT
%%--------------------------------------------------------------------

create_path(Req, State = #state{path = [], version = Version}) ->
    {ok, Decoded, Req1} = wiggle_handler:decode(Req),
    case jsxd:from_list(Decoded) of
        [{<<"url">>, URL}] ->
            Start = now(),
            {ok, UUID} = libsniffle:dataset_import(URL),
            ?MSniffle(?P(State), Start),
            {<<"/api/", Version/binary, "/datasets/", UUID/binary>>, Req1, State#state{body = Decoded}};
        [{<<"config">>, Config},
         {<<"snapshot">>, Snap},
         {<<"vm">>, Vm}] ->
            Start1 = now(),
            {ok, UUID} = libsniffle:vm_promote_snapshot(Vm, Snap, Config),
            ?MSniffle(?P(State), Start1),
            {<<"/api/", Version/binary, "/datasets/", UUID/binary>>, Req1, State#state{body = Decoded}}
    end.

from_json(Req, State) ->
    {ok, Body, Req1} = cowboy_req:body(Req),
    {Reply, Req2, State1} = case Body of
                                <<>> ->
                                    handle_write(Req1, State, []);
                                _ ->
                                    Decoded = jsx:decode(Body),
                                    handle_write(Req1, State, Decoded)
                            end,
    {Reply, Req2, State1}.

from_msgpack(Req, State) ->
    {ok, Body, Req1} = cowboy_req:body(Req),
    {Reply, Req2, State1} = case Body of
                                <<>> ->
                                    handle_write(Req1, State, []);
                                _ ->
                                    {ok, Decoded} = msgpack:unpack(Body, [jsx]),
                                    handle_write(Req1, State, Decoded)
                            end,
    {Reply, Req2, State1}.

handle_write(Req, State = #state{path = [Dataset, <<"metadata">> | Path]}, [{K, V}]) ->
    Start = now(),
    libsniffle:dataset_set(Dataset, [<<"metadata">> | Path] ++ [K], jsxd:from_list(V)),
    ?MSniffle(?P(State), Start),
    {true, Req, State};

handle_write(Req, State = #state{path = [Dataset]}, [{K, V}]) ->
    Start = now(),
    libsniffle:dataset_set(Dataset, [K], jsxd:from_list(V)),
    ?MSniffle(?P(State), Start),
    {true, Req, State};

handle_write(Req, State = #state{path = []}, _Body) ->
    {true, Req, State};

handle_write(Req, State, _Body) ->
    {false, Req, State}.

%%--------------------------------------------------------------------
%% DELETE
%%--------------------------------------------------------------------

delete_resource(Req, State = #state{path = [Dataset, <<"metadata">> | Path]}) ->
    Start = now(),
    libsniffle:dataset_set(Dataset, [<<"metadata">> | Path], delete),
    ?MSniffle(?P(State), Start),
    {true, Req, State};

delete_resource(Req, State = #state{path = [Dataset]}) ->
    Start = now(),
    ok = libsniffle:dataset_delete(Dataset),
    ?MSniffle(?P(State), Start),
    {true, Req, State}.
