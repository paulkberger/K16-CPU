(* -------------------------------------------------------------------------- *)
(* --- Optimizer ------------------------------------------------------------ *)
(* -------------------------------------------------------------------------- *)

(**
 * An element of "outgoing code". These are organized in a linked list and
 * subject to optimization. The list will be flushed on each label that is
 * being written and at the end of a procedure or function.
 *)
type
  PCode = ^TCode;
  TCode = record
    Tag, Instruction, Comment: String;  // Label, instruction, and comment
    Next, Prev: PCode;                  // Successor and predecessor
  end;

var
  (**
   * The most recent line of assembly code generated.
   * Must be nil at procedure boundaries. Flushed by Flush.
   *)
  Code: PCode = nil;

(**
 * Appends a line of assembly code consisting of the three given elements, any
 * of which may be the empty string.
 *)
procedure AppendCode(Tag, Instruction, Comment: String);
var
  Temp: PCode;
begin
  New(Temp);
  Temp^.Tag := Tag;
  Temp^.Instruction := Instruction;
  Temp^.Comment := Comment;
  Temp^.Prev := Code;
  Temp^.Next := nil;
  if Code <> nil then
    Code^.Next := Temp;
  Code := Temp;
end;

(**
 * Removes the most-recently generated line of assembly code.
 *)
procedure RemoveCode();
var
  Temp: PCode;
begin
  Temp := Code;
  Code := Code^.Prev;
  if Code <> nil then
    Code^.Next := nil;
  Dispose(Temp);
end;

(* -------------------------------------------------------------------------- *)
(* --- Flush-pass gates ------------------------------------------------------ *)
(* -------------------------------------------------------------------------- *)
(*
 * Set any of these False and rebuild to take one transform out of circulation.
 * They exist so a miscompilation can be localised in one rebuild per pass
 * instead of by reverting patches, and they cost nothing when all are True.
 *)
const
  EnablePagedAccess   = True;   { Rules 15, 16 + read-modify-write }
  EnableFrameLEA      = True;   { Rule 22 }
  EnableIndexed       = True;   { Rule 18 }
  EnablePointerIntoX  = True;   { Rules 20, 21 }
  EnableNegate        = True;   { Rule 23 }
  EnableDropDeadImm   = True;   { Rule 19 }
  EnableImmediatePush = True;   { Rule 24 -- see the note below }

  (* Rule 24 emits PUSH #imm, XYs -- opcode $07 mode 11, "PUSHI" in the opcode
   * map. Note the assembler SYNTAX is PUSH #imm, XYs; emitting the mnemonic
   * PUSHI is rejected. The map's example column is the authority for this.
   *
   * HISTORY, because it cost several runs and the lesson generalises.
   *
   * The instruction appears nowhere in k16_rtl_kos.asm, k16_rtl.asm or
   * k16_kernel.asm, so the code generator emitting it was its first execution
   * in the project's history -- and it was broken in the emulator, in two
   * compounding ways:
   *
   *   k16-decode.js   needsImm() had no case for $07 at all, so it fell to
   *                   `default: return false`. PC advanced one word instead
   *                   of two and the immediate was executed as an
   *                   instruction. ($5678 decodes as a TWO-word SUB, which
   *                   then swallowed the following POP as its operand -- so
   *                   one bad push destroyed three instructions.)
   *   k16-opcodes.js  $07 mode 3 was wired to a "discard one word" handler:
   *                   stack pointer moved +2 instead of -2.
   *   k16-debug.js    disassembled it as "POPD", a mnemonic that appears
   *                   nowhere in the manual -- the tell, had anyone looked.
   *
   * The cycle table in k16-decode.js already read "PUSHI=5" for that slot, so
   * the encoding was understood when that table was written; needsImm simply
   * never caught up.
   *
   * Fixed and confirmed. Keep the probe as the regression test:
   *
   *     LOADI  D0, #$1234
   *     PUSH   D0, XY3          ; known-good push
   *     PUSH   #$5678, XY3      ; under test -- must assemble to $3E06 $5678
   *     POP    D1, XY3          ; expect D1 = $5678
   *     POP    D2, XY3          ; expect D2 = $1234, X3 back where it started
   *     NOP    #$FF             ; EMU breakpoint -- inspect D1, D2, X3
   *
   * STILL UNCHECKED: Digital's microcode, and emu_decode.pas in K16EmuIDE.
   * k16-decode.js calls itself a "1:1 hand-port of emu_decode.pas", so if the
   * needsImm omission predates the port, the Pascal emulator has it too.
   *)

(* -------------------------------------------------------------------------- *)
(* --- Paged-access fusion (Part 23, section 5.4) --------------------------- *)
(* -------------------------------------------------------------------------- *)

(**
 * True if S contains Tok as a whole token (letters/digits/$/_ runs).
 * Prevents 'X0' matching inside 'XY0' and vice versa.
 *)
function MentionsToken(const S, Tok: String): Boolean;
var
  I: Integer;
  Cur: String;
begin
  MentionsToken := False;
  Cur := '';
  for I := 1 to Length(S) + 1 do
  begin
    if (I <= Length(S)) and
       (((S[I] >= 'A') and (S[I] <= 'Z')) or ((S[I] >= 'a') and (S[I] <= 'z')) or
        ((S[I] >= '0') and (S[I] <= '9')) or (S[I] = '$') or (S[I] = '_')) then
      Cur := Cur + S[I]
    else
    begin
      if Cur = Tok then begin MentionsToken := True; Exit; end;
      Cur := '';
    end;
  end;
end;

function MnemonicOf(const Instr: String): String;
var
  P: Integer;
begin
  P := Pos(' ', Instr);
  if P = 0 then MnemonicOf := Instr else MnemonicOf := Copy(Instr, 1, P - 1);
end;

(**
 * The first operand of Instr, i.e. its destination for the register-writing
 * mnemonics. Returns '' if there is no operand.
 *)
function FirstOperand(const Instr: String): String;
var
  P, Q: Integer;
begin
  P := Pos(' ', Instr);
  if P = 0 then begin FirstOperand := ''; Exit; end;
  while (P <= Length(Instr)) and (Instr[P] = ' ') do Inc(P);
  Q := P;
  while (Q <= Length(Instr)) and
        (((Instr[Q] >= 'A') and (Instr[Q] <= 'Z')) or
         ((Instr[Q] >= '0') and (Instr[Q] <= '9'))) do Inc(Q);
  FirstOperand := Copy(Instr, P, Q - P);
end;

function WritesRegister(const Instr, Reg: String): Boolean;
var
  M, Op1: String;
begin
  M   := MnemonicOf(Instr);
  Op1 := FirstOperand(Instr);
  { The load family writes its destination without reading it, so it kills the
    previous value just as LOADI/MOVE/POP do. Omitting them made liveness
    answer "read" for a register that was in fact being overwritten, and
    declined valid fusions. ALU forms (ADD, SUB, AND, ...) are deliberately
    absent: they read the destination as well as writing it. }
  WritesRegister := ((M = 'LOADI') or (M = 'MOVE') or (M = 'POP') or
                     (M = 'LOADXY') or (M = 'LEA') or
                     (M = 'LOADD') or (M = 'LOADB') or (M = 'LOADX') or
                     (M = 'LOADP') or (M = 'LOADPB') or
                     (M = 'LOADZ') or (M = 'LOADZB')) and (Op1 = Reg);
end;

(**
 * Unlinks C from the code list. RemoveCode can only pop the tail; this pass
 * deletes from the middle, so it needs the general form.
 *)
procedure UnlinkCode(C: PCode);
begin
  if C^.Prev <> nil then C^.Prev^.Next := C^.Next;
  if C^.Next <> nil then C^.Next^.Prev := C^.Prev;
  if Code = C then Code := C^.Prev;
  Dispose(C);
end;

