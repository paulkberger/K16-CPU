; ============================================================================
; PATDEMO.asm  --  KGFX mode-1 (1280x720 1bpp) pattern-fill smoke.
; ----------------------------------------------------------------------------
; Exercises gfx_fillpat / vpat_1 only (no font, to isolate the new code):
;   1. Desktop filled with 50% gray in TWO halves split at x=645 (odd, not
;      byte-aligned) -> the seam must be invisible, proving screen-aligned
;      tiling + the leading/trailing partial-byte pattern RMW (gfx_rmwp).
;   2. A "window": solid white panel, black frame, 75% gray title strip,
;      25% gray content area -> three patterns, rect origins not byte-aligned.
;   3. Clip test: a clip region (rect) with a diagonal pattern filled over a
;      larger rect -> the diagonal must appear ONLY inside the clip rect,
;      proving pattern fill honours GS_CLIP (shares fillrow_clipped).
;
; Build: assemble as a .COM; gfx + regions include tail (no font).
; ============================================================================
                .INCLUDE "../../kos_defs.inc"
                .INCLUDE "../gfx_defs.inc"
                .INCLUDE "../gfx_regions_defs.inc"

C_BLACK         .EQU    0
C_WHITE         .EQU    1

rC_pg           .EQU    $0164
rC_of           .EQU    $0166

                .ORG    $0200
start:
                LEA     XY0, banner
                TRAP    #TRAP_PUTLN

                LOADI   D0, #1                  ; 1bpp mode 1
                CALLR   gfx_open
                BCS     .busy
                MOVE    Y1, Y3
                LOADI   X1, #GS_BASE

                ; ============================================================
                ; 1. desktop gray, two halves split at odd x=645
                ; ============================================================
                LOADI   D0, #0
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #0
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #645
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #720
                STOREP  D0, Y3, [#gr_h]
                LEA     XY0, PAT_GRAY
                CALLR   gfx_fillpat
                LOADI   D0, #645
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #0
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #635
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #720
                STOREP  D0, Y3, [#gr_h]
                LEA     XY0, PAT_GRAY
                CALLR   gfx_fillpat

                ; ============================================================
                ; 2. window: white panel, frame, dkgray title, ltgray content
                ; ============================================================
                LOADI   D0, #200                ; solid white panel
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #120
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #560
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #400
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_WHITE
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_fillrect
                LOADI   D0, #200                ; black frame
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #120
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #560
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #400
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_BLACK
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_rect
                LOADI   D0, #201                ; 75% gray title strip
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #121
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #558
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #28
                STOREP  D0, Y3, [#gr_h]
                LEA     XY0, PAT_DKGRAY
                CALLR   gfx_fillpat
                LOADI   D0, #220                ; 25% gray content area
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #160
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #520
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #340
                STOREP  D0, Y3, [#gr_h]
                LEA     XY0, PAT_LTGRAY
                CALLR   gfx_fillpat

                ; ============================================================
                ; 3. clip test: diagonal pattern bounded to a clip rect
                ; ============================================================
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
                LOADI   D0, #300                ; clip rect
                LOADI   D1, #260
                LOADI   D2, #560
                LOADI   D3, #460
                CALLR   rgn_set_rect
                LOADP   D0, Y3, [#rC_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#rC_of]
                MOVE    X0, D0
                CALLR   gfx_setclip             ; clip ON
                LOADI   D0, #220                ; fill diag over the WHOLE content
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #160
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #520
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #340
                STOREP  D0, Y3, [#gr_h]
                LEA     XY0, PAT_DIAG
                CALLR   gfx_fillpat             ; diag appears only in clip rect
                LOADI   D0, #0                  ; clip OFF
                MOVE    Y0, D0
                MOVE    X0, D0
                CALLR   gfx_setclip

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
banner          .TEXT   "PATDEMO: mode 1 1bpp pattern fill (vpat_1)", 0
prompt          .TEXT   "drawn - press a key to exit", 0
msg_busy        .TEXT   "gfx: graphics busy", 0
msg_nomem       .TEXT   "rgn: out of heap", 0

                .ALIGN
PAT_GRAY        .BYTE   $AA, $55, $AA, $55, $AA, $55, $AA, $55   ; 50% checker
PAT_LTGRAY      .BYTE   $44, $11, $44, $11, $44, $11, $44, $11   ; 25%
PAT_DKGRAY      .BYTE   $BB, $EE, $BB, $EE, $BB, $EE, $BB, $EE   ; 75%
PAT_DIAG        .BYTE   $88, $44, $22, $11, $88, $44, $22, $11   ; diagonal

                .ALIGN
                .INCLUDE "../gfx.asm"
                .INCLUDE "../gfx_1bpp.asm"
                .INCLUDE "../gfx_8bpp.asm"
                .INCLUDE "../gfx_regions.asm"
