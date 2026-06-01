unit emu_alu;
{
  K16 Emulator — ALU Operations and Lookup Table Ops
  All ALU functions update CPU.SR.Flags as a side effect (except LOOKUP ops).
  Part of the K16 homebrew CPU project.
}

{$mode Delphi}
{$H+}

interface

uses
  emu_types, emu_cpu;

// ---------------------------------------------------------------------------
// ALU operation selector
// ---------------------------------------------------------------------------

type
  TAluOp = (aopADD, aopADC, aopSUB, aopSBC,
            aopAND, aopOR,  aopXOR, aopNOT,
            aopCMP);

// ---------------------------------------------------------------------------
// ALU functions — each updates CPU.SR.Flags
// ---------------------------------------------------------------------------

function AluAdd(a, b: TWord; cin: Boolean): TWord;
function AluSub(a, b: TWord; bin: Boolean): TWord;
function AluAnd(a, b: TWord): TWord;
function AluOr (a, b: TWord): TWord;
function AluXor(a, b: TWord): TWord;
function AluNot(a: TWord): TWord;
function AluNeg(a: TWord): TWord;   { NEG: result = 0 - a; sets C, Z, N, V per section 6.3 }
function AluCmp(a, b: TWord): TWord; { = AluSub, result unused by caller }

{ Dispatch via TAluOp selector }
function DoAluOp(op: TAluOp; a, b: TWord): TWord;

// ---------------------------------------------------------------------------
// LOOKUP operations — no flag side effects (except SHL/SHR set C)
// ---------------------------------------------------------------------------

function LookupSHL (v: TWord): TWord;
function LookupSHR (v: TWord): TWord;
function LookupASR (v: TWord): TWord;
function LookupROL (v: TWord): TWord;
function LookupROR (v: TWord): TWord;
function LookupSWAPB(v: TWord): TWord;
function LookupHIGH(v: TWord): TWord;
function LookupLOW (v: TWord): TWord;
function LookupSHL4(v: TWord): TWord;
function LookupSHR4(v: TWord): TWord;
function LookupASR4(v: TWord): TWord;
function LookupASR8(v: TWord): TWord;
function LookupMULB(v: TWord): TWord;
function LookupRECIP(v: TWord): TWord;

implementation

// ---------------------------------------------------------------------------
// Internal flag helpers
// ---------------------------------------------------------------------------

procedure SetFlagsZN(result: TWord);
begin
  CPU.SR.Flags.Z := result = 0;
  CPU.SR.Flags.N := (result and $8000) <> 0;
end;

procedure SetFlagsArith(a, b: TWord; result32: LongWord; isSub: Boolean);
var
  r: TWord;
begin
  r := TWord(result32);
  CPU.SR.Flags.Z := r = 0;
  CPU.SR.Flags.N := (r and $8000) <> 0;
  if isSub then
    { SUB/SBC/CMP: C=0 indicates borrow (K16 convention).
      Borrow occurs when unsigned a < b, i.e. result32 wraps (>$FFFF).
      So C := NOT borrow = result32 <= $FFFF, i.e. a >= b unsigned. }
    CPU.SR.Flags.C := result32 <= $FFFF
  else
    { ADD/ADC: C=1 on unsigned overflow (result > 16 bits) }
    CPU.SR.Flags.C := result32 > $FFFF;
  { Signed overflow: same-sign operands produce different-sign result }
  if isSub then
    CPU.SR.Flags.V := ((a xor b) and $8000 <> 0) and
                      ((a xor r) and $8000 <> 0)
  else
    CPU.SR.Flags.V := ((not (a xor b)) and $8000 <> 0) and
                      ((a xor r) and $8000 <> 0);
end;

// ---------------------------------------------------------------------------
// ALU operations
// ---------------------------------------------------------------------------

function AluAdd(a, b: TWord; cin: Boolean): TWord;
var r32: LongWord;
begin
  r32 := LongWord(a) + LongWord(b);
  if cin then Inc(r32);
  SetFlagsArith(a, b, r32, False);
  Result := TWord(r32);
end;

function AluSub(a, b: TWord; bin: Boolean): TWord;
var r32: LongWord;
begin
  r32 := LongWord(a) - LongWord(b);
  if bin then Dec(r32);
  SetFlagsArith(a, b, r32, True);
  Result := TWord(r32);
end;

function AluAnd(a, b: TWord): TWord;
begin
  Result := a and b;
  SetFlagsZN(Result);
  CPU.SR.Flags.C := False;
  { V unchanged }
end;

function AluOr(a, b: TWord): TWord;
begin
  Result := a or b;
  SetFlagsZN(Result);
  CPU.SR.Flags.C := False;
end;

function AluXor(a, b: TWord): TWord;
begin
  Result := a xor b;
  SetFlagsZN(Result);
  CPU.SR.Flags.C := False;
