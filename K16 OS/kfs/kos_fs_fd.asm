; ============================================================================
; kos_fs_fd.asm — k/OS Phase 16 Piece 5: file descriptor syscalls
; ============================================================================
; Date:    18 May 2026
; Status:  Part 26 — FD_POSITION is genuinely 32-bit; files > 64 KB work
;
; Revision: r11 — 2 August 2026 — Part 26 fix: _FdEnsureCluster's
;             "position == 0" test was low-word only, so every exact
;             multiple of 64 KB skipped its cluster allocation and
;             overwrote the previous cluster. Found by per-4KB block
;             checksums against a known-good image (zblk.pas).
;           r10 — 2 August 2026 — Part 26: FD_POSITION's high word is now
;             live. _FdAdvancePosition propagates the ADD's carry;
;             _FdComputeReadChunk, _FdEnsureCluster, _FdFlushDirent and
;             _FdAdvancePositionAndSize all compare 32-bit via the new
;             _FdCmpPosSize leaf. sys_write enforces the documented
;             24-bit (16 MB) limit with ERR_TOOBIG instead of leaving it
;             as a comment. Previously every file in k/OS wrapped silently
;             at 64 KB.
;           r9 — 18 May 2026 — Part 34: sys_write now returns the
;             partial byte count in D1 alongside the error code in D0
;             when C=1. The "C=1 = bad" invariant is preserved (so
;             pre-Part 34 callers compile and run unchanged), and the
;             extra D1 lets newer code report "X of Y bytes written"
;             on errors like ERR_NOSPACE.
;
;             Implementation: .sw_done2 (the single exit point) now
;             does LOADZ D1, [FD_BYTES_DONE] before the EINT gate,
;             and PUSH/POP D1 around the kernel-state CMP so the
;             gate's scratch use doesn't trample the return value.
;             FD_BYTES_DONE is initialised to 0 at entry, so the
;             early-exit paths (.sw_badfd, .sw_readonly) correctly
;             return D1=0.
;
;             Contract header at sys_write updated to document the
;             new D1 semantics. The previously-unreachable
;             .load_short_write path in kosh (kosh_cmds_fs.asm) stays
;             unreachable under these semantics — sys_write never
;             returns C=0 with a short count; partial counts are only
;             surfaced via D1 on C=1.
;
; Revision: r8 — 12 May 2026 — dir-cache coherence: latent staleness fixes
;             in _LoadDirentFromCookie and _PatchDirentSizeCl.
;
;             Both routines read a dir sector into FS_BUF_SECTOR via
;             _VolBlockRead without updating DIR_CACHE_SECTOR /
;             DIR_CACHE_DRIVE. Their callers always run _DirLookup first
;             (which leaves the cache identity matching the buffer), so
;             the read at the top of these routines re-reads the same
;             sector the cache already claims — accidentally consistent.
;
;             If a future caller invokes either routine in a state where
;             the cache identity points at a DIFFERENT dir sector (e.g.
;             multi-sector roots on D:), the buffer contents and cache
;             identity would disagree silently: subsequent _DirNextRaw
;             requesting the cache-claimed sector would skip the read
;             and parse wrong sector data as dirents.
;
;             Fix: after each _VolBlockRead of a dir sector, update
;             DIR_CACHE_SECTOR and DIR_CACHE_DRIVE to reflect what's now
;             in the buffer. This is the orthodox "we just brought this
;             sector in, mark it cached" pattern — matches _DirLookup's
;             handling at .dl_must_read.
;
;             Same bug family as the _ExecCopyChain r4 fix in
;             kos_fs_exec.asm (12 May 2026). Surfaced during the
;             FS_BUF_SECTOR audit that followed it. No active reproducer
;             today — both call sites currently chain off _DirLookup
;             which leaves the cache consistent — but the latency is
;             real and easy to close.
;
;           r7 — 11 May 2026 — Part 25: added sys_unlink (TRAP #37) and
;             sys_rename (TRAP #38), plus their kernel-internal helpers
;             _DeleteFile and _RenameFile.
;             • sys_unlink: parse path → _DirLookup → read first_cluster
;               from dirent → _FATFreeChain → _FATFlush → _DirDelete.
;               Errors: ERR_BADPATH, ERR_BADDRIVE, ERR_NOTFOUND, ERR_READONLY,
;               ERR_IO. Reuses existing infrastructure heavily; the only
;               new code is the dirent first-cluster extraction.
;             • sys_rename: same-drive only. Both paths parsed; their
;               drive bytes must match (else ERR_INVALID — kosh falls
;               back to cp+unlink in that case). _DirLookup on old name;
;               _DirLookup on new name (must miss → ERR_EXISTS if it
;               hits); RMW the dirent at old cookie, overwriting bytes
;               0..10 with the new 11-byte FAT name.
;             • Vector installs handled in kos_boot.asm r37.
;             • Both syscalls follow the non-leaf DINT/EINT-gated pattern,
;               preserve D2/D3/XY2 per V2 ABI.
;             • Note on safety: neither syscall checks whether the file
;               is currently open in some fd table. Documented as
;               "don't unlink/rename files open in another task".
;               Single-shell-single-user makes this tolerable.
;
;           r6 — 10 May 2026 — Part 22: sys_dirent iteration cache.
;             sys_dirent now caches the previous walk's end-cookie +
;             index + drive. A sequential sys_dirent(0), (1), (2), ...
;             pattern (kosh `ls` idiom) resumes from the saved cookie
;             with iterations=1 instead of restarting from cookie=0
;             with iterations=N+1. _DirNextRaw calls drops from
;             O(N²) to O(N) for an N-file directory.
;
;             Cache slots ($03BC..$03C0):
;               DIRENT_LAST_COOKIE  — word, $FFFF = empty
;               DIRENT_LAST_INDEX   — word
;               DIRENT_LAST_DRIVE   — byte
;
;             Invalidated by: non-sequential sys_dirent (different drive
;             or index jump; falls through to full walk); _DirCreate /
;             _DirDelete; _FATInvalidate (now extended to clear all
;             three caches: FAT + dir-buffer + dirent-iteration).
;
;             Single-task today; multi-task (Phase 4+) needs per-task
;             state in TCB or per-FD state via OPEN_DIR/READ_DIR.
;
;           r5 — 9 May 2026 — Part 22: _ParsePath now accepts drive
;             letters A..F (was A..C). The 'C'+1 upper bound at the
;             pp_no_lc check was a hard limit on the path syntax,
;             separate from FS_MAX_DRIVES; bumped to 'F'+1 to expose
;             the new host-disk slots through path-based syscalls.
;             _SlotForDrive already uses FS_MAX_DRIVES so it picks
;             up the new bound automatically.
;
;           r4 — 8 May 2026 — FD_DIRENT_RAW moved from $039B (odd) to $039C
;             (even). Per Gotcha #30: Digital silently drops A0 on word
;             reads at odd addresses, returning garbage. _FatEntryToInfo
;             reads word fields at +$1A, +$1C, +$1E, +$16, +$18 — all
;             landed odd from the previous base.
;
;             Symptom: `ls` showed all file sizes as "BIG" on Digital
;             (high word non-zero garbage). EMU was unaffected.
;
;             Pad byte at $039B unused. FE_* slots in kos_fs_exec.asm
;             shifted +1 to match (kos_fs_exec.asm r2).
;
;           r3 — 8 May 2026 — All syscalls in this file now preserve D2 and
;             D3 across the call, per V2 ABI (D2/D3/XY2 callee-saved).
;             sys_open, sys_close, sys_read, sys_write, sys_dirent each get
;             PUSH D2/D3 at entry and POP D3/D2 at exit (after the SR-gated
;             EINT, before RET — POP Dn doesn't disturb flags).
;
;             sys_read and sys_write also had a more direct bug: `MOVE D2, Y0`
;             was used to copy the user-buffer page byte for stash, clobbering
;             D2 with a value that wasn't restored. Now uses D1 as scratch.
;             sys_dirent has the same `MOVE D2, Y0` but D2 is on the stack
;             at that point so the clobber is harmless once D2 is restored.
;
;             Bug originally surfaced as ERR_BADFD on the second back-to-back
;             read in kosh `cat`: cat stashed fd in D2, sys_read overwrote D2
;             (eventually with the new file position = 220), so the next
;             `MOVE D0, D2` passed 220 as fd → _FdValid rejected it.
;             Confirmed by adding NOP #$FF magic-NOP at .fv_bad and inspecting
;             registers at the breakpoint.
;
;             Other syscalls (kos_console.asm, kos_fs_exec.asm, KLIB) need the
;             same audit pass. ABI gotcha entry to be added to ISA_Gotchas.md.
;
;           r2 — 6 May 2026 — FD_DIRENT_RAW shifted $039B → $039C for word
;             alignment (Digital silently drops A0 on word reads at odd
;             addresses; EMU does not).
;
;           r1 — 6 May 2026 — initial. Provides:
;             • sys_open    (TRAP #26)
;             • sys_close   (TRAP #27)
;             • sys_read    (TRAP #28)
;             • sys_write   (TRAP #29)
;             • sys_dirent  (TRAP #30)
;
;           Plus internal helpers:
;             • _ParsePath           drive index + 11-byte FAT name
;             • _SlotForDrive        drive (0/1/2) → XY2 slot ptr
;             • _AllocFd             find first free slot in FD_TABLE
;             • _FdAddr              fd (0..7) → XY1 = slot ptr
;             • _FdValid             fd → C=0 if open, C=1 with ERR_BADFD
;             • _LoadDirentFromCookie read first-cluster + size from dirent
;             • _CreateEmptyEntry    new dirent (cluster=0, size=0)
;             • _TruncateExisting    free chain, rewrite dirent to empty
;             • _PatchDirentSizeCl   RMW dirent size + first-cluster
;             • _PopulateFd          fill in fd slot from open state
;             • _FdComputeReadChunk  min(count, sec_remain, file_remain)
;             • _FdComputeWriteChunk min(count, sec_remain)
;             • _FdReadCurrSector    read FD_CURR_CLUSTER's sector → buf
;             • _FdWriteCurrSector   write buf → FD_CURR_CLUSTER's sector
;             • _FdCopyToUser        FS_BUF_SECTOR → user
;             • _FdCopyFromUser      user → FS_BUF_SECTOR
;             • _FdAdvancePosition   pos += chunk; walk FAT if cross
;             • _FdEnsureCluster     for writes — alloc + chain if needed
;             • _FdFlushDirent       on close, RMW dirent with live size
;             • _RefreshDirSize      reload FD_DIR_SIZE_LO from on-disk dirent
;
; --- TRAP handler shape ----------------------------------------------------
;
; Per K16 ref Manual §6.11 and gotcha 4.6: TRAP does NOT push SR. Handlers
; return with plain RET. Flags carry success/error to caller. To protect
; FS state against the timer IRQ, each handler does:
;
;     sys_xxx:
;             DINT
;             ... body that sets D0 + C=0/1 ...
;             PUSH    SR, XY3              ; save body's C/Z
;             LOADZ   D1, [#KERNEL_STATE]
;             LOW     D1
;             CMP     D1, #KERN_STATE_RUN
;             BNE.S   .skip_eint
;             EINT
;     .skip_eint:
;             POP     SR, XY3              ; restore body's C/Z
;             RET
;
; The EINT-gate-on-KERNEL_STATE is mandatory (gotcha 4.6) — boot-context
; calls must not enable IRQs.
;
; --- File position model ---------------------------------------------------
;
; FD_POSITION is a byte offset held as two words: low at +$08, high at
; +$0A. Valid range is 24 bits (16 MB).
;
; THE HIGH WORD IS LIVE (Part 26). Until then it was always 0 and most
; sites operated on the low word alone; that capped every file in k/OS at
; 64 KB and did it silently, by wrapping. The ONLY legitimate 16-bit use
; of the position is `pos AND $01FF' (offset within a sector), which is
; correct on the low word because 512 divides 65536 exactly. Every other
; read of FD_POSITION must take BOTH words -- use _FdCmpPosSize to compare
; against FD_DIR_SIZE_LO/HI.
;
; FD_CURR_CLUSTER caches the cluster containing FD_POSITION. Sequential
; reads/writes only walk the FAT once per cluster boundary crossing.
;
; --- Cross-syscall scratch -------------------------------------------------
;
; FD_DIR_SIZE_LO scratch lives in page $00 ($0378) and is volatile across
; syscalls. sys_read/sys_write must reload it from the on-disk dirent
; at entry via _RefreshDirSize.
;
; --- Buffer assumption -----------------------------------------------------
;
; User buffer XY0 is page-local: the block backends advance X by 1 byte
; per byte and never adjust Y, so a buffer crossing a page boundary
; mid-transfer would corrupt memory. Phase 16 limit: callers keep
; buffers off the very end of their page.
;
; ============================================================================

; ============================================================================
; sys_open — TRAP #26 — open a file
;
;   In:    XY0 = path "X:NAME.EXT" or "dir/NAME.EXT" (nul-terminated)
;          D0  = open flags (FOPEN_READ|WRITE|CREATE|TRUNC|APPEND)
;          D1  = CWD cluster (0 = root)   — Part 44, for relative paths
;          D2  = CWD drive index          — Part 44, start drive when path
;                                            has no "X:" prefix
;   Out:   D0 = fd (0..7), C=0 on success
;          D0 = ERR_*, C=1 on failure
;   Note:  Part 44 — path is resolved relative to (D2:D1) via _ResolveParent.
;          An "X:" prefix in the path overrides D2. D1/D2 are callee-preserved
;          (read as inputs up front, restored on exit) per V2 ABI.
; ============================================================================
sys_open:
                DINT

                ; --- Per V2 ABI (Part 36 expansion):
                ; Register contract: see kos_defs.inc, SYSCALL REGISTER CONTRACT.
                ; Part 36 r2: PUSH D1 added — _DirLookup and other helpers
                ; clobber D1 internally on deep paths (NOTFOUND, IO, etc.)
                ; and the body uses page-zero TMPs rather than re-loading
                ; caller's D1, so D1 must be saved at the boundary.
                PUSH    D2, XY3
                PUSH    D3, XY3
                PUSH    XY1, XY3                    ; Part 36: V2 ABI
                PUSH    XY2, XY3                    ; Part 25: XY2 is the Pascal frame pointer
                PUSH    D1, XY3                     ; Part 36 r2

                ; Stash open flags.
                STOREZ  D0, [#FD_OPEN_FLAGS]

                ; Part 16: D2 = CWD_SELF -> resolve relative to THIS task's CWD.
                ; Load the running task's TCB_CWD_DRIVE/CLU into D2/D1. A real drive
                ; index or an "X:" prefix in the path bypasses this.
                CMP     D2, #CWD_SELF
                BNE     .so_cwd_ready
                LOADZ   D0, [#CURRENT_TCB]         ; D0 = running TCB offset (page $00)
                MOVE    X1, D0
                LOADI   Y1, #$00
                LOADI   D0, #TCB_CWD_DRIVE
                LOADD   D2, [XY1+D0]              ; D2 = task CWD drive
                LOADI   D0, #TCB_CWD_CLU
                LOADD   D1, [XY1+D0]              ; D1 = task CWD cluster
.so_cwd_ready:

                ; --- Part 44: resolve the PARENT of the path relative to CWD.
                ; _ResolveParent wants D0=start drive, D1=start clu, XY0=path.
                ; flags are already stashed; D2=CWD drive, D1=CWD clu (inputs).
                MOVE    D0, D2                      ; D0 = CWD drive (start drive)
                ; D1 already = CWD cluster (caller input)
                CALLR   _ResolveParent
                BCS     .so_err                     ; BADPATH/BADDRIVE/NOTFOUND/NOTDIR/IO
                ; D0 = drive (prefix or CWD), D1 = parent cluster;
                ; leaf 11-byte name in RV_FATNAME.
                STOREZB D0, [#FD_DRIVE_TMP]
                MOVE    D3, D0                      ; D3 = drive
                STOREZ  D1, [#FD_PARENT_CL]         ; parent clu -> carried to _PopulateFd

                ; Copy the leaf RV_FATNAME -> FD_NAMEBUF so the existing
                ; lookup/create path (which reads FD_NAMEBUF) sees the leaf.
                CALLR   _CopyLeafToNamebuf

                ; Resolve drive → slot ptr (XY2).
                MOVE    D0, D3
                CALLR   _SlotForDrive
                BCS     .so_err

                ; --- Bug fix (28 May 2026): gate write-ish opens against
                ; VOL_READONLY at the open boundary. Without this gate,
                ; FOPEN_CREATE on a read-only volume runs _CreateEmptyEntry,
                ; which calls _DirCreate and mutates the in-memory dir
                ; sector before the eventual block-write fails (or, on a
                ; host-disk-backed A:, silently succeeds — leaving a stray
                ; zero-length dirent on the read-only volume).
                ;
                ; Mask = FOPEN_WRITE($02) | FOPEN_CREATE($04) | FOPEN_TRUNC($08)
                ;      = $0E. Pure read opens (FOPEN_READ alone) still work
                ; on r/o volumes; only write-intent opens are blocked.
                LOADZ   D0, [#FD_OPEN_FLAGS]
                AND     D0, #$0E
                BEQ     .so_ro_ok
                LOADB   D0, [XY2+#VOL_READONLY]
                AND     D0, #$FF
                BEQ     .so_ro_ok
                LOADI   D0, #ERR_READONLY
                BRA     .so_err
.so_ro_ok:

                ; Part 44: operate inside the resolved parent directory.
                LOADZ   D0, [#FD_PARENT_CL]
                STOREZ  D0, [#DIR_WALK_CLU]

                ; Lookup name. Long-aware: matches by long name (RV_COMP) or by
                ; 8.3 (RV_FATNAME) when RV_SAVE_PAD=1 — both still set from the
                ; _ResolveParent above. A long dest has no usable FD_NAMEBUF, so
                ; the existence/dup check MUST go through here, not _DirLookup.
                CALLR   _DirLookupLong
                BCS     .so_lookup_failed

                ; --- Found ----------------------------------------------
                STOREZ  D0, [#FD_COOKIE_TMP]
                CALLR   _LoadDirentFromCookie
                BCS     .so_err

                ; O_TRUNC?
                LOADZ   D0, [#FD_OPEN_FLAGS]
                AND     D0, #FOPEN_TRUNC
                BEQ     .so_no_trunc
                ; Trunc only if also write-permission requested (silent ignore otherwise).
                LOADZ   D0, [#FD_OPEN_FLAGS]
                AND     D0, #FOPEN_WRITE
                BEQ     .so_no_trunc
                CALLR   _TruncateExisting
                BCS     .so_err
.so_no_trunc:
                BRA     .so_have_dirent

.so_lookup_failed:
                ; D0 = ERR_NOTFOUND or ERR_IO.
                CMP     D0, #ERR_NOTFOUND
                BNE     .so_err                 ; ERR_IO → propagate
                LOADZ   D0, [#FD_OPEN_FLAGS]
                AND     D0, #FOPEN_CREATE
                BEQ     .so_err_notfound
                ; Part 44: re-assert parent dir for the create (defensive;
                ; _DirLookup does not reset DIR_WALK_CLU today, but make it
                ; explicit — mirrors sys_mkdir before _DirCreate).
                LOADZ   D0, [#FD_PARENT_CL]
                STOREZ  D0, [#DIR_WALK_CLU]
                CALLR   _CreateEmptyEntry
                BCS     .so_err

.so_have_dirent:
                ; Allocate fd.
                CALLR   _AllocFd                ; D0=fd, XY1=slot, FD_RESULT_TMP=fd
                BCS     .so_err

                ; Populate slot from open state.
                CALLR   _PopulateFd

                ; Return fd in D0.
                LOADZB  D0, [#FD_RESULT_TMP]
                AND     D0, #$FF
                CLC
                BRA     .so_done

.so_err_notfound:
                LOADI   D0, #ERR_NOTFOUND
                SEC
                BRA     .so_done

.so_err:
                ; D0 already holds err code, C=1.
                SEC

.so_done:
                ; Part 44: restore DIR_WALK_CLU to the root default. Preserve
                ; the result code in D0 across the store; the EINT gate's
                ; PUSH/POP SR carries the result carry through (same structure
                ; as sys_mkdir .mkd_exit).
                PUSH    D0, XY3
                LOADI   D0, #0
                STOREZ  D0, [#DIR_WALK_CLU]
                POP     D0, XY3

                ; Gate EINT on KERNEL_STATE (gotcha 4.6).
                ; Part 36: stash D0 (the return value) across the gate
                ; because D1 is now callee-preserved per V2 ABI.
                PUSH    SR, XY3
                PUSH    D0, XY3
                LOADZ   D0, [#KERNEL_STATE]
                LOW     D0
                CMP     D0, #KERN_STATE_RUN
                POP     D0, XY3
                BNE.S   .so_skip_eint
                EINT
.so_skip_eint:
                POP     SR, XY3

                ; Restore callee-saved D1, XY1, D3, D2.
                POP     D1, XY3                     ; Part 36 r2
                POP     XY2, XY3                    ; Part 25: XY2 is the Pascal frame pointer
                POP     XY1, XY3                    ; Part 36: V2 ABI
                POP     D3, XY3
                POP     D2, XY3
                RET

; ============================================================================
; sys_close — TRAP #27 — close a file
;
;   In:    D0 = fd
;   Out:   C=0 on success, D0 = 0
;          C=1 with D0 = ERR_BADFD or ERR_IO
; ============================================================================
sys_close:
                DINT

                ; --- Per V2 ABI (Part 36 expansion):
                ; Register contract: see kos_defs.inc, SYSCALL REGISTER CONTRACT.
                ; Part 36 r2: PUSH D1 added — _FdFlushDirent and other
                ; helpers clobber D1 internally on deep paths.
                PUSH    D2, XY3
                PUSH    D3, XY3
                PUSH    XY1, XY3                    ; Part 36: V2 ABI
                PUSH    XY2, XY3                    ; Part 25: XY2 is the Pascal frame pointer
                PUSH    D1, XY3                     ; Part 36 r2

                CALLR   _FdValid                ; XY1 = slot
                BCS     .sc_err

                ; If FD_FLAG_DIRTY, flush dirent.
                LOADB   D0, [XY1+#FD_FLAGS]
                AND     D0, #$FF
                AND     D0, #FD_FLAG_DIRTY
                BEQ     .sc_no_flush

                ; Set up XY2 = slot for the flush.
                LOADB   D3, [XY1+#FD_DRIVE]
                AND     D3, #$FF
                MOVE    D0, D3
                CALLR   _SlotForDrive
                BCS     .sc_err                 ; should never happen

                ; Re-derive XY1 (SlotForDrive preserves it but cheap to be safe).
                LOADZB  D0, [#FD_RESULT_TMP]
                AND     D0, #$FF
                CALLR   _FdAddr

                CALLR   _FdFlushDirent
                BCS     .sc_err

                ; Re-derive XY1 again — _FdFlushDirent uses block I/O.
                LOADZB  D0, [#FD_RESULT_TMP]
                AND     D0, #$FF
                CALLR   _FdAddr

.sc_no_flush:
                ; Clear FD_FLAGS to mark slot free.
                LOADI   D0, #0
                STOREB  D0, [XY1+#FD_FLAGS]

                LOADI   D0, #ERR_OK
                CLC
                BRA     .sc_done

.sc_err:
                SEC

.sc_done:
                ; Part 36: stash D0 (return) across EINT gate; D1 is now
                ; callee-preserved per V2 ABI.
                PUSH    SR, XY3
                PUSH    D0, XY3
                LOADZ   D0, [#KERNEL_STATE]
                LOW     D0
                CMP     D0, #KERN_STATE_RUN
                POP     D0, XY3
                BNE.S   .scd_skip_eint
                EINT
.scd_skip_eint:
                POP     SR, XY3

                ; Restore callee-saved D1, XY1, D3, D2.
                POP     D1, XY3                     ; Part 36 r2
                POP     XY2, XY3                    ; Part 25: XY2 is the Pascal frame pointer
                POP     XY1, XY3                    ; Part 36: V2 ABI
                POP     D3, XY3
                POP     D2, XY3
                RET

; ============================================================================
; sys_read — TRAP #28 — read from file
;
;   In:    D0 = fd, D1 = count, XY0 = dest buffer
;   Out:   D0 = bytes read, C=0 (D0=0 means EOF)
;          D0 = ERR_*, C=1
; ============================================================================
sys_read:
                DINT

                ; --- Per V2 ABI (Part 36 expansion):
                ; Register contract: see kos_defs.inc, SYSCALL REGISTER CONTRACT —
                ; *except* when documented as input/return registers.
                ; D1 is the count input arg here, legitimately consumed.
                PUSH    D2, XY3
                PUSH    D3, XY3
                PUSH    XY1, XY3                    ; Part 36: V2 ABI
                PUSH    XY2, XY3                    ; Part 25: XY2 is the Pascal frame pointer

                ; Stash count + user buf BEFORE _FdValid (which clobbers D1).
                STOREZ  D1, [#FD_COUNT_TMP]
                STOREZ  X0, [#FD_USERBUF_X]
                MOVE    D1, Y0                  ; D1 = caller's user-buf page byte
                STOREZB D1, [#FD_USERBUF_Y]
                LOADI   D1, #0
                STOREZ  D1, [#FD_BYTES_DONE]

                CALLR   _FdValid                ; XY1=slot, FD_RESULT_TMP=fd
                BCS     .sr_err

                ; Validate readable.
                LOADB   D0, [XY1+#FD_FLAGS]
                AND     D0, #$FF
                AND     D0, #FD_FLAG_READ
                BEQ     .sr_badfd

                ; Drive → XY2.
                LOADB   D3, [XY1+#FD_DRIVE]
                AND     D3, #$FF
                MOVE    D0, D3
                CALLR   _SlotForDrive
                BCS     .sr_err

                ; Re-derive XY1.
                LOADZB  D0, [#FD_RESULT_TMP]
                AND     D0, #$FF
                CALLR   _FdAddr

                ; Refresh size from on-disk dirent (volatile across syscalls).
                CALLR   _RefreshDirSize         ; uses XY1's FD_DIR_COOKIE
                BCS     .sr_err

                ; Re-derive XY1 (_RefreshDirSize uses block I/O).
                LOADZB  D0, [#FD_RESULT_TMP]
                AND     D0, #$FF
                CALLR   _FdAddr

.sr_loop:
                LOADZ   D0, [#FD_COUNT_TMP]
                CMP     D0, #0                  ; LOAD doesn't set flags; explicit CMP needed
                BEQ     .sr_done

                CALLR   _FdComputeReadChunk     ; D0 = chunk (0 = EOF)
                BCS     .sr_err
                CMP     D0, #0
                BEQ     .sr_done
                STOREZ  D0, [#FD_CHUNK_TMP]

                CALLR   _FdReadCurrSector       ; clobbers XY1
                BCS     .sr_err
                LOADZB  D0, [#FD_RESULT_TMP]
                AND     D0, #$FF
                CALLR   _FdAddr

                CALLR   _FdCopyToUser           ; clobbers XY1

                ; Re-derive XY1 for advance.
                LOADZB  D0, [#FD_RESULT_TMP]
                AND     D0, #$FF
                CALLR   _FdAddr

                LOADZ   D0, [#FD_CHUNK_TMP]
                CALLR   _FdAdvancePosition
                BCS     .sr_err

                ; Bookkeeping.
                LOADZ   D0, [#FD_CHUNK_TMP]
                LOADZ   D1, [#FD_COUNT_TMP]
                SUB     D1, D0
                STOREZ  D1, [#FD_COUNT_TMP]
                LOADZ   D1, [#FD_BYTES_DONE]
                ADD     D1, D0
                STOREZ  D1, [#FD_BYTES_DONE]
                LOADZ   D1, [#FD_USERBUF_X]
                ADD     D1, D0
                STOREZ  D1, [#FD_USERBUF_X]

                BRA     .sr_loop

.sr_badfd:
                LOADI   D0, #ERR_BADFD
                SEC
                BRA     .sr_done2

.sr_err:
                SEC
                BRA     .sr_done2

.sr_done:
                LOADZ   D0, [#FD_BYTES_DONE]
                CLC

.sr_done2:
                PUSH    SR, XY3
                LOADZ   D1, [#KERNEL_STATE]
                LOW     D1
                CMP     D1, #KERN_STATE_RUN
                BNE.S   .srd_skip_eint
                EINT
.srd_skip_eint:
                POP     SR, XY3

                ; Restore callee-saved XY1, D3, D2 (reverse of prologue PUSH).
                POP     XY2, XY3                    ; Part 25: XY2 is the Pascal frame pointer
                POP     XY1, XY3                    ; Part 36: V2 ABI
                POP     D3, XY3
                POP     D2, XY3
                RET

; ============================================================================
; sys_write — TRAP #29 — write to file
;
;   In:    D0 = fd, D1 = count, XY0 = source buffer
;   Out:   C=0 success:
;            D0 = bytes written (== count)
;            D1 = bytes written (same as D0)
;          C=1 failure:
;            D0 = error code (ERR_BADFD / ERR_READONLY / ERR_NOSPACE /
;                 ERR_IO / etc.)
;            D1 = bytes successfully written BEFORE the failure (0 if
;                 the error fired before any data was committed)
;
;   The D1 partial-count is a Part 34 addition. Pre-Part 34 callers
;   ignored D1 on C=1; they keep working unchanged. New callers that
;   care about partial writes (e.g. kosh's load command on ENOSPC) can
;   now report "X of Y bytes written before disk full".
; ============================================================================
sys_write:
                DINT

                ; --- Per V2 ABI (Part 36 expansion):
                ; Register contract: see kos_defs.inc, SYSCALL REGISTER CONTRACT —
                ; *except* when documented as input/return registers.
                ; D1 is both input arg (count) and return register
                ; (bytes-written), legitimately consumed/produced.
                PUSH    D2, XY3
                PUSH    D3, XY3
                PUSH    XY1, XY3                    ; Part 36: V2 ABI
                PUSH    XY2, XY3                    ; Part 25: XY2 is the Pascal frame pointer

                ; Stash count + user buf BEFORE _FdValid (which clobbers D1).
                STOREZ  D1, [#FD_COUNT_TMP]
                STOREZ  X0, [#FD_USERBUF_X]
                MOVE    D1, Y0                  ; D1 = caller's user-buf page byte
                STOREZB D1, [#FD_USERBUF_Y]
                LOADI   D1, #0
                STOREZ  D1, [#FD_BYTES_DONE]

                CALLR   _FdValid                ; XY1=slot
                BCS     .sw_err

                ; Validate writable.
                LOADB   D0, [XY1+#FD_FLAGS]
                AND     D0, #$FF
                AND     D0, #FD_FLAG_WRITE
                BEQ     .sw_badfd

                ; Drive → XY2.
                LOADB   D3, [XY1+#FD_DRIVE]
                AND     D3, #$FF
                MOVE    D0, D3
                CALLR   _SlotForDrive
                BCS     .sw_err

                ; Re-derive XY1.
                LOADZB  D0, [#FD_RESULT_TMP]
                AND     D0, #$FF
                CALLR   _FdAddr

                ; Read-only volume?
                LOADB   D0, [XY2+#VOL_READONLY]
                AND     D0, #$FF
                BNE     .sw_readonly

                ; Refresh dirent size — for size growth tracking.
                CALLR   _RefreshDirSize
                BCS     .sw_err
                LOADZB  D0, [#FD_RESULT_TMP]
                AND     D0, #$FF
                CALLR   _FdAddr

.sw_loop:
                LOADZ   D0, [#FD_COUNT_TMP]
                CMP     D0, #0                  ; LOAD doesn't set flags; explicit CMP needed
                BEQ     .sw_done

                ; --- 24-bit position limit (Part 26) ----------------------
                ; FD_POSITION's high word is live now, but _FdAdvancePosition's
                ; block index assumes it stays <= $FF (blk = hi*128 + blk_lo
                ; must fit a word). Refuse at 16 MB rather than wrap silently,
                ; which is exactly what the old 16-bit position did at 64 KB.
                ; Tested per chunk, at the top: FD_BYTES_DONE is already
                ; correct here, so .sw_done2 reports the partial count.
                LOADD   D0, [XY1+#FD_POSITION+2]
                CMP     D0, #$0100
                BHS     .sw_toobig

                ; Ensure FD_CURR_CLUSTER is allocated and ready.
                CALLR   _FdEnsureCluster
                BCS     .sw_err
                LOADZB  D0, [#FD_RESULT_TMP]
                AND     D0, #$FF
                CALLR   _FdAddr

                CALLR   _FdComputeWriteChunk    ; D0 = chunk
                STOREZ  D0, [#FD_CHUNK_TMP]

                ; Always RMW (simplest; optimisation later).
                CALLR   _FdReadCurrSector
                BCS     .sw_err
                LOADZB  D0, [#FD_RESULT_TMP]
                AND     D0, #$FF
                CALLR   _FdAddr

                CALLR   _FdCopyFromUser

                ; Re-derive (CopyFromUser clobbers XY1).
                LOADZB  D0, [#FD_RESULT_TMP]
                AND     D0, #$FF
                CALLR   _FdAddr

                CALLR   _FdWriteCurrSector
                BCS     .sw_err
                LOADZB  D0, [#FD_RESULT_TMP]
                AND     D0, #$FF
                CALLR   _FdAddr

                LOADZ   D0, [#FD_CHUNK_TMP]
                CALLR   _FdAdvancePositionAndSize
                BCS     .sw_err
                LOADZB  D0, [#FD_RESULT_TMP]
                AND     D0, #$FF
                CALLR   _FdAddr

                ; Mark FD_FLAG_DIRTY.
                LOADB   D0, [XY1+#FD_FLAGS]
                AND     D0, #$FF
                OR      D0, #FD_FLAG_DIRTY
                STOREB  D0, [XY1+#FD_FLAGS]

                ; Bookkeeping.
                LOADZ   D0, [#FD_CHUNK_TMP]
                LOADZ   D1, [#FD_COUNT_TMP]
                SUB     D1, D0
                STOREZ  D1, [#FD_COUNT_TMP]
                LOADZ   D1, [#FD_BYTES_DONE]
                ADD     D1, D0
                STOREZ  D1, [#FD_BYTES_DONE]
                LOADZ   D1, [#FD_USERBUF_X]
                ADD     D1, D0
                STOREZ  D1, [#FD_USERBUF_X]

                BRA     .sw_loop

.sw_badfd:
                LOADI   D0, #ERR_BADFD
                SEC
                BRA     .sw_done2

.sw_readonly:
                LOADI   D0, #ERR_READONLY
                SEC
                BRA     .sw_done2

.sw_toobig:
                ; Part 26. ERR_TOOBIG is shared with sys_spawn's length check;
                ; the family is right (a value beyond what the call can
                ; represent) and it is distinct from ERR_NOSPACE, which means
                ; the VOLUME is full rather than the file being too long.
                LOADI   D0, #ERR_TOOBIG
                SEC
                BRA     .sw_done2

.sw_err:
                SEC
                BRA     .sw_done2

.sw_done:
                LOADZ   D0, [#FD_BYTES_DONE]
                CLC

.sw_done2:
                ; Part 34 partial-write reporting:
                ; On C=1 the caller gets D0 = err code AND D1 = bytes
                ; written before failure (read from FD_BYTES_DONE, which
                ; is initialised to 0 at entry so the early-exit paths
                ; .sw_badfd / .sw_readonly correctly return D1=0).
                ; On C=0, D1 = bytes written (== requested count); same
                ; value as D0 in that case, but kept consistent so a
                ; caller can read "D1 = always the byte count" regardless
                ; of C.
                LOADZ   D1, [#FD_BYTES_DONE]

                ; Gate EINT on KERNEL_STATE (gotcha 4.6).
                ;   PUSH SR  saves our C flag (clobbered by the CMP below).
                ;   PUSH D1  saves the bytes-done return value (kernel-state
                ;            check uses D1 as scratch).
                PUSH    SR, XY3
                PUSH    D1, XY3
                LOADZ   D1, [#KERNEL_STATE]
                LOW     D1
                CMP     D1, #KERN_STATE_RUN
                BNE.S   .swd_skip_eint
                EINT
.swd_skip_eint:
                POP     D1, XY3                 ; restore bytes-done
                POP     SR, XY3                 ; restore C flag

                ; Restore callee-saved XY1, D3, D2.
                POP     XY2, XY3                    ; Part 25: XY2 is the Pascal frame pointer
                POP     XY1, XY3                    ; Part 36: V2 ABI
                POP     D3, XY3
                POP     D2, XY3
                RET

; ============================================================================
; sys_dirent — TRAP #30 — read N-th visible entry from a directory
;
;   In:    D0 = drive (0=A:, 1=B:)
;          D1 = index (0-based)
;          D2 = start cluster (0 = root region; >= 2 = subdirectory)
;             Phase 2a: lets ls/glob list a subdirectory or the CWD.
;          XY0 = 32-byte DIRENT_INFO destination (in caller's page)
;   Out:   C=0 on success
;          C=1 with D0 = ERR_NOMORE / ERR_BADDRIVE / ERR_IO
;
;   Strategy: iterate _DirNext (index+1) times into a kernel scratch
;   buffer (FD_DIRENT_RAW), then translate the last raw 32-byte FAT
;   directory entry into the DIRENT_INFO layout and copy to user buf.
; ============================================================================
sys_dirent:
                DINT

                ; --- Per V2 ABI (Part 36 expansion):
                ; Register contract: see kos_defs.inc, SYSCALL REGISTER CONTRACT —
                ; *except* when documented as input/return registers.
                ; D1 = index input. D2 = start cluster input (Phase 2a: 0=root,
                ; >=2 = subdir). Both legitimately consumed, so D2 is no longer
                ; preserved. D3, XY1 still preserved.
                PUSH    D3, XY3
                PUSH    XY1, XY3                    ; Part 36: V2 ABI
                PUSH    XY2, XY3                    ; Part 25: XY2 is the Pascal frame pointer

                ; Stash drive (D0), index (D1), cluster (D2), user buf (XY0).
                STOREZB D0, [#FD_DRIVE_TMP]
                STOREZ  D1, [#FD_INDEX_TMP]
                STOREZ  D2, [#DIR_WALK_CLU]         ; iterate this directory
                STOREZ  X0, [#FD_USERBUF_X]
                MOVE    D2, Y0                  ; D2 saved (no longer preserved)
                STOREZB D2, [#FD_USERBUF_Y]

                ; Resolve drive → XY2.
                LOADZB  D0, [#FD_DRIVE_TMP]
                AND     D0, #$FF
                CALLR   _SlotForDrive
                BCS     .sd_err

                LOADZB  D3, [#FD_DRIVE_TMP]
                AND     D3, #$FF

                ; --- Dirent iteration cache check (Part 22 + Phase 2a) ---
                ; Resume only if previous successful sys_dirent was the same
                ; drive, same start cluster, and index = (this index - 1).
                ; The CLUSTER key (Phase 2a) is essential: without it, listing
                ; root then a subdir at the same indices would resume in the
                ; wrong directory.
                LOADZ   D0, [#DIRENT_LAST_COOKIE]
                CMP     D0, #$FFFF
                BEQ     .sd_full_walk           ; cache empty
                LOADZB  D2, [#DIRENT_LAST_DRIVE]
                CMP     D2, D3
                BNE     .sd_full_walk           ; different drive
                ; same start cluster?
                LOADZ   D2, [#DIRENT_LAST_CLU]
                LOADZ   D1, [#DIR_WALK_CLU]
                CMP     D2, D1
                BNE     .sd_full_walk           ; different directory
                LOADZ   D2, [#DIRENT_LAST_INDEX]
                ADD     D2, #1
                LOADZ   D1, [#FD_INDEX_TMP]
                CMP     D2, D1
                BNE     .sd_full_walk           ; non-sequential index

                ; Cache hit. D0 = saved cookie (already loaded above).
                LOADI   D1, #1
                BRA     .sd_iter

.sd_full_walk:
                ; Set up cookie=0 and loop count=index+1.
                LOADI   D0, #0                  ; cookie
                LOADZ   D1, [#FD_INDEX_TMP]
                ADD     D1, #1                  ; iterations remaining

.sd_iter:
                ; XY1 = kernel scratch buffer (raw 32-byte FAT entry).
                LOADI   Y1, #$00
                LOADI   X1, #FD_DIRENT_RAW

                PUSH    D1, XY3                 ; save loop counter
                CALLR   _DirNext
                ; D0 = next cookie or err code; C=0/1
                BCS     .sd_iter_failed

                POP     D1, XY3
                SUB     D1, #1
                BNE     .sd_iter

                ; Walk done. D0 = cookie immediately AFTER the matched entry.
                ; Stash for next time's cache lookup (drive + index + cluster).
                STOREZ  D0, [#DIRENT_LAST_COOKIE]
                LOADZ   D1, [#FD_INDEX_TMP]
                STOREZ  D1, [#DIRENT_LAST_INDEX]
                STOREZB D3, [#DIRENT_LAST_DRIVE]
                LOADZ   D1, [#DIR_WALK_CLU]
                STOREZ  D1, [#DIRENT_LAST_CLU]

                ; Convert raw entry → DIRENT_INFO into user buffer.
                CALLR   _FatEntryToInfo
                LOADI   D0, #ERR_OK
                CLC
                BRA     .sd_done

.sd_iter_failed:
                ; D0 has error from _DirNext. Drop loop counter.
                POP     D1, XY3
                ; Invalidate the iteration cache — we're past the end of
                ; the directory or hit an IO error; either way the next
                ; sys_dirent should start fresh.
                LOADI   D2, #$FFFF
                STOREZ  D2, [#DIRENT_LAST_COOKIE]
                SEC
                BRA     .sd_done

.sd_err:
                SEC

.sd_done:
                PUSH    SR, XY3
                LOADZ   D1, [#KERNEL_STATE]
                LOW     D1
                CMP     D1, #KERN_STATE_RUN
                BNE.S   .sdd_skip_eint
                EINT
.sdd_skip_eint:
                POP     SR, XY3

                ; Reset DIR_WALK_CLU to the root-region default so unrelated
                ; later callers (that don't set it) still see root.
                PUSH    D0, XY3
                LOADI   D0, #0
                STOREZ  D0, [#DIR_WALK_CLU]
                POP     D0, XY3

                ; Restore callee-saved XY1, D3. (D2 is now an input arg —
                ; consumed, not preserved.)
                POP     XY2, XY3                    ; Part 25: XY2 is the Pascal frame pointer
                POP     XY1, XY3                    ; Part 36: V2 ABI
                POP     D3, XY3
                RET

; ============================================================================
; ----------------------- INTERNAL HELPERS ---------------------------------
; ============================================================================

; ============================================================================
; _ParsePath — "X:NAME.EXT" → drive index + 11-byte FAT name
;
;   In:    XY0 = path (nul-terminated)
;          XY1 = 11-byte destination
;   Out:   C=0 with D3 = drive, [XY1..+10] = FAT name
;          C=1 with D0 = ERR_BADPATH
;   Clobbers: D0, D1, D2, D3, X0, X1, flags
;   Preserves: Y0, Y1, XY2, XY3
; ============================================================================
_ParsePath:
                LOADB   D0, [XY0]
                AND     D0, #$FF
                BEQ     .pp_bad

                ; Uppercase a..z.
                CMP     D0, #'a'
                BLO.S   .pp_no_lc
                CMP     D0, #$7B                ; 'z'+1
                BHS.S   .pp_no_lc
                SUB     D0, #$20
.pp_no_lc:
                CMP     D0, #'A'
                BLO     .pp_bad
                CMP     D0, #$47                ; 'F'+1 = $47 (Part 22: A..F)
                BHS     .pp_bad
                SUB     D0, #'A'
                MOVE    D3, D0                  ; D3 = drive (0..5)

                ADD     X0, #1
                LOADB   D0, [XY0]
                AND     D0, #$FF
                CMP     D0, #':'
                BNE     .pp_bad

                ADD     X0, #1
                ; XY0 → "NAME.EXT", XY1 → 11-byte dest.
                ; _DirNameToFat preserves D3.
                CALLR   _DirNameToFat
                BCS     .pp_bad
                RETCC

.pp_bad:
                LOADI   D0, #ERR_BADPATH
                RETCS

; ============================================================================
; _CopyLeafToNamebuf — copy the 11-byte resolver leaf into FD_NAMEBUF
;
;   Part 44. _ResolveParent leaves the final path component as an 11-byte
;   space-padded FAT name in RV_FATNAME. The fd open path (and _CreateEmptyEntry)
;   read the name from FD_NAMEBUF, so copy it across once after a resolve.
;
;   In:    (RV_FATNAME holds 11-byte FAT name)
;   Out:   FD_NAMEBUF holds the same 11 bytes
;   Clobbers: D0, D1, X0, X1, Y0, Y1, flags
;   Preserves: D2, D3, XY2, XY3
;   Both buffers live in the kernel page (page $00).
; ============================================================================
_CopyLeafToNamebuf:
                LOADI   Y0, #$00
                LOADI   X0, #RV_FATNAME
                LOADI   Y1, #$00
                LOADI   X1, #FD_NAMEBUF
                LOADI   D1, #11
.cln_loop:
                LOADB   D0, [XY0]+
                STOREB  D0, [XY1]+
                SUB     D1, #1
                BNE     .cln_loop
                RET

; ============================================================================
; _CopyLeafToNamebuf2 — copy the 11-byte resolver leaf into FD_NAMEBUF2
;
;   Part 44. Sibling of _CopyLeafToNamebuf used by _RenameFile for the new
;   name (the old name already occupies FD_NAMEBUF).
;
;   In:    (RV_FATNAME holds 11-byte FAT name)
;   Out:   FD_NAMEBUF2 holds the same 11 bytes
;   Clobbers: D0, D1, X0, X1, Y0, Y1, flags
;   Preserves: D2, D3, XY2, XY3
; ============================================================================
_CopyLeafToNamebuf2:
                LOADI   Y0, #$00
                LOADI   X0, #RV_FATNAME
                LOADI   Y1, #$00
                LOADI   X1, #FD_NAMEBUF2
                LOADI   D1, #11
.cln2_loop:
                LOADB   D0, [XY0]+
                STOREB  D0, [XY1]+
                SUB     D1, #1
                BNE     .cln2_loop
                RET

; ============================================================================
; _SlotForDrive — drive index → volume slot pointer
;
;   In:    D0 = drive (0..2)
;   Out:   C=0 with XY2 = slot ptr (mounted slot)
;          C=1 with D0 = ERR_BADDRIVE
;   Clobbers: D0, X2, flags
;   Preserves: D1, D2, D3, Y0, Y1, X0, X1, XY3
; ============================================================================
_SlotForDrive:
                CMP     D0, #FS_MAX_DRIVES
                BHS     .sfd_bad

                ; X2 = drive << 6 = drive * 64
                SHL     D0, #6
                MOVE    X2, D0
                ADD     X2, #VOL_TABLE_BASE
                LOADI   Y2, #$00

                LOADB   D0, [XY2+#VOL_PRESENT]
                AND     D0, #$FF
                BEQ     .sfd_bad

                RETCC

.sfd_bad:
                LOADI   D0, #ERR_BADDRIVE
                RETCS

; ============================================================================
; _AllocFd — find first free fd slot
;
;   In:    (none)
;   Out:   C=0 with D0 = fd, XY1 = slot ptr; FD_RESULT_TMP = fd
;          C=1 with D0 = ERR_NOFD
;   Clobbers: D0, D1, X1, Y1, flags
;   Preserves: D2, D3, Y0, X0, XY2, XY3
; ============================================================================
_AllocFd:
                LOADI   D0, #0
                MOVE    Y1, Y3                  ; fd table lives in caller's task page
                LOADI   X1, #FD_TABLE
.af_loop:
                LOADB   D1, [XY1+#FD_FLAGS]
                AND     D1, #$FF
                AND     D1, #FD_FLAG_OPEN
                BEQ     .af_found

                ADD     D0, #1
                CMP     D0, #FD_COUNT
                BHS     .af_full
                ADD     X1, #FD_ENTRY_SIZE
                BRA     .af_loop

.af_found:
                STOREZB D0, [#FD_RESULT_TMP]
                RETCC

.af_full:
                LOADI   D0, #ERR_NOFD
                RETCS

; ============================================================================
; _FdAddr — fd → slot ptr (no validation)
;
;   In:    D0 = fd
;   Out:   XY1 = Y3:FD_TABLE + fd*FD_ENTRY_SIZE (fd table lives in caller's task page)
;   Clobbers: D1, X1, Y1, flags
;   Preserves: D0, D2, D3, X0, Y0, XY2, XY3
; ============================================================================
_FdAddr:
                MOVE    Y1, Y3                  ; fd table is per-task
                LOADI   X1, #FD_TABLE
                PUSH    D0, XY3
                LOADI   D1, #FD_ENTRY_SIZE
.fa_loop:
                CMP     D0, #0
                BEQ     .fa_done
                ADD     X1, D1
                SUB     D0, #1
                BRA     .fa_loop
.fa_done:
                POP     D0, XY3
                RET

; ============================================================================
; _FdValid — fd in range AND open
;
;   In:    D0 = fd
;   Out:   C=0 with XY1 = slot; FD_RESULT_TMP = fd
;          C=1 with D0 = ERR_BADFD
;   Clobbers: D0, D1, X1, Y1, flags
;   Preserves: D2, D3, X0, Y0, XY2, XY3
; ============================================================================
_FdValid:
                CMP     D0, #FD_COUNT
                BHS     .fv_bad
                STOREZB D0, [#FD_RESULT_TMP]
                CALLR   _FdAddr
                LOADB   D1, [XY1+#FD_FLAGS]
                AND     D1, #$FF
                AND     D1, #FD_FLAG_OPEN
                BEQ     .fv_bad
                RETCC
.fv_bad:
                LOADI   D0, #ERR_BADFD
                RETCS

; ============================================================================
; _LoadDirentFromCookie — read first-cluster + size from dirent
;
;   In:    D0 = cookie
;          XY2 = vol slot
;          D3  = drive
;   Out:   FD_DIR_FIRST_CL, FD_DIR_SIZE_LO, FD_DIR_SIZE_HI populated
;          C=0 / C=1 with D0=ERR_IO on read failure
;   Clobbers: D0, D1, D2, X0, X1, Y0, Y1, flags
;   Preserves: D3, XY2, XY3
; ============================================================================
_LoadDirentFromCookie:
                MOVE    D1, D0
                SHR4    D1                      ; sec_off
                MOVE    D2, D0
                AND     D2, #$0F                ; ent_idx

                ; Part 44: the cookie's sec_off is directory-relative. Convert
                ; via _DirSecToAbs (DIR_WALK_CLU-aware) rather than the old
                ; root-only VOL_ROOT_START+sec_off. Caller MUST have set
                ; DIR_WALK_CLU to the directory holding this entry (sys_open:
                ; parent cluster; _FdFlushDirent: fd's FD_DIR_CLUSTER).
                ; _DirSecToAbs: D1=sec_off -> D0=abs sec; preserves D1,D2,D3,XY2.
                CALLR   _DirSecToAbs
                BCS     .ldfc_io_nopush         ; failed before any PUSH — don't pop
                PUSH    D0, XY3                 ; r8: save abs sec across read
                PUSH    D2, XY3
                LOADI   Y0, #$00
                LOADI   X0, #FS_BUF_SECTOR
                CALLR   _VolBlockRead
                BCS     .ldfc_io
                POP     D2, XY3
                POP     D0, XY3                 ; r8: restore abs sec

                ; r8: update dir cache identity. The buffer now holds
                ; abs_sec for drive D3; reflect that so the next
                ; _DirNextRaw / _DirLookup of the same sector hits.
                STOREZ  D0, [#DIR_CACHE_SECTOR]
                STOREZB D3, [#DIR_CACHE_DRIVE]

                ; Entry addr = FS_BUF_SECTOR + ent_idx*32
                MOVE    D0, D2
                SHL4    D0
                SHL     D0
                ADD     D0, #FS_BUF_SECTOR
                LOADI   Y1, #$00
                MOVE    X1, D0

                ; All these offsets ($1A, $1C, $1E) fit in IMM5.
                LOADD   D0, [XY1+#DIR_FIRST_CLUSTER_LO]
                STOREZ  D0, [#FD_DIR_FIRST_CL]

                LOADD   D0, [XY1+#DIR_FILE_SIZE]
                STOREZ  D0, [#FD_DIR_SIZE_LO]
                LOADD   D0, [XY1+#DIR_FILE_SIZE+2]
                STOREZ  D0, [#FD_DIR_SIZE_HI]

                RETCC

.ldfc_io:
                POP     D2, XY3
                POP     D0, XY3                 ; r8: discard saved abs sec
.ldfc_io_nopush:
                LOADI   D0, #ERR_IO
                RETCS

; ============================================================================
; _CreateEmptyEntry — call _DirCreate then re-lookup for cookie
;
;   In:    XY2 = vol slot, D3 = drive, FD_NAMEBUF = 11-byte name
;   Out:   FD_COOKIE_TMP, FD_DIR_FIRST_CL=0, FD_DIR_SIZE_*=0
;          C=0 / C=1 with D0=ERR_*
;   Clobbers: D0, D1, D2, X0, X1, Y0, Y1, flags
;   Preserves: D3, XY2, XY3
; ============================================================================
_CreateEmptyEntry:
                ; Generate the short name from the long leaf (RV_COMP). needs_lfn
                ; tells us whether a full LFN run is required (a long name, or a
                ; clean 8.3 whose lower case must be preserved) or whether a plain
                ; short entry suffices. RV_COMP is set by the _ResolveParent that
                ; precedes every _CreateEmptyEntry caller.
                LOADI   Y0, #$00
                LOADI   X0, #RV_COMP
                CALLR   _GenShortName           ; -> LFN_SHORT[11], D0 = needs_lfn
                BCS     .cee_err
                CMP     D0, #0
                BNE     .cee_lfn

                ; --- plain 8.3 short entry --------------------------------
                LOADI   Y0, #$00
                LOADI   X0, #LFN_SHORT          ; canonical generated 8.3 name
                LOADI   D0, #0                  ; attr = 0
                LOADI   D1, #0                  ; cluster = 0
                LOADI   D2, #0                  ; size = 0
                CALLR   _DirCreate
                BCS     .cee_err
                BRA     .cee_relookup

.cee_lfn:
                ; --- LFN run: stage the long name into LFN_ASM, then write --
                CALLR   _CopyCompToLfnAsm       ; RV_COMP -> LFN_ASM, set LFN_ASM_LEN
                LOADI   D0, #0                  ; attr = 0
                LOADI   D1, #0                  ; cluster = 0
                LOADI   D2, #0                  ; size = 0
                CALLR   _DirCreateRun           ; writes the run; reads LFN_SHORT+LFN_ASM
                BCS     .cee_err

.cee_relookup:
                ; Re-find the entry to capture its cookie. Long-aware: matches by
                ; long name (RV_COMP) or 8.3 fallback (RV_FATNAME) — the cookie
                ; identifies the SHORT entry in both cases.
                CALLR   _DirLookupLong
                BCS     .cee_err

                STOREZ  D0, [#FD_COOKIE_TMP]
                LOADI   D0, #0
                STOREZ  D0, [#FD_DIR_FIRST_CL]
                STOREZ  D0, [#FD_DIR_SIZE_LO]
                STOREZ  D0, [#FD_DIR_SIZE_HI]
                RETCC

.cee_err:
                RETCS

; ============================================================================
; _TruncateExisting — free chain, zero size, rewrite dirent
;
;   In:    XY2, D3, FD_DIR_FIRST_CL (populated by _LoadDirentFromCookie)
;          FD_COOKIE_TMP
;   Out:   FD_DIR_FIRST_CL=0, FD_DIR_SIZE_*=0; on-disk dirent updated
;          C=0 / C=1 with D0=ERR_IO
;   Clobbers: D0, D1, D2, X0, X1, Y0, Y1, flags
;   Preserves: D3, XY2, XY3
; ============================================================================
_TruncateExisting:
                LOADZ   D1, [#FD_DIR_FIRST_CL]
                CMP     D1, #CLUSTER_FIRST_VALID
                BLO     .te_chain_done

.te_walk:
                ; D1 = current cluster. _FATGetEntry clobbers D1, so stash.
                MOVE    D0, D1
                PUSH    D1, XY3                 ; save current
                CALLR   _FATGetEntry            ; D0 = next; clobbers D1
                BCS     .te_io_pop
                MOVE    D2, D0                  ; D2 = next
                POP     D1, XY3                 ; restore current
                MOVE    D0, D1                  ; D0 = current for FreeCluster
                CALLR   _FreeCluster
                BCS     .te_io
                MOVE    D1, D2
                CMP     D1, #FAT_EOC_MIN
                BHS     .te_chain_done
                CMP     D1, #CLUSTER_FIRST_VALID
                BLO     .te_chain_done
                BRA     .te_walk

.te_io_pop:
                POP     D1, XY3                 ; balance the stack
                BRA     .te_io

.te_chain_done:
                CALLR   _FATFlush
                BCS     .te_io

                LOADI   D0, #0
                STOREZ  D0, [#FD_DIR_FIRST_CL]
                STOREZ  D0, [#FD_DIR_SIZE_LO]
                STOREZ  D0, [#FD_DIR_SIZE_HI]

                CALLR   _PatchDirentSizeCl
                BCS     .te_io
                RETCC

.te_io:
                LOADI   D0, #ERR_IO
                RETCS

; ============================================================================
; _PatchDirentSizeCl — RMW dirent: write FD_DIR_FIRST_CL + FD_DIR_SIZE_*
;
;   In:    XY2, D3, FD_COOKIE_TMP, FD_DIR_FIRST_CL, FD_DIR_SIZE_*
;   Out:   sector written back
;          C=0 / C=1 with D0=ERR_IO
;   Clobbers: D0, D1, D2, X0, X1, Y0, Y1, flags
;   Preserves: D3, XY2, XY3
; ============================================================================
_PatchDirentSizeCl:
                LOADZ   D0, [#FD_COOKIE_TMP]
                MOVE    D1, D0
                SHR4    D1                      ; sec_off
                MOVE    D2, D0
                AND     D2, #$0F                ; ent_idx

                ; Part 44: directory-relative -> absolute via _DirSecToAbs
                ; (DIR_WALK_CLU-aware). Caller (_FdFlushDirent / sys_open /
                ; _TruncateExisting) sets DIR_WALK_CLU to the entry's dir.
                CALLR   _DirSecToAbs           ; D1=sec_off -> D0=abs sec
                BCS     .pd_io_nopush          ; failed before PUSH D2 — don't pop
                STOREZ  D0, [#FD_PD_ABS_SEC]

                PUSH    D2, XY3
                LOADI   Y0, #$00
                LOADI   X0, #FS_BUF_SECTOR
                CALLR   _VolBlockRead
                BCS     .pd_io
                POP     D2, XY3

                ; r8: update dir cache identity — the buffer now holds
                ; FD_PD_ABS_SEC for drive D3. After the write-back below,
                ; on-disk and buffer agree, so the cache remains valid.
                LOADZ   D0, [#FD_PD_ABS_SEC]
                STOREZ  D0, [#DIR_CACHE_SECTOR]
                STOREZB D3, [#DIR_CACHE_DRIVE]

                ; Entry addr.
                MOVE    D0, D2
                SHL4    D0
                SHL     D0
                ADD     D0, #FS_BUF_SECTOR
                LOADI   Y1, #$00
                MOVE    X1, D0

                ; First-cluster-low at +$1A.
                LOADZ   D0, [#FD_DIR_FIRST_CL]
                STORED  D0, [XY1+#DIR_FIRST_CLUSTER_LO]

                ; Size at +$1C / +$1E.
                LOADZ   D0, [#FD_DIR_SIZE_LO]
                STORED  D0, [XY1+#DIR_FILE_SIZE]
                LOADZ   D0, [#FD_DIR_SIZE_HI]
                STORED  D0, [XY1+#DIR_FILE_SIZE+2]

                ; Write back.
                LOADZ   D0, [#FD_PD_ABS_SEC]
                LOADI   Y0, #$00
                LOADI   X0, #FS_BUF_SECTOR
                CALLR   _VolBlockWrite
                BCS     .pd_io_pass
                RETCC

.pd_io:
                POP     D2, XY3
.pd_io_nopush:
                LOADI   D0, #ERR_IO
                RETCS

.pd_io_pass:
                ; D0 already set by _VolBlockWrite (ERR_IO or ERR_READONLY)
                ; Normalise to ERR_IO for the dirent-patch path.
                LOADI   D0, #ERR_IO
                RETCS

; ============================================================================
; _PopulateFd — fill in the just-allocated fd slot
;
;   In:    XY1 = slot, XY2 = vol slot
;          FD_OPEN_FLAGS, FD_DRIVE_TMP, FD_COOKIE_TMP, FD_DIR_FIRST_CL,
;          FD_DIR_SIZE_LO, FD_DIR_SIZE_HI populated
;   Out:   slot fully populated, C=0
;   Clobbers: D0, D1, X0, flags
;   Preserves: D2, D3, Y0, XY2, XY3
; ============================================================================
_PopulateFd:
                ; Build flags byte.
                LOADI   D1, #FD_FLAG_OPEN

                LOADZ   D0, [#FD_OPEN_FLAGS]
                AND     D0, #FOPEN_READ
                BEQ.S   .pf_no_read
                OR      D1, #FD_FLAG_READ
.pf_no_read:
                LOADZ   D0, [#FD_OPEN_FLAGS]
                AND     D0, #FOPEN_WRITE
                BEQ.S   .pf_no_write
                OR      D1, #FD_FLAG_WRITE
.pf_no_write:
                LOADB   D0, [XY2+#VOL_READONLY]
                AND     D0, #$FF
                BEQ.S   .pf_no_rom
                OR      D1, #FD_FLAG_ROM
.pf_no_rom:
                STOREB  D1, [XY1+#FD_FLAGS]

                LOADZB  D1, [#FD_DRIVE_TMP]
                STOREB  D1, [XY1+#FD_DRIVE]

                LOADZ   D1, [#FD_DIR_FIRST_CL]
                STORED  D1, [XY1+#FD_FIRST_CLUSTER]
                STORED  D1, [XY1+#FD_CURR_CLUSTER]

                LOADZ   D1, [#FD_COOKIE_TMP]
                STORED  D1, [XY1+#FD_DIR_COOKIE]

                ; Part 44: remember the directory holding this file's entry so
                ; close-time _FdFlushDirent can resolve the cookie correctly.
                LOADZ   D1, [#FD_PARENT_CL]
                STORED  D1, [XY1+#FD_DIR_CLUSTER]

                ; Position: 0 by default; FOPEN_APPEND → file size.
                LOADZ   D0, [#FD_OPEN_FLAGS]
                AND     D0, #FOPEN_APPEND
                BNE.S   .pf_append

                LOADI   D1, #0
                STORED  D1, [XY1+#FD_POSITION]
                STORED  D1, [XY1+#FD_POSITION+2]
                RET

.pf_append:
                LOADZ   D1, [#FD_DIR_SIZE_LO]
                STORED  D1, [XY1+#FD_POSITION]
                LOADZ   D1, [#FD_DIR_SIZE_HI]
                STORED  D1, [XY1+#FD_POSITION+2]
                ; FD_CURR_CLUSTER is still FD_FIRST_CLUSTER. The first
                ; sys_write or sys_read will need to walk the chain. For
                ; Phase 16 we accept the cost; a future seek helper can
                ; refresh proactively.
                RET

; ============================================================================
; _RefreshDirSize — reload FD_DIR_SIZE_LO/HI from on-disk dirent
;
;   In:    XY1 = slot, XY2 = vol, D3 = drive
;   Out:   FD_DIR_SIZE_LO/HI populated; FD_DIR_FIRST_CL also reloaded
;          C=0 / C=1 ERR_IO
;   Clobbers: D0, D1, D2, X0, X1, Y0, Y1, flags
;   Preserves: D3, XY2, XY3
; ============================================================================
_RefreshDirSize:
                ; Part 44: this runs mid sys_read/sys_write with DIR_WALK_CLU=0.
                ; Re-establish the entry's directory so the cookie resolves in
                ; the right place (root or subdir), then restore the default.
                LOADD   D0, [XY1+#FD_DIR_CLUSTER]
                STOREZ  D0, [#DIR_WALK_CLU]
                LOADD   D0, [XY1+#FD_DIR_COOKIE]
                STOREZ  D0, [#FD_COOKIE_TMP]
                CALLR   _LoadDirentFromCookie
                ; Reset DIR_WALK_CLU; preserve the result code + carry across
                ; the store (same idiom as sys_mkdir .mkd_exit).
                PUSH    D0, XY3
                LOADI   D0, #0
                STOREZ  D0, [#DIR_WALK_CLU]
                POP     D0, XY3
                RET

; ============================================================================
; _FdComputeReadChunk — chunk = min(count, sec_remain, file_remain)
;
;   In:    XY1 = slot
;   Out:   D0 = chunk size (0 = EOF), C=0
;   Clobbers: D0, D1, D2, flags
;   Preserves: D3, XY1, XY2, XY3
; ============================================================================
_FdComputeReadChunk:
                ; D0 = count
                LOADZ   D0, [#FD_COUNT_TMP]

                ; D2 = byte_off = pos & $1FF
                LOADD   D1, [XY1+#FD_POSITION]
                MOVE    D2, D1
                AND     D2, #$01FF

                ; D1 = 512 - byte_off
                LOADI   D1, #512
                SUB     D1, D2

                CMP     D1, D0
                BHS.S   .fcr_check_eof
                MOVE    D0, D1

.fcr_check_eof:
                ; remaining = file_size - position, 32-bit (Part 26).
                CALLR   _FdCmpPosSize
                BHS     .fcr_eof                ; pos >= size

                ; The low-word clamp is still needed when the high words
                ; differ: pos=$0FFFF against size=$10000 leaves exactly 1 byte.
                ; PUSH/POP and LOADZ/LOADD are all flag-transparent, so the
                ; SUB's borrow reaches the SBC and the CMP's Z reaches the BNE.
                LOADZ   D1, [#FD_DIR_SIZE_LO]
                LOADD   D2, [XY1+#FD_POSITION]
                SUB     D1, D2                  ; D1 = remain low; C=1 = no borrow
                PUSH    D1, XY3
                LOADZ   D1, [#FD_DIR_SIZE_HI]
                LOADD   D2, [XY1+#FD_POSITION+2]
                SBC     D1, D2                  ; D1 = remain high
                CMP     D1, #0
                POP     D1, XY3                 ; D1 = remain low
                BNE.S   .fcr_done               ; remain >= 64 KB: chunk stands

                CMP     D1, D0
                BHS.S   .fcr_done
                MOVE    D0, D1

.fcr_done:
                RETCC

.fcr_eof:
                LOADI   D0, #0
                RETCC

; ============================================================================
; _FdComputeWriteChunk — chunk = min(count, 512 - byte_off)
; ============================================================================
_FdComputeWriteChunk:
                LOADZ   D0, [#FD_COUNT_TMP]
                LOADD   D1, [XY1+#FD_POSITION]
                MOVE    D2, D1
                AND     D2, #$01FF
                LOADI   D1, #512
                SUB     D1, D2
                CMP     D1, D0
                BHS.S   .fcw_done
                MOVE    D0, D1
.fcw_done:
                RETCC

; ============================================================================
; _FdReadCurrSector — read FD_CURR_CLUSTER's sector into FS_BUF_SECTOR
;
;   In:    XY1 = slot, XY2 = vol, D3 = drive
;   Out:   FS_BUF_SECTOR holds the data; C=0
;          C=1 with D0=ERR_IO on failure
;   Clobbers: D0, D1, D2, X0, X1, Y0, Y1, flags  (XY1 specifically clobbered!)
;   Preserves: D3, XY2, XY3
; ============================================================================
_FdReadCurrSector:
                LOADD   D0, [XY1+#FD_CURR_CLUSTER]
                CALLR   _ClusterToSector
                BCS     .frcs_err
                LOADI   Y0, #$00
                LOADI   X0, #FS_BUF_SECTOR
                CALLR   _VolBlockRead
                BCS     .frcs_err
                ; Part 22: invalidate dir cache — this read overwrote
                ; FS_BUF_SECTOR with file data, so any cached root-sector
                ; identity is stale.
                CALLR   _DirCacheInvalidate
                RETCC
.frcs_err:
                LOADI   D0, #ERR_IO
                RETCS

; ============================================================================
; _FdWriteCurrSector — write FS_BUF_SECTOR to FD_CURR_CLUSTER's sector
;
;   In:    XY1 = slot, XY2 = vol, D3 = drive, FS_BUF_SECTOR = data
;   Out:   C=0 / C=1 with D0=ERR_IO or ERR_READONLY
;   Clobbers: D0, D1, D2, X0, X1, Y0, Y1, flags
;   Preserves: D3, XY2, XY3
; ============================================================================
_FdWriteCurrSector:
                LOADD   D0, [XY1+#FD_CURR_CLUSTER]
                CALLR   _ClusterToSector
                BCS     .fwcs_io
                LOADI   Y0, #$00
                LOADI   X0, #FS_BUF_SECTOR
                CALLR   _VolBlockWrite
                BCS     .fwcs_pass
                ; FS_BUF_SECTOR holds file data; if it's still considered
                ; "the dir sector" by the cache, that's stale.
                CALLR   _DirCacheInvalidate
                RETCC
.fwcs_io:
                LOADI   D0, #ERR_IO
                RETCS
.fwcs_pass:
                ; D0 already set (ERR_IO or ERR_READONLY); pass through.
                RETCS

; ============================================================================
; _FdCopyToUser — copy [#FD_CHUNK_TMP] bytes from FS_BUF_SECTOR+byte_off
;                 to user buffer
;
;   In:    XY1 = slot (for FD_POSITION); FD_CHUNK_TMP, FD_USERBUF_*
;   Out:   C=0
;   Clobbers: D0, D1, D2, X0, X1, Y0, Y1, flags  (XY1 clobbered!)
;   Preserves: D3, XY2, XY3
; ============================================================================
_FdCopyToUser:
                LOADZ   D2, [#FD_CHUNK_TMP]  ; D2 = count (<=512)
                CMP     D2, #0
                BEQ     .fctu_ret       ; count 0 -> no-op

                ; src = FS_BUF_SECTOR + byte_off (XY1 still slot).
                LOADD   D0, [XY1+#FD_POSITION]
                AND     D0, #$01FF
                ADD     D0, #FS_BUF_SECTOR
                LOADI   Y0, #$00
                MOVE    X0, D0          ; XY0 = src ; D0 = src low

                LOADZ   D1, [#FD_USERBUF_X]  ; D1 = dst low
                MOVE    X1, D1
                OR      D0, D1          ; low bit set if EITHER ptr odd
                LOADZB  D1, [#FD_USERBUF_Y]
                MOVE    Y1, D1          ; XY1 = dst
                AND     D0, #$0001
                BNE     .fctu_byte      ; opposite parity or odd/odd -> bytes

                ; --- even/even: word blit (stride 2) + optional tail byte ---
                MOVE    D1, D2
                AND     D1, #$0001      ; D1 = tail flag (0/1)
                SHR     D2              ; D2 = word count (flag-transparent)
                CMP     D2, #0
                BEQ     .fctu_tail
.fctu_wl:
                LOADD   D0, [XY0]+
                STORED  D0, [XY1]+
                SUB     D2, #1
                BNE     .fctu_wl
.fctu_tail:
                CMP     D1, #0
                BEQ     .fctu_ret
                LOADB   D0, [XY0]
                STOREB  D0, [XY1]
.fctu_ret:
                RETCC

.fctu_byte:                          ; byte fallback (post-inc, page-carry safe)
                LOADB   D0, [XY0]+
                STOREB  D0, [XY1]+
                SUB     D2, #1
                BNE     .fctu_byte
                RETCC

; ============================================================================
; _FdCopyFromUser — copy [#FD_CHUNK_TMP] bytes from user → FS_BUF_SECTOR+off
;
;   In:    XY1 = slot, FD_CHUNK_TMP, FD_USERBUF_*
;   Out:   C=0
;   Clobbers: D0, D1, D2, X0, X1, Y0, Y1, flags  (XY1 clobbered!)
;   Preserves: D3, XY2, XY3
; ============================================================================
_FdCopyFromUser:
                LOADZ   D2, [#FD_CHUNK_TMP]  ; D2 = count (<=512)
                CMP     D2, #0
                BEQ     .fcfu_ret       ; count 0 -> no-op

                ; dest = FS_BUF_SECTOR + byte_off (XY1 still slot).
                LOADD   D1, [XY1+#FD_POSITION]
                AND     D1, #$01FF
                ADD     D1, #FS_BUF_SECTOR
                LOADI   Y1, #$00
                MOVE    X1, D1          ; XY1 = dest ; D1 = dst low
                MOVE    D0, D1          ; save dst low for parity

                LOADZ   D1, [#FD_USERBUF_X]  ; D1 = src low
                MOVE    X0, D1
                OR      D0, D1          ; low bit set if EITHER ptr odd
                LOADZB  D1, [#FD_USERBUF_Y]
                MOVE    Y0, D1          ; XY0 = src
                AND     D0, #$0001
                BNE     .fcfu_byte      ; opposite parity or odd/odd -> bytes

                ; --- even/even: word blit (stride 2) + optional tail byte ---
                MOVE    D1, D2
                AND     D1, #$0001      ; D1 = tail flag (0/1)
                SHR     D2              ; D2 = word count (flag-transparent)
                CMP     D2, #0
                BEQ     .fcfu_tail
.fcfu_wl:
                LOADD   D0, [XY0]+
                STORED  D0, [XY1]+
                SUB     D2, #1
                BNE     .fcfu_wl
.fcfu_tail:
                CMP     D1, #0
                BEQ     .fcfu_ret
                LOADB   D0, [XY0]
                STOREB  D0, [XY1]
.fcfu_ret:
                RETCC

.fcfu_byte:                          ; byte fallback (post-inc, page-carry safe)
                LOADB   D0, [XY0]+
                STOREB  D0, [XY1]+
                SUB     D2, #1
                BNE     .fcfu_byte
                RETCC

; ============================================================================
; _FdCmpPosSize — 32-bit unsigned compare of FD_POSITION vs FD_DIR_SIZE
;
;   In:    XY1 = slot; FD_DIR_SIZE_LO/HI current (_RefreshDirSize first)
;   Out:   flags set exactly as a 32-bit CMP pos, size --
;          BHS / BLO / BHI / BLS / BEQ / BNE are all valid after this call
;   Clobbers: D1, D2, flags
;   Preserves: D0, D3, XY0, XY1, XY2, XY3
;
;   Exits via plain RET, NOT RETCC/RETCS. RETCC/RETCS force C and clear
;   Z/N/V (Reference Manual $1E mode 10), which would destroy the answer
;   this routine exists to return. RET touches no flags.
;
;   When the high words differ they decide the comparison outright and Z=0
;   is already correct, so the low compare is skipped.
; ============================================================================
_FdCmpPosSize:
                LOADD   D1, [XY1+#FD_POSITION+2]
                LOADZ   D2, [#FD_DIR_SIZE_HI]
                CMP     D1, D2
                BNE.S   .fcps_out
                LOADD   D1, [XY1+#FD_POSITION]
                LOADZ   D2, [#FD_DIR_SIZE_LO]
                CMP     D1, D2
.fcps_out:
                RET

; ============================================================================
; _FdAdvancePosition — pos += D0; walk FAT if cluster boundary crossed
;
;   In:    D0 = chunk, XY1 = slot, XY2 = vol, D3 = drive
;   Out:   C=0 / C=1 with D0=ERR_IO
;   Clobbers: D0, D1, D2, X0, X1, Y0, Y1, flags
;   Preserves: D3, XY2, XY3
;
;   The position is 32-bit: the ADD's carry propagates into the high word.
;
;   The BLOCK INDEX stays 16-bit deliberately. It exists only for the
;   CMP old,new that decides whether to walk the FAT, and a chunk is
;   <= 512. Within one high word blk_full = hi*128 + blk_lo, so blk_lo
;   decides; across a wrap old_blk = 127 and new_blk = 0, which still
;   differs. Widening it would buy nothing.
; ============================================================================
_FdAdvancePosition:
                LOADD   D1, [XY1+#FD_POSITION]
                MOVE    D2, D1
                ADD     D2, D0                  ; D2 = new pos low; C = carry out

                ; Propagate the carry into the high word NOW. Only
                ; flag-transparent instructions may sit between ADD and ADC;
                ; LOADD is one.
                LOADD   D0, [XY1+#FD_POSITION+2]
                ADC     D0, #0
                STORED  D0, [XY1+#FD_POSITION+2]

                ; old block index = D1 >> 9 → HIGH then SHR
                MOVE    D0, D1
                HIGH    D0
                SHR     D0                      ; D0 = old block

                ; new block index = D2 >> 9
                MOVE    D1, D2
                HIGH    D1
                SHR     D1                      ; D1 = new block

                ; Save new position.
                STORED  D2, [XY1+#FD_POSITION]

                CMP     D0, D1
                BEQ     .fap_done

                ; Crossed boundary. Walk FAT once.
                LOADD   D0, [XY1+#FD_CURR_CLUSTER]
                CALLR   _FATGetEntry            ; clobbers X1
                BCS     .fap_io
                ; Re-derive XY1.
                PUSH    D0, XY3
                LOADZB  D0, [#FD_RESULT_TMP]
                AND     D0, #$FF
                CALLR   _FdAddr
                POP     D0, XY3
                CMP     D0, #FAT_EOC_MIN
                BHS.S   .fap_done               ; EOC: leave curr alone
                STORED  D0, [XY1+#FD_CURR_CLUSTER]

.fap_done:
                RETCC

.fap_io:
                LOADI   D0, #ERR_IO
                RETCS

; ============================================================================
; _FdAdvancePositionAndSize — like above, also bumps FD_DIR_SIZE_LO/HI if
;                              new position > old size (32-bit, Part 26)
;
;   _FdAdvancePosition leaves XY1 valid (it re-derives internally on the
;   FAT-walk path and never clobbers it on the no-cross path), so this
;   wrapper can read FD_POSITION via XY1 directly.
; ============================================================================
_FdAdvancePositionAndSize:
                CALLR   _FdAdvancePosition
                BCS     .faps_err
                ; 32-bit max(size, pos). BLS is a pseudo-instruction (BEQ/BLO)
                ; so it needs both Z and C -- which is exactly what
                ; _FdCmpPosSize guarantees.
                CALLR   _FdCmpPosSize
                BLS     .faps_done              ; pos <= size: nothing to do
                LOADD   D1, [XY1+#FD_POSITION]
                STOREZ  D1, [#FD_DIR_SIZE_LO]
                LOADD   D1, [XY1+#FD_POSITION+2]
                STOREZ  D1, [#FD_DIR_SIZE_HI]
.faps_done:
                RETCC
.faps_err:
                RETCS

; ============================================================================
; _FdEnsureCluster — for writes — alloc + chain if needed
;
;   In:    XY1 = slot, XY2 = vol, D3 = drive
;   Out:   FD_CURR_CLUSTER points at a writable cluster
;          C=0 / C=1 with D0=ERR_NOSPACE/ERR_IO
;   Clobbers: D0, D1, D2, X0, X1, Y0, Y1, flags
;   Preserves: D3, XY2, XY3
;
;   Cases:
;     (1) FD_FIRST_CLUSTER == 0 (empty file): alloc new, set first+curr.
;     (2) byte_off != 0: mid-cluster, current is fine.
;     (3) byte_off == 0 AND pos == 0: at start, current = first.
;     (4) byte_off == 0 AND pos > 0 AND pos < size: just crossed into
;         a previously-allocated cluster; advance via FAT.
;     (5) byte_off == 0 AND pos >= size: need a new cluster; alloc + chain.
; ============================================================================
_FdEnsureCluster:
                LOADD   D0, [XY1+#FD_FIRST_CLUSTER]
                CMP     D0, #CLUSTER_FIRST_VALID
                BLO     .fec_alloc_first        ; (1)

                LOADD   D0, [XY1+#FD_POSITION]
                AND     D0, #$01FF
                BNE     .fec_done               ; (2): mid-cluster

                ; byte_off == 0 -- is the position ZERO? Part 26: this must
                ; test BOTH words. Testing the low word alone made every
                ; exact multiple of 64 KB look like offset 0, so case (3) was
                ; taken, the cluster allocation was skipped, and the sector
                ; for that position overwrote the previous cluster. Every
                ; later cluster then ran one behind: reading position p came
                ; back with the data from p+512, and the file's last cluster
                ; was never written at all.
                ;
                ; OR sets Z only when both words are zero, and is exactly the
                ; test we want. (LOAD is flag-transparent, hence the explicit
                ; flag-setting op -- the original comment's point still holds.)
                LOADD   D0, [XY1+#FD_POSITION]
                LOADD   D1, [XY1+#FD_POSITION+2]
                OR      D0, D1
                BEQ     .fec_done               ; (3): pos == 0

                ; pos > 0, byte_off == 0 -- 32-bit pos vs size (Part 26).
                CALLR   _FdCmpPosSize
                BLO     .fec_advance_existing   ; (4) pos < size
                ; (5) pos >= size
                LOADD   D0, [XY1+#FD_CURR_CLUSTER]
                CALLR   _FATGetEntry            ; clobbers X1
                BCS     .fec_io
                ; Re-derive XY1.
                PUSH    D0, XY3
                LOADZB  D0, [#FD_RESULT_TMP]
                AND     D0, #$FF
                CALLR   _FdAddr
                POP     D0, XY3
                CMP     D0, #FAT_EOC_MIN
                BLO     .fec_use_next_have      ; chain has next, advance

                ; Tail of chain — alloc new.
                CALLR   _AllocCluster
                BCS     .fec_alloc_err
                ; Chain prev → new.
                MOVE    D1, D0                  ; D1 = new
                ; Re-derive XY1.
                PUSH    D1, XY3
                LOADZB  D0, [#FD_RESULT_TMP]
                AND     D0, #$FF
                CALLR   _FdAddr
                POP     D1, XY3
                LOADD   D0, [XY1+#FD_CURR_CLUSTER]
                CALLR   _FATSetEntry            ; clobbers X1; D1 preserved
                BCS     .fec_io
                ; Re-derive XY1; D1 still has new cluster.
                PUSH    D1, XY3
                LOADZB  D0, [#FD_RESULT_TMP]
                AND     D0, #$FF
                CALLR   _FdAddr
                POP     D1, XY3
                STORED  D1, [XY1+#FD_CURR_CLUSTER]
                RETCC

.fec_use_next_have:
                ; D0 = next cluster (already in D0 after FATGetEntry path).
                STORED  D0, [XY1+#FD_CURR_CLUSTER]
                RETCC

.fec_advance_existing:
                ; (4): chain has next; walk one step.
                LOADD   D0, [XY1+#FD_CURR_CLUSTER]
                CALLR   _FATGetEntry            ; clobbers X1
                BCS     .fec_io
                ; Re-derive XY1.
                PUSH    D0, XY3
                LOADZB  D0, [#FD_RESULT_TMP]
                AND     D0, #$FF
                CALLR   _FdAddr
                POP     D0, XY3
                CMP     D0, #FAT_EOC_MIN
                BHS     .fec_done               ; defensive: shouldn't happen
                STORED  D0, [XY1+#FD_CURR_CLUSTER]
                RETCC

.fec_alloc_first:
                CALLR   _AllocCluster
                BCS     .fec_alloc_err
                ; Re-derive XY1; D0 = new cluster.
                PUSH    D0, XY3
                LOADZB  D0, [#FD_RESULT_TMP]
                AND     D0, #$FF
                CALLR   _FdAddr
                POP     D0, XY3
                STORED  D0, [XY1+#FD_FIRST_CLUSTER]
                STORED  D0, [XY1+#FD_CURR_CLUSTER]
                STOREZ  D0, [#FD_DIR_FIRST_CL]
                RETCC

.fec_done:
                RETCC

.fec_alloc_err:
                ; D0 has ERR_NOSPACE or ERR_IO; C=1.
                RETCS

.fec_io:
                LOADI   D0, #ERR_IO
                RETCS

; ============================================================================
; _FdFlushDirent — on close, write live size + first-cluster back to dirent
;
;   In:    XY1 = slot, XY2 = vol, D3 = drive
;   Out:   C=0 / C=1 ERR_IO
;
;   Process:
;     1. Load current dirent (gives us authoritative cookie + sizes).
;     2. New size = max(stored_size, FD_POSITION) -- 32-bit.
;     3. New first_cluster = slot's FD_FIRST_CLUSTER.
;     4. RMW.
;     5. Flush FAT cache (chain may be dirty).
; ============================================================================
_FdFlushDirent:
                ; Part 44: this runs at close/sync, long after sys_open reset
                ; DIR_WALK_CLU to 0. Re-establish the entry's directory so the
                ; cookie's sec_off resolves correctly (root or subdir). The
                ; parent cluster was stashed in the fd at open time.
                LOADD   D0, [XY1+#FD_DIR_CLUSTER]
                STOREZ  D0, [#DIR_WALK_CLU]

                LOADD   D0, [XY1+#FD_DIR_COOKIE]
                STOREZ  D0, [#FD_COOKIE_TMP]
                CALLR   _LoadDirentFromCookie
                BCS     .ffd_io

                ; (After block I/O, XY1 was clobbered. Re-derive.)
                LOADZB  D0, [#FD_RESULT_TMP]
                AND     D0, #$FF
                CALLR   _FdAddr

                ; New size = max(old, position) -- 32-bit (Part 26). Without
                ; the high word the file closes with a wrapped length even
                ; when every byte landed correctly.
                CALLR   _FdCmpPosSize
                BLS     .ffd_size_ok
                LOADD   D0, [XY1+#FD_POSITION]
                STOREZ  D0, [#FD_DIR_SIZE_LO]
                LOADD   D0, [XY1+#FD_POSITION+2]
                STOREZ  D0, [#FD_DIR_SIZE_HI]
.ffd_size_ok:

                LOADD   D0, [XY1+#FD_FIRST_CLUSTER]
                STOREZ  D0, [#FD_DIR_FIRST_CL]

                CALLR   _PatchDirentSizeCl
                BCS     .ffd_io

                CALLR   _FATFlush
                BCS     .ffd_io

                ; Part 44: restore the root default for DIR_WALK_CLU.
                LOADI   D0, #0
                STOREZ  D0, [#DIR_WALK_CLU]
                CLC
                RET

.ffd_io:
                LOADI   D0, #0
                STOREZ  D0, [#DIR_WALK_CLU]     ; Part 44: reset on the error path too
                LOADI   D0, #ERR_IO
                SEC
                RET

; ============================================================================
; _FatEntryToInfo — translate raw 32-byte FAT entry → DIRENT_INFO at user buf
;
;   In:    FD_DIRENT_RAW holds the raw FAT entry (set by _DirNext).
;          FD_USERBUF_X / FD_USERBUF_Y point at user's 32-byte DIRENT_INFO.
;   Out:   C=0 (no errors)
;   Clobbers: D0, D1, D2, X0, X1, Y0, Y1, flags
;   Preserves: D3, XY2, XY3
;
;   DIRENT_INFO layout (32 bytes):
;     $00..$0B  12 B   name "NAME.EXT" with dot, nul-padded
;     $0C       byte   attributes
;     $0D       byte   reserved (0)
;     $0E       word   first cluster
;     $10       4 B    file size
;     $14       word   modification date
;     $16       word   modification time
;     $18..$1F  8 B    reserved (0)
;
;   Source raw FAT entry:
;     $00..$0A  11 B   8.3 name (space-padded, no dot)
;     $0B       byte   attr
;     $1A       word   first cluster low
;     $1C       4 B    size
;     $16       word   write time
;     $18       word   write date
; ============================================================================
_FatEntryToInfo:
                ; --- Zero the user buffer first (32 bytes) -----------------
                LOADZ   D1, [#FD_USERBUF_X]

                MOVE    X1, D1

                LOADZB  D1, [#FD_USERBUF_Y]

                MOVE    Y1, D1
                LOADI   D0, #0
                LOADI   D2, #DIRENT_INFO_SIZE   ; 64 (Part 45: 8.3 + long name)
.fei_zero:
                STOREB  D0, [XY1]+
                SUB     D2, #1
                BNE     .fei_zero

                ; --- Convert name: raw 11 → display 8.3 with dot -----------
                ; XY0 = source FD_DIRENT_RAW
                ; XY1 = dest = user buffer base (re-derive)
                LOADI   Y0, #$00
                LOADI   X0, #FD_DIRENT_RAW
                LOADZ   D1, [#FD_USERBUF_X]

                MOVE    X1, D1

                LOADZB  D1, [#FD_USERBUF_Y]

                MOVE    Y1, D1
                CALLR   _DirNameFromFat
                ; That fills [XY1..XY1+11] with "NAME.EXT", 0. Good.

                ; --- Copy attribute byte: raw $0B → INFO $0C --------------
                LOADI   Y0, #$00
                LOADI   X0, #FD_DIRENT_RAW + DIR_ATTR
                LOADB   D0, [XY0]
                AND     D0, #$FF
                LOADZ   D1, [#FD_USERBUF_X]

                MOVE    X1, D1

                LOADZB  D1, [#FD_USERBUF_Y]

                MOVE    Y1, D1
                ADD     X1, #$0C
                STOREB  D0, [XY1]

                ; --- First cluster: raw $1A → INFO $0E --------------------
                LOADI   Y0, #$00
                LOADI   X0, #FD_DIRENT_RAW + DIR_FIRST_CLUSTER_LO
                LOADD   D0, [XY0]
                LOADZ   D1, [#FD_USERBUF_X]

                MOVE    X1, D1

                LOADZB  D1, [#FD_USERBUF_Y]

                MOVE    Y1, D1
                ADD     X1, #$0E
                STORED  D0, [XY1]

                ; --- File size (4 bytes): raw $1C → INFO $10 --------------
                LOADI   Y0, #$00
                LOADI   X0, #FD_DIRENT_RAW + DIR_FILE_SIZE
                LOADD   D0, [XY0]
                LOADZ   D1, [#FD_USERBUF_X]

                MOVE    X1, D1

                LOADZB  D1, [#FD_USERBUF_Y]

                MOVE    Y1, D1
                ADD     X1, #$10
                STORED  D0, [XY1]
                ; high word
                LOADI   Y0, #$00
                LOADI   X0, #FD_DIRENT_RAW + DIR_FILE_SIZE + 2
                LOADD   D0, [XY0]
                LOADZ   D1, [#FD_USERBUF_X]

                MOVE    X1, D1

                LOADZB  D1, [#FD_USERBUF_Y]

                MOVE    Y1, D1
                ADD     X1, #$12
                STORED  D0, [XY1]

                ; --- Write date: raw $18 → INFO $14 -----------------------
                LOADI   Y0, #$00
                LOADI   X0, #FD_DIRENT_RAW + DIR_WRITE_DATE
                LOADD   D0, [XY0]
                LOADZ   D1, [#FD_USERBUF_X]

                MOVE    X1, D1

                LOADZB  D1, [#FD_USERBUF_Y]

                MOVE    Y1, D1
                ADD     X1, #$14
                STORED  D0, [XY1]

                ; --- Write time: raw $16 → INFO $16 -----------------------
                LOADI   Y0, #$00
                LOADI   X0, #FD_DIRENT_RAW + DIR_WRITE_TIME
                LOADD   D0, [XY0]
                LOADZ   D1, [#FD_USERBUF_X]

                MOVE    X1, D1

                LOADZB  D1, [#FD_USERBUF_Y]

                MOVE    Y1, D1
                ADD     X1, #$16
                STORED  D0, [XY1]

                ; --- Long name (Part 45): copy LFN_ASM -> INFO +$20 --------
                ; _DirNext leaves LFN_ASM_LEN > 0 only when a valid long name
                ; was assembled for this entry; else +$20 stays nul (8.3 only).
                LOADZ   D2, [#LFN_ASM_LEN]
                CMP     D2, #0
                BEQ     .fei_no_lfn
                ; dest = user buffer + $20
                LOADZ   D1, [#FD_USERBUF_X]
                MOVE    X1, D1
                LOADZB  D1, [#FD_USERBUF_Y]
                MOVE    Y1, D1
                ADD     X1, #$20
                ; src = LFN_ASM (page $00)
                LOADI   Y0, #$00
                LOADI   X0, #LFN_ASM
                ; copy D2 bytes, then a nul terminator
.fei_lfn_copy:
                LOADB   D0, [XY0]+
                STOREB  D0, [XY1]+
                SUB     D2, #1
                BNE     .fei_lfn_copy
                LOADI   D0, #0
                STOREB  D0, [XY1]               ; nul-terminate
.fei_no_lfn:

                RETCC


; ============================================================================
; sys_unlink — TRAP #37 — delete a file by path
; ============================================================================
;
;   In:    XY0 = path: "X:NAME.EXT", a CWD-relative name, or a subpath
;          D1  = CWD cluster (0 = root)   — Part 44, for relative paths
;          D2  = CWD drive index          — Part 44, start drive when no "X:"
;   Out:   C=0 on success
;          C=1 with D0 = ERR_BADPATH    malformed path
;                       ERR_BADDRIVE    drive not mounted
;                       ERR_NOTFOUND    no such file
;                       ERR_NOTDIR      target is a directory (use rmdir)
;                       ERR_READONLY    target volume is read-only
;                       ERR_IO          block read/write failed
;   Clobbers: D0, XY0
;   Preserves: D1, D2, D3, XY1, XY2, XY3           ; V2 ABI (Part 36)
;
; Pattern follows sys_format: non-leaf, DINT at entry, gate EINT on
; KERNEL_STATE == KERN_STATE_RUN at exit (gotcha 4.6). PUSH D2/D3/XY1
; per V2 ABI (Part 36 — XY1 added to callee-preserved set). D1/D2 are read
; as inputs by _DeleteFile (they flow in untouched after the entry PUSHes).
; ============================================================================
sys_unlink:
                DINT
                PUSH    D2, XY3
                PUSH    D3, XY3
                PUSH    XY1, XY3                    ; Part 36: V2 ABI
                PUSH    XY2, XY3                    ; Part 25: XY2 is the Pascal frame pointer
                PUSH    D1, XY3                     ; Part 36 r2 — helpers clobber D1

                CALLR   _DeleteFile
                ; D0 / C already set by _DeleteFile.

                ; Part 36: stash D0 (return) across EINT gate; D1 is now
                ; callee-preserved per V2 ABI.
                PUSH    SR, XY3
                PUSH    D0, XY3
                LOADZ   D0, [#KERNEL_STATE]
                LOW     D0
                CMP     D0, #KERN_STATE_RUN
                POP     D0, XY3
                BNE.S   .su_skip_eint
                EINT
.su_skip_eint:
                POP     SR, XY3

                POP     D1, XY3                     ; Part 36 r2
                POP     XY2, XY3                    ; Part 25: XY2 is the Pascal frame pointer
                POP     XY1, XY3                    ; Part 36: V2 ABI
                POP     D3, XY3
                POP     D2, XY3
                RET


; ============================================================================
; _DeleteFile — kernel-internal: delete a file by path
; ============================================================================
;
;   Algorithm:
;     1. _ParsePath          → drive + 11-byte FAT name in FD_NAMEBUF
;     2. _SlotForDrive       → XY2 = volume slot
;        (Read-only check is implicit via the eventual _VolBlockWrite
;         in _FATSetEntry/_DirDelete.)
;     3. _DirLookup          → cookie, dirent now in FS_BUF_SECTOR
;     4. Read DIR_FIRST_CLUSTER_LO from the matched entry
;     5. _FATFreeChain(first_cluster)
;     6. _FATFlush
;     7. _DirDelete          (writes $E5 over the name's first byte)
;
;   In:    XY0 = nul-terminated path
;   Out:   C=0 on success
;          C=1 with D0 = ERR_*
;   Clobbers: D0, D1, D2, D3, XY0, XY1   (XY2/XY3 preserved)
;
;   Note on the dirent-read-back step: _DirLookup leaves FS_BUF_SECTOR
;   loaded with the matching root-dir sector and returns a cookie. We
;   compute the entry address (FS_BUF_SECTOR + ent_idx*32) and read the
;   first-cluster word at offset DIR_FIRST_CLUSTER_LO ($1A) directly.
;   Crucially this read MUST happen BEFORE any other _VolBlockRead is
;   issued (e.g. by _FATGetEntry inside _FATFreeChain), because such a
;   read would overwrite FS_BUF_SECTOR.
; ============================================================================
_DeleteFile:
                PUSH    XY2, XY3

                ; --- 1. Resolve parent (Part 44) --------------------------
                ; XY0 = path, D0 = start drive (CWD drive, from D2),
                ; D1 = start cluster (CWD clu). _ResolveParent leaves drive in
                ; D0, parent cluster in D1, the leaf 11-byte name in RV_FATNAME.
                MOVE    D0, D2                  ; start drive = CWD drive index
                CALLR   _ResolveParent
                BCS     .df_err_pop             ; BADPATH/BADDRIVE/NOTFOUND/NOTDIR/IO
                MOVE    D3, D0                  ; D3 = drive
                STOREZ  D1, [#FD_PARENT_CL]     ; parent cluster
                CALLR   _CopyLeafToNamebuf      ; RV_FATNAME -> FD_NAMEBUF

                ; --- 2. Resolve drive → XY2 = slot ------------------------
                MOVE    D0, D3
                CALLR   _SlotForDrive
                BCS     .df_err_pop             ; ERR_BADDRIVE

                ; --- 2a. Pre-flight read-only check -----------------------
                ; BUGFIX 28 May 2026 (Part 37): reject BEFORE touching the
                ; FAT. The old "implicit" check let _FATFreeChain run, then
                ; _FATFlush discovered r/o and aborted — leaving the FAT
                ; cache DIRTY with bogus freed-cluster state never written to
                ; ROM. The next sys_diskfree (`vol`) then mis-read free space
                ; and the forced flush returned ERR_READONLY, which `vol`
                ; rendered as "(not mounted)" for every drive.
                ;
                ; IMPORTANT: a volume's read-only-ness is NOT reliably in
                ; VOL_READONLY. The ROM disk (A:) leaves VOL_READONLY=0 and
                ; is read-only purely by having a NULL VOL_BLOCKWRITE_PTR
                ; (kos_fs_rom.asm: no _BlockWriteROM). So test the write
                ; pointer — the same source of truth _VolBlockWrite uses at
                ; .vbw_readonly — OR'ing both halves of the 24-bit pointer.
                LOADD   D0, [XY2+#VOL_BLOCKWRITE_PTR]      ; page word
                LOADI   D1, #VOL_BLOCKWRITE_PTR+2
                LOADD   D1, [XY2+D1]                      ; X word
                OR      D0, D1
                BNE.S   .df_writable                      ; non-null -> writable
                ; Null write pointer => read-only volume.
                LOADI   D0, #ERR_READONLY
                BRA     .df_err_pop
.df_writable:

                ; Part 44: operate inside the resolved parent directory.
                LOADZ   D0, [#FD_PARENT_CL]
                STOREZ  D0, [#DIR_WALK_CLU]

                ; --- 3. _DirLookupLong ----------------------------------
                ; Part 46 (45.5.3a): long-aware so `rm <longname>` resolves.
                ; Driven by RV_COMP / RV_FATNAME / RV_SAVE_PAD (left live by
                ; _ResolveParent above; FD_NAMEBUF is no longer consulted here).
                CALLR   _DirLookupLong
                BCS     .df_err_pop             ; ERR_NOTFOUND or ERR_IO

                ; D0 = cookie. _DirDelete (step 7) does its own _DirLookup
                ; (the cache will hit, no I/O cost) so we don't save the
                ; cookie. We just need first_cluster out of the dirent
                ; while FS_BUF_SECTOR still has the right sector loaded.

                ; --- 4. Extract first_cluster from the dirent -------------
                ; entry_addr = FS_BUF_SECTOR + ent_idx * 32
                ; ent_idx = cookie & $0F
                MOVE    D1, D0
                AND     D1, #$0F
                SHL4    D1                      ; ent_idx * 16
                SHL     D1                      ; ent_idx * 32
                ADD     D1, #FS_BUF_SECTOR
                LOADI   Y0, #$00
                MOVE    X0, D1

                LOADD   D0, [XY0+#DIR_FIRST_CLUSTER_LO]
                ; D0 = first cluster (0 if file is empty).
                ; Stash in FD_NAMEBUF2 (low word) — we need it across
                ; _FATFreeChain which uses D0.
                STOREZ  D0, [#FD_NAMEBUF2]

                ; --- 4a. refuse directories -------------------------------
                ; `rm` deletes files only. Without this guard, rm on a
                ; directory would free its cluster chain and delete the
                ; entry, orphaning any child clusters (a leak) and bypassing
                ; the emptiness check. Read the attr from the SAME entry
                ; (XY0 still points at it; FS_BUF_SECTOR not yet disturbed)
                ; and bail with ERR_NOTDIR before touching the FAT. Callers
                ; should use rmdir for directories.
                LOADB   D0, [XY0+#DIR_ATTR]
                AND     D0, #DIR_ATTR_DIRECTORY
                BEQ.S   .df_not_dir
                LOADI   D0, #ERR_NOTDIR
                BRA     .df_err_pop
.df_not_dir:

                ; --- 5. Free the cluster chain ----------------------------
                LOADZ   D0, [#FD_NAMEBUF2]
                CALLR   _FATFreeChain
                BCS     .df_err_pop             ; ERR_IO

                ; --- 6. Flush FAT ----------------------------------------
                CALLR   _FATFlush
                BCS     .df_err_pop             ; ERR_IO

                ; --- 7. _DirDeleteRun -----------------------------------
                ; Part 46 (45.5.3a): whole-run delete ($E5 the LFN fragments
                ; AND the short entry). It re-runs _DirLookupLong internally
                ; (cache hit), so re-assert DIR_WALK_CLU = parent. Needs
                ; XY2 = slot, D3 = drive (both still set); RV_COMP survived
                ; _FATFreeChain/_FATFlush (FAT-only ops, untouched).
                LOADZ   D0, [#FD_PARENT_CL]
                STOREZ  D0, [#DIR_WALK_CLU]
                CALLR   _DirDeleteRun
                BCS     .df_err_pop

                ; success — restore DIR_WALK_CLU root default.
                LOADI   D0, #0
                STOREZ  D0, [#DIR_WALK_CLU]
                POP     XY2, XY3
                CLC
                RET

.df_err_pop:
                ; D0 already set by callee. Reset DIR_WALK_CLU (preserve err+carry),
                ; unwind and bubble up.
                PUSH    D0, XY3
                LOADI   D0, #0
                STOREZ  D0, [#DIR_WALK_CLU]
                POP     D0, XY3
                POP     XY2, XY3
                SEC
                RET


; ============================================================================
; sys_rename — TRAP #38 — rename a file (same drive only)
; ============================================================================
;
;   In:    XY0 = old path,  XY1 = new path (each "X:NAME", CWD-relative, or
;               a subpath)
;          D1  = CWD cluster (0 = root)   — Part 44
;          D2  = CWD drive index          — Part 44
;   Out:   C=0 on success
;          C=1 with D0 = ERR_BADPATH    malformed path
;                       ERR_INVALID     old & new are not in the SAME
;                                       directory (different drive, OR same
;                                       drive but different parent cluster).
;                                       kosh uses this to fall back to
;                                       cp+unlink (handles cross-dir moves).
;                       ERR_BADDRIVE    drive not mounted
;                       ERR_NOTFOUND    old name doesn't exist
;                       ERR_EXISTS      new name already exists
;                       ERR_READONLY    target volume is read-only
;                       ERR_IO          block read/write failed
;   Clobbers: D0, XY0
;   Preserves: D1, D2, D3, XY2, XY3                ; V2 ABI (Part 36)
;
;   XY1 is an INPUT ARG (new-path pointer), legitimately consumed per
;   the V2 ABI input-arg/return clarification (kOS Reference Manual §5).
;
;   Part 44: both paths are resolved (PARENT mode) relative to (D2:D1). The
;   rename is an in-place name overwrite in a single directory entry, so old
;   and new MUST resolve to the same parent directory; otherwise ERR_INVALID.
;
;   The new-name pre-check is "must NOT be found" — if _DirLookup on the
;   new name succeeds, we return ERR_EXISTS. Same semantics as cp's
;   pre-flight existence check, applied at the kernel level so kosh's
;   mv command doesn't need to duplicate it.
; ============================================================================
sys_rename:
                DINT
                PUSH    D2, XY3
                PUSH    D3, XY3
                PUSH    XY2, XY3                    ; Part 25: XY2 is the Pascal frame pointer
                PUSH    D1, XY3                     ; Part 36 r2 — helpers clobber D1

                CALLR   _RenameFile

                ; Part 36: stash D0 (return) across EINT gate; D1 is now
                ; callee-preserved per V2 ABI.
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

                POP     D1, XY3                     ; Part 36 r2
                POP     XY2, XY3                    ; Part 25: XY2 is the Pascal frame pointer
                POP     D3, XY3
                POP     D2, XY3
                RET


; ============================================================================
; _RenameFile — kernel-internal: same-directory rename (Part 44; LFN-aware 45.5.3b)
; ============================================================================
;
;   In:    XY0 = old path,  XY1 = new path
;          D1  = CWD cluster, D2 = CWD drive index            (Part 44)
;   Out:   C=0 on success
;          C=1 with D0 = ERR_*
;   Clobbers: D0, D1, D2, D3, XY0, XY1   (XY2/XY3 preserved)
;
;   Part 45.5.3b — LFN-aware. The old in-place 11-byte name overwrite cannot
;   stand once long names exist: the fragment count, the stored long name and
;   the per-entry checksum all change with the name. So a rename is now
;   "create the new-named entry carrying the old entry's metadata, then delete
;   the old whole-run", reusing the verified create/delete primitives:
;
;     A. _ResolveParent(old) -> drive_old, parent_old; _SlotForDrive -> XY2;
;        _DirLookupLong(old) -> short entry; capture {attr, first_cluster,
;        size_lo, size_hi} (attr preserved so a renamed *directory* keeps its
;        DIRECTORY bit — files are attr=0 anyway).
;     B. _ResolveParent(new) -> drive_new, parent_new; require same dir
;        (else ERR_INVALID — kosh falls back to cp+unlink for moves);
;        _DirLookupLong(new) must NOT exist (else ERR_EXISTS); _GenShortName
;        + _DirCreate / _DirCreateRun stamping the preserved attr/cluster/
;        size_lo. If size_hi != 0 (file >= 64 KB — _DicFormatShortEntry only
;        writes the low size word), re-lookup the new cookie and
;        _PatchDirentSizeCl to lay down the full 32-bit size.
;     C. _ResolveParent(old) again (repopulates RV_COMP=old) -> _DirDeleteRun.
;
;   Notes / accepted limitations:
;     • The entry is relocated within the directory and timestamps are
;       re-stamped (RTC stubs are baked constants today, so moot).
;     • A case-only rename of one name (e.g. "FILE.TXT"->"file.txt") still
;       returns ERR_EXISTS: FAT 8.3 / case-insensitive LFN match treats them
;       as the same name (unchanged from the old in-place behaviour).
;     • New entry is created before the old is deleted, so a (rare) ERR_IO on
;       the final delete, or ERR_NOSPACE creating the new run in a full dir,
;       can leave both entries present (cross-linked on the same cluster).
;       The file data/FAT chain are never touched. Subdir runs can't grow yet
;       (45.5.2b), so a long new name may ERR_NOSPACE in a packed subdir.
; ============================================================================
_RenameFile:
                PUSH    XY2, XY3                ; [slot] preserve caller slot
                PUSH    XY0, XY3                ; [oldp] old-path pointer
                PUSH    XY1, XY3                ; [newp] new-path pointer

                ; Stash CWD context (every _ResolveParent clobbers D0/D1/D2/D3).
                STOREZ  D1, [#RNM_CWD_CLU]
                STOREZ  D2, [#RNM_CWD_DRV]

                ; ===== A. resolve OLD, look up OLD, capture metadata =====
                ; XY0 = old path. D0 = start drive (CWD), D1 = start clu (CWD).
                MOVE    D0, D2                  ; start drive = CWD drive
                CALLR   _ResolveParent
                BCS     .rf_err                 ; BADPATH/BADDRIVE/NOTFOUND/NOTDIR/IO
                STOREZB D0, [#FD_DRIVE_TMP]     ; drive_old
                STOREZ  D1, [#RNM_PARENT_CL]    ; parent_old

                ; drive_old -> XY2 = volume slot (used by every call below;
                ; _ResolveParent preserves XY2, so this survives B and C).
                CALLR   _SlotForDrive           ; D0 = drive -> XY2
                BCS     .rf_err                 ; ERR_BADDRIVE

                ; long-aware lookup of OLD inside parent_old.
                LOADZ   D0, [#RNM_PARENT_CL]
                STOREZ  D0, [#DIR_WALK_CLU]
                LOADZB  D3, [#FD_DRIVE_TMP]
                AND     D3, #$FF
                CALLR   _DirLookupLong          ; RV_COMP=old leaf -> D0 = cookie
                BCS     .rf_err                 ; ERR_NOTFOUND / ERR_IO

                ; entry_addr = FS_BUF_SECTOR + ent_idx*32  (ent_idx = cookie&$0F)
                MOVE    D1, D0
                AND     D1, #$0F
                SHL4    D1
                SHL     D1
                ADD     D1, #FS_BUF_SECTOR
                LOADI   Y0, #$00
                MOVE    X0, D1                  ; XY0 = old short entry

                ; capture attr / first_cluster / size (FS_BUF_SECTOR is live).
                LOADB   D0, [XY0+#DIR_ATTR]
                AND     D0, #$FF
                STOREZB D0, [#FD_NAMEBUF2]      ; reuse FD_NAMEBUF2[0] = old attr
                LOADD   D0, [XY0+#DIR_FIRST_CLUSTER_LO]
                STOREZ  D0, [#FD_DIR_FIRST_CL]
                LOADD   D0, [XY0+#DIR_FILE_SIZE]
                STOREZ  D0, [#FD_DIR_SIZE_LO]
                LOADD   D0, [XY0+#DIR_FILE_SIZE+2]
                STOREZ  D0, [#FD_DIR_SIZE_HI]

                ; ===== B. resolve NEW, same-dir, not-exist, create =====
                POP     XY0, XY3                ; [newp] -> XY0 = new path
                PUSH    XY0, XY3                ; restore stack symmetry
                LOADZ   D0, [#RNM_CWD_DRV]
                LOADZ   D1, [#RNM_CWD_CLU]
                CALLR   _ResolveParent          ; -> D0=drive_new, D1=parent_new
                BCS     .rf_err
                LOADZB  D2, [#FD_DRIVE_TMP]
                AND     D2, #$FF
                CMP     D0, D2
                BNE     .rf_invalid             ; different drive
                LOADZ   D2, [#RNM_PARENT_CL]
                CMP     D1, D2
                BNE     .rf_invalid             ; different directory

                ; operate inside the shared parent; D3 = drive (resolve ate it).
                LOADZ   D0, [#RNM_PARENT_CL]
                STOREZ  D0, [#DIR_WALK_CLU]
                LOADZB  D3, [#FD_DRIVE_TMP]
                AND     D3, #$FF

                ; new name must NOT already exist.
                CALLR   _DirLookupLong          ; RV_COMP = new leaf
                BCC     .rf_exists              ; found -> ERR_EXISTS
                CMP     D0, #ERR_NOTFOUND
                BNE     .rf_err                 ; ERR_IO etc.

                ; generate the new short name (dup already disproven above).
                LOADI   Y0, #$00
                LOADI   X0, #RV_COMP
                CALLR   _GenShortName           ; -> LFN_SHORT, D0 = needs_lfn
                BCS     .rf_err
                CMP     D0, #0
                BNE     .rf_lfn

                ; --- plain 8.3 short entry, carrying old attr/cluster/size ---
                LOADI   Y0, #$00
                LOADI   X0, #LFN_SHORT
                LOADZB  D0, [#FD_NAMEBUF2]      ; old attr
                AND     D0, #$FF
                LOADZ   D1, [#FD_DIR_FIRST_CL]  ; old cluster
                LOADZ   D2, [#FD_DIR_SIZE_LO]   ; old size low
                CALLR   _DirCreate
                BCS     .rf_err
                BRA     .rf_created

.rf_lfn:
                ; --- LFN run, carrying old attr/cluster/size ---
                CALLR   _CopyCompToLfnAsm       ; RV_COMP(new) -> LFN_ASM
                LOADZB  D0, [#FD_NAMEBUF2]      ; old attr
                AND     D0, #$FF
                LOADZ   D1, [#FD_DIR_FIRST_CL]  ; old cluster
                LOADZ   D2, [#FD_DIR_SIZE_LO]   ; old size low
                CALLR   _DirCreateRun
                BCS     .rf_err

.rf_created:
                ; _DicFormatShortEntry only wrote the low size word. For a
                ; file >= 64 KB lay down the full 32-bit size via the dirent
                ; patcher (skip otherwise — keeps the common path RMW-free).
                LOADZ   D0, [#FD_DIR_SIZE_HI]
                CMP     D0, #0
                BEQ     .rf_no_patch
                CALLR   _DirLookupLong          ; re-find new -> cookie
                BCS     .rf_err
                STOREZ  D0, [#FD_COOKIE_TMP]
                CALLR   _PatchDirentSizeCl      ; DIR_WALK_CLU + FD_DIR_* set
                BCS     .rf_err
.rf_no_patch:

                ; ===== C. delete the OLD whole-run =====
                POP     XY1, XY3                ; discard [newp]
                POP     XY0, XY3                ; [oldp] -> XY0 = old path
                ; stack now holds only [slot].
                LOADZ   D0, [#RNM_CWD_DRV]
                LOADZ   D1, [#RNM_CWD_CLU]
                CALLR   _ResolveParent          ; repopulate RV_COMP = old leaf
                BCS     .rf_err_slot
                LOADZ   D0, [#RNM_PARENT_CL]
                STOREZ  D0, [#DIR_WALK_CLU]
                LOADZB  D3, [#FD_DRIVE_TMP]
                AND     D3, #$FF
                CALLR   _DirDeleteRun           ; $E5 old fragments + short entry
                BCS     .rf_err_slot

                ; success.
                LOADI   D0, #0
                STOREZ  D0, [#DIR_WALK_CLU]
                POP     XY2, XY3                ; [slot]
                CLC
                RET

.rf_invalid:
                LOADI   D0, #ERR_INVALID
                BRA     .rf_err

.rf_exists:
                LOADI   D0, #ERR_EXISTS
                ; fall through

.rf_err:
                ; Regime 1 ([newp][oldp][slot] on stack). D0 = ERR_*.
                ; Reset DIR_WALK_CLU (preserve D0), unwind all three.
                PUSH    D0, XY3
                LOADI   D0, #0
                STOREZ  D0, [#DIR_WALK_CLU]
                POP     D0, XY3
                POP     XY1, XY3                ; discard [newp]
                POP     XY1, XY3                ; discard [oldp]
                POP     XY2, XY3                ; [slot]
                SEC
                RET

.rf_err_slot:
                ; Regime 2 (only [slot] on stack — reached after step C's pops).
                PUSH    D0, XY3
                LOADI   D0, #0
                STOREZ  D0, [#DIR_WALK_CLU]
                POP     D0, XY3
                POP     XY2, XY3                ; [slot]
                SEC
                RET


; ============================================================================
; ----------------------- KERNEL-SCRATCH SLOTS -----------------------------
; ============================================================================
; Page-$00 scratch slots used by Piece 5 (FD-layer syscalls) have been
; RELOCATED into kos_fs_defs.inc as of Part 36 (18 May 2026).
;
; See kos_fs_defs.inc for the declarations and kos_defs.inc "ZERO PAGE MAP
; — RULES" for the rationale (Gotchas 4.25 / 4.43 / 4.47 all stemmed from
; page-$00 scratch declared inside .asm files rather than the canonical
; defs files).
;
; All FD_* and FE_* symbols referenced in this file resolve via the
; .INCLUDE chain through kos_defs.inc → kos_fs_defs.inc.

; ============================================================================
; End of kos_fs_fd.asm
; ============================================================================
