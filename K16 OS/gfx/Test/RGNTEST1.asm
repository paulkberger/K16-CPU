; ============================================================================
; RGNTEST1.asm -- KGFX regions R1 Smoke A
; ----------------------------------------------------------------------------
; 1. rgn_new(256) -> region on the heap.
; 2. rgn_set_rect(10,20,100,60); dump nbands (expect 1).
; 3. Hand-build a 2-band L-shape directly (no algebra yet):
;       band0: y[0,80)  x[0,200)
;       band1: y[80,150) x[0,100)
; 4. rgn_band_at for y = 40, 100, 200 -> expect band0, band1, none.
; 5. rgn_pt_in for (50,40)in (150,100)out (50,100)in (250,40)out.
; 6. rgn_dispose; exit.
;
; Region ptr is stashed in rg_pg/rg_of because the print TRAPs clobber XY0.
; ============================================================================
                .INCLUDE "../../kos_defs.inc"
                .INCLUDE "../gfx_regions_defs.inc"
                .ORG    $0200
start:
                LEA     XY0, banner
                TRAP    #TRAP_PUTLN

                ; --- rgn_new(256) ---
                LOADI   D0, #256
                CALLR   rgn_new
                BCC     .got
                LEA     XY0, msg_nomem
                TRAP    #TRAP_PUTLN
                TRAP    #TRAP_EXIT
