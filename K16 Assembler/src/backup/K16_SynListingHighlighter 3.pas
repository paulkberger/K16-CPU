unit K16_SynListingHighlighter;

{$mode Delphi}

interface

uses
  SysUtils, Classes, Graphics,
  SynEditTypes, SynEditHighlighter;

type
  TtkListingTokenKind = (
    // Listing column tokens
    tkAddress,       // FF 0000
    tkMachineCode,   // C0E0
    tkColImmediate,  // 0010 or ---- in the immediate column
    tkOpMode,        // 18.0.2
    tkSeparator,     // ==== or ---- header separator lines
    // Source column tokens (same as source highlighter)
    tkComment,
    tkIdentifier,
    tkInstruction,
    tkRegister,
    tkNumber,
    tkHexNumber,
    tkImmediate,
    tkMemory,
    tkLabel,
    tkDirective,
    tkForthWord,
    tkNull,
    tkSpace,
    tkString,
    tkSymbol,
    tkUnknown
  );

  // Tracks which column region we are currently scanning on this line
  TListingLineState = (
    llsAddress,    // Expecting address field (FF 0000)
    llsCode,       // Expecting machine code field (C0E0)
    llsImmediate,  // Expecting immediate field (0010 or ----)
    llsOpMode,     // Expecting opmode field (18.0.2)
    llsSource,     // In the source column - use source-style scanning
    llsHeaderLine, // Separator/header line (=== or ---)
    llsTextLine    // Plain text line (starts with A-Z) - render all black
  );

  TRangeState = (rsUnknown);

  TSynK16ListingSyn = class(TSynCustomHighlighter)
  private
    fLine:        PChar;
    fLineLen:     Integer;
    fLineNumber:  Integer;
    Run:          LongInt;
    fTokenPos:    Integer;
    fTokenID:     TtkListingTokenKind;
    fRange:       TRangeState;
    fLineState:   TListingLineState;  // current column context, reset per line

    // Listing column attributes
    fAddressAttri:     TSynHighlighterAttributes;
    fMachineCodeAttri: TSynHighlighterAttributes;
    fColImmediateAttri:TSynHighlighterAttributes;
    fOpModeAttri:      TSynHighlighterAttributes;
    fSeparatorAttri:   TSynHighlighterAttributes;
    // Source column attributes (match source highlighter colours)
    fCommentAttri:     TSynHighlighterAttributes;
    fIdentifierAttri:  TSynHighlighterAttributes;
    fInstructionAttri: TSynHighlighterAttributes;
    fRegisterAttri:    TSynHighlighterAttributes;
    fNumberAttri:      TSynHighlighterAttributes;
    fHexNumberAttri:   TSynHighlighterAttributes;
    fImmediateAttri:   TSynHighlighterAttributes;
    fMemoryAttri:      TSynHighlighterAttributes;
    fLabelAttri:       TSynHighlighterAttributes;
    fDirectiveAttri:   TSynHighlighterAttributes;
    fForthWordAttri:   TSynHighlighterAttributes;
    fSpaceAttri:       TSynHighlighterAttributes;
    fStringAttri:      TSynHighlighterAttributes;
    fSymbolAttri:      TSynHighlighterAttributes;

    function IsInstruction(const Token: string): Boolean;
    function IsRegister(const Token: string): Boolean;
    function IsDirective(const Token: string): Boolean;
    function IsForthWord(const Token: string): Boolean;
    function GetTokenString: string;
    function IsHexChar(C: Char): Boolean;

    // Column-region procs
    procedure AddressProc;
    procedure MachineCodeProc;
    procedure ColImmediateProc;
    procedure OpModeProc;
    // Source column procs (same logic as source highlighter)
    procedure IdentProc;
    procedure CommentProc;
    procedure CRProc;
    procedure LFProc;
    procedure NullProc;
    procedure NumberProc;
    procedure HexNumberProc;
    procedure ImmediateProc;
    procedure MemoryProc;
    procedure LabelProc;
    procedure SpaceProc;
    procedure StringProc;
    procedure SymbolProc;
    procedure UnknownProc;
    procedure SeparatorProc;
    procedure SourceColumnProc;

  protected
    function GetSampleSource: string; override;
    function IsFilterStored: Boolean; override;

  public
    constructor Create(AOwner: TComponent); override;

    procedure SetLine(const NewValue: string; LineNumber: Integer); override;

    function GetDefaultAttribute(Index: Integer): TSynHighlighterAttributes; override;
    function GetEol: Boolean; override;
    function GetToken: string; override;
    procedure GetTokenEx(out TokenStart: PChar; out TokenLength: Integer); override;
    function GetTokenID: TtkListingTokenKind;
    function GetTokenAttribute: TSynHighlighterAttributes; override;
    function GetTokenKind: Integer; override;
    function GetTokenPos: Integer; override;
    procedure Next; override;
    procedure SetRange(Value: Pointer); override;
    procedure ResetRange; override;
    function GetRange: Pointer; override;
    class function GetLanguageName: string; override;

  published
    property AddressAttri:      TSynHighlighterAttributes read fAddressAttri      write fAddressAttri;
    property MachineCodeAttri:  TSynHighlighterAttributes read fMachineCodeAttri  write fMachineCodeAttri;
    property ColImmediateAttri: TSynHighlighterAttributes read fColImmediateAttri write fColImmediateAttri;
    property OpModeAttri:       TSynHighlighterAttributes read fOpModeAttri       write fOpModeAttri;
    property SeparatorAttri:    TSynHighlighterAttributes read fSeparatorAttri    write fSeparatorAttri;
    property CommentAttri:      TSynHighlighterAttributes read fCommentAttri      write fCommentAttri;
    property IdentifierAttri:   TSynHighlighterAttributes read fIdentifierAttri   write fIdentifierAttri;
    property InstructionAttri:  TSynHighlighterAttributes read fInstructionAttri  write fInstructionAttri;
    property RegisterAttri:     TSynHighlighterAttributes read fRegisterAttri     write fRegisterAttri;
    property NumberAttri:       TSynHighlighterAttributes read fNumberAttri       write fNumberAttri;
    property HexNumberAttri:    TSynHighlighterAttributes read fHexNumberAttri    write fHexNumberAttri;
    property ImmediateAttri:    TSynHighlighterAttributes read fImmediateAttri    write fImmediateAttri;
    property MemoryAttri:       TSynHighlighterAttributes read fMemoryAttri       write fMemoryAttri;
    property LabelAttri:        TSynHighlighterAttributes read fLabelAttri        write fLabelAttri;
    property DirectiveAttri:    TSynHighlighterAttributes read fDirectiveAttri    write fDirectiveAttri;
    property ForthWordAttri:    TSynHighlighterAttributes read fForthWordAttri    write fForthWordAttri;
    property SpaceAttri:        TSynHighlighterAttributes read fSpaceAttri        write fSpaceAttri;
    property StringAttri:       TSynHighlighterAttributes read fStringAttri       write fStringAttri;
    property SymbolAttri:       TSynHighlighterAttributes read fSymbolAttri       write fSymbolAttri;
  end;

