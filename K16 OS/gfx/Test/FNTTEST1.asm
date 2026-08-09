; ============================================================================
; FNTTEST1.asm  --  KGFX font F1a smoke: transparent + opaque string render.
; ----------------------------------------------------------------------------
; mode 2 (640x480 8bpp). Clears black, fills a colour bar, then:
;   - "K16"    drawn TRANSPARENT over the bar  (clear pixels show bar through)
;   - "K16 OS" drawn OPAQUE below              (clear pixels painted with bg)
; Holds at the end (graphics auto-reset on sys_exit).
;
; Visual pass criteria:
;   * the three transparent letters sit on the coloured bar; the gaps between
;     and inside the strokes show the BAR colour (proves transparency)
;   * the lower string's letters sit in solid bg-colour cells on the black
;     field (proves opaque fill); the space renders as a solid bg cell
;   * letter shapes read as  K 1 6  /  K 1 6 (space) O S
; Colour indices are palette-dependent; only contrast matters for the smoke.
; ============================================================================
                .INCLUDE "../../kos_defs.inc"
                .INCLUDE "../gfx_defs.inc"
                .INCLUDE "../gfx_regions_defs.inc"
                .INCLUDE "../gfx_font_defs.inc"

                .ORG    $0200
start:
                LEA     XY0, banner
                TRAP    #TRAP_PUTLN

                LOADI   D0, #2                  ; 8bpp mode 2
                CALLR   gfx_open
                BCS     .busy
                MOVE    Y1, Y3
                LOADI   X1, #GS_BASE            ; XY1 = descriptor
                LOADI   D0, #0
                CALLR   gfx_clear               ; black field

                ; --- colour bar behind the transparent text ---
                LOADI   D0, #40
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #40
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #220
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #28
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #4                  ; bar colour idx
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_fillrect

                ; --- patch demo font's glyph-bits ptr, then make it current ---
                LEA     XY0, glyph_bits         ; Y0=page, X0=offset of glyphs
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_demo
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALLR   gfx_setfont             ; XY1=desc, XY0=font_demo

                ; --- "K16" TRANSPARENT over the bar (fg = white) ---
                LEA     XY0, str_k16
                LOADI   D0, #48
                LOADI   D1, #44
                LOADI   D3, #15                 ; fg white
                CALLR   gfx_draw_string

                ; --- "K16 OS" OPAQUE below (fg = white, bg = idx 2) ---
                LEA     XY0, str_k16os
                LOADI   D0, #40
                LOADI   D1, #120
                LOADI   D3, #$020F              ; (bg=2)<<8 | (fg=15)
                CALLR   gfx_draw_string_opaque

.hold:
                BRA     .hold
.busy:
                LEA     XY0, msg_busy
                TRAP    #TRAP_PUTLN
                TRAP    #TRAP_EXIT

; ----------------------------------------------------------------------------
banner          .TEXT   "font F1a: transparent + opaque", 0
msg_busy        .TEXT   "gfx: graphics busy", 0
str_k16         .TEXT   "K16", 0
str_k16os       .TEXT   "K16 OS", 0

                .ALIGN
                .INCLUDE "../gfx_font_demo.inc"

                .ALIGN
                .INCLUDE "../gfx.asm"
                .INCLUDE "../gfx_regions.asm"
                .INCLUDE "../gfx_font.asm"
