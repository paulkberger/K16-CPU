; ============================================================================
; RGNTEST6.asm -- KGFX regions R2.3 Smoke E: visible-region via ping-pong
; ----------------------------------------------------------------------------
; The overlapping-windows payoff. Compute window A's VISIBLE region as
;   vis = A.rect - occluderB - occluderC
; using two region buffers ping-ponged through rgn_subtract, then set vis as
; the clip and fill the whole surface. Only A's visible pixels paint, so the
; result is A's rectangle with a rectangular bite removed where each occluder
; sat -- direct proof the subtracts (and the clip) work, with no z-order
; overdraw hiding anything.
;
;   A  = (50,50,450,400)         window we compute the visible region for
;   B  = (350,100,520,250)       occluder over A's right-middle
;   C  = (100,320,300,460)       occluder over A's bottom-left
;   vis = A - B - C  -> big rect with two rectangular notches.
;
; Holds at the end (graphics auto-reset on sys_exit).
; ============================================================================
                .INCLUDE "../../kos_defs.inc"
                .INCLUDE "../gfx_defs.inc"
                .INCLUDE "../gfx_regions_defs.inc"

vis_pg          .EQU    $0170
vis_of          .EQU    $0172
vis2_pg         .EQU    $0174
vis2_of         .EQU    $0176
occ_pg          .EQU    $0178
occ_of          .EQU    $017A

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

                ; --- allocate vis, vis2, occ regions ---
                LOADI   D0, #256
                CALLR   rgn_new
                BCS     .nomem
                MOVE    D0, Y0
                STOREP  D0, Y3, [#vis_pg]
                MOVE    D0, X0
                STOREP  D0, Y3, [#vis_of]

                LOADI   D0, #256
                CALLR   rgn_new
                BCS     .nomem
                MOVE    D0, Y0
                STOREP  D0, Y3, [#vis2_pg]
                MOVE    D0, X0
                STOREP  D0, Y3, [#vis2_of]

                LOADI   D0, #256
                CALLR   rgn_new
                BCS     .nomem
                MOVE    D0, Y0
                STOREP  D0, Y3, [#occ_pg]
                MOVE    D0, X0
                STOREP  D0, Y3, [#occ_of]

                ; --- vis = A.rect (50,50,450,400) ---
                CALLR   load_vis
                LOADI   D0, #50
                LOADI   D1, #50
                LOADI   D2, #450
                LOADI   D3, #400
                CALLR   rgn_set_rect

                ; --- vis = vis - B(350,100,520,250) ---
                CALLR   load_occ
                LOADI   D0, #350
                LOADI   D1, #100
                LOADI   D2, #520
                LOADI   D3, #250
                CALLR   rgn_set_rect
                CALLR   sub_occ                 ; vis2 = vis - occ ; swap

                ; --- vis = vis - C(100,320,300,460) ---
                CALLR   load_occ
                LOADI   D0, #100
                LOADI   D1, #320
                LOADI   D2, #300
                LOADI   D3, #460
                CALLR   rgn_set_rect
                CALLR   sub_occ

                ; --- clip to vis, fill the surface ---
                MOVE    Y1, Y3
                LOADI   X1, #GS_BASE            ; XY1 = descriptor
                CALLR   load_vis                ; XY0 = vis
                CALLR   gfx_setclip
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
; sub_occ -- vis2 = vis - occ ; then swap vis <-> vis2.
;   Leaves the running visible region in vis. Rebuilds nothing for the caller.
; ----------------------------------------------------------------------------
sub_occ:
                LOADP   D0, Y3, [#vis2_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#vis2_of]
                MOVE    X0, D0                  ; XY0 = vis2 (dst)
                LOADP   D0, Y3, [#vis_pg]
                MOVE    Y1, D0
                LOADP   D0, Y3, [#vis_of]
                MOVE    X1, D0                  ; XY1 = vis (A)
                LOADP   D0, Y3, [#occ_pg]
                MOVE    Y2, D0
                LOADP   D0, Y3, [#occ_of]
                MOVE    X2, D0                  ; XY2 = occ (B)
                CALLR   rgn_subtract
                ; swap vis <-> vis2
                LOADP   D0, Y3, [#vis_pg]
                LOADP   D1, Y3, [#vis2_pg]
                STOREP  D1, Y3, [#vis_pg]
                STOREP  D0, Y3, [#vis2_pg]
                LOADP   D0, Y3, [#vis_of]
                LOADP   D1, Y3, [#vis2_of]
                STOREP  D1, Y3, [#vis_of]
                STOREP  D0, Y3, [#vis2_of]
                RET

; load_vis / load_occ -- XY0 = the region ptr from its stash
load_vis:
                LOADP   D0, Y3, [#vis_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#vis_of]
                MOVE    X0, D0
                RET
load_occ:
                LOADP   D0, Y3, [#occ_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#occ_of]
                MOVE    X0, D0
                RET

; ----------------------------------------------------------------------------
banner          .TEXT   "rgn R2.3 - Smoke E: visible region = A - B - C (ping-pong)", 0
msg_busy        .TEXT   "gfx: graphics busy", 0
msg_nomem       .TEXT   "rgn: out of heap", 0

                .INCLUDE "../gfx.asm"
                .INCLUDE "../gfx_regions.asm"
