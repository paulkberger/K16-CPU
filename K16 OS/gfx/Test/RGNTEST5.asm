; ============================================================================
; RGNTEST5.asm -- KGFX regions R2.2 Smoke D: band-merge sweep (console)
; ----------------------------------------------------------------------------
; A = rect (L,T,R,B) = (0,0,100,100)     -> band y[0,100)  x[0,100)
; B = rect            = (40,40,140,140)  -> band y[40,140) x[40,140)
;
; Expected (no vertical coalescing yet, so bands are per-strip):
;   subtract A-B:
;     y0..40   x: 0..100
;     y40..100 x: 0..40
;   intersect A&B:
;     y40..100 x: 40..100
;   union A|B:
;     y0..40   x: 0..100
;     y40..100 x: 0..140
;     y100..140 x: 40..140
; ============================================================================
                .INCLUDE "../../kos_defs.inc"
                .INCLUDE "../gfx_regions_defs.inc"

ra_pg           .EQU    $0170
ra_of           .EQU    $0172
rb_pg           .EQU    $0174
rb_of           .EQU    $0176
rd_pg           .EQU    $0178
rd_of           .EQU    $017A
db_rem          .EQU    $017C   ; dumpBands: bands remaining
db_off          .EQU    $017E   ; dumpBands: current band offset
db_nx           .EQU    $0180   ; dumpBands: coords remaining in band
db_cof          .EQU    $0182   ; dumpBands: current coord offset

                .ORG    $0200
