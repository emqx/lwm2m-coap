%
% The contents of this file are subject to the Mozilla Public License
% Version 1.1 (the "License"); you may not use this file except in
% compliance with the License. You may obtain a copy of the License at
% http://www.mozilla.org/MPL/
%
% Copyright (c) 2015 Petr Gotthard <petr.gotthard@centrum.cz>
%

-module(lwm2m_coap_resource).

-include("coap.hrl").

% called when a client asks for .well-known/core resources
-callback coap_discover([binary()], any()) ->
    [coap_uri()].

% GET handler
-callback coap_get(coap_channel_id(), [binary()], [binary()], coap_content(), lwm2m_state()) ->
    {ok, coap_content(), lwm2m_state()} |
    {'error', atom(), lwm2m_state()}.

% POST handler
-callback coap_post(coap_channel_id(), [binary()], [binary()], coap_content(), lwm2m_state()) ->
    {'ok', atom(), coap_content(), lwm2m_state()} |
    {'error', atom(), lwm2m_state()}.

% PUT handler
-callback coap_put(coap_channel_id(), [binary()], [binary()], coap_content(), lwm2m_state()) ->
    {'ok', lwm2m_state()} |
    {'error', atom(), lwm2m_state()}.

% DELETE handler
-callback coap_delete(coap_channel_id(), [binary()], coap_content(), lwm2m_state()) ->
    {'ok', lwm2m_state()} |
    {'error', atom(), lwm2m_state()}.

% observe request handler
-callback coap_observe(coap_channel_id(), [binary()], [binary()], coap_content(), lwm2m_state()) ->
    {'ok', lwm2m_state()} |
    {'error', atom(), lwm2m_state()}.

% cancellation request handler
-callback coap_unobserve(lwm2m_state()) ->
    {'ok', lwm2m_state()}.

% handler for messages sent to the responder process
% used to generate notifications
-callback handle_info(any(), lwm2m_state()) ->
    {'notify', any(), coap_content(), lwm2m_state()} |
    {'noreply', lwm2m_state()} |
    {send_request, coap_message(), lwm2m_reqeust_ref() , lwm2m_state()} |
    {'error', coap_code(), lwm2m_state()}.

% response to notifications
-callback coap_ack(coap_channel_id(), any(), any()) ->
    {'ok', any()}.

-type coap_channel_id() :: {inet:port_number(), inet:ip_address()}.
-type coap_uri() :: {'absolute', [binary()], coap_uri_param()}.
-type coap_uri_param() :: {atom(), binary()}.

-type lwm2m_state() :: any().
-type lwm2m_reqeust_ref() :: any().
-type coap_code() :: atom().

% end of file
