; ============================================================================
; SCROLL1.asm  --  minimal visual test of gfx_scroll  (.COM)
; ----------------------------------------------------------------------------
; Fills an 80x25 window with distinctly-labelled lines, then on each keypress
; scrolls the window UP one line via gfx_scroll and draws one fresh line into
; the exposed bottom band. Step-by-step so each scroll can be watched.
;
; Diagnostic intent: every line carries a 2-char tag and a ruler, so a clean
; scroll shows tags marching up in order with an intact ruler; any tear shows
; exactly where. The window spans y=120..420, crossing the framebuffer 64KB
; page boundary (mode-1 pitch 160 -> row 409.6), so the bottom rows exercise
; the LEA page-carry in gfx_scroll's row advance.
;
;   key Q : quit       any other key : scroll up one line + feed next line
;
; Requires gfx_scroll.asm (module include below), gfx_scroll_defs.inc,
; and GSO_PITCH/GSO_BPP in gfx_defs.inc. Adjust .INCLUDE paths to the tree.
; ============================================================================
                .INCLUDE "../../kos_defs.inc"
                .INCLUDE "../../klib/kos_klib.inc"
                .INCLUDE "../gfx_defs.inc"
                .INCLUDE "../gfx_scroll_defs.inc"
                .INCLUDE "../gfx_regions_defs.inc"
                .INCLUDE "../gfx_font_defs.inc"

C_BLACK         .EQU    0
C_WHITE         .EQU    1

WIN_X           .EQU    80
WIN_Y           .EQU    120
WIN_W           .EQU    480
WIN_H           .EQU    300
LINE_H          .EQU    12
WIN_BOT_LINE    .EQU    WIN_Y + WIN_H - LINE_H

SCROLL_LINES    .EQU    60             ; auto-scroll this many lines, then stop
DELAY_MS        .EQU    80             ; ~66 ms/line at 30 Hz tick resolution

; ---- harness scratch (task page, below $0200 code; clear of gfx $0100-$015F)
sc_logpg        .EQU    $0164          ; feed cursor into the line table
sc_logof        .EQU    $0166
sc_count        .EQU    $0168          ; lines remaining to scroll

                .ORG    $0200
