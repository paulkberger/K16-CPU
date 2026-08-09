; ============================================================================
; GFXT720.asm   --  K16 graphics test harness: mode-1 full-panel (1280x720)
; ----------------------------------------------------------------------------
; 3 June 2026 -- Thin harness over the gfx library (gfxdefs.inc + gfx.inc).
;   Mode-1 native scene that pushes the poke to every framebuffer edge
;   (x=0/1279, y=0/719) to verify the emulator's full mode-1 extent.
; ============================================================================
                .INCLUDE "../../kos_defs.inc"
                .INCLUDE "../gfx_defs.inc"
                .INCLUDE "../gfx_regions_defs.inc"

                .ORG    $0200

start:
                LEA     XY0, banner
                TRAP    #TRAP_PUTLN

                LOADI   D0, #1                  ; mode 1: 1280x720 1bpp (full-panel emu test)
                CALLR   gfx_open
                BCS     .busy

                MOVE    Y1, Y3
                LOADI   X1, #GS_BASE            ; XY1 = descriptor (held)

                ; clear to black (idx 0)
                LOADI   D0, #0
                CALLR   gfx_clear

                ; centre fill block (idx 1) at (320,180) 640x360 -- long spans, many rows
                LOADI   D0, #320
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #180
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #640
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #360
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #1
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_fillrect

                ; full-screen border (idx 1) at exact edges (0,0) 1280x720
                ;   hits x=0 (byte0 bit7), x=1279 (byte159 bit0), y=0, y=719
                LOADI   D0, #0
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #0
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #1280
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #720
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #1
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_rect

                ; full diagonal (idx 1): (0,0)-(1279,719)
                LOADI   D0, #0
                STOREP  D0, Y3, [#gl_x0]
                LOADI   D0, #0
                STOREP  D0, Y3, [#gl_y0]
                LOADI   D0, #1279
                STOREP  D0, Y3, [#gl_x1]
                LOADI   D0, #719
                STOREP  D0, Y3, [#gl_y1]
                LOADI   D0, #1
                STOREP  D0, Y3, [#gl_idx]
                CALLR   gfx_line

                ; full anti-diagonal (idx 1): (1279,0)-(0,719)
                LOADI   D0, #1279
                STOREP  D0, Y3, [#gl_x0]
                LOADI   D0, #0
                STOREP  D0, Y3, [#gl_y0]
                LOADI   D0, #0
                STOREP  D0, Y3, [#gl_x1]
                LOADI   D0, #719
                STOREP  D0, Y3, [#gl_y1]
                LOADI   D0, #1
                STOREP  D0, Y3, [#gl_idx]
                CALLR   gfx_line

                ; full-width horizontal (idx 1): (0,360)-(1279,360)
                LOADI   D0, #0
                STOREP  D0, Y3, [#gl_x0]
                LOADI   D0, #360
                STOREP  D0, Y3, [#gl_y0]
                LOADI   D0, #1279
                STOREP  D0, Y3, [#gl_x1]
                LOADI   D0, #360
                STOREP  D0, Y3, [#gl_y1]
                LOADI   D0, #1
                STOREP  D0, Y3, [#gl_idx]
                CALLR   gfx_line

                ; full-height vertical (idx 1): (640,0)-(640,719)
                LOADI   D0, #640
                STOREP  D0, Y3, [#gl_x0]
                LOADI   D0, #0
                STOREP  D0, Y3, [#gl_y0]
                LOADI   D0, #640
                STOREP  D0, Y3, [#gl_x1]
                LOADI   D0, #719
                STOREP  D0, Y3, [#gl_y1]
                LOADI   D0, #1
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
                .TEXT   "gfx 720 - mode 1 full-panel emu test (1280x720)", 0
                .ALIGN
msg_busy:
                .TEXT   "gfx: graphics busy", 0
                .ALIGN

; ==========================================================================
; Library
; ==========================================================================
                .INCLUDE "../gfx.asm"
                .INCLUDE "../gfx_regions.asm"
