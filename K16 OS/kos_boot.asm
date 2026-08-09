; ============================================================================
; kos_boot.asm — k/OS Phase 10 boot
; ============================================================================
; Date:    8 August 2026
; Status:  Part 61 — k/OS v1.02, host-populated RAM disk.
; Revision: r56 — 8 August 2026 — Part 61: KOS_VERSION_VALUE $0101 -> $0102
;             (v1.02) and phase tag "Phase 51+" -> "Phase 61+". Build date is
;             auto-stamped (__YEAR__/__MONTH__/__DAY__) so it needs no edit.
;             Marks the Part 61 work: kosh's HELLO.COM/NOTES.TXT boot seeder
;             removed (kosh.asm r44), A:STARTUP.KSH bootstraps a host-side
;             boot.ksh through the new `load ramdisk/<name>` folder prefix
;             (kosh_cmds_fs.asm r26 + k16-host.js), brief (-b) script echo
;             (kosh_script.asm), and drive-qualified bare execution
;             (kosh.asm r45 / kosh_cmds_fs.asm r27). No code change in this
;             file beyond the two identity constants; the splash and `info`
;             read them from the page-$00 slots, so nothing else rebuilds.
; Revision: r55 — 30 June 2026 — Part 51: phase tag "Phase 50+" -> "Phase 51+",
;             build date -> 30 June 2026. Version held at v1.01 ($0101). The VC
;             auto-switch-on-launch work lands in kos_switcher/kos_fs_exec/
;             kos_spawn/kosh; this file only re-stamps the boot identity slots.
; Revision: r54 — 28 June 2026 — Part 49: KOS_VERSION_VALUE $0100 -> $0101
;             (v1.01), phase tag "Phase 47+" -> "Phase 49+", build date
;             18 -> 28 June 2026. Identity slots feed the kosh splash, which
;             now renders the minor as two digits (kosh_splash.asm r9), so the
;             logo reads "v1.01 Phase 49+". Accompanies the graphics-task
;             foreground integration (kos_video/switcher/console/tcb/task,
;             kos_defs.inc r45).
; Revision: r53 — 18 June 2026 — Part 47: phase tag bumped to "Phase 47+";
;             build date set to 18 June 2026 (KOS_BUILD_MONTH 5->6, DAY 29->18).
;             Splash + info read these via the kernel identity slots; no
;             change needed in kosh_splash.asm / kosh_cmds_sys.asm.
; Revision: r52 — 29 May 2026 — Part 40: publish the phase-tag string's
;             ROM PAGE BYTE too. _InitKernel now stages KOS_PHASE_TAG_PAGE
;             (#>_KosPhaseTag = $FF) next to KOS_PHASE_TAG_PTR (the
;             16-bit offset). Reason: kernel ROM is .ORG $FF0000 (page
;             $FF); the r51 slot published only the offset, so a consumer
;             had no way to know the page and the splash phase tag came up
;             empty when read as $00:offset (kernel RAM). Now consumers
;             get the full 24-bit address. Requires kos_defs.inc r44+
;             (KOS_PHASE_TAG_PAGE EQU) and kosh_splash.asm r7+ (consumer).
;
;           r51 — 29 May 2026 — Part 39 r-final: kernel identity self-
;             publishing. Adds:
;               1. KOS_VERSION_VALUE / KOS_BUILD_YEAR_VALUE / _MONTH_VALUE /
;                  _DAY_VALUE constants at the top of this file (after
;                  the .INCLUDEs). These are the source-of-truth values
;                  for k/OS v1.0 and its build date (29 May 2026).
;               2. _KosPhaseTag string in kernel ROM ("Phase 39+", 0)
;                  near boot_msg.
;               3. _InitKernel stages all five facts (version, year,
;                  month, day, phase-tag pointer) into the new page-$00
;                  slots at $A300..$A309 (defined in kos_defs.inc r43).
;             Result: kosh's splash, `info` command, and any future
;             shell can read the kernel identity at runtime via LOADZ
;             rather than hardcoding it at the consumer's assembly time.
;             Cuts "kosh assembles knowing the kernel version" coupling.
;             Requires kos_defs.inc r43+ (KOS_VERSION etc. slot EQUs)
;             and kosh_splash.asm r5+ (consumer side).
;
; Revision: r50 — 29 May 2026 — Part 39 (kosh.com migration) integration.
;             Four changes to plumb the new structure into the kernel build:
;               1. .INCLUDE "emulib/kos_emulib.inc" after the KLIB inc
;                  include — publishes EMULIB_BASE + EMULIB_* slot names.
;               2. CALL24 _InitEmulib added to _InitKernel right after
;                  CALL24 _InitKLib — copies EMULIB ROM template into
;                  the RAM jump table at $00:$A200..$A2FF.
;               3. .INCLUDE "emulib/kos_emulib_template.asm" after the
;                  KLIB template include — pulls the ROM template and
;                  _InitEmulib body into the kernel binary.
;               4. .INCLUDE "kosh/kosh_boot.asm" replaces .INCLUDE
;                  "kosh/kosh.asm" — kosh is now built standalone as
;                  kosh.com and embedded via .INCBIN inside kosh_boot.asm.
;             Requires kos_klib.inc r8+ (slots 06/07 KLIB_TRY_MOUNT +
;             KLIB_SLOT_FOR_DRIVE), kos_klib_template.asm r8+, EMULIB
;             v1.0 (kos_emulib.inc r1, kos_emulib_template.asm r1),
;             kos_spawn.asm r8+ (_SpawnShell), kosh_boot.asm r2+
;             (.INCBIN "kosh/kosh.com" + _SpawnShell call), kos_defs.inc
;             r42+ (RESET_VECTOR + EMULIB region in page-$00 map).
;
; Revision: r49 — 18 May 2026 — Part 34: install sys_diskfree at VEC_DISKFREE
;             ($0110), TRAP #68. Four-instruction block in _InitVectors,
;             adjacent to sys_rename. Requires kos_defs.inc r41+ and
;             kos_fs.asm r11+.
;
;           r48 — 17 May 2026 — Phase 14 Part 3b: reap smoke wiring.
;             Added commented Test/kos_p14p3_reap_smoke.asm to the smoke-
;             include block. No active behaviour change; smoke is opt-in
;             via the standard include swap.
;
;           r47 — 17 May 2026 — Phase 14 Part 3b: per-TID query vector.
;             Install vector for sys_heapstats_by_tid (TRAP #44). One new
;             4-instruction block, adjacent to the Part 2 installs.
;             Requires kos_defs.inc r39+ and kos_heap.asm r3+.
;
;           r46 — 17 May 2026 — Phase 14 Part 2: heap completion.
;             Install vectors for sys_krealloc (TRAP #42) and sys_heapstats
;             (TRAP #43). Two new 4-instruction blocks in _InitVectors,
;             adjacent to the existing sys_kmalloc / sys_kfree installs.
;             Also wires a commented-out Test/kos_p14p2_heap_smoke.asm
;             entry into the smoke-include block; uncomment (and comment
;             the kosh include) to run the smoke at boot.
;             Requires kos_defs.inc r38+ and kos_heap.asm r2+.
;
;           r45 — 14 May 2026 — k/OS Part 30 cont'd: SYS_TICKS_HI init.
;             _InitKernel now zeroes SYS_TICKS_HI ($0202) instead of
;             SYS_FLAGS (same address; renamed in kos_defs.inc r36).
;             Same one-word STOREZ; behaviour unchanged at boot.
;             Together with kos_ctxsw.asm r34 this extends the system
;             uptime counter from 16 to 32 bits.
;             Requires kos_defs.inc r36+, kos_ctxsw.asm r34+.
;
; Revision: r44 — 14 May 2026 — k/OS Part 30 cleanup: boot splash relocated
;             to kosh. The full sign-on (logo, host, kernel layout, heap,
;             pages, tasks, boot date, rule) is now emitted by kosh on
;             entry via TRAP_CLEAR/PUTS/PUTDEC/PUTCHAR, so it lands in
;             the shell back-buffer and survives foreground switches.
;             kos_boot now prints a single "Booting k/OS" line via
;             _RawPuts before _P2Main runs.
;             CALL24 _ShowSplash removed; .INCLUDE "kernel/kos_splash.asm"
;             removed (file deleted; its two helpers _RawPutDec and
;             _RawPutHexByte absorbed into kos_rawio.asm r8). New
;             boot_msg string added below _DetectHost.
;             Requires kos_rawio.asm r8+, kosh.asm r-next with kosh_splash
;             include.
;
;           r43 — 13 May 2026 — Phase B Step 2: install sys_setforeground.
;             Installs VEC_SETFOREGROUND ($0130, TRAP #76) pointing at
;             sys_setforeground in kos_switcher.asm r2. Vector install
;             only — sys_setforeground itself is not reachable until
;             kosh adds the `fg` command in Step 9 (or _KbdDispatch's
;             hot-key body lands in Step 6 and calls the internal
;             _SwitchForegroundNext/Prev helpers).
;             Requires kos_defs.inc r35+, kos_switcher.asm r2+.
;
; Revision: r42 — 13 May 2026 — Phase B Step 1: shell registration.
;             Installs VEC_REGISTER_SHELL ($0134, TRAP #77) pointing at
;             sys_register_shell in the new kernel/kos_switcher.asm module.
;             Includes kernel/kos_switcher.asm after kos_sem.asm (it
;             depends on _kmalloc and _TidToTcb).
;             No other changes — the switcher module currently provides
;             only the registration syscall; sys_setforeground and the
;             switcher machinery land in later Phase B steps.
;             Requires kos_defs.inc r34+.
;
; Revision: r41 — 13 May 2026 — Phase A: include kdrv/kos_kbd.asm.
;             New keyboard subsystem (ring buffer, _RingPush, _RingPop,
;             _RingWaitPop, _KbdDispatch policy seam). _InitKernel's
;             existing zero-init of KBD_HEAD/KBD_TAIL ($0204/$0206) is
;             reused — the slots were pre-reserved.
;             Requires kos_defs.inc r33+, kos_ctxsw.asm r30+,
;             kos_console.asm r13+.
;
; Revision: r40 — 12 May 2026 — Part 20: install sys_setvidmode + init video.
;             _InitVectors installs sys_setvidmode at VEC_SETVIDMODE
;             ($012C, TRAP #75). _InitKernel calls _InitVideo at end to
;             force VID_MODE=0 and clear VIDEO_OWNER_TID.
;             New subdirectory kdrv/ for device drivers:
;               • kdrv/kos_console.asm  (relocated from kernel/)
;               • kdrv/kos_video.asm    (new)
;             Future kbd, sound, mouse, serial drivers go in kdrv/ too.
;             Requires kos_defs.inc r30+ and kdrv/kos_video.asm r1+.
;
; Revision: r39 — 12 May 2026 — Part 20: install sys_kill at VEC_KILL ($0080).
;             Body in kos_task.asm r14. Sits in the task-group syscalls
;             between VEC_EXEC and VEC_FORMAT in install order.
;             VEC_SETVIDMODE ($012C, TRAP #75) still bad_trap — body lands later.
;             Requires kos_defs.inc r29+ and kos_task.asm r14+.
;
; Revision: r38 — 12 May 2026 — Part 20 syscall renumber.
;             _InitVectors uses the new VEC_TRAP_FIRST boundary symbol
;             (from kos_defs.inc r28) instead of hard-coding VEC_PUTCHAR
;             as the IRQ/TRAP boundary. Same installs, all symbolic —
;             the renumbered TRAP slots get bad_trap automatically and
;             the explicit installs find their new home addresses
;             unchanged at the source level.
;
;             VEC_KILL ($0080) and VEC_SETVIDMODE ($012C) declared in
;             kos_defs.inc r28 are NOT yet installed here — their bodies
;             land in subsequent revisions. They sit as bad_trap stubs
;             until then; calling them returns ERR_BADCALL with C=1.
;
; Revision: r37 — 11 May 2026 — Part 25: install sys_unlink at VEC_UNLINK
;             ($0094) and sys_rename at VEC_RENAME ($0098). Both implemented
;             in kos_fs_fd.asm (r5+). Requires kos_defs.inc r27+.
;
; Revision: r36 — 10 May 2026 — Part 23: switched include from
;             kos_fs_disk_pool.asm (Part 22 pool helpers — deleted) to
;             kos_fs_host_mgr.asm (Part 23 name-based host manager).
;             No init-order or other functional changes; the new file
;             provides the same _SemTakeBlocking-based MMIO wrappers
;             and _InitHostDisk semantics under different names
;             (_HostMount/_HostUnmount/_HostList/_HostCreate/_HostDelete).
;
; Revision: r35 — 9 May 2026 — Part 22: host-disk backend bring-up.
;             • Init order rewritten: _InitSemPool moved BEFORE _InitFS
;               (was after) so that _InitHostDisk can allocate the
;               disk-mutex semaphore before _InitFS probes the host bays.
;               New order: _InitSemPool → _InitHostDisk → _InitFS.
;             • Include order for kfs/kos_*.asm reorganised. kos_sem.asm
;               now comes before any kfs/* file (kos_fs_host.asm needs
;               sem entry points). kos_fs_host.asm is included between
;               kos_fs_rom.asm and kos_fs.asm so its labels are defined
;               by the time kos_fs.asm's _InitFS references them.
;             • Sem-pool comment updated for new pool address $0400..$047F.
;             • Requires kos_defs.inc r26+, kos_sem.asm r2+,
;               kos_fs_defs.inc r9+, kos_fs.asm r5+, kos_fs_host.asm r1+.
;
; Revision: r34 — 8 May 2026 — Part 20b: counting semaphores wired in.
;             • _InitVectors now installs sys_semcreate at VEC_SEMCREATE
;               ($0084), sys_semtake at VEC_SEMTAKE ($0088),
;               sys_semgive at VEC_SEMGIVE ($008C), sys_semdestroy at
;               VEC_SEMDESTROY ($0090).
;             • _InitKernel now calls _InitSemPool after _InitFS to
;               zero the 16-entry sem pool at $03C8..$0447. Order
;               doesn't actually matter for correctness — _InitSemPool
;               only touches its own pool — but later in the sequence
;               keeps the "feature ordering" intuitive (FS, then sem,
;               then any future bring-ups).
;             • Requires kos_defs.inc r25+, kos_sem.asm r1+,
;               kos_tcb.asm r19+ (TCB_SEM_NEXT zeroing).
;
; Revision: r33 - 7 May 2026 — Phase 19 sys_format wired in.
;             • _InitVectors now installs sys_format at VEC_FORMAT ($0080).
;             • Depends on:
;                 - kos_defs.inc r24+ (TRAP_FORMAT, VEC_FORMAT)
;                 - kfs/kos_fs.asm r3+ (sys_format wrapper)
;
;           r32 - 7 May 2026 — Phase 16.7 wired in.
;             • Active include changed from Test/kos_p16_fs_exec_smoke.asm
;               to kosh/kosh.asm. kosh is now the primary user task,
;               replacing the per-phase smoke harness.
;             • Phase 16 Piece 6 smoke now commented as verified.
;             • Depends on:
;                 - klib/kos_klib_impl.asm r7+ (cursor-style UTOA/ITOA/ITOH)
;                 - kosh/kosh.asm r14+ (with .INCLUDE of kosh_fs_cmds.asm)
;                 - kosh/kosh_fs_cmds.asm r1+
;
;           r31 - 6 May 2026 — Phase 16 Piece 6 wired in.
;             • New include: kfs/kos_fs_exec.asm — sys_exec (TRAP #31).
;               Loads .COM file from disk into a fresh user page and
;               spawns it as a new task. Helpers: _ExecCheckExt,
;               _ExecCopyChain, _ExecCopyOneSector, _ExecStageName.
;             • _InitVectors now installs sys_exec at VEC_EXEC ($007C).
;               All six Phase 16 syscalls (TRAPs #26..#31) are now live.
;             • Active smoke include changed to
;               Test/kos_p16_fs_exec_smoke.asm. Piece 5 RW smoke now
;               commented as verified.
;             Requires kos_fs_exec.asm r1+.
;
;           r30 - 6 May 2026 — Phase 16 Piece 5 wired in.
;             • New include: kfs/kos_fs_fd.asm — file syscalls
;               (sys_open #26, sys_close #27, sys_read #28, sys_write
;               #29, sys_dirent #30) plus internal helpers (_ParsePath,
;               _SlotForDrive, _AllocFd, _FdAddr, _FdValid, etc.).
;             • _InitVectors now installs the five Piece 5 handlers in
;               VEC_OPEN..VEC_DIRENT ($0068..$007B). VEC_EXEC ($007C)
;               remains a bad_trap stub for Piece 6.
;             • Active smoke include changed to
;               Test/kos_p16_fs_rw_smoke.asm. Piece 4 dir smoke now
;               commented as verified.
;             Requires kos_fs_fd.asm r1+, kos_fs_defs.inc r8+.
;
;           r29 - 6 May 2026 — Phase 16 Piece 4 wired in.
;             • New include: kfs/kos_fs_dir.asm — directory operations
;               (_DirNameToFat, _DirNameFromFat, _DirOpen, _DirNext,
;               _DirNextRaw, _DirRewind, _DirLookup, _DirCreate,
;               _DirDelete, _GetDate, _GetTime). Root-directory only;
;               LFN and volume-label entries skipped on iteration;
;               _GetDate/_GetTime are RTC-stub seams (return baked
;               constants) until Phase 17.
;             • Active smoke include changed to
;               Test/kos_p16_fs_dir_smoke.asm. The Pieces 1-3 smoke
;               (kos_p16_fs_smoke.asm) is now commented as verified.
;             Requires kos_fs_dir.asm r1+.
;
;           r28 - 6 May 2026 — Phase 16 Pieces 1+2+3 wired in.
;             • Phase 16 syscall plumbing (TRAP_OPEN..TRAP_EXEC, VEC_OPEN
;               ..VEC_EXEC, FS error codes) folded into kos_defs.inc r21.
;               The earlier kos_defs_phase16_addendum.inc is no longer
;               included or required and can be deleted.
;             • New include: kfs/kos_fs_defs.inc — FS-internal constants
;               (volume table layout, BPB offsets, FAT cache state).
;             • New includes: kfs/kos_fs_ram.asm, kfs/kos_fs_rom.asm,
;               kfs/kos_fs.asm — block backends + top-level FS code
;               (mount, format, FAT walk, cluster allocator).
;             • _InitKernel now calls _InitFS after _InitKLib. Volume
;               table is zeroed, backend function pointers are installed
;               for A: (ROM) and B: (RAM), and each populated slot is
;               probed. On a fresh boot both A: and B: fail to mount
;               (no real ROM image yet, RAM is garbage) — that's expected.
;               After 'format', subsequent boots mount B: successfully.
;             • _InitVectors: TRAP #26..#31 slots remain bad_trap stubs
;               for now — the syscall handlers land in Phase 16 Piece 4+.
;             • Active smoke include changed to Test/kos_p16_fs_smoke.asm.
;             Requires kos_defs.inc r21+, kos_fs_defs.inc r6+,
;             kos_fs.asm r3+, kos_fs_ram.asm r3+, kos_fs_rom.asm r1+.
;
;           r27 - 5 May 2026 — Phase 14. _InitVectors now installs
;             sys_kmalloc (TRAP #24) and sys_kfree (TRAP #25). Wrapper
;             module kos_heap.asm included between kos_kmalloc.asm
;             and the KLIB sources. Active smoke include changed to
;             Test/kos_p14_kheap_syscall_smoke.asm.
;             Requires kos_defs.inc r19+, kos_heap.asm r1+.
;
;           r26 - 5 May 2026 — _InitKernel now writes KERN_STATE_BOOT
;             to KERNEL_STATE at $0232. Promoted to KERN_STATE_RUN by
;             _RestoreIdle just before EINT. Used by _KDelayMs to
;             refuse cleanly when called from boot-time kernel context.
;
;           r25 - 5 May 2026 — Phase 13. Active smoke include changed to
;             Test/kos_p13_klib_tier4_smoke.asm. KLIB jump table now
;             contains 20 LIVE entries (was 15): added STRCAT (35),
;             ATOH (44), RAND16 (48), SRAND (49), DELAY_MS (51).
;             _InitKLib now also seeds KLIB_SEED at $00:$9FFE.
;             Requires klib/kos_klib.inc r4+, klib/kos_klib_template.asm
;             r4+, klib/kos_klib_impl.asm r4+.
;
;           r24 - 5 May 2026 — Phase 12. Active smoke include changed to
;             Test/kos_p12_klib_tier23_smoke.asm. KLIB jump table now
;             contains 15 LIVE entries (was 7): Phase 10 (00, 01, 63),
;             Phase 11 (32, 37, 38, 50), and Phase 12 adds slots 33
;             (STRCPY), 34 (STRCMP), 36 (STRCHR), 39 (MEMCMP), 40 (ITOA),
;             41 (UTOA), 42 (ITOH), 43 (ATOI). Requires klib/kos_klib.inc
;             r3+, klib/kos_klib_template.asm r3+, klib/kos_klib_impl.asm
;             r3+.
;
;           r23 - 5 May 2026 — Phase 11. Active smoke include changed to
;             Test/kos_p11_klib_tier1_smoke.asm. KLIB jump table now
;             contains 7 LIVE entries (was 3): KLIB_MUL16x16_32 (00),
;             KLIB_DIV10 (01), KLIB_STRLEN (32), KLIB_MEMCPY (37),
;             KLIB_MEMSET (38), KLIB_TICKS (50), KLIB_VERSION (63).
;             No changes to _InitKLib or template structure — just new
;             impl symbols wired into existing template slots.
;             Requires klib/kos_klib.inc r2+, klib/kos_klib_template.asm
;             r2+, klib/kos_klib_impl.asm r2+.
;
;           r22 - 5 May 2026 — Phase 10. _InitKLib wired into _InitKernel
;             between _InitHeap and the final RET. Brings up the KLIB
;             RAM jump table at $00:$A000 with 64 entries (3 LIVE: slots
;             00/01/63, 61 stubbed to _BadKlibCall). KLIB does not depend
;             on the heap, but installing after _InitHeap means heap is
;             available if any future KLIB entry needs to allocate state.
;             KLIB sources live in klib/ subdir alongside kernel root.
;             Active smoke include: Test/kos_p10_klib_smoke.asm.
;             Requires kos_defs.inc r19+, klib/kos_klib.inc r1+,
;             klib/kos_klib_template.asm r1+, klib/kos_klib_impl.asm r1+.
;
;           r21 - 4 May 2026 — Branch .S polish.
;             2 unsuffixed branches converted to .S form
;             where target distance is ≤10 instructions.
;             FORWARD ONLY (assembler imm5 is unsigned 0..+31).
;             Per
;             K16 Manual Amendment 2026-05-04 E.5/E.6, default
;             auto-select picks long form; explicit .S saves
;             one word per branch. Saves 2 words.
;
; Revision: r20 - 4 May 2026 — Smoke tests relocated to Test/ subdir.
;             Updated .INCLUDE paths for kos_p3_*_smoke.asm and
;             kos_p9_heap_smoke.asm to "Test/...". Kernel sources
;             remain at top level.
;
;           r19 - 3 May 2026 — Part 9 wiring: kernel heap.
;             - _InitKernel now calls _InitMemConfig (after host detect)
;               and _InitHeap (before splash) to bring up the kernel heap.
;             - Heap region #1 is laid down on page $01 (always); on EMU
;               additional pages from $20..$FF are claimed on demand.
;             - User task pages reduced from $01..$20 (33) to $02..$1F
;               (30) to (a) free page $01 for heap and (b) fix the
;               existing off-by-one that put page $20 outside Digital's
;               2MB ceiling. USER_TCB_COUNT 32 → 30.
;             - Active smoke include: kos_p9_heap_smoke.asm.
;             Requires kos_defs.inc r16+, kos_kmalloc.asm r1+,
;             kos_splash.asm r2+.
;
;           r18 - 2 May 2026 — boot splash added.
;             Replaced the minimal "k/OS Phase 3 - boot OK [host=...]"
;             banner with a proper boxed splash showing version, host,
;             kernel layout, task slot counts, free page count, and
;             build date. Lives in kos_splash.asm; called from boot
;             between _InitKernel and _P2Main via _ShowSplash.
;
;           r17 - 2 May 2026 — Part 8 idle-restore fix.
;             Boot now uses JMP24 _P2Main (instead of CALL24) since
;             _P2Main no longer returns — it ends in JMP24 _IdleLoop.
;             This avoids leaving an orphaned 4-byte return PC frame
;             on the kernel stack indefinitely.
;             Companion changes in kos_ctxsw.asm r28+ (canonical
;             _IdleLoop and _RestoreIdle) and kos_task.asm r12+,
;             kos_spawn.asm r4+ (restore-incoming sites diverted to
;             _RestoreIdle when incoming is IDLE_TCB).
;
;           r16 - 2 May 2026 — Part 8 wiring:
;             - Host detection added to _InitKernel: probes $E0:2468 for
;               SHL($1234)=$2468; matches => Digital, else => EMU.
;               Result stored in KOS_HOST.
;             - Banner now prints "[host=Digital]" or "[host=EMU]" suffix.
;             - Vector installs for sys_putdec (TRAP #20), sys_puthex
;               (TRAP #21), sys_clear (TRAP #22), sys_setcursor (TRAP #23).
;             - Active smoke include: kos_p3_console_smoke.asm.
;             Requires kos_defs.inc r15+, kos_console.asm r5+,
;             kos_p3_console_smoke.asm r1+.
;           r15 - 2 May 2026 — TRAP MICROCODE BUG RESOLVED (gotcha #33).
;             T8 needs 8 bits but the direct path to DB-Lo only carries
;             5. Microcode change routes T8 via AB-Hi to DB, recovering
;             the full byte width — zero hardware change. All vector
;             mappings restored to canonical Phase 3 Part 7.
;           r14, r13 - earlier TRAP # swap workaround attempts (reverted)
;           r12 - Part 7 wiring
;           (earlier history elided)
; ============================================================================

                .INCLUDE "kos_defs.inc"
                .INCLUDE "klib/kos_klib.inc"                     ; Phase 10
                .INCLUDE "emulib/kos_emulib.inc"                 ; Part 39 — emulator-only host-disk shim
                .INCLUDE "kfs/kos_fs_defs.inc"                   ; Phase 16

;-----------------------------------------------------------------------------
; Kernel identity — SOURCE OF TRUTH for k/OS version and build date.
;-----------------------------------------------------------------------------
; These four immediate constants are the canonical k/OS version and build
; date. _InitKernel copies them into page-$00 slots (KOS_VERSION,
; KOS_BUILD_YEAR, KOS_BUILD_MONTH, KOS_BUILD_DAY) at boot so any task can
; read the kernel's identity at runtime via plain LOADZ.
;
; To cut a new k/OS release: bump these four values, rebuild the kernel.
; Nothing else needs to change — kosh's splash and `info` command both
; query the page-$00 slots, so they pick up the new version automatically.
;
; KOS_VERSION_VALUE encoding: high byte = major, low byte = minor. The
; splash renders minor as TWO digits (zero-padded), so $0101 reads "1.01".
;   $0100 = v1.00 (Part 39 release, 29 May 2026)
;   $0101 = v1.01 (Part 49, 28 June 2026 — graphics-task foreground)
;   $0101 retained through Part 51 (30 June 2026 — VC auto-switch on launch);
;           phase tag bumped to "Phase 51+", version held at v1.01.
;   $0102 = v1.02 (Part 61, 8 August 2026 — host-populated RAM disk: the
;           kosh boot seeder is gone, A:STARTUP.KSH bootstraps a host-side
;           boot.ksh via `load ramdisk/...`, plus brief (-b) scripts and
;           drive-qualified bare execution)
;   $010A = v1.10 (future)
;   $0200 = v2.00 (future)
;-----------------------------------------------------------------------------
KOS_VERSION_VALUE     .EQU $0102               ; v1.02
KOS_BUILD_YEAR_VALUE  .EQU __YEAR__            ; auto-stamped at kernel assemble time
KOS_BUILD_MONTH_VALUE .EQU __MONTH__
KOS_BUILD_DAY_VALUE   .EQU __DAY__

                .BASE   $F00000
                .ORG    $FF0000

Start:
                LOADI   Y3, #$00
                LOADI   X3, #KERNEL_STACK_TOP

                CALL24  _InitVectors
                CALL24  _InitKernel

                ; Part 20b smoke. Kept available for re-validation but
                ; disabled by default once the primitives have been
                ; verified working on EMU + Digital (8 May 2026).
                ; CALL24  _SemSmoke

                ; Minimal kernel boot message. The full splash (logo,
                ; host, heap, pages, tasks, boot date) is the first
                ; thing kosh emits once it's running — see kosh_splash.asm.
                ; Putting it there means it lands in the shell back-buffer
                ; and survives foreground switches; the kernel only needs
                ; to confirm it reached the point of spawning the shell.
                LOADI   Y0, #>boot_msg
                LOADI   X0, #<boot_msg
                CALL24  _RawPuts

                ; _P2Main is the smoke's entry point; it never returns
                ; (ends with JMP24 _IdleLoop). Use JMP24 so we don't
                ; leave an orphaned return PC on the kernel stack.
                JMP24   _P2Main

                ; (Unreachable; defensive marker if _P2Main ever returns.)
                HALT    #$01

; ============================================================================
; _InitVectors — fill vector table
;
; CRITICAL: INT/IRQ slots get bad_int (RTI return), TRAP slots get bad_trap
; (RET return). Hardware INT pushes 6 bytes (PC+SR); TRAP pushes 4 bytes (PC).
; ============================================================================
_InitVectors:
                PUSH    D0, XY3
                PUSH    D1, XY3
                PUSH    D2, XY3

                ;-- Pass 1a: fill INT/IRQ slots ($0000..$0023) with bad_int --
                LOADI   D0, #<bad_int
                LOADI   D1, #>bad_int

                LOADI   D2, #0
.fill_int_loop:
                LOADI   Y0, #$00
                MOVE    X0, D2

                STORED  D1, [XY0]
                STORED  D0, [XY0+#2]

                ADD     D2, #4
                CMP     D2, #VEC_TRAP_FIRST     ; first TRAP-style slot (r38)
                BLO     .fill_int_loop

                ;-- Pass 1b: fill TRAP slots (VEC_TRAP_FIRST..$01FC) with bad_trap --
                LOADI   D0, #<bad_trap
                LOADI   D1, #>bad_trap

.fill_trap_loop:
                LOADI   Y0, #$00
                MOVE    X0, D2

                STORED  D1, [XY0]
                STORED  D0, [XY0+#2]

                ADD     D2, #4
                CMP     D2, #VEC_TABLE_END
                BLO     .fill_trap_loop

                ;-- Pass 2: install real syscall handlers ------------------
                LOADI   Y0, #$00

                LOADI   X0, #VEC_PUTCHAR
                LOADI   D0, #>sys_putchar
                STORED  D0, [XY0]
                LOADI   D0, #<sys_putchar
                STORED  D0, [XY0+#2]

                LOADI   X0, #VEC_GETCHAR
                LOADI   D0, #>sys_getchar
                STORED  D0, [XY0]
                LOADI   D0, #<sys_getchar
                STORED  D0, [XY0+#2]

                LOADI   X0, #VEC_PUTS
                LOADI   D0, #>sys_puts
                STORED  D0, [XY0]
                LOADI   D0, #<sys_puts
                STORED  D0, [XY0+#2]

                LOADI   X0, #VEC_PUTLP
                LOADI   D0, #>sys_putlp
                STORED  D0, [XY0]
                LOADI   D0, #<sys_putlp
                STORED  D0, [XY0+#2]

                LOADI   X0, #VEC_GETS
                LOADI   D0, #>sys_gets
                STORED  D0, [XY0]
                LOADI   D0, #<sys_gets
                STORED  D0, [XY0+#2]

                LOADI   X0, #VEC_GETPID
                LOADI   D0, #>sys_getpid
                STORED  D0, [XY0]
                LOADI   D0, #<sys_getpid
                STORED  D0, [XY0+#2]

                LOADI   X0, #VEC_YIELD
                LOADI   D0, #>sys_yield
                STORED  D0, [XY0]
                LOADI   D0, #<sys_yield
                STORED  D0, [XY0+#2]

                LOADI   X0, #VEC_EXIT
                LOADI   D0, #>sys_exit
                STORED  D0, [XY0]
                LOADI   D0, #<sys_exit
                STORED  D0, [XY0+#2]

                LOADI   X0, #VEC_SLEEP
                LOADI   D0, #>sys_sleep
                STORED  D0, [XY0]
                LOADI   D0, #<sys_sleep
                STORED  D0, [XY0+#2]

                ; Part 7 syscalls
                LOADI   X0, #VEC_SPAWN
                LOADI   D0, #>sys_spawn
                STORED  D0, [XY0]
                LOADI   D0, #<sys_spawn
                STORED  D0, [XY0+#2]

                LOADI   X0, #VEC_WAIT
                LOADI   D0, #>sys_wait
                STORED  D0, [XY0]
                LOADI   D0, #<sys_wait
                STORED  D0, [XY0+#2]

                ; Part 8 syscalls
                LOADI   X0, #VEC_PUTDEC
                LOADI   D0, #>sys_putdec
                STORED  D0, [XY0]
                LOADI   D0, #<sys_putdec
                STORED  D0, [XY0+#2]

                LOADI   X0, #VEC_PUTHEX
                LOADI   D0, #>sys_puthex
                STORED  D0, [XY0]
                LOADI   D0, #<sys_puthex
                STORED  D0, [XY0+#2]

                LOADI   X0, #VEC_CLEAR
                LOADI   D0, #>sys_clear
                STORED  D0, [XY0]
                LOADI   D0, #<sys_clear
                STORED  D0, [XY0+#2]

                LOADI   X0, #VEC_SETCURSOR
                LOADI   D0, #>sys_setcursor
                STORED  D0, [XY0]
                LOADI   D0, #<sys_setcursor
                STORED  D0, [XY0+#2]

                ; Part 15 - terminal geometry syscall (TRAP #19)
                LOADI   X0, #VEC_TERMSIZE
                LOADI   D0, #>sys_termsize
                STORED  D0, [XY0]
                LOADI   D0, #<sys_termsize
                STORED  D0, [XY0+#2]

                ; Step 1 - console cursor-visibility (TRAP #22)
                LOADI   X0, #VEC_CURSORVIS
                LOADI   D0, #>sys_cursorvis
                STORED  D0, [XY0]
                LOADI   D0, #<sys_cursorvis
                STORED  D0, [XY0+#2]

                ; Step 2 - console attr / clear-region / query (TRAP #20,21,23,24)
                LOADI   X0, #VEC_SETATTR
                LOADI   D0, #>sys_setattr
                STORED  D0, [XY0]
                LOADI   D0, #<sys_setattr
                STORED  D0, [XY0+#2]
                LOADI   X0, #VEC_CLREOL
                LOADI   D0, #>sys_clreol
                STORED  D0, [XY0]
                LOADI   D0, #<sys_clreol
                STORED  D0, [XY0+#2]
                LOADI   X0, #VEC_WHEREXY
                LOADI   D0, #>sys_wherexy
                STORED  D0, [XY0]
                LOADI   D0, #<sys_wherexy
                STORED  D0, [XY0+#2]
                LOADI   X0, #VEC_CLREOS
                LOADI   D0, #>sys_clreos
                STORED  D0, [XY0]
                LOADI   D0, #<sys_clreos
                STORED  D0, [XY0+#2]

                ; Phase 14 syscalls
                LOADI   X0, #VEC_KMALLOC
                LOADI   D0, #>sys_kmalloc
                STORED  D0, [XY0]
                LOADI   D0, #<sys_kmalloc
                STORED  D0, [XY0+#2]

                LOADI   X0, #VEC_KFREE
                LOADI   D0, #>sys_kfree
                STORED  D0, [XY0]
                LOADI   D0, #<sys_kfree
                STORED  D0, [XY0+#2]

                ; Phase 14 Part 2 syscalls
                LOADI   X0, #VEC_KREALLOC
                LOADI   D0, #>sys_krealloc
                STORED  D0, [XY0]
                LOADI   D0, #<sys_krealloc
                STORED  D0, [XY0+#2]

                LOADI   X0, #VEC_HEAPSTATS
                LOADI   D0, #>sys_heapstats
                STORED  D0, [XY0]
                LOADI   D0, #<sys_heapstats
                STORED  D0, [XY0+#2]

                ; Phase 14 Part 3b — per-TID query
                LOADI   X0, #VEC_HEAPSTATS_BY_TID
                LOADI   D0, #>sys_heapstats_by_tid
                STORED  D0, [XY0]
                LOADI   D0, #<sys_heapstats_by_tid
                STORED  D0, [XY0+#2]

                ; Phase 16 Piece 5 — file syscalls
                LOADI   X0, #VEC_OPEN
                LOADI   D0, #>sys_open
                STORED  D0, [XY0]
                LOADI   D0, #<sys_open
                STORED  D0, [XY0+#2]

                LOADI   X0, #VEC_CLOSE
                LOADI   D0, #>sys_close
                STORED  D0, [XY0]
                LOADI   D0, #<sys_close
                STORED  D0, [XY0+#2]

                LOADI   X0, #VEC_READ
                LOADI   D0, #>sys_read
                STORED  D0, [XY0]
                LOADI   D0, #<sys_read
                STORED  D0, [XY0+#2]

                LOADI   X0, #VEC_WRITE
                LOADI   D0, #>sys_write
                STORED  D0, [XY0]
                LOADI   D0, #<sys_write
                STORED  D0, [XY0+#2]

                LOADI   X0, #VEC_DIRENT
                LOADI   D0, #>sys_dirent
                STORED  D0, [XY0]
                LOADI   D0, #<sys_dirent
                STORED  D0, [XY0+#2]

                ; Phase 16 Piece 6 — sys_exec
                LOADI   X0, #VEC_EXEC
                LOADI   D0, #>sys_exec
                STORED  D0, [XY0]
                LOADI   D0, #<sys_exec
                STORED  D0, [XY0+#2]

                ; Part 20 — sys_kill
                LOADI   X0, #VEC_KILL
                LOADI   D0, #>sys_kill
                STORED  D0, [XY0]
                LOADI   D0, #<sys_kill
                STORED  D0, [XY0+#2]

                ; Part 20 — sys_setvidmode (Device group)
                LOADI   X0, #VEC_SETVIDMODE
                LOADI   D0, #>sys_setvidmode
                STORED  D0, [XY0]
                LOADI   D0, #<sys_setvidmode
                STORED  D0, [XY0+#2]

                ; Phase 19 — sys_format
                LOADI   X0, #VEC_FORMAT
                LOADI   D0, #>sys_format
                STORED  D0, [XY0]
                LOADI   D0, #<sys_format
                STORED  D0, [XY0+#2]

                ; Part 20b — counting semaphores
                LOADI   X0, #VEC_SEMCREATE
                LOADI   D0, #>sys_semcreate
                STORED  D0, [XY0]
                LOADI   D0, #<sys_semcreate
                STORED  D0, [XY0+#2]

                LOADI   X0, #VEC_SEMTAKE
                LOADI   D0, #>sys_semtake
                STORED  D0, [XY0]
                LOADI   D0, #<sys_semtake
                STORED  D0, [XY0+#2]

                LOADI   X0, #VEC_SEMGIVE
                LOADI   D0, #>sys_semgive
                STORED  D0, [XY0]
                LOADI   D0, #<sys_semgive
                STORED  D0, [XY0+#2]

                LOADI   X0, #VEC_SEMDESTROY
                LOADI   D0, #>sys_semdestroy
                STORED  D0, [XY0]
                LOADI   D0, #<sys_semdestroy
                STORED  D0, [XY0+#2]

                ; Part 25 — rm / mv
                LOADI   X0, #VEC_UNLINK
                LOADI   D0, #>sys_unlink
                STORED  D0, [XY0]
                LOADI   D0, #<sys_unlink
                STORED  D0, [XY0+#2]

                LOADI   X0, #VEC_RENAME
                LOADI   D0, #>sys_rename
                STORED  D0, [XY0]
                LOADI   D0, #<sys_rename
                STORED  D0, [XY0+#2]

                ; Part 34 — sys_diskfree
                LOADI   X0, #VEC_DISKFREE
                LOADI   D0, #>sys_diskfree
                STORED  D0, [XY0]
                LOADI   D0, #<sys_diskfree
                STORED  D0, [XY0+#2]

                ; Subdir support — sys_mkdir
                LOADI   X0, #VEC_MKDIR
                LOADI   D0, #>sys_mkdir
                STORED  D0, [XY0]
                LOADI   D0, #<sys_mkdir
                STORED  D0, [XY0+#2]

                ; Path resolver — sys_resolve
                LOADI   X0, #VEC_RESOLVE
                LOADI   D0, #>sys_resolve
                STORED  D0, [XY0]
                LOADI   D0, #<sys_resolve
                STORED  D0, [XY0+#2]

                ; Path resolver — sys_pwd
                LOADI   X0, #VEC_PWD
                LOADI   D0, #>sys_pwd
                STORED  D0, [XY0]
                LOADI   D0, #<sys_pwd
                STORED  D0, [XY0+#2]

                ; Subdir support — sys_rmdir
                LOADI   X0, #VEC_RMDIR
                LOADI   D0, #>sys_rmdir
                STORED  D0, [XY0]
                LOADI   D0, #<sys_rmdir
                STORED  D0, [XY0+#2]

                ; Phase B Step 2 — sys_setforeground
                LOADI   X0, #VEC_SETFOREGROUND
                LOADI   D0, #>sys_setforeground
                STORED  D0, [XY0]
                LOADI   D0, #<sys_setforeground
                STORED  D0, [XY0+#2]

                ; Phase B Step 1 — sys_register_shell
                LOADI   X0, #VEC_REGISTER_SHELL
                LOADI   D0, #>sys_register_shell
                STORED  D0, [XY0]
                LOADI   D0, #<sys_register_shell
                STORED  D0, [XY0+#2]

                ; Named drives v2 — sys_assign
                LOADI   X0, #VEC_ASSIGN
                LOADI   D0, #>sys_assign
                STORED  D0, [XY0]
                LOADI   D0, #<sys_assign
                STORED  D0, [XY0+#2]

                ; sys_kbhit — non-blocking key poll (animated graphics)
                LOADI   X0, #VEC_KBHIT
                LOADI   D0, #>sys_kbhit
                STORED  D0, [XY0]
                LOADI   D0, #<sys_kbhit
                STORED  D0, [XY0+#2]

                POP     D2, XY3
                POP     D1, XY3
                POP     D0, XY3
                RET

; ============================================================================
; _InitKernel — zero kernel sysvars, init TCB pool, detect host environment
; ============================================================================
_InitKernel:
                PUSH    D0, XY3

                LOADI   D0, #0
                STOREZ  D0, [#SYS_TICKS]
                STOREZ  D0, [#SYS_TICKS_HI]     ; Part 30 — was SYS_FLAGS (renamed)
                STOREZ  D0, [#KBD_HEAD]
                STOREZ  D0, [#KBD_TAIL]
                STOREZ  D0, [#KOS_HOST]         ; HOST_UNKNOWN initially
                STOREZ  D0, [#KERNEL_STATE]     ; KERN_STATE_BOOT (Phase 13)

                ;-- Publish kernel identity (Part 39 r-final) ---------------
                ; Stage KOS_VERSION_VALUE etc. (defined at the top of this
                ; file) into the page-$00 slots so any task can query the
                ; kernel's identity at runtime via LOADZ. See kos_defs.inc
                ; r43+ for the slot layout and read pattern.
                LOADI   D0, #KOS_VERSION_VALUE
                STOREZ  D0, [#KOS_VERSION]
                LOADI   D0, #KOS_BUILD_YEAR_VALUE
                STOREZ  D0, [#KOS_BUILD_YEAR]
                LOADI   D0, #KOS_BUILD_MONTH_VALUE
                STOREZ  D0, [#KOS_BUILD_MONTH]
                LOADI   D0, #KOS_BUILD_DAY_VALUE
                STOREZ  D0, [#KOS_BUILD_DAY]
                LOADI   D0, #<_KosPhaseTag      ; 16-bit offset within ROM page
                STOREZ  D0, [#KOS_PHASE_TAG_PTR]
                LOADI   D0, #>_KosPhaseTag      ; ROM page byte ($FF) — kernel ROM is
                STOREZ  D0, [#KOS_PHASE_TAG_PAGE] ;   .ORG $FF0000, NOT page $00
                LOADI   D0, #<_KosBuildStr      ; kernel build-stamp string (ISO)
                STOREZ  D0, [#KOS_BUILD_STR_PTR]
                LOADI   D0, #>_KosBuildStr      ; ROM page byte ($FF)
                STOREZ  D0, [#KOS_BUILD_STR_PAGE]

                ;-- Initialise TCB pool ------------------------------------
                ; Marks all TCBs TS_UNUSED and constructs the idle TCB at
                ; slot 0. Done here (rather than inside the smoke) so the
                ; TCB pool is in a known state by the time kosh's splash
                ; queries it for free-page and task counts.
                CALL24  _InitTCBPool

                ;-- Host detection -----------------------------------------
                ; Read $E0:LOOKUP_PROBE_OFF; on Digital this is real ROM and
                ; returns LOOKUP_PROBE_VAL (the SHL of the lookup index).
                ; On EMU there's no backing ROM image — reads return $0000.
                CALL24  _DetectHost

                ;-- Memory configuration (Part 9) --------------------------
                ; Sets KOS_PAGE_COUNT, KOS_KHEAP_BASE, KOS_KHEAP_END based
                ; on the detected host. Must come AFTER _DetectHost.
                CALL24  _InitMemConfig

                ;-- Kernel heap bring-up (Part 9) --------------------------
                ; Lays down region #1 on page $01 with one big free block.
                ; Must come AFTER _InitMemConfig.
                CALL24  _InitHeap

                ;-- KLIB jump table bring-up (Phase 10) -------------------
                ; Copies the 64-entry ROM template to RAM at $00:$A000.
                ; Slots 00 (KLIB_MUL16x16_32), 01 (KLIB_DIV10), 63
                ; (KLIB_VERSION) are LIVE; all others stub to _BadKlibCall
                ; which prints a diagnostic and HALTs (#$1B).
                CALL24  _InitKLib

                ;-- EMULIB jump table bring-up (Part 39) ------------------
                ; Copies the 64-entry ROM template to RAM at $00:$A200.
                ; Slots 00..09 (host-disk shim _HostList etc.), 63
                ; (EMULIB_VERSION) are LIVE; all others stub to
                ; _BadEmulibCall which prints a diagnostic and HALTs (#$1C).
                ; Order vs _InitKLib doesn't matter — neither table
                ; depends on the other at init time.
                CALL24  _InitEmulib

                ;-- Semaphore pool bring-up (Part 20b) --------------------
                ; Zeroes 16-entry pool at $0400..$047F; all slots free.
                ; Must come BEFORE _InitHostDisk (which allocates the
                ; disk-mutex sem) and BEFORE _InitFS (which calls
                ; _TryMount → _BlockReadHost → take disk-mutex).
                CALL24  _InitSemPool

                ;-- Host-disk controller bring-up (Part 22) ---------------
                ; Creates the disk-mutex semaphore (count=1) at the slot
                ; pointed to by HOST_DISK_SEM. Must come BEFORE _InitFS
                ; because _InitFS probes slots C..F which take the mutex.
                CALL24  _InitHostDisk

                ;-- Filesystem bring-up (Phase 16) ------------------------
                ; Zeroes volume table, installs backend function pointers
                ; for A: (ROM, read-only), B: (RAM, read+write), and
                ; C..F: (host-disk bays 0..3). Probes all populated slots.
                ; The FAT cache is also invalidated.
                ; Must come AFTER _InitHeap (in case a future FS feature
                ; allocates), AFTER _DetectHost (format needs KOS_HOST),
                ; AFTER _InitSemPool, and AFTER _InitHostDisk.
                CALL24  _InitFS

                ;-- Named-volume assign table (named drives v2) -----------
                ; Clears the 32-entry assign table, then seeds the locked
                ; system volumes ROM: (A:) and RAM: (B:) — only for drives
                ; that actually mounted. Must come AFTER _InitFS.
                CALL24  _SeedAssigns

                ;-- Video driver bring-up (Part 20) -----------------------
                ; Forces VID_MODE = 0 (text mode) and clears
                ; VIDEO_OWNER_TID. Independent of prior state — a soft
                ; reset that left the panel in graphics mode lands here
                ; and goes back to text.
                CALL24  _InitVideo

                POP     D0, XY3
                RET

; ============================================================================
; _SeedAssigns — clear the assign table and seed locked system volumes.
;   ROM: -> A: (locked, read-only) ; RAM: -> B: (locked). Each seeded only
;   if its backing drive mounted. Called from boot after _InitFS.
;   Clobbers: D0, D1, D2, D3, X0, X1, Y0, Y1, XY2, flags
; ============================================================================
_SeedAssigns:
                ; --- clear the 32-entry table (512 B) ---
                LOADI   X0, #AS_TABLE_BASE
                LOADI   Y0, #$00
                LOADI   D0, #0
                LOADI   D1, #AS_TABLE_END-AS_TABLE_BASE
.ssa_clr:
                STOREB  D0, [XY0]+
                SUB     D1, #1
                BNE     .ssa_clr
                ; --- seed ROM: -> A: (locked, read-only) ---
                LOADI   D0, #0
                LOADI   D1, #AS_FLAG_LOCKED+AS_FLAG_READONLY
                LOADI   Y0, #>str_vol_rom
                LOADI   X0, #<str_vol_rom
                CALL24  _SeedAssign
                ; --- seed RAM: -> B: (locked) ---
                LOADI   D0, #1
                LOADI   D1, #AS_FLAG_LOCKED
                LOADI   Y0, #>str_vol_ram
                LOADI   X0, #<str_vol_ram
                CALL24  _SeedAssign
                RET

; ============================================================================
; _SeedAssign — seed one assign-table entry, iff its backing drive mounted.
;   The table is pre-cleared by _SeedAssigns, so AS_ROOTCLU and the spare
;   bytes are already 0 — only AS_NAME / AS_DRIVE / AS_FLAGS are written.
;
;   In:    D0  = drive index
;          D1  = flags (AS_FLAGS)
;          XY0 = ptr to name (UPPER ASCIIZ, <= 11 chars)  [Y0=page, X0=off]
;   Out:   entry seeded, or silently skipped if drive unmounted / table full
;   Clobbers: D0, D1, D2, D3, X0, X1, Y1, XY2, flags
; ============================================================================
_SeedAssign:
                MOVE    D2, D0                  ; save drive (survives _SlotForDrive)
                MOVE    D3, D1                  ; save flags
                CALL24  _SlotForDrive           ; D0=drive -> XY2 ; C=1 if unmounted
                BCS     .sda_skip               ; not mounted -> don't seed
                ; find first free entry (AS_NAME[0] == 0)
                LOADI   X1, #AS_TABLE_BASE
                LOADI   Y1, #$00
                LOADI   D0, #AS_MAX
.sda_find:
                LOADB   D1, [XY1]
                AND     D1, #$FF
                BEQ     .sda_free
                ADD     X1, #AS_ENTRY_SIZE
                SUB     D0, #1
                BNE     .sda_find
                RET                             ; table full -> skip
.sda_free:
                MOVE    D0, X1                  ; save entry base offset
                ; copy name  [XY0] -> [XY1] (dest at AS_NAME = entry+0)
.sda_copy:
                LOADB   D1, [XY0]
                AND     D1, #$FF
                STOREB  D1, [XY1]+
                CMP     D1, #0
                BEQ     .sda_fields
                INC     XY0, #1
                BRA     .sda_copy
.sda_fields:
                MOVE    X1, D0                  ; restore entry base ptr
                LOADI   Y1, #$00
                MOVE    D1, D2                  ; drive
                STOREB  D1, [XY1+#AS_DRIVE]
                MOVE    D1, D3                  ; flags
                STOREB  D1, [XY1+#AS_FLAGS]
                ; AS_ROOTCLU stays 0 (table pre-cleared)
.sda_skip:
                RET

; ============================================================================
; _DetectHost — probe $E0:2468 to identify Digital vs EMU
;   Stores HOST_DIGITAL or HOST_EMU into KOS_HOST.
;   Clobbers: D0, XY0
; ============================================================================
_DetectHost:
                PUSH    D0, XY3
                PUSH    XY0, XY3

                LOADI   Y0, #LOOKUP_PAGE
                LOADI   X0, #LOOKUP_PROBE_OFF
                LOADD   D0, [XY0]
                CMP     D0, #LOOKUP_PROBE_VAL
                BEQ.S     .is_digital

                LOADI   D0, #HOST_EMU
                STOREZ  D0, [#KOS_HOST]
                LOADI   D0, #1                  ; EMU: 30 Hz timer × 1 = 30 ticks/sec
                STOREZ  D0, [#TICK_INCREMENT]
                BRA.S     .det_done
.is_digital:
                LOADI   D0, #HOST_DIGITAL
                STOREZ  D0, [#KOS_HOST]
                LOADI   D0, #5                  ; Digital: 6 Hz timer × 5 = 30 ticks/sec
                STOREZ  D0, [#TICK_INCREMENT]
.det_done:
                POP     XY0, XY3
                POP     D0, XY3
                RET

; ============================================================================
; Boot banner string
;   Single-line boot message emitted between _InitKernel and the spawn of
;   the first shell. The rich splash (logo + system info) is rendered by
;   kosh on entry so it goes through the shell back-buffer and survives
;   foreground switching.
; ============================================================================
boot_msg:       .TEXT   "Booting k/OS", $0A, 0

; Named-volume seed names (UPPER, ASCIIZ; .TEXT auto-pads to even)
str_vol_rom:    .TEXT   "ROM", 0
str_vol_ram:    .TEXT   "RAM", 0

; ============================================================================
; Kernel phase-tag string
;   Pointed at by the page-$00 slot KOS_PHASE_TAG_PTR (set by _InitKernel
;   to the low 16 of this label's address). Any task can read the slot
;   and TRAP_PUTS the string. Single source of truth for the "Phase NN+"
;   marker that appears on the splash and in the `info` command.
;
;   To bump the phase tag for a new release: edit the string below,
;   rebuild the kernel. kosh picks up the change automatically without
;   needing kosh.com to be rebuilt.
; ============================================================================
_KosPhaseTag:   .TEXT   "Phase 61+", 0

; k/OS build stamp - ISO 8601 date+time, auto-stamped at kernel assemble time.
; Published to page-$00 via KOS_BUILD_STR_PTR/PAGE (same pattern as the phase
; tag). Consumed by kosh splash + info.
_KosBuildStr:   .TEXT   __DATE__, " ", __TIME__, 0

                .INCLUDE "kernel/kos_bad_trap.asm"
                .INCLUDE "kernel/kos_rawio.asm"
                .INCLUDE "kdrv/kos_console.asm"                  ; Part 20 — moved to kdrv/
                .INCLUDE "kdrv/kos_kbd.asm"                      ; Phase A — keyboard ring (13 May 2026)
                .INCLUDE "kernel/kos_task.asm"
                .INCLUDE "kernel/kos_tcb.asm"
                .INCLUDE "kernel/kos_sched.asm"
                .INCLUDE "kernel/kos_ctxsw.asm"
                .INCLUDE "kernel/kos_spawn.asm"
                .INCLUDE "kdrv/kos_video.asm"                    ; Part 20 — video driver
                .INCLUDE "kernel/kos_kmalloc.asm"                ; Part 9
                .INCLUDE "kernel/kos_heap.asm"                   ; Phase 14
                .INCLUDE "kernel/kos_sem.asm"                    ; Part 20b — counting semaphores (now needed by kos_fs_host)
                .INCLUDE "kernel/kos_switcher.asm"               ; Phase B Step 1 — shell registration / foreground switcher (13 May 2026)
                .INCLUDE "kfs/kos_fs_ram.asm"            ; Phase 16
                .INCLUDE "kfs/kos_fs_rom.asm"            ; Phase 16
                .INCLUDE "kfs/kos_fs_host.asm"           ; Part 22 — host-disk backend
                .INCLUDE "kfs/kos_fs_host_mgr.asm"       ; Part 23 — host mgr
                .INCLUDE "kfs/kos_fs.asm"                ; Phase 16
                .INCLUDE "kfs/kos_fs_dir.asm"            ; Phase 16 Piece 4
                .INCLUDE "kfs/kos_fs_dir_lfn.asm"        ; Part 47 — LFN family (split from kos_fs_dir)
                .INCLUDE "kfs/kos_fs_dir_path.asm"       ; Part 47 — path resolver + pwd (split from kos_fs_dir)
                .INCLUDE "kfs/kos_fs_fd.asm"             ; Phase 16 Piece 5
                .INCLUDE "kfs/kos_fs_exec.asm"           ; Phase 16 Piece 6
                .INCLUDE "klib/kos_klib_template.asm"             ; Phase 10
                .INCLUDE "klib/kos_klib_impl.asm"                 ; Phase 10
                .INCLUDE "emulib/kos_emulib_template.asm"         ; Part 39 — emulator-only host-disk shim
                ; .INCLUDE "Test/kos_p3_spawn_smoke.asm"         ; Part 7 (verified)
                ; .INCLUDE "Test/kos_p3_console_smoke.asm"       ; Part 8 (verified)
                ; .INCLUDE "Test/kos_p9_heap_smoke.asm"          ; Part 9 (verified)
                ; .INCLUDE "Test/kos_p10_klib_smoke.asm"         ; Phase 10 (verified)
                ; .INCLUDE "Test/kos_p11_klib_tier1_smoke.asm"   ; Phase 11 (verified)
                ; .INCLUDE "Test/kos_p12_klib_tier23_smoke.asm"  ; Phase 12 (verified)
                ; .INCLUDE "Test/kos_p13_klib_tier4_smoke.asm"   ; Phase 13 (verified)
                ; .INCLUDE "Test/kos_p14_kheap_syscall_smoke.asm" ; Phase 14 Part 1 (verified)
                ; .INCLUDE "Test/kos_p14_kheap_user_smoke.asm"   ; Phase 14 Part 1b (verified)
                ; .INCLUDE "Test/kos_p14p2_heap_smoke.asm"       ; Phase 14 Part 2 — verified
                ; .INCLUDE "Test/kos_p14p3_reap_smoke.asm"       ; Phase 14 Part 3b — verified 17 May 2026 (9/9 PASS)
                ; .INCLUDE "Test/kos_p16_fs_smoke.asm"           ; Phase 16 Pieces 1-3 (verified)
                ; .INCLUDE "Test/kos_p16_fs_dir_smoke.asm"       ; Phase 16 Piece 4 (verified)
                ; .INCLUDE "Test/kos_p16_fs_rw_smoke.asm"        ; Phase 16 Piece 5 (verified)
                ; .INCLUDE "Test/kos_p16_fs_exec_smoke.asm"      ; Phase 16 Piece 6 (verified)
                ; .INCLUDE "Test/kos_sem_smoke.asm"        ; Part 20b — sem smoke (verified 8 May 2026)
                .INCLUDE "kosh/kosh_boot.asm"                    ; Part 39 r2 — was kosh/kosh.asm; kosh.com now .INCBIN'd inside kosh_boot.asm
