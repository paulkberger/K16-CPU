{
  K16_Listing.pas — K16 Assembler Listing Generator

  Produces a human-readable assembly listing from a completed TK16Assembler.
  Separated from the assembler so it can be maintained, extended, or replaced
  independently.  The listing never modifies assembler state.

  Sections generated:
    1. File header and assembly statistics
    2. Symbol table
    3. Machine code body (address, opcode, immediate, OP.M.B, source)
       — labels emitted on their own line before each instruction
    4. Memory usage summary
    5. Instruction frequency statistics
    6. Warnings, errors and completion status

  Part of the K16 homebrew CPU project.
  License: MIT
}
unit K16_Listing;

{$mode Delphi}

interface

uses
  SysUtils, Classes, Generics.Collections, Math, StrUtils,
  K16_Parser, K16_Encoder_Base,
  K16_Assembler;

type
  TK16ListingGenerator = class
  private
    FAsm: TK16Assembler;

    { Build address -> label-name map (labels only, not constants) }
    function  BuildAddressLabelMap: TDictionary<UInt32, string>;
    function  IsBuildSymbol(const AName: string): Boolean;

    { Join a TArray<string> with a separator — local copy so unit is self-contained }
    function  JoinStrings(const Arr: TArray<string>; const Sep: string): string;

    { Extract operands from a .TEXT/.BYTE source line, stripping comments }
    function  ExtractTextOperands(const SourceLine: string): string;

    { Listing sections }
    procedure WriteHeader(Listing: TStringList);
    procedure WriteSymbolTable(Listing: TStringList);
    procedure WriteMachineCode(Listing: TStringList;
                               AddrLabels: TDictionary<UInt32, string>);
    procedure WriteMemorySummary(Listing: TStringList);
    procedure WriteInstructionStats(Listing: TStringList);
    procedure WriteFooter(Listing: TStringList);

  public
    constructor Create(Assembler: TK16Assembler);

    { Generate the full listing text }
    function Generate: string;

    { Save the listing to a file }
    procedure SaveToFile(const Filename: string);
  end;

implementation

{ ============================================================
  TK16ListingGenerator
  ============================================================ }

constructor TK16ListingGenerator.Create(Assembler: TK16Assembler);
begin
  inherited Create;
  FAsm := Assembler;
end;

{ ---- Utility ---- }

function TK16ListingGenerator.JoinStrings(const Arr: TArray<string>;
  const Sep: string): string;
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

function TK16ListingGenerator.ExtractTextOperands(const SourceLine: string): string;
var
  TextPos: Integer;
  AfterText: string;
  i, j: Integer;
  InQuote: Boolean;
  QuoteChar: Char;
  CommentPos, BackslashCount: Integer;
