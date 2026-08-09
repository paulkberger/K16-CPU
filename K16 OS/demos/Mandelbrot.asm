; Mandelbrot.asm — K16 Mandelbrot Set renderer (k/OS .COM port of Gfx_Mandebrot.asm)
; Fixed-point 2.12. 640x480 8bpp. x:-2.5..+1.0, y:-1.25..+1.25. 32 iters.
; Frame (18 bytes at XY2): +0 x, +2 y, +4 xx, +6 yy, +8 cx, +10 cy,
;                          +12 cx_start, +14 row, +16 iter
;
; 8 August 2026 -- three fixes:
;   1. VID_PAGE ($DC0000) is now programmed to FB_PAGE after acquiring the
;      mode.  It never was - the old `VID_PAGE .EQU $DD` named VID_MODE's
;      page, not VID_PAGE's, and nothing in the file ever stored to
;      $DC0000.  The kernel does not set it either (_InitVideo only zeroes
;      VID_MODE), so the display showed whatever page was left over -
;      0 from reset, or $B4 from a previous cube run.  We rendered into
;      $B0_0000 and the hardware was pointed somewhere else.
;   2. sq12's three SHL4/SHL4 byte-packs replaced with SWAPB.  RM Appendix
;      B.11: the two-shift idiom silently corrupts any byte > $0F, so the
;      squares were wrong for |value| >= $1000 (>= 1.0 in 2.12) - most of
;      the interesting part of the plane.
;   3. The terminal `BRA .forever` spin is now a blocking TRAP_GETCHAR
;      followed by a clean video release + exit.  The spin burned a core
;      forever while holding foreground and VID_MODE, with no way out but
;      Reset.  Blocking costs no CPU and any key quits.

                .INCLUDE "../kos_defs.inc"

                .SPACE  mandel
                        ; This binary's own task page.  kos_defs.inc's regions
                        ; (SYSVARS $0200, ...) are kernel-space and its .SPACE is
                        ; sticky across the .INCLUDE, so without this line .ORG
                        ; below would pin our code space to kernel and the
                        ; code-in-region guard fires at $000200.  RM 4.13.

ESCAPE_COMP     .EQU    8192
ESCAPE_SQ       .EQU    16384
MAX_ITER_1      .EQU    31
X_MIN           .EQU    $D800
Y_MIN           .EQU    $EC00
X_STEP          .EQU    22
Y_STEP          .EQU    21
FB_PAGE         .EQU    $B0
; VID_PAGE register - the framebuffer page the display scans out of.
; NOTE $DC, not $DD: $DD0000 is VID_MODE.  The old `VID_PAGE .EQU $DD`
; was the mode register's page, and the two constants below it
; (VID_ADDR/VID_8BPP) belonged to the direct VID_MODE write that was
; removed when TRAP_SETVIDMODE took over - all three are gone now.
VIDPAGE_PG      .EQU    $00DC           ; high byte of $DC0000
VIDPAGE_OFF     .EQU    $0000
FB_ROWS         .EQU    480
FB_COLS         .EQU    640

                .ORG    $0200           ; .COM entry point

                JMP16   start                   ; $0200 - universal entry
; --- .COM header (Part 60) -------------------------------------------------
; $0200 is a JMP16 so the image stays directly executable with no loader at
; all; the header follows at $0204 and is parsed separately, so a bad header
; can never endanger control flow.  The loader REFUSES a bad magic - there is
; no headerless fallback.  See kos_defs.inc for the full field description.
;
; Every field is a full WORD, and the block is emitted with .WORD only.  RM
; 4.6 lists what .BYTE accepts - numeric literals, string literals, escape
; sequences - and symbols are not among them, so `.BYTE COM_VERSION` is an
; undefined-symbol error (RM 11: only immediates, .EQU and .WORD evaluate
; expressions).  An all-.WORD block also cannot leave an odd byte count, so
; it can never desynchronise the alignment of what follows.
;
; To change the page allocation, edit COM_PAGES / COM_HEAPPG - nothing else in
; this file needs to know.
COM_PAGES       .EQU    1       ; TOTAL contiguous pages, including heap
COM_HEAPPG      .EQU    0       ; how many of those are heap (0 = task page)

                .WORD   COM_MAGIC       ; $0204 - dumps as 52 42 "RB"
                .WORD   COM_VERSION     ; $0206 - header version
                .WORD   COM_PAGES       ; $0208 - total pages
                .WORD   COM_HEAPPG      ; $020A - heap pages (partition of pages)
