unit K16_Encoder_Branch;

{$mode Delphi}

interface

uses
  SysUtils, StrUtils,
  K16_Parser, K16_Encoder_Base;

type
  TBranchCondition = (
    bcEQ = 0,  // Equals Zero (Z = 1)
    bcNE = 1,  // Not Equal (Z = 0)
    bcCS = 2,  // Carry Set / Higher or Same unsigned (C = 1)
    bcCC = 3,  // Carry Clear / Lower unsigned (C = 0)
    bcLT = 4,  // Less Than signed (N XOR V)
    bcGT = 5,  // Greater Than signed (NOT Z) AND (N XNOR V)
    bcGE = 6,  // Greater than or Equal signed (N XNOR V)
    bcLE = 7   // Less than or Equal signed: Z OR (N XOR V)
  );

  TK16BranchEncoder = class(TK16EncoderBase, IK16Encoder)
  private
    function GetBranchCondition(const Mnemonic: string): TBranchCondition;
    function GetBranchOpcode: Byte;
    function ValidateShortByteOffset(ByteOffset: Integer; LineNumber: Integer; ErrorReporter: TErrorReporter): Boolean;
    function ValidateLongByteOffset(ByteOffset: Integer; LineNumber: Integer; ErrorReporter: TErrorReporter): Boolean;
    function CalculateByteOffset(TargetAddr, InstrAddr, InstrSize: Integer): Integer;
    function IsLongBranchMnemonic(const Mnemonic: string): Boolean;
    function IsShortBranchMnemonic(const Mnemonic: string): Boolean;
    function IsUnconditionalBranch(const Mnemonic: string): Boolean;
    function GetBaseMnemonic(const Mnemonic: string): string;
  public
    function Encode(const Instr: TInstructionRecord;
                   SymbolResolver: TSymbolResolver;
                   ErrorReporter: TErrorReporter;
                   WarningReporter: TWarningReporter): TMachineCode;
    function GetSupportedMnemonics: TArray<string>;
    function SupportsInstruction(const Mnemonic: string): Boolean;
  end;

implementation

{ TK16BranchEncoder }

function TK16BranchEncoder.GetSupportedMnemonics: TArray<string>;
begin
  // Support both auto-select and explicit modes
  // BHS = Branch if Higher or Same (alias for BCS, unsigned >=)
  // BLO = Branch if Lower (alias for BCC, unsigned <)
  // BRA/BRANCH = unconditional branch (Mode 10/11 with condition 000)
  Result := [
    // Auto-select modes (choose based on distance)
    'BEQ', 'BNE', 'BCS', 'BCC', 'BLT', 'BGT', 'BGE', 'BLE',
    // Aliases for unsigned comparisons
    'BHS', 'BLO',
    // Unconditional branch (auto-select)
    'BRA', 'BRANCH',
    // Explicit short modes (force Mode 00/10: unsigned 0-31 byte offset)
    'BEQ.S', 'BNE.S', 'BCS.S', 'BCC.S', 'BLT.S', 'BGT.S', 'BGE.S', 'BLE.S',
    'BHS.S', 'BLO.S', 'BRA.S',
    // Explicit long modes (force Mode 01/11: signed byte offset via T16W)
    'BEQ.L', 'BNE.L', 'BCS.L', 'BCC.L', 'BLT.L', 'BGT.L', 'BGE.L', 'BLE.L',
    'BHS.L', 'BLO.L', 'BRA.L', 'BRANCH.L'
  ];
end;

function TK16BranchEncoder.SupportsInstruction(const Mnemonic: string): Boolean;
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

function TK16BranchEncoder.GetBaseMnemonic(const Mnemonic: string): string;
begin
  // Strip .S or .L suffix to get base mnemonic
  Result := Mnemonic;
  if Result.EndsWith('.S') or Result.EndsWith('.L') then
    Result := Copy(Result, 1, Length(Result) - 2);
end;

function TK16BranchEncoder.IsShortBranchMnemonic(const Mnemonic: string): Boolean;
begin
  Result := Mnemonic.EndsWith('.S');
end;

function TK16BranchEncoder.IsLongBranchMnemonic(const Mnemonic: string): Boolean;
begin
  Result := Mnemonic.EndsWith('.L');
end;

function TK16BranchEncoder.IsUnconditionalBranch(const Mnemonic: string): Boolean;
var
  BaseMnemonic: string;
begin
  BaseMnemonic := GetBaseMnemonic(Mnemonic);
  Result := SameText(BaseMnemonic, 'BRA') or SameText(BaseMnemonic, 'BRANCH');
end;

