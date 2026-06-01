unit K16_Encoder_Interrupt;

{$mode Delphi}

interface

uses
  SysUtils, StrUtils,
  K16_Parser, K16_Encoder_Base;

type
  TK16InterruptEncoder = class(TK16EncoderBase, IK16Encoder)
  public
    function Encode(const Instr: TInstructionRecord;
                   SymbolResolver: TSymbolResolver;
                   ErrorReporter: TErrorReporter;
                   WarningReporter: TWarningReporter): TMachineCode;
    function GetSupportedMnemonics: TArray<string>;
    function SupportsInstruction(const Mnemonic: string): Boolean;
  end;

implementation

{ TK16InterruptEncoder }

function TK16InterruptEncoder.GetSupportedMnemonics: TArray<string>;
begin
  Result := ['DINT', 'EINT', 'RTI', 'INT'];
end;

function TK16InterruptEncoder.SupportsInstruction(const Mnemonic: string): Boolean;
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

function TK16InterruptEncoder.Encode(const Instr: TInstructionRecord;
                                    SymbolResolver: TSymbolResolver;
                                    ErrorReporter: TErrorReporter;
                                    WarningReporter: TWarningReporter): TMachineCode;
var
  OpCode: Word;
  OpcodeValue: Byte;
  ModeValue: Byte;
begin
  // Initialize result
  Result.Address := Instr.Address;
  Result.SourceLine := Instr.LineNumber;
  Result.HasImmediate := False;
  Result.Immediate := 0;

  // Handle DINT instruction - Disable Interrupts (Opcode $1F, Mode 00)
  if SameText(Instr.Mnemonic, 'DINT') then
  begin
    if Length(Instr.Operands) > 0 then
      ErrorReporter('DINT takes no operands', Instr.LineNumber);

    // Opcode $1F = %11111, Mode $00
    // Encoding: %11111 00 0 00000000 = $F800
    OpcodeValue := $1F;
    ModeValue := $00;
    OpCode := (OpcodeValue shl 11) or (ModeValue shl 9);
    Result.OpCode := OpCode;
  end

  // Handle EINT instruction - Enable Interrupts (Opcode $1F, Mode 01)
  else if SameText(Instr.Mnemonic, 'EINT') then
  begin
    if Length(Instr.Operands) > 0 then
      ErrorReporter('EINT takes no operands', Instr.LineNumber);

    // Opcode $1F = %11111, Mode $01
    // Encoding: %11111 01 0 00000000 = $FA00
    OpcodeValue := $1F;
    ModeValue := $01;
    OpCode := (OpcodeValue shl 11) or (ModeValue shl 9);
    Result.OpCode := OpCode;
  end

  // Handle RTI instruction - Return from Interrupt (Opcode $1F, Mode 10)
  else if SameText(Instr.Mnemonic, 'RTI') then
  begin
    if Length(Instr.Operands) > 0 then
      ErrorReporter('RTI takes no operands', Instr.LineNumber);

    // Opcode $1F = %11111, Mode $10
    // Encoding: %11111 10 0 00000000 = $FC00
    OpcodeValue := $1F;
    ModeValue := $02;
    OpCode := (OpcodeValue shl 11) or (ModeValue shl 9);
    Result.OpCode := OpCode;
  end

  // Handle INT instruction - Software Interrupt (Opcode $1F, Mode 11)
  // Note: Hardware interrupt forces $FFFF on bus, but INT can be used for software interrupt
  else if SameText(Instr.Mnemonic, 'INT') then
  begin
    if Length(Instr.Operands) > 0 then
      ErrorReporter('INT takes no operands', Instr.LineNumber);

    // Opcode $1F = %11111, Mode $11
    // Encoding: %11111 11 1 11111111 = $FFFF (all ones)
    // Hardware forces this via pull-ups, software can also use it
    Result.OpCode := $FFFF;
  end

  else
  begin
    ErrorReporter(Format('Unsupported interrupt instruction: %s', [Instr.Mnemonic]), Instr.LineNumber);
    Result.OpCode := 0;
  end;
end;

end.
