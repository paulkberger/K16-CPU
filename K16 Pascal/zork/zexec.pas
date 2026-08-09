{ ---------------------------------------------------------------------------
  zexec.pas -- Z-machine v3 execution                 K16 Pascal, Part 26 / 27

  Include AFTER zmem, ztext, zobj, zdict, zdis, zstate and zsave.

  The decoder is zdis.pas and is already verified against ztools' txd over
  20,968 instructions in Zork I, II and III. This module is the half that
  runs them: variables, frames, branches and the opcode bodies.

  ---- Where the stack and the frames went ----------------------------------

  Into zstate.pas, unchanged, in Part 27. zsave needs them and zexec calls
  zsave, so in a single-pass compiler the declarations have to precede both.
  Nothing about their meaning changed; ZFArgs was added alongside them.

  ---- The cursor IS the PC -------------------------------------------------

  Carried over from zdis: the memory cursor is the program counter, so a
  branch target is `where the cursor is now, plus offset, minus 2'. Only
  call, return and branch ever move it explicitly. ZPCRel does the page
  carry, which is the one piece of arithmetic here that must handle the
  story's second page.

  ---- Indirect variable references -----------------------------------------

  store, inc, dec, inc_chk, dec_chk, load and pull take a variable NUMBER as
  their first operand and act on that variable IN PLACE. For variable 0 that
  means the top of the stack is read or written WITHOUT being popped or
  pushed (Standard 1.1 s6.3.4). Using the ordinary variable path for these
  silently corrupts the stack, and the symptom appears in some unrelated
  routine much later -- ZVarGetInd / ZVarSetInd exist for exactly this.

  ---- Signedness -----------------------------------------------------------

  Z-machine values are 16-bit SIGNED where it matters: jl, jg, add, sub, mul,
  div, mod, inc_chk, dec_chk, print_num and jump's offset. Word is unsigned
  here, so the comparisons go through ZLT (a bias-by-$8000 trick) and the
  divides through sign-magnitude. Getting this wrong makes a room's object
  count of -1 compare as 65535 and the game wanders.
  --------------------------------------------------------------------------- }

var
  ZOp      : array[0..ZD_OPTOP] of Word;  { evaluated operand values }

  ZQuit    : Boolean;
  ZFault   : Boolean;
  ZRndSeed : Word;

  ZInBuf   : String;                      { one input line }
  ZTmpS    : String;                      { shared scratch: a String LOCAL
                                            costs a 256-byte frame block at
                                            every call site (Part 24 s5.2) }
  ZPCSOfs  : Word;                        { PC save slot -- see ZPCSave }
  ZPCSPage : Word;
  ZDisc    : Word;                        { sink for results that must be
                                            consumed but not used }

  { Instruction trace. zdistest verified the decoder's BOUNDARIES and opcode
    classification, but never its operand VALUES -- it printed only address,
    class and opcode number. A bad operand fetch passes that test silently,
    so the trace prints the evaluated operands too and is diffed against the
    same trace produced by a host-side model. Zork I reaches its first sread
    in 407 instructions, so a couple of hundred lines localise anything in
    the startup path. }
  ZTraceMax : Word;                       { 0 = off }
  ZTraceN   : Word;

{ ---- Faults -------------------------------------------------------------- }

{ Loud, not silent. A Z-machine that keeps going after a stack overflow
  produces output that looks almost right, which is far worse to diagnose
  than a stop. }
procedure ZDie(var msg: String);
begin
  ZOutNewLine;
  Write('[z-machine fault: ');
  Write(msg);
  WriteLn(']');
  ZFault := True;
  ZQuit  := True;
end;

{ ---- Stack --------------------------------------------------------------- }

procedure ZPush(v: Word);
var m: String;
begin
  if ZSP > ZS_TOP then
  begin
    ZTmpS := 'stack overflow';
    ZDie(ZTmpS);
    Exit;
  end;
  ZStack[ZSP] := v;
  ZSP := ZSP + 1;
end;

function ZPop: Word;
var m: String;
begin
  ZPop := 0;
  if ZSP = 0 then
  begin
    ZTmpS := 'stack underflow';
    ZDie(ZTmpS);
    Exit;
  end;
  ZSP := ZSP - 1;
  ZPop := ZStack[ZSP];
end;

{ ---- Variables -----------------------------------------------------------

  0 = stack, 1..15 = local, 16..255 = global.

  EVERY local index goes through ZLIdx and lands in a plain variable before
  it is used. This is not style. It works around a compiler bug found here
  in Part 26 and FIXED in the same part -- kept because it costs nothing and
  the reasoning is worth preserving.

  The trigger was a PROCEDURE PARAMETER used as an array index on the left
  of `:=', compound or not. `A[v] := 1234' was enough:

      A[v] := 1234        <-- assigned 1234 to v
      idx := v;
      A[idx] := 1234;     <-- correct

  It did not fail to store. It stored into the PARAMETER'S OWN FRAME SLOT.
  EmitAddress set DestIsXY2 on the first frame access while parsing the LHS
  -- for a subscripted destination that is the INDEX -- so EmitStore took
  its [XY2+#N] fast path with the index's offset. The element address was
  computed correctly in D0 and thrown away.

  READS through the identical index were fine, which is what made it so slow
  to find: locals returned their header initial values forever while every
  write vanished, and Zork's serial-number loop span with its output
  swallowed by the wrap buffer. `base + i' stored correctly because both are
  var-section locals, which this compiler allocates statically and addresses
  by page, not by frame -- so ZDoCall worked and the fault looked like a read
  problem somewhere else entirely.

  Reduced in bug.pas / zvartest.pas / zidxtest2.pas; fixed by DestXY2Mark in
  K16Pascal_codegen.inc plus the validation in ParseAssignment.
  --------------------------------------------------------------------------- }

{ Flat index of local n (1..15) in the current frame.

  An add, not a multiply -- see ZFBase in zstate.pas. Kept as a function for
  the indirect forms below, which are rare; the two hot accessors inline it,
  because on this path a CALL16/RET costs more than the arithmetic does. }
function ZLIdx(v: Word): Word;
var
  idx: Word;
begin
  idx := ZFBase + (v - 1);
  ZLIdx := idx;
end;

function ZVarGet(v: Word): Word;
begin
  if v = 0 then ZVarGet := ZPop
  else if v < 16 then ZVarGet := ZLocals[ZFBase + (v - 1)]
  else ZVarGet := ZGlobal(v - 16);
end;

procedure ZVarSet(v, x: Word);
var
  idx: Word;
begin
  if v = 0 then ZPush(x)
  else if v < 16 then
  begin
    idx := ZFBase + (v - 1);
    ZLocals[idx] := x;
  end
  else ZSetGlobal(v - 16, x);
end;

{ Indirect forms: variable 0 is the TOP OF STACK IN PLACE. }
function ZVarGetInd(v: Word): Word;
var
  top: Word;
begin
  if v = 0 then
  begin
    if ZSP = 0 then ZVarGetInd := 0
    else
    begin
      top := ZSP - 1;
      ZVarGetInd := ZStack[top];
    end;
  end
  else if v < 16 then ZVarGetInd := ZLocals[ZLIdx(v)]
  else ZVarGetInd := ZGlobal(v - 16);
end;

procedure ZVarSetInd(v, x: Word);
var
  idx, top: Word;
begin
  if v = 0 then
  begin
    if ZSP = 0 then ZPush(x)
    else
    begin
      top := ZSP - 1;
      ZStack[top] := x;
    end;
  end
  else if v < 16 then
  begin
    idx := ZLIdx(v);
    ZLocals[idx] := x;
  end
  else ZSetGlobal(v - 16, x);
end;

{ ---- Signed helpers ------------------------------------------------------ }

{ Signed less-than by biasing both operands into unsigned order. }
function ZLT(a, b: Word): Boolean;
begin
  ZLT := (a xor $8000) < (b xor $8000);
end;

function ZNeg(a: Word): Word;
begin
  ZNeg := (not a) + 1;
end;

function ZDivS(a, b: Word): Word;
var
  na, nb, q: Word;
  neg: Boolean;
begin
  ZDivS := 0;
  if b = 0 then
  begin
    ZTmpS := 'division by zero';
    ZDie(ZTmpS);
    Exit;
  end;
  neg := False;
  na := a;  nb := b;
  if (na and $8000) <> 0 then begin na := ZNeg(na); neg := not neg; end;
  if (nb and $8000) <> 0 then begin nb := ZNeg(nb); neg := not neg; end;
  q := na div nb;
  if neg then q := ZNeg(q);
  ZDivS := q;
end;

{ Remainder takes the sign of the DIVIDEND, as in Pascal and as the Standard
  requires -- not the floored convention some languages use. }
function ZModS(a, b: Word): Word;
var
  na, nb, r: Word;
  neg: Boolean;
begin
  ZModS := 0;
  if b = 0 then
  begin
    ZTmpS := 'division by zero';
    ZDie(ZTmpS);
    Exit;
  end;
  neg := (a and $8000) <> 0;
  na := a;  nb := b;
  if neg then na := ZNeg(na);
  if (nb and $8000) <> 0 then nb := ZNeg(nb);
  r := na mod nb;
  if neg then r := ZNeg(r);
  ZModS := r;
end;

{ xorshift-16. Never returns to zero, which a plain LCG on 16 bits can. }
function ZRand(r: Word): Word;
begin
  if ZRndSeed = 0 then ZRndSeed := $A5C3;
  ZRndSeed := ZRndSeed xor ((ZRndSeed shl 7) and $FFFF);
  ZRndSeed := ZRndSeed xor (ZRndSeed shr 9);
  ZRndSeed := ZRndSeed xor ((ZRndSeed shl 8) and $FFFF);
  if r = 0 then ZRand := 0
  else ZRand := (ZRndSeed mod r) + 1;
end;

{ ---- PC ------------------------------------------------------------------ }

{ Move the cursor by a SIGNED delta, carrying the page. This is the only
  place in the engine that has to know the story spans two pages. }
procedure ZPCRel(delta: Word);
var
  ofs, pg, nofs: Word;
begin
  ofs  := MemTellOfs;
  pg   := MemTellPage;
  nofs := (ofs + delta) and $FFFF;
  if (delta and $8000) <> 0 then
  begin
    if nofs > ofs then pg := pg - 1;        { borrowed }
  end
  else
  begin
    if nofs < ofs then pg := pg + 1;        { carried }
  end;
  MemSeek(nofs, pg);
end;

{ Anything that SEEKS moves the program counter, because the cursor is the
  PC. print_obj, print_addr, print_paddr and the status line all decode a
  string somewhere else in memory and must put the cursor back afterwards or
  execution resumes inside the text they just printed.

  Not reentrant, and does not need to be: every user is a leaf. }
procedure ZPCSave;
begin
  ZPCSOfs  := MemTellOfs;
  ZPCSPage := MemTellPage;
end;

procedure ZPCRestore;
begin
  MemSeek(ZPCSOfs, ZPCSPage);
end;

{ ---- Frames -------------------------------------------------------------- }

procedure ZDoReturn(v: Word);
var
  rv: Word;
begin
  if ZFP = 0 then
  begin
    ZTmpS := 'return from the main routine';
    ZDie(ZTmpS);
    Exit;
  end;
  ZSP := ZFFloor[ZFP];                      { discard anything left behind }
  rv  := ZFRetVar[ZFP];
  MemSeek(ZFPCOfs[ZFP], ZFPCPage[ZFP]);
  ZFP := ZFP - 1;
  ZFBase := ZFBase - ZL_COUNT;              { before ZVarSet: the result goes
                                              into the CALLER's frame }
  if rv <> ZRETVAR_NONE then ZVarSet(rv, v);
end;

{ CALL. paddr is a PACKED routine address; a packed address of 0 is defined
  to do nothing and store false, which games use as a null callback. }
procedure ZDoCall(paddr, nargs, retvar: Word);
var
  n, i, base: Word;
begin
  if paddr = 0 then
  begin
    if retvar <> ZRETVAR_NONE then ZVarSet(retvar, 0);
    Exit;
  end;

  if ZFP >= ZF_TOP then
  begin
    ZTmpS := 'call frames exhausted';
    ZDie(ZTmpS);
    Exit;
  end;

  ZFP := ZFP + 1;
  ZFBase := ZFBase + ZL_COUNT;              { must track ZFP -- see zstate }
  ZFPCOfs[ZFP]  := MemTellOfs;              { cursor is past the call already }
  ZFPCPage[ZFP] := MemTellPage;
  ZFFloor[ZFP]  := ZSP;
  ZFRetVar[ZFP] := retvar;
  ZFArgs[ZFP]   := nargs;                   { for `save' only -- see zstate }

  ZSeekPacked(paddr);
  n := MemNextByte;
  if n > ZL_COUNT then n := ZL_COUNT;       { malformed; clamp rather than
                                              scribble past the frame }
  ZFNLoc[ZFP] := n;
  base := ZFBase;

  { v3 stores each local's INITIAL VALUE as a word after the count. v5
    dropped them; reading them on a v5 story decodes the first instruction
    as data. }
  i := 0;
  while i < n do
  begin
    ZLocals[base + i] := MemNextWordBE;
    i := i + 1;
  end;

  { Arguments overwrite locals 1..nargs, left to right. Extra arguments are
    discarded; missing ones keep their initial values. }
  i := 0;
  while (i < nargs) and (i < n) do
  begin
    ZLocals[base + i] := ZOp[i + 1];   { `base + i' does store correctly }
    i := i + 1;
  end;
end;

{ ---- Branch -------------------------------------------------------------- }

{ Apply the decoded branch to a condition. }
procedure ZBranch(cond: Boolean);
begin
  if cond <> ZIBrOn then Exit;              { polarity did not match }
  if ZIBrWhat = ZBR_RFALSE then ZDoReturn(0)
  else if ZIBrWhat = ZBR_RTRUE then ZDoReturn(1)
  else ZPCRel(ZIBrOfs - 2);
end;

{ ---- Operand evaluation -------------------------------------------------- }

{ Constants stand for themselves; a variable operand is READ, which pops the
  stack when the number is 0. Correct for the indirect opcodes too: there the
  value read IS the variable number to act on. }
procedure ZEvalOperands;
var
  i: Word;
begin
  i := 0;
  while i < ZINOps do
  begin
    if ZIOpT[i] = ZOT_VAR then ZOp[i] := ZVarGet(ZIOpV[i])
    else ZOp[i] := ZIOpV[i];
    i := i + 1;
  end;
end;

{ ---- Input --------------------------------------------------------------- }

{ v3 status line: the game keeps the location object in global 0 and the
  score/turns in globals 1 and 2, and expects the interpreter to draw them.
  Drawn as a plain line rather than a reverse-video top row -- a split screen
  needs cursor addressing this build does not have yet, and the information
  is what matters. }
procedure ZStatusLine;
begin
  { Break the line only if there is something on it. Unconditionally
    emitting one left a blank line above the status bar every turn. }
  if (ZOutCol > 0) or (ZOutWLen > 0) then ZOutNewLine;
  ZPCSave;                                { ZObjName seeks: the PC must survive }
  ZObjName(ZGlobal(0), ZTmpS);
  ZPCRestore;
  Write('[ ');
  Write(ZTmpS);
  Write('   Score: ');
  Write(ZGlobal(1));
  Write('   Moves: ');
  Write(ZGlobal(2));
  WriteLn(' ]');
  ZOutCol := 0;
end;

{ sread. Lowercases as it stores: the dictionary is lowercase and the
  tokeniser does not fold case itself. }
procedure ZDoRead(taddr, paddr: Word);
var
  i, c, maxc: Word;
begin
  { Zork prints its OWN prompt immediately before sread -- which is also why
    it never issues show_status: a v3 game expects the INTERPRETER to draw
    the status line. On a real terminal that lands on a reserved top row and
    the ordering is invisible; inline it is not, and the result was the
    prompt stranded ABOVE the status bar with a second prompt below it.

    The game's '>' is still sitting unflushed in the wrap buffer at this
    point (nothing followed it), so it can simply be dropped and reissued
    after the status line. Tested for explicitly rather than clearing the
    buffer blind: any other pending text is real output and must survive. }
  if (ZOutWLen = 1) and (ZOutWord[1] = '>') then
  begin
    ZOutWLen := 0;
    ZOutWord[0] := Chr(0);
  end;

  ZStatusLine;
  ZOutFlushWord;
  Write('>');
  ReadLn(ZInBuf);

  maxc := ZByte(taddr);
  if maxc = 0 then maxc := 100;

  i := 1;
  while (i <= Length(ZInBuf)) and (i <= maxc) do
  begin
    c := Ord(ZInBuf[i]);
    if (c >= 65) and (c <= 90) then c := c + 32;
    ZPutByte(taddr + i, c);
    i := i + 1;
  end;
  ZPutByte(taddr + i, 0);

  ZOutCol := 0;
  ZDictTokenise(taddr, paddr);
end;

{ ---- Dispatch ------------------------------------------------------------

  Four case statements, one per operand count, rather than one flat table.
  There are no procedure pointers in this compiler, so a jump table is not
  available and a case is what it generates well.

  Opcodes Zork I never uses are still here where they are cheap. The ones
  left as no-ops are marked; each is a window/stream control that a v3 game
  may call and must not fault on.
  --------------------------------------------------------------------------- }

procedure ZExec2OP;
var
  i, a, b, p: Word;
  cond: Boolean;
begin
  case ZIOpcode of
    $01: begin                                        { je }
           { The VAR form takes up to four operands and branches if the
             first equals ANY of the rest. Handling only the two-operand
             case passes an enormous amount of code and then fails in the
             parser, which is where the multi-operand form lives. }
           cond := False;
           i := 1;
           while i < ZINOps do
           begin
             if ZOp[0] = ZOp[i] then cond := True;
             i := i + 1;
           end;
           ZBranch(cond);
         end;
    $02: ZBranch(ZLT(ZOp[0], ZOp[1]));                { jl  -- signed }
    $03: ZBranch(ZLT(ZOp[1], ZOp[0]));                { jg  -- signed }
    $04: begin                                        { dec_chk -- indirect }
           a := ZVarGetInd(ZOp[0]);
           a := (a - 1) and $FFFF;
           ZVarSetInd(ZOp[0], a);
           ZBranch(ZLT(a, ZOp[1]));
         end;
    $05: begin                                        { inc_chk -- indirect }
           a := ZVarGetInd(ZOp[0]);
           a := (a + 1) and $FFFF;
           ZVarSetInd(ZOp[0], a);
           ZBranch(ZLT(ZOp[1], a));
         end;
    $06: ZBranch(ZObjParent(ZOp[0]) = ZOp[1]);        { jin }
    $07: ZBranch((ZOp[0] and ZOp[1]) = ZOp[1]);       { test: ALL bits set }
    $08: ZVarSet(ZIStoreV, ZOp[0] or ZOp[1]);         { or }
    $09: ZVarSet(ZIStoreV, ZOp[0] and ZOp[1]);        { and }
    $0A: ZBranch(ZObjAttr(ZOp[0], ZOp[1]));           { test_attr }
    $0B: ZObjSetAttr(ZOp[0], ZOp[1]);                 { set_attr }
    $0C: ZObjClearAttr(ZOp[0], ZOp[1]);               { clear_attr }
    $0D: ZVarSetInd(ZOp[0], ZOp[1]);                  { store -- indirect }
    $0E: ZObjInsert(ZOp[0], ZOp[1]);                  { insert_obj }
    $0F: ZVarSet(ZIStoreV, ZWord(ZOp[0] + (ZOp[1] shl 1)));   { loadw }
    $10: ZVarSet(ZIStoreV, ZByte(ZOp[0] + ZOp[1]));           { loadb }
    $11: ZVarSet(ZIStoreV, ZObjGetProp(ZOp[0], ZOp[1]));      { get_prop }
    $12: begin                                        { get_prop_addr }
           { zobj returns the address of the SIZE BYTE; the Z-machine wants
             the address of the DATA, one further on. Zero stays zero. }
           p := ZObjPropAddr(ZOp[0], ZOp[1]);
           if p <> 0 then p := p + 1;
           ZVarSet(ZIStoreV, p);
         end;
    $13: ZVarSet(ZIStoreV, ZObjNextProp(ZOp[0], ZOp[1]));     { get_next_prop }
    $14: ZVarSet(ZIStoreV, (ZOp[0] + ZOp[1]) and $FFFF);      { add }
    $15: ZVarSet(ZIStoreV, (ZOp[0] - ZOp[1]) and $FFFF);      { sub }
    $16: ZVarSet(ZIStoreV, (ZOp[0] * ZOp[1]) and $FFFF);      { mul }
    $17: ZVarSet(ZIStoreV, ZDivS(ZOp[0], ZOp[1]));            { div -- signed }
    $18: ZVarSet(ZIStoreV, ZModS(ZOp[0], ZOp[1]));            { mod -- signed }
  else
    ZTmpS := 'unknown 2OP opcode';
    ZDie(ZTmpS);
  end;
end;

procedure ZExec1OP;
var
  a, p: Word;
begin
  case ZIOpcode of
    $00: ZBranch(ZOp[0] = 0);                         { jz }
    $01: begin                                        { get_sibling }
           a := ZObjSibling(ZOp[0]);                  { stores AND branches }
           ZVarSet(ZIStoreV, a);
           ZBranch(a <> 0);
         end;
    $02: begin                                        { get_child }
           a := ZObjChild(ZOp[0]);
           ZVarSet(ZIStoreV, a);
           ZBranch(a <> 0);
         end;
    $03: ZVarSet(ZIStoreV, ZObjParent(ZOp[0]));       { get_parent }
    $04: begin                                        { get_prop_len }
           { The operand is the address of the property DATA. zobj's
             ZObjPropLen takes the SIZE BYTE's address, one earlier. }
           if ZOp[0] = 0 then ZVarSet(ZIStoreV, 0)
           else ZVarSet(ZIStoreV, ZObjPropLen(ZOp[0] - 1));
         end;
    $05: ZVarSetInd(ZOp[0], (ZVarGetInd(ZOp[0]) + 1) and $FFFF);   { inc }
    $06: ZVarSetInd(ZOp[0], (ZVarGetInd(ZOp[0]) - 1) and $FFFF);   { dec }
    $07: begin                                        { print_addr }
           ZPCSave;
           ZTextPrintAt(ZOp[0]);
           ZPCRestore;
         end;
    $09: ZObjRemove(ZOp[0]);                          { remove_obj }
    $0A: begin                                        { print_obj }
           ZPCSave;
           ZObjName(ZOp[0], ZTmpS);
           ZPCRestore;
           ZTextWrite(ZTmpS);
         end;
    $0B: ZDoReturn(ZOp[0]);                           { ret }
    $0C: ZPCRel((ZOp[0] - 2) and $FFFF);              { jump -- SIGNED offset,
                                                        and not a branch }
    $0D: begin                                        { print_paddr }
           ZPCSave;
           ZTextPrintPacked(ZOp[0]);
           ZPCRestore;
         end;
    $0E: ZVarSet(ZIStoreV, ZVarGetInd(ZOp[0]));       { load -- indirect }
    $0F: ZVarSet(ZIStoreV, (not ZOp[0]) and $FFFF);   { not }
  else
    ZTmpS := 'unknown 1OP opcode';
    ZDie(ZTmpS);
  end;
end;

procedure ZExec0OP;
begin
  case ZIOpcode of
    $00: ZDoReturn(1);                                { rtrue }
    $01: ZDoReturn(0);                                { rfalse }
    $02: ;                                            { print -- the decoder
                                                        already printed it }
    $03: begin                                        { print_ret }
           ZOutNewLine;
           ZDoReturn(1);
         end;
    $04: ;                                            { nop }
    $05: ZBranch(ZQSave(ZIBrAtOfs, ZIBrAtPage));      { save }
    $06: begin                                        { restore }
           { On success the PC has already been replaced by the one the save
             file carried, which points at the branch bytes of the SAVE
             instruction that wrote it (Quetzal s5.8.1). Decode THAT branch
             and take it as true: the restored game resumes as though its
             save had just succeeded, which is what a v3 game expects and why
             restoring a v3 story prints its save message a second time.

             This instruction's own branch data is read but never used on the
             success path -- the PC that would have consumed it is gone. }
           if ZQRestore then
           begin
             ZDDecodeBranch;
             ZBranch(True);
           end
           else ZBranch(False);
         end;
    $07: ZQRestart;                                   { restart }
    $08: ZDoReturn(ZPop);                             { ret_popped }
    $09: begin                                        { pop -- DISCARD the top }
           { Not ZVarSet(0, ZPop): writing variable 0 PUSHES, so that pops
             and pushes straight back and does nothing at all. The result
             still has to be consumed -- a call cannot be a statement in
             this compiler (Part 24 s5.4). }
           ZDisc := ZPop;
         end;
    $0A: begin                                        { quit }
           ZOutNewLine;
           ZQuit := True;
         end;
    $0B: ZOutNewLine;                                 { new_line }
    $0C: ZStatusLine;                                 { show_status }
    $0D: ZBranch(ZVerify);                            { verify }
  else
    ZTmpS := 'unknown 0OP opcode';
    ZDie(ZTmpS);
  end;
end;

procedure ZExecVAR;
var
  i, n: Word;
begin
  case ZIOpcode of
    $00: begin                                        { call }
           n := ZINOps;
           if n > 0 then n := n - 1;                  { operand 0 is the
                                                        routine, the rest args }
           ZDoCall(ZOp[0], n, ZIStoreV);
         end;
    $01: ZPutWord(ZOp[0] + (ZOp[1] shl 1), ZOp[2]);   { storew }
    $02: ZPutByte(ZOp[0] + ZOp[1], ZOp[2]);           { storeb }
    $03: ZObjPutProp(ZOp[0], ZOp[1], ZOp[2]);         { put_prop }
    $04: ZDoRead(ZOp[0], ZOp[1]);                     { sread }
    $05: ZTZscii(ZOp[0]);                             { print_char }
    $06: begin                                        { print_num -- SIGNED }
           if (ZOp[0] and $8000) <> 0 then
           begin
             ZOutChar('-');
             ZTextWriteNum(ZNeg(ZOp[0]));
           end
           else ZTextWriteNum(ZOp[0]);
         end;
    $07: ZVarSet(ZIStoreV, ZRand(ZOp[0]));            { random }
    $08: ZPush(ZOp[0]);                               { push }
    $09: ZVarSetInd(ZOp[0], ZPop);                    { pull -- indirect }
    $0A: ;                                            { split_window -- ignored }
    $0B: ;                                            { set_window   -- ignored }
    $13: ;                                            { output_stream -- ignored }
    $14: ;                                            { input_stream  -- ignored }
    $15: ;                                            { sound_effect  -- ignored }
  else
    ZTmpS := 'unknown VAR opcode';
    ZDie(ZTmpS);
  end;
end;

{ ---- Run ----------------------------------------------------------------- }

procedure ZExecInit;
begin
  ZSP    := 0;
  ZFP    := 0;
  ZQuit  := False;
  ZFault := False;

  ZFFloor[0]  := 0;
  ZFNLoc[0]   := 0;
  ZFArgs[0]   := 0;
  ZFRetVar[0] := ZRETVAR_NONE;
  ZFBase      := 0;

  ZDisInit;                     { the decoder's flag table -- see zdis.pas }

  ZRndSeed    := $A5C3;
  ZDPrintText := True;
  ZTraceN     := 0;

  ZOutInit;
  ZDictInit;

  { v3's initial PC is a plain BYTE address pointing at the first
    INSTRUCTION -- not a packed address, and not a routine header. Zork I's
    main routine has its locals byte at $50D4 and the header field says
    $50D5. Seeking to $50D4 would execute the header as an opcode. }
  ZSeek(ZInitPC);
end;

const
  ZTHex: array[0..15] of Char =
    ('0','1','2','3','4','5','6','7','8','9','a','b','c','d','e','f');

procedure ZTWHex4(v: Word);
begin
  Write(ZTHex[(v shr 12) and $0F], ZTHex[(v shr 8) and $0F],
        ZTHex[(v shr 4)  and $0F], ZTHex[v and $0F]);
end;

{ One line per instruction: address, operand count class, opcode number, then
  the evaluated operands. Written with Write rather than through the wrap
  sink -- the trace must not be reflowed, and must not disturb ZOutCol. }
procedure ZTraceLine;
var
  i: Word;
begin
  Write(ZTHex[(ZIAtPage - ZPg0) and $0F]);
  ZTWHex4(ZIAtOfs);
  Write(' '); Write(ZIClass);
  Write(' '); Write(ZTHex[(ZIOpcode shr 4) and $0F], ZTHex[ZIOpcode and $0F]);
  i := 0;
  while i < ZINOps do
  begin
    Write(' ');
    ZTWHex4(ZOp[i]);
    i := i + 1;
  end;
  WriteLn;
end;

procedure ZRun;
begin
  while not ZQuit do
  begin
    ZDecode;
    ZEvalOperands;
    if ZTraceN < ZTraceMax then
    begin
      ZTraceLine;
      ZTraceN := ZTraceN + 1;
    end;
    if ZIClass = ZC_2OP then ZExec2OP
    else if ZIClass = ZC_1OP then ZExec1OP
    else if ZIClass = ZC_0OP then ZExec0OP
    else ZExecVAR;
  end;
  ZOutFlushWord;
end;
