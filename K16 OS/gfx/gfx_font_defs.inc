; ============================================================================
; gfx_font_defs.inc  --  KGFX font layer: definitions (F1a, polish r2)
; ----------------------------------------------------------------------------
; Font descriptor offsets, the surface-descriptor font-pointer slot, and the
; FNT_BSS render scratch. Include BEFORE .ORG, AFTER gfx_defs.inc. Pairs with
; gfx_font.asm (routine code, included after the program body).
;
; A font is a descriptor-fronted blob: an 11-word descriptor + a contiguous
; glyph bitmap. Glyph for char c lives at  FNT_BITS + (c - FNT_FIRST)*16,
; one byte per row, MSB = leftmost pixel (8x16 monospace for F1a). The layout
; is proportional-ready (FNT_WTAB/FNT_OTAB reserved) and depth-blind: glyphs
; render through gfx_setpixel, so depth/bounds/clip are all inherited free.
;
; r2 (polish): font geometry is cached into FNT_BSS by gfx_setfont (the
; "compile the font" step), so the per-char path never re-reads the
; descriptor. => call gfx_setfont AFTER any edit to the font descriptor
; (e.g. patching FNT_BITS_*). Opaque text is now a clipped cell fill + the
; transparent renderer on top, so the inner loop only paints set bits.
; ============================================================================

; ---- surface-descriptor font pointer ---------------------------------------
; GS_FONT_PG/OF and GSO_FONT_PG/OF now live in gfx_defs.inc (descriptor block).

; ---- font descriptor field offsets (base-relative, [XY+#imm5]) -------------
FNT_FIRST       .EQU    0               ; word: first char code in glyph table
FNT_LAST        .EQU    2               ; word: last char code (inclusive)
FNT_WIDTH       .EQU    4               ; word: glyph cell width  (px; <=8 F1a)
FNT_HEIGHT      .EQU    6               ; word: glyph cell height (px)
FNT_ADVANCE     .EQU    8               ; word: monospace pen advance (px)
FNT_ASCENT      .EQU    10              ; word: baseline from cell top (carried)
FNT_FLAGS       .EQU    12              ; word: reserved (proportional bit etc.)
FNT_BITS_PG     .EQU    14              ; word: glyph bitmap base page
FNT_BITS_OF     .EQU    16              ; word: glyph bitmap base offset (glyph0)
FNT_WTAB        .EQU    18              ; word: width  table off (0=mono) [F4]
FNT_OTAB        .EQU    20              ; word: offset table off          [F4]
FNT_DESC_SIZE   .EQU    22              ; total descriptor size (bytes)

FNT_GLYPH_BYTES .EQU    16              ; bytes per glyph (8x16: 1 byte/row)

; ---- FNT_FLAGS bits --------------------------------------------------------
FNT_FL_PROP     .EQU    $0001           ; proportional: per-char WTAB/OTAB [F4]

; ---- synthesized style bits (fn_style; set via gfx_setfontstyle) -----------
;   Renderer-applied, no strike data needed (Mac-style). Normal = 0.
FS_BOLD         .EQU    $0001           ; smear stroke 1px right (rowbits |= rowbits>>1)

; ---- render scratch (high BSS, clear of RGN_BSS $6000-$6097) ---------------
; Single global -> font ops not re-entrant (one drawing context per task,
; matching gfx + regions). Relocate the whole block via FNT_BSS alone.
FNT_BSS         .EQU    $6200
; per-char render state
fn_x            .EQU    FNT_BSS+0       ; cell origin x (string: running pen x)
fn_y            .EQU    FNT_BSS+2       ; cell origin y
fn_char         .EQU    FNT_BSS+4       ; char being rendered
fn_fg           .EQU    FNT_BSS+6       ; foreground colour idx
fn_bg           .EQU    FNT_BSS+8       ; background colour idx (opaque only)
fn_oor          .EQU    FNT_BSS+10      ; out-of-range char -> blank glyph
fn_gp_pg        .EQU    FNT_BSS+12      ; glyph running row pointer (page)
fn_gp_of        .EQU    FNT_BSS+14      ; glyph running row pointer (offset)
fn_row          .EQU    FNT_BSS+16      ; current row index
fn_py           .EQU    FNT_BSS+18      ; current pixel y
fn_rowbits      .EQU    FNT_BSS+20      ; current row byte (low 8 bits; masked in-place)
fn_rowmask      .EQU    FNT_BSS+22      ; (was fn_col)  bound/final visible-cols mask
fn_clo          .EQU    FNT_BSS+24      ; (was fn_px)   region walk: col lo (temp)
fn_chi          .EQU    FNT_BSS+26      ; (was fn_mask) region walk: col hi / M(hi) (temp)
; cached font geometry (written once by gfx_setfont)
fn_w            .EQU    FNT_BSS+28      ; glyph width  (cols scanned)
fn_h            .EQU    FNT_BSS+30      ; glyph height (rows)
fn_adv          .EQU    FNT_BSS+32      ; pen advance (px) -- also opaque cell w
fn_first        .EQU    FNT_BSS+34      ; FNT_FIRST
fn_last         .EQU    FNT_BSS+36      ; FNT_LAST
fn_bits_pg      .EQU    FNT_BSS+38      ; glyph bitmap base page
fn_bits_of      .EQU    FNT_BSS+40      ; glyph bitmap base offset
; string-driver state
fn_sfg          .EQU    FNT_BSS+42      ; saved fg (or packed (bg<<8)|fg)
fn_sopaque      .EQU    FNT_BSS+44      ; 0 = transparent string, 1 = opaque
fn_tmpch        .EQU    FNT_BSS+46      ; current string char
fn_str_pg       .EQU    FNT_BSS+48      ; string running pointer (page)
fn_str_of       .EQU    FNT_BSS+50      ; string running pointer (offset)
; F3 row-blit
fn_acc          .EQU    FNT_BSS+52      ; _fn_rowmask region accumulator
fn_scale        .EQU    FNT_BSS+54      ; cached font scale (GS_FSCALE; 1/2/...)
; F4 proportional (per-char advance + bearing; tables cached at setfont)
fn_prop         .EQU    FNT_BSS+56      ; proportional? (0/1)
fn_cw           .EQU    FNT_BSS+58      ; this char's advance (w[c] prop / fn_adv mono,OOR)
fn_dx           .EQU    FNT_BSS+60      ; this char's image draw origin (fn_x + o[c])
fn_wtab_pg      .EQU    FNT_BSS+62      ; width-table  base ptr (bits_base + FNT_WTAB)
fn_wtab_of      .EQU    FNT_BSS+64
fn_otab_pg      .EQU    FNT_BSS+66      ; offset-table base ptr (bits_base + FNT_OTAB)
fn_otab_of      .EQU    FNT_BSS+68
; F3 row-blit visible-row clamp (B-lite)
fn_end          .EQU    FNT_BSS+70      ; end row (exclusive) for the scale-1 blit
fn_mult         .EQU    FNT_BSS+72      ; MULB shift multiplier (1<<(8-s)) in high byte
fn_style        .EQU    FNT_BSS+74      ; synthesized style bits (FS_*); 0 = normal
; F4-wide (>8px, word/row glyph data): wide flag + vtext_1 3-byte placement scratch
fn_wide         .EQU    FNT_BSS+76      ; 1 = FNT_WIDTH>8 (word/row data); 0 = byte/row
fn_vh           .EQU    FNT_BSS+78      ; vtext_1 wide: MULB(rh,mult) held across RMWs
; FNT_BSS top = $6250