implementation

const
  K16_INSTRUCTIONS: array[0..105] of string = (
    'NOP', 'HALT', 'NEG',
    'LOOKUP',
    'SHL', 'SHR', 'ASR', 'ROL', 'ROR',
    'SWAPB', 'HIGH', 'LOW',
    'SHL4', 'SHR4', 'ASR4', 'ASR8',
    'MULB', 'RECIP',
    'INC', 'DEC',
    'LEA',
    'SEQ', 'SNE', 'SCS', 'SHS', 'SCC', 'SLO', 'SLT', 'SGT', 'SGE', 'SLE',
    'MOVE', 'SWAP',
    'PUSH', 'PUSHD', 'PUSHDG', 'PUSHXY', 'PUSHI',
    'POP', 'POPD', 'POPDG', 'POPXY', 'POPI',
    'ADD', 'ADC', 'SUB', 'SBC', 'AND', 'OR', 'XOR', 'NOT',
    'CMP',
    'BRANCH',
    'BEQ', 'BNE', 'BCS', 'BCC', 'BHS', 'BLO', 'BMI', 'BPL',
    'BVS', 'BVC', 'BGE', 'BLT', 'BGT', 'BLE', 'BRA',
    'JMP', 'JMP24', 'JMP16', 'JMPT', 'JMPXY', 'JMPI',
    'CALL', 'CALL24', 'CALL16', 'CALLR', 'CALLXY', 'RET',
    'TRAP',
    'LOAD', 'LOADD', 'LOADB', 'LOADX', 'LOADY',
    'LOADI', 'LOADXY', 'LOADP', 'LOADPB',
    'STORE', 'STORED', 'STOREB', 'STOREX', 'STOREY',
    'STOREI', 'STOREXY', 'STOREP', 'STOREPB',
    'DINT', 'EINT', 'RTI', 'RETI', 'INT',
    'SEC', 'CLC'
  );

  K16_REGISTERS: array[0..23] of string = (
    'D0', 'D1', 'D2', 'D3',
    'X0', 'X1', 'X2', 'X3',
    'Y0', 'Y1', 'Y2', 'Y3',
    'XY0', 'XY1', 'XY2', 'XY3',
    'PC', 'PCH', 'PCL', 'SR', 'ORDB', 'ORAB', 'T8', 'T16'
  );

  K16_DIRECTIVES: array[0..11] of string = (
    'BASE', 'EQU', 'ORG', 'WORD', 'BYTE', 'TEXT', 'ALIGN',
    'DS', 'IF', 'ENDIF', 'INCLUDE', '='
  );

  FORTH_WORDS: array[0..47] of string = (
    'fDUP', 'fDROP', 'fSWAP', 'fOVER', 'fROT', 'fNROT', 'fNIP', 'fTUCK',
    'f2DUP', 'f2DROP', 'f2SWAP', 'f2OVER', 'fPICK', 'fROLL', 'fDEPTH', 'fCLEAR',
    'f@', 'f!', 'fC@', 'fC!', 'f+!', 'f2@', 'f2!', 'fFILL',
    'f>R', 'fR>', 'fR@', 'fEXECUTE', 'fEXIT', 'fCALL', 'fBRANCH', 'f?BRANCH',
    'f=', 'f<>', 'f<', 'f>', 'f<=', 'f>=', 'f0=', 'f0<>',
    'fEMIT', 'fKEY', 'fCR', 'fSPACE', 'f.', 'fU.', 'f.S', 'fWORDS'
  );

