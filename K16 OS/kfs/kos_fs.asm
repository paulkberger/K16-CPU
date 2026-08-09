; ============================================================================
; kos_fs.asm — k/OS Phase 16: top-level filesystem code
; ============================================================================
; Date:    18 May 2026
; Status:  Phase 16 + Part 24 + Part 25 + Part 34 + sys_mkdir
;
; Revision: r14 — 17 June 2026 — Part 47: mkdir/rmdir LFN-aware. sys_mkdir
;             dup-check _DirLookup->_DirLookupLong; leaf link now
;             _GenShortName + needs_lfn branch (_DirCreateRun for a
;             long dir name, else _DirCreate), carrying attr=DIR/
;             cluster=newclu. _RemoveDir lookup->_DirLookupLong and
;             _DirDelete->_DirDeleteRun (whole-run). Directory
;             cluster '.'/'..' contents unchanged (8.3).
; Revision: r13 — 16 June 2026 — subdir support: sys_mkdir (TRAP #69) added
;             at end of file. Path-string ABI (XY0 = "X:NAME"), matching
;             sys_unlink: _ParsePath -> drive + 8.3 name; read-only pre-
;             flight via VOL_BLOCKWRITE_PTR (not VOL_READONLY); dup-check
;             via _DirLookup -> _AllocCluster -> _DirInitCluster (writes
;             '.'/'..' with '..'=0 for the root parent) -> _DirCreate link;
;             _FreeCluster rollback if init/link fails. newclu held on the
;             stack (not slot scratch) to dodge the VOL_RESERVED_3 "$36
;             looks free" hazard. Non-leaf DINT / EINT-gated exit per
;             sys_format.
;             NOTE: sys_mkdir CALLRs _ParsePath/_SlotForDrive (kos_fs_fd.asm)
;             and _DirLookup/_DirCreate/_DirInitCluster (kos_fs_dir.asm),
;             .INCLUDEd AFTER this file. If the assembler reports a CALLR
;             displacement out of range, switch that call to CALL16.
;
; Revision: r12 — 18 May 2026 — Part 34 polish: _VolFreeClusters now hoists
;             the loop bound out of the per-iteration body. Previously it
;             reloaded VOL_TOTAL_CLUSTERS + ADD CLUSTER_FIRST_VALID at the
;             top of every iteration; the new code computes the limit once
;             at function entry and stashes it in DISKFREE_LIMIT
;             (kos_fs_defs.inc r13 → r14, new slot at $03F8). For a typical
;             1MB volume (2030 clusters) this saves ~8K cycles per
;             sys_diskfree call. Functional behaviour identical.
;
; Revision: r11 — 18 May 2026 — Part 34: _AllocCluster now uses the proper
;             VOL_TOTAL_CLUSTERS-based bound. Previously bounded by
;             VOL_TOTAL_SECTORS, which over-estimated by reserved + FAT +
;             root-dir sectors (~18 on a 1MB volume). Behaviour identical
;             when free space exists (loop terminates on first FAT_FREE);
;             ENOSPC detection is now O(actual data clusters) instead of
;             O(total sectors).
;
;             Bound: VOL_TOTAL_CLUSTERS + CLUSTER_FIRST_VALID. Cluster
;             numbers 2..(N+1) are valid; first invalid number is N+2.
;             Safe against the mount-time $FFFF sentinel (would wrap to
;             $0001 and refuse all allocations — correct for a too-big
;             volume) and against VOL_TOTAL_CLUSTERS=0 on unmounted slots
;             (refuses to allocate, also correct).
;
; Revision: r10 — 11 May 2026 — CRITICAL BUG FIX: _FreeCluster now actually
;             preserves D2 (PUSH/POP across the _FATSetEntry call). Its
;             header had always claimed to preserve D2, but the body
;             didn't. Both call sites (_FATFreeChain here, and
;             _TruncateExisting in kos_fs_fd.asm) keep "next cluster"
;             in D2 across _FreeCluster. The leak caused the walk to
;             advance to garbage cluster numbers (byte offsets, not
;             cluster IDs), eventually hitting clusters ≥ 256 where
;             _FATGetEntry's FAT-sector calc lands on absolute sector
;             VOL_FAT_START + 1. On a minimum-size disk (sec_per_fat=1,
;             total=64 sectors) that's sector 2 — the FIRST DIR SECTOR.
;             _FATLoad then read dir-sector content into FS_BUF_FAT and
;             set FAT_CACHE_SECTOR=2; the next _FATFlush wrote (corrupted)
;             dir data BACK to sector 2, zeroing entry 0's first byte
;             and making ls see an empty directory after `load -f` or
;             any rm/unlink. Bug invisible on larger disks (D: 32480 cl)
;             because their FAT spans many sectors and the runaway walk
;             stays within FAT region. Diagnosed by adding a hex-dump in
;             emu_disk.pas's DoWrite which caught a write to lba=2 from
;             FS_BUF_FAT ($BE00) containing dirent data.
;
; Revision: r9 — 11 May 2026 — Part 25: added _FATFreeChain helper between
;             _FreeCluster and _ClusterToSector. Walks a FAT chain freeing
;             each cluster; used by sys_unlink (kos_fs_fd.asm). Does not
;             flush — caller batches the flush. Pattern lifted from the
;             existing walk inside _TruncateExisting (which is left as-is).
;
; Revision: r8 — 11 May 2026 — Part 24: _FormatVolume extended to format
;             host disks (C..F:) in addition to B:.
;             • Validate-drive section accepts FS_DRIVE_B..FS_DRIVE_F;
;               A: still rejected as ERR_READONLY.
;             • For B: keep the EMU/Digital RAM sizing constants and
;               historical root_entries=32.
;             • For C..F: query the disk sector count via CMD_IDENT on
;               the controller (new helper _HostQuerySize), then derive
;               sec_per_fat / data_start / root_entries via _ComputeFAT16Layout.
;             • root_entries rule (host disks only): 32 if total_sectors
;               ≤ 1024 (≤512 KB); 256 otherwise. Reflects "no subdirs yet"
;               reality — small disks fine with 32, larger ones shouldn't
;               cap files at 32. B: keeps 32 (Option b — see Part 24
;               session log for rationale).
;             • Slot pointer derived from drive index (drive << 6 +
;               VOL_TABLE_BASE) — same idiom as _TryMount.
;             • Sizing layout: sec_per_cluster=1, num_fats=1,
;               sec_per_fat = ceil(total_sectors/256). Pessimistic but
;               harmless and keeps the math 16-bit.
;             • Re-mount step uses the just-set drive index instead of
;               hardcoded FS_DRIVE_B (drive stashed at slot+$36).
;             • Slot+$38 used for root_entries scratch alongside the
;               existing $30..$35 transient sizing area.
;             • EMU-side counterpart: emu_disk.pas DoIdent (already
;               present, unchanged) returns Stream.Size div 512 in
;               DSK_SECCOUNT and updates DSK_FLAGS.
;
; Revision: r7 — 10 May 2026 — Part 22: _TryMount now scans the first root
;             directory sector for a VOLUME_ID entry (attr=$08) and
;             overrides the BPB-embedded label with that name if found.
;             Windows' format writes "NO NAME    " into the BPB and
;             puts the user-supplied label in a root-dir VOLUME_ID
;             entry; mtools/mformat does the same. Without the scan,
;             `vol` always reported "NO NAME" for any externally-formatted
;             disk regardless of what label the user typed during format.
;             Scan is limited to the first root sector (16 entries) —
;             VOLUME_ID is conventionally the first entry. Keeps the
;             BPB label as fallback if no VOLUME_ID is present (which
;             is the case for k/OS's own _FormatVolume output).
;
; Revision: r6 — 9 May 2026 — Part 22: _TryMount accepts NUM_FATS = 1 or 2.
;             k/OS's own _FormatVolume writes 1 FAT (no redundancy needed
;             for ROM/RAM disks); standard tools (Windows format, mtools
;             mformat) write 2. Previously _TryMount rejected anything
;             except NUM_FATS=1, which prevented mounting host-disk
;             images formatted by external tools. Now both are accepted;
;             root_start computation honours num_fats × sec_per_fat.
;             Writes still update only FAT #0 — FAT #1 silently drifts
;             on writeback. Read-only mount/access is fully correct.
;             Future work: either (a) extend _FormatVolume + write paths
;             to handle 2 FATs symmetrically, or (b) document that k/OS
;             treats the second FAT as permanently stale on imported
;             external images.
;
; Revision: r5 — 9 May 2026 — Part 22: install host-disk backend pointers
;             for slots C, D, E, F and call _TryMount on each. The host
;             backend is read-write (writeable bays), so both pointers
;             go in. Volume table zero-loop bumped from 96 words to 192
;             words to cover the expanded six-slot table.
;
; Revision: r4 — 8 May 2026 — Part 20a ABI audit fix.
;             sys_format now preserves D2 across the call per V2 ABI.
;             _FormatVolume's contract documents D2 as clobbered; without
;             a save/restore at the syscall boundary, callers that stash
;             state in D2 see it overwritten — same class of bug as the
;             sys_read/sys_write/sys_dirent fix that landed in
;             kos_fs_fd.asm r3 (cf. NEW_CHAT_CONTEXT 2026-05-08 r1).
;             D3 and XY2 are already preserved by _FormatVolume itself,
;             so only D2 needs guarding here. Save sequence mirrors the
;             canonical kos_fs_fd.asm pattern: PUSH D2 immediately after
;             DINT, POP D2 after the SR-gated EINT (POP doesn't disturb
;             flags, so the C-bit result survives).
;
; Revision: r3 — 7 May 2026 — Phase 19: sys_format syscall wrapper.
;             Thin DINT/CALLR/EINT-gate around _FormatVolume so user
;             tasks (including kosh) can format the writable volume
;             via a clean TRAP rather than CALL24'ing a kernel internal.
;             ABI matches _FormatVolume one-to-one:
;               In:    D0  = drive (FS_DRIVE_B = 1; A: rejected)
;                      XY0 = pointer to 11-byte space-padded label
;               Out:   C=0  on success
;                      C=1  with D0 = ERR_BADDRIVE / ERR_READONLY /
;                                     ERR_IO / ERR_INVALID
;
; Revision: r2 — 7 May 2026 — _TryMount now computes and caches
;             VOL_TOTAL_CLUSTERS at mount. Field was reserved in the
;             slot layout but never filled; kosh's `vol` command was
;             reading zero. Computation:
;               total_clusters = (total_sectors - data_start) / sec_per_cluster
;             Phase 16 volumes are <= 64K sectors so the low-word path
;             is sufficient; sec_per_cluster powers-of-2 (1/2/4/8) are
;             handled via SHR; values outside that set fall through with
;             unmodified data-sector count (acceptable for now — RAM and
;             ROM disks are 1 sec/cluster).
;
; Revision: r1 — 6 May 2026 — Piece 1: volume table init + mount probe.
;             Provides _InitFS (called once at boot from kos_boot.asm)
;             and _TryMount (per-volume probe + cache).
;
;             NOT in this revision: _FormatVolume, FAT walk, cluster
;             allocation, sys_format. Those land in Piece 2 and Piece 3.
;
; Purpose: Boot-time filesystem setup. Walks the volume table, calls each
;            slot's BlockRead to read sector 0, validates as FAT16, and
;            caches the BPB fields. After _InitFS returns, the volume
;            slots have present=1 for any successfully-mounted volume,
;            present=0 for slots that failed.
;
; Phase 16.1 expectation:
;   • A: probably fails (no real ROM image yet — Phase 17 sidequest).
;   • B: definitely fails on a fresh boot (RAM is garbage). Subsequent
;     boots after the user has run 'format' will succeed.
;   • C: always fails — slot is reserved but no backend is installed.
;
; --- Why _InitFS lives separate from kos_fs_ram/_rom -----------------------
;
; The block backends are pure data movers: sector→address, copy bytes.
; The mount logic is FS policy: validate format, cache fields, decide
; whether the volume is usable. Keeping them apart means a future SD
; backend just provides _BlockRead/_BlockWrite functions; _InitFS calls
; through to them via the same volume-table mechanism with no FS-side
; changes.
;
; --- Volume table layout (recap from kos_fs_defs.inc) ----------------------
;
; Slots at $0260, $02A0, $02E0 (64 bytes each, drives A: B: C:).
; Field offsets within slot:
;   $00  VOL_PRESENT          1 B   1 = mounted, 0 = empty
;   $01  VOL_READONLY         1 B   from BPB_KOS_FLAGS bit 0
;   $02  VOL_BYTES_PER_SECTOR 2 B   cached BPB
;   $04  VOL_SEC_PER_CLUSTER  2 B   (BPB byte zero-extended)
;   $06  VOL_RESERVED_SECTORS 2 B
;   $08  VOL_FAT_START        2 B   = reserved_sectors
;   $0A  VOL_SEC_PER_FAT      2 B
;   $0C  VOL_ROOT_START       2 B   = fat_start + num_fats * sec_per_fat
;   $0E  VOL_ROOT_ENTRIES     2 B
;   $10  VOL_DATA_START       2 B   = root_start + ceil(root_entries*32/512)
;   $12  VOL_TOTAL_SECTORS    4 B
;   $16  VOL_TOTAL_CLUSTERS   4 B   computed at mount
;   $1A  VOL_BLOCKREAD_PTR    4 B   24-bit address (0 = no backend)
;   $1E  VOL_BLOCKWRITE_PTR   4 B   24-bit address (0 = read-only volume)
;   $22  VOL_LABEL            11 B  cached
;
; ============================================================================


; ============================================================================
; _InitFS — boot-time filesystem initialisation
;
;   Called once from kos_boot.asm during _InitKernel, after the heap and
;   TCB pool are set up but before the scheduler is started.
;
;   1. Zero the volume table (all slots present=0).
;   2. Install backend function pointers per slot.
;   3. For each slot with a non-null _BlockRead, call _TryMount.
;
;   In:    (none)
;   Out:   (no return value; volume slots updated in place)
;   Clobbers: D0, D1, D2, XY0, XY1
; ============================================================================
_InitFS:
                ; --- Zero the volume table
                ; Volume table runs $0260..$03DF (384 bytes = 192 words,
                ; six 64-byte slots A..F).
                LOADI   Y1, #$00
                LOADI   X1, #VOL_TABLE_BASE
                LOADI   D2, #192                ; word count
                LOADI   D0, #0
