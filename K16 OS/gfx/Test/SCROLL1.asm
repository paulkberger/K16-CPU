; ============================================================================
; SCROLL1.asm  --  KGFX terminal-scroll "feel" demo (mode 1, 1bpp, Spleen 6x12)
; ----------------------------------------------------------------------------
; Goal: feel how a terminal scrolls at the 10 MHz hardware target. A bounded
; window (80x25 chars = 480x300 px) is pre-filled with a fake build log and
; scrolled upward by a single parameterised wrap-scroll routine:
;
;   LINE  mode -- jump up one text row (12 px) per frame   (classic terminal)
;   PIXEL mode -- creep up 1 px per frame                  (smooth marquee)
;
; The hot loop is a windowed vertical memmove built on the STREAM post-
; increment word-blast (LOADD/STORED [XYn]+, opcode $02). Content is CIRCULAR:
; the n rows that scroll off the top are saved to a RAM strip and restored at
; the bottom, so no per-frame font render contaminates the blit benchmark.
;
; THE 10 MHz NUMBER (static cycle accounting -- NOT wall-clock):
;   The emulator runs ~330 MHz, so on-screen motion is ~33x faster than the
;   10 MHz target and cannot be "felt" directly. Instead the per-frame cost is
;   COUNTED from the verified v3.17 ISA cycle table (Sec 15.2 / 6.1) and shown
;   on the status line. Derivation (per scroll_wrap call, typical path):
;
;     copy_row  = 30 * (LOADD [XY]+ 4  +  STORED [XY]+ 5)  = 270  (unrolled)
;     main row  = copy_row 270 + CALLR 12 + RET 6 + src adv 7 + dst adv 7
;                 + DEC 4 + BNE.L 4                                = 310
;     save row  = 270 +12+6 + src adv 7        + DEC 4 + BNE.L 4   = 303
;     restore   = 270 +12+6        + dst adv 7 + DEC 4 + BNE.L 4   = 303
;       (adv = ADD Xn,#100 [4] + BCC.S [3]; rare page-cross +3 ignored;
;        STREAM word is +2 on the ~1 page boundary the window straddles.)
;     setup/frame ~ 25.
;     LINE  (n=12): main 288*310 + save 12*303 + restore 12*303 + 25 = 96577
;     PIXEL (n= 1): main 299*310 + save  1*303 + restore  1*303 + 25 = 93321
;
;   @ 10 MHz (100 ns/cycle):
;     LINE  ~9.66 ms/frame  ->  ~103 full-window line-scrolls / sec
;     PIXEL ~9.33 ms/frame  ->  ~107 fps (1 px) = ~9 text lines / sec
;   Same blit bandwidth; PIXEL needs 12x the frames for equal text advance.
;
; INPUT: k/OS exposes only a BLOCKING sys_getchar (#11) -- no key-poll syscall
;   -- so the demo runs a fixed BURST of frames per mode (watch it run free at
;   emu speed) then blocks for a key BETWEEN bursts:
;     SPACE = toggle LINE/PIXEL,  Q = quit,  any other = re-run same mode.
;
; Build: drop alongside GUISPL6.asm; assemble as a .COM. Same include tail.
; ============================================================================
                .INCLUDE "../../kos_defs.inc"
                .INCLUDE "../gfx_defs.inc"
                .INCLUDE "../gfx_regions_defs.inc"
                .INCLUDE "../gfx_font_defs.inc"

; ---- 1bpp palette --------------------------------------------------------
C_BLACK         .EQU    0
C_WHITE         .EQU    1

; ---- window geometry (byte-aligned: WIN_X / WIN_W multiples of 8) --------
WIN_X           .EQU    80              ; left px  (byte col 10)
WIN_Y           .EQU    120             ; top px
WIN_W           .EQU    480             ; 80 cols * 6
WIN_H           .EQU    300             ; 25 rows * 12
LINE_H          .EQU    12              ; Spleen 6x12 cell height
WIN_BYTECOL     .EQU    WIN_X / 8       ; 10
WIN_WBYTES      .EQU    WIN_W / 8       ; 60 bytes / row
PITCH           .EQU    160             ; mode-1 bytes / row
ROWGAP          .EQU    PITCH - WIN_WBYTES   ; 100 bytes to next row start
WIN_OFFS        .EQU    WIN_Y * PITCH + WIN_BYTECOL   ; FB byte offset of top-left

; ---- keys ----------------------------------------------------------------
KEY_SPACE       .EQU    $20
KEY_Q           .EQU    $71            ; 'q'
KEY_QU          .EQU    $51            ; 'Q'

; ---- burst length (frames per mode before the key prompt) ----------------
; Tune for visible sustained motion on the emulator; the 10 MHz numbers on the
; status line are independent of this.
FRAMES_LINE     .EQU    2000
FRAMES_PIXEL    .EQU    6000

; ---- task-page harness scratch ($0164-$01FF free per gfx_regions_defs) ----
sc_n            .EQU    $0164          ; scroll step px (12 or 1)
sc_rows         .EQU    $0166          ; main memmove row count (WIN_H - n)
sc_fbpg         .EQU    $0168          ; FB page (from descriptor)
sc_frames       .EQU    $016A          ; frames remaining in burst
sc_mode         .EQU    $016C          ; 0 = LINE, 1 = PIXEL

; ---- circular-wrap RAM strip (n rows * 60 bytes; n<=12 -> 720 bytes) ------
; Above FNT_BSS top ($624C); clear of gfx BSS, below the task stack.
SCR_STRIP       .EQU    $6300

                .ORG    $0200
start:
                LEA     XY0, banner
                TRAP    #TRAP_PUTLN

                LOADI   D0, #1                  ; mode 1 (1280x720 1bpp)
                CALLR   gfx_open
                BCS     .busy
                MOVE    Y1, Y3
                LOADI   X1, #GS_BASE            ; XY1 = descriptor (held)
                LOADD   D0, [XY1+#0]            ; GS_FB_PAGE
                STOREP  D0, Y3, [#sc_fbpg]

                LOADI   D0, #C_BLACK            ; black desktop
                CALLR   gfx_clear

                ; Spleen 6x12 current font
                LEA     XY0, spleen_6x12_bits
                MOVE    D2, Y0
                MOVE    D3, X0
                LEA     XY0, font_spleen_6x12
                STORED  D2, [XY0+#FNT_BITS_PG]
                STORED  D3, [XY0+#FNT_BITS_OF]
                CALLR   gfx_setfont

                CALLR   draw_chrome             ; frame, title, prompt
                CALLR   fill_window             ; pre-fill 25 log lines

                LOADI   D0, #0                  ; default mode = LINE
                STOREP  D0, Y3, [#sc_mode]

; ============================================================================
; main burst loop
; ============================================================================
.loop:
                CALLR   set_mode_params         ; sc_n / sc_rows
                CALLR   draw_overlay            ; status line for active mode

                LOADP   D0, Y3, [#sc_mode]
                CMP     D0, #0
                BNE     .pixburst
                LOADI   D0, #FRAMES_LINE
                BRA     .runburst
.pixburst:
                LOADI   D0, #FRAMES_PIXEL
.runburst:
                STOREP  D0, Y3, [#sc_frames]
.frame:
                CALLR   scroll_wrap             ; <-- the counted hot loop
                LOADP   D0, Y3, [#sc_frames]
                SUB     D0, #1
                STOREP  D0, Y3, [#sc_frames]
                CMP     D0, #0
                BNE.L   .frame

                TRAP    #TRAP_GETCHAR           ; D0 = key (blocks)
                CMP     D0, #KEY_Q
                BEQ     .quit
                CMP     D0, #KEY_QU
                BEQ     .quit
                CMP     D0, #KEY_SPACE
                BNE.L   .loop                   ; other key: re-run same mode
                LOADP   D0, Y3, [#sc_mode]      ; SPACE: toggle
                XOR     D0, #1
                STOREP  D0, Y3, [#sc_mode]
                BRA.L   .loop

.quit:
                TRAP    #TRAP_EXIT
.busy:
                LEA     XY0, msg_busy
                TRAP    #TRAP_PUTLN
                TRAP    #TRAP_EXIT

; ============================================================================
; set_mode_params -- sc_n / sc_rows from sc_mode.  Clobbers D0.
; ============================================================================
set_mode_params:
                LOADP   D0, Y3, [#sc_mode]
                CMP     D0, #0
                BNE     .smp_pix
                LOADI   D0, #LINE_H
                STOREP  D0, Y3, [#sc_n]
                LOADI   D0, #(WIN_H - LINE_H)   ; 288
                STOREP  D0, Y3, [#sc_rows]
                RET
.smp_pix:
                LOADI   D0, #1
                STOREP  D0, Y3, [#sc_n]
                LOADI   D0, #(WIN_H - 1)        ; 299
                STOREP  D0, Y3, [#sc_rows]
                RET

; ============================================================================
; scroll_wrap -- circular vertical scroll up by sc_n px. Pointer-flow keeps
;   every address 24-bit-correct via each loop's own carry handling (the
;   window straddles the 64 KB FB-page boundary, so offsets must carry):
;     (1) save top n rows: FB top -> SCR_STRIP. XY2 ends at FB row n.
;     (2) main: src = XY2 (carried), dst = FB top. XY0 ends at FB row (H-n).
;     (3) restore: src = SCR_STRIP, dst = XY0 (carried) = bottom n rows.
;   Uses XY0(dst), XY2(src), D0(copy), D1(rows); preserves XY1, XY3.
; ============================================================================
scroll_wrap:
                ; ---- (1) save top n rows -> SCR_STRIP (packed) -------------
                LOADP   D0, Y3, [#sc_fbpg]
                MOVE    Y2, D0
                LOADI   X2, #WIN_OFFS           ; src = FB:window-top
                MOVE    Y0, Y3
                LOADI   X0, #SCR_STRIP          ; dst = task-page strip
                LOADP   D1, Y3, [#sc_n]
.sw_save:
                CALLR   copy_row                ; XY0,XY2 += 60
                ADD     X2, #ROWGAP             ; next FB row (strip dst: packed)
                BCC.S   .sw_s1
                ADD     Y2, #1
.sw_s1:
                SUB     D1, #1
                BNE.L   .sw_save                ; XY2 now = FB row n (= main src)

                ; ---- (2) main memmove up by n: dst = FB top, src = XY2 -----
                LOADP   D0, Y3, [#sc_fbpg]
                MOVE    Y0, D0
                LOADI   X0, #WIN_OFFS           ; dst = row 0
                LOADP   D1, Y3, [#sc_rows]
.sw_main:
                CALLR   copy_row
                ADD     X2, #ROWGAP
                BCC.S   .sw_m1
                ADD     Y2, #1
.sw_m1:
                ADD     X0, #ROWGAP
                BCC.S   .sw_m2
                ADD     Y0, #1
.sw_m2:
                SUB     D1, #1
                BNE.L   .sw_main                ; XY0 now = FB row (H-n)

                ; ---- (3) restore SCR_STRIP -> bottom n rows (dst = XY0) ----
                MOVE    Y2, Y3
                LOADI   X2, #SCR_STRIP          ; src = strip
                LOADP   D1, Y3, [#sc_n]
.sw_rest:
                CALLR   copy_row
                ADD     X0, #ROWGAP             ; next FB row (strip src: packed)
                BCC.S   .sw_r1
                ADD     Y0, #1
.sw_r1:
                SUB     D1, #1
                BNE.L   .sw_rest
                RET

; ============================================================================
; copy_row -- copy 30 words from [XY2]+ to [XY0]+ (word-blast, fully unrolled).
;   On exit XY0,XY2 each advanced by 60.  Clobbers D0.  STREAM = flag-transparent.
; ============================================================================
copy_row:
                LOADD   D0, [XY2]+
                STORED  D0, [XY0]+
                LOADD   D0, [XY2]+
                STORED  D0, [XY0]+
                LOADD   D0, [XY2]+
                STORED  D0, [XY0]+
                LOADD   D0, [XY2]+
                STORED  D0, [XY0]+
                LOADD   D0, [XY2]+
                STORED  D0, [XY0]+
                LOADD   D0, [XY2]+
                STORED  D0, [XY0]+
                LOADD   D0, [XY2]+
                STORED  D0, [XY0]+
                LOADD   D0, [XY2]+
                STORED  D0, [XY0]+
                LOADD   D0, [XY2]+
                STORED  D0, [XY0]+
                LOADD   D0, [XY2]+
                STORED  D0, [XY0]+
                LOADD   D0, [XY2]+
                STORED  D0, [XY0]+
                LOADD   D0, [XY2]+
                STORED  D0, [XY0]+
                LOADD   D0, [XY2]+
                STORED  D0, [XY0]+
                LOADD   D0, [XY2]+
                STORED  D0, [XY0]+
                LOADD   D0, [XY2]+
                STORED  D0, [XY0]+
                LOADD   D0, [XY2]+
                STORED  D0, [XY0]+
                LOADD   D0, [XY2]+
                STORED  D0, [XY0]+
                LOADD   D0, [XY2]+
                STORED  D0, [XY0]+
                LOADD   D0, [XY2]+
                STORED  D0, [XY0]+
                LOADD   D0, [XY2]+
                STORED  D0, [XY0]+
                LOADD   D0, [XY2]+
                STORED  D0, [XY0]+
                LOADD   D0, [XY2]+
                STORED  D0, [XY0]+
                LOADD   D0, [XY2]+
                STORED  D0, [XY0]+
                LOADD   D0, [XY2]+
                STORED  D0, [XY0]+
                LOADD   D0, [XY2]+
                STORED  D0, [XY0]+
                LOADD   D0, [XY2]+
                STORED  D0, [XY0]+
                LOADD   D0, [XY2]+
                STORED  D0, [XY0]+
                LOADD   D0, [XY2]+
                STORED  D0, [XY0]+
                LOADD   D0, [XY2]+
                STORED  D0, [XY0]+
                LOADD   D0, [XY2]+
                STORED  D0, [XY0]+
                RET

; ============================================================================
; draw_chrome -- window panel + frame + title + key prompt (drawn once).
; ============================================================================
draw_chrome:
                LOADI   D0, #(WIN_X - 2)
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #(WIN_Y - 20)
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #(WIN_W + 4)
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #(WIN_H + 22)
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_WHITE
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_fillrect
                LOADI   D0, #(WIN_X - 2)
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #(WIN_Y - 20)
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #(WIN_W + 4)
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #(WIN_H + 22)
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_BLACK
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_rect
                LEA     XY0, win_title
                LOADI   D0, #WIN_X
                LOADI   D1, #(WIN_Y - 16)
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string
                LEA     XY0, prompt
                LOADI   D0, #WIN_X
                LOADI   D1, #(WIN_Y + WIN_H + 26)
                LOADI   D3, #C_WHITE
                CALLR   gfx_draw_string
                RET

; ============================================================================
; draw_overlay -- erase status strip, draw the baked metrics for active mode.
; ============================================================================
draw_overlay:
                LOADI   D0, #WIN_X
                STOREP  D0, Y3, [#gr_x]
                LOADI   D0, #(WIN_Y + WIN_H + 6)
                STOREP  D0, Y3, [#gr_y]
                LOADI   D0, #WIN_W
                STOREP  D0, Y3, [#gr_w]
                LOADI   D0, #LINE_H
                STOREP  D0, Y3, [#gr_h]
                LOADI   D0, #C_WHITE
                STOREP  D0, Y3, [#gr_idx]
                CALLR   gfx_fillrect
                LOADP   D0, Y3, [#sc_mode]
                CMP     D0, #0
                BNE     .ov_pix
                LEA     XY0, lbl_line
                BRA     .ov_draw
.ov_pix:
                LEA     XY0, lbl_pixel
.ov_draw:
                LOADI   D0, #WIN_X
                LOADI   D1, #(WIN_Y + WIN_H + 6)
                LOADI   D3, #C_BLACK
                CALLR   gfx_draw_string
                RET

; ============================================================================
; fill_window -- pre-fill the 25 visible rows from the log table (wraps).
;   XY2 = table cursor (persisted across draws via stack save).
; ============================================================================
fill_window:
                LEA     XY0, log0
                MOVE    Y2, Y0
                MOVE    X2, X0
                LOADI   D2, #25                 ; rows
                LOADI   D1, #WIN_Y              ; y cursor
.fw_row:
                MOVE    Y0, Y2
                MOVE    X0, X2                  ; XY0 = current line
                LOADI   D0, #WIN_X
                LOADI   D3, #C_BLACK
                PUSH    XY2, XY3
                PUSH    D1, XY3
                PUSH    D2, XY3
                CALLR   gfx_draw_string
                POP     D2, XY3
                POP     D1, XY3
                POP     XY2, XY3
                CALLR   strskip                 ; XY2 -> next line (wraps)
                ADD     D1, #LINE_H
                SUB     D2, #1
                BNE.L   .fw_row
                RET

; strskip -- advance XY2 past the next nul; rewind to log0 at log_end.
;   Clobbers D0, XY0.  Preserves D1,D2,XY1,XY3 and (on no-wrap) Y2.
strskip:
                LOADB   D0, [XY2]+              ; STREAM load is flag-transparent
                CMP     D0, #0
                BNE.L   strskip
                ; .TEXT word-packs 2 chars/word and pads even-length strings
                ; with a 2nd nul; round the cursor up to the next word boundary
                ; so it lands on the next string, not a stray pad byte.
                MOVE    D0, X2
                AND     D0, #1
                BEQ.S   .ss_chk
                ADD     X2, #1
.ss_chk:
                LEA     XY0, log_end
                MOVE    D0, X0
                CMP     X2, D0                  ; X2 >= log_end offset -> rewind
                BLO     .ss_done
                LEA     XY0, log0
                MOVE    Y2, Y0
                MOVE    X2, X0
.ss_done:
                RET

; ----------------------------------------------------------------------------
banner          .TEXT   "SCROLL1: terminal-scroll feel @ 10 MHz - Spleen 6x12", 0
msg_busy        .TEXT   "gfx: graphics busy", 0
win_title       .TEXT   "k/OS terminal  -  80x25  -  Spleen 6x12 mono", 0
prompt          .TEXT   "SPACE = LINE/PIXEL toggle    Q = quit    other = re-run", 0
lbl_line        .TEXT   "LINE  12px/frame   96577 cyc   9.7 ms   103 scrolls/s @10MHz", 0
lbl_pixel       .TEXT   "PIXEL  1px/frame   93321 cyc   9.3 ms   107 fps (9 lines/s) @10MHz", 0

; ---- fake build log (cycled by fill_window) -------------------------------
log0            .TEXT   "k/OS 0.22  cold boot  -  discrete TTL @ 10 MHz", 0
                .TEXT   "[  0.000] kernel: vector table @ 00:0000..01FC", 0
                .TEXT   "[  0.001] heap: first-fit + bidir coalesce online", 0
                .TEXT   "[  0.002] timer: 30 Hz tick, SYS_TICKS 32-bit", 0
                .TEXT   "[  0.004] kbd: ring drained, type-ahead armed", 0
                .TEXT   "[  0.006] video: mode 1  1280x720 1bpp  pitch 160", 0
                .TEXT   "[  0.009] fat16: mount B:  label=KOS  ok", 0
                .TEXT   "[  0.013] klib: 25/64 slots live", 0
                .TEXT   "[  0.014] spawn: kosh  tid=1  page=02", 0
                .TEXT   "kosh$ run scroll1", 0
                .TEXT   "  loading SCROLL1.COM ... ok", 0
                .TEXT   "  gfx_open mode 1 ... surface 1280x720x1", 0
                .TEXT   "  setfont spleen_6x12 ... mono 6px cell", 0
                .TEXT   "  prefill window 80x25 ... ok", 0
                .TEXT   "the quick brown fox jumps over the lazy dog 01234", 0
                .TEXT   "STREAM blast: LOADD/STORED [XYn]+  4/5 cyc", 0
                .TEXT   "window memmove: 30 words/row x 288 rows", 0
                .TEXT   "static accounting -> cycles/frame -> 10 MHz", 0
                .TEXT   "no wall-clock: emulator runs ~330 MHz", 0
                .TEXT   "carry is 6502-style: BCS = no borrow", 0
                .TEXT   ".S branches forward 0..31 bytes only", 0
                .TEXT   "page-cross adds +2 cyc on a STREAM word", 0
                .TEXT   "94 TTL chips, 24-bit address, ROM ALU", 0
                .TEXT   "iiii MMMM align check  !?#&@  ()[]{}<>/", 0
                .TEXT   "----------------------------------------------", 0
log_end         .TEXT   "", 0

                .ALIGN
                .INCLUDE "../font/gfx_font_spleen_6x12.inc"

                .ALIGN
                .INCLUDE "../gfx.asm"
                .INCLUDE "../gfx_1bpp.asm"
                .INCLUDE "../gfx_8bpp.asm"
                .INCLUDE "../gfx_regions.asm"
                .INCLUDE "../gfx_font.asm"
