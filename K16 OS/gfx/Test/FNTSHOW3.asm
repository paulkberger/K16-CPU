;  ============================================================================
; FNTSHOW3.asm  --  KGFX showcase: converted IIGS faces, mode 1 1bpp.
; ----------------------------------------------------------------------------
; Each converted face/size, grouped by family. Sample: pangram fragment +
; ink-heavy WMil 0123 @#&. Clean exit restores text mode (mode 0).
;
; Helvetica 9 and Times 9 are omitted: their IIGS source strikes use heavier
; strokes (2px / chunky serifs) for small-size legibility, so they read bold
; next to the lighter 10/12/14. Courier 9 (mono, consistent) is kept.
;
; ALIGNMENT: each line starts at x = 40 - first-char ink offset, so the visible
; left edge is flush across all families. Faces with a 1px left side bearing
; (Helvetica 12/14, Times 14, Palatino 14) start at x=39; the rest at x=40.
;
; MEMORY: the gfx engine keeps fixed task-page scratch at $6000-$6250
; (RGN/GP/GB/FNT BSS). With many strikes embedded the data would overrun that
; region and corrupt whichever font's wtab/otab land there (Times 14 was the
; casualty). So the font block is split: strikes below $6000, then .ORG $6260
; reserves the scratch, then the rest plus the engine above it. ADDRESSING:
; engine calls use CALL16; fonts use plain LEA except palatino (>32KB past the
; gap) which uses LEA mode 01 (base+disp). Build: assemble as a .COM.
; ============================================================================
                .INCLUDE "../../kos_defs.inc"
                .INCLUDE "../gfx_defs.inc"
                .INCLUDE "../gfx_regions_defs.inc"
                .INCLUDE "../gfx_font_defs.inc"

C_BLACK         .EQU    0
C_WHITE         .EQU    1

                .ORG    $0200
