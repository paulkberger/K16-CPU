unit K16_Regions;

{$mode Delphi}

// ---------------------------------------------------------------------------
// K16 assembler - .REGION / .RS reservation state machine.
// Spec: K16_REGION_Directive_Specification_v1.5.
//
// Self-contained: depends only on three callbacks supplied by the host
// assembler, so it needs no knowledge of TSymbol / the symbol dictionary:
//
//   DefineConst(name, value, line)  - bind a constant symbol
//   SymbolExists(name): Boolean     - is a symbol already in the table?
//   ReportError(msg, line)          - emit an assembler error
//
// The host wires three ProcessDirective branches to OpenRegion / Reserve /
// CloseRegion, and calls RejectEmit before any emitting directive.
//
// Reservation is NOT emission: nothing here touches the emit PC. The host's
// FCurrentAddress is never read or written - a region carries its own running
// address (spec 9).
//
// v1.5 changes vs v1.4: structs removed; @-scoped aliases; strict collision
// detection; auto-chain (omit start -> previous _END); overlap detection on
// explicit starts; opt-in region map (BuildMapText).
// ---------------------------------------------------------------------------

interface

uses
  SysUtils, Classes, Generics.Collections, Generics.Defaults;

type
  TDefineConst  = procedure(const AName: string; AValue: UInt32; ALine: Integer) of object;
  TSymbolExists = function (const AName: string): Boolean of object;
  TReportError  = procedure(const AMsg: string; ALine: Integer) of object;

  TRegionSpan = record
    Name:    string;
    S, E:    UInt32;       // half-open [S, E)
    Cap:     UInt32;
    HasCap:  Boolean;
    Fields:  Integer;
    Space:   string;       // owning address space (.SPACE); 'default' if untagged
  end;

  TRegionField = record
    Region:  string;
    Name:    string;       // plain field name (no @)
    Addr:    UInt32;
    Size:    UInt32;       // bytes
  end;

  TK16RegionState = class
  private
    FOpen:       Boolean;
    FName:       string;
    FStart:      UInt32;
    FAddr:       UInt32;   // running address
    FCap:        UInt32;
    FCapped:     Boolean;
    FLine:       Integer;
    FFieldCount: Integer;

    FPrevEnd:    UInt32;   // last closed region's _END, for auto-chain
    FHavePrev:   Boolean;

    FSpace:      string;   // current declaration space, set by .SPACE

    FDefine:     TDefineConst;
    FExists:     TSymbolExists;
    FError:      TReportError;

    FSpans:      TList<TRegionSpan>;
    FFields:     TList<TRegionField>;

    function  TryDefine(const AName: string; AValue: UInt32; ALine: Integer;
                        const AHint: string): Boolean;
    function  IsPriorRegionField(const AName: string): Boolean;
    procedure DefineAutoSyms(AEndValue: UInt32; ALine: Integer);
    procedure RecordSpan(AEndValue: UInt32);
  public
    constructor Create(ADefine: TDefineConst; AExists: TSymbolExists;
                       AReport: TReportError);
    destructor Destroy; override;

    function IsOpen: Boolean;
    function KindName: string;             // always 'region' - for host messages

    // NAME .REGION [start] [, cap]
    //   AHasStart = False  -> auto-chain from the previous region's _END.
    procedure OpenRegion(const AName: string; AHasStart: Boolean; AStart: UInt32;
                         ACapped: Boolean; ACap: UInt32; ALine: Integer);
    // SYMBOL .RS count[w]
    procedure Reserve(const ASymbol: string; AByteCount: UInt32; ALine: Integer);
    procedure CloseRegion(ALine: Integer);
    procedure RejectEmit(const ADirective: string; ALine: Integer);

    // .SPACE name - tag subsequent regions (and, via the host, this binary's
    // code) with an address-space name. Overlap and the code-in-region guard
    // only fire within one space, so a defs file included purely for its
    // constants (different space) can't false-trip against emitted code.
    procedure SetSpace(const ASpace: string; ALine: Integer);

    // Does [AAddr, AAddr+ASize) fall inside any placed region span of ASpace?
    // Used post-assembly to catch code/data that has grown into reserved space.
    function CodeInRegion(AAddr, ASize: UInt32; const ASpace: string;
                          out ARegionName: string): Boolean;

    // Opt-in memory map (regions only), address-sorted, with gaps.
    function BuildMapText(const ATitle: string; const ASpace: string = ''): string;

    property Current: UInt32 read FAddr;   // __RS
    property CurrentSpace: string read FSpace;
  end;

