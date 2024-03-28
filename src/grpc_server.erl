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

%%% Implementation of the interface between the gRPC framework and the
%%% Cowboy HTTP server.
%%%
%%% Starts and stops the server, and acts as the 
%%% entry point for each request (the 'init' function). 
%%%
-module(grpc_server).
-include("common.hrl").

-export([start/5]).
-export([stop/1]).
-export([init/2]).

%% status codes as defined here: http://www.grpc.io/grpc/csharp/html/T_Grpc_Core_StatusCode.htm
-define(GRPC_STATUS_OK, <<"0">>).
-define(GRPC_STATUS_UNKNOWN, <<"2">>).
-define(GRPC_STATUS_UNIMPLEMENTED, <<"12">>).
-define(GRPC_STATUS_INTERNAL, <<"13">>).
-define(GRPC_STATUS_INTERNAL_INT, 13).
-define(GRPC_STATUS_UNAUTHENTICATED, <<"16">>).

-spec start(Name::term(),
            Transport::tcp|ssl,
            Port::integer(),
            Services::grpc:services(),
            Options::[grpc:server_option()]) ->
    {ok, CowboyListenerPid::pid()} | {error, any()}.
start(Name, Transport, Port, Services, Options) ->
    AuthFun = get_authfun(Transport, Options),
    Middlewares = get_middlewares(Options),
    %% All requests are dispatched to this same module (?MODULE),
    %% which means that `init/2` below will be called for each
    %% request.
    Dispatch = cowboy_router:compile([
	{'_', [{"/:service/:method", 
                ?MODULE, 
                #{auth_fun => AuthFun,
                  services => Services}}]}]),
    ProtocolOpts = #{env => #{dispatch => Dispatch},
                     %% inactivity_timeout => infinity,
                     stream_handlers => [grpc_stream_handler,
                                         cowboy_stream_h],
                     middlewares => Middlewares,
                     max_received_frame_rate => {20000, 10000},
                     stream_window_margin_size => 16384,
                     max_stream_window_size =>  512000,  %65536,
                     max_connection_window_size => 1024000,
                     idle_timeout => 9000000,
                     inactivity_timeout => 12000000,
                     active_n => 500,
                     max_concurrent_streams => infinity,
                     max_stream_buffer_size => 32000000,
                     max_connection_buffer_size => 96000000, 
                     sendfile => false,
                     goaway_initial_timeout => 10000,
                     goaway_complete_timeout => 32000,
                     max_reset_stream_rate => {100,10000}
                    },
    case Transport of
        tcp ->
            cowboy:start_clear(Name, [{port, Port}], ProtocolOpts);
        ssl ->
            TransportOpts = [{port, Port} |
                             proplists:get_value(transport_options, Options, [])],
            cowboy:start_tls(Name, TransportOpts, ProtocolOpts)
    end.

-spec stop(Name::term()) -> ok.
stop(Name) ->
    cowboy:stop_listener(Name).

%% This is called by cowboy for each request. 
%% It needs to differentiate between the different types of RPC (Simple RPC,
%% Client-side streaming RPC etc.)
init(Req, Options) ->
    Stream = make_stream(Req),
    case authenticate(Req, Options) of 
        false ->
            finalize(Stream, ?GRPC_STATUS_UNAUTHENTICATED, <<"">>);
        {true, ClientInfo} ->
            try 
                authenticated(Stream#{client_info => ClientInfo}, Options)
            catch
                throw:{Code, Reason} ->
                    finalize(Stream, Code, Reason)
            end
    end.
        
make_stream(#{headers := Headers,
              host := Authority,
              scheme := Scheme,
              path := Path,
              method := Method} = Req) ->
    maps:fold(fun process_header/3, 
              #{cowboy_req => Req,
                authority => Authority,
                scheme => Scheme,
                path => Path,
                method => Method,
                headers => #{<<"content-type">>=><<"application/grpc+proto">>},
                trailers => #{},
                metadata => #{}, %% metadata received from client
                %% headers can be sent explicitly from the user code, for 
                %% example to do it quickly or to add metadata. If not, they 
                %% will be sent by the framework before the first data frame.
                headers_sent => false,
                encoding => plain,
                compression => none, %% compression of the response messages
                start_time => erlang:system_time(1),
                content_type => undefined,
                user_agent => undefined,
                timeout => infinity}, Headers).

process_header(<<"grpc-timeout">>, Value, Acc) ->
    Acc#{timeout => Value};
%% TODO: not clear what should be done with this header
process_header(<<"te">>, _Value, Acc) ->
    Acc;
process_header(<<"user-agent">>, Value, Acc) ->
    Acc#{user_agent => Value};
process_header(<<"grpc-encoding">>, Value, Acc) ->
    Acc#{encoding => Value};
process_header(<<"content-type">>, Value, Acc) ->
    Acc#{content_type => Value};
