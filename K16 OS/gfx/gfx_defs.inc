; ============================================================================
; gfx_defs.inc  --  K16 graphics library: definitions
; ----------------------------------------------------------------------------
; Descriptor layout, descriptor-relative offsets, poke scratch, and the
; fillrect/rect/line param blocks. Include BEFORE .ORG. Pairs with gfx.asm
; (the routine code, included after the program body).
;
; Surface descriptor is a single global at GS_BASE in the task page. All
; scratch/param slots are task-page resident -> the library is not
; re-entrant (one drawing context per task). See gfx.asm header for ABI.
;
; ---- TASK-PAGE LOW MEMORY MAP (canonical) ----------------------------------
;   $0100-$011D  surface descriptor  (GS_* — incl GS_CLIP, GS_FONT, GS_VTEXT, GS_FSCALE, GS_VPAT)
;   $011E-$011F  (free)
;   $0120-$015A  gfx scratch          (gs_*, gr_*, gl_*, frc_nx)
;   $015C        gv_shift             (vtext_1)
;   $015E-$015F  (free)
;   $0160-$0162  region persistent    (rg_pg/rg_of — gfx_regions_defs.inc)
;   $0164-$01FF  free: harness / test scratch
;   $6000+       RGN_BSS region work scratch (gfx_regions_defs.inc)
;   $6100+       GP_BSS  pattern-fill scratch (this file)
;   $6120+       GB_BSS  bitmap-blit scratch (this file)
;   $6200+       FNT_BSS font render scratch (gfx_font_defs.inc)
; Code .ORG $0200. Stack grows down from the top of the page.
; ============================================================================

VID_MODE        .EQU    $DD0000
VID_PAGE        .EQU    $DC0000

