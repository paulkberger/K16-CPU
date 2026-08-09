; ============================================================================
; FNTSHOW1.asm  --  KGFX wide-path smoke (word/row >8px strikes), mode 1 1bpp.
; ----------------------------------------------------------------------------
; Step-1 smoke for word-wide (>8px) font support. Proves the >8px byte path:
;   stride x2, LOADD row fetch, +2 advance, _topbits_w 16-bit mask, and the
;   vtext_1 wide placement (2-byte aligned / 3-byte MULB shift).
;
; Layout (1bpp -> vtext_1 only; vtext_8 wide needs an 8bpp harness):
;   A. ModernDOS 8x16 mono  -- narrow REGRESSION ANCHOR (must be unchanged).
;   B. Spleen 16x32 wide  x=40 (s=0)  -- aligned 2-byte wide path.
;   C. Spleen 16x32 wide  x=43 (s=3)  -- 3-byte MULB placement.
;   D. Spleen 16x32 wide  x=47 (s=7)  -- max shift, max spill into byte2.
; Mono advance=16 (mult of 8) -> every glyph on a line shares the start s,
; so each line isolates one vtext_1 sub-path. Sample chars are ink-heavy in
; the right columns (W M @ # &) so a broken byte2 shows at a glance.
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
                ; A. ModernDOS 8x16 mono  -- narrow regression anchor
                ; ====================================================
                LEA     XY0, moderndos_8x16_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_moderndos_8x16
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALLR   gfx_setfont

                LEA     XY0, title
                LOADI   D0, #40
                LOADI   D1, #24
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string

                LEA     XY0, s_anchor
                LOADI   D0, #40
                LOADI   D1, #70
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string

                ; ====================================================
                ; Spleen 16x32 wide mono  -- set once, draw at 3 shifts
                ; ====================================================
                LEA     XY0, spleen_16x32_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_spleen_16x32
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALLR   gfx_setfont

                ; B. aligned: x=40 (s=0) -> 2-byte wide path
                LEA     XY0, s_w0
                LOADI   D0, #40
                LOADI   D1, #120
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string

                ; C. x=43 (s=3) -> 3-byte MULB placement
                LEA     XY0, s_w3
                LOADI   D0, #43
                LOADI   D1, #180
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string

                ; D. x=47 (s=7) -> max shift, max byte2 spill
                LEA     XY0, s_w7
                LOADI   D0, #47
                LOADI   D1, #240
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string

                LEA     XY0, s_note
                LOADI   D0, #40
                LOADI   D1, #300
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
banner          .TEXT   "KGFX FNTSHOW1: wide (>8px) smoke, mode 1 1bpp", 0
prompt          .TEXT   "drawn - press a key to exit", 0
msg_busy        .TEXT   "gfx: graphics busy", 0

title           .TEXT   "KGFX wide-path smoke - word/row >8px strikes (vtext_1):", 0
s_anchor        .TEXT   "ModernDOS 8x16 mono - narrow anchor, must be unchanged  WM@#& 0123", 0
s_w0            .TEXT   "Spleen 16x32  x=40 s=0  WMgjpq @#&!? 0123 ABCxyz", 0
s_w3            .TEXT   "Spleen 16x32  x=43 s=3  WMgjpq @#&!? 0123 ABCxyz", 0
s_w7            .TEXT   "Spleen 16x32  x=47 s=7  WMgjpq @#&!? 0123 ABCxyz", 0
s_note          .TEXT   "anchor unchanged + all 3 wide lines identical = wide path good", 0

                .ALIGN
                .INCLUDE "../font/gfx_font_moderndos_8x16.inc"
                .ALIGN
                .INCLUDE "../font/gfx_font_spleen_16x32.inc"

                .ALIGN
                .INCLUDE "../gfx.asm"
                .INCLUDE "../gfx_1bpp.asm"
                .INCLUDE "../gfx_8bpp.asm"
                .INCLUDE "../gfx_regions.asm"
                .INCLUDE "../font/gfx_font.asm"