(**
 * Rule 15 -- LOADP / LOADPB for compile-time addresses.
 *
 *     LOADI  Xn, #addr        \
 *     LOADI  Yn, #$00          |  ->  LOADP  Dm, Y3, [#addr]
 *     LOADD  Dm, [XYn]        /       3 instr / 4 words / 7 cyc -> 1 / 2 / 3
 *
 * LOADB gives LOADPB. Y3 is the data page on both targets: on k/OS it is the
 * task page set by the loader, on bare metal __reset does LOADI Y3, #$00 and
 * globals live in page $00.
 *
 * Why the page register is written as LOADI Yn, #$00 here and MOVE Yn, Y3 in
 * the listing: KosPatchInstr rewrites it, and it runs in Emit0 at flush time,
 * AFTER this pass. So the code list carries one uniform form for both
 * targets. That also disposes of the bare-metal CODEBANK hazard the Part 22
 * handover flagged as "the dangerous kind": ROM and string-literal access
 * goes through LOADI Yn, #CODEBANK, which is a different immediate and simply
 * never matches. The discrimination falls out of where the rule sits rather
 * than having to be enforced with a keyword blocklist.
 *
 * WHY THIS IS NOT A PEEPHOLE RULE. Collapsing the triple stops writing Xn and
 * Yn, so it is only legal if nothing downstream reads them. DoOptimize fires
 * on append and can only look backwards, which is not enough -- the for-loop
 * increment is a live counterexample:
 *
 *     LOADI  X0, #g_i / LOADI Yn, #$00 / LOADD D1, [XY0]
 *     ADD    D1, #1
 *     STORED D1, [XY0]        <- would store through a stale XY0
 *
 * A backward rule rewrites the triple before the STORED is ever seen, and the
 * result is silent memory corruption. So the fusion runs at Flush, where the
 * whole basic block is in the list and a forward liveness scan is possible.
 * Blocks are bounded by labels (Emit flushes on a tag), which is exactly the
 * right scope.
 *
 * The scan walks forward tracking Xn and Yn separately and requires BOTH to
 * be dead -- overwritten before being read -- before fusing. Any read first,
 * including any [XYn], declines. Reaching the end of the block is safe: every
 * block establishes its own XY0/XY1 before use, the only registers held
 * across blocks being XY2 (frame pointer) and XY3 (stack), which is why the
 * rule is restricted to n in {0,1} and never touches those two.
 *)
(**
 * Control-transfer instructions. A backward scan stops at these: past one the
 * window is no longer straight-line, so "nothing between here and there
 * touches Dm" stops being a statement about a single execution path.
 *)
function IsControlFlow(const Instr: String): Boolean;
var
  M: String;
begin
  M := MnemonicOf(Instr);
  IsControlFlow := (Copy(M, 1, 1) = 'B') or (Copy(M, 1, 3) = 'JMP') or
                   (Copy(M, 1, 4) = 'CALL') or (Copy(M, 1, 3) = 'RET') or
                   (M = 'TRAP') or (M = 'HALT') or (M = 'RTI');
end;

(**
 * True if BOTH halves of the XY pair XYd die unread from S onward -- each is
 * overwritten before anything reads it. Any read first (including any use of
 * [XYd] as an address) answers False.
 *
 * Reaching the end of the block is True: every block establishes its own
 * XY0/XY1 before use. The only pairs held across blocks are XY2 (frame
 * pointer) and XY3 (stack), which is why callers restrict d to 0 and 1.
 *)
function XYPairDeadAfter(S: PCode; D: Char): Boolean;
var
  XReg, YReg, XYReg: String;
  XDead, YDead: Boolean;
begin
  XReg  := 'X' + D;
  YReg  := 'Y' + D;
  XYReg := 'XY' + D;
  XDead := False;
  YDead := False;
  XYPairDeadAfter := True;

  while (S <> nil) and not (XDead and YDead) do
  begin
    { Unlike RegDeadAfter, this one DOES see past a call, and the difference
      is the V2 ABI: D0/D1/D2 are argument registers, XY0/XY1 are not. Every
      call target the code generator emits -- the RTL entry points and
      compiled procedures alike -- writes its XY pair before reading it, so a
      callee cannot be reading one as an argument. It clobbers them freely
      instead, which means nothing after the call can be relying on a value
      set before it either.

      Verified by inspection of every emitted CALL target rather than assumed;
      an RTL routine that grew an XY argument would invalidate this, and the
      standing-page audit (no [XYn] access without a local setup, n = 0 or 1)
      is what would catch it. }
    if MentionsToken(S^.Instruction, XYReg) or
       MentionsToken(S^.Instruction, XReg) or
       MentionsToken(S^.Instruction, YReg) then
    begin
      if WritesRegister(S^.Instruction, XYReg) then
      begin XDead := True; YDead := True; end
      else if WritesRegister(S^.Instruction, XReg) and
              not MentionsToken(S^.Instruction, YReg) and
              not MentionsToken(S^.Instruction, XYReg) then
        XDead := True
      else if WritesRegister(S^.Instruction, YReg) and
              not MentionsToken(S^.Instruction, XReg) and
              not MentionsToken(S^.Instruction, XYReg) then
        YDead := True
      else
      begin
        XYPairDeadAfter := False;
        Exit;
      end;
    end;
    S := S^.Next;
  end;
end;

(**
 * True if Reg dies unread from S onward. Same rule as XYPairDeadAfter for a
 * single register: the first instruction that mentions it must be a plain
 * overwrite, and it must mention it exactly once (so ADD D0,D0 -- which reads
 * as well as writes, and is not a writing mnemonic anyway -- answers False).
 *)
function RegDeadAfter(S: PCode; const Reg: String): Boolean;
begin
  RegDeadAfter := True;
  while S <> nil do
  begin
    { A call reads registers that do not appear in its text. D0/D1/D2 are the
      V2 ABI argument registers, so CALL16 __putc reads D0 while mentioning
      neither. A textual scan walks straight through it and concludes the
      argument register was overwritten unread -- which deletes the argument.
      Any control transfer therefore answers "not dead". }
    if IsControlFlow(S^.Instruction) then
    begin
      RegDeadAfter := False;
      Exit;
    end;
    if MentionsToken(S^.Instruction, Reg) then
    begin
      RegDeadAfter := WritesRegister(S^.Instruction, Reg) and
                      (FirstOperand(S^.Instruction) = Reg);
      Exit;
    end;
    S := S^.Next;
  end;
end;

(**
 * Like RegDeadAfter, but requires PROOF: reaching the end of the block
 * answers False rather than True.
 *
 * The difference matters for deleting a write. Rules 15/16 delete a write
 * whose replacement sets the same pair two instructions later, so an
 * unterminated block is still safe. Rule 19 deletes a write with nothing
 * replacing it, so "nobody read it before the block ended" is not the same
 * claim as "nobody reads it" -- and D registers are statement scratch, which
 * is a convention rather than something this pass can see.
 *)
function RegKilledAfter(S: PCode; const Reg: String): Boolean;
begin
  RegKilledAfter := False;
  while S <> nil do
  begin
    if IsControlFlow(S^.Instruction) then Exit;   { see RegDeadAfter }
    if MentionsToken(S^.Instruction, Reg) then
    begin
      RegKilledAfter := WritesRegister(S^.Instruction, Reg) and
                        (FirstOperand(S^.Instruction) = Reg);
      Exit;
    end;
    S := S^.Next;
  end;
end;

(**
 * True if a conditional branch is reached before any CMP.
 *
 * Rule 18 removes an ADD, and ADD sets flags. Every conditional branch the
 * code generator emits is preceded by the CMP that set the flags it tests
 * (that is the whole shape Rule 14 fuses), so no branch should ever be
 * reading an address-add's flags -- but asserting it is cheaper than
 * relying on it.
 *)
function BranchBeforeCompare(S: PCode): Boolean;
var
  M: String;