{ TSynK16ListingSyn }

constructor TSynK16ListingSyn.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);

  // Listing column attributes
  fAddressAttri := TSynHighlighterAttributes.Create('Address');
  fAddressAttri.Foreground := clTeal;
  AddAttribute(fAddressAttri);

  fMachineCodeAttri := TSynHighlighterAttributes.Create('MachineCode');
  fMachineCodeAttri.Foreground := clMaroon;
  AddAttribute(fMachineCodeAttri);

  fColImmediateAttri := TSynHighlighterAttributes.Create('ColImmediate');
  fColImmediateAttri.Foreground := clGray;
  AddAttribute(fColImmediateAttri);

  fOpModeAttri := TSynHighlighterAttributes.Create('OpMode');
  fOpModeAttri.Foreground := clGray;
  AddAttribute(fOpModeAttri);

  fSeparatorAttri := TSynHighlighterAttributes.Create('Separator');
  fSeparatorAttri.Foreground := clSilver;
  AddAttribute(fSeparatorAttri);

  // Source column attributes - same colours as TSynK16Syn
  fCommentAttri := TSynHighlighterAttributes.Create('Comment');
  fCommentAttri.Style := [fsItalic];
  fCommentAttri.Foreground := $3C8031;
  AddAttribute(fCommentAttri);

  fIdentifierAttri := TSynHighlighterAttributes.Create('Identifier');
  fIdentifierAttri.Foreground := clBlack;
  AddAttribute(fIdentifierAttri);

  fInstructionAttri := TSynHighlighterAttributes.Create('Instruction');
  fInstructionAttri.Foreground := clNavy;
  AddAttribute(fInstructionAttri);

  fRegisterAttri := TSynHighlighterAttributes.Create('Register');
  fRegisterAttri.Foreground := clPurple;
  AddAttribute(fRegisterAttri);

  fNumberAttri := TSynHighlighterAttributes.Create('Number');
  fNumberAttri.Foreground := clBlack;
  AddAttribute(fNumberAttri);

  fHexNumberAttri := TSynHighlighterAttributes.Create('HexNumber');
  fHexNumberAttri.Foreground := clMaroon;
  AddAttribute(fHexNumberAttri);

  fImmediateAttri := TSynHighlighterAttributes.Create('Immediate');
  fImmediateAttri.Foreground := $625d5d;
  fImmediateAttri.Style := [fsBold];
  AddAttribute(fImmediateAttri);

  fMemoryAttri := TSynHighlighterAttributes.Create('Memory');
  fMemoryAttri.Foreground := clTeal;
  fMemoryAttri.Style := [fsBold];
  AddAttribute(fMemoryAttri);

  fLabelAttri := TSynHighlighterAttributes.Create('Label');
  fLabelAttri.Foreground := clNavy;
  fLabelAttri.Style := [fsBold];
  AddAttribute(fLabelAttri);

  fDirectiveAttri := TSynHighlighterAttributes.Create('Directive');
  fDirectiveAttri.Foreground := clBlack;
  fDirectiveAttri.Style := [fsBold];
  AddAttribute(fDirectiveAttri);

  fForthWordAttri := TSynHighlighterAttributes.Create('ForthWord');
  fForthWordAttri.Foreground := clFuchsia;
  fForthWordAttri.Style := [fsBold];
  AddAttribute(fForthWordAttri);

  fSpaceAttri := TSynHighlighterAttributes.Create('Space');
  AddAttribute(fSpaceAttri);

  fStringAttri := TSynHighlighterAttributes.Create('String');
  fStringAttri.Foreground := clRed;
  AddAttribute(fStringAttri);

  fSymbolAttri := TSynHighlighterAttributes.Create('Symbol');
  AddAttribute(fSymbolAttri);

  SetAttributesOnChange(DefHighlightChange);
  fDefaultFilter := 'K16 Listing files (*.lst)|*.lst';
