; ==========================================================================
; gfx_scroll -- vertical scroll of a byte-rectangle within the surface.
;
;   Depth-blind block-move: only the pixel->byte conversion of x/width uses
;   GS_BPP (via the GS_ADDR corner helper); the row copy is byte-identical at
;   1bpp and 8bpp. NOT a descriptor method vector -- the GS_* CALLXY table is
;   full to the imm5 ceiling and there is only one implementation to call.
;
;   Setup computes everything loop-invariant ONCE: direction, |dv|, clamped
;   height, row count, the (iters, rem, odd) split of the row width, the
;   per-row advance, and the two corner addresses. The copy then runs in one
;   of two direction-specialised loops -- no per-row direction test, no per-row
;   width recompute:
;       up   : copy_row ; LEA XY,XY+adv     (forward, page-safe)
;       down : copy_row ; SUB X,adv / SBC Y,#0   (backward, borrow into page)
;   copy_row is the shared bottleneck (8-word blocks + remainder + odd byte).
;
;   Does NOT fill the vacated band (caller's job, ScrollRect semantics).
;   Region clip deferred; height is clamped to the surface into a local
;   (gsc_h) -- the caller's gr_h is left untouched. 1bpp: rect x and width
;   must be byte-aligned (multiple of 8).
;
;   In:  XY1 = surface descriptor
;        gr_x, gr_y, gr_w, gr_h = rect (pixels)
;        D0 = dv (signed rows): +N down (exposes top N), -N up (exposes bottom)
;   Out: bits moved; vacated band untouched.
;   Preserves XY1 and Y3. Clobbers D0-D3, XY0, XY2, gs_*/gsc_* scratch.
;   Overlap-safe: up copies rows top->bottom, down bottom->top.
; ==========================================================================
gfx_scroll:
                CMP     D0, #0
                BNE     .sc_nz
                RET                             ; dv = 0: nothing to do
.sc_nz:
                ; --- direction (0=up, 1=down) and n = |dv| ---
                MOVE    D1, D0
                AND     D1, #$8000
                BEQ     .sc_down                ; dv > 0 -> down
                NEG     D0                      ; up: n = -dv
                LOADI   D1, #0
                BRA     .sc_dirset
.sc_down:
                LOADI   D1, #1
.sc_dirset:
                STOREP  D1, Y3, [#gsc_dir]
                STOREP  D0, Y3, [#gsc_n]        ; n (> 0)

                ; --- clamp height into gsc_h (gr_y + h <= GS_HEIGHT) ----------
                LOADP   D2, Y3, [#gr_y]
                LOADP   D3, Y3, [#gr_h]
                LOADD   D1, [XY1+#GSO_HEIGHT]
                SUB     D1, D2                  ; hmax = H - y0
                CMP     D3, D1
                BLS     .sc_hok
                MOVE    D3, D1                  ; clamp
.sc_hok:
                STOREP  D3, Y3, [#gsc_h]
                ; rows = h - n ; bail if n >= h
                MOVE    D1, D3
                CMP     D1, D0
                BHI     .sc_rowsok
                RET
.sc_rowsok:
                SUB     D1, D0
                STOREP  D1, Y3, [#gsc_rows]

                ; --- fb page + constant gs_x for the corner helper ------------
                LOADD   D0, [XY1+#0]
                STOREP  D0, Y3, [#gs_fbpage]
                LOADP   D0, Y3, [#gr_x]
                STOREP  D0, Y3, [#gs_x]

                ; --- width split: wb -> (iters, rem) words + odd byte ---------
                LOADP   D0, Y3, [#gr_w]
                LOADP   D1, Y3, [#GS_BPP]
                CMP     D1, #1
                BNE     .sc_wbok
                SHR     D0
                SHR     D0
                SHR     D0                      ; 1bpp: wb = w >> 3
.sc_wbok:
                MOVE    D3, D0                  ; D3 = wb (kept for adv below)
                AND     D0, #1
                STOREP  D0, Y3, [#gsc_odd]      ; odd = wb & 1
                MOVE    D0, D3
                SHR     D0                      ; words = wb >> 1
                MOVE    D2, D0
                SHR     D2
                SHR     D2
                SHR     D2                      ; iters = words >> 3
                STOREP  D2, Y3, [#gsc_iters]
                AND     D0, #7                  ; rem = words & 7
                STOREP  D0, Y3, [#gsc_rem]

                ; --- per-row advance: up = pitch - wb ; down = pitch + wb -----
                LOADP   D1, Y3, [#GS_PITCH]
                LOADP   D2, Y3, [#gsc_dir]
                CMP     D2, #0
                BNE     .sc_advdn
                SUB     D1, D3                  ; up
                BRA     .sc_advok
.sc_advdn:
                ADD     D1, D3                  ; down
.sc_advok:
                STOREP  D1, Y3, [#gsc_adv]

                ; --- corner addresses via GS_ADDR (gs_x preset) --------------
                LOADP   D2, Y3, [#gsc_dir]
                CMP     D2, #0
                BNE     .sc_cdn
                ; UP: dst row = gr_y ; src row = gr_y + n
                LOADP   D0, Y3, [#gr_y]
                STOREP  D0, Y3, [#gs_y]
                CALLR   sc_addr
                STOREP  X0, Y3, [#gsc_dof]
                STOREP  Y0, Y3, [#gsc_dpg]
                LOADP   D0, Y3, [#gr_y]
                LOADP   D1, Y3, [#gsc_n]
                ADD     D0, D1
                STOREP  D0, Y3, [#gs_y]
                CALLR   sc_addr
                STOREP  X0, Y3, [#gsc_sof]
                STOREP  Y0, Y3, [#gsc_spg]
                BRA     .sc_run
.sc_cdn:
                ; DOWN: base = gr_y + h - 1 ; dst = base ; src = base - n
                LOADP   D0, Y3, [#gr_y]
                LOADP   D1, Y3, [#gsc_h]
                ADD     D0, D1
                SUB     D0, #1
                MOVE    D3, D0                  ; save base (sc_addr preserves D3)
                STOREP  D0, Y3, [#gs_y]
                CALLR   sc_addr
                STOREP  X0, Y3, [#gsc_dof]
                STOREP  Y0, Y3, [#gsc_dpg]
                MOVE    D0, D3
                LOADP   D1, Y3, [#gsc_n]
                SUB     D0, D1
                STOREP  D0, Y3, [#gs_y]
                CALLR   sc_addr
                STOREP  X0, Y3, [#gsc_sof]
                STOREP  Y0, Y3, [#gsc_spg]

.sc_run:
                ; --- load working pointers, row counter, advance; dispatch ----
                LOADP   X0, Y3, [#gsc_dof]
                LOADP   Y0, Y3, [#gsc_dpg]      ; XY0 = dst pointer
                LOADP   X2, Y3, [#gsc_sof]
                LOADP   Y2, Y3, [#gsc_spg]      ; XY2 = src pointer
                LOADP   D3, Y3, [#gsc_rows]     ; D3 = rows (held)
                LOADP   D1, Y3, [#gsc_adv]      ; D1 = advance (held)
                LOADP   D2, Y3, [#gsc_dir]
                CMP     D2, #0
                BNE     .sc_dnloop

.sc_uploop:
                CALLR   copy_row
                LEA     XY0, XY0+D1             ; dst += adv (page-safe forward)
                LEA     XY2, XY2+D1             ; src += adv
                DEC     D3
                BNE.L   .sc_uploop
                RET

.sc_dnloop:
                CALLR   copy_row
                SUB     X0, D1                  ; dst -= adv (borrow into page)
                SBC     Y0, #0
                SUB     X2, D1                  ; src -= adv
                SBC     Y2, #0
                DEC     D3
                BNE.L   .sc_dnloop
                RET

; --------------------------------------------------------------------------
; copy_row -- copy one row src(XY2) -> dst(XY0), advancing both by wb bytes.
;   Uses the precomputed gsc_iters / gsc_rem / gsc_odd. Clobbers D0, D2;
;   preserves D1 (advance), D3 (row counter), XY1.
; --------------------------------------------------------------------------
copy_row:
                LOADP   D2, Y3, [#gsc_iters]
                CMP     D2, #0
                BEQ     .cr_rem
.cr_m8:
                LOADD   D0, [XY2]+
                STORED  D0, [XY0]+
                LOADD   D0, [XY2]+
                STORED  D0, [XY0]+
                LOADD   D0, [XY2]+
                STORED  D0, [XY0]+
                LOADD   D0, [XY2]+
                STORED  D0, [XY0]+
                LOADD   D0, [XY2]+
                STORED  D0, [XY0]+
                LOADD   D0, [XY2]+
                STORED  D0, [XY0]+
                LOADD   D0, [XY2]+
                STORED  D0, [XY0]+
                LOADD   D0, [XY2]+
                STORED  D0, [XY0]+
                DEC     D2
                BNE     .cr_m8
.cr_rem:
                LOADP   D2, Y3, [#gsc_rem]
                CMP     D2, #0
                BEQ     .cr_odd
.cr_rw:
                LOADD   D0, [XY2]+
                STORED  D0, [XY0]+
                DEC     D2
                BNE     .cr_rw
.cr_odd:
                LOADP   D2, Y3, [#gsc_odd]
                CMP     D2, #0
                BEQ     .cr_done
                LOADB   D0, [XY2]+
                STOREB  D0, [XY0]+
.cr_done:
                RET

; --------------------------------------------------------------------------
; sc_addr -- XY0 = byte addr for (gs_x, gs_y) via the descriptor's GS_ADDR
;   helper. Preserves XY1, XY2, D3 (per GS_ADDR contract). Clobbers D0-D2.
; --------------------------------------------------------------------------
sc_addr:
                LOADP   D0, Y3, [#GS_ADDR]
                MOVE    X0, D0
                MOVE    Y0, Y3
                CALLXY  XY0
                RET
