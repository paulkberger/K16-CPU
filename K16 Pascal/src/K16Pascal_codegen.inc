(* ============================================================ *)
(* K16 Pascal — Code Generation Backend                        *)
(*                                                             *)
(* Register convention (V2 ABI):                               *)
(*   D0  primary accumulator / return value                    *)
(*   D1  second argument                                       *)
(*   D2  third argument / callee-saved                         *)
(*   D3  callee-saved                                          *)
(*   X3  stack pointer  (Y3 = $00 always)                      *)
(*   X2  frame pointer cache (Y2 = $00 always)                 *)
(*   X0, X1  scratch address registers                         *)
(*   Y0..Y2 = $00 always (bank 0)                              *)
(*                                                             *)
(* Stack: Full Descending                                       *)
(*   PUSH = decrement X3 then write                            *)
(*   POP  = read then increment X3                             *)
(*                                                             *)
(* All pointers are 16-bit within a 64KB task partition.       *)
(* display[] at $000180: frame pointer array (one per level).  *)
(*                                                             *)
(* String ABI: pass-by-destination, string temps on stack.     *)
(*   StringTempDepth tracks live 256-byte string temps.        *)
(* ============================================================ *)

const
  DisplaySlots         = 8;    { display[] entries -- max lexical nesting depth.
                                 Used BOTH to reserve the region and to seed it
                                 in main's prologue; keep them from drifting. }

var
  StringTempDepth : Integer = 0;
  CurrentSlotPrefix : String = 'main';   { Part 18: owner of the slots being emitted }
  ConcatDestAddr    : Integer = 0;   { Part 17: static dest buffer for a concat chain }
  ConcatDestOpen    : Integer = 0;   { Part 18: concat chains currently accumulating }
  GlobalFieldTags   : array of String;   { Part 17: k/OS globals -> GLOBALS .REGION fields }
  GlobalFieldBytes  : array of Integer;
  GlobalFieldCount  : Integer = 0;
  GlobalTagNames    : array of String;   { Part 17: issued global tags, for uniqueness }
  GlobalTagCount    : Integer = 0;
  CurrentProcName   : String = '';       { Part 17: owner of statically-allocated locals }
  StackTempPeak    : Integer = 0;       { Part 17: peak live 256B string temps, per block }
  CurrentLocalBytes : Integer = 0;       { Part 17: prologue-allocated locals, per block }
  CurrentParamCopyBytes : Integer = 0;   { Part 18: frame copies of by-value String params }
  LastLiteralValue  : Integer = 0;
  LastLiteralKnown  : Boolean = False; { True if TOS is a known integer literal }
  InArgContext    : Boolean = false; { true inside ParseArguments }
  CurrentFuncArgBytes : Integer = 0;
  { Phase 10.3: TOS was loaded via [XY2+#N] -- EmitLoad can collapse to LOADD [XY2+#N] }
  LastWasXY2Addr  : Boolean = False; { True if TOS = address from [XY2+#N] fast path }
  LastXY2Offset   : Integer = 0;    { frame offset used in last [XY2+#N] address push }
  { EmitStore fast path: dest was EmitAddress'd via [XY2+#N] before RHS expression }
  DestIsXY2       : Boolean = False; { True if LHS dest is a simple [XY2+#N] frame slot }
  DestXY2Offset   : Integer = 0;    { frame offset of LHS dest }
  DestXY2Mark     : PCode   = nil;  { code node at which DestIsXY2 was set.

      Part 26. DestIsXY2 is set by EmitAddress on the FIRST frame access it
      meets while the LHS is being parsed -- and for `A[v] := x' that is the
      INDEX v, not the destination. EmitStore then took its [XY2+#N] fast
      path with the INDEX's offset and stored the value into v's own frame
      slot: the element address was computed correctly in D0 and thrown away.

      Reads through the same index were unaffected, so an array written
      through a setter kept returning its old contents with no fault and no
      wrong value -- just nothing new. It cost most of a session to find.

      The flag is only trustworthy when the frame-slot address push IS the
      destination, i.e. when nothing was emitted after it. Recording the node
      lets ParseAssignment check exactly that, the same way DestIsPaged is
      already validated structurally rather than trusted. }
  { ---------------------------------------------------------------------
    Part 23 bisect gates for the NON-optimiser changes. The optimiser passes
    have their own gate block at the top of K16Pascal_optimizer.inc. Set any
    of these False and rebuild to take one transform out of circulation.
    --------------------------------------------------------------------- }
  EnableConstSubscript : Boolean = True;  { constant array/string subscript fold }
  EnablePagedDest      : Boolean = True;  { STOREP destination for scalar assign }
  EnableConstShift     : Boolean = True;  { SHL/SHR Dn,#n vs the runtime call }
  EnableJMPTCase       : Boolean = True;  { jump-table case dispatch, else chain }

  { Part 23 (5.4 store path): dest is a compile-time address, so no address was
    pushed and EmitStore can write it with STOREP/STOREPB instead of popping an
    address it already knows. Set by ParseAssignment, consumed by EmitStore. }
  DestIsPaged     : Boolean = False;
  DestPagedAddr   : String  = '';   { the address expression, e.g. 'g_W + 8' }

(* ---- Core emit infrastructure ---- *)

(*
 * k/OS target rewrite, applied at the single emit sink (Emit0).  Mirrors the
 * mechanical transform used for k16_rtl_kos.asm, so every emitted instruction
 * is made .COM-safe in one place instead of at dozens of call sites:
 *   LOADI Yn,#$00  -> MOVE Yn,Y3   (data lives in the task page, not bank $00)
 *   CALL24/CALL    -> CALL16       (page-relative; only KLIB uses CALL24)
 *   JMP24/JMP      -> JMP16
 * Leaves .EQU, TRAP, Bcc.L (PC-relative) and everything else untouched.
 *)
function KosPatchInstr(const S: String): String;
var
  P, I: Integer;
  Mnem, Rest, RestC: String;
begin
  KosPatchInstr := S;
  if S = '' then Exit;
  P := Pos(' ', S);
  if P = 0 then Exit;
  Mnem := Copy(S, 1, P - 1);
  Rest := TrimStr(Copy(S, P + 1, MaxInt));
  if Mnem = 'CALL24' then Mnem := 'CALL16'
  else if Mnem = 'JMP24' then Mnem := 'JMP16'
  else if Mnem = 'CALL'  then Mnem := 'CALL16'
  else if Mnem = 'JMP'   then Mnem := 'JMP16'
  else if Mnem = 'LOADI' then
  begin
    RestC := '';
    for I := 1 to Length(Rest) do
      if Rest[I] <> ' ' then RestC := RestC + Rest[I];
    if (RestC = 'Y0,#$00') or (RestC = 'Y1,#$00') or (RestC = 'Y2,#$00') then
    begin
      Mnem := 'MOVE';
      Rest := Copy(RestC, 1, 2) + ', Y3';   { Yn, Y3 }
    end;
  end;
  KosPatchInstr := Mnem + ' ' + Rest;
end;

procedure Emit0(Tag, Instruction, Comment: String);
var
  P: Integer;
  S: String;
begin
  if (Tag = '') and (Instruction = '') and (Comment <> '') then
  begin
    WriteLn(Target, '; ', Comment);
    Exit;
  end;

  if TargetKOS and (Instruction <> '') then
    Instruction := KosPatchInstr(Instruction);

  S := '';

  { K16 assembler: .EQU format is '.EQU symbol, value' (directive-first) }
  if Tag <> '' then
  begin
    if Copy(Instruction, 1, 4) = '.EQU' then
    begin
      { Reformat: 'symbol .EQU value' -> '.EQU symbol, value' }
      Instruction := '.EQU ' + Tag + ', ' + TrimStr(Copy(Instruction, 6, 255));
      { Tag consumed into instruction; don't emit as label }
    end
    else if (Copy(Instruction, 1, 3) = '.RS') or (Copy(Instruction, 1, 7) = '.REGION') then
      { .RS / .REGION want 'SYMBOL .RS count' -- label on same line, NO colon }
      S := S + PadStr(Tag, 15) + ' '
    else
      S := S + Tag + ':';
  end;

  if Instruction <> '' then
  begin
    P := Pos(' ', Instruction);
    if (P <> 0) and (Copy(Instruction, 1, 1) <> '.') then
      Instruction := PadStr(Copy(Instruction, 1, P-1), 9) + TrimStr(Copy(Instruction, P+1, 255));

    S := PadStr(S, 16) + Instruction;
  end;

  if Comment <> '' then
    S := PadStr(S, 52) + '; ' + Comment;

  WriteLn(Target, S);
end;

procedure SetLibrary;
begin
  { The $L directive never opens the file -- it emits .INCLUDE for the
    assembler -- so it has to probe on disk to pick a path rather than
    discovering the answer by failing to open one.  Same two-entry order as
    the $I directive: source dir, then rtl. }
  FileName := ResolveInclude(FileName);

  Flush;
  { Part 24: was `include "..."` -- lowercase and dotless, a PASTA/80 leftover
    that the K16 assembler rejects as an unknown instruction.  Same family as
    the Z80 `ld (hl),e` that Mem[] carried.  Nothing had exercised $L on this
    target before memory.pas. }
  Emit0('', '.INCLUDE "' + FileName + '"', '');
end;

procedure Emit(Tag, Instruction, Comment: String);
begin
  (* Part 23 (1): invalidate the literal tracker on every push.
   *
   * LastLiteralKnown means "the top of the evaluation stack is the literal
   * LastLiteralValue"; EmitBinOp reads it to fold the right operand into an
   * immediate. Clearing it used to be each value-producing routine's own
   * job, and nine of the fourteen that push a value never did -- so a
   * literal's value survived across the thing that replaced it, and the
   * fold used the stale operand. Confirmed live in seven forms, including
   *   a + F(7)        -> ADD D0,#7   (return value computed, then discarded)
   *   W[7]            -> ADD D0,#7   (should be +14; odd addr -> DATA FAULT)
   *   a + -3          -> ADD D0,#3   (sign inverted)
   *
   * Clearing here makes it structural instead of remembered: a routine
   * added later cannot forget. EmitLiteral is unaffected because it pushes
   * first and sets the flag afterwards.
   *
   * The test is deliberately broad -- any PUSH, not just PUSH D0,XY3.
   * Over-clearing costs at most a fold; under-clearing miscompiles. *)
  if Copy(Instruction, 1, 4) = 'PUSH' then
    LastLiteralKnown := False;

  if not Optimize then
  begin
    Emit0(Tag, Instruction, Comment);
    Exit;
  end;

  if Tag <> '' then Flush;

  AppendCode(Tag, Instruction, Comment);

  while DoOptimize do
  begin
  end;
end;

procedure EmitI(S: String);
begin
  Emit('', S, '');
end;

(* ---- Part 19 item 5 (1b(B)): frame-reserved concat destinations ----------
 * The concat destination used to be ONE static buffer per routine, so a
 * recursive routine's callee overwrote the dest its caller was still
 * accumulating into (Part 18 s4 rejected exactly that). It cannot go on the
 * stack either: the stack is LIFO and downward-growing, and the dest is only
 * known to be needed once the '+' is seen -- after the left operand's temps
 * are already below it -- so freeing those temps walks X3 up through the live
 * dest (Part 18 s7 proves this).
 *
 * The fix is to reserve the dest area in the PROLOGUE, above the string-temp
 * watermark. Frame layout below the frame base XY2:
 *
 *     X2                      <- frame base
 *     X2 - LocalBytes         locals occupy [X2-LocalBytes, X2)
 *     X2 - LocalBytes - 256   dest 0
 *     X2 - LocalBytes - 512   dest 1   ...
 *     X3 after prologue       = X2 - (LocalBytes + Dests*256)
 *     ... string temps SUB X3,#256 from here DOWN
 *
 * Every dest is per-invocation, so recursion is safe; and because the temps
 * live strictly below the dest area, freeing them can never disturb a dest.
 *
 * The dest COUNT is unknown when the prologue is emitted, so the prologue's
 * single SUB takes a forward .EQU resolved in the footer. Part 19 verified the
 * assembler accepts that and that symbolic immediates always take the IMM16
 * form, so the encoding width is identical on both passes -- no phase shift.
 *
 * Keyed by slot prefix rather than by call-graph node, because main does not
 * go through ParseBlock and so has no CGCurrent.
 *)
var
  FSNames:  array of String;
  FSLocals: array of Integer;
  FSDests:  array of Integer;
  { Part 20: peak bytes of `with` base slots this routine needs. They sit
    immediately BELOW the locals so their offset stays numerically known when
    a field reference is emitted (a field ref carries a plain Integer Value).
    That pushes the dest area down by this much -- see EmitConcatDestAddr. }
  FSWith:   array of Integer;
  FSCount:  Integer = 0;
  { Dests are REUSED across statements, exactly as the static slots they
    replaced were (those reset per statement too; the pool itself was retired
    in Part 21). FrameDestCur is the live depth within one statement; FSDests holds the routine's PEAK, which
    is what the frame must actually reserve. Without the reset a routine with
    N concat statements would reserve N*256 bytes instead of peak*256. }
  FrameDestCur: Integer = 0;

function FSIndex(const P: String): Integer;
var
  I: Integer;
begin
  for I := 0 to FSCount - 1 do
    if FSNames[I] = P then begin FSIndex := I; Exit; end;
  if FSCount >= Length(FSNames) then
  begin
    SetLength(FSNames,  FSCount + 32);
    SetLength(FSLocals, FSCount + 32);
    SetLength(FSDests,  FSCount + 32);
    SetLength(FSWith,   FSCount + 32);
  end;
  FSNames[FSCount]  := P;
  FSLocals[FSCount] := 0;
  FSDests[FSCount]  := 0;
  FSWith[FSCount]   := 0;
  FSIndex := FSCount;
  Inc(FSCount);
end;

function FrameSpaceSym: String;
begin
  FrameSpaceSym := 'FRAMESPACE_' + CurrentSlotPrefix;
end;

(* Part 20: bytes of `with` base slots, resolved in the footer. Forward-
   referenced from the body exactly as FRAMESPACE_* is -- symbolic immediates
   always take the IMM16 form, so the encoding width is stable across passes. *)
function WithBytesSym: String;
begin
  WithBytesSym := 'WITHBYTES_' + CurrentSlotPrefix;
end;

(* Reserve one 2-byte `with` base slot; returns its byte offset below X2.
   Called from ParseWithVar, which has already moved Offset down by 2, so the
   offset is simply -Offset and needs no separate cursor. *)
procedure NoteWithBytes(Bytes: Integer);
var
  I: Integer;
begin
  I := FSIndex(CurrentSlotPrefix);   { own statement -- see EmitFrameSpace }
  if Bytes > FSWith[I] then FSWith[I] := Bytes;
end;

(* One SUB covering locals AND the dest area. Emitted unconditionally: a
   routine with neither gets SUB X3,#0, which the footer .EQU makes explicit. *)
procedure EmitFrameSpace;
var
  I: Integer;
begin
  { FSIndex may SetLength the arrays, and Pascal resolves an array element
    reference before evaluating the index expression -- so the index must be
    taken in its own statement, or the first call indexes a zero-length array. }
  I := FSIndex(CurrentSlotPrefix);
  FSLocals[I] := CurrentLocalBytes;
  Emit('', 'SUB    X3, #' + FrameSpaceSym, 'locals + concat dests');
end;

(* Address of this routine's concat dest N, computed off the frame base. *)
procedure EmitConcatDestAddr(N: Integer; const Note: String);
begin
  EmitI('MOVE   D0, X2');
  { Part 20: the with-slot area lies between the locals and the dests, and its
    size is not known until the routine has been parsed -- so the offset is
    <with bytes symbol> + <locals + (N+1)*256>, resolved in the footer. }
  Emit('', 'SUB    D0, #' + WithBytesSym + '+' +
       IntToStr(CurrentLocalBytes + (N + 1) * 256), Note);
end;

(* Part 20: reserve one 256-byte per-invocation block in this routine's frame
   and return its index. Extracted from EmitAllocConcatDest so that string
   ARGUMENT buffers can use the identical mechanism -- see EmitAllocStringTemp.

   Declared here, beside the registry, because EmitAllocStringTemp sits ahead
   of EmitAllocConcatDest in this file. *)
function AllocFrameBlock: Integer;
var
  FSI: Integer;
begin
  { FSIndex may SetLength -- take the index in its own statement (see
    EmitFrameSpace for why an inline index expression crashes here). }
  FSI := FSIndex(CurrentSlotPrefix);
  AllocFrameBlock := FrameDestCur;
  Inc(FrameDestCur);
  if FrameDestCur > FSDests[FSI] then FSDests[FSI] := FrameDestCur;
end;

procedure EmitC(S: String);
begin
  Emit('', '', S);
end;

procedure EmitInclude(S: String);
begin
  EmitI('.INCLUDE "' + S + '"');
end;

(* ---- EmitClear forward (needed by non-stdcall paths) ---- *)
procedure EmitClear(Bytes: Integer); forward;
procedure EmitAllocStringTemp; forward;  { Phase 6: string temp helpers }
procedure EmitFreeStringTemp; forward;

(* ---- Compute total arg bytes for a stdcall symbol ---- *)
function CalcArgBytes(Sym: PSymbol): Integer;
var
  I, J: Integer;
begin
  Result := 0;
  for I := 0 to Sym^.Value - 1 do
  begin
    if Sym^.ArgIsRef[I] then J := 2
    else if Sym^.ArgTypes[I]^.Kind = scStringType then J := 2  { strings passed as address }
    else
    begin
      J := Sym^.ArgTypes[I]^.Value;
      if J < 2 then J := 2;
    end;
    Result := Result + J;
  end;
end;

(* ---- Subroutine call ---- *)
(*
 * Emits a call to the given symbol. For stdcall procedures, arguments
 * have already been pushed; the callee cleans them via RET #Nw.
 * Non-stdcall ("magic") procedures pop 1-3 arguments into D0-D2.
 *)
procedure EmitCall(Sym: PSymbol);
var
  N, RegArgs: Integer;
  IsStrFunc: Boolean;
begin
  with Sym^ do
    if SmartLink and (Level = 0) and not IsExternal then
      AddDependency(CurrentBlock, Sym);

  { Part 18 Phase 0: persistent call graph. Separate from the Deps[]/IsAlive
    liveness marking above, which is gated to SmartLink/Level 0 and dies with
    the symbol table. Records nothing that reaches the output. }
  CGRecordCall(Sym, ConcatDestOpen > 0);

  N := Sym^.Value;  { declared arg count }
  IsStrFunc := (Sym^.Kind = scFunc) and (Sym^.DataType <> nil)
               and (Sym^.DataType^.Kind = scStringType);

  { V2 register-arg pop sequence.
    For normal funcs:   stack (top->btm) = argN ... arg1      ; pop D2..D0
    For string funcs:   stack (top->btm) = dest argN ... arg1 ; pop D0=dest, D2..D1=args
    Args beyond 3 (normal) or beyond 2 (string func) remain on stack for callee. }

  if IsStrFunc then
  begin
    EmitI('POP    D0, XY3');   { dest addr -> D0; D1/D2 already set before dest alloc }
    { D1/D2 were set by the caller (ParseArguments call site) before dest buf alloc }
    { Args beyond 2 remain on stack at [X3+4], [X3+6], ... }
  end
  else
  begin
    if N >= 3 then EmitI('POP    D2, XY3');
    if N >= 2 then EmitI('POP    D1, XY3');
    if N >= 1 then EmitI('POP    D0, XY3');
  end;

  EmitI('CALL24 ' + Sym^.Tag);
  LastWasXY2Addr := False;
  DestIsXY2      := False;

  if Sym^.Kind = scFunc then
    EmitI('PUSH   D0, XY3');  { result (or dest addr for strings) -> stack }
end;

(* ---- File header ---- *)
(*
 * Emits the K16 assembly file header.  The reset vector is at $FF0000.
 * A small stub initialises the stack and Y registers, then jumps to main.
 *)
procedure EmitHeader(Home: String; SrcFile: String);
begin
  EmitC('');
  EmitC('program ' + SrcFile);
  { Part 22: read the constant rather than a second literal -- the two had
    already drifted apart once. }
  EmitC('Generated by K16 Pascal v' + Version +
        '  (V2 ABI, XY2 frame cache)');
  EmitC('');

  if TargetKOS then
  begin
    EmitI('.INCLUDE "' + KosDir + '/kos_defs.inc"');
    EmitI('.INCLUDE "' + KosDir + '/klib/kos_klib.inc"');
    EmitI('.SPACE  pascal');
    EmitI('.ORG    $0200');
    EmitC('');

    { Part 24: the k/OS .COM header (k/OS Part 60).  The JMP16 comes FIRST so
      SPAWN_ENTRY_OFFSET is unchanged and a header parse can never endanger
      control flow.  PASCAL_PAGES / PASCAL_HEAPPAGES are forward .EQUs emitted
      by EmitFooter -- the directives that set them are not scanned until after
      this header has been written. }
    Emit('__reset', 'JMP16  __start', 'k/OS .COM entry -- $0200, 2 words');
    EmitI('.WORD  $4252');                { $0204 magic -- dumps 52 42 = "RB" }
    EmitI('.WORD  1');                    { $0206 header version }
    EmitI('.WORD  PASCAL_PAGES');         { $0208 total pages, incl. heap }
    EmitI('.WORD  PASCAL_HEAPPAGES');     { $020A how many of those are heap }
    EmitC('');

    Emit('__start', '', '$020C (Y3=task page, X3=$FFF0, kernel-set)');
    EmitI('MOVE   Y0, Y3');       { scratch Y banks = task page }
    EmitI('MOVE   Y1, Y3');
    EmitI('MOVE   Y2, Y3');
    EmitI('CALL16 __bssinit');    { zero-init globals before main }
    EmitI('CALL16 main');
    EmitI('LOADI  D0, #0');       { exit code 0 }
    EmitI('TRAP   #TRAP_EXIT');   { clean task exit (does not return) }
    EmitC('');

    EmitI('.INCLUDE "' + HomeDir + '/rtl/k16_rtl_kos.asm"');
    EmitC('');
  end
  else
  begin
    EmitI('.BASE   $F00000');
    EmitI('.ORG    $FF0000');
    EmitC('');

    Emit('__reset', '', 'Reset vector / startup');
    EmitI('LOADI  X3, #$BFF0');   { initial stack pointer - top of RAM }
    EmitI('LOADI  Y3, #$00');     { Y3 = bank 0 always (K16 convention) }
    EmitI('LOADI  Y0, #$00');     { all scratch Y regs = bank 0 }
    EmitI('LOADI  Y1, #$00');
    EmitI('LOADI  Y2, #$00');
    EmitI('CALL24 __bssinit');    { zero-init globals before main }
    EmitI('CALL24 main');
    EmitI('HALT   #0');             { if main returns, halt cleanly }
    EmitC('');

    EmitI('.INCLUDE "' + HomeDir + '/rtl/k16_rtl.asm"');
    EmitC('');
  end;
end;

(* ---- File footer ---- *)
(*
 * Emits the K16 assembly file footer.  After the main program body the
 * assembler falls through to HALT #0.
 *)
procedure EmitTaskPageRegions; forward;   { Part 17: defined below; called from EmitFooter }

procedure EmitFooter(BinFile: String);
var
  BssBase: Integer;
  FSI: Integer;
begin
  EmitC('');
  Emit('__end', '', 'End of program');
  if TargetKOS then
  begin
    EmitI('LOADI  D0, #0');
    EmitI('TRAP   #TRAP_EXIT');
  end
  else
    EmitI('HALT   #0');
  EmitC('');

  { ---- BSS clear: zero-init globals region (Delphi/FPC semantics) ---- }
  { GlobalRAMOffset holds the high-water; region [base..highwater) is     }
  { word-aligned. Word STREAM clear; count 0 => BEQ skips. Absolute/MMIO  }
  { vars sit outside the region (they don't advance GlobalRAMOffset).     }
  if TargetKOS then BssBase := $008210 else BssBase := $000200;
  Emit('__bssinit', '', 'Zero-init globals (word STREAM clear) -- from __reset');
  EmitI('LOADI  D1, #' + IntToStr((GlobalRAMOffset - BssBase) div 2));
  EmitI('CMP    D1, #0');
  EmitI('BEQ.L  .bi_done');
  { k/OS: base is the GLOBALS region start (assembler-placed), not a literal.
    Count above is still a compile-time size. If there are no globals the count
    is 0 and the BEQ skips, so the placeholder base is never used. }
  if TargetKOS then
  begin
    if GlobalFieldCount > 0 then
      EmitI('LOADI  X0, #GLOBALS_START')
    else
      EmitI('LOADI  X0, #0');
  end
  else
    EmitI('LOADI  X0, #$' + IntToHex(BssBase, 4));
  EmitI('LOADI  Y0, #$00');        { -> MOVE Y0,Y3 on k/OS (task page) }
  EmitI('LOADI  D0, #0');
  Emit('.bi_loop', '', '');
  EmitI('STORED D0, [XY0]+');
  EmitI('SUB    D1, #1');
  EmitI('BNE.L  .bi_loop');
  Emit('.bi_done', '', '');
  EmitI('RET');
  EmitC('');

  { Part 19 item 5: resolve each routine's frame reservation. Emitted here
    because the dest count is only final once every body has been parsed. }
  if FSCount > 0 then
  begin
    EmitC('');
    EmitC('frame reservations (locals + 256B per concat dest)');
    for FSI := 0 to FSCount - 1 do
    begin
      Emit('WITHBYTES_' + FSNames[FSI], '.EQU ' + IntToStr(FSWith[FSI]),
           IntToStr(FSWith[FSI] div 2) + ' with slot');
      Emit('FRAMESPACE_' + FSNames[FSI],
           '.EQU ' + IntToStr(FSLocals[FSI] + FSWith[FSI] +
                              FSDests[FSI] * 256),
           IntToStr(FSLocals[FSI]) + ' B locals + ' +
           IntToStr(FSWith[FSI]) + ' B with + ' +
           IntToStr(FSDests[FSI]) + ' dest');
    end;
    EmitC('');
  end;

  { Part 24: values for the .COM header words at $0208 / $020A.  Emitted here
    because $PAGES / $HEAP are only final once the whole source has been
    scanned, and this is also the only place both are known -- so it is where
    the partition is checked. }
  if TargetKOS then
  begin
    if ComHeapPages >= ComPages then
      Error('{$HEAP} must be less than {$PAGES} -- page 0 is the task page');
    EmitC('');
    EmitC('.COM header page declaration (header words at $0208 / $020A)');
    Emit('PASCAL_PAGES', '.EQU ' + IntToStr(ComPages),
         'total contiguous pages, including heap');
    Emit('PASCAL_HEAPPAGES', '.EQU ' + IntToStr(ComHeapPages),
         'how many of those are heap');
    EmitC('');
  end;

  EmitTaskPageRegions;   { Part 17: regions last -- must follow ALL code }

  EmitC('end of ' + BinFile);
end;

(* ---- Variable list comment ---- *)
(*
 * Builds a textual description of all variables in scope, used as a
 * comment in the generated assembly.
 *)
procedure CollectVars(Sym: PSymbol; var S: String);
begin
  if Sym^.Kind <> scScope then CollectVars(Sym^.Prev, S);

  if Sym^.Kind = scVar then
  begin
    if S <> '' then S := S + ', ' + Sym^.Name else S := Sym^.Name;
    S := S + '(';
    if Sym^.Tag <> '' then
      S := S + '@' + Sym^.Tag + ')'
    else
    begin
      if Sym^.Value > 0 then S := S + '+';
      S := S + IntToStr(Sym^.Value) + ')';
    end;
  end;
end;

(* ---- String literal encoding ---- *)
(*
 * Encodes a Pascal string for use with the K16 .BYTE directive.
 * Generates:  length_byte [, "printable"] [, escape_byte ...]
 *)
function EncodeAsmStr(const S: String): String;
var
  T: String;
  Quotes: Boolean;
  I: Integer;
  C: Char;
begin
  T := IntToStr(Length(S));
  Quotes := False;

  for I := 1 to Length(S) do
  begin
    C := S[I];
    if (C < ' ') or (C > '~') or (C = '"') or (C = '\') then
    begin
      if Quotes then begin T := T + '"'; Quotes := False; end;
      T := T + ',' + IntToStr(Ord(C));
    end
    else
    begin
      if not Quotes then begin T := T + ',"'; Quotes := True; end;
      T := T + C;
    end;
  end;

  if Quotes then T := T + '"';
  EncodeAsmStr := T;
end;

(* ---- String literal pool ---- *)
(*
 * Emits all string literals collected during compilation.
 * Uses the K16 .BYTE directive (length byte then characters).
 *)
(* ---- Part 17: readable global symbol names ---- *)
(*
 * Globals were emitted as global<n>, which makes the region map useless for
 * diagnosis (you cannot tell which variable ate the arena). We now derive the
 * tag from the Pascal identifier: 'Rows' -> g_Rows.
 *
 * The 'g_' prefix is reserved and deliberate: a field name that collides with
 * an existing symbol is a hard assembler error, so user code must not be able
 * to break the build by naming a variable TASKRAM_TOP, TIB_PTR or any kos_defs
 * symbol. Nothing in the kernel/RTL/compiler namespace starts with 'g_'.
 * Duplicate Pascal names (k16_system.pas vs the program) get _2, _3, ...
 * Comparison is case-insensitive because assembler symbols are.
 *)
function UpStr(const S: String): String;
var
  I: Integer;
  T: String;
begin
  T := S;
  for I := 1 to Length(T) do T[I] := UpCase(T[I]);
  UpStr := T;
end;

function GlobalTagTaken(const Cand: String): Boolean;
var
  I: Integer;
  U: String;
begin
  U := UpStr(Cand);
  GlobalTagTaken := False;
  for I := 0 to GlobalTagCount - 1 do
    if UpStr(GlobalTagNames[I]) = U then
    begin
      GlobalTagTaken := True;
      Exit;
    end;
end;

function SanitiseIdent(const Name: String): String;
var
  I: Integer;
  Ch: Char;
  R: String;
begin
  R := '';
  for I := 1 to Length(Name) do
  begin
    Ch := Name[I];
    if ((Ch >= 'A') and (Ch <= 'Z')) or ((Ch >= 'a') and (Ch <= 'z')) or
       ((Ch >= '0') and (Ch <= '9')) or (Ch = '_') then
      R := R + Ch
    else
      R := R + '_';                   { non-identifier char -> underscore }
  end;
  SanitiseIdent := R;
end;

(* Owner = '' for a program-scope global -> g_<Name>.
   Otherwise the var is a procedure local that this compiler allocates
   STATICALLY, so qualify it by its owner -> l_<Proc>_<Name>. That both
   removes the _2/_3 noise and shows in the region map which procedure
   owns the storage. *)
function MakeGlobalTag(const Owner, Name: String): String;
const
  MAXBASE = 32;                        { keep symbols a sane length }
var
  Base, Cand: String;
  N: Integer;
begin
  Base := SanitiseIdent(Name);
  if Base = '' then Base := 'anon';
  if Owner = '' then
    Base := 'g_' + Base
  else
    Base := 'l_' + SanitiseIdent(Owner) + '_' + Base;
  if Length(Base) > MAXBASE then Base := Copy(Base, 1, MAXBASE);

  Cand := Base;
  N := 1;
  while GlobalTagTaken(Cand) do
  begin
    Inc(N);
    Cand := Base + '_' + IntToStr(N);
  end;

  if GlobalTagCount >= Length(GlobalTagNames) then
    SetLength(GlobalTagNames, GlobalTagCount + 64);
  GlobalTagNames[GlobalTagCount] := Cand;
  Inc(GlobalTagCount);
  MakeGlobalTag := Cand;
end;

(* ---- Part 17: record a k/OS global as a GLOBALS region field ---- *)
(*
 * k/OS globals are no longer emitted as fixed .EQU addresses at declaration.
 * They are collected here and emitted as .RS fields of the GLOBALS .REGION at
 * end of file (EmitTaskPageRegions), so the assembler places them after code.
 *)
procedure AddGlobalField(const Tag: String; Bytes: Integer);
begin
  if GlobalFieldCount >= Length(GlobalFieldTags) then
  begin
    SetLength(GlobalFieldTags,  GlobalFieldCount + 64);
    SetLength(GlobalFieldBytes, GlobalFieldCount + 64);
  end;
  GlobalFieldTags[GlobalFieldCount]  := Tag;
  GlobalFieldBytes[GlobalFieldCount] := Bytes;
  Inc(GlobalFieldCount);
end;

(* ---- Part 17: task-page RAM regions, placed by the assembler (k/OS) ---- *)
(*
 * Emitted at the very end of the image, after ALL code. The first region takes
 * an explicit start of code_end (a label); every later region auto-chains off
 * the previous region's _END. Nothing here emits bytes -- .RS is reservation
 * only, so the .COM stays code-sized. Adding code re-flows every address.
 *
 * Order: GLOBALS | DISPLAY | RTLVARS
 *
 * The last region is capped at TASKRAM_TOP, so an arena that grows past the
 * task-page RAM ceiling is an assemble-time error ("region RTLVARS overflowed")
 * instead of silent runtime corruption. The bump heap starts at RTLVARS_END and
 * grows UP from there, so this cap bounds the reserved storage, not the heap. Regions are contiguous, so capping the last one
 * bounds them all. (Caps require an explicit start -- see OpenRegion.)
 * RTLVARS holds the buffers that used to be fixed .EQUs at $8000..$81FF in
 * k16_rtl_kos.asm (those .EQUs are removed there; the RTL now references these
 * symbols, resolved by second-pass operand fixup).
 *)
procedure EmitTaskPageRegions;
var
  I, W: Integer;
  First: Boolean;
  PrevRegion: String;

  (* Cap = '' for an uncapped region. A CAPPED region may NOT omit its start
     (".REGION , cap" is a syntax error), so a capped non-first region chains
     explicitly off the previous region's _END -- which places identically to
     auto-chaining. Cap overflow is a hard assembler error naming the region. *)
  procedure OpenRegion(const Name, Comment, Cap: String);
  begin
    if First then
    begin
      if Cap <> '' then
        Emit(Name, '.REGION code_end, ' + Cap, Comment)
      else
        Emit(Name, '.REGION code_end', Comment);
      First := False;
    end
    else if Cap <> '' then
      Emit(Name, '.REGION ' + PrevRegion + '_END, ' + Cap, Comment)
    else
      Emit(Name, '.REGION', Comment + ' (auto-chained)');
    PrevRegion := Name;
  end;

begin
  if not TargetKOS then Exit;
  First := True;
  PrevRegion := '';
  EmitC('');
  EmitC('Task-page RAM regions -- assembler-placed, sized from use.');
  EmitC('First region starts at code_end; the rest auto-chain off _END.');
  EmitI('.ALIGN  2');
  Emit('code_end', '', 'first byte past the emitted image');

  if GlobalFieldCount > 0 then
  begin
    OpenRegion('GLOBALS', 'Pascal global variables', '');
    for I := 0 to GlobalFieldCount - 1 do
    begin
      W := (GlobalFieldBytes[I] + 1) div 2;      { whole words -> cursor stays even }
      if W < 1 then W := 1;
      Emit(GlobalFieldTags[I], '.RS ' + IntToStr(W) + 'w', '');
    end;
    EmitI('.ENDREGION');
  end;

  OpenRegion('DISPLAY', 'frame pointer display', '');
  Emit('display', '.RS ' + IntToStr(DisplaySlots) + 'w',
       IntToStr(DisplaySlots * 2) + ' bytes');
  EmitI('.ENDREGION');

  OpenRegion('RTLVARS', 'RTL buffers; capped at the task-page RAM ceiling', 'TASKRAM_TOP');
  Emit('TIB_BASE',     '.RS 64w',  '128-byte line buffer');
  Emit('TIB_PTR',      '.RS 1w',   'current read position');
  Emit('STRN_DIGITS',  '.RS 4w',   '8-byte digit scratch');
  Emit('STRN_SCRATCH', '.RS 128w', '256-byte format scratch');
  Emit('HEAP_PTR',     '.RS 1w',   'bump-heap pointer (grows UP from RTLVARS_END)');
  EmitI('.ENDREGION');
  EmitC('');
end;

procedure EmitStrings();
var
  Temp: PStringLiteral;
begin
  Temp := Strings;
  while Temp <> nil do
  begin
    EmitI('.ALIGN 2');   { word-align: K16 16-bit ROM, LOADB fails on odd addresses }
    Emit(Temp^.Tag, '.BYTE  ' + EncodeAsmStr(Temp^.Value), Temp^.Value);
    Temp := Temp^.Next;
  end;
  if Strings <> nil then
    EmitI('.ALIGN 2');   { word-align after last string before eof/HALT }
end;

(* ---- EmitSpace forward (needed by EmitPrologue) ---- *)
procedure EmitSpace(Bytes: Integer); forward;

(* ---- Procedure / function prologue ---- *)
(*
 * Stack frame layout (same as Z80 PASTA/80):
 *
 *   +------------------+
 *   | result (if any)  |
 *   | 1st argument     |  } caller-pushed, caller-cleaned
 *   | nth argument     |
 *   | return address   |  (2 bytes, pushed by CALL24)
 *   | old frame ptr    |  <-- frame pointer (display[Level])
 *   | 1st local        |
 *   | nth local        |  <-- stack pointer (X3)
 *   +------------------+
 *
 * Frame pointers live in display[], a 16-byte area in zero page.
 * display[Level*2] holds the current frame base for nesting Level.
 *)
procedure EmitPrologue(Sym: PSymbol);
var
  V: String;
  DispOfs: String;
  S: PSymbol;
  IsStrFunc: Boolean;
  ArgReg: Integer;
  AllocBytes: Integer;
  CopyBytes: Integer;
  RegName: array[0..2] of String;
begin
  RegName[0] := 'D3'; RegName[1] := 'D1'; RegName[2] := 'D2';
  { Note: D0 is saved in D3 at prologue entry; D1/D2 are arg2/arg3 directly }

  V := '';
  CollectVars(SymbolTable, V);
  if V <> '' then
  begin
    EmitC('var ' + V);
    EmitC('');
  end;

  FrameDestCur := 0;        { Part 19: frame dests are numbered per routine }
  DestIsXY2 := False;  { clear cross-procedure flag }
  DestIsPaged := False;
  CurrentParamCopyBytes := 0;

  if Sym = nil then
  begin
    { Main program entry point }
    Emit('main', '', 'Program entry');
    EmitI('MOVE   D0, X3');
    EmitI('STOREP D0, Y3, [#display]');  { display[0] = initial SP }
    (* Part 22 (4.1): display[1..7] are NOT seeded here.
     *
     * Part 20 (B) seeded them from main's frame base because the epilogue
     * restored X2 from display[Level] -- so a level-1 callee returning to
     * level-0 main would otherwise have restored an uninitialised word.
     * Part 21 (4.2) replaced that with PUSH X2 / POP X2, so X2 no longer
     * comes out of display[] at all and the seed values were never read.
     *
     * display[] is now purely lexical. Slot N is written by the prologue of
     * a level-N routine and read for uplevel access, which can only execute
     * while that routine is active -- i.e. after its own prologue wrote the
     * slot. The prologue's own LOADP of display[Level] saves the previous
     * occupant for the epilogue to put back; on the first entry to a level
     * that word is undefined, but it is only ever stored, never
     * interpreted. So no slot is read before it is written. *)
    EmitI('MOVE   X2, D0');              { XY2 = frame base (V2) }

    (* Y2 is NOT re-established here, and that is deliberate.
       Part 25 briefly emitted MOVE Y2,Y3 in every prologue, because
       sys_open was destroying XY2 -- _SlotForDrive leaves the volume
       slot in X2 and LOADI Y2,#$00. That was the wrong layer: it cost
       a word per call and only repaired the frame pointer at entry,
       not after the syscall that broke it. Fixed kernel-side instead;
       XY2 is now callee-preserved across syscalls (kos_defs.inc). *)
    EmitCall(LookupBuiltInOrFail('InitHeap'));
    CurrentLocalBytes := -Offset;        { Part 17: for the frame comment }
    if CurrentLocalBytes < 0 then CurrentLocalBytes := 0;
    EmitFrameSpace;                      { Part 19: locals + frame concat dests }
  end
  else
  begin
    DispOfs := IntToStr(Level * 2);
    Emit(Sym^.Tag, '', 'Prologue');

    (* Part 21 (4.2): save the DYNAMIC caller's frame pointer.
     *
     * display[] is a LEXICAL structure -- ParseVariableAccess reads it for
     * uplevel access when Sym^.Level <> Level -- so the saved-display word the
     * prologue already pushes is the previous occupant of THIS lexical level,
     * not the routine that called us. The epilogue used to restore X2 from it,
     * which is the same thing only when caller and callee share a level.
     * Part 20 seeded display[1..7] from main so the level-0 -> level-1 case
     * worked; a level-1 -> level-2 return still restored the wrong base.
     *
     * X2 holds the caller's frame base right now, so push it. This goes BEFORE
     * the SUB X3,#AllocBytes below, so the frame base keeps its offset from the
     * spill area and every [XY2+#N] slot -- params, ResultOfs, the parser's
     * base-+2 convention -- is unchanged. The whole frame simply sits 2 bytes
     * lower. Popped in EmitEpilogue after the ADD X3,#SkipBytes. *)
    EmitI('PUSH   X2, XY3');             { caller's frame pointer }

    IsStrFunc := (Sym^.DataType <> nil) and (Sym^.DataType^.Kind = scStringType);
    CurrentFuncArgBytes := CalcArgBytes(Sym);

    if (Sym^.Value >= 1) or IsStrFunc then
      EmitI('MOVE   D3, D0');             { save arg1 before frame setup clobbers D0 }

    EmitI('LOADP  D0, Y3, [#display+' + DispOfs + ']');  { D0 = old frame ptr }

    { V2 fix: pre-allocate spill space + RESULT slot before pushing old fp }
    AllocBytes := CurrentFuncArgBytes;
    if Sym^.Kind = scFunc then
      AllocBytes := AllocBytes + 2;  { RESULT needs its own slot (all func kinds) }
    if AllocBytes > 0 then
      Emit('', 'SUB    X3, #' + IntToStr(AllocBytes),
           'alloc ' + IntToStr(AllocBytes) + 'b spill/result space');

    EmitI('PUSH   D0, XY3');                              { push old fp }
    EmitI('MOVE   D0, X3');                               { D0 = new frame base }
    EmitI('STOREP D0, Y3, [#display+' + DispOfs + ']');  { display[Level] = frame base }
    EmitI('MOVE   X2, D0');                               { XY2 = frame base }

    (* Y2 is NOT re-established here, and that is deliberate.
       Part 25 briefly emitted MOVE Y2,Y3 in every prologue, because
       sys_open was destroying XY2 -- _SlotForDrive leaves the volume
       slot in X2 and LOADI Y2,#$00. That was the wrong layer: it cost
       a word per call and only repaired the frame pointer at entry,
       not after the syscall that broke it. Fixed kernel-side instead;
       XY2 is now callee-preserved across syscalls (kos_defs.inc). *)

    if IsStrFunc then
    begin
      { Spill dest (was D0, now in D3) to RESULT slot }
      S := SymbolTable;
      while S <> nil do
      begin
        if (S^.Kind = scVar) and (S^.Tag = 'RESULT') then
        begin
          Emit('', 'STORED D3, [XY2+#' + IntToStr(S^.Value) + ']', 'spill dest->RESULT');
          Break;
        end;
        S := S^.Prev;
      end;
      ArgReg := 1;  { real args start at D1 }
    end
    else
      ArgReg := 0;  { D0 (now in D3) = first param }

    { Walk params in declaration order (ArgIsRef/ArgTypes[0]=first).
      Symbol table is in reverse order; collect then spill in forward order.
      Params have Value > 0 and Kind=scVar with no Tag (or Tag<>'RESULT'). }
    if Sym^.Value > 0 then
    begin
      { Collect param symbols, sort by Value descending = declaration order.
        Simple insertion into a small fixed array (max 8 args). }
      { Walk once: gather all params with Value>=6 and Tag<>'RESULT' }
      S := SymbolTable;
      while S <> nil do
      begin
        if (S^.Kind = scVar) and (S^.Value >= 2) and (S^.Tag <> 'RESULT') then
        begin
          begin
            { rank = (Value - 2) / 2  (base is now +2 not +6) }
            if IsStrFunc then
              ArgReg := 1 + (Sym^.Value - 1) - (S^.Value - 2) div 2
            else
              ArgReg := 0 + (Sym^.Value - 1) - (S^.Value - 2) div 2;
            if ArgReg <= 2 then
              Emit('', 'STORED ' + RegName[ArgReg] + ', [XY2+#' + IntToStr(S^.Value) + ']',
                   'spill ' + RegName[ArgReg] + '->[frame+' + IntToStr(S^.Value) + ']');
          end;
        end;
        S := S^.Prev;
      end;
    end;

    CurrentLocalBytes := -Offset;        { Part 17: for the frame comment }
    if CurrentLocalBytes < 0 then CurrentLocalBytes := 0;
    EmitFrameSpace;                      { Part 19: locals + frame concat dests }

    { ---- Part 18 Phase 1b(A): by-value String parameters ---- }
    (*
     * A String passed by value arrives as a bare 2-byte pointer spilled into a
     * frame slot, so the callee ALIASES the caller's buffer: assigning to the
     * parameter writes through to the caller, and under recursion the child's
     * arg slot overwrites a parent that still needs its own copy (RecStr/RevA).
     *
     * Copy each one into this frame and repoint the slot at the copy. Every
     * later use derefs the slot, so no other code changes and no symbol is
     * rebound. Pass-by-reference (var s: String) is untouched, and a string
     * function's RESULT slot -- which legitimately holds the CALLER's dest
     * pointer -- is excluded by the Tag test.
     *
     * Placement is load-bearing: this must follow the register spills above,
     * which hold the incoming args in D1/D2/D3 until they reach the frame.
     * __storestr preserves D0 (dest) and XY2 (it works through XY0/XY1), so
     * the frame pointer survives and D0 is still the copy's address on return.
     * No explicit free: the epilogue restores X3 from display[].
     *)
    S := SymbolTable;
    while (S <> nil) and (S <> CurrentScope) do
    begin
      if (S^.Kind = scVar) and (S^.Value >= 2) and (S^.Tag <> 'RESULT')
         and (not S^.IsRef) and (S^.DataType <> nil)
         and (S^.DataType^.Kind = scStringType) then
      begin
        CopyBytes := S^.DataType^.Value;        { declared max + 1 length byte }
        if CopyBytes < 2 then CopyBytes := 2;
        if CopyBytes and 1 = 1 then Inc(CopyBytes);   { keep X3 word-aligned }

        Emit('', 'SUB    X3, #' + IntToStr(CopyBytes),
             'frame copy of String param [XY2+#' + IntToStr(S^.Value) + ']');
        EmitI('MOVE   D0, X3');
        Emit('', 'LOADD  D1, [XY2+#' + IntToStr(S^.Value) + ']', 'caller pointer');
        Emit('', 'LOADI  D2, #' + IntToStr(S^.DataType^.Value - 1), 'max length');
        EmitI('CALL24 __storestr');
        Emit('', 'STORED D0, [XY2+#' + IntToStr(S^.Value) + ']',
             'param now points at the copy');

        CurrentParamCopyBytes := CurrentParamCopyBytes + CopyBytes;
      end;
      S := S^.Prev;
    end;
  end;
end;

(* ---- Procedure / function epilogue ---- *)
(*
 * Restores the frame pointer from the display, pops the saved old
 * frame pointer, and returns.
 *)
procedure EmitEpilogue(Sym: PSymbol);
var
  DispOfs: String;
  ArgBytes, SkipBytes: Integer;
  S: PSymbol;
  ResultOfs: Integer;
  IsFunc: Boolean;
begin
  if Sym <> nil then
  begin
    DispOfs  := IntToStr(Level * 2);
    ArgBytes := CalcArgBytes(Sym);

    { For all functions (scalar and string), find RESULT offset to return in D0 }
    IsFunc := (Sym^.Kind = scFunc) and (Sym^.DataType <> nil);
    ResultOfs := 0;
    if IsFunc then
    begin
      S := SymbolTable;
      while S <> nil do
      begin
        if (S^.Kind = scVar) and (S^.Tag = 'RESULT') then
        begin
          ResultOfs := S^.Value;
          Break;
        end;
        S := S^.Prev;
      end;
      if ResultOfs = 0 then IsFunc := False;
    end;

    Emit(ExitTarget, '', 'Epilogue');
    EmitI('LOADP  D0, Y3, [#display+' + DispOfs + ']');  { D0 = frame base }
    EmitI('MOVE   X3, D0');                               { X3 = frame base }

    { Restore display[Level] -- the LEXICAL chain. X2 is NOT restored from this
      value; see below. }
    if IsFunc then
    begin
      { Load RESULT into D0 (scalar: the computed value; string: dest addr).

        Part 25: the WIDTH must match the store.  Assignment to the function
        name goes through EmitStore, which is type-directed and emits STOREB
        for a 1-byte result, but the RESULT slot is always 2 bytes -- so a
        LOADD here returns (stale high byte) shl 8 or value.

        Boolean is the loud case.  `not F(x)' compiles to XOR D0,#1, which
        clears only the low bit; a dirty high byte survives it and the result
        tests non-zero either way, so BOTH F(x) and not F(x) read as True.
        Byte and Char are quieter and just as wrong.

        Value = 1 is the narrow test on purpose: a String result holds a dest
        ADDRESS in the slot, and DataType^.Value is the string's size, so it
        stays on the LOADD arm along with every other word-sized result. }
      if Sym^.DataType^.Value = 1 then
        EmitI('LOADB  D0, [XY3+#' + IntToStr(ResultOfs) + ']')
      else
        EmitI('LOADD  D0, [XY3+#' + IntToStr(ResultOfs) + ']');
      EmitI('POP    D1, XY3');
      EmitI('STOREP D1, Y3, [#display+' + DispOfs + ']');
    end
    else
    begin
      EmitI('POP    D0, XY3');
      EmitI('STOREP D0, Y3, [#display+' + DispOfs + ']');
    end;

    { Skip all pre-allocated space (spills + RESULT if func) to reach the
      caller's frame pointer. SkipBytes always equals the prologue's AllocBytes,
      so X3 lands exactly on the word PUSH X2 wrote. }
    SkipBytes := ArgBytes;
    if IsFunc then SkipBytes := SkipBytes + 2;
    if SkipBytes > 0 then
      EmitI('ADD    X3, #' + IntToStr(SkipBytes));

    (* Part 21 (4.2): X2 comes off the stack, not out of display[].
       D1 is free in both paths -- D0 carries the result for functions. *)
    EmitI('POP    D1, XY3');             { caller's frame pointer }
    EmitI('MOVE   X2, D1');
    EmitI('RET');
  end
  else
  begin
    Emit(ExitTarget, '', 'Epilogue');  { main }
    (* Part 20: restore X3 before returning to the .COM entry stub.
     *
     * main's prologue does SUB X3,#FRAMESPACE_main and nothing ever gave
     * it back. That was harmless for as long as FRAMESPACE_main was always
     * 0 -- main's variables are allocated as globals, so it has no locals,
     * and its string arg buffers used to be static addresses. Part 20 made
     * those buffers frame blocks, so main now reserves real space and RET
     * popped its return address from 1024 bytes below where CALL16 main
     * pushed it, jumping into ROM with a corrupted Y3.
     *
     * display[0] holds X3 exactly as it was on entry, so restoring from it
     * also absorbs any unbalanced string-temp SUB in main's body. D0 is
     * free here: the entry stub reloads it for the TRAP_EXIT status. *)
    EmitI('LOADP  D0, Y3, [#display]');
    EmitI('MOVE   X3, D0');
    EmitI('RET');
  end;
end;

(* ---- Push address of symbol onto stack ---- *)
(*
 * Globals:  push label address as 16-bit immediate.
 * Locals:   load frame pointer from display[Level], add variable offset.
 * Var params: extra dereference to get the referenced address.
 * Record fields: add Value2 offset after base address.
 *)
procedure EmitAddress(Sym: PSymbol);
var
  DispOfs: String;
  IsStrValParam: Boolean;
  StrDerefPending: Boolean;
begin
  LastLiteralKnown := False;
  LastWasXY2Addr := False;
  DestIsXY2      := False;
  StrDerefPending := False;

  (* ---- Part 18 Phase 1b(A2): by-value String parameters ----
   * The slot of a by-value String parameter holds a 2-byte POINTER to the
   * string -- since 1b(A), to this frame's private copy. So the address of the
   * string is the slot's CONTENT, not the slot itself, and this is the only
   * place that distinction can be made: everything downstream (EmitLoad,
   * EmitStore, ParseVariableAccess's index arithmetic) just consumes whatever
   * address we push.
   *
   * Without the deref, whole-string assignment wrote string bytes from the slot
   * upward -- over the remaining params, the saved frame pointer and the return
   * address -- and s[i] read or wrote the pointer bytes instead of characters.
   * A var parameter already gets this treatment below (IsRef), and a string
   * RESULT slot gets it in the Tag='RESULT' branch; this is the missing third
   * case, not a new mechanism.
   *)
  IsStrValParam := (Sym^.Tag = '') and (not Sym^.IsRef) and (Sym^.Value > 0)
                   and (Sym^.DataType <> nil)
                   and (Sym^.DataType^.Kind = scStringType);

  with Sym^ do
  begin
    if (Tag <> '') and (Tag <> 'RESULT') then
    begin
      { Global variable: push its RAM zero page address }
      Emit('', 'LOADI  D0, #' + Tag, 'Global ' + Name);
      EmitI('PUSH   D0, XY3');
    end
    else if (Tag = 'RESULT') and (DataType^.Kind = scStringType) then
    begin
      EmitI('LOADD  D0, [XY2+#' + IntToStr(Value) + ']');
      EmitI('PUSH   D0, XY3');
    end
    else
    begin
      DispOfs := IntToStr(Sym^.Level * 2);
      if (Sym^.Level = Level) and (Value > 0) and (Value <= 31) then
      begin
        { Param at positive frame offset in current scope.
          Emit the address push for EmitLoad/EmitStore to use.
          - EmitLoad: uses RemoveCode??3 to replace with LOADD [XY2+#N].
          - EmitStore: uses DestIsXY2 + DestXY2Offset; RemoveCode??3 is NOT
            used there (peephole may have changed the stream). Instead
            EmitStore uses the deferred NOPUSH path -- see below. }
        if IsStrValParam then
        begin
          { Push the pointer, not the slot address. LastWasXY2Addr/DestIsXY2
            stay False on purpose: what is on the stack is NOT a frame-slot
            address, so EmitStore must not take its [XY2+#N] fast path. }
          Emit('', 'LOADD  D0, [XY2+#' + IntToStr(Value) + ']', 'str ptr ' + Name);
          EmitI('PUSH   D0, XY3');
        end
        else
        begin
          EmitI('MOVE   D0, X2');
          Emit('', 'ADD    D0, #' + IntToStr(Value), Name);
          EmitI('PUSH   D0, XY3');
          LastWasXY2Addr := True;  LastXY2Offset := Value;
          if not DestIsXY2 then
          begin
            DestIsXY2     := True;
            DestXY2Offset := Value;
            DestXY2Mark   := Code;   { the PUSH just emitted -- see the
                                       declaration for why this is needed }
          end;
        end;
      end
      else if (Sym^.Level = Level) and (Value < 0) and (-Value <= 31) then
      begin
        { Current scope, small negative offset: push address only }
        EmitI('MOVE   D0, X2');
        Emit('', 'SUB    D0, #' + IntToStr(-Value), Name);
        EmitI('PUSH   D0, XY3');
      end
      else
      begin
        EmitI('LOADP  D0, Y3, [#display+' + DispOfs + ']');
        if Value > 0 then
          Emit('', 'ADD    D0, #' + IntToStr(Value), '')
        else if Value < 0 then
          Emit('', 'SUB    D0, #' + IntToStr(-Value), '');
        if Sym^.Level = Level then
        begin
          { Same scope large offset: push address only, EmitLoad will dereference }
          EmitI('PUSH   D0, XY3');
          { A String value param here still needs its pointer loaded. }
          if IsStrValParam then StrDerefPending := True;
        end
        else
        begin
          { Outer scope upvalue: load value through address }
          EmitI('MOVE   X0, D0');
          EmitI('LOADI  Y0, #$00');
          EmitI('LOADD  D0, [XY0]');
          EmitI('PUSH   D0, XY3');
        end;
      end;
    end;

    if StrDerefPending then
    begin
      LastWasXY2Addr := False;
      DestIsXY2      := False;
      EmitI('POP    D0, XY3');
      EmitI('MOVE   X0, D0');
      EmitI('LOADI  Y0, #$00');
      Emit('', 'LOADD  D0, [XY0]', 'str ptr ' + Name);
      EmitI('PUSH   D0, XY3');
    end;

    if IsRef then
    begin
      LastWasXY2Addr := False;
      DestIsXY2      := False;
      EmitI('POP    D0, XY3');
      EmitI('MOVE   X0, D0');
      EmitI('LOADI  Y0, #$00');
      EmitI('LOADD  D0, [XY0]');
      EmitI('PUSH   D0, XY3');
    end;

    if Value2 <> 0 then
    begin
      LastWasXY2Addr := False;
      DestIsXY2      := False;
      EmitI('POP    D0, XY3');
      Emit('', 'ADD    D0, #' + IntToStr(Value2), 'Field offset');
      EmitI('PUSH   D0, XY3');
    end;
  end;
end;

(* ---- Pop address, push value at that address ---- *)
procedure EmitLoad(DataType: PSymbol);
var
  SavedXY2: Boolean;
  SavedOfs: Integer;
begin
  LastLiteralKnown := False;
  { Capture and clear the XY2 fast-path flag before any early exits }
  SavedXY2 := LastWasXY2Addr;
  SavedOfs := LastXY2Offset;
  LastWasXY2Addr := False;

  if DataType^.Kind = scStringType then
  begin
    { String: address already on stack, nothing to dereference. }
    Exit;
  end;

  { When EmitAddress emitted MOVE D0,X2 / ADD D0,#N / PUSH D0,
    TOS is the address (frame_base + N). For word/byte types in the current
    scope we can replace the whole POP/MOVE/LOADI/LOADD sequence with a
    single LOADD/LOADB [XY2+#N] by removing the 3 address instructions
    and replacing with a direct indexed load.
    We do this by removing the last 3 emitted instructions (MOVE,ADD,PUSH)
    and emitting LOADD/LOADB [XY2+#N] / PUSH instead.
    Use RemoveLastN only when it is safe (not in arg context). }
  { The fast path collapses the address-push pattern MOVE D0,X2 / ADD D0,#N /
    PUSH D0 into a direct LOADD/LOADB [XY2+#N]. Only do so if the buffer tail
    ACTUALLY matches that pattern with no intervening label. SavedXY2 can be
    stale (e.g. left True by a preceding frame-slot store), in which case the
    real tail may be a global address push or a label -- removing 3 entries
    then would corrupt the stream (eat the false-label of an if/else chain and
    substitute a wrong frame load). }
  { Part 19 item 4: the InArgContext restriction is gone. What actually makes
    the rewrite safe is the exact tail-pattern match below, not the flag -- the
    fast path never touches X3, so it emits one PUSH just as the slow form did
    and the argument block is unchanged. Two guards added at the same time,
    because widening the gate sends 17 more sites down this path:
      - the MIDDLE instruction is now verified. It never was, yet SavedOfs (a
        separate variable) supplies the emitted offset -- so a tail whose ADD
        disagreed with SavedOfs would silently load from the wrong slot.
        Matching against IntToStr(SavedOfs) makes SavedOfs self-validating.
      - SavedOfs is range-checked to IMM5 (0..31). [XY2+#N] has no wider form,
        so a frame larger than 31 bytes previously emitted unassemblable code
        (assembler: "Offset 32 exceeds IMM5 range"). Out-of-range now falls
        back to the slow address form instead. }
  if SavedXY2
     and (DataType^.Value in [1, 2])
     and (SavedOfs >= 0) and (SavedOfs <= 31)
     and (Code <> nil) and (Code^.Prev <> nil) and (Code^.Prev^.Prev <> nil)
     and (Code^.Tag = '') and (Code^.Prev^.Tag = '') and (Code^.Prev^.Prev^.Tag = '')
     and (Code^.Instruction = 'PUSH   D0, XY3')
     and (Code^.Prev^.Instruction = 'ADD    D0, #' + IntToStr(SavedOfs))
     and (Code^.Prev^.Prev^.Instruction = 'MOVE   D0, X2') then
  begin
    { Remove: MOVE D0,X2 / ADD D0,#N / PUSH D0 (3 instructions) }
    RemoveCode;  { PUSH D0, XY3 }
    RemoveCode;  { ADD  D0, #N  }
    RemoveCode;  { MOVE D0, X2  }
    case DataType^.Value of
      1: begin
           Emit('', 'LOADB  D0, [XY2+#' + IntToStr(SavedOfs) + ']', 'byte [frame+' + IntToStr(SavedOfs) + ']');
           EmitI('PUSH   D0, XY3');
         end;
      2: begin
           Emit('', 'LOADD  D0, [XY2+#' + IntToStr(SavedOfs) + ']', '[frame+' + IntToStr(SavedOfs) + ']');
           EmitI('PUSH   D0, XY3');
         end;
    end;
    Exit;
  end;

  case DataType^.Value of
    1: begin
         Emit('', 'POP    D0, XY3', 'Load byte');
         EmitI('MOVE   X0, D0');
         EmitI('LOADI  Y0, #$00');
         EmitI('LOADB  D0, [XY0]');     { zero-extended byte }
         EmitI('PUSH   D0, XY3');
       end;
    2: begin
         Emit('', 'POP    D0, XY3', 'Load word');
         EmitI('MOVE   X0, D0');
         EmitI('LOADI  Y0, #$00');
         EmitI('LOADD  D0, [XY0]');
         EmitI('PUSH   D0, XY3');
       end;
    else
    begin
      { Large type (e.g. set = 32 bytes): src addr is on TOS.
        Allocate DataType^.Value bytes on stack, copy src into it.
        __memcopy: D0=dest, D1=src, D2=count }
      Emit('', 'POP    D1, XY3', 'Load ' + IntToStr(DataType^.Value) + 'b src addr');
      Emit('', 'SUB    X3, #' + IntToStr(DataType^.Value), 'alloc ' + IntToStr(DataType^.Value) + 'b on stack');
      EmitI('MOVE   D0, X3');
      Emit('', 'LOADI  D2, #' + IntToStr(DataType^.Value), '');
      EmitI('CALL24 __memcopy');        { D0=dest, D1=src, D2=count }
    end;
  end;
end;

(* ---- Pop value and address, store value ---- *)
(*
 * Stack on entry: ... address value  (value on top)
 *)
procedure EmitStore(DataType: PSymbol);
var
  SkipBytes: Integer;
  SavedDest, SavedPaged: Boolean;
  SavedDestOfs: Integer;
  SavedPagedAddr: String;
begin
  { Capture dest XY2 info immediately -- RHS may have cleared LastWasXY2Addr
    but DestIsXY2/DestXY2Offset were set by EmitAddress for the LHS dest. }
  SavedDest    := DestIsXY2;
  SavedDestOfs := DestXY2Offset;
  DestIsXY2    := False;  { consumed }
  SavedPaged     := DestIsPaged;
  SavedPagedAddr := DestPagedAddr;
  DestIsPaged    := False;  { consumed }

  if DataType^.Kind = scStringType then
  begin
    { Stack layout: [..., dest_addr(2), temp_block_1(256), ..., temp_block_N(256), src_addr(2)]
      where N = StringTempDepth (256-byte blocks allocated during RHS evaluation).
      POP D1 = src_addr. Then dest_addr is at X3 + N*256. }
    EmitI('POP    D1, XY3');            { D1 = src addr }
    SkipBytes := StringTempDepth * 256;
    if SkipBytes > 0 then
    begin
      { Skip over the N temp blocks to get dest_addr }
      Emit('', 'LOADI  D0, #' + IntToStr(SkipBytes), 'skip string temps to dest_addr');
      EmitI('ADD    D0, X3');           { D0 = &dest_addr }
      EmitI('MOVE   X0, D0');
      EmitI('LOADI  Y0, #$00');
      EmitI('LOADD  D0, [XY0]');       { D0 = dest_addr }
    end
    else
      EmitI('POP    D0, XY3');         { D0 = dest addr (no temps between) }
    Emit('', 'LOADI  D2, #' + IntToStr(DataType^.Value - 1), 'max length');
    EmitI('CALL24 __storestr');        { D0=dest, D1=src, D2=maxlen }
    { Free all stack temp blocks and the dest_addr word }
    if SkipBytes > 0 then
    begin
      { ADD X3 to skip past the temp blocks + dest_addr word (2 bytes) }
      Emit('', 'ADD    X3, #' + IntToStr(SkipBytes + 2), 'free string temps + dest_addr');
      StringTempDepth := 0;
    end;
    Exit;
  end;

  { Paged fast-path: the LHS address was a compile-time constant, so
    ParseAssignment retracted its push and handed the address over here. The
    stack therefore holds only the RHS value.

        POP    D0, XY3
        STOREP D0, Y3, [#addr]

    D0 rather than D1 for the value: with no address to hold, D0 is free, and
    the RHS pushed FROM D0 -- so peephole Rule 1 deletes the PUSH/POP pair
    outright rather than Rule 2 turning it into a MOVE. Passed := Passed + 1
    goes from ten instructions to four this way. }
  if SavedPaged and EnablePagedDest then
  begin
    if DataType^.Value = 1 then
    begin
      Emit('', 'POP    D0, XY3', 'Store byte value');
      Emit('', 'STOREPB D0, Y3, [#' + SavedPagedAddr + ']', 'paged dest');
    end
    else
    begin
      Emit('', 'POP    D0, XY3', 'Store word value');
      Emit('', 'STOREP  D0, Y3, [#' + SavedPagedAddr + ']', 'paged dest');
    end;
    Exit;
  end;

  { XY2 fast-path: LHS is a param at [XY2+#N].
    Stack: dest_addr value(top).
    Pop value D1, pop dest_addr D0 (discard), emit STORED/STOREB [XY2+#N].
    Peephole-safe: no RemoveCode needed. }
  if SavedDest and not InArgContext and (DataType^.Value in [1, 2]) then
  begin
    case DataType^.Value of
      1: begin
           Emit('', 'POP    D1, XY3', 'Store byte value');
           EmitI('POP    D0, XY3');          { discard dest addr }
           Emit('', 'STOREB D1, [XY2+#' + IntToStr(SavedDestOfs) + ']',
                '[frame+' + IntToStr(SavedDestOfs) + ']');
           Exit;
         end;
      2: begin
           Emit('', 'POP    D1, XY3', 'Store word value');
           EmitI('POP    D0, XY3');
           Emit('', 'STORED D1, [XY2+#' + IntToStr(SavedDestOfs) + ']',
                '[frame+' + IntToStr(SavedDestOfs) + ']');
           Exit;
         end;
    end;
  end;

  case DataType^.Value of
    1: begin
         Emit('', 'POP    D1, XY3', 'Store byte value');
         Emit('', 'POP    D0, XY3', 'Store byte address');
         EmitI('MOVE   X0, D0');
         EmitI('LOADI  Y0, #$00');
         EmitI('STOREB D1, [XY0]');
       end;
    2: begin
         Emit('', 'POP    D1, XY3', 'Store word value');
         Emit('', 'POP    D0, XY3', 'Store word address');
         EmitI('MOVE   X0, D0');
         EmitI('LOADI  Y0, #$00');
         EmitI('STORED D1, [XY0]');
       end;
    else
    begin
      { Large type (e.g. set = 32 bytes).
        Stack: [dest_addr][value(N bytes)] -- value on top.
        __memcopy: D0=dest, D1=src, D2=count }
      EmitI('MOVE   D1, X3');           { D1 = src = TOS (the value block) }
      Emit('', 'LOADI  D2, #' + IntToStr(DataType^.Value), '');
      EmitI('MOVE   D0, D2');           { D0 = offset = DataType^.Value }
      EmitI('LOADD  D0, [XY3+D0]');    { D0 = dest addr (register-indexed) }
      EmitI('CALL24 __memcopy');        { D0=dest, D1=src, D2=count }
      Emit('', 'ADD    X3, #' + IntToStr(DataType^.Value + 2), 'free value + dest_addr');
    end;
  end;
end;

(* ---- Push integer literal ---- *)
procedure EmitLiteral(Value: Integer);
begin
  Emit('', 'LOADI  D0, #' + IntToStr(Value), 'Literal ' + IntToStr(Value));
  EmitI('PUSH   D0, XY3');
  LastLiteralValue := Value;
  LastLiteralKnown := True;
end;

(* ---- Grow stack (allocate space) ---- *)
(*
 * Negative Bytes means grow (allocate); called as EmitSpace(-Offset).
 * ADD X3, #-N decrements the stack pointer by N bytes.
 *)
procedure EmitSpace(Bytes: Integer);
begin
  if Bytes = 0 then Exit;
  Emit('', 'SUB    X3, #' + IntToStr(Bytes), 'Space ' + IntToStr(Bytes));
end;

(* ---- Shrink stack (release space) ---- *)
procedure EmitClear(Bytes: Integer);
begin
  if Bytes = 0 then Exit;
  Emit('', 'ADD    X3, #' + IntToStr(Bytes), 'Clear ' + IntToStr(Bytes));
end;

(* ---- Is this type compared and divided as unsigned? ---- *)
(*
 * Part 24.  Word only.  Byte and Char are 0..255 and are zero-extended on
 * load, so a signed compare gives the identical answer for them -- adding
 * them here would change generated code for no benefit and for some risk.
 *)
function IsUnsignedType(T: PSymbol): Boolean;
begin
  while (T <> nil) and (T^.Kind = scSubrangeType) do T := T^.DataType;
  IsUnsignedType := (T = dtWord);
end;

(* ---- Relational operators (integer / boolean, 16-bit) ---- *)
(*
 * K16 has native Scc (set-conditional) instructions that set a register
 * to 1 or 0 based on the flags after CMP.  No runtime call needed.
 *
 * Stack on entry: ... left right  (right on top)
 * Result pushed: 1 (true) or 0 (false)
 *
 * Part 24 -- state the carry sense before reading the unsigned arm.  K16 is
 * 6502-style: after CMP A,B, C = 1 means NO BORROW, i.e. A >= B unsigned;
 * C = 0 means borrow, A < B.  RM s6.8.  The x86 autopilot is backwards.
 *
 * Only two unsigned conditions exist -- SHS/SCS (C=1) and SLO/SCC (C=0) --
 * so > and <= are obtained by SWAPPING THE OPERANDS rather than by a new
 * condition.  BHI/BLS are deliberately not used: RM s6.15.1/2 makes them
 * pseudo-instructions that expand to two branches plus a synthetic label,
 * where the swap costs one instruction.
 *)
procedure EmitRelOp(Op: TToken; Unsigned: Boolean);
begin
  Emit('', 'POP    D1, XY3', 'RelOp right');
  Emit('', 'POP    D0, XY3', 'RelOp left');

  if Unsigned and ((Op = toGt) or (Op = toLeq)) then
    Emit('', 'CMP    D1, D0', 'operands swapped: unsigned > and <= via SLO/SHS')
  else
    EmitI('CMP    D0, D1');

  if Unsigned then
    case Op of
      toEq:  EmitI('SEQ    D0');   { equality is sign-agnostic }
      toNeq: EmitI('SNE    D0');
      toLt:  EmitI('SLO    D0');   { C=0: borrow, D0 <  D1 }
      toGeq: EmitI('SHS    D0');   { C=1: no borrow, D0 >= D1 }
      toGt:  EmitI('SLO    D0');   { swapped: D1 <  D0 }
      toLeq: EmitI('SHS    D0');   { swapped: D1 >= D0 }
    end
  else
  case Op of
    toEq:  EmitI('SEQ    D0');
    toNeq: EmitI('SNE    D0');
    toLt:  EmitI('SLT    D0');
    toGt:  EmitI('SGT    D0');
    toLeq: EmitI('SLE    D0');
    toGeq: EmitI('SGE    D0');
  end;

  EmitI('AND    D0, #1');        { normalize $FFFF->1, $0000->0 }
  EmitI('PUSH   D0, XY3');
  LastLiteralKnown := False;  { result is a computed boolean, not a literal }
end;

procedure EmitUnOp(Op: TToken; DataType: PSymbol); forward;

(* ---- String relational operators (stub) ---- *)
procedure EmitStrOp(Op: TToken);
var
  Invert: Boolean;
  TempsBefore: Integer;
begin
  Invert := (Op = toNeq) or (Op = toGt) or (Op = toGeq);

  TempsBefore := StringTempDepth;
  EmitI('POP    D1, XY3');            { D1 = right addr }
  EmitI('POP    D0, XY3');            { D0 = left addr }

  case Op of
    toEq, toNeq: EmitI('CALL24 __streq');
    toLt, toGeq: EmitI('CALL24 __strlt');
    toGt, toLeq: EmitI('CALL24 __strleq');
  end;

  EmitI('PUSH   D0, XY3');
  if Invert then EmitUnOp(toNot, dtBoolean);

  { Phase 6: free any stack string temps consumed by this comparison.
    Both operands have been consumed; free one temp per stack-alloc'd operand. }
  while StringTempDepth > 0 do
    EmitFreeStringTemp;
end;

procedure EmitNeg(DataType: PSymbol); forward;

(* ---- Set operators (stub) ---- *)
procedure EmitSetOp(Op: TToken);
var
  Invert: Boolean;
begin
  Invert := Op = toNeq;

  if Op = toIn then
  begin
    EmitI('CALL24 __setmember');
    EmitClear(34);
    EmitI('PUSH   D0, XY3');
  end
  else
  begin
    case Op of
      toAdd: EmitI('CALL24 __setadd');
      toSub: EmitI('CALL24 __setsub');
      toMul: EmitI('CALL24 __setmul');
      toEq, toNeq: EmitI('CALL24 __seteq');
      toLeq: EmitI('CALL24 __setleq');
      toGeq: EmitI('CALL24 __setgeq');
    end;

    if Op in [toAdd, toSub, toMul] then
      EmitClear(32)
    else
    begin
      EmitClear(64);
      EmitI('PUSH   D0, XY3');
    end;

    if Invert then EmitUnOp(toNot, dtBoolean);
  end;
end;

(* ---- Float operators (stub) ---- *)
procedure EmitFloatOp(Op: TToken);
var
  Invert: Boolean;
begin
  Invert := (Op = toNeq) or (Op = toGt) or (Op = toGeq);

  EmitI('POP    D1, XY3');
  EmitI('POP    D0, XY3');

  case Op of
    toAdd: EmitI('CALL24 __fpadd');
    toSub: EmitI('CALL24 __fpsub');
    toMul: EmitI('CALL24 __fpmul');
    toDiv: EmitI('CALL24 __fpdiv');
    toMod: EmitI('CALL24 __fpmod');
    toEq, toNeq: EmitI('CALL24 __flteq');
    toLt, toGeq: EmitI('CALL24 __fltlt');
    toGt, toLeq: EmitI('CALL24 __fltleq');
  end;

  if Op in [toAdd, toSub, toMul, toDiv, toMod] then
    EmitI('PUSH   D0, XY3')
  else
    EmitI('PUSH   D0, XY3');

  if Invert then EmitUnOp(toNot, dtBoolean);
end;

(* ---- Unconditional jump ---- *)
procedure EmitJump(Target: String);
begin
  EmitI('JMP    ' + Target);
end;

(* ---- Conditional jump ---- *)
(*
 * Pops TOS; jumps to Target if value is non-zero (When=True) or
 * zero (When=False).
 *)
procedure EmitJumpIf(When: Boolean; Target: String);
begin
  EmitI('POP    D0, XY3');
  EmitI('CMP    D0, #0');
  if When then
    EmitI('BNE.L  ' + Target)
  else
    EmitI('BEQ.L  ' + Target);
end;

(* ---- Integer / boolean binary operators ---- *)
(*
 * Stack on entry: ... left right  (right on top)
 * Result replaces both operands.
 *)
(* Part 24: is V a power of two in 2..32768?  Used only for unsigned div/mod
 * folding, so 1 is excluded (handled separately) and 0 cannot fold. *)
function Pow2Log(V: Integer): Integer;
var
  N, S: Integer;
begin
  Pow2Log := -1;
  if V < 2 then Exit;
  N := V; S := 0;
  while (N and 1) = 0 do begin N := N shr 1; Inc(S); end;
  if N = 1 then Pow2Log := S;
end;

procedure EmitBinOp(Op: TToken; DataType: PSymbol);
var
  RK, Uns: Boolean; RV, AbsRV, Shifts: Integer;
begin
  RK := LastLiteralKnown; RV := LastLiteralValue;
  LastLiteralKnown := False;
  Uns := IsUnsignedType(DataType);

  Emit('', 'POP    D1, XY3', '');
  Emit('', 'POP    D0, XY3', '');

  case Op of
    toAdd:
      if RK then Emit('', 'ADD    D0, #' + IntToStr(RV), '')
      else EmitI('ADD    D0, D1');

    toSub:
      if RK then Emit('', 'SUB    D0, #' + IntToStr(RV), '')
      else EmitI('SUB    D0, D1');

    toMul:
      begin
        if RK and (RV > 0) then
        begin
          AbsRV := RV; Shifts := 0;
          while (AbsRV > 1) and ((AbsRV and 1) = 0) do
          begin AbsRV := AbsRV shr 1; Inc(Shifts); end;
          if AbsRV = 1 then
          begin
            { pure power of 2 }
            while Shifts > 0 do begin EmitI('ADD    D0, D0'); Dec(Shifts); end;
          end
          else if AbsRV = 3 then
          begin
            { x * 3 * 2^Shifts }
            while Shifts > 0 do begin EmitI('ADD    D0, D0'); Dec(Shifts); end;
            EmitI('MOVE   D1, D0'); EmitI('ADD    D0, D0'); EmitI('ADD    D0, D1');
          end
          else if AbsRV = 5 then
          begin
            { x * 5 * 2^Shifts }
            while Shifts > 0 do begin EmitI('ADD    D0, D0'); Dec(Shifts); end;
            EmitI('MOVE   D1, D0'); EmitI('ADD    D0, D0'); EmitI('ADD    D0, D0'); EmitI('ADD    D0, D1');
          end
          else EmitI('CALL24 __mul16');
        end
        else EmitI('CALL24 __mul16');
      end;

    (* Part 24.  Power-of-two folding is legal for Word and NOT for Integer:
     * signed div truncates toward zero, an arithmetic shift rounds toward
     * -infinity, and they disagree for every negative dividend (Part 23
     * s2.4).  Unsigned they are exact.  This pays constantly in a Z-machine,
     * where addr div 2 and addr mod 2 are on nearly every line. *)
    toDivKw:
      if Uns then
      begin
        if RK and (RV = 1) then
          EmitC('div by 1: no code')
        else if RK and (Pow2Log(RV) > 0) then
          Emit('', 'SHR    D0, #' + IntToStr(Pow2Log(RV)),
               'unsigned div ' + IntToStr(RV))
        else
          EmitI('CALL24 __udiv16');
      end
      else
        EmitI('CALL24 __sdiv16');

    toMod:
      if Uns then
      begin
        if RK and (RV = 1) then
          Emit('', 'LOADI  D0, #0', 'mod 1 is always 0')
        else if RK and (Pow2Log(RV) > 0) then
          Emit('', 'AND    D0, #' + IntToStr(RV - 1),
               'unsigned mod ' + IntToStr(RV))
        else
        begin
          EmitI('CALL24 __udiv16');
          EmitI('MOVE   D0, D1');
        end;
      end
      else
      begin
        { __sdiv16 -> KLIB_DIVMOD16 is a SIGNED divmod: it already returns the
          remainder with the dividend's sign, which is what Pascal wants.
          This used to negate it again when the dividend was negative -- a
          double correction, so (-7) mod 2 came out +1 instead of -1. The
          quotient path (toDivKw) never had the extra step, which is why
          (-7) div 2 was correct all along. }
        EmitI('CALL24 __sdiv16');
        EmitI('MOVE   D0, D1');
      end;

    toAnd:
      if RK then Emit('', 'AND    D0, #' + IntToStr(RV), '')
      else EmitI('AND    D0, D1');

    toOr:
      if RK then Emit('', 'OR     D0, #' + IntToStr(RV), '')
      else EmitI('OR     D0, D1');

    toXor:
      if RK then Emit('', 'XOR    D0, #' + IntToStr(RV), '')
      else EmitI('XOR    D0, D1');

    { Part 23 (5.5): constant shift counts go to the assembler's multi-bit
      shift pseudo-instruction rather than the runtime loop.

          v shr 3    was: LOADI 2 + CALL16 11 + 3 x loop 16 + tail 7 + RET 6
                          = 74 cycles
                     now: SHR D0, #3  ->  SHR / SHR / SHR   = 9 cycles
          v shr 9    was: ~110 cycles
                     now: SHR D0, #9  ->  HIGH / SHR        = 6 cycles

      The decomposition is deliberately NOT done here. Reference Manual
      s6.15.3/6.15.4 gives the assembler a per-count table that draws on
      SHL4/SHR4, and on LOW/SWAPB (left) and HIGH (right) for counts of 8
      and over -- shortcuts a hand-rolled "N div 4 lots of SHR4 plus the
      remainder" would miss entirely. Emitting the pseudo gets the whole
      table for free and stays correct if the table is ever improved.

      Pascal's shr/shl are logical on both signed and unsigned operands
      (Delphi semantics), so this is SHR, never ASR. ASR would be the wrong
      instruction here even though the operand type is signed -- and note
      that x div 2 is NOT x shr 1 for negative x: div truncates toward zero,
      arithmetic shift rounds toward -infinity. div/mod are left alone for
      exactly that reason.

      Count handling follows s6.15.8's diagnostics so the assembler stays
      quiet: 0 emits nothing (the pseudo would warn), 16 and over is a
      constant zero (ditto), and a negative count keeps the runtime call
      rather than tripping the "negative shift count" error -- preserving
      whatever the loop did before, which is not this change's business.

      Flag-transparent: s6.15.9 confirms the expansions use only LOOKUP-class
      instructions, which preserve all flags via FLAGSX. }
    toShl, toShr:
      if EnableConstShift and RK and (RV >= 0) then
      begin
        if RV = 0 then
          { no code -- value already correct }
        else if RV >= 16 then
          Emit('', 'LOADI  D0, #0', 'shift >= 16 -> zero')
        else if Op = toShl then
          Emit('', 'SHL    D0, #' + IntToStr(RV), '')
        else
          Emit('', 'SHR    D0, #' + IntToStr(RV), '');
      end
      else if Op = toShl then
        EmitI('CALL24 __shl16')
      else
        EmitI('CALL24 __shr16');
  end;

  Emit('', 'PUSH   D0, XY3', '');
end;

(* ---- Integer / boolean unary operators ---- *)
procedure EmitUnOp(Op: TToken; DataType: PSymbol);
begin
  case Op of
    toNot:
      begin
        Emit('', 'POP    D0, XY3', 'Not');
        if DataType = dtBoolean then
          EmitI('XOR    D0, #1')         { flip bit 0: 0->1, 1->0 }
        else
          EmitI('XOR    D0, #$FFFF');    { bitwise complement }
        EmitI('PUSH   D0, XY3');
      end;
  end;
end;

(* ---- Negation ---- *)
procedure EmitNeg(DataType: PSymbol);
begin
  { Part 24: Word included -- negation is 0 - x in two's complement and the
    instructions are identical; only the reading of the result differs. }
  if (DataType = dtInteger) or (DataType = dtByte) or (DataType = dtWord) then
  begin
    Emit('', 'POP    D1, XY3', 'Neg');
    EmitI('LOADI  D0, #0');
    EmitI('SUB    D0, D1');
    EmitI('PUSH   D0, XY3');
  end
  else if DataType = dtReal then
  begin
    EmitI('POP    D0, XY3');
    EmitI('CALL24 __fpneg');            { TODO: floating point }
    EmitI('PUSH   D0, XY3');
  end
  else Error('Invalid type ' + DataType^.Name);
end;

(* ---- Increment / decrement in place ---- *)
(*
 * TOS holds the address of the variable to modify.
 *)
procedure EmitInc(DataType: PSymbol);
begin
  (* Part 24: size-driven, not `DataType = dtInteger` -- see EmitDec. *)
  while DataType^.Kind = scSubrangeType do DataType := DataType^.DataType;
  Emit('', 'POP    D0, XY3', 'Inc address');
  EmitI('MOVE   X0, D0');
  EmitI('LOADI  Y0, #$00');
  if DataType^.Value >= 2 then
  begin
    EmitI('LOADD  D1, [XY0]');
    EmitI('ADD    D1, #1');
    EmitI('STORED D1, [XY0]');
  end
  else
  begin
    EmitI('LOADB  D1, [XY0]');
    EmitI('ADD    D1, #1');
    EmitI('STOREB D1, [XY0]');
  end;
end;

procedure EmitDec(DataType: PSymbol);
begin
  (* Part 24: was `DataType = dtInteger`, which sent a Word down the BYTE
   * path -- a silent wrong answer, not a compile error.  Size-driven is both
   * the fix and the more honest test: what decides LOADD vs LOADB is how
   * wide the slot is, never which named type occupies it. *)
  while DataType^.Kind = scSubrangeType do DataType := DataType^.DataType;
  Emit('', 'POP    D0, XY3', 'Dec address');
  EmitI('MOVE   X0, D0');
  EmitI('LOADI  Y0, #$00');
  if DataType^.Value >= 2 then
  begin
    EmitI('LOADD  D1, [XY0]');
    EmitI('SUB    D1, #1');
    EmitI('STORED D1, [XY0]');
  end
  else
  begin
    EmitI('LOADB  D1, [XY0]');
    EmitI('SUB    D1, #1');
    EmitI('STOREB D1, [XY0]');
  end;
end;

(* ---- Shift left by one (used for array index scaling) ---- *)
procedure EmitShl;
begin
  Emit('', 'POP    D0, XY3', 'Shl1');
  EmitI('ADD    D0, D0');
  EmitI('PUSH   D0, XY3');
end;

(* ---- Str() built-in (stub) ---- *)
procedure EmitStr(DataType, VarType: PSymbol);
begin
  while DataType^.Kind = scSubrangeType do DataType := DataType^.DataType;

  Emit('', 'LOADI  D2, #' + IntToStr(VarType^.Value - 1), 'Str maxlen');

  (* Part 24: this path serves both Str(w, s) and Write(TextFile, w). *)
  if DataType = dtWord then
  begin
    EmitI('POP    D0, XY3');    { D0 = dest addr (top of stack) }
    EmitI('POP    D1, XY3');    { D1 = value }
    EmitI('CALL24 __strnu');
  end
  else if (DataType = dtInteger) or (DataType = dtByte) then
  begin
    EmitI('POP    D0, XY3');    { D0 = dest addr (top of stack) }
    EmitI('POP    D1, XY3');    { D1 = value }
    EmitI('CALL24 __strn');
  end
  else if DataType = dtChar then
  begin
    EmitI('POP    D0, XY3');    { D0 = dest addr }
    EmitI('POP    D1, XY3');    { D1 = char value }
    EmitI('CALL24 __strc');
  end
  else if DataType^.Kind = scStringType then
  begin
    EmitI('POP    D1, XY3');
    EmitI('CALL24 __strs');
  end
  else Error('Unprintable type: ' + DataType^.Name);
end;

procedure EmitStr1(DataType, VarType: PSymbol);
begin
  while DataType^.Kind = scSubrangeType do DataType := DataType^.DataType;

  Emit('', 'LOADI  D2, #' + IntToStr(VarType^.Value - 1), 'Str1 maxlen');

  if (DataType = dtInteger) or (DataType = dtByte) then
  begin
    EmitI('POP    D0, XY3');    { D0 = dest addr }
    EmitI('POP    D1, XY3');    { D1 = value }
    EmitI('CALL24 __strn1');
  end
  else if DataType = dtChar then
  begin
    EmitI('POP    D0, XY3');    { D0 = dest addr }
    EmitI('POP    D1, XY3');    { D1 = char value }
    EmitI('CALL24 __strc1');
  end
  else Error('Unprintable type (1 fmt): ' + DataType^.Name);
end;

procedure EmitStr2(DataType, VarType: PSymbol);
begin
  if DataType <> dtReal then
    Error('Str2 only for Real: ' + DataType^.Name);

  Emit('', 'LOADI  D2, #' + IntToStr(VarType^.Value - 1), 'Str2 maxlen');
  EmitI('POP    D1, XY3');
  EmitI('POP    D0, XY3');
  EmitI('CALL24 __strf2');
end;

(* ---- Write / WriteLn output ---- *)
(*
 * TOS holds the value to write (or the string address for strings).
 * All terminal I/O goes to $D00000 via runtime calls.
 *)
procedure EmitWrite(DataType: PSymbol);
begin
  while DataType^.Kind = scSubrangeType do DataType := DataType^.DataType;

  (* Part 24.  Without this arm Write(w) prints 40000 as -25536: the value is
     right, the reading of it is not.  Exactly the failure Part 23 s5.1 warns
     about -- every integer assertion would still pass. *)
  if DataType = dtWord then
  begin
    Emit('', 'POP    D0, XY3', 'Write word (unsigned)');
    EmitI('CALL24 __putu');
  end
  else if (DataType = dtInteger) or (DataType = dtByte) then
  begin
    Emit('', 'POP    D0, XY3', 'Write integer');
    EmitI('CALL24 __putn');
  end
  else if DataType = dtChar then
  begin
    Emit('', 'POP    D0, XY3', 'Write char');
    EmitI('CALL24 __putc');
  end
  else if DataType^.Kind = scStringType then
  begin
    EmitI('POP    D0, XY3');
    EmitI('CALL24 __puts');
    { Phase 6: free any stack-allocated string temp that held this value }
    while StringTempDepth > 0 do EmitFreeStringTemp;
  end
  else if DataType = dtReal then
  begin
    EmitI('POP    D0, XY3');
    EmitI('CALL24 __putf');             { TODO: floating point }
  end
  else if DataType^.Kind = scEnumType then
  begin
    Emit('', 'POP    D0, XY3', 'Write enum');
    Emit('', 'LOADI  D1, #' + DataType^.Tag, '');
    EmitI('CALL24 __pute');
  end
  else Error('Unprintable type: ' + DataType^.Name);
end;

procedure EmitWrite1(DataType: PSymbol);
begin
  while DataType^.Kind = scSubrangeType do DataType := DataType^.DataType;

  EmitI('POP    D2, XY3');                   { format width }

  if DataType = dtWord then
  begin
    Emit('', 'POP    D0, XY3', 'Write1 word (unsigned)');
    EmitI('CALL24 __putu_fmt');
  end
  else if (DataType = dtInteger) or (DataType = dtByte) then
  begin
    Emit('', 'POP    D0, XY3', 'Write1 integer');
    EmitI('CALL24 __putn_fmt');
  end
  else if DataType = dtChar then
  begin
    Emit('', 'POP    D0, XY3', 'Write1 char');
    EmitI('CALL24 __putc_fmt');
  end
  else if DataType^.Kind = scStringType then
  begin
    EmitI('POP    D0, XY3');
    EmitI('CALL24 __puts_fmt');
    while StringTempDepth > 0 do EmitFreeStringTemp;
  end
  else Error('Unprintable type (fmt1): ' + DataType^.Name);
end;

procedure EmitWrite2(DataType: PSymbol);
begin
  if DataType <> dtReal then
    Error('Write2 only for Real: ' + DataType^.Name);

  EmitI('POP    D2, XY3');                   { fraction digits }
  EmitI('POP    D1, XY3');                   { field width }
  EmitI('POP    D0, XY3');                   { value }
  EmitI('CALL24 __putf_fix');
end;

(* ---- Close output file ---- *)
procedure CloseTarget();
begin
  Flush;
  Close(Target);
end;

(* ---- Allocate / free a 256-byte string temporary on the Pascal stack ---- *)
(*
 * Phase 6: string temporaries live on the stack, not in global rotating buffers.
 * EmitAllocStringTemp: allocates 256 bytes, leaves address in D0.
 *   Does NOT push the address -- caller does that.
 *   Increments StringTempDepth.
 * EmitFreeStringTemp:  frees the 256 bytes previously allocated.
 *   Decrements StringTempDepth.
 *)
procedure EmitAllocStringTemp;
var
  N: Integer;
begin
  if InArgContext then
  begin
    (* Part 20: a per-invocation frame block, not a static pool slot.
     *
     * These were static because a mid-expression SUB X3,#256 would punch a
     * hole in the argument block being built on the stack. A frame block has
     * no mid-expression SUB -- the space is reserved once in the prologue --
     * so that objection does not apply, exactly as for the concat dest.
     *
     * Static was wrong here. ArgLive.pas: in a self-recursive routine whose
     * call takes several arguments, an earlier argument's buffer is PUSHed
     * and stays live while a later argument recurses, and the child writes
     * the same address. RevC('abc') returned 'bba' for 'cba'. The three
     * reasons the other static buffers survive recursion all fail for this
     * one -- it is not consumed into a frame dest, Phase 1b(A)'s param copy
     * does not reach it until the consuming call is entered, and it is read
     * after return rather than written at return.
     *
     * Reuse matches the static slots this replaced: FrameDestCur is reset
     * per statement (ParseStatementList), so a routine reserves its PEAK
     * rather than the sum.
     *
     * The emitted SUB sets flags where the old LOADI did not. Safe because
     * every one of these buffers exists to hand a dest to an immediately
     * following CALL -- verified across the suite, 785 emissions, none
     * reaching a conditional branch before a CALL. *)
    N := AllocFrameBlock;
    EmitConcatDestAddr(N, 'str arg buf ' + IntToStr(N) + ' (frame)');
  end
  else
  begin
    EmitI('SUB    X3, #256');
    EmitI('MOVE   D0, X3');
    Inc(StringTempDepth);
    if StringTempDepth > StackTempPeak then StackTempPeak := StringTempDepth;
  end;
end;

procedure EmitFreeStringTemp;
begin
  EmitI('ADD    X3, #256');          { free 256-byte string temp }
  Dec(StringTempDepth);
end;

(* ---- Part 17: persistent static destination for one concat chain ---- *)
(*
 * Concat now accumulates into ONE static buffer, appending each operand
 * (see K16Pascal_parser.inc / _builtins.inc). Uses the arg-slot static pool
 * (peak-tracked, reset per procedure). Address left in ConcatDestAddr.
 * Not reclaimed mid-procedure; peak cost = concat chains live per procedure.
 *)
procedure EmitAllocConcatDest;
begin
  { Part 19 item 5: a per-invocation 256-byte block in this routine's frame,
    no longer a slot in the shared static pool. This is what makes recursion
    through a concat chain safe. Part 20 moved the reservation itself into
    AllocFrameBlock, shared with the string argument buffers. }
  ConcatDestAddr := AllocFrameBlock;

  { Part 18 Phase 1a: the chain is now accumulating. Any call emitted while this
    is non-zero happens with a static buffer the caller still needs afterwards,
    which is only safe if the callee cannot re-enter us. Chains nest (a
    parenthesised operand re-enters), hence a counter and not a flag. }
  Inc(ConcatDestOpen);
end;

(* Part 18 Phase 1a: paired with EmitAllocConcatDest, called once the chain's
   result has been pushed and the buffer is no longer read. *)
procedure EmitCloseConcatDest;
begin
  { Part 19 item 7.4: this used to be 'if ConcatDestOpen > 0 then Dec(...)',
    silently absorbing an unbalanced close. But Phase 1a's rejection of
    recursion-through-a-static-string-buffer is only sound if the counter is
    exactly balanced -- an absorbed close would under-count, EmitCall would
    stop tagging edges risky, and a genuinely unsafe recursion would compile
    clean. Fail loudly instead. }
  if ConcatDestOpen <= 0 then
    Error('internal: EmitCloseConcatDest with no open concat dest');
  Dec(ConcatDestOpen);
end;

(* ---- Char to string promotion ---- *)
(*
 * Phase 6: allocate a 256-byte stack temp, call __char2str(dest, char).
 * TOS after = dest addr (the temp buffer holding the 1-char string).
 *)
procedure EmitCharToString;
begin
  EmitI('POP    D1, XY3');           { D1 = char }
  EmitAllocStringTemp;               { SUB X3,#256; D0=dest; StringTempDepth++ }
  EmitI('CALL24 __char2str');        { __char2str(dest=D0, char=D1) }
  EmitI('PUSH   D0, XY3');           { push dest addr as string value }
end;

(* ---- Read / ReadLn console input ---- *)
(*
 * Reads a value from the keyboard ($C00000) via runtime call.
 * Result pushed on stack.
 *)
procedure EmitReadConsole(T: PSymbol);
begin
  if T = dtInteger then
    EmitI('CALL24 __getn')
  else if T = dtChar then
    EmitI('CALL24 __getc')
  else if T = dtReal then
    EmitI('CALL24 __getr')              { TODO: floating point }
  else if T^.Kind = scEnumType then
  begin
    Emit('', 'LOADI  D1, #' + T^.Tag, '');
    EmitI('CALL24 __gete');
  end
  else if T^.Kind = scStringType then
  begin
    Emit('', 'LOADI  D2, #' + IntToStr(T^.Value - 1), 'Max string len');
    EmitI('CALL24 __gets');
  end
  else Error('Unreadable type');
end;

(* ---- New() store-back (Issue 2: Phase 8) ---- *)
(*
 * Called by ParseBuiltInProcedure after CALL24 __getmem.
 * D0 = allocated address. TOS = address of the pointer variable (var param).
 * Pops the pointer variable address, stores D0 into it.
 *)
procedure EmitNewStoreBack;
begin
  EmitI('POP    D1, XY3');    { D1 = address of pointer variable }
  EmitI('MOVE   X1, D1');
  EmitI('LOADI  Y1, #$00');
  EmitI('STORED D0, [XY1]');  { *ptrvar = allocated address }
end;
