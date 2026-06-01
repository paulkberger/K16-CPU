unit emu_terminal;
{
  K16 Emulator IDE — VT100 Terminal Component
  A custom paint control implementing a VT100-compatible terminal.

  Features:
  - Dynamic rows/cols derived from panel size and fixed font metrics
  - Scrollback buffer (SCROLLBACK_LINES above visible area)
  - Host scrollbar for scrollback review; auto-scrolls to bottom on new output
  - VT100 parser: cursor movement, erase, SGR colours, scroll region
  - Blinking block cursor; solid when focused
  - Keyboard input only when focused; Ctrl+V paste support

  Part of the K16 homebrew CPU project.
  https://github.com/paulkberger/K16-CPU
}

{$mode Delphi}
{$H+}

interface

uses
  Classes, SysUtils, Controls, Graphics, Forms,
  LCLType, LCLIntf, StdCtrls, ExtCtrls, Clipbrd, Math;

const
  SCROLLBACK_LINES = 500;
  FONT_NAME        = 'Cascadia Mono';
  FONT_HEIGHT      = -18;

type
  TAttr = record
    FG      : Byte;
    BG      : Byte;
    Bold    : Boolean;
    Reverse : Boolean;
  end;

  TCell = record
    Ch   : Char;
    Attr : TAttr;
  end;

  TCellRow = array of TCell;

  TKeyCallback   = procedure(code: Word) of object;
  TPasteCallback = procedure(const s: string) of object;

  TK16Terminal = class(TCustomControl)
  private
    FCellW      : Integer;
    FCellH      : Integer;
    FCols       : Integer;
    FRows       : Integer;
    FReady      : Boolean;

    FBuffer     : array of TCellRow;
    FBufLines   : Integer;
    FBufTop     : Integer;

    FCurX       : Integer;
    FCurY       : Integer;
    FCurVis     : Boolean;

    FScrollTop  : Integer;
    FScrollBot  : Integer;

    FSavedX     : Integer;
    FSavedY     : Integer;

    FCurAttr    : TAttr;

    FDirtyAll   : Boolean;

    FState      : (psNormal, psEsc, psCSI);
    FParams     : array[0..15] of Integer;
    FParamCount : Integer;
    FParamAccum : Integer;
    FParamSeen  : Boolean;
    FPrivate    : Boolean;

    FBlink      : TTimer;
    FBlinkOn    : Boolean;

    FSB         : TScrollBar;
    FScrollPos  : Integer;

    FOnKey      : TKeyCallback;
    FOnPaste    : TPasteCallback;

    function  BufRow(visRow: Integer): Integer;
    procedure InitCell(var c: TCell);
    procedure BlankRow(bufIdx: Integer);
    procedure BlankRange(visRow, c1, c2: Integer);
    procedure ScrollUp(top, bot: Integer);
    procedure ScrollDown(top, bot: Integer);
    procedure SetDirty;
    procedure MeasureFont;
    procedure AllocBuffer(newRows: Integer);
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
                          Shift: TShiftState; X, Y: Integer);
    function  ColourOf(idx: Byte; bright: Boolean): TColor;
  protected
    procedure Paint; override;
    procedure Resize; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor  Destroy; override;
    procedure WriteChar(ch: Byte);   { process one byte — no repaint }
    procedure FlushDisplay;          { call after batching chars to repaint }
    procedure ResetTerminal;
    property OnKey   : TKeyCallback   read FOnKey   write FOnKey;
    property OnPaste : TPasteCallback read FOnPaste write FOnPaste;
    property Cols    : Integer        read FCols;
    property Rows    : Integer        read FRows;
  end;

implementation

const
  VT_COL : array[0..15] of TColor = (
    $000000, $0000AA, $00AA00, $00AAAA,
    $AA0000, $AA00AA, $AAAA00, $AAAAAA,
    $555555, $5555FF, $55FF55, $55FFFF,
    $FF5555, $FF55FF, $FFFF55, $FFFFFF
  );
  DEF_FG = 7;
  DEF_BG = 0;

