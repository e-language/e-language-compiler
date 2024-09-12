-module(e_dumper_e).
-export([generate_code/3]).
-include("e_record_definition.hrl").

-spec generate_code(e_ast(), e_ast(), string()) -> ok.
generate_code(AST, InitCode, OutputFile) ->
	ok = file:write_file(OutputFile, statements_to_str(AST, InitCode)).

-spec statements_to_str(e_ast(), [e_stmt()]) -> iolist().
statements_to_str([#e_function{name = main, stmts = Stmts} | Rest], InitCode) ->
	Body = string:join(lists:map(fun e_util:stmt_to_str/1, Stmts), "\n\t"),
	Init = string:join(lists:map(fun e_util:stmt_to_str/1, InitCode), "\n\t"),
	CodeStr = io_lib:format("fn ~s~n%%init~n\t~s~n%%init end~n~n\t~s~n~n", [main, Init, Body]),
	[CodeStr | statements_to_str(Rest, InitCode)];
statements_to_str([#e_function{name = Name, stmts = Stmts} | Rest], InitCode) ->
	Code = string:join(lists:map(fun e_util:stmt_to_str/1, Stmts), "\n\t"),
	CodeStr = io_lib:format("fn ~s~n\t~s~n~n", [Name, Code]),
	[CodeStr | statements_to_str(Rest, InitCode)];
statements_to_str([_ | Rest], InitCode) ->
	statements_to_str(Rest, InitCode);
statements_to_str([], _) ->
	[].