begin
  BranchBeforeCompare := False;
  while S <> nil do
  begin
    M := MnemonicOf(S^.Instruction);
    if Copy(M, 1, 3) = 'CMP' then Exit;
    if (Copy(M, 1, 1) = 'B') and (Copy(M, 1, 3) <> 'BRA') then
    begin
      BranchBeforeCompare := True;
      Exit;
    end;
    S := S^.Next;
  end;
end;

(**
 * The first node at or after S that mentions any part of the XY pair XYd,
 * or nil if the block ends without one.
 *)
function FirstXYUse(S: PCode; D: Char): PCode;
begin
  FirstXYUse := nil;
  while S <> nil do
  begin
    if IsControlFlow(S^.Instruction) then Exit;   { callee may clobber the pair }
    if MentionsToken(S^.Instruction, 'XY' + D) or
       MentionsToken(S^.Instruction, 'X' + D) or
       MentionsToken(S^.Instruction, 'Y' + D) then
    begin
      FirstXYUse := S;
      Exit;
    end;
    S := S^.Next;
  end;
end;

procedure FusePagedAccess;
var
  C, C2, C3, S, A, U, StoreNode: PCode;
  D, Ch: Char;
  XYReg, Addr, Dm, Dv, Mn, Mn2: String;
  Safe: Boolean;
