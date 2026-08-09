; ============================================================================
; FNTTEST4.asm  --  KGFX mode-1 (1bpp) F4 PROPORTIONAL harness.
; ----------------------------------------------------------------------------
; 1280x720 1bpp, MSB-first. Uses the proportional font gfx_font_ascii_prop.inc
; (FNT_FL_PROP set; per-char WTAB advance, left-justified glyphs, o[c]=0).
; Draws once, waits for a key, exits. Each block isolates one F4 path:
;
;   P1  i-line vs W-line, same x=0    advance: w[c] varies -> the all-'i' line
;                                     (w=5) ends well left of the all-'W' line
;                                     (w=8). Proves fn_cw drives the pen.
;   P2  proportional sentence         tight kerning eyeball: narrow i/l/./,/'
;                                     hug, wide m/W/# get room. No overlap/gap.
;   P3  flush-left tick at x=200      a 2px tick column drawn at x=200; "flush.."
;                                     starts at x=200 -> first glyph's ink left
;                                     edge sits under the tick (o[c]=0 + left-
;                                     justify => ink flush at the pen).
;   P4  region clip, right edge x=600 long prop string cut clean mid-glyph ->
;                                     proves _fn_rowmask clips on fn_dx (the
;                                     fn_x->fn_dx refactor regression).
;   P5  x=1240, prop run past 1280    right-edge bound mask, no byte1 spill.
;   P6  OPAQUE prop (bg=1 fg=0)       white cells of width w[c] abut tightly,
;                                     black glyph knocked out, NO left-spill ->
;                                     the payoff of left-justify (o>=0): opaque
;                                     bg at the pen exactly covers the ink.
;   P7  2x scale, prop                advance + glyph scale: spacing stays
;                                     proportional (fn_cw * scale via fillrect).
;   P8  2x scale + clip x=600         scaled prop clips at block granularity.
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

