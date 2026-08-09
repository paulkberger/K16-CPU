(* ==============================================================================
  console.pas -- k/OS screen + raw keyboard for K16 Pascal   (--kos target)
  ------------------------------------------------------------------------------
  Include with:  {$I console.pas}
  Backed by __gotoxy / __clrscr / __getkey in k16_rtl_kos.asm, which wrap
  sys_setcursor (TRAP 18), sys_clear (TRAP 17) and sys_getchar (TRAP 11).
  ============================================================================== *)

{ Position the cursor. Row and Col are 1-indexed (top-left = 1,1). }
procedure GotoXY(Row, Col: Integer);   external '__gotoxy';

{ Clear the whole screen. }
procedure ClrScr;                       external '__clrscr';

{ Read one raw keystroke (blocks until a key is available). Returns the byte.
  The caller decodes escape sequences -- arrow keys arrive as ESC '[' 'A'..'D'. }
function  GetKey: Integer;              external '__getkey';

{ Hide / show the terminal cursor (VT100 DECTCEM). Bracket a full-screen
  repaint with HideCursor .. ShowCursor to stop the cursor sweeping the
  screen during the redraw. }
procedure HideCursor; external '__hidecursor';
procedure ShowCursor; external '__showcursor';

{ Set the current text attribute. Attr is a VGA byte: foreground in the low
  nibble (0..15, bit 3 = bright), background 0..7 in bits 4..6. Stamped into
  cells written afterwards and shown immediately while this task is foreground.
  On Digital (dumb-TTY) the attribute is stored but not rendered. }
procedure TextAttr(Attr: Integer);      external '__setattr';

{ Set the foreground colour (0..15) on a black background -- shorthand for
  TextAttr(Fg). For a coloured background use TextAttr with the full byte. }
procedure TextColor(Fg: Integer);       external '__setattr';

{ Clear from the cursor to the end of the line / screen. Blanked cells take
  the current attribute (background colour extends). }
procedure ClrEol;                       external '__clreol';
procedure ClrEos;                       external '__clreos';

{ Cursor position, 1-based (top-left = 1,1) -- Turbo-style. }
function  WhereX: Integer;              external '__wherex';
function  WhereY: Integer;              external '__wherey';

{ Register as a switchable Phase B shell (Ctrl-N/P to switch between it and
  kosh). Call once at startup before any output. Harmless if it fails -- the
  task then runs as a plain foreground child. }
procedure RegisterShell; external '__register_shell';

{ Live terminal geometry via sys_termsize (TRAP #19): the real window size on
  EMU (tracks resizes), a fixed 80x24 on Digital. Replaces the VT100 DSR probe. }
function  TermCols: Integer;            external '__termcols';
function  TermRows: Integer;            external '__termrows';

{ Copy this task's command-line tail into S -- the text after the program name
  when launched as 'run <prog> <tail>' (or '<prog> <tail>'). Empty when no args
  were given; kosh has already trimmed leading/trailing spaces. }
procedure GetArgs(var S: String);       external '__getargs';