end;

procedure TSynK16ListingSyn.SetLine(const NewValue: string; LineNumber: Integer);
var
  P: PChar;
begin
  inherited SetLine(NewValue, LineNumber);
  fLineNumber := LineNumber;
  fLine    := PChar(NewValue);
  fLineLen := Length(NewValue);
  Run      := 0;

  // Determine line type up front so Next knows which column region to expect.
  // An addressed line starts with two hex digits then a space then four hex digits.
  // A separator/header line starts with '=' or '-' (after optional spaces).
  // Everything else is a source-only line - skip straight to source scanning.
  P := fLine;
  if IsHexChar(P[0]) and IsHexChar(P[1]) and (P[2] = ' ') and
     IsHexChar(P[3]) and IsHexChar(P[4]) and IsHexChar(P[5]) and IsHexChar(P[6]) then
    fLineState := llsAddress
  else
  begin
    if fLine[0] in ['A'..'Z', 'a'..'z'] then
      fLineState := llsTextLine
    else
    begin
      // Scan past leading spaces to check for separator chars
      while P^ = ' ' do Inc(P);
      if P^ in ['=', '-'] then
        fLineState := llsHeaderLine
      else
        fLineState := llsSource;
    end;
  end;

  Next;
end;

function TSynK16ListingSyn.IsHexChar(C: Char): Boolean;
begin
  Result := C in ['0'..'9', 'A'..'F', 'a'..'f'];
end;

function TSynK16ListingSyn.GetTokenString: string;
begin
  SetString(Result, fLine + fTokenPos, Run - fTokenPos);
end;

function TSynK16ListingSyn.GetToken: string;
begin
  SetString(Result, fLine + fTokenPos, Run - fTokenPos);
end;

procedure TSynK16ListingSyn.GetTokenEx(out TokenStart: PChar; out TokenLength: Integer);
begin
  TokenStart  := fLine + fTokenPos;
  TokenLength := Run - fTokenPos;
end;

function TSynK16ListingSyn.GetTokenPos: Integer;
begin
  Result := fTokenPos;
end;

{ ---- Listing column procs ---- }

procedure TSynK16ListingSyn.AddressProc;
// Scans: "FF 0000" (two hex, space, four hex)
begin
  fTokenID := tkAddress;
  // two high bytes
  while IsHexChar(fLine[Run]) do Inc(Run);
  // space separator within address
  if fLine[Run] = ' ' then Inc(Run);
  // four low bytes
  while IsHexChar(fLine[Run]) do Inc(Run);
  fLineState := llsCode;
end;

