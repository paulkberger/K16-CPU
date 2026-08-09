; ============================================================================
; STEST.asm  --  gfx_scroll self-checking test + timing harness  (.COM)
; ----------------------------------------------------------------------------
; Verifies the gfx_scroll vertical block-move WITHOUT relying on the eye:
; it writes a unique marker into each row of a test rectangle straight into
; the framebuffer, scrolls, then reads the markers back and checks every row
; landed where it should. The rect is placed to STRADDLE the framebuffer's
; 64KB page boundary (mode-1 pitch 160 -> boundary at row 65536/160 = 409.6),
; which is the case that exercises the LEA mode-01 X->Y page carry in the
; row-advance. Width 152 px -> wb=19 bytes -> 9 words + 1 odd byte, so the
; inner copy runs all three phases (8-word block, remainder word, odd byte).
;
; Per row it stamps three checkpoints:
;   offset 0   first word  = MARK_BASE + r
;   offset 16  last  word  = (MARK_BASE + r) XOR $FFFF   (distinct, no alias)
;   offset 18  odd  byte   = r AND $FF
; After scrolling UP by N, row r must hold the data that was in row r+N for
; r < ROWS (= H-N); the bottom N rows are the vacated band and keep their own
; markers (gfx_scroll does not fill it).
;
; Then a timing pass: TICKS, TIMING_ITERS scrolls, TICKS -> elapsed 30 Hz
; ticks (EMU wall-clock; useful for before/after optimisation comparison, not
; a 10 MHz hardware figure).
;
; Output goes to the Terminal tab via TRAP_PUTLN. Requires gfx_scroll in
; gfx.asm, GSC_BSS in gfx_scroll_defs.inc, GSO_PITCH/GSO_BPP in gfx_defs.inc.
; Adjust the .INCLUDE paths to match the build tree.
; ============================================================================
                .INCLUDE "../../kos_defs.inc"
                .INCLUDE "../../klib/kos_klib.inc"
                .INCLUDE "../gfx_defs.inc"
                .INCLUDE "../gfx_scroll_defs.inc"
                .INCLUDE "../gfx_regions_defs.inc"
                .INCLUDE "../gfx_font_defs.inc"

; ---- test geometry ----
TEST_X          .EQU    0               ; byte-aligned (1bpp requirement)
TEST_W          .EQU    152             ; wb = 19 -> 9 words + 1 odd byte
TEST_Y0         .EQU    400             ; rows 400..429 straddle FB page bound
TEST_H          .EQU    30
TEST_N          .EQU    3               ; scroll up by 3 rows
TEST_ROWS       .EQU    TEST_H - TEST_N ; rows that receive moved data (27)
MARK_BASE       .EQU    $1000           ; row r first-word marker = $1000 + r
LAST_OFS        .EQU    16              ; last full word offset within rect
BYTE_OFS        .EQU    18              ; odd-byte offset within rect

TIMING_ITERS    .EQU    60000           ; ~0.6 s on EMU -> ~20 ticks @ 30 Hz

; ---- harness scratch (task page, below $0200 code; clear of gfx $0100-$015F)
t_t0            .EQU    $0164
t_loop          .EQU    $0166
t_cnt           .EQU    $0168           ; mismatch count
t_first         .EQU    $016A           ; first failing row (or $FFFF)
BUF             .EQU    $0170           ; line buffer (~48 bytes -> $019F)

                .ORG    $0200
