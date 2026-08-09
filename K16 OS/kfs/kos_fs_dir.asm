; ============================================================================
; kos_fs_dir.asm — k/OS Phase 16 Piece 4: directory operations
; ============================================================================
; Date:    6 May 2026
; Status:  Phase 16 Piece 4 — name conversion, iteration, lookup, create/delete
;
; Revision: r5 — 17 June 2026 — Part 47: file split into three (same
;             assembly unit, .INCLUDEd adjacently — layout-neutral, all
;             inter-file calls are CALLR):
;               kos_fs_dir.asm      — core 8.3 ops: name conversion,
;                                     iteration (_DirNextRaw/_DirNext), 8.3
;                                     lookup, _DirSecToAbs, create + 8.3
;                                     delete, dir-cache, RTC stubs.
;               kos_fs_dir_lfn.asm  — LFN family, 8.3 short-name generator,
;                                     LFN-run lookup/create/delete.
;               kos_fs_dir_path.asm — path resolver + pwd reconstruction.
;             kos_boot.asm: the single kos_fs_dir.asm include is now three
;             adjacent includes (dir, then _lfn, then _path).
;
; Revision: r4 — 17 June 2026 — Part 47: _ScanForCluster is LFN-aware
;             (_DirNextRaw -> _DirNext). On a first-cluster match it recovers
;             the long name (left in LFN_ASM by _DirNext, too big for the
;             14-byte RV_NAMEBUF) and signals D0=1; 8.3 matches stay in
;             RV_NAMEBUF (D0=0). _BuildPath selects the source by that flag,
;             so sys_pwd / the prompt now show long directory names.
;
; Revision: r3 — 17 June 2026 — Part 46 (45.5.3a): _DirDeleteRun added —
;             LFN-aware whole-run delete ($E5s the contiguous LFN fragment
;             entries preceding the short entry, then the short entry).
;             Single-sector RMW; backward walk gated on attr==$0F + matching
;             short-name checksum, terminated by the $40 (last-logical) seq
;             bit. 8.3 files behave byte-identically to _DirDelete, which is
;             retained (still used by _RmDir; dirs remain 8.3-only until
;             mkdir-LFN). _DeleteFile rewired: _DirLookup->_DirLookupLong and
;             _DirDelete->_DirDeleteRun. (rename whole-run = 45.5.3b, pending.)
;
; Revision: r2 — 16 June 2026 — Cluster-aware directory traversal.
;             • _DirNextRaw and _DirLookup now resolve sec_off → absolute
;               sector via either the root region (DIR_WALK_CLU = 0, the
;               original path, fall-through, unchanged) or a FAT chain walk
;               (DIR_WALK_CLU >= 2). New ZP word DIR_WALK_CLU at $03EE
;               (kos_fs_defs.inc); _InitFS clears it to 0. Chain walk reuses
;               _FATGetEntry + _ClusterToSector. Assumes sec_per_cluster = 1
;               (enforced by _ClusterToSector today). FAT_BAD mid-chain →
;               ERR_IO; running off EOC → ERR_NOMORE (_DirNextRaw) /
;               ERR_NOTFOUND (_DirLookup).
;             • BUNDLED (separate concern, flagged for bisection): the
;               32-byte entry copy in _DirNextRaw and the 11-byte name
;               compare in _DirLookup converted to STREAM [XYn]+ post-
;               increment (Ref Manual §6.1, flag-transparent, default
;               stride 1 for byte). If a regression appears, the STREAM
;               edits are independently revertible from the cluster logic.
;             • _DirOpen / _DirNext gained contract notes only (inherit
;               DIR_WALK_CLU via _DirNextRaw; no logic change).
;             • _DirCreate / _DirDelete remain root-only (mkdir follow-up).
;
; Revision: r1 — 6 May 2026 — initial. Provides:
;             • _DirNameToFat / _DirNameFromFat   — 8.3 ↔ 11-byte conversion
;             • _DirOpen / _DirRewind             — iteration setup
;             • _DirNextRaw / _DirNext            — iteration (raw / filtered)
;             • _DirLookup                        — find entry by name
;             • _DirCreate / _DirDelete           — entry create/delete
;             • _GetDate  / _GetTime              — RTC stubs (Phase 17 seam)
;
; Phase 16 limitations:
;   • Root directory only — no subdirectory traversal.
;   • Long filenames (LFN) silently skipped on iteration.
;   • Volume-label entries silently skipped on iteration (visible to raw).
;   • No real-time clock; date/time fields written from _GetDate/_GetTime
;     stubs. _GetDate returns today's date as a baked constant; when an RTC
;     arrives the body is swapped without touching any caller.
;
; --- Iteration cookie format -----------------------------------------------
;
; A directory iterator is a single 16-bit word ("cookie") with:
;
;     bits 15..4   sector offset within root dir region (0..root_sectors-1)
;     bits 3..0    entry index within that sector (0..15)
;
; Initial cookie: 0 = (sector 0, entry 0).
; Advancing past the last entry of the last sector returns ERR_NOMORE.
;
; The encoding is deliberately compact so it fits in a single D-register
; argument and matches the future sys_dirent ABI directly.
;
; --- Free-slot policy ------------------------------------------------------
;
; _DirCreate scans the root in order. It claims the first slot whose
; first byte is either DIR_FREE_REUSABLE ($E5, deleted) or DIR_FREE_END
; ($00, never used). If the scan finishes without finding either, the
; directory is full → ERR_NOSPACE.
;
; --- Read-modify-write strategy --------------------------------------------
;
; Directory writes (create, delete) read the target sector into
; FS_BUF_SECTOR, modify the 32-byte slice in place, then write the whole
; sector back with _VolBlockWrite.
;
; ============================================================================


; ============================================================================
; _GetDate — return today's date packed for FAT16 dirent
;
;   FAT16 date format:
;     bits 15..9   year - 1980
;     bits  8..5   month (1..12)
;     bits  4..0   day   (1..31)
;
;   Phase 16 baked constant: 6 May 2026
;     ((2026-1980) << 9) | (5 << 5) | 6
;     = (46 << 9) | (5 << 5) | 6
;     = $5C00 | $00A0 | $0006
;     = $5CA6
;
;   When an RTC lands (Phase 17+), only this routine changes — every
;   caller passes the result through unmodified.
;
;   In:    (none)
;   Out:   D0 = packed date
;   Clobbers: D0
;   Preserves: D1, D2, D3, all XYn, flags
; ============================================================================
_GetDate:
                LOADI   D0, #$5CA6
                RET


; ============================================================================
; _GetTime — return current time-of-day packed for FAT16 dirent
;
;   FAT16 time format:
;     bits 15..11  hour (0..23)
;     bits 10..5   minute (0..59)
;     bits  4..0   seconds / 2 (0..29)
;
;   Phase 16 returns 00:00:00 = $0000. When an RTC lands, becomes a real read.
;
;   In:    (none)
;   Out:   D0 = packed time
;   Clobbers: D0
;   Preserves: D1, D2, D3, all XYn, flags
; ============================================================================
_GetTime:
                LOADI   D0, #$0000
                RET


; ============================================================================
; _DirNameToFat — convert "FOO.TXT" to "FOO     TXT" (11 bytes, space-padded)
;
;   Validates and uppercases. Lowercase a..z folded to uppercase A..Z.
;   Empty names, oversize names, and names containing illegal characters
;   are rejected with ERR_INVALID.
;
;   Allowed: A-Z 0-9 ! # $ % & ' ( ) - @ ^ _ ` { } ~  (and the dot, handled
;   structurally rather than as a name char).
;
;   Rejected: control chars, space, " * + , / : ; < = > ? [ \ ] |
;
;   First-byte $E5 in the resulting name is rejected to avoid collision
;   with the "deleted" sentinel. (FAT16's $05 escape mechanism is not
;   implemented in Phase 16.)
;
;   In:    XY0 = source name (nul-terminated)
;          XY1 = destination 11-byte buffer
;   Out:   C=0 on success, destination contains 11 bytes
;          C=1 with D0 = ERR_INVALID on bad name
;   Clobbers: D0, D1, D2, X0, X1, flags
;   Preserves: D3, Y0, Y1, XY2, XY3
; ============================================================================
_DirNameToFat:
                PUSH    D3, XY3
                PUSH    XY1, XY3                ; save dest base for final $E5 check

                ; --- Pre-fill destination with 11 spaces ------------------
                LOADI   D0, #' '
                LOADI   D1, #11
.dn2f_fill:
                STOREB  D0, [XY1]+
                SUB     D1, #1
                BNE     .dn2f_fill

                ; Restore destination base.
                POP     XY1, XY3
                PUSH    XY1, XY3                ; re-push for final E5 check

                ; --- Collect base name (up to 8 chars) --------------------
                LOADI   D3, #0                  ; D3 = base position 0..8
.dn2f_base_loop:
                LOADB   D0, [XY0]
                AND     D0, #$FF
                BEQ     .dn2f_done_no_ext       ; nul: no extension
                CMP     D0, #'.'
                BEQ     .dn2f_dot

                CALLR   _DirCharNormalise
                BCS     .dn2f_invalid_pop2

                CMP     D3, #8
                BHS     .dn2f_invalid_pop2      ; >8 base chars

                STOREB  D0, [XY1+D3]
                ADD     D3, #1
                ADD     X0, #1
                BRA     .dn2f_base_loop

