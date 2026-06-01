unit K16_Encoder_LEA;

{$mode Delphi}

{
  K16 Assembler Encoder for LEA (Load Effective Address) Instruction
  ===================================================================

  Opcode $03: Calculate address without memory access

  Syntax (no brackets - LEA calculates address, not memory access):
    LEA XYn, XYm                Mode 00: Copy XY pair
    LEA XYn, XYm+Do             Mode 01: Dynamic index
    LEA XYn, label              Mode 10: PC-relative (label)
    LEA XYn, XYm+#imm5          Mode 11: Stack offset (0-31)

  Encoding:
    Bit:  15-11 | 10-9 | 8-7 | 6-5 | 4-3 | 2-0
          00011 | MODE | XYn | XYm | Dn  | imm3
}

interface

uses
  SysUtils, StrUtils,
  K16_Parser, K16_Encoder_Base;

type
  // Internal record for LEA address expression parsing (no brackets)
  TLeaAddressExpr = record
    BaseReg: string;           // XY0-XY3 or empty for PC-relative label
    Offset: Integer;           // Numeric offset for Mode 11
    HasOffset: Boolean;        // True if numeric offset present
    OffsetRegister: string;    // D0-D3 for Mode 01
    HasRegisterOffset: Boolean; // True if D register offset
    OffsetSymbol: string;      // Label name for Mode 10
    HasSymbolOffset: Boolean;  // True if label reference
    IsLabel: Boolean;          // True if just a plain label (Mode 10)
  end;

  TK16LeaEncoder = class(TK16EncoderBase, IK16Encoder)
  private
    function ParseXYPairRegister(const RegStr: string): Integer;
    function ParseLeaAddressExpr(const ExprStr: string): TLeaAddressExpr;
    function ValidateXYPairDestination(const DestStr: string;
      ErrorReporter: TErrorReporter; LineNumber: Integer): Integer;
  public
    function Encode(const Instr: TInstructionRecord;
                   SymbolResolver: TSymbolResolver;
                   ErrorReporter: TErrorReporter;
                   WarningReporter: TWarningReporter): TMachineCode;
    function GetSupportedMnemonics: TArray<string>;
    function SupportsInstruction(const Mnemonic: string): Boolean;
  end;

implementation

const
  OPCODE_LEA = $03;  // 00011

{ TK16LeaEncoder }

function TK16LeaEncoder.GetSupportedMnemonics: TArray<string>;
begin
  Result := ['LEA'];
end;

function TK16LeaEncoder.SupportsInstruction(const Mnemonic: string): Boolean;
begin
  Result := SameText(Mnemonic, 'LEA');
end;

function TK16LeaEncoder.ParseXYPairRegister(const RegStr: string): Integer;
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

function TK16LeaEncoder.ParseLeaAddressExpr(const ExprStr: string): TLeaAddressExpr;
var
  Expr: string;
  PlusPos: Integer;
  BaseStr, OffsetStr: string;
  IsWordSuffix: Boolean;
