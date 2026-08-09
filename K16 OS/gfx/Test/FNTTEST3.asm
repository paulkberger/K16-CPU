; ============================================================================
; FNTTEST3.asm  --  KGFX mode-1 (1bpp) font harness: exercises vtext_1 (F3).
; ----------------------------------------------------------------------------
; 1280x720 1bpp, MSB-first. Pixel idx is a single bit: 1 = set, 0 = clear.
; Static screen (no double-buffer needed in 1bpp here); draws once, waits for
; a key, exits. Each block targets a distinct vtext_1 / _fn_rowmask path:
;
;   L1  x=0 , fg=1   single-byte path: s=(x&7)=0 -> byte1 skipped (.vt1_done).
;   L2  x=3 , fg=1   straddle path: s=3 -> both RMW bytes, every glyph spans 2.
;   L3  x=0 , fg=1   region clip: clip rect (0,Tc,600,Bc) cuts the line mid-
;                    glyph at x=600 -> proves _fn_rowmask region mask in 1bpp.
;   L4  fg=0         inverse: fill a white bar (idx=1), draw text fg=0 over it
;                    -> black text knocked out via gfx_rmw1 AND-NOT path.
;   L5  x=1240,fg=1  right-edge: glyphs run past width 1280; bound mask must
;                    clip cleanly with no byte1 spill garbage into the next row.
;
; Build: assemble as a .COM; same include tail as the other gfx/Test harnesses.
; ============================================================================
                .INCLUDE "../../kos_defs.inc"
                .INCLUDE "../gfx_defs.inc"
                .INCLUDE "../gfx_regions_defs.inc"
                .INCLUDE "../gfx_font_defs.inc"

; ---- palette (1bpp) ---------------------------------------------------------
C_CLR           .EQU    0               ; background bit
C_SET           .EQU    1               ; foreground bit (set)

; ---- clip band for L3 -------------------------------------------------------
CLIP_L          .EQU    0
CLIP_T          .EQU    96
CLIP_R          .EQU    600
CLIP_B          .EQU    120

; ---- harness scratch --------------------------------------------------------
rC_pg           .EQU    $0164           ; clip region ptr
rC_of           .EQU    $0166

                .ORG    $0200
