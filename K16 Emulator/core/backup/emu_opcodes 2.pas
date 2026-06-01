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
begin
  WriteLn(ErrOutput,
    Format('Illegal opcode $%2.2X mode %d at $%6.6X',
           [D.Opcode, D.Mode, (CPU.PC - 2) and ADDR_MASK]));
  Halt(2);
end;

// ===========================================================================
// $00 MISC
// ===========================================================================

procedure ExecNOP(const D: TDecodedInstr);
begin
  { nothing }
end;

procedure ExecHALT(const D: TDecodedInstr);
begin
  CPU.HaltCode := D.Operand and $FF;   { IR[7:0] = halt code }
  CPU.Halted   := True;
end;

procedure ExecNEG(const D: TDecodedInstr);
{ NEG Dd, Ds - IR[8:7]=Dd, IR[6:5]=Ds }
var Dd, Ds: Byte;
begin
  Dd := (D.Operand shr 7) and 3;
  Ds := (D.Operand shr 5) and 3;
  CPU.D[Dd] := AluNeg(CPU.D[Ds]);
end;

// ===========================================================================
// $01 LOOKUP  - IR[4:0]=op, IR[8:5]=Dn
// All 4 modes map here.
// ===========================================================================

procedure ExecLOOKUP(const D: TDecodedInstr);
var
  Dn  : Byte;
  op  : Byte;
  v   : TWord;
begin
  Dn := (D.Operand shr 5) and $0F;   { IR[8:5] - note: 4 bits, but only 0-3 valid }
  Dn := Dn and 3;
  op := D.Operand and $1F;           { IR[4:0] }
  v  := CPU.D[Dn];
  case op of
    $01: CPU.D[Dn] := LookupSHL (v);
    $02: CPU.D[Dn] := LookupSHR (v);
    $03: CPU.D[Dn] := LookupASR (v);
    $04: CPU.D[Dn] := LookupROL (v);
    $05: CPU.D[Dn] := LookupROR (v);
    $06: CPU.D[Dn] := LookupSWAPB(v);
    $07: CPU.D[Dn] := LookupHIGH(v);
    $08: CPU.D[Dn] := LookupLOW (v);
    $09: CPU.D[Dn] := LookupSHL4(v);
    $0A: CPU.D[Dn] := LookupSHR4(v);
    $0B: CPU.D[Dn] := LookupASR4(v);
    $0C: CPU.D[Dn] := LookupASR8(v);
    $0D: CPU.D[Dn] := LookupMULB(v);
    $0E: CPU.D[Dn] := LookupRECIP(v);
  else
    { unknown lookup op - treat as NOP }
  end;
end;

// ===========================================================================
// $02 INC/DEC - 24-bit XY arithmetic; IR[6:5]=XY pair; no flags
// ===========================================================================

procedure ExecINC_Word(const D: TDecodedInstr);
{ INC XYn - adds 2 (word stride) }
var n: Byte;
begin
  n := (D.Operand shr 5) and 3;
  CPU.XYSet(n, (CPU.XYGet(n) + 2) and ADDR_MASK);
end;

procedure ExecDEC_Word(const D: TDecodedInstr);
{ DEC XYn - subtracts 2 }
var n: Byte;
begin
  n := (D.Operand shr 5) and 3;
  CPU.XYSet(n, (CPU.XYGet(n) - 2) and ADDR_MASK);
end;

// ===========================================================================
// $03 LEA - IR[8:7]=destXY, IR[6:5]=srcXY or Dn
// ===========================================================================

