; ============================================================================
; GUISPL6.asm  --  KGFX mode-1 (1280x720 1bpp) patterned GUI demo, Spleen 6x12 mono font.
; ----------------------------------------------------------------------------
; GUIPROP1280 + pattern fill: the full classic-Mac look.
;   * 50% gray STIPPLE desktop (gfx_fillpat PAT_GRAY, screen-aligned)
;   * white windows, black frames
;   * horizontal-line title bars (PAT_HLINES) with a white title gap holding
;     the title text -- the Mac "racing stripes" title bar
;   * a light-gray scrollbar track (PAT_LTGRAY) on Window A
;   * Window A body poured into visA = A.rect - B.rect (rgn_subtract); Window B
;     occludes the corner; opaque-prop highlight row (bg=0 fg=1)
; Spleen 6x12 mono font throughout; regions + clip as before.
;
; Build: assemble as a .COM; gfx + regions + font include tail.
; ============================================================================
                .INCLUDE "../../kos_defs.inc"
                .INCLUDE "../gfx_defs.inc"
                .INCLUDE "../gfx_regions_defs.inc"
                .INCLUDE "../gfx_font_defs.inc"

; ---- "palette": 1bpp is two values --------------------------------------
C_BLACK         .EQU    0               ; desktop / ink / frames
C_WHITE         .EQU    1               ; windows / bars / paper

; ---- region scratch (same slots as GUIDEMO/GUIPROP) -------------------------
vA_pg           .EQU    $0164
vA_of           .EQU    $0166
v2_pg           .EQU    $0168
v2_of           .EQU    $016A
oc_pg           .EQU    $016C
oc_of           .EQU    $016E

                .ORG    $0200
