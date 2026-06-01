unit K16_Encoder_Jump;

{$mode Delphi}

interface

uses
  SysUtils, StrUtils,
  K16_Parser, K16_Encoder_Base;

type
  TK16JumpEncoder = class(TK16EncoderBase, IK16Encoder)
  public
    function Encode(const Instr: TInstructionRecord;
                   SymbolResolver: TSymbolResolver;
                   ErrorReporter: TErrorReporter;
                   WarningReporter: TWarningReporter): TMachineCode;
    function GetSupportedMnemonics: TArray<string>;
    function SupportsInstruction(const Mnemonic: string): Boolean;
  end;

implementation

{ TK16JumpEncoder }

function TK16JumpEncoder.GetSupportedMnemonics: TArray<string>;
begin
  Result := ['JMP', 'JMP24', 'JMP16', 'JMPT', 'JMPXY'];
end;

function TK16JumpEncoder.SupportsInstruction(const Mnemonic: string): Boolean;
var
  Supported: TArray<string>;
  i: Integer;
begin
  Supported := GetSupportedMnemonics;
  for i := 0 to High(Supported) do
    if SameText(Mnemonic, Supported[i]) then
      Exit(True);
  Result := False;
end;

function TK16JumpEncoder.Encode(const Instr: TInstructionRecord;
                               SymbolResolver: TSymbolResolver;
                               ErrorReporter: TErrorReporter;
                               WarningReporter: TWarningReporter): TMachineCode;
var
  OpCode: Word;
  JumpAddress: Integer;
  XYReg, DReg: Integer;
  ImmValue: TImmediateValue;
