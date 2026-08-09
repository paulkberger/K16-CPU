; ============================================================================
; gfx_font.asm  --  KGFX font layer: routine code (F1a, polish r2)
; ----------------------------------------------------------------------------
; Include AFTER the program body, alongside gfx.asm (forward CALLR to
; gfx_setpixel / gfx_fillrect; the two-pass assembler resolves them).
; Requires gfx_font_defs.inc and gfx_defs.inc.
;
; Public API (unchanged; all take the surface descriptor in XY1, preserve XY1):
;   gfx_setfont            XY0 = font descriptor ptr (Y0=page, X0=offset)
;   gfx_draw_char          D0=x D1=y D2=ch  D3=fg                  transparent
;   gfx_draw_char_opaque   D0=x D1=y D2=ch  D3=(bg<<8)|fg          opaque
;   gfx_draw_string        XY0=strptr D0=x D1=y  D3=fg             transparent
;   gfx_draw_string_opaque XY0=strptr D0=x D1=y  D3=(bg<<8)|fg     opaque
;
; r2 changes (faster + tighter, same API):
;   * gfx_setfont CACHES geometry (w/h/advance/first/last/bits) into FNT_BSS.
;     The per-char path never re-reads the descriptor. Call setfont AFTER any
;     descriptor edit (e.g. patching FNT_BITS_*).
;   * Opaque = one clipped gfx_fillrect of the advance-wide cell in bg, then
;     the transparent renderer paints fg on top. The inner loop only ever
;     plots set bits -- no per-pixel bg branch. (Clobbers the gr_* block.)
;   * _fn_blit skips empty rows (rowbits==0) wholesale, and out-of-range chars
;     return immediately (opaque cell already bg-filled).
;
; F3 (row-blit): the per-pixel inner loop is gone. _fn_blit now folds region +
; right/bottom bounds into a byte mask (_fn_rowmask) and dispatches ONE CALLXY
; per glyph row to the surface's depth vtext (GS_VTEXT: vtext_8 / vtext_1).
; Clip is tested once per row, not per pixel. fn_x<0 coarse-skips the glyph
; (no left-edge clip yet). All loop state lives in FNT_BSS (vtext clobbers
; D0-D3/X0/Y0 but preserves XY1 and never touches Y3).
;
; F4 (proportional): if FNT_FLAGS bit FNT_FL_PROP is set, gfx_setfont caches the
; WTAB/OTAB base pointers (bits_base + FNT_WTAB / +FNT_OTAB) and _fn_setup looks
; up this char's advance w[c] (-> fn_cw) and signed left bearing o[c] (image
; drawn at fn_dx = fn_x + o[c]; pen still advances by w[c]). The render path
; reads fn_dx (image origin) while the pen/string origin stays in fn_x, so
; offset positions the glyph and width drives the pen (QuickDraw split). fn_w
; (cols scanned) stays the cell width; mono fonts take the fn_cw=fn_adv default
; and are bit-identical to F3.
; ============================================================================