function TK16Terminal.ColourOf(idx: Byte; bright: Boolean): TColor;
var i: Integer;
begin
  i := idx and $0F;
  if bright and (i < 8) then Inc(i, 8);
  Result := VT_COL[i];
end;

procedure TK16Terminal.InitCell(var c: TCell);
begin
  c.Ch          := ' ';
  c.Attr.FG     := DEF_FG;
  c.Attr.BG     := DEF_BG;
  c.Attr.Bold   := False;
  c.Attr.Reverse:= False;
end;

procedure TK16Terminal.BlankRow(bufIdx: Integer);
var c: Integer;
begin
  if (bufIdx < 0) or (bufIdx >= FBufLines) then Exit;
  for c := 0 to FCols - 1 do
    InitCell(FBuffer[bufIdx][c]);
end;

procedure TK16Terminal.BlankRange(visRow, c1, c2: Integer);
var c: Integer; cell: TCell;
begin
  InitCell(cell);
  cell.Attr.FG := FCurAttr.FG;
  cell.Attr.BG := FCurAttr.BG;
  for c := c1 to c2 do
    if (c >= 0) and (c < FCols) then
      FBuffer[BufRow(visRow)][c] := cell;
end;

function TK16Terminal.BufRow(visRow: Integer): Integer;
begin
  Result := FBufTop + visRow;
end;

procedure TK16Terminal.ScrollUp(top, bot: Integer);
var r: Integer;
begin
  if top = 0 then
  begin
    if FBufTop < FBufLines - FRows then
      Inc(FBufTop)
    else
    begin
      for r := 1 to FBufLines - 1 do
        FBuffer[r-1] := FBuffer[r];
    end;
    BlankRow(BufRow(bot));
  end
  else
  begin
    for r := top to bot - 1 do
      FBuffer[BufRow(r)] := FBuffer[BufRow(r+1)];
    BlankRow(BufRow(bot));
  end;
  SetDirty;
end;

procedure TK16Terminal.ScrollDown(top, bot: Integer);
var r: Integer;
begin
  for r := bot downto top + 1 do
    FBuffer[BufRow(r)] := FBuffer[BufRow(r-1)];
  BlankRow(BufRow(top));
  SetDirty;
end;

procedure TK16Terminal.SetDirty;
begin
  FDirtyAll := True;
end;

procedure TK16Terminal.MeasureFont;
var
  bmp : TBitmap;
begin
  { Use a scratch bitmap — safe before the control has a window handle }
  bmp := TBitmap.Create;
  try
    bmp.Width  := 1;
    bmp.Height := 1;
    bmp.Canvas.Font.Name    := FONT_NAME;
    bmp.Canvas.Font.Height  := FONT_HEIGHT;
    bmp.Canvas.Font.Quality := fqDraft;
    bmp.Canvas.Font.Style   := [];
    FCellW := bmp.Canvas.TextWidth('W');
    FCellH := bmp.Canvas.TextHeight('W');
  finally
    bmp.Free;
  end;
  if FCellW < 4 then FCellW := 10;
  if FCellH < 8 then FCellH := 18;
end;

procedure TK16Terminal.AllocBuffer(newRows: Integer);
var
  newLines : Integer;
  newBuf   : array of TCellRow;
  copyRows : Integer;
  r, c     : Integer;
begin
  newLines := SCROLLBACK_LINES + newRows;
  SetLength(newBuf, newLines);
  for r := 0 to newLines - 1 do
  begin
    SetLength(newBuf[r], FCols);
    for c := 0 to FCols - 1 do
      InitCell(newBuf[r][c]);
  end;
  if (FBufLines > 0) and (Length(FBuffer) > 0) then
  begin
    copyRows := Min(FRows, newRows);
    for r := 0 to copyRows - 1 do
      if (FBufTop + r < FBufLines) then
        for c := 0 to Min(FCols, Length(FBuffer[FBufTop + r])) - 1 do
          newBuf[SCROLLBACK_LINES + r][c] := FBuffer[FBufTop + r][c];
  end;
  FBuffer   := newBuf;
  FBufLines := newLines;
  FBufTop   := SCROLLBACK_LINES;
  FDirtyAll := True;
end;

