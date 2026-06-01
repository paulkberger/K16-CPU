unit K16_Encoder_PushPop;

{$mode Delphi}

interface

uses
  SysUtils, StrUtils,
  K16_Parser, K16_Encoder_Base;

type
  TK16PushPopEncoder = class(TK16EncoderBase, IK16Encoder)
  private
    function GetXYStackNumber(const StackName: string): Byte;
    function EncodeDRegister(const RegName: string): Byte;
    function EncodeAllRegisters(const RegName: string): Byte;
    function EncodeXYSpecialRegister(const RegName: string): Byte;
    function IsRegisterGroup(const Name: string): Boolean;
    function EncodeRegisterGroup(const GroupName: string): Byte;
    function IsXYPair(const Name: string): Boolean;
    function EncodeXYPair(const PairName: string): Byte;
    function IsDRegister(const Name: string): Boolean;
    function IsXYSpecialRegister(const Name: string): Boolean;
  public
    function Encode(const Instr: TInstructionRecord;
                   SymbolResolver: TSymbolResolver;
                   ErrorReporter: TErrorReporter;
                   WarningReporter: TWarningReporter): TMachineCode;
    function GetSupportedMnemonics: TArray<string>;
    function SupportsInstruction(const Mnemonic: string): Boolean;
  end;

implementation

{ TK16PushPopEncoder }

function TK16PushPopEncoder.GetSupportedMnemonics: TArray<string>;
begin
  Result := ['PUSH', 'POP'];
end;

function TK16PushPopEncoder.SupportsInstruction(const Mnemonic: string): Boolean;
begin
  Result := SameText(Mnemonic, 'PUSH') or SameText(Mnemonic, 'POP');
end;

function TK16PushPopEncoder.GetXYStackNumber(const StackName: string): Byte;
begin
  if SameText(StackName, 'XY0') then Result := 0
  else if SameText(StackName, 'XY1') then Result := 1
  else if SameText(StackName, 'XY2') then Result := 2
  else if SameText(StackName, 'XY3') then Result := 3
  else Result := 255; // Invalid
end;

function TK16PushPopEncoder.IsDRegister(const Name: string): Boolean;
begin
  Result := SameText(Name, 'D0') or SameText(Name, 'D1') or
            SameText(Name, 'D2') or SameText(Name, 'D3');
end;

function TK16PushPopEncoder.IsXYSpecialRegister(const Name: string): Boolean;
begin
  // X0-X3, Y0-Y3, ORDB, SR, PCH, PCL
  Result := SameText(Name, 'X0') or SameText(Name, 'X1') or
            SameText(Name, 'X2') or SameText(Name, 'X3') or
            SameText(Name, 'Y0') or SameText(Name, 'Y1') or
            SameText(Name, 'Y2') or SameText(Name, 'Y3') or
            SameText(Name, 'ORDB') or SameText(Name, 'SR') or
            SameText(Name, 'PCH') or SameText(Name, 'PCL');
end;

function TK16PushPopEncoder.IsRegisterGroup(const Name: string): Boolean;
begin
  Result := SameText(Name, 'D') or SameText(Name, 'X') or SameText(Name, 'Y');
end;

function TK16PushPopEncoder.EncodeRegisterGroup(const GroupName: string): Byte;
begin
  // IR8-IR7 encoding for groups (IR6-IR5 = 00)
  if SameText(GroupName, 'D') then Result := 0      // 00
  else if SameText(GroupName, 'X') then Result := 1  // 01
  else if SameText(GroupName, 'Y') then Result := 2  // 10
  else Result := 255; // Invalid
end;

function TK16PushPopEncoder.IsXYPair(const Name: string): Boolean;
begin
  Result := SameText(Name, 'XY0') or SameText(Name, 'XY1') or
            SameText(Name, 'XY2') or SameText(Name, 'XY3');
end;

function TK16PushPopEncoder.EncodeXYPair(const PairName: string): Byte;
begin
  // IR8-IR7 encoding for XY pairs (IR6-IR5 = 00)
  if SameText(PairName, 'XY0') then Result := 0
  else if SameText(PairName, 'XY1') then Result := 1
  else if SameText(PairName, 'XY2') then Result := 2
  else if SameText(PairName, 'XY3') then Result := 3
  else Result := 255; // Invalid
end;

