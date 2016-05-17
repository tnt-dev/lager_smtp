-module(lager_smtp_backend).
-author("Ivan Blinkov <ivan@blinkov.ru>").

-behaviour(gen_event).

-export([init/1, handle_call/2, handle_event/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {level, from, to, relay, username, password, port, ssl,
                flush, flush_interval, seq=0}).
-define(ETS_BUFFER, lager_smtp_buffer).

-include_lib("lager/include/lager.hrl").

init(Args) when is_list(Args) ->
    ensure_started(),
    To = lists:map(fun iolist_to_binary/1, proplists:get_value(to, Args)),
    ets:new(?ETS_BUFFER, [ordered_set, private, named_table]),
    {ok, #state{
            level=parse_level(proplists:get_value(level, Args, error)),
            from=iolist_to_binary(proplists:get_value(from, Args)),
            to=To,
            relay=iolist_to_binary(proplists:get_value(relay, Args)),
            username = iolist_to_binary(
                         proplists:get_value(username, Args, <<>>)),
            password = iolist_to_binary(
                         proplists:get_value(password, Args, <<>>)),
            port=proplists:get_value(port, Args, 587),
            ssl=proplists:get_value(ssl, Args, true),
            flush=proplists:get_value(flush, Args, true),
            flush_interval=proplists:get_value(flush_interval, Args, 20000)}}.

handle_call(get_loglevel, #state{level=Level}=State) ->
    {ok, Level, State};
handle_call({set_loglevel, Level}, State) ->
    try parse_level(Level) of
        L -> {ok, ok, State#state{level=L}}
    catch
        _:_ -> {ok, {error, bad_log_level}, State}
    end;
handle_call(_Request, State) ->
    {ok, ok, State}.

handle_event({log, Level, Datetime, [_LevelStr, _Location, RawMessage]},
             #state{level=LogLevel}=State) when Level =< LogLevel ->
    handle_message({Level, Datetime, RawMessage}, State);
handle_event({log, Message}, #state{level=LogLevel}=State) ->
    case lager_util:is_loggable(Message, LogLevel, ?MODULE) of
        true ->
            Level = lager_msg:severity(Message),
            Datetime = lager_msg:datetime(Message),
            RawMessage = lager_msg:message(Message),
            handle_message({Level, Datetime, RawMessage}, State);
        false ->
            {ok, State}
    end;
handle_event(smtp_flush, State) ->
    Messages = [Message || {_, Message} <- ets:tab2list(?ETS_BUFFER)],
    send(Messages, State),
    true = ets:delete_all_objects(?ETS_BUFFER),
    {ok, State#state{seq=0}};
handle_event(_Event, State) ->
    {ok, State}.

handle_info(_Info, State) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ets:delete(?ETS_BUFFER),
    application:stop(gen_smtp),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_message(Message, #state{flush=true,
                               flush_interval=FlushInterval,
                               seq=Seq}=State) ->
    ets:insert(?ETS_BUFFER, {Seq, Message}),
    case Seq of
        0 -> timer:apply_after(FlushInterval, gen_event, notify,
                               [lager_event, smtp_flush]);
        _ -> ok
    end,
    {ok, State#state{seq=Seq+1}};
handle_message(Message, State) ->
    send([Message], State),
    {ok, State}.

send(Messages, #state{from=From,
                      to=To,
                      relay=Relay,
                      username=Username,
                      password=Password,
                      port=Port,
                      ssl=SSL}) ->
    BinaryNode = list_to_binary(atom_to_list(node())),
    Subject = case Messages of
                  [{Level, _, _}] ->
                      BinaryLevel = atom_to_binary(Level, latin1),
                      <<BinaryNode/binary, " ", BinaryLevel/binary>>;
                  _ ->
                      <<"Logs from ", BinaryNode/binary>>
              end,
    Recipients = join_to(To),
    Body = lists:foldl(fun(Message, Acc) ->
                               BodyPart = body(Message),
                               <<Acc/binary, BodyPart/binary>>
                       end, <<>>, Messages),
    Data = <<"Subject: ", Subject/binary, "\r\n",
             "From: ", From/binary, "\r\n",
             "To: ", Recipients/binary, "\r\n\r\n",
             Body/binary>>,
    gen_smtp_client:send({From, To, Data},
                         [{relay, Relay},
                          {username, Username},
                          {password, Password},
                          {port, Port},
                          {ssl, SSL}]).

body({Level, {Date, Time}, RawMessage}) ->
    BinaryLevel = list_to_binary(string:to_upper(atom_to_list(Level))),
    BinaryDate = iolist_to_binary(Date),
    BinaryTime = iolist_to_binary(Time),
    BinaryMessage = iolist_to_binary(RawMessage),
    <<BinaryDate/binary, " ", BinaryTime/binary, " ",
      "[", BinaryLevel/binary, "] ",
      BinaryMessage/binary, "\r\n\r\n">>.

join_to(To) ->
    join_to(To, []).

join_to([Last], Acc) when is_binary(Last) ->
    iolist_to_binary(lists:reverse([Last | Acc]));
join_to([Recipient|To], Acc) ->
    join_to(To, [<<", ">> | [Recipient | Acc]]).

parse_level(Level) ->
    try lager_util:config_to_mask(Level) of
        Res -> Res
    catch
        error:undef ->
            %% must be lager < 2.0
            lager_util:level_to_num(Level)
    end.

ensure_started() ->
    case application:start(gen_smtp) of
        ok -> ok;
        {error, {already_started, _}} -> ok
    end.
