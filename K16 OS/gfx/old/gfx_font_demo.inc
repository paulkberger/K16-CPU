; ============================================================================
; gfx_font_demo.inc  --  KGFX F1a hand-drawn demo font (6 glyphs).
; ----------------------------------------------------------------------------
; A descriptor-fronted 8x16 monospace font covering char codes 32..83, with
; real glyphs for  SPACE  K  1  6  O  S  (everything else blank). Glyph c sits
; at glyph_bits + (c-32)*16, one byte per row, MSB = leftmost pixel. The
; figures occupy a 5-wide stroke (cols 1..5) over rows 4..10, giving a 1px
; left / 2px right margin and a baseline near row 10 in the 8x16 cell.
;
; DATA ONLY -- include it in a harness body (after a halt/hold, before the
; code includes). FNT_BITS_PG/OF are $0000 placeholders; the harness patches
; them at runtime with `LEA glyph_bits` (avoids depending on .WORD address-
; operator syntax). At F2 this whole file is replaced by the full ASCII
; 32..127 pcface table -- same layout, drop-in.
; ============================================================================

font_demo:
                .WORD   32              ; FNT_FIRST   (space)
                .WORD   83              ; FNT_LAST    ('S')
                .WORD   8               ; FNT_WIDTH
                .WORD   16              ; FNT_HEIGHT
                .WORD   8               ; FNT_ADVANCE
                .WORD   11              ; FNT_ASCENT  (baseline; carried)
                .WORD   0               ; FNT_FLAGS
                .WORD   0               ; FNT_BITS_PG (patched at runtime)
                .WORD   0               ; FNT_BITS_OF (patched at runtime)
                .WORD   0               ; FNT_WTAB    (0 = monospace)
                .WORD   0               ; FNT_OTAB

glyph_bits:
                ; ---- 32  SPACE ----
                .DS     16
                ; ---- 33..48  unused ----
                .DS     256
                ; ---- 49  '1' ----
                .DS     4               ; rows 0..3 blank
                .BYTE   $10             ; ...X....
                .BYTE   $30             ; ..XX....
                .BYTE   $10             ; ...X....
                .BYTE   $10             ; ...X....
                .BYTE   $10             ; ...X....
                .BYTE   $10             ; ...X....
                .BYTE   $38             ; ..XXX...
                .DS     5               ; rows 11..15 blank
                ; ---- 50..53  unused ----
                .DS     64
                ; ---- 54  '6' ----
                .DS     4
                .BYTE   $38             ; ..XXX...
                .BYTE   $40             ; .X......
                .BYTE   $40             ; .X......
                .BYTE   $78             ; .XXXX...
                .BYTE   $44             ; .X...X..
                .BYTE   $44             ; .X...X..
                .BYTE   $38             ; ..XXX...
                .DS     5
                ; ---- 55..74  unused ----
                .DS     320
                ; ---- 75  'K' ----
                .DS     4
                .BYTE   $44             ; .X...X..
                .BYTE   $48             ; .X..X...
                .BYTE   $50             ; .X.X....
                .BYTE   $60             ; .XX.....
                .BYTE   $50             ; .X.X....
                .BYTE   $48             ; .X..X...
                .BYTE   $44             ; .X...X..
                .DS     5
                ; ---- 76..78  unused ----
                .DS     48
                ; ---- 79  'O' ----
                .DS     4
                .BYTE   $38             ; ..XXX...
                .BYTE   $44             ; .X...X..
                .BYTE   $44             ; .X...X..
                .BYTE   $44             ; .X...X..
                .BYTE   $44             ; .X...X..
                .BYTE   $44             ; .X...X..
                .BYTE   $38             ; ..XXX...
                .DS     5
                ; ---- 80..82  unused ----
                .DS     48
                ; ---- 83  'S' ----
                .DS     4
                .BYTE   $3C             ; ..XXXX..
                .BYTE   $40             ; .X......
                .BYTE   $40             ; .X......
                .BYTE   $38             ; ..XXX...
                .BYTE   $04             ; .....X..
                .BYTE   $04             ; .....X..
                .BYTE   $78             ; .XXXX...
                .DS     5
                ; glyph table size = 832 bytes ('S' at offset 816)
