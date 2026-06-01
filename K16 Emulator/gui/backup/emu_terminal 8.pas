unit emu_terminal;
{
  K16 Emulator IDE — VT100 Terminal Component
  Simple ring-buffer approach:
  - Total buffer = SCROLLBACK_LINES + FRows lines
  - FWriteRow = next row to write into (0-based, wraps)
  - Visible rows = FWriteRow-FRows .. FWriteRow-1 (mod total)
  - Scrollbar lets user view history above
}
{$mode Delphi}
{$H+}

interface

uses
  Classes, SysUtils, Controls, Graphics, Forms,
  LCLType, LCLIntf, StdCtrls, ExtCtrls, Clipbrd, Math;

const
  SCROLLBACK_LINES = 200;
  FONT_NAME        = 'Cascadia Mono';
  FONT_HEIGHT      = -18;

type
  TAttr = record
    FG, BG  : Byte;
    Bold, Reverse : Boolean;
  end;

  TCell = record
    Ch   : Char;
    Attr : TAttr;
  end;

  TCellRow   = array of TCell;
  TKeyCallback   = procedure(code: Word) of object;
  TPasteCallback = procedure(const s: string) of object;

  TK16Terminal = class(TCustomControl)
  private
    FCellW, FCellH : Integer;
    FCols, FRows   : Integer;
    FReady         : Boolean;
    FTotalLines    : Integer;   { SCROLLBACK_LINES + FRows }

    { Ring buffer — FTotalLines rows, each FCols cells }
    FBuf           : array of TCellRow;

    { FWriteRow: index of the NEXT row to be written (i.e. bottom+1).
      The current bottom visible row is (FWriteRow-1+FTotalLines) mod FTotalLines.
      The current top visible row is (FWriteRow-FRows+FTotalLines) mod FTotalLines. }
    FWriteRow      : Integer;

    FCurX, FCurY   : Integer;   { 0-based, relative to visible top }
    FCurVis        : Boolean;
    FScrollTop, FScrollBot : Integer;
    FSavedX, FSavedY       : Integer;
    FCurAttr       : TAttr;

    { Scrollbar — FViewOffset=0 means live, N means scrolled back N lines }
    FSB            : TScrollBar;
    FViewOffset    : Integer;

    { Parser }
    FState         : (psNormal, psEsc, psCSI);
    FParams        : array[0..15] of Integer;
    FParamCount, FParamAccum : Integer;
    FParamSeen, FPrivate     : Boolean;

    { Blink }
    FBlink         : TTimer;
    FBlinkOn       : Boolean;

    FOnKey         : TKeyCallback;
    FOnPaste       : TPasteCallback;

    { Mouse selection }
    FSelActive     : Boolean;
    FSelecting     : Boolean;
    FSelStartCol   : Integer;
    FSelStartRow   : Integer;   { visible row at selection start }
    FSelEndCol     : Integer;
    FSelEndRow     : Integer;
    FSelStartRing  : Integer;   { ring index at selection start (stable across scrolls) }
    FSelEndRing    : Integer;

    function  RingRow(visRow: Integer): Integer; inline;
    procedure InitCell(var c: TCell);
    procedure BlankRingRow(ringIdx: Integer);
    procedure BlankVisRange(visRow, c1, c2: Integer);
    procedure ScrollUp(top, bot: Integer);
    procedure ScrollDown(top, bot: Integer);
    procedure MeasureFont;
    procedure AllocBuffer;
    procedure UpdateSB;
    function  P(idx, def: Integer): Integer;
    procedure DoCSI(fb: Byte);
    procedure DoDEC(fb: Byte);
    procedure DoSGR;
    procedure Advance;
    procedure DoLF;
    procedure DoCR;
    procedure DoBS;
    procedure DoTab;
    procedure OnBlink(Sender: TObject);
    procedure OnSBChange(Sender: TObject);
    procedure DoKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure DoKeyPress(Sender: TObject; var Key: Char);
    procedure TermMouseDown(Sender: TObject; Button: TMouseButton;
                            {%H-}Shift: TShiftState; X, Y: Integer);
    procedure TermMouseMove(Sender: TObject; {%H-}Shift: TShiftState; X, Y: Integer);
    procedure TermMouseUp(Sender: TObject; {%H-}Button: TMouseButton;
                          {%H-}Shift: TShiftState; X, Y: Integer);
    function  GetSelectedText: string;
    procedure CopySelection;
    function  CellInSelection(ringIdx, col: Integer): Boolean;
    function  ColourOf(idx: Byte; bright: Boolean): TColor;
  protected
    procedure Paint; override;
    procedure Resize; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor  Destroy; override;
    procedure WriteChar(ch: Byte);
    procedure FlushDisplay;
    procedure ResetTerminal;
    property OnKey   : TKeyCallback   read FOnKey   write FOnKey;
    property OnPaste : TPasteCallback read FOnPaste write FOnPaste;
    property Cols    : Integer        read FCols;
    property Rows    : Integer        read FRows;
  end;

