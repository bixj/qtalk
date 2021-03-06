%% Feel free to use, reuse and abuse the code in this file.
%%========================================================
%%用户注册接口（默认添加白名单）
%%========================================================

-module(http_register_user).

-export([init/3]).
-export([handle/2]).
-export([terminate/3]).

-include("ejabberd.hrl").
-include("logger.hrl").
-include("http_req.hrl").

init(_Transport, Req, []) ->
	{ok, Req, undefined}.

handle(Req, State) ->
    handle(Req, State, iplimit_util:check_ip(Req)).

handle(Req, State, false) ->
    Res = http_utils:gen_result(false, 3, <<"ip is limited">>),
    {ok, NewReq} = cowboy_req:reply(200, [
                                    {<<"content-type">>, <<"text/plain; charset=utf-8">>}
                                   ], Res, Req),
    {ok, NewReq, State};
handle(Req, State, _) ->
	{Method, _} = cowboy_req:method(Req),
	case Method of 
	<<"GET">> ->
		{ok, NReq} = get_echo(Method,Req),
		{ok, NReq, State};
	<<"POST">> ->
		HasBody = cowboy_req:has_body(Req),
		{ok, NReq} = post_echo(Method, HasBody, Req),
		{ok, NReq, State};
	_ ->
		{ok,NReq} = echo(undefined, Req),
		{ok, NReq, State}
	end.
    	
get_echo(<<"GET">>,Req) ->
	Res = 
		case http_utils:verify_user_key(Req) of
		true ->
			register_user("GET", Req);
		_ ->
        	http_utils:gen_result(false, 1, <<"Not found Mac_Key">>)
		end,

	cowboy_req:reply(200, [
			{<<"content-type">>, <<"text/plain; charset=utf-8">>}
		], Res,Req);
get_echo(_,Req) ->
	cowboy_req:reply(405, Req).

post_echo(<<"POST">>, true, Req) ->
	Header = cowboy_req:get(headers,Req),
	{ok, Body, _} = cowboy_req:body(Req),
	Res = 
		case http_utils:verify_user_key(Req) of
		true ->
			NBody = 
				case catch proplists:get_value(<<"content-encoding">>,Header) of 
				<<"gzip">> ->
					cow_qs:parse_qs(zlib:gunzip(Body));
				_ ->
					cow_qs:parse_qs(Body)
				end,
                   register_user("POST", NBody);
		_ ->
                http_utils:gen_result(false, 2, <<"Not found Mac_Key">>)
		end,

		cowboy_req:reply(200, [
			{<<"content-type">>, <<"text/plain; charset=utf-8">>}
		], Res, Req);
post_echo(<<"POST">>, false, Req) ->
	cowboy_req:reply(400, [], <<"Missing Post body.">>, Req);
post_echo(_, _, Req) ->
	cowboy_req:reply(405, Req).
										

echo(undefined, Req) ->
    cowboy_req:reply(400, [], <<"Missing parameter.">>, Req);
echo(Echo, Req) ->
    cowboy_req:reply(200, [
			        {<<"content-type">>, <<"text/plain; charset=utf-8">>}
	    			    ], Echo, Req).

terminate(_Reason, _Req, _State) ->
	ok.

register_user("GET", Req) ->
    QueryList = query_list(),
    case get_value(QueryList, Req, fun(Key, Sets) ->
                                           {Value, _} = cowboy_req:qs_val(list_to_binary(Key), Sets),
                                           Value
                                   end, [[], []]) of
       error ->
            http_utils:gen_result(false, 3, <<"parameter error">>);
       [Keys, Values] ->
            do_register_user(Keys, Values)
    end;

register_user("POST", Req) ->
    QueryList = query_list(),
    case get_value(QueryList, Req, fun(Key, Sets) ->
                                           proplists:get_value(list_to_binary(Key), Sets, undefined)
                                   end, [[], []]) of
       error ->
            http_utils:gen_result(false, 3, <<"parameter error">>);
       [Keys, Values] ->
            do_register_user(Keys, Values)
    end.


do_register_user(Keys, Values) ->
    Servers = ejabberd_config:get_myhosts(),
    LServer = lists:nth(1,Servers),
    KeyValues = lists:zip(Keys, Values),
    Username = proplists:get_value(<<"username">>, KeyValues),
	{Key,Val}= add_key_val(Keys,Values,KeyValues,Username),

    F = fun() ->
                odbc_queries:insert_t_no_single_quotes("users", Key, Val),
                odbc_queries:insert_t("white_list", [<<"username">>], [Username])
        end,            
    case odbc_queries:sql_transaction(LServer, F) of
                 {atomic, _} ->
                     http_utils:gen_result(true, 0, <<"success">>);
                 {aborted, Reason} ->
                     ?DEBUG("register user fail, reason is ~p~n", [Reason]),
                     http_utils:gen_result(false, http_utils:to_integer(proplists:get_value(code, Reason)), proplists:get_value(message, Reason))
             end.

get_value([], _Sets, _F, Acc) ->
    Acc;
get_value([{Key, true}|Rest], Sets, F, [Keys, Values]) ->
    case F(Key, Sets) of
        undefined ->
            error;
        Value ->
            get_value(Rest, Sets, F, [[list_to_binary(Key)|Keys], [Value|Values]])
    end;
get_value([{Key, false}|Rest], Sets, F, [Keys, Values]) ->
    case F(Key, Sets) of
        undefined ->
            get_value(Rest, Sets, F, [Keys, Values]);
        Value ->
            get_value(Rest, Sets, F, [[list_to_binary(Key)|Keys], [Value|Values]])
    end.

query_list() ->
    [{"username", true},
     {"password", true},
     {"created_at", false},
     {"name", true},
     {"dep1", true},
     {"dep2", false},
     {"dep3", false},
     {"dep4", false},
     {"dep5", false},
     {"frozen_flag", false}
    ].

assemble_depart(KeyValues) ->
	Keys = [<<"dep1">>,<<"dep2">>,<<"dep3">>,<<"dep4">>,<<"dep5">>],
	Ldep = lists:flatmap(fun(K) ->
		case  proplists:get_value(K,KeyValues) of
		undefined ->
			[];
		<<"">> ->
			[];
		V ->
			[<<"/">>,V]
		end end,Keys),
	list_to_binary(Ldep).

add_key_val(Key,Val,KeyValues,Username) ->
	Add_dep_Key = Key ++ [<<"department">>],
	Add_dep_Val = Val ++ [assemble_depart(KeyValues)],
	add_pinyin(Add_dep_Key,add_single_quotes(Add_dep_Val),Username).

add_pinyin(Key,Val,Username) ->
	Add_pinyin_Key = Key ++[<<"fpinyin">>,<<"spinyin">>],
	Add_pinyin_Val = Val ++[list_to_binary([<<"hanzi_to_pinyin('">>,Username,<<"')">>]),list_to_binary([<<"hanzi_to_pinyin('">>,Username,<<"')">>])],
	{Add_pinyin_Key,Add_pinyin_Val}.

add_single_quotes(Val) ->
	lists:flatmap(fun(V) ->
			[list_to_binary([<<"'">>,V,<<"'">>])] 
			end ,Val).