implementation

constructor TK16RegionState.Create(ADefine: TDefineConst; AExists: TSymbolExists;
  AReport: TReportError);
begin
  inherited Create;
  FOpen     := False;
  FHavePrev := False;
  FSpace    := 'default';
  FDefine   := ADefine;
  FExists   := AExists;
  FError    := AReport;
  FSpans    := TList<TRegionSpan>.Create;
  FFields   := TList<TRegionField>.Create;
end;

destructor TK16RegionState.Destroy;
begin
  FFields.Free;
  FSpans.Free;
  inherited;
end;

function TK16RegionState.IsOpen: Boolean;
begin
  Result := FOpen;
end;

function TK16RegionState.KindName: string;
begin
  Result := 'region';
end;

// Strict define: any pre-existing symbol is a collision - report and withhold.
function TK16RegionState.TryDefine(const AName: string; AValue: UInt32;
  ALine: Integer; const AHint: string): Boolean;
begin
  if FExists(AName) then
  begin
    FError(Format('Symbol ''%s'' already defined - %s.', [AName, AHint]), ALine);
    Result := False;    // withhold: do not overwrite the existing symbol
  end
  else
  begin
    FDefine(AName, AValue, ALine);
    Result := True;
  end;
end;

function TK16RegionState.IsPriorRegionField(const AName: string): Boolean;
var
  F: TRegionField;
begin
  for F in FFields do
    if SameText(F.Name, AName) then
      Exit(True);
  Result := False;
end;

procedure TK16RegionState.DefineAutoSyms(AEndValue: UInt32; ALine: Integer);
begin
  // Auto symbols stay plain (no @ alias) but are still strict-checked.
  TryDefine(FName + '_START', FStart,    ALine, 'region auto-symbol clashes');
  TryDefine(FName + '_END',   AEndValue, ALine, 'region auto-symbol clashes');
  TryDefine(FName + '_SIZE',  AEndValue - FStart, ALine, 'region auto-symbol clashes');
  if FCapped then
    TryDefine(FName + '_CAP', FCap, ALine, 'region auto-symbol clashes');
end;

procedure TK16RegionState.RecordSpan(AEndValue: UInt32);
var
  Sp: TRegionSpan;
begin
  Sp.Name   := FName;
  Sp.S      := FStart;
  Sp.E      := AEndValue;
  Sp.Cap    := FCap;
  Sp.HasCap := FCapped;
  Sp.Fields := FFieldCount;
  Sp.Space  := FSpace;
  FSpans.Add(Sp);
end;

// --- opener ----------------------------------------------------------------

procedure TK16RegionState.OpenRegion(const AName: string; AHasStart: Boolean;
  AStart: UInt32; ACapped: Boolean; ACap: UInt32; ALine: Integer);
var
  Sp: TRegionSpan;
begin
  if FOpen then
  begin
    FError(Format('region ''%s'' still open (line %d) - nesting is not allowed; ' +
      '.ENDREGION before opening ''%s''.', [FName, FLine, AName]), ALine);
    Exit;
  end;

  // Resolve the start address.
  if AHasStart then
    FStart := AStart
  else
  begin
    if not FHavePrev then
    begin
      FError(Format('region ''%s'': the first region must state an explicit ' +
        'start (no auto-zero - page $00 has fixed ABI zones).', [AName]), ALine);
      Exit;
    end;
    FStart := FPrevEnd;                 // auto-chain
  end;

  if ACapped and (ACap <= FStart) then
  begin
    FError(Format('.REGION ''%s'': cap $%.4X must be above start $%.4X ' +
      '(cap is the exclusive first address past the region).',
      [AName, ACap, FStart]), ALine);
    Exit;
  end;

  // Overlap check - explicit starts only (auto-chained can't overlap).
  // Same-space only: an address means different things in different spaces
  // (kernel page $00 vs a .com task page), so cross-space "overlap" is not.
  if AHasStart then
    for Sp in FSpans do
      if SameText(Sp.Space, FSpace) and
         (FStart >= Sp.S) and (FStart < Sp.E) then
      begin
        FError(Format('.REGION ''%s'' start $%.4X falls inside region ''%s'' ' +
          '($%.4X..$%.4X).', [AName, FStart, Sp.Name, Sp.S, Sp.E - 1]), ALine);
        Exit;
      end;

  FOpen       := True;
  FName       := AName;
  FAddr       := FStart;
  FCapped     := ACapped;
  FCap        := ACap;
  FLine       := ALine;
  FFieldCount := 0;
