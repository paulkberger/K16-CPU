unit K16_Encoder_Load;

{$mode Delphi}

interface

uses
  SysUtils, StrUtils,
  K16_Parser, K16_Encoder_Base;

type
  TK16LoadEncoder = class(TK16EncoderBase, IK16Encoder)
  private
    function ResolveGenericMnemonic(const Mnemonic: string;
      const Operands: TArray<string>; ErrorReporter: TErrorReporter; LineNumber: Integer): string;
    function SelectImmediateMode(Value: Integer): TAddressingMode;
    function IsWordOperation(const Mnemonic: string): Boolean;
    function ValidateDestinationRegister(const Mnemonic: string;
      const DestReg: TRegister; ErrorReporter: TErrorReporter; LineNumber: Integer): Boolean;
    function ValidateXYPair(const MemRef: TMemoryRef;
      ErrorReporter: TErrorReporter; LineNumber: Integer): Boolean;
    function ParseXYPairRegister(const RegStr: string): Integer;
    function ParseYRegister(const RegStr: string): Integer;
  public
    function Encode(const Instr: TInstructionRecord;
                   SymbolResolver: TSymbolResolver;
                   ErrorReporter: TErrorReporter;
                   WarningReporter: TWarningReporter): TMachineCode;
    function GetSupportedMnemonics: TArray<string>;
    function SupportsInstruction(const Mnemonic: string): Boolean;
  end;

implementation

{ TK16LoadEncoder }

function TK16LoadEncoder.GetSupportedMnemonics: TArray<string>;
begin
  Result := ['LOAD', 'LOADD', 'LOADB', 'LOADX', 'LOADY', 'LOADI', 'LOADXY', 'LOADP', 'LOADPB',
             'LOADZ', 'LOADZB',
             'SEC', 'CLC'];  // SEC/CLC are aliases for LOADI SR, #$01 / LOADI SR, #$00
end;

function TK16LoadEncoder.SupportsInstruction(const Mnemonic: string): Boolean;
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

function TK16LoadEncoder.SelectImmediateMode(Value: Integer): TAddressingMode;
begin
  // T8-5 range: 0-31 (unsigned bytes) → use IMM5 for fast 1-word encoding
  if (Value >= 0) and (Value <= 31) then
    Result := amImm5
  else
    Result := amImm16; // T16W for everything else
end;

function TK16LoadEncoder.IsWordOperation(const Mnemonic: string): Boolean;
begin
  // Word operations require even addresses for proper alignment
  // LOADB is byte operation - no alignment needed
  Result := SameText(Mnemonic, 'LOADD') or
            SameText(Mnemonic, 'LOADX') or
            SameText(Mnemonic, 'LOADY') or
            SameText(Mnemonic, 'LOAD');  // Generic LOAD resolves to word op
end;

function TK16LoadEncoder.ValidateDestinationRegister(const Mnemonic: string;
  const DestReg: TRegister; ErrorReporter: TErrorReporter; LineNumber: Integer): Boolean;

  function RegToStr(const R: TRegister): string;
  begin
    case R.RegType of
      rtData:   Result := Format('D%d', [R.Number]);
      rtIndexX: Result := Format('X%d', [R.Number]);
      rtIndexY: Result := Format('Y%d', [R.Number]);
      rtPC:     Result := 'PC';
      rtSR:     Result := 'SR';
    else
      Result := '?';
    end;
  end;

begin
  Result := True;

  if SameText(Mnemonic, 'LOADD') then
  begin
    if DestReg.RegType <> rtData then
    begin
      ErrorReporter(Format('LOADD requires D register destination (D0-D3), got %s',
        [RegToStr(DestReg)]), LineNumber);
      Result := False;
    end;
  end
  else if SameText(Mnemonic, 'LOADX') then
  begin
    if DestReg.RegType <> rtIndexX then
    begin
      ErrorReporter(Format('LOADX requires X register destination (X0-X3), got %s',
        [RegToStr(DestReg)]), LineNumber);
      Result := False;
    end;
  end
  else if SameText(Mnemonic, 'LOADY') then
  begin
    if DestReg.RegType <> rtIndexY then
    begin
      ErrorReporter(Format('LOADY requires Y register destination (Y0-Y3), got %s',
        [RegToStr(DestReg)]), LineNumber);
      Result := False;
    end;
  end
  else if SameText(Mnemonic, 'LOADB') then
  begin
    if DestReg.RegType <> rtData then
    begin
      ErrorReporter(Format('LOADB requires D register destination (D0-D3), got %s',
        [RegToStr(DestReg)]), LineNumber);
      Result := False;
    end;
  end;
  // LOAD and LOADI accept any valid register type
