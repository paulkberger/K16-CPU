unit emu_opcodes;
{
  K16 Emulator - Instruction Dispatch Table and Exec Handlers
  Two-level dispatch: DispatchTable[Opcode, Mode] - single indirect call per instruction.
  Part of the K16 homebrew CPU project.
}

{$mode Delphi}
{$H+}

interface

uses
  SysUtils, emu_types, emu_mem, emu_cpu, emu_alu, emu_decode;

type
  TExecProc = procedure(const D: TDecodedInstr);

var
  DispatchTable : array[0..$1F, 0..3] of TExecProc;

procedure InitDispatch;

implementation

// ===========================================================================
// Illegal / unimplemented
// ===========================================================================

procedure ExecIllegal(const D: TDecodedInstr);
var
  msg : string;
  i   : Integer;
begin
  msg := Format('ILLEGAL op=$%2.2X mode=%d PC=$%6.6X',
                [D.Opcode, D.Mode, (CPU.PC - 2) and ADDR_MASK]);
  if Assigned(IO) then
  begin
    IO^.WriteByte(TERM_ADDR, 10);
    for i := 1 to Length(msg) do
      IO^.WriteByte(TERM_ADDR, Byte(msg[i]));
    IO^.WriteByte(TERM_ADDR, 10);
  end;
  CPU.Halted   := True;
  CPU.HaltCode := $FE;   { $FE = illegal opcode sentinel }
end;

// ===========================================================================
// $00 MISC
// ===========================================================================

procedure ExecNOP(const D: TDecodedInstr);
begin
  if D.Opcode = 0 then ;  { suppress unused warning }
end;

procedure ExecHALT(const D: TDecodedInstr);
begin
  CPU.HaltCode := D.Operand and $FF;   { IR[7:0] = halt code }
  CPU.Halted   := True;
end;

procedure ExecNEG(const D: TDecodedInstr);
{ NEG dst, src — dst=rf4 IR[8:5]=(opr shr 5)&$F; src=rf4 IR[4:1]=(opr shr 1)&$F }
var Dd, Ds: Byte; vs: TWord;
begin
  Dd := (D.Operand shr 5) and $0F;
  Ds := (D.Operand shr 1) and $0F;
  case Ds of
    0..3:  vs := CPU.D[Ds];
    4..7:  vs := CPU.X[Ds-4];
    8..11: vs := CPU.Y[Ds-8];
    else   vs := 0;
  end;
  vs := AluNeg(vs);
  case Dd of
    0..3:  CPU.D[Dd]   := vs;
    4..7:  CPU.X[Dd-4] := vs;
    8..11: CPU.Y[Dd-8] := vs and $FF;
  end;
end;

// ===========================================================================
// $01 LOOKUP  - IR[4:0]=op, IR[8:5]=Dn
// All 4 modes map here.
// ===========================================================================

procedure ExecLOOKUP(const D: TDecodedInstr);
{ LOOKUP: dest D reg = IR[10:9] = D.Mode; page (operation) = IR[7:0] = D.Operand and $FF
  Page values from actual assembled ROM addresses (not ISA doc logical pages): }
var
  Dn : Byte;
  pg : Byte;
  v  : TWord;
begin
  Dn := D.Mode and 3;          { destination D0-D3 from IR[10:9] }
  pg := D.Operand and $FF;     { lookup page = full IMM8 }
  v  := CPU.D[Dn];
  case pg of
    $E0: CPU.D[Dn] := LookupSHL (v);    { SHL  — shift left 1 }
    $E2: CPU.D[Dn] := LookupSHR (v);    { SHR  — shift right logical }
    $E4: CPU.D[Dn] := LookupASR (v);    { ASR  — shift right arithmetic }
    $E6: CPU.D[Dn] := LookupROL (v);    { ROL  }
    $E8: CPU.D[Dn] := LookupROR (v);    { ROR  }
    $EA: CPU.D[Dn] := LookupSWAPB(v);   { SWAPB }
    $EC: CPU.D[Dn] := LookupHIGH(v);   { HIGH — extract high byte }
    $EE: CPU.D[Dn] := LookupLOW (v);   { LOW  — extract low byte }
    $F0: CPU.D[Dn] := LookupSHR4(v);   { SHR4 — shift right 4 }
    $F2: CPU.D[Dn] := LookupSHL4(v);   { SHL4 — shift left 4 }
    $F4: CPU.D[Dn] := LookupASR4(v);   { ASR4 }
    $F6: CPU.D[Dn] := LookupASR8(v);   { ASR8 }
    $F8: CPU.D[Dn] := LookupMULB(v);   { MULB }
    $FA: CPU.D[Dn] := LookupRECIP(v);  { RECIP }
  else
    { unknown page — treat as NOP (custom user table not emulated) }
  end;
end;

// ===========================================================================
// $02 INC/DEC - 24-bit XY arithmetic; IR[6:5]=XY pair; IR[4:0]=IMM5 step
// Hardware: step 1 writes SR with 16-bit X result flags (FLAGSLoad=true).
// Carry from X addition propagates into Y via cmADC in step 3.
// SR is set from the 16-bit X+imm result — not meaningful as a 24-bit flag,
// but must be written to match hardware behaviour.
// ===========================================================================