procedure TSynK16ListingSyn.MachineCodeProc;
// Scans up to 4 hex chars (the encoded word)
begin
  fTokenID := tkMachineCode;
  while IsHexChar(fLine[Run]) do Inc(Run);
  fLineState := llsImmediate;
end;

procedure TSynK16ListingSyn.ColImmediateProc;
// Scans 4 hex digits or "----"
begin
  fTokenID := tkColImmediate;
  if fLine[Run] = '-' then
    while fLine[Run] = '-' do Inc(Run)
  else
    while IsHexChar(fLine[Run]) do Inc(Run);
  fLineState := llsOpMode;
end;

procedure TSynK16ListingSyn.OpModeProc;
// Scans "N.N.N" opcode/mode/bank field
begin
  fTokenID := tkOpMode;
  while fLine[Run] in ['0'..'9', '.'] do Inc(Run);
  fLineState := llsSource;
end;

procedure TSynK16ListingSyn.SeparatorProc;
begin
  fTokenID := tkSeparator;
  while fLine[Run] in ['=', '-'] do Inc(Run);
end;

{ ---- Source column procs (identical logic to TSynK16Syn) ---- }

function TSynK16ListingSyn.IsInstruction(const Token: string): Boolean;
var
  i: Integer;
  U: string;
begin
  U := UpperCase(Token);
  for i := 0 to High(K16_INSTRUCTIONS) do
    if U = K16_INSTRUCTIONS[i] then Exit(True);
  Result := False;
end;

function TSynK16ListingSyn.IsRegister(const Token: string): Boolean;
var
  i: Integer;
  U: string;
begin
  U := UpperCase(Token);
  for i := 0 to High(K16_REGISTERS) do
    if U = K16_REGISTERS[i] then Exit(True);
  Result := False;
end;

function TSynK16ListingSyn.IsDirective(const Token: string): Boolean;
var
  i: Integer;
  U: string;
begin
  U := UpperCase(Token);
  for i := 0 to High(K16_DIRECTIVES) do
    if U = K16_DIRECTIVES[i] then Exit(True);
  Result := False;
end;

function TSynK16ListingSyn.IsForthWord(const Token: string): Boolean;
var
  i: Integer;
  U: string;
begin
  U := UpperCase(Token);
  for i := 0 to High(FORTH_WORDS) do
    if UpperCase(FORTH_WORDS[i]) = U then Exit(True);
  Result := False;
end;

procedure TSynK16ListingSyn.IdentProc;
var
  Token: string;
begin
  while fLine[Run] in ['A'..'Z', 'a'..'z', '0'..'9', '_'] do Inc(Run);
  Token := GetTokenString;
  if IsInstruction(Token) then      fTokenID := tkInstruction
  else if IsRegister(Token) then    fTokenID := tkRegister
  else if IsDirective(Token) then   fTokenID := tkDirective
  else if IsForthWord(Token) then   fTokenID := tkForthWord
  else                              fTokenID := tkIdentifier;
end;