end;

function TK16LoadEncoder.ValidateXYPair(const MemRef: TMemoryRef;
  ErrorReporter: TErrorReporter; LineNumber: Integer): Boolean;
var
  BaseReg: string;
begin
  Result := True;
  BaseReg := UpperCase(MemRef.BaseReg);

  // PC is valid for Mode 10 (PC-relative)
  if BaseReg = 'PC' then
    Exit(True);

  // Must be XY0, XY1, XY2, or XY3 - not just X0-X3 or Y0-Y3
  if not ((BaseReg = 'XY0') or (BaseReg = 'XY1') or
          (BaseReg = 'XY2') or (BaseReg = 'XY3')) then
  begin
    ErrorReporter(Format('Memory addressing requires XY register pair (XY0-XY3), got %s. ' +
      'Use [XY0], [XY1], [XY2], or [XY3] syntax.', [MemRef.BaseReg]), LineNumber);
    Result := False;
  end;
end;

function TK16LoadEncoder.ParseXYPairRegister(const RegStr: string): Integer;
var
  UpperReg: string;
begin
  // Returns 0-3 for XY0-XY3, -1 for invalid
  Result := -1;
  UpperReg := UpperCase(Trim(RegStr));

  if UpperReg = 'XY0' then Result := 0
  else if UpperReg = 'XY1' then Result := 1
  else if UpperReg = 'XY2' then Result := 2
  else if UpperReg = 'XY3' then Result := 3;
end;

function TK16LoadEncoder.ParseYRegister(const RegStr: string): Integer;
var
  UpperReg: string;
begin
  // Returns 0-3 for Y0-Y3, -1 for invalid
  Result := -1;
  UpperReg := UpperCase(Trim(RegStr));

  if UpperReg = 'Y0' then Result := 0
  else if UpperReg = 'Y1' then Result := 1
  else if UpperReg = 'Y2' then Result := 2
  else if UpperReg = 'Y3' then Result := 3;
end;

function TK16LoadEncoder.ResolveGenericMnemonic(const Mnemonic: string;
  const Operands: TArray<string>; ErrorReporter: TErrorReporter; LineNumber: Integer): string;
var
  DestReg: TRegister;
  SecondOp: string;
begin
  Result := Mnemonic; // Default - return original

  if SameText(Mnemonic, 'LOAD') then
  begin
    if Length(Operands) >= 2 then
    begin
      DestReg := TRegister.Parse(Operands[0]);
      SecondOp := Operands[1];

      if DestReg.IsValid then
      begin
        // Check if second operand is immediate (#value)
        if (Length(SecondOp) > 0) and (SecondOp[1] = '#') then
        begin
          // Immediate load - always use LOADI
          Result := 'LOADI';  // LOAD D0, #5 → LOADI D0, #5
        end
        else
        begin
          // Memory load - use register-specific instruction
          case DestReg.RegType of
            rtData:   Result := 'LOADD';  // LOAD D0, [XY0] → LOADD
            rtIndexX: Result := 'LOADX';  // LOAD X0, [XY0] → LOADX
            rtIndexY: Result := 'LOADY';  // LOAD Y0, [XY0] → LOADY
            rtPC:     Result := 'LOADD';  // LOAD PC, [XY0] → LOADD (treat PC as data)
          else
            ErrorReporter('Invalid destination register for LOAD', LineNumber);
          end;
        end;
      end
      else
        ErrorReporter('Invalid destination register syntax in LOAD', LineNumber);
    end
    else
      ErrorReporter('LOAD requires at least 2 operands', LineNumber);
  end;
end;

function TK16LoadEncoder.Encode(const Instr: TInstructionRecord;
                               SymbolResolver: TSymbolResolver;
                               ErrorReporter: TErrorReporter;
                               WarningReporter: TWarningReporter): TMachineCode;
var
  OpCode: Word;
  OpcodeValue: Byte;
  ImmediateValue: Word;
  RegField: Byte;
  ActualMode: TAddressingMode;
  TempMemRef: TMemoryRef;
  LastOp: string;
  TempImm: TImmediateValue;
  ResolvedMnemonic: string;
  OffsetReg: TRegister;
  IntValue: Integer;
  LabelAddr: UInt32;
  PCAfter: UInt32;
  RelOffset: Integer;
  DestXY, SrcXY: Integer;
  DestReg: TRegister;
  YReg: Integer;
  BracketContent: string;
  LocalInstr: TInstructionRecord;  // Mutable copy for SEC/CLC alias rewrite