.zero_loop:
                STORED  D0, [XY1]+
                SUB     D2, #1
                BNE     .zero_loop

                ; --- Default subdir-walk state to "root region" (0). The
                ; cluster-aware dir routines fall through to the original
                ; root-region path whenever DIR_WALK_CLU = 0; callers that
                ; walk a subdir set it, then restore 0.
                LOADI   D0, #0
                STOREZ  D0, [#DIR_WALK_CLU]

                ; --- Install backend function pointers
                ; Each pointer is stored as two 16-bit words:
                ;   [ptr+0]  high byte (page Y), zero-extended
                ;   [ptr+2]  16-bit offset (X)
                ; Read back later with two LOADZ + MOVE Y/X.
                ;
                ; Slot A (ROM disk): BlockRead = _BlockReadROM, no write.
                LOADI   D0, #>_BlockReadROM
                STOREZ  D0, [#VOL_SLOT_A + VOL_BLOCKREAD_PTR]
                LOADI   D0, #<_BlockReadROM
                STOREZ  D0, [#VOL_SLOT_A + VOL_BLOCKREAD_PTR + 2]
                ; (BlockWrite stays zero from the zero-loop above.)

                ; Slot B (RAM disk): BlockRead + BlockWrite.
                LOADI   D0, #>_BlockReadRAM
                STOREZ  D0, [#VOL_SLOT_B + VOL_BLOCKREAD_PTR]
                LOADI   D0, #<_BlockReadRAM
                STOREZ  D0, [#VOL_SLOT_B + VOL_BLOCKREAD_PTR + 2]
                LOADI   D0, #>_BlockWriteRAM
                STOREZ  D0, [#VOL_SLOT_B + VOL_BLOCKWRITE_PTR]
                LOADI   D0, #<_BlockWriteRAM
                STOREZ  D0, [#VOL_SLOT_B + VOL_BLOCKWRITE_PTR + 2]

                ; Slots C..F (host disk bays 0..3): BlockRead + BlockWrite.
                ; All four use the same backend; the bay number is derived
                ; from (drive - FS_DRIVE_C) inside the backend.
                LOADI   D0, #>_BlockReadHost
                STOREZ  D0, [#VOL_SLOT_C + VOL_BLOCKREAD_PTR]
                STOREZ  D0, [#VOL_SLOT_D + VOL_BLOCKREAD_PTR]
                STOREZ  D0, [#VOL_SLOT_E + VOL_BLOCKREAD_PTR]
                STOREZ  D0, [#VOL_SLOT_F + VOL_BLOCKREAD_PTR]
                LOADI   D0, #<_BlockReadHost
                STOREZ  D0, [#VOL_SLOT_C + VOL_BLOCKREAD_PTR + 2]
                STOREZ  D0, [#VOL_SLOT_D + VOL_BLOCKREAD_PTR + 2]
                STOREZ  D0, [#VOL_SLOT_E + VOL_BLOCKREAD_PTR + 2]
                STOREZ  D0, [#VOL_SLOT_F + VOL_BLOCKREAD_PTR + 2]

                LOADI   D0, #>_BlockWriteHost
                STOREZ  D0, [#VOL_SLOT_C + VOL_BLOCKWRITE_PTR]
                STOREZ  D0, [#VOL_SLOT_D + VOL_BLOCKWRITE_PTR]
                STOREZ  D0, [#VOL_SLOT_E + VOL_BLOCKWRITE_PTR]
                STOREZ  D0, [#VOL_SLOT_F + VOL_BLOCKWRITE_PTR]
                LOADI   D0, #<_BlockWriteHost
                STOREZ  D0, [#VOL_SLOT_C + VOL_BLOCKWRITE_PTR + 2]
                STOREZ  D0, [#VOL_SLOT_D + VOL_BLOCKWRITE_PTR + 2]
                STOREZ  D0, [#VOL_SLOT_E + VOL_BLOCKWRITE_PTR + 2]
                STOREZ  D0, [#VOL_SLOT_F + VOL_BLOCKWRITE_PTR + 2]

                ; --- Try to mount each populated slot
                ; First: invalidate the FAT cache so initial state is clean.
                CALLR   _FATInvalidate

                LOADI   D0, #FS_DRIVE_A
                CALLR   _TryMount

                LOADI   D0, #FS_DRIVE_B
                CALLR   _TryMount

                ; --- Auto-format B: if it didn't mount ---------------------
                ; Cold boot: the RAM disk is zeroed RAM with no BPB, so the
                ; mount above fails. Format it here (formatting re-mounts it)
                ; so B: is present BEFORE _SeedAssigns runs and RAM: seeds.
                ; Warm boot: already mounted -> skipped. Non-fatal on failure
                ; (B: stays unmounted). The _RawPuts trace is cleared by kosh's
                ; splash but survives on the raw terminal if kosh never paints.
                ; (Moved here from _P2Main so RAM-disk readiness is part of FS
                ; init and the boot seed works cold as well as warm.)
                LOADI   Y0, #$00
                LOADI   X0, #VOL_SLOT_B
                LOADB   D0, [XY0+#VOL_PRESENT]
                CMP     D0, #0
                BNE     .initfs_b_ready
                LOADI   Y0, #>boot_format_msg
                LOADI   X0, #<boot_format_msg
                CALL24  _RawPuts
                LOADI   D0, #FS_DRIVE_B
                LOADI   Y0, #>boot_ramdisk_label
                LOADI   X0, #<boot_ramdisk_label
                CALL24  _FormatVolume
                BCS     .initfs_b_fmterr
                LOADI   Y0, #>boot_format_ok
                LOADI   X0, #<boot_format_ok
                CALL24  _RawPuts
                BRA     .initfs_b_ready
.initfs_b_fmterr:
                LOADI   Y0, #>boot_format_err
                LOADI   X0, #<boot_format_err
                CALL24  _RawPuts
.initfs_b_ready:

                ; Host bays C..F: only probe on EMU. On Digital the disk
                ; controller doesn't exist; reads/writes to $DA0000 are
                ; undefined and could destabilise the bus. We still install
                ; the backend pointers above (cheap), but skip the probe
                ; so Digital boots cleanly with C..F all present=0.
                LOADZ   D0, [#KOS_HOST]
                LOW     D0
                CMP     D0, #HOST_EMU
                BNE     .skip_host_probe

                LOADI   D0, #FS_DRIVE_C
                CALLR   _TryMount

                LOADI   D0, #FS_DRIVE_D
                CALLR   _TryMount

                LOADI   D0, #FS_DRIVE_E
                CALLR   _TryMount

                LOADI   D0, #FS_DRIVE_F
                CALLR   _TryMount

.skip_host_probe:
                RET


; ============================================================================
; _TryMount — probe a single volume slot
;
;   1. Look up the slot's _BlockRead pointer; if null, fail.
;   2. Read sector 0 into FS_BUF_SECTOR.
;   3. Verify the boot signature ($AA55 at $1FE).
;   4. Verify the FAT16 type label ("FAT16   " at $36).
;   5. Cache BPB fields into the slot.
;   6. Set VOL_PRESENT = 1.
;
;   In:    D0  = drive index (0..2)
;   Out:   C=0  on success, slot's VOL_PRESENT now 1
;          C=1  on failure, slot's VOL_PRESENT stays 0
;            D0 = ERR_BADDRIVE  no backend installed in this slot
;            D0 = ERR_IO        BlockRead failed
;            D0 = ERR_INVALID   bad signature or wrong FS type
;   Clobbers: D0, D1, D2, XY0, XY1
;
; Slot base address calc:
;   slot_base = VOL_TABLE_BASE + drive * VOL_SLOT_SIZE
;             = $0260 + drive * 64
;             = $0260 + (drive << 6)
;
; ============================================================================
_TryMount:
                ; Stash drive index for later — D3 is callee-saved per the
                ; ABI but we touch it only here, push to be safe.
                PUSH    D3, XY3

                ; Part 22: _TryMount reads sector 0 (BPB) into FS_BUF_SECTOR;
                ; any prior dir-cache claim is stale.
                LOADI   D3, #FAT_CACHE_INVALID
                STOREZ  D3, [#DIR_CACHE_SECTOR]

                ; --- Compute slot base offset (in page $00) -------------
                ; D3 = drive (saved across BlockRead call)
                MOVE    D3, D0

                ; D1 = drive << 6 = drive * 64
                MOVE    D1, D0
                SHL4    D1                      ; D1 = drive * 16
                SHL     D1                      ; D1 = drive * 32
                SHL     D1                      ; D1 = drive * 64
                ADD     D1, #VOL_TABLE_BASE     ; D1 = slot offset in page $00

                ; XY1 = pointer to slot ($00 : slot_offset). Keep this
                ; live across the BlockRead call — XY1 is in our preserve
                ; list and BlockRead clobbers only XY0/XY1's *contents
                ; being changed*... wait: _BlockReadRAM clobbers X1 (it's
                ; used as the source pointer in the loop). We need the
                ; slot pointer somewhere safe.
                ;
                ; Use XY2 for the slot pointer (callee-saved; nothing
                ; in this function or below clobbers it).
                LOADI   Y2, #$00
                MOVE    X2, D1                  ; XY2 = slot base

                ; --- Look up BlockRead pointer in slot ------------------
                ; slot+$1A = page byte (low 8 bits of word at +$1A)
                ; slot+$1C = X (16-bit offset, word at +$1C)
                ; If both bytes of the function pointer are zero, slot
                ; has no backend.
                LOADD   D0, [XY2+#VOL_BLOCKREAD_PTR]   ; D0 = page word
                LOADD   D1, [XY2+#VOL_BLOCKREAD_PTR+2] ; D1 = offset word
                ; OR them — if both zero, no backend.
                MOVE    D2, D0
                OR      D2, D1
                BEQ     .no_backend

                ; --- Set up BlockRead call -----------------------------
                ; BlockRead(D0=sector, XY0=buffer)
                ; Sector 0, buffer = $00:FS_BUF_SECTOR.
                ; The function we're calling lives at (Y=lo(D0), X=D1).
                ;
                ; Use XY1 for the call target (CALLXY XYn).
                MOVE    Y1, D0                  ; Y1 = backend page byte
                MOVE    X1, D1                  ; X1 = backend offset

                LOADI   Y0, #$00                ; XY0 = buffer (in page $00)
                LOADI   X0, #FS_BUF_SECTOR
                LOADI   D0, #0                  ; sector 0
                CALLXY  XY1
                BCS     .io_err

                ; --- Validate boot signature at offset $1FE ------------
                LOADZ   D0, [#FS_BUF_SECTOR + BPB_SIGNATURE]
                CMP     D0, #FS_BOOT_SIG
                BNE     .bad_format

                ; --- Validate FS type label "FAT16   " ($46 41 54 31 36 20 20 20) ---
                ; Compare 8 bytes word-wise: 4 word compares.
                LOADZ   D0, [#FS_BUF_SECTOR + BPB_FS_TYPE]
                CMP     D0, #$4146                  ; "FA" little-endian: 'A'<<8|'F'
                BNE     .bad_format
                LOADZ   D0, [#FS_BUF_SECTOR + BPB_FS_TYPE + 2]
                CMP     D0, #$3154                  ; "T1" : '1'<<8|'T'
                BNE     .bad_format
                LOADZ   D0, [#FS_BUF_SECTOR + BPB_FS_TYPE + 4]
                CMP     D0, #$2036                  ; "6 " : ' '<<8|'6'
                BNE     .bad_format
                LOADZ   D0, [#FS_BUF_SECTOR + BPB_FS_TYPE + 6]
                CMP     D0, #$2020                  ; "  "
                BNE     .bad_format

                ; --- Cache BPB fields into slot ------------------------
                ; bytes_per_sector — at BPB offset $0B (odd). Read as two
                ; bytes and combine to avoid unaligned word access.
                LOADZB  D0, [#FS_BUF_SECTOR + BPB_BYTES_PER_SECTOR]
                LOADZB  D1, [#FS_BUF_SECTOR + BPB_BYTES_PER_SECTOR + 1]
                SWAPB   D1                      ; D1 = high byte << 8
                OR      D0, D1                  ; D0 = combined word
                STORED  D0, [XY2+#VOL_BYTES_PER_SECTOR]

                ; sec_per_cluster (byte field, BPB offset $0D)
                LOADZB  D0, [#FS_BUF_SECTOR + BPB_SEC_PER_CLUSTER]
                STORED  D0, [XY2+#VOL_SEC_PER_CLUSTER]

                ; reserved_sectors
                LOADZ   D0, [#FS_BUF_SECTOR + BPB_RESERVED_SECTORS]
                STORED  D0, [XY2+#VOL_RESERVED_SECTORS]
                ; FAT_START = reserved_sectors (just under FAT16 conventions
                ; with reserved_sectors = 1, FAT starts at sector 1).
                STORED  D0, [XY2+#VOL_FAT_START]

                ; sec_per_fat
                LOADZ   D0, [#FS_BUF_SECTOR + BPB_SEC_PER_FAT]
                STORED  D0, [XY2+#VOL_SEC_PER_FAT]

                ; root_entries — at BPB offset $11 (odd).
                LOADZB  D0, [#FS_BUF_SECTOR + BPB_ROOT_ENTRIES]
                LOADZB  D1, [#FS_BUF_SECTOR + BPB_ROOT_ENTRIES + 1]
                SWAPB   D1
                OR      D1, D0                  ; D1 = combined (D1 used downstream)
                STORED  D1, [XY2+#VOL_ROOT_ENTRIES]

                ; Compute root_start = fat_start + num_fats * sec_per_fat.
                ; num_fats is a byte at BPB+$10. k/OS's own _FormatVolume
                ; writes 1 FAT (we don't use the redundant copy). Standard
                ; tools (Windows format, mtools mformat) write 2 FATs.
                ; Accept both — for now, on writes we only update FAT #0;
                ; FAT #1 will silently drift. Read-only mount is fine.
                ; If NUM_FATS is something else (0, 3+), reject as malformed.
                LOADZB  D2, [#FS_BUF_SECTOR + BPB_NUM_FATS]
                CMP     D2, #0
                BEQ     .bad_format
                CMP     D2, #3
                BHS     .bad_format

                ; Compute num_fats * sec_per_fat — D2 holds num_fats (1 or 2).
                LOADD   D0, [XY2+#VOL_SEC_PER_FAT]
                CMP     D2, #1
                BEQ     .nf_one
                ; num_fats = 2: D0 *= 2 via single shift
                SHL     D0
.nf_one:
                LOADD   D2, [XY2+#VOL_FAT_START]
                ADD     D0, D2                  ; D0 = root_start
                STORED  D0, [XY2+#VOL_ROOT_START]

                ; data_start = root_start + ceil(root_entries * 32 / 512)
                ;            = root_start + (root_entries + 15) >> 4
                ; (since 32/512 = 1/16, and we round up)
                ; D1 still holds root_entries from above.
                ADD     D1, #15
                SHR4    D1                      ; D1 = (root_entries+15) / 16
                ADD     D0, D1                  ; D0 = data_start
                STORED  D0, [XY2+#VOL_DATA_START]

                ; total_sectors: prefer 16-bit field; if zero use 32-bit.
                ; BPB_TOTAL_SECTORS_16 is at $13 (odd). The 32-bit field
                ; at $20 is even and uses ordinary word loads.
                LOADZB  D0, [#FS_BUF_SECTOR + BPB_TOTAL_SECTORS_16]
                LOADZB  D1, [#FS_BUF_SECTOR + BPB_TOTAL_SECTORS_16 + 1]
                SWAPB   D1
                OR      D0, D1                  ; D0 = total_sectors_16
                CMP     D0, #0
                BNE     .have_total
                ; 32-bit field
                LOADZ   D0, [#FS_BUF_SECTOR + BPB_TOTAL_SECTORS_32]
                LOADZ   D1, [#FS_BUF_SECTOR + BPB_TOTAL_SECTORS_32 + 2]
                STORED  D0, [XY2+#VOL_TOTAL_SECTORS]
                STORED  D1, [XY2+#VOL_TOTAL_SECTORS+2]
                BRA.S   .total_done
.have_total:
                STORED  D0, [XY2+#VOL_TOTAL_SECTORS]
                LOADI   D1, #0
                STORED  D1, [XY2+#VOL_TOTAL_SECTORS+2]
.total_done:

                ; --- Compute VOL_TOTAL_CLUSTERS -----------------------------
                ; total_clusters = (total_sectors - data_start) / sec_per_cluster
                ;
                ; Phase 16 volumes are <= 64K sectors so the low-word path
                ; is sufficient. If total_sectors high word is non-zero,
                ; the volume is larger than we support — store $FFFF as a
                ; sentinel rather than corrupting downstream math.
                LOADD   D1, [XY2+#VOL_TOTAL_SECTORS+2]  ; high word
                CMP     D1, #0
                BNE     .clusters_too_big

                LOADD   D0, [XY2+#VOL_TOTAL_SECTORS]    ; low word = total sectors
                LOADD   D1, [XY2+#VOL_DATA_START]
                SUB     D0, D1                          ; D0 = data sectors
                ; Divide by sec_per_cluster.
                LOADD   D1, [XY2+#VOL_SEC_PER_CLUSTER]
                CMP     D1, #1
                BEQ     .clusters_done                  ; common case: 1 sec/cluster
                CMP     D1, #2
                BEQ     .clusters_div2
                CMP     D1, #4
                BEQ     .clusters_div4
                CMP     D1, #8
                BEQ     .clusters_div8
                ; Unsupported sec_per_cluster — store as-is and move on.
                BRA     .clusters_done
.clusters_div2:
                SHR     D0
                BRA     .clusters_done
.clusters_div4:
                SHR     D0
                SHR     D0
                BRA     .clusters_done
.clusters_div8:
                SHR     D0
                SHR     D0
                SHR     D0
                BRA     .clusters_done
.clusters_too_big:
                LOADI   D0, #$FFFF
.clusters_done:
                STORED  D0, [XY2+#VOL_TOTAL_CLUSTERS]
                LOADI   D1, #0
                STORED  D1, [XY2+#VOL_TOTAL_CLUSTERS+2]

                ; Free-cluster cache starts stale; first sys_diskfree walks
                ; and populates it. (D1 still = 0 here.) Offset > IMM5, so
                ; use mode-01 D-indexed access (D0 free after the store above).
                LOADI   D0, #VOL_FREE_VALID
                STORED  D1, [XY2+D0]            ; VOL_FREE_VALID := 0

                ; Cache k/OS read-only flag (BPB byte at $25).
                LOADZB  D0, [#FS_BUF_SECTOR + BPB_KOS_FLAGS]
                AND     D0, #BPB_KOS_RDONLY
                STOREB  D0, [XY2+#VOL_READONLY]

                ; --- Cache 11-byte volume label ------------------------
                ; VOL_LABEL = $22 exceeds IMM5 range (0..31), so use a
                ; D-register-indexed LEA (mode 01) for the destination.
                LOADI   Y0, #$00
                LOADI   X0, #FS_BUF_SECTOR + BPB_VOLUME_LABEL
                LOADI   D1, #VOL_LABEL
                LEA     XY1, XY2+D1             ; XY1 = slot + VOL_LABEL
                LOADI   D2, #11
.label_loop:
                LOADB   D0, [XY0]+
                STOREB  D0, [XY1]+
                SUB     D2, #1
                BNE     .label_loop

                ; --- Override label from root-dir VOLUME_ID if present --
                ; Windows' format writes "NO NAME    " into the BPB-embedded
                ; label and puts the user-supplied label in a directory
                ; entry at the start of the root with attr=$08
                ; (DIR_ATTR_VOLUME_LABEL, NOT $0F LFN). Scan the first root
                ; sector for that entry and, if found, replace VOL_LABEL.
                ;
                ; Read the first root-dir sector into FS_BUF_SECTOR.
                ; (FS_BUF_SECTOR currently holds the BPB; that data is no
                ; longer needed — we cached everything we wanted.)
                LOADD   D0, [XY2+#VOL_ROOT_START]
                LOADI   Y0, #$00
                LOADI   X0, #FS_BUF_SECTOR
                CALLR   _VolBlockRead
                BCS     .label_scan_done        ; IO err — keep BPB label

                ; Walk 16 entries × 32 bytes each.
                LOADI   D2, #0                  ; ent_idx
.label_scan_loop:
                ; entry_addr = FS_BUF_SECTOR + ent_idx * 32
                MOVE    D0, D2
                SHL4    D0
                SHL     D0
                ADD     D0, #FS_BUF_SECTOR
                LOADI   Y0, #$00
                MOVE    X0, D0                  ; XY0 = entry

                ; First byte: $00 = end-of-dir, $E5 = deleted/skip.
                LOADB   D1, [XY0]
                AND     D1, #$FF
                CMP     D1, #0
                BEQ     .label_scan_done        ; end of dir, no label found
                CMP     D1, #$E5
                BEQ     .label_scan_next        ; deleted, skip

                ; Attr byte at offset $0B.
                ADD     X0, #11
                LOADB   D1, [XY0]
                AND     D1, #$FF
                ; LFN entries (attr=$0F) sometimes look like volume label;
                ; skip them.
                CMP     D1, #DIR_ATTR_LFN
                BEQ     .label_scan_next
                ; Volume-label entries have bit 3 set. Mask & test.
                AND     D1, #DIR_ATTR_VOLUME_LABEL
                BEQ     .label_scan_next        ; not a volume label

                ; Found it. Copy 11 bytes from entry+0 to slot+VOL_LABEL.
                ; XY0 currently points at entry+11 (the attr we just read);
                ; back up to entry+0.
                MOVE    D0, D2
                SHL4    D0
                SHL     D0
                ADD     D0, #FS_BUF_SECTOR
                LOADI   Y0, #$00
                MOVE    X0, D0                  ; XY0 = entry+0

                LOADI   D1, #VOL_LABEL
                LEA     XY1, XY2+D1             ; XY1 = slot + VOL_LABEL
                LOADI   D2, #11
.label_copy_loop:
                LOADB   D0, [XY0]+
                STOREB  D0, [XY1]+
                SUB     D2, #1
                BNE     .label_copy_loop
                BRA     .label_scan_done

.label_scan_next:
                ADD     D2, #1
                CMP     D2, #16
                BLO     .label_scan_loop
                ; Walked all 16 entries in the first root sector without
                ; finding a volume label. We don't scan further sectors —
                ; VOLUME_ID, if present, is conventionally the very first
                ; entry. Keep the BPB-embedded label.

.label_scan_done:
                ; --- All checks passed: mark present -------------------
                LOADI   D0, #1
                STOREB  D0, [XY2+#VOL_PRESENT]

                LOADI   D0, #ERR_OK
                CLC
                BRA.S   .done

.no_backend:
                LOADI   D0, #ERR_BADDRIVE
                SEC
                BRA.S   .done

.io_err:
                LOADI   D0, #ERR_IO
                SEC
                BRA.S   .done

.bad_format:
                LOADI   D0, #ERR_INVALID
                SEC
                ; fall through

.done:
                POP     D3, XY3
                RET

; ============================================================================
; Piece 2: _VolBlockRead, _VolBlockWrite, _ZeroBuffer, _FormatVolume
; ============================================================================
; Revision: r2 — 6 May 2026 — Piece 2 added.
;
; New helpers:
;   _VolBlockRead   — call slot's BlockRead via function pointer
;   _VolBlockWrite  — call slot's BlockWrite via function pointer
;   _ZeroBuffer     — zero FS_BUF_SECTOR (used pre-write)
;
; New routine:
;   _FormatVolume   — write a fresh FAT16 image to drive B:
;
; ============================================================================


; ============================================================================
; _VolBlockRead — call a slot's BlockRead through its function pointer
;
;   In:    D0  = sector number
;          XY0 = destination buffer
;          XY2 = pointer to volume slot ($00:slot_offset)
;   Out:   C=0 on success, C=1 with D0=ERR_IO on failure
;          C=1 with D0=ERR_BADDRIVE if slot has no BlockRead
;   Clobbers: D0, D1, D2, X0, X1, flags
;   Preserves: D3, Y0, Y1 (after the call), XY2, XY3
; ============================================================================
_VolBlockRead:
                ; Load function pointer halves from the slot.
                LOADD   D1, [XY2+#VOL_BLOCKREAD_PTR]      ; D1 = page word
                LOADD   D2, [XY2+#VOL_BLOCKREAD_PTR+2]    ; D2 = X word

                ; Null-pointer check. ALU instructions accept D/X/Y as
                ; either source or destination (per K16_Encoder_ALU.pas
                ; line 51 — "destination must be D0-D3, X0-X3, or Y0-Y3").
                ; Use X1 as scratch for the OR, since it's clobber-listed.
                ; D0 (sector) stays untouched throughout.
                MOVE    X1, D1
                OR      X1, D2
                BEQ     .vbr_no_backend

                ; Set up indirect call target in XY1.
                MOVE    Y1, D1                  ; Y1 = backend page byte
                MOVE    X1, D2                  ; X1 = backend offset
                CALLXY  XY1
                RET

.vbr_no_backend:
                LOADI   D0, #ERR_BADDRIVE
                RETCS


; ============================================================================
; _VolBlockWrite — call a slot's BlockWrite through its function pointer
;
;   Same shape as _VolBlockRead but invokes the BlockWrite handler.
;   A null write pointer yields ERR_READONLY (volume is r/o).
;
;   In:    D0  = sector number
;          XY0 = source buffer
;          XY2 = pointer to volume slot
;   Out:   C=0 on success, C=1 with D0=ERR_IO on failure
;          C=1 with D0=ERR_READONLY if slot is read-only
;   Clobbers: D0, D1, D2, X0, X1, flags
; ============================================================================
_VolBlockWrite:
                ; VOL_BLOCKWRITE_PTR+2 = $20 = 32, just over IMM5 range.
                ; Use mode 01 [XY+D] for the second half of the pointer.
                LOADD   D1, [XY2+#VOL_BLOCKWRITE_PTR]
                LOADI   D2, #VOL_BLOCKWRITE_PTR+2
                LOADD   D2, [XY2+D2]            ; D2 = X word
                MOVE    X1, D1
                OR      X1, D2
                BEQ     .vbw_readonly

                MOVE    Y1, D1
                MOVE    X1, D2
                CALLXY  XY1
                RET

.vbw_readonly:
                LOADI   D0, #ERR_READONLY
                RETCS


; ============================================================================
; _ZeroBuffer — zero FS_BUF_SECTOR (256 words / 512 bytes)
;
;   In:    (none)
;   Out:   FS_BUF_SECTOR contents = 0
;          C cleared
;   Clobbers: D0, D1, X0, flags
;   Preserves: Y0, Y1, XY2, XY3, D2, D3
; ============================================================================
_ZeroBuffer:
                LOADI   Y0, #$00
                LOADI   X0, #FS_BUF_SECTOR
                LOADI   D0, #0
                LOADI   D1, #256                ; word count
.zb_loop:
                STORED  D0, [XY0]+
                SUB     D1, #1
                BNE     .zb_loop
                RETCC


; ============================================================================
; _HostQuerySize — Part 24 — ask the disk controller for a bay's sector count
;
;   Issues CMD_IDENT on the controller. The EMU services this by setting
;   DSK_SECCOUNT to (Stream.Size div 512) — capped at $FFFF — and updating
;   DSK_FLAGS (presence + RO bits). Bays without a stream attached return
;   RES_NO_MEDIA with SECCOUNT = 0.
;
;   Caller is responsible for taking the disk-mutex semaphore. In practice
;   _FormatVolume runs with DINT in effect across the whole syscall (kernel
;   single-context), so contention is impossible today.
;
;   In:    D0  = drive (FS_DRIVE_C..FS_DRIVE_F = 2..5)
;   Out:   C=0 success, D0 = total_sectors (low 16 bits — limit 65535)
;          C=1 failure, D0 = ERR_IO (no media or bad bay)
;   Clobbers: D0, D1, D2, X0, X1, Y0, Y1, flags
;   Preserves: D3, XY2, XY3
;
;   Notes:
;     • Reads DSK_SECCOUNT, not DSK_LBA_LO — matches the long-standing EMU
;       DoIdent contract (size returned in SECCOUNT; FLAGS bit 0 = present).
;     • Doesn't take the host-disk semaphore — _FormatVolume runs DINT,
;       so contention is impossible. If/when the kernel preempts during
;       syscalls (Phase 4+), wrap the body in _SemTakeBlocking/_SemGive.
; ============================================================================
_HostQuerySize:
                ; Digital has no disk controller — fail fast.
                ; (k/OS would otherwise read garbage from $DA0010 and
                ; possibly see RES_OK by chance.)
                LOADZ   D1, [#KOS_HOST]
                LOW     D1
                CMP     D1, #HOST_EMU
                BNE     .hqs_io_err

                ; D0 = drive (2..5). Compute bay = drive - FS_DRIVE_C.
                SUB     D0, #FS_DRIVE_C         ; D0 = bay (0..3)

                ; Program the controller. XY1 = $DA:0000.
                LOADI   Y1, #DSK_PAGE

                ; DSK_DRIVE := bay
                LOADI   X1, #DSK_DRIVE
                STORED  D0, [XY1]

                ; DSK_CMD := CMD_IDENT  (triggers, services synchronously)
                LOADI   D2, #CMD_IDENT
                LOADI   X1, #DSK_CMD
                STORED  D2, [XY1]

                ; Read DSK_RESULT.
                LOADI   X1, #DSK_RESULT
                LOADD   D2, [XY1]
                CMP     D2, #RES_OK
                BNE.S   .hqs_io_err

                ; Success. Read DSK_SECCOUNT into D0.
                LOADI   X1, #DSK_SECCOUNT
                LOADD   D0, [XY1]
                RETCC

.hqs_io_err:
                LOADI   D0, #ERR_IO
                RETCS


; ============================================================================
; _ComputeFAT16Layout — Part 24 — derive FAT16 layout from sector count
;
;   Picks a small but workable FAT16 layout for the given total sector
;   count. Matches what _FormatVolume's RAM-disk path produces:
;
;     bytes_per_sector  = 512   (k/OS invariant)
;     sec_per_cluster   = 1     (always — k/OS sector numbers are 16-bit
;                                so disks ≤ 32 MB; cluster=1 is fine)
;     reserved_sectors  = 1     (the boot sector)
;     num_fats          = 1     (k/OS convention)
;     root_entries      = 32 if total_sectors ≤ 1024 (≤512 KB);
;                         256 otherwise.
;                         Root sectors = root_entries × 32 / 512
;                         (= 2 or 16). The threshold reflects the
;                         "no subdirectories yet" reality: small disks
;                         don't need 256-entry roots, large disks
;                         shouldn't be capped at 32 files.
;     sec_per_fat       = ceil(total_sectors × 2 / 512)
;                       = ceil(total_sectors / 256)
;                       = (total_sectors + 255) >> 8
;     data_start        = 1 + sec_per_fat + root_sectors
;
;   The sec_per_fat formula is pessimistic — it assumes every sector on
;   the disk is a cluster, but boot/FAT/root sectors aren't clusters.
;   The cost is a few unused FAT entries in the last FAT sector. The
;   benefit is no iteration: one ADD + one shift gives the answer in
;   word arithmetic.
;
;   Minimum disk size: 1 (boot) + 1 (FAT minimum) + 2 (root) + 1 (data)
;                    = 5 sectors. Anything ≤ 4 returns ERR_INVALID.
;
;   In:    D0  = total_sectors (1..65535)
;          XY2 = volume slot ptr (used to write root_entries to slot+$38)
;   Out:   C=0 success
;            D1 = total_sectors (echoed)
;            D2 = sec_per_fat
;            D0 = data_start
;            (slot+$38 = root_entries — 32 or 256 — written here)
;          C=1 failure
;            D0 = ERR_INVALID  (disk too small for FAT16 with our layout)
;   Clobbers: D0, D1, D2, X1, Y1, flags
;   Preserves: D3, XY0, XY2, XY3
; ============================================================================
_ComputeFAT16Layout:
                ; Reject tiny disks.
                CMP     D0, #5
                BLO     .cfl_too_small

                ; Reject disks where (total+255) would overflow 16 bits.
                ; sec_per_fat math wraps if total_sectors > 65280. With
                ; sector numbers being 16-bit anyway this is ~32 MB; we
                ; just refuse those edge sizes for cleanliness.
                ; Want "total > 65280" → "total >= 65281".
                LOADI   D1, #65281
                CMP     D0, D1
                BHS     .cfl_too_small

                ; D1 = total_sectors (echo for caller)
                MOVE    D1, D0

                ; --- Pick root_entries by size -----------------------------
                ; ≤ 1024 sectors (≤512 KB) → 32; otherwise 256.
                ; Stash to slot+$38 immediately so we don't need another
                ; register live across the rest of the routine.
                LOADI   D2, #$38
                LEA     XY1, XY2+D2             ; XY1 = slot + $38
                ; BHI not implemented in assembler — synthesise via
                ; CMP against (threshold+1) + BHS. Want "> 1024", which
                ; equals ">= 1025".
                CMP     D1, #1025
                BHS.S   .cfl_big_root
                LOADI   D2, #32
                BRA.S   .cfl_root_done
.cfl_big_root:
                LOADI   D2, #256
.cfl_root_done:
                STORED  D2, [XY1]               ; slot+$38 = root_entries

                ; root_sectors = root_entries / 16  (16 entries per sector)
                ; D2 currently = root_entries (32 or 256). Shift right 4.
                SHR4    D2                      ; D2 = root_sectors (2 or 16)

                ; D0 = root_sectors (saved across the FAT calc)
                MOVE    D0, D2

                ; --- sec_per_fat = (total_sectors + 255) >> 8 --------------
                MOVE    D2, D1                  ; D2 = total_sectors
                ADD     D2, #255
                SWAPB   D2                      ; high-byte → low-byte
                LOW     D2                      ; mask off original low byte

                ; If sec_per_fat ended up zero (would only happen for
                ; a 1-sector disk, but we already rejected those), bump
                ; to 1 — defensive.
                CMP     D2, #0
                BNE.S   .cfl_have_fat
                LOADI   D2, #1
.cfl_have_fat:

                ; --- data_start = 1 + sec_per_fat + root_sectors ----------
                ; D0 = root_sectors, D2 = sec_per_fat.
                ADD     D0, D2                  ; D0 = sec_per_fat + root_sectors
                ADD     D0, #1                  ; D0 = data_start

                ; Sanity: data_start must be < total_sectors so there's
                ; at least one data cluster.
                CMP     D0, D1
                BHS     .cfl_too_small

                RETCC

.cfl_too_small:
                LOADI   D0, #ERR_INVALID
                RETCS


; ============================================================================
; _FormatVolume — write a fresh FAT16 image to a writable drive
;
;   1. Validate drive (B: or C..F:; A: rejects).
;   2. Pick sizing:
;      • B:  use EMU_RAM_* / DIG_RAM_* constants per host.
;      • C..F: query controller via CMD_IDENT for sector count;
;             derive sec_per_fat and data_start via _ComputeFAT16Layout.
;   3. Compute slot pointer from drive index.
;   4. Zero FS_BUF_SECTOR; build boot sector in it; write to sector 0.
;   5. Zero buffer; install FAT sentinels; write to sector 1.
;   6. Write zero-filled buffer to sectors 2..(data_start - 1)
;      (this clears the rest of the FAT and the root directory).
;   7. Re-mount the volume to refresh the slot.
;
;   In:    D0  = drive (FS_DRIVE_B = 1, or FS_DRIVE_C..F = 2..5)
;          XY0 = pointer to 11-byte volume label (space-padded)
;   Out:   C=0 on success, slot now mounted with new format
;          C=1 on failure
;            D0 = ERR_BADDRIVE  drive index out of range
;            D0 = ERR_READONLY  attempting to format A:
;            D0 = ERR_IO        block-write failed mid-format, or
;                               CMD_IDENT failed (no media in bay)
;            D0 = ERR_INVALID   re-mount failed (bug — internal inconsistency)
;   Clobbers: D0, D1, D2, XY0, XY1, flags
;
; ============================================================================
_FormatVolume:
                PUSH    D3, XY3
                PUSH    XY2, XY3

                ; Part 22: format writes BPB / FAT / dir sectors through
                ; FS_BUF_SECTOR; any prior dir-cache identity is stale.
                LOADI   D3, #FAT_CACHE_INVALID
                STOREZ  D3, [#DIR_CACHE_SECTOR]

                ; --- Validate drive (Part 24: B + C..F accepted) ---------
                ; A: → ERR_READONLY (ROM disk).
                ; B..F (1..5) → OK.
                ; ≥6 → ERR_BADDRIVE.
                CMP     D0, #FS_DRIVE_A
                BEQ     .fv_readonly
                CMP     D0, #FS_MAX_DRIVES
                BHS     .fv_baddrive
                ; D0 ∈ 1..5 — fall through.

.fv_drive_ok:
                ; Stash drive index in D3 (saved across calls below).
                MOVE    D3, D0

                PUSH    XY0, XY3                ; save caller's label ptr

                ; --- Compute slot pointer from drive (Part 24) ----------
                ; slot = VOL_TABLE_BASE + drive × 64
                MOVE    D1, D0
                SHL4    D1                      ; D1 = drive × 16
                SHL     D1                      ; D1 = drive × 32
                SHL     D1                      ; D1 = drive × 64
                ADD     D1, #VOL_TABLE_BASE     ; D1 = slot offset in page $00
                LOADI   Y2, #$00
                MOVE    X2, D1                  ; XY2 = slot ptr

                ; --- Pick sizing (Part 24) -------------------------------
                ; Branch on drive: B uses constants, C..F query controller.
                CMP     D3, #FS_DRIVE_B
                BNE     .fv_size_host

                ; B: — use EMU_RAM_* or DIG_RAM_* per host.
                LOADI   D1, #EMU_RAM_TOTAL_SECTORS
                LOADI   D2, #EMU_RAM_FAT_SECTORS
                LOADI   D0, #EMU_RAM_DATA_START

                LOADZ   D3, [#KOS_HOST]
                LOW     D3
                CMP     D3, #HOST_DIGITAL
                BNE.S   .fv_have_sizing_b
                LOADI   D1, #DIG_RAM_TOTAL_SECTORS
                LOADI   D2, #DIG_RAM_FAT_SECTORS
                LOADI   D0, #DIG_RAM_DATA_START

.fv_have_sizing_b:
                ; Restore D3 = drive (we clobbered it reading KOS_HOST).
                LOADI   D3, #FS_DRIVE_B
                ; B: keeps the historical 32-entry root regardless of
                ; size. Stash it to slot+$38 so the BPB-build code (which
                ; now reads root_entries from there) finds the right value.
                ; The host path's _ComputeFAT16Layout already writes its
                ; own choice of root_entries to slot+$38.
                PUSH    D0, XY3                 ; save data_start
                PUSH    D1, XY3                 ; save total_sectors
                LOADI   D0, #$38
                LEA     XY1, XY2+D0
                LOADI   D1, #32
                STORED  D1, [XY1]               ; slot+$38 = 32
                POP     D1, XY3
                POP     D0, XY3
                BRA     .fv_have_sizing

.fv_size_host:
                ; C..F: ask the controller for the bay's sector count.
                ; _HostQuerySize: in D0 = drive (2..5); out D0 = total_sectors,
                ; C=0 on success or C=1 with D0=ERR_IO if the bay is empty.
                ; _HostQuerySize preserves D3 and XY2.
                MOVE    D0, D3                  ; D0 = drive
                CALLR   _HostQuerySize
                BCS     .fv_pop_xy0_io          ; ERR_IO already in D0

                ; D0 = total_sectors. Compute layout.
                ; _ComputeFAT16Layout: in D0 = total_sectors; out
                ; D1 = total, D2 = sec_per_fat, D0 = data_start. C=0
                ; on success or C=1 with D0=ERR_INVALID if too small.
                ; Preserves D3 and XY2.
                CALLR   _ComputeFAT16Layout
                BCS     .fv_pop_xy0_baddrv      ; treat tiny disk as bad

                BRA     .fv_have_sizing

; --- Early-error trampolines that drop the saved XY0 (label ptr) -----------
; Reached when a sizing helper fails AFTER `PUSH XY0` but BEFORE the
; label-copy loop consumes it. We can't fall through to `.fv_io_err` /
; `.fv_baddrive` directly because their only pops are XY2/D3 — they
; would leak the saved XY0.
.fv_pop_xy0_io:
                POP     XY0, XY3                ; drop saved label ptr
                LOADI   D0, #ERR_IO
                SEC
                BRA     .fv_done

.fv_pop_xy0_baddrv:
                POP     XY0, XY3                ; drop saved label ptr
                LOADI   D0, #ERR_BADDRIVE
                SEC
                BRA     .fv_done

.fv_have_sizing:
                ; D1 = total_sectors, D2 = sec_per_fat, D0 = data_start.
                ; Stash sizes in the slot's reserved area at offset $30..$36
                ; so they survive _ZeroBuffer and other helper calls that
                ; clobber D1/D2/D3. The mount pass at the end of this
                ; routine overwrites the reserved area with cached BPB,
                ; so this is purely transient scratch.
                ;
                ; Slot+$30 = total_sectors
                ; Slot+$32 = sec_per_fat
                ; Slot+$34 = data_start
                ; Slot+$36 = drive index (Part 24 — needed for remount)
                ;
                ; Mode 01 LEA because offsets ≥32 exceed the IMM5 limit.
                PUSH    D0, XY3                 ; save data_start
                LOADI   D0, #$30
                LEA     XY1, XY2+D0             ; XY1 = slot + $30
                STORED  D1, [XY1+#0]            ; total_sectors
                STORED  D2, [XY1+#2]            ; sec_per_fat
                POP     D0, XY3                 ; D0 = data_start
                STORED  D0, [XY1+#4]            ; data_start
                STORED  D3, [XY1+#6]            ; drive index (Part 24)

                ; --- Build boot sector ----------------------------------
                CALLR   _ZeroBuffer

                ; Jump instruction "EB 3C 90" (JMP +60 ; NOP) — non-bootable
                ; sentinel pattern. 3 bytes at offsets $00..$02.
                LOADI   D0, #$3CEB              ; bytes EB at $00, 3C at $01
                STOREZ  D0, [#FS_BUF_SECTOR + BPB_JUMP]
                LOADI   D0, #$90                ; byte 90 at $02
                STOREZB D0, [#FS_BUF_SECTOR + BPB_JUMP + 2]

                ; OEM name "K16-KOS " — 8 bytes at offset $03 (odd).
                ; Word stores at odd addresses fail on K16, so we write
                ; byte-by-byte with STOREZB.
                LOADI   D0, #'K'
                STOREZB D0, [#FS_BUF_SECTOR + BPB_OEM_NAME + 0]
                LOADI   D0, #'1'
                STOREZB D0, [#FS_BUF_SECTOR + BPB_OEM_NAME + 1]
                LOADI   D0, #'6'
                STOREZB D0, [#FS_BUF_SECTOR + BPB_OEM_NAME + 2]
                LOADI   D0, #'-'
                STOREZB D0, [#FS_BUF_SECTOR + BPB_OEM_NAME + 3]
                LOADI   D0, #'K'
                STOREZB D0, [#FS_BUF_SECTOR + BPB_OEM_NAME + 4]
                LOADI   D0, #'O'
                STOREZB D0, [#FS_BUF_SECTOR + BPB_OEM_NAME + 5]
                LOADI   D0, #'S'
                STOREZB D0, [#FS_BUF_SECTOR + BPB_OEM_NAME + 6]
                LOADI   D0, #' '
                STOREZB D0, [#FS_BUF_SECTOR + BPB_OEM_NAME + 7]

                ; bytes_per_sector = 512, at offset $0B (odd). Two byte stores.
                ; 512 = $0200; low byte = $00, high byte = $02.
                LOADI   D0, #0
                STOREZB D0, [#FS_BUF_SECTOR + BPB_BYTES_PER_SECTOR]
                LOADI   D0, #2
                STOREZB D0, [#FS_BUF_SECTOR + BPB_BYTES_PER_SECTOR + 1]

                ; --- Small fields in the BPB ---------------------------
                ; Mix of byte and word fields. STOREZ for words, STOREZB
                ; for bytes — both are page-$00 absolute, 16-bit addr.

                ; sec_per_cluster = 1 (byte at $0D)
                LOADI   D0, #1
                STOREZB D0, [#FS_BUF_SECTOR + BPB_SEC_PER_CLUSTER]

                ; reserved_sectors = 1 (word at $0E)
                LOADI   D0, #1
                STOREZ  D0, [#FS_BUF_SECTOR + BPB_RESERVED_SECTORS]

                ; num_fats = 1 (byte at $10)
                LOADI   D0, #1
                STOREZB D0, [#FS_BUF_SECTOR + BPB_NUM_FATS]

                ; root_entries — at BPB offset $11 (odd). Two byte stores.
                ; Part 24: read from slot+$38 (set by _ComputeFAT16Layout
                ; for host disks, or pinned to 32 in .fv_have_sizing_b for B:).
                LOADI   D0, #$38
                LEA     XY1, XY2+D0
                LOADD   D0, [XY1]               ; D0 = root_entries
                STOREZB D0, [#FS_BUF_SECTOR + BPB_ROOT_ENTRIES]
                MOVE    D1, D0
                SWAPB   D1
                LOW     D1
                STOREZB D1, [#FS_BUF_SECTOR + BPB_ROOT_ENTRIES + 1]

                ; total_sectors_16. Offset $13 is odd. Need to reload D1
                ; from the slot stash because _ZeroBuffer clobbered it.
                ; Slot+$30 holds total_sectors (set up earlier).
                LOADI   D0, #$30
                LEA     XY1, XY2+D0             ; XY1 = slot + $30
                LOADD   D1, [XY1+#0]            ; D1 = total_sectors

                STOREZB D1, [#FS_BUF_SECTOR + BPB_TOTAL_SECTORS_16]
                MOVE    D0, D1
                SWAPB   D0
                STOREZB D0, [#FS_BUF_SECTOR + BPB_TOTAL_SECTORS_16 + 1]

                ; media = $F8 (byte at $15)
                LOADI   D0, #FS_MEDIA_FIXED
                STOREZB D0, [#FS_BUF_SECTOR + BPB_MEDIA]

                ; sec_per_fat — reload D2 from slot stash for the same reason.
                LOADD   D2, [XY1+#2]            ; D2 = sec_per_fat
                STOREZ  D2, [#FS_BUF_SECTOR + BPB_SEC_PER_FAT]

                ; drive_num = $80 (byte at $24)
                LOADI   D0, #$80
                STOREZB D0, [#FS_BUF_SECTOR + BPB_DRIVE_NUM]

                ; kos_flags = 0 — already zero from _ZeroBuffer

                ; ext_boot_sig = $29 (byte at $26)
                LOADI   D0, #$29
                STOREZB D0, [#FS_BUF_SECTOR + BPB_EXT_BOOT_SIG]

                ; volume_id (4 bytes at $27, both word halves at odd
                ; offsets). Use SYS_TICKS as pseudo-random; split each
                ; word into two byte stores.
                LOADZ   D0, [#SYS_TICKS]
                STOREZB D0, [#FS_BUF_SECTOR + BPB_VOLUME_ID + 0]
                MOVE    D1, D0
                SWAPB   D1
                STOREZB D1, [#FS_BUF_SECTOR + BPB_VOLUME_ID + 1]

                LOADZ   D0, [#SYS_TICKS]
                ADD     D0, #$5A5A              ; jiggle so high word ≠ low word
                STOREZB D0, [#FS_BUF_SECTOR + BPB_VOLUME_ID + 2]
                MOVE    D1, D0
                SWAPB   D1
                STOREZB D1, [#FS_BUF_SECTOR + BPB_VOLUME_ID + 3]

                ; volume_label (11 bytes at offset $2B). Pop the caller's
                ; label pointer (pushed near the top of the routine) and
                ; copy 11 bytes byte-by-byte into the BPB.
                POP     XY1, XY3                ; XY1 = label ptr from caller

                LOADI   Y0, #$00
                LOADI   X0, #FS_BUF_SECTOR + BPB_VOLUME_LABEL
                LOADI   D0, #11
.fv_label_copy:
                LOADB   D2, [XY1]+
                STOREB  D2, [XY0]+
                SUB     D0, #1
                BNE     .fv_label_copy

                ; fs_type "FAT16   " (8 bytes at $36).
                ; "FA" (16) "T1" (16) "6 " (16) "  " (16)
                LOADI   D0, #$4146              ; "FA"
                STOREZ  D0, [#FS_BUF_SECTOR + BPB_FS_TYPE]
                LOADI   D0, #$3154              ; "T1"
                STOREZ  D0, [#FS_BUF_SECTOR + BPB_FS_TYPE + 2]
                LOADI   D0, #$2036              ; "6 "
                STOREZ  D0, [#FS_BUF_SECTOR + BPB_FS_TYPE + 4]
                LOADI   D0, #$2020              ; "  "
                STOREZ  D0, [#FS_BUF_SECTOR + BPB_FS_TYPE + 6]

                ; signature $AA55 at $1FE
                LOADI   D0, #FS_BOOT_SIG
                STOREZ  D0, [#FS_BUF_SECTOR + BPB_SIGNATURE]

                ; --- Write boot sector ----------------------------------
                LOADI   Y0, #$00
                LOADI   X0, #FS_BUF_SECTOR
                LOADI   D0, #0                  ; sector 0
                CALLR   _VolBlockWrite
                BCS     .fv_io_err

                ; --- Build FAT sector 0
                CALLR   _ZeroBuffer
                LOADI   D0, #FS_FAT0_VALUE
                STOREZ  D0, [#FS_BUF_SECTOR]                ; FAT[0]
                LOADI   D0, #FS_FAT1_VALUE
                STOREZ  D0, [#FS_BUF_SECTOR + 2]            ; FAT[1]

                LOADI   Y0, #$00
                LOADI   X0, #FS_BUF_SECTOR
                LOADI   D0, #1                  ; sector 1 (first FAT sector)
                CALLR   _VolBlockWrite
                BCS     .fv_io_err

                ; --- Zero remaining metadata sectors
                ; Re-zero the buffer (still has FAT sentinels in it).
                CALLR   _ZeroBuffer

                ; Loop sector D0 = 2..(data_start - 1) inclusive.
                ; data_start was stashed in slot+$34.
                ; D2 = loop counter (clobbered by _VolBlockWrite — must
                ; PUSH/POP across the call). D3 holds the bound and is
                ; preserved by the call (not in its clobber list).
                LOADI   D0, #$34
                LEA     XY1, XY2+D0
                LOADD   D3, [XY1]               ; D3 = data_start
                LOADI   D2, #2                  ; current sector

.fv_zero_loop:
                CMP     D2, D3
                BHS.S   .fv_zero_done

                LOADI   Y0, #$00
                LOADI   X0, #FS_BUF_SECTOR
                MOVE    D0, D2                  ; D0 = current sector
                PUSH    D2, XY3                 ; save loop counter
                CALLR   _VolBlockWrite
                POP     D2, XY3                 ; restore counter
                BCS     .fv_io_err

                ADD     D2, #1
                BRA     .fv_zero_loop

.fv_zero_done:
                ; --- Re-mount the freshly-formatted volume
                ; Invalidate FAT cache first — anything we wrote above
                ; that the cache might have been holding is now stale.
                CALLR   _FATInvalidate

                ; Part 24: remount the same drive we formatted, not
                ; hardcoded FS_DRIVE_B. Drive index was stashed at slot+$36.
                LOADI   D0, #$36
                LEA     XY1, XY2+D0
                LOADD   D0, [XY1]               ; D0 = drive
                CALLR   _TryMount
                BCS     .fv_mount_err

                ; Success.
                LOADI   D0, #ERR_OK
                CLC
                BRA     .fv_done

.fv_baddrive:
                LOADI   D0, #ERR_BADDRIVE
                SEC
                BRA     .fv_done

.fv_readonly:
                LOADI   D0, #ERR_READONLY
                SEC
                BRA     .fv_done

.fv_io_err:
                ; D0/C already set by _VolBlockWrite.
                BRA     .fv_done

.fv_mount_err:
                ; _TryMount left D0 with its own err code; coerce to ERR_INVALID
                ; since this is a "we just wrote it, mount must succeed" case.
                LOADI   D0, #ERR_INVALID
                SEC
                ; fall through

.fv_done:
                POP     XY2, XY3
                POP     D3, XY3
                RET

; ============================================================================
; FAT cache and cluster allocator
; ============================================================================
;
; FAT cache rules:
;   • At any moment the cache holds zero or one FAT sector for one drive.
;   • On a cache miss (different sector or different drive), if the cache
;     is dirty we flush it before loading the new sector.
;   • _InitFS invalidates the cache at boot.
;   • _FormatVolume invalidates the cache before re-mounting the volume.
;
; Multi-sector-per-cluster caveat:
;   _ClusterToSector currently rejects sec_per_cluster ≠ 1 with ERR_INVALID.
;   _FormatVolume always writes sec_per_cluster = 1 for both EMU and Digital
;   RAM disks, so this is fine for Phase 16. SD support (Phase 17+) will
;   need a proper multiply or a power-of-2 shift table cached at mount.
;
; ============================================================================


; ============================================================================
; _FATInvalidate — drop any cached FAT sector AND any cached dir sector
;
;   Called from _InitFS at boot, and from _TryMount on remount. Discards
;   any pending dirty bytes.
;
;   Part 22: also invalidates DIR_CACHE_SECTOR (FS_BUF_SECTOR identity)
;   AND DIRENT_LAST_COOKIE (sys_dirent iteration cache). Every site that
;   wants a clean cache state should call this and get all three reset.
;
;   In:    (none)
;   Out:   FAT_CACHE_SECTOR    = $FFFF, FAT_CACHE_DIRTY = 0
;          DIR_CACHE_SECTOR    = $FFFF
;          DIRENT_LAST_COOKIE  = $FFFF
;          C cleared
;   Clobbers: D0, flags
; ============================================================================
_FATInvalidate:
                LOADI   D0, #FAT_CACHE_INVALID
                STOREZ  D0, [#FAT_CACHE_SECTOR]
                STOREZ  D0, [#DIR_CACHE_SECTOR]
                STOREZ  D0, [#DIRENT_LAST_COOKIE]
                LOADI   D0, #0
                STOREZB D0, [#FAT_CACHE_DIRTY]
                RETCC


; ============================================================================
; _FATFlush — write the FAT cache back to disk if dirty
;
;   In:    XY2 = volume slot ptr (the drive whose cache may be dirty)
;          (caller should match against FAT_CACHE_DRIVE — internal helpers
;          do this automatically)
;   Out:   C=0 success (or no flush needed), FAT_CACHE_DIRTY cleared
;          C=1 with D0 = ERR_IO if write fails
;   Clobbers: D0, D1, D2, X0, X1, flags
;   Preserves: XY2 (saved/restored around the owner-slot resolution), D3, XY3
;
;   Dependency: cross-file CALL24 to _SlotForDrive (kos_fs_fd.asm) to map
;   FAT_CACHE_DRIVE -> its volume slot for the write-back. Issued once per
;   flush (straight-line, not in a loop) — safe per handover 4a.
; ============================================================================
_FATFlush:
                LOADZB  D0, [#FAT_CACHE_DIRTY]
                CMP     D0, #0
                BEQ     .ff_clean               ; long form: body grew past .S range

                ; Cache is dirty — write it back.
                ;
                ; BUGFIX 28 May 2026 (Part 37): flush to the drive that OWNS
                ; the dirty cache (FAT_CACHE_DRIVE), NOT to whatever XY2 the
                ; caller currently holds. During a cross-drive operation
                ; (e.g. `cp a:*.* b:`), XY2 can point at A:/ROM while the
                ; dirty FAT sector belongs to B:/RAMDISK. Flushing through
                ; A:'s null write pointer returned ERR_READONLY, which
                ; bubbled up through _FATGetEntry -> _FdAdvancePosition
                ; (.fap_io) and aborted the second sys_write of any
                ; multi-cluster file. The block layer was never reached
                ; (no RAMDISK bounds path), which is why it presented as a
                ; non-IO failure. Resolve FAT_CACHE_DRIVE -> its own slot,
                ; flush there, restore the caller's XY2.
                PUSH    XY2, XY3                ; save caller's volume slot

                LOADZB  D0, [#FAT_CACHE_DRIVE]
                AND     D0, #$FF
                CALL24  _SlotForDrive           ; cross-file call (kos_fs_fd.asm); once per flush, not in a loop
                BCS     .ff_badowner            ; owner not mounted (shouldn't happen)

                ; Sector number from cache state.
                LOADZ   D0, [#FAT_CACHE_SECTOR]
                LOADI   Y0, #$00
                LOADI   X0, #FS_BUF_FAT
                CALLR   _VolBlockWrite
                BCS     .ff_io_err_pop

                POP     XY2, XY3                ; restore caller's volume slot

                ; Clear dirty flag.
                LOADI   D0, #0
                STOREZB D0, [#FAT_CACHE_DIRTY]

.ff_clean:
                LOADI   D0, #ERR_OK
                RETCC

.ff_io_err_pop:
                POP     XY2, XY3                ; restore (flag-transparent POP)
.ff_io_err:
                ; D0/C already set by _VolBlockWrite.
                RETCS

.ff_badowner:
                ; FAT_CACHE_DRIVE doesn't resolve to a mounted slot. Should
                ; never happen (we only dirty a cache for a mounted drive),
                ; but fail safe rather than flush to the wrong volume.
                POP     XY2, XY3
                LOADI   D0, #ERR_IO
                RETCS


; ============================================================================
; _FATLoad — load a FAT sector into the cache, flushing first if needed
;
;   Used by _FATGetEntry / _FATSetEntry when their target sector isn't
;   currently cached.
;
;   In:    D0  = absolute sector number to load (i.e. FAT_START + index)
;          D1  = drive index (for cache identity)
;          XY2 = volume slot ptr
;   Out:   C=0 with cache holding the sector
;          C=1 with D0 = ERR_IO on read failure
;   Clobbers: D0, D1, D2, X0, X1, flags
;   Preserves: D3, XY2, XY3
; ============================================================================
_FATLoad:
                ; Stash inputs we'll need after the flush call.
                PUSH    D0, XY3                 ; sector
                PUSH    D1, XY3                 ; drive

                CALLR   _FATFlush
                BCS     .fl_io_err

                ; Restore inputs and read the new sector.
                POP     D1, XY3                 ; drive
                POP     D0, XY3                 ; sector

                ; Update cache identity BEFORE the read so that an aborted
                ; read leaves the cache in a sane "invalid" state if we
                ; bail. We set the cache to the new sector tentatively,
                ; then if read fails we mark invalid.
                STOREZ  D0, [#FAT_CACHE_SECTOR]
                STOREZB D1, [#FAT_CACHE_DRIVE]

                LOADI   Y0, #$00
                LOADI   X0, #FS_BUF_FAT
                ; D0 still holds sector number.
                CALLR   _VolBlockRead
                BCS     .fl_read_err

                ; Cache fresh, not dirty.
                LOADI   D0, #0
                STOREZB D0, [#FAT_CACHE_DIRTY]
                LOADI   D0, #ERR_OK
                RETCC

.fl_io_err:
                ; _FATFlush failed. D0 holds err code, C=1.
                ; Discard the two saved words via POP (flag-transparent;
                ; ADD on X registers would clobber C).
                POP     D1, XY3                 ; discard saved drive
                POP     D1, XY3                 ; discard saved sector
                RET

.fl_read_err:
                ; Read failed — mark cache invalid so future calls retry.
                LOADI   D0, #FAT_CACHE_INVALID
                STOREZ  D0, [#FAT_CACHE_SECTOR]
                LOADI   D0, #ERR_IO
                RETCS


; ============================================================================
; _FATGetEntry — read a FAT entry for a given cluster
;
;   In:    D0  = cluster number
;          XY2 = volume slot ptr
;          D3  = drive index for cache identity
;            (caller must supply this; we don't compute it from XY2)
;   Out:   C=0 with D0 = FAT entry value (next-cluster or EOC marker)
;          C=1 with D0 = ERR_IO on read failure
;   Clobbers: D0, D1, D2, X0, X1, flags
;   Preserves: D3, XY2, XY3
;
; Math:
;   fat_sector_idx = cluster >> 8        (HIGH gives this directly)
;   fat_byte_off   = (cluster & $FF) << 1
;   fat_sector_abs = VOL_FAT_START + fat_sector_idx
; ============================================================================
_FATGetEntry:
                ; D2 = byte offset within FAT sector = (cluster & $FF) * 2
                MOVE    D2, D0
                LOW     D2                      ; D2 = cluster & $00FF
                SHL     D2                      ; D2 = (cluster mod 256) * 2

                ; D1 = absolute FAT sector = VOL_FAT_START + (cluster >> 8)
                HIGH    D0                      ; D0 = cluster >> 8
                LOADD   D1, [XY2+#VOL_FAT_START]
                ADD     D1, D0                  ; D1 = absolute sector

                ; --- Cache hit check ------------------------------------
                LOADZ   D0, [#FAT_CACHE_SECTOR]
                CMP     D0, D1
                BNE.S   .fge_miss
                LOADZB  D0, [#FAT_CACHE_DRIVE]
                CMP     D0, D3
                BEQ.S   .fge_hit
                ; fall through to miss

.fge_miss:
                ; Need to load D1 for drive D3.
                ; _FATLoad takes sector in D0 and drive in D1.
                MOVE    D0, D1                  ; D0 = sector
                MOVE    D1, D3                  ; D1 = drive
                ; D2 (byte offset) preserved across call? _FATLoad clobbers
                ; D2; need to save it.
                PUSH    D2, XY3                 ; save byte offset
                CALLR   _FATLoad
                POP     D2, XY3
                BCS     .fge_err

.fge_hit:
                ; Read entry from cache: word at FS_BUF_FAT + D2
                ; Use mode 01 (XY+D) addressing.
                LOADI   Y0, #$00
                LOADI   X0, #FS_BUF_FAT
                LOADD   D0, [XY0+D2]            ; D0 = FAT entry value
                RETCC

.fge_err:
                ; D0 already has error code; C=1.
                RETCS


; ============================================================================
; _FATSetEntry — write a FAT entry for a given cluster
;
;   In:    D0  = cluster number
;          D1  = new FAT entry value (next-cluster or sentinel)
;          XY2 = volume slot ptr
;          D3  = drive index
;   Out:   C=0 success (cache marked dirty; not written to disk yet)
;          C=1 with D0 = ERR_IO on read failure (couldn't load the sector)
;   Clobbers: D0, D2, X0, X1, flags
;   Preserves: D1 (= new value), D3, XY2, XY3
; ============================================================================
_FATSetEntry:
                ; Save cluster (D0) and new value (D1) so the cache-miss
                ; path can use them as call args without juggling.
                PUSH    D1, XY3                 ; save new value
                PUSH    D0, XY3                 ; save cluster

                ; D2 = byte offset
                MOVE    D2, D0
                LOW     D2
                SHL     D2

                ; D1 = absolute FAT sector
                MOVE    D1, D0                  ; D1 = cluster
                HIGH    D1                      ; D1 = cluster >> 8
                LOADD   D0, [XY2+#VOL_FAT_START]
                ADD     D1, D0                  ; D1 = absolute sector

                ; --- Cache hit check ------------------------------------
                LOADZ   D0, [#FAT_CACHE_SECTOR]
                CMP     D0, D1
                BNE.S   .fse_miss
                LOADZB  D0, [#FAT_CACHE_DRIVE]
                CMP     D0, D3
                BEQ.S   .fse_hit

.fse_miss:
                ; Load the right sector. _FATLoad: D0=sector, D1=drive.
                MOVE    D0, D1                  ; D0 = sector
                MOVE    D1, D3                  ; D1 = drive
                ; D2 (byte offset) needs to survive the call.
                PUSH    D2, XY3
                CALLR   _FATLoad
                POP     D2, XY3
                BCS     .fse_err

.fse_hit:
                ; Restore the new value (was stashed two pushes ago).
                ; Stack layout from top: cluster, new_value.
                ; Pop cluster to D0 (we don't need it anymore — drop),
                ; then pop new_value to D1.
                POP     D0, XY3                 ; D0 = cluster (discarded)
                POP     D1, XY3                 ; D1 = new value

                ; Write entry to cache: word at FS_BUF_FAT + D2
                LOADI   Y0, #$00
                LOADI   X0, #FS_BUF_FAT
                STORED  D1, [XY0+D2]            ; cache[offset] = new value

                ; Mark cache dirty.
                LOADI   D0, #1
                STOREZB D0, [#FAT_CACHE_DIRTY]

                LOADI   D0, #ERR_OK
                RETCC

.fse_err:
                ; _FATLoad failed. D0 holds err code, C=1. Discard the two
                ; saved words via flag-transparent POPs.
                POP     D2, XY3                 ; discard saved cluster
                POP     D2, XY3                 ; discard saved new value
                RET


; ============================================================================
; _AllocCluster — find a free cluster, mark it as EOC, return cluster number
;
;   Linear scan from cluster 2 upward. First cluster whose FAT entry is
;   FAT_FREE wins.
;
;   In:    XY2 = volume slot ptr
;          D3  = drive index
;   Out:   C=0 with D0 = newly-allocated cluster number (≥ 2)
;          C=1 with D0 = ERR_NOSPACE if no free cluster
;          C=1 with D0 = ERR_IO if FAT read fails
;   Clobbers: D0, D1, D2, X0, X1, flags
;   Preserves: D3, XY2, XY3
;
; Performance: with the single-sector FAT cache, the worst-case scan
; touches each FAT sector at most once. For our 1MB volume (8 FAT
; sectors, 2048 clusters) that's roughly 8 sector reads + 2048 word
; comparisons in cache.
; ============================================================================
_AllocCluster:
                ; D1 = current cluster, starting at 2.
                ; Bound: VOL_TOTAL_CLUSTERS + CLUSTER_FIRST_VALID. Cluster
                ; numbers 2..(N+1) are valid for an N-data-cluster volume;
                ; first invalid number is N+2.
                ;
                ; Previously (r10 and earlier) this used VOL_TOTAL_SECTORS as
                ; an over-estimate, because VOL_TOTAL_CLUSTERS wasn't populated
                ; at mount. That changed in kos_fs.asm r11+; Part 34 (r15)
                ; switches the bound here to match. On a typical 1MB volume
                ; this avoids ~18 superfluous loop iterations per ENOSPC
                ; detection (the gap between data_sectors and total_sectors).
                LOADI   D1, #CLUSTER_FIRST_VALID

.ac_loop:
                ; Bound check.
                LOADD   D0, [XY2+#VOL_TOTAL_CLUSTERS]
                ADD     D0, #CLUSTER_FIRST_VALID    ; first invalid cluster #
                CMP     D1, D0
                BHS     .ac_no_space

                ; Read FAT entry for cluster D1.
                PUSH    D1, XY3                 ; save current cluster
                MOVE    D0, D1                  ; D0 = cluster for _FATGetEntry
                CALLR   _FATGetEntry
                ; D0 = entry value, or err on C=1.
                BCS     .ac_io_err_pop

                ; Is it free?
                CMP     D0, #FAT_FREE
                BEQ.S   .ac_found

                ; Not free — restore D1, increment, loop.
                POP     D1, XY3
                ADD     D1, #1
                BRA     .ac_loop

.ac_found:
                ; Stack top: saved cluster (the one we just decided to alloc).
                ; Pop it into D0 for the _FATSetEntry call, then push it
                ; back so we have it for the return value after the call.
                POP     D0, XY3                 ; D0 = cluster
                PUSH    D0, XY3                 ; save again for return path

                ; Set FAT[cluster] = EOC.
                ; _FATSetEntry: D0=cluster, D1=value, XY2=slot, D3=drive
                LOADI   D1, #FS_FAT1_VALUE      ; EOC marker $FFFF
                CALLR   _FATSetEntry
                BCS     .ac_set_err

                ; Maintain free-cluster cache (-1) if live. D0 holds the
                ; cluster (return value); D1/D2 are scratch (clobber set).
                ; Offsets > IMM5 → mode-01 D-indexed [XY2+D2].
                LOADI   D2, #VOL_FREE_VALID
                LOADD   D1, [XY2+D2]
                CMP     D1, #0
                BEQ.S   .ac_nocache
                LOADI   D2, #VOL_FREE_CLUSTERS
                LOADD   D1, [XY2+D2]
                SUB     D1, #1
                STORED  D1, [XY2+D2]
.ac_nocache:
                ; Restore cluster as return value.
                POP     D0, XY3                 ; D0 = cluster
                CLC                             ; SUB left C=1 (no borrow); success = C=0
                RET

.ac_set_err:
                ; _FATSetEntry failed. D0 holds its error code (C=1).
                ; Discard the saved cluster — POP is flag-transparent
                ; (ADD on X registers would clobber C).
                POP     D1, XY3
                RET

.ac_io_err_pop:
                ; _FATGetEntry failed. Discard the saved cluster the same
                ; way. D0 already holds the error code, C=1.
                POP     D1, XY3
                ; fall through

.ac_io_err:
                RET

.ac_no_space:
                LOADI   D0, #ERR_NOSPACE
                RETCS


; ============================================================================
; _FreeCluster — mark a cluster free
;
;   Trivial wrapper around _FATSetEntry with FAT_FREE as the value.
;
;   In:    D0  = cluster number
;          XY2 = volume slot ptr
;          D3  = drive index
;   Out:   C=0 success
;          C=1 with D0 = ERR_IO on failure
;   Clobbers: D0, D1, X0, X1, flags
;   Preserves: D2, D3, XY2, XY3
;
;   (D1 is clobbered — the body does LOADI D1,#FAT_FREE for _FATSetEntry.
;   The header previously claimed "Preserves: D1" but never did; callers
;   that keep a cross-call value do so in D2, which IS preserved. Comment
;   corrected Part 48.)
;
;   Bug fix 11 May 2026: previously claimed to preserve D2 but
;   _FATSetEntry's body clobbers D2 (uses it to hold the FAT byte
;   offset for the STORED to FS_BUF_FAT). Callers (_FATFreeChain
;   in kos_fs.asm and _TruncateExisting in kos_fs_fd.asm) keep the
;   "next cluster" in D2 across this call, so on a small disk where
;   sec_per_fat=1, the walk could fall through to FAT entries for
;   bogus high cluster numbers whose computed FAT-sector address
;   lands on the dir sector — `_FATLoad` then loaded a dir sector
;   into FS_BUF_FAT, and the subsequent `_FATFlush` wrote dir data
;   back to the dir sector, zeroing entry 0's first byte and
;   making `ls` see an empty directory after a `load -f`.
;   Fix: actually preserve D2 by pushing across _FATSetEntry.
; ============================================================================
_FreeCluster:
                PUSH    D2, XY3                 ; preserve D2 (caller's "next cluster")
                LOADI   D1, #FAT_FREE
                CALLR   _FATSetEntry
                ; C set by _FATSetEntry; flag-transparent POP follows.
                POP     D2, XY3
                BCS     .fc_ret                 ; failed → leave cache, preserve C=1 (plain: success span >31B)

                ; Maintain free-cluster cache (+1) if live. Save D0/D1 (both
                ; dead post-call) so the routine's register footprint is
                ; unchanged; D0 = offset, D1 = value. Offsets > IMM5 →
                ; mode-01 D-indexed. XY2 read-only.
                PUSH    D0, XY3                 ; flag-transparent
                PUSH    D1, XY3
                LOADI   D0, #VOL_FREE_VALID
                LOADD   D1, [XY2+D0]
                CMP     D1, #0
                BEQ.S   .fc_nocache
                LOADI   D0, #VOL_FREE_CLUSTERS
                LOADD   D1, [XY2+D0]
                ADD     D1, #1
                STORED  D1, [XY2+D0]
.fc_nocache:
                POP     D1, XY3                 ; flag-transparent
                POP     D0, XY3
                CLC                             ; success
.fc_ret:
                RET


; ============================================================================
; _VolFreeClusters — count FAT_FREE entries across a volume's data region
;
;   Linear walk of clusters 2..(VOL_TOTAL_CLUSTERS+1), counting entries
;   equal to FAT_FREE. Sequential access is cache-friendly: _FATGetEntry's
;   single-sector FAT cache turns over once per 256 clusters, so a 1MB
;   volume (2030 data clusters, 8 FAT sectors) costs ~8 sector reads plus
;   2030 word compares.
;
;   In:    XY2 = vol slot ptr (mounted; caller guarantees VOL_PRESENT=1)
;          D3  = drive index (for _FATGetEntry's cache identity)
;   Out:   C=0 with D0 = free cluster count (0..VOL_TOTAL_CLUSTERS)
;          C=1 with D0 = ERR_IO if a FAT sector read fails
;   Clobbers: D0, D1, D2, X0, X1
;   Preserves: D3, XY2, XY3 (cluster# and count parked in page-$00 scratch)
;
;   Scratch slots: DISKFREE_CLUSTER ($03F4), DISKFREE_COUNT ($03F6).
;   These survive the _FATGetEntry call which clobbers D0..D2 + X0/X1.
; ============================================================================
_VolFreeClusters:
                ; Initialise counter and cluster cursor.
                LOADI   D0, #0
                STOREZ  D0, [#DISKFREE_COUNT]
                LOADI   D0, #CLUSTER_FIRST_VALID
                STOREZ  D0, [#DISKFREE_CLUSTER]

                ; Compute the scan limit (first invalid cluster #) ONCE
                ; and cache in page-$00. Saves a LOADD + ADD per iteration
                ; (~8K cycles on a 1MB volume's 2030-iter walk).
                LOADD   D0, [XY2+#VOL_TOTAL_CLUSTERS]
                ADD     D0, #CLUSTER_FIRST_VALID
                STOREZ  D0, [#DISKFREE_LIMIT]

.vfc_loop:
                ; Bound check: current cluster vs cached limit.
                LOADZ   D0, [#DISKFREE_CLUSTER]
                LOADZ   D1, [#DISKFREE_LIMIT]
                CMP     D0, D1
                BHS     .vfc_done

                ; Read FAT entry for current cluster (D0 already loaded).
                CALLR   _FATGetEntry
                BCS     .vfc_io_err

                ; D0 = FAT entry value. Is it free?
                CMP     D0, #FAT_FREE
                BNE.S   .vfc_skip

                ; Free — bump count.
                LOADZ   D0, [#DISKFREE_COUNT]
                ADD     D0, #1
                STOREZ  D0, [#DISKFREE_COUNT]

.vfc_skip:
                ; Advance cluster cursor.
                LOADZ   D0, [#DISKFREE_CLUSTER]
                ADD     D0, #1
                STOREZ  D0, [#DISKFREE_CLUSTER]
                BRA     .vfc_loop

.vfc_done:
                LOADZ   D0, [#DISKFREE_COUNT]
                CLC
                RET

.vfc_io_err:
                ; D0 already = ERR_IO from _FATGetEntry; C=1.
                RET


; ============================================================================
; sys_diskfree — TRAP #68 — report free + total clusters for a drive
;
;   In:    D0 = drive (0=A:, 1=B:, ...)
;   Out:   C=0 success:
;            D0 = free clusters
;            D1 = total clusters (== VOL_TOTAL_CLUSTERS)
;            D2 = cluster size in bytes (typically 512)
;          C=1 failure:
;            D0 = ERR_BADDRIVE (drive not mounted)
;                 ERR_IO       (FAT scan failed mid-walk)
;
;   Userland can multiply free*cluster_size / total*cluster_size for byte
;   counts; KLIB_DIVMOD32 / KLIB_UTOA32 cover the 32-bit math.
;
;   Pattern follows sys_format: DINT at entry, EINT gated on KERN_STATE_RUN
;   at exit (gotcha 4.6). D2/D3 callee-saved per V2 ABI — but this TRAP
;   actually returns a value in D2, so the caller must read D2 BEFORE any
;   subsequent syscall (V2 says D2/D3 are caller-saved at syscall sites
;   from the caller's perspective, but kosh/Pascal compiled code currently
;   treats syscall-returns-in-D2 as load-and-use-immediately).
; ============================================================================
sys_diskfree:
                DINT

                ; --- V2 TRAP ABI: handler must preserve D1..D3 and XY1/XY2/XY3.
                ; Our internal callees (_SlotForDrive, _VolFreeClusters →
                ; _FATGetEntry) clobber X0, X1, Y0, Y1, D1, D2, D3. We save
                ; the lot at entry and restore at exit, then write our
                ; returns into D0/D1/D2 below. (XY3 is the stack, managed
                ; by PUSH/POP.)
                PUSH    D3, XY3
                PUSH    XY0, XY3
                PUSH    XY1, XY3
                PUSH    XY2, XY3                    ; Part 25: XY2 is the Pascal frame pointer

                ; Resolve drive → XY2.
                MOVE    D3, D0                  ; D3 = drive idx (for _FATGetEntry)
                CALL24  _SlotForDrive           ; cross-file call (kos_fs_fd.asm)
                BCS     .sdf_err

                ; Free count: cache hit (O(1)), or walk-and-populate.
                ; Cache is maintained incrementally by _AllocCluster (-1) and
                ; _FreeCluster (+1); a full walk runs only once per
                ; boot/mount/format (when VOL_FREE_VALID = 0). Slot offsets
                ; > IMM5 → mode-01 D-indexed [XY2+D1].
                LOADI   D1, #VOL_FREE_VALID
                LOADD   D0, [XY2+D1]
                CMP     D0, #0
                BEQ     .sdf_walk
                LOADI   D1, #VOL_FREE_CLUSTERS
                LOADD   D0, [XY2+D1]                    ; hit
                BRA.S   .sdf_have_free
.sdf_walk:
                CALL24  _VolFreeClusters
                BCS     .sdf_err
                LOADI   D1, #VOL_FREE_CLUSTERS
                STORED  D0, [XY2+D1]                    ; populate (D0 = free count)
                LOADI   D1, #VOL_FREE_VALID
                LOADI   D2, #1
                STORED  D2, [XY2+D1]                    ; mark cache live
.sdf_have_free:
                ; D0 = free clusters (cached or freshly walked).

                ; Stage D1 (total) and D2 (cluster size) from XY2.
                ; Don't trash D0 — it's our return value.
                ; LOAD doesn't clobber other regs, so load each in place.
                ; (Memo: VOL_TOTAL_CLUSTERS high word is always 0 on Phase
                ; 16 volumes, so the low-word load is sufficient.)
                LOADD   D1, [XY2+#VOL_TOTAL_CLUSTERS]
                LOADD   D2, [XY2+#VOL_SEC_PER_CLUSTER]

                ; Translate sectors-per-cluster → bytes-per-cluster.
                ; (VOL_SEC_PER_CLUSTER stores the BPB byte zero-extended.)
                ; SECTOR_SIZE is always 512 = 2^9, so bytes = sec << 9.
                SHL4    D2                      ; ×16
                SHL4    D2                      ; ×256
                SHL     D2                      ; ×512

                CLC
                BRA     .sdf_exit

.sdf_err:
                SEC

.sdf_exit:
                ; Gate EINT on KERNEL_STATE (gotcha 4.6).
                ;   PUSH SR  saves our C flag (gets clobbered by the CMP).
                ;   PUSH D1  saves the total-clusters return value (the
                ;            kernel-state check uses D1 as scratch).
                ; D0 (free) and D2 (cluster size) are not touched here.
                PUSH    SR, XY3
                PUSH    D1, XY3
                LOADZ   D1, [#KERNEL_STATE]
                LOW     D1
                CMP     D1, #KERN_STATE_RUN
                BNE.S   .sdf_skip_eint
                EINT
.sdf_skip_eint:
                POP     D1, XY3                 ; restore total-clusters return
                POP     SR, XY3                 ; restore C flag

                ; Restore callee-saved XY1, XY0, D3 (reverse order of PUSHes).
                POP     XY2, XY3                    ; Part 25: XY2 is the Pascal frame pointer
                POP     XY1, XY3
                POP     XY0, XY3
                POP     D3, XY3
                RET


; ============================================================================
; _FATFreeChain — walk a FAT cluster chain, marking every cluster FREE
;
;   Frees the entire chain starting at the given cluster. Does NOT touch
;   the dirent — caller is responsible for that (e.g. _DirDelete, or
;   patching first_cluster=0 if truncating).
;
;   Walk pattern mirrors _TruncateExisting (kos_fs_fd.asm): read next-link
;   via _FATGetEntry BEFORE calling _FreeCluster on the current one,
;   because _FreeCluster overwrites the link. Loop terminates on EOC,
;   FREE, or any value < CLUSTER_FIRST_VALID (defensive — corrupt chains
;   stop rather than running away).
;
;   Caller must call _FATFlush after this if it wants the changes
;   persisted before any other FAT operation (we don't flush here so the
;   caller can batch with other FAT mutations).
;
;   In:    D0  = starting cluster number
;          XY2 = volume slot ptr
;          D3  = drive index
;   Out:   C=0 on success
;          C=1 with D0 = ERR_IO if FAT read/write failed
;   Clobbers: D0, D1, D2, X0, X1, flags
;   Preserves: D3, XY2, XY3
;
;   Part 25 — extracted as standalone helper for sys_unlink. The walk in
;   _TruncateExisting is functionally identical and could in principle
;   delegate here, but leaving _TruncateExisting alone for now (touched
;   only when there's a real reason).
; ============================================================================
_FATFreeChain:
                MOVE    D1, D0                  ; D1 = current cluster
                CMP     D1, #CLUSTER_FIRST_VALID
                BLO     .ffc_done               ; empty chain (no clusters)
                CMP     D1, #FAT_EOC_MIN
                BHS     .ffc_done               ; degenerate: start = EOC

.ffc_walk:
                ; Get next-link before freeing current (FreeCluster overwrites it).
                MOVE    D0, D1
                PUSH    D1, XY3                 ; save current
                CALLR   _FATGetEntry            ; D0 = next; clobbers D1
                BCS     .ffc_io_pop
                MOVE    D2, D0                  ; D2 = next
                POP     D1, XY3                 ; restore current

                ; Free current.
                MOVE    D0, D1
                CALLR   _FreeCluster
                BCS     .ffc_io                 ; ERR_IO bubbles up

                ; Advance.
                MOVE    D1, D2
                CMP     D1, #FAT_EOC_MIN
                BHS     .ffc_done
                CMP     D1, #CLUSTER_FIRST_VALID
                BLO     .ffc_done               ; defensive — invalid link
                BRA     .ffc_walk

.ffc_io_pop:
                POP     D1, XY3                 ; balance stack from PUSH above
                BRA     .ffc_io

.ffc_done:
                RETCC

.ffc_io:
                LOADI   D0, #ERR_IO
                RETCS


; ============================================================================
; _ClusterToSector — given cluster N, compute its first data sector
;
;   sector = data_start + (cluster - 2) * sec_per_cluster
;
;   Phase 16.3 assumes sec_per_cluster is a power of 2 (always true in
;   FAT16). If sec_per_cluster = 1 (our default), no shift is needed.
;   For larger cluster sizes the implementation would compute log2 at
;   mount time and cache it; that's deferred.
;
;   In:    D0  = cluster number (must be ≥ 2)
;          XY2 = volume slot ptr
;   Out:   C=0 with D0 = first data sector
;          C=1 with D0 = ERR_INVALID if cluster < 2
;   Clobbers: D0, D1, flags
;   Preserves: D2, D3, XY0, XY1, XY2, XY3
; ============================================================================
_ClusterToSector:
                CMP     D0, #CLUSTER_FIRST_VALID
                BLO     .cts_invalid

                ; D0 = cluster - 2
                SUB     D0, #CLUSTER_FIRST_VALID

                ; D1 = sec_per_cluster (cached as word in slot).
                LOADD   D1, [XY2+#VOL_SEC_PER_CLUSTER]

                ; If sec_per_cluster = 1, skip the multiply.
                CMP     D1, #1
                BEQ.S   .cts_add_data_start

                ; Multi-sector cluster (Phase 17+ SD support).
                ; For now, refuse — the volumes we mount in Phase 16 always
                ; have sec_per_cluster = 1.
                LOADI   D0, #ERR_INVALID
                RETCS

.cts_add_data_start:
                LOADD   D1, [XY2+#VOL_DATA_START]
                ADD     D0, D1                  ; D0 = data_start + (cluster - 2)
                ; ADD clobbers carry; RETCC would leak ERR_INVALID on an
                ; address-overflow carry. Force success carry explicitly.
                CLC
                RET

.cts_invalid:
                LOADI   D0, #ERR_INVALID
                SEC
                RET


; ============================================================================
; sys_format — TRAP #32 — format the writable volume
;
;   Thin syscall wrapper over _FormatVolume. Kept here (in kos_fs.asm)
;   alongside the primitive it wraps, rather than in kos_fs_fd.asm,
;   because it doesn't touch fd state at all.
;
;   In:    D0  = drive (FS_DRIVE_B = 1; FS_DRIVE_A rejected)
;          XY0 = pointer to 11-byte space-padded volume label
;   Out:   C=0 on success — slot now mounted with new format
;          C=1 with D0 = ERR_BADDRIVE  drive index out of range
;                       ERR_READONLY  attempting to format A:
;                       ERR_IO        block-write failed mid-format
;                       ERR_INVALID   re-mount failed (internal)
;   Clobbers: D0, XY0
;   Preserves: D1, D2, D3, XY1, XY2, XY3           ; V2 ABI (Part 36)
;
; Pattern follows sys_open / sys_dirent: DINT at entry, gate EINT on
; KERNEL_STATE == KERN_STATE_RUN at exit (gotcha 4.6). r4: D2 saved at
; entry / restored at exit — _FormatVolume documents D2 as clobbered.
; Part 36 (r5): added PUSH XY1 — XY1 is now callee-preserved per the
; expanded V2 ABI and _FormatVolume's internals clobber it.
; ============================================================================
sys_format:
                DINT

                ; --- Per V2 ABI (Part 36 expansion):
                ; D1, D2, D3, XY1 all callee-preserved.
                ; D3 and XY2 are saved internally by _FormatVolume.
                ; Part 36 r2: PUSH D1 added — _FormatVolume clobbers D1
                ; internally.
                PUSH    D2, XY3
                PUSH    XY1, XY3                    ; Part 36: V2 ABI
                PUSH    D1, XY3                     ; Part 36 r2
                PUSH    D3, XY3                     ; named drives v2: hold drive in D3
                PUSH    XY2, XY3                    ; Part 25: XY2 is the Pascal frame pointer
                MOVE    D3, D0                      ; D3 = drive (survives _FormatVolume)

                CALLR   _FormatVolume
                ; D0 / C already set by _FormatVolume.
                ; Named drives v2: on success, dirty this drive's path-mounts.
                BCS     .sf_noinval
                PUSH    D0, XY3                     ; save return code
                MOVE    D0, D3                      ; drive
                CALLR   _AssignInvalidateDrive
                POP     D0, XY3                     ; restore return code
                CLC                                 ; success (C=0)
.sf_noinval:

                ; Gate EINT on KERNEL_STATE (gotcha 4.6).
                ; Part 36: stash D0 (return) across the gate; D1 is now
                ; callee-preserved per V2 ABI.
                ; PUSH SR saves the C flag from _FormatVolume; CMP below
                ; clobbers it. POP SR restores C/Z/N/V only — the IE bit
                ; is hardware-managed (gotcha 2.5: SR bits 7:4 are read-
                ; only from software), so POP cannot undo our EINT.
                PUSH    SR, XY3
                PUSH    D0, XY3
                LOADZ   D0, [#KERNEL_STATE]
                LOW     D0
                CMP     D0, #KERN_STATE_RUN
                POP     D0, XY3
                BNE.S   .sf_skip_eint
                EINT
.sf_skip_eint:
                POP     SR, XY3

                ; Restore callee-saved D1, XY1, D2 (POP doesn't disturb flags).
                POP     XY2, XY3                    ; Part 25: XY2 is the Pascal frame pointer
                POP     D3, XY3                     ; named drives v2
                POP     D1, XY3                     ; Part 36 r2
                POP     XY1, XY3                    ; Part 36: V2 ABI
                POP     D2, XY3
                RET


; ============================================================================
; sys_mkdir — TRAP #69 — create a directory (resolve-aware, nested)
;
;   Creates a directory named by the LAST component of the path, inside the
;   directory named by the parent components — resolved via _ResolveParent.
;   So "B:FOO/BAR" creates BAR inside FOO; "BAR" (relative) creates BAR in
;   the caller's CWD; "B:BAR" creates BAR in B:'s root.
;
;   In:    XY0 = nul-terminated path
;          D0  = CWD drive index (for relative paths)
;          D1  = CWD cluster     (for relative paths; 0 = root)
;   Out:   C=0 success
;          C=1 with D0 = ERR_BADPATH / ERR_BADDRIVE / ERR_NOTFOUND /
;                        ERR_NOTDIR / ERR_READONLY / ERR_EXISTS /
;                        ERR_NOSPACE / ERR_IO
;   Clobbers: D0, XY0
;   Preserves: D1, D2, D3, XY1, XY2, XY3   (V2 ABI)
;
;   Non-leaf: DINT / EINT-gated exit per sys_format.
;
;   Sequence:
;     1. _ResolveParent    path -> drive, parent cluster; leaf in RV_FATNAME
;     2. _SlotForDrive     drive -> XY2
;     2a. read-only pre-flight (VOL_BLOCKWRITE_PTR null = r/o)
;     3. DIR_WALK_CLU = parent cluster
;     4. _DirLookup leaf   dup-check -> ERR_EXISTS if found
;     5. _AllocCluster     -> newclu (EOC)
;     6. _DirInitCluster(newclu, parent=parent cluster)   '.' and '..'
;     7. _DirCreate leaf -> newclu, attr=DIR, size=0  (in DIR_WALK_CLU=parent)
;        on failure: _FreeCluster(newclu) rollback
; ============================================================================
sys_mkdir:
                DINT

                PUSH    D1, XY3
                PUSH    D2, XY3
                PUSH    D3, XY3
                PUSH    XY1, XY3
                PUSH    XY2, XY3                    ; Part 25: XY2 is the Pascal frame pointer

                ; --- 1. resolve parent -> drive (D0), parent clu (D1);
                ;        leaf 11-byte name lands in RV_FATNAME.
                ; _ResolveParent: XY0=path, D0=start drive, D1=start clu.
                CALLR   _ResolveParent
                BCS     .mkd_err                ; BADPATH/BADDRIVE/NOTFOUND/NOTDIR/IO
                ; D0 = drive, D1 = parent cluster.
                MOVE    D3, D0                  ; D3 = drive (for dir routines)
                STOREZ  D1, [#MKD_PARENT_CL]    ; stash parent cluster

                ; --- 2. drive -> slot -------------------------------------
                MOVE    D0, D3
                CALLR   _SlotForDrive          ; D0=drive -> XY2
                BCS     .mkd_err                ; ERR_BADDRIVE

                ; --- 2a. read-only pre-flight -----------------------------
                LOADD   D0, [XY2+#VOL_BLOCKWRITE_PTR]
                LOADI   D1, #VOL_BLOCKWRITE_PTR+2
                LOADD   D1, [XY2+D1]
                OR      D0, D1
                BNE.S   .mkd_writable
                LOADI   D0, #ERR_READONLY
                BRA     .mkd_err
.mkd_writable:

                ; --- 3. operate inside the parent cluster -----------------
                LOADZ   D0, [#MKD_PARENT_CL]    ; parent cluster
                STOREZ  D0, [#DIR_WALK_CLU]

                ; --- 4. duplicate check (long-aware) ----------------------
                ; Part 47: _DirLookupLong matches a long dir name (RV_COMP) or
                ; 8.3 (RV_FATNAME when RV_SAVE_PAD=1).
                CALLR   _DirLookupLong
                BCC     .mkd_exists             ; found => already exists
                CMP     D0, #ERR_NOTFOUND
                BNE     .mkd_err                ; ERR_IO etc. -> propagate

                ; --- 5. allocate the new directory's cluster -------------
                CALLR   _AllocCluster          ; -> D0 = newclu (EOC); C=1 on fail
                BCS     .mkd_err                ; ERR_NOSPACE / ERR_IO
                ; Hold newclu on the stack — unambiguous across the
                ; _DirInitCluster / _DirCreate calls below, both of which use
                ; the slot scratch area ($30..$34) themselves. (Slot scratch
                ; would *happen* to survive, but the stack is collision-proof
                ; — cf. Gotcha 4.25 "looks free" hazard.)
                PUSH    D0, XY3                 ; [N] newclu

                ; --- 6. write '.' and '..' into the new cluster ----------
                ; _DirInitCluster: D0 = self, D1 = parent, XY2, D3.
                ; D0 already = newclu from _AllocCluster. Parent '..' = the
                ; resolved parent cluster (0 if parent is the root region).
                LOADZ   D1, [#MKD_PARENT_CL]    ; parent cluster
                CALLR   _DirInitCluster
                BCS     .mkd_free_and_err       ; init failed -> free cluster

                ; --- 7. link the leaf into the parent directory ----------
                ; Re-assert DIR_WALK_CLU = parent (defensive; nothing between
                ; step 3 and here resets it today, but make it explicit).
                LOADZ   D0, [#MKD_PARENT_CL]
                STOREZ  D0, [#DIR_WALK_CLU]
                ; Part 47: long-aware. Generate the 8.3 short name from the long
                ; leaf (RV_COMP); needs_lfn selects the LFN-run vs plain-short
                ; path (same shape as _CreateEmptyEntry). The held newclu [N]
                ; survives _GenShortName (stack, not slot scratch).
                LOADI   Y0, #$00
                LOADI   X0, #RV_COMP
                CALLR   _GenShortName           ; -> LFN_SHORT, D0 = needs_lfn
                BCS     .mkd_free_and_err       ; ERR_IO / ERR_NOSPACE
                CMP     D0, #0
                BNE     .mkd_lfn

                ; --- plain 8.3 directory entry ----------------------------
                LOADI   Y0, #$00
                LOADI   X0, #LFN_SHORT          ; generated 8.3 name
                POP     D1, XY3                 ; [N] newclu -> D1 (first cluster)
                PUSH    D1, XY3                 ; [N] re-push for rollback/exit
                LOADI   D0, #DIR_ATTR_DIRECTORY ; D0 = attr
                LOADI   D2, #0                  ; D2 = size = 0
                CALLR   _DirCreate
                BCS     .mkd_free_and_err       ; NOSPACE/IO -> roll back cluster
                BRA     .mkd_linked

.mkd_lfn:
                ; --- LFN run for a long directory name --------------------
                CALLR   _CopyCompToLfnAsm       ; RV_COMP -> LFN_ASM, LFN_ASM_LEN
                LOADI   Y0, #$00
                LOADI   X0, #LFN_SHORT
                POP     D1, XY3                 ; [N] newclu -> D1 (first cluster)
                PUSH    D1, XY3                 ; [N] re-push for rollback/exit
                LOADI   D0, #DIR_ATTR_DIRECTORY ; D0 = attr
                LOADI   D2, #0                  ; D2 = size = 0
                CALLR   _DirCreateRun
                BCS     .mkd_free_and_err       ; NOSPACE/IO -> roll back cluster

.mkd_linked:
                ; success — discard the held newclu
                POP     D1, XY3                 ; [N] drop
                LOADI   D0, #ERR_OK
                CLC
                BRA     .mkd_exit

.mkd_free_and_err:
                ; Entry: D0 = error code (from the failed callee, C=1);
                ;        stack top = [N] newclu.
                ; Free newclu, preserving the error code. newclu is under the
                ; saved err on the stack, so juggle: stack [E][N] -> pull both
                ; -> D0=err, D1=newclu -> re-save err -> free(D0=newclu) ->
                ; restore err.
                PUSH    D0, XY3                 ; [E] err ; stack [E][N]
                POP     D0, XY3                 ; D0 = err          ; stack [N]
                POP     D1, XY3                 ; D1 = newclu       ; stack []
                PUSH    D0, XY3                 ; [E] re-save err   ; stack [E]
                MOVE    D0, D1                  ; D0 = newclu
                CALLR   _FreeCluster           ; preserves D3, XY2, XY3
                POP     D0, XY3                 ; restore err code  ; stack []
                SEC
                BRA     .mkd_exit

.mkd_exists:
                LOADI   D0, #ERR_EXISTS
                SEC
                BRA     .mkd_exit

.mkd_err:
                ; D0 / C already set by the failing callee.
                ; fall through

.mkd_exit:
                ; Restore DIR_WALK_CLU to the root default (0). It is already
                ; 0 here, but make the contract explicit and robust against
                ; future callers that set it non-zero before us.
                PUSH    D0, XY3                 ; save return code across the store
                LOADI   D0, #0
                STOREZ  D0, [#DIR_WALK_CLU]
                POP     D0, XY3

                ; Gate EINT on KERNEL_STATE (gotcha 4.6). PUSH SR preserves
                ; the result carry across the CMP; POP SR restores C/Z/N/V
                ; (IE is hardware-managed, gotcha 2.5).
                PUSH    SR, XY3
                PUSH    D0, XY3
                LOADZ   D0, [#KERNEL_STATE]
                LOW     D0
                CMP     D0, #KERN_STATE_RUN
                POP     D0, XY3
                BNE.S   .mkd_skip_eint
                EINT
.mkd_skip_eint:
                POP     SR, XY3

                POP     XY2, XY3                    ; Part 25: XY2 is the Pascal frame pointer
                POP     XY1, XY3
                POP     D3, XY3
                POP     D2, XY3
                POP     D1, XY3
                RET


; ============================================================================
; sys_resolve — TRAP #70 — resolve a path to (drive, cluster, attr)
;
;   Stateless. The caller supplies its CWD context (start drive + cluster)
;   for relative/rooted paths; an "X:" prefix overrides the drive and starts
;   at that drive's root.
;
;   In:    XY0 = nul-terminated path (caller page)
;          D0  = start drive index (CWD drive)
;          D1  = start cluster     (CWD cluster; 0 = root)
;   Out:   C=0: D0 = drive, D1 = cluster, D2 = attr of final entry
;          C=1: D0 = ERR_BADPATH/BADDRIVE/NOTFOUND/NOTDIR/INVALID/IO
;   Clobbers: D0, D1, D2
;   Preserves: D3, XY1, XY2, XY3   (V2 ABI)
;
;   Non-leaf: DINT / EINT-gated exit per sys_format.
; ============================================================================
sys_resolve:
                DINT
                PUSH    D3, XY3
                PUSH    XY1, XY3
                PUSH    XY2, XY3

                CALLR   _Resolve               ; D0=drive,D1=clu,D2=attr / C,err

                POP     XY2, XY3
                POP     XY1, XY3
                PUSH    SR, XY3
                PUSH    D0, XY3
                LOADZ   D0, [#KERNEL_STATE]
                LOW     D0
                CMP     D0, #KERN_STATE_RUN
                POP     D0, XY3
                BNE.S   .sr_skip_eint
                EINT
.sr_skip_eint:
                POP     SR, XY3
                POP     D3, XY3
                RET


; ============================================================================
; sys_pwd — TRAP #71 — reconstruct a path string from (drive, cluster)
;
;   In:    D0  = drive index
;          D1  = cluster (0 = root)
;          XY0 = dest buffer (caller page; >= ~80 bytes)
;   Out:   C=0 with dest = "X:/..."\0
;          C=1 with D0 = ERR_IO / ERR_INVALID / ERR_BADDRIVE
;   Clobbers: D0
;   Preserves: D1, D2, D3, XY1, XY2, XY3   (V2 ABI)
;
;   Non-leaf: DINT / EINT-gated exit.
; ============================================================================
sys_pwd:
                DINT
                PUSH    D1, XY3
                PUSH    D2, XY3
                PUSH    D3, XY3
                PUSH    XY1, XY3
                PUSH    XY2, XY3

                CALLR   _BuildPath             ; writes dest; C,err

                POP     XY2, XY3
                POP     XY1, XY3
                PUSH    SR, XY3
                PUSH    D0, XY3
                LOADZ   D0, [#KERNEL_STATE]
                LOW     D0
                CMP     D0, #KERN_STATE_RUN
                POP     D0, XY3
                BNE.S   .pwd_skip_eint
                EINT
.pwd_skip_eint:
                POP     SR, XY3
                POP     D3, XY3
                POP     D2, XY3
                POP     D1, XY3
                RET


; ============================================================================
; sys_rmdir — TRAP #72 — remove an empty directory
;
;   Resolve-aware (nested) like sys_mkdir. The target must be a directory
;   and must be empty (only '.' and '..' present). Refuses '.'/'..' as the
;   leaf and refuses the drive root.
;
;   In:    XY0 = nul-terminated path
;          D0  = CWD drive index (for relative paths)
;          D1  = CWD cluster     (for relative paths; 0 = root)
;   Out:   C=0 success
;          C=1 with D0 = ERR_BADPATH / ERR_BADDRIVE / ERR_NOTFOUND /
;                        ERR_NOTDIR / ERR_NOTEMPTY / ERR_READONLY /
;                        ERR_INVALID / ERR_IO
;   Clobbers: D0, XY0
;   Preserves: D1, D2, D3, XY1, XY2, XY3   (V2 ABI)
;
;   Non-leaf: DINT / EINT-gated exit per sys_format.
; ============================================================================
sys_rmdir:
                DINT
                PUSH    D1, XY3
                PUSH    D2, XY3
                PUSH    D3, XY3
                PUSH    XY1, XY3
                PUSH    XY2, XY3                    ; Part 25: XY2 is the Pascal frame pointer

                CALLR   _RemoveDir              ; D0/C set

                POP     XY2, XY3                    ; Part 25: XY2 is the Pascal frame pointer
                POP     XY1, XY3
                PUSH    SR, XY3
                PUSH    D0, XY3
                LOADZ   D0, [#KERNEL_STATE]
                LOW     D0
                CMP     D0, #KERN_STATE_RUN
                POP     D0, XY3
                BNE.S   .srd_skip_eint
                EINT
.srd_skip_eint:
                POP     SR, XY3
                POP     D3, XY3
                POP     D2, XY3
                POP     D1, XY3
                RET


; ============================================================================
; _RemoveDir — kernel-internal: remove an empty directory by path
;
;   Algorithm:
;     1. _ResolveParent      path -> drive, parent clu; leaf -> RV_FATNAME
;     2. _SlotForDrive       drive -> XY2 ; read-only pre-flight
;     3. DIR_WALK_CLU=parent; _DirLookup leaf -> cookie (entry in FS_BUF)
;     4. Read attr + first cluster of the leaf entry
;        - attr must be DIRECTORY        else ERR_NOTDIR
;        - first cluster must be >= 2     else ERR_INVALID (corrupt/root)
;     5. _DirIsEmpty(leaf cluster)        else ERR_NOTEMPTY
;     6. _FATFreeChain(leaf cluster) + _FATFlush
;     7. DIR_WALK_CLU=parent; _DirDelete leaf from the parent
;
;   In:    XY0 = path, D0 = CWD drive, D1 = CWD cluster
;   Out:   C=0 / C=1 D0=ERR_*
;   Clobbers: D0..D3, XY0, XY1   (XY2/XY3 preserved)
; ============================================================================
_RemoveDir:
                PUSH    XY2, XY3

                ; --- 1. resolve parent + leaf -----------------------------
                CALLR   _ResolveParent
                BCS     .rd_err_pop             ; BADPATH/BADDRIVE/NOTFOUND/NOTDIR/IO
                MOVE    D3, D0                  ; D3 = drive
                STOREZ  D1, [#MKD_PARENT_CL]    ; parent cluster

                ; --- 2. drive -> slot -------------------------------------
                MOVE    D0, D3
                CALLR   _SlotForDrive          ; D0=drive -> XY2
                BCS     .rd_err_pop             ; ERR_BADDRIVE

                ; --- 2a. read-only pre-flight -----------------------------
                LOADD   D0, [XY2+#VOL_BLOCKWRITE_PTR]
                LOADI   D1, #VOL_BLOCKWRITE_PTR+2
                LOADD   D1, [XY2+D1]
                OR      D0, D1
                BNE.S   .rd_writable
                LOADI   D0, #ERR_READONLY
                BRA     .rd_err_pop
.rd_writable:

                ; --- 3. lookup the leaf in the parent ---------------------
                LOADZ   D0, [#MKD_PARENT_CL]
                STOREZ  D0, [#DIR_WALK_CLU]
                ; Part 47: long-aware (finds long-named directories).
                CALLR   _DirLookupLong
                BCS     .rd_err_pop             ; ERR_NOTFOUND / ERR_IO

                ; --- 4. read attr + first cluster of the matched entry ----
                ; entry_addr = FS_BUF_SECTOR + (cookie & $0F)*32
                MOVE    D1, D0
                AND     D1, #$0F
                SHL4    D1
                SHL     D1
                ADD     D1, #FS_BUF_SECTOR
                LOADI   Y0, #$00
                MOVE    X0, D1
                ; attr
                LOADB   D0, [XY0+#DIR_ATTR]
                AND     D0, #DIR_ATTR_DIRECTORY
                BNE.S   .rd_is_dir
                LOADI   D0, #ERR_NOTDIR
                BRA     .rd_err_pop
.rd_is_dir:
                ; first cluster (stash for emptiness + free)
                LOADD   D0, [XY0+#DIR_FIRST_CLUSTER_LO]
                STOREZ  D0, [#FD_NAMEBUF2]      ; reuse fd scratch (low word)
                ; refuse a cluster < 2 (corrupt, or somehow the root)
                CMP     D0, #2
                BHS.S   .rd_clu_ok
                LOADI   D0, #ERR_INVALID
                BRA     .rd_err_pop
.rd_clu_ok:

                ; --- 5. emptiness check -----------------------------------
                LOADZ   D0, [#FD_NAMEBUF2]      ; leaf cluster
                CALLR   _DirIsEmpty             ; C=0 empty / C=1 D0=ERR_NOTEMPTY/IO
                BCS     .rd_err_pop

                ; --- 6. free the dir's cluster chain + flush --------------
                LOADZ   D0, [#FD_NAMEBUF2]
                CALLR   _FATFreeChain
                BCS     .rd_err_pop             ; ERR_IO
                ; named drives v2: mark assigns pointing at this freed dir
                ; cluster dirty, so a later NAME: resolve fails cleanly.
                MOVE    D0, D3                  ; drive (D3 preserved by the chain)
                LOADZ   D1, [#FD_NAMEBUF2]      ; freed leaf cluster
                CALLR   _AssignInvalidate       ; preserves XY2, XY3
                CALLR   _FATFlush
                BCS     .rd_err_pop             ; ERR_IO

                ; --- 7. delete the leaf entry from the parent -------------
                ; Part 47: whole-run delete ($E5 a long-named dir's LFN
                ; fragments + short entry); RV_COMP=leaf survived steps 5-6.
                LOADZ   D0, [#MKD_PARENT_CL]
                STOREZ  D0, [#DIR_WALK_CLU]
                CALLR   _DirDeleteRun
                BCS     .rd_err_pop

                ; reset DIR_WALK_CLU and succeed.
                LOADI   D0, #0
                STOREZ  D0, [#DIR_WALK_CLU]
                POP     XY2, XY3
                CLC
                RET

.rd_err_pop:
                ; D0 already set, C=1. Reset DIR_WALK_CLU, unwind.
                PUSH    D0, XY3
                LOADI   D0, #0
                STOREZ  D0, [#DIR_WALK_CLU]
                POP     D0, XY3
                POP     XY2, XY3
                SEC
                RET


; ============================================================================
; _DirIsEmpty — true if a directory cluster contains only '.' and '..'
;
;   Walks the directory's entries. Any live entry whose name does not start
;   with '.' (i.e. a real file or subdir) makes it non-empty. Deleted ($E5)
;   and LFN/volume entries are ignored; the $00 sentinel ends the scan.
;
;   In:    D0  = directory cluster (>= 2)
;          XY2 = volume slot ptr
;          D3  = drive index
;   Out:   C=0 if empty
;          C=1 with D0 = ERR_NOTEMPTY  if a real entry is present
;                       ERR_IO         on read failure
;   Clobbers: D0, D1, D2, X0, X1, Y0, Y1, flags
;   Preserves: D3, XY2, XY3
; ============================================================================
_DirIsEmpty:
                STOREZ  D0, [#DIR_WALK_CLU]     ; iterate this cluster
                LOADI   D0, #0                  ; cookie
.die_loop:
                LOADI   Y1, #$00
                LOADI   X1, #RV_DIRENT_RAW
                CALLR   _DirNextRaw
                BCS     .die_nomore             ; ERR_NOMORE -> empty; ERR_IO -> err
                PUSH    D0, XY3                 ; save next cookie
                LOADI   Y0, #$00
                LOADI   X0, #RV_DIRENT_RAW
                LOADB   D1, [XY0]               ; first name byte
                AND     D1, #$FF
                CMP     D1, #DIR_FREE_END
                BEQ     .die_empty_pop          ; $00 -> end -> empty
                CMP     D1, #DIR_FREE_REUSABLE
                BEQ     .die_next               ; deleted -> ignore
                CMP     D1, #'.'
                BEQ     .die_next               ; '.' or '..' -> ignore
                ; attr filter: LFN / volume label don't count as real entries
                LOADB   D1, [XY0+#DIR_ATTR]
                AND     D1, #$FF
                CMP     D1, #DIR_ATTR_LFN
                BEQ     .die_next
                MOVE    D2, D1
                AND     D2, #DIR_ATTR_VOLUME_LABEL
                BNE     .die_next
                ; A real, live entry -> not empty.
                POP     D0, XY3                 ; discard cookie
                LOADI   D0, #ERR_NOTEMPTY
                SEC
                RET
.die_next:
                POP     D0, XY3                 ; D0 = next cookie
                BRA     .die_loop
.die_empty_pop:
                POP     D0, XY3                 ; discard cookie
.die_empty:
                LOADI   D0, #0
                STOREZ  D0, [#DIR_WALK_CLU]
                CLC
                RET
.die_nomore:
                ; D0 = ERR_NOMORE (clean end -> empty) or ERR_IO.
                CMP     D0, #ERR_NOMORE
                BNE.S   .die_io
                BRA     .die_empty
.die_io:
                ; ERR_IO: reset DIR_WALK_CLU, propagate.
                PUSH    D0, XY3
                LOADI   D0, #0
                STOREZ  D0, [#DIR_WALK_CLU]
                POP     D0, XY3
                SEC
                RET


; ============================================================================
; End of kos_fs.asm (Pieces 1+2+3 + Phase 19 sys_format + sys_mkdir
;                    + path resolver sys_resolve / sys_pwd + sys_rmdir)
; ============================================================================