function TK16PushPopEncoder.EncodeDRegister(const RegName: string): Byte;
begin
  // MODE 00 D register encoding (IR8-IR5) - PUSH only
  if SameText(RegName, 'D0') then Result := $0
  else if SameText(RegName, 'D1') then Result := $1
  else if SameText(RegName, 'D2') then Result := $2
  else if SameText(RegName, 'D3') then Result := $3
  else Result := 255; // Invalid
end;

function TK16PushPopEncoder.EncodeXYSpecialRegister(const RegName: string): Byte;
begin
  // MODE 11 PUSH register encoding (IR8-IR5)
  // X0-X3
  if SameText(RegName, 'X0') then Result := $4
  else if SameText(RegName, 'X1') then Result := $5
  else if SameText(RegName, 'X2') then Result := $6
  else if SameText(RegName, 'X3') then Result := $7
  // Y0-Y3
  else if SameText(RegName, 'Y0') then Result := $8
  else if SameText(RegName, 'Y1') then Result := $9
  else if SameText(RegName, 'Y2') then Result := $A
  else if SameText(RegName, 'Y3') then Result := $B
  // Special registers
  else if SameText(RegName, 'ORDB') then Result := $C
  else if SameText(RegName, 'SR') then Result := $D
  else if SameText(RegName, 'PCH') then Result := $E
  else if SameText(RegName, 'PCL') then Result := $F
  else Result := 255; // Invalid
end;

function TK16PushPopEncoder.EncodeAllRegisters(const RegName: string): Byte;
begin
  // MODE 00 POP register encoding (IR8-IR5)
  // D0-D3
  if SameText(RegName, 'D0') then Result := $0
  else if SameText(RegName, 'D1') then Result := $1
  else if SameText(RegName, 'D2') then Result := $2
  else if SameText(RegName, 'D3') then Result := $3
  // X0-X3
  else if SameText(RegName, 'X0') then Result := $4
  else if SameText(RegName, 'X1') then Result := $5
  else if SameText(RegName, 'X2') then Result := $6
  else if SameText(RegName, 'X3') then Result := $7
  // Y0-Y3
  else if SameText(RegName, 'Y0') then Result := $8
  else if SameText(RegName, 'Y1') then Result := $9
  else if SameText(RegName, 'Y2') then Result := $A
  else if SameText(RegName, 'Y3') then Result := $B
  // Special registers - only SR can be POPped
  else if SameText(RegName, 'SR') then Result := $D
  else Result := 255; // Invalid
end;

function TK16PushPopEncoder.Encode(const Instr: TInstructionRecord;
                               SymbolResolver: TSymbolResolver;
                               ErrorReporter: TErrorReporter;
                   WarningReporter: TWarningReporter): TMachineCode;
var
  OpCode: Word;
  ModeCode: Byte;
  RegCode: Byte;
  XYStack: Byte;
  IsPush: Boolean;
  FirstOperand: string;
  ImmValue: Integer;
  ImmParsed: TImmediateValue;
