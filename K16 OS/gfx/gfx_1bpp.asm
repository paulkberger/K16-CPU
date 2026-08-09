; ============================================================================
; gfx_1bpp.asm  --  K16 graphics: 1bpp (mode 1) depth back end.
; ----------------------------------------------------------------------------
; Per-depth poke routines reached via the GS_VSPAN/VCLEAR/VTEXT/VPAT/VBLIT
; method vectors that gfx_open points at these labels. Self-contained: these
; call only their own 1bpp helpers (gfx_byte1/gfx_rmw1/gfx_rmwp/gfx_blitop).
; Include AFTER gfx.asm (front end), alongside gfx_8bpp.asm. Requires
; gfx_defs.inc. Split out of gfx.asm (pure relocation, no logic change).
; ============================================================================


; ==========================================================================
; vspan_1 -- 1bpp horizontal run, MSB-first (poke method)
;   In:  XY1=desc, D0=x, D1=y, D2=count, D3=idx (in-bounds assumed)
;   Per-pixel RMW (correctness-first; whole-byte middle-fill is a future
;   optimisation inside this poke -- geometry unaffected).
;   Clobbers D0-D3,X0,Y0; gs_*/gv_*. Preserves XY1.
; ==========================================================================
; Fast version: start address computed once, then leading-partial byte ->
; solid $FF/$00 middle bytes -> trailing-partial byte. Whole-byte middle
; means a 640-wide row is ~80 byte-stores, not 640 RMWs.
vspan_1:
                STOREP  D0, Y3, [#gs_x]
                STOREP  D1, Y3, [#gs_y]
                STOREP  D2, Y3, [#gv_cnt]       ; remaining
                AND     D3, #1
                STOREP  D3, Y3, [#gv_idx]       ; value 0/1
                LOADD   D0, [XY1+#0]            ; FB_PAGE
                STOREP  D0, Y3, [#gs_fbpage]
                CALLR   gfx_byte1               ; XY0 = start byte addr

                ; --- leading partial byte ---
                LOADP   D0, Y3, [#gs_x]
                AND     D0, #7                  ; first_bit
                LOADI   D1, #8
                SUB     D1, D0                  ; avail = 8 - first_bit
                LOADP   D2, Y3, [#gv_cnt]
                CMP     D1, D2
                BLE     .v1_navail
                MOVE    D1, D2                  ; n_lead = min(avail, remaining)
.v1_navail:
                STOREP  D1, Y3, [#gv_nlead]
                ; mask = ($FF >> first_bit) with low (avail - n_lead) bits cleared
                LOADI   D2, #$FF
                MOVE    D3, D0                  ; first_bit
.v1_shr1:
                CMP     D3, #0
                BEQ     .v1_shr1d
                SHR     D2
                DEC     D3
                BRA     .v1_shr1
.v1_shr1d:
                LOADI   D3, #8
                SUB     D3, D0                  ; avail
                LOADP   D1, Y3, [#gv_nlead]
                SUB     D3, D1                  ; low_clear = avail - n_lead
                MOVE    D1, D3
.v1_shr2:
                CMP     D1, #0
                BEQ     .v1_shr2d
                SHR     D2
                DEC     D1
                BRA     .v1_shr2
.v1_shr2d:
                MOVE    D1, D3
.v1_shl2:
                CMP     D1, #0
                BEQ     .v1_shl2d
                ADD     D2, D2                  ; << 1
                DEC     D1
                BRA     .v1_shl2
.v1_shl2d:
                CALLR   gfx_rmw1                ; apply mask D2 at [XY0]
                ADD     X0, #1
                BCC     .v1_lnc
                ADD     Y0, #1
.v1_lnc:
                LOADP   D0, Y3, [#gv_cnt]
                LOADP   D1, Y3, [#gv_nlead]
                SUB     D0, D1
                STOREP  D0, Y3, [#gv_cnt]       ; remaining -= n_lead

                ; --- middle whole bytes ($FF or $00), word-blast via [XY0]+ ---
                LOADP   D3, Y3, [#gv_idx]
                CMP     D3, #0
                BEQ     .v1_mz
                LOADI   D3, #$FF
                BRA     .v1_mcnt
.v1_mz:
                LOADI   D3, #$00
.v1_mcnt:
                LOADP   D0, Y3, [#gv_cnt]       ; remaining bits
                MOVE    D1, D0
                SHR     D1
                SHR     D1
                SHR     D1                      ; D1 = whole bytes = cnt >> 3
                AND     D0, #7                  ; remainder bits
                STOREP  D0, Y3, [#gv_cnt]       ; gv_cnt = trailing bits
                CMP     D1, #0
                BEQ     .v1_mdone
                MOVE    D2, D3                  ; build idx:idx word
                SWAPB   D2
                OR      D2, D3                  ; D2 = fill:fill
                ; leading byte to even-align XY0 for word stores (if odd)
                MOVE    D0, X0
                AND     D0, #1
                CMP     D0, #0
                BEQ     .v1_meven
                STOREB  D3, [XY0]+              ; align byte
                DEC     D1
                BEQ     .v1_mdone               ; that was the only whole byte
.v1_meven:
                MOVE    D0, D1
                AND     D0, #1                  ; leftover whole byte (survives loop)
                SHR     D1                      ; word count
                CMP     D1, #0
                BEQ     .v1_mtail
.v1_mwloop:
                STORED  D2, [XY0]+              ; 2 bytes, even-aligned, +2 (24-bit)
                DEC     D1
                BNE     .v1_mwloop
.v1_mtail:
                CMP     D0, #0
                BEQ     .v1_mdone
                STOREB  D3, [XY0]+              ; trailing whole byte
.v1_mdone:
                ; --- trailing partial byte ---
                LOADP   D0, Y3, [#gv_cnt]
                CMP     D0, #0
                BEQ     .v1_done
                LOADI   D1, #8
                SUB     D1, D0                  ; 8 - remaining
                LOADI   D2, #$FF
.v1_tshl:
                CMP     D1, #0
                BEQ     .v1_tshld
                ADD     D2, D2                  ; << 1
                DEC     D1
                BRA     .v1_tshl
.v1_tshld:
                AND     D2, #$FF                ; top `remaining` bits
                CALLR   gfx_rmw1
.v1_done:
                RET


; gfx_rmw1 -- read-modify-write masked bits at [XY0] with value gv_idx
;   In: D2 = mask, gv_idx = 0/1, XY0 = byte addr.  Preserves XY0,D2.
;   Clobbers D0,D1.
gfx_rmw1:
                LOADB   D0, [XY0]
                LOADP   D1, Y3, [#gv_idx]
                CMP     D1, #0
                BEQ     .rmw_clr
                OR      D0, D2                  ; set masked bits
                BRA     .rmw_st
.rmw_clr:
                MOVE    D1, D2
                NOT     D1                      ; ~mask
                AND     D0, D1                  ; clear masked bits
.rmw_st:
                STOREB  D0, [XY0]
                RET


; gfx_rmwp -- pattern RMW: dest = (dest & ~mask) | (gp_patrow & mask)
;   In: D2 = mask, gp_patrow = pattern byte, XY0 = byte addr.
;   Preserves XY0,D2.  Clobbers D0,D1.
gfx_rmwp:
                LOADB   D0, [XY0]
                MOVE    D1, D2
                NOT     D1                      ; ~mask
                AND     D0, D1                  ; dest & ~mask
                LOADP   D1, Y3, [#gp_patrow]
                AND     D1, D2                  ; patrow & mask
                OR      D0, D1
                STOREB  D0, [XY0]
                RET


; gfx_byte1 -- 1bpp byte address for (gs_x,gs_y) (no mask)
;   addr = fbpage:0 + y*160 + (x>>3); y*160 = (y<<7)+(y<<5)
;   Out: XY0 = byte addr. Clobbers D0,D1,D2,X0,Y0.
gfx_byte1:
                ; --- y*160 via MULB:  160*y_lo + (160*y_hi << 8) ---
                LOADP   D0, Y3, [#gs_y]
                MOVE    D1, D0
                HIGH    D1                      ; D1 = y_hi
                LOW     D0                      ; D0 = y_lo
                LOADI   D2, #160
                SWAPB   D2                      ; 160 into high byte
                OR      D0, D2
                MULB    D0                      ; D0 = 160 * y_lo  (P0)
                LOADI   D2, #160
                SWAPB   D2
                OR      D1, D2
                MULB    D1                      ; D1 = 160 * y_hi  (P1)
                MOVE    D2, D1                  ; y*160 = P0 + (P1 << 8)
                LOW     D2
                SWAPB   D2                      ; (P1 low byte) << 8
                HIGH    D1                      ; D1 = P1 high byte
                ADD     D0, D2
                ADC     D1, #0                  ; D1:D0 = y*160
                LOADP   D2, Y3, [#gs_x]
                SHR     D2
                SHR     D2
                SHR     D2                      ; x>>3
                ADD     D0, D2
                ADC     D1, #0
                LOADP   D2, Y3, [#gs_fbpage]
                ADD     D1, D2
                MOVE    X0, D0
                MOVE    Y0, D1                  ; XY0 = byte addr
                RET


; ==========================================================================
; vclear_1 -- fast 1bpp whole-surface fill ($1C200 = 720*160), word-blast
;   In: XY1=desc, D0=idx (bit 0).  Uses XY2 as end-marker; XY1 preserved.
;   Clobbers D0,D1,D2,X0,Y0,X2,Y2.
; ==========================================================================
vclear_1:
                AND     D0, #1
                BEQ     .c1_zero
                LOADI   D0, #$FFFF              ; all bits set
                BRA     .c1_go
.c1_zero:
                LOADI   D0, #$0000
.c1_go:
                LOADD   D1, [XY1+#0]            ; FB_PAGE
                MOVE    Y0, D1
                LOADI   X0, #$0000
                MOVE    Y2, D1
                ADD     Y2, #1
                LOADI   X2, #$C200              ; end (page+1):C200  ($1C200)
                ; 16-word blast; [XY0]+ default stride 2, 24-bit carry in HW
.c1_loop:
                STORED  D0, [XY0]+
                STORED  D0, [XY0]+
                STORED  D0, [XY0]+
                STORED  D0, [XY0]+
                STORED  D0, [XY0]+
                STORED  D0, [XY0]+
                STORED  D0, [XY0]+
                STORED  D0, [XY0]+
                STORED  D0, [XY0]+
                STORED  D0, [XY0]+
                STORED  D0, [XY0]+
                STORED  D0, [XY0]+
                STORED  D0, [XY0]+
                STORED  D0, [XY0]+
                STORED  D0, [XY0]+
                STORED  D0, [XY0]+
                CMP     Y0, Y2
                BLO     .c1_loop
                CMP     X0, X2
                BLO     .c1_loop
                RET


; ==========================================================================
; vtext_1 -- 1bpp glyph-row poke (F3). The glyph rowbits ARE framebuffer bits
;   (both MSB-first), so the row lands in <=2 bytes via a shift + RMW: shift
;   rowbits right by s=(x&7) into byte0, the spill (rowbits << (8-s)) into
;   byte1. fg=1 sets, fg=0 clears (inverse text), reusing gfx_rmw1. Out-of-
;   bounds columns are already zeroed by _fn_rowmask, so the spill byte (which
;   may be the first byte of the next row at the right edge) writes nothing.
;   In:  XY1=desc, D0=x (>=0), D1=y, D2=rowbits (MSB=col0, masked), D3=fg(0/1).
;   Preserves XY1.  Clobbers D0-D3,X0,Y0; gs_*/gv_*.
; ==========================================================================
vtext_1:
                MOVE    Y0, Y2                   ; XY0 = leftmost FB byte (caller's XY2)
                MOVE    X0, X2
                AND     D3, #1
                STOREP  D3, Y3, [#gv_idx]       ; fg bit (0/1) for gfx_rmw1
                LOADP   D3, Y3, [#fn_wide]       ; F4-wide: 16-bit (word/row) path?
                CMP     D3, #0
                BNE     .vt1_wide
                MOVE    D3, D2                   ; rowbits -> D3
                AND     D3, #$FF
                LOADP   D0, Y3, [#gs_x]          ; gs_x = fn_dx (preset by _fn_blit)
                AND     D0, #7                   ; s = x & 7
                CMP     D0, #0
                BNE     .vt1_shift
                ; --- s == 0: byte-aligned; byte0 = rowbits, no spill byte ---
                MOVE    D2, D3
                CALLR   gfx_rmw1
                RET
.vt1_shift:
                ; --- s > 0: place rowbits at bit-offset s via one MULB ---
                ;   V = rowbits << (8-s) = rowbits * (1<<(8-s)) = MULB(rowbits, fn_mult)
                ;   byte0 = HIGH(V) = rowbits >> s ; byte1 = LOW(V) = rowbits << (8-s)
                MOVE    D2, D3                   ; rowbits (low byte)
                LOADP   D0, Y3, [#fn_mult]       ; 1<<(8-s) in high byte (per-glyph)
                OR      D2, D0
                MULB    D2                       ; D2 = V (16-bit placed value)
                MOVE    D3, D2                   ; save V (gfx_rmw1 preserves D3)
                HIGH    D2                       ; byte0 mask = HIGH(V)
                CALLR   gfx_rmw1                 ; RMW byte0 (preserves XY0,D2,D3)
                ADD     X0, #1                   ; advance to byte1
                BCC     .vt1_nc                  ; C=1 = page wrap
                ADD     Y0, #1
.vt1_nc:
                MOVE    D2, D3                   ; V
                LOW     D2                       ; byte1 mask = LOW(V)
                CALLR   gfx_rmw1                 ; RMW byte1
                RET

; --- vtext_1 wide (>8px, 16-bit rowbits, bit15=col0): row spans <=3 bytes ---
;   s==0 -> byte0=rh @XY0, byte1=rl @+1.  s>0 -> 3-byte MULB placement:
;     Vh=MULB(rh,mult); Vl=MULB(rl,mult);
;     byte0=HIGH(Vh); byte1=LOW(Vh)|HIGH(Vl); byte2=LOW(Vl).
;   Reuses fn_mult + gfx_rmw1 (preserves XY0,D2,D3). fn_vh holds Vh; Vl in D3.
.vt1_wide:
                LOADP   D0, Y3, [#gs_x]          ; s = x & 7
                AND     D0, #7
                CMP     D0, #0
                BNE     .vt1_wsh
                ; --- s == 0: byte0 = rh, byte1 = rl ---
                MOVE    D3, D2                   ; save rowbits
                HIGH    D2                       ; rh (cols 0-7)
                CALLR   gfx_rmw1
                ADD     X0, #1
                BCC     .vt1_w0nc
                ADD     Y0, #1
.vt1_w0nc:
                MOVE    D2, D3
                LOW     D2                       ; rl (cols 8-15)
                CALLR   gfx_rmw1
                RET
.vt1_wsh:
                LOADP   D0, Y3, [#fn_mult]       ; 1<<(8-s) in high byte
                MOVE    D1, D2                   ; Vh = MULB(rh, mult)
                HIGH    D1                       ; rh
                OR      D1, D0
                MULB    D1
                STOREP  D1, Y3, [#fn_vh]         ; hold Vh across RMWs
                MOVE    D3, D2                   ; Vl = MULB(rl, mult) -> D3 (preserved)
                LOW     D3                       ; rl
                OR      D3, D0
                MULB    D3
                LOADP   D2, Y3, [#fn_vh]         ; byte0 = HIGH(Vh)
                HIGH    D2
                CALLR   gfx_rmw1
                ADD     X0, #1
                BCC     .vt1_w1
                ADD     Y0, #1
.vt1_w1:
                LOADP   D2, Y3, [#fn_vh]         ; byte1 = LOW(Vh) | HIGH(Vl)
                LOW     D2
                MOVE    D0, D3
                HIGH    D0                       ; HIGH(Vl)
                OR      D2, D0
                CALLR   gfx_rmw1
                ADD     X0, #1
                BCC     .vt1_w2
                ADD     Y0, #1
.vt1_w2:
                MOVE    D2, D3                   ; byte2 = LOW(Vl)
                LOW     D2
                CALLR   gfx_rmw1
                RET


; ==========================================================================
; vpat_1 -- 1bpp patterned run. Screen-aligned 8x8 pattern: every whole frame-
;   buffer byte == patrow (gp_patrow = pattern[y&7]); only the leading/trailing
;   partial bytes need a masked pattern RMW (gfx_rmwp). Same structure as
;   vspan_1 with the solid $FF/$00 middle replaced by patrow.
;   In: XY1=desc, D0=x, D1=y, D2=count, D3=patrow.  Preserves XY1.
;   Clobbers D0-D3,X0,Y0; gs_*/gv_*/gp_patrow.
; ==========================================================================
vpat_1:
                STOREP  D0, Y3, [#gs_x]
                STOREP  D1, Y3, [#gs_y]
                STOREP  D2, Y3, [#gv_cnt]
                AND     D3, #$FF
                STOREP  D3, Y3, [#gp_patrow]
                LOADD   D0, [XY1+#0]            ; FB_PAGE
                STOREP  D0, Y3, [#gs_fbpage]
                CALLR   gfx_byte1               ; XY0 = start byte addr
                ; --- leading partial byte ---
                LOADP   D0, Y3, [#gs_x]
                AND     D0, #7                  ; first_bit
                LOADI   D1, #8
                SUB     D1, D0                  ; avail = 8 - first_bit
                LOADP   D2, Y3, [#gv_cnt]
                CMP     D1, D2
                BLE     .vp1_navail
                MOVE    D1, D2                  ; n_lead = min(avail, remaining)
.vp1_navail:
                STOREP  D1, Y3, [#gv_nlead]
                LOADI   D2, #$FF
                MOVE    D3, D0                  ; first_bit
.vp1_shr1:
                CMP     D3, #0
                BEQ     .vp1_shr1d
                SHR     D2
                DEC     D3
                BRA     .vp1_shr1
.vp1_shr1d:
                LOADI   D3, #8
                SUB     D3, D0                  ; avail
                LOADP   D1, Y3, [#gv_nlead]
                SUB     D3, D1                  ; low_clear = avail - n_lead
                MOVE    D1, D3
.vp1_shr2:
                CMP     D1, #0
                BEQ     .vp1_shr2d
                SHR     D2
                DEC     D1
                BRA     .vp1_shr2
.vp1_shr2d:
                MOVE    D1, D3
.vp1_shl2:
                CMP     D1, #0
                BEQ     .vp1_shl2d
                ADD     D2, D2                  ; << 1
                DEC     D1
                BRA     .vp1_shl2
.vp1_shl2d:
                CALLR   gfx_rmwp                ; pattern bits into masked cols
                ADD     X0, #1
                BCC     .vp1_lnc
                ADD     Y0, #1
.vp1_lnc:
                LOADP   D0, Y3, [#gv_cnt]
                LOADP   D1, Y3, [#gv_nlead]
                SUB     D0, D1
                STOREP  D0, Y3, [#gv_cnt]       ; remaining -= n_lead
                ; --- middle whole bytes = patrow, word-blast via [XY0]+ ---
                LOADP   D3, Y3, [#gp_patrow]
                LOADP   D0, Y3, [#gv_cnt]       ; remaining bits
                MOVE    D1, D0
                SHR     D1
                SHR     D1
                SHR     D1                      ; D1 = whole bytes = cnt >> 3
                AND     D0, #7                  ; remainder bits
                STOREP  D0, Y3, [#gv_cnt]       ; gv_cnt = trailing bits
                CMP     D1, #0
                BEQ     .vp1_mdone
                MOVE    D2, D3                  ; build patrow:patrow word
                SWAPB   D2
                OR      D2, D3                  ; D2 = patrow:patrow
                ; leading byte to even-align XY0 for word stores (if odd)
                MOVE    D0, X0
                AND     D0, #1
                CMP     D0, #0
                BEQ     .vp1_meven
                STOREB  D3, [XY0]+              ; align byte
                DEC     D1
                BEQ     .vp1_mdone              ; that was the only whole byte
.vp1_meven:
                MOVE    D0, D1
                AND     D0, #1                  ; leftover whole byte (survives loop)
                SHR     D1                      ; word count
                CMP     D1, #0
                BEQ     .vp1_mtail
.vp1_mwloop:
                STORED  D2, [XY0]+              ; 2 bytes, even-aligned, +2 (24-bit)
                DEC     D1
                BNE     .vp1_mwloop
.vp1_mtail:
                CMP     D0, #0
                BEQ     .vp1_mdone
                STOREB  D3, [XY0]+              ; trailing whole byte
.vp1_mdone:
                ; --- trailing partial byte ---
                LOADP   D0, Y3, [#gv_cnt]
                CMP     D0, #0
                BEQ     .vp1_done
                LOADI   D1, #8
                SUB     D1, D0                  ; 8 - remaining
                LOADI   D2, #$FF
.vp1_tshl:
                CMP     D1, #0
                BEQ     .vp1_tshld
                ADD     D2, D2                  ; << 1
                DEC     D1
                BRA     .vp1_tshl
.vp1_tshld:
                AND     D2, #$FF                ; top `remaining` bits
                CALLR   gfx_rmwp
.vp1_done:
                RET


; ==========================================================================
; gfx_blitop -- apply one aligned source-bit group to a dest byte (1bpp).
;   In: XY0 = dest byte; D2 = source-set bits (aligned to this byte);
;       gb_cover = covered-columns mask (aligned); gb_mode/gb_fg/gb_bg.
;   Or:  fg? dest|=src : dest&=~src.   Xor: dest^=src.
;   Copy: V=(fg?src:0)|(bg?(cover&~src):0); dest=(dest&~cover)|V.
;   Preserves XY0,D2.  Clobbers D0,D1,D3; gv_idx (temp).
; ==========================================================================
gfx_blitop:
                LOADP   D3, Y3, [#gb_mode]
                CMP     D3, #1
                BEQ     .bop_copy
                CMP     D3, #2
                BEQ     .bop_xor
                ; --- Or (transparent) ---
                LOADP   D3, Y3, [#gb_fg]
                CMP     D3, #0
                BEQ     .bop_orclr
                LOADB   D0, [XY0]
                OR      D0, D2
                STOREB  D0, [XY0]
                RET
.bop_orclr:
                LOADB   D0, [XY0]
                MOVE    D1, D2
                NOT     D1
                AND     D0, D1                   ; clear src-set bits
                STOREB  D0, [XY0]
                RET
.bop_xor:
                LOADB   D0, [XY0]
                XOR     D0, D2
                STOREB  D0, [XY0]
                RET
.bop_copy:
                LOADI   D0, #0                   ; V
                LOADP   D3, Y3, [#gb_fg]
                CMP     D3, #0
                BEQ     .bop_cfg0
                OR      D0, D2                   ; V |= src   (fg pixels)
.bop_cfg0:
                LOADP   D3, Y3, [#gb_bg]
                CMP     D3, #0
                BEQ     .bop_cbg0
                LOADP   D1, Y3, [#gb_cover]
                MOVE    D3, D2
                NOT     D3                       ; ~src
                AND     D1, D3                   ; cover & ~src = src-clear cols
                OR      D0, D1                   ; V |= bg pixels
.bop_cbg0:
                STOREP  D0, Y3, [#gv_idx]        ; stash V
                LOADB   D0, [XY0]
                LOADP   D1, Y3, [#gb_cover]
                NOT     D1                       ; ~cover
                AND     D0, D1                   ; dest & ~cover
                LOADP   D1, Y3, [#gv_idx]
                OR      D0, D1                   ; | V
                STOREB  D0, [XY0]
                RET


; ==========================================================================
; vblit_1 -- 1bpp-dest row of a 1bpp mask. Source byte i (8 cols) lands in two
;   dest bytes at constant shift s=(x&7): byte0 = bits>>s, byte1 = bits<<(8-s).
;   Walks source bytes, advancing one dest byte per source byte (boundary
;   double-touch is harmless: complementary cover masks). gfx_blitop applies
;   the mode. In: XY1=desc, D0=x, D1=py, D2=visw; src row in gb_row_*.
;   Preserves XY1.  Clobbers D0-D3,X0,Y0,X2,Y2; gs_*/gv_*/gb_*.
; ==========================================================================
vblit_1:
                STOREP  D0, Y3, [#gs_x]
                STOREP  D1, Y3, [#gs_y]
                STOREP  D2, Y3, [#gv_cnt]        ; remaining columns
                LOADD   D0, [XY1+#0]
                STOREP  D0, Y3, [#gs_fbpage]
                LOADP   D0, Y3, [#gs_x]
                AND     D0, #7
                STOREP  D0, Y3, [#gb_s]
                CALLR   gfx_byte1                ; XY0 = dest byte0
                LOADP   D0, Y3, [#gb_row_pg]     ; XY2 = source row
                MOVE    Y2, D0
                LOADP   D0, Y3, [#gb_row_of]
                MOVE    X2, D0
.bl1_loop:
                LOADP   D0, Y3, [#gv_cnt]
                CMP     D0, #0
                BLE     .bl1_done
                ; nbits = min(8, remaining) ; coverf = top nbits bits
                LOADI   D1, #8
                CMP     D0, D1
                BGE     .bl1_n8
                MOVE    D1, D0
.bl1_n8:
                LOADI   D2, #$FF
                LOADI   D3, #8
                SUB     D3, D1                   ; 8 - nbits
.bl1_csh:
                CMP     D3, #0
                BEQ     .bl1_cshd
                ADD     D2, D2                   ; << 1
                DEC     D3
                BRA     .bl1_csh
.bl1_cshd:
                AND     D2, #$FF
                STOREP  D2, Y3, [#gb_coverf]
                LOADB   D0, [XY2]+               ; source byte (post-inc)
                AND     D0, D2                   ; & cover -> sb
                STOREP  D0, Y3, [#gb_opv]
                ; --- byte0: cover0 = coverf>>s, src0 = sb>>s ---
                LOADP   D2, Y3, [#gb_coverf]
                LOADP   D3, Y3, [#gb_s]
.bl1_c0:
                CMP     D3, #0
                BEQ     .bl1_c0d
                SHR     D2
                DEC     D3
                BRA     .bl1_c0
.bl1_c0d:
                STOREP  D2, Y3, [#gb_cover]
                LOADP   D2, Y3, [#gb_opv]
                LOADP   D3, Y3, [#gb_s]
.bl1_s0:
                CMP     D3, #0
                BEQ     .bl1_s0d
                SHR     D2
                DEC     D3
                BRA     .bl1_s0
.bl1_s0d:
                CALLR   gfx_blitop               ; byte0 at XY0 (D2=src0)
                ; --- byte1 if s>0 ---
                LOADP   D3, Y3, [#gb_s]
                CMP     D3, #0
                BEQ     .bl1_adv
                ADD     X0, #1
                BCC     .bl1_b1nc
                ADD     Y0, #1
.bl1_b1nc:
                ; cover1 = (coverf << (8-s)) & $FF
                LOADP   D2, Y3, [#gb_coverf]
                LOADI   D3, #8
                LOADP   D1, Y3, [#gb_s]
                SUB     D3, D1                   ; 8 - s
.bl1_c1:
                CMP     D3, #0
                BEQ     .bl1_c1d
                ADD     D2, D2
                DEC     D3
                BRA     .bl1_c1
.bl1_c1d:
                AND     D2, #$FF
                STOREP  D2, Y3, [#gb_cover]
                ; src1 = (sb << (8-s)) & $FF
                LOADP   D2, Y3, [#gb_opv]
                LOADI   D3, #8
                LOADP   D1, Y3, [#gb_s]
                SUB     D3, D1
.bl1_s1:
                CMP     D3, #0
                BEQ     .bl1_s1d
                ADD     D2, D2
                DEC     D3
                BRA     .bl1_s1
.bl1_s1d:
                AND     D2, #$FF
                CALLR   gfx_blitop               ; byte1 at XY0 (now byte0+1)
                BRA     .bl1_next
.bl1_adv:
                ADD     X0, #1                   ; s==0: advance to next dest byte
                BCC     .bl1_anc
                ADD     Y0, #1
.bl1_anc:
.bl1_next:
                LOADP   D0, Y3, [#gv_cnt]        ; XY2 advanced by [XY2]+ above
                SUB     D0, #8
                STOREP  D0, Y3, [#gv_cnt]
                BRA     .bl1_loop
.bl1_done:
                RET
