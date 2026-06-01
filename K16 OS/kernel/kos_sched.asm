; ============================================================================
; kos_sched.asm — k/OS round-robin scheduler (Phase 3, idle-task model)
; ============================================================================
; Date:    2 May 2026
; Status:  Phase 3 implementation
; Revision: r13 - 4 May 2026 — Branch .S polish.
;             6 unsuffixed branches converted to .S form
;             where target distance is ≤10 instructions.
;             FORWARD ONLY (assembler imm5 is unsigned 0..+31).
;             Per
;             K16 Manual Amendment 2026-05-04 E.5/E.6, default
;             auto-select picks long form; explicit .S saves
;             one word per branch. Saves 6 words.
;
; Revision: r12 - 2 May 2026 — _WakeSleepers moved here from kos_ctxsw.asm.
;             It is a scheduler-policy routine (deciding which blocked
;             tasks become runnable), not IRQ plumbing. Phase 4+ will add
;             companion routines (priority aging, quantum decrement,
;             timer-event delivery) and they all belong in this file.
;             _TimerIRQ continues to call it via CALL24 _WakeSleepers
;             between its SYS_TICKS bump and the _Schedule call.
;           r11 - 2 May 2026 — state-skip scan: walks the ready ring
;             from current.next_tcb until a TS_READY TCB is found, or
;             until we've walked back to the starting node (in which
;             case CURRENT_TCB falls back to IDLE_TCB). Required for
;             sys_exit (TS_DEAD entries) and sys_sleep (TS_BLOCKED).
;             Preserves the v3.3 Amendment 2 "two parallel return paths"
;             pattern — no shared epilogue with merge point — to stay
;             gotcha-#32-resilient.
;           r10 - 1 May 2026 — restructured _Schedule to avoid forward BRA;
;                              two independent return paths instead of fall-through.
;           r9  - 1 May 2026 — idle bootstrap support: if CURRENT_TCB ==
;                              IDLE_TCB, switch to READY_HEAD instead of
;                              following .next_tcb (idle is off-queue).
; History:  r8 - 1 May 2026 — TCB v2.1: TCB_NEXT_TCB shifted $04 → $06,
;                              symbolic offsets.
; Purpose: Scheduling policy: pick next ready TCB; transition expired
;          sleepers back to READY. Phase 2/3 has no priorities; round-
;          robin with state filtering plus tick-based wake.
;
; Called from _TimerIRQ (kos_ctxsw.asm) on the kernel stack (Y3=$00,
; X3=KERNEL_STACK_TOP+) and from sys_yield / sys_exit / sys_sleep
; (kos_task.asm) after the same pivot.
;
; Note: included from kos_boot.asm; constants from kos_defs.inc.
; ============================================================================

