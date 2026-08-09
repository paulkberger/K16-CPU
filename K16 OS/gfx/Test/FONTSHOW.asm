; ============================================================================
; FONTSHOW.asm  --  KGFX multi-font sampler (mode 1, 1280x720 1bpp).
; ----------------------------------------------------------------------------
; Proves multiple fonts + sizes coexisting in one harness: four <=8-wide
; strikes are included together (unique labels), each selected via gfx_setfont
; and drawn with the SAME sample line so they can be compared directly.
;   1. ModernDOS 8x16  (mono)
;   2. ModernDOS 8x16  (proportional)
;   3. Spleen   6x12   (mono)
;   4. Spleen   8x16   (mono)
; All on the fast byte-row vtext path. The 12x24 / 16x32 wide strikes need the
; >8px width path and are not shown here.
; Build: assemble as a .COM; gfx + regions + font include tail.
; ============================================================================
                .INCLUDE "../../kos_defs.inc"
                .INCLUDE "../gfx_defs.inc"
                .INCLUDE "../gfx_regions_defs.inc"
                .INCLUDE "../font/gfx_font_defs.inc"

C_BLACK         .EQU    0               ; ink
C_WHITE         .EQU    1               ; paper

                .ORG    $0200
start:
                LEA     XY0, banner
                TRAP    #TRAP_PUTLN

                LOADI   D0, #1                  ; mode 1 (1280x720 1bpp)
                CALLR   gfx_open
                BCS     .busy
                MOVE    Y1, Y3
                LOADI   X1, #GS_BASE            ; XY1 = descriptor (held throughout)

                ; --- white paper ---
                LOADI   D0, #C_WHITE
                CALLR   gfx_clear

                ; ====================================================
                ; 1. ModernDOS 8x16 mono  -> title + sample
                ; ====================================================
                LEA     XY0, moderndos_8x16_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_moderndos_8x16
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALLR   gfx_setfont

                LEA     XY0, title
                LOADI   D0, #40
                LOADI   D1, #24
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string

                LEA     XY0, s_md
                LOADI   D0, #40
                LOADI   D1, #80
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string

                ; ====================================================
                ; 2. ModernDOS 8x16 proportional
                ; ====================================================
                LEA     XY0, moderndos_8x16_prop_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_moderndos_8x16_prop
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALLR   gfx_setfont

                LEA     XY0, s_mdp
                LOADI   D0, #40
                LOADI   D1, #140
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string

                ; ====================================================
                ; 3. Spleen 6x12 mono
                ; ====================================================
                LEA     XY0, spleen_6x12_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_spleen_6x12
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALLR   gfx_setfont

                LEA     XY0, s_sp6
                LOADI   D0, #40
                LOADI   D1, #200
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string

                ; ====================================================
                ; 4. Spleen 8x16 mono
                ; ====================================================
                LEA     XY0, spleen_8x16_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_spleen_8x16
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALLR   gfx_setfont

                LEA     XY0, s_sp8
                LOADI   D0, #40
                LOADI   D1, #260
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string

                LEA     XY0, s_note
                LOADI   D0, #40
                LOADI   D1, #320
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string

                ; --- synthesized bold: ModernDOS 8x16 mono + FS_BOLD ---
                ;   re-select the font (resets style to normal), then set bold.
                LEA     XY0, moderndos_8x16_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_moderndos_8x16
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALLR   gfx_setfont
                LOADI   D0, #FS_BOLD
                CALLR   gfx_setfontstyle
                LEA     XY0, s_bold
                LOADI   D0, #40
                LOADI   D1, #380
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string

.hold:
                LEA     XY0, prompt
                TRAP    #TRAP_PUTLN
                TRAP    #TRAP_GETCHAR
                TRAP    #TRAP_EXIT
.busy:
                LEA     XY0, msg_busy
                TRAP    #TRAP_PUTLN
                TRAP    #TRAP_EXIT

; ----------------------------------------------------------------------------
banner          .TEXT   "KGFX FONTSHOW: 4 fonts, mode 1 1bpp", 0
prompt          .TEXT   "drawn - press a key to exit", 0
msg_busy        .TEXT   "gfx: graphics busy", 0

title           .TEXT   "KGFX font sampler - mode 1 1280x720 1bpp - same line, four strikes:", 0
s_md            .TEXT   "ModernDOS 8x16 mono   ABCDabcd 01234 the quick brown fox  !?#@&", 0
s_mdp           .TEXT   "ModernDOS 8x16 prop   ABCDabcd 01234 the quick brown fox  !?#@&", 0
s_sp6           .TEXT   "Spleen 6x12 mono      ABCDabcd 01234 the quick brown fox  !?#@&", 0
s_sp8           .TEXT   "Spleen 8x16 mono      ABCDabcd 01234 the quick brown fox  !?#@&", 0
s_note          .TEXT   "(Spleen 12x24 / 16x32 pending the >8px width path)", 0
s_bold          .TEXT   "ModernDOS 8x16 BOLD   ABCDabcd 01234 the quick brown fox  !?#@&  (synthesized)", 0

                .ALIGN
                .INCLUDE "../font/gfx_font_moderndos_8x16.inc"
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
                .INCLUDE "../font/gfx_font.asm"
