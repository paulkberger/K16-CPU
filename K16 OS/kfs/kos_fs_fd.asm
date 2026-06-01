; ============================================================================
; kos_fs_fd.asm — k/OS Phase 16 Piece 5: file descriptor syscalls
; ============================================================================
; Date:    18 May 2026
; Status:  Part 34 — sys_write returns partial byte count on error
;
; Revision: r9 — 18 May 2026 — Part 34: sys_write now returns the
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
; FD_POSITION is a 24-bit byte offset (low word at +$08, high word at
; +$0A). Phase 16 caps single files well below 64 KB, so the high word
; is always 0 for now and we operate in 16 bits where convenient.
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
;   In:    XY0 = path "X:NAME.EXT" (nul-terminated, ≤ 14 chars)
;          D0  = open flags (FOPEN_READ|WRITE|CREATE|TRUNC|APPEND)
;   Out:   D0 = fd (0..7), C=0 on success
;          D0 = ERR_*, C=1 on failure
; ============================================================================
sys_open:
                DINT

                ; --- Per V2 ABI (Part 36 expansion):
                ; D1, D2, D3, XY1 all callee-preserved across syscalls.
                ; Part 36 r2: PUSH D1 added — _DirLookup and other helpers
                ; clobber D1 internally on deep paths (NOTFOUND, IO, etc.)
                ; and the body uses page-zero TMPs rather than re-loading
                ; caller's D1, so D1 must be saved at the boundary.
                PUSH    D2, XY3
                PUSH    D3, XY3
                PUSH    XY1, XY3                    ; Part 36: V2 ABI
                PUSH    D1, XY3                     ; Part 36 r2

                ; Stash open flags.
                STOREZ  D0, [#FD_OPEN_FLAGS]

                ; Parse path → drive in D3, FAT name in FD_NAMEBUF.
                LOADI   Y1, #$00
                LOADI   X1, #FD_NAMEBUF
                CALLR   _ParsePath
                BCS     .so_err

                ; Save drive.
                STOREZB D3, [#FD_DRIVE_TMP]

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

                ; Lookup name.
                LOADI   Y0, #$00
                LOADI   X0, #FD_NAMEBUF
                CALLR   _DirLookup
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
                ; D1, D2, D3, XY1 all callee-preserved across syscalls.
                ; Part 36 r2: PUSH D1 added — _FdFlushDirent and other
                ; helpers clobber D1 internally on deep paths.
                PUSH    D2, XY3
                PUSH    D3, XY3
                PUSH    XY1, XY3                    ; Part 36: V2 ABI
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
                ; D1, D2, D3, XY1 all callee-preserved across syscalls —
                ; *except* when documented as input/return registers.
                ; D1 is the count input arg here, legitimately consumed.
                PUSH    D2, XY3
                PUSH    D3, XY3
                PUSH    XY1, XY3                    ; Part 36: V2 ABI

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
                ; D1, D2, D3, XY1 all callee-preserved across syscalls —
                ; *except* when documented as input/return registers.
                ; D1 is both input arg (count) and return register
                ; (bytes-written), legitimately consumed/produced.
                PUSH    D2, XY3
                PUSH    D3, XY3
                PUSH    XY1, XY3                    ; Part 36: V2 ABI

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
                POP     XY1, XY3                    ; Part 36: V2 ABI
                POP     D3, XY3
                POP     D2, XY3
                RET

; ============================================================================
; sys_dirent — TRAP #30 — read N-th visible entry from a directory
;
;   In:    D0 = drive (0=A:, 1=B:)
;          D1 = index (0-based)
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
                ; D1, D2, D3, XY1 all callee-preserved across syscalls —
                ; *except* when documented as input/return registers.
                ; D1 is the index input arg here, legitimately consumed.
                PUSH    D2, XY3
                PUSH    D3, XY3
                PUSH    XY1, XY3                    ; Part 36: V2 ABI

                ; Stash drive (D0), index (D1), user buf (XY0).
                STOREZB D0, [#FD_DRIVE_TMP]
                STOREZ  D1, [#FD_INDEX_TMP]
                STOREZ  X0, [#FD_USERBUF_X]
                MOVE    D2, Y0                  ; D2 saved on stack — OK to clobber
                STOREZB D2, [#FD_USERBUF_Y]

                ; Resolve drive → XY2.
                LOADZB  D0, [#FD_DRIVE_TMP]
                AND     D0, #$FF
                CALLR   _SlotForDrive
                BCS     .sd_err

                LOADZB  D3, [#FD_DRIVE_TMP]
                AND     D3, #$FF

                ; --- Dirent iteration cache check (Part 22) --------------
                ; If the previous successful sys_dirent was on the same drive
                ; and at index = (this index - 1), AND the cache isn't empty,
                ; resume from LAST_COOKIE with iterations=1. Otherwise full
                ; walk from cookie=0 with iterations=index+1.
                LOADZ   D0, [#DIRENT_LAST_COOKIE]
                CMP     D0, #$FFFF
                BEQ     .sd_full_walk           ; cache empty
                LOADZB  D2, [#DIRENT_LAST_DRIVE]
                CMP     D2, D3
                BNE     .sd_full_walk           ; different drive
                LOADZ   D2, [#DIRENT_LAST_INDEX]
                ADD     D2, #1
                LOADZ   D1, [#FD_INDEX_TMP]
                CMP     D2, D1
                BNE     .sd_full_walk           ; non-sequential index

                ; Cache hit. D0 = saved cookie (already loaded above).
                ; D1 = requested index (just loaded). One iteration only.
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
                ; Stash for next time's cache lookup.
                STOREZ  D0, [#DIRENT_LAST_COOKIE]
                LOADZ   D1, [#FD_INDEX_TMP]
                STOREZ  D1, [#DIRENT_LAST_INDEX]
                STOREZB D3, [#DIRENT_LAST_DRIVE]

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

                ; Restore callee-saved XY1, D3, D2.
                POP     XY1, XY3                    ; Part 36: V2 ABI
                POP     D3, XY3
                POP     D2, XY3
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
;   Out:   XY1 = Y3:FD_TABLE + fd*12 (fd table lives in caller's task page)
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

                LOADD   D0, [XY2+#VOL_ROOT_START]
                ADD     D0, D1
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
                LOADI   Y0, #$00
                LOADI   X0, #FD_NAMEBUF
                LOADI   D0, #0                  ; attr = 0
                LOADI   D1, #0                  ; cluster = 0
                LOADI   D2, #0                  ; size = 0
                CALLR   _DirCreate
                BCS     .cee_err

                LOADI   Y0, #$00
                LOADI   X0, #FD_NAMEBUF
                CALLR   _DirLookup
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

                LOADD   D0, [XY2+#VOL_ROOT_START]
                ADD     D0, D1
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
                LOADD   D0, [XY1+#FD_DIR_COOKIE]
                STOREZ  D0, [#FD_COOKIE_TMP]
                CALLR   _LoadDirentFromCookie
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
                ; remaining = file_size - position (Phase 16: low word only).
                LOADD   D1, [XY1+#FD_POSITION]
                LOADZ   D2, [#FD_DIR_SIZE_LO]
                CMP     D1, D2
                BHS     .fcr_eof
                SUB     D2, D1                  ; D2 = file_remain
                CMP     D2, D0
                BHS.S   .fcr_done
                MOVE    D0, D2

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
                LOADZ   D2, [#FD_CHUNK_TMP]

                ; Compute byte_off first while XY1 is still slot.
                LOADD   D0, [XY1+#FD_POSITION]
                AND     D0, #$01FF
                ADD     D0, #FS_BUF_SECTOR
                LOADI   Y0, #$00
                MOVE    X0, D0                  ; XY0 = src

                LOADZ   D1, [#FD_USERBUF_X]

                MOVE    X1, D1

                LOADZB  D1, [#FD_USERBUF_Y]

                MOVE    Y1, D1

.fctu_loop:
                LOADB   D0, [XY0]
                STOREB  D0, [XY1]
                ADD     X0, #1
                ADD     X1, #1
                SUB     D2, #1
                BNE     .fctu_loop
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
                LOADZ   D2, [#FD_CHUNK_TMP]

                ; Compute dest = FS_BUF_SECTOR + byte_off; XY1 still slot.
                LOADD   D1, [XY1+#FD_POSITION]
                AND     D1, #$01FF
                ADD     D1, #FS_BUF_SECTOR
                LOADI   Y1, #$00
                MOVE    X1, D1                  ; XY1 = dest

                LOADZ   D1, [#FD_USERBUF_X]

                MOVE    X0, D1

                LOADZB  D1, [#FD_USERBUF_Y]

                MOVE    Y0, D1

.fcfu_loop:
                LOADB   D0, [XY0]
                STOREB  D0, [XY1]
                ADD     X0, #1
                ADD     X1, #1
                SUB     D2, #1
                BNE     .fcfu_loop
                RETCC

; ============================================================================
; _FdAdvancePosition — pos += D0; walk FAT if cluster boundary crossed
;
;   In:    D0 = chunk, XY1 = slot, XY2 = vol, D3 = drive
;   Out:   C=0 / C=1 with D0=ERR_IO
;   Clobbers: D0, D1, D2, X0, X1, Y0, Y1, flags
;   Preserves: D3, XY2, XY3
;
;   Phase 16: position fits in 16 bits. We compute (old >> 9) vs
;   (new >> 9) using HIGH + SHR (HIGH = >>8, then >>1 = >>9).
; ============================================================================
_FdAdvancePosition:
                LOADD   D1, [XY1+#FD_POSITION]
                MOVE    D2, D1
                ADD     D2, D0                  ; D2 = new pos low

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
                ; (high word stays 0)

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
; _FdAdvancePositionAndSize — like above, also bumps FD_DIR_SIZE_LO if
;                              new position > old size
;
;   _FdAdvancePosition leaves XY1 valid (it re-derives internally on the
;   FAT-walk path and never clobbers it on the no-cross path), so this
;   wrapper can read FD_POSITION via XY1 directly.
; ============================================================================
_FdAdvancePositionAndSize:
                CALLR   _FdAdvancePosition
                BCS     .faps_err
                LOADD   D1, [XY1+#FD_POSITION]
                LOADZ   D2, [#FD_DIR_SIZE_LO]
                CMP     D2, D1
                BHS.S   .faps_done
                STOREZ  D1, [#FD_DIR_SIZE_LO]
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

                ; byte_off == 0
                LOADD   D0, [XY1+#FD_POSITION]
                CMP     D0, #0                  ; LOAD doesn't set flags; explicit CMP needed
                BEQ     .fec_done               ; (3): pos==0

                ; pos > 0, byte_off == 0
                LOADZ   D1, [#FD_DIR_SIZE_LO]
                CMP     D0, D1
                BLO     .fec_advance_existing   ; (4)
                ; (5)
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
;     2. New size = max(stored_size, FD_POSITION).
;     3. New first_cluster = slot's FD_FIRST_CLUSTER.
;     4. RMW.
;     5. Flush FAT cache (chain may be dirty).
; ============================================================================
_FdFlushDirent:
                LOADD   D0, [XY1+#FD_DIR_COOKIE]
                STOREZ  D0, [#FD_COOKIE_TMP]
                CALLR   _LoadDirentFromCookie
                BCS     .ffd_io

                ; (After block I/O, XY1 was clobbered. Re-derive.)
                LOADZB  D0, [#FD_RESULT_TMP]
                AND     D0, #$FF
                CALLR   _FdAddr

                ; New size = max(old, position low).
                LOADD   D0, [XY1+#FD_POSITION]
                LOADZ   D1, [#FD_DIR_SIZE_LO]
                CMP     D1, D0
                BHS.S   .ffd_size_ok
                STOREZ  D0, [#FD_DIR_SIZE_LO]
.ffd_size_ok:

                LOADD   D0, [XY1+#FD_FIRST_CLUSTER]
                STOREZ  D0, [#FD_DIR_FIRST_CL]

                CALLR   _PatchDirentSizeCl
                BCS     .ffd_io

                CALLR   _FATFlush
                BCS     .ffd_io

                RETCC

.ffd_io:
                LOADI   D0, #ERR_IO
                RETCS

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
                LOADI   D2, #FS_DIR_ENTRY_SIZE  ; 32
.fei_zero:
                STOREB  D0, [XY1]
                ADD     X1, #1
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

                RETCC


; ============================================================================
; sys_unlink — TRAP #37 — delete a file by path
; ============================================================================
;
;   In:    XY0 = pointer to nul-terminated path ("B:NAME.EXT")
;   Out:   C=0 on success
;          C=1 with D0 = ERR_BADPATH    malformed path
;                       ERR_BADDRIVE    drive not mounted
;                       ERR_NOTFOUND    no such file
;                       ERR_READONLY    target volume is read-only
;                       ERR_IO          block read/write failed
;   Clobbers: D0, XY0
;   Preserves: D1, D2, D3, XY1, XY2, XY3           ; V2 ABI (Part 36)
;
; Pattern follows sys_format: non-leaf, DINT at entry, gate EINT on
; KERNEL_STATE == KERN_STATE_RUN at exit (gotcha 4.6). PUSH D2/D3/XY1
; per V2 ABI (Part 36 — XY1 added to callee-preserved set).
; ============================================================================
sys_unlink:
                DINT
                PUSH    D2, XY3
                PUSH    D3, XY3
                PUSH    XY1, XY3                    ; Part 36: V2 ABI
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

                ; --- 1. Parse path into FD_NAMEBUF, get drive in D3 -------
                LOADI   Y1, #$00
                LOADI   X1, #FD_NAMEBUF
                CALLR   _ParsePath
                BCS     .df_err_pop             ; ERR_BADPATH

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

                ; --- 3. _DirLookup --------------------------------------
                ; XY0 = FD_NAMEBUF (11-byte FAT name).
                LOADI   Y0, #$00
                LOADI   X0, #FD_NAMEBUF
                CALLR   _DirLookup
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

                ; --- 5. Free the cluster chain ----------------------------
                LOADZ   D0, [#FD_NAMEBUF2]
                CALLR   _FATFreeChain
                BCS     .df_err_pop             ; ERR_IO

                ; --- 6. Flush FAT ----------------------------------------
                CALLR   _FATFlush
                BCS     .df_err_pop             ; ERR_IO

                ; --- 7. _DirDelete --------------------------------------
                ; _DirDelete needs XY0 = 11-byte FAT name, XY2 = slot,
                ; D3 = drive. XY2 and D3 are still set; reload XY0.
                LOADI   Y0, #$00
                LOADI   X0, #FD_NAMEBUF
                CALLR   _DirDelete
                BCS     .df_err_pop

                POP     XY2, XY3
                RETCC

.df_err_pop:
                ; D0 already set by callee. Just unwind and bubble up.
                POP     XY2, XY3
                RETCS


; ============================================================================
; sys_rename — TRAP #38 — rename a file (same drive only)
; ============================================================================
;
;   In:    XY0 = pointer to nul-terminated old path ("B:OLD.TXT")
;          XY1 = pointer to nul-terminated new path ("B:NEW.TXT")
;   Out:   C=0 on success
;          C=1 with D0 = ERR_BADPATH    malformed path
;                       ERR_INVALID     drives differ (kosh uses this
;                                       signal to fall back to cp+unlink)
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
;   The new-name pre-check is "must NOT be found" — if _DirLookup on the
;   new name succeeds, we return ERR_EXISTS. Same semantics as cp's
;   pre-flight existence check, applied at the kernel level so kosh's
;   mv command doesn't need to duplicate it.
; ============================================================================
sys_rename:
                DINT
                PUSH    D2, XY3
                PUSH    D3, XY3
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
                POP     D3, XY3
                POP     D2, XY3
                RET


; ============================================================================
; _RenameFile — kernel-internal: same-drive rename
; ============================================================================
;
;   Algorithm:
;     1. _ParsePath(oldpath)  → drive_old in D3, FD_NAMEBUF
;     2. Stash drive_old in FD_DRIVE_TMP
;     3. _ParsePath(newpath)  → drive_new in D3, FD_NAMEBUF2
;     4. Compare drives — different → ERR_INVALID
;     5. _SlotForDrive(D3)    → XY2
;        (Read-only check is implicit via _VolBlockWrite at step 10.)
;     6. _DirLookup(FD_NAMEBUF2) — new name must NOT exist → ERR_EXISTS
;     7. _DirLookup(FD_NAMEBUF) — find old entry's sector/cookie
;     8. RMW: overwrite the 11 name bytes at entry_addr with FD_NAMEBUF2
;     9. Write the sector back (returns ERR_READONLY here if A:)
;    10. Invalidate dir cache (so subsequent lookups see new name)
;
;   In:    XY0 = old path,  XY1 = new path
;   Out:   C=0 on success
;          C=1 with D0 = ERR_*
;   Clobbers: D0, D1, D2, D3, XY0, XY1   (XY2/XY3 preserved)
; ============================================================================
_RenameFile:
                PUSH    XY2, XY3
                PUSH    XY1, XY3                ; save new-path pointer

                ; --- 1. Parse old path → FD_NAMEBUF ----------------------
                ; XY0 already = old path.
                LOADI   Y1, #$00
                LOADI   X1, #FD_NAMEBUF
                CALLR   _ParsePath
                BCS     .rf_err_pop2            ; ERR_BADPATH

                ; --- 2. Stash drive_old ----------------------------------
                STOREZB D3, [#FD_DRIVE_TMP]

                ; --- 3. Parse new path → FD_NAMEBUF2 ---------------------
                POP     XY0, XY3                ; XY0 = new path
                PUSH    XY0, XY3                ; restore stack symmetry
                LOADI   Y1, #$00
                LOADI   X1, #FD_NAMEBUF2
                CALLR   _ParsePath
                BCS     .rf_err_pop2            ; ERR_BADPATH

                ; --- 4. drive_old == drive_new ? -------------------------
                LOADZB  D0, [#FD_DRIVE_TMP]
                CMP     D0, D3
                BNE     .rf_diffdrive

                ; --- 5. _SlotForDrive(D3) → XY2 --------------------------
                MOVE    D0, D3
                CALLR   _SlotForDrive
                BCS     .rf_err_pop2            ; ERR_BADDRIVE

                ; Read-only check is implicit — the _VolBlockWrite at step
                ; 9 will return ERR_READONLY if the slot's write pointer
                ; is null (e.g. A:).

                ; --- 6. New name must NOT exist --------------------------
                ; _DirLookup on FD_NAMEBUF2; success → ERR_EXISTS.
                LOADI   Y0, #$00
                LOADI   X0, #FD_NAMEBUF2
                CALLR   _DirLookup
                BCC     .rf_exists              ; FOUND → bad
                ; D0 should be ERR_NOTFOUND (good) or ERR_IO (bubble up).
                CMP     D0, #ERR_NOTFOUND
                BNE     .rf_err_pop2            ; ERR_IO etc.
                ; Fall through — new name is absent, proceed.

                ; --- 7. _DirLookup on old name ---------------------------
                ; This populates FS_BUF_SECTOR with the matching root-dir
                ; sector and returns the cookie.
                LOADI   Y0, #$00
                LOADI   X0, #FD_NAMEBUF
                CALLR   _DirLookup
                BCS     .rf_err_pop2            ; ERR_NOTFOUND or ERR_IO

                ; D0 = cookie. Save for sector address calc.
                MOVE    D1, D0
                SHR4    D1                      ; D1 = sec_off
                MOVE    D2, D0
                AND     D2, #$0F                ; D2 = ent_idx

                ; --- 8. entry_addr = FS_BUF_SECTOR + ent_idx * 32 -------
                MOVE    D0, D2
                SHL4    D0
                SHL     D0
                ADD     D0, #FS_BUF_SECTOR
                LOADI   Y1, #$00
                MOVE    X1, D0                  ; XY1 = entry_addr (page $00)

                ; Copy 11 bytes from FD_NAMEBUF2 → entry_addr.
                LOADI   Y0, #$00
                LOADI   X0, #FD_NAMEBUF2
                LOADI   D0, #11
.rf_copy:
                LOADB   D2, [XY0]
                STOREB  D2, [XY1]
                INC     XY0, #1
                INC     XY1, #1
                SUB     D0, #1
                BNE     .rf_copy

                ; --- 9. Write the sector back ---------------------------
                ; abs_sec = VOL_ROOT_START + sec_off (D1).
                LOADD   D0, [XY2+#VOL_ROOT_START]
                ADD     D0, D1                  ; absolute sector
                LOADI   Y0, #$00
                LOADI   X0, #FS_BUF_SECTOR
                CALLR   _VolBlockWrite
                BCS     .rf_err_pop2            ; ERR_IO / ERR_READONLY

                ; --- 10. Invalidate dir cache ----------------------------
                ; The cached sector contents have just changed beneath us;
                ; the cache identity (sector+drive) is still technically
                ; valid, but to keep things simple we invalidate so the
                ; next _DirLookup re-reads. (Cheap.)
                LOADI   D0, #$FFFF
                STOREZ  D0, [#DIR_CACHE_SECTOR]
                ; Also invalidate the dirent-iteration cache — a rename
                ; doesn't change positions but plays it safe.
                STOREZ  D0, [#DIRENT_LAST_COOKIE]

                POP     XY1, XY3                ; balance the new-path push
                POP     XY2, XY3
                RETCC

.rf_diffdrive:
                LOADI   D0, #ERR_INVALID
                BRA.S   .rf_err_pop2_set

.rf_exists:
                LOADI   D0, #ERR_EXISTS
                ; Fall through.

.rf_err_pop2_set:
                POP     XY1, XY3
                POP     XY2, XY3
                RETCS

.rf_err_pop2:
                ; D0 already holds the ERR_* from the failed callee.
                POP     XY1, XY3
                POP     XY2, XY3
                RETCS


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
