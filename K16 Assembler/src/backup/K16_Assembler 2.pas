{
  K16_Assembler.pas — K16 CPU Assembler

  Assembles K16 source code into machine code. Supports the full K16
  instruction set, assembler directives (.ORG, .BASE, .EQU, .WORD, .TEXT,
  .BYTE, .ALIGN, .DS, .INCLUDE), local labels, and expression evaluation.

  Two-pass assembly: FirstPass builds the symbol table and computes addresses;
  SecondPass encodes instructions and resolves forward references.

  Part of the K16 homebrew CPU project.
  https://github.com/paulkberger/K16-CPU

  License: MIT
}
unit K16_Assembler;

{$mode Delphi}

interface

uses
  SysUtils, Classes, Generics.Collections, Generics.Defaults,
  StrUtils, Math,

  K16_Parser,
  K16_Encoder_Base,
  K16_Encoder_Control,
  K16_Encoder_Lookup,
  K16_Encoder_IncDec,
  K16_Encoder_LEA,
  K16_Encoder_ConditionalSet,
  K16_Encoder_ALU,
  K16_Encoder_Load,
  K16_Encoder_Store,
  K16_Encoder_Jump,
  K16_Encoder_Compare,
  K16_Encoder_Branch,
  K16_Encoder_Move,
  K16_Encoder_Call,
  K16_Encoder_PushPop,
  K16_Encoder_Interrupt;

type
  // Symbol types
  TSymbolType = (stLabel, stConstant, stVariable);

  TK16MessageEvent = procedure(const Msg: string) of object;

  TLineInfo = record
    FileName:     string;
    OriginalLine: Integer;
  end;

  TSymbol = record
    Name:     string;
    Value:    UInt32;
    SymType:  TSymbolType;
    Defined:  Boolean;
    LineNumber: Integer;

    class function CreateLabel(const AName: string; AValue: UInt32; ALineNum: Integer): TSymbol; static;
    class function CreateConstant(const AName: string; AValue: UInt32; ALineNum: Integer): TSymbol; static;
  end;

  // Forward reference tracking
  TForwardRef = record
    SymbolName: string;
    Address:    UInt32;
    LineNumber: Integer;
    InstructionIndex: Integer;
  end;

  // Expression evaluator for arithmetic expressions
  TExpressionEvaluator = class
  private
    FExpression: string;
    FPos: Integer;
    FSymbols: TDictionary<string, TSymbol>;
    FErrorMsg: string;
    FHasError: Boolean;

    function CurrentChar: Char;
    procedure SkipWhitespace;
    procedure Advance;
    function ParseNumber: Int64;
    function ParseSymbol: Int64;
    function ParseFactor: Int64;    // Numbers, symbols, parentheses, unary minus
    function ParseTerm: Int64;      // * and /
    function ParseExpression: Int64; // + and -
  public
    constructor Create(ASymbols: TDictionary<string, TSymbol>);
    function Evaluate(const Expr: string): Int64;
    property HasError: Boolean read FHasError;
    property ErrorMsg: string read FErrorMsg;
  end;

  // Main assembler class
  TK16Assembler = class
  private
    FParser: TK16Parser;
    FSymbols: TDictionary<string, TSymbol>;
    FForwardRefs: TList<TForwardRef>;
    FInstructions: TList<TInstructionRecord>;
    FInstrScope: TStringList;   // parallel to FInstructions: global scope at each instruction
    FMachineCode: TList<TMachineCode>;
    FSourceLines: TStringList;
    FListingLines: TStringList;
    FErrorList: TStringList;
    FWarningList: TStringList;
    FOnMessage: TK16MessageEvent;
    FLineMap: array of TLineInfo;
    FAdditionalWords: TList<TMachineCode>;

    // Encoders
    FEncoders:          TList<IK16Encoder>;
    FALUEncoder:        TK16ALUEncoder;
    FLoadEncoder:       TK16LoadEncoder;
    FStoreEncoder:      TK16StoreEncoder;
    FControlEncoder:    TK16ControlEncoder;
    FJumpEncoder:       TK16JumpEncoder;
    FCompareEncoder:    TK16CompareEncoder;
    FBranchEncoder:     TK16BranchEncoder;
    FMoveEncoder:       TK16MoveEncoder;
    FJSREncoder:        TK16JSREncoder;
    FPushPopEncoder:    TK16PushPopEncoder;
    FLookupEncoder:     TK16LookupEncoder;
    FInterruptEncoder:  TK16InterruptEncoder;
    FSCCEncoder:        TK16SccEncoder;
    FIncDecEncoder:     TK16IncDecEncoder;
    FLEAEncoder:        TK16LeaEncoder;

    FCurrentAddress:  UInt32;
    FStartAddress:    UInt32;
    FEntryPoint:      UInt32;
    FBaseAddress:     UInt32;  // ROM base address for image generation
    FSourceDir:       string;  // Directory of main source file (for .INCLUDE)
    FSourceFileName:  string;  // Full path of main source file
    FCurrentGlobalLabel: string; // Current enclosing global label (for local labels)

    // Symbol resolver and error reporter functions
    function  SymbolResolver(const SymName: string; LineNumber: Integer): UInt32;
    procedure ErrorReporter(const Msg: string; LineNumber: Integer);
    procedure WarningReporter(const Msg: string; LineNumber: Integer);

    // Property getter
    function  GetHasErrors: Boolean;
    function  GetHasWarnings: Boolean;

    // Pass 1 - Symbol table building
    procedure FirstPass;
    procedure ProcessLabel(const LabelName: string; Address: UInt32; LineNumber: Integer);
    procedure ProcessDirective(const Instr: TInstructionRecord);
    function  CalculateInstructionSize(const Instr: TInstructionRecord): Integer;

    // Pass 2 - Code generation
    procedure SecondPass;
    function  ResolveSymbol(const SymName: string; LineNumber: Integer): Word;
    function  EncodeInstruction(const Instr: TInstructionRecord; InstrIndex: Integer): TMachineCode;
    procedure ResolveForwardReferences;
    function  FindEncoder(const Mnemonic: string): IK16Encoder;

    procedure MergeAdditionalWords;

    // Utilities
    procedure AddError(const Msg: string; LineNumber: Integer = 0);
    procedure AddWarning(const Msg: string; LineNumber: Integer = 0);
    procedure NotifyMessage(const Msg: string);
    function  IsInstruction(const Mnemonic: string): Boolean;
    function  IsDirective(const Mnemonic: string): Boolean;
    function  QualifyLabel(const RawLabel: string; LineNumber: Integer): string;
    procedure SetSourceFileName(const Value: string);
    procedure ExpandIncludes(Lines: TStringList; const CurrentDir: string;
                             Depth: Integer; OpenFiles: TStringList;
                             var LineMap: array of TLineInfo);

    function SignedWordToInteger(Value: Word): Integer ;
    function ParseTextString(const Input: string; LineNumber: Integer; out Bytes: TArray<Byte>): Boolean;
    function ExtractTextOperands(const SourceLine: string): string;
    function ExtractDirectiveContent(const SourceLine, DirectiveName: string): string;
    function EvalDirectiveArg(const ArgStr: string; LineNumber: Integer): Integer;

    function SupportsIMM5Mode(const Mnemonic: string): Boolean;

    // Dummy callbacks for CalculateInstructionSize (replaces anonymous methods)
    function  DummySizeSymbolResolver(const SymName: string; LineNumber: Integer): UInt32;
    function  ResolveScopedLabel(const UpperDotName: string; const DerivOp: Char; out Value: UInt32): Boolean;
    procedure DummySizeErrorReporter(const Msg: string; LineNumber: Integer);
    procedure DummySizeWarningReporter(const Msg: string; LineNumber: Integer);

  public
    constructor Create;
    destructor Destroy; override;

    // Main assembly process
    function AssembleFile(const Filename: string): Boolean;
    function AssembleText(const SourceText: string): Boolean;

    // Output generation
    procedure GenerateIntelHex(const Filename: string);
    procedure GenerateBinary(const Filename: string);
    procedure GenerateListing(const Filename: string);
    procedure GenerateSymbolTable(const Filename: string);
    function  GenerateListingText: string;

    // Properties
    property HasErrors: Boolean read GetHasErrors;
    property HasWarnings: Boolean read GetHasWarnings;
    property ErrorList: TStringList read FErrorList;
    property WarningList: TStringList read FWarningList;
    property OnMessage: TK16MessageEvent read FOnMessage write FOnMessage;
    property SourceLines: TStringList read FSourceLines;
    property Symbols: TDictionary<string, TSymbol> read FSymbols;
    property MachineCode: TList<TMachineCode> read FMachineCode;
    property Instructions: TList<TInstructionRecord> read FInstructions;
    property StartAddress: UInt32 read FStartAddress write FStartAddress;
    property EntryPoint: UInt32 read FEntryPoint write FEntryPoint;
    property BaseAddress: UInt32 read FBaseAddress write FBaseAddress;  // ROM base for image generation
    property SourceFileName: string read FSourceFileName write SetSourceFileName;
  end;

implementation

uses
  K16_Listing;

function JoinStrings(const Arr: TArray<string>; const Sep: string): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(Arr) do
  begin
    if i > 0 then Result := Result + Sep;
    Result := Result + Arr[i];
  end;
end;


{ TSymbol }

class function TSymbol.CreateLabel(const AName: string; AValue: UInt32; ALineNum: Integer): TSymbol;
begin
  Result.Name := UpperCase(AName);
  Result.Value := AValue;
  Result.SymType := stLabel;
  Result.Defined := True;
  Result.LineNumber := ALineNum;
end;

class function TSymbol.CreateConstant(const AName: string; AValue: UInt32; ALineNum: Integer): TSymbol;
begin
  Result.Name := UpperCase(AName);
  Result.Value := AValue;
  Result.SymType := stConstant;
  Result.Defined := True;
  Result.LineNumber := ALineNum;
end;

{ TExpressionEvaluator }

constructor TExpressionEvaluator.Create(ASymbols: TDictionary<string, TSymbol>);
begin
  inherited Create;
  FSymbols := ASymbols;
  FHasError := False;
  FErrorMsg := '';
end;

function TExpressionEvaluator.CurrentChar: Char;
begin
  if FPos <= Length(FExpression) then
    Result := FExpression[FPos]
  else
    Result := #0;
end;

