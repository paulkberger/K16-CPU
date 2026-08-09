; ============================================================================
; GUIPROP.asm  --  KGFX mode-2 (640x480 8bpp) GUI demo, PROPORTIONAL font.
; ----------------------------------------------------------------------------
; The 640 GUI mockup, re-skinned with the F4 proportional font
; (gfx_font_moderndos_8x16_prop.inc). Shows where proportional reads like a real GUI:
;   * top menu bar + status bar with tight prop labels
;   * Window A (back): title bar + body paragraph poured into a region that is
;     A.rect - B.rect (rgn_subtract) -> A's lower-right corner is bitten by B,
;     every glyph clipped for free by _fn_rowmask (the fn_dx clip path)
;   * Window B (front): title bar + body + ONE opaque-prop highlight row
;     (bg<<8|fg) -> a selected-list-item bar: proportional cells abut tight,
;     white glyph on a coloured bar, no left-spill (the left-justify payoff)
;
; NOTE: the GUIDEMO charset grid is deliberately gone -- a fixed-stride grid is
; a monospace widget; proportional advance would make it ragged. Chrome + prose
; is the proportional showcase.
;
; Build: assemble as a .COM; same include tail as the other gfx/Test harnesses.
; ============================================================================
                .INCLUDE "../../kos_defs.inc"
                .INCLUDE "../gfx_defs.inc"
                .INCLUDE "../gfx_regions_defs.inc"
                .INCLUDE "../font/gfx_font_defs.inc"

; ---- palette (mode 2 boot palette indices) ----------------------------------
C_BG            .EQU    0               ; black desktop
C_TOPBAR        .EQU    7               ; light grey (menu / status bars)
C_BARTEXT       .EQU    0               ; black text on the grey bars
C_ATITLE        .EQU    2               ; green  (Window A title bar)
C_BTITLE        .EQU    4               ; red    (Window B title bar)
C_PANEL         .EQU    8               ; dark grey (Window A content)
C_BPANEL        .EQU    1               ; blue   (Window B content)
C_HILITE        .EQU    1               ; blue   (selected-row bar; opaque bg)
C_FRAME         .EQU    15              ; white  (outlines)
C_TEXT          .EQU    15              ; white  (body text)

