{
  K16_PseudoShift.pas — K16 Assembler Shift Pseudo-Instructions

  Implements SHL Dn, #n / SHR Dn, #n / ASR Dn, #n as pseudo-instructions
  that expand to the shortest known sequence of native LOOKUP shifts.

  The three decomposition tables (one per direction) are built in the
  unit initialization section as arrays of dynamic-array rows.  Each
  table maps count [0..16] to a sequence of native mnemonics.  The
  function ExpandShift is a pure lookup + register substitution — no
  parser or encoder coupling.

  Cost model (per K16 ISA Gotchas v4, May 2026):
    SHL, SHR, ASR, SHL4, SHR4, ASR4, ASR8, HIGH, LOW, SWAPB : 3 cycles, 1 word
    LOADI Dn, #0  (IMM5 form, fits in 5-bit immediate)      : 2 cycles, 1 word

  Asymmetries:
    SHL has no '>> 8' shortcut — uses LOW / SWAPB (clear high byte, swap).
    SHR has HIGH (single-instruction unsigned >> 8 with high-byte clear).
    ASR has ASR8 (single-instruction signed >> 8).
    ASR cannot constant-fold count >= 16 to zero (negative => $FFFF,
    positive => $0000); emits a full 16-ASR chain and a warning.

  Part of the K16 homebrew CPU project.
  https://github.com/paulkberger/K16-CPU

  License: MIT
}
unit K16_PseudoShift;

{$mode Delphi}

interface

uses
  SysUtils,
  K16_PseudoCommon;

type
  TShiftResult = record
    Sequence: TInstructionSequence;
    // Warning the assembler should issue.  Empty string = no warning.
    Warning:  string;
  end;

// ExpandShift: produce the shortest known native sequence for
//   <Direction> Dn, #Count.
//
// Negative count: raises Exception (parser should already reject; this
//   is a belt-and-braces guard for unit-test fuzz cases).
// Count = 0: returns an empty sequence (zero instructions emitted).
// Count >= 17 for SHL/SHR: same as count = 16, with a warning.
// Count >= 16 for ASR: full 16-ASR chain, with a warning.
//
// RegNum: 0..3 (D0..D3).
function ExpandShift(Direction: TShiftDirection;
                     Count: Integer;
                     RegNum: Byte): TShiftResult;

// Cycle/byte cost of a fixed-count shift expansion.  Useful for the
// listing comment and for compiler cost models.
function ShiftCycles(Direction: TShiftDirection; Count: Integer): Integer;
function ShiftBytes(Direction: TShiftDirection; Count: Integer): Integer;

implementation

type
  TShiftRow   = array of string;       // mnemonics in emit order
  TShiftTable = array[0..16] of TShiftRow;

var
  // Decomposition tables, populated in initialization.
  SHL_TABLE: TShiftTable;
  SHR_TABLE: TShiftTable;
  ASR_TABLE: TShiftTable;

const
  ZERO_MARKER = '__ZERO__';   // special row content => emit LOADI Dn, #0