; ---- clip band right edge (P4 / P8) -----------------------------------------
CLIP_L          .EQU    0
CLIP_R          .EQU    600

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

                ; --- proportional font (depth-blind) ---
                LEA     XY0, ascii_glyph_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_ascii
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALLR   gfx_setfont             ; caches prop flag + WTAB/OTAB

                ; --- clip region (P4 / P8) ---
                LOADI   D0, #256
                CALLR   rgn_new
                BCS     .nomem
                MOVE    D0, Y0
                STOREP  D0, Y3, [#rC_pg]
                MOVE    D0, X0
                STOREP  D0, Y3, [#rC_of]

                ; --- clear surface to 0 ---
                LOADI   D0, #C_CLR
                CALLR   gfx_clear

                ; ====================================================
                ; P1  advance: all-'i' (w=5) vs all-'W' (w=8) from x=0
                ; ====================================================
                LEA     XY0, p1i
                LOADI   D0, #0
                LOADI   D1, #16
                LOADI   D3, #C_SET
                CALLR   gfx_draw_string
                LEA     XY0, p1w
                LOADI   D0, #0
                LOADI   D1, #36
                LOADI   D3, #C_SET
                CALLR   gfx_draw_string

                ; ====================================================
                ; P2  proportional sentence (eyeball tight kerning)
                ; ====================================================
                LEA     XY0, p2
                LOADI   D0, #0
                LOADI   D1, #64
                LOADI   D3, #C_SET
                CALLR   gfx_draw_string

                ; ====================================================
                ; P3  flush-left: tick column at x=200, text starts there
                ; ====================================================
                LOADI   D0, #200
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #82
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #2                  ; 2px tick
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #10
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_SET
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_fillrect
                LEA     XY0, p3
                LOADI   D0, #200
                LOADI   D1, #96
                LOADI   D3, #C_SET
                CALLR   gfx_draw_string

                ; ====================================================
                ; P4  region clip cuts prop string clean at x=600
                ; ====================================================
                LOADP   D0, Y3, [#rC_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#rC_of]
                MOVE    X0, D0
                LOADI   D0, #CLIP_L
                LOADI   D1, #124
                LOADI   D2, #CLIP_R
                LOADI   D3, #150
                CALLR   rgn_set_rect
                LOADP   D0, Y3, [#rC_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#rC_of]
                MOVE    X0, D0
                CALLR   gfx_setclip             ; clip ON
                LEA     XY0, p4
                LOADI   D0, #0
                LOADI   D1, #130
                LOADI   D3, #C_SET
                CALLR   gfx_draw_string
                LOADI   D0, #0                  ; clip OFF
                MOVE    Y0, D0
                MOVE    X0, D0
                CALLR   gfx_setclip

                ; ====================================================
                ; P5  right-edge: prop run past width 1280, no spill
                ; ====================================================
                LEA     XY0, p5
                LOADI   D0, #1240
                LOADI   D1, #180
                LOADI   D3, #C_SET
                CALLR   gfx_draw_string

                ; ====================================================
                ; P6  OPAQUE prop: white cells (w[c] wide) abut, black glyph
                ;      knocked out; no left-spill (left-justify payoff).
                ; ====================================================
                LEA     XY0, p6
                LOADI   D0, #0
                LOADI   D1, #212
                LOADI   D3, #$0100              ; (bg<<8)|fg = bg 1 (white), fg 0
                CALLR   gfx_draw_string_opaque

                ; ====================================================
                ; P7  2x scale, proportional (advance + glyph scale)
                ; ====================================================
                LOADI   D0, #2
                CALLR   gfx_setfontscale
                LEA     XY0, p7
                LOADI   D0, #0
                LOADI   D1, #250
                LOADI   D3, #C_SET
                CALLR   gfx_draw_string

                ; ====================================================
                ; P8  2x scale + region clip at x=600
                ; ====================================================
                LOADP   D0, Y3, [#rC_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#rC_of]
                MOVE    X0, D0
                LOADI   D0, #CLIP_L
                LOADI   D1, #292
                LOADI   D2, #CLIP_R
                LOADI   D3, #336
                CALLR   rgn_set_rect
                LOADP   D0, Y3, [#rC_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#rC_of]
                MOVE    X0, D0
                CALLR   gfx_setclip
                LEA     XY0, p8
                LOADI   D0, #0
                LOADI   D1, #300
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
banner          .TEXT   "FNTTEST4: mode 1 (1bpp) F4 proportional", 0
prompt          .TEXT   "drawn - press a key to exit", 0
msg_busy        .TEXT   "gfx: graphics busy", 0
msg_nomem       .TEXT   "rgn: out of heap", 0

p1i             .TEXT   "iiiiiiiiiiiiiiiiiiii  <- all i (w=5) ends left of:", 0
p1w             .TEXT   "WWWWWWWWWWWWWWWWWWWW  <- all W (w=8)", 0
p2              .TEXT   "P2 The quick brown fox: ITWm i.l',;!? proportional", 0
p3              .TEXT   "flush at x=200 (ink under the tick)", 0
p4              .TEXT   "P4 proportional region clip at x=600 - every glyph past this column must be cut clean >>>>>>>>>>", 0
p5              .TEXT   "RIGHTEDGEMW", 0
p6              .TEXT   "P6 opaque prop: iWmM.l',!  cells abut, no spill", 0
p7              .TEXT   "P7 2x prop 0123 iWmM", 0
p8              .TEXT   "P8 2x prop clipped at x=600 - tail must vanish >>>>>", 0

                .ALIGN
                .INCLUDE "../gfx_font_ascii_prop.inc"

                .ALIGN
                .INCLUDE "../gfx.asm"
                .INCLUDE "../gfx_1bpp.asm"
                .INCLUDE "../gfx_8bpp.asm"
                .INCLUDE "../gfx_regions.asm"
                .INCLUDE "../gfx_font.asm"
