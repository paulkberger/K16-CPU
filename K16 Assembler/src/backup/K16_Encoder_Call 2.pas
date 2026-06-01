unit K16_Encoder_Call;

{$mode Delphi}

interface

uses
  SysUtils, StrUtils,
  K16_Parser, K16_Encoder_Base;

type
  TK16CallEncoder = class(TK16EncoderBase, IK16Encoder)
  public
    function Encode(const Instr: TInstructionRecord;
                   SymbolResolver: TSymbolResolver;
                   ErrorReporter: TErrorReporter;
                   WarningReporter: TWarningReporter): TMachineCode;
    function GetSupportedMnemonics: TArray<string>;
    function SupportsInstruction(const Mnemonic: string): Boolean;
  end;

implementation

{ TK16CallEncoder }

function TK16CallEncoder.GetSupportedMnemonics: TArray<string>;
begin
  Result := ['CALL', 'CALL24', 'CALL16', 'CALLR', 'CALLXY'];
end;

function TK16CallEncoder.SupportsInstruction(const Mnemonic: string): Boolean;
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

function TK16CallEncoder.Encode(const Instr: TInstructionRecord;
                               SymbolResolver: TSymbolResolver;
                               ErrorReporter: TErrorReporter;
                   WarningReporter: TWarningReporter): TMachineCode;
var
  OpCode: Word;
  TargetAddress: Integer;
  Offset: Integer;
  Mode: Byte;
  ActualMnemonic: string;
  ImmValue: TImmediateValue;
  OffsetStr: string;
  OperandStr: string;