procedure InitShiftTables;
begin
  // -------------------------------------------------------------------
  // SHL Dn, #count  —  logical left shift
  // Counts 9..11: LOW/SWAPB prefix + 1..3 SHLs.
  // Counts 12..15: SHL4 × 3 + 0..3 SHLs (cheaper than LOW/SWAPB chain
  //   at this end).
  // -------------------------------------------------------------------
  SHL_TABLE[0]  := nil;
  SHL_TABLE[1]  := TShiftRow.Create('SHL');
  SHL_TABLE[2]  := TShiftRow.Create('SHL', 'SHL');
  SHL_TABLE[3]  := TShiftRow.Create('SHL', 'SHL', 'SHL');
  SHL_TABLE[4]  := TShiftRow.Create('SHL4');
  SHL_TABLE[5]  := TShiftRow.Create('SHL4', 'SHL');
  SHL_TABLE[6]  := TShiftRow.Create('SHL4', 'SHL', 'SHL');
  SHL_TABLE[7]  := TShiftRow.Create('SHL4', 'SHL', 'SHL', 'SHL');
  SHL_TABLE[8]  := TShiftRow.Create('LOW',  'SWAPB');
  SHL_TABLE[9]  := TShiftRow.Create('LOW',  'SWAPB', 'SHL');
  SHL_TABLE[10] := TShiftRow.Create('LOW',  'SWAPB', 'SHL', 'SHL');
  SHL_TABLE[11] := TShiftRow.Create('LOW',  'SWAPB', 'SHL', 'SHL', 'SHL');
  SHL_TABLE[12] := TShiftRow.Create('SHL4', 'SHL4',  'SHL4');
  SHL_TABLE[13] := TShiftRow.Create('SHL4', 'SHL4',  'SHL4', 'SHL');
  SHL_TABLE[14] := TShiftRow.Create('SHL4', 'SHL4',  'SHL4', 'SHL', 'SHL');
  SHL_TABLE[15] := TShiftRow.Create('SHL4', 'SHL4',  'SHL4', 'SHL', 'SHL', 'SHL');
  SHL_TABLE[16] := TShiftRow.Create(ZERO_MARKER);

  // -------------------------------------------------------------------
  // SHR Dn, #count  —  logical right shift
  // HIGH does the work of SHR4 × 2 + free high-byte clear, so any
  // count >= 8 prefers HIGH.
  // -------------------------------------------------------------------
  SHR_TABLE[0]  := nil;
  SHR_TABLE[1]  := TShiftRow.Create('SHR');
  SHR_TABLE[2]  := TShiftRow.Create('SHR', 'SHR');
  SHR_TABLE[3]  := TShiftRow.Create('SHR', 'SHR', 'SHR');
  SHR_TABLE[4]  := TShiftRow.Create('SHR4');
  SHR_TABLE[5]  := TShiftRow.Create('SHR4', 'SHR');
  SHR_TABLE[6]  := TShiftRow.Create('SHR4', 'SHR', 'SHR');
  SHR_TABLE[7]  := TShiftRow.Create('SHR4', 'SHR', 'SHR', 'SHR');
  SHR_TABLE[8]  := TShiftRow.Create('HIGH');
  SHR_TABLE[9]  := TShiftRow.Create('HIGH', 'SHR');
  SHR_TABLE[10] := TShiftRow.Create('HIGH', 'SHR', 'SHR');
  SHR_TABLE[11] := TShiftRow.Create('HIGH', 'SHR', 'SHR', 'SHR');
  SHR_TABLE[12] := TShiftRow.Create('HIGH', 'SHR4');
  SHR_TABLE[13] := TShiftRow.Create('HIGH', 'SHR4', 'SHR');
  SHR_TABLE[14] := TShiftRow.Create('HIGH', 'SHR4', 'SHR', 'SHR');
  SHR_TABLE[15] := TShiftRow.Create('HIGH', 'SHR4', 'SHR', 'SHR', 'SHR');
  SHR_TABLE[16] := TShiftRow.Create(ZERO_MARKER);

  // -------------------------------------------------------------------
  // ASR Dn, #count  —  arithmetic right shift
  // Count 16: full 16-ASR chain — saturates at sign bit (NOT zero).
  // Emits warning suggesting SHR if zero-fill is intended.
  // -------------------------------------------------------------------
  ASR_TABLE[0]  := nil;
  ASR_TABLE[1]  := TShiftRow.Create('ASR');
  ASR_TABLE[2]  := TShiftRow.Create('ASR', 'ASR');
  ASR_TABLE[3]  := TShiftRow.Create('ASR', 'ASR', 'ASR');
  ASR_TABLE[4]  := TShiftRow.Create('ASR4');
  ASR_TABLE[5]  := TShiftRow.Create('ASR4', 'ASR');
  ASR_TABLE[6]  := TShiftRow.Create('ASR4', 'ASR', 'ASR');
  ASR_TABLE[7]  := TShiftRow.Create('ASR4', 'ASR', 'ASR', 'ASR');
  ASR_TABLE[8]  := TShiftRow.Create('ASR8');
  ASR_TABLE[9]  := TShiftRow.Create('ASR8', 'ASR');
  ASR_TABLE[10] := TShiftRow.Create('ASR8', 'ASR', 'ASR');
  ASR_TABLE[11] := TShiftRow.Create('ASR8', 'ASR', 'ASR', 'ASR');
  ASR_TABLE[12] := TShiftRow.Create('ASR8', 'ASR4');
  ASR_TABLE[13] := TShiftRow.Create('ASR8', 'ASR4', 'ASR');
  ASR_TABLE[14] := TShiftRow.Create('ASR8', 'ASR4', 'ASR', 'ASR');
  ASR_TABLE[15] := TShiftRow.Create('ASR8', 'ASR4', 'ASR', 'ASR', 'ASR');
  ASR_TABLE[16] := TShiftRow.Create('ASR', 'ASR', 'ASR', 'ASR',
                                    'ASR', 'ASR', 'ASR', 'ASR',
                                    'ASR', 'ASR', 'ASR', 'ASR',
                                    'ASR', 'ASR', 'ASR', 'ASR');