; ---- region scratch (same slots as GUIDEMO) ---------------------------------
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

                LOADI   D0, #2                  ; 8bpp mode 2 (640x480)
                CALLR   gfx_open
                BCS     .busy
                MOVE    Y1, Y3
                LOADI   X1, #GS_BASE            ; XY1 = descriptor (held throughout)
                LOADI   D0, #C_BG
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
                ; 1. top menu bar
                ; ============================================================
                LOADI   D0, #0
                STOREP  D0, Y3, [#gr_x]
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #640
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #20
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_TOPBAR
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_fillrect
                LEA     XY0, top_label
                LOADI   D0, #8
                LOADI   D1, #3
                LOADI   D3, #C_BARTEXT
                CALLR   gfx_draw_string

                ; ============================================================
                ; 2. Window A content region = visA = A.rect - B.rect
                ;    A content rect (44,72,396,360); B rect (300,210,600,400)
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
                LOADI   D0, #44
                LOADI   D1, #72
                LOADI   D2, #396
                LOADI   D3, #360
                CALLR   rgn_set_rect
                ; occ = Window B rect
                LOADP   D0, Y3, [#oc_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#oc_of]
                MOVE    X0, D0
                LOADI   D0, #300
                LOADI   D1, #210
                LOADI   D2, #600
                LOADI   D3, #400
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

                ; --- Window A chrome (unclipped): title bar + panel + frame ---
                LOADI   D0, #40                 ; title bar (40,48,360,20)
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #48
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #360
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #20
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_ATITLE
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_fillrect
                LOADI   D0, #40                 ; content panel (40,68,360,304)
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #68
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #360
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #304
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_PANEL
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_fillrect
                LOADI   D0, #40                 ; frame (40,48,360,324)
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #48
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #360
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #324
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_FRAME
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_rect
                LEA     XY0, a_title            ; title text (prop, unclipped)
                LOADI   D0, #48
                LOADI   D1, #51
                LOADI   D3, #C_TEXT
                CALLR   gfx_draw_string

                ; --- Window A body: clip to visA, pour prop paragraph ---
                LOADP   D0, Y3, [#vA_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#vA_of]
                MOVE    X0, D0
                CALLR   gfx_setclip             ; clip ON (L-shape)
                LEA     XY0, a_l0
                LOADI   D0, #52
                LOADI   D1, #80
                LOADI   D3, #C_TEXT
                CALLR   gfx_draw_string
                LEA     XY0, a_l1
                LOADI   D0, #52
                LOADI   D1, #100
                LOADI   D3, #C_TEXT
                CALLR   gfx_draw_string
                LEA     XY0, a_l2
                LOADI   D0, #52
                LOADI   D1, #120
                LOADI   D3, #C_TEXT
                CALLR   gfx_draw_string
                LEA     XY0, a_l3
                LOADI   D0, #52
                LOADI   D1, #140
                LOADI   D3, #C_TEXT
                CALLR   gfx_draw_string
                LEA     XY0, a_l4
                LOADI   D0, #52
                LOADI   D1, #170
                LOADI   D3, #C_TEXT
                CALLR   gfx_draw_string
                LEA     XY0, a_l5               ; long lines: right end gets bitten
                LOADI   D0, #52
                LOADI   D1, #220
                LOADI   D3, #C_TEXT
                CALLR   gfx_draw_string
                LEA     XY0, a_l6
                LOADI   D0, #52
                LOADI   D1, #240
                LOADI   D3, #C_TEXT
                CALLR   gfx_draw_string
                LEA     XY0, a_l7
                LOADI   D0, #52
                LOADI   D1, #260
                LOADI   D3, #C_TEXT
                CALLR   gfx_draw_string
                LOADI   D0, #0                  ; clip OFF
                MOVE    Y0, D0
                MOVE    X0, D0
                CALLR   gfx_setclip

                ; ============================================================
                ; 3. Window B (front) -- occludes A's corner
                ;    title bar (300,210,300,20); panel (300,230,300,170)
                ; ============================================================
                LOADI   D0, #300
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #210
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #300
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #20
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_BTITLE
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_fillrect
                LOADI   D0, #300
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #230
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #300
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #170
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_BPANEL
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_fillrect
                LOADI   D0, #300
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #210
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #300
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #190
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_FRAME
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_rect
                LEA     XY0, b_title
                LOADI   D0, #308
                LOADI   D1, #213
                LOADI   D3, #C_TEXT
                CALLR   gfx_draw_string
                LEA     XY0, b_l0
                LOADI   D0, #308
                LOADI   D1, #240
                LOADI   D3, #C_TEXT
                CALLR   gfx_draw_string
                ; --- opaque-prop highlight row (selected list item) ---
                LEA     XY0, b_sel
                LOADI   D0, #308
                LOADI   D1, #264
                LOADI   D3, #$010F              ; (bg<<8)|fg = bg C_HILITE(1), fg white(15)
                CALLR   gfx_draw_string_opaque
                LEA     XY0, b_l1
                LOADI   D0, #308
                LOADI   D1, #292
                LOADI   D3, #C_TEXT
                CALLR   gfx_draw_string
                LEA     XY0, b_l2
                LOADI   D0, #308
                LOADI   D1, #312
                LOADI   D3, #C_TEXT
                CALLR   gfx_draw_string

                ; ============================================================
                ; 4. status bar
                ; ============================================================
                LOADI   D0, #0
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #460
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #640
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #20
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_TOPBAR
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_fillrect
                LEA     XY0, status
                LOADI   D0, #8
                LOADI   D1, #463
                LOADI   D3, #C_BARTEXT
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
banner          .TEXT   "KGFX GUIPROP: mode 2 8bpp, F4 proportional", 0
prompt          .TEXT   "drawn - press a key to exit", 0
msg_busy        .TEXT   "gfx: graphics busy", 0
msg_nomem       .TEXT   "rgn: out of heap", 0

top_label       .TEXT   "k/OS  KGFX        File   Edit   View   Window   Help", 0
status          .TEXT   "GUIPROP - regions + proportional ModernDOS - press a key", 0

a_title         .TEXT   "Document  -  proportional", 0
a_l0            .TEXT   "Proportional text in a window.", 0
a_l1            .TEXT   "Narrow i l . , ' hug the pen;", 0
a_l2            .TEXT   "wide m W # M @ get their room.", 0
a_l3            .TEXT   "the quick brown fox jumps over", 0
a_l4            .TEXT   "the lazy dog.  0123456789 !?#&", 0
a_l5            .TEXT   "This lower-right corner is bitten by Window B", 0
a_l6            .TEXT   "- the visible area is A.rect minus B.rect, so each", 0
a_l7            .TEXT   "glyph clips for free.  regions + prop = a GUI.", 0

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
