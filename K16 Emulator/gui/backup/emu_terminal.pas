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
  LCLType, LCLIntf, StdCtrls, ExtCtrls, Clipbrd, Math, Menus;

const
  SCROLLBACK_LINES = 200;
  FONT_NAME        = 'Cascadia Mono';
  FONT_HEIGHT      = -18;
  TERM_PAD         = 6;   { internal pixel padding around the cell grid }

type
  TTermScheme = (tsWhite, tsGreen, tsAmber);

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
    FPopup         : TPopupMenu;
    FOnPaste       : TPasteCallback;
    FOnSchemeChange: TNotifyEvent;

    { Colour scheme }
    FScheme        : TTermScheme;
    FFGPal         : array[0..15] of TColor;
    FBGPal         : array[0..15] of TColor;
    FMiSchemeWhite : TMenuItem;
    FMiSchemeGreen : TMenuItem;
    FMiSchemeAmber : TMenuItem;

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
    procedure SaveAndCompactVisible;
    procedure ScrollUp(top, bot: Integer);
    procedure ScrollDown(top, bot: Integer);
    procedure MeasureFont;
    procedure AllocBuffer;
    procedure GrowBuffer;
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
    procedure MenuCopy(Sender: TObject);
    procedure MenuPaste(Sender: TObject);
    procedure MenuSelectAll(Sender: TObject);
    procedure MenuClear(Sender: TObject);
    procedure MenuSchemeWhite(Sender: TObject);
    procedure MenuSchemeGreen(Sender: TObject);
    procedure MenuSchemeAmber(Sender: TObject);
    procedure PopupMenuPopup(Sender: TObject);
    function  ColourOf(idx: Byte; bright, forBG: Boolean): TColor;
    procedure ApplyScheme(s: TTermScheme);
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
    property OnSchemeChange : TNotifyEvent read FOnSchemeChange write FOnSchemeChange;
    property Cols    : Integer        read FCols;
    property Rows    : Integer        read FRows;
    property Scheme  : TTermScheme    read FScheme  write ApplyScheme;
  end;

implementation