implementation

const
  VT_COL : array[0..15] of TColor = (
    $000000, $0000CC, $00AA00, $00AAAA,
    $CC0000, $AA00AA, $AAAA00, $FFFFFF,   { 7=white }
    $555555, $5555FF, $55FF55, $55FFFF,
    $FF5555, $FF55FF, $FFFF55, $FFFFFF);  { 15=bright white }
  DEF_FG = 0;   { black }
  DEF_BG = 7;   { white }

function TK16Terminal.ColourOf(idx: Byte; bright: Boolean): TColor;
var i: Integer;
begin
  i := idx and $0F;
  if bright and (i < 8) then Inc(i, 8);
  Result := VT_COL[i];
end;

procedure TK16Terminal.InitCell(var c: TCell);
begin
  c.Ch := ' '; c.Attr.FG := DEF_FG; c.Attr.BG := DEF_BG;
  c.Attr.Bold := False; c.Attr.Reverse := False;
end;

{ RingRow: convert visible row (0=top of screen) to ring buffer index }
function TK16Terminal.RingRow(visRow: Integer): Integer;
begin
  { Visible top = FWriteRow - FRows }
  Result := (FWriteRow - FRows + visRow + FTotalLines) mod FTotalLines;
end;

procedure TK16Terminal.BlankRingRow(ringIdx: Integer);
var c: Integer;
begin
  ringIdx := ringIdx mod FTotalLines;
  for c := 0 to FCols-1 do InitCell(FBuf[ringIdx][c]);
end;

procedure TK16Terminal.BlankVisRange(visRow, c1, c2: Integer);
var c: Integer; cell: TCell; ri: Integer;
begin
  InitCell(cell);
  cell.Attr.FG := FCurAttr.FG; cell.Attr.BG := FCurAttr.BG;
  ri := RingRow(visRow);
  for c := c1 to c2 do
    if (c >= 0) and (c < FCols) then FBuf[ri][c] := cell;
end;

procedure TK16Terminal.ScrollUp(top, bot: Integer);
{ Scroll visible rows [top..bot] up 1. Bottom row blanked.
  When top=0, advance FWriteRow (ring advances naturally). }
var r, src, dst: Integer;
begin
  if top = 0 then
  begin
    { Advance the ring — old top row becomes new bottom row slot }
    FWriteRow := (FWriteRow + 1) mod FTotalLines;
    BlankRingRow(FWriteRow - 1 + FTotalLines);  { blank new bottom }
  end
  else
  begin
    { Scroll within region: shift rows up, blank bottom }
    for r := top to bot - 1 do
    begin
      dst := RingRow(r);
      src := RingRow(r + 1);
      FBuf[dst] := FBuf[src];
    end;
    BlankRingRow(RingRow(bot));
  end;
end;

procedure TK16Terminal.ScrollDown(top, bot: Integer);
var r, src, dst: Integer;
begin
  for r := bot downto top + 1 do
  begin
    dst := RingRow(r);
    src := RingRow(r - 1);
    FBuf[dst] := FBuf[src];
  end;
  BlankRingRow(RingRow(top));
end;

procedure TK16Terminal.MeasureFont;
var bmp: TBitmap;
begin
  bmp := TBitmap.Create;
  try
    bmp.Width := 1; bmp.Height := 1;
    bmp.Canvas.Font.Name    := FONT_NAME;
    bmp.Canvas.Font.Height  := FONT_HEIGHT;
    bmp.Canvas.Font.Quality := fqDraft;
    bmp.Canvas.Font.Style   := [];
    FCellW := bmp.Canvas.TextWidth('W');
    FCellH := bmp.Canvas.TextHeight('W');
  finally bmp.Free; end;
  if FCellW < 4  then FCellW := 10;
  if FCellH < 8  then FCellH := 18;
