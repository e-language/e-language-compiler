-module(e_dumper_ir1).
-export([generate_code/4]).
-include("e_record_definition.hrl").

-type context() :: #{wordsize => pos_integer(), scope_tag => atom(), tmp_regs => [atom()], free_regs => [atom()]}.
-type irs() :: [tuple() | irs()].

-spec generate_code(e_ast(), e_ast(), string(), non_neg_integer()) -> ok.
generate_code(AST, InitCode, OutputFile, WordSize) ->
	Regs = tmp_regs(),
	Ctx = #{wordsize => WordSize, scope_tag => top, tmp_regs => Regs, free_regs => Regs},
	IRs = [{fn, '<init1>'}, lists:map(fun(S) -> stmt_to_ir(S, Ctx) end, InitCode) | ast_to_ir(AST, WordSize)],
	Fn = fun(IO_Dev) -> write_irs([{comment, "vim:ft=erlang"} | IRs], IO_Dev) end,
	file_transaction(OutputFile, Fn).

-spec ast_to_ir(e_ast(), non_neg_integer()) -> irs().
ast_to_ir([#e_function{name = Name, stmts = Stmts} = Fn | Rest], WordSize) ->
	#e_function{vars = #e_vars{size = Size0}} = Fn,
	Size1 = e_util:fill_unit_pessi(Size0, WordSize),
	%% The extra `2` is for `fp` and `returning address`.
	FrameSize = Size1 + WordSize * 2,
	SaveRegs = [{sw, {sp, Size1}, fp}, {sw, {sp, Size1 + WordSize}, ra}, {mv, fp, sp}],
	Regs = tmp_regs(),
	[T1 | _] = Regs,
	PrepareFrame = [{li, T1, FrameSize}, {'+', sp, sp, T1}],
	Prologue = [{comment, prologue_start}, SaveRegs, PrepareFrame, {comment, prologue_end}],
	RestoreRegs = [{mv, sp, fp}, {lw, fp, {sp, Size1}}, {lw, ra, {sp, Size1 + WordSize}}],
	EndLabel = {label, concat_atoms([Name, epilogue])},
	Epilogue = [{comment, epilogue_start}, EndLabel, RestoreRegs, {ret, ra}, {comment, epilogue_end}],
	Ctx = #{wordsize => WordSize, scope_tag => Name, tmp_regs => Regs, free_regs => Regs},
	[{fn, Name}, Prologue, lists:map(fun(S) -> stmt_to_ir(S, Ctx) end, Stmts), Epilogue | ast_to_ir(Rest, WordSize)];
ast_to_ir([_ | Rest], Ctx) ->
	ast_to_ir(Rest, Ctx);
ast_to_ir([], _) ->
	[].

-spec stmt_to_ir(e_stmt(), context()) -> irs().
stmt_to_ir(#e_if_stmt{condi = Condi, then = Then0, 'else' = Else0, loc = Loc}, Ctx) ->
	{CondiIRs, R_Cond, _} = expr_to_ir(Condi, Ctx),
	StartComment = comment('if', e_util:stmt_to_str(Condi), Loc),
	EndComment = comment('if', "end", Loc),
	Then1 = lists:map(fun(S) -> stmt_to_ir(S, Ctx) end, Then0),
	Else1 = lists:map(fun(S) -> stmt_to_ir(S, Ctx) end, Else0),
	Then2 = [comment('if', "then part", Loc), Then1, {j, end_if}],
	Else2 = [comment('if', "else part", Loc), {label, else_label}, Else1, {j, end_if}, {label, end_if}],
	[StartComment, CondiIRs, {jcond, R_Cond, else_label}, Then2, Else2, EndComment];
stmt_to_ir(#e_while_stmt{condi = Condi, stmts = Stmts0, loc = Loc}, Ctx) ->
	{CondiIRs, R_Cond, _} = expr_to_ir(Condi, Ctx),
	StartComment = comment(while, e_util:stmt_to_str(Condi), Loc),
	EndComment = comment(while, "end", Loc),
	Stmts1 = lists:map(fun(S) -> stmt_to_ir(S, Ctx) end, Stmts0),
	Stmts2 = [comment(while, "body part", Loc), {label, body_start}, Stmts1, {j, body_start}, {label, end_while}],
	[StartComment, CondiIRs, {jcond, R_Cond, end_while}, Stmts2, EndComment];
stmt_to_ir(#e_return_stmt{expr = Expr}, #{scope_tag := ScopeTag} = Ctx) ->
	{ExprIRs, R, _} = expr_to_ir(Expr, Ctx),
	%% We use stack to pass result
	[ExprIRs, {comment, "prepare return value"}, {sw, {fp, 0}, R}, {j, concat_atoms([ScopeTag, epilogue])}];
stmt_to_ir(#e_goto_stmt{label = Label}, _) ->
	[{j, Label}];
stmt_to_ir(#e_label{name = Label}, _) ->
	[{label, Label}];
stmt_to_ir(Stmt, Ctx) ->
	{Exprs, _, _} = expr_to_ir(Stmt, Ctx),
	Exprs.

concat_atoms(AtomList) ->
	list_to_atom(string:join(lists:map(fun(A) -> atom_to_list(A) end, AtomList), "_")).

comment(Tag, Info, {Line, Col}) ->
	{comment, io_lib:format("[~s@~w:~w] ~s", [Tag, Line, Col, Info])}.

-define(IS_ARITH(Tag),
	(
	Tag =:= '+' orelse Tag =:= '-' orelse Tag =:= '*' orelse Tag =:= '/' orelse Tag =:= 'rem' orelse
	Tag =:= 'and' orelse Tag =:= 'or' orelse Tag =:= 'band' orelse Tag =:= 'bor' orelse Tag =:= 'bxor' orelse
	Tag =:= 'bsl' orelse Tag =:= 'bsr'
	)).

-define(IS_COMPARE(Tag),
	(
	Tag =:= '>' orelse Tag =:= '<' orelse Tag =:= '==' orelse Tag =:= '!=' orelse
	Tag =:= '>=' orelse Tag =:= '<='
	)).

-define(IS_SPECIAL_REG(Tag),
	(
	Tag =:= fp orelse Tag =:= gp orelse Tag =:= zero
	)).

-spec expr_to_ir(e_expr(), context()) -> {irs(), atom(), context()}.
expr_to_ir(?OP2('=', ?OP2('^', ?OP2('+', #e_varref{} = Varref, ?I(N)), ?I(V)), Right), Ctx) ->
	{RightIRs, R1, Ctx1} = expr_to_ir(Right, Ctx),
	{VarrefIRs, R2, Ctx2} = expr_to_ir(Varref, Ctx1),
	{[RightIRs, VarrefIRs, {st_instr_from_v(V), {R2, N}, R1}], R1, Ctx2};
expr_to_ir(?OP2('=', ?OP2('^', Expr, ?I(V)), Right), Ctx) ->
	{RightIRs, R1, Ctx1} = expr_to_ir(Right, Ctx),
	{LeftIRs, R2, Ctx2} = expr_to_ir(Expr, Ctx1),
	{[RightIRs, LeftIRs, {st_instr_from_v(V), {R2, 0}, R1}], R1, Ctx2};
expr_to_ir(?OP2('^', ?OP2('+', #e_varref{} = Varref, ?I(N)), ?I(V)), Ctx) ->
	{IRs, R, #{free_regs := RestRegs}} = expr_to_ir(Varref, Ctx),
	[T1 | RestRegs2] = RestRegs,
	{[IRs, {ld_instr_from_v(V), T1, {R, N}}], T1, Ctx#{free_regs := recycle_tmpreg([R], RestRegs2)}};
expr_to_ir(?OP2('^', Expr, ?I(V)), Ctx) ->
	{IRs, R, #{free_regs := RestRegs}} = expr_to_ir(Expr, Ctx),
	[T1 | RestRegs2] = RestRegs,
	{[IRs, {ld_instr_from_v(V), T1, {R, 0}}], T1, Ctx#{free_regs := recycle_tmpreg([R], RestRegs2)}};
expr_to_ir(#e_op{tag = {call, Fn}, data = Args}, Ctx) ->
	{FnLoadIRs, R, Ctx1} = expr_to_ir(Fn, Ctx),
	ArgPreparingIRs = args_to_stack(Args, 0, Ctx1),
	{[FnLoadIRs, ArgPreparingIRs, {call, R}, {comment, "load returned value"}, {lw, R, {sp, 0}}], R, Ctx1};
expr_to_ir(?OP2(Tag, Left, Right), Ctx) when ?IS_ARITH(Tag) ->
	{IRs1, R1, Ctx1} = expr_to_ir(Left, Ctx),
	{IRs2, R2, #{free_regs := RestRegs}} = expr_to_ir(Right, Ctx1),
	[T1 | RestRegs2] = RestRegs,
	{[IRs1, IRs2, {Tag, T1, R1, R2}], T1, Ctx#{free_regs := recycle_tmpreg([R2, R1], RestRegs2)}};
expr_to_ir(?OP2(Tag, Left, Right), Ctx) when ?IS_COMPARE(Tag) ->
	{IRs1, R1, Ctx1} = expr_to_ir(Left, Ctx),
	{IRs2, R2, #{free_regs := RestRegs}} = expr_to_ir(Right, Ctx1),
	[T1 | RestRegs2] = RestRegs,
	ReversedTag = e_util:reverse_compare_tag(Tag),
	{[IRs1, IRs2, {ReversedTag, T1, R1, R2}], T1, Ctx#{free_regs := recycle_tmpreg([R2, R1], RestRegs2)}};
expr_to_ir(?OP1(Tag, Expr), Ctx) ->
	{IRs, R, Ctx1} = expr_to_ir(Expr, Ctx),
	{[IRs, {Tag, R}], R, Ctx1};
expr_to_ir(#e_varref{name = Name}, Ctx) when ?IS_SPECIAL_REG(Name) ->
	{[], Name, Ctx};
expr_to_ir(#e_varref{name = Name}, #{free_regs := [R | RestRegs]} = Ctx) ->
	{[{la, R, Name}], R, Ctx#{free_regs := RestRegs}};
expr_to_ir(#e_string{value = Value}, #{free_regs := [R | RestRegs]} = Ctx) ->
	%% TODO: string literals should be placed in certain place.
	{[{la, R, Value}], R, Ctx#{free_regs := RestRegs}};
expr_to_ir(?I(N), #{free_regs := Regs} = Ctx) ->
	[R | RestRegs] = Regs,
	{[{li, R, N}], R, Ctx#{free_regs := RestRegs}};
expr_to_ir(?F(N), #{free_regs := Regs} = Ctx) ->
	%% TODO: float is special
	[R | RestRegs] = Regs,
	{[{li, R, N}], R, Ctx#{free_regs := RestRegs}};
expr_to_ir(Any, _) ->
	e_util:ethrow(element(2, Any), "IR1: unsupported expr \"~w\"", [Any]).

recycle_tmpreg([R | Regs], RegBank) when ?IS_SPECIAL_REG(R) ->
	recycle_tmpreg(Regs, RegBank);
recycle_tmpreg([R | Regs], RegBank) ->
	recycle_tmpreg(Regs, [R | RegBank]);
recycle_tmpreg([], RegBank) ->
	RegBank.

args_to_stack([Arg | Rest], N, #{wordsize := WordSize} = Ctx) ->
	{IRs, R, _} = expr_to_ir(Arg, Ctx),
	[IRs, {sw, {sp, N}, R} | args_to_stack(Rest, N + WordSize, Ctx)];
args_to_stack([], _, _) ->
	[].

-spec write_irs(irs(), file:io_device()) -> ok.
write_irs([IRs | Rest], IO_Dev) when is_list(IRs) ->
	write_irs(IRs, IO_Dev),
	write_irs(Rest, IO_Dev);
write_irs([{comment, Content} | Rest], IO_Dev) ->
	io:format(IO_Dev, "\t%% ~s~n", [Content]),
	write_irs(Rest, IO_Dev);
write_irs([{fn, _} = IR | Rest], IO_Dev) ->
	io:format(IO_Dev, "~w.~n", [IR]),
	write_irs(Rest, IO_Dev);
write_irs([IR | Rest], IO_Dev) ->
	io:format(IO_Dev, "\t~w.~n", [IR]),
	write_irs(Rest, IO_Dev);
write_irs([], _) ->
	ok.

-spec file_transaction(string(), fun((file:io_device()) -> R)) -> R when R :: ok.
file_transaction(Filename, Handle) ->
	{ok, IO_Dev} = file:open(Filename, [write]),
	try
		Handle(IO_Dev)
	after
		ok = file:close(IO_Dev)
	end.

st_instr_from_v(1) -> sb;
st_instr_from_v(_) -> sw.
ld_instr_from_v(1) -> lb;
ld_instr_from_v(_) -> lw.

%% We don't need many registers with current allocation algorithm.
%% Most RISC machine can provide 8 free registers.
tmp_regs() ->
	[t0, t1, t2, t3, t4, t5, t6, t7].

