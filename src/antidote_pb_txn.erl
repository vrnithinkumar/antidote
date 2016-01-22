%% -------------------------------------------------------------------
%%
%% Copyright (c) 2014 SyncFree Consortium.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------
-module(antidote_pb_txn).

-ifdef(TEST).
-compile([export_all]).
-include_lib("eunit/include/eunit.hrl").
-endif.

-behaviour(riak_api_pb_service).

-include_lib("riak_pb/include/antidote_pb.hrl").
-include("antidote.hrl").

-export([init/0,
         decode/2,
         encode/1,
         process/2,
         process_stream/3
        ]).

-record(state, {client}).

%% @doc init/0 callback. Returns the service internal start
%% state.
init() ->
    #state{}.

%% @doc decode/2 callback. Decodes an incoming message.
decode(Code, Bin) ->
    Msg = riak_pb_codec:decode(Code, Bin),
    case Msg of
        #fpbatomicupdatetxnreq{} ->
            {ok, Msg, {"antidote.atomicupdate", <<>>}};
        #fpbsnapshotreadtxnreq{} ->
            {ok, Msg, {"antidote.snapshotread",<<>>}}
    end.

%% @doc encode/1 callback. Encodes an outgoing response message.
encode(Message) ->
    {ok, riak_pb_codec:encode(Message)}.

%% @doc process/2 callback. Handles an incoming request message.
process(#fpbatomicupdatetxnreq{clock=BClock,ops = Ops}, State) ->
    Updates = decode_au_txn_ops(Ops),
    Clock = binary_to_term(BClock),
    Properties = antidote_pb_codec:decode(txn_properties, BProperties),
    Response = antidote:start_transaction(Clock, Properties, true),
    case Response of
        {error, _Reason} ->
            {reply, #fpbatomicupdatetxnresp{success = false}, State};
        {ok, {_Txid, _ReadSet, CommitTime}} ->
            {reply, #fpbatomicupdatetxnresp{success = true,
                                            clock=term_to_binary(CommitTime)},
             State}
    end;

process(#fpbsnapshotreadtxnreq{clock=BClock,ops = Ops}, State) ->
    ReadReqs = decode_snapshot_read_ops(Ops),
    %%TODO: change this to interactive reads
    Clock = binary_to_term(BClock),
    Properties = antidote_pb_codec:decode(txn_properties, BProperties),
    Updates = lists:map(fun(O) ->
                                antidote_pb_codec:decode(update_object, O) end,
                        BUpdates),
    Response = antidote:update_objects(Clock, Properties, Updates, true),
    case Response of
        {error, Reason} ->
            {reply, antidote_pb_codec:encode(commit_response,
                                             {error, Reason}), State};
        {ok, CommitTime} ->
            {reply, antidote_pb_codec:encode(commit_response, {ok, CommitTime}),
             State}
    end;            
process(#apbstaticreadobjects{
           transaction=#apbstarttransaction{timestamp=BClock, properties = BProperties},
           objects=BoundObjects},
        State) ->
    Clock = binary_to_term(BClock),
    Properties = antidote_pb_codec:decode(txn_properties, BProperties),
    Objects = lists:map(fun(O) ->
                                antidote_pb_codec:decode(bound_object, O) end,
                        BoundObjects),
    Response = antidote:read_objects(Clock, Properties, Objects, true),
    case Response of
        {error, Reason} ->
            {reply, antidote_pb_codec:encode(commit_response,
                                             {error, Reason}), State};
        {ok, Results, CommitTime} ->
            {reply, antidote_pb_codec:encode(static_read_objects_response,
                                             {ok, lists:zip(Objects,Results), CommitTime}),
             State}
    end.


%% @doc process_stream/3 callback. This service does not create any
%% streaming responses and so ignores all incoming messages.
process_stream(_,_,State) ->
    {ignore, State}.

%% @doc decode_au_txn_ops : converts the pb messages for atomic update
%% transaction into update messages for interface in antidote.erl
-spec decode_au_txn_ops([#fpbatomicupdatetxnop{}]) ->
                               [{update, key(), type(), op()}].
decode_au_txn_ops(Ops) ->
    lists:foldl(fun(Op, Acc) ->
                     Acc ++ decode_au_txn_op(Op)
                end, [], Ops).
%% Counter
decode_au_txn_op(#fpbatomicupdatetxnop{counterinc=#fpbincrementreq{key=Key, amount=Amount}}) ->
    [{update, Key, riak_dt_pncounter, {{increment, Amount}, node()}}];
decode_au_txn_op(#fpbatomicupdatetxnop{counterdec=#fpbdecrementreq{key=Key, amount=Amount}}) ->
    [{update, Key, riak_dt_pncounter, {{decrement, Amount}, node()}}];
%% Set
decode_au_txn_op(#fpbatomicupdatetxnop{setupdate=#fpbsetupdatereq{key=Key,adds=AddElems, rems=RemElems}}) ->
     Adds = lists:map(fun(X) ->
                              binary_to_term(X)
                      end, AddElems),
     Rems = lists:map(fun(X) ->
                              binary_to_term(X)
                      end, RemElems),
    Op = case length(Adds) of
             0 -> [];
             1 -> [{update, Key, riak_dt_orset, {{add,Adds}, node()}}];
             _ -> [{update, Key, riak_dt_orset, {{add_all, Adds},node()}}]
         end,
    case length(Rems) of
        0 -> Op;
        1 -> [{update, Key, riak_dt_orset, {{remove, hd(Rems)}, ignore}}] ++ Op;
        _ -> [{update, Key, riak_dt_orset, {{remove_all, Rems},ignore}}] ++ Op
    end.

%% @doc decode_snapshot_read_ops : converts the pb messages for snapshot
%%  read transaction into read messages.
-spec decode_snapshot_read_ops([#fpbsnapshotreadtxnop{}]) ->
                                      [{read, key(), type()}].
decode_snapshot_read_ops(Ops) ->
    lists:map(fun(Op) ->
                      decode_snapshot_read_op(Op)
              end, Ops).

decode_snapshot_read_op(#fpbsnapshotreadtxnop{counter=#fpbgetcounterreq{key=Key}}) ->
    {read, Key, riak_dt_pncounter};
decode_snapshot_read_op(#fpbsnapshotreadtxnop{set=#fpbgetsetreq{key=Key}}) ->
    {read,Key, riak_dt_orset}.

%% @doc encodes the response for snapshot read into pb messages
encode_snapshot_read_response(Zipped) ->
    lists:map(fun(Resp) ->
                      encode_snapshot_read_resp(Resp)
              end, Zipped).
encode_snapshot_read_resp({{read, Key, riak_dt_pncounter}, Result}) ->
    #fpbsnapshotreadtxnrespvalue{key=Key,counter=#fpbgetcounterresp{value =Result}};
encode_snapshot_read_resp({{read,Key,riak_dt_orset}, Result}) ->
    #fpbsnapshotreadtxnrespvalue{key=Key,set=#fpbgetsetresp{value = term_to_binary(Result)}}.