start:
                LEA     XY0, banner
                TRAP    #TRAP_PUTLN

                LOADI   D0, #1                  ; mode 1 (1280x720 1bpp)
                CALL16  gfx_open
                BCS     .busy
                MOVE    Y1, Y3
                LOADI   X1, #GS_BASE
                LOADI   D0, #C_WHITE
                CALL16  gfx_clear

                ; --- title in Helvetica 12 ---
                LEA     XY0, helvetica_12_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_helvetica_12
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALL16  gfx_setfont
                LEA     XY0, title
                LOADI   D0, #40
                LOADI   D1, #18
                LOADI   D3, #C_BLACK
                CALL16  gfx_draw_string

                ; ---- courier_9 ----
                LEA     XY0, courier_9_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_courier_9
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALL16  gfx_setfont
                LEA     XY0, s_courier_9
                LOADI   D0, #40
                LOADI   D1, #52
                LOADI   D3, #C_BLACK
                CALL16  gfx_draw_string

                ; ---- courier_10 ----
                LEA     XY0, courier_10_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_courier_10
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALL16  gfx_setfont
                LEA     XY0, s_courier_10
                LOADI   D0, #40
                LOADI   D1, #65
                LOADI   D3, #C_BLACK
                CALL16  gfx_draw_string

                ; ---- courier_12 ----
                LEA     XY0, courier_12_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_courier_12
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALL16  gfx_setfont
                LEA     XY0, s_courier_12
                LOADI   D0, #40
                LOADI   D1, #79
                LOADI   D3, #C_BLACK
                CALL16  gfx_draw_string

                ; ---- helvetica_10 ----
                LEA     XY0, helvetica_10_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_helvetica_10
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALL16  gfx_setfont
                LEA     XY0, s_helvetica_10
                LOADI   D0, #40
                LOADI   D1, #105
                LOADI   D3, #C_BLACK
                CALL16  gfx_draw_string

                ; ---- helvetica_12 ----
                LEA     XY0, helvetica_12_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_helvetica_12
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALL16  gfx_setfont
                LEA     XY0, s_helvetica_12
                LOADI   D0, #39
                LOADI   D1, #119
                LOADI   D3, #C_BLACK
                CALL16  gfx_draw_string

                ; ---- helvetica_14 ----
                LEA     XY0, helvetica_14_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_helvetica_14
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALL16  gfx_setfont
                LEA     XY0, s_helvetica_14
                LOADI   D0, #39
                LOADI   D1, #135
                LOADI   D3, #C_BLACK
                CALL16  gfx_draw_string

                ; ---- times_10 ----
                LEA     XY0, times_10_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_times_10
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALL16  gfx_setfont
                LEA     XY0, s_times_10
                LOADI   D0, #40
                LOADI   D1, #163
                LOADI   D3, #C_BLACK
                CALL16  gfx_draw_string

                ; ---- times_12 ----
                LEA     XY0, times_12_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_times_12
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALL16  gfx_setfont
                LEA     XY0, s_times_12
                LOADI   D0, #40
                LOADI   D1, #177
                LOADI   D3, #C_BLACK
                CALL16  gfx_draw_string

                ; ---- times_14 ----
                LEA     XY0, times_14_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_times_14
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALL16  gfx_setfont
                LEA     XY0, s_times_14
                LOADI   D0, #39
                LOADI   D1, #192
                LOADI   D3, #C_BLACK
                CALL16  gfx_draw_string

                ; ---- new_century_10 ----
                LEA     XY0, new_century_10_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_new_century_10
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALL16  gfx_setfont
                LEA     XY0, s_new_century_10
                LOADI   D0, #40
                LOADI   D1, #221
                LOADI   D3, #C_BLACK
                CALL16  gfx_draw_string

                ; ---- new_century_12 ----
                LEA     XY0, new_century_12_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_new_century_12
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALL16  gfx_setfont
                LEA     XY0, s_new_century_12
                LOADI   D0, #40
                LOADI   D1, #236
                LOADI   D3, #C_BLACK
                CALL16  gfx_draw_string

                ; ---- new_century_14 ----
                LEA     XY0, new_century_14_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_new_century_14
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALL16  gfx_setfont
                LEA     XY0, s_new_century_14
                LOADI   D0, #40
                LOADI   D1, #252
                LOADI   D3, #C_BLACK
                CALL16  gfx_draw_string

                ; ---- palatino_10 (far: LEA mode 01 base+disp) ----
                LEA     XY2, start
                LOADI   D0, #(palatino_10_bits - start)
                LEA     XY0, XY2+D0
                MOVE    D2, Y0
                MOVE    D3, X0
                LOADI   D0, #(font_palatino_10 - start)
                LEA     XY0, XY2+D0
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALL16  gfx_setfont
                LEA     XY0, s_palatino_10
                LOADI   D0, #40
                LOADI   D1, #282
                LOADI   D3, #C_BLACK
                CALL16  gfx_draw_string

                ; ---- palatino_12 (far: LEA mode 01 base+disp) ----
                LEA     XY2, start
                LOADI   D0, #(palatino_12_bits - start)
                LEA     XY0, XY2+D0
                MOVE    D2, Y0
                MOVE    D3, X0
                LOADI   D0, #(font_palatino_12 - start)
                LEA     XY0, XY2+D0
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALL16  gfx_setfont
                LEA     XY0, s_palatino_12
                LOADI   D0, #40
                LOADI   D1, #297
                LOADI   D3, #C_BLACK
                CALL16  gfx_draw_string

                ; ---- palatino_14 (far: LEA mode 01 base+disp) ----
                LEA     XY2, start
                LOADI   D0, #(palatino_14_bits - start)
                LEA     XY0, XY2+D0
                MOVE    D2, Y0
                MOVE    D3, X0
                LOADI   D0, #(font_palatino_14 - start)
                LEA     XY0, XY2+D0
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALL16  gfx_setfont
                LEA     XY0, s_palatino_14
                LOADI   D0, #39
                LOADI   D1, #314
                LOADI   D3, #C_BLACK
                CALL16  gfx_draw_string

.hold:
                LEA     XY0, prompt
                TRAP    #TRAP_PUTLN
                TRAP    #TRAP_GETCHAR
                LOADI   D0, #0
                TRAP    #TRAP_SETVIDMODE
                TRAP    #TRAP_EXIT
