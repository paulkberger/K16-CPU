; ============================================================================
; kos_kbd.asm — k/OS keyboard ring driver
; ============================================================================
; Date:    14 May 2026
; Status:  Part 30 r37 hygiene + Phase A keyboard ring + Phase B Step 6 + 6b.
; Revision: r4 — 14 May 2026. k/OS Part 30 hygiene: Ctrl-digit range
;               check now uses KEY_CTRL_DIGIT_FIRST/LAST from kos_defs.inc
;               instead of literal $81/$8B. Same encoded value, named
;               constants bring the defs entries into actual use.
;               Also: rewrote the _KbdDispatch header comment block —
;               the "TODO Step 6b" / "no shell switch happens" notes
;               were stale (Step 6b landed in r3, direct-index switch
;               via _SwitchForegroundByIndex is live).
;               Requires kos_defs.inc r37+.
;
;           r3 — 13 May 2026. Phase B Step 6b — Ctrl-digit direct-index.
;               $81..$8A (Ctrl-1..0 on EMU) now call _SwitchForegroundByIndex
;               in kos_switcher.asm r5+. Index = key - $80, so $81 → 1
;               (first registered shell, normally kosh), $8A → 10.
;               Out-of-range indices and missing anchor are silent no-ops.
;               $0E (Ctrl-N) and $10 (Ctrl-P) handling unchanged from r2.
;
;           r2 — 13 May 2026. Phase B Step 6 hot-key filter.
;               _KbdDispatch's previously empty body now intercepts
;               Ctrl-N ($0E) → _SwitchForegroundNext and Ctrl-P ($10) →
;               _SwitchForegroundPrev before they reach the ring. Also
;               swallows Ctrl-digit range $81..$8A so EMU-only direct-
;               index keys don't pollute the ring; direct-index switch
;               itself is a Step 6b TODO.  All other bytes fall through
;               to _RingPush unchanged.
;
;           r1 — 13 May 2026. Initial.
;               Four routines:
;                 _KbdDispatch  — policy seam (Phase A: empty, falls through
;                                 to _RingPush; Phase B: prepended hot-key
;                                 filter goes here)
;                 _RingPush     — mechanism: SPSC producer
;                 _RingPop      — mechanism: SPSC consumer (C=1 if empty)
;                 _RingWaitPop  — convenience: spin-pop wrapper
;
; Architecture:
;
;     MMIO @ $DE_0000 (read-clear)
;             |
;             v
;       _KbdTick (inline in _TimerIRQ; reads MMIO; CALL24s _KbdDispatch
;                 on non-zero)
;             |
;             v
;       _KbdDispatch  ◄── policy (Phase A: fall-through; Phase B: hot-key filter)
;             |
;             v
;       _RingPush     ◄── mechanism (unconditional push; silent drop if full)
;             |
;          [ring at KBD_RING_BUF, 64 bytes]
;             |
;             v
;       _RingPop      ◄── mechanism (C=1 on empty)
;             ^
;             |
;       _RingWaitPop  ◄── used by sys_getchar
;
; Ring invariants:
;   Empty: KBD_HEAD == KBD_TAIL
;   Full:  ((KBD_HEAD + 1) AND KBD_RING_MASK) == KBD_TAIL
;   Capacity: 63 bytes
;
; Return convention (kernel-internal flag ABI):
;   _RingPop:     C=0 → D0 holds the popped byte
;                 C=1 → ring was empty; D0 unspecified
;   _RingPush:    no flag return (silent overrun drop)
;   _RingWaitPop: C=0, D0 = byte (always — spins until non-empty)
;
; SPSC safety:
;   Producer (_RingPush) writes KBD_HEAD only, reads KBD_TAIL only.
;   Consumer (_RingPop) writes KBD_TAIL only, reads KBD_HEAD only.
;   LOADZ/STOREZ are atomic per CPU contract.
;   Hardware DINT in the ISR means the producer is non-reentrant.
;   No locks needed.
;
; Note: included from kos_boot.asm after kdrv/kos_console.asm.
;       Constants come from kos_defs.inc.
; ============================================================================