start:
                LEA     XY0, banner
                TRAP    #TRAP_PUTLN

                ; --- open 1bpp surface ---
                LOADI   D0, #1
                CALLR   gfx_open
                BCS     .busy
                MOVE    Y1, Y3
                LOADI   X1, #GS_BASE

                ; --- font (ASCII, depth-blind) ---
                LEA     XY0, ascii_glyph_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_ascii
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALLR   gfx_setfont

                ; --- clip region (for L3) ---
                LOADI   D0, #256
                CALLR   rgn_new
                BCS     .nomem
                MOVE    D0, Y0
                STOREP  D0, Y3, [#rC_pg]
                MOVE    D0, X0
                STOREP  D0, Y3, [#rC_of]
                LOADP   D0, Y3, [#rC_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#rC_of]
                MOVE    X0, D0
                LOADI   D0, #CLIP_L
                LOADI   D1, #CLIP_T
                LOADI   D2, #CLIP_R
                LOADI   D3, #CLIP_B
                CALLR   rgn_set_rect

                ; --- clear surface to 0 ---
                LOADI   D0, #C_CLR
                CALLR   gfx_clear

                ; ====================================================
                ; L1  x=0  fg=1  -- s=0 single-byte path
                ; ====================================================
                LEA     XY0, l1
                LOADI   D0, #0
                LOADI   D1, #20
                LOADI   D3, #C_SET
                CALLR   gfx_draw_string

                ; ====================================================
                ; L2  x=3  fg=1  -- s=3 straddle path (both RMW bytes)
                ; ====================================================
                LEA     XY0, l2
                LOADI   D0, #3
                LOADI   D1, #44
                LOADI   D3, #C_SET
                CALLR   gfx_draw_string

                ; ====================================================
                ; L3  x=0  fg=1  -- region clip cuts at x=600 mid-glyph
                ; ====================================================
                LOADP   D0, Y3, [#rC_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#rC_of]
                MOVE    X0, D0
                CALLR   gfx_setclip             ; clip ON
                LEA     XY0, l3
                LOADI   D0, #0
                LOADI   D1, #100
                LOADI   D3, #C_SET
                CALLR   gfx_draw_string
                LOADI   D0, #0                  ; clip OFF
                MOVE    Y0, D0
                MOVE    X0, D0
                CALLR   gfx_setclip

                ; ====================================================
                ; L4  fg=0  -- inverse: white bar then knock-out text
                ; ====================================================
                LOADI   D0, #40
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #150
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #420
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #20
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_SET              ; bar = set bits (white)
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_fillrect
                LEA     XY0, l4
                LOADI   D0, #48
                LOADI   D1, #152
                LOADI   D3, #C_CLR              ; fg=0 -> clear (inverse)
                CALLR   gfx_draw_string

                ; ====================================================
                ; L5  x=1240 fg=1 -- right-edge bound (glyphs run past 1280)
                ; ====================================================
                LEA     XY0, l5
                LOADI   D0, #1240
                LOADI   D1, #200
                LOADI   D3, #C_SET
                CALLR   gfx_draw_string

                ; ====================================================
                ; L6  2x scale  fg=1  -- readable scaled text (fillrect blocks)
                ; ====================================================
                LOADI   D0, #2
                CALLR   gfx_setfontscale
                LEA     XY0, l6
                LOADI   D0, #0
                LOADI   D1, #250
                LOADI   D3, #C_SET
                CALLR   gfx_draw_string

                ; ====================================================
                ; L7  2x scale + region clip -- scaled text clips too
                ; ====================================================
                LOADP   D0, Y3, [#rC_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#rC_of]
                MOVE    X0, D0
                LOADI   D0, #CLIP_L
                LOADI   D1, #290
                LOADI   D2, #CLIP_R              ; right edge x=600
                LOADI   D3, #336
                CALLR   rgn_set_rect
                LOADP   D0, Y3, [#rC_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#rC_of]
                MOVE    X0, D0
                CALLR   gfx_setclip
                LEA     XY0, l7
                LOADI   D0, #0
                LOADI   D1, #298
                LOADI   D3, #C_SET
                CALLR   gfx_draw_string
                LOADI   D0, #0                  ; clip OFF
                MOVE    Y0, D0
                MOVE    X0, D0
                CALLR   gfx_setclip
                LOADI   D0, #1                  ; scale back to 1x
                CALLR   gfx_setfontscale

                ; --- done: wait for a key, then exit ---
                LEA     XY0, prompt
                TRAP    #TRAP_PUTLN
                TRAP    #TRAP_GETCHAR
                TRAP    #TRAP_EXIT

.busy:
                LEA     XY0, msg_busy
                TRAP    #TRAP_PUTLN
                TRAP    #TRAP_EXIT
.nomem:
                LEA     XY0, msg_nomem
                TRAP    #TRAP_PUTLN
                TRAP    #TRAP_EXIT

; ----------------------------------------------------------------------------
banner          .TEXT   "FNTTEST3: mode 1 (1bpp) vtext_1 test", 0
prompt          .TEXT   "drawn - press a key to exit", 0
msg_busy        .TEXT   "gfx: graphics busy", 0
msg_nomem       .TEXT   "rgn: out of heap", 0

l1              .TEXT   "L1 x=0  s=0 single-byte  0123456789", 0
l2              .TEXT   "L2 x=3  s=3 straddle     ABCDEFGHIJ", 0
l3              .TEXT   "L3 region clip box right edge is x=600 - every glyph past that column must be cut clean >>>>>>>>>>", 0
l4              .TEXT   "L4 inverse text (fg=0) knocked out of a white bar", 0
l5              .TEXT   "L5 RIGHTEDGE", 0
l6              .TEXT   "L6 2x scale - readable mode-1 text 0123456789", 0
l7              .TEXT   "L7 2x scale clipped at x=600 - tail must vanish >>>>>>", 0

                .ALIGN
                .INCLUDE "../gfx_font_ascii.inc"

                .ALIGN
                .INCLUDE "../gfx.asm"
                .INCLUDE "../gfx_regions.asm"
                .INCLUDE "../gfx_font.asm"
