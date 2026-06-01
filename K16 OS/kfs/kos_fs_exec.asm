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
;        D0   flags
;               bit 0 = block (wait for child to exit)   [reserved P16; ignored]
;               bit 1 = inherit_stdio                    [reserved P18]
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
; 1. _ParsePath  → drive in D3, FAT name in FD_NAMEBUF.
; 2. Check FD_NAMEBUF[8..10] = "COM" else ERR_NOTEXEC.
; 3. _SlotForDrive → XY2.
; 4. _DirLookup    → cookie of file or ERR_NOTFOUND.
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
;   In:    XY0 = path "X:NAME.COM" (nul-terminated, ≤ 14 chars)
;          D0  = flags (bit 0 = block; reserved/ignored in P16)
;   Out:   D0 = new task TID, C=0 on success
;          D0 = ERR_*, C=1 on failure
; ============================================================================
sys_exec:
                DINT

                ; --- Per V2 ABI (Part 36 expansion):
                ; D1, D2, D3, XY1, XY2 all callee-preserved across syscalls.
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

                ; --- Parse path → drive in D3, FAT name in FD_NAMEBUF ------
                LOADI   Y1, #$00
                LOADI   X1, #FD_NAMEBUF
                CALLR   _ParsePath
                BCS     .se_err

                ; Save drive.
                STOREZB D3, [#FD_DRIVE_TMP]

                ; --- Verify extension is "COM" ----------------------------
                CALLR   _ExecCheckExt
                BCS     .se_err

                ; --- Resolve drive → XY2 ----------------------------------
                MOVE    D0, D3
                CALLR   _SlotForDrive
                BCS     .se_err

                ; --- Look up file -----------------------------------------
                LOADI   Y0, #$00
                LOADI   X0, #FD_NAMEBUF
                CALLR   _DirLookup
                BCS     .se_lookup_failed

                STOREZ  D0, [#FD_COOKIE_TMP]

                ; --- Load dirent details (first cluster + size) -----------
                CALLR   _LoadDirentFromCookie
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
                CALL24  _AllocPage
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

                LOADI   D0, #1
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

                ; --- Build the task ---------------------------------------
                ; XY2 isn't needed after this point so no need to save it.
                CALL24  _BuildTask
                BCS     .se_noslots
                ; D0 = new TCB ptr. Read its TCB_ID for return.
                LOADI   Y1, #$00
                MOVE    X1, D0
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
                LOADB   D0, [XY0]
                STOREB  D0, [XY1]
                ADD     X0, #1
                ADD     X1, #1
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