procedure ExecLEA_XYImm(const D: TDecodedInstr);
{ LEA XYd, XYs+#imm9 - sign-extend IR[4:0] as 5-bit offset (word units) }
var
  Xd, Xs: Byte;
  imm5  : Integer;
begin
  Xd   := (D.Operand shr 7) and 3;
  Xs   := (D.Operand shr 5) and 3;
  imm5 := D.Operand and $1F;
  { sign-extend 5-bit }
  if imm5 and $10 <> 0 then imm5 := imm5 or Integer(not $1F);
  CPU.XYSet(Xd, (CPU.XYGet(Xs) + TAddr(imm5 * 2)) and ADDR_MASK);
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
{ LEA XYd, XYs (copy) }
var Xd, Xs: Byte;
begin
  Xd := (D.Operand shr 7) and 3;
  Xs := (D.Operand shr 5) and 3;
  CPU.XYSet(Xd, CPU.XYGet(Xs));
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
var
  Dd  : Byte;
  cond: Byte;
begin
  Dd   := (D.Operand shr 7) and 3;
  cond := (D.Operand shr 2) and 7;
  if EvalCond(cond) then CPU.D[Dd] := 1
  else CPU.D[Dd] := 0;
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
{ MOVE covers many sub-forms - dispatch on IR[8:6] }
var
  form  : Byte;
  Dd, Ds, Xd, Xs, Yn: Byte;
begin
  form := (D.Operand shr 6) and 7;  { IR[8:6] }
  case form of
    { IR[8:7]=00, IR[6]=0: MOVE Dd, Ds - IR[5:4]=Dd, IR[3:2]=Ds }
    0:
    begin
      Dd := (D.Operand shr 4) and 3;
      Ds := (D.Operand shr 2) and 3;
      CPU.D[Dd] := CPU.D[Ds];
    end;
    { IR[8:7]=00, IR[6]=1: MOVE Dd, Xs - Dd=IR[5:4], Xs=IR[3:2] }
    1:
    begin
      Dd := (D.Operand shr 4) and 3;
      Xs := (D.Operand shr 2) and 3;
      CPU.D[Dd] := CPU.X[Xs];
    end;
    { IR[8:7]=01, IR[6]=0: MOVE Xd, Ds }
    2:
    begin
      Xd := (D.Operand shr 4) and 3;
      Ds := (D.Operand shr 2) and 3;
      CPU.X[Xd] := CPU.D[Ds];
    end;
    { IR[8:7]=01, IR[6]=1: MOVE Xd, Xs }
    3:
    begin
      Xd := (D.Operand shr 4) and 3;
      Xs := (D.Operand shr 2) and 3;
      CPU.X[Xd] := CPU.X[Xs];
    end;
    { IR[8:7]=10, IR[6]=0: MOVE Dd, Yn }
    4:
    begin
      Dd := (D.Operand shr 4) and 3;
      Yn := (D.Operand shr 2) and 3;
      CPU.D[Dd] := CPU.Y[Yn];
    end;
    { IR[8:7]=10, IR[6]=1: MOVE Yn, Ds }
    5:
    begin
      Yn := (D.Operand shr 4) and 3;
      Ds := (D.Operand shr 2) and 3;
      CPU.Y[Yn] := CPU.D[Ds] and $FF;
    end;
    { IR[8:7]=11, IR[6]=0: MOVE Dd, SR }
    6:
    begin
      Dd := (D.Operand shr 4) and 3;
      CPU.D[Dd] := CPU.SRToWord;
    end;
    { IR[8:7]=11, IR[6]=1: MOVE SR, Ds }
    7:
    begin
      Ds := (D.Operand shr 4) and 3;
      CPU.SRFromWord(CPU.D[Ds]);
    end;
  end;
end;

// ===========================================================================
// $06 PUSH
// ===========================================================================

procedure ExecPUSH_Single(const D: TDecodedInstr);
{ PUSH Dn, XYsp - IR[8:7]=Dn, IR[2:1]=stack XY }
var Dn, sp: Byte;
begin
  Dn := (D.Operand shr 7) and 3;
  sp := (D.Operand shr 1) and 3;
  CPU.XYSet(sp, CPU.XYGet(sp) - 2);
  MemWriteWord(CPU.XYGet(sp), CPU.D[Dn]);
end;

procedure ExecPUSH_Group(const D: TDecodedInstr);
{ PUSH D0..D3 group - IR[7:4] = register mask; IR[2:1]=stack XY }
{ Bit 7=D0,6=D1,5=D2,4=D3, bit 3=X0,2=X1,... }
var
  mask, sp: Byte;
  i: Integer;
begin
  mask := (D.Operand shr 4) and $0F;   { D registers }
  sp   := (D.Operand shr 1) and 3;
  { Push highest-numbered first (D3..D0) }
  for i := 3 downto 0 do
    if (mask shr (3 - i)) and 1 = 1 then
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
{ POP Dn, XYsp }
var Dn, sp: Byte;
begin
  Dn := (D.Operand shr 7) and 3;
  sp := (D.Operand shr 1) and 3;
  CPU.D[Dn] := MemReadWord(CPU.XYGet(sp));
  CPU.XYSet(sp, CPU.XYGet(sp) + 2);
end;

procedure ExecPOP_Group(const D: TDecodedInstr);
{ POP D0..D3 - mirror of PUSH_Group, pop D0 first }
var
  mask, sp: Byte;
  i: Integer;
begin
  mask := (D.Operand shr 4) and $0F;
  sp   := (D.Operand shr 1) and 3;
  for i := 0 to 3 do
    if (mask shr (3 - i)) and 1 = 1 then
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
var Dd, Ds: Byte;
begin
  Dd := (D.Operand shr 5) and 3;
  Ds := (D.Operand shr 3) and 3;
  CPU.D[Dd] := DoAluOp(op, CPU.D[Dd], CPU.D[Ds]);
end;

procedure ALU_Imm5(op: TAluOp; const D: TDecodedInstr); inline;
var Dd: Byte; imm5: TWord;
begin
  Dd   := (D.Operand shr 5) and 3;
  imm5 := D.Operand and $1F;
  CPU.D[Dd] := DoAluOp(op, CPU.D[Dd], imm5);
end;

procedure ALU_XReg(op: TAluOp; const D: TDecodedInstr); inline;
{ ALU Dd, Xn - uses X register as source }
var Dd, Xs: Byte;
begin
  Dd := (D.Operand shr 5) and 3;
  Xs := (D.Operand shr 3) and 3;
  CPU.D[Dd] := DoAluOp(op, CPU.D[Dd], CPU.X[Xs]);
end;

procedure ALU_Imm16(op: TAluOp; const D: TDecodedInstr); inline;
var Dd: Byte;
begin
  Dd := (D.Operand shr 5) and 3;
  CPU.D[Dd] := DoAluOp(op, CPU.D[Dd], D.Imm16);
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

procedure ExecNOT_RR   (const D: TDecodedInstr); begin ALU_RR   (aopNOT, D); end;
procedure ExecNOT_Imm5 (const D: TDecodedInstr); begin ALU_Imm5 (aopNOT, D); end;
procedure ExecNOT_XReg (const D: TDecodedInstr); begin ALU_XReg (aopNOT, D); end;
procedure ExecNOT_Imm16(const D: TDecodedInstr); begin ALU_Imm16(aopNOT, D); end;

procedure ExecCMP_RR   (const D: TDecodedInstr);
begin AluCmp(CPU.D[(D.Operand shr 7) and 3], CPU.D[(D.Operand shr 5) and 3]); end;
procedure ExecCMP_Imm5 (const D: TDecodedInstr);
begin AluCmp(CPU.D[(D.Operand shr 7) and 3], D.Operand and $1F); end;
procedure ExecCMP_XReg (const D: TDecodedInstr);
begin AluCmp(CPU.D[(D.Operand shr 7) and 3], CPU.X[(D.Operand shr 5) and 3]); end;
procedure ExecCMP_Imm16(const D: TDecodedInstr);
begin AluCmp(CPU.D[(D.Operand shr 7) and 3], D.Imm16); end;

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
{ JMPT XYn - indirect through XY table; IR[6:5]=XYn }
var n: Byte;
begin
  n := (D.Operand shr 5) and 3;
  CPU.PC := CPU.XYGet(n);
end;

procedure ExecJMPXY(const D: TDecodedInstr);
{ JMPXY - same as JMPT mode 11 form }
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
{ LOADXY XYn, #addr24 - IR[8:7]=XYn
  Fetch has already consumed one imm word (Imm16 = word 1 = Y:pad word).
  Word 2 (X) is the next word - consume it now. }
var
  n  : Byte;
  Yb : TByte;
  Xw : TWord;
begin
  n  := (D.Operand shr 7) and 3;
  { D.Imm16 = first extra word: low byte = Y, high byte = 0 }
  Yb := D.Imm16 and $FF;
  { Second extra word = X }
  Xw := MemReadWord(CPU.PC);
  Inc(CPU.PC, 2);
  CPU.PC := CPU.PC and ADDR_MASK;
  CPU.Y[n] := Yb;
  CPU.X[n] := Xw;
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
{ TRAP #n - n = (IR[7:0] shr 1) - 1
  Vector at (Y3 shl 16) or ($0004 + n*2)
  Pushes return PC, loads vector word, sets PC[23:16] = Y3 }
var
  n   : Byte;
  vec : TAddr;
  tgt : TWord;
begin
  n   := ((D.Operand and $FF) shr 1);
  if n > 0 then Dec(n);
  vec := (TAddr(CPU.Y[3]) shl 16) or TAddr($0004 + n * 2);
  CPU.StackPush24(CPU.PC);
  tgt    := MemReadWord(vec);
  CPU.PC := (TAddr(CPU.Y[3]) shl 16) or tgt;
end;

procedure ExecRET(const D: TDecodedInstr);
{ RET [#Nw] - IR[4:0] = stack cleanup word count (0–13) }
var cleanup: TWord;
begin
  CPU.PC  := CPU.StackPop24;
  cleanup := (D.Operand and $1F) * 2;
  if cleanup > 0 then
    CPU.XYSet(3, (CPU.XYGet(3) + cleanup) and ADDR_MASK);
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
{ Hardware interrupt - not emulated in software; treat as ExecIllegal }
begin
  ExecIllegal(D);
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
  DispatchTable[$06, 3] := @ExecPUSH_Imm;

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
  DispatchTable[$0F, 0] := @ExecNOT_RR;
  DispatchTable[$0F, 1] := @ExecNOT_Imm5;
  DispatchTable[$0F, 2] := @ExecNOT_XReg;
  DispatchTable[$0F, 3] := @ExecNOT_Imm16;

  { $10 CMP }
  DispatchTable[$10, 0] := @ExecCMP_RR;
  DispatchTable[$10, 1] := @ExecCMP_XReg;
  DispatchTable[$10, 2] := @ExecCMP_Imm5;
  DispatchTable[$10, 3] := @ExecCMP_Imm16;

  { $11 Bcc - modes 2,3 illegal }
  DispatchTable[$11, 0] := @ExecBcc_Short;
  DispatchTable[$11, 1] := @ExecBcc_Long;
  DispatchTable[$11, 2] := @ExecBcc_Short;  { short BRA }
  DispatchTable[$11, 3] := @ExecBcc_LongMode3;  { long BRA }

  { $12 JMP }
  DispatchTable[$12, 0] := @ExecJMP24;
  DispatchTable[$12, 1] := @ExecJMP16;
  DispatchTable[$12, 2] := @ExecJMPT;
  DispatchTable[$12, 3] := @ExecJMPXY;

  { $13 CALL }
  DispatchTable[$13, 0] := @ExecCALL24;
  DispatchTable[$13, 1] := @ExecCALL16;
  DispatchTable[$13, 2] := @ExecCALLR;
  DispatchTable[$13, 3] := @ExecCALLXY;

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
