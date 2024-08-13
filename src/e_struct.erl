-module(e_struct).
-export([eliminate_dot_in_ast/3, eliminate_dot_in_stmts/3]).
-include("e_record_definition.hrl").

-type interface_context() :: {#{atom() => #e_fn_type{}}, #{atom() => #e_struct{}}}.

-spec eliminate_dot_in_ast(e_ast(), #e_vars{}, interface_context()) -> e_ast().
eliminate_dot_in_ast([#e_function{stmts = Stmts0} = Fn | Rest], GlobalVars, {FnTypeMap, StructMap} = Ctx) ->
	Vars = e_util:merge_vars(GlobalVars, Fn#e_function.vars, ignore_tag),
	Stmts1 = eliminate_dot(Stmts0, {Vars, FnTypeMap, StructMap, #e_basic_type{}}),
	[Fn#e_function{stmts = Stmts1} | eliminate_dot_in_ast(Rest, GlobalVars, Ctx)];
eliminate_dot_in_ast([Any | Rest], GlobalVars, Ctx) ->
	[Any | eliminate_dot_in_ast(Rest, GlobalVars, Ctx)];
eliminate_dot_in_ast([], _, _) ->
	[].

-spec eliminate_dot_in_stmts([e_stmt()], #e_vars{}, interface_context()) -> [e_stmt()].
eliminate_dot_in_stmts(Stmts, Vars, {FnTypeMap, StructMap}) ->
	eliminate_dot(Stmts, {Vars, FnTypeMap, StructMap, #e_basic_type{}}).

%% This `context()` is the same as the one in `e_type.erl`.
-type context() ::
	{
	GlobalVarTypes :: #e_vars{},
	FnTypeMap :: #{atom() := #e_fn_type{}},
	StructMap :: #{atom() => #e_struct{}},
	ReturnType :: e_type()
	}.

-spec eliminate_dot([e_stmt()], context()) -> [e_stmt()].
eliminate_dot(Stmts0, Ctx) ->
	Stmts1 = e_util:expr_map(fun(E) -> eliminate_dot_in_expr(E, Ctx) end, Stmts0),
	e_util:eliminate_pointer(Stmts1).

%% `a.b` will be converted to `(a@ + OFFSET_OF_b)^`.
-spec eliminate_dot_in_expr(e_expr(), context()) -> e_expr().
eliminate_dot_in_expr(#e_op{tag = '.', line = L} = Op, {_, _, StructMap, _} = Ctx) ->
	#e_op{data = [O, #e_varref{name = FieldName}]} = Op,
	#e_basic_type{class = struct, tag = Name, p_depth = 0} = e_type:type_of_node(O, Ctx),
	{ok, #e_struct{fields = #e_vars{offset_map = FieldOffsetMap}}} = maps:find(Name, StructMap),
	{ok, Offset} = maps:find(FieldName, FieldOffsetMap),
	A = #e_op{tag = '@', data = [eliminate_dot_in_expr(O, Ctx)], line = L},
	B = #e_op{tag = '+', data = [A, #e_integer{value = Offset, line = L}], line = L},
	#e_op{tag = '^', data = [B]};
eliminate_dot_in_expr(#e_op{data = Args} = Op, Ctx) ->
	Op#e_op{data = lists:map(fun(E) -> eliminate_dot_in_expr(E, Ctx) end, Args)};
eliminate_dot_in_expr(Any, _) ->
	Any.
