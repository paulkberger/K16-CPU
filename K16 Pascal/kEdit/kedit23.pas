program KEdit19;
{ ==============================================================================
  KEdit -- minimal full-screen text editor for k/OS, in K16 Pascal.
  ------------------------------------------------------------------------------
  Architecture after antirez's Kilo: a row array + cursor + scroll offsets,
  a render pass via sys_setcursor/sys_clear, and a keypress dispatch loop.

  THIS SKELETON: load a file, display it, move the cursor (arrows), quit (Ctrl-Q).
  NEXT INCREMENTS: insert/delete char + newline, save (Ctrl-S), status/message
  line detail, horizontal scroll polish, filename argument, >BUFSIZE files.

  Build: k16pascal --kos kedit.pas
  Needs files.pas, console.pas and k16_rtl_kos.asm on the include path.

  NB (verify on first run): arrow keys are decoded as VT100 ESC '[' 'A'..'D'.
  If the EMU delivers arrows differently, ReadKey is the single place to change.
  ============================================================================== }
{$I C:\K16 CPU\K16 Pascal\rtl\files.pas}
{$I C:\K16 CPU\K16 Pascal\rtl\console.pas}

const
  KEDIT_VER  = 'v2.3';  // bump on every change so the status bar confirms the build
  ATTR_TEXT   = 15;        // white on black  -- editor text
  ATTR_TILDE  = 7;         // grey on black   -- ~ past-EOF markers
  ATTR_STATUS = 31;        // white on blue   -- status bar = Attr(15,1)
  MAXROWS    = 240;  // max lines held (sized rows fit the task page)
  MAXROW     = 239;  // = MAXROWS-1 (array-bound needs a bare constant)
  LINEW      = 120;  // max chars per line (rows are String[120])
  CHUNK      = 512;  // load/save I/O chunk size
  CHUNKMAX   = 511;  // = CHUNK-1
  DEF_ROWS   = 24;  // fallback terminal height if DSR query gets no answer
  DEF_COLS   = 80;

  KEY_QUIT   = 24;  // Ctrl-X (nano-style exit); WebEMU now forwards Ctrl keys
  KEY_SAVE   = 15;  // Ctrl-O save (write out)
  KEY_ENTER  = 13;  // split line
  KEY_BS     = 8;  // backspace
  KEY_ESC    = 27;
  KEY_UP     = 1000;
  KEY_DOWN   = 1001;
  KEY_LEFT   = 1002;
  KEY_RIGHT  = 1003;

  RL_STATUS  = 0;   // cursor + status line only
  RL_LINE    = 1;   // current text row + status
  RL_FULL    = 2;   // whole text area + status

  TABW       = 8;   // tab-stop width (tabs are expanded to spaces on load)

var
  Rows    : array[0..MAXROW] of String[120];   // ~29 KB total (String[120] = 122 B each)
  NumRows : Integer;
  Cx, Cy  : Integer;  // cursor column / row, as offsets into the file
  RowOff  : Integer;  // first visible file row
  ColOff  : Integer;  // first visible column
  TheName : String[80];
  Quitting: Boolean;
  Dirty   : Boolean;  // buffer modified since load/save
  Buf     : array[0..CHUNKMAX] of Char;   // small streaming I/O buffer
  Key     : Integer;
  Level, PrevCy : Integer;   // dirty-region redraw dispatch
  SCREENROWS : Integer;  // visible text rows  (set by QueryTermSize)
  SCREENCOLS : Integer;  // visible columns
  STATUSROW  : Integer;  // status line row = terminal height
  DbgDSR     : Integer;  // vestigial: DSR retired in v1.3 (kept for the status readout)
  ArgName    : String;   // command-line filename from GetArgs (Part 15)
  // Appended at the tail of the var block: the compiler does not word-align
  // individual globals, so byte-sized flags must not precede word-typed
  // globals or they shift them onto odd addresses (odd-addr word fault).
  Msg       : String;    // transient status-line message (cleared each keystroke)
  Truncated : Boolean;   // file lost lines on load (> MAXROWS) -> saving disabled
  QuitArmed : Boolean;   // Ctrl-X pressed once on a modified buffer; second confirms
  WasArmed  : Boolean;   // quit-armed state carried into this keystroke

