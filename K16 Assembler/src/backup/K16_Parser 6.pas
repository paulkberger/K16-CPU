{
  K16_Parser.pas — K16 Assembly Source Parser

  Parses individual source lines into TInstructionRecord structures consumed
  by TK16Assembler. Handles label extraction, mnemonic identification,
  operand splitting, and directive recognition.

  Part of the K16 homebrew CPU project.
  https://github.com/paulkberger/K16-CPU

  License: MIT
}
unit K16_Parser;

{$mode Delphi}

interface

uses
  SysUtils, Classes,
  Generics.Collections, StrUtils;

type
  TRegisterType = (rtData, rtIndexX, rtIndexY, rtPC, rtSR, rtORDB, rtPCH, rtPCL);

  TRegister = record
    RegType: TRegisterType;
    Number: Byte;
    Name: string;

    class function Parse(const Token: string): TRegister; static;
    function IsValid: Boolean;
    function Encode: Byte;
  end;

  TAddressingMode = ( amRegReg,  amRegMem,   amImm5,  amImm16, amMemory, amPCRel,
                      amIndexed, amPCHImm16, amImm8);

  TImmediateValue = record
    Value:    UInt32;
    IsSigned: Boolean;
    BitWidth: Byte;
    IsSymbol: Boolean;
    SymbolName: string;
    HasDerivative: Boolean;
    DerivativeOp:  Char;  // '<' or '>

    class function Parse(const Token: string): TImmediateValue; static;
    function IsValid5Bit: Boolean;
    function IsValid8Bit: Boolean;
    function IsValid5BitSigned: Boolean;
    function ToSigned5Bit: ShortInt;
    function IsValid8BitSigned: Boolean;
    function ToSigned8Bit: ShortInt;
  end;

  TMemoryRef = record
    BaseReg: string;
    Offset: Integer;
    HasOffset: Boolean;
    OffsetRegister: string;
    HasRegisterOffset: Boolean;
    OffsetSymbol: string;
    HasSymbolOffset: Boolean;

    class function Parse(const Token: string): TMemoryRef; static;
    function IsValid: Boolean;
  end;

  TInstructionRecord = record
    SourceLine: string;
    LineNumber: Integer;
    LabelName: string;
    Mnemonic: string;
    CanonicalMnemonic: string;
    Operands: TArray<string>;

    Mode: TAddressingMode;
    Destination: TRegister;
    SourceA: TRegister;
    SourceB: TRegister;
    Immediate: TImmediateValue;
    MemoryRef: TMemoryRef;
    Address: UInt32;
    Scope: string;  // Active global label scope at this instruction (for local label resolution)

    procedure Clear;
    function IsValid: Boolean;
    function GetOperandCount: Integer;
  end;

  TK16Parser = class
  private
    FErrorList: TStringList;
    FCurrentLine: Integer;

    function  CleanLine(const Line: string): string;
    function  ExtractLabel(var Line: string): string;
    function  SplitOperands(const OpStr: string): TArray<string>;
    function  DetermineAddressingMode(const Mnemonic: string; const Operands: TArray<string>): TAddressingMode;
    function  ValidateRegisterCombination(const Instr: TInstructionRecord): Boolean;
    function  ValidateImmediateRange(const Instr: TInstructionRecord): Boolean;
    procedure AddError(const Msg: string);
    procedure AddWarning(const Msg: string);
    function  IsBranchInstruction(const Mnemonic: string): Boolean;
    function  GetBaseBranchMnemonic(const Mnemonic: string): string;
    function  IsALUInstruction(const Mnemonic: string): Boolean;
    function  IsNEGInstruction(const Mnemonic: string): Boolean;
    function  IsSccInstruction(const Mnemonic: string): Boolean;
    function  IsDirective(const Token: string): Boolean;

  public
    constructor Create;
    destructor Destroy; override;

    function ParseLine(const Line: string; LineNumber: Integer): TInstructionRecord;
    function HasErrors: Boolean;
    function GetErrors: TStringList;
    procedure ClearErrors;
  end;

implementation

// TRegister

class function TRegister.Parse(const Token: string): TRegister;
var
  Upper: string;
begin
  Result.Name := Token;
  Upper := UpperCase(Token);

  if (Length(Upper) = 2) and (Upper[1] = 'D') and (Upper[2] in ['0'..'3']) then
  begin
    Result.RegType := rtData;
    Result.Number := Ord(Upper[2]) - Ord('0');
    Exit;
  end;

  if (Length(Upper) = 2) and (Upper[1] = 'X') and (Upper[2] in ['0'..'3']) then
  begin
    Result.RegType := rtIndexX;
    Result.Number := Ord(Upper[2]) - Ord('0');
    Exit;
  end;

  if (Length(Upper) = 2) and (Upper[1] = 'Y') and (Upper[2] in ['0'..'3']) then
  begin
    Result.RegType := rtIndexY;
    Result.Number := Ord(Upper[2]) - Ord('0');
    Exit;
  end;

  if SameText(Upper, 'PC') then
  begin
    Result.RegType := rtPC;
    Result.Number := 0;
    Exit;
  end;

  if SameText(Upper, 'SR') then
  begin
    Result.RegType := rtSR;
    Result.Number := 0;
    Exit;
  end;

  if SameText(Upper, 'ORDB') then
  begin
    Result.RegType := rtORDB;
    Result.Number := 0;
    Exit;
  end;

  if SameText(Upper, 'PCH') then
  begin
    Result.RegType := rtPCH;
    Result.Number := 0;
    Exit;
  end;

  if SameText(Upper, 'PCL') then
  begin
    Result.RegType := rtPCL;
    Result.Number := 0;
    Exit;
  end;

  Result.RegType := rtData;
  Result.Number := 255;
end;

function TRegister.IsValid: Boolean;
begin
  Result := Number <> 255;
end;

function TRegister.Encode: Byte;
begin
  case RegType of
    rtData:   Result := Number;
    rtIndexX: Result := Number + 4;
    rtIndexY: Result := Number + 8;
    rtORDB:   Result := 12;
    rtSR:     Result := 13;
    rtPCH:    Result := 14;
    rtPCL:    Result := 15;
    rtPC:     Result := 15;  // PC maps to PCL for backward compatibility
    else      Result := 255;
  end;
end;

// TImmediateValue
class function TImmediateValue.Parse(const Token: string): TImmediateValue;
var
  ValueStr: string;
  TempValue: Integer;
  i: Integer;
  HasLetter, IsHex, IsWordSuffix: Boolean;
  IsExpression: Boolean;
