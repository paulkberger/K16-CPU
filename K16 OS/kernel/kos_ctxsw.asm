; ============================================================================
; kos_ctxsw.asm — k/OS context switch (Phase 3, idle-task model)
; ============================================================================
; Date:    18 July 2026
; Status:  Part 30 hygiene + Phase 13 + Phase A keyboard ring + drain-loop poll
; Revision: r36 - 18 July 2026 — .restore_idle returns via a
;             synthesized-frame RTI instead of JMP24 _RestoreIdle's
;             EINT+BRA. This path is entered from a LIVE timer IRQ; on
;             Digital's 74LS148 priority hardware only RTI clears the
;             IRQ's in-service level (LVL is read-only; EINT sets IE
;             alone), so the old path masked the timer the instant the
;             system went idle at a blocked prompt — keyboard dead, CPU
;             parked in _IdleLoop. Latent since r28's _RestoreIdle path;
;             harmless while keyboard-wait was a spin (task stayed
;             runnable, standard restore RTI'd), exposed by Part 48's
;             block+park (idle now reached during a key wait). EMU gates
;             on IE only, so it never showed. Frame layout + SR value
;             ($0080 = IE=1, LVL=0, flags clear) match _BuildTask and the
;             non-leaf syscall return ABI. _RestoreIdle unchanged — boot,
;             .bc_idle, and spawn/wait idle diversions stay EINT+BRA
;             (TRAP-context, no live IRQ to unwind).
;
; Revision: r35 - 14 May 2026 — k/OS Part 30 hygiene: removed dead
;             _UnhandledIRQ stub. Was a 5-instruction "emit '?' and
;             HALT" with zero references in the codebase — all 8
;             _IRQ_VECS slots install _TimerIRQ. No behavioural change.
;
;           r34 - 14 May 2026 — SYS_TICKS extended to 32 bits.
;             After the existing low-word ADD/STOREZ, load SYS_TICKS_HI
;             (was SYS_FLAGS, renamed in kos_defs.inc r36) and ADC #0
;             to propagate the low-word carry. Three extra instructions
;             per timer IRQ. Wraps at ~4.5 years @ 30 Hz.
;             Requires kos_defs.inc r36+, kos_boot.asm r45+ (init).
;
; Revision: r33 - 14 May 2026 — _KbdTick: backpressure-aware drain.
;             r32 introduced drain-until-empty in the timer ISR to lift
;             the 30 cps paste cap. That worked but exposed a new
;             failure: the 63-byte kernel ring overflowed on any paste
;             longer than the consumer could drain in one tick, and
;             _RingPush silently drops on full. Result: ~73-char
;             truncation on BASIC paste.
;
;             r33 adds a ring-full check at the top of the drain loop.
;             If next_head == tail (ring full) the loop exits without
;             reading MMIO, leaving the byte in the producer queue (emu
;             FKeyQueue / real-silicon host buffer). Next tick the
;             consumer will have drained one or more bytes and we
;             resume. Net effect: paste is lossless and arrives as fast
;             as the consumer (sys_gets + echo via _BackbufPutChar) can
;             absorb it — no longer rate-capped by the 30 Hz tick.
;
;             Cost per iteration: 5 cycles for the full check + 3 for
;             the LOADD + ~50 for the dispatch. Hot path (no key)
;             unchanged at ~12 cycles per tick.
;
;             No defs.inc change; no ABI change; one file edit.
;             Requires kos_kbd.asm r3+ (Phase B hot-key filter is
;             called from inside the drain loop just as it was from
;             the single-read version).
;
;           r32 - 14 May 2026 — _KbdTick drain-until-empty (superseded by
;             r33). Removed the 30 cps paste cap but caused ring
;             overflow on long pastes. See r33 for the fix.
;
;           r31 - 13 May 2026 — TCB_PREEMPT_COUNT promoted to 32 bits.
;             32-bit increment via ADD low / ADC hi #0. Note: $22 is
;             outside imm5 range so the high word uses mode-01 [XY+D].
;             (Code change shipped in handover; this revision-history
;             entry back-filled in r32.)
;
; Revision: r30 - 13 May 2026 — Phase A: keyboard ring buffer.
;             Inline _KbdTick block added in _TimerIRQ between the
;             SYS_TICKS bump and the _WakeSleepers call. Reads the
;             keyboard MMIO ($DE_0000, read-clear); if non-zero,
;             CALL24 _KbdDispatch to push into the keyboard ring.
;             Hot path (no key): 16 cycles (~0.005% of 10 MHz at 30 Hz).
;             Cold path: ~50 cycles (CALL + dispatch + push).
;             The MMIO read-clear semantics mean no write-back is
;             needed — _KbdTick reads, branches on the read value, done.
;             Important: LOADD does NOT set flags (ISA: load/store/move
;             are flag-transparent). An explicit CMP D0, #0 follows the
;             LOADD before the BEQ. (Initial draft of this routine had
;             a "BEQ.S .kbd_idle" directly after LOADD on the assumption
;             LOADD set Z; this branched on stale flag state and made
;             keystrokes either drop or duplicate depending on what was
;             in C/Z/N/V from the prior SYS_TICKS path. Caught when
;             kosh saw garbage commands.)
;             This is the only edit Phase A makes to _TimerIRQ.
;             Phase B's hot-key filter slots into _KbdDispatch
;             (kdrv/kos_kbd.asm) without touching this file.
;
;           r29 - 5 May 2026 — _RestoreIdle now writes KERN_STATE_RUN to
;             KERNEL_STATE just before EINT. This promotes the kernel
;             from BOOT state to RUN state. Routines like _KDelayMs check
;             this flag to refuse cleanly when called from boot-time
;             kernel context (where timer IRQs would corrupt the bare-
;             kernel stack). First write happens on the very first idle
;             entry from boot; subsequent writes are idempotent.
;
;           r28 - 2 May 2026 — fix idle restore bug.
;             Background: when _TimerIRQ pivots to KERNEL_STACK_TOP and
;             calls _WakeSleepers / _Schedule, those calls' own stack
;             usage overwrites the IRQ-frame that _INTDispatch + _TimerIRQ
;             pushed on the kernel stack while idle was being preempted.
;             Idle's TCB_SAVED_X then points at corrupted memory. As
;             long as idle is never re-scheduled (which is the case
;             whenever at least one user task is alive), the corruption
;             is invisible. The moment a user task exits and idle is the
;             only remaining option, _Schedule picks idle and the
;             restore-incoming path RTIs through stale bytes.
;
;             Fix: idle does not need a real saved frame. A fixed
;             _IdleLoop entry point provides clean idle resumption with
;             no dependency on TCB_SAVED_X/Y. _RestoreIdle re-establishes
;             X3=KERNEL_STACK_TOP, Y3=$00, EINT, and falls into the
;             idle loop body. Every restore site (timer, yield, sleep,
;             exit, spawn, wait) detects "incoming == IDLE_TCB" and
;             diverts to _RestoreIdle instead of doing the standard
;             saved-frame restore.
;           r27 - 2 May 2026 — _WakeSleepers moved out to kos_sched.asm.
;           r26, r25, r24, r23, r22 — see git history if needed.
; ============================================================================

; (Part 30 r35 hygiene: _UnhandledIRQ removed — was a 5-instruction
;  "emit '?' and HALT #$AA" handler with zero references. All 8 IRQ
;  vector slots are installed pointing at _TimerIRQ; nothing in the
;  codebase ever pointed at _UnhandledIRQ. Reachable today only via
;  manual vector poke, which can install bad_int directly instead.)

; ============================================================================
; _INTDispatch — installed at $00:0000
; ============================================================================
_INTDispatch:

; _INTDispatch Version 1
;                PUSH    D0, XY3
;                PUSH    XY1, XY3            ; save XY1 — about to clobber for JMPT base
;
;                ; Saved SR is at [XY3+#6] now (after PUSH D0 + PUSH XY1 = 6 bytes)
;                LOADD   D0, [XY3+#6]
;                AND     D0, #$0070
;                SHR     D0
;                SHR     D0
;                SHR     D0                      ; word offset 0,2,...,14
;                LOADI   Y1, #>_IRQ_VECS
;                LOADI   X1, #<_IRQ_VECS
;                JMPT    XY1, D0

; _INTDispatch Version 2
;                PUSH    D0, XY3
;                PUSH    XY1, XY3            ; save XY1 — about to clobber for JMPT base
;
;                ; Saved SR is at [XY3+#6] (after PUSH D0 + PUSH XY1 = 6 bytes)
;                LOADD   D0, [XY3+#6]
;                AND     D0, #$0070
;                SHR4    D0                  ; bits 6:4 → bits 2:0
;                SHL     D0                  ; ×2 for word offset (0,2,...,14)
;                LOADI   Y1, #>_IRQ_VECS
;                LOADI   X1, #<_IRQ_VECS
;                JMPT    XY1, D0

; _INTDispatch Version 3 — JMPT D0 (page-$00 form, no base register)
;   *** TEMPORARILY DISABLED — boot hang under investigation (V3) ***
;   JMPT D0 reads [$00:D0] directly: no XY base to build, no XY1 to save.
;   D0 must therefore hold the full low-16 address _IRQ_VECS + level×2.
;   Only D0 is pushed now, so saved SR is at [XY3+#2].
;                PUSH    D0, XY3
;
;                LOADD   D0, [XY3+#2]        ; saved SR (only PUSH D0 = 2 bytes)
;                AND     D0, #$0070
;                SHR4    D0                  ; bits 6:4 → bits 2:0  (= level 0..7)
;                SHL     D0                  ; ×2 word offset (0,2,...,14)
;                ADD     D0, #<_IRQ_VECS     ; low-16 addr; JMPT D0 reads [$00:D0]
;                JMPT    D0

; _INTDispatch Version 2 — RESTORED (known-good, boots)
                PUSH    D0, XY3
                PUSH    XY1, XY3            ; save XY1 — about to clobber for JMPT base

                ; Saved SR is at [XY3+#6] (after PUSH D0 + PUSH XY1 = 6 bytes)
                LOADD   D0, [XY3+#6]
                AND     D0, #$0070
                SHR4    D0                  ; bits 6:4 → bits 2:0
                SHL     D0                  ; ×2 for word offset (0,2,...,14)
                LOADI   Y1, #>_IRQ_VECS
                LOADI   X1, #<_IRQ_VECS
                JMPT    XY1, D0



; ============================================================================
; _IRQ_VECS — JMPT table in ROM
; Index 0 = level 0 = IRQ7 (highest, timer); 7 = IRQ0 (lowest)
; ============================================================================
_IRQ_VECS:
                .WORD   _TimerIRQ
                .WORD   _TimerIRQ
                .WORD   _TimerIRQ
                .WORD   _TimerIRQ
                .WORD   _TimerIRQ
                .WORD   _TimerIRQ
                .WORD   _TimerIRQ
                .WORD   _TimerIRQ

; ============================================================================
; _TimerIRQ — timer handler / scheduler entry
; ============================================================================
_TimerIRQ:
                ; Restore XY1 (saved by _INTDispatch before its JMPT clobber)
                ; and D0 (saved by _INTDispatch's first PUSH).  [V2 pairing]
                POP     XY1, XY3
                POP     D0, XY3

                PUSH    D0, XY3
                PUSH    D123, XY3
                PUSH    XY0, XY3
                PUSH    XY1, XY3
                PUSH    XY2, XY3

                LOADZ   D0, [#CURRENT_TCB]
                MOVE    X1, D0
                LOADI   Y1, #$00

                ; --- Save outgoing task's stack pointer (X3) and page (Y3) ---
                MOVE    D0, X3
                STORED  D0, [XY1+#TCB_SAVED_X]
                MOVE    D0, Y3
                STORED  D0, [XY1+#TCB_SAVED_Y]

                ; --- Bump preemption counter ----------------------------------
                ; 32-bit counter spread across two non-adjacent words:
                ;   $1E = TCB_PREEMPT_COUNT     (low word, within imm5)
                ;   $22 = TCB_PREEMPT_COUNT_HI  (high word, OUTSIDE imm5
                ;                                 so needs mode-01 [XY+D])
                ; ADD on the low word sets C if it wrapped; ADC #0 then
                ; propagates that carry into the high word.  LOADD/STORED
                ; are flag-transparent, so the C from ADD survives the
                ; intervening store and the LOADI/LOADD pair below.
                ; Wraps at ~4 years @ 30Hz.
                LOADD   D0, [XY1+#TCB_PREEMPT_COUNT]
                ADD     D0, #1
                STORED  D0, [XY1+#TCB_PREEMPT_COUNT]
                ; High-word access via D-indexed mode (offset > imm5).
                LOADI   D1, #TCB_PREEMPT_COUNT_HI
                LOADD   D0, [XY1+D1]
                ADC     D0, #0
                STORED  D0, [XY1+D1]

                ; Pivot to kernel context
                LOADI   Y3, #$00
                LOADI   X3, #KERNEL_STACK_TOP

                ; --- 32-bit system tick bump (Part 30 r34, 14 May 2026) ----
                ; Low word: increment by TICK_INCREMENT, set C on wrap.
                ; High word: ADC #0 propagates C across the LOADZ
                ; (load/store/move are flag-transparent — C survives).
                ; Wraps at ~4.5 years @ 30 ticks/sec, replacing the
                ; ~36-minute wrap of the prior 16-bit counter.
                ;
                ; TICK_INCREMENT = 1 on EMU (30 Hz timer), 5 on Digital
                ; (6 Hz timer). Net 30 ticks/sec on both hosts so
                ; sys_sleep semantics match across hosts.
                ; (D1 is free here — saved by PUSH D123 above.)
                LOADZ   D0, [#SYS_TICKS]
                LOADZ   D1, [#TICK_INCREMENT]
                ADD     D0, D1
                STOREZ  D0, [#SYS_TICKS]
                LOADZ   D0, [#SYS_TICKS_HI]
                ADC     D0, #0
                STOREZ  D0, [#SYS_TICKS_HI]

                ; --- _KbdTick (Phase A inline keyboard poll) -----------------
                ; Read the keyboard MMIO. Hardware is read-clear: reading
                ; returns the key code (and clears the register) or zero
                ; if no key arrived this tick.
                ;
                ; r33 (14 May 2026): backpressure-aware drain. r32's blind
                ; drain-until-empty fixed the 30 cps cap but introduced a
                ; new failure: the kernel ring is 63 bytes and `sys_gets`
                ; consumes a byte every few hundred cycles, so a paste
                ; >63 chars would overflow the ring and `_RingPush` would
                ; silently drop bytes. The emulator's FKeyQueue already
                ; absorbs the entire paste atomically — there's no reason
                ; to flood-drain it into a smaller kernel ring. Better to
                ; leave bytes in the producer (emu FIFO / hardware register)
                ; until the kernel ring has room.
                ;
                ; r33 checks ring-full at the TOP of each iteration. If
                ; the ring is full, skip the MMIO read entirely so the
                ; byte stays in the emu's FKeyQueue. Next tick the
                ; consumer will have drained one or more bytes; we resume
                ; draining then. On real silicon (one-deep read-clear
                ; register), backpressure naturally falls back on the
                ; host's send buffer.
                ;
                ; Cost per iteration:
                ;   - Full check: 5 cycles (LOADZ + ADD + AND + LOADZ + CMP)
                ;   - MMIO read:  3 cycles (LOADD)
                ;   - Dispatch:   ~50 cycles (CALL24 _KbdDispatch)
                ; Hot path (no key): ~12 cycles per tick; trivial.
                ;
                ; NOTE: LOADD does NOT set flags (ISA: load/store/move are
                ; flag-transparent). Must follow with an explicit CMP.
                ; _KbdDispatch clobbers D0, D1, XY0, XY1 — XY0 is re-set
                ; at the top of each iteration.
.kbd_drain:
                ; Ring-full check: next_head == tail?
                LOADZ   D1, [#KBD_HEAD]
                ADD     D1, #1
                AND     D1, #KBD_RING_MASK      ; D1 = (HEAD+1) & MASK
                LOADZ   D0, [#KBD_TAIL]
                CMP     D1, D0
                BEQ.S   .kbd_idle               ; ring full — backpressure

                ; Ring has space; read MMIO.
                LOADI   Y0, #KEYBOARD_PAGE
                LOADI   X0, #$0000
                LOADD   D0, [XY0]               ; read-clear (no flag effect)
                CMP     D0, #0
                BEQ.S   .kbd_idle               ; no key — done draining
                CALL24  _KbdDispatch            ; D0 low = keystroke
                BRA     .kbd_drain              ; check for another
.kbd_idle:

                CALL24  _WakeSleepers
                CALL24  _Schedule

                ; --- Restore: idle case takes a different path ----------------
                LOADZ   D0, [#CURRENT_TCB]
                CMP     D0, #IDLE_TCB
                BEQ     .restore_idle

                ; --- Standard restore (incoming task) -------------------------
                MOVE    X1, D0
                LOADI   Y1, #$00

                LOADD   D0, [XY1+#TCB_SAVED_X]
                MOVE    X3, D0
                LOADD   D0, [XY1+#TCB_SAVED_Y]
                MOVE    Y3, D0

                POP     XY2, XY3
                POP     XY1, XY3
                POP     XY0, XY3
                POP     D123, XY3
                POP     D0, XY3

                RTI

.restore_idle:
                ; Idle is being scheduled. Its TCB_SAVED_X/Y are unreliable
                ; because the kernel stack is shared with idle's preemption
                ; frame and was overwritten by _WakeSleepers/_Schedule above.
                ; Don't touch the saved frame — go to a fresh idle entry.
                ; --- Digital timer-recurrence fix (was: JMP24 _RestoreIdle) ---
                ; This path is entered from a LIVE timer IRQ. Returning via
                ; _RestoreIdle's EINT+BRA leaves the IRQ's in-service level
                ; latched on Digital's 74LS148 priority logic (EINT sets IE
                ; only; LVL is read-only), so the timer never re-fires and
                ; the keyboard -- polled only in _KbdTick inside this IRQ --
                ; goes dead. EMU gates on IE alone, so it never showed.
                ; (Latent since r28's _RestoreIdle path; harmless while the
                ; keyboard wait was a spin -- the task stayed runnable and
                ; the standard restore RTI'd. Part 48's block+park is the
                ; first time idle is reached during a key wait, exposing it.)
                ;
                ; Fix: complete the interrupt with a real RTI. Build a fresh
                ; idle INT frame on the kernel stack and RTI through it.
                ; Push order PC[15:0], PC[23:16], SR -> SR ends on top;
                ; RTI pops SR/PC and re-enables ints from SR. Frame layout
                ; and SR value ($0080 = IE=1, LVL=0, flags clear) match
                ; _BuildTask and the non-leaf syscall return ABI. Boot,
                ; .bc_idle, and the spawn/wait idle diversions keep using
                ; _RestoreIdle (EINT+BRA) -- they are TRAP-context, no live IRQ.
                LOADI   Y3, #$00
                LOADI   X3, #KERNEL_STACK_TOP
                LOADI   D0, #KERN_STATE_RUN     ; BOOT -> RUN (idempotent)
                STOREZ  D0, [#KERNEL_STATE]
                LOADI   D0, #<_IdleLoop         ; PC[15:0]
                PUSH    D0, XY3
                LOADI   D0, #>_IdleLoop         ; PC[23:16] (page byte)
                PUSH    D0, XY3
                LOADI   D0, #$0080              ; SR: IE=1, LVL=0, flags clear
                PUSH    D0, XY3
                RTI

; ============================================================================
; _RestoreIdle — fresh idle entry (no saved-frame dependency)
;
; Called via JMP24 (not CALL24) from a NO-LIVE-IRQ restore site whose
; _Schedule result is IDLE_TCB — boot (_P2Main), _BlockCommon's .bc_idle,
; and the sys_spawn/sys_wait idle diversions. Re-establishes a clean
; kernel-stack/page state and falls into _IdleLoop. Does not return.
;
; *** CALLER CONTRACT — do NOT route a live-IRQ path through here. ***
; This entry finishes with EINT + fall-through to _IdleLoop, NOT RTI. That
; is correct only when no interrupt is in service. A path reached from
; inside a hardware IRQ (e.g. _TimerIRQ's .restore_idle) MUST instead
; return via RTI, so the IRQ's in-service level clears on real priority
; hardware (74LS148): EINT sets IE but cannot lower LVL (read-only). Using
; this EINT+BRA form from a live IRQ masks that IRQ forever on Digital
; (invisible on EMU, which gates on IE alone). See .restore_idle (r36) for
; the synthesized-frame RTI pattern to use from IRQ context.
;
; Why this is needed: idle's TCB_SAVED_X points at the kernel stack region
; which gets clobbered by _WakeSleepers and _Schedule themselves. Reading
; it back via POP/RTI yields garbage. The only safe way to resume idle is
; to re-construct its execution context from scratch.
;
; Side effects:
;   X3 := KERNEL_STACK_TOP
;   Y3 := $00 (kernel page)
;   IE := 1 (EINT — must allow timer to schedule away if anything wakes)
;   Falls through to _IdleLoop
; ============================================================================
_RestoreIdle:
                LOADI   X3, #KERNEL_STACK_TOP
                LOADI   Y3, #$00
                ; Promote KERNEL_STATE: BOOT → RUN. Idempotent — every
                ; subsequent task→idle restore writes the same value.
                ; Safe to do before EINT (interrupts still masked here).
                LOADI   D0, #KERN_STATE_RUN
                STOREZ  D0, [#KERNEL_STATE]
                EINT
                ; fall through to _IdleLoop

; ============================================================================
; _IdleLoop — kernel idle loop
;
; Single canonical idle entry point. Boot's _P2Main JMP24's here after
; building the first task; _RestoreIdle JMP24's here from restore sites
; when no user task is runnable.
;
; Halts the CPU implicitly via tight branch — timer IRQ will preempt and
; _Schedule may or may not pick a real task next. If no real task ever
; appears, the system idles here forever, which is correct.
; ============================================================================
_IdleLoop:
                BRA     _IdleLoop

; ============================================================================
; End of kos_ctxsw.asm
; ============================================================================