begin

  // Initialize result
  Result.Address := Instr.Address;
  Result.SourceLine := Instr.LineNumber;
  Result.HasImmediate := False;
  Result.Immediate := 0;

  // Resolve CALL to CALL24 (default)
  if SameText(Instr.Mnemonic, 'CALL') then
  begin
    ActualMnemonic := 'CALL24';
    Result.CanonicalMnemonic := 'CALL24';  // Always show CALL24 in listing
  end
  else
  begin
    ActualMnemonic := Instr.Mnemonic;
    Result.CanonicalMnemonic := Instr.Mnemonic;
  end;

  // CALL variants use opcode $13:
  // Mode 00: CALL24 - 24-bit absolute call (4 bytes)
  // Mode 01: CALL16 - 16-bit absolute call (3 bytes)
  // Mode 10: CALLR  - PC-relative call (3 bytes)
  // Mode 11: CALLXY - indirect call via XY register (2 bytes)
  //
  // RET/TRAP use opcode $1E:
  // Mode 00: TRAP #n - software trap/syscall (2 bytes)
  // Mode 11: RET     - return with optional cleanup (2 bytes)

  if SameText(ActualMnemonic, 'CALL24') then
  begin
    Mode := 0;  // Mode 00
    Result.HasImmediate := True;

    // Resolve target address
    if Length(Instr.Operands) >= 1 then
    begin
      if Instr.Operands[0].StartsWith('#') then
      begin
        // Immediate address: CALL24 #$123456
        ImmValue := TImmediateValue.Parse(Instr.Operands[0]);
        TargetAddress := ResolveImmediate(ImmValue, SymbolResolver, Instr.LineNumber);
      end
      else if Instr.Operands[0].StartsWith('$') then
      begin
        // Direct hex address: CALL24 $123456
        try
          TargetAddress := StrToInt('$' + Copy(Instr.Operands[0], 2, MaxInt));
        except
          ErrorReporter('Invalid hex address in CALL24', Instr.LineNumber);
          TargetAddress := 0;
        end;
      end
      else
      begin
        // Symbol address: CALL24 SUBROUTINE
        TargetAddress := SymbolResolver(Instr.Operands[0], Instr.LineNumber);
      end;
    end
    else
    begin
      ErrorReporter('CALL24 requires target address', Instr.LineNumber);
      TargetAddress := 0;
    end;

    // Validate even address for word-aligned architecture
    if (TargetAddress and 1) <> 0 then
    begin
      ErrorReporter(Format('CALL24 target $%06X is odd - K16 requires even addresses', [TargetAddress]), Instr.LineNumber);
      TargetAddress := TargetAddress and $FFFFFFFE;
    end;

    // Validate 24-bit range
    if (TargetAddress < 0) or (TargetAddress > $FFFFFF) then
    begin
      ErrorReporter(Format('CALL24 target $%06X out of 24-bit range', [TargetAddress]), Instr.LineNumber);
      TargetAddress := TargetAddress and $FFFFFF;
    end;

    // Encoding: [opcode $13][addr[23:16]] [addr[15:0]]
    // OpCode word: bits 15-11 = opcode (0x13 = 10011)
    //              bits 10-9 = mode (00)
    //              bits 8 = unused (0)
    //              bits 7-0 = addr[23:16]
    OpCode := ($13 shl 11) or                     // Opcode 0x13
              (Mode shl 9) or                     // Mode 00
              ((TargetAddress shr 16) and $FF);   // High 8 bits

    Result.Immediate := TargetAddress and $FFFF;  // Low 16 bits
  end
  else if SameText(ActualMnemonic, 'CALL16') then
  begin
    Mode := 1;  // Mode 01
    Result.HasImmediate := True;

    // Resolve target address (16-bit within current page)
    if Length(Instr.Operands) >= 1 then
    begin
      if Instr.Operands[0].StartsWith('#') then
      begin
        ImmValue := TImmediateValue.Parse(Instr.Operands[0]);
        TargetAddress := ResolveImmediate(ImmValue, SymbolResolver, Instr.LineNumber);
      end
      else if Instr.Operands[0].StartsWith('$') then
      begin
        try
          TargetAddress := StrToInt('$' + Copy(Instr.Operands[0], 2, MaxInt));
        except
          ErrorReporter('Invalid hex address in CALL16', Instr.LineNumber);
          TargetAddress := 0;
        end;
      end
      else
      begin
        TargetAddress := SymbolResolver(Instr.Operands[0], Instr.LineNumber);
      end;
    end
    else
    begin
      ErrorReporter('CALL16 requires target address', Instr.LineNumber);
      TargetAddress := 0;
    end;

    // Validate even address
    if (TargetAddress and 1) <> 0 then
    begin
      ErrorReporter(Format('CALL16 target $%04X is odd - K16 requires even addresses', [TargetAddress]), Instr.LineNumber);
      TargetAddress := TargetAddress and $FFFFFFFE;
    end;

    // Validate 16-bit range
    if (TargetAddress < 0) or (TargetAddress > $FFFF) then
    begin
      ErrorReporter(Format('CALL16 target $%04X out of 16-bit range', [TargetAddress]), Instr.LineNumber);
      TargetAddress := TargetAddress and $FFFF;
    end;

    // Encoding: [opcode $13][unused 8 bits] [addr[15:0]]
    OpCode := ($13 shl 11) or     // Opcode 0x13
              (Mode shl 9) or     // Mode 01
              0;                  // Unused bits 8-0 = 0

    Result.Immediate := TargetAddress and $FFFF;
  end
  else if SameText(ActualMnemonic, 'CALLR') then
  begin
    Mode := 2;  // Mode 10
    Result.HasImmediate := True;

    // Resolve offset (signed 16-bit, PC-relative)
    if Length(Instr.Operands) >= 1 then
    begin
      if Instr.Operands[0].StartsWith('#+') or Instr.Operands[0].StartsWith('#-') then
      begin
        // Relative offset: CALLR #+1000 or CALLR #-500
        OffsetStr := Copy(Instr.Operands[0], 2, MaxInt); // Remove '#'
        try
          if OffsetStr.StartsWith('$') then
            Offset := StrToInt(OffsetStr)
          else
            Offset := StrToInt(OffsetStr);
        except
          ErrorReporter('Invalid offset in CALLR', Instr.LineNumber);
          Offset := 0;
        end;
      end
      else if Instr.Operands[0].StartsWith('#') then
      begin
        // Immediate offset value
        ImmValue := TImmediateValue.Parse(Instr.Operands[0]);
        Offset := Integer(ResolveImmediate(ImmValue, SymbolResolver, Instr.LineNumber));
      end
      else
      begin
        // Symbol - calculate offset from current PC
        // PC after instruction fetch = current address + 4
        // Offset = Target - (PC + 4)
        TargetAddress := SymbolResolver(Instr.Operands[0], Instr.LineNumber);
        Offset := TargetAddress - Integer(Instr.Address + 4);
      end;
    end
    else
    begin
      ErrorReporter('CALLR requires offset or target label', Instr.LineNumber);
      Offset := 0;
    end;

    // Validate offset is even (word-aligned)
    if (Offset and 1) <> 0 then
    begin
      ErrorReporter(Format('CALLR offset %d is odd - K16 requires even offsets', [Offset]), Instr.LineNumber);
      Offset := Offset and $FFFFFFFE;
    end;

    // Validate signed 16-bit range (�32KB)
    if (Offset < -32768) or (Offset > 32767) then
    begin
      ErrorReporter(Format('CALLR offset %d out of range (�32KB)', [Offset]), Instr.LineNumber);
    end;

    // Encoding: [opcode $13][unused 8 bits] [signed_offset[15:0]]
    OpCode := ($13 shl 11) or     // Opcode 0x13
              (Mode shl 9) or     // Mode 10
              0;                  // Unused bits 8-0 = 0

    Result.Immediate := Word(Offset and $FFFF);  // Store as unsigned word
  end
  else if SameText(ActualMnemonic, 'CALLXY') then
  begin
    // CALLXY XYn — opcode $13 mode 11, IR[6:5] = XY register number
    // Encoding: ($13 shl 11) or (3 shl 9) or (XYn shl 5)
    Result.HasImmediate := False;
    if Length(Instr.Operands) < 1 then
    begin
      ErrorReporter('CALLXY requires XY register operand (XY0-XY3)', Instr.LineNumber);
      OpCode := 0;
    end
    else
    begin
      OperandStr := UpperCase(Trim(Instr.Operands[0]));
      if      OperandStr = 'XY0' then OpCode := ($13 shl 11) or (3 shl 9) or (0 shl 5)
      else if OperandStr = 'XY1' then OpCode := ($13 shl 11) or (3 shl 9) or (1 shl 5)
      else if OperandStr = 'XY2' then OpCode := ($13 shl 11) or (3 shl 9) or (2 shl 5)
      else if OperandStr = 'XY3' then OpCode := ($13 shl 11) or (3 shl 9) or (3 shl 5)
      else
      begin
        ErrorReporter(Format('CALLXY operand must be XY0-XY3, got "%s"', [Instr.Operands[0]]), Instr.LineNumber);
        OpCode := 0;
      end;
    end;
  end
  else
  begin
    ErrorReporter(Format('Unknown CALL instruction: %s', [ActualMnemonic]), Instr.LineNumber);
    OpCode := 0;
  end;

  Result.OpCode := OpCode;
end;

end.