; ==========================================================================
; gfx_setfont -- set the current font AND cache its geometry ("compile").
;   In:  XY1=desc, XY0 = font desc ptr (Y0=page, X0=offset). Y0=0 clears it.
;   Out: GS_FONT_PG/OF stored; fn_w/h/adv/first/last/bits cached.
;        Preserves XY1. Clobbers D0.
; ==========================================================================
gfx_setfont:
                MOVE    D0, Y0
                STOREP  D0, Y3, [#GS_FONT_PG]
                MOVE    D0, X0
                STOREP  D0, Y3, [#GS_FONT_OF]
                ; cache geometry from the font descriptor (XY0)
                LOADD   D0, [XY0+#FNT_WIDTH]
                STOREP  D0, Y3, [#fn_w]
                LOADI   D1, #0                   ; F4-wide: fn_wide = (FNT_WIDTH > 8)
                CMP     D0, #8
                BLE     .sf_nw
                LOADI   D1, #1
.sf_nw:
                STOREP  D1, Y3, [#fn_wide]
                LOADD   D0, [XY0+#FNT_HEIGHT]
                STOREP  D0, Y3, [#fn_h]
                LOADD   D0, [XY0+#FNT_ADVANCE]
                STOREP  D0, Y3, [#fn_adv]
                LOADD   D0, [XY0+#FNT_FIRST]
                STOREP  D0, Y3, [#fn_first]
                LOADD   D0, [XY0+#FNT_LAST]
                STOREP  D0, Y3, [#fn_last]
                LOADD   D0, [XY0+#FNT_BITS_PG]
                STOREP  D0, Y3, [#fn_bits_pg]
                LOADD   D0, [XY0+#FNT_BITS_OF]
                STOREP  D0, Y3, [#fn_bits_of]
                ; F4: proportional flag + table bases (bits_base + FNT_WTAB/OTAB)
                LOADD   D0, [XY0+#FNT_FLAGS]
                AND     D0, #FNT_FL_PROP
                STOREP  D0, Y3, [#fn_prop]
                CMP     D0, #0                   ; AND is flag-transparent
                BEQ     .sf_noprop
                LOADP   D2, Y3, [#fn_bits_of]    ; wtab base = bits + FNT_WTAB
                LOADP   D3, Y3, [#fn_bits_pg]
                LOADD   D0, [XY0+#FNT_WTAB]
                ADD     D2, D0
                ADC     D3, #0
                STOREP  D2, Y3, [#fn_wtab_of]
                STOREP  D3, Y3, [#fn_wtab_pg]
                LOADP   D2, Y3, [#fn_bits_of]    ; otab base = bits + FNT_OTAB
                LOADP   D3, Y3, [#fn_bits_pg]
                LOADD   D0, [XY0+#FNT_OTAB]
                ADD     D2, D0
                ADC     D3, #0
                STOREP  D2, Y3, [#fn_otab_of]
                STOREP  D3, Y3, [#fn_otab_pg]
.sf_noprop:
                LOADP   D0, Y3, [#GS_FSCALE]     ; cache current scale (1 if unset by open)
                CMP     D0, #1
                BGE     .sf_sc_ok
                LOADI   D0, #1
.sf_sc_ok:
                STOREP  D0, Y3, [#fn_scale]
                LOADI   D0, #0                   ; default style = normal
                STOREP  D0, Y3, [#fn_style]      ; (set bold etc. AFTER gfx_setfont)
                RET

; ==========================================================================
; gfx_setfontscale -- set integer font scale (1=1x, 2=2x, ...). Affects
;   subsequent draw_char/string: glyphs render as scale x scale blocks and
;   the pen advance scales. scale 1 uses the fast vtext row-blit; scale >= 2
;   renders via clipped gfx_fillrect blocks (clip/bounds/depth inherited).
;   In: XY1=desc, D0=scale.  Stores GS_FSCALE + fn_scale.  Preserves XY1.
; ==========================================================================
gfx_setfontscale:
                CMP     D0, #1
                BGE     .sfs_ok
                LOADI   D0, #1                   ; clamp >= 1
.sfs_ok:
                STOREP  D0, Y3, [#GS_FSCALE]
                STOREP  D0, Y3, [#fn_scale]
                RET

; ==========================================================================
; gfx_setfontstyle -- set synthesized style bits (FS_BOLD, ...). Normal = 0.
;   Style is renderer-applied (no strike data); persists until changed, but
;   gfx_setfont resets it to normal -- so call this AFTER gfx_setfont.
;   In: XY1=desc, D0=style.  Stores fn_style.  Preserves XY1.
; ==========================================================================
gfx_setfontstyle:
                STOREP  D0, Y3, [#fn_style]
                RET

; ==========================================================================
; gfx_draw_char -- transparent: paint the glyph's set bits in fg.
;   In: XY1=desc, D0=x, D1=y, D2=ch, D3=fg.  Preserves XY1.
; ==========================================================================
gfx_draw_char:
                STOREP  D0, Y3, [#fn_x]
                STOREP  D1, Y3, [#fn_y]
                STOREP  D2, Y3, [#fn_char]
                AND     D3, #$FF
                STOREP  D3, Y3, [#fn_fg]
                CALLR   _fn_setup
                BCS     .dc_ret                  ; no font -> no-op
                CALLR   _fn_blit
.dc_ret:
                RET

; ==========================================================================
; gfx_draw_char_opaque -- fill the cell with bg, then paint fg on top.
;   In: XY1=desc, D0=x, D1=y, D2=ch, D3=(bg<<8)|fg.  Preserves XY1.
;   Clobbers the gr_* fillrect param block.
; ==========================================================================
gfx_draw_char_opaque:
                STOREP  D0, Y3, [#fn_x]
                STOREP  D1, Y3, [#fn_y]
                STOREP  D2, Y3, [#fn_char]
                MOVE    D0, D3
                AND     D0, #$FF                 ; fg = low byte
                STOREP  D0, Y3, [#fn_fg]
                MOVE    D0, D3
                SWAPB   D0                        ; bg into low byte
                AND     D0, #$FF
                STOREP  D0, Y3, [#fn_bg]
                CALLR   _fn_setup
                BCS     .dco_ret                 ; no font -> no-op
                ; fill the advance-wide cell with bg (clip-aware), scaled
                LOADP   D0, Y3, [#fn_x]
                STOREP  D0, Y3, [#gr_x]
                LOADP   D0, Y3, [#fn_y]
                STOREP  D0, Y3, [#gr_y]
                LOADP   D0, Y3, [#fn_cw]
                CALLR   _fn_mulscale             ; D0 = fn_cw * fn_scale
                STOREP  D0, Y3, [#gr_w]
                LOADP   D0, Y3, [#fn_h]
                CALLR   _fn_mulscale             ; D0 = fn_h * fn_scale
                STOREP  D0, Y3, [#gr_h]
                LOADP   D0, Y3, [#fn_bg]
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_fillrect             ; bg cell (honours GS_CLIP)
                CALLR   _fn_blit                 ; fg set-bits on top
.dco_ret:
                RET

; ==========================================================================
; _fn_setup -- per-char prep using CACHED geometry. Sets fn_oor and (if in
;   range) the glyph row pointer fn_gp_pg/of for fn_char.
;   Out: C=1 if no font set (caller no-ops); C=0 otherwise (fn_oor valid).
;   Clobbers D0-D3, X0, Y0.
; ==========================================================================
_fn_setup:
                LOADP   D0, Y3, [#GS_FONT_PG]
                CMP     D0, #0
                BEQ     .su_nofont
                LOADI   D1, #0
                STOREP  D1, Y3, [#fn_oor]
                LOADP   D0, Y3, [#fn_adv]        ; F4: default advance (mono / OOR)
                STOREP  D0, Y3, [#fn_cw]
                LOADP   D1, Y3, [#fn_char]
                LOADP   D2, Y3, [#fn_first]
                CMP     D1, D2
                BLT     .su_oor                  ; char < first
                LOADP   D2, Y3, [#fn_last]
                CMP     D1, D2
                BLE     .su_glyph                ; char <= last -> in range
.su_oor:
                LOADI   D1, #1
                STOREP  D1, Y3, [#fn_oor]
                CLC                              ; font present, char OOR
                RET
.su_glyph:
                ; glyph row0 = fn_bits + (char - first) * FNT_HEIGHT
                ;   (1 byte/row for w<=8; the >8px width path must use fn_h*2)
                LOADP   D2, Y3, [#fn_bits_of]
                LOADP   D3, Y3, [#fn_bits_pg]
                LOADP   D0, Y3, [#fn_char]
                LOADP   D1, Y3, [#fn_first]
                SUB     D0, D1                    ; char - first (low byte, hi=0)
                LOADP   D1, Y3, [#fn_h]           ; row stride = FNT_HEIGHT
                SWAPB   D1                        ; height into high byte
                OR      D0, D1                    ; D0 = (fn_h<<8) | (char-first)
                MULB    D0                        ; D0 = (char - first) * fn_h
                LOADP   D1, Y3, [#fn_wide]        ; F4-wide: word/row -> x2 stride
                CMP     D1, #0
                BEQ     .su_nstride
                SHL     D0                        ; 2 bytes/row
.su_nstride:
                ADD     D2, D0
                ADC     D3, #0                    ; carry -> page
                STOREP  D2, Y3, [#fn_gp_of]
                STOREP  D3, Y3, [#fn_gp_pg]
                ; F4: default image origin = pen; mono keeps fn_cw=fn_adv default
                LOADP   D0, Y3, [#fn_x]
                STOREP  D0, Y3, [#fn_dx]
                LOADP   D0, Y3, [#fn_prop]
                CMP     D0, #0
                BEQ     .su_done                 ; mono -> defaults already set
                ; --- proportional: per-char advance w[c] + signed bearing o[c] ---
                LOADP   D0, Y3, [#fn_char]
                LOADP   D1, Y3, [#fn_first]
                SUB     D0, D1                   ; D0 = idx (kept across both lookups)
                LOADP   D2, Y3, [#fn_wtab_of]    ; w[c] = wtab[idx]
                LOADP   D3, Y3, [#fn_wtab_pg]
                ADD     D2, D0
                ADC     D3, #0
                MOVE    Y0, D3
                MOVE    X0, D2
                LOADB   D1, [XY0]
                AND     D1, #$FF
                STOREP  D1, Y3, [#fn_cw]         ; advance = w[c]
                LOADP   D2, Y3, [#fn_otab_of]    ; o[c] = otab[idx]
                LOADP   D3, Y3, [#fn_otab_pg]
                ADD     D2, D0
                ADC     D3, #0
                MOVE    Y0, D3
                MOVE    X0, D2
                LOADB   D1, [XY0]
                AND     D1, #$FF
                MOVE    D0, D1                   ; sign-extend signed byte
                AND     D0, #$80                 ; bit7? (AND flag-transparent)
                CMP     D0, #0
                BEQ     .su_osext
                OR      D1, #$FF00               ; negative bearing -> $FFxx
.su_osext:
                LOADP   D0, Y3, [#fn_x]          ; fn_dx = fn_x + o[c]
                ADD     D0, D1
                STOREP  D0, Y3, [#fn_dx]
.su_done:
                CLC
                RET
.su_nofont:
                SEC
                RET

; ==========================================================================
; _fn_blit -- F3 row-blit: per glyph row, fold region+bounds into a byte mask
;   (_fn_rowmask), AND it into the row bits, and dispatch one CALLXY to the
;   surface's depth vtext (GS_VTEXT). Replaces the per-pixel gfx_setpixel
;   loop: clip is tested once per row, not per pixel. Transparent only
;   (opaque cell-fill ran first in gfx_draw_char_opaque). Assumes _fn_setup
;   ran. OOR / empty rows / off-screen rows skipped. fn_x<0 coarse-skips the
;   glyph (F3 scope: no left-edge clip).
;   Preserves XY1; clobbers D0-D3, X0, Y0.
; ==========================================================================
_fn_blit:
                LOADP   D0, Y3, [#fn_oor]
                CMP     D0, #0
                BNE     .bl_ret                  ; OOR -> nothing (cell already bg if opaque)
                LOADP   D0, Y3, [#fn_dx]
                CMP     D0, #0
                BLT     .bl_ret                  ; off left edge -> coarse skip (F3 scope)
                LOADP   D0, Y3, [#fn_scale]
                CMP     D0, #2
                BLT     .bl_1x                   ; scale 1 -> fast row-blit
                BRA     _fn_blit_scaled          ; scale >= 2 -> fillrect blocks
.bl_1x:
                ; --- visible-row clamp: start = max(0,-fn_y); end = min(fn_h, H-fn_y) ---
                LOADP   D0, Y3, [#fn_y]
                LOADI   D1, #0                   ; start_row = 0 (fn_y >= 0)
                CMP     D0, #0
                BGE     .bl_st0
                LOADI   D1, #0                   ; fn_y < 0: start_row = -fn_y
                SUB     D1, D0
.bl_st0:
                STOREP  D1, Y3, [#fn_row]        ; loop counter starts at start_row
                LOADD   D2, [XY1+#GSO_HEIGHT]
                LOADP   D0, Y3, [#fn_y]
                CMP     D2, D0                   ; H vs fn_y
                BLE     .bl_ret                  ; fn_y >= H -> glyph fully below
                SUB     D2, D0                   ; H - fn_y  (> 0)
                LOADP   D3, Y3, [#fn_h]
                CMP     D2, D3
                BLE     .bl_endok                ; (H-fn_y) <= fn_h -> use it
                MOVE    D2, D3                   ; else clamp to glyph height
.bl_endok:
                STOREP  D2, Y3, [#fn_end]        ; end row (exclusive)
                CMP     D1, D2
                BGE     .bl_ret                  ; start >= end -> nothing visible
                ; --- pre-skip glyph rows by start_row (D1) ---
                LOADP   D2, Y3, [#fn_wide]        ; F4-wide: skip 2 bytes/row
                CMP     D2, #0
                BEQ     .bl_gpsk_n1
                SHL     D1                        ; start_row * 2
.bl_gpsk_n1:
                LOADP   D0, Y3, [#fn_gp_of]
                ADD     D0, D1
                STOREP  D0, Y3, [#fn_gp_of]
                BCC     .bl_gpsk_nc
                LOADP   D0, Y3, [#fn_gp_pg]
                ADD     D0, #1
                STOREP  D0, Y3, [#fn_gp_pg]
.bl_gpsk_nc:
                ; --- row-0 FB byte address (computed once), held in XY2 ---
                LOADP   D0, Y3, [#fn_dx]
                STOREP  D0, Y3, [#gs_x]          ; gs_x = fn_dx (also read by vtext_1 shift)
                LOADD   D0, [XY1+#0]
                STOREP  D0, Y3, [#gs_fbpage]
                LOADP   D0, Y3, [#fn_y]
                LOADP   D1, Y3, [#fn_row]
                ADD     D0, D1                   ; py_start = fn_y + start_row
                STOREP  D0, Y3, [#gs_y]
                LOADP   D0, Y3, [#GS_ADDR]       ; depth addr routine offset (page = Y3)
                MOVE    X0, D0
                MOVE    Y0, Y3
                CALLXY  XY0                      ; -> XY0 = leftmost byte (preserves XY1,XY2,D3)
                MOVE    Y2, Y0                   ; XY2 = running FB row pointer
                MOVE    X2, X0
                ; precompute MULB multiplier for the row-blit shift: 1<<(8-s) in hi byte
                ; (s = fn_dx & 7, constant across the glyph's rows; s==0 unused by vtext_1)
                LOADP   D0, Y3, [#fn_dx]
                AND     D0, #7                   ; s
                LOADI   D1, #$0100
.bl_mloop:
                CMP     D0, #0
                BEQ     .bl_mdone
                SHR     D1                       ; $0100 >> s  =  1<<(8-s)
                DEC     D0
                BRA     .bl_mloop
.bl_mdone:
                SWAPB   D1                        ; multiplier into high byte
                STOREP  D1, Y3, [#fn_mult]
.bl_row:
                LOADP   D0, Y3, [#fn_row]
                LOADP   D1, Y3, [#fn_end]
                CMP     D0, D1
                BGE     .bl_ret
                ; rowbits (glyph ptr in TLS; XY2 = FB ptr preserved across the row)
                LOADP   D0, Y3, [#fn_gp_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#fn_gp_of]
                MOVE    X0, D0
                LOADP   D1, Y3, [#fn_wide]        ; F4-wide: word/row fetch
                CMP     D1, #0
                BEQ     .bl_fb
                LOADD   D0, [XY0]                 ; 16-bit rowbits (bit15=col0)
                BRA     .bl_fd
.bl_fb:
                LOADB   D0, [XY0]                 ; 8-bit rowbits (bit7=col0)
.bl_fd:
                LOADP   D1, Y3, [#fn_style]      ; FS_BOLD? smear stroke 1px right
                AND     D1, #FS_BOLD
                CMP     D1, #0                   ; (don't trust AND flags)
                BEQ     .bl_nobold
                MOVE    D1, D0
                SHR     D1                       ; bit7=leftmost -> SHR = 1px right
                OR      D0, D1                   ; stroke + 1px right shadow
.bl_nobold:
                STOREP  D0, Y3, [#fn_rowbits]
                CMP     D0, #0
                BEQ     .bl_next                 ; empty glyph row -> advance only
                ; py = fn_y + row (already in range by clamp -> no per-row bounds test)
                LOADP   D0, Y3, [#fn_y]
                LOADP   D1, Y3, [#fn_row]
                ADD     D0, D1
                STOREP  D0, Y3, [#fn_py]
                ; visible-columns mask (region n bounds), AND into rowbits
                CALLR   _fn_rowmask              ; D0 = mask; preserves XY1,XY2
                LOADP   D1, Y3, [#fn_rowbits]
                AND     D0, D1
                CMP     D0, #0                   ; (don't trust AND flags)
                BEQ     .bl_next                 ; nothing visible this row
                STOREP  D0, Y3, [#fn_rowbits]    ; masked rowbits
                ; dispatch depth vtext: FB ptr in XY2, gs_x=fn_dx, D2=rowbits, D3=fg
                LOADP   D2, Y3, [#fn_rowbits]
                LOADP   D3, Y3, [#fn_fg]
                LOADX   X0, [XY1+#GSO_VTEXT]
                MOVE    Y0, Y3
                CALLXY  XY0                      ; vtext_8 / vtext_1 (preserves XY1,XY2)
.bl_next:
                ; advance FB row pointer (XY2) by GS_PITCH (160/640; 24-bit)
                LOADP   D0, Y3, [#GS_PITCH]
                MOVE    D1, X2
                ADD     D1, D0
                MOVE    X2, D1
                BCC     .bl_padv_nc
                ADD     Y2, #1
.bl_padv_nc:
                ; advance glyph row pointer (+1 narrow / +2 wide, carry to page)
                LOADP   D1, Y3, [#fn_wide]        ; F4-wide: bytes/row = 1 + wide
                ADD     D1, #1
                LOADP   D0, Y3, [#fn_gp_of]
                ADD     D0, D1
                STOREP  D0, Y3, [#fn_gp_of]
                BCC     .bl_gnc
                LOADP   D0, Y3, [#fn_gp_pg]
                ADD     D0, #1
                STOREP  D0, Y3, [#fn_gp_pg]
.bl_gnc:
                LOADP   D0, Y3, [#fn_row]
                ADD     D0, #1
                STOREP  D0, Y3, [#fn_row]
                BRA     .bl_row
.bl_ret:
                RET

; ==========================================================================
; gfx_draw_string / gfx_draw_string_opaque -- NUL-terminated string, pen
;   advances by fn_adv per char. Single-line (F1a).
;   In: XY1=desc, XY0=str ptr (Y0=page,X0=offset), D0=x, D1=y;
;       D3=fg (transparent) or D3=(bg<<8)|fg (opaque).  Preserves XY1.
; ==========================================================================
gfx_draw_string:
                MOVE    D2, Y0
                STOREP  D2, Y3, [#fn_str_pg]
                MOVE    D2, X0
                STOREP  D2, Y3, [#fn_str_of]
                STOREP  D0, Y3, [#fn_x]
                STOREP  D1, Y3, [#fn_y]
                STOREP  D3, Y3, [#fn_sfg]
                LOADI   D0, #0
                STOREP  D0, Y3, [#fn_sopaque]
                BRA     _fn_string_run

gfx_draw_string_opaque:
                MOVE    D2, Y0
                STOREP  D2, Y3, [#fn_str_pg]
                MOVE    D2, X0
                STOREP  D2, Y3, [#fn_str_of]
                STOREP  D0, Y3, [#fn_x]
                STOREP  D1, Y3, [#fn_y]
                STOREP  D3, Y3, [#fn_sfg]
                LOADI   D0, #1
                STOREP  D0, Y3, [#fn_sopaque]

_fn_string_run:
                LOADP   D0, Y3, [#GS_FONT_PG]
                CMP     D0, #0
                BEQ     .sr_done                 ; no font -> nothing
.sr_loop:
                LOADP   D0, Y3, [#fn_str_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#fn_str_of]
                MOVE    X0, D0
                LOADB   D0, [XY0]
                CMP     D0, #0
                BEQ     .sr_done
                STOREP  D0, Y3, [#fn_tmpch]
                LOADP   D0, Y3, [#fn_sopaque]
                CMP     D0, #0
                BNE     .sr_op
                ; transparent
                LOADP   D0, Y3, [#fn_x]
                LOADP   D1, Y3, [#fn_y]
                LOADP   D2, Y3, [#fn_tmpch]
                LOADP   D3, Y3, [#fn_sfg]
                CALLR   gfx_draw_char
                BRA     .sr_adv
.sr_op:
                LOADP   D0, Y3, [#fn_x]
                LOADP   D1, Y3, [#fn_y]
                LOADP   D2, Y3, [#fn_tmpch]
                LOADP   D3, Y3, [#fn_sfg]
                CALLR   gfx_draw_char_opaque
.sr_adv:
                LOADP   D0, Y3, [#fn_cw]
                CALLR   _fn_mulscale             ; D0 = fn_cw * fn_scale
                MOVE    D1, D0                   ; scaled advance
                LOADP   D0, Y3, [#fn_x]
                ADD     D0, D1
                STOREP  D0, Y3, [#fn_x]
                LOADP   D0, Y3, [#fn_str_of]
                ADD     D0, #1
                STOREP  D0, Y3, [#fn_str_of]
                BCC     .sr_loop
                LOADP   D0, Y3, [#fn_str_pg]
                ADD     D0, #1
                STOREP  D0, Y3, [#fn_str_pg]
                BRA     .sr_loop
.sr_done:
                RET

; ==========================================================================
; _fn_rowmask -- build the visible-columns byte mask for the current row,
;   folding surface RIGHT/width bounds AND the GS_CLIP region into one byte.
;   Bit 7 = leftmost column (= fn_x); bit (7-k) = column fn_x+k. The caller
;   ANDs this into the glyph row bits so the depth vtext stays a pure poke.
;   Assumes fn_x>=0 and fn_py already bounds-checked.
;   In:  XY1=desc; reads fn_x/fn_w/fn_py + GSO_WIDTH/GSO_CLIP.
;   Out: D0 = mask.  Preserves XY1.  Clobbers D0-D3, X0, Y0; fn_rowmask/clo/chi/acc.
; ==========================================================================
_fn_rowmask:
                ; bcount = min(fn_w, max(0, width - fn_x))
                LOADD   D0, [XY1+#GSO_WIDTH]
                LOADP   D1, Y3, [#fn_dx]
                SUB     D0, D1                   ; width - fn_dx
                BGE     .rm_wpos                 ; >=0 ?
                LOADI   D0, #0                   ; glyph fully off the right
.rm_wpos:
                LOADP   D1, Y3, [#fn_w]
                CMP     D0, D1
                BLE     .rm_bc                   ; (width-fn_x) <= fn_w -> use it
                MOVE    D0, D1                   ; else clamp to glyph width
.rm_bc:
                CALLR   _topbits_w               ; D2 = bound_mask = topbits(bcount)
                STOREP  D2, Y3, [#fn_rowmask]
                ; clip region?
                LOADD   D3, [XY1+#GSO_CLIP_PG]
                CMP     D3, #0
                BNE     .rm_clip
                LOADP   D0, Y3, [#fn_rowmask]    ; no clip -> just the bound mask
                RET
.rm_clip:
                MOVE    Y0, D3                   ; clip region page
                LOADD   D3, [XY1+#GSO_CLIP_OF]
                MOVE    X0, D3                   ; XY0 = clip region ptr
                LOADP   D0, Y3, [#fn_py]
                PUSH    XY1, XY3                 ; save descriptor
                CALLR   rgn_band_at              ; XY1=band, C=0/1; clobbers D1-3,XY1
                BCS     .rm_noband
                MOVE    Y0, Y1                   ; XY0 = band cursor
                MOVE    X0, X1
                POP     XY1, XY3                 ; restore descriptor
                LOADD   D2, [XY0+#BND_NX]        ; coord count (pairs*2)
                STOREP  D2, Y3, [#frc_nx]
                MOVE    D3, X0
                ADD     D3, #BND_X0              ; advance cursor to first x-coord
                MOVE    X0, D3
                LOADI   D0, #0
                STOREP  D0, Y3, [#fn_acc]        ; region accumulator
.rm_iloop:
                LOADP   D2, Y3, [#frc_nx]
                CMP     D2, #0
                BLE     .rm_iacc
                LOADD   D0, [XY0+#0]             ; cx0
                LOADD   D1, [XY0+#2]             ; cx1
                ; clip sub-span to [fn_x, fn_x+fn_w)
                LOADP   D3, Y3, [#fn_dx]
                CMP     D0, D3
                BGE     .rm_clo                  ; cx0 >= fn_dx
                MOVE    D0, D3                   ; lo = fn_x
.rm_clo:
                LOADP   D3, Y3, [#fn_dx]
                LOADP   D2, Y3, [#fn_w]
                ADD     D3, D2                   ; fn_dx+fn_w (right, exclusive)
                CMP     D1, D3
                BLE     .rm_chi                  ; cx1 <= right
                MOVE    D1, D3                   ; hi = right
.rm_chi:
                LOADP   D3, Y3, [#fn_dx]
                SUB     D0, D3                   ; col_lo = lo - fn_dx
                SUB     D1, D3                   ; col_hi = hi - fn_dx
                CMP     D0, D1
                BGE     .rm_inext                ; empty sub-span -> skip
                STOREP  D0, Y3, [#fn_clo]
                STOREP  D1, Y3, [#fn_chi]
                ; run = topbits(col_hi) XOR topbits(col_lo)  (M(lo) subset M(hi))
                LOADP   D0, Y3, [#fn_chi]
                CALLR   _topbits_w               ; D2 = M(col_hi)
                STOREP  D2, Y3, [#fn_chi]        ; stash M(hi) (col_hi no longer needed)
                LOADP   D0, Y3, [#fn_clo]
                CALLR   _topbits_w               ; D2 = M(col_lo)
                LOADP   D0, Y3, [#fn_chi]        ; M(hi)
                XOR     D0, D2                   ; run bits
                LOADP   D1, Y3, [#fn_acc]
                OR      D1, D0
                STOREP  D1, Y3, [#fn_acc]
.rm_inext:
                MOVE    D3, X0                   ; cursor += 4 (next interval)
                ADD     D3, #4
                MOVE    X0, D3
                LOADP   D2, Y3, [#frc_nx]
                SUB     D2, #2
                STOREP  D2, Y3, [#frc_nx]
                BRA     .rm_iloop
.rm_iacc:
                LOADP   D0, Y3, [#fn_rowmask]    ; bound mask
                LOADP   D1, Y3, [#fn_acc]        ; region mask
                AND     D0, D1                   ; region n bounds
                RET
.rm_noband:
                POP     XY1, XY3                 ; restore descriptor (nothing visible)
                LOADI   D0, #0
                RET

; ==========================================================================
; _topbits_w -- mask with the top N bits set, width-selected by fn_wide.
;   narrow (fn_wide=0): byte mask, bit7 first, N=0..8 (topbits_lut).
;   wide   (fn_wide=1): word mask, bit15 first, N=0..16 (topbits16_lut).
;   In: D0 = N.  Out: D2 = mask.  Clobbers D0,D1,D2.
; ==========================================================================
_topbits_w:
                PUSH    XY0, XY3                 ; preserve caller's XY0 (region cursor)
                LOADP   D2, Y3, [#fn_wide]       ; F4-wide: 16-bit mask path?
                CMP     D2, #0
                BNE     .tbw_wide
                LEA     XY0, topbits_lut         ; narrow: byte LUT, bit7 = first col
                LOADB   D2, [XY0+D0]             ; mask = top N bits (N = 0..8)
                POP     XY0, XY3
                RET
.tbw_wide:
                LEA     XY0, topbits16_lut       ; wide: word LUT, bit15 = first col
                SHL     D0                       ; N -> byte offset (N*2)
                LOADD   D2, [XY0+D0]             ; 16-bit mask (N = 0..16)
                POP     XY0, XY3
                RET
topbits_lut:    .BYTE   $00,$80,$C0,$E0,$F0,$F8,$FC,$FE,$FF,$00   ; [8]=$FF; [9] pad (even, never indexed)
topbits16_lut:  .WORD   $0000,$8000,$C000,$E000,$F000,$F800,$FC00,$FE00
                .WORD   $FF00,$FF80,$FFC0,$FFE0,$FFF0,$FFF8,$FFFC,$FFFE,$FFFF

; ==========================================================================
; _fn_blit_scaled -- scale >= 2 path. Each set source pixel becomes a
;   scale x scale filled block via gfx_fillrect, which inherits clip, bounds
;   and depth for free. Slower than the 1x row-blit, but scaled text is not
;   the hot path and the code reuses the proven clipped fillrect entirely.
;   Entered from _fn_blit with OOR / fn_x<0 already screened. Assumes _fn_setup
;   ran. Loop state in fn_* (fillrect clobbers D0-D3/X0/Y0 and gs_*/gr_*).
;   Preserves XY1.
;   col index -> fn_clo ; bit mask -> fn_chi ; pen x -> fn_acc.
; ==========================================================================
_fn_blit_scaled:
                LOADI   D0, #0
                STOREP  D0, Y3, [#fn_row]
.bls_row:
                LOADP   D0, Y3, [#fn_row]
                LOADP   D1, Y3, [#fn_h]
                CMP     D0, D1
                BGE     .bls_ret
                ; rowbits
                LOADP   D0, Y3, [#fn_gp_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#fn_gp_of]
                MOVE    X0, D0
                LOADP   D1, Y3, [#fn_wide]        ; F4-wide: word/row fetch
                CMP     D1, #0
                BEQ     .bls_fb
                LOADD   D0, [XY0]
                BRA     .bls_fd
.bls_fb:
                LOADB   D0, [XY0]
.bls_fd:
                STOREP  D0, Y3, [#fn_rowbits]
                CMP     D0, #0
                BEQ     .bls_next                ; empty source row
                ; py = fn_y + fn_row * scale
                LOADP   D0, Y3, [#fn_row]
                CALLR   _fn_mulscale             ; D0 = fn_row * scale
                LOADP   D1, Y3, [#fn_y]
                ADD     D0, D1
                STOREP  D0, Y3, [#fn_py]
                ; col setup
                LOADI   D0, #0
                STOREP  D0, Y3, [#fn_clo]        ; col
                LOADP   D0, Y3, [#fn_dx]
                STOREP  D0, Y3, [#fn_acc]        ; pen x (scaled step)
                LOADI   D0, #$80                 ; F4-wide: col0 bit (bit7 / bit15)
                LOADP   D1, Y3, [#fn_wide]
                CMP     D1, #0
                BEQ     .bls_seed
                LOADI   D0, #$8000
.bls_seed:
                STOREP  D0, Y3, [#fn_chi]        ; bit mask
.bls_col:
                LOADP   D0, Y3, [#fn_clo]
                LOADP   D1, Y3, [#fn_w]
                CMP     D0, D1
                BGE     .bls_next
                LOADP   D0, Y3, [#fn_rowbits]
                LOADP   D1, Y3, [#fn_chi]
                AND     D0, D1
                CMP     D0, #0                   ; (don't trust AND flags)
                BEQ     .bls_adv                 ; clear bit -> skip block
                ; gfx_fillrect(px, py, scale, scale, fg)
                LOADP   D0, Y3, [#fn_acc]
                STOREP  D0, Y3, [#gr_x]
                LOADP   D0, Y3, [#fn_py]
                STOREP  D0, Y3, [#gr_y]
                LOADP   D0, Y3, [#fn_scale]
                STOREP  D0, Y3, [#gr_w]
                STOREP  D0, Y3, [#gr_h]
                LOADP   D0, Y3, [#fn_fg]
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_fillrect             ; clip/bounds/depth for free
.bls_adv:
                LOADP   D0, Y3, [#fn_chi]
                SHR     D0
                STOREP  D0, Y3, [#fn_chi]
                LOADP   D0, Y3, [#fn_acc]        ; pen x += scale
                LOADP   D1, Y3, [#fn_scale]
                ADD     D0, D1
                STOREP  D0, Y3, [#fn_acc]
                LOADP   D0, Y3, [#fn_clo]
                ADD     D0, #1
                STOREP  D0, Y3, [#fn_clo]
                BRA     .bls_col
.bls_next:
                ; advance glyph row pointer (+1 narrow / +2 wide, carry to page)
                LOADP   D1, Y3, [#fn_wide]        ; F4-wide: bytes/row = 1 + wide
                ADD     D1, #1
                LOADP   D0, Y3, [#fn_gp_of]
                ADD     D0, D1
                STOREP  D0, Y3, [#fn_gp_of]
                BCC     .bls_nc
                LOADP   D0, Y3, [#fn_gp_pg]
                ADD     D0, #1
                STOREP  D0, Y3, [#fn_gp_pg]
.bls_nc:
                LOADP   D0, Y3, [#fn_row]
                ADD     D0, #1
                STOREP  D0, Y3, [#fn_row]
                BRA     .bls_row
.bls_ret:
                RET

; ==========================================================================
; _fn_mulscale -- D0 := D0 * fn_scale  (scale small; repeated add).
;   In: D0.  Out: D0.  Clobbers D1,D2.
; ==========================================================================
_fn_mulscale:
                LOADP   D2, Y3, [#fn_scale]
                MOVE    D1, D0                   ; addend
                LOADI   D0, #0                   ; acc
.ms_loop:
                CMP     D2, #0
                BEQ     .ms_done
                ADD     D0, D1
                DEC     D2
                BRA     .ms_loop
.ms_done:
                RET