end;

// --- body ------------------------------------------------------------------

procedure TK16RegionState.Reserve(const ASymbol: string; AByteCount: UInt32;
  ALine: Integer);
var
  Qualified: string;
  Fld: TRegionField;
begin
  if not FOpen then
  begin
    FError(Format('.RS ''%s'' outside a region - .RS reserves inside ' +
      '.REGION..ENDREGION.', [ASymbol]), ALine);
    Exit;
  end;

  // Qualified alias always (unique by construction: REGION@FIELD).
  Qualified := FName + '@' + ASymbol;
  TryDefine(Qualified, FAddr, ALine,
            Format('field ''%s'' declared twice in region ''%s''',
                   [ASymbol, FName]));

  // Plain alias: strict - withheld on any collision.  The hint distinguishes
  // a cross-region reuse (resolve via @) from an external clash (rename).
  if IsPriorRegionField(ASymbol) then
    TryDefine(ASymbol, FAddr, ALine,
              Format('also a field in another region - use %s or rename',
                     [Qualified]))
  else
    TryDefine(ASymbol, FAddr, ALine,
              Format('qualify as %s or rename', [Qualified]));

  Fld.Region := FName;
  Fld.Name   := ASymbol;
  Fld.Addr   := FAddr;
  Fld.Size   := AByteCount;
  FFields.Add(Fld);

  Inc(FFieldCount);
  Inc(FAddr, AByteCount);
end;

// --- closer ----------------------------------------------------------------

procedure TK16RegionState.CloseRegion(ALine: Integer);
begin
  if not FOpen then
  begin
    FError('.ENDREGION without an open .REGION.', ALine);
    Exit;
  end;

  if FCapped and (FAddr > FCap) then
    FError(Format('.REGION ''%s'' overflowed: packed end $%.4X exceeds cap ' +
      '$%.4X (over by %d bytes).', [FName, FAddr, FCap, FAddr - FCap]), ALine);

  DefineAutoSyms(FAddr, ALine);   // _START/_END/_SIZE/_CAP
  RecordSpan(FAddr);

  FPrevEnd  := FAddr;             // feed auto-chain of the next region
  FHavePrev := True;
  FOpen     := False;
end;

// --- emit guard ------------------------------------------------------------

procedure TK16RegionState.RejectEmit(const ADirective: string; ALine: Integer);
begin
  if FOpen then
    FError(Format('%s emits bytes and cannot appear inside region ''%s'' - use ' +
      '.RS to reserve non-emitting space.', [ADirective, FName]), ALine);
end;

// .SPACE name - set the current declaration space. Rejected mid-region.
procedure TK16RegionState.SetSpace(const ASpace: string; ALine: Integer);
begin
  if FOpen then
  begin
    FError(Format('.SPACE cannot appear inside region ''%s'' - close it with ' +
      '.ENDREGION first.', [FName]), ALine);
    Exit;
  end;
  FSpace := ASpace;
end;

// Half-open overlap test against placed region spans of ASpace only.
function TK16RegionState.CodeInRegion(AAddr, ASize: UInt32; const ASpace: string;
  out ARegionName: string): Boolean;
var
  Sp: TRegionSpan;
begin
  for Sp in FSpans do
    if SameText(Sp.Space, ASpace) and
       (AAddr < Sp.E) and (AAddr + ASize > Sp.S) then
    begin
      ARegionName := Sp.Name;
      Exit(True);
    end;
  ARegionName := '';
  Result := False;
end;

// --- opt-in region map -----------------------------------------------------

function TK16RegionState.BuildMapText(const ATitle: string; const ASpace: string): string;
var
  SB:   TStringBuilder;
  Sp:   TRegionSpan;
  Fld:  TRegionField;
  FreeBytes: Int64;
  CapStr, FreeStr: string;
  i, j: Integer;
  SpanTmp: TRegionSpan;
  FldTmp:  TRegionField;
  SpansSorted:  TArray<TRegionSpan>;
  FieldsSorted: TArray<TRegionField>;
  FilterSpace:  string;
  RegSpace:     string;
  TmpSpans:     TList<TRegionSpan>;
  TmpFields:    TList<TRegionField>;