// ---- load: stream the file in CHUNK-byte reads, split on newlines into Rows ----
procedure LoadFile(Name: String);
var
  fd, n, i, nsp: Integer;
  line: String[120];
  c: Char;
begin
  NumRows := 0;
  Truncated := False;
  line := '';
  fd := FileOpen(Name, FOPEN_READ);
  if fd >= 0 then
  begin
    n := FileRead(fd, @Buf[0], CHUNK);
    while n > 0 do
    begin
      i := 0;
      while i < n do
      begin
        c := Buf[i];
        if c = Chr(10) then  // LF ends a line
        begin
          if NumRows < MAXROWS then
          begin
            Rows[NumRows] := line;
            NumRows := NumRows + 1;
          end
          else
            Truncated := True;   // lines past MAXROWS dropped -> block saving
          line := '';
        end
        else if c = Chr(9) then  // expand tab to the next TABW stop
        begin
          if Length(line) < LINEW then
          begin
            nsp := TABW - (Length(line) and (TABW - 1));
            while (nsp > 0) and (Length(line) < LINEW) do
            begin
              line := line + ' ';
              nsp := nsp - 1;
            end;
          end;
        end
        else if c <> Chr(13) then  // ignore CR
        begin
          if Length(line) < LINEW then line := line + c;
        end;
        i := i + 1;
      end;
      n := FileRead(fd, @Buf[0], CHUNK);   // next chunk
    end;
    FileClose(fd);
    // trailing line with no final newline
    if Length(line) > 0 then
    begin
      if NumRows < MAXROWS then
      begin
        Rows[NumRows] := line;
        NumRows := NumRows + 1;
      end
      else
        Truncated := True;
    end;
  end;
end;

// ---- render the text area (each row padded to erase old content) ----
procedure DrawRow(y: Integer);            // y = 0-based screen row in the text area
var
  filerow: Integer;
  s, vis: String;
begin
  filerow := RowOff + y;
  GotoXY(y + 1, 1);
  if filerow < NumRows then
  begin
    TextAttr(ATTR_TEXT);                      // white
    s := Rows[filerow];
    vis := Copy(s, ColOff + 1, SCREENCOLS);   // visible horizontal slice (Pascal temp)
    Write(vis);                               // one length-prefixed emit (TRAP_PUTLP)
  end
  else
  begin
    TextAttr(ATTR_TILDE);                     // grey
    Write('~');                               // past end of file
  end;
  ClrEol;                                     // BCE-fill to EOL, replaces per-char space pad
end;

procedure DrawRows;
var
  y: Integer;
begin
  y := 0;
  while y < SCREENROWS do
  begin
    DrawRow(y);
    y := y + 1;
  end;
end;

// ---- status line ----
procedure DrawStatus;
var
  s, tmp: String;
begin
  s := ' KEdit ' + KEDIT_VER;
  s := s + '  ';
  if Length(TheName) > 0 then s := s + TheName else s := s + '[No Name]';
  if Dirty then s := s + ' *';
  if Truncated then s := s + ' [TRUNC]';
  s := s + '  Ln ';
  Str(Cy + 1, tmp);  s := s + tmp;
  s := s + ' Col ';
  Str(Cx + 1, tmp);  s := s + tmp;
  if Length(Msg) > 0 then s := s + '  ' + Msg
  else s := s + '  ^O ^X';
  GotoXY(STATUSROW, 1);
  TextAttr(ATTR_STATUS);
  Write(Copy(s, 1, SCREENCOLS - 1));               // status text in one emit, never last column
  ClrEol;                                          // BCE-fill rest of bar (incl. last cell)
  TextAttr(ATTR_TEXT);
end;

// ---- keep the cursor on-screen ----
function Scroll: Boolean;
var
  oldRow, oldCol: Integer;
