%
% The contents of this file are subject to the Mozilla Public License
% Version 1.1 (the "License"); you may not use this file except in
% compliance with the License. You may obtain a copy of the License at
% http://www.mozilla.org/MPL/
%
% Copyright (c) 2015 Petr Gotthard <petr.gotthard@centrum.cz>
%

% provides the .well-known/core resource and content queries
-module(lwm2m_coap_server_content).
-behaviour(lwm2m_coap_resource).

-export([ coap_discover/2
        , coap_get/5
        , coap_post/5
        , coap_put/5
        , coap_delete/4
        , coap_observe/5
        , coap_unobserve/1
        , handle_info/2
        , coap_ack/3
        , terminate/2
        ]).

-include("coap.hrl").

%% TODO: The callback implementation for lwm2m_coap_resource seem to be very much off the spec.
-dialyzer(no_behaviours).

coap_discover(_Prefix, _Args) ->
    [].

coap_get(_ChId, _Prefix, Query, _Content, State) ->
    Links = coap_core_link:encode(filter(lwm2m_coap_server_registry:get_links(), Query)),
    {ok, #coap_content{etag = binary:part(crypto:hash(sha, Links), {0,4}),
                       content_format = <<"application/link-format">>,
                       payload = list_to_binary(Links)}, State};

coap_get(_ChId, _Prefix, _Query, _Content, State) ->
    {error, not_found, State}.

coap_post(_ChId, _Prefix, _Query, _Content, State) ->
    {error, method_not_allowed, State}.

coap_put(_ChId, _Prefix, _Query, _Content, State) ->
    {error, method_not_allowed, State}.

coap_delete(_ChId, _Prefix, _Content, State) ->
    {error, method_not_allowed, State}.

coap_observe(_ChId, _Prefix, _Name, _Ack, State) ->
    {error, method_not_allowed, State}.

coap_unobserve(State) ->
    {ok, State}.

coap_ack(_ChId, _Ref, State) -> {ok, State}.

handle_info(_Message, State) -> {noreply, State}.

terminate(_Reason, _State) ->
    ok.

% uri-query processing

filter(Links, []) ->
    Links;
filter(Links, [Search | Query]) ->
    filter(
        case binary:split(Search, <<$=>>) of
            [Name0, Value0] ->
                Name = list_to_atom(binary_to_list(Name0)),
                Value = wildcard_value(Value0),
                lists:filter(
                    fun (Link) -> match_link(Link, Name, Value) end,
                    Links);
            _Else ->
                Links
        end,
        Query).

wildcard_value(<<>>) ->
    {global, <<>>};
wildcard_value(Value) ->
    case binary:last(Value) of
        $* -> {prefix, binary:part(Value, 0, byte_size(Value)-1)};
        _Else -> {global, Value}
    end.

match_link({_Type, _Uri, Attrs}, Name, Value0) ->
    lists:any(
        fun (AttrVal) ->
            case Value0 of
                {prefix, Value} -> binary:part(AttrVal, 0, byte_size(Value)) =:= Value;
                {global, Value} -> AttrVal =:= Value
            end
        end,
        proplists:get_all_values(Name, Attrs)).

% end of file
