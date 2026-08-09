; ============================================================================
; GUIMOVE2.asm  --  KGFX movable window, DOUBLE-BUFFERED. WASD moves Window B;
;                   Window A's visible region (A.rect - B.rect) is recomputed
;                   every frame. Q quits.
; ----------------------------------------------------------------------------
; Two full framebuffers in the FB band: A=$B0_0000, B=$B5_0000 (5-page stride,
; non-overlapping). The gfx library reads its draw page from the descriptor's
; GS_FB_PAGE every call (vclear_8/vspan_8 do LOADD [XY1+#0]), so the entire
; scene is painted into the HIDDEN page; gfx_flip then points the Video Page
; register ($DC0000) at the freshly-drawn page and toggles GS_FB_PAGE to the
; other buffer. The eye only ever sees finished frames -> no clear-flash, no
; tearing. (VID_PAGE value = page number = high 16 bits of FB base; $B0^$B5=$05
; toggles the two.)  Mechanics lifted from CUBE4, routed through the descriptor.
;
; Keys:  w/a/s/d move B (12 px)   q quit
; ============================================================================
                .INCLUDE "../../kos_defs.inc"
                .INCLUDE "../gfx_defs.inc"
                .INCLUDE "../gfx_regions_defs.inc"
                .INCLUDE "../font/gfx_font_defs.inc"

; ---- double buffer ----------------------------------------------------------
FB_PAGE_A       .EQU    $00B0           ; front-on-boot (gfx_open default)
FB_PAGE_B       .EQU    $00B5           ; second buffer ($B5_0000..$B9_AFFF)
FB_PAGE_XOR     .EQU    $0005           ; $B0 ^ $B5 -> toggles the pair

; ---- geometry ---------------------------------------------------------------
AW_L            .EQU    260
AW_T            .EQU    88
AW_R            .EQU    560
AW_B            .EQU    330
BW              .EQU    160
BH              .EQU    130
STEP            .EQU    12
BX_MAX          .EQU    480
BY_MIN          .EQU    24
BY_MAX          .EQU    350

; ---- palette ----------------------------------------------------------------
C_BG            .EQU    0
C_TOPBAR        .EQU    7
C_PANEL         .EQU    8
C_ATITLE        .EQU    2
C_BTITLE        .EQU    4
C_BPANEL        .EQU    1
C_FRAME         .EQU    15
C_TEXT          .EQU    15

; ---- harness scratch --------------------------------------------------------
bx              .EQU    $0164
by              .EQU    $0166
rA_pg           .EQU    $0168
rA_of           .EQU    $016A
rB_pg           .EQU    $016C
rB_of           .EQU    $016E
rV_pg           .EQU    $0170
rV_of           .EQU    $0172

                .ORG    $0200
start:
                LEA     XY0, banner
                TRAP    #TRAP_PUTLN

                LOADI   D0, #2
                CALLR   gfx_open
                BCS     .busy
                MOVE    Y1, Y3
                LOADI   X1, #GS_BASE

                ; font
                LEA     XY0, moderndos_8x16_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_moderndos_8x16
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALLR   gfx_setfont

                ; regions
                LOADI   D0, #256
                CALLR   rgn_new
                BCS     .nomem
                MOVE    D0, Y0
                STOREP  D0, Y3, [#rA_pg]
                MOVE    D0, X0
                STOREP  D0, Y3, [#rA_of]
                LOADI   D0, #256
                CALLR   rgn_new
                BCS     .nomem
                MOVE    D0, Y0
                STOREP  D0, Y3, [#rB_pg]
                MOVE    D0, X0
                STOREP  D0, Y3, [#rB_of]
                LOADI   D0, #256
                CALLR   rgn_new
                BCS     .nomem
                MOVE    D0, Y0
                STOREP  D0, Y3, [#rV_pg]
                MOVE    D0, X0
                STOREP  D0, Y3, [#rV_of]

                ; rA = A content rect (fixed)
                LOADP   D0, Y3, [#rA_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#rA_of]
                MOVE    X0, D0
                LOADI   D0, #AW_L
                LOADI   D1, #AW_T
                LOADI   D2, #AW_R
                LOADI   D3, #AW_B
                CALLR   rgn_set_rect

                ; initial B position
                LOADI   D0, #430
                STOREP  D0, Y3, [#bx]
                LOADI   D0, #200
                STOREP  D0, Y3, [#by]

                ; --- clean both buffers' starting state ---
                ; front (A) is what's displayed on boot: clear it so the
                ; pre-first-flip moment isn't garbage.
                LOADI   D0, #FB_PAGE_A
                STOREP  D0, Y3, [#GS_FB_PAGE]
                LOADI   D0, #C_BG
                CALLR   gfx_clear
                ; switch draw target to the hidden buffer (B)
                LOADI   D0, #FB_PAGE_B
                STOREP  D0, Y3, [#GS_FB_PAGE]

                CALLR   redraw                  ; paints B hidden, flips to show it

; ---- input loop -------------------------------------------------------------
.kloop:
                TRAP    #TRAP_GETCHAR           ; D0 = key (blocks)
                CMP     D0, #'q'
                BEQ     .quit
                CMP     D0, #'Q'
                BEQ     .quit
                CMP     D0, #'w'
                BEQ     .k_up
                CMP     D0, #'s'
                BEQ     .k_dn
                CMP     D0, #'a'
                BEQ     .k_lf
                CMP     D0, #'d'
                BEQ     .k_rt
                BRA     .kloop

.k_up:
                LOADP   D0, Y3, [#by]
                SUB     D0, #STEP
                CMP     D0, #BY_MIN
                BGE     .k_up_s
                LOADI   D0, #BY_MIN
.k_up_s:
                STOREP  D0, Y3, [#by]
                BRA     .move
.k_dn:
                LOADP   D0, Y3, [#by]
                ADD     D0, #STEP
                CMP     D0, #BY_MAX
                BLE     .k_dn_s
                LOADI   D0, #BY_MAX
.k_dn_s:
                STOREP  D0, Y3, [#by]
                BRA     .move
.k_lf:
                LOADP   D0, Y3, [#bx]
                SUB     D0, #STEP
                CMP     D0, #0
                BGE     .k_lf_s
                LOADI   D0, #0
.k_lf_s:
                STOREP  D0, Y3, [#bx]
                BRA     .move
.k_rt:
                LOADP   D0, Y3, [#bx]
                ADD     D0, #STEP
                CMP     D0, #BX_MAX
                BLE     .k_rt_s
                LOADI   D0, #BX_MAX
.k_rt_s:
                STOREP  D0, Y3, [#bx]
.move:
                CALLR   redraw
                BRA     .kloop

.quit:
                TRAP    #TRAP_EXIT
.busy:
                LEA     XY0, msg_busy
                TRAP    #TRAP_PUTLN
                TRAP    #TRAP_EXIT
.nomem:
                LEA     XY0, msg_nomem
                TRAP    #TRAP_PUTLN
                TRAP    #TRAP_EXIT

; ============================================================================
; gfx_flip -- show the page we just drew, then aim drawing at the other buffer.
;   VID_PAGE := GS_FB_PAGE ; GS_FB_PAGE ^= FB_PAGE_XOR.  Clobbers D0,X0,Y0.
; ============================================================================
gfx_flip:
                LOADP   D0, Y3, [#GS_FB_PAGE]
                LOADI   X0, #<VID_PAGE
                LOADI   Y0, #>VID_PAGE
                STORED  D0, [XY0]                ; display the freshly-drawn page
                LOADP   D0, Y3, [#GS_FB_PAGE]
                XOR     D0, #FB_PAGE_XOR
                STOREP  D0, Y3, [#GS_FB_PAGE]    ; next frame draws to the other one
                RET

; ============================================================================
; redraw -- paint the whole scene into the HIDDEN buffer, then flip.
;   GS_FB_PAGE already points at the hidden page (set by the previous flip).
; ============================================================================
redraw:
                MOVE    Y1, Y3
                LOADI   X1, #GS_BASE
                LOADI   D0, #C_BG
                CALLR   gfx_clear

                ; help strip
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
                LEA     XY0, help
                LOADI   D0, #8
                LOADI   D1, #5
                LOADI   D3, #C_TEXT
                CALLR   gfx_draw_string

                ; rB = current B rect
                LOADP   D0, Y3, [#rB_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#rB_of]
                MOVE    X0, D0
                LOADP   D0, Y3, [#bx]
                LOADP   D1, Y3, [#by]
                LOADP   D2, Y3, [#bx]
                ADD     D2, #BW
                LOADP   D3, Y3, [#by]
                ADD     D3, #BH
                CALLR   rgn_set_rect

                ; rVis = rA - rB
                LOADP   D0, Y3, [#rV_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#rV_of]
                MOVE    X0, D0
                LOADP   D0, Y3, [#rA_pg]
                MOVE    Y1, D0
                LOADP   D0, Y3, [#rA_of]
                MOVE    X1, D0
                LOADP   D0, Y3, [#rB_pg]
                MOVE    Y2, D0
                LOADP   D0, Y3, [#rB_of]
                MOVE    X2, D0
                CALLR   rgn_subtract

                MOVE    Y1, Y3
                LOADI   X1, #GS_BASE
                BCS     .rd_noclip

                LOADP   D0, Y3, [#rV_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#rV_of]
                MOVE    X0, D0
                CALLR   gfx_setclip
                BRA     .rd_fillA
.rd_noclip:
                LOADI   D0, #0
                MOVE    Y0, D0
                MOVE    X0, D0
                CALLR   gfx_setclip
.rd_fillA:
                ; A content panel (clipped)
                LOADI   D0, #AW_L
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #AW_T
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #300
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #242
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_PANEL
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_fillrect

                ; A text (clipped)
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

                ; clip OFF for chrome + B
                LOADI   D0, #0
                MOVE    Y0, D0
                MOVE    X0, D0
                CALLR   gfx_setclip

                ; A chrome
                LOADI   D0, #AW_L
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
                LOADI   D0, #AW_L
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

                ; Window B at (bx,by)
                LOADP   D0, Y3, [#bx]
                STOREP  D0, Y3, [#gr_x]
                LOADP   D0, Y3, [#by]
                ADD     D0, #18
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #BW
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #112
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_BPANEL
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_fillrect
                LOADP   D0, Y3, [#bx]
                STOREP  D0, Y3, [#gr_x]
                LOADP   D0, Y3, [#by]
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #BW
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #18
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_BTITLE
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_fillrect
                LOADP   D0, Y3, [#bx]
                STOREP  D0, Y3, [#gr_x]
                LOADP   D0, Y3, [#by]
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #BW
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #BH
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_FRAME
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_rect
                LOADP   D0, Y3, [#bx]
                ADD     D0, #6
                LOADP   D1, Y3, [#by]
                ADD     D1, #2
                LEA     XY0, winB_title
                LOADI   D3, #C_TEXT
                CALLR   gfx_draw_string

                ; --- present the finished frame ---
                CALLR   gfx_flip
                RET

; .drawline -- string at x=268, white, y in D1
.drawline:
                LOADI   D0, #268
                LOADI   D3, #C_TEXT
                CALLR   gfx_draw_string
                RET

; ----------------------------------------------------------------------------
banner          .TEXT   "KGFX movable window (double-buffered): WASD, Q quit", 0
msg_busy        .TEXT   "gfx: graphics busy", 0
msg_nomem       .TEXT   "rgn: out of heap", 0
help            .TEXT   "WASD: move Window B    Q: quit   [double-buffered]", 0
winA_title      .TEXT   "Window A  (region-clipped)", 0
winB_title      .TEXT   "Window B (drag me)", 0

a_l0            .TEXT   "k/OS KGFX  -  Window A", 0
a_l1            .TEXT   "------------------------------", 0
a_l2            .TEXT   "Visible region tracks B:", 0
a_l3            .TEXT   "  visible = A.rect - B.rect", 0
a_l4            .TEXT   "Recomputed every frame as", 0
a_l5            .TEXT   "you drag B with the keys.", 0
a_l6            .TEXT   "Move B off A: text fills in.", 0
a_l7            .TEXT   "ABCDEFGHIJKLMNOPQRSTUVWXYZ 0-9", 0
a_l8            .TEXT   "the quick brown fox jumps over", 0
a_l9            .TEXT   "the lazy dog.  0123456789 !?#&", 0
a_l10           .TEXT   "no flicker now - off-screen draw", 0
a_l11           .TEXT   "regions + fonts = a GUI.", 0

                .ALIGN
                .INCLUDE "../font/gfx_font_moderndos_8x16.inc"

                .ALIGN
                .INCLUDE "../gfx.asm"
                .INCLUDE "../gfx_regions.asm"
                .INCLUDE "../font/gfx_font.asm"
