-module(e_dumper_ir1).
-export([generate_code/4]).
-include("e_record_definition.hrl").

%% According the calling convention of RISC-V: RA is X1, SP is X2, GP is X3, FP is X8. X5-X7 is T0-T2.
%% We use A0-A4 as T3-T7 since we pass arguments and result through stack and `Ax` are caller saved just like `Tx`.

-type machine_reg() :: {x, non_neg_integer()}.

-type context() ::
	#{
	wordsize => pos_integer(),
	scope_tag => atom(),
	tmp_regs => [machine_reg()],
	free_regs => [machine_reg()],
	%% `condi_label` is for generating logic operator (and, or, not) related code.
	condi_label => {atom(), atom()}
	}.

-spec generate_code(e_ast(), e_ast(), string(), non_neg_integer()) -> ok.
generate_code(AST, InitCode, OutputFile, WordSize) ->
	Regs = tmp_regs(),
	Ctx = #{wordsize => WordSize, scope_tag => '__init', tmp_regs => Regs, free_regs => Regs},
	IRs = [{fn, '__init'}, lists:map(fun(S) -> stmt_to_ir(S, Ctx) end, InitCode) | ast_to_ir(AST, WordSize)],
	Fn = fun(IO_Dev) -> write_irs([{comment, "vim:ft=erlang"} | IRs], IO_Dev) end,
	e_util:file_write(OutputFile, Fn).

-type irs() :: [tuple() | irs()].