procedure TExpressionEvaluator.SkipWhitespace;
begin
  while (FPos <= Length(FExpression)) and (FExpression[FPos] in [' ', #9]) do
    Inc(FPos);
end;

procedure TExpressionEvaluator.Advance;
begin
  Inc(FPos);
end;

function TExpressionEvaluator.ParseNumber: Int64;
var
  StartPos: Integer;
  NumStr: string;
  IsWordSuffix: Boolean;
begin
  Result := 0;
  SkipWhitespace;

  // Hex number ($xxx)
  if CurrentChar = '$' then
  begin
    Advance;
    StartPos := FPos;
    while CurrentChar in ['0'..'9', 'A'..'F', 'a'..'f'] do
      Advance;
    NumStr := '$' + Copy(FExpression, StartPos, FPos - StartPos);
    // Check for 'w' suffix (word count - multiply by 2)
    IsWordSuffix := CurrentChar in ['w', 'W'];
    if IsWordSuffix then Advance;
    try
      Result := StrToInt64(NumStr);
      if IsWordSuffix then Result := Result * 2;
    except
      FHasError := True;
      FErrorMsg := 'Invalid hex number: ' + NumStr;
    end;
  end
  // Decimal number
  else if CurrentChar in ['0'..'9'] then
  begin
    StartPos := FPos;
    while CurrentChar in ['0'..'9'] do
      Advance;
    NumStr := Copy(FExpression, StartPos, FPos - StartPos);
    // Check for 'w' suffix (word count - multiply by 2)
    IsWordSuffix := CurrentChar in ['w', 'W'];
    if IsWordSuffix then Advance;
    try
      Result := StrToInt64(NumStr);
      if IsWordSuffix then Result := Result * 2;
    except
      FHasError := True;
      FErrorMsg := 'Invalid number: ' + NumStr;
    end;
  end
  else
  begin
    FHasError := True;
    FErrorMsg := 'Expected number at position ' + IntToStr(FPos);
  end;
end;

function TExpressionEvaluator.ParseSymbol: Int64;
var
  StartPos: Integer;
  SymName: string;
  Symbol: TSymbol;
begin
  Result := 0;
  StartPos := FPos;

  // Symbol starts with letter or underscore
  while CurrentChar in ['A'..'Z', 'a'..'z', '0'..'9', '_'] do
    Advance;

  SymName := UpperCase(Copy(FExpression, StartPos, FPos - StartPos));

  if FSymbols.TryGetValue(SymName, Symbol) then
    Result := Int64(Symbol.Value)
  else
  begin
    FHasError := True;
    FErrorMsg := 'Undefined symbol: ' + SymName;
  end;
end;

function TExpressionEvaluator.ParseFactor: Int64;
begin
  Result := 0;
  SkipWhitespace;

  if FHasError then Exit;

  // Parenthesized expression
  if CurrentChar = '(' then
  begin
    Advance;
    Result := ParseExpression;
    SkipWhitespace;
    if CurrentChar = ')' then
      Advance
    else
    begin
      FHasError := True;
      FErrorMsg := 'Missing closing parenthesis';
    end;
  end
  // Unary minus
  else if CurrentChar = '-' then
  begin
    Advance;
    Result := -ParseFactor;
  end
  // Unary plus (just skip it)
  else if CurrentChar = '+' then
  begin
    Advance;
    Result := ParseFactor;
  end
  // Hex number
  else if CurrentChar = '$' then
  begin
    Result := ParseNumber;
  end
  // Decimal number
  else if CurrentChar in ['0'..'9'] then
  begin
    Result := ParseNumber;
  end
  // Symbol
  else if CurrentChar in ['A'..'Z', 'a'..'z', '_'] then
  begin
    Result := ParseSymbol;
  end
  else
  begin
    FHasError := True;
    FErrorMsg := 'Unexpected character: ' + CurrentChar;
  end;
end;

function TExpressionEvaluator.ParseTerm: Int64;
var
  Op: Char;
  Right: Int64;
begin
  Result := ParseFactor;

  while not FHasError do
  begin
    SkipWhitespace;
    Op := CurrentChar;

    if Op in ['*', '/'] then
    begin
      Advance;
      Right := ParseFactor;
      if FHasError then Exit;

      case Op of
        '*': Result := Result * Right;
        '/':
          if Right <> 0 then
            Result := Result div Right
          else
          begin
            FHasError := True;
            FErrorMsg := 'Division by zero';
          end;
      end;
    end
    else
      Break;
  end;
end;

function TExpressionEvaluator.ParseExpression: Int64;
var
  Op: Char;
  Right: Int64;
begin
  Result := ParseTerm;

  while not FHasError do
  begin
    SkipWhitespace;
    Op := CurrentChar;

    if Op in ['+', '-'] then
    begin
      Advance;
      Right := ParseTerm;
      if FHasError then Exit;

      case Op of
        '+': Result := Result + Right;
        '-': Result := Result - Right;
      end;
    end
    else
      Break;
  end;
end;

function TExpressionEvaluator.Evaluate(const Expr: string): Int64;
begin
  FExpression := Expr;
  FPos := 1;
  FHasError := False;
  FErrorMsg := '';

  Result := ParseExpression;

  // Check for trailing garbage
  SkipWhitespace;
  if (not FHasError) and (FPos <= Length(FExpression)) then
  begin
    FHasError := True;
    FErrorMsg := 'Unexpected character after expression: ' + CurrentChar;
  end;
end;

{ TK16Assembler }

constructor TK16Assembler.Create;
begin
  inherited;
  FParser := TK16Parser.Create;
  FSymbols := TDictionary<string, TSymbol>.Create;
  FForwardRefs := TList<TForwardRef>.Create;
  FInstructions := TList<TInstructionRecord>.Create;
  FInstrScope := TStringList.Create;
  FMachineCode := TList<TMachineCode>.Create;
  FSourceLines := TStringList.Create;
  FListingLines := TStringList.Create;
  FErrorList := TStringList.Create;
  FWarningList := TStringList.Create;
  FAdditionalWords := TList<TMachineCode>.Create;

  // Create encoders
  FEncoders         := TList<IK16Encoder>.Create;
  FALUEncoder       := TK16ALUEncoder.Create;
  FLoadEncoder      := TK16LoadEncoder.Create;
  FStoreEncoder     := TK16StoreEncoder.Create;
  FControlEncoder   := TK16ControlEncoder.Create;
  FJumpEncoder      := TK16JumpEncoder.Create;
  FCompareEncoder   := TK16CompareEncoder.Create;
  FBranchEncoder    := TK16BranchEncoder.Create;
  FMoveEncoder      := TK16MoveEncoder.Create;
  FJSREncoder       := TK16JSREncoder.Create;
  FPushPopEncoder   := TK16PushPopEncoder.Create;
  FLookupEncoder    := TK16LookupEncoder.Create;
  FInterruptEncoder := TK16InterruptEncoder.Create;
  FSCCEncoder       := TK16SccEncoder.Create;
  FIncDecEncoder    := TK16IncDecEncoder.Create;
  FLEAEncoder       := TK16LEAEncoder.Create;

  // Add encoders to list
  FEncoders.Add(FALUEncoder);
  FEncoders.Add(FLoadEncoder);
  FEncoders.Add(FStoreEncoder);
  FEncoders.Add(FControlEncoder);
  FEncoders.Add(FJumpEncoder);
  FEncoders.Add(FCompareEncoder);
  FEncoders.Add(FBranchEncoder);
  FEncoders.Add(FMoveEncoder);
  FEncoders.Add(FJSREncoder);
  FEncoders.Add(FPushPopEncoder);
  FEncoders.Add(FLookupEncoder);
  FEncoders.Add(FInterruptEncoder);
  FEncoders.Add(FSCCEncoder);
  FEncoders.Add(FIncDecEncoder);
  FEncoders.Add(FLEAEncoder);

  FCurrentAddress := 0;
  FStartAddress := 0;
  FEntryPoint := 0;
  FBaseAddress := 0;  // Default: no base offset
end;

destructor TK16Assembler.Destroy;
begin
  FEncoders.Free;
  // Individual encoders freed automatically via interface reference counting
  FAdditionalWords.Free;
  FErrorList.Free;
  FWarningList.Free;
  FListingLines.Free;
  FSourceLines.Free;
  FMachineCode.Free;
  FInstructions.Free;
  FInstrScope.Free;
  FForwardRefs.Free;
  FSymbols.Free;
  FParser.Free;
  inherited;
end;

function TK16Assembler.GetHasErrors: Boolean;
begin
  Result := FErrorList.Count > 0;
end;

function TK16Assembler.GetHasWarnings: Boolean;
begin
  Result := FWarningList.Count > 0;
end;

function TK16Assembler.SignedWordToInteger(Value: Word): Integer;
begin
  // Convert Word to proper signed integer
  if Value > 32767 then
    Result := Integer(Value) - 65536  // Convert 2's complement to negative
  else
    Result := Integer(Value);
end;

function TK16Assembler.SymbolResolver(const SymName: string; LineNumber: Integer): UInt32;
var
  ForwardRef: TForwardRef;
  Symbol: TSymbol;
  UpperName: string;
  CleanName: string;
  TempValue: Integer;
  DerivOp: Char;
  BaseValue: UInt32;
  IsExpression: Boolean;
  Evaluator: TExpressionEvaluator;
  ExprResult: UInt32;
begin

  UpperName := UpperCase(SymName);
  DerivOp := #0;

  { Qualify bare local label references (e.g. branch to .exit) }
  if (Length(UpperName) > 0) and (UpperName[1] = '.') then
  begin
    { Save original dot-name BEFORE qualification - needed for fallback scope scan }
    CleanName := UpperName;
    if FCurrentGlobalLabel <> '' then
      UpperName := FCurrentGlobalLabel + UpperName;

    { Check symbol table with qualified name }
    if FSymbols.TryGetValue(UpperName, Symbol) then
    begin
      Result := Symbol.Value;
      Exit;
    end;

    { Scope fallback: suffix-scan all symbols for original '.NAME' }
    if ResolveScopedLabel(CleanName, #0, Result) then
      Exit;

    { Truly unresolved - error if no scope, else create forward ref }
    if FCurrentGlobalLabel = '' then
    begin
      AddError('Local label reference before any global label: ' + SymName, LineNumber);
      Result := 0;
      Exit;
    end;
    { Fall through to forward ref with qualified UpperName }
  end;

  { Check symbol table (non-local labels) }
  if FSymbols.TryGetValue(UpperName, Symbol) then
  begin
    Result := Symbol.Value;
    Exit;
  end;

  { Handle immediate values that start with # }
  if SymName.StartsWith('#') then
  begin
    CleanName := Copy(SymName, 2, Length(SymName) - 1); { Remove # }

    { CHECK FOR DERIVATIVE OPERATOR (#< or #>) - do this FIRST }
    if (Length(CleanName) > 0) and (CleanName[1] in ['<', '>']) then
    begin
      DerivOp := CleanName[1];
      CleanName := Copy(CleanName, 2, Length(CleanName) - 1); { Remove derivative operator }
    end;

    { Qualify local label in immediate (#.exit → #FUNC.EXIT) }
    if (Length(CleanName) > 0) and (CleanName[1] = '.') then
    begin
      { Save original dot-name BEFORE qualification }
      UpperName := UpperCase(CleanName);   { e.g. '.EXIT' }
      if FCurrentGlobalLabel <> '' then
        CleanName := FCurrentGlobalLabel + UpperCase(CleanName);
    end;

    { Try to resolve CleanName as a symbol }
    UpperName := UpperCase(CleanName);
    if FSymbols.TryGetValue(UpperName, Symbol) then
    begin
      BaseValue := Symbol.Value;

      { Apply derivative operation }
      case DerivOp of
        '<': Result := BaseValue and $FFFF;           { LOW WORD (bits 15-0) }
        '>': Result := (BaseValue shr 16) and $FF;    { BANK BYTE (bits 23-16) }
        else Result := BaseValue;                      { No derivative }
      end;

      Exit;
    end;

    { Scope fallback for #.LABEL: use the saved original dot-name (before qualification) }
    if (Length(UpperName) > 0) and (UpperName[1] = '.') then
    begin
      if ResolveScopedLabel(UpperName, DerivOp, Result) then
        Exit;
    end
    else
    begin
      { Qualified name failed - try suffix scan with the dot portion }
      if (Pos('.', UpperName) > 1) then
      begin
        { Extract the '.NAME' part from 'SCOPE.NAME' and try suffix scan }
        UpperName := Copy(UpperName, Pos('.', UpperName), MaxInt);
        if ResolveScopedLabel(UpperName, DerivOp, Result) then
          Exit;
        UpperName := UpperCase(CleanName); { Restore for forward ref }
      end;
    end;

    { Check if this is an expression (contains operators) or has 'w' suffix }
    { Note: leading minus before a symbol (#-BASE) must also route to evaluator }
    IsExpression := (Pos('+', CleanName) > 0) or
                        (Pos('-', CleanName) > 1) or  // minus within expression
                        ((Length(CleanName) > 1) and (CleanName[1] = '-') and
                         not (CleanName[2] in ['0'..'9', '$'])) or  // leading minus before symbol/paren
                        (Pos('*', CleanName) > 0) or
                        (Pos('/', CleanName) > 0) or
                        (Pos('(', CleanName) > 0) or
                        ((Length(CleanName) > 1) and (CleanName[Length(CleanName)] in ['w', 'W']));

    if IsExpression then
    begin
      { Use expression evaluator }
      Evaluator := TExpressionEvaluator.Create(FSymbols);
      try
        ExprResult := Evaluator.Evaluate(CleanName);
        if Evaluator.HasError then
        begin
          AddError(Format('Expression error: %s', [Evaluator.ErrorMsg]), LineNumber);
          Result := 0;
        end
        else
        begin
          { Convert to UInt32 — ExprResult is Int64, mask to 32 bits }
          Result := UInt32(ExprResult and $FFFFFFFF);

          { Apply derivative operation }
          case DerivOp of
            '<': Result := Result and $FFFF;
            '>': Result := (Result shr 16) and $FF;
          end;
        end;
      finally
        Evaluator.Free;
      end;
      Exit;
    end;

    { Not an expression, try parsing as simple numeric literal }
    try
      { Handle negative immediate values }
      if CleanName.StartsWith('-') then
      begin
        CleanName := Copy(CleanName, 2, Length(CleanName) - 1); { Remove - }
        if CleanName.StartsWith('$') then
          TempValue := -StrToInt('$' + Copy(CleanName, 2, Length(CleanName) - 1))
        else
          TempValue := -StrToInt(CleanName);
      end
      else
      begin
        { Handle positive immediate values }
        if CleanName.StartsWith('$') then
          TempValue := StrToInt('$' + Copy(CleanName, 2, Length(CleanName) - 1))
        else
          TempValue := StrToInt(CleanName);
      end;

      { Convert signed integer to UInt32 format }
      if TempValue < 0 then
        Result := UInt32(TempValue + $100000000)  { Convert negative to 2's complement UInt32 }
      else
        Result := UInt32(TempValue);

      { Apply derivative to literal value (unusual but supported) }
      case DerivOp of
        '<': Result := Result and $FFFF;           { LOW WORD }
        '>': Result := (Result shr 16) and $FF;    { BANK BYTE }
      end;

      Exit;
    except
      { If parsing fails, fall through to forward reference handling }
    end;
  end;

  { Symbol not found - create forward reference }
  { NOTE: CleanName (without derivative) should be used for forward ref }
  ForwardRef.SymbolName := UpperName;  { This is the cleaned symbol name }
  ForwardRef.Address := FCurrentAddress;
  ForwardRef.LineNumber := LineNumber;
  ForwardRef.InstructionIndex := FMachineCode.Count;
  FForwardRefs.Add(ForwardRef);

  Result := 0; { Placeholder for forward references }
end;

procedure TK16Assembler.ErrorReporter(const Msg: string; LineNumber: Integer);
begin
  AddError(Msg, LineNumber);
end;

function TK16Assembler.AssembleFile(const Filename: string): Boolean;
begin
  try
    SetSourceFileName(Filename);
    FSourceLines.LoadFromFile(Filename);
    Result := AssembleText(FSourceLines.Text);
  except
    on E: Exception do
    begin
      AddError(Format('Error reading file %s: %s', [Filename, E.Message]));
      Result := False;
    end;
  end;
end;

function TK16Assembler.AssembleText(const SourceText: string): Boolean;
var
  OpenFiles: TStringList;
  k: Integer;
begin
  // Clear previous assembly
  FSymbols.Clear;
  FForwardRefs.Clear;
  FInstructions.Clear;
  FInstrScope.Clear;
  FMachineCode.Clear;
  FErrorList.Clear;
  FWarningList.Clear;
  FParser.ClearErrors;

  FSourceLines.Text := SourceText;
  FCurrentAddress := FStartAddress;
  FBaseAddress := 0;  // Reset base address
  FCurrentGlobalLabel := '';  // Reset local label scope

  FAdditionalWords.Clear;

  try
    // Build initial line map for main file
    SetLength(FLineMap, FSourceLines.Count);
    for k := 0 to FSourceLines.Count - 1 do
    begin
      FLineMap[k].FileName     := FSourceFileName;
      FLineMap[k].OriginalLine := k + 1;
    end;

    // Expand .INCLUDE directives before FirstPass
    if FSourceDir <> '' then
    begin
      OpenFiles := TStringList.Create;
      try
        ExpandIncludes(FSourceLines, FSourceDir, 0, OpenFiles, FLineMap);
      finally
        OpenFiles.Free;
      end;
    end;
    FirstPass;

    if not HasErrors then
      SecondPass;

    if not HasErrors then
      MergeAdditionalWords;

    if not HasErrors then
      ResolveForwardReferences;
    Result := not HasErrors;

  except
    on E: Exception do
    begin
      AddError(Format('Assembly error: %s', [E.Message]));
      Result := False;
    end;
  end;
end;

procedure TK16Assembler.FirstPass;
var
  i: Integer;
  Instr: TInstructionRecord;
  InstrSize: Integer;
begin
  FCurrentAddress := FStartAddress;

  for i := 0 to FSourceLines.Count - 1 do
  begin
    Instr := FParser.ParseLine(FSourceLines[i], i + 1);

    // Process label if present
    if Instr.LabelName <> '' then
      ProcessLabel(Instr.LabelName, FCurrentAddress, i + 1);

    // Process instruction or directive
    if Instr.Mnemonic <> '' then
    begin
      // Set address BEFORE checking if it's a directive
      Instr.Address := FCurrentAddress;  // This should work here

      if IsDirective(Instr.Mnemonic) then
      begin
        ProcessDirective(Instr);  // Pass the record with Address already set
      end
      else if IsInstruction(Instr.Mnemonic) then
      begin
        FInstructions.Add(Instr);
        FInstrScope.Add(FCurrentGlobalLabel);  // capture scope at this instruction

        InstrSize := CalculateInstructionSize(Instr);
        Inc(FCurrentAddress, InstrSize * 2);
      end
      else
      begin
        AddError(Format('Unknown instruction or directive: %s', [Instr.Mnemonic]), i + 1);
      end;
    end;
  end;
end;

procedure TK16Assembler.ProcessLabel(const LabelName: string; Address: UInt32; LineNumber: Integer);
var
  Symbol:   TSymbol;
  QualName: string;
begin
  if (Address and 1) <> 0 then
    AddWarning(Format('Label "%s" at odd address $%06X - may cause misalignment if used as code target',
      [LabelName, Address]), LineNumber);

  QualName := QualifyLabel(LabelName, LineNumber);
  if QualName = '' then Exit;  // Error already reported

  if FSymbols.ContainsKey(QualName) then
  begin
    AddError(Format('Label "%s" already defined', [QualName]), LineNumber);
    Exit;
  end;

  Symbol := TSymbol.CreateLabel(QualName, Address, LineNumber);
  FSymbols.Add(QualName, Symbol);
end;

procedure TK16Assembler.ProcessDirective(const Instr: TInstructionRecord);
var
  Symbol:       TSymbol;
  Value:        UInt32;
  SymbolName:   string;
  NewAddress:   UInt32;
  ValueStr:     string;
  IsExpr:       Boolean;
  Evaluator:    TExpressionEvaluator;
  ExprResult:   UInt32;
  AddrStr:      string;
  FullText:     string;
  ByteCount:    Integer;
  WordCount:    Integer;
  FoundSymbol:  TSymbol;
  TextData:     TArray<Byte>;
  Boundary:     Integer;
  PadBytes:     Integer;
  ModifiedInstr: TInstructionRecord;
begin

  if SameText(Instr.Mnemonic, '.EQU') then
  begin
    // .EQU SYMBOL, value (or expression)
    if Length(Instr.Operands) = 2 then
    begin
      SymbolName := Trim(Instr.Operands[0]);
      ValueStr := Trim(Instr.Operands[1]);

      // Check if value is an expression (contains operators) or 'w' suffix
      IsExpr := (Pos('+', ValueStr) > 0) or
                    (Pos('-', ValueStr) > 1) or  // > 1 to skip leading minus
                    (Pos('*', ValueStr) > 0) or
                    (Pos('/', ValueStr) > 0) or
                    (Pos('(', ValueStr) > 0) or
                    ((Length(ValueStr) > 1) and (ValueStr[Length(ValueStr)] in ['w', 'W']));

      if IsExpr then
      begin
        // Use expression evaluator
        Evaluator := TExpressionEvaluator.Create(FSymbols);
        try
          ExprResult := Evaluator.Evaluate(ValueStr);
          if Evaluator.HasError then
            AddError(Format('.EQU expression error: %s', [Evaluator.ErrorMsg]), Instr.LineNumber)
          else
          begin
            Value := UInt32(ExprResult and $FFFFFFFF);
            Symbol := TSymbol.CreateConstant(SymbolName, Value, Instr.LineNumber);
            FSymbols.AddOrSetValue(UpperCase(SymbolName), Symbol);
          end;
        finally
          Evaluator.Free;
        end;
      end
      else
      begin
        // Simple value
        try
          if ValueStr.StartsWith('$') then
            Value := StrToInt('$' + Copy(ValueStr, 2, MaxInt))
          else
            Value := StrToInt(ValueStr);

          Symbol := TSymbol.CreateConstant(SymbolName, Value, Instr.LineNumber);
          FSymbols.AddOrSetValue(UpperCase(SymbolName), Symbol);
        except
          on E: EConvertError do
            AddError(Format('Invalid constant value in .EQU directive: %s', [E.Message]), Instr.LineNumber);
        end;
      end;
    end
    else
      AddError('.EQU directive requires exactly 2 operands: .EQU SYMBOL, value', Instr.LineNumber);
  end
  else if SameText(Instr.Mnemonic, '.ORG') then
  begin
    // .ORG address - set assembly origin (MUST be even for K16)
    // Supports: .ORG $FF0000, .ORG 65536, .ORG SYMBOL_NAME
    if Length(Instr.Operands) = 1 then
    begin
      AddrStr := Trim(Instr.Operands[0]);

      // First, check if it's a symbol reference
      if FSymbols.TryGetValue(UpperCase(AddrStr), FoundSymbol) then
      begin
        NewAddress := FoundSymbol.Value;
      end
      else
      begin
        // Try to parse as numeric value
        try
          if AddrStr.StartsWith('$') then
            NewAddress := StrToInt('$' + Copy(AddrStr, 2, MaxInt))
          else
            NewAddress := StrToInt(AddrStr);
        except
          on E: EConvertError do
          begin
            AddError(Format('Invalid address in .ORG directive: ''%s'' is not a valid address or symbol', [AddrStr]), Instr.LineNumber);
            Exit;
          end;
        end;
      end;

      // Validate 24-bit range (K16 addressing limit)
      if NewAddress > $FFFFFF then
      begin
        AddError(Format('.ORG address $%06X exceeds K16 24-bit range ($000000-$FFFFFF)',
                 [NewAddress]), Instr.LineNumber);
        Exit;
      end;

      // Validate even address for K16 word-aligned architecture
      if (NewAddress and 1) <> 0 then
      begin
        AddError(Format('.ORG address $%06X is odd - K16 requires even addresses', [NewAddress]), Instr.LineNumber);
        NewAddress := NewAddress and $FFFFFFFE; // Force even (24-bit mask)
        AddWarning(Format('Adjusted .ORG to even address $%06X', [NewAddress]), Instr.LineNumber);
      end;

      FCurrentAddress := NewAddress;
    end
    else
      AddError('.ORG directive requires exactly 1 operand: .ORG address', Instr.LineNumber);
  end
  else if SameText(Instr.Mnemonic, '.BASE') then
  begin
    // .BASE address - set ROM base address for image generation
    // Supports: .BASE $F00000, .BASE 65536, .BASE SYMBOL_NAME
    if Length(Instr.Operands) = 1 then
    begin
      AddrStr := Trim(Instr.Operands[0]);

      // First, check if it's a symbol reference
      if FSymbols.TryGetValue(UpperCase(AddrStr), FoundSymbol) then
      begin
        NewAddress := FoundSymbol.Value;
      end
      else
      begin
        // Try to parse as numeric value
        try
          if AddrStr.StartsWith('$') then
            NewAddress := StrToInt('$' + Copy(AddrStr, 2, MaxInt))
          else
            NewAddress := StrToInt(AddrStr);
        except
          on E: EConvertError do
          begin
            AddError(Format('Invalid address in .BASE directive: ''%s'' is not a valid address or symbol', [AddrStr]), Instr.LineNumber);
            Exit;
          end;
        end;
      end;

      // Validate 24-bit range
      if NewAddress > $FFFFFF then
      begin
        AddError(Format('.BASE address $%06X exceeds K16 24-bit range ($000000-$FFFFFF)',
                 [NewAddress]), Instr.LineNumber);
        Exit;
      end;

      // Must be even
      if (NewAddress and 1) <> 0 then
      begin
        AddError(Format('.BASE address $%06X is odd - K16 requires even addresses', [NewAddress]), Instr.LineNumber);
        NewAddress := NewAddress and $FFFFFFFE;
        AddWarning(Format('Adjusted .BASE to even address $%06X', [NewAddress]), Instr.LineNumber);
      end;

      FBaseAddress := NewAddress;
    end
    else
      AddError('.BASE directive requires exactly 1 operand: .BASE address', Instr.LineNumber);
  end
  else if SameText(Instr.Mnemonic, '.WORD') then
  begin
    // .WORD value1, value2, ... - generate actual data words
    if Length(Instr.Operands) > 0 then
    begin
      // Add directive to instruction list for SecondPass to generate machine code
      FInstructions.Add(Instr);  // Address already set by FirstPass
      Inc(FCurrentAddress, Length(Instr.Operands) * 2); // Each word = 2 bytes
    end
    else
      AddError('.WORD directive requires at least 1 operand: .WORD value1 [,value2...]', Instr.LineNumber);
  end

  else if SameText(Instr.Mnemonic, '.TEXT') then
  begin

    // .TEXT 'string', bytes... - generate text data (strings and bytes)
    if Length(Instr.Operands) > 0 then
    begin
      FullText := ExtractTextOperands(Instr.SourceLine);

      if ParseTextString(FullText, Instr.LineNumber, TextData) then
      begin
        ByteCount := Length(TextData);
        WordCount := (ByteCount + 1) div 2;
        FInstructions.Add(Instr);
        Inc(FCurrentAddress, WordCount * 2);
      end
      else
      begin
        AddError('Failed to parse .TEXT directive content', Instr.LineNumber);
      end;
    end
    else
      AddError('.TEXT directive requires at least 1 operand: .TEXT ''string'' or .TEXT bytes', Instr.LineNumber);
  end

  else if SameText(Instr.Mnemonic, '.BYTE') then
  begin
    // .BYTE val, val, "str", ...  — emit individual bytes, PC advances by byte count
    FullText := ExtractDirectiveContent(Instr.SourceLine, '.BYTE');
    if ParseTextString(FullText, Instr.LineNumber, TextData) then
    begin
      ByteCount := Length(TextData);
      if ByteCount > 0 then
      begin
        FInstructions.Add(Instr);
        Inc(FCurrentAddress, ByteCount);   // exact bytes, not rounded to words
      end;
      // .BYTE with zero bytes is a no-op (no warning needed)
    end
    else
      AddError('Failed to parse .BYTE directive content', Instr.LineNumber);
  end

  else if SameText(Instr.Mnemonic, '.ALIGN') then
  begin
    // .ALIGN [boundary]  — pad to boundary (default 2 = word align)
    Boundary := 2;
    if Length(Instr.Operands) >= 1 then
      Boundary := EvalDirectiveArg(Instr.Operands[0], Instr.LineNumber);

    if Boundary < 1 then Boundary := 2;

    if (Boundary > 1) and ((Boundary and (Boundary - 1)) <> 0) then
    begin
      AddError('.ALIGN boundary must be a power of 2', Instr.LineNumber);
      Boundary := 2;
    end;

    // Compute pad bytes needed to reach alignment
    PadBytes := 0;
    if Boundary > 1 then
      PadBytes := (Boundary - (Integer(FCurrentAddress) mod Boundary)) mod Boundary;

    Inc(FCurrentAddress, PadBytes);

    // Only emit words when PadBytes >= 2.
    // PadBytes=0: already aligned, nothing to do.
    // PadBytes=1: high byte of preceding .BYTE word is already $00 — no word needed.
    if PadBytes >= 2 then
    begin
      ModifiedInstr := Instr;
      SetLength(ModifiedInstr.Operands, 1);
      ModifiedInstr.Operands[0] := IntToStr(PadBytes);
      FInstructions.Add(ModifiedInstr);
    end;
  end

  else if SameText(Instr.Mnemonic, '.DS') then
  begin
    // .DS count [, fill_byte]  — reserve N bytes, default fill $00
    if Length(Instr.Operands) >= 1 then
    begin
      ByteCount := EvalDirectiveArg(Instr.Operands[0], Instr.LineNumber);
      if ByteCount < 0 then
      begin
        AddError('.DS count must be >= 0', Instr.LineNumber);
        ByteCount := 0;
      end;
      if ByteCount > 0 then
      begin
        FInstructions.Add(Instr);
        Inc(FCurrentAddress, ByteCount);
      end;
      // .DS 0 — valid no-op, no instruction added
    end
    else
      AddError('.DS requires a byte count: .DS count [, fill_byte]', Instr.LineNumber);
  end

  else if SameText(Instr.Mnemonic, '.INCLUDE') then
  begin
    // Fully expanded before FirstPass — if we see one here, either FSourceDir
    // was empty (unsaved file) or expansion was skipped
    if FSourceDir = '' then
      AddError('.INCLUDE requires the file to be saved before assembling', Instr.LineNumber);
    // Otherwise silently ignore — already expanded into FSourceLines
  end;
end;

function TK16Assembler.CalculateInstructionSize(const Instr: TInstructionRecord): Integer;
var
  Encoder: IK16Encoder;
  DummyMachCode: TMachineCode;
  FullText: string;
  ByteCount: Integer;
  TextData: TArray<Byte>;
begin

  Result := 1; // Safe default for unknown instructions

  // Handle directives that don't use encoders
  if SameText(Instr.Mnemonic, '.WORD') then
  begin
    Result := Length(Instr.Operands);
    Exit;
  end;

  if SameText(Instr.Mnemonic, '.TEXT') then
  begin
    if Length(Instr.Operands) > 0 then
    begin
      FullText := ExtractTextOperands(Instr.SourceLine);
      if ParseTextString(FullText, Instr.LineNumber, TextData) then
      begin
        ByteCount := Length(TextData);
        Result := (ByteCount + 1) div 2;
      end
      else
        Result := 1;
    end;
    Exit;
  end;

  if SameText(Instr.Mnemonic, '.ORG')  or SameText(Instr.Mnemonic, '.EQU') or
     SameText(Instr.Mnemonic, '.BASE') or SameText(Instr.Mnemonic, '.INCLUDE') then
  begin
    Result := 0;
    Exit;
  end;

  if SameText(Instr.Mnemonic, '.BYTE') then
  begin
    if Length(Instr.Operands) > 0 then
    begin
      FullText := ExtractDirectiveContent(Instr.SourceLine, '.BYTE');
      if ParseTextString(FullText, 0, TextData) then
        Result := (Length(TextData) + 1) div 2   // words in output for listing
      else
        Result := 0;
    end
    else
      Result := 0;
    Exit;
  end;

  if SameText(Instr.Mnemonic, '.ALIGN') then
  begin
    // Operands[0] holds pre-computed PadBytes from ProcessDirective
    if Length(Instr.Operands) >= 1 then
      ByteCount := StrToIntDef(Instr.Operands[0], 0)
    else
      ByteCount := 0;
    Result := ByteCount div 2;
    Exit;
  end;

  if SameText(Instr.Mnemonic, '.DS') then
  begin
    if Length(Instr.Operands) >= 1 then
      ByteCount := EvalDirectiveArg(Instr.Operands[0], 0)
    else
      ByteCount := 0;
    Result := (ByteCount + 1) div 2;
    Exit;
  end;
  Encoder := FindEncoder(Instr.Mnemonic);
  if Encoder <> nil then
  begin
    // SMART DUMMY RESOLVER: Checks real symbols first, then falls back
    // Dummy callbacks using private methods

    try
      DummyMachCode := Encoder.Encode(Instr, Self.DummySizeSymbolResolver, Self.DummySizeErrorReporter, Self.DummySizeWarningReporter);
      Result := DummyMachCode.GetTotalWords;

      if (Result < 1) or (Result > 4) then
        Result := 2;
    except
      Result := 2;
    end;
  end;
end;

procedure TK16Assembler.SecondPass;
var
  i: Integer;
  Instr: TInstructionRecord;
  MC: TMachineCode;
begin
  FCurrentGlobalLabel := '';  // Reset scope for second pass

  for i := 0 to FInstructions.Count - 1 do
  begin
    Instr := FInstructions[i];

    // Restore global scope from FirstPass - handles standalone labels correctly
    if i < FInstrScope.Count then
      FCurrentGlobalLabel := FInstrScope[i];

    // Just encode with the mode already determined in FirstPass
    MC := EncodeInstruction(Instr, i);
    MC.Address := Instr.Address;
    FMachineCode.Add(MC);
  end;
end;

procedure TK16Assembler.MergeAdditionalWords;
var
  i, SortI, SortJ: Integer;
  SortTemp: TMachineCode;
begin

    for i := 0 to FAdditionalWords.Count - 1 do
    begin
      FMachineCode.Add(FAdditionalWords[i]);
    end;

    // Sort by address (FPC-compatible insertion sort)
    for SortI := 0 to FMachineCode.Count - 2 do
      for SortJ := SortI + 1 to FMachineCode.Count - 1 do
        if FMachineCode[SortJ].Address < FMachineCode[SortI].Address then
        begin
          SortTemp := FMachineCode[SortI];
          FMachineCode[SortI] := FMachineCode[SortJ];
          FMachineCode[SortJ] := SortTemp;
        end;

end;

function TK16Assembler.ResolveSymbol(const SymName: string; LineNumber: Integer): Word;
var
  Value: UInt32;
begin
  Value := SymbolResolver(SymName, LineNumber);

  { Warn if value exceeds 16-bit range }
  if Value > $FFFF then
  begin
    AddWarning(Format('Symbol value $%x truncated to 16 bits: $%x',
                      [Value, Value and $FFFF]), LineNumber);
  end;

  Result := Word(Value and $FFFF);
end;

function TK16Assembler.FindEncoder(const Mnemonic: string): IK16Encoder;
var
  i: Integer;
begin
  for i := 0 to FEncoders.Count - 1 do
  begin
    if FEncoders[i].SupportsInstruction(Mnemonic) then
      Exit(FEncoders[i]);
  end;
  Result := nil;
end;

function TK16Assembler.EncodeInstruction(const Instr: TInstructionRecord; InstrIndex: Integer): TMachineCode;
var
  Encoder: IK16Encoder;
  ModifiedInstr: TInstructionRecord;
  Value: UInt32;
  i: Integer;
  AdditionalValue: UInt32;
  FullText: string;
  ByteCount: Integer;
  AdditionalWord: TMachineCode;
  TextData: TArray<Byte>;
  FillByte: Byte;
  PadBytes: Integer;begin

  Result.Address := Instr.Address;  // Ensure address is always set
  Result.SourceLine := Instr.LineNumber;
  Result.HasImmediate := False;
  Result.Immediate := 0;
  Result.CanonicalMnemonic := Instr.Mnemonic; // Default
  Result.IsDataWord := False;

  // Handle .WORD directive specially
  if SameText(Instr.Mnemonic, '.WORD') then
  begin
    if Length(Instr.Operands) > 0 then
    begin
      // Generate first word (returned as main result)
      Value := SymbolResolver('#' + Instr.Operands[0], Instr.LineNumber);
      Result.OpCode := Word(Value and $FFFF);
      Result.CanonicalMnemonic := '.WORD';
      Result.IsDataWord := True;
      // Generate additional words for operands 1, 2, 3, etc.
      for i := 1 to High(Instr.Operands) do
      begin
        AdditionalWord.Address := Instr.Address + (i * 2);
        AdditionalWord.SourceLine := Instr.LineNumber;
        AdditionalWord.HasImmediate := False;
        AdditionalWord.Immediate := 0;
        AdditionalWord.CanonicalMnemonic := '.WORD';
        AdditionalWord.IsDataWord := True;
        AdditionalValue := SymbolResolver('#' + Instr.Operands[i], Instr.LineNumber);
        AdditionalWord.OpCode := Word(AdditionalValue and $FFFF);
        FAdditionalWords.Add(AdditionalWord);
      end;
    end;
    Exit;
  end;

  // Handle .TEXT directive specially
  if SameText(Instr.Mnemonic, '.TEXT') then
  begin
    if Length(Instr.Operands) > 0 then
    begin
      FullText := ExtractTextOperands(Instr.SourceLine);

      if ParseTextString(FullText, Instr.LineNumber, TextData) then
      begin
        ByteCount := Length(TextData);

        if ByteCount > 0 then
        begin
          Result.OpCode := TextData[0];
          if ByteCount > 1 then
            Result.OpCode := Result.OpCode or (Word(TextData[1]) shl 8);

          Result.CanonicalMnemonic := '.TEXT';
          Result.IsDataWord := True;

          // Generate additional words for remaining bytes
          i := 2;
          while i < ByteCount do
          begin
            AdditionalWord.Address := Instr.Address + ((i div 2) * 2);
            AdditionalWord.SourceLine := Instr.LineNumber;
            AdditionalWord.HasImmediate := False;
            AdditionalWord.Immediate := 0;
            AdditionalWord.CanonicalMnemonic := '.TEXT';
            AdditionalWord.IsDataWord := True;

            // Pack two bytes into word (LITTLE-ENDIAN: low byte first!)
            AdditionalWord.OpCode := TextData[i]; // Low byte (even address)
            if (i + 1) < ByteCount then
              AdditionalWord.OpCode := AdditionalWord.OpCode or (Word(TextData[i + 1]) shl 8); // High byte (odd address)

            FAdditionalWords.Add(AdditionalWord);

            Inc(i, 2);
          end;
        end;
      end;
    end;
    Exit;
  end;

  // Handle .BYTE directive — pack bytes into words, same pattern as .TEXT
  if SameText(Instr.Mnemonic, '.BYTE') then
  begin
    FullText := ExtractDirectiveContent(Instr.SourceLine, '.BYTE');
    if ParseTextString(FullText, Instr.LineNumber, TextData) then
    begin
      ByteCount := Length(TextData);
      if ByteCount > 0 then
      begin
        Result.OpCode := TextData[0];
        if ByteCount > 1 then
          Result.OpCode := Result.OpCode or (Word(TextData[1]) shl 8);
        Result.CanonicalMnemonic := '.BYTE';
        Result.IsDataWord := True;

        i := 2;
        while i < ByteCount do
        begin
          AdditionalWord.Address           := Instr.Address + i;
          AdditionalWord.SourceLine        := Instr.LineNumber;
          AdditionalWord.HasImmediate      := False;
          AdditionalWord.Immediate         := 0;
          AdditionalWord.CanonicalMnemonic := '.BYTE';
          AdditionalWord.IsDataWord        := True;
          AdditionalWord.OpCode            := TextData[i];
          if (i + 1) < ByteCount then
            AdditionalWord.OpCode := AdditionalWord.OpCode or (Word(TextData[i + 1]) shl 8);
          FAdditionalWords.Add(AdditionalWord);
          Inc(i, 2);
        end;
      end
      else
      begin
        // Zero-byte .BYTE — emit a dummy so listing can show the directive
        Result.OpCode            := 0;
        Result.CanonicalMnemonic := '.BYTE';
        Result.IsDataWord        := True;
      end;
    end;
    Exit;
  end;

  // Handle .ALIGN directive
  // Operands[0] = pre-computed PadBytes (stored by ProcessDirective)
  if SameText(Instr.Mnemonic, '.ALIGN') then
  begin
    PadBytes := StrToIntDef(Instr.Operands[0], 0);
    Result.CanonicalMnemonic := '.ALIGN';
    Result.IsDataWord        := True;
    Result.OpCode            := 0;

    // PadBytes = 0 → already aligned, nothing to emit
    // PadBytes = 1 → odd byte; the high byte of the preceding word is already $00,
    //                so we just advance PC — no word emitted
    // PadBytes >= 2 → emit floor(PadBytes/2) zero words starting at next even address
    if PadBytes >= 2 then
    begin
      // First word: address is already the next even address (Instr.Address is
      // the address at entry to .ALIGN, which may be odd — round up)
      Result.Address := (Instr.Address + 1) and $FFFFFE;

      i := 2;
      while i < (PadBytes div 2) * 2 do
      begin
        AdditionalWord.Address           := Result.Address + i;
        AdditionalWord.SourceLine        := Instr.LineNumber;
        AdditionalWord.HasImmediate      := False;
        AdditionalWord.Immediate         := 0;
        AdditionalWord.CanonicalMnemonic := '.ALIGN';
        AdditionalWord.IsDataWord        := True;
        AdditionalWord.OpCode            := 0;
        FAdditionalWords.Add(AdditionalWord);
        Inc(i, 2);
      end;
    end;
    Exit;
  end;

  // Handle .DS directive — reserve N bytes filled with FillByte (default $00)
  if SameText(Instr.Mnemonic, '.DS') then
  begin
    ByteCount := EvalDirectiveArg(Instr.Operands[0], Instr.LineNumber);
    FillByte  := 0;
    if Length(Instr.Operands) >= 2 then
      FillByte := Byte(EvalDirectiveArg(Instr.Operands[1], Instr.LineNumber) and $FF);

    Result.CanonicalMnemonic := '.DS';
    Result.IsDataWord        := True;
    Result.OpCode            := FillByte or (Word(FillByte) shl 8);

    i := 2;
    while i < ByteCount do
    begin
      AdditionalWord.Address           := Instr.Address + i;
      AdditionalWord.SourceLine        := Instr.LineNumber;
      AdditionalWord.HasImmediate      := False;
      AdditionalWord.Immediate         := 0;
      AdditionalWord.CanonicalMnemonic := '.DS';
      AdditionalWord.IsDataWord        := True;
      AdditionalWord.OpCode            := FillByte or (Word(FillByte) shl 8);
      FAdditionalWords.Add(AdditionalWord);
      Inc(i, 2);
    end;
    Exit;
  end;

  Encoder := FindEncoder(Instr.Mnemonic);
  if Encoder <> nil then
  begin
    try
      Result := Encoder.Encode(Instr, SymbolResolver, ErrorReporter, WarningReporter);

      // Preserve address — encoder may overwrite it
      Result.Address := Instr.Address;

      // Store canonical mnemonic back in the instruction record
      ModifiedInstr := Instr;
      ModifiedInstr.CanonicalMnemonic := Result.CanonicalMnemonic;
      FInstructions[InstrIndex] := ModifiedInstr;

    except
      on E: Exception do
      begin
        ErrorReporter(Format('Error encoding %s: %s', [Instr.Mnemonic, E.Message]), Instr.LineNumber);
        Result.OpCode := 0;
        Result.Address := Instr.Address; // Ensure address is set even on error
      end;
    end;
  end
  else
  begin
    ErrorReporter(Format('No encoder found for instruction: %s', [Instr.Mnemonic]), Instr.LineNumber);
    Result.OpCode := 0;
    Result.Address := Instr.Address; // Ensure address is set even on error
  end;
end;

procedure TK16Assembler.ResolveForwardReferences;
var
  i: Integer;
  ForwardRef: TForwardRef;
  Symbol: TSymbol;
  MachCode: TMachineCode;
  Instruction: TInstructionRecord;
  ByteOffset: Integer;
  IsBranchInstruction: Boolean;
  IsLongBranch: Boolean;
  InstrSize: Integer;
  ShouldBeLong: Boolean;
begin
  for i := 0 to FForwardRefs.Count - 1 do
  begin
    ForwardRef := FForwardRefs[i];

    if FSymbols.TryGetValue(ForwardRef.SymbolName, Symbol) then
    begin
      if ForwardRef.InstructionIndex < FMachineCode.Count then
      begin
        MachCode := FMachineCode[ForwardRef.InstructionIndex];
        Instruction := FInstructions[ForwardRef.InstructionIndex];

        // Check for all branch instruction variants
        IsBranchInstruction := SameText(Instruction.Mnemonic, 'BEQ') or
                              SameText(Instruction.Mnemonic, 'BNE') or
                              SameText(Instruction.Mnemonic, 'BCS') or
                              SameText(Instruction.Mnemonic, 'BCC') or
                              SameText(Instruction.Mnemonic, 'BMI') or
                              SameText(Instruction.Mnemonic, 'BPL') or
                              SameText(Instruction.Mnemonic, 'BGE') or
                              SameText(Instruction.Mnemonic, 'BRA') or
                              SameText(Instruction.Mnemonic, 'BRANCH') or
                              // Mode 00 short branches (.S suffix)
                              SameText(Instruction.Mnemonic, 'BEQ.S') or
                              SameText(Instruction.Mnemonic, 'BNE.S') or
                              SameText(Instruction.Mnemonic, 'BCS.S') or
                              SameText(Instruction.Mnemonic, 'BCC.S') or
                              SameText(Instruction.Mnemonic, 'BMI.S') or
                              SameText(Instruction.Mnemonic, 'BPL.S') or
                              SameText(Instruction.Mnemonic, 'BRA.S') or
                              // Mode 01 long branches (.L suffix)
                              SameText(Instruction.Mnemonic, 'BEQ.L') or
                              SameText(Instruction.Mnemonic, 'BNE.L') or
                              SameText(Instruction.Mnemonic, 'BCS.L') or
                              SameText(Instruction.Mnemonic, 'BCC.L') or
                              SameText(Instruction.Mnemonic, 'BMI.L') or
                              SameText(Instruction.Mnemonic, 'BPL.L') or
                              SameText(Instruction.Mnemonic, 'BRA.L');

        if IsBranchInstruction then
        begin
          // Determine if this is a long branch (Mode 01)
          IsLongBranch := Instruction.Mnemonic.EndsWith('.L') or MachCode.HasImmediate;

          // Determine instruction size for byte offset calculation
          if IsLongBranch then
            InstrSize := 4  // Long branch: 2 words = 4 bytes
          else
            InstrSize := 2; // Short branch: 1 word = 2 bytes

          // Calculate byte offset (not word offset!)
          ByteOffset := Integer(Symbol.Value) - (Instruction.Address + InstrSize);

          // Check only even addresses
          if (Integer(Symbol.Value) and 1) <> 0 then
          begin
            AddError(Format('%s target address $%.*X is odd - K16 requires even addresses',
              [Instruction.Mnemonic, 6, Integer(Symbol.Value)]), ForwardRef.LineNumber);
            Continue; // Skip this reference
          end;

          // **NEW: Validate auto-select branch mode consistency**
          if not (Instruction.Mnemonic.EndsWith('.S') or Instruction.Mnemonic.EndsWith('.L')) then
          begin
            // This is an auto-select branch - check if chosen mode matches actual distance
            ShouldBeLong := (ByteOffset < 0) or (ByteOffset > 31);

            if ShouldBeLong <> IsLongBranch then
            begin
              if ShouldBeLong then
                AddError(Format('Branch mode mismatch for %s: distance %d bytes requires long mode but short was generated - use %s.L',
                  [Instruction.Mnemonic, ByteOffset, Instruction.Mnemonic]), ForwardRef.LineNumber)
              else
                AddError(Format('Branch mode mismatch for %s: distance %d bytes requires short mode but long was generated - use %s.S',
                  [Instruction.Mnemonic, ByteOffset, Instruction.Mnemonic]), ForwardRef.LineNumber);
              Continue;
            end;
          end;

          if IsLongBranch then
          begin
            // Mode 01: Long branch with signed byte offset in T16W
            if (ByteOffset < -32768) or (ByteOffset > 32767) then
            begin
              AddError(Format('Long branch to %s: byte offset %d out of range (-32768 to +32767 bytes)',
                [ForwardRef.SymbolName, ByteOffset]), ForwardRef.LineNumber);
              Continue;
            end;

            // Store signed byte offset in immediate field (T16W)
            MachCode.HasImmediate := True;
            MachCode.Immediate := Word(ByteOffset and $FFFF);
          end
          else
          begin
            // Mode 00: Short branch with unsigned byte offset in T8-5 (0-31 bytes, forward only)
            if (ByteOffset < 0) or (ByteOffset > 31) then
            begin
              AddError(Format('Short branch to %s: byte offset %d out of range (0 to +31 bytes, forward only)',
                [ForwardRef.SymbolName, ByteOffset]), ForwardRef.LineNumber);
              Continue;
            end;

            // Update unsigned byte offset in opcode (bits 4-0) - T8-5 encoding
            MachCode.OpCode := MachCode.OpCode and $FFE0; // Clear bits 4-0
            MachCode.OpCode := MachCode.OpCode or (ByteOffset and $1F); // Set unsigned offset
          end;
        end
        else
        begin
          // Non-branch instructions: update immediate value (T16W)
          MachCode.Immediate := Symbol.Value;
        end;

        FMachineCode[ForwardRef.InstructionIndex] := MachCode;
      end;
    end
    else
    begin
      AddError(Format('Undefined symbol: %s', [ForwardRef.SymbolName]), ForwardRef.LineNumber);
    end;
  end;
end;

procedure TK16Assembler.GenerateIntelHex(const Filename: string);
var
  HexFile: TStringList;
  i: Integer;
  MachCode: TMachineCode;
  Bytes: TArray<Byte>;
  HexLine: string;
  Checksum: Byte;
  j: Integer;
begin
  HexFile := TStringList.Create;
  try
    for i := 0 to FMachineCode.Count - 1 do
    begin
      MachCode := FMachineCode[i];
      Bytes := MachCode.GetBytes;

      // Generate Intel HEX record
      HexLine := Format(':%02X%04X00', [Length(Bytes), MachCode.Address]); // Word addressing
      Checksum := Length(Bytes) + ((MachCode.Address shr 8) and $FF) + (MachCode.Address and $FF);

      for j := 0 to High(Bytes) do
      begin
        HexLine := HexLine + Format('%02X', [Bytes[j]]);
        Inc(Checksum, Bytes[j]);
      end;

      Checksum := Byte(256 - Checksum);
      HexLine := HexLine + Format('%02X', [Checksum]);

      HexFile.Add(HexLine);
    end;

    // End of file record
    HexFile.Add(':00000001FF');

    HexFile.SaveToFile(Filename);
  finally
    HexFile.Free;
  end;
end;

procedure TK16Assembler.GenerateBinary(const Filename: string);
var
  BinaryFile: TFileStream;
  i: Integer;
  MachCode: TMachineCode;
  Bytes: TArray<Byte>;
begin
  BinaryFile := TFileStream.Create(Filename, fmCreate);
  try
    for i := 0 to FMachineCode.Count - 1 do
    begin
      MachCode := FMachineCode[i];
      Bytes := MachCode.GetBytes;
      BinaryFile.WriteBuffer(Bytes[0], Length(Bytes));
    end;
  finally
    BinaryFile.Free;
  end;
end;

procedure TK16Assembler.GenerateSymbolTable(const Filename: string);
var
  SymFile: TStringList;
  Symbol: TSymbol;
begin
  SymFile := TStringList.Create;
  try
    SymFile.Add('K16 Symbol Table');
    SymFile.Add('================');
    SymFile.Add('');

    SymFile.Add('Name                     Type      Address  Line');
SymFile.Add('------------------------ --------- -------- ----');

for Symbol in FSymbols.Values do
begin
  case Symbol.SymType of
    stLabel:    SymFile.Add(Format('%-24s %-9s %06X   %4d', [Symbol.Name, 'Label',    Symbol.Value, Symbol.LineNumber]));
    stConstant: SymFile.Add(Format('%-24s %-9s %06X   %4d', [Symbol.Name, 'Constant', Symbol.Value, Symbol.LineNumber]));
    stVariable: SymFile.Add(Format('%-24s %-9s %06X   %4d', [Symbol.Name, 'Variable', Symbol.Value, Symbol.LineNumber]));
  end;
end;

    SymFile.SaveToFile(Filename);
  finally
    SymFile.Free;
  end;
end;

function TK16Assembler.GenerateListingText: string;
var
  L: TK16ListingGenerator;
begin
  L := TK16ListingGenerator.Create(Self);
  try
    Result := L.Generate;
  finally
    L.Free;
  end;
end;

procedure TK16Assembler.GenerateListing(const Filename: string);
var
  L: TK16ListingGenerator;
begin
  L := TK16ListingGenerator.Create(Self);
  try
    L.SaveToFile(Filename);
  finally
    L.Free;
  end;
end;

procedure TK16Assembler.AddError(const Msg: string; LineNumber: Integer);
var
  Info: TLineInfo;
  Prefix: string;
begin
  if (LineNumber > 0) and (LineNumber <= Length(FLineMap)) then
  begin
    Info := FLineMap[LineNumber - 1];
    if Info.FileName <> '' then
      Prefix := Format('%s line %d', [ExtractFileName(Info.FileName), Info.OriginalLine])
    else
      Prefix := Format('line %d', [Info.OriginalLine]);
  end
  else if LineNumber > 0 then
    Prefix := Format('line %d', [LineNumber])
  else
    Prefix := '';

  if Prefix <> '' then
    FErrorList.Add(Format('%s: %s', [Prefix, Msg]))
  else
    FErrorList.Add(Msg);
end;

procedure TK16Assembler.WarningReporter(const Msg: string; LineNumber: Integer);
begin
  AddWarning(Msg, LineNumber);
end;

procedure TK16Assembler.AddWarning(const Msg: string; LineNumber: Integer);
var
  Info: TLineInfo;
  Prefix: string;
begin
  if (LineNumber > 0) and (LineNumber <= Length(FLineMap)) then
  begin
    Info := FLineMap[LineNumber - 1];
    if Info.FileName <> '' then
      Prefix := Format('%s line %d', [ExtractFileName(Info.FileName), Info.OriginalLine])
    else
      Prefix := Format('line %d', [Info.OriginalLine]);
  end
  else if LineNumber > 0 then
    Prefix := Format('line %d', [LineNumber])
  else
    Prefix := '';

  if Prefix <> '' then
    FWarningList.Add(Format('%s: %s', [Prefix, Msg]))
  else
    FWarningList.Add(Msg);
end;

procedure TK16Assembler.NotifyMessage(const Msg: string);
begin
  if Assigned(FOnMessage) then
    FOnMessage(Msg);
end;

function TK16Assembler.IsInstruction(const Mnemonic: string): Boolean;
var
  i: Integer;
begin
  // Check if any encoder supports this mnemonic
  for i := 0 to FEncoders.Count - 1 do
  begin
    if FEncoders[i].SupportsInstruction(Mnemonic) then
      Exit(True);
  end;
  Result := False;
end;

function TK16Assembler.IsDirective(const Mnemonic: string): Boolean;
begin
  Result := AnsiIndexText(Mnemonic, ['.EQU', '=', '.ORG', '.BASE',
                                      '.WORD', '.TEXT', '.BYTE',
                                      '.ALIGN', '.DS', '.INCLUDE']) >= 0;
end;

function TK16Assembler.ParseTextString(const Input: string; LineNumber: Integer;
                                       out Bytes: TArray<Byte>): Boolean;
var
  i: Integer;
  Ch: Char;
  ByteList: TList<Byte>;
  QuoteChar: Char;
  NumStr: string;
  Value: Integer;
  HexStr: string;
  HexValue: Integer;
  TempByte: Byte;
begin

  Result := False;
  ByteList := TList<Byte>.Create;
  try
    i := 1;
    while i <= Length(Input) do
    begin
      Ch := Input[i];

      // Handle string literals in quotes
      if (Ch = '''') or (Ch = '"') then
      begin
        QuoteChar := Ch;
        Inc(i); // Skip opening quote

        while (i <= Length(Input)) and (Input[i] <> QuoteChar) do
        begin
          if Input[i] = '\' then
          begin
            // Handle escape sequences
            Inc(i);
            if i <= Length(Input) then
            begin
              case Input[i] of
                'n':
                begin
                  ByteList.Add(10);
                  Inc(i);
                end;
                'r':
                begin
                  ByteList.Add(13);
                  Inc(i);
                end;
                't':
                begin
                  ByteList.Add(9);
                  Inc(i);
                end;
                '0':
                begin
                  ByteList.Add(0);
                  Inc(i);
                end;
                '\':
                begin
                  ByteList.Add(Ord('\'));
                  Inc(i);
                end;
                '''':
                begin
                  ByteList.Add(Ord(''''));
                  Inc(i);
                end;
                '"':
                begin
                  ByteList.Add(Ord('"'));
                  Inc(i);
                end;
                'x', 'X':  // Hex escape \xHH
                begin
                  if (i + 2) <= Length(Input) then
                  begin
                    HexStr := Copy(Input, i + 1, 2);
                    try
                      HexValue := StrToInt('$' + HexStr);
                      if (HexValue >= 0) and (HexValue <= 255) then
                      begin
                        ByteList.Add(Byte(HexValue));
                        Inc(i, 3);  // Skip x + two hex digits
                      end
                      else
                      begin
                        AddError(Format('Hex escape \x%s out of range (00-FF)', [HexStr]), LineNumber);
                        Exit;
                      end;
                    except
                      AddError(Format('Invalid hex escape: \x%s', [HexStr]), LineNumber);
                      Exit;
                    end;
                  end
                  else
                  begin
                    AddError('Incomplete hex escape at end of string', LineNumber);
                    Exit;
                  end;
                end;
                else
                begin
                  AddError(Format('Unknown escape sequence: \%s', [Input[i]]), LineNumber);
                  Exit;
                end;
              end;
            end
            else
            begin
              AddError('Incomplete escape sequence at end of string', LineNumber);
              Exit;
            end;
          end
          else
          begin
            // Normal character
            TempByte := Ord(Input[i]);
            ByteList.Add(TempByte);
            Inc(i);
          end;
        end;

        if (i > Length(Input)) or (Input[i] <> QuoteChar) then
        begin
          AddError('Unterminated string literal', LineNumber);
          Exit;
        end;
        Inc(i); // Skip closing quote

        // Skip optional comma after string
        while (i <= Length(Input)) and (Input[i] = ' ') do Inc(i);
        if (i <= Length(Input)) and (Input[i] = ',') then Inc(i);
      end
      // Handle numeric values (hex or decimal)
      else if Ch in ['0'..'9', '$', '-'] then
      begin
        NumStr := '';
        while (i <= Length(Input)) and
              (Input[i] in ['0'..'9', '$', 'A'..'F', 'a'..'f', 'x', 'X', '-']) do
        begin
          NumStr := NumStr + Input[i];
          Inc(i);
        end;

        try
          if NumStr.StartsWith('$') then
            Value := StrToInt('$' + Copy(NumStr, 2, Length(NumStr)))
          else if NumStr.StartsWith('0x') or NumStr.StartsWith('0X') then
            Value := StrToInt('$' + Copy(NumStr, 3, Length(NumStr)))
          else
            Value := StrToInt(NumStr);

          if (Value < 0) or (Value > 255) then
          begin
            AddError(Format('Byte value %d out of range (0-255)', [Value]), LineNumber);
            Exit;
          end;
          ByteList.Add(Byte(Value));
        except
          on E: EConvertError do
          begin
            AddError(Format('Invalid numeric value: %s', [NumStr]), LineNumber);
            Exit;
          end;
        end;

        // Skip optional comma after number
        while (i <= Length(Input)) and (Input[i] = ' ') do Inc(i);
        if (i <= Length(Input)) and (Input[i] = ',') then Inc(i);
      end
      // Skip whitespace and commas
      else if Ch in [' ', ','] then
        Inc(i)
      else
      begin
        AddError(Format('Unexpected character in .TEXT directive: %s', [Ch]), LineNumber);
        Exit;
      end;
    end;

    Bytes := ByteList.ToArray;
    Result := True;
  finally
    ByteList.Free;
  end;
end;

function TK16Assembler.ExtractTextOperands(const SourceLine: string): string;
var
  TextPos: Integer;
  AfterText: string;
  i: Integer;
  InQuote: Boolean;
  QuoteChar: Char;
  CommentPos: Integer;
  BackslashCount: Integer;
  j: Integer;
begin
  // Find .TEXT in the source line
  TextPos := Pos('.TEXT', UpperCase(SourceLine));
  if TextPos = 0 then
  begin
    Result := '';
    Exit;
  end;

  // Get everything after .TEXT
  AfterText := Copy(SourceLine, TextPos + 5, Length(SourceLine));

  // Trim leading whitespace only (preserve spacing in operands)
  AfterText := TrimLeft(AfterText);

  // Find comment semicolon (but not inside quotes)
  InQuote := False;
  QuoteChar := #0;
  CommentPos := 0;

  for i := 1 to Length(AfterText) do
  begin
    // Track quote state
    if not InQuote and ((AfterText[i] = '''') or (AfterText[i] = '"')) then
    begin
      InQuote := True;
      QuoteChar := AfterText[i];
    end
    else if InQuote and (AfterText[i] = QuoteChar) then
    begin
      // Check if it's escaped by counting preceding backslashes
      // An odd number of backslashes means the quote is escaped
      BackslashCount := 0;
      j := i - 1;
      while (j >= 1) and (AfterText[j] = '\') do
      begin
        Inc(BackslashCount);
        Dec(j);
      end;

      if (BackslashCount mod 2) = 1 then
        Continue  // Odd number of backslashes = escaped quote, stay in quote mode
      else
      begin
        InQuote := False;
        QuoteChar := #0;
      end;
    end
    // Found semicolon outside quotes
    else if (AfterText[i] = ';') and not InQuote then
    begin
      CommentPos := i;
      Break;
    end;
  end;

  // Remove comment if found
  if CommentPos > 0 then
    AfterText := Copy(AfterText, 1, CommentPos - 1);

  // Remove trailing whitespace
  Result := TrimRight(AfterText);
end;

function TK16Assembler.SupportsIMM5Mode(const Mnemonic: string): Boolean;
var
  Upper: string;
begin
  Upper := UpperCase(Mnemonic);

  { LOAD family supports IMM5 }
  if (Upper = 'LOADD') or (Upper = 'LOADB') or (Upper = 'LOADX') or
     (Upper = 'LOADY') or (Upper = 'LOADI') or (Upper = 'LOAD') then
  begin
    Result := True;
    Exit;
  end;

  { ALU family supports IMM5 }
  if (Upper = 'ADD') or (Upper = 'SUB') or (Upper = 'AND') or
     (Upper = 'OR') or (Upper = 'XOR') or (Upper = 'SHL') or
     (Upper = 'SHR') or (Upper = 'ROL') or (Upper = 'ROR') then
  begin
    Result := True;
    Exit;
  end;

  { CMP does NOT support IMM5 }
  { JMP/JSR do NOT support IMM5 }
  { BRANCH uses T8-5 as offset, not immediate }

  Result := False;
end;

function TK16Assembler.ResolveScopedLabel(const UpperDotName: string;
  const DerivOp: Char; out Value: UInt32): Boolean;
var
  Pair: TPair<string, TSymbol>;
  BaseValue: UInt32;
begin
  // Fallback: '.FOO' may be stored as 'SCOPE.FOO' - find by suffix match
  Result := False;
  for Pair in FSymbols do
  begin
    if Pair.Key.EndsWith(UpperDotName) then
    begin
      BaseValue := Pair.Value.Value;
      case DerivOp of
        '<': Value := BaseValue and $FFFF;
        '>': Value := (BaseValue shr 16) and $FF;
        else Value := BaseValue;
      end;
      Result := True;
      Exit;
    end;
  end;
end;

function TK16Assembler.DummySizeSymbolResolver(const SymName: string; LineNumber: Integer): UInt32;
var
  Symbol: TSymbol;
  UpperName: string;
  CleanName: string;
  DerivOp: Char;
  BaseValue: UInt32;
  IsExpr: Boolean;
begin
  UpperName := UpperCase(SymName);
  DerivOp := #0;
  Result := 0;

  if FSymbols.TryGetValue(UpperName, Symbol) then
  begin
    Result := Symbol.Value;
    Exit;
  end;

  // Scope suffix fallback for bare .LABEL references (no # prefix)
  if (Length(UpperName) > 0) and (UpperName[1] = '.') then
    if ResolveScopedLabel(UpperName, #0, Result) then
      Exit;

  if (Length(SymName) > 0) and (SymName[1] = '#') then
  begin
    CleanName := Copy(SymName, 2, Length(SymName) - 1);

    if (Length(CleanName) > 0) and (CleanName[1] in ['<', '>']) then
    begin
      DerivOp := CleanName[1];
      CleanName := Copy(CleanName, 2, Length(CleanName) - 1);
    end;

    UpperName := UpperCase(CleanName);
    if FSymbols.TryGetValue(UpperName, Symbol) then
    begin
      BaseValue := Symbol.Value;
      case DerivOp of
        '<': Result := BaseValue and $FFFF;
        '>': Result := (BaseValue shr 16) and $FF;
        else Result := BaseValue;
      end;
      Exit;
    end;

    // Scope suffix fallback: '.LABEL' may be stored as 'SCOPE.LABEL'
    if (Length(UpperName) > 0) and (UpperName[1] = '.') then
      if ResolveScopedLabel(UpperName, DerivOp, Result) then
        Exit;

    IsExpr := (Pos('+', CleanName) > 0) or
              (Pos('-', CleanName) > 1) or
              ((Length(CleanName) > 1) and (CleanName[1] = '-') and
               not (CleanName[2] in ['0'..'9', '$'])) or  // leading minus before symbol/paren
              (Pos('*', CleanName) > 0) or
              (Pos('/', CleanName) > 0) or
              (Pos('(', CleanName) > 0) or
              ((Length(CleanName) > 1) and (CleanName[Length(CleanName)] in ['w', 'W']));

    if IsExpr then
    begin
      Result := 1000;
      Exit;
    end;

    if (Length(CleanName) > 0) and (CleanName[1] in ['$', '-', '0'..'9']) then
    begin
      try
        if (Length(CleanName) > 0) and (CleanName[1] = '$') then
          Result := StrToInt('$' + Copy(CleanName, 2, Length(CleanName) - 1))
        else
          Result := StrToInt(CleanName);
        case DerivOp of
          '<': Result := Result and $FFFF;
          '>': Result := (Result shr 16) and $FF;
        end;
        Exit;
      except
      end;
    end;
  end;

  Result := 1000; // Forward reference - force IMM16
end;

function TK16Assembler.ExtractDirectiveContent(const SourceLine, DirectiveName: string): string;
var
  DirPos:     Integer;
  AfterDir:   string;
  i, j:       Integer;
  InQuote:    Boolean;
  QuoteChar:  Char;
  CommentPos: Integer;
  BackslashCount: Integer;
begin
  DirPos := Pos(UpperCase(DirectiveName), UpperCase(SourceLine));
  if DirPos = 0 then begin Result := ''; Exit; end;

  AfterDir := TrimLeft(Copy(SourceLine, DirPos + Length(DirectiveName), MaxInt));

  // Strip trailing comment, respecting quoted strings
  InQuote    := False;
  QuoteChar  := #0;
  CommentPos := 0;

  for i := 1 to Length(AfterDir) do
  begin
    if not InQuote and ((AfterDir[i] = '''') or (AfterDir[i] = '"')) then
    begin
      InQuote := True;
      QuoteChar := AfterDir[i];
    end
    else if InQuote and (AfterDir[i] = QuoteChar) then
    begin
      BackslashCount := 0;
      j := i - 1;
      while (j >= 1) and (AfterDir[j] = '\') do begin Inc(BackslashCount); Dec(j); end;
      if (BackslashCount mod 2) = 0 then begin InQuote := False; QuoteChar := #0; end;
    end
    else if (AfterDir[i] = ';') and not InQuote then
    begin
      CommentPos := i;
      Break;
    end;
  end;

  if CommentPos > 0 then
    AfterDir := Copy(AfterDir, 1, CommentPos - 1);

  Result := TrimRight(AfterDir);
end;

function TK16Assembler.EvalDirectiveArg(const ArgStr: string; LineNumber: Integer): Integer;
var
  Evaluator: TExpressionEvaluator;
begin
  Evaluator := TExpressionEvaluator.Create(FSymbols);
  try
    Result := Integer(Evaluator.Evaluate(Trim(ArgStr)));
    if Evaluator.HasError then
    begin
      AddError(Format('Directive argument error: %s', [Evaluator.ErrorMsg]), LineNumber);
      Result := 0;
    end;
  finally
    Evaluator.Free;
  end;
end;

function TK16Assembler.QualifyLabel(const RawLabel: string; LineNumber: Integer): string;
var
  Upper: string;
begin
  Upper := UpperCase(RawLabel);
  if (Length(Upper) > 0) and (Upper[1] = '.') then
  begin
    // Local label — must have an enclosing global
    if FCurrentGlobalLabel = '' then
    begin
      AddError(Format('Local label "%s" defined before any global label', [RawLabel]), LineNumber);
      Result := '';
      Exit;
    end;
    Result := FCurrentGlobalLabel + Upper;   // e.g. "FUNC_A.DONE"
  end
  else
  begin
    // Global label — update current scope
    FCurrentGlobalLabel := Upper;
    Result := Upper;
  end;
end;

procedure TK16Assembler.SetSourceFileName(const Value: string);
begin
  FSourceFileName := Value;
  if Value <> '' then
    FSourceDir := IncludeTrailingPathDelimiter(ExtractFilePath(ExpandFileName(Value)))
  else
    FSourceDir := '';
end;

procedure TK16Assembler.ExpandIncludes(Lines: TStringList; const CurrentDir: string;
                                        Depth: Integer; OpenFiles: TStringList;
                                        var LineMap: array of TLineInfo);
var
  i, j, k:    Integer;
  RawLine:    string;
  Token:      string;
  IncFile:    string;
  IncPath:    string;
  CommentPos: Integer;
  InQuote:    Boolean;
  QuoteChar:  Char;
  IncLines:   TStringList;
  IncDir:     string;
  InsertCount: Integer;
  NewMap:     array of TLineInfo;
  IncMap:     array of TLineInfo;
begin
  NewMap := nil;
  IncMap := nil;
  if Depth > 8 then
  begin
    AddError('.INCLUDE nesting exceeds maximum depth (8 levels)');
    Exit;
  end;

  i := 0;
  while i < Lines.Count do
  begin
    RawLine := Trim(Lines[i]);

    // Strip comment to find directive token
    InQuote    := False;
    QuoteChar  := #0;
    CommentPos := 0;
    for j := 1 to Length(RawLine) do
    begin
      if not InQuote and ((RawLine[j] = '"') or (RawLine[j] = '''')) then
      begin
        InQuote := True; QuoteChar := RawLine[j];
      end
      else if InQuote and (RawLine[j] = QuoteChar) then
        InQuote := False
      else if (RawLine[j] = ';') and not InQuote then
      begin
        CommentPos := j; Break;
      end;
    end;
    if CommentPos > 0 then
      RawLine := Trim(Copy(RawLine, 1, CommentPos - 1));

    // Check for .INCLUDE directive
    Token := '';
    j := 1;
    while (j <= Length(RawLine)) and not (RawLine[j] in [' ', #9]) do
    begin
      Token := Token + RawLine[j];
      Inc(j);
    end;

    if not SameText(Token, '.INCLUDE') then
    begin
      Inc(i);
      Continue;
    end;

    // Extract filename
    IncFile := Trim(Copy(RawLine, j, MaxInt));
    if (Length(IncFile) >= 2) and
       (IncFile[1] in ['"', '''']) and
       (IncFile[Length(IncFile)] = IncFile[1]) then
      IncFile := Copy(IncFile, 2, Length(IncFile) - 2);

    if IncFile = '' then
    begin
      AddError('.INCLUDE requires a filename');
      Inc(i);
      Continue;
    end;

    // Resolve path: prepend CurrentDir for any relative path (with or without subdirs).
    // Only skip if path is absolute (drive letter on Windows, or leading / or \).
    if ((Length(IncFile) >= 2) and (IncFile[2] = ':')) or
       ((Length(IncFile) >= 1) and (IncFile[1] in ['/', '\'])) then
      IncPath := IncFile              // absolute path — use as-is
    else
      IncPath := CurrentDir + IncFile; // relative path — anchor to source dir
    IncPath := ExpandFileName(IncPath);

    // Circular include check
    if OpenFiles.IndexOf(UpperCase(IncPath)) >= 0 then
    begin
      AddError(Format('Circular include detected: %s', [IncPath]));
      Inc(i);
      Continue;
    end;

    // File existence check
    if not FileExists(IncPath) then
    begin
      AddError(Format('.INCLUDE file not found: %s', [IncPath]));
      Inc(i);
      Continue;
    end;

    IncLines := TStringList.Create;
    try
      NotifyMessage(Format('Including: %s', [IncPath]));
      IncLines.LoadFromFile(IncPath);
      IncDir := IncludeTrailingPathDelimiter(ExtractFilePath(IncPath));

      // Build line map entries for included file (before recursive expand)
      SetLength(IncMap, IncLines.Count);
      for k := 0 to IncLines.Count - 1 do
      begin
        IncMap[k].FileName     := IncPath;
        IncMap[k].OriginalLine := k + 1;
      end;

      OpenFiles.Add(UpperCase(IncPath));
      ExpandIncludes(IncLines, IncDir, Depth + 1, OpenFiles, IncMap);
      OpenFiles.Delete(OpenFiles.Count - 1);

      // InsertCount = 2 banners + all included lines
      InsertCount := IncLines.Count + 2;

      // Rebuild line map: [0..i-1] + banner(no file) + IncMap + banner(no file) + [i+1..end]
      SetLength(NewMap, Length(LineMap) - 1 + InsertCount);

      // Copy entries before .INCLUDE line
      for k := 0 to i - 1 do
        NewMap[k] := LineMap[k];

      // BEGIN banner — no file/line (it's a synthetic comment)
      NewMap[i].FileName     := '';
      NewMap[i].OriginalLine := 0;

      // Included lines
      for k := 0 to IncLines.Count - 1 do
        NewMap[i + 1 + k] := IncMap[k];

      // END banner
      NewMap[i + 1 + IncLines.Count].FileName     := '';
      NewMap[i + 1 + IncLines.Count].OriginalLine := 0;

      // Copy entries after .INCLUDE line (skip the original .INCLUDE line)
      for k := i + 1 to Length(LineMap) - 1 do
        NewMap[k - 1 + InsertCount] := LineMap[k];

      // Apply map back — can't resize 'var array' directly, copy into FLineMap
      SetLength(FLineMap, Length(NewMap));
      for k := 0 to Length(NewMap) - 1 do
        FLineMap[k] := NewMap[k];
      // Note: LineMap parameter now stale — caller uses FLineMap directly

      // Splice lines
      Lines[i] := Format('; === BEGIN INCLUDE "%s" ===', [IncFile]);
      for j := IncLines.Count - 1 downto 0 do
        Lines.Insert(i + 1, IncLines[j]);
      Lines.Insert(i + 1 + IncLines.Count,
                   Format('; === END INCLUDE "%s" ===', [IncFile]));

      Inc(i, InsertCount);

    finally
      IncLines.Free;
    end;
  end;
end;

procedure TK16Assembler.DummySizeErrorReporter(const {%H-}Msg: string; {%H-}LineNumber: Integer);
begin
  // Silently ignore errors during size calculation
end;

procedure TK16Assembler.DummySizeWarningReporter(const {%H-}Msg: string; {%H-}LineNumber: Integer);
begin
  // Silently ignore warnings during size calculation
end;


end.