begin
  oldRow := RowOff;  oldCol := ColOff;
  if Cy < RowOff then RowOff := Cy;
  if Cy >= RowOff + SCREENROWS then RowOff := Cy - SCREENROWS + 1;
  if Cx < ColOff then ColOff := Cx;
  if Cx >= ColOff + SCREENCOLS then ColOff := Cx - SCREENCOLS + 1;
  Scroll := (RowOff <> oldRow) or (ColOff <> oldCol);
end;

// ---- full repaint, then park the hardware cursor ----
procedure PlaceCursor;
begin
  GotoXY(Cy - RowOff + 1, Cx - ColOff + 1);
end;

procedure Refresh;            // full: whole text area + status
begin
  HideCursor; DrawRows; DrawStatus; PlaceCursor; ShowCursor;
end;

procedure RefreshLine;        // current text row + status
begin
  HideCursor; DrawRow(Cy - RowOff); DrawStatus; PlaceCursor; ShowCursor;
end;

procedure RefreshStatus;      // status line + cursor only
begin
  HideCursor; DrawStatus; PlaceCursor; ShowCursor;
end;

// ---- one keystroke, decoding VT100/SS3 arrow escapes ----
function ReadKey: Integer;
var
  k, k2, k3: Integer;
begin
  k := GetKey;
  if k = KEY_ESC then
  begin
    k2 := GetKey;
    if (k2 = Ord('[')) or (k2 = Ord('O')) then   // CSI or SS3
    begin
      k3 := GetKey;
      case k3 of
        65: ReadKey := KEY_UP;  // ESC [ A
        66: ReadKey := KEY_DOWN;  // ESC [ B
        67: ReadKey := KEY_RIGHT;  // ESC [ C
        68: ReadKey := KEY_LEFT;  // ESC [ D
      else
      begin
        // Drain the rest of a CSI parameter sequence (ESC[3~, ESC[5~, ESC[6~,
        // ...) so its terminating '~' is not left to be read as a stray key.
        while (k3 >= 48) and (k3 <= 57) do k3 := GetKey;
        ReadKey := KEY_ESC;
      end;
      end;
    end
    else
      ReadKey := KEY_ESC;
  end
  else
    ReadKey := k;
end;

// ---- move the cursor, clamped to buffer + current line ----
procedure MoveCursor(k: Integer);
var
  rowlen: Integer;
begin
  case k of
    KEY_UP:
      if Cy > 0 then Cy := Cy - 1;
    KEY_DOWN:
      if Cy < NumRows - 1 then Cy := Cy + 1;
    KEY_LEFT:
      if Cx > 0 then Cx := Cx - 1;
    KEY_RIGHT:
      if Cy < NumRows then
      begin
        rowlen := Length(Rows[Cy]);
        if Cx < rowlen then Cx := Cx + 1;
      end;
  end;
  // snap Cx back onto the (possibly shorter) new line
  if Cy < NumRows then
  begin
    rowlen := Length(Rows[Cy]);
    if Cx > rowlen then Cx := rowlen;
  end
  else
    Cx := 0;
end;

// ---- row-array helpers ----
procedure InsertRow(At: Integer; S: String);
var
  i: Integer;
begin
  if NumRows < MAXROWS then
  begin
    i := NumRows;
    while i > At do
    begin
      Rows[i] := Rows[i - 1];
      i := i - 1;
    end;
    Rows[At] := S;
    NumRows := NumRows + 1;
  end;
end;

procedure DeleteRow(At: Integer);
var
  i: Integer;
begin
  if (At >= 0) and (At < NumRows) then
  begin
    i := At;
    while i < NumRows - 1 do
    begin
      Rows[i] := Rows[i + 1];
      i := i + 1;
    end;
    NumRows := NumRows - 1;
  end;
end;

// ---- editing ops ----
procedure InsertChar(ch: Char);
var
  s: String;
  len: Integer;
begin
  s := Rows[Cy];
  len := Length(s);
  if len < LINEW then
  begin
    Rows[Cy] := Copy(s, 1, Cx) + ch + Copy(s, Cx + 1, len - Cx);
    Cx := Cx + 1;
    Dirty := True;
  end;
