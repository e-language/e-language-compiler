-module(e_size).
-export([expand_kw_in_ast/2, expand_kw_in_stmts/2, fill_offsets_in_stmts/2, fill_offsets_in_vars/2]).
-export([size_of/2, align_of/2]).
-include("e_record_definition.hrl").

-type context() :: {StructMap :: #{atom() => #e_struct{}}, PointerWidth :: non_neg_integer()}.

-spec expand_kw_in_ast(e_ast(), context()) -> e_ast().
expand_kw_in_ast([#e_function{stmts = Stmts} = Fn | Rest], Ctx) ->
	[Fn#e_function{stmts = expand_kw_in_stmts(Stmts, Ctx)} | expand_kw_in_ast(Rest, Ctx)];
expand_kw_in_ast([#e_struct{default_value_map = FieldDefaults} = S | Rest], Ctx) ->
	[S#e_struct{default_value_map = expand_kw_in_map(FieldDefaults, Ctx)} | expand_kw_in_ast(Rest, Ctx)];
expand_kw_in_ast([], _) ->
	[].

-spec expand_kw_in_stmts([e_stmt()], context()) -> [e_stmt()].
expand_kw_in_stmts(Stmts, Ctx) ->
	e_util:expr_map(fun(E) -> expand_kw_in_expr(E, Ctx) end, Stmts).

-spec expand_kw_in_expr(e_expr(), context()) -> e_expr().
expand_kw_in_expr(#e_op{tag = {sizeof, T}, loc = Loc}, Ctx) ->
	#e_integer{value = size_of(T, Ctx), loc = Loc};
expand_kw_in_expr(#e_op{tag = {alignof, T}, loc = Loc}, Ctx) ->
	#e_integer{value = align_of(T, Ctx), loc = Loc};
expand_kw_in_expr(#e_op{tag = {call, Callee}, data = Args} = E, Ctx) ->
	E#e_op{tag = {call, expand_kw_in_expr(Callee, Ctx)}, data = lists:map(fun(O) -> expand_kw_in_expr(O, Ctx) end, Args)};
expand_kw_in_expr(#e_op{data = Data} = E, Ctx) ->
	E#e_op{data = lists:map(fun(O) -> expand_kw_in_expr(O, Ctx) end, Data)};
expand_kw_in_expr(#e_struct_init_expr{field_value_map = ExprMap} = S, Ctx) ->
	S#e_struct_init_expr{field_value_map = expand_kw_in_map(ExprMap, Ctx)};
expand_kw_in_expr(#e_array_init_expr{elements = Elements} = A, Ctx) ->
	A#e_array_init_expr{elements = lists:map(fun(E) -> expand_kw_in_expr(E, Ctx) end, Elements)};
expand_kw_in_expr(Any, _) ->
	Any.

expand_kw_in_map(Map, Ctx) ->
	maps:map(fun(_, V1) -> expand_kw_in_expr(V1, Ctx) end, Map).

-spec fill_offsets_in_stmts(e_ast(), context()) -> e_ast().
fill_offsets_in_stmts([#e_function{vars = Old} = Fn | Rest], Ctx) ->
	[Fn#e_function{vars = fill_offsets_in_vars(Old, Ctx)} | fill_offsets_in_stmts(Rest, Ctx)];
fill_offsets_in_stmts([#e_struct{name = Name, fields = Old} = S | Rest], {StructMap, PointerWidth} = Ctx) ->
	FilledS = S#e_struct{fields = fill_offsets_in_vars(Old, Ctx)},
	%% StructMap in Ctx got updated to avoid some duplicated calculations.
	[FilledS | fill_offsets_in_stmts(Rest, {StructMap#{Name := FilledS}, PointerWidth})];
fill_offsets_in_stmts([Any | Rest], Ctx) ->
	[Any | fill_offsets_in_stmts(Rest, Ctx)];
fill_offsets_in_stmts([], _) ->
	[].

-spec fill_offsets_in_vars(#e_vars{}, context()) -> #e_vars{}.
fill_offsets_in_vars(#e_vars{} = Vars, Ctx) ->
	{Size, Align, OffsetMap} = size_and_offsets_of_vars(Vars, Ctx),
	Vars#e_vars{offset_map = OffsetMap, size = Size, align = Align}.

-spec size_of_struct(#e_struct{}, context()) -> non_neg_integer().
size_of_struct(#e_struct{fields = #e_vars{size = Size}}, _) when Size > 0 ->
	Size;
size_of_struct(#e_struct{fields = Fields}, Ctx) ->
	{Size, _, _} = size_and_offsets_of_vars(Fields, Ctx),
	Size.

-spec align_of_struct(#e_struct{}, context()) -> non_neg_integer().
align_of_struct(#e_struct{fields = #e_vars{align = Align}}, _) when Align > 0 ->
	Align;
align_of_struct(#e_struct{fields = #e_vars{type_map = TypeMap}}, Ctx) ->
	maps:fold(fun(_, Type, Align) -> erlang:max(align_of(Type, Ctx), Align) end, 0, TypeMap).


-type size_and_offsets_result() ::
	{Size :: non_neg_integer(), Align :: non_neg_integer(), OffsetMap :: #{atom() => var_offset()}}.

-spec size_and_offsets_of_vars(#e_vars{}, context()) -> size_and_offsets_result().
size_and_offsets_of_vars(#e_vars{names = Names, type_map = TypeMap}, Ctx) ->
	TypeList = e_util:get_kvpair_by_keys(Names, TypeMap),
	size_and_offsets(TypeList, {0, 1, #{}}, Ctx).

-spec size_and_offsets([{atom(), e_type()}], In, context()) -> Out
	when In :: size_and_offsets_result(), Out :: size_and_offsets_result().

size_and_offsets([{Name, Type} | Rest], {CurrentOffset, MaxAlign, OffsetMap}, Ctx) ->
	CurrentAlign = align_of(Type, Ctx),
	FieldSize = size_of(Type, Ctx),
	Offset = e_util:fill_unit_pessi(CurrentOffset, CurrentAlign),
	OffsetMapNew = OffsetMap#{Name => {Offset, FieldSize}},
	MaxAlignNew = erlang:max(MaxAlign, CurrentAlign),
	size_and_offsets(Rest, {Offset + FieldSize, MaxAlignNew, OffsetMapNew}, Ctx);
size_and_offsets([], {CurrentOffset, MaxAlign, OffsetMap}, _) ->
	%% The size should be aligned to MaxAlign.
	{e_util:fill_unit_pessi(CurrentOffset, MaxAlign), MaxAlign, OffsetMap}.

-spec size_of(e_type(), context()) -> non_neg_integer().
size_of(#e_array_type{elem_type = T, length = Len}, Ctx) ->
	size_of(T, Ctx) * Len;
size_of(#e_fn_type{}, {_, PointerWidth}) ->
	PointerWidth;
size_of(#e_basic_type{p_depth = N}, {_, PointerWidth}) when N > 0 ->
	PointerWidth;
size_of(#e_basic_type{class = struct} = S, {StructMap, _} = Ctx) ->
	size_of_struct(e_util:get_struct_from_type(S, StructMap), Ctx);
size_of(#e_basic_type{class = C, tag = Tag}, {_, PointerWidth}) when C =:= integer; C =:= float ->
	e_util:primitive_size_of(Tag, PointerWidth);
size_of(Any, _) ->
	e_util:ethrow(element(2, Any), "invalid type ~p on sizeof", [Any]).

-spec align_of(e_type(), context()) -> non_neg_integer().
align_of(#e_array_type{elem_type = T}, Ctx) ->
	align_of(T, Ctx);
align_of(#e_fn_type{}, {_, PointerWidth}) ->
	PointerWidth;
align_of(#e_basic_type{p_depth = N}, {_, PointerWidth}) when N > 0 ->
	PointerWidth;
align_of(#e_basic_type{class = struct} = S, {StructMap, _} = Ctx) ->
	align_of_struct(e_util:get_struct_from_type(S, StructMap), Ctx);
align_of(#e_basic_type{class = C, tag = Tag}, {_, PointerWidth}) when C =:= integer; C =:= float ->
	e_util:primitive_size_of(Tag, PointerWidth);
align_of(Any, _) ->
	e_util:ethrow(element(2, Any), "invalid type ~p on alignof", [Any]).