const
  { Reference VT100 palette — used as-is for the White scheme.
    DEF_FG = 0 (black), DEF_BG = 7 (white). }
  VT_COL : array[0..15] of TColor = (
    $000000, $0000CC, $00AA00, $00AAAA,
    $CC0000, $AA00AA, $AAAA00, $FFFFFF,   { 7=white }
    $555555, $5555FF, $55FF55, $55FFFF,
    $FF5555, $FF55FF, $FFFF55, $FFFFFF);  { 15=bright white }
  DEF_FG = 0;   { black }
  DEF_BG = 7;   { white }

  { Monochrome phosphor colours — TColor is $00BBGGRR (BGR) }
  GREEN_DIM    = $0033CC33;   { dim green     — BGR for #33CC33 (R=33 G=CC B=33) }
  GREEN_BRIGHT = $0066FF66;   { bright green  — #66FF66 }
  GREEN_BG     = $00081008;   { near-black with faint green tint }

  AMBER_DIM    = $0020A0E0;   { dim amber     — BGR for #E0A020 (R=E0 G=A0 B=20) }
  AMBER_BRIGHT = $0040C8FF;   { bright amber  — #FFC840 }
  AMBER_BG     = $00060810;   { near-black with faint warm tint }

procedure TK16Terminal.ApplyScheme(s: TTermScheme);
var i: Integer;
begin
  FScheme := s;
  case s of
    tsWhite:
      begin
        for i := 0 to 15 do
        begin
          FFGPal[i] := VT_COL[i];
          FBGPal[i] := VT_COL[i];
        end;
      end;
    tsGreen:
      begin
        for i := 0 to 7 do
        begin
          FFGPal[i]     := GREEN_DIM;
          FFGPal[i + 8] := GREEN_BRIGHT;
          FBGPal[i]     := GREEN_BG;
          FBGPal[i + 8] := GREEN_BG;
        end;
      end;
    tsAmber:
      begin
        for i := 0 to 7 do
        begin
          FFGPal[i]     := AMBER_DIM;
          FFGPal[i + 8] := AMBER_BRIGHT;
          FBGPal[i]     := AMBER_BG;
          FBGPal[i + 8] := AMBER_BG;
        end;
      end;
  end;
  if Assigned(FMiSchemeWhite) then FMiSchemeWhite.Checked := (s = tsWhite);
  if Assigned(FMiSchemeGreen) then FMiSchemeGreen.Checked := (s = tsGreen);
  if Assigned(FMiSchemeAmber) then FMiSchemeAmber.Checked := (s = tsAmber);
  Invalidate;
  if Assigned(FOnSchemeChange) then FOnSchemeChange(Self);
end;

function TK16Terminal.ColourOf(idx: Byte; bright, forBG: Boolean): TColor;
var i: Integer;
begin
  i := idx and $0F;
  if bright and (i < 8) then Inc(i, 8);
  if forBG then Result := FBGPal[i]
           else Result := FFGPal[i];
end;

procedure TK16Terminal.InitCell(var c: TCell);
begin
  c.Ch := ' '; c.Attr.FG := DEF_FG; c.Attr.BG := DEF_BG;
  c.Attr.Bold := False; c.Attr.Reverse := False;
end;

{ RingRow: convert visible row (0=top of screen) to ring buffer index }
function TK16Terminal.RingRow(visRow: Integer): Integer;
var idx: Integer;
begin
  idx := FWriteRow - FRows + visRow;
  Result := idx mod FTotalLines;
  if Result < 0 then Result := Result + FTotalLines;
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

procedure TK16Terminal.SaveAndCompactVisible;
{ ESC[3J support — clear scrollback while preserving the visible window.
  Saves the current visible rows, blanks the entire ring (visible AND
  scrollback), restores the visible rows into ring positions 0..FRows-1,
  and resets FWriteRow=FRows. After this, the screen looks unchanged but
  there is no accessible scrollback above it, and any subsequent ScrollUp
  pulls in blank rows (not stale history). }
var
  snapshot : array of array of TCell;
  r, c     : Integer;
begin
  if FTotalLines = 0 then Exit;

  { 1. Snapshot visible rows. }
  SetLength(snapshot, FRows);
  for r := 0 to FRows-1 do
  begin
    SetLength(snapshot[r], FCols);
    for c := 0 to FCols-1 do
      snapshot[r][c] := FBuf[RingRow(r)][c];
  end;

  { 2. Blank entire ring. }
  for r := 0 to FTotalLines-1 do BlankRingRow(r);

  { 3. Restore visible rows into ring positions 0..FRows-1. }
  for r := 0 to FRows-1 do
    for c := 0 to FCols-1 do
      FBuf[r][c] := snapshot[r][c];

  { 4. Reset ring pointer. Visible window now maps to ring 0..FRows-1
       with FRows-worth of blank slots ahead in the ring before
       wraparound — which is the natural "fresh boot" state. }
  FWriteRow := FRows;
  FViewOffset := 0;
end;

procedure TK16Terminal.ScrollUp(top, bot: Integer);
{ Scroll visible rows [top..bot] up 1. Bottom row blanked.
  When top=0, advance FWriteRow (ring advances naturally). }
var r, src, dst: Integer;
begin
  if top = 0 then
  begin
    { Advance the ring — old top row becomes new bottom row slot }
    Inc(FWriteRow);   { never mod — RingRow handles the modular indexing }
    BlankRingRow((FWriteRow - 1) mod FTotalLines);  { blank new bottom }
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
  FWriteRow := FRows;   { reset to initial position }   { visible rows are 0..FRows-1 initially }
end;

procedure TK16Terminal.GrowBuffer;
{ Resize FBuf to current FCols/FRows WITHOUT wiping existing cells. Used
  by Resize so window-drag doesn't blank the screen. SetLength preserves
  existing array contents up to min(old,new); only freshly-added rows /
  cells need explicit InitCell.

  Note FTotalLines depends on FRows. If FRows grows, FTotalLines grows;
  if FRows shrinks, FTotalLines shrinks — and SetLength will TRUNCATE
  the outer dimension, dropping the oldest scrollback. To avoid that,
  we keep FTotalLines monotonic: it only ever grows. }
var
  r, c        : Integer;
  oldTotal    : Integer;
  oldCols     : Integer;
  newTotal    : Integer;
begin
  oldTotal := Length(FBuf);
  oldCols  := 0;
  if oldTotal > 0 then oldCols := Length(FBuf[0]);

  newTotal := SCROLLBACK_LINES + FRows;
  if newTotal < oldTotal then newTotal := oldTotal;  { monotonic — don't drop scrollback }
  FTotalLines := newTotal;

  SetLength(FBuf, FTotalLines);
  { Initialise any newly-added rows (beyond oldTotal). Existing rows are
    untouched in their outer dimension. }
  for r := oldTotal to FTotalLines - 1 do
  begin
    SetLength(FBuf[r], FCols);
    for c := 0 to FCols - 1 do InitCell(FBuf[r][c]);
  end;
  { For pre-existing rows, grow the per-row column count if needed.
    SetLength preserves existing cells; we only init the newly-added
    cells past oldCols. }
  if FCols > oldCols then
    for r := 0 to oldTotal - 1 do
    begin
      SetLength(FBuf[r], FCols);
      for c := oldCols to FCols - 1 do InitCell(FBuf[r][c]);
    end;
end;

procedure TK16Terminal.UpdateSB;
{ Scrollback available = how many lines have been scrolled off = FWriteRow - FRows.
  If negative (hasn't filled yet), clamp to 0. }
var avail: Integer;
begin
  if FSB = nil then Exit;
  avail := FWriteRow - FRows;
  if avail < 0 then avail := 0;
  if avail > SCROLLBACK_LINES then avail := SCROLLBACK_LINES;  { cap at buffer size }
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
  if avail > SCROLLBACK_LINES then avail := SCROLLBACK_LINES;  { cap at buffer size }
  FViewOffset := avail - FSB.Position;
  if FViewOffset < 0 then FViewOffset := 0;
  if FViewOffset > avail then FViewOffset := avail;
  Invalidate;
end;

procedure TK16Terminal.Resize;
var
  newCols, newRows: Integer;
  oldRows         : Integer;
  oldCurYFromBot  : Integer;
begin
  inherited;
  if FSB = nil then Exit;
  if FCellW = 0 then MeasureFont;
  { 80-col floor: kosh output is formatted for 80 cols; narrower wraps
    and the wrap is overwritten by the next line before any subsequent
    resize can save it. Wider windows grow FCols normally. }
  newCols := Max(80, (Width - FSB.Width - 2 * TERM_PAD) div FCellW);
  newRows := Max(3,   (Height - 2 * TERM_PAD) div FCellH);
  if (newCols <> FCols) or (newRows <> FRows) or not FReady then
  begin
    { Snapshot cursor's distance from the bottom row BEFORE FRows changes.
      Bottom of visible window is logical line FWriteRow-1 — same in old
      and new geometry — so preserving (rows-from-bottom) keeps the
      cursor on the same logical line, which is where kosh expects it. }
    if FReady then
    begin
      oldRows        := FRows;
      oldCurYFromBot := (oldRows - 1) - FCurY;   { 0 = bottom row }
    end
    else
    begin
      oldRows        := 0;
      oldCurYFromBot := 0;
    end;

    FCols := newCols; FRows := newRows;
    if FReady then
      GrowBuffer   { preserve existing cells across window resize }
    else
      AllocBuffer; { first init: clean blank buffer, FWriteRow := FRows }

    if oldRows > 0 then
    begin
      FCurY := (FRows - 1) - oldCurYFromBot;
      if FCurY < 0      then FCurY := 0;
      if FCurY >= FRows then FCurY := FRows - 1;
    end
    else
    begin
      if FCurY >= FRows then FCurY := FRows - 1;
    end;
    if FCurX >= FCols then FCurX := FCols - 1;

    FScrollTop := 0; FScrollBot := FRows - 1;
    FReady := True;
    UpdateSB;
    Invalidate;
  end;
end;

procedure AddMenuItem(Menu: TPopupMenu; const ACaption: string;
                     AClick: TNotifyEvent; AShortCut: TShortCut);
var item: TMenuItem;
begin
  item := TMenuItem.Create(Menu);
  item.Caption  := ACaption;
  item.OnClick  := AClick;
  item.ShortCut := AShortCut;
  Menu.Items.Add(item);
end;

function AddSubMenuItem(Parent: TMenuItem; const ACaption: string;
                        AClick: TNotifyEvent): TMenuItem;
begin
  Result := TMenuItem.Create(Parent);
  Result.Caption    := ACaption;
  Result.OnClick    := AClick;
  Result.RadioItem  := True;
  Result.GroupIndex := 1;
  Parent.Add(Result);
end;

constructor TK16Terminal.Create(AOwner: TComponent);
var schemeRoot: TMenuItem;
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

  { Right-click context menu }
  FPopup := TPopupMenu.Create(Self);
  FPopup.OnPopup := PopupMenuPopup;
  AddMenuItem(FPopup, 'Copy',       MenuCopy,      ShortCut(Ord('C'), [ssCtrl]));
  AddMenuItem(FPopup, 'Paste',      MenuPaste,     ShortCut(Ord('V'), [ssCtrl]));
  AddMenuItem(FPopup, '-',          nil,            0);
  AddMenuItem(FPopup, 'Select All', MenuSelectAll, ShortCut(Ord('A'), [ssCtrl]));
  AddMenuItem(FPopup, '-',          nil,            0);
  AddMenuItem(FPopup, 'Clear',      MenuClear,     0);
  AddMenuItem(FPopup, '-',          nil,            0);
  schemeRoot := TMenuItem.Create(FPopup);
  schemeRoot.Caption := 'Colour Scheme';
  FPopup.Items.Add(schemeRoot);
  FMiSchemeWhite := AddSubMenuItem(schemeRoot, 'White', MenuSchemeWhite);
  FMiSchemeGreen := AddSubMenuItem(schemeRoot, 'Green', MenuSchemeGreen);
  FMiSchemeAmber := AddSubMenuItem(schemeRoot, 'Amber', MenuSchemeAmber);
  PopupMenu := FPopup;

  ApplyScheme(tsWhite);   { default — also sets check marks }
  MeasureFont;
end;

procedure TK16Terminal.MenuSchemeWhite(Sender: TObject); begin ApplyScheme(tsWhite); end;
procedure TK16Terminal.MenuSchemeGreen(Sender: TObject); begin ApplyScheme(tsGreen); end;
procedure TK16Terminal.MenuSchemeAmber(Sender: TObject); begin ApplyScheme(tsAmber); end;

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
  Canvas.Brush.Color := ColourOf(DEF_BG, False, True);
  Canvas.FillRect(Rect(0, 0, Width - FSB.Width, Height));

  { When scrolled back, we view FViewOffset lines before current write pos }
  viewWriteRow := FWriteRow - FViewOffset;
  if viewWriteRow < FRows then viewWriteRow := FRows;  { clamp }

  drawCursor := FCurVis and FBlinkOn and Focused and (FViewOffset = 0);

  for row := 0 to FRows - 1 do
  begin
    y := TERM_PAD + row * FCellH;
    { Ring index for this visible row }
    ringIdx := (viewWriteRow - FRows + row) mod FTotalLines;
    if ringIdx < 0 then ringIdx := ringIdx + FTotalLines;

    for col := 0 to FCols - 1 do
    begin
      x := TERM_PAD + col * FCellW;
      if col < Length(FBuf[ringIdx]) then
        cell := FBuf[ringIdx][col]
      else
        InitCell(cell);

      isCursor := drawCursor and (row = FCurY) and (col = FCurX);
      fg := ColourOf(cell.Attr.FG, cell.Attr.Bold, False);
      bg := ColourOf(cell.Attr.BG, False, True);
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

  { Fill any partial column strip at right edge — between cell grid and scrollbar }
  x := TERM_PAD + FCols * FCellW;
  if x < Width - FSB.Width then
  begin
    Canvas.Brush.Color := ColourOf(DEF_BG, False, True);
    Canvas.FillRect(Rect(x, 0, Width - FSB.Width, Height));
  end;
  { Fill any partial row strip at bottom edge }
  y := TERM_PAD + FRows * FCellH;
  if y < Height then
  begin
    Canvas.Brush.Color := ColourOf(DEF_BG, False, True);
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
                 { Per xterm/VT100 spec, ESC[2J does NOT move the cursor.
                   (Some early DOS terminals did move it; we follow the
                   modern standard. Callers wanting to home should send
                   ESC[H separately.) }
                 end;
        3: begin
                 { Erase scrollback buffer (xterm extension). The visible
                   window keeps its content; only the off-screen history
                   is cleared. Implementation: save the visible rows,
                   blank the entire ring, restore the visible rows back
                   into ring positions 0..FRows-1, reset FWriteRow=FRows.
                   This makes the visible content unchanged but ensures
                   any subsequent ScrollUp pulls in blank rows from
                   above instead of stale scrollback content. }
                 SaveAndCompactVisible;
                 UpdateSB;
                 end;
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

procedure TK16Terminal.PopupMenuPopup({%H-}Sender: TObject);
begin
  { Enable Copy only when there is a selection }
  FPopup.Items[0].Enabled := FSelActive;
end;

procedure TK16Terminal.MenuCopy({%H-}Sender: TObject);
begin
  CopySelection;
end;

procedure TK16Terminal.MenuPaste({%H-}Sender: TObject);
begin
  if Assigned(FOnPaste) then FOnPaste(Clipboard.AsText);
end;

procedure TK16Terminal.MenuSelectAll({%H-}Sender: TObject);
{ Select all visible content — from first non-empty ring row to current bottom }
var firstRow, ringIdx, c: Integer; hasContent: Boolean;
begin
  { Find first row with content }
  firstRow := 0;
  while firstRow < FTotalLines do
  begin
    ringIdx := (FWriteRow - FRows - firstRow + FTotalLines * 10) mod FTotalLines;
    hasContent := False;
    for c := 0 to FCols - 1 do
      if (c < Length(FBuf[ringIdx])) and (FBuf[ringIdx][c].Ch <> ' ') then
      begin hasContent := True; Break; end;
    if hasContent then Break;
    Inc(firstRow);
  end;
  { Select from top of scrollback to current cursor }
  FSelStartRing := (FWriteRow - FRows - firstRow + FTotalLines * 10) mod FTotalLines;
  FSelStartCol  := 0;
  FSelEndRing   := RingRow(FCurY);
  FSelEndCol    := FCurX;
  FSelActive    := True;
  CopySelection;
  Invalidate;
end;

procedure TK16Terminal.MenuClear({%H-}Sender: TObject);
begin
  ResetTerminal;
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
  FWriteRow := FRows;   { reset to initial position }
  UpdateSB; Invalidate;
end;

procedure TK16Terminal.TermMouseDown(Sender: TObject; Button: TMouseButton;
                                     Shift: TShiftState; X, Y: Integer);
var col, row, ri: Integer;
begin
  SetFocus;
  if Button = mbLeft then
  begin
    col := (X - TERM_PAD) div FCellW;
    row := (Y - TERM_PAD) div FCellH;
    if col < 0 then col := 0;
    if row < 0 then row := 0;
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
  col := (X - TERM_PAD) div FCellW;
  row := (Y - TERM_PAD) div FCellH;
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
    VK_RIGHT  : begin
                  if ssCtrl in Shift then
                    { Ctrl-Right == Ctrl-N (next shell) }
                    begin if Assigned(FOnKey) then FOnKey($0E); end
                  else
                    if Assigned(FOnKey) then begin FOnKey(27); FOnKey(Ord('[')); FOnKey(Ord('C')); end;
                  Key := 0;
                end;
    VK_LEFT   : begin
                  if ssCtrl in Shift then
                    { Ctrl-Left == Ctrl-P (prev shell) }
                    begin if Assigned(FOnKey) then FOnKey($10); end
                  else
                    if Assigned(FOnKey) then begin FOnKey(27); FOnKey(Ord('[')); FOnKey(Ord('D')); end;
                  Key := 0;
                end;
    Ord('A')  : if ssCtrl in Shift then
                begin MenuSelectAll(nil); Key := 0; end;
    Ord('C')  : if ssCtrl in Shift then
                begin CopySelection; Key := 0; end;
    Ord('V')  : if ssCtrl in Shift then
                begin if Assigned(FOnPaste) then FOnPaste(Clipboard.AsText); Key := 0; end;

    { ---- k/OS Phase B foreground-switcher hot keys --------------------- }
    Ord('N')  : if ssCtrl in Shift then
                begin if Assigned(FOnKey) then FOnKey($0E); Key := 0; end;
    Ord('P')  : if ssCtrl in Shift then
                begin if Assigned(FOnKey) then FOnKey($10); Key := 0; end;

    { Ctrl-1..9 -> $81..$89, Ctrl-0 -> $8A   (EMU only; "shell 10" = $8A) }
    Ord('1')  : if ssCtrl in Shift then
                begin if Assigned(FOnKey) then FOnKey($81); Key := 0; end;
    Ord('2')  : if ssCtrl in Shift then
                begin if Assigned(FOnKey) then FOnKey($82); Key := 0; end;
    Ord('3')  : if ssCtrl in Shift then
                begin if Assigned(FOnKey) then FOnKey($83); Key := 0; end;
    Ord('4')  : if ssCtrl in Shift then
                begin if Assigned(FOnKey) then FOnKey($84); Key := 0; end;
    Ord('5')  : if ssCtrl in Shift then
                begin if Assigned(FOnKey) then FOnKey($85); Key := 0; end;
    Ord('6')  : if ssCtrl in Shift then
                begin if Assigned(FOnKey) then FOnKey($86); Key := 0; end;
    Ord('7')  : if ssCtrl in Shift then
                begin if Assigned(FOnKey) then FOnKey($87); Key := 0; end;
    Ord('8')  : if ssCtrl in Shift then
                begin if Assigned(FOnKey) then FOnKey($88); Key := 0; end;
    Ord('9')  : if ssCtrl in Shift then
                begin if Assigned(FOnKey) then FOnKey($89); Key := 0; end;
    Ord('0')  : if ssCtrl in Shift then
                begin if Assigned(FOnKey) then FOnKey($8A); Key := 0; end;
  end;
end;

end.
