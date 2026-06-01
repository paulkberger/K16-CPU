unit K16_SynEditHighlighter;

{$mode Delphi}

interface

uses
  SysUtils, Classes, Graphics,
  SynEditTypes, SynEditHighlighter;

type
  TtkTokenKind = (
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

  TRangeState = (rsUnknown, rsComment, rsString);

  TSynK16Syn = class(TSynCustomHighlighter)
  private
    // These fields must be declared here - TSynCustomHighlighter does NOT provide them
    fLine:      PChar;
    fLineLen:   Integer;
    fLineNumber: Integer;
    Run:        LongInt;
    fTokenPos:  Integer;
    fTokenID:   TtkTokenKind;

    fRange: TRangeState;

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
    function GetTokenID: TtkTokenKind;
    function GetTokenAttribute: TSynHighlighterAttributes; override;
    function GetTokenKind: Integer; override;
    function GetTokenPos: Integer; override;
    procedure Next; override;
    procedure SetRange(Value: Pointer); override;
    procedure ResetRange; override;
    function GetRange: Pointer; override;
    class function GetLanguageName: string; override;

  published
    property CommentAttri:     TSynHighlighterAttributes read fCommentAttri     write fCommentAttri;
    property IdentifierAttri:  TSynHighlighterAttributes read fIdentifierAttri  write fIdentifierAttri;
    property InstructionAttri: TSynHighlighterAttributes read fInstructionAttri write fInstructionAttri;
    property RegisterAttri:    TSynHighlighterAttributes read fRegisterAttri    write fRegisterAttri;
    property NumberAttri:      TSynHighlighterAttributes read fNumberAttri      write fNumberAttri;
    property HexNumberAttri:   TSynHighlighterAttributes read fHexNumberAttri   write fHexNumberAttri;
    property ImmediateAttri:   TSynHighlighterAttributes read fImmediateAttri   write fImmediateAttri;
    property MemoryAttri:      TSynHighlighterAttributes read fMemoryAttri      write fMemoryAttri;
    property LabelAttri:       TSynHighlighterAttributes read fLabelAttri       write fLabelAttri;
    property DirectiveAttri:   TSynHighlighterAttributes read fDirectiveAttri   write fDirectiveAttri;
    property ForthWordAttri:   TSynHighlighterAttributes read fForthWordAttri   write fForthWordAttri;
    property SpaceAttri:       TSynHighlighterAttributes read fSpaceAttri       write fSpaceAttri;
    property StringAttri:      TSynHighlighterAttributes read fStringAttri      write fStringAttri;
    property SymbolAttri:      TSynHighlighterAttributes read fSymbolAttri      write fSymbolAttri;
  end;

implementation

const
  K16_INSTRUCTIONS: array[0..107] of string = (
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
    'LOADI', 'LOADXY', 'LOADP', 'LOADPB', 'LOADZ', 'LOADZB',
    'STORE', 'STORED', 'STOREB', 'STOREX', 'STOREY',
    'STOREI', 'STOREXY', 'STOREP', 'STOREPB', 'STOREZ', 'STOREZB',
    'DINT', 'EINT', 'RTI', 'RETI', 'INT',
    'SEC', 'CLC'
  );

  K16_REGISTERS: array[0..23] of string = (
    'D0', 'D1', 'D2', 'D3',
    'X0', 'X1', 'X2', 'X3',
    'Y0', 'Y1', 'Y2', 'Y3',
    'XY0', 'XY1', 'XY2', 'XY3',
    'PC', 'PCH', 'PCL',
    'SR', 'ORDB', 'ORAB',
    'T8', 'T16'
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

{ TSynK16Syn }

constructor TSynK16Syn.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);

  fCommentAttri := TSynHighlighterAttributes.Create('Comment');
  fCommentAttri.Style := [fsItalic];
  fCommentAttri.Foreground := $3C8031;
  AddAttribute(fCommentAttri);

  fIdentifierAttri := TSynHighlighterAttributes.Create('Identifier');
  AddAttribute(fIdentifierAttri);

  fInstructionAttri := TSynHighlighterAttributes.Create('Instruction');
  fInstructionAttri.Foreground := clNavy;
  AddAttribute(fInstructionAttri);

  fRegisterAttri := TSynHighlighterAttributes.Create('Register');
  fRegisterAttri.Foreground := clPurple;
  AddAttribute(fRegisterAttri);

  fNumberAttri := TSynHighlighterAttributes.Create('Number');
  fNumberAttri.Foreground := clBlue;
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
  fDefaultFilter := 'K16 Assembly files (*.k16, *.asm)|*.k16;*.asm';
end;

procedure TSynK16Syn.SetLine(const NewValue: string; LineNumber: Integer);
begin
  inherited SetLine(NewValue, LineNumber);
  fLineNumber := LineNumber;
  fLine := PChar(NewValue);
  fLineLen := Length(NewValue);
  Run := 0;
  Next;
end;

function TSynK16Syn.GetTokenString: string;
begin
  SetString(Result, fLine + fTokenPos, Run - fTokenPos);
end;

function TSynK16Syn.GetToken: string;
begin
  SetString(Result, fLine + fTokenPos, Run - fTokenPos);
end;

procedure TSynK16Syn.GetTokenEx(out TokenStart: PChar; out TokenLength: Integer);
begin
  TokenStart  := fLine + fTokenPos;
  TokenLength := Run - fTokenPos;
end;

function TSynK16Syn.GetTokenPos: Integer;
begin
  Result := fTokenPos;
end;

function TSynK16Syn.IsInstruction(const Token: string): Boolean;
var
  i: Integer;
  UpperToken: string;
begin
  UpperToken := UpperCase(Token);
  for i := 0 to High(K16_INSTRUCTIONS) do
    if UpperToken = K16_INSTRUCTIONS[i] then
      Exit(True);
  Result := False;
end;

function TSynK16Syn.IsRegister(const Token: string): Boolean;
var
  i: Integer;
  UpperToken: string;
begin
  UpperToken := UpperCase(Token);
  for i := 0 to High(K16_REGISTERS) do
    if UpperToken = K16_REGISTERS[i] then
      Exit(True);
  Result := False;
end;

function TSynK16Syn.IsDirective(const Token: string): Boolean;
var
  i: Integer;
  UpperToken: string;
begin
  UpperToken := UpperCase(Token);
  for i := 0 to High(K16_DIRECTIVES) do
    if UpperToken = K16_DIRECTIVES[i] then
      Exit(True);
  Result := False;
end;

function TSynK16Syn.IsForthWord(const Token: string): Boolean;
var
  i: Integer;
  UpperToken: string;
begin
  UpperToken := UpperCase(Token);
  for i := 0 to High(FORTH_WORDS) do
    if UpperCase(FORTH_WORDS[i]) = UpperToken then
      Exit(True);
  Result := False;
end;

procedure TSynK16Syn.IdentProc;
var
  Token: string;
begin
  while fLine[Run] in ['A'..'Z', 'a'..'z', '0'..'9', '_'] do
    Inc(Run);
  Token := GetTokenString;
  if IsInstruction(Token) then
    fTokenID := tkInstruction
  else if IsRegister(Token) then
    fTokenID := tkRegister
  else if IsDirective(Token) then
    fTokenID := tkDirective
  else if IsForthWord(Token) then
    fTokenID := tkForthWord
  else
    fTokenID := tkIdentifier;
end;

procedure TSynK16Syn.CommentProc;
begin
  fTokenID := tkComment;
  while not (fLine[Run] in [#0, #10, #13]) do
    Inc(Run);
end;

procedure TSynK16Syn.CRProc;
begin
  fTokenID := tkSpace;
  Inc(Run);
  if fLine[Run] = #10 then Inc(Run);
end;

procedure TSynK16Syn.LFProc;
begin
  fTokenID := tkSpace;
  Inc(Run);
end;

procedure TSynK16Syn.NullProc;
begin
  fTokenID := tkNull;
  Inc(Run);
end;

procedure TSynK16Syn.NumberProc;
begin
  fTokenID := tkNumber;
  while fLine[Run] in ['0'..'9'] do
    Inc(Run);
end;

procedure TSynK16Syn.HexNumberProc;
begin
  fTokenID := tkHexNumber;
  Inc(Run); // Skip '$'
  while fLine[Run] in ['0'..'9', 'A'..'F', 'a'..'f', '_'] do
    Inc(Run);
end;

procedure TSynK16Syn.ImmediateProc;
begin
  fTokenID := tkImmediate;
  Inc(Run); // Skip '#'
  if fLine[Run] in ['>', '<'] then
    Inc(Run);
  if fLine[Run] = '$' then
  begin
    Inc(Run);
    while fLine[Run] in ['0'..'9', 'A'..'F', 'a'..'f', '_'] do
      Inc(Run);
  end
  else if fLine[Run] = '-' then
  begin
    Inc(Run);
    while fLine[Run] in ['0'..'9'] do
      Inc(Run);
  end
  else if fLine[Run] in ['A'..'Z', 'a'..'z', '_'] then
  begin
    while fLine[Run] in ['A'..'Z', 'a'..'z', '0'..'9', '_'] do
      Inc(Run);
  end
  else
  begin
    while fLine[Run] in ['0'..'9'] do
      Inc(Run);
  end;
end;

procedure TSynK16Syn.MemoryProc;
var
  BracketCount: Integer;
begin
  fTokenID := tkMemory;
  BracketCount := 0;
  repeat
    if fLine[Run] = '[' then
      Inc(BracketCount)
    else if fLine[Run] = ']' then
      Dec(BracketCount);
    Inc(Run);
  until (BracketCount = 0) or (fLine[Run] in [#0, #10, #13]);
end;

procedure TSynK16Syn.LabelProc;
begin
  fTokenID := tkLabel;
  while fLine[Run] in ['A'..'Z', 'a'..'z', '0'..'9', '_'] do
    Inc(Run);
  if fLine[Run] = ':' then
    Inc(Run);
end;

procedure TSynK16Syn.SpaceProc;
begin
  fTokenID := tkSpace;
  while fLine[Run] in [#1..#32] do
    Inc(Run);
end;

procedure TSynK16Syn.StringProc;
var
  QuoteChar: Char;
begin
  fTokenID := tkString;
  QuoteChar := fLine[Run];
  Inc(Run);
  while not (fLine[Run] in [#0, #10, #13]) do
  begin
    if fLine[Run] = QuoteChar then
    begin
      Inc(Run);
      Break;
    end;
    Inc(Run);
  end;
end;

procedure TSynK16Syn.SymbolProc;
begin
  fTokenID := tkSymbol;
  Inc(Run);
end;

procedure TSynK16Syn.UnknownProc;
begin
  fTokenID := tkUnknown;
  Inc(Run);
end;

procedure TSynK16Syn.Next;
var
  SaveRun: Integer;
begin
  fTokenPos := Run;
  case fLine[Run] of
    #0:                          NullProc;
    #10:                         LFProc;
    #13:                         CRProc;
    #1..#9, #11, #12, #14..#32: SpaceProc;
    ';':                         CommentProc;
    '#':                         ImmediateProc;
    '$':                         HexNumberProc;
    '[':                         MemoryProc;
    '"', '''':                   StringProc;
    '0'..'9':                    NumberProc;
    '.':
      begin
        Inc(Run);
        while fLine[Run] in ['A'..'Z', 'a'..'z', '0'..'9', '_'] do
          Inc(Run);
        fTokenID := tkDirective;
      end;
    'A'..'Z', 'a'..'z', '_':
      begin
        SaveRun := Run;
        while fLine[Run] in ['A'..'Z', 'a'..'z', '0'..'9', '_'] do
          Inc(Run);
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
  inherited;
end;

function TSynK16Syn.GetDefaultAttribute(Index: Integer): TSynHighlighterAttributes;
begin
  case Index of
    SYN_ATTR_COMMENT:    Result := fCommentAttri;
    SYN_ATTR_IDENTIFIER: Result := fIdentifierAttri;
    SYN_ATTR_KEYWORD:    Result := fInstructionAttri;
    SYN_ATTR_STRING:     Result := fStringAttri;
    SYN_ATTR_WHITESPACE: Result := fSpaceAttri;
    SYN_ATTR_SYMBOL:     Result := fSymbolAttri;
    else
      Result := nil;
  end;
end;

function TSynK16Syn.GetEol: Boolean;
begin
  Result := (fTokenID = tkNull) and (Run >= fLineLen);
end;

function TSynK16Syn.GetTokenID: TtkTokenKind;
begin
  Result := fTokenID;
end;

function TSynK16Syn.GetTokenAttribute: TSynHighlighterAttributes;
begin
  case fTokenID of
    tkComment:     Result := fCommentAttri;
    tkIdentifier:  Result := fIdentifierAttri;
    tkInstruction: Result := fInstructionAttri;
    tkRegister:    Result := fRegisterAttri;
    tkNumber:      Result := fNumberAttri;
    tkHexNumber:   Result := fHexNumberAttri;
    tkImmediate:   Result := fImmediateAttri;
    tkMemory:      Result := fMemoryAttri;
    tkLabel:       Result := fLabelAttri;
    tkDirective:   Result := fDirectiveAttri;
    tkForthWord:   Result := fForthWordAttri;
    tkSpace:       Result := fSpaceAttri;
    tkString:      Result := fStringAttri;
    tkSymbol:      Result := fSymbolAttri;
    else           Result := fIdentifierAttri;
  end;
end;

function TSynK16Syn.GetTokenKind: Integer;
begin
  Result := Ord(fTokenID);
end;

function TSynK16Syn.GetRange: Pointer;
begin
  Result := Pointer(PtrUInt(fRange));
end;

procedure TSynK16Syn.SetRange(Value: Pointer);
begin
  fRange := TRangeState(PtrUInt(Value));
end;

procedure TSynK16Syn.ResetRange;
begin
  fRange := rsUnknown;
end;

function TSynK16Syn.IsFilterStored: Boolean;
begin
  Result := fDefaultFilter <> 'K16 Assembly files (*.k16, *.asm)|*.k16;*.asm';
end;

class function TSynK16Syn.GetLanguageName: string;
begin
  Result := 'K16 Assembly';
end;

function TSynK16Syn.GetSampleSource: string;
begin
  Result :=
    '; K16 CPU Assembly Example'#13#10 +
    '.ORG $1000'#13#10 +
    'BUFFER_SIZE .EQU $100'#13#10 +
    'start:'#13#10 +
    '    LOADI D0, #$FF          ; Load immediate'#13#10 +
    '    ADD D2, D0, D1          ; D2 = D0 + D1'#13#10 +
    '    BEQ done                ; Branch if equal'#13#10 +
    'done:'#13#10 +
    '    HALT                    ; Stop execution'#13#10;
end;

end.
