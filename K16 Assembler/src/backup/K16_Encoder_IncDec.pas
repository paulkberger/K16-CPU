unit K16_Encoder_IncDec;

{$mode Delphi}

{
  K16 INC/DEC Instruction Encoder
  ================================

  Opcode $02: INC/DEC XY pairs with 24-bit carry/borrow

  Encoding:
    Bit:  15-11 | 10-9 | 8-7 | 6-5 | 4-0
          00010 | MODE | 00  | XYn | IMM5

  Modes:
    Mode 00: INC XYn, #imm5  - XYn += imm5 (5 cycles)
    Mode 01: DEC XYn, #imm5  - XYn -= imm5 (6 cycles)

  Syntax for hardware INC/DEC (24-bit, opcode $02):
    INC XYn           ; XYn += 2 (default)
    INC XYn, #imm     ; XYn += imm (0-31)
    DEC XYn           ; XYn -= 2 (default)
    DEC XYn, #imm     ; XYn -= imm (0-31)

  Syntax sugar for D/X/Y registers (assembled as ADD/SUB):
    INC Dn            ; ADD Dn, #1
    INC Dn, #imm      ; ADD Dn, #imm
    INC Xn            ; ADD Xn, #1  (16-bit, NOT 24-bit XY pair!)
    INC Yn            ; ADD Yn, #1  (8-bit)
    DEC Dn            ; SUB Dn, #1
    DEC Dn, #imm      ; SUB Dn, #imm
    DEC Xn            ; SUB Xn, #1
    DEC Yn            ; SUB Yn, #1
}

interface

uses
  SysUtils, StrUtils,
  K16_Parser, K16_Encoder_Base;

type
  TK16IncDecEncoder = class(TK16EncoderBase, IK16Encoder)
  public
    function Encode(const Instr: TInstructionRecord;
                   SymbolResolver: TSymbolResolver;
                   ErrorReporter: TErrorReporter;
                   WarningReporter: TWarningReporter): TMachineCode;
    function GetSupportedMnemonics: TArray<string>;
    function SupportsInstruction(const Mnemonic: string): Boolean;
  private
    function ParseXYPair(const Token: string): Integer;
  end;

implementation

{ TK16IncDecEncoder }

function TK16IncDecEncoder.GetSupportedMnemonics: TArray<string>;
begin
  Result := ['INC', 'DEC'];
end;

function TK16IncDecEncoder.SupportsInstruction(const Mnemonic: string): Boolean;
begin
  Result := SameText(Mnemonic, 'INC') or SameText(Mnemonic, 'DEC');
end;

function TK16IncDecEncoder.ParseXYPair(const Token: string): Integer;
var
  Upper: string;
begin
  Upper := UpperCase(Trim(Token));

  if Upper = 'XY0' then Result := 0
  else if Upper = 'XY1' then Result := 1
  else if Upper = 'XY2' then Result := 2
  else if Upper = 'XY3' then Result := 3
  else Result := -1;  // Invalid
end;

function TK16IncDecEncoder.Encode(const Instr: TInstructionRecord;
                                  SymbolResolver: TSymbolResolver;
                                  ErrorReporter: TErrorReporter;
                                  WarningReporter: TWarningReporter): TMachineCode;
var
  OpCode: Word;
  ModeCode: Byte;
  XYn: Integer;
  Imm5: Word;
  ImmValue: TImmediateValue;
  IsINC: Boolean;
  DestToken: string;
  DestReg: TRegister;