-spec ast_to_ir(e_ast(), non_neg_integer()) -> irs().
ast_to_ir([#e_function{name = Name, stmts = Stmts, vars = #e_vars{shifted_size = Size0}} = Fn | Rest], WordSize) ->
	%% When there are no local variables, there should still be one word for returning value.
	Size1 = erlang:max(e_util:fill_unit_pessi(Size0, WordSize), WordSize),
	%% The extra `2` words are for `frame pointer`({x, 8}) and `returning address`({x, 1}).
	FrameSize = Size1 + WordSize * 2,
	RegSave = [{sw, {x, 8}, {{x, 2}, Size1}}, {sw, {x, 1}, {{x, 2}, Size1 + WordSize}}, {mv, {x, 8}, {x, 2}}],
	Regs = tmp_regs(),
	Ctx = #{wordsize => WordSize, scope_tag => Name, tmp_regs => Regs, free_regs => Regs},
	{Before, After} = interrupt_related_code(Fn, Regs, Ctx),
	Prologue = [RegSave, smart_addi({x, 2}, FrameSize, Ctx), Before, {comment, "prologue end"}],
	RegRestore = [{mv, {x, 2}, {x, 8}}, {lw, {x, 8}, {{x, 2}, Size1}}, {lw, {x, 1}, {{x, 2}, Size1 + WordSize}}],
	EndLabel = {label, generate_tag(Name, epilogue)},
	Epilogue = [EndLabel, After, RegRestore, {jalr, {x, 0}, {x, 1}}],
	Body = lists:map(fun(S) -> stmt_to_ir(S, Ctx) end, Stmts),
	%% The result should be flattened before calling `fix_irs/1`.
	FinalIRs = lists:flatten([{fn, Name}, Prologue, Body, Epilogue | ast_to_ir(Rest, WordSize)]),
	fix_irs(FinalIRs);
ast_to_ir([_ | Rest], Ctx) ->
	ast_to_ir(Rest, Ctx);
ast_to_ir([], _) ->
	[].

interrupt_related_code(#e_function{interrupt = true}, Regs, Ctx) ->
	reg_save_restore(Regs, Ctx);
interrupt_related_code(_, _, _) ->
	{[], []}.

-spec stmt_to_ir(e_stmt(), context()) -> irs().
stmt_to_ir(#e_if_stmt{condi = Condi, then = Then0, 'else' = Else0, loc = Loc}, #{scope_tag := ScopeTag} = Ctx) ->
	ThenLabel = generate_tag(ScopeTag, 'then', Loc),
	ElseLabel = generate_tag(ScopeTag, 'else', Loc),
	EndLabel = generate_tag(ScopeTag, 'end', Loc),
	{CondiIRs, R_Cond, _} = expr_to_ir(Condi, Ctx#{condi_label => {ThenLabel, ElseLabel}}),
	StartComment = comment('if', e_util:stmt_to_str(Condi), Loc),
	EndComment = comment('if', "end", Loc),
	Then1 = lists:map(fun(S) -> stmt_to_ir(S, Ctx) end, Then0),
	Else1 = lists:map(fun(S) -> stmt_to_ir(S, Ctx) end, Else0),
	Then2 = [{label, ThenLabel}, Then1, {j, EndLabel}],
	Else2 = [{label, ElseLabel}, Else1, {label, EndLabel}],
	[StartComment, CondiIRs, 'br!_reg'(R_Cond, ElseLabel), Then2, Else2, EndComment];
stmt_to_ir(#e_while_stmt{condi = Condi, stmts = Stmts0, loc = Loc}, #{scope_tag := ScopeTag} = Ctx) ->
	StartLabel = generate_tag(ScopeTag, start, Loc),
	BodyLabel = generate_tag(ScopeTag, body, Loc),
	EndLabel = generate_tag(ScopeTag, 'end', Loc),
	{CondiIRs, R_Cond, _} = expr_to_ir(Condi, Ctx#{condi_label => {BodyLabel, EndLabel}}),
	StartComment = comment(while, e_util:stmt_to_str(Condi), Loc),
	EndComment = comment(while, "end", Loc),
	RawBody = lists:map(fun(S) -> stmt_to_ir(S, Ctx) end, Stmts0),
	Body = [{label, BodyLabel}, RawBody, {j, StartLabel}, {label, EndLabel}],
	[StartComment, {label, StartLabel}, CondiIRs, 'br!_reg'(R_Cond, EndLabel), Body, EndComment];
stmt_to_ir(#e_return_stmt{expr = Expr}, #{scope_tag := ScopeTag} = Ctx) ->
	{ExprIRs, R, _} = expr_to_ir(Expr, Ctx),
	%% We use stack to pass result
	[ExprIRs, {comment, "prepare return value"}, {sw, R, {{x, 8}, 0}}, {j, generate_tag(ScopeTag, epilogue)}];
stmt_to_ir(#e_goto_stmt{label = Label}, #{scope_tag := ScopeTag}) ->
	[{j, generate_tag(ScopeTag, Label)}];
stmt_to_ir(#e_label{name = Label}, #{scope_tag := ScopeTag}) ->
	[{label, generate_tag(ScopeTag, Label)}];
stmt_to_ir(Stmt, Ctx) ->
	{Exprs, _, _} = expr_to_ir(Stmt, Ctx),
	Exprs.

generate_tag(ScopeTag, Tag, {Line, Column}) ->
	list_to_atom(e_util:fmt("~s_~s_~w_~w", [ScopeTag, Tag, Line, Column])).

generate_tag(ScopeTag, Tag) ->
	list_to_atom(e_util:fmt("~s_~s", [ScopeTag, Tag])).

comment(Tag, Info, {Line, Col}) ->
	{comment, io_lib:format("[~s@~w:~w] ~s", [Tag, Line, Col, Info])}.

-define(IS_SPECIAL_REG(Tag),
	(
	Tag =:= {x, 8} orelse Tag =:= {x, 3} orelse Tag =:= {x, 2} orelse Tag =:= {x, 1} orelse Tag =:= {x, 0}
	)).

-define(IS_SMALL_IMMEDI(N),
	(
	N >= -2048 andalso N < 2048
	)).

-spec expr_to_ir(e_expr(), context()) -> {irs(), machine_reg(), context()}.
expr_to_ir(?OP2('=', ?OP2('^', ?OP2('+', #e_varref{} = Var, ?I(N)), ?I(V)), Right), Ctx) when ?IS_SMALL_IMMEDI(N) ->
	{RightIRs, R1, Ctx1} = expr_to_ir(Right, Ctx),
	{VarrefIRs, R2, Ctx2} = expr_to_ir(Var, Ctx1),
	{[RightIRs, VarrefIRs, {st_instr_from_v(V), R1, {R2, N}}], R1, Ctx2};
expr_to_ir(?OP2('=', ?OP2('^', Expr, ?I(V)), Right), Ctx) ->
	{RightIRs, R1, Ctx1} = expr_to_ir(Right, Ctx),
	{LeftIRs, R2, Ctx2} = expr_to_ir(Expr, Ctx1),
	{[RightIRs, LeftIRs, {st_instr_from_v(V), R1, {R2, 0}}], R1, Ctx2};
expr_to_ir(?OP2('^', ?OP2('+', #e_varref{} = Var, ?I(N)), ?I(V)), Ctx) when ?IS_SMALL_IMMEDI(N) ->
	{IRs, R, #{free_regs := RestRegs}} = expr_to_ir(Var, Ctx),
	[T1 | RestRegs2] = RestRegs,
	{[IRs, {ld_instr_from_v(V), T1, {R, N}}], T1, Ctx#{free_regs := recycle_tmpreg([R], RestRegs2)}};
expr_to_ir(?OP2('^', Expr, ?I(V)), Ctx) ->
	{IRs, R, #{free_regs := RestRegs}} = expr_to_ir(Expr, Ctx),
	[T1 | RestRegs2] = RestRegs,
	{[IRs, {ld_instr_from_v(V), T1, {R, 0}}], T1, Ctx#{free_regs := recycle_tmpreg([R], RestRegs2)}};
expr_to_ir(?CALL(Fn, Args), Ctx) ->
	%% register preparing and restoring steps
	#{free_regs := FreeRegs, tmp_regs := TmpRegs} = Ctx,
	{BeforeCall, AfterCall} = reg_save_restore(TmpRegs -- FreeRegs, Ctx),
	%% The calling related steps
	{FnLoad, T1, Ctx1} = expr_to_ir(Fn, Ctx),
	{ArgPrepare, N} = args_to_stack(Args, 0, [], Ctx1),
	RetLoad = [{comment, "load ret"}, {lw, T1, {{x, 2}, 0}}],
	StackRestore = [{comment, "drop args"}, smart_addi({x, 2}, -N, Ctx1)],
	Call = [FnLoad, {comment, "args"}, ArgPrepare, {comment, "call"}, {jalr, {x, 1}, T1}, RetLoad, StackRestore],
	{[{comment, "call start"}, BeforeCall, Call, AfterCall, {comment, "call end"}], T1, Ctx1};
%% RISC-V do not have immediate version `sub` instruction, convert `-` to `+` to make use of `addi` later.
expr_to_ir(?OP2('-', Expr, ?I(N)) = OP, Ctx) ->
	expr_to_ir(OP?OP2('+', Expr, ?I(-N)), Ctx);
expr_to_ir(?OP2(Tag, Expr, ?I(0)), Ctx) when Tag =:= '+'; Tag =:= 'bor'; Tag =:= 'bxor'; Tag =:= 'bsl'; Tag =:= 'bsr' ->
	expr_to_ir(Expr, Ctx);
expr_to_ir(?OP2('band', Expr, ?I(-1)), Ctx) ->
	expr_to_ir(Expr, Ctx);
%% The immediate ranges for shifting instructions are different from other immediate ranges.
expr_to_ir(?OP2(Tag, Expr, ?I(N)), Ctx) when (Tag =:= 'bsl' orelse Tag =:= 'bsr'), N > 0, N =< 32 ->
	{IRs, R, Ctx1} = expr_to_ir(Expr, Ctx),
	{[IRs, {to_op_immedi(Tag), R, R, N}], R, Ctx1};
expr_to_ir(?OP2(Tag, Expr, ?I(N)), Ctx) when ?IS_IMMID_ARITH(Tag), ?IS_SMALL_IMMEDI(N) ->
	{IRs1, R, Ctx1} = expr_to_ir(Expr, Ctx),
	{[IRs1, {to_op_immedi(Tag), R, R, N}], R, Ctx1};
expr_to_ir(?OP2(Tag, Left, Right), Ctx) when ?IS_ARITH(Tag) ->
	{IRs1, R1, Ctx1} = expr_to_ir(Left, Ctx),
	{IRs2, R2, _} = expr_to_ir(Right, Ctx1),
	{[IRs1, IRs2, {to_op_normal(Tag), R1, R1, R2}], R1, Ctx1};
%% The tags for comparing operations are not translated here, it will be merged with the pseudo `br` or `br!`.
expr_to_ir(?OP2(Tag, Left, Right), Ctx) when ?IS_COMPARE(Tag) ->
	{IRs1, R1, Ctx1} = expr_to_ir(Left, Ctx),
	{IRs2, R2, _} = expr_to_ir(Right, Ctx1),
	{[IRs1, IRs2, {Tag, R1, R1, R2}], R1, Ctx1};
%% `and` and `or` do not consume tmp registers, it returns the same context and {x, 0} as a sign.
expr_to_ir(?OP2('and', Left, Right, Loc), #{scope_tag := ScopeTag, condi_label := {True, False}} = Ctx) ->
	Next = generate_tag(ScopeTag, 'and_next', Loc),
	{IRs1, R1, _} = expr_to_ir(Left, Ctx#{condi_label := {Next, False}}),
	{IRs2, R2, _} = expr_to_ir(Right, Ctx#{condi_label := {True, False}}),
	{[IRs1, 'br!_reg'(R1, False), {label, Next}, IRs2, 'br!_reg'(R2, False), {j, True}], {x, 0}, Ctx};
expr_to_ir(?OP2('or', Left, Right, Loc), #{scope_tag := ScopeTag, condi_label := {True, False}} = Ctx) ->
	Next = generate_tag(ScopeTag, 'or_next', Loc),
	{IRs1, R1, _} = expr_to_ir(Left, Ctx#{condi_label := {True, Next}}),
	{IRs2, R2, _} = expr_to_ir(Right, Ctx#{condi_label := {True, False}}),
	{[IRs1, br_reg(R1, True), {label, Next}, IRs2, br_reg(R2, True), {j, False}], {x, 0}, Ctx};
expr_to_ir(?OP1('not', Expr), #{condi_label := {True, False}} = Ctx) ->
	{IRs, R, Ctx1} = expr_to_ir(Expr, Ctx#{condi_label := {False, True}}),
	{[IRs, 'br!_reg'(R, True), {j, False}], {x, 0}, Ctx1};
%% RISC-V do not have instruction for `bnot`, use `xor` to do that.
expr_to_ir(?OP1('bnot', Expr), Ctx) ->
	{IRs, R, Ctx1} = expr_to_ir(Expr, Ctx),
	{[IRs, {xori, R, R, -1}], R, Ctx1};
expr_to_ir(?OP1('-', Expr), Ctx) ->
	{IRs, R, Ctx1} = expr_to_ir(Expr, Ctx),
	{[IRs, {sub, R, {x, 0}, R}], R, Ctx1};
expr_to_ir(#e_varref{name = fp}, Ctx) ->
	{[], {x, 8}, Ctx};
expr_to_ir(#e_varref{name = gp}, Ctx) ->
	{[], {x, 3}, Ctx};
expr_to_ir(#e_varref{name = Name}, #{free_regs := [R | RestRegs]} = Ctx) ->
	{[{la, R, Name}], R, Ctx#{free_regs := RestRegs}};
expr_to_ir(#e_string{value = Value}, #{free_regs := [R | RestRegs]} = Ctx) ->
	%% TODO: string literals should be placed in certain place.
	{[{la, R, Value}], R, Ctx#{free_regs := RestRegs}};
expr_to_ir(?I(0), Ctx) ->
	{[], {x, 0}, Ctx};
expr_to_ir(?I(N), #{free_regs := Regs} = Ctx) ->
	[R | RestRegs] = Regs,
	{smart_li(R, N), R, Ctx#{free_regs := RestRegs}};
expr_to_ir(Any, _) ->
	e_util:ethrow(element(2, Any), "IR1: unsupported expr \"~w\"", [Any]).

fix_irs([{Tag, Rd, R1, R2}, {'br!', Rd, DestTag} | Rest]) ->
	fix_irs([{e_util:reverse_cmp_tag(Tag), Rd, R1, R2}, {br, Rd, DestTag} | Rest]);
fix_irs([{Tag, Rd, R1, R2}, {br, Rd, DestTag} | Rest]) ->
	[{to_cmp_op(Tag), R1, R2, DestTag} | fix_irs(Rest)];
fix_irs([{j, Label} = I, {j, Label} | Rest]) ->
	fix_irs([I | Rest]);
fix_irs([{j, Label}, {label, Label} = L | Rest]) ->
	fix_irs([L | Rest]);
fix_irs([Any | Rest]) ->
	[Any | fix_irs(Rest)];
fix_irs([]) ->
	[].

recycle_tmpreg([R | Regs], RegBank) when ?IS_SPECIAL_REG(R) ->
	recycle_tmpreg(Regs, RegBank);
recycle_tmpreg([R | Regs], RegBank) ->
	recycle_tmpreg(Regs, [R | RegBank]);
recycle_tmpreg([], RegBank) ->
	RegBank.

reg_save_restore(Regs, #{wordsize := WordSize} = Ctx) ->
	TotalSize = length(Regs) * WordSize,
	StackGrow = [{comment, "grow stack"}, smart_addi({x, 2}, TotalSize, Ctx)],
	StackShrink = [{comment, "shrink stack"}, smart_addi({x, 2}, -TotalSize, Ctx)],
	Save = e_util:list_map(fun(R, I) -> {sw, R, {{x, 2}, I * WordSize}} end, Regs),
	Restore = e_util:list_map(fun(R, I) -> {lw, R, {{x, 2}, I * WordSize}} end, Regs),
	Before = [{comment, io_lib:format("regs to save: ~w", [Regs])}, Save, StackGrow],
	After = [{comment, io_lib:format("regs to restore: ~w", [Regs])}, StackShrink, Restore],
	{Before, After}.

smart_addi(_, 0, _) ->
	[];
smart_addi(Reg, N, _) when ?IS_SMALL_IMMEDI(N) ->
	[{addi, Reg, Reg, N}];
smart_addi(Reg, N, #{free_regs := [T | _]}) ->
	[smart_li(T, N), {add, Reg, Reg, T}].

smart_li(Reg, N) when ?IS_SMALL_IMMEDI(N) ->
	[{addi, Reg, {x, 0}, N}];
smart_li(Reg, N) ->
	{High, Low} = separate_immedi_for_lui(N),
	[{lui, Reg, High}, {addi, Reg, Reg, Low}].

%% The immediate value of `LUI` instruction is a signed value.
%% When N is negative, the high part should be increased by 1 to balance it.
%% The mechanism is simple:
%% `+1` then `+(-1)` keeps the number unchanged. Negative signed extending can be treated as `-1`.
separate_immedi_for_lui(N) ->
	High = N bsr 12,
	Low = N band 16#FFF,
	case Low > 2047 of
		true ->
			{High + 1, Low};
		false ->
			{High, Low}
	end.

args_to_stack([Arg | Rest], N, Result, #{wordsize := WordSize} = Ctx) ->
	{IRs, R, _} = expr_to_ir(Arg, Ctx),
	args_to_stack(Rest, N + WordSize, [[IRs, {sw, R, {{x, 2}, 0}}, {addi, {x, 2}, {x, 2}, WordSize}] | Result], Ctx);
args_to_stack([], N, Result, _) ->
	{lists:reverse(Result), N}.

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
write_irs([{label, _} = IR | Rest], IO_Dev) ->
	io:format(IO_Dev, "~w.~n", [IR]),
	write_irs(Rest, IO_Dev);
write_irs([IR | Rest], IO_Dev) ->
	io:format(IO_Dev, "\t~w.~n", [IR]),
	write_irs(Rest, IO_Dev);
write_irs([], _) ->
	ok.

%% {x, 0} means there are not branching to generate. (already generated in previous IRs)
'br!_reg'({x, 0}, _)	-> [];
'br!_reg'(Reg, Label)	-> [{'br!', Reg, Label}].

br_reg({x, 0}, _)	-> [];
br_reg(Reg, Label)	-> [{'br', Reg, Label}].

st_instr_from_v(1) -> sb;
st_instr_from_v(_) -> sw.
ld_instr_from_v(1) -> lb;
ld_instr_from_v(_) -> lw.

%% We don't need many registers with current allocation algorithm.
%% Most RISC machine can provide 8 free registers.
-spec tmp_regs() -> [machine_reg()].
tmp_regs() ->
	[{x, 5}, {x, 6}, {x, 7}, {x, 10}, {x, 11}, {x, 12}, {x, 13}, {x, 14}].

to_op_normal('+')	->  add;
to_op_normal('-')	->  sub;
to_op_normal('*')	->  mul;
to_op_normal('/')	-> 'div';
to_op_normal('rem')	-> 'rem';
to_op_normal('band')	-> 'and';
to_op_normal('bor')	-> 'or';
to_op_normal('bxor')	-> 'xor';
to_op_normal('bsl')	->  sll;
to_op_normal('bsr')	->  sra.

to_op_immedi('+')	-> addi;
to_op_immedi('band')	-> andi;
to_op_immedi('bor')	-> ori;
to_op_immedi('bxor')	-> xori;
to_op_immedi('bsl')	-> slli;
to_op_immedi('bsr')	-> srai.

to_cmp_op('==')		-> beq;
to_cmp_op('!=')		-> bne;
to_cmp_op('>=')		-> bge;
to_cmp_op('<=')		-> ble;
to_cmp_op('>')		-> bgt;
to_cmp_op('<')		-> blt.

