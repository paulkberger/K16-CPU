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
    tkSugar,
    tkRegister,
    tkNumber,
    tkHexNumber,
    tkImmediate,
    tkMemory,
    tkLabel,
    tkDirective,
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

    // Tracks whether the most recently emitted non-whitespace token was a
    // branch/jump instruction, so we can consume a trailing ".S"/".L" suffix
    // and colour it as part of the instruction rather than as a directive.
    fLastWasBranch: Boolean;

    fCommentAttri:     TSynHighlighterAttributes;
    fIdentifierAttri:  TSynHighlighterAttributes;
    fInstructionAttri: TSynHighlighterAttributes;
    fSugarAttri:       TSynHighlighterAttributes;
    fRegisterAttri:    TSynHighlighterAttributes;
    fNumberAttri:      TSynHighlighterAttributes;
    fHexNumberAttri:   TSynHighlighterAttributes;
    fImmediateAttri:   TSynHighlighterAttributes;
    fMemoryAttri:      TSynHighlighterAttributes;
    fLabelAttri:       TSynHighlighterAttributes;
    fDirectiveAttri:   TSynHighlighterAttributes;
    fSpaceAttri:       TSynHighlighterAttributes;
    fStringAttri:      TSynHighlighterAttributes;
    fSymbolAttri:      TSynHighlighterAttributes;

    function IsInstruction(const Token: string): Boolean;
    function IsSugar(const Token: string): Boolean;
    function IsBranchMnemonic(const Token: string): Boolean;
    function PeekNextOperandIsXY: Boolean;
    function IsRegister(const Token: string): Boolean;
    function IsDirective(const Token: string): Boolean;
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
    procedure BranchSuffixProc;
    procedure DirectiveProc;

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
    property SugarAttri:       TSynHighlighterAttributes read fSugarAttri       write fSugarAttri;
    property RegisterAttri:    TSynHighlighterAttributes read fRegisterAttri    write fRegisterAttri;
    property NumberAttri:      TSynHighlighterAttributes read fNumberAttri      write fNumberAttri;
    property HexNumberAttri:   TSynHighlighterAttributes read fHexNumberAttri   write fHexNumberAttri;
    property ImmediateAttri:   TSynHighlighterAttributes read fImmediateAttri   write fImmediateAttri;
    property MemoryAttri:      TSynHighlighterAttributes read fMemoryAttri      write fMemoryAttri;
    property LabelAttri:       TSynHighlighterAttributes read fLabelAttri       write fLabelAttri;
    property DirectiveAttri:   TSynHighlighterAttributes read fDirectiveAttri   write fDirectiveAttri;
    property SpaceAttri:       TSynHighlighterAttributes read fSpaceAttri       write fSpaceAttri;
    property StringAttri:      TSynHighlighterAttributes read fStringAttri      write fStringAttri;
    property SymbolAttri:      TSynHighlighterAttributes read fSymbolAttri      write fSymbolAttri;
  end;

implementation

