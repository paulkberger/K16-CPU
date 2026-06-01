unit K16_Encoder_ConditionalSet;

{$mode Delphi}

{
  K16 Scc (Conditional Set) Instruction Encoder
  ==============================================

  Encodes Scc instructions for the K16 CPU.
  Sets destination register to $FFFF if condition TRUE, else to IMM16.

  Scc Instruction Format:
    Scc dest            ; dest = $FFFF if condition, else $0000 (default)
    Scc dest, #imm16    ; dest = $FFFF if condition, else imm16

  Condition Codes (same as Branch):
    SEQ - Equal (Z=1)
    SNE - Not Equal (Z=0)
    SCS - Carry Set (C=1) / SHS - Unsigned Higher or Same
    SCC - Carry Clear (C=0) / SLO - Unsigned Lower
    SLT - Signed Less Than (N!=V)
    SGT - Signed Greater Than (Z=0 AND N=V)
    SGE - Signed Greater or Equal (N=V)
    SLE - Signed Less or Equal (Z=1 OR N!=V)

  Register Encoding (4-bit, bits 4-1):
    0x0: D0    0x4: X0    0x8: Y0
    0x1: D1    0x5: X1    0x9: Y1
    0x2: D2    0x6: X2    0xA: Y2
    0x3: D3    0x7: X3    0xB: Y3

  Instruction Encoding:
    Word 1: [OPCODE:5][00][1][CC:3][DST:4][0]
            Bits 15-11: Opcode $04
            Bits 10-9:  Reserved (00)
            Bit 8:      Must be 1 (distinguishes from Branch)
            Bits 7-5:   Condition code (0-7)
            Bits 4-1:   Destination register (0-11)
            Bit 0:      Reserved (0)

    Word 2: IMM16 (false value, typically $0000)

  NOTE: Destination registers limited to D0-D3, X0-X3, Y0-Y3 (codes 0-11)
}

interface

uses
  SysUtils, StrUtils,
  K16_Parser, K16_Encoder_Base;

type
  TK16SccEncoder = class(TK16EncoderBase, IK16Encoder)
  private
    function GetFullRegisterCode(RegType: TRegisterType; Number: Integer): Integer;
    function GetConditionCode(const Mnemonic: string): Integer;
    function ValidateSccConstraints(const Instr: TInstructionRecord;
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

{ TK16SccEncoder }

function TK16SccEncoder.GetSupportedMnemonics: TArray<string>;
begin
  Result := ['SEQ', 'SNE', 'SCS', 'SCC', 'SHS', 'SLO', 'SLT', 'SGT', 'SGE', 'SLE'];
end;

function TK16SccEncoder.SupportsInstruction(const Mnemonic: string): Boolean;
var
  M: string;
begin
  Result := False;
  for M in GetSupportedMnemonics do
    if SameText(Mnemonic, M) then
      Exit(True);
end;

function TK16SccEncoder.GetFullRegisterCode(RegType: TRegisterType; Number: Integer): Integer;
begin
  // Return 4-bit register code (0-11) for valid Scc destinations
  case RegType of
    rtData:   Result := Number;           // D0-D3: 0-3
    rtIndexX: Result := 4 + Number;       // X0-X3: 4-7
    rtIndexY: Result := 8 + Number;       // Y0-Y3: 8-11
  else
    Result := 255; // Invalid
  end;
end;

function TK16SccEncoder.GetConditionCode(const Mnemonic: string): Integer;
begin
  // Return 3-bit condition code (0-7)
  if SameText(Mnemonic, 'SEQ') then Result := 0      // Equal (Z=1)
  else if SameText(Mnemonic, 'SNE') then Result := 1 // Not Equal (Z=0)
  else if SameText(Mnemonic, 'SCS') then Result := 2 // Carry Set (C=1)
  else if SameText(Mnemonic, 'SHS') then Result := 2 // Unsigned Higher or Same (alias for SCS)
  else if SameText(Mnemonic, 'SCC') then Result := 3 // Carry Clear (C=0)
  else if SameText(Mnemonic, 'SLO') then Result := 3 // Unsigned Lower (alias for SCC)
  else if SameText(Mnemonic, 'SLT') then Result := 4 // Signed Less Than
  else if SameText(Mnemonic, 'SGT') then Result := 5 // Signed Greater Than
  else if SameText(Mnemonic, 'SGE') then Result := 6 // Signed Greater or Equal
  else if SameText(Mnemonic, 'SLE') then Result := 7 // Signed Less or Equal
  else Result := 0; // Default to EQ
end;

function TK16SccEncoder.ValidateSccConstraints(const Instr: TInstructionRecord;
                                               ErrorReporter: TErrorReporter): Boolean;
var
  DestCode: Integer;
begin
  Result := True;

  // Scc requires 1 or 2 operands: Scc dest or Scc dest, #imm16
  if (Length(Instr.Operands) < 1) or (Length(Instr.Operands) > 2) then
  begin
    ErrorReporter('Scc requires 1 or 2 operands: Scc dest [, #imm16]', Instr.LineNumber);
    Result := False;
    Exit;
  end;

  // Validate destination register (must be D0-D3, X0-X3, or Y0-Y3)
  DestCode := GetFullRegisterCode(Instr.Destination.RegType, Instr.Destination.Number);
  if DestCode > 11 then
  begin
    ErrorReporter('Scc destination must be D0-D3, X0-X3, or Y0-Y3', Instr.LineNumber);
    Result := False;
    Exit;
  end;
end;

function TK16SccEncoder.Encode(const Instr: TInstructionRecord;
                               SymbolResolver: TSymbolResolver;
                               ErrorReporter: TErrorReporter;
                               WarningReporter: TWarningReporter): TMachineCode;
var
  OpCode: Word;
  ImmediateValue: Word;
  DestCode, CondCode: Integer;
begin
  // Initialize result
  Result.Address := Instr.Address;
  Result.SourceLine := Instr.LineNumber;
  Result.HasImmediate := True;  // Scc always has IMM16 (word 2)
  Result.Immediate := 0;        // Default false value is $0000

  // Validate constraints
  if not ValidateSccConstraints(Instr, ErrorReporter) then
  begin
    Result.OpCode := 0;
    Result.HasImmediate := False;
    Exit;
  end;

  // Scc opcode is $04
  OpCode := $04 shl 11;         // Bits 15-11: Opcode

  // Mode bits 10-9 = 00 (reserved)
  // Bit 8 = 1 (Scc flag, distinguishes from Branch)
  OpCode := OpCode or (1 shl 8);

  // Get condition code from mnemonic (bits 7-5)
  CondCode := GetConditionCode(Instr.Mnemonic);
  OpCode := OpCode or (CondCode shl 5);

  // Get destination register code (bits 4-1)
  DestCode := GetFullRegisterCode(Instr.Destination.RegType, Instr.Destination.Number);
  OpCode := OpCode or (DestCode shl 1);

  // Bit 0 = 0 (reserved)

  // Get immediate value if provided, else default to $0000
  if Length(Instr.Operands) = 2 then
    ImmediateValue := ResolveImmediate(Instr.Immediate, SymbolResolver, Instr.LineNumber)
  else
    ImmediateValue := $0000;

  Result.OpCode := OpCode;
  Result.Immediate := ImmediateValue;
end;

end.