begin
  TextPos := Pos('.TEXT', UpperCase(SourceLine));
  if TextPos = 0 then begin Result := ''; Exit; end;

  AfterText := TrimLeft(Copy(SourceLine, TextPos + 5, MaxInt));

  InQuote    := False;
  QuoteChar  := #0;
  CommentPos := 0;

  for i := 1 to Length(AfterText) do
  begin
    if not InQuote and ((AfterText[i] = '''') or (AfterText[i] = '"')) then
    begin
      InQuote := True; QuoteChar := AfterText[i];
    end
    else if InQuote and (AfterText[i] = QuoteChar) then
    begin
      BackslashCount := 0; j := i - 1;
      while (j >= 1) and (AfterText[j] = '\') do begin Inc(BackslashCount); Dec(j); end;
      if (BackslashCount mod 2) = 0 then begin InQuote := False; QuoteChar := #0; end;
    end
    else if (AfterText[i] = ';') and not InQuote then
    begin
      CommentPos := i; Break;
    end;
  end;

  if CommentPos > 0 then
    AfterText := Copy(AfterText, 1, CommentPos - 1);

  Result := TrimRight(AfterText);
end;

function TK16ListingGenerator.BuildAddressLabelMap: TDictionary<UInt32, string>;
var
  Sym: TSymbol;
  Existing: string;
begin
  Result := TDictionary<UInt32, string>.Create;
  for Sym in FAsm.Symbols.Values do
    if Sym.SymType = stLabel then
    begin
      if Result.TryGetValue(Sym.Value, Existing) then
        Result[Sym.Value] := Existing + ', ' + LowerCase(Sym.Name)
      else
        Result.Add(Sym.Value, LowerCase(Sym.Name));
    end;
end;

{ ---- Section 1: Header ---- }

function TK16ListingGenerator.IsBuildSymbol(const AName: string): Boolean;
begin
  // Reserved predefined build symbols (__DATE__, __YEAR__, ...) are build
  // metadata, not program symbols — excluded from the human-facing symbol
  // table and its count (their values are not addresses).
  Result := AName.StartsWith('__') and AName.EndsWith('__');
end;


procedure TK16ListingGenerator.WriteHeader(Listing: TStringList);
var
  Sym: TSymbol;
  UserSymCount: Integer;
begin
  UserSymCount := 0;
  for Sym in FAsm.Symbols.Values do
    if not IsBuildSymbol(Sym.Name) then
      Inc(UserSymCount);

  Listing.Add('K16 CPU Assembly Listing');
  Listing.Add('========================');
  Listing.Add('Generated : ' + DateTimeToStr(Now));
  Listing.Add('');
  Listing.Add(Format('Source Lines  : %d', [FAsm.SourceLines.Count]));
  Listing.Add(Format('Instructions  : %d', [FAsm.MachineCode.Count]));
  Listing.Add(Format('Symbols       : %d', [UserSymCount]));
  Listing.Add(Format('Start Address : %.*X %.*X',
    [2, FAsm.StartAddress shr 16, 4, FAsm.StartAddress and $FFFF]));
  if FAsm.EntryPoint <> FAsm.StartAddress then
    Listing.Add(Format('Entry Point   : %.*X %.*X',
      [2, FAsm.EntryPoint shr 16, 4, FAsm.EntryPoint and $FFFF]));
  Listing.Add('');
end;

{ ---- Section 2: Symbol table ---- }

procedure TK16ListingGenerator.WriteSymbolTable(Listing: TStringList);
var
  Sym: TSymbol;
  Sorted: TList<TSymbol>;
  i, j: Integer;
  Tmp: TSymbol;
  TypeStr: string;
begin
  if FAsm.Symbols.Count = 0 then Exit;

  { Copy symbols into a list so we can sort by address. Constants and .EQU
    values don't have a meaningful "address" as such, but their Value field
    is used as the sort key — this puts small constants at the top and
    real labels in memory order, which is what you want when scanning a
    listing alongside a memory dump. }
  Sorted := TList<TSymbol>.Create;
  try
    for Sym in FAsm.Symbols.Values do
      if not IsBuildSymbol(Sym.Name) then
        Sorted.Add(Sym);

    { Simple insertion sort — symbol counts stay small, O(n²) is fine. }
    for i := 0 to Sorted.Count - 2 do
      for j := i + 1 to Sorted.Count - 1 do
        if Sorted[j].Value < Sorted[i].Value then
        begin
          Tmp := Sorted[i];
          Sorted[i] := Sorted[j];
          Sorted[j] := Tmp;
        end;

    Listing.Add('Symbol Table (by address) :');
    Listing.Add('===========================');
    Listing.Add('Address  Name                     Type      Line');
    Listing.Add('-------- ------------------------ --------- ----');
    for i := 0 to Sorted.Count - 1 do
    begin
      Sym := Sorted[i];
      case Sym.SymType of
        stLabel:    TypeStr := 'Label';
        stConstant: TypeStr := 'Constant';
        stVariable: TypeStr := 'Variable';
        else        TypeStr := '';
      end;
      Listing.Add(Format('%06X   %-24s %-9s %4d',
        [Sym.Value and $FFFFFF, Sym.Name, TypeStr, Sym.LineNumber]));
    end;
  finally
    Sorted.Free;
  end;

  Listing.Add('');
end;

{ ---- Section 3: Machine code body ---- }

procedure TK16ListingGenerator.WriteMachineCode(Listing: TStringList;
  AddrLabels: TDictionary<UInt32, string>);
const
  FmtStr = '%-12s %-8s %-9s %-5s %-40s%s';
var
  SourceLines:  TStringList;
  Instructions: TList<TInstructionRecord>;
  MachCode:     TList<TMachineCode>;
  i, j, InstrIndex: Integer;
  MC:           TMachineCode;
  Line:         string;
  AddrStr, CodeStr, ImmStr, BytesStr: string;
  OriginalSource, CleanSource: string;
  InstrPart, CommentPart: string;
  CommentPos:   Integer;
  DisplayMnemonic, OperandsPart: string;
  IsDataDirective: Boolean;
  OperandsForDisplay, DirectiveLine: string;
  StartJ, ByteIndex: Integer;
  HexCodes, AsciiChars: string;
  BytesThisLine, LineAddr, ByteVal: Integer;
  TrimmedInstr: string;
  SpacePos, TabPos, FirstWS: Integer;
  Mnemonic, Operands, SymbolName: string;
  SecondWS: Integer;
  Directive, Value: string;
  CommaPos: Integer;
  SymName, SymValue: string;
  OpcodeNum, ModeNum: Byte;
  TextBytes: TList<Byte>;
  LabelNames: string;
  IR: TInstructionRecord;
  FullText: string;
  RealBytes: TArray<Byte>;
  B: Integer;
begin
  SourceLines  := FAsm.SourceLines;
  Instructions := FAsm.Instructions;
  MachCode     := FAsm.MachineCode;

  Listing.Add('Machine Code Listing :');
  Listing.Add('=====================');
  Listing.Add('Address      Code     Immediate OP.M.B Source');
  Listing.Add('------------ -------- --------- ------ ----------------------------------------');

  j          := 0;
  InstrIndex := 0;

  for i := 0 to SourceLines.Count - 1 do
  begin
    { Normalise source line: tabs -> 8 spaces, collapse runs > 8, trim }
    CleanSource := StringReplace(SourceLines[i], #9, '        ', [rfReplaceAll]);
    while Pos('         ', CleanSource) > 0 do
      CleanSource := StringReplace(CleanSource, '         ', '        ', [rfReplaceAll]);
    CleanSource := Trim(CleanSource);

    if (j < MachCode.Count) and (MachCode[j].SourceLine = i + 1) then
    begin
      MC      := MachCode[j];
      AddrStr := Format('%.2X %.4X', [MC.Address shr 16, MC.Address and $FFFF]);

      { Hoisted IR lookup: find the TInstructionRecord whose LineNumber
        matches this source line so we can read PseudoBanner /
        TrailingComment / IsPseudoExpansion before rendering. }
      while (InstrIndex < Instructions.Count) and
            (Instructions[InstrIndex].LineNumber <> i + 1) do
        Inc(InstrIndex);

      { Banner / label ordering:
          - Pseudo-instruction expansions (BHI/BLS/SHL N) — banner first,
            then label: the label conceptually sits inside the expansion.
          - .INCBIN — label first, then banner: the label marks the byte
            preceding the embedded blob, and the banner cleanly brackets
            the .INCBIN's data. }
      if (InstrIndex < Instructions.Count) and
         (Instructions[InstrIndex].PseudoBanner <> '') and
         (SameText(Instructions[InstrIndex].Mnemonic,          '.INCBIN') or
          SameText(Instructions[InstrIndex].CanonicalMnemonic, '.INCBIN')) then
      begin
        { .INCBIN: label first (it semantically belongs to whatever
          preceded the .INCBIN — e.g. `notes_txt_image_end:` marks the
          end of the prior block), then a blank line opens the .INCBIN
          block visually, then the BEGIN banner. }
        if AddrLabels.TryGetValue(MC.Address, LabelNames) then
          Listing.Add(Format(FmtStr, [AddrStr, '', '', '', LabelNames + ':', '']));
        Listing.Add('');
        Listing.Add(Format(FmtStr,
          ['', '', '', '', '        ; ' + Instructions[InstrIndex].PseudoBanner, '']));
      end
      else
      begin
        { Pseudo expansion (or any non-.INCBIN PseudoBanner consumer):
          banner first, then label, as before. }
        if (InstrIndex < Instructions.Count) and
           (Instructions[InstrIndex].PseudoBanner <> '') then
          Listing.Add(Format(FmtStr,
            ['', '', '', '', '        ; ' + Instructions[InstrIndex].PseudoBanner, '']));

        if AddrLabels.TryGetValue(MC.Address, LabelNames) then
          Listing.Add(Format(FmtStr, [AddrStr, '', '', '', LabelNames + ':', '']));
      end;

      CodeStr := Format('%.*X', [4, MC.OpCode]);
      ImmStr  := IfThen(MC.HasImmediate, Format('%.*X', [4, MC.Immediate]), '----');

      if MC.IsDataWord then
        BytesStr := '----'
      else
      begin
        OpcodeNum := (MC.OpCode shr 11) and $1F;
        ModeNum   := (MC.OpCode shr 9)  and $03;
        BytesStr  := Format('%02X.%d.%d', [OpcodeNum, ModeNum, MC.GetTotalWords * 2]);
      end;

      InstrPart   := CleanSource;
      CommentPart := '';
      CommentPos  := Pos(';', CleanSource);
      if CommentPos > 0 then
      begin
        InstrPart   := TrimRight(Copy(CleanSource, 1, CommentPos - 1));
        CommentPart := Copy(CleanSource, CommentPos, MaxInt);
      end;

      { Pseudo-expansion: replace the source-derived InstrPart and
        CommentPart with values from the TInstructionRecord.  The
        original source line is the pseudo (e.g. "SHL D0, #6"); we
        want to show the EXPANDED native mnemonic in the listing,
        with the user's trailing ';' comment attached to the first
        emitted line only. }
      if (InstrIndex < Instructions.Count) and
         Instructions[InstrIndex].IsPseudoExpansion then
      begin
        if Instructions[InstrIndex].TrailingComment <> '' then
          CommentPart := Instructions[InstrIndex].TrailingComment
        else
          CommentPart := '';
        InstrPart := '';   { force re-render from canonical mnemonic below }
      end;

      if InstrPart.EndsWith(':') then
        { Label-only source line that coincides with machine code — show as-is }
        Line := Format(FmtStr, [AddrStr, CodeStr, ImmStr, BytesStr, InstrPart, CommentPart])
      else
      begin
        if InstrIndex < Instructions.Count then
        begin
          IR := Instructions[InstrIndex];
          DisplayMnemonic := IR.CanonicalMnemonic;
          if DisplayMnemonic = '' then DisplayMnemonic := IR.Mnemonic;
          OperandsPart := JoinStrings(IR.Operands, ', ');
          if OperandsPart <> '' then
            InstrPart := Format('    %-8s %s', [DisplayMnemonic, OperandsPart])
          else
            InstrPart := Format('    %-8s', [DisplayMnemonic]);
        end
        else
          InstrPart := '    ' + TrimLeft(InstrPart);

        Line := Format(FmtStr, [AddrStr, CodeStr, ImmStr, BytesStr, InstrPart, CommentPart]);
      end;

      { Data directives (.TEXT / .BYTE / .DS / .INCBIN) get hex-dump formatting }
      IsDataDirective := False;
      if MC.IsDataWord and (InstrIndex < Instructions.Count) then
      begin
        IR := Instructions[InstrIndex];
        IsDataDirective :=
          SameText(IR.Mnemonic,          '.TEXT') or
          SameText(IR.CanonicalMnemonic, '.TEXT') or
          SameText(IR.Mnemonic,          '.BYTE') or
          SameText(IR.CanonicalMnemonic, '.BYTE') or
          SameText(IR.Mnemonic,          '.DS')   or
          SameText(IR.CanonicalMnemonic, '.DS')   or
          SameText(IR.Mnemonic,          '.INCBIN') or
          SameText(IR.CanonicalMnemonic, '.INCBIN');
      end;

      if IsDataDirective then
      begin
        IR := Instructions[InstrIndex];
        OperandsForDisplay := JoinStrings(IR.Operands, ', ');
        if (Length(IR.Operands) = 0) or (Pos(';', OperandsForDisplay) > 0) then
          OperandsForDisplay := ExtractTextOperands(IR.SourceLine);

        { .INCBIN: Operands[0] is the cache key (resolved absolute path
          in upper case), not what the user wrote.  Re-derive from the
          source line so the listing shows the original quoted filename. }
        if SameText(IR.Mnemonic, '.INCBIN') or
           SameText(IR.CanonicalMnemonic, '.INCBIN') then
          OperandsForDisplay := Trim(FAsm.PublicExtractDirectiveContent(
                                       IR.SourceLine, '.INCBIN'));

        DirectiveLine := Format('%-12s %-8s %-9s %-5s %-40s%s',
          ['', '', '', '', '    ' + IR.Mnemonic + '    ' + OperandsForDisplay, CommentPart]);
        Listing.Add(DirectiveLine);

        { Byte-faithful dump: re-parse the original directive content to get
          exactly the bytes the user wrote. The emitted MachineCode words are
          zero-padded to word boundaries; displaying those pad bytes was how
          BUG 1 stayed hidden for so long (see Assembler_Fixes_Required.md).
          For .BYTE / .TEXT we show only the real byte count; for .DS we
          retain the padded-word view (the fill bytes are genuine). }
        TextBytes := TList<Byte>.Create;
        try
          if SameText(IR.Mnemonic, '.BYTE') or SameText(IR.CanonicalMnemonic, '.BYTE')
          or SameText(IR.Mnemonic, '.TEXT') or SameText(IR.CanonicalMnemonic, '.TEXT') then
          begin
            FullText := '';
            if SameText(IR.Mnemonic, '.BYTE') or SameText(IR.CanonicalMnemonic, '.BYTE') then
              FullText := FAsm.PublicExtractDirectiveContent(IR.SourceLine, '.BYTE')
            else
              FullText := FAsm.PublicExtractDirectiveContent(IR.SourceLine, '.TEXT');

            if FAsm.PublicParseTextString(FullText, i + 1, RealBytes) then
            begin
              for B := 0 to High(RealBytes) do
                TextBytes.Add(RealBytes[B]);

              { .TEXT auto-pads to word alignment with $00 — show that pad
                byte in the listing so display matches emitted ROM. .BYTE
                stays byte-precise (no auto-pad). }
              if (SameText(IR.Mnemonic, '.TEXT') or SameText(IR.CanonicalMnemonic, '.TEXT'))
                 and ((Length(RealBytes) and 1) <> 0) then
                TextBytes.Add(0);
            end
            else
            begin
              { Re-parse failed (shouldn't happen — pass-1 already parsed) —
                fall back to the word-padded display so the user sees something. }
              TextBytes.Add(MC.OpCode and $FF);
              TextBytes.Add((MC.OpCode shr 8) and $FF);
            end;

            { Advance j past all continuation records for this line so the
              outer loop doesn't double-render them. }
            StartJ := j;
            Inc(j);
            while (j < MachCode.Count) and (MachCode[j].SourceLine = i + 1) do
              Inc(j);
          end
          else
          begin
            { .DS and anything else: keep padded-word behaviour }
            TextBytes.Add(MC.OpCode and $FF);
            TextBytes.Add((MC.OpCode shr 8) and $FF);
            StartJ := j;
            Inc(j);
            while (j < MachCode.Count) and (MachCode[j].SourceLine = i + 1) do
            begin
              TextBytes.Add(MachCode[j].OpCode and $FF);
              TextBytes.Add((MachCode[j].OpCode shr 8) and $FF);
              Inc(j);
            end;
          end;

          ByteIndex := 0;
          while ByteIndex < TextBytes.Count do
          begin
            HexCodes      := '';
            AsciiChars    := '';
            BytesThisLine := 0;
            LineAddr      := MachCode[StartJ].Address + ByteIndex;
            while (ByteIndex < TextBytes.Count) and (BytesThisLine < 16) do
            begin
              ByteVal := TextBytes[ByteIndex];
              if HexCodes <> '' then HexCodes := HexCodes + ' ';
              HexCodes   := HexCodes + Format('%.2X', [ByteVal]);
              if (ByteVal >= 32) and (ByteVal <= 126) then
                AsciiChars := AsciiChars + Chr(ByteVal)
              else
                AsciiChars := AsciiChars + '.';
              Inc(ByteIndex); Inc(BytesThisLine);
            end;
            AddrStr := Format('%.2X %.4X', [LineAddr shr 16, LineAddr and $FFFF]);
            Listing.Add(Format('%-12s %-47s  ; %s', [AddrStr, HexCodes, AsciiChars]));
          end;

          { Matching END banner for .INCBIN (mirrors the BEGIN banner the
            assembler attached via PseudoBanner).  Other data directives
            don't get an END marker — they're typically short and don't
            need one. PublicExtractDirectiveContent returns the user's
            text verbatim (including their quotes), so no re-quoting.
            Followed by a blank line to bracket the block visually. }
          if SameText(IR.Mnemonic, '.INCBIN') or
             SameText(IR.CanonicalMnemonic, '.INCBIN') then
          begin
            Listing.Add(Format('%-12s %-8s %-9s %-5s %s',
              ['', '', '', '',
               '        ; === END INCBIN ' +
               Trim(FAsm.PublicExtractDirectiveContent(IR.SourceLine, '.INCBIN'))
               + ' ===']));
            Listing.Add('');
          end;
        finally
          TextBytes.Free;
        end;
      end
      else
      begin
        Listing.Add(Line);
        Inc(j);
        { Continuation words for multi-word instructions, AND additional
          native instructions emitted by a pseudo expansion (each pseudo
          expansion record has its own TInstructionRecord with
          IsPseudoExpansion=True; advance InstrIndex per record so the
          native mnemonic is rendered on every line). }
        while (j < MachCode.Count) and (MachCode[j].SourceLine = i + 1) do
        begin
          MC      := MachCode[j];
          AddrStr := Format('%.2X %.4X', [MC.Address shr 16, MC.Address and $FFFF]);
          CodeStr := Format('%.*X', [4, MC.OpCode]);
          if MC.IsDataWord then
            BytesStr := '----'
          else
          begin
            OpcodeNum := (MC.OpCode shr 11) and $1F;
            ModeNum   := (MC.OpCode shr 9)  and $03;
            BytesStr  := Format('%02X.%d.%d', [OpcodeNum, ModeNum, MC.GetTotalWords * 2]);
          end;

          { If the next TInstructionRecord is a pseudo-expansion
            continuation (same source line, IsPseudoExpansion=True),
            advance InstrIndex and render its native mnemonic.
            Otherwise this is a multi-word continuation of the same
            native instruction — leave the disassembly column blank
            as before. }
          InstrPart := '';
          if (InstrIndex + 1 < Instructions.Count) and
             (Instructions[InstrIndex + 1].LineNumber = i + 1) and
             Instructions[InstrIndex + 1].IsPseudoExpansion then
          begin
            Inc(InstrIndex);
            IR := Instructions[InstrIndex];
            DisplayMnemonic := IR.CanonicalMnemonic;
            if DisplayMnemonic = '' then DisplayMnemonic := IR.Mnemonic;
            OperandsPart := JoinStrings(IR.Operands, ', ');
            if OperandsPart <> '' then
              InstrPart := Format('    %-8s %s', [DisplayMnemonic, OperandsPart])
            else
              InstrPart := Format('    %-8s', [DisplayMnemonic]);
          end;

          Listing.Add(Format(FmtStr, [AddrStr, CodeStr, '----', BytesStr, InstrPart, '']));
          Inc(j);
        end;
      end;

      if InstrIndex < Instructions.Count then Inc(InstrIndex);
    end
    else
    begin
      { Source line with no machine code: comments, directives, standalone labels,
        OR pseudo-instructions that emitted nothing (e.g. SHL Dn, #0). }
      InstrPart   := CleanSource;
      CommentPart := '';
      CommentPos  := Pos(';', CleanSource);
      if CommentPos > 0 then
      begin
        InstrPart   := TrimRight(Copy(CleanSource, 1, CommentPos - 1));
        CommentPart := Copy(CleanSource, CommentPos, MaxInt);
      end;

      { Shift pseudos with count=0 emit a warning and produce no code.
        Render them as a comment so they don't appear mis-aligned in the
        listing as if they were instruction lines.  Heuristic: mnemonic
        is SHL/SHR/ASR (case-insensitive) and operands include #0.  If
        the heuristic misses an unusual variant the line just renders
        as before — no regression. }
      if InstrPart <> '' then
      begin
        TrimmedInstr := Trim(InstrPart);
        SpacePos := Pos(' ', TrimmedInstr); TabPos := Pos(#9, TrimmedInstr);
        FirstWS  := 0;
        if (SpacePos > 0) and (TabPos > 0) then FirstWS := Min(SpacePos, TabPos)
        else if SpacePos > 0 then FirstWS := SpacePos
        else if TabPos   > 0 then FirstWS := TabPos;

        if FirstWS > 0 then
        begin
          Mnemonic := UpperCase(Copy(TrimmedInstr, 1, FirstWS - 1));
          Operands := Trim(Copy(TrimmedInstr, FirstWS + 1, MaxInt));
          if ((Mnemonic = 'SHL') or (Mnemonic = 'SHR') or (Mnemonic = 'ASR')) and
             (Pos('#0', Operands) > 0) and
             { exclude false-positive: #0xNN, #0b... — only bare #0 with no following digit/letter }
             (
               (Pos('#0', Operands) + 1 = Length(Operands)) or
               not (Operands[Pos('#0', Operands) + 2] in
                    ['0'..'9', 'a'..'z', 'A'..'Z'])
             ) then
          begin
            Listing.Add(Format(FmtStr,
              ['', '', '', '', '        ; ' + TrimmedInstr + '   [no code emitted]', '']));
            Continue;
          end;
        end;
      end;

      if InstrPart.EndsWith(':') then
        { Standalone label-only line: suppressed here — AddrLabels emits it
          with the correct address just before the following instruction. }
        Line := ''
      else if (InstrPart = '') and (CommentPart <> '') then
        Line := Format(FmtStr, ['', '', '', '', '        ' + CommentPart, ''])
      else if InstrPart <> '' then
      begin
        TrimmedInstr := Trim(InstrPart);
        SpacePos := Pos(' ', TrimmedInstr); TabPos := Pos(#9, TrimmedInstr);
        FirstWS  := 0;
        if (SpacePos > 0) and (TabPos > 0) then FirstWS := Min(SpacePos, TabPos)
        else if SpacePos > 0 then FirstWS := SpacePos
        else if TabPos   > 0 then FirstWS := TabPos;

        if FirstWS > 0 then
        begin
          Mnemonic := Copy(TrimmedInstr, 1, FirstWS - 1);
          Operands := Trim(Copy(TrimmedInstr, FirstWS + 1, MaxInt));
          while Pos('  ', Operands) > 0 do
            Operands := StringReplace(Operands, '  ', ' ', [rfReplaceAll]);
          while Pos(#9, Operands) > 0 do
            Operands := StringReplace(Operands, #9, ' ', [rfReplaceAll]);

          if (not Mnemonic.StartsWith('.')) and Operands.StartsWith('.') then
          begin
            { SYMBOL .DIRECTIVE VALUE }
            SymbolName := Mnemonic;
            SecondWS   := Pos(' ', Operands);
            if SecondWS > 0 then
            begin
              Directive := Copy(Operands, 1, SecondWS - 1);
              Value     := Trim(Copy(Operands, SecondWS + 1, MaxInt));
              InstrPart := Format('%-12s %-12s %s', [SymbolName, Directive, Value]);
            end
            else
              InstrPart := Format('%-12s %s', [SymbolName, Operands]);
          end
          else if SameText(Mnemonic, '.EQU') then
          begin
            { Old-style: .EQU SYMBOL, VALUE }
            CommaPos := Pos(',', Operands);
            if CommaPos > 0 then
            begin
              SymName   := Trim(Copy(Operands, 1, CommaPos - 1));
              SymValue  := Trim(Copy(Operands, CommaPos + 1, MaxInt));
              InstrPart := Format('%-12s %-12s %s', [SymName, Mnemonic, SymValue]);
            end
            else
              InstrPart := Format('%-12s %-12s %s', ['', Mnemonic, Operands]);
          end
          else if SameText(Mnemonic, '.BASE') or SameText(Mnemonic, '.ORG') then
            InstrPart := Format('%-12s %-12s %s', ['', Mnemonic, Operands])
          else
          begin
            Operands  := StringReplace(Operands, ', ', ',',  [rfReplaceAll]);
            Operands  := StringReplace(Operands, ',',  ', ', [rfReplaceAll]);
            InstrPart := Format('    %-8s %s', [Mnemonic, Operands]);
          end;
        end
        else
          InstrPart := Format('    %-8s', [TrimmedInstr]);

        Line := Format(FmtStr, ['', '', '', '', InstrPart, CommentPart]);
      end
      else
        Line := '';

      Listing.Add(Line);
    end;
  end;
end;

{ ---- Section 4: Memory summary ---- }

procedure TK16ListingGenerator.WriteMemorySummary(Listing: TStringList);
var
  i, TotalBytes, SpanBytes, UsedBytes: Integer;
  StartAddr, EndAddr: UInt32;
  MC: TList<TMachineCode>;
  LastMC: TMachineCode;
begin
  MC := FAsm.MachineCode;
  if MC.Count = 0 then Exit;

  Listing.Add('');
  Listing.Add('Memory Usage Summary :');
  Listing.Add('====================');

  TotalBytes := 0;
  StartAddr  := MC[0].Address;
  EndAddr    := MC[MC.Count - 1].Address;
  LastMC     := MC[MC.Count - 1];
  for i := 0 to MC.Count - 1 do
    Inc(TotalBytes, MC[i].GetTotalWords * 2);

  Listing.Add(Format('Code Start :   %.*X %.*X',
    [2, StartAddr shr 16, 4, StartAddr and $FFFF]));
  Listing.Add(Format('Code End :     %.*X %.*X',
    [2, (EndAddr + LastMC.GetTotalWords - 1) shr 16,
     4, (EndAddr + LastMC.GetTotalWords - 1) and $FFFF]));
  Listing.Add(Format('Code Size :    %d bytes (%d words)', [TotalBytes, TotalBytes div 2]));
  Listing.Add(Format('Address Span : %02X %04X bytes',
    [(EndAddr - StartAddr + LastMC.GetTotalWords) shr 16,
     (EndAddr - StartAddr + LastMC.GetTotalWords) and $FFFF]));

  UsedBytes := TotalBytes;
  SpanBytes := (EndAddr - StartAddr + LastMC.GetTotalWords) * 2;
  if SpanBytes > 0 then
    Listing.Add(Format('Memory Efficiency : %.1f%% (%d/%d bytes)',
      [UsedBytes * 100.0 / SpanBytes, UsedBytes, SpanBytes]));
end;

{ ---- Section 5: Instruction statistics ---- }

procedure TK16ListingGenerator.WriteInstructionStats(Listing: TStringList);
var
  i: Integer;
  InstrName: string;
  Percent: Double;
  InstrCounts: TDictionary<string, Integer>;
  Instructions: TList<TInstructionRecord>;
begin
  Instructions := FAsm.Instructions;
  if FAsm.MachineCode.Count = 0 then Exit;

  Listing.Add('');
  Listing.Add('Instruction Statistics :');
  Listing.Add('======================');

  InstrCounts := TDictionary<string, Integer>.Create;
  try
    for i := 0 to Instructions.Count - 1 do
    begin
      InstrName := Instructions[i].CanonicalMnemonic;
      if InstrName = '' then InstrName := Instructions[i].Mnemonic;
      if InstrCounts.ContainsKey(InstrName) then
        InstrCounts.AddOrSetValue(InstrName, InstrCounts[InstrName] + 1)
      else
        InstrCounts.Add(InstrName, 1);
    end;

    Listing.Add('Instruction  Count Percent');
    Listing.Add('------------ ----- -------');
    for i := 0 to InstrCounts.Count - 1 do
    begin
      InstrName := InstrCounts.Keys.ToArray[i];
      Percent   := InstrCounts[InstrName] * 100.0 / Instructions.Count;
      Listing.Add(Format('%-12s %5d %6.1f%%', [InstrName, InstrCounts[InstrName], Percent]));
    end;
  finally
    InstrCounts.Free;
  end;
end;

{ ---- Section 6: Footer (warnings / errors / status) ---- }

procedure TK16ListingGenerator.WriteFooter(Listing: TStringList);
var
  i: Integer;
begin
  if FAsm.HasWarnings then
  begin
    Listing.Add('');
    Listing.Add('Assembly Warnings:');
    Listing.Add('==================');
    for i := 0 to FAsm.WarningList.Count - 1 do
      Listing.Add(FAsm.WarningList[i]);
  end;

  if FAsm.HasErrors then
  begin
    Listing.Add('');
    Listing.Add('Assembly Errors:');
    Listing.Add('================');
    for i := 0 to FAsm.ErrorList.Count - 1 do
      Listing.Add(FAsm.ErrorList[i]);
  end
  else
  begin
    Listing.Add('');
    if FAsm.HasWarnings then
      Listing.Add(Format('Assembly completed with %d warning(s).', [FAsm.WarningList.Count]))
    else
      Listing.Add('Assembly completed successfully.');
  end;
end;

{ ---- Orchestrator ---- }

function TK16ListingGenerator.Generate: string;
var
  Listing:    TStringList;
  AddrLabels: TDictionary<UInt32, string>;
begin
  Listing    := TStringList.Create;
  AddrLabels := BuildAddressLabelMap;
  try
    WriteHeader(Listing);
    WriteSymbolTable(Listing);
    WriteMachineCode(Listing, AddrLabels);
    WriteMemorySummary(Listing);
    WriteInstructionStats(Listing);
    WriteFooter(Listing);
    Result := Listing.Text;
  finally
    AddrLabels.Free;
    Listing.Free;
  end;
end;

procedure TK16ListingGenerator.SaveToFile(const Filename: string);
var
  F: TStringList;
begin
  F := TStringList.Create;
  try
    F.Text := Generate;
    F.SaveToFile(Filename);
  finally
    F.Free;
  end;
end;

end.