const
  // Real opcodes (per Reference Manual v3.12 §6.0 / §15.1).
  // Aliases (sugar) live in K16_SUGAR instead.
  K16_INSTRUCTIONS: array[0..94] of string = (
    // Control / Negate ($00)
    'NOP', 'HALT', 'NEG',
    // LOOKUP family ($01)
    'LOOKUP',
    'SHL', 'SHR', 'ASR', 'ROL', 'ROR',
    'SWAPB', 'HIGH', 'LOW',
    'SHL4', 'SHR4', 'ASR4', 'ASR8',
    'MULB', 'RECIP',
    // LEA ($03)
    'LEA',
    // Conditional Set ($04)
    'SEQ', 'SNE', 'SCS', 'SCC',
    'SLT', 'SGT', 'SGE', 'SLE',
    'SMI', 'SPL', 'SAL',
    // Register transfer ($05)
    'MOVE', 'SWAP',
    // Stack ($06 / $07) — generic plus the operand-form variants the
    // toolchain emits in listings.
    'PUSH', 'PUSHD', 'PUSHDG', 'PUSHXY', 'PUSHI',
    'POP', 'POPD', 'POPDG', 'POPXY',
    // ALU ($08-$0F)
    'ADD', 'ADC', 'SUB', 'SBC',
    'AND', 'OR', 'XOR', 'NOT',
    // Compare ($10)
    'CMP',
    // Branches ($11) — note BHS/BLO are aliases (see K16_SUGAR)
    'BEQ', 'BNE', 'BCS', 'BCC',
    'BLT', 'BGT', 'BGE', 'BLE',
    'BRA',
    // Jumps ($12) — JMP is an alias for JMP24 (see K16_SUGAR)
    'JMP24', 'JMP16', 'JMPT', 'JMPXY',
    // Subroutine call ($13) — CALL is an alias for CALL24
    'CALL24', 'CALL16', 'CALLR', 'CALLXY',
    // TRAP / RET-family ($1E)
    'TRAP', 'RET', 'RETCC', 'RETCS',
    // Loads ($14-$18)
    'LOADD', 'LOADB', 'LOADX', 'LOADY',
    'LOADI', 'LOADXY',
    'LOADP', 'LOADPB', 'LOADZ', 'LOADZB',
    // Stores ($19-$1D)
    'STORED', 'STOREB', 'STOREX', 'STOREY',
    'STOREI', 'STOREXY',
    'STOREP', 'STOREPB', 'STOREZ', 'STOREZB',
    // Interrupts ($1F)
    'DINT', 'EINT', 'RTI', 'INT'
  );

  // Level-2 syntactic sugar per Reference Manual §6.0 plus assembler
  // pseudo-instructions per §6.15.
  // INC/DEC are sugar for ADD/SUB on D registers; on XY they are real $02
  // opcodes — the colour reflects the conceptual "alias" framing either way.
  // BHI/BLS are pseudo-instructions added 19 May 2026 — they expand to
  // pairs of native branches (BEQ.S/BHS and BEQ/BLO respectively).
  // Note: SHL/SHR/ASR remain in K16_INSTRUCTIONS — their one-operand
  // forms are native LOOKUP ops, and the highlighter can't easily tell
  // one-operand from two-operand uses inline.
  K16_SUGAR: array[0..11] of string = (
    'JMP', 'CALL',
    'SEC', 'CLC',
    'BHS', 'BLO',
    'BHI', 'BLS',
    'SHS', 'SLO',
    'INC', 'DEC'
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
    'DS', 'IF', 'ENDIF', 'INCLUDE', 'LOCAL'
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

  // Syntactic sugar: same hue family as instructions but lighter,
  // signalling "this is an alias, not a distinct opcode".
  // RGB $5080B0 in BGR byte order = $B08050 = steel blue, lighter navy.
  fSugarAttri := TSynHighlighterAttributes.Create('Sugar');
  fSugarAttri.Foreground := $B08050;
  AddAttribute(fSugarAttri);

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
  fLastWasBranch := False;
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

function TSynK16Syn.IsSugar(const Token: string): Boolean;
var
  i: Integer;
  UpperToken: string;
begin
  UpperToken := UpperCase(Token);
  for i := 0 to High(K16_SUGAR) do
    if UpperToken = K16_SUGAR[i] then
      Exit(True);
  Result := False;
end;

// After IdentProc has consumed a mnemonic, peek ahead past whitespace to see
// whether the first operand starts with "XY". Used to distinguish
// "INC XYn" (real $02 opcode) from "INC Dn" (sugar for ADD Dn,#1).
// We do not consume anything — Run is restored before returning.
function TSynK16Syn.PeekNextOperandIsXY: Boolean;
var
  p: LongInt;
begin
  p := Run;
  while fLine[p] in [#1..#9, #11, #12, #14..#32] do
    Inc(p);
  Result := ((fLine[p] = 'X') or (fLine[p] = 'x')) and
            ((fLine[p + 1] = 'Y') or (fLine[p + 1] = 'y')) and
            (fLine[p + 2] in ['0'..'9']);
end;

// Branch/jump mnemonics that may carry a ".S" or ".L" short/long suffix.
// This list is used only for deciding whether to absorb a trailing ".S"/".L"
// as part of the instruction token; it does not affect colouring otherwise.
function TSynK16Syn.IsBranchMnemonic(const Token: string): Boolean;
var
  UpperToken: string;
begin
  UpperToken := UpperCase(Token);
  Result :=
    (UpperToken = 'BRA') or
    (UpperToken = 'BEQ') or (UpperToken = 'BNE') or
    (UpperToken = 'BCS') or (UpperToken = 'BCC') or
    (UpperToken = 'BHS') or (UpperToken = 'BLO') or
    (UpperToken = 'BLT') or (UpperToken = 'BGT') or
    (UpperToken = 'BGE') or (UpperToken = 'BLE') or
    (UpperToken = 'BMI') or (UpperToken = 'BPL') or
    (UpperToken = 'BVS') or (UpperToken = 'BVC') or
    (UpperToken = 'BHI') or (UpperToken = 'BLS');
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

procedure TSynK16Syn.IdentProc;
var
  Token: string;
begin
  while fLine[Run] in ['A'..'Z', 'a'..'z', '0'..'9', '_'] do
    Inc(Run);
  Token := GetTokenString;
  if IsInstruction(Token) then
  begin
    fTokenID := tkInstruction;
    fLastWasBranch := IsBranchMnemonic(Token);
  end
  else if IsSugar(Token) then
  begin
    // INC/DEC are sugar on D registers but real $02 opcodes on XY pairs.
    // Peek the first operand to pick the right colour.
    if ((UpperCase(Token) = 'INC') or (UpperCase(Token) = 'DEC')) and
       PeekNextOperandIsXY then
      fTokenID := tkInstruction
    else
      fTokenID := tkSugar;
    fLastWasBranch := IsBranchMnemonic(Token);
  end
  else if IsRegister(Token) then
  begin
    fTokenID := tkRegister;
    fLastWasBranch := False;
  end
  else if IsDirective(Token) then
  begin
    fTokenID := tkDirective;
    fLastWasBranch := False;
  end
  else
  begin
    fTokenID := tkIdentifier;
    fLastWasBranch := False;
  end;
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
  fLastWasBranch := False;
end;

procedure TSynK16Syn.LFProc;
begin
  fTokenID := tkSpace;
  Inc(Run);
  fLastWasBranch := False;
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
  // Whitespace alone doesn't reset the "last was branch" flag — we want
  // "BRA .S target" (with the space between BRA and .S) to still be valid.
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

// Consume a ".S" or ".L" suffix as part of a branch instruction.
// Run is on the '.' on entry; emit "[.][SL]" as tkInstruction so it picks up
// the navy colour rather than the bold-black directive colour.
procedure TSynK16Syn.BranchSuffixProc;
begin
  Inc(Run); // skip '.'
  Inc(Run); // skip S or L
  fTokenID := tkInstruction;
  fLastWasBranch := False;
end;

// Standard directive path: '.' followed by identifier chars.
procedure TSynK16Syn.DirectiveProc;
begin
  Inc(Run); // skip '.'
  while fLine[Run] in ['A'..'Z', 'a'..'z', '0'..'9', '_'] do
    Inc(Run);
  fTokenID := tkDirective;
  fLastWasBranch := False;
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
        // If we just emitted a branch/jump mnemonic and this is ".S" or ".L"
        // not followed by another ident char, treat the suffix as part of
        // the instruction rather than as a directive.
        if fLastWasBranch and
           ((fLine[Run + 1] = 'S') or (fLine[Run + 1] = 's') or
            (fLine[Run + 1] = 'L') or (fLine[Run + 1] = 'l')) and
           not (fLine[Run + 2] in ['A'..'Z', 'a'..'z', '0'..'9', '_']) then
          BranchSuffixProc
        else
          DirectiveProc;
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
    tkSugar:       Result := fSugarAttri;
    tkRegister:    Result := fRegisterAttri;
    tkNumber:      Result := fNumberAttri;
    tkHexNumber:   Result := fHexNumberAttri;
    tkImmediate:   Result := fImmediateAttri;
    tkMemory:      Result := fMemoryAttri;
    tkLabel:       Result := fLabelAttri;
    tkDirective:   Result := fDirectiveAttri;
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
    '    LOADI   D0, #$FF        ; Load immediate'#13#10 +
    '    ADD     D2, D0, D1      ; D2 = D0 + D1'#13#10 +
    '    INC     D0              ; sugar for ADD D0, #1'#13#10 +
    '    CMP     D0, D1'#13#10 +
    '    BEQ.S   done            ; short branch'#13#10 +
    '    BRA.L   far_target      ; long branch'#13#10 +
    '    CALL    helper          ; sugar for CALL24'#13#10 +
    '    RETCC                   ; success return'#13#10 +
    'done:'#13#10 +
    '    HALT                    ; Stop execution'#13#10;
end;

end.
