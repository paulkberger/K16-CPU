; ============================================================================
; kos_console.asm — k/OS console syscall handlers
; ============================================================================
; Date:    13 May 2026
; Status:  Phase 14 + Phase A keyboard ring + Phase B Steps 3 & 4
; Revision: r14 - 13 May 2026 — Phase B Steps 3 & 4 complete.
;             Step 3: output routing for all 7 console syscalls
;             (sys_putchar, sys_puts, sys_putln, sys_putdec, sys_puthex,
;             sys_clear, sys_setcursor) — at entry each tests caller's
;             TF_HAS_BACKBUF flag and branches to fast path (bit-identical
;             to pre-Phase B) or shell body (dual-emit through
;             _BackbufPutChar when foreground, back-buffer only when
;             background). sys_clear (shell) zero-fills the back-buffer
;             and resets cursor; sys_setcursor (shell) writes
;             TCB_BACKBUF_CRSR directly. ESC sequences bypass
;             _BackbufPutChar.
;             Step 4: sys_getchar and sys_gets keyboard reads gated by
;             foreground status when caller is a shell. Background
;             shells block on .ggk_wait until they become foreground.
;             Spin is safe — timer IRQ fires (TRAP preserves SR/IE=1)
;             so scheduler runs and other tasks get CPU. sys_getchar
;             tail-calls _GetGatedKey; sys_gets calls _GetGatedKey
;             per character (replaces former _RingWaitPop call).
;             Echo STOREBs in sys_gets are NOT routed to back-buffer
;             in v1 (acceptable staleness; recaptured at sys_putln).
;             Requires kos_defs.inc r34+ and kos_switcher.asm r3+.
;
;           r13 - 13 May 2026 — Phase A: sys_getchar reduced to a single
;             BRA into _RingWaitPop. The MMIO spin moved out into
;             _KbdTick (kos_ctxsw.asm) and the ring primitives live in
;             kdrv/kos_kbd.asm. Type-ahead now works because keystrokes
;             buffer into the ring every tick rather than only being
;             observable when a task is in sys_getchar.
;             Also: sys_gets' inline MMIO spin replaced with a
;             CALL24 _RingWaitPop (with D1 push/pop around it, since
;             _RingWaitPop clobbers D1 — D2 is preserved). This was
;             the second of two direct MMIO reader sites in the tree;
;             both now go through the ring.
;
;           r12 - 5 May 2026 — Phase 14. Retrofit the leaf-syscall
;             EINT gate from kos_heap.asm onto all six leaf syscalls
;             that use DINT/EINT here: sys_puts, sys_putln, sys_putdec,
;             sys_puthex, sys_clear, sys_setcursor. Each now reads
;             KERNEL_STATE and skips the EINT in BOOT context. Without
;             this, calling any of these from boot-context kernel code
;             (e.g. before _RestoreIdle promotes BOOT->RUN) would enable
;             IRQs against IDLE_TCB and corrupt the kernel stack on
;             Digital. EMU is permissive; bug was previously dormant.
;             Six instructions per site, no register clobber (D0 dead
;             at every EINT in this file by inspection).
;
;           r11 - 5 May 2026 — Phase 10. _KMul16x16_32 and _KDiv10
;             relocated to kos_klib_impl.asm. Existing in-file callers
;             (sys_putdec, _RawPutDec) continue to call the symbols
;             directly; only the file location changes. No behavioural
;             change to console handlers.
;
;           r10 - 4 May 2026 — Branch .S polish.
;             14 unsuffixed branches converted to .S form
;             where target distance is ≤10 instructions.
;             FORWARD ONLY (assembler imm5 is unsigned 0..+31).
;             Per
;             K16 Manual Amendment 2026-05-04 E.5/E.6, default
;             auto-select picks long form; explicit .S saves
;             one word per branch. Saves 14 words.
;
; Revision: r9 - 4 May 2026 — Opcode polish.
;             - Six SHL4 D? / SHL4 D? pairs in _KMul16x16_32 replaced
;               with single SWAPB D? — the canonical byte-shift-into-
;               high-byte idiom (per K16 Reference Manual section 6.5
;               MULB packing patterns). Saves 6 instructions.
;             - Five AND D?, #$00FF / AND D?, #$FF replaced with LOW D?.
;               Same operation, 1 word instead of 2, 3 cycles instead
;               of 4. Z flag no longer set, but no callers depend on
;               it (verified). Saves 5 words.
;             Net saving in this file: 6 instructions + 5 words.
;
;           r8 - 4 May 2026 — LEA Mode 00 refactor.
;             Per K16_Manual_Amendment_2026-05-04.md A.1 + Mode 00
;             validation (test_lea_mode00_v2.asm), four MOVE Xx,Xy /
;             MOVE Yx,Yy XY-copy pairs replaced with LEA XYx, XYy.
;             Sites: sys_puts, sys_putln, sys_gets, sys_putdec.emit.
;             Net saving: 4 instructions.
;
;             RET #4w NOT applied to _KMul16x16_32: per amendment G.2
;             clarification, RET #Nw is for caller-pushed args only.
;             _KMul16x16_32 has callee-pushed scratch (4 self-pushed
;             words) — `ADD X3,#8 / RET` is the correct pattern there.
;
;           r7 - 4 May 2026 — REFACTOR FULLY REVERTED (initial r7
;             attempt). Reverted to manual MOVE sequences pending
;             diagnosis.
;
;           r6 - 3 May 2026 — sys_putdec divide replaced with _KDiv10
;             reciprocal-multiply helper (adapted from Forth v2.24).
;             Worst-case (D0=65535) drops from ~6500 cycles to ~80 cycles
;             (~80× speedup). Added shared kernel helpers _KMul16x16_32
;             and _KDiv10 at end of file. _RawPutDec in kos_splash.asm
;             also calls _KDiv10. DINT envelope on sys_putdec preserved
;             but now closes the timer hole that previously held the
;             scheduler off for ~73ms on Digital max-value inputs.
;             Requires kos_splash.asm r5+ for the matching _RawPutDec
;             change.
;
;           r5 - 2 May 2026 — Part 8 additions:
;             - sys_putdec  (TRAP #20): D0 as unsigned decimal
;             - sys_puthex  (TRAP #21): D0 as 4-digit hex
;             - sys_clear   (TRAP #22): host-aware clear screen
;             - sys_setcursor (TRAP #23): host-aware cursor positioning
;             clear/setcursor read KOS_HOST: VT100 sequences on EMU,
;             best-effort fallback on Digital (clear=LFs, setcursor=no-op).
;             putdec/puthex are unconditional (no ESC sequences).
;             All four are leaf syscalls — TRAP / body / RET, flag-return.
;           r4 - 1 May 2026 — sys_puts/sys_putln atomic via DINT/EINT
;             (atomicity expedient — see notes below).
;           r3 - 30 April 2026 — initial multitasking-aware version.
;
; Note: included from kos_boot.asm; constants come from kos_defs.inc.
;
; ============================================================================
; ATOMICITY EXPEDIENT (Phase 3, 1 May 2026)
; ============================================================================
; sys_puts and sys_putln wrap their per-byte pump loop in DINT/EINT so
; the entire string emits as one uninterruptible operation. Without this,
; the timer IRQ can preempt mid-string, the next task pumps its own bytes
; to the same terminal, and streams interleave at byte granularity.
;
; This is a TEMPORARY expedient — Phase 4+ should replace with a console
; mutex or per-task output FIFO drained by a writer task.
;
; sys_putdec, sys_puthex, sys_clear, sys_setcursor follow the same
; convention since they all emit multi-byte sequences.
;
; sys_gets is NOT atomic — it blocks on keyboard input and would starve
; all other tasks indefinitely. Multi-task line-edit arbitration is
; deferred to Phase 4+.
;
; sys_putchar is single-byte and inherently atomic.
; ============================================================================

; ============================================================================
; sys_putchar — TRAP #9
;   Write one character to the terminal.
;   Input:   D0 = character (low byte used)
;   Output:  D0 = 0, C=0
;   Clobbers: D0, XY0
;
; Phase B Step 3: caller's TCB is checked for TF_HAS_BACKBUF. If clear,
; the original fast path runs (a single STOREB to terminal MMIO). If set,
; the shell path additionally calls _BackbufPutChar to update the caller's
; back-buffer, and only emits to the terminal if the caller is currently
; foreground.
; ============================================================================
sys_putchar:
                ; --- Routing prologue ---
                ; Save the input byte; we need D0 free for the flag test.
                PUSH    D0, XY3

                ; Read caller's TCB_FLAGS via MY_TCB_PTR (task-local slot).
                LOADP   X0, Y3, [#MY_TCB_PTR]
                LOADI   Y0, #$00
                LOADD   D0, [XY0+#TCB_FLAGS]
                AND     D0, #TF_HAS_BACKBUF     ; Z=1 → no backbuf

                ; Restore the byte. POP preserves flags from the AND.
                POP     D0, XY3
                BNE     .pc_shell

                ; --- Fast path (non-shell, unchanged from pre-Phase B) ---
                LOADI   Y0, #TERMINAL_PAGE
                LOADI   X0, #$0000
                STOREB  D0, [XY0]

                LOADI   D0, #ERR_OK
                RETCC

.pc_shell:
                ; --- Shell path ---
                ; Save callee-preserve regs we're about to clobber.
                ; _BackbufPutChar clobbers D0..D3 and XY0, XY2; preserves XY1, XY3.
                ; We additionally need to save XY1 because we'll set it to
                ; the caller's TCB ptr.
                PUSH    D123, XY3
                PUSH    XY1, XY3
                PUSH    XY2, XY3

                ; XY1 = caller's TCB.
                LOADP   X1, Y3, [#MY_TCB_PTR]
                LOADI   Y1, #$00

                ; If foreground, emit raw byte to terminal first. (Terminal
                ; interprets CR/LF/BS natively; we don't need _BackbufPutChar's
                ; cursor logic for the terminal side.) Use XY2 for the MMIO
                ; address since _BackbufPutChar will clobber it anyway.
                LOADZ   D1, [#FOREGROUND_TCB]
                LOADD   D2, [XY1+#TCB_ID]
                CMP     D1, D2
                BNE.S   .pc_skip_term
                LOADI   Y2, #TERMINAL_PAGE
                LOADI   X2, #$0000
                STOREB  D0, [XY2]

.pc_skip_term:
                ; Update back-buffer (always). D0 = byte, XY1 = TCB.
                CALL24  _BackbufPutChar

                POP     XY2, XY3
                POP     XY1, XY3
                POP     D123, XY3

                LOADI   D0, #ERR_OK
                RETCC

; ============================================================================
; sys_getchar — TRAP #10
;   Read one character from the keyboard ring. Blocks if empty.
;   Input:   none
;   Output:  D0 = character (zero-extended), C=0
;   Clobbers: D0, XY0
;   Preserves: D1, D2, D3, XY1, XY2, XY3       ; V2 ABI (Part 36)
;
;   Phase A: identical to _RingWaitPop (kdrv/kos_kbd.asm). Phase B adds
;   the foreground gate for shells: a shell that is currently a background
;   task blocks until it becomes foreground. The MMIO read used to live
;   here; it now lives in _KbdTick inside _TimerIRQ (kos_ctxsw.asm) so
;   keystrokes are buffered even when no task is in sys_getchar.
;
; Phase B Step 4: if the caller has TF_HAS_BACKBUF (i.e. is a registered
; shell), the function spins until two conditions both hold:
;   1. caller is the foreground shell (FOREGROUND_TCB == my TID)
;   2. a key is available in the ring
;
; The spin is safe because timer IRQs fire during the loop (caller's SR
; from TRAP has IE=1) and the scheduler runs every 30Hz, so other tasks
; get fair CPU time.
;
; The Step 4 gate works alongside Step 6 (keyboard dispatch hot-key
; filter). Step 4 alone provides the task-side gate; Step 6 provides the
; driver-side ring-push gate. Together they implement "only the
; foreground shell receives keystrokes."
; ============================================================================
sys_getchar:
                BRA     _GetGatedKey

; ----------------------------------------------------------------------------
; _GetGatedKey — get one keystroke with foreground gate
;
; Used both as sys_getchar's body (via tail-call BRA) AND as a kernel-
; internal helper callable from inside other syscall handlers (e.g.
; sys_gets) without a nested TRAP.
;
; In:        none
; Out:       D0 = byte (zero-extended), C=0
; Clobbers:  D0, XY0
; Preserves: D1, D2, D3, XY1, XY2, XY3           ; V2 ABI (Part 36)
;
; Part 36: was 'Clobbers: D0, D1, XY0'. Swapped the FOREGROUND_TCB
; comparison scratch from D1 to D2, with PUSH/POP D2 around the
; gated path so D2 is preserved across the call.
; ----------------------------------------------------------------------------
_GetGatedKey:
                ; Routing test.
                LOADP   X0, Y3, [#MY_TCB_PTR]
                LOADI   Y0, #$00
                LOADD   D0, [XY0+#TCB_FLAGS]
                AND     D0, #TF_HAS_BACKBUF
                BEQ     _RingWaitPop            ; not a shell — straight to ring

                ; --- Shell path: gate on foreground status ---
                ; Preserve D2 across the gate (callee-preserved per V2 ABI).
                PUSH    D2, XY3
.ggk_wait:
                LOADP   X0, Y3, [#MY_TCB_PTR]
                LOADI   Y0, #$00
                LOADD   D0, [XY0+#TCB_ID]       ; D0 = my TID
                LOADZ   D2, [#FOREGROUND_TCB]   ; D2 = foreground TID
                CMP     D0, D2
                BNE     .ggk_wait               ; not foreground → spin

                ; Foreground — try the ring.
                CALL24  _RingPop
                BCS     .ggk_wait               ; empty → re-check fg + retry
                POP     D2, XY3                 ; restore preserved D2
                RETCC                           ; D0 = byte, C=0

; ============================================================================
; sys_puts — TRAP #11
;   Write a zero-terminated string to the terminal.
;   Input:   XY0 = pointer to zstring (24-bit)
;   Output:  D0 = byte count written, C=0
;   Clobbers: D0, XY0, flags
;   Preserves: D1, D2, D3, XY1, XY2, XY3
;
;   ATOMIC (DINT for byte pump duration).
;
; Phase B Step 3: at entry, caller's TF_HAS_BACKBUF is tested. If clear,
; the original fast path runs (single STOREB-per-byte to terminal). If
; set, the shell body emits each byte to the terminal (when foreground)
; AND to the caller's back-buffer.
; ============================================================================
sys_puts:
                ; --- Routing prologue ---
                ; Preserve the string ptr (XY0) across the flag test.
                PUSH    XY0, XY3

                LOADP   X0, Y3, [#MY_TCB_PTR]
                LOADI   Y0, #$00
                LOADD   D0, [XY0+#TCB_FLAGS]
                AND     D0, #TF_HAS_BACKBUF     ; Z=1 → no backbuf

                POP     XY0, XY3                ; restore string ptr; flags survive
                BNE     .sp_shell

                ; --- Fast path (non-shell, unchanged from pre-Phase B) ---
                PUSH    D1, XY3
                PUSH    XY1, XY3

                LEA     XY1, XY0
                LOADI   D1, #0

                LOADI   Y0, #TERMINAL_PAGE
                LOADI   X0, #$0000

                DINT
.sp_loop:
                LOADB   D0, [XY1]
                CMP     D0, #0
                BEQ.S   .sp_done
                STOREB  D0, [XY0]
                INC     XY1, #1
                ADD     D1, #1
                BRA     .sp_loop
.sp_done:
                LOADZ   D0, [#KERNEL_STATE]
                LOW     D0
                CMP     D0, #KERN_STATE_RUN
                BNE.S   .sp_skip_eint
                EINT
.sp_skip_eint:
                MOVE    D0, D1
                CLC
                POP     XY1, XY3
                POP     D1, XY3
                RET

.sp_shell:
                ; --- Shell path ---
                PUSH    D123, XY3
                PUSH    XY1, XY3
                PUSH    XY2, XY3

                LEA     XY2, XY0                ; XY2 = walking string ptr
                LOADI   D1, #0                  ; D1 = byte count

                ; XY1 = caller's TCB.
                LOADP   X1, Y3, [#MY_TCB_PTR]
                LOADI   Y1, #$00

                ; D3 = foreground flag (1 if caller's TID == FOREGROUND_TCB).
                LOADZ   D0, [#FOREGROUND_TCB]
                LOADD   D3, [XY1+#TCB_ID]
                CMP     D0, D3
                BNE.S   .sp_bg
                LOADI   D3, #1
                BRA.S   .sp_fg_done
.sp_bg:
                LOADI   D3, #0
.sp_fg_done:

                ; Terminal MMIO base in XY0 (used only when foreground).
                LOADI   Y0, #TERMINAL_PAGE
                LOADI   X0, #$0000

                DINT
.sp_sloop:
                LOADB   D0, [XY2]
                CMP     D0, #0
                BEQ     .sp_sdone

                ; If foreground, emit raw byte to terminal first.
                CMP     D3, #0
                BEQ.S   .sp_skip_term
                STOREB  D0, [XY0]
.sp_skip_term:
                ; Always update the back-buffer.  _BackbufPutChar clobbers
                ; D0..D3, XY0, XY2 (preserves XY1, XY3). Save what we need.
                PUSH    D1, XY3                 ; byte count
                PUSH    D3, XY3                 ; foreground flag
                PUSH    XY0, XY3                ; terminal MMIO base
                PUSH    XY2, XY3                ; walking string ptr

                CALL24  _BackbufPutChar         ; D0 = byte, XY1 = TCB

                POP     XY2, XY3
                POP     XY0, XY3
                POP     D3, XY3
                POP     D1, XY3

                INC     XY2, #1
                ADD     D1, #1
                BRA     .sp_sloop
.sp_sdone:
                LOADZ   D0, [#KERNEL_STATE]
                LOW     D0
                CMP     D0, #KERN_STATE_RUN
                BNE.S   .sp_skip_eint2
                EINT
.sp_skip_eint2:
                MOVE    D0, D1                  ; return byte count
                CLC
                POP     XY2, XY3
                POP     XY1, XY3
                POP     D123, XY3
                RET

; ============================================================================
; sys_putln — TRAP #12
;   Write zero-terminated string + LF.
;   Input:   XY0 = pointer to zstring (24-bit)
;   Output:  D0 = byte count written (incl. LF), C=0
;   Clobbers: D0, XY0, flags
;   Preserves: D1, D2, D3, XY1, XY2, XY3
;
;   ATOMIC.
;
; Phase B Step 3: same routing pattern as sys_puts; LF is treated as one
; more byte (which _BackbufPutChar interprets as "advance row").
; ============================================================================
sys_putln:
                ; --- Routing prologue ---
                PUSH    XY0, XY3

                LOADP   X0, Y3, [#MY_TCB_PTR]
                LOADI   Y0, #$00
                LOADD   D0, [XY0+#TCB_FLAGS]
                AND     D0, #TF_HAS_BACKBUF

                POP     XY0, XY3
                BNE     .pl_shell

                ; --- Fast path (non-shell, unchanged) ---
                PUSH    D1, XY3
                PUSH    XY1, XY3

                LEA     XY1, XY0
                LOADI   D1, #0

                LOADI   Y0, #TERMINAL_PAGE
                LOADI   X0, #$0000

                DINT
.pl_loop:
                LOADB   D0, [XY1]
                CMP     D0, #0
                BEQ.S   .pl_nl
                STOREB  D0, [XY0]
                INC     XY1, #1
                ADD     D1, #1
                BRA     .pl_loop
.pl_nl:
                LOADI   D0, #CH_LF
                STOREB  D0, [XY0]
                ADD     D1, #1

                LOADZ   D0, [#KERNEL_STATE]
                LOW     D0
                CMP     D0, #KERN_STATE_RUN
                BNE.S   .pl_skip_eint
                EINT
.pl_skip_eint:
                MOVE    D0, D1
                CLC
                POP     XY1, XY3
                POP     D1, XY3
                RET

.pl_shell:
                ; --- Shell path ---
                PUSH    D123, XY3
                PUSH    XY1, XY3
                PUSH    XY2, XY3

                LEA     XY2, XY0
                LOADI   D1, #0

                LOADP   X1, Y3, [#MY_TCB_PTR]
                LOADI   Y1, #$00

                LOADZ   D0, [#FOREGROUND_TCB]
                LOADD   D3, [XY1+#TCB_ID]
                CMP     D0, D3
                BNE.S   .pl_bg
                LOADI   D3, #1
                BRA.S   .pl_fg_done
.pl_bg:
                LOADI   D3, #0
.pl_fg_done:

                LOADI   Y0, #TERMINAL_PAGE
                LOADI   X0, #$0000

                DINT
.pl_sloop:
                LOADB   D0, [XY2]
                CMP     D0, #0
                BEQ     .pl_snl

                CMP     D3, #0
                BEQ.S   .pl_skip_term
                STOREB  D0, [XY0]
.pl_skip_term:
                ; Save state across _BackbufPutChar (clobbers D0..D3, XY0, XY2).
                PUSH    D1, XY3
                PUSH    D3, XY3
                PUSH    XY0, XY3
                PUSH    XY2, XY3
                CALL24  _BackbufPutChar
                POP     XY2, XY3
                POP     XY0, XY3
                POP     D3, XY3
                POP     D1, XY3

                INC     XY2, #1
                ADD     D1, #1
                BRA     .pl_sloop

.pl_snl:
                ; Trailing LF — same dual emit.
                LOADI   D0, #CH_LF

                CMP     D3, #0
                BEQ.S   .pl_skip_term_lf
                STOREB  D0, [XY0]
.pl_skip_term_lf:
                ; Same save/restore pattern (D1, D3, XY0 will all be needed
                ; for the gated-EINT cleanup below).
                PUSH    D1, XY3
                PUSH    D3, XY3
                PUSH    XY0, XY3
                CALL24  _BackbufPutChar
                POP     XY0, XY3
                POP     D3, XY3
                POP     D1, XY3
                ADD     D1, #1

                LOADZ   D0, [#KERNEL_STATE]
                LOW     D0
                CMP     D0, #KERN_STATE_RUN
                BNE.S   .pl_skip_eint2
                EINT
.pl_skip_eint2:
                MOVE    D0, D1
                CLC
                POP     XY2, XY3
                POP     XY1, XY3
                POP     D123, XY3
                RET

; ============================================================================
; sys_gets — TRAP #13
;   Read a line from the keyboard. CR ends, BS edits, others append.
;   Input:   XY0 = buffer pointer (24-bit)
;            D0  = max length (excluding null terminator)
;   Output:  D0 = actual length, C=0
;   Clobbers: D0, XY0, flags
;   Preserves: D1, D2, D3, XY1, XY2, XY3
;
;   NOT atomic — see notes at top of file.
;
; Phase B Step 4: ring reads inside sys_gets are gated by foreground
; status when the caller is a shell. The echo STOREBs are NOT routed
; through the back-buffer in v1 — typing while in the foreground draws
; straight to the terminal, and a switch-away mid-typing means the
; back-buffer stops at the most recent committed output. The line is
; recaptured into the back-buffer when sys_putln is called on result.
; Acceptable v1 trade-off; v2 may route echo through _BackbufPutChar.
; ============================================================================
sys_gets:
                PUSH    D123, XY3
                PUSH    XY1, XY3

                LEA     XY1, XY0            ; XY1 = advancing buffer ptr
                MOVE    D2, D0              ; D2 = max
                LOADI   D1, #0              ; D1 = current count
.read_loop:
                ;-- Get one keystroke (Phase B Step 4 gate).
                ;   Part 36: _GetGatedKey now preserves D1 (V2 ABI).
                ;   The PUSH/POP D1 below is therefore redundant but
                ;   kept for defensive symmetry — zero harm.
                PUSH    D1, XY3
                CALL24  _GetGatedKey            ; D0 = key byte, C=0
                POP     D1, XY3
                MOVE    D3, D0              ; D3 = key (existing convention)
                ;----------------------------------------------------------

                CMP     D3, #CH_CR
                BEQ     .got_enter
                CMP     D3, #CH_LF
                BEQ     .got_enter
                CMP     D3, #CH_BS
                BEQ.S     .got_bs

                ; Regular char — store if buffer not full
                CMP     D1, D2
                BHS     .read_loop          ; buffer full → ignore

                ; Echo via sys_putchar — routes to terminal AND back-buffer
                ; (when shell + foreground) so the back-buffer cursor stays
                ; in sync with what the terminal shows. Without this, a
                ; subsequent TRAP_PUTS would overwrite the prompt area
                ; because the back-buffer cursor didn't advance.
                MOVE    D0, D3
                CALL24  sys_putchar
                ; D1..D3 and XY1 preserved by sys_putchar's contract.

                ; Store and advance
                STOREB  D3, [XY1]
                INC     XY1, #1
                ADD     D1, #1
                BRA     .read_loop

.got_bs:
                CMP     D1, #0
                BEQ     .read_loop          ; nothing to delete

                DEC     XY1, #1
                SUB     D1, #1

                ; Echo BS / space / BS via sys_putchar so back-buffer cursor
                ; tracks (BS in back-buffer decrements col without erasing
                ; the prior cell — see _BackbufPutChar; terminal handles
                ; BS/space/BS as a destructive backspace natively).
                LOADI   D0, #CH_BS
                CALL24  sys_putchar
                LOADI   D0, #CH_SPACE
                CALL24  sys_putchar
                LOADI   D0, #CH_BS
                CALL24  sys_putchar
                BRA     .read_loop

.got_enter:
                ; Echo LF via sys_putchar — routes to terminal AND back-buffer.
                ; The back-buffer LF moves cursor to (row+1, 0), so the next
                ; prompt from kosh/BASIC lands at the start of a new row,
                ; not overlapping the previous prompt.
                LOADI   D0, #CH_LF
                CALL24  sys_putchar

                ; Null-terminate (XY1 preserved across sys_putchar).
                LOADI   D3, #CH_NUL
                STOREB  D3, [XY1]

                MOVE    D0, D1
                CLC

                POP     XY1, XY3
                POP     D123, XY3
                RET

; ============================================================================
; sys_putdec — TRAP #20
;   Write D0 as unsigned decimal, no leading zeros, 1..5 digits.
;   Input:   D0 = value (0..65535)
;   Output:  D0 = byte count written, C=0
;   Clobbers: D0, XY0, flags
;   Preserves: D1, D2, D3, XY1, XY2, XY3
;
;   Implementation: build digits in a 6-byte page-$00 buffer (5 digits +
;   safety), filling from the right, then emit left-to-right.
;
;   ATOMIC (DINT around emission to keep digit stream contiguous).
;
; Phase B Step 3: divide loop is shared. At the start of the emit phase
; we branch to fast emit or shell emit. The shell variant calls
; _BackbufPutChar for each digit and emits to terminal only when
; foreground.
; ============================================================================
sys_putdec:
                ; --- Routing test (D0 is the input value; preserve it) ---
                PUSH    D0, XY3
                LOADP   X0, Y3, [#MY_TCB_PTR]
                LOADI   Y0, #$00
                LOADD   D0, [XY0+#TCB_FLAGS]
                AND     D0, #TF_HAS_BACKBUF     ; D0 = 0 (fast) or TF_HAS_BACKBUF (shell)

                ; Stash routing decision in X0 (caller-clobber) BEFORE the
                ; callee-save PUSHes — depending on PUSH-preserving-flags is
                ; not documented in the K16 ISA, so we materialise the
                ; decision into a register we know is safe.
                MOVE    X0, D0                  ; X0 = 0 or non-zero

                POP     D0, XY3                 ; restore the input value

                PUSH    D123, XY3
                PUSH    XY1, XY3

                ; Recover routing flag from X0 into D3.
                MOVE    D3, X0                  ; D3 = 0 (fast) or non-zero (shell)
                CMP     D3, #0
                BEQ     .pd_dvbegin
                LOADI   D3, #1                  ; normalise to 0/1

.pd_dvbegin:
                MOVE    D1, D0                  ; D1 = value
                LOADI   D2, #0                  ; D2 = digit count

                DINT

                ; Build digits backward starting at PUTDEC_BUF_END-1.
                LOADI   Y0, #$00
                LOADI   X0, #PUTDEC_BUF_END

                ; Special case: value = 0 -> emit single '0'
                CMP     D1, #0
                BNE.S   .pd_div_loop

                DEC     XY0, #1
                LOADI   D0, #'0'                ; (was D3; D3 now holds routing flag)
                STOREB  D0, [XY0]
                ADD     D2, #1
                BRA     .pd_emit_dispatch

.pd_div_loop:
                CMP     D1, #0
                BEQ     .pd_emit_dispatch

                MOVE    D0, D1
                PUSH    D2, XY3
                PUSH    D3, XY3                 ; _KDiv10 trashes D2/D3
                PUSH    XY0, XY3
                CALL24  _KDiv10
                POP     XY0, XY3
                POP     D3, XY3
                POP     D2, XY3

                ADD     D1, #'0'                ; D1 was remainder
                DEC     XY0, #1
                STOREB  D1, [XY0]
                ADD     D2, #1

                MOVE    D1, D0                  ; D1 = quotient for next iter
                BRA     .pd_div_loop

.pd_emit_dispatch:
                ; XY0 points at first digit; D2 = digit count; D3 = routing flag.
                CMP     D3, #0
                BNE     .pd_shell_emit

                ; --- Fast path: copy digits to terminal MMIO ---
                LEA     XY1, XY0                ; XY1 = digit ptr
                LOADI   Y0, #TERMINAL_PAGE
                LOADI   X0, #$0000
                MOVE    D3, D2                  ; D3 = remaining count
.pd_emit_loop:
                CMP     D3, #0
                BEQ.S   .pd_emit_done
                LOADB   D1, [XY1]
                STOREB  D1, [XY0]
                INC     XY1, #1
                SUB     D3, #1
                BRA     .pd_emit_loop
.pd_emit_done:
                LOADZ   D0, [#KERNEL_STATE]
                LOW     D0
                CMP     D0, #KERN_STATE_RUN
                BNE.S   .pd_skip_eint
                EINT
.pd_skip_eint:
                MOVE    D0, D2                  ; return count
                CLC
                POP     XY1, XY3
                POP     D123, XY3
                RET

.pd_shell_emit:
                ; --- Shell path: each digit goes to back-buffer and (if fg) terminal ---
                ; XY0 = first digit ptr (page $00, X0 = PUTDEC_BUF_END - count).
                ; D2 = digit count.  D3 = 1 (we're a shell — repurposed below).
                ; Stack: D1, D2, D3, XY1 saved at entry.

                ; Stash the count in D1 (currently holds remaining-value=0;
                ; the value-divide is done).
                MOVE    D1, D2                  ; D1 = digit count (saved)

                ; XY2 = walking digit ptr.  Copy XY0 to XY2.
                LEA     XY2, XY0

                ; XY1 = caller's TCB; compute fg flag → D3.
                LOADP   X1, Y3, [#MY_TCB_PTR]
                LOADI   Y1, #$00
                LOADZ   D0, [#FOREGROUND_TCB]
                LOADD   D3, [XY1+#TCB_ID]
                CMP     D0, D3
                BNE.S   .pd_bg
                LOADI   D3, #1
                BRA.S   .pd_fg_done
.pd_bg:
                LOADI   D3, #0
.pd_fg_done:

                ; Terminal MMIO base in XY0.
                LOADI   Y0, #TERMINAL_PAGE
                LOADI   X0, #$0000

.pd_sloop:
                CMP     D2, #0
                BEQ     .pd_sdone

                LOADB   D0, [XY2]               ; D0 = digit byte

                CMP     D3, #0
                BEQ.S   .pd_skip_term
                STOREB  D0, [XY0]
.pd_skip_term:
                ; Save state across _BackbufPutChar (clobbers D0..D3, XY0, XY2).
                PUSH    D123, XY3               ; saved digit count
                PUSH    XY0, XY3                ; terminal MMIO base
                PUSH    XY2, XY3                ; walking digit ptr
                CALL24  _BackbufPutChar         ; D0 = byte, XY1 = TCB
                POP     XY2, XY3
                POP     XY0, XY3
                POP     D123, XY3

                INC     XY2, #1
                SUB     D2, #1
                BRA     .pd_sloop

.pd_sdone:
                LOADZ   D0, [#KERNEL_STATE]
                LOW     D0
                CMP     D0, #KERN_STATE_RUN
                BNE.S   .pd_skip_eint2
                EINT
.pd_skip_eint2:
                MOVE    D0, D1                  ; return original digit count
                CLC
                POP     XY1, XY3
                POP     D123, XY3
                RET

; ============================================================================
; sys_puthex — TRAP #21
;   Write D0 as 4-digit hex, leading zeros, uppercase.
;   Input:   D0 = value
;   Output:  D0 = 4 (bytes written), C=0
;   Clobbers: D0, XY0, flags
;   Preserves: D1, D2, D3, XY1, XY2, XY3
;
;   ATOMIC.
;
; Phase B Step 3: same routing pattern as the others. Fast path calls
; _PutNib (unchanged). Shell path uses _PutNibShell which writes the
; nibble to back-buffer and (if foreground) terminal.
; ============================================================================
sys_puthex:
                ; --- Routing test ---
                PUSH    D0, XY3
                LOADP   X0, Y3, [#MY_TCB_PTR]
                LOADI   Y0, #$00
                LOADD   D0, [XY0+#TCB_FLAGS]
                AND     D0, #TF_HAS_BACKBUF
                POP     D0, XY3
                BNE     .ph_shell

                ; --- Fast path (non-shell, unchanged) ---
                PUSH    D1, XY3
                PUSH    D2, XY3

                MOVE    D2, D0                  ; D2 = value (preserved across nibbles)
                LOADI   Y0, #TERMINAL_PAGE
                LOADI   X0, #$0000

                DINT

                ; nibble 3 (bits 15..12)
                MOVE    D0, D2
                HIGH    D0
                SHR4    D0
                CALL24  _PutNib

                ; nibble 2 (bits 11..8)
                MOVE    D0, D2
                HIGH    D0
                AND     D0, #$000F
                CALL24  _PutNib

                ; nibble 1 (bits 7..4)
                MOVE    D0, D2
                LOW     D0
                SHR4    D0
                CALL24  _PutNib

                ; nibble 0 (bits 3..0)
                MOVE    D0, D2
                LOW     D0
                AND     D0, #$000F
                CALL24  _PutNib

                LOADZ   D0, [#KERNEL_STATE]
                LOW     D0
                CMP     D0, #KERN_STATE_RUN
                BNE.S   .ph_skip_eint
                EINT
.ph_skip_eint:
                LOADI   D0, #4
                CLC
                POP     D2, XY3
                POP     D1, XY3
                RET

.ph_shell:
                ; --- Shell path ---
                ; D0 = value. Save callee-saves and set up shell context.
                PUSH    D123, XY3
                PUSH    XY1, XY3
                PUSH    XY2, XY3

                MOVE    D2, D0                  ; D2 = value

                ; XY1 = caller's TCB; D3 = foreground flag.
                LOADP   X1, Y3, [#MY_TCB_PTR]
                LOADI   Y1, #$00
                LOADZ   D0, [#FOREGROUND_TCB]
                LOADD   D3, [XY1+#TCB_ID]
                CMP     D0, D3
                BNE.S   .ph_bg
                LOADI   D3, #1
                BRA.S   .ph_fg_done
.ph_bg:
                LOADI   D3, #0
.ph_fg_done:

                ; XY0 = terminal MMIO base (used only when foreground).
                LOADI   Y0, #TERMINAL_PAGE
                LOADI   X0, #$0000

                DINT

                ; nibble 3
                MOVE    D0, D2
                HIGH    D0
                SHR4    D0
                CALL24  _PutNibShell

                ; nibble 2
                MOVE    D0, D2
                HIGH    D0
                AND     D0, #$000F
                CALL24  _PutNibShell

                ; nibble 1
                MOVE    D0, D2
                LOW     D0
                SHR4    D0
                CALL24  _PutNibShell

                ; nibble 0
                MOVE    D0, D2
                LOW     D0
                AND     D0, #$000F
                CALL24  _PutNibShell

                LOADZ   D0, [#KERNEL_STATE]
                LOW     D0
                CMP     D0, #KERN_STATE_RUN
                BNE.S   .ph_skip_eint2
                EINT
.ph_skip_eint2:
                LOADI   D0, #4                  ; return byte count
                CLC
                POP     XY2, XY3
                POP     XY1, XY3
                POP     D123, XY3
                RET

; --- _PutNib: write low nibble of D0 as one hex char to [Y0=DF, X0=0000] ---
; (helper for sys_puthex fast path; XY0 must already point at terminal port)
_PutNib:
                CMP     D0, #10
                BHS.S     .alpha
                ADD     D0, #'0'
                BRA.S     .emit
.alpha:
                ADD     D0, #$37            ; 'A' - 10
.emit:
                STOREB  D0, [XY0]
                RET

; --- _PutNibShell: nibble → ASCII; emit to terminal (if D3=1) AND back-buffer
;     In:  D0 = low nibble (0..15)
;          D3 = foreground flag (0 or 1)
;          XY0 = terminal MMIO base ($DF:$0000)
;          XY1 = caller's TCB ptr
;     Out: D2 = value (preserved by save/restore — sys_puthex relies on it)
;     Clobbers: D0, D1.  Preserves D2, D3, XY0, XY1, XY2, XY3.
;
;     _BackbufPutChar clobbers D0..D3 and XY0, XY2; this helper saves the
;     state sys_puthex needs across that call (D2 value, D3 fg flag, XY0).
; ----------------------------------------------------------------------------
_PutNibShell:
                CMP     D0, #10
                BHS.S   .pns_alpha
                ADD     D0, #'0'
                BRA.S   .pns_emit
.pns_alpha:
                ADD     D0, #$37
.pns_emit:
                ; D0 = ASCII char. If foreground, emit to terminal first.
                CMP     D3, #0
                BEQ.S   .pns_skip_term
                STOREB  D0, [XY0]
.pns_skip_term:
                ; Save state that _BackbufPutChar would clobber.
                PUSH    D2, XY3                 ; sys_puthex value
                PUSH    D3, XY3                 ; foreground flag
                PUSH    XY0, XY3                ; terminal MMIO base
                PUSH    XY2, XY3                ; _BackbufPutChar's scratch

                CALL24  _BackbufPutChar         ; D0 = byte, XY1 = TCB

                POP     XY2, XY3
                POP     XY0, XY3
                POP     D3, XY3
                POP     D2, XY3
                RET

; ============================================================================
; sys_clear — TRAP #22
;   Clear screen.
;   Input:   none
;   Output:  D0 = 0, C=0
;   Clobbers: D0, XY0, flags
;   Preserves: D1, D2, D3, XY1, XY2, XY3
;
;   On EMU: emit ESC[2J ESC[H (VT100)
;   On Digital: emit Form Feed ($0C) — terminal native clear
;
;   ATOMIC.
;
; Phase B Step 3: shell variant zero-fills the caller's back-buffer
; (2400 bytes), resets TCB_BACKBUF_CRSR to (0,0), and only emits the
; clear sequence to the terminal when the caller is foreground.
; Escape bytes are NOT routed through _BackbufPutChar (they'd be
; written into the buffer as visible glyphs and corrupt repaint).
; ============================================================================
sys_clear:
                ; --- Routing test (no inputs to preserve) ---
                LOADP   X0, Y3, [#MY_TCB_PTR]
                LOADI   Y0, #$00
                LOADD   D0, [XY0+#TCB_FLAGS]
                AND     D0, #TF_HAS_BACKBUF
                BNE     .cl_shell

                ; --- Fast path (non-shell, unchanged) ---
                PUSH    D1, XY3
                PUSH    D2, XY3
                PUSH    XY1, XY3

                LOADI   Y0, #TERMINAL_PAGE
                LOADI   X0, #$0000

                DINT

                LOADZ   D1, [#KOS_HOST]
                CMP     D1, #HOST_DIGITAL
                BEQ.S   .cl_digital

                ; EMU path: ESC[2J ESC[H
                LOADI   Y1, #>STR_CLEAR_VT
                LOADI   X1, #<STR_CLEAR_VT
.cl_vt_loop:
                LOADB   D2, [XY1]
                CMP     D2, #0
                BEQ.S   .cl_done
                STOREB  D2, [XY0]
                INC     XY1, #1
                BRA     .cl_vt_loop

.cl_digital:
                LOADI   D2, #$0C
                STOREB  D2, [XY0]
.cl_done:
                LOADZ   D0, [#KERNEL_STATE]
                LOW     D0
                CMP     D0, #KERN_STATE_RUN
                BNE.S   .cl_skip_eint
                EINT
.cl_skip_eint:
                LOADI   D0, #ERR_OK
                CLC
                POP     XY1, XY3
                POP     D2, XY3
                POP     D1, XY3
                RET

.cl_shell:
                ; --- Shell path ---
                ; 1. Zero-fill the caller's back-buffer (2400 bytes).
                ; 2. Reset TCB_BACKBUF_CRSR to (0,0).
                ; 3. If foreground, also emit the terminal clear sequence.

                PUSH    D123, XY3
                PUSH    XY1, XY3
                PUSH    XY2, XY3

                ; XY1 = caller's TCB.
                LOADP   X1, Y3, [#MY_TCB_PTR]
                LOADI   Y1, #$00

                ; XY2 = back-buffer base.
                LOADI   D0, #TCB_BACKBUF_OFFS
                LOADD   D0, [XY1+D0]
                MOVE    X2, D0
                LOADI   D0, #TCB_BACKBUF_PAGE
                LOADD   D0, [XY1+D0]
                MOVE    Y2, D0

                ; Zero-fill 2400 bytes at [XY2].
                LOADI   D2, #6400               ; BACKBUF_SIZE (literal — no arith in imm)
                LOADI   D0, #0
.cl_zfill:
                STOREB  D0, [XY2]
                INC     XY2, #1
                SUB     D2, #1
                BNE     .cl_zfill

                ; Reset cursor.
                LOADI   D2, #TCB_BACKBUF_CRSR
                LOADI   D0, #0
                STORED  D0, [XY1+D2]

                ; Foreground check.
                LOADZ   D0, [#FOREGROUND_TCB]
                LOADD   D3, [XY1+#TCB_ID]
                CMP     D0, D3
                BNE     .cl_shell_skip_term

                ; Foreground — emit the existing clear sequence to terminal.
                LOADI   Y0, #TERMINAL_PAGE
                LOADI   X0, #$0000

                DINT

                LOADZ   D1, [#KOS_HOST]
                CMP     D1, #HOST_DIGITAL
                BEQ.S   .cl_sh_digital

                LOADI   Y1, #>STR_CLEAR_VT
                LOADI   X1, #<STR_CLEAR_VT
.cl_sh_vt_loop:
                LOADB   D2, [XY1]
                CMP     D2, #0
                BEQ.S   .cl_sh_term_done
                STOREB  D2, [XY0]
                INC     XY1, #1
                BRA     .cl_sh_vt_loop

.cl_sh_digital:
                LOADI   D2, #$0C
                STOREB  D2, [XY0]
.cl_sh_term_done:
                LOADZ   D0, [#KERNEL_STATE]
                LOW     D0
                CMP     D0, #KERN_STATE_RUN
                BNE.S   .cl_skip_eint2
                EINT
.cl_skip_eint2:

.cl_shell_skip_term:
                LOADI   D0, #ERR_OK
                CLC
                POP     XY2, XY3
                POP     XY1, XY3
                POP     D123, XY3
                RET

STR_CLEAR_VT:   .TEXT   $1B, "[2J", $1B, "[H", 0

; ============================================================================
; sys_setcursor — TRAP #23
;   Move cursor to (row, col), 1-based.
;   Input:   D0 = row (1..24)
;            D1 = col (1..80)
;   Output:  D0 = 0, C=0
;   Clobbers: D0, XY0, flags
;   Preserves: D2, D3, XY1, XY2, XY3
;
;   On EMU: emit ESC[<row>;<col>H
;   On Digital: silent no-op
;
;   ATOMIC.
;
; Phase B Step 3: shell variant writes the new position directly into
; TCB_BACKBUF_CRSR (converting 1-based to 0-based) and only emits the
; ESC sequence to the terminal when the caller is foreground. ESC
; bytes are NOT routed through _BackbufPutChar.
; ============================================================================
sys_setcursor:
                ; --- Routing test (D0=row, D1=col are inputs; preserve both) ---
                PUSH    D0, XY3
                PUSH    D1, XY3
                LOADP   X0, Y3, [#MY_TCB_PTR]
                LOADI   Y0, #$00
                LOADD   D0, [XY0+#TCB_FLAGS]
                AND     D0, #TF_HAS_BACKBUF
                POP     D1, XY3
                POP     D0, XY3
                BNE     .sc_shell

                ; --- Fast path (non-shell, unchanged) ---
                PUSH    D2, XY3
                PUSH    D3, XY3

                LOADZ   D2, [#KOS_HOST]
                CMP     D2, #HOST_DIGITAL
                BEQ     .sc_nop

                LOADI   Y0, #TERMINAL_PAGE
                LOADI   X0, #$0000

                DINT

                LOADI   D2, #CH_ESC
                STOREB  D2, [XY0]
                LOADI   D2, #'['
                STOREB  D2, [XY0]

                CALL24  _PutDecSmall

                LOADI   D2, #';'
                STOREB  D2, [XY0]

                MOVE    D0, D1
                CALL24  _PutDecSmall

                LOADI   D2, #'H'
                STOREB  D2, [XY0]

                LOADZ   D0, [#KERNEL_STATE]
                LOW     D0
                CMP     D0, #KERN_STATE_RUN
                BNE.S   .sc_skip_eint
                EINT
.sc_skip_eint:
.sc_nop:
                LOADI   D0, #ERR_OK
                CLC
                POP     D3, XY3
                POP     D2, XY3
                RET

.sc_shell:
                ; --- Shell path ---
                ; 1. Convert (row, col) 1-based → 0-based.
                ; 2. Pack into D3 = (row<<8) | col.  Write to TCB_BACKBUF_CRSR.
                ; 3. If foreground, also emit ESC[r;cH to terminal.
                PUSH    D2, XY3
                PUSH    D3, XY3
                PUSH    XY1, XY3

                ; XY1 = caller's TCB.
                LOADP   X1, Y3, [#MY_TCB_PTR]
                LOADI   Y1, #$00

                ; Convert to 0-based, with floor at 0 (defensive: row=0 or col=0
                ; input — original ABI says 1-based, but harden against 0).
                CMP     D0, #0
                BEQ.S   .sc_row_zero
                SUB     D0, #1                  ; row -= 1
.sc_row_zero:
                CMP     D1, #0
                BEQ.S   .sc_col_zero
                SUB     D1, #1                  ; col -= 1
.sc_col_zero:

                ; Pack D3 = (row<<8) | col, with row from D0 and col from D1.
                MOVE    D3, D0
                SHL4    D3
                SHL4    D3                      ; D3 = row << 8
                OR      D3, D1                  ; D3 |= col

                ; Write to TCB_BACKBUF_CRSR.
                LOADI   D2, #TCB_BACKBUF_CRSR
                STORED  D3, [XY1+D2]

                ; Foreground check.
                LOADZ   D2, [#FOREGROUND_TCB]
                LOADD   D3, [XY1+#TCB_ID]
                CMP     D2, D3
                BNE     .sc_shell_done

                ; Foreground — emit ESC sequence to terminal.
                ; This needs the original 1-based row/col, but we just
                ; decremented them.  Re-increment for emission.
                ADD     D0, #1
                ADD     D1, #1

                ; Check host. Digital: skip terminal emit (no cursor control).
                LOADZ   D2, [#KOS_HOST]
                CMP     D2, #HOST_DIGITAL
                BEQ     .sc_shell_done

                LOADI   Y0, #TERMINAL_PAGE
                LOADI   X0, #$0000

                DINT

                LOADI   D2, #CH_ESC
                STOREB  D2, [XY0]
                LOADI   D2, #'['
                STOREB  D2, [XY0]

                CALL24  _PutDecSmall            ; D0 = row

                LOADI   D2, #';'
                STOREB  D2, [XY0]

                MOVE    D0, D1
                CALL24  _PutDecSmall            ; D0 = col

                LOADI   D2, #'H'
                STOREB  D2, [XY0]

                LOADZ   D0, [#KERNEL_STATE]
                LOW     D0
                CMP     D0, #KERN_STATE_RUN
                BNE.S   .sc_skip_eint2
                EINT
.sc_skip_eint2:

.sc_shell_done:
                LOADI   D0, #ERR_OK
                CLC
                POP     XY1, XY3
                POP     D3, XY3
                POP     D2, XY3
                RET

; --- _PutDecSmall: emit D0 (0..999) to [Y0:X0] without leading zeros -------
; (helper for sys_setcursor; XY0 = terminal port on entry)
; Clobbers D0, D2, D3.
;   D2 = digit being built
;   D3 = "have emitted any digit yet" flag (0 = no, non-zero = yes)
_PutDecSmall:
                LOADI   D3, #0          ; no digits emitted yet

                ; Hundreds
                LOADI   D2, #0
.h_loop:
                CMP     D0, #100
                BLO.S     .h_done
                SUB     D0, #100
                ADD     D2, #1
                BRA     .h_loop
.h_done:
                CMP     D2, #0
                BEQ.S     .skip_h         ; hundreds=0 -> suppress
                ADD     D2, #'0'
                STOREB  D2, [XY0]
                LOADI   D3, #1          ; we have emitted
.skip_h:

                ; Tens
                LOADI   D2, #0
.t_loop:
                CMP     D0, #10
                BLO.S     .t_done
                SUB     D0, #10
                ADD     D2, #1
                BRA     .t_loop
.t_done:
                CMP     D2, #0
                BNE.S     .emit_t         ; non-zero tens -> emit
                CMP     D3, #0
                BEQ.S     .skip_t         ; zero tens AND no prior -> suppress
.emit_t:
                ADD     D2, #'0'
                STOREB  D2, [XY0]
.skip_t:

                ; Ones (always emit; D0 is now 0..9)
                ADD     D0, #'0'
                STOREB  D0, [XY0]
                RET

; ============================================================================
; (PUTDEC_BUF and PUTDEC_BUF_END constants live in kos_defs.inc)
; ============================================================================

; ============================================================================
; _KMul16x16_32 and _KDiv10 moved to kos_klib_impl.asm (Phase 10, r11)
; ============================================================================

; ============================================================================
; End of kos_console.asm
; ============================================================================
