; ============================================================================
; FNTSHOW_T14.asm  --  isolate the Times 14 scramble, mode 1 1bpp.
; ----------------------------------------------------------------------------
; Times 14 renders with the right glyphs but wrong spacing in the full
; showcase, while its data is verified clean. This minimal harness draws ONLY
; Times 14 and Helvetica 14 (same 13px cell width, known-good control) in a
; small binary with simple in-range addressing (LEA / CALLR, like FNTSHOW2).
;
;   * If Times 14 scrambles here too -> font/renderer bug, clean repro.
;   * If Times 14 is clean here       -> the showcase's far-addressing is at
;                                         fault for that font, not the data.
;
; Each face draws the same sample twice (s=0 and s=3 start) plus a width probe
; (iiiii vs WWWWW). Build: assemble as a .COM; gfx + regions + font tail.
; ============================================================================
                .INCLUDE "../../kos_defs.inc"
                .INCLUDE "../gfx_defs.inc"
                .INCLUDE "../gfx_regions_defs.inc"
                .INCLUDE "../gfx_font_defs.inc"

C_BLACK         .EQU    0
C_WHITE         .EQU    1

                .ORG    $0200
start:
                LEA     XY0, banner
                TRAP    #TRAP_PUTLN

                LOADI   D0, #1
                CALLR   gfx_open
                BCS     .busy
                MOVE    Y1, Y3
                LOADI   X1, #GS_BASE
                LOADI   D0, #C_WHITE
                CALLR   gfx_clear

                ; ---- Helvetica 14 (control, 13px wide) ----
                LEA     XY0, helvetica_14_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_helvetica_14
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALLR   gfx_setfont

                LEA     XY0, s_ctl
                LOADI   D0, #40
                LOADI   D1, #30
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string

                LEA     XY0, s_probe
                LOADI   D0, #40
                LOADI   D1, #54
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string

                ; ---- Times 14 (suspect) ----
                LEA     XY0, times_14_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_times_14
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALLR   gfx_setfont

                LEA     XY0, s_t14
                LOADI   D0, #40
                LOADI   D1, #100
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string

                ; same string, start x=43 (s=3) -> exercise wide placement
                LEA     XY0, s_t14
                LOADI   D0, #43
                LOADI   D1, #128
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string

                LEA     XY0, s_probe
                LOADI   D0, #40
                LOADI   D1, #156
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string

.hold:
                LEA     XY0, prompt
                TRAP    #TRAP_PUTLN
                TRAP    #TRAP_GETCHAR
                LOADI   D0, #0
                TRAP    #TRAP_SETVIDMODE
                TRAP    #TRAP_EXIT
.busy:
                LEA     XY0, msg_busy
                TRAP    #TRAP_PUTLN
                TRAP    #TRAP_EXIT

; ----------------------------------------------------------------------------
banner          .TEXT   "FNTSHOW_T14: isolate Times 14 vs Helvetica 14", 0
prompt          .TEXT   "drawn - press a key to exit", 0
msg_busy        .TEXT   "gfx: graphics busy", 0

s_ctl           .TEXT   "Helvetica 14 control: The quick brown fox WMil 0123 @#&", 0
s_t14           .TEXT   "Times 14 suspect: The quick brown fox WMil 0123 @#&", 0
s_probe         .TEXT   "width probe: iiiii vs WWWWW  lll MMM  0123456789", 0

                .ALIGN
                .INCLUDE "../font/gfx_font_helvetica_14.inc"
                .ALIGN
                .INCLUDE "../font/gfx_font_times_14.inc"

                .ALIGN
                .INCLUDE "../gfx.asm"
                .INCLUDE "../gfx_1bpp.asm"
                .INCLUDE "../gfx_8bpp.asm"
                .INCLUDE "../gfx_regions.asm"
                .INCLUDE "../gfx_font.asm"
