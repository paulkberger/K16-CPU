; ============================================================================
; GUIDEMO.asm  --  KGFX showcase: regions + ModernDOS 8x16 font, one screen.
; ----------------------------------------------------------------------------
; A "desktop" that exercises the whole stack in anger -- no library change,
; just primitives + regions + the font layer:
;
;   * top strip          : opaque-feel title bar + label
;   * charset card (left) : all 96 printable glyphs (ASCII 32..127) in a grid
;   * Window A (centre)   : its CONTENT is clipped to  visA = A.rect - B.rect,
;                           so text + panel fill pour into an L-shape; the
;                           lower-right BITE is exactly where Window B sits.
;   * Window B (right)    : a normal solid window drawn last, occupying the
;                           bite -> reads as B occluding A, but the hole was
;                           computed by rgn_subtract (visible-region), not by
;                           painter's order.
;
; Holds at the end (graphics auto-reset on sys_exit). Colour indices are
; palette-dependent; only contrast matters.
; ============================================================================
                .INCLUDE "../../kos_defs.inc"
                .INCLUDE "../gfx_defs.inc"
                .INCLUDE "../gfx_regions_defs.inc"
                .INCLUDE "../gfx_font_defs.inc"

; ---- harness scratch (task page, $0164+ free per the gfx low-page map) ------
vA_pg           .EQU    $0164
vA_of           .EQU    $0166
v2_pg           .EQU    $0168
v2_of           .EQU    $016A
oc_pg           .EQU    $016C
oc_of           .EQU    $016E
cs_ch           .EQU    $0170           ; charset loop: current char
cs_x            .EQU    $0172
cs_y            .EQU    $0174