start:
                LEA     XY0, banner
                TRAP    #TRAP_PUTLN

                LOADI   D0, #1
                CALLR   gfx_open
                BCS     .busy
                MOVE    Y1, Y3
                LOADI   X1, #GS_BASE            ; XY1 = descriptor (held)

                LOADI   D0, #C_BLACK
                CALLR   gfx_clear

                LEA     XY0, spleen_6x12_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_spleen_6x12
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALLR   gfx_setfont

                CALLR   draw_chrome
                CALLR   fill_window             ; draw 25 lines, set feed cursor

                LOADI   D0, #SCROLL_LINES
                STOREP  D0, Y3, [#sc_count]
.loop:
                ; --- scroll window up one line ---
                LOADI   D0, #WIN_X
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #WIN_Y
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #WIN_W
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #WIN_H
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #LINE_H
                NEG     D0                      ; dv = -LINE_H (up)
                CALLR   gfx_scroll
                CALLR   feed_line

                LOADI   D0, #DELAY_MS
                CALL24  KLIB_DELAY_MS           ; pace the scroll (C ignored)

                LOADP   D0, Y3, [#sc_count]
                SUB     D0, #1
                STOREP  D0, Y3, [#sc_count]
                CMP     D0, #0
                BNE.L   .loop

                TRAP    #TRAP_EXIT
.busy:
                LEA     XY0, msg_busy
                TRAP    #TRAP_PUTLN
                TRAP    #TRAP_EXIT

; ============================================================================
; feed_line -- clear the exposed bottom band and draw the next table line,
;   advancing the feed cursor (wraps at log_end). Preserves XY1.
; ============================================================================
feed_line:
                LOADI   D0, #WIN_X
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #WIN_BOT_LINE
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #WIN_W
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #LINE_H
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_WHITE
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_fillrect

                LOADP   D0, Y3, [#sc_logof]
                MOVE    X0, D0
                LOADP   D0, Y3, [#sc_logpg]
                MOVE    Y0, D0                  ; XY0 = feed cursor
                LOADI   D0, #WIN_X
                LOADI   D1, #WIN_BOT_LINE
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string

                LOADP   D0, Y3, [#sc_logof]
                MOVE    X2, D0
                LOADP   D0, Y3, [#sc_logpg]
                MOVE    Y2, D0
                CALLR   strskip                 ; advance cursor (wraps)
                MOVE    D0, X2
                STOREP  D0, Y3, [#sc_logof]
                MOVE    D0, Y2
                STOREP  D0, Y3, [#sc_logpg]
                RET

; ============================================================================
; draw_chrome -- white panel, black frame, title, key prompt (drawn once).
; ============================================================================
draw_chrome:
                LOADI   D0, #(WIN_X - 2)
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #(WIN_Y - 20)
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #(WIN_W + 4)
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #(WIN_H + 22)
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_WHITE
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_fillrect
                LOADI   D0, #(WIN_X - 2)
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #(WIN_Y - 20)
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #(WIN_W + 4)
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #(WIN_H + 22)
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_BLACK
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_rect
                LEA     XY0, win_title
                LOADI   D0, #WIN_X
                LOADI   D1, #(WIN_Y - 16)
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string
                LEA     XY0, prompt
                LOADI   D0, #WIN_X
                LOADI   D1, #(WIN_Y + WIN_H + 6)
                LOADI   D3, #C_WHITE
                CALLR   gfx_draw_string
                RET

; ============================================================================
; fill_window -- draw the first 25 table lines into the window; leave the
;   feed cursor (sc_logpg/of) at the next line for the live feed.
; ============================================================================
fill_window:
                LEA     XY0, log0
                MOVE    Y2, Y0
                MOVE    X2, X0
                LOADI   D2, #25
                LOADI   D1, #WIN_Y
.fw_row:
                MOVE    Y0, Y2
                MOVE    X0, X2
                LOADI   D0, #WIN_X
                LOADI   D3, #C_BLACK
                PUSH    XY2, XY3
                PUSH    D1, XY3
                PUSH    D2, XY3
                CALLR   gfx_draw_string
                POP     D2, XY3
                POP     D1, XY3
                POP     XY2, XY3
                CALLR   strskip
                ADD     D1, #LINE_H
                SUB     D2, #1
                BNE.L   .fw_row
                MOVE    D0, X2
                STOREP  D0, Y3, [#sc_logof]
                MOVE    D0, Y2
                STOREP  D0, Y3, [#sc_logpg]
                RET

; strskip -- advance XY2 past the next nul; rewind to log0 at log_end.
;   Clobbers D0, XY0. Preserves D1, D2, XY1, XY3 and (no-wrap) Y2.
strskip:
                LOADB   D0, [XY2]+
                CMP     D0, #0
                BNE.L   strskip
                MOVE    D0, X2
                AND     D0, #1
                BEQ.S   .ss_chk
                ADD     X2, #1
.ss_chk:
                LEA     XY0, log_end
                MOVE    D0, X0
                CMP     X2, D0
                BLO     .ss_done
                LEA     XY0, log0
                MOVE    Y2, Y0
                MOVE    X2, X0
.ss_done:
                RET

; ----------------------------------------------------------------------------
banner          .TEXT   "SCROLL1: gfx_scroll auto-scroll demo", 0
msg_busy        .TEXT   "gfx: graphics busy", 0
win_title       .TEXT   "k/OS scroll test  -  80x25  -  gfx_scroll", 0
prompt          .TEXT   "auto-scrolling, then exits", 0

; ---- labelled lines: 2-char tag + ruler so motion/tears are obvious --------
log0            .TEXT   "00  ....+....1....+....2....+....3....+....4....+", 0
                .TEXT   "01  the quick brown fox jumps over the lazy dog", 0
                .TEXT   "02  THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG", 0
                .TEXT   "03  0123456789 0123456789 0123456789 0123456789", 0
                .TEXT   "04  |||||||||||||||||||||||||||||||||||||||||||", 0
                .TEXT   "05  gfx_scroll: vertical byte block-move (1bpp)", 0
                .TEXT   "06  abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOP", 0
                .TEXT   "07  ....+....1....+....2....+....3....+....4....+", 0
                .TEXT   "08  row tags should march up cleanly, in order", 0
                .TEXT   "09  watch the bottom rows: they cross a FB page", 0
                .TEXT   "10  boundary (y~410), exercising the LEA carry", 0
                .TEXT   "11  iiii MMMM WWWW .... mixed widths for tears", 0
                .TEXT   "12  the quick brown fox jumps over the lazy dog", 0
                .TEXT   "13  THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG", 0
                .TEXT   "14  0123456789 0123456789 0123456789 0123456789", 0
                .TEXT   "15  ....+....1....+....2....+....3....+....4....+", 0
                .TEXT   "16  scroll up by 12 px per key (one text line)", 0
                .TEXT   "17  no tearing = page carry + overlap both good", 0
                .TEXT   "18  abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOP", 0
                .TEXT   "19  |||||||||||||||||||||||||||||||||||||||||||", 0
                .TEXT   "20  the quick brown fox jumps over the lazy dog", 0
                .TEXT   "21  0123456789 0123456789 0123456789 0123456789", 0
                .TEXT   "22  ....+....1....+....2....+....3....+....4....+", 0
                .TEXT   "23  end of the first screen of lines is near now", 0
                .TEXT   "24  ---- line 24 (bottom of initial fill) ------", 0
                .TEXT   "25  ==== fed line 25 (first scrolled-in line) ==", 0
                .TEXT   "26  ==== fed line 26 ==========================", 0
                .TEXT   "27  ==== fed line 27 ==========================", 0
                .TEXT   "28  ==== fed line 28 ==========================", 0
                .TEXT   "29  ==== fed line 29 (table wraps after this) ==", 0
log_end         .TEXT   "", 0

                .ALIGN
                .INCLUDE "../font/gfx_font_spleen_6x12.inc"

                .ALIGN
                .INCLUDE "../gfx.asm"
                .INCLUDE "../gfx_scroll.asm"
                .INCLUDE "../gfx_1bpp.asm"
                .INCLUDE "../gfx_8bpp.asm"
                .INCLUDE "../gfx_regions.asm"
                .INCLUDE "../gfx_font.asm"
