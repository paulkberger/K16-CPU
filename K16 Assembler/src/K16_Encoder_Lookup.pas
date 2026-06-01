unit K16_Encoder_Lookup;

{$mode Delphi}

interface

uses
  SysUtils,
  K16_Parser, K16_Encoder_Base;

type
  TLookupAlias = (laSHL, laSHR, laASR, laROL, laROR, laSWAPB, laHIGH, laLOW,
                  laSHR4, laSHL4, laASR4, laASR8, laMULB, laRECIP);

  TK16LookupEncoder = class(TK16EncoderBase, IK16Encoder)
  private const
    OPCODE_LOOKUP = $01;  // Bits 15:11

    // ROM table pages at $E00000 (bank $E0-$EE)
    LOOKUP_SHL   = $E0;
    LOOKUP_SHR   = $E2;
    LOOKUP_ASR   = $E4;
    LOOKUP_ROL   = $E6;
    LOOKUP_ROR   = $E8;
    LOOKUP_SWAPB = $EA;
    LOOKUP_HIGH  = $EC;
    LOOKUP_LOW   = $EE;

    // ROM table pages at $F00000 (bank $F0-$FE)
    LOOKUP_SHR4  = $F0;
    LOOKUP_SHL4  = $F2;
    LOOKUP_ASR4  = $F4;
    LOOKUP_ASR8  = $F6;
    LOOKUP_MULB  = $F8;
    LOOKUP_RECIP = $FA;
  private
    function IsAliasInstruction(const Mnemonic: string): Boolean;
    function GetAliasPage(const Mnemonic: string): Byte;
    function EncodeLookupOpcode(DReg: Byte; Page: Byte): Word;
  public
    function Encode(const Instr: TInstructionRecord;
                   SymbolResolver: TSymbolResolver;
                   ErrorReporter: TErrorReporter;
                   WarningReporter: TWarningReporter): TMachineCode;
    function GetSupportedMnemonics: TArray<string>;
    function SupportsInstruction(const Mnemonic: string): Boolean;
  end;

implementation

{ TK16LookupEncoder }

function TK16LookupEncoder.GetSupportedMnemonics: TArray<string>;
begin
  Result := ['LOOKUP', 'SHL', 'SHR', 'ASR', 'ROL', 'ROR', 'SWAPB', 'HIGH', 'LOW',
             'SHR4', 'SHL4', 'ASR4', 'ASR8', 'MULB', 'RECIP'];
end;

function TK16LookupEncoder.SupportsInstruction(const Mnemonic: string): Boolean;
var
  S: string;
begin
  for S in GetSupportedMnemonics do
    if SameText(Mnemonic, S) then
      Exit(True);
  Result := False;
end;

function TK16LookupEncoder.IsAliasInstruction(const Mnemonic: string): Boolean;
begin
  Result := SameText(Mnemonic, 'SHL') or SameText(Mnemonic, 'SHR') or
            SameText(Mnemonic, 'ASR') or SameText(Mnemonic, 'ROL') or
            SameText(Mnemonic, 'ROR') or SameText(Mnemonic, 'SWAPB') or
            SameText(Mnemonic, 'HIGH') or SameText(Mnemonic, 'LOW') or
            SameText(Mnemonic, 'SHR4') or SameText(Mnemonic, 'SHL4') or
            SameText(Mnemonic, 'ASR4') or SameText(Mnemonic, 'ASR8') or
            SameText(Mnemonic, 'MULB') or SameText(Mnemonic, 'RECIP');
end;

function TK16LookupEncoder.GetAliasPage(const Mnemonic: string): Byte;
begin
  // Lookups at $E00000 (bank $E0-$EE)
  if SameText(Mnemonic, 'SHL')   then Result := LOOKUP_SHL
  else if SameText(Mnemonic, 'SHR')   then Result := LOOKUP_SHR
  else if SameText(Mnemonic, 'ASR')   then Result := LOOKUP_ASR
  else if SameText(Mnemonic, 'ROL')   then Result := LOOKUP_ROL
  else if SameText(Mnemonic, 'ROR')   then Result := LOOKUP_ROR
  else if SameText(Mnemonic, 'SWAPB') then Result := LOOKUP_SWAPB
  else if SameText(Mnemonic, 'HIGH')  then Result := LOOKUP_HIGH
  else if SameText(Mnemonic, 'LOW')   then Result := LOOKUP_LOW
  // Lookups at $F00000 (bank $F0-$FE)
  else if SameText(Mnemonic, 'SHR4')  then Result := LOOKUP_SHR4
  else if SameText(Mnemonic, 'SHL4')  then Result := LOOKUP_SHL4
  else if SameText(Mnemonic, 'ASR4')  then Result := LOOKUP_ASR4
  else if SameText(Mnemonic, 'ASR8')  then Result := LOOKUP_ASR8
  else if SameText(Mnemonic, 'MULB')  then Result := LOOKUP_MULB
  else if SameText(Mnemonic, 'RECIP') then Result := LOOKUP_RECIP
  else Result := LOOKUP_SHL;  // Default fallback
