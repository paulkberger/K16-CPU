; ============================================================================
; kos_sem.asm — k/OS counting semaphores (Part 20b)
; ============================================================================
; Date:    9 May 2026
; Status:  Part 22 — kernel-context blocking helpers added; pool relocated.
;
; Revision: r2 — 9 May 2026 — Part 22:
;             • SEM_POOL_BASE moved from $03C8 to $0400. The volume table
;               grew from 3 slots ($0260..$031F) to 6 slots ($0260..$03DF)
;               for the host-disk backend (C: D: E: F: are host bays 0..3).
;               FAT cache moved to $03E0..$03EF. The sem pool now lives in
;               $0400..$047F. _ValidateSem's alignment check (low 3 bits
;               zero) is still correct: $0400 is 8-aligned.
;             • Added _SemBlockYield — kernel-context block-and-schedule
;               helper. Mirrors sys_semtake's inlined block dance, but as
;               a CALLR-reachable subroutine that resumes at the call site
;               instead of via RTI. Sets TF_SEM_KERNEL_WAITER on the TCB
;               before _Schedule.
;             • Added _SemTakeBlocking — retry loop around _SemTakeTry and
;               _SemBlockYield. Standard kernel-side blocking sem-take.
;             • _SemGive's wake path now skips _SemDeliverWake patching
;               for waiters with TF_SEM_KERNEL_WAITER set. Those waiters
;               retry _SemTakeTry on resume (via _SemTakeBlocking's loop)
;               rather than receiving a patched RTI result. The flag is
;               cleared in the wake path so it doesn't persist.
;             • These extensions are forward-looking: today's kernel runs
;               with DINT in effect across all syscalls, so the disk
;               semaphore (the first user) never sees real contention.
;               The block path lands correctly but won't fire until
;               kernel preemption mid-syscall is enabled (Phase 4+).
;
; Revision: r1 — 8 May 2026 — initial.
;             • _SemCreate / _SemDestroy / _SemGive   kernel helpers (leaf)
;             • _SemTakeTry                           kernel "policy" helper
;                                                     (validate + decrement
;                                                     or enqueue; never
;                                                     touches scheduler)
;             • sys_semcreate (#33), sys_semgive (#35), sys_semdestroy (#36)
;                                                     leaf TRAP wrappers
;             • sys_semtake (#34)                     non-leaf TRAP wrapper
;                                                     with inlined block
;                                                     path
;             • Per-sem state lives in SEM_POOL at $00:$0400 (8 bytes
;               each × 16 entries = 128 bytes; ends $0480).
;             • TS_SEMWAIT (=5) added to TCB state enum (kos_defs.inc r21+).
;             • TCB_SEM_NEXT (=$20) added to TCB layout in TCB_RESERVED
;               zone (kos_defs.inc r21+).
;
; --- Why "policy" + inline-block split -------------------------------------
;
; _SemTake cannot exist as a single subroutine that "may block", because
; the slow path requires the calling TRAP wrapper's frame to remain on
; the stack while the caller is task-switched out. A subroutine's own
; PUSH/POP of locals would only be balanced if the same task resumed —
; but on a sem block the resume happens at an arbitrary later time,
; possibly never on the original task. Calling _Schedule from inside
; a subroutine, then resuming on a *different* task's stack and POP-ing
; the original task's locals would corrupt the resumed task's state.
;
; The solution mirrors how sys_yield / sys_wait / sys_sleep are built:
; the non-leaf prologue (PUSH SR / DINT / PUSH D, XY0..XY2) is in the
; TRAP wrapper itself, the body is inlined, and the epilogue is the
; canonical POP XY2..XY0, POP D, RTI shape. The shared epilogue is
; reached on every task switch — including the wake-up of a previously
; blocked task — and it always pops from the right stack because each
; task's stack independently carries its own PUSH'd state.
;
; _SemTakeTry is therefore a leaf "decide" routine: it inspects/updates
; the sem slot and decides whether the caller must block. It does NOT
; pivot to kernel and does NOT call _Schedule. The caller (sys_semtake's
; inline body) handles the scheduler dance directly.
;
; Future kernel-internal blockable sem users (e.g. the disk driver's
; _BlockRead) follow the same pattern: their non-leaf TRAP wrapper
; calls _SemTakeTry; on "must block" return, the wrapper inlines the
; block dance — typically as a CALLR to a shared `_SemBlockAndSched`
; helper which pivots, calls _Schedule, restores incoming, exits via
; the wrapper's own RTI. This file does not need that helper yet
; because the only blockable sem user is sys_semtake itself; we'll
; refactor when the disk driver lands.
;
; --- Per-sem layout (8 bytes) ----------------------------------------------
;
;   $00 SEM_COUNT   word  signed; ≤ 0 implies waiters are present
;   $02 SEM_HEAD    word  TCB ptr of first waiter (0 = no waiters)
;   $04 SEM_TAIL    word  TCB ptr of last waiter (FIFO insertion)
;   $06 SEM_FLAGS   word  bit 0 = in-use, others reserved
;
; --- Wait queue linkage ----------------------------------------------------
;
; Each TCB has a TCB_SEM_NEXT field at $20 (in the TCB_RESERVED zone).
; When a task is parked on a sem wait queue, its TCB_SEM_NEXT points
; at the next waiter (0 at tail). The task's TCB_NEXT_TCB still points
; at the next ready-ring entry; _Schedule's state-skip scan handles
; non-TS_READY entries, so the waiter is invisible to the scheduler
; without ever being unlinked from the ready ring. Symmetric with how
; TS_BLOCKED (sys_sleep) and TS_WAITING (sys_wait) work.
;
; --- Wakeup result delivery ------------------------------------------------
;
; When _SemGive unblocks a waiter, it pokes ERR_OK into the waiter's
; saved-D0 stack slot and writes a success SR ($0080: IE=1, C=0) into
; the waiter's saved-SR slot — same trick as _DeliverWaitResult in
; kos_spawn.asm. The waiter's RTI epilogue then loads D0 and SR from
; the saved group, delivering success cleanly back to user.
;
; ============================================================================

; ============================================================================
; SEM_POOL — 16 semaphores × 8 bytes each
;
; A semaphore handle is the absolute address (low word; page=$00) of
; its 8-byte slot. Range: $0400..$0478 (last slot at $0478..$047F).
; ============================================================================
SEM_POOL_BASE   .EQU    $0400               ; first byte
SEM_POOL_END    .EQU    $0480               ; one past last byte ($0400+128)
SEM_COUNT_MAX   .EQU    16                  ; number of sem slots
SEM_SLOT_SIZE   .EQU    8                   ; bytes per slot

SEM_COUNT       .EQU    $00                 ; word — current count (signed)
SEM_HEAD        .EQU    $02                 ; word — first waiter TCB ptr
SEM_TAIL        .EQU    $04                 ; word — last waiter TCB ptr
SEM_FLAGS       .EQU    $06                 ; word — flags

SEM_FLAG_INUSE  .EQU    $0001

; --- _SemTakeTry return convention ------------------------------------------
; D0 result codes:
;   ERR_OK      — count was positive, decremented, NO BLOCK NEEDED
;   ERR_BUSY    — count was ≤0, caller is enqueued, MUST BLOCK
;   ERR_INVALID — bad handle
;
; ERR_BUSY isn't a real error — it's a flow-control indicator. We
; reuse the unallocated $FFF6 slot for this. (No need to add to
; kos_defs.inc — only kos_sem.asm references it.)
SEM_BUSY        .EQU    $FFF6               ; "decision: must block"

; ============================================================================
; _InitSemPool — zero all sem slots, mark all free
;
;   In:    none
;   Out:   none
;   Clobbers: D0, D1, XY0, flags
;
; Called once at boot from kos_boot.asm's _InitKernel.
; ============================================================================
_InitSemPool:
                LOADI   Y0, #$00
                LOADI   X0, #SEM_POOL_BASE
                LOADI   D1, #SEM_POOL_END - SEM_POOL_BASE
                LOADI   D0, #0
.zero_loop:
                STOREB  D0, [XY0]
                INC     XY0, #1
                SUB     D1, #1
                BNE     .zero_loop
                RET

; ============================================================================
; _SemCreate — allocate a fresh semaphore from the pool
;
;   In:    D0 = initial count (signed; typically 0 or 1)
;   Out:   D0 = handle (low word), C=0 on success
;          D0 = ERR_NOSLOTS, C=1 if pool full
;   Clobbers: D0, D1, X0, X1, Y0, Y1, flags
;   Preserves: D2, D3, XY2, XY3
; ============================================================================
_SemCreate:
                PUSH    D2, XY3
                PUSH    XY1, XY3

                ; D2 = initial count, preserved across the scan.
                MOVE    D2, D0

                LOADI   Y1, #$00
                LOADI   X1, #SEM_POOL_BASE

.scan:
                LOADD   D1, [XY1+#SEM_FLAGS]
                AND     D1, #SEM_FLAG_INUSE
                BEQ     .found

                ; Advance.
                INC     XY1, #SEM_SLOT_SIZE
                MOVE    D1, X1
                CMP     D1, #SEM_POOL_END
                BLO     .scan

                ; Pool full.
                LOADI   D0, #ERR_NOSLOTS
                SEC
                BRA     .done

.found:
                ; Init: count := initial, head/tail := 0, flags := IN_USE
                STORED  D2, [XY1+#SEM_COUNT]
                LOADI   D1, #0
                STORED  D1, [XY1+#SEM_HEAD]
                STORED  D1, [XY1+#SEM_TAIL]
                LOADI   D1, #SEM_FLAG_INUSE
                STORED  D1, [XY1+#SEM_FLAGS]

                ; Return handle in D0 (low word).
                MOVE    D0, X1
                CLC

.done:
                POP     XY1, XY3
                POP     D2, XY3
                RET

; ============================================================================
; _SemDestroy — release a semaphore back to the pool
;
;   In:    D0 = handle
;   Out:   D0 = ERR_OK / ERR_INVALID / ERR_BADARG, C=0/1
;   Clobbers: D0, D1, X0, X1, Y0, Y1, flags
;   Preserves: D2, D3, XY2, XY3
;
; Refuses if waiters present (ERR_BADARG).
; ============================================================================
_SemDestroy:
                PUSH    XY1, XY3

                CALLR   _ValidateSem            ; XY1 = slot, or C=1
                BCS     .err

                LOADD   D1, [XY1+#SEM_HEAD]
                CMP     D1, #0
                BNE     .busy

                ; Hygiene: zero the slot.
                LOADI   D1, #0
                STORED  D1, [XY1+#SEM_COUNT]
                STORED  D1, [XY1+#SEM_HEAD]
                STORED  D1, [XY1+#SEM_TAIL]
                STORED  D1, [XY1+#SEM_FLAGS]

                LOADI   D0, #ERR_OK
                CLC
                BRA     .done

.busy:
                LOADI   D0, #ERR_BADARG
                SEC
                BRA.S   .done

.err:
                ; D0/C set by _ValidateSem
                SEC

.done:
                POP     XY1, XY3
                RET

; ============================================================================
; _ValidateSem — verify a handle and resolve to slot pointer in XY1
;
;   In:    D0 = candidate handle
;   Out:   XY1 = slot pointer, C=0 on success
;          D0 = ERR_INVALID, C=1 on bad handle
;   Clobbers: D0, D1, XY1, flags
;   Preserves: D2, D3, XY0, XY2
;
; Valid handle = in [SEM_POOL_BASE..SEM_POOL_END), 8-aligned, in-use.
; ============================================================================
_ValidateSem:
                ; Range
                CMP     D0, #SEM_POOL_BASE
                BLO     .bad
                MOVE    D1, D0
                CMP     D1, #SEM_POOL_END
                BHS     .bad

                ; Alignment (low 3 bits zero — base is $0400, 8-aligned).
                MOVE    D1, D0
                AND     D1, #$0007
                BNE     .bad

                ; In-use?
                LOADI   Y1, #$00
                MOVE    X1, D0
                LOADD   D1, [XY1+#SEM_FLAGS]
                AND     D1, #SEM_FLAG_INUSE
                BEQ.S   .bad

                RETCC

.bad:
                LOADI   D0, #ERR_INVALID
                RETCS

; ============================================================================
; _SemTakeTry — decide-and-update for sem-take. NEVER BLOCKS.
;
;   In:    D0 = handle
;   Out:   D0 = ERR_OK     — count was positive, decremented; no block
;          D0 = SEM_BUSY   — count was ≤ 0, caller enqueued; MUST BLOCK
;          D0 = ERR_INVALID — bad handle
;          C  = 0 on ERR_OK, 1 otherwise
;   Clobbers: D0, D1, X0, X1, Y0, Y1, flags
;   Preserves: D2, D3, XY2, XY3
;
; Caller's responsibilities on SEM_BUSY:
;   1. Save outgoing X3/Y3 in self TCB.
;   2. Mark TCB_STATE = TS_SEMWAIT.
;   3. Pivot to kernel stack and CALL24 _Schedule.
;   4. On wake (some future _Schedule selects this task), restore
;      incoming X3/Y3 from CURRENT_TCB and exit via the canonical
;      non-leaf RTI epilogue. _SemGive will have already patched the
;      saved-D0 / saved-SR slots to deliver success.
;
; This routine performs the queue insertion (caller becomes new tail)
; and the count decrement before returning SEM_BUSY. So by the time
; the caller starts the block dance, the data structures are already
; consistent.
; ============================================================================
_SemTakeTry:
                PUSH    D2, XY3
                PUSH    D3, XY3
                PUSH    XY1, XY3
                PUSH    XY2, XY3

                CALLR   _ValidateSem            ; XY1 = slot, or C=1
                BCS     .err

                ; Inspect count.
                LOADD   D1, [XY1+#SEM_COUNT]
                CMP     D1, #0
                BLE     .must_block             ; signed: ≤ 0 → block

                ; Fast path: positive count, decrement, return ERR_OK.
                SUB     D1, #1
                STORED  D1, [XY1+#SEM_COUNT]
                LOADI   D0, #ERR_OK
                CLC
                BRA     .done

.must_block:
                ; Enqueue self at tail of wait queue.
                ; XY2 = self TCB.
                LOADZ   D1, [#CURRENT_TCB]
                LOADI   Y2, #$00
                MOVE    X2, D1

                ; self.TCB_SEM_NEXT := 0 (we're new tail).
                ; TCB_SEM_NEXT = $20 is just outside IMM5 range (0..31),
                ; so use mode-01 [XY+D] addressing instead of mode-11
                ; [XY+#imm5]. Pattern from kos_fs.asm _VolBlockWrite.
                LOADI   D2, #0
                LOADI   D1, #TCB_SEM_NEXT
                STORED  D2, [XY2+D1]

                ; Empty queue? → self is both head and tail.
                LOADD   D2, [XY1+#SEM_HEAD]
                CMP     D2, #0
                BNE.S   .have_tail

                MOVE    D2, X2                  ; D2 = self ptr
                STORED  D2, [XY1+#SEM_HEAD]
                STORED  D2, [XY1+#SEM_TAIL]
                BRA     .enqueued

.have_tail:
                ; old_tail.TCB_SEM_NEXT := self
                LOADD   D3, [XY1+#SEM_TAIL]
                LOADI   Y0, #$00
                MOVE    X0, D3
                MOVE    D2, X2                  ; D2 = self ptr
                LOADI   D1, #TCB_SEM_NEXT       ; mode-01 offset (out of IMM5)
                STORED  D2, [XY0+D1]
                ; tail := self
                STORED  D2, [XY1+#SEM_TAIL]

.enqueued:
                ; SEM_COUNT-- (count tracks logical units; goes negative).
                LOADD   D2, [XY1+#SEM_COUNT]
                SUB     D2, #1
                STORED  D2, [XY1+#SEM_COUNT]

                ; Signal "must block" to caller.
                LOADI   D0, #SEM_BUSY
                SEC
                BRA.S   .done

.err:
                ; D0 = ERR_INVALID, C=1 (set by _ValidateSem)
                SEC

.done:
                POP     XY2, XY3
                POP     XY1, XY3
                POP     D3, XY3
                POP     D2, XY3
                RET

; ============================================================================
; _SemGive — increment a semaphore; wake one waiter if any. LEAF.
;
;   In:    D0 = handle
;   Out:   D0 = ERR_OK / ERR_INVALID, C=0/1
;   Clobbers: D0, D1, X0, X1, Y0, Y1, flags
;   Preserves: D2, D3, XY2, XY3
; ============================================================================
_SemGive:
                PUSH    D2, XY3
                PUSH    XY1, XY3
                PUSH    XY2, XY3

                CALLR   _ValidateSem            ; XY1 = slot, or C=1
                BCS     .err

                ; Any waiters?
                LOADD   D1, [XY1+#SEM_HEAD]
                CMP     D1, #0
                BEQ     .nowaiter

                ; Wake head waiter. XY2 = head TCB.
                LOADI   Y2, #$00
                MOVE    X2, D1

                ; Unlink: head := head.TCB_SEM_NEXT
                ; TCB_SEM_NEXT = $20 is out of IMM5 range; use [XY+D].
                LOADI   D1, #TCB_SEM_NEXT
                LOADD   D2, [XY2+D1]
                STORED  D2, [XY1+#SEM_HEAD]

                ; If queue now empty, clear tail too.
                CMP     D2, #0
                BNE.S   .clr_done
                LOADI   D2, #0
                STORED  D2, [XY1+#SEM_TAIL]
.clr_done:

                ; Defensive: clear woken task's TCB_SEM_NEXT.
                ; (D1 still holds #TCB_SEM_NEXT from unlink read.)
                LOADI   D2, #0
                STORED  D2, [XY2+D1]

                ; Bump SEM_COUNT (it was negative — restoring one slot).
                LOADD   D2, [XY1+#SEM_COUNT]
                ADD     D2, #1
                STORED  D2, [XY1+#SEM_COUNT]

                ; Patch waiter's saved-D0 / saved-SR for success delivery —
                ; ONLY if waiter is a TRAP-context blocker. Kernel-context
                ; blockers (TF_SEM_KERNEL_WAITER set) retry _SemTakeTry on
                ; resume instead of receiving a patched RTI result, so we
                ; must NOT touch their stack frames (which aren't shaped
                ; like a non-leaf TRAP frame).
                LOADD   D2, [XY2+#TCB_FLAGS]
                AND     D2, #TF_SEM_KERNEL_WAITER
                BNE.S   .skip_deliver

                CALLR   _SemDeliverWake         ; uses XY2
                BRA.S   .mark_ready

.skip_deliver:
                ; Clear the kernel-waiter flag so it doesn't persist if the
                ; same task later blocks via the TRAP path.
                LOADD   D2, [XY2+#TCB_FLAGS]
                AND     D2, #$FFFE              ; clear bit 0 (TF_SEM_KERNEL_WAITER)
                STORED  D2, [XY2+#TCB_FLAGS]

.mark_ready:
                ; Mark waiter TS_READY (state-skip scheduler picks up next).
                LOADI   D2, #TS_READY
                STORED  D2, [XY2+#TCB_STATE]
                BRA.S   .ok

.nowaiter:
                ; No waiters: just bump count.
                LOADD   D1, [XY1+#SEM_COUNT]
                ADD     D1, #1
                STORED  D1, [XY1+#SEM_COUNT]

.ok:
                LOADI   D0, #ERR_OK
                CLC
                BRA.S   .done

.err:
                ; D0/C set by _ValidateSem
                SEC

.done:
                POP     XY2, XY3
                POP     XY1, XY3
                POP     D2, XY3
                RET

; ============================================================================
; _SemDeliverWake — patch a waiter's saved-D0 / saved-SR to success
;
;   In:    XY2 = waiter TCB ptr
;   Out:   none
;   Clobbers: D0, D1, X0, X1, Y0, Y1, flags
;   Preserves: D2, D3, XY2, XY3
;
; The waiter's user stack frame at TCB_SAVED_X looks like (top of stack
; first, growing down — matches sys_yield/sys_wait epilogue layout):
;
;   [X3+0]  XY2 (high)        \
;   [X3+2]  XY2 (low)          | PUSH XY2, XY3
;   [X3+4]  XY1 (high)         | PUSH XY1, XY3
;   [X3+6]  XY1 (low)          | PUSH XY0, XY3
;   [X3+8]  XY0 (high)         | PUSH D, XY3 — pushes D3, D2, D1, D0
;   [X3+10] XY0 (low)          | (high addresses of the D group are
;   [X3+12] D3                 |  D0 — pushed first ⇒ deepest in stack)
;   [X3+14] D2                 |
;   [X3+16] D1                 |
;   [X3+18] D0                /
;   [X3+20] SR                  PUSH SR, XY3 (from non-leaf prologue)
;   [X3+22] return PC (low)     pushed by hardware on TRAP
;   [X3+24] return PC (high)
;
; So +18 = saved D0, +20 = saved SR. Identical to kos_spawn.asm's
; _DeliverWaitResult.
; ============================================================================
_SemDeliverWake:
                ; Build XY1 = absolute pointer to waiter's user stack top.
                LOADD   D0, [XY2+#TCB_SAVED_X]
                LOADD   D1, [XY2+#TCB_SAVED_Y]
                MOVE    Y1, D1
                MOVE    X1, D0

                ; Patch saved-D0 ← ERR_OK.
                LOADI   D0, #ERR_OK
                STORED  D0, [XY1+#18]

                ; Patch saved-SR ← $0080 (IE=1, C=0 = success).
                LOADI   D0, #$0080
                STORED  D0, [XY1+#20]

                RET

; ============================================================================
; _SemBlockYield — kernel-context block-and-schedule helper (Part 22)
;
;   In:    (none — operates on CURRENT_TCB)
;   Out:   (none — task suspends; on resume, returns normally)
;   Clobbers: D0, D1, X3, Y3 (X3/Y3 are restored from TCB on resume)
;   Preserves: D2, D3, XY0, XY1, XY2 (caller's responsibility — see below)
;
; This helper is the kernel-context counterpart to sys_semtake's inlined
; block dance. Use it when a CALL24-reachable kernel routine (e.g. the
; disk driver's _BlockReadHost) discovers via _SemTakeTry that it must
; block, but cannot itself be a non-leaf TRAP wrapper.
;
; Difference from the TRAP path: the waiter is NOT delivered a patched
; saved-D0 / saved-SR via RTI. Instead, the waiter resumes at the
; instruction after CALL24 _SemBlockYield, with X3/Y3 restored from
; TCB_SAVED_X/Y. The caller is expected to re-attempt _SemTakeTry on
; resume (the standard idiom: see _SemTakeBlocking below).
;
; Stack discipline:
;   _SemBlockYield itself does NOT push anything to the caller's stack
;   between the save-X3/Y3 and the call to _Schedule. This avoids
;   Gotcha #32 (mismatched POPs across schedule). The caller's locals
;   are saved in the caller's own frame on the caller's stack; that
;   stack pointer is captured in TCB_SAVED_X and restored on resume.
;
; The TF_SEM_KERNEL_WAITER flag is set on the TCB before _Schedule,
; telling _SemGive's wake path to skip its saved-D0/SR patching for
; this waiter.
; ============================================================================
_SemBlockYield:
                ; XY1 = self TCB.
                LOADZ   D0, [#CURRENT_TCB]
                LOADI   Y1, #$00
                MOVE    X1, D0

                ; self.TCB_FLAGS |= TF_SEM_KERNEL_WAITER
                LOADD   D1, [XY1+#TCB_FLAGS]
                OR      D1, #TF_SEM_KERNEL_WAITER
                STORED  D1, [XY1+#TCB_FLAGS]

                ; self.TCB_STATE := TS_SEMWAIT
                LOADI   D0, #TS_SEMWAIT
                STORED  D0, [XY1+#TCB_STATE]

                ; Save outgoing X3, Y3 — call site's stack pointer.
                ; On resume we restore exactly these values, so the
                ; caller's stack frame is intact and execution continues
                ; right after the CALL24 to this routine.
                MOVE    D0, X3
                STORED  D0, [XY1+#TCB_SAVED_X]
                MOVE    D0, Y3
                STORED  D0, [XY1+#TCB_SAVED_Y]

                ; Bump yield counter.
                LOADD   D0, [XY1+#TCB_YIELD_COUNT]
                ADD     D0, #1
                STORED  D0, [XY1+#TCB_YIELD_COUNT]

                ; Pivot to kernel stack and schedule.
                LOADI   Y3, #$00
                LOADI   X3, #KERNEL_STACK_TOP

                CALL24  _Schedule

                ; ===== RESUME POINT =====================================
                ; A future _Schedule has selected this task because
                ; _SemGive marked it TS_READY. CURRENT_TCB == self TCB.
                ; Restore X3, Y3 from TCB so we return to caller cleanly.

                LOADZ   D0, [#CURRENT_TCB]
                LOADI   Y1, #$00
                MOVE    X1, D0

                LOADD   D0, [XY1+#TCB_SAVED_X]
                MOVE    X3, D0
                LOADD   D0, [XY1+#TCB_SAVED_Y]
                MOVE    Y3, D0

                ; The TF_SEM_KERNEL_WAITER flag was already cleared by
                ; _SemGive's .skip_deliver path before TS_READY was set.
                RET

; ============================================================================
; _SemTakeBlocking — kernel-context blocking sem-take (Part 22)
;
;   In:    D0  = handle
;   Out:   D0  = ERR_OK on success, C=0 (eventually — may block first)
;          D0  = ERR_INVALID on bad handle, C=1
;   Clobbers: D0, D1, flags
;   Preserves: D2, D3, XY0, XY1, XY2, XY3
;
; Standard retry loop around _SemTakeTry + _SemBlockYield. Used by the
; disk driver and any other kernel-context blockable sem user.
;
; The handle is parked in D2 across the loop; D2 is preserved across both
; _SemTakeTry (its documented ABI) and _SemBlockYield (preserves D2/D3/XY).
; This keeps the handle in a per-task register rather than a shared
; page-zero slot — important when the kernel becomes preemptable mid-syscall.
;
; Note: this routine PUSHes nothing across _SemBlockYield, so the
; Gotcha #32 stack-mismatch issue doesn't apply. _SemTakeTry is a
; self-contained leaf and _SemBlockYield manages its own (TCB-based)
; save/restore.
; ============================================================================
_SemTakeBlocking:
                PUSH    D2, XY3                 ; preserve caller's D2

                ; Stash handle in D2 (preserved across _SemTakeTry and
                ; _SemBlockYield).
                MOVE    D2, D0

.retry:
                MOVE    D0, D2                  ; D0 = handle
                CALLR   _SemTakeTry
                BCC     .got_it                 ; ERR_OK — fast path

                CMP     D0, #SEM_BUSY
                BNE     .err                    ; ERR_INVALID — propagate

                ; SEM_BUSY: enqueued, count decremented. Yield CPU.
                CALLR   _SemBlockYield

                ; On wake: retry the take. We've been re-readied and the
                ; sem state has been advanced (count bumped) by the
                ; _SemGive that woke us. Loop will succeed unless another
                ; task has stolen the slot — in which case we re-block.
                BRA     .retry

.got_it:
                ; D0 = ERR_OK, C=0
                POP     D2, XY3                 ; POP doesn't disturb flags
                RET

.err:
                ; D0 = ERR_INVALID, C=1 from _SemTakeTry
                POP     D2, XY3
                RET


; ============================================================================
; sys_semcreate — TRAP #33 — create a counting semaphore.   LEAF.
;
;   In:    D0 = initial count
;   Out:   D0 = handle, C=0
;          D0 = ERR_NOSLOTS, C=1
; ============================================================================
sys_semcreate:
                DINT
                ; V2 ABI saves done by _SemCreate internally, but we
                ; still need to wrap DINT/EINT for atomicity.
                ; (D2 is preserved by _SemCreate; D3, XY2 untouched.)

                ; Part 36: _SemCreate declares 'Clobbers: D1' in its header
                ; (from the pre-Part-34 ABI). The TRAP boundary now must
                ; preserve D1, so we PUSH/POP it around the CALLR.
                PUSH    D1, XY3
                CALLR   _SemCreate
                POP     D1, XY3

                ; D0 is the return value — stash across the EINT gate.
                ; (Part 36: was D1-scratch; D1 is now callee-preserved
                ; per V2 ABI.)
                PUSH    SR, XY3
                PUSH    D0, XY3
                LOADZ   D0, [#KERNEL_STATE]
                LOW     D0
                CMP     D0, #KERN_STATE_RUN
                POP     D0, XY3
                BNE.S   .sc_skip_eint
                EINT
.sc_skip_eint:
                POP     SR, XY3
                RET

; ============================================================================
; sys_semdestroy — TRAP #36 — destroy a semaphore.   LEAF.
;
;   In:    D0 = handle
;   Out:   D0 = ERR_OK / ERR_INVALID / ERR_BADARG, C=0/1
; ============================================================================
sys_semdestroy:
                DINT

                ; Part 36: _SemDestroy clobbers D1 (per its header) —
                ; preserve caller's D1 across the boundary.
                PUSH    D1, XY3
                CALLR   _SemDestroy
                POP     D1, XY3

                ; D0 is the return value — stash across the EINT gate.
                ; (Part 36: was D1-scratch.)
                PUSH    SR, XY3
                PUSH    D0, XY3
                LOADZ   D0, [#KERNEL_STATE]
                LOW     D0
                CMP     D0, #KERN_STATE_RUN
                POP     D0, XY3
                BNE.S   .sd_skip_eint
                EINT
.sd_skip_eint:
                POP     SR, XY3
                RET

; ============================================================================
; sys_semgive — TRAP #35 — V() / signal / up.   LEAF.
;
;   In:    D0 = handle
;   Out:   D0 = ERR_OK / ERR_INVALID, C=0/1
; ============================================================================
sys_semgive:
                DINT

                ; Part 36: _SemGive clobbers D1 (per its header) —
                ; preserve caller's D1 across the boundary.
                PUSH    D1, XY3
                CALLR   _SemGive
                POP     D1, XY3

                ; D0 is the return value — stash across the EINT gate.
                ; (Part 36: was D1-scratch.)
                PUSH    SR, XY3
                PUSH    D0, XY3
                LOADZ   D0, [#KERNEL_STATE]
                LOW     D0
                CMP     D0, #KERN_STATE_RUN
                POP     D0, XY3
                BNE.S   .sg_skip_eint
                EINT
.sg_skip_eint:
                POP     SR, XY3
                RET

; ============================================================================
; sys_semtake — TRAP #34 — P() / wait / down.   NON-LEAF (may block).
;
;   In:    D0 = handle
;   Out:   D0 = ERR_OK on resume after grant, C=0
;          D0 = ERR_INVALID on bad handle, C=1
;
; Standard non-leaf prologue. Body inlines _SemTakeTry; on SEM_BUSY,
; inlines the block-and-schedule dance. On fast path or error,
; patches saved-D0 / saved-SR and falls through to the canonical
; epilogue. On block path, _Schedule yields control; later _SemGive
; on this handle will patch our saved-D0 / saved-SR and re-mark us
; TS_READY, and a future _Schedule entry will resume us at the
; epilogue.
; ============================================================================
sys_semtake:
                PUSH    SR, XY3
                DINT

                PUSH    D0, XY3
                PUSH    D123, XY3
                PUSH    XY0, XY3
                PUSH    XY1, XY3
                PUSH    XY2, XY3

                ; Recover handle from saved-D0 slot.
                LOADD   D0, [XY3+#18]

                CALLR   _SemTakeTry
                ; Three possible returns:
                ;   ERR_OK    (C=0) — fast path, count was positive
                ;   SEM_BUSY  (C=1) — must block; _SemTakeTry already
                ;                     enqueued us and decremented count
                ;   ERR_INVALID (C=1) — bad handle

                BCC     .st_fast_ok             ; C=0 ⇒ fast path success

                ; C=1. Distinguish SEM_BUSY from ERR_INVALID.
                CMP     D0, #SEM_BUSY
                BEQ     .st_block

                ; ERR_INVALID — patch failure into saved-D0/SR and exit.
                STORED  D0, [XY3+#18]           ; saved D0 ← ERR_INVALID
                LOADI   D0, #$0081              ; SR: IE=1, C=1
                STORED  D0, [XY3+#20]
                BRA     .st_eint

.st_fast_ok:
                ; Patch saved-D0/SR with success (D0 already ERR_OK).
                STORED  D0, [XY3+#18]           ; saved D0 ← ERR_OK
                LOADI   D0, #$0080              ; SR: IE=1, C=0
                STORED  D0, [XY3+#20]
                BRA     .st_eint

.st_block:
                ; ===== BLOCK PATH ======================================
                ; _SemTakeTry has already:
                ;   • enqueued self on the sem's wait queue
                ;   • decremented SEM_COUNT
                ; We must now:
                ;   • mark self TS_SEMWAIT
                ;   • save outgoing X3/Y3
                ;   • bump yield counter
                ;   • pivot to kernel and call _Schedule
                ;   • on resume, restore incoming X3/Y3 and fall through
                ;     to the shared epilogue (the saved-D0/SR will have
                ;     been patched by whichever _SemGive woke us).

                ; XY1 = self TCB
                LOADZ   D0, [#CURRENT_TCB]
                LOADI   Y1, #$00
                MOVE    X1, D0

                ; self.TCB_STATE := TS_SEMWAIT
                LOADI   D0, #TS_SEMWAIT
                STORED  D0, [XY1+#TCB_STATE]

                ; Save outgoing X3, Y3.
                MOVE    D0, X3
                STORED  D0, [XY1+#TCB_SAVED_X]
                MOVE    D0, Y3                  ; D0 = $00xx
                STORED  D0, [XY1+#TCB_SAVED_Y]

                ; Bump yield counter.
                LOADD   D0, [XY1+#TCB_YIELD_COUNT]
                ADD     D0, #1
                STORED  D0, [XY1+#TCB_YIELD_COUNT]

                ; Pivot to kernel.
                LOADI   Y3, #$00
                LOADI   X3, #KERNEL_STACK_TOP

                ; Schedule.
                CALL24  _Schedule

                ; ===== RESUME POINT ====================================
                ; We're either:
                ;   (a) just woken — _Schedule has set CURRENT_TCB to
                ;       this task because _SemGive marked us TS_READY,
                ;       OR
                ;   (b) running as some other task that was previously
                ;       blocked here — but in that case the CALL24
                ;       _Schedule above resolved to that task and we're
                ;       running its post-_Schedule code with its X3/Y3
                ;       (after the restore below).
                ; In both cases the same code path is correct.

                LOADZ   D0, [#CURRENT_TCB]
                CMP     D0, #IDLE_TCB
                BEQ     .st_to_idle

                ; XY1 = incoming TCB
                LOADI   Y1, #$00
                MOVE    X1, D0

                LOADD   D0, [XY1+#TCB_SAVED_X]
                MOVE    X3, D0
                LOADD   D0, [XY1+#TCB_SAVED_Y]
                MOVE    Y3, D0

                ; Saved-D0/SR were patched by _SemGive; the POP D / RTI
                ; below will deliver them. Fall through to .st_eint.

.st_eint:
                ; SR-gated EINT (live SR; saved SR delivers via RTI).
                LOADZ   D1, [#KERNEL_STATE]
                LOW     D1
                CMP     D1, #KERN_STATE_RUN
                BNE.S   .st_skip_eint
                EINT
.st_skip_eint:

                POP     XY2, XY3
                POP     XY1, XY3
                POP     XY0, XY3
                POP     D123, XY3               ; restore D1..D3 from saved
                POP     D0, XY3                 ; restore D0 (was: POP D, XY3)
                RTI                              ; PC + SR (success/fail)

.st_to_idle:
                JMP24   _RestoreIdle

; ============================================================================
; End of kos_sem.asm
; ============================================================================
