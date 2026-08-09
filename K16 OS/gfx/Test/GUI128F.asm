;  ============================================================================
; GUI128_FONTS.asm  --  KGFX mode-1 (1280x720 1bpp) GUI: a font sampler poured
;                       into a Mac-style Document window.
; ----------------------------------------------------------------------------
; Classic-Mac look (gray stipple desktop, racing-stripe title bars, menu and
; status bars) from GUI128, with the Document window enlarged and its body
; filled with one sample per converted face -- no IIGS header line. A smaller
; Inspector window still overlaps the Document's lower-right corner (visA =
; A.rect - B.rect, body clipped to visA). Chrome text uses Helvetica 12.
;
; FONTS (18): 15 IIGS (Courier/Helvetica/Times/New Century/Palatino) +
; ModernDOS prop + Spleen 6x12/8x16. The big Spleen 12x24/16x32 are omitted
; (they would blow the 64KB page).
;
; MEMORY: the engine keeps fixed task-page scratch at $6000-$6250. With ~40KB
; of strikes embedded the data would overrun it, so the font block is split:
; the 9 nearer faces sit below $6000, then .ORG $6260 reserves the scratch, and
; the other 9 plus the engine sit above. ADDRESSING: every engine call is
; CALL16 (engine is >32KB past the code); below-gap fonts use plain LEA,
; above-gap fonts use LEA mode 01 (base+disp). Build: assemble as a .COM.
; ============================================================================
                .INCLUDE "../../kos_defs.inc"
                .INCLUDE "../gfx_defs.inc"
                .INCLUDE "../gfx_regions_defs.inc"
                .INCLUDE "../gfx_font_defs.inc"

                .SPACE  gui128f
                        ; This binary's own task page.  kos_defs.inc's regions
                        ; (SYSVARS $0200, ...) are kernel-space and .SPACE is
                        ; sticky across an .INCLUDE, so without this the .ORG
                        ; below pins our code space to kernel and the
                        ; code-in-region guard fires at $000200.  RM 4.13.
                        ; Placed before BOTH .ORGs so it does not matter
                        ; which one pins the code space.

C_BLACK         .EQU    0
C_WHITE         .EQU    1

; ---- region scratch (same low slots as GUI128) -----------------------------
vA_pg           .EQU    $0164
vA_of           .EQU    $0166
v2_pg           .EQU    $0168
v2_of           .EQU    $016A
oc_pg           .EQU    $016C
oc_of           .EQU    $016E

                .ORG    $0200

                JMP16   start                   ; $0200 - universal entry
; --- .COM header (Part 60) -------------------------------------------------
; $0200 is a JMP16 so the image stays directly executable with no loader at
; all; the header follows at $0204 and is parsed separately, so a bad header
; can never endanger control flow.  The loader REFUSES a bad magic - there is
; no headerless fallback, so this file would not load at all without the
; block below.
;
; Every field is a full WORD, emitted with .WORD only: .BYTE does not accept
; symbols, and an all-.WORD block cannot leave an odd byte count to
; desynchronise what follows.
;
; NOTE the 12 bytes below shift everything after $0200 up by 12.  This file
; hand-packs its layout - nine font strikes below $6000, engine scratch at
; $6000-$6250, .ORG $6260 above - so confirm in the listing that the
; below-gap block still ends before $6260.  If it collides, move the gap to
; $6280 (and this comment with it).
COM_PAGES       .EQU    1       ; TOTAL contiguous pages, including heap
COM_HEAPPG      .EQU    0       ; how many of those are heap (0 = task page)

                .WORD   COM_MAGIC       ; $0204 - dumps as 52 42 "RB"
                .WORD   COM_VERSION     ; $0206 - header version
                .WORD   COM_PAGES       ; $0208 - total pages
                .WORD   COM_HEAPPG      ; $020A - heap pages (partition of pages)
; --- end of header; start follows at $020C