; ---- palette indices (guesses; swap if your palette differs) ----------------
C_BG            .EQU    0               ; black desktop
C_TOPBAR        .EQU    7               ; light grey
C_CARD          .EQU    1               ; blue   (card title bar)
C_PANEL         .EQU    8               ; dark grey (card / A content panel)
C_ATITLE        .EQU    2               ; green  (Window A title)
C_BTITLE        .EQU    4               ; red    (Window B title)
C_BPANEL        .EQU    1               ; blue   (Window B content)
C_FRAME         .EQU    15              ; white  (outlines)
C_TEXT          .EQU    15              ; white  (text)

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

                ; --- make the ASCII font current ---
                LEA     XY0, ascii_glyph_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_ascii
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALLR   gfx_setfont

                ; ============================================================
                ; 1. top strip
                ; ============================================================
                LOADI   D0, #0
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #0
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #640
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #22
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_TOPBAR
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_fillrect
                LEA     XY0, top_label
                LOADI   D0, #8
                LOADI   D1, #5
                LOADI   D3, #C_TEXT
                CALLR   gfx_draw_string

                ; ============================================================
                ; 2. charset card (left): panel, title bar, frame, 16x6 grid
                ; ============================================================
                ; content panel
                LOADI   D0, #26
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #60
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #158
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #128
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_PANEL
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_fillrect
                ; title bar
                LOADI   D0, #24
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #40
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #160
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #18
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_CARD
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_fillrect
                ; frame
                LOADI   D0, #24
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #40
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #160
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #150
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_FRAME
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_rect
                ; title text
                LEA     XY0, card_title
                LOADI   D0, #30
                LOADI   D1, #42
                LOADI   D3, #C_TEXT
                CALLR   gfx_draw_string
                ; --- charset grid: char c at (32 + col*8, 64 + row*16) ---
                LOADI   D0, #32
                STOREP  D0, Y3, [#cs_ch]
.cs_loop:
                LOADP   D0, Y3, [#cs_ch]
                CMP     D0, #128
                BGE     .cs_done
                SUB     D0, #32                  ; idx = c - 32
                MOVE    D1, D0
                AND     D1, #15                  ; col = idx & 15
                MOVE    D2, D0
                SHR     D2
                SHR     D2
                SHR     D2
                SHR     D2                       ; row = idx >> 4
                ; x = 32 + col*8
                ADD     D1, D1
                ADD     D1, D1
                ADD     D1, D1
                ADD     D1, #32
                STOREP  D1, Y3, [#cs_x]
                ; y = 64 + row*16
                SHL4    D2
                ADD     D2, #64
                STOREP  D2, Y3, [#cs_y]
                LOADP   D0, Y3, [#cs_x]
                LOADP   D1, Y3, [#cs_y]
                LOADP   D2, Y3, [#cs_ch]
                LOADI   D3, #C_TEXT
                CALLR   gfx_draw_char
                LOADP   D0, Y3, [#cs_ch]
                ADD     D0, #1
                STOREP  D0, Y3, [#cs_ch]
                BRA     .cs_loop
.cs_done:

                ; ============================================================
                ; 3. Window A content = visA = A.rect(260,88,560,330) - B
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

                ; visA = A content rect (260,88,560,330)
                LOADP   D0, Y3, [#vA_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#vA_of]
                MOVE    X0, D0
                LOADI   D0, #260
                LOADI   D1, #88
                LOADI   D2, #560
                LOADI   D3, #330
                CALLR   rgn_set_rect
                ; occ = Window B rect (430,200,610,360)
                LOADP   D0, Y3, [#oc_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#oc_of]
                MOVE    X0, D0
                LOADI   D0, #430
                LOADI   D1, #200
                LOADI   D2, #610
                LOADI   D3, #360
                CALLR   rgn_set_rect
                ; visA2 = visA - occ ; swap visA <-> visA2
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
                ; clip to visA
                LOADP   D0, Y3, [#vA_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#vA_of]
                MOVE    X0, D0
                CALLR   gfx_setclip

                ; A content panel fill (260,88, 300x242) -> clipped to L-shape
                LOADI   D0, #260
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #88
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #300
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #242
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_PANEL
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_fillrect

                ; A text lines (clipped): top rows full width, lower rows cut
                ; at x=430 where the bite begins.
                LEA     XY0, a_l0
                LOADI   D1, #92
                CALLR   .drawline
                LEA     XY0, a_l1
                LOADI   D1, #108
                CALLR   .drawline
                LEA     XY0, a_l2
                LOADI   D1, #124
                CALLR   .drawline
                LEA     XY0, a_l3
                LOADI   D1, #140
                CALLR   .drawline
                LEA     XY0, a_l4
                LOADI   D1, #156
                CALLR   .drawline
                LEA     XY0, a_l5
                LOADI   D1, #172
                CALLR   .drawline
                LEA     XY0, a_l6
                LOADI   D1, #188
                CALLR   .drawline
                LEA     XY0, a_l7
                LOADI   D1, #204
                CALLR   .drawline
                LEA     XY0, a_l8
                LOADI   D1, #220
                CALLR   .drawline
                LEA     XY0, a_l9
                LOADI   D1, #236
                CALLR   .drawline
                LEA     XY0, a_l10
                LOADI   D1, #252
                CALLR   .drawline
                LEA     XY0, a_l11
                LOADI   D1, #268
                CALLR   .drawline

                ; --- clip OFF ---
                LOADI   D0, #0
                MOVE    Y0, D0
                MOVE    X0, D0
                CALLR   gfx_setclip

                ; ============================================================
                ; 4. Window A chrome (title bar + frame + title), unclipped
                ; ============================================================
                LOADI   D0, #260
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #70
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #300
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #18
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_ATITLE
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_fillrect
                LOADI   D0, #260
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #70
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #300
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #260
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_FRAME
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_rect
                LEA     XY0, winA_title
                LOADI   D0, #266
                LOADI   D1, #72
                LOADI   D3, #C_TEXT
                CALLR   gfx_draw_string

                ; ============================================================
                ; 5. Window B (front): solid, drawn last, sits in the bite
                ; ============================================================
                LOADI   D0, #430
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #218
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #180
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #142
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_BPANEL
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_fillrect
                LOADI   D0, #430
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #200
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #180
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #18
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_BTITLE
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_fillrect
                LOADI   D0, #430
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #200
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #180
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #160
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_FRAME
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_rect
                LEA     XY0, winB_title
                LOADI   D0, #436
                LOADI   D1, #202
                LOADI   D3, #C_TEXT
                CALLR   gfx_draw_string
                LEA     XY0, winB_l1
                LOADI   D0, #436
                LOADI   D1, #226
                LOADI   D3, #C_TEXT
                CALLR   gfx_draw_string
                LEA     XY0, winB_l2
                LOADI   D0, #436
                LOADI   D1, #242
                LOADI   D3, #C_TEXT
                CALLR   gfx_draw_string

.hold:
                BRA     .hold
.busy:
                LEA     XY0, msg_busy
                TRAP    #TRAP_PUTLN
                TRAP    #TRAP_EXIT
.nomem:
                LEA     XY0, msg_nomem
                TRAP    #TRAP_PUTLN
                TRAP    #TRAP_EXIT

; ----------------------------------------------------------------------------
; .drawline -- draw a string at x=268 in white, y in D1 (Window A text helper)
; ----------------------------------------------------------------------------
.drawline:
                LOADI   D0, #268
                LOADI   D3, #C_TEXT
                CALLR   gfx_draw_string
                RET

; ----------------------------------------------------------------------------
banner          .TEXT   "KGFX GUI demo: regions + ModernDOS 8x16", 0
msg_busy        .TEXT   "gfx: graphics busy", 0
msg_nomem       .TEXT   "rgn: out of heap", 0
top_label       .TEXT   "k/OS  KGFX   regions + ModernDOS 8x16 font", 0
card_title      .TEXT   "ASCII 32-127", 0
winA_title      .TEXT   "Window A  (region-clipped)", 0
winB_title      .TEXT   "Window B (front)", 0
winB_l1         .TEXT   "occludes A via", 0
winB_l2         .TEXT   "rgn_subtract", 0

a_l0            .TEXT   "k/OS KGFX  -  Window A", 0
a_l1            .TEXT   "------------------------------", 0
a_l2            .TEXT   "Text poured into a region:", 0
a_l3            .TEXT   "  visible = A.rect - B.rect", 0
a_l4            .TEXT   "Every glyph clips for free", 0
a_l5            .TEXT   "via gfx_setpixel + GS_CLIP.", 0
a_l6            .TEXT   "ModernDOS 8x16, CC0 public.", 0
a_l7            .TEXT   "ABCDEFGHIJKLMNOPQRSTUVWXYZ 0-9", 0
a_l8            .TEXT   "the quick brown fox jumps over", 0
a_l9            .TEXT   "the lazy dog.  0123456789 !?#&", 0
a_l10           .TEXT   "this row is cut by the bite ->", 0
a_l11           .TEXT   "regions + fonts = a GUI.", 0

                .ALIGN
                .INCLUDE "../gfx_font_ascii.inc"

                .ALIGN
                .INCLUDE "../gfx.asm"
                .INCLUDE "../gfx_regions.asm"
                .INCLUDE "../gfx_font.asm"
