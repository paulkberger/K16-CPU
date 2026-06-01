unit K16_Encoder_Control;

{$mode Delphi}

interface

uses
  SysUtils, StrUtils,
  K16_Parser, K16_Encoder_Base;

type
  TK16ControlEncoder = class(TK16EncoderBase, IK16Encoder)
  public
    function Encode(const Instr: TInstructionRecord;
                   SymbolResolver: TSymbolResolver;
                   ErrorReporter: TErrorReporter;
                   WarningReporter: TWarningReporter): TMachineCode;
    function GetSupportedMnemonics: TArray<string>;
    function SupportsInstruction(const Mnemonic: string): Boolean;
  end;

implementation

{ TK16ControlEncoder }

function TK16ControlEncoder.GetSupportedMnemonics: TArray<string>;
begin
  Result := ['NOP', 'HALT', 'NEG'];
end;

function TK16ControlEncoder.SupportsInstruction(const Mnemonic: string): Boolean;
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

function TK16ControlEncoder.Encode(const Instr: TInstructionRecord;
                                  SymbolResolver: TSymbolResolver;
                                  ErrorReporter: TErrorReporter;
                   WarningReporter: TWarningReporter): TMachineCode;
var
  OpCode: Word;
  OpcodeValue: Byte;
  ModeValue: Byte;
  T8Value: Byte;
  ImmediateValue: Word;
  DestEncoded: Byte;
  SrcEncoded: Byte;
begin
  // Initialize result
  Result.Address := Instr.Address;
  Result.SourceLine := Instr.LineNumber;
  Result.HasImmediate := False;
  Result.Immediate := 0;

  // Handle NOP instruction (Opcode 0x00, Mode 00)
  if SameText(Instr.Mnemonic, 'NOP') then
  begin
    OpcodeValue := $00;  // NOP opcode
    ModeValue := $00;    // NOP mode

    // Check for T8 parameter
    if Length(Instr.Operands) = 0 then
    begin
      // Simple NOP - T8 = 0
      T8Value := 0;
    end
    else if (Length(Instr.Operands) = 1) and (Instr.Mode = amImm8) then
    begin
      // NOP with T8 value: NOP #$FF, NOP #DebugMarker
      if Instr.Immediate.IsSymbol then
        ImmediateValue := SymbolResolver(Instr.Immediate.SymbolName, Instr.LineNumber)
      else
        ImmediateValue := Instr.Immediate.Value;

      // Validate 8-bit range for T8
      if ImmediateValue > 255 then
      begin
        ErrorReporter(Format('NOP T8 value %d out of range (0-255)', [ImmediateValue]), Instr.LineNumber);
        T8Value := ImmediateValue and $FF; // Truncate to 8 bits
      end
      else
        T8Value := ImmediateValue and $FF;
    end
    else
    begin
      ErrorReporter('Invalid NOP operand format', Instr.LineNumber);
      T8Value := 0;
    end;

    // Build opcode: Bits 15-11: Opcode, Bits 10-9: Mode, Bits 7-0: T8
    OpCode := (OpcodeValue shl 11) or (ModeValue shl 9) or T8Value;
    Result.OpCode := OpCode;
  end

  // Handle HALT instruction (Opcode 0x00, Mode 01)
  else if SameText(Instr.Mnemonic, 'HALT') then
  begin
    OpcodeValue := $00;  // HALT opcode (same as NOP)
    ModeValue := $01;    // HALT mode (different from NOP)

    // Check for T8 parameter (exit code, error status, etc.)
    if Length(Instr.Operands) = 0 then
    begin
      // Simple HALT - T8 = 0 (normal exit)
      T8Value := 0;
    end
    else if (Length(Instr.Operands) = 1) and (Instr.Mode = amImm8) then
    begin
      // HALT with T8 value: HALT #0, HALT #$FF
      if Instr.Immediate.IsSymbol then
        ImmediateValue := SymbolResolver(Instr.Immediate.SymbolName, Instr.LineNumber)
      else
        ImmediateValue := Instr.Immediate.Value;

      // Validate 8-bit range for T8
      if ImmediateValue > 255 then
      begin
        ErrorReporter(Format('HALT T8 value %d out of range (0-255)', [ImmediateValue]), Instr.LineNumber);
        T8Value := ImmediateValue and $FF; // Truncate to 8 bits
      end
      else
        T8Value := ImmediateValue and $FF;
    end
    else
    begin
      ErrorReporter('Invalid HALT operand format', Instr.LineNumber);
      T8Value := 0;
    end;

    // Build opcode: Bits 15-11: Opcode, Bits 10-9: Mode, Bits 7-0: T8
    OpCode := (OpcodeValue shl 11) or (ModeValue shl 9) or T8Value;
    Result.OpCode := OpCode;
  end

  // Handle NEG instruction (Opcode $00, Mode 11)
  // NEG dst, src  — dst <- -src
  // NEG dst       — sugar for NEG dst, dst
  else if SameText(Instr.Mnemonic, 'NEG') then
  begin
    // Validate destination
    if not (Instr.Destination.RegType in [rtData, rtIndexX, rtIndexY]) then
    begin
      ErrorReporter('NEG: invalid destination register', Instr.LineNumber);
      Result.OpCode := 0;
      Exit;
    end;

    DestEncoded := EncodeDestinationRegister(Instr.Destination);

    case Instr.Mode of
      amRegReg:
        begin
          // Two-operand: NEG dst, src — SourceA is valid
          // In-place:    NEG dst     — SourceA not set, src = dst
          if Instr.SourceA.IsValid then
            SrcEncoded := Instr.SourceA.Encode
          else
            SrcEncoded := DestEncoded;
        end;

    else
      ErrorReporter('NEG: invalid operand format — use NEG dst or NEG dst, src', Instr.LineNumber);
      Result.OpCode := 0;
      Exit;
    end;

    // Opcode $00, Mode 11, IR[8:5]=dst, IR[4:1]=src, IR[0]=0
    OpCode := ($00 shl 11) or (3 shl 9)
           or (Word(DestEncoded) shl 5)
           or (Word(SrcEncoded)  shl 1);
    Result.OpCode := OpCode;
  end

  else
  begin
    ErrorReporter(Format('Unsupported control instruction: %s', [Instr.Mnemonic]), Instr.LineNumber);
    Result.OpCode := 0;
  end;
end;

end.