begin
  Result.Address := Instr.Address;
  Result.SourceLine := Instr.LineNumber;
  Result.HasImmediate := False;
  Result.Immediate := 0;

  // JMP or JMP24 - 24-bit absolute (Mode 00)
  if SameText(Instr.Mnemonic, 'JMP') or SameText(Instr.Mnemonic, 'JMP24') then
  begin
    Result.HasImmediate := True;

    if Length(Instr.Operands) < 1 then
    begin
      ErrorReporter('JMP24 requires target address', Instr.LineNumber);
      Exit;
    end;

    // Parse address: #$hex, #symbol, $hex, or symbol
    if Instr.Operands[0].StartsWith('#') then
    begin
      ImmValue := TImmediateValue.Parse(Instr.Operands[0]);
      JumpAddress := ResolveImmediate(ImmValue, SymbolResolver, Instr.LineNumber);
    end
    else if Instr.Operands[0].StartsWith('$') then
      JumpAddress := StrToIntDef('$' + Copy(Instr.Operands[0], 2, MaxInt), 0)
    else
      // Symbol target — prepend '#' for expression support (e.g. 'JMP24 func+4').
      JumpAddress := SymbolResolver('#' + Instr.Operands[0], Instr.LineNumber);

    // Validate even address
    if (JumpAddress and 1) <> 0 then
    begin
      ErrorReporter(Format('Jump target $%06X is odd - K16 requires even addresses', [JumpAddress]), Instr.LineNumber);
      JumpAddress := JumpAddress and $FFFFFFFE;
    end;

    // JMP24: Opcode 0x12, Mode 00, bits 7-0 = A23-A16
    OpCode := ($12 shl 11) or
              (0 shl 9) or
              ((JumpAddress shr 16) and $FF);
    Result.Immediate := JumpAddress and $FFFF;
  end

  // JMP16 - 16-bit jump within current page (Mode 01)
  else if SameText(Instr.Mnemonic, 'JMP16') then
  begin
    Result.HasImmediate := True;

    if Length(Instr.Operands) < 1 then
    begin
      ErrorReporter('JMP16 requires target address', Instr.LineNumber);
      Exit;
    end;

    // Parse address: #$hex, #symbol, $hex, or symbol
    if Instr.Operands[0].StartsWith('#') then
    begin
      ImmValue := TImmediateValue.Parse(Instr.Operands[0]);
      JumpAddress := ResolveImmediate(ImmValue, SymbolResolver, Instr.LineNumber);
    end
    else if Instr.Operands[0].StartsWith('$') then
      JumpAddress := StrToIntDef('$' + Copy(Instr.Operands[0], 2, MaxInt), 0)
    else
      // Symbol target — prepend '#' for expression support.
      JumpAddress := SymbolResolver('#' + Instr.Operands[0], Instr.LineNumber);

    // Validate even address
    if (JumpAddress and 1) <> 0 then
    begin
      ErrorReporter(Format('Jump target $%04X is odd - K16 requires even addresses', [JumpAddress and $FFFF]), Instr.LineNumber);
      JumpAddress := JumpAddress and $FFFFFFFE;
    end;

    // Warn if high byte non-zero (page change ignored)
    if (JumpAddress and $FF0000) <> 0 then
      WarningReporter(Format('JMP16 ignores page byte - target $%06X will jump to $%04X in current page',
                             [JumpAddress, JumpAddress and $FFFF]), Instr.LineNumber);

    // JMP16: Opcode 0x12, Mode 01, bits 8-0 = 0
    OpCode := ($12 shl 11) or (1 shl 9);
    Result.Immediate := JumpAddress and $FFFF;
  end

  // JMPT - Jump table indexed indirect (Mode 10)
  // Syntax: JMPT XYn, Dm
  else if SameText(Instr.Mnemonic, 'JMPT') then
  begin
    if Length(Instr.Operands) < 2 then
    begin
      ErrorReporter('JMPT requires XY register and D register: JMPT XYn, Dm', Instr.LineNumber);
      Exit;
    end;

    // Parse XY register (first operand): XY0-XY3
    XYReg := -1;
    if SameText(Instr.Operands[0], 'XY0') then XYReg := 0
    else if SameText(Instr.Operands[0], 'XY1') then XYReg := 1
    else if SameText(Instr.Operands[0], 'XY2') then XYReg := 2
    else if SameText(Instr.Operands[0], 'XY3') then XYReg := 3;
    if XYReg < 0 then
    begin
      ErrorReporter(Format('Invalid XY register pair: %s (expected XY0-XY3)', [Instr.Operands[0]]), Instr.LineNumber);
      Exit;
    end;

    // Parse D register (second operand): D0-D3
    DReg := -1;
    if SameText(Instr.Operands[1], 'D0') then DReg := 0
    else if SameText(Instr.Operands[1], 'D1') then DReg := 1
    else if SameText(Instr.Operands[1], 'D2') then DReg := 2
    else if SameText(Instr.Operands[1], 'D3') then DReg := 3;
    if DReg < 0 then
    begin
      ErrorReporter(Format('Invalid D register: %s (expected D0-D3)', [Instr.Operands[1]]), Instr.LineNumber);
      Exit;
    end;

    // JMPT: Opcode 0x12, Mode 10, bits 8-7 = d, bits 6-5 = xy, bits 4-0 = 0
    // Note: A0 not connected to ROMs, so IR bits shift down by 1 in ROM address
    OpCode := ($12 shl 11) or
              (2 shl 9) or
              (DReg shl 7) or
              (XYReg shl 5);
  end

  // JMPXY - Indirect jump via XY pair (Mode 11)
  // Syntax: JMPXY XYn
  else if SameText(Instr.Mnemonic, 'JMPXY') then
  begin
    if Length(Instr.Operands) < 1 then
    begin
      ErrorReporter('JMPXY requires XY register pair: JMPXY XYn', Instr.LineNumber);
      Exit;
    end;

    // Parse XY register: XY0-XY3
    XYReg := -1;
    if SameText(Instr.Operands[0], 'XY0') then XYReg := 0
    else if SameText(Instr.Operands[0], 'XY1') then XYReg := 1
    else if SameText(Instr.Operands[0], 'XY2') then XYReg := 2
    else if SameText(Instr.Operands[0], 'XY3') then XYReg := 3;
    if XYReg < 0 then
    begin
      ErrorReporter(Format('Invalid XY register pair: %s (expected XY0-XY3)', [Instr.Operands[0]]), Instr.LineNumber);
      Exit;
    end;

    // JMPXY: Opcode 0x12, Mode 11, bits 8-7 = 0, bits 6-5 = xy, bits 4-0 = 0
    // Note: A0 not connected to ROMs, so IR bits shift down by 1 in ROM address
    OpCode := ($12 shl 11) or
              (3 shl 9) or
              (XYReg shl 5);
  end

  else
  begin
    ErrorReporter(Format('Unknown jump instruction: %s', [Instr.Mnemonic]), Instr.LineNumber);
    OpCode := 0;
  end;

  Result.OpCode := OpCode;
end;

end.
