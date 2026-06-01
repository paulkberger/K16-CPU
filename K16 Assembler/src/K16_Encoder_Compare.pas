 unit K16_Encoder_Compare;

{$mode Delphi}

{
  K16 CMP Instruction Encoder
  ==========================

  Encodes CMP (Compare) instructions for the K16 CPU.
  CMP uses the same modes as other ALU instructions (ADD, SUB, etc.)

  CMP Instruction Modes:
  - Mode 00: CMP reg, reg     (register to register)
  - Mode 01: CMP reg, [XY]    (register to memory)
  - Mode 10: CMP reg, #imm5   (register to 5-bit immediate, 0-31)
  - Mode 11: CMP reg, #imm16  (register to 16-bit immediate)

  Register Encoding (4-bit):
    0x0: D0    0x4: X0    0x8: Y0    0xC: ORDB
    0x1: D1    0x5: X1    0x9: Y1    0xD: SR
    0x2: D2    0x6: X2    0xA: Y2    0xE: PCH
    0x3: D3    0x7: X3    0xB: Y3    0xF: PCL

  Instruction Encoding:
  Mode 00: [OPCODE:5][00][DEST:4][SRC:4][0]
  Mode 01: [OPCODE:5][01][DEST:4][unused:2][XY:2][0]
  Mode 10: [OPCODE:5][10][DEST:4][IMM5:5]
  Mode 11: [OPCODE:5][11][DEST:4][unused:5] + IMM16

  NOTE: Destination registers limited to D0-D3, X0-X3, Y0-Y3 (codes 0-11)
        Source registers in Mode 00 can use full 16 codes (0-15)
        Y registers are 8-bit (zero-extended for comparison)
}

interface

uses
  SysUtils, StrUtils,
  K16_Parser, K16_Encoder_Base;

type
  TK16CompareEncoder = class(TK16EncoderBase, IK16Encoder)
  private
    function GetFullRegisterCode(RegType: TRegisterType; Number: Integer): Integer;
    function ValidateCompareConstraints(const Instr: TInstructionRecord;
                                       ErrorReporter: TErrorReporter): Boolean;
  public
    function Encode(const Instr: TInstructionRecord;
                   SymbolResolver: TSymbolResolver;
                   ErrorReporter: TErrorReporter;
                   WarningReporter: TWarningReporter): TMachineCode;
    function GetSupportedMnemonics: TArray<string>;
    function SupportsInstruction(const Mnemonic: string): Boolean;
  end;

implementation

{ TK16CompareEncoder }

function TK16CompareEncoder.GetSupportedMnemonics: TArray<string>;
begin
  Result := ['CMP'];
end;

function TK16CompareEncoder.SupportsInstruction(const Mnemonic: string): Boolean;
begin
  Result := SameText(Mnemonic, 'CMP');
end;

function TK16CompareEncoder.GetFullRegisterCode(RegType: TRegisterType; Number: Integer): Integer;
begin
  // Return 4-bit register code (0-15) for any register type
  case RegType of
    rtData:   Result := Number;           // D0-D3: 0-3
    rtIndexX: Result := 4 + Number;       // X0-X3: 4-7
    rtIndexY: Result := 8 + Number;       // Y0-Y3: 8-11
    rtORDB:   Result := 12;               // ORDB: 12
    rtSR:     Result := 13;               // SR: 13
    rtPCH:    Result := 14;               // PCH: 14
    rtPCL:    Result := 15;               // PCL: 15
    rtPC:     Result := 15;               // PC maps to PCL for backward compatibility
  else
    Result := 0; // Default
  end;
end;

function TK16CompareEncoder.ValidateCompareConstraints(const Instr: TInstructionRecord;
                                                      ErrorReporter: TErrorReporter): Boolean;
var
  DestCode: Integer;
