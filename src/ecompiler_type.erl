-module(ecompiler_type).

-export([checktype_ast/3, checktype_exprs/3, typeof_expr/2]).

-import(ecompiler_utils, [expr2str/1, flat_format/2, void_type/1, assert/2]).

-include("./ecompiler_frame.hrl").

checktype_ast([#function{var_types=VarTypes, exprs=Exprs, type=Fntype} | Rest],
	      GlobalVarTypes, {FunctionMap, StructMap} = Maps) ->
	checktype_types(maps:values(VarTypes), StructMap),
	checktype_type(Fntype#fun_type.ret, StructMap),
	CurrentVars = maps:merge(GlobalVarTypes, VarTypes),
	Ctx = {CurrentVars, FunctionMap, StructMap, Fntype#fun_type.ret},
	typeof_exprs(Exprs, Ctx),
	checktype_ast(Rest, GlobalVarTypes, Maps);

checktype_ast([#struct{name=Name, field_types=FieldTypes,
		       field_names=FieldNames, field_defaults=FieldDefaults} |
	       Rest], GlobalVarTypes, {FunctionMap, StructMap} = Maps) ->
	checktype_types(maps:values(FieldTypes), StructMap),
	Ctx = {GlobalVarTypes, FunctionMap, StructMap, none},
	%% check the default values for fields
	check_structfields(FieldNames, FieldTypes, FieldDefaults, Name, Ctx),
	checktype_ast(Rest, GlobalVarTypes, Maps);

checktype_ast([_ | Rest], GlobalVarTypes, Maps) ->
	checktype_ast(Rest, GlobalVarTypes, Maps);

checktype_ast([], _, _) ->
	ok.


checktype_exprs(Exprs, GlobalVarTypes, {FunctionMap, StructMap}) ->
	Ctx = {GlobalVarTypes, FunctionMap, StructMap, none},
	typeof_exprs(Exprs, Ctx).

typeof_exprs([Expr | Rest], Ctx) ->
	[typeof_expr(Expr, Ctx) | typeof_exprs(Rest, Ctx)];
typeof_exprs([], _) ->
	[].

typeof_expr(#op2{operator=assign, op1=Op1, op2=Op2, line=Line},
	    {_, _, StructMap, _} = Ctx) ->
	TypeofOp1 = case Op1 of
			    #op2{operator='.', op1=SubOp1, op2=SubOp2} ->
				    S = typeof_expr(SubOp1, Ctx),
				    typeof_structfield(S, SubOp2, StructMap,
						       Line);
			    #op1{operator='^', operand=SubOp} ->
				    decr_pdepth(typeof_expr(SubOp, Ctx), Line);
			    #varref{} ->
				    typeof_expr(Op1, Ctx);
			    Any ->
				    throw({Line,
					   flat_format("invalid left value ~s",
						       [expr2str(Any)])})
		    end,
	TypeofOp2 = typeof_expr(Op2, Ctx),
	case compare_type(TypeofOp1, TypeofOp2) of
		false ->
			throw({Line,
			       flat_format("type mismatch in \"~s = ~s\"",
					   [fmt_type(TypeofOp1),
					    fmt_type(TypeofOp2)])});
		_ ->
			TypeofOp1
	end;
typeof_expr(#op2{operator='.', op1=Op1, op2=Op2, line=Line},
	    {_, _, StructMap, _} = Ctx) ->
	typeof_structfield(typeof_expr(Op1, Ctx), Op2, StructMap, Line);
typeof_expr(#op2{operator='::', op1=#varref{name=self}, op2=Op2}, Ctx) ->
	typeof_expr(Op2, Ctx);
typeof_expr(#op2{operator='::', op1=Op1, op2=Op2, line=Line}, _) ->
	assert(is_record(Op1, varref), {Line, "invalid usage on ::"}),
	assert(is_record(Op2, varref), {Line, "invalid usage on ::"}),
	#varref{name=ModName} = Op1,
	#varref{name=FunName} = Op2,
	try
		ecompiler:query_modulefun(ModName, FunName)
	of
		{error, module_notfound, _} ->
			throw({Line, flat_format("module ~s is not found",
						 [ModName])});
		{error, function_notfound} ->
			throw({Line, flat_format("~s:~s is not found",
						 [ModName, FunName])});
		{ok, Type} ->
			Type
	catch
		throw:E ->
			throw({Line, E})
	end;
typeof_expr(#op2{operator='+', op1=Op1, op2=Op2, line=Line}, Ctx) ->
	TypeofOp1 = typeof_expr(Op1, Ctx),
	TypeofOp2 = typeof_expr(Op2, Ctx),
	case is_bothnumber_sametype(TypeofOp1, TypeofOp2) of
		false ->
			case is_pointer_and_int(TypeofOp1, TypeofOp2) of
				false ->
					E = type_mismatchinfo_op2('+',
								  TypeofOp1,
								  TypeofOp2),
					throw({Line, E});
				{true, Ptype} ->
					Ptype
			end;
		{true, T} ->
			T
	end;
%% integer + pointer is valid, but integer - pointer is invalid
typeof_expr(#op2{operator='-', op1=Op1, op2=Op2, line=Line}, Ctx) ->
	TypeofOp1 = typeof_expr(Op1, Ctx),
	TypeofOp2 = typeof_expr(Op2, Ctx),
	case is_bothnumber_sametype(TypeofOp1, TypeofOp2) of
		false ->
			case is_pointer_and_int_order(TypeofOp1, TypeofOp2) of
				false ->
					E = type_mismatchinfo_op2('-',
								  TypeofOp1,
								  TypeofOp2),
					throw({Line, E});
				{true, Ptype} ->
					Ptype
			end;
		{true, T} ->
			T
	end;
typeof_expr(#op2{operator=Op, op1=Op1, op2=Op2, line=Line}, Ctx)
  when Op =:= '*'; Op =:= '/' ->
	TypeofOp1 = typeof_expr(Op1, Ctx),
	TypeofOp2 = typeof_expr(Op2, Ctx),
	case is_bothnumber_sametype(TypeofOp1, TypeofOp2) of
		false ->
			throw({Line, type_mismatchinfo_op2(Op, TypeofOp1,
							   TypeofOp2)});
		{true, T} ->
			T
	end;
%% the left operators are: and, or, band, bor, bxor, bsl, bsr, >, <, ...
typeof_expr(#op2{operator=Op, op1=Op1, op2=Op2, line=Line}, Ctx) ->
	TypeofOp1 = typeof_expr(Op1, Ctx),
	TypeofOp2 = typeof_expr(Op2, Ctx),
	case is_bothinteger(TypeofOp1, TypeofOp2) of
		false ->
			throw({Line, type_mismatchinfo_op2(Op, TypeofOp1,
							   TypeofOp2)});
		true ->
			TypeofOp1
	end;
typeof_expr(#op1{operator='^', operand=Operand, line=Line}, Ctx) ->
	case typeof_expr(Operand, Ctx) of
		#basic_type{} = T ->
			decr_pdepth(T, Line);
		_ ->
			throw({Line, flat_format("invalid \"^\" on operand ~s",
						 [expr2str(Operand)])})
	end;
typeof_expr(#op1{operator='@', operand=Operand, line=Line},
	    {_, _, StructMap, _} = Ctx) ->
	case Operand of
		#op2{operator='.', op1=Op1, op2=Op2} ->
			T = typeof_structfield(typeof_expr(Op1, Ctx),
					       Op2, StructMap, Line),
			incr_pdepth(T, Line);
		#varref{} ->
			incr_pdepth(typeof_expr(Operand, Ctx), Line);
		_ ->
			throw({Line, flat_format("invalid \"@\" on operand ~s",
						 [expr2str(Operand)])})
	end;
typeof_expr(#op1{operand=Operand}, Ctx) ->
	typeof_expr(Operand, Ctx);
typeof_expr(#call{fn=FunExpr, args=Args, line=Line}, Ctx) ->
	ArgsTypes = typeof_exprs(Args, Ctx),
	case typeof_expr(FunExpr, Ctx) of
		#fun_type{params=FnParamTypes, ret=FnRetType} ->
			case compare_types(ArgsTypes, FnParamTypes) of
				false ->
					E = args_errorinfo(FnParamTypes,
							   ArgsTypes),
					throw({Line, E});
				true ->
					FnRetType
			end;
		T ->
			throw({Line, flat_format("invalid function expr: ~s",
						 [fmt_type(T)])})
	end;
typeof_expr(#if_expr{condition=Condition, then=Then, else=Else, line=Line},
	    Ctx) ->
	typeof_expr(Condition, Ctx),
	typeof_exprs(Then, Ctx),
	typeof_exprs(Else, Ctx),
	void_type(Line);
typeof_expr(#while_expr{condition=Condition, exprs=Exprs, line=Line}, Ctx) ->
	typeof_expr(Condition, Ctx),
	typeof_exprs(Exprs, Ctx),
	void_type(Line);
typeof_expr(#return{expr=Expr, line=Line}, {_, _, _, FnRetType} = Ctx) ->
	RealRet = typeof_expr(Expr, Ctx),
	case compare_type(RealRet, FnRetType) of
		false ->
			E = flat_format("ret type should be (~s), not (~s)",
					[fmt_type(FnRetType),
					 fmt_type(RealRet)]),
			throw({Line, E});
		true ->
			RealRet
	end;
typeof_expr(#varref{name=Name, line=Line},
	    {VarTypes, FunctionMap, StructMap, _}) ->
	NotFoundError = flat_format("variable ~s is undefined", [Name]),
	Type = case maps:find(Name, VarTypes) of
		       error ->
			       case maps:find(Name, FunctionMap) of
				       error ->
					       throw({Line, NotFoundError});
				       {ok, T} ->
					       T
			       end;
		       {ok, T} ->
			       T
	       end,
	checktype_type(Type, StructMap),
	Type;
typeof_expr(#array_init{elements=Elements, line=Line}, Ctx) ->
	ElementTypes = typeof_exprs(Elements, Ctx),
	case are_sametype(ElementTypes) of
		true ->
			#array_type{elemtype=hd(ElementTypes),
				    len=length(ElementTypes), line=Line};
		_ ->
			throw({Line,
			       flat_format("array init type conflict: {~s}",
					   [fmt_types_join(ElementTypes)])})
	end;
typeof_expr(#struct_init{name=StructName, field_names=InitFieldNames,
			 field_values=InitFieldValues, line=Line},
	    {_, _, StructMap, _} = Ctx) ->
	case maps:find(StructName, StructMap) of
		{ok, #struct{field_types=FieldTypes}} ->
			check_structfields(InitFieldNames, FieldTypes,
					   InitFieldValues, StructName,
					   Ctx),
			#basic_type{class=struct, tag=StructName,
				    pdepth=0, line=Line};
		_ ->
			throw({Line, flat_format("struct ~s is not found",
						 [StructName])})
	end;
typeof_expr(#sizeof{line=Line}, _) ->
	#basic_type{class=integer, pdepth=0, tag=i64, line=Line};
typeof_expr(#goto{line=Line}, _) ->
	void_type(Line);
typeof_expr(#label{line=Line}, _) ->
	void_type(Line);
typeof_expr({float, Line, _}, _) ->
	#basic_type{class=float, pdepth=0, tag=f64, line=Line};
typeof_expr({integer, Line, _}, _) ->
	#basic_type{class=integer, pdepth=0, tag=i64, line=Line};
typeof_expr({string, Line, _}, _) ->
	#basic_type{class=integer, pdepth=1, tag=i8, line=Line}.

args_errorinfo(FnParamTypes, ArgsTypes) ->
	flat_format("args should be (~s), not (~s)",
		    [fmt_types_join(FnParamTypes),
		     fmt_types_join(ArgsTypes)]).

incr_pdepth(#basic_type{pdepth=Pdepth} = T, _) ->
	T#basic_type{pdepth=Pdepth+1};
incr_pdepth(#array_type{elemtype=#basic_type{pdepth=Pdepth} = T}, _) ->
	T#basic_type{pdepth=Pdepth+1};
incr_pdepth(#fun_type{}, OpLine) ->
	throw({OpLine, "@ on function type is not allowed"}).

decr_pdepth(#basic_type{pdepth=Pdepth} = T, Line) ->
	if Pdepth > 0 ->
		   T#basic_type{pdepth=Pdepth-1};
	   true ->
		   throw({Line, "^ on a non-pointer type"})
	end;
decr_pdepth(#array_type{} = Type, OpLine) ->
	throw({OpLine, flat_format("pointer- on array type ~s is invalid",
				   [fmt_type(Type)])});
decr_pdepth(#fun_type{}, OpLine) ->
	throw({OpLine, "^ on function type is not allowed"}).

check_structfields([#varref{name=F, line=Line} | Rest], FieldTypes,
		   ValMap, StructName, Ctx) ->
	case maps:find(F, ValMap) of
		{ok, Val} ->
			check_fieldvalue(F, typeof_expr(Val, Ctx),
					 FieldTypes, StructName, Line),
			check_structfields(Rest, FieldTypes, ValMap,
					   StructName, Ctx);
		error ->
			check_structfields(Rest, FieldTypes, ValMap,
					   StructName, Ctx)
	end;
check_structfields([], _, _, _, _) ->
	ok.

check_fieldvalue(FieldName, GivenType, FieldTypes, StructName, Line) ->
	case maps:find(FieldName, FieldTypes) of
		{ok, T} ->
			E = flat_format("~s.~s type error: ~s = ~s",
					[StructName, FieldName, fmt_type(T),
					 fmt_type(GivenType)]),
			case compare_type(T, GivenType) of
				false ->
					throw({Line, E});
				_ ->
					ok
			end;
		error ->
			throw({Line,
			       flat_format("field ~s does not exist",
					   [FieldName])})
	end.

are_sametype([TargetType, TargetType | Rest]) ->
	are_sametype([TargetType | Rest]);
are_sametype([_]) ->
	true;
are_sametype(_) ->
	false.

typeof_structfield(#basic_type{class=struct, tag=StructName, pdepth=0},
		   #varref{name=FieldName}, StructMap, Line) ->
	case maps:find(StructName, StructMap) of
		{ok, S} ->
			get_field_type(S, FieldName, StructMap, Line);
		error ->
			throw({Line, flat_format("struct ~s is not found",
						 [StructName])})
	end;
typeof_structfield(T, _, _, Line) ->
	throw({Line, flat_format("op1 for \".\" is not struct ~s",
				 [fmt_type(T)])}).

get_field_type(#struct{name=StructName, field_types=FieldTypes},
	       FieldName, StructMap, Line) ->
	case maps:find(FieldName, FieldTypes) of
		{ok, Type} ->
			checktype_type(Type, StructMap),
			Type;
		error ->
			throw({Line,
			       flat_format("\"~s.~s\" does not exist",
					   [StructName, FieldName])})
	end.

compare_types([T1 | Types1], [T2 | Types2]) ->
	case compare_type(T1, T2) of
		true ->
			compare_types(Types1, Types2);
		_ ->
			false
	end;
compare_types([], []) ->
	true;
compare_types(_, _) ->
	false.

compare_type(#fun_type{params=P1, ret=R1},
	     #fun_type{params=P2, ret=R2}) ->
	compare_types(P1, P2) and compare_type(R1, R2);
compare_type(#array_type{elemtype=E1, len=L1},
	     #array_type{elemtype=E2, len=L2}) ->
	compare_type(E1, E2) and (L1 =:= L2);
compare_type(#basic_type{class=integer, pdepth=0},
	     #basic_type{class=integer, pdepth=0}) ->
	true;
compare_type(#basic_type{class=C, tag=T, pdepth=P},
	     #basic_type{class=C, tag=T, pdepth=P}) ->
	true;
compare_type(_, _) ->
	false.

is_pointer_and_int_order(#basic_type{pdepth=N} = O,
			 #basic_type{class=integer, pdepth=0})
  when N > 0 ->
	{true, O};
is_pointer_and_int_order(_, _) ->
	false.

is_pointer_and_int(#basic_type{pdepth=N} = O,
		   #basic_type{class=integer, pdepth=0}) when N > 0 ->
	{true, O};
is_pointer_and_int(#basic_type{class=integer, pdepth=0},
		   #basic_type{pdepth=N} = O) when N > 0 ->
	{true, O};
is_pointer_and_int(_, _) ->
	false.

is_bothnumber_sametype(T1, T2) ->
	case (is_bothinteger(T1, T2) or is_bothfloat(T1, T2)) of
		true ->
			{true, T1};
		false ->
			false
	end.

is_bothinteger(#basic_type{pdepth=0, class=integer},
	       #basic_type{pdepth=0, class=integer}) ->
	true;
is_bothinteger(_, _) ->
	false.

is_bothfloat(#basic_type{pdepth=0, class=float},
	     #basic_type{pdepth=0, class=float}) ->
	true;
is_bothfloat(_, _) ->
	false.

type_mismatchinfo_op2(Operator, TypeofOp1, TypeofOp2) ->
	flat_format("type error in \"~s ~s ~s\"",
		    [fmt_type(TypeofOp1), Operator, fmt_type(TypeofOp2)]).

checktype_types(TypeList, StructMap) ->
	lists:map(fun(T) -> checktype_type(T, StructMap) end, TypeList).

%% check type, ensure that all struct used by type exists.
checktype_type(#basic_type{class=struct, tag=Tag, line=Line},
	       StructMap) ->
	case maps:find(Tag, StructMap) of
		error ->
			throw({Line, flat_format("struct ~s is not found",
						 [Tag])});
		{ok, _} ->
			ok
	end;
checktype_type(#basic_type{}, _) ->
	ok;
checktype_type(#array_type{elemtype=Elemtype}, StructMap) ->
	case Elemtype of
		#array_type{line=Line} ->
			throw({Line, "nested array is not supported"});
		_ ->
			checktype_type(Elemtype, StructMap)
	end;
checktype_type(#fun_type{params=Params, ret=Rettype}, StructMap) ->
	checktype_types(Params, StructMap),
	checktype_type(Rettype, StructMap).

fmt_types_join(Types) ->
	lists:join(",", fmt_types(Types)).

fmt_types(Types) -> fmt_types(Types, []).

fmt_types([Type | Rest], Result) ->
	fmt_types(Rest, [fmt_type(Type) | Result]);
fmt_types([], Result) ->
	lists:reverse(Result).

fmt_type(#fun_type{params=Params, ret=Rettype}) ->
	io_lib:format("fun(~s): ~s", [fmt_types_join(Params),
				      fmt_type(Rettype)]);
fmt_type(#array_type{elemtype=Type, len=N}) ->
	io_lib:format("{~s, ~w}", [fmt_type(Type), N]);
fmt_type(#basic_type{tag=Tag, pdepth=Pdepth}) when Pdepth > 0 ->
	io_lib:format("(~s~s)", [Tag, lists:duplicate(Pdepth, "^")]);
fmt_type(#basic_type{tag=Tag, pdepth=0}) ->
	atom_to_list(Tag).

