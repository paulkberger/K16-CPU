; ============================================================================
; kos_fs_dir.asm — k/OS Phase 16 Piece 4: directory operations
; ============================================================================
; Date:    6 May 2026
; Status:  Phase 16 Piece 4 — name conversion, iteration, lookup, create/delete
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
                STOREB  D0, [XY1]
                ADD     X1, #1
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
; _DirOpen — initialise an iteration cookie for the root directory
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

                ; --- Bound check: sec_off < ceil(root_entries / 16) -------
                LOADD   D0, [XY2+#VOL_ROOT_ENTRIES]
                ADD     D0, #15
                SHR4    D0                      ; D0 = root_sectors
                CMP     D1, D0
                BHS     .dnr_nomore

                ; --- Read the target root sector --------------------------
                ; Check dir cache first — if FS_BUF_SECTOR already holds this
                ; sector for this drive, skip the read. _DirCacheInvalidate
                ; resets these on any non-_DirNextRaw write to FS_BUF_SECTOR.
                LOADD   D0, [XY2+#VOL_ROOT_START]
                ADD     D0, D1                  ; D0 = absolute sector
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
                MOVE    X0, D0
                LOADI   D0, #32
.dnr_copy:
                LOADB   D2, [XY0]
                STOREB  D2, [XY1]
                ADD     X0, #1
                ADD     X1, #1
                SUB     D0, #1
                BNE     .dnr_copy

                ; --- Advance cookie ---------------------------------------
                ; D1 = sec_off (still valid). D2 was clobbered by the copy
                ; loop; recompute ent_idx from X0:
                ;   X0 = FS_BUF_SECTOR + (ent_idx+1)*32
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


; ============================================================================
; _DirNext — advance, return next *visible* entry (filter applied)
;
;   Skip rules:
;     • First byte $00  → end-of-dir (ERR_NOMORE)
;     • First byte $E5  → deleted, skip silently
;     • Attr == $0F     → LFN, skip silently
;     • Attr bit 3 set  → volume label, skip silently
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
.dn_loop:
                CALLR   _DirNextRaw
                BCS     .dn_err

                LOADB   D1, [XY1]
                AND     D1, #$FF
                BEQ     .dn_eod                 ; $00 → end of dir

                CMP     D1, #DIR_FREE_REUSABLE
                BEQ     .dn_loop                ; deleted, retry

                LOADI   D2, #DIR_ATTR
                LOADB   D1, [XY1+D2]
                AND     D1, #$FF

                CMP     D1, #DIR_ATTR_LFN
                BEQ     .dn_loop                ; LFN, skip

                AND     D1, #DIR_ATTR_VOLUME_LABEL
                BNE     .dn_loop                ; volume label, skip

                RETCC

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
                ; Bound check.
                LOADD   D0, [XY2+#VOL_ROOT_ENTRIES]
                ADD     D0, #15
                SHR4    D0
                CMP     D1, D0
                BHS     .dl_notfound

                ; Read sector sec_off into FS_BUF_SECTOR — cache-aware.
                LOADD   D0, [XY2+#VOL_ROOT_START]
                ADD     D0, D1
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
                LOADB   D0, [XY0]
                AND     D0, #$FF
                LOADB   D2, [XY1]
                AND     D2, #$FF
                CMP     D0, D2
                BNE     .dl_mismatch
                ADD     X0, #1
                ADD     X1, #1
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
                RETCS

.dl_io_err:
                ; Read failed — mark dir cache invalid so future calls retry.
                LOADI   D0, #FAT_CACHE_INVALID
                STOREZ  D0, [#DIR_CACHE_SECTOR]
                ; Stack top→down: sec_off, name_ptr, D3.
                POP     D1, XY3                 ; discard sec_off
                POP     XY0, XY3                ; restore name
                POP     D3, XY3
                LOADI   D0, #ERR_IO
                RETCS


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
                ; Bound check.
                LOADD   D0, [XY2+#VOL_ROOT_ENTRIES]
                ADD     D0, #15
                SHR4    D0
                CMP     D1, D0
                BHS     .dc_nospace

                ; Read sector.
                LOADD   D0, [XY2+#VOL_ROOT_START]
                ADD     D0, D1
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

                ; --- Copy 11 name bytes from XY0 to XY1 -------------------
                ; XY1 walks forward through the dirent.
                LOADI   D0, #11
.dc_name_copy:
                LOADB   D2, [XY0]
                STOREB  D2, [XY1]
                ADD     X0, #1
                ADD     X1, #1
                SUB     D0, #1
                BNE     .dc_name_copy

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

                ; --- Write the modified sector back -----------------------
                POP     D1, XY3                 ; restore sec_off
                LOADD   D0, [XY2+#VOL_ROOT_START]
                ADD     D0, D1                  ; absolute sector

                LOADI   Y0, #$00
                LOADI   X0, #FS_BUF_SECTOR
                CALLR   _VolBlockWrite
                BCS     .dc_io_err              ; D0 = ERR_IO or ERR_READONLY

                ; Part 22: update dir cache identity. _VolBlockWrite
                ; clobbered D0 (status code), so recompute the sector #.
                LOADD   D0, [XY2+#VOL_ROOT_START]
                ADD     D0, D1
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

                ; Write sector back.
                LOADD   D0, [XY2+#VOL_ROOT_START]
                ADD     D0, D1                  ; absolute sector

                LOADI   Y0, #$00
                LOADI   X0, #FS_BUF_SECTOR
                CALLR   _VolBlockWrite
                BCS     .dd_io_err              ; D0 = ERR_IO or ERR_READONLY

                ; Part 22: update dir cache identity (FS_BUF_SECTOR is now
                ; this dir sector with the deletion applied). _VolBlockWrite
                ; clobbered D0; recompute.
                LOADD   D0, [XY2+#VOL_ROOT_START]
                ADD     D0, D1
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
                ; D0 already set by _VolBlockWrite, C=1.
                POP     XY0, XY3
                RET

.dd_err:
                ; D0/C already set by _DirLookup.
                POP     XY0, XY3
                RET


; ============================================================================
; _DirCacheInvalidate — drop the dir-buffer cache (Part 22)
;
;   Used by anything that writes to FS_BUF_SECTOR with sector data that's
;   NOT a root-directory sector (or a different drive's root). Examples:
;   _TryMount reading a BPB, _DirLookup reading directory entries on a
;   different drive, sys_read reading file data, _DirInsert / _DirDelete
;   after their sector-write.
;
;   In:    none
;   Out:   DIR_CACHE_SECTOR = $FFFF
;   Clobbers: D0
; ============================================================================
_DirCacheInvalidate:
                LOADI   D0, #FAT_CACHE_INVALID
                STOREZ  D0, [#DIR_CACHE_SECTOR]
                RET


; ============================================================================
; End of kos_fs_dir.asm
; ============================================================================