; --- end of header; start follows at $020C

start:
                ; Acquire video mode 2 (640x480 8bpp VGA) via k/OS
                LOADI   D0, #2          ; VID_MODE_640x480_VGA
                TRAP    #TRAP_SETVIDMODE
                BCS     vid_busy        ; ERR_BUSY → bail

                ; Point the display at the framebuffer we are about to
                ; render into.  VID_PAGE is not mediated by k/OS (the
                ; VID_MODE owner is implicitly entitled to bash it) and is
                ; not initialised by the kernel, so its contents are
                ; whatever the last graphics task left behind.  Without
                ; this the render is invisible.
                LOADI   Y0, #VIDPAGE_PG
                LOADI   X0, #VIDPAGE_OFF
                LOADI   D0, #FB_PAGE
                STORED  D0, [XY0]

                ; Clear the framebuffer to black before rendering.
                ; Every pixel does get written eventually, so this is not
                ; needed for the finished image - but the render walks the
                ; plane row by row over several minutes, and without the
                ; clear the previous graphics task's leftovers (Cube6's
                ; wireframe, GUI128F's window) sit on screen and get eaten
                ; away a line at a time.
                ;
                ; 640*480 = 307200 bytes = 153600 words, which will not fit
                ; a 16-bit counter, hence rows x words-per-row.  STORED
                ; [XY0]+ advances by 2 through the 24-bit carry-skip path,
                ; so it crosses the $B0->$B1... page boundaries by itself
                ; (RM 6.1) and is flag-transparent, leaving SUB/BNE to
                ; drive the loops.
                LOADI   Y0, #FB_PAGE
                LOADI   X0, #$0000
                LOADI   D0, #0                  ; black
                LOADI   D1, #FB_ROWS            ; 480 rows
clr_row:
                LOADI   D2, #FB_COLS/2          ; 320 words per row