end;

procedure DoBackspace;
var
  s, prev: String;
  len, plen: Integer;
begin
  if Cx > 0 then
  begin
    s := Rows[Cy];
    len := Length(s);
    Rows[Cy] := Copy(s, 1, Cx - 1) + Copy(s, Cx + 1, len - Cx);
    Cx := Cx - 1;
    Dirty := True;
  end
  else if Cy > 0 then
  begin
    prev := Rows[Cy - 1];
    plen := Length(prev);
    if plen + Length(Rows[Cy]) <= LINEW then
    begin
      Rows[Cy - 1] := prev + Rows[Cy];
      DeleteRow(Cy);
      Cy := Cy - 1;
      Cx := plen;
      Dirty := True;
    end;
  end;
end;

procedure DoEnter;
var
  s, tail: String;
  len: Integer;
begin
  s := Rows[Cy];
  len := Length(s);
  tail := Copy(s, Cx + 1, len - Cx);  // text after the cursor
  Rows[Cy] := Copy(s, 1, Cx);  // text before the cursor
  InsertRow(Cy + 1, tail);
  Cy := Cy + 1;
  Cx := 0;
  Dirty := True;
end;

// ---- save: stream rows (newline-separated) out in CHUNK-byte writes ----
procedure SaveFile;
var
  fd, r, i, len, pos, w: Integer;
  s: String[120];
  err: Boolean;
begin
  if Truncated then
    Msg := 'File was truncated on load -- save disabled'
  else
  begin
    fd := FileOpen(TheName, FOPEN_WRITE or FOPEN_CREATE or FOPEN_TRUNC);
    if fd < 0 then
      Msg := 'Save failed: cannot open ' + TheName
    else
    begin
      pos := 0;
      err := False;
      r := 0;
      while r < NumRows do
      begin
        s := Rows[r];
        len := Length(s);
        i := 1;
        while i <= len do
        begin
          Buf[pos] := s[i];
          pos := pos + 1;
          if pos = CHUNK then  // buffer full -> flush
          begin
            w := FileWrite(fd, @Buf[0], CHUNK);
            if w <> CHUNK then err := True;
            pos := 0;
          end;
          i := i + 1;
        end;
        Buf[pos] := Chr(10);  // LF after each row
        pos := pos + 1;
        if pos = CHUNK then
        begin
          w := FileWrite(fd, @Buf[0], CHUNK);
          if w <> CHUNK then err := True;
          pos := 0;
        end;
        r := r + 1;
      end;
      if pos > 0 then  // flush the final partial buffer
      begin
        w := FileWrite(fd, @Buf[0], pos);
        if w <> pos then err := True;
      end;
      FileClose(fd);
      if err then
        Msg := 'Save failed: write error'
      else
      begin
        Dirty := False;  // clear dirty only on a clean write
        Msg := 'Saved';
      end;
    end;
  end;
end;

// ---- query terminal size via DSR (VT100 cursor-position report) ----
// Park the cursor bottom-right (the terminal clamps it to its real size), ask
// for its position with ESC[6n, and parse the ESC[<rows>;<cols>R reply.
// Requires the DSR-capable WebEMU; falls back to DEF_ROWS/DEF_COLS otherwise.
procedure QueryTermSize;
var
  r, c: Integer;
begin
  // Part 15: live geometry from the kernel (sys_termsize / TRAP #19) instead of
  // the VT100 DSR round-trip. Works foreground OR background; EMU returns the
  // real window size, Digital a fixed 80x24. The DSR dance is retired.
  c := TermCols;
  r := TermRows;
  SCREENCOLS := c;
  STATUSROW  := r;              // status line = terminal height
  SCREENROWS := r - 1;          // reserve the bottom status row
  DbgDSR := 0;                  // DSR retired; kept only for the status readout
end;

// ---- read a filename from the user (simple line editor with Backspace) ----
function ReadFileName: String;
var
  s: String;
  k: Integer;
  done: Boolean;
