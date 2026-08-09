; ============================================================================
; gfx.asm  --  K16 graphics library: routine code
; ----------------------------------------------------------------------------
; Depth-blind geometry over per-surface poke methods dispatched by CALLXY.
; Include AFTER the program body and data (routines are reached by forward
; CALLR; the two-pass assembler resolves them). Requires gfx_defs.inc.
;
; Public API (all take the descriptor in XY1, which every routine preserves):
;   gfx_open    D0=mode(1|2)              acquire video + set VID_PAGE +
;                                         populate descriptor
;                                         + method vector. C=1 on busy.
;   gfx_clear   D0=idx                    whole-surface fill (fast word-blast)
;   gfx_setpixel D0=x D1=y D2=idx         clipped pixel
;   gfx_fillrect params gr_*             clipped filled rect
;   gfx_line    params gl_*              Bresenham line (clipped per-pixel)
;   gfx_rect    params gr_*              rect outline (4 lines)
;
; Poke methods (selected per surface via the descriptor's method offsets):
;   vspan_<d>   XY1=desc D0=x D1=y D2=count D3=idx   clipped horizontal run
;   vclear_<d>  XY1=desc D0=idx                      whole-surface blast
; Depths: _8 (8bpp mode 2), _1 (1bpp mode 1, MSB-first). Adding a depth =
; two new pokes + a gfx_open branch; geometry is untouched.
;
; Method-pointer convention: routines, descriptor and stack all live in the
; task page Y3, so a method pointer is a 16-bit page-offset. Dispatch is
; LOADX X0,[XY1+#off] / MOVE Y0,Y3 / CALLXY XY0 (D0-D3 reach the poke intact).
; ============================================================================

; ==========================================================================
; gfx_open -- acquire video, populate descriptor + method vector for `mode`
;   In:  D0 = mode (1 or 2)
;   Out: C=0 success, C=1 fail (video busy). Clobbers D0,X0,Y0.
; ==========================================================================

gfx_open:
                STOREP  D0, Y3, [#GS_MODE]
                TRAP    #TRAP_SETVIDMODE        ; D0 = mode
                BCS     .open_fail
                LOADI   D0, #$00B0
                STOREP  D0, Y3, [#GS_FB_PAGE]
                ; Point the display at the framebuffer we just claimed.
                ; VID_PAGE ($DC0000) is not mediated by k/OS and is not
                ; initialised by the kernel (_InitVideo only zeroes
                ; VID_MODE), so it holds whatever the last graphics task
                ; left there - Cube6 alternates $B0/$B4 every frame, so
                ; without this a KGFX program renders correctly and shows
                ; nothing, or works, depending on which frame cube died on.
                ; D0 still = $00B0; D0/X0/Y0 are already clobber-listed.
                LOADI   Y0, #$00DC
                LOADI   X0, #$0000
                STORED  D0, [XY0]               ; VID_PAGE := $B0
                LOADI   D0, #0
                STOREP  D0, Y3, [#GS_CLIP_PG]   ; default: no clip (clip to bounds)
                LOADI   D0, #0
                STOREP  D0, Y3, [#GS_FONT_PG]   ; default: no font set
                LOADI   D0, #1
                STOREP  D0, Y3, [#GS_FSCALE]    ; default: 1x
                LOADP   D0, Y3, [#GS_MODE]
                CMP     D0, #1
                BNE     .open_m2
                ; --- mode 1: 1280x720 1bpp ---
                LOADI   D0, #1280
                STOREP  D0, Y3, [#GS_WIDTH]
                LOADI   D0, #720
                STOREP  D0, Y3, [#GS_HEIGHT]
                LOADI   D0, #160
                STOREP  D0, Y3, [#GS_PITCH]
                LOADI   D0, #1
                STOREP  D0, Y3, [#GS_BPP]
                LEA     XY0, vspan_1
                MOVE    D0, X0
                STOREP  D0, Y3, [#GS_VSPAN]
                LEA     XY0, vclear_1
                MOVE    D0, X0
                STOREP  D0, Y3, [#GS_VCLEAR]
                LEA     XY0, vtext_1
                MOVE    D0, X0
                STOREP  D0, Y3, [#GS_VTEXT]
                LEA     XY0, gfx_byte1
                MOVE    D0, X0
                STOREP  D0, Y3, [#GS_ADDR]
                LEA     XY0, vpat_1
                MOVE    D0, X0
                STOREP  D0, Y3, [#GS_VPAT]
                LEA     XY0, vblit_1
                MOVE    D0, X0
                STOREP  D0, Y3, [#GS_VBLIT]
                BRA     .open_ok
.open_m2:
                ; --- mode 2: 640x480 8bpp ---
                LOADI   D0, #640
                STOREP  D0, Y3, [#GS_WIDTH]
                LOADI   D0, #480
                STOREP  D0, Y3, [#GS_HEIGHT]
                LOADI   D0, #640
                STOREP  D0, Y3, [#GS_PITCH]
                LOADI   D0, #8
                STOREP  D0, Y3, [#GS_BPP]
                LEA     XY0, vspan_8
                MOVE    D0, X0
                STOREP  D0, Y3, [#GS_VSPAN]
                LEA     XY0, vclear_8
                MOVE    D0, X0
                STOREP  D0, Y3, [#GS_VCLEAR]
                LEA     XY0, vtext_8
                MOVE    D0, X0
                STOREP  D0, Y3, [#GS_VTEXT]
                LEA     XY0, gfx_addr8
                MOVE    D0, X0
                STOREP  D0, Y3, [#GS_ADDR]
                LEA     XY0, vpat_8
                MOVE    D0, X0
                STOREP  D0, Y3, [#GS_VPAT]
                LEA     XY0, vblit_8
                MOVE    D0, X0
                STOREP  D0, Y3, [#GS_VBLIT]
.open_ok:
                CLC
                RET
.open_fail:
                SEC
                RET


; ==========================================================================
; gfx_span -- dispatch a clipped horizontal run to the surface's vspan
;   In:  XY1=desc, D0=x, D1=y, D2=count, D3=idx (all in-bounds assumed)
;   Out: via CALLXY. D0-D3 reach the poke routine untouched (offset loaded
;        into X0, not a D register). Preserves XY1.
; ==========================================================================
gfx_span:
                LOADX   X0, [XY1+#GSO_VSPAN]
                MOVE    Y0, Y3
                CALLXY  XY0
                RET


; ==========================================================================
; gfx_clear -- dispatch whole-surface fill to the surface's vclear
;   In:  XY1=desc, D0=idx.  Preserves XY1.
; ==========================================================================
gfx_clear:
                LOADX   X0, [XY1+#GSO_VCLEAR]
                MOVE    Y0, Y3
                CALLXY  XY0
                RET


; ==========================================================================
; gfx_setclip -- set (or disable) the clip region.
;   In:  XY1=desc, XY0 = clip region ptr (Y0=page, X0=offset).
;        Pass Y0=0 to disable (clip to bounds). Preserves XY1.
;   Clobbers D0.
; ==========================================================================
gfx_setclip:
                MOVE    D0, Y0
                STOREP  D0, Y3, [#GS_CLIP_PG]
                MOVE    D0, X0
                STOREP  D0, Y3, [#GS_CLIP_OF]
                RET


; ==========================================================================
; gfx_setpixel -- clip (x,y); emit a 1-pixel span (depth-blind)
;   In:  XY1=desc, D0=x, D1=y, D2=idx.  Preserves XY1.
; ==========================================================================
gfx_setpixel:
                LOADD   D3, [XY1+#GSO_WIDTH]
                CMP     D0, #0
                BLT     .sp_rej
                CMP     D0, D3
                BGE     .sp_rej
                LOADD   D3, [XY1+#GSO_HEIGHT]
                CMP     D1, #0
                BLT     .sp_rej
                CMP     D1, D3
                BGE     .sp_rej
                ; --- clip-region test (NEW): skip if GS_CLIP_PG == 0 ---
                LOADD   D3, [XY1+#GSO_CLIP_PG]
                CMP     D3, #0
                BEQ     .sp_emit                ; no clip region -> emit
                PUSH    XY1, XY3                ; save descriptor
                PUSH    D2, XY3                 ; save idx
                PUSH    D1, XY3                 ; save y (rgn_pt_in consumes D1)
                MOVE    Y0, D3                  ; XY0.page = clip page
                LOADD   D3, [XY1+#GSO_CLIP_OF]
                MOVE    X0, D3                  ; XY0 = clip region ptr
                CALLR   rgn_pt_in               ; In D0=x,D1=y -> C=0 in / C=1 out
                POP     D1, XY3                 ; restore y
                POP     D2, XY3                 ; restore idx
                POP     XY1, XY3                ; restore descriptor (POP keeps C)
                BCS     .sp_rej                 ; outside clip -> reject
.sp_emit:
                MOVE    D3, D2                  ; idx -> D3
                LOADI   D2, #1                  ; count = 1
                CALLR   gfx_span
                RET
.sp_rej:
                RET


; ==========================================================================
; gfx_fillrect -- clip rect (depth-blind), emit one vspan per row
;   In:  XY1=desc; params gr_x,gr_y,gr_w,gr_h,gr_idx.  Preserves XY1.
; ==========================================================================
gfx_fillrect:
                LOADI   D0, #0
                STOREP  D0, Y3, [#gp_mode]      ; solid fill
                BRA     _gfx_fill_common


; ==========================================================================
; gfx_fillpat -- Mac-style 8x8 1bpp pattern fill of a rect (clip-aware).
;   In:  XY1=desc; rect in gr_x/gr_y/gr_w/gr_h; XY0 = pattern ptr (8 bytes,
;        one row each, MSB = leftmost; screen-aligned so tiles abut). 8bpp
;        uses gp_fg (set bits) / gp_bg (clear bits); 1bpp uses the bits as-is
;        (gr_idx/gp_fg/gp_bg ignored). Preserves XY1.
; ==========================================================================
gfx_fillpat:
                MOVE    D0, Y0
                STOREP  D0, Y3, [#gp_pat_pg]
                MOVE    D0, X0
                STOREP  D0, Y3, [#gp_pat_of]
                LOADI   D0, #1
                STOREP  D0, Y3, [#gp_mode]      ; pattern fill


_gfx_fill_common:
                LOADD   D0, [XY1+#GSO_WIDTH]
                STOREP  D0, Y3, [#gs_w]
                LOADD   D0, [XY1+#GSO_HEIGHT]
                STOREP  D0, Y3, [#gs_h]
                ; clamp x>=0
                LOADP   D0, Y3, [#gr_x]
                CMP     D0, #0
                BGE     .fr_xok
                LOADP   D1, Y3, [#gr_w]
                ADD     D1, D0
                STOREP  D1, Y3, [#gr_w]
                LOADI   D0, #0
                STOREP  D0, Y3, [#gr_x]
.fr_xok:
                ; clamp x+w <= width
                LOADP   D0, Y3, [#gr_x]
                LOADP   D1, Y3, [#gr_w]
                ADD     D0, D1
                LOADP   D2, Y3, [#gs_w]
                CMP     D0, D2
                BLE     .fr_xwok
                LOADP   D2, Y3, [#gs_w]
                LOADP   D0, Y3, [#gr_x]
                SUB     D2, D0
                STOREP  D2, Y3, [#gr_w]
.fr_xwok:
                ; clamp y>=0
                LOADP   D0, Y3, [#gr_y]
                CMP     D0, #0
                BGE     .fr_yok
                LOADP   D1, Y3, [#gr_h]
                ADD     D1, D0
                STOREP  D1, Y3, [#gr_h]
                LOADI   D0, #0
                STOREP  D0, Y3, [#gr_y]
.fr_yok:
                ; clamp y+h <= height
                LOADP   D0, Y3, [#gr_y]
                LOADP   D1, Y3, [#gr_h]
                ADD     D0, D1
                LOADP   D2, Y3, [#gs_h]
                CMP     D0, D2
                BLE     .fr_yhok
                LOADP   D2, Y3, [#gs_h]
                LOADP   D0, Y3, [#gr_y]
                SUB     D2, D0
                STOREP  D2, Y3, [#gr_h]
.fr_yhok:
                LOADP   D0, Y3, [#gr_w]
                CMP     D0, #0
                BLE     .fr_done
                LOADP   D0, Y3, [#gr_h]
                CMP     D0, #0
                BLE     .fr_done
                LOADP   D0, Y3, [#gr_y]
                STOREP  D0, Y3, [#gr_cy]
.fr_row:
                CALLR   gfx_fillrow_clipped     ; emits row (full, or clipped to region)
                LOADP   D0, Y3, [#gr_cy]
                ADD     D0, #1
                STOREP  D0, Y3, [#gr_cy]
                LOADP   D1, Y3, [#gr_y]
                LOADP   D2, Y3, [#gr_h]
                ADD     D1, D2
                CMP     D0, D1
                BLT     .fr_row
.fr_done:
                RET


; ==========================================================================
; gfx_fillrow_clipped -- emit one row of the current fillrect, honouring
; GS_CLIP. Reads gr_x/gr_cy/gr_w/gr_idx. With no clip (GS_CLIP_PG==0) emits
; the full clamped span; otherwise emits one vspan per visible sub-span of
; the clip band covering gr_cy (nothing if no band covers it).
;   In: XY1=desc.  Clobbers D0-D3, XY0.  Preserves XY1.
; ==========================================================================
gfx_fillrow_clipped:
                LOADD   D3, [XY1+#GSO_CLIP_PG]
                CMP     D3, #0
                BNE     .frc_clip
                ; --- no clip: full clamped span ---
                LOADP   D0, Y3, [#gr_x]
                LOADP   D1, Y3, [#gr_cy]
                LOADP   D2, Y3, [#gr_w]
                LOADP   D3, Y3, [#gr_idx]
                CALLR   gfx_emitrow
                RET
.frc_clip:
                ; XY0 = clip region ptr ; D0 = gr_cy
                MOVE    Y0, D3                  ; clip page
                LOADD   D3, [XY1+#GSO_CLIP_OF]
                MOVE    X0, D3
                LOADP   D0, Y3, [#gr_cy]
                PUSH    XY1, XY3                ; save descriptor
                CALLR   rgn_band_at            ; XY1 = band, C=0/1 ; clobbers D1-3,XY1
                BCS     .frc_noband
                MOVE    Y0, Y1                  ; XY0 = band ptr (walk cursor)
                MOVE    X0, X1
                POP     XY1, XY3               ; restore descriptor
                LOADD   D2, [XY0+#BND_NX]       ; coord count
                STOREP  D2, Y3, [#frc_nx]
                MOVE    D3, X0                  ; advance cursor to first x-coord
                ADD     D3, #BND_X0
                MOVE    X0, D3
.frc_iloop:
                LOADP   D2, Y3, [#frc_nx]
                CMP     D2, #0
                BLE     .frc_done
                LOADD   D0, [XY0+#0]            ; cx0
                LOADD   D1, [XY0+#2]            ; cx1
                ; lo = max(gr_x, cx0)
                LOADP   D3, Y3, [#gr_x]
                CMP     D0, D3
                BGE     .frc_lo                 ; cx0 >= gr_x -> lo = cx0
                MOVE    D0, D3                  ; lo = gr_x
.frc_lo:
                ; hi = min(gr_x+gr_w, cx1)
                LOADP   D3, Y3, [#gr_x]
                LOADP   D2, Y3, [#gr_w]
                ADD     D3, D2                  ; right edge (exclusive)
                CMP     D1, D3
                BLE     .frc_hi                 ; cx1 <= right -> hi = cx1
                MOVE    D1, D3                  ; hi = right
.frc_hi:
                MOVE    D2, D1
                SUB     D2, D0                  ; width = hi - lo
                CMP     D2, #0
                BLE     .frc_inext              ; empty sub-span -> skip
                ; emit gfx_span(lo, gr_cy, width, gr_idx)
                PUSH    XY0, XY3                ; save band cursor (gfx_span clobbers XY0)
                LOADP   D1, Y3, [#gr_cy]        ; y
                LOADP   D3, Y3, [#gr_idx]       ; idx  (D0=lo, D2=width already)
                CALLR   gfx_emitrow
                POP     XY0, XY3                ; restore cursor
.frc_inext:
                MOVE    D3, X0                  ; cursor += 4 (next interval)
                ADD     D3, #4
                MOVE    X0, D3
                LOADP   D2, Y3, [#frc_nx]
                SUB     D2, #2
                STOREP  D2, Y3, [#frc_nx]
                BRA     .frc_iloop
.frc_noband:
                POP     XY1, XY3               ; restore descriptor (nothing emitted)
                RET
.frc_done:
                RET


; ==========================================================================
; gfx_emitrow -- emit one span as solid (gfx_span) or pattern (gfx_patspan)
;   per gp_mode. In: D0=x, D1=y, D2=count, D3=idx (idx used only when solid).
;   Preserves XY1; D0/D1/D2 reach the writer untouched.
; ==========================================================================
gfx_emitrow:
                LOADP   D3, Y3, [#gp_mode]      ; clobbers D3 (reloaded below)
                CMP     D3, #0
                BNE     .er_pat
                LOADP   D3, Y3, [#gr_idx]       ; solid: restore idx
                CALLR   gfx_span
                RET
.er_pat:
                CALLR   gfx_patspan
                RET


; ==========================================================================
; gfx_patspan -- dispatch one patterned run to the surface's vpat.
;   In: D0=x, D1=y, D2=count.  Looks up patrow = pattern[y&7] and passes it
;   in D3 to GS_VPAT (D0=x,D1=y,D2=count,D3=patrow).  Preserves XY1.
; ==========================================================================
gfx_patspan:
                STOREP  D0, Y3, [#gp_sx]        ; save x
                STOREP  D2, Y3, [#gp_scnt]      ; save count
                MOVE    D0, D1                  ; y
                AND     D0, #7                  ; row index 0..7
                LOADP   D2, Y3, [#gp_pat_of]
                LOADP   D3, Y3, [#gp_pat_pg]
                ADD     D2, D0
                ADC     D3, #0                  ; pattern + (y&7)
                MOVE    Y0, D3
                MOVE    X0, D2
                LOADB   D3, [XY0]               ; patrow (D1=y still intact)
                AND     D3, #$FF
                LOADP   D0, Y3, [#gp_sx]        ; restore x
                LOADP   D2, Y3, [#gp_scnt]      ; restore count
                LOADX   X0, [XY1+#GSO_VPAT]
                MOVE    Y0, Y3
                CALLXY  XY0                      ; vpat_8 / vpat_1 (preserves XY1)
                RET


; ==========================================================================
; gfx_line -- Bresenham (depth-blind: plots via gfx_setpixel)
;   In:  XY1=desc; params gl_x0,gl_y0,gl_x1,gl_y1,gl_idx.  Preserves XY1.
;   Algorithm lifted from CUBE4 draw_line.
; ==========================================================================
gfx_line:
                ; dx = |x1-x0|, sx
                LOADP   D0, Y3, [#gl_x1]
                LOADP   D1, Y3, [#gl_x0]
                SUB     D0, D1
                BGE     .gl_dxp
                NEG     D0
                LOADI   D1, #$FFFF
                BRA     .gl_dxd
.gl_dxp:
                LOADI   D1, #1
.gl_dxd:
                STOREP  D0, Y3, [#gl_dx]
                STOREP  D1, Y3, [#gl_sx]
                ; dy = |y1-y0|, sy
                LOADP   D0, Y3, [#gl_y1]
                LOADP   D1, Y3, [#gl_y0]
                SUB     D0, D1
                BGE     .gl_dyp
                NEG     D0
                LOADI   D1, #$FFFF
                BRA     .gl_dyd
.gl_dyp:
                LOADI   D1, #1
.gl_dyd:
                STOREP  D0, Y3, [#gl_dy]
                STOREP  D1, Y3, [#gl_sy]
                ; cx,cy
                LOADP   D0, Y3, [#gl_x0]
                STOREP  D0, Y3, [#gl_cx]
                LOADP   D0, Y3, [#gl_y0]
                STOREP  D0, Y3, [#gl_cy]
                ; choose axis
                LOADP   D0, Y3, [#gl_dx]
                LOADP   D1, Y3, [#gl_dy]
                CMP     D0, D1
                BLT     .gl_steep
                ; shallow: err = 2dy - dx; count = dx+1
                LOADP   D0, Y3, [#gl_dy]
                ADD     D0, D0
                LOADP   D1, Y3, [#gl_dx]
                SUB     D0, D1
                STOREP  D0, Y3, [#gl_err]
                LOADP   D0, Y3, [#gl_dx]
                ADD     D0, #1
                STOREP  D0, Y3, [#gl_cnt]
.gl_sh_loop:
                CALLR   gl_plot
                LOADP   D0, Y3, [#gl_err]
                CMP     D0, #0
                BLE     .gl_sh_no_y
                LOADP   D1, Y3, [#gl_cy]
                LOADP   D2, Y3, [#gl_sy]
                ADD     D1, D2
                STOREP  D1, Y3, [#gl_cy]
                LOADP   D1, Y3, [#gl_dx]
                ADD     D1, D1
                SUB     D0, D1
.gl_sh_no_y:
                LOADP   D1, Y3, [#gl_dy]
                ADD     D1, D1
                ADD     D0, D1
                STOREP  D0, Y3, [#gl_err]
                LOADP   D1, Y3, [#gl_cx]
                LOADP   D2, Y3, [#gl_sx]
                ADD     D1, D2
                STOREP  D1, Y3, [#gl_cx]
                LOADP   D0, Y3, [#gl_cnt]
                DEC     D0
                STOREP  D0, Y3, [#gl_cnt]
                CMP     D0, #0
                BNE     .gl_sh_loop
                RET
.gl_steep:
                ; steep: err = 2dx - dy; count = dy+1
                LOADP   D0, Y3, [#gl_dx]
                ADD     D0, D0
                LOADP   D1, Y3, [#gl_dy]
                SUB     D0, D1
                STOREP  D0, Y3, [#gl_err]
                LOADP   D0, Y3, [#gl_dy]
                ADD     D0, #1
                STOREP  D0, Y3, [#gl_cnt]
.gl_st_loop:
                CALLR   gl_plot
                LOADP   D0, Y3, [#gl_err]
                CMP     D0, #0
                BLE     .gl_st_no_x
                LOADP   D1, Y3, [#gl_cx]
                LOADP   D2, Y3, [#gl_sx]
                ADD     D1, D2
                STOREP  D1, Y3, [#gl_cx]
                LOADP   D1, Y3, [#gl_dy]
                ADD     D1, D1
                SUB     D0, D1
.gl_st_no_x:
                LOADP   D1, Y3, [#gl_dx]
                ADD     D1, D1
                ADD     D0, D1
                STOREP  D0, Y3, [#gl_err]
                LOADP   D1, Y3, [#gl_cy]
                LOADP   D2, Y3, [#gl_sy]
                ADD     D1, D2
                STOREP  D1, Y3, [#gl_cy]
                LOADP   D0, Y3, [#gl_cnt]
                DEC     D0
                STOREP  D0, Y3, [#gl_cnt]
                CMP     D0, #0
                BNE     .gl_st_loop
                RET


; gl_plot -- emit (gl_cx,gl_cy) via gfx_setpixel (XY1 already = desc)
gl_plot:
                LOADP   D0, Y3, [#gl_cx]
                LOADP   D1, Y3, [#gl_cy]
                LOADP   D2, Y3, [#gl_idx]
                CALLR   gfx_setpixel
                RET


; ==========================================================================
; gfx_rect -- rectangle outline (4 edges via gfx_line)
;   In:  XY1=desc; params gr_x,gr_y,gr_w,gr_h,gr_idx.  Preserves XY1.
; ==========================================================================
gfx_rect:
                LOADP   D0, Y3, [#gr_w]
                CMP     D0, #1
                BLT     .rect_done
                LOADP   D0, Y3, [#gr_h]
                CMP     D0, #1
                BLT     .rect_done
                LOADP   D0, Y3, [#gr_x]
                LOADP   D1, Y3, [#gr_w]
                ADD     D0, D1
                DEC     D0
                STOREP  D0, Y3, [#gr_x2]
                LOADP   D0, Y3, [#gr_y]
                LOADP   D1, Y3, [#gr_h]
                ADD     D0, D1
                DEC     D0
                STOREP  D0, Y3, [#gr_y2]
                LOADP   D0, Y3, [#gr_idx]
                STOREP  D0, Y3, [#gl_idx]
                ; top
                LOADP   D0, Y3, [#gr_x]
                STOREP  D0, Y3, [#gl_x0]
                LOADP   D0, Y3, [#gr_y]
                STOREP  D0, Y3, [#gl_y0]
                LOADP   D0, Y3, [#gr_x2]
                STOREP  D0, Y3, [#gl_x1]
                LOADP   D0, Y3, [#gr_y]
                STOREP  D0, Y3, [#gl_y1]
                CALLR   gfx_line
                ; bottom
                LOADP   D0, Y3, [#gr_x]
                STOREP  D0, Y3, [#gl_x0]
                LOADP   D0, Y3, [#gr_y2]
                STOREP  D0, Y3, [#gl_y0]
                LOADP   D0, Y3, [#gr_x2]
                STOREP  D0, Y3, [#gl_x1]
                LOADP   D0, Y3, [#gr_y2]
                STOREP  D0, Y3, [#gl_y1]
                CALLR   gfx_line
                ; left
                LOADP   D0, Y3, [#gr_x]
                STOREP  D0, Y3, [#gl_x0]
                LOADP   D0, Y3, [#gr_y]
                STOREP  D0, Y3, [#gl_y0]
                LOADP   D0, Y3, [#gr_x]
                STOREP  D0, Y3, [#gl_x1]
                LOADP   D0, Y3, [#gr_y2]
                STOREP  D0, Y3, [#gl_y1]
                CALLR   gfx_line
                ; right
                LOADP   D0, Y3, [#gr_x2]
                STOREP  D0, Y3, [#gl_x0]
                LOADP   D0, Y3, [#gr_y]
                STOREP  D0, Y3, [#gl_y0]
                LOADP   D0, Y3, [#gr_x2]
                STOREP  D0, Y3, [#gl_x1]
                LOADP   D0, Y3, [#gr_y2]
                STOREP  D0, Y3, [#gl_y1]
                CALLR   gfx_line
.rect_done:
                RET


; ==========================================================================
; gfx_blit1 -- blit a 1bpp mask bitmap to the surface (depth via GS_VBLIT).
;   In:  XY1=desc; XY0 = source bitmap ptr (1bpp, MSB-first rows);
;        gb_x/gb_y dest, gb_w/gb_h source dims (px), gb_stride bytes/row,
;        gb_mode (0=Or 1=Copy 2=Xor), gb_fg, gb_bg.  Preserves XY1.
;   Bounds-clipped: top (y<0 rows skipped), bottom (py>=height stops), right
;   (visible width clamped). x<0 coarse-skips the whole blit (no left clip;
;   region clip deferred). One GS_VBLIT dispatch per visible row.
; ==========================================================================
gfx_blit1:
                MOVE    D0, Y0
                STOREP  D0, Y3, [#gb_src_pg]
                STOREP  D0, Y3, [#gb_row_pg]
                MOVE    D0, X0
                STOREP  D0, Y3, [#gb_src_of]
                STOREP  D0, Y3, [#gb_row_of]
                LOADP   D0, Y3, [#gb_x]
                CMP     D0, #0
                BLT     .blit_done              ; x<0 -> coarse skip (no left clip)
                ; vis_w = min(gb_w, width - x)
                LOADD   D1, [XY1+#GSO_WIDTH]
                LOADP   D0, Y3, [#gb_x]
                SUB     D1, D0                   ; width - x
                CMP     D1, #0
                BLE     .blit_done              ; off right entirely
                LOADP   D0, Y3, [#gb_w]
                CMP     D1, D0
                BGE     .blit_vwok              ; width-x >= w -> visw = w
                MOVE    D0, D1                   ; visw = width-x
.blit_vwok:
                STOREP  D0, Y3, [#gb_visw]
                LOADI   D0, #0
                STOREP  D0, Y3, [#gb_r]
.blit_rowloop:
                LOADP   D0, Y3, [#gb_r]
                LOADP   D1, Y3, [#gb_h]
                CMP     D0, D1
                BGE     .blit_done
                LOADP   D0, Y3, [#gb_y]
                LOADP   D1, Y3, [#gb_r]
                ADD     D0, D1
                STOREP  D0, Y3, [#gb_py]
                CMP     D0, #0
                BLT     .blit_skiprow           ; py<0 -> skip (advance src)
                LOADD   D1, [XY1+#GSO_HEIGHT]
                CMP     D0, D1
                BGE     .blit_done              ; py>=height -> done
                ; dispatch GS_VBLIT(D0=x, D1=py, D2=visw)
                LOADP   D0, Y3, [#gb_x]
                LOADP   D1, Y3, [#gb_py]
                LOADP   D2, Y3, [#gb_visw]
                LOADX   X0, [XY1+#GSO_VBLIT]
                MOVE    Y0, Y3
                CALLXY  XY0                      ; vblit_1 / vblit_8 (preserves XY1)
.blit_skiprow:
                LOADP   D0, Y3, [#gb_row_of]     ; src row ptr += stride
                LOADP   D1, Y3, [#gb_stride]
                ADD     D0, D1
                STOREP  D0, Y3, [#gb_row_of]
                BCC     .blit_rnc
                LOADP   D0, Y3, [#gb_row_pg]
                ADD     D0, #1
                STOREP  D0, Y3, [#gb_row_pg]
.blit_rnc:
                LOADP   D0, Y3, [#gb_r]
                ADD     D0, #1
                STOREP  D0, Y3, [#gb_r]
                BRA     .blit_rowloop
.blit_done:
                RET
