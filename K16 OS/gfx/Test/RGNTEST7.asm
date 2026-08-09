; ============================================================================
; RGNTEST7.asm -- KGFX regions: rgn_copy + empty-operand merges (console)
; ----------------------------------------------------------------------------
; Closes the last unverified paths in the region module.
;
; Part 1 -- rgn_copy (the ONLY user of [XY+D] mode-01 addressing):
;   Build a 2-band region in rA, rgn_copy rA -> rB, dump both. Must match:
;     0..80   x: 0..200
;     80..150 x: 0..100
;
; Part 2 -- empty-operand merges (the paths a window with no occluders hits):
;   A = rect(10,10,100,100), E = empty.
;     A - E  -> 10..100 x: 10..100
;     E - A  -> (empty)
;     A & E  -> (empty)
;     A | E  -> 10..100 x: 10..100
; ============================================================================
                .INCLUDE "../../kos_defs.inc"
                .INCLUDE "../gfx_regions_defs.inc"

ra_pg           .EQU    $0170
ra_of           .EQU    $0172
rb_pg           .EQU    $0174
rb_of           .EQU    $0176
rc_pg           .EQU    $0178
rc_of           .EQU    $017A
cur_pg          .EQU    $017C   ; region currently being dumped
cur_of          .EQU    $017E
db_rem          .EQU    $0180
db_off          .EQU    $0182
db_nx           .EQU    $0184
db_cof          .EQU    $0186

                .ORG    $0200
