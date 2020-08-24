-module(ecompiler_expandinit).

-export([expand_initexpr_infun/2]).

-import(ecompiler_utils, [flat_format/2]).

-include("./ecompiler_frame.hrl").

expand_initexpr_infun([#function{exprs=Exprs} = F | Rest], StructMap) ->
    [F#function{exprs=expand_init(Exprs, [], {StructMap})} |
     expand_initexpr_infun(Rest, StructMap)];
expand_initexpr_infun([Any | Rest], StructMap) ->
    [Any | expand_initexpr_infun(Rest, StructMap)];
expand_initexpr_infun([], _) ->
    [].

-define(ASSIGN(Op1, Op2), #op2{operator=assign, op1=Op1, op2=Op2}).

expand_init([#if_expr{then=Then, else=Else} = E | Rest], NewAst, Ctx) ->
    expand_init(Rest,
		[E#if_expr{then=expand_init(Then, [], Ctx),
			   else=expand_init(Else, [], Ctx)} | NewAst],
		Ctx);
expand_init([#while_expr{exprs=Exprs} = E | Rest], NewAst, Ctx) ->
    expand_init(Rest,
		[E#while_expr{exprs=expand_init(Exprs, [], Ctx)} | NewAst],
		Ctx);
expand_init([#op2{operator=_} = Op | Rest], NewAst, Ctx) ->
    expand_init(Rest, replace_init_ops(Op, Ctx) ++ NewAst, Ctx);
expand_init([Any | Rest], NewAst, Ctx) ->
    expand_init(Rest, [Any | NewAst], Ctx);
expand_init([], NewAst, _) ->
    lists:reverse(NewAst).

replace_init_ops(?ASSIGN(Op1, #struct_init{name=Name, field_values=FieldValues,
					   line=Line}), {Structs} = Ctx) ->
    case maps:find(Name, Structs) of
	{ok, #struct{field_names=FieldNames,
		     field_defaults=FieldDefaults}} ->
	    FieldValueMap = maps:merge(FieldDefaults, FieldValues),
	    structinit_to_op(Op1, FieldNames, FieldValueMap, [], Ctx);
	error ->
	    throw({Line, flat_format("struct ~s is not found", [Name])})
    end;
replace_init_ops(?ASSIGN(Op1, #array_init{elements=Elements, line=Line}),
		 Ctx) ->
    arrayinit_to_op(Op1, Elements, 0, Line, [], Ctx);
replace_init_ops(Any, _) ->
    [Any].

structinit_to_op(Target, [#varref{line=Line, name=Fname} = Field | Rest],
		 FieldInitMap, Newcode, Ctx) ->
    InitCode = case maps:find(Fname, FieldInitMap) of
		   {ok, InitOp} ->
		       InitOp;
		   error ->
		       {integer, Line, 0}
	       end,
    NewAssign = #op2{operator=assign, op2=InitCode, line=Line,
		     op1=#op2{operator='.', op1=Target, op2=Field, line=Line}},
    Ops = replace_init_ops(NewAssign, Ctx),
    structinit_to_op(Target, Rest, FieldInitMap, Ops ++ Newcode, Ctx);
structinit_to_op(_, [], _, Newcode, _) ->
    Newcode.

arrayinit_to_op(Target, [E | Rest], Cnt, Line, Newcode, Ctx) ->
    Offset = {integer, Line, Cnt},
    NewAssign = #op2{operator=assign, op2=E, line=Line,
		     op1=#op1{operator='^', line=Line,
			      operand=#op2{operator='+', op2=Offset, line=Line,
					   op1=#op1{operator='@', line=Line,
						    operand=Target}}}},
    Ops = replace_init_ops(NewAssign, Ctx),
    arrayinit_to_op(Target, Rest, Cnt + 1, Line, Ops ++ Newcode, Ctx);
arrayinit_to_op(_, [], _, _, Newcode, _) ->
    Newcode.

