; ============================================================================
; kos_defs.inc — k/OS shared constants (Phase 1, Phase 2, Phase 3)
; ============================================================================
; Date:    29 May 2026
; Status:  Part 40 — kernel identity (KOS_INFO_*) at $A300..$A30B.
; Revision: r44 — 29 May 2026 — Part 40: added KOS_PHASE_TAG_PAGE ($A30A)
;               so the phase-tag pointer is published as a COMPLETE 24-bit
;               address. The kernel's ROM (code + ROM data, incl. the
;               phase-tag string) lives at page $FF (kos_boot.asm is
;               .ORG $FF0000); the page-$00 slots are kernel zero-page
;               RAM. The r43 slot stored only the 16-bit offset and the
;               doc wrongly said "page byte is $00" — a consumer that
;               built a $00:offset pointer read kernel RAM, not the ROM
;               string, and printed nothing. Now: KOS_PHASE_TAG_PTR =
;               #<_KosPhaseTag (offset), KOS_PHASE_TAG_PAGE = #>_KosPhaseTag
;               (page, $FF). Consumers read both, build XY0, and sys_puts
;               (which honours the page byte). Page-$00 work area continued
;               now $A30C..$BBFF. Requires kos_boot.asm r52+.
;
;           r43 — 29 May 2026 — Part 39 r-final: published kernel identity
;               at page-$00 slots $A300..$A309. Five words:
;                 $A300  KOS_VERSION
;                 $A302  KOS_BUILD_YEAR
;                 $A304  KOS_BUILD_MONTH
;                 $A306  KOS_BUILD_DAY
;                 $A308  KOS_PHASE_TAG_PTR
;               Written by _InitKernel from the source-of-truth constants
;               in kos_boot.asm (KOS_VERSION_VALUE, KOS_BUILD_YEAR_VALUE,
;               KOS_BUILD_MONTH_VALUE, KOS_BUILD_DAY_VALUE) and the kernel-
;               ROM phase-tag string. Eliminates the prior pattern where
;               kosh hardcoded "k/OS v1.0 Phase 39+" in its splash logo —
;               kosh now LOADZ-es these slots and formats at runtime.
;
;               Page-$00 map updated: kernel work area continued now
;               $A30A..$BBFF (was $A300..$BBFF).
;
;               Requires kos_boot.asm r51+ (defines the source values
;               and copies them into the slots in _InitKernel).
;
; Revision: r42 — 29 May 2026 — Part 39 (kosh.com migration). Two changes:
;               1. Added RESET_VECTOR ($FF0000) for use by user-space
;                  code that wants to reboot via JMP24 RESET_VECTOR.
;                  The kernel-side `Start` label remains canonical and
;                  unchanged; this just gives standalone user assemblies
;                  a way to reach it without depending on a kernel-
;                  internal symbol.
;               2. Updated the page-$00 map to add the EMULIB jump-table
;                  region at $A200..$A2FF (64 entries × 4 bytes). EMULIB
;                  is the emulator-only host-disk shim ABI; see
;                  emulib/kos_emulib.inc r1. Sits immediately after the
;                  reserved GLIB region at $A100..$A1FF. Kernel work
;                  area continued shrinks accordingly to $A300..$BBFF.
;
;           r41 — 18 May 2026 — Part 34: TRAP_DISKFREE / VEC_DISKFREE.
;               TRAP_DISKFREE = 68 at VEC_DISKFREE = $0110. First entry in
;               the FS-group reserved tail ($0110..$0128); five more slots
;               still reserved.
;
;           r40 — 17 May 2026. Phase 14 Part 3 page-$00 audit fix.
;               r38/r39 placed the heap helper scratch slots at
;               $0330..$033B believing $0340..$03FF was "reserved" per
;               the page-$00 layout comment in THIS file. The comment
;               was stale — the volume table actually runs $0260..$03DF
;               (6 × 64-byte slots), so $0330 sat inside slot D, offset
;               $10. Every _HeapStatsByTid call silently corrupted
;               drive D's volume entry. Bug was latent (drives D/E/F
;               typically unmounted) but would have surfaced as soon as
;               a fourth drive was mounted.
;
;               Fix this revision:
;                 • Moved HEAP_TID_QUERY from $0330 to $03F0.
;                 • Moved HEAP_RBT_REGION from $0332 to $03F2.
;                 • Removed HEAP_SCRATCH0..3 (declared r38 but never
;                   read/written by the final _HeapStatsByTid /
;                   _ReapByTid code).
;                 • Updated the page-$00 layout comment in this file
;                   to match the canonical layout in the kOS Reference
;                   Manual section 2.2 (which was already correct).
;
;               No source code changes in kos_kmalloc.asm — all access
;               is symbolic via HEAP_TID_QUERY / HEAP_RBT_REGION.
;
;               Cross-references: this was the same class of bug that
;               triggered Gotcha 4.25 (Part 22 r9 FD scratch relocation
;               from $0370 after volume-table expansion overlap). Future
;               page-$00 slot allocations must consult the manual's §2.2,
;               not legacy comments in this file. New entries in the
;               kOS Gotchas catalogue this revision: §4.26 (the page-$00
;               layout comment was lying) and §4.27 (kernel-side smokes
;               must use _RawPuts not TRAP_PUTS to avoid the foreground-
;               shell dereference fault).
;
;           r39 — 17 May 2026. Phase 14 Part 3b: ownership consumers.
;               New TRAP/VEC slot in the Memory group:
;                 • VEC_HEAPSTATS_BY_TID ($00B0) / TRAP_HEAPSTATS_BY_TID (44)
;               Memory group now uses 5 of 10 slots; $00B4..$00C4 still
;               reserved (TRAP #45..#49).
;               No layout change; no new sysvar. The heap-helper scratch
;               slots at $0330..$033B (declared in r38) are now consumed
;               by _HeapStatsByTid and _ReapByTid.
;               Requires kos_kmalloc.asm r14+ (adds _HeapStatsByTid and
;               _ReapByTid), kos_heap.asm r3+ (adds sys_heapstats_by_tid
;               wrapper), and kos_boot.asm r47+ (installs the new vector).
;               _ReapDeadTask hook deferred — kos_tcb.asm unchanged.
;
;           r38 — 17 May 2026. Phase 14 Parts 2 & 3a.
;
;               Part 2 — new syscalls:
;                 • VEC_KREALLOC ($00A8) / TRAP_KREALLOC (42)
;                 • VEC_HEAPSTATS ($00AC) / TRAP_HEAPSTATS (43)
;                 Memory group now uses 4 of 10 slots; $00B0..$00C4 still
;                 reserved (TRAP #44..#49).
;
;               Part 3a — block header layout change + ownership stamp:
;                 BH_HEADER_SIZE 4 → 6 (was: size, flags; now: size, flags,
;                 owner_tid). BH_PAYLOAD / BH_NEXT_Y slide from $04 to $06.
;                 BH_NEXT_X slides from $06 to $08 (still ≤ IMM5 range, so
;                 all mode-01 [XY+#imm5] accesses unchanged). BH_MIN_BLOCK
;                 8 → 10. New constants: BH_OWNER_TID ($04), OWNER_KERNEL (0).
;
;                 ABI impact: every allocation pays 2 extra bytes forever.
;                 Minimum block grows from 8 to 10 bytes. No call-site
;                 changes — all kos_kmalloc.asm references are symbolic.
;
;                 Ownership semantics: _kmalloc reads CURRENT_TCB → TCB_ID
;                 and stamps BH_OWNER_TID. If CURRENT_TCB == 0 (boot
;                 context), block is stamped OWNER_KERNEL = 0. This part
;                 (Part 3a) makes every allocation carry a valid owner —
;                 a no-op at runtime, but a structural prerequisite for
;                 the consumer helpers in Part 3b.
;
;                 New page-$00 scratch slots at $0330..$033B
;                 (HEAP_TID_QUERY etc.) reserved for the deferred Part 3b
;                 helpers. They're declared here so the slot numbering is
;                 final, even though nothing reads them yet.
;
;               Part 3b — consumers — DEFERRED:
;                 _HeapStatsByTid, _ReapByTid, _ReapDeadTask reap hook,
;                 and the kosh 'meminfo' command land in a future revision.
;
;               Requires kos_kmalloc.asm r13+ (_krealloc, _HeapStatsFull,
;               owner-stamp in _kmalloc), kos_heap.asm r2+ (sys_krealloc /
;               sys_heapstats wrappers), and kos_boot.asm r46+ (installs
;               the two new vectors).
;
;           r37 — 14 May 2026. k/OS Part 30 hygiene pass.
;               Deleted unused/misleading constants:
;                 • TERMINAL ($DF0000) / KEYBOARD ($DE0000) — 24-bit
;                   absolute aliases. All code uses the corresponding
;                   _PAGE byte + low-word offset; the 24-bit forms
;                   couldn't be loaded as immediates anyway.
;                 • USER_PAGE_END / USER_PAGE_COUNT — compile-time maxes
;                   that hid the real runtime cap in KOS_USER_PAGE_END.
;                   USER_PAGE_END_DIGITAL / _EMU stay for compile-time
;                   bounds where needed.
;                 • TASK_PAGE_BASE / TASK_PAGE_END — deprecated aliases
;                   for USER_PAGE_BASE / USER_PAGE_END. Two call sites
;                   in kos_spawn.asm migrated to the canonical names
;                   (USER_PAGE_BASE / USER_PAGE_END_EMU+1). Requires
;                   kos_spawn.asm r7+.
;                 • TASK_A_PAGE / TASK_B_PAGE / TASK_C_PAGE /
;                   TASK_STACK_TOP — convenience constants from the
;                   pre-dynamic-task era. Zero call sites.
;                 • BT_NAME_LEN — unused literal that documented the
;                   BT_NAME buffer size; _BuildTask uses 32 inline.
;               No semantic changes; net ROM saving is zero (constants
;               only). Pure clarity improvement.
;               Requires kos_spawn.asm r7+, kos_kbd.asm r4+ (the latter
;               brings KEY_CTRL_DIGIT_FIRST/LAST into actual use).
;
;           r36 — 14 May 2026. k/OS Part 30: SYS_TICKS promoted to 32 bits.
;               • SYS_FLAGS at $0202 renamed to SYS_TICKS_HI. SYS_FLAGS
;                 was written once at boot (zero) and never read, so the
;                 slot was effectively free. SYS_TICKS_HI now holds the
;                 high word of a 32-bit system tick counter; bumped via
;                 ADC in _TimerIRQ when the low word carries.
;                 Wraps at ~4.5 years @ 30 Hz instead of 36 minutes.
;               Requires kos_ctxsw.asm r34+ (ADC chain) and kos_boot.asm
;               r45+ (boot init writes 0 to the renamed slot).
;
;           r35 — 13 May 2026. Phase B Step 2: shell-ring walk +
;               foreground-set syscall constants.
;               • Added VEC_SETFOREGROUND ($0130) / TRAP_SETFOREGROUND (76)
;                 for sys_setforeground.
;               • Added MAX_SHELL_RING_LEN (16) — defensive walk cap used
;                 by _SwitchForegroundPrev's forward walk through a
;                 singly-linked ring.
;               No layout change; no new sysvar; no new TCB field.
;               Step 2 helpers (_SwitchForegroundNext/Prev) and the
;               sys_setforeground syscall body live in kos_switcher.asm r2.
;
; Revision: r34 — 13 May 2026. Phase B Step 1: TCB extension + shell
;               registration scaffolding.
;               • Added FOREGROUND_TCB sysvar at $00:$0238 (word — TID of
;                 foreground shell; 0 = none). Slot was free between
;                 VIDEO_OWNER_TID ($0236) and BT_NAME ($0240).
;               • Added TF_HAS_BACKBUF flag (TCB_FLAGS bit 3, value $0008)
;                 — task is a registered shell. Output syscalls (Step 3)
;                 will route through the per-task back-buffer when this
;                 bit is set; sys_getchar (Step 4) will gate on
;                 FOREGROUND_TCB matching the caller's TID.
;               • Added four TCB fields inside the existing TCB_RESERVED
;                 zone ($22..$5F); no layout shift:
;                   TCB_BACKBUF_OFFS $4C  word — back-buffer offset in page
;                   TCB_BACKBUF_PAGE $4E  word — back-buffer page byte
;                   TCB_SHELL_NEXT   $50  word — next-shell page-$00 offset
;                   TCB_BACKBUF_CRSR $52  word — packed cursor hi=row lo=col
;                 _BuildTask already zero-fills $20..$7F, so no init change
;                 is needed. TCB_RESERVED comment narrowed to $22..$4B.
;               • Added BACKBUF_SIZE (2400), KOS_TERM_COLS (80),
;                 KOS_TERM_ROWS (30) constants.
;               • Added TRAP_REGISTER_SHELL (77) / VEC_REGISTER_SHELL
;                 ($0134) in the device vector group.
;               • Pinned Phase B hot-key codes (verified 13 May 2026 via
;                 keydump.com on EMU; Digital expected to emit matching
;                 codes natively via Swing keyTyped):
;                   KEY_CTRL_N $0E  next shell  (also Ctrl-RightArrow on EMU)
;                   KEY_CTRL_P $10  prev shell  (also Ctrl-LeftArrow  on EMU)
;                   KEY_CTRL_1..9 $81..$89, KEY_CTRL_0 $8A — EMU-only direct
;                     shell-index jumps; high-nibble $8 marks synthesised
;                     virtual key, low nibble = digit (0 → "shell 10").
;
; Revision: r33 — 13 May 2026. Phase A: keyboard ring buffer.
;               • Added KBD_RING_BUF ($2780) and KBD_RING_MASK ($003F) for
;                 the 64-byte SPSC keyboard ring. KBD_HEAD/KBD_TAIL slots
;                 (long pre-allocated at $0204/$0206 as "P6") now have a
;                 defined backing buffer and accompanying constants.
;               • Page-$00 map updated: ring occupies $2780..$27BF, kernel
;                 work area now starts at $27C0. No collision — TCB pool
;                 ends exactly at $2780 (TCB_POOL_END).
;               • Producer: _KbdTick inline in _TimerIRQ (kos_ctxsw.asm)
;                 calls _KbdDispatch → _RingPush (kdrv/kos_kbd.asm).
;               • Consumer: sys_getchar = BRA _RingWaitPop. Existing TRAP
;                 vector unchanged.
;
; Revision: r32 — 12 May 2026. Part 28: TF_SYSCRITICAL flag.
;               • Added TF_SYSCRITICAL (TCB_FLAGS bit 2, value $0004) —
;                 "this task may not be killed". sys_kill refuses victims
;                 with this bit set regardless of caller privilege, returning
;                 ERR_PERM. Closes the kill-1 hole: kosh sets both TF_PRIV
;                 and TF_SYSCRITICAL after _BuildTask so no other task
;                 (privileged or not) can kill kosh and leave the system
;                 shellless. Orthogonal to TF_PRIV — a task can be one,
;                 the other, both, or neither.
;               • Body wiring in kos_task.asm r16, kosh.asm r33.
;               • No layout changes — one new constant.
;
; Revision: r31 — 12 May 2026. Cleanup: HOST_DISK_SEM moved here.
;               • Page-$00 sysvar slots should all live in this file as
;                 the single registry. HOST_DISK_SEM was declared in
;                 kos_fs_host.asm (Part 22), invisible to anyone adding
;                 new slots — collided with VIDEO_OWNER_TID's first
;                 placement at $0234 (r30) and broke host-disk init.
;                 Symbol moved here; module-private declaration replaced
;                 with a "see kos_defs.inc" comment.
;               • No functional change beyond restoring correctness.
;
; Revision: r30 — 12 May 2026. Part 20: sys_setvidmode plumbing.
;               • Added VIDEO_OWNER_TID slot at $00:$0236 (word, low byte
;                 used). Holds TID of task that owns the VID_MODE MMIO
;                 register; 0 = unowned (text-mode default).
;                 (Initially placed at $0234, but that collided with
;                  HOST_DISK_SEM declared in kos_fs_host.asm. Worth a
;                  follow-up: move HOST_DISK_SEM declaration into this
;                  file so all page-$00 slot allocations live in one
;                  registry.)
;               • Body in kos_video.asm r1. Auto-release on owner death
;                 is wired into _HandleDeadTCB and sys_exit (kos_task.asm
;                 r15).
;
; Revision: r29 — 12 May 2026. Part 20: sys_kill plumbing.
;               • Added TF_PRIV (TCB_FLAGS bit 1, value $0002) — privilege
;                 flag for sys_kill. Bit 0 (TF_SEM_KERNEL_WAITER) already in use.
;               • Added KILL_EXIT_CODE ($FFFF) — sentinel exit code stored
;                 by sys_kill on the victim's TCB_EXIT_CODE.
;               • Added ERR_PERM ($FFF6) — permission denied.
;               • Added ERR_BUSY ($FFF5) — resource busy / contended.
;                 Used by sys_kill for "victim is TS_SEMWAIT, can't unlink
;                 from sem queue" (v1 limitation); reserved for sys_setvidmode
;                 acquire failure too.
;               • No layout changes — only new constants.
;
; Revision: r28 — 12 May 2026. Part 20: domain-grouped syscall renumber.
;               • All TRAP / VEC numbers renumbered into domain groups
;                 with deliberate reservation per group. New layout:
;                   TRAP  10..24   Console     (15 slots)   $0028..
;                   TRAP  25..39   Task        (15 slots)   $0064..
;                   TRAP  40..49   Memory      (10 slots)   $00A0..
;                   TRAP  50..59   Sync        (10 slots)   $00C8..
;                   TRAP  60..74   FS          (15 slots)   $00F0..
;                   TRAP  75..84   Device      (10 slots)   $012C..
;                   TRAP  85..127  Reserved    (43 slots)   $0154..
;               • EXEC reclassified semantically as Task (was in FS by
;                 accident of Phase 16 ordering). Vector number unchanged
;                 (still TRAP #31 — TRAP 31 happens to land inside the
;                 new Task range).
;               • All other syscalls move. Only kos_defs.inc changes;
;                 every other file uses TRAP_* / VEC_* symbols and just
;                 needs a rebuild.
;               • New slots reserved: VEC_KILL ($0080, TRAP #32) and
;                 VEC_SETVIDMODE ($012C, TRAP #75) — declared here but
;                 bodies land in subsequent revisions.
;               • Stability promise: this is the final renumber. After
;                 r28, TRAP numbers are stable; new syscalls consume
;                 from the per-group reserve, or from the global
;                 Reserved tail if their group is full.
;               • Spec: Part_20_renumber_spec.md.
;
; Revision: r27 — 11 May 2026. Part 25: rm/mv syscalls.
;               • Added TRAP_UNLINK (37) at VEC_UNLINK ($0094) and
;                 TRAP_RENAME (38) at VEC_RENAME ($0098). Both are
;                 NON-LEAF (PUSH SR / DINT / body / RTI pattern).
;               • Implementations in kos_fs_fd.asm (sys_unlink wraps
;                 _DeleteFile; sys_rename wraps _RenameFile).
;               • _DeleteFile uses new _FATFreeChain helper in kos_fs.asm,
;                 followed by existing _DirDelete (kos_fs_dir.asm).
;               • _RenameFile is same-drive only. Cross-drive returns
;                 ERR_INVALID so kosh can fall back to cp + unlink.
;               • No new memory layout. No new error codes (reuses
;                 ERR_NOTFOUND, ERR_EXISTS, ERR_READONLY, ERR_IO,
;                 ERR_BADPATH, ERR_BADDRIVE, ERR_INVALID).
;
; Revision: r26 — 9 May 2026. Part 22: host-disk backend memory-map updates.
;               • Sem pool note updated — pool moved from $03C8..$0447 to
;                 $0400..$047F to make room for the expanded volume table
;                 (now 6 slots, ending $03DF) and FAT cache (now $03E0).
;                 Single-symbol change in kos_sem.asm; no other kernel code
;                 references the pool by literal address.
;               • No new vectors or TRAP numbers in this revision —
;                 the host-disk backend is wired through the existing
;                 _BlockRead/_BlockWrite function pointer table in the
;                 volume-table slots.
;
; Revision: r25 — 8 May 2026. Part 20b: counting semaphores.
;               • Added TS_SEMWAIT (= 5) — task blocked on a semaphore.
;                 _Schedule's state-skip scan handles it automatically;
;                 no scheduler change.
;               • Added TCB_SEM_NEXT (= $20) in TCB_RESERVED zone —
;                 links waiters into a per-sem FIFO wait queue. Sits
;                 just outside IMM5 range; access via [XY+D] mode-01.
;               • Added VEC_SEMCREATE..VEC_SEMDESTROY ($0084..$0093) —
;                 four new TRAP vector slots.
;               • Added TRAP_SEMCREATE..TRAP_SEMDESTROY (33..36).
;               • The 8-byte sem pool (16 entries) is defined in
;                 kos_sem.asm rather than here, since nothing else in
;                 the kernel touches it directly. (Originally placed at
;                 $03C8; relocated to $0400 in r26.)
;                 
; Revision: r24 — 7 May 2026. Phase 19: kosh FS extensions.
;               Added TRAP_FORMAT (32) at VEC_FORMAT ($0080). Wraps
;               _FormatVolume so the kosh `format` command stays in
;               the syscall lane (matches the Phase 16 sys_open / sys_*
;               surface) rather than CALL24'ing a kernel internal.
;               No other changes.
;
;           r23 — 6 May 2026. Page-$00 layout reorganisation:
;               • KERNEL_STACK_TOP moved from $BFF0 to $FFFE. Reclaims
;                 the upper-half-of-page-$00 region (~16 KB) as the
;                 kernel stack growth zone. No code change beyond the
;                 EQU — all references are symbolic.
;               • FS_BUF_SECTOR / FS_BUF_FAT moved from $C000/$C200
;                 (above-stack-top, undocumented) to $BC00/$BE00
;                 (just below the stack region, inside the documented
;                 kernel work area). Both still 512-byte aligned. See
;                 kos_fs_defs.inc r7 for the EQU updates.
;               Banner strings in kos_splash.asm and kos_p15_kosh_smoke.asm
;               updated to reflect new stack address.
;
;           r22 — 6 May 2026. Updated page-$00 layout comment to reflect
;               the Phase 16 FS structures: volume table at $0260..$031F,
;               FAT cache state at $0320..$032F, and FS scratch buffers
;               at $C000..$C3FF (above stack top). No new EQUs in this
;               revision — the constants were added in r21 and the FS
;               layer's own kos_fs_defs.inc r6.
;
;           r21 — 6 May 2026. Phase 16: filesystem syscall plumbing.
;               Added VEC_OPEN..VEC_EXEC ($0068..$007F) — six new TRAP
;               vector slots. Added TRAP_OPEN..TRAP_EXEC (26..31) for
;               sys_open / sys_close / sys_read / sys_write / sys_dirent
;               / sys_exec. Added eleven FS error codes:
;               ERR_NOFD ($FFE7), ERR_BADFD ($FFE6), ERR_BADPATH ($FFE5),
;               ERR_NOTFOUND ($FFE4), ERR_EXISTS ($FFE3),
;               ERR_READONLY ($FFE2), ERR_NOSPACE ($FFE1), ERR_IO ($FFE0),
;               ERR_BADDRIVE ($FFDF), ERR_NOMORE ($FFDE),
;               ERR_NOTEXEC ($FFDD). Folds in the previously-separate
;               kos_defs_phase16_addendum.inc (now deleted).
;               FS-internal constants (volume table layout, BPB offsets,
;               FAT cache state, etc.) live in kfs/kos_fs_defs.inc — not
;               here, since the rest of the kernel doesn't care.
;
;           r20 — 5 May 2026. Added BT_NAME ($0240, 32 bytes) — caller-
;               staged inline name buffer for _BuildTask. If the first
;               byte is non-zero, _BuildTask copies up to 31 bytes (then
;               nul-terminates) into the new TCB's TCB_NAME field. If
;               first byte is zero (or BT_NAME never written), TCB_NAME
;               stays zero-filled as before. Used by 'ps' to display
;               human-readable task names.
;
;           r19 — 5 May 2026. Phase 14: heap syscalls. Added VEC_KMALLOC
;               ($0060), VEC_KFREE ($0064), TRAP_KMALLOC (24), TRAP_KFREE
;               (25). User tasks can now request kernel-heap blocks via
;               TRAP #24 / #25. Wrappers in kos_syscall_heap.asm. _InitVectors
;               (kos_boot.asm r27+) installs the two slots.
;
;           r18 — 3 May 2026. EMU user-page count refined to 62 (pages
;               $02..$3F) so that EMU mirrors a 64-page (4MB-style) machine
;               with the same kernel+heap+user layout as Digital, just with
;               more user slots. Total 64 pages = 1 kernel + 1 heap + 62 user.
;               Heap growth pool starts at $40 (was $42).
;
;               Page-map (Digital — 32-page RAM):
;                 $00       kernel
;                 $01       kernel heap region #1
;                 $02..$1F  user task pages (30 slots)
;
;               Page-map (EMU — 64-page logical, 16MB physical):
;                 $00       kernel
;                 $01       kernel heap region #1
;                 $02..$3F  user task pages (62 slots)
;                 $40..$FF  kernel-heap growth pool (192 pages)
;
;           r17 — 3 May 2026. TCB pool grown to support EMU expansion.
;               (history merged into r18.)
;
;           r16 — 3 May 2026. Part 9: kernel heap on dedicated page(s).
;
;               Page assignment (both hosts):
;                 $00       kernel (vectors, scheduler, TCB pool, work, stack)
;                 $01       kernel heap region #1 (always present, 64KB)
;                 $02..$1F  user task pages (30 slots — was 32)
;
;               EMU-only growth pool:
;                 $20..$FF  available for kernel heap expansion
;
;               Page count corrected: previous design ran user pages
;               $01..$20 which is 33 pages and overflows Digital's 2MB
;               (32 pages). USER_TCB_COUNT reduced 32 → 30. TCB_POOL_COUNT
;               reduced 33 → 31 (idle + 30 user). User TCBs now begin at
;               $0880 still — pool just shrinks at the high end.
;
;               Heap globals at $00:0224..$00:022F. Heap allocator
;               (kos_kmalloc.asm) runs in kernel context only. API:
;               _kmalloc / _kfree (24-bit pointers). Sub-page granular,
;               first-fit + coalesce. Single-region on Digital, multi-
;               region on EMU.
;
;               Compatibility aliases TASK_PAGE_BASE/END preserved for
;               existing code; new symbols USER_PAGE_BASE/END preferred.
;
;           r15 — 2 May 2026. Part 8: host environment detection.
;               (See r15 history in earlier revisions for KOS_HOST,
;               TRAPs #20–#23, PUTDEC_BUF.)
;           r14 — 2 May 2026. Part 7 prep. TCB v2.4: TCB_NAME and
;               TCB_RESERVED zones swapped.
;           r13 — 2 May 2026. TCB v2.3: added TCB_WAKE_TICK at $08.
;           r12 — TCB pool grown 16 → 33 (idle + 32 user tasks).
;           (earlier history elided for brevity — see prior revisions)
; ============================================================================

;-----------------------------------------------------------------------------
; Hardware memory map
;-----------------------------------------------------------------------------
; (TERMINAL/KEYBOARD 24-bit absolute aliases removed in Part 30 r37 hygiene
;  pass — codebase consistently uses TERMINAL_PAGE/KEYBOARD_PAGE + low-word
;  offset, since 24-bit immediates aren't directly loadable.)
TERMINAL_PAGE   .EQU    $DF                 ; Page byte for terminal MMIO ($DF_0000)
KEYBOARD_PAGE   .EQU    $DE                 ; Page byte for keyboard MMIO ($DE_0000)

;-----------------------------------------------------------------------------
; Lookup table region (Digital has ROM here; EMU does not)
;-----------------------------------------------------------------------------
LOOKUP_PAGE     .EQU    $E0                 ; SHL table base page
LOOKUP_PROBE_OFF .EQU   $2468               ; offset for input $1234
LOOKUP_PROBE_VAL .EQU   $2468               ; SHL($1234) = $2468

;-----------------------------------------------------------------------------
; Page $00 layout
;-----------------------------------------------------------------------------
; This map is the AUTHORITATIVE-FOR-DEFS view. It must match the live
; allocation in the various _Init* routines AND the canonical layout
; documented in kOS_Reference_Manual section 2.2.
;
; Updated 18 May 2026 (Part 36): added FE_* relocation to $04D8..$04E3,
; bumped FD scratch upper bound to $04D7 (was stale at $04CB), and added
; the ZERO PAGE MAP rules block below.
;
; $0000-$01FF   TRAP/INT vector table (128 slots × 4 bytes)
; $0200-$023F   Kernel sysvars + scheduler state
; $0240-$025F   BT_NAME buffer (Phase 14)
; $0260-$03DF   Volume table (Phase 16/Part 22: 6 × 64-byte slots, drives A..F)
; $03E0-$03EF   FAT cache state and dir/dirent caches (Phase 16/Part 22)
; $03F0-$03FF   Heap/diskfree scratch (Part 14.3 + Part 34)
;               $03F0..$03F3   HEAP_TID_QUERY / HEAP_RBT_REGION
;               $03F4..$03F9   DISKFREE_CLUSTER / DISKFREE_COUNT / DISKFREE_LIMIT
;               $03FA..$03FF   reserved free-space
; $0400-$047F   Counting-semaphore pool (Part 20b)
; $0480-$04D6   FD scratch (Part 22 — relocated from $0370 after volume-
;               table expansion overlap; see Gotcha 4.25)
; $04D8-$04E3   FE scratch (Part 36 — relocated from $03BC after FE_NEW_PAGE
;               was found to overlap VOL_SLOT_F+$1C, smashing F:'s
;               VOL_BLOCKREAD_PTR on every sys_exec; see Gotcha 4.47)
; $04E4-$07FF   Reserved (kernel growth)
; $0800-$277F   TCB pool (63 × 128 bytes — idle + 62 user tasks)
; $2780-$27BF   KBD_RING_BUF  (Phase A: 64-byte keyboard ring)
; $27C0-$9FFD   Kernel work area
; $9FFE-$9FFF   KLIB internal state (xorshift seed)
; $A000-$A0FF   KLIB jump table (64 entries × 4 bytes)
; $A100-$A1FF   Reserved (GLIB jump table — future)
; $A200-$A2FF   EMULIB jump table (64 entries × 4 bytes; Part 39, emulator-
;               only host-disk shim — see kos_emulib.inc)
; $A300-$A309   KOS_INFO_* (kernel identity: version, build date, phase tag
;               ptr — written by _InitKernel from kernel-ROM constants in
;               kos_boot.asm)
; $A30A-$BBFF   Kernel work area (continued)
; $BC00-$BDFF   FS_BUF_SECTOR (Phase 16: kernel sector scratch buffer)
; $BE00-$BFFF   FS_BUF_FAT    (Phase 16: FAT cache backing store)
; $C000-$FFFD   Kernel stack region (16 KB; stack grows down from $FFFE)
; $FFFE         Kernel stack top
;-----------------------------------------------------------------------------
; ZERO PAGE MAP — RULES FOR ADDING ALLOCATIONS
;-----------------------------------------------------------------------------
; History of layout-collision bugs (read before allocating page-$00):
;
;   Gotcha 4.25 (Part 22) — FD scratch at $0370 collided with the grown
;       volume table (3 slots → 6 slots in Part 22). Surfaced as CODE
;       FAULT when host disks were mounted. Relocated to $0480.
;
;   Gotcha 4.43 (Part 14.3) — HEAP_TID_QUERY at $0330 collided with the
;       same grown volume table (drive D's slot+$10). Worked in testing
;       only because D/E/F were unmounted. Relocated to $03F0.
;
;   Gotcha 4.47 (Part 36) — FE_NEW_PAGE at $03BC collided with VOL_SLOT_F
;       at slot offset $1C (the page byte of VOL_BLOCKREAD_PTR). Every
;       sys_exec corrupted F:'s block-read function pointer. Surfaced
;       as CODE FAULT odd-addr fetch when vol/sys_diskfree iterated to F:.
;       Relocated to $04D8.
;
; Common root cause: a developer wrote a scratch-slot block in a `.asm`
; source file with a comment claiming the address range was free, based
; on a then-current understanding of the page-$00 map. When the volume
; table later grew, the new range collided silently. The bug stayed
; latent until a code path actually exercised the affected drive slot.
;
; RULES to prevent recurrence:
;
;   1. Every absolute page-$00 allocation lives in an `.inc` file.
;      Never in a `.asm`. (Today: kos_defs.inc for kernel-wide slots,
;      kos_fs_defs.inc for FS-specific slots.)
;
;   2. The page-$00 layout comment above is the ONE canonical map.
;      When you add an allocation, update this map in the same edit.
;
;   3. "Reserved" means OWNED BY FUTURE GROWTH, not unallocated. To
;      consume reserved space, document the consuming region's
;      `_END` immediately above the reserved block.
;
;   4. Every allocation block should have an `_END` constant (one
;      past last byte) so the next block can derive its `_BASE`.
;      That makes the cascade visible if anyone tries to back-fit.
;
;   5. When the volume table grows (or any large block does), audit
;      everything in the now-affected address range, not just adjacent
;      slots. The VOL_SLOT_* allocations span $0260..$03DF — anything
;      written below $03DF must be checked against slot offsets $00..$3F.
;-----------------------------------------------------------------------------

;--- Vector table slots (TRAP #n at $00:n*4) ---------------------------------
;
; Layout (Part 20 — 12 May 2026):
;   TRAP  0..8    Hardware/IRQ ($0000..$0023)
;   TRAP  10..24  Console     (15 slots, $0028..$0063)
;   TRAP  25..39  Task        (15 slots, $0064..$009F)
;   TRAP  40..49  Memory      (10 slots, $00A0..$00C7)
;   TRAP  50..59  Sync        (10 slots, $00C8..$00EF)
;   TRAP  60..74  FS          (15 slots, $00F0..$012B)
;   TRAP  75..84  Device      (10 slots, $012C..$0153)
;   TRAP  85..127 Reserved    (43 slots, $0154..$01FF)
;
; Per-group reserved slots are for future syscalls in that domain.
; Cross-domain growth consumes from the Reserved tail.
;-----------------------------------------------------------------------------

; ── Hardware / interrupts ─────────────────────────────────────────────────
VEC_INT         .EQU    $0000               ; TRAP #0  / INT dispatcher
VEC_IRQ0        .EQU    $0004               ; TRAP #1  / IRQ0 (lowest priority)
VEC_IRQ1        .EQU    $0008               ; TRAP #2  / IRQ1
VEC_IRQ2        .EQU    $000C               ; TRAP #3  / IRQ2
VEC_IRQ3        .EQU    $0010               ; TRAP #4  / IRQ3
VEC_IRQ4        .EQU    $0014               ; TRAP #5  / IRQ4
VEC_IRQ5        .EQU    $0018               ; TRAP #6  / IRQ5
VEC_IRQ6        .EQU    $001C               ; TRAP #7  / IRQ6
VEC_IRQ7        .EQU    $0020               ; TRAP #8  / IRQ7 (timer)
;                                             TRAP #9  reserved (was PUTCHAR pre-r28)

; Boundary between IRQ-style (bad_int default) and TRAP-style (bad_trap
; default) vectors. _InitVectors fills $0000..VEC_TRAP_FIRST-1 with
; bad_int, and VEC_TRAP_FIRST..VEC_TABLE_END-1 with bad_trap. Note that
; TRAP #9 (slot $0024) is currently in the bad_trap range — it's an
; unused TRAP slot pending future use.
VEC_TRAP_FIRST  .EQU    $0024               ; TRAP #9 — first TRAP-style slot

; ── Console group ─────────────────────────────────── starts $0028 ──
VEC_PUTCHAR     .EQU    $0028               ; TRAP #10
VEC_GETCHAR     .EQU    $002C               ; TRAP #11
VEC_PUTS        .EQU    $0030               ; TRAP #12
VEC_PUTLN       .EQU    $0034               ; TRAP #13
VEC_GETS        .EQU    $0038               ; TRAP #14
VEC_PUTDEC      .EQU    $003C               ; TRAP #15
VEC_PUTHEX      .EQU    $0040               ; TRAP #16
VEC_CLEAR       .EQU    $0044               ; TRAP #17
VEC_SETCURSOR   .EQU    $0048               ; TRAP #18
;                                             $004C..$0060 reserved (TRAP #19..#24)

; ── Task group ────────────────────────────────────── starts $0064 ──
VEC_GETPID      .EQU    $0064               ; TRAP #25
VEC_YIELD       .EQU    $0068               ; TRAP #26
VEC_EXIT        .EQU    $006C               ; TRAP #27
VEC_SLEEP       .EQU    $0070               ; TRAP #28
VEC_SPAWN       .EQU    $0074               ; TRAP #29
VEC_WAIT        .EQU    $0078               ; TRAP #30
VEC_EXEC        .EQU    $007C               ; TRAP #31
VEC_KILL        .EQU    $0080               ; TRAP #32 (Part 20 — body lands later)
;                                             $0084..$009C reserved (TRAP #33..#39)

; ── Memory group ──────────────────────────────────── starts $00A0 ──
VEC_KMALLOC         .EQU    $00A0               ; TRAP #40
VEC_KFREE           .EQU    $00A4               ; TRAP #41
VEC_KREALLOC        .EQU    $00A8               ; TRAP #42
VEC_HEAPSTATS       .EQU    $00AC               ; TRAP #43
VEC_HEAPSTATS_BY_TID .EQU   $00B0               ; TRAP #44
;                                                 $00B4..$00C4 reserved (TRAP #45..#49)

; ── Sync group ────────────────────────────────────── starts $00C8 ──
VEC_SEMCREATE   .EQU    $00C8               ; TRAP #50
VEC_SEMTAKE     .EQU    $00CC               ; TRAP #51
VEC_SEMGIVE     .EQU    $00D0               ; TRAP #52
VEC_SEMDESTROY  .EQU    $00D4               ; TRAP #53
;                                             $00D8..$00EC reserved (TRAP #54..#59)

; ── FS group ──────────────────────────────────────── starts $00F0 ──
VEC_OPEN        .EQU    $00F0               ; TRAP #60
VEC_CLOSE       .EQU    $00F4               ; TRAP #61
VEC_READ        .EQU    $00F8               ; TRAP #62
VEC_WRITE       .EQU    $00FC               ; TRAP #63
VEC_DIRENT      .EQU    $0100               ; TRAP #64
VEC_FORMAT      .EQU    $0104               ; TRAP #65
VEC_UNLINK      .EQU    $0108               ; TRAP #66
VEC_RENAME      .EQU    $010C               ; TRAP #67
VEC_DISKFREE    .EQU    $0110               ; TRAP #68 — sys_diskfree (Part 34)
;                                             $0114..$0128 reserved (TRAP #69..#74)

; ── Device group ──────────────────────────────────── starts $012C ──
VEC_SETVIDMODE  .EQU    $012C               ; TRAP #75 (Part 20 — body lands later)
VEC_SETFOREGROUND .EQU  $0130               ; TRAP #76 — sys_setforeground (Phase B Step 2)
VEC_REGISTER_SHELL .EQU $0134               ; TRAP #77 — sys_register_shell (Phase B Step 1)
;                                             $0138..$0150 reserved (TRAP #78..#84)

; ── Reserved tail $0154..$01FF (TRAP #85..#127) ───────────────────────────

VEC_TABLE_END   .EQU    $0200               ; one past last slot

;--- Kernel system variables (Phase 1) ---------------------------------------
SYS_TICKS       .EQU    $0200               ; word — system tick counter
SYS_TICKS_HI    .EQU    $0202               ; word — system tick counter (high word)
                                            ; — Part 30 r36 (14 May 2026):
                                            ; was SYS_FLAGS (unused, written 0
                                            ; at boot, never read). Repurposed
                                            ; to extend SYS_TICKS to 32 bits.
                                            ; Wraps at ~4.5 years @ 30 Hz.
KBD_HEAD        .EQU    $0204               ; word — keyboard ring head (write index)
KBD_TAIL        .EQU    $0206               ; word — keyboard ring tail (read index)

;--- Keyboard ring storage (Phase A — 13 May 2026) --------------------------
; 64-byte SPSC ring in the kernel work area. Power-of-two size lets
; HEAD/TAIL wrap with a single AND. Effective capacity is 63 bytes
; (empty iff HEAD==TAIL; full iff (HEAD+1)&MASK==TAIL).
; Producer: _KbdTick inline in _TimerIRQ (kos_ctxsw.asm) via _RingPush.
; Consumer: sys_getchar → _RingWaitPop (kdrv/kos_kbd.asm).
KBD_RING_BUF    .EQU    $2780               ; base of 64-byte ring storage
KBD_RING_MASK   .EQU    $003F               ; size 64 - 1; wraps HEAD/TAIL

;--- Phase B Step 1: terminal geometry & back-buffer sizing -----------------
KOS_TERM_COLS   .EQU    80                  ; characters per row
KOS_TERM_ROWS   .EQU    80                  ; rows per screen
BACKBUF_SIZE    .EQU    6400                ; bytes per shell back-buffer
                                            ; (80 cols * 80 rows; literal because
                                            ;  .EQU doesn't accept arithmetic).
                                            ; Chars only — attribute plane
                                            ; deferred to Phase B v2.

;--- Phase B Step 2: shell-ring walk bound ----------------------------------
MAX_SHELL_RING_LEN .EQU 16                  ; defensive cap on shell-ring walks.
                                            ; Realistic case is 2..4 shells
                                            ; (kosh + BASIC + Forth); 16 is well
                                            ; above that. Used by
                                            ; _SwitchForegroundPrev to bound its
                                            ; forward walk against ring
                                            ; corruption.

;--- Phase B Step 1: keyboard hot-key codes ---------------------------------
; All codes confirmed 13 May 2026 via keydump.com on EMU. Digital should
; emit Ctrl-N / Ctrl-P natively as $0E / $10 via Swing keyTyped (the keys
; below in the $80..$8A range are EMU-only — Digital can't produce them).
;
; Encoding for the EMU-only direct-jump keys:
;   High nibble $8 = "synthesised virtual key, Ctrl-digit"
;   Low  nibble    = digit  (Ctrl-0 mapped to $8A meaning "shell 10")
KEY_CTRL_N           .EQU $0E                ; Ctrl-N — next shell
                                             ; (also Ctrl-RightArrow on EMU)
KEY_CTRL_P           .EQU $10                ; Ctrl-P — previous shell
                                             ; (also Ctrl-LeftArrow on EMU)
KEY_CTRL_1           .EQU $81                ; Ctrl-1 — direct switch to shell 1
KEY_CTRL_2           .EQU $82                ; Ctrl-2
KEY_CTRL_3           .EQU $83
KEY_CTRL_4           .EQU $84
KEY_CTRL_5           .EQU $85
KEY_CTRL_6           .EQU $86
KEY_CTRL_7           .EQU $87
KEY_CTRL_8           .EQU $88
KEY_CTRL_9           .EQU $89
KEY_CTRL_0           .EQU $8A                ; Ctrl-0 — shell 10
KEY_CTRL_DIGIT_FIRST .EQU $81                ; range bounds for hot-key filter
KEY_CTRL_DIGIT_LAST  .EQU $8A

;--- Scheduler globals (Phase 2) ---------------------------------------------
CURRENT_TCB     .EQU    $0208               ; word — running TCB ptr (low word)
READY_HEAD      .EQU    $020C               ; word — ready queue head (low word)
TASK_COUNT      .EQU    $0210               ; word — number of active tasks

;--- _BuildTask scratch slots ($00:0212..$021A) -----------------------------
BT_ENTRY_LO     .EQU    $0212               ; word — task entry low word
BT_ENTRY_PG     .EQU    $0214               ; word — entry page byte (low byte used)
BT_PRIMARY      .EQU    $0216               ; word — primary_page (low byte used)
BT_PCOUNT       .EQU    $0218               ; word — page_count (low byte used)
BT_PARENT_ID    .EQU    $021A               ; word — parent task id (0 = kernel)

;--- Host environment (Part 8) ----------------------------------------------
KOS_HOST        .EQU    $021C               ; word — host type (low byte used)
HOST_UNKNOWN    .EQU    0
HOST_DIGITAL    .EQU    1                   ; dumb-TTY, lookup ROMs populated
HOST_EMU        .EQU    2                   ; VT100, lookup tables ALU-computed

;--- sys_putdec scratch buffer (Part 8) -------------------------------------
PUTDEC_BUF      .EQU    $021E               ; first byte of digit buffer
PUTDEC_BUF_END  .EQU    $0223               ; one past last byte (5 bytes)

;--- Kernel heap globals (Part 9) -------------------------------------------
; Set by _InitMemConfig at boot, used by _kmalloc/_kfree.
KOS_PAGE_COUNT  .EQU    $0224               ; word — total RAM pages (low byte)
KOS_KHEAP_BASE  .EQU    $0226               ; word — first heap page (always $01)
KOS_KHEAP_END   .EQU    $0228               ; word — last heap page available
HEAP_REGIONS    .EQU    $022A               ; word — count of active heap regions
HEAP_BYTES_FREE .EQU    $022C               ; word — total free bytes (capped $FFFF)
HEAP_FIRST_PAGE .EQU    $022E               ; word — page byte of first region (low byte)

;--- Heap walk scratch slots (Phase 14 Part 3 — relocated 17 May 2026) ------
; Used by _HeapStatsByTid and _ReapByTid. Page $00 scratch frees up
; D-registers during the block walks (which need 4 D-regs for cursor +
; running totals). Kernel-internal, single-caller serialised — no
; concurrency concerns.
;
; ORIGINAL HOME (r38, r39):  $0330..$033B
;   This was wrong: per the live page-$00 layout the volume table runs
;   $0260..$03DF (6 slots × 64 B = drives A..F). $0330 = slot D + offset
;   $10 — clobbered drive D's volume entry on every _HeapStatsByTid call.
;   Worked in testing only because drives D/E/F were unmounted. As soon
;   as a fourth drive mounted, the next ps would silently corrupt it.
;   Source of the bug: the page-$00 layout comment in this file (above)
;   was out of date and claimed $0340..$03FF was "reserved Phase 16+
;   growth" — but the live layout extends the volume table to $03DF.
;   The reference manual section 2.2 was correct all along.
;
; NEW HOME:  $03F0..$03F3 (2 slots, 4 bytes total)
;   $03F0..$03FF is genuinely unused per ref manual section 2.2 — "was
;   POOL_NAME_BUF in Part 22; freed in Part 23". Just before the FD
;   scratch at $0480.
;
; The HEAP_SCRATCH0..3 entries from r38 (originally planned for snapshot
; stashes during the walks) are removed — the final code uses only
; HEAP_TID_QUERY and HEAP_RBT_REGION. The other four were dead.
HEAP_TID_QUERY  .EQU    $03F0               ; word — target TID for walk
HEAP_RBT_REGION .EQU    $03F2               ; word — region page (_ReapByTid: survives _kfree)

;--- Host-aware user-page ceiling (Part 9 — TCB pool expansion) -------------
; Set by _InitMemConfig based on KOS_HOST. _AllocPage in kos_tcb.asm reads
; this rather than using a literal compile-time TASK_PAGE_END. Digital
; gets $1F (30 pages); EMU gets $41 (64 pages).
KOS_USER_PAGE_END .EQU  $0230               ; word — runtime user-page ceiling (low byte)

;--- Kernel runtime state (Phase 13) ----------------------------------------
; Scheduler liveness flag. Used by routines that depend on timer IRQs and
; the scheduler being able to deliver them — e.g. _KDelayMs polls SYS_TICKS
; and would hang at boot time when the IRQ path can't safely return.
;
;   KERN_STATE_BOOT — pre-scheduler. Bare kernel code on the kernel stack.
;                     Timer IRQs may be masked or, if EINT'd, will route
;                     through _TimerIRQ which expects a real task context.
;                     Routines that need the scheduler must refuse.
;   KERN_STATE_RUN  — scheduler is live. _IdleLoop has run, IRQs are
;                     enabled, real task structures exist.
;
; Set to KERN_STATE_BOOT during _InitKernel; promoted to KERN_STATE_RUN by
; _IdleLoop just before its EINT. Once promoted, never demoted.
KERNEL_STATE      .EQU  $0232               ; word (low byte used)
KERN_STATE_BOOT   .EQU  $00
KERN_STATE_RUN    .EQU  $01

;--- Host-disk controller state (Part 22) -----------------------------------
; Handle of the semaphore protecting MMIO access to the host-disk
; controller. Populated by _InitHostDisk via _SemCreate(1); zero before
; init (and on Digital where the controller doesn't exist).
;
; (r31 — moved here from kos_fs_host.asm to colocate all page-$00 slot
; allocations in one registry; see r30 note re collision discovery.)
HOST_DISK_SEM     .EQU  $0234               ; word — sem handle

;--- Video driver state (Part 20) -------------------------------------------
; Owner of VID_MODE. 0 = unowned (text mode by default). When non-zero,
; holds the TID of the task that called sys_setvidmode(mode != 0). Cleared
; by sys_setvidmode(0) from owner, or by _VideoForceReset when owner dies.
VIDEO_OWNER_TID   .EQU  $0236               ; word — TID of mode owner (low byte used)

;--- Phase B Step 1: foreground-shell state ---------------------------------
; FOREGROUND_TCB holds the TID of the foreground shell (0 = no shell yet).
; Set by sys_register_shell on the first call, updated by sys_setforeground
; (Step 2) and by hot-key dispatch (Step 6). Looked up via _TidToTcb when
; the TCB pointer is needed; we don't cache the pointer because lookups
; happen only on switch events (rare).
FOREGROUND_TCB    .EQU  $0238               ; word — TID of foreground shell

; FIRST_SHELL_TID is the anchor for Ctrl-digit direct-index switching.
; Set by sys_register_shell when it creates the first shell (the singleton
; self-loop case); never changed afterwards by the registration path. Ctrl-1
; walks 0 hops from this anchor, Ctrl-2 walks 1 hop, etc.
FIRST_SHELL_TID   .EQU  $023A               ; word — TID of first registered shell

;--- Host-dependent tick increment (27 May 2026) ---------------------------
; Digital's hardware timer fires at 6 Hz to reduce IRQ overhead; EMU's
; timer fires at 30 Hz. To keep sys_sleep semantics consistent across
; hosts (30 ticks/sec on both), _TimerIRQ adds TICK_INCREMENT to
; SYS_TICKS each fire. _DetectHost sets this to 1 on EMU, 5 on Digital.
TICK_INCREMENT    .EQU  $023C               ; word (low byte used)

;--- _BuildTask name buffer (r20) -------------------------------------------
; 32-byte inline buffer in page $00. Caller writes a zstring here before
; calling _BuildTask. If first byte is non-zero, _BuildTask copies up to
; 31 bytes into the new TCB's TCB_NAME field. Zero first byte = no name
; (TCB_NAME stays zero-filled).
BT_NAME           .EQU  $0240               ; first byte of name buffer (32 B)

;--- TCB pool ----------------------------------------------------------------
TCB_POOL_BASE   .EQU    $0800               ; first TCB at $00:0800
TCB_POOL_COUNT  .EQU    63                  ; 1 idle + 62 user tasks
TCB_SIZE        .EQU    128                 ; bytes per TCB
TCB_POOL_END    .EQU    $2780               ; one past last TCB
USER_TCB_BASE   .EQU    $0880               ; first user TCB ($0800 = idle)
USER_TCB_COUNT  .EQU    62                  ; user tasks (Digital runtime-caps at 30)
IDLE_TCB        .EQU    $0800               ; idle TCB lives at slot 0

;--- TCB field offsets (v2.4 — word-granular throughout) --------------------
TCB_SAVED_X     .EQU    $00                 ; word — saved X3 (stack pointer)
TCB_SAVED_Y     .EQU    $02                 ; word — saved Y3 (low byte = page)
TCB_PAGE_COUNT  .EQU    $04                 ; word — pages owned (low byte used)
TCB_NEXT_TCB    .EQU    $06                 ; word — next TCB ptr (low word)
TCB_WAKE_TICK   .EQU    $08                 ; word — SYS_TICKS at which to wake
TCB_STATE       .EQU    $0A                 ; word — TS_xxx
TCB_PRIORITY    .EQU    $0C                 ; word — priority (Phase 2: 0)
TCB_ID          .EQU    $0E                 ; word — task id (1..62)
TCB_QUANTUM     .EQU    $10                 ; word — remaining quantum
TCB_FLAGS       .EQU    $12                 ; word — task flags
                                            ; bit 0 = TF_SEM_KERNEL_WAITER
                                            ; bit 1 = TF_PRIV
                                            ; bit 2 = TF_SYSCRITICAL
                                            ; bit 3 = TF_HAS_BACKBUF   (Phase B)
                                            ;   When set, _SemGive's wake
                                            ;   path skips saved-D0/SR
                                            ;   patching for this waiter.
                                            ;   Used by kernel-internal
                                            ;   blockers (e.g. disk driver)
                                            ;   that retry _SemTakeTry on
                                            ;   wake instead of receiving a
                                            ;   patched result via RTI.
TCB_EVENT_MASK  .EQU    $14                 ; word — pending events bitmap
TCB_PARENT_ID   .EQU    $16                 ; word — parent task id (0=kernel)
TCB_EXIT_CODE   .EQU    $18                 ; word — exit code (valid TS_DEAD)
TCB_WAIT_ID     .EQU    $1A                 ; word — child TID we're waiting on
TCB_YIELD_COUNT .EQU    $1C                 ; word — voluntary yields (sys_yield)
TCB_PREEMPT_COUNT .EQU  $1E                 ; word — involuntary preemptions (timer)
TCB_SEM_NEXT    .EQU    $20                 ; word — next-waiter ptr in sem queue
                                            ;        (Part 20b; first word of what
                                            ;         was TCB_RESERVED).
                                            ;        Note: $20 is just outside IMM5
                                            ;        range (0..31), so use mode-01
                                            ;        [XY+D] addressing — see
                                            ;        kos_sem.asm for examples.
TCB_PREEMPT_COUNT_HI .EQU $22               ; word — high word of preempt counter,
                                            ;        non-contiguous with low word
                                            ;        at $1E because $20 was already
                                            ;        taken by SEM_NEXT when 32-bit
                                            ;        TICKS was added. _TimerIRQ
                                            ;        does ADD low / ADC hi #0 to
                                            ;        propagate carry across the
                                            ;        non-adjacent words. Wraps at
                                            ;        ~4 years of continuous timer
                                            ;        IRQs at 30Hz.
TCB_RESERVED    .EQU    $24                 ; 40 bytes ($24..$4B) — growth space.
                                            ;        Phase B Step 1 narrowed this
                                            ;        from 62 to 42 bytes by claiming
                                            ;        $4C..$53 for the four shell
                                            ;        fields below. 13 May 2026: a
                                            ;        further 2 bytes claimed at $22
                                            ;        for TCB_PREEMPT_COUNT_HI.
                                            ;        Anything new in $24..$4B
                                            ;        remains fair game.

;--- Phase B Step 1: per-shell TCB fields -----------------------------------
; These live inside the old TCB_RESERVED zone — no layout shift, no change
; to _BuildTask (which already zero-fills $20..$7F).
; NOTE: all four offsets ($4C..$53) are outside IMM5 range (0..31), so
; mode-11 [XY+#FIELD] won't assemble. Use mode-01 [XY+D] with the offset
; pre-loaded into a D register — pattern from kos_sem.asm / kos_switcher.asm.
TCB_BACKBUF_OFFS .EQU   $4C                 ; word — back-buffer offset within page
                                            ;        (zero if TF_HAS_BACKBUF unset)
TCB_BACKBUF_PAGE .EQU   $4E                 ; word — back-buffer page byte (low byte)
                                            ;        (zero if TF_HAS_BACKBUF unset)
TCB_SHELL_NEXT   .EQU   $50                 ; word — page-$00 offset of next shell TCB
                                            ;        in the circular shell ring
                                            ;        (zero if not in ring; self-offset
                                            ;         if singleton).
TCB_BACKBUF_CRSR .EQU   $52                 ; word — packed cursor for back-buffer:
                                            ;        high byte = row (0..29)
                                            ;        low  byte = col (0..79)
                                            ;        (only meaningful when
                                            ;         TF_HAS_BACKBUF is set).

TCB_NAME        .EQU    $60                 ; 32 bytes — null-padded name

;--- TCB state values --------------------------------------------------------
TS_READY        .EQU    0                   ; on run queue, can be scheduled
TS_BLOCKED      .EQU    1                   ; waiting on timer (sys_sleep)
TS_DEAD         .EQU    2                   ; exited, awaiting cleanup
TS_UNUSED       .EQU    3                   ; slot is free, available
TS_WAITING      .EQU    4                   ; blocked in sys_wait
TS_SEMWAIT      .EQU    5                   ; blocked on a counting semaphore (Part 20b)

;--- TCB_FLAGS bit values ----------------------------------------------------
; Stored in the word at TCB+$12. Bits 2..15 reserved for future use.
TF_SEM_KERNEL_WAITER .EQU $0001              ; bit 0 — _SemGive's wake path
                                             ; skips saved-D0/SR patching
                                             ; for this waiter; the waiter
                                             ; retries _SemTakeTry on resume
                                             ; instead of receiving a
                                             ; patched-via-RTI result.
                                             ; Set by _SemBlockYield.
TF_PRIV              .EQU $0002              ; bit 1 — task is privileged.
                                             ; A privileged task may sys_kill
                                             ; any other task. Non-privileged
                                             ; tasks may only kill their own
                                             ; children. Set by kosh's spawn
                                             ; site in kos_boot.asm; cleared
                                             ; everywhere else by default
                                             ; (_BuildTask zeroes TCB_FLAGS).
TF_SYSCRITICAL       .EQU $0004              ; bit 2 — task may not be killed.
                                             ; sys_kill refuses victims with
                                             ; this bit set, regardless of
                                             ; caller privilege; returns
                                             ; ERR_PERM. Orthogonal to
                                             ; TF_PRIV — a task can be
                                             ; privileged-but-killable (admin
                                             ; tool) or unprivileged-but-
                                             ; syscritical (read-only system
                                             ; service). Set by kosh after
                                             ; _BuildTask along with TF_PRIV;
                                             ; future system daemons (init,
                                             ; logger, ...) should set it too.
TF_HAS_BACKBUF       .EQU $0008              ; bit 3 — task is a registered shell.
                                             ; Output syscalls (Phase B Step 3)
                                             ; route through the per-task back-
                                             ; buffer at TCB_BACKBUF_OFFS / _PAGE;
                                             ; sys_getchar (Step 4) is gated on
                                             ; FOREGROUND_TCB == this task's TID.
                                             ; Set by sys_register_shell; cleared
                                             ; on task death by _HandleDeadTCB
                                             ; (Phase B Step 10).

; Convenience: combined flag mask written by kosh into its own TCB_FLAGS
; immediately after _BuildTask returns. Pre-combined here because the K16
; assembler doesn't accept `|` in expressions; using `+` works only because
; TF_PRIV and TF_SYSCRITICAL are disjoint single-bit values.
TF_KOSH_FLAGS        .EQU $0006              ; TF_PRIV | TF_SYSCRITICAL

;--- sys_kill / sys_exit shared constants ----------------------------------
KILL_EXIT_CODE  .EQU    $FFFF               ; exit code stored for sys_kill'd
                                            ; tasks. $FFFF chosen so a parent
                                            ; doing sys_wait can distinguish
                                            ; "child died normally with this
                                            ; exit code" from "child was
                                            ; killed". Conventional exit codes
                                            ; are 0..255.

;--- Stack ------------------------------------------------------------------
KERNEL_STACK_TOP .EQU   $FFFE               ; initial X3 / kernel X3 after pivot

;--- Boot/reset vector ------------------------------------------------------
; K16 reset vector — execution starts here on power-on / HALT-reset. The
; kernel label `Start` (in kos_boot.asm) is the canonical name for this
; address in kernel-side code; user-space code (e.g. kosh's `reboot`)
; uses RESET_VECTOR via JMP24 RESET_VECTOR since `Start` is a kernel-
; internal label not visible to standalone user assemblies.
RESET_VECTOR    .EQU    $FF0000             ; 24-bit absolute reset entry

;--- Kernel identity (Part 39 r-final: v1.0 self-identification) ------------
; Five page-$00 words written by _InitKernel from compile-time kernel-ROM
; constants. Allow any task (kosh, BASIC, Forth, future shells) to read
; the kernel's identity at runtime via plain LOADZ — no need to bake the
; kernel version into the standalone task assembly.
;
; The source-of-truth values live in kos_boot.asm (KOS_VERSION_VALUE,
; KOS_BUILD_YEAR_VALUE, etc.) so a kernel-build version bump touches one
; file. _InitKernel copies them into the page-$00 slots below.
;
; Read pattern from user code (kosh splash, info command, etc.):
;     LOADZ   D0, [#KOS_VERSION]       ; D0 = $XXYY, X=major Y=minor
;     LOADZ   D0, [#KOS_BUILD_YEAR]    ; D0 = year (2026..)
;
;   Phase tag is a kernel-ROM string; its address is published in FULL
;   (page + offset), because kernel ROM lives at page $FF (.ORG $FF0000),
;   NOT page $00. Page $00 holds only the kernel's zero-page RAM (these
;   slots, TCBs, stack). To print it:
;     LOADZ   D0, [#KOS_PHASE_TAG_PAGE] ; D0 = ROM page byte ($FF)
;     MOVE    Y0, D0
;     LOADZ   D0, [#KOS_PHASE_TAG_PTR]  ; D0 = 16-bit offset within $FF
;     MOVE    X0, D0
;     TRAP    #TRAP_PUTS                ; sys_puts honours the Y0 page byte
KOS_VERSION       .EQU  $A300             ; word - high byte = major, low byte = minor
                                          ;        (e.g. $0100 = v1.0)
KOS_BUILD_YEAR    .EQU  $A302             ; word - build year (e.g. 2026)
KOS_BUILD_MONTH   .EQU  $A304             ; word - build month 1..12 (low byte used)
KOS_BUILD_DAY     .EQU  $A306             ; word - build day 1..31 (low byte used)
KOS_PHASE_TAG_PTR .EQU  $A308             ; word - 16-bit OFFSET of phase-tag
                                          ;        string within the kernel ROM page
KOS_PHASE_TAG_PAGE .EQU $A30A             ; word - kernel ROM page byte ($FF) for the
                                          ;        phase-tag string (low byte used).
                                          ;        Pair with KOS_PHASE_TAG_PTR for the
                                          ;        full 24-bit address.
;--- Pages ------------------------------------------------------------------
IDLE_PAGE       .EQU    $00                 ; idle task lives in kernel page
KHEAP_PAGE      .EQU    $01                 ; kernel heap region #1 (always)
USER_PAGE_BASE  .EQU    $02                 ; first allocatable user task page
USER_PAGE_END_DIGITAL .EQU $1F              ; Digital ceiling (30 user pages)
USER_PAGE_END_EMU     .EQU $3F              ; EMU ceiling (62 user pages)

; (Part 30 r37 hygiene pass: removed unused/misleading constants from this
;  block — USER_PAGE_END / USER_PAGE_COUNT (compile-time maxes that hid the
;  real runtime cap in KOS_USER_PAGE_END), and the deprecated legacy
;  compatibility block (TASK_PAGE_BASE/END / TASK_A_PAGE / TASK_B_PAGE /
;  TASK_C_PAGE / TASK_STACK_TOP). All call sites already use USER_PAGE_*
;  or KOS_USER_PAGE_END.)

;--- EMU-only kernel heap growth pool ---------------------------------------
KHEAP_POOL_BASE_EMU .EQU $40                ; first growth-pool page on EMU (post-user)
KHEAP_POOL_END_EMU  .EQU $FF                ; last growth-pool page on EMU

;--- sys_spawn constants ----------------------------------------------------
SPAWN_ENTRY_OFFSET .EQU $0200               ; child's PC starts at primary:$0200
SPAWN_MAX_LEN      .EQU $FE00               ; max copy length

;--- Task-local page-zero slots (per task page) ----------------------------
MY_TCB_PTR      .EQU    $0000               ; word — TCB low word
TASK_ID         .EQU    $0004               ; word — task id (1..62)
TLS_ERRNO       .EQU    $0006               ; word — reserved (Phase 4+)
TLS_FLAGS       .EQU    $0008               ; word — reserved (Phase 4+)
TLS_SCRATCH0    .EQU    $000A               ; word — syscall scratch

;-----------------------------------------------------------------------------
; Heap region layout (per page) — Part 9
;-----------------------------------------------------------------------------
; Each kernel-heap page starts with a 16-byte region descriptor at offset
; $0000. The first allocatable block begins at offset $0010. The last 16
; bytes of the page ($FFF0..$FFFF) are reserved as an end-of-page sentinel.
;
; Region descriptor:
;   $00  word   region_size       (usable byte count, normally $FFE0)
;   $02  word   region_flags      (bit 0 = INITIALISED; rest reserved)
;   $04  word   free_list_head    (page offset, or 0 = no free blocks)
;   $06  word   next_region_page  (low byte = next region's page byte; 0=last)
;   $08  word   bytes_free        (cached free count for this region)
;   $0A  word   reserved
;   $0C  word   reserved
;   $0E  word   region_magic      ($K1H6 = $4B16 little-endian → "K6" tag)
;   $10..$FFEF  block area
;   $FFF0..$FFFF  end-of-page sentinel (16 bytes, currently zero-filled)
;-----------------------------------------------------------------------------
HR_SIZE         .EQU    $00                 ; word — region usable bytes
HR_FLAGS        .EQU    $02                 ; word — region flags
HR_FREE_HEAD    .EQU    $04                 ; word — free-list head (page offset)
HR_NEXT_PAGE    .EQU    $06                 ; word — next region's page byte
HR_BYTES_FREE   .EQU    $08                 ; word — cached free byte count
HR_MAGIC        .EQU    $0E                 ; word — region magic ($4B16)
HR_BLOCK_BASE   .EQU    $0010               ; first block offset within page
HR_BLOCK_END    .EQU    $FFF0               ; one past last byte of block area
HR_USABLE_BYTES .EQU    $FFE0               ; HR_BLOCK_END - HR_BLOCK_BASE
HR_MAGIC_VALUE  .EQU    $4B16               ; "K6" — kernel heap v6

HR_FLAG_INIT    .EQU    $0001               ; region initialised

;--- Block header layout ----------------------------------------------------
; Every block (free or used) is preceded by a 6-byte header (Phase 14 Part 3).
;
;   $00  word   size           (payload size in bytes; even, ≥ 4)
;   $02  word   flags          (bit 0 = USED; bit 1 = LAST; rest reserved)
;   $04  word   owner_tid      (TID that allocated; 0 = kernel; ignored when free)
;   $06..$06+size payload
;
; Free-block payload first 4 bytes (24-bit next-free pointer in K16 layout):
;   +$00  word   next_free_y    (page byte; only low byte used)
;   +$02  word   next_free_x    (offset within page; 0 = end of list)
;
; The Y-first / X-second order matches the K16 LOADXY/STOREXY memory
; convention so a single LOADXY can read the entire next pointer.
;
; Minimum block payload: 4 bytes (room for next_free pointer when free).
; Allocations are rounded up to even, then floored to 4. Block size never
; includes the 6-byte header.
;
; Layout evolution:
;   Phase 14 Part 1 (r12): 4-byte header (size, flags).
;   Phase 14 Part 3 (r38+): 6-byte header. BH_OWNER_TID added at $04.
;     BH_NEXT_Y / BH_NEXT_X slide from $04/$06 to $06/$08. All offset
;     references in kos_kmalloc.asm are symbolic, so the code change is
;     purely the .EQU values below.
;-----------------------------------------------------------------------------
BH_SIZE         .EQU    $00                 ; word — payload size
BH_FLAGS        .EQU    $02                 ; word — flags (USED, LAST, ...)
BH_OWNER_TID    .EQU    $04                 ; word — owner TID (0 = kernel)
BH_PAYLOAD      .EQU    $06                 ; first byte of payload
BH_NEXT_Y       .EQU    $06                 ; free-block: next_free page (= BH_PAYLOAD+0)
BH_NEXT_X       .EQU    $08                 ; free-block: next_free offset (= BH_PAYLOAD+2)

BH_FLAG_USED    .EQU    $0001               ; block in use
BH_FLAG_LAST    .EQU    $0002               ; last block in region

BH_HEADER_SIZE  .EQU    6                   ; bytes of block header
BH_MIN_PAYLOAD  .EQU    4                   ; minimum payload (next_free ptr)
BH_MIN_BLOCK    .EQU    10                  ; header (6) + minimum payload (4)

; Convention: BH_OWNER_TID == 0 means "kernel-owned, never reaped on task death".
; Used for boot-time allocations (back-buffers pre-allocated by _BuildTask,
; host-disk init, etc.) and for any _kmalloc call made while CURRENT_TCB == 0
; (scheduler not yet running).
OWNER_KERNEL    .EQU    0

;-----------------------------------------------------------------------------
; Syscall numbers (TRAP #n)
;
; Part 20 — domain-grouped layout (see VEC_ table above for full details).
;-----------------------------------------------------------------------------

; ── Console group (TRAP #10..#24) ────────────────────────────────────────
TRAP_PUTCHAR    .EQU    10
TRAP_GETCHAR    .EQU    11
TRAP_PUTS       .EQU    12
TRAP_PUTLN      .EQU    13
TRAP_GETS       .EQU    14
TRAP_PUTDEC     .EQU    15
TRAP_PUTHEX     .EQU    16
TRAP_CLEAR      .EQU    17
TRAP_SETCURSOR  .EQU    18
;                       19..24 reserved

; ── Task group (TRAP #25..#39) ───────────────────────────────────────────
TRAP_GETPID     .EQU    25
TRAP_YIELD      .EQU    26
TRAP_EXIT       .EQU    27
TRAP_SLEEP      .EQU    28
TRAP_SPAWN      .EQU    29
TRAP_WAIT       .EQU    30
TRAP_EXEC       .EQU    31
TRAP_KILL       .EQU    32                  ; Part 20 — body lands later
;                       33..39 reserved

; ── Memory group (TRAP #40..#49) ─────────────────────────────────────────
TRAP_KMALLOC         .EQU    40
TRAP_KFREE           .EQU    41
TRAP_KREALLOC        .EQU    42
TRAP_HEAPSTATS       .EQU    43
TRAP_HEAPSTATS_BY_TID .EQU   44
;                       45..49 reserved

; ── Sync group (TRAP #50..#59) ───────────────────────────────────────────
TRAP_SEMCREATE  .EQU    50
TRAP_SEMTAKE    .EQU    51
TRAP_SEMGIVE    .EQU    52
TRAP_SEMDESTROY .EQU    53
;                       54..59 reserved

; ── FS group (TRAP #60..#74) ─────────────────────────────────────────────
TRAP_OPEN       .EQU    60
TRAP_CLOSE      .EQU    61
TRAP_READ       .EQU    62
TRAP_WRITE      .EQU    63
TRAP_DIRENT     .EQU    64
TRAP_FORMAT     .EQU    65
TRAP_UNLINK     .EQU    66
TRAP_RENAME     .EQU    67
TRAP_DISKFREE   .EQU    68                  ; Part 34 — sys_diskfree
;                       68..74 reserved

; ── Device group (TRAP #75..#84) ─────────────────────────────────────────
TRAP_SETVIDMODE .EQU    75                  ; Part 20 — body lands later
TRAP_SETFOREGROUND .EQU 76                  ; Phase B Step 2 — sys_setforeground
TRAP_REGISTER_SHELL .EQU 77                 ; Phase B Step 1 — sys_register_shell
;                       78..84 reserved

; ── Reserved tail (TRAP #85..#127) ───────────────────────────────────────

;-----------------------------------------------------------------------------
; Error codes (returned in D0 with C=1)
;-----------------------------------------------------------------------------
ERR_OK          .EQU    $0000               ; success (C=0; D0 = result)
ERR_BADCALL     .EQU    $FFFF               ; uninitialised vector
ERR_BUFFER_FULL .EQU    $FFFE               ; line buffer full
ERR_INVALID     .EQU    $FFFD               ; invalid argument
ERR_NOMEM       .EQU    $FFFC               ; page allocation failed
ERR_NOSLOTS     .EQU    $FFFB               ; TCB pool full
ERR_TOOBIG      .EQU    $FFFA               ; sys_spawn length out of range
ERR_BADARG      .EQU    $FFF9               ; bad arg
ERR_NOTCHILD    .EQU    $FFF8               ; sys_wait on a non-child TID
ERR_DEADLOCK    .EQU    $FFF7               ; sys_wait but child has waiter
ERR_PERM        .EQU    $FFF6               ; permission denied (Part 20)
ERR_BUSY        .EQU    $FFF5               ; resource busy / contended (Part 20)

; Phase 16 — filesystem error codes ($FFE0..$FFE7 reserved for FS;
; $FFE8..$FFF6 reserved for future expansion).
ERR_NOFD        .EQU    $FFE7               ; per-task fd table full
ERR_BADFD       .EQU    $FFE6               ; fd is not open
ERR_BADPATH     .EQU    $FFE5               ; path is malformed
ERR_NOTFOUND    .EQU    $FFE4               ; file does not exist
ERR_EXISTS      .EQU    $FFE3               ; file exists (CREATE+EXCL)
ERR_READONLY    .EQU    $FFE2               ; write rejected on r/o volume
ERR_NOSPACE     .EQU    $FFE1               ; disk full
ERR_IO          .EQU    $FFE0               ; block-layer read/write failed
ERR_BADDRIVE    .EQU    $FFDF               ; drive letter not mounted
ERR_NOMORE      .EQU    $FFDE               ; directory iteration ended
ERR_NOTEXEC     .EQU    $FFDD               ; sys_exec on non-.COM file

;-----------------------------------------------------------------------------
; Character constants
;-----------------------------------------------------------------------------
CH_BS           .EQU    $08                 ; backspace
CH_LF           .EQU    $0A                 ; line feed
CH_CR           .EQU    $0D                 ; carriage return
CH_SPACE        .EQU    $20                 ; space
CH_NUL          .EQU    $00                 ; null terminator
CH_ESC          .EQU    $1B                 ; escape (VT100 sequences)

; ============================================================================
; End of kos_defs.inc
; ============================================================================
