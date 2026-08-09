; ============================================================================
; RGNTEST4.asm -- KGFX regions R2.1 Smoke C2: 1-D intersect + union
; ----------------------------------------------------------------------------
; Console test of _isect1d and _union1d. Loads A/B interval buffers by hand,
; runs the op, dumps R. No graphics, no heap.
;
;   intersect:
;     i1: A[10,100)        & B[40,60)   -> 40..60
;     i2: A[10,50)[70,120) & B[30,80)   -> 30..50 70..80
;     i3: A[10,20)         & B[50,60)   -> (empty)
;     i4: A[10,100)        & B[]        -> (empty)
;   union:
;     u1: A[10,40)         | B[30,60)   -> 10..60       (overlap)
;     u2: A[10,20)         | B[20,30)   -> 10..30       (touch coalesce)
;     u3: A[10,20)         | B[50,60)   -> 10..20 50..60 (disjoint)
;     u4: A[10,100)        | B[]        -> 10..100
; ============================================================================
                .INCLUDE "../../kos_defs.inc"
                .INCLUDE "../gfx_regions_defs.inc"

dr_rem          .EQU    $0164
dr_off          .EQU    $0166

                .ORG    $0200
start:
                LEA     XY0, banner
                TRAP    #TRAP_PUTLN

                ; ===== intersect =====
                ; i1: A[10,100) & B[40,60)
                LOADI   D0, #2
                STOREP  D0, Y3, [#RGW_A_N]
                LOADI   D0, #10
                STOREP  D0, Y3, [#RGW_A_X]
                LOADI   D0, #100
                STOREP  D0, Y3, [#RGW_A_X+2]
                LOADI   D0, #2
                STOREP  D0, Y3, [#RGW_B_N]
                LOADI   D0, #40
                STOREP  D0, Y3, [#RGW_B_X]
                LOADI   D0, #60
                STOREP  D0, Y3, [#RGW_B_X+2]
                CALLR   _isect1d
                LEA     XY0, msg_i1
                TRAP    #TRAP_PUTS
                CALLR   dumpR

                ; i2: A[10,50)[70,120) & B[30,80)
                LOADI   D0, #4
                STOREP  D0, Y3, [#RGW_A_N]
                LOADI   D0, #10
                STOREP  D0, Y3, [#RGW_A_X]
                LOADI   D0, #50
                STOREP  D0, Y3, [#RGW_A_X+2]
                LOADI   D0, #70
                STOREP  D0, Y3, [#RGW_A_X+4]
                LOADI   D0, #120
                STOREP  D0, Y3, [#RGW_A_X+6]
                LOADI   D0, #2
                STOREP  D0, Y3, [#RGW_B_N]
                LOADI   D0, #30
                STOREP  D0, Y3, [#RGW_B_X]
                LOADI   D0, #80
                STOREP  D0, Y3, [#RGW_B_X+2]
                CALLR   _isect1d
                LEA     XY0, msg_i2
                TRAP    #TRAP_PUTS
                CALLR   dumpR

                ; i3: A[10,20) & B[50,60)
                LOADI   D0, #2
                STOREP  D0, Y3, [#RGW_A_N]
                LOADI   D0, #10
                STOREP  D0, Y3, [#RGW_A_X]
                LOADI   D0, #20
                STOREP  D0, Y3, [#RGW_A_X+2]
                LOADI   D0, #2
                STOREP  D0, Y3, [#RGW_B_N]
                LOADI   D0, #50
                STOREP  D0, Y3, [#RGW_B_X]
                LOADI   D0, #60
                STOREP  D0, Y3, [#RGW_B_X+2]
                CALLR   _isect1d
                LEA     XY0, msg_i3
                TRAP    #TRAP_PUTS
                CALLR   dumpR

                ; i4: A[10,100) & B[]
                LOADI   D0, #2
                STOREP  D0, Y3, [#RGW_A_N]
                LOADI   D0, #10
                STOREP  D0, Y3, [#RGW_A_X]
                LOADI   D0, #100
                STOREP  D0, Y3, [#RGW_A_X+2]
                LOADI   D0, #0
                STOREP  D0, Y3, [#RGW_B_N]
                CALLR   _isect1d
                LEA     XY0, msg_i4
                TRAP    #TRAP_PUTS
                CALLR   dumpR

                ; ===== union =====
                ; u1: A[10,40) | B[30,60)
                LOADI   D0, #2
                STOREP  D0, Y3, [#RGW_A_N]
                LOADI   D0, #10
                STOREP  D0, Y3, [#RGW_A_X]
                LOADI   D0, #40
                STOREP  D0, Y3, [#RGW_A_X+2]
                LOADI   D0, #2
                STOREP  D0, Y3, [#RGW_B_N]
                LOADI   D0, #30
                STOREP  D0, Y3, [#RGW_B_X]
                LOADI   D0, #60
                STOREP  D0, Y3, [#RGW_B_X+2]
                CALLR   _union1d
                LEA     XY0, msg_u1
                TRAP    #TRAP_PUTS
                CALLR   dumpR

                ; u2: A[10,20) | B[20,30)
                LOADI   D0, #2
                STOREP  D0, Y3, [#RGW_A_N]
                LOADI   D0, #10
                STOREP  D0, Y3, [#RGW_A_X]
                LOADI   D0, #20
                STOREP  D0, Y3, [#RGW_A_X+2]
                LOADI   D0, #2
                STOREP  D0, Y3, [#RGW_B_N]
                LOADI   D0, #20
                STOREP  D0, Y3, [#RGW_B_X]
                LOADI   D0, #30
                STOREP  D0, Y3, [#RGW_B_X+2]
                CALLR   _union1d
                LEA     XY0, msg_u2
                TRAP    #TRAP_PUTS
                CALLR   dumpR

                ; u3: A[10,20) | B[50,60)
                LOADI   D0, #2
                STOREP  D0, Y3, [#RGW_A_N]
                LOADI   D0, #10
                STOREP  D0, Y3, [#RGW_A_X]
                LOADI   D0, #20
                STOREP  D0, Y3, [#RGW_A_X+2]
                LOADI   D0, #2
                STOREP  D0, Y3, [#RGW_B_N]
                LOADI   D0, #50
                STOREP  D0, Y3, [#RGW_B_X]
                LOADI   D0, #60
                STOREP  D0, Y3, [#RGW_B_X+2]
                CALLR   _union1d
                LEA     XY0, msg_u3
                TRAP    #TRAP_PUTS
                CALLR   dumpR

                ; u4: A[10,100) | B[]
                LOADI   D0, #2
                STOREP  D0, Y3, [#RGW_A_N]
                LOADI   D0, #10
                STOREP  D0, Y3, [#RGW_A_X]
                LOADI   D0, #100
                STOREP  D0, Y3, [#RGW_A_X+2]
                LOADI   D0, #0
                STOREP  D0, Y3, [#RGW_B_N]
                CALLR   _union1d
                LEA     XY0, msg_u4
                TRAP    #TRAP_PUTS
                CALLR   dumpR

                LEA     XY0, msg_done
                TRAP    #TRAP_PUTLN
                TRAP    #TRAP_EXIT

; ----------------------------------------------------------------------------
; dumpR -- print R buffer as "lo..hi " pairs, or "(empty)", then newline.
; ----------------------------------------------------------------------------
dumpR:
                LOADP   D0, Y3, [#RGW_R_N]
                STOREP  D0, Y3, [#dr_rem]
                CMP     D0, #0
                BNE     .dr_go
                LEA     XY0, msg_empty
                TRAP    #TRAP_PUTS
                BRA     .dr_nl
.dr_go:
                LOADI   D0, #RGW_R_X
                STOREP  D0, Y3, [#dr_off]
.dr_loop:
                LOADP   D0, Y3, [#dr_rem]
                CMP     D0, #0
                BLE     .dr_nl
                MOVE    Y0, Y3
                LOADP   D0, Y3, [#dr_off]
                MOVE    X0, D0
                LOADD   D0, [XY0+#0]
                TRAP    #TRAP_PUTDEC
                LEA     XY0, msg_dd
                TRAP    #TRAP_PUTS
                MOVE    Y0, Y3
                LOADP   D0, Y3, [#dr_off]
                MOVE    X0, D0
                LOADD   D0, [XY0+#2]
                TRAP    #TRAP_PUTDEC
                LEA     XY0, msg_sp
                TRAP    #TRAP_PUTS
                LOADP   D0, Y3, [#dr_off]
                ADD     D0, #4
                STOREP  D0, Y3, [#dr_off]
                LOADP   D0, Y3, [#dr_rem]
                SUB     D0, #2
                STOREP  D0, Y3, [#dr_rem]
                BRA     .dr_loop
.dr_nl:
                LEA     XY0, msg_nl
                TRAP    #TRAP_PUTS
                RET

; ----------------------------------------------------------------------------
banner          .TEXT   "rgn R2.1 - Smoke C2: intersect + union", 0
msg_i1          .TEXT   "i1: ", 0
msg_i2          .TEXT   "i2: ", 0
msg_i3          .TEXT   "i3: ", 0
msg_i4          .TEXT   "i4: ", 0
msg_u1          .TEXT   "u1: ", 0
msg_u2          .TEXT   "u2: ", 0
msg_u3          .TEXT   "u3: ", 0
msg_u4          .TEXT   "u4: ", 0
msg_dd          .TEXT   "..", 0
msg_sp          .TEXT   " ", 0
msg_empty       .TEXT   "(empty)", 0
msg_done        .TEXT   "done", 0
msg_nl          .TEXT   " ", 0

                .INCLUDE "../gfx_regions.asm"