begin
  s := '';
  done := False;
  while not done do
  begin
    k := GetKey;
    if k = KEY_ENTER then
      done := True
    else if k = KEY_BS then
    begin
      if Length(s) > 0 then
      begin
        s := Copy(s, 1, Length(s) - 1);
        Write(Chr(8)); Write(' '); Write(Chr(8));   // erase last char on screen
      end;
    end
    else if (k >= 32) and (k <= 126) then
    begin
      s := s + Chr(k);
      Write(Chr(k));                                 // echo
    end;
  end;
  ReadFileName := s;
end;

// ---- Save As: prompt for a name on the status row, then save under it ----
procedure SaveAs;
var
  nm: String;
begin
  GotoXY(STATUSROW, 1);
  Write('Save as: ');
  nm := ReadFileName;              // echoes on the status row; blocks for a key
  if Length(nm) > 0 then
  begin
    TheName := nm;
    SaveFile;
  end;
  // the next main-loop Refresh repaints over the prompt line.
end;

// ---- main ----
begin
  InitFiles;
  RegisterShell;                   // become a switchable shell (starts backgrounded)

  // Part 16: a command-line filename ('run kedit B:FOO.TXT') opens that file;
  // no args => a blank, unnamed document. GetArgs reads this task's argv tail
  // (empty when none). No startup prompt either way -- the edit loop's first
  // ReadKey is what blocks until we are switched to (Ctrl-N).
  GetArgs(ArgName);
  TheName := ArgName;              // empty => unnamed blank document

  // sys_termsize works foreground or background, so sizing needs no prompt.
  // On the args path we are still backgrounded here; the edit loop's first
  // ReadKey blocks until foreground, and the switch repaints from the
  // back-buffer -- so the render below is correct either way.
  QueryTermSize;

  if Length(TheName) > 0 then LoadFile(TheName);   // unnamed => stay blank
  if NumRows = 0 then  // new / empty / unnamed = one empty line to edit
  begin
    Rows[0] := '';
    NumRows := 1;
  end;

  Cx := 0;
  Cy := 0;
  RowOff := 0;
  ColOff := 0;
  Quitting := False;
  Dirty := False;

  ClrScr;
  QuitArmed := False;
  Msg := '';
  Refresh;                              // initial full paint (cursor at origin)
  while not Quitting do
  begin
    Key := ReadKey;
    Msg := '';                          // clear the previous action's transient message
    WasArmed := QuitArmed;
    QuitArmed := False;                 // any keystroke disarms the quit confirmation
    Level := RL_STATUS;                 // default: cursor-only
    case Key of
      KEY_QUIT:
        if (not Dirty) or WasArmed then
          Quitting := True
        else
        begin
          QuitArmed := True;                    // first Ctrl-X on a modified buffer
          Msg := 'Modified -- Ctrl-X again to discard';
        end;
      KEY_SAVE:
        if Length(TheName) = 0 then
        begin SaveAs; Level := RL_FULL; end     // prompt overwrote the screen
        else
          SaveFile;                             // sets Msg (Saved / failed / trunc)
      KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT:
        MoveCursor(Key);                        // RL_STATUS
      KEY_ENTER:
      begin
        DoEnter; Level := RL_FULL;              // rows renumber below the split
      end;
      KEY_BS:
      begin
        PrevCy := Cy;
        DoBackspace;
        if Cy <> PrevCy then Level := RL_FULL   // line-join renumbered rows
        else Level := RL_LINE;                  // same-line delete
      end;
      32..126:
      begin
        InsertChar(Chr(Key)); Level := RL_LINE;
      end;
    end;

    if not Quitting then
    begin
      if Scroll then Level := RL_FULL;          // viewport moved -> full
      case Level of
        RL_FULL:   Refresh;
        RL_LINE:   RefreshLine;
        RL_STATUS: RefreshStatus;
      end;
    end;
  end;

  ClrScr;
  GotoXY(1, 1);
  WriteLn('KEdit: bye');
end.