process_header(Key, Value, #{metadata := Metadata} = Acc) ->
    {_, DecodedValue} = grpc_lib:maybe_decode_header({Key, Value}),
    Acc#{metadata => Metadata#{Key => DecodedValue}}.

%% If an authorisation fucntion is specified, use it. If not, there is a 
%% default that looks for client certificates in client_cert_dir (if that 
%% is specified).
get_authfun(ssl, Options) ->
    case proplists:get_value(auth_fun, Options) of
        undefined ->
            case proplists:get_value(client_cert_dir, Options) of
                undefined -> 
                    undefined;
                Dir ->
                    grpc_lib:auth_fun(Dir)
            end;
        Fun ->
            Fun
    end;
get_authfun(_, _) ->
    undefined.

get_middlewares(Options) ->
    case proplists:get_value(middlewares, Options) of
        undefined ->
            %% default cowboy middlewares
            [cowboy_router, cowboy_handler];
        Middlewares ->
            Middlewares
    end.

authenticate(Req, #{auth_fun := AuthFun}) when is_function(AuthFun) ->
    case cowboy_req:cert(Req) of
        undefined ->
            false;
        Cert when is_binary(Cert) ->
            AuthFun(Cert)
    end;
authenticate(_Req, _Options) ->
    {true, undefined}.

authenticated(#{cowboy_req := Req} = Stream, Options) ->
    %% invoke the rpc (= function) for the service (= module).
    %% TODO: implement authorize and authorized ... move this to authorized
    %% support for bearer tokens and do the signature verification here
    %% however, use the handler to pass authorization of RPC calls
    try
        get_function(Req, Options, Stream)
    of
        NewStream ->
            read_frames(NewStream)
    catch
        _:_ -> 
            throw({?GRPC_STATUS_UNIMPLEMENTED,
                  <<"Operation not implemented">>})
    end.

get_function(Req, #{services := Services} = _Options, Stream) ->
    QualifiedService = cowboy_req:binding(service, Req), 
    Service = binary_to_existing_atom(lists:last(binary:split(QualifiedService, 
                                                              <<".">>, [global]))),
    #{Service := #{handler := Handler} = Spec} = Services,
    {module, _} = code:ensure_loaded(Handler),
    HandlerState = maps:get(handler_state, Spec, undefined),
    DecoderModule = maps:get(decoder, Spec, Handler:decoder()),
    {module, _} = code:ensure_loaded(DecoderModule),
    Rpc = binary_to_existing_atom(cowboy_req:binding(method, Req)),
    Stream#{decoder => DecoderModule,
            service => Service,
            handler => Handler,
            handler_state => HandlerState,
            rpc => Rpc}.
            

read_frames( Stream ) ->
    read_frames(<<>>, Stream).
read_frames(LoopVar, #{encoding := Encoding} = Stream) ->
    {More, InFrame, Req2, LoopVar2} = read_complete_frame(LoopVar, Stream ),
    Messages = split_frame(InFrame, Encoding),
    process_messages(LoopVar2, Messages, Stream#{cowboy_req => Req2}, More).

read_complete_frame(LoopVar, #{cowboy_req := Req} = Stream) ->
    Slow = case maps:get(slow_flag,Stream,go) of
        slow when byte_size(LoopVar) < 131072 -> cowboy_req:cast(go,Req), go;
        go when byte_size(LoopVar) > 131072 -> cowboy_req:cast(slow,Req), slow;
        Slow_ -> Slow_
    end,
    {More, InFrame, Req2} = if 
        byte_size(LoopVar) < 65536 -> 
            cowboy_req:read_body(Req, #{period=>100, timeout=>20000, length=>524288});
        true ->
            {more, <<>>, Req}
    end,
    NewFrame = <<LoopVar/binary, InFrame/binary>>,
    case More of
        more ->
            case byte_size(NewFrame) >= 5 of
                true ->
                    <<_:8, EncLen:32, RRR/binary>> = NewFrame,
                    if
                        EncLen == byte_size(RRR) ->
                                {More, NewFrame, Req2, <<>>};
                        EncLen < byte_size(RRR) ->
                                <<H:(EncLen+5)/binary, R/binary>> = NewFrame,
                                {More, H, Req2, R};
                        true -> read_complete_frame(NewFrame, Stream#{cowboy_req => Req2, slow_flag=>Slow})
                    end;
                false ->
                    read_complete_frame(NewFrame, Stream#{cowboy_req => Req2, slow_flag=>Slow})
            end;
        ok ->
            {ok, NewFrame, Req2, <<>>}
    end.

process_messages(LoopVar, [Message | T], Stream, More) ->
    case execute(Message, Stream) of
        {Response, NewStream, NewState} ->
            respond_and_continue(LoopVar, T, Response, NewStream, NewState, More);
        {_Response, _NewStream} = FinalResponse ->
            respond_and_finalize(FinalResponse);
        {error, Code, ErrorMessage, NewStream} when is_integer(Code), 
                                                    is_binary(ErrorMessage) ->
            finalize(NewStream, integer_to_binary(Code), ErrorMessage);
         _Other ->
            finalize(Stream, ?GRPC_STATUS_INTERNAL,
                     <<"Internal error - unexpected response value">>)
    end;
process_messages(LoopVar, [], Stream, More) -> 
    case More of 
        ok ->
            case byte_size(LoopVar) == 0 of
                true ->
                    case execute(eof, Stream) of
                        {stop, #{cowboy_req := Req}} ->
                            {ok, Req, []};
                        {Resp, NewStream, _} ->
                            respond_and_finalize({Resp, NewStream});
                        {Resp, NewStream} ->
                            respond_and_finalize({Resp, NewStream});
                        {error, Code, ErrorMessage, NewStream} when is_integer(Code), is_binary(ErrorMessage) ->
                            finalize(NewStream, integer_to_binary(Code), ErrorMessage);
                         _Other ->
                            finalize(Stream, ?GRPC_STATUS_INTERNAL,<<"Internal error - unexpected response value">>)
                    end;
                false ->
                    read_frames(LoopVar, Stream)
                end;
        more ->
            read_frames(LoopVar, Stream)
    end.

respond_and_finalize({Response, NewStream}) ->
    try grpc:send(NewStream, Response) of
        SentStream ->
            finalize(SentStream)
    catch 
        throw:{error, Status, Message} ->
            finalize(NewStream, Status, Message);
        throw:{error, Status, Message, CurrentStream} ->
            finalize(CurrentStream, Status, Message);
        _:_ ->
            finalize(NewStream)
    end.


-dialyzer({no_opaque, respond_and_continue/6}).

respond_and_continue(LoopVar, T, continue, NewStream, NewState, More) ->
   process_messages(LoopVar, T, NewStream#{handler_state => NewState}, More);
respond_and_continue(LoopVar, T, Response, NewStream, NewState, More) ->
    try grpc:send(NewStream#{handler_state => NewState}, Response) of
        SentStream ->
            process_messages(LoopVar, T, SentStream, More)
    catch 
        throw:{error, _, Message} ->
            finalize(NewStream, ?GRPC_STATUS_UNKNOWN, Message)
    end.

execute(Msg, #{handler := Module,
               service := Service,
               rpc := Function,
               decoder := Decoder,
               handler_state := State} = Stream) ->
    %  ?DLOG("Exec Message: ~B",[byte_size(Msg)]),
    try grpc_lib:decode_input(Service, Function, Decoder, Msg) of
        Decoded ->
            try 
                Module:Function(Decoded, Stream, State) 
            catch
                throw:{Code, ErrorMsg} ->
                    {error, Code, ErrorMsg};
                _:_ ->
                    ?LOG_ERROR("Exception on ~s:~s (~p,...)",[Module,Function,Decoded]),
                    {error, ?GRPC_STATUS_INTERNAL_INT, 
                     <<"Internal server error">>, Stream}
            end
    catch
        _:_ ->
            {error, ?GRPC_STATUS_INTERNAL_INT, 
             <<"Error parsing request protocol buffer">>, Stream}
    end.

finalize(Stream) ->
    finalize(Stream, ?GRPC_STATUS_OK, <<"">>).

-dialyzer({no_opaque, finalize/3}).

finalize(#{headers_sent := false} = Stream, Status, Message) ->
    %% (In theory this could be a "trailers-only" response, but
    %% in fact headers are sent separately).
    try grpc:send_headers(Stream) of
        NewStream ->
            finalize(NewStream, Status, Message)
    catch 
        _:_ ->
            finalize(Stream,Status,Message)
    end;
finalize(#{cowboy_req := Req, trailers := Trailers}, Status, <<"">>) ->
    try cowboy_req:stream_trailers(Trailers#{<<"grpc-status">> => Status}, Req) of
        _R ->
            {ok, Req, []}
    catch
        _:_ ->
            {ok, Req, []}
    end;
finalize(#{trailers := Trailers} = Stream, Status, Message) ->
    finalize(Stream#{trailers => Trailers#{<<"grpc-message">> => Message}}, Status, <<"">>).

split_frame(Frame, Encoding) ->
    split_frame(Frame, Encoding, []).
split_frame(<<>>, _Encoding, Acc) ->
    lists:reverse(Acc);
split_frame(<<0, Length:32, Encoded:Length/binary, Rest/binary>>, Encoding, Acc) ->
    split_frame(Rest, Encoding, [Encoded | Acc]);
split_frame(<<1, Length:32, Compressed:Length/binary, Rest/binary>>, 
            Encoding, Acc) ->
    Encoded = case Encoding of
                  <<"gzip">> ->
                      zlib:gunzip(Compressed);
                  _ ->
                      throw({?GRPC_STATUS_UNIMPLEMENTED, 
                             <<"compression mechanism not supported">>})
              end,
    split_frame(Rest, Encoding, [Encoded | Acc]).