begin
  Result.Value := 0;
  Result.IsSigned := False;
  Result.BitWidth := 16;
  Result.IsSymbol := False;
  Result.SymbolName := '';
  Result.HasDerivative := False;
  Result.DerivativeOp := #0;

  if Length(Token) = 0 then Exit;
  if Token[1] <> '#' then Exit;

  ValueStr := Copy(Token, 2, Length(Token) - 1); // Remove #

  // Character literal: #'X' where X is a printable char, or #'\n', #'\r', #'\t',
  // #'\0', #'\\', #'\'', #'\"', or #'\xHH'. Escape vocabulary mirrors
  // ParseTextString. Produces a plain numeric immediate equal to the ASCII code.
  // Handle this FIRST so nothing else trips on the embedded quote/backslash.
  if (Length(ValueStr) >= 3) and (ValueStr[1] = '''')
     and (ValueStr[Length(ValueStr)] = '''') then
  begin
    // Extract the content between the quotes
    if (Length(ValueStr) = 3) then
    begin
      // Simple one-char literal: #'X'
      Result.Value := UInt32(Ord(ValueStr[2]));
      Result.IsSymbol := False;
      Result.BitWidth := 8;
      Exit;
    end
    else if (Length(ValueStr) = 4) and (ValueStr[2] = '\') then
    begin
      // Single-char escape: #'\n', #'\r', etc.
      case ValueStr[3] of
        'n':  Result.Value := 10;
        'r':  Result.Value := 13;
        't':  Result.Value := 9;
        '0':  Result.Value := 0;
        '\':  Result.Value := Ord('\');
        '''': Result.Value := Ord('''');
        '"':  Result.Value := Ord('"');
        else
        begin
          Result.Value := 0;
          Result.IsSymbol := True;  // Fall through to symbol resolution for error
          Result.SymbolName := ValueStr;
          Exit;
        end;
      end;
      Result.IsSymbol := False;
      Result.BitWidth := 8;
      Exit;
    end
    else if (Length(ValueStr) = 6) and (ValueStr[2] = '\')
        and (ValueStr[3] in ['x', 'X']) then
    begin
      // Hex escape: #'\xHH'  — 6 chars total: '  \  x  H  H  '
      if TryStrToInt('$' + Copy(ValueStr, 4, 2), TempValue) and
         (TempValue >= 0) and (TempValue <= 255) then
      begin
        Result.Value := UInt32(TempValue);
        Result.IsSymbol := False;
        Result.BitWidth := 8;
        Exit;
      end;
      // Malformed hex escape — fall through to symbol path for error
      Result.IsSymbol := True;
      Result.SymbolName := ValueStr;
      Result.Value := 0;
      Exit;
    end;
    // Not a recognised char-literal form — fall through to normal parsing,
    // which will treat it as a symbol and error out on resolve.
  end;

  // NEW: Check for derivative operator FIRST (before checking negative)
  Result.HasDerivative := False;
  Result.DerivativeOp := #0;
  if (Length(ValueStr) > 0) and (ValueStr[1] in ['<', '>']) then
  begin
    Result.HasDerivative := True;
    Result.DerivativeOp := ValueStr[1];
    ValueStr := Copy(ValueStr, 2, Length(ValueStr) - 1); // Remove derivative
  end;

  // Check for negative values (AFTER derivative check)
  if (Length(ValueStr) > 0) and (ValueStr[1] = '-') then
  begin
    Result.IsSigned := True;
    ValueStr := Copy(ValueStr, 2, Length(ValueStr) - 1);
  end;

  // Check for expression operators or 'w' suffix - route to expression evaluator
  // Look for +, -, *, / anywhere (using Pos for reliability), or parentheses, or 'w' suffix
  IsExpression := (Pos('+', ValueStr) > 0) or
                      (Pos('-', ValueStr) > 1) or  // Position > 1 to skip leading minus
                      (Pos('*', ValueStr) > 0) or
                      (Pos('/', ValueStr) > 0) or
                      (Pos('(', ValueStr) > 0) or
                      ((Length(ValueStr) > 1) and (ValueStr[Length(ValueStr)] in ['w', 'W']));

  if IsExpression then
  begin
    Result.IsSymbol := True;
    if Result.IsSigned then
    begin
      Result.SymbolName := '-' + ValueStr;  // Restore negation for expression evaluator
      Result.IsSigned := False;             // Expression evaluator owns negation now
    end
    else
      Result.SymbolName := ValueStr;        // Keep original case for expression
    Result.Value := 0;
    Exit;
  end;

  // Check for 'w' suffix (word count - multiply by 2)
  // Only check after confirming it's not an expression
  IsWordSuffix := False;
  if (Length(ValueStr) > 0) and (ValueStr[Length(ValueStr)] in ['w', 'W']) then
  begin
    IsWordSuffix := True;
    ValueStr := Copy(ValueStr, 1, Length(ValueStr) - 1); // Remove 'w'
  end;

  // Check for 'b' suffix (byte count - identity, parallel to 'w').
  // Accepted as a no-op so that authors can write explicit step sizes
  // symmetrically: INC XY0, #1b for byte, INC XY0, #1w for word. The
  // assembler's own bare-INC error message recommends this syntax, so it
  // must actually parse. No multiplier applied — raw immediates are
  // already byte-counted.
  //
  // IMPORTANT: only strip 'b'/'B' when the literal is unambiguously decimal.
  // In hex, 'B' is a digit (value 11) — #$1B must mean 27, not 1-with-b-suffix.
  // So we only apply the suffix to plain decimal literals at this stage.
  // (If the value starts with '$' or '0x' it's hex — skip.) This is a
  // deliberate asymmetry with 'w' which cannot be a hex digit.

  // Check if hex value
  IsHex := False;
  if (Length(ValueStr) > 0) and (ValueStr[1] = '$') then
  begin
    IsHex := True;
    ValueStr := Copy(ValueStr, 2, Length(ValueStr) - 1);
  end
  else if (Length(ValueStr) > 2) and
          ((Copy(ValueStr, 1, 2) = '0x') or (Copy(ValueStr, 1, 2) = '0X')) then
  begin
    IsHex := True;
    ValueStr := Copy(ValueStr, 3, Length(ValueStr) - 2);
  end;

  // Now safe to strip trailing 'b' suffix if value is decimal. For hex,
  // 'b'/'B' is a valid digit (= 11) so leave it alone. See comment above.
  if (not IsHex) and (not IsWordSuffix) and
     (Length(ValueStr) > 1) and (ValueStr[Length(ValueStr)] in ['b', 'B']) then
  begin
    // Only strip if preceding chars are all decimal digits — otherwise this
    // is a symbol name that happens to end in 'b' (e.g. 'stub', 'lab_b').
    HasLetter := False;
    for i := 1 to Length(ValueStr) - 1 do
      if not (ValueStr[i] in ['0'..'9']) then
      begin
        HasLetter := True;
        Break;
      end;
    if not HasLetter then
      ValueStr := Copy(ValueStr, 1, Length(ValueStr) - 1);  // Strip 'b'
  end;

  // Check if it contains any letter (potential symbol) BEFORE stripping underscores
  // Underscore is valid in symbol names, only strip from numeric values
  HasLetter := False;
  for i := 1 to Length(ValueStr) do
  begin
    if ValueStr[i] in ['A'..'Z', 'a'..'z', '_'] then
    begin
      // For hex values, A-F are valid digits (but underscore is not)
      if IsHex and (UpCase(ValueStr[i]) in ['A'..'F']) then
        Continue;
      HasLetter := True;
      Break;
    end;
  end;

  if HasLetter then
  begin
    // It's a symbol reference - keep underscores in symbol name
    Result.IsSymbol := True;
    if Result.IsSigned then
    begin
      Result.SymbolName := '-' + ValueStr;  // Restore negation for expression evaluator
      Result.IsSigned := False;             // Expression evaluator owns negation now
    end
    else
      Result.SymbolName := ValueStr;
    Result.Value := 0;
  end
  else
  begin
    // Numeric value - remove underscores (K16 style visual separators like $20_0000)
    ValueStr := StringReplace(ValueStr, '_', '', [rfReplaceAll]);

    // Parse as numeric value
    if IsHex then
    begin
      if TryStrToInt('$' + ValueStr, TempValue) then
        Result.Value := UInt32(TempValue)
      else
        Result.Value := 0;
    end
    else
    begin
      if TryStrToInt(ValueStr, TempValue) then
        Result.Value := UInt32(TempValue)
      else
        Result.Value := 0;
    end;

    // Apply word suffix multiplier
    if IsWordSuffix then
      Result.Value := Result.Value * 2;

    // Apply negation
    if Result.IsSigned then
      Result.Value := UInt32(-Integer(Result.Value));
  end;
end;

function TImmediateValue.IsValid5Bit: Boolean;
begin
  // Unsigned 5-bit: 0-31
  Result := (Value <= 31) and not IsSigned and not IsSymbol;
end;

function TImmediateValue.IsValid8Bit: Boolean;
begin
  // Unsigned 8-bit: 0-255
  Result := (Value <= 255) and not IsSigned and not IsSymbol;
end;

function TImmediateValue.IsValid5BitSigned: Boolean;
var
  SignedVal: Integer;
begin
  // Signed 5-bit: -16 to +15
  if not IsSigned then
    SignedVal := Integer(Value)
  else
    SignedVal := -Integer(Value);

  Result := (SignedVal >= -16) and (SignedVal <= 15) and not IsSymbol;
end;

function TImmediateValue.ToSigned5Bit: ShortInt;
begin
  // Convert to signed 5-bit value
  if IsSigned then
    Result := -ShortInt(Value and $1F)
  else
    Result := ShortInt(Value and $1F);
end;

function TImmediateValue.IsValid8BitSigned: Boolean;
var
  SignedVal: Integer;
begin
  // Signed 8-bit: -128 to +127
  if not IsSigned then
    SignedVal := Integer(Value)
  else
    SignedVal := -Integer(Value);

  Result := (SignedVal >= -128) and (SignedVal <= 127) and not IsSymbol;
end;

function TImmediateValue.ToSigned8Bit: ShortInt;
begin
  // Convert to signed 8-bit value
  if IsSigned then
    Result := -ShortInt(Value and $FF)
  else
    Result := ShortInt(Value and $FF);
end;

// TMemoryRef
class function TMemoryRef.Parse(const Token: string): TMemoryRef;
var
  Inner, RegPart, OffsetPart: string;
  PlusPos, MinusPos, SplitPos: Integer;
  OffsetValue: Integer;
  IsSymbolic: Boolean;
  i: Integer;
  CloseBracket: Integer;
  IsWordSuffix: Boolean;
  UpperOffset: string;
begin
  Result.BaseReg := '';
  Result.Offset := 0;
  Result.HasOffset := False;
  Result.OffsetRegister := '';
  Result.HasRegisterOffset := False;
  Result.OffsetSymbol := '';
  Result.HasSymbolOffset := False;

  // Check for correct format
  if (Length(Token) < 2) or (Token[1] <> '[') then Exit;

  // Find the closing bracket
  CloseBracket := Pos(']', Token);
  if CloseBracket = 0 then Exit;

  // Extract content between brackets
  Inner := Trim(Copy(Token, 2, CloseBracket - 2));
  if Inner = '' then Exit;

  // Look for + or - (offset separator)
  PlusPos := Pos('+', Inner);
  MinusPos := Pos('-', Inner);

  if PlusPos > 0 then
    SplitPos := PlusPos
  else if MinusPos > 0 then
    SplitPos := MinusPos
  else
    SplitPos := 0;

  if SplitPos > 0 then
  begin
    // Has offset
    RegPart := Trim(Copy(Inner, 1, SplitPos - 1));
    OffsetPart := Trim(Copy(Inner, SplitPos + 1, MaxInt));

    // Check if offset is negative
    if MinusPos > 0 then
    begin
      // Negative offset - negate after parsing
    end;

    Result.BaseReg := UpperCase(RegPart);
    Result.HasOffset := True;

    // Check if offset starts with # (immediate)
    if (Length(OffsetPart) > 0) and (OffsetPart[1] = '#') then
    begin
      OffsetPart := Copy(OffsetPart, 2, MaxInt); // Remove #

      // Check for 'w' suffix (word count)
      IsWordSuffix := False;
      if (Length(OffsetPart) > 0) and (OffsetPart[Length(OffsetPart)] in ['w', 'W']) then
      begin
        IsWordSuffix := True;
        OffsetPart := Copy(OffsetPart, 1, Length(OffsetPart) - 1);
      end;

      // Check if it's a symbol or numeric
      IsSymbolic := False;
      for i := 1 to Length(OffsetPart) do
      begin
        if OffsetPart[i] in ['A'..'Z', 'a'..'z', '_'] then
        begin
          // Check if it might be hex
          if (Length(OffsetPart) > 1) and (OffsetPart[1] = '$') then
          begin
            if UpCase(OffsetPart[i]) in ['A'..'F'] then
              Continue;
          end;
          IsSymbolic := True;
          Break;
        end;
      end;

      if IsSymbolic then
      begin
        Result.HasSymbolOffset := True;
        Result.OffsetSymbol := OffsetPart;
        if IsWordSuffix then
          Result.OffsetSymbol := Result.OffsetSymbol + 'w'; // Preserve suffix for evaluator
      end
      else
      begin
        // Parse as number
        if (Length(OffsetPart) > 0) and (OffsetPart[1] = '$') then
        begin
          OffsetPart := StringReplace(OffsetPart, '_', '', [rfReplaceAll]);
          TryStrToInt(OffsetPart, OffsetValue);
        end
        else
        begin
          OffsetPart := StringReplace(OffsetPart, '_', '', [rfReplaceAll]);
          TryStrToInt(OffsetPart, OffsetValue);
        end;

        if IsWordSuffix then
          OffsetValue := OffsetValue * 2;

        Result.Offset := OffsetValue;
      end;

      // Apply negative sign if needed
      if MinusPos > 0 then
      begin
        if not Result.HasSymbolOffset then
          Result.Offset := -Result.Offset;
      end;
    end
    else
    begin
      // Check if it's a register offset (D0-D3 only)
      UpperOffset := UpperCase(OffsetPart);
      if (Length(UpperOffset) = 2) and (UpperOffset[1] = 'D') and
         (UpperOffset[2] in ['0'..'3']) then
      begin
        Result.HasRegisterOffset := True;
        Result.OffsetRegister := UpperOffset;
      end
      else if (Length(UpperOffset) >= 2) and
              ((UpperOffset[1] = 'X') or (UpperOffset[1] = 'Y')) and
              (UpperOffset[2] in ['0'..'3']) then
      begin
        // X/Y registers are not valid index registers — silently encoding as Dn
        // would produce wrong results.  Record an error via the offset symbol
        // field so callers can detect this; the assembler will emit a proper error.
        Result.HasRegisterOffset := True;
        Result.OffsetRegister    := 'D' + UpperOffset[2];  // placeholder
        Result.HasSymbolOffset   := True;
        Result.OffsetSymbol      := '__ERR_XYREG_INDEX:' + UpperOffset;  // sentinel
      end
      else
      begin
        // Check for bare symbol name (no # prefix) e.g. [PC+label]
        IsSymbolic := False;
        for i := 1 to Length(OffsetPart) do
          if OffsetPart[i] in ['A'..'Z', 'a'..'z', '_'] then
          begin
            IsSymbolic := True;
            Break;
          end;

        if IsSymbolic then
        begin
          Result.HasSymbolOffset := True;
          Result.OffsetSymbol := OffsetPart;
        end
        else
        begin
          // Plain numeric offset without # — e.g. [XY0+4]
          OffsetPart := StringReplace(OffsetPart, '_', '', [rfReplaceAll]);
          if TryStrToInt(OffsetPart, OffsetValue) then
            Result.Offset := OffsetValue;
        end;
      end;
    end;
  end
  else
  begin
    // No offset - just register
    Result.BaseReg := UpperCase(Inner);
  end;
end;

function TMemoryRef.IsValid: Boolean;
begin
  // Check if base register is a valid XY pair
  Result := (BaseReg = 'XY0') or (BaseReg = 'XY1') or
            (BaseReg = 'XY2') or (BaseReg = 'XY3');
end;

// TInstructionRecord
procedure TInstructionRecord.Clear;
begin
  SourceLine := '';
  LineNumber := 0;
  LabelName := '';
  Mnemonic := '';
  CanonicalMnemonic := '';
  SetLength(Operands, 0);
  Mode := amRegReg;
  // Registers: zero-fill leaves Number=0/RegType=rtData, which IsValid reports
  // as TRUE (indistinguishable from D0). Must use sentinel Number=255 so that
  // encoders checking IsValid can tell "unset" from "D0". See NEG single-operand
  // bug — without this, NEG D1 encoded src=D0.
  FillChar(Destination, SizeOf(Destination), 0);
  Destination.Number := 255;
  FillChar(SourceA, SizeOf(SourceA), 0);
  SourceA.Number := 255;
  FillChar(SourceB, SizeOf(SourceB), 0);
  SourceB.Number := 255;
  FillChar(Immediate, SizeOf(Immediate), 0);
  FillChar(MemoryRef, SizeOf(MemoryRef), 0);
  Address := 0;
end;

function TInstructionRecord.IsValid: Boolean;
begin
  Result := Mnemonic <> '';
end;

function TInstructionRecord.GetOperandCount: Integer;
begin
  Result := Length(Operands);
end;

// TK16Parser
constructor TK16Parser.Create;
begin
  inherited;
  FErrorList := TStringList.Create;
  FCurrentLine := 0;
end;

destructor TK16Parser.Destroy;
begin
  FErrorList.Free;
  inherited;
end;

function TK16Parser.CleanLine(const Line: string): string;
var
  CommentPos, i: Integer;
  InQuote: Boolean;
  QuoteChar: Char;
  BackslashCount: Integer;
  j: Integer;
begin
  Result := Line;

  // Find semicolon outside of quoted strings
  InQuote := False;
  QuoteChar := #0;
  CommentPos := 0;

  for i := 1 to Length(Result) do
  begin
    // Track quote state
    if not InQuote and ((Result[i] = '''') or (Result[i] = '"')) then
    begin
      InQuote := True;
      QuoteChar := Result[i];
    end
    else if InQuote and (Result[i] = QuoteChar) then
    begin
      // Check if quote is escaped by counting preceding backslashes
      BackslashCount := 0;
      j := i - 1;
      while (j >= 1) and (Result[j] = '\') do
      begin
        Inc(BackslashCount);
        Dec(j);
      end;

      if (BackslashCount mod 2) = 1 then
        Continue  // Odd number of backslashes = escaped quote
      else
        InQuote := False;
    end
    else if (Result[i] = ';') and not InQuote then
    begin
      CommentPos := i;
      Break;
    end;
  end;

  if CommentPos > 0 then
    Result := Copy(Result, 1, CommentPos - 1);

  Result := Trim(Result);
end;

function TK16Parser.ExtractLabel(var Line: string): string;
var
  ColonPos, i: Integer;
  InQuote: Boolean;
  QuoteChar: Char;
  BackslashCount: Integer;
  j: Integer;
begin
  Result := '';
  ColonPos := 0;
  InQuote := False;
  QuoteChar := #0;

  for i := 1 to Length(Line) do
  begin
    // Track quote state
    if not InQuote and ((Line[i] = '''') or (Line[i] = '"')) then
    begin
      InQuote := True;
      QuoteChar := Line[i];
    end
    else if InQuote and (Line[i] = QuoteChar) then
    begin
      // Check if quote is escaped
      BackslashCount := 0;
      j := i - 1;
      while (j >= 1) and (Line[j] = '\') do
      begin
        Inc(BackslashCount);
        Dec(j);
      end;

      if (BackslashCount mod 2) = 1 then
        Continue  // Odd number of backslashes = escaped quote
      else
      begin
        InQuote := False;
        QuoteChar := #0;
      end;
    end
    // Found colon outside quotes
    else if (Line[i] = ':') and not InQuote then
    begin
      ColonPos := i;
      Break;
    end;
  end;

  if ColonPos > 0 then
  begin
    Result := Trim(Copy(Line, 1, ColonPos - 1));
    Line := Trim(Copy(Line, ColonPos + 1, MaxInt));
  end;
end;

function TK16Parser.SplitOperands(const OpStr: string): TArray<string>;
var
  Parts: TList<string>;
  CurrentPart: string;
  i: Integer;
  InQuote: Boolean;
  QuoteChar: Char;
  BackslashCount: Integer;
  BracketDepth: Integer;
  j: Integer;
begin
  Parts := TList<string>.Create;
  try
    CurrentPart := '';
    InQuote := False;
    QuoteChar := #0;
    BracketDepth := 0;

    for i := 1 to Length(OpStr) do
    begin
      // Track bracket depth (outside quotes)
      if not InQuote then
      begin
        if OpStr[i] = '[' then
          Inc(BracketDepth)
        else if OpStr[i] = ']' then
          Dec(BracketDepth);
      end;

      // Track quote state
      if not InQuote and ((OpStr[i] = '''') or (OpStr[i] = '"')) then
      begin
        InQuote := True;
        QuoteChar := OpStr[i];
        CurrentPart := CurrentPart + OpStr[i];
      end
      else if InQuote and (OpStr[i] = QuoteChar) then
      begin
        // Check if quote is escaped by counting preceding backslashes
        BackslashCount := 0;
        j := Length(CurrentPart);
        while (j >= 1) and (CurrentPart[j] = '\') do
        begin
          Inc(BackslashCount);
          Dec(j);
        end;

        if (BackslashCount mod 2) = 1 then
        begin
          // Odd number of backslashes = escaped quote
          CurrentPart := CurrentPart + OpStr[i];
        end
        else
        begin
          // Not escaped - end of quote
          InQuote := False;
          QuoteChar := #0;
          CurrentPart := CurrentPart + OpStr[i];
        end;
      end
      // Split on comma only if outside quotes AND outside brackets
      else if (OpStr[i] = ',') and not InQuote and (BracketDepth = 0) then
      begin
        Parts.Add(Trim(CurrentPart));
        CurrentPart := '';
      end
      else
      begin
        CurrentPart := CurrentPart + OpStr[i];
      end;
    end;

    // Add the last part if not empty
    if CurrentPart <> '' then
      Parts.Add(Trim(CurrentPart));

    Result := Parts.ToArray;
  finally
    Parts.Free;
  end;
end;

function TK16Parser.IsBranchInstruction(const Mnemonic: string): Boolean;
var
  BaseMnemonic: string;
begin
  BaseMnemonic := GetBaseBranchMnemonic(Mnemonic);

  Result := SameText(BaseMnemonic, 'BEQ') or SameText(BaseMnemonic, 'BNE') or
            SameText(BaseMnemonic, 'BCS') or SameText(BaseMnemonic, 'BCC') or
            SameText(BaseMnemonic, 'BHS') or SameText(BaseMnemonic, 'BLO') or
            SameText(BaseMnemonic, 'BLT') or SameText(BaseMnemonic, 'BGT') or
            SameText(BaseMnemonic, 'BGE') or SameText(BaseMnemonic, 'BLE') or
            SameText(BaseMnemonic, 'BRA') or SameText(BaseMnemonic, 'BRANCH');
end;

function TK16Parser.GetBaseBranchMnemonic(const Mnemonic: string): string;
begin
  // Strip .S or .L suffix to get base mnemonic
  Result := Mnemonic;
  if Result.EndsWith('.S') or Result.EndsWith('.L') then
    Result := Copy(Result, 1, Length(Result) - 2);
end;

function TK16Parser.IsALUInstruction(const Mnemonic: string): Boolean;
begin
  Result := SameText(Mnemonic, 'ADD') or SameText(Mnemonic, 'ADC') or
            SameText(Mnemonic, 'SUB') or SameText(Mnemonic, 'SBC') or
            SameText(Mnemonic, 'AND') or SameText(Mnemonic, 'OR') or
            SameText(Mnemonic, 'XOR') or SameText(Mnemonic, 'NOT');
end;

function TK16Parser.IsNEGInstruction(const Mnemonic: string): Boolean;
begin
  Result := SameText(Mnemonic, 'NEG');
end;

function TK16Parser.IsSccInstruction(const Mnemonic: string): Boolean;
var
  Upper: string;
begin
  Upper := UpperCase(Mnemonic);
  Result := (Upper = 'SEQ') or (Upper = 'SNE') or
            (Upper = 'SCS') or (Upper = 'SCC') or
            (Upper = 'SHS') or (Upper = 'SLO') or
            (Upper = 'SLT') or (Upper = 'SGT') or
            (Upper = 'SGE') or (Upper = 'SLE');
end;

function TK16Parser.IsDirective(const Token: string): Boolean;
begin
  Result := AnsiIndexText(Token, ['.EQU', '.ORG', '.BASE', '.WORD',
                                   '.BYTE', '.TEXT', '.ALIGN', '.DS',
                                   '.INCLUDE']) >= 0;
end;

function TK16Parser.DetermineAddressingMode(const {%H-}Mnemonic: string; const Operands: TArray<string>): TAddressingMode;
var
  LastOp: string;
begin
  // Mnemonic reserved for future use; detailed mode analysis happens in the encoder
  Result := amRegReg; // Safe default

  if Length(Operands) = 0 then Exit;

  LastOp := Operands[Length(Operands) - 1];

  // Basic categorization
  if (Length(LastOp) > 0) and (LastOp[1] = '#') then
    Result := amImm16    // Default immediate, encoder refines to amImm5/amImm8
  else if (Length(LastOp) > 0) and (LastOp[1] = '[') then
    Result := amMemory   // Default memory, encoder refines to amIndexed/amPCRel
  else if LastOp.StartsWith('PCH+#') then
    Result := amPCHImm16
  else
    Result := amRegReg;
end;

  // Helper function to find a character outside of quoted strings
  function FindOutsideQuotes(const Str: string; Ch: Char): Integer;
  var
    i: Integer;
    InQuote: Boolean;
    QuoteChar: Char;
    BackslashCount: Integer;
    j: Integer;
  begin
    Result := 0;
    InQuote := False;
    QuoteChar := #0;

    for i := 1 to Length(Str) do
    begin
      // Track quote state
      if not InQuote and ((Str[i] = '''') or (Str[i] = '"')) then
      begin
        InQuote := True;
        QuoteChar := Str[i];
      end
      else if InQuote and (Str[i] = QuoteChar) then
      begin
        // Check if quote is escaped by counting preceding backslashes
        BackslashCount := 0;
        j := i - 1;
        while (j >= 1) and (Str[j] = '\') do
        begin
          Inc(BackslashCount);
          Dec(j);
        end;

        if (BackslashCount mod 2) = 1 then
          Continue  // Odd number of backslashes = escaped quote
        else
        begin
          InQuote := False;
          QuoteChar := #0;
        end;
      end
      // Found target character outside quotes
      else if (Str[i] = Ch) and not InQuote then
      begin
        Result := i;
        Exit;
      end;
    end;
  end;

function TK16Parser.ParseLine(const Line: string; LineNumber: Integer): TInstructionRecord;
var
  CleanedLine: string;
  SpacePos, EqualPos: Integer;
  InstrPart, OperandPart: string;
  SecondSpacePos: Integer;
  DirectivePart: string;
  i: Integer;
  ImmStr: string;
begin
  FCurrentLine := LineNumber;
  Result.Clear;
  Result.SourceLine := Line;
  Result.LineNumber := LineNumber;

  CleanedLine := CleanLine(Line);

  if CleanedLine = '' then
    Exit;

  Result.LabelName := ExtractLabel(CleanedLine);

  if CleanedLine = '' then
    Exit;

  // Handle SYMBOL = VALUE syntax (shorthand for .EQU)
  EqualPos := FindOutsideQuotes(CleanedLine, '=');
  if (EqualPos > 0) and (Result.LabelName = '') then
  begin
    Result.Mnemonic := '.EQU';
    SetLength(Result.Operands, 2);
    Result.Operands[0] := Trim(Copy(CleanedLine, 1, EqualPos - 1));
    Result.Operands[1] := Trim(Copy(CleanedLine, EqualPos + 1, MaxInt));
    Exit;
  end;

  // Split into first token and rest (handle both spaces and tabs)
  SpacePos := 0;
  for i := 1 to Length(CleanedLine) do
  begin
    if CharInSet(CleanedLine[i], [' ', #9]) then
    begin
      SpacePos := i;
      Break;
    end;
  end;

  if SpacePos > 0 then
  begin
    InstrPart := Trim(Copy(CleanedLine, 1, SpacePos - 1));
    OperandPart := Trim(Copy(CleanedLine, SpacePos + 1, MaxInt));
  end else
  begin
    InstrPart := CleanedLine;
    OperandPart := '';
  end;

  // =========================================================================
  // NEW FORMAT SUPPORT: SYMBOL .DIRECTIVE VALUE
  // Check if first token is NOT a directive but operand part STARTS with one
  // Examples:
  //   ROM_BASE .EQU $F00000       -> .EQU ROM_BASE, $F00000
  //   BUFFER   .WORD $0000        -> .WORD with label BUFFER
  // =========================================================================
  if (not InstrPart.StartsWith('.')) and (OperandPart <> '') then
  begin
    // Check if operand part starts with a directive
    SecondSpacePos := 0;
    for i := 1 to Length(OperandPart) do
    begin
      if CharInSet(OperandPart[i], [' ', #9]) then
      begin
        SecondSpacePos := i;
        Break;
      end;
    end;

    if SecondSpacePos > 0 then
      DirectivePart := UpperCase(Trim(Copy(OperandPart, 1, SecondSpacePos - 1)))
    else
      DirectivePart := UpperCase(OperandPart);

    if IsDirective(DirectivePart) then
    begin
      // New format detected: SYMBOL .DIRECTIVE VALUE
      if SameText(DirectivePart, '.EQU') then
      begin
        // SYMBOL .EQU VALUE -> Mnemonic=.EQU, Operands[0]=SYMBOL, Operands[1]=VALUE
        Result.Mnemonic := '.EQU';
        SetLength(Result.Operands, 2);
        Result.Operands[0] := InstrPart;  // Symbol name
        if SecondSpacePos > 0 then
          Result.Operands[1] := Trim(Copy(OperandPart, SecondSpacePos + 1, MaxInt))
        else
          Result.Operands[1] := '';  // Error: no value
        Exit;
      end
      else if SameText(DirectivePart, '.ORG') or SameText(DirectivePart, '.BASE') then
      begin
        // For .ORG/.BASE, the symbol before becomes a label at that address
        // Actually, .ORG SYMBOL doesn't make sense with symbol first
        // Treat SYMBOL .ORG as: label SYMBOL at .ORG address
        // But typically you don't write: RESET .ORG $FF0000
        // More likely this is just .ORG with a symbol value
        // So fall through to normal processing
      end
      else if SameText(DirectivePart, '.WORD') or SameText(DirectivePart, '.BYTE') or
              SameText(DirectivePart, '.TEXT') then
      begin
        // SYMBOL .WORD value -> Label at this address, then .WORD data
        // The symbol becomes a label (already in Result.LabelName? No, it's in InstrPart)
        // Set it as label and process directive
        if Result.LabelName = '' then
          Result.LabelName := InstrPart;
        Result.Mnemonic := DirectivePart;
        if SecondSpacePos > 0 then
          Result.Operands := SplitOperands(Trim(Copy(OperandPart, SecondSpacePos + 1, MaxInt)))
        else
          SetLength(Result.Operands, 0);
        Exit;
      end;
    end;
  end;

  // Standard format: directive/instruction first
  Result.Mnemonic := UpperCase(InstrPart);

  if OperandPart <> '' then
    Result.Operands := SplitOperands(OperandPart);

  // =========================================================================
  // Handle directives - exit early, assembler processes these
  // =========================================================================
  if Result.Mnemonic.StartsWith('.') then
  begin
    // Directives are passed to assembler as-is
    // .EQU SYMBOL, VALUE  ->  Operands[0]=SYMBOL, Operands[1]=VALUE (with comma stripped)
    // .ORG ADDRESS        ->  Operands[0]=ADDRESS
    // .WORD val1, val2    ->  Operands[0]=val1, Operands[1]=val2
    // .TEXT "string"      ->  Operands[0]="string"
    // .BASE ADDRESS       ->  Operands[0]=ADDRESS
    Exit;  // Don't validate as instruction
  end;

  Result.Mode := DetermineAddressingMode(Result.Mnemonic, Result.Operands);

  // Handle control instructions (NOP, HALT) with T8 support
  if SameText(Result.Mnemonic, 'NOP') then
  begin
    if Length(Result.Operands) = 0 then
    begin
      // Simple NOP - T8 = 0
      Result.Mode := amRegReg; // Default mode, encoder handles it
    end
    else if Length(Result.Operands) = 1 then
    begin
      // NOP with T8 value: NOP #$FF, NOP #DebugMarker
      if (Length(Result.Operands[0]) > 0) and (Result.Operands[0][1] = '#') then
      begin
        Result.Immediate := TImmediateValue.Parse(Result.Operands[0]);
        Result.Mode := amImm8; // 8-bit immediate for T8
      end
      else
      begin
        AddError('NOP operand must be immediate value: NOP #value');
      end;
    end
    else
    begin
      AddError('NOP accepts 0 or 1 operand: NOP [#t8_value]');
    end;
  end
  // Handle HALT instruction with T8 support
  else if SameText(Result.Mnemonic, 'HALT') then
  begin
    if Length(Result.Operands) = 0 then
    begin
      // Simple HALT - T8 = 0
      Result.Mode := amRegReg; // Default mode, encoder handles it
    end
    else if Length(Result.Operands) = 1 then
    begin
      // HALT with T8 value (exit code, error status, etc.): HALT #0, HALT #$FF
      if (Length(Result.Operands[0]) > 0) and (Result.Operands[0][1] = '#') then
      begin
        Result.Immediate := TImmediateValue.Parse(Result.Operands[0]);
        Result.Mode := amImm8; // 8-bit immediate for T8
      end
      else
      begin
        AddError('HALT operand must be immediate value: HALT #value');
      end;
    end
    else
    begin
      AddError('HALT accepts 0 or 1 operand: HALT [#t8_value]');
    end;
  end
  // ========================================
  // INC / DEC — bare XYn form requires explicit step
  // ========================================
  else if SameText(Result.Mnemonic, 'INC') or SameText(Result.Mnemonic, 'DEC') then
  begin
    if (Length(Result.Operands) = 1) and
       (Length(Result.Operands[0]) >= 2) and
       SameText(Copy(Result.Operands[0], 1, 2), 'XY') then
    begin
      AddError(Format('%s XYn requires explicit step: use #Nb (byte) or #Nw (word)',
                      [Result.Mnemonic]));
      Result.Mode := amRegReg;  { fallback }
    end;
    { all other INC/DEC forms (register, or XYn with step) pass through to encoder }
  end
  // ========================================
  // Handle all ALU instructions (ADD, ADC, SUB, SBC, AND, OR, XOR, NOT)
  // NEW: 2-operand format: dest = dest op source
  // ========================================
  else if IsALUInstruction(Result.Mnemonic) then
  begin
    if (Length(Result.Operands) = 1) and SameText(Result.Mnemonic, 'NOT') then
    begin
      // 1-operand form: NOT dest  (in-place, Mode 10)
      Result.Destination := TRegister.Parse(Result.Operands[0]);
      Result.Mode := amImm5;  // Mode 10: NOT dst -> dst
    end
    else if Length(Result.Operands) = 2 then
    begin
      // 2-operand form: dest = dest op source
      Result.Destination := TRegister.Parse(Result.Operands[0]);

      // Check second operand type
      if (Length(Result.Operands[1]) > 0) and (Result.Operands[1][1] = '#') then
      begin
        // Immediate value
        Result.Immediate := TImmediateValue.Parse(Result.Operands[1]);
        if Result.Immediate.IsValid5Bit and not Result.Immediate.IsSymbol then
          Result.Mode := amImm5    // Mode 10
        else
          Result.Mode := amImm16;  // Mode 11
      end
      else if (Length(Result.Operands[1]) > 0) and (Result.Operands[1][1] = '[') then
      begin
        // Memory reference [XY] — offset forms not supported for ALU instructions
        Result.MemoryRef := TMemoryRef.Parse(Result.Operands[1]);
        if Result.MemoryRef.BaseReg = '' then
        begin
          if Pos(',', Result.Operands[1]) > 0 then
            AddError(Format('Invalid memory syntax: use [XY+#offset] not [XY, #offset]. Got: %s',
              [Result.Operands[1]]))
          else
            AddError(Format('Invalid memory reference: %s', [Result.Operands[1]]));
          Result.Mode := amRegReg;  { fallback — suppress encoder errors }
        end
        else if Result.MemoryRef.HasOffset or Result.MemoryRef.HasRegisterOffset then
        begin
          AddError(Format('%s: [XY+offset] not valid — use LOADD/LOADB first', [Result.Mnemonic]));
          Result.Mode := amRegReg;  { fallback — suppress encoder errors }
        end
        else
          Result.Mode := amRegMem;  { Mode 01 }
      end
      else
      begin
        // Register source
        Result.SourceA := TRegister.Parse(Result.Operands[1]);
        if not Result.SourceA.IsValid then
          AddError(Format('Invalid source register: %s', [Result.Operands[1]]))
        else
          Result.Mode := amRegReg;  // Mode 00
      end;
    end
    else
    begin
      AddError(Format('%s requires 2 operands: %s dest, source', [Result.Mnemonic, Result.Mnemonic]));
    end;
  end
  // Handle NEG instruction (opcode $00 mode 11)
  // NEG dst       — in-place: dst <- -dst
  // NEG dst, src  — two operand: dst <- -src
  else if IsNEGInstruction(Result.Mnemonic) then
  begin
    if Length(Result.Operands) = 1 then
    begin
      // NEG dst  (in-place, src = dst)
      Result.Destination := TRegister.Parse(Result.Operands[0]);
      if not Result.Destination.IsValid then
        AddError(Format('NEG: invalid destination register: %s', [Result.Operands[0]]));
      Result.Mode := amRegReg;  // encoder sets src = dst
    end
    else if Length(Result.Operands) = 2 then
    begin
      // NEG dst, src
      Result.Destination := TRegister.Parse(Result.Operands[0]);
      if not Result.Destination.IsValid then
        AddError(Format('NEG: invalid destination register: %s', [Result.Operands[0]]));
      Result.SourceA := TRegister.Parse(Result.Operands[1]);
      if not Result.SourceA.IsValid then
        AddError(Format('NEG: invalid source register: %s', [Result.Operands[1]]));
      Result.Mode := amRegReg;
    end
    else
      AddError('NEG requires 1 or 2 operands: NEG dst or NEG dst, src');
  end
  // Handle CMP instruction
  else if SameText(Result.Mnemonic, 'CMP') then
  begin
    if Length(Result.Operands) = 2 then
    begin
      Result.Destination := TRegister.Parse(Result.Operands[0]);

      // Check second operand type
      if (Length(Result.Operands[1]) > 0) and (Result.Operands[1][1] = '#') then
      begin
        // Immediate value
        Result.Immediate := TImmediateValue.Parse(Result.Operands[1]);
        if Result.Immediate.IsValid5Bit and not Result.Immediate.IsSymbol then
          Result.Mode := amImm5
        else
          Result.Mode := amImm16;
      end
      else if (Length(Result.Operands[1]) > 0) and (Result.Operands[1][1] = '[') then
      begin
        // Memory reference [XY] — offset forms not supported for CMP
        Result.MemoryRef := TMemoryRef.Parse(Result.Operands[1]);
        if Result.MemoryRef.HasOffset or Result.MemoryRef.HasRegisterOffset then
        begin
          AddError('CMP: [XY+offset] not valid — use LOADD/LOADB first');
          Result.Mode := amRegReg;  { fallback — suppress encoder errors }
        end
        else
          Result.Mode := amRegMem;
      end
      else
      begin
        // Register source
        Result.SourceA := TRegister.Parse(Result.Operands[1]);
        Result.Mode := amRegReg;
      end;
    end
    else
    begin
      AddError('CMP requires 2 operands: CMP reg, source');
    end;
  end
  // Handle Scc (Conditional Set) instructions
  else if IsSccInstruction(Result.Mnemonic) then
  begin
    if Length(Result.Operands) = 1 then
    begin
      Result.Destination := TRegister.Parse(Result.Operands[0]);
      Result.Mode := amRegReg; // Encoder will handle the condition encoding
    end
    else
    begin
      AddError(Format('%s requires 1 operand: %s dest', [Result.Mnemonic, Result.Mnemonic]));
    end;
  end
  // =========================================================================
  // LOADXY - Load 24-bit XY pair from memory: LOADXY XYn, [XYm]
  // 2 operands: destination XY pair, source memory [XY]
  // =========================================================================
  else if SameText(Result.Mnemonic, 'LOADXY') then
  begin
    if Length(Result.Operands) = 2 then
    begin
      // Encoder handles XY pair parsing
      Result.Mode := amMemory;
    end
    else
    begin
      AddError('LOADXY requires exactly 2 operands: LOADXY XYn, [XYm]');
    end;
  end
  // =========================================================================
  // STOREXY - Store XY pair: STOREXY XYn, [XYm]
  // 2 operands: source XY pair, destination memory [XY]
  // =========================================================================
  else if SameText(Result.Mnemonic, 'STOREXY') then
  begin
    if Length(Result.Operands) = 2 then
    begin
      // Encoder handles XY pair parsing
      Result.Mode := amMemory;
    end
    else
    begin
      AddError('STOREXY requires exactly 2 operands: STOREXY XYn, [XYm]');
    end;
  end
  // Handle LOAD family instructions including LOADI and syntax sugar
  else if SameText(Result.Mnemonic, 'LOADD') or
     SameText(Result.Mnemonic, 'LOADB') or
     SameText(Result.Mnemonic, 'LOADX') or
     SameText(Result.Mnemonic, 'LOADY') or
     SameText(Result.Mnemonic, 'LOADI') or
     SameText(Result.Mnemonic, 'LOAD') then    // Syntax sugar
  begin
    if Length(Result.Operands) = 2 then
    begin
      Result.Destination := TRegister.Parse(Result.Operands[0]);

      // Check for PCH+# syntax FIRST
      if Result.Operands[1].StartsWith('PCH+#') then
      begin
        ImmStr := Copy(Result.Operands[1], 5, MaxInt);
        Result.Immediate := TImmediateValue.Parse(ImmStr);
        Result.Mode := amPCHImm16;
      end
      // Check for regular immediate
      else if (Length(Result.Operands[1]) > 0) and (Result.Operands[1][1] = '#') then
      begin
        Result.Immediate := TImmediateValue.Parse(Result.Operands[1]);
        // Let encoder determine if IMM5 or IMM16
        if Result.Immediate.IsValid5Bit then
          Result.Mode := amImm5
        else
          Result.Mode := amImm16;
      end
      // Check for memory reference
      else if (Length(Result.Operands[1]) > 0) and (Result.Operands[1][1] = '[') then
      begin
        Result.MemoryRef := TMemoryRef.Parse(Result.Operands[1]);
        // Check for invalid comma syntax
        if Result.MemoryRef.BaseReg = '' then
        begin
          if Pos(',', Result.Operands[1]) > 0 then
            AddError(Format('Invalid memory syntax: use [XY+#offset] not [XY, #offset]. Got: %s',
              [Result.Operands[1]]))
          else
            AddError(Format('Invalid memory reference: %s', [Result.Operands[1]]));
        end
        else
        begin
          // Let encoder determine specific memory mode
          Result.Mode := amMemory;
        end;
      end
      else
      begin
        // Invalid operand for LOAD
        AddError(Format('Invalid operand for %s: %s', [Result.Mnemonic, Result.Operands[1]]));
      end;
    end
    else
    begin
      AddError(Format('%s requires exactly 2 operands', [Result.Mnemonic]));
    end;
  end
  // Handle branch instructions (UPDATED for T8-5/T16W architecture)
  else if IsBranchInstruction(Result.Mnemonic) then
  begin
    if Length(Result.Operands) < 1 then
    begin
      AddError(Format('%s requires at least 1 operand (target)', [Result.Mnemonic]));
    end
    else
    begin
      // Parse target operand (label or immediate offset)
      if (Length(Result.Operands[0]) > 0) and (Result.Operands[0][1] = '#') then
      begin
        // Immediate relative byte offset: BEQ #offset, BEQ.S #offset, BEQ.L #offset
        Result.Immediate := TImmediateValue.Parse(Result.Operands[0]);

        // For immediate offsets, use amImm16 mode and let encoder decide T8-5 vs T16W
        Result.Mode := amImm16;
      end
      else
      begin
        // Label target: BEQ target_label, BEQ.S target_label, BEQ.L target_label
        // Use amRegReg as placeholder - encoder will calculate distance and choose mode
        Result.Mode := amRegReg;
      end;

      // Handle optional condition parameter for BRANCH instruction
      if SameText(GetBaseBranchMnemonic(Result.Mnemonic), 'BRANCH') then
      begin
        if Length(Result.Operands) > 2 then
        begin
          AddError('BRANCH accepts maximum 2 operands: BRANCH target [,condition]');
        end;
        // Second operand (condition) is handled by the encoder if present
      end
      else
      begin
        // Specific branch instructions (BEQ, BNE, etc.) take only 1 operand
        if Length(Result.Operands) > 1 then
        begin
          AddError(Format('%s accepts only 1 operand (target)', [Result.Mnemonic]));
        end;
      end;
    end;
  end;

  // RET #Nw — warn on stack cleanup N >= 5 words (emulator oscillation bug)
  // Compiler workaround: ADD X3, #N then plain RET
  if SameText(Result.Mnemonic, 'RET') and
     (Length(Result.Operands) = 1) and
     (Length(Result.Operands[0]) > 0) and
     (Result.Operands[0][1] = '#') then
  begin
    Result.Immediate := TImmediateValue.Parse(Result.Operands[0]);
    if (not Result.Immediate.IsSigned) and
       (not Result.Immediate.IsSymbol) and
       (Result.Immediate.Value >= 10) then   { #5w = 10 bytes }
      AddWarning('RET: cleanup >= 5w — emulator oscillation bug; use ADD X3, #N then RET');
  end;

  if not ValidateRegisterCombination(Result) then
    AddError(Format('Invalid register combination on line %d', [LineNumber]));

  if not ValidateImmediateRange(Result) then
    AddError(Format('Immediate value out of range on line %d', [LineNumber]));
end;

function TK16Parser.ValidateRegisterCombination(const Instr: TInstructionRecord): Boolean;
begin
  Result := True;

  // ALU instruction validation (new 2-operand format)
  if IsALUInstruction(Instr.Mnemonic) then
  begin
    // Destination must be D0-D3, X0-X3, or Y0-Y3
    if not (Instr.Destination.RegType in [rtData, rtIndexX, rtIndexY]) then
    begin
      AddError(Format('%s: destination must be D0-D3, X0-X3, or Y0-Y3', [Instr.Mnemonic]));
      Result := False;
    end;

    // Mode 00: Source can be any register (D, X, Y, ORDB, SR, PCH, PCL)
    if Instr.Mode = amRegReg then
    begin
      if not Instr.SourceA.IsValid then
      begin
        AddError(Format('%s Mode 00: invalid source register', [Instr.Mnemonic]));
        Result := False;
      end;
    end;

    // Mode 01: Memory reference must be valid XY pair
    if Instr.Mode = amRegMem then
    begin
      if not Instr.MemoryRef.IsValid then
      begin
        AddError(Format('%s Mode 01: memory source must be [XY0]-[XY3]', [Instr.Mnemonic]));
        Result := False;
      end;
    end;
  end;

  // CMP validation (similar to ALU but allows more source types)
  if SameText(Instr.Mnemonic, 'CMP') then
  begin
    // First operand (in Destination field) must be D/X/Y
    if not (Instr.Destination.RegType in [rtData, rtIndexX, rtIndexY]) then
    begin
      AddError('CMP: first operand must be D0-D3, X0-X3, or Y0-Y3');
      Result := False;
    end;
  end;

  // Scc validation
  if IsSccInstruction(Instr.Mnemonic) then
  begin
    // Destination must be D0-D3, X0-X3, or Y0-Y3
    if not (Instr.Destination.RegType in [rtData, rtIndexX, rtIndexY]) then
    begin
      AddError(Format('%s: destination must be D0-D3, X0-X3, or Y0-Y3', [Instr.Mnemonic]));
      Result := False;
    end;
  end;

  // Similar validation for LOAD/STORE instructions...
end;

function TK16Parser.ValidateImmediateRange(const Instr: TInstructionRecord): Boolean;
var
  BaseMnemonic: string;
begin
  Result := True;

  // Validate T8-5 range (unsigned 0-31)
  if (Instr.Mode = amImm5) and not Instr.Immediate.IsValid5Bit then
  begin
    AddError('T8-5 immediate out of range (0 to 31, unsigned)');
    Result := False;
  end;

  // Warn on negative immediate literals for ALU/CMP instructions
  // e.g. ADD D0, #-5 silently encodes $FFFB — use SUB for subtraction
  if Instr.Immediate.IsSigned and
     (IsALUInstruction(Instr.Mnemonic) or SameText(Instr.Mnemonic, 'CMP')) then
    AddWarning(Format('%s: negative immediate — use SUB/SBC for subtraction',
                      [Instr.Mnemonic]));

  // Validate branch instruction operand counts
  BaseMnemonic := GetBaseBranchMnemonic(Instr.Mnemonic);

  if SameText(BaseMnemonic, 'BEQ') or SameText(BaseMnemonic, 'BNE') or
     SameText(BaseMnemonic, 'BCS') or SameText(BaseMnemonic, 'BCC') or
     SameText(BaseMnemonic, 'BHS') or SameText(BaseMnemonic, 'BLO') or
     SameText(BaseMnemonic, 'BLT') or SameText(BaseMnemonic, 'BGT') or
     SameText(BaseMnemonic, 'BGE') or SameText(BaseMnemonic, 'BLE') or
     SameText(BaseMnemonic, 'BRA') then
  begin
    if Length(Instr.Operands) <> 1 then
    begin
      AddError(Format('%s requires exactly 1 operand (target)', [Instr.Mnemonic]));
      Result := False;
    end;
  end;

  if SameText(BaseMnemonic, 'BRANCH') then
  begin
    if (Length(Instr.Operands) < 1) or (Length(Instr.Operands) > 2) then
    begin
      AddError('BRANCH requires 1-2 operands: BRANCH target [,condition]');
      Result := False;
    end;
  end;
end;

procedure TK16Parser.AddError(const Msg: string);
begin
  FErrorList.Add(Format('Error line %d: %s', [FCurrentLine, Msg]));
end;

procedure TK16Parser.AddWarning(const Msg: string);
begin
  FErrorList.Add(Format('Warning line %d: %s', [FCurrentLine, Msg]));
end;

function TK16Parser.HasErrors: Boolean;
begin
  Result := FErrorList.Count > 0;
end;

function TK16Parser.GetErrors: TStringList;
begin
  Result := FErrorList;
end;

procedure TK16Parser.ClearErrors;
begin
  FErrorList.Clear;
end;

end.