end;

function TK16LookupEncoder.EncodeLookupOpcode(DReg: Byte; Page: Byte): Word;
begin
  // Format: OPCODE[15:11] MODE[10:9] 0[8] PAGE[7:0]
  // OPCODE = $01, MODE = D register (0-3), bit 8 reserved = 0, PAGE forced even
  Result := (OPCODE_LOOKUP shl 11) or ((DReg and $03) shl 9) or (Page and $FE);
end;

function TK16LookupEncoder.Encode(const Instr: TInstructionRecord;
                                 SymbolResolver: TSymbolResolver;
                                 ErrorReporter: TErrorReporter;
                                 WarningReporter: TWarningReporter): TMachineCode;
var
  DReg: Byte;
  Page: Byte;
  PageValue: UInt32;
  DestReg: TRegister;
  ImmVal: TImmediateValue;
begin
  Result := Default(TMachineCode);
  Result.Address := Instr.Address;
  Result.SourceLine := Instr.LineNumber;
  Result.CanonicalMnemonic := UpperCase(Instr.Mnemonic);
  Result.IsDataWord := False;
  Result.HasImmediate := False;

  // Alias instructions: SHL, SHR, ASR, ROL, ROR, SWAPB, HIGH, LOW, SHR4, SHL4, ASR4, ASR8, MULB, RECIP
  // Syntax: MNEMONIC Dx
  if IsAliasInstruction(Instr.Mnemonic) then
  begin
    if Length(Instr.Operands) <> 1 then
    begin
      ErrorReporter(Format('%s requires exactly 1 operand (Dx)', [Instr.Mnemonic]), Instr.LineNumber);
      Exit;
    end;

    DestReg := TRegister.Parse(Instr.Operands[0]);
    if not DestReg.IsValid or (DestReg.RegType <> rtData) then
    begin
      ErrorReporter(Format('%s requires D register (D0-D3), got %s',
        [Instr.Mnemonic, Instr.Operands[0]]), Instr.LineNumber);
      Exit;
    end;

    DReg := DestReg.Number;
    Page := GetAliasPage(Instr.Mnemonic);
    Result.OpCode := EncodeLookupOpcode(DReg, Page);
    Result.CanonicalMnemonic := UpperCase(Instr.Mnemonic);
  end

  // Generic LOOKUP instruction
  // Syntax: LOOKUP Dx, #page
  else if SameText(Instr.Mnemonic, 'LOOKUP') then
  begin
    if Length(Instr.Operands) <> 2 then
    begin
      ErrorReporter('LOOKUP requires 2 operands: LOOKUP Dx, #page', Instr.LineNumber);
      Exit;
    end;

    // Parse destination register
    DestReg := TRegister.Parse(Instr.Operands[0]);
    if not DestReg.IsValid or (DestReg.RegType <> rtData) then
    begin
      ErrorReporter(Format('LOOKUP requires D register (D0-D3), got %s',
        [Instr.Operands[0]]), Instr.LineNumber);
      Exit;
    end;
    DReg := DestReg.Number;

    // Parse page immediate
    if (Length(Instr.Operands[1]) < 2) or (Instr.Operands[1][1] <> '#') then
    begin
      ErrorReporter('LOOKUP requires immediate page value (#page)', Instr.LineNumber);
      Exit;
    end;

    ImmVal := TImmediateValue.Parse(Instr.Operands[1]);
    if ImmVal.IsSymbol then
      PageValue := SymbolResolver('#' + ImmVal.SymbolName, Instr.LineNumber)
    else
      PageValue := ImmVal.Value;

    // Validate page range (0-255, 8-bit)
    if PageValue > 255 then
    begin
      ErrorReporter(Format('LOOKUP page must be 0-255, got $%X', [PageValue]), Instr.LineNumber);
      Exit;
    end;

    Page := Byte(PageValue);

    // Warn if odd page specified
    if (Page and 1) <> 0 then
      WarningReporter(Format('LOOKUP: Odd page $%2.2X specified - using $%2.2X',
        [Page, Page and $FE]), Instr.LineNumber);

    Result.OpCode := EncodeLookupOpcode(DReg, Page);
  end
  else
  begin
    ErrorReporter(Format('Unknown LOOKUP instruction: %s', [Instr.Mnemonic]), Instr.LineNumber);
  end;
end;

end.