begin
  // Filter to ASpace (normally the build's code space) so a kosh map shows
  // only kosh-space regions, not the kernel regions that ride in via .INCLUDE
  // for their .EQU constants. '' = all spaces. Fall back to all if nothing
  // matches, so a map is never mysteriously blank.
  FilterSpace := ASpace;
  if FilterSpace <> '' then
  begin
    TmpSpans := TList<TRegionSpan>.Create;
    try
      for Sp in FSpans do
        if SameText(Sp.Space, FilterSpace) then TmpSpans.Add(Sp);
      if TmpSpans.Count = 0 then
        FilterSpace := ''
      else
        SpansSorted := TmpSpans.ToArray;
    finally
      TmpSpans.Free;
    end;
  end;
  if FilterSpace = '' then
    SpansSorted := FSpans.ToArray;

  if FilterSpace <> '' then
  begin
    TmpFields := TList<TRegionField>.Create;
    try
      for Fld in FFields do
      begin
        RegSpace := '';
        for Sp in FSpans do
          if SameText(Sp.Name, Fld.Region) then
          begin
            RegSpace := Sp.Space;
            Break;
          end;
        if SameText(RegSpace, FilterSpace) then TmpFields.Add(Fld);
      end;
      FieldsSorted := TmpFields.ToArray;
    finally
      TmpFields.Free;
    end;
  end
  else
    FieldsSorted := FFields.ToArray;

  // Insertion sort by address. Arrays are tiny (a few regions/fields) and this
  // avoids TComparer/anonymous-function mode dependencies (Delphi vs objfpc).
  for i := 1 to High(SpansSorted) do
  begin
    SpanTmp := SpansSorted[i];
    j := i - 1;
    while (j >= 0) and (SpansSorted[j].S > SpanTmp.S) do
    begin
      SpansSorted[j + 1] := SpansSorted[j];
      Dec(j);
    end;
    SpansSorted[j + 1] := SpanTmp;
  end;

  for i := 1 to High(FieldsSorted) do
  begin
    FldTmp := FieldsSorted[i];
    j := i - 1;
    while (j >= 0) and (FieldsSorted[j].Addr > FldTmp.Addr) do
    begin
      FieldsSorted[j + 1] := FieldsSorted[j];
      Dec(j);
    end;
    FieldsSorted[j + 1] := FldTmp;
  end;

  SB := TStringBuilder.Create;
  try
    SB.AppendLine('K16 Region Map - ' + ATitle);
    SB.AppendLine('Generated : ' + FormatDateTime('d/mm/yyyy  h:nn:ss AM/PM', Now));
    if FilterSpace <> '' then
      SB.AppendLine('Space     : ' + FilterSpace)
    else
      SB.AppendLine('Space     : all');
    SB.AppendLine('');
    SB.AppendLine('  Region            Start   End     Size   Cap     Free    Fields');
    SB.AppendLine('  ----------------  ------  ------  -----  ------  ------  ------');
    for Sp in SpansSorted do
    begin
      if Sp.HasCap then
      begin
        CapStr  := Format('$%.4X', [Sp.Cap]);
        FreeBytes := Int64(Sp.Cap) - Int64(Sp.E);
        FreeStr := Format('$%.4X', [UInt32(FreeBytes)]);
      end
      else
      begin
        CapStr  := '-';
        FreeStr := '-';
      end;
      SB.AppendLine(Format('  %-16s  $%.4X   $%.4X   %5d  %-6s  %-6s  %6d',
        [Sp.Name, Sp.S, Sp.E, Sp.E - Sp.S, CapStr, FreeStr, Sp.Fields]));
    end;

    SB.AppendLine('');
    SB.AppendLine('Fields (by address):');
    SB.AppendLine('  Addr    Region@Field                        Size   Decimal');
    SB.AppendLine('  ------  ----------------------------------  -----  -------');
    for Fld in FieldsSorted do
      SB.AppendLine(Format('  $%.4X  %-34s  %5s  %7d',
        [Fld.Addr, Fld.Region + '@' + Fld.Name, Format('$%X', [Fld.Size]),
         Fld.Size]));

    // Gaps between consecutive placed spans.
    if Length(SpansSorted) > 1 then
    begin
      SB.AppendLine('');
      SB.AppendLine('Gaps:');
      for i := 0 to High(SpansSorted) - 1 do
        if SpansSorted[i].E < SpansSorted[i + 1].S then
          SB.AppendLine(Format('  $%.4X..$%.4X   %d bytes',
            [SpansSorted[i].E, SpansSorted[i + 1].S - 1,
             SpansSorted[i + 1].S - SpansSorted[i].E]));
    end;

    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

end.