start:
                LEA     XY0, banner
                TRAP    #TRAP_PUTLN

                ; --- allocate three regions ---
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
                STOREP  D0, Y3, [#rd_pg]
                MOVE    D0, X0
                STOREP  D0, Y3, [#rd_of]

                ; --- A = rect(0,0,100,100) ---
                LOADP   D0, Y3, [#ra_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#ra_of]
                MOVE    X0, D0
                LOADI   D0, #0                  ; L
                LOADI   D1, #0                  ; T
                LOADI   D2, #100                ; R
                LOADI   D3, #100                ; B
                CALLR   rgn_set_rect

                ; --- B = rect(40,40,140,140) ---
                LOADP   D0, Y3, [#rb_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#rb_of]
                MOVE    X0, D0
                LOADI   D0, #40
                LOADI   D1, #40
                LOADI   D2, #140
                LOADI   D3, #140
                CALLR   rgn_set_rect

                ; --- subtract: dst = A - B ---
                LEA     XY0, msg_sub
                TRAP    #TRAP_PUTLN
                CALLR   setup_regs
                CALLR   rgn_subtract
                CALLR   dumpBands

                ; --- intersect: dst = A & B ---
                LEA     XY0, msg_is
                TRAP    #TRAP_PUTLN
                CALLR   setup_regs
                CALLR   rgn_intersect
                CALLR   dumpBands

                ; --- union: dst = A | B ---
                LEA     XY0, msg_un
                TRAP    #TRAP_PUTLN
                CALLR   setup_regs
                CALLR   rgn_union
                CALLR   dumpBands

                ; --- coalesce test: A=(0,0,100,200) - B=(200,50,300,150) ---
                ; B is disjoint in x, so every strip yields x[0,100); B's y-edges
                ; (50,150) split the sweep into 3 strips that must coalesce to ONE
                ; band y0..200 x0..100.
                LOADP   D0, Y3, [#ra_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#ra_of]
                MOVE    X0, D0
                LOADI   D0, #0
                LOADI   D1, #0
                LOADI   D2, #100
                LOADI   D3, #200
                CALLR   rgn_set_rect
                LOADP   D0, Y3, [#rb_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#rb_of]
                MOVE    X0, D0
                LOADI   D0, #200
                LOADI   D1, #50
                LOADI   D2, #300
                LOADI   D3, #150
                CALLR   rgn_set_rect
                LEA     XY0, msg_coal
                TRAP    #TRAP_PUTLN
                CALLR   setup_regs
                CALLR   rgn_subtract
                CALLR   dumpBands

                LEA     XY0, msg_done
                TRAP    #TRAP_PUTLN
                TRAP    #TRAP_EXIT
.nomem:
                LEA     XY0, msg_nomem
                TRAP    #TRAP_PUTLN
                TRAP    #TRAP_EXIT

; ----------------------------------------------------------------------------
; setup_regs -- load XY0=dst, XY1=A, XY2=B from the stashes.
; ----------------------------------------------------------------------------
setup_regs:
                LOADP   D0, Y3, [#rd_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#rd_of]
                MOVE    X0, D0
                LOADP   D0, Y3, [#ra_pg]
                MOVE    Y1, D0
                LOADP   D0, Y3, [#ra_of]
                MOVE    X1, D0
                LOADP   D0, Y3, [#rb_pg]
                MOVE    Y2, D0
                LOADP   D0, Y3, [#rb_of]
                MOVE    X2, D0
                RET

; ----------------------------------------------------------------------------
; dumpBands -- print dst region's bands: "  yT..yB x: l..r l..r" per band.
;   Reads dst from rd_pg/rd_of. Rebuilds pointers from offsets each print
;   (TRAPs clobber XY0/D). Uses db_* scratch.
; ----------------------------------------------------------------------------
dumpBands:
                LOADP   D0, Y3, [#rd_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#rd_of]
                MOVE    X0, D0
                LOADD   D0, [XY0+#RGN_NBANDS]
                STOREP  D0, Y3, [#db_rem]
                CMP     D0, #0
                BNE     .db_go
                LEA     XY0, msg_empty
                TRAP    #TRAP_PUTLN
                RET
.db_go:
                ; first band offset = base_of + RGN_BANDS
                LOADP   D0, Y3, [#rd_of]
                ADD     D0, #RGN_BANDS
                STOREP  D0, Y3, [#db_off]
.db_band:
                LOADP   D0, Y3, [#db_rem]
                CMP     D0, #0
                BLE     .db_done
                ; print "  " + ytop
                LEA     XY0, msg_ind
                TRAP    #TRAP_PUTS
                CALLR   db_ptr                  ; XY0 -> band
                LOADD   D0, [XY0+#BND_YTOP]
                TRAP    #TRAP_PUTDEC
                LEA     XY0, msg_dd
                TRAP    #TRAP_PUTS
                CALLR   db_ptr
                LOADD   D0, [XY0+#BND_YBOT]
                TRAP    #TRAP_PUTDEC
                LEA     XY0, msg_xcol
                TRAP    #TRAP_PUTS
                ; intervals
                CALLR   db_ptr
                LOADD   D0, [XY0+#BND_NX]
                STOREP  D0, Y3, [#db_nx]
                LOADP   D0, Y3, [#db_off]
                ADD     D0, #BND_X0
                STOREP  D0, Y3, [#db_cof]       ; coord offset cursor
.db_xloop:
                LOADP   D0, Y3, [#db_nx]
                CMP     D0, #0
                BLE     .db_xend
                LOADP   D0, Y3, [#rd_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#db_cof]
                MOVE    X0, D0
                LOADD   D0, [XY0+#0]            ; l
                TRAP    #TRAP_PUTDEC
                LEA     XY0, msg_dd
                TRAP    #TRAP_PUTS
                LOADP   D0, Y3, [#rd_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#db_cof]
                MOVE    X0, D0
                LOADD   D0, [XY0+#2]            ; r
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
                ; advance to next band: db_off += BND_HDR + nx*2
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

; db_ptr -- XY0 = dst_page : db_off
db_ptr:
                LOADP   D0, Y3, [#rd_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#db_off]
                MOVE    X0, D0
                RET

; ----------------------------------------------------------------------------
banner          .TEXT   "rgn R2.2 - Smoke D: merge A(0,0,100,100) B(40,40,140,140)", 0
msg_sub         .TEXT   "subtract A-B:", 0
msg_is          .TEXT   "intersect A&B:", 0
msg_un          .TEXT   "union A|B:", 0
msg_coal        .TEXT   "subtract (coalesce: B disjoint in x):", 0
msg_ind         .TEXT   "  ", 0
msg_xcol        .TEXT   " x: ", 0
msg_dd          .TEXT   "..", 0
msg_sp          .TEXT   " ", 0
msg_empty       .TEXT   "  (empty)", 0
msg_nomem       .TEXT   "rgn: out of heap", 0
msg_done        .TEXT   "done", 0
msg_nl          .TEXT   "", 0

                .INCLUDE "../gfx_regions.asm"