; ====== Surface descriptor (task page) ====================================
GS_BASE         .EQU    $0100
GS_FB_PAGE      .EQU    $0100           ; word: high 16 bits of FB base ($00B0)
GS_WIDTH        .EQU    $0102           ; word: pixels
GS_HEIGHT       .EQU    $0104           ; word: pixels
GS_PITCH        .EQU    $0106           ; word: bytes/row
GS_BPP          .EQU    $0108           ; word: 1/2/8
GS_MODE         .EQU    $010A           ; word: VID_MODE value
GS_VSPAN        .EQU    $010C           ; word: vspan routine page-offset
GS_VCLEAR       .EQU    $010E           ; word: vclear routine page-offset
GS_CLIP_PG      .EQU    $0110           ; word: clip region page (0 = clip to bounds)
GS_CLIP_OF      .EQU    $0112           ; word: clip region offset
GS_FONT_PG      .EQU    $0114           ; word: current font descriptor page (0 = none)
GS_FONT_OF      .EQU    $0116           ; word: current font descriptor offset
GS_VTEXT        .EQU    $0118           ; word: vtext routine page-offset (F3 row-blit)
GS_FSCALE       .EQU    $011A           ; word: integer font scale (1=1x, 2=2x ...)
GS_VPAT         .EQU    $011C           ; word: vpat routine page-offset (pattern fill)
GS_VBLIT        .EQU    $011E           ; word: vblit routine page-offset (1bpp mask blit)
; descriptor-relative offsets for [XY1+#imm5] reads
GSO_WIDTH       .EQU    2
GSO_HEIGHT      .EQU    4
GSO_PITCH       .EQU    6               ; GS_PITCH - GS_BASE
GSO_BPP         .EQU    8               ; GS_BPP   - GS_BASE
GSO_VSPAN       .EQU    12
GSO_VCLEAR      .EQU    14
GSO_CLIP_PG     .EQU    16
GSO_CLIP_OF     .EQU    18
GSO_FONT_PG     .EQU    20
GSO_FONT_OF     .EQU    22
GSO_VTEXT       .EQU    24
GSO_VPAT        .EQU    28
GSO_VBLIT       .EQU    30

; ====== Poke scratch ======================================================
gs_x            .EQU    $0120
gs_y            .EQU    $0122
gs_fbpage       .EQU    $0124
gv_cnt          .EQU    $0126
gv_idx          .EQU    $0128
gs_w            .EQU    $012A
gs_h            .EQU    $012C
gv_nlead        .EQU    $012E           ; vspan_1: leading-partial pixel count
gv_shift        .EQU    $015C           ; vtext_1: bit shift (x & 7)
GS_ADDR         .EQU    $015E           ; word: depth addr routine offset (page=Y3);
                                        ;   B-lite text path: row-0 byte addr, once/glyph

; ====== fillrect / rect param block + scratch =============================
gr_x            .EQU    $0130
gr_y            .EQU    $0132
gr_w            .EQU    $0134
gr_h            .EQU    $0136
gr_idx          .EQU    $0138
gr_cy           .EQU    $013A
gr_x2           .EQU    $013C
gr_y2           .EQU    $013E

; ====== line param block + scratch ========================================
gl_x0           .EQU    $0140
gl_y0           .EQU    $0142
gl_x1           .EQU    $0144
gl_y1           .EQU    $0146
gl_idx          .EQU    $0148
gl_dx           .EQU    $014A
gl_dy           .EQU    $014C
gl_sx           .EQU    $014E
gl_sy           .EQU    $0150
gl_err          .EQU    $0152
gl_cx           .EQU    $0154
gl_cy           .EQU    $0156
gl_cnt          .EQU    $0158

; ====== clip scratch (gfx_fillrow_clipped) ================================
frc_nx          .EQU    $015A           ; remaining clip-band coords during a row

; ====== pattern-fill scratch (GP_BSS, between RGN_BSS and FNT_BSS) =========
; High-BSS block (like RGN_BSS/FNT_BSS) so the crowded low map is untouched.
GP_BSS          .EQU    $6100
gp_mode         .EQU    GP_BSS+0        ; 0 = solid fillrect, 1 = pattern fill
gp_pat_pg       .EQU    GP_BSS+2        ; pattern source ptr (8 bytes, 1bpp, MSB=left)
gp_pat_of       .EQU    GP_BSS+4
gp_patrow       .EQU    GP_BSS+6        ; pattern byte for the current row (y&7)
gp_fg           .EQU    GP_BSS+8        ; 8bpp pattern fg index (set bits)
gp_bg           .EQU    GP_BSS+10       ; 8bpp pattern bg index (clear bits)
gp_sx           .EQU    GP_BSS+12       ; gfx_patspan: saved x
gp_scnt         .EQU    GP_BSS+14       ; gfx_patspan: saved count
; GP_BSS top = $6110

; ====== bitmap-blit scratch (GB_BSS) ======================================
; 1bpp mask source -> 1bpp or 8bpp dest. Modes: 0=Or(transparent),
; 1=Copy(opaque fg/bg), 2=Xor. Bounds-clipped (region clip deferred).
GB_BSS          .EQU    $6120
gb_x            .EQU    GB_BSS+0        ; dest x (param)
gb_y            .EQU    GB_BSS+2        ; dest y (param; may be <0 -> top clip)
gb_w            .EQU    GB_BSS+4        ; source width px (param)
gb_h            .EQU    GB_BSS+6        ; source height rows (param)
gb_stride       .EQU    GB_BSS+8        ; source bytes/row (param)
gb_mode         .EQU    GB_BSS+10       ; 0=Or 1=Copy 2=Xor (param)
gb_fg           .EQU    GB_BSS+12       ; fg index/bit (param)
gb_bg           .EQU    GB_BSS+14       ; bg index/bit (param, Copy only)
gb_src_pg       .EQU    GB_BSS+16       ; source base ptr (from XY0)
gb_src_of       .EQU    GB_BSS+18
gb_row_pg       .EQU    GB_BSS+20       ; running source row ptr
gb_row_of       .EQU    GB_BSS+22
gb_visw         .EQU    GB_BSS+24       ; visible width (right-clamped)
gb_py           .EQU    GB_BSS+26       ; current dest y
gb_r            .EQU    GB_BSS+28       ; current source row index
gb_s            .EQU    GB_BSS+30       ; vblit_1 shift = x&7
gb_coverf       .EQU    GB_BSS+32       ; vblit_1 full cover (pre-shift)
gb_opv          .EQU    GB_BSS+34       ; vblit_1 source byte (masked, pre-shift)
gb_cover        .EQU    GB_BSS+36       ; gfx_blitop: aligned cover mask
; GB_BSS top = $6146
