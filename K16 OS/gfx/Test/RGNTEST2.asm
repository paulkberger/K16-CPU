; ============================================================================
; RGNTEST2.asm -- KGFX regions R1 Smoke B: clip integration (visual)
; ----------------------------------------------------------------------------
; Opens 8bpp mode 2, clears black, builds an L-shaped clip region, then:
;   - fillrect over the WHOLE surface (idx 15) -> only the L is painted
;   - draws a corner-to-corner diagonal (idx 9) -> only its part inside the L
; Expected: a white L on black, with the red diagonal visible ONLY where it
; crosses the L's upper band (it leaves the L when it would enter the narrow
; lower band, since there x >= 200 but the band is x[50,200)).
;
; L-shape (surface coords):
;   band0: y[50,200)  x[50,400)
;   band1: y[200,350) x[50,200)
;
; Depth-blind: change the gfx_open arg to #1 to verify the same clip in 1bpp.
; Holds at the end (graphics auto-reset on sys_exit, so we don't exit).
; ============================================================================
                .INCLUDE "../../kos_defs.inc"
                .INCLUDE "../gfx_defs.inc"
                .INCLUDE "../gfx_regions_defs.inc"
                .ORG    $0200
start:
                LEA     XY0, banner
                TRAP    #TRAP_PUTLN

                LOADI   D0, #2                  ; 8bpp mode 2 (#1 = 1bpp to retest)
                CALLR   gfx_open
                BCS     .busy
                MOVE    Y1, Y3
                LOADI   X1, #GS_BASE            ; XY1 = descriptor (held)

                ; clear to black
                LOADI   D0, #0
                CALLR   gfx_clear

                ; --- build the L-shaped clip region ---
                LOADI   D0, #256
                CALLR   rgn_new                 ; XY0 = region ptr
                BCS     .nomem
                ; band0: y[50,200) x[50,400)
                LOADI   D1, #50
                STORED  D1, [XY0+#RGN_BANDS+BND_YTOP]
                LOADI   D1, #200
                STORED  D1, [XY0+#RGN_BANDS+BND_YBOT]
                LOADI   D1, #2
                STORED  D1, [XY0+#RGN_BANDS+BND_NX]
                LOADI   D1, #50
                STORED  D1, [XY0+#RGN_BANDS+BND_X0]
                LOADI   D1, #400
                STORED  D1, [XY0+#RGN_BANDS+BND_X0+2]
                ; band1 at offset 22: y[200,350) x[50,200)
                LOADI   D1, #200
                STORED  D1, [XY0+#22]           ; ytop
                LOADI   D1, #350
                STORED  D1, [XY0+#24]           ; ybot
                LOADI   D1, #2
                STORED  D1, [XY0+#26]           ; nx
                LOADI   D1, #50
                STORED  D1, [XY0+#28]           ; xL
                LOADI   D1, #200
                STORED  D1, [XY0+#30]           ; xR
                LOADI   D1, #2
                STORED  D1, [XY0+#RGN_NBANDS]
                ; bbox (cosmetic; band_at/pt_in don't read it)
                LOADI   D1, #50
                STORED  D1, [XY0+#RGN_TOP]
                LOADI   D1, #50
                STORED  D1, [XY0+#RGN_LEFT]
                LOADI   D1, #350
                STORED  D1, [XY0+#RGN_BOTTOM]
                LOADI   D1, #400
                STORED  D1, [XY0+#RGN_RIGHT]

                ; --- install as clip (XY0 = region, XY1 = desc) ---
                CALLR   gfx_setclip

                ; --- fill the whole surface; clip restricts it to the L ---
                LOADI   D0, #0
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #0
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #640
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #480
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #15                 ; white
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_fillrect

                ; --- diagonal across the whole surface; clipped per-pixel ---
                LOADI   D0, #0
                STOREP  D0, Y3, [#gl_x0]
                LOADI   D0, #0
                STOREP  D0, Y3, [#gl_y0]
                LOADI   D0, #639
                STOREP  D0, Y3, [#gl_x1]
                LOADI   D0, #479
                STOREP  D0, Y3, [#gl_y1]
                LOADI   D0, #9                  ; red
                STOREP  D0, Y3, [#gl_idx]
                CALLR   gfx_line

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

banner          .TEXT   "rgn R1 - Smoke B: clip a fill + line to an L-shape", 0
msg_busy        .TEXT   "gfx: graphics busy", 0
msg_nomem       .TEXT   "rgn: out of heap", 0

                .INCLUDE "../gfx.asm"
                .INCLUDE "../gfx_regions.asm"
