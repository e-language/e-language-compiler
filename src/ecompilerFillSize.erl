-module(ecompilerFillSize).

-export([expandSizeOf/2, expandSizeofInExpressions/2, fillStructInformation/2]).

-include("ecompilerFrameDef.hrl").

-spec expandSizeOf(eAST(), compilePassCtx1()) -> eAST().
expandSizeOf([#function{exprs = Expressions} = F | Rest], Ctx) ->
    [F#function{exprs = expandSizeofInExpressions(Expressions, Ctx)} | expandSizeOf(Rest, Ctx)];
expandSizeOf([#struct{field_defaults = FieldDefaults} = S | Rest], Ctx) ->
    [S#struct{field_defaults = expandSizeofInMap(FieldDefaults, Ctx)} | expandSizeOf(Rest, Ctx)];
expandSizeOf([], _) ->
    [].

expandSizeofInMap(Map, Ctx) ->
    maps:map(fun (_, V1) -> expandSizeofInExpression(V1, Ctx) end, Map).

-spec expandSizeofInExpressions(eAST(), compilePassCtx1()) -> [eExpression()].
expandSizeofInExpressions(Expressions, Ctx) ->
    ecompilerUtil:expressionMap(fun (E) -> expandSizeofInExpression(E, Ctx) end, Expressions).

-spec expandSizeofInExpression(eExpression(), compilePassCtx1()) -> eExpression().
expandSizeofInExpression(#sizeof{type = T, line = Line}, Ctx) ->
    try {integer, Line, sizeOf(T, Ctx)} catch
        I ->
            throw({Line, I})
    end;
expandSizeofInExpression(#op2{op1 = Operand1, op2 = Operand2} = O, Ctx) ->
    O#op2{op1 = expandSizeofInExpression(Operand1, Ctx), op2 = expandSizeofInExpression(Operand2, Ctx)};
expandSizeofInExpression(#op1{operand = Operand} = O, Ctx) ->
    O#op1{operand = expandSizeofInExpression(Operand, Ctx)};
expandSizeofInExpression(#struct_init{field_values = ExprMap} = Si, Ctx) ->
    Si#struct_init{field_values = expandSizeofInMap(ExprMap, Ctx)};
expandSizeofInExpression(#array_init{elements = Elements} = Ai, Ctx) ->
    Ai#array_init{elements = expandSizeofInExpressions(Elements, Ctx)};
expandSizeofInExpression(Any, _) ->
    Any.

%% calculate struct size and collect field offsets.
%%
%% In the current algorithm, the size of the same struct will be calculated for multiple times, which is not necessary.
%% But the code is beautiful, so I will just keep it as it is now.
%% use a process to hold the calculated struct info when the speed really becomes a problem.
-spec fillStructInformation(eAST(), compilePassCtx1()) -> eAST().
fillStructInformation(AST, {_, PointerWidth} = Ctx) ->
    %% struct definition are only allowed in top level of an AST.
    Ast1 = lists:map(fun (E) -> fillStructSize(E, Ctx) end, AST),
    {_, StructMap1} = ecompilerUtil:makeFunctionAndStructMapFromAST(Ast1),
    lists:map(fun (E) -> fillStructOffsets(E, {StructMap1, PointerWidth}) end, Ast1).

-spec fillStructSize(eExpression(), compilePassCtx1()) -> eExpression().
fillStructSize(#struct{} = S, Ctx) ->
    S#struct{size = sizeOfStruct(S, Ctx)};
fillStructSize(Any, _) ->
    Any.

-spec fillStructOffsets(eExpression(), compilePassCtx1()) -> eExpression().
fillStructOffsets(#struct{} = S, Ctx) ->
    S#struct{field_offsets = offsetOfStruct(S, Ctx)};
fillStructOffsets(Any, _) ->
    Any.

-spec offsetOfStruct(#struct{}, compilePassCtx1()) -> #{atom() := integer()}.
offsetOfStruct(#struct{field_names = FieldNames, field_types = FieldTypes}, Ctx) ->
    FieldTypeList = getKVsByReferences(FieldNames, FieldTypes),
    {_, OffsetMap} = sizeOfStructFields(FieldTypeList, 0, #{}, Ctx),
    OffsetMap.

-spec sizeOfStruct(#struct{}, compilePassCtx1()) -> non_neg_integer().
sizeOfStruct(#struct{size = Size}, _) when is_integer(Size), Size > 0 ->
    Size;
sizeOfStruct(#struct{field_names = Names, field_types = Types}, Ctx) ->
    FieldTypeList = getKVsByReferences(Names, Types),
    {Size, _} = sizeOfStructFields(FieldTypeList, 0, #{}, Ctx),
    Size.

-spec getKVsByReferences([#varref{}], #{atom() := any()}) -> [{atom(), any()}].
getKVsByReferences(RefList, Map) ->
    Keys = ecompilerUtil:namesOfVariableReferences(RefList),
    Values = ecompilerUtil:getValuesByKeys(Keys, Map),
    lists:zip(Keys, Values).

%% this is the function that calculate size and offsets
-spec sizeOfStructFields([{atom(), eType()}], integer(), OffsetMap, compilePassCtx1()) -> {integer(), OffsetMap}
        when OffsetMap :: #{atom() := integer()}.
sizeOfStructFields([{Fname, Ftype} | Rest], CurrentOffset, OffsetMap, {_, PointerWidth} = Ctx) ->
    FieldSize = sizeOf(Ftype, Ctx),
    NextOffset = CurrentOffset + FieldSize,
    case CurrentOffset rem PointerWidth =/= 0 of
        true ->
            OffsetFixed = fixStructFieldOffset(CurrentOffset, NextOffset, PointerWidth),
            sizeOfStructFields(Rest, OffsetFixed + FieldSize, OffsetMap#{Fname => OffsetFixed}, Ctx);
        false ->
            sizeOfStructFields(Rest, NextOffset, OffsetMap#{Fname => CurrentOffset}, Ctx)
    end;
sizeOfStructFields([], CurrentOffset, OffsetMap, _) ->
    {CurrentOffset, OffsetMap}.

-spec fixStructFieldOffset(integer(), integer(), integer()) -> integer().
fixStructFieldOffset(CurrentOffset, NextOffset, PointerWidth) ->
    case ecompilerUtil:cutExtra(NextOffset, PointerWidth) > ecompilerUtil:cutExtra(CurrentOffset, PointerWidth) of
        true ->
            ecompilerUtil:fillOffset(CurrentOffset, PointerWidth);
        false ->
            CurrentOffset
    end.

-spec sizeOf(eType(), compilePassCtx1()) -> non_neg_integer().
sizeOf(#array_type{elemtype = T, len = Len}, {_, PointerWidth} = Ctx) ->
    ElemSize = sizeOf(T, Ctx),
    FixedSize = case ElemSize < PointerWidth of
                    true ->
                        case PointerWidth rem ElemSize of
                            0 ->
                                ElemSize;
                            _ ->
                                PointerWidth
                        end;
                    false ->
                        ecompilerUtil:fillToPointerWidth(ElemSize, PointerWidth)
                end,
    FixedSize * Len;
sizeOf(#basic_type{pdepth = N}, {_, PointerWidth}) when N > 0 ->
    PointerWidth;
sizeOf(#basic_type{class = struct, tag = Tag}, {StructMap, _} = Ctx) ->
    case maps:find(Tag, StructMap) of
        {ok, S} ->
            sizeOfStruct(S, Ctx);
        error ->
            throw(ecompilerUtil:flatfmt("~s is not found", [Tag]))
    end;
sizeOf(#basic_type{class = C, tag = Tag}, {_, PointerWidth}) when C =:= integer; C =:= float ->
    case ecompilerUtil:primitiveSizeOf(Tag) of
        pwidth ->
            PointerWidth;
        V when is_integer(V) ->
            V
    end;
sizeOf(#fun_type{}, {_, PointerWidth}) ->
    PointerWidth;
sizeOf(A, _) ->
    throw(ecompilerUtil:flatfmt("invalid type ~p on sizeof", [A])).
