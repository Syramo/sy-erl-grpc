%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @file common.hrl
%%% @author helge
%%% @copyright (C) 2021, Vigilant AI
%%% Created : 07. December 2021 @ 08:47:59
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-author("helge").

-include_lib("kernel/include/logger.hrl").

-ifdef(debug).

    -define (DBGV(X),io:format("~n~n~p/~p:~n~p~n~n",[?MODULE,?FUNCTION_NAME,X])).

    -ifdef(use_logger).
        
        -define (DLOG(X), ?LOG_NOTICE(X)).
        -define (DLOG(X,Y), ?LOG_NOTICE(X,Y)).

    -else.

        -define (DLOG(X),io:format("~p (~B): ~p~n",[?MODULE, ?LINE , X])).
        -define (DLOG(X,Y),io:format("~p (~B): " X  "~n",[?MODULE, ?LINE | Y])).
        
    -endif.

-else.

    -define (DBGV(X), _=X, true).
    -define (DLOG(X), _=X, true).
    -define (DLOG(X,Y), _=X, _=Y, true).

-endif.

-define (STPROF,Xprofile_start=erlang:system_time(millisecond), Xprofile_line=?LINE-1).
-define (PROFILE,io:format("PROFILE: ~s:~s/~B (~B) took ~B ms~n",[?MODULE,?FUNCTION_NAME,?FUNCTION_ARITY,Xprofile_line, erlang:system_time(millisecond)-Xprofile_start])).

