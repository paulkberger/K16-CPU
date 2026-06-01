; ============================================================================
; kosh_cmds_fs.asm - kosh filesystem commands
; ============================================================================
; Date:    29 May 2026
; Status:  Part 39 - kosh.com migration.
; Revision: r23 - 29 May 2026 - Part 39: kosh.com migration. 126 CALL24
;             _Kosh* helper calls converted to CALL16, and 88 string
;             references switched from
;                 #SPAWN_ENTRY_OFFSET + (label - kosh_entry)
;             to bare
;                 #label
;             because kosh.asm now assembles with .ORG $0200 and labels
;             resolve directly to their in-page addresses. One compound
;             offset (kosh_format_label + 10 - kosh_entry) also flattened
;             to kosh_format_label + 10. Additionally, 12 CALL24 calls
;             to emulator-only host-disk helpers were redirected via
;             EMULIB v1.0 (kos_emulib.inc, base $A100):
;                 _HostBayName  -> EMULIB_HOST_BAYNAME   (slot 06)
;                 _HostRename   -> EMULIB_HOST_RENAME    (slot 05)
;                 _HostFOpen    -> EMULIB_HOST_FOPEN     (slot 07)
;                 _HostFClose   -> EMULIB_HOST_FCLOSE    (slot 08)  (×6)
;                 _HostFRead    -> EMULIB_HOST_FREAD     (slot 09)
;             EMULIB is a new emulator-only jump table at $A100,
;             separate from KLIB ($A000), so the portable / host-shim
;             distinction is clear in the architecture. No behaviour
;             change. Requires kosh.asm r39+, kos_emulib.inc r1+.
;
; Revision: r22 - 29 May 2026 - Part 38: removed now-unused per-error
;             strings superseded by the unified error reporter introduced
;             during Part 37 cp/mv rework.
;             Deleted (10 strings):
;               cp:   msg_cp_openerr_src, msg_cp_createerr, msg_cp_readerr,
;                     msg_cp_short
;               cat:  msg_cat_readerr
;               mv:   msg_mv_src_openerr, msg_mv_dst_createerr,
;                     msg_mv_read_err, msg_mv_write_err, msg_mv_short_write
;             Kept (still live or reserved):
;               msg_mv_unlink_err (defined, no current callers - left for
;                                  the post-copy unlink-failure path)
;               msg_mv_ro_src, msg_mv_ro_src_tag (RO-source mv notes,
;                                  added in Part 37 2nd session)
;             Verified zero live references for each deleted symbol before
;             removal. Old r10 string-list comment patched to reflect the
;             post-cleanup state.
;
; Revision: r21 - 18 May 2026 - Part 34 polish:
;             - Fixed Use% column alignment: pct render's pad-skip branch
;               had inverted carry sense (BCS where BCC was needed for the
;               "shouldn't happen" overflow path). Same K16-carry-sense
;               trap as kosh_helpers.asm r4; now the column data lines up
;               with the "Use%" header.
;             - SHL x 6 -> SHL4 + SHL + SHL in two slot-offset chains
;               (.do_ls header and _KoshPrintVolLine label setup). 3
;               instructions, 9 cycles vs 6 instructions, 18 cycles.
;               Saves ~12 bytes ROM total and matches the idiom used in
;               sys_diskfree's x512 chain.
;
; Revision: r20 - 18 May 2026 - Part 34 cont'd:
;             - .do_vol rewritten as a column-aligned disk-usage table
;               (Drive / Label / Total / Used / Free / Use%). Header line
;               + per-drive row built via _KoshPrintVolLine, which now
;               takes a drive index and calls sys_diskfree internally.
;             - _KoshPrintVolLine: full rewrite. Builds 50-char row in
;               ROW_BUF using _KoshEmitSize (kosh_helpers.asm r3) for the
;               size cells. Use% computed as (used*100)/total via
;               KLIB_DIVMOD32 over a KLIB_MUL16x16_32 product.
;             - msg_vol_clusters / msg_vol_ro retired; msg_vol_hdr +
;               msg_vol_dferr added. msg_vol_unmounted no longer carries
;               its own LF.
;             - .do_ls totals line:
;                 BEFORE: "  N file(s), BYTES bytes\n" (or KB, or BIG)
;                 NOW:    "  N file(s), USED used, FREE free\n"
;               Per-file size column kept as bare decimal (forensic
;               precision). Total + free emitted human-readable via
;               _KoshEmitSize raw mode (D2=0). Removes the bytes/KB/BIG
;               three-way branch and the 32-bit shift-divide block.
;             - msg_ls_bytes / msg_ls_kb / msg_ls_big retired;
;               msg_ls_used + msg_ls_free added.
;             - .load_copy_loop: track cumulative bytes-written in
;               LOAD_WRITTEN_LO/HI (kosh.asm r37). Init at dest-open;
;               accumulate per successful sys_write.
;             - .load_write_err: uses Part 34 sys_write's D1 (bytes of
;               failed chunk that landed before err) plus the cumulative
;               to print "load: wrote <SIZE> then failed:" preamble
;               before the standard "load: write error [...]" line. The
;               <SIZE> is rendered via _KoshEmitSize, so ENOSPC at 14464
;               bytes reads as "load: wrote 14.12KB then failed:".
;             - msg_load_wrote + msg_load_wrote_then added.
;
; Revision: r19 - 18 May 2026 - Part 34: fix three .do_load error paths
;             that called TRAP_CLOSE / _HostFClose BEFORE _KoshPrintErr,
;             clobbering D0 (the err code) with the close result.
;
;             Sites:
;               .load_create_err - _HostFClose clobbers D0 (also D1/D2).
;               .load_fread_err  - TRAP_CLOSE and _HostFClose both clobber D0.
;               .load_write_err  - same. This was the site that hid ENOSPC.
;
;             Pattern fix: MOVE D3, D0 to stash err code before close;
;             MOVE D0, D3 to restore before _KoshPrintErr. D3 is preserved
;             across TRAP_CLOSE (V2 ABI callee-saved), _HostFClose (per
;             its header), and _KoshPrintErr (per its header).
;
;             The same idiom exists correctly in .cat_read_err (uses D3),
;             .cp_*_err and .mv_*_err (use D2, but those paths don't call
;             _HostFClose which would clobber D2). load is the outlier
;             that mixes both close types; D3 is the right register here.
;
;             Also: .load_short_write annotated as currently unreachable
;             (sys_write never returns C=0 with short count under the
;             present semantics; pending Phase 11 design call on partial-
;             write reporting).
;
;           r18 - 11 May 2026 - reverted r17 workaround. The underlying
;             kernel bug (_FreeCluster clobbering D2 in _FATFreeChain /
;             _TruncateExisting walk on small disks) is fixed in
;             kos_fs.asm r10. `load -f` once again takes the direct
;             CREATE|WRITE|TRUNC path on the existing entry - faster,
;             one fewer syscall, no race window between unlink and
;             create.
;
; Revision: r17 - 11 May 2026 - Part 25 r8: .do_load `-f` path now unlinks
;             the destination file before opening with CREATE+WRITE+TRUNC.
;             Workaround for a kernel bug where TRAP_OPEN(OPEN_FLAGS_NEW)
;             on an existing file corrupts the directory on disk (entry 0
;             first byte gets zeroed, making the dir appear empty to ls).
;             Static analysis of the truncate path didn't find the root
;             cause; the workaround sidesteps it by always creating fresh.
;
;           r16 - 11 May 2026 - Part 25 r7 fix: bg flag now stashed in
;             task-local RUN_BG_TMP word ($45F8) across TRAP_EXEC, instead
;             of via PUSH D / POP D. The PUSH/POP approach clobbered D2
;             (which holds the returned TID), causing sys_wait to be
;             called with a garbage TID -> ERR_BADARG ($FFF9).
;
;           r15 - 11 May 2026 - Part 25 r7: backgrounded run via `&`.
;             • `run <path> &` spawns the child and returns immediately;
;               kosh prints "[bg N]\n" where N = child TID.
;             • `run <path>` (no &) is unchanged: TRAP_EXEC + TRAP_WAIT,
;               prints "[exit N]\n".
;             • Detection: after path parse, walks args backward over
;               trailing spaces; if the final non-space byte is '&',
;               clears it (and any preceding spaces) so sys_exec sees a
;               clean path, and sets D3 = bg flag.
;             • New string msg_run_bg_lbl ("bg "); msg_run_usage updated
;               to advertise the new syntax.
;             • Reaping: backgrounded children left as TS_DEAD until
;               kosh exits (no orphan reaper yet - Phase 20+).
;
;           r14 - 11 May 2026 - Part 25 r6: .do_load handler.
;             • New `load <name> [-f]` command ingests a host-side file
;               from EMU's load/ folder into the current drive.
;             • Uses CALL24 EMULIB_HOST_FOPEN / _HostFRead / _HostFClose
;               (kos_fs_host_mgr.asm r4) to talk to the new MMIO
;               surface (HOST_CMD_FOPEN/FREAD/FCLOSE).
;             • Reuses CP_BUF for read/write buffering, KOSH_NORM_A
;               for destination path. Load doesn't run concurrently
;               with cp/mv so the shared buffer is safe.
;             • All error paths call _HostFClose if FOPEN succeeded -
;               singleton state in the EMU means leaking a handle
;               would block all future load commands until reboot.
;             • Detects `-f` anywhere in the rest of the command line
;               (after the name token); refuses by default if dest
;               exists (matches cp behaviour).
;
;           r13 - 11 May 2026 - Part 25 r4: CWD support.
;             • Every path-taking command (.do_cat, .do_rm, .do_mv,
;               .do_cp, .do_run) now calls _KoshNormPath before its
;               TRAP. Bare filenames get "<CWD>:" prepended; explicit
;               "X:NAME" paths pass through unchanged.
;             • cp and mv use KOSH_NORM_A and KOSH_NORM_B (two
;               normalisation buffers; both paths live simultaneously).
;             • .ls_default now reads KOSH_CWD instead of hardcoding
;               FS_DRIVE_B - `ls` with no arg shows the current drive.
;             • .do_format still requires explicit drive arg (too
;               destructive to default).
;             • No new error paths - the kernel's existing ERR_BADPATH
;               etc. handle malformed inputs as before; _KoshNormPath
;               is a pure-rewrite helper.
;
;           r12 - 11 May 2026 - Part 25 r3: every err-printing site
;             refactored to use _KoshPrintErr (kosh_helpers.asm r2).
;             Net effect:
;             • Old: "format: failed $FFE2"
;               New: "format: failed [ERR_READONLY $FFE2]"
;             • Saved ~60 lines across .do_format/.do_cp/.do_rm/.do_mv/
;               .do_run + cat's open/read err pads.
;             • cat err sites now include the actual err code (previously
;               static "cat: cannot open file" - useless for diagnosing
;               ERR_BADPATH vs ERR_NOTFOUND vs ERR_IO).
;             • Some redundant msg_*_err strings removed in favour of
;               more general single-line prefixes (cp/mv consolidated
;               their per-stage prefix strings).
;             • Removed mid-error "$" emission and ROW_BUF formatting
;               from all sites - _KoshPrintErr owns that.
;
;           r11 - 11 May 2026 - Part 25 r2: .do_rm and .do_mv handlers.
;             • .do_rm: thin wrapper over TRAP_UNLINK. Parse path, refuse
;               on empty arg, print "OK" or "rm: <err>\n$XXXX\n".
;             • .do_mv: first try TRAP_RENAME (kernel does the work for
;               same-drive). If it returns ERR_INVALID (drives differ),
;               fall back to a cp-style copy loop + TRAP_UNLINK(src):
;                 - same dst-exists pre-flight as cp
;                 - reuse CP_BUF for the I/O staging buffer
;                 - if copy succeeds but unlink fails, print
;                   "mv: copy OK but unlink failed $XXXX\n" and leave
;                   the file at both locations (survivable)
;             • Same-path detection lives in the kernel for the rename
;               case (ERR_EXISTS), and in the kosh fallback path for
;               the cross-drive case (mirrors cp's logic).
;             • Three new strings: msg_rm_usage, msg_rm_failed, msg_mv_*.
;             • Two new cmd strings: cmd_rm_str (tag 27), cmd_mv_str
;               (tag 28). See kosh.asm r25.
;
; Revision: r10 - 11 May 2026 - Part 25: new .do_cp handler.
;             • cp <src> <dst> - copies a file using sys_open/read/write/close.
;             • Refuses if dst exists (pre-flight FOPEN_READ probe).
;               No silent overwrite - keeps the dev shell forgiving. A
;               `-f` flag can be added later if it matters.
;             • Refuses same-path src=dst (case-insensitive string compare).
;               Without this, the FD layer would happily open the same file
;               twice (no sharing protection) and the write side would
;               corrupt clusters under us.
;             • Buffer = 512 B (CP_BUF in kosh.asm) - matches sys_read's
;               natural cluster unit on the disks we use.
;             • Mid-copy short-write or error: closes both fds, leaves the
;               partial dst file in place, prints "cp: write error" with
;               the err code. No sys_delete exists yet to clean up; users
;               will see a partial file with a valid dirent. Documented
;               failure mode rather than a silent footgun.
;             • New strings: msg_cp_usage, msg_cp_samepath, msg_cp_exists,
;               msg_cp_writeerr, msg_cp_ok. (Several per-error strings -
;               msg_cp_openerr_src, msg_cp_createerr, msg_cp_readerr,
;               msg_cp_short - retired in r22.)
;             • New cmd_cp_str command-name string (tag 26 - see kosh.asm r24).
;
;           r9 - 11 May 2026 - Part 24 r2: format default-label sources
;             from host filename (option 3). `format C:` with no label
;             reads the bay's filename via _HostBayName and uses that as
;             the FAT16 label, instead of always defaulting to "USERDATA".
;             Result: even without typing a label, BPB and host filename
;             stay in sync. B: keeps "USERDATA" since there's no host
;             file. Fall back to "USERDATA" if _HostBayName fails.
;
;           r8 - 11 May 2026 - Part 24 rename integration:
;             - format with custom label now calls _HostRename after a
;               successful TRAP_FORMAT, keeping host filename and FAT16
;               label in sync. Default-label format (no arg) leaves the
;               host filename alone.
;             - Label characters validated upfront: A..Z, 0..9, _ only.
;               Mismatch with host-name rules used to silently leave
;               filenames diverged; now rejected with msg_format_badlabel.
;             - kosh_format_label buffer extended by 5 bytes to hold a
;               nul-terminated form after trim, used by _HostRename.
;             - kosh_format_custom byte tracks whether to rename.
;             - msg_format_rename_warn used when format OK but rename
;               failed (e.g., name conflict).
;
;           r7 - 11 May 2026 - Part 24 host-disk format:
;             - .do_format now accepts B..F (was B-only). Lowercase
;               accepted; optional ':' allowed; case-insensitive.
;             - Optional volume label argument: "format C: MYDISK" stores
;               "MYDISK     " in the BPB. Without label -> "USERDATA   "
;               default (rebuilt fresh each invocation; no carry-over).
;             - Label is uppercased, space-padded to 11, truncated at 11.
;             - _FormatVolume itself extended in kos_fs.asm r8: queries
;               disk size via CMD_IDENT for host bays.
;             - Strings updated: msg_format_usage now reads
;               "usage: format <drive> [label]   drive=B..F"; baddrv
;               reads "format: bad drive (B..F only; A: is read-only)".
;
; Revision: r6 - 9 May 2026 - Part 22 ls byte-total fix:
;             - ls now accumulates a 32-bit total via ADD/ADC into
;               LS_TOTAL_LO/LS_TOTAL_HI (was a single 16-bit
;               LS_TOTAL_BYTES that wrapped at 64KB, producing
;               nonsense totals for any directory > 64KB).
;             - "BIG" individual-file rows now also contribute to the
;               total (previously they were skipped, which made the
;               16-bit total even less reliable).
;             - Footer print mode chosen at the end:
;                 HI=0           -> "<lo> bytes"
;                 HI<>0, fits KB -> "<kb> KB"
;                 KB > 65535     -> "BIG"
;             - kosh.asm scratch layout extended: LS_TOTAL_HI added
;               at $40A4; LS_SIZE_TMP / LS_DRIVE_TMP / LS_INDEX_TMP /
;               CAT_BUF all shifted up by 1 word.
;             - ls usage string updated: "drive=A..F" (was "A:|B:").
;
; Revision: r5 - 9 May 2026 - Part 22 kosh-side updates:
;             - vol now prints all six slots (A..F).
;             - ls now accepts A..F (was A..B) - letter-to-drive
;               conversion is now a single CMP+SUB rather than a
;               4-way branch, and the slot offset is computed as
;               VOL_TABLE_BASE + drive*64 (six SHLs) rather than
;               looked up.
;             - format remains B-only by design - _FormatVolume in
;               kos_fs.asm is hardcoded for FS_DRIVE_B with RAM-disk
;               sizing. Host-disk format will require a CMD_IDENT-
;               based size query and FAT16 sizing logic appropriate
;               to variable disk sizes; deferred to a later Part 22 step.
;             - cat works for any letter unchanged: the path string
;               flows through to sys_open which now accepts A..F via
;               kos_fs_fd.asm r5's _ParsePath.
;
; Revision: r4 - 8 May 2026 - Removed do_cat's short-read EOF hack. The
;             post-EOF sys_read now correctly returns D0=0 / C=0 (was
;             returning ERR_BADFD due to V2 ABI violation in sys_read
;             clobbering D2 - fixed in kos_fs_fd.asm r3, 8 May 2026).
;             cat now follows the canonical loop: read until D0=0.
;
;           r3 - 7 May 2026 - Phase 19 ls bugfix:
;             - .do_ls was clobbering its own drive (D2) and index (D3)
;               via _KoshEmitNamePadded (takes width in D2) and
;               _KoshEmitDec (clobbers D1/D2/D3). Symptom: ls always
;               stopped at the first file, sys_dirent on iter 2
;               returned ERR_BADDRIVE because D2 was garbage.
;             - Bug was hidden until r17: until disk populate started
;               creating multiple files, B: never had more than one
;               entry, and ls treats any error as "end of dir".
;             - Fix: stash drive in LS_DRIVE_TMP, index in LS_INDEX_TMP
;               (new zero-page kosh-page slots, $40A6/$40A8). Re-load
;               at top of each iteration; bump LS_INDEX_TMP at the
;               bottom. CAT_BUF moved up 4 bytes ($40A6 -> $40AA) to
;               make room.
;
;           r2 - 7 May 2026 - Phase 19 additions:
;             - format <drive>: TRAP_FORMAT (TRAP #32) wrapper. Drive
;               must be B:. Hardcoded label "USERDATA   " for now;
;               optional label arg deferred.
;             - run <path>: TRAP_EXEC + TRAP_WAIT pair. Loads child
;               .COM, blocks until exit, prints "[exit N]\n". Path
;               passed straight through to sys_exec; sys_exec does
;               its own _ParsePath validation.
;             - Two new dispatch tags consumed: 18 (format), 19 (run).
;             - Two new strings each: cmd_format_str/cmd_run_str plus
;               their msg_*_usage / status messages.
;             - No new helpers needed - both commands are short and
;               use existing TRAPs only.
;
;           r1 - 7 May 2026 - initial: vol, ls, cat (Phase 16.7).
;
;   .INCLUDEd from kosh.asm after kosh_entry: so the strings declared here
;   live inside the kosh.com image. kosh.asm assembles with .ORG $0200, so
;   labels resolve directly to their in-page addresses (no manual rebase).
;
;   Commands:
;     vol             - print mounted volumes (label, total clusters)
;     ls [drive]      - list directory; drive defaults to B:
;     cat path        - print file contents to stdout
;
;   Dispatch tags 15, 16, 17 added to kos_kosh.asm cmd_table.
;
;   New CALL24 helpers (defined at bottom of this file):
;     _KoshEmitDec        - decimal cursor-emit; thin wrapper over KLIB_UTOA
;     _KoshEmitStrZ       - append zstring at XY0 to cursor
;     _KoshEmitNamePadded - emit zstring at XY0 trimmed/padded to D2 chars
;     _KoshPrintVolLine   - print one volume info line (used by vol)
;
;   Buffer-and-blast pattern used everywhere (one TRAP_PUTS per line)
;   to keep Digital responsive when listing many files or large vols.
;
;   KLIB use: KLIB_UTOA (slot 41) for decimal output. KLIB v1.1+ cursor
;   contract (advances XY0, writes nul at advanced position). All other
;   "1-instruction" emit helpers (_KoshEmitByte, _KoshEmitByteHex,
;   _KoshEmitWordHex) live in kos_kosh.asm and are reused as-is.
;
;   TODO Phase 17+: free-cluster count for `vol` (requires FAT walk).
; ============================================================================


; ----------------------------------------------------------------------------
; .do_vol - print disk usage table (Part 34 rewrite).
;
;   Output:
;     Drive  Label         Total     Used     Free  Use%
;     A:     KOSDISK      1.00MB     45KB    979KB    4%
;     B:     RAMDISK      1.00MB        0   1.00MB    0%
;     C:     (not mounted)
;     ...
;
;   Each row calls sys_diskfree(drive) -> free/total clusters + cluster_size.
;   Sizes rendered via _KoshEmitSize (kosh_helpers.asm r3) which builds the
;   human-readable string using KLIB_BYTES_SPLIT (slot 46).
;
;   Use% column = (used * 100) / total, computed in cluster space (16-bit
;   safe for Phase 16 sizes; cluster counts <= 2030 means used*100 <= 203000
;   so we need 32-bit intermediate via KLIB_DIVMOD32).
;
;   Pre-Part 34 vol output:
;     "<DRV>: <LABEL>  <total> clusters[, read-only]\n"
;   replaced - single command, single richer report.
; ----------------------------------------------------------------------------
.do_vol:
                ; Emit header line.
                MOVE    Y0, Y3
                LOADI   X0, #msg_vol_hdr
                TRAP    #TRAP_PUTS

                ; Loop drives 0..FS_MAX_DRIVES-1.
                LOADI   D0, #0
                STOREP  D0, Y3, [#DISK_DRIVE_TMP]
.dv_loop:
                LOADP   D0, Y3, [#DISK_DRIVE_TMP]
                CMP     D0, #FS_MAX_DRIVES
                BHS.S   .dv_done
                CALL16  _KoshPrintVolLine       ; D0 = drive index
                LOADP   D0, Y3, [#DISK_DRIVE_TMP]
                ADD     D0, #1
                STOREP  D0, Y3, [#DISK_DRIVE_TMP]
                BRA     .dv_loop
.dv_done:
                BRA     .repl_loop


; ----------------------------------------------------------------------------
; .do_ls - list directory contents of a drive.
;
;   Args: optional drive letter "A:" or "B:"; default "B:".
;
;   Output:
;     <DRV>: <LABEL>
;     <8.3 name>     <size>
;     ...
;     <n> file(s), <total> bytes
;
;   Walks via sys_dirent (TRAP_DIRENT) - forward-compatible if kosh
;   later moves to user context.
; ----------------------------------------------------------------------------
.do_ls:
                ; Find args via KLIB_STRLEN: XY0 lands at the word's nul.
                LEA     XY0, XY2
                CALL24  KLIB_STRLEN
                INC     XY0, #1                 ; step past nul

                ; Skip leading whitespace.
.ls_skip_ws:
                LOADB   D0, [XY0]
                CMP     D0, #CH_SPACE
                BEQ     .ls_advance_ws
                BRA     .ls_check_arg
.ls_advance_ws:
                INC     XY0, #1
                BRA     .ls_skip_ws

.ls_check_arg:
                LOADB   D0, [XY0]
                CMP     D0, #0
                BEQ     .ls_default

                ; Arg present. Split into drive + basename pattern. This
                ; accepts "B:", "B:*.TXT", "*.TXT" (bare pattern -> CWD drive),
                ; etc. Drive letter is validated A..F inside the helper.
                CALL16  _KoshSplitDrivePat      ; D0=drive, XY1=basename ptr
                BCS     .ls_usage               ; bad drive letter

                MOVE    D2, D0                  ; D2 = drive index
                ; Is the basename empty (arg was just "X:")? If so, match all.
                LOADB   D0, [XY1]
                CMP     D0, #0
                BNE.S   .ls_pat_explicit
                ; Empty basename -> pattern "*".
                MOVE    Y0, Y3
                LOADI   X0, #ls_star_pat
                STOREP  X0, Y3, [#LS_PAT_PTR]
                BRA     .ls_have_drive
.ls_pat_explicit:
                ; Pattern = basename pointer (XY1).
                MOVE    D0, X1
                STOREP  D0, Y3, [#LS_PAT_PTR]
                BRA     .ls_have_drive

.ls_default:
                ; No arg: default to current working drive, match-all pattern.
                MOVE    Y0, Y3
                LOADI   X0, #KOSH_CWD
                LOADB   D0, [XY0]
                SUB     D0, #'A'                ; D0 = drive index 0..5
                MOVE    D2, D0
                MOVE    Y0, Y3
                LOADI   X0, #ls_star_pat
                STOREP  X0, Y3, [#LS_PAT_PTR]

.ls_have_drive:
                ; --- Print header: "<DRV>: <LABEL>\n" ---------------------
                ; D2 = drive index (0..5).
                ;
                ; Compute slot offset = VOL_TABLE_BASE + drive*VOL_SLOT_SIZE
                ; in D3. VOL_SLOT_SIZE = 64. Cheaper than x64 via 6 SHL: do
                ; x16 via SHL4 then x4 via two SHLs (3 instructions, 9 cyc
                ; vs 6 instructions, 18 cyc).
                MOVE    D3, D2
                SHL4    D3                      ; x16
                SHL     D3                      ; x32
                SHL     D3                      ; x64
                ADD     D3, #VOL_TABLE_BASE     ; D3 = slot offset
                MOVE    Y1, Y3
                LOADI   X1, #ROW_BUF

                ; "  " (2-space indent - matches vol/disks/task layout)
                LOADI   D0, #CH_SPACE
                CALL16  _KoshEmitByte
                LOADI   D0, #CH_SPACE
                CALL16  _KoshEmitByte

                MOVE    D0, D2
                ADD     D0, #'A'                ; drive index -> letter
                CALL16  _KoshEmitByte
                LOADI   D0, #':'
                CALL16  _KoshEmitByte
                LOADI   D0, #CH_SPACE
                CALL16  _KoshEmitByte

                ; Copy 11-byte VOL_LABEL from kernel slot.
                LOADI   Y0, #$00
                MOVE    X0, D3
                ADD     X0, #VOL_LABEL
                LOADI   D1, #11
.ls_hdr_lbl_loop:
                LOADB   D0, [XY0]
                STOREB  D0, [XY1]
                INC     XY0, #1
                INC     XY1, #1
                SUB     D1, #1
                BNE     .ls_hdr_lbl_loop

                LOADI   D0, #CH_LF
                CALL16  _KoshEmitByte
                LOADI   D0, #0
                CALL16  _KoshEmitByte

                MOVE    Y0, Y3
                LOADI   X0, #ROW_BUF
                TRAP    #TRAP_PUTS

                ; --- Walk directory via sys_dirent ------------------------
                ; D2 = drive (preserved across loop via LS_DRIVE_TMP)
                ; D3 = index (preserved across loop via LS_INDEX_TMP)
                ;
                ; r18: stash D2/D3 in zero-page slots before any _KoshEmit*
                ; helper call that would clobber them. _KoshEmitDec clobbers
                ; D1/D2/D3 (it pushes XY0/D1/D2/D3 internally but is called
                ; from a context that needs them preserved); _KoshEmitNamePadded
                ; takes its width arg in D2.
                ;
                ; Earlier ls "worked" because the D2/D3 corruption happened
                ; AFTER processing the first file's row, then the next sys_dirent
                ; got bogus drive/index, returned ERR_BADDRIVE - and ls treated
                ; any error as "end of dir" (silent stop). Diagnostic in r18
                ; revealed it: index jumped 0->2 and second call returned $FFDF.
                LOADI   D0, #0
                STOREP  D0, Y3, [#LS_FILE_COUNT]
                STOREP  D0, Y3, [#LS_TOTAL_LO]
                STOREP  D0, Y3, [#LS_TOTAL_HI]

                STOREP  D2, Y3, [#LS_DRIVE_TMP]
                LOADI   D3, #0                  ; D3 = index
                STOREP  D3, Y3, [#LS_INDEX_TMP]

.ls_loop:
                ; Re-load drive + index (might have been clobbered last iter
                ; by the row-build helpers).
                LOADP   D0, Y3, [#LS_DRIVE_TMP]
                LOADP   D1, Y3, [#LS_INDEX_TMP]
                MOVE    Y0, Y3
                LOADI   X0, #LS_DIRENT_BUF
                TRAP    #TRAP_DIRENT
                BCS     .ls_done

                ; --- Wildcard filter (Part 37) ---------------------------
                LOADP   D0, Y3, [#LS_PAT_PTR]
                MOVE    Y0, Y3
                MOVE    X0, D0                  ; XY0 = pattern
                MOVE    Y1, Y3
                LOADI   X1, #LS_DIRENT_BUF      ; XY1 = name
                CALL16  _KoshFnMatch
                BCS     .ls_skip                ; no match -> skip entry

                ; Build row in ROW_BUF.
                MOVE    Y1, Y3
                LOADI   X1, #ROW_BUF

                ; "  " (2-space indent - matches vol/disks/task layout)
                LOADI   D0, #CH_SPACE
                CALL16  _KoshEmitByte
                LOADI   D0, #CH_SPACE
                CALL16  _KoshEmitByte

                ; Emit display name padded to 12 columns.
                MOVE    Y0, Y3
                LOADI   X0, #LS_DIRENT_BUF
                LOADI   D2, #12                 ; field width
                CALL16  _KoshEmitNamePadded

                ; Two-space separator.
                LOADI   D0, #CH_SPACE
                CALL16  _KoshEmitByte
                CALL16  _KoshEmitByte

                ; Size: read 32-bit field at LS_DIRENT_BUF+$10 (low) and
                ; LS_DIRENT_BUF+$12 (high).
                ;
                ; Print rules (per file):
                ;   Always show the low 16 bits as decimal if the file fits;
                ;   otherwise print "BIG". (Existing behaviour - unchanged.)
                ;
                ; Tally rules (Part 22):
                ;   ALWAYS accumulate the full 32-bit size into LS_TOTAL_LO/HI,
                ;   regardless of whether we printed "BIG" for the individual
                ;   row. The footer print at the end handles the bytes-vs-KB
                ;   decision based on the 32-bit total.
                MOVE    Y0, Y3
                LOADI   X0, #LS_DIRENT_BUF+$10
                LOADD   D2, [XY0]               ; D2 = size_lo
                LOADI   X0, #LS_DIRENT_BUF+$12
                LOADD   D3, [XY0]               ; D3 = size_hi

                ; --- 32-bit accumulate: total += (D3:D2) ------------------
                LOADP   D0, Y3, [#LS_TOTAL_LO]
                LOADP   D1, Y3, [#LS_TOTAL_HI]
                ADD     D0, D2                  ; lo += size_lo, sets C
                ADC     D1, D3                  ; hi += size_hi + C
                STOREP  D0, Y3, [#LS_TOTAL_LO]
                STOREP  D1, Y3, [#LS_TOTAL_HI]

                ; --- Per-row print: decide BIG vs decimal -----------------
                CMP     D3, #0
                BNE     .ls_size_big

                ; Low-word fits in 16 bits - print as decimal.
                ; D2 holds size_lo; _KoshEmitDec wants D0.
                MOVE    D0, D2
                CALL16  _KoshEmitDec
                BRA     .ls_after_size

.ls_size_big:
                LOADI   D0, #'B'
                CALL16  _KoshEmitByte
                LOADI   D0, #'I'
                CALL16  _KoshEmitByte
                LOADI   D0, #'G'
                CALL16  _KoshEmitByte

.ls_after_size:
                LOADI   D0, #CH_LF
                CALL16  _KoshEmitByte
                LOADI   D0, #0
                CALL16  _KoshEmitByte

                MOVE    Y0, Y3
                LOADI   X0, #ROW_BUF
                TRAP    #TRAP_PUTS

                ; Tally and advance.
                LOADP   D0, Y3, [#LS_FILE_COUNT]
                ADD     D0, #1
                STOREP  D0, Y3, [#LS_FILE_COUNT]

                LOADP   D0, Y3, [#LS_INDEX_TMP]
                ADD     D0, #1
                STOREP  D0, Y3, [#LS_INDEX_TMP]
                BRA     .ls_loop

.ls_skip:
                ; Non-matching entry: advance index only (no row, no tally).
                LOADP   D0, Y3, [#LS_INDEX_TMP]
                ADD     D0, #1
                STOREP  D0, Y3, [#LS_INDEX_TMP]
                BRA     .ls_loop

.ls_done:
                ; --- Footer: "<n> file(s), <total> bytes\n"  or
                ;             "<n> file(s), <total> KB\n"     or
                ;             "<n> file(s), BIG\n"
                ;
                ; Rule: if HI=0 and LO < $10000, print bytes (always true
                ; when HI=0). If HI != 0, divide (HI:LO) by 1024 and print KB.
                ; If KB total still exceeds 16 bits (>= 64 MB), print "BIG".
                MOVE    Y1, Y3
                LOADI   X1, #ROW_BUF

                ; "  " (2-space indent - matches vol/disks/task layout)
                LOADI   D0, #CH_SPACE
                CALL16  _KoshEmitByte
                LOADI   D0, #CH_SPACE
                CALL16  _KoshEmitByte

                LOADP   D0, Y3, [#LS_FILE_COUNT]
                CALL16  _KoshEmitDec

                MOVE    Y0, Y3
                LOADI   X0, #msg_ls_files
                CALL16  _KoshEmitStrZ

                ; --- Used size: human-readable via _KoshEmitSize (Part 34) ---
                ; Pre-r19 this branched into bytes/KB/BIG paths with a 32-bit
                ; shift-divide; _KoshEmitSize now picks the unit and handles
                ; sizes up to GB cleanly. Width=0 = raw (no padding, no
                ; clipping).
                LOADP   D0, Y3, [#LS_TOTAL_LO]
                LOADP   D1, Y3, [#LS_TOTAL_HI]
                LOADI   D2, #0                  ; raw mode
                CALL16  _KoshEmitSize

                MOVE    Y0, Y3
                LOADI   X0, #msg_ls_used
                CALL16  _KoshEmitStrZ

                ; --- Free size on the listed drive (Part 34) ------------------
                ; sys_diskfree(D0=drive) -> D0=free_clusters, D1=total_clusters,
                ; D2=cluster_size_bytes. Compute free_bytes = free*cluster_sz.
                LOADP   D0, Y3, [#LS_DRIVE_TMP]
                TRAP    #TRAP_DISKFREE
                BCS.S   .ls_skip_free

                ; D0 = free clusters; D2 = cluster_sz. KLIB_MUL takes D0,D1
                ; -> D1:D0 product. Move cluster_sz into D1.
                MOVE    D1, D2
                CALL24  KLIB_MUL16x16_32        ; D1:D0 = free bytes
                LOADI   D2, #0                  ; raw
                CALL16  _KoshEmitSize

                MOVE    Y0, Y3
                LOADI   X0, #msg_ls_free
                CALL16  _KoshEmitStrZ
                BRA.S   .ls_emit_row

.ls_skip_free:
                ; sys_diskfree failed - shouldn't happen (we just walked the
                ; directory, so the volume is mounted). Close the line with
                ; a bare LF and skip the free figure.
                LOADI   D0, #CH_LF
                CALL16  _KoshEmitByte

.ls_emit_row:
                LOADI   D0, #0
                CALL16  _KoshEmitByte

                MOVE    Y0, Y3
                LOADI   X0, #ROW_BUF
                TRAP    #TRAP_PUTS

                BRA     .repl_loop

.ls_usage:
                MOVE    Y0, Y3
                LOADI   X0, #msg_ls_usage
                TRAP    #TRAP_PUTS
                BRA     .repl_loop


; ----------------------------------------------------------------------------
; .do_cat - print file contents to stdout.
;
;   Args: path (e.g. "B:HELLO.TXT" or "A:README.MD")
;
;   sys_open(READ) -> loop sys_read into CAT_BUF (512) -> sys_puts -> sys_close.
;
;   sys_puts requires a nul terminator: we write 0 at CAT_BUF[bytes_read]
;   after each sys_read. CAT_BUF has 513 bytes reserved (512 data + 1
;   for the terminator at end-of-buffer).
; ----------------------------------------------------------------------------
.do_cat:
                ; Find args via KLIB_STRLEN.
                LEA     XY0, XY2
                CALL24  KLIB_STRLEN
                INC     XY0, #1                 ; step past nul

                ; Skip leading whitespace.
.cat_skip_ws:
                LOADB   D0, [XY0]
                CMP     D0, #CH_SPACE
                BEQ     .cat_advance_ws
                BRA     .cat_check_path
.cat_advance_ws:
                INC     XY0, #1
                BRA     .cat_skip_ws

.cat_check_path:
                LOADB   D0, [XY0]
                CMP     D0, #0
                BEQ     .cat_usage

                ; Wildcard present?
                LEA     XY1, XY0                ; stash arg start
                CALL16  _KoshHasWildcard
                LEA     XY0, XY1                ; restore arg start
                BCC     .cat_glob               ; C=0 -> has wildcard

                ; --- Literal path (no wildcard) ------------------------------
                MOVE    Y1, Y3
                LOADI   X1, #KOSH_NORM_A
                CALL16  _KoshNormPath
                MOVE    Y0, Y1
                MOVE    X0, X1
                CALL16  _KoshCatOne
                BCS     .cat_literal_err
                BRA     .repl_loop

.cat_literal_err:
                ; D0 = err code. _KoshCatOne already closed any open fd.
                MOVE    Y0, Y3
                LOADI   X0, #msg_cat_openerr
                CALL16  _KoshPrintErr
                BRA     .repl_loop

; --- Glob path -------------------------------------------------------------
; cat each matching file's contents in directory order (continue-on-error).
.cat_glob:
                CALL16  _KoshSplitDrivePat      ; D0=drive, XY1=basename pattern
                BCS     .cat_glob_baddrv

                STOREP  D0, Y3, [#GLOB_DRIVE]

                ; root_entries from volume slot (kernel page $00).
                MOVE    D2, D0
                SHL4    D2
                SHL     D2
                SHL     D2                      ; *64
                ADD     D2, #VOL_TABLE_BASE
                LOADI   Y0, #$00
                MOVE    X0, D2
                ADD     X0, #VOL_ROOT_ENTRIES
                LOADD   D2, [XY0]               ; D2 = root_entries

                ; Reserve stack table: root_entries * 14.
                MOVE    D3, D2
                SHL     D3
                MOVE    D0, D3                  ; *2
                SHL     D3
                ADD     D0, D3                  ; *6
                SHL     D3
                ADD     D0, D3                  ; *14
                STOREP  D0, Y3, [#GLOB_RSVSIZE]
                SUB     X3, D0
                MOVE    D0, X3
                STOREP  D0, Y3, [#GLOB_TABLE]

                ; Expand.
                LOADP   D0, Y3, [#GLOB_DRIVE]
                CALL16  _KoshGlobExpand
                BCS     .cat_glob_toomany       ; truncated -> refuse batch

                CMP     D0, #0
                BEQ     .cat_glob_nomatch

                STOREP  D0, Y3, [#GLOB_COUNT]
                LOADI   D0, #0
                STOREP  D0, Y3, [#GLOB_INDEX]

.cat_glob_iter:
                LOADP   D0, Y3, [#GLOB_INDEX]
                LOADP   D1, Y3, [#GLOB_COUNT]
                CMP     D0, D1
                BHS     .cat_glob_release

                ; Build "<DRV>:<name>" in KOSH_NORM_A (name = GLOB_TABLE + idx*14).
                MOVE    D2, D0
                SHL     D0
                MOVE    D3, D0
                SHL     D0
                ADD     D3, D0                  ; *6
                SHL     D0
                ADD     D3, D0                  ; *14
                LOADP   D0, Y3, [#GLOB_TABLE]
                ADD     D3, D0                  ; D3 = name source offset

                MOVE    Y1, Y3
                LOADI   X1, #KOSH_NORM_A
                LOADP   D0, Y3, [#GLOB_DRIVE]
                ADD     D0, #'A'
                STOREB  D0, [XY1]
                INC     XY1, #1
                LOADI   D0, #':'
                STOREB  D0, [XY1]
                INC     XY1, #1
                MOVE    Y0, Y3
                MOVE    X0, D3
.cat_glob_namecpy:
                LOADB   D0, [XY0]
                STOREB  D0, [XY1]
                CMP     D0, #0
                BEQ.S   .cat_glob_namedone
                INC     XY0, #1
                INC     XY1, #1
                BRA     .cat_glob_namecpy
.cat_glob_namedone:
                ; cat this file.
                MOVE    Y0, Y3
                LOADI   X0, #KOSH_NORM_A
                CALL16  _KoshCatOne
                BCC     .cat_glob_advance

                ; Per-item error (continue): print "<path> <err>".
                PUSH    D0, XY3
                MOVE    Y0, Y3
                LOADI   X0, #KOSH_NORM_A
                TRAP    #TRAP_PUTS
                LOADI   D0, #CH_SPACE
                TRAP    #TRAP_PUTCHAR
                POP     D0, XY3
                MOVE    Y0, Y3
                LOADI   X0, #msg_cat_openerr
                CALL16  _KoshPrintErr

.cat_glob_advance:
                LOADP   D0, Y3, [#GLOB_INDEX]
                ADD     D0, #1
                STOREP  D0, Y3, [#GLOB_INDEX]
                BRA     .cat_glob_iter

.cat_glob_release:
                LOADP   D0, Y3, [#GLOB_RSVSIZE]
                ADD     X3, D0
                BRA     .repl_loop

.cat_glob_baddrv:
                MOVE    Y0, Y3
                LOADI   X0, #msg_glob_drivewild
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.cat_glob_nomatch:
                LOADP   D0, Y3, [#GLOB_RSVSIZE]
                ADD     X3, D0
                MOVE    Y0, Y3
                LOADI   X0, #msg_glob_nomatch
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.cat_glob_toomany:
                LOADP   D0, Y3, [#GLOB_RSVSIZE]
                ADD     X3, D0
                MOVE    Y0, Y3
                LOADI   X0, #msg_glob_toomany
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.cat_usage:
                MOVE    Y0, Y3
                LOADI   X0, #msg_cat_usage
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

; ----------------------------------------------------------------------------
; _KoshCatOne - stream one file's contents to stdout.
;
;   In:   XY0 = literal path (ASCIIZ, "X:NAME"; task page)
;   Out:  C = 0 OK / C = 1 error (D0 = err code; any open fd already closed)
;   Clobbers: D0, D1, D2, D3, XY0, XY1
;   Preserves: XY3
;
;   sys_open(READ) -> loop sys_read into CAT_BUF -> sys_puts -> sys_close.
;   Shared by the literal and glob cat paths. On read error, closes the fd
;   before returning so no descriptor leaks across the glob iteration.
; ----------------------------------------------------------------------------
_KoshCatOne:
                ; sys_open(path=XY0, flags=READ).
                LOADI   D0, #FOPEN_READ
                TRAP    #TRAP_OPEN
                BCS     .c1_open_err

                MOVE    D2, D0                  ; D2 = fd

.c1_read_loop:
                MOVE    D0, D2
                LOADI   D1, #CAT_BUF_SIZE
                MOVE    Y0, Y3
                LOADI   X0, #CAT_BUF
                TRAP    #TRAP_READ
                BCS     .c1_read_err

                CMP     D0, #0
                BEQ     .c1_eof

                ; Nul-terminate at CAT_BUF[bytes] for sys_puts.
                MOVE    Y0, Y3
                LOADI   X0, #CAT_BUF
                ADD     X0, D0
                LOADI   D1, #0
                STOREB  D1, [XY0]

                MOVE    Y0, Y3
                LOADI   X0, #CAT_BUF
                TRAP    #TRAP_PUTS
                BRA     .c1_read_loop

.c1_eof:
                MOVE    D0, D2
                TRAP    #TRAP_CLOSE
                CLC
                RET

.c1_read_err:
                ; D0 = err. Close fd (D2) then return error in D0.
                MOVE    D3, D0
                MOVE    D0, D2
                TRAP    #TRAP_CLOSE
                MOVE    D0, D3
                SEC
                RET

.c1_open_err:
                ; D0 = err. No fd to close.
                SEC
                RET


; ----------------------------------------------------------------------------
; .do_format - format a writable volume.
;
;   Args: drive letter ("B"/"B:"/"C"/"C:"/.../"F:"; A: rejected as r/o)
;         optional volume label (<=11 chars; default "USERDATA")
;
;   Wraps TRAP_FORMAT (TRAP #32). The label buffer is built in
;   kosh_format_label (an in-page writable buffer initially containing
;   "USERDATA   ", overwritten on each invocation):
;     • If the user provides a label, it's copied in, uppercased,
;       right-padded with spaces to 11 chars, truncated at 11.
;     • If no label, "USERDATA   " is rebuilt fresh (no carry-over
;       from a previous invocation in this session).
;
;   No [y/N] confirmation in v1 - kosh is a dev shell and `format` is
;   not a likely typo target. Adding a confirm step is one sys_gets
;   call when we want it.
;
;   Output:
;     OK             - on success (slot remounted)
;     format: bad drive    - on A: or other letter
;     format: missing drive - on no arg
;     format: failed $XXXX  - on TRAP error
;
;   Part 24: drive set widened from B-only to B + C..F. _FormatVolume
;   queries the controller (CMD_IDENT) for host-disk sector counts.
; ----------------------------------------------------------------------------
.do_format:
                ; Find args via KLIB_STRLEN.
                LEA     XY0, XY2
                CALL24  KLIB_STRLEN
                INC     XY0, #1                 ; step past nul

                ; Skip leading whitespace.
.format_skip_ws:
                LOADB   D0, [XY0]
                CMP     D0, #CH_SPACE
                BNE.S   .format_check_arg
                INC     XY0, #1
                BRA     .format_skip_ws

.format_check_arg:
                ; Must have at least one non-nul byte.
                CMP     D0, #0
                BEQ     .format_no_arg

                ; Normalise drive letter to upper case.
                ; Lowercase b..f -> B..F.
                CMP     D0, #'a'
                BLO.S   .format_no_lc
                CMP     D0, #$67                ; 'f'+1
                BHS.S   .format_no_lc
                SUB     D0, #$20
.format_no_lc:
                ; Range: 'B'..'F'. A: rejected here as read-only -
                ; _FormatVolume itself rejects too, but we get a clearer
                ; message by catching it up front.
                CMP     D0, #'A'
                BEQ     .format_bad_drive
                CMP     D0, #'B'
                BLO     .format_bad_drive
                CMP     D0, #$47                ; 'F'+1
                BHS     .format_bad_drive

                ; Convert letter to drive index. D0 = letter - 'A'.
                SUB     D0, #'A'

                ; Stash drive in D2 (preserved across CALL24s; D0 needed
                ; for label-build below).
                MOVE    D2, D0

                ; Step past the drive letter; skip optional ':'.
                INC     XY0, #1
                LOADB   D0, [XY0]
                CMP     D0, #':'
                BNE.S   .format_after_colon
                INC     XY0, #1
.format_after_colon:

                ; Skip whitespace before the optional label.
.format_skip_ws2:
                LOADB   D0, [XY0]
                CMP     D0, #CH_SPACE
                BNE.S   .format_label_start
                INC     XY0, #1
                BRA     .format_skip_ws2

.format_label_start:
                ; XY0 now points at first non-space char of label, or nul.
                ; Build the 11-byte label at kosh_format_label (in-page,
                ; writable post-spawn). Also set kosh_format_custom = 0/1
                ; to drive the post-format _HostRename step. Strategy:
                ;   • If [XY0] = 0, write the default "USERDATA   " fresh.
                ;     Set kosh_format_custom = 0 - no rename.
                ;   • Else copy up to 11 chars (uppercased, must be
                ;     [A-Z0-9_]), then space-pad. Set custom = 1.
                CMP     D0, #0
                BEQ     .format_default_label

                ; --- Custom label: copy up to 11 chars from XY0, uppercase,
                ; reject invalid chars, then space-pad the rest of the 11.
                MOVE    Y1, Y3
                LOADI   X1, #kosh_format_label
                LOADI   D1, #11                 ; D1 = remaining label cols

.format_lbl_copy:
                CMP     D1, #0
                BEQ     .format_lbl_done
                LOADB   D0, [XY0]
                CMP     D0, #0
                BEQ     .format_lbl_pad
                CMP     D0, #CH_SPACE           ; trailing space ends label
                BEQ     .format_lbl_pad
                ; Uppercase a..z -> A..Z.
                CMP     D0, #'a'
                BLO.S   .format_lbl_no_lc
                CMP     D0, #$7B                ; 'z'+1
                BHS.S   .format_lbl_no_lc
                SUB     D0, #$20
.format_lbl_no_lc:
                ; Validate: A..Z, 0..9, or underscore. Anything else
                ; means we can't rename the host file, so reject upfront
                ; rather than format-with-half-sync.
                CMP     D0, #'_'
                BEQ.S   .format_lbl_ok_char
                CMP     D0, #'0'
                BLO     .format_bad_label
                CMP     D0, #$3A                ; '9'+1
                BLO.S   .format_lbl_ok_char
                CMP     D0, #'A'
                BLO     .format_bad_label
                CMP     D0, #$5B                ; 'Z'+1
                BHS     .format_bad_label
.format_lbl_ok_char:
                STOREB  D0, [XY1]
                INC     XY0, #1
                INC     XY1, #1
                SUB     D1, #1
                BRA     .format_lbl_copy

.format_lbl_pad:
                ; Source ended; space-pad remaining cols.
                CMP     D1, #0
                BEQ     .format_lbl_done
                LOADI   D0, #' '
                STOREB  D0, [XY1]
                INC     XY1, #1
                SUB     D1, #1
                BRA     .format_lbl_pad

.format_lbl_done:
                ; Custom label path -> set custom flag = 1.
                MOVE    Y1, Y3
                LOADI   X1, #kosh_format_custom
                LOADI   D0, #1
                STOREB  D0, [XY1]
                BRA     .format_issue

.format_default_label:
                ; --- No user label given. Part 24 r2: default the label
                ; to the host filename (so disks/vol stay in sync without
                ; an explicit rename step). Steps:
                ;   1. If drive is B:, write "USERDATA   " - no host file.
                ;   2. Else call _HostBayName(bay) -> writes ASCIIZ basename
                ;      into kosh_format_label. Space-pad to 11 chars.
                ;   3. If _HostBayName fails (e.g. empty bay), fall back
                ;      to USERDATA.
                ;
                ; Clear custom flag regardless - no rename needed since
                ; the BPB label is already by construction equal to the
                ; host filename.
                MOVE    Y1, Y3
                LOADI   X1, #kosh_format_custom
                LOADI   D0, #0
                STOREB  D0, [XY1]

                ; B:? Skip the bayname query.
                CMP     D2, #FS_DRIVE_B
                BEQ     .format_userdata_label

                ; C..F - query the bayname into kosh_format_label.
                ; _HostBayName clobbers D2; save drive across the call.
                PUSH    D2, XY3                 ; save drive
                MOVE    D0, D2                  ; D0 = drive
                SUB     D0, #FS_DRIVE_C         ; D0 = bay 0..3
                MOVE    Y0, Y3
                LOADI   X0, #kosh_format_label
                CALL24  EMULIB_HOST_BAYNAME
                POP     D2, XY3                 ; restore drive
                BCS     .format_userdata_label  ; query failed -> USERDATA

                ; Buffer now holds ASCIIZ basename. Walk to the nul,
                ; then space-pad up to 11 chars total. D1 = chars seen.
                MOVE    Y1, Y3
                LOADI   X1, #kosh_format_label
                LOADI   D1, #0
.format_bn_find_nul:
                CMP     D1, #11
                BHS.S   .format_bn_clip
                LOADB   D0, [XY1]
                CMP     D0, #0
                BEQ.S   .format_bn_pad
                INC     XY1, #1
                ADD     D1, #1
                BRA     .format_bn_find_nul
.format_bn_clip:
                ; Name was ≥ 11 chars; no padding needed. The first 11
                ; bytes are already the label (uppercased by EMU).
                BRA     .format_issue
.format_bn_pad:
                ; XY1 is at the nul; pad with spaces up to byte 10
                ; (so total = 11 bytes label).
                CMP     D1, #11
                BHS.S   .format_issue_from_pad
                LOADI   D0, #' '
                STOREB  D0, [XY1]
                INC     XY1, #1
                ADD     D1, #1
                BRA     .format_bn_pad
.format_issue_from_pad:
                BRA     .format_issue

.format_userdata_label:
                ; --- Fall-back: rebuild "USERDATA   " in case a previous
                ; invocation left something else there.
                MOVE    Y1, Y3
                LOADI   X1, #kosh_format_label
                LOADI   D0, #'U'
                STOREB  D0, [XY1]
                INC     XY1, #1
                LOADI   D0, #'S'
                STOREB  D0, [XY1]
                INC     XY1, #1
                LOADI   D0, #'E'
                STOREB  D0, [XY1]
                INC     XY1, #1
                LOADI   D0, #'R'
                STOREB  D0, [XY1]
                INC     XY1, #1
                LOADI   D0, #'D'
                STOREB  D0, [XY1]
                INC     XY1, #1
                LOADI   D0, #'A'
                STOREB  D0, [XY1]
                INC     XY1, #1
                LOADI   D0, #'T'
                STOREB  D0, [XY1]
                INC     XY1, #1
                LOADI   D0, #'A'
                STOREB  D0, [XY1]
                INC     XY1, #1
                LOADI   D0, #' '
                STOREB  D0, [XY1]
                INC     XY1, #1
                STOREB  D0, [XY1]
                INC     XY1, #1
                STOREB  D0, [XY1]

.format_issue:
                ; Issue the TRAP. D0 = drive index (saved in D2);
                ; XY0 = page-local label.
                MOVE    D0, D2                  ; drive
                MOVE    Y0, Y3
                LOADI   X0, #kosh_format_label
                TRAP    #TRAP_FORMAT
                BCS     .fmt_failed

                ; --- Post-format: rename host file if custom label given ---
                ; Read kosh_format_custom. If 0, just print OK.
                MOVE    Y1, Y3
                LOADI   X1, #kosh_format_custom
                LOADB   D0, [XY1]
                CMP     D0, #0
                BEQ     .format_print_ok

                ; Custom label: nul-terminate kosh_format_label by walking
                ; back from byte 10 to find the last non-space. Then call
                ; _HostRename. Drive index still in D2 (preserved).
                MOVE    Y1, Y3
                LOADI   X1, #kosh_format_label + 10
                LOADI   D1, #11                 ; max chars to scan
.format_trim_loop:
                LOADB   D0, [XY1]
                CMP     D0, #' '
                BNE.S   .format_trim_done
                SUB     X1, #1
                SUB     D1, #1
                BNE     .format_trim_loop
                ; All spaces - shouldn't happen since custom flag implies
                ; at least one non-space char. Fall through.
.format_trim_done:
                ; XY1 currently points at last non-space char. Write nul
                ; at XY1+1.
                INC     XY1, #1
                LOADI   D0, #0
                STOREB  D0, [XY1]

                ; Call _HostRename. D0 = bay = drive - FS_DRIVE_C.
                MOVE    D0, D2                  ; D0 = drive
                SUB     D0, #FS_DRIVE_C         ; D0 = bay 0..3
                MOVE    Y0, Y3
                LOADI   X0, #kosh_format_label
                CALL24  EMULIB_HOST_RENAME
                BCS     .format_rename_warn

.format_print_ok:
                ; Success. Print "OK\n".
                MOVE    Y0, Y3
                LOADI   X0, #msg_format_ok
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.format_rename_warn:
                ; Format succeeded but rename failed (name conflict, IO).
                ; Tell the user - disk is formatted but host filename is
                ; out of sync with the label.
                MOVE    Y0, Y3
                LOADI   X0, #msg_format_rename_warn
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.format_bad_label:
                MOVE    Y0, Y3
                LOADI   X0, #msg_format_badlabel
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.format_no_arg:
                MOVE    Y0, Y3
                LOADI   X0, #msg_format_usage
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.format_bad_drive:
                MOVE    Y0, Y3
                LOADI   X0, #msg_format_baddrv
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.fmt_failed:
                ; D0 = ERR_*. _KoshPrintErr handles all the formatting:
                ;   "format: failed [ERR_NAME $XXXX]\n"
                MOVE    Y0, Y3
                LOADI   X0, #msg_format_failed
                CALL16  _KoshPrintErr
                BRA     .repl_loop


; ----------------------------------------------------------------------------
; .do_run - run a .COM file and block until it exits.
;
;   Args: path to .COM file ("A:HELLO.COM" or "B:NEW.COM").
;
;   Pure composition of TRAP_EXEC + TRAP_WAIT. sys_exec validates the
;   path itself (_ParsePath inside) so we don't pre-flight here - just
;   pass the args ptr straight through.
;
;   sys_exec returns the new child's TID; sys_wait blocks until that
;   child becomes TS_DEAD and returns its exit code.
;
;   Output:
;     [exit N]\n              - on success (N = child's exit code)
;     run: cannot exec $XXXX  - on sys_exec failure
;     run: wait failed $XXXX  - on sys_wait failure (unreachable in
;                               practice; see note below)
;
;   sys_wait failure modes (ERR_NOTCHILD / ERR_DEADLOCK) shouldn't
;   occur here because the TID we pass is the one we just spawned and
;   no one else can have waited on it. If they do happen we print the
;   raw err code.
; ----------------------------------------------------------------------------
.do_run:
                ; Find args via KLIB_STRLEN.
                LEA     XY0, XY2
                CALL24  KLIB_STRLEN
                INC     XY0, #1                 ; step past nul

                ; Skip leading whitespace.
.run_skip_ws:
                LOADB   D0, [XY0]
                CMP     D0, #CH_SPACE
                BNE.S   .run_check_path
                INC     XY0, #1
                BRA     .run_skip_ws

.run_check_path:
                CMP     D0, #0
                BEQ     .run_usage

                ; --- Scan args for trailing '&' --------------------------
                ; XY0 = first non-space char of the path arg.
                ; Walk to end-of-string. If the last non-space byte is '&',
                ; null it out (along with any spaces between it and the
                ; path) and set D3 = 1 (background flag).
                LOADI   D3, #0                  ; bg flag = 0
                MOVE    X1, X0
                MOVE    Y1, Y0                  ; XY1 = walking cursor
.run_find_end:
                LOADB   D2, [XY1]
                CMP     D2, #0
                BEQ     .run_chk_amp
                INC     XY1, #1
                BRA     .run_find_end
.run_chk_amp:
                ; XY1 -> NUL terminator. Step back over trailing spaces.
                CMP     X1, X0
                BNE.S   .run_chk_back_ok
                CMP     Y1, Y0
                BEQ     .run_no_bg              ; collapsed to empty
.run_chk_back_ok:
                DEC     XY1, #1
                LOADB   D2, [XY1]
                CMP     D2, #CH_SPACE
                BEQ     .run_chk_amp
                ; D2 = last non-space char.
                CMP     D2, #'&'
                BNE     .run_no_bg

                ; It's an '&'. Null it, set bg flag, trim preceding spaces.
                LOADI   D2, #0
                STOREB  D2, [XY1]
                LOADI   D3, #1                  ; bg flag
.run_trim_bg:
                CMP     X1, X0
                BNE.S   .run_trim_bg_ok
                CMP     Y1, Y0
                BEQ     .run_no_bg
.run_trim_bg_ok:
                DEC     XY1, #1
                LOADB   D2, [XY1]
                CMP     D2, #CH_SPACE
                BNE     .run_no_bg
                LOADI   D2, #0
                STOREB  D2, [XY1]
                BRA     .run_trim_bg

.run_no_bg:
                ; Stash bg flag in task-local word -- survives TRAP_EXEC
                ; without the PUSH/POP D clobber issue (POP D would overwrite
                ; D2 which we use to hold the TID returned by sys_exec).
                MOVE    Y1, Y3
                LOADI   X1, #RUN_BG_TMP
                STORED  D3, [XY1]

                ; Normalise path (prepend CWD if needed).
                MOVE    Y1, Y3
                LOADI   X1, #KOSH_NORM_A
                CALL16  _KoshNormPath
                MOVE    Y0, Y1
                MOVE    X0, X1

                ; sys_exec(path=XY0, flags=0).
                ; flags bit 0 (block) is reserved/ignored in P16-P19;
                ; we still do an explicit sys_wait below in the FG case.
                LOADI   D0, #0
                TRAP    #TRAP_EXEC
                BCS     .run_exec_err

                ; D0 = child TID. Stash in D2 (safe -- no PUSH/POP coming).
                MOVE    D2, D0

                ; Re-read bg flag.
                MOVE    Y1, Y3
                LOADI   X1, #RUN_BG_TMP
                LOADD   D3, [XY1]

                CMP     D3, #0
                BNE     .run_bg_report          ; backgrounded - skip wait

                ; --- Foreground: wait for child --------------------------
                MOVE    D0, D2                  ; D0 = TID for sys_wait
                TRAP    #TRAP_WAIT
                BCS     .run_wait_err

                ; D0 = exit code. Build "[exit N]\n" in ROW_BUF.
                MOVE    D2, D0
                MOVE    Y1, Y3
                LOADI   X1, #ROW_BUF
                LOADI   D0, #'['
                CALL16  _KoshEmitByte
                MOVE    Y0, Y3
                LOADI   X0, #msg_run_exit_lbl
                CALL16  _KoshEmitStrZ
                MOVE    D0, D2
                CALL16  _KoshEmitDec
                LOADI   D0, #']'
                CALL16  _KoshEmitByte
                LOADI   D0, #CH_LF
                CALL16  _KoshEmitByte
                LOADI   D0, #0
                CALL16  _KoshEmitByte
                MOVE    Y0, Y3
                LOADI   X0, #ROW_BUF
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

                ; --- Background: print "[bg N]\n" and return -------------
.run_bg_report:
                ; D2 = TID.
                MOVE    Y1, Y3
                LOADI   X1, #ROW_BUF
                LOADI   D0, #'['
                CALL16  _KoshEmitByte
                MOVE    Y0, Y3
                LOADI   X0, #msg_run_bg_lbl
                CALL16  _KoshEmitStrZ
                MOVE    D0, D2
                CALL16  _KoshEmitDec
                LOADI   D0, #']'
                CALL16  _KoshEmitByte
                LOADI   D0, #CH_LF
                CALL16  _KoshEmitByte
                LOADI   D0, #0
                CALL16  _KoshEmitByte
                MOVE    Y0, Y3
                LOADI   X0, #ROW_BUF
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.run_usage:
                MOVE    Y0, Y3
                LOADI   X0, #msg_run_usage
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.run_exec_err:
                ; D0 = ERR_*. _KoshPrintErr emits the full line.
                MOVE    Y0, Y3
                LOADI   X0, #msg_run_execerr
                CALL16  _KoshPrintErr
                BRA     .repl_loop

.run_wait_err:
                ; D0 = ERR_NOTCHILD / ERR_DEADLOCK / similar.
                MOVE    Y0, Y3
                LOADI   X0, #msg_run_waiterr
                CALL16  _KoshPrintErr
                BRA     .repl_loop


; ----------------------------------------------------------------------------
; .do_cp - copy a file.
;
;   Args: src dst   (e.g. "cp B:HELLO.COM C:HELLO.COM")
;
;   Flow:
;     1. Parse src path; nul-terminate at trailing space; advance to dst.
;     2. Parse dst path; nul-terminate at trailing space.
;     3. Same-path check (case-insensitive). Refuse if equal.
;     4. sys_open(src, FOPEN_READ).
;     5. Pre-flight: sys_open(dst, FOPEN_READ). If success -> dst exists,
;        refuse. (No FOPEN_EXCL enforcement in P16 kernel.)
;     6. sys_open(dst, FOPEN_WRITE|CREATE|TRUNC).
;     7. Loop: sys_read(src, CP_BUF, 512) -> sys_write(dst, CP_BUF, n)
;        until read returns 0 (EOF).
;     8. sys_close both, print "OK".
;
;   Error policy on mid-copy failure: close both fds, leave partial dst
;   file in place. No sys_delete exists to clean up. Reported via
;   "cp: write error $XXXX" / "cp: short write $XXXX".
;
;   Scratch use:
;     CP_BUF              - 512 B I/O staging (kosh user page)
;     CP_SRC_FD_TMP       - src fd preserved across CALL24/TRAP boundaries
;     CP_DST_FD_TMP       - dst fd
;     CP_SRC_PATH_TMP     - src path pointer preserved across pre-flight close
;     CP_DST_PATH_TMP     - dst path pointer preserved across pre-flight close
;
;   Registers: D2 holds the src fd in the inner read/write loop (same
;   idiom as .do_cat). D3 holds bytes-read (== bytes-to-write) for the
;   short-write check.
; ----------------------------------------------------------------------------
.do_cp:
                ; Find args via KLIB_STRLEN.
                LEA     XY0, XY2
                CALL24  KLIB_STRLEN
                INC     XY0, #1                 ; step past nul

                ; --- Skip leading whitespace before src --------------------
.cp_skip_ws1:
                LOADB   D0, [XY0]
                CMP     D0, #CH_SPACE
                BNE.S   .cp_have_src
                INC     XY0, #1
                BRA     .cp_skip_ws1

.cp_have_src:
                CMP     D0, #0
                BEQ     .cp_usage

                ; XY0 = src path start. Save pointer.
                LEA     XY1, XY0
                MOVE    D0, X1
                STOREP  D0, Y3, [#CP_SRC_PATH_TMP]

                ; --- Find end of src, nul-terminate ------------------------
.cp_src_find_end:
                LOADB   D0, [XY0]
                CMP     D0, #0
                BEQ     .cp_usage               ; no dst arg
                CMP     D0, #CH_SPACE
                BEQ.S   .cp_term_src
                INC     XY0, #1
                BRA     .cp_src_find_end

.cp_term_src:
                LOADI   D0, #0
                STOREB  D0, [XY0]
                INC     XY0, #1

                ; --- Skip whitespace before dst ----------------------------
.cp_skip_ws2:
                LOADB   D0, [XY0]
                CMP     D0, #CH_SPACE
                BNE.S   .cp_have_dst
                INC     XY0, #1
                BRA     .cp_skip_ws2

.cp_have_dst:
                CMP     D0, #0
                BEQ     .cp_usage

                ; XY0 = dst path start. Save pointer.
                MOVE    D0, X0
                STOREP  D0, Y3, [#CP_DST_PATH_TMP]

                ; --- Find end of dst, nul-terminate ------------------------
.cp_dst_find_end:
                LOADB   D0, [XY0]
                CMP     D0, #0
                BEQ.S   .cp_dst_terminated
                CMP     D0, #CH_SPACE
                BNE.S   .cp_dst_advance
                LOADI   D0, #0
                STOREB  D0, [XY0]
                BRA.S   .cp_dst_terminated
.cp_dst_advance:
                INC     XY0, #1
                BRA     .cp_dst_find_end

.cp_dst_terminated:
                ; Does the SRC contain a wildcard?
                MOVE    Y0, Y3
                LOADP   D0, Y3, [#CP_SRC_PATH_TMP]
                MOVE    X0, D0
                CALL16  _KoshHasWildcard
                BCC     .cp_glob                ; C=0 -> wildcard src

                ; --- Literal path (no wildcard) - normalise both, copy one ---
                MOVE    Y0, Y3
                LOADP   D0, Y3, [#CP_SRC_PATH_TMP]
                MOVE    X0, D0
                MOVE    Y1, Y3
                LOADI   X1, #KOSH_NORM_A
                CALL16  _KoshNormPath
                LOADI   D0, #KOSH_NORM_A
                STOREP  D0, Y3, [#CP_SRC_PATH_TMP]

                MOVE    Y0, Y3
                LOADP   D0, Y3, [#CP_DST_PATH_TMP]
                MOVE    X0, D0
                MOVE    Y1, Y3
                LOADI   X1, #KOSH_NORM_B
                CALL16  _KoshNormPath
                LOADI   D0, #KOSH_NORM_B
                STOREP  D0, Y3, [#CP_DST_PATH_TMP]

                ; Part 37: bare-drive dst ("B:") -> "B:<src-basename>".
                CALL16  _KoshExpandBareDst

                CALL16  _KoshCpOne
                ; C=0 OK, C=1 error (D0=err, or special codes - see worker).
                BCS     .cp_report_err
                MOVE    Y0, Y3
                LOADI   X0, #msg_cp_ok
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.cp_report_err:
                ; D0 = err code (or sentinel). _KoshCpOne already closed fds.
                ; Distinguish the "same path" and "dst exists" sentinels so the
                ; right message prints; otherwise generic copy error.
                CMP     D0, #CP_ERR_SAMEPATH
                BEQ     .cp_same_path
                CMP     D0, #CP_ERR_EXISTS
                BEQ     .cp_exists_msg
                MOVE    Y0, Y3
                LOADI   X0, #msg_cp_writeerr
                CALL16  _KoshPrintErr
                BRA     .repl_loop

.cp_exists_msg:
                MOVE    Y0, Y3
                LOADI   X0, #msg_cp_exists
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

; --- Glob path -------------------------------------------------------------
; cp <pattern> <destdrive>: - copy each matching file to the dest drive,
; keeping its basename. Destination MUST be a bare drive (no filename, no
; wildcard). Stop-on-error policy.
.cp_glob:
                ; Validate dst: must be "X:" exactly (alpha, colon, nul).
                ; Reject dst wildcards and dst filenames.
                MOVE    Y0, Y3
                LOADP   D0, Y3, [#CP_DST_PATH_TMP]
                MOVE    X0, D0
                CALL16  _KoshHasWildcard
                BCC     .cp_glob_destwild       ; dst has wildcard -> reject

                ; Parse dst into drive + remainder; remainder must be empty.
                MOVE    Y0, Y3
                LOADP   D0, Y3, [#CP_DST_PATH_TMP]
                MOVE    X0, D0
                CALL16  _KoshSplitDrivePat      ; D0=destdrive, XY1=remainder
                BCS     .cp_glob_baddrv
                ; Remainder must be empty (bare "X:").
                LOADB   D0, [XY1]
                CMP     D0, #0
                BNE     .cp_glob_multidest      ; dst had a filename part
                ; Stash dest drive.
                LOADP   D0, Y3, [#CP_DST_PATH_TMP]  ; (re-derive drive below cleanly)
                MOVE    Y0, Y3
                LOADP   D0, Y3, [#CP_DST_PATH_TMP]
                MOVE    X0, D0
                CALL16  _KoshSplitDrivePat
                STOREP  D0, Y3, [#CP_DSTDRV_TMP]    ; dest drive index

                ; Split SRC into drive + pattern.
                MOVE    Y0, Y3
                LOADP   D0, Y3, [#CP_SRC_PATH_TMP]
                MOVE    X0, D0
                CALL16  _KoshSplitDrivePat      ; D0=srcdrive, XY1=pattern
                BCS     .cp_glob_baddrv
                STOREP  D0, Y3, [#GLOB_DRIVE]

                ; root_entries for src drive.
                MOVE    D2, D0
                SHL4    D2
                SHL     D2
                SHL     D2
                ADD     D2, #VOL_TABLE_BASE
                LOADI   Y0, #$00
                MOVE    X0, D2
                ADD     X0, #VOL_ROOT_ENTRIES
                LOADD   D2, [XY0]

                ; Reserve stack table.
                MOVE    D3, D2
                SHL     D3
                MOVE    D0, D3
                SHL     D3
                ADD     D0, D3
                SHL     D3
                ADD     D0, D3                  ; D0 = root_entries*14
                STOREP  D0, Y3, [#GLOB_RSVSIZE]
                SUB     X3, D0
                MOVE    D0, X3
                STOREP  D0, Y3, [#GLOB_TABLE]

                ; Expand src pattern.
                LOADP   D0, Y3, [#GLOB_DRIVE]
                CALL16  _KoshGlobExpand
                BCS     .cp_glob_toomany

                CMP     D0, #0
                BEQ     .cp_glob_nomatch

                STOREP  D0, Y3, [#GLOB_COUNT]
                LOADI   D0, #0
                STOREP  D0, Y3, [#GLOB_INDEX]

.cp_glob_iter:
                LOADP   D0, Y3, [#GLOB_INDEX]
                LOADP   D1, Y3, [#GLOB_COUNT]
                CMP     D0, D1
                BHS     .cp_glob_release

                ; name source offset = GLOB_TABLE + idx*14.
                MOVE    D2, D0
                SHL     D0
                MOVE    D3, D0
                SHL     D0
                ADD     D3, D0                  ; *6
                SHL     D0
                ADD     D3, D0                  ; *14
                LOADP   D0, Y3, [#GLOB_TABLE]
                ADD     D3, D0                  ; D3 = name source offset
                STOREP  D3, Y3, [#CP_NAME_TMP]      ; remember for both src and dst

                ; Build SRC path "<srcdrive>:<name>" in KOSH_NORM_A.
                MOVE    Y1, Y3
                LOADI   X1, #KOSH_NORM_A
                LOADP   D0, Y3, [#GLOB_DRIVE]
                ADD     D0, #'A'
                STOREB  D0, [XY1]
                INC     XY1, #1
                LOADI   D0, #':'
                STOREB  D0, [XY1]
                INC     XY1, #1
                LOADP   D0, Y3, [#CP_NAME_TMP]
                MOVE    Y0, Y3
                MOVE    X0, D0
.cp_glob_srccpy:
                LOADB   D0, [XY0]
                STOREB  D0, [XY1]
                CMP     D0, #0
                BEQ.S   .cp_glob_srcdone
                INC     XY0, #1
                INC     XY1, #1
                BRA     .cp_glob_srccpy
.cp_glob_srcdone:
                LOADI   D0, #KOSH_NORM_A
                STOREP  D0, Y3, [#CP_SRC_PATH_TMP]

                ; Build DST path "<dstdrive>:<name>" in KOSH_NORM_B.
                MOVE    Y1, Y3
                LOADI   X1, #KOSH_NORM_B
                LOADP   D0, Y3, [#CP_DSTDRV_TMP]
                ADD     D0, #'A'
                STOREB  D0, [XY1]
                INC     XY1, #1
                LOADI   D0, #':'
                STOREB  D0, [XY1]
                INC     XY1, #1
                LOADP   D0, Y3, [#CP_NAME_TMP]
                MOVE    Y0, Y3
                MOVE    X0, D0
.cp_glob_dstcpy:
                LOADB   D0, [XY0]
                STOREB  D0, [XY1]
                CMP     D0, #0
                BEQ.S   .cp_glob_dstdone
                INC     XY0, #1
                INC     XY1, #1
                BRA     .cp_glob_dstcpy
.cp_glob_dstdone:
                LOADI   D0, #KOSH_NORM_B
                STOREP  D0, Y3, [#CP_DST_PATH_TMP]

                ; Copy this file.
                CALL16  _KoshCpOne
                BCS     .cp_glob_item_err

                ; Success: echo "<src> -> <dst>".
                MOVE    Y0, Y3
                LOADI   X0, #KOSH_NORM_A
                TRAP    #TRAP_PUTS
                MOVE    Y0, Y3
                LOADI   X0, #msg_cp_arrow
                TRAP    #TRAP_PUTS
                MOVE    Y0, Y3
                LOADI   X0, #KOSH_NORM_B
                TRAP    #TRAP_PUTS
                LOADI   D0, #CH_LF
                TRAP    #TRAP_PUTCHAR

                LOADP   D0, Y3, [#GLOB_INDEX]
                ADD     D0, #1
                STOREP  D0, Y3, [#GLOB_INDEX]
                BRA     .cp_glob_iter

.cp_glob_item_err:
                ; Stop-on-error policy: report and abort the batch.
                ; D0 = err code (or sentinel). Release stack first.
                PUSH    D0, XY3
                LOADP   D0, Y3, [#GLOB_RSVSIZE]
                ADD     X3, D0
                POP     D0, XY3
                ; Print the failing src path then the error.
                PUSH    D0, XY3
                MOVE    Y0, Y3
                LOADI   X0, #KOSH_NORM_A
                TRAP    #TRAP_PUTS
                LOADI   D0, #CH_SPACE
                TRAP    #TRAP_PUTCHAR
                POP     D0, XY3
                CMP     D0, #CP_ERR_EXISTS
                BEQ     .cp_glob_item_exists
                CMP     D0, #CP_ERR_SAMEPATH
                BEQ     .cp_glob_item_same
                MOVE    Y0, Y3
                LOADI   X0, #msg_cp_writeerr
                CALL16  _KoshPrintErr
                BRA     .repl_loop
.cp_glob_item_exists:
                MOVE    Y0, Y3
                LOADI   X0, #msg_cp_exists
                TRAP    #TRAP_PUTS
                BRA     .repl_loop
.cp_glob_item_same:
                MOVE    Y0, Y3
                LOADI   X0, #msg_cp_samepath
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.cp_glob_release:
                LOADP   D0, Y3, [#GLOB_RSVSIZE]
                ADD     X3, D0
                BRA     .repl_loop

.cp_glob_destwild:
                MOVE    Y0, Y3
                LOADI   X0, #msg_glob_destwild
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.cp_glob_multidest:
                MOVE    Y0, Y3
                LOADI   X0, #msg_glob_multidest
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.cp_glob_baddrv:
                MOVE    Y0, Y3
                LOADI   X0, #msg_glob_drivewild
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.cp_glob_nomatch:
                LOADP   D0, Y3, [#GLOB_RSVSIZE]
                ADD     X3, D0
                MOVE    Y0, Y3
                LOADI   X0, #msg_glob_nomatch
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.cp_glob_toomany:
                LOADP   D0, Y3, [#GLOB_RSVSIZE]
                ADD     X3, D0
                MOVE    Y0, Y3
                LOADI   X0, #msg_glob_toomany
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.cp_usage:
                MOVE    Y0, Y3
                LOADI   X0, #msg_cp_usage
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.cp_same_path:
                MOVE    Y0, Y3
                LOADI   X0, #msg_cp_samepath
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

; ----------------------------------------------------------------------------
; _KoshCpOne - copy one file. src in CP_SRC_PATH_TMP, dst in CP_DST_PATH_TMP
;   (both pointers into the task page, already normalised).
;
;   Out:  C = 0 OK
;         C = 1 error, D0 = err code OR one of the sentinels:
;                 CP_ERR_SAMEPATH  src == dst (case-insensitive)
;                 CP_ERR_EXISTS    dst already exists
;   Clobbers: D0, D1, D2, D3, XY0, XY1
;   Preserves: XY3
;
;   Same-path check, pre-flight existence check, then open/copy/close.
;   All fds are closed on every exit path so none leak across a glob batch.
; ----------------------------------------------------------------------------
_KoshCpOne:
                ; --- Same-path check (case-insensitive) --------------------
                MOVE    Y0, Y3
                LOADP   D0, Y3, [#CP_SRC_PATH_TMP]
                MOVE    X0, D0
                MOVE    Y1, Y3
                LOADP   D0, Y3, [#CP_DST_PATH_TMP]
                MOVE    X1, D0
.c2_cmp_loop:
                LOADB   D0, [XY0]
                LOADB   D1, [XY1]
                CMP     D0, #'a'
                BLO.S   .c2_d0_noup
                CMP     D0, #$7B
                BHS.S   .c2_d0_noup
                SUB     D0, #$20
.c2_d0_noup:
                CMP     D1, #'a'
                BLO.S   .c2_d1_noup
                CMP     D1, #$7B
                BHS.S   .c2_d1_noup
                SUB     D1, #$20
.c2_d1_noup:
                CMP     D0, D1
                BNE.S   .c2_differ
                CMP     D0, #0
                BEQ     .c2_same
                INC     XY0, #1
                INC     XY1, #1
                BRA     .c2_cmp_loop

.c2_same:
                LOADI   D0, #CP_ERR_SAMEPATH
                SEC
                RET

.c2_differ:
                ; --- Open src for reading ----------------------------------
                MOVE    Y0, Y3
                LOADP   D0, Y3, [#CP_SRC_PATH_TMP]
                MOVE    X0, D0
                LOADI   D0, #FOPEN_READ
                TRAP    #TRAP_OPEN
                BCS     .c2_src_openerr
                STOREP  D0, Y3, [#CP_SRC_FD_TMP]

                ; --- Pre-flight: does dst already exist? -------------------
                MOVE    Y0, Y3
                LOADP   D0, Y3, [#CP_DST_PATH_TMP]
                MOVE    X0, D0
                LOADI   D0, #FOPEN_READ
                TRAP    #TRAP_OPEN
                BCS.S   .c2_dst_new             ; not found -> good
                ; Dst exists: close probe + src, return EXISTS.
                TRAP    #TRAP_CLOSE             ; D0 = probe fd
                LOADP   D0, Y3, [#CP_SRC_FD_TMP]
                TRAP    #TRAP_CLOSE
                LOADI   D0, #CP_ERR_EXISTS
                SEC
                RET

.c2_dst_new:
                ; --- Open dst for writing ----------------------------------
                MOVE    Y0, Y3
                LOADP   D0, Y3, [#CP_DST_PATH_TMP]
                MOVE    X0, D0
                LOADI   D0, #OPEN_FLAGS_NEW
                TRAP    #TRAP_OPEN
                BCS     .c2_dst_createerr
                STOREP  D0, Y3, [#CP_DST_FD_TMP]

                ; --- Copy loop ---------------------------------------------
.c2_loop:
                LOADP   D0, Y3, [#CP_SRC_FD_TMP]
                LOADI   D1, #CP_BUF_SIZE
                MOVE    Y0, Y3
                LOADI   X0, #CP_BUF
                TRAP    #TRAP_READ
                BCS     .c2_read_err
                CMP     D0, #0
                BEQ     .c2_eof
                MOVE    D3, D0                  ; D3 = bytes read

                LOADP   D0, Y3, [#CP_DST_FD_TMP]
                MOVE    D1, D3
                MOVE    Y0, Y3
                LOADI   X0, #CP_BUF
                TRAP    #TRAP_WRITE
                BCS     .c2_write_err
                CMP     D0, D3
                BNE     .c2_short
                BRA     .c2_loop

.c2_eof:
                LOADP   D0, Y3, [#CP_DST_FD_TMP]
                TRAP    #TRAP_CLOSE
                LOADP   D0, Y3, [#CP_SRC_FD_TMP]
                TRAP    #TRAP_CLOSE
                CLC
                RET

.c2_src_openerr:
                ; D0 = err. No fd open yet.
                SEC
                RET

.c2_dst_createerr:
                ; D0 = err. Close src.
                MOVE    D2, D0
                LOADP   D0, Y3, [#CP_SRC_FD_TMP]
                TRAP    #TRAP_CLOSE
                MOVE    D0, D2
                SEC
                RET

.c2_read_err:
.c2_write_err:
                MOVE    D2, D0
                LOADP   D0, Y3, [#CP_SRC_FD_TMP]
                TRAP    #TRAP_CLOSE
                LOADP   D0, Y3, [#CP_DST_FD_TMP]
                TRAP    #TRAP_CLOSE
                MOVE    D0, D2
                SEC
                RET

.c2_short:
                ; D0 = bytes written (< D3). Return it as the "code".
                MOVE    D2, D0
                LOADP   D0, Y3, [#CP_SRC_FD_TMP]
                TRAP    #TRAP_CLOSE
                LOADP   D0, Y3, [#CP_DST_FD_TMP]
                TRAP    #TRAP_CLOSE
                MOVE    D0, D2
                SEC
                RET


; ----------------------------------------------------------------------------
; .do_rm - delete a file.
;
;   Args: path   (e.g. "rm B:HELLO.COM")
;
;   Thin wrapper over TRAP_UNLINK. The kernel does the heavy lifting:
;   parses path, validates drive, walks the FAT chain, marks dirent
;   deleted. Output:
;     OK                - on success
;     rm: <message>     - usage / cannot delete (with $XXXX code)
; ----------------------------------------------------------------------------
.do_rm:
                LEA     XY0, XY2
                CALL24  KLIB_STRLEN
                INC     XY0, #1

.rm_skip_ws:
                LOADB   D0, [XY0]
                CMP     D0, #CH_SPACE
                BNE.S   .rm_have_path
                INC     XY0, #1
                BRA     .rm_skip_ws

.rm_have_path:
                CMP     D0, #0
                BEQ     .rm_usage

                ; XY0 = path arg. Wildcard present?
                ; (_KoshHasWildcard preserves XY1..XY3; advances XY0, so save it.)
                LEA     XY1, XY0                ; stash arg start in XY1
                CALL16  _KoshHasWildcard
                LEA     XY0, XY1                ; restore arg start
                BCC     .rm_glob                ; C=0 -> has wildcard

                ; --- Literal path (no wildcard) - unchanged behaviour --------
                MOVE    Y1, Y3
                LOADI   X1, #KOSH_NORM_A
                CALL16  _KoshNormPath
                MOVE    Y0, Y1
                MOVE    X0, X1
                CALL16  _KoshRmOne
                BCS     .rm_failed
                MOVE    Y0, Y3
                LOADI   X0, #msg_format_ok
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

; --- Glob path -------------------------------------------------------------
; XY0 = arg containing a wildcard. Split into drive + basename pattern,
; expand against the drive's directory onto a stack-reserved table, then
; rm each match (continue-on-error policy).
.rm_glob:
                CALL16  _KoshSplitDrivePat      ; D0=drive, XY1=basename pattern
                BCS     .rm_glob_baddrv

                ; Stash drive; copy pattern pointer for _KoshGlobExpand (XY1).
                STOREP  D0, Y3, [#GLOB_DRIVE]       ; (also re-stashed inside expander)

                ; Read root_entries from the volume slot (kernel page $00).
                ; slot = VOL_TABLE_BASE + drive*64.
                MOVE    D2, D0
                SHL4    D2                      ; *16
                SHL     D2                      ; *32
                SHL     D2                      ; *64
                ADD     D2, #VOL_TABLE_BASE
                LOADI   Y0, #$00
                MOVE    X0, D2
                ADD     X0, #VOL_ROOT_ENTRIES
                LOADD   D2, [XY0]               ; D2 = root_entries (table capacity)

                ; Reserve stack table: bytes = root_entries * 14.
                ; D2*14 = D2*8 + D2*4 + D2*2.
                MOVE    D3, D2
                SHL     D3                      ; *2
                MOVE    D0, D3                  ; D0 = *2
                SHL     D3                      ; *4
                ADD     D0, D3                  ; D0 = *2 + *4 = *6
                SHL     D3                      ; *8
                ADD     D0, D3                  ; D0 = *6 + *8 = *14
                ; Save table byte-size to release later.
                STOREP  D0, Y3, [#GLOB_RSVSIZE]
                SUB     X3, D0                  ; reserve region [X3 .. X3+size)
                ; Table base offset = current X3.
                MOVE    D0, X3
                STOREP  D0, Y3, [#GLOB_TABLE]

                ; Expand: _KoshGlobExpand(D0=drive, XY1=pattern, D2=max).
                LOADP   D0, Y3, [#GLOB_DRIVE]
                ; XY1 still = basename pattern from _KoshSplitDrivePat.
                CALL16  _KoshGlobExpand
                ; D0 = count. C=1 = truncated -> refuse whole batch (safety).
                BCS     .rm_glob_toomany

                ; D0 = count. Zero matches?
                CMP     D0, #0
                BEQ     .rm_glob_nomatch

                ; Iterate matches.
                STOREP  D0, Y3, [#GLOB_COUNT]       ; total
                LOADI   D0, #0
                STOREP  D0, Y3, [#GLOB_INDEX]       ; iterator

.rm_glob_iter:
                LOADP   D0, Y3, [#GLOB_INDEX]
                LOADP   D1, Y3, [#GLOB_COUNT]
                CMP     D0, D1
                BHS     .rm_glob_release        ; done all matches

                ; Build "<DRV>:<name>" in KOSH_NORM_A.
                ; name source = GLOB_TABLE + index*14.
                MOVE    D2, D0
                SHL     D0                      ; *2
                MOVE    D3, D0
                SHL     D0                      ; *4
                ADD     D3, D0                  ; *6
                SHL     D0                      ; *8
                ADD     D3, D0                  ; *14
                LOADP   D0, Y3, [#GLOB_TABLE]
                ADD     D3, D0                  ; D3 = name source offset

                ; Write drive letter + ':' into KOSH_NORM_A.
                MOVE    Y1, Y3
                LOADI   X1, #KOSH_NORM_A
                LOADP   D0, Y3, [#GLOB_DRIVE]
                ADD     D0, #'A'
                STOREB  D0, [XY1]
                INC     XY1, #1
                LOADI   D0, #':'
                STOREB  D0, [XY1]
                INC     XY1, #1
                ; Append name (ASCIIZ) from [Y3:D3].
                MOVE    Y0, Y3
                MOVE    X0, D3
.rm_glob_namecpy:
                LOADB   D0, [XY0]
                STOREB  D0, [XY1]
                CMP     D0, #0
                BEQ.S   .rm_glob_namedone
                INC     XY0, #1
                INC     XY1, #1
                BRA     .rm_glob_namecpy
.rm_glob_namedone:
                ; KOSH_NORM_A now holds the full path. rm it.
                MOVE    Y0, Y3
                LOADI   X0, #KOSH_NORM_A
                CALL16  _KoshRmOne
                BCC     .rm_glob_ok_one

                ; Per-item error (continue policy): print the failing path
                ; then the error, and carry on to the next match.
                PUSH    D0, XY3                 ; save err code
                MOVE    Y0, Y3
                LOADI   X0, #KOSH_NORM_A
                TRAP    #TRAP_PUTS
                LOADI   D0, #CH_SPACE
                TRAP    #TRAP_PUTCHAR
                POP     D0, XY3                 ; restore err code
                MOVE    Y0, Y3
                LOADI   X0, #msg_rm_failed
                CALL16  _KoshPrintErr
                BRA     .rm_glob_advance

.rm_glob_ok_one:
                ; Print "<path> removed" - or just the path + OK. Keep it brief:
                ; echo the path followed by newline so the user sees progress.
                MOVE    Y0, Y3
                LOADI   X0, #KOSH_NORM_A
                TRAP    #TRAP_PUTS
                MOVE    Y0, Y3
                LOADI   X0, #msg_glob_removed
                TRAP    #TRAP_PUTS

.rm_glob_advance:
                LOADP   D0, Y3, [#GLOB_INDEX]
                ADD     D0, #1
                STOREP  D0, Y3, [#GLOB_INDEX]
                BRA     .rm_glob_iter

.rm_glob_release:
                ; Release the stack table using the saved reserve size.
                LOADP   D0, Y3, [#GLOB_RSVSIZE]
                ADD     X3, D0                  ; restore SP
                BRA     .repl_loop

.rm_glob_baddrv:
                MOVE    Y0, Y3
                LOADI   X0, #msg_glob_drivewild
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.rm_glob_nomatch:
                ; Release reserved stack.
                LOADP   D0, Y3, [#GLOB_RSVSIZE]
                ADD     X3, D0
                MOVE    Y0, Y3
                LOADI   X0, #msg_glob_nomatch
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.rm_glob_toomany:
                ; Truncation: refuse the whole batch (safety). Release stack
                ; and warn.
                LOADP   D0, Y3, [#GLOB_RSVSIZE]
                ADD     X3, D0
                MOVE    Y0, Y3
                LOADI   X0, #msg_glob_toomany
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.rm_usage:
                MOVE    Y0, Y3
                LOADI   X0, #msg_rm_usage
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.rm_failed:
                ; D0 = err code. _KoshPrintErr handles the rest.
                MOVE    Y0, Y3
                LOADI   X0, #msg_rm_failed
                CALL16  _KoshPrintErr
                BRA     .repl_loop

; ----------------------------------------------------------------------------
; _KoshRmOne - delete a single file given a literal normalised path.
;
;   In:   XY0 = literal path (ASCIIZ, "X:NAME"; task page)
;   Out:  C = 0 OK / C = 1 error (D0 = err code)
;   Clobbers: per TRAP_UNLINK
;   Preserves: XY3 (and whatever TRAP_UNLINK preserves)
;
;   Thin wrapper over TRAP_UNLINK. Both the literal and glob rm paths call
;   this so deletion semantics are identical regardless of how the path
;   was produced.
; ----------------------------------------------------------------------------
_KoshRmOne:
                TRAP    #TRAP_UNLINK
                RET



; ----------------------------------------------------------------------------
; .do_mv - rename or move a file.
;
;   Args: src dst   (e.g. "mv B:OLD.TXT B:NEW.TXT" or "mv B:F.TXT C:F.TXT")
;
;   Algorithm:
;     1. Parse both paths (same idiom as cp).
;     2. TRAP_RENAME(src, dst). If success -> "OK".
;        If err = ERR_INVALID -> drives differ, fall through to cp+unlink.
;        Any other err -> report and bail.
;     3. Cross-drive fallback: open src for read, pre-flight dst, open dst
;        for create-trunc, loop read->write, close both, then TRAP_UNLINK(src).
;     4. If unlink fails after a successful copy, the file is now at both
;        locations; print a warning but don't unwind.
;
;   The CP_BUF scratch and CP_SRC_FD_TMP / CP_DST_FD_TMP slots are
;   shared with .do_cp (no concurrent use - kosh is single-task; the
;   slots are kosh-local).
;
;   Scratch additions: MV_SRC_PATH_TMP / MV_DST_PATH_TMP reuse the
;   CP_SRC_PATH_TMP / CP_DST_PATH_TMP slots - same purpose, same shape,
;   no need for new storage.
; ----------------------------------------------------------------------------
.do_mv:
                LEA     XY0, XY2
                CALL24  KLIB_STRLEN
                INC     XY0, #1

                ; --- Skip leading whitespace ------------------------------
.mv_skip_ws1:
                LOADB   D0, [XY0]
                CMP     D0, #CH_SPACE
                BNE.S   .mv_have_src
                INC     XY0, #1
                BRA     .mv_skip_ws1

.mv_have_src:
                CMP     D0, #0
                BEQ     .mv_usage

                MOVE    D0, X0
                STOREP  D0, Y3, [#CP_SRC_PATH_TMP]

.mv_src_find_end:
                LOADB   D0, [XY0]
                CMP     D0, #0
                BEQ     .mv_usage
                CMP     D0, #CH_SPACE
                BEQ.S   .mv_term_src
                INC     XY0, #1
                BRA     .mv_src_find_end

.mv_term_src:
                LOADI   D0, #0
                STOREB  D0, [XY0]
                INC     XY0, #1

.mv_skip_ws2:
                LOADB   D0, [XY0]
                CMP     D0, #CH_SPACE
                BNE.S   .mv_have_dst
                INC     XY0, #1
                BRA     .mv_skip_ws2

.mv_have_dst:
                CMP     D0, #0
                BEQ     .mv_usage

                MOVE    D0, X0
                STOREP  D0, Y3, [#CP_DST_PATH_TMP]

.mv_dst_find_end:
                LOADB   D0, [XY0]
                CMP     D0, #0
                BEQ.S   .mv_dst_terminated
                CMP     D0, #CH_SPACE
                BNE.S   .mv_dst_advance
                LOADI   D0, #0
                STOREB  D0, [XY0]
                BRA.S   .mv_dst_terminated
.mv_dst_advance:
                INC     XY0, #1
                BRA     .mv_dst_find_end

.mv_dst_terminated:
                ; Does the SRC contain a wildcard?
                MOVE    Y0, Y3
                LOADP   D0, Y3, [#CP_SRC_PATH_TMP]
                MOVE    X0, D0
                CALL16  _KoshHasWildcard
                BCC     .mv_glob                ; C=0 -> wildcard src

                ; --- Literal path - normalise both, move one ----------------
                MOVE    Y0, Y3
                LOADP   D0, Y3, [#CP_SRC_PATH_TMP]
                MOVE    X0, D0
                MOVE    Y1, Y3
                LOADI   X1, #KOSH_NORM_A
                CALL16  _KoshNormPath
                LOADI   D0, #KOSH_NORM_A
                STOREP  D0, Y3, [#CP_SRC_PATH_TMP]

                MOVE    Y0, Y3
                LOADP   D0, Y3, [#CP_DST_PATH_TMP]
                MOVE    X0, D0
                MOVE    Y1, Y3
                LOADI   X1, #KOSH_NORM_B
                CALL16  _KoshNormPath
                LOADI   D0, #KOSH_NORM_B
                STOREP  D0, Y3, [#CP_DST_PATH_TMP]

                ; Part 37: bare-drive dst ("B:") -> "B:<src-basename>".
                CALL16  _KoshExpandBareDst

                CALL16  _KoshMvOne
                BCS     .mv_report_err
                MOVE    Y0, Y3
                LOADI   X0, #msg_format_ok
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.mv_report_err:
                ; D0 = err / sentinel. _KoshMvOne already cleaned up fds.
                CMP     D0, #MV_WARN_ROSRC
                BEQ     .mv_ro_note
                CMP     D0, #CP_ERR_SAMEPATH
                BEQ     .mv_same_path
                CMP     D0, #CP_ERR_EXISTS
                BEQ     .mv_exists_msg
                MOVE    Y0, Y3
                LOADI   X0, #msg_mv_failed
                CALL16  _KoshPrintErr
                BRA     .repl_loop

.mv_ro_note:
                ; Copy succeeded; source left in place (read-only volume).
                MOVE    Y0, Y3
                LOADI   X0, #msg_mv_ro_src
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.mv_exists_msg:
                MOVE    Y0, Y3
                LOADI   X0, #msg_mv_dst_exists
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.mv_same_path:
                MOVE    Y0, Y3
                LOADI   X0, #msg_cp_samepath
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

; --- Glob path -------------------------------------------------------------
; mv <pattern> <destdrive>: - move each matching file to the dest drive,
; keeping its basename. Same dest rules as cp glob. Stop-on-error.
.mv_glob:
                MOVE    Y0, Y3
                LOADP   D0, Y3, [#CP_DST_PATH_TMP]
                MOVE    X0, D0
                CALL16  _KoshHasWildcard
                BCC     .mv_glob_destwild

                MOVE    Y0, Y3
                LOADP   D0, Y3, [#CP_DST_PATH_TMP]
                MOVE    X0, D0
                CALL16  _KoshSplitDrivePat
                BCS     .mv_glob_baddrv
                LOADB   D0, [XY1]
                CMP     D0, #0
                BNE     .mv_glob_multidest
                MOVE    Y0, Y3
                LOADP   D0, Y3, [#CP_DST_PATH_TMP]
                MOVE    X0, D0
                CALL16  _KoshSplitDrivePat
                STOREP  D0, Y3, [#CP_DSTDRV_TMP]

                MOVE    Y0, Y3
                LOADP   D0, Y3, [#CP_SRC_PATH_TMP]
                MOVE    X0, D0
                CALL16  _KoshSplitDrivePat
                BCS     .mv_glob_baddrv
                STOREP  D0, Y3, [#GLOB_DRIVE]

                MOVE    D2, D0
                SHL4    D2
                SHL     D2
                SHL     D2
                ADD     D2, #VOL_TABLE_BASE
                LOADI   Y0, #$00
                MOVE    X0, D2
                ADD     X0, #VOL_ROOT_ENTRIES
                LOADD   D2, [XY0]

                MOVE    D3, D2
                SHL     D3
                MOVE    D0, D3
                SHL     D3
                ADD     D0, D3
                SHL     D3
                ADD     D0, D3                  ; root_entries*14
                STOREP  D0, Y3, [#GLOB_RSVSIZE]
                SUB     X3, D0
                MOVE    D0, X3
                STOREP  D0, Y3, [#GLOB_TABLE]

                LOADP   D0, Y3, [#GLOB_DRIVE]
                CALL16  _KoshGlobExpand
                BCS     .mv_glob_toomany

                CMP     D0, #0
                BEQ     .mv_glob_nomatch

                STOREP  D0, Y3, [#GLOB_COUNT]
                LOADI   D0, #0
                STOREP  D0, Y3, [#GLOB_INDEX]

.mv_glob_iter:
                LOADP   D0, Y3, [#GLOB_INDEX]
                LOADP   D1, Y3, [#GLOB_COUNT]
                CMP     D0, D1
                BHS     .mv_glob_release

                MOVE    D2, D0
                SHL     D0
                MOVE    D3, D0
                SHL     D0
                ADD     D3, D0
                SHL     D0
                ADD     D3, D0                  ; idx*14
                LOADP   D0, Y3, [#GLOB_TABLE]
                ADD     D3, D0
                STOREP  D3, Y3, [#CP_NAME_TMP]

                ; Build src "<srcdrive>:<name>" in KOSH_NORM_A.
                MOVE    Y1, Y3
                LOADI   X1, #KOSH_NORM_A
                LOADP   D0, Y3, [#GLOB_DRIVE]
                ADD     D0, #'A'
                STOREB  D0, [XY1]
                INC     XY1, #1
                LOADI   D0, #':'
                STOREB  D0, [XY1]
                INC     XY1, #1
                LOADP   D0, Y3, [#CP_NAME_TMP]
                MOVE    Y0, Y3
                MOVE    X0, D0
.mv_glob_srccpy:
                LOADB   D0, [XY0]
                STOREB  D0, [XY1]
                CMP     D0, #0
                BEQ.S   .mv_glob_srcdone
                INC     XY0, #1
                INC     XY1, #1
                BRA     .mv_glob_srccpy
.mv_glob_srcdone:
                LOADI   D0, #KOSH_NORM_A
                STOREP  D0, Y3, [#CP_SRC_PATH_TMP]

                ; Build dst "<dstdrive>:<name>" in KOSH_NORM_B.
                MOVE    Y1, Y3
                LOADI   X1, #KOSH_NORM_B
                LOADP   D0, Y3, [#CP_DSTDRV_TMP]
                ADD     D0, #'A'
                STOREB  D0, [XY1]
                INC     XY1, #1
                LOADI   D0, #':'
                STOREB  D0, [XY1]
                INC     XY1, #1
                LOADP   D0, Y3, [#CP_NAME_TMP]
                MOVE    Y0, Y3
                MOVE    X0, D0
.mv_glob_dstcpy:
                LOADB   D0, [XY0]
                STOREB  D0, [XY1]
                CMP     D0, #0
                BEQ.S   .mv_glob_dstdone
                INC     XY0, #1
                INC     XY1, #1
                BRA     .mv_glob_dstcpy
.mv_glob_dstdone:
                LOADI   D0, #KOSH_NORM_B
                STOREP  D0, Y3, [#CP_DST_PATH_TMP]

                CALL16  _KoshMvOne
                BCS     .mv_glob_check_warn

                ; Success: echo "<src> -> <dst>".
                MOVE    Y0, Y3
                LOADI   X0, #KOSH_NORM_A
                TRAP    #TRAP_PUTS
                MOVE    Y0, Y3
                LOADI   X0, #msg_cp_arrow
                TRAP    #TRAP_PUTS
                MOVE    Y0, Y3
                LOADI   X0, #KOSH_NORM_B
                TRAP    #TRAP_PUTS
                LOADI   D0, #CH_LF
                TRAP    #TRAP_PUTCHAR

                LOADP   D0, Y3, [#GLOB_INDEX]
                ADD     D0, #1
                STOREP  D0, Y3, [#GLOB_INDEX]
                BRA     .mv_glob_iter

.mv_glob_check_warn:
                ; MV_WARN_ROSRC is a soft outcome: the copy succeeded, only
                ; the source unlink was skipped (read-only volume). Echo the
                ; move + a note and CONTINUE the batch (do not abort/cleanup).
                CMP     D0, #MV_WARN_ROSRC
                BNE     .mv_glob_item_err
                MOVE    Y0, Y3
                LOADI   X0, #KOSH_NORM_A
                TRAP    #TRAP_PUTS
                MOVE    Y0, Y3
                LOADI   X0, #msg_cp_arrow
                TRAP    #TRAP_PUTS
                MOVE    Y0, Y3
                LOADI   X0, #KOSH_NORM_B
                TRAP    #TRAP_PUTS
                MOVE    Y0, Y3
                LOADI   X0, #msg_mv_ro_src_tag
                TRAP    #TRAP_PUTS
                LOADP   D0, Y3, [#GLOB_INDEX]
                ADD     D0, #1
                STOREP  D0, Y3, [#GLOB_INDEX]
                BRA     .mv_glob_iter

.mv_glob_item_err:
                ; Stop-on-error: release stack, report, abort.
                PUSH    D0, XY3
                LOADP   D0, Y3, [#GLOB_RSVSIZE]
                ADD     X3, D0
                POP     D0, XY3
                PUSH    D0, XY3
                MOVE    Y0, Y3
                LOADI   X0, #KOSH_NORM_A
                TRAP    #TRAP_PUTS
                LOADI   D0, #CH_SPACE
                TRAP    #TRAP_PUTCHAR
                POP     D0, XY3
                CMP     D0, #CP_ERR_EXISTS
                BEQ     .mv_glob_item_exists
                CMP     D0, #CP_ERR_SAMEPATH
                BEQ     .mv_glob_item_same
                MOVE    Y0, Y3
                LOADI   X0, #msg_mv_failed
                CALL16  _KoshPrintErr
                BRA     .repl_loop
.mv_glob_item_exists:
                MOVE    Y0, Y3
                LOADI   X0, #msg_mv_dst_exists
                TRAP    #TRAP_PUTS
                BRA     .repl_loop
.mv_glob_item_same:
                MOVE    Y0, Y3
                LOADI   X0, #msg_cp_samepath
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.mv_glob_release:
                LOADP   D0, Y3, [#GLOB_RSVSIZE]
                ADD     X3, D0
                BRA     .repl_loop

.mv_glob_destwild:
                MOVE    Y0, Y3
                LOADI   X0, #msg_glob_destwild
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.mv_glob_multidest:
                MOVE    Y0, Y3
                LOADI   X0, #msg_glob_multidest
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.mv_glob_baddrv:
                MOVE    Y0, Y3
                LOADI   X0, #msg_glob_drivewild
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.mv_glob_nomatch:
                LOADP   D0, Y3, [#GLOB_RSVSIZE]
                ADD     X3, D0
                MOVE    Y0, Y3
                LOADI   X0, #msg_glob_nomatch
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.mv_glob_toomany:
                LOADP   D0, Y3, [#GLOB_RSVSIZE]
                ADD     X3, D0
                MOVE    Y0, Y3
                LOADI   X0, #msg_glob_toomany
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.mv_usage:
                MOVE    Y0, Y3
                LOADI   X0, #msg_mv_usage
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

; ----------------------------------------------------------------------------
; _KoshMvOne - move one file. src in CP_SRC_PATH_TMP, dst in CP_DST_PATH_TMP
;   (both normalised pointers in the task page).
;
;   Out:  C = 0 OK
;         C = 1 error, D0 = err code OR sentinel (CP_ERR_SAMEPATH/EXISTS,
;             or MV_WARN_ROSRC = copied OK but source on a read-only volume
;             so it was not removed — caller should treat as success+note).
;   Clobbers: D0, D1, D2, D3, XY0, XY1
;   Preserves: XY3
;
;   Same-drive: TRAP_RENAME (atomic). Cross-drive (kernel returns
;   ERR_INVALID): fall back to _KoshCpOne then TRAP_UNLINK the source.
;   On a unlink-after-copy failure the file exists at both ends; that's
;   survivable, reported as ERR via the copy-succeeded/unlink-failed code.
; ----------------------------------------------------------------------------
_KoshMvOne:
                ; Try kernel rename first (XY0 = old, XY1 = new).
                MOVE    Y0, Y3
                LOADP   D0, Y3, [#CP_SRC_PATH_TMP]
                MOVE    X0, D0
                MOVE    Y1, Y3
                LOADP   D0, Y3, [#CP_DST_PATH_TMP]
                MOVE    X1, D0
                TRAP    #TRAP_RENAME
                BCC     .m1_ok                  ; C=0 -> renamed in place

                ; Rename failed. ERR_INVALID = different drives -> cp+unlink.
                CMP     D0, #ERR_INVALID
                BEQ     .m1_xdrive
                ; Any other error: propagate.
                SEC
                RET

.m1_ok:
                CLC
                RET

.m1_xdrive:
                ; Cross-drive: copy then unlink source.
                CALL16  _KoshCpOne
                BCS     .m1_cp_failed           ; copy failed - src untouched

                ; Copy OK. Unlink the source.
                MOVE    Y0, Y3
                LOADP   D0, Y3, [#CP_SRC_PATH_TMP]
                MOVE    X0, D0
                TRAP    #TRAP_UNLINK
                BCS     .m1_unlink_failed
                CLC
                RET

.m1_cp_failed:
                ; D0 = err/sentinel from _KoshCpOne; src not removed. Propagate.
                SEC
                RET

.m1_unlink_failed:
                ; Copy succeeded but source unlink failed. If the source is
                ; on a read-only volume (e.g. A:/ROM), this is not a real
                ; failure - the file IS at the destination; ROM simply can't
                ; be modified. Signal a soft warning so the caller reports
                ; success-with-note and (for globs) keeps going. Any other
                ; unlink error is a genuine failure (file now at both ends).
                CMP     D0, #ERR_READONLY
                BNE.S   .m1_unlink_hard
                LOADI   D0, #MV_WARN_ROSRC
.m1_unlink_hard:
                SEC
                RET


; ============================================================================
; .do_load - ingest a host-side file into the current drive (Part 25 r6).
;
;   Usage:  load <name>          load LoadFolder/<name> -> <CWD>:<NAME>
;           load <name> -f       overwrite if dest exists
;
;   Workflow:
;     1. Parse name + optional -f flag.
;     2. _HostFOpen(name) -> file size in D0.
;     3. Normalise dest path "<CWD>:<NAME>" via _KoshNormPath.
;     4. If dest exists and no -f: print "exists", FCLOSE, abort.
;     5. sys_open dest WRITE|CREATE|TRUNC.
;     6. Loop: _HostFRead(CP_BUF, 512) -> sys_write until EOF (0 bytes).
;     7. sys_close, _HostFClose, report.
;
;   Cleanup invariant: any path that has FOPEN'd the host file must call
;   _HostFClose before returning to .repl_loop, even on error paths.
;   The EMU's singleton lock means an unclosed FOPEN blocks all future
;   load commands until reboot.
;
;   Reuses CP_BUF (512 B) for the read/write buffer, KOSH_NORM_A for
;   the destination path. Load doesn't run concurrently with cp/mv so
;   the shared buffer is safe.
; ----------------------------------------------------------------------------
.do_load:
                LEA     XY0, XY2
                CALL24  KLIB_STRLEN
                INC     XY0, #1

.load_skip_ws1:
                LOADB   D0, [XY0]
                CMP     D0, #CH_SPACE
                BNE.S   .load_have_name
                INC     XY0, #1
                BRA     .load_skip_ws1

.load_have_name:
                CMP     D0, #0
                BEQ     .load_usage

                ; XY0 = start of name. Walk to end-of-token; capture in-place.
                LEA     XY1, XY0
                ; Default: no -f.
                LOADI   D2, #0
                STOREP  D2, Y3, [#LOAD_FORCE_TMP]

.load_name_find_end:
                LOADB   D0, [XY1]
                CMP     D0, #0
                BEQ     .load_name_terminated   ; line ended at name (>31B away)
                CMP     D0, #CH_SPACE
                BEQ.S   .load_term_name
                INC     XY1, #1
                BRA     .load_name_find_end

.load_term_name:
                ; Nul-terminate the name, then look for -f in the rest.
                LOADI   D0, #0
                STOREB  D0, [XY1]
                INC     XY1, #1
                ; Now scan rest of line for -f.
.load_scan_flag:
                LOADB   D0, [XY1]
                CMP     D0, #0
                BEQ     .load_name_terminated   ; (>31B away)
                CMP     D0, #CH_SPACE
                BEQ.S   .load_scan_skip
                CMP     D0, #'-'
                BNE.S   .load_scan_skip         ; ignore unknown tokens
                ; '-' - check next char for 'f' or 'F'.
                INC     XY1, #1
                LOADB   D0, [XY1]
                CMP     D0, #'f'
                BEQ.S   .load_set_force
                CMP     D0, #'F'
                BNE.S   .load_scan_skip
.load_set_force:
                LOADI   D0, #1
                STOREP  D0, Y3, [#LOAD_FORCE_TMP]
.load_scan_skip:
                INC     XY1, #1
                BRA     .load_scan_flag

.load_name_terminated:
                ; XY0 still = start of (now nul-terminated) name. Save it.
                MOVE    D0, X0
                STOREP  D0, Y3, [#LOAD_NAME_TMP]

                ; --- _HostFOpen(name) -> file size in D0 -------------------
                ; (XY0 already points at the name in the line buffer.)
                CALL24  EMULIB_HOST_FOPEN
                BCS     .load_fopen_err

                ; Save file size for the success message.
                STOREP  D0, Y3, [#LOAD_SIZE_TMP]

                ; --- Build destination path "<CWD>:<NAME>" in KOSH_NORM_A -
                MOVE    Y0, Y3
                LOADP   D0, Y3, [#LOAD_NAME_TMP]
                MOVE    X0, D0
                MOVE    Y1, Y3
                LOADI   X1, #KOSH_NORM_A
                CALL16  _KoshNormPath
                ; XY1 = normalised path; copy to XY0 for sys_open.
                MOVE    Y0, Y1
                MOVE    X0, X1

                ; --- If not -f, check whether dest already exists ---------
                LOADP   D0, Y3, [#LOAD_FORCE_TMP]
                CMP     D0, #0
                BNE.S   .load_open_dest_for_write

                ; Probe sys_open(dest, READ). On success, dest exists -> refuse.
                ; XY0 still points at normalised path.
                LOADI   D0, #FOPEN_READ
                TRAP    #TRAP_OPEN
                BCS.S   .load_open_dest_for_write   ; doesn't exist -> proceed
                ; Exists. Close the probe fd and refuse.
                TRAP    #TRAP_CLOSE
                MOVE    Y0, Y3
                LOADI   X0, #msg_load_exists
                TRAP    #TRAP_PUTS
                ; Must close host file before returning.
                CALL24  EMULIB_HOST_FCLOSE
                BRA     .repl_loop

.load_open_dest_for_write:
                ; Rebuild XY0 from KOSH_NORM_A (sys_open may have clobbered).
                MOVE    Y0, Y3
                LOADI   X0, #KOSH_NORM_A
                LOADI   D0, #OPEN_FLAGS_NEW         ; CREATE | WRITE | TRUNC
                TRAP    #TRAP_OPEN
                BCS     .load_create_err

                STOREP  D0, Y3, [#LOAD_DST_FD_TMP]

                ; Part 34: initialise cumulative bytes-written counter to 0.
                LOADI   D0, #0
                STOREP  D0, Y3, [#LOAD_WRITTEN_LO]
                STOREP  D0, Y3, [#LOAD_WRITTEN_HI]

                ; --- Copy loop -------------------------------------------
.load_copy_loop:
                ; _HostFRead(CP_BUF, 512) -> D0 = bytes read
                MOVE    Y0, Y3
                LOADI   X0, #CP_BUF
                LOADI   D0, #CP_BUF_SIZE
                CALL24  EMULIB_HOST_FREAD
                BCS     .load_fread_err

                CMP     D0, #0
                BEQ     .load_eof

                MOVE    D3, D0                  ; D3 = bytes read

                ; sys_write(fd, count=D3, buf=CP_BUF)
                LOADP   D0, Y3, [#LOAD_DST_FD_TMP]
                MOVE    D1, D3
                MOVE    Y0, Y3
                LOADI   X0, #CP_BUF
                TRAP    #TRAP_WRITE
                BCS     .load_write_err

                CMP     D0, D3
                BNE     .load_short_write

                ; Part 34: accumulate cumulative bytes-written.
                ; D0 = chunk bytes written; add to LOAD_WRITTEN (32-bit).
                LOADP   D1, Y3, [#LOAD_WRITTEN_LO]
                ADD     D1, D0                  ; D1 = new low; C = carry
                STOREP  D1, Y3, [#LOAD_WRITTEN_LO]
                LOADP   D1, Y3, [#LOAD_WRITTEN_HI]
                ADC     D1, #0                  ; propagate carry
                STOREP  D1, Y3, [#LOAD_WRITTEN_HI]

                BRA     .load_copy_loop

.load_eof:
                ; --- Close everything cleanly ----------------------------
                LOADP   D0, Y3, [#LOAD_DST_FD_TMP]
                TRAP    #TRAP_CLOSE
                CALL24  EMULIB_HOST_FCLOSE

                ; --- Print "loaded <N> bytes\n" --------------------------
                ; Build in ROW_BUF: "loaded " + dec(N) + " bytes\n\0"
                MOVE    Y1, Y3
                LOADI   X1, #ROW_BUF

                ; Emit "loaded " prefix.
                MOVE    Y0, Y3
                LOADI   X0, #msg_load_ok
                CALL16  _KoshEmitStrZ

                ; Emit decimal byte count.
                LOADP   D0, Y3, [#LOAD_SIZE_TMP]
                CALL16  _KoshEmitDec

                ; Emit " bytes\n" suffix.
                MOVE    Y0, Y3
                LOADI   X0, #msg_load_bytes
                CALL16  _KoshEmitStrZ

                ; Nul-terminate.
                LOADI   D0, #0
                CALL16  _KoshEmitByte

                MOVE    Y0, Y3
                LOADI   X0, #ROW_BUF
                TRAP    #TRAP_PUTS

                BRA     .repl_loop

; --- Error paths (must always close any open resources before returning) ----

.load_usage:
                MOVE    Y0, Y3
                LOADI   X0, #msg_load_usage
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.load_fopen_err:
                ; FOPEN failed - nothing to close.
                MOVE    Y0, Y3
                LOADI   X0, #msg_load_fopen_err
                CALL16  _KoshPrintErr
                BRA     .repl_loop

.load_create_err:
                ; sys_open WRITE+CREATE failed - close host file before bail.
                ; D0 holds the open error. _HostFClose clobbers D0/D1/D2 but
                ; preserves D3, so stash in D3 across the close. _KoshPrintErr
                ; also preserves D3 -> safe end-to-end.
                MOVE    D3, D0
                CALL24  EMULIB_HOST_FCLOSE
                MOVE    D0, D3
                MOVE    Y0, Y3
                LOADI   X0, #msg_load_create_err
                CALL16  _KoshPrintErr
                BRA     .repl_loop

.load_fread_err:
                ; FREAD failed mid-stream - close dest and host file.
                ; D0 holds the host-side read error. Stash in D3 before
                ; TRAP_CLOSE (which returns its own D0) and _HostFClose
                ; (clobbers D0/D1/D2). Both preserve D3.
                MOVE    D3, D0
                LOADP   D0, Y3, [#LOAD_DST_FD_TMP]
                TRAP    #TRAP_CLOSE
                CALL24  EMULIB_HOST_FCLOSE
                MOVE    D0, D3
                MOVE    Y0, Y3
                LOADI   X0, #msg_load_fread_err
                CALL16  _KoshPrintErr
                BRA     .repl_loop

.load_write_err:
                ; sys_write failed (commonly ERR_NOSPACE mid-stream).
                ; Part 34: D0 = err code, D1 = partial bytes of failed chunk.
                ; Add D1 to LOAD_WRITTEN to get the real on-disk total, then
                ; emit "load: wrote <SIZE> then failed:\n" preamble + the
                ; standard "load: write error [ERR_NAME $hhhh]\n" line.
                ;
                ; Err code must survive: TRAP_CLOSE, _HostFClose, then
                ; _KoshEmitStrZ x 2 and _KoshEmitSize for the preamble.
                ; _KoshEmitSize does NOT preserve D3 (its KLIB callees
                ; clobber it), so we stash the err code in a page-$00 slot
                ; rather than D3.
                STOREP  D0, Y3, [#LOAD_ERR_TMP]

                ; Add partial-chunk count (D1) to cumulative.
                LOADP   D0, Y3, [#LOAD_WRITTEN_LO]
                ADD     D0, D1
                STOREP  D0, Y3, [#LOAD_WRITTEN_LO]
                LOADP   D0, Y3, [#LOAD_WRITTEN_HI]
                ADC     D0, #0
                STOREP  D0, Y3, [#LOAD_WRITTEN_HI]

                ; Close the destination file (truncated to whatever made it).
                LOADP   D0, Y3, [#LOAD_DST_FD_TMP]
                TRAP    #TRAP_CLOSE
                CALL24  EMULIB_HOST_FCLOSE

                ; Build the "wrote <SIZE> then failed:\n" preamble in ROW_BUF.
                MOVE    Y1, Y3
                LOADI   X1, #ROW_BUF
                MOVE    Y0, Y3
                LOADI   X0, #msg_load_wrote
                CALL16  _KoshEmitStrZ
                LOADP   D0, Y3, [#LOAD_WRITTEN_LO]
                LOADP   D1, Y3, [#LOAD_WRITTEN_HI]
                LOADI   D2, #0                  ; raw size mode
                CALL16  _KoshEmitSize
                MOVE    Y0, Y3
                LOADI   X0, #msg_load_wrote_then
                CALL16  _KoshEmitStrZ
                LOADI   D0, #0
                CALL16  _KoshEmitByte
                MOVE    Y0, Y3
                LOADI   X0, #ROW_BUF
                TRAP    #TRAP_PUTS

                ; Then the standard "load: write error [...]" line with the
                ; stashed err code.
                LOADP   D0, Y3, [#LOAD_ERR_TMP]
                MOVE    Y0, Y3
                LOADI   X0, #msg_load_write_err
                CALL16  _KoshPrintErr
                BRA     .repl_loop

.load_short_write:
                ; NOTE (Part 34): currently unreachable. sys_write's contract
                ; is "C=0 with full count OR C=1 with err code"; partial-byte
                ; counts are never surfaced. If sys_write semantics change to
                ; POSIX-style (C=0 with short count permitted), this path
                ; activates. See Phase 11 partial-write design note.
                LOADP   D0, Y3, [#LOAD_DST_FD_TMP]
                TRAP    #TRAP_CLOSE
                CALL24  EMULIB_HOST_FCLOSE
                MOVE    Y0, Y3
                LOADI   X0, #msg_load_short_write
                TRAP    #TRAP_PUTS
                BRA     .repl_loop


; ============================================================================
; FS-command strings (page-local, addressed via Y3 + page-offset).
; ============================================================================

; --- vol (Part 34 disk-usage table) ----------------------------------------
; Header line aligned to _KoshPrintVolLine's column layout (col starts
; 1-based):
;     1: Drive   8: Label   20: Total (right-aligned in 8)
;    29: Used    38: Free   47: Use%
; Section widths (data row):
;   Drive=7  Label=12  Total=9  Used=9  Free=9  Use%=4   (total 50 chars)
; Section breakdown for the header literal below (concatenated):
;   "Drive  "     (7)   "Label       "  (12)
;   "   Total "   (9)   "    Used "     (9)
;   "    Free "   (9)   "Use%"          (4)
msg_vol_hdr:       .TEXT "Drive  Label          Total     Used     Free Use%\n",0
msg_vol_unmounted: .TEXT "(not mounted)",0
; 28 May 2026 - distinguish "bay bound but image is not formatted FAT16"
; from "no bay bound at all". Emitted as: "(unformatted: <name>)" so the
; user sees both the state and which disk file is bound. Two halves
; because the basename is inserted between them at runtime.
msg_vol_unfmt_pre: .TEXT "(unformatted: ",0
msg_vol_unfmt_post: .TEXT ")",0

; --- ls --------------------------------------------------------------------
msg_ls_usage:     .TEXT  "usage: ls [drive][pattern]  e.g. ls B:  ls *.COM\n",0
msg_ls_files:     .TEXT  " file(s), ",0
msg_ls_used:      .TEXT  " used, ",0
msg_ls_free:      .TEXT  " free\n",0
ls_star_pat:      .TEXT  "*",0             ; match-all pattern (Part 37)
; Pre-Part 34 strings (msg_ls_bytes, msg_ls_kb, msg_ls_big) removed -
; size formatting is now done by _KoshEmitSize (kosh_helpers.asm r3+).

; --- cat -------------------------------------------------------------------
msg_cat_usage:    .TEXT  "usage: cat <path>    e.g. cat B:NOTES.TXT  cat *.TXT\n",0
msg_cat_openerr:  .TEXT  "cat: cannot open file",0

; --- format ----------------------------------------------------------------
msg_format_usage:        .TEXT "usage: format <drive> [label]   drive=B..F\n",0
msg_format_baddrv:       .TEXT "format: bad drive (B..F only; A: is read-only)\n",0
msg_format_badlabel:     .TEXT "format: bad label (use A..Z, 0..9, _ only)\n",0
msg_format_failed:       .TEXT "format: failed",0
msg_format_rename_warn:  .TEXT "format: OK (warning: host filename rename failed)\n",0
msg_format_ok:           .TEXT "OK\n",0

; 11-byte FAT16 volume label, space-padded. Default is "USERDATA   "; this
; buffer is rewritten every .do_format call (custom or default), so its
; initial contents are only the seed value used when the kosh task page is
; first spawned. Page-local - kosh task page is writable post-spawn.
;
; Part 24: on the custom-label path, after a successful TRAP_FORMAT we
; trim trailing spaces in place and write a nul, then pass the same
; address to _HostRename. So this buffer can morph between two shapes:
;   • 11 bytes space-padded label (what _FormatVolume reads)
;   • ASCIIZ basename (<=11 chars + nul) for _HostRename to read
; The two shapes are non-overlapping in time within a single .do_format.
;
; Total reserved: 16 bytes (11 label + 5 spare for nul-term form + pad).
; Use .WORD throughout - .BYTE for zero-fill misbehaves with the
; assembler's word-aligned PC tracking.
kosh_format_label:       .TEXT "USERDATA   "
                         .ALIGN 2
                         .WORD 0, 0               ; 4 spare bytes
                         .WORD 0                  ; +2 = 6 spare total

; kosh_format_custom = nonzero if user gave a label to `format`.
; Drives the post-format _HostRename step. Stored as a word for
; alignment safety; we only ever load it as a byte from the low half.
kosh_format_custom:      .WORD 0

; --- run -------------------------------------------------------------------
msg_run_usage:    .TEXT  "usage: run <path> [&]   e.g. run A:HELLO.COM\n",0
msg_run_execerr:  .TEXT  "run: cannot exec",0
msg_run_waiterr:  .TEXT  "run: wait failed",0
msg_run_exit_lbl: .TEXT  "exit ",0
msg_run_bg_lbl:   .TEXT  "bg ",0

; --- cp --------------------------------------------------------------------
msg_cp_usage:        .TEXT "usage: cp <src> <dst>   e.g. cp A:HI.COM B:HI.COM  cp *.COM B:\n",0
msg_cp_samepath:     .TEXT "cp: source and destination are the same\n",0
msg_cp_exists:       .TEXT "cp: destination exists\n",0
msg_cp_writeerr:     .TEXT "cp: write error",0
msg_cp_ok:           .TEXT "OK\n",0

; --- rm --------------------------------------------------------------------
msg_rm_usage:        .TEXT "usage: rm <path>     e.g. rm B:HELLO.COM  rm *.TMP\n",0
msg_rm_failed:       .TEXT "rm: failed",0

; --- wildcard glob (Part 37) -----------------------------------------------
msg_glob_nomatch:    .TEXT "no matches\n",0
msg_glob_toomany:    .TEXT "too many matches; refine pattern\n",0
msg_glob_drivewild:  .TEXT "drive letter cannot be a wildcard\n",0
msg_glob_removed:    .TEXT " removed\n",0
msg_glob_destwild:   .TEXT "destination cannot contain wildcards\n",0
msg_glob_multidest:  .TEXT "multiple sources need a drive target (e.g. B:)\n",0
msg_cp_arrow:        .TEXT " -> ",0

; --- mv --------------------------------------------------------------------
msg_mv_usage:           .TEXT "usage: mv <src> <dst>   e.g. mv B:OLD.TXT B:NEW.TXT  mv *.TXT C:\n",0
msg_mv_failed:          .TEXT "mv: failed",0
msg_mv_dst_exists:      .TEXT "mv: destination exists\n",0
msg_mv_unlink_err:      .TEXT "mv: copy OK but unlink failed",0
msg_mv_ro_src:          .TEXT "moved (source read-only, left in place)\n",0
msg_mv_ro_src_tag:      .TEXT " (source read-only, left in place)\n",0

; --- load (Part 25 r6) -----------------------------------------------------
msg_load_usage:         .TEXT "usage: load <name> [-f]   reads from host load/ folder\n",0
msg_load_exists:        .TEXT "load: destination exists (use -f to overwrite)\n",0
msg_load_fopen_err:     .TEXT "load: cannot open host file",0
msg_load_create_err:    .TEXT "load: cannot create destination",0
msg_load_fread_err:     .TEXT "load: host read error",0
msg_load_write_err:     .TEXT "load: write error",0
msg_load_short_write:   .TEXT "load: short write\n",0
msg_load_ok:            .TEXT "loaded ",0
msg_load_bytes:         .TEXT " bytes\n",0
; Part 34 partial-write reporting: when sys_write fails mid-stream we now
; print "load: wrote <SIZE> then failed:" before the standard error line.
msg_load_wrote:         .TEXT "load: wrote ",0
msg_load_wrote_then:    .TEXT " then failed:\n",0

; Command name strings (for cmd_table)
cmd_vol_str:      .TEXT  "vol",0
cmd_ls_str:       .TEXT  "ls",0
cmd_cat_str:      .TEXT  "cat",0
cmd_format_str:   .TEXT  "format",0
cmd_run_str:      .TEXT  "run",0
cmd_cp_str:       .TEXT  "cp",0
cmd_rm_str:       .TEXT  "rm",0
cmd_mv_str:       .TEXT  "mv",0
cmd_load_str:     .TEXT  "load",0


; ============================================================================
; CALL24-callable helpers (kernel-side; same idiom as existing _Kosh*).
;
; All helpers preserve D1/D2/D3 unless documented otherwise. They follow
; the convention of _KoshEmitByte / _KoshEmitByteHex / _KoshEmitWordHex:
; cursor in XY1, advance XY1 past output.
; ============================================================================

; ----------------------------------------------------------------------------
; _KoshEmitDec - append decimal text of D0 (unsigned 16) at ROW_BUF cursor.
;
;   In:       D0  unsigned 16-bit value
;             XY1 = cursor
;   Out:      digits stored at [XY1]; XY1 advanced past them
;             (KLIB_UTOA writes a nul at the new position; harmless -
;             overwritten by the next emit, or kept if you nul-terminate
;             the buffer as part of the build)
;   Clobbers: D0
;   Preserves: D1, D2, D3, XY0, XY2, XY3
;
;   Thin wrapper around KLIB_UTOA. KLIB_UTOA uses XY0 as its cursor;
;   kosh's emit-helper convention uses XY1. The wrapper's job is the
;   XY1↔XY0 swap; the swap is two LEA instructions.
;
;   KLIB_UTOA contract (v1.1+, cursor + nul):
;     - writes digits at original XY0
;     - advances XY0 past digits (NOT past nul)
;     - writes nul at advanced XY0
;     - returns D0 = digit count
;
;   So we: copy XY1 to XY0, call, copy advanced XY0 back to XY1.
; ----------------------------------------------------------------------------
_KoshEmitDec:
                PUSH    XY0, XY3
                PUSH    D123, XY3

                LEA     XY0, XY1                ; XY0 = cursor
                CALL24  KLIB_UTOA               ; advances XY0, writes nul at [XY0]
                LEA     XY1, XY0                ; XY1 = advanced cursor

                POP     D123, XY3
                POP     XY0, XY3
                RET


; ----------------------------------------------------------------------------
; _KoshEmitStrZ - append a zstring source at XY0 to ROW_BUF cursor.
;
;   In:       XY0 = source zstring (typically page-relative)
;             XY1 = cursor
;   Out:      bytes copied (excluding the source's nul); XY1 advanced
;   Clobbers: D0
;   Preserves: D1, D2, D3, XY0, XY2, XY3
; ----------------------------------------------------------------------------
_KoshEmitStrZ:
                PUSH    XY0, XY3
.es_loop:
                LOADB   D0, [XY0]
                CMP     D0, #0
                BEQ     .es_done
                STOREB  D0, [XY1]
                INC     XY0, #1
                INC     XY1, #1
                BRA     .es_loop
.es_done:
                POP     XY0, XY3
                RET


; ----------------------------------------------------------------------------
; _KoshEmitNamePadded - emit zstring at XY0 trimmed/padded to D2 chars.
;
;   In:       XY0 = source zstring (in caller's page)
;             XY1 = cursor
;             D2  = field width (1..255)
;   Out:      Exactly D2 bytes written at [XY1]: source up to its nul
;             (or D2 chars, whichever first), then space-padded to D2.
;             XY1 advanced by D2.
;   Clobbers: D0
;   Preserves: D1, D2, D3, XY0, XY2, XY3
; ----------------------------------------------------------------------------
_KoshEmitNamePadded:
                PUSH    XY0, XY3
                PUSH    D1, XY3

                MOVE    D1, D2                  ; D1 = remaining columns
.enp_copy_loop:
                CMP     D1, #0
                BEQ     .enp_done
                LOADB   D0, [XY0]
                CMP     D0, #0
                BEQ     .enp_pad
                STOREB  D0, [XY1]
                INC     XY0, #1
                INC     XY1, #1
                SUB     D1, #1
                BRA     .enp_copy_loop
.enp_pad:
                ; Source ended; pad remaining cols with spaces.
                CMP     D1, #0
                BEQ     .enp_done
                LOADI   D0, #' '
                STOREB  D0, [XY1]
                INC     XY1, #1
                SUB     D1, #1
                BRA     .enp_pad
.enp_done:
                POP     D1, XY3
                POP     XY0, XY3
                RET


; ----------------------------------------------------------------------------
; _KoshPrintVolLine - print one row of the Part 34 disk-usage table.
;
;   In:       D0 = drive index (0..FS_MAX_DRIVES-1)
;   Out:      One line emitted via TRAP_PUTS (built in ROW_BUF).
;   Clobbers: D0, D1, D2, D3, XY0, XY1
;   Preserves: XY2, XY3 (apart from XY3 stack motion)
;
;   Row format (51 chars):
;     "X:     LABEL       TOTAL    USED    FREE  PCT%\n"
;
;   Columns:
;     col0 width  7  "X:     "          drive letter + colon + 5 spaces
;     col1 width 12  "LABEL       "     11-byte FAT label + 1 space (or
;                                       trim if label has internal nul)
;     col2 width  9  "  1.00MB "       total (right-aligned size + 1 sep)
;     col3 width  9  "    45KB "       used
;     col4 width  9  "   979KB "       free
;     col5 width  5  "   4%"            use% (right-aligned)
;
;   Unmounted slots emit:
;     "X:     (not mounted)\n"
;
;   Data flow:
;     1. Resolve slot ptr (slot offset = drive << 6 + VOL_TABLE_BASE).
;     2. If VOL_PRESENT==0 -> emit unmounted line, return.
;     3. sys_diskfree(drive) -> free, total, cluster_sz_bytes (stashed in
;        VOL_FREE_TMP / VOL_TOTAL_TMP / VOL_CLSZ_TMP).
;     4. Build row in ROW_BUF using _KoshEmitByte / _KoshEmitNamePadded
;        for the drive + label cells, then _KoshEmitSize for each size
;        cell. The 4 cells (Total, Used, Free, Use%) need:
;          total_bytes = total * cluster_sz   (32-bit via KLIB_MUL16x16_32)
;          used_clusters = total - free
;          used_bytes = used_clusters * cluster_sz
;          free_bytes = free * cluster_sz
;          pct = (used * 100) / total
;     5. TRAP_PUTS to emit.
; ----------------------------------------------------------------------------
_KoshPrintVolLine:
                ; Stash drive index in DISK_DRIVE_TMP - needed across multiple
                ; CALL24s below.
                STOREP  D0, Y3, [#DISK_DRIVE_TMP]

                ; Build line cursor in ROW_BUF.
                MOVE    Y1, Y3
                LOADI   X1, #ROW_BUF

                ; --- col0 Drive: "X:     " (7 chars) ----------------------
                LOADP   D0, Y3, [#DISK_DRIVE_TMP]
                ADD     D0, #'A'
                CALL16  _KoshEmitByte           ; letter
                LOADI   D0, #':'
                CALL16  _KoshEmitByte
                LOADI   D0, #' '
                CALL16  _KoshEmitByte
                CALL16  _KoshEmitByte
                CALL16  _KoshEmitByte
                CALL16  _KoshEmitByte
                CALL16  _KoshEmitByte           ; 5 trailing spaces, col0 = 7

                ; --- Query the drive via sys_diskfree --------------------
                ; This doubles as the "is it mounted?" test: ERR_BADDRIVE
                ; if not present. Saves us a separate VOL_PRESENT read AND
                ; the manual SHL chain that was earlier giving wrong slots.
                LOADP   D0, Y3, [#DISK_DRIVE_TMP]
                TRAP    #TRAP_DISKFREE
                BCS     .pvl_unmounted
                ; D0=free, D1=total, D2=cluster_sz.
                STOREP  D0, Y3, [#VOL_FREE_TMP]
                STOREP  D1, Y3, [#VOL_TOTAL_TMP]
                STOREP  D2, Y3, [#VOL_CLSZ_TMP]

                ; --- col1 Label: 11-byte VOL_LABEL + 1 space (12 chars) --
                ; Compute slot offset = drive x 64 + VOL_TABLE_BASE.
                ; x64 = x16 (SHL4) + x2 + x2: 3 instructions vs 6.
                LOADP   D2, Y3, [#DISK_DRIVE_TMP]
                SHL4    D2                      ; x16
                SHL     D2                      ; x32
                SHL     D2                      ; x64
                ADD     D2, #VOL_TABLE_BASE

                LOADI   Y0, #$00
                MOVE    X0, D2
                ADD     X0, #VOL_LABEL
                LOADI   D1, #11
.pvl_lbl_loop:
                LOADB   D0, [XY0]
                STOREB  D0, [XY1]
                INC     XY0, #1
                INC     XY1, #1
                SUB     D1, #1
                BNE     .pvl_lbl_loop
                ; One separator space -> col1 total width 12
                LOADI   D0, #' '
                CALL16  _KoshEmitByte

                ; --- col2 Total: total_clusters * cluster_sz, 9-wide -----
                LOADP   D0, Y3, [#VOL_TOTAL_TMP]
                LOADP   D1, Y3, [#VOL_CLSZ_TMP]
                CALL24  KLIB_MUL16x16_32        ; D1:D0 = total bytes
                LOADI   D2, #8                  ; size cell width 8
                CALL16  _KoshEmitSize
                LOADI   D0, #' '
                CALL16  _KoshEmitByte           ; col2 = 8+1 = 9 chars

                ; --- col3 Used: (total-free)*cluster_sz, 9-wide ---------
                LOADP   D0, Y3, [#VOL_TOTAL_TMP]
                LOADP   D1, Y3, [#VOL_FREE_TMP]
                SUB     D0, D1                  ; D0 = used clusters
                LOADP   D1, Y3, [#VOL_CLSZ_TMP]
                CALL24  KLIB_MUL16x16_32        ; D1:D0 = used bytes
                LOADI   D2, #8
                CALL16  _KoshEmitSize
                LOADI   D0, #' '
                CALL16  _KoshEmitByte

                ; --- col4 Free: free * cluster_sz, 9-wide ---------------
                LOADP   D0, Y3, [#VOL_FREE_TMP]
                LOADP   D1, Y3, [#VOL_CLSZ_TMP]
                CALL24  KLIB_MUL16x16_32        ; D1:D0 = free bytes
                LOADI   D2, #8
                CALL16  _KoshEmitSize
                LOADI   D0, #' '
                CALL16  _KoshEmitByte

                ; --- col5 Use%: (used*100) / total, 4-wide value + '%' --
                ; Compute used = total - free.
                LOADP   D0, Y3, [#VOL_TOTAL_TMP]
                LOADP   D1, Y3, [#VOL_FREE_TMP]
                SUB     D0, D1                  ; D0 = used clusters
                ; D1:D0 = used * 100 (32-bit)
                LOADI   D1, #100
                CALL24  KLIB_MUL16x16_32        ; D1:D0 = used*100
                ; Divide by total clusters.
                LOADP   D2, Y3, [#VOL_TOTAL_TMP]
                CALL24  KLIB_DIVMOD32           ; D1:D0=pct, D2=rem (ignored)
                ; pct in D0 (0..100 fits in low word). Render as
                ; right-aligned 3-wide field + '%'.
                ; Use _KoshEmitNamePadded after a quick UTOA into SIZE_FMT_BUF.
                ; Cheaper: just emit 3-wide right-aligned decimal manually.
                ;
                ; UTOA into a scratch, then emit padding + digits + '%'.
                PUSH    D0, XY3                 ; save pct (at [XY3+4] after next push)
                ; Render pct into SIZE_FMT_BUF.
                PUSH    XY0, XY3                ; [XY3+0]=Y0, [XY3+2]=X0
                MOVE    Y0, Y3
                LOADI   X0, #SIZE_FMT_BUF
                ; Reload pct: PUSH XY0 stored 4 bytes (X then Y), so the
                ; PUSH D0 slot is now at [XY3+#4].
                LOADD   D0, [XY3+#4]
                CALL24  KLIB_UTOA               ; XY0 advanced; D0 = digit count
                MOVE    D3, D0                  ; D3 = digit count (1..3)
                POP     XY0, XY3
                POP     D1, XY3                 ; discard saved pct

                ; Emit (3 - D3) leading spaces.
                LOADI   D2, #3
                SUB     D2, D3
                ; K16 carry: C=0 means borrow (D3 > 3, the overflow case).
                ; Branch over the pad emit only on the overflow path.
                BCC.S   .pvl_pct_digits         ; clip if D3 > 3 (shouldn't happen)
                LOADI   D0, #' '
.pvl_pct_pad:
                CMP     D2, #0
                BEQ.S   .pvl_pct_digits
                STOREB  D0, [XY1]
                INC     XY1, #1
                SUB     D2, #1
                BRA     .pvl_pct_pad
.pvl_pct_digits:
                ; Copy digits from SIZE_FMT_BUF.
                PUSH    XY0, XY3
                MOVE    Y0, Y3
                LOADI   X0, #SIZE_FMT_BUF
.pvl_pct_cpy:
                CMP     D3, #0
                BEQ.S   .pvl_pct_cpy_done
                LOADB   D0, [XY0]
                STOREB  D0, [XY1]
                INC     XY0, #1
                INC     XY1, #1
                SUB     D3, #1
                BRA     .pvl_pct_cpy
.pvl_pct_cpy_done:
                POP     XY0, XY3
                ; Append '%'.
                LOADI   D0, #'%'
                CALL16  _KoshEmitByte

                ; --- LF + nul -------------------------------------------
                LOADI   D0, #CH_LF
                CALL16  _KoshEmitByte
                LOADI   D0, #0
                CALL16  _KoshEmitByte
                BRA     .pvl_emit

.pvl_unmounted:
                ; 28 May 2026 - distinguish "(not mounted)" from
                ; "(unformatted)". Reach here whenever sys_diskfree fails;
                ; that's either because the slot is genuinely empty OR
                ; because the bay is bound but the image has no FAT16
                ; BPB (just mkdisk'd, never formatted).
                ;
                ; For drives C..F (index ≥ 2) probe the controller bay
                ; via _HostBayName. If a file is bound, emit
                ; "(unformatted: <name>)" and exit. Otherwise fall through
                ; to the original "(not mounted)" path. Drives A: and B:
                ; (index 0/1) have no bay concept - skip the probe.
                LOADP   D0, Y3, [#DISK_DRIVE_TMP]
                CMP     D0, #2
                BLO     .pvl_um_notmounted          ; A: or B:

                ; bay = drive - 2 (C:->0, D:->1, E:->2, F:->3).
                SUB     D0, #2
                ; XY1 is cursor in ROW_BUF - save across the kernel call
                ; (per _HostBayName spec, X1/Y1 are clobbered).
                PUSH    XY1, XY3
                MOVE    Y0, Y3                       ; task page (buffer lives here)
                LOADI   X0, #kosh_rename_buf        ; 16-byte scratch buf
                CALL24  EMULIB_HOST_BAYNAME
                POP     XY1, XY3
                BCS     .pvl_um_notmounted          ; bay empty -> fall back

                ; Bay has a file bound. Emit "(unformatted: ".
                MOVE    Y0, Y3
                LOADI   X0, #msg_vol_unfmt_pre
                CALL16  _KoshEmitStrZ
                ; Emit basename (ASCIIZ in kosh_rename_buf - page-relative).
                MOVE    Y0, Y3
                LOADI   X0, #kosh_rename_buf
                CALL16  _KoshEmitStrZ
                ; Emit ")".
                MOVE    Y0, Y3
                LOADI   X0, #msg_vol_unfmt_post
                CALL16  _KoshEmitStrZ
                BRA     .pvl_um_finish

.pvl_um_notmounted:
                MOVE    Y0, Y3
                LOADI   X0, #msg_vol_unmounted
                CALL16  _KoshEmitStrZ

.pvl_um_finish:
                LOADI   D0, #CH_LF
                CALL16  _KoshEmitByte
                LOADI   D0, #0
                CALL16  _KoshEmitByte

.pvl_emit:
                MOVE    Y0, Y3
                LOADI   X0, #ROW_BUF
                TRAP    #TRAP_PUTS
                RET


; ============================================================================
; End of kosh_cmds_fs.asm
; ============================================================================