function TK16BranchEncoder.GetBranchCondition(const Mnemonic: string): TBranchCondition;
var
  BaseMnemonic: string;
begin
  BaseMnemonic := GetBaseMnemonic(Mnemonic);

  if SameText(BaseMnemonic, 'BEQ') then Result := bcEQ
  else if SameText(BaseMnemonic, 'BNE') then Result := bcNE
  else if SameText(BaseMnemonic, 'BCS') then Result := bcCS
  else if SameText(BaseMnemonic, 'BHS') then Result := bcCS  // Alias: Higher or Same = Carry Set
  else if SameText(BaseMnemonic, 'BCC') then Result := bcCC
  else if SameText(BaseMnemonic, 'BLO') then Result := bcCC  // Alias: Lower = Carry Clear
  else if SameText(BaseMnemonic, 'BLT') then Result := bcLT  // Less Than (signed)
  else if SameText(BaseMnemonic, 'BGT') then Result := bcGT  // Greater Than (signed)
  else if SameText(BaseMnemonic, 'BGE') then Result := bcGE  // Greater or Equal (signed)
  else if SameText(BaseMnemonic, 'BLE') then Result := bcLE  // Less than or Equal (signed)
  else Result := bcEQ; // Default
end;

function TK16BranchEncoder.GetBranchOpcode: Byte;
begin
  // All branch instructions use the same BRANCH opcode 0x11
  Result := $11;  // BRANCH opcode from K16 CPU ISA
end;

function TK16BranchEncoder.ValidateShortByteOffset(ByteOffset: Integer; LineNumber: Integer; ErrorReporter: TErrorReporter): Boolean;
begin
  // Mode 00: T8-5 register - unsigned 0 to 31 bytes (forward only)
  Result := (ByteOffset >= 0) and (ByteOffset <= 31);
  if not Result then
    ErrorReporter(Format('Short branch byte offset %d out of range (0 to +31 bytes, forward only)', [ByteOffset]), LineNumber);
end;

function TK16BranchEncoder.ValidateLongByteOffset(ByteOffset: Integer; LineNumber: Integer; ErrorReporter: TErrorReporter): Boolean;
begin
  // Mode 01: T16W register - signed -32768 to +32767 bytes
  Result := (ByteOffset >= -32768) and (ByteOffset <= 32767);
  if not Result then
    ErrorReporter(Format('Long branch byte offset %d out of range (-32768 to +32767 bytes)', [ByteOffset]), LineNumber);
end;

function TK16BranchEncoder.CalculateByteOffset(TargetAddr, InstrAddr, InstrSize: Integer): Integer;
begin
  // Calculate byte offset from next instruction to target
  // All calculations in bytes, no word scaling
  Result := TargetAddr - (InstrAddr + InstrSize);
end;

function TK16BranchEncoder.Encode(const Instr: TInstructionRecord;
                                 SymbolResolver: TSymbolResolver;
                                 ErrorReporter: TErrorReporter;
                   WarningReporter: TWarningReporter): TMachineCode;
var
  OpCode: Word;
  Condition: TBranchCondition;
  ByteOffset: Integer;
  TargetAddress: UInt32;
  OpcodeValue: Byte;
  ImmediateValue: Integer;
  IsLongMode: Boolean;
  InstrSize: Integer;
  TempOffset: Integer;
  BaseMnemonic: string;
  TempImm: TImmediateValue;
