; ============================================================================
; FNTTEST2.asm  --  KGFX font F1b smoke: clip a string with a region.
; ----------------------------------------------------------------------------
; Proves gfx_draw_string inherits clipping for free (it renders via
; gfx_setpixel, which already runs the GS_CLIP region test). No library change.
;
; mode 2 (640x480 8bpp). Clears black, then:
;   - reference: "K16 OS" drawn unclipped (red) at y=80  -> full extent
;   - clip: a region rect (0,100,60,160) covering only the LEFT part of the
;     second string; setclip; "K16 OS" drawn white at y=120.
; The clip's right edge (x=60) falls INSIDE the '6' cell (56..63), so the '6'
; is sliced by a clean vertical edge; "K1" survive whole, space/O/S vanish.
; Holds (graphics auto-reset on sys_exit).
;
; Visual pass criteria:
;   * red row shows the whole "K16 OS"
;   * white row shows "K1" + the left columns of "6", cut by a vertical edge;
;     nothing paints to the right of x=60
; ============================================================================
                .INCLUDE "../../kos_defs.inc"
                .INCLUDE "../gfx_defs.inc"
                .INCLUDE "../gfx_regions_defs.inc"
                .INCLUDE "../gfx_font_defs.inc"

clip_pg         .EQU    $0170
clip_of         .EQU    $0172

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
                CALLR   gfx_clear               ; black

                ; --- patch demo font glyph-bits ptr, make it current ---
                LEA     XY0, ascii_glyph_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_ascii
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALLR   gfx_setfont

                ; --- reference: full string, NO clip (red) ---
                LEA     XY0, str_k16os
                LOADI   D0, #40
                LOADI   D1, #80
                LOADI   D3, #4
                CALLR   gfx_draw_string

                ; --- build left-half clip region rect (0,100,60,160) ---
                LOADI   D0, #256
                CALLR   rgn_new
                BCS     .nomem
                MOVE    D0, Y0
                STOREP  D0, Y3, [#clip_pg]
                MOVE    D0, X0
                STOREP  D0, Y3, [#clip_of]
                ; XY0 still = region
                LOADI   D0, #0                  ; left
                LOADI   D1, #100                ; top
                LOADI   D2, #60                 ; right (cut edge, inside '6')
                LOADI   D3, #160                ; bottom
                CALLR   rgn_set_rect

                ; --- set clip = region ---
                LOADP   D0, Y3, [#clip_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#clip_of]
                MOVE    X0, D0
                CALLR   gfx_setclip             ; XY1=desc, XY0=region

                ; --- clipped string (white) at y=120 ---
                LEA     XY0, str_k16os
                LOADI   D0, #40
                LOADI   D1, #120
                LOADI   D3, #15
                CALLR   gfx_draw_string

.hold:
                BRA     .hold
.busy:
                LEA     XY0, msg_busy
                TRAP    #TRAP_PUTLN
                TRAP    #TRAP_EXIT
.nomem:
                LEA     XY0, msg_nomem
                TRAP    #TRAP_PUTLN
                TRAP    #TRAP_EXIT

; ----------------------------------------------------------------------------
banner          .TEXT   "font F1b: clip a string with a region", 0
msg_busy        .TEXT   "gfx: graphics busy", 0
msg_nomem       .TEXT   "rgn: out of heap", 0
str_k16os       .TEXT   "K16 OS", 0

                .ALIGN
                .INCLUDE "../gfx_font_ascii.inc"

                .ALIGN
                .INCLUDE "../gfx.asm"
                .INCLUDE "../gfx_regions.asm"
                .INCLUDE "../gfx_font.asm"
