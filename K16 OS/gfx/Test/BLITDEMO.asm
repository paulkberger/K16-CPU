; ============================================================================
; BLITDEMO.asm  --  KGFX mode-1 (1280x720 1bpp) bitmap-blit smoke.
; ----------------------------------------------------------------------------
; Exercises gfx_blit1 / vblit_1 with a 16x16 arrow + 16x16 diamond (1bpp masks,
; MSB-first, stride 2). No font, to isolate the new code.
;   1. Arrow Or @ (100,80)  byte-aligned (x&7=4 here -> actually 100&7=4)
;   2. Arrow Or @ (205,80)  shifted (205&7=5) -> two-byte straddle per row
;   3. Diamond Copy @ (300,80) over a gray patch -> opaque: clear pixels get
;      bg=0 (black), so a 16x16 black box with a white diamond knocks out gray
;   4. Arrow Xor @ (450,80) over a white bar -> pixels flip white->black
;   5. Arrow Xor @ (560,80) TWICE over a white bar -> erased (XOR self-inverse)
;   6. Arrow Or @ (1268,80) -> right edge: last 4 cols clipped, no row spill
;   7. Arrow Or @ (700,-5)  -> top clip: first 5 source rows skipped
;
; Build: assemble as a .COM; gfx + regions tail. Needs gfx_font_defs.inc --
;   the depth files carry vtext_1, which references fn_mult.
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

                LOADI   D0, #1                  ; 1bpp mode 1
                CALLR   gfx_open
                BCS     .busy
                MOVE    Y1, Y3
                LOADI   X1, #GS_BASE
                LOADI   D0, #C_BLACK
                CALLR   gfx_clear

                ; common blit dims: 16x16, stride 2
                LOADI   D0, #16
                STOREP  D0, Y3, [#gb_w]
                LOADI   D0, #16
                STOREP  D0, Y3, [#gb_h]
                LOADI   D0, #2
                STOREP  D0, Y3, [#gb_stride]

                ; 1. arrow Or, aligned-ish
                LOADI   D0, #100
                STOREP  D0, Y3, [#gb_x]
                LOADI   D0, #80
                STOREP  D0, Y3, [#gb_y]
                LOADI   D0, #0                  ; Or
                STOREP  D0, Y3, [#gb_mode]
                LOADI   D0, #1                  ; fg=1
                STOREP  D0, Y3, [#gb_fg]
                LOADI   D0, #0
                STOREP  D0, Y3, [#gb_bg]
                LEA     XY0, arrow
                CALLR   gfx_blit1

                ; 2. arrow Or, shifted x=205
                LOADI   D0, #205
                STOREP  D0, Y3, [#gb_x]
                LEA     XY0, arrow
                CALLR   gfx_blit1

                ; 3. diamond Copy over a gray patch (opaque box)
                LOADI   D0, #296
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #76
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #24
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #24
                STOREP  D0, Y3, [#gr_h]
                LEA     XY0, PAT_GRAY
                CALLR   gfx_fillpat
                LOADI   D0, #300
                STOREP  D0, Y3, [#gb_x]
                LOADI   D0, #80
                STOREP  D0, Y3, [#gb_y]
                LOADI   D0, #1                  ; Copy
                STOREP  D0, Y3, [#gb_mode]
                LOADI   D0, #1                  ; fg=1 (diamond white)
                STOREP  D0, Y3, [#gb_fg]
                LOADI   D0, #0                  ; bg=0 (box black)
                STOREP  D0, Y3, [#gb_bg]
                LEA     XY0, diamond
                CALLR   gfx_blit1

                ; 4. arrow Xor over a white bar
                LOADI   D0, #446
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #76
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #24
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #24
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_WHITE
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_fillrect
                LOADI   D0, #450
                STOREP  D0, Y3, [#gb_x]
                LOADI   D0, #80
                STOREP  D0, Y3, [#gb_y]
                LOADI   D0, #2                  ; Xor
                STOREP  D0, Y3, [#gb_mode]
                LOADI   D0, #1
                STOREP  D0, Y3, [#gb_fg]
                LEA     XY0, arrow
                CALLR   gfx_blit1

                ; 5. arrow Xor TWICE over a white bar -> erased
                LOADI   D0, #556
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #76
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #24
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #24
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_WHITE
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_fillrect
                LOADI   D0, #560
                STOREP  D0, Y3, [#gb_x]
                LOADI   D0, #80
                STOREP  D0, Y3, [#gb_y]
                LOADI   D0, #2                  ; Xor
                STOREP  D0, Y3, [#gb_mode]
                LEA     XY0, arrow
                CALLR   gfx_blit1
                LEA     XY0, arrow              ; again -> XOR self-inverse erases
                CALLR   gfx_blit1

                ; 6. arrow Or at the right edge (clip last cols)
                LOADI   D0, #1268
                STOREP  D0, Y3, [#gb_x]
                LOADI   D0, #80
                STOREP  D0, Y3, [#gb_y]
                LOADI   D0, #0                  ; Or
                STOREP  D0, Y3, [#gb_mode]
                LOADI   D0, #1
                STOREP  D0, Y3, [#gb_fg]
                LEA     XY0, arrow
                CALLR   gfx_blit1

                ; 7. arrow Or with y=-5 (top clip: first 5 source rows skipped)
                LOADI   D0, #700
                STOREP  D0, Y3, [#gb_x]
                LOADI   D0, #$FFFB              ; -5
                STOREP  D0, Y3, [#gb_y]
                LEA     XY0, arrow
                CALLR   gfx_blit1

                LEA     XY0, prompt
                TRAP    #TRAP_PUTLN
                TRAP    #TRAP_GETCHAR
                TRAP    #TRAP_EXIT

.busy:
                LEA     XY0, msg_busy
                TRAP    #TRAP_PUTLN
                TRAP    #TRAP_EXIT

; ----------------------------------------------------------------------------
banner          .TEXT   "BLITDEMO: mode 1 1bpp bitmap blit (vblit_1)", 0
prompt          .TEXT   "drawn - press a key to exit", 0
msg_busy        .TEXT   "gfx: graphics busy", 0

                .ALIGN
PAT_GRAY        .BYTE   $AA, $55, $AA, $55, $AA, $55, $AA, $55

                .ALIGN
arrow:                                          ; 16x16, MSB-first, stride 2
                .BYTE   $80, $00
                .BYTE   $C0, $00
                .BYTE   $E0, $00
                .BYTE   $F0, $00
                .BYTE   $F8, $00
                .BYTE   $FC, $00
                .BYTE   $FE, $00
                .BYTE   $FF, $00
                .BYTE   $FF, $80
                .BYTE   $F8, $00
                .BYTE   $D8, $00
                .BYTE   $8C, $00
                .BYTE   $0C, $00
                .BYTE   $06, $00
                .BYTE   $06, $00
                .BYTE   $00, $00

                .ALIGN
diamond:                                        ; 16x16, MSB-first, stride 2
                .BYTE   $01, $80
                .BYTE   $03, $C0
                .BYTE   $07, $E0
                .BYTE   $0F, $F0
                .BYTE   $1F, $F8
                .BYTE   $3F, $FC
                .BYTE   $7F, $FE
                .BYTE   $FF, $FF
                .BYTE   $FF, $FF
                .BYTE   $7F, $FE
                .BYTE   $3F, $FC
                .BYTE   $1F, $F8
                .BYTE   $0F, $F0
                .BYTE   $07, $E0
                .BYTE   $03, $C0
                .BYTE   $01, $80

                .ALIGN
                .INCLUDE "../gfx.asm"
                .INCLUDE "../gfx_1bpp.asm"
                .INCLUDE "../gfx_8bpp.asm"
                .INCLUDE "../gfx_regions.asm"