begin
  if not EnablePagedAccess then Exit;
  if not Optimize or (Code = nil) then Exit;

  while Code^.Prev <> nil do Code := Code^.Prev;
  C := Code;

  while C <> nil do
  begin
    C2 := C^.Next;
    if C2 = nil then Break;
    C3 := C2^.Next;
    if C3 = nil then Break;

    Safe := False;
    StoreNode := nil;
    D := ' ';

    { Match LOADI Xn, #addr, n restricted to 0 and 1 }
    if (Copy(C^.Instruction, 1, 8) = 'LOADI  X') and
       ((C^.Instruction[9] = '0') or (C^.Instruction[9] = '1')) and
       (Copy(C^.Instruction, 10, 3) = ', #') then
    begin
      D     := C^.Instruction[9];
      XYReg := 'XY' + D;
      Addr  := Copy(C^.Instruction, 13, 255);

      Mn := MnemonicOf(C3^.Instruction);

      if (C2^.Instruction = 'LOADI  Y' + D + ', #$00') and
         (C2^.Tag = '') and (C3^.Tag = '') and
         ((Mn = 'LOADD') or (Mn = 'LOADB')) and
         (Pos('[' + XYReg + ']', C3^.Instruction) > 0) then
      begin
        Dm := FirstOperand(C3^.Instruction);
        if (Length(Dm) = 2) and (Dm[1] = 'D') then
        begin
          Safe := XYPairDeadAfter(C3^.Next, D);

          if not Safe then
          begin
            { Read-modify-write: the pair is not dead after the load because
              a store through it follows --

                  LOADI  X0, #g_i / LOADI Y0, #$00 / LOADD D1, [XY0]
                  ADD    D1, #1
                  STORED D1, [XY0]

              which is every loop counter increment, executed once per
              iteration. Rule 15 alone must decline this (the store would
              go through a stale XY0), but if the store is the ONLY use of
              the pair and the pair is dead after it, then BOTH halves can
              be paged and the pair disappears entirely:

                  LOADP  D1, Y3, [#g_i] / ADD D1, #1 / STOREP D1, Y3, [#g_i]

              FirstXYUse enforces "only use": anything else touching the
              pair first -- including a store through an offset form like
              [XY0+#2] -- is found instead and declines. }
            U := FirstXYUse(C3^.Next, D);
            if (U <> nil) and (U^.Tag = '') and
               (Pos('[' + XYReg + ']', U^.Instruction) > 0) then
            begin
              Mn2 := MnemonicOf(U^.Instruction);
              if ((Mn2 = 'STORED') or (Mn2 = 'STOREB')) and
                 XYPairDeadAfter(U^.Next, D) then
              begin
                Dv := FirstOperand(U^.Instruction);
                if (Length(Dv) = 2) and (Dv[1] = 'D') then
                begin
                  Safe      := True;
                  StoreNode := U;
                end;
              end;
            end;
          end;
        end;
      end;
    end;

    if Safe then
    begin
      if MnemonicOf(C3^.Instruction) = 'LOADB' then Ch := 'B' else Ch := ' ';
      if Ch = 'B' then
        C^.Instruction := 'LOADPB ' + Dm + ', Y3, [#' + Addr + ']'
      else
        C^.Instruction := 'LOADP  ' + Dm + ', Y3, [#' + Addr + ']';
      C^.Comment := 'paged';
      UnlinkCode(C2);
      UnlinkCode(C3);

      if StoreNode <> nil then
      begin
        if MnemonicOf(StoreNode^.Instruction) = 'STOREB' then
          StoreNode^.Instruction := 'STOREPB ' + Dv + ', Y3, [#' + Addr + ']'
        else
          StoreNode^.Instruction := 'STOREP  ' + Dv + ', Y3, [#' + Addr + ']';
        StoreNode^.Comment := 'paged';
      end;
    end
    else
    begin
      { --- Rule 16: STOREP / STOREPB for compile-time addresses --------------
        The mirror of Rule 15, for the write side:

            LOADI  Dm, #addr          (somewhere earlier in the block)
            ...                       (computes the value into Dv)
            MOVE   Xn, Dm         \
            LOADI  Yn, #$00        |  ->  STOREP Dv, Y3, [#addr]
            STORED Dv, [XYn]      /       4 instr / 5 words / 15 cyc -> 1 / 2 / 5

        The address is not adjacent to the store the way it is on the read
        side -- the value gets computed in between -- so the address LOADI is
        found by walking BACKWARDS from the MOVE. The scan gives up on the
        first instruction that touches Dm for any reason other than being the
        defining LOADI, and on any control transfer, because past a branch the
        window is no longer one straight-line path.

        Three liveness obligations, all of which delete a write:
          - Dm dead after the store: its LOADI goes away.
          - Xn / Yn dead after the store: their writes go away (Rule 15's
            condition, same helper).
          - Dv <> Dm: with the LOADI gone, Dm no longer holds the address, so
            a store OF the address THROUGH the address would read a register
            that is no longer set.

        If the address LOADI carries a Tag it cannot simply be deleted -- the
        label has to stay where it is, since the STOREP must still execute
        after the value is computed, not at the label. The node is blanked to
        a label-only element instead, which Flush already emits (Emit0 writes
        the tag and no instruction). }
      if (Copy(C^.Instruction, 1, 8) = 'MOVE   X') and
         ((C^.Instruction[9] = '0') or (C^.Instruction[9] = '1')) and
         (Copy(C^.Instruction, 10, 3) = ', D') and
         (C^.Tag = '') and (C2^.Tag = '') and (C3^.Tag = '') then
      begin
        D     := C^.Instruction[9];
        XYReg := 'XY' + D;
        Dm    := Copy(C^.Instruction, 12, 2);          { the address register }
        Mn    := MnemonicOf(C3^.Instruction);

        if (C2^.Instruction = 'LOADI  Y' + D + ', #$00') and
           ((Mn = 'STORED') or (Mn = 'STOREB')) and
           (Pos('[' + XYReg + ']', C3^.Instruction) > 0) then
        begin
          Dv := FirstOperand(C3^.Instruction);          { the value register }

          if (Length(Dv) = 2) and (Dv[1] = 'D') and (Dv <> Dm) then
          begin
            { Walk back for the LOADI that defined Dm. }
            A    := nil;
            S    := C^.Prev;
            while S <> nil do
            begin
              if IsControlFlow(S^.Instruction) then Break;
              if MentionsToken(S^.Instruction, Dm) then
              begin
                if (Copy(S^.Instruction, 1, 7) = 'LOADI  ') and
                   (FirstOperand(S^.Instruction) = Dm) and
                   (Copy(S^.Instruction, 8 + Length(Dm), 3) = ', #') then
                  A := S;
                Break;
              end;
              S := S^.Prev;
            end;

            if (A <> nil) and RegDeadAfter(C3^.Next, Dm)
                          and XYPairDeadAfter(C3^.Next, D) then
            begin
              Addr := Copy(A^.Instruction, 11 + Length(Dm), 255);
              if Mn = 'STOREB' then
                C3^.Instruction := 'STOREPB ' + Dv + ', Y3, [#' + Addr + ']'
              else
                C3^.Instruction := 'STOREP  ' + Dv + ', Y3, [#' + Addr + ']';
              C3^.Comment := 'paged';

              if A^.Tag <> '' then
              begin
                A^.Instruction := '';                   { keep the label only }
                A^.Comment     := '';
              end
              else
                UnlinkCode(A);

              UnlinkCode(C);                            { MOVE Xn, Dm }
              UnlinkCode(C2);                           { LOADI Yn, #$00 }
              C := C3;
            end;
          end;
        end;
      end;
    end;

    C := C^.Next;
  end;

  while Code^.Prev <> nil do Code := Code^.Prev;
end;

(**
 * Rule 18 -- [XY+D] register-indexed addressing for variable array indices.
 *
 *     LOADI  Dn, #base       \
 *     ADD    Dm, Dn           |
 *     MOVE   Xk, Dm           |  ->  LOADI Xk, #base
 *     LOADI  Yk, #$00         |      LOADI Yk, #$00
 *     LOADD  Dv, [XYk]       /       LOADD Dv, [XYk+Dm]
 *
 *     5 instr / 6 words / 18 cyc  ->  3 / 4 / 8
 *
 * This is the case LOADP cannot reach: LOADP takes [#imm16] only, so a
 * runtime subscript has to have the base added to it somewhere. [XY+D] folds
 * that add into the load itself. The two are complementary -- LOADP covers
 * compile-time addresses (and after the constant-subscript fold that is most
 * literal-subscript array access), [XY+D] covers the rest.
 *
 * The rewritten load usually comes out as LOADD D0, [XY0+D0] -- D0 as its own
 * index -- which is legal and deliberate: the address is formed before the
 * destination is written. k16_rtl_kos.asm documents the same idiom in its
 * arg-access header ("D0 can serve as its own offset").
 *
 * Obligations:
 *   - Dn dead after: its LOADI is deleted.
 *   - Dm dead after: it no longer holds base+index after the rewrite, only
 *     the index. When Dv = Dm the load itself kills it, which is the common
 *     shape; otherwise it has to die on its own.
 *   - Xk / Yk carry no obligation -- both are still written, by the two
 *     LOADIs that replace the MOVE.
 *   - No conditional branch may read the flags the deleted ADD would have
 *     set (BranchBeforeCompare).
 *)
procedure FuseIndexedAccess;
var
  C, Cb, Cc, Cd, Ce: PCode;
  K: Char;
  Base, Dn, Dm, Dv, XYReg, Mn: String;
begin
  if not EnableIndexed then Exit;
  if not Optimize or (Code = nil) then Exit;

  while Code^.Prev <> nil do Code := Code^.Prev;
  C := Code;

  while C <> nil do
  begin
    Cb := C^.Next;   if Cb = nil then Break;
    Cc := Cb^.Next;  if Cc = nil then Break;
    Cd := Cc^.Next;  if Cd = nil then Break;
    Ce := Cd^.Next;  if Ce = nil then Break;

    if (Copy(C^.Instruction, 1, 8) = 'LOADI  D') and
       (Copy(C^.Instruction, 10, 3) = ', #') and
       (Cb^.Tag = '') and (Cc^.Tag = '') and (Cd^.Tag = '') and (Ce^.Tag = '') and
       (Copy(Cb^.Instruction, 1, 7) = 'ADD    ') and
       (Copy(Cc^.Instruction, 1, 8) = 'MOVE   X') and
       ((Cc^.Instruction[9] = '0') or (Cc^.Instruction[9] = '1')) and
       (Copy(Cc^.Instruction, 10, 3) = ', D') then
    begin
      Dn   := Copy(C^.Instruction, 8, 2);
      Base := Copy(C^.Instruction, 13, 255);
      K    := Cc^.Instruction[9];
      Dm   := Copy(Cc^.Instruction, 12, 2);
      XYReg := 'XY' + K;
      Mn   := MnemonicOf(Ce^.Instruction);

      if (Cb^.Instruction = 'ADD    ' + Dm + ', ' + Dn) and
         (Cd^.Instruction = 'LOADI  Y' + K + ', #$00') and
         ((Mn = 'LOADD') or (Mn = 'LOADB')) and
         (Pos('[' + XYReg + ']', Ce^.Instruction) > 0) then
      begin
        Dv := FirstOperand(Ce^.Instruction);
        { Dm carries an obligation only when the load does not overwrite it.
          The usual shape is LOADD D0, [XY0+D0], where the load itself kills
          the old base+index value, so asking whether Dm is dead AFTER the
          load would wrongly see the freshly loaded value being read and
          decline every ordinary array access. }
        if (Length(Dv) = 2) and (Dv[1] = 'D') and (Dn <> Dm) and
           RegDeadAfter(Ce^.Next, Dn) and
           ((Dv = Dm) or RegDeadAfter(Ce^.Next, Dm)) and
           not BranchBeforeCompare(Ce^.Next) then
        begin
          C^.Instruction  := 'LOADI  X' + K + ', #' + Base;
          C^.Comment      := 'indexed base';
          Ce^.Instruction := Mn + '  ' + Dv + ', [' + XYReg + '+' + Dm + ']';
          Ce^.Comment     := 'register-indexed';
          UnlinkCode(Cb);                    { ADD  Dm, Dn }
          UnlinkCode(Cc);                    { MOVE Xk, Dm }
          C := Ce;
        end;
      end;
    end;

    C := C^.Next;
  end;

  while Code^.Prev <> nil do Code := Code^.Prev;
end;

(**
 * Rule 20 -- load a pointer straight into X.
 *
 *     LOADP  Dm, Y3, [#addr]       \      LOADP  Xk, Y3, [#addr]
 *     ...  (does not touch Dm/Xk)   |  ->  ...
 *     MOVE   Xk, Dm                /       (MOVE gone)
 *
 * LOADP's destination field is 4 bits wide and X registers are encodable, so
 * the load can name Xk directly and the D register never needs to exist.
 * Confirmed against the assembler and emulator before this rule was written
 * -- the encoding being wide enough is not the same as the microcode
 * implementing it, and the opcode map alone would not have settled it.
 *
 * This is the tail of the "one genuine gap" the Part 22 survey identified:
 * no LEA form moves a 16-bit value from a D register into an XY pair, so
 * every pointer dereference paid MOVE Xk,Dm at 3 cycles. Where the value came
 * from a paged load, it never has to enter a D register at all.
 *
 * The definer is found by walking backwards, as in Rule 16. The scan gives up
 * on the first instruction that touches Dm for any reason other than being
 * the defining LOADP, on any control transfer, and on anything that touches
 * Xk -- because the write to Xk moves EARLIER, so a reader of Xk in the
 * window would see the new value instead of the old one.
 *
 * Dm must be dead after the MOVE: it is no longer written at all.
 *
 * Word form only. LOADPB zero-extends a byte, which is not a pointer.
 *
 * The same applies to a pointer arriving off the stack:
 *
 *     POP    Dm, XY3               \      POP    Xk, XY3
 *     ...                           |  ->  ...
 *     MOVE   Xk, Dm                /       (MOVE gone)
 *
 * Reference Manual s6.12: "POP of ANY single register is unified at $07 mode
 * 00", and the opcode map gives it a 4-bit register field noted
 * (D,X,Y,ORDB,FLAGS,PCH,PCL). Four cycles either way, so this is a straight
 * saving of the MOVE. The code generator never used the form -- even the
 * epilogue writes POP D1 / MOVE X2, D1 -- so the population is every
 * runtime-address store left after the paged-destination work.
 *
 * The stack pair is required to be XY3, which is the only one the code
 * generator emits, and which also rules out the degenerate case of popping
 * into the very pair being used as the stack.
 *)
procedure RedirectPagedPointerLoads;
var
  C, S, A, Nxt: PCode;
  K: Char;
  Dm, XReg, XYReg: String;
begin
  if not EnablePointerIntoX then Exit;
  if not Optimize or (Code = nil) then Exit;

  while Code^.Prev <> nil do Code := Code^.Prev;
  C := Code;

  while C <> nil do
  begin
    Nxt := C^.Next;

    if (Copy(C^.Instruction, 1, 8) = 'MOVE   X') and
       ((C^.Instruction[9] = '0') or (C^.Instruction[9] = '1')) and
       (Copy(C^.Instruction, 10, 3) = ', D') and
       (C^.Tag = '') then
    begin
      K     := C^.Instruction[9];
      XReg  := 'X' + K;
      XYReg := 'XY' + K;
      Dm    := Copy(C^.Instruction, 12, 2);

      A := nil;
      S := C^.Prev;
      while S <> nil do
      begin
        if IsControlFlow(S^.Instruction) then Break;
        if MentionsToken(S^.Instruction, XReg) or
           MentionsToken(S^.Instruction, XYReg) then Break;
        if MentionsToken(S^.Instruction, Dm) then
        begin
          if (Copy(S^.Instruction, 1, 7) = 'LOADP  ') and
             (FirstOperand(S^.Instruction) = Dm) then
            A := S
          else if (Copy(S^.Instruction, 1, 7) = 'POP    ') and
                  (FirstOperand(S^.Instruction) = Dm) and
                  (Copy(S^.Instruction, 10, 5) = ', XY3') then
            A := S;
          Break;
        end;
        S := S^.Prev;
      end;

      if (A <> nil) and RegDeadAfter(C^.Next, Dm) then
      begin
        if Copy(A^.Instruction, 1, 7) = 'POP    ' then
          A^.Instruction := 'POP    ' + XReg + Copy(A^.Instruction, 10, 255)
        else
          A^.Instruction := 'LOADP  ' + XReg + Copy(A^.Instruction, 10, 255);
        A^.Comment := 'pointer into X';
        UnlinkCode(C);
      end;
    end;

    C := Nxt;
  end;

  if Code <> nil then
    while Code^.Prev <> nil do Code := Code^.Prev;
end;

(**
 * Rule 22 -- LEA for frame-relative addresses.
 *
 *     MOVE   D0, X2         3 cyc   \
 *     ADD    D0, #N         3 cyc    |  ->  LEA  XYk, XY2+#N     4 cyc
 *     MOVE   Xk, D0         3 cyc    |
 *     LOADI  Yk, #$00       2 cyc   /
 *
 *     4 instructions / 11 cycles  ->  1 / 4
 *
 * LEA mode 11 does base + imm5 across the full 24-bit pair in one go, and it
 * carries the page byte along with it -- which is why the LOADI Yk goes too,
 * not just the two MOVEs.
 *
 * THE PAGE QUESTION. Taking Yk from Y2 rather than setting it from Y3 is only
 * right if Y2 = Y3. It is, and the important part is that this rule does not
 * introduce the assumption:
 *
 *   - Every write to Y2 anywhere in k16_rtl_kos.asm, k16_rtl.asm and
 *     k16_kernel.asm is MOVE Y2,Y3, LOADI Y2,#$00 (bare metal, where Y3 is
 *     $00), or LEA XY2,XY0+... where Y0 is itself Y3. No path leaves Y2
 *     holding anything else.
 *   - The code generator NEVER writes Y2 at all -- prologues set X2 only --
 *     and it already reads frame slots as LOADD Dn,[XY2+#N] without setting
 *     Y2 first. The invariant is therefore load-bearing in existing output;
 *     if it were false, frame access would already be broken.
 *
 * That is a different situation from the MOVE Yn,Y3 elimination the Part 22
 * handover put behind an RTL audit: that one proposed trusting Y0 to be
 * correct on entry from an arbitrary predecessor, whereas this reads a
 * register the compiler itself maintains.
 *
 * imm5 caps the offset at 31. Larger frames fall back untouched.
 *
 * ADD sets flags and LEA is flag-transparent, so the same
 * BranchBeforeCompare guard as Rule 18 applies.
 *)
procedure FuseFrameAddresses;
var
  C, Cb, Cc, Cd, Nxt: PCode;
  K: Char;
  Ofs, Err: Integer;
  OfsTxt, Dm: String;
begin
  if not EnableFrameLEA then Exit;
  if not Optimize or (Code = nil) then Exit;

  while Code^.Prev <> nil do Code := Code^.Prev;
  C := Code;

  while C <> nil do
  begin
    Nxt := C^.Next;

    Cb := C^.Next;   if Cb = nil then Break;
    Cc := Cb^.Next;  if Cc = nil then Break;
    Cd := Cc^.Next;  if Cd = nil then Break;

    if (C^.Instruction = 'MOVE   D0, X2') and
       (Cb^.Tag = '') and (Cc^.Tag = '') and (Cd^.Tag = '') and
       (Copy(Cb^.Instruction, 1, 11) = 'ADD    D0, ') and
       (Copy(Cb^.Instruction, 12, 1) = '#') and
       (Copy(Cc^.Instruction, 1, 8) = 'MOVE   X') and
       ((Cc^.Instruction[9] = '0') or (Cc^.Instruction[9] = '1')) and
       (Copy(Cc^.Instruction, 10, 4) = ', D0') then
    begin
      K      := Cc^.Instruction[9];
      OfsTxt := Copy(Cb^.Instruction, 13, 255);
      Dm     := 'D0';
      Val(OfsTxt, Ofs, Err);

      if (Err = 0) and (Ofs >= 0) and (Ofs <= 31) and
         (Cd^.Instruction = 'LOADI  Y' + K + ', #$00') and
         RegDeadAfter(Cd^.Next, Dm) and
         not BranchBeforeCompare(Cd^.Next) then
      begin
        C^.Instruction := 'LEA    XY' + K + ', XY2+#' + OfsTxt;
        C^.Comment     := 'frame address';
        UnlinkCode(Cb);
        UnlinkCode(Cc);
        UnlinkCode(Cd);
        Nxt := C^.Next;
      end;
    end;

    C := Nxt;
  end;

  if Code <> nil then
    while Code^.Prev <> nil do Code := Code^.Prev;
end;

(**
 * Rule 23 -- NEG.
 *
 *     LOADI Dn, #0        2 cyc, 2 words        NEG  Dn, Dm    3 cyc, 1 word
 *     SUB   Dn, Dm        4 cyc, 1 word    ->
 *
 * Six cycles and three words become three and one. NEG's two-operand form
 * (Reference Manual s6.3) writes dst from a separate src, which is what makes
 * this a substitution rather than a reordering -- the in-place form alone
 * would not help, since the result is wanted in Dn and the operand is in Dm.
 *
 * Flag-equivalent, which is the part worth checking rather than assuming.
 * LOADI is flag-transparent, so the pair's flags come entirely from the SUB,
 * and NEG's documented behaviour matches it on all four:
 *     Z  result = 0                    -- same
 *     N  result bit 15                 -- same
 *     C  clear if src <> 0 (borrow)    -- same, and note this is the
 *        set if src = 0                   6502 sense: C=1 means NO borrow
 *     V  set if src = $8000            -- same (-(-32768) unrepresentable)
 * So no BranchBeforeCompare guard is needed here, unlike Rules 18 and 22.
 *
 * Dn <> Dm is required: LOADI Dn,#0 / SUB Dn,Dn is a convoluted zero, not a
 * negation, and NEG Dn,Dn would compute something else entirely.
 *)
procedure FuseNegate;
var
  C, Nxt: PCode;
  Dn, Dm: String;
begin
  if not EnableNegate then Exit;
  if not Optimize or (Code = nil) then Exit;

  while Code^.Prev <> nil do Code := Code^.Prev;
  C := Code;

  while (C <> nil) and (C^.Next <> nil) do
  begin
    Nxt := C^.Next;

    if (Copy(C^.Instruction, 1, 8) = 'LOADI  D') and
       (Copy(C^.Instruction, 10, 4) = ', #0') and
       (Length(C^.Instruction) = 13) and
       (C^.Next^.Tag = '') and
       (Copy(C^.Next^.Instruction, 1, 7) = 'SUB    ') then
    begin
      Dn := Copy(C^.Instruction, 8, 2);
      Dm := Copy(C^.Next^.Instruction, 12, 2);
      if (C^.Next^.Instruction = 'SUB    ' + Dn + ', ' + Dm) and
         (Length(Dm) = 2) and (Dm[1] = 'D') and (Dn <> Dm) then
      begin
        C^.Instruction := 'NEG    ' + Dn + ', ' + Dm;
        C^.Comment     := 'negate';
        UnlinkCode(C^.Next);
        Nxt := C^.Next;
      end;
    end;

    C := Nxt;
  end;

  if Code <> nil then
    while Code^.Prev <> nil do Code := Code^.Prev;
end;

(**
 * Rule 24 -- PUSHI.
 *
 *     LOADI Dn, #k        2 cyc          PUSH #k, XY3     5 cyc, 2 words
 *     PUSH  Dn, XY3       5 cyc     ->
 *
 * MNEMONIC: the encoding is named PUSHI in the opcode map ($07 mode 11), but
 * the ASSEMBLER SYNTAX is `PUSH #imm, XYs` -- the map's example column reads
 * `PUSH #$1234, XY3`. Reference Manual s6.12 writes "(PUSHI)" as the name of
 * the encoding, and the Assembler Syntax Guide's worked example
 * (`PUSHI #50w, XY3`) is stale. Emitting PUSHI is rejected with "Unknown
 * instruction or directive". The opcode map's example column is the
 * authority for anything the code generator has not emitted before.
 *
 * IMM16 only -- there is no imm5 form -- so this is two words either way for
 * a small constant, and saves a word only against a 16-bit LOADI. The two
 * cycles are the reliable part.
 *
 * Two cycles and one instruction per literal pushed. EmitLiteral
 * produces this pair for every literal operand in every expression, so the
 * population is large even after the folding rules have eaten most of them.
 *
 * ORDER MATTERS, and getting it wrong makes things SLOWER. Peephole Rule 4
 * turns LOADI D0,#x / PUSH D0 / POP D1 into LOADI D1,#x -- two cycles.
 * Converting to PUSHI first would leave PUSHI #x / POP D1 at nine. So this
 * pass runs LAST, on the pairs that survived every collapsing rule, and only
 * ever replaces a pair that is genuinely still a push.
 *
 * Dn must be dead afterwards: the register is no longer written at all. That
 * uses RegDeadAfter, which since the Rule 19 miscompilation treats any
 * control transfer as a read -- D0/D1/D2 are argument registers.
 *
 * XY3 only. It is the only stack the code generator uses, and requiring it
 * keeps the immediate operand unambiguous.
 *)
procedure UseImmediatePush;
var
  C, Nxt: PCode;
  Dn, Imm: String;
begin
  if not EnableImmediatePush then Exit;
  if not Optimize or (Code = nil) then Exit;

  while Code^.Prev <> nil do Code := Code^.Prev;
  C := Code;

  while (C <> nil) and (C^.Next <> nil) do
  begin
    Nxt := C^.Next;

    if (Copy(C^.Instruction, 1, 8) = 'LOADI  D') and
       (Copy(C^.Instruction, 10, 3) = ', #') and
       (C^.Next^.Tag = '') then
    begin
      Dn  := Copy(C^.Instruction, 8, 2);
      Imm := Copy(C^.Instruction, 13, 255);
      { RegKilledAfter, not RegDeadAfter. This deletes a write to Dn with
        nothing replacing it, which is Rule 19's situation, not Rule 16's --
        so "nobody read it before the block ended" is too weak a claim.
        Proof of an overwrite is required. }
      if (C^.Next^.Instruction = 'PUSH   ' + Dn + ', XY3') and
         RegKilledAfter(C^.Next^.Next, Dn) then
      begin
        C^.Instruction := 'PUSH   #' + Imm + ', XY3';
        C^.Comment     := 'push literal';
        UnlinkCode(C^.Next);
        Nxt := C^.Next;
      end;
    end;

    C := Nxt;
  end;

  if Code <> nil then
    while Code^.Prev <> nil do Code := Code^.Prev;
end;

(**
 * Rule 19 -- dead immediates.
 *
 * EmitLiteral pushes every literal operand; EmitBinOp then folds the value
 * into the instruction as an immediate and pops the pushed copy into a
 * register nobody reads. Peephole Rule 4 collapses the push/pop pair into a
 * lone LOADI, and that LOADI is the residue:
 *
 *     LOADP  D0, Y3, [#g_Passed]
 *     LOADI  D1, #1                 <- folded into the ADD below; never read
 *     ADD    D0, #1
 *     STOREP D0, Y3, [#g_Passed]
 *
 * Deleting it needs proof rather than the absence of evidence, so this uses
 * RegKilledAfter: the register must be demonstrably overwritten inside the
 * block, not merely un-read up to the block's end.
 *
 * Runs last, after the fusion passes, so that an address LOADI they were
 * going to consume is not pulled out from under them. (Such a LOADI is read
 * by the MOVE that follows it and so is never dead, but the ordering makes
 * that a property of the pass sequence rather than of a coincidence.)
 *)
procedure DropDeadImmediates;
var
  C, Nxt: PCode;
begin
  if not EnableDropDeadImm then Exit;
  if not Optimize or (Code = nil) then Exit;

  while Code^.Prev <> nil do Code := Code^.Prev;
  C := Code;

  while C <> nil do
  begin
    Nxt := C^.Next;
    if (C^.Tag = '') and
       (Copy(C^.Instruction, 1, 8) = 'LOADI  D') and
       (Copy(C^.Instruction, 10, 3) = ', #') and
       RegKilledAfter(C^.Next, Copy(C^.Instruction, 8, 2)) then
      UnlinkCode(C);
    C := Nxt;
  end;

  if Code <> nil then
    while Code^.Prev <> nil do Code := Code^.Prev;
end;

(**
 * Opens the target file.
 *)

procedure Flush;
var
  Temp: PCode;
begin
  if not Optimize or (Code = nil) then Exit;

  FusePagedAccess;
  FuseFrameAddresses;
  FuseIndexedAccess;
  RedirectPagedPointerLoads;
  FuseNegate;
  DropDeadImmediates;
  UseImmediatePush;      { must be last -- see the note in UseImmediatePush }

  while Code^.Prev <> nil do
    Code := Code^.Prev;

  while Code <> nil do
  begin
    if (Code^.Tag <> '') or (Code^.Instruction <> '') or (Code^.Comment <> '') then
      Emit0(Code^.Tag, Code^.Instruction, Code^.Comment);
    Temp := Code;
    Code := Code^.Next;
    Dispose(Temp);
  end;
end;

(**
 * True if Mark is still reachable by walking back from the list tail.
 *
 * The idiom "Old := Code; ...parse...; while Code <> Old do RemoveCode" is
 * already used in builtins.inc (High/Low) to discard speculatively emitted
 * code. It is unguarded there: if the list were flushed during the parse,
 * Old would never be reached and the loop would run past the head. Flush
 * only happens on a tagged Emit and expressions do not emit tags, so it has
 * not bitten -- but new callers should check first and fall back to the
 * runtime path rather than rely on that.
 *
 * Mark = nil means "the list was empty", which is reachable by definition.
 *)
function CodeReachable(Mark: PCode): Boolean;
var
  C: PCode;
begin
  C := Code;
  while (C <> nil) and (C <> Mark) do C := C^.Prev;
  CodeReachable := (C = Mark);
end;

function InstrIs(C: PCode; const S: String): Boolean;
begin
  InstrIs := (C <> nil) and (C^.Instruction = S);
end;

function InstrStarts(C: PCode; const S: String): Boolean;
begin
  InstrStarts := (C <> nil) and StartsWith(C^.Instruction, S);
end;

(**
 * Maps one of the six Scc mnemonics the code generator emits onto the
 * equivalent Bcc mnemonic, for Rule 14.
 *
 * Direct = True  : branch when the condition Scc tested is TRUE.
 * Direct = False : branch when it is FALSE (the inverted sense).
 *
 * Returns '' for anything not in the table, so the caller fails safe.
 *
 * The whole correctness argument for Rule 14 lives in this table, so it is
 * written out in full rather than derived. Reference Manual s6.7 and s6.8:
 * Scc and Bcc share the same 3-bit condition encoding, and all six forms
 * below test Z, N and V only -- none of them reads carry. The K16 carry
 * sense (6502-style, C=1 = no borrow) therefore does NOT come into it.
 * If SCS/SHS/SCC/SLO are ever emitted they must be added deliberately, with
 * the carry sense stated aloud first; they are absent here on purpose.
 *)
function SccToBcc(const Instruction: String; Direct: Boolean): String;
begin
  if      Instruction = 'SEQ    D0' then begin if Direct then SccToBcc := 'BEQ' else SccToBcc := 'BNE' end
  else if Instruction = 'SNE    D0' then begin if Direct then SccToBcc := 'BNE' else SccToBcc := 'BEQ' end
  else if Instruction = 'SLT    D0' then begin if Direct then SccToBcc := 'BLT' else SccToBcc := 'BGE' end
  else if Instruction = 'SGT    D0' then begin if Direct then SccToBcc := 'BGT' else SccToBcc := 'BLE' end
  else if Instruction = 'SLE    D0' then begin if Direct then SccToBcc := 'BLE' else SccToBcc := 'BGT' end
  else if Instruction = 'SGE    D0' then begin if Direct then SccToBcc := 'BGE' else SccToBcc := 'BLT' end
  (* Part 24: the unsigned pair, added deliberately as the old comment asked.
     Both are pure carry tests, so inverting one is simply the other carry
     polarity -- no N/V reasoning is involved, unlike the signed rows above.
     Spelled BHS/BLO rather than BCS/BCC: identical encoding (RM s6.8), but
     the name says what is meant at the point of use. *)
  else if Instruction = 'SHS    D0' then begin if Direct then SccToBcc := 'BHS' else SccToBcc := 'BLO' end
  else if Instruction = 'SLO    D0' then begin if Direct then SccToBcc := 'BLO' else SccToBcc := 'BHS' end
  else SccToBcc := '';
end;

function DoOptimize: Boolean;
var
  Prev, Prev2, Prev3: PCode;
  PushReg, PopReg, Bcc: String;
begin
  DoOptimize := True;

  if Code = nil then begin DoOptimize := False; Exit; end;
  Prev := Code^.Prev;
  if Prev = nil then begin DoOptimize := False; Exit; end;
  Prev2 := Prev^.Prev;
  if Prev2 <> nil then Prev3 := Prev2^.Prev else Prev3 := nil;

  { --- Rule 1: PUSH Rn, XYm / POP Rn, XYm -> delete both (same reg, same stack) --- }
  if InstrStarts(Prev, 'PUSH ') and InstrStarts(Code, 'POP ') then
  begin
    PushReg := TrimStr(Copy(Prev^.Instruction, 6, 255));
    PopReg  := TrimStr(Copy(Code^.Instruction,  5, 255));
    if PushReg = PopReg then
    begin
      RemoveCode;
      RemoveCode;
      Exit;
    end;
  end;

  { --- Rule 2: PUSH D0, XY3 / POP D1, XY3 -> MOVE D1, D0 --- }
  if InstrIs(Prev, 'PUSH   D0, XY3') and InstrIs(Code, 'POP    D1, XY3') then
  begin
    Prev^.Instruction := 'MOVE   D1, D0';
    Prev^.Comment := '';
    RemoveCode;
    Exit;
  end;

  { --- Rule 3: PUSH D1, XY3 / POP D0, XY3 -> MOVE D0, D1 --- }
  if InstrIs(Prev, 'PUSH   D1, XY3') and InstrIs(Code, 'POP    D0, XY3') then
  begin
    Prev^.Instruction := 'MOVE   D0, D1';
    Prev^.Comment := '';
    RemoveCode;
    Exit;
  end;

  { --- Rule 4: LOADI D0, #x / PUSH D0, XY3 / POP D1, XY3 -> LOADI D1, #x --- }
  if (Prev2 <> nil) and InstrStarts(Prev2, 'LOADI  D0, #')
    and InstrIs(Prev, 'PUSH   D0, XY3') and InstrIs(Code, 'POP    D1, XY3') then
  begin
    Prev2^.Instruction := 'LOADI  D1, #' + Copy(Prev2^.Instruction, 13, 255);
    RemoveCode;
    RemoveCode;
    Exit;
  end;

  { --- Rule 5: LOADI D0, #x / MOVE D1, D0 -> LOADI D1, #x --- }
  if InstrStarts(Prev, 'LOADI  D0, #') and InstrIs(Code, 'MOVE   D1, D0') then
  begin
    Prev^.Instruction := 'LOADI  D1, #' + Copy(Prev^.Instruction, 13, 255);
    Prev^.Comment := '';
    RemoveCode;
    Exit;
  end;

  { --- Rule 6: LOADI D0, #x / MOVE X0, D0 -> LOADI X0, #x --- }
  if InstrStarts(Prev, 'LOADI  D0, #') and InstrIs(Code, 'MOVE   X0, D0') then
  begin
    Prev^.Instruction := 'LOADI  X0, #' + Copy(Prev^.Instruction, 13, 255);
    Prev^.Comment := '';
    RemoveCode;
    Exit;
  end;

  { --- Rule 7: pushfp / popfp -> delete both --- }
  if InstrIs(Prev, 'pushfp') and InstrIs(Code, 'popfp') then
  begin
    RemoveCode;
    RemoveCode;
    Exit;
  end;

  { --- Rule 8: PUSH D0, XY3 / POP D2, XY3 -> MOVE D2, D0 --- }
  if InstrIs(Prev, 'PUSH   D0, XY3') and InstrIs(Code, 'POP    D2, XY3') then
  begin
    Prev^.Instruction := 'MOVE   D2, D0'; Prev^.Comment := ''; RemoveCode; Exit;
  end;

  { --- Rule 9: PUSH D0, XY3 / POP D3, XY3 -> MOVE D3, D0 --- }
  if InstrIs(Prev, 'PUSH   D0, XY3') and InstrIs(Code, 'POP    D3, XY3') then
  begin
    Prev^.Instruction := 'MOVE   D3, D0'; Prev^.Comment := ''; RemoveCode; Exit;
  end;

  { --- Rule 10: LOADI D0, #x / PUSH D0, XY3 / POP D2, XY3 -> LOADI D2, #x --- }
  if (Prev2 <> nil) and InstrStarts(Prev2, 'LOADI  D0, #')
    and InstrIs(Prev, 'PUSH   D0, XY3') and InstrIs(Code, 'POP    D2, XY3') then
  begin
    Prev2^.Instruction := 'LOADI  D2, #' + Copy(Prev2^.Instruction, 13, 255);
    RemoveCode; RemoveCode; Exit;
  end;

  { --- Rule 11: LOADI D0, #x / PUSH D0, XY3 / POP D3, XY3 -> LOADI D3, #x --- }
  if (Prev2 <> nil) and InstrStarts(Prev2, 'LOADI  D0, #')
    and InstrIs(Prev, 'PUSH   D0, XY3') and InstrIs(Code, 'POP    D3, XY3') then
  begin
    Prev2^.Instruction := 'LOADI  D3, #' + Copy(Prev2^.Instruction, 13, 255);
    RemoveCode; RemoveCode; Exit;
  end;

  { --- Rule 12: redundant LOADP D0,Y3,[#display+N] after PUSH when same N --- }
  if (Prev2 <> nil) and InstrStarts(Code, 'LOADP  D0, Y3, [#display+')
    and InstrIs(Prev, 'PUSH   D0, XY3')
    and InstrStarts(Prev2, 'LOADP  D0, Y3, [#display+')
    and (Code^.Instruction = Prev2^.Instruction) then
  begin
    RemoveCode; Exit;
  end;

  { --- Rule 13: PUSH Dn, XY3 / LOADI Dm, #x / POP Dn, XY3 -> LOADI Dm, #x  (m <> n) ---
    The mirror image of Rules 4/10/11, which have the LOADI *before* the PUSH.
    Safe because LOADI Dm is flag-transparent (Reference Manual s15.3, Move/Load/Store),
    reads no memory, is not control flow, and writes only Dm -- so with m <> n the
    pushed value is never disturbed and the PUSH/POP pair is pure overhead.

    Deliberately a WHITELIST on the intervening instruction: anything other than
    LOADI Dm is left alone rather than reasoned about. Requiring 'D' also excludes
    'LOADI  X3, #' automatically, which would write the stack pointer.
    The ', XY3' position test excludes the D123 group form and non-XY3 stacks.

    Prev's content is copied UP into Prev2 because RemoveCode can only pop the tail.
    Prev2^.Tag is preserved: Emit flushes before appending a tagged element, so only
    the list head can carry a Tag, and the label must stay on the surviving
    instruction (execution from that label is equivalent once the pair is gone). }
  if (Prev2 <> nil)
    and InstrStarts(Prev2, 'PUSH   D') and InstrStarts(Prev, 'LOADI  D')
    and InstrStarts(Code, 'POP    D')
    and (Prev^.Tag = '') and (Code^.Tag = '') then
  begin
    PushReg := TrimStr(Copy(Prev2^.Instruction, 6, 255));   { 'Dn, XY3' }
    PopReg  := TrimStr(Copy(Code^.Instruction,  5, 255));   { 'Dn, XY3' }
    if (PushReg = PopReg) and (Copy(PushReg, 3, 5) = ', XY3')
      and (Copy(Prev^.Instruction, 8, 2) <> Copy(PushReg, 1, 2)) then
    begin
      Prev2^.Instruction := Prev^.Instruction;
      Prev2^.Comment     := Prev^.Comment;
      RemoveCode;                          { the POP }
      RemoveCode;                          { the LOADI, now living in Prev2 }
      Exit;
    end;
  end;

  { --- Rule 14: Scc / AND #1 / CMP #0 / Bcc -> a single Bcc ------------------
    Every conditional in the language currently materialises a boolean and
    then compares it back to zero:

        CMP    D0, D1        flags set here...
        SEQ    D0            ...and Scc does not disturb them (RM s6.7)
        AND    D0, #1        $FFFF/$0000 -> 1/0
        CMP    D0, #0        ...compare the boolean back to zero
        BEQ.L  target

    The flags from the first CMP are still live at the branch, so the middle
    three instructions are dead. Collapsing to

        CMP    D0, D1
        BNE.L  target

    saves 3 instructions, 4 words and 10 cycles at every conditional.
    Statically rare, dynamically everywhere: the chain sits inside every if,
    while, repeat-until and for test, and both for-loop tests execute once
    per iteration.

    By the time the branch is appended, Rule 1 has already removed the
    PUSH D0 / POP D0 pair that EmitRelOp and EmitJumpIf produce between the
    AND and the CMP, so the four elements are adjacent.

    Guards, in order of how much they matter:

    - Prev3^.Prev must be a CMP. This is what makes the flag-liveness
      argument LOCAL: it asserts the flags the surviving branch will read
      were set by an adjacent compare with nothing in between, rather than
      assuming it from how EmitRelOp happens to be written today. All
      producers satisfy it -- EmitRelOp emits CMP D0,D1 (or CMP D1,D0 for
      the Part 24 unsigned > and <=, where the operands are swapped instead
      of the condition being changed) and builtins.inc's Assigned() emits
      CMP D0,#0, each immediately before the Scc. The guard tests only that
      a CMP is adjacent, so the swapped shape needs nothing here.
    - Exact string match on all three doomed instructions, and a whitelist
      (SccToBcc) on the Scc. Anything unrecognised leaves the code alone.
    - Empty Tag on Prev2, Prev and Code: a label between the compare and the
      branch would mean control can arrive with different flags. Prev3 keeps
      whatever Tag it had -- it is the surviving instruction. }
  if (Prev3 <> nil) and (Prev3^.Prev <> nil)
    and InstrStarts(Prev3^.Prev, 'CMP')
    and (InstrStarts(Code, 'BEQ.L  ') or InstrStarts(Code, 'BNE.L  '))
    and InstrIs(Prev,  'CMP    D0, #0')
    and InstrIs(Prev2, 'AND    D0, #1')
    and (Prev2^.Tag = '') and (Prev^.Tag = '') and (Code^.Tag = '') then
  begin
    { BNE.L branches when the boolean is true, so it wants the direct sense;
      BEQ.L branches when it is false and wants the inverted one. }
    Bcc := SccToBcc(Prev3^.Instruction, InstrStarts(Code, 'BNE.L  '));
    if Bcc <> '' then
    begin
      Prev3^.Instruction := Bcc + '.L  ' + Copy(Code^.Instruction, 8, 255);
      Prev3^.Comment     := 'fused Scc + branch';
      RemoveCode;                          { the Bcc          }
      RemoveCode;                          { the CMP D0, #0   }
      RemoveCode;                          { the AND D0, #1   }
      Exit;
    end;
  end;

  { --- Rule 17: POP Dn / PUSH Dn / PUSH Dn -> LOADD Dn, [XY3] / PUSH Dn -----
    The counted-loop emitter duplicates its limit by popping it and pushing it
    back twice:

        POP    D1, XY3          4 cyc     \
        PUSH   D1, XY3          5 cyc      |  14 cycles to leave D1 = TOS
        PUSH   D1, XY3          5 cyc     /   and one extra copy pushed

    Peeking does the same job without moving the stack pointer at all:

        LOADD  D1, [XY3]        2 cyc     X3 is the top word (full descending,
        PUSH   D1, XY3          5 cyc     PUSH pre-decrements), so [XY3] IS TOS

    Both leave D1 = the old TOS and exactly one extra copy on the stack, so
    the net stack effect is identical. 7 cycles instead of 14, one instruction
    fewer -- and this sits in the loop-control block, so it is paid on every
    iteration rather than once.

    Flag-neutral in both directions: stack operations are "not affected
    (except POP SR)" per Reference Manual s6.12, and LOADD is flag-transparent.

    Prev2 survives and keeps any Tag: entering at that label runs the peek
    instead of the pop, and the stack effect is the same either way. }
  if (Prev2 <> nil)
    and InstrStarts(Prev2, 'POP    D') and InstrStarts(Prev, 'PUSH   D')
    and InstrStarts(Code, 'PUSH   D')
    and (Prev^.Tag = '') and (Code^.Tag = '') then
  begin
    PopReg  := TrimStr(Copy(Prev2^.Instruction, 5, 255));   { 'Dn, XY3' }
    PushReg := TrimStr(Copy(Prev^.Instruction,  6, 255));
    if (PopReg = PushReg)
      and (PushReg = TrimStr(Copy(Code^.Instruction, 6, 255)))
      and (Copy(PushReg, 3, 5) = ', XY3') then
    begin
      Prev2^.Instruction := 'LOADD  ' + Copy(PushReg, 1, 2) + ', [XY3]';
      Prev2^.Comment     := 'peek limit';
      RemoveCode;                          { the second PUSH }
      Exit;
    end;
  end;

  DoOptimize := False;
end;