end;

function GetRow(Direction: TShiftDirection; Count: Integer): TShiftRow;
begin
  case Direction of
    sdSHL: Result := SHL_TABLE[Count];
    sdSHR: Result := SHR_TABLE[Count];
    sdASR: Result := ASR_TABLE[Count];
  end;
end;

function DirectionName(Direction: TShiftDirection): string;
begin
  case Direction of
    sdSHL: Result := 'SHL';
    sdSHR: Result := 'SHR';
    sdASR: Result := 'ASR';
    else   Result := '?';
  end;
end;

function ExpandShift(Direction: TShiftDirection;
                     Count: Integer;
                     RegNum: Byte): TShiftResult;
var
  Row:       TShiftRow;
  Effective: Integer;
  RegName:   string;
  i:         Integer;
begin
  Result.Sequence := nil;
  Result.Warning  := '';

  if Count < 0 then
    raise Exception.CreateFmt('ExpandShift: negative count %d', [Count]);
  if RegNum > 3 then
    raise Exception.CreateFmt('ExpandShift: invalid register D%d', [RegNum]);

  RegName := Format('D%d', [RegNum]);

  // Count clamping --------------------------------------------------------
  Effective := Count;
  if Effective > 16 then
  begin
    Effective := 16;
    if Direction = sdASR then
      Result.Warning :=
        'ASR by 16 or more saturates at sign bit; consider SHR if zero-fill is intended'
    else
      Result.Warning :=
        Format('%s count %d clamped to 16; result is zero', [DirectionName(Direction), Count]);
  end
  else if (Effective = 16) and (Direction = sdASR) then
    Result.Warning :=
      'ASR by 16 or more saturates at sign bit; consider SHR if zero-fill is intended';

  // Zero count ------------------------------------------------------------
  // Emit a warning and return an empty sequence.  This is almost always
  // a bug in user code (typo, mis-computed constant), but K16Pascal may
  // legitimately generate it from compile-time-constant-zero counts and
  // should optimise the line away itself rather than relying on a hard
  // error here.  Empty sequence + warning splits the difference.
  if Effective = 0 then
  begin
    if Result.Warning = '' then  { don't overwrite a clamp/saturate warning }
      Result.Warning := Format(
        '%s %s, #0 emits no code; remove the line or check the count expression',
        [DirectionName(Direction), RegName]);
    Exit;
  end;

  Row := GetRow(Direction, Effective);

  // Special case: SHL/SHR count 16 -> single LOADI Dn, #0 (IMM5 form) ----
  if (Length(Row) = 1) and (Row[0] = ZERO_MARKER) then
  begin
    SetLength(Result.Sequence, 1);
    Result.Sequence[0] := PI('LOADI', Format('%s, #0', [RegName]));
    Result.Sequence[0].Comment :=
      Format('%s %s, #%d (-> zero)', [DirectionName(Direction), RegName, Count]);
    Exit;
  end;

  // Normal case: emit one record per row entry ----------------------------
  SetLength(Result.Sequence, Length(Row));
  for i := 0 to High(Row) do
  begin
    Result.Sequence[i] := PI(Row[i], RegName);
    if i = 0 then
      Result.Sequence[i].Comment :=
        Format('%s %s, #%d', [DirectionName(Direction), RegName, Count]);
  end;
end;

function ShiftCycles(Direction: TShiftDirection; Count: Integer): Integer;
var
  Effective: Integer;
  Row:       TShiftRow;
begin
  Effective := Count;
  if Effective < 0 then Exit(0);
  if Effective > 16 then Effective := 16;
  if Effective = 0 then Exit(0);

  Row := GetRow(Direction, Effective);
  if (Length(Row) = 1) and (Row[0] = ZERO_MARKER) then
    Result := 2   // LOADI Dn, #0 (IMM5 form)
  else
    Result := Length(Row) * 3;
end;

function ShiftBytes(Direction: TShiftDirection; Count: Integer): Integer;
var
  Effective: Integer;
  Row:       TShiftRow;
begin
  Effective := Count;
  if Effective < 0 then Exit(0);
  if Effective > 16 then Effective := 16;
  if Effective = 0 then Exit(0);

  Row := GetRow(Direction, Effective);
  if (Length(Row) = 1) and (Row[0] = ZERO_MARKER) then
    Result := 2   // LOADI Dn, #0 (IMM5 form) — 1 word = 2 bytes
  else
    Result := Length(Row) * 2;
end;

initialization
  InitShiftTables;

end.
