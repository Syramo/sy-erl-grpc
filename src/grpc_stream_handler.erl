%%%-------------------------------------------------------------------
%%% Licensed to the Apache Software Foundation (ASF) under one
%%% or more contributor license agreements.  See the NOTICE file
%%% distributed with this work for additional information
%%% regarding copyright ownership.  The ASF licenses this file
%%% to you under the Apache License, Version 2.0 (the
%%% "License"); you may not use this file except in compliance
%%% with the License.  You may obtain a copy of the License at
%%%
%%%   http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing,
%%% software distributed under the License is distributed on an
%%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%%% KIND, either express or implied.  See the License for the
%%% specific language governing permissions and limitations
%%% under the License.
%%%

%% @doc This cowboy stream handler takes care of flow control.
%%
%% It keeps track of the number of bytes received on a stream
%% and sends a {flow, ...} command when this reaches a certain threshold, so 
%% that the stream and connection windows are adjusted (Cowboy will send
%% two WINDOW_UPDATE frames to the client, one for the stream and one for the 
%% connection).
%%
%% The goal is to send the updates in such a way that the traffic will
%% never be stalled, but at the same time limiting the number of WINDOW_UPDATE
%% frames. Since this implementation has no knowledge of the specifics of the 
%% stream, it must take a very general approach. The chosen approach is to 
%% "top up" the window to its original size (65535 bytes) as soon as it is
%% 50% depleted.
-module(grpc_stream_handler).
-include("common.hrl").

-export([init/3]).
-export([data/4]).
-export([info/3]).
-export([terminate/3]).
-export([early_error/5]).

-record(state, {
        next :: any(),
    count = 0 :: integer(),
    backoff = go :: go | slow,
	bytes_received = 0 :: integer()}).

-spec init(cowboy_stream:streamid(), cowboy_req:req(), cowboy:opts())
    -> {cowboy_stream:commands(), #state{}}.
init(StreamID, Req, Opts) ->
    {Commands0, Next} = cowboy_stream:init(StreamID, Req, Opts),
    {Commands0, #state{bytes_received=0, next=Next}}.

-spec data(cowboy_stream:streamid(), cowboy_stream:fin(), cowboy_req:resp_body(), State)
    -> {cowboy_stream:commands(), State} when State::#state{}.
data(StreamID, IsFin, Data, State0=#state{next=Next0, count=C}) ->                                   
    {Commands0, Next} = cowboy_stream:data(StreamID, IsFin, Data, Next0),
    Size = size(Data),
    %TotalReceived = Size + Received,
    %if (B==slow) andalso (C rem 100 =:= 0) -> timer:sleep(50); true -> ok end,
    flow_control (Commands0, Size, State0#state{next=Next, count=C+1}).
    
    
-spec flow_control (cowboy_stream:commands(), Receives::integer(), #state{}) ->  {cowboy_stream:commands(), State} when State::#state{}.
flow_control (Commands, Size, #state{bytes_received=Received, backoff=B}=State) ->
    TotalReceived = Size + Received,
    %?DLOG("DATA: size=~B, total=~B",[Size, TotalReceived]),
    if 
        (TotalReceived > 32767) andalso (B==go) -> 
            %?DLOG("FLOW / USED=~B / CONSUMED=~B",[TotalReceived,C]), 
            %{[{flow, max(C,65534)} | Commands], State#state{bytes_received = max(0,32767-C), consumed = 0}};
            {[{flow, TotalReceived} | Commands], State#state{bytes_received = 0}};
        true ->             
            %?DLOG("STALLED / USED=~B / CONSUMED=~B",[TotalReceived,C]), 
            {Commands, State#state{bytes_received = TotalReceived}}
    end.

-spec info(cowboy_stream:streamid(), any(), State) -> {cowboy_stream:commands(), State} when State::#state{}.
info(StreamID, Info, State0=#state{next=Next0}) ->
    {Commands0, Next} = cowboy_stream:info(StreamID, Info, Next0),
    Commands = remove_date_and_server(Commands0),
    case Info of
        go -> 
            {[{flow, 65536}|Commands], State0#state{next=Next, backoff=go}};
        slow -> 
            {Commands, State0#state{next=Next, backoff=slow}};
        _ -> 
            {Commands, State0#state{next=Next}}
    end.

-spec terminate(cowboy_stream:streamid(), cowboy_stream:reason(), #state{}) -> any().
terminate(StreamID, Reason, #state{next=Next}) ->
    cowboy_stream:terminate(StreamID, Reason, Next).

-spec early_error(cowboy_stream:streamid(), cowboy_stream:reason(),
    cowboy_stream:partial_req(), Resp, cowboy:opts()) -> Resp
    when Resp::cowboy_stream:resp_command().
early_error(StreamID, Reason, PartialReq, Resp, Opts) ->
    cowboy_stream:early_error(StreamID, Reason, PartialReq, Resp, Opts).


%%-----------------------------------------------------------------------------
%% Internal functions
%%-----------------------------------------------------------------------------

%% cowboy adds headers for "date" and "server", these must be removed.
remove_date_and_server(Commands) ->
    F = fun({headers, Status, Headers}) ->
                {headers, Status, maps:without([<<"date">>, <<"server">>], Headers)};
           (Other) ->
                Other
        end,
    [F(C) || C <- Commands].