; ----------------------------------------------------------------------------
; _KbdDispatch — keystroke policy filter
;   Input:    D0 low = received key byte (high byte already zero from MMIO)
;   Output:   none
;   Clobbers: D0, D1, XY0, XY1
;   Preserves: D2, D3, XY2, XY3
;   Context:  kernel stack (Y3=$00), called from _TimerIRQ via CALL24.
;
;   Phase A: no filter — fell straight through into _RingPush.
;
;   Phase B Step 6: hot-key filter. Recognised switcher keys are consumed
;   (not pushed to the ring); they trigger a foreground switch directly.
;   All other keys fall through to _RingPush unchanged.
;
;   Recognised (Step 6 + 6b — all live):
;     $0E (Ctrl-N / Ctrl-RightArrow on EMU)   → _SwitchForegroundNext
;     $10 (Ctrl-P / Ctrl-LeftArrow on EMU)    → _SwitchForegroundPrev
;     $81..$8A (Ctrl-1..0 on EMU, EMU-only)   → _SwitchForegroundByIndex
;                                                 (index = key - $80,
;                                                  1..10; out-of-range
;                                                  silently no-ops in
;                                                  the switcher helper)
;
;   The _SwitchForeground{Next,Prev,ByIndex} helpers themselves clobber
;   D0..D3, XY0..XY2 — wider than _KbdDispatch's contract. We save the
;   contract regs around the call.
; ----------------------------------------------------------------------------
_KbdDispatch:
                ; --- Hot-key dispatch ------------------------------------
                ; Mask any junk in the high byte. The MMIO read uses LOADD
                ; (16-bit) into D0 even though the keyboard register is
                ; 8-bit; the upper byte is unspecified on some hosts.
                ; Without this LOW, a non-zero high byte would prevent the
                ; CMP/BEQ chain from matching the low-byte key code.
                LOW     D0

                CMP     D0, #KEY_CTRL_N
                BEQ     .kd_next
                CMP     D0, #KEY_CTRL_P
                BEQ     .kd_prev

                ; Ctrl-digit range KEY_CTRL_1 ($81) .. KEY_CTRL_0 ($8A)
                ; → switch by index (1..10). Part 30 r37 hygiene: was
                ; literals $81/$8B; now uses the named constants from
                ; kos_defs.inc.
                CMP     D0, #KEY_CTRL_DIGIT_FIRST
                BLO     _RingPush               ; below range → fall through
                CMP     D0, #KEY_CTRL_DIGIT_LAST+1
                BHS     _RingPush               ; above range → fall through

                ; Index = key - $80.  D0 holds key.
                SUB     D0, #$80
                PUSH    D2, XY3
                PUSH    D3, XY3
                PUSH    XY2, XY3
                CALL24  _SwitchForegroundByIndex
                POP     XY2, XY3
                POP     D3, XY3
                POP     D2, XY3
                RET

