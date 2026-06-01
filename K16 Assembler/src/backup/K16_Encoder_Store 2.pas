unit K16_Encoder_Store;

{$mode Delphi}

interface

uses
  SysUtils, StrUtils,
  K16_Parser, K16_Encoder_Base;

type
  TK16StoreEncoder = class(TK16EncoderBase, IK16Encoder)
  private
    function ResolveGenericMnemonic(const Mnemonic: string;
      const Operands: TArray<string>; ErrorReporter: TErrorReporter; LineNumber: Integer): string;
    function IsWordOperation(const Mnemonic: string): Boolean;
    function ValidateSourceRegister(const Mnemonic: string;
      const SrcReg: TRegister; ErrorReporter: TErrorReporter; LineNumber: Integer): Boolean;
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

{ TK16StoreEncoder }

function TK16StoreEncoder.GetSupportedMnemonics: TArray<string>;
begin
  Result := ['STORE', 'STORED', 'STOREB', 'STOREX', 'STOREY', 'STOREI', 'STOREXY', 'STOREP', 'STOREPB',
             'STOREZ', 'STOREZB'];
end;

function TK16StoreEncoder.SupportsInstruction(const Mnemonic: string): Boolean;
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

function TK16StoreEncoder.IsWordOperation(const Mnemonic: string): Boolean;
begin
  // Word operations require even addresses for proper alignment
  // STOREB is byte operation - no alignment needed
  Result := SameText(Mnemonic, 'STORED') or
            SameText(Mnemonic, 'STOREX') or
            SameText(Mnemonic, 'STOREY') or
            SameText(Mnemonic, 'STORE');  // Generic STORE resolves to word op
end;

function TK16StoreEncoder.ValidateSourceRegister(const Mnemonic: string;
  const SrcReg: TRegister; ErrorReporter: TErrorReporter; LineNumber: Integer): Boolean;

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

  if SameText(Mnemonic, 'STORED') then
  begin
    if SrcReg.RegType <> rtData then
    begin
      ErrorReporter(Format('STORED requires D register source (D0-D3), got %s',
        [RegToStr(SrcReg)]), LineNumber);
      Result := False;
    end;
  end
  else if SameText(Mnemonic, 'STOREX') then
  begin
    if SrcReg.RegType <> rtIndexX then
    begin
      ErrorReporter(Format('STOREX requires X register source (X0-X3), got %s',
        [RegToStr(SrcReg)]), LineNumber);
      Result := False;
    end;
  end
  else if SameText(Mnemonic, 'STOREY') then
  begin
    if SrcReg.RegType <> rtIndexY then
    begin
      ErrorReporter(Format('STOREY requires Y register source (Y0-Y3), got %s',
        [RegToStr(SrcReg)]), LineNumber);
      Result := False;
    end;
  end
  else if SameText(Mnemonic, 'STOREB') then
  begin
    if SrcReg.RegType <> rtData then
    begin
      ErrorReporter(Format('STOREB requires D register source (D0-D3), got %s',
        [RegToStr(SrcReg)]), LineNumber);
      Result := False;
    end;
  end;
  // STORE accepts any valid register type (resolved by ResolveGenericMnemonic)
end;