procedure TK16Terminal.UpdateSB;
var avail: Integer;
begin
  if FSB = nil then Exit;
  avail := FBufTop - SCROLLBACK_LINES;
  if avail < 0 then avail := 0;
  { Disconnect OnChange to avoid re-entry while we set position }
  FSB.OnChange   := nil;
  FSB.Min        := 0;
  FSB.Max        := avail + FRows;   { thumb represents one page }
  FSB.PageSize   := FRows;
  FSB.LargeChange:= Max(1, FRows div 2);
  FSB.SmallChange:= 1;
  FSB.Position   := Max(0, avail - FScrollPos);  { avail = live bottom }
  FSB.OnChange   := OnSBChange;
end;

procedure TK16Terminal.OnSBChange(Sender: TObject);
var avail: Integer;
begin
  avail := FBufTop - SCROLLBACK_LINES;
  if avail < 0 then avail := 0;
  { FScrollPos=0 means live; higher = lines scrolled back }
  FScrollPos := avail - FSB.Position;
  if FScrollPos < 0 then FScrollPos := 0;
  if FScrollPos > avail then FScrollPos := avail;
  SetDirty;
  Invalidate;
end;

procedure TK16Terminal.Resize;
var
  sbW     : Integer;
  newCols : Integer;
  newRows : Integer;
begin
  inherited;
  if FSB = nil then Exit;
  if FCellW = 0 then MeasureFont;
  sbW     := FSB.Width;
  newCols := Max(10, (Width - sbW) div FCellW);
  newRows := Max(3,   Height       div FCellH);
  if (newCols <> FCols) or (newRows <> FRows) or not FReady then
  begin
    FCols := newCols;
    FRows := newRows;
    AllocBuffer(FRows);
    if FCurX >= FCols then FCurX := FCols - 1;
    if FCurY >= FRows then FCurY := FRows - 1;
    FScrollTop := 0;
    FScrollBot := FRows - 1;
    FReady     := True;
    UpdateSB;
    Invalidate;
  end;
end;

constructor TK16Terminal.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  TabStop      := True;
  Color        := clBlack;
  FCurVis      := True;
  FBlinkOn     := True;
  FScrollPos   := 0;
  FReady       := False;
  FCurAttr.FG  := DEF_FG;
  FCurAttr.BG  := DEF_BG;
  FCurAttr.Bold    := False;
  FCurAttr.Reverse := False;
  FState := psNormal;
  FSB              := TScrollBar.Create(Self);
  FSB.Kind         := sbVertical;
  FSB.Parent       := Self;
  FSB.Align        := alRight;
  FSB.OnChange     := OnSBChange;
  FSB.Width        := GetSystemMetrics(SM_CXVSCROLL);
  FBlink           := TTimer.Create(Self);
  FBlink.Interval  := 500;
  FBlink.OnTimer   := OnBlink;
  FBlink.Enabled   := True;
  OnKeyDown   := DoKeyDown;
  OnKeyPress  := DoKeyPress;
  OnMouseDown := TermMouseDown;

  { Measure font now so FCellW/FCellH are valid before first Resize }
  MeasureFont;
end;

destructor TK16Terminal.Destroy;
begin
  FBlink.Free;
  inherited;
end;

procedure TK16Terminal.Paint;
var
  row, col    : Integer;
  cell        : TCell;
  fg, bg, tmp : TColor;
  x, y        : Integer;
  ch          : string;
  viewTop     : Integer;
  drawCursor  : Boolean;
  isCursor    : Boolean;