end;

procedure TK16Terminal.AllocBuffer;
var r, c: Integer;
begin
  FTotalLines := SCROLLBACK_LINES + FRows;
  SetLength(FBuf, FTotalLines);
  for r := 0 to FTotalLines - 1 do
  begin
    SetLength(FBuf[r], FCols);
    for c := 0 to FCols - 1 do InitCell(FBuf[r][c]);
  end;
  FWriteRow := FRows;   { visible rows are 0..FRows-1 initially }
end;

procedure TK16Terminal.UpdateSB;
{ Scrollback available = how many lines have been scrolled off = FWriteRow - FRows.
  If negative (hasn't filled yet), clamp to 0. }
var avail: Integer;
begin
  if FSB = nil then Exit;
  avail := FWriteRow - FRows;
  if avail < 0 then avail := 0;
  FSB.OnChange    := nil;
  FSB.Min         := 0;
  FSB.Max         := avail + FRows - 1;
  FSB.PageSize    := FRows;
  FSB.LargeChange := FRows;
  FSB.SmallChange := 1;
  { Position at bottom = avail (thumb at bottom of scrollback) }
  FSB.Position    := Max(0, avail - FViewOffset);
  FSB.OnChange    := OnSBChange;
end;

procedure TK16Terminal.OnSBChange(Sender: TObject);
var avail: Integer;
begin
  avail := FWriteRow - FRows;
  if avail < 0 then avail := 0;
  FViewOffset := avail - FSB.Position;
  if FViewOffset < 0 then FViewOffset := 0;
  if FViewOffset > avail then FViewOffset := avail;
  Invalidate;
end;

procedure TK16Terminal.Resize;
var newCols, newRows: Integer;
begin
  inherited;
  if FSB = nil then Exit;
  if FCellW = 0 then MeasureFont;
  newCols := Max(10, (Width - FSB.Width) div FCellW);
  newRows := Max(3,   Height div FCellH);
  if (newCols <> FCols) or (newRows <> FRows) or not FReady then
  begin
    FCols := newCols; FRows := newRows;
    AllocBuffer;
    if FCurX >= FCols then FCurX := FCols - 1;
    if FCurY >= FRows then FCurY := FRows - 1;
    FScrollTop := 0; FScrollBot := FRows - 1;
    FReady := True;
    UpdateSB;
    Invalidate;
  end;
end;

constructor TK16Terminal.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  TabStop := True; Color := clBlack;
  FCurVis := True; FBlinkOn := True; FViewOffset := 0; FReady := False;
  FCurAttr.FG := DEF_FG; FCurAttr.BG := DEF_BG;
  FCurAttr.Bold := False; FCurAttr.Reverse := False;
  FState := psNormal;
  FSB := TScrollBar.Create(Self);
  FSB.Kind := sbVertical; FSB.Parent := Self;
  FSB.Align := alRight; FSB.OnChange := OnSBChange;
  FSB.Width := GetSystemMetrics(SM_CXVSCROLL);
  FBlink := TTimer.Create(Self);
  FBlink.Interval := 500; FBlink.OnTimer := OnBlink; FBlink.Enabled := True;
  OnKeyDown  := DoKeyDown;
  OnKeyPress := DoKeyPress;
  OnMouseDown := TermMouseDown;
  OnMouseMove := TermMouseMove;
  OnMouseUp   := TermMouseUp;
  MeasureFont;
end;

destructor TK16Terminal.Destroy;
begin FBlink.Free; inherited; end;

procedure TK16Terminal.Paint;
var
  row, col    : Integer;
  cell        : TCell;
  fg, bg, tmp : TColor;
  x, y        : Integer;
  ch          : string;
  ringIdx     : Integer;
  drawCursor  : Boolean;
  isCursor    : Boolean;
  viewWriteRow: Integer;   { FWriteRow adjusted for scrollback view }
begin
  if not FReady then
  begin
    Canvas.Brush.Color := clWhite;
    Canvas.FillRect(ClientRect);
    Exit;
  end;

  Canvas.Font.Name    := FONT_NAME;
  Canvas.Font.Height  := FONT_HEIGHT;
  Canvas.Font.Quality := fqDraft;
  Canvas.Font.Style   := [];

  { Fill entire area with default background first — covers any gaps }
  Canvas.Brush.Color := ColourOf(DEF_BG, False);
  Canvas.FillRect(Rect(0, 0, Width - FSB.Width, Height));

  { When scrolled back, we view FViewOffset lines before current write pos }
  viewWriteRow := FWriteRow - FViewOffset;
  if viewWriteRow < FRows then viewWriteRow := FRows;  { clamp }

  drawCursor := FCurVis and FBlinkOn and Focused and (FViewOffset = 0);

  for row := 0 to FRows - 1 do
  begin
    y := row * FCellH;
    { Ring index for this visible row }
    ringIdx := (viewWriteRow - FRows + row + FTotalLines) mod FTotalLines;

    for col := 0 to FCols - 1 do
    begin
      x := col * FCellW;
      if col < Length(FBuf[ringIdx]) then
        cell := FBuf[ringIdx][col]
      else
        InitCell(cell);

      isCursor := drawCursor and (row = FCurY) and (col = FCurX);
      fg := ColourOf(cell.Attr.FG, cell.Attr.Bold);
      bg := ColourOf(cell.Attr.BG, False);
      if cell.Attr.Reverse or isCursor then
      begin tmp := fg; fg := bg; bg := TColor(tmp); end;
      { Selection highlight }
      if FSelActive and CellInSelection(ringIdx, col) then
      begin fg := clWhite; bg := clNavy; end;

      Canvas.Brush.Color := bg; Canvas.Font.Color := fg;
      if cell.Attr.Bold then Canvas.Font.Style := [fsBold]
      else Canvas.Font.Style := [];
      Canvas.FillRect(Rect(x, y, x + FCellW, y + FCellH));
      ch := cell.Ch;
      if (ch <> ' ') and (ch <> #0) then Canvas.TextOut(x, y, ch);
    end;
  end;

  { Fill any partial column strip at right edge }
  x := FCols * FCellW;
  if x < Width - FSB.Width then
  begin
    Canvas.Brush.Color := ColourOf(DEF_BG, False);
    Canvas.FillRect(Rect(x, 0, Width - FSB.Width, Height));
  end;
  { Fill any partial row strip at bottom edge }
  y := FRows * FCellH;
  if y < Height then
  begin
    Canvas.Brush.Color := ColourOf(DEF_BG, False);
    Canvas.FillRect(Rect(0, y, Width - FSB.Width, Height));
  end;
end;

procedure TK16Terminal.OnBlink(Sender: TObject);
begin
  if not FCurVis then Exit;
  FBlinkOn := not FBlinkOn;
  Invalidate;
end;

procedure TK16Terminal.Advance;
begin
  Inc(FCurX);
  if FCurX >= FCols then begin FCurX := 0; DoLF; end;
end;

procedure TK16Terminal.DoLF;
begin
  if FCurY >= FScrollBot then
    ScrollUp(FScrollTop, FScrollBot)
  else
  if FCurY < FRows - 1 then
    Inc(FCurY);
end;

procedure TK16Terminal.DoCR;  begin FCurX := 0; end;
procedure TK16Terminal.DoBS;  begin if FCurX > 0 then Dec(FCurX); end;
procedure TK16Terminal.DoTab;
begin
  FCurX := ((FCurX div 8) + 1) * 8;
  if FCurX >= FCols then FCurX := FCols - 1;
end;

procedure TK16Terminal.WriteChar(ch: Byte);
var cell: TCell; ri: Integer;
begin
  if not FReady then Exit;
  case FState of
    psNormal:
      case ch of
        8:  DoBS;
        9:  DoTab;
        10: begin DoCR; DoLF; end;
        13: DoCR;
        27: FState := psEsc;
        32..126, 128..255:
          begin
            cell.Ch := Chr(ch); cell.Attr := FCurAttr;
            if (FCurX >= 0) and (FCurX < FCols) and
               (FCurY >= 0) and (FCurY < FRows) then
            begin
              ri := RingRow(FCurY);
              if ri < FTotalLines then FBuf[ri][FCurX] := cell;
            end;
            Advance;
          end;
      end;
    psEsc:
      case ch of
        Ord('['):
          begin
            FState := psCSI; FParamCount := 0; FParamAccum := 0;
            FParamSeen := False; FPrivate := False;
            FillChar(FParams, SizeOf(FParams), 0);
          end;
        Ord('c'): ResetTerminal;
        Ord('7'): begin FSavedX := FCurX; FSavedY := FCurY; FState := psNormal; end;
        Ord('8'): begin FCurX := FSavedX; FCurY := FSavedY; FState := psNormal; end;
        Ord('M'):
          begin
            if FCurY = FScrollTop then ScrollDown(FScrollTop, FScrollBot)
            else if FCurY > 0 then Dec(FCurY);
            FState := psNormal;
          end;
      else FState := psNormal;
      end;
    psCSI:
      case ch of
        Ord('0')..Ord('9'):
          begin FParamAccum := FParamAccum * 10 + (ch - Ord('0')); FParamSeen := True; end;
        Ord(';'):
          begin
            if FParamCount <= High(FParams) then
            begin FParams[FParamCount] := FParamAccum; Inc(FParamCount); end;
            FParamAccum := 0; FParamSeen := False;
          end;
        Ord('?'): FPrivate := True;
      else
        if FParamSeen or (FParamCount = 0) then
          if FParamCount <= High(FParams) then
          begin FParams[FParamCount] := FParamAccum; Inc(FParamCount); end;
        if FPrivate then DoDEC(ch) else DoCSI(ch);
        FState := psNormal;
      end;
  end;
  { Snap to live view on any output }
  FViewOffset := 0;
end;

function TK16Terminal.P(idx, def: Integer): Integer;
begin
  if (idx < FParamCount) and (FParams[idx] <> 0) then Result := FParams[idx]
  else Result := def;
end;

procedure TK16Terminal.DoCSI(fb: Byte);
var n, r, c: Integer;
begin
  case Chr(fb) of
    'A': FCurY := Max(FScrollTop, FCurY - P(0,1));
    'B': FCurY := Min(FScrollBot, FCurY + P(0,1));
    'C': FCurX := Min(FCols-1,    FCurX + P(0,1));
    'D': FCurX := Max(0,          FCurX - P(0,1));
    'E': begin FCurX := 0; FCurY := Min(FRows-1, FCurY + P(0,1)); end;
    'F': begin FCurX := 0; FCurY := Max(0,       FCurY - P(0,1)); end;
    'G': FCurX := Max(0, Min(FCols-1, P(0,1)-1));
    'H','f':
      begin
        FCurY := Max(0, Min(FRows-1, P(0,1)-1));
        FCurX := Max(0, Min(FCols-1, P(1,1)-1));
      end;
    'J':
      case P(0,0) of
        0: begin BlankVisRange(FCurY, FCurX, FCols-1);
                 for r := FCurY+1 to FRows-1 do BlankRingRow(RingRow(r)); end;
        1: begin BlankVisRange(FCurY, 0, FCurX);
                 for r := 0 to FCurY-1 do BlankRingRow(RingRow(r)); end;
        2: begin for r := 0 to FRows-1 do BlankRingRow(RingRow(r));
                 FCurX := 0; FCurY := 0; end;
      end;
    'K':
      case P(0,0) of
        0: BlankVisRange(FCurY, FCurX, FCols-1);
        1: BlankVisRange(FCurY, 0, FCurX);
        2: BlankVisRange(FCurY, 0, FCols-1);
      end;
    'L': begin n := P(0,1); for r := 1 to n do ScrollDown(FCurY, FScrollBot); end;
    'M': begin n := P(0,1); for r := 1 to n do ScrollUp(FCurY, FScrollBot); end;
    'P':
      begin
        n := P(0,1);
        for c := FCurX to FCols-1-n do
          FBuf[RingRow(FCurY)][c] := FBuf[RingRow(FCurY)][c+n];
        BlankVisRange(FCurY, FCols-n, FCols-1);
      end;
    'S': begin n := P(0,1); for r := 1 to n do ScrollUp(FScrollTop, FScrollBot); end;
    'T': begin n := P(0,1); for r := 1 to n do ScrollDown(FScrollTop, FScrollBot); end;
    'r':
      begin
        FScrollTop := Max(0, Min(FRows-2, P(0,1)-1));
        FScrollBot := Max(FScrollTop+1, Min(FRows-1, P(1,FRows)-1));
        FCurX := 0; FCurY := 0;
      end;
    's': begin FSavedX := FCurX; FSavedY := FCurY; end;
    'u': begin FCurX := FSavedX; FCurY := FSavedY; end;
    'm': DoSGR;
  end;
end;

procedure TK16Terminal.DoDEC(fb: Byte);
begin
  case Chr(fb) of
    'h': if FParams[0] = 25 then FCurVis := True;
    'l': if FParams[0] = 25 then FCurVis := False;
  end;
end;

procedure TK16Terminal.DoSGR;
var i, v: Integer;
begin
  if FParamCount = 0 then
  begin
    FCurAttr.FG := DEF_FG; FCurAttr.BG := DEF_BG;
    FCurAttr.Bold := False; FCurAttr.Reverse := False; Exit;
  end;
  for i := 0 to FParamCount-1 do
  begin
    v := FParams[i];
    case v of
      0:        begin FCurAttr.FG := DEF_FG; FCurAttr.BG := DEF_BG;
                      FCurAttr.Bold := False; FCurAttr.Reverse := False; end;
      1:        FCurAttr.Bold    := True;
      7:        FCurAttr.Reverse := True;
      22:       FCurAttr.Bold    := False;
      27:       FCurAttr.Reverse := False;
      30..37:   FCurAttr.FG     := v-30;
      39:       FCurAttr.FG     := DEF_FG;
      40..47:   FCurAttr.BG     := v-40;
      49:       FCurAttr.BG     := DEF_BG;
      90..97:   FCurAttr.FG     := (v-90)+8;
      100..107: FCurAttr.BG     := v-100;
    end;
  end;
end;

procedure TK16Terminal.FlushDisplay;
begin
  FViewOffset := 0;
  UpdateSB;
  Invalidate;
end;

procedure TK16Terminal.ResetTerminal;
var r: Integer;
begin
  FCurX := 0; FCurY := 0; FSavedX := 0; FSavedY := 0;
  FScrollTop := 0; FScrollBot := Max(0, FRows-1);
  FCurVis := True; FViewOffset := 0; FState := psNormal;
  FCurAttr.FG := DEF_FG; FCurAttr.BG := DEF_BG;
  FCurAttr.Bold := False; FCurAttr.Reverse := False;
  for r := 0 to FTotalLines-1 do BlankRingRow(r);
  FWriteRow := FRows;
  UpdateSB; Invalidate;
end;

procedure TK16Terminal.TermMouseDown(Sender: TObject; Button: TMouseButton;
                                     Shift: TShiftState; X, Y: Integer);
var col, row, ri: Integer;
begin
  SetFocus;
  if Button = mbLeft then
  begin
    col := X div FCellW;
    row := Y div FCellH;
    if col >= FCols then col := FCols - 1;
    if row >= FRows then row := FRows - 1;
    ri := (FWriteRow - FViewOffset - FRows + row + FTotalLines) mod FTotalLines;
    FSelStartCol  := col;
    FSelStartRow  := row;
    FSelStartRing := ri;
    FSelEndCol    := col;
    FSelEndRow    := row;
    FSelEndRing   := ri;
    FSelActive    := False;
    FSelecting    := True;
    Invalidate;
  end;
end;

procedure TK16Terminal.TermMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
var col, row, ri: Integer;
begin
  if not FSelecting then Exit;
  col := X div FCellW;
  row := Y div FCellH;
  if col < 0 then col := 0;
  if col >= FCols then col := FCols - 1;
  if row < 0 then row := 0;
  if row >= FRows then row := FRows - 1;
  ri := (FWriteRow - FViewOffset - FRows + row + FTotalLines) mod FTotalLines;
  FSelEndCol    := col;
  FSelEndRow    := row;
  FSelEndRing   := ri;
  FSelActive    := (ri <> FSelStartRing) or (col <> FSelStartCol);
  Invalidate;
end;

procedure TK16Terminal.TermMouseUp(Sender: TObject; Button: TMouseButton;
                                   Shift: TShiftState; X, Y: Integer);
begin
  if FSelecting then
  begin
    FSelecting := False;
    if FSelActive then CopySelection;  { auto-copy on release like xterm }
    Invalidate;
  end;
end;

function TK16Terminal.CellInSelection(ringIdx, col: Integer): Boolean;
var
  sr, er, sc, ec, tmp: Integer;
begin
  Result := False;
  if not FSelActive then Exit;
  sr := FSelStartRing; sc := FSelStartCol;
  er := FSelEndRing;   ec := FSelEndCol;
  { Normalise so sr/sc <= er/ec in ring order }
  { Simple approach: use row numbers relative to view }
  { Compare ring indices adjusted to linear order }
  if (sr > er) or ((sr = er) and (sc > ec)) then
  begin
    tmp := sr; sr := er; er := tmp;
    tmp := sc; sc := ec; ec := tmp;
  end;
  if sr = er then
    Result := (ringIdx = sr) and (col >= sc) and (col <= ec)
  else if ringIdx = sr then
    Result := col >= sc
  else if ringIdx = er then
    Result := col <= ec
  else
  begin
    { ringIdx between sr and er — need to check modular order }
    if sr <= er then
      Result := (ringIdx > sr) and (ringIdx < er)
    else
      Result := (ringIdx > sr) or (ringIdx < er);
  end;
end;

function TK16Terminal.GetSelectedText: string;
var
  sr, er, sc, ec, tmp: Integer;
  ri, c: Integer;
  row: Integer;
  line: string;
begin
  Result := '';
  if not FSelActive then Exit;
  sr := FSelStartRing; sc := FSelStartCol;
  er := FSelEndRing;   ec := FSelEndCol;
  if (sr > er) or ((sr = er) and (sc > ec)) then
  begin
    tmp := sr; sr := er; er := tmp;
    tmp := sc; sc := ec; ec := tmp;
  end;
  { Walk from sr to er }
  ri := sr;
  repeat
    line := '';
    if ri = sr then c := sc else c := 0;
    while c < FCols do
    begin
      if ri = er then
      begin
        if c > ec then Break;
      end;
      if c < Length(FBuf[ri]) then
        line := line + FBuf[ri][c].Ch
      else
        line := line + ' ';
      Inc(c);
    end;
    { Trim trailing spaces from line }
    while (Length(line) > 0) and (line[Length(line)] = ' ') do
      Delete(line, Length(line), 1);
    if ri <> er then
      Result := Result + line + LineEnding
    else
      Result := Result + line;
    ri := (ri + 1) mod FTotalLines;
  until ri = (er + 1) mod FTotalLines;
end;

procedure TK16Terminal.CopySelection;
var s: string;
begin
  s := GetSelectedText;
  if s <> '' then Clipboard.AsText := s;
end;

procedure TK16Terminal.DoKeyPress({%H-}Sender: TObject; var Key: Char);
begin
  if Ord(Key) >= 32 then
  begin if Assigned(FOnKey) then FOnKey(Ord(Key)); Key := #0; end;
end;

procedure TK16Terminal.DoKeyDown({%H-}Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  case Key of
    VK_RETURN : if Assigned(FOnKey) then FOnKey(13);
    VK_BACK   : if Assigned(FOnKey) then FOnKey(8);
    VK_ESCAPE : if Assigned(FOnKey) then FOnKey(27);
    VK_TAB    : begin if Assigned(FOnKey) then FOnKey(9); Key := 0; end;
    VK_UP     : begin if Assigned(FOnKey) then begin FOnKey(27); FOnKey(Ord('[')); FOnKey(Ord('A')); end; Key := 0; end;
    VK_DOWN   : begin if Assigned(FOnKey) then begin FOnKey(27); FOnKey(Ord('[')); FOnKey(Ord('B')); end; Key := 0; end;
    VK_RIGHT  : begin if Assigned(FOnKey) then begin FOnKey(27); FOnKey(Ord('[')); FOnKey(Ord('C')); end; Key := 0; end;
    VK_LEFT   : begin if Assigned(FOnKey) then begin FOnKey(27); FOnKey(Ord('[')); FOnKey(Ord('D')); end; Key := 0; end;
    Ord('C')  : if ssCtrl in Shift then
                begin CopySelection; Key := 0; end;
    Ord('V')  : if ssCtrl in Shift then
                begin if Assigned(FOnPaste) then FOnPaste(Clipboard.AsText); Key := 0; end;
  end;
end;

end.
