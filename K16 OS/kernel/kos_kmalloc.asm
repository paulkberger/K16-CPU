; ============================================================================
; kos_kmalloc.asm — k/OS Phase 3 Part 9: kernel heap allocator
; ============================================================================
; Date:    18 May 2026
; Status:  Phase 14 Parts 2, 3a & 3b — heap completion + per-task ownership
;          (production; reap hook live in _ReapDeadTask).
; Revision: r15 — 18 May 2026 — _kmalloc XY2-clean (callee-saves XY2).
;
;             _kmalloc previously clobbered XY2 via its internal calls to
;             _FindFit / _SplitBlock. This leaked an implementation detail
;             into the heap-API contract: every caller had to know which
;             helpers _kmalloc happened to use today and save XY2 around
;             the call. Two bugs in Part 33 (_krealloc grow path) were
;             direct hits of this footgun.
;
;             r15 closes the bug class permanently: _kmalloc now PUSHes
;             XY2 immediately after its existing PUSHes and POPs it before
;             returning. The heap API is now uniformly caller-clean —
;             _kmalloc / _kfree / _krealloc all preserve D1/D2/D3 and
;             XY1/XY2/XY3, with only D0 + XY0 carrying I/O.
;
;             Cost: one PUSH/POP pair, ~6 bytes, two memory cycles.
;             Heap path is not in any hot loop.
;
;             Updated _krealloc's .kr_grow comment: the PUSH XY0 there is
;             now only stashing the old payload pointer across the XY0
;             clobber, not double-duty XY2 preservation.
;
;           r14 — 17 May 2026 — Phase 14 Part 3b: ownership consumers.
;
;             Two new kernel-internal helpers:
;
;             _HeapStatsByTid — count USED blocks and bytes owned by a
;                              given TID. Walks every region in physical
;                              block order (not the free list).
;                              Input:  D0 = target TID
;                              Output: D1 = block count
;                                      D2 = total payload bytes
;                                      C  = 0
;                              Clobbers: D0..D3, X1/Y1, X2/Y2.
;
;             _ReapByTid     — free every USED block owned by a TID.
;                              Same physical-order walk; calls _kfree on
;                              each match, then restarts the current
;                              region's walk from HR_BLOCK_BASE to handle
;                              _kfree's coalescing safely. O(N) per
;                              freed block but reap is one-shot at task
;                              death; N is small in practice.
;                              Input:  D0 = TID to reap.
;                              Output: none.
;                              Clobbers: D0..D3, X0/Y0, X1/Y1, X2/Y2.
;
;             Register plan for both walks:
;               HEAP_TID_QUERY  (page-$00)  target TID, stashed
;               D1, D2                      output accumulators
;               D0, D3                      transient scratch
;               XY1 (Y1=page, X1=0)         region descriptor
;               XY2 (Y2=page, X2=offset)    block ptr; source of truth
;             X2 advance pattern: load size into D0, ADD #header, MOVE
;             D3 ← X2, ADD D3 += D0, MOVE X2 ← D3. Stays within page
;             since payloads are bounded.
;
;             _ReapByTid additionally stashes the current region page in
;             HEAP_RBT_REGION (page-$00) so it survives _kfree clobber
;             and the post-_kfree restart can reload it.
;
;             The TRAP wrapper sys_heapstats_by_tid lands in kos_heap.asm
;             r3 (TRAP #44, VEC $00B0). The companion to call _ReapByTid
;             from _ReapDeadTask is intentionally NOT wired this revision —
;             waiting for htest TX-TD to validate the helpers first.
;
;           r13 — 17 May 2026 — Phase 14 Parts 2 & 3a.
;
;             Part 2 (heap completion helpers):
;             _krealloc      — resize an allocation. malloc-copy-free
;                              unless the new size fits in the current
;                              block (in-place; no shrink-split yet).
;                              Edge cases: realloc(NULL, n) == malloc(n);
;                              realloc(p, 0) returns ERR_INVALID rather
;                              than acting as free (footgun guard).
;                              On ERR_NOMEM the original ptr is preserved
;                              per C realloc contract.
;
;                              Two bugs found during htest.com runs
;                              (17 May 2026), both in the grow path:
;
;                              Bug 1: the original code stashed the old
;                              payload ptr in XY2 across the inner
;                              _kmalloc call. _kmalloc's internal helpers
;                              (_FindFit, _SplitBlock) use XY2 as scratch
;                              and do NOT preserve it. Fix: PUSH XY0
;                              before _kmalloc, POP into XY2 after.
;
;                              Bug 2 (the actual leak the first run
;                              caught): the byte-copy loop advances BOTH
;                              X0 and X2 by the payload size. After the
;                              loop, X2 points to the END of the old
;                              block, not its START. The subsequent
;                              _kfree(XY2) was therefore called on
;                              old_payload+N, _kfree's validation read
;                              garbage at "header"−6, failed silently
;                              with C=1 (which _krealloc ignores), and
;                              the old USED block leaked. Fix: PUSH X2
;                              before the copy loop, POP after.
;
;                              T8 of htest.com (compare HEAP_BYTES_FREE
;                              against baseline) is what surfaced this —
;                              T5 itself passes content checks since
;                              the new block's contents are correct;
;                              only the heap accounting reveals the leak.
;
;             _HeapStatsFull — returns free / used / largest / regions
;                              in D0..D3. No failure mode (C=0 always).
;                              K16 has no BHI/BLS — the "update max if
;                              size > current" test uses reversed-CMP
;                              + BHS synthesis (see comment at the
;                              .hsf_block_loop site).
;
;             Part 3a (per-task ownership — stamp side only):
;             Block header grew 4 → 6 bytes; new BH_OWNER_TID at $04.
;             All offset references in this file are symbolic — the layout
;             change is contained in kos_defs.inc r38+. Two new touches:
;
;               * _kmalloc now stamps BH_OWNER_TID from CURRENT_TCB → TCB_ID.
;                 CURRENT_TCB == 0 (boot context) stamps OWNER_KERNEL = 0,
;                 which is reserved as "kernel-owned, never reaped".
;               * _InitRegion and _SplitBlock initialise BH_OWNER_TID to 0
;                 on new free blocks (defensive; stamped properly when
;                 _kmalloc hands them out).
;
;             Part 3b (consumers — DEFERRED to next session):
;               _HeapStatsByTid — count blocks and bytes by TID
;               _ReapByTid      — free all of a dying task's allocations
;               _ReapDeadTask hook to call _ReapByTid
;               kosh 'meminfo' command
;
;             Pre-Part-3b state is safe: every USED block carries a valid
;             owner_tid, but the helpers that read it don't exist yet.
;             Existing call sites (back-buffer manual free in _ReapDeadTask)
;             continue working unchanged because they don't look at
;             BH_OWNER_TID.
;
;             The existing _HeapStats (free-only in D0) is retained.
;
;             No in-place GROW optimisation in this revision — even if the
;             physically-next block is free and adjacent, _krealloc still
;             does malloc-copy-free. Worthwhile follow-up but not essential.
;
;             Requires kos_defs.inc r38+ (header layout + new constants).
;
;           r12 — 5 May 2026 — Size-cap on entry. Reject requests
;             larger than HR_USABLE_BYTES-BH_HEADER_SIZE ($FFDC) before
;             the round-up-to-even step. This closes a wrap bug where
;             a request of $FFFF would round up to $0000 and silently
;             allocate a tiny block. Discovered during Phase 14 Part 1
;             smoke development.
;
;           r11 - 4 May 2026 — Branch .S polish.
;             21 unsuffixed branches converted to .S form
;             where target distance is ≤10 instructions.
;             FORWARD ONLY (assembler imm5 is unsigned 0..+31).
;             Per
;             K16 Manual Amendment 2026-05-04 E.5/E.6, default
;             auto-select picks long form; explicit .S saves
;             one word per branch. Saves 21 words.
;
; Revision: r10 — 4 May 2026 — Opcode polish.
;             10 occurrences of `AND Dn, #$00FF` replaced with `LOW Dn`.
;             Same operation (extract low byte / clear high byte),
;             1 word instead of 2, 3 cycles instead of 4. Z flag no
;             longer set; verified no callers depend on it.
;             Saves 10 words.
;
;           r9 — 4 May 2026 — LEA Mode 00 added to refactor.
;             Mode 00 (`LEA XYn, XYm` — full XY copy) validated by
;             test_lea_mode00_v2.asm (T1 simple PASS, T2 pattern PASS).
;             Earlier v1 test had memory-backing dependency that gave
;             a false negative — pure-register v2 confirmed Mode 00
;             encodes and executes correctly.
;             One Mode 00 substitution applied:
;               _InsertFreeBlock backward coalesce: 2-instr → 1-instr
;                                                    LEA XY1, XY2
;             Total kmalloc savings: 6 instructions in hot allocator paths.
;             Smoke test: 5/5 PASS expected on both targets.
;
;           r8 — 4 May 2026 — LEA Mode 11 refactor reapplied.
;             Per K16_Manual_Amendment_2026-05-04.md A.1, LEA Mode 11
;             with symbolic operand (LEA XYn, XYm+#SYMBOL) is fixed.
;             Validated by test_lea_mode11.asm (T1 literal PASS,
;             T2 symbol PASS).
;             Substitutions applied:
;               .take_whole payload ptr  : 4-instr → 1-instr LEA Mode 11
;                                          (saves 3)
;               _SplitBlock tail addr    : 5-instr → 3-instr
;                                          (LEA Mode 11 + MOVE D,X +
;                                           ADD D,D + MOVE X,D, saves 2)
;             LEA Mode 00 candidate (line 654 _InsertFreeBlock backward
;             coalesce: MOVE Y1,Y2 / MOVE X1,X2 → LEA XY1, XY2) NOT
;             applied in this revision — Mode 00 status pending
;             test_lea_mode00_v2.asm validation. Will apply if v2 PASSes.
;
;             Manual sequences retained where LEA cannot apply:
;               _kfree header ptr (-4)   : LEA imm5 is unsigned, no sub
;               _UnlinkFreeBlock .scan   : X2 from D2 (offset), not XY copy
;               _InsertFreeBlock .walk   : same shape as above
;               _InsertFreeBlock .fwd    : X2 from D3 (computed offset)
;             Net saving: 5 instructions in hot allocator paths.
;             Smoke test: 5/5 PASS expected on both targets.
;
;           r7 — 4 May 2026 — REFACTOR FULLY REVERTED (initial r7
;             attempt). LEA Mode 11 + Mode 00 + RET #4w substitutions
;             caused boot crash. Code reverted to manual MOVE sequences
;             pending diagnosis.
;
;           r6 — 3 May 2026 — ROOT CAUSE FOUND (then). r3 refactor
;             failure attributed to assembler bug. File reverted to
;             manual MOVE sequences pending assembler fix.
;
;           r5 — 3 May 2026 — All LEAs removed (cause then unknown).
;
;           r3 — 3 May 2026 — LEA refactor (broken by assembler bug).
;
;           r2 — 3 May 2026 — _InitMemConfig also writes KOS_USER_PAGE_END.
;             Digital → $1F (30 user pages); EMU → $3F (62 user pages).
;             Heap growth pool start moves on EMU: $20 → $40.
;
;           r1 — 3 May 2026 — initial. Implements:
;
;             _InitMemConfig    — host-aware page/heap configuration
;             _InitHeap         — lay down region #1 on KHEAP_PAGE
;             _kmalloc          — allocate a block, return 24-bit ptr
;             _kfree            — free a block, coalesce neighbours
;             _HeapStats        — return total bytes free in D0
;
;           Internal helpers:
;             _InitRegion       — write fresh descriptor + free block on a page
;             _GrowHeap         — claim next page from EMU growth pool
;             _FindFit          — first-fit search across all regions
;             _SplitBlock       — split a free block to satisfy a smaller request
;             _UnlinkFreeBlock  — remove a block from its region's free list
;             _InsertFreeBlock  — insert a block, coalescing neighbours
;
;           Pointer convention: 24-bit (page byte + 16-bit offset).
;           _kmalloc returns the pointer in XY0 (Y0 low byte = page,
;           X0 = offset, addressing the PAYLOAD). _kfree expects the
;           same form in XY0.
;
;           Free-list layout (per block, in payload bytes):
;             +0  word  next_y  (page byte; only low byte used)
;             +2  word  next_x  (offset within page; 0 = end of list)
;           Y-first / X-second matches K16 LOADXY/STOREXY convention.
;           Free lists never cross region boundaries.
;
;           Requires kos_defs.inc r19+. Kernel-internal only (TRAP wrappers
;           come in Part 10 once soaked).
; ============================================================================

; ============================================================================
; _InitMemConfig — configure heap-related constants based on detected host
; ============================================================================
_InitMemConfig:
                PUSH    D0, XY3

                ; Always: heap base = $01
                LOADI   D0, #KHEAP_PAGE
                STOREZ  D0, [#KOS_KHEAP_BASE]
                STOREZ  D0, [#HEAP_FIRST_PAGE]

                ; Zero counters (set by _InitHeap)
                LOADI   D0, #0
                STOREZ  D0, [#HEAP_REGIONS]
                STOREZ  D0, [#HEAP_BYTES_FREE]

                ; Branch on host
                LOADZ   D0, [#KOS_HOST]
                CMP     D0, #HOST_DIGITAL
                BEQ.S     .digital

                ;-- EMU: 256 pages, 62 user, growth pool $40..$FF -----------
                LOADI   D0, #$0100
                STOREZ  D0, [#KOS_PAGE_COUNT]
                LOADI   D0, #USER_PAGE_END_EMU
                STOREZ  D0, [#KOS_USER_PAGE_END]
                LOADI   D0, #KHEAP_POOL_END_EMU
                STOREZ  D0, [#KOS_KHEAP_END]
                BRA.S     .done

.digital:
                ;-- Digital: 32 pages, 30 user, no heap growth ------------
                LOADI   D0, #$0020
                STOREZ  D0, [#KOS_PAGE_COUNT]
                LOADI   D0, #USER_PAGE_END_DIGITAL
                STOREZ  D0, [#KOS_USER_PAGE_END]
                LOADI   D0, #KHEAP_PAGE         ; end == base = no growth
                STOREZ  D0, [#KOS_KHEAP_END]

.done:
                POP     D0, XY3
                RET

; ============================================================================
; _InitHeap — initialise heap region #1 on KHEAP_PAGE
; ============================================================================
_InitHeap:
                PUSH    D0, XY3
                PUSH    D1, XY3

                LOADI   D0, #KHEAP_PAGE         ; this region's page
                LOADI   D1, #0                  ; no next region
                CALL24  _InitRegion

                LOADI   D0, #1
                STOREZ  D0, [#HEAP_REGIONS]

                LOADI   D0, #HR_USABLE_BYTES-BH_HEADER_SIZE
                STOREZ  D0, [#HEAP_BYTES_FREE]

                POP     D1, XY3
                POP     D0, XY3
                RET

; ============================================================================
; _InitRegion — write a fresh region descriptor + initial free block
;
;   Input: D0 = page byte for this region (low byte)
;          D1 = next region's page byte (low byte; 0 = last region)
; ============================================================================
_InitRegion:
                PUSH    D2, XY3
                PUSH    XY0, XY3

                ; XY0 = <page>:0000 (region descriptor)
                MOVE    Y0, D0
                LOADI   X0, #0

                LOADI   D2, #HR_USABLE_BYTES
                STORED  D2, [XY0+#HR_SIZE]

                LOADI   D2, #HR_FLAG_INIT
                STORED  D2, [XY0+#HR_FLAGS]

                LOADI   D2, #HR_BLOCK_BASE
                STORED  D2, [XY0+#HR_FREE_HEAD]

                STORED  D1, [XY0+#HR_NEXT_PAGE]

                LOADI   D2, #HR_USABLE_BYTES-BH_HEADER_SIZE
                STORED  D2, [XY0+#HR_BYTES_FREE]

                LOADI   D2, #HR_MAGIC_VALUE
                STORED  D2, [XY0+#HR_MAGIC]

                ; --- Initial block at <page>:0010 -------------------------
                ; Adjust XY0 to point at first block. Avoid same-register LEA
                ; mode 11 (LEA XY0, XY0+#imm5) — appears to misbehave when
                ; src == dst. Plain ADD on X0 stays within the page; Y0 is
                ; unchanged (already correct).
                ADD     X0, #HR_BLOCK_BASE

                LOADI   D2, #HR_USABLE_BYTES-BH_HEADER_SIZE
                STORED  D2, [XY0+#BH_SIZE]

                LOADI   D2, #BH_FLAG_LAST
                STORED  D2, [XY0+#BH_FLAGS]

                ; owner_tid = 0 (free block; stamped properly by _kmalloc
                ; when handed out).
                LOADI   D2, #0
                STORED  D2, [XY0+#BH_OWNER_TID]

                ; payload first 4 bytes = next_free pointer = 0:0
                LOADI   D2, #0
                STORED  D2, [XY0+#BH_NEXT_Y]
                STORED  D2, [XY0+#BH_NEXT_X]

                POP     XY0, XY3
                POP     D2, XY3
                RET

; ============================================================================
; _kmalloc — allocate a block from the kernel heap
;
;   Input:  D0 = requested size in bytes (1..$FFE0 reasonable)
;   Output: XY0 = payload pointer (24-bit), C=0 on success
;           D0 = ERR_NOMEM, C=1 if no fit and growth not possible
;   Clobbers: D0, XY0 (success); D0 (failure)
;   Preserves: D1, D2, D3, XY1, XY2, XY3 (saved/restored internally)
;
;   Note: XY2 is used as scratch by _FindFit / _SplitBlock, so _kmalloc
;   saves and restores it. This matches the _kfree / _krealloc convention
;   and keeps the heap-API clobber surface symmetric (D0 + XY0 only).
; ============================================================================
_kmalloc:
                PUSH    D123, XY3
                PUSH    XY1, XY3
                PUSH    XY2, XY3                ; r15: preserve across _FindFit/_SplitBlock

                ; --- Round up requested size to even, floor to MIN -------
                ; Reject oversize before any rounding. Max legal aligned
                ; payload is HR_USABLE_BYTES - BH_HEADER_SIZE = $FFDC.
                ; Anything > that goes to .nomem. This also catches the
                ; $FFFF case where ADD D1,#1 in .check_even would wrap to
                ; $0000 and silently produce a tiny allocation.
                ; Use BHS against MAX+1 since K16 BHI is not implemented.
                MOVE    D1, D0
                CMP     D1, #HR_USABLE_BYTES-BH_HEADER_SIZE+1
                BHS     .nomem

                CMP     D1, #BH_MIN_PAYLOAD
                BHS.S     .check_even
                LOADI   D1, #BH_MIN_PAYLOAD

.check_even:
                MOVE    D2, D1
                AND     D2, #1
                CMP     D2, #0
                BEQ.S     .size_ok
                ADD     D1, #1

.size_ok:
                ; D1 = aligned size
                CALL24  _FindFit
                BCC.S     .got_fit

                ; No fit: try to grow on EMU
                CALL24  _GrowHeap
                BCS     .nomem

                CALL24  _FindFit
                BCS     .nomem

.got_fit:
                ; XY1 = block header. D1 = aligned size.
                LOADD   D2, [XY1+#BH_SIZE]

                ; Decide whether to split: slack = D2 - D1
                MOVE    D3, D2
                SUB     D3, D1
                CMP     D3, #BH_MIN_BLOCK
                BLO.S     .take_whole

                CALL24  _SplitBlock

.take_whole:
                CALL24  _UnlinkFreeBlock

                ; Mark USED (preserve LAST flag)
                LOADD   D2, [XY1+#BH_FLAGS]
                OR      D2, #BH_FLAG_USED
                STORED  D2, [XY1+#BH_FLAGS]

                ; --- Stamp owner TID (Phase 14 Part 3) ---------------------
                ; Read CURRENT_TCB. If 0, scheduler not running yet — stamp
                ; OWNER_KERNEL (= 0). If non-zero, deref TCB+#TCB_ID to get
                ; the owning task's TID.
                LOADZ   D2, [#CURRENT_TCB]
                CMP     D2, #0
                BEQ.S     .stamp_kernel

                ; XY0 = current TCB (page $00, offset = D2)
                PUSH    XY0, XY3
                LOADI   Y0, #$00
                MOVE    X0, D2
                LOADD   D2, [XY0+#TCB_ID]
                POP     XY0, XY3
                BRA.S     .stamp_owner

.stamp_kernel:
                LOADI   D2, #OWNER_KERNEL       ; = 0

.stamp_owner:
                STORED  D2, [XY1+#BH_OWNER_TID]

                ; HEAP_BYTES_FREE -= (block.size + header)
                LOADD   D2, [XY1+#BH_SIZE]
                ADD     D2, #BH_HEADER_SIZE
                LOADZ   D3, [#HEAP_BYTES_FREE]
                SUB     D3, D2
                STOREZ  D3, [#HEAP_BYTES_FREE]

                ; XY0 = payload ptr = block + BH_HEADER_SIZE
                LEA     XY0, XY1+#BH_HEADER_SIZE

                CLC
                BRA.S     .done

.nomem:
                LOADI   D0, #ERR_NOMEM
                SEC

.done:
                POP     XY2, XY3                ; r15: matched against PUSH XY2 at entry
                POP     XY1, XY3
                POP     D123, XY3
                RET

; ============================================================================
; _kfree — free a block and coalesce with adjacent free blocks
;
;   Input:  XY0 = payload pointer (as returned by _kmalloc)
;   Output: C=0 success; C=1 / D0=ERR_INVALID on bad pointer.
;   Clobbers: D0
; ============================================================================
_kfree:
                PUSH    D1, XY3
                PUSH    D2, XY3
                PUSH    XY1, XY3

                ; XY1 = header ptr = payload - 4. LEA can't subtract, so
                ; build manually. Stays within page (XY0 was a payload ptr,
                ; payload offset ≥ $0014 ≥ 4 so no underflow).
                MOVE    Y1, Y0
                MOVE    D1, X0
                SUB     D1, #BH_HEADER_SIZE
                MOVE    X1, D1

                ; Validate: BH_FLAGS must have USED set
                LOADD   D1, [XY1+#BH_FLAGS]
                MOVE    D2, D1
                AND     D2, #BH_FLAG_USED
                CMP     D2, #0
                BEQ     .invalid

                ; Clear USED flag (keep LAST if set)
                AND     D1, #$FFFE
                STORED  D1, [XY1+#BH_FLAGS]

                ; HEAP_BYTES_FREE += (block.size + header)
                LOADD   D2, [XY1+#BH_SIZE]
                ADD     D2, #BH_HEADER_SIZE
                LOADZ   D1, [#HEAP_BYTES_FREE]
                ADD     D1, D2
                STOREZ  D1, [#HEAP_BYTES_FREE]

                CALL24  _InsertFreeBlock

                LOADI   D0, #ERR_OK
                CLC
                BRA.S     .done

.invalid:
                LOADI   D0, #ERR_INVALID
                SEC

.done:
                POP     XY1, XY3
                POP     D2, XY3
                POP     D1, XY3
                RET

; ============================================================================
; _FindFit — first-fit search across all regions
;
;   Input:  D1 = aligned payload size needed
;   Output: XY1 = block header ptr (free, big enough), C=0
;           D0 = 0, C=1 if no block fits
; ============================================================================
_FindFit:
                PUSH    D2, XY3
                PUSH    XY0, XY3

                ; D0 = current region's page byte
                LOADZ   D0, [#HEAP_FIRST_PAGE]

.next_region:
                CMP     D0, #0
                BEQ     .nofit

                ; XY0 = <region_page>:0000 (descriptor)
                MOVE    Y0, D0
                LOADI   X0, #0

                ; Free list head for this region
                LOADD   D2, [XY0+#HR_FREE_HEAD]
                CMP     D2, #0
                BEQ.S     .skip_region

                ; XY1 = first free block (page=D0, offset=D2)
                MOVE    Y1, D0
                MOVE    X1, D2

.scan_block:
                LOADD   D2, [XY1+#BH_SIZE]
                CMP     D2, D1
                BHS.S     .found

                ; Move to next free block — within same region, so only
                ; the X (offset) word matters.
                LOADD   D2, [XY1+#BH_NEXT_X]
                CMP     D2, #0
                BEQ.S     .skip_region

                MOVE    X1, D2
                BRA     .scan_block

.skip_region:
                ; Advance to next region
                LOADD   D2, [XY0+#HR_NEXT_PAGE]
                MOVE    D0, D2
                LOW     D0
                BRA     .next_region

.found:
                CLC
                BRA.S     .done

.nofit:
                LOADI   D0, #0
                SEC

.done:
                POP     XY0, XY3
                POP     D2, XY3
                RET

; ============================================================================
; _SplitBlock — split a free block to satisfy a smaller request
;
;   Input:  XY1 = free block header ptr
;           D1  = aligned size (caller has checked slack ≥ MIN_BLOCK)
;
;   Effect: Head shrinks to D1 (loses LAST if it had it). New tail at
;           <head + BH_HEADER_SIZE + D1> with size (old - D1 - BH_HEADER_SIZE)
;           and LAST inherited. Tail takes head's slot in the free list
;           (head→tail→old_next). HR_BYTES_FREE and HEAP_BYTES_FREE both
;           -= BH_HEADER_SIZE (new tail header is bookkeeping overhead).
;
;   The tail is born free, so its BH_OWNER_TID is 0 — it'll be stamped
;   properly when _kmalloc eventually hands it out. We init it explicitly
;   anyway as defensive hygiene (matches _InitRegion).
;
;   Clobbers: D0
; ============================================================================
_SplitBlock:
                PUSH    D2, XY3
                PUSH    D3, XY3
                PUSH    XY0, XY3

                ; D2 = old size, D3 = old flags
                LOADD   D2, [XY1+#BH_SIZE]
                LOADD   D3, [XY1+#BH_FLAGS]

                ; Tail block address: XY0 = XY1 + BH_HEADER_SIZE + D1
                LEA     XY0, XY1+#BH_HEADER_SIZE
                MOVE    D0, X0
                ADD     D0, D1
                MOVE    X0, D0

                ; Tail size = D2 - D1 - BH_HEADER_SIZE
                MOVE    D0, D2
                SUB     D0, D1
                SUB     D0, #BH_HEADER_SIZE
                STORED  D0, [XY0+#BH_SIZE]

                ; Tail flags: LAST if head had LAST, else 0
                MOVE    D0, D3
                AND     D0, #BH_FLAG_LAST
                STORED  D0, [XY0+#BH_FLAGS]

                ; Tail owner_tid = 0 (free block; stamped when allocated)
                LOADI   D0, #0
                STORED  D0, [XY0+#BH_OWNER_TID]

                ; Tail's free-list next = head's old free-list next
                LOADD   D0, [XY1+#BH_NEXT_Y]
                STORED  D0, [XY0+#BH_NEXT_Y]
                LOADD   D0, [XY1+#BH_NEXT_X]
                STORED  D0, [XY0+#BH_NEXT_X]

                ; Head's BH_SIZE = D1
                STORED  D1, [XY1+#BH_SIZE]

                ; Head loses LAST flag (transferred to tail)
                MOVE    D0, D3
                AND     D0, #$FFFD              ; clear LAST bit
                STORED  D0, [XY1+#BH_FLAGS]

                ; Head's free-list next = tail (page=Y0, offset=X0)
                MOVE    D0, Y0
                LOW     D0
                STORED  D0, [XY1+#BH_NEXT_Y]
                MOVE    D0, X0
                STORED  D0, [XY1+#BH_NEXT_X]

                ; HR_BYTES_FREE -= 4 ; HEAP_BYTES_FREE -= 4
                MOVE    Y0, Y1
                LOADI   X0, #HR_BYTES_FREE
                LOADD   D0, [XY0]
                SUB     D0, #BH_HEADER_SIZE
                STORED  D0, [XY0]
                LOADZ   D0, [#HEAP_BYTES_FREE]
                SUB     D0, #BH_HEADER_SIZE
                STOREZ  D0, [#HEAP_BYTES_FREE]

                POP     XY0, XY3
                POP     D3, XY3
                POP     D2, XY3
                RET

; ============================================================================
; _UnlinkFreeBlock — remove a block from its region's free list
;
;   Input: XY1 = block header ptr (currently on free list)
;   Clobbers: D0
; ============================================================================
_UnlinkFreeBlock:
                PUSH    D2, XY3
                PUSH    D3, XY3
                PUSH    XY0, XY3
                PUSH    XY2, XY3

                ; XY0 = region descriptor
                MOVE    Y0, Y1
                LOADI   X0, #0

                ; D2 = current head offset
                LOADD   D2, [XY0+#HR_FREE_HEAD]

                ; If head IS our block, splice head pointer
                MOVE    D3, X1
                CMP     D2, D3
                BNE.S     .scan

                ; Head was us: HR_FREE_HEAD = our.next_x
                LOADD   D2, [XY1+#BH_NEXT_X]
                STORED  D2, [XY0+#HR_FREE_HEAD]
                BRA     .done

.scan:
                ; Walk free list to find predecessor.
                ; XY2 = current node (same page as XY1) — manual copy.
                MOVE    Y2, Y1
                MOVE    X2, D2

.scan_loop:
                LOADD   D2, [XY2+#BH_NEXT_X]
                MOVE    D3, X1
                CMP     D2, D3
                BEQ.S     .found_pred

                CMP     D2, #0
                BEQ.S     .done                   ; not on list — bail
                MOVE    X2, D2
                BRA     .scan_loop

.found_pred:
                ; pred.next = our.next  (full Y+X copy)
                LOADD   D2, [XY1+#BH_NEXT_Y]
                STORED  D2, [XY2+#BH_NEXT_Y]
                LOADD   D2, [XY1+#BH_NEXT_X]
                STORED  D2, [XY2+#BH_NEXT_X]

.done:
                POP     XY2, XY3
                POP     XY0, XY3
                POP     D3, XY3
                POP     D2, XY3
                RET

; ============================================================================
; _InsertFreeBlock — insert block into free list, coalescing neighbours
;
;   Input: XY1 = block header ptr (USED bit already cleared)
;
;   Walks address-ordered free list; finds insertion point. Then:
;     - Backward coalesce: if (prev + prev.size + 4) == us, merge us into prev
;     - Forward coalesce:  if (us + size + 4) == next physical AND it's free,
;                          merge it into us
;
;   Recovers BH_HEADER_SIZE per coalesce into HR_BYTES_FREE and HEAP_BYTES_FREE.
;   Clobbers: D0
; ============================================================================
_InsertFreeBlock:
                PUSH    D2, XY3
                PUSH    D3, XY3
                PUSH    XY0, XY3
                PUSH    XY2, XY3

                ; XY0 = region descriptor
                MOVE    Y0, Y1
                LOADI   X0, #0

                ; D2 = current head offset
                LOADD   D2, [XY0+#HR_FREE_HEAD]

                ; Empty list? Become sole head.
                CMP     D2, #0
                BEQ     .empty_list

                ; If our offset < head's offset, insert at head
                MOVE    D3, X1
                CMP     D3, D2
                BLO     .insert_at_head

                ; Walk to find predecessor (largest offset < ours).
                MOVE    Y2, Y1                  ; same page
                MOVE    X2, D2

.walk:
                LOADD   D2, [XY2+#BH_NEXT_X]
                CMP     D2, #0
                BEQ     .insert_after_xy2       ; XY2 is last
                MOVE    D3, X1
                CMP     D2, D3
                BHS     .insert_after_xy2       ; current.next ≥ ours

                MOVE    X2, D2
                BRA     .walk

;-----------------------------------------------------------------------------
.empty_list:
                ; HR_FREE_HEAD = X1
                MOVE    D2, X1
                STORED  D2, [XY0+#HR_FREE_HEAD]

                ; XY1.next = nil
                LOADI   D2, #0
                STORED  D2, [XY1+#BH_NEXT_Y]
                STORED  D2, [XY1+#BH_NEXT_X]
                BRA     .done

;-----------------------------------------------------------------------------
.insert_at_head:
                ; XY1.next_y = Y1 (same page); XY1.next_x = old head offset (D2)
                MOVE    D3, Y1
                LOW     D3
                STORED  D3, [XY1+#BH_NEXT_Y]
                STORED  D2, [XY1+#BH_NEXT_X]

                ; HR_FREE_HEAD = X1
                MOVE    D2, X1
                STORED  D2, [XY0+#HR_FREE_HEAD]

                ; No predecessor. Try forward coalesce.
                BRA     .try_forward_coalesce

;-----------------------------------------------------------------------------
.insert_after_xy2:
                ; XY1.next = XY2.next  (full Y+X copy)
                LOADD   D2, [XY2+#BH_NEXT_Y]
                STORED  D2, [XY1+#BH_NEXT_Y]
                LOADD   D2, [XY2+#BH_NEXT_X]
                STORED  D2, [XY1+#BH_NEXT_X]

                ; XY2.next = XY1 (page=Y1, offset=X1)
                MOVE    D2, Y1
                LOW     D2
                STORED  D2, [XY2+#BH_NEXT_Y]
                MOVE    D2, X1
                STORED  D2, [XY2+#BH_NEXT_X]

                ; --- Backward coalesce: XY2 + size + 4 == XY1 ? -----------
                LOADD   D2, [XY2+#BH_SIZE]
                ADD     D2, #BH_HEADER_SIZE
                MOVE    D3, X2
                ADD     D3, D2
                MOVE    D2, X1
                CMP     D2, D3
                BNE     .try_forward_coalesce

                ; Adjacent: merge XY1 into XY2.
                LOADD   D2, [XY2+#BH_SIZE]
                LOADD   D3, [XY1+#BH_SIZE]
                ADD     D2, D3
                ADD     D2, #BH_HEADER_SIZE
                STORED  D2, [XY2+#BH_SIZE]

                ; XY2.next = XY1.next
                LOADD   D2, [XY1+#BH_NEXT_Y]
                STORED  D2, [XY2+#BH_NEXT_Y]
                LOADD   D2, [XY1+#BH_NEXT_X]
                STORED  D2, [XY2+#BH_NEXT_X]

                ; If XY1 was LAST, XY2 inherits LAST
                LOADD   D2, [XY1+#BH_FLAGS]
                AND     D2, #BH_FLAG_LAST
                CMP     D2, #0
                BEQ.S     .b_not_last
                LOADD   D3, [XY2+#BH_FLAGS]
                OR      D3, #BH_FLAG_LAST
                STORED  D3, [XY2+#BH_FLAGS]
.b_not_last:

                ; Recover header
                LOADD   D2, [XY0+#HR_BYTES_FREE]
                ADD     D2, #BH_HEADER_SIZE
                STORED  D2, [XY0+#HR_BYTES_FREE]
                LOADZ   D2, [#HEAP_BYTES_FREE]
                ADD     D2, #BH_HEADER_SIZE
                STOREZ  D2, [#HEAP_BYTES_FREE]

                ; XY1 absorbed into XY2; forward coalesce now operates on
                ; the merged block.
                LEA     XY1, XY2

;-----------------------------------------------------------------------------
.try_forward_coalesce:
                ; If XY1 is LAST, no forward coalesce possible
                LOADD   D2, [XY1+#BH_FLAGS]
                AND     D2, #BH_FLAG_LAST
                CMP     D2, #0
                BNE     .done

                ; Compute next physical block: offset = X1 + size + 4
                LOADD   D2, [XY1+#BH_SIZE]
                ADD     D2, #BH_HEADER_SIZE
                MOVE    D3, X1
                ADD     D3, D2

                ; Sanity: must be < HR_BLOCK_END
                CMP     D3, #HR_BLOCK_END
                BHS     .done

                ; XY2 = next physical block (same page as XY1)
                MOVE    Y2, Y1
                MOVE    X2, D3

                ; Free? (USED bit clear)
                LOADD   D2, [XY2+#BH_FLAGS]
                MOVE    D3, D2
                AND     D3, #BH_FLAG_USED
                CMP     D3, #0
                BNE     .done

                ; Adjacent free block. Merge XY2 into XY1.
                LOADD   D3, [XY1+#BH_SIZE]
                LOADD   D2, [XY2+#BH_SIZE]
                ADD     D3, D2
                ADD     D3, #BH_HEADER_SIZE
                STORED  D3, [XY1+#BH_SIZE]

                ; XY1.next = XY2.next
                LOADD   D3, [XY2+#BH_NEXT_Y]
                STORED  D3, [XY1+#BH_NEXT_Y]
                LOADD   D3, [XY2+#BH_NEXT_X]
                STORED  D3, [XY1+#BH_NEXT_X]

                ; If XY2 was LAST, XY1 inherits LAST
                LOADD   D2, [XY2+#BH_FLAGS]
                AND     D2, #BH_FLAG_LAST
                CMP     D2, #0
                BEQ.S     .f_not_last
                LOADD   D3, [XY1+#BH_FLAGS]
                OR      D3, #BH_FLAG_LAST
                STORED  D3, [XY1+#BH_FLAGS]
.f_not_last:

                ; Recover header
                LOADD   D2, [XY0+#HR_BYTES_FREE]
                ADD     D2, #BH_HEADER_SIZE
                STORED  D2, [XY0+#HR_BYTES_FREE]
                LOADZ   D2, [#HEAP_BYTES_FREE]
                ADD     D2, #BH_HEADER_SIZE
                STOREZ  D2, [#HEAP_BYTES_FREE]

.done:
                POP     XY2, XY3
                POP     XY0, XY3
                POP     D3, XY3
                POP     D2, XY3
                RET

; ============================================================================
; _GrowHeap — claim next page from EMU growth pool, link as new region
;
;   Output: C=0 success / C=1 + D0=ERR_NOMEM if no growth possible.
; ============================================================================
_GrowHeap:
                PUSH    D123, XY3
                PUSH    XY0, XY3

                ; Bail if KOS_KHEAP_END == KOS_KHEAP_BASE (Digital case)
                LOADZ   D1, [#KOS_KHEAP_END]
                LOW     D1
                LOADZ   D2, [#KOS_KHEAP_BASE]
                LOW     D2
                CMP     D1, D2
                BEQ     .nogrow

                ; D1 = end (low byte), D2 = candidate (start at growth pool base)
                LOADI   D2, #KHEAP_POOL_BASE_EMU

.try_page:
                ; Beyond end? (D2 > D1 ⇔ D1 < D2)
                CMP     D1, D2
                BLO     .nogrow

                ; Is D2 already in the heap chain?
                LOADZ   D3, [#HEAP_FIRST_PAGE]
                LOW     D3
.chain_walk:
                CMP     D3, #0
                BEQ.S     .free_page              ; reached end of chain
                CMP     D3, D2
                BEQ.S     .next_candidate         ; already in chain

                ; D3 = page-at-D3's HR_NEXT_PAGE
                MOVE    Y0, D3
                LOADI   X0, #HR_NEXT_PAGE
                LOADD   D3, [XY0]
                LOW     D3
                BRA     .chain_walk

.next_candidate:
                ADD     D2, #1
                BRA     .try_page

.free_page:
                ; D2 is free. Initialise it as a new region with no next.
                MOVE    D0, D2
                LOADI   D1, #0
                CALL24  _InitRegion

                ; Find tail of chain and append D2
                LOADZ   D3, [#HEAP_FIRST_PAGE]
                LOW     D3
.find_tail:
                MOVE    Y0, D3
                LOADI   X0, #HR_NEXT_PAGE
                LOADD   D1, [XY0]
                LOW     D1
                CMP     D1, #0
                BEQ.S     .at_tail
                MOVE    D3, D1
                BRA     .find_tail
.at_tail:
                STORED  D2, [XY0]               ; tail.HR_NEXT_PAGE = new

                LOADZ   D1, [#HEAP_REGIONS]
                ADD     D1, #1
                STOREZ  D1, [#HEAP_REGIONS]

                LOADZ   D1, [#HEAP_BYTES_FREE]
                ADD     D1, #HR_USABLE_BYTES-BH_HEADER_SIZE
                STOREZ  D1, [#HEAP_BYTES_FREE]

                CLC
                BRA.S     .done

.nogrow:
                LOADI   D0, #ERR_NOMEM
                SEC

.done:
                POP     XY0, XY3
                POP     D123, XY3
                RET

; ============================================================================
; _krealloc — resize an allocation
;
;   Input:  XY0 = current payload pointer (Y0 = page, X0 = offset)
;                 OR Y0:X0 = $00:$0000 to act as plain _kmalloc
;           D0  = new size in bytes
;
;   Output: XY0 = new payload pointer, C = 0 on success
;           D0  = ERR_NOMEM or ERR_INVALID, C = 1 on failure
;                 On ERR_NOMEM the original XY0 is restored (caller still
;                 owns the old, unmoved block — per C realloc contract).
;
;   Semantics:
;     _krealloc(0:0, n)    == _kmalloc(n)
;     _krealloc(p, 0)      -> ERR_INVALID (footgun guard; differs from C)
;     _krealloc(p, n<=cur) -> in-place; returns same XY0 (no shrink-split yet)
;     _krealloc(p, n>cur)  -> malloc-new, byte-copy old payload, free old
;
;   Clobbers: D0 (success and failure)
;   Preserves: D1, D2, D3, XY1, XY2 (saved/restored)
; ============================================================================
_krealloc:
                PUSH    D123, XY3
                PUSH    XY1, XY3
                PUSH    XY2, XY3

                ; -------- (1) size == 0 -> ERR_INVALID -----------------------
                CMP     D0, #0
                BEQ     .kr_invalid

                ; Stash new size in D3 (D1/D2 used as scratch below).
                MOVE    D3, D0

                ; -------- (2) NULL pointer -> behave as malloc ---------------
                MOVE    D1, X0
                MOVE    D2, Y0
                OR      D1, D2
                CMP     D1, #0
                BNE.S     .kr_have_ptr

                MOVE    D0, D3
                CALL24  _kmalloc
                BRA     .kr_done                ; propagate C and D0

.kr_have_ptr:
                ; -------- (3) Validate the existing block --------------------
                ; Header at payload - 4. Same shape as _kfree.
                MOVE    Y1, Y0
                MOVE    D1, X0
                SUB     D1, #BH_HEADER_SIZE
                MOVE    X1, D1

                LOADD   D1, [XY1+#BH_FLAGS]
                MOVE    D2, D1
                AND     D2, #BH_FLAG_USED
                CMP     D2, #0
                BEQ     .kr_invalid

                ; -------- (4) New size fits in current block? ----------------
                LOADD   D1, [XY1+#BH_SIZE]      ; D1 = old payload size
                CMP     D1, D3
                BLO.S     .kr_grow              ; old < new -> need bigger

                ; In-place: return same XY0, success.
                CLC
                BRA     .kr_done

.kr_grow:
                ; -------- (5) Allocate new block ----------------------------
                ; Old payload ptr is currently in XY0. _kmalloc clobbers XY0
                ; with the new block pointer on success, so we must stash the
                ; old pointer first. Park it on the stack and reload into XY2
                ; after _kmalloc returns (XY2 is our source cursor for the
                ; byte-copy below).
                ;
                ; (Pre-r15 of kos_kmalloc.asm, _kmalloc also clobbered XY2 via
                ; _FindFit / _SplitBlock and this PUSH did double duty as XY2
                ; preservation. r15 made _kmalloc save XY2 internally; we now
                ; only need this PUSH for the XY0 stash.)
                PUSH    XY0, XY3                ; [SP] = old payload ptr

                MOVE    D0, D3
                CALL24  _kmalloc                ; XY0 := new payload OR C=1
                BCS     .kr_nomem_grow_pop

                ; -------- (6) Byte-copy old -> new ---------------------------
                ; Pop the saved old payload ptr into XY2 for the copy loop's
                ; source cursor. (XY0 is the new payload, the dest cursor.)
                POP     XY2, XY3                ; XY2 = old payload

                ; Rebuild XY1 = old header (= old payload - 6) to read size.
                MOVE    Y1, Y2
                MOVE    D1, X2
                SUB     D1, #BH_HEADER_SIZE
                MOVE    X1, D1
                LOADD   D2, [XY1+#BH_SIZE]      ; D2 = byte count

                ; Save the new payload start AND the old payload start
                ; (X2). The copy loop advances both X0 and X2, so without
                ; saving them we'd pass _kfree a pointer to the END of
                ; the old block, not its start — _kfree would silently
                ; fail validation and the old block would leak. Caught
                ; via T8 baseline mismatch on 17 May 2026.
                PUSH    X0, XY3
                PUSH    X2, XY3

.kr_copy_loop:
                CMP     D2, #0
                BEQ.S     .kr_copy_done
                LOADB   D1, [XY2]
                STOREB  D1, [XY0]
                INC     X2, #1
                INC     X0, #1
                SUB     D2, #1
                BRA     .kr_copy_loop

.kr_copy_done:
                POP     X2, XY3                 ; restore old payload start
                POP     X0, XY3                 ; restore new payload start
                ; Y0 and Y2 were untouched by the loop (payload stays
                ; within one page).

                ; -------- (7) Free the old block ----------------------------
                ; _kfree wants XY0 = old payload. Stash new XY0, swap in old,
                ; call, swap back.
                PUSH    XY0, XY3                ; save new payload ptr
                MOVE    X0, X2
                MOVE    Y0, Y2
                CALL24  _kfree                  ; ignore result
                POP     XY0, XY3                ; restore new payload ptr

                CLC
                BRA     .kr_done

.kr_nomem_grow_pop:
                ; _kmalloc failed but we have an old-ptr stash on the stack.
                ; Pop it back into XY0 (the return register) and propagate
                ; ERR_NOMEM with C=1 — caller still owns the old, unmoved
                ; block (per C realloc contract).
                POP     XY0, XY3
                LOADI   D0, #ERR_NOMEM
                SEC
                BRA     .kr_done

.kr_invalid:
                LOADI   D0, #ERR_INVALID
                SEC

.kr_done:
                POP     XY2, XY3
                POP     XY1, XY3
                POP     D123, XY3
                RET


; ============================================================================
; _HeapStatsFull — return free / used / largest-free / region count.
;
;   Output: D0 = total bytes free          (== HEAP_BYTES_FREE)
;           D1 = total bytes used          (capacity - free; exact)
;           D2 = largest contiguous free block (payload bytes)
;           D3 = region count
;           C  = 0 (no failure mode)
;
;   Notes:
;     - All counts are payload bytes. Block headers (4B each) are not
;       counted as free or used. Matches what user code cares about.
;     - "Largest" walks every region's free list once. O(free-blocks),
;       small in practice; not perf-critical.
;
;   Clobbers: D0..D3, X1, Y1, X2, Y2 (caller saves anything needed).
; ============================================================================
_HeapStatsFull:
                ; --- Region count, capacity, used ----------------------------
                LOADZ   D3, [#HEAP_REGIONS]
                LOW     D3

                ; Total capacity = regions * (HR_USABLE_BYTES - BH_HEADER_SIZE).
                ; Region count is small (1..62); use repeated add.
                LOADI   D1, #0
                MOVE    D2, D3
.hsf_cap_loop:
                CMP     D2, #0
                BEQ.S     .hsf_cap_done
                ADD     D1, #HR_USABLE_BYTES-BH_HEADER_SIZE
                SUB     D2, #1
                BRA     .hsf_cap_loop
.hsf_cap_done:
                LOADZ   D0, [#HEAP_BYTES_FREE]
                SUB     D1, D0                  ; D1 = used

                ; --- Largest free block --------------------------------------
                LOADI   D2, #0                  ; D2 = running max
                LOADZ   D0, [#HEAP_FIRST_PAGE]
                LOW     D0
.hsf_region_loop:
                CMP     D0, #0
                BEQ     .hsf_largest_done

                MOVE    Y1, D0
                LOADI   X1, #0                  ; XY1 = region descriptor

                LOADD   D0, [XY1+#HR_FREE_HEAD]
                CMP     D0, #0
                BEQ     .hsf_next_region

                MOVE    Y2, Y1
                MOVE    X2, D0                  ; XY2 = first free block

.hsf_block_loop:
                ; "Update D2 if block's BH_SIZE > current max."
                ; K16 has no BHI/BLS — synthesise unsigned ≤ as: reverse
                ; the CMP operands and use BHS. "CMP D2,D0 / BHS skip"
                ; reads as "if D2 ≥ D0, skip update" — same as "if D0 ≤ D2".
                LOADD   D0, [XY2+#BH_SIZE]
                CMP     D2, D0
                BHS.S     .hsf_not_bigger
                MOVE    D2, D0
.hsf_not_bigger:
                LOADD   D0, [XY2+#BH_NEXT_X]
                CMP     D0, #0
                BEQ.S     .hsf_next_region
                MOVE    X2, D0
                BRA     .hsf_block_loop


.hsf_next_region:
                LOADD   D0, [XY1+#HR_NEXT_PAGE]
                LOW     D0
                BRA     .hsf_region_loop

.hsf_largest_done:
                ; D1 = used, D2 = largest, D3 = regions.
                ; Reload D0 = free.
                LOADZ   D0, [#HEAP_BYTES_FREE]
                CLC
                RET


; ============================================================================
; _HeapStatsByTid — count USED blocks and bytes owned by a given TID.
;
;   Input:  D0 = owner TID to query (0 = kernel-owned blocks)
;
;   Output: D1 = block count
;           D2 = total payload bytes (no headers)
;           C  = 0 always
;
;   Walks every region's blocks in physical order (not the free list).
;   For each block with BH_FLAG_USED set AND BH_OWNER_TID == TID,
;   accumulates count and bytes. Skips free blocks (their owner_tid
;   value is undefined-but-harmless).
;
;   Clobbers: D0, D1, D2, D3, X1, Y1, X2, Y2
;
;   Used by kosh 'meminfo' and the sys_heapstats_by_tid TRAP wrapper.
;
;   Register plan:
;     HEAP_TID_QUERY  target TID (stashed; freed up D-reg pressure)
;     D1              block count (output)
;     D2              byte count  (output)
;     D0, D3          scratch
;     XY1             region descriptor (Y1 = region page, X1 = 0)
;     XY2             current block ptr (X2 = block offset within region)
; ============================================================================
_HeapStatsByTid:
                ; Stash target TID in page-$00 scratch.
                STOREZ  D0, [#HEAP_TID_QUERY]

                ; Zero the accumulators.
                LOADI   D1, #0
                LOADI   D2, #0

                ; D0 = first region's page (or 0 if no heap).
                LOADZ   D0, [#HEAP_FIRST_PAGE]
                LOW     D0

.hsbt_region_loop:
                CMP     D0, #0
                BEQ     .hsbt_done

                ; XY1 = region descriptor at <page>:0000.
                MOVE    Y1, D0
                LOADI   X1, #0

                ; XY2 = first block at <page>:HR_BLOCK_BASE.
                MOVE    Y2, Y1
                LOADI   X2, #HR_BLOCK_BASE

.hsbt_block_loop:
                ; USED bit set?
                LOADD   D0, [XY2+#BH_FLAGS]
                AND     D0, #BH_FLAG_USED
                CMP     D0, #0
                BEQ.S     .hsbt_check_last

                ; Used — compare owner against target.
                LOADD   D0, [XY2+#BH_OWNER_TID]
                LOADZ   D3, [#HEAP_TID_QUERY]
                CMP     D0, D3
                BNE.S     .hsbt_check_last

                ; Match — accumulate.
                ADD     D1, #1
                LOADD   D0, [XY2+#BH_SIZE]
                ADD     D2, D0

.hsbt_check_last:
                ; Re-load flags (we clobbered D0). Check LAST.
                LOADD   D0, [XY2+#BH_FLAGS]
                AND     D0, #BH_FLAG_LAST
                CMP     D0, #0
                BNE     .hsbt_next_region

                ; Advance X2 by (size + HEADER_SIZE).
                LOADD   D0, [XY2+#BH_SIZE]
                ADD     D0, #BH_HEADER_SIZE
                MOVE    D3, X2
                ADD     D3, D0
                MOVE    X2, D3
                BRA     .hsbt_block_loop

.hsbt_next_region:
                ; Next region (chain through HR_NEXT_PAGE).
                LOADD   D0, [XY1+#HR_NEXT_PAGE]
                LOW     D0
                BRA     .hsbt_region_loop

.hsbt_done:
                CLC
                RET


; ============================================================================
; _ReapByTid — free every USED block owned by a given TID.
;
;   Input:  D0 = owner TID to reap (0 is permitted but pointless — kernel
;                allocations are stamped OWNER_KERNEL = 0 and survive by
;                convention)
;
;   Output: none (C indeterminate; the routine does not fail)
;
;   Walks every region's blocks in physical order. For each block with
;   BH_FLAG_USED set AND BH_OWNER_TID == TID, calls _kfree to release it.
;
;   Safety: _kfree mutates the free list and may coalesce the just-freed
;   block with its physical neighbours. After each _kfree, we restart the
;   current region's walk from HR_BLOCK_BASE. The newly-coalesced block
;   has USED = 0 so the restart skips it harmlessly. Restart is O(N) per
;   freed block but reap runs at task death only and N is small.
;
;   Called from kos_tcb.asm's _ReapDeadTask (hook deferred — lands after
;   helpers are verified by htest TX-TD).
;
;   Register plan: same as _HeapStatsByTid for walk; everything except
;   the page-$00 stashes is callee-saved across _kfree by reload.
;
;     HEAP_TID_QUERY   target TID
;     HEAP_RBT_REGION  current region page (survives _kfree)
;     D0, D3           scratch
;     XY1              region descriptor (reload from HEAP_RBT_REGION)
;     XY2              current block ptr (reload after _kfree)
;
;   Clobbers: D0, D1, D2, D3, X0, Y0, X1, Y1, X2, Y2
; ============================================================================
_ReapByTid:
                STOREZ  D0, [#HEAP_TID_QUERY]

                LOADZ   D0, [#HEAP_FIRST_PAGE]
                LOW     D0

.rbt_region_loop:
                CMP     D0, #0
                BEQ     .rbt_done

                ; Save region page so we can resume after _kfree clobber.
                STOREZ  D0, [#HEAP_RBT_REGION]

                MOVE    Y1, D0
                LOADI   X1, #0
                MOVE    Y2, Y1
                LOADI   X2, #HR_BLOCK_BASE

.rbt_block_loop:
                ; USED bit set?
                LOADD   D0, [XY2+#BH_FLAGS]
                AND     D0, #BH_FLAG_USED
                CMP     D0, #0
                BEQ     .rbt_check_last

                ; Used — compare owner.
                LOADD   D0, [XY2+#BH_OWNER_TID]
                LOADZ   D3, [#HEAP_TID_QUERY]
                CMP     D0, D3
                BNE     .rbt_check_last

                ; Match — free it. _kfree wants XY0 = payload.
                LEA     XY0, XY2+#BH_HEADER_SIZE
                CALL24  _kfree

                ; _kfree clobbered everything. Restart this region's
                ; walk from HR_BLOCK_BASE. The freed-and-possibly-
                ; coalesced block now has USED clear so the re-walk
                ; skips it. The next match (if any) gets freed on
                ; this re-walk.
                LOADZ   D0, [#HEAP_RBT_REGION]
                MOVE    Y1, D0
                LOADI   X1, #0
                MOVE    Y2, Y1
                LOADI   X2, #HR_BLOCK_BASE
                BRA     .rbt_block_loop

.rbt_check_last:
                ; Re-load flags. Check LAST.
                LOADD   D0, [XY2+#BH_FLAGS]
                AND     D0, #BH_FLAG_LAST
                CMP     D0, #0
                BNE     .rbt_next_region

                ; Advance X2 by (size + HEADER_SIZE).
                LOADD   D0, [XY2+#BH_SIZE]
                ADD     D0, #BH_HEADER_SIZE
                MOVE    D3, X2
                ADD     D3, D0
                MOVE    X2, D3
                BRA     .rbt_block_loop

.rbt_next_region:
                ; XY1 still valid here (no _kfree on the path that
                ; reaches this label). Walk to next region.
                LOADD   D0, [XY1+#HR_NEXT_PAGE]
                LOW     D0
                BRA     .rbt_region_loop

.rbt_done:
                RET


; ============================================================================
; _HeapStats — total bytes free across all regions (capped $FFFF)
; ============================================================================
_HeapStats:
                LOADZ   D0, [#HEAP_BYTES_FREE]
                RET

; ============================================================================
; End of kos_kmalloc.asm
; ============================================================================