.dn2f_dot:
                ; Empty base ("." or ".foo") is rejected.
                CMP     D3, #0
                BEQ     .dn2f_invalid_pop2
                ADD     X0, #1                  ; consume dot

                ; --- Collect extension (up to 3 chars) --------------------
                LOADI   D3, #8                  ; D3 = dest offset, 8..11
.dn2f_ext_loop:
                LOADB   D0, [XY0]
                AND     D0, #$FF
                BEQ     .dn2f_done_with_ext
                CMP     D0, #'.'
                BEQ     .dn2f_invalid_pop2      ; second dot rejected

                CALLR   _DirCharNormalise
                BCS     .dn2f_invalid_pop2

                CMP     D3, #11
                BHS     .dn2f_invalid_pop2      ; >3 ext chars

                STOREB  D0, [XY1+D3]
                ADD     D3, #1
                ADD     X0, #1
                BRA     .dn2f_ext_loop

.dn2f_done_no_ext:
                ; No extension. Empty name guard:
                CMP     D3, #0
                BEQ     .dn2f_invalid_pop2
                BRA     .dn2f_check_e5

.dn2f_done_with_ext:
                ; Empty extension ("FOO.") permitted — pre-fill of spaces
                ; is already correct. Fall through.

.dn2f_check_e5:
                ; Reject if first byte is $E5 (deleted-slot sentinel).
                POP     XY1, XY3                ; restore dest base
                LOADB   D0, [XY1]
                AND     D0, #$FF
                CMP     D0, #DIR_FREE_REUSABLE
                BEQ     .dn2f_invalid

                LOADI   D0, #ERR_OK
                CLC
                POP     D3, XY3
                RET

.dn2f_invalid_pop2:
                POP     XY1, XY3                ; discard saved dest base
                ; fall through

.dn2f_invalid:
                LOADI   D0, #ERR_INVALID
                SEC
                POP     D3, XY3
                RET


; ============================================================================
; _DirCharNormalise — validate and uppercase one filename character
;
;   Internal helper for _DirNameToFat.
;
;   In:    D0 = candidate byte (0..255)
;   Out:   C=0 with D0 = uppercased valid char
;          C=1 if char is illegal in an 8.3 name
;   Clobbers: D0, flags
;   Preserves: D1, D2, D3, all XYn
; ============================================================================
_DirCharNormalise:
                ; Reject control chars (< $20) and DEL ($7F).
                CMP     D0, #$20
                BLO     .dcn_bad
                CMP     D0, #$7F
                BEQ     .dcn_bad

                ; Reject space and the structural dot (handled by caller).
                CMP     D0, #' '
                BEQ     .dcn_bad
                CMP     D0, #'.'
                BEQ     .dcn_bad

                ; Reject explicitly-disallowed punctuation. Use hex
                ; literals for chars that might confuse the assembler's
                ; character-literal parser (backslash, doublequote).
                CMP     D0, #$22                ; "
                BEQ     .dcn_bad
                CMP     D0, #'*'
                BEQ     .dcn_bad
                CMP     D0, #'+'
                BEQ     .dcn_bad
                CMP     D0, #','
                BEQ     .dcn_bad
                CMP     D0, #'/'
                BEQ     .dcn_bad
                CMP     D0, #':'
                BEQ     .dcn_bad
                CMP     D0, #';'
                BEQ     .dcn_bad
                CMP     D0, #'<'
                BEQ     .dcn_bad
                CMP     D0, #'='
                BEQ     .dcn_bad
                CMP     D0, #'>'
                BEQ     .dcn_bad
                CMP     D0, #'?'
                BEQ     .dcn_bad
                CMP     D0, #'['
                BEQ     .dcn_bad
                CMP     D0, #$5C                ; backslash
                BEQ     .dcn_bad
                CMP     D0, #']'
                BEQ     .dcn_bad
                CMP     D0, #'|'
                BEQ     .dcn_bad

                ; Lowercase a..z → uppercase A..Z.
                ; (Using hex $7B for 'z'+1 to avoid relying on assembler
                ; arithmetic on char literals.)
                CMP     D0, #'a'
                BLO     .dcn_ok
                CMP     D0, #$7B                ; 'z' + 1
                BHS     .dcn_ok
                SUB     D0, #$20

.dcn_ok:
                RETCC

.dcn_bad:
                LOADI   D0, #ERR_INVALID
                RETCS


; ============================================================================
; _DirNameFromFat — convert "FOO     TXT" to "FOO.TXT" (nul-terminated)
;
;   Trims trailing spaces from base, inserts a dot, then trims trailing
;   spaces from ext. If ext is all-space, no dot is emitted. Output is
;   nul-terminated. Worst-case length is 12 bytes ("12345678.123") + nul,
;   so caller's buffer should be ≥ 13.
;
;   The output remains uppercase — Phase 16 spec follows MS-DOS convention
;   (8.3 names display as stored).
;
;   In:    XY0 = source 11-byte FAT name field
;          XY1 = destination buffer (≥ 13 bytes)
;   Out:   C=0 with D0 = output length (excluding nul)
;   Clobbers: D0, D1, D2, X0, X1, flags
;   Preserves: D3, Y0, Y1, XY2, XY3
; ============================================================================
_DirNameFromFat:
                PUSH    D3, XY3

                ; --- Find base length (last non-space within bytes 0..7) --
                LOADI   D2, #0                  ; D2 = base length (0..8)
                LOADI   D1, #8                  ; D1 = scan position (1..8)
.dnff_base_scan:
                MOVE    D3, D1
                SUB     D3, #1                  ; D3 = index = D1 - 1
                LOADB   D0, [XY0+D3]
                AND     D0, #$FF
                CMP     D0, #' '
                BNE     .dnff_base_found
                SUB     D1, #1
                BNE     .dnff_base_scan
                BRA     .dnff_base_done         ; all spaces → length 0
.dnff_base_found:
                MOVE    D2, D1
.dnff_base_done:

                ; --- Find ext length (last non-space within bytes 8..10) --
                LOADI   D3, #0                  ; D3 = ext length (0..3)
                LOADI   D1, #11                 ; D1 = scan position (9..11)
.dnff_ext_scan:
                MOVE    D0, D1
                SUB     D0, #1                  ; D0 = index = D1 - 1
                CMP     D0, #8
                BLO     .dnff_ext_done          ; below ext range
                LOADB   D0, [XY0+D0]
                AND     D0, #$FF
                CMP     D0, #' '
                BNE     .dnff_ext_found
                SUB     D1, #1
                BRA     .dnff_ext_scan
.dnff_ext_found:
                MOVE    D3, D1
                SUB     D3, #8                  ; D3 = ext length
.dnff_ext_done:

                ; --- Copy base, optional dot+ext, nul-terminate -----------
                LOADI   D1, #0                  ; D1 = dest index
.dnff_copy_base:
                CMP     D1, D2
                BHS     .dnff_after_base
                LOADB   D0, [XY0+D1]
                STOREB  D0, [XY1+D1]
                ADD     D1, #1
                BRA     .dnff_copy_base
.dnff_after_base:

                CMP     D3, #0
                BEQ     .dnff_terminate

                LOADI   D0, #'.'
                STOREB  D0, [XY1+D1]
                ADD     D1, #1

                LOADI   D2, #0                  ; D2 = ext source counter
.dnff_copy_ext:
                CMP     D2, D3
                BHS     .dnff_terminate
                MOVE    D0, D2
                ADD     D0, #8
                LOADB   D0, [XY0+D0]
                STOREB  D0, [XY1+D1]
                ADD     D1, #1
                ADD     D2, #1
                BRA     .dnff_copy_ext

.dnff_terminate:
                LOADI   D0, #0
                STOREB  D0, [XY1+D1]
                MOVE    D0, D1
                CLC
                POP     D3, XY3
                RET