procedure TSynK16ListingSyn.CommentProc;
begin
  fTokenID := tkComment;
  while not (fLine[Run] in [#0, #10, #13]) do Inc(Run);
end;

procedure TSynK16ListingSyn.CRProc;
begin
  fTokenID := tkSpace;
  Inc(Run);
  if fLine[Run] = #10 then Inc(Run);
end;

procedure TSynK16ListingSyn.LFProc;
begin
  fTokenID := tkSpace;
  Inc(Run);
end;

procedure TSynK16ListingSyn.NullProc;
begin
  fTokenID := tkNull;
  Inc(Run);
end;

procedure TSynK16ListingSyn.NumberProc;
begin
  fTokenID := tkNumber;
  while fLine[Run] in ['0'..'9'] do Inc(Run);
end;

procedure TSynK16ListingSyn.HexNumberProc;
begin
  fTokenID := tkHexNumber;
  Inc(Run); // skip '$'
  while fLine[Run] in ['0'..'9', 'A'..'F', 'a'..'f', '_'] do Inc(Run);
end;

procedure TSynK16ListingSyn.ImmediateProc;
begin
  fTokenID := tkImmediate;
  Inc(Run); // skip '#'
  if fLine[Run] in ['>', '<'] then Inc(Run);
  if fLine[Run] = '$' then
  begin
    Inc(Run);
    while fLine[Run] in ['0'..'9', 'A'..'F', 'a'..'f', '_'] do Inc(Run);
  end
  else if fLine[Run] = '-' then
  begin
    Inc(Run);
    while fLine[Run] in ['0'..'9'] do Inc(Run);
  end
  else if fLine[Run] in ['A'..'Z', 'a'..'z', '_'] then
    while fLine[Run] in ['A'..'Z', 'a'..'z', '0'..'9', '_'] do Inc(Run)
  else
    while fLine[Run] in ['0'..'9'] do Inc(Run);
end;

procedure TSynK16ListingSyn.MemoryProc;
var
  BracketCount: Integer;
begin
  fTokenID := tkMemory;
  BracketCount := 0;
  repeat
    if fLine[Run] = '[' then Inc(BracketCount)
    else if fLine[Run] = ']' then Dec(BracketCount);
    Inc(Run);
  until (BracketCount = 0) or (fLine[Run] in [#0, #10, #13]);
end;

procedure TSynK16ListingSyn.LabelProc;
begin
  fTokenID := tkLabel;
  while fLine[Run] in ['A'..'Z', 'a'..'z', '0'..'9', '_'] do Inc(Run);
  if fLine[Run] = ':' then Inc(Run);
end;

procedure TSynK16ListingSyn.SpaceProc;
begin
  fTokenID := tkSpace;
  while fLine[Run] in [#1..#32] do Inc(Run);
end;

procedure TSynK16ListingSyn.StringProc;
var
  QuoteChar: Char;
begin
  fTokenID := tkString;
  QuoteChar := fLine[Run];
  Inc(Run);
  while not (fLine[Run] in [#0, #10, #13]) do
  begin
    if fLine[Run] = QuoteChar then begin Inc(Run); Break; end;
    Inc(Run);
  end;
end;

procedure TSynK16ListingSyn.SymbolProc;
begin
  fTokenID := tkSymbol;
  Inc(Run);
end;

procedure TSynK16ListingSyn.UnknownProc;
begin
  fTokenID := tkUnknown;
  Inc(Run);
end;

{ ---- Main dispatcher ---- }

procedure TSynK16ListingSyn.Next;
var
  SaveRun: Integer;
begin
  fTokenPos := Run;

  case fLine[Run] of
    #0:  begin NullProc; Exit; end;
    #10: begin LFProc;   Exit; end;
    #13: begin CRProc;   Exit; end;
  end;

  // Whitespace is always whitespace regardless of column
  if fLine[Run] in [#1..#32] then
  begin
    SpaceProc;
    Exit;
  end;

  // Dispatch based on which column region we are in
  case fLineState of

    llsAddress:
      if IsHexChar(fLine[Run]) then
        AddressProc
      else
        UnknownProc;

    llsCode:
      if IsHexChar(fLine[Run]) then
        MachineCodeProc
      else
      begin
        fLineState := llsSource;
        SourceColumnProc;
      end;

    llsImmediate:
      if IsHexChar(fLine[Run]) or (fLine[Run] = '-') then
        ColImmediateProc
      else
      begin
        fLineState := llsSource;
        SourceColumnProc;
      end;

    llsOpMode:
      if fLine[Run] in ['0'..'9'] then
        OpModeProc
      else
      begin
        fLineState := llsSource;
        SourceColumnProc;
      end;

    llsHeaderLine:
      begin
        if fLine[Run] in ['=', '-'] then
          SeparatorProc
        else
          UnknownProc;
      end;

    llsTextLine:
      begin
        // Consume to end of line as plain identifier/unknown - all black
        fTokenID := tkIdentifier;
        while not (fLine[Run] in [#0, #10, #13]) do Inc(Run);
      end;

    llsSource:
      SourceColumnProc;

  end; // case fLineState

  inherited;
end;

procedure TSynK16ListingSyn.SourceColumnProc;
var
  SaveRun: Integer;
begin
  case fLine[Run] of
          ';':                         CommentProc;
          '#':                         ImmediateProc;
          '$':                         HexNumberProc;
          '[':                         MemoryProc;
          '"', '''':                   StringProc;
          '0'..'9':                    NumberProc;
          '.':
            begin
              Inc(Run);
              while fLine[Run] in ['A'..'Z', 'a'..'z', '0'..'9', '_'] do Inc(Run);
              fTokenID := tkDirective;
            end;
          'A'..'Z', 'a'..'z', '_':
            begin
              SaveRun := Run;
              while fLine[Run] in ['A'..'Z', 'a'..'z', '0'..'9', '_'] do Inc(Run);
              if fLine[Run] = ':' then
              begin
                Run := SaveRun;
                LabelProc;
              end
              else
              begin
                Run := SaveRun;
                IdentProc;
              end;
            end;
    '+', '-', '*', '/', '=', '<', '>', '(', ')', ',', ':': SymbolProc;
    else
      UnknownProc;
  end;
end;

function TSynK16ListingSyn.GetDefaultAttribute(Index: Integer): TSynHighlighterAttributes;
begin
  case Index of
    SYN_ATTR_COMMENT:    Result := fCommentAttri;
    SYN_ATTR_IDENTIFIER: Result := fIdentifierAttri;
    SYN_ATTR_KEYWORD:    Result := fInstructionAttri;
    SYN_ATTR_STRING:     Result := fStringAttri;
    SYN_ATTR_WHITESPACE: Result := fSpaceAttri;
    SYN_ATTR_SYMBOL:     Result := fSymbolAttri;
    else Result := nil;
  end;
end;

function TSynK16ListingSyn.GetEol: Boolean;
begin
  Result := (fTokenID = tkNull) and (Run >= fLineLen);
end;

function TSynK16ListingSyn.GetTokenID: TtkListingTokenKind;
begin
  Result := fTokenID;
end;

function TSynK16ListingSyn.GetTokenAttribute: TSynHighlighterAttributes;
begin
  case fTokenID of
    tkAddress:       Result := fAddressAttri;
    tkMachineCode:   Result := fMachineCodeAttri;
    tkColImmediate:  Result := fColImmediateAttri;
    tkOpMode:        Result := fOpModeAttri;
    tkSeparator:     Result := fSeparatorAttri;
    tkComment:       Result := fCommentAttri;
    tkIdentifier:    Result := fIdentifierAttri;
    tkInstruction:   Result := fInstructionAttri;
    tkRegister:      Result := fRegisterAttri;
    tkNumber:        Result := fNumberAttri;
    tkHexNumber:     Result := fHexNumberAttri;
    tkImmediate:     Result := fImmediateAttri;
    tkMemory:        Result := fMemoryAttri;
    tkLabel:         Result := fLabelAttri;
    tkDirective:     Result := fDirectiveAttri;
    tkForthWord:     Result := fForthWordAttri;
    tkSpace:         Result := fSpaceAttri;
    tkString:        Result := fStringAttri;
    tkSymbol:        Result := fSymbolAttri;
    else             Result := fIdentifierAttri;
  end;
end;

function TSynK16ListingSyn.GetTokenKind: Integer;
begin
  Result := Ord(fTokenID);
end;

function TSynK16ListingSyn.GetRange: Pointer;
begin
  Result := Pointer(PtrUInt(fRange));
end;

procedure TSynK16ListingSyn.SetRange(Value: Pointer);
begin
  fRange := TRangeState(PtrUInt(Value));
end;

procedure TSynK16ListingSyn.ResetRange;
begin
  fRange := rsUnknown;
end;

function TSynK16ListingSyn.IsFilterStored: Boolean;
begin
  Result := fDefaultFilter <> 'K16 Listing files (*.lst)|*.lst';
end;

class function TSynK16ListingSyn.GetLanguageName: string;
begin
  Result := 'K16 Assembly Listing';
end;

function TSynK16ListingSyn.GetSampleSource: string;
begin
  Result :=
    'K16 CPU Assembly Listing'#13#10 +
    '========================'#13#10 +
    #13#10 +
    'Address      Code     Immediate OP.M.B Source'#13#10 +
    '------------ -------- --------- ------ ----'#13#10 +
    '                                      RESET_VECTOR .EQU $FF0000'#13#10 +
    '                                        RESET:'#13#10 +
    'FF 0000      C0E0     ----      18.0.2     LOADI D0, #$FF   ; init'#13#10 +
    'FF 0002      90FF     0010      12.0.4     JMP   MAIN'#13#10;
end;

end.