.kd_next:
                ; Save callee-preserve regs (per _KbdDispatch's contract)
                ; that _SwitchForegroundNext will clobber.
                PUSH    D2, XY3
                PUSH    D3, XY3
                PUSH    XY2, XY3
                CALL24  _SwitchForegroundNext
                POP     XY2, XY3
                POP     D3, XY3
                POP     D2, XY3
                RET

.kd_prev:
                PUSH    D2, XY3
                PUSH    D3, XY3
                PUSH    XY2, XY3
                CALL24  _SwitchForegroundPrev
                POP     XY2, XY3
                POP     D3, XY3
                POP     D2, XY3
                RET

; ----------------------------------------------------------------------------
; _RingPush — unconditional producer
;   Input:    D0 low = byte to push (high byte zero by convention)
;   Output:   none — no flag return; overrun is silent
;   Clobbers: D0, D1, XY0, XY1
;   Preserves: D2, D3, XY2, XY3
;   Context:  kernel stack (Y3=$00).
; ----------------------------------------------------------------------------
_RingPush:
                LOW     D0                  ; ensure key byte in low only

                ; Compute next head; check against tail for full
                LOADZ   D1, [#KBD_HEAD]
                ADD     D1, #1
                AND     D1, #KBD_RING_MASK  ; D1 = next head
                LOADZ   X0, [#KBD_TAIL]
                CMP     D1, X0
                BEQ     .full               ; next == tail → ring full (plain: spans store + wake)

                ; Store byte at current head: XY1 = $00:KBD_RING_BUF + head
                LOADZ   X1, [#KBD_HEAD]
                LOADI   Y1, #$00
                ADD     X1, #KBD_RING_BUF
                STOREB  D0, [XY1]

                ; Commit new head (already in D1)
                STOREZ  D1, [#KBD_HEAD]

                ; --- Wake the parked reader, if one is registered ----------
                ; Single waiter (foreground gate guarantees one consumer).
                ; O(1) — one known TCB, no scan. Runs in timer-IRQ context
                ; (IE=0), so the TS_READY store is atomic w.r.t. _Schedule.
                ; The byte stays in the ring; the woken reader re-polls and
                ; retrieves it (SPSC, single consumer — no D0 patch needed).
                ; Ring-full path skips this: a waiter can only park when the
                ; ring is EMPTY, and is woken on the first push — so "full
                ; with a waiter parked" cannot arise.
                LOADZ   D1, [#KBD_WAITER_TCB]
                CMP     D1, #0
                BEQ.S   .full                   ; no waiter
                MOVE    X1, D1
                LOADI   Y1, #$00
                LOADI   D0, #TS_READY
                STORED  D0, [XY1+#TCB_STATE]     ; mark runnable
                LOADI   D0, #0
                STOREZ  D0, [#KBD_WAITER_TCB]    ; consume the registration
.full:
                RET


; ----------------------------------------------------------------------------
; _RingPop — non-blocking consumer
;   Input:    none
;   Output:   if non-empty: D0 = byte (zero-extended), C = 0
;             if empty:     D0 unspecified,            C = 1
;   Clobbers: D0, D1, XY0 (only on the non-empty path)
;   Preserves: D2, D3, XY1, XY2, XY3
;
;   Used by _RingWaitPop and by any future non-blocking reader.
; ----------------------------------------------------------------------------
_RingPop:
                LOADZ   D0, [#KBD_HEAD]
                LOADZ   D1, [#KBD_TAIL]
                CMP     D0, D1
                BEQ.S   .empty              ; HEAD == TAIL → empty

                ; Non-empty: D0 ← ring[TAIL]. Build XY0 = $00:KBD_RING_BUF,
                ; index by D1 (the tail) using LOADB Mode 01 [XYn+Dm].
                LOADI   Y0, #$00
                LOADI   X0, #KBD_RING_BUF
                LOADB   D0, [XY0+D1]        ; D0 = byte (zero-extended)

                ; Advance tail (in D1) and commit
                ADD     D1, #1
                AND     D1, #KBD_RING_MASK
                STOREZ  D1, [#KBD_TAIL]

                RETCC
.empty:
                RETCS


; ----------------------------------------------------------------------------
; _RingWaitPop — blocking consumer
;   Input:    none
;   Output:   D0 = byte (zero-extended), C = 0
;   Clobbers: D0, D1, XY0
;
;   Polls _RingPop; on an empty ring it parks via _WaitInput (the task is
;   marked TS_BLOCKED_ON_INPUT and yields the CPU until _RingPush wakes it),
;   then re-polls. Worst-case keystroke->return latency is one tick.
;
;   NOT a leaf (Part 48): calls _WaitInput, which DINTs, builds an
;   INT-compatible frame, and reschedules. SPSC-safe (single consumer).
; ----------------------------------------------------------------------------
_RingWaitPop:
                CALL24  _RingPop
                BCC.S   .rwp_got                ; got a byte
                CALL24  _WaitInput              ; empty → park until woken
                BRA     _RingWaitPop            ; re-poll
.rwp_got:
                RETCC                           ; D0 = byte, C=0


; ============================================================================
; _BlockCommon — generic kernel-context block/yield (Part 48)
;
;   Suspends the current task and reschedules, building the same
;   INT-compatible frame that sys_yield / sys_sleep / _TimerIRQ use — so a
;   task parked here is restored interchangeably by ANY scheduler path
;   (the timer's RTI included). This is what makes a timer-IRQ wake
;   (_RingPush) safe; the coroutine _SemBlockYield frame is NOT timer-safe
;   and must never be used for an IRQ-woken waiter.
;
;   Entry contract (reached by BRA from a head routine, never called):
;     - Stack: [SR][resume_PC]  (SR pushed by the head; resume_PC is the
;       head's CALL return — i.e. the caller re-polls/re-gates on wake).
;     - Interrupts DISABLED (head DINTed to close the wake race).
;     - D0 = target TCB_STATE (TS_BLOCKED_ON_INPUT to truly block;
;       TS_READY to yield the slice and stay runnable).
;     - Any waiter registration (e.g. KBD_WAITER_TCB) already done.
;
;   On wake (some scheduler marks this task TS_READY and selects it), the
;   restoring path pops this frame and RTIs to resume_PC with all caller
;   registers and IE restored from the saved SR.
;
;   Mirrors sys_yield's body exactly, parameterised by the target state.
; ============================================================================
_BlockCommon:
                ; Complete the INT frame on top of [SR][resume_PC].
                ; Push order matches _TimerIRQ: D0, D123, XY0, XY1, XY2.
                ; The D0 slot carries the state value here; it is irrelevant
                ; on resume because the caller re-checks (re-polls/re-gates).
                PUSH    D0, XY3                 ; frame D0 (= state; junk on resume)
                PUSH    D123, XY3               ; frame D1/D2/D3 (caller's)
                PUSH    XY0, XY3                ; frame XY0 (caller's)
                PUSH    XY1, XY3                ; frame XY1 (caller's)
                PUSH    XY2, XY3                ; frame XY2 (caller's)

                ; Locate self TCB (D0 still = target state).
                LOADZ   D1, [#CURRENT_TCB]
                MOVE    X1, D1
                LOADI   Y1, #$00
                STORED  D0, [XY1+#TCB_STATE]    ; state := target

                ; Save outgoing X3 / Y3.
                MOVE    D0, X3
                STORED  D0, [XY1+#TCB_SAVED_X]
                MOVE    D0, Y3
                STORED  D0, [XY1+#TCB_SAVED_Y]

                ; Pivot to kernel context and reschedule.
                LOADI   Y3, #$00
                LOADI   X3, #KERNEL_STACK_TOP
                CALL24  _Schedule

                ; --- Restore incoming task (idle gets fresh-entry) ---------
                LOADZ   D0, [#CURRENT_TCB]
                CMP     D0, #IDLE_TCB
                BEQ     .bc_idle

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

                RTI                             ; pops resume_PC + SR (IE restored)

.bc_idle:
                JMP24   _RestoreIdle


; ----------------------------------------------------------------------------
; _WaitInput — park the current task until a keyboard byte is available.
;   Called (CALL24) by _RingWaitPop and _GetGatedKey on an empty ring.
;   In:    none
;   Out:   returns (RET) only on the fast path (a byte appeared during the
;          race-closing recheck): C=0, D0 = byte. Otherwise the task blocks
;          and, on wake, control resumes at the caller's instruction after
;          the CALL24 (the caller re-polls).
;   Clobbers: D0, D1, XY0 (matches _RingPop; block path restores via frame).
; ----------------------------------------------------------------------------
_WaitInput:
                PUSH    SR, XY3                 ; capture caller IE (=1); frame base
                DINT                            ; close the wake race vs _RingPush
                CALL24  _RingPop                ; recheck under DINT
                BCS     .wi_block               ; still empty → park

                ; A byte appeared between the caller's poll and our DINT.
                ; D0 = byte, C=0. Drop the saved SR, re-enable IE (gated),
                ; and return it to the caller.
                POP     SR, XY3                 ; discard (POP SR doesn't restore IE)
                PUSH    D0, XY3                 ; preserve byte across the EINT gate
                LOADZ   D0, [#KERNEL_STATE]
                LOW     D0
                CMP     D0, #KERN_STATE_RUN
                BNE.S   .wi_no_eint
                EINT
.wi_no_eint:
                POP     D0, XY3                 ; restore byte
                CLC                             ; success
                RET

.wi_block:
                ; Register as the single keyboard waiter, then block. On wake
                ; (_RingPush set us TS_READY), control resumes at the caller's
                ; post-CALL24 instruction; the byte waits in the ring.
                ; Store the TCB POINTER (page-$00 offset), not the TID —
                ; _RingPush uses it directly as XY1 for the TCB_STATE store.
                LOADZ   D0, [#CURRENT_TCB]      ; D0 = self TCB pointer
                STOREZ  D0, [#KBD_WAITER_TCB]
                LOADI   D0, #TS_BLOCKED_ON_INPUT
                BRA     _BlockCommon


; ----------------------------------------------------------------------------
; _YieldKernel — give up the rest of the slice from kernel context.
;   Called (CALL24) by _GetGatedKey when a backgrounded shell is waiting to
;   become foreground (it waits on focus, not on a key, so it must NOT block
;   on the ring — it yields and re-gates each round). The task stays
;   TS_READY; the scheduler brings it back, and on resume control returns to
;   the caller's post-CALL24 instruction. True focus-block is deferred (it
;   needs the Phase-4 multi-shell input arbitration).
;   In:    none
;   Out:   returns (via the scheduler) to the caller's post-CALL24 point.
;   Clobbers: nothing observable (all regs restored via frame on resume).
; ----------------------------------------------------------------------------
_YieldKernel:
                PUSH    SR, XY3                 ; capture caller IE (=1); frame base
                DINT
                LOADI   D0, #TS_READY           ; stay runnable — pure yield
                BRA     _BlockCommon


; ----------------------------------------------------------------------------
; _KbdReleaseWaiter — hand off the keyboard when foreground changes.
;
;   Called (CALL24) right after any FOREGROUND_TCB change (focus switch or
;   shell exit). If a task is parked on the ring, wake it (so it re-gates and
;   steps aside via _YieldKernel when it finds it is no longer foreground)
;   and clear KBD_WAITER_TCB. Without this, the old foreground stays
;   TS_BLOCKED_ON_INPUT and the new foreground's _WaitInput overwrites
;   KBD_WAITER_TCB, orphaning the old reader forever (dead keyboard).
;
;   Wakes ONLY if the parked task is genuinely TS_BLOCKED_ON_INPUT; if it has
;   since changed state (e.g. exiting → TS_DEAD), it just clears the stale
;   registration without reviving it. Maintains the invariant: the only
;   TS_BLOCKED_ON_INPUT task is the current KBD_WAITER.
;
;   Clobbers: flags only (D0/D1/XY1 saved/restored).
; ----------------------------------------------------------------------------
_KbdReleaseWaiter:
                PUSH    D0, XY3
                PUSH    D1, XY3
                PUSH    XY1, XY3
                LOADZ   D1, [#KBD_WAITER_TCB]
                CMP     D1, #0
                BEQ.S   .krw_done               ; nobody parked
                MOVE    X1, D1
                LOADI   Y1, #$00
                LOADD   D0, [XY1+#TCB_STATE]
                CMP     D0, #TS_BLOCKED_ON_INPUT
                BNE.S   .krw_clear              ; not blocked-on-input → don't revive
                LOADI   D0, #TS_READY
                STORED  D0, [XY1+#TCB_STATE]    ; wake → it re-gates and yields
.krw_clear:
                LOADI   D0, #0
                STOREZ  D0, [#KBD_WAITER_TCB]   ; drop the stale registration
.krw_done:
                POP     XY1, XY3
                POP     D1, XY3
                POP     D0, XY3
                RET


; ============================================================================
; End of kos_kbd.asm
; ============================================================================
