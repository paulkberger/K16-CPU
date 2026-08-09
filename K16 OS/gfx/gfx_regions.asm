; ============================================================================
; gfx_regions.asm -- KGFX regions R1: alloc, rect build, scanline query.
; ----------------------------------------------------------------------------
; Region ptr in XY0 (Y0 = heap page, X0 = offset). Single-page invariant:
; band walking is X-offset arithmetic only; Y never changes. Include AFTER
; the program body. Requires gfx_regions_defs.inc and kos_defs.inc (TRAP_KMALLOC,
; TRAP_KFREE, ERR_NOMEM).
;
; Carry sense (6502-style): CMP A,B sets C=1 = no borrow (A>=B), C=0 = borrow
; (A<B). BLO = BCC = A<B. Stated at each branch below.
; ============================================================================

; ----------------------------------------------------------------------------
; rgn_new -- allocate an empty region block.
;   In:  D0 = capacity bytes
;   Out: XY0 = region ptr, C=0 ;  D0 = ERR_NOMEM, C=1 on failure
;   Clobbers: D0, XY0 (D1-D3, XY1-XY2 preserved by sys_kmalloc)
; ----------------------------------------------------------------------------
rgn_new:
                MOVE    D1, D0                  ; save capacity (kmalloc preserves D1)
                TRAP    #TRAP_KMALLOC           ; D0=size in -> XY0=ptr, C
                BCS     .rn_fail                ; C=1: D0=ERR_NOMEM
                STORED  D1, [XY0+#RGN_SIZE]
                LOADI   D1, #0
                STORED  D1, [XY0+#RGN_NBANDS]   ; empty
                CLC
                RET
.rn_fail:
                RET                             ; D0=ERR_NOMEM, C=1 from kmalloc

; ----------------------------------------------------------------------------
; rgn_dispose -- free a region block.
;   In: XY0 = region ptr.  Clobbers D0 (C per sys_kfree).
; ----------------------------------------------------------------------------
rgn_dispose:
                TRAP    #TRAP_KFREE
                RET

; ----------------------------------------------------------------------------
; rgn_is_empty -- test whether a region has no bands.
;   In: XY0 = region ptr.  Out: Z=1 if empty, Z=0 otherwise.  Clobbers D0.
; ----------------------------------------------------------------------------
rgn_is_empty:
                LOADD   D0, [XY0+#RGN_NBANDS]
                CMP     D0, #0                  ; Z=1 if empty
                RET

; ----------------------------------------------------------------------------
; rgn_copy -- duplicate src into dst (dst must have >= src used bytes).
;   In: XY0 = dst, XY1 = src.  Out: C=0.
;   Clobbers D0,D1,D2,D3,XY0,XY1.  dst's RGN_SIZE (capacity) is preserved.
;   Band-length walk uses [XY+D] (mode 01); copy is [XYn]+ dual-stream.
; ----------------------------------------------------------------------------
rgn_copy:
                ; --- compute src used bytes -> D2 (walk bands) ---
                LOADD   D0, [XY1+#RGN_NBANDS]   ; band count
                LOADI   D2, #RGN_BANDS          ; running end offset
.rcp_len:
                CMP     D0, #0
                BEQ     .rcp_lendone
                MOVE    D1, D2
                ADD     D1, #BND_NX             ; offset of this band's nx
                LOADD   D3, [XY1+D1]            ; nx          (mode 01: [XY+D])
                ADD     D3, D3                  ; 2*nx
                ADD     D3, #BND_HDR            ; band size
                ADD     D2, D3                  ; advance end offset
                DEC     D0
                BRA     .rcp_len
.rcp_lendone:
                ; --- copy [RGN_NBANDS .. used) word-stream (preserve dst RGN_SIZE) ---
                SUB     D2, #RGN_NBANDS         ; bytes to copy (RGN_SIZE excluded)
                SHR     D2                      ; -> word count
                INC     XY1, #RGN_NBANDS        ; src -> first copied word (even)
                INC     XY0, #RGN_NBANDS        ; dst -> first copied word (even)
.rcp_copy:
                CMP     D2, #0
                BEQ     .rcp_done
                LOADD   D3, [XY1]+              ; src word, post-inc (stride 2)
                STORED  D3, [XY0]+              ; dst word, post-inc (stride 2)
                DEC     D2
                BRA     .rcp_copy
.rcp_done:
                CLC
                RET

; ----------------------------------------------------------------------------
; rgn_set_empty -- mark region empty.
;   In: XY0 = region ptr.  Clobbers D1.
; ----------------------------------------------------------------------------
rgn_set_empty:
                LOADI   D1, #0
                STORED  D1, [XY0+#RGN_NBANDS]
                RET

; ----------------------------------------------------------------------------
; rgn_set_rect -- one-band rectangular region.
;   In: XY0 = region ptr; D0=L, D1=T, D2=R, D3=B
;   Out: C=0.  Clobbers D1 (T is stored before reuse).
; ----------------------------------------------------------------------------
rgn_set_rect:
                STORED  D1, [XY0+#RGN_TOP]              ; T
                STORED  D0, [XY0+#RGN_LEFT]             ; L
                STORED  D3, [XY0+#RGN_BOTTOM]           ; B
                STORED  D2, [XY0+#RGN_RIGHT]            ; R
                STORED  D1, [XY0+#RGN_BANDS+BND_YTOP]   ; band ytop = T
                STORED  D3, [XY0+#RGN_BANDS+BND_YBOT]   ; band ybot = B
                STORED  D0, [XY0+#RGN_BANDS+BND_X0]     ; xL = L
                STORED  D2, [XY0+#RGN_BANDS+BND_X0+2]   ; xR = R
                LOADI   D1, #1                          ; (T already stored)
                STORED  D1, [XY0+#RGN_NBANDS]
                LOADI   D1, #2
                STORED  D1, [XY0+#RGN_BANDS+BND_NX]
                CLC
                RET

; ----------------------------------------------------------------------------
; rgn_band_at -- find the band covering scanline y.
;   In:  XY0 = region ptr, D0 = y
;   Out: XY1 = band ptr (Y1=page, X1=band offset), C=0 ; C=1 if no band
;   Clobbers: D1, D2, D3, XY1.  Preserves XY0, D0.
; ----------------------------------------------------------------------------
rgn_band_at:
                LOADD   D2, [XY0+#RGN_NBANDS]   ; D2 = band count (loop counter)
                CMP     D2, #0
                BEQ     .rba_none               ; empty region
                MOVE    Y1, Y0
                MOVE    D3, X0
                ADD     D3, #RGN_BANDS
                MOVE    X1, D3                  ; XY1 -> first band
.rba_loop:
                LOADD   D3, [XY1+#BND_YTOP]
                CMP     D0, D3                  ; y - ytop
                BLO     .rba_none               ; C=0: y < ytop -> gap (sorted)
                LOADD   D3, [XY1+#BND_YBOT]
                CMP     D0, D3                  ; y - ybot
                BLO     .rba_found              ; C=0: ytop <= y < ybot
                ; advance: X1 += BND_HDR + 2*nx
                LOADD   D3, [XY1+#BND_NX]
                ADD     D3, D3                  ; 2*nx
                ADD     D3, #BND_HDR
                MOVE    D1, X1
                ADD     D1, D3
                MOVE    X1, D1
                DEC     D2
                BNE     .rba_loop
.rba_none:
                SEC
                RET
.rba_found:
                CLC
                RET

; ----------------------------------------------------------------------------
; rgn_pt_in -- is (x,y) inside the region?
;   In:  XY0 = region ptr, D0 = x, D1 = y
;   Out: C=0 inside ; C=1 outside
;   Clobbers: D1, D2, D3, XY1.
; ----------------------------------------------------------------------------
rgn_pt_in:
                PUSH    D0, XY3                 ; save x
                MOVE    D0, D1                  ; D0 = y for band_at
                CALLR   rgn_band_at
                BCS     .pti_out_pop            ; no band -> outside
                POP     D0, XY3                 ; restore x
                LOADD   D2, [XY1+#BND_NX]       ; coord count (even)
                MOVE    D3, X1
                ADD     D3, #BND_X0
                MOVE    X1, D3                  ; X1 -> first x-coord
.pti_loop:
                CMP     D2, #0
                BEQ     .pti_out                ; intervals exhausted
                LOADD   D3, [XY1+#0]            ; xL
                CMP     D0, D3                  ; x - xL
                BLO     .pti_out                ; C=0: x < xL (sorted) -> out
                LOADD   D3, [XY1+#2]            ; xR
                CMP     D0, D3                  ; x - xR
                BLO     .pti_in                 ; C=0: xL <= x < xR -> in
                MOVE    D3, X1                  ; next pair: X1 += 4
                ADD     D3, #4
                MOVE    X1, D3
                SUB     D2, #2
                BRA     .pti_loop
.pti_out_pop:
                POP     D0, XY3                 ; balance stack on no-band path
.pti_out:
                SEC
                RET
.pti_in:
                CLC
                RET

; ============================================================================
; R2.1 -- 1-D interval operators (operate on the RGW_* interval buffers).
; These are the operator-specific kernel of the band-merge sweep (R2.2).
; All take A in RGW_A_*, B in RGW_B_*, write R in RGW_R_*, C=1 on R overflow.
; Coords are sorted, coalesced L,R pairs. Signed compares (coords >= 0,
; well under 32768) match the gfx geometry convention.
; ============================================================================

; ----------------------------------------------------------------------------
; _rgw_emit -- append interval [D0,D1) to the R buffer.
;   In:  D0=lo, D1=hi, XY2 = R write pointer (Y3:offset).
;   Out: XY2 advanced by 4, RGW_R_N += 2, C=0 ; C=1 if it would exceed CAPN.
;   Clobbers D2.
; ----------------------------------------------------------------------------
_rgw_emit:
                LOADP   D2, Y3, [#RGW_R_N]
                ADD     D2, #2
                CMP     D2, #RGW_CAPN+1         ; new count > CAPN ?
                BHS     .emit_of                ; D2 >= CAPN+1 -> overflow
                STOREP  D2, Y3, [#RGW_R_N]
                STORED  D0, [XY2+#0]            ; lo
                STORED  D1, [XY2+#2]            ; hi
                MOVE    D2, X2
                ADD     D2, #4
                MOVE    X2, D2                  ; advance R ptr
                CLC
                RET
.emit_of:
                SEC
                RET

; ----------------------------------------------------------------------------
; _sub1d -- R = A - B  (interval subtraction).
;   In:  RGW_A_*, RGW_B_*.  Out: RGW_R_*, C=0 ; C=1 on R overflow.
;   For each A-interval, emit the parts not covered by any B-interval.
;   Clobbers D0-D3, XY0, XY1, XY2; RGW_AREM/BREM/CUR/AR, RGW_R_N.
; ----------------------------------------------------------------------------
_sub1d:
                LOADI   D0, #0
                STOREP  D0, Y3, [#RGW_R_N]      ; R empty
                MOVE    Y2, Y3
                LOADI   X2, #RGW_R_X            ; R write ptr
                MOVE    Y0, Y3
                LOADI   X0, #RGW_A_X            ; A read ptr
                LOADP   D0, Y3, [#RGW_A_N]
                STOREP  D0, Y3, [#RGW_AREM]
.sub_aloop:
                LOADP   D0, Y3, [#RGW_AREM]
                CMP     D0, #0
                BLE     .sub_done               ; no more A intervals
                ; cur = aL ; aR
                LOADD   D0, [XY0+#0]            ; aL
                STOREP  D0, Y3, [#RGW_CUR]      ; cur = aL
                LOADD   D0, [XY0+#2]            ; aR
                STOREP  D0, Y3, [#RGW_AR]
                MOVE    D0, X0                  ; advance A ptr +4
                ADD     D0, #4
                MOVE    X0, D0
                LOADP   D0, Y3, [#RGW_AREM]
                SUB     D0, #2
                STOREP  D0, Y3, [#RGW_AREM]
                ; reset B scan
                MOVE    Y1, Y3
                LOADI   X1, #RGW_B_X
                LOADP   D0, Y3, [#RGW_B_N]
                STOREP  D0, Y3, [#RGW_BREM]
.sub_bloop:
                LOADP   D0, Y3, [#RGW_BREM]
                CMP     D0, #0
                BLE     .sub_tail               ; no more B -> emit tail
                LOADD   D2, [XY1+#0]            ; bL
                LOADD   D3, [XY1+#2]            ; bR
                MOVE    D0, X1                  ; advance B ptr +4
                ADD     D0, #4
                MOVE    X1, D0
                LOADP   D0, Y3, [#RGW_BREM]
                SUB     D0, #2
                STOREP  D0, Y3, [#RGW_BREM]
                ; if bR <= cur: B entirely left, next B
                LOADP   D0, Y3, [#RGW_CUR]
                CMP     D3, D0                  ; bR vs cur
                BLE     .sub_bloop
                ; if bL >= aR: B (and rest) right of A-interval -> tail
                LOADP   D1, Y3, [#RGW_AR]
                CMP     D2, D1                  ; bL vs aR
                BGE     .sub_tail
                ; B overlaps [cur,aR). If bL > cur: emit gap [cur,bL)
                LOADP   D0, Y3, [#RGW_CUR]
                CMP     D2, D0                  ; bL vs cur
                BLE     .sub_setcur             ; bL <= cur -> no gap
                MOVE    D1, D2                  ; hi = bL  (D0 = cur = lo)
                CALLR   _rgw_emit
                BCS     .sub_of
.sub_setcur:
                ; cur = max(cur, bR)
                LOADP   D0, Y3, [#RGW_CUR]
                CMP     D3, D0                  ; bR vs cur
                BLE     .sub_curok
                STOREP  D3, Y3, [#RGW_CUR]      ; cur = bR
.sub_curok:
                LOADP   D0, Y3, [#RGW_CUR]
                LOADP   D1, Y3, [#RGW_AR]
                CMP     D0, D1                  ; cur vs aR
                BGE     .sub_aloop              ; cur >= aR -> next A interval
                BRA     .sub_bloop
.sub_tail:
                LOADP   D0, Y3, [#RGW_CUR]
                LOADP   D1, Y3, [#RGW_AR]
                CMP     D0, D1                  ; cur vs aR
                BGE     .sub_aloop              ; nothing left in this A interval
                CALLR   _rgw_emit               ; emit [cur, aR)
                BCS     .sub_of
                BRA     .sub_aloop
.sub_done:
                CLC
                RET
.sub_of:
                SEC
                RET

; ----------------------------------------------------------------------------
; _isect1d -- R = A intersect B.
;   In:  RGW_A_*, RGW_B_*.  Out: RGW_R_*, C=0 ; C=1 on R overflow.
;   Two-pointer: emit [max(aL,bL), min(aR,bR)) where they overlap; advance
;   whichever interval ends first (both if equal). aR/bR stashed in
;   RGW_AR/RGW_CUR across _rgw_emit (which clobbers D2).
;   Clobbers D0-D3, XY0,XY1,XY2; RGW_AREM/BREM/AR/CUR, RGW_R_N.
; ----------------------------------------------------------------------------
_isect1d:
                LOADI   D0, #0
                STOREP  D0, Y3, [#RGW_R_N]
                MOVE    Y2, Y3
                LOADI   X2, #RGW_R_X
                MOVE    Y0, Y3
                LOADI   X0, #RGW_A_X
                LOADP   D0, Y3, [#RGW_A_N]
                STOREP  D0, Y3, [#RGW_AREM]
                MOVE    Y1, Y3
                LOADI   X1, #RGW_B_X
                LOADP   D0, Y3, [#RGW_B_N]
                STOREP  D0, Y3, [#RGW_BREM]
.is_loop:
                LOADP   D0, Y3, [#RGW_AREM]
                CMP     D0, #0
                BLE     .is_done
                LOADP   D0, Y3, [#RGW_BREM]
                CMP     D0, #0
                BLE     .is_done
                LOADD   D0, [XY0+#0]            ; aL
                LOADD   D1, [XY0+#2]            ; aR
                LOADD   D2, [XY1+#0]            ; bL
                LOADD   D3, [XY1+#2]            ; bR
                STOREP  D1, Y3, [#RGW_AR]       ; stash aR
                STOREP  D3, Y3, [#RGW_CUR]      ; stash bR
                ; lo = max(aL,bL) -> D0
                CMP     D0, D2                  ; aL vs bL
                BGE     .is_lo
                MOVE    D0, D2                  ; lo = bL
.is_lo:
                ; hi = min(aR,bR) -> D1   (D1=aR, D3=bR)
                CMP     D1, D3                  ; aR vs bR
                BLE     .is_hi
                MOVE    D1, D3                  ; hi = bR
.is_hi:
                CMP     D0, D1                  ; lo vs hi
                BGE     .is_adv                 ; lo >= hi -> no overlap
                CALLR   _rgw_emit               ; [lo,hi)
                BCS     .is_of
.is_adv:
                LOADP   D0, Y3, [#RGW_AR]       ; aR
                LOADP   D1, Y3, [#RGW_CUR]      ; bR
                CMP     D1, D0                  ; bR vs aR
                BLT     .is_advB                ; bR < aR -> advance B only
                ; aR <= bR: advance A
                MOVE    D2, X0
                ADD     D2, #4
                MOVE    X0, D2
                LOADP   D2, Y3, [#RGW_AREM]
                SUB     D2, #2
                STOREP  D2, Y3, [#RGW_AREM]
                CMP     D0, D1                  ; aR vs bR
                BNE     .is_loop                ; aR < bR -> done advancing
                ; aR == bR -> also advance B
.is_advB:
                MOVE    D2, X1
                ADD     D2, #4
                MOVE    X1, D2
                LOADP   D2, Y3, [#RGW_BREM]
                SUB     D2, #2
                STOREP  D2, Y3, [#RGW_BREM]
                BRA     .is_loop
.is_done:
                CLC
                RET
.is_of:
                SEC
                RET

; ----------------------------------------------------------------------------
; _union1d -- R = A union B.
;   In:  RGW_A_*, RGW_B_*.  Out: RGW_R_*, C=0 ; C=1 on R overflow.
;   Merge both sorted lists by left edge into a running interval [OLO,OHI);
;   coalesce while next.lo <= OHI (overlap or touch), else flush and restart.
;   Flush the running interval at end. RGW_AR/RGW_CUR reused as incoming
;   stash during a flush (clobbered by _rgw_emit).
;   Clobbers D0-D3, XY0,XY1,XY2; RGW_AREM/BREM/OLO/OHI/OHAVE/AR/CUR, RGW_R_N.
; ----------------------------------------------------------------------------
_union1d:
                LOADI   D0, #0
                STOREP  D0, Y3, [#RGW_R_N]
                STOREP  D0, Y3, [#RGW_OHAVE]   ; no running interval
                MOVE    Y2, Y3
                LOADI   X2, #RGW_R_X
                MOVE    Y0, Y3
                LOADI   X0, #RGW_A_X
                LOADP   D0, Y3, [#RGW_A_N]
                STOREP  D0, Y3, [#RGW_AREM]
                MOVE    Y1, Y3
                LOADI   X1, #RGW_B_X
                LOADP   D0, Y3, [#RGW_B_N]
                STOREP  D0, Y3, [#RGW_BREM]
.un_loop:
                LOADP   D0, Y3, [#RGW_AREM]
                CMP     D0, #0
                BLE     .un_b_or_done           ; A exhausted
                LOADP   D0, Y3, [#RGW_BREM]
                CMP     D0, #0
                BLE     .un_useA                ; B exhausted -> use A
                ; both: take the smaller left edge
                LOADD   D0, [XY0+#0]            ; aL
                LOADD   D1, [XY1+#0]            ; bL
                CMP     D0, D1                  ; aL vs bL
                BLE     .un_useA                ; aL <= bL -> take A
                BRA     .un_useB
.un_b_or_done:
                LOADP   D0, Y3, [#RGW_BREM]
                CMP     D0, #0
                BLE     .un_flush_done          ; both exhausted
                ; fall to useB
.un_useB:
                LOADD   D0, [XY1+#0]            ; lo
                LOADD   D1, [XY1+#2]            ; hi
                MOVE    D2, X1
                ADD     D2, #4
                MOVE    X1, D2
                LOADP   D2, Y3, [#RGW_BREM]
                SUB     D2, #2
                STOREP  D2, Y3, [#RGW_BREM]
                BRA     .un_have
.un_useA:
                LOADD   D0, [XY0+#0]            ; lo
                LOADD   D1, [XY0+#2]            ; hi
                MOVE    D2, X0
                ADD     D2, #4
                MOVE    X0, D2
                LOADP   D2, Y3, [#RGW_AREM]
                SUB     D2, #2
                STOREP  D2, Y3, [#RGW_AREM]
.un_have:
                ; D0=lo, D1=hi : merge into running interval
                LOADP   D2, Y3, [#RGW_OHAVE]
                CMP     D2, #0
                BNE     .un_merge
                ; no running: start one
                STOREP  D0, Y3, [#RGW_OLO]
                STOREP  D1, Y3, [#RGW_OHI]
                LOADI   D2, #1
                STOREP  D2, Y3, [#RGW_OHAVE]
                BRA     .un_loop
.un_merge:
                LOADP   D2, Y3, [#RGW_OHI]
                CMP     D2, D0                  ; OHI vs lo
                BLT     .un_flush_start         ; OHI < lo -> disjoint
                ; coalesce: OHI = max(OHI, hi)
                CMP     D1, D2                  ; hi vs OHI
                BLE     .un_loop                ; hi <= OHI -> unchanged
                STOREP  D1, Y3, [#RGW_OHI]
                BRA     .un_loop
.un_flush_start:
                ; stash incoming, flush old running, then start new = incoming
                STOREP  D0, Y3, [#RGW_AR]       ; tmp lo
                STOREP  D1, Y3, [#RGW_CUR]      ; tmp hi
                LOADP   D0, Y3, [#RGW_OLO]
                LOADP   D1, Y3, [#RGW_OHI]
                CALLR   _rgw_emit
                BCS     .un_of
                LOADP   D0, Y3, [#RGW_AR]
                STOREP  D0, Y3, [#RGW_OLO]
                LOADP   D0, Y3, [#RGW_CUR]
                STOREP  D0, Y3, [#RGW_OHI]
                BRA     .un_loop
.un_flush_done:
                LOADP   D2, Y3, [#RGW_OHAVE]
                CMP     D2, #0
                BEQ     .un_done
                LOADP   D0, Y3, [#RGW_OLO]
                LOADP   D1, Y3, [#RGW_OHI]
                CALLR   _rgw_emit
                BCS     .un_of
.un_done:
                CLC
                RET
.un_of:
                SEC
                RET

; ============================================================================
; R2.2 -- band-merge sweep driver (mode-arg). dst = op(A,B).
; One y-strip sweep; per strip, copy each region's active band x-list into the
; A/B interval buffers, run the selected 1-D op, append the result as a band.
; No vertical coalescing in this revision (R2.2b) -- output is correct but may
; carry adjacent identical bands. dst must not alias A or B.
; ============================================================================

; ----------------------------------------------------------------------------
; _rgm_probe -- for region XY0 at scanline RGM_Y, find active band + next edge.
;   In:  XY0 = region ptr (Y0=page, X0=base offset), RGM_Y = y.
;   Out: D0 = active band offset within page ($FFFF if none covers y)
;        D1 = next y-edge strictly > y ($7FFF/INF if none)
;   Clobbers D2, D3, XY0 (walked).
; ----------------------------------------------------------------------------
_rgm_probe:
                LOADD   D2, [XY0+#RGN_NBANDS]   ; band count
                MOVE    D3, X0
                ADD     D3, #RGN_BANDS
                MOVE    X0, D3                  ; XY0 -> first band
                LOADP   D3, Y3, [#RGM_Y]        ; y
.pr_loop:
                CMP     D2, #0
                BLE     .pr_past
                LOADD   D1, [XY0+#BND_YBOT]
                CMP     D3, D1                  ; y vs ybot
                BLT     .pr_hit                 ; y < ybot -> first band ending after y
                ; advance: X0 += BND_HDR + 2*nx
                LOADD   D0, [XY0+#BND_NX]
                ADD     D0, D0
                ADD     D0, #BND_HDR
                MOVE    D1, X0
                ADD     D1, D0
                MOVE    X0, D1
                DEC     D2
                BRA     .pr_loop
.pr_hit:
                ; D1 = ybot. Covers y if ytop <= y.
                LOADD   D0, [XY0+#BND_YTOP]
                CMP     D0, D3                  ; ytop vs y
                BLE     .pr_active              ; ytop <= y -> covers
                ; gap: next edge = ytop, no active band
                MOVE    D1, D0                  ; next = ytop
                LOADI   D0, #$FFFF
                RET
.pr_active:
                MOVE    D0, X0                  ; active band offset; D1 = ybot = next edge
                RET
.pr_past:
                LOADI   D0, #$FFFF
                LOADI   D1, #RGM_INF
                RET

; ----------------------------------------------------------------------------
; _rgm_band2buf -- copy a band's x-coords into an interval buffer.
;   In: XY0 = band ptr (Y0=page, X0=band offset); D2 = target buffer N-addr
;       (e.g. RGW_A_N). Buffer layout: [N]=count, [N+2..]=coords.
;   Clobbers D0, D1, D3, XY0 (advanced), XY1.
; ----------------------------------------------------------------------------
_rgm_band2buf:
                MOVE    Y1, Y3
                MOVE    X1, D2                  ; XY1 -> buffer count slot
                LOADD   D0, [XY0+#BND_NX]       ; n coords
                STORED  D0, [XY1+#0]            ; buffer count
                MOVE    D3, X1
                ADD     D3, #2
                MOVE    X1, D3                  ; XY1 -> buffer coords
                MOVE    D3, X0
                ADD     D3, #BND_X0
                MOVE    X0, D3                  ; XY0 -> band coords
.b2b_loop:
                CMP     D0, #0
                BLE     .b2b_done
                LOADD   D1, [XY0+#0]
                STORED  D1, [XY1+#0]
                MOVE    D3, X0
                ADD     D3, #2
                MOVE    X0, D3
                MOVE    D3, X1
                ADD     D3, #2
                MOVE    X1, D3
                DEC     D0
                BRA     .b2b_loop
.b2b_done:
                RET

; ----------------------------------------------------------------------------
; Public wrappers -- set op selector, tail into the sweep.
;   In: XY0 = dst, XY1 = A, XY2 = B.  Out: C=0 ; C=1 (D0=ERR_NOMEM) on overflow.
; ----------------------------------------------------------------------------
rgn_subtract:
                LOADI   D3, #0
                STOREP  D3, Y3, [#RGM_OP]
                BRA     _rgn_merge
rgn_intersect:
                LOADI   D3, #1
                STOREP  D3, Y3, [#RGM_OP]
                BRA     _rgn_merge
rgn_union:
                LOADI   D3, #2
                STOREP  D3, Y3, [#RGM_OP]
                BRA     _rgn_merge

; ----------------------------------------------------------------------------
; _rgn_merge -- the sweep. dst=XY0, A=XY1, B=XY2, RGM_OP set.
; ----------------------------------------------------------------------------
_rgn_merge:
                ; stash region bases
                MOVE    D0, Y0
                STOREP  D0, Y3, [#RGM_DST_PG]
                MOVE    D0, X0
                STOREP  D0, Y3, [#RGM_DST_OF]
                MOVE    D0, Y1
                STOREP  D0, Y3, [#RGM_A_PG]
                MOVE    D0, X1
                STOREP  D0, Y3, [#RGM_A_OF]
                MOVE    D0, Y2
                STOREP  D0, Y3, [#RGM_B_PG]
                MOVE    D0, X2
                STOREP  D0, Y3, [#RGM_B_OF]
                ; init dst accumulators
                ; WPTR is an ABSOLUTE page offset = dst base + RGN_BANDS
                ; (region fields are base-relative; pointers carry the base in X).
                LOADP   D0, Y3, [#RGM_DST_OF]
                ADD     D0, #RGN_BANDS
                STOREP  D0, Y3, [#RGM_WPTR]
                LOADI   D0, #0
                STOREP  D0, Y3, [#RGM_NB]
                LOADI   D0, #$FFFF
                STOREP  D0, Y3, [#RGM_PREV]
                LOADI   D0, #RGM_INF
                STOREP  D0, Y3, [#RGM_BB_T]
                STOREP  D0, Y3, [#RGM_BB_L]
                LOADI   D0, #$8000              ; -INF (signed min) for max-accumulators
                STOREP  D0, Y3, [#RGM_BB_B]
                STOREP  D0, Y3, [#RGM_BB_R]
                ; initial y = min(A.first.ytop, B.first.ytop)
                LOADP   D0, Y3, [#RGM_A_PG]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#RGM_A_OF]
                MOVE    X0, D0
                LOADD   D2, [XY0+#RGN_NBANDS]
                CMP     D2, #0
                BEQ     .mg_ay_inf
                LOADD   D0, [XY0+#RGN_BANDS+BND_YTOP]
                BRA     .mg_ay_done
.mg_ay_inf:
                LOADI   D0, #RGM_INF
.mg_ay_done:
                STOREP  D0, Y3, [#RGM_Y]        ; ay (temp)
                LOADP   D0, Y3, [#RGM_B_PG]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#RGM_B_OF]
                MOVE    X0, D0
                LOADD   D2, [XY0+#RGN_NBANDS]
                CMP     D2, #0
                BEQ     .mg_by_inf
                LOADD   D1, [XY0+#RGN_BANDS+BND_YTOP]
                BRA     .mg_by_done
.mg_by_inf:
                LOADI   D1, #RGM_INF
.mg_by_done:
                LOADP   D0, Y3, [#RGM_Y]        ; ay
                CMP     D0, D1                  ; ay vs by
                BLE     .mg_y0
                MOVE    D0, D1                  ; y = by
.mg_y0:
                STOREP  D0, Y3, [#RGM_Y]
                CMP     D0, #RGM_INF
                BEQ     .mg_finalize            ; both empty
.mg_loop:
                ; probe A
                LOADP   D0, Y3, [#RGM_A_PG]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#RGM_A_OF]
                MOVE    X0, D0
                CALLR   _rgm_probe
                STOREP  D0, Y3, [#RGM_AACT]
                STOREP  D1, Y3, [#RGM_ANEXT]
                ; probe B
                LOADP   D0, Y3, [#RGM_B_PG]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#RGM_B_OF]
                MOVE    X0, D0
                CALLR   _rgm_probe
                STOREP  D0, Y3, [#RGM_BACT]
                STOREP  D1, Y3, [#RGM_BNEXT]
                ; ynext = min(ANEXT, BNEXT)
                LOADP   D0, Y3, [#RGM_ANEXT]
                LOADP   D1, Y3, [#RGM_BNEXT]
                CMP     D0, D1
                BLE     .mg_yn
                MOVE    D0, D1
.mg_yn:
                STOREP  D0, Y3, [#RGM_YNEXT]
                CMP     D0, #RGM_INF
                BEQ     .mg_finalize            ; no more edges
                ; --- A buffer ---
                LOADP   D0, Y3, [#RGM_AACT]
                CMP     D0, #$FFFF
                BEQ     .mg_a_empty
                LOADP   D1, Y3, [#RGM_A_PG]
                MOVE    Y0, D1
                MOVE    X0, D0                  ; XY0 = A active band ptr
                LOADI   D2, #RGW_A_N
                CALLR   _rgm_band2buf
                BRA     .mg_b
.mg_a_empty:
                LOADI   D0, #0
                STOREP  D0, Y3, [#RGW_A_N]
.mg_b:
                ; --- B buffer ---
                LOADP   D0, Y3, [#RGM_BACT]
                CMP     D0, #$FFFF
                BEQ     .mg_b_empty
                LOADP   D1, Y3, [#RGM_B_PG]
                MOVE    Y0, D1
                MOVE    X0, D0                  ; XY0 = B active band ptr
                LOADI   D2, #RGW_B_N
                CALLR   _rgm_band2buf
                BRA     .mg_op
.mg_b_empty:
                LOADI   D0, #0
                STOREP  D0, Y3, [#RGW_B_N]
.mg_op:
                LOADP   D0, Y3, [#RGM_OP]
                CMP     D0, #0
                BEQ     .mg_sub
                CMP     D0, #1
                BEQ     .mg_is
                CALLR   _union1d
                BRA     .mg_opd
.mg_sub:
                CALLR   _sub1d
                BRA     .mg_opd
.mg_is:
                CALLR   _isect1d
.mg_opd:
                BCS     .mg_overflow            ; 1-D op overflowed R buffer
                ; emit band if R non-empty
                LOADP   D0, Y3, [#RGW_R_N]
                CMP     D0, #0
                BLE     .mg_advance
                ; --- try vertical coalesce: prev band y-adjacent + identical x-list ---
                LOADP   D0, Y3, [#RGM_PREV]
                CMP     D0, #$FFFF
                BEQ     .mg_append              ; no previous band
                LOADP   D1, Y3, [#RGM_DST_PG]
                MOVE    Y1, D1
                MOVE    X1, D0                  ; XY1 -> prev band
                LOADD   D1, [XY1+#BND_YBOT]
                LOADP   D2, Y3, [#RGM_Y]
                CMP     D1, D2
                BNE     .mg_append              ; not y-adjacent
                LOADD   D1, [XY1+#BND_NX]
                LOADP   D2, Y3, [#RGW_R_N]
                CMP     D1, D2
                BNE     .mg_append              ; different interval count
                ; compare coord lists (D2 = count)
                MOVE    D0, X1
                ADD     D0, #BND_X0
                MOVE    X1, D0                  ; XY1 -> prev coords
                MOVE    Y0, Y3
                LOADI   X0, #RGW_R_X            ; XY0 -> R coords
.mg_cmp:
                CMP     D2, #0
                BLE     .mg_coalesce            ; all coords equal
                LOADD   D0, [XY1+#0]
                LOADD   D1, [XY0+#0]
                CMP     D0, D1
                BNE     .mg_append              ; differs -> new band
                MOVE    D0, X1
                ADD     D0, #2
                MOVE    X1, D0
                MOVE    D0, X0
                ADD     D0, #2
                MOVE    X0, D0
                SUB     D2, #1
                BRA     .mg_cmp
.mg_coalesce:
                ; extend prev.ybot to this strip's bottom; no new band
                LOADP   D0, Y3, [#RGM_DST_PG]
                MOVE    Y1, D0
                LOADP   D0, Y3, [#RGM_PREV]
                MOVE    X1, D0
                LOADP   D0, Y3, [#RGM_YNEXT]
                STORED  D0, [XY1+#BND_YBOT]
                ; bbox B = max(BB_B, YNEXT)
                LOADP   D0, Y3, [#RGM_BB_B]
                LOADP   D2, Y3, [#RGM_YNEXT]
                CMP     D2, D0
                BLE     .mg_advance
                STOREP  D2, Y3, [#RGM_BB_B]
                BRA     .mg_advance
.mg_append:
                ; capacity check: WPTR + BND_HDR + R_N*2 <= dst.RGN_SIZE
                LOADP   D1, Y3, [#RGM_WPTR]
                LOADP   D2, Y3, [#RGW_R_N]
                ADD     D2, D2
                ADD     D2, #BND_HDR
                ADD     D1, D2                  ; new WPTR
                LOADP   D0, Y3, [#RGM_DST_PG]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#RGM_DST_OF]
                MOVE    X0, D0
                LOADD   D3, [XY0+#RGN_SIZE]
                LOADP   D0, Y3, [#RGM_DST_OF]
                ADD     D3, D0                  ; absolute end-of-payload = base + capacity
                CMP     D3, D1                  ; payload end vs new WPTR
                BLT     .mg_overflow            ; end < new WPTR -> no space
                ; write band header at dst:WPTR
                LOADP   D0, Y3, [#RGM_DST_PG]
                MOVE    Y1, D0
                LOADP   D0, Y3, [#RGM_WPTR]
                MOVE    X1, D0                  ; XY1 -> band slot
                LOADP   D0, Y3, [#RGM_Y]
                STORED  D0, [XY1+#BND_YTOP]
                LOADP   D0, Y3, [#RGM_YNEXT]
                STORED  D0, [XY1+#BND_YBOT]
                LOADP   D0, Y3, [#RGW_R_N]
                STORED  D0, [XY1+#BND_NX]
                ; copy R coords -> band coords
                MOVE    D0, X1
                ADD     D0, #BND_X0
                MOVE    X1, D0                  ; XY1 -> band coords
                MOVE    Y0, Y3
                LOADI   X0, #RGW_R_X            ; XY0 -> R coords
                LOADP   D2, Y3, [#RGW_R_N]
.mg_cpy:
                CMP     D2, #0
                BLE     .mg_cpd
                LOADD   D3, [XY0+#0]
                STORED  D3, [XY1+#0]
                MOVE    D0, X0
                ADD     D0, #2
                MOVE    X0, D0
                MOVE    D0, X1
                ADD     D0, #2
                MOVE    X1, D0
                SUB     D2, #1                  ; one word copied per pass; R_N counts words
                BRA     .mg_cpy
.mg_cpd:
                ; bbox T = min(T, Y)
                LOADP   D0, Y3, [#RGM_BB_T]
                LOADP   D2, Y3, [#RGM_Y]
                CMP     D2, D0
                BGE     .mg_bb1
                STOREP  D2, Y3, [#RGM_BB_T]
.mg_bb1:
                ; bbox B = max(B, YNEXT)
                LOADP   D0, Y3, [#RGM_BB_B]
                LOADP   D2, Y3, [#RGM_YNEXT]
                CMP     D2, D0
                BLE     .mg_bb2
                STOREP  D2, Y3, [#RGM_BB_B]
.mg_bb2:
                ; bbox L = min(L, first R coord)
                LOADP   D2, Y3, [#RGW_R_X]
                LOADP   D0, Y3, [#RGM_BB_L]
                CMP     D2, D0
                BGE     .mg_bb3
                STOREP  D2, Y3, [#RGM_BB_L]
.mg_bb3:
                ; bbox R = max(R, last R coord)
                LOADP   D2, Y3, [#RGW_R_N]
                SUB     D2, #1
                ADD     D2, D2                  ; (R_N-1)*2 byte offset of last word
                MOVE    Y0, Y3
                LOADI   D0, #RGW_R_X
                ADD     D0, D2
                MOVE    X0, D0
                LOADD   D2, [XY0+#0]            ; last coord
                LOADP   D0, Y3, [#RGM_BB_R]
                CMP     D2, D0
                BLE     .mg_bb4
                STOREP  D2, Y3, [#RGM_BB_R]
.mg_bb4:
                ; PREV = WPTR ; NB++ ; WPTR += band bytes
                LOADP   D0, Y3, [#RGM_WPTR]
                STOREP  D0, Y3, [#RGM_PREV]
                LOADP   D0, Y3, [#RGM_NB]
                ADD     D0, #1
                STOREP  D0, Y3, [#RGM_NB]
                LOADP   D0, Y3, [#RGM_WPTR]
                LOADP   D2, Y3, [#RGW_R_N]
                ADD     D2, D2
                ADD     D2, #BND_HDR
                ADD     D0, D2
                STOREP  D0, Y3, [#RGM_WPTR]
.mg_advance:
                LOADP   D0, Y3, [#RGM_YNEXT]
                STOREP  D0, Y3, [#RGM_Y]
                BRA     .mg_loop
.mg_finalize:
                LOADP   D0, Y3, [#RGM_DST_PG]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#RGM_DST_OF]
                MOVE    X0, D0
                LOADP   D1, Y3, [#RGM_NB]
                STORED  D1, [XY0+#RGN_NBANDS]
                CMP     D1, #0
                BNE     .mg_bbox
                LOADI   D1, #0
                STORED  D1, [XY0+#RGN_TOP]
                STORED  D1, [XY0+#RGN_LEFT]
                STORED  D1, [XY0+#RGN_BOTTOM]
                STORED  D1, [XY0+#RGN_RIGHT]
                BRA     .mg_ok
.mg_bbox:
                LOADP   D1, Y3, [#RGM_BB_T]
                STORED  D1, [XY0+#RGN_TOP]
                LOADP   D1, Y3, [#RGM_BB_L]
                STORED  D1, [XY0+#RGN_LEFT]
                LOADP   D1, Y3, [#RGM_BB_B]
                STORED  D1, [XY0+#RGN_BOTTOM]
                LOADP   D1, Y3, [#RGM_BB_R]
                STORED  D1, [XY0+#RGN_RIGHT]
.mg_ok:
                CLC
                RET
.mg_overflow:
                ; finalize band count so far, then signal no-space
                LOADP   D0, Y3, [#RGM_DST_PG]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#RGM_DST_OF]
                MOVE    X0, D0
                LOADP   D1, Y3, [#RGM_NB]
                STORED  D1, [XY0+#RGN_NBANDS]
                LOADI   D0, #ERR_NOMEM          ; result too large for dst
                SEC
                RET