start:
                LEA     XY0, banner
                TRAP    #TRAP_PUTLN

                LOADI   D0, #1
                CALLR   gfx_open
                BCS     .busy
                MOVE    Y1, Y3
                LOADI   X1, #GS_BASE            ; XY1 = descriptor (held)

                ; preset row-address helper inputs (gs_x, gs_fbpage)
                LOADI   D0, #TEST_X
                STOREP  D0, Y3, [#gs_x]
                LOADD   D0, [XY1+#0]            ; GS_FB_PAGE
                STOREP  D0, Y3, [#gs_fbpage]

; ---- Phase 1: correctness -------------------------------------------------
                CALLR   fill_markers
                ; scroll up by N
                LOADI   D0, #TEST_X
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #TEST_Y0
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #TEST_W
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #TEST_H
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #TEST_N
                NEG     D0                      ; dv = -N (up)
                CALLR   gfx_scroll
                CALLR   verify_up               ; -> t_cnt, t_first

                ; report PASS / FAIL
                LOADP   D0, Y3, [#t_cnt]
                CMP     D0, #0
                BNE     .failed
                LEA     XY0, msg_pass
                TRAP    #TRAP_PUTLN
                BRA     .timing
.failed:
                LEA     XY0, msg_fail           ; "...up FAIL mismatches="
                LOADP   D0, Y3, [#t_cnt]
                CALLR   report_num
                LEA     XY0, msg_firstrow       ; "  first bad row="
                LOADP   D0, Y3, [#t_first]
                CALLR   report_num

; ---- Phase 2: timing ------------------------------------------------------
.timing:
                CALL24  KLIB_TICKS              ; D0 = t0
                STOREP  D0, Y3, [#t_t0]
                ; rect already set from Phase 1; refresh to be safe
                LOADI   D0, #TEST_Y0
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #TEST_H
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #TIMING_ITERS
                STOREP  D0, Y3, [#t_loop]
.tloop:
                LOADI   D0, #TEST_N
                NEG     D0                      ; up
                CALLR   gfx_scroll
                LOADP   D0, Y3, [#t_loop]
                SUB     D0, #1
                STOREP  D0, Y3, [#t_loop]
                CMP     D0, #0
                BNE.L   .tloop
                CALL24  KLIB_TICKS              ; D0 = t1
                LOADP   D1, Y3, [#t_t0]
                SUB     D0, D1                  ; delta = t1 - t0 (mod 65536)
                LEA     XY0, msg_ticks          ; "60000 scrolls, ticks="
                CALLR   report_num

                LEA     XY0, msg_done
                TRAP    #TRAP_PUTLN
                TRAP    #TRAP_EXIT
.busy:
                LEA     XY0, msg_busy
                TRAP    #TRAP_PUTLN
                TRAP    #TRAP_EXIT

; ============================================================================
; trow -- FB byte address of (TEST_X, y).
;   In:  D0 = y.   Out: XY0 = 24-bit byte addr.
;   Clobbers D0-D2, X0, Y0; preserves D3, XY1, XY2. (gs_x/gs_fbpage preset.)
; ============================================================================
trow:
                STOREP  D0, Y3, [#gs_y]
                LOADP   D0, Y3, [#GS_ADDR]
                MOVE    X0, D0
                MOVE    Y0, Y3
                CALLXY  XY0                     ; -> XY0 = addr
                RET

; ============================================================================
; fill_markers -- stamp the three checkpoints into every row of the rect.
;   D3 = row index r (survives trow); markers derived from r.
; ============================================================================
fill_markers:
                LOADI   D3, #0
.fm_row:
                LOADI   D0, #TEST_Y0
                ADD     D0, D3
                CALLR   trow                    ; XY0 = row start (offset 0)
                ; first word = MARK_BASE + r
                LOADI   D0, #MARK_BASE
                ADD     D0, D3
                STORED  D0, [XY0]
                ; last word @+16 = marker XOR $FFFF
                MOVE    D1, D0
                XOR     D1, #$FFFF
                INC     XY0, #LAST_OFS
                STORED  D1, [XY0]
                ; odd byte @+18 = r AND $FF
                MOVE    D2, D3
                AND     D2, #$FF
                INC     XY0, #(BYTE_OFS - LAST_OFS)
                STOREB  D2, [XY0]
                INC     D3
                CMP     D3, #TEST_H
                BLO.L   .fm_row
                RET

; ============================================================================
; verify_up -- after an up-scroll by N, check each row's three checkpoints.
;   Expected source row for dst row r:  (r < ROWS) ? r+N : r.
;   Counts mismatches into t_cnt; records first failing row into t_first.
; ============================================================================
verify_up:
                LOADI   D0, #0
                STOREP  D0, Y3, [#t_cnt]
                LOADI   D0, #$FFFF
                STOREP  D0, Y3, [#t_first]
                LOADI   D3, #0
.vu_row:
                ; srcrow = (r < ROWS) ? r+N : r   -> stash in t_loop (reuse)
                MOVE    D0, D3
                CMP     D3, #TEST_ROWS
                BHS     .vu_band                ; r >= ROWS: untouched band
                ADD     D0, #TEST_N             ; r+N
.vu_band:
                STOREP  D0, Y3, [#t_loop]       ; srcrow (expected marker index)

                LOADI   D0, #TEST_Y0
                ADD     D0, D3
                CALLR   trow                    ; XY0 = row start
                ; check first word == MARK_BASE + srcrow
                LOADD   D0, [XY0]
                LOADP   D1, Y3, [#t_loop]
                ADD     D1, #MARK_BASE
                CMP     D0, D1
                BNE     .vu_bad
                ; check last word @+16 == (MARK_BASE+srcrow) XOR $FFFF
                INC     XY0, #LAST_OFS
                LOADD   D0, [XY0]
                LOADP   D1, Y3, [#t_loop]
                ADD     D1, #MARK_BASE
                XOR     D1, #$FFFF
                CMP     D0, D1
                BNE     .vu_bad
                ; check odd byte @+18 == srcrow AND $FF
                INC     XY0, #(BYTE_OFS - LAST_OFS)
                LOADB   D0, [XY0]
                LOADP   D1, Y3, [#t_loop]
                AND     D1, #$FF
                CMP     D0, D1
                BNE     .vu_bad
                BRA     .vu_next
.vu_bad:
                LOADP   D0, Y3, [#t_cnt]
                INC     D0
                STOREP  D0, Y3, [#t_cnt]
                ; record first failing row if not set
                LOADP   D0, Y3, [#t_first]
                CMP     D0, #$FFFF
                BNE     .vu_next
                STOREP  D3, Y3, [#t_first]
.vu_next:
                INC     D3
                CMP     D3, #TEST_H
                BLO.L   .vu_row
                RET

; ============================================================================
; report_num -- PUTLN a prefix string followed by an unsigned 16-bit value.
;   In: XY0 = prefix (nul-terminated), D0 = value.
; ============================================================================
report_num:
                ; -- copy prefix into BUF, then append the number --
                STOREP  D0, Y3, [#t_loop]       ; stash value in t_loop
                LOADI   X2, #BUF                ; XY2 = dest cursor (task-page abs)
                MOVE    Y2, Y3
.rn_cp:
                LOADB   D0, [XY0]+
                CMP     D0, #0
                BEQ     .rn_cpd
                STOREB  D0, [XY2]+
                BRA     .rn_cp
.rn_cpd:
                ; XY2 = end of prefix -> hand to UTOA32 as cursor in XY0
                MOVE    X0, X2
                MOVE    Y0, Y2
                LOADP   D0, Y3, [#t_loop]
                LOADI   D1, #0                  ; D1:D0 = value (hi = 0)
                CALL24  KLIB_UTOA32             ; appends digits + nul
                LOADI   X0, #BUF
                MOVE    Y0, Y3
                TRAP    #TRAP_PUTLN
                RET

; ----------------------------------------------------------------------------
banner          .TEXT   "STEST: gfx_scroll self-check + timing", 0
msg_busy        .TEXT   "gfx: graphics busy", 0
msg_pass        .TEXT   "gfx_scroll up: PASS (all rows correct, page boundary crossed)", 0
msg_fail        .TEXT   "gfx_scroll up: FAIL  mismatches=", 0
msg_firstrow    .TEXT   "  first bad row=", 0
msg_ticks       .TEXT   "timing: 60000 scrolls, elapsed ticks=", 0
msg_done        .TEXT   "STEST done.", 0

                .ALIGN
                .INCLUDE "../gfx.asm"
                .INCLUDE "../gfx_scroll.asm"
                .INCLUDE "../gfx_1bpp.asm"
                .INCLUDE "../gfx_8bpp.asm"
                .INCLUDE "../gfx_regions.asm"
                .INCLUDE "../gfx_font.asm"