.got:
                CALLR   rgnt_save               ; stash XY0 -> rg_pg/rg_of

                ; --- rgn_set_rect(L=10,T=20,R=100,B=60) ---
                CALLR   rgnt_reload
                LOADI   D0, #10
                LOADI   D1, #20
                LOADI   D2, #100
                LOADI   D3, #60
                CALLR   rgn_set_rect

                LEA     XY0, msg_rect
                TRAP    #TRAP_PUTS
                CALLR   rgnt_reload
                LOADD   D0, [XY0+#RGN_NBANDS]
                TRAP    #TRAP_PUTDEC            ; expect 1
                CALLR   rgnt_nl

                ; --- hand-build the 2-band L-shape ---
                CALLR   rgnt_reload
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
                ; band1 at offset 22 = RGN_BANDS(12) + BND_HDR(6) + 2*2
                LOADI   D1, #80
                STORED  D1, [XY0+#22]           ; band1 ytop
                LOADI   D1, #150
                STORED  D1, [XY0+#24]           ; band1 ybot
                LOADI   D1, #2
                STORED  D1, [XY0+#26]           ; band1 nx
                LOADI   D1, #0
                STORED  D1, [XY0+#28]           ; band1 xL
                LOADI   D1, #100
                STORED  D1, [XY0+#30]           ; band1 xR
                ; nbands = 2
                LOADI   D1, #2
                STORED  D1, [XY0+#RGN_NBANDS]

                ; --- band_at queries ---
                LEA     XY0, msg_band
                TRAP    #TRAP_PUTLN

                LOADI   D0, #40
                CALLR   rgnt_band_report        ; expect found, xL=0 xR=200
                LOADI   D0, #100
                CALLR   rgnt_band_report        ; expect found, xL=0 xR=100
                LOADI   D0, #200
                CALLR   rgnt_band_report        ; expect none

                ; --- pt_in queries ---
                LEA     XY0, msg_pt
                TRAP    #TRAP_PUTLN

                LOADI   D0, #50
                LOADI   D1, #40
                CALLR   rgnt_pt_report          ; in
                LOADI   D0, #150
                LOADI   D1, #100
                CALLR   rgnt_pt_report          ; out
                LOADI   D0, #50
                LOADI   D1, #100
                CALLR   rgnt_pt_report          ; in
                LOADI   D0, #250
                LOADI   D1, #40
                CALLR   rgnt_pt_report          ; out

                ; --- dispose + exit ---
                CALLR   rgnt_reload
                CALLR   rgn_dispose
                LEA     XY0, msg_done
                TRAP    #TRAP_PUTLN
                TRAP    #TRAP_EXIT

; ----------------------------------------------------------------------------
; rgnt_band_report -- call rgn_band_at(D0=y), print y + result + interval.
;   Clobbers D0-D3, XY0, XY1.
; ----------------------------------------------------------------------------
rgnt_band_report:
                PUSH    D0, XY3                 ; save y for printing
                LEA     XY0, msg_y
                TRAP    #TRAP_PUTS
                POP     D0, XY3
                PUSH    D0, XY3
                TRAP    #TRAP_PUTDEC            ; y
                LEA     XY0, msg_arrow
                TRAP    #TRAP_PUTS
                CALLR   rgnt_reload
                POP     D0, XY3                 ; y back into D0
                CALLR   rgn_band_at
                BCC     .br_found
                LEA     XY0, msg_none
                TRAP    #TRAP_PUTLN
                RET
.br_found:
                ; XY1 = band; print xL, xR
                LOADD   D0, [XY1+#BND_X0]
                TRAP    #TRAP_PUTDEC
                LEA     XY0, msg_dotdot
                TRAP    #TRAP_PUTS
                ; reload band ptr is gone (XY0 clobbered by puts) -> recompute
                ; not needed: we already have xR offset; but XY1 survives puts?
                ; puts clobbers XY0 only -> XY1 intact.
                LOADD   D0, [XY1+#BND_X0+2]
                TRAP    #TRAP_PUTDEC
                CALLR   rgnt_nl
                RET

; ----------------------------------------------------------------------------
; rgnt_pt_report -- call rgn_pt_in(D0=x,D1=y), print "(x,y) in/out".
;   Clobbers D0-D3, XY0, XY1.
; ----------------------------------------------------------------------------
rgnt_pt_report:
                PUSH    D0, XY3                 ; x
                PUSH    D1, XY3                 ; y
                LEA     XY0, msg_lp
                TRAP    #TRAP_PUTS
                POP     D1, XY3
                POP     D0, XY3
                PUSH    D0, XY3
                PUSH    D1, XY3
                TRAP    #TRAP_PUTDEC            ; x
                LEA     XY0, msg_comma
                TRAP    #TRAP_PUTS
                POP     D1, XY3
                PUSH    D1, XY3
                MOVE    D0, D1
                TRAP    #TRAP_PUTDEC            ; y
                LEA     XY0, msg_rp
                TRAP    #TRAP_PUTS
                CALLR   rgnt_reload
                POP     D1, XY3                 ; y
                POP     D0, XY3                 ; x
                CALLR   rgn_pt_in
                BCC     .pr_in
                LEA     XY0, msg_out
                TRAP    #TRAP_PUTLN
                RET
.pr_in:
                LEA     XY0, msg_in
                TRAP    #TRAP_PUTLN
                RET

; ----------------------------------------------------------------------------
; rgnt_save / rgnt_reload -- stash/restore region ptr (XY0) across prints.
; ----------------------------------------------------------------------------
rgnt_save:
                MOVE    D0, Y0
                STOREP  D0, Y3, [#rg_pg]
                MOVE    D0, X0
                STOREP  D0, Y3, [#rg_of]
                RET
rgnt_reload:
                LOADP   D0, Y3, [#rg_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#rg_of]
                MOVE    X0, D0
                RET
rgnt_nl:
                LEA     XY0, msg_nl
                TRAP    #TRAP_PUTS
                RET

; ----------------------------------------------------------------------------
banner          .TEXT   "rgn R1 - Smoke A: alloc / rect / band_at / pt_in", 0
msg_nomem       .TEXT   "rgn: out of heap", 0
msg_rect        .TEXT   "set_rect nbands=", 0
msg_band        .TEXT   "band_at:", 0
msg_pt          .TEXT   "pt_in:", 0
msg_y           .TEXT   "  y=", 0
msg_arrow       .TEXT   " -> ", 0
msg_none        .TEXT   "none", 0
msg_dotdot      .TEXT   "..", 0
msg_lp          .TEXT   "  (", 0
msg_comma       .TEXT   ",", 0
msg_rp          .TEXT   ") ", 0
msg_in          .TEXT   "in", 0
msg_out         .TEXT   "out", 0
msg_done        .TEXT   "done", 0
msg_nl          .TEXT   "", 0

                .INCLUDE "../gfx_regions.asm"