start:
                LEA     XY0, banner
                TRAP    #TRAP_PUTLN

                LOADI   D0, #1                  ; 1bpp mode 1 (1280x720)
                CALLR   gfx_open
                BCS     .busy
                MOVE    Y1, Y3
                LOADI   X1, #GS_BASE            ; XY1 = descriptor (held throughout)
                ; --- 50% gray stipple desktop ---
                LOADI   D0, #0
                STOREP  D0, Y3, [#gr_x]
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #1280
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #720
                STOREP  D0, Y3, [#gr_h]
                LEA     XY0, PAT_GRAY
                CALLR   gfx_fillpat

                ; --- Spleen 6x12 mono font current ---
                LEA     XY0, spleen_6x12_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_spleen_6x12
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALLR   gfx_setfont             ; caches prop flag + WTAB/OTAB

                ; ============================================================
                ; 1. top menu bar (white, black text)
                ; ============================================================
                LOADI   D0, #0
                STOREP  D0, Y3, [#gr_x]
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #1280
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #24
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_WHITE
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_fillrect
                LEA     XY0, top_label
                LOADI   D0, #12
                LOADI   D1, #5
                LOADI   D3, #C_BLACK            ; fg=0 -> black text on white bar
                CALLR   gfx_draw_string

                ; ============================================================
                ; 2. Window A content region = visA = A.rect - B.rect
                ;    A content rect (84,112,716,546); B rect (480,380,1080,670)
                ; ============================================================
                LOADI   D0, #256
                CALLR   rgn_new
                BCS     .nomem
                MOVE    D0, Y0
                STOREP  D0, Y3, [#vA_pg]
                MOVE    D0, X0
                STOREP  D0, Y3, [#vA_of]
                LOADI   D0, #256
                CALLR   rgn_new
                BCS     .nomem
                MOVE    D0, Y0
                STOREP  D0, Y3, [#v2_pg]
                MOVE    D0, X0
                STOREP  D0, Y3, [#v2_of]
                LOADI   D0, #256
                CALLR   rgn_new
                BCS     .nomem
                MOVE    D0, Y0
                STOREP  D0, Y3, [#oc_pg]
                MOVE    D0, X0
                STOREP  D0, Y3, [#oc_of]

                ; visA = A content rect
                LOADP   D0, Y3, [#vA_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#vA_of]
                MOVE    X0, D0
                LOADI   D0, #84
                LOADI   D1, #112
                LOADI   D2, #716
                LOADI   D3, #546
                CALLR   rgn_set_rect
                ; occ = Window B rect
                LOADP   D0, Y3, [#oc_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#oc_of]
                MOVE    X0, D0
                LOADI   D0, #480
                LOADI   D1, #380
                LOADI   D2, #1080
                LOADI   D3, #670
                CALLR   rgn_set_rect
                ; visA2 = visA - occ
                LOADP   D0, Y3, [#v2_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#v2_of]
                MOVE    X0, D0
                LOADP   D0, Y3, [#vA_pg]
                MOVE    Y1, D0
                LOADP   D0, Y3, [#vA_of]
                MOVE    X1, D0
                LOADP   D0, Y3, [#oc_pg]
                MOVE    Y2, D0
                LOADP   D0, Y3, [#oc_of]
                MOVE    X2, D0
                CALLR   rgn_subtract
                BCS     .nomem
                ; swap stashes so visA now names the result
                LOADP   D0, Y3, [#vA_pg]
                LOADP   D1, Y3, [#v2_pg]
                STOREP  D1, Y3, [#vA_pg]
                STOREP  D0, Y3, [#v2_pg]
                LOADP   D0, Y3, [#vA_of]
                LOADP   D1, Y3, [#v2_of]
                STOREP  D1, Y3, [#vA_of]
                STOREP  D0, Y3, [#v2_of]

                ; restore XY1 = descriptor (rgn_subtract used XY1/XY2)
                MOVE    Y1, Y3
                LOADI   X1, #GS_BASE

                ; --- Window A chrome (unclipped): white panel + frame + title -
                LOADI   D0, #80                 ; panel (80,80,640,470)
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #80
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #640
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #470
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_WHITE
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_fillrect
                LOADI   D0, #80                 ; frame (80,80,640,470)
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #80
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #640
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #470
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_BLACK
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_rect
                ; title bar: horizontal-line pattern + white title gap
                LOADI   D0, #81
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #81
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #638
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #25
                STOREP  D0, Y3, [#gr_h]
                LEA     XY0, PAT_HLINES
                CALLR   gfx_fillpat
                LOADI   D0, #90                 ; white gap for the title text
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #83
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #330
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #21
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_WHITE
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_fillrect
                LEA     XY0, a_title            ; title (black in the white gap)
                LOADI   D0, #96
                LOADI   D1, #86
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string
                LOADI   D0, #84                 ; divider under the title bar
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #108
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #632
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #2
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_BLACK
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_fillrect
                ; light-gray scrollbar track on the right edge
                LOADI   D0, #704
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #110
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #14
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #438
                STOREP  D0, Y3, [#gr_h]
                LEA     XY0, PAT_LTGRAY
                CALLR   gfx_fillpat
                LOADI   D0, #704                ; scrollbar frame
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #110
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #14
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #438
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_BLACK
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_rect

                ; --- Window A body: clip to visA, pour prop paragraph ---
                LOADP   D0, Y3, [#vA_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#vA_of]
                MOVE    X0, D0
                CALLR   gfx_setclip             ; clip ON (L-shape)

                ; ---- font catalog: small -> large, each at its own leading ----
                ; -- Spleen 6x12 (pitch 14) --
                LEA     XY0, spleen_6x12_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_spleen_6x12
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALLR   gfx_setfont
                LEA     XY0, a_h6
                LOADI   D0, #96
                LOADI   D1, #118
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string
                LEA     XY0, a_s6a
                LOADI   D0, #96
                LOADI   D1, #132
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string
                LEA     XY0, a_s6b
                LOADI   D0, #96
                LOADI   D1, #146
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string

                ; -- Spleen 8x16 (pitch 18) --
                LEA     XY0, spleen_8x16_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_spleen_8x16
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALLR   gfx_setfont
                LEA     XY0, a_h8
                LOADI   D0, #96
                LOADI   D1, #172
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string
                LEA     XY0, a_s8a
                LOADI   D0, #96
                LOADI   D1, #190
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string
                LEA     XY0, a_s8b
                LOADI   D0, #96
                LOADI   D1, #208
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string

                ; -- ModernDOS 8x16 mono (pitch 18) --
                LEA     XY0, moderndos_8x16_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_moderndos_8x16
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALLR   gfx_setfont
                LEA     XY0, a_hm
                LOADI   D0, #96
                LOADI   D1, #234
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string
                LEA     XY0, a_sma
                LOADI   D0, #96
                LOADI   D1, #252
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string
                LEA     XY0, a_smb
                LOADI   D0, #96
                LOADI   D1, #270
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string

                ; -- ModernDOS 8x16 proportional (pitch 18) --
                ;    last lines run past y=380 -> bitten by Window B (clip demo)
                LEA     XY0, moderndos_8x16_prop_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_moderndos_8x16_prop
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALLR   gfx_setfont
                LEA     XY0, a_hp
                LOADI   D0, #96
                LOADI   D1, #296
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string
                LEA     XY0, a_spa
                LOADI   D0, #96
                LOADI   D1, #314
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string
                LEA     XY0, a_spb
                LOADI   D0, #96
                LOADI   D1, #332
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string
                LEA     XY0, a_spc
                LOADI   D0, #96
                LOADI   D1, #350
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string
                LEA     XY0, a_spd
                LOADI   D0, #96
                LOADI   D1, #384
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string
                LEA     XY0, a_spe
                LOADI   D0, #96
                LOADI   D1, #402
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string

                ; -- footer note (back to Spleen 6x12), left of Window B --
                LEA     XY0, spleen_6x12_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_spleen_6x12
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALLR   gfx_setfont
                LEA     XY0, a_note
                LOADI   D0, #96
                LOADI   D1, #430
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string

                LOADI   D0, #0                  ; clip OFF
                MOVE    Y0, D0
                MOVE    X0, D0
                CALLR   gfx_setclip

                ; ============================================================
                ; 3. Window B (front) -- occludes A's corner
                ;    panel (480,380,600,290); rect = occ above
                ; ============================================================
                LOADI   D0, #480
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #380
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #600
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #290
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_WHITE
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_fillrect
                LOADI   D0, #480
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #380
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #600
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #290
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_BLACK
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_rect
                ; title bar: horizontal-line pattern + white title gap
                LOADI   D0, #481
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #381
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #598
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #25
                STOREP  D0, Y3, [#gr_h]
                LEA     XY0, PAT_HLINES
                CALLR   gfx_fillpat
                LOADI   D0, #490                ; white gap for the title
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #383
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #150
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #21
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_WHITE
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_fillrect
                LEA     XY0, b_title
                LOADI   D0, #496
                LOADI   D1, #386
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string
                LOADI   D0, #484                ; divider under the title bar
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #408
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #592
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #2
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_BLACK
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_fillrect
                LEA     XY0, b_l0
                LOADI   D0, #496
                LOADI   D1, #420
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string
                ; --- opaque-prop highlight row (inverted selected item) ---
                LEA     XY0, b_sel
                LOADI   D0, #496
                LOADI   D1, #446
                LOADI   D3, #$0001              ; (bg<<8)|fg = bg black(0), fg white(1)
                CALLR   gfx_draw_string_opaque
                LEA     XY0, b_l1
                LOADI   D0, #496
                LOADI   D1, #478
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string
                LEA     XY0, b_l2
                LOADI   D0, #496
                LOADI   D1, #504
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string

                ; ============================================================
                ; 4. status bar (white, black text)
                ; ============================================================
                LOADI   D0, #0
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #696
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #1280
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #24
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_WHITE
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_fillrect
                LEA     XY0, status
                LOADI   D0, #12
                LOADI   D1, #701
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string

                ; --- hold for a key, then exit ---
.hold:
                LEA     XY0, prompt
                TRAP    #TRAP_PUTLN
                TRAP    #TRAP_GETCHAR
                TRAP    #TRAP_EXIT

.busy:
                LEA     XY0, msg_busy
                TRAP    #TRAP_PUTLN
                TRAP    #TRAP_EXIT
.nomem:
                LEA     XY0, msg_nomem
                TRAP    #TRAP_PUTLN
                TRAP    #TRAP_EXIT

; ----------------------------------------------------------------------------
banner          .TEXT   "KGFX GUISPL6: mode 1 1bpp, patterns + Spleen 6x12 mono", 0
prompt          .TEXT   "drawn - press a key to exit", 0
msg_busy        .TEXT   "gfx: graphics busy", 0
msg_nomem       .TEXT   "rgn: out of heap", 0

top_label       .TEXT   "k/OS  KGFX        File   Edit   View   Window   Help", 0
status          .TEXT   "GUISPL6 - 1280x720 1bpp - gray stipple desktop + patterned title bars + Spleen 6x12 mono - press a key", 0

a_title         .TEXT   "Document  -  Font catalog  (1bpp)", 0
a_h6            .TEXT   "Spleen 6x12 mono  -  6 px fixed cell:", 0
a_s6a           .TEXT   "the quick brown fox jumps over the lazy dog 0123456789", 0
a_s6b           .TEXT   "iiii MMMM align  -  !?#&@  ITWmi.l'  ()[]{}<>/", 0
a_h8            .TEXT   "Spleen 8x16 mono  -  8 px fixed cell:", 0
a_s8a           .TEXT   "the quick brown fox jumps over the lazy dog", 0
a_s8b           .TEXT   "0123456789  !?#&@  iiii MMMM align", 0
a_hm            .TEXT   "ModernDOS 8x16 mono:", 0
a_sma           .TEXT   "the quick brown fox jumps over the lazy dog", 0
a_smb           .TEXT   "0123456789  !?#&@  ABCDEFG abcdefg", 0
a_hp            .TEXT   "ModernDOS 8x16 proportional:", 0
a_spa           .TEXT   "the quick brown fox jumps over the lazy dog", 0
a_spb           .TEXT   "Proportional spacing: iiii is narrow, MMMM is wide.", 0
a_spc           .TEXT   "Mixed: Illustration, Million, Window, mimimi.", 0
a_spd           .TEXT   "This lower-right zone is bitten by Window B in front -", 0
a_spe           .TEXT   "visible area is A.rect minus B.rect, every glyph clips free.", 0
a_note          .TEXT   "(Spleen 12x24 / 16x32 await the >8px width path)", 0

b_title         .TEXT   "Inspector", 0
b_l0            .TEXT   "Font: Spleen 6x12", 0
b_sel           .TEXT   " gfx_font_spleen_6x12.inc ", 0
b_l1            .TEXT   "monospace - no width table", 0
b_l2            .TEXT   "fixed 6 px advance", 0

                .ALIGN
PAT_GRAY        .BYTE   $AA, $55, $AA, $55, $AA, $55, $AA, $55   ; 50% stipple desktop
PAT_HLINES      .BYTE   $FF, $00, $FF, $00, $FF, $00, $FF, $00   ; title-bar stripes
PAT_LTGRAY      .BYTE   $44, $11, $44, $11, $44, $11, $44, $11   ; scrollbar track

                .ALIGN
                .INCLUDE "../font/gfx_font_spleen_6x12.inc"
                .ALIGN
                .INCLUDE "../font/gfx_font_spleen_8x16.inc"
                .ALIGN
                .INCLUDE "../font/gfx_font_moderndos_8x16.inc"
                .ALIGN
                .INCLUDE "../font/gfx_font_moderndos_8x16_prop.inc"

                .ALIGN
                .INCLUDE "../gfx.asm"
                .INCLUDE "../gfx_1bpp.asm"
                .INCLUDE "../gfx_8bpp.asm"
                .INCLUDE "../gfx_regions.asm"
                .INCLUDE "../gfx_font.asm"
