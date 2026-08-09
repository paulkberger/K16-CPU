unit K16_Encoder_Stream;

{$mode Delphi}

{
  K16 STREAM Instruction Encoder  (opcode $02)
  ============================================

  Post-increment load/store family. These share the LOADD/LOADB/STORED/STOREB
  mnemonics with the $14/$19 forms; the post-increment addressing form [XYn]+
  selects this $02 encoding instead. Because the assembler dispatches encoders
  by mnemonic (FindEncoder, first match), the Load and Store encoders own those
  mnemonics and DELEGATE here when they detect TMemoryRef.PostIncrement. This
  unit is therefore a stateless helper, not a registered IK16Encoder.

  Syntax:
    LOADD  Dn, [XYn]+            ; word load,  then XYn += 2   (default)
    LOADB  Dn, [XYn]+            ; byte load,  then XYn += 1   (default)
    STORED Dn, [XYn]+            ; word store, then XYn += 2
    STOREB Dn, [XYn]+            ; byte store, then XYn += 1
    <op>   Dn, [XYn]+, #stride   ; explicit stride (raw byte delta 0..31;
                                 ;   'w' suffix = word count x2, handled by the
                                 ;   immediate parser)

  Encoding:
    Bit:  15-11 | 10-9 | 8-7 | 6-5 | 4-0
          00010 | MODE | Dn  | XYn | IMM5 (stride)

    MODE:  00 = LOADD  (load,  word)
           01 = LOADB  (load,  byte)
           10 = STORED (store, word)
           11 = STOREB (store, byte)

  Rules enforced here:
    - Dn must be D0..D3; base must be XY0..XY3; [XYn]+ takes no offset.
    - Default stride: word ops 2, byte ops 1.
    - Stride 0..31 (IMM5); > 31 is an error (use a separate INC).
    - Word ops (LOADD/STORED) require an even stride for alignment.
}

interface

uses
  SysUtils,
  K16_Parser, K16_Encoder_Base;

  // Stateless. IsLoad: True = LOAD*, False = STORE*. IsByte: True = *B (byte).
  function EncodeStream(const Instr: TInstructionRecord;
                        IsLoad, IsByte: Boolean;
                        SymbolResolver: TSymbolResolver;
                        ErrorReporter: TErrorReporter;
                        WarningReporter: TWarningReporter): TMachineCode;

implementation

function EncodeStream(const Instr: TInstructionRecord;
                      IsLoad, IsByte: Boolean;
                      SymbolResolver: TSymbolResolver;
                      ErrorReporter: TErrorReporter;
                      WarningReporter: TWarningReporter): TMachineCode;
var
  OpCode   : Word;
  ModeCode : Byte;
  Dn, XYn  : Integer;
  Stride   : Word;
  MemRef   : TMemoryRef;
  DReg     : TRegister;
  ImmValue : TImmediateValue;
  Mnem     : string;
begin
  // Result defaults
  Result.Address     := Instr.Address;
  Result.SourceLine  := Instr.LineNumber;
  Result.HasImmediate := False;     // single-word instruction (stride is in IMM5)
  Result.Immediate   := 0;
  Result.IsDataWord  := False;
  Result.OpCode      := 0;

  if IsLoad then
    if IsByte then Mnem := 'LOADB' else Mnem := 'LOADD'
  else
    if IsByte then Mnem := 'STOREB' else Mnem := 'STORED';
  Result.CanonicalMnemonic := Mnem;

  // Operand count: 2 (Dn, [XYn]+) or 3 (+ explicit stride)
  if (Length(Instr.Operands) < 2) or (Length(Instr.Operands) > 3) then
  begin
    ErrorReporter(Format('%s [XYn]+ requires 2 or 3 operands: %s Dn, [XYn]+ [, #stride]',
      [Mnem, Mnem]), Instr.LineNumber);
    Exit;
  end;

  // Operand 0: destination/source data register D0..D3
  DReg := TRegister.Parse(Trim(Instr.Operands[0]));
  if (not DReg.IsValid) or (DReg.RegType <> rtData) then
  begin
    ErrorReporter(Format('%s: first operand must be a data register D0-D3, got %s',
      [Mnem, Instr.Operands[0]]), Instr.LineNumber);
    Exit;
  end;
  Dn := DReg.Number;            // 0..3  -> IR8:7

  // Operand 1: post-increment memory reference [XYn]+
  MemRef := TMemoryRef.Parse(Trim(Instr.Operands[1]));
  if not MemRef.PostIncrement then
  begin
    ErrorReporter(Format('%s: expected post-increment reference [XYn]+, got %s',
      [Mnem, Instr.Operands[1]]), Instr.LineNumber);
    Exit;
  end;
  if not MemRef.IsValid then
  begin
    ErrorReporter(Format('%s: post-increment base must be XY0-XY3, got %s',
      [Mnem, Instr.Operands[1]]), Instr.LineNumber);
    Exit;
  end;
  if MemRef.HasOffset or MemRef.HasRegisterOffset or MemRef.HasSymbolOffset then
  begin
    ErrorReporter(Format('%s: post-increment [XYn]+ takes no offset', [Mnem]),
      Instr.LineNumber);
    Exit;
  end;

  if      MemRef.BaseReg = 'XY0' then XYn := 0
  else if MemRef.BaseReg = 'XY1' then XYn := 1
  else if MemRef.BaseReg = 'XY2' then XYn := 2
  else                                XYn := 3;   // 'XY3' (IsValid guaranteed above)

  // Stride: explicit operand 2, else width default (word 2 / byte 1)
  if Length(Instr.Operands) = 3 then
  begin
    ImmValue := TImmediateValue.Parse(Instr.Operands[2]);
    if ImmValue.IsSymbol then
      Stride := Word(SymbolResolver('#' + ImmValue.SymbolName, Instr.LineNumber))
    else
      Stride := Word(ImmValue.Value);   // 'w' suffix already x2 in the parser
  end
  else
  begin
    if IsByte then Stride := 1 else Stride := 2;
  end;

  // Validate stride range (IMM5 = 0..31)
  if Stride > 31 then
  begin
    ErrorReporter(Format('%s: stride %d exceeds maximum 31 (use a separate INC)',
      [Mnem, Stride]), Instr.LineNumber);
    Exit;
  end;

  // Word ops must keep the pointer word-aligned -> even stride
  if (not IsByte) and ((Stride and 1) <> 0) then
  begin
    ErrorReporter(Format('%s: word stride must be even (got %d) to preserve alignment',
      [Mnem, Stride]), Instr.LineNumber);
    Exit;
  end;

  // MODE: load/word=00, load/byte=01, store/word=10, store/byte=11
  if IsLoad then ModeCode := 0 else ModeCode := 2;
  if IsByte then Inc(ModeCode);

  OpCode := $02 shl 11;                          // bits 15-11: opcode $02
  OpCode := OpCode or (Word(ModeCode) shl 9);    // bits 10-9 : mode
  OpCode := OpCode or (Word(Dn) shl 7);          // bits 8-7  : Dn
  OpCode := OpCode or (Word(XYn) shl 5);         // bits 6-5  : XYn
  OpCode := OpCode or (Stride and $1F);          // bits 4-0  : stride (IMM5)

  Result.OpCode := OpCode;
end;

end.