begin
  // Initialize result
  Result.Address := Instr.Address;
  Result.SourceLine := Instr.LineNumber;
  Result.HasImmediate := False;
  Result.Immediate := 0;

  IsPush := SameText(Instr.Mnemonic, 'PUSH');

  // Both PUSH and POP require exactly 2 operands
  if Length(Instr.Operands) <> 2 then
  begin
    ErrorReporter(Format('%s requires exactly 2 operands', [Instr.Mnemonic]), Instr.LineNumber);
    Result.OpCode := 0;
    Exit;
  end;

  FirstOperand := Trim(Instr.Operands[0]);

  // Parse XY stack (second operand)
  XYStack := GetXYStackNumber(Instr.Operands[1]);
  if XYStack = 255 then
  begin
    ErrorReporter(Format('Invalid stack specification: %s (must be XY0, XY1, XY2, or XY3)',
                        [Instr.Operands[1]]), Instr.LineNumber);
    Result.OpCode := 0;
    Exit;
  end;

  // Determine MODE and encode based on first operand type and operation
  if FirstOperand.StartsWith('#') then
  begin
    // Immediate value - V4.0: PUSH #IMM is encoded as POP opcode MODE 11
    if IsPush then
    begin
      // User writes PUSH #value, assembles as POP opcode MODE 11
      OpCode := $07 shl 11;  // POP opcode
      ModeCode := 3;          // MODE 11

      ImmParsed := TImmediateValue.Parse(FirstOperand);
      ImmValue := ResolveImmediate(ImmParsed, SymbolResolver, Instr.LineNumber);

      if (ImmValue < 0) or (ImmValue > $FFFF) then
      begin
        ErrorReporter(Format('Immediate value $%X out of range (0-$FFFF)', [ImmValue]),
                     Instr.LineNumber);
      end;

      Result.HasImmediate := True;
      Result.Immediate := ImmValue and $FFFF;
      RegCode := 0; // IR8-IR5 = 0000 for PUSH #IMM
    end
    else
    begin
      // POP with immediate - not valid
      ErrorReporter('POP does not support immediate values. Use PUSH #value, XYn instead.',
                   Instr.LineNumber);
      Result.OpCode := 0;
      Exit;
    end;
  end
  else if IsRegisterGroup(FirstOperand) then
  begin
    // MODE 01: Register group (D only for now)
    if not SameText(FirstOperand, 'D') then
    begin
      ErrorReporter('Only D group supported in MODE 01', Instr.LineNumber);
      Result.OpCode := 0;
      Exit;
    end;

    // Determine opcode
    if IsPush then
      OpCode := $06 shl 11
    else
      OpCode := $07 shl 11;

    ModeCode := 1;
    RegCode := 0; // D group = 00 in IR8-IR7, IR6-IR5 = 00
  end
  else if IsXYPair(FirstOperand) then
  begin
    // MODE 10: XY pair
    // Determine opcode
    if IsPush then
      OpCode := $06 shl 11
    else
      OpCode := $07 shl 11;

    ModeCode := 2;
    RegCode := EncodeXYPair(FirstOperand);

    if RegCode = 255 then
    begin
      ErrorReporter(Format('Invalid XY pair: %s', [FirstOperand]), Instr.LineNumber);
      Result.OpCode := 0;
      Exit;
    end;

    // Pair code goes in IR8-IR7, IR6-IR5 = 00
    RegCode := RegCode shl 2;
  end
  else
  begin
    // MODE 00: Single register
    // For PUSH: only D registers allowed
    // For POP: all registers allowed

    if IsPush then
    begin
      // PUSH MODE 00: Only D registers
      if not IsDRegister(FirstOperand) then
      begin
        // Check if it's an X/Y/special register
        if IsXYSpecialRegister(FirstOperand) then
        begin
          // Use MODE 11 for X/Y/special registers
          OpCode := $06 shl 11;  // PUSH opcode
          ModeCode := 3;          // MODE 11
          RegCode := EncodeXYSpecialRegister(FirstOperand);

          if RegCode = 255 then
          begin
            ErrorReporter(Format('Invalid register: %s', [FirstOperand]), Instr.LineNumber);
            Result.OpCode := 0;
            Exit;
          end;
        end
        else
        begin
          ErrorReporter(Format('PUSH MODE 00 only accepts D registers (D0-D3). Use MODE 11 for X/Y/special: %s',
                              [FirstOperand]), Instr.LineNumber);
          Result.OpCode := 0;
          Exit;
        end;
      end
      else
      begin
        // Valid D register for PUSH MODE 00
        OpCode := $06 shl 11;
        ModeCode := 0;
        RegCode := EncodeDRegister(FirstOperand);

        if RegCode = 255 then
        begin
          ErrorReporter(Format('Invalid D register: %s', [FirstOperand]), Instr.LineNumber);
          Result.OpCode := 0;
          Exit;
        end;
      end;
    end
    else
    begin
      // POP MODE 00: All registers allowed
      OpCode := $07 shl 11;
      ModeCode := 0;
      RegCode := EncodeAllRegisters(FirstOperand);

      if RegCode = 255 then
      begin
        ErrorReporter(Format('Invalid register: %s', [FirstOperand]), Instr.LineNumber);
        Result.OpCode := 0;
        Exit;
      end;
    end;
  end;

  // Build complete opcode
  // Bits 15-11: Opcode (0x06 for PUSH, 0x07 for POP)
  // Bits 10-9:  MODE
  // Bits 8-5:   REG (4 bits)
  // Bits 4-3:   Fixed 00
  // Bits 2-1:   XY stack
  // Bit 0:      Reserved 0

  OpCode := OpCode or (ModeCode shl 9);        // MODE bits 10-9
  OpCode := OpCode or (RegCode shl 5);         // REG bits 8-5
  // Bits 4-3 are already 0
  OpCode := OpCode or (XYStack shl 1);         // XY stack bits 2-1
  // Bit 0 is already 0

  Result.OpCode := OpCode;
end;

end.