clr_word:
                STORED  D0, [XY0]+              ; store, advance 2, page-safe
                SUB     D2, #1
                BNE     clr_word
                SUB     D1, #1
                BNE     clr_row

                ; Frame on kernel-provided stack (X3). Don't touch Y3.
                ; CRITICAL: must set Y2 = Y3 too — at task entry XY0..XY2 are
                ; zero per the fake INT frame, so Y2 = $00 (kernel page).
                ; Without this, [XY2+#N] writes go to kernel page $00:$FFEx,
                ; corrupting the kernel stack and eventually causing a fault.
                SUB     X3, #18
                MOVE    X2, X3
                MOVE    Y2, Y3
                LOADI   D0, #Y_MIN
                STORED  D0, [XY2+#10]
                LOADI   D0, #X_MIN
                STORED  D0, [XY2+#12]
                LOADI   D0, #0
                STORED  D0, [XY2+#14]

                ; Set framebuffer pointer
                LOADI   Y0, #FB_PAGE
                LOADI   X0, #$0000

                ; (Removed: redundant VID_MODE write — k/OS already set mode 2
                ;  via TRAP_SETVIDMODE above. Writing it again from the CPU
                ;  thread fires the emulator's IOWriteHook → SetVideoMode,
                ;  which manipulates LCL GUI components from the wrong thread.
                ;  Bare-metal version had this because it had no TRAP option.)

row_loop:
                LOADD   D0, [XY2+#12]
                STORED  D0, [XY2+#8]
                LOADI   X1, #0

col_loop:
                LOADI   D0, #0
                STORED  D0, [XY2+#0]
                STORED  D0, [XY2+#2]
                LOADI   D0, #MAX_ITER_1
                STORED  D0, [XY2+#16]

iter_loop:
                LOADD   D0, [XY2+#0]
                CMP     D0, #0
                BGE.L   x_pos
                NEG     D0, D0
x_pos:
                CMP     D0, #ESCAPE_COMP
                BGT.L   escaped

                LOADD   D0, [XY2+#2]
                CMP     D0, #0
                BGE.L   y_pos
                NEG     D0, D0
y_pos:
                CMP     D0, #ESCAPE_COMP
                BGT.L   escaped

                LOADD   D0, [XY2+#0]
                CALLR   sq12
                STORED  D0, [XY2+#4]

                LOADD   D0, [XY2+#2]
                CALLR   sq12
                STORED  D0, [XY2+#6]

                LOADD   D0, [XY2+#4]
                LOADD   D1, [XY2+#6]
                ADD     D0, D1
                CMP     D0, #ESCAPE_SQ
                BGT.L   escaped

                LOADD   D0, [XY2+#0]
                LOADD   D1, [XY2+#2]
                ADD     D0, D1
                CALLR   sq12
                LOADD   D1, [XY2+#4]
                SUB     D0, D1
                LOADD   D1, [XY2+#6]
                SUB     D0, D1
                LOADD   D1, [XY2+#10]
                ADD     D0, D1
                STORED  D0, [XY2+#2]

                LOADD   D0, [XY2+#4]
                LOADD   D1, [XY2+#6]
                SUB     D0, D1
                LOADD   D1, [XY2+#8]
                ADD     D0, D1
                STORED  D0, [XY2+#0]

                LOADD   D0, [XY2+#16]
                SUB     D0, #1
                STORED  D0, [XY2+#16]
                BNE.L   iter_loop

                LOADI   D3, #0
                BRA.L   write_pixel

escaped:
                LOADD   D3, [XY2+#16]
                AND     D3, #$0F
                BNE.L   write_pixel
                LOADI   D3, #1

write_pixel:
                STOREB  D3, [XY0]
                ADD     X0, #1
                BNE.L   no_bump
                ADD     Y0, #1
no_bump:
                LOADD   D0, [XY2+#8]
                ADD     D0, #X_STEP
                STORED  D0, [XY2+#8]

                ADD     X1, #1
                CMP     X1, #FB_COLS
                BNE.L   col_loop

                LOADD   D0, [XY2+#10]
                ADD     D0, #Y_STEP
                STORED  D0, [XY2+#10]

                LOADD   D0, [XY2+#14]
                ADD     D0, #1
                STORED  D0, [XY2+#14]
                CMP     D0, #FB_ROWS
                BNE.L   row_loop

                ; (Removed: redundant final VID_MODE write — same reason as above.)

                ; Restore stack (release frame)
                ADD     X3, #18

                ; Hold the finished image on screen until the user presses a
                ; key, then put the terminal back and exit.  We are a
                ; TF_FOCUSABLE ring member (sys_setvidmode acquire spliced us
                ; in), so keystrokes reach us through the gate while we hold
                ; the foreground.  Blocking here costs no CPU - the old
                ; `BRA .forever` spun a core forever holding VID_MODE and the
                ; foreground, recoverable only by Reset.
                TRAP    #TRAP_GETCHAR   ; block until any key

                LOADI   D0, #0          ; release video -> text mode
                TRAP    #TRAP_SETVIDMODE
                LOADI   D0, #0          ; exit code 0
                TRAP    #TRAP_EXIT

vid_busy:
                ; The acquire FAILED - we never took VID_MODE, never joined
                ; the focus ring, and kosh is still FOREGROUND_TCB, so
                ; nothing repaints on our way out and this text survives.
                ; (Output after a SUCCESSFUL acquire would not: the reap
                ; repaints the incoming shell's back-buffer over it.)
                ; D0 holds the ERR_* code - stash it across the printing.
                PUSH    D0, XY3
                LEA     XY0, msg_vid_busy
                TRAP    #TRAP_PUTS
                POP     D0, XY3
                TRAP    #TRAP_EXIT              ; kosh adds "[exit ERR_BUSY]"

msg_vid_busy:
                ; Hard-wrapped for 80 columns - the VT100 layer breaks at
                ; the margin wherever it lands, mid-word if need be.
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
                .ALIGN

sq12:
                CMP     D0, #0
                BGE.L   sq12_pos
                NEG     D0, D0
sq12_pos:
                MOVE    D1, D0
                SHR4    D1
                SHR4    D1
                MOVE    D2, D0
                AND     D2, #$00FF
                MOVE    D3, D1
                SWAPB   D3              ; RM B.11: SHL4/SHL4 corrupts >$0F
                OR      D3, D1
                MULB    D3
                MOVE    D0, D1
                SWAPB   D0              ; RM B.11
                OR      D0, D2
                MULB    D0
                MOVE    D1, D2          ; keep a copy of the low byte
                SWAPB   D2              ; RM B.11 (also drops a PUSH/POP)
                OR      D2, D1
                MULB    D2
                SHL4    D3
                SHL     D0
                SHR4    D0
                SHR4    D2
                SHR4    D2
                SHR4    D2
                ADD     D3, D0
                ADD     D3, D2
                MOVE    D0, D3
                RET