start:
                ; No console banner.  A graphics task has no back-buffer,
                ; so its text reaches the terminal directly and nothing
                ; records it; the mode switch a few instructions later
                ; hides it and the reap repaint erases it.  Title text
                ; belongs on the graphics surface, where it persists.
                LOADI   D0, #1                  ; 1bpp mode 1 (1280x720)
                CALL16  gfx_open
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
                CALL16  gfx_fillpat

                ; --- chrome font = Helvetica 12 ---
                LEA     XY0, helvetica_12_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_helvetica_12
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALL16  gfx_setfont

                ; ============================================================
                ; 1. top menu bar (white, black text)
                ; ============================================================
                LOADI   D0, #0
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #0
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #1280
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #24
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_WHITE
                STOREP  D0, Y3, [#gr_idx]
                CALL16  gfx_fillrect
                LEA     XY0, top_label
                LOADI   D0, #12
                LOADI   D1, #5
                LOADI   D3, #C_BLACK
                CALL16  gfx_draw_string

                ; ============================================================
                ; 2. regions: visA = A.content - B.rect
                ;    A content (60,74,1152,620) ; B rect (940,460,1240,640)
                ; ============================================================
                LOADI   D0, #256
                CALL16  rgn_new
                BCS     .nomem
                MOVE    D0, Y0
                STOREP  D0, Y3, [#vA_pg]
                MOVE    D0, X0
                STOREP  D0, Y3, [#vA_of]
                LOADI   D0, #256
                CALL16  rgn_new
                BCS     .nomem
                MOVE    D0, Y0
                STOREP  D0, Y3, [#v2_pg]
                MOVE    D0, X0
                STOREP  D0, Y3, [#v2_of]
                LOADI   D0, #256
                CALL16  rgn_new
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
                LOADI   D0, #60
                LOADI   D1, #74
                LOADI   D2, #1152
                LOADI   D3, #620
                CALL16  rgn_set_rect
                ; occ = Inspector rect
                LOADP   D0, Y3, [#oc_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#oc_of]
                MOVE    X0, D0
                LOADI   D0, #940
                LOADI   D1, #460
                LOADI   D2, #1240
                LOADI   D3, #640
                CALL16  rgn_set_rect
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
                CALL16  rgn_subtract
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
                ; restore XY1 = descriptor
                MOVE    Y1, Y3
                LOADI   X1, #GS_BASE

                ; ============================================================
                ; 3. Document window chrome (enlarged): panel + frame + title
                ;    panel (56,44,1100,580)
                ; ============================================================
                LOADI   D0, #56
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #44
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #1100
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #580
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_WHITE
                STOREP  D0, Y3, [#gr_idx]
                CALL16  gfx_fillrect
                LOADI   D0, #56
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #44
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #1100
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #580
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_BLACK
                STOREP  D0, Y3, [#gr_idx]
                CALL16  gfx_rect
                LOADI   D0, #57
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #45
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #1098
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #25
                STOREP  D0, Y3, [#gr_h]
                LEA     XY0, PAT_HLINES
                CALL16  gfx_fillpat
                LOADI   D0, #66
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #47
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #380
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #21
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_WHITE
                STOREP  D0, Y3, [#gr_idx]
                CALL16  gfx_fillrect
                LEA     XY0, a_title
                LOADI   D0, #74
                LOADI   D1, #50
                LOADI   D3, #C_BLACK
                CALL16  gfx_draw_string
                LOADI   D0, #60
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #70
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #1092
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #2
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_BLACK
                STOREP  D0, Y3, [#gr_idx]
                CALL16  gfx_fillrect

                ; --- Document body: clip to visA, pour the font sampler ---
                LOADP   D0, Y3, [#vA_pg]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#vA_of]
                MOVE    X0, D0
                CALL16  gfx_setclip             ; clip ON (L-shape)
                ; ---- courier_9 ----
                LEA     XY0, courier_9_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_courier_9
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALL16  gfx_setfont
                LEA     XY0, s_courier_9
                LOADI   D0, #76
                LOADI   D1, #88
                LOADI   D3, #C_BLACK
                CALL16  gfx_draw_string

                ; ---- courier_10 ----
                LEA     XY0, courier_10_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_courier_10
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALL16  gfx_setfont
                LEA     XY0, s_courier_10
                LOADI   D0, #76
                LOADI   D1, #101
                LOADI   D3, #C_BLACK
                CALL16  gfx_draw_string

                ; ---- courier_12 ----
                LEA     XY0, courier_12_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_courier_12
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALL16  gfx_setfont
                LEA     XY0, s_courier_12
                LOADI   D0, #76
                LOADI   D1, #115
                LOADI   D3, #C_BLACK
                CALL16  gfx_draw_string

                ; ---- helvetica_10 ----
                LEA     XY0, helvetica_10_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_helvetica_10
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALL16  gfx_setfont
                LEA     XY0, s_helvetica_10
                LOADI   D0, #76
                LOADI   D1, #141
                LOADI   D3, #C_BLACK
                CALL16  gfx_draw_string

                ; ---- helvetica_12 ----
                LEA     XY0, helvetica_12_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_helvetica_12
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALL16  gfx_setfont
                LEA     XY0, s_helvetica_12
                LOADI   D0, #75
                LOADI   D1, #155
                LOADI   D3, #C_BLACK
                CALL16  gfx_draw_string

                ; ---- helvetica_14 ----
                LEA     XY0, helvetica_14_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_helvetica_14
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALL16  gfx_setfont
                LEA     XY0, s_helvetica_14
                LOADI   D0, #75
                LOADI   D1, #171
                LOADI   D3, #C_BLACK
                CALL16  gfx_draw_string

                ; ---- times_10 ----
                LEA     XY0, times_10_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_times_10
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALL16  gfx_setfont
                LEA     XY0, s_times_10
                LOADI   D0, #76
                LOADI   D1, #199
                LOADI   D3, #C_BLACK
                CALL16  gfx_draw_string

                ; ---- times_12 ----
                LEA     XY0, times_12_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_times_12
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALL16  gfx_setfont
                LEA     XY0, s_times_12
                LOADI   D0, #76
                LOADI   D1, #213
                LOADI   D3, #C_BLACK
                CALL16  gfx_draw_string

                ; ---- times_14 ----
                LEA     XY0, times_14_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_times_14
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALL16  gfx_setfont
                LEA     XY0, s_times_14
                LOADI   D0, #75
                LOADI   D1, #228
                LOADI   D3, #C_BLACK
                CALL16  gfx_draw_string

                ; ---- new_century_10 ----
                LEA     XY2, start
                LOADI   D0, #(new_century_10_bits - start)
                LEA     XY0, XY2+D0
                MOVE    D2, Y0
                MOVE    D3, X0
                LOADI   D0, #(font_new_century_10 - start)
                LEA     XY0, XY2+D0
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALL16  gfx_setfont
                LEA     XY0, s_new_century_10
                LOADI   D0, #76
                LOADI   D1, #257
                LOADI   D3, #C_BLACK
                CALL16  gfx_draw_string

                ; ---- new_century_12 ----
                LEA     XY2, start
                LOADI   D0, #(new_century_12_bits - start)
                LEA     XY0, XY2+D0
                MOVE    D2, Y0
                MOVE    D3, X0
                LOADI   D0, #(font_new_century_12 - start)
                LEA     XY0, XY2+D0
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALL16  gfx_setfont
                LEA     XY0, s_new_century_12
                LOADI   D0, #76
                LOADI   D1, #272
                LOADI   D3, #C_BLACK
                CALL16  gfx_draw_string

                ; ---- new_century_14 ----
                LEA     XY2, start
                LOADI   D0, #(new_century_14_bits - start)
                LEA     XY0, XY2+D0
                MOVE    D2, Y0
                MOVE    D3, X0
                LOADI   D0, #(font_new_century_14 - start)
                LEA     XY0, XY2+D0
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALL16  gfx_setfont
                LEA     XY0, s_new_century_14
                LOADI   D0, #76
                LOADI   D1, #288
                LOADI   D3, #C_BLACK
                CALL16  gfx_draw_string

                ; ---- palatino_10 ----
                LEA     XY2, start
                LOADI   D0, #(palatino_10_bits - start)
                LEA     XY0, XY2+D0
                MOVE    D2, Y0
                MOVE    D3, X0
                LOADI   D0, #(font_palatino_10 - start)
                LEA     XY0, XY2+D0
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALL16  gfx_setfont
                LEA     XY0, s_palatino_10
                LOADI   D0, #76
                LOADI   D1, #318
                LOADI   D3, #C_BLACK
                CALL16  gfx_draw_string

                ; ---- palatino_12 ----
                LEA     XY2, start
                LOADI   D0, #(palatino_12_bits - start)
                LEA     XY0, XY2+D0
                MOVE    D2, Y0
                MOVE    D3, X0
                LOADI   D0, #(font_palatino_12 - start)
                LEA     XY0, XY2+D0
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALL16  gfx_setfont
                LEA     XY0, s_palatino_12
                LOADI   D0, #76
                LOADI   D1, #333
                LOADI   D3, #C_BLACK
                CALL16  gfx_draw_string

                ; ---- palatino_14 ----
                LEA     XY2, start
                LOADI   D0, #(palatino_14_bits - start)
                LEA     XY0, XY2+D0
                MOVE    D2, Y0
                MOVE    D3, X0
                LOADI   D0, #(font_palatino_14 - start)
                LEA     XY0, XY2+D0
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALL16  gfx_setfont
                LEA     XY0, s_palatino_14
                LOADI   D0, #75
                LOADI   D1, #350
                LOADI   D3, #C_BLACK
                CALL16  gfx_draw_string

                ; ---- moderndos_8x16_prop ----
                LEA     XY2, start
                LOADI   D0, #(moderndos_8x16_prop_bits - start)
                LEA     XY0, XY2+D0
                MOVE    D2, Y0
                MOVE    D3, X0
                LOADI   D0, #(font_moderndos_8x16_prop - start)
                LEA     XY0, XY2+D0
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALL16  gfx_setfont
                LEA     XY0, s_moderndos_8x16_prop
                LOADI   D0, #76
                LOADI   D1, #380
                LOADI   D3, #C_BLACK
                CALL16  gfx_draw_string

                ; ---- spleen_6x12 ----
                LEA     XY2, start
                LOADI   D0, #(spleen_6x12_bits - start)
                LEA     XY0, XY2+D0
                MOVE    D2, Y0
                MOVE    D3, X0
                LOADI   D0, #(font_spleen_6x12 - start)
                LEA     XY0, XY2+D0
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALL16  gfx_setfont
                LEA     XY0, s_spleen_6x12
                LOADI   D0, #76
                LOADI   D1, #410
                LOADI   D3, #C_BLACK
                CALL16  gfx_draw_string

                ; ---- spleen_8x16 ----
                LEA     XY2, start
                LOADI   D0, #(spleen_8x16_bits - start)
                LEA     XY0, XY2+D0
                MOVE    D2, Y0
                MOVE    D3, X0
                LOADI   D0, #(font_spleen_8x16 - start)
                LEA     XY0, XY2+D0
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALL16  gfx_setfont
                LEA     XY0, s_spleen_8x16
                LOADI   D0, #76
                LOADI   D1, #425
                LOADI   D3, #C_BLACK
                CALL16  gfx_draw_string

                LOADI   D0, #0                  ; clip OFF
                MOVE    Y0, D0
                MOVE    X0, D0
                CALL16  gfx_setclip

                ; chrome font back for Inspector + status
                LEA     XY0, helvetica_12_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_helvetica_12
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALL16  gfx_setfont

                ; ============================================================
                ; 4. Inspector window (front, smaller) -- overlaps A corner
                ;    panel (940,460,300,180)
                ; ============================================================
                LOADI   D0, #940
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #460
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #300
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #180
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_WHITE
                STOREP  D0, Y3, [#gr_idx]
                CALL16  gfx_fillrect
                LOADI   D0, #940
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #460
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #300
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #180
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_BLACK
                STOREP  D0, Y3, [#gr_idx]
                CALL16  gfx_rect
                LOADI   D0, #941
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #461
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #298
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #25
                STOREP  D0, Y3, [#gr_h]
                LEA     XY0, PAT_HLINES
                CALL16  gfx_fillpat
                LOADI   D0, #950
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #463
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #150
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #21
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_WHITE
                STOREP  D0, Y3, [#gr_idx]
                CALL16  gfx_fillrect
                LEA     XY0, b_title
                LOADI   D0, #956
                LOADI   D1, #466
                LOADI   D3, #C_BLACK
                CALL16  gfx_draw_string
                LOADI   D0, #944
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #486
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #292
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #2
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_BLACK
                STOREP  D0, Y3, [#gr_idx]
                CALL16  gfx_fillrect
                LEA     XY0, b_l0
                LOADI   D0, #956
                LOADI   D1, #500
                LOADI   D3, #C_BLACK
                CALL16  gfx_draw_string
                LEA     XY0, b_l1
                LOADI   D0, #956
                LOADI   D1, #520
                LOADI   D3, #C_BLACK
                CALL16  gfx_draw_string

                ; ============================================================
                ; 5. status bar (white, black text)
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
                CALL16  gfx_fillrect
                LEA     XY0, status
                LOADI   D0, #12
                LOADI   D1, #701
                LOADI   D3, #C_BLACK
                CALL16  gfx_draw_string

.hold:
                ; The on-screen status line already says "press a key";
                ; no console prompt (it would be invisible - see start:).
                TRAP    #TRAP_GETCHAR           ; block until any key
                LOADI   D0, #0
                TRAP    #TRAP_SETVIDMODE        ; release video -> text mode
                LOADI   D0, #0                  ; exit code 0
                TRAP    #TRAP_EXIT

.busy:
                ; gfx_open FAILED, so we never took VID_MODE and never
                ; joined the focus ring - still a plain task, kosh still
                ; FOREGROUND_TCB, nothing repaints on exit.  This text
                ; survives.  D0 = the ERR_* code; stash it across printing.
                PUSH    D0, XY3
                LEA     XY0, msg_busy
                TRAP    #TRAP_PUTS
                POP     D0, XY3
                TRAP    #TRAP_EXIT              ; kosh adds "[exit ERR_BUSY]"

.nomem:
                ; D0 = the ERR_* code from the failing kmalloc/region call.
                ; Released video is not needed - sys_exit runs
                ; _VideoForceReset for a task holding VID_MODE.
                TRAP    #TRAP_EXIT

; ----------------------------------------------------------------------------
; banner / prompt / msg_nomem removed.  Output from a task that has ALREADY
; joined the focus ring is repainted away by _ReapDeadTask when it exits, so
; the banner and the post-render prompt could never be read.  The .busy path
; is different: gfx_open failed there, so we are still a plain task and the
; message survives - hence msg_busy stays.  .nomem reports by code only.
msg_busy:
                ; ONE .TEXT, not two.  The first chunk here is 57 bytes
                ; (56 + the LF) - odd - and the assembler pads a data
                ; directive to a word boundary with $00 before emitting
                ; the next one.  That pad byte IS a nul terminator, so
                ; sys_puts would stop dead at the end of line one and
                ; the second line would silently never appear.  (Found
                ; via SHL4Test.asm, whose m_end lost six lines the same
                ; way: "10, \"expected:\", 10" is 11 bytes, padded to 12.)
                ; Keeping it in a single directive leaves no seam for a
                ; pad to land in.
                .TEXT   "Currently only one graphics based app can run at a time.", 10, "Use ps and kill to close tasks.", 10, 0
top_label:      .TEXT   "k/OS  KGFX        File   Edit   View   Window   Help", 0
status:         .TEXT   "GUI128_FONTS - 1280x720 1bpp - 18 converted faces in a document window - press a key", 0
a_title:        .TEXT   "Document  -  font sampler  (1bpp)", 0
b_title:        .TEXT   "Inspector", 0
b_l0:           .TEXT   "Font sampler", 0
b_l1:           .TEXT   "18 faces - 1bpp", 0
s_courier_9:           .TEXT   "Courier 9  The quick brown fox  WMil 0123 @#&", 0
s_courier_10:          .TEXT   "Courier 10  The quick brown fox  WMil 0123 @#&", 0
s_courier_12:          .TEXT   "Courier 12  The quick brown fox  WMil 0123 @#&", 0
s_helvetica_10:        .TEXT   "Helvetica 10  The quick brown fox  WMil 0123 @#&", 0
s_helvetica_12:        .TEXT   "Helvetica 12  The quick brown fox  WMil 0123 @#&", 0
s_helvetica_14:        .TEXT   "Helvetica 14  The quick brown fox  WMil 0123 @#&", 0
s_times_10:            .TEXT   "Times 10  The quick brown fox  WMil 0123 @#&", 0
s_times_12:            .TEXT   "Times 12  The quick brown fox  WMil 0123 @#&", 0
s_times_14:            .TEXT   "Times 14  The quick brown fox  WMil 0123 @#&", 0
s_new_century_10:      .TEXT   "New Century 10  The quick brown fox  WMil 0123 @#&", 0
s_new_century_12:      .TEXT   "New Century 12  The quick brown fox  WMil 0123 @#&", 0
s_new_century_14:      .TEXT   "New Century 14  The quick brown fox  WMil 0123 @#&", 0
s_palatino_10:         .TEXT   "Palatino 10  The quick brown fox  WMil 0123 @#&", 0
s_palatino_12:         .TEXT   "Palatino 12  The quick brown fox  WMil 0123 @#&", 0
s_palatino_14:         .TEXT   "Palatino 14  The quick brown fox  WMil 0123 @#&", 0
s_moderndos_8x16_prop: .TEXT   "ModernDOS prop  The quick brown fox  WMil 0123 @#&", 0
s_spleen_6x12:         .TEXT   "Spleen 6x12  The quick brown fox  WMil 0123 @#&", 0
s_spleen_8x16:         .TEXT   "Spleen 8x16  The quick brown fox  WMil 0123 @#&", 0

                .ALIGN
PAT_GRAY:       .BYTE   $AA, $55, $AA, $55, $AA, $55, $AA, $55   ; 50% stipple desktop
PAT_HLINES:     .BYTE   $FF, $00, $FF, $00, $FF, $00, $FF, $00   ; title-bar stripes

; ---- strikes BELOW the gfx scratch ($6000-$6250) ----
                .ALIGN
                .INCLUDE "../font/gfx_font_courier_9.inc"
                .ALIGN
                .INCLUDE "../font/gfx_font_courier_10.inc"
                .ALIGN
                .INCLUDE "../font/gfx_font_courier_12.inc"
                .ALIGN
                .INCLUDE "../font/gfx_font_helvetica_10.inc"
                .ALIGN
                .INCLUDE "../font/gfx_font_helvetica_12.inc"
                .ALIGN
                .INCLUDE "../font/gfx_font_helvetica_14.inc"
                .ALIGN
                .INCLUDE "../font/gfx_font_times_10.inc"
                .ALIGN
                .INCLUDE "../font/gfx_font_times_12.inc"
                .ALIGN
                .INCLUDE "../font/gfx_font_times_14.inc"

; ---- reserve the gfx render scratch so no font data lands on it ----
                .ORG    $6260
; ---- strikes ABOVE the scratch ----
                .ALIGN
                .INCLUDE "../font/gfx_font_new_century_10.inc"
                .ALIGN
                .INCLUDE "../font/gfx_font_new_century_12.inc"
                .ALIGN
                .INCLUDE "../font/gfx_font_new_century_14.inc"
                .ALIGN
                .INCLUDE "../font/gfx_font_palatino_10.inc"
                .ALIGN
                .INCLUDE "../font/gfx_font_palatino_12.inc"
                .ALIGN
                .INCLUDE "../font/gfx_font_palatino_14.inc"
                .ALIGN
                .INCLUDE "../font/gfx_font_moderndos_8x16_prop.inc"
                .ALIGN
                .INCLUDE "../font/gfx_font_spleen_6x12.inc"
                .ALIGN
                .INCLUDE "../font/gfx_font_spleen_8x16.inc"

                .ALIGN
                .INCLUDE "../gfx.asm"
                .INCLUDE "../gfx_1bpp.asm"
                .INCLUDE "../gfx_8bpp.asm"
                .INCLUDE "../gfx_regions.asm"
                .INCLUDE "../gfx_font.asm"