begin
  // Initialize result
  Result.BaseReg := '';
  Result.Offset := 0;
  Result.HasOffset := False;
  Result.OffsetRegister := '';
  Result.HasRegisterOffset := False;
  Result.OffsetSymbol := '';
  Result.HasSymbolOffset := False;
  Result.IsLabel := False;

  Expr := Trim(ExprStr);
  if Length(Expr) = 0 then Exit;

  // Check for + sign (XY+D or XY+#imm)
  PlusPos := Pos('+', Expr);

  if PlusPos > 0 then
  begin
    // Has offset: XYm+Do or XYm+#imm5
    BaseStr := Trim(Copy(Expr, 1, PlusPos - 1));
    OffsetStr := Trim(Copy(Expr, PlusPos + 1, Length(Expr) - PlusPos));

    Result.BaseReg := UpperCase(BaseStr);

    // Check if offset is a D-register (XY+D0 through XY+D3)
    if (Length(OffsetStr) = 2) and (UpperCase(OffsetStr)[1] = 'D') and
       (OffsetStr[2] in ['0'..'3']) then
    begin
      Result.HasRegisterOffset := True;
      Result.OffsetRegister := UpperCase(OffsetStr);
    end
    else
    begin
      // Parse as immediate offset
      // Remove # if present
      if (Length(OffsetStr) > 0) and (OffsetStr[1] = '#') then
        OffsetStr := Copy(OffsetStr, 2, Length(OffsetStr) - 1);

      if Length(OffsetStr) > 0 then
      begin
        // Check if it looks like a number (starts with digit or $)
        if (OffsetStr[1] in ['0'..'9', '$']) then
        begin
          Result.HasOffset := True;
          // Check for 'w' suffix (word count - multiply by 2)
          IsWordSuffix := (Length(OffsetStr) > 0) and
              (OffsetStr[Length(OffsetStr)] in ['w', 'W']);
          if IsWordSuffix then
            OffsetStr := Copy(OffsetStr, 1, Length(OffsetStr) - 1);
          try
            Result.Offset := StrToInt(OffsetStr);
            if IsWordSuffix then
              Result.Offset := Result.Offset * 2;
          except
            // If parse fails, treat as symbol
            Result.HasOffset := False;
            Result.HasSymbolOffset := True;
            Result.OffsetSymbol := UpperCase(OffsetStr);
          end;
        end
        else
        begin
          // Symbol reference (e.g., XY0+LABEL - unusual but valid)
          Result.HasSymbolOffset := True;
          Result.OffsetSymbol := UpperCase(OffsetStr);
        end;
      end;
    end;
  end
  else
  begin
    // No + sign - either just XYm (copy) or a label (PC-relative)
    BaseStr := UpperCase(Expr);

    // Check if it's an XY register
    if (BaseStr = 'XY0') or (BaseStr = 'XY1') or
       (BaseStr = 'XY2') or (BaseStr = 'XY3') then
    begin
      // Mode 00: Copy XY pair
      Result.BaseReg := BaseStr;
    end
    else
    begin
      // Assume it's a label for PC-relative addressing (Mode 10)
      Result.IsLabel := True;
      Result.OffsetSymbol := BaseStr;
      Result.HasSymbolOffset := True;
    end;
  end;
end;

function TK16LeaEncoder.ValidateXYPairDestination(const DestStr: string;
  ErrorReporter: TErrorReporter; LineNumber: Integer): Integer;
begin
  Result := ParseXYPairRegister(DestStr);
  if Result < 0 then
  begin
    ErrorReporter(Format('LEA destination must be XY register pair (XY0-XY3), got %s',
      [DestStr]), LineNumber);
  end;
end;

function TK16LeaEncoder.Encode(const Instr: TInstructionRecord;
  SymbolResolver: TSymbolResolver;
  ErrorReporter: TErrorReporter;
  WarningReporter: TWarningReporter): TMachineCode;
var
  OpCode: Word;
  XYn, XYm: Integer;
  OffsetReg: TRegister;
  AddrExpr: TLeaAddressExpr;
  ImmediateValue: Word;
  IntValue: Integer;
  LabelAddr: Cardinal;
  PCAfter: Cardinal;
  RelOffset: Integer;
