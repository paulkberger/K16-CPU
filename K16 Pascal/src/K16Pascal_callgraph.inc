(* ============================================================ *)
(* K16 Pascal - Call Graph            (Part 18, Phase 0)        *)
(*                                                              *)
(* A persistent side table of Pascal routines and the static     *)
(* calls between them. Deliberately SEPARATE from TSymbol.Deps:  *)
(*                                                              *)
(*   - CloseScope Dispose()s symbols, and BOTH of ParseProgram's *)
(*     CloseScope calls run before EmitFooter. Anything that     *)
(*     wants the graph at footer time (Phase 2 slot recycling)   *)
(*     cannot hold PSymbols.                                    *)
(*   - Nested routines are disposed when the parent scope closes,*)
(*     so recording them in a parent's Deps[] would leave        *)
(*     dangling pointers.                                       *)
(*   - Deps[] is consumed eagerly for SmartLink liveness and is  *)
(*     gated to Level = 0. Widening it changes .IF __USE output. *)
(*     This table changes no emitted byte.                      *)
(*                                                              *)
(* Nodes are keyed by assembler tag. Tags are unique (GetLabel)  *)
(* and a forward declaration shares its tag with the body        *)
(* (ParseProcFunc: NewSym^.Tag := FwdSym^.Tag), so a call seen   *)
(* before the body still lands on the right node.               *)
(*                                                              *)
(* Self-edges ARE recorded, unlike AddDependency, which skips    *)
(* them: direct recursion is the signal Phase 1a looks for.      *)
(*                                                              *)
(* Only Pascal-bodied routines are nodes. Externals are RTL asm  *)
(* with no Pascal string slots and cannot call back into user    *)
(* code; magics are expanded by the compiler.                   *)
(* ============================================================ *)

const
  CG_MAIN_TAG = '@main';   { the main program body has no symbol }

type
  TCallNode = record
    Tag: String;              { assembler tag - the key }
    Name: String;             { Pascal name, for diagnostics }
    Level: Integer;           { nesting level, 0 = global }
    SlotPrefix: String;       { symbol stem for this routine's frame symbols }
    ArgCount: Integer;
    HasStrValParam: Boolean;  { has a by-value String parameter }
    HasStaticLocal: Boolean;  { has a local promoted to static storage }
    Defined: Boolean;         { body was parsed }
    Edges: array of Integer;  { callee node indices }
    EdgeRisky: array of Boolean;  { call made with a static concat dest open }
    EdgeCount: Integer;
    Mark: Integer;            { traversal scratch (generation stamp) }
  end;

var
  CGNodes: array of TCallNode;
  CGCount: Integer = 0;

  (**
   * Node whose body is currently being emitted, or -1 outside any block.
   * Saved/restored by ParseBlock, so nested routines nest correctly.
   *)
  CGCurrent: Integer = -1;

  (**
   * Generation stamp for reachability walks; avoids clearing Mark each time.
   *)
  CGVisitGen: Integer = 0;

  (**
   * --calls: dump the graph to stdout after parsing.
   *)
  DumpCalls: Boolean = False;

(**
 * Discards the whole graph. Called from Build, which resets all global
 * compiler state so a second compilation in one process starts clean.
 *)
procedure CGReset;
begin
  SetLength(CGNodes, 0);
  CGCount    := 0;
  CGCurrent  := -1;
  CGVisitGen := 0;
end;

(**
 * Returns the index of the node with the given tag, or -1.
 *)
function CGLookup(const Tag: String): Integer;
var
  I: Integer;
begin
  CGLookup := -1;
  for I := 0 to CGCount - 1 do
    if CGNodes[I].Tag = Tag then
    begin
      CGLookup := I;
      Exit;
    end;
end;

(**
 * Returns the node with the given tag, creating it if needed. A node may be
 * created by a call site long before its body is parsed (forward declaration,
 * mutual recursion), in which case Defined stays False until CGRegisterBlock
 * sees the body.
 *)
function CGIntern(const Tag, Name: String; Lvl: Integer): Integer;
var
  N: Integer;
begin
  N := CGLookup(Tag);
  if N < 0 then
  begin
    if CGCount >= Length(CGNodes) then SetLength(CGNodes, CGCount + 32);
    N := CGCount;
    CGNodes[N].Tag            := Tag;
    CGNodes[N].Name           := Name;
    CGNodes[N].Level          := Lvl;
    CGNodes[N].SlotPrefix     := '';
    CGNodes[N].ArgCount       := 0;
    CGNodes[N].HasStrValParam := False;
    CGNodes[N].HasStaticLocal := False;
    CGNodes[N].Defined        := False;
    CGNodes[N].EdgeCount      := 0;
    CGNodes[N].Mark           := 0;
    SetLength(CGNodes[N].Edges, 0);
    SetLength(CGNodes[N].EdgeRisky, 0);
    Inc(CGCount);
  end;
  CGIntern := N;
end;

(**
 * Records a Src -> Dst call edge, deduplicated. Self-edges are kept.
 *
 * Risky means this call was emitted while Src had a static concat destination
 * open -- a buffer it will read again after the call returns. One risky call
 * site is enough to taint the edge, so the flag is OR-ed into an existing one.
 *)
procedure CGAddEdge(Src, Dst: Integer; Risky: Boolean);
var
  I: Integer;
begin
  if (Src < 0) or (Dst < 0) then Exit;

  for I := 0 to CGNodes[Src].EdgeCount - 1 do
    if CGNodes[Src].Edges[I] = Dst then
    begin
      if Risky then CGNodes[Src].EdgeRisky[I] := True;
      Exit;
    end;

  if CGNodes[Src].EdgeCount >= Length(CGNodes[Src].Edges) then
  begin
    SetLength(CGNodes[Src].Edges,     CGNodes[Src].EdgeCount + 8);
    SetLength(CGNodes[Src].EdgeRisky, CGNodes[Src].EdgeCount + 8);
  end;

  CGNodes[Src].Edges[CGNodes[Src].EdgeCount]     := Dst;
  CGNodes[Src].EdgeRisky[CGNodes[Src].EdgeCount] := Risky;
  Inc(CGNodes[Src].EdgeCount);
end;

(**
 * Registers the block about to be emitted and returns its node. Sym = nil is
 * the main program body. Called from the top of ParseBlock, so the node exists
 * before any of the block's own declarations are parsed.
 *)
function CGRegisterBlock(Sym: PSymbol): Integer;
var
  N, I: Integer;
  T: PSymbol;
begin
  if Sym = nil then
    N := CGIntern(CG_MAIN_TAG, 'main', 0)
  else
    N := CGIntern(Sym^.Tag, Sym^.Name, Sym^.Level);

  CGNodes[N].Defined := True;

  { Phase 2: stem for this routine's slot symbols. Tags are unique (GetLabel),
    so stripping the leading underscores keeps them unique AND readable in the
    listing: __RevA99 -> SS_RevA99_0. }
  if CGNodes[N].SlotPrefix = '' then
  begin
    if Sym = nil then
      CGNodes[N].SlotPrefix := 'main'
    else
    begin
      I := 1;
      while (I <= Length(Sym^.Tag)) and (Sym^.Tag[I] = '_') do Inc(I);
      CGNodes[N].SlotPrefix := Copy(Sym^.Tag, I, Length(Sym^.Tag));
    end;
  end;

  if Sym <> nil then
  begin
    CGNodes[N].Level    := Sym^.Level;
    CGNodes[N].ArgCount := Sym^.Value;

    { A by-value String parameter is passed as a bare pointer today, so the
      callee aliases the caller's buffer. Phase 1a rejects this under
      recursion; Phase 1b(A) copies it into the frame. }
    for I := 0 to Sym^.Value - 1 do
    begin
      if I > 15 then Break;             { ArgTypes is 0..15 }
      T := Sym^.ArgTypes[I];
      if (T <> nil) and (not Sym^.ArgIsRef[I]) and (T^.Kind = scStringType) then
        CGNodes[N].HasStrValParam := True;
    end;
  end;

  CGRegisterBlock := N;
end;

(**
 * Records a call from the block being emitted to Sym, if Sym is a Pascal-bodied
 * routine. Called from EmitCall. Interns the callee even when there is no
 * current block, so the node still shows up in the dump.
 *)
procedure CGRecordCall(Sym: PSymbol; StaticDestOpen: Boolean);
var
  N: Integer;
begin
  if Sym = nil then Exit;
  if (Sym^.Kind <> scProc) and (Sym^.Kind <> scFunc) then Exit;
  if Sym^.IsExternal or Sym^.IsMagic then Exit;
  if Sym^.Tag = '' then Exit;

  { Part 19 item 7.6: CGIntern's CGLookup is a linear scan over every node, and
    this runs once per call site, so the cost was O(call sites x routines). The
    tag -> node mapping never changes once made, so cache it on the symbol. }
  if Sym^.CGNodeCache > 0 then
    N := Sym^.CGNodeCache - 1
  else
  begin
    N := CGIntern(Sym^.Tag, Sym^.Name, Sym^.Level);
    Sym^.CGNodeCache := N + 1;
  end;
  if CGCurrent >= 0 then CGAddEdge(CGCurrent, N, StaticDestOpen);
end;

(**
 * Flags the block being parsed as owning a local in static storage. Called from
 * the {$A+} promotion in ParseVarList, which is reached from ParseDeclarations
 * while CGCurrent still names the enclosing routine.
 *)
procedure CGNoteStaticLocal;
begin
  if CGCurrent >= 0 then CGNodes[CGCurrent].HasStaticLocal := True;
end;

(**
 * Depth-first reachability, stamped with CGVisitGen so no clearing pass is
 * needed. Kept separate from CGReaches so the stamp is bumped exactly once
 * per query.
 *)
function CGReachFrom(N, Target: Integer): Boolean;
var
  I, D: Integer;
begin
  CGReachFrom := False;
  if CGNodes[N].Mark = CGVisitGen then Exit;
  CGNodes[N].Mark := CGVisitGen;

  for I := 0 to CGNodes[N].EdgeCount - 1 do
  begin
    D := CGNodes[N].Edges[I];
    if D = Target then
    begin
      CGReachFrom := True;
      Exit;
    end;
    if CGReachFrom(D, Target) then
    begin
      CGReachFrom := True;
      Exit;
    end;
  end;
end;

(**
 * True if Dst is reachable from Src by one or more calls.
 *)
function CGReaches(Src, Dst: Integer): Boolean;
begin
  Inc(CGVisitGen);
  CGReaches := CGReachFrom(Src, Dst);
end;

(**
 * True if the routine can re-enter itself: direct recursion, mutual recursion,
 * or any longer cycle. This is the predicate Phase 1a and Phase 2 need.
 *)
function CGIsCyclic(N: Integer): Boolean;
begin
  CGIsCyclic := CGReaches(N, N);
end;

(**
 * Part 18 Phase 1a: reject recursion through a static string buffer.
 *
 * A concat destination is ONE static buffer per routine, so if a routine holds
 * one open across a call that can re-enter it, the callee overwrites the
 * caller's half-built result. That is silent wrong output today (RecStr's
 * RevB / Wrap / OddStr / EvenStr); this turns it into a build error until
 * Phase 1b(B) moves those temps onto the stack.
 *
 * The predicate is deliberately narrower than "cyclic and uses string temps":
 * that coarser test also rejects routines where the recursive call COMPLETES
 * before the concatenation starts (RecStr's Depth, which is the control proving
 * String locals survive recursion) or which never re-read anything afterwards
 * (LastChar). Both are correct today and must keep compiling.
 *
 * Scope, stated plainly: this catches the mechanism observed in RecStr. It is a
 * tripwire for that failure mode, not a proof that a cyclic routine is safe.
 *)
procedure CGCheckRecursion;
var
  I, J, D, Count: Integer;
begin
  (* --- Warning: static locals in a routine that can re-enter itself ---
   * {$A+} is on by default (Build forces AbsCode := True), and ParseVarList
   * promotes every local of a type <= 32 bytes to static storage. Static means
   * ONE copy shared by all invocations, so a value written before a recursive
   * call is gone after it returns. String locals escape (256 > 32), which is
   * why RecStr's Depth survives.
   *
   * A warning and not an error: whether this bites depends on whether a local
   * is actually read after the recursive call, and the common accumulator shape
   *     if n <= 1 then r := 1 else r := n * Fact(n - 1);  Fact := r;
   * is correct -- r is written after the call and read with no call in between.
   * Rejecting that would be worse than the bug. Deciding it properly needs
   * liveness on statics across calls; the real fix is per-routine {$A-} chosen
   * from this graph, which needs the same pre-pass as Phase 1b(B).
   *)
  Count := 0;
  for I := 0 to CGCount - 1 do
    if CGNodes[I].HasStaticLocal and CGIsCyclic(I) then
    begin
      if Count = 0 then
      begin
        WriteLn;
        WriteLn('*** Warning: static locals in recursive routines');
        WriteLn;
      end;
      WriteLn('  ', CGNodes[I].Name, ' can re-enter itself and has locals in ' +
              'static storage.');
      Inc(Count);
    end;

  if Count > 0 then
  begin
    WriteLn;
    WriteLn('  {$A+} (the default) gives locals ONE shared copy, so a value');
    WriteLn('  written before the recursive call is gone after it returns.');
    WriteLn('  This is only wrong if a local is READ after that call -- the');
    WriteLn('  usual accumulator shape is fine. If it is, add {$A-} to put');
    WriteLn('  locals in the frame instead (String locals already are).');
    WriteLn;
  end;

  { Part 19 item 5 (1b(B)): this check is RETIRED, not merely disabled.
    It rejected a routine that held a concat destination across a call that
    could re-enter it -- correct while the destination was one static buffer
    per routine, because the callee overwrote the caller's partial result.
    The destination is now a per-invocation block reserved in the frame
    (see EmitConcatDestAddr in K16Pascal_codegen.inc), so each activation
    accumulates into its own buffer and the pattern is simply legal. The four
    RecStr routines it used to reject -- RevB, Wrap, OddStr, EvenStr -- build.

    What is KEPT: EdgeRisky tagging and its --calls annotation. That still
    records "a call made while a concat chain was accumulating", which is
    worth seeing, and it is the hook to reuse if this is ever narrowed to
    police the arg-context static buffers instead (those were never counted
    here, so this check never guarded them -- Part 18 s7's claim that 1a would
    remain a net for that residue does not hold). }
  Count := 0;
end;

(**
 * --calls: human-readable dump. Writes to stdout only; the emitted assembly is
 * unaffected.
 *)
procedure CGDump;
var
  I, J, Cyclic: Integer;
  S, F: String;
begin
  WriteLn;
  WriteLn('Call graph: ', IntToStr(CGCount), ' routine(s)');
  WriteLn;

  Cyclic := 0;
  for I := 0 to CGCount - 1 do
  begin
    F := '';
    if CGNodes[I].HasStrValParam then F := F + ' [str-val-param]';
    if CGNodes[I].HasStaticLocal then F := F + ' [static-local]';
    if not CGNodes[I].Defined     then F := F + ' [undefined]';
    if CGIsCyclic(I) then
    begin
      F := F + ' [cyclic]';
      Inc(Cyclic);
    end;

    S := '  ' + PadStr(CGNodes[I].Name, 24) +
         ' level ' + IntToStr(CGNodes[I].Level) +
         '  args ' + IntToStr(CGNodes[I].ArgCount);
    if F <> '' then S := PadStr(S, 60) + F;
    WriteLn(S);

    for J := 0 to CGNodes[I].EdgeCount - 1 do
      if CGNodes[I].EdgeRisky[J] then
        WriteLn('      -> ', CGNodes[CGNodes[I].Edges[J]].Name,
                '   [concat buffer open]')
      else
        WriteLn('      -> ', CGNodes[CGNodes[I].Edges[J]].Name);
  end;

  WriteLn;
  WriteLn('  ', IntToStr(Cyclic), ' routine(s) can re-enter themselves.');
  WriteLn;
end;