begin
  // Initialize result
  Result.Address := Instr.Address;
  Result.SourceLine := Instr.LineNumber;
  Result.HasImmediate := False;
  Result.Immediate := 0;

  // Initialize variables
  TargetAddress := 0;
  ByteOffset := 0;
  IsLongMode := False;
  InstrSize := 2; // Default

  BaseMnemonic := GetBaseMnemonic(Instr.Mnemonic);

  // Get condition from mnemonic
  Condition := GetBranchCondition(Instr.Mnemonic);

  // Validate operands
  if Length(Instr.Operands) < 1 then
  begin
    ErrorReporter(Format('%s requires target operand', [Instr.Mnemonic]), Instr.LineNumber);
    Result.OpCode := 0;
    Exit;
  end;

  // Parse target operand
  if (Length(Instr.Operands[0]) > 0) and (Instr.Operands[0][1] = '#') then
  begin
    // Immediate relative byte offset
    TempImm := TImmediateValue.Parse(Instr.Operands[0]);
    if TempImm.IsSymbol then
      // Prepend '#' so resolver routes symbolic expressions (e.g.
      // '#SYMBOL+4', '#-OFFS') through the expression evaluator.
      ImmediateValue := Integer(SymbolResolver('#' + TempImm.SymbolName, Instr.LineNumber))
    else
    begin
      ImmediateValue := Integer(TempImm.Value);
      if TempImm.IsSigned then
        ImmediateValue := -ImmediateValue;
    end;

    ByteOffset := ImmediateValue;
  end
  else
  begin
    // Label target - resolve symbol.
    // Prepend '#' for expression support (e.g. 'BNE label+4').
    TargetAddress := Integer(SymbolResolver('#' + Instr.Operands[0], Instr.LineNumber));
  end;

  // FORCE mode selection based on explicit suffix - THIS IS KEY
  if IsShortBranchMnemonic(Instr.Mnemonic) then
  begin
    InstrSize := 2;
    IsLongMode := False;
  end
  else if IsLongBranchMnemonic(Instr.Mnemonic) then
  begin
    InstrSize := 4;  // ALWAYS 4 bytes for .L suffix
    IsLongMode := True;
  end
  else if (Length(Instr.Operands[0]) > 0) and (Instr.Operands[0][1] = '#') then
  begin
    // Auto-select for immediate offsets only
    IsLongMode := (ByteOffset < 0) or (ByteOffset > 31);

    if IsLongMode then
      InstrSize := 4
    else
      InstrSize := 2;

  end
  else
  begin
    // Auto-select for label targets without explicit suffix.
    // ALWAYS use long mode. This guarantees pass-1 sizing matches pass-2:
    // pass 1 sees a placeholder address (1000) from the dummy resolver and
    // would pick long; pass 2 with the real address might pick short for
    // nearby labels, causing a size mismatch and code-layout corruption.
    // User can force short with explicit .S suffix when offset is known to
    // fit in 5 bits.
    IsLongMode := True;
    InstrSize := 4;
  end;

  // Calculate offset if not immediate
  if not ((Length(Instr.Operands[0]) > 0) and (Instr.Operands[0][1] = '#')) then
    ByteOffset := CalculateByteOffset(TargetAddress, Instr.Address, InstrSize);

  // Set HasImmediate up-front for long mode so pass-1 sizing is correct
  // (4 bytes / 2 words) even if validation below fails on a placeholder
  // address from DummySizeSymbolResolver. Pass-2 will see real values and
  // either validate successfully or report a real error.
  if IsLongMode then
    Result.HasImmediate := True;

  // Validate offsets — always check.  Out-of-range branches must error
  // rather than silently truncate to a wrong target.  Pass-1 sizing uses
  // DummySize* reporters which silence spurious errors from unresolved
  // symbols, so it's safe to validate unconditionally here.
  if IsLongMode then
  begin
    if not ValidateLongByteOffset(ByteOffset, Instr.LineNumber, ErrorReporter) then
    begin
      Result.OpCode := 0;
      Exit;
    end;
  end
  else
  begin
    if not ValidateShortByteOffset(ByteOffset, Instr.LineNumber, ErrorReporter) then
    begin
      Result.OpCode := 0;
      Exit;
    end;
  end;

  // Set canonical mnemonic
  if IsLongMode then
    Result.CanonicalMnemonic := BaseMnemonic + '.L'
  else
    Result.CanonicalMnemonic := BaseMnemonic + '.S';

  // Build opcode
  OpcodeValue := GetBranchOpcode;
  OpCode := OpcodeValue shl 11;

  if IsUnconditionalBranch(Instr.Mnemonic) then
  begin
    // BRA/BRANCH: Mode 10 (short) or Mode 11 (long), condition always 000
    if IsLongMode then
    begin
      OpCode := OpCode or (3 shl 9);  // Mode 11
      OpCode := OpCode or (0 shl 5);  // Condition 000 (always)
      Result.HasImmediate := True;
      Result.Immediate := Word(ByteOffset and $FFFF);
    end
    else
    begin
      OpCode := OpCode or (2 shl 9);  // Mode 10
      OpCode := OpCode or (0 shl 5);  // Condition 000 (always)
      OpCode := OpCode or (ByteOffset and $1F);
    end;
  end
  else
  begin
    // Conditional branches: Mode 00 (short) or Mode 01 (long)
    if IsLongMode then
    begin
      OpCode := OpCode or (1 shl 9);  // Mode 01
      OpCode := OpCode or (Byte(Condition) shl 5);
      Result.HasImmediate := True;
      Result.Immediate := Word(ByteOffset and $FFFF);
    end
    else
    begin
      OpCode := OpCode or (0 shl 9);  // Mode 00
      OpCode := OpCode or (Byte(Condition) shl 5);
      OpCode := OpCode or (ByteOffset and $1F);
    end;
  end;

  Result.OpCode := OpCode;
end;

end.