end;

function AluNot(a: TWord): TWord;
begin
  Result := not a;
  SetFlagsZN(Result);
  CPU.SR.Flags.C := False;
end;

function AluNeg(a: TWord): TWord;
{ Two's complement negate.
  Per Reference Manual section 6.3 / 15.3 (NEG sets C, Z, N, V):
    Z = result is zero
    N = result bit 15 set
    C = src was zero (no borrow; matches K16 SUB convention C=1 = no borrow)
    V = src was $8000 (the single overflow case: -(-32768) is unrepresentable in 16 bits)
  Equivalent to 0 - a through the SUB convention.
  CR-2026-001 v1.2 also relocated NEG from $00 mode 11 to $1E mode 01;
  the flag-update behaviour here is unchanged by that move (FLAGSX=0 at $1E
  routes these writes to user-visible SR as required). }
begin
  Result := TWord(0 - LongWord(a));
  CPU.SR.Flags.Z := Result = 0;
  CPU.SR.Flags.N := (Result and $8000) <> 0;
  CPU.SR.Flags.C := a = 0;               { no borrow only if src was zero }
  CPU.SR.Flags.V := a = $8000;           { $8000 is the sole overflow case }
end;

function AluCmp(a, b: TWord): TWord;
begin
  Result := AluSub(a, b, False);
end;

function DoAluOp(op: TAluOp; a, b: TWord): TWord;
begin
  case op of
    aopADD : Result := AluAdd(a, b, False);
    aopADC : Result := AluAdd(a, b, CPU.SR.Flags.C);
    aopSUB : Result := AluSub(a, b, False);
    aopSBC : Result := AluSub(a, b, not CPU.SR.Flags.C);  { dst - src - ~C }
    aopAND : Result := AluAnd(a, b);
    aopOR  : Result := AluOr (a, b);
    aopXOR : Result := AluXor(a, b);
    aopNOT : Result := AluNot(b);  { NOT uses second operand for immediate modes }
    aopCMP : Result := AluCmp(a, b);
  else
    Result := 0;
  end;
end;

// ---------------------------------------------------------------------------
// LOOKUP operations
// ---------------------------------------------------------------------------

function LookupSHL(v: TWord): TWord;
{ SHL — shift left 1. Flag-transparent per section 15.3 (LOOKUP is — — — —).
  Hardware: lookup table read; SR untouched (no FLAGSLoad in step 2). }
begin
  Result := (v shl 1) and $FFFF;
end;

function LookupSHR(v: TWord): TWord;
{ SHR — shift right 1, logical. Flag-transparent. }
begin
  Result := v shr 1;
end;

function LookupASR(v: TWord): TWord;
{ ASR — shift right 1, arithmetic (sign-extending). Flag-transparent. }
begin
  Result := TWord((SmallInt(v)) shr 1);
end;

function LookupROL(v: TWord): TWord;
{ ROL — pure rotate left by 1 (bit 15 → bit 0).
  Flag-transparent: K16 ROL is NOT rotate-through-carry. The hardware
  implementation is a lookup table that reads no carry input; the value
  shifted out at bit 15 wraps directly back to bit 0. Matches section 15.3
  (LOOKUP — — — —) and the page-select-only role of step 1's FLAGSLoad. }
begin
  Result := ((v shl 1) and $FFFF) or ((v shr 15) and 1);
end;

function LookupROR(v: TWord): TWord;
{ ROR — pure rotate right by 1 (bit 0 → bit 15).
  Flag-transparent; same rationale as LookupROL — pure rotate, no carry. }
begin
  Result := (v shr 1) or ((v and 1) shl 15);
end;

function LookupSWAPB(v: TWord): TWord;
begin
  Result := ((v shl 8) and $FF00) or (v shr 8);
end;

function LookupHIGH(v: TWord): TWord;
begin
  Result := v shr 8;
end;

function LookupLOW(v: TWord): TWord;
begin
  Result := v and $00FF;
end;

function LookupSHL4(v: TWord): TWord;
begin
  Result := (v shl 4) and $FFFF;
end;

function LookupSHR4(v: TWord): TWord;
begin
  Result := v shr 4;
end;

function LookupASR4(v: TWord): TWord;
begin
  Result := TWord(SmallInt(v) shr 4);
end;

function LookupASR8(v: TWord): TWord;
begin
  Result := TWord(SmallInt(v) shr 8);
end;

function LookupMULB(v: TWord): TWord;
begin
  Result := TWord((v and $FF) * ((v shr 8) and $FF));
end;

function LookupRECIP(v: TWord): TWord;
begin
  if v = 0 then Result := $FFFF
  else Result := TWord(Round(65536.0 / v));
end;

end.
