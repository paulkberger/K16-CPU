; ============================================================================
; RGNTEST3.asm -- KGFX regions R2.1 Smoke C: 1-D interval subtract (_sub1d)
; ----------------------------------------------------------------------------
; Console test of the band-algebra kernel. Loads A and B interval buffers by
; hand, runs R = A - B, dumps R. No graphics, no heap.
;
;   1: A[10,100)            - B[40,60)            -> 10..40 60..100
;   2: A[10,100)            - B[]                 -> 10..100
;   3: A[10,50)[70,120)     - B[30,80)            -> 10..30 80..120
;   4: A[10,100)            - B[0,200)            -> (empty)
;   5: A[10,100)            - B[10,100)           -> (empty)
; ============================================================================
                .INCLUDE "../../kos_defs.inc"
                .INCLUDE "../gfx_regions_defs.inc"

dr_rem          .EQU    $0164           ; dumpR: coords remaining
dr_off          .EQU    $0166           ; dumpR: current R_X offset

                .ORG    $0200
start:
                LEA     XY0, banner
                TRAP    #TRAP_PUTLN

                ; --- case 1: A[10,100) - B[40,60) ---
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
                CALLR   _sub1d
                LEA     XY0, msg_c1
                TRAP    #TRAP_PUTS
                CALLR   dumpR

                ; --- case 2: A[10,100) - B[] ---
                LOADI   D0, #2
                STOREP  D0, Y3, [#RGW_A_N]
                LOADI   D0, #10
                STOREP  D0, Y3, [#RGW_A_X]
                LOADI   D0, #100
                STOREP  D0, Y3, [#RGW_A_X+2]
                LOADI   D0, #0
                STOREP  D0, Y3, [#RGW_B_N]
                CALLR   _sub1d
                LEA     XY0, msg_c2
                TRAP    #TRAP_PUTS
                CALLR   dumpR

                ; --- case 3: A[10,50)[70,120) - B[30,80) ---
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
                CALLR   _sub1d
                LEA     XY0, msg_c3
                TRAP    #TRAP_PUTS
                CALLR   dumpR

                ; --- case 4: A[10,100) - B[0,200) ---
                LOADI   D0, #2
                STOREP  D0, Y3, [#RGW_A_N]
                LOADI   D0, #10
                STOREP  D0, Y3, [#RGW_A_X]
                LOADI   D0, #100
                STOREP  D0, Y3, [#RGW_A_X+2]
                LOADI   D0, #2
                STOREP  D0, Y3, [#RGW_B_N]
                LOADI   D0, #0
                STOREP  D0, Y3, [#RGW_B_X]
                LOADI   D0, #200
                STOREP  D0, Y3, [#RGW_B_X+2]
                CALLR   _sub1d
                LEA     XY0, msg_c4
                TRAP    #TRAP_PUTS
                CALLR   dumpR

                ; --- case 5: A[10,100) - B[10,100) ---
                LOADI   D0, #2
                STOREP  D0, Y3, [#RGW_A_N]
                LOADI   D0, #10
                STOREP  D0, Y3, [#RGW_A_X]
                LOADI   D0, #100
                STOREP  D0, Y3, [#RGW_A_X+2]
                LOADI   D0, #2
                STOREP  D0, Y3, [#RGW_B_N]
                LOADI   D0, #10
                STOREP  D0, Y3, [#RGW_B_X]
                LOADI   D0, #100
                STOREP  D0, Y3, [#RGW_B_X+2]
                CALLR   _sub1d
                LEA     XY0, msg_c5
                TRAP    #TRAP_PUTS
                CALLR   dumpR

                LEA     XY0, msg_done
                TRAP    #TRAP_PUTLN
                TRAP    #TRAP_EXIT

; ----------------------------------------------------------------------------
; dumpR -- print the R buffer as "lo..hi " pairs, or "(empty)", then newline.
;   Rebuilds the R pointer from dr_off each step (print TRAPs clobber XY0/D).
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
                LOADD   D0, [XY0+#0]            ; lo
                TRAP    #TRAP_PUTDEC
                LEA     XY0, msg_dd
                TRAP    #TRAP_PUTS
                MOVE    Y0, Y3
                LOADP   D0, Y3, [#dr_off]
                MOVE    X0, D0
                LOADD   D0, [XY0+#2]            ; hi
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
banner          .TEXT   "rgn R2.1 - Smoke C: 1-D interval subtract", 0
msg_c1          .TEXT   "1: ", 0
msg_c2          .TEXT   "2: ", 0
msg_c3          .TEXT   "3: ", 0
msg_c4          .TEXT   "4: ", 0
msg_c5          .TEXT   "5: ", 0
msg_dd          .TEXT   "..", 0
msg_sp          .TEXT   " ", 0
msg_empty       .TEXT   "(empty)", 0
msg_done        .TEXT   "done", 0
msg_nl          .TEXT   " ", 0

                .INCLUDE "../gfx_regions.asm"