.busy:
                LEA     XY0, msg_busy
                TRAP    #TRAP_PUTLN
                TRAP    #TRAP_EXIT

; ----------------------------------------------------------------------------
banner          .TEXT   "KGFX FNTSHOW3: converted IIGS faces", 0
prompt          .TEXT   "drawn - press a key to exit", 0
msg_busy        .TEXT   "gfx: graphics busy", 0
title           .TEXT   "KGFX - Apple IIGS faces converted to K16 (mono + wide proportional):", 0
s_courier_9          .TEXT   "Courier 9  The quick brown fox  WMil 0123 @#&", 0
s_courier_10         .TEXT   "Courier 10  The quick brown fox  WMil 0123 @#&", 0
s_courier_12         .TEXT   "Courier 12  The quick brown fox  WMil 0123 @#&", 0
s_helvetica_10       .TEXT   "Helvetica 10  The quick brown fox  WMil 0123 @#&", 0
s_helvetica_12       .TEXT   "Helvetica 12  The quick brown fox  WMil 0123 @#&", 0
s_helvetica_14       .TEXT   "Helvetica 14  The quick brown fox  WMil 0123 @#&", 0
s_times_10           .TEXT   "Times 10  The quick brown fox  WMil 0123 @#&", 0
s_times_12           .TEXT   "Times 12  The quick brown fox  WMil 0123 @#&", 0
s_times_14           .TEXT   "Times 14  The quick brown fox  WMil 0123 @#&", 0
s_new_century_10     .TEXT   "New Century 10  The quick brown fox  WMil 0123 @#&", 0
s_new_century_12     .TEXT   "New Century 12  The quick brown fox  WMil 0123 @#&", 0
s_new_century_14     .TEXT   "New Century 14  The quick brown fox  WMil 0123 @#&", 0
s_palatino_10        .TEXT   "Palatino 10  The quick brown fox  WMil 0123 @#&", 0
s_palatino_12        .TEXT   "Palatino 12  The quick brown fox  WMil 0123 @#&", 0
s_palatino_14        .TEXT   "Palatino 14  The quick brown fox  WMil 0123 @#&", 0

; ---- strikes BELOW the gfx scratch ($6000-$6250) ----
                .ALIGN
                .INCLUDE "../font/gfx_font_courier_9.inc"
                .ALIGN
                .INCLUDE "../font/gfx_font_courier_10.inc"
                .ALIGN
                .INCLUDE "../font/gfx_font_courier_12.inc"
                .ALIGN
                .INCLUDE "../font/gfx_font_helvetica_10.inc"
                .ALIGN
                .INCLUDE "../font/gfx_font_helvetica_12.inc"
                .ALIGN
                .INCLUDE "../font/gfx_font_helvetica_14.inc"
                .ALIGN
                .INCLUDE "../font/gfx_font_times_10.inc"
                .ALIGN
                .INCLUDE "../font/gfx_font_times_12.inc"

; ---- reserve the gfx render scratch region so no font data lands on it ----
                .ORG    $6260
; ---- strikes ABOVE the scratch ----
                .ALIGN
                .INCLUDE "../font/gfx_font_times_14.inc"
                .ALIGN
                .INCLUDE "../font/gfx_font_new_century_10.inc"
                .ALIGN
                .INCLUDE "../font/gfx_font_new_century_12.inc"
                .ALIGN
                .INCLUDE "../font/gfx_font_new_century_14.inc"
                .ALIGN
                .INCLUDE "../font/gfx_font_palatino_10.inc"
                .ALIGN
                .INCLUDE "../font/gfx_font_palatino_12.inc"
                .ALIGN
                .INCLUDE "../font/gfx_font_palatino_14.inc"

                .ALIGN
                .INCLUDE "../gfx.asm"
                .INCLUDE "../gfx_1bpp.asm"
                .INCLUDE "../gfx_8bpp.asm"
                .INCLUDE "../gfx_regions.asm"
                .INCLUDE "../gfx_font.asm"