start:
                LEA     XY0, banner
                TRAP    #TRAP_PUTLN

                ; --- allocate rA, rB, rC ---
                LOADI   D0, #256
                CALLR   rgn_new
                BCS     .nomem
                MOVE    D0, Y0
                STOREP  D0, Y3, [#ra_pg]
                MOVE    D0, X0
                STOREP  D0, Y3, [#ra_of]
                LOADI   D0, #256
                CALLR   rgn_new
                BCS     .nomem
                MOVE    D0, Y0
                STOREP  D0, Y3, [#rb_pg]
                MOVE    D0, X0
                STOREP  D0, Y3, [#rb_of]
                LOADI   D0, #256
                CALLR   rgn_new
                BCS     .nomem
                MOVE    D0, Y0
                STOREP  D0, Y3, [#rc_pg]
                MOVE    D0, X0
                STOREP  D0, Y3, [#rc_of]

                ; ===== Part 1: rgn_copy =====
                ; build a 2-band region in rA
                LOADP   D0, Y3, [#ra_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#ra_of]
                MOVE    X0, D0
                ; band0: y[0,80) x[0,200)
                LOADI   D1, #0
                STORED  D1, [XY0+#RGN_BANDS+BND_YTOP]
                LOADI   D1, #80
                STORED  D1, [XY0+#RGN_BANDS+BND_YBOT]
                LOADI   D1, #2
                STORED  D1, [XY0+#RGN_BANDS+BND_NX]
                LOADI   D1, #0
                STORED  D1, [XY0+#RGN_BANDS+BND_X0]
                LOADI   D1, #200
                STORED  D1, [XY0+#RGN_BANDS+BND_X0+2]
                ; band1 @ offset 22: y[80,150) x[0,100)
                LOADI   D1, #80
                STORED  D1, [XY0+#22]
                LOADI   D1, #150
                STORED  D1, [XY0+#24]
                LOADI   D1, #2
                STORED  D1, [XY0+#26]
                LOADI   D1, #0
                STORED  D1, [XY0+#28]
                LOADI   D1, #100
                STORED  D1, [XY0+#30]
                LOADI   D1, #2
                STORED  D1, [XY0+#RGN_NBANDS]
                LOADI   D1, #0
                STORED  D1, [XY0+#RGN_TOP]
                STORED  D1, [XY0+#RGN_LEFT]
                LOADI   D1, #150
                STORED  D1, [XY0+#RGN_BOTTOM]
                LOADI   D1, #200
                STORED  D1, [XY0+#RGN_RIGHT]

                ; rgn_copy rB <- rA  (XY0=dst, XY1=src)
                LOADP   D0, Y3, [#rb_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#rb_of]
                MOVE    X0, D0
                LOADP   D0, Y3, [#ra_pg]
                MOVE    Y1, D0
                LOADP   D0, Y3, [#ra_of]
                MOVE    X1, D0
                CALLR   rgn_copy

                LEA     XY0, msg_src
                TRAP    #TRAP_PUTLN
                CALLR   cur_is_a
                CALLR   dumpBands
                LEA     XY0, msg_dst
                TRAP    #TRAP_PUTLN
                CALLR   cur_is_b
                CALLR   dumpBands

                ; ===== Part 2: empty-operand merges =====
                ; A = rect(10,10,100,100) in rA ; E = empty in rC
                LOADP   D0, Y3, [#ra_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#ra_of]
                MOVE    X0, D0
                LOADI   D0, #10
                LOADI   D1, #10
                LOADI   D2, #100
                LOADI   D3, #100
                CALLR   rgn_set_rect
                LOADP   D0, Y3, [#rc_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#rc_of]
                MOVE    X0, D0
                CALLR   rgn_set_empty

                ; A - E  (dst=rB, A=rA, B=rC)
                LEA     XY0, msg_ame
                TRAP    #TRAP_PUTLN
                CALLR   regs_AE
                CALLR   rgn_subtract
                CALLR   cur_is_b
                CALLR   dumpBands

                ; E - A  (dst=rB, A=rC, B=rA)
                LEA     XY0, msg_ema
                TRAP    #TRAP_PUTLN
                CALLR   regs_EA
                CALLR   rgn_subtract
                CALLR   cur_is_b
                CALLR   dumpBands

                ; A & E
                LEA     XY0, msg_aie
                TRAP    #TRAP_PUTLN
                CALLR   regs_AE
                CALLR   rgn_intersect
                CALLR   cur_is_b
                CALLR   dumpBands

                ; A | E
                LEA     XY0, msg_aue
                TRAP    #TRAP_PUTLN
                CALLR   regs_AE
                CALLR   rgn_union
                CALLR   cur_is_b
                CALLR   dumpBands

                LEA     XY0, msg_done
                TRAP    #TRAP_PUTLN
                TRAP    #TRAP_EXIT
.nomem:
                LEA     XY0, msg_nomem
                TRAP    #TRAP_PUTLN
                TRAP    #TRAP_EXIT

; ---- register setups for merges (dst=rB) ----
regs_AE:                                        ; XY0=rB, XY1=rA, XY2=rC
                LOADP   D0, Y3, [#rb_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#rb_of]
                MOVE    X0, D0
                LOADP   D0, Y3, [#ra_pg]
                MOVE    Y1, D0
                LOADP   D0, Y3, [#ra_of]
                MOVE    X1, D0
                LOADP   D0, Y3, [#rc_pg]
                MOVE    Y2, D0
                LOADP   D0, Y3, [#rc_of]
                MOVE    X2, D0
                RET
regs_EA:                                        ; XY0=rB, XY1=rC, XY2=rA
                LOADP   D0, Y3, [#rb_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#rb_of]
                MOVE    X0, D0
                LOADP   D0, Y3, [#rc_pg]
                MOVE    Y1, D0
                LOADP   D0, Y3, [#rc_of]
                MOVE    X1, D0
                LOADP   D0, Y3, [#ra_pg]
                MOVE    Y2, D0
                LOADP   D0, Y3, [#ra_of]
                MOVE    X2, D0
                RET

cur_is_a:
                LOADP   D0, Y3, [#ra_pg]
                STOREP  D0, Y3, [#cur_pg]
                LOADP   D0, Y3, [#ra_of]
                STOREP  D0, Y3, [#cur_of]
                RET
cur_is_b:
                LOADP   D0, Y3, [#rb_pg]
                STOREP  D0, Y3, [#cur_pg]
                LOADP   D0, Y3, [#rb_of]
                STOREP  D0, Y3, [#cur_of]
                RET

; ----------------------------------------------------------------------------
; dumpBands -- print cur region's bands "  yT..yB x: l..r ...", or "(empty)".
; ----------------------------------------------------------------------------
dumpBands:
                LOADP   D0, Y3, [#cur_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#cur_of]
                MOVE    X0, D0
                LOADD   D0, [XY0+#RGN_NBANDS]
                STOREP  D0, Y3, [#db_rem]
                CMP     D0, #0
                BNE     .db_go
                LEA     XY0, msg_empty
                TRAP    #TRAP_PUTLN
                RET
.db_go:
                LOADP   D0, Y3, [#cur_of]
                ADD     D0, #RGN_BANDS
                STOREP  D0, Y3, [#db_off]
.db_band:
                LOADP   D0, Y3, [#db_rem]
                CMP     D0, #0
                BLE     .db_done
                LEA     XY0, msg_ind
                TRAP    #TRAP_PUTS
                CALLR   db_ptr
                LOADD   D0, [XY0+#BND_YTOP]
                TRAP    #TRAP_PUTDEC
                LEA     XY0, msg_dd
                TRAP    #TRAP_PUTS
                CALLR   db_ptr
                LOADD   D0, [XY0+#BND_YBOT]
                TRAP    #TRAP_PUTDEC
                LEA     XY0, msg_xcol
                TRAP    #TRAP_PUTS
                CALLR   db_ptr
                LOADD   D0, [XY0+#BND_NX]
                STOREP  D0, Y3, [#db_nx]
                LOADP   D0, Y3, [#db_off]
                ADD     D0, #BND_X0
                STOREP  D0, Y3, [#db_cof]
.db_xloop:
                LOADP   D0, Y3, [#db_nx]
                CMP     D0, #0
                BLE     .db_xend
                LOADP   D0, Y3, [#cur_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#db_cof]
                MOVE    X0, D0
                LOADD   D0, [XY0+#0]
                TRAP    #TRAP_PUTDEC
                LEA     XY0, msg_dd
                TRAP    #TRAP_PUTS
                LOADP   D0, Y3, [#cur_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#db_cof]
                MOVE    X0, D0
                LOADD   D0, [XY0+#2]
                TRAP    #TRAP_PUTDEC
                LEA     XY0, msg_sp
                TRAP    #TRAP_PUTS
                LOADP   D0, Y3, [#db_cof]
                ADD     D0, #4
                STOREP  D0, Y3, [#db_cof]
                LOADP   D0, Y3, [#db_nx]
                SUB     D0, #2
                STOREP  D0, Y3, [#db_nx]
                BRA     .db_xloop
.db_xend:
                LEA     XY0, msg_nl
                TRAP    #TRAP_PUTLN
                CALLR   db_ptr
                LOADD   D0, [XY0+#BND_NX]
                ADD     D0, D0
                ADD     D0, #BND_HDR
                LOADP   D1, Y3, [#db_off]
                ADD     D1, D0
                STOREP  D1, Y3, [#db_off]
                LOADP   D0, Y3, [#db_rem]
                SUB     D0, #1
                STOREP  D0, Y3, [#db_rem]
                BRA     .db_band
.db_done:
                RET

db_ptr:                                         ; XY0 = cur_pg : db_off
                LOADP   D0, Y3, [#cur_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#db_off]
                MOVE    X0, D0
                RET

; ----------------------------------------------------------------------------
banner          .TEXT   "rgn: rgn_copy + empty-operand merges", 0
msg_src         .TEXT   "copy src:", 0
msg_dst         .TEXT   "copy dst:", 0
msg_ame         .TEXT   "A - E:", 0
msg_ema         .TEXT   "E - A:", 0
msg_aie         .TEXT   "A & E:", 0
msg_aue         .TEXT   "A | E:", 0
msg_ind         .TEXT   "  ", 0
msg_xcol        .TEXT   " x: ", 0
msg_dd          .TEXT   "..", 0
msg_sp          .TEXT   " ", 0
msg_empty       .TEXT   "  (empty)", 0
msg_nomem       .TEXT   "rgn: out of heap", 0
msg_done        .TEXT   "done", 0
msg_nl          .TEXT   "", 0

                .INCLUDE "../gfx_regions.asm"
