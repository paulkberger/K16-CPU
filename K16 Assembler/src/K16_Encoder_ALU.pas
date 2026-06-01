unit K16_Encoder_ALU;

{$mode Delphi}

interface

uses
  SysUtils, StrUtils,
  K16_Parser, K16_Encoder_Base;

type
  TK16ALUEncoder = class(TK16EncoderBase, IK16Encoder)
  private
    function ValidateALURegisterConstraints(const Instr: TInstructionRecord;
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

{ TK16ALUEncoder }

function TK16ALUEncoder.GetSupportedMnemonics: TArray<string>;
begin
  Result := ['ADD', 'ADC', 'SUB', 'SBC', 'AND', 'OR', 'XOR', 'NOT'];
end;

function TK16ALUEncoder.SupportsInstruction(const Mnemonic: string): Boolean;
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

function TK16ALUEncoder.ValidateALURegisterConstraints(const Instr: TInstructionRecord;
                                                      ErrorReporter: TErrorReporter): Boolean;
begin
  Result := True;

  // Destination must be D0-D3, X0-X3, or Y0-Y3 (values 0-11)
  // NOT allowed: ORDB, SR, PCH, PCL, PC as destination
  if not (Instr.Destination.RegType in [rtData, rtIndexX, rtIndexY]) then
  begin
    case Instr.Destination.RegType of
      rtSR:   ErrorReporter(Format('%s: SR cannot be ALU destination', [Instr.Mnemonic]), Instr.LineNumber);
      rtPC:   ErrorReporter(Format('%s: PC cannot be ALU destination', [Instr.Mnemonic]), Instr.LineNumber);
      rtORDB: ErrorReporter(Format('%s: ORDB cannot be ALU destination', [Instr.Mnemonic]), Instr.LineNumber);
      rtPCH:  ErrorReporter(Format('%s: PCH cannot be ALU destination', [Instr.Mnemonic]), Instr.LineNumber);
      rtPCL:  ErrorReporter(Format('%s: PCL cannot be ALU destination', [Instr.Mnemonic]), Instr.LineNumber);
    else
      ErrorReporter(Format('%s: Invalid destination - must be D0-D3, X0-X3, or Y0-Y3', [Instr.Mnemonic]), Instr.LineNumber);
    end;
    Result := False;
  end;

  case Instr.Mode of
    amRegReg:
    begin
      // Source must be a valid register
      if not Instr.SourceA.IsValid then
      begin
        ErrorReporter(Format('%s Mode 00: requires source register', [Instr.Mnemonic]), Instr.LineNumber);
        Result := False;
      end;
    end;

    amRegMem:
    begin
      // Memory reference must be valid XY pair
      if not Instr.MemoryRef.IsValid then
      begin
        ErrorReporter(Format('%s Mode 01: requires [XY] memory source', [Instr.Mnemonic]), Instr.LineNumber);
        Result := False;
      end;
    end;

    amImm5:
    begin
      // No additional validation - dest = dest + IMM5
    end;

    amImm16:
    begin
      // No additional validation - dest = dest + IMM16
    end;
  end;
end;

function TK16ALUEncoder.Encode(const Instr: TInstructionRecord;
                              SymbolResolver: TSymbolResolver;
                              ErrorReporter: TErrorReporter;
                              WarningReporter: TWarningReporter): TMachineCode;
var
  OpCode: Word;
  OpcodeValue: Byte;
  DestEncoded: Byte;
  SourceEncoded: Byte;
  ImmediateValue: UInt32;
begin
  // Initialize result
  Result.Address := Instr.Address;
  Result.SourceLine := Instr.LineNumber;
  Result.HasImmediate := False;
  Result.Immediate := 0;
  Result.IsDataWord := False;

  // Validate register constraints first
  if not ValidateALURegisterConstraints(Instr, ErrorReporter) then
  begin
    Result.OpCode := 0;
    Exit;
  end;

  // Get ALU opcode value
  if      SameText(Instr.Mnemonic, 'ADD') then OpcodeValue := $08
  else if SameText(Instr.Mnemonic, 'ADC') then OpcodeValue := $09
  else if SameText(Instr.Mnemonic, 'SUB') then OpcodeValue := $0A
  else if SameText(Instr.Mnemonic, 'SBC') then OpcodeValue := $0B
  else if SameText(Instr.Mnemonic, 'AND') then OpcodeValue := $0C
  else if SameText(Instr.Mnemonic, 'OR')  then OpcodeValue := $0D
  else if SameText(Instr.Mnemonic, 'XOR') then OpcodeValue := $0E
  else if SameText(Instr.Mnemonic, 'NOT') then OpcodeValue := $0F
  else OpcodeValue := $08; // Default to ADD

  // Encode destination register (4 bits, values 0-11)
  DestEncoded := EncodeDestinationRegister(Instr.Destination);

  // Get immediate value if present
  ImmediateValue := ResolveImmediate(Instr.Immediate, SymbolResolver, Instr.LineNumber);

  // Build opcode word
  // Bits 15-11: Opcode
  // Bits 10-9:  Mode
  // Bits 8-5:   Dest (maps to microcode bits 7-4)
  // Bits 4-1:   Source (maps to microcode bits 3-0)
  // Bit 0:      unused (except Mode 10 where bits 4-0 = IMM5)

  OpCode := Word(OpcodeValue) shl 11;  // Bits 15-11

  case Instr.Mode of
    amRegReg: // Mode 00: Dest = Dest + Source
    begin
      OpCode := OpCode or (0 shl 9);                    // Mode 00
      OpCode := OpCode or (Word(DestEncoded) shl 5);    // Bits 8-5
      SourceEncoded := Instr.SourceA.Encode;           // Use TRegister.Encode
      OpCode := OpCode or (Word(SourceEncoded) shl 1); // Bits 4-1
    end;

    amRegMem: // Mode 01: Dest = Dest + [XY]
    begin
      OpCode := OpCode or (1 shl 9);                    // Mode 01
      OpCode := OpCode or (Word(DestEncoded) shl 5);    // Bits 8-5
      SourceEncoded := GetXYRegisterNumber(Instr.MemoryRef);  // 0-3
      OpCode := OpCode or (Word(SourceEncoded) shl 1); // Bits 4-1
    end;

    amImm5: // Mode 10: Dest = Dest + IMM5
    begin
      OpCode := OpCode or (2 shl 9);                   // Mode 10
      OpCode := OpCode or (Word(DestEncoded) shl 5);   // Bits 8-5

      if ImmediateValue > 31 then
      begin
        ErrorReporter('Mode 10 immediate must be 0-31', Instr.LineNumber);
        ImmediateValue := ImmediateValue and $1F;
      end;

      OpCode := OpCode or (ImmediateValue and $1F);   // Bits 4-0 (not shifted)
    end;

    amImm16: // Mode 11: Dest = Dest + #IMM16
    begin
      OpCode := OpCode or (3 shl 9);                   // Mode 11
      OpCode := OpCode or (Word(DestEncoded) shl 5);   // Bits 8-5
      // Bits 4-0 unused
      Result.HasImmediate := True;
      Result.Immediate := Word(ImmediateValue);
    end;
  else
    ErrorReporter(Format('%s: unsupported addressing mode', [Instr.Mnemonic]), Instr.LineNumber);
    Result.OpCode := 0;
    Exit;
  end;

  Result.OpCode := OpCode;
end;

end.
