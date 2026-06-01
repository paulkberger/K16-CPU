; ============================================================================
; kos_heap.asm — k/OS Phase 14: heap syscall TRAP wrappers
; ============================================================================
; Date:    17 May 2026
; Status:  Phase 14 Parts 2 & 3b — heap syscall completion (helpers exposed).
; Revision: r3 — 17 May 2026 — Phase 14 Part 3b: ownership consumer wrapper.
;             One new TRAP wrapper, same DINT envelope and BOOT/RUN-aware
;             EINT gate as the sister wrappers.
;
;               TRAP #44  sys_heapstats_by_tid — count blocks+bytes by TID  [LEAF]
;
;             ABI: D0 in = target TID. D1 out = block count, D2 out =
;             payload bytes, D0 out = preserved input TID (convenience),
;             C = 0. Preserves XY1, XY2.
;
;             Requires kos_kmalloc.asm r14+ (adds _HeapStatsByTid),
;             kos_defs.inc r39+ (adds TRAP_HEAPSTATS_BY_TID,
;             VEC_HEAPSTATS_BY_TID), kos_boot.asm r47+ (installs vector).
;
;           r2 — 17 May 2026 — Phase 14 Part 2: heap completion.
;             Two new TRAP wrappers, same DINT envelope and BOOT/RUN-aware
;             EINT gate as sys_kmalloc / sys_kfree.
;
;               TRAP #42  sys_krealloc  — resize an allocation         [LEAF]
;               TRAP #43  sys_heapstats — free/used/largest/regions    [LEAF]
;
;             Also: stale "TRAP #24 / #25" in r1 file comment referred to
;             the pre-domain-grouped numbers (renumber in kos_defs.inc r28).
;             Fixed to "TRAP #40 / #41".
;
;             Requires kos_kmalloc.asm r13+ (adds _krealloc, _HeapStatsFull),
;             kos_defs.inc r38+ (adds TRAP_KREALLOC/_HEAPSTATS, VEC_KREALLOC/
;             _HEAPSTATS), and kos_boot.asm r46+ (installs the two vectors).
;
;           r1 — 5 May 2026 — initial.
;
; Purpose: Expose _kmalloc / _kfree / _krealloc / _HeapStatsFull to user
;            tasks via the TRAP dispatch.
;            TRAP #40  sys_kmalloc   — allocate a kernel heap block      [LEAF]
;            TRAP #41  sys_kfree     — free a kernel heap block          [LEAF]
;            TRAP #42  sys_krealloc  — resize an allocation              [LEAF]
;            TRAP #43  sys_heapstats — free/used/largest/regions         [LEAF]
;
; --- Why these are LEAF syscalls --------------------------------------------
;
; Although the heap allocator mutates global kernel state (free lists,
; HEAP_BYTES_FREE, region descriptors), it does NOT touch task scheduler
; structures and never switches context. The same task that called returns
; from the call. So:
;
;   * No PUSH SR / RTI machinery (that's only for context-switch syscalls).
;   * No Y3 pivot to kernel — _kmalloc / _kfree use LOADZ/STOREZ which
;     are Y-independent (ZOA forces page $00 regardless of caller's Y3).
;   * The call IS atomic against the timer IRQ and other tasks: we wrap
;     the whole body in DINT / EINT. Same pattern as sys_putdec, sys_puts.
;
; This is the canonical "leaf-with-DINT" style. Call duration is bounded
; by free-list walks (worst case maybe a few hundred cycles per region);
; not long enough to delay the scheduler perceptibly at 30 Hz.
;
; --- ABI -------------------------------------------------------------------
;
; sys_kmalloc:  TRAP #24
;   In:   D0  = requested payload size in bytes (rounded up to even,
;               floored to BH_MIN_PAYLOAD = 4)
;   Out:  XY0 = 24-bit payload pointer (Y0 = page byte, X0 = offset)
;         C   = 0 on success
;         D0  = ERR_NOMEM, C = 1 on allocation failure
;   Clobbers: D0, XY0, flags
;   Preserves: D1, D2, D3, XY1, XY2 (callee-restored even though _kmalloc
;              touches them — we PUSH/POP around the body)
;
; sys_kfree:  TRAP #25
;   In:   XY0 = payload pointer (as previously returned by sys_kmalloc)
;   Out:  C   = 0 on success
;         D0  = ERR_INVALID, C = 1 if XY0 doesn't look like a live block
;   Clobbers: D0, flags
;   Preserves: D1, D2, D3, XY0, XY1, XY2
;
; Notes:
;   * Pointer is opaque to the caller. Don't rely on its layout.
;   * Don't free the same pointer twice — _kfree's USED-bit check will
;     catch the second free with ERR_INVALID, but corruption is possible
;     if the block has been re-allocated between the two frees.
;   * Allocations come from the SHARED kernel heap. There is no per-task
;     quota in Phase 14. A misbehaving task can starve everyone.
;
; Note: included from kos_boot.asm; constants from kos_defs.inc.
;
; ============================================================================

; ============================================================================
; sys_kmalloc — TRAP #24   [LEAF, DINT envelope]
;
; The caller's D1/D2/D3/XY1 are saved/restored because the underlying
; _kmalloc clobbers them as scratch. Caller's XY0 is overwritten with
; the result (or D0 with the error) — that's the documented ABI.
;
; IE handling: DINT unconditionally; EINT only if KERNEL_STATE = RUN.
; This matches the caller's IE state in both contexts:
;   * BOOT  — caller had IE=0 (scheduler not up). Stay disabled; the
;             eventual transition to _IdleLoop will enable IRQs.
;   * RUN   — caller had IE=1 (it's a real task). Re-enable on exit.
; Without this gate, an unconditional EINT in BOOT context fires the
; timer IRQ against IDLE_TCB and corrupts the bare-kernel stack on
; Digital (EMU is permissive and doesn't fire from boot).
; ============================================================================
sys_kmalloc:
                PUSH    D123, XY3
                PUSH    XY1, XY3

                DINT

                ; D0 holds the size on entry; _kmalloc consumes it.
                CALL24  _kmalloc

                ; _kmalloc returns:
                ;   success: XY0 = payload, C = 0
                ;   failure: D0 = ERR_NOMEM, C = 1
                ; Both branches leave SR's C correctly set; we propagate
                ; through the EINT gate (EINT does not touch flags).

                ; Save C across KERNEL_STATE check.
                PUSH    SR, XY3
                LOADZ   D1, [#KERNEL_STATE]
                LOW     D1
                CMP     D1, #KERN_STATE_RUN
                BNE.S     .skip_eint_m
                EINT
.skip_eint_m:
                POP     SR, XY3                 ; restore C from _kmalloc

                ; Restore caller's saved registers (POP doesn't touch flags).
                POP     XY1, XY3
                POP     D123, XY3
                RET

; ============================================================================
; sys_kfree — TRAP #25   [LEAF, DINT envelope]
;
; IE handling: same gate as sys_kmalloc — see comment there.
; ============================================================================
sys_kfree:
                PUSH    D1, XY3
                PUSH    D2, XY3
                PUSH    XY1, XY3

                DINT

                ; XY0 holds the payload pointer on entry; _kfree consumes it.
                CALL24  _kfree

                ; _kfree returns:
                ;   success: C = 0, D0 preserved as ERR_OK
                ;   failure: D0 = ERR_INVALID, C = 1

                ; Save C across KERNEL_STATE check.
                PUSH    SR, XY3
                LOADZ   D1, [#KERNEL_STATE]
                LOW     D1
                CMP     D1, #KERN_STATE_RUN
                BNE.S     .skip_eint_f
                EINT
.skip_eint_f:
                POP     SR, XY3                 ; restore C from _kfree

                POP     XY1, XY3
                POP     D2, XY3
                POP     D1, XY3
                RET

; ============================================================================
; sys_krealloc — TRAP #42   [LEAF, DINT envelope]
;
; ABI:
;   In:   XY0 = current payload pointer (or 0:0 for "act as malloc")
;         D0  = new size in bytes
;   Out:  XY0 = new payload pointer, C = 0 on success
;         D0  = ERR_NOMEM or ERR_INVALID, C = 1 on failure
;         On ERR_NOMEM, the original XY0 is preserved (caller still
;         owns the old, unmoved block).
;   Clobbers: D0, XY0, flags
;   Preserves: D1, D2, D3, XY1, XY2
;
; IE handling: matches sys_kmalloc — DINT unconditionally, EINT only if
; KERNEL_STATE = RUN.
; ============================================================================
sys_krealloc:
                PUSH    D123, XY3
                PUSH    XY1, XY3
                PUSH    XY2, XY3

                DINT

                CALL24  _krealloc

                PUSH    SR, XY3
                LOADZ   D1, [#KERNEL_STATE]
                LOW     D1
                CMP     D1, #KERN_STATE_RUN
                BNE.S     .skip_eint_r
                EINT
.skip_eint_r:
                POP     SR, XY3                 ; restore C from _krealloc

                POP     XY2, XY3
                POP     XY1, XY3
                POP     D123, XY3
                RET

; ============================================================================
; sys_heapstats — TRAP #43   [LEAF, DINT envelope]
;
; ABI:
;   In:   nothing
;   Out:  D0 = total bytes free
;         D1 = total bytes used
;         D2 = largest contiguous free block (payload bytes)
;         D3 = region count
;         C  = 0 (no failure mode)
;   Clobbers: D0..D3, XY0, flags
;   Preserves: XY1, XY2
;
; IE handling: matches sys_kmalloc.
;
; The KERNEL_STATE gate is structurally redundant here — sys_heapstats is
; a TRAP, only reachable from a user task (KERN_STATE_RUN). Kept anyway
; for symmetry with sister wrappers.
; ============================================================================
sys_heapstats:
                PUSH    XY1, XY3
                PUSH    XY2, XY3

                DINT

                CALL24  _HeapStatsFull
                ; D0..D3 hold free/used/largest/regions; C = 0.

                ; Stash D0 across the LOADZ (D0..D3 are all return regs;
                ; we need scratch).
                PUSH    SR, XY3
                PUSH    D0, XY3
                LOADZ   D0, [#KERNEL_STATE]
                LOW     D0
                CMP     D0, #KERN_STATE_RUN
                POP     D0, XY3
                BNE.S     .skip_eint_s
                EINT
.skip_eint_s:
                POP     SR, XY3

                POP     XY2, XY3
                POP     XY1, XY3
                RET

; ============================================================================
; sys_heapstats_by_tid — TRAP #44   [LEAF, DINT envelope]
;
; Count USED blocks and bytes owned by a given TID. Pass TID=0 to query
; kernel-owned blocks.
;
; ABI:
;   In:   D0 = target TID
;   Out:  D1 = block count
;         D2 = total payload bytes (no headers)
;         D0 = preserved (still target TID) — convenience for callers
;              that want to label their output
;         C  = 0 (no failure mode)
;   Clobbers: D3, XY0, flags
;   Preserves: XY1, XY2
;
; IE handling: matches sys_kmalloc.
;
; The KERNEL_STATE gate is redundant here (TRAP, so always KERN_STATE_RUN)
; but kept for symmetry with sister wrappers.
; ============================================================================
sys_heapstats_by_tid:
                PUSH    XY1, XY3
                PUSH    XY2, XY3
                PUSH    D0, XY3             ; preserve caller's TID

                DINT

                CALL24  _HeapStatsByTid
                ; D1 = count, D2 = bytes. D0/D3 clobbered.

                ; KERNEL_STATE gate.
                PUSH    SR, XY3
                LOADZ   D0, [#KERNEL_STATE]
                LOW     D0
                CMP     D0, #KERN_STATE_RUN
                BNE.S     .skip_eint_t
                EINT
.skip_eint_t:
                POP     SR, XY3

                POP     D0, XY3             ; restore TID into D0
                POP     XY2, XY3
                POP     XY1, XY3
                RET

; ============================================================================
; End of kos_heap.asm
; ============================================================================