; ============================================================================
; _Schedule — pick next runnable task
;
;   Special case: if CURRENT_TCB == IDLE_TCB, this is the bootstrap call
;   (idle has just been preempted by the first ever timer IRQ). Start the
;   scan at READY_HEAD instead of idle.next_tcb (idle is off-queue and
;   has no meaningful next pointer).
;
;   Common case: walk the ready ring forward from current.next_tcb,
;   skipping any TCB whose state is not TS_READY. If we walk all the way
;   back to the starting node without finding a runnable task, fall back
;   to IDLE_TCB.
;
;   Properties:
;     - O(N) worst case (N = ring length); O(1) when next_tcb is ready.
;     - Two parallel return paths (.found, .none_ready) — no shared
;       epilogue or forward BRA over body, per gotcha #32 prophylaxis.
;     - Sentinel comparison is on the *starting candidate* (D2). When
;       advancing, if next == sentinel we've completed a full loop with
;       nothing runnable.
;
;   Preserves: D3, XY0, XY2, XY3
;   Clobbers:  D0, D1, D2, XY1, flags
;     (D1, D2, XY1 saved/restored locally; D0 is scratch)
; ============================================================================
_Schedule:
                PUSH    D1, XY3
                PUSH    D2, XY3
                PUSH    XY1, XY3

                LOADZ   D0, [#CURRENT_TCB]
                CMP     D0, #IDLE_TCB
                BNE.S     .from_task

                ; -- Bootstrap path: scan starts at READY_HEAD -------------
                LOADZ   D2, [#READY_HEAD]       ; D2 = sentinel (scan start)
                MOVE    D1, D2                  ; D1 = candidate
                BRA.S     .check

.from_task:
                ; -- Normal path: scan starts at current.next_tcb ----------
                MOVE    X1, D0
                LOADI   Y1, #$00
                LOADD   D2, [XY1+#TCB_NEXT_TCB] ; D2 = sentinel (scan start)
                MOVE    D1, D2                  ; D1 = candidate

.check:
                ; -- Probe candidate.state ---------------------------------
                MOVE    X1, D1
                LOADI   Y1, #$00
                LOADD   D0, [XY1+#TCB_STATE]
                CMP     D0, #TS_READY
                BEQ.S     .found

                ; -- Not READY → advance to next, check for full loop ------
                LOADD   D1, [XY1+#TCB_NEXT_TCB]
                CMP     D1, D2                  ; back to sentinel?
                BEQ.S     .none_ready
                BRA     .check

.found:
                STOREZ  D1, [#CURRENT_TCB]
                POP     XY1, XY3
                POP     D2, XY3
                POP     D1, XY3
                RET

.none_ready:
                ; -- Nothing runnable in the ring → fall back to idle ------
                LOADI   D1, #IDLE_TCB
                STOREZ  D1, [#CURRENT_TCB]
                POP     XY1, XY3
                POP     D2, XY3
                POP     D1, XY3
                RET

; ============================================================================
; _WakeSleepers — scan user TCBs, transition expired sleepers to READY
;
; Linear scan of all 32 user TCB slots (idle is never blocked). For each
; TS_BLOCKED slot, computes (SYS_TICKS - TCB_WAKE_TICK). If bit 15 of
; the difference is clear, the wake_tick has been reached (within the
; last 32768 ticks) and the task transitions to TS_READY.
;
; Wrap handling:
;   The bit-15 test correctly handles SYS_TICKS wrapping past wake_tick.
;   E.g. if a task slept setting wake_tick = $FFF0 just before SYS_TICKS
;   wrapped to $0010: $0010 - $FFF0 = $0020, bit 15 clear → wake.
;   Window is +/- 32768 ticks (~18 minutes at 30Hz). Sleeps longer
;   than that need 32-bit ticks (Phase 4+).
;
; Cost:
;   ~10-25 cycles per slot, 32 slots ≈ 640 cycles worst case. At the
;   10 MHz hardware target with a 30 Hz timer that's ~0.19% of CPU.
;
; Preserves: D, XY0, XY1 (saved/restored locally). Caller (_TimerIRQ) does
;   not depend on flags before or after, so flags are clobbered freely.
; Clobbers:  flags. (D0 and X0 used as scratch but saved on entry.)
; ============================================================================
_WakeSleepers:
                PUSH    D0, XY3
                PUSH    D123, XY3
                PUSH    XY0, XY3
                PUSH    XY1, XY3

                LOADZ   D3, [#SYS_TICKS]        ; D3 = current tick

                LOADI   D1, #USER_TCB_BASE      ; D1 = TCB scan pointer
                LOADI   D2, #USER_TCB_COUNT     ; D2 = remaining slots
                LOADI   Y1, #$00

.loop:
                MOVE    X1, D1
                LOADD   D0, [XY1+#TCB_STATE]
                CMP     D0, #TS_BLOCKED
                BNE.S     .skip

                ; Blocked. Compute (SYS_TICKS - WAKE_TICK) in D0.
                ; SUB Dn, Xn is mode 00 (per spreadsheet ADD/SUB example).
                LOADX   X0, [XY1+#TCB_WAKE_TICK]
                MOVE    D0, D3                  ; D0 = SYS_TICKS
                SUB     D0, X0                  ; D0 = SYS_TICKS - WAKE_TICK
                AND     D0, #$8000              ; bit 15 set → still sleeping
                BNE.S     .skip

                ; Wake: state = TS_READY
                LOADI   D0, #TS_READY
                STORED  D0, [XY1+#TCB_STATE]

.skip:
                ADD     D1, #TCB_SIZE           ; advance scan pointer
                SUB     D2, #1
                BNE     .loop

                POP     XY1, XY3
                POP     XY0, XY3
                POP     D123, XY3
                POP     D0, XY3
                RET

; ============================================================================
; End of kos_sched.asm
; ============================================================================
