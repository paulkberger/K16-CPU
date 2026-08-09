; ============================================================================
; kos_tcb.asm — k/OS TCB management (Phase 3, TCB v2.4, idle-task model)
; ============================================================================
; Date:    28 June 2026
; Status:  Part 50 — _InitTCBPool zeroes foreground/shell anchors at boot.
; Revision: r25 — 28 June 2026 — Part 50: _InitTCBPool now also zeroes
;               FOREGROUND_TCB and FIRST_SHELL_TID. These globals live outside
;               the TCB pool, so the TS_UNUSED sweep never cleared them; on a
;               reset that leaves RAM intact (hardware reset line / b-reset /
;               warm WebEMU boot) a stale FOREGROUND_TCB from a prior foreground
;               task (esp. a Part 49 graphics task) pointed sys_register_shell
;               at a now-dead TID, so the freshly-spawned kosh spliced against a
;               ghost and hung at "Loading k/OS shell ...". Two STOREZ in the
;               scheduler-globals clear block. Boot is now correct regardless of
;               prior RAM contents.
; Revision: r24 — 28 June 2026 — Part 50: reap unlink treats next = 0 as a lone
;               shell (clear globals) and refuses to walk any sub-pool link
;               (< USER_TCB_BASE), closing the DATA FAULT $00014F path.
; Revision: r23 — 28 June 2026 — Part 49: graphics-task reap. _ReapDeadTask's
;             ring-unlink entry guard broadened TF_HAS_BACKBUF -> TF_FOCUSABLE,
;             so a dying graphics task (TF_GRAPHICS, no back-buffer) is unlinked
;             from the foreground ring and hands the foreground back exactly as
;             a shell does. The back-buffer free is already guarded by a
;             zero-offset skip, so a graphics task frees nothing. The victim
;             flag-clear mask widened $FFF7 -> $FFE7 (clears TF_GRAPHICS too)
;             and now also zeroes TCB_GFX_MODE. (Also corrected a stale comment:
;             TCB_FLAGS is at $12, not $1C.) Requires kos_defs.inc r45+.
; Revision: r22 — 17 May 2026 — Phase 14 Part 3b: heap reap hook.
;             • _ReapDeadTask calls _ReapByTid(victim.TID) at the
;               .rdt_not_shell convergence point, AFTER the shell
;               back-buffer manual free and BEFORE the ready-ring unlink.
;             • For shell tasks: back-buffer's USED bit is already clear
;               when _ReapByTid walks; it skips that block harmlessly.
;               All OTHER heap allocations owned by the dying TID are
;               freed automatically.
;             • For non-shell tasks: _ReapByTid is the sole heap cleanup
;               path (shell prologue was a no-op).
;             • TID 0 (kernel-owned blocks) is skipped via BEQ — kernel
;               allocations survive task death by OWNER_KERNEL convention.
;             • XY1 (victim TCB ptr) saved/restored around the call
;               since _ReapByTid uses XY1 as its region-descriptor scratch.
;             • Validated by Test/kos_p14p3_reap_smoke.asm (9/9 PASS,
;               17 May 2026). With this hook a leaky user task gets its
;               allocations reclaimed automatically on exit.
;             Requires kos_kmalloc.asm r14+ (adds _ReapByTid) and
;             kos_defs.inc r39+ (adds OWNER_KERNEL, BH_OWNER_TID, and
;             page-$00 scratch slots HEAP_TID_QUERY / HEAP_RBT_REGION).
;
;           r21 — 14 May 2026 — Part 31 refactor: hand-back consolidated.
;             • _ReapDeadTask's FOREGROUND_TCB retarget block now also
;               calls _RepaintFromBackbuf on the successor TCB. Combined
;               with the shell-ring unlink and back-buffer free added in
;               r20, _ReapDeadTask is now the single point that handles
;               every consequence of a registered shell dying.
;             • Companion changes in kos_task.asm r18 remove the
;               duplicate hand-back hooks from sys_exit and
;               _HandleDeadTCB, and add an explicit eager-reap branch
;               for shells in sys_exit's no-waiter case (so lazy-reap
;               doesn't leave the foreground frozen on a dead shell).
;             • No behaviour change for non-shell reaps (TF_HAS_BACKBUF
;               clear takes the BEQ branch and skips the whole block).
;             Requires kos_task.asm r18 to match (drops the now-redundant
;             hooks). Without r18, behaviour is still correct -- just
;             duplicated work (hand-back called twice, repaint called
;             twice -- minor flicker, no incorrect state).
;
; Revision: r20 — 14 May 2026 — Part 31: shell-ring unlink in _ReapDeadTask.
;             • _ReapDeadTask gains a prologue that, if the victim TCB has
;               TF_HAS_BACKBUF set, splices the victim out of the shell ring
;               (TCB_SHELL_NEXT chain), retargets FOREGROUND_TCB and
;               FIRST_SHELL_TID if either pointed at the victim, calls
;               _kfree on the back-buffer (~2400 bytes/shell), and clears
;               TF_HAS_BACKBUF / TCB_SHELL_NEXT / TCB_BACKBUF_OFFS /
;               TCB_BACKBUF_PAGE on the victim TCB.
;             • Lone-shell case (victim.SHELL_NEXT == victim): clears
;               FOREGROUND_TCB / FIRST_SHELL_TID and skips the walk.
;             • Multi-shell case: forward walk capped at MAX_SHELL_RING_LEN;
;               if cap exceeded (corrupt ring), skip the unlink but still
;               free the buffer and clear the flag bits.
;             • Pre-Part-31, reaping a registered shell left stale entries
;               in the shell ring, so Ctrl-N / Ctrl-P / Ctrl-digit would
;               teleport into the now-TS_UNUSED corpse and try to read its
;               (potentially-freed) back-buffer. Never triggered before
;               because reap was unreachable for registered shells (lazy-
;               reap left them TS_DEAD forever; sys_kill refused TS_DEAD).
;               Part 31 (b) made sys_kill reap TS_DEAD, exposing this.
;             • Non-shell reaps (TF_HAS_BACKBUF clear) take the BEQ branch
;               and skip the whole new block — zero overhead.
;             Requires kos_defs.inc r32+ (MAX_SHELL_RING_LEN, FIRST_SHELL_TID,
;             TCB_SHELL_NEXT, TCB_BACKBUF_OFFS, TCB_BACKBUF_PAGE, TF_HAS_BACKBUF)
;             and kos_kmalloc.asm (_kfree).
;
; Revision: r19 — 8 May 2026 — Part 20b: TCB_SEM_NEXT field accommodation.
;             • _BuildTask's zero-init scan now starts at TCB_SEM_NEXT
;               (= $20) instead of TCB_RESERVED (= $22 in the new layout).
;               Keeps the byte range $20..$7F covered as before, ensuring
;               fresh tasks have TCB_SEM_NEXT = 0 (i.e. not on any sem
;               wait queue), and TCB_RESERVED + TCB_NAME zero as before.
;               Word count unchanged (48); only the start anchor moved.
;             • No other changes; existing behaviour preserved exactly.
;             Requires kos_defs.inc r25+.
;
; Revision: r18 - 5 May 2026 — Task names.
;             - _InitTCBPool: write "idle\0" into IDLE_TCB+TCB_NAME
;               after the existing field init.
;             - _BuildTask: after the zero-init of TCB_RESERVED+TCB_NAME,
;               if BT_NAME ($00:$0240) starts with a non-zero byte, copy
;               up to 31 bytes from BT_NAME into TCB_NAME, terminating
;               with a nul. Empty BT_NAME leaves TCB_NAME zero-filled
;               as before, so this is backwards-compatible with all
;               existing callers (Phase 14 smokes).
;             Requires kos_defs.inc r20+.
;
; Revision: r17 - 4 May 2026 — Branch .S polish.
;             14 unsuffixed branches converted to .S form
;             where target distance is ≤10 instructions.
;             FORWARD ONLY (assembler imm5 is unsigned 0..+31).
;             Per
;             K16 Manual Amendment 2026-05-04 E.5/E.6, default
;             auto-select picks long form; explicit .S saves
;             one word per branch. Saves 14 words.
;
; Revision: r16 - 4 May 2026 — Opcode polish.
;             1 occurrence of `AND D2, #$00FF` replaced with `LOW D2`.
;             Same operation, 1 word instead of 2, 3 cycles instead
;             of 4. Saves 1 word.
;
;           r15 - 3 May 2026 — _AllocPage host-aware. Reads
;             KOS_USER_PAGE_END (set by _InitMemConfig) instead of the
;             literal compile-time TASK_PAGE_END. Digital caps at $1F
;             (30 user pages); EMU runs to $3F (62 user pages). TCB
;             pool is statically sized for 62 on both hosts. Requires
;             kos_defs.inc r18+, kos_kmalloc.asm r2+ (the latter writes
;             KOS_USER_PAGE_END at boot before any spawn).
;
;           r14 - 2 May 2026 — Part 7 additions:
;             - Added _AllocPage / _PageInUse: derive page allocation
;               from TCB pool state. No bitmap. A page is "free" iff
;               no in-use TCB has TCB_SAVED_Y matching it.
;             - Added _ReapDeadTask: unlinks a TCB from the ready
;               ring, marks slot TS_UNUSED. Page is implicitly freed
;               by the state change (no separate _FreePage needed).
;             - _BuildTask r14: zero-init the TCB_RESERVED+TCB_NAME
;               zone ($20..$7F, 48 words). Cheap defensive cleanup
;               for debug observers.
;             - TCB v2.4: TCB_NAME moved from $20 to $60; TCB_RESERVED
;               from $40 to $20. Hot-path field offsets unchanged
;               so all existing field accesses still assemble cleanly.
;             Requires kos_defs.inc r14+.
;           r13 - 2 May 2026 — TCB v2.3: TCB_WAKE_TICK now occupies offset
;             $08 (formerly the unused TCB_NEXT_TCB_HI reservation, kept
;             in IMM5 range so [XY+#TCB_WAKE_TICK] addressing assembles
;             cleanly). Both _InitTCBPool (idle TCB) and _BuildTask
;             (user TCBs) zero the new field. Defensive only — the slot
;             is read only when state==TS_BLOCKED, and sys_sleep sets
;             wake_tick atomically under DINT before transitioning to
;             BLOCKED — but cheap and safer for future reasoning.
;             Requires kos_defs.inc r13+.
;           r12 - 2 May 2026 — _AllocTCB now uses USER_TCB_BASE and
;             USER_TCB_COUNT symbolic constants from kos_defs.inc r12,
;             replacing hardcoded $0880 / #15. Supports the 32-user-task
;             pool size automatically.
;           r11 - 2 May 2026 — _InitTCBPool and _BuildTask zero the new
;             TCB_YIELD_COUNT and TCB_PREEMPT_COUNT counter fields per
;             kos_defs.inc r10.
;           r10 - 2 May 2026 — _BuildTask now populates task-local
;             page-zero slots [primary:MY_TCB_PTR] and [primary:TASK_ID]
;             at task creation. Enables fast LOADP-based per-task state
;             access from leaf syscalls (sys_getpid is the first user).
;           r9 - 1 May 2026 — idle-task bootstrap model:
;             - _InitTCBPool now constructs the idle TCB at slot 0,
;               sets CURRENT_TCB = IDLE_TCB, READY_HEAD = 0
;             - _AllocTCB scans from slot 1 (idle is never reallocated)
;             - _BuildTask unchanged otherwise
; History:  r8 - 1 May 2026 — TCB v2.1 layout: symbolic offsets, word-granular
;                              fields, parent_id support, new fields zeroed
; Purpose: TCB pool init/alloc, ready-queue insertion, fake-frame task
;          creation, page allocation, dead-task reaping.
;          All routines run from kernel context (Y3=$00) at boot or
;          task-creation time, never from inside an IRQ.
;
; TCB pool: $00:0800..$187F (33 TCBs × 128 bytes).
;
; Note: included from kos_boot.asm; constants from kos_defs.inc.
; ============================================================================

; ============================================================================
; _InitTCBPool — mark all TCBs as TS_UNUSED, construct idle TCB at slot 0
;
; Idle-task model:
;   Slot 0 (= IDLE_TCB at $00:0800) is the idle TCB. It represents the
;   kernel idle loop in Page $00 — Y3=$00, X3 somewhere on kernel stack.
;   CURRENT_TCB is initialised to point at idle so the very first timer
;   IRQ has a real TCB to save state into. _Schedule treats CURRENT==idle
;   as "nothing running yet" and switches to READY_HEAD.
;
;   Idle is never on the ready queue. _AllocTCB scans from slot 1.
; ============================================================================
_InitTCBPool:
                PUSH    D0, XY3
                PUSH    D1, XY3
                PUSH    XY1, XY3
                PUSH    XY2, XY3                ; r18 (used to set idle name)

                ;-- Mark every TCB TS_UNUSED first ---------------------------
                LOADI   Y1, #$00
                LOADI   X1, #TCB_POOL_BASE
                LOADI   D1, #TCB_POOL_COUNT
                LOADI   D0, #TS_UNUSED
.loop:
                STORED  D0, [XY1+#TCB_STATE]
                ADD     X1, #TCB_SIZE
                SUB     D1, #1
                BNE     .loop

                ;-- Clear scheduler globals ----------------------------------
                LOADI   D0, #0
                STOREZ  D0, [#READY_HEAD]
                STOREZ  D0, [#TASK_COUNT]
                STOREZ  D0, [#BT_PARENT_ID]

                ;-- Clear foreground/shell-ring anchors (r25) ----------------
                ; sys_register_shell tests FOREGROUND_TCB == 0 to decide the
                ; first-shell path. These two globals are NOT in the TCB pool,
                ; so the TS_UNUSED sweep above does not touch them; without an
                ; explicit clear they survive a reset that leaves RAM intact
                ; (real-hardware reset line, the b-reset button, or a warm
                ; WebEMU boot). A stale FOREGROUND_TCB pointing at a now-dead
                ; TID makes the freshly-spawned kosh splice against a ghost and
                ; hang at shell bring-up. Zero here so boot is correct
                ; regardless of prior RAM contents.
                STOREZ  D0, [#FOREGROUND_TCB]
                STOREZ  D0, [#FIRST_SHELL_TID]

                ;-- Construct idle TCB at slot 0 -----------------------------
                LOADI   Y1, #$00
                LOADI   X1, #IDLE_TCB

                ; saved_x / saved_y: undefined at init; first IRQ will
                ; overwrite them with whatever the idle loop's X3/Y3 are.
                ; Initialise to plausible kernel values for cleanliness.
                LOADI   D0, #KERNEL_STACK_TOP
                STORED  D0, [XY1+#TCB_SAVED_X]
                LOADI   D0, #IDLE_PAGE
                STORED  D0, [XY1+#TCB_SAVED_Y]

                LOADI   D0, #0
                STORED  D0, [XY1+#TCB_PAGE_COUNT]
                STORED  D0, [XY1+#TCB_NEXT_TCB]      ; idle has no successor
                STORED  D0, [XY1+#TCB_WAKE_TICK]     ; r13: was NEXT_TCB_HI in v2.2
                LOADI   D0, #TS_READY
                STORED  D0, [XY1+#TCB_STATE]
                LOADI   D0, #0
                STORED  D0, [XY1+#TCB_PRIORITY]
                STORED  D0, [XY1+#TCB_ID]            ; id 0 = idle
                STORED  D0, [XY1+#TCB_QUANTUM]
                STORED  D0, [XY1+#TCB_FLAGS]
                STORED  D0, [XY1+#TCB_EVENT_MASK]
                STORED  D0, [XY1+#TCB_PARENT_ID]
                STORED  D0, [XY1+#TCB_EXIT_CODE]
                STORED  D0, [XY1+#TCB_WAIT_ID]
                STORED  D0, [XY1+#TCB_YIELD_COUNT]
                STORED  D0, [XY1+#TCB_PREEMPT_COUNT]

                ; r18: idle TCB name = "idle\0". TCB_NAME at TCB+$60 is
                ; out of IMM5 reach so use a rebased X2 pointer and write
                ; the five bytes individually.
                MOVE    X2, X1
                ADD     X2, #TCB_NAME           ; X2 -> IDLE_TCB+$60
                LOADI   Y2, #$00
                LOADI   D0, #'i'
                STOREB  D0, [XY2]
                ADD     X2, #1
                LOADI   D0, #'d'
                STOREB  D0, [XY2]
                ADD     X2, #1
                LOADI   D0, #'l'
                STOREB  D0, [XY2]
                ADD     X2, #1
                LOADI   D0, #'e'
                STOREB  D0, [XY2]
                ADD     X2, #1
                LOADI   D0, #0
                STOREB  D0, [XY2]

                ; CURRENT_TCB = IDLE_TCB
                LOADI   D0, #IDLE_TCB
                STOREZ  D0, [#CURRENT_TCB]

                POP     XY2, XY3
                POP     XY1, XY3
                POP     D1, XY3
                POP     D0, XY3
                RET

; ============================================================================
; _AllocTCB — find first TS_UNUSED TCB, mark TS_READY, return its address
;
;   Output:
;     D0 = TCB low-word address (or 0 on failure)
;     C  = 0 success, 1 failure (pool full)
;
;   Marks state = TS_READY but caller must still fill in the TCB
;   fields and call _AddToRunQueue.
;
;   Slot 0 is reserved for idle and is skipped by the scan.
; ============================================================================
_AllocTCB:
                PUSH    D1, XY3
                PUSH    D2, XY3
                PUSH    XY1, XY3

                LOADI   Y1, #$00
                LOADI   X1, #USER_TCB_BASE      ; start at slot 1 (skip idle)
                LOADI   D1, #USER_TCB_COUNT     ; scan all user slots
                LOADI   D2, #TS_UNUSED
.scan:
                LOADD   D0, [XY1+#TCB_STATE]
                CMP     D0, D2
                BEQ.S     .found
                ADD     X1, #TCB_SIZE
                SUB     D1, #1
                BNE     .scan

                ; Pool full
                LOADI   D0, #0
                SEC
                BRA.S     .done

.found:
                LOADI   D0, #TS_READY
                STORED  D0, [XY1+#TCB_STATE]
                MOVE    D0, X1                  ; return TCB address
                CLC

.done:
                POP     XY1, XY3
                POP     D2, XY3
                POP     D1, XY3
                RET

; ============================================================================
; _PageInUse - is a given page byte currently owned by some live TCB?
;
;   Input:    D0 = candidate page byte ($01..$20)
;   Output:   C=0 if page is FREE (no in-use TCB owns it)
;             C=1 if page is OWNED by some TCB
;   Clobbers: flags only (D0 preserved)
;
;   "In use" = TCB_STATE != TS_UNUSED. Note that TS_DEAD slots still
;   own their pages (until _ReapDeadTask runs); we treat them as owned.
;   This means an unreaped dead task's pages are unavailable for reuse,
;   which is correct.
;
;   Part 60 - RANGE test, not an equality test.  A task owns a RUN of
;   TCB_PAGE_COUNT contiguous pages starting at its own page:
;
;       owned(p) := p >= TCB_SAVED_Y  and  p < TCB_SAVED_Y + TCB_PAGE_COUNT
;
;   e.g. base $04 with count 2 owns $04 and $05; $06 is free.
;
;   Contiguity, and the run starting at the task's OWN page, are what let a
;   single TCB field describe the whole set.  That is what keeps release
;   free: there is no _FreePage and no ownership bitmap, so reaping the TCB
;   to TS_UNUSED makes the ENTIRE run vanish from this scan at once.  The
;   kill / exit / reap path needs no edit for multi-page tasks.
;
;   A count of 0 yields an empty range.  The idle TCB is built directly by
;   _InitTCBPool with SAVED_Y=$00 / PAGE_COUNT=0, so it now claims nothing
;   where the old equality test reported page $00 owned.  No effect - the
;   allocator's scan starts at USER_PAGE_BASE ($02) - but it is a real
;   behaviour delta, recorded here rather than discovered later.
;
;   CARRY SENSE.  K16 is 6502-style: after CMP A,B, C=1 means NO borrow,
;   i.e. A >= B unsigned; C=0 means borrow, A < B.  BLO = C=0 = A < B.
;   The x86 autopilot is backwards.  Both tests below branch on BLO, to
;   opposite targets.
;
;   Cost: 32 TCB inspections, ~10 cycles each => ~320 cycles worst case
;   (was ~160).  Spawn-time only.
; ============================================================================
_PageInUse:
                ; Part 60: was PUSH D1 / PUSH D2 separately.  PUSH D123 costs
                ; about the same and hands us D3 - which is exactly the extra
                ; scratch the range test needs.
                PUSH    D123, XY3
                PUSH    XY1, XY3

                MOVE    D2, D0                  ; D2 = candidate page byte
                LOADI   X1, #USER_TCB_BASE
                LOADI   Y1, #$00
                LOADI   D1, #USER_TCB_COUNT

.scan:
                ; Skip TS_UNUSED slots
                LOADD   D0, [XY1+#TCB_STATE]
                CMP     D0, #TS_UNUSED
                BEQ.S   .skip

                ; -- Is the candidate inside this task's page run? ---------
                ; Carry is 6502-style: after CMP A,B, C=1 = no borrow = A >= B
                ; unsigned.  BLO = C=0 = A < B.  State it before writing the
                ; branch; the x86 reading is backwards.
                LOADD   D3, [XY1+#TCB_SAVED_Y]  ; D3 = run base page
                CMP     D2, D3
                BLO.S   .skip                   ; candidate below the run

                LOADD   D0, [XY1+#TCB_PAGE_COUNT]
                ADD     D0, D3                  ; D0 = first page PAST the run
                                                ; (ADD takes no carry in, RM
                                                ;  6.3 mode 00, so no CLC)
                CMP     D2, D0
                BLO.S   .owned                  ; candidate inside the run
                                                ; count 0 => D0 = base, so this
                                                ; fails: the range is empty

.skip:
                ADD     X1, #TCB_SIZE
                SUB     D1, #1
                BNE     .scan

                ; Walked entire pool without finding owner => free
                MOVE    D0, D2                  ; restore D0
                CLC
                BRA.S   .done

.owned:
                MOVE    D0, D2                  ; restore D0
                SEC

.done:
                POP     XY1, XY3
                POP     D123, XY3
                RET

; ============================================================================
; _AllocPageRun - lowest run of N consecutive free user pages     [Part 60]
;                 in [USER_PAGE_BASE .. KOS_USER_PAGE_END]
;
;   Input:    D0 = N, pages wanted (>= 1)
;   Output:   D0 = base page byte of the run, C=0    on success
;             D0 = $0000,                     C=1    if no such run exists
;   Clobbers: flags only (D0 is the result; D1/D2/D3 preserved)
;
;   The ceiling is host-dependent: Digital -> $1F (30 pages), EMU -> $3F (62
;   pages). It's set at boot by _InitMemConfig into KOS_USER_PAGE_END.
;
;   ALGORITHM.  One _PageInUse probe per CANDIDATE, carrying a
;   consecutive-free run length in D3; an owned probe resets the run to
;   zero.  O(candidates), NOT O(N x candidates) - worst case is the same
;   ~62 probes as the old single-page scan, so N costs nothing extra.
;
;   N is parked on the stack at [XY3+#6]: D1 = candidate, D2 = ceiling+1 and
;   D3 = run length use every register _PageInUse leaves free, and D0 is its
;   argument.  (PUSH D0 = 2 bytes, PUSH D123 = 6 bytes, so N sits 6 above
;   the stack pointer.)
;
;   Returns the LOWEST qualifying run.  Deterministic across boots.
;
;   WHY CONTIGUOUS.  Not a convenience: it is what lets one TCB_PAGE_COUNT
;   describe the whole run, which is what makes release free - reap the TCB
;   to TS_UNUSED and the entire range vanishes from _PageInUse.  There is
;   deliberately no _FreePage and no ownership bitmap; "the TCB pool is the
;   truth" survives intact.
;
;   TWO DELIBERATE LIMITATIONS, recorded so they read as choices:
;     - No dynamic growth.  A task cannot ask for more later.
;     - Fragmentation is possible: a run of 2 can fail with 5 pages free
;       but scattered.  With allocation only at spawn, release only at
;       reap, and few concurrent tasks this is unlikely; N=1 is unaffected
;       either way.
;
;   FAIL-FAST IS THE POINT.  A task that cannot get its pages is dead.
;   Failing here means the PARENT handles ERR_NOMEM - kosh prints a message
;   and returns to the prompt.  Failing mid-initialisation would leave a
;   half-built task with pages already consumed.
;
;   NOTE: allocation does NOT clear the pages.  A multi-page task sees the
;   previous tenant's bytes in its extra pages, exactly as it already does
;   below $0200 in its own page - which is why sys_exec must stamp
;   ARGV_BASE rather than trust a zero there.
; ============================================================================
_AllocPageRun:
                PUSH    D0, XY3                 ; N - read back as [XY3+#6]
                PUSH    D123, XY3

                CMP     D0, #0
                BEQ     .apr_fail               ; N=0 is a caller bug

                ; D2 = runtime user-page ceiling (set by _InitMemConfig)
                ; Digital: $1F (30 pages)  EMU: $3F (62 pages)
                LOADZ   D2, [#KOS_USER_PAGE_END]
                LOW     D2
                ADD     D2, #1                  ; one past last valid

                LOADI   D1, #USER_PAGE_BASE     ; D1 = candidate, start at $02
                LOADI   D3, #0                  ; D3 = consecutive free so far

.apr_scan:
                MOVE    D0, D1                  ; candidate page in D0
                CALL24  _PageInUse
                BCS.S   .apr_break              ; C=1 => owned, run is broken

                ADD     D3, #1
                LOADD   D0, [XY3+#6]            ; D0 = N
                CMP     D3, D0
                BLO.S   .apr_next               ; C=0 => run not long enough yet

                ; Run complete.  Base = candidate - (N-1) = D1 - D3 + 1.
                MOVE    D0, D1
                SUB     D0, D3
                ADD     D0, #1
                BRA.S   .apr_ok

.apr_break:
                LOADI   D3, #0                  ; owned page - restart the run

.apr_next:
                ADD     D1, #1
                CMP     D1, D2                  ; vs runtime ceiling+1
                BLO     .apr_scan               ; C=0 => still below ceiling

                ; Fell off the ceiling without completing a run.
                ; Two self-contained tails, no shared epilogue.  POP leaves
                ; flags alone but ADD X3 does NOT (ADD Xn sets flags; ADD XYn
                ; does not - RM 6.4), so the carry must be set LAST.
.apr_fail:
                POP     D123, XY3
                ADD     X3, #2                  ; discard saved N - CLOBBERS FLAGS
                LOADI   D0, #0
                SEC
                RET

.apr_ok:
                POP     D123, XY3
                ADD     X3, #2                  ; discard saved N - CLOBBERS FLAGS
                CLC
                RET

; ============================================================================
; _AllocPage - lowest free single user page          [Part 60: thin wrapper]
;
;   Output:
;     D0 = page byte ($02..ceiling), C=0    on success
;     D0 = $0000,                    C=1    if all pages exhausted (ERR_NOMEM)
;
;   Contract unchanged, so sys_spawn, _SpawnShell and sys_exec's existing
;   call sites need no edit.  Tail call: _AllocPageRun's RET returns to OUR
;   caller.
; ============================================================================
_AllocPage:
                LOADI   D0, #1
                JMP24   _AllocPageRun

; ============================================================================
; _AddToRunQueue — insert TCB into round-robin ready queue
;
;   Input:  D0 = TCB low-word address
;
;   If queue is empty, new TCB becomes head pointing at itself.
;   Otherwise insert just after READY_HEAD.
;
;   Does NOT touch CURRENT_TCB. CURRENT_TCB is owned by the idle bootstrap
;   in _InitTCBPool and is only ever changed by _Schedule.
;
;   Clobbers: D0, flags
; ============================================================================
_AddToRunQueue:
                PUSH    D1, XY3
                PUSH    D2, XY3
                PUSH    XY0, XY3
                PUSH    XY1, XY3

                ; XY0 = new TCB
                MOVE    X0, D0
                LOADI   Y0, #$00

                ; Check if queue is empty
                LOADZ   D1, [#READY_HEAD]
                CMP     D1, #0
                BNE.S     .not_empty

                ; Empty: new.next = self, become head
                MOVE    D2, X0
                STORED  D2, [XY0+#TCB_NEXT_TCB]
                STOREZ  D2, [#READY_HEAD]
                BRA.S     .bump

.not_empty:
                ; XY1 = head TCB
                MOVE    X1, D1
                LOADI   Y1, #$00

                ; new.next = head.next
                LOADD   D2, [XY1+#TCB_NEXT_TCB]
                STORED  D2, [XY0+#TCB_NEXT_TCB]

                ; head.next = new
                MOVE    D2, X0
                STORED  D2, [XY1+#TCB_NEXT_TCB]

.bump:
                LOADZ   D2, [#TASK_COUNT]
                ADD     D2, #1
                STOREZ  D2, [#TASK_COUNT]

                POP     XY1, XY3
                POP     XY0, XY3
                POP     D2, XY3
                POP     D1, XY3
                RET

; ============================================================================
; _ReapDeadTask — unlink TCB from all rings, free shell back-buffer if any,
;                 mark slot TS_UNUSED. Single source of truth for shell
;                 death cleanup including foreground hand-back + repaint.
;
;   Input:    X1:Y1 = TCB pointer (Y1 = $00 always)
;   Output:   none.
;   Preserves: All caller-visible regs -- D0..D3, XY0, XY1, XY2, XY3.
;             Internally clobbers, but saves/restores via PUSH/POP at
;             entry/exit. XY1 is temporarily redirected to the new fg
;             TCB across the _RepaintFromBackbuf call but restored to
;             the victim TCB before return.
;   Effect:
;     1. Phase B shell-ring cleanup (Part 31 — r5):
;          If TF_HAS_BACKBUF set:
;            a. Walk shell ring forward to find predecessor; splice out.
;            b. If victim WAS foreground:
;                  - Retarget FOREGROUND_TCB to successor's TID.
;                  - _RepaintFromBackbuf(successor TCB).
;               If victim was the lone shell, clear FOREGROUND_TCB and
;               FIRST_SHELL_TID entirely (no successor to paint).
;            c. Same retarget for FIRST_SHELL_TID anchor.
;            d. _kfree the back-buffer (~2400 bytes/shell).
;            e. Clear TF_HAS_BACKBUF, TCB_SHELL_NEXT, TCB_BACKBUF_*.
;     2. Forward-scan ready ring to find predecessor; unlink target.
;     3. Adjust READY_HEAD if it pointed at target.
;     4. TCB_STATE := TS_UNUSED  (also implicitly frees the page —
;        _AllocPage's scan will no longer see the slot as in-use)
;     5. TCB_NEXT_TCB := 0      (defensive; catches stale ptr use)
;
;   Single-source-of-truth invariant (Part 31 r6+):
;     Any path that destroys a registered shell (sys_exit eager-reap,
;     sys_kill via _HandleDeadTCB, future reapers) routes through here.
;     Callers do NOT separately call _SwitchForegroundNext or unlink the
;     shell ring -- _ReapDeadTask handles foreground transition, repaint,
;     ring unlink, and buffer free as one atomic kernel-side operation.
;
;   Safety:
;     - Caller must not reap idle (slot 0). Not checked here.
;     - Caller must DINT during reap if the ring is being scanned by
;       a concurrent IRQ. In practice, all reap callers are already
;       in DINT context (sys_exit / sys_wait under DINT).
;
;   Note on "freeing the page": there is no explicit _FreePage. The
;   page becomes available the moment TCB_STATE goes TS_UNUSED, since
;   _PageInUse skips TS_UNUSED slots. Single source of truth.
;
;   Revision history:
;     r6 — 14 May 2026 — Part 31 refactor: foreground hand-back + repaint
;          consolidated here, removing duplicate hooks in sys_exit and
;          _HandleDeadTCB.
;     r5 — 14 May 2026 — Part 31: shell-ring unlink + back-buffer free.
;     r4 — pre-Part-31 baseline (ready-ring only).
; ============================================================================
_ReapDeadTask:
                PUSH    D0, XY3
                PUSH    D123, XY3
                PUSH    XY0, XY3
                PUSH    XY2, XY3

                ; -------- Phase B shell-ring unlink (Part 31, 14 May 2026) ------
                ; If victim has TF_HAS_BACKBUF set, it's also a node in the
                ; shell ring (TCB_SHELL_NEXT chain anchored by FIRST_SHELL_TID).
                ; Reap MUST unlink from this ring too, otherwise Ctrl-N /
                ; Ctrl-P / Ctrl-digit will still teleport to the now-reaped
                ; (TS_UNUSED) TCB and try to read its freed back-buffer.
                ;
                ; This was deferred at Phase B Step 10 ("a killed shell should
                ; be unlinked by Step 10's death cleanup") and never landed
                ; because reap was never actually reached for a registered
                ; shell prior to Part 31 (b)'s "kill TS_DEAD" change.
                ;
                ; Steps:
                ;   1. Skip if TF_HAS_BACKBUF clear (non-shell reap, common).
                ;   2. Special-case lone shell (next==self): clear globals.
                ;   3. Else walk forward to find predecessor; splice out;
                ;      retarget FOREGROUND_TCB / FIRST_SHELL_TID if needed.
                ;   4. _kfree the back-buffer (~2400 bytes/shell).
                ;   5. Clear TF_HAS_BACKBUF / TF_GRAPHICS and TCB_SHELL_NEXT.
                ; Part 49: a graphics task (TF_GRAPHICS, no back-buffer) is also
                ; a ring member, so the unlink must fire for it too. The
                ; back-buffer free below is guarded by a zero-offset skip, so a
                ; graphics task (TCB_BACKBUF_OFFS = 0) frees nothing.
                LOADD   D0, [XY1+#TCB_FLAGS]
                AND     D0, #TF_FOCUSABLE
                BEQ     .rdt_not_shell

                ; -- D1 := victim TID (referenced repeatedly below) -----------
                LOADD   D1, [XY1+#TCB_ID]

                ; -- D3 := TCB_SHELL_NEXT offset (used as mode-01 index) ------
                ; All TCB_SHELL_NEXT / TCB_BACKBUF_* fields ($4C..$50) live
                ; outside the imm5 range (0..31), so mode-01 [XY+D] is
                ; required for every access. We keep the offset in D3
                ; through the shell-unlink block.
                LOADI   D3, #TCB_SHELL_NEXT

                ; -- Lone shell vs multi-shell vs corrupt link ---------------
                LOADD   D0, [XY1+D3]
                ; Part 50: a lone shell carries next = 0 (the live convention
                ; _SwitchForegroundNext honours) or next = self. Both mean
                ; "last shell out" -> clear globals, skip the walk. Any other
                ; sub-pool value (< USER_TCB_BASE, e.g. a stray $00FF) is a
                ; corrupt link: never walk it or it faults on the page-$00
                ; vector table. CMP: C=1 when D0 >= base; BLO = C=0 = below.
                CMP     D0, #0
                BEQ     .rdt_lone
                CMP     D0, #USER_TCB_BASE
                BLO     .rdt_free_backbuf
                CMP     D0, X1
                BNE     .rdt_multi_shell

.rdt_lone:
                ; Lone shell — last one out. Clear global anchors.
                LOADI   D0, #0
                STOREZ  D0, [#FOREGROUND_TCB]
                STOREZ  D0, [#FIRST_SHELL_TID]
                ; Drop any keyboard-waiter registration (Part 48).
                CALL24  _KbdReleaseWaiter
                BRA     .rdt_free_backbuf

.rdt_multi_shell:
                ; Walk forward from victim's successor to find predecessor P
                ; such that P.SHELL_NEXT == victim. Bound by MAX_SHELL_RING_LEN.
                ; D0 already holds victim.SHELL_NEXT (our successor offset).
                MOVE    X2, D0
                LOADI   Y2, #$00
                LOADI   D2, #MAX_SHELL_RING_LEN
.rdt_find_pred:
                LOADD   D0, [XY2+D3]            ; D0 = walker.SHELL_NEXT
                CMP     D0, X1
                BEQ     .rdt_found_pred
                MOVE    X2, D0                  ; advance walker
                SUB     D2, #1
                BNE     .rdt_find_pred
                ; Walked past cap — ring corrupt. Skip unlink but still free
                ; the back-buffer and clear flags, rather than infinite-loop.
                BRA     .rdt_free_backbuf

.rdt_found_pred:
                ; XY2 = predecessor. Splice: P.SHELL_NEXT := victim.SHELL_NEXT
                LOADD   D0, [XY1+D3]            ; victim's successor offset
                STORED  D0, [XY2+D3]

                ; If FOREGROUND_TCB == victim.TID, retarget to successor TID
                ; AND repaint terminal from new foreground's back-buffer.
                ; (D1 still holds victim TID; D3 still = TCB_SHELL_NEXT offset.)
                ;
                ; This is the "single source of truth" for foreground hand-back
                ; on shell exit: sys_exit's eager-reap path and sys_kill's
                ; _HandleDeadTCB path both flow through here, so there's
                ; exactly one place that decides "the foreground shell just
                ; died; promote the next one and paint its buffer".
                LOADZ   D0, [#FOREGROUND_TCB]
                CMP     D0, D1
                BNE     .rdt_fg_keep

                ; Read successor TCB offset from predecessor's now-updated
                ; SHELL_NEXT link, load successor TCB into XY0, grab its TID.
                LOADD   D0, [XY2+D3]
                MOVE    X0, D0
                LOADI   Y0, #$00
                LOADD   D0, [XY0+#TCB_ID]
                STOREZ  D0, [#FOREGROUND_TCB]

                ; Hand off the keyboard to the successor foreground; clears
                ; the exiting shell's stale registration (Part 48).
                CALL24  _KbdReleaseWaiter

                ; Repaint terminal from new foreground's back-buffer.
                ; _RepaintFromBackbuf wants XY1 = new fg TCB. Save victim's
                ; X1 across the call (the downstream code -- back-buffer
                ; free, flag clears, ready-ring unlink -- all need XY1 back
                ; at the victim TCB). _RepaintFromBackbuf preserves XY1
                ; per its contract but we're going to OVERWRITE XY1 to point
                ; at the new foreground before the call, so the save/restore
                ; is for our own bookkeeping, not _RepaintFromBackbuf's.
                PUSH    X1, XY3
                MOVE    X1, X0                  ; XY1 = new fg TCB (from XY0)
                ; Y1 already $00 (from earlier in this routine)
                CALL24  _RepaintFromBackbuf
                POP     X1, XY3
                LOADI   Y1, #$00
.rdt_fg_keep:

                ; Same retarget for FIRST_SHELL_TID.
                LOADZ   D0, [#FIRST_SHELL_TID]
                CMP     D0, D1
                BNE     .rdt_first_keep
                LOADD   D0, [XY2+D3]
                MOVE    X0, D0
                LOADI   Y0, #$00
                LOADD   D0, [XY0+#TCB_ID]
                STOREZ  D0, [#FIRST_SHELL_TID]
.rdt_first_keep:

.rdt_free_backbuf:
                ; -- Free the back-buffer ------------------------------------
                ; _kfree clobbers only D0 — XY1 (victim TCB ptr) survives.
                ; TCB_BACKBUF_OFFS/_PAGE/_SHELL_NEXT all outside imm5; reuse
                ; D3 as the mode-01 index, reloading per field.
                LOADI   D3, #TCB_BACKBUF_OFFS
                LOADD   D0, [XY1+D3]
                MOVE    X0, D0
                LOADI   D3, #TCB_BACKBUF_PAGE
                LOADD   D0, [XY1+D3]
                MOVE    Y0, D0                      ; Y0 takes low byte
                ; Skip kfree if payload offset is zero (defensive).
                CMP     X0, #0
                BEQ     .rdt_skip_kfree
                CALL24  _kfree                      ; clobbers D0 only
.rdt_skip_kfree:

                ; -- Clear shell/graphics TCB fields on victim ---------------
                LOADI   D0, #0
                LOADI   D3, #TCB_SHELL_NEXT
                STORED  D0, [XY1+D3]
                LOADI   D3, #TCB_BACKBUF_OFFS
                STORED  D0, [XY1+D3]
                LOADI   D3, #TCB_BACKBUF_PAGE
                STORED  D0, [XY1+D3]
                LOADI   D3, #TCB_GFX_MODE           ; Part 49 — graphics task mode
                STORED  D0, [XY1+D3]
                ; Clear TF_HAS_BACKBUF + TF_GRAPHICS bits (~$0018 & $FFFF = $FFE7).
                ; TCB_FLAGS at $12 IS within imm5 — use mode-11 directly.
                LOADD   D0, [XY1+#TCB_FLAGS]
                AND     D0, #$FFE7
                STORED  D0, [XY1+#TCB_FLAGS]

.rdt_not_shell:
                ; -------- Phase 14 Part 3b: reap victim's heap blocks ---------
                ; Free every block in the kernel heap stamped with the dying
                ; task's TID (BH_OWNER_TID). _ReapByTid walks all regions
                ; in physical block order and calls _kfree on each match.
                ;
                ; Ordering rationale: this runs AFTER the shell path's
                ; explicit back-buffer _kfree. That manual free clears the
                ; back-buffer block's USED bit, so _ReapByTid's walk skips
                ; it (USED == 0 → not a match candidate). For non-shell
                ; tasks the shell path was a no-op (BEQ at the top) and
                ; this is the sole heap cleanup.
                ;
                ; _ReapByTid clobbers XY1 (uses it as region descriptor
                ; during the walk). Save/restore around the call since
                ; the ring-unlink code below needs XY1 = victim TCB.
                ;
                ; Validated by Test/kos_p14p3_reap_smoke.asm (9/9 PASS,
                ; 17 May 2026).
                LOADD   D0, [XY1+#TCB_ID]
                CMP     D0, #0
                BEQ     .rdt_skip_heap_reap     ; TID 0 (kernel) — no-op
                PUSH    XY1, XY3
                CALL24  _ReapByTid
                POP     XY1, XY3
.rdt_skip_heap_reap:

                ; -------- Find predecessor in ring -----------------------
                ; Walk forward from READY_HEAD; we want the node whose
                ; .next == target.
                ;
                ; Safety: if target is not actually in the ring (e.g.
                ; already-unlinked, or never inserted), the scan would
                ; loop forever. Detect by remembering the start point
                ; and bailing if we come back around.
                LOADZ   D0, [#READY_HEAD]
                CMP     D0, #0
                BEQ     .ring_empty             ; nothing to unlink
                MOVE    X0, D0
                LOADI   Y0, #$00
                ; X2 = remember start so we can detect full loop
                MOVE    X2, X0
                LOADI   Y2, #$00

.find_pred:
                LOADD   D0, [XY0+#TCB_NEXT_TCB]
                ; D0 = current.next; compare to target (X1)
                ; Direct CMP X..,X.. not always available; route via D0.
                ; But D0 == TCB low word of next, and X1 == TCB low word
                ; of target. So plain CMP D0, X1 works since X1 fits 16b.
                ; (CMP variant TBD — fall back to MOVE+CMP if needed.)
                CMP     D0, X1
                BEQ.S     .found_pred

                ; advance
                MOVE    X0, D0
                ; loop check: have we come back to start?
                CMP     X0, X2
                BNE     .find_pred
                ; Walked full ring, target not present — bail without unlink
                BRA.S     .mark_unused

.found_pred:
                ; X0 = predecessor; X1 = target.
                ; predecessor.next := target.next
                LOADD   D0, [XY1+#TCB_NEXT_TCB]
                STORED  D0, [XY0+#TCB_NEXT_TCB]

                ; If READY_HEAD pointed at target, advance head to target.next
                LOADZ   D0, [#READY_HEAD]
                CMP     D0, X1
                BNE.S     .head_ok
                LOADD   D0, [XY1+#TCB_NEXT_TCB]
                ; If target was the only node, target.next == target; we'd
                ; leave READY_HEAD pointing back at the dead TCB. Detect
                ; and zero the head in that case.
                CMP     D0, X1
                BNE.S     .write_head
                LOADI   D0, #0
.write_head:
                STOREZ  D0, [#READY_HEAD]
.head_ok:

.ring_empty:
.mark_unused:
                ; -------- Mark slot TS_UNUSED, clear next ptr ------------
                LOADI   D0, #TS_UNUSED
                STORED  D0, [XY1+#TCB_STATE]
                LOADI   D0, #0
                STORED  D0, [XY1+#TCB_NEXT_TCB]

                POP     XY2, XY3
                POP     XY0, XY3
                POP     D123, XY3
                POP     D0, XY3
                RET

; ============================================================================
; _BuildTask — create a TCB and prime its stack with a fake saved frame
;
;   Phase 2/3 ABI: caller stages task description in kernel scratch
;   slots, then calls _BuildTask with no register arguments.
;
;   Caller fills these scratch slots first:
;     BT_ENTRY_LO   ($00:0212) — task entry low word
;     BT_ENTRY_PG   ($00:0214) — task entry page byte (low byte of word)
;     BT_PRIMARY    ($00:0216) — primary_page (low byte of word)
;     BT_PCOUNT     ($00:0218) — page_count (low byte of word)
;     BT_PARENT_ID  ($00:021A) — parent task id (0 = kernel; default 0)
;
;   Output:
;     D0 = TCB ptr on success, 0 on failure
;     C  = 0 success, 1 failure
;
;   On success, the new task is in the ready queue.
;
;   Stack frame layout (per K16 INT push convention — page at lower addr):
;     [primary:$FFF4]  PC[15:0]
;     [primary:$FFF2]  PC[23:16] (low byte of word)
;     [primary:$FFF0]  SR ($0080 = IE=1, all flags 0)
;
;   ISR prologue then pushes D, XY0, XY1, XY2 (20 bytes total),
;   so saved_x = $FFDC with the prologue area pre-zeroed.
;
;   r14 addition: zero-init TCB_RESERVED + TCB_NAME zone ($20..$7F,
;   48 words). Cheap defensive cleanup; helps debug observers.
; ============================================================================
_BuildTask:
                PUSH    D1, XY3
                PUSH    D2, XY3
                PUSH    XY1, XY3
                PUSH    XY2, XY3

                ; Allocate a TCB
                CALL24  _AllocTCB
                BCS     .fail

                ; XY1 = TCB pointer
                MOVE    X1, D0
                LOADI   Y1, #$00

                ; -------- Fill TCB fields from scratch slots (word-granular) --------

                ; Saved Y3 = primary page byte (in low byte of word)
                LOADZ   D0, [#BT_PRIMARY]
                STORED  D0, [XY1+#TCB_SAVED_Y]

                ; Page count.  Part 60: BT_PCOUNT is page-$00 scratch that
                ; survives between spawns.  Before multi-page runs, a path
                ; that forgot to stage it inherited "1" and was harmless.
                ; Now it would inherit the PREVIOUS task's count and claim
                ; pages this task does not own - two tasks writing one page,
                ; with nothing to fault.  So clamp 0 to 1, then CONSUME the
                ; slot, making the guarantee structural rather than a rule
                ; every future spawn path has to remember.
                LOADZ   D0, [#BT_PCOUNT]
                CMP     D0, #0                  ; LOADZ is flag-transparent
                BNE.S   .bt_pc_ok
                LOADI   D0, #1                  ; unstaged => single page
.bt_pc_ok:
                STORED  D0, [XY1+#TCB_PAGE_COUNT]

                ; Priority, quantum, flags = 0 - and consume BT_PCOUNT with
                ; the same zero, so the next spawn cannot inherit this one.
                LOADI   D0, #0
                STOREZ  D0, [#BT_PCOUNT]
                STORED  D0, [XY1+#TCB_PRIORITY]
                STORED  D0, [XY1+#TCB_QUANTUM]
                STORED  D0, [XY1+#TCB_FLAGS]

                ; v2.1 new fields: zero EVENT_MASK / EXIT_CODE / WAIT_ID
                STORED  D0, [XY1+#TCB_EVENT_MASK]
                STORED  D0, [XY1+#TCB_EXIT_CODE]
                STORED  D0, [XY1+#TCB_WAIT_ID]

                ; r10 stat counters: zero yield/preempt counts
                STORED  D0, [XY1+#TCB_YIELD_COUNT]
                STORED  D0, [XY1+#TCB_PREEMPT_COUNT]

                ; r13: v2.3 wake_tick (defensive zero; only read when
                ;      TS_BLOCKED, but cheap and safer)
                STORED  D0, [XY1+#TCB_WAKE_TICK]

                ; r19 (Part 20b): zero-init the TCB_SEM_NEXT + TCB_RESERVED +
                ; TCB_NAME zone ($20..$7F, 48 words). TCB_SEM_NEXT (added at
                ; $20) MUST start zeroed — fresh tasks never on a sem queue.
                ; Was previously ADD X2,#TCB_RESERVED; now uses TCB_SEM_NEXT
                ; as the start anchor to keep the same byte range despite
                ; TCB_RESERVED shifting from $20 to $22.
                ; D0 already 0; X2 walks within the TCB.
                MOVE    X2, X1
                ADD     X2, #TCB_SEM_NEXT       ; X2 -> TCB+$20
                LOADI   Y2, #$00
                LOADI   D2, #48                 ; word count ($60 bytes / 2)
.zero_rsvd:
                STORED  D0, [XY2]+
                SUB     D2, #1
                BNE     .zero_rsvd

                ; r18: copy BT_NAME -> TCB_NAME if BT_NAME[0] != 0.
                ; Source = $00:BT_NAME (kernel page-zero buffer).
                ; Dest   = X1 + TCB_NAME (X1 still holds TCB ptr).
                ; Copies up to 31 bytes plus a guaranteed nul at byte 31.
                ; Y1 is already $00, Y2 already $00 (kernel page).
                ;
                ; D2 = byte counter (max 31).
                ; XY2 = source ptr (start at BT_NAME).
                ; Use XY0 for dest (caller-clobber friendly here — _BuildTask
                ; doesn't preserve XY0).
                LOADI   X2, #BT_NAME
                LOADB   D0, [XY2]
                CMP     D0, #0
                BEQ     .name_done              ; empty -> leave zero-filled

                MOVE    Y0, Y1                  ; Y0 = $00 (kernel page)
                MOVE    X0, X1                  ; X0 = TCB ptr
                ADD     X0, #TCB_NAME           ; X0 -> TCB+$60

                LOADI   D2, #31                 ; cap at 31 chars
.name_loop:
                LOADB   D0, [XY2]
                STOREB  D0, [XY0]
                CMP     D0, #0
                BEQ.S   .name_done              ; copied the nul; stop
                ADD     X2, #1
                ADD     X0, #1
                SUB     D2, #1
                BNE     .name_loop

                ; Ran out of budget — force nul at TCB+TCB_NAME+31.
                LOADI   D0, #0
                STOREB  D0, [XY0]
.name_done:

                ; Parent id from scratch slot (0 = kernel by default)
                LOADZ   D0, [#BT_PARENT_ID]
                STORED  D0, [XY1+#TCB_PARENT_ID]

                ; Task ID = TASK_COUNT + 1 (word)
                LOADZ   D0, [#TASK_COUNT]
                ADD     D0, #1
                STORED  D0, [XY1+#TCB_ID]

                ; -------- Build fake INT frame in task's primary page --------
                ; XY2 = pointer into task page; X2 walks through the frame.
                LOADZ   D0, [#BT_PRIMARY]
                MOVE    Y2, D0

                ; Layout (matches emulator's INT push convention, verified
                ; in ExecINT: PC[15:0] → higher addr, PC[23:16] → lower addr):
                ;
                ;   Initial X3 (before INT) = $FFF6
                ;   INT pushes (in order):
                ;     PC[15:0]  → lands at $FFF4   (higher addr)
                ;     PC[23:16] → lands at $FFF2   (page byte word)
                ;     SR        → lands at $FFF0   (lowest, popped first)
                ;   Final X3 after INT push = $FFF0
                ;
                ;   Then ISR prologue pushes D, XY0, XY1, XY2 (20 bytes):
                ;     PUSH D    → $FFE8..$FFEF
                ;     PUSH XY0  → $FFE4..$FFE7
                ;     PUSH XY1  → $FFE0..$FFE3
                ;     PUSH XY2  → $FFDC..$FFDF
                ;   Final saved_x = $FFDC

                ; Write SR at $FFF0 (IE=1, all flags clear)
                LOADI   X2, #$FFF0
                LOADI   D0, #$0080
                STORED  D0, [XY2]

                ; Write PC page byte at $FFF2
                LOADI   X2, #$FFF2
                LOADZ   D0, [#BT_ENTRY_PG]
                STORED  D0, [XY2]

                ; Write PC low word at $FFF4
                LOADI   X2, #$FFF4
                LOADZ   D0, [#BT_ENTRY_LO]
                STORED  D0, [XY2]

                ; Pre-fill $FFDC..$FFEE with zeros (10 words)
                LOADI   D0, #0
                LOADI   X2, #$FFDC
.zero:
                STORED  D0, [XY2]+
                CMP     X2, #$FFF0
                BLO     .zero

                ; -------- Populate task-local OS slots ---------------------
                ; Per Part 1 §4.4: first 256 bytes of each task's primary
                ; page hold OS-reserved task-private state, reachable in
                ; one instruction via LOADP/STOREP with Y3 = task page.
                ; Y2 still holds primary page from frame-build above.
                ;
                ; MY_TCB_PTR ← TCB low word (X1). Page is always $00 so
                ; only the low word is stored; readers know to use Y=$00.
                LOADI   X2, #MY_TCB_PTR
                MOVE    D0, X1
                STORED  D0, [XY2]

                ; TASK_ID ← same value just stored in TCB_ID
                LOADI   X2, #TASK_ID
                LOADZ   D0, [#TASK_COUNT]
                ADD     D0, #1
                STORED  D0, [XY2]

                ; Set saved_x = $FFDC
                LOADI   D0, #$FFDC
                STORED  D0, [XY1+#TCB_SAVED_X]

                ; Add TCB to ready queue
                MOVE    D0, X1
                CALL24  _AddToRunQueue

                ; Return TCB ptr
                MOVE    D0, X1
                CLC
                BRA.S     .done

.fail:
                LOADI   D0, #0
                SEC

.done:
                POP     XY2, XY3
                POP     XY1, XY3
                POP     D2, XY3
                POP     D1, XY3
                RET

; ============================================================================
; End of kos_tcb.asm
; ============================================================================
