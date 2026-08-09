; ============================================================================
; gfx_8bpp.asm  --  K16 graphics: 8bpp (mode 2) depth back end.
; ----------------------------------------------------------------------------
; Per-depth poke routines reached via the GS_VSPAN/VCLEAR/VTEXT/VPAT/VBLIT
; method vectors that gfx_open points at these labels. Self-contained: these
; call only their own 8bpp helper (gfx_addr8). Include AFTER gfx.asm (front
; end), alongside gfx_1bpp.asm. Requires gfx_defs.inc. Split out of gfx.asm.
; ============================================================================


; ==========================================================================
; vspan_8 -- 8bpp horizontal run (poke method), word-blast middle
;   In:  XY1=desc, D0=x, D1=y, D2=count, D3=idx (in-bounds assumed)
;   Leading byte (if start odd) -> STORED idx:idx words -> trailing byte.
;   Even-aligned words: never straddle a page, satisfy word-mode alignment
;   (same proven pattern as vclear_8). ~2x vs the old byte-per-pixel loop.
;   Clobbers D0-D3,X0,Y0; gs_*/gv_*. Preserves XY1.
; ==========================================================================
vspan_8:
                STOREP  D0, Y3, [#gs_x]
                STOREP  D1, Y3, [#gs_y]
                STOREP  D2, Y3, [#gv_cnt]
                STOREP  D3, Y3, [#gv_idx]
                LOADD   D0, [XY1+#0]            ; FB_PAGE
                STOREP  D0, Y3, [#gs_fbpage]
                CALLR   gfx_addr8               ; XY0 = start addr
                LOADP   D2, Y3, [#gv_cnt]       ; count
                LOADP   D3, Y3, [#gv_idx]
                AND     D3, #$FF                ; idx byte (D3, for byte ends)
                MOVE    D1, D3
                SWAPB   D1
                OR      D1, D3                  ; D1 = idx:idx word
                ; --- leading byte if start addr odd ---
                MOVE    D0, X0
                AND     D0, #1
                CMP     D0, #0                  ; (CMP: don't trust AND flags)
                BEQ     .v8_mid                 ; even start -> middle
                STOREB  D3, [XY0]
                ADD     X0, #1
                BCC     .v8_lnc
                ADD     Y0, #1
.v8_lnc:
                DEC     D2
                BEQ     .v8_done                ; count was exactly 1
.v8_mid:
                ; D2 = remaining pixels; split into words + leftover byte
                MOVE    D0, D2
                AND     D0, #1                  ; D0 = leftover (survives loop)
                SHR     D2                      ; D2 = word count
                CMP     D2, #0
                BEQ     .v8_tail
.v8_wloop:
                STORED  D1, [XY0]+              ; 2 px, even-aligned, +2 (24-bit)
                DEC     D2
                BNE     .v8_wloop
.v8_tail:
                CMP     D0, #0
                BEQ     .v8_done
                STOREB  D3, [XY0]               ; trailing odd pixel
.v8_done:
                RET


; gfx_addr8 -- 8bpp byte addr for (gs_x,gs_y); y*640 = (y<<9)+(y<<7)
;   Out: XY0 = addr. Clobbers D0,D1,D2,X0,Y0.
gfx_addr8:
                ; --- y*640 = (y*160) << 2; y*160 via MULB (160*y_lo + 160*y_hi<<8) ---
                LOADP   D0, Y3, [#gs_y]
                MOVE    D1, D0
                HIGH    D1                      ; y_hi
                LOW     D0                      ; y_lo
                LOADI   D2, #160
                SWAPB   D2
                OR      D0, D2
                MULB    D0                      ; D0 = 160 * y_lo  (P0)
                LOADI   D2, #160
                SWAPB   D2
                OR      D1, D2
                MULB    D1                      ; D1 = 160 * y_hi  (P1)
                MOVE    D2, D1
                LOW     D2
                SWAPB   D2                      ; (P1 low) << 8
                HIGH    D1                      ; P1 high
                ADD     D0, D2
                ADC     D1, #0                  ; D1:D0 = y*160
                ADD     D0, D0
                ADC     D1, D1                  ; y*320
                ADD     D0, D0
                ADC     D1, D1                  ; y*640
                LOADP   D2, Y3, [#gs_x]
                ADD     D0, D2
                ADC     D1, #0
                LOADP   D2, Y3, [#gs_fbpage]
                ADD     D1, D2
                MOVE    X0, D0
                MOVE    Y0, D1
                RET


; ==========================================================================
; vclear_8 -- fast 8bpp whole-surface fill ($4B000), 16x unrolled word-blast
;   In: XY1=desc, D0=idx.  Uses XY2 as end-marker so XY1 is preserved.
;   Clobbers D0,D1,D2,X0,Y0,X2,Y2.
; ==========================================================================
vclear_8:
                AND     D0, #$FF
                MOVE    D2, D0
                SWAPB   D2
                OR      D0, D2                  ; idx:idx
                LOADD   D1, [XY1+#0]            ; FB_PAGE
                MOVE    Y0, D1
                LOADI   X0, #$0000
                MOVE    Y2, D1
                ADD     Y2, #4
                LOADI   X2, #$B000              ; end (page+4):B000
                ; 16-word blast; [XY0]+ default stride 2, 24-bit carry in HW
.c8_loop:
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
                BLO     .c8_loop
                CMP     X0, X2
                BLO     .c8_loop
                RET


; ==========================================================================
; vtext_8 -- 8bpp glyph-row poke (F3). Paints fg where rowbits set; clear
;   bits untouched (transparent). Pure poke: bounds AND region are folded
;   into rowbits by the caller (_fn_rowmask), so this routine is bounds- and
;   region-blind. One CALLXY per glyph row replaces up to 8 gfx_setpixel.
;   In:  XY1=desc, D0=x (>=0), D1=y (in-bounds), D2=rowbits (low 8, MSB=col0,
;        already masked), D3=fg.  Preserves XY1.  Clobbers D0-D3,X0,Y0; gs_*/gv_*.
; ==========================================================================
vtext_8:
                MOVE    Y0, Y2                   ; XY0 = leftmost FB byte (caller's XY2)
                MOVE    X0, X2
                AND     D3, #$FF
                STOREP  D3, Y3, [#gv_idx]       ; fg byte
                MOVE    D3, D2                   ; rowbits -> D3
                LOADP   D0, Y3, [#fn_wide]       ; F4-wide: 16 cols (bit15=col0)?
                CMP     D0, #0
                BNE     .vt8_wide
                AND     D3, #$FF
                LOADI   D1, #$80                 ; col0 = bit7 (MSB = leftmost)
                LOADI   D2, #8                   ; 8 columns
                BRA     .vt8_loop
.vt8_wide:
                LOADI   D1, #$8000               ; col0 = bit15
                LOADI   D2, #16                  ; 16 columns
.vt8_loop:
                MOVE    D0, D3
                AND     D0, D1
                CMP     D0, #0                   ; (don't trust AND flags)
                BEQ     .vt8_skip                ; clear/masked bit -> advance only
                LOADP   D0, Y3, [#gv_idx]
                STOREB  D0, [XY0]+               ; store fg + advance (24-bit)
                BRA     .vt8_col
.vt8_skip:
                INC     XY0, #1                  ; advance only (flag-transparent)
.vt8_col:
                SHR     D1                       ; next column bit
                DEC     D2
                BNE     .vt8_loop
                RET


; ==========================================================================
; vpat_8 -- 8bpp patterned run. Each pixel = gp_fg where the pattern bit is
;   set, else gp_bg. Per-pixel walk (pattern is not the 8bpp hot path; the
;   1bpp desktop is). Column bit = $80 >> (x&7), wraps to $80 every 8 px.
;   In: XY1=desc, D0=x, D1=y, D2=count, D3=patrow.  Preserves XY1.
;   Clobbers D0-D3,X0,Y0; gs_*/gv_*/gp_patrow.
; ==========================================================================
vpat_8:
                STOREP  D0, Y3, [#gs_x]
                STOREP  D1, Y3, [#gs_y]
                STOREP  D2, Y3, [#gv_cnt]
                AND     D3, #$FF
                STOREP  D3, Y3, [#gp_patrow]
                LOADD   D0, [XY1+#0]            ; FB_PAGE
                STOREP  D0, Y3, [#gs_fbpage]
                CALLR   gfx_addr8               ; XY0 = start byte addr
                LOADP   D0, Y3, [#gs_x]
                AND     D0, #7
                LOADI   D1, #$80                ; column bit (MSB = leftmost)
.vp8_bsh:
                CMP     D0, #0
                BEQ     .vp8_bshd
                SHR     D1
                DEC     D0
                BRA     .vp8_bsh
.vp8_bshd:
                LOADP   D3, Y3, [#gv_cnt]       ; D3 = pixel counter
                CMP     D3, #0
                BLE     .vp8_done
.vp8_loop:
                LOADP   D2, Y3, [#gp_patrow]
                MOVE    D0, D2
                AND     D0, D1                  ; pattern bit at this column?
                CMP     D0, #0                  ; (don't trust AND flags)
                BEQ     .vp8_bg
                LOADP   D0, Y3, [#gp_fg]
                BRA     .vp8_put
.vp8_bg:
                LOADP   D0, Y3, [#gp_bg]
.vp8_put:
                AND     D0, #$FF
                STOREB  D0, [XY0]+              ; store + advance (24-bit)
                SHR     D1                      ; next column bit
                CMP     D1, #0
                BNE     .vp8_keep
                LOADI   D1, #$80                ; wrapped -> next 8-block
.vp8_keep:
                DEC     D3
                BNE     .vp8_loop
.vp8_done:
                RET


; ==========================================================================
; vblit_8 -- 8bpp-dest row of a 1bpp mask. Walks visw columns; source bit set
;   -> Or/Copy write gb_fg, Xor writes (dest^gb_fg); clear -> Copy writes
;   gb_bg, Or/Xor skip. In: XY1=desc, D0=x, D1=py, D2=visw; src row gb_row_*.
;   Preserves XY1.  Clobbers D0-D3,X0,Y0,X2,Y2; gs_*/gv_*.
; ==========================================================================
vblit_8:
                STOREP  D0, Y3, [#gs_x]
                STOREP  D1, Y3, [#gs_y]
                STOREP  D2, Y3, [#gv_cnt]
                LOADD   D0, [XY1+#0]
                STOREP  D0, Y3, [#gs_fbpage]
                CALLR   gfx_addr8                ; XY0 = dest byte
                LOADP   D0, Y3, [#gb_row_pg]     ; XY2 = source row
                MOVE    Y2, D0
                LOADP   D0, Y3, [#gb_row_of]
                MOVE    X2, D0
                LOADI   D1, #$80                 ; source bit (col 0 = MSB)
.bl8_loop:
                LOADP   D0, Y3, [#gv_cnt]
                CMP     D0, #0
                BLE     .bl8_done
                LOADB   D3, [XY2]
                AND     D3, D1                   ; source bit set?
                CMP     D3, #0
                BEQ     .bl8_clr
                ; source set
                LOADP   D3, Y3, [#gb_mode]
                CMP     D3, #2
                BEQ     .bl8_xor
                LOADP   D0, Y3, [#gb_fg]         ; Or/Copy: write fg
                AND     D0, #$FF
                STOREB  D0, [XY0]+               ; store + advance
                BRA     .bl8_dnc
.bl8_xor:
                LOADB   D0, [XY0]
                LOADP   D3, Y3, [#gb_fg]
                XOR     D0, D3
                AND     D0, #$FF
                STOREB  D0, [XY0]+               ; store + advance
                BRA     .bl8_dnc
.bl8_clr:
                LOADP   D3, Y3, [#gb_mode]       ; source clear
                CMP     D3, #1
                BNE     .bl8_skip                ; not Copy -> skip (no store)
                LOADP   D0, Y3, [#gb_bg]         ; Copy: write bg
                AND     D0, #$FF
                STOREB  D0, [XY0]+               ; store + advance
                BRA     .bl8_dnc
.bl8_skip:
                INC     XY0, #1                  ; transparent: advance only
.bl8_dnc:
                SHR     D1                       ; next source bit
                CMP     D1, #0
                BNE     .bl8_keep
                LOADI   D1, #$80                 ; wrapped -> next source byte
                INC     XY2, #1                  ; next source byte
.bl8_keep:
                LOADP   D0, Y3, [#gv_cnt]
                SUB     D0, #1
                STOREP  D0, Y3, [#gv_cnt]
                BRA     .bl8_loop
.bl8_done:
                RET