begin
  if not FReady then
  begin
    Canvas.Brush.Color := clBlack;
    Canvas.FillRect(ClientRect);
    Exit;
  end;

  Canvas.Font.Name    := FONT_NAME;
  Canvas.Font.Height  := FONT_HEIGHT;
  Canvas.Font.Quality := fqDraft;

  viewTop    := FBufTop - FScrollPos;
  if viewTop < 0 then viewTop := 0;
  drawCursor := FCurVis and FBlinkOn and Focused and (FScrollPos = 0);

  for row := 0 to FRows - 1 do
  begin
    y := row * FCellH;
    for col := 0 to FCols - 1 do
    begin
      x := col * FCellW;
      if (viewTop + row < FBufLines) and (col < Length(FBuffer[viewTop + row])) then
        cell := FBuffer[viewTop + row][col]
      else
        InitCell(cell);

      isCursor := drawCursor and (row = FCurY) and (col = FCurX);

      fg := ColourOf(cell.Attr.FG, cell.Attr.Bold);
      bg := ColourOf(cell.Attr.BG, False);

      if cell.Attr.Reverse or isCursor then
      begin
        tmp := fg; fg := bg; bg := TColor(tmp);
      end;

      Canvas.Brush.Color := bg;
      Canvas.Font.Color  := fg;
      if cell.Attr.Bold then
        Canvas.Font.Style := [fsBold]
      else
        Canvas.Font.Style := [];

      Canvas.FillRect(Rect(x, y, x + FCellW, y + FCellH));
      ch := cell.Ch;
      if (ch <> ' ') and (ch <> #0) then
        Canvas.TextOut(x, y, ch);
    end;
  end;

  FDirtyAll := False;

  if Focused then
  begin
    Canvas.Brush.Style := bsClear;
    Canvas.Pen.Color   := clHighlight;
    Canvas.Pen.Width   := 2;
    Canvas.Rectangle(0, 0, Width - FSB.Width - 1, Height - 1);
    Canvas.Pen.Width   := 1;
    Canvas.Brush.Style := bsSolid;
  end;
end;

procedure TK16Terminal.OnBlink(Sender: TObject);
begin
  if not FCurVis then Exit;
  FBlinkOn := not FBlinkOn;
  SetDirty;
  Invalidate;
end;

procedure TK16Terminal.Advance;
begin
  Inc(FCurX);
  if FCurX >= FCols then
  begin
    FCurX := 0;
    DoLF;
  end;
end;

procedure TK16Terminal.DoLF;
begin
  if FCurY >= FScrollBot then
    ScrollUp(FScrollTop, FScrollBot)
  else
  if FCurY < FRows - 1 then
    Inc(FCurY);
end;

procedure TK16Terminal.DoCR;
begin
  FCurX := 0;
end;

procedure TK16Terminal.DoBS;
begin
  if FCurX > 0 then Dec(FCurX);
end;

procedure TK16Terminal.DoTab;
begin
  FCurX := ((FCurX div 8) + 1) * 8;
  if FCurX >= FCols then FCurX := FCols - 1;
end;

procedure TK16Terminal.WriteChar(ch: Byte);
var cell: TCell;
begin
  if not FReady then Exit;

  case FState of

    psNormal:
      case ch of
        8:  DoBS;
        9:  DoTab;
        10: begin DoCR; DoLF; end;   { LF implies CR for dumb terminal }
        13: DoCR;                    { bare CR — just return to col 0 }
        27: FState := psEsc;
        32..126, 128..255:
          begin
            cell.Ch   := Chr(ch);
            cell.Attr := FCurAttr;
            if (FCurX >= 0) and (FCurX < FCols) and
               (FCurY >= 0) and (FCurY < FRows) then
              FBuffer[BufRow(FCurY)][FCurX] := cell;
            Advance;
          end;
      end;

    psEsc:
      case ch of
        Ord('['):
          begin
            FState      := psCSI;
            FParamCount := 0;
            FParamAccum := 0;
            FParamSeen  := False;
            FPrivate    := False;
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
      else
        FState := psNormal;
      end;

    psCSI:
      case ch of
        Ord('0')..Ord('9'):
          begin
            FParamAccum := FParamAccum * 10 + (ch - Ord('0'));
            FParamSeen  := True;
          end;
        Ord(';'):
          begin
            if FParamCount <= High(FParams) then
            begin
              FParams[FParamCount] := FParamAccum;
              Inc(FParamCount);
            end;
            FParamAccum := 0;
            FParamSeen  := False;
          end;
        Ord('?'): FPrivate := True;
      else
        if FParamSeen or (FParamCount = 0) then
          if FParamCount <= High(FParams) then
          begin
            FParams[FParamCount] := FParamAccum;
            Inc(FParamCount);
          end;
        if FPrivate then DoDEC(ch) else DoCSI(ch);
        FState := psNormal;
      end;

  end;

  { Always snap to live view on output }
  FScrollPos := 0;
  { Note: caller must call Invalidate after batching chars — see FlushDisplay }
end;

function TK16Terminal.P(idx, def: Integer): Integer;
begin
  if (idx < FParamCount) and (FParams[idx] <> 0) then
    Result := FParams[idx]
  else
    Result := def;
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
    'G': FCurX := Max(0, Min(FCols-1, P(0,1) - 1));
    'H','f':
      begin
        FCurY := Max(0, Min(FRows-1, P(0,1) - 1));
        FCurX := Max(0, Min(FCols-1, P(1,1) - 1));
      end;
    'J':
      begin
        case P(0,0) of
          0: begin BlankRange(FCurY, FCurX, FCols-1);
                   for r := FCurY+1 to FRows-1 do BlankRow(BufRow(r)); end;
          1: begin BlankRange(FCurY, 0, FCurX);
                   for r := 0 to FCurY-1 do BlankRow(BufRow(r)); end;
          2: begin for r := 0 to FRows-1 do BlankRow(BufRow(r));
                   FCurX := 0; FCurY := 0; end;
        end;
      end;
    'K':
      begin
        case P(0,0) of
          0: BlankRange(FCurY, FCurX, FCols-1);
          1: BlankRange(FCurY, 0, FCurX);
          2: BlankRange(FCurY, 0, FCols-1);
        end;
      end;
    'L': begin n := P(0,1); for r := 1 to n do ScrollDown(FCurY, FScrollBot); end;
    'M': begin n := P(0,1); for r := 1 to n do ScrollUp(FCurY, FScrollBot); end;
    'P':
      begin
        n := P(0,1);
        for c := FCurX to FCols-1-n do
          FBuffer[BufRow(FCurY)][c] := FBuffer[BufRow(FCurY)][c+n];
        BlankRange(FCurY, FCols-n, FCols-1);
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
  SetDirty;
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
    FCurAttr.Bold := False; FCurAttr.Reverse := False;
    Exit;
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
      30..37:   FCurAttr.FG     := v - 30;
      39:       FCurAttr.FG     := DEF_FG;
      40..47:   FCurAttr.BG     := v - 40;
      49:       FCurAttr.BG     := DEF_BG;
      90..97:   FCurAttr.FG     := (v - 90) + 8;
      100..107: FCurAttr.BG     := v - 100;
    end;
  end;
end;

procedure TK16Terminal.FlushDisplay;
begin
  FScrollPos := 0;   { always snap to live view after output }
  UpdateSB;
  SetDirty;
  Invalidate;
end;

procedure TK16Terminal.ResetTerminal;
var r: Integer;
begin
  FCurX      := 0; FCurY      := 0;
  FSavedX    := 0; FSavedY    := 0;
  FScrollTop := 0; FScrollBot := Max(0, FRows-1);
  FCurVis    := True;
  FScrollPos := 0;
  FState     := psNormal;
  FCurAttr.FG := DEF_FG; FCurAttr.BG := DEF_BG;
  FCurAttr.Bold := False; FCurAttr.Reverse := False;
  for r := 0 to FBufLines-1 do BlankRow(r);
  FBufTop := SCROLLBACK_LINES;
  UpdateSB;
  SetDirty;
  Invalidate;
end;

procedure TK16Terminal.TermMouseDown(Sender: TObject; Button: TMouseButton;
                                   {%H-}Shift: TShiftState; {%H-}X, Y: Integer);
begin
  SetFocus;
end;

procedure TK16Terminal.DoKeyPress({%H-}Sender: TObject; var Key: Char);
begin
  if Ord(Key) >= 32 then
  begin
    if Assigned(FOnKey) then FOnKey(Ord(Key));
    Key := #0;
  end;
end;

procedure TK16Terminal.DoKeyDown({%H-}Sender: TObject; var Key: Word;
                                  Shift: TShiftState);
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
    Ord('V')  : if ssCtrl in Shift then
                begin
                  if Assigned(FOnPaste) then FOnPaste(Clipboard.AsText);
                  Key := 0;
                end;
  end;
end;

end.