begin
  // Initialize result
  Result.Address := Instr.Address;
  Result.SourceLine := Instr.LineNumber;
  Result.HasImmediate := False;
  Result.Immediate := 0;
  Result.IsDataWord := False;

  IsINC := SameText(Instr.Mnemonic, 'INC');

  // Validate operand count (1 or 2)
  if (Length(Instr.Operands) < 1) or (Length(Instr.Operands) > 2) then
  begin
    ErrorReporter(Format('%s requires 1 or 2 operands: %s dest [, #imm]',
      [Instr.Mnemonic, Instr.Mnemonic]), Instr.LineNumber);
    Result.OpCode := 0;
    Exit;
  end;

  DestToken := Trim(Instr.Operands[0]);

  // Check if destination is an XY pair (hardware INC/DEC)
  XYn := ParseXYPair(DestToken);

  if XYn >= 0 then
  begin
    // Hardware INC/DEC for XY pairs
    if IsINC then
      Result.CanonicalMnemonic := 'INC'
    else
      Result.CanonicalMnemonic := 'DEC';

    // Parse immediate value (if provided)
    if Length(Instr.Operands) = 2 then
    begin
      ImmValue := TImmediateValue.Parse(Instr.Operands[1]);
      if ImmValue.IsSymbol then
        Imm5 := Word(SymbolResolver('#' + ImmValue.SymbolName, Instr.LineNumber))
      else
        Imm5 := Word(ImmValue.Value);

      // Validate IMM5 range (0-31)
      if Imm5 > 31 then
      begin
        ErrorReporter(Format('%s: immediate value %d exceeds maximum 31',
          [Instr.Mnemonic, Imm5]), Instr.LineNumber);
        Result.OpCode := 0;
        Exit;
      end;
    end
    else
    begin
      // Default for XY pairs is 2 (word increment/decrement)
      Imm5 := 2;
    end;

    // Build opcode for XY pair INC/DEC
    // Opcode $02 = 00010
    OpCode := $02 shl 11;  // Bits 15-11: Opcode

    // Mode: 00 = INC, 01 = DEC
    if IsINC then
      ModeCode := 0
    else
      ModeCode := 1;

    OpCode := OpCode or (Word(ModeCode) shl 9);  // Bits 10-9: Mode

    // Bits 8-7: Must be 00 (zero field)
    // Already 0

    // Bits 6-5: XYn
    OpCode := OpCode or (Word(XYn) shl 5);

    // Bits 4-0: IMM5
    OpCode := OpCode or (Imm5 and $1F);

    Result.OpCode := OpCode;
    Exit;
  end;

  // Not an XY pair - check if it's D, X, or Y register (syntax sugar -> ADD/SUB)
  DestReg := TRegister.Parse(DestToken);

  if not DestReg.IsValid then
  begin
    ErrorReporter(Format('%s: invalid destination register: %s',
      [Instr.Mnemonic, DestToken]), Instr.LineNumber);
    Result.OpCode := 0;
    Exit;
  end;

  // Must be D, X, or Y register for syntax sugar
  if not (DestReg.RegType in [rtData, rtIndexX, rtIndexY]) then
  begin
    ErrorReporter(Format('%s: destination must be XY0-XY3, D0-D3, X0-X3, or Y0-Y3, got: %s',
      [Instr.Mnemonic, DestToken]), Instr.LineNumber);
    Result.OpCode := 0;
    Exit;
  end;

  // Syntax sugar: INC reg -> ADD reg, #1; DEC reg -> SUB reg, #1

  // Determine immediate value
  if Length(Instr.Operands) = 2 then
  begin
    ImmValue := TImmediateValue.Parse(Instr.Operands[1]);
    if ImmValue.IsSymbol then
      Imm5 := Word(SymbolResolver('#' + ImmValue.SymbolName, Instr.LineNumber))
    else
      Imm5 := Word(ImmValue.Value);
  end
  else
  begin
    // Default for D/X/Y registers is 1
    Imm5 := 1;
  end;

  // Check if fits in IMM5 (0-31)
  if Imm5 <= 31 then
  begin
    // Encode as ADD/SUB Mode 10 (IMM5 fast path)
    // ADD = $08, SUB = $0A
    if IsINC then
    begin
      OpCode := $08 shl 11;  // ADD opcode
      Result.CanonicalMnemonic := 'ADD';
    end
    else
    begin
      OpCode := $0A shl 11;  // SUB opcode
      Result.CanonicalMnemonic := 'SUB';
    end;

    // Mode 10 = IMM5 fast path
    OpCode := OpCode or ($02 shl 9);  // Mode bits 10-9 = 10

    // Destination register in bits 8-5 (4-bit encoding)
    OpCode := OpCode or (Word(DestReg.Encode) shl 5);

    // IMM5 in bits 4-0
    OpCode := OpCode or (Imm5 and $1F);

    Result.OpCode := OpCode;
    Result.HasImmediate := False;
  end
  else
  begin
    // Encode as ADD/SUB Mode 11 (IMM16)
    if IsINC then
    begin
      OpCode := $08 shl 11;  // ADD opcode
      Result.CanonicalMnemonic := 'ADD';
    end
    else
    begin
      OpCode := $0A shl 11;  // SUB opcode
      Result.CanonicalMnemonic := 'SUB';
    end;

    // Mode 11 = IMM16
    OpCode := OpCode or ($03 shl 9);  // Mode bits 10-9 = 11

    // Destination register in bits 8-5
    OpCode := OpCode or (Word(DestReg.Encode) shl 5);

    Result.OpCode := OpCode;
    Result.HasImmediate := True;
    Result.Immediate := Imm5;
  end;
end;

end.