begin
  // -------------------------------------------------------------------------
  // SEC / CLC — Level 2 syntactic sugar for LOADI SR, #$01 / LOADI SR, #$00
  // Rewrite in place to a LOADI instruction and fall through to normal LOADI
  // encoding path below. Both take no operands.
  // -------------------------------------------------------------------------
  if SameText(Instr.Mnemonic, 'SEC') or SameText(Instr.Mnemonic, 'CLC') then
  begin
    if Length(Instr.Operands) <> 0 then
    begin
      ErrorReporter(Format('%s takes no operands', [UpperCase(Instr.Mnemonic)]),
        Instr.LineNumber);
      Result.OpCode := 0;
      Exit;
    end;

    LocalInstr := Instr;
    LocalInstr.Mnemonic := 'LOADI';
    LocalInstr.Destination.RegType := rtSR;
    LocalInstr.Destination.Number  := 0;
    LocalInstr.Destination.Name    := 'SR';

    SetLength(LocalInstr.Operands, 2);
    LocalInstr.Operands[0] := 'SR';
    if SameText(Instr.Mnemonic, 'SEC') then
      LocalInstr.Operands[1] := '#$01'
    else
      LocalInstr.Operands[1] := '#$00';

    // Re-dispatch through ourselves with the rewritten instruction
    Result := Encode(LocalInstr, SymbolResolver, ErrorReporter, WarningReporter);
    Result.CanonicalMnemonic := UpperCase(Instr.Mnemonic);  // preserve SEC/CLC in listing
    Exit;
  end;

  // Resolve generic mnemonic but use original Instr for all data
  ResolvedMnemonic := ResolveGenericMnemonic(Instr.Mnemonic, Instr.Operands, ErrorReporter, Instr.LineNumber);

  // Get base opcode value
  if SameText(ResolvedMnemonic, 'LOADD') then OpcodeValue := $14
  else if SameText(ResolvedMnemonic, 'LOADB') then OpcodeValue := $15
  else if SameText(ResolvedMnemonic, 'LOADX') then OpcodeValue := $16
  else if SameText(ResolvedMnemonic, 'LOADY') then OpcodeValue := $17
  else if SameText(ResolvedMnemonic, 'LOADI') then OpcodeValue := $18
  else if SameText(Instr.Mnemonic, 'LOADXY') then OpcodeValue := $18  // LOADXY uses LOADI opcode
  else if SameText(Instr.Mnemonic, 'LOADP') then OpcodeValue := $18   // LOADP uses LOADI opcode
  else if SameText(Instr.Mnemonic, 'LOADZ') then OpcodeValue := $18   // LOADZ uses LOADI opcode
  else OpcodeValue := $14; // Default to LOADD

  OpCode := OpcodeValue shl 11; // Bits 15-11: Opcode

  // Initialize result
  Result.OpCode := OpCode;
  Result.Address := Instr.Address;
  Result.SourceLine := Instr.LineNumber;
  Result.HasImmediate := False;
  Result.Immediate := 0;
  Result.CanonicalMnemonic := ResolvedMnemonic;

  // =========================================================================
  // LOADXY HANDLING - Mode 10: Load XY pair from [XY]
  // Syntax: LOADXY XYn, [XYm]
  // Encoding: 11000 10 xy xy [xy] [xy] 00000
  // =========================================================================
  if SameText(Instr.Mnemonic, 'LOADXY') then
  begin
    Result.CanonicalMnemonic := 'LOADXY';

    if Length(Instr.Operands) <> 2 then
    begin
      ErrorReporter('LOADXY requires exactly 2 operands: LOADXY XYn, [XYm]', Instr.LineNumber);
      Result.OpCode := 0;
      Exit;
    end;

    // Parse destination XY pair (first operand)
    DestXY := ParseXYPairRegister(Instr.Operands[0]);
    if DestXY < 0 then
    begin
      ErrorReporter(Format('LOADXY requires XY register pair destination (XY0-XY3), got %s',
        [Instr.Operands[0]]), Instr.LineNumber);
      Result.OpCode := 0;
      Exit;
    end;

    // Parse source [XY] (second operand)
    LastOp := Instr.Operands[1];
    if (Length(LastOp) < 3) or (LastOp[1] <> '[') or (LastOp[Length(LastOp)] <> ']') then
    begin
      ErrorReporter(Format('LOADXY requires memory reference [XYn], got %s', [LastOp]), Instr.LineNumber);
      Result.OpCode := 0;
      Exit;
    end;

    // Extract register name from brackets
    SrcXY := ParseXYPairRegister(Copy(LastOp, 2, Length(LastOp) - 2));
    if SrcXY < 0 then
    begin
      ErrorReporter(Format('LOADXY requires XY register pair source [XY0-XY3], got %s', [LastOp]), Instr.LineNumber);
      Result.OpCode := 0;
      Exit;
    end;

    // Encode: 11000 10 xy xy [xy] [xy] 00000
    // Bits 15-11: 11000 ($18)
    // Bits 10-9:  10 (Mode 10)
    // Bits 8-7:   destination XY pair (0-3)
    // Bits 6-5:   source XY pair (0-3)
    // Bits 4-0:   00000
    OpCode := OpCode or (2 shl 9);          // MODE = 10
    OpCode := OpCode or (DestXY shl 7);     // dest xy xy (bits 8-7)
    OpCode := OpCode or (SrcXY shl 5);      // src [xy] [xy] (bits 6-5)
    OpCode := OpCode or 0;                  // Bits 4-0 = 00000

    Result.OpCode := OpCode;
    Exit;
  end

  // =========================================================================
  // LOADP/LOADPB HANDLING - Mode 11: Load from paged memory [Yn:IMM16]
  // Syntax: LOADP dest, Yn, [#offset]   (word)
  //         LOADPB dest, Yn, [#offset]  (byte)
  // Encoding: 11000 11 dr dr dr dr 0 b yy 0 + IMM16
  //   b = 0 for word (LOADP), b = 1 for byte (LOADPB)
  // =========================================================================
  else if SameText(Instr.Mnemonic, 'LOADP') or SameText(Instr.Mnemonic, 'LOADPB') then
  begin
    Result.CanonicalMnemonic := Instr.Mnemonic;

    if Length(Instr.Operands) <> 3 then
    begin
      ErrorReporter(Format('%s requires exactly 3 operands: %s dest, Yn, [#offset]',
        [Instr.Mnemonic, Instr.Mnemonic]), Instr.LineNumber);
      Result.OpCode := 0;
      Exit;
    end;

    // Parse destination register (first operand)
    DestReg := TRegister.Parse(Instr.Operands[0]);
    if not DestReg.IsValid then
    begin
      ErrorReporter(Format('%s: invalid destination register %s',
        [Instr.Mnemonic, Instr.Operands[0]]), Instr.LineNumber);
      Result.OpCode := 0;
      Exit;
    end;

    // Parse Y register (second operand) - provides bank/page
    YReg := ParseYRegister(Instr.Operands[1]);
    if YReg < 0 then
    begin
      ErrorReporter(Format('%s requires Y register (Y0-Y3) as bank selector, got %s',
        [Instr.Mnemonic, Instr.Operands[1]]), Instr.LineNumber);
      Result.OpCode := 0;
      Exit;
    end;

    // Parse memory reference with immediate (third operand)
    LastOp := Instr.Operands[2];
    if (Length(LastOp) < 3) or (LastOp[1] <> '[') or (LastOp[Length(LastOp)] <> ']') then
    begin
      ErrorReporter(Format('%s requires memory reference [#offset], got %s',
        [Instr.Mnemonic, LastOp]), Instr.LineNumber);
      Result.OpCode := 0;
      Exit;
    end;

    // Extract content between brackets
    BracketContent := Copy(LastOp, 2, Length(LastOp) - 2);
    if (Length(BracketContent) = 0) or (BracketContent[1] <> '#') then
    begin
      ErrorReporter(Format('%s requires immediate offset: [#value]', [Instr.Mnemonic]), Instr.LineNumber);
      Result.OpCode := 0;
      Exit;
    end;

    // Parse immediate value
    TempImm := TImmediateValue.Parse(BracketContent);
    ImmediateValue := ResolveImmediate(TempImm, SymbolResolver, Instr.LineNumber);

    // Alignment warning for word operations
    if SameText(Instr.Mnemonic, 'LOADP') and ((ImmediateValue and 1) = 1) then
    begin
      WarningReporter(Format('LOADP with odd offset #$%4.4X may cause misalignment. ' +
        'Word operations require even addresses.', [ImmediateValue]), Instr.LineNumber);
    end;

    // Encode destination register (4 bits)
    RegField := EncodeDestinationRegister(DestReg);

    // Build opcode: 11000 11 dr dr dr dr 0 b yy 0
    // Bits 15-11: 11000 = $18
    // Bits 10-9: 11 = Mode 11
    // Bits 8-5: destination register
    // Bit 4: 0 (fixed)
    // Bit 3: 0 = word (LOADP), 1 = byte (LOADPB)
    // Bits 2-1: Y register selector
    // Bit 0: 0 (reserved)
    OpCode := $18 shl 11;                    // Opcode $18
    OpCode := OpCode or (3 shl 9);           // Mode 11
    OpCode := OpCode or (RegField shl 5);    // dest register (4 bits at 8-5)
    if SameText(Instr.Mnemonic, 'LOADPB') then
      OpCode := OpCode or (1 shl 3)          // Byte mode (bit 3 = 1)
    else
      OpCode := OpCode or (0 shl 3);         // Word mode (bit 3 = 0)
    OpCode := OpCode or (YReg shl 1);        // Y register (bits 2-1)
    OpCode := OpCode or 0;                   // Reserved bit 0

    Result.OpCode := OpCode;
    Result.HasImmediate := True;
    Result.Immediate := Word(ImmediateValue and $FFFF);
    Exit;
  end

  // =========================================================================
  // LOADZ/LOADZB HANDLING - Mode 11 ZOA: Load from zero page [$00:IMM16]
  // Syntax: LOADZ  dest, [#offset]   (word)
  //         LOADZB dest, [#offset]   (byte)
  // Encoding: 11000 11 dr dr dr dr 1 b 00 0 + IMM16
  //   IR4 = 1 selects ZOA path in microcode (Y selector ignored)
  //   IR3 = 0 word (LOADZ), 1 byte (LOADZB)
  // =========================================================================
  else if SameText(Instr.Mnemonic, 'LOADZ') or SameText(Instr.Mnemonic, 'LOADZB') then
  begin
    Result.CanonicalMnemonic := Instr.Mnemonic;

    if Length(Instr.Operands) <> 2 then
    begin
      ErrorReporter(Format('%s requires exactly 2 operands: %s dest, [#offset]',
        [Instr.Mnemonic, Instr.Mnemonic]), Instr.LineNumber);
      Result.OpCode := 0;
      Exit;
    end;

    // Parse destination register (first operand)
    DestReg := TRegister.Parse(Instr.Operands[0]);
    if not DestReg.IsValid then
    begin
      ErrorReporter(Format('%s: invalid destination register %s',
        [Instr.Mnemonic, Instr.Operands[0]]), Instr.LineNumber);
      Result.OpCode := 0;
      Exit;
    end;

    // Parse memory reference with immediate (second operand)
    LastOp := Instr.Operands[1];
    if (Length(LastOp) < 3) or (LastOp[1] <> '[') or (LastOp[Length(LastOp)] <> ']') then
    begin
      ErrorReporter(Format('%s requires memory reference [#offset], got %s',
        [Instr.Mnemonic, LastOp]), Instr.LineNumber);
      Result.OpCode := 0;
      Exit;
    end;

    // Extract content between brackets
    BracketContent := Copy(LastOp, 2, Length(LastOp) - 2);
    if (Length(BracketContent) = 0) or (BracketContent[1] <> '#') then
    begin
      ErrorReporter(Format('%s requires immediate offset: [#value]', [Instr.Mnemonic]), Instr.LineNumber);
      Result.OpCode := 0;
      Exit;
    end;

    // Parse immediate value
    TempImm := TImmediateValue.Parse(BracketContent);
    ImmediateValue := ResolveImmediate(TempImm, SymbolResolver, Instr.LineNumber);

    // Alignment warning for word operations
    if SameText(Instr.Mnemonic, 'LOADZ') and ((ImmediateValue and 1) = 1) then
    begin
      WarningReporter(Format('LOADZ with odd offset #$%4.4X may cause misalignment. ' +
        'Word operations require even addresses.', [ImmediateValue]), Instr.LineNumber);
    end;

    // Encode destination register (4 bits)
    RegField := EncodeDestinationRegister(DestReg);

    // Build opcode: 11000 11 dr dr dr dr 1 b 00 0
    // Bits 15-11: 11000 = $18
    // Bits 10-9: 11 = Mode 11
    // Bits 8-5: destination register
    // Bit 4: 1 (ZOA select)
    // Bit 3: 0 = word (LOADZ), 1 = byte (LOADZB)
    // Bits 2-1: 00 (Y selector ignored when ZOA)
    // Bit 0: 0 (reserved)
    OpCode := $18 shl 11;                    // Opcode $18
    OpCode := OpCode or (3 shl 9);           // Mode 11
    OpCode := OpCode or (RegField shl 5);    // dest register (4 bits at 8-5)
    OpCode := OpCode or (1 shl 4);           // ZOA flag (bit 4 = 1)
    if SameText(Instr.Mnemonic, 'LOADZB') then
      OpCode := OpCode or (1 shl 3);         // Byte mode (bit 3 = 1)
    // bits 2-1 = 00, bit 0 = 0 (already cleared)

    Result.OpCode := OpCode;
    Result.HasImmediate := True;
    Result.Immediate := Word(ImmediateValue and $FFFF);
    Exit;
  end

  // =========================================================================
  // LOADI HANDLING (Pure immediate loads)
  // Mode 00: IMM5 (0-31)
  // Mode 01: IMM16 (any 16-bit value)
  // =========================================================================
  else if SameText(ResolvedMnemonic, 'LOADI') then
  begin
    if Length(Instr.Operands) = 2 then
    begin
      LastOp := Instr.Operands[1];

      if (Length(LastOp) > 0) and (LastOp[1] = '#') then
      begin

        // Parse immediate
        TempImm := TImmediateValue.Parse(LastOp);
        ImmediateValue := ResolveImmediate(TempImm, SymbolResolver, Instr.LineNumber);

        // Convert to signed integer for range checking
        IntValue := Integer(ImmediateValue);
        if ImmediateValue > 32767 then
          IntValue := IntValue - 65536;

        // Determine LOADI mode: 0-31 = Mode 00 (IMM5), else Mode 01 (IMM16)
        if (IntValue >= 0) and (IntValue <= 31) then
          ActualMode := amImm5
        else
          ActualMode := amImm16;

        // Encode based on destination register type and mode
        case Instr.Destination.RegType of
          rtData:
          begin
            // D-register encoding: dr dr dr dr = D0-D3 (0000-0011)
            if ActualMode = amImm5 then
            begin
              OpCode := OpCode or (0 shl 9);                          // MODE = 00
              OpCode := OpCode or (Instr.Destination.Number shl 5);   // dr dr dr dr (4 bits)
              OpCode := OpCode or (ImmediateValue and $1F);           // IMM5 (bits 4-0)
            end
            else
            begin
              OpCode := OpCode or (1 shl 9);                        // MODE = 01 (was 11)
              OpCode := OpCode or (Instr.Destination.Number shl 5); // dr dr dr dr (4 bits)
              OpCode := OpCode or 0;                                // Bits 4-0 unused
              Result.HasImmediate := True;
              Result.Immediate := ImmediateValue;
            end;
          end;

          rtIndexX:
          begin
            // X-register encoding: dr dr dr dr = X0-X3 (0100-0111)
            if ActualMode = amImm5 then
            begin
              OpCode := OpCode or (0 shl 9);                                    // MODE = 00
              OpCode := OpCode or ((4 + Instr.Destination.Number) shl 5);       // dr dr dr dr (4+X#)
              OpCode := OpCode or (ImmediateValue and $1F);                     // IMM5
            end
            else
            begin
              OpCode := OpCode or (1 shl 9);                                  // MODE = 01 (was 11)
              OpCode := OpCode or ((4 + Instr.Destination.Number) shl 5);     // dr dr dr dr (4+X#)
              OpCode := OpCode or 0;                                          // Bits 4-0 unused
              Result.HasImmediate := True;
              Result.Immediate := ImmediateValue;
            end;
          end;

          rtIndexY:
          begin
            // Y-register encoding: dr dr dr dr = Y0-Y3 (1000-1011)
            if ActualMode = amImm5 then
            begin
              OpCode := OpCode or (0 shl 9);                                    // MODE = 00
              OpCode := OpCode or ((8 + Instr.Destination.Number) shl 5);       // dr dr dr dr (8+Y#)
              OpCode := OpCode or (ImmediateValue and $1F);                     // IMM5
            end
            else
            begin
              OpCode := OpCode or (1 shl 9);                                  // MODE = 01 (was 11)
              OpCode := OpCode or ((8 + Instr.Destination.Number) shl 5);     // dr dr dr dr (8+Y#)
              OpCode := OpCode or 0;                                          // Bits 4-0 unused
              Result.HasImmediate := True;
              Result.Immediate := ImmediateValue;
            end;
          end;

          rtPC:
          begin
            // PC encoding: dr dr dr dr = PC (1100)
            if ActualMode = amImm5 then
            begin
              OpCode := OpCode or (0 shl 9);                          // MODE = 00
              OpCode := OpCode or (12 shl 5);                         // dr dr dr dr = 1100 (PC)
              OpCode := OpCode or (ImmediateValue and $1F);           // IMM5
            end
            else
            begin
              OpCode := OpCode or (1 shl 9);                        // MODE = 01 (was 11)
              OpCode := OpCode or (12 shl 5);                       // dr dr dr dr = 1100 (PC)
              OpCode := OpCode or 0;                                // Bits 4-0 unused
              Result.HasImmediate := True;
              Result.Immediate := ImmediateValue;
            end;
          end;

          rtSR:
          begin
            // SR (Status Register) encoding: dr dr dr dr = SR (1101)
            if ActualMode = amImm5 then
            begin
              OpCode := OpCode or (0 shl 9);                          // MODE = 00
              OpCode := OpCode or (13 shl 5);                         // dr dr dr dr = 1101 (SR)
              OpCode := OpCode or (ImmediateValue and $1F);           // IMM5
            end
            else
            begin
              OpCode := OpCode or (1 shl 9);                        // MODE = 01 (was 11)
              OpCode := OpCode or (13 shl 5);                       // dr dr dr dr = 1101 (SR)
              OpCode := OpCode or 0;                                // Bits 4-0 unused
              Result.HasImmediate := True;
              Result.Immediate := ImmediateValue;
            end;
          end;

          else
            ErrorReporter('LOADI: Invalid destination register type', Instr.LineNumber);
        end;
      end
      else
        ErrorReporter('LOADI requires immediate value (#value)', Instr.LineNumber);
    end
    else
      ErrorReporter('LOADI requires exactly 2 operands', Instr.LineNumber);
  end

  // =========================================================================
  // LOAD FAMILY HANDLING (LOADD/LOADB/LOADX/LOADY)
  // =========================================================================
  else
  begin
    // *** Validate mnemonic matches destination register type ***
    if not ValidateDestinationRegister(ResolvedMnemonic, Instr.Destination,
                                        ErrorReporter, Instr.LineNumber) then
    begin
      Result.OpCode := 0;
      Exit;
    end;

    // Get register field (bits 8-7) - destination register number (0-3)
    case Instr.Destination.RegType of
      rtData:   RegField := Instr.Destination.Number and $03;  // D0-D3
      rtIndexX: RegField := Instr.Destination.Number and $03;  // X0-X3
      rtIndexY: RegField := Instr.Destination.Number and $03;  // Y0-Y3
    else
      begin
        ErrorReporter(Format('Invalid destination register type for %s',
          [ResolvedMnemonic]), Instr.LineNumber);
        Result.OpCode := 0;
        Exit;
      end;
    end;

    // Memory reference handling
    if Length(Instr.Operands) = 2 then
    begin
      LastOp := Instr.Operands[1];

      // Check for memory references ([...])
      if (Length(LastOp) > 0) and (LastOp[1] = '[') then
      begin
        TempMemRef := TMemoryRef.Parse(LastOp);

        // *** Check for invalid comma syntax FIRST ***
        if TempMemRef.BaseReg = '' then
        begin
          if Pos(',', LastOp) > 0 then
            ErrorReporter(Format('Invalid memory syntax: use [XY+#offset] not [XY, #offset]. Got: %s',
              [LastOp]), Instr.LineNumber)
          else
            ErrorReporter(Format('Invalid memory reference: %s', [LastOp]), Instr.LineNumber);
          Result.OpCode := 0;
          Exit;
        end;

        // *** Validate XY pair for non-PC addressing ***
        if not ValidateXYPair(TempMemRef, ErrorReporter, Instr.LineNumber) then
        begin
          Result.OpCode := 0;
          Exit;
        end;

        // MODE 01: [XY+D] - Dynamic indexing
        if TempMemRef.HasRegisterOffset then
        begin
          OffsetReg := TRegister.Parse(TempMemRef.OffsetRegister);

          if OffsetReg.RegType <> rtData then
          begin
            ErrorReporter('Mode 01 requires D-register offset: [XY+D0-D3]', Instr.LineNumber);
            Result.OpCode := 0;
            Exit;
          end;

          // Encoding: 1 0 1 0 0 0 1 dr dr xy xy d d 0 0 0
          OpCode := OpCode or (1 shl 9);                               // MODE = 01 (bit 9 = 1)
          OpCode := OpCode or (RegField shl 7);                        // dr dr (bits 8-7)
          OpCode := OpCode or (GetXYRegisterNumber(TempMemRef) shl 5); // xy xy (bits 6-5)
          OpCode := OpCode or (OffsetReg.Number shl 3);               // d d (bits 4-3) D-register
          OpCode := OpCode or 0;                                       // Bits 2-0 = 000
        end

        // MODE 10: [PC+imm16] or [PC+label] - PC-relative with T16
        else if UpperCase(TempMemRef.BaseReg) = 'PC' then
        begin
          if TempMemRef.HasOffset or TempMemRef.HasSymbolOffset then
          begin
            // Calculate PC-relative offset for symbol references
            if TempMemRef.HasSymbolOffset then
            begin
              // Resolve symbol to absolute address
              LabelAddr := SymbolResolver(TempMemRef.OffsetSymbol, Instr.LineNumber);

              // PC after this instruction (2-word instruction = 4 bytes)
              PCAfter := Instr.Address + 4;

              // Calculate relative offset
              RelOffset := Integer(LabelAddr) - Integer(PCAfter);

              // Validate range (16-bit signed: -32768 to +32767)
              if (RelOffset < -32768) or (RelOffset > 32767) then
              begin
                ErrorReporter(Format('PC-relative offset out of range: %d (label %s at $%6.6X, PC after = $%6.6X)',
                  [RelOffset, TempMemRef.OffsetSymbol, LabelAddr, PCAfter]), Instr.LineNumber);
                Result.OpCode := 0;
                Exit;
              end;

              ImmediateValue := Word(RelOffset and $FFFF);
            end
            else
            begin
              // Explicit numeric offset - use as-is
              ImmediateValue := Word(TempMemRef.Offset and $FFFF);
            end;

            // Encoding: OPCODE 1 0 dr dr 0 0 0 0 0 0 0 + IMM16
            OpCode := OpCode or (2 shl 9);                    // MODE = 10 (bit 10 = 1)
            OpCode := OpCode or (RegField shl 7);             // dr dr (bits 8-7)
            OpCode := OpCode or 0;                            // Bits 6-0 = 0000000

            Result.HasImmediate := True;
            Result.Immediate := ImmediateValue;
          end
          else
          begin
            // MODE 00: [PC] direct access (no offset)
            OpCode := OpCode or (0 shl 9);                // MODE = 00
            OpCode := OpCode or (RegField shl 7);         // dr dr (bits 8-7)
            OpCode := OpCode or (3 shl 5);                // xy xy = 11 for PC special
            OpCode := OpCode or 0;                        // Bits 4-0 = 00000
          end;
        end

        // MODE 11: [XY + IMM5] - Indexed with 5-bit immediate offset
        else if TempMemRef.HasOffset then
        begin
          // Check IMM5 range (0-31)
          IntValue := TempMemRef.Offset;
          if (IntValue < 0) or (IntValue > 31) then
          begin
            ErrorReporter(Format('Mode 11 [XY+IMM5] requires offset 0-31, got %d', [IntValue]), Instr.LineNumber);
            Result.OpCode := 0;
            Exit;
          end;

          // *** ALIGNMENT WARNING: Check for odd offset on word operations ***
          if IsWordOperation(ResolvedMnemonic) and ((IntValue and 1) = 1) then
          begin
            WarningReporter(Format('%s with odd offset #%d may cause misalignment. ' +
              'Word operations require even addresses. Suggestion: use #%d or #%d',
              [ResolvedMnemonic, IntValue, IntValue - 1, IntValue + 1]), Instr.LineNumber);
          end;

          // Encoding: OPCODE 1 1 dr dr xy xy imm5[4:0]
          OpCode := OpCode or (3 shl 9);                               // MODE = 11 (bits 10-9 = 11)
          OpCode := OpCode or (RegField shl 7);                        // dr dr (bits 8-7)
          OpCode := OpCode or (GetXYRegisterNumber(TempMemRef) shl 5); // xy xy (bits 6-5)
          OpCode := OpCode or (IntValue and $1F);                      // IMM5 (bits 4-0)
        end

        // MODE 00: [XY] - Direct XY addressing (no offset)
        else
        begin
          // Encoding: 1 0 1 0 0 0 0 dr dr xy xy 0 0 0 0 0
          OpCode := OpCode or (0 shl 9);                      // MODE = 00 (bits 10-9 = 00)
          OpCode := OpCode or (RegField shl 7);               // dr dr (bits 8-7)
          OpCode := OpCode or (GetXYRegisterNumber(TempMemRef) shl 5); // xy xy (bits 6-5)
          OpCode := OpCode or 0;                              // Bits 4-0 = 00000
        end;
      end

      else
        ErrorReporter(Format('Invalid operand format for %s: %s', [ResolvedMnemonic, LastOp]), Instr.LineNumber);
    end;
  end;

  Result.OpCode := OpCode;
end;

end.
