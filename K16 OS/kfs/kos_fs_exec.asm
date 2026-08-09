; ============================================================================
; kos_fs_exec.asm — k/OS Phase 16 Piece 6: sys_exec syscall
; ============================================================================
; Date:    8 May 2026
; Status:  Phase 16 Piece 6 — sys_exec (TRAP #31). Loads a .COM file from
;          disk into a fresh user page and starts it as a new task.
;          Part 20a ABI audit done.
;
; Revision: r4 — 12 May 2026 — dir-cache coherence fix in _ExecCopyChain.
;             _ExecCopyChain reads file-data sectors into FS_BUF_SECTOR via
;             _VolBlockRead, but did NOT invalidate DIR_CACHE_SECTOR /
;             DIR_CACHE_DRIVE. Per the Part 22 protocol (see _FdReadCurrSector
;             in kos_fs_fd.asm), any non-_DirNextRaw write to FS_BUF_SECTOR
;             MUST invalidate the dir cache, or _DirNextRaw's cache check
;             will skip the next sector read and serve file data parsed as
;             dirents.
;
;             Symptom: cold boot → run C:CUBE2.COM → ls c: shows garbage
;             (e.g. "=>>>???@.@@@  BIG  21041 KB"). `remount c` clears the
;             stale cache and ls works again. Bug is independent of cube2;
;             any .COM read on any drive would trigger it.
;
;             Fix: single CALLR _DirCacheInvalidate at top of _ExecCopyChain,
;             before the first _VolBlockRead. _DirCacheInvalidate is idempotent
;             and clobbers only D0 (which _ExecCopyChain overwrites in its
;             first instruction anyway), so the call is free.
;
;             Same bug class as kOS_Gotchas 4.29 — established buffer-protocol
;             invariant violated by a newer code path. Worth a dedicated
;             gotcha entry (lying preservation of cache invariants).
;
; Revision: r3 — 8 May 2026 — Part 20a ABI audit fix.
;             sys_exec now preserves D2, D3 and XY2 across the call per
;             V2 ABI. Body uses D3 as drive number and XY2 as volume slot
;             throughout, and the helpers _ExecCopyChain / _ExecCopyOneSector
;             / _ExecStageName all clobber D2 (used as counters / via
;             _FATGetEntry). Without saves at the syscall boundary, callers
;             that stash state in D2/D3/XY2 see it overwritten — same class
;             of bug as the sys_read/sys_write/sys_dirent fix in
;             kos_fs_fd.asm r3.
;             Save sequence mirrors the canonical kos_fs_fd.asm pattern:
;             PUSH D2 / PUSH D3 / PUSH XY2 immediately after DINT;
;             matching POPs after the SR-gated EINT (POP doesn't disturb
;             flags, so the C-bit result survives).
;
; Revision: r2 — 8 May 2026 — FE_* slots shifted +1 to follow the new
;             FD_DIRENT_RAW end at $03BB (per Gotcha #30 alignment fix in
;             kos_fs_fd.asm r4). New layout:
;               FE_NEW_PAGE   $03BC (byte; pad at $03BD)
;               FE_FLAGS      $03BE (word)
;               FE_DEST_OFF   $03C0 (word)
;               FE_BYTES_LEFT $03C2 (word)
;               FE_CURR_CL    $03C4 (word)
;               FE_CHUNK_TMP  $03C6 (word)
;             No code changes — only constant addresses.
;
;           r1 — 6 May 2026 — initial. Provides:
;             • sys_exec    (TRAP #31)
;
;           Plus internal helpers:
;             • _ExecCheckExt        verify FD_NAMEBUF[8..10] = "COM"
;             • _ExecCopyChain       walk cluster chain, copy to user page
;             • _ExecCopyOneSector   read sector → FS_BUF_SECTOR; copy to dest
;             • _ExecStageName       set BT_NAME from base of FD_NAMEBUF
;
; --- Spec recap (kOS_FS_Reference §9.6) ------------------------------------
;
; In:    XY0  pointer to nul-terminated path ("A:HELLO.COM")
;        XY1  ASCIIZ arg tail in caller page when D0.bit2 (EXEC_HAS_ARGS) set (Part 15)
;        D0   flags
;               bit 0 = block (wait for child to exit)   [reserved P16; ignored]
;               bit 1 = EXEC_FOREGROUND  auto-foreground child when it registers as a shell
;               bit 2 = EXEC_HAS_ARGS    XY1 = ASCIIZ arg tail (Part 15)
; Out:   D0   child's TID on success
;        C=0  success
;        C=1  failure with D0 = ERR_BADPATH / ERR_NOTFOUND / ERR_NOTEXEC /
;                              ERR_NOMEM / ERR_NOSPACE (no TCB) / ERR_IO
;
; Phase 16 ignores the block flag; a future phase will add sys_wait coupling.
; The TID return is correct for both block values today.
;
; --- Implementation flow ---------------------------------------------------
;
; 1. _ResolveParent → drive, parent cluster; leaf 11-byte name -> FD_NAMEBUF
;    (Part 44: resolved relative to the CWD context in D1/D2).
; 2. Check FD_NAMEBUF[8..10] = "COM" else ERR_NOTEXEC.
; 3. _SlotForDrive → XY2.
; 4. DIR_WALK_CLU = parent; _DirLookup → cookie of file or ERR_NOTFOUND.
; 5. _LoadDirentFromCookie → FD_DIR_FIRST_CL, FD_DIR_SIZE_LO/HI.
; 6. Validate: size > 0 and size ≤ SPAWN_MAX_LEN; first cluster ≥ 2.
; 7. _AllocPage → new_page (D0). On fail → ERR_NOMEM.
; 8. _ExecCopyChain: walk FAT, read each cluster's sector into FS_BUF_SECTOR,
;    byte-copy into new_page:$0200..$0200+size-1.
; 9. Stage BT_* slots, including BT_NAME from base name.
; 10. _BuildTask → returns TCB ptr in D0.
; 11. Pull TCB_ID out of new TCB → D0.
; 12. EINT-on-KERNEL_STATE epilogue, RET.
;
; --- Failure semantics -----------------------------------------------------
;
; Per spec §7.4 there is no _FreePage. If sys_exec succeeds in _AllocPage
; but a later step fails (rare — only _ExecCopyChain or _BuildTask), the
; page leaks until next reboot. Acceptable for Phase 16; matches existing
; sys_spawn behaviour.
;
; ============================================================================

; ============================================================================
; sys_exec — TRAP #31 — load .COM and spawn it as a task
;
;   In:    XY0 = path "X:NAME.COM", CWD-relative, or a subpath
;          D0  = flags (bit 0 = block; reserved/ignored in P16)
;          D1  = CWD cluster (0 = root)   — Part 44, for relative paths
;          D2  = CWD drive index          — Part 44, start drive when no "X:"
;   Out:   D0 = new task TID, C=0 on success
;          D0 = ERR_*, C=1 on failure
; ============================================================================
sys_exec:
                DINT

                ; --- Per V2 ABI (Part 36 expansion):
                ; Register contract: see kos_defs.inc, SYSCALL REGISTER CONTRACT.
                ; Body uses D3 (drive) and XY2 (volume slot) directly;
                ; helpers _ExecCopyChain et al. clobber D2 internally.
                ; Part 36 r2: PUSH D1 added — _DirLookup and other helpers
                ; clobber D1 internally on deep paths.
                PUSH    D2, XY3
                PUSH    D3, XY3
                PUSH    XY1, XY3                    ; Part 36: V2 ABI
                PUSH    XY2, XY3
                PUSH    D1, XY3                     ; Part 36 r2

                ; Stash flags (currently unused in P16, but recorded for P17+).
                STOREZ  D0, [#FE_FLAGS]

                ; Part 16: stash the inherited CWD (D1=cluster, D2=drive) before
                ; _ResolveParent clobbers them; written into the child TCB after
                ; _BuildTask so the child resolves bare paths from this CWD.
                STOREZ  D1, [#FE_CWD_CLU]
                STOREZ  D2, [#FE_CWD_DRIVE]

                ; Part 15: capture argv-tail offset before helpers clobber XY1.
                ; Caller page = Y3 (stable for the whole syscall). X1 = tail
                ; offset in the caller page when EXEC_HAS_ARGS set, else none.
                LOADI   D0, #0
                STOREZ  D0, [#FE_ARGV_OFF]     ; default: no args
                LOADZ   D0, [#FE_FLAGS]
                AND     D0, #EXEC_HAS_ARGS
                BEQ     .se_no_args_in
                MOVE    D0, X1
                STOREZ  D0, [#FE_ARGV_OFF]
.se_no_args_in:

                ; --- Part 44: resolve parent relative to CWD --------------
                ; D2 = CWD drive, D1 = CWD clu. _ResolveParent -> drive (D0),
                ; parent cluster (D1), leaf 11-byte name in RV_FATNAME.
                MOVE    D0, D2
                CALLR   _ResolveParent
                BCS     .se_err
                STOREZB D0, [#FD_DRIVE_TMP]     ; drive
                MOVE    D3, D0
                STOREZ  D1, [#FD_PARENT_CL]     ; parent cluster
                CALLR   _CopyLeafToNamebuf      ; RV_FATNAME -> FD_NAMEBUF

                ; --- Resolve drive → XY2 (needed before the lookup) -------
                MOVE    D0, D3
                CALLR   _SlotForDrive
                BCS     .se_err

                ; --- Look up file (long-aware) in the resolved parent -----
                ; Part 45: _DirLookupLong matches by long name (RV_COMP) or 8.3
                ; (RV_FATNAME); RV_* are still set from _ResolveParent above. A
                ; long-named .COM has no usable FD_NAMEBUF, so the lookup AND the
                ; extension check must run off the matched entry, not FD_NAMEBUF.
                LOADZ   D0, [#FD_PARENT_CL]
                STOREZ  D0, [#DIR_WALK_CLU]
                CALLR   _DirLookupLong
                BCS     .se_lookup_failed

                STOREZ  D0, [#FD_COOKIE_TMP]

                ; --- Adopt the matched SHORT name (Part 45) ---------------
                ; FD_NAMEBUF from _CopyLeafToNamebuf is only valid for an 8.3
                ; leaf; for a long name it is garbage. Copy the matched short
                ; entry's 11-byte name out of FS_BUF_SECTOR so the extension
                ; check and task-name staging see a real 8.3 "NAME    COM".
                CALLR   _ExecCopyShortName

                ; --- Verify extension is "COM" ----------------------------
                CALLR   _ExecCheckExt
                BCS     .se_err

                ; --- Load dirent details (first cluster + size) -----------
                ; _LoadDirentFromCookie takes the cookie in D0, but the calls
                ; above (_ExecCopyShortName, _ExecCheckExt) clobber D0 — reload
                ; it from FD_COOKIE_TMP first.
                LOADZ   D0, [#FD_COOKIE_TMP]
                CALLR   _LoadDirentFromCookie     ; uses DIR_WALK_CLU = parent
                BCS     .se_err

                ; --- Validate size: 0 < size ≤ SPAWN_MAX_LEN --------------
                LOADZ   D0, [#FD_DIR_SIZE_HI]
                CMP     D0, #0
                BNE     .se_too_big             ; >65535 always too big
                LOADZ   D0, [#FD_DIR_SIZE_LO]
                CMP     D0, #0
                BEQ     .se_not_exec            ; empty file is not executable
                ; Want: if D0 > SPAWN_MAX_LEN → too_big. BHI not implemented
                ; (gotcha 3.6); synthesise via reversed CMP + BLO.
                LOADI   D1, #SPAWN_MAX_LEN
                CMP     D1, D0                  ; D1 < D0 ⇔ D0 > D1
                BLO     .se_too_big

                ; --- Validate first cluster ≥ 2 ---------------------------
                LOADZ   D0, [#FD_DIR_FIRST_CL]
                CMP     D0, #CLUSTER_FIRST_VALID
                BLO     .se_not_exec            ; empty/invalid chain

                ; --- Allocate a fresh user page ---------------------------
                ; CALL24 _AllocPage doesn't document its preserves — must
                ; assume D3 and XY2 are clobbered. Re-derive both after.
                ; --- Parse the .COM header (Part 60) ---------------------
                ; Must happen BEFORE the allocation, because the page count
                ; is what we are about to allocate - and allocation precedes
                ; the copy, so the header cannot be read back from the loaded
                ; page.  _ExecReadHeader reads the image's first sector into
                ; FS_BUF_SECTOR and leaves the parsed values in FE_PAGES /
                ; FE_HEAPPG.  On failure D0 already carries ERR_NOTEXEC or
                ; ERR_IO with C=1, so .se_err needs no special case.
                CALLR   _ExecReadHeader
                BCS     .se_err

                ; --- Allocate the destination page RUN --------------------
                ; CALL24 _AllocPageRun doesn't document its preserves - must
                ; assume D3 and XY2 are clobbered. Re-derive both after.
                LOADZ   D0, [#FE_PAGES]
                CALL24  _AllocPageRun
                BCS     .se_nomem
                ; D0 = new page byte. Stash BEFORE any further calls.
                STOREZB D0, [#FE_NEW_PAGE]

                ; --- Re-derive D3 (drive) and XY2 (slot) ------------------
                LOADZB  D3, [#FD_DRIVE_TMP]
                AND     D3, #$FF
                MOVE    D0, D3
                CALLR   _SlotForDrive
                BCS     .se_err                 ; should never happen here

                ; --- Walk cluster chain, copy bytes into new_page:$0200 ---
                ; XY2 = volume slot, D3 = drive (just restored).
                ; FE_NEW_PAGE has destination page byte.
                ; FD_DIR_FIRST_CL has starting cluster.
                ; FD_DIR_SIZE_LO has byte count to copy.
                CALLR   _ExecCopyChain
                BCS     .se_err

                ; --- Stage BT_* slots for _BuildTask ----------------------
                LOADI   D0, #SPAWN_ENTRY_OFFSET
                STOREZ  D0, [#BT_ENTRY_LO]

                LOADZB  D0, [#FE_NEW_PAGE]
                AND     D0, #$FF
                STOREZ  D0, [#BT_ENTRY_PG]
                STOREZ  D0, [#BT_PRIMARY]

                ; Part 60: the page count the header asked for and the
                ; allocator granted.  Staged HERE rather than at parse time:
                ; _BuildTask consumes BT_PCOUNT, so a value left behind by an
                ; error path between the parse and the build would be
                ; inherited by the NEXT spawn.  FE_PAGES is the carry-across
                ; precisely so BT_PCOUNT is only ever written on the path
                ; that goes on to build.
                LOADZ   D0, [#FE_PAGES]
                STOREZ  D0, [#BT_PCOUNT]

                ; Parent = current task TID. CURRENT_TCB holds TCB ptr;
                ; read TCB_ID from it. (Idle/boot context: CURRENT_TCB
                ; may be IDLE_TCB; that's fine — its TCB_ID = 0.)
                LOADZ   D0, [#CURRENT_TCB]
                LOADI   Y1, #$00
                MOVE    X1, D0
                LOADD   D0, [XY1+#TCB_ID]
                STOREZ  D0, [#BT_PARENT_ID]

                ; --- Stage BT_NAME from base name -------------------------
                CALLR   _ExecStageName
                ; --- Stage argv block at child:$0100 (Part 15) ------------
                CALLR   _ExecStageArgs

                ; --- Build the task ---------------------------------------
                ; XY2 isn't needed after this point so no need to save it.
                CALL24  _BuildTask
                BCS     .se_noslots
                ; D0 = new TCB ptr. XY1 := child TCB.
                LOADI   Y1, #$00
                MOVE    X1, D0
                ; Part 16: inherit CWD into the child TCB. Offsets $26/$28 exceed imm5,
                ; so index via D3 (mode-01 [XY+D]). D0/D3 are reloaded below.
                LOADI   D3, #TCB_CWD_DRIVE
                LOADZ   D0, [#FE_CWD_DRIVE]
                STORED  D0, [XY1+D3]
                LOADI   D3, #TCB_CWD_CLU
                LOADZ   D0, [#FE_CWD_CLU]
                STORED  D0, [XY1+D3]
                ; Part 51: tag child for auto-foreground when it registers as a
                ; shell, if launched with EXEC_FOREGROUND (consumed by
                ; sys_register_shell). FE_FLAGS holds the stashed exec flags.
                LOADZ   D0, [#FE_FLAGS]
                AND     D0, #EXEC_FOREGROUND
                BEQ.S   .se_no_autofg
                LOADD   D0, [XY1+#TCB_FLAGS]
                OR      D0, #TF_AUTOFG
                STORED  D0, [XY1+#TCB_FLAGS]
.se_no_autofg:
                ; Read child TCB_ID for return LAST (D0 = return value).
                LOADD   D0, [XY1+#TCB_ID]

                CLC
                BRA     .se_done

.se_lookup_failed:
                ; D0 = ERR_NOTFOUND or ERR_IO. Both already set with C=1.
                BRA     .se_err

.se_not_exec:
                LOADI   D0, #ERR_NOTEXEC
                SEC
                BRA     .se_done

.se_too_big:
                LOADI   D0, #ERR_NOTEXEC        ; no ERR_TOOBIG defined yet;
                                                ; fold into NOTEXEC per spec
                SEC
                BRA     .se_done

.se_nomem:
                LOADI   D0, #ERR_NOMEM
                SEC
                BRA     .se_done

.se_noslots:
                ; _BuildTask returned C=1 (D0 = 0). Per spec §9.6, the
                ; appropriate error is ERR_NOSLOTS.
                LOADI   D0, #ERR_NOSLOTS
                SEC
                BRA     .se_done

.se_err:
                SEC

.se_done:
                ; Part 44: restore DIR_WALK_CLU root default (single exit funnel;
                ; preserve the return value in D0 across the store).
                PUSH    D0, XY3
                LOADI   D0, #0
                STOREZ  D0, [#DIR_WALK_CLU]
                POP     D0, XY3

                ; Gate EINT on KERNEL_STATE (gotcha 4.6).
                ; Part 36: stash D0 (return) across the gate; D1 is now
                ; callee-preserved per V2 ABI.
                PUSH    SR, XY3
                PUSH    D0, XY3
                LOADZ   D0, [#KERNEL_STATE]
                LOW     D0
                CMP     D0, #KERN_STATE_RUN
                POP     D0, XY3
                BNE.S   .se_skip_eint
                EINT
.se_skip_eint:
                POP     SR, XY3

                ; Restore callee-saved D1, XY2, XY1, D3, D2 (POP doesn't disturb flags).
                POP     D1, XY3                     ; Part 36 r2
                POP     XY2, XY3
                POP     XY1, XY3                    ; Part 36: V2 ABI
                POP     D3, XY3
                POP     D2, XY3
                RET

; ============================================================================
; ----------------------- INTERNAL HELPERS ---------------------------------
; ============================================================================

; ============================================================================
; _ExecReadHeader - read and validate the .COM header            [Part 60]
;
;   In:    XY2 = volume slot ptr
;          D3  = drive index (for _FATGetEntry / backend cache identity)
;          FD_DIR_FIRST_CL = file's first cluster (>= 2, already validated)
;          FD_DIR_SIZE_LO  = file size in bytes (non-zero, already validated)
;   Out:   C=0, FE_PAGES / FE_HEAPPG set from the header
;          C=1 with D0 = ERR_BADHEADER (bad or absent header), or ERR_IO /
;          ERR_INVALID from the sector read. The code is propagated to
;          .se_err unchanged, so `run` reports which of the two it was.
;   Clobbers: D0, D1, D2, X0, X1, Y0, Y1, flags
;   Preserves: D3, XY2, XY3
;
;   The loader needs the page count BEFORE it allocates, and allocation
;   precedes the copy - so the header must come from the FILE, not from the
;   loaded page.  We read the first sector of the chain into FS_BUF_SECTOR
;   and parse it there; _ExecCopyChain then re-reads that same sector as
;   part of its normal walk.  One redundant 512-byte read per exec, which
;   buys leaving a working copy routine completely untouched.
;
;   FS_BUF_SECTOR is even-aligned, so _ComHeaderCheck's word read at +$04
;   is safe.
;
;   DIR-CACHE COHERENCE (Part 22 protocol, Gotcha 4.47 family): any
;   non-_DirNextRaw write to FS_BUF_SECTOR MUST invalidate the dir cache,
;   or _DirNextRaw will skip its next sector read and serve file data
;   parsed as dirents.  _ExecCopyChain does this at its own entry; we are
;   the first writer now, so we must do it too rather than rely on a
;   routine that runs after us.
;
;   Called only after FD_DIR_FIRST_CL and FD_DIR_SIZE_LO have been read out
;   of the dirent into page-$00, so clobbering FS_BUF_SECTOR here costs
;   nothing.
; ============================================================================
_ExecReadHeader:
                CALLR   _DirCacheInvalidate     ; we are about to write
                                                ; FS_BUF_SECTOR

                ; --- Read the image's first sector ------------------------
                LOADZ   D0, [#FD_DIR_FIRST_CL]
                CALLR   _ClusterToSector        ; preserves D3, XY2
                BCS     .erh_fail               ; D0 = ERR_INVALID

                LOADI   Y0, #$00
                LOADI   X0, #FS_BUF_SECTOR
                CALLR   _VolBlockRead           ; preserves D3, XY2
                BCS     .erh_fail               ; D0 = ERR_IO

                ; --- Validate the header ---------------------------------
                ; _VolBlockRead clobbers X0/X1, so rebuild the pointer.
                LOADI   Y0, #$00
                LOADI   X0, #FS_BUF_SECTOR
                LOADZ   D0, [#FD_DIR_SIZE_LO]   ; D0 = image length
                CALL24  _ComHeaderCheck         ; preserves D2, D3, XY1, XY2
                BCS     .erh_fail               ; D0 = ERR_NOTEXEC

                ; D0 = pages, D1 = heapPages
                STOREZ  D0, [#FE_PAGES]
                STOREZ  D1, [#FE_HEAPPG]
                RETCC

.erh_fail:
                ; D0 already carries the error with C=1.
                RETCS


; ============================================================================
; _ExecCopyShortName — copy the matched short entry's 11-byte name into
; FD_NAMEBUF (Part 45, LFN-aware exec).
;
;   After _DirLookupLong, FS_BUF_SECTOR holds the sector containing the matched
;   SHORT entry and FD_COOKIE_TMP's low nibble is its index. Copy the 11 name
;   bytes out so _ExecCheckExt / _ExecStageName operate on a valid 8.3 name even
;   when the file was opened by its long name.
;
;   In:    FD_COOKIE_TMP set; FS_BUF_SECTOR holds the entry's sector.
;   Out:   FD_NAMEBUF[0..10] = the short entry's 11-byte FAT name.
;   Clobbers: D0, D1, X0, X1, Y0, Y1, flags.   Preserves: D2, D3, XY2, XY3.
; ============================================================================
_ExecCopyShortName:
                LOADZ   D0, [#FD_COOKIE_TMP]
                AND     D0, #$0F                ; ent_idx within the sector
                SHL4    D0
                SHL     D0                      ; * 32
                ADD     D0, #FS_BUF_SECTOR
                LOADI   Y0, #$00
                MOVE    X0, D0                  ; XY0 = short entry
                LOADI   Y1, #$00
                LOADI   X1, #FD_NAMEBUF
                LOADI   D1, #11
.ecsn_copy:
                LOADB   D0, [XY0]+
                STOREB  D0, [XY1]+
                SUB     D1, #1
                BNE     .ecsn_copy
                RET


; ============================================================================
; _ExecCheckExt — verify FD_NAMEBUF[8..10] = "COM"
;
;   In:    FD_NAMEBUF holds 11-byte FAT name (uppercased by _ParsePath).
;   Out:   C=0 if extension is "COM"
;          C=1 with D0 = ERR_NOTEXEC otherwise
;   Clobbers: D0, D1, X0, Y0, flags
;   Preserves: D2, D3, XY1, XY2, XY3
; ============================================================================
_ExecCheckExt:
                LOADI   Y0, #$00
                LOADI   X0, #FD_NAMEBUF
                ADD     X0, #8                  ; first byte of extension

                LOADB   D0, [XY0]
                AND     D0, #$FF
                CMP     D0, #EXEC_EXT_COM_C     ; 'C'
                BNE     .ce_bad

                ADD     X0, #1
                LOADB   D0, [XY0]
                AND     D0, #$FF
                CMP     D0, #EXEC_EXT_COM_O     ; 'O'
                BNE     .ce_bad

                ADD     X0, #1
                LOADB   D0, [XY0]
                AND     D0, #$FF
                CMP     D0, #EXEC_EXT_COM_M     ; 'M'
                BNE     .ce_bad

                RETCC

.ce_bad:
                LOADI   D0, #ERR_NOTEXEC
                RETCS

; ============================================================================
; _ExecCopyChain — walk cluster chain, copy file bytes into user page
;
;   In:    XY2 = volume slot ptr
;          D3  = drive index (for _FATGetEntry cache identity)
;          FD_DIR_FIRST_CL = starting cluster (≥ 2, validated)
;          FD_DIR_SIZE_LO  = total byte count to copy
;          FE_NEW_PAGE     = destination page byte
;   Out:   C=0 success
;          C=1 with D0 = ERR_IO on read failure, or ERR_NOTEXEC on a
;                premature EOC (chain ends before size satisfied)
;   Clobbers: D0, D1, D2, X0, X1, Y0, Y1, flags
;   Preserves: D3, XY2, XY3
;
;   Phase 16 assumes sec_per_cluster = 1, so each cluster = one sector =
;   512 bytes. The last cluster may be partially used; we cap copy to
;   the remaining byte count.
; ============================================================================
_ExecCopyChain:
                ; --- Dir-cache coherence (r4, 12 May 2026) ----------------
                ; This routine reads file-data sectors into FS_BUF_SECTOR
                ; via _VolBlockRead. Per the Part 22 protocol (mirrored in
                ; _FdReadCurrSector / _FdWriteCurrSector), any non-_DirNextRaw
                ; write to FS_BUF_SECTOR MUST invalidate the dir cache, or
                ; _DirNextRaw will skip its next sector read and serve file
                ; data parsed as dirents. _DirCacheInvalidate clobbers D0
                ; only — fine here, we set D0 in the very next instruction.
                CALLR   _DirCacheInvalidate

                ; FE_DEST_OFF = SPAWN_ENTRY_OFFSET ($0200)
                LOADI   D0, #SPAWN_ENTRY_OFFSET
                STOREZ  D0, [#FE_DEST_OFF]

                ; FE_BYTES_LEFT = file size
                LOADZ   D0, [#FD_DIR_SIZE_LO]
                STOREZ  D0, [#FE_BYTES_LEFT]

                ; FE_CURR_CL = first cluster
                LOADZ   D0, [#FD_DIR_FIRST_CL]
                STOREZ  D0, [#FE_CURR_CL]

.cc_loop:
                LOADZ   D0, [#FE_BYTES_LEFT]
                CMP     D0, #0                  ; LOAD doesn't set flags (4.16)
                BEQ     .cc_done

                ; Sanity-check current cluster.
                LOADZ   D0, [#FE_CURR_CL]
                CMP     D0, #FAT_EOC_MIN
                BHS     .cc_truncated           ; EOC before size satisfied
                CMP     D0, #CLUSTER_FIRST_VALID
                BLO     .cc_truncated           ; bogus chain

                ; Convert to sector and read it.
                CALLR   _ClusterToSector
                BCS     .cc_io                  ; ERR_INVALID → fail
                ; D0 = absolute sector

                LOADI   Y0, #$00
                LOADI   X0, #FS_BUF_SECTOR
                CALLR   _VolBlockRead
                BCS     .cc_io                  ; D0 = ERR_IO

                ; Copy min(BYTES_LEFT, 512) bytes from FS_BUF_SECTOR to
                ; FE_NEW_PAGE:FE_DEST_OFF.
                CALLR   _ExecCopyOneSector

                ; Advance dest offset by chunk that was copied.
                ; _ExecCopyOneSector returns chunk size in D0.
                LOADZ   D1, [#FE_DEST_OFF]
                ADD     D1, D0
                STOREZ  D1, [#FE_DEST_OFF]

                ; Subtract chunk from bytes-left.
                LOADZ   D1, [#FE_BYTES_LEFT]
                SUB     D1, D0
                STOREZ  D1, [#FE_BYTES_LEFT]

                ; Get next cluster from FAT.
                LOADZ   D0, [#FE_CURR_CL]
                CALLR   _FATGetEntry            ; clobbers D0,D1,D2,X0,X1
                BCS     .cc_io
                STOREZ  D0, [#FE_CURR_CL]

                BRA     .cc_loop

.cc_done:
                RETCC

.cc_truncated:
                LOADI   D0, #ERR_NOTEXEC
                RETCS

.cc_io:
                ; D0 already set to ERR_IO (or similar) with C=1.
                RETCS

; ============================================================================
; _ExecCopyOneSector — copy min(FE_BYTES_LEFT, 512) bytes
;                      from FS_BUF_SECTOR (page $00)
;                      to FE_NEW_PAGE:FE_DEST_OFF
;
;   In:    FS_BUF_SECTOR holds one sector (just read).
;          FE_BYTES_LEFT = bytes still needed for the file.
;          FE_NEW_PAGE   = destination page byte.
;          FE_DEST_OFF   = current destination offset within new page.
;   Out:   D0 = chunk size copied (1..512)
;          (no flag return; copy can't fail)
;   Clobbers: D0, D1, D2, X0, X1, Y0, Y1, flags
;   Preserves: D3, XY2, XY3
; ============================================================================
_ExecCopyOneSector:
                ; Want: D0 = min(BYTES_LEFT, 512). 512 doesn't fit in IMM5,
                ; so load it into D1 as scratch. BLS not implemented
                ; (gotcha 3.6) — synthesise via BLO over the cap step.
                LOADZ   D0, [#FE_BYTES_LEFT]
                LOADI   D1, #FS_BYTES_PER_SECTOR
                CMP     D0, D1
                BLO.S   .cs_have_chunk          ; D0 < 512 → keep
                MOVE    D0, D1                  ; D0 ≥ 512 → cap to 512
.cs_have_chunk:
                ; D0 = chunk size. Stash for return; also use as counter.
                STOREZ  D0, [#FE_CHUNK_TMP]

                ; Source: kernel page, FS_BUF_SECTOR.
                LOADI   Y0, #$00
                LOADI   X0, #FS_BUF_SECTOR

                ; Dest: FE_NEW_PAGE : FE_DEST_OFF.
                LOADZB  D1, [#FE_NEW_PAGE]
                AND     D1, #$FF
                MOVE    Y1, D1
                LOADZ   D1, [#FE_DEST_OFF]
                MOVE    X1, D1

                ; D2 = counter (down to 0).
                MOVE    D2, D0
.cs_byte_loop:
                CMP     D2, #0                  ; LOAD/MOVE preserve flags
                BEQ     .cs_byte_done
                LOADB   D0, [XY0]+
                STOREB  D0, [XY1]+
                SUB     D2, #1
                BRA     .cs_byte_loop

.cs_byte_done:
                ; Return chunk size in D0.
                LOADZ   D0, [#FE_CHUNK_TMP]
                RET

; ============================================================================
; _ExecStageName — copy base name (FD_NAMEBUF[0..7]) into BT_NAME, trimming
;                  trailing spaces, nul-terminated.
;
;   In:    FD_NAMEBUF holds 11-byte name (8+3, space-padded).
;   Out:   BT_NAME holds 8-byte-or-less base, nul-terminated.
;   Clobbers: D0, D1, D2, X0, X1, Y0, Y1, flags
;   Preserves: D3, XY2, XY3
;
;   Example: FD_NAMEBUF = "HELLO   COM" → BT_NAME = "HELLO\0"
; ============================================================================
_ExecStageName:
                LOADI   Y0, #$00
                LOADI   X0, #FD_NAMEBUF
                LOADI   Y1, #$00
                LOADI   X1, #BT_NAME
                LOADI   D2, #8                  ; max 8 chars to inspect

.es_loop:
                CMP     D2, #0                  ; LOAD doesn't set flags
                BEQ     .es_done
                LOADB   D0, [XY0]
                AND     D0, #$FF
                CMP     D0, #' '                ; trailing space → stop
                BEQ     .es_done
                ; Lowercase A..Z (Part 41 follow-up): task names display
                ; lowercase, consistent with the boot shell's "kosh". FAT
                ; names are uppercased by _ParsePath; only the TCB display
                ; name is folded here. File lookups use FD_NAMEBUF and are
                ; unaffected. Mirrors the command-word lowercase idiom in
                ; kosh.asm (.lc_loop). Carry is 6502-style: BLO = below ('A'),
                ; BHS = >= ('Z'+1).
                CMP     D0, #'A'
                BLO.S   .es_store
                CMP     D0, #$5B                ; 'Z'+1
                BHS.S   .es_store
                ADD     D0, #$20                ; -> lowercase
.es_store:
                STOREB  D0, [XY1]
                ADD     X0, #1
                ADD     X1, #1
                SUB     D2, #1
                BRA     .es_loop

.es_done:
                ; Nul-terminate BT_NAME.
                LOADI   D0, #0
                STOREB  D0, [XY1]
                RET

; ============================================================================
; _ExecStageArgs - stamp the argv tail into child:$0100 (Part 15)
;
;   Copies the caller's nul-terminated arg tail (already leading/trailing
;   trimmed by kosh) from Y3:FE_ARGV_OFF into FE_NEW_PAGE:$0100 as ASCIIZ,
;   capped at ARGV_MAX chars, and always writes a terminating NUL. If
;   FE_ARGV_OFF = 0 (no args) it writes a lone $00 at $0100. The stamp is
;   unconditional: _AllocPage does not clear the page, so $0100 must be
;   written for the child to trust "peek($0100)=0 => no args".
;
;   In:    FE_NEW_PAGE = child page byte
;          FE_ARGV_OFF = caller-page offset of arg tail (0 = none)
;          Y3          = caller page (source page for the tail)
;   Out:   child:$0100.. = ASCIIZ arg tail (or a lone $00)
;   Clobbers: D0, D1, D2, X0, X1, Y0, Y1, flags
;   Preserves: D3, XY2, XY3
; ============================================================================
_ExecStageArgs:
                ; Dest = FE_NEW_PAGE:ARGV_BASE ($0100).
                LOADZB  D0, [#FE_NEW_PAGE]
                AND     D0, #$FF
                MOVE    Y1, D0
                LOADI   X1, #ARGV_BASE

                ; No args -> write a lone NUL at $0100 and return.
                LOADZ   D0, [#FE_ARGV_OFF]
                CMP     D0, #0
                BEQ     .sa_term

                ; Source = Y3:FE_ARGV_OFF.
                MOVE    Y0, Y3
                MOVE    X0, D0
                LOADI   D2, #ARGV_MAX           ; copy budget (chars)
.sa_loop:
                CMP     D2, #0                  ; LOADB is flag-transparent
                BEQ     .sa_term                ; budget exhausted -> terminate
                LOADB   D0, [XY0]+
                AND     D0, #$FF
                CMP     D0, #0
                BEQ     .sa_term                ; source NUL -> done
                STOREB  D0, [XY1]+
                SUB     D2, #1
                BRA     .sa_loop
.sa_term:
                LOADI   D0, #0
                STOREB  D0, [XY1]               ; guaranteed NUL terminator
                RET

; ============================================================================
; ----------------------- KERNEL-SCRATCH SLOTS -----------------------------
; ============================================================================
; Page-$00 scratch slots used by Piece 6 (sys_exec) have been RELOCATED
; into kos_fs_defs.inc as of Part 36 (18 May 2026).
;
; History summary (full version in kos_fs_defs.inc and Gotcha 4.47):
;   The FE_* slots were declared here at $03BC..$03C7. The Part 22
;   volume-table expansion put VOL_SLOT_F at $03A0..$03DF, with the
;   24-bit VOL_BLOCKREAD_PTR at slot offset $1A..$1C — i.e. $03BA..$03BC.
;   FE_NEW_PAGE at $03BC overlapped the page byte of F:'s BLOCKREAD_PTR.
;   Every sys_exec smashed it. Surfaced via Part 36's smoke test as
;   "CODE FAULT odd-addr fetch PC=$FF2803" when `vol` walked F: after
;   any `run` command. Relocated to $04D8..$04E3.
;
; All FE_* symbols referenced in this file resolve via the .INCLUDE
; chain through kos_defs.inc → kos_fs_defs.inc.

; ============================================================================
; End of kos_fs_exec.asm
; ============================================================================