begin
  Result := True;

  // CMP requires exactly 2 operands
  if Length(Instr.Operands) <> 2 then
  begin
    ErrorReporter('CMP requires exactly 2 operands: CMP reg, source', Instr.LineNumber);
    Result := False;
    Exit;
  end;

  // Validate destination register (must be D0-D3, X0-X3, or Y0-Y3)
  DestCode := GetFullRegisterCode(Instr.Destination.RegType, Instr.Destination.Number);
  if DestCode > 11 then
  begin
    ErrorReporter('CMP destination must be D0-D3, X0-X3, or Y0-Y3', Instr.LineNumber);
    Result := False;
    Exit;
  end;

  case Instr.Mode of
    amRegReg: // Mode 00: register to register
    begin
      // Full source register set allowed (0-15)
    end;

    amRegMem: // Mode 01: register to memory [XY]
    begin
      if not Instr.MemoryRef.IsValid then
      begin
        ErrorReporter('CMP Mode 01: Invalid memory reference', Instr.LineNumber);
        Result := False;
      end;
    end;

    amImm5: // Mode 10: register to 5-bit immediate
    begin
      // Immediate value 0-31, validated during encoding
    end;

    amImm16: // Mode 11: register to 16-bit immediate
    begin
      // No additional validation needed
    end;

    else
    begin
      ErrorReporter(Format('CMP does not support addressing mode %d', [Ord(Instr.Mode)]), Instr.LineNumber);
      Result := False;
    end;
  end;
end;

function TK16CompareEncoder.Encode(const Instr: TInstructionRecord;
                                  SymbolResolver: TSymbolResolver;
                                  ErrorReporter: TErrorReporter;
                                  WarningReporter: TWarningReporter): TMachineCode;
var
  OpCode: Word;
  ImmediateValue: Word;
  DestCode, SrcCode: Integer;
begin
  // Initialize result
  Result.Address := Instr.Address;
  Result.SourceLine := Instr.LineNumber;
  Result.HasImmediate := False;
  Result.Immediate := 0;

  // Validate constraints
  if not ValidateCompareConstraints(Instr, ErrorReporter) then
  begin
    Result.OpCode := 0;
    Exit;
  end;

  // CMP opcode is 0x10
  OpCode := $10 shl 11; // Bits 15-11

  // Get destination register code
  DestCode := GetFullRegisterCode(Instr.Destination.RegType, Instr.Destination.Number);

  // Get immediate value if present
  ImmediateValue := ResolveImmediate(Instr.Immediate, SymbolResolver, Instr.LineNumber);

  case Instr.Mode of
    amRegReg: // Mode 00: CMP reg, reg
    begin
      OpCode := OpCode or (0 shl 9);  // Mode 00

      // DEST field (bits 8-5)
      OpCode := OpCode or (DestCode shl 5);

      // SRC field (bits 4-1)
      SrcCode := GetFullRegisterCode(Instr.SourceA.RegType, Instr.SourceA.Number);
      OpCode := OpCode or (SrcCode shl 1);
    end;

    amRegMem: // Mode 01: CMP reg, [XY]
    begin
      OpCode := OpCode or (1 shl 9);  // Mode 01

      // DEST field (bits 8-5)
      OpCode := OpCode or (DestCode shl 5);

      // XY pair selector (bits 2-1)
      if Instr.MemoryRef.BaseReg = 'XY0' then OpCode := OpCode or (0 shl 1)
      else if Instr.MemoryRef.BaseReg = 'XY1' then OpCode := OpCode or (1 shl 1)
      else if Instr.MemoryRef.BaseReg = 'XY2' then OpCode := OpCode or (2 shl 1)
      else if Instr.MemoryRef.BaseReg = 'XY3' then OpCode := OpCode or (3 shl 1)
      else OpCode := OpCode or (0 shl 1); // Default XY0
    end;

    amImm5: // Mode 10: CMP reg, #imm5
    begin
      // Validate immediate fits in 5 bits
      if ImmediateValue > 31 then
      begin
        // Promote to Mode 11 if value too large
        WarningReporter('CMP immediate value > 31, using Mode 11 (16-bit)', Instr.LineNumber);
        OpCode := OpCode or (3 shl 9);  // Mode 11
        OpCode := OpCode or (DestCode shl 5);
        Result.HasImmediate := True;
        Result.Immediate := ImmediateValue;
      end
      else
      begin
        OpCode := OpCode or (2 shl 9);  // Mode 10

        // DEST field (bits 8-5)
        OpCode := OpCode or (DestCode shl 5);

        // IMM5 field (bits 4-0)
        OpCode := OpCode or (ImmediateValue and $1F);
      end;
    end;

    amImm16: // Mode 11: CMP reg, #imm16
    begin
      OpCode := OpCode or (3 shl 9);  // Mode 11

      // DEST field (bits 8-5)
      OpCode := OpCode or (DestCode shl 5);

      // 16-bit immediate in next word
      Result.HasImmediate := True;
      Result.Immediate := ImmediateValue;
    end;
  end;

  Result.OpCode := OpCode;
end;

end.
