; ============================================================================
; FNTSHOW2.asm  --  KGFX smoke for the converted IIGS faces, mode 1 1bpp.
; ----------------------------------------------------------------------------
; First on-screen test of glyph data produced by iigs_fon_to_k16.py:
;   A. Courier 12     -- narrow (7x12, byte/row) + PROPORTIONAL metrics.
;   B. Helvetica 12   -- wide   (11x13, word/row) + PROPORTIONAL metrics.
;
; Helvetica 12 is the gate: it is the first WIDE + PROP strike to run. The
; narrow wide path was proven by FNTSHOW1 (spleen, mono); proportional was
; proven narrow (pcface). This is the first time BOTH ride together, so the
; per-char advance (WTAB) and signed bearing (OTAB) drive the >8px word path.
;
; Pass criteria (eyeball):
;   * Courier line reads cleanly, fixed pitch, no broken cells (narrow anchor).
;   * Helvetica reads as natural proportional text - tight i/l/., wide W/M/m.
;   * "iiiii" is visibly MUCH narrower than "WWWWW" (mono fallback would make
;     them equal width -> FAIL).
;   * Ink-heavy right-column chars (W M @ # & %) are clean, no garbage in the
;     last 1-3 columns (a broken byte2 spill in vtext_1 shows here).
;   * The s=0 and s=3 Helvetica lines are identical in shape (start-offset ok).
; Build: assemble as a .COM; gfx + regions + font include tail.
; ============================================================================
                .INCLUDE "../../kos_defs.inc"
                .INCLUDE "../gfx_defs.inc"
                .INCLUDE "../gfx_regions_defs.inc"
                .INCLUDE "../font/gfx_font_defs.inc"

C_BLACK         .EQU    0               ; ink
C_WHITE         .EQU    1               ; paper

                .ORG    $0200
start:
                LEA     XY0, banner
                TRAP    #TRAP_PUTLN

                LOADI   D0, #1                  ; mode 1 (1280x720 1bpp)
                CALLR   gfx_open
                BCS     .busy
                MOVE    Y1, Y3
                LOADI   X1, #GS_BASE            ; XY1 = descriptor (held throughout)

                ; --- white paper ---
                LOADI   D0, #C_WHITE
                CALLR   gfx_clear

                ; ====================================================
                ; A. Courier 12  -- narrow (byte/row) + proportional
                ; ====================================================
                LEA     XY0, courier_12_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_courier_12
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALLR   gfx_setfont

                LEA     XY0, c_title
                LOADI   D0, #40
                LOADI   D1, #24
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string

                LEA     XY0, c_sample
                LOADI   D0, #40
                LOADI   D1, #44
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string

                ; ====================================================
                ; B. Helvetica 12  -- wide (word/row) + proportional
                ;    set once, draw several lines
                ; ====================================================
                LEA     XY0, helvetica_12_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_helvetica_12
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALLR   gfx_setfont

                LEA     XY0, h_title
                LOADI   D0, #40
                LOADI   D1, #90
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string

                ; proportional showcase: i-run vs W-run must differ in width
                LEA     XY0, h_prop
                LOADI   D0, #40
                LOADI   D1, #115
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string

                ; pangram - natural text should read evenly (s=0 origin)
                LEA     XY0, h_pan
                LOADI   D0, #40
                LOADI   D1, #140
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string

                ; ink-heavy / right-column chars - byte2 spill check
                LEA     XY0, h_ink
                LOADI   D0, #40
                LOADI   D1, #165
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string

                ; same pangram at x=43 (s=3) - start-offset sweep
                LEA     XY0, h_pan3
                LOADI   D0, #43
                LOADI   D1, #190
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string

                LEA     XY0, h_note
                LOADI   D0, #40
                LOADI   D1, #220
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string

.hold:
                LEA     XY0, prompt
                TRAP    #TRAP_PUTLN
                TRAP    #TRAP_GETCHAR
                TRAP    #TRAP_EXIT
.busy:
                LEA     XY0, msg_busy
                TRAP    #TRAP_PUTLN
                TRAP    #TRAP_EXIT

; ----------------------------------------------------------------------------
banner          .TEXT   "KGFX FNTSHOW2: IIGS faces - Courier narrow, Helvetica wide+prop", 0
prompt          .TEXT   "drawn - press a key to exit", 0
msg_busy        .TEXT   "gfx: graphics busy", 0

c_title         .TEXT   "Courier 12 (narrow 7x12, proportional):", 0
c_sample        .TEXT   "The quick brown fox  WMgjpq @#&!? 0123456789 ABCxyz", 0

h_title         .TEXT   "Helvetica 12 (wide 11x13, proportional):", 0
h_prop          .TEXT   "prop check:  iiiii  vs  WWWWW    lIi1.,;:!    mmm MMM", 0
h_pan           .TEXT   "The quick brown fox jumps over the lazy dog. s=0", 0
h_ink           .TEXT   "ink/right-col: WM@#&%$  AVOWAL  Wjpqy  0123456789", 0
h_pan3          .TEXT   "The quick brown fox jumps over the lazy dog. s=3", 0
h_note          .TEXT   "iiiii << WWWWW + clean right cols + s0=s3 shape = wide+prop good", 0

                .ALIGN
                .INCLUDE "../font/gfx_font_courier_12.inc"
                .ALIGN
                .INCLUDE "../font/gfx_font_helvetica_12.inc"

                .ALIGN
                .INCLUDE "../gfx.asm"
                .INCLUDE "../gfx_1bpp.asm"
                .INCLUDE "../gfx_8bpp.asm"
                .INCLUDE "../gfx_regions.asm"
                .INCLUDE "../font/gfx_font.asm"
