%
% The contents of this file are subject to the Mozilla Public License
% Version 1.1 (the "License"); you may not use this file except in
% compliance with the License. You may obtain a copy of the License at
% http://www.mozilla.org/MPL/
%
% Copyright (c) 2015 Petr Gotthard <petr.gotthard@centrum.cz>
%

% dispatcher for UDP communication
% maintains a lookup-table for existing channels
% when a channel pool is provided (server mode), creates new channels
-module(lwm2m_coap_udp_socket).
-behaviour(gen_server).

-export([start_link/0, start_link/3, get_channel/2, close/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, code_change/3, terminate/2]).

-record(state, {sock, chans, pool, proxy_protocol, lb}).

-record(proxy_header, {inet     :: 4 | 6,
                       src_addr :: inet:ip_address(),
                       dst_addr :: inet:ip_address(),
                       src_port :: inet:port_number(),
                       dst_port :: inet:port_number()}).

-include("coap.hrl").

% client
start_link() ->
    gen_server:start_link(?MODULE, [0], []).
% server
start_link(InPort, SupPid, Options) ->
    gen_server:start_link(?MODULE, [InPort, SupPid, Options], []).

get_channel(Pid, {PeerIP, PeerPortNo}) ->
    gen_server:call(Pid, {get_channel, {PeerIP, PeerPortNo}}).

close(Pid) ->
    % the channels will be terminated by their supervisor (server), or
    % should be terminated by the user (client)
    gen_server:cast(Pid, shutdown).


init([InPort]) ->
    init([InPort, [] ]);

init([InPort, Options]) ->
    process_flag(trap_exit, true),
    Opts = proplists:get_value(opts, Options, []),
    {ok, Socket} = gen_udp:open(InPort, [binary, {active, true}, {reuseaddr, true}] ++ Opts),
    {ok, InPort2} = inet:port(Socket),
    error_logger:info_msg("coap listen on *:~p~n", [InPort2]),
    {ok, #state{sock=Socket,
                chans=dict:new(),
                proxy_protocol = proplists:get_value(proxy_protocol, Options),
                lb = proplists:get_value(lb, Options)
                }};

init([InPort, SupPid, Options]) ->
    gen_server:cast(self(), {set_pool, SupPid}),
    init([InPort, Options]).