; ============================================================================
; _DirOpen — initialise an iteration cookie for a directory
;
;   Cluster-aware: the directory walked by the subsequent _DirNext /
;   _DirNextRaw calls is selected by the ZP word DIR_WALK_CLU (0 = root
;   region, >=2 = subdir start cluster). _DirOpen itself only validates the
;   mount and returns the initial cookie; the caller is responsible for
;   setting DIR_WALK_CLU before the open and restoring it to 0 afterwards.
;
;   In:    XY2 = volume slot ptr
;   Out:   C=0 with D0 = initial cookie (0)
;          C=1 with D0 = ERR_BADDRIVE if slot not mounted
;   Clobbers: D0, flags
;   Preserves: D1, D2, D3, XY0, XY1, XY2, XY3
; ============================================================================
_DirOpen:
                LOADB   D0, [XY2+#VOL_PRESENT]
                AND     D0, #$FF
                BEQ     .do_baddrive
                LOADI   D0, #0
                RETCC
.do_baddrive:
                LOADI   D0, #ERR_BADDRIVE
                RETCS


; ============================================================================
; _DirRewind — reset a cookie to the start of the directory
;
;   In:    (none)
;   Out:   D0 = 0, C=0
;   Clobbers: D0, flags
; ============================================================================
_DirRewind:
                LOADI   D0, #0
                RETCC


; ============================================================================
; _DirNextRaw — advance one slot, return its raw 32-byte dirent (no filter)
;
;   Returns every slot, including:
;     • Deleted entries (first byte = $E5)
;     • Volume-label entries (attr bit 3)
;     • LFN entries (attr = $0F)
;     • End-of-dir sentinel ($00 first byte)
;
;   In:    D0  = current cookie
;          XY1 = destination buffer (≥ 32 bytes)
;          XY2 = volume slot ptr
;          D3  = drive index
;   Out:   C=0 with D0 = next cookie, 32 bytes copied to [XY1]
;          C=1 with D0 = ERR_NOMORE if cookie is past end of root dir
;          C=1 with D0 = ERR_IO     if a sector read fails
;   Clobbers: D0, D1, D2, X0, X1, flags
;   Preserves: D3, Y0, Y1 (after copy), XY2, XY3
; ============================================================================
_DirNextRaw:
                PUSH    D3, XY3
                PUSH    XY1, XY3                ; save caller's dest

                ; --- Decode cookie ----------------------------------------
                MOVE    D1, D0
                SHR4    D1                      ; D1 = sec_off
                MOVE    D2, D0
                AND     D2, #$0F                ; D2 = ent_idx

                ; --- Resolve sec_off -> absolute sector -------------------
                ; DIR_WALK_CLU = 0 : root region (original path, fall-through).
                ; DIR_WALK_CLU >=2 : subdir — walk the FAT chain sec_off links.
                LOADZ   D0, [#DIR_WALK_CLU]
                CMP     D0, #0
                BNE     .dnr_subdir

                ; ===== ROOT REGION (unchanged) ============================
                ; Bound check: sec_off < ceil(root_entries / 16)
                LOADD   D0, [XY2+#VOL_ROOT_ENTRIES]
                ADD     D0, #15
                SHR4    D0                      ; D0 = root_sectors
                CMP     D1, D0
                BHS     .dnr_nomore

                LOADD   D0, [XY2+#VOL_ROOT_START]
                ADD     D0, D1                  ; D0 = absolute sector
                BRA     .dnr_have_sector

                ; ===== SUBDIR (cluster chain) =============================
                ; Walk sec_off (=D1) FAT links from DIR_WALK_CLU. _FATGetEntry
                ; needs D3=drive (live) + XY2=slot (live); it clobbers
                ; D0/D1/D2/X0/X1, so sec_off+ent_idx go on the stack and the
                ; per-step counter is re-saved across the call.
.dnr_subdir:
                PUSH    D2, XY3                 ; [A] ent_idx  (for the tail)
                PUSH    D1, XY3                 ; [B] orig sec_off (for cookie)
                LOADZ   D2, [#DIR_WALK_CLU]      ; D2 = current cluster
                ; D1 = remaining steps (= sec_off)
.dnr_walk:
                CMP     D1, #0
                BEQ     .dnr_walk_done
                PUSH    D1, XY3                 ; [C] counter across the call
                MOVE    D0, D2                  ; D0 = current cluster (input)
                CALLR   _FATGetEntry             ; D0 = next/EOC; clobbers D1,D2,X0,X1
                POP     D1, XY3                 ; [C]
                BCS     .dnr_walk_io             ; FAT read error
                CMP     D0, #FAT_BAD
                BEQ     .dnr_walk_io             ; corrupt link -> ERR_IO
                CMP     D0, #FAT_EOC_MIN
                BHS     .dnr_walk_nomore         ; chain ends before sec_off
                MOVE    D2, D0                   ; advance current cluster
                SUB     D1, #1
                BRA     .dnr_walk
.dnr_walk_done:
                MOVE    D0, D2                   ; D2 = target cluster
                CALLR   _ClusterToSector         ; D0 = abs sector; preserves D2,D3,XY*
                BCS     .dnr_walk_io             ; defensive (cluster<2 == corrupt)
                POP     D1, XY3                 ; [B] restore sec_off
                POP     D2, XY3                 ; [A] restore ent_idx
                ; fall through — D0 = abs sector, D1 = sec_off, D2 = ent_idx

                ; ===== COMMON: read sector, copy entry, advance cookie ====
                ; Dir cache: if FS_BUF_SECTOR already holds this sector for
                ; this drive, skip the read.
.dnr_have_sector:
                PUSH    D1, XY3                 ; save sec_off
                PUSH    D2, XY3                 ; save ent_idx

                LOADZ   D2, [#DIR_CACHE_SECTOR]
                CMP     D2, D0
                BNE.S   .dnr_must_read
                LOADZB  D2, [#DIR_CACHE_DRIVE]
                CMP     D2, D3
                BEQ.S   .dnr_cache_hit
.dnr_must_read:
                ; Update cache identity BEFORE the read so that on read
                ; failure we mark invalid via the err path. Tentative now.
                STOREZ  D0, [#DIR_CACHE_SECTOR]
                STOREZB D3, [#DIR_CACHE_DRIVE]

                LOADI   Y0, #$00
                LOADI   X0, #FS_BUF_SECTOR
                CALLR   _VolBlockRead
                BCS     .dnr_io_err

.dnr_cache_hit:
                POP     D2, XY3                 ; restore ent_idx
                POP     D1, XY3                 ; restore sec_off

                ; --- Source addr = FS_BUF_SECTOR + ent_idx * 32 -----------
                MOVE    D0, D2
                SHL4    D0                      ; * 16
                SHL     D0                      ; * 32
                ADD     D0, #FS_BUF_SECTOR

                ; --- Restore caller's dest, copy 32 bytes -----------------
                POP     XY1, XY3                ; restore dest
                PUSH    XY1, XY3                ; re-push for clean unwind

                LOADI   Y0, #$00
                MOVE    X0, D0                  ; XY0 = source
                LOADI   D0, #32
.dnr_copy:
                ; STREAM post-increment (stride 1, byte) — flag-transparent;
                ; replaces LOADB/STOREB + ADD X0/X1. SUB below sets the flags.
                LOADB   D2, [XY0]+
                STOREB  D2, [XY1]+
                SUB     D0, #1
                BNE     .dnr_copy

                ; --- Advance cookie ---------------------------------------
                ; D1 = sec_off (still valid). D2 was clobbered by the copy
                ; loop; recompute ent_idx from X0:
                ;   X0 = FS_BUF_SECTOR + (ent_idx+1)*32   (32 byte-steps)
                ; so ((X0 - FS_BUF_SECTOR) >> 5) = ent_idx + 1.
                MOVE    D2, X0
                SUB     D2, #FS_BUF_SECTOR
                SHR4    D2                      ; / 16
                SHR     D2                      ; / 32
                ; D2 is now ent_idx + 1, in range 1..16.
                CMP     D2, #16
                BLO     .dnr_no_wrap
                LOADI   D2, #0
                ADD     D1, #1
.dnr_no_wrap:
                MOVE    D0, D1
                SHL4    D0
                OR      D0, D2

                POP     XY1, XY3                ; discard re-push
                POP     D3, XY3
                RETCC

.dnr_io_err:
                ; Read failed — mark dir cache invalid so future calls retry.
                LOADI   D0, #FAT_CACHE_INVALID
                STOREZ  D0, [#DIR_CACHE_SECTOR]
                ; Stack top→bottom: ent_idx, sec_off, dest, D3.
                POP     D2, XY3
                POP     D1, XY3
                POP     XY1, XY3
                POP     D3, XY3
                LOADI   D0, #ERR_IO
                RETCS

.dnr_nomore:
                POP     XY1, XY3
                POP     D3, XY3
                LOADI   D0, #ERR_NOMORE
                RETCS

                ; --- subdir walk failures ---------------------------------
                ; Stack top→bottom: sec_off [B], ent_idx [A], dest, D3.
                ; ([C] counter is always popped before reaching here.)
.dnr_walk_io:
                POP     D1, XY3                 ; discard sec_off [B]
                POP     D2, XY3                 ; discard ent_idx [A]
                POP     XY1, XY3                ; discard dest
                POP     D3, XY3
                LOADI   D0, #ERR_IO
                SEC
                RET

.dnr_walk_nomore:
                POP     D1, XY3                 ; discard sec_off [B]
                POP     D2, XY3                 ; discard ent_idx [A]
                POP     XY1, XY3                ; discard dest
                POP     D3, XY3
                LOADI   D0, #ERR_NOMORE
                SEC
                RET


; ============================================================================
; _DirNext — advance, return next *visible* entry (filter applied)
;
;   Skip rules:
;     • First byte $00  → end-of-dir (ERR_NOMORE)
;     • First byte $E5  → deleted, skip silently
;     • Attr == $0F     → LFN, skip silently
;     • Attr bit 3 set  → volume label, skip silently
;
;   Cluster-aware via DIR_WALK_CLU (read by _DirNextRaw): 0 = root region,
;   >=2 = subdir start cluster. Caller sets it before the walk, restores 0
;   after. No logic change here — inherited through _DirNextRaw.
;
;   In:    D0  = current cookie
;          XY1 = destination buffer (≥ 32 bytes)
;          XY2 = volume slot ptr
;          D3  = drive index
;   Out:   C=0 with D0 = next cookie, 32 bytes in [XY1]
;          C=1 with D0 = ERR_NOMORE  at end of directory
;          C=1 with D0 = ERR_IO      on read failure
;   Clobbers: D0, D1, D2, X0, X1, flags
;   Preserves: D3, XY2, XY3
; ============================================================================
_DirNext:
                ; Part 45: reset the per-call LFN run state. Each _DirNext call
                ; consumes one visible short entry plus any LFN fragments that
                ; physically precede it, so the long name (if valid) lands in
                ; LFN_ASM and its length in LFN_ASM_LEN by the time we return.
                ; D1 is used (clobberable) so the incoming cookie in D0 survives
                ; into the first _DirNextRaw.
                LOADI   D1, #0
                STOREZ  D1, [#LFN_EXP_SEQ]       ; $0000 = idle (no run)
                STOREZ  D1, [#LFN_ASM_LEN]       ; 0 = no long name yet
.dn_loop:
                CALLR   _DirNextRaw
                BCS     .dn_err

                LOADB   D1, [XY1]
                AND     D1, #$FF
                BEQ     .dn_eod                 ; $00 → end of dir

                CMP     D1, #DIR_FREE_REUSABLE
                BEQ     .dn_break_run           ; deleted breaks any LFN run, retry

                LOADI   D2, #DIR_ATTR
                LOADB   D1, [XY1+D2]
                AND     D1, #$FF

                CMP     D1, #DIR_ATTR_LFN
                BEQ     .dn_lfn                 ; LFN fragment → accumulate, retry

                AND     D1, #DIR_ATTR_VOLUME_LABEL
                BNE     .dn_break_run           ; volume label breaks run, retry

                ; Visible short entry. Finalise the accumulated long name (if a
                ; complete run with a matching checksum precedes it). _LfnFinal
                ; preserves D0/XY1/XY2/D3 and sets carry internally, so force
                ; C=0 for the success return.
                CALLR   _LfnFinal
                CLC
                RET

.dn_lfn:
                CALLR   _LfnAccum               ; folds [XY1] into LFN_ASM
                BRA     .dn_loop

.dn_break_run:
                LOADI   D2, #0
                STOREZ  D2, [#LFN_EXP_SEQ]       ; chain broken → back to idle
                BRA     .dn_loop

.dn_eod:
                LOADI   D0, #ERR_NOMORE
                RETCS

.dn_err:
                ; D0/C already set by _DirNextRaw.
                RETCS


; ============================================================================
; _DirLookup — find a directory entry by name
;
;   Walks the root directory sector by sector, scanning 16 entries per
;   sector in place in FS_BUF_SECTOR. Stops on the $00 sentinel.
;
;   On success, FS_BUF_SECTOR is left holding the matching entry's sector
;   so callers (e.g. _DirDelete) can reuse without re-reading.
;
;   In:    XY0 = 11-byte FAT-format name (caller pre-converted)
;          XY2 = volume slot ptr
;          D3  = drive index
;   Out:   C=0 with:
;            D0 = cookie pointing AT the matched entry
;            FS_BUF_SECTOR = the sector containing the match
;          C=1 with D0 = ERR_NOTFOUND if not present
;          C=1 with D0 = ERR_IO       on read failure
;   Clobbers: D0, D1, D2, X0, X1, flags
;   Preserves: D3, XY0, XY2, XY3
;
; --- Register usage --------------------------------------------------------
;
; Across the per-entry work:
;   D1  = sec_off            (callee-saved across the inner steps)
;   D2  = ent_idx            (callee-saved across the inner steps)
;   D0  = scratch (filter byte / attr / cmp byte)
;   XY0 = caller's name ptr  (saved on stack throughout, restored at exit)
;   XY1 = current entry addr / walk pointer during compare
;
; ============================================================================
_DirLookup:
                PUSH    D3, XY3
                PUSH    XY0, XY3                ; save caller's name

                LOADI   D1, #0                  ; sec_off = 0

.dl_sec_loop:
                ; --- Resolve sec_off -> absolute sector -------------------
                ; DIR_WALK_CLU = 0 : root region (original path, fall-through).
                ; DIR_WALK_CLU >=2 : subdir — walk the FAT chain sec_off links.
                LOADZ   D0, [#DIR_WALK_CLU]
                CMP     D0, #0
                BNE     .dl_subdir_sector

                ; ===== ROOT REGION (unchanged) =====
                ; Bound check.
                LOADD   D0, [XY2+#VOL_ROOT_ENTRIES]
                ADD     D0, #15
                SHR4    D0
                CMP     D1, D0
                BHS     .dl_notfound
                LOADD   D0, [XY2+#VOL_ROOT_START]
                ADD     D0, D1                  ; D0 = absolute sector
                BRA     .dl_have_sector

                ; ===== SUBDIR: walk chain sec_off (=D1) links =====
                ; _FATGetEntry needs D3=drive + XY2=slot (both live); it
                ; clobbers D0/D1/D2/X0/X1 — keep sec_off on the stack.
.dl_subdir_sector:
                PUSH    D1, XY3                 ; [W] save sec_off (loop-counter copy)
                LOADZ   D2, [#DIR_WALK_CLU]      ; D2 = current cluster
                ; D1 = remaining steps (= sec_off)
.dl_walk:
                CMP     D1, #0
                BEQ     .dl_walk_done
                PUSH    D1, XY3                 ; [V] counter across the call
                MOVE    D0, D2
                CALLR   _FATGetEntry             ; D0 = next/EOC; clobbers D1,D2,X0,X1
                POP     D1, XY3                 ; [V]
                BCS     .dl_walk_io              ; FAT read error
                CMP     D0, #FAT_BAD
                BEQ     .dl_walk_io              ; corrupt link -> ERR_IO
                CMP     D0, #FAT_EOC_MIN
                BHS     .dl_walk_eoc             ; chain ends before sec_off -> NOTFOUND
                MOVE    D2, D0                   ; advance cluster
                SUB     D1, #1
                BRA     .dl_walk
.dl_walk_done:
                MOVE    D0, D2                   ; D2 = target cluster
                CALLR   _ClusterToSector         ; D0 = abs sector; preserves D2,D3,XY*
                BCS     .dl_walk_io              ; defensive (cluster<2 == corrupt)
                POP     D1, XY3                 ; [W] restore sec_off
                ; fall through — D0 = absolute sector, D1 = sec_off

                ; --- Read that sector into FS_BUF_SECTOR — cache-aware ----
.dl_have_sector:
                PUSH    D1, XY3                 ; save sec_off across the I/O
                ; Cache hit?
                LOADZ   D2, [#DIR_CACHE_SECTOR]
                CMP     D2, D0
                BNE.S   .dl_must_read
                LOADZB  D2, [#DIR_CACHE_DRIVE]
                CMP     D2, D3
                BEQ.S   .dl_cache_hit
.dl_must_read:
                STOREZ  D0, [#DIR_CACHE_SECTOR]
                STOREZB D3, [#DIR_CACHE_DRIVE]
                LOADI   Y0, #$00
                LOADI   X0, #FS_BUF_SECTOR
                CALLR   _VolBlockRead
                BCS     .dl_io_err
.dl_cache_hit:
                POP     D1, XY3                 ; restore sec_off

                ; Walk 16 entries.
                LOADI   D2, #0                  ; ent_idx
.dl_ent_loop:
                ; Compute entry address.
                MOVE    D0, D2
                SHL4    D0
                SHL     D0
                ADD     D0, #FS_BUF_SECTOR
                LOADI   Y1, #$00
                MOVE    X1, D0                  ; XY1 = entry address

                ; Check first byte.
                LOADB   D0, [XY1]
                AND     D0, #$FF
                CMP     D0, #DIR_FREE_END
                BEQ     .dl_notfound            ; $00 sentinel → done
                CMP     D0, #DIR_FREE_REUSABLE
                BEQ     .dl_skip                ; deleted

                ; Check attr.
                LOADI   D0, #DIR_ATTR
                LOADB   D0, [XY1+D0]
                AND     D0, #$FF
                CMP     D0, #DIR_ATTR_LFN
                BEQ     .dl_skip
                AND     D0, #DIR_ATTR_VOLUME_LABEL
                BNE     .dl_skip

                ; --- Compare 11 bytes against caller's name ---------------
                ; XY1 = entry address (set above). Restore XY0 to caller's
                ; name from stack. The compare walks both XY0 and XY1
                ; forward, so we must restore XY0 from scratch each
                ; .dl_ent_loop iteration that reaches the compare. The
                ; outer .dl_ent_loop reload of XY1 from ent_idx*32 means
                ; XY1 is also rebuilt every iteration, so no need to save
                ; that.
                ;
                ; Stack top→down: name_ptr, D3.
                POP     XY0, XY3                ; load caller's name
                PUSH    XY0, XY3                ; re-push (we walk it)

                ; Save sec_off (D1) and ent_idx (D2) so we can use them
                ; freely as compare scratch.
                PUSH    D1, XY3                 ; save sec_off
                PUSH    D2, XY3                 ; save ent_idx

                LOADI   D1, #11                 ; counter
.dl_cmp:
                ; STREAM post-increment (stride 1, byte) — flag-transparent.
                ; LOADB zero-extends, so the AND #$FF is belt-and-braces.
                ; The CMP below provides the branch flags (never branch on a
                ; post-increment load result — see Ref Manual B.13).
                LOADB   D0, [XY0]+
                AND     D0, #$FF
                LOADB   D2, [XY1]+
                AND     D2, #$FF
                CMP     D0, D2
                BNE     .dl_mismatch
                SUB     D1, #1
                BNE     .dl_cmp

                ; --- Match: 11 bytes equal -------------------------------
                POP     D2, XY3                 ; restore ent_idx
                POP     D1, XY3                 ; restore sec_off

                ; Build cookie = (sec_off << 4) | ent_idx
                MOVE    D0, D1
                SHL4    D0
                OR      D0, D2

                POP     XY0, XY3                ; restore caller's name
                POP     D3, XY3
                RETCC

.dl_mismatch:
                POP     D2, XY3                 ; restore ent_idx
                POP     D1, XY3                 ; restore sec_off
                ; XY0 is mid-walk through caller's name. We don't fix it
                ; up here — next .dl_ent_loop iteration that reaches the
                ; compare reloads XY0 from the saved stack value.
                ; fall through to .dl_skip

.dl_skip:
                ADD     D2, #1
                CMP     D2, #16
                BLO     .dl_ent_loop

                ADD     D1, #1
                BRA     .dl_sec_loop

.dl_notfound:
                POP     XY0, XY3                ; restore caller's name
                POP     D3, XY3
                LOADI   D0, #ERR_NOTFOUND
                SEC
                RET

.dl_io_err:
                ; Read failed — mark dir cache invalid so future calls retry.
                LOADI   D0, #FAT_CACHE_INVALID
                STOREZ  D0, [#DIR_CACHE_SECTOR]
                ; Stack top→down: sec_off, name_ptr, D3.
                POP     D1, XY3                 ; discard sec_off
                POP     XY0, XY3                ; restore name
                POP     D3, XY3
                LOADI   D0, #ERR_IO
                SEC
                RET

                ; --- subdir walk failures ---------------------------------
                ; Stack top→down: sec_off [W], name_ptr, D3.
                ; ([V] counter is always popped before reaching here.)
.dl_walk_io:
                POP     D1, XY3                 ; discard sec_off [W]
                POP     XY0, XY3                ; restore name
                POP     D3, XY3
                LOADI   D0, #ERR_IO
                SEC
                RET

.dl_walk_eoc:
                ; Chain ended before sec_off — the name simply isn't in this
                ; directory. Same meaning to the caller as the root $00
                ; sentinel: ERR_NOTFOUND.
                POP     D1, XY3                 ; discard sec_off [W]
                POP     XY0, XY3                ; restore name
                POP     D3, XY3
                LOADI   D0, #ERR_NOTFOUND
                SEC
                RET


; ============================================================================
; _DirSecToAbs — resolve a directory sec_off to an absolute volume sector
;
;   Cluster-aware. DIR_WALK_CLU selects the directory:
;     0   = root region  -> VOL_ROOT_START + sec_off
;     >=2 = subdir        -> walk the FAT chain sec_off links, then
;                            _ClusterToSector on the resulting cluster.
;
;   In:    D1  = sec_off
;          XY2 = volume slot ptr
;          D3  = drive index
;   Out:   C=0 with D0 = absolute sector
;          C=1 with D0 = ERR_NOMORE   sec_off is past end-of-dir (chain EOC)
;          C=1 with D0 = ERR_IO       FAT read failed / corrupt link
;   Clobbers: D0, X0, X1, flags
;   Preserves: D1, D2, D3, Y0, Y1, XY2, XY3
;
; D1 (sec_off) is preserved so the caller can reuse it for the cookie /
; write-back. The chain walk needs a scratch counter + cluster; both are
; kept on the stack across _FATGetEntry (which clobbers D0/D1/D2/X0/X1),
; and D1/D2 are restored before return.
; ============================================================================
_DirSecToAbs:
                LOADZ   D0, [#DIR_WALK_CLU]
                CMP     D0, #0
                BNE     .dsa_subdir

                ; ----- root region -----
                ; Bound: sec_off < ceil(root_entries / 16). Past the end is
                ; reported as ERR_NOMORE (same as a subdir chain hitting EOC),
                ; so callers get one uniform "no more sectors" signal.
                LOADD   D0, [XY2+#VOL_ROOT_ENTRIES]
                ADD     D0, #15
                SHR4    D0                      ; D0 = root_sectors
                CMP     D1, D0
                BHS     .dsa_root_end
                LOADD   D0, [XY2+#VOL_ROOT_START]
                ADD     D0, D1                  ; D0 = absolute sector
                ; NOTE: ADD sets carry on overflow; RETCC here would be a
                ; flag bug (it returns on C=0, but ADD just clobbered C).
                ; Force success carry explicitly.
                CLC
                RET

.dsa_root_end:
                LOADI   D0, #ERR_NOMORE
                SEC
                RET

                ; ----- subdir: walk chain sec_off links -----
.dsa_subdir:
                PUSH    D1, XY3                 ; [a] save sec_off (preserve for caller)
                PUSH    D2, XY3                 ; [b] save D2 (preserve for caller)
                ; D1 = remaining steps (= sec_off); D2 = current cluster.
                LOADZ   D2, [#DIR_WALK_CLU]
.dsa_walk:
                CMP     D1, #0
                BEQ     .dsa_walk_done
                PUSH    D1, XY3                 ; [c] counter across the call
                MOVE    D0, D2
                CALLR   _FATGetEntry             ; D0 = next/EOC; clobbers D1,D2,X0,X1
                POP     D1, XY3                 ; [c]
                BCS     .dsa_io                  ; FAT read error
                CMP     D0, #FAT_BAD
                BEQ     .dsa_io                  ; corrupt link -> ERR_IO
                CMP     D0, #FAT_EOC_MIN
                BHS     .dsa_eoc                 ; chain ends before sec_off
                MOVE    D2, D0                   ; advance cluster
                SUB     D1, #1
                BRA     .dsa_walk
.dsa_walk_done:
                MOVE    D0, D2                   ; target cluster
                CALLR   _ClusterToSector         ; D0 = abs sector; preserves D2,D3,XY*
                BCS     .dsa_io                  ; defensive (cluster<2 == corrupt)
                POP     D2, XY3                 ; [b] restore D2
                POP     D1, XY3                 ; [a] restore sec_off
                CLC                              ; explicit success (POPs are
                RET                              ;   flag-transparent; be sure)

.dsa_io:
                POP     D2, XY3                 ; [b]
                POP     D1, XY3                 ; [a]
                LOADI   D0, #ERR_IO
                SEC
                RET

.dsa_eoc:
                POP     D2, XY3                 ; [b]
                POP     D1, XY3                 ; [a]
                LOADI   D0, #ERR_NOMORE
                SEC
                RET


; ============================================================================
; _DirGrowChain — append one fresh, zeroed cluster to a subdirectory.
;
;   Walks the chain at DIR_WALK_CLU to its tail, allocates a new cluster
;   (EOC), links the tail to it, then zero-fills the new cluster's sector so
;   every entry reads as DIR_FREE_END ($00). Used by _DirFindRun / _DirCreate
;   when a subdir create runs off the end of the directory chain.
;
;   SUBDIRS ONLY — caller must have verified DIR_WALK_CLU != 0 (the fixed root
;   region cannot grow).
;
;   In:    DIR_WALK_CLU = directory start cluster (>= 2)
;          XY2 = volume slot ptr,   D3 = drive index
;   Out:   C=0 success (chain is now one cluster longer; new sector zeroed).
;          C=1 with D0 = ERR_NOSPACE (volume full) / ERR_IO / ERR_READONLY.
;   Clobbers: D0, D1, D2, X0, X1, flags.   Preserves: D3, XY2, XY3.
;
;   Uses NO slot scratch — the tail and new-cluster numbers live on the stack.
;   The grow is invoked from inside _DirFindRun (called by _DirCreateRun), which
;   has live metadata in slot+$3A/$3B/$3C (notably the LFN checksum at $3A).
;   Touching slot scratch here would corrupt that and yield ERR_NOTFOUND on the
;   subsequent long-name lookup.
; ============================================================================
_DirGrowChain:
                ; --- 1. walk to the tail cluster --------------------------
                LOADZ   D2, [#DIR_WALK_CLU]      ; D2 = cur
.dgc_walk:
                MOVE    D0, D2
                PUSH    D2, XY3                  ; preserve cur across the FAT read
                CALLR   _FATGetEntry             ; D0 = FAT[cur]; clobbers D1,D2,X0,X1
                POP     D2, XY3                  ; D2 = cur
                BCS     .dgc_err                 ; D0 = ERR_IO
                CMP     D0, #FAT_BAD
                BEQ     .dgc_io                  ; corrupt link
                CMP     D0, #FAT_EOC_MIN
                BHS     .dgc_tail                ; D0 >= EOC -> cur (D2) is the tail
                MOVE    D2, D0                   ; advance to next cluster
                BRA     .dgc_walk
.dgc_tail:
                ; D2 = tail cluster.
                ; --- 1b. clear the end-of-dir sentinel in the tail --------
                ; Once we append a cluster, this tail is no longer the final
                ; cluster, so it must contain no $00 (DIR_FREE_END) entry — a
                ; $00 here would make traversal (lookup, dirent) stop before
                ; reaching the new cluster. Rewrite every $00 first-byte to
                ; $E5 (DIR_FREE_REUSABLE), which scanners skip. The 8.3 grow
                ; path only grows a full tail, so this is a no-op there.
                PUSH    D2, XY3                  ; [tail]
                MOVE    D0, D2
                CALLR   _ClusterToSector         ; D0 = tail abs sector
                BCS     .dgc_err_pop1
                PUSH    D0, XY3                  ; [tail][tsec]
                LOADI   Y0, #$00
                LOADI   X0, #FS_BUF_SECTOR
                CALLR   _VolBlockRead            ; tail sector -> FS_BUF_SECTOR
                BCS     .dgc_err_pop2
                LOADI   Y1, #$00                 ; scan 16 entries
                LOADI   X1, #FS_BUF_SECTOR
                LOADI   D1, #16
.dgc_fill:
                LOADB   D0, [XY1]
                AND     D0, #$FF
                CMP     D0, #DIR_FREE_END        ; $00 = never-used
                BNE     .dgc_fill_next
                LOADI   D0, #DIR_FREE_REUSABLE   ; $E5 = deleted/reusable (skipped)
                STOREB  D0, [XY1]
.dgc_fill_next:
                ADD     X1, #32                  ; next 32-byte entry
                SUB     D1, #1
                BNE     .dgc_fill
                POP     D0, XY3                  ; [tail] ; D0 = tsec
                LOADI   Y0, #$00
                LOADI   X0, #FS_BUF_SECTOR
                CALLR   _VolBlockWrite           ; write the de-sentinelled tail back
                BCS     .dgc_err_pop1            ; ERR_IO/READONLY -> discard [tail]

                ; --- 2. allocate a new cluster (returns EOC) --------------
                CALLR   _AllocCluster            ; D0 = newclu; C=1 ERR_NOSPACE
                BCS     .dgc_err_pop1            ; full -> discard [tail]
                POP     D1, XY3                  ; D1 = tail   (stack: empty)
                PUSH    D0, XY3                  ; [newclu]
                MOVE    D0, D1                   ; D0 = tail
                POP     D1, XY3                  ; D1 = newclu (stack: empty)
                PUSH    D1, XY3                  ; [newclu]    (keep for sector zero)
                ; --- 3. link FAT[tail] = newclu ---------------------------
                CALLR   _FATSetEntry             ; FAT[tail]=newclu (D0=tail, D1=newclu)
                BCS     .dgc_err_pop1            ; ERR_IO/READONLY -> discard [newclu]
                ; --- 4. zero the new cluster's sector and write it --------
                CALLR   _ZeroBuffer              ; FS_BUF_SECTOR = 0 (keeps stack/XY3)
                POP     D0, XY3                  ; D0 = newclu (stack: empty)
                CALLR   _ClusterToSector         ; D0 = abs sector; preserves XY*,D2,D3
                BCS     .dgc_err                 ; (defensive: cluster < 2)
                LOADI   Y0, #$00
                LOADI   X0, #FS_BUF_SECTOR        ; XY0 = source buffer
                CALLR   _VolBlockWrite           ; D0 = sector, XY0 = buf, XY2 = slot
                BCS     .dgc_err                 ; ERR_IO / ERR_READONLY
                CLC
                RET

.dgc_err_pop2:
                POP     D1, XY3                  ; discard [tsec]
.dgc_err_pop1:
                POP     D1, XY3                  ; discard the one saved cluster number
                SEC
                RET
.dgc_io:
                LOADI   D0, #ERR_IO
.dgc_err:
                SEC
                RET


; ============================================================================
; _DirInitCluster — write the '.' and '..' entries into a fresh dir cluster
;
;   Lays down exactly two 32-byte directory entries at the start of the
;   given (already-allocated, EOC-marked) cluster, the rest zero-filled:
;     entry 0  "."   attr=DIR, first_cluster = selfclu
;     entry 1  ".."  attr=DIR, first_cluster = parentclu  (0 if parent is
;                                                           the root region)
;   Then writes the sector to disk via _VolBlockWrite.
;
;   FAT '.'/'..' names are plain 8.3, never LFN: "."  -> "."+10 spaces,
;   ".." -> ".."+9 spaces. Date/time from _GetDate/_GetTime.
;
;   In:    D0  = self cluster   (the new directory's own cluster, >=2)
;          D1  = parent cluster (0 = parent is the hardware root region)
;          XY2 = volume slot ptr
;          D3  = drive index
;   Out:   C=0 success
;          C=1 with D0 = ERR_IO / ERR_READONLY  on write failure
;          C=1 with D0 = ERR_INVALID            self cluster < 2
;   Clobbers: D0, D1, D2, X0, X1, flags
;   Preserves: D3, XY2, XY3
;
;   Self/parent clusters are stashed in the slot reserved area $30..$33
;   (same scratch _DirCreate / _FormatVolume use; no temporal overlap).
; ============================================================================
_DirInitCluster:
                PUSH    D3, XY3

                ; Stash self (D0) + parent (D1) in slot+$30 / slot+$32.
                MOVE    X1, X2
                ADD     X1, #$30
                MOVE    Y1, Y2                  ; XY1 = slot + $30
                STORED  D0, [XY1+#0]            ; self cluster
                STORED  D1, [XY1+#2]            ; parent cluster

                ; Compute target sector for self cluster (need it before we
                ; clobber things; _ClusterToSector preserves D2/D3/XY*).
                ; D0 still = self cluster here.
                CALLR   _ClusterToSector         ; D0 = abs sector
                BCS     .dic_inval               ; self < 2 -> ERR_INVALID
                ; Stash the sector at slot+$34.
                MOVE    X1, X2
                ADD     X1, #$34
                MOVE    Y1, Y2
                STORED  D0, [XY1+#0]            ; abs sector

                ; Zero the whole sector buffer.
                CALLR   _ZeroBuffer              ; FS_BUF_SECTOR = 0; preserves D2,D3,XY2,XY3

                ; --- entry 0 : "." -----------------------------------------
                ; Name: '.' then 10 spaces.
                LOADI   Y1, #$00
                LOADI   X1, #FS_BUF_SECTOR       ; XY1 -> entry 0, byte 0
                LOADI   D0, #'.'
                STOREB  D0, [XY1]+               ; name[0] = '.'
                LOADI   D0, #' '
                LOADI   D2, #10
.dic_dot_pad:
                STOREB  D0, [XY1]+
                SUB     D2, #1
                BNE     .dic_dot_pad
                ; XY1 now at entry0 + 11 = DIR_ATTR.
                LOADI   D0, #DIR_ATTR_DIRECTORY
                STOREB  D0, [XY1]+               ; attr ; XY1 -> +$0C
                CALLR   _DicFillMeta             ; fills +$0C..+$19, sets cluster/size
                ; On return XY1 -> entry0 + $1A; write self cluster + zero size.
                MOVE    X1, X2
                ADD     X1, #$30
                MOVE    Y1, Y2
                LOADD   D0, [XY1+#0]             ; self cluster
                LOADI   Y1, #$00
                LOADI   X1, #FS_BUF_SECTOR
                ADD     X1, #$1A                 ; entry0 + DIR_FIRST_CLUSTER_LO
                STORED  D0, [XY1]                ; first cluster lo
                ADD     X1, #2
                LOADI   D0, #0
                STORED  D0, [XY1]                ; size lo
                ADD     X1, #2
                STORED  D0, [XY1]                ; size hi

                ; --- entry 1 : ".." ----------------------------------------
                LOADI   Y1, #$00
                LOADI   X1, #FS_BUF_SECTOR
                ADD     X1, #32                  ; entry 1, byte 0
                LOADI   D0, #'.'
                STOREB  D0, [XY1]+               ; name[0] = '.'
                STOREB  D0, [XY1]+               ; name[1] = '.'
                LOADI   D0, #' '
                LOADI   D2, #9
.dic_dd_pad:
                STOREB  D0, [XY1]+
                SUB     D2, #1
                BNE     .dic_dd_pad
                ; XY1 -> entry1 + 11 = DIR_ATTR.
                LOADI   D0, #DIR_ATTR_DIRECTORY
                STOREB  D0, [XY1]+
                CALLR   _DicFillMeta
                ; parent cluster + zero size at entry1 + $1A.
                MOVE    X1, X2
                ADD     X1, #$32
                MOVE    Y1, Y2
                LOADD   D0, [XY1+#0]             ; parent cluster (0 = root)
                LOADI   Y1, #$00
                LOADI   X1, #FS_BUF_SECTOR
                ADD     X1, #32
                ADD     X1, #$1A                 ; entry1 + DIR_FIRST_CLUSTER_LO
                STORED  D0, [XY1]
                ADD     X1, #2
                LOADI   D0, #0
                STORED  D0, [XY1]
                ADD     X1, #2
                STORED  D0, [XY1]

                ; --- write the sector back ---------------------------------
                MOVE    X1, X2
                ADD     X1, #$34
                MOVE    Y1, Y2
                LOADD   D0, [XY1+#0]             ; abs sector
                LOADI   Y0, #$00
                LOADI   X0, #FS_BUF_SECTOR
                CALLR   _VolBlockWrite
                BCS     .dic_err                 ; D0 = ERR_IO / ERR_READONLY

                ; The dir cache may have held a different sector; this write
                ; bypassed _DirNextRaw, so drop the cache to be safe.
                CALLR   _DirCacheInvalidate

                LOADI   D0, #ERR_OK
                CLC
                POP     D3, XY3
                RET

.dic_inval:
                LOADI   D0, #ERR_INVALID
                POP     D3, XY3
                SEC
                RET

.dic_err:
                ; D0 already = ERR_IO / ERR_READONLY, C=1.
                POP     D3, XY3
                RET


; ============================================================================
; _DicFillMeta — fill dirent metadata bytes +$0C..+$19 (NT/time/date)
;
;   Internal helper for _DirInitCluster. On entry XY1 points at the
;   attribute byte + 1 (i.e. dirent + $0C). Writes:
;     +$0C NT-reserved = 0, +$0D create-tenths = 0
;     +$0E create-time, +$10 create-date, +$12 access-date
;     +$14 first-cluster-hi = 0
;     +$16 write-time, +$18 write-date
;   Leaves XY1 -> dirent + $1A (DIR_FIRST_CLUSTER_LO). Caller writes the
;   cluster + size words.
;
;   In:    XY1 = dirent + $0C
;   Out:   XY1 = dirent + $1A
;   Clobbers: D0, X1, flags
;   Preserves: D1, D2, D3, Y1, XY2, XY3
; ============================================================================
_DicFillMeta:
                LOADI   D0, #0
                STOREB  D0, [XY1]+               ; +$0C NT-reserved
                STOREB  D0, [XY1]+               ; +$0D create-tenths
                CALLR   _GetTime
                STORED  D0, [XY1]                ; +$0E create-time
                ADD     X1, #2
                CALLR   _GetDate
                STORED  D0, [XY1]                ; +$10 create-date
                ADD     X1, #2
                STORED  D0, [XY1]                ; +$12 access-date (= create-date)
                ADD     X1, #2
                LOADI   D0, #0
                STORED  D0, [XY1]                ; +$14 first-cluster-hi = 0
                ADD     X1, #2
                CALLR   _GetTime
                STORED  D0, [XY1]                ; +$16 write-time
                ADD     X1, #2
                CALLR   _GetDate
                STORED  D0, [XY1]                ; +$18 write-date
                ADD     X1, #2                   ; XY1 -> +$1A
                RET


; ============================================================================
; _DirCreate — create a new directory entry
;
;   Walks the root in order, claims the first $E5 (deleted) or $00
;   (never used) slot. Writes a fresh 32-byte entry with the supplied
;   name, attributes, first-cluster, and size. Time/date fields come
;   from _GetDate / _GetTime. The modified sector is written back.
;
;   Caller is responsible for ensuring the name doesn't already exist
;   (call _DirLookup first; map ERR_OK to ERR_EXISTS yourself if needed).
;   _DirCreate does NOT do duplicate-name detection.
;
;   In:    XY0 = 11-byte FAT-format name (caller pre-converted)
;          D0  = attributes byte (DIR_ATTR_*)
;          D1  = first cluster (word)
;          D2  = size in bytes (low word; high word always 0 for Phase 16)
;          XY2 = volume slot ptr
;          D3  = drive index
;   Out:   C=0 success
;          C=1 with D0 = ERR_NOSPACE   if directory is full
;          C=1 with D0 = ERR_READONLY  if volume is read-only
;          C=1 with D0 = ERR_IO        on read/write failure
;   Clobbers: D0, D1, D2, X0, X1, flags
;   Preserves: D3, XY0, XY2, XY3
;
; --- Implementation note ---------------------------------------------------
;
; D0/D1/D2 carry the user's attr/cluster/size into this function; the
; directory walk clobbers all three. Stash them in the slot's reserved
; area at offset $30..$35 (same scratch range _FormatVolume uses; they
; don't overlap in time).
;
; ============================================================================
_DirCreate:
                PUSH    D3, XY3
                PUSH    XY0, XY3                ; save caller's name

                ; --- Stash D0/D1/D2 in slot reserved area $30..$35 --------
                ; Need a temp for the LEA D-register offset; D0..D2 hold
                ; the values we're about to stash. Use D3? D3 was just
                ; pushed and is the drive index — we'd need to PUSH/POP.
                ; Cheaper: stash D0 to slot+$30 first via a fresh slot
                ; pointer built using X1 directly (mode 00 [XY] only).
                ; Simpler: build the slot+$30 pointer with two MOVEs.
                MOVE    X1, X2
                ADD     X1, #$30
                MOVE    Y1, Y2
                ; XY1 now = slot + $30. (Y2 = $00 always for slots in
                ; page $00; ADD can't propagate to Y so this is safe.)
                STORED  D0, [XY1+#0]            ; attr (low byte used)
                STORED  D1, [XY1+#2]            ; first cluster
                STORED  D2, [XY1+#4]            ; size low word

                ; --- Walk root sectors looking for a free slot ------------
                LOADI   D1, #0                  ; sec_off

.dc_sec_loop:
                ; Resolve sec_off -> absolute sector (root or subdir chain).
                CALLR   _DirSecToAbs
                BCS     .dc_offend              ; off the end -> grow subdir or ENOSPACE
                                                ; for create purposes; ERR_IO
                                                ; also lands here -> see note.
                ; NOTE: _DirSecToAbs returns ERR_NOMORE past end-of-dir and
                ; ERR_IO on a FAT fault. For a root dir, the original code
                ; treated "ran off the end" as ERR_NOSPACE; we preserve that
                ; by mapping both the chain-end and the root bound here.
                ; A genuine ERR_IO is rare and also surfaces as no-space to
                ; the caller; acceptable for Phase-16 mkdir (subdir growth,
                ; which would distinguish them, is a later change).
                PUSH    D1, XY3                 ; save sec_off
                LOADI   Y0, #$00
                LOADI   X0, #FS_BUF_SECTOR
                CALLR   _VolBlockRead
                BCS     .dc_io_err_pop1
                POP     D1, XY3

                ; Walk 16 entries looking for $E5 or $00.
                LOADI   D2, #0
.dc_ent_loop:
                MOVE    D0, D2
                SHL4    D0
                SHL     D0
                ADD     D0, #FS_BUF_SECTOR
                LOADI   Y1, #$00
                MOVE    X1, D0                  ; XY1 = entry addr

                LOADB   D0, [XY1]
                AND     D0, #$FF
                CMP     D0, #DIR_FREE_END
                BEQ     .dc_found
                CMP     D0, #DIR_FREE_REUSABLE
                BEQ     .dc_found

                ADD     D2, #1
                CMP     D2, #16
                BLO     .dc_ent_loop

                ADD     D1, #1
                BRA     .dc_sec_loop

.dc_found:
                ; XY1 = target entry addr, D1 = sec_off, D2 = ent_idx.
                ; XY0 has been clobbered by _VolBlockRead (the RAM disk
                ; backend walks XY0 through the caller's buffer during
                ; the copy). Restore it from the saved stack slot.
                ;
                ; Stack top→down: name_ptr, D3.
                POP     XY0, XY3                ; restore caller's name
                PUSH    XY0, XY3                ; re-push for exit unwind

                ; --- Save sec_off (ent_idx not needed past this point) ---
                PUSH    D1, XY3

                ; Format the 32-byte short entry (name + metadata) in place.
                ; XY0 = name, XY1 = entry addr, XY2 = slot (meta at slot+$30).
                CALLR   _DicFormatShortEntry

                ; --- Write the modified sector back -----------------------
                POP     D1, XY3                 ; restore sec_off
                CALLR   _DirSecToAbs            ; D0 = absolute sector (D1 preserved)
                BCS     .dc_io_err              ; (shouldn't fail — sector was just read)

                ; Stash the absolute sector before _VolBlockWrite, which
                ; clobbers D0/D1/D2. We reuse it for the cache identity below
                ; instead of re-calling _DirSecToAbs — _VolBlockWrite destroys
                ; D1 (sec_off), so a second resolve would walk a garbage
                ; sec_off and (for the root) trip the bound -> ERR_NOMORE.
                PUSH    D0, XY3                 ; [S] absolute sector

                LOADI   Y0, #$00
                LOADI   X0, #FS_BUF_SECTOR
                CALLR   _VolBlockWrite
                BCS     .dc_io_err_pops         ; D0 = ERR_IO or ERR_READONLY

                ; Part 22: update dir cache identity. Reuse [S], NOT a fresh
                ; _DirSecToAbs (D1 is now garbage from _VolBlockWrite).
                POP     D0, XY3                 ; [S] absolute sector
                STOREZ  D0, [#DIR_CACHE_SECTOR]
                STOREZB D3, [#DIR_CACHE_DRIVE]

                ; Invalidate dirent iteration cache — file create may shift
                ; later entries' indices, so any cached "I was at index N
                ; cookie X" assumption is no longer safe.
                LOADI   D0, #$FFFF
                STOREZ  D0, [#DIRENT_LAST_COOKIE]

                LOADI   D0, #ERR_OK
                CLC
                POP     XY0, XY3                ; restore name
                POP     D3, XY3
                RET

.dc_io_err_pop1:
                ; Used after the per-sector PUSH but before per-entry pushes.
                ; Stack: sec_off, name_ptr, D3.
                POP     D1, XY3                 ; discard sec_off
                ; fall through to .dc_io_err

.dc_offend:
                ; _DirSecToAbs ran off the end. Subdir + end-of-chain
                ; (ERR_NOMORE) -> grow one cluster and retry the same sec_off;
                ; root region or a real ERR_IO -> ENOSPACE (as before).
                CMP     D0, #ERR_NOMORE
                BNE     .dc_nospace
                LOADZ   D0, [#DIR_WALK_CLU]
                CMP     D0, #0
                BEQ     .dc_nospace             ; root region cannot grow
                PUSH    D1, XY3                 ; save sec_off across the grow
                CALLR   _DirGrowChain
                POP     D1, XY3
                BCS     .dc_grow_fail
                BRA     .dc_sec_loop            ; retry; sec_off now in the new cluster
.dc_grow_fail:
                ; D0 = grow error. Unwind entry pushes (name_ptr, D3), return it.
                POP     XY0, XY3
                POP     D3, XY3
                SEC
                RET

.dc_nospace:
                ; Stack: name_ptr, D3.
                POP     XY0, XY3
                POP     D3, XY3
                LOADI   D0, #ERR_NOSPACE
                RETCS

.dc_io_err:
                ; D0 already = ERR_IO or ERR_READONLY from _VolBlockRead/Write,
                ; C=1. Just unwind and return.
                POP     XY0, XY3
                POP     D3, XY3
                RET

.dc_io_err_pops:
                ; Write-back failure with [S] (absolute sector) still on the
                ; stack: [S, name_ptr, D3]. Discard [S] into D1 (POP is flag-
                ; transparent; D0 keeps the error code), then unwind. C=1
                ; already from _VolBlockWrite.
                POP     D1, XY3                 ; discard [S]
                POP     XY0, XY3                ; name
                POP     D3, XY3
                RET




; ============================================================================
; _DicFormatShortEntry — write a 32-byte 8.3 short directory entry at [XY1].
;
;   Factored out of _DirCreate so the LFN run writer (_DirCreateRun) shares the
;   exact same short-entry layout. Copies the 11-byte name from XY0, then the
;   attr / NT-reserved / create+access+write time & date / first-cluster / size
;   fields, reading attr/cluster/size from the slot stash at slot+$30..$35.
;
;   In:    XY0 = 11-byte name source   XY1 = dest entry addr (in FS_BUF_SECTOR)
;          XY2 = slot (meta stash at slot+$30 attr, +$32 cluster, +$34 size)
;   Out:   32 bytes written at the original [XY1]; XY1 walked to entry+32.
;   Clobbers: D0, D2, X0, X1, flags.   Preserves: D1, D3, XY2, XY3.
; ============================================================================
_DicFormatShortEntry:
                ; --- Copy 11 name bytes from XY0 to XY1 -------------------
                ; XY1 walks forward through the dirent.
                LOADI   D0, #11
.dfs_name_copy:
                LOADB   D2, [XY0]+
                STOREB  D2, [XY1]+
                SUB     D0, #1
                BNE     .dfs_name_copy

                ; XY1 now = entry + 11 = +DIR_ATTR.
                ; --- Reload caller's attr/cluster/size from slot stash ---
                ; Build slot+$30 pointer in XY0 using MOVE+ADD (same
                ; pattern as the stash setup at top of this function).
                MOVE    X0, X2
                ADD     X0, #$30
                MOVE    Y0, Y2                  ; XY0 = slot + $30 (stash)

                ; Attr byte at +$0B.
                LOADD   D0, [XY0+#0]
                STOREB  D0, [XY1]
                ADD     X1, #1                  ; → +$0C

                ; NT-reserved + create-time-tenths zero (+$0C, +$0D).
                LOADI   D0, #0
                STOREB  D0, [XY1]
                ADD     X1, #1
                STOREB  D0, [XY1]
                ADD     X1, #1                  ; → +$0E

                ; Create time at +$0E (word).
                CALLR   _GetTime
                STORED  D0, [XY1]
                ADD     X1, #2                  ; → +$10

                ; Create date at +$10.
                CALLR   _GetDate
                STORED  D0, [XY1]
                ADD     X1, #2                  ; → +$12

                ; Access date at +$12 (same as create date).
                STORED  D0, [XY1]
                ADD     X1, #2                  ; → +$14

                ; First-cluster-high at +$14 (FAT16: zero).
                LOADI   D0, #0
                STORED  D0, [XY1]
                ADD     X1, #2                  ; → +$16

                ; Last-write-time at +$16.
                CALLR   _GetTime
                STORED  D0, [XY1]
                ADD     X1, #2                  ; → +$18

                ; Last-write-date at +$18.
                CALLR   _GetDate
                STORED  D0, [XY1]
                ADD     X1, #2                  ; → +$1A

                ; First-cluster-low at +$1A.
                LOADD   D0, [XY0+#2]            ; cluster from stash
                STORED  D0, [XY1]
                ADD     X1, #2                  ; → +$1C

                ; File size at +$1C (low word + high word = 0).
                LOADD   D0, [XY0+#4]            ; size low from stash
                STORED  D0, [XY1]
                ADD     X1, #2
                LOADI   D0, #0
                STORED  D0, [XY1]
                RET




; ============================================================================
; _DcrEntryAddr — XY1 = FS_BUF_SECTOR + (ent_idx + k) * 32  (entry address).
;   In:  D0 = k.   Reads ent_idx from slot+$3E.   XY2 = slot.
;   Out: XY1 = entry address.   Clobbers D0, D1, X1, Y1.   Preserves D2, D3.
; ============================================================================
_DcrEntryAddr:
                MOVE    X1, X2
                ADD     X1, #$3E
                MOVE    Y1, Y2
                LOADB   D1, [XY1]
                AND     D1, #$FF                ; ent_idx
                ADD     D0, D1                  ; slot index = ent_idx + k
                SHL4    D0
                SHL     D0                      ; * 32
                ADD     D0, #FS_BUF_SECTOR
                LOADI   Y1, #$00
                MOVE    X1, D0
                RET


; ============================================================================
; _DirDelete — mark a directory entry as deleted ($E5 first byte)
;
;   Caller MUST have already freed any cluster chain (walk via FAT
;   sentinels and call _FreeCluster on each); _DirDelete does not touch
;   the cluster chain.
;
;   In:    XY0 = 11-byte FAT-format name (caller pre-converted)
;          XY2 = volume slot ptr
;          D3  = drive index
;   Out:   C=0 success
;          C=1 with D0 = ERR_NOTFOUND  if name not present
;          C=1 with D0 = ERR_READONLY  if volume is read-only
;          C=1 with D0 = ERR_IO        on read/write failure
;   Clobbers: D0, D1, D2, X0, X1, flags
;   Preserves: D3, XY0, XY2, XY3
;
; Calls _DirLookup, which leaves the matching sector in FS_BUF_SECTOR
; and returns the cookie. Patch the first byte to $E5 in place and
; write the sector back.
;
; ============================================================================
_DirDelete:
                PUSH    XY0, XY3                ; preserve caller's name
                CALLR   _DirLookup
                BCS     .dd_err                 ; ERR_NOTFOUND or ERR_IO

                ; D0 = cookie pointing at the entry.
                MOVE    D1, D0
                SHR4    D1                      ; D1 = sec_off
                MOVE    D2, D0
                AND     D2, #$0F                ; D2 = ent_idx

                ; entry_addr = FS_BUF_SECTOR + ent_idx * 32
                MOVE    D0, D2
                SHL4    D0
                SHL     D0
                ADD     D0, #FS_BUF_SECTOR
                LOADI   Y1, #$00
                MOVE    X1, D0

                LOADI   D0, #DIR_FREE_REUSABLE
                STOREB  D0, [XY1]

                ; Write sector back. The entry lives in DIR_WALK_CLU's
                ; directory (root region if 0, else a subdir cluster chain),
                ; NOT necessarily the root — so map sec_off -> absolute via
                ; _DirSecToAbs, exactly as _DirCreate does. (Bug 16 Jun 2026:
                ; this used VOL_ROOT_START + sec_off unconditionally, so a
                ; subdir delete stamped the modified subdir sector on top of
                ; the ROOT directory — wiping root and orphaning entries.)
                ; D1 = sec_off here. _DirSecToAbs takes sec_off in D1 and
                ; preserves D2/D3/XY*.
                CALLR   _DirSecToAbs            ; D0 = absolute sector
                BCS     .dd_io_err              ; (shouldn't fail — just read)

                ; _VolBlockWrite clobbers D0/D1/D2; stash the abs sector to
                ; reuse for the cache identity (a second _DirSecToAbs would
                ; see a garbage sec_off and could trip the root bound).
                PUSH    D0, XY3                 ; [S] absolute sector

                LOADI   Y0, #$00
                LOADI   X0, #FS_BUF_SECTOR
                CALLR   _VolBlockWrite
                BCS     .dd_io_err_pops         ; D0 = ERR_IO or ERR_READONLY

                ; Part 22: update dir cache identity. Reuse [S].
                POP     D0, XY3                 ; [S] absolute sector
                STOREZ  D0, [#DIR_CACHE_SECTOR]
                STOREZB D3, [#DIR_CACHE_DRIVE]

                ; Invalidate dirent iteration cache — deletion changes the
                ; visible-entry indexing, so any cached resume point is
                ; potentially wrong.
                LOADI   D0, #$FFFF
                STOREZ  D0, [#DIRENT_LAST_COOKIE]

                LOADI   D0, #ERR_OK
                CLC
                POP     XY0, XY3                ; restore caller's name
                RET

.dd_io_err:
                ; D0 already set by _VolBlockWrite/_DirSecToAbs, C=1.
                POP     XY0, XY3
                RET

.dd_io_err_pops:
                ; Write-back failure with [S] (abs sector) still on the stack:
                ; [S, name]. Discard [S] into D1 (POP is flag-transparent;
                ; D0 keeps the error code), then unwind. C=1 already.
                POP     D1, XY3                 ; discard [S]
                POP     XY0, XY3                ; name
                RET

.dd_err:
                ; D0/C already set by _DirLookup.
                POP     XY0, XY3
                RET


_DirCacheInvalidate:
                LOADI   D0, #FAT_CACHE_INVALID
                STOREZ  D0, [#DIR_CACHE_SECTOR]
                RET


; ============================================================================
; End of kos_fs_dir.asm
; ============================================================================




