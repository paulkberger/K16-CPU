; ============================================================================
; GFXTEST3.asm  --  K16 graphics test harness: depth-blind scene (8bpp/1bpp)
; ----------------------------------------------------------------------------
; 3 June 2026 -- Thin harness over the gfx library (gfxdefs.inc + gfx.inc).
;   Standard test scene; change the mode arg in start (#2 = 8bpp mode 2,
;   #1 = 1bpp mode 1) to verify depth-independence. Drawing code lives in
;   gfx.inc; this file is scene + data only.
; ============================================================================
                .INCLUDE "../../kos_defs.inc"
                .INCLUDE "../gfx_defs.inc"
                .INCLUDE "../gfx_regions_defs.inc"

                .ORG    $0200

start:
                LEA     XY0, banner
                TRAP    #TRAP_PUTLN

                LOADI   D0, #2                  ; <-- #2 = 8bpp, #1 = 1bpp mono
                CALLR   gfx_open
                BCS     .busy

                MOVE    Y1, Y3
                LOADI   X1, #GS_BASE            ; XY1 = descriptor (held)

                ; clear to black / clear (idx 0)
                LOADI   D0, #0
                CALLR   gfx_clear

                ; fillrect backdrop (idx 1) at (40,40) 560x400
                LOADI   D0, #40
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #40
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #560
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #400
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #1
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_fillrect

                ; rect outline (idx 14) at (20,20) 600x440
                LOADI   D0, #20
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #20
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #600
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #440
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #14
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_rect

                ; diagonal (idx 9): (0,0)-(639,479)
                LOADI   D0, #0
                STOREP  D0, Y3, [#gl_x0]
                LOADI   D0, #0
                STOREP  D0, Y3, [#gl_y0]
                LOADI   D0, #639
                STOREP  D0, Y3, [#gl_x1]
                LOADI   D0, #479
                STOREP  D0, Y3, [#gl_y1]
                LOADI   D0, #9
                STOREP  D0, Y3, [#gl_idx]
                CALLR   gfx_line

                ; anti-diagonal (idx 13): (639,0)-(0,479)
                LOADI   D0, #639
                STOREP  D0, Y3, [#gl_x0]
                LOADI   D0, #0
                STOREP  D0, Y3, [#gl_y0]
                LOADI   D0, #0
                STOREP  D0, Y3, [#gl_x1]
                LOADI   D0, #479
                STOREP  D0, Y3, [#gl_y1]
                LOADI   D0, #13
                STOREP  D0, Y3, [#gl_idx]
                CALLR   gfx_line

                ; horizontal (idx 11): (0,240)-(639,240)
                LOADI   D0, #0
                STOREP  D0, Y3, [#gl_x0]
                LOADI   D0, #240
                STOREP  D0, Y3, [#gl_y0]
                LOADI   D0, #639
                STOREP  D0, Y3, [#gl_x1]
                LOADI   D0, #240
                STOREP  D0, Y3, [#gl_y1]
                LOADI   D0, #11
                STOREP  D0, Y3, [#gl_idx]
                CALLR   gfx_line

                ; vertical (idx 10): (320,0)-(320,479)
                LOADI   D0, #320
                STOREP  D0, Y3, [#gl_x0]
                LOADI   D0, #0
                STOREP  D0, Y3, [#gl_y0]
                LOADI   D0, #320
                STOREP  D0, Y3, [#gl_x1]
                LOADI   D0, #479
                STOREP  D0, Y3, [#gl_y1]
                LOADI   D0, #10
                STOREP  D0, Y3, [#gl_idx]
                CALLR   gfx_line

                ; clip test (idx 15): (-50,100)-(700,100)
                LOADI   D0, #$FFCE              ; -50
                STOREP  D0, Y3, [#gl_x0]
                LOADI   D0, #100
                STOREP  D0, Y3, [#gl_y0]
                LOADI   D0, #700
                STOREP  D0, Y3, [#gl_x1]
                LOADI   D0, #100
                STOREP  D0, Y3, [#gl_y1]
                LOADI   D0, #15
                STOREP  D0, Y3, [#gl_idx]
                CALLR   gfx_line

.hold:
                BRA     .hold

.busy:
                LEA     XY0, msg_busy
                TRAP    #TRAP_PUTLN
                LOADI   D0, #1
                TRAP    #TRAP_EXIT

; ==========================================================================
; Data
; ==========================================================================
banner:
                .TEXT   "gfx S3 - depth-blind geometry via CALLXY vector", 0
                .ALIGN
msg_busy:
                .TEXT   "gfx: graphics busy", 0
                .ALIGN

; ==========================================================================
; Library
; ==========================================================================
                .INCLUDE "../gfx.asm"
                .INCLUDE "../gfx_regions.asm"
