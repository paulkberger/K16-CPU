; ============================================================================
; Cube6.asm  --  K16 3D Cube Wireframe, k/OS .COM port
; ----------------------------------------------------------------------------
; Gfx_Cube v6.  Ported from Gfx_Cube_v5.asm (bare-metal, 21 April 2026).
; Saturday, 1 August 2026 -- v6, Part 60: .COM header. The image now opens with
;                the universal 12-byte header - JMP16 start at $0200, magic
;                'RB' at $0204, version, page count, heap-page count - so
;                `start` moves from $0200 to $020C. Declares pages = 1,
;                heapPages = 0.
;                No code change: this file is position-independent by
;                construction (CALLR / BRA / Bcc / LEA throughout, see
;                below), so the 12-byte shift touches no operand. The
;                loader now REFUSES a headerless image - v5 will not run
;                under a Part 60 kernel and v6 will not run under an
;                older one.
; 11 May 2026 -- initial k/OS .COM port
; 16 May 2026 -- Part 33 sweep: clear_fb tail RET -> RETCS (1 site).
;                Net: -2 cycles, -1 word per frame. No legacy PUSH D / POP D
;                in this file; no canonical PUSH/POP D123 patterns; no
;                CLC/SEC + RET pairs. Implicit C=1 at clear_fb exit (both
;                BLO branches fell through with C=1 from final CMP) so
;                RETCS preserves the natural carry state.
;
; Changes for k/OS:
;   * .ORG $0200 (task entry point)         was: .ORG $FF0000
;   * No stack/Y3 init -- k/OS does it
;   * All variables relocated from page $00 ($0400..$04FF) to the
;     task's own page ($0100..$01FF, addressed via Y3 = current task
;     page). Page $00 belongs to the kernel under v3.10+.
;   * Banner emitted via sys_puts + CH_LF (Part 60: sys_putln retired,
;     TRAP #13 reassigned to sys_putlp) instead of raw
;     terminal-port writes.
;   * Vertex-table pointer builds use `MOVE Y2, Y3` instead of
;     `LOADI Y2, #$00`, because vert_x / vert_y are now task-local.
;   * Main loop is endless (visual demo) -- kill via kosh.
;
; Position-independent:
;   * Code references via CALLR / BRA / Bcc / LEA -- all PC-relative.
;   * Data references to ROM tables (idx3_tbl, vert3d, edges, cos_tbl,
;     data tables) via LEA -- PC-relative.
;   * I/O ports (VID_MODE, VID_PAGE) and framebuffer addresses are
;     fixed regardless of load page -- loaded via LOADI literal.
;
; Note: video RAM and VID_PAGE are not mediated by k/OS in this build;
; the task touches the framebuffer directly. If a future k/OS adds a
; video lock or multi-task video mux, this will need syscall wrappers.
; ============================================================================

                .INCLUDE "../kos_defs.inc"

                .SPACE  cube
                        ; This binary's own task page.  kos_defs.inc's regions
                        ; (SYSVARS $0200, ...) are kernel-space and its .SPACE is
                        ; sticky across the .INCLUDE, so without this line .ORG
                        ; below would pin our code space to kernel and the
                        ; code-in-region guard fires at $000200.  RM 4.13.

VID_MODE        .EQU    $DD0000
VID_PAGE        .EQU    $DC0000
CX              .EQU    320
CY              .EQU    240

FB_PAGE_A       .EQU    $00B0           ; high byte of FB_A base (B00000 >> 16)
FB_PAGE_B       .EQU    $00B4           ; high byte of FB_B base (B40000 >> 16)

; ====== Task-local RAM (task page, $0100..$01FF) ==========================
; Reached via LOADP/STOREP, Y3, [#sym]. Kernel reserves $0000..$00FF, so
; we start at $0100.
ln_x0           .EQU    $0100
ln_y0           .EQU    $0102
ln_x1           .EQU    $0104
ln_y1           .EQU    $0106
ln_col          .EQU    $0108
ln_dx           .EQU    $010A
ln_dy           .EQU    $010C
ln_sx           .EQU    $010E
ln_sy           .EQU    $0110
ln_err          .EQU    $0112
ln_cx           .EQU    $0114
ln_cy           .EQU    $0116

draw_page       .EQU    $0118           ; current draw page (high byte word)

angle_y         .EQU    $0140
angle_x         .EQU    $0142
cos_y           .EQU    $0144
sin_y           .EQU    $0146
cos_x           .EQU    $0148
sin_x           .EQU    $014A

vx0             .EQU    $0150
vy0             .EQU    $0152
vz0             .EQU    $0154
vx1             .EQU    $0156
vz1             .EQU    $0158
tmp_prod        .EQU    $015A
vert_idx        .EQU    $015C
edge_idx        .EQU    $015E

vert_x          .EQU    $0160           ; 8 words: $0160..$016F
vert_y          .EQU    $0180           ; 8 words: $0180..$018F

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
                ; No console banner.  A graphics task has no back-buffer,
                ; so its text goes straight to the terminal and nothing
                ; records it: the mode switch a few instructions below
                ; hides it, and the repaint _ReapDeadTask does on the way
                ; out erases it.  Failure is reported by exit code.

                ; Acquire video mode 2 (640x480 8bpp VGA) via k/OS
                ; (Part 20: VID_MODE is now arbitrated by sys_setvidmode.
                ; Direct MMIO writes still work but bypass the kernel's
                ; auto-reset on death, so use the syscall.)
                LOADI   D0, #2                  ; VID_MODE_640x480_VGA
                TRAP    #TRAP_SETVIDMODE
                BCS     .vid_busy               ; ERR_BUSY → bail

                ; start with draw_page = B (we're showing A by default)
                LOADI   D0, #FB_PAGE_B
                STOREP  D0, Y3, [#draw_page]

                LOADI   D0, #0
                STOREP  D0, Y3, [#angle_y]
                STOREP  D0, Y3, [#angle_x]
                BRA     frame

.vid_busy:
                ; The acquire FAILED, so we never took VID_MODE and never
                ; joined the focus ring - we are still a plain task, kosh is
                ; still FOREGROUND_TCB, and nothing repaints on our way out.
                ; So this text survives, exactly like a usage message from a
                ; text-mode .COM.  (Anything printed AFTER a successful
                ; acquire would not: _ReapDeadTask repaints the incoming
                ; foreground shell's back-buffer over it.)
                ;
                ; D0 holds the ERR_* code, so stash it across the printing.
                PUSH    D0, XY3
                LEA     XY0, msg_vid_busy
                TRAP    #TRAP_PUTS
                POP     D0, XY3
                TRAP    #TRAP_EXIT              ; kosh adds "[exit ERR_BUSY]"
                ; (sys_exit doesn't return)

msg_vid_busy:
                ; Hard-wrapped: sys_puts emits bytes and the VT100 layer
                ; breaks at the right margin wherever it lands, so a single
                ; 88-char line splits mid-word on an 80-column terminal.
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

frame:
                CALLR   clear_fb
                CALLR   project_vertices
                CALLR   draw_curr_cube

                ; flip: show the page we just drew to
                LOADI   X0, #<VID_PAGE
                LOADI   Y0, #>VID_PAGE
                LOADP   D0, Y3, [#draw_page]
                STORED  D0, [XY0]

                ; swap draw_page: A <-> B (XOR with $04 toggles B0 <-> B4)
                LOADP   D0, Y3, [#draw_page]
                XOR     D0, #$0004
                STOREP  D0, Y3, [#draw_page]

                ; advance angles
                LOADP   D0, Y3, [#angle_y]
                ADD     D0, #1
                AND     D0, #$FF
                STOREP  D0, Y3, [#angle_y]

                LOADP   D0, Y3, [#angle_x]
                ADD     D0, #3
                AND     D0, #$FF
                STOREP  D0, Y3, [#angle_x]

                ; Any key quits.  sys_kbhit is the non-blocking poll -
                ; sys_getchar would block and freeze the cube on frame
                ; one.  C=1 means the ring was empty, so keep spinning.
                TRAP    #TRAP_KBHIT
                BCS     frame                   ; no key - next frame

                LOADI   D0, #0                  ; release video -> text mode
                TRAP    #TRAP_SETVIDMODE
                LOADI   D0, #0                  ; exit code 0
                TRAP    #TRAP_EXIT

; =========================================================================
; draw_curr_cube -- 12 edges, face-coloured
; =========================================================================
draw_curr_cube:
                LOADI   D0, #0
                STOREP  D0, Y3, [#edge_idx]
.dcc_loop:
                LOADP   D0, Y3, [#edge_idx]
                ADD     D0, D0
                LEA     XY2, edges
                ADD     X2, D0
                LOADB   D2, [XY2]
                INC     X2, #1
                LOADB   D3, [XY2]

                MOVE    D0, D2
                ADD     D0, D0
                LOADI   X2, #vert_x
                MOVE    Y2, Y3                  ; task page
                ADD     X2, D0
                LOADD   D0, [XY2]
                STOREP  D0, Y3, [#ln_x0]

                MOVE    D0, D2
                ADD     D0, D0
                LOADI   X2, #vert_y
                MOVE    Y2, Y3
                ADD     X2, D0
                LOADD   D0, [XY2]
                STOREP  D0, Y3, [#ln_y0]

                MOVE    D0, D3
                ADD     D0, D0
                LOADI   X2, #vert_x
                MOVE    Y2, Y3
                ADD     X2, D0
                LOADD   D0, [XY2]
                STOREP  D0, Y3, [#ln_x1]

                MOVE    D0, D3
                ADD     D0, D0
                LOADI   X2, #vert_y
                MOVE    Y2, Y3
                ADD     X2, D0
                LOADD   D0, [XY2]
                STOREP  D0, Y3, [#ln_y1]

                LOADP   D0, Y3, [#edge_idx]
                CMP     D0, #4
                BLT     .col_back
                CMP     D0, #8
                BLT     .col_front
                LOADI   D0, #15
                BRA     .col_done
.col_back:
                LOADI   D0, #4
                BRA     .col_done
.col_front:
                LOADI   D0, #11
.col_done:
                STOREP  D0, Y3, [#ln_col]
                CALLR   draw_line

                LOADP   D0, Y3, [#edge_idx]
                ADD     D0, #1
                STOREP  D0, Y3, [#edge_idx]
                CMP     D0, #12
                BLT     .dcc_loop
                RET

; =========================================================================
project_vertices:
                LOADP   D0, Y3, [#angle_y]
                LEA     XY2, cos_tbl
                ADD     X2, D0
                LOADB   D1, [XY2]
                CALLR   sext_d1
                STOREP  D1, Y3, [#cos_y]

                LOADP   D0, Y3, [#angle_y]
                ADD     D0, #192
                AND     D0, #$FF
                LEA     XY2, cos_tbl
                ADD     X2, D0
                LOADB   D1, [XY2]
                CALLR   sext_d1
                STOREP  D1, Y3, [#sin_y]

                LOADP   D0, Y3, [#angle_x]
                LEA     XY2, cos_tbl
                ADD     X2, D0
                LOADB   D1, [XY2]
                CALLR   sext_d1
                STOREP  D1, Y3, [#cos_x]

                LOADP   D0, Y3, [#angle_x]
                ADD     D0, #192
                AND     D0, #$FF
                LEA     XY2, cos_tbl
                ADD     X2, D0
                LOADB   D1, [XY2]
                CALLR   sext_d1
                STOREP  D1, Y3, [#sin_x]

                LOADI   D0, #0
                STOREP  D0, Y3, [#vert_idx]
.pv_loop:
                LOADP   D0, Y3, [#vert_idx]
                LEA     XY2, idx3_tbl
                ADD     X2, D0
                LOADB   D0, [XY2]

                LEA     XY2, vert3d
                ADD     X2, D0
                LOADB   D1, [XY2]
                MOVE    D2, D1
                AND     D2, #$80
                BEQ     .pv_x_pos
                OR      D1, #$FF00
.pv_x_pos:
                STOREP  D1, Y3, [#vx0]

                LEA     XY2, vert3d
                ADD     X2, D0
                INC     X2, #1
                LOADB   D1, [XY2]
                MOVE    D2, D1
                AND     D2, #$80
                BEQ     .pv_y_pos
                OR      D1, #$FF00
.pv_y_pos:
                STOREP  D1, Y3, [#vy0]

                LEA     XY2, vert3d
                ADD     X2, D0
                INC     X2, #2
                LOADB   D1, [XY2]
                MOVE    D2, D1
                AND     D2, #$80
                BEQ     .pv_z_pos
                OR      D1, #$FF00
.pv_z_pos:
                STOREP  D1, Y3, [#vz0]

                ; Y rotation: x1
                LOADP   D0, Y3, [#vx0]
                LOADP   D1, Y3, [#cos_y]
                CALLR   signed_mul
                STOREP  D0, Y3, [#tmp_prod]

                LOADP   D0, Y3, [#vz0]
                LOADP   D1, Y3, [#sin_y]
                CALLR   signed_mul

                LOADP   D1, Y3, [#tmp_prod]
                SUB     D1, D0
                ASR4    D1
                ASR     D1
                ASR     D1
                STOREP  D1, Y3, [#vx1]

                ; Y rotation: z1
                LOADP   D0, Y3, [#vx0]
                LOADP   D1, Y3, [#sin_y]
                CALLR   signed_mul
                STOREP  D0, Y3, [#tmp_prod]

                LOADP   D0, Y3, [#vz0]
                LOADP   D1, Y3, [#cos_y]
                CALLR   signed_mul

                LOADP   D1, Y3, [#tmp_prod]
                ADD     D1, D0
                ASR4    D1
                ASR     D1
                ASR     D1
                STOREP  D1, Y3, [#vz1]

                ; X rotation: y2 = y*cos_x - z1*sin_x
                LOADP   D0, Y3, [#vy0]
                LOADP   D1, Y3, [#cos_x]
                CALLR   signed_mul
                STOREP  D0, Y3, [#tmp_prod]

                LOADP   D0, Y3, [#vz1]
                LOADP   D1, Y3, [#sin_x]
                CALLR   signed_mul

                LOADP   D1, Y3, [#tmp_prod]
                SUB     D1, D0
                ASR4    D1
                ASR     D1
                ASR     D1

                LOADI   D0, #CY
                SUB     D0, D1

                LOADP   D1, Y3, [#vert_idx]
                ADD     D1, D1
                LOADI   X2, #vert_y
                MOVE    Y2, Y3
                ADD     X2, D1
                STORED  D0, [XY2]

                LOADI   D0, #CX
                LOADP   D1, Y3, [#vx1]
                ADD     D0, D1

                LOADP   D1, Y3, [#vert_idx]
                ADD     D1, D1
                LOADI   X2, #vert_x
                MOVE    Y2, Y3
                ADD     X2, D1
                STORED  D0, [XY2]

                LOADP   D0, Y3, [#vert_idx]
                ADD     D0, #1
                STOREP  D0, Y3, [#vert_idx]
                CMP     D0, #8
                BLT     .pv_loop
                RET

; =========================================================================
sext_d1:
                MOVE    D2, D1
                AND     D2, #$80
                BEQ     .sx_done
                OR      D1, #$FF00
.sx_done:
                RET

; =========================================================================
; signed_mul -- D0 * D1 -> D0, |inputs| <= 127
; Clobbers D1, D2, D3.
; =========================================================================
signed_mul:
                LOADI   D2, #0
                CMP     D0, #0
                BGE     .sm_apos
                NEG     D0
                XOR     D2, #1
.sm_apos:
                CMP     D1, #0
                BGE     .sm_bpos
                LOADI   D3, #0
                SUB     D3, D1
                MOVE    D1, D3
                XOR     D2, #1
.sm_bpos:
                SWAPB   D1
                OR      D0, D1
                MULB    D0
                CMP     D2, #0
                BEQ     .sm_done
                NEG     D0
.sm_done:
                RET

; =========================================================================
; clear_fb -- fill current draw page with 0
; =========================================================================
clear_fb:
                LOADP   D0, Y3, [#draw_page]
                MOVE    Y0, D0
                LOADI   X0, #$0000
                LOADP   D0, Y3, [#draw_page]
                ADD     D0, #4                  ; end page (exclusive)
                MOVE    Y1, D0
                LOADI   X1, #$B000              ; end X = $B000 (total $4B000)
                LOADI   D0, #0
.cf_loop:
                STORED  D0, [XY0]+
                STORED  D0, [XY0]+
                STORED  D0, [XY0]+
                STORED  D0, [XY0]+
                STORED  D0, [XY0]+
                STORED  D0, [XY0]+
                STORED  D0, [XY0]+
                STORED  D0, [XY0]+
                STORED  D0, [XY0]+
                STORED  D0, [XY0]+
                STORED  D0, [XY0]+
                STORED  D0, [XY0]+
                STORED  D0, [XY0]+
                STORED  D0, [XY0]+
                STORED  D0, [XY0]+
                STORED  D0, [XY0]+
                CMP     Y0, Y1
                BLO     .cf_loop
                CMP     X0, X1
                BLO     .cf_loop
                RETCS

; =========================================================================
draw_line:
                LOADP   D0, Y3, [#ln_x1]
                LOADP   D1, Y3, [#ln_x0]
                SUB     D0, D1
                BGE     .dx_pos
                NEG     D0
                LOADI   D1, #$FFFF
                BRA     .dx_done
.dx_pos:
                LOADI   D1, #1
.dx_done:
                STOREP  D0, Y3, [#ln_dx]
                STOREP  D1, Y3, [#ln_sx]

                LOADP   D0, Y3, [#ln_y1]
                LOADP   D1, Y3, [#ln_y0]
                SUB     D0, D1
                BGE     .dy_pos
                NEG     D0
                LOADI   D1, #$FFFF
                BRA     .dy_done
.dy_pos:
                LOADI   D1, #1
.dy_done:
                STOREP  D0, Y3, [#ln_dy]
                STOREP  D1, Y3, [#ln_sy]

                LOADP   D0, Y3, [#ln_x0]
                STOREP  D0, Y3, [#ln_cx]
                LOADP   D0, Y3, [#ln_y0]
                STOREP  D0, Y3, [#ln_cy]

                LOADP   D0, Y3, [#ln_dx]
                LOADP   D1, Y3, [#ln_dy]
                CMP     D0, D1
                BLT     .steep

                LOADP   D0, Y3, [#ln_dy]
                ADD     D0, D0
                LOADP   D1, Y3, [#ln_dx]
                SUB     D0, D1
                STOREP  D0, Y3, [#ln_err]
                LOADP   D3, Y3, [#ln_dx]
                INC     D3
.sh_loop:
                CALLR   plot_pixel
                LOADP   D0, Y3, [#ln_err]
                CMP     D0, #0
                BLE     .sh_no_y
                LOADP   D1, Y3, [#ln_cy]
                LOADP   D2, Y3, [#ln_sy]
                ADD     D1, D2
                STOREP  D1, Y3, [#ln_cy]
                LOADP   D1, Y3, [#ln_dx]
                ADD     D1, D1
                SUB     D0, D1
.sh_no_y:
                LOADP   D1, Y3, [#ln_dy]
                ADD     D1, D1
                ADD     D0, D1
                STOREP  D0, Y3, [#ln_err]
                LOADP   D1, Y3, [#ln_cx]
                LOADP   D2, Y3, [#ln_sx]
                ADD     D1, D2
                STOREP  D1, Y3, [#ln_cx]
                DEC     D3
                BNE     .sh_loop
                RET

.steep:
                LOADP   D0, Y3, [#ln_dx]
                ADD     D0, D0
                LOADP   D1, Y3, [#ln_dy]
                SUB     D0, D1
                STOREP  D0, Y3, [#ln_err]
                LOADP   D3, Y3, [#ln_dy]
                INC     D3
.st_loop:
                CALLR   plot_pixel
                LOADP   D0, Y3, [#ln_err]
                CMP     D0, #0
                BLE     .st_no_x
                LOADP   D1, Y3, [#ln_cx]
                LOADP   D2, Y3, [#ln_sx]
                ADD     D1, D2
                STOREP  D1, Y3, [#ln_cx]
                LOADP   D1, Y3, [#ln_dy]
                ADD     D1, D1
                SUB     D0, D1
.st_no_x:
                LOADP   D1, Y3, [#ln_dx]
                ADD     D1, D1
                ADD     D0, D1
                STOREP  D0, Y3, [#ln_err]
                LOADP   D1, Y3, [#ln_cy]
                LOADP   D2, Y3, [#ln_sy]
                ADD     D1, D2
                STOREP  D1, Y3, [#ln_cy]
                DEC     D3
                BNE     .st_loop
                RET

; =========================================================================
; plot_pixel -- write ln_col at (cx, cy) in the current draw page
; =========================================================================
plot_pixel:
                CALLR   mul_cy_640
                LOADP   D1, Y3, [#ln_cx]
                ADD     X0, D1
                BCC     .pp_nc
                ADD     Y0, #1
.pp_nc:
                LOADP   D2, Y3, [#draw_page]
                ADD     Y0, D2                  ; Y0 += draw page (B0 or B4)
                LOADP   D0, Y3, [#ln_col]
                STOREB  D0, [XY0]
                RET

; =========================================================================
mul_cy_640:
                ; cy*640 = (cy*160)<<2 ; cy*160 via MULB (160*lo + 160*hi<<8)
                LOADP   D0, Y3, [#ln_cy]
                MOVE    D1, D0
                HIGH    D1                      ; cy_hi
                LOW     D0                      ; cy_lo
                LOADI   D2, #160
                SWAPB   D2
                OR      D0, D2
                MULB    D0                      ; 160 * cy_lo
                LOADI   D2, #160
                SWAPB   D2
                OR      D1, D2
                MULB    D1                      ; 160 * cy_hi
                MOVE    D2, D1
                LOW     D2
                SWAPB   D2                      ; (hi-prod low) << 8
                HIGH    D1                      ; hi-prod high
                ADD     D0, D2
                ADC     D1, #0                  ; D1:D0 = cy*160
                ADD     D0, D0
                ADC     D1, D1                  ; cy*320
                ADD     D0, D0
                ADC     D1, D1                  ; cy*640
                MOVE    X0, D0
                MOVE    Y0, D1
                RET

; =========================================================================
; Data tables (in the .COM image, reached via LEA -- PC-relative)
; =========================================================================
idx3_tbl:
                .BYTE   0, 3, 6, 9, 12, 15, 18, 21

vert3d:
                .BYTE   156, 156, 156, 100, 156, 156, 100, 100, 156, 156, 100, 156
                .BYTE   156, 156, 100, 100, 156, 100, 100, 100, 100, 156, 100, 100

edges:
                .BYTE   0, 1, 1, 2, 2, 3, 3, 0, 4, 5, 5, 6, 6, 7, 7, 4
                .BYTE   0, 4, 1, 5, 2, 6, 3, 7

cos_tbl:
                .BYTE   64,  64,  64,  64,  64,  64,  63,  63,  63,  62,  62,  62,  61,  61,  60,  60
                .BYTE   59,  59,  58,  57,  56,  56,  55,  54,  53,  52,  51,  50,  49,  48,  47,  46
                .BYTE   45,  44,  43,  42,  41,  39,  38,  37,  36,  34,  33,  32,  30,  29,  27,  26
                .BYTE   24,  23,  22,  20,  19,  17,  16,  14,  12,  11,   9,   8,   6,   5,   3,   2
                .BYTE    0, 254, 253, 251, 250, 248, 247, 245, 244, 242, 240, 239, 237, 236, 234, 233
                .BYTE  232, 230, 229, 227, 226, 224, 223, 222, 220, 219, 218, 217, 215, 214, 213, 212
                .BYTE  211, 210, 209, 208, 207, 206, 205, 204, 203, 202, 201, 200, 200, 199, 198, 197
                .BYTE  197, 196, 196, 195, 195, 194, 194, 194, 193, 193, 193, 192, 192, 192, 192, 192
                .BYTE  192, 192, 192, 192, 192, 192, 193, 193, 193, 194, 194, 194, 195, 195, 196, 196
                .BYTE  197, 197, 198, 199, 200, 200, 201, 202, 203, 204, 205, 206, 207, 208, 209, 210
                .BYTE  211, 212, 213, 214, 215, 217, 218, 219, 220, 222, 223, 224, 226, 227, 229, 230
                .BYTE  232, 233, 234, 236, 237, 239, 240, 242, 244, 245, 247, 248, 250, 251, 253, 254
                .BYTE    0,   2,   3,   5,   6,   8,   9,  11,  12,  14,  16,  17,  19,  20,  22,  23
                .BYTE   24,  26,  27,  29,  30,  32,  33,  34,  36,  37,  38,  39,  41,  42,  43,  44
                .BYTE   45,  46,  47,  48,  49,  50,  51,  52,  53,  54,  55,  56,  56,  57,  58,  59
                .BYTE   59,  60,  60,  61,  61,  62,  62,  62,  63,  63,  63,  64,  64,  64,  64,  64

                .ALIGN

; ============================================================================
; End of Gfx_Cube.asm
; ============================================================================
