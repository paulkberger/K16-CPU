; ============================================================================
; GUIPROP1280.asm  --  KGFX mode-1 (1280x720 1bpp) GUI demo, PROPORTIONAL font.
; ----------------------------------------------------------------------------
; The GUIPROP mockup at 1280x720. Mode 1 is 1bpp, so there is NO palette: the
; colour chrome becomes a classic-Mac-style black & white treatment -- white
; windows / bars on a black desktop, black ink (frames, title + body text via
; the fg=0 inverse-text path), and an inverted (black bar, white text) opaque
; highlight row. Structure is identical to GUIPROP:
;   * menu bar + status bar (white, black prop labels)
;   * Window A (back): white panel + black frame + title; body paragraph poured
;     into visA = A.rect - B.rect (rgn_subtract) -> lower-right bitten by B,
;     every glyph clipped for free by _fn_rowmask (the fn_dx clip path)
;   * Window B (front): white panel + black frame + title + ONE opaque-prop
;     highlight row (bg=0 fg=1) -> inverted selected-list-item, tight cells,
;     no spill (the left-justify payoff)
;
; A and B are both white windows; they are told apart by their black frames,
; title dividers and the clipped body text -- not by colour.
;
; Build: assemble as a .COM; same include tail as the other gfx/Test harnesses.
; ============================================================================
                .INCLUDE "../../kos_defs.inc"
                .INCLUDE "../gfx_defs.inc"
                .INCLUDE "../gfx_regions_defs.inc"
                .INCLUDE "../font/gfx_font_defs.inc"

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
                LOADI   D0, #C_BLACK
                CALLR   gfx_clear

                ; --- proportional font current ---
                LEA     XY0, moderndos_8x16_prop_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_moderndos_8x16_prop
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
                LEA     XY0, a_title            ; title (black on white panel)
                LOADI   D0, #96
                LOADI   D1, #86
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string
                LOADI   D0, #84                 ; title divider line
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

                ; --- Window A body: clip to visA, pour prop paragraph ---
                LOADP   D0, Y3, [#vA_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#vA_of]
                MOVE    X0, D0
                CALLR   gfx_setclip             ; clip ON (L-shape)
                LEA     XY0, a_l0
                LOADI   D0, #96
                LOADI   D1, #120
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string
                LEA     XY0, a_l1
                LOADI   D0, #96
                LOADI   D1, #146
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string
                LEA     XY0, a_l2
                LOADI   D0, #96
                LOADI   D1, #172
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string
                LEA     XY0, a_l3
                LOADI   D0, #96
                LOADI   D1, #198
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string
                LEA     XY0, a_l4
                LOADI   D0, #96
                LOADI   D1, #224
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string
                LEA     XY0, a_l5               ; long lines: right end gets bitten
                LOADI   D0, #96
                LOADI   D1, #380
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string
                LEA     XY0, a_l6
                LOADI   D0, #96
                LOADI   D1, #406
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string
                LEA     XY0, a_l7
                LOADI   D0, #96
                LOADI   D1, #432
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
                LEA     XY0, b_title
                LOADI   D0, #496
                LOADI   D1, #386
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string
                LOADI   D0, #484                ; title divider
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
banner          .TEXT   "KGFX GUIPROP1280: mode 1 1bpp, F4 proportional", 0
prompt          .TEXT   "drawn - press a key to exit", 0
msg_busy        .TEXT   "gfx: graphics busy", 0
msg_nomem       .TEXT   "rgn: out of heap", 0

top_label       .TEXT   "k/OS  KGFX        File   Edit   View   Window   Help", 0
status          .TEXT   "GUIPROP1280 - 1280x720 1bpp - regions + proportional ModernDOS - press a key", 0

a_title         .TEXT   "Document  -  proportional  (1bpp)", 0
a_l0            .TEXT   "Proportional text in a 1-bit-per-pixel window.", 0
a_l1            .TEXT   "Narrow i l . , ' hug the pen;", 0
a_l2            .TEXT   "wide m W # M @ get their room.", 0
a_l3            .TEXT   "the quick brown fox jumps over the lazy dog.", 0
a_l4            .TEXT   "0123456789  !?#&  ITWmi.l'", 0
a_l5            .TEXT   "This lower-right corner is bitten by Window B in front -", 0
a_l6            .TEXT   "the visible area is A.rect minus B.rect, so every glyph", 0
a_l7            .TEXT   "clips for free.  regions + proportional fonts = a GUI.", 0

b_title         .TEXT   "Inspector", 0
b_l0            .TEXT   "Font: ModernDOS prop", 0
b_sel           .TEXT   " gfx_font_moderndos_8x16_prop.inc ", 0
b_l1            .TEXT   "width table active", 0
b_l2            .TEXT   "advance per glyph", 0

                .ALIGN
                .INCLUDE "../font/gfx_font_moderndos_8x16_prop.inc"

                .ALIGN
                .INCLUDE "../gfx.asm"
                .INCLUDE "../gfx_1bpp.asm"
                .INCLUDE "../gfx_8bpp.asm"
                .INCLUDE "../gfx_regions.asm"
                .INCLUDE "../font/gfx_font.asm"