procedure ExecINC_Word(const D: TDecodedInstr);
{ INC XYn, #imm5 — XYn += imm5 (24-bit with carry into Y) }
var
  n    : Byte;
  imm  : Byte;
  oldX : TWord;
  newX : LongWord;
  newXY: TAddr;
begin
  n    := (D.Operand shr 5) and 3;
  imm  := D.Operand and $1F;
  oldX := CPU.X[n];
  newX := LongWord(oldX) + imm;
  { Carry into Y }
  newXY := (TAddr(CPU.Y[n]) shl 16) or (newX and $FFFF);
  if newX > $FFFF then
    newXY := (newXY + $010000) and ADDR_MASK;
  CPU.XYSet(n, newXY);
  { SR flags from the 16-bit X+imm result (hardware FLAGSLoad step 1) }
  CPU.SR.Flags.C := newX > $FFFF;
  CPU.SR.Flags.Z := (newX and $FFFF) = 0;
  CPU.SR.Flags.N := (newX and $8000) <> 0;
  CPU.SR.Flags.V := ((not (oldX xor imm)) and (oldX xor Word(newX)) and $8000) <> 0;
end;

procedure ExecDEC_Word(const D: TDecodedInstr);
{ DEC XYn, #imm5 — XYn -= imm5 (24-bit with borrow from Y) }
var
  n    : Byte;
  imm  : Byte;
  oldX : TWord;
  newX : LongWord;
  newXY: TAddr;
begin
  n    := (D.Operand shr 5) and 3;
  imm  := D.Operand and $1F;
  oldX := CPU.X[n];
  newX := LongWord(oldX) - imm;
  { Borrow from Y if X underflowed }
  newXY := (TAddr(CPU.Y[n]) shl 16) or (newX and $FFFF);
  if newX > $FFFF then  { unsigned underflow → borrow }
    newXY := (newXY - $010000) and ADDR_MASK;
  CPU.XYSet(n, newXY);
  { SR flags from the 16-bit X-imm result (hardware FLAGSLoad step 2) }
  CPU.SR.Flags.C := newX <= $FFFF;  { C=1 = no borrow (K16 SUB convention) }
  CPU.SR.Flags.Z := (newX and $FFFF) = 0;
  CPU.SR.Flags.N := (newX and $8000) <> 0;
  CPU.SR.Flags.V := ((oldX xor imm) and (oldX xor Word(newX)) and $8000) <> 0;
end;

// ===========================================================================
// $03 LEA - IR[8:7]=destXY, IR[6:5]=srcXY or Dn
// ===========================================================================

procedure ExecLEA_XYImm(const D: TDecodedInstr);
{ LEA XYd, [XYs] — plain copy (mode 0, D field = 0)
  LEA XYd, [XYs+Dn] — also mode 0 when D bits nonzero; same encoding as mode 1 }
var Xd, Xs, Dn: Byte;
begin
  Xd := (D.Operand shr 7) and 3;
  Xs := (D.Operand shr 5) and 3;
  Dn := (D.Operand shr 3) and 3;
  if D.Operand and $18 = 0 then
    CPU.XYSet(Xd, CPU.XYGet(Xs))           { plain copy — no D bits set }
  else
    CPU.XYSet(Xd, (CPU.XYGet(Xs) + CPU.D[Dn]) and ADDR_MASK);  { +Dn }
end;

procedure ExecLEA_XYReg(const D: TDecodedInstr);
{ LEA XYd, XYs+Dn - IR[4:3]=Dn as byte offset }
var
  Xd, Xs, Dn: Byte;
begin
  Xd := (D.Operand shr 7) and 3;
  Xs := (D.Operand shr 5) and 3;
  Dn := (D.Operand shr 3) and 3;
  CPU.XYSet(Xd, (CPU.XYGet(Xs) + CPU.D[Dn]) and ADDR_MASK);
end;

procedure ExecLEA_PCRel(const D: TDecodedInstr);
{ LEA XYd, PC+#imm16 (signed) }
var
  Xd  : Byte;
  off : Integer;
begin
  Xd  := (D.Operand shr 7) and 3;
  off := SmallInt(D.Imm16);
  CPU.XYSet(Xd, (CPU.PC + TAddr(off)) and ADDR_MASK);
end;

procedure ExecLEA_Copy(const D: TDecodedInstr);
{ LEA XYd, [XYs+#imm5] — mode 3: byte offset in IR[4:0] }
var Xd, Xs: Byte; imm5: Integer;
begin
  Xd   := (D.Operand shr 7) and 3;
  Xs   := (D.Operand shr 5) and 3;
  imm5 := D.Operand and $1F;
  CPU.XYSet(Xd, (CPU.XYGet(Xs) + TAddr(imm5)) and ADDR_MASK);
end;

// ===========================================================================
// $04 Scc - IR[4:2]=condition; all modes use same handler
// IR[8:7]=Dd (destination data reg)
// ===========================================================================

function EvalCond(cond: Byte): Boolean;
var F: TFlags;
begin
  F := CPU.SR.Flags;
  case cond of
    0: Result := F.Z;                                         { EQ/Z }
    1: Result := not F.Z;                                     { NE/NZ }
    2: Result := F.C;                                         { CS/HS }
    3: Result := not F.C;                                     { CC/LO }
    4: Result := F.N xor F.V;                                 { LT }
    5: Result := (not F.Z) and (not (F.N xor F.V));           { GT }
    6: Result := not (F.N xor F.V);                           { GE }
    7: Result := F.Z or (F.N xor F.V);                        { LE }
  else Result := False;
  end;
end;

procedure ExecScc(const D: TDecodedInstr);
{ Scc: cond=IR[7:5]=(opr shr 5)&7; dst=rf4 IR[4:1]=(opr shr 1)&$0F }
var
  Dd  : Byte;
  cond: Byte;
begin
  cond := (D.Operand shr 5) and 7;
  Dd   := (D.Operand shr 1) and $0F;
  if EvalCond(cond) then
    case Dd of
      0..3:  CPU.D[Dd]    := 1;
      4..7:  CPU.X[Dd-4]  := 1;
      8..11: CPU.Y[Dd-8]  := 1;
    end
  else
    case Dd of
      0..3:  CPU.D[Dd]    := 0;
      4..7:  CPU.X[Dd-4]  := 0;
      8..11: CPU.Y[Dd-8]  := 0;
    end;
end;

// ===========================================================================
// $05 MOVE - sub-form in IR[8:0]; all modes use same handler
// Sub-forms (from reference manual):
//   IR[8:7]=00: MOVE Dd, Ds        (D→D)
//   IR[8:7]=01: MOVE Xd, Ds        (D→X)
//   IR[8:7]=10: MOVE Dd, Xs        (X→D)
//   IR[8:7]=11: MOVE Xd, Xs        (X→X)
// Additional forms encoded in lower bits - simplified implementation:
//   IR[8]=1, IR[6:5]=dest, IR[4:3]=src
// Full decoding follows the reference manual encoding.
// ===========================================================================

procedure ExecMOVE(const D: TDecodedInstr);
{ MOVE/SWAP - mode selects operation, rf4 fields select registers
  Mode 0: MOVE dst(rf4 bits 8:5), src(rf4 bits 4:1) — IR bit 0 always 0
  Mode 1: MOVE dst(rf4 bits 8:5), src(rf4 bits 4:1) — X/Y source via T16
  Mode 2: SWAP reg(rf4 bits 8:5), reg(rf4 bits 4:1)
  Mode 3: SWAP reg(rf4 bits 8:5), reg(rf4 bits 4:1) }
var
  dst, src : Byte;
  tmp      : TWord;

  function ReadRf4(r: Byte): TWord;
  begin
    case r of
      0..3:  Result := CPU.D[r];
      4..7:  Result := CPU.X[r-4];
      8..11: Result := CPU.Y[r-8];
      12:    Result := CPU.ORDB;
      14:    Result := CPU.PC shr 16;   { PCH }
      15:    Result := CPU.PC and $FFFF; { PCL }
    else     Result := 0;
    end;
  end;

  procedure WriteRf4(r: Byte; v: TWord);
  begin
    case r of
      0..3:  CPU.D[r]   := v;
      4..7:  CPU.X[r-4] := v;
      8..11: CPU.Y[r-8] := v and $FF;
      12:    CPU.ORDB   := v;
      14:    CPU.PC     := (CPU.PC and $FFFF) or (TAddr(v and $FF) shl 16);
      15:    CPU.PC     := (CPU.PC and $FF0000) or v;
    end;
  end;

begin
  dst := (D.Operand shr 5) and $0F;
  case D.Mode of
    0: begin  { MOVE dst, src — src is rf4 at bits 4:1 (IR bit 0 always 0) }
         src := (D.Operand shr 1) and $0F;
         WriteRf4(dst, ReadRf4(src));
       end;
    1: begin  { MOVE dst, src — both rf4 }
         src := (D.Operand shr 1) and $0F;
         WriteRf4(dst, ReadRf4(src));
       end;
    2,3: begin  { SWAP }
         src := (D.Operand shr 1) and $0F;
         tmp := ReadRf4(dst);
         WriteRf4(dst, ReadRf4(src));
         WriteRf4(src, tmp);
       end;
  end;
end;

// ===========================================================================
// $06 PUSH
// ===========================================================================

procedure ExecPUSH_Single(const D: TDecodedInstr);
{ PUSH reg, XYsp - rf4 at bits 8:5 (D0-D3=0-3, X0-X3=4-7, Y0-Y3=8-11); sp=bits 2:1 }
var rf4, sp: Byte; v: TWord;
begin
  rf4 := (D.Operand shr 5) and $0F;
  sp  := (D.Operand shr 1) and 3;
  case rf4 of
    0..3:  v := CPU.D[rf4];
    4..7:  v := CPU.X[rf4-4];
    8..11: v := CPU.Y[rf4-8];
  else     v := 0;
  end;
  CPU.XYSet(sp, CPU.XYGet(sp) - 2);
  MemWriteWord(CPU.XYGet(sp), v);
end;

procedure ExecPUSH_Group(const D: TDecodedInstr);
{ PUSHDG - pushes D0,D1,D2,D3 in that order (D0 at lowest address).
  Microcode: step2=D0, step5=D1, step8=D2, step11=D3.
  sp = IR[2:1] }
var sp: Byte; i: Integer;
begin
  sp := (D.Operand shr 1) and 3;
  for i := 0 to 3 do
  begin
    CPU.XYSet(sp, CPU.XYGet(sp) - 2);
    MemWriteWord(CPU.XYGet(sp), CPU.D[i]);
  end;
end;

procedure ExecPUSH_XY(const D: TDecodedInstr);
{ PUSH XYn, XYsp - IR[6:5]=XYn, IR[2:1]=sp; Y at lower addr, X at higher }
var n, sp: Byte;
begin
  n  := (D.Operand shr 5) and 3;
  sp := (D.Operand shr 1) and 3;
  { Push X first (higher addr), then Y (lower addr) }
  CPU.XYSet(sp, CPU.XYGet(sp) - 2);
  MemWriteWord(CPU.XYGet(sp), CPU.X[n]);
  CPU.XYSet(sp, CPU.XYGet(sp) - 2);
  MemWriteWord(CPU.XYGet(sp), CPU.Y[n]);  { zero-extended word }
end;

procedure ExecPUSH_Imm(const D: TDecodedInstr);
{ PUSH #imm5, XYsp - zero-extended 5-bit immediate }
var imm5, sp: Byte;
begin
  imm5 := D.Operand and $1F;
  sp   := (D.Operand shr 1) and 3;
  CPU.XYSet(sp, CPU.XYGet(sp) - 2);
  MemWriteWord(CPU.XYGet(sp), imm5);
end;

// ===========================================================================
// $07 POP
// ===========================================================================

procedure ExecPOP_Single(const D: TDecodedInstr);
{ POP reg, XYsp - rf4 at bits 8:5; sp=bits 2:1 }
var rf4, sp: Byte; v: TWord;
begin
  rf4 := (D.Operand shr 5) and $0F;
  sp  := (D.Operand shr 1) and 3;
  v   := MemReadWord(CPU.XYGet(sp));
  CPU.XYSet(sp, CPU.XYGet(sp) + 2);
  case rf4 of
    0..3:  CPU.D[rf4]   := v;
    4..7:  CPU.X[rf4-4] := v;
    8..11: CPU.Y[rf4-8] := v and $FF;
  end;
end;

procedure ExecPOP_Group(const D: TDecodedInstr);
{ POPDG - pops into D3,D2,D1,D0 in that order (D3 gets lowest address).
  Microcode: step1=mem→D3, step3=mem→D2, step5=mem→D1, step7=mem→D0.
  sp = IR[2:1] }
var sp: Byte; i: Integer;
begin
  sp := (D.Operand shr 1) and 3;
  for i := 3 downto 0 do
  begin
    CPU.D[i] := MemReadWord(CPU.XYGet(sp));
    CPU.XYSet(sp, CPU.XYGet(sp) + 2);
  end;
end;

procedure ExecPOP_XY(const D: TDecodedInstr);
{ POP XYn, XYsp - Y at lower addr popped first, then X }
var n, sp: Byte;
begin
  n  := (D.Operand shr 5) and 3;
  sp := (D.Operand shr 1) and 3;
  CPU.Y[n] := MemReadWord(CPU.XYGet(sp)) and $FF;
  CPU.XYSet(sp, CPU.XYGet(sp) + 2);
  CPU.X[n] := MemReadWord(CPU.XYGet(sp));
  CPU.XYSet(sp, CPU.XYGet(sp) + 2);
end;

procedure ExecPOPD(const D: TDecodedInstr);
{ POPD / discard - pop and discard one word }
var sp: Byte;
begin
  sp := (D.Operand shr 1) and 3;
  CPU.XYSet(sp, CPU.XYGet(sp) + 2);
end;

// ===========================================================================
// ALU helpers  ($08–$0F, $10)
// ===========================================================================

procedure ALU_RR(op: TAluOp; const D: TDecodedInstr); inline;
{ dst = rf4 at bits 8:5; src = rf4 at bits 4:1 (IR bit 0 always 0) }
var Dd, Ds: Byte; vd, vs, res: TWord;
begin
  Dd := (D.Operand shr 5) and $0F;
  Ds := (D.Operand shr 1) and $0F;
  case Dd of
    0..3:  vd := CPU.D[Dd];
    4..7:  vd := CPU.X[Dd-4];
    8..11: vd := CPU.Y[Dd-8];
    12:    vd := CPU.ORDB;
    else   vd := 0;
  end;
  case Ds of
    0..3:  vs := CPU.D[Ds];
    4..7:  vs := CPU.X[Ds-4];
    8..11: vs := CPU.Y[Ds-8];
    12:    vs := CPU.ORDB;
    else   vs := 0;
  end;
  res := DoAluOp(op, vd, vs);
  case Dd of
    0..3:  CPU.D[Dd]    := res;
    4..7:  CPU.X[Dd-4]  := res;
    8..11: CPU.Y[Dd-8]  := res and $FF;
    12:    CPU.ORDB      := res;
  end;
end;

procedure ALU_Imm5(op: TAluOp; const D: TDecodedInstr); inline;
{ dst = rf4 at bits 8:5 (D0-D3=0-3, X0-X3=4-7, Y0-Y3=8-11); imm5 = bits 4:0 }
var rf4: Byte; imm5, v: TWord;
begin
  rf4  := (D.Operand shr 5) and $0F;
  imm5 := D.Operand and $1F;
  case rf4 of
    0..3:  begin v := DoAluOp(op, CPU.D[rf4],   imm5); CPU.D[rf4]   := v; end;
    4..7:  begin v := DoAluOp(op, CPU.X[rf4-4], imm5); CPU.X[rf4-4] := v; end;
    8..11: begin v := DoAluOp(op, CPU.Y[rf4-8], imm5); CPU.Y[rf4-8] := v and $FF; end;
  end;
end;

procedure ALU_XReg(op: TAluOp; const D: TDecodedInstr); inline;
{ ALU dst, [XYn] - dst=rf4 bits 8:5; XY=bits 2:1 (bit 0 always 0) }
var Dd, Xs: Byte; vd, res: TWord;
begin
  Dd := (D.Operand shr 5) and $0F;
  Xs := (D.Operand shr 1) and 3;
  case Dd of
    0..3:  vd := CPU.D[Dd];
    4..7:  vd := CPU.X[Dd-4];
    8..11: vd := CPU.Y[Dd-8];
    else   vd := 0;
  end;
  res := DoAluOp(op, vd, MemReadWord(CPU.XYGet(Xs)));
  case Dd of
    0..3:  CPU.D[Dd]   := res;
    4..7:  CPU.X[Dd-4] := res;
    8..11: CPU.Y[Dd-8] := res and $FF;
  end;
end;

procedure ALU_Imm16(op: TAluOp; const D: TDecodedInstr); inline;
{ dst = rf4 at bits 8:5; imm16 = D.Imm16 }
var rf4: Byte; v: TWord;
begin
  rf4 := (D.Operand shr 5) and $0F;
  case rf4 of
    0..3:  begin v := DoAluOp(op, CPU.D[rf4],   D.Imm16); CPU.D[rf4]   := v; end;
    4..7:  begin v := DoAluOp(op, CPU.X[rf4-4], D.Imm16); CPU.X[rf4-4] := v; end;
    8..11: begin v := DoAluOp(op, CPU.Y[rf4-8], D.Imm16); CPU.Y[rf4-8] := v and $FF; end;
  end;
end;

procedure ExecADD_RR   (const D: TDecodedInstr); begin ALU_RR   (aopADD, D); end;
procedure ExecADD_Imm5 (const D: TDecodedInstr); begin ALU_Imm5 (aopADD, D); end;
procedure ExecADD_XReg (const D: TDecodedInstr); begin ALU_XReg (aopADD, D); end;
procedure ExecADD_Imm16(const D: TDecodedInstr); begin ALU_Imm16(aopADD, D); end;

procedure ExecADC_RR   (const D: TDecodedInstr); begin ALU_RR   (aopADC, D); end;
procedure ExecADC_Imm5 (const D: TDecodedInstr); begin ALU_Imm5 (aopADC, D); end;
procedure ExecADC_XReg (const D: TDecodedInstr); begin ALU_XReg (aopADC, D); end;
procedure ExecADC_Imm16(const D: TDecodedInstr); begin ALU_Imm16(aopADC, D); end;

procedure ExecSUB_RR   (const D: TDecodedInstr); begin ALU_RR   (aopSUB, D); end;
procedure ExecSUB_Imm5 (const D: TDecodedInstr); begin ALU_Imm5 (aopSUB, D); end;
procedure ExecSUB_XReg (const D: TDecodedInstr); begin ALU_XReg (aopSUB, D); end;
procedure ExecSUB_Imm16(const D: TDecodedInstr); begin ALU_Imm16(aopSUB, D); end;

procedure ExecSBC_RR   (const D: TDecodedInstr); begin ALU_RR   (aopSBC, D); end;
procedure ExecSBC_Imm5 (const D: TDecodedInstr); begin ALU_Imm5 (aopSBC, D); end;
procedure ExecSBC_XReg (const D: TDecodedInstr); begin ALU_XReg (aopSBC, D); end;
procedure ExecSBC_Imm16(const D: TDecodedInstr); begin ALU_Imm16(aopSBC, D); end;

procedure ExecAND_RR   (const D: TDecodedInstr); begin ALU_RR   (aopAND, D); end;
procedure ExecAND_Imm5 (const D: TDecodedInstr); begin ALU_Imm5 (aopAND, D); end;
procedure ExecAND_XReg (const D: TDecodedInstr); begin ALU_XReg (aopAND, D); end;
procedure ExecAND_Imm16(const D: TDecodedInstr); begin ALU_Imm16(aopAND, D); end;

procedure ExecOR_RR    (const D: TDecodedInstr); begin ALU_RR   (aopOR,  D); end;
procedure ExecOR_Imm5  (const D: TDecodedInstr); begin ALU_Imm5 (aopOR,  D); end;
procedure ExecOR_XReg  (const D: TDecodedInstr); begin ALU_XReg (aopOR,  D); end;
procedure ExecOR_Imm16 (const D: TDecodedInstr); begin ALU_Imm16(aopOR,  D); end;

procedure ExecXOR_RR   (const D: TDecodedInstr); begin ALU_RR   (aopXOR, D); end;
procedure ExecXOR_Imm5 (const D: TDecodedInstr); begin ALU_Imm5 (aopXOR, D); end;
procedure ExecXOR_XReg (const D: TDecodedInstr); begin ALU_XReg (aopXOR, D); end;
procedure ExecXOR_Imm16(const D: TDecodedInstr); begin ALU_Imm16(aopXOR, D); end;

// NOT handlers - specialized because operand routing differs by mode
procedure ExecNOT_RR(const D: TDecodedInstr);
{ NOT dest, src — result = NOT(src) → dest }
var Dd, Ds: Byte; vs, res: TWord;
begin
  Dd := (D.Operand shr 5) and $0F;
  Ds := (D.Operand shr 1) and $0F;
  case Ds of
    0..3:  vs := CPU.D[Ds];
    4..7:  vs := CPU.X[Ds-4];
    8..11: vs := CPU.Y[Ds-8];
    12:    vs := CPU.ORDB;
    else   vs := 0;
  end;
  res := AluNot(vs);  { NOT the source operand }
  case Dd of
    0..3:  CPU.D[Dd]    := res;
    4..7:  CPU.X[Dd-4]  := res;
    8..11: CPU.Y[Dd-8]  := res and $FF;
    12:    CPU.ORDB     := res;
  end;
end;

procedure ExecNOT_Imm5(const D: TDecodedInstr);
{ NOT dest, #imm5 — result = NOT(imm5) → dest }
var rf4: Byte; imm5, res: TWord;
begin
  rf4  := (D.Operand shr 5) and $0F;
  imm5 := D.Operand and $1F;
  res  := AluNot(imm5);  { NOT the immediate operand }
  case rf4 of
    0..3:  CPU.D[rf4]   := res;
    4..7:  CPU.X[rf4-4] := res;
    8..11: CPU.Y[rf4-8] := res and $FF;
  end;
end;

procedure ExecNOT_XReg(const D: TDecodedInstr);
{ NOT dest, [XYn] — result = NOT(memory) → dest }
var Dd, Xs: Byte; memVal, res: TWord;
begin
  Dd := (D.Operand shr 5) and $0F;
  Xs := (D.Operand shr 1) and 3;
  memVal := MemReadWord(CPU.XYGet(Xs));
  res := AluNot(memVal);  { NOT the memory operand }
  case Dd of
    0..3:  CPU.D[Dd]   := res;
    4..7:  CPU.X[Dd-4] := res;
    8..11: CPU.Y[Dd-8] := res and $FF;
  end;
end;

procedure ExecNOT_Imm16(const D: TDecodedInstr);
{ NOT dest, #imm16 — result = NOT(imm16) → dest }
var rf4: Byte; res: TWord;
begin
  rf4 := (D.Operand shr 5) and $0F;
  res := AluNot(D.Imm16);  { NOT the immediate operand }
  case rf4 of
    0..3:  CPU.D[rf4]   := res;
    4..7:  CPU.X[rf4-4] := res;
    8..11: CPU.Y[rf4-8] := res and $FF;
  end;
end;

procedure ExecNOT_InPlace(const D: TDecodedInstr);
{ NOT dest — result = NOT(dest) → dest (in-place negation) }
var rf4: Byte; currentVal, res: TWord;
begin
  rf4 := (D.Operand shr 5) and $0F;
  case rf4 of
    0..3:  currentVal := CPU.D[rf4];
    4..7:  currentVal := CPU.X[rf4-4];
    8..11: currentVal := CPU.Y[rf4-8];
    else   currentVal := 0;
  end;
  res := AluNot(currentVal);  { NOT the current register value }
  case rf4 of
    0..3:  CPU.D[rf4]   := res;
    4..7:  CPU.X[rf4-4] := res;
    8..11: CPU.Y[rf4-8] := res and $FF;
  end;
end;

procedure ExecCMP_RR   (const D: TDecodedInstr);
{ CMP dst, src — dst=rf4 bits 8:5, src=rf4 bits 4:1 (IR bit 0 always 0) }
var Dd, Ds: Byte; vd, vs: TWord;
begin
  Dd := (D.Operand shr 5) and $0F;
  Ds := (D.Operand shr 1) and $0F;
  case Dd of
    0..3:  vd := CPU.D[Dd];
    4..7:  vd := CPU.X[Dd-4];
    8..11: vd := CPU.Y[Dd-8];
    12:    vd := CPU.ORDB;
    else   vd := 0;
  end;
  case Ds of
    0..3:  vs := CPU.D[Ds];
    4..7:  vs := CPU.X[Ds-4];
    8..11: vs := CPU.Y[Ds-8];
    12:    vs := CPU.ORDB;
    else   vs := 0;
  end;
  AluCmp(vd, vs);
end;
procedure ExecCMP_Imm5 (const D: TDecodedInstr);
{ dst=rf4 bits 8:5; imm5=bits 4:0 }
begin AluCmp(CPU.D[(D.Operand shr 5) and $0F], D.Operand and $1F); end;
procedure ExecCMP_XReg (const D: TDecodedInstr);
{ dst=rf4 bits 8:5; XY src=bits 2:1 }
begin AluCmp(CPU.D[(D.Operand shr 5) and $0F], MemReadWord(CPU.XYGet((D.Operand shr 1) and 3))); end;
procedure ExecCMP_Imm16(const D: TDecodedInstr);
{ dst=rf4 bits 8:5; imm16=word2 }
begin AluCmp(CPU.D[(D.Operand shr 5) and $0F], D.Imm16); end;

// ===========================================================================
// $11 Bcc
// ===========================================================================

procedure ExecBcc_Short(const D: TDecodedInstr);
{ Short branch: cond in IR[7:5], unsigned forward offset in IR[4:0] (bytes) }
var
  cond: Byte;
  off : TAddr;
begin
  cond := (D.Operand shr 5) and 7;
  off  := D.Operand and $1F;
  if EvalCond(cond) then
    CPU.PC := (CPU.PC + off) and ADDR_MASK;
end;

procedure ExecBcc_Long(const D: TDecodedInstr);
{ Long branch: cond in IR[7:5], signed 16-bit offset in Imm16 }
var
  cond: Byte;
  off : Integer;
begin
  cond := (D.Operand shr 5) and 7;
  off  := SmallInt(D.Imm16);
  if EvalCond(cond) then
    CPU.PC := TAddr(Integer(CPU.PC) + off) and ADDR_MASK;
end;

procedure ExecBRA_Short(const D: TDecodedInstr);
{ BRA short — mode 2, unconditional: always branch by unsigned 5-bit offset.
  Cond field in instruction is "don't care" for BRA — must NOT call EvalCond. }
var off: TAddr;
begin
  off := D.Operand and $1F;
  CPU.PC := (CPU.PC + off) and ADDR_MASK;
end;

procedure ExecBcc_LongMode3(const D: TDecodedInstr);
{ BRA.L / long unconditional branch: mode 3, signed 16-bit offset in Imm16 }
var
  off: Integer;
begin
  { Mode 3 = unconditional long branch (BRA.L) }
  off := SmallInt(D.Imm16);
  CPU.PC := TAddr(Integer(CPU.PC) + off) and ADDR_MASK;
end;

// ===========================================================================
// $12 JMP
// ===========================================================================

procedure ExecJMP24(const D: TDecodedInstr);
{ JMP24 - IR[7:0]=bank byte, Imm16=low 16 }
begin
  CPU.PC := ((TAddr(D.Operand and $FF) shl 16) or D.Imm16) and ADDR_MASK;
end;

procedure ExecJMP16(const D: TDecodedInstr);
{ JMP16 - stays in current bank (Y3 page) }
begin
  CPU.PC := (CPU.PC and $FF0000) or D.Imm16;
end;

procedure ExecJMPT(const D: TDecodedInstr);
{ JMPT XYn, Dm — indexed indirect jump table (3 steps + fetch = 4 cycles)
  Encoding: IR[6:5]=XYn, IR[8:7]=Dm  (A0=IR1 shift: ROM GetBits(4,5)=IR[6:5], GetBits(6,7)=IR[8:7])
  Operation: EA = Xn + Dm; PC = Yn : mem[Yn:EA] }
var
  n  : Byte;
  m  : Byte;
  EA : TAddr;
begin
  n  := (D.Operand shr 5) and 3;   { XY pair: IR[6:5] }
  m  := (D.Operand shr 7) and 3;   { D reg:   IR[8:7] }
  EA := (CPU.X[n] + CPU.D[m]) and $FFFF;
  CPU.PC := (TAddr(CPU.Y[n]) shl 16) or MemReadWord((TAddr(CPU.Y[n]) shl 16) or EA);
end;

procedure ExecJMPXY(const D: TDecodedInstr);
{ JMPXY XYn — direct jump to XY register (mode 11, 2 cycles)
  Operation: PC = XYn }
var n: Byte;
begin
  n := (D.Operand shr 5) and 3;
  CPU.PC := CPU.XYGet(n);
end;

// ===========================================================================
// $13 CALL
// ===========================================================================

procedure ExecCALL24(const D: TDecodedInstr);
begin
  CPU.StackPush24(CPU.PC);
  CPU.PC := ((TAddr(D.Operand and $FF) shl 16) or D.Imm16) and ADDR_MASK;
end;

procedure ExecCALL16(const D: TDecodedInstr);
begin
  CPU.StackPush24(CPU.PC);
  CPU.PC := (CPU.PC and $FF0000) or D.Imm16;
end;

procedure ExecCALLR(const D: TDecodedInstr);
{ CALLR - PC-relative signed 16-bit offset }
var off: Integer;
begin
  off := SmallInt(D.Imm16);
  CPU.StackPush24(CPU.PC);
  CPU.PC := TAddr(Integer(CPU.PC) + off) and ADDR_MASK;
end;

procedure ExecCALLXY(const D: TDecodedInstr);
{ CALLXY XYn - IR[6:5]=XYn }
var n: Byte;
begin
  n := (D.Operand shr 5) and 3;
  CPU.StackPush24(CPU.PC);
  CPU.PC := CPU.XYGet(n);
end;

// ===========================================================================
// LOAD helpers  ($14–$17)
// ===========================================================================

function CalcAddr_Ind (const D: TDecodedInstr): TAddr; inline;
{ [XYn]  - IR[6:5]=XY base }
begin Result := CPU.XYGet((D.Operand shr 5) and 3); end;

function CalcAddr_Idx (const D: TDecodedInstr): TAddr; inline;
{ [XYn + Dd]  - IR[6:5]=XY, IR[4:3]=D index reg (byte offset) }
begin
  Result := (CPU.XYGet((D.Operand shr 5) and 3)
            + CPU.D[(D.Operand shr 3) and 3]) and ADDR_MASK;
end;

function CalcAddr_PCRel(const D: TDecodedInstr): TAddr; inline;
{ [PC + SignExtend(Imm16)] - PC already past both words }
begin Result := TAddr(Integer(CPU.PC) + SmallInt(D.Imm16)) and ADDR_MASK; end;

function CalcAddr_Off5 (const D: TDecodedInstr): TAddr; inline;
{ [XYn + imm5*1]  byte offset - IR[6:5]=XY, IR[4:0]=offset }
begin
  Result := (CPU.XYGet((D.Operand shr 5) and 3)
            + (D.Operand and $1F)) and ADDR_MASK;
end;

// LOADD
procedure ExecLOADD_Ind   (const D: TDecodedInstr);
begin CPU.D[(D.Operand shr 7) and 3] := MemReadWord(CalcAddr_Ind(D));   end;
procedure ExecLOADD_Idx   (const D: TDecodedInstr);
begin CPU.D[(D.Operand shr 7) and 3] := MemReadWord(CalcAddr_Idx(D));   end;
procedure ExecLOADD_PCRel (const D: TDecodedInstr);
begin CPU.D[(D.Operand shr 7) and 3] := MemReadWord(CalcAddr_PCRel(D)); end;
procedure ExecLOADD_Off5  (const D: TDecodedInstr);
begin CPU.D[(D.Operand shr 7) and 3] := MemReadWord(CalcAddr_Off5(D));  end;

// LOADB - zero-extended byte
procedure ExecLOADB_Ind   (const D: TDecodedInstr);
begin CPU.D[(D.Operand shr 7) and 3] := MemReadByte(CalcAddr_Ind(D));   end;
procedure ExecLOADB_Idx   (const D: TDecodedInstr);
begin CPU.D[(D.Operand shr 7) and 3] := MemReadByte(CalcAddr_Idx(D));   end;
procedure ExecLOADB_PCRel (const D: TDecodedInstr);
begin CPU.D[(D.Operand shr 7) and 3] := MemReadByte(CalcAddr_PCRel(D)); end;
procedure ExecLOADB_Off5  (const D: TDecodedInstr);
begin CPU.D[(D.Operand shr 7) and 3] := MemReadByte(CalcAddr_Off5(D));  end;

// LOADX
procedure ExecLOADX_Ind   (const D: TDecodedInstr);
begin CPU.X[(D.Operand shr 7) and 3] := MemReadWord(CalcAddr_Ind(D));   end;
procedure ExecLOADX_Imm16 (const D: TDecodedInstr);
{ LOADX mode 1 = LOADI Xn, #imm16 }
begin CPU.X[(D.Operand shr 7) and 3] := D.Imm16; end;
procedure ExecLOADX_PCRel (const D: TDecodedInstr);
begin CPU.X[(D.Operand shr 7) and 3] := MemReadWord(CalcAddr_PCRel(D)); end;
procedure ExecLOADX_Off5  (const D: TDecodedInstr);
begin CPU.X[(D.Operand shr 7) and 3] := MemReadWord(CalcAddr_Off5(D));  end;

// LOADY - byte register
procedure ExecLOADY_Ind   (const D: TDecodedInstr);
begin CPU.Y[(D.Operand shr 7) and 3] := MemReadByte(CalcAddr_Ind(D));   end;
procedure ExecLOADY_Imm8  (const D: TDecodedInstr);
{ LOADY mode 1 = LOADI Yn, #imm8 (low byte of imm16) }
begin CPU.Y[(D.Operand shr 7) and 3] := D.Imm16 and $FF; end;
procedure ExecLOADY_PCRel (const D: TDecodedInstr);
begin CPU.Y[(D.Operand shr 7) and 3] := MemReadByte(CalcAddr_PCRel(D)); end;
procedure ExecLOADY_Off5  (const D: TDecodedInstr);
begin CPU.Y[(D.Operand shr 7) and 3] := MemReadByte(CalcAddr_Off5(D));  end;

// ===========================================================================
// $18 LOADI
// ===========================================================================

procedure ExecLOADI_Imm5(const D: TDecodedInstr);
{ LOADI reg, #imm5 - IR[8:5]=reg field (4 bits), IR[4:0]=imm5
  D0-D3=0-3, X0-X3=4-7, Y0-Y3=8-11 }
var rf: Byte;
begin
  rf := (D.Operand shr 5) and $0F;
  case rf of
    0..3:  CPU.D[rf]     := D.Operand and $1F;   { D0-D3 }
    4..7:  CPU.X[rf - 4] := D.Operand and $1F;   { X0-X3 }
    8..11: CPU.Y[rf - 8] := D.Operand and $1F;   { Y0-Y3 }
  end;
end;

procedure ExecLOADI_Imm16(const D: TDecodedInstr);
{ LOADI reg, #imm16 - IR[8:5]=reg field (4 bits)
  D0-D3=0-3, X0-X3=4-7, Y0-Y3=8-11 }
var rf: Byte;
begin
  rf := (D.Operand shr 5) and $0F;
  case rf of
    0..3:  CPU.D[rf]     := D.Imm16;   { D0-D3 }
    4..7:  CPU.X[rf - 4] := D.Imm16;   { X0-X3 }
    8..11: CPU.Y[rf - 8] := D.Imm16 and $FF; { Y0-Y3 -- 8-bit }
  end;
end;

procedure ExecLOADXY(const D: TDecodedInstr);
{ LOADXY XYn, [XYm] — 1 word, memory source
  IR bits[8:7] = dest n,  bits[6:5] = src m
  Memory layout (matches STOREXY): Y byte at [XYm+0], X word at [XYm+2] }
var
  n, m : Byte;
  addr : TAddr;
begin
  n    := (D.Operand shr 7) and 3;
  m    := (D.Operand shr 5) and 3;
  addr := (TAddr(CPU.Y[m]) shl 16) or CPU.X[m];
  CPU.Y[n] := MemReadByte(addr);
  CPU.X[n] := MemReadWord((addr + 2) and ADDR_MASK);
end;

procedure ExecLOADP(const D: TDecodedInstr);
{ LOADP reg, Yn, [#imm16] - paged load
  reg = rf4 at bits 8:5 (4-bit: D0-D3=0-3, X0-X3=4-7, Y0-Y3=8-11)
  Yn = bits 2:1 (bank register); addr = (Y[n] shl 16) or Imm16
  bit 3 = 0: word (LOADP), 1: byte (LOADPB) }
var rf4, Yn: Byte; addr: TAddr; v: TWord;
begin
  rf4  := (D.Operand shr 5) and $0F;
  Yn   := (D.Operand shr 1) and 3;
  addr := (TAddr(CPU.Y[Yn]) shl 16) or D.Imm16;
  if (D.Operand shr 3) and 1 = 1 then
    v := MemReadByte(addr)
  else
    v := MemReadWord(addr);
  case rf4 of
    0..3:  CPU.D[rf4]     := v;
    4..7:  CPU.X[rf4 - 4] := v;
    8..11: CPU.Y[rf4 - 8] := v and $FF;
  end;
end;

// ===========================================================================
// STORE helpers  ($19–$1C)
// ===========================================================================

// STORED
procedure ExecSTORED_Ind   (const D: TDecodedInstr);
begin MemWriteWord(CalcAddr_Ind(D),    CPU.D[(D.Operand shr 7) and 3]); end;
procedure ExecSTORED_Idx   (const D: TDecodedInstr);
begin MemWriteWord(CalcAddr_Idx(D),    CPU.D[(D.Operand shr 7) and 3]); end;
procedure ExecSTORED_PCRel (const D: TDecodedInstr);
begin MemWriteWord(CalcAddr_PCRel(D),  CPU.D[(D.Operand shr 7) and 3]); end;
procedure ExecSTORED_Off5  (const D: TDecodedInstr);
begin MemWriteWord(CalcAddr_Off5(D),   CPU.D[(D.Operand shr 7) and 3]); end;

// STOREB - low byte only
procedure ExecSTOREEB_Ind   (const D: TDecodedInstr);
begin MemWriteByte(CalcAddr_Ind(D),    CPU.D[(D.Operand shr 7) and 3] and $FF); end;
procedure ExecSTOREEB_Idx   (const D: TDecodedInstr);
begin MemWriteByte(CalcAddr_Idx(D),    CPU.D[(D.Operand shr 7) and 3] and $FF); end;
procedure ExecSTOREEB_PCRel (const D: TDecodedInstr);
begin MemWriteByte(CalcAddr_PCRel(D),  CPU.D[(D.Operand shr 7) and 3] and $FF); end;
procedure ExecSTOREEB_Off5  (const D: TDecodedInstr);
begin MemWriteByte(CalcAddr_Off5(D),   CPU.D[(D.Operand shr 7) and 3] and $FF); end;

// STOREX
procedure ExecSTOREX_Ind   (const D: TDecodedInstr);
begin MemWriteWord(CalcAddr_Ind(D),    CPU.X[(D.Operand shr 7) and 3]); end;
procedure ExecSTOREX_Idx   (const D: TDecodedInstr);
begin MemWriteWord(CalcAddr_Idx(D),    CPU.X[(D.Operand shr 7) and 3]); end;
procedure ExecSTOREX_PCRel (const D: TDecodedInstr);
begin MemWriteWord(CalcAddr_PCRel(D),  CPU.X[(D.Operand shr 7) and 3]); end;
procedure ExecSTOREX_Off5  (const D: TDecodedInstr);
begin MemWriteWord(CalcAddr_Off5(D),   CPU.X[(D.Operand shr 7) and 3]); end;

// STOREY - byte register
procedure ExecSTOREY_Ind   (const D: TDecodedInstr);
begin MemWriteByte(CalcAddr_Ind(D),    CPU.Y[(D.Operand shr 7) and 3]); end;
procedure ExecSTOREY_Idx   (const D: TDecodedInstr);
begin MemWriteByte(CalcAddr_Idx(D),    CPU.Y[(D.Operand shr 7) and 3]); end;
procedure ExecSTOREY_PCRel (const D: TDecodedInstr);
begin MemWriteByte(CalcAddr_PCRel(D),  CPU.Y[(D.Operand shr 7) and 3]); end;
procedure ExecSTOREY_Off5  (const D: TDecodedInstr);
begin MemWriteByte(CalcAddr_Off5(D),   CPU.Y[(D.Operand shr 7) and 3]); end;

// ===========================================================================
// $1D STOREI
// ===========================================================================

procedure ExecSTOREI_Off5(const D: TDecodedInstr);
{ STOREI #imm5, [XYn] - store 5-bit immediate to [XYn]
  bits 4:0 = imm5; bits 7:5 = XYn }
var Xs: Byte;
begin
  Xs := (D.Operand shr 5) and 3;
  MemWriteWord(CPU.XYGet(Xs), D.Operand and $1F);
end;

procedure ExecSTOREI_Imm16(const D: TDecodedInstr);
{ STOREI [XYn], #imm16 - store T16 (Imm16) to [XYn] }
var Xs: Byte;
begin
  Xs := (D.Operand shr 5) and 3;
  MemWriteWord(CPU.XYGet(Xs), D.Imm16);
end;

procedure ExecSTOREXY(const D: TDecodedInstr);
{ STOREXY [XYd], XYs - Y at lower addr, X at higher }
var Xd, Xs: Byte;
begin
  Xd := (D.Operand shr 7) and 3;
  Xs := (D.Operand shr 5) and 3;
  MemWriteWord(CPU.XYGet(Xd),     CPU.Y[Xs]);  { Y at +0 (zero-extended) }
  MemWriteWord(CPU.XYGet(Xd) + 2, CPU.X[Xs]);  { X at +2 }
end;

procedure ExecSTOREP(const D: TDecodedInstr);
{ STOREP reg, Yn, [#imm16] - paged store
  reg = rf4 at bits 8:5 (4-bit: D0-D3=0-3, X0-X3=4-7, Y0-Y3=8-11)
  Yn = bits 2:1 (bank register); addr = (Y[n] shl 16) or Imm16
  bit 3 = 0: word (STOREP), 1: byte (STOREPB) }
var rf4, Yn: Byte; addr: TAddr; v: TWord;
begin
  rf4  := (D.Operand shr 5) and $0F;
  Yn   := (D.Operand shr 1) and 3;
  addr := (TAddr(CPU.Y[Yn]) shl 16) or D.Imm16;
  case rf4 of
    0..3:  v := CPU.D[rf4];
    4..7:  v := CPU.X[rf4 - 4];
    8..11: v := CPU.Y[rf4 - 8];
  else     v := 0;
  end;
  if (D.Operand shr 3) and 1 = 1 then
    MemWriteByte(addr, v and $FF)
  else
    MemWriteWord(addr, v);
end;

// ===========================================================================
// $1E TRAP / RET
// ===========================================================================

procedure ExecTRAP(const D: TDecodedInstr);
{ TRAP #n — vector at [Y3: n*4]
  Entry layout: page_word at +0 (low byte = Y/bank), addr_word at +2
  IR encoding: IR[7:0] = n*2, so n = (IR[7:0] shr 1) }
var
  n        : Byte;
  vecBase  : TAddr;
  pageWord : TWord;
  addrWord : TWord;
begin
  n       := (D.Operand and $FE) shr 1;   { n = IR[7:1] }
  vecBase := (TAddr(CPU.Y[3]) shl 16) or TAddr(n * 4);
  pageWord := MemReadWord(vecBase);        { low byte = target Y (page) }
  addrWord := MemReadWord(vecBase + 2);    { target X (address word) }
  CPU.StackPush24(CPU.PC);
  CPU.PC := (TAddr(pageWord and $FF) shl 16) or addrWord;
end;

procedure ExecRET(const D: TDecodedInstr);
{ RET [#nw] - IMM5 in IR[4:0] (D.Operand bits [4:0])
  Encoder: IMM5 = 4 + cleanup_bytes. Base RET has IMM5=4 (no cleanup).
  Hardware step 1: X3 + IMM5 → ORDB; step 5: ORDB → X3.
  Emulator: StackPop24 already advances X3 by 4 (return addr),
  so we add the remaining (IMM5 - 4) cleanup bytes. }
var
  imm5    : Byte;
  cleanup : TWord;
begin
  CPU.PC := CPU.StackPop24;
  imm5   := D.Operand and $1F;      { IMM5 in bits[4:0], no shift needed }
  if imm5 > 4 then
  begin
    cleanup := imm5 - 4;
    CPU.XYSet(3, (CPU.XYGet(3) + cleanup) and ADDR_MASK);
  end;
end;

// ===========================================================================
// $1F INT
// ===========================================================================

procedure ExecDINT(const D: TDecodedInstr);
begin CPU.SR.IE := False; end;

procedure ExecEINT(const D: TDecodedInstr);
begin CPU.SR.IE := True; end;

procedure ExecRTI(const D: TDecodedInstr);
var SR_word: TWord;
begin
  SR_word := CPU.StackPopWord;
  CPU.SRFromWord(SR_word);
  CPU.PC := CPU.StackPop24;
end;

procedure ExecINT(const D: TDecodedInstr);
{ Hardware interrupt — opcode $FFFF forced onto IR by hardware (or by cpu_thread
  when IRQPending <> 0 and IE set).
  Stack frame (matches RTI microcode, SP+0 popped first by RTI):
    SP+0: SR           (pushed last  → lowest address)
    SP+2: PC[23:16]    (pushed second)
    SP+4: PC[15:0]     (pushed first → highest address)
  Vector: 3-byte address at [Y3:$0000] (page byte) and [Y3:$0002] (low word).
  IE is cleared on entry; restored by RTI via SR pop. }
var
  VecBase : TAddr;
begin
  CPU.StackPush24(CPU.PC);           { PC[15:0] → higher addr, PC[23:16] → lower addr }
  CPU.StackPushWord(CPU.SRToWord);   { SR → lowest addr (RTI pops this first) }
  CPU.SR.IE := False;                { disable interrupts on entry }
  { Read 3-byte handler address from TRAP #0 vector at [Y3:$0000] }
  VecBase    := TAddr(CPU.Y[3]) shl 16;
  CPU.T8     := MemReadWord(VecBase)       and $FF;   { page byte at $xx0000 }
  CPU.PC     := (TAddr(CPU.T8) shl 16)
              or MemReadWord(VecBase + 2);             { low word at $xx0002 }
end;

// ===========================================================================
// Dispatch table initialisation
// ===========================================================================

procedure InitDispatch;
var
  op, md: Integer;
begin
  { Default all 128 slots to ExecIllegal }
  for op := 0 to $1F do
    for md := 0 to 3 do
      DispatchTable[op, md] := @ExecIllegal;

  { $00 MISC }
  DispatchTable[$00, 0] := @ExecNOP;
  DispatchTable[$00, 1] := @ExecHALT;
  { $00 mode 2 = illegal (spare) }
  DispatchTable[$00, 3] := @ExecNEG;

  { $01 LOOKUP }
  DispatchTable[$01, 0] := @ExecLOOKUP;
  DispatchTable[$01, 1] := @ExecLOOKUP;
  DispatchTable[$01, 2] := @ExecLOOKUP;
  DispatchTable[$01, 3] := @ExecLOOKUP;

  { $02 INC/DEC - modes 2,3 spare }
  DispatchTable[$02, 0] := @ExecINC_Word;
  DispatchTable[$02, 1] := @ExecDEC_Word;

  { $03 LEA }
  DispatchTable[$03, 0] := @ExecLEA_XYImm;
  DispatchTable[$03, 1] := @ExecLEA_XYReg;
  DispatchTable[$03, 2] := @ExecLEA_PCRel;
  DispatchTable[$03, 3] := @ExecLEA_Copy;

  { $04 Scc }
  DispatchTable[$04, 0] := @ExecScc;
  DispatchTable[$04, 1] := @ExecScc;
  DispatchTable[$04, 2] := @ExecScc;
  DispatchTable[$04, 3] := @ExecScc;

  { $05 MOVE }
  DispatchTable[$05, 0] := @ExecMOVE;
  DispatchTable[$05, 1] := @ExecMOVE;
  DispatchTable[$05, 2] := @ExecMOVE;
  DispatchTable[$05, 3] := @ExecMOVE;

  { $06 PUSH }
  DispatchTable[$06, 0] := @ExecPUSH_Single;
  DispatchTable[$06, 1] := @ExecPUSH_Group;
  DispatchTable[$06, 2] := @ExecPUSH_XY;
  DispatchTable[$06, 3] := @ExecPUSH_Single;  { was ExecPUSH_Imm -- WRONG for PUSH X/Y/special regs }

  { $07 POP }
  DispatchTable[$07, 0] := @ExecPOP_Single;
  DispatchTable[$07, 1] := @ExecPOP_Group;
  DispatchTable[$07, 2] := @ExecPOP_XY;
  DispatchTable[$07, 3] := @ExecPOPD;

  { $08 ADD }
  DispatchTable[$08, 0] := @ExecADD_RR;
  DispatchTable[$08, 1] := @ExecADD_XReg;
  DispatchTable[$08, 2] := @ExecADD_Imm5;
  DispatchTable[$08, 3] := @ExecADD_Imm16;

  { $09 ADC }
  DispatchTable[$09, 0] := @ExecADC_RR;
  DispatchTable[$09, 1] := @ExecADC_XReg;
  DispatchTable[$09, 2] := @ExecADC_Imm5;
  DispatchTable[$09, 3] := @ExecADC_Imm16;

  { $0A SUB }
  DispatchTable[$0A, 0] := @ExecSUB_RR;
  DispatchTable[$0A, 1] := @ExecSUB_XReg;
  DispatchTable[$0A, 2] := @ExecSUB_Imm5;
  DispatchTable[$0A, 3] := @ExecSUB_Imm16;

  { $0B SBC }
  DispatchTable[$0B, 0] := @ExecSBC_RR;
  DispatchTable[$0B, 1] := @ExecSBC_XReg;
  DispatchTable[$0B, 2] := @ExecSBC_Imm5;
  DispatchTable[$0B, 3] := @ExecSBC_Imm16;

  { $0C AND }
  DispatchTable[$0C, 0] := @ExecAND_RR;
  DispatchTable[$0C, 1] := @ExecAND_XReg;
  DispatchTable[$0C, 2] := @ExecAND_Imm5;
  DispatchTable[$0C, 3] := @ExecAND_Imm16;

  { $0D OR }
  DispatchTable[$0D, 0] := @ExecOR_RR;
  DispatchTable[$0D, 1] := @ExecOR_XReg;
  DispatchTable[$0D, 2] := @ExecOR_Imm5;
  DispatchTable[$0D, 3] := @ExecOR_Imm16;

  { $0E XOR }
  DispatchTable[$0E, 0] := @ExecXOR_RR;
  DispatchTable[$0E, 1] := @ExecXOR_XReg;
  DispatchTable[$0E, 2] := @ExecXOR_Imm5;
  DispatchTable[$0E, 3] := @ExecXOR_Imm16;

  { $0F NOT }
  DispatchTable[$0F, 0] := @ExecNOT_RR;       { Mode 00: NOT dest, src }
  DispatchTable[$0F, 1] := @ExecNOT_XReg;     { Mode 01: NOT dest, [XY] }
  DispatchTable[$0F, 2] := @ExecNOT_InPlace;  { Mode 10: NOT dest (in-place) }
  DispatchTable[$0F, 3] := @ExecNOT_Imm16;    { Mode 11: NOT dest, #imm16 }

  { $10 CMP }
  DispatchTable[$10, 0] := @ExecCMP_RR;
  DispatchTable[$10, 1] := @ExecCMP_XReg;
  DispatchTable[$10, 2] := @ExecCMP_Imm5;
  DispatchTable[$10, 3] := @ExecCMP_Imm16;

  { $11 Bcc - mode 2 = BRA short (unconditional); mode 3 = BRA.L }
  DispatchTable[$11, 0] := @ExecBcc_Short;
  DispatchTable[$11, 1] := @ExecBcc_Long;
  DispatchTable[$11, 2] := @ExecBRA_Short;       { was ExecBcc_Short — WRONG }
  DispatchTable[$11, 3] := @ExecBcc_LongMode3;

  { $12 JMP }
  DispatchTable[$12, 0] := @ExecJMP24;
  DispatchTable[$12, 1] := @ExecJMP16;
  DispatchTable[$12, 2] := @ExecJMPT;
  DispatchTable[$12, 3] := @ExecJMPXY;

  { $13 CALL }
  DispatchTable[$13, 0] := @ExecCALL24;
  DispatchTable[$13, 1] := @ExecCALL16;
  DispatchTable[$13, 2] := @ExecCALLR;   { mode 10 = CALLR  (ocMode10) }
  DispatchTable[$13, 3] := @ExecCALLXY;  { mode 11 = CALLXY (ocMode11) }

  { $14 LOADD }
  DispatchTable[$14, 0] := @ExecLOADD_Ind;
  DispatchTable[$14, 1] := @ExecLOADD_Idx;
  DispatchTable[$14, 2] := @ExecLOADD_PCRel;
  DispatchTable[$14, 3] := @ExecLOADD_Off5;

  { $15 LOADB }
  DispatchTable[$15, 0] := @ExecLOADB_Ind;
  DispatchTable[$15, 1] := @ExecLOADB_Idx;
  DispatchTable[$15, 2] := @ExecLOADB_PCRel;
  DispatchTable[$15, 3] := @ExecLOADB_Off5;

  { $16 LOADX }
  DispatchTable[$16, 0] := @ExecLOADX_Ind;
  DispatchTable[$16, 1] := @ExecLOADX_Imm16;
  DispatchTable[$16, 2] := @ExecLOADX_PCRel;
  DispatchTable[$16, 3] := @ExecLOADX_Off5;

  { $17 LOADY }
  DispatchTable[$17, 0] := @ExecLOADY_Ind;
  DispatchTable[$17, 1] := @ExecLOADY_Imm8;
  DispatchTable[$17, 2] := @ExecLOADY_PCRel;
  DispatchTable[$17, 3] := @ExecLOADY_Off5;

  { $18 LOADI }
  DispatchTable[$18, 0] := @ExecLOADI_Imm5;
  DispatchTable[$18, 1] := @ExecLOADI_Imm16;
  DispatchTable[$18, 2] := @ExecLOADXY;
  DispatchTable[$18, 3] := @ExecLOADP;

  { $19 STORED }
  DispatchTable[$19, 0] := @ExecSTORED_Ind;
  DispatchTable[$19, 1] := @ExecSTORED_Idx;
  DispatchTable[$19, 2] := @ExecSTORED_PCRel;
  DispatchTable[$19, 3] := @ExecSTORED_Off5;

  { $1A STOREB }
  DispatchTable[$1A, 0] := @ExecSTOREEB_Ind;
  DispatchTable[$1A, 1] := @ExecSTOREEB_Idx;
  DispatchTable[$1A, 2] := @ExecSTOREEB_PCRel;
  DispatchTable[$1A, 3] := @ExecSTOREEB_Off5;

  { $1B STOREX }
  DispatchTable[$1B, 0] := @ExecSTOREX_Ind;
  DispatchTable[$1B, 1] := @ExecSTOREX_Idx;
  DispatchTable[$1B, 2] := @ExecSTOREX_PCRel;
  DispatchTable[$1B, 3] := @ExecSTOREX_Off5;

  { $1C STOREY }
  DispatchTable[$1C, 0] := @ExecSTOREY_Ind;
  DispatchTable[$1C, 1] := @ExecSTOREY_Idx;
  DispatchTable[$1C, 2] := @ExecSTOREY_PCRel;
  DispatchTable[$1C, 3] := @ExecSTOREY_Off5;

  { $1D STOREI }
  DispatchTable[$1D, 0] := @ExecSTOREI_Off5;
  DispatchTable[$1D, 1] := @ExecSTOREI_Imm16;
  DispatchTable[$1D, 2] := @ExecSTOREXY;
  DispatchTable[$1D, 3] := @ExecSTOREP;

  { $1E TRAP/RET - modes 1,2 illegal }
  DispatchTable[$1E, 0] := @ExecTRAP;
  DispatchTable[$1E, 3] := @ExecRET;

  { $1F INT }
  DispatchTable[$1F, 0] := @ExecDINT;
  DispatchTable[$1F, 1] := @ExecEINT;
  DispatchTable[$1F, 2] := @ExecRTI;
  DispatchTable[$1F, 3] := @ExecINT;
end;

end.
