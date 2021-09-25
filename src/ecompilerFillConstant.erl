%%% this is the 1st pass, ast generated by yeec file is handled by this module

-module(ecompilerFillConstant).

-export([parseAndRemoveConstants/1]).

-include("ecompilerFrameDef.hrl").

%% find all consts in AST, calculate it and replace all const references.
parseAndRemoveConstants(AST) ->
    {Constants, Ast2} = fetchContants(AST),
    Ast3 = replaceContants(Ast2, Constants),
    %io:format(">>> ~p~n", [Ast3]),
    Ast3.

%% fetch constants
fetchContants(AST) ->
    fetchContants(AST, [], #{}).

fetchContants([#const{name = Name, val = Expression} | Rest], Statements, Constants) ->
    fetchContants(Rest, Statements, Constants#{Name => evaluateConstantExpression(Expression, Constants)});
fetchContants([Any | Rest], Statements, Constants) ->
    fetchContants(Rest, [Any | Statements], Constants);
fetchContants([], Statements, Constants) ->
    {Constants, lists:reverse(Statements)}.

evaluateConstantExpression(#op2{operator = '+', op1 = Operand1, op2 = Operand2}, Constants) ->
    evaluateConstantExpression(Operand1, Constants) + evaluateConstantExpression(Operand2, Constants);
evaluateConstantExpression(#op2{operator = '-', op1 = Operand1, op2 = Operand2}, Constants) ->
    evaluateConstantExpression(Operand1, Constants) - evaluateConstantExpression(Operand2, Constants);
evaluateConstantExpression(#op2{operator = '*', op1 = Operand1, op2 = Operand2}, Constants) ->
    evaluateConstantExpression(Operand1, Constants) * evaluateConstantExpression(Operand2, Constants);
evaluateConstantExpression(#op2{operator = '/', op1 = Operand1, op2 = Operand2}, Constants) ->
    evaluateConstantExpression(Operand1, Constants) / evaluateConstantExpression(Operand2, Constants);
evaluateConstantExpression(#op2{operator = 'rem', op1 = Operand1, op2 = Operand2}, Constants) ->
    evaluateConstantExpression(Operand1, Constants) rem evaluateConstantExpression(Operand2, Constants);
evaluateConstantExpression(#op2{operator = 'and', op1 = Operand1, op2 = Operand2}, Constants) ->
    (evaluateConstantExpression(Operand1, Constants) =/= 0) and (evaluateConstantExpression(Operand2, Constants) =/= 0);
evaluateConstantExpression(#op2{operator = 'or', op1 = Operand1, op2 = Operand2}, Constants) ->
    (evaluateConstantExpression(Operand1, Constants) =:= 1) or (evaluateConstantExpression(Operand2, Constants) =:= 1);
evaluateConstantExpression(#op2{operator = 'band', op1 = Operand1, op2 = Operand2}, Constants) ->
    evaluateConstantExpression(Operand1, Constants) band evaluateConstantExpression(Operand2, Constants);
evaluateConstantExpression(#op2{operator = 'bor', op1 = Operand1, op2 = Operand2}, Constants) ->
    evaluateConstantExpression(Operand1, Constants) bor evaluateConstantExpression(Operand2, Constants);
evaluateConstantExpression(#op2{operator = 'bxor', op1 = Operand1, op2 = Operand2}, Constants) ->
    evaluateConstantExpression(Operand1, Constants) bxor evaluateConstantExpression(Operand2, Constants);
evaluateConstantExpression(#op2{operator = 'bsr', op1 = Operand1, op2 = Operand2}, Constants) ->
    evaluateConstantExpression(Operand1, Constants) bsr evaluateConstantExpression(Operand2, Constants);
evaluateConstantExpression(#op2{operator = 'bsl', op1 = Operand1, op2 = Operand2}, Constants) ->
    evaluateConstantExpression(Operand1, Constants) bsl evaluateConstantExpression(Operand2, Constants);
evaluateConstantExpression(#varref{name = Name, line = Line}, Constants) ->
    case maps:find(Name, Constants) of
        {ok, Val} ->
            Val;
        error ->
            throw({Line, ecompilerUtil:flatfmt("undefined constant ~s", [Name])})
    end;
evaluateConstantExpression({ImmiType, _, Val}, _) when ImmiType =:= integer; ImmiType =:= float ->
    Val;
evaluateConstantExpression(Num, _) when is_integer(Num); is_float(Num) ->
    Num;
evaluateConstantExpression(Any, _) ->
    throw(ecompilerUtil:flatfmt("invalid const expression: ~p", [Any])).

%% replace constants in AST
replaceContants([#function_raw{params = Params, exprs = Expressions} = Fn | Rest], Constants) ->
    [Fn#function_raw{params = replaceContantsInExpressions(Params, Constants), exprs = replaceContantsInExpressions(Expressions, Constants)} | replaceContants(Rest, Constants)];
replaceContants([#struct_raw{fields = Fields} = S | Rest], Constants) ->
    [S#struct_raw{fields = replaceContantsInExpressions(Fields, Constants)} | replaceContants(Rest, Constants)];
replaceContants([#vardef{type = Type, initval = Initval} = V | Rest], Constants) ->
    [V#vardef{type = replaceConstantsInType(Type, Constants), initval = replaceContantsInExpression(Initval, Constants)} | replaceContants(Rest, Constants)];
replaceContants([], _) ->
    [].

replaceContantsInExpressions(Expressions, Constants) ->
    ecompilerUtil:expressionMap(fun (E) -> replaceContantsInExpression(E, Constants) end, Expressions).

replaceContantsInExpression(#vardef{name = Name, initval = Initval, type = Type, line = Line} = Expression, Constants) ->
    case maps:find(Name, Constants) of
        {ok, _} ->
            throw({Line, ecompilerUtil:flatfmt("~s conflicts with const", [Name])});
        error ->
            Expression#vardef{initval = replaceContantsInExpression(Initval, Constants), type = replaceConstantsInType(Type, Constants)}
    end;
replaceContantsInExpression(#varref{name = Name, line = Line} = Expression, Constants) ->
    case maps:find(Name, Constants) of
        {ok, Val} ->
            constantNumberToToken(Val, Line);
        error ->
            Expression
    end;
replaceContantsInExpression(#struct_init_raw{fields = Fields} = Expression, Constants) ->
    Expression#struct_init_raw{fields = replaceContantsInExpressions(Fields, Constants)};
replaceContantsInExpression(#array_init{elements = Elements} = Expression, Constants) ->
    Expression#array_init{elements = replaceContantsInExpressions(Elements, Constants)};
replaceContantsInExpression(#op2{op1 = Operand1, op2 = Operand2} = Expression, Constants) ->
    Expression#op2{op1 = replaceContantsInExpression(Operand1, Constants), op2 = replaceContantsInExpression(Operand2, Constants)};
replaceContantsInExpression(#op1{operand = Operand} = Expression, Constants) ->
    Expression#op1{operand = replaceContantsInExpression(Operand, Constants)};
replaceContantsInExpression(Any, _) ->
    Any.

constantNumberToToken(Num, Line) when is_float(Num) ->
    #float{val = Num, line = Line};
constantNumberToToken(Num, Line) when is_integer(Num) ->
    #integer{val = Num, line = Line}.

replaceConstantsInType(#array_type{elemtype = ElementType, len = Len} = T, Constants) ->
    T#array_type{elemtype = replaceConstantsInType(ElementType, Constants), len = evaluateConstantExpression(replaceContantsInExpression(Len, Constants), Constants)};
replaceConstantsInType(Any, _) ->
    Any.