handle_call({get_channel, ChId}, _From, State=#state{chans=Chans, pool=undefined}) ->
    case find_channel(ChId, Chans) of
        {ok, Pid} ->
            {reply, {ok, Pid}, State};
        undefined ->
            {ok, _, Pid} = lwm2m_coap_channel_sup:start_link(self(), ChId),
            {reply, {ok, Pid}, store_channel(ChId, Pid, State)}
    end;
handle_call({get_channel, ChId}, _From, State=#state{pool=PoolPid}) ->
    case lwm2m_coap_channel_sup_sup:start_channel(PoolPid, ChId) of
        {ok, _, Pid} ->
            {reply, {ok, Pid}, store_channel(ChId, Pid, State)};
        Error ->
            {reply, Error, State}
    end;
handle_call(_Unknown, _From, State) ->
    {reply, unknown_call, State}.

handle_cast({set_pool, SupPid}, State) ->
    % calling lwm2m_coap_server directly from init/1 causes deadlock
    PoolPid = lwm2m_coap_server:channel_sup(SupPid),
    {noreply, State#state{pool=PoolPid}};
handle_cast(shutdown, State) ->
    {stop, normal, State};
handle_cast(Request, State) ->
    error_logger:error_msg("lwm2m_coap_udp_socket unknown cast: ~p", [Request]),
    {noreply, State}.

handle_info({udp, _Socket, PeerIP, PeerPortNo, Data}, State=#state{chans=Chans, pool=PoolPid, proxy_protocol = undefined}) ->
    ChId = {PeerIP, PeerPortNo},
    %io:format("Got normal udp data, Peer: ~p, data: ~p~n", [ChId, Data]),
    goto_channel(ChId, Chans, Data, PoolPid, State);

handle_info({udp, _Socket, PeerIP, PeerPortNo, Data}, State=#state{chans=Chans, pool=PoolPid, proxy_protocol = v1}) ->
    %io:format("Got proxy protocol udp data, Peer: ~p, data: ~p~n", [{PeerIP, PeerPortNo}, Data]),
    case parse_v1(Data) of
        {error, invalid_header} ->
            {noreply, State}; % drop
        {ok, {_ProxyHeader = #proxy_header{src_addr= SrcAddr, src_port = SrcPort}, Body}} ->
            %io:format("Proxy Protocol Header: ~p~n", [_ProxyHeader]),
            ChId = {SrcAddr, SrcPort},
            cache_proxy_addr(ChId, {PeerIP, PeerPortNo}),
            goto_channel(ChId, Chans, Body, PoolPid, State)
    end;

handle_info({datagram, _ChId, undefined}, State) ->
    {noreply, State};

handle_info({datagram, ChId, Data}, State=#state{sock=Socket, proxy_protocol = PP}) ->
    {PeerIP, PeerPortNo} = get_addr(PP, ChId),
    ok = gen_udp:send(Socket, PeerIP, PeerPortNo, Data),
    {noreply, State};

handle_info({ping, ChId, Data}, State=#state{sock=Socket, proxy_protocol = PP, lb = LB}) ->
    case LB of
        undefined -> ok;
        _ ->
            {PeerIP, PeerPortNo} = get_addr(PP, ChId),
            ok = gen_udp:send(Socket, PeerIP, PeerPortNo, Data)
    end,
    {noreply, State};

handle_info({terminated, ChId}, State=#state{sock=Socket, chans=Chans, proxy_protocol = PP, lb = LB}) ->
    case LB of
        undefined -> ok;
        _ ->
            {PeerIP, PeerPortNo} = get_addr(PP, ChId),
            ok = gen_udp:send(Socket, PeerIP, PeerPortNo, ?CLOSED)
    end,
    Chans2 = dict:erase(ChId, Chans),
    delete_proxy_addr(ChId),
    lwm2m_coap_channel_sup_sup:delete_channel(ChId),
    {noreply, State#state{chans=Chans2}};

handle_info({'EXIT', _Pid, _Reason}, State) ->
    {noreply, State};

handle_info(Info, State) ->
    error_logger:error_msg("lwm2m_coap_udp_socket unexpected: ~p", [Info]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(Reason, #state{sock=Sock}) ->
    error_logger:info_msg("coap socket stopped, reason: ~p", [Reason]),
    gen_udp:close(Sock),
    ok.

parse_v1(<<"PROXY TCP", Proto, 16#20, Data/binary>>) ->
    case binary:split(Data, [<<"\r\n">>], [trim]) of
        [ProxyInfo, Body] ->
            case binary:split(ProxyInfo, [<<" ">>], [global, trim]) of
                [SrcAddrBin, DstAddrBin, SrcPortBin, DstPortBin] ->
                    PPHeader = parse_v1_header(Proto, SrcAddrBin, DstAddrBin, SrcPortBin, DstPortBin),
                    {ok, {PPHeader, Body}};
                _ ->
                    %io:format("parse_v1 - invalid ProxyHeader: ~p~n", [ProxyInfo]),
                    {error, invalid_header}
            end;
        _Data ->
            %io:format("parse_v1 - invalid Data: ~p~n", [_Data]),
            {error, invalid_header}
    end;
parse_v1(_) ->
    {error, invalid_header}.

parse_v1_header(Proto, SrcAddrBin, DstAddrBin, SrcPortBin, DstPortBin) ->
    {ok, SrcAddr} = inet:parse_address(binary_to_list(SrcAddrBin)),
    {ok, DstAddr} = inet:parse_address(binary_to_list(DstAddrBin)),
    SrcPort = list_to_integer(binary_to_list(SrcPortBin)),
    DstPort = list_to_integer(binary_to_list(DstPortBin)),
    #proxy_header{
        inet = Proto,
        src_addr = SrcAddr,
        dst_addr = DstAddr,
        src_port = SrcPort,
        dst_port = DstPort
    }.

find_channel(ChId, Chans) ->
    case dict:find(ChId, Chans) of
        % there is a channel in our cache, but it might have crashed
        {ok, Pid} ->
            case erlang:is_process_alive(Pid) of
                true -> {ok, Pid};
                false -> undefined
            end;
        % we got data via a new channel
        error -> undefined
    end.

goto_channel(ChId, Chans, Data, PoolPid, State) ->
    case find_channel(ChId, Chans) of
        % channel found in cache
        {ok, Pid} ->
            Pid ! {datagram, Data},
            {noreply, State};
        undefined when is_pid(PoolPid) ->
            case lwm2m_coap_channel:start_link(self(), ChId) of
                % new channel created
                {ok, Pid} ->
                    Pid ! {datagram, Data},
                    {noreply, store_channel(ChId, Pid, State)};
                % drop this packet
                {error, _} ->
                    {noreply, State}
            end;
        undefined ->
            % ignore unexpected message received by a client
            % TODO: do we want to send reset?
            {noreply, State}
    end.

store_channel(ChId, Pid, State=#state{chans=Chans}) ->
    State#state{chans=dict:store(ChId, Pid, Chans)}.

cache_proxy_addr(ChId, Proxy) ->
    %io:format("Cache Proxy Addr: (~p) for ChId: (~p)~n", [Proxy, ChId]),
    put(ChId, Proxy).

get_proxy_addr(ChId) ->
    case get(ChId) of
        undefined -> not_found;
        Proxy -> Proxy
    end.

delete_proxy_addr(ChId) ->
    case erase(ChId) of
        undefined -> not_found;
        Proxy -> Proxy
    end.

get_addr(v1, ChId) -> get_proxy_addr(ChId);
get_addr(_, {PeerIP, PeerPortNo}) -> {PeerIP, PeerPortNo}.
% end of file
