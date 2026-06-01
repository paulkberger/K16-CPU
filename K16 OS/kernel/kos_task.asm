; ============================================================================
; kos_task.asm — k/OS Phase 3 task control syscalls
; ============================================================================
; Date:    14 May 2026
; Status:  Part 31 r18 — refactored. _ReapDeadTask is single source of truth
;          for shell death; sys_exit and _HandleDeadTCB no longer have their
;          own hand-back hooks.
; Revision: r18 — 14 May 2026 — Part 31 refactor.
;             Companion to kos_tcb.asm r21. The earlier r17 fix used three
;             separate sites (sys_exit, _HandleDeadTCB, _ReapDeadTask) to
;             handle shell death, which was duplicative. Refactor:
;             (a) sys_exit drops its hand-back hook entirely; the no-waiter
;                 path now branches on TF_HAS_BACKBUF -- shells eager-reap
;                 (so _ReapDeadTask does the unlink/handback/repaint/free
;                 atomically), non-shells keep the lazy-reap policy. The
;                 two sub-paths share a clean orphan/schedule/RTI tail.
;             (b) _HandleDeadTCB drops its hand-back hook; the single
;                 _ReapDeadTask call at the end now handles everything.
;             Requires kos_tcb.asm r21+ (which preserves D0..D3/XY0..XY2
;             across _ReapDeadTask so D3 = self.TID survives the call,
;             and adds the foreground retarget + _RepaintFromBackbuf inline).
;             Net: ~60 lines removed; one logical place to look when asking
;             "what happens when a shell dies".
;
; Revision: r17 — 14 May 2026 — Part 31: foreground hand-back on shell exit
;             + sys_kill reaps already-dead corpses.
;             (a) sys_exit and _HandleDeadTCB both now detect "victim is
;             foreground shell" (TF_HAS_BACKBUF set AND FOREGROUND_TCB ==
;             victim.TID) and call _SwitchForegroundNext before reap.
;             Without this, when a registered shell exits (BASIC's BYE,
;             Forth v2.25's BYE, any future shell-mode .COM with an exit
;             command), FOREGROUND_TCB kept pointing at the dead TCB and
;             the user saw a frozen back-buffer until they manually pressed
;             Ctrl-N. The hook gates strictly so kosh's own exit path (it
;             can't really exit anyway under TF_SYSCRITICAL from r16) and
;             non-shell task exits are zero-overhead.
;             (b) sys_kill now reaps an already-TS_DEAD victim instead of
;             returning ERR_NOTFOUND. Permission checks still apply; the
;             original TCB_EXIT_CODE is preserved. Closes the case where
;             a backgrounded shell self-exits (no waiter, lazy-reap leaves
;             corpse) and the user's natural `kill N` was being refused.
;             Both hooks run inside existing DINT windows; foreground
;             hand-back reloads XY1, D3, D2 from the TCB since
;             _SwitchForegroundNext clobbers D0..D3/XY0..XY2.
;
; Revision: r16 — 12 May 2026 — Part 28: TF_SYSCRITICAL check in sys_kill.
;             Before the existing permission (TF_PRIV) check, sys_kill
;             now reads victim's TCB_FLAGS and rejects with ERR_PERM if
;             TF_SYSCRITICAL is set. The check is absolute — even a
;             TF_PRIV caller is refused. This closes the case where a
;             future second privileged task could kill kosh and leave
;             the system shellless. The existing victim==caller refusal
;             still protects kosh from sys_kill'ing itself directly.
;             Requires kos_defs.inc r32+ (TF_SYSCRITICAL constant).
;
; Revision: r15 — 12 May 2026 — Part 20: video-mode auto-release on
;             task death. _HandleDeadTCB now calls _VideoForceReset(TID)
;             before orphaning children, so if the dying task owned the
;             VID_MODE register, the screen is force-reset to text mode
;             and ownership cleared. sys_exit does the same for self
;             (in the common pre-branch path, before either with-waiter
;             or no-waiter route).
;             Requires kos_defs.inc r30+ (VIDEO_OWNER_TID slot) and
;             kos_video.asm r1+ (_VideoForceReset).
;
; Revision: r14 — 12 May 2026 — Part 20: sys_kill (TRAP #32) + reaper sweep.
;             New non-context-switching syscall. Marks a victim TCB
;             TS_DEAD with KILL_EXIT_CODE, then calls _HandleDeadTCB
;             helper to finalise (orphan kids, deliver to waiter if
;             any, reap). Then sweeps the entire user-TCB pool and
;             runs _HandleDeadTCB on every other TS_DEAD slot — this
;             opportunistically cleans up backgrounded tasks that
;             self-exited without a parent waiter. ~600 cycles of
;             sweep overhead per kill — invisible.
;             New helper: _HandleDeadTCB(X1:Y1=victim) bundles the
;             waiter-find / deliver / wake / orphan / reap dance.
;             Does NOT call _Schedule — the caller resumes after TRAP.
;             Structurally a DINT-gated leaf syscall (PUSH SR / EINT
;             gate at exit on KERNEL_STATE == RUN), matching the
;             sys_exec / sys_format template.
;             Permission model: caller is privileged (TF_PRIV in
;             TCB_FLAGS) → may kill anyone. Else: victim must be
;             caller's child (victim.TCB_PARENT_ID == caller.TID).
;             Else: ERR_PERM.
;             v1 limitation: refuses to kill TS_SEMWAIT victims with
;             ERR_BUSY (sem-queue unlink not yet implemented).
;             Other states (READY, BLOCKED, WAITING) all kill cleanly.
;             Requires kos_defs.inc r29+ (TF_PRIV, KILL_EXIT_CODE,
;             ERR_PERM, ERR_BUSY); _TidToTcb, _FindWaiterFor,
;             _OrphanChildren, _DeliverWaitResult (kos_spawn.asm);
;             _ReapDeadTask (kos_tcb.asm).
;
; Revision: r13 - 4 May 2026 — Branch .S polish.
;             1 unsuffixed branches converted to .S form
;             where target distance is ≤10 instructions.
;             FORWARD ONLY (assembler imm5 is unsigned 0..+31).
;             Per
;             K16 Manual Amendment 2026-05-04 E.5/E.6, default
;             auto-select picks long form; explicit .S saves
;             one word per branch. Saves 1 words.
;
; Revision: r12 - 2 May 2026 — Part 8 idle-restore fix.
;             sys_yield, sys_exit (both paths), and sys_sleep now check
;             whether the incoming TCB is IDLE_TCB and JMP24 to
;             _RestoreIdle (in kos_ctxsw.asm r28+) when it is. This
;             avoids reading idle's TCB_SAVED_X/Y, which are unreliable
;             because the kernel stack is shared with idle's IRQ-saved
;             frame and gets clobbered by _WakeSleepers/_Schedule.
;             Symptom of the bug pre-fix: after the only user task calls
;             sys_exit, _Schedule picks idle, restore-incoming RTIs
;             through stale stack bytes, system crashes. Repro: Part 8
;             console smoke `quit` command on EMU resets (RTI lands at
;             reset vector); on Digital halts at $0028 with garbage
;             "HALT $7E" because RTI lands inside the vector table.
;             Requires kos_ctxsw.asm r28+ for _RestoreIdle.
;
;           r11 - 2 May 2026 — Part 7: sys_exit extended for sys_spawn/wait
;             cooperation. After marking self TS_DEAD and storing exit
;             code, sys_exit now:
;               1. Calls _FindWaiterFor(self.TID). If a waiter exists:
;                  a. _DeliverWaitResult(waiter_tcb, exit_code)
;                     — pokes our exit code into waiter's saved-D0
;                       stack slot and clears C in waiter's saved SR.
;                  b. Marks waiter TS_READY and clears its TCB_WAIT_ID.
;                  c. Calls _ReapDeadTask on self — eager reap when a
;                     waiter exists, since the result is now in flight.
;               2. Calls _OrphanChildren(self.TID) — clears
;                  TCB_PARENT_ID of any of our still-living children.
;             Without a waiter, sys_exit's behaviour is unchanged from
;             r10: leave self TS_DEAD in the ring (lazy-reap policy)
;             and proceed to schedule.
;             Requires kos_defs.inc r14+, kos_tcb.asm r14+, kos_spawn.asm r1+.
;
;           r10 - 2 May 2026 — added sys_exit (TRAP #16) and sys_sleep
;             (TRAP #17). Both are non-leaf syscalls following the
;             canonical PUSH SR / DINT / body / RTI template established
;             by sys_yield (r8). sys_exit marks TS_DEAD, stores exit code,
;             never returns. sys_sleep marks TS_BLOCKED with TCB_WAKE_TICK
;             = SYS_TICKS + ticks; _WakeSleepers (kos_sched.asm r12) wakes
;             the task when the tick is reached. sys_sleep with D0=0 has
;             a leaf-style early return for the no-op case.
;             Requires kos_defs.inc r13+ (TCB_WAKE_TICK, VEC_EXIT, VEC_SLEEP),
;             kos_tcb.asm r13+ (TCB_WAKE_TICK zeroed in init/build),
;             kos_sched.asm r11+ (state-skip scan), kos_ctxsw.asm r26+
;             (_WakeSleepers + integration).
;           r9 - 2 May 2026 — sys_yield increments TCB_YIELD_COUNT for the
;             outgoing task (between save of X3/Y3 and kernel pivot).
;             Requires kos_defs.inc r10+ and kos_tcb.asm r11+.
;           r8 - 2 May 2026 — sys_yield now DINTs after PUSH SR. The
;             previous r7 left IE=1 throughout, allowing the timer IRQ to
;             fire DURING _Schedule. If timer fired between _Schedule's
;             update of CURRENT_TCB and sys_yield's TCB restore, the timer
;             would save kernel-context X3/Y3 to the INCOMING task's TCB,
;             corrupting it. Symptom: PC into NOP land after thousands of
;             yields. Yield-once narrowing test passed because window was
;             rare with so few yields. Fix: DINT after PUSH SR (so saved
;             SR has IE=1); RTI re-enables atomically on resume.
;           r7 - 2 May 2026 — sys_yield self-contained body.
;           r6 - 2 May 2026 — sys_yield uses PUSH SR.
;           r5 - 2 May 2026 — TLS_SCRATCH0 dance to preserve D0.
;           r4 - 2 May 2026 — PUSHI (didn't exist).
;           r3 - 2 May 2026 — sys_yield with shared _SchedEntry.
;           r2 - 2 May 2026 — sys_getpid uses task-local TASK_ID slot.
;           r1 - 2 May 2026 — initial; sys_getpid via CURRENT_TCB indirect.
;
; Purpose: TRAP handlers for task control (Part 20 numbering):
;            TRAP #25  sys_getpid   — return current task's TCB_ID    [LEAF]
;            TRAP #26  sys_yield    — voluntary preemption        [NON-LEAF]
;            TRAP #27  sys_exit     — terminate current task      [NON-LEAF]
;            TRAP #28  sys_sleep    — sleep N timer ticks         [NON-LEAF]
;            TRAP #32  sys_kill     — terminate another task by TID
;                                     [DINT-gated leaf, no resched]
;
; --- Leaf vs non-leaf syscalls ----------------------------------------------
;
; LEAF syscalls return to the calling task. Plain RET pops the TRAP-pushed
; PC and resumes the caller. Caller's Y3/X3 are unchanged. Examples:
; sys_getpid, sys_putchar.
;
; NON-LEAF syscalls may return to a DIFFERENT task. They synthesise an
; INT-shaped frame on entry (TRAP-pushed PC + an explicit PUSH SR), do the
; full save-schedule-restore dance, and emerge via RTI.
;
; To work around gotcha #32 (forward branch over body to shared epilogue
; fails when called repeatedly in IRQ-context), each non-leaf syscall
; carries its own complete copy of the dispatch body. _TimerIRQ has its
; own copy in kos_ctxsw.asm. Code duplication is the prescribed workaround.
;
; --- Stack frame after the standard non-leaf prologue ----------------------
;
; PUSH SR  (1 word) / PUSH D (4 words: D0,D1,D2,D3 in stack order, D3 on
; top) / PUSH XY0 (X0 then Y0; Y0 on top) / PUSH XY1 / PUSH XY2.
; Stack layout from top-of-stack ([XY3+0]) downward:
;
;   [XY3+0]   = Y2          (top, last pushed)
;   [XY3+2]   = X2
;   [XY3+4]   = Y1
;   [XY3+6]   = X1
;   [XY3+8]   = Y0
;   [XY3+10]  = X0
;   [XY3+12]  = D3
;   [XY3+14]  = D2
;   [XY3+16]  = D1
;   [XY3+18]  = D0          <-- caller's D0 (first syscall arg)
;   [XY3+20]  = SR
;
; Syscalls that need the caller's D0 after the prologue read it from
; [XY3+#18]. Within IMM5 range so encodes as one word.
;
; Note: included from kos_boot.asm; constants from kos_defs.inc.
; ============================================================================

; ============================================================================
; sys_getpid — TRAP #14   [LEAF]
;   Return the calling task's TCB_ID (1..32 for user tasks, 0 = idle).
;   Input:   none
;   Output:  D0 = task id, C=0
;   Clobbers: D0, flags
;   Preserves: D1, D2, D3, XY0, XY1, XY2, XY3
; ============================================================================
sys_getpid:
                LOADP   D0, Y3, [#TASK_ID]      ; D0 ← [primary:$0004]
                RETCC

; ============================================================================
; sys_yield — TRAP #15   [NON-LEAF]
;   Voluntarily release the CPU. The scheduler picks another runnable task.
;   The calling task remains TS_READY and will be scheduled in again on a
;   future round.
;
;   Input:   none
;   Output:  none (when this task is rescheduled, control resumes after TRAP)
;   Clobbers: nothing — full register state and flags preserved across the
;             yield via PUSH SR / RTI machinery.
;
;   See r8 history note above for why DINT after PUSH SR is mandatory.
; ============================================================================
sys_yield:
                ; -- Capture real SR, completing the TRAP→INT frame --------
                PUSH    SR, XY3
                
                ; -- Disable interrupts for the kernel work ----------------
                ; CRITICAL: prevents timer IRQ from firing during _Schedule
                ; or the TCB save/restore.
                DINT
                
                ; -- Save outgoing task's volatile registers ---------------
                PUSH    D0, XY3
                PUSH    D123, XY3
                PUSH    XY0, XY3
                PUSH    XY1, XY3
                PUSH    XY2, XY3
                
                ; -- Locate outgoing TCB -----------------------------------
                LOADZ   D0, [#CURRENT_TCB]
                MOVE    X1, D0
                LOADI   Y1, #$00
                
                ; -- Save outgoing X3 and Y3 -------------------------------
                MOVE    D0, X3
                STORED  D0, [XY1+#TCB_SAVED_X]
                MOVE    D0, Y3                  ; D0 = $00xx (zero-extended)
                STORED  D0, [XY1+#TCB_SAVED_Y]
                
                ; -- Bump yield counter (16-bit, wraps every ~98s) ---------
                LOADD   D0, [XY1+#TCB_YIELD_COUNT]
                ADD     D0, #1
                STORED  D0, [XY1+#TCB_YIELD_COUNT]
                
                ; -- Pivot to kernel context -------------------------------
                LOADI   Y3, #$00
                LOADI   X3, #KERNEL_STACK_TOP
                
                ; -- Schedule (no SYS_TICKS bump — yields aren't time) -----
                CALL24  _Schedule
                
                ; -- Locate incoming TCB; idle gets fresh-entry treatment --
                LOADZ   D0, [#CURRENT_TCB]
                CMP     D0, #IDLE_TCB
                BEQ     .yield_to_idle

                MOVE    X1, D0
                LOADI   Y1, #$00
                
                ; -- Restore incoming X3 and Y3 ----------------------------
                LOADD   D0, [XY1+#TCB_SAVED_X]
                MOVE    X3, D0
                LOADD   D0, [XY1+#TCB_SAVED_Y]
                MOVE    Y3, D0
                
                ; -- Restore incoming task's volatile registers ------------
                POP     XY2, XY3
                POP     XY1, XY3
                POP     XY0, XY3
                POP     D123, XY3
                POP     D0, XY3
                
                ; RTI pops PC + SR atomically; SR has IE=1 from PUSH SR.
                RTI

.yield_to_idle:
                JMP24   _RestoreIdle

; ============================================================================
; sys_exit — TRAP #16   [NON-LEAF]
;   Terminate the calling task. NEVER RETURNS to the caller.
;
;   Input:   D0 = exit code (16-bit)
;   Output:  none — does not return.
;
;   Behaviour (Part 31 — r18, refactored):
;     1. Mark self TS_DEAD; store exit code in TCB_EXIT_CODE.
;     2. Auto-release VID_MODE if self owns it (_VideoForceReset).
;     3. _FindWaiterFor(self.TID).
;        If a waiter exists  (with-waiter path):
;          - _DeliverWaitResult(waiter, exit_code) → poke waiter's saved-D0
;            and clear C in saved SR.
;          - waiter.TCB_STATE := TS_READY ; waiter.TCB_WAIT_ID := 0.
;          - _ReapDeadTask(self) — eager reap. If self was a registered
;            shell, this also unlinks the shell ring, retargets
;            FOREGROUND_TCB to the successor, repaints, and frees the
;            back-buffer (kos_tcb.asm r21+).
;          - _OrphanChildren(self.TID).
;        If no waiter:
;          - If self is a shell (TF_HAS_BACKBUF): _ReapDeadTask(self) as
;            above, then CURRENT_TCB := IDLE_TCB so _Schedule bootstraps
;            from READY_HEAD instead of our reaped slot.
;          - Else (non-shell lazy-reap): stay TS_DEAD in ring; _Schedule's
;            state-skip scan makes us invisible. TCB_EXIT_CODE is preserved
;            indefinitely in case a long-lost parent calls sys_wait.
;          - _OrphanChildren(self.TID).
;     4. Pivot to kernel, _Schedule, restore incoming, RTI.
;
;   Single source of truth: every consequence of a registered shell dying
;   (shell-ring unlink, foreground hand-back, repaint, back-buffer free)
;   is implemented exactly once -- inside _ReapDeadTask. sys_exit just
;   decides "reap now or later" based on TF_HAS_BACKBUF + waiter presence.
; ============================================================================
sys_exit:
                ; -- Capture real SR, completing the TRAP→INT frame --------
                PUSH    SR, XY3
                DINT
                
                PUSH    D0, XY3                 ; D0 (exit code) preserved on stack
                PUSH    D123, XY3
                PUSH    XY0, XY3
                PUSH    XY1, XY3
                PUSH    XY2, XY3
                
                ; -- Locate self TCB --------------------------------------
                LOADZ   D0, [#CURRENT_TCB]
                MOVE    X1, D0
                LOADI   Y1, #$00
                
                ; -- Recover caller's D0 (= exit code) from saved-D group --
                LOADD   D2, [XY3+#18]           ; D2 = exit code
                
                ; -- Mark dead, store exit code ----------------------------
                LOADI   D0, #TS_DEAD
                STORED  D0, [XY1+#TCB_STATE]
                STORED  D2, [XY1+#TCB_EXIT_CODE]
                
                ; -- Read self.TID into D3 --------------------------------
                LOADD   D3, [XY1+#TCB_ID]
                
                ; -- Auto-release video mode if self owns it (Part 20) ----
                MOVE    D0, D3
                CALL24  _VideoForceReset        ; clobbers D1/XY0 only
                
                ; -- Look for a waiter ------------------------------------
                MOVE    D0, D3                  ; D0 = self.TID
                CALL24  _FindWaiterFor
                BCC     .with_waiter            ; C=0 ⇒ waiter found

                ; -- No waiter. Two sub-paths, sharing a common tail:
                ;
                ;   Shell-eager:  TF_HAS_BACKBUF set. _ReapDeadTask runs so
                ;                 the shell ring is unlinked, foreground is
                ;                 handed back, the new fg's back-buffer is
                ;                 repainted, and our buffer is freed.
                ;
                ;   Lazy-reap:    TF_HAS_BACKBUF clear. Stay TS_DEAD in the
                ;                 ring; _Schedule's state-skip scan makes
                ;                 us invisible. The lingering TCB preserves
                ;                 exit_code for a future sys_wait.
                ;
                ; _FindWaiterFor clobbered XY1 -- reload from CURRENT_TCB
                ; so the TF_HAS_BACKBUF check reads OUR TCB, not whatever
                ; _FindWaiterFor's scan left in XY1.
                LOADZ   D0, [#CURRENT_TCB]
                MOVE    X1, D0
                LOADI   Y1, #$00

                ; _ReapDeadTask now preserves D0..D3/XY0..XY2 (PUSH/POP at
                ; entry/exit) so D3 = self.TID survives across the call --
                ; we don't need to reorder OrphanChildren or stash anything.
                LOADD   D0, [XY1+#TCB_FLAGS]
                AND     D0, #TF_HAS_BACKBUF
                BEQ     .exit_post_reap         ; non-shell: skip reap

                ; Shell-eager: reap self. XY1 = self TCB.
                CALL24  _ReapDeadTask
                ; CURRENT_TCB now points at a TS_UNUSED slot. Reset to IDLE
                ; so _Schedule scans from READY_HEAD rather than the stale
                ; CURRENT_TCB.next.
                LOADI   D0, #IDLE_TCB
                STOREZ  D0, [#CURRENT_TCB]

.exit_post_reap:
                ; --- Shared tail: orphan / schedule / restore / RTI -------
                MOVE    D0, D3                  ; D0 = self.TID
                CALL24  _OrphanChildren

                LOADI   Y3, #$00
                LOADI   X3, #KERNEL_STACK_TOP
                CALL24  _Schedule

                LOADZ   D0, [#CURRENT_TCB]
                CMP     D0, #IDLE_TCB
                BEQ     .exit_nw_to_idle

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
                RTI                              ; ===== no-waiter ENDS =====

.exit_nw_to_idle:
                JMP24   _RestoreIdle

.with_waiter:
                ; ============= WITH-WAITER PATH (self-contained body) =====
                ; Waiter found at X1:Y1. Deliver result, wake waiter,
                ; eager-reap self, orphan kids, pivot, schedule, RTI.
                MOVE    X2, X1
                LOADI   Y2, #$00
                
                ; Deliver result to waiter's saved-D0 / saved-SR
                MOVE    D0, D2                  ; D0 = exit code
                CALL24  _DeliverWaitResult      ; preserves X1:Y1
                
                ; Transition waiter to TS_READY, clear TCB_WAIT_ID
                LOADI   D0, #TS_READY
                STORED  D0, [XY2+#TCB_STATE]
                LOADI   D0, #0
                STORED  D0, [XY2+#TCB_WAIT_ID]
                
                ; Eager-reap self
                LOADZ   D0, [#CURRENT_TCB]
                MOVE    X1, D0
                LOADI   Y1, #$00
                CALL24  _ReapDeadTask
                
                ; CURRENT_TCB now points at reaped (TS_UNUSED, next=0)
                ; TCB. Reset to IDLE_TCB so _Schedule's bootstrap path
                ; scans from READY_HEAD instead of CURRENT_TCB.next.
                LOADI   D0, #IDLE_TCB
                STOREZ  D0, [#CURRENT_TCB]
                
                ; Orphan our children
                MOVE    D0, D3                  ; D0 = self.TID
                CALL24  _OrphanChildren
                
                LOADI   Y3, #$00
                LOADI   X3, #KERNEL_STACK_TOP
                CALL24  _Schedule
                
                LOADZ   D0, [#CURRENT_TCB]
                CMP     D0, #IDLE_TCB
                BEQ     .exit_ww_to_idle

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
                RTI                              ; ===== with-waiter ENDS =====

.exit_ww_to_idle:
                JMP24   _RestoreIdle

; ============================================================================
; sys_sleep — TRAP #17   [NON-LEAF]
;   Block calling task for D0 timer ticks. Marks TCB_STATE = TS_BLOCKED
;   and TCB_WAKE_TICK = SYS_TICKS + D0. _WakeSleepers (in _TimerIRQ)
;   transitions the task back to TS_READY when SYS_TICKS reaches the
;   wake target. _Schedule skips TS_BLOCKED entries.
;
;   Input:   D0 = ticks to sleep (16-bit unsigned)
;            D0 = 0 → immediate return (no scheduling overhead)
;   Output:  D0 undefined on resume (no result).
;            C = 0 in both cases (success).
;
;   Granularity is one timer tick (~33ms at 30Hz). Maximum sleep is 32767
;   ticks (~18 minutes at 30Hz) due to the half-cycle wake comparison
;   in _WakeSleepers.
;
;   Note: CMP D0, #0 leaves C=1 (no borrow on equal). Without the explicit
;   CLC before the early RET, the leaf-style return would signal "error"
;   to the syscall ABI. CLC sets C=0 = success.
; ============================================================================
sys_sleep:
                ; -- D0 == 0? leaf-style early exit ------------------------
                CMP     D0, #0
                BNE.S     .doSleep
                RETCC

.doSleep:
                ; -- Capture real SR, completing the TRAP→INT frame --------
                PUSH    SR, XY3
                DINT
                
                PUSH    D0, XY3                 ; D0 (ticks) preserved on stack
                PUSH    D123, XY3
                PUSH    XY0, XY3
                PUSH    XY1, XY3
                PUSH    XY2, XY3
                
                ; -- Locate outgoing TCB -----------------------------------
                LOADZ   D0, [#CURRENT_TCB]
                MOVE    X1, D0
                LOADI   Y1, #$00
                
                ; -- Save outgoing X3/Y3 (task WILL resume) ----------------
                MOVE    D0, X3
                STORED  D0, [XY1+#TCB_SAVED_X]
                MOVE    D0, Y3
                STORED  D0, [XY1+#TCB_SAVED_Y]
                
                ; -- Bump yield counter (sys_sleep also yields the CPU) ----
                LOADD   D0, [XY1+#TCB_YIELD_COUNT]
                ADD     D0, #1
                STORED  D0, [XY1+#TCB_YIELD_COUNT]
                
                ; -- Recover caller's D0 (= ticks) from saved-D group ------
                LOADD   D2, [XY3+#18]           ; D2 = ticks
                
                ; -- Compute wake_tick = SYS_TICKS + ticks -----------------
                LOADZ   D0, [#SYS_TICKS]
                ADD     D0, D2
                STORED  D0, [XY1+#TCB_WAKE_TICK]
                
                ; -- Mark TCB blocked --------------------------------------
                LOADI   D0, #TS_BLOCKED
                STORED  D0, [XY1+#TCB_STATE]
                
                ; -- Pivot to kernel context -------------------------------
                LOADI   Y3, #$00
                LOADI   X3, #KERNEL_STACK_TOP
                
                ; -- Schedule (our TCB is now TS_BLOCKED, will be skipped) -
                CALL24  _Schedule
                
                ; -- Resume here when _WakeSleepers transitions us READY ---
                
                ; -- Restore incoming task ---------------------------------
                LOADZ   D0, [#CURRENT_TCB]
                CMP     D0, #IDLE_TCB
                BEQ     .sleep_to_idle

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

.sleep_to_idle:
                JMP24   _RestoreIdle

; ============================================================================
; _HandleDeadTCB — finalise a TS_DEAD TCB.
;
;   Input:    X1:Y1 = TCB ptr (already in TS_DEAD; TCB_EXIT_CODE set).
;   Output:   none meaningful. C, flags clobbered.
;   Clobbers: D0..D3, X0..X2, Y0..Y2 — caller saves anything it cares about.
;
;   Steps performed:
;     1. Read victim TID from TCB.
;     2. Orphan victim's children (TCB_PARENT_ID == tid → 0).
;     3. _FindWaiterFor(tid). If a TS_WAITING parent exists:
;          a. _DeliverWaitResult(waiter, victim.TCB_EXIT_CODE) — poke
;             the parent's saved-D0 slot and clear C in saved SR.
;          b. waiter.TCB_STATE := TS_READY; waiter.TCB_WAIT_ID := 0.
;     4. _ReapDeadTask(victim) — unlink from ring, mark TS_UNUSED.
;
;   Idempotent across already-orphaned children and already-cleared
;   waiter fields. Safe to invoke on any TS_DEAD TCB regardless of how
;   it died (sys_exit, sys_kill, etc.) provided exit_code is set.
;
;   Must be called with DINT in effect (touches another task's stack
;   in the deliver-wait-result step).
; ============================================================================
_HandleDeadTCB:
                PUSH    D2, XY3
                PUSH    XY2, XY3

                ; -- Stash victim TCB ptr in XY2 ------------------------------
                MOVE    X2, X1
                LOADI   Y2, #$00

                ; -- Read victim TID ------------------------------------------
                LOADD   D2, [XY2+#TCB_ID]               ; D2 = victim TID

                ; -- Auto-release video mode if victim owns it (Part 20) ------
                MOVE    D0, D2
                CALL24  _VideoForceReset

                ; -- Orphan victim's children ---------------------------------
                MOVE    D0, D2
                CALL24  _OrphanChildren                 ; preserves D0

                ; -- Look for a parent waiter ---------------------------------
                MOVE    D0, D2
                CALL24  _FindWaiterFor                  ; X1:Y1=waiter, C=0=found
                BCS     .hd_no_waiter

                ; -- Waiter exists: deliver victim's exit_code ----------------
                LOADD   D0, [XY2+#TCB_EXIT_CODE]
                CALL24  _DeliverWaitResult              ; preserves X1:Y1, D0

                ; waiter.TCB_STATE := TS_READY ; waiter.TCB_WAIT_ID := 0
                LOADI   D0, #TS_READY
                STORED  D0, [XY1+#TCB_STATE]
                LOADI   D0, #0
                STORED  D0, [XY1+#TCB_WAIT_ID]

.hd_no_waiter:
                ; -- Reap victim ---------------------------------------------
                ; _ReapDeadTask (kos_tcb.asm r21+) is the single source of
                ; truth for shell death: it unlinks the shell ring, retargets
                ; FOREGROUND_TCB to the successor, calls _RepaintFromBackbuf,
                ; frees the back-buffer, AND unlinks the ready ring + marks
                ; TS_UNUSED -- all in one call. No separate hand-back hook
                ; needed here.
                MOVE    X1, X2
                LOADI   Y1, #$00
                CALL24  _ReapDeadTask

                POP     XY2, XY3
                POP     D2, XY3
                RET

; ============================================================================
; sys_kill — TRAP #32                                          [DINT-gated]
;
; Terminate another task by TID, AND opportunistically reap any other
; TS_DEAD corpses still on the ring. Does NOT context-switch — caller
; resumes after the TRAP.
;
; As of Part 31 (14 May 2026), an already-dead victim is reapable rather
; than refused: `kill N` against a TS_DEAD corpse now runs the same
; permission check as a live kill and (on permission) routes the corpse
; through _HandleDeadTCB. The original TCB_EXIT_CODE is preserved (not
; overwritten with KILL_EXIT_CODE) so the cause of death stays
; informative. Closes the case where a background-launched shell exits
; via BYE but its TCB lingers as TS_DEAD because no parent sys_wait
; reaped it.
;
;   Input:    D0 = victim TID
;   Output:   D0 = 0 on success, ERR_* on failure
;             C  = 0 success, 1 error
;   Errors:   ERR_INVALID   victim TID is 0, or victim TID == caller TID
;                            (use sys_exit to terminate self)
;             ERR_NOTFOUND  no task with that TID at all (TS_UNUSED slot)
;             ERR_PERM      caller is not privileged and victim is not
;                            caller's child (applies to live AND dead
;                            victims), OR victim is TF_SYSCRITICAL
;             ERR_BUSY      victim is TS_SEMWAIT — sem-queue unlink not
;                            yet implemented (v1 limitation)
;   Preserves: D2, D3, XY2 (V2 ABI)
;
; Concurrency: DINT/EINT-gated. While the body runs, no other task or IRQ
; can mutate the TCB pool or ready ring. EINT only if KERNEL_STATE == RUN
; (boot-context safety, same gate as sys_exec / sys_format).
;
; Structurally: leaf syscall with internal critical section. Does not
; PUSH SR / RTI like the canonical non-leaf template — sys_kill never
; reschedules. Returns to caller via plain RET.
;
; Side effects on success:
;   Live victim path:
;     victim.TCB_STATE       := TS_DEAD
;     victim.TCB_EXIT_CODE   := KILL_EXIT_CODE ($FFFF)
;     _HandleDeadTCB(victim) — orphan kids, deliver to waiter (if any), reap
;   Already-dead victim path:
;     victim.TCB_STATE / TCB_EXIT_CODE — unchanged (preserve original)
;     _HandleDeadTCB(victim) — same reaping path
;   In both cases:
;     For each OTHER TS_DEAD TCB in the pool: _HandleDeadTCB(it).
;     The sweep catches backgrounded tasks that self-exited without a
;     parent waiter, plus anything else that piled up. The "kill" call
;     is the natural opportunity for cleanup — it's already a privileged,
;     explicit, destructive op and adding ~600 cycles for a pool sweep
;     is invisible.
;
; Notes:
;   - If victim is currently sleeping (TS_BLOCKED), the transition to
;     TS_DEAD is silent — _WakeSleepers only inspects TS_BLOCKED rows.
;   - If victim is TS_WAITING (in a sys_wait of its own), its waiter-id
;     bookkeeping becomes moot once we mark it dead.
; ============================================================================
sys_kill:
                DINT

                ; -- V2 ABI callee-saves ---------------------------------------
                ; Part 36 (expanded V2 ABI): XY1 now callee-preserved.
                ; The body uses X1:Y1 freely as a TCB-walk register, so we
                ; save the caller's XY1 at entry and restore at exit.
                ; D1 is already untouched by the body (EINT gate uses D2).
                PUSH    D2, XY3
                PUSH    D3, XY3
                PUSH    XY1, XY3                    ; Part 36: V2 ABI
                PUSH    XY2, XY3

                ; -- Validate: victim != 0 (would be idle) ---------------------
                CMP     D0, #0
                BEQ     .sk_invalid

                ; -- Validate: victim != self ---------------------------------
                ; Read caller's TID from CURRENT_TCB.TCB_ID.
                LOADZ   D2, [#CURRENT_TCB]
                MOVE    X1, D2
                LOADI   Y1, #$00
                LOADD   D2, [XY1+#TCB_ID]           ; D2 = caller TID
                CMP     D0, D2
                BEQ     .sk_invalid

                ; -- Resolve victim TID → TCB ptr -----------------------------
                ; _TidToTcb returns X1:Y1 = victim TCB, C=0; or C=1 on bad TID
                ; (out of range or TS_UNUSED). It clobbers D0 on failure but
                ; preserves on success.
                CALL24  _TidToTcb
                BCS     .sk_notfound

                ; -- Save victim TCB ptr in XY2 (D2/D3/XY2 are saved) ---------
                MOVE    X2, X1
                LOADI   Y2, #$00

                ; -- Detect TS_DEAD victim ------------------------------------
                ; Pre-Part-31: returned ERR_NOTFOUND. As of Part 31 (14 May
                ; 2026), an already-dead victim is reapable — fall through
                ; permission checks below, then jump straight to the sweep
                ; (which reaps via _HandleDeadTCB). User intent of "kill 2"
                ; against a corpse is unambiguously "make it go away".
                ;
                ; D3 = 1 if victim already dead (skip the live-kill commit
                ; block and head straight to the sweep), else 0.
                LOADD   D2, [XY2+#TCB_STATE]
                LOADI   D3, #0
                CMP     D2, #TS_DEAD
                BNE     .sk_not_dead
                LOADI   D3, #1
.sk_not_dead:

                ; -- Refuse if victim is TS_SEMWAIT (v1 limitation) -----------
                CMP     D2, #TS_SEMWAIT
                BEQ     .sk_busy

                ; -- Refuse if victim is TF_SYSCRITICAL (Part 28) -------------
                ; Absolute — no caller, however privileged, may kill a
                ; syscritical task. Closes the kill-kosh hole and any
                ; future "kill the init shim" / "kill the logger" case.
                LOADD   D2, [XY2+#TCB_FLAGS]
                AND     D2, #TF_SYSCRITICAL
                BNE     .sk_perm                    ; reuse ERR_PERM exit

                ; -- Permission check -----------------------------------------
                ; caller_priv := CURRENT_TCB.TCB_FLAGS & TF_PRIV
                LOADZ   D2, [#CURRENT_TCB]
                MOVE    X1, D2
                LOADI   Y1, #$00
                LOADD   D2, [XY1+#TCB_FLAGS]
                AND     D2, #TF_PRIV
                BNE     .sk_perm_ok                 ; privileged caller

                ; Non-privileged: victim must be caller's child.
                ; victim.TCB_PARENT_ID == caller.TID ?
                LOADD   D2, [XY2+#TCB_PARENT_ID]    ; victim's parent
                LOADD   D0, [XY1+#TCB_ID]           ; caller's TID (D3 holds dead-flag)
                CMP     D2, D0
                BNE     .sk_perm

.sk_perm_ok:
                ; -- Already-dead path: skip the mark-as-dead block, go ------
                ; straight to _HandleDeadTCB which reaps. The victim already
                ; has TCB_STATE = TS_DEAD and a TCB_EXIT_CODE from whatever
                ; killed it originally (sys_exit, prior sys_kill). We do NOT
                ; overwrite the exit code — the original is more informative.
                CMP     D3, #1
                BEQ     .sk_finalize

                ; -- All checks passed. Commit the kill -----------------------

                ; victim.TCB_STATE := TS_DEAD
                LOADI   D2, #TS_DEAD
                STORED  D2, [XY2+#TCB_STATE]

                ; victim.TCB_EXIT_CODE := KILL_EXIT_CODE ($FFFF)
                LOADI   D2, #KILL_EXIT_CODE
                STORED  D2, [XY2+#TCB_EXIT_CODE]

.sk_finalize:
                ; -- Finalise the victim via the shared helper ---------------
                MOVE    X1, X2
                LOADI   Y1, #$00
                CALL24  _HandleDeadTCB

                ; -- Sweep: clean up any other TS_DEAD corpses ---------------
                ; Walk the user TCB pool. For each TS_DEAD slot, run the
                ; same helper. (The just-killed victim is now TS_UNUSED so
                ; the scan naturally skips it; same for any TCB that was
                ; already TS_UNUSED.)
                LOADI   X2, #USER_TCB_BASE
                LOADI   Y2, #$00
                LOADI   D2, #USER_TCB_COUNT
.sk_sweep:
                LOADD   D3, [XY2+#TCB_STATE]
                CMP     D3, #TS_DEAD
                BNE.S   .sk_sweep_next

                ; Found a corpse. Hand to helper (which reaps via
                ; _ReapDeadTask, marking TS_UNUSED so we won't re-process).
                MOVE    X1, X2
                LOADI   Y1, #$00
                CALL24  _HandleDeadTCB

.sk_sweep_next:
                ADD     X2, #TCB_SIZE
                SUB     D2, #1
                BNE     .sk_sweep

.sk_success:
                LOADI   D0, #0
                CLC
                BRA     .sk_done

.sk_invalid:    LOADI   D0, #ERR_INVALID
                SEC
                BRA     .sk_done
.sk_notfound:   LOADI   D0, #ERR_NOTFOUND
                SEC
                BRA     .sk_done
.sk_perm:       LOADI   D0, #ERR_PERM
                SEC
                BRA     .sk_done
.sk_busy:       LOADI   D0, #ERR_BUSY
                SEC

.sk_done:
                ; -- Gated EINT (only if scheduler is live) -------------------
                ; Same template as sys_exec/sys_format. PUSH SR / EINT /
                ; POP SR; POP doesn't disturb flags so the C-bit result
                ; survives. POPs of callee-saved regs are also flag-clean.
                PUSH    SR, XY3
                LOADZ   D2, [#KERNEL_STATE]
                LOW     D2
                CMP     D2, #KERN_STATE_RUN
                BNE.S   .sk_skip_eint
                EINT
.sk_skip_eint:
                POP     SR, XY3

                POP     XY2, XY3
                POP     XY1, XY3                    ; Part 36: V2 ABI
                POP     D3, XY3
                POP     D2, XY3
                RET

; ============================================================================
; End of kos_task.asm
; ============================================================================
