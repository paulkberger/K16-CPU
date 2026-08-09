; ============================================================================
; kos_spawn.asm — k/OS Phase 3 Part 7: dynamic task creation/teardown
; ============================================================================
; Date:    29 May 2026
; Status:  Part 39 — _SpawnShell added (kernel-context shell spawner).
; Revision: r8 - 29 May 2026 — Part 39 (kosh.com migration). Added
;             _SpawnShell, a kernel-context helper that encapsulates
;             the page-copy + _BuildTask + privileged-flags pattern
;             previously inlined in _P2Main. Inputs:
;                 Y0:X0 = 24-bit source image start (the .INCBIN'd blob)
;                 D2    = image length in bytes (≤ SPAWN_MAX_LEN = $FE00)
;                 XY1   = pointer to ASCIIZ task name (max 15 chars + NUL)
;             Outputs:
;                 C=0, D0 = new TCB ptr (low word; page is $00)
;                 C=1, D0 = ERR_TOOBIG / ERR_NOMEM / ERR_NOSLOTS
;             Side effects:
;                 Allocates one user page, builds one task with
;                 TF_PRIV | TF_SYSCRITICAL (TF_KOSH_FLAGS).
;             NOT a TRAP — runs in kernel context (Y3=$00), entered
;             via plain CALL24, returns via RET. Called once from
;             _P2Main during kernel boot. Pure factoring of pre-
;             existing logic; no new behaviour.
;
; Revision: r7 - 14 May 2026 — k/OS Part 30 hygiene pass: src_page
;             validation in spawn_from_buffer now uses USER_PAGE_BASE /
;             USER_PAGE_END_EMU rather than the deprecated TASK_PAGE_BASE
;             / TASK_PAGE_END aliases (which kos_defs.inc r37 removed).
;             Same numeric values ($02 and $3F), clearer names.
;             Requires kos_defs.inc r37+.
;
; Revision: r6 - 12 May 2026 — Part 20: _TidToTcb rewritten as linear scan.
;             The original O(1) address-arithmetic lookup assumed slot
;             index and TID were the same number. Held pre-Part-20 because
;             slots were never recycled within a session (sys_exit's
;             no-waiter path was lazy-reap; nothing else freed slots).
;             Post-Part-20 with eager-reap and sys_kill's pool sweep,
;             slots get reused while TASK_COUNT (the next-TID source)
;             keeps incrementing. After a couple of run-and-kill cycles
;             a fresh task at slot 2 might have TCB_ID = 7, and
;             _TidToTcb(7) would compute slot index 6 (TS_UNUSED) and
;             fail with ERR_BADARG — surfaced as:
;                 - kosh `ps` showed correct TID but `kill <that TID>`
;                   returned ERR_NOTFOUND.
;                 - Foreground `run cube4.com` failed with
;                   "run: wait failed [ERR_BADARG]" — sys_wait's
;                   _TidToTcb on the returned child TID didn't find it.
;             Fix: linear scan of the user-TCB pool, matching TCB_ID
;             rather than computing address from TID. O(USER_TCB_COUNT)
;             = O(62). The only callers (sys_wait, sys_kill, future
;             introspection) are rare relative to scheduler ticks.
;             ABI unchanged. No other code touched.
;
; Revision: r5 - 4 May 2026 — Branch .S polish.
;             6 unsuffixed branches converted to .S form
;             where target distance is ≤10 instructions.
;             FORWARD ONLY (assembler imm5 is unsigned 0..+31).
;             Per
;             K16 Manual Amendment 2026-05-04 E.5/E.6, default
;             auto-select picks long form; explicit .S saves
;             one word per branch. Saves 6 words.
;
; Revision: r4 - 2 May 2026 — Part 8 idle-restore fix.
;             Each of the 10 restore-incoming sites in sys_spawn (5 paths:
;             success, ERR_BADARG, ERR_TOOBIG, ERR_NOMEM, ERR_NOSLOTS) and
;             sys_wait (5 paths: slow, fast, ERR_BADARG, ERR_NOTCHILD,
;             ERR_DEADLOCK) now check whether the incoming TCB is IDLE_TCB
;             before reading TCB_SAVED_X/Y. If incoming is idle, JMP24 to
;             _RestoreIdle (in kos_ctxsw.asm r28+) which re-establishes
;             clean idle state without depending on the (potentially
;             corrupted) saved frame. See kos_ctxsw.asm r28 history for
;             the bug analysis. Requires kos_ctxsw.asm r28+ for
;             _RestoreIdle.
;
;           r3 - 2 May 2026 — Reverted prologue ordering to canonical form.
;             During the gotcha #33 debug arc (TRAP T8 5-bit clip on Digital,
;             since hardware-fixed) the prologue was reorganised from the
;             canonical PUSH SR / DINT / PUSH D / PUSH XYn into PUSH SR /
;             PUSH D / DINT / PUSH XYn. With #33 fixed at the hardware
;             level, that reorganisation served no purpose — PUSH D doesn't
;             depend on IE state, so DINT before or after PUSH D is
;             equivalent. Reverted for consistency with sys_yield, sys_exit,
;             sys_sleep, sys_wait. Defensive comment about not touching
;             D0..D3 before PUSH D retained — that lesson is real and worth
;             keeping in code.
;           r2 - 2 May 2026 — Removed DIAG markers '0'..'7' and the ARG DUMP
;             block added during Digital bring-up debug. Marker '0' was
;             poisoning saved-D0 with $30 ('0' char) before PUSH D could
;             capture the real caller's D0; this caused every spawn to
;             return ERR_BADARG. The bug was traced via the ARG DUMP
;             output showing src_page=$0030 instead of expected $0001.
;             Markers '1'..'7' worked correctly (they ran after PUSH D)
;             but cluttered terminal output; removed for production.
;             Added defensive comment at sys_spawn entry warning against
;             adding any pre-prologue code that touches D0..D3.
;             Body logic is unchanged from r1.
;           r1 - 2 May 2026 — initial. Implements:
;             TRAP #18  sys_spawn   — create child task    [NON-LEAF]
;             TRAP #19  sys_wait    — wait for child exit  [NON-LEAF]
;           Helpers:
;             _TidToTcb         — TID (1..32) → TCB ptr
;             _FindWaiterFor    — scan for any TCB waiting on a given TID
;             _OrphanChildren   — clear parent_id of all our children
;           Both syscalls follow the canonical non-leaf template
;             (PUSH SR / DINT / PUSH D,XY / body / RTI). Page allocation
;             via _AllocPage (kos_tcb.asm r14+); TCB allocation via
;             _AllocTCB; reaping via _ReapDeadTask.
;           Requires kos_defs.inc r14+, kos_tcb.asm r14+.
; Purpose: Runtime task spawn/wait/reap — closes Phase 3 by making
;          dynamic task creation work.
;
; --- Syscall return ABI for non-leaf syscalls -------------------------------
;
; Non-leaf syscalls return via RTI which restores SR from the stack at
; [XY3+#20] (after the canonical PUSH SR / PUSH D / PUSH XY*).
;
; The PUSH SR at entry is a single-word opcode and gives RTI something
; to pop. Its initial value is the caller's SR — but we don't preserve
; it. The syscall ABI is C=success/failure; other flag bits (Z/N/V) are
; undefined across a syscall. So at exit we OVERWRITE [XY3+#20] with a
; freshly-built SR:
;
;     ; Return C=0 (success)
;     LOADI   D0, #$0080              ; IE=1, LVL=0, all flags clear
;     STORED  D0, [XY3+#20]
;
;     ; Return C=1 (error)
;     LOADI   D0, #$0081              ; IE=1, LVL=0, C=1, others clear
;     STORED  D0, [XY3+#20]
;
; The return VALUE in D0 is staged into [XY3+#18] (saved D0 slot) so
; the standard POP D restores it into the caller's D0.
;
; --- Stack frame layout after standard non-leaf prologue --------------------
;
; (Same as sys_yield/sys_exit/sys_sleep)
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
;   [XY3+18]  = D0          <-- caller's D0 (first syscall arg / return slot)
;   [XY3+20]  = SR          <-- patch C flag here for return
;
; Note: included from kos_boot.asm; constants from kos_defs.inc.
; ============================================================================

; ============================================================================
; _TidToTcb — convert task ID to TCB pointer (linear scan)
;
;   Input:    D0 = TID
;   Output:   X1:Y1 = TCB ptr, C=0    success
;             X1=0, Y1=0,     C=1    failure (TID 0, or no live TCB matches)
;             D0 preserved on success; clobbered on failure.
;
;   Walks the user-TCB pool linearly, comparing each in-use slot's
;   TCB_ID against the requested TID. Returns the first match.
;
;   History (12 May 2026 — Part 20):
;     The original implementation computed the slot address by
;     arithmetic — slot = USER_TCB_BASE + (TID-1)*TCB_SIZE — assuming
;     TID and slot index were the same. That held while sys_exit's
;     no-waiter path was lazy-reap (slot stays TS_DEAD on the ring,
;     never reused) and TASK_COUNT was bounded by simultaneous tasks.
;
;     Post-Part-20's eager-reap + sys_kill sweep, slots get returned
;     to TS_UNUSED while TASK_COUNT keeps incrementing. _BuildTask
;     assigns TASK_COUNT+1 as the new TID; _AllocTCB picks the
;     first-free slot which has no relationship to the new TID. So
;     "TID 7 lives at slot index 2" is normal — the arithmetic lookup
;     would point at slot index 6 (which is TS_UNUSED) and fail.
;
;     The fix is a linear scan. O(62) over the user-TCB pool but the
;     only callers are sys_wait, sys_kill, and the future kosh
;     introspection commands — all rare relative to scheduler ticks.
; ============================================================================
_TidToTcb:
                ; Reject TID 0 (idle is never a sys_wait/sys_kill target).
                CMP     D0, #0
                BEQ     .bad

                PUSH    D1, XY3
                PUSH    D2, XY3

                MOVE    D2, D0                  ; D2 = target TID
                LOADI   X1, #USER_TCB_BASE
                LOADI   Y1, #$00
                LOADI   D1, #USER_TCB_COUNT

.scan:
                ; Skip TS_UNUSED slots
                LOADD   D0, [XY1+#TCB_STATE]
                CMP     D0, #TS_UNUSED
                BEQ.S   .next

                ; Compare TCB_ID with target
                LOADD   D0, [XY1+#TCB_ID]
                CMP     D0, D2
                BEQ.S   .found

.next:
                ADD     X1, #TCB_SIZE
                SUB     D1, #1
                BNE     .scan

                ; Not found
                POP     D2, XY3
                POP     D1, XY3
                LOADI   X1, #0
                LOADI   Y1, #0
                RETCS

.found:
                MOVE    D0, D2                  ; restore D0 = TID
                POP     D2, XY3
                POP     D1, XY3
                RETCC

.bad:
                LOADI   X1, #0
                LOADI   Y1, #0
                RETCS

; ============================================================================
; _FindWaiterFor — scan TCB pool for any task waiting on the given TID
;
;   Input:    D0 = target TID (the child we'd be waited on)
;   Output:   X1:Y1 = waiter's TCB ptr, C=0    found
;             X1=0, Y1=0,              C=1    no waiter
;             D0 preserved.
;
;   "Waiting on TID T" means: TCB_STATE == TS_WAITING and TCB_WAIT_ID == T.
;   Returns the FIRST such TCB found (lowest slot number).
; ============================================================================
_FindWaiterFor:
                PUSH    D1, XY3
                PUSH    D2, XY3

                MOVE    D2, D0                  ; D2 = target TID
                LOADI   X1, #USER_TCB_BASE
                LOADI   Y1, #$00
                LOADI   D1, #USER_TCB_COUNT

.scan:
                LOADD   D0, [XY1+#TCB_STATE]
                CMP     D0, #TS_WAITING
                BNE.S     .skip

                LOADD   D0, [XY1+#TCB_WAIT_ID]
                CMP     D0, D2
                BEQ.S     .found

.skip:
                ADD     X1, #TCB_SIZE
                SUB     D1, #1
                BNE     .scan

                ; No waiter found
                LOADI   X1, #0
                LOADI   Y1, #0
                MOVE    D0, D2                  ; restore D0
                POP     D2, XY3
                POP     D1, XY3
                RETCS

.found:
                MOVE    D0, D2                  ; restore D0
                POP     D2, XY3
                POP     D1, XY3
                RETCC

; ============================================================================
; _OrphanChildren — clear TCB_PARENT_ID of all our children
;
;   Input:    D0 = our TID
;   Output:   none (D0 preserved)
;   Effect:   For each TCB with TCB_PARENT_ID == D0, set TCB_PARENT_ID := 0.
;             Called from sys_exit when a parent dies — leaves children
;             alive but parentless.
; ============================================================================
_OrphanChildren:
                PUSH    D1, XY3
                PUSH    D2, XY3
                PUSH    XY1, XY3

                MOVE    D2, D0                  ; D2 = our TID (preserve)
                LOADI   X1, #USER_TCB_BASE
                LOADI   Y1, #$00
                LOADI   D1, #USER_TCB_COUNT

.loop:
                ; Skip TS_UNUSED slots (parent_id is stale)
                LOADD   D0, [XY1+#TCB_STATE]
                CMP     D0, #TS_UNUSED
                BEQ.S     .skip

                LOADD   D0, [XY1+#TCB_PARENT_ID]
                CMP     D0, D2
                BNE.S     .skip

                LOADI   D0, #0
                STORED  D0, [XY1+#TCB_PARENT_ID]

.skip:
                ADD     X1, #TCB_SIZE
                SUB     D1, #1
                BNE     .loop

                MOVE    D0, D2                  ; restore D0
                POP     XY1, XY3
                POP     D2, XY3
                POP     D1, XY3
                RET

; ============================================================================
; _DeliverWaitResult — poke exit code into waiter's saved-D0 stack slot
;                      and clear C in the waiter's saved SR
;
;   Input:    X1:Y1 = waiter's TCB ptr
;             D0    = exit code to deliver
;
;   Output:   none (D0 preserved; X1, Y1 preserved)
;             Clobbers X0, Y0, D1, D2, D3, flags
;
;   Effect:   Reads waiter's saved X3 and Y3 (page) from TCB. Computes
;             the address of the waiter's saved-D0 stack slot at
;             [waiter_y : waiter_x + 18] and stores the exit code
;             there. Then computes the saved-SR slot at +20 and
;             clears bit 0 (C := 0 = success).
;
;   Caller responsibility:
;     - Waiter must be in TS_WAITING (so its saved X3/Y3 are valid
;       and its user stack has a sys_wait frame at the top).
;     - DINT must be in effect (we're touching another task's stack).
;     - After this call, transition the waiter to TS_READY.
; ============================================================================
_DeliverWaitResult:
                PUSH    D123, XY3
                PUSH    XY0, XY3

                MOVE    D3, D0                  ; D3 = exit code (preserve)

                ; Read waiter's saved X3 (low word of stack pointer)
                LOADD   D1, [XY1+#TCB_SAVED_X]
                ; Read waiter's saved Y3 (low byte = page)
                LOADD   D2, [XY1+#TCB_SAVED_Y]

                ; Build XY0 = (waiter_page : waiter_x + 18)
                MOVE    Y0, D2
                MOVE    X0, D1
                ADD     X0, #18
                STORED  D3, [XY0]               ; saved-D0 := exit_code

                ; Build clean return SR for the waiter: IE=1, LVL=0,
                ; C=0 (success). Other flags don't carry meaning across
                ; a syscall — undefined per ABI, so we just zero them.
                ADD     X0, #2
                LOADI   D1, #$0080              ; IE=1, all flags 0 (C=0)
                STORED  D1, [XY0]

                MOVE    D0, D3                  ; restore D0

                POP     XY0, XY3
                POP     D123, XY3
                RET

; ============================================================================
; _DeliverWaitDetached — wake a waiter with ERR_DETACHED + C=1   (Part 51)
;
;   Input:    X1:Y1 = waiter's TCB ptr
;   Output:   none (X1, Y1 preserved); clobbers X0, Y0, D0, D1, D2, D3, flags
;
;   Mirrors _DeliverWaitResult's saved-D0 / saved-SR poke, but stages
;   ERR_DETACHED in the waiter's saved-D0 slot and sets the saved-SR carry
;   (C=1), so the waiter's TRAP_WAIT returns as a soft failure. Used by
;   sys_register_shell's auto-foreground path to tell the launching shell
;   "your child went interactive — stop waiting, stay alive" instead of
;   reporting an exit code.
;
;   Caller responsibility: waiter in TS_WAITING; DINT in effect; transition
;   the waiter to TS_READY after this call.
; ============================================================================
_DeliverWaitDetached:
                PUSH    D123, XY3
                PUSH    XY0, XY3

                LOADD   D1, [XY1+#TCB_SAVED_X]
                LOADD   D2, [XY1+#TCB_SAVED_Y]

                ; XY0 = (waiter_page : waiter_x + 18) = saved-D0 slot
                MOVE    Y0, D2
                MOVE    X0, D1
                ADD     X0, #18
                LOADI   D3, #ERR_DETACHED
                STORED  D3, [XY0]               ; saved-D0 := ERR_DETACHED

                ; saved-SR at +2: IE=1, C=1 (soft failure)
                ADD     X0, #2
                LOADI   D3, #$0081              ; IE=1, C=1
                STORED  D3, [XY0]

                POP     XY0, XY3
                POP     D123, XY3
                RET


; ============================================================================
; _ComHeaderCheck - validate a .COM image header                  [Part 60]
;
;   Input:
;     Y0:X0 = 24-bit address of image byte 0 - the byte that lands at
;             <page>:$0200.  Works on a file buffer or on a loaded page.
;     D0    = image length in bytes
;
;   Output (C=0):
;     D0 = pages      (total contiguous pages, incl. heap; >= 1)
;     D1 = heapPages  (a partition of pages; <= pages-1)
;
;   Output (C=1):
;     D0 = ERR_BADHEADER short image, bad magic, unknown version, or an
;                        inconsistent page split. Deliberately NOT
;                        ERR_NOTEXEC - that code already means four other
;                        things, and "this is not a K16 .COM image" is the
;                        one failure a caller most needs told plainly.
;
;   Clobbers: D0, D1, flags.  XY0 is restored, so a caller can go straight
;             on to copy from it.  Preserves D2, D3, XY1, XY2, XY3.
;
;   One parser, three callers (_SpawnShell, sys_spawn, sys_exec) - the .COM
;   layout is stated once rather than re-derived at each site.
;
;   The magic's job is REJECTION, not compatibility: every .COM carries a
;   header, so `run readme.txt` gets a clean loader error instead of
;   executing text at $0200.  There is no headerless fallback and no
;   "assume one page" default.
;
;   heapPages is validated but not otherwise used - the far heap is a later
;   part.  It is parsed and range-checked NOW so the field is nailed down
;   before the first .COM is rebuilt; changing it later means rebuilding
;   them all a second time.
;
;   NOTE: every field is a word, so the image base must be EVEN.  Every
;   caller supplies one (FS_BUF_SECTOR, an .INCBIN'd image, an even src
;   offset - sys_spawn validates that explicitly).
; ============================================================================
_ComHeaderCheck:
                PUSH    XY0, XY3

                ; --- Length must cover the header ------------------------
                ; Carry is 6502-style: C=0 after CMP means borrow, i.e. below.
                CMP     D0, #COM_HDR_SIZE
                BLO     .chc_bad                ; C=0 => len < 12

                ; --- Magic (word at +$04) --------------------------------
                ; Stored little-endian, so COM_MAGIC $4252 lays down $52 ('R')
                ; first and an ascending hex dump reads "RB".
                ; Every field is a full word, so the walk is four word reads
                ; at consecutive even offsets - STREAM post-increment
                ; ([XYn]+, word stride 2) advances the cursor as part of each
                ; load.  The advance is unconditional along the success path
                ; and there is no delimiter to land on, which is exactly the
                ; shape post-increment is for.
                ;
                ; LOADD is flag-transparent, so each CMP is doing the work;
                ; never branch straight off a load.
                ADD     X0, #COM_OFF_MAGIC      ; -> image+$04
                LOADD   D0, [XY0]+              ; magic,   -> +$06
                CMP     D0, #COM_MAGIC
                BNE     .chc_bad

                LOADD   D0, [XY0]+              ; version, -> +$08
                CMP     D0, #COM_VERSION
                BNE     .chc_bad

                LOADD   D0, [XY0]+              ; pages,   -> +$0A
                CMP     D0, #1
                BLO     .chc_bad                ; C=0 => pages < 1

                ; Require heapPages <= pages-1, i.e. heapPages < pages: the
                ; primary page always holds code and stack.  After CMP D1,D0
                ; the sense is C=0 <=> D1 < D0, so BHS (C=1) is the REJECT.
                LOADD   D1, [XY0]               ; heapPages (last - no advance)
                CMP     D1, D0
                BHS     .chc_bad

                ; D0 = pages, D1 = heapPages.  Two self-contained tails; POP
                ; leaves flags alone, but the carry is set last regardless.
                POP     XY0, XY3
                CLC
                RET

.chc_bad:
                POP     XY0, XY3
                LOADI   D0, #ERR_BADHEADER
                SEC
                RET

; ============================================================================
; _SpawnShell — kernel-context shell/task spawner   [Part 39]
;
;   Allocates a user page, copies a .com image into it at offset $0200,
;   stages BT_NAME, builds the task, and applies privileged shell flags
;   (TF_KOSH_FLAGS = TF_PRIV | TF_SYSCRITICAL).
;
;   This is a kernel function, NOT a TRAP. It runs in kernel context
;   (Y3=$00) and is called once from _P2Main during boot to bring up
;   kosh from the .INCBIN'd "kosh.com" image. It can be reused for
;   any future shell or daemon launched from kernel boot.
;
;   Input:
;     Y0:X0 = 24-bit source address of .com image start
;     D2    = image length in bytes (1..SPAWN_MAX_LEN = $FE00)
;     XY1   = pointer to ASCIIZ task name (≤15 chars + NUL; copied into
;             BT_NAME).
;     Y3    = $00 (kernel context — caller's responsibility)
;
;   Output (C=0):
;     D0    = new TCB pointer (low word; page is always $00)
;
;   Output (C=1):
;     D0 = ERR_TOOBIG   length 0 or > SPAWN_MAX_LEN
;     D0 = ERR_NOMEM    _AllocPage exhausted user pages
;     D0 = ERR_NOSLOTS  _BuildTask TCB-pool exhausted
;     D0 = ERR_BADHEADER image has no valid .COM header (Part 60)
;
;   Side effects:
;     - Allocates one user page (never freed by this routine).
;     - Builds one task. New task is parentless (BT_PARENT_ID = 0).
;     - Sets new TCB's TCB_FLAGS = TF_KOSH_FLAGS (privileged +
;       syscritical: may kill any task, cannot itself be killed).
;     - Does NOT register a shell. The spawned task does that itself
;       via TRAP_REGISTER_SHELL when it starts running.
;     - Does NOT context-switch. Caller continues running; the new
;       task picks up next time the scheduler runs (typically the
;       caller's JMP24 _RestoreIdle).
;
;   Clobbers: D0, D1, D2, D3, XY0, XY1, XY2
;   Preserves: XY3 (stack pointer; balanced via PUSH/POP pairs).
;   (XY1 is consumed reading the name string — not preserved.)
;
;   Implementation notes:
;     - Page-copy is **word-at-a-time**. The .INCBIN-emitted image is
;       word-aligned by assembler constraint (.com files always have
;       even length), so D2 is even and the SUB D2,#2 / BNE loop
;       terminates exactly. About 2× faster than sys_spawn's byte loop.
;     - The copy uses XY0 (src) and XY2 (dst), so XY1 (name ptr)
;       survives the copy phase without needing a stack save.
;     - We DON'T do an explicit DINT/EINT around the BT_* staging:
;       this entire routine runs at boot before _InitKernel finishes
;       setting up interrupts. The first scheduler tick can't fire
;       until _P2Main reaches JMP24 _RestoreIdle.
; ============================================================================
_SpawnShell:
                ; -- Preserve callee-saved registers we'll trash -----------
                ; XY1 (name ptr) survives the page-copy because the copy
                ; uses XY0 (source) and XY2 (destination). _AllocPage and
                ; _BuildTask both clobber D0..D3 / XY0 / XY2 but preserve
                ; XY1, so XY1 stays valid right up to the BT_NAME staging.
                ;
                ; We still need to preserve Y0:X0 and D2 across _AllocPage
                ; (it clobbers them). Save them on the kernel stack.
                PUSH    XY0, XY3                ; source addr
                PUSH    D2, XY3                 ; length (in bytes; always even)

                ; -- Validate length --------------------------------------
                CMP     D2, #0
                BEQ     .ss_toobig
                CMP     D2, #SPAWN_MAX_LEN+1
                BHS     .ss_toobig

                ; -- Parse and validate the .COM header (Part 60) ---------
                ; XY0 (source) and D2 (length) are still live in registers -
                ; the PUSHes above copied them, they did not consume them.
                ; _ComHeaderCheck preserves both.  A stale kosh.com built
                ; before the header existed now fails LOUDLY at boot instead
                ; of running headerless.
                MOVE    D0, D2                  ; D0 = image length
                CALLR   _ComHeaderCheck
                BCS     .ss_badhdr
                STOREZ  D0, [#FE_PAGES]         ; carry across _AllocPageRun
                STOREZ  D1, [#FE_HEAPPG]

                ; -- Allocate destination page run ------------------------
                LOADZ   D0, [#FE_PAGES]
                CALL24  _AllocPageRun
                BCS     .ss_nomem

                ; D0 = new page byte; stash in BT_PRIMARY for _BuildTask.
                STOREZ  D0, [#BT_PRIMARY]
                STOREZ  D0, [#BT_ENTRY_PG]      ; entry page = primary

                ; -- Restore source addr and length, set up destination ---
                POP     D2, XY3                 ; D2 = length (even, > 0)
                POP     XY0, XY3                ; Y0:X0 = source addr

                LOADZ   D0, [#BT_PRIMARY]
                MOVE    Y2, D0
                LOADI   X2, #SPAWN_ENTRY_OFFSET ; dst = <new_page>:$0200

                ; -- Word copy: Y0:X0 → Y2:X2, D2 bytes (always even) -----
                ; The .INCBIN-emitted image is word-aligned by assembler
                ; constraint (.com files have even length), so D2 is even
                ; and a 2-bytes-per-iteration loop terminates exactly.
.ss_copy_loop:
                LOADD   D0, [XY0]+
                STORED  D0, [XY2]+
                SUB     D2, #2
                BNE     .ss_copy_loop

                ; -- Stage remaining BT_* slots ---------------------------
                LOADI   D0, #SPAWN_ENTRY_OFFSET
                STOREZ  D0, [#BT_ENTRY_LO]
                LOADZ   D0, [#FE_PAGES]        ; Part 60: header's page count
                STOREZ  D0, [#BT_PCOUNT]
                LOADI   D0, #0
                STOREZ  D0, [#BT_PARENT_ID]     ; shells are parentless

                ; -- Stage BT_NAME from caller's name pointer -------------
                ; XY1 still holds the original name pointer (preserved
                ; across _AllocPage; the copy loop used XY0/XY2; the
                ; STOREZ block above used implicit page-$00 addressing
                ; with no XY clobber). Source via XY1, dest at $00:BT_NAME.
                LOADI   Y0, #$00
                LOADI   X0, #BT_NAME
                LOADI   D1, #16                 ; max name bytes
.ss_name_loop:
                LOADB   D0, [XY1]
                STOREB  D0, [XY0]
                CMP     D0, #0
                BEQ     .ss_name_done           ; NUL terminator stored
                ADD     X1, #1
                ADD     X0, #1
                SUB     D1, #1
                BNE     .ss_name_loop
                ; Exhausted 16 bytes without finding NUL — force one in
                ; the last byte so BT_NAME is always nul-terminated.
                LOADI   D0, #0
                STOREB  D0, [XY0]
.ss_name_done:

                ; -- Build the task --------------------------------------
                CALL24  _BuildTask
                BCS     .ss_nosl

                ; -- Apply TF_KOSH_FLAGS to the new TCB -------------------
                ; D0 = new TCB ptr (low word; page is always $00).
                LOADI   Y1, #$00
                MOVE    X1, D0
                LOADI   D2, #TF_KOSH_FLAGS
                STORED  D2, [XY1+#TCB_FLAGS]

                ; -- Return success (C=0; D0 still = TCB ptr) -------------
                RETCC

.ss_toobig:
                ; Stack at .ss_toobig: D2 (length), XY0 (src)
                POP     D2, XY3
                POP     XY0, XY3
                LOADI   D0, #ERR_TOOBIG
                RETCS

.ss_badhdr:
                ; Part 60: bad/absent .COM header. Stack: D2, XY0.
                ; At boot this is fatal - the caller falls into _BootFail -
                ; which is the intended outcome for a kosh.com that was not
                ; rebuilt with a header.
                POP     D2, XY3
                POP     XY0, XY3
                LOADI   D0, #ERR_BADHEADER
                RETCS

.ss_nomem:
                ; _AllocPage failed. Stack: D2, XY0
                POP     D2, XY3
                POP     XY0, XY3
                LOADI   D0, #ERR_NOMEM
                RETCS

.ss_nosl:
                ; _BuildTask failed AFTER _AllocPage succeeded and the
                ; page-copy completed. We've already popped D2 and XY0
                ; from the stack during the success path's preamble.
                ; The page is technically leaked but boot-time failure
                ; here is fatal anyway (caller falls into _BootFail).
                LOADI   D0, #ERR_NOSLOTS
                RETCS


; ============================================================================
; sys_spawn — TRAP #18   [NON-LEAF]
;
;   Create a new task by allocating a page, copying code into it, and
;   building a TCB.
;
;   Input:
;     D0 = src page byte ($01..$20)
;     D1 = src offset within page ($0000..$FFFF)
;     D2 = length in bytes ($0001..$FE00)
;
;   Output (C=0):
;     D0 = new task's pid (1..32)
;
;   Output (C=1):
;     D0 = ERR_BADARG    bad src page or zero length, page-crossing source,
;                        or an ODD src offset (Part 60 - the header word
;                        read at image+$04 needs an even base)
;     D0 = ERR_TOOBIG    length > $FE00
;     D0 = ERR_BADHEADER source is not a valid .COM image (Part 60)
;     D0 = ERR_NOMEM     no free run of the requested page count
;     D0 = ERR_NOSLOTS   TCB pool full
;
;   Notes:
;     - Source must NOT cross a page boundary (src_offset + length ≤ $10000).
;     - Child entry PC is fixed at primary:$0200 (SPAWN_ENTRY_OFFSET).
;     - Child runs as our child (TCB_PARENT_ID = our TID).
;     - Non-leaf: scheduler runs, child may execute immediately on RTI.
;
;   Structure: per gotcha #32 prophylaxis, each path is a self-contained
;   body ending in its own RTI. Forward BCS/BRA to error-path labels is
;   fine because each error path is a complete dead-end body, NOT a
;   shared epilogue. No falling-through or merging between paths.
; ============================================================================
sys_spawn:
                ; -- Standard non-leaf prologue ---------------------------
                ; NOTE: Do NOT add any code here that touches D0..D3 before
                ; the PUSH D0 / PUSH D123 pair — the caller's args live in
                ; those registers and the pair captures them into the
                ; saved-D group at [XY3+12..18] from where validation logic
                ; reads them.
                PUSH    SR, XY3
                DINT

                PUSH    D0, XY3
                PUSH    D123, XY3
                PUSH    XY0, XY3
                PUSH    XY1, XY3
                PUSH    XY2, XY3

                ; -- Recover args from saved-D group ----------------------
                ; [XY3+18] = D0 = src_page
                ; [XY3+16] = D1 = src_offset
                ; [XY3+14] = D2 = length

                ; -- Validate length ---------------------------------------
                LOADD   D0, [XY3+#14]           ; D0 = length
                CMP     D0, #0
                BEQ     .err_badarg
                CMP     D0, #SPAWN_MAX_LEN+1
                BHS     .err_toobig

                ; -- Validate src_page (must be $01..$20) -----------------
                LOADD   D0, [XY3+#18]           ; D0 = src_page
                CMP     D0, #USER_PAGE_BASE     ; Part 30 r37: was TASK_PAGE_BASE (deprecated alias)
                BLO     .err_badarg
                CMP     D0, #USER_PAGE_END_EMU+1 ; Part 30 r37: was TASK_PAGE_END+1
                BHS     .err_badarg

                ; -- Validate no page crossing ----------------------------
                ; src_offset + length must fit in 16 bits.
                LOADD   D0, [XY3+#16]           ; D0 = src_offset
                LOADD   D1, [XY3+#14]           ; D1 = length
                CLC
                ADD     D0, D1                  ; C=1 ⇒ wraps past $FFFF
                BCS     .err_badarg

                ; -- Validate src_offset is EVEN (Part 60) ----------------
                ; _ComHeaderCheck reads a word at image+$04; an odd image
                ; base would make that a DATA FAULT odd-addr word access.
                LOADD   D0, [XY3+#16]           ; src_offset
                AND     D0, #1
                BNE     .err_badarg

                ; -- Parse and validate the .COM header (Part 60) ---------
                ; The source buffer must be a real .COM image: same magic,
                ; same version, same page declaration as a file on disk.
                LOADD   D0, [XY3+#18]           ; src_page
                MOVE    Y0, D0
                LOADD   D0, [XY3+#16]           ; src_offset
                MOVE    X0, D0
                LOADD   D0, [XY3+#14]           ; length
                CALL24  _ComHeaderCheck
                BCS     .err_badheader
                STOREZ  D0, [#FE_PAGES]         ; carry across _AllocPageRun
                STOREZ  D1, [#FE_HEAPPG]

                ; -- Allocate destination page run ------------------------
                ; NOTE: only the PRIMARY page receives the image. Extra pages
                ; are blank workspace - SPAWN_MAX_LEN ($FE00) plus $0200 is
                ; exactly $10000, so the copy can never cross a page anyway.
                LOADZ   D0, [#FE_PAGES]
                CALL24  _AllocPageRun
                BCS     .err_nomem

                ; D0 = new page byte; stash in BT_PRIMARY for _BuildTask.
                STOREZ  D0, [#BT_PRIMARY]
                STOREZ  D0, [#BT_ENTRY_PG]      ; entry page = primary

                ; -- Copy code: src(page,offset) → dst(new_page, $0200) ---
                LOADD   D0, [XY3+#18]           ; src_page
                MOVE    Y0, D0
                LOADD   D0, [XY3+#16]           ; src_offset
                MOVE    X0, D0
                LOADZ   D0, [#BT_PRIMARY]       ; dst_page
                MOVE    Y1, D0
                LOADI   X1, #SPAWN_ENTRY_OFFSET ; dst_offset = $0200
                LOADD   D1, [XY3+#14]           ; D1 = length

.copy_loop:
                LOADB   D0, [XY0]+              ; D0 = byte from source
                STOREB  D0, [XY1]+              ; → destination
                SUB     D1, #1
                BNE     .copy_loop

                ; -- Stage remaining BT_* scratch slots -------------------
                LOADI   D0, #SPAWN_ENTRY_OFFSET
                STOREZ  D0, [#BT_ENTRY_LO]
                LOADZ   D0, [#FE_PAGES]         ; Part 60: header's page count
                STOREZ  D0, [#BT_PCOUNT]

                ; Parent ID = our TID (read from our TLS slot)
                LOADP   D0, Y3, [#TASK_ID]
                STOREZ  D0, [#BT_PARENT_ID]

                ; -- Build the task --------------------------------------
                CALL24  _BuildTask
                BCS     .err_buildfail

                ; -- Success: D0 = new TCB ptr → read TCB_ID for return -
                MOVE    X1, D0
                LOADI   Y1, #$00
                LOADD   D0, [XY1+#TCB_ID]

                ; -- Stash result in saved-D0 slot, build SR=success ----
                STORED  D0, [XY3+#18]
                LOADI   D0, #$0080              ; IE=1, C=0
                STORED  D0, [XY3+#20]

                ; -- Save outgoing X3/Y3 ----------------------------------
                LOADZ   D0, [#CURRENT_TCB]
                MOVE    X1, D0
                LOADI   Y1, #$00

                MOVE    D0, X3
                STORED  D0, [XY1+#TCB_SAVED_X]
                MOVE    D0, Y3
                STORED  D0, [XY1+#TCB_SAVED_Y]

                ; -- Bump yield counter -----------------------------------
                LOADD   D0, [XY1+#TCB_YIELD_COUNT]
                ADD     D0, #1
                STORED  D0, [XY1+#TCB_YIELD_COUNT]

                ; -- Pivot to kernel --------------------------------------
                LOADI   Y3, #$00
                LOADI   X3, #KERNEL_STACK_TOP

                CALL24  _Schedule

                ; -- Restore incoming task --------------------------------
                LOADZ   D0, [#CURRENT_TCB]
                CMP     D0, #IDLE_TCB
                BEQ     .idle_01

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
                RTI                              ; ===== success ENDS =====

.idle_01:
                JMP24   _RestoreIdle

; --- Error tails: each is a self-contained dead-end body ---
; Per gotcha #32: no shared epilogue. Each ends in its own RTI.

.err_badarg:
                LOADI   D0, #ERR_BADARG
                STORED  D0, [XY3+#18]
                LOADI   D0, #$0081              ; IE=1, C=1
                STORED  D0, [XY3+#20]

                LOADZ   D0, [#CURRENT_TCB]
                MOVE    X1, D0
                LOADI   Y1, #$00
                MOVE    D0, X3
                STORED  D0, [XY1+#TCB_SAVED_X]
                MOVE    D0, Y3
                STORED  D0, [XY1+#TCB_SAVED_Y]
                LOADD   D0, [XY1+#TCB_YIELD_COUNT]
                ADD     D0, #1
                STORED  D0, [XY1+#TCB_YIELD_COUNT]
                LOADI   Y3, #$00
                LOADI   X3, #KERNEL_STACK_TOP
                CALL24  _Schedule
                LOADZ   D0, [#CURRENT_TCB]
                CMP     D0, #IDLE_TCB
                BEQ     .idle_02

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
                RTI                              ; ===== ERR_BADARG ENDS =====

.idle_02:
                JMP24   _RestoreIdle

.err_toobig:
                LOADI   D0, #ERR_TOOBIG
                STORED  D0, [XY3+#18]
                LOADI   D0, #$0081
                STORED  D0, [XY3+#20]

                LOADZ   D0, [#CURRENT_TCB]
                MOVE    X1, D0
                LOADI   Y1, #$00
                MOVE    D0, X3
                STORED  D0, [XY1+#TCB_SAVED_X]
                MOVE    D0, Y3
                STORED  D0, [XY1+#TCB_SAVED_Y]
                LOADD   D0, [XY1+#TCB_YIELD_COUNT]
                ADD     D0, #1
                STORED  D0, [XY1+#TCB_YIELD_COUNT]
                LOADI   Y3, #$00
                LOADI   X3, #KERNEL_STACK_TOP
                CALL24  _Schedule
                LOADZ   D0, [#CURRENT_TCB]
                CMP     D0, #IDLE_TCB
                BEQ     .idle_03

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
                RTI                              ; ===== ERR_TOOBIG ENDS =====

.idle_03:
                JMP24   _RestoreIdle

.err_nomem:
                LOADI   D0, #ERR_NOMEM
                STORED  D0, [XY3+#18]
                LOADI   D0, #$0081
                STORED  D0, [XY3+#20]

                LOADZ   D0, [#CURRENT_TCB]
                MOVE    X1, D0
                LOADI   Y1, #$00
                MOVE    D0, X3
                STORED  D0, [XY1+#TCB_SAVED_X]
                MOVE    D0, Y3
                STORED  D0, [XY1+#TCB_SAVED_Y]
                LOADD   D0, [XY1+#TCB_YIELD_COUNT]
                ADD     D0, #1
                STORED  D0, [XY1+#TCB_YIELD_COUNT]
                LOADI   Y3, #$00
                LOADI   X3, #KERNEL_STACK_TOP
                CALL24  _Schedule
                LOADZ   D0, [#CURRENT_TCB]
                CMP     D0, #IDLE_TCB
                BEQ     .idle_04

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
                RTI                              ; ===== ERR_NOMEM ENDS =====

.idle_04:
                JMP24   _RestoreIdle

.err_buildfail:
                ; _AllocTCB failed after _AllocPage succeeded. The page
                ; we allocated has no TCB owning it, so it's already
                ; "free" by _PageInUse's definition. No explicit cleanup.
                LOADI   D0, #ERR_NOSLOTS
                STORED  D0, [XY3+#18]
                LOADI   D0, #$0081
                STORED  D0, [XY3+#20]

                LOADZ   D0, [#CURRENT_TCB]
                MOVE    X1, D0
                LOADI   Y1, #$00
                MOVE    D0, X3
                STORED  D0, [XY1+#TCB_SAVED_X]
                MOVE    D0, Y3
                STORED  D0, [XY1+#TCB_SAVED_Y]
                LOADD   D0, [XY1+#TCB_YIELD_COUNT]
                ADD     D0, #1
                STORED  D0, [XY1+#TCB_YIELD_COUNT]
                LOADI   Y3, #$00
                LOADI   X3, #KERNEL_STACK_TOP
                CALL24  _Schedule
                LOADZ   D0, [#CURRENT_TCB]
                CMP     D0, #IDLE_TCB
                BEQ     .idle_05

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
                RTI                              ; ===== ERR_NOSLOTS ENDS =====

.idle_05:
                JMP24   _RestoreIdle

.err_badheader:
                ; Part 60: source buffer is not a valid .COM image (bad
                ; magic, unknown version, short, or an inconsistent page
                ; split). Self-contained dead-end body per gotcha #32 - no
                ; shared epilogue, ends in its own RTI.
                LOADI   D0, #ERR_BADHEADER
                STORED  D0, [XY3+#18]
                LOADI   D0, #$0081              ; IE=1, C=1
                STORED  D0, [XY3+#20]

                LOADZ   D0, [#CURRENT_TCB]
                MOVE    X1, D0
                LOADI   Y1, #$00
                MOVE    D0, X3
                STORED  D0, [XY1+#TCB_SAVED_X]
                MOVE    D0, Y3
                STORED  D0, [XY1+#TCB_SAVED_Y]
                LOADD   D0, [XY1+#TCB_YIELD_COUNT]
                ADD     D0, #1
                STORED  D0, [XY1+#TCB_YIELD_COUNT]
                LOADI   Y3, #$00
                LOADI   X3, #KERNEL_STACK_TOP
                CALL24  _Schedule
                LOADZ   D0, [#CURRENT_TCB]
                CMP     D0, #IDLE_TCB
                BEQ     .idle_06

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
                RTI                              ; ===== ERR_NOTEXEC ENDS =====

.idle_06:
                JMP24   _RestoreIdle

; ============================================================================
; sys_wait — TRAP #19   [NON-LEAF]
;
;   Block calling task until specified child exits, then return its
;   exit code. If the child has already exited, return immediately
;   (fast path).
;
;   Input:
;     D0 = child's TID
;
;   Output (C=0):
;     D0 = child's exit code
;
;   Output (C=1):
;     D0 = ERR_BADARG    TID out of range or refers to TS_UNUSED slot
;     D0 = ERR_NOTCHILD  that TID's parent isn't us
;     D0 = ERR_DEADLOCK  another task is already waiting on that child
;
;   --- Control-flow model ---
;
;   sys_wait runs once per call. There is NO resume point in this
;   function for the slow path — when this task is later re-scheduled,
;   control returns directly to user code via the standard restore-
;   incoming machinery in some other task's epilogue.
;
;   Result delivery on the slow path: when the child's sys_exit finds
;   us as a waiter, it pokes our exit code directly into our user-stack
;   saved-D0 slot at [our_page : our_X3 + 18] and clears bit 0 of our
;   saved SR at +20 (C=0 = success). The standard restore-incoming
;   machinery then pops those values back into D0 and SR on RTI.
;
;   Fast path (child already dead): we stage the exit code in our own
;   saved-D0 slot here and reap the child, then go through the normal
;   pivot-and-schedule-and-return path.
;
;   Error paths: stage the error code in our saved-D0 slot, set C=1
;   in our saved SR, then go through the normal pivot-and-schedule-
;   and-return path. We will be restored normally with our error in D0.
;
;   So this function has ONE epilogue: pivot, _Schedule, restore
;   incoming task, RTI. The only difference between paths is what's
;   pre-staged in our saved-D0 slot and saved-SR carry bit before we
;   block (slow) or before we go through scheduling (fast/error).
; ============================================================================
sys_wait:
                ; -- Standard non-leaf prologue ---------------------------
                PUSH    SR, XY3
                DINT

                PUSH    D0, XY3
                PUSH    D123, XY3
                PUSH    XY0, XY3
                PUSH    XY1, XY3
                PUSH    XY2, XY3

                ; -- Recover child_tid from saved-D0 slot -----------------
                LOADD   D0, [XY3+#18]           ; D0 = child_tid

                ; -- Convert to TCB ptr (also validates range/state) ------
                CALL24  _TidToTcb
                BCS     .err_badarg
                ; X1:Y1 = child's TCB ptr; D0 still has TID.

                ; -- Save child's TCB ptr in XY2 (we'll need it later) ---
                MOVE    X2, X1
                LOADI   Y2, #$00

                ; -- Verify parent relationship ---------------------------
                ; We haven't pivoted to kernel yet, so Y3 still holds the
                ; user task's primary page. LOADP Y3 reads from that page,
                ; where TASK_ID lives at offset $0004 (TLS slot).
                LOADD   D0, [XY1+#TCB_PARENT_ID]
                LOADP   D1, Y3, [#TASK_ID]
                CMP     D0, D1
                BNE     .err_notchild

                ; -- Part 26: has the child already announced a detach? ---
                ; A shell that registered before we got here left
                ; TF_DETACH_PENDING on its own TCB because _FindWaiterFor
                ; found nobody to poke. Consume it and return ERR_DETACHED
                ; immediately rather than blocking on a child that will not
                ; exit until the user quits it. XY2 = child TCB.
                LOADD   D0, [XY2+#TCB_FLAGS]
                AND     D0, #TF_DETACH_PENDING
                BEQ.S   .no_detach_pending
                LOADD   D0, [XY2+#TCB_FLAGS]
                AND     D0, #$FFBF              ; ~TF_DETACH_PENDING (one-shot)
                STORED  D0, [XY2+#TCB_FLAGS]
                BRA     .err_detached
.no_detach_pending:

                ; -- Check for existing waiter (other than us) -----------
                LOADD   D0, [XY3+#18]           ; D0 = child_tid (reload)
                CALL24  _FindWaiterFor
                BCS.S     .no_waiter              ; C=1 ⇒ none found, good

                ; A waiter exists. Is it us?
                MOVE    D0, X1
                LOADZ   D1, [#CURRENT_TCB]
                CMP     D0, D1
                BNE     .err_deadlock           ; different waiter ⇒ DEADLOCK
                ; We are already the waiter (defensive — should not happen
                ; under normal control flow). Fall through to no_waiter.

.no_waiter:
                ; -- Locate self TCB (XY1) --------------------------------
                LOADZ   D0, [#CURRENT_TCB]
                MOVE    X1, D0
                LOADI   Y1, #$00

                ; -- Check child state: TS_DEAD ⇒ fast path ---------------
                LOADD   D0, [XY2+#TCB_STATE]
                CMP     D0, #TS_DEAD
                BEQ     .fast_path

                ; ============= SLOW PATH (self-contained body) =============
                ; Child still alive — block self in TS_WAITING. Result
                ; will be delivered by child's sys_exit poking our
                ; saved-D0 slot before transitioning us to TS_READY.

                ; Pre-build success SR (IE=1, C=0). On wake, this is
                ; what gets RTI'd back to user. (sys_exit's
                ; _DeliverWaitResult writes the same value — idempotent.)
                LOADI   D0, #$0080
                STORED  D0, [XY3+#20]

                ; self.TCB_WAIT_ID = child_tid
                LOADD   D0, [XY3+#18]
                STORED  D0, [XY1+#TCB_WAIT_ID]

                ; self.TCB_STATE = TS_WAITING
                LOADI   D0, #TS_WAITING
                STORED  D0, [XY1+#TCB_STATE]

                ; Save outgoing X3/Y3 (X1 still = self.TCB)
                MOVE    D0, X3
                STORED  D0, [XY1+#TCB_SAVED_X]
                MOVE    D0, Y3
                STORED  D0, [XY1+#TCB_SAVED_Y]

                ; Bump yield counter
                LOADD   D0, [XY1+#TCB_YIELD_COUNT]
                ADD     D0, #1
                STORED  D0, [XY1+#TCB_YIELD_COUNT]

                ; Pivot
                LOADI   Y3, #$00
                LOADI   X3, #KERNEL_STACK_TOP
                CALL24  _Schedule

                ; Restore incoming task
                LOADZ   D0, [#CURRENT_TCB]
                CMP     D0, #IDLE_TCB
                BEQ     .idle_06

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
                RTI                              ; ===== slow-path ENDS =====

.idle_06:
                JMP24   _RestoreIdle

.fast_path:
                ; ============= FAST PATH (self-contained body) =============
                ; Child already TS_DEAD. Stage exit code, build success
                ; SR, reap child, pivot+schedule, RTI.
                LOADD   D0, [XY2+#TCB_EXIT_CODE]
                STORED  D0, [XY3+#18]

                LOADI   D0, #$0080              ; IE=1, C=0
                STORED  D0, [XY3+#20]

                ; Reap the child (X1:Y1 = child)
                MOVE    X1, X2
                LOADI   Y1, #$00
                CALL24  _ReapDeadTask

                ; Save outgoing X3/Y3
                LOADZ   D0, [#CURRENT_TCB]
                MOVE    X1, D0
                LOADI   Y1, #$00
                MOVE    D0, X3
                STORED  D0, [XY1+#TCB_SAVED_X]
                MOVE    D0, Y3
                STORED  D0, [XY1+#TCB_SAVED_Y]
                LOADD   D0, [XY1+#TCB_YIELD_COUNT]
                ADD     D0, #1
                STORED  D0, [XY1+#TCB_YIELD_COUNT]
                LOADI   Y3, #$00
                LOADI   X3, #KERNEL_STACK_TOP
                CALL24  _Schedule
                LOADZ   D0, [#CURRENT_TCB]
                CMP     D0, #IDLE_TCB
                BEQ     .idle_07

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
                RTI                              ; ===== fast-path ENDS =====

.idle_07:
                JMP24   _RestoreIdle

; --- Error tails: each is a self-contained dead-end body ---

.err_detached:
                ; Part 26. Not an error: the child detached to the foreground
                ; as a shell. Delivered exactly as sys_register_shell's live
                ; poke delivers it, so kosh's REPL cannot tell the two apart.
                LOADI   D0, #ERR_DETACHED
                STORED  D0, [XY3+#18]
                LOADI   D0, #$0081              ; IE=1, C=1
                STORED  D0, [XY3+#20]
                BRA     .wait_sched_ret

.err_badarg:
                LOADI   D0, #ERR_BADARG
                STORED  D0, [XY3+#18]
                LOADI   D0, #$0081              ; IE=1, C=1
                STORED  D0, [XY3+#20]
.wait_sched_ret:

                LOADZ   D0, [#CURRENT_TCB]
                MOVE    X1, D0
                LOADI   Y1, #$00
                MOVE    D0, X3
                STORED  D0, [XY1+#TCB_SAVED_X]
                MOVE    D0, Y3
                STORED  D0, [XY1+#TCB_SAVED_Y]
                LOADD   D0, [XY1+#TCB_YIELD_COUNT]
                ADD     D0, #1
                STORED  D0, [XY1+#TCB_YIELD_COUNT]
                LOADI   Y3, #$00
                LOADI   X3, #KERNEL_STACK_TOP
                CALL24  _Schedule
                LOADZ   D0, [#CURRENT_TCB]
                CMP     D0, #IDLE_TCB
                BEQ     .idle_08

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
                RTI                              ; ===== ERR_BADARG ENDS =====

.idle_08:
                JMP24   _RestoreIdle

.err_notchild:
                LOADI   D0, #ERR_NOTCHILD
                STORED  D0, [XY3+#18]
                LOADI   D0, #$0081
                STORED  D0, [XY3+#20]

                LOADZ   D0, [#CURRENT_TCB]
                MOVE    X1, D0
                LOADI   Y1, #$00
                MOVE    D0, X3
                STORED  D0, [XY1+#TCB_SAVED_X]
                MOVE    D0, Y3
                STORED  D0, [XY1+#TCB_SAVED_Y]
                LOADD   D0, [XY1+#TCB_YIELD_COUNT]
                ADD     D0, #1
                STORED  D0, [XY1+#TCB_YIELD_COUNT]
                LOADI   Y3, #$00
                LOADI   X3, #KERNEL_STACK_TOP
                CALL24  _Schedule
                LOADZ   D0, [#CURRENT_TCB]
                CMP     D0, #IDLE_TCB
                BEQ     .idle_09

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
                RTI                              ; ===== ERR_NOTCHILD ENDS =====

.idle_09:
                JMP24   _RestoreIdle

.err_deadlock:
                LOADI   D0, #ERR_DEADLOCK
                STORED  D0, [XY3+#18]
                LOADI   D0, #$0081
                STORED  D0, [XY3+#20]

                LOADZ   D0, [#CURRENT_TCB]
                MOVE    X1, D0
                LOADI   Y1, #$00
                MOVE    D0, X3
                STORED  D0, [XY1+#TCB_SAVED_X]
                MOVE    D0, Y3
                STORED  D0, [XY1+#TCB_SAVED_Y]
                LOADD   D0, [XY1+#TCB_YIELD_COUNT]
                ADD     D0, #1
                STORED  D0, [XY1+#TCB_YIELD_COUNT]
                LOADI   Y3, #$00
                LOADI   X3, #KERNEL_STACK_TOP
                CALL24  _Schedule
                LOADZ   D0, [#CURRENT_TCB]
                CMP     D0, #IDLE_TCB
                BEQ     .idle_10

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
                RTI                              ; ===== ERR_DEADLOCK ENDS =====

.idle_10:
                JMP24   _RestoreIdle

; ============================================================================
; End of kos_spawn.asm
; ============================================================================