function TK16StoreEncoder.ValidateXYPair(const MemRef: TMemoryRef;
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

function TK16StoreEncoder.ParseXYPairRegister(const RegStr: string): Integer;
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

function TK16StoreEncoder.ParseYRegister(const RegStr: string): Integer;
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

function TK16StoreEncoder.ResolveGenericMnemonic(const Mnemonic: string;
  const Operands: TArray<string>; ErrorReporter: TErrorReporter; LineNumber: Integer): string;
var
  SourceOp, SecondOp: string;
  SourceReg: TRegister;
begin
  Result := Mnemonic; // Default - return original

  if SameText(Mnemonic, 'STORE') then
  begin
    if Length(Operands) >= 2 then
    begin
      SourceOp := Operands[0];
      SecondOp := Operands[1];

      // Check for STOREI pattern: STORE #value, [XY]
      // First operand is immediate, second is memory reference
      if (Length(SourceOp) > 0) and (SourceOp[1] = '#') and
         (Length(SecondOp) > 0) and (SecondOp[1] = '[') then
      begin
        Result := 'STOREI';  // STORE #5, [XY0] -> STOREI
        Exit;
      end;

      // Reject old syntax: STORE [XY], #value
      if (Length(SourceOp) > 0) and (SourceOp[1] = '[') and
         (Length(SecondOp) > 0) and (SecondOp[1] = '#') then
      begin
        ErrorReporter('Invalid STORE syntax. Use: STORE #value, [XYn] (value first, then memory)', LineNumber);
        Exit;
      end;

      // Memory store - determine type from source register
      SourceReg := TRegister.Parse(SourceOp);

      if SourceReg.IsValid then
      begin
        case SourceReg.RegType of
          rtData:   Result := 'STORED';  // STORE D0, [XY0] -> STORED
          rtIndexX: Result := 'STOREX';  // STORE X0, [XY0] -> STOREX
          rtIndexY: Result := 'STOREY';  // STORE Y0, [XY0] -> STOREY
        else
          ErrorReporter('Invalid source register for STORE', LineNumber);
        end;
      end
      else
        ErrorReporter('Invalid source register syntax in STORE', LineNumber);
    end
    else
      ErrorReporter('STORE requires at least 2 operands', LineNumber);
  end;
end;

function TK16StoreEncoder.Encode(const Instr: TInstructionRecord;
                                SymbolResolver: TSymbolResolver;
                                ErrorReporter: TErrorReporter;
                                WarningReporter: TWarningReporter): TMachineCode;
var
  OpCode: Word;
  OpcodeValue: Byte;
  ImmediateValue: Word;
  RegField: Byte;
  TempMemRef: TMemoryRef;
  TempImm: TImmediateValue;
  MemOp: string;
  OffsetReg: TRegister;
  SourceReg: TRegister;
  IntValue: Integer;
  ResolvedMnemonic: string;
  LabelAddr: UInt32;
  PCAfter: UInt32;
  RelOffset: Integer;
  SrcXY, DestXY: Integer;
  FirstOp, SecondOp: string;
  YReg: Integer;
  BracketContent: string;
begin
  // Resolve generic mnemonic but use original Instr for all data
  ResolvedMnemonic := ResolveGenericMnemonic(Instr.Mnemonic, Instr.Operands, ErrorReporter, Instr.LineNumber);

  // Get base opcode value
  // STORED=0x19, STOREB=0x1A, STOREX=0x1B, STOREY=0x1C, STOREI=0x1D
  if SameText(ResolvedMnemonic, 'STORED') then OpcodeValue := $19
  else if SameText(ResolvedMnemonic, 'STOREB') then OpcodeValue := $1A
  else if SameText(ResolvedMnemonic, 'STOREX') then OpcodeValue := $1B
  else if SameText(ResolvedMnemonic, 'STOREY') then OpcodeValue := $1C
  else if SameText(ResolvedMnemonic, 'STOREI') then OpcodeValue := $1D
  else if SameText(Instr.Mnemonic, 'STOREXY') then OpcodeValue := $1D  // STOREXY uses STOREI opcode
  else if SameText(Instr.Mnemonic, 'STOREP') then OpcodeValue := $1D   // STOREP uses STOREI opcode
  else if SameText(Instr.Mnemonic, 'STOREZ') then OpcodeValue := $1D   // STOREZ uses STOREI opcode
  else OpcodeValue := $19; // Default to STORED

  OpCode := OpcodeValue shl 11; // Bits 15-11: Opcode

  // Initialize result
  Result.OpCode := OpCode;
  Result.Address := Instr.Address;
  Result.SourceLine := Instr.LineNumber;
  Result.HasImmediate := False;
  Result.Immediate := 0;
  Result.CanonicalMnemonic := ResolvedMnemonic;

  // =========================================================================
  // STOREXY HANDLING - Mode 10: Store XY pair to [XY]
  // Syntax: STOREXY XYsrc, [XYdest]
  // Encoding: 11101 10 ss ss dd dd 00000
  //   Bits 15-11: opcode $1D
  //   Bits 10-9:  mode 10
  //   Bits 8-7:   src XY pair (the pair to store)
  //   Bits 6-5:   dest XY pair (pointer to store at)
  //   Bits 4-0:   00000
  // =========================================================================
  if SameText(Instr.Mnemonic, 'STOREXY') then
  begin
    Result.CanonicalMnemonic := 'STOREXY';

    if Length(Instr.Operands) <> 2 then
    begin
      ErrorReporter('STOREXY requires exactly 2 operands: STOREXY XYsrc, [XYdest]', Instr.LineNumber);
      Result.OpCode := 0;
      Exit;
    end;

    FirstOp := Instr.Operands[0];
    SecondOp := Instr.Operands[1];

    // Parse source XY pair (first operand)
    SrcXY := ParseXYPairRegister(FirstOp);
    if SrcXY < 0 then
    begin
      ErrorReporter(Format('STOREXY requires XY register pair source (XY0-XY3), got %s',
        [FirstOp]), Instr.LineNumber);
      Result.OpCode := 0;
      Exit;
    end;

    // Parse destination [XY] (second operand - memory reference)
    if (Length(SecondOp) < 3) or (SecondOp[1] <> '[') or (SecondOp[Length(SecondOp)] <> ']') then
    begin
      ErrorReporter(Format('STOREXY requires memory reference [XYn] as second operand, got %s', [SecondOp]), Instr.LineNumber);
      Result.OpCode := 0;
      Exit;
    end;

    // Extract register name from brackets
    DestXY := ParseXYPairRegister(Copy(SecondOp, 2, Length(SecondOp) - 2));
    if DestXY < 0 then
    begin
      ErrorReporter(Format('STOREXY requires XY register pair destination [XY0-XY3], got %s', [SecondOp]), Instr.LineNumber);
      Result.OpCode := 0;
      Exit;
    end;

    // Encode: 11101 10 ss ss dd dd 00000
    // Bits 15-11: 11101 ($1D)
    // Bits 10-9:  10 (Mode 10)
    // Bits 8-7:   source XY pair (0-3)
    // Bits 6-5:   destination XY pair (0-3)
    // Bits 4-0:   00000
    OpCode := OpCode or (2 shl 9);          // MODE = 10
    OpCode := OpCode or (SrcXY shl 7);      // src xy xy (bits 8-7)
    OpCode := OpCode or (DestXY shl 5);     // dest [xy] [xy] (bits 6-5)
    OpCode := OpCode or 0;                  // Bits 4-0 = 00000

    Result.OpCode := OpCode;
    Exit;
  end

  // =========================================================================
  // STOREP/STOREPB HANDLING - Mode 11: Store to paged memory [Yn:IMM16]
  // Syntax: STOREP src, Yn, [#offset]   (word)
  //         STOREPB src, Yn, [#offset]  (byte)
  // Encoding: 11101 11 sr sr sr sr 0 b yy 0 + IMM16
  //   b = 0 for word (STOREP), b = 1 for byte (STOREPB)
  // =========================================================================
  else if SameText(Instr.Mnemonic, 'STOREP') or SameText(Instr.Mnemonic, 'STOREPB') then
  begin
    Result.CanonicalMnemonic := Instr.Mnemonic;

    if Length(Instr.Operands) <> 3 then
    begin
      ErrorReporter(Format('%s requires exactly 3 operands: %s src, Yn, [#offset]',
        [Instr.Mnemonic, Instr.Mnemonic]), Instr.LineNumber);
      Result.OpCode := 0;
      Exit;
    end;

    // Parse source register (first operand)
    SourceReg := TRegister.Parse(Instr.Operands[0]);
    if not SourceReg.IsValid then
    begin
      ErrorReporter(Format('%s: invalid source register %s',
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
    MemOp := Instr.Operands[2];
    if (Length(MemOp) < 3) or (MemOp[1] <> '[') or (MemOp[Length(MemOp)] <> ']') then
    begin
      ErrorReporter(Format('%s requires memory reference [#offset], got %s',
        [Instr.Mnemonic, MemOp]), Instr.LineNumber);
      Result.OpCode := 0;
      Exit;
    end;

    // Extract content between brackets
    BracketContent := Copy(MemOp, 2, Length(MemOp) - 2);
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
    if SameText(Instr.Mnemonic, 'STOREP') and ((ImmediateValue and 1) = 1) then
    begin
      WarningReporter(Format('STOREP with odd offset #$%4.4X may cause misalignment. ' +
        'Word operations require even addresses.', [ImmediateValue]), Instr.LineNumber);
    end;

    // Encode source register (4 bits)
    RegField := EncodeDestinationRegister(SourceReg);

    // Build opcode: 11101 11 sr sr sr sr 0 b yy 0
    // Bits 15-11: 11101 = $1D
    // Bits 10-9: 11 = Mode 11
    // Bits 8-5: source register
    // Bit 4: 0 (fixed)
    // Bit 3: 0 = word (STOREP), 1 = byte (STOREPB)
    // Bits 2-1: Y register selector
    // Bit 0: 0 (reserved)
    OpCode := $1D shl 11;                    // Opcode $1D
    OpCode := OpCode or (3 shl 9);           // Mode 11
    OpCode := OpCode or (RegField shl 5);    // src register (4 bits at 8-5)
    if SameText(Instr.Mnemonic, 'STOREPB') then
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
  // STOREZ/STOREZB HANDLING - Mode 11 ZOA: Store to zero page [$00:IMM16]
  // Syntax: STOREZ  src, [#offset]   (word)
  //         STOREZB src, [#offset]   (byte)
  // Encoding: 11101 11 sr sr sr sr 1 b 00 0 + IMM16
  //   IR4 = 1 selects ZOA path in microcode (Y selector ignored)
  //   IR3 = 0 word (STOREZ), 1 byte (STOREZB)
  // =========================================================================
  else if SameText(Instr.Mnemonic, 'STOREZ') or SameText(Instr.Mnemonic, 'STOREZB') then
  begin
    Result.CanonicalMnemonic := Instr.Mnemonic;

    if Length(Instr.Operands) <> 2 then
    begin
      ErrorReporter(Format('%s requires exactly 2 operands: %s src, [#offset]',
        [Instr.Mnemonic, Instr.Mnemonic]), Instr.LineNumber);
      Result.OpCode := 0;
      Exit;
    end;

    // Parse source register (first operand)
    SourceReg := TRegister.Parse(Instr.Operands[0]);
    if not SourceReg.IsValid then
    begin
      ErrorReporter(Format('%s: invalid source register %s',
        [Instr.Mnemonic, Instr.Operands[0]]), Instr.LineNumber);
      Result.OpCode := 0;
      Exit;
    end;

    // Parse memory reference with immediate (second operand)
    MemOp := Instr.Operands[1];
    if (Length(MemOp) < 3) or (MemOp[1] <> '[') or (MemOp[Length(MemOp)] <> ']') then
    begin
      ErrorReporter(Format('%s requires memory reference [#offset], got %s',
        [Instr.Mnemonic, MemOp]), Instr.LineNumber);
      Result.OpCode := 0;
      Exit;
    end;

    // Extract content between brackets
    BracketContent := Copy(MemOp, 2, Length(MemOp) - 2);
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
    if SameText(Instr.Mnemonic, 'STOREZ') and ((ImmediateValue and 1) = 1) then
    begin
      WarningReporter(Format('STOREZ with odd offset #$%4.4X may cause misalignment. ' +
        'Word operations require even addresses.', [ImmediateValue]), Instr.LineNumber);
    end;

    // Encode source register (4 bits)
    RegField := EncodeDestinationRegister(SourceReg);

    // Build opcode: 11101 11 sr sr sr sr 1 b 00 0
    // Bits 15-11: 11101 = $1D
    // Bits 10-9: 11 = Mode 11
    // Bits 8-5: source register
    // Bit 4: 1 (ZOA select)
    // Bit 3: 0 = word (STOREZ), 1 = byte (STOREZB)
    // Bits 2-1: 00 (Y selector ignored when ZOA)
    // Bit 0: 0 (reserved)
    OpCode := $1D shl 11;                    // Opcode $1D
    OpCode := OpCode or (3 shl 9);           // Mode 11
    OpCode := OpCode or (RegField shl 5);    // src register (4 bits at 8-5)
    OpCode := OpCode or (1 shl 4);           // ZOA flag (bit 4 = 1)
    if SameText(Instr.Mnemonic, 'STOREZB') then
      OpCode := OpCode or (1 shl 3);         // Byte mode (bit 3 = 1)
    // bits 2-1 = 00, bit 0 = 0 (already cleared)

    Result.OpCode := OpCode;
    Result.HasImmediate := True;
    Result.Immediate := Word(ImmediateValue and $FFFF);
    Exit;
  end

  // =========================================================================
  // STOREI HANDLING (Store immediate to memory)
  // Syntax: STOREI #value, [XYn]  or  STORE #value, [XYn]
  // Mode 00: IMM5 (0-31) - single word
  // Mode 01: IMM16 (any 16-bit value) - two words
  // =========================================================================
  else if SameText(ResolvedMnemonic, 'STOREI') then
  begin
    // Validate operand count
    if Length(Instr.Operands) <> 2 then
    begin
      ErrorReporter('STOREI requires exactly 2 operands: STOREI #value, [XYn]', Instr.LineNumber);
      Result.OpCode := 0;
      Exit;
    end;

    // Validate first operand is immediate
    if (Length(Instr.Operands[0]) = 0) or (Instr.Operands[0][1] <> '#') then
    begin
      ErrorReporter('STOREI requires immediate value as first operand', Instr.LineNumber);
      Result.OpCode := 0;
      Exit;
    end;

    // Validate second operand is memory reference
    if (Length(Instr.Operands[1]) = 0) or (Instr.Operands[1][1] <> '[') then
    begin
      ErrorReporter('STOREI requires memory reference as second operand', Instr.LineNumber);
      Result.OpCode := 0;
      Exit;
    end;

    // Parse memory reference
    TempMemRef := TMemoryRef.Parse(Instr.Operands[1]);
    if not ValidateXYPair(TempMemRef, ErrorReporter, Instr.LineNumber) then
    begin
      Result.OpCode := 0;
      Exit;
    end;

    // Parse immediate value (first operand)
    TempImm := TImmediateValue.Parse(Instr.Operands[0]);
    ImmediateValue := ResolveImmediate(TempImm, SymbolResolver, Instr.LineNumber);
    IntValue := Integer(ImmediateValue);

    // Select mode based on value range
    if (IntValue >= 0) and (IntValue <= 31) then
    begin
      // Mode 00: IMM5 - single word encoding
      // Encoding: [opcode:5] [mode:00] [00] [xy:2] [imm5:5]
      OpCode := OpCode or (0 shl 9);                               // MODE = 00
      OpCode := OpCode or (GetXYRegisterNumber(TempMemRef) shl 5); // XY (bits 6-5)
      OpCode := OpCode or (IntValue and $1F);                      // IMM5 (bits 4-0)
    end
    else
    begin
      // Mode 01: IMM16 - two word encoding
      // Encoding: [opcode:5] [mode:01] [00] [xy:2] [00000] + IMM16
      OpCode := OpCode or (1 shl 9);                               // MODE = 01
      OpCode := OpCode or (GetXYRegisterNumber(TempMemRef) shl 5); // XY (bits 6-5)
      OpCode := OpCode or 0;                                       // Bits 4-0 = 00000
      Result.HasImmediate := True;
      Result.Immediate := ImmediateValue;
    end;

    Result.OpCode := OpCode;
    Exit;
  end;

  // =========================================================================
  // STORE FAMILY HANDLING (STORED/STOREB/STOREX/STOREY)
  // ARM Syntax: STORED source_reg, [memory]
  // =========================================================================
  if Length(Instr.Operands) <> 2 then
  begin
    ErrorReporter(Format('%s requires exactly 2 operands', [ResolvedMnemonic]), Instr.LineNumber);
    Result.OpCode := 0;
    Exit;
  end;

  // Validate source operand is NOT an immediate
  if (Length(Instr.Operands[0]) > 0) and (Instr.Operands[0][1] = '#') then
  begin
    ErrorReporter(Format('%s requires register source, not immediate value. ' +
      'Suggestion: LOADI Dn, %s then %s Dn, %s',
      [ResolvedMnemonic, Instr.Operands[0], ResolvedMnemonic, Instr.Operands[1]]),
      Instr.LineNumber);
    Result.OpCode := 0;
    Exit;
  end;

  // First operand is SOURCE register
  SourceReg := TRegister.Parse(Instr.Operands[0]);

  // Validate register parsed successfully
  if not SourceReg.IsValid then
  begin
    ErrorReporter(Format('Invalid source register for %s: %s',
      [ResolvedMnemonic, Instr.Operands[0]]), Instr.LineNumber);
    Result.OpCode := 0;
    Exit;
  end;

  // *** NEW: Validate mnemonic matches source register type ***
  if not ValidateSourceRegister(ResolvedMnemonic, SourceReg, ErrorReporter, Instr.LineNumber) then
  begin
    Result.OpCode := 0;
    Exit;
  end;

  // Second operand is MEMORY destination
  MemOp := Instr.Operands[1];

  // Get register field (bits 8-7) - source register number (0-3)
  RegField := SourceReg.Number and $03;

  // Check for memory references ([...])
  if (Length(MemOp) > 0) and (MemOp[1] = '[') then
  begin
    TempMemRef := TMemoryRef.Parse(MemOp);

    // *** Check for invalid comma syntax ***
    if TempMemRef.BaseReg = '' then
    begin
      if Pos(',', MemOp) > 0 then
        ErrorReporter(Format('Invalid memory syntax: use [XY+#offset] not [XY, #offset]. Got: %s',
          [MemOp]), Instr.LineNumber)
      else
        ErrorReporter(Format('Invalid memory reference: %s', [MemOp]), Instr.LineNumber);
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

      // Encoding: [opcode] 0 1 sr sr xy xy d d 0 0 0
      OpCode := OpCode or (1 shl 9);                               // MODE = 01 (bit 9 = 1)
      OpCode := OpCode or (RegField shl 7);                        // sr sr (bits 8-7)
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

        // Encoding: [opcode] 1 0 sr sr 0 0 0 0 0 0 0 + IMM16
        OpCode := OpCode or (2 shl 9);                    // MODE = 10 (bit 10 = 1)
        OpCode := OpCode or (RegField shl 7);             // sr sr (bits 8-7)
        OpCode := OpCode or 0;                            // Bits 6-0 = 0000000

        Result.HasImmediate := True;
        Result.Immediate := ImmediateValue;
      end
      else
      begin
        // MODE 00: [PC] direct access (if supported)
        OpCode := OpCode or (0 shl 9);                // MODE = 00
        OpCode := OpCode or (RegField shl 7);         // sr sr (bits 8-7)
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

      // Encoding: OPCODE 1 1 sr sr xy xy imm5[4:0]
      OpCode := OpCode or (3 shl 9);                               // MODE = 11 (bits 10-9 = 11)
      OpCode := OpCode or (RegField shl 7);                        // sr sr (bits 8-7)
      OpCode := OpCode or (GetXYRegisterNumber(TempMemRef) shl 5); // xy xy (bits 6-5)
      OpCode := OpCode or (IntValue and $1F);                      // IMM5 (bits 4-0)
    end

    // MODE 00: [XY] - Direct XY addressing (no offset)
    else
    begin
      // Encoding: [opcode] 0 0 sr sr xy xy 0 0 0 0 0
      OpCode := OpCode or (0 shl 9);                      // MODE = 00 (bits 10-9 = 00)
      OpCode := OpCode or (RegField shl 7);               // sr sr (bits 8-7)
      OpCode := OpCode or (GetXYRegisterNumber(TempMemRef) shl 5); // xy xy (bits 6-5)
      OpCode := OpCode or 0;                              // Bits 4-0 = 00000
    end;
  end

  else
    ErrorReporter(Format('Invalid memory operand format for %s: %s', [ResolvedMnemonic, MemOp]), Instr.LineNumber);

  Result.OpCode := OpCode;
end;

end.