begin
  Result.OpCode := 0;
  Result.HasImmediate := False;
  Result.Immediate := 0;

  // Base opcode for LEA: 00011 = $03
  OpCode := OPCODE_LEA shl 11;

  // Validate operand count
  if Length(Instr.Operands) <> 2 then
  begin
    ErrorReporter('LEA requires exactly 2 operands: LEA XYn, address', Instr.LineNumber);
    Exit;
  end;

  // Parse and validate destination (must be XY pair)
  XYn := ValidateXYPairDestination(Instr.Operands[0], ErrorReporter, Instr.LineNumber);
  if XYn < 0 then
    Exit;

  // Parse address expression (no brackets for LEA)
  AddrExpr := ParseLeaAddressExpr(Instr.Operands[1]);

  // =========================================================================
  // MODE 10: label - PC-relative (just a label, no base register)
  //
  // NOTE (27 May 2026): LEA Mode 10 is PAGE-LOCAL on current hardware —
  // Yn is copied directly from PCH at runtime, with no carry/borrow from
  // the low-word add. The previous "24-bit PC-relative" microcode was
  // broken for negative displacements (every backward label reference
  // came out one page high). The fix simplified Mode 10 to a 4-step
  // page-local form; this warning catches code that would have relied
  // on the cross-page behaviour and now silently fails.
  //
  // For cross-page address loading, use:
  //   LOADI Xn, #<LABEL
  //   MOVE  Yn, Y3                ; under k/OS - task page
  // or
  //   LOADI Xn, #<LABEL
  //   LOADI Yn, #>LABEL           ; bare-metal - known page at assembly time
  // =========================================================================
  if AddrExpr.IsLabel then
  begin
    // Resolve symbol to absolute address
    LabelAddr := SymbolResolver(AddrExpr.OffsetSymbol, Instr.LineNumber);

    // PC after this instruction (2-word instruction = 4 bytes)
    PCAfter := Instr.Address + 4;

    // Calculate relative offset
    RelOffset := Integer(LabelAddr) - Integer(PCAfter);

    // Validate range (16-bit signed: -32768 to +32767)
    if (RelOffset < -32768) or (RelOffset > 32767) then
    begin
      ErrorReporter(Format('LEA PC-relative offset out of range: %d (label %s at $%6.6X, PC after = $%6.6X)',
        [RelOffset, AddrExpr.OffsetSymbol, LabelAddr, PCAfter]), Instr.LineNumber);
      Exit;
    end;

    // Page-locality check: warn if LEA and label are in different
    // assembly-time pages (compare bits 23..16). Runtime Yn will be
    // PCH (LEA's page) regardless of what the displacement points at,
    // so a cross-page LEA produces a wrong-page address silently.
    if (LabelAddr shr 16) <> (Instr.Address shr 16) then
    begin
      if Assigned(WarningReporter) then
        WarningReporter(Format('LEA XY%d, %s crosses page boundary ' +
          '(LEA at $%6.6X, label at $%6.6X) — Mode 10 is page-local; ' +
          'Y will be set to LEA''s page byte, not the label''s. Use ' +
          '"LOADI Xn,#<%s / MOVE Yn,Y3" under k/OS or ' +
          '"LOADI Xn,#<%s / LOADI Yn,#>%s" for bare-metal cross-page.',
          [XYn, AddrExpr.OffsetSymbol,
           Instr.Address, LabelAddr,
           AddrExpr.OffsetSymbol,
           AddrExpr.OffsetSymbol, AddrExpr.OffsetSymbol]),
          Instr.LineNumber);
    end;

    ImmediateValue := Word(RelOffset and $FFFF);

    // Encoding: 00011 | 10 | XYn | 00 | 00 | 000 + IMM16
    OpCode := OpCode or (2 shl 9);                  // MODE = 10
    OpCode := OpCode or (XYn shl 7);                // XYn (bits 8-7)
    OpCode := OpCode or 0;                          // Bits 6-0 = 0000000

    Result.HasImmediate := True;
    Result.Immediate := ImmediateValue;
  end

  // =========================================================================
  // MODE 01: XYm+Do - Dynamic indexing with D register
  // =========================================================================
  else if AddrExpr.HasRegisterOffset then
  begin
    OffsetReg := TRegister.Parse(AddrExpr.OffsetRegister);

    if OffsetReg.RegType <> rtData then
    begin
      ErrorReporter('LEA Mode 01 requires D-register offset: XYm+D0 through XYm+D3', Instr.LineNumber);
      Exit;
    end;

    XYm := ParseXYPairRegister(AddrExpr.BaseReg);
    if XYm < 0 then
    begin
      ErrorReporter(Format('LEA Mode 01 requires XY pair base register, got %s', [AddrExpr.BaseReg]), Instr.LineNumber);
      Exit;
    end;

    // Encoding: 00011 | 01 | XYn | XYm | Dn | 000
    OpCode := OpCode or (1 shl 9);                    // MODE = 01
    OpCode := OpCode or (XYn shl 7);                  // XYn (bits 8-7)
    OpCode := OpCode or (XYm shl 5);                  // XYm (bits 6-5)
    OpCode := OpCode or (OffsetReg.Number shl 3);    // Dn (bits 4-3)
    OpCode := OpCode or 0;                            // Bits 2-0 = 000
  end

  // =========================================================================
  // MODE 11: XYm+#imm5 - Indexed with 5-bit immediate offset (literal)
  // =========================================================================
  else if AddrExpr.HasOffset then
  begin
    XYm := ParseXYPairRegister(AddrExpr.BaseReg);
    if XYm < 0 then
    begin
      ErrorReporter(Format('LEA Mode 11 requires XY pair base register, got %s', [AddrExpr.BaseReg]), Instr.LineNumber);
      Exit;
    end;

    // Check IMM5 range (0-31)
    IntValue := AddrExpr.Offset;
    if (IntValue < 0) or (IntValue > 31) then
    begin
      ErrorReporter(Format('LEA Mode 11 offset must be 0-31, got %d', [IntValue]), Instr.LineNumber);
      Exit;
    end;

    // Encoding: 00011 | 11 | XYn | XYm | IMM5[4:0]
    OpCode := OpCode or (3 shl 9);                    // MODE = 11
    OpCode := OpCode or (XYn shl 7);                  // XYn (bits 8-7)
    OpCode := OpCode or (XYm shl 5);                  // XYm (bits 6-5)
    OpCode := OpCode or (IntValue and $1F);           // IMM5 (bits 4-0)
  end

  // =========================================================================
  // MODE 11 (symbolic): XYm+#SYMBOL or XYm+SYMBOL - resolve symbol to imm5
  // =========================================================================
  else if AddrExpr.HasSymbolOffset and (AddrExpr.BaseReg <> '') then
  begin
    XYm := ParseXYPairRegister(AddrExpr.BaseReg);
    if XYm < 0 then
    begin
      ErrorReporter(Format('LEA Mode 11 requires XY pair base register, got %s', [AddrExpr.BaseReg]), Instr.LineNumber);
      Exit;
    end;

    // Resolve symbol to its value. SymbolResolver convention is to pass
    // the symbol prefixed with '#' for immediate references.
    IntValue := Integer(SymbolResolver('#' + AddrExpr.OffsetSymbol, Instr.LineNumber));

    // Range check: IMM5 is unsigned 0..31
    if (IntValue < 0) or (IntValue > 31) then
    begin
      ErrorReporter(Format('LEA Mode 11 offset must be 0-31, got %d (from symbol %s)',
        [IntValue, AddrExpr.OffsetSymbol]), Instr.LineNumber);
      Exit;
    end;

    // Encoding: 00011 | 11 | XYn | XYm | IMM5[4:0]
    OpCode := OpCode or (3 shl 9);                    // MODE = 11
    OpCode := OpCode or (XYn shl 7);                  // XYn (bits 8-7)
    OpCode := OpCode or (XYm shl 5);                  // XYm (bits 6-5)
    OpCode := OpCode or (IntValue and $1F);           // IMM5 (bits 4-0)
  end

  // =========================================================================
  // MODE 00: XYm - Direct copy (no offset)
  // =========================================================================
  else if AddrExpr.BaseReg <> '' then
  begin
    XYm := ParseXYPairRegister(AddrExpr.BaseReg);
    if XYm < 0 then
    begin
      ErrorReporter(Format('LEA Mode 00 requires XY pair register, got %s', [AddrExpr.BaseReg]), Instr.LineNumber);
      Exit;
    end;

    // Encoding: 00011 | 00 | XYn | XYm | 00 | 000
    OpCode := OpCode or (0 shl 9);                    // MODE = 00
    OpCode := OpCode or (XYn shl 7);                  // XYn (bits 8-7)
    OpCode := OpCode or (XYm shl 5);                  // XYm (bits 6-5)
    OpCode := OpCode or 0;                            // Bits 4-0 = 00000
  end

  else
  begin
    ErrorReporter(Format('Invalid LEA address expression: %s', [Instr.Operands[1]]), Instr.LineNumber);
    Exit;
  end;

  Result.OpCode := OpCode;
end;

end.
