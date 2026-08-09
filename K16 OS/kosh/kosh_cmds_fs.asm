; ============================================================================
; kosh_cmds_fs.asm - kosh filesystem commands
; ============================================================================
; Date:    8 August 2026
; Status:  Part 64 - glob and ls carry long names and subdirectories.
; Revision: r33 - 9 August 2026 - Part 64: mv's half-completed cross-drive
;             move is reported as itself. _KoshMvOne's .m1_unlink_hard
;             returned the raw unlink error, which both reporters printed
;             through msg_mv_failed - so "the copy landed, the source is
;             still there, the file exists at BOTH ends" read as "mv
;             failed", i.e. as though nothing had happened. Wrong enough to
;             act on: the obvious responses are to re-run the mv or delete
;             the copy that did work. msg_mv_unlink_err had been defined
;             and reserved for this since Part 37 and never wired.
;             Now raises MV_ERR_UNLINK with the real code in MV_UNLINK_ERR,
;             mirroring how MV_WARN_ROSRC already handles the SOFT version
;             of the same event. That asymmetry - soft case named, hard
;             case generic - was the tell.
;           r32 - 9 August 2026 - Part 64 step 2: glob understands a
;             directory part, on both sides.
;             SOURCE: all four glob sites move from _KoshSplitDrivePat to
;             _KoshSplitDirPat, so "rm sub/*.com", "cat b:/a/b/*.txt" and
;             "cp gfx:*.com b:" work. Previously the whole argument became
;             the basename pattern and matched nothing, with no message.
;             DESTINATION (cp/mv only): the bare-"X:" requirement is gone;
;             any existing directory will do. The blocker was never the
;             destination parsing - it was that the src split overwrote
;             CP_CWD_* with the GLOBBED SOURCE directory, so a relative dst
;             would have resolved against the source. _KoshCpOne,
;             _KoshMvOne and TRAP_RENAME each take ONE context for both
;             paths, and TRAP_RENAME could not carry a split one without a
;             kernel ABI change - so instead CP_CWD_* now stays on the
;             shell CWD for the whole batch and the SOURCE is built as a
;             full "<prefix><name>" path. Both sides are then shell-
;             relative and the literal path's _KoshResolveDstPath does the
;             destination join per item, exactly as it does for a single
;             cp. The destination is checked ONCE up front and must be a
;             directory: a file or a missing path would otherwise have
;             every match join onto the same name, and item 2 would report
;             "destination exists" - the symptom, not the mistake.
;             .cp_glob_multidest / .mv_glob_multidest and
;             msg_glob_multidest retire with the requirement they enforced.
;           r31 - 9 August 2026 - Part 64 step 1: long names through glob
;             and ls.
;             (a) ls matched the wildcard against LS_DIRENT_BUF+$00 while
;             printing +$20, so the filter and the row disagreed and
;             `ls Mandel*` found nothing it would then have displayed. The
;             display offset is now computed ONCE per entry into LS_NAMEPTR
;             (_KoshDirentDisplay) and drives both, with an 8.3 fallback in
;             the match (_KoshDirentMatch).
;             (b) GLOB_ENTRY_SIZE 14 -> 32, so the eight open-coded *14
;             shift-and-add chains go: the four reservation sites become
;             SHL4 + SHL, and the four index sites become one CALL16 to
;             _KoshGlobEntryPtr. Worst-case reservation rises 3584 -> 8192
;             bytes against ~30 KB of free stack; derivation in
;             kosh_defs.inc.
;             Deliberately NOT in this revision: _KoshSplitDrivePat still
;             has no '/' handling, so a source pattern with a directory
;             component ("cp sub/*.com b:") still matches nothing, and a
;             glob destination must still be a bare "X:". Both are step 2 -
;             they need CP_CWD_* to stop pointing at the globbed source
;             directory, which is a larger change than this one.
;           r30 - 9 August 2026 - Part 62: .cp_glob_item_err and
;             .mv_glob_item_err reported a garbage error code. Both
;             PUSHed D0, then released the glob-table reservation with
;             ADD X3 - which winds X3 up PAST the pushed slot - then
;             POPped, reading residue out of the just-freed region. The
;             code is now held in D3 across the release. Every observed
;             "[ERR_UNKNOWN $253A]" was this, not a real status, so any
;             earlier diagnosis resting on that value is void.
;           r29 - 9 August 2026 - Part 62: KOSH_NORM_A/B are 80 bytes
;             (KOSH_NORM_LEN) and every copy into them is bounded. The
;             six glob name builds go through _KoshCopyBounded; the
;             literal cp/mv path gets a CP_ERR_TOOLONG arm because
;             _KoshResolveDstPath can now fail. The old 16-byte buffers
;             were overrun by any directory-destination cp/mv with a
;             name of ordinary length - "gfx/Mandelbrot.com" is 19 -
;             which landed silently in CAT_BUF and so never showed.
;           r28 - 9 August 2026 - Part 62: .do_load's destination is now
;             CWD-relative. It was the last command still building its
;             path through _KoshNormPath, which prepends "<KOSH_CWD>:";
;             per the resolver convention an explicit "X:" prefix means
;             start cluster 0, so every load landed in the drive root
;             regardless of the current directory (`cd graphics` then
;             `load ramdisk/GUI128F.com` wrote B:/GUI128F.com). Now the
;             raw basename is passed with CWD context in D1/D2, the same
;             shape .do_cat and cp/mv took in Part 44. Side effect: the
;             destination path no longer stages through KOSH_NORM_A, so
;             the 16-byte buffer no longer caps the name - "B:" +
;             "Mandelbrot.com" + nul was already a 1-byte overrun into
;             KOSH_NORM_B.
;           r27 - 8 August 2026 - Part 61: .cd_resolve's two failure arms
;             consult CD_BARE. Entered from the bare colon-token route, a
;             non-directory target (or ERR_NOTFOUND) is an executable rather
;             than a failed cd, so control returns to .nds_nocolon and takes
;             the cmd_table-miss -> .unknown -> _KoshExecFile path. Entered
;             from `cd`, behaviour is unchanged. .do_cd clears CD_BARE.
;           r26 - 8 August 2026 - Part 61: .do_load accepts an optional
;             host-folder prefix, e.g. `load ramdisk/zork.com`, selecting
;             the host's system/ramdisk folder instead of the default
;             uploads folder. LOAD_NAME keeps the full token (the prefix is
;             what the EMU resolves the folder from); the new LOAD_BASENAME
;             holds the last '/'-separated component and is what feeds
;             _KoshNormPath. Without the split _KoshNormPath reads '/' as a
;             k/OS separator and tries to create the file inside a directory
;             named "ramdisk" on the destination drive. Also added an
;             early silent return on HOST_DIGITAL: A:STARTUP.KSH carries
;             `load` lines that run on every target, and the host bridge is
;             EMU-only, so Digital would otherwise print one failure per
;             line at boot.
;           r25 - 2 August 2026 - Part 26: .do_load stores the host file
;             size as a 32-bit pair (LOAD_SIZE_LO/HI) now that _HostFOpen
;             returns D1:D0, checks it against LOAD_WRITTEN before
;             reporting success, and renders the count with the new
;             _KoshEmitDec32. Previously the message truncated at 64 KB.
;           r24 - 17 June 2026 - Part 44 (Phase 2b): cat/rm/run/cp/mv made
;             CWD-relative. These commands drop _KoshNormPath (which only
;             prepended the CWD drive *letter*, pinning everything to root)
;             and instead pass the raw arg plus CWD context (cluster + drive
;             index) so the kernel resolver applies an "X:" prefix, a leading
;             "/", or a CWD-relative subpath. cp/mv share new CP_CWD_CLU/DRV
;             slots (set via _KoshStashCwd) consumed at each open/rename/
;             unlink. _KoshExpandBareDst (prefix-only bare-drive hack)
;             replaced by _KoshResolveDstPath: if the dst resolves to an
;             existing directory, the path becomes "<dst>/<src-basename>"
;             (covers bare "b:" and any subdir like "b:/foo"). Glob cp/mv
;             stay root-only (subdir glob is a later step); _KoshNormPath
;             is now used only by .do_load.
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
;             task-local RUN_BG word ($45F8) across TRAP_EXEC, instead
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
;               at $40A4; LS_SIZE / LS_DRIVE / LS_INDEX /
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
;             - Fix: stash drive in LS_DRIVE, index in LS_INDEX
;               (new zero-page kosh-page slots, $40A6/$40A8). Re-load
;               at top of each iteration; bump LS_INDEX at the
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
                STOREP  D0, Y3, [#DISK_DRIVE]
.dv_loop:
                LOADP   D0, Y3, [#DISK_DRIVE]
                CMP     D0, #FS_MAX_DRIVES
                BHS.S   .dv_done
                CALL16  _KoshPrintVolLine       ; D0 = drive index
                LOADP   D0, Y3, [#DISK_DRIVE]
                ADD     D0, #1
                STOREP  D0, Y3, [#DISK_DRIVE]
                BRA     .dv_loop
.dv_done:
                CALL16  _KoshBlankLine
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

                ; Next token = optional drive/path arg (quote-aware).
                CALL16  _KoshNextToken
                BCS     .ls_default              ; no arg -> default drive
                LEA     XY0, XY1                 ; XY0 = arg start (ASCIIZ)
.ls_check_arg:
                ; Stash the arg pointer (offset; page = Y3) — we re-walk it.
                MOVE    D0, X0
                STOREP  D0, Y3, [#LS_ARG_PTR]
                LOADB   D0, [XY0]
                CMP     D0, #0
                BEQ     .ls_default

                ; ============================================================
                ; Full path/wildcard matrix (Phase 2a):
                ;   basename = chars after last '/', or after "X:" if no '/',
                ;              or the whole arg otherwise.
                ;   If basename has a wildcard ('*'/'?') -> it's the PATTERN and
                ;      the part before it is the directory to resolve.
                ;   Else -> the WHOLE arg is the directory; pattern = "*".
                ; ============================================================

                ; --- scan for last '/' and drive prefix -------------------
                ; XY0 = arg start. Walk to nul, remembering last-slash offset.
                ; D1 = last-slash absolute offset, $FFFF = none.
                LOADI   D1, #$FFFF              ; last_slash = none
.ls_scan:
                LOADB   D0, [XY0]
                AND     D0, #$FF
                CMP     D0, #0
                BEQ.S   .ls_scan_done
                CMP     D0, #'/'
                BNE.S   .ls_scan_adv
                MOVE    D1, X0                  ; record this slash offset
.ls_scan_adv:
                INC     XY0, #1
                BRA     .ls_scan
.ls_scan_done:

                ; --- compute basename start offset ------------------------
                ; if last_slash != none -> basename = last_slash + 1
                ; else if "X:" prefix   -> basename = arg + 2
                ; else                  -> basename = arg
                CMP     D1, #$FFFF
                BEQ.S   .ls_no_slash
                MOVE    D2, D1
                ADD     D2, #1                  ; basename_start = slash+1
                BRA     .ls_have_basename
.ls_no_slash:
                ; drive prefix? arg[0] alpha and arg[1] == ':'
                LOADP   D0, Y3, [#LS_ARG_PTR]
                MOVE    X0, D0
                MOVE    Y0, Y3
                LOADB   D0, [XY0]               ; arg[0]
                AND     D0, #$FF
                CALL16  _KoshIsAlpha            ; C=0 if alpha (helper below)
                BCS     .ls_basename_is_arg
                INC     XY0, #1
                LOADB   D0, [XY0]               ; arg[1]
                AND     D0, #$FF
                CMP     D0, #':'
                BNE     .ls_basename_is_arg
                ; prefix present: basename_start = arg + 2
                LOADP   D2, Y3, [#LS_ARG_PTR]
                ADD     D2, #2
                BRA     .ls_have_basename
.ls_basename_is_arg:
                LOADP   D2, Y3, [#LS_ARG_PTR]   ; basename_start = arg
.ls_have_basename:
                ; D2 = basename_start offset. Stash it (reuse LS_INDEX
                ; briefly — it's set to 0 later in loop setup).
                STOREP  D2, Y3, [#LS_INDEX]

                ; --- wildcard in basename? --------------------------------
                MOVE    X0, D2
                MOVE    Y0, Y3
.ls_wild_scan:
                LOADB   D0, [XY0]
                AND     D0, #$FF
                CMP     D0, #0
                BEQ     .ls_no_wild
                CMP     D0, #'*'
                BEQ     .ls_is_wild
                CMP     D0, #'?'
                BEQ     .ls_is_wild
                INC     XY0, #1
                BRA     .ls_wild_scan

.ls_is_wild:
                ; pattern = basename (offset in LS_INDEX); directory =
                ; part before basename.
                LOADP   D0, Y3, [#LS_INDEX] ; basename_start
                STOREP  D0, Y3, [#LS_PAT_PTR]
                ; Was there a slash? -> resolve the dir up to it.
                CMP     D1, #$FFFF
                BEQ     .ls_wild_noslash
                ; Resolve dir part = arg[0..slash). _KoshLsResolveDir handles
                ; the temporary nul-at-offset + restore internally.
                ;   In: XY0 = arg start, D1 = terminate offset (the slash)
                LOADP   D0, Y3, [#LS_ARG_PTR]
                MOVE    X0, D0
                MOVE    Y0, Y3
                CALL16  _KoshLsResolveDir       ; D1=term off -> D2=drive, LS_CLU; C=1 err
                BCS     .ls_resolve_err
                BRA     .ls_have_drive
.ls_wild_noslash:
                ; no slash: dir = CWD, or "X:" root if prefix present.
                LOADP   D0, Y3, [#LS_ARG_PTR]
                MOVE    X0, D0
                MOVE    Y0, Y3
                LOADB   D0, [XY0]               ; arg[0]
                AND     D0, #$FF
                CALL16  _KoshIsAlpha
                BCS     .ls_wild_cwd
                INC     XY0, #1
                LOADB   D0, [XY0]
                AND     D0, #$FF
                CMP     D0, #':'
                BNE     .ls_wild_cwd
                ; "X:" prefix -> that drive's root.
                LOADP   D0, Y3, [#LS_ARG_PTR]
                MOVE    X0, D0
                MOVE    Y0, Y3
                LOADB   D0, [XY0]
                CALL16  _KoshFoldChar
                SUB     D0, #'A'
                MOVE    D2, D0                  ; D2 = drive index
                LOADI   D0, #0
                STOREP  D0, Y3, [#LS_CLU]   ; root
                BRA     .ls_have_drive
.ls_wild_cwd:
                ; CWD drive + CWD cluster.
                MOVE    Y0, Y3
                LOADI   X0, #KOSH_CWD
                LOADB   D0, [XY0]
                SUB     D0, #'A'
                MOVE    D2, D0
                LOADI   X0, #KOSH_CWD_CLU
                LOADD   D0, [XY0]
                STOREP  D0, Y3, [#LS_CLU]
                BRA     .ls_have_drive

.ls_no_wild:
                ; Whole arg is a directory; pattern = "*".
                MOVE    Y0, Y3
                LOADI   X0, #ls_star_pat
                STOREP  X0, Y3, [#LS_PAT_PTR]
                ; resolve whole arg (terminate offset = $FFFF -> none).
                LOADP   D0, Y3, [#LS_ARG_PTR]
                MOVE    X0, D0
                MOVE    Y0, Y3
                LOADI   D1, #$FFFF
                CALL16  _KoshLsResolveDir       ; -> D2=drive, LS_CLU; C=1 err
                BCS     .ls_resolve_err
                BRA     .ls_have_drive

.ls_resolve_err:
                ; D0 = err from sys_resolve (NOTFOUND/NOTDIR/BADPATH/...).
                ; ERR_NOTDIR gets a friendlier message.
                CMP     D0, #ERR_NOTDIR
                BNE.S   .ls_resolve_err_generic
                MOVE    Y0, Y3
                LOADI   X0, #msg_ls_notdir
                TRAP    #TRAP_PUTS
                BRA     .repl_loop
.ls_resolve_err_generic:
                MOVE    Y0, Y3
                LOADI   X0, #msg_ls_failed
                CALL16  _KoshPrintErr
                BRA     .repl_loop

.ls_default:
                ; No arg: list CWD (drive + cluster), match-all pattern.
                MOVE    Y0, Y3
                LOADI   X0, #KOSH_CWD
                LOADB   D0, [XY0]
                SUB     D0, #'A'                ; D0 = drive index 0..5
                MOVE    D2, D0
                MOVE    Y0, Y3
                LOADI   X0, #KOSH_CWD_CLU
                LOADD   D0, [XY0]
                STOREP  D0, Y3, [#LS_CLU]
                MOVE    Y0, Y3
                LOADI   X0, #ls_star_pat
                STOREP  X0, Y3, [#LS_PAT_PTR]

.ls_have_drive:
                ; Stash drive early - used by the header pwd and the walk loop
                ; below (sys_pwd may clobber D2, so don't rely on it after).
                STOREP  D2, Y3, [#LS_DRIVE]

                ; --- Header: "  <full path>\n" via sys_pwd ----------------
                ; Reverse-resolve the listed dir (drive + LS_CLU) to its
                ; full path, so subdirs show e.g. "B:/test dir" rather than
                ; just the volume label. Lay the 2-space indent into ROW_BUF
                ; by hand, then let sys_pwd write the path at ROW_BUF+2.
                MOVE    Y0, Y3
                LOADI   X0, #ROW_BUF
                LOADI   D0, #CH_SPACE
                STOREB  D0, [XY0]+
                STOREB  D0, [XY0]+
                LOADP   D0, Y3, [#LS_DRIVE]   ; D0 = drive index
                LOADP   D1, Y3, [#LS_CLU]     ; D1 = listed cluster (0=root)
                TRAP    #TRAP_PWD
                BCS     .ls_hdr_fallback

                ; ROW_BUF = "  X:/path"\0 ; append LF + nul.
                MOVE    Y0, Y3
                LOADI   X0, #ROW_BUF
                CALL24  KLIB_STRLEN              ; XY0 -> nul
                LOADI   D0, #CH_LF
                STOREB  D0, [XY0]+
                LOADI   D0, #0
                STOREB  D0, [XY0]
                BRA     .ls_hdr_emit

.ls_hdr_fallback:
                ; sys_pwd failed (shouldn't happen) - emit "  X:/\n".
                MOVE    Y1, Y3
                LOADI   X1, #ROW_BUF
                LOADI   D0, #CH_SPACE
                CALL16  _KoshEmitByte
                CALL16  _KoshEmitByte
                LOADP   D0, Y3, [#LS_DRIVE]
                ADD     D0, #'A'                ; drive index -> letter
                CALL16  _KoshEmitByte
                LOADI   D0, #':'
                CALL16  _KoshEmitByte
                LOADI   D0, #'/'
                CALL16  _KoshEmitByte
                LOADI   D0, #CH_LF
                CALL16  _KoshEmitByte
                LOADI   D0, #0
                CALL16  _KoshEmitByte

.ls_hdr_emit:
                ; name-aware header: emit the 2-space indent, then substitute
                ; the drive letter with a named volume if one exists.
                MOVE    Y0, Y3
                LOADI   X0, #msg_two_sp
                TRAP    #TRAP_PUTS
                MOVE    Y0, Y3
                LOADI   X0, #ROW_BUF
                ADD     X0, #2                  ; skip the baked-in indent
                CALL16  _KoshEmitPwdNamed

                ; --- Walk directory via sys_dirent ------------------------
                ; D2 = drive (preserved across loop via LS_DRIVE)
                ; D3 = index (preserved across loop via LS_INDEX)
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
                STOREP  D0, Y3, [#LS_DIR_COUNT]
                STOREP  D0, Y3, [#LS_TOTAL_LO]
                STOREP  D0, Y3, [#LS_TOTAL_HI]

                ; (LS_DRIVE already stashed at .ls_have_drive.)
                LOADI   D3, #0                  ; D3 = index
                STOREP  D3, Y3, [#LS_INDEX]

.ls_loop:
                ; Re-load drive + index + cluster (clobbered last iter by the
                ; row-build helpers).
                LOADP   D0, Y3, [#LS_DRIVE]
                LOADP   D1, Y3, [#LS_INDEX]
                LOADP   D2, Y3, [#LS_CLU]   ; directory cluster (0=root)
                MOVE    Y0, Y3
                LOADI   X0, #LS_DIRENT_BUF
                TRAP    #TRAP_DIRENT
                BCS     .ls_done

                ; --- Display name (Part 64) ------------------------------
                ; +$20 when this entry has a VFAT long name, else +$00.
                ; Computed once and kept, because the filter below and the
                ; row emit further down MUST agree on which name they mean.
                ; They did not before Part 64: the filter matched the 8.3
                ; name while the row printed the long one, so `ls Mandel*`
                ; found nothing it would then have displayed.
                LOADI   D0, #LS_DIRENT_BUF
                CALL16  _KoshDirentDisplay
                STOREP  D0, Y3, [#LS_NAMEPTR]

                ; --- Wildcard filter (Part 37; Part 64: 8.3 fallback) ----
                MOVE    D2, D0                  ; D2 = display name offset
                LOADI   D1, #LS_DIRENT_BUF      ; D1 = 8.3 name offset
                LOADP   D0, Y3, [#LS_PAT_PTR]   ; D0 = pattern offset
                CALL16  _KoshDirentMatch
                BCS     .ls_skip                ; no match -> skip entry

                ; Build row in ROW_BUF.
                MOVE    Y1, Y3
                LOADI   X1, #ROW_BUF

                ; "  " (2-space indent - matches vol/disks/task layout)
                LOADI   D0, #CH_SPACE
                CALL16  _KoshEmitByte
                LOADI   D0, #CH_SPACE
                CALL16  _KoshEmitByte

                ; Emit the display name selected above (Part 64: LS_NAMEPTR,
                ; so the row shows exactly what the filter matched). The
                ; probe that used to sit here has moved to the top of the
                ; loop - duplicating it was how the two came to disagree.
                ; _KoshEmitNameLong does not truncate, so names > 12 cols
                ; overflow the field (that row's size just shifts right).
                MOVE    Y0, Y3
                LOADP   D0, Y3, [#LS_NAMEPTR]
                MOVE    X0, D0
                LOADI   D2, #32                 ; field width = LFN_MAX+1 (long names align)
                CALL16  _KoshEmitNameLong

                ; Two-space separator.
                LOADI   D0, #CH_SPACE
                CALL16  _KoshEmitByte
                CALL16  _KoshEmitByte

                ; Size: read 32-bit field at LS_DIRENT_BUF+$10 (low) and
                ; LS_DIRENT_BUF+$12 (high).
                ;
                ; Print rules (Part 26):
                ;   Human form via _KoshEmitSize, right-aligned in 9 to match
                ;   vol's column. Replaces "low 16 bits as decimal, else the
                ;   literal string BIG" -- files above 64 KB are ordinary now
                ;   that the fd layer carries a 32-bit position, and BIG was
                ;   never a size.
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

                ; --- Directory? show "<DIR>" instead of a size -------------
                ; DIRENT_INFO attribute byte is at +$0C (set by
                ; _FatEntryToInfo from raw dirent $0B). If DIR_ATTR_DIRECTORY
                ; is set, emit "<DIR>" and skip both the size accumulate and
                ; the decimal/BIG print. (A dir's size field is 0, so the
                ; total is unaffected either way; skipping is just cleaner.)
                MOVE    Y0, Y3
                LOADI   X0, #LS_DIRENT_BUF+$0C
                LOADB   D0, [XY0]
                AND     D0, #DIR_ATTR_DIRECTORY
                BEQ     .ls_not_dir
                ; It's a directory. Part 26: the size column is now
                ; right-aligned in 9, so "<DIR>" (5 chars) needs 4 leading
                ; spaces to sit in the same column as a size.
                LOADI   D0, #CH_SPACE
                CALL16  _KoshEmitByte
                CALL16  _KoshEmitByte
                CALL16  _KoshEmitByte
                CALL16  _KoshEmitByte
                LOADI   D0, #'<'
                CALL16  _KoshEmitByte
                LOADI   D0, #'D'
                CALL16  _KoshEmitByte
                LOADI   D0, #'I'
                CALL16  _KoshEmitByte
                LOADI   D0, #'R'
                CALL16  _KoshEmitByte
                LOADI   D0, #'>'
                CALL16  _KoshEmitByte
                ; count this directory (Windows counts . and .. too).
                LOADP   D0, Y3, [#LS_DIR_COUNT]
                ADD     D0, #1
                STOREP  D0, Y3, [#LS_DIR_COUNT]
                BRA     .ls_after_size

.ls_not_dir:
                ; count this file.
                LOADP   D0, Y3, [#LS_FILE_COUNT]
                ADD     D0, #1
                STOREP  D0, Y3, [#LS_FILE_COUNT]
                ; --- 32-bit accumulate: total += (D3:D2) ------------------
                LOADP   D0, Y3, [#LS_TOTAL_LO]
                LOADP   D1, Y3, [#LS_TOTAL_HI]
                ADD     D0, D2                  ; lo += size_lo, sets C
                ADC     D1, D3                  ; hi += size_hi + C
                STOREP  D0, Y3, [#LS_TOTAL_LO]
                STOREP  D1, Y3, [#LS_TOTAL_HI]

                ; --- Per-row print: human form, right-aligned in 9 --------
                ; _KoshEmitSize takes D1:D0 = count and D2 = field width, and
                ; clobbers D0..D3 -- safe here, the 32-bit accumulate above
                ; has already consumed D3:D2 and nothing past .ls_after_size
                ; reads them.
                MOVE    D0, D2                  ; D0 = size low
                MOVE    D1, D3                  ; D1 = size high
                LOADI   D2, #9                  ; field width, matches vol
                CALL16  _KoshEmitSize

.ls_after_size:
                LOADI   D0, #CH_LF
                CALL16  _KoshEmitByte
                LOADI   D0, #0
                CALL16  _KoshEmitByte

                MOVE    Y0, Y3
                LOADI   X0, #ROW_BUF
                TRAP    #TRAP_PUTS

                ; Advance index (the file/dir count was bumped in its branch).
                LOADP   D0, Y3, [#LS_INDEX]
                ADD     D0, #1
                STOREP  D0, Y3, [#LS_INDEX]
                BRA     .ls_loop

.ls_skip:
                ; Non-matching entry: advance index only (no row, no tally).
                LOADP   D0, Y3, [#LS_INDEX]
                ADD     D0, #1
                STOREP  D0, Y3, [#LS_INDEX]
                BRA     .ls_loop

.ls_done:
                ; --- Footer: two aligned, pluralised lines ----------------
                ;     "  <count> <word> <size> used"
                ;     "  <count> <word> <size> free"
                ; Fixed columns so size + used/free line up: count right-
                ; aligned (w4), word left-padded (w5), size right-aligned (w9).
                ; used = sum of file sizes; free = disk free. Singular word
                ; when the count is exactly 1.

                ; ---- Line 1: files + used ----
                MOVE    Y1, Y3
                LOADI   X1, #ROW_BUF
                LOADI   D0, #CH_SPACE
                CALL16  _KoshEmitByte
                CALL16  _KoshEmitByte

                LOADP   D0, Y3, [#LS_FILE_COUNT]
                LOADI   D2, #3                  ; count field (left-aligned)
                CALL16  _KoshEmitDecL

                LOADP   D0, Y3, [#LS_FILE_COUNT]
                CMP     D0, #1
                BNE     .ls_word_files
                MOVE    Y0, Y3
                LOADI   X0, #msg_cnt_file
                BRA     .ls_word_femit
.ls_word_files:
                MOVE    Y0, Y3
                LOADI   X0, #msg_cnt_files
.ls_word_femit:
                LOADI   D2, #6                  ; word field (left-padded)
                CALL16  _KoshEmitNamePadded

                LOADP   D0, Y3, [#LS_TOTAL_LO]
                LOADP   D1, Y3, [#LS_TOTAL_HI]
                LOADI   D2, #9                  ; size field (right-aligned)
                CALL16  _KoshEmitSize
                LOADI   D0, #CH_SPACE
                CALL16  _KoshEmitByte
                MOVE    Y0, Y3
                LOADI   X0, #msg_ls_used        ; "used\n"
                CALL16  _KoshEmitStrZ
                LOADI   D0, #0
                CALL16  _KoshEmitByte
                MOVE    Y0, Y3
                LOADI   X0, #ROW_BUF
                TRAP    #TRAP_PUTS

                ; ---- Line 2: dirs + free ----
                MOVE    Y1, Y3
                LOADI   X1, #ROW_BUF
                LOADI   D0, #CH_SPACE
                CALL16  _KoshEmitByte
                CALL16  _KoshEmitByte

                LOADP   D0, Y3, [#LS_DIR_COUNT]
                LOADI   D2, #3
                CALL16  _KoshEmitDecL

                LOADP   D0, Y3, [#LS_DIR_COUNT]
                CMP     D0, #1
                BNE     .ls_word_dirs
                MOVE    Y0, Y3
                LOADI   X0, #msg_cnt_dir
                BRA     .ls_word_demit
.ls_word_dirs:
                MOVE    Y0, Y3
                LOADI   X0, #msg_cnt_dirs
.ls_word_demit:
                LOADI   D2, #6
                CALL16  _KoshEmitNamePadded

                ; free bytes = free_clusters * cluster_size on the listed drive
                LOADP   D0, Y3, [#LS_DRIVE]
                TRAP    #TRAP_DISKFREE
                BCS     .ls_skip_free
                MOVE    D1, D2                  ; D1 = cluster_sz
                CALL24  KLIB_MUL16x16_32        ; D1:D0 = free bytes
                LOADI   D2, #9                  ; size field (right-aligned)
                CALL16  _KoshEmitSize
                LOADI   D0, #CH_SPACE
                CALL16  _KoshEmitByte
                MOVE    Y0, Y3
                LOADI   X0, #msg_ls_free        ; "free\n"
                CALL16  _KoshEmitStrZ
                BRA     .ls_emit_row

.ls_skip_free:
                LOADI   D0, #CH_LF
                CALL16  _KoshEmitByte

.ls_emit_row:
                LOADI   D0, #0
                CALL16  _KoshEmitByte
                MOVE    Y0, Y3
                LOADI   X0, #ROW_BUF
                TRAP    #TRAP_PUTS

                CALL16  _KoshBlankLine
                BRA     .repl_loop


.ls_usage:
                MOVE    Y0, Y3
                LOADI   X0, #msg_ls_usage
                TRAP    #TRAP_PUTS
                BRA     .repl_loop


; ----------------------------------------------------------------------------
; _KoshIsAlpha - C=0 if D0 (low byte) is A..Z or a..z, else C=1.
;   D0 preserved. Clobbers nothing else.
; ----------------------------------------------------------------------------
_KoshIsAlpha:
                PUSH    D1, XY3
                MOVE    D1, D0
                AND     D1, #$FF
                CMP     D1, #'A'
                BLO.S   .kia_no
                CMP     D1, #$5B                ; 'Z'+1
                BLO.S   .kia_yes
                CMP     D1, #'a'
                BLO.S   .kia_no
                CMP     D1, #$7B                ; 'z'+1
                BHS.S   .kia_no
.kia_yes:
                POP     D1, XY3
                CLC
                RET
.kia_no:
                POP     D1, XY3
                SEC
                RET


; ----------------------------------------------------------------------------
; _KoshLsResolveDir - resolve a directory path for `ls`, set D2=drive +
;   LS_CLU=cluster. Optionally terminates the path at an offset first
;   (for "dir/PATTERN" splitting) and restores it after.
;
;   In:  XY0 = path start (task page)
;        D1  = terminate offset within the page ($FFFF = use whole string)
;   Out: C=0 with D2 = drive index, LS_CLU = directory cluster
;        C=1 with D0 = ERR_* (NOTDIR if the path resolves to a non-directory)
;   Clobbers: D0, D1, D2, D3, XY0, XY1
;   Preserves: XY2, XY3
;
;   Uses sys_resolve with CWD context (KOSH_CWD drive + KOSH_CWD_CLU), so
;   relative paths and "X:" prefixes both work. The result must be a
;   directory; a file yields ERR_NOTDIR. State is kept in LS_* ZP scratch
;   (no stack juggling): LS_RD_ARG (path ptr), LS_RD_OFF (term offset),
;   LS_RD_BYTE (saved byte).
; ----------------------------------------------------------------------------
_KoshLsResolveDir:
                ; Stash path ptr + term offset.
                MOVE    D2, X0
                STOREP  D2, Y3, [#LS_RD_ARG]
                STOREP  D1, Y3, [#LS_RD_OFF]

                ; If terminating, save the byte and write a nul.
                CMP     D1, #$FFFF
                BEQ.S   .lrd_resolve
                MOVE    X1, D1
                MOVE    Y1, Y3
                LOADB   D2, [XY1]
                STOREP  D2, Y3, [#LS_RD_BYTE]   ; saved original byte
                LOADI   D2, #0
                STOREB  D2, [XY1]               ; nul-terminate the dir part

.lrd_resolve:
                ; sys_resolve(XY0=path, D0=cwd drive, D1=cwd clu).
                LOADP   D0, Y3, [#LS_RD_ARG]
                MOVE    X0, D0
                MOVE    Y0, Y3                  ; XY0 = path start
                MOVE    Y1, Y3
                LOADI   X1, #KOSH_CWD
                LOADB   D0, [XY1]
                SUB     D0, #'A'                ; CWD drive index
                LOADI   X1, #KOSH_CWD_CLU
                LOADD   D1, [XY1]               ; CWD cluster
                TRAP    #TRAP_RESOLVE           ; -> D0=drive, D1=clu, D2=attr

                ; Stash resolve outputs in ZP before the byte-restore.
                STOREP  D0, Y3, [#LS_RD_DRV]
                STOREP  D1, Y3, [#LS_RD_CLU]
                STOREP  D2, Y3, [#LS_RD_ATTR]
                ; Capture carry by branching now (before any flag-touching op).
                BCS     .lrd_restore_then_err

                ; --- success path: restore byte, then validate dir --------
                CALL16  _KoshLsRestoreByte
                LOADP   D2, Y3, [#LS_RD_ATTR]
                AND     D2, #DIR_ATTR_DIRECTORY
                BEQ.S   .lrd_notdir
                LOADP   D2, Y3, [#LS_RD_DRV]    ; D2 = drive index
                LOADP   D0, Y3, [#LS_RD_CLU]
                STOREP  D0, Y3, [#LS_CLU]
                CLC
                RET

.lrd_notdir:
                LOADI   D0, #ERR_NOTDIR
                SEC
                RET

.lrd_restore_then_err:
                CALL16  _KoshLsRestoreByte
                LOADP   D0, Y3, [#LS_RD_DRV]    ; resolve put err code in D0
                SEC
                RET

; _KoshLsRestoreByte - if LS_RD_OFF != $FFFF, write LS_RD_BYTE back at that
;   offset (page = Y3). Clobbers D0, D1, XY1.
_KoshLsRestoreByte:
                LOADP   D1, Y3, [#LS_RD_OFF]
                CMP     D1, #$FFFF
                BEQ.S   .lrb_done
                MOVE    X1, D1
                MOVE    Y1, Y3
                LOADP   D0, Y3, [#LS_RD_BYTE]
                STOREB  D0, [XY1]
.lrb_done:
                RET


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

                ; Next token = path arg (quote-aware).
                CALL16  _KoshNextToken
                BCS     .cat_usage               ; no arg
                LEA     XY0, XY1                 ; XY0 = arg start (ASCIIZ)
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
                ; Part 44: pass the raw arg (NO _KoshNormPath) plus CWD context
                ; so the resolver applies an "X:" prefix, a leading "/", or a
                ; CWD-relative subpath ("cat sub/notes.txt"). XY0 already = arg
                ; start. _KoshCatOne open ABI: D1 = start cluster, D2 = start
                ; drive index (D0 = flags is set inside _KoshCatOne).
                MOVE    Y1, Y3
                LOADI   X1, #KOSH_CWD
                LOADB   D2, [XY1]               ; CWD drive letter
                SUB     D2, #'A'                ; -> drive index 0..5
                LOADI   X1, #KOSH_CWD_CLU
                LOADD   D1, [XY1]               ; CWD cluster
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
                ; Part 64 step 2: _KoshSplitDirPat, not _KoshSplitDrivePat -
                ; the pattern may carry a directory part ("cat sub/*.txt").
                ; cat has no destination, so the bare match name resolved in
                ; the globbed directory is still the right idiom; only the
                ; choice of that directory has widened.
                CALL16  _KoshSplitDirPat        ; D0=drive, D1=clu, XY1=pattern
                BCS     .cat_glob_srcdir        ; D0 = ERR_* / CP_ERR_TOOLONG

                STOREP  D0, Y3, [#GLOB_DRIVE]
                STOREP  D1, Y3, [#GLOB_CLU]     ; Part 44 step 4: dir to glob (CWD or root)

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

                ; Reserve stack table: bytes = root_entries * GLOB_ENTRY_SIZE.
                ; Part 64: GLOB_ENTRY_SIZE is 32, so this is SHL4 + SHL. The
                ; shift count IS GLOB_ENTRY_SHIFT; the symbol cannot be spelled
                ; in the operand, so keep the two in step by hand. Worst case
                ; is 256*32 = 8192 bytes - derivation in kosh_defs.inc.
                MOVE    D0, D2
                SHL4    D0                      ; *16
                SHL     D0                      ; *32 = GLOB_ENTRY_SIZE
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

                ; Build the bare match name in KOSH_NORM_A. Part 44 step 4:
                ; no "<DRV>:" prefix — open the bare name with the globbed
                ; directory as context, so it resolves in the CWD (or the
                ; prefixed drive's root) rather than always root.
                CALL16  _KoshGlobEntryPtr       ; D0 = index -> D3 = entry offset

                MOVE    Y1, Y3
                LOADI   X1, #KOSH_NORM_A
                MOVE    Y0, Y3
                MOVE    X0, D3
                ; Part 62: bounded. Part 64 is the case it was written for -
                ; GLOB_ENTRY_SIZE is now 32, so a 31-char long name plus its
                ; nul lands in an 80-byte KOSH_NORM_A with room to spare, and
                ; anything that would not fit fails loudly here instead of
                ; silently writing past the buffer.
                LOADI   D1, #KOSH_NORM_LEN
                CALL16  _KoshCopyBounded
                BCS     .cat_glob_item_err
.cat_glob_namedone:
                ; cat this file. KOSH_NORM_A holds the bare name; resolve it in
                ; the globbed directory (GLOB_CLU : GLOB_DRIVE).
                MOVE    Y0, Y3
                LOADI   X0, #KOSH_NORM_A
                LOADP   D1, Y3, [#GLOB_CLU]     ; start cluster = globbed dir
                LOADP   D2, Y3, [#GLOB_DRIVE]   ; start drive
                CALL16  _KoshCatOne
                BCC     .cat_glob_advance

.cat_glob_item_err:
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
                CALL16  _KoshBlankLine
                BRA     .repl_loop

.cat_glob_srcdir:
                ; Nothing is reserved yet - the split runs before the table.
                MOVE    Y0, Y3
                LOADI   X0, #msg_glob_srcdir
                CALL16  _KoshPrintErr
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
;   In:   XY0 = path (ASCIIZ, task page): "X:NAME", a CWD-relative name, or
;               a subpath ("sub/notes.txt").
;         D1  = start cluster (CWD cluster, or 0 for root)   — Part 44
;         D2  = start drive index                            — Part 44
;               (an "X:" prefix in the path overrides D2 and forces root)
;   Out:  C = 0 OK / C = 1 error (D0 = err code; any open fd already closed)
;   Clobbers: D0, D1, D2, D3, XY0, XY1
;   Preserves: XY3
;
;   sys_open(READ) -> loop sys_read into CAT_BUF -> sys_puts -> sys_close.
;   Shared by the literal and glob cat paths. On read error, closes the fd
;   before returning so no descriptor leaks across the glob iteration.
; ----------------------------------------------------------------------------
_KoshCatOne:
                ; sys_open(path=XY0, flags=READ, D1=start clu, D2=start drive).
                ; D1/D2 were set by the caller; they flow untouched into the
                ; TRAP (only D0 is loaded here).
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
                STOREB  D0, [XY1]+
                INC     XY0, #1
                SUB     D1, #1
                BRA     .format_lbl_copy

.format_lbl_pad:
                ; Source ended; space-pad remaining cols.
                CMP     D1, #0
                BEQ     .format_lbl_done
                LOADI   D0, #' '
                STOREB  D0, [XY1]+
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
                STOREB  D0, [XY1]+
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
                STOREB  D0, [XY1]+
                LOADI   D0, #'S'
                STOREB  D0, [XY1]+
                LOADI   D0, #'E'
                STOREB  D0, [XY1]+
                LOADI   D0, #'R'
                STOREB  D0, [XY1]+
                LOADI   D0, #'D'
                STOREB  D0, [XY1]+
                LOADI   D0, #'A'
                STOREB  D0, [XY1]+
                LOADI   D0, #'T'
                STOREB  D0, [XY1]+
                LOADI   D0, #'A'
                STOREB  D0, [XY1]+
                LOADI   D0, #' '
                STOREB  D0, [XY1]+
                STOREB  D0, [XY1]+
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
                CALL16  _KoshBlankLine
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
                ; --- Strip a surrounding "..." quote pair -----------------
                ; Consistency with the other path commands; run keeps interior
                ; spaces either way, so quotes are optional. If quoted, drop the
                ; opening quote and nul the closing one; else leave untouched.
                ; (An '&' inside quotes was never treated as bg: the bg scan
                ; above only inspects the last non-space char, which for a
                ; quoted arg is the closing quote.)
                LOADB   D0, [XY0]
                AND     D0, #$FF
                CMP     D0, #CH_QUOTE
                BNE     .run_no_strip
                INC     XY0, #1                  ; skip opening quote (new start)
                LEA     XY1, XY0
.run_strip_scan:
                LOADB   D0, [XY1]
                AND     D0, #$FF
                CMP     D0, #0
                BEQ     .run_strip_close
                INC     XY1, #1
                BRA     .run_strip_scan
.run_strip_close:
                CMP     X1, X0                   ; empty body ("") -> leave as-is
                BEQ     .run_no_strip
                DEC     XY1, #1
                LOADB   D0, [XY1]
                AND     D0, #$FF
                CMP     D0, #CH_QUOTE
                BNE     .run_no_strip            ; no closing quote -> leave
                LOADI   D0, #0
                STOREB  D0, [XY1]                ; drop closing quote
.run_no_strip:
                ; XY0 = path, D3 = bg flag. Hand off to the shared exec core
                ; (_KoshExecFile tries XY0 as-typed; on ERR_NOTFOUND retries
                ; once with ".com" appended; runs FG/BG and prints
                ; [exit N]/[bg N] itself). C=1 return = exec failed, unreported.
                CALL16  _KoshExecFile
                BCC     .run_done                ; C=0 -> ran & reported
                ; C=1 -> exec failed (D0=ERR_*). run is explicit: always report.
                MOVE    Y0, Y3
                LOADI   X0, #msg_run_execerr
                CALL16  _KoshPrintErr
.run_done:
                BRA     .repl_loop

.run_usage:
                MOVE    Y0, Y3
                LOADI   X0, #msg_run_usage
                TRAP    #TRAP_PUTS
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
;     CP_SRC_FD       - src fd preserved across CALL24/TRAP boundaries
;     CP_DST_FD       - dst fd
;     CP_SRC_PATH     - src path pointer preserved across pre-flight close
;     CP_DST_PATH     - dst path pointer preserved across pre-flight close
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

                ; --- src + dst tokens (quote-aware) ------------------------
                ; A quoted token keeps interior spaces, so a spaced long
                ; filename survives:  cp notes.txt "test test.txt"
                CALL16  _KoshNextToken           ; src
                BCS     .cp_usage
                MOVE    D0, X1
                STOREP  D0, Y3, [#CP_SRC_PATH]
                CALL16  _KoshNextToken           ; dst
                BCS     .cp_usage
                MOVE    D0, X1
                STOREP  D0, Y3, [#CP_DST_PATH]

.cp_dst_terminated:
                ; Does the SRC contain a wildcard?
                MOVE    Y0, Y3
                LOADP   D0, Y3, [#CP_SRC_PATH]
                MOVE    X0, D0
                CALL16  _KoshHasWildcard
                BCC     .cp_glob                ; C=0 -> wildcard src

                ; --- Literal path (no wildcard) - Part 44 CWD-relative -------
                ; Keep the raw src/dst pointers (CP_SRC_PATH/CP_DST_PATH already
                ; point at the nul-terminated args). Stash CWD context for the
                ; opens, then rewrite a directory dst to "<dst>/<src-basename>".
                CALL16  _KoshStashCwd
                CALL16  _KoshResolveDstPath
                BCS     .cp_report_err          ; Part 62: CP_ERR_TOOLONG

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
                CMP     D0, #CP_ERR_TOOLONG
                BEQ     .cp_toolong_msg
                MOVE    Y0, Y3
                LOADI   X0, #msg_cp_writeerr
                CALL16  _KoshPrintErr
                BRA     .repl_loop

.cp_exists_msg:
                MOVE    Y0, Y3
                LOADI   X0, #msg_cp_exists
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.cp_toolong_msg:
                MOVE    Y0, Y3
                LOADI   X0, #msg_path_toolong
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

; --- Glob path -------------------------------------------------------------
; cp <pattern> <dst> - copy each match into dst, keeping its basename.
; Part 64 step 2: dst may be a bare drive, a named assign, or any existing
; directory - but it must be a DIRECTORY, and it may not contain a wildcard.
; Stop-on-error policy.
.cp_glob:
                MOVE    Y0, Y3
                LOADP   D0, Y3, [#CP_DST_PATH]
                MOVE    X0, D0
                CALL16  _KoshHasWildcard
                BCC     .cp_glob_destwild       ; dst has wildcard -> reject

                ; --- Context: SHELL CWD, for the whole batch --------------
                ; Part 64 step 2. Before this, the src split overwrote
                ; CP_CWD_* with the globbed SOURCE directory, which is the
                ; real reason dst had to be a fully-qualified bare "X:" - a
                ; relative dst would have resolved against the source. The
                ; context cannot simply be split in two: TRAP_RENAME takes
                ; one (D1, D2) pair for BOTH of its paths, so _KoshMvOne
                ; could not carry a split one without a kernel ABI change.
                ; Instead both sides are made shell-relative - the source by
                ; being rebuilt as a full "<prefix><name>" path below.
                CALL16  _KoshStashCwd

                ; Remember the dst token as typed: _KoshResolveDstPath
                ; repoints CP_DST_PATH at KOSH_NORM_B for each match, so the
                ; original must be restored at the top of every iteration.
                LOADP   D0, Y3, [#CP_DST_PATH]
                STOREP  D0, Y3, [#CP_GDST]

                ; --- dst must be an existing DIRECTORY, checked once ------
                ; If it were a file or absent, every match would join onto
                ; the same name: item 1 would copy and item 2 would report
                ; "destination exists", which describes the symptom and not
                ; the mistake. Checked here, before anything is reserved.
                MOVE    Y0, Y3
                MOVE    X0, D0                  ; XY0 = dst token
                LOADP   D0, Y3, [#CP_CWD_DRV]
                LOADP   D1, Y3, [#CP_CWD_CLU]
                TRAP    #TRAP_RESOLVE           ; -> D0=drive, D1=clu, D2=attr
                BCS     .cp_glob_dstmissing
                AND     D2, #DIR_ATTR_DIRECTORY
                BEQ     .cp_glob_dstnotdir

                ; --- Split SRC into a directory part + a pattern ----------
                MOVE    Y0, Y3
                LOADP   D0, Y3, [#CP_SRC_PATH]
                MOVE    X0, D0
                CALL16  _KoshSplitDirPat        ; D0=drv, D1=clu, D2=pfxlen, XY1=pat
                BCS     .cp_glob_srcdir
                STOREP  D0, Y3, [#GLOB_DRIVE]
                STOREP  D1, Y3, [#GLOB_CLU]
                MOVE    D0, X1
                STOREP  D0, Y3, [#GLOB_PATPTR]  ; _KoshGlobExpand re-stashes this,
                                                ;   but the prefix copy below
                                                ;   clobbers XY1 before it runs

                ; --- Lay the source prefix into KOSH_NORM_A, once ---------
                ; Each item then appends only its own name, so every source
                ; path is spelled the way the user spelled it ("gfx:",
                ; "sub/", "b:/a/") and resolves in the same frame as the
                ; destination. An empty prefix is the ordinary CWD case and
                ; leaves the buffer empty.
                LOADP   D0, Y3, [#GLOB_PFXPTR]
                MOVE    Y0, Y3
                MOVE    X0, D0
                MOVE    Y1, Y3
                LOADI   X1, #KOSH_NORM_A
                MOVE    D0, D2                  ; count = prefix length
                LOADI   D1, #KOSH_NORM_LEN
                CALL16  _KoshCopyCounted
                BCS     .cp_glob_pathlong
                MOVE    D0, X1                  ; XY1 was left AT the nul
                STOREP  D0, Y3, [#GLOB_NAMEOFF]
                STOREP  D1, Y3, [#GLOB_NAMECAP] ; capacity left, incl the nul

                ; root_entries for the globbed drive.
                LOADP   D2, Y3, [#GLOB_DRIVE]
                SHL4    D2
                SHL     D2
                SHL     D2
                ADD     D2, #VOL_TABLE_BASE
                LOADI   Y0, #$00
                MOVE    X0, D2
                ADD     X0, #VOL_ROOT_ENTRIES
                LOADD   D2, [XY0]

                ; Reserve stack table: bytes = root_entries * GLOB_ENTRY_SIZE.
                ; Part 64: GLOB_ENTRY_SIZE is 32, so this is SHL4 + SHL. The
                ; shift count IS GLOB_ENTRY_SHIFT; the symbol cannot be spelled
                ; in the operand, so keep the two in step by hand. Worst case
                ; is 256*32 = 8192 bytes - derivation in kosh_defs.inc.
                MOVE    D0, D2
                SHL4    D0                      ; *16
                SHL     D0                      ; *32 = GLOB_ENTRY_SIZE
                STOREP  D0, Y3, [#GLOB_RSVSIZE]
                SUB     X3, D0
                MOVE    D0, X3
                STOREP  D0, Y3, [#GLOB_TABLE]

                ; Expand src pattern. XY1 was consumed by the prefix copy,
                ; so rebuild it from GLOB_PATPTR; D2 still holds root_entries.
                LOADP   D0, Y3, [#GLOB_PATPTR]
                MOVE    Y1, Y3
                MOVE    X1, D0
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

                CALL16  _KoshGlobEntryPtr       ; D0 = index -> D3 = entry offset
                STOREP  D3, Y3, [#CP_NAME]      ; remember for both src and dst

                ; SRC = "<prefix><name>" in KOSH_NORM_A. The prefix is
                ; already there; append at GLOB_NAMEOFF with whatever
                ; capacity it left. A long prefix plus a long name fails
                ; here with CP_ERR_TOOLONG rather than silently truncating
                ; onto some other file.
                LOADP   D0, Y3, [#CP_NAME]
                MOVE    Y0, Y3
                MOVE    X0, D0                  ; XY0 = the table entry
                LOADP   D0, Y3, [#GLOB_NAMEOFF]
                MOVE    Y1, Y3
                MOVE    X1, D0
                LOADP   D1, Y3, [#GLOB_NAMECAP]
                CALL16  _KoshCopyBounded
                BCS     .cp_glob_item_err
.cp_glob_srcdone:
                LOADI   D0, #KOSH_NORM_A
                STOREP  D0, Y3, [#CP_SRC_PATH]

                ; DST: restore the token as typed, then let
                ; _KoshResolveDstPath join basename(src) onto it in
                ; KOSH_NORM_B. This is the SAME helper the literal cp path
                ; uses, so a directory destination behaves identically
                ; whether or not a wildcard was involved.
                LOADP   D0, Y3, [#CP_GDST]
                STOREP  D0, Y3, [#CP_DST_PATH]
                CALL16  _KoshResolveDstPath     ; C=1 -> D0 = CP_ERR_TOOLONG
                BCS     .cp_glob_item_err
.cp_glob_dstdone:

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
                ; Part 62: hold the code in D3, NOT on the stack. The release
                ; below moves X3 past the pushed slot, so a PUSH/POP pair
                ; straddling it pops residue from the freed glob table - that
                ; is where the bogus "[ERR_UNKNOWN $253A]" came from. D3 is
                ; dead on entry (the worker clobbers it) and is restored
                ; before any TRAP that could touch it.
                MOVE    D3, D0
                LOADP   D0, Y3, [#GLOB_RSVSIZE]
                ADD     X3, D0
                MOVE    D0, D3
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

; The four arms below all fire BEFORE the glob table is reserved, so none
; of them releases stack. Keep it that way if any of them ever moves.
.cp_glob_dstmissing:
                MOVE    Y0, Y3
                LOADI   X0, #msg_glob_dstnotfound
                CALL16  _KoshPrintErr
                BRA     .repl_loop

.cp_glob_dstnotdir:
                MOVE    Y0, Y3
                LOADI   X0, #msg_glob_dstnotdir
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.cp_glob_srcdir:
                MOVE    Y0, Y3
                LOADI   X0, #msg_glob_srcdir
                CALL16  _KoshPrintErr
                BRA     .repl_loop

.cp_glob_pathlong:
                MOVE    Y0, Y3
                LOADI   X0, #msg_path_toolong
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
; _KoshCpOne - copy one file. src in CP_SRC_PATH, dst in CP_DST_PATH
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
                LOADP   D0, Y3, [#CP_SRC_PATH]
                MOVE    X0, D0
                MOVE    Y1, Y3
                LOADP   D0, Y3, [#CP_DST_PATH]
                MOVE    X1, D0
.c2_cmp_loop:
                LOADB   D0, [XY0]+
                LOADB   D1, [XY1]+
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
                BRA     .c2_cmp_loop

.c2_same:
                LOADI   D0, #CP_ERR_SAMEPATH
                SEC
                RET

.c2_differ:
                ; --- Open src for reading ----------------------------------
                MOVE    Y0, Y3
                LOADP   D0, Y3, [#CP_SRC_PATH]
                MOVE    X0, D0
                LOADI   D0, #FOPEN_READ
                LOADP   D1, Y3, [#CP_CWD_CLU]   ; Part 44: CWD context
                LOADP   D2, Y3, [#CP_CWD_DRV]
                TRAP    #TRAP_OPEN
                BCS     .c2_src_openerr
                STOREP  D0, Y3, [#CP_SRC_FD]

                ; --- Pre-flight: does dst already exist? -------------------
                MOVE    Y0, Y3
                LOADP   D0, Y3, [#CP_DST_PATH]
                MOVE    X0, D0
                LOADI   D0, #FOPEN_READ
                LOADP   D1, Y3, [#CP_CWD_CLU]   ; Part 44: CWD context
                LOADP   D2, Y3, [#CP_CWD_DRV]
                TRAP    #TRAP_OPEN
                BCS.S   .c2_dst_new             ; not found -> good
                ; Dst exists: close probe + src, return EXISTS.
                TRAP    #TRAP_CLOSE             ; D0 = probe fd
                LOADP   D0, Y3, [#CP_SRC_FD]
                TRAP    #TRAP_CLOSE
                LOADI   D0, #CP_ERR_EXISTS
                SEC
                RET

.c2_dst_new:
                ; --- Open dst for writing ----------------------------------
                MOVE    Y0, Y3
                LOADP   D0, Y3, [#CP_DST_PATH]
                MOVE    X0, D0
                LOADI   D0, #OPEN_FLAGS_NEW
                LOADP   D1, Y3, [#CP_CWD_CLU]   ; Part 44: CWD context
                LOADP   D2, Y3, [#CP_CWD_DRV]
                TRAP    #TRAP_OPEN
                BCS     .c2_dst_createerr
                STOREP  D0, Y3, [#CP_DST_FD]

                ; --- Copy loop ---------------------------------------------
.c2_loop:
                LOADP   D0, Y3, [#CP_SRC_FD]
                LOADI   D1, #CP_BUF_SIZE
                MOVE    Y0, Y3
                LOADI   X0, #CP_BUF
                TRAP    #TRAP_READ
                BCS     .c2_read_err
                CMP     D0, #0
                BEQ     .c2_eof
                MOVE    D3, D0                  ; D3 = bytes read

                LOADP   D0, Y3, [#CP_DST_FD]
                MOVE    D1, D3
                MOVE    Y0, Y3
                LOADI   X0, #CP_BUF
                TRAP    #TRAP_WRITE
                BCS     .c2_write_err
                CMP     D0, D3
                BNE     .c2_short
                BRA     .c2_loop

.c2_eof:
                LOADP   D0, Y3, [#CP_DST_FD]
                TRAP    #TRAP_CLOSE
                LOADP   D0, Y3, [#CP_SRC_FD]
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
                LOADP   D0, Y3, [#CP_SRC_FD]
                TRAP    #TRAP_CLOSE
                MOVE    D0, D2
                SEC
                RET

.c2_read_err:
.c2_write_err:
                MOVE    D2, D0
                LOADP   D0, Y3, [#CP_SRC_FD]
                TRAP    #TRAP_CLOSE
                LOADP   D0, Y3, [#CP_DST_FD]
                TRAP    #TRAP_CLOSE
                MOVE    D0, D2
                SEC
                RET

.c2_short:
                ; D0 = bytes written (< D3). Return it as the "code".
                MOVE    D2, D0
                LOADP   D0, Y3, [#CP_SRC_FD]
                TRAP    #TRAP_CLOSE
                LOADP   D0, Y3, [#CP_DST_FD]
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

                ; Next token = path arg (quote-aware).
                CALL16  _KoshNextToken
                BCS     .rm_usage
                LEA     XY0, XY1                 ; XY0 = path arg (ASCIIZ)
.rm_have_path:

                ; XY0 = path arg. Wildcard present?
                ; (_KoshHasWildcard preserves XY1..XY3; advances XY0, so save it.)
                LEA     XY1, XY0                ; stash arg start in XY1
                CALL16  _KoshHasWildcard
                LEA     XY0, XY1                ; restore arg start
                BCC     .rm_glob                ; C=0 -> has wildcard

                ; --- Literal path (no wildcard) - Part 44 CWD-relative -------
                ; Raw arg + CWD context; sys_unlink resolves the path (an "X:"
                ; prefix, a leading "/", or a CWD-relative subpath).
                ; XY0 already = arg start. D1 = CWD cluster, D2 = CWD drive idx.
                MOVE    Y1, Y3
                LOADI   X1, #KOSH_CWD
                LOADB   D2, [XY1]               ; CWD drive letter
                SUB     D2, #'A'                ; -> drive index 0..5
                LOADI   X1, #KOSH_CWD_CLU
                LOADD   D1, [XY1]               ; CWD cluster
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
                ; Part 64 step 2: see .cat_glob. "rm sub/*.tmp" now resolves
                ; its directory part instead of folding it into the pattern.
                CALL16  _KoshSplitDirPat        ; D0=drive, D1=clu, XY1=pattern
                BCS     .rm_glob_srcdir         ; D0 = ERR_* / CP_ERR_TOOLONG

                ; Stash drive + globbed-dir cluster; pattern ptr (XY1) -> expander.
                STOREP  D0, Y3, [#GLOB_DRIVE]       ; (also re-stashed inside expander)
                STOREP  D1, Y3, [#GLOB_CLU]         ; Part 44 step 4: CWD or root

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

                ; Reserve stack table: bytes = root_entries * GLOB_ENTRY_SIZE.
                ; Part 64: GLOB_ENTRY_SIZE is 32, so this is SHL4 + SHL. The
                ; shift count IS GLOB_ENTRY_SHIFT; the symbol cannot be spelled
                ; in the operand, so keep the two in step by hand. Worst case
                ; is 256*32 = 8192 bytes - derivation in kosh_defs.inc.
                MOVE    D0, D2
                SHL4    D0                      ; *16
                SHL     D0                      ; *32 = GLOB_ENTRY_SIZE
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

                ; Build the bare match name in KOSH_NORM_A (Part 44 step 4: no
                ; "<DRV>:" prefix — resolve it in the globbed directory below).
                CALL16  _KoshGlobEntryPtr       ; D0 = index -> D3 = entry offset

                MOVE    Y1, Y3
                LOADI   X1, #KOSH_NORM_A
                ; Copy name (ASCIIZ) from [Y3:D3].
                MOVE    Y0, Y3
                MOVE    X0, D3
                ; Part 62: bounded (see .cat_glob_namedone).
                LOADI   D1, #KOSH_NORM_LEN
                CALL16  _KoshCopyBounded
                BCS     .rm_glob_item_err
.rm_glob_namedone:
                ; KOSH_NORM_A holds the bare name; resolve + unlink it in the
                ; globbed directory (GLOB_CLU : GLOB_DRIVE).
                MOVE    Y0, Y3
                LOADI   X0, #KOSH_NORM_A
                LOADP   D1, Y3, [#GLOB_CLU]     ; start cluster = globbed dir
                LOADP   D2, Y3, [#GLOB_DRIVE]   ; start drive
                CALL16  _KoshRmOne
                BCC     .rm_glob_ok_one

.rm_glob_item_err:
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

.rm_glob_srcdir:
                MOVE    Y0, Y3
                LOADI   X0, #msg_glob_srcdir
                CALL16  _KoshPrintErr
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
; _KoshRmOne - delete a single file given a path.
;
;   In:   XY0 = path (ASCIIZ, task page): "X:NAME", CWD-relative, or subpath
;         D1  = CWD cluster (0 = root)   — Part 44 (flows into TRAP_UNLINK)
;         D2  = CWD drive index          — Part 44 (an "X:" prefix overrides)
;   Out:  C = 0 OK / C = 1 error (D0 = err code)
;   Clobbers: per TRAP_UNLINK
;   Preserves: XY3 (and whatever TRAP_UNLINK preserves)
;
;   Thin wrapper over TRAP_UNLINK. Both the literal and glob rm paths call
;   this so deletion semantics are identical regardless of how the path
;   was produced. D1/D2 are set by the caller and flow untouched into the TRAP.
; ----------------------------------------------------------------------------
_KoshRmOne:
                TRAP    #TRAP_UNLINK
                RET



; ----------------------------------------------------------------------------
; .do_mkdir - create a directory.
;
;   Args: path   (e.g. "mkdir B:STUFF")
;
;   Thin wrapper over TRAP_MKDIR. No wildcard expansion (mkdir of a glob
;   makes no sense). Normalises the path (prepends "<CWD>:" if bare), then
;   the kernel parses drive + name and does the alloc/'.'/'..'/link work.
;   Output:
;     OK                 - on success
;     mkdir: <message>   - usage / failed (with [ERR_NAME $XXXX])
; ----------------------------------------------------------------------------
.do_mkdir:
                LEA     XY0, XY2
                CALL24  KLIB_STRLEN
                INC     XY0, #1

                ; Next token = path arg (quote-aware).
                CALL16  _KoshNextToken
                BCS     .mkdir_usage
                LEA     XY0, XY1                 ; XY0 = path arg (ASCIIZ)
.mkdir_have_path:

                ; New ABI (option b): sys_mkdir resolves the path itself,
                ; relative to the CWD. Pass raw path + CWD context; no
                ; drive-prepend (the resolver handles "X:" / "/" / relative).
                ;   XY0 = path arg, D0 = CWD drive index, D1 = CWD cluster.
                MOVE    Y1, Y3
                LOADI   X1, #KOSH_CWD
                LOADB   D0, [XY1]               ; CWD drive letter
                SUB     D0, #'A'                ; -> drive index
                LOADI   X1, #KOSH_CWD_CLU
                LOADD   D1, [XY1]               ; CWD cluster
                TRAP    #TRAP_MKDIR
                BCS     .mkdir_failed

                MOVE    Y0, Y3
                LOADI   X0, #msg_format_ok      ; shared "OK\n"
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.mkdir_usage:
                MOVE    Y0, Y3
                LOADI   X0, #msg_mkdir_usage
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.mkdir_failed:
                ; D0 = err code. _KoshPrintErr appends " [ERR_NAME $HHHH]\n".
                MOVE    Y0, Y3
                LOADI   X0, #msg_mkdir_failed
                CALL16  _KoshPrintErr
                BRA     .repl_loop


; ----------------------------------------------------------------------------
; .do_cd - change the current working directory.
;
;   Args: optional path. No arg -> root of current drive. "X:" / "/" /
;   relative all handled by the kernel resolver (sys_resolve).
;
;   Algorithm:
;     1. Skip the command word + whitespace to the arg.
;     2. No arg -> KOSH_CWD_CLU = 0 (root of current drive), done.
;     3. sys_resolve(path, CWD drive, CWD cluster) -> drive, cluster, attr.
;     4. attr must be a directory, else "cd: not a directory".
;     5. Store drive (as letter -> KOSH_CWD) + cluster (-> KOSH_CWD_CLU).
; ----------------------------------------------------------------------------
.do_cd:
                LEA     XY0, XY2
                CALL24  KLIB_STRLEN
                INC     XY0, #1
                ; Next token = optional path arg (quote-aware).
                CALL16  _KoshNextToken
                BCS     .cd_no_arg               ; no arg -> root of current drive
                LEA     XY0, XY1                 ; XY0 = path arg (ASCIIZ)
                LOADI   D0, #0                   ; Part 61: explicit cd - a
                STOREP  D0, Y3, [#CD_BARE]       ;   non-dir target IS an error
                BRA     .cd_resolve
.cd_no_arg:
                ; --- no arg: go to root of current drive ------------------
                LOADI   D0, #0
                MOVE    Y1, Y3
                LOADI   X1, #KOSH_CWD_CLU
                STORED  D0, [XY1]
                BRA     .repl_loop

.cd_resolve:
                ; XY0 = path arg. Load CWD context: D0 = drive idx, D1 = clu.
                ; (Stash path pointer; the CWD reads use XY1.)
                MOVE    Y1, Y3
                LOADI   X1, #KOSH_CWD
                LOADB   D0, [XY1]               ; CWD drive letter
                SUB     D0, #'A'                ; -> drive index
                LOADI   X1, #KOSH_CWD_CLU
                LOADD   D1, [XY1]               ; CWD cluster
                TRAP    #TRAP_RESOLVE           ; -> D0=drive,D1=clu,D2=attr
                BCS     .cd_failed

                ; --- must be a directory ----------------------------------
                ; (Hold D0=drive, D1=clu across the attr check via the test
                ; on D2 only.)
                MOVE    D3, D2                  ; D3 = attr (D2 may be clobbered)
                AND     D3, #DIR_ATTR_DIRECTORY
                BEQ     .cd_notdir

                ; --- store new CWD ----------------------------------------
                ; D0 = drive index -> letter into KOSH_CWD; D1 = cluster.
                ADD     D0, #'A'
                MOVE    Y1, Y3
                LOADI   X1, #KOSH_CWD
                STOREB  D0, [XY1]
                LOADI   X1, #KOSH_CWD_CLU
                STORED  D1, [XY1]
                BRA     .repl_loop

.cd_notdir:
                ; Part 61: a bare colon token that resolved to a FILE is an
                ; executable, not a failed cd. Resume the normal dispatch at
                ; .nds_nocolon: cmd_table can't match a token containing ':',
                ; so it falls to .unknown -> _KoshExecFile, which handles the
                ; '&' background suffix and the arg tail exactly as for any
                ; other command. XY2 still holds the command word - the CWD
                ; reads above used XY0/XY1, and TRAP_RESOLVE preserves XY2
                ; (callee-saved frame pointer in the V2 ABI).
                LOADP   D0, Y3, [#CD_BARE]
                CMP     D0, #0
                BNE     .nds_nocolon
                MOVE    Y0, Y3
                LOADI   X0, #msg_cd_notdir
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.cd_failed:
                ; D0 = err code.
                ; Part 61: ERR_NOTFOUND on a bare token also goes to the exec
                ; path - that is what makes the extension-less form work
                ; (`ram:hello` resolves to nothing, but _KoshExecFile retries
                ; as "hello.com"). A genuinely absent name then reports as an
                ; unknown command rather than a cd failure, which is the right
                ; register for something typed as a command. Other errors
                ; (ERR_BADDRIVE, ERR_BADPATH) keep the cd message: those are
                ; about the path itself and would only be obscured by a
                ; second, vaguer failure.
                MOVE    D3, D0                   ; keep err across the test
                LOADP   D0, Y3, [#CD_BARE]
                CMP     D0, #0
                BEQ     .cd_failed_report
                CMP     D3, #ERR_NOTFOUND
                BEQ     .nds_nocolon
.cd_failed_report:
                MOVE    D0, D3                   ; restore err for _KoshPrintErr
                MOVE    Y0, Y3
                LOADI   X0, #msg_cd_failed
                CALL16  _KoshPrintErr
                BRA     .repl_loop


; ----------------------------------------------------------------------------
; .do_pwd - print the current working directory.
;
;   sys_pwd reconstructs "X:/a/b/c" from (CWD drive, CWD cluster) into
;   ROW_BUF; then print it with a trailing newline.
; ----------------------------------------------------------------------------
.do_pwd:
                ; D0 = CWD drive idx, D1 = CWD cluster, XY0 = ROW_BUF dest.
                MOVE    Y1, Y3
                LOADI   X1, #KOSH_CWD
                LOADB   D0, [XY1]
                SUB     D0, #'A'
                LOADI   X1, #KOSH_CWD_CLU
                LOADD   D1, [XY1]
                MOVE    Y0, Y3
                LOADI   X0, #ROW_BUF
                TRAP    #TRAP_PWD
                BCS     .pwd_failed

                ; Append "\n" then print ROW_BUF. ROW_BUF holds "X:/..."\0;
                ; find the nul, write LF + nul, then puts.
                MOVE    Y0, Y3
                LOADI   X0, #ROW_BUF
                CALL24  KLIB_STRLEN             ; XY0 -> nul
                LOADI   D0, #CH_LF
                STOREB  D0, [XY0]+
                LOADI   D0, #0
                STOREB  D0, [XY0]
                MOVE    Y0, Y3
                LOADI   X0, #ROW_BUF
                CALL16  _KoshEmitPwdNamed
                CALL16  _KoshBlankLine
                BRA     .repl_loop

.pwd_failed:
                MOVE    Y0, Y3
                LOADI   X0, #msg_pwd_failed
                CALL16  _KoshPrintErr
                BRA     .repl_loop


; ----------------------------------------------------------------------------
; .do_assign - list / set / clear named-volume assigns (named drives v2).
;
;   assign               -> list every assign as "NAME: -> X:/backing/path"
;   assign NAME PATH      -> set (PATH resolved with CWD context; must be a dir)
;   assign NAME           -> clear
;
;   Set/clear mutate the kernel assign table via sys_assign (TRAP_ASSIGN);
;   the target path is resolved here via TRAP_RESOLVE. List reads the table
;   directly (kernel page $00) and reconstructs each backing path via sys_pwd.
; ----------------------------------------------------------------------------
.do_assign:
                LEA     XY0, XY2
                CALL24  KLIB_STRLEN
                INC     XY0, #1                 ; past verb nul -> args
                CALL16  _KoshNextToken          ; token1 = NAME
                BCS     .asn_list               ; no args -> list
                MOVE    D0, X1
                STOREP  D0, Y3, [#ASN_NAME_OFF] ; save name-token offset
                CALL16  _KoshNextToken          ; token2 = PATH
                BCS     .asn_clear              ; name only -> clear

                ; --- set: resolve PATH (CWD context), require a directory ---
                LEA     XY0, XY1                 ; XY0 = path token
                MOVE    Y1, Y3
                LOADI   X1, #KOSH_CWD
                LOADB   D0, [XY1]
                SUB     D0, #'A'                ; CWD drive index
                LOADI   X1, #KOSH_CWD_CLU
                LOADD   D1, [XY1]               ; CWD cluster
                TRAP    #TRAP_RESOLVE           ; -> D0=drive, D1=clu, D2=attr
                BCS     .asn_fail               ; resolve error (D0=err)
                MOVE    D3, D2
                AND     D3, #DIR_ATTR_DIRECTORY
                BEQ     .asn_notdir             ; target is a file
                ; sys_assign(set): XY0=name, D0=drive, D1=clu, D2=flags, D3=op
                LOADP   D3, Y3, [#ASN_NAME_OFF]
                MOVE    X0, D3
                MOVE    Y0, Y3                  ; XY0 = name (D0/D1 intact)
                LOADI   D2, #0                  ; flags = 0 (user assign)
                LOADI   D3, #0                  ; op = set
                TRAP    #TRAP_ASSIGN
                BCS     .asn_fail
                MOVE    Y0, Y3
                LOADI   X0, #msg_assign_ok
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.asn_clear:
                ; sys_assign(clear): XY0=name, op=1
                LOADP   D0, Y3, [#ASN_NAME_OFF]
                MOVE    X0, D0
                MOVE    Y0, Y3
                LOADI   D0, #0
                LOADI   D1, #0
                LOADI   D2, #0
                LOADI   D3, #1                  ; op = clear
                TRAP    #TRAP_ASSIGN
                BCS     .asn_fail
                MOVE    Y0, Y3
                LOADI   X0, #msg_assign_ok
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.asn_notdir:
                LOADI   D0, #ERR_NOTDIR
.asn_fail:
                MOVE    Y0, Y3
                LOADI   X0, #msg_assign_fail
                CALL16  _KoshPrintErr           ; prints "assign: failed [ERR $HHHH]"
                BRA     .repl_loop

.asn_list:
                LOADI   D3, #0                  ; entry index
.asn_l_loop:
                STOREP  D3, Y3, [#ASN_LIST_IDX]
                ; entry base = AS_TABLE_BASE + index*16 (kernel page $00)
                MOVE    D0, D3
                SHL4    D0
                ADD     D0, #AS_TABLE_BASE
                MOVE    X0, D0
                LOADI   Y0, #$00
                LOADB   D1, [XY0]               ; AS_NAME[0]
                AND     D1, #$FF
                BEQ     .asn_l_next             ; empty slot
                ; "  " indent (match ls)
                MOVE    Y0, Y3
                LOADI   X0, #msg_two_sp
                TRAP    #TRAP_PUTS
                ; NAME (page $00)
                LOADP   D3, Y3, [#ASN_LIST_IDX]
                MOVE    D0, D3
                SHL4    D0
                ADD     D0, #AS_TABLE_BASE
                MOVE    X0, D0
                LOADI   Y0, #$00
                TRAP    #TRAP_PUTS              ; "NAME"
                MOVE    Y0, Y3
                LOADI   X0, #msg_colon
                TRAP    #TRAP_PUTS              ; ":"
                ; namelen (cap 11) to align the "->" column
                LOADP   D3, Y3, [#ASN_LIST_IDX]
                MOVE    D0, D3
                SHL4    D0
                ADD     D0, #AS_TABLE_BASE
                MOVE    X0, D0
                LOADI   Y0, #$00
                LOADI   D2, #0
.asn_l_nlen:
                LOADB   D0, [XY0]+
                AND     D0, #$FF
                BEQ     .asn_l_nlend
                ADD     D2, #1
                CMP     D2, #11
                BLO     .asn_l_nlen
.asn_l_nlend:
                ; pad: msg_asn_pad + namelen -> emits (12 - namelen) spaces
                MOVE    Y0, Y3
                LOADI   X0, #msg_asn_pad
                ADD     X0, D2
                TRAP    #TRAP_PUTS
                MOVE    Y0, Y3
                LOADI   X0, #msg_assign_arrow   ; "-> "
                TRAP    #TRAP_PUTS
                ; backing path: sys_pwd(drive, cluster) -> ROW_BUF
                LOADP   D3, Y3, [#ASN_LIST_IDX]
                MOVE    D0, D3
                SHL4    D0
                ADD     D0, #AS_TABLE_BASE
                MOVE    X0, D0
                LOADI   Y0, #$00
                LOADB   D0, [XY0+#AS_FLAGS]     ; deleted backing? (dirty)
                AND     D0, #AS_FLAG_DIRTY
                BNE     .asn_l_deleted
                LOADB   D0, [XY0+#AS_DRIVE]
                AND     D0, #$FF
                LOADD   D1, [XY0+#AS_ROOTCLU]
                MOVE    Y0, Y3
                LOADI   X0, #ROW_BUF
                TRAP    #TRAP_PWD
                BCS     .asn_l_nl               ; couldn't rebuild -> bare newline
                MOVE    Y0, Y3
                LOADI   X0, #ROW_BUF
                CALL24  KLIB_STRLEN
                LOADI   D0, #CH_LF
                STOREB  D0, [XY0]+
                LOADI   D0, #0
                STOREB  D0, [XY0]
                MOVE    Y0, Y3
                LOADI   X0, #ROW_BUF
                TRAP    #TRAP_PUTS
                BRA     .asn_l_next
.asn_l_deleted:
                MOVE    Y0, Y3
                LOADI   X0, #msg_assign_deleted
                TRAP    #TRAP_PUTS
                BRA     .asn_l_next
.asn_l_nl:
                MOVE    Y0, Y3
                LOADI   X0, #msg_assign_nl
                TRAP    #TRAP_PUTS
.asn_l_next:
                LOADP   D3, Y3, [#ASN_LIST_IDX]
                ADD     D3, #1
                CMP     D3, #AS_MAX
                BLO     .asn_l_loop
                CALL16  _KoshBlankLine
                BRA     .repl_loop


; ----------------------------------------------------------------------------
; .do_rmdir - remove an empty directory.
;
;   Args: path (required). Resolve-aware + relative, like mkdir. The kernel
;   refuses non-directories (ERR_NOTDIR) and non-empty dirs (ERR_NOTEMPTY).
; ----------------------------------------------------------------------------
.do_rmdir:
                LEA     XY0, XY2
                CALL24  KLIB_STRLEN
                INC     XY0, #1
                ; Next token = path arg (quote-aware).
                CALL16  _KoshNextToken
                BCS     .rmdir_usage
                LEA     XY0, XY1                 ; XY0 = path arg (ASCIIZ)
.rmdir_have_path:

                ; XY0 = path; D0 = CWD drive idx, D1 = CWD cluster.
                MOVE    Y1, Y3
                LOADI   X1, #KOSH_CWD
                LOADB   D0, [XY1]
                SUB     D0, #'A'
                LOADI   X1, #KOSH_CWD_CLU
                LOADD   D1, [XY1]
                TRAP    #TRAP_RMDIR
                BCS     .rmdir_failed

                MOVE    Y0, Y3
                LOADI   X0, #msg_format_ok      ; shared "OK\n"
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.rmdir_usage:
                MOVE    Y0, Y3
                LOADI   X0, #msg_rmdir_usage
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.rmdir_failed:
                MOVE    Y0, Y3
                LOADI   X0, #msg_rmdir_failed
                CALL16  _KoshPrintErr
                BRA     .repl_loop



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
;   The CP_BUF scratch and CP_SRC_FD / CP_DST_FD slots are
;   shared with .do_cp (no concurrent use - kosh is single-task; the
;   slots are kosh-local).
;
;   Scratch additions: MV_SRC_PATH_TMP / MV_DST_PATH_TMP reuse the
;   CP_SRC_PATH / CP_DST_PATH slots - same purpose, same shape,
;   no need for new storage.
; ----------------------------------------------------------------------------
.do_mv:
                LEA     XY0, XY2
                CALL24  KLIB_STRLEN
                INC     XY0, #1

                ; --- src + dst tokens (quote-aware) ------------------------
                CALL16  _KoshNextToken           ; src
                BCS     .mv_usage
                MOVE    D0, X1
                STOREP  D0, Y3, [#CP_SRC_PATH]
                CALL16  _KoshNextToken           ; dst
                BCS     .mv_usage
                MOVE    D0, X1
                STOREP  D0, Y3, [#CP_DST_PATH]

.mv_dst_terminated:
                ; Does the SRC contain a wildcard?
                MOVE    Y0, Y3
                LOADP   D0, Y3, [#CP_SRC_PATH]
                MOVE    X0, D0
                CALL16  _KoshHasWildcard
                BCC     .mv_glob                ; C=0 -> wildcard src

                ; --- Literal path - Part 44 CWD-relative --------------------
                ; Raw src/dst pointers + CWD context. Resolve a directory dst
                ; to "<dst>/<src-basename>" (so "mv f b:/foo" lands in foo).
                CALL16  _KoshStashCwd
                CALL16  _KoshResolveDstPath
                BCS     .mv_report_err          ; Part 62: CP_ERR_TOOLONG

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
                CMP     D0, #CP_ERR_TOOLONG
                BEQ     .mv_toolong_msg
                CMP     D0, #MV_ERR_UNLINK
                BEQ     .mv_unlink_msg
                MOVE    Y0, Y3
                LOADI   X0, #msg_mv_failed
                CALL16  _KoshPrintErr
                BRA     .repl_loop

.mv_unlink_msg:
                ; Copy landed, source could not be removed - the file is at
                ; both ends. Print the REAL kernel code, not the sentinel.
                LOADP   D0, Y3, [#MV_UNLINK_ERR]
                MOVE    Y0, Y3
                LOADI   X0, #msg_mv_unlink_err
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

.mv_toolong_msg:
                MOVE    Y0, Y3
                LOADI   X0, #msg_path_toolong
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

; --- Glob path -------------------------------------------------------------
; mv <pattern> <destdrive>: - move each matching file to the dest drive,
; keeping its basename. Same dest rules as cp glob. Stop-on-error.
.mv_glob:
                ; Part 44 step 4: CP_CWD context for the bare src matches is set
                ; from the src split below (glob in CWD or, if prefixed, root).
                MOVE    Y0, Y3
                LOADP   D0, Y3, [#CP_DST_PATH]
                MOVE    X0, D0
                CALL16  _KoshHasWildcard
                BCC     .mv_glob_destwild

                ; Part 64 step 2: mirrors .cp_glob exactly - see the long
                ; comment there for why CP_CWD_* stays on the shell CWD and
                ; the source is rebuilt as a full path. It matters more here:
                ; TRAP_RENAME takes ONE (D1, D2) context for both of its
                ; paths, so a split context was never expressible.
                CALL16  _KoshStashCwd

                LOADP   D0, Y3, [#CP_DST_PATH]
                STOREP  D0, Y3, [#CP_GDST]

                MOVE    Y0, Y3
                MOVE    X0, D0                  ; XY0 = dst token
                LOADP   D0, Y3, [#CP_CWD_DRV]
                LOADP   D1, Y3, [#CP_CWD_CLU]
                TRAP    #TRAP_RESOLVE           ; -> D0=drive, D1=clu, D2=attr
                BCS     .mv_glob_dstmissing
                AND     D2, #DIR_ATTR_DIRECTORY
                BEQ     .mv_glob_dstnotdir

                MOVE    Y0, Y3
                LOADP   D0, Y3, [#CP_SRC_PATH]
                MOVE    X0, D0
                CALL16  _KoshSplitDirPat        ; D0=drv, D1=clu, D2=pfxlen, XY1=pat
                BCS     .mv_glob_srcdir
                STOREP  D0, Y3, [#GLOB_DRIVE]
                STOREP  D1, Y3, [#GLOB_CLU]
                MOVE    D0, X1
                STOREP  D0, Y3, [#GLOB_PATPTR]

                LOADP   D0, Y3, [#GLOB_PFXPTR]
                MOVE    Y0, Y3
                MOVE    X0, D0
                MOVE    Y1, Y3
                LOADI   X1, #KOSH_NORM_A
                MOVE    D0, D2                  ; count = prefix length
                LOADI   D1, #KOSH_NORM_LEN
                CALL16  _KoshCopyCounted
                BCS     .mv_glob_pathlong
                MOVE    D0, X1
                STOREP  D0, Y3, [#GLOB_NAMEOFF]
                STOREP  D1, Y3, [#GLOB_NAMECAP]

                LOADP   D2, Y3, [#GLOB_DRIVE]
                SHL4    D2
                SHL     D2
                SHL     D2
                ADD     D2, #VOL_TABLE_BASE
                LOADI   Y0, #$00
                MOVE    X0, D2
                ADD     X0, #VOL_ROOT_ENTRIES
                LOADD   D2, [XY0]

                ; Reserve stack table: bytes = root_entries * GLOB_ENTRY_SIZE.
                ; Part 64: GLOB_ENTRY_SIZE is 32, so this is SHL4 + SHL. The
                ; shift count IS GLOB_ENTRY_SHIFT; the symbol cannot be spelled
                ; in the operand, so keep the two in step by hand. Worst case
                ; is 256*32 = 8192 bytes - derivation in kosh_defs.inc.
                MOVE    D0, D2
                SHL4    D0                      ; *16
                SHL     D0                      ; *32 = GLOB_ENTRY_SIZE
                STOREP  D0, Y3, [#GLOB_RSVSIZE]
                SUB     X3, D0
                MOVE    D0, X3
                STOREP  D0, Y3, [#GLOB_TABLE]

                ; XY1 was consumed by the prefix copy; D2 still = root_entries.
                LOADP   D0, Y3, [#GLOB_PATPTR]
                MOVE    Y1, Y3
                MOVE    X1, D0
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

                CALL16  _KoshGlobEntryPtr       ; D0 = index -> D3 = entry offset
                STOREP  D3, Y3, [#CP_NAME]

                ; SRC = "<prefix><name>" in KOSH_NORM_A - see .cp_glob_iter.
                LOADP   D0, Y3, [#CP_NAME]
                MOVE    Y0, Y3
                MOVE    X0, D0
                LOADP   D0, Y3, [#GLOB_NAMEOFF]
                MOVE    Y1, Y3
                MOVE    X1, D0
                LOADP   D1, Y3, [#GLOB_NAMECAP]
                CALL16  _KoshCopyBounded
                BCS     .mv_glob_item_err
.mv_glob_srcdone:
                LOADI   D0, #KOSH_NORM_A
                STOREP  D0, Y3, [#CP_SRC_PATH]

                ; DST via _KoshResolveDstPath, same as the literal mv path.
                LOADP   D0, Y3, [#CP_GDST]
                STOREP  D0, Y3, [#CP_DST_PATH]
                CALL16  _KoshResolveDstPath     ; C=1 -> D0 = CP_ERR_TOOLONG
                BCS     .mv_glob_item_err
.mv_glob_dstdone:

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
                ; Part 62: hold the code in D3, NOT on the stack. The release
                ; below moves X3 past the pushed slot, so a PUSH/POP pair
                ; straddling it pops residue from the freed glob table - that
                ; is where the bogus "[ERR_UNKNOWN $253A]" came from. D3 is
                ; dead on entry (the worker clobbers it) and is restored
                ; before any TRAP that could touch it.
                MOVE    D3, D0
                LOADP   D0, Y3, [#GLOB_RSVSIZE]
                ADD     X3, D0
                MOVE    D0, D3
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
                CMP     D0, #MV_ERR_UNLINK
                BEQ     .mv_glob_item_unlink
                MOVE    Y0, Y3
                LOADI   X0, #msg_mv_failed
                CALL16  _KoshPrintErr
                BRA     .repl_loop
.mv_glob_item_unlink:
                ; Stop-on-error, as for any hard failure - but say which
                ; failure. The stack was released above, so reading
                ; MV_UNLINK_ERR here touches nothing that was freed.
                LOADP   D0, Y3, [#MV_UNLINK_ERR]
                MOVE    Y0, Y3
                LOADI   X0, #msg_mv_unlink_err
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

; As in .cp_glob: all four fire before the table is reserved, so none of
; them releases stack.
.mv_glob_dstmissing:
                MOVE    Y0, Y3
                LOADI   X0, #msg_glob_dstnotfound
                CALL16  _KoshPrintErr
                BRA     .repl_loop

.mv_glob_dstnotdir:
                MOVE    Y0, Y3
                LOADI   X0, #msg_glob_dstnotdir
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.mv_glob_srcdir:
                MOVE    Y0, Y3
                LOADI   X0, #msg_glob_srcdir
                CALL16  _KoshPrintErr
                BRA     .repl_loop

.mv_glob_pathlong:
                MOVE    Y0, Y3
                LOADI   X0, #msg_path_toolong
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
; _KoshMvOne - move one file. src in CP_SRC_PATH, dst in CP_DST_PATH
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
                LOADP   D0, Y3, [#CP_SRC_PATH]
                MOVE    X0, D0
                MOVE    Y1, Y3
                LOADP   D0, Y3, [#CP_DST_PATH]
                MOVE    X1, D0
                LOADP   D1, Y3, [#CP_CWD_CLU]   ; Part 44: CWD context
                LOADP   D2, Y3, [#CP_CWD_DRV]
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
                LOADP   D0, Y3, [#CP_SRC_PATH]
                MOVE    X0, D0
                LOADP   D1, Y3, [#CP_CWD_CLU]   ; Part 44: CWD context
                LOADP   D2, Y3, [#CP_CWD_DRV]
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
                ; success-with-note and (for globs) keeps going.
                CMP     D0, #ERR_READONLY
                BNE.S   .m1_unlink_hard
                LOADI   D0, #MV_WARN_ROSRC
                SEC
                RET

.m1_unlink_hard:
                ; Any other unlink error: the copy IS at the destination and
                ; the source is still there, so the file now exists at both
                ; ends. Part 64: raise a distinct sentinel rather than
                ; returning the raw code, which the reporters could not tell
                ; apart from an ordinary "the move never happened" failure.
                ; The raw code is stashed so the report can still name it.
                ; Y3 is the task page and _KoshMvOne preserves XY3, so a
                ; STOREP here is safe.
                STOREP  D0, Y3, [#MV_UNLINK_ERR]
                LOADI   D0, #MV_ERR_UNLINK
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
;     3. Point XY0 at LOAD_BASENAME; opens carry CWD context (D1/D2).
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
;   Reuses CP_BUF (512 B) for the read/write buffer. The destination
;   path is read in place from LINE_BUF via LOAD_BASENAME - no staging
;   buffer, so long names are not capped by KOSH_NORM_A's 16 bytes.
; ----------------------------------------------------------------------------
.do_load:
                ; --- Digital guard (Part 61) ------------------------------
                ; The host file bridge is EMU-only: _HostFOpen rejects
                ; HOST_DIGITAL with ERR_INVALID before touching MMIO. The
                ; Part 57 boot cascade runs A:STARTUP.KSH on every target,
                ; and that script carries `load ramdisk/...` lines, so on
                ; Digital return silently rather than printing a failure per
                ; line at boot. Interactive `load` on Digital is likewise a
                ; no-op, which is honest - there is no host to load from.
                LOADZ   D0, [#KOS_HOST]
                LOW     D0
                CMP     D0, #HOST_DIGITAL
                BEQ     .repl_loop

                LEA     XY0, XY2
                CALL24  KLIB_STRLEN
                INC     XY0, #1

                ; Name token (quote-aware -> spaced host filenames OK).
                ; Default: no -f.
                LOADI   D2, #0
                STOREP  D2, Y3, [#LOAD_FORCE]
                CALL16  _KoshNextToken
                BCS     .load_usage
                ; XY1 = name (ASCIIZ); XY0 = cursor past name -> scan for -f.
                ; Stash the name offset for the dest-path build below.
                MOVE    D0, X1
                STOREP  D0, Y3, [#LOAD_NAME]

                ; --- Host-folder prefix split (Part 61) -------------------
                ; The token may carry a host-folder prefix:
                ;     load zork.com            -> uploads folder
                ;     load ramdisk/zork.com    -> system/ramdisk folder
                ; LOAD_NAME keeps the FULL token - EMULIB_HOST_FOPEN needs
                ; the prefix to pick the folder. LOAD_BASENAME points at the
                ; last component only and is what the K16-side open uses;
                ; without the split the resolver reads '/' as a k/OS
                ; separator and tries to create the file inside a
                ; nonexistent "ramdisk" directory on the destination drive.
                ; Walk to nul, tracking the offset just past the last '/'.
                ; With no '/' present, LOAD_BASENAME == LOAD_NAME.
                ; Walk XY1, NOT XY0: _KoshNextToken left XY0 as the cursor
                ; past the name and .load_scan_flag below consumes it. XY1
                ; (the name pointer) is dead after the MOVE D0, X1 above.
                MOVE    D2, D0                  ; D2 = basename offset so far
                MOVE    Y1, Y3
                MOVE    X1, D0                  ; XY1 = token cursor
.load_base_scan:
                LOADB   D0, [XY1]               ; flag-transparent - CMP below
                CMP     D0, #0
                BEQ     .load_base_done
                INC     XY1, #1
                CMP     D0, #'/'
                BNE     .load_base_scan
                MOVE    D2, X1                  ; char after '/' = new base
                BRA     .load_base_scan
.load_base_done:
                STOREP  D2, Y3, [#LOAD_BASENAME]

.load_scan_flag:
                LOADB   D0, [XY0]
                CMP     D0, #0
                BEQ     .load_name_terminated
                CMP     D0, #CH_SPACE
                BEQ.S   .load_scan_skip
                CMP     D0, #'-'
                BNE.S   .load_scan_skip         ; ignore unknown tokens
                ; '-' - check next char for 'f' or 'F'.
                INC     XY0, #1
                LOADB   D0, [XY0]
                CMP     D0, #'f'
                BEQ.S   .load_set_force
                CMP     D0, #'F'
                BNE.S   .load_scan_skip
.load_set_force:
                LOADI   D0, #1
                STOREP  D0, Y3, [#LOAD_FORCE]
.load_scan_skip:
                INC     XY0, #1
                BRA     .load_scan_flag

.load_name_terminated:
                ; Restore XY0 = name ptr (saved in LOAD_NAME above).
                MOVE    Y0, Y3
                LOADP   D0, Y3, [#LOAD_NAME]
                MOVE    X0, D0

                ; --- _HostFOpen(name) -> file size in D0 -------------------
                ; (XY0 already points at the name in the line buffer.)
                CALL24  EMULIB_HOST_FOPEN
                BCS     .load_fopen_err

                ; Save file size (32-bit, Part 26) for the success message
                ; and the short-copy check at .load_eof.
                STOREP  D0, Y3, [#LOAD_SIZE_LO]
                STOREP  D1, Y3, [#LOAD_SIZE_HI]

                ; --- Destination path = LOAD_BASENAME, in place ----------
                ; Part 61: LOAD_BASENAME, not LOAD_NAME - the host-folder
                ; prefix must not reach the K16 destination path.
                ; Part 62: no _KoshNormPath. That helper prepends
                ; "<KOSH_CWD>:", and a leading "X:" tells the resolver to
                ; start at cluster 0 (see _KoshSplitDrivePat), which forced
                ; every load into the drive root. The bare basename plus
                ; CWD context in D1/D2 resolves inside the current
                ; directory; a name that carries its own "X:" still goes to
                ; that drive's root, matching every other command.
                MOVE    Y0, Y3
                LOADP   D0, Y3, [#LOAD_BASENAME]
                MOVE    X0, D0

                ; --- If not -f, check whether dest already exists ---------
                LOADP   D0, Y3, [#LOAD_FORCE]
                CMP     D0, #0
                BNE     .load_open_dest_for_write

                ; Probe sys_open(dest, READ). On success, dest exists -> refuse.
                ; XY0 still points at the basename in LINE_BUF.
                ; Part 62: CWD context (D1 = cluster, D2 = drive index).
                MOVE    Y1, Y3
                LOADI   X1, #KOSH_CWD
                LOADB   D2, [XY1]               ; CWD drive letter
                SUB     D2, #'A'                ; -> drive index 0..5
                LOADI   X1, #KOSH_CWD_CLU
                LOADD   D1, [XY1]               ; CWD cluster (0 = root)
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
                ; Rebuild XY0 from LOAD_BASENAME (sys_open may have
                ; clobbered it). Part 62: CWD context in D1/D2.
                MOVE    Y0, Y3
                LOADP   D0, Y3, [#LOAD_BASENAME]
                MOVE    X0, D0
                MOVE    Y1, Y3
                LOADI   X1, #KOSH_CWD
                LOADB   D2, [XY1]               ; CWD drive letter
                SUB     D2, #'A'                ; -> drive index 0..5
                LOADI   X1, #KOSH_CWD_CLU
                LOADD   D1, [XY1]               ; CWD cluster (0 = root)
                LOADI   D0, #OPEN_FLAGS_NEW         ; CREATE | WRITE | TRUNC
                TRAP    #TRAP_OPEN
                BCS     .load_create_err

                STOREP  D0, Y3, [#LOAD_DST_FD]

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
                LOADP   D0, Y3, [#LOAD_DST_FD]
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
                LOADP   D0, Y3, [#LOAD_DST_FD]
                TRAP    #TRAP_CLOSE
                CALL24  EMULIB_HOST_FCLOSE

                ; --- Integrity: host size vs bytes actually written -------
                ; Part 26. A silent short copy is invisible until something
                ; downstream fails a checksum, three layers from the cause.
                ; Compare here, where the cause is still in view.
                LOADP   D0, Y3, [#LOAD_WRITTEN_LO]
                LOADP   D1, Y3, [#LOAD_SIZE_LO]
                CMP     D0, D1
                BNE     .load_short_copy
                LOADP   D0, Y3, [#LOAD_WRITTEN_HI]
                LOADP   D1, Y3, [#LOAD_SIZE_HI]
                CMP     D0, D1
                BNE     .load_short_copy

                ; --- Print "loaded <N> bytes\n" --------------------------
                ; Build in ROW_BUF: "loaded " + dec32(N) + " bytes\n\0"
                MOVE    Y1, Y3
                LOADI   X1, #ROW_BUF

                ; Emit "loaded " prefix.
                MOVE    Y0, Y3
                LOADI   X0, #msg_load_ok
                CALL16  _KoshEmitStrZ

                ; Emit decimal byte count (32-bit: an 85 KB story overflows
                ; the old 16-bit _KoshEmitDec).
                LOADP   D0, Y3, [#LOAD_WRITTEN_LO]
                LOADP   D1, Y3, [#LOAD_WRITTEN_HI]
                CALL16  _KoshEmitDec32

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

.load_short_copy:
                ; Part 26. Everything is already closed by .load_eof; this
                ; arm only reports. "load: short copy - wrote N of M bytes".
                MOVE    Y1, Y3
                LOADI   X1, #ROW_BUF
                MOVE    Y0, Y3
                LOADI   X0, #msg_load_short_copy
                CALL16  _KoshEmitStrZ
                LOADP   D0, Y3, [#LOAD_WRITTEN_LO]
                LOADP   D1, Y3, [#LOAD_WRITTEN_HI]
                CALL16  _KoshEmitDec32
                MOVE    Y0, Y3
                LOADI   X0, #msg_load_of
                CALL16  _KoshEmitStrZ
                LOADP   D0, Y3, [#LOAD_SIZE_LO]
                LOADP   D1, Y3, [#LOAD_SIZE_HI]
                CALL16  _KoshEmitDec32
                MOVE    Y0, Y3
                LOADI   X0, #msg_load_bytes
                CALL16  _KoshEmitStrZ
                LOADI   D0, #0
                CALL16  _KoshEmitByte
                MOVE    Y0, Y3
                LOADI   X0, #ROW_BUF
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

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
                LOADP   D0, Y3, [#LOAD_DST_FD]
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
                STOREP  D0, Y3, [#LOAD_ERR]

                ; Add partial-chunk count (D1) to cumulative.
                LOADP   D0, Y3, [#LOAD_WRITTEN_LO]
                ADD     D0, D1
                STOREP  D0, Y3, [#LOAD_WRITTEN_LO]
                LOADP   D0, Y3, [#LOAD_WRITTEN_HI]
                ADC     D0, #0
                STOREP  D0, Y3, [#LOAD_WRITTEN_HI]

                ; Close the destination file (truncated to whatever made it).
                LOADP   D0, Y3, [#LOAD_DST_FD]
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
                LOADP   D0, Y3, [#LOAD_ERR]
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
                LOADP   D0, Y3, [#LOAD_DST_FD]
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
msg_vol_hdr:       .TEXT "Drive  Label       Name        Total     Used     Free Use%\n",0
msg_two_sp:        .TEXT "  ",0
msg_vol_unmounted: .TEXT "(not mounted)",0
; 28 May 2026 - distinguish "bay bound but image is not formatted FAT16"
; from "no bay bound at all". Emitted as: "(unformatted: <name>)" so the
; user sees both the state and which disk file is bound. Two halves
; because the basename is inserted between them at runtime.
msg_vol_unfmt_pre: .TEXT "(unformatted: ",0
msg_vol_unfmt_post: .TEXT ")",0

; --- ls --------------------------------------------------------------------
msg_ls_usage:     .TEXT  "usage: ls [path][pattern]  e.g. ls  ls FOO  ls *.COM\n",0
msg_ls_notdir:    .TEXT  "ls: not a directory\n",0
msg_ls_failed:    .TEXT  "ls: failed",0
msg_cnt_file:     .TEXT  "file",0
msg_cnt_files:    .TEXT  "files",0
msg_cnt_dir:      .TEXT  "dir",0
msg_cnt_dirs:     .TEXT  "dirs",0
msg_ls_used:      .TEXT  "used\n",0
msg_ls_free:      .TEXT  "free\n",0
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
msg_path_toolong:    .TEXT "path too long\n",0
msg_cp_writeerr:     .TEXT "cp: write error",0
msg_cp_ok:           .TEXT "OK\n",0

; --- rm --------------------------------------------------------------------
msg_rm_usage:        .TEXT "usage: rm <path>     e.g. rm B:HELLO.COM  rm *.TMP\n",0
msg_rm_failed:       .TEXT "rm: failed",0

; --- mkdir -----------------------------------------------------------------
msg_mkdir_usage:     .TEXT "usage: mkdir <path>     e.g. mkdir B:STUFF\n",0
msg_mkdir_failed:    .TEXT "mkdir: failed",0
msg_cd_notdir:       .TEXT "cd: not a directory\n",0
msg_cd_failed:       .TEXT "cd: failed",0
msg_pwd_failed:      .TEXT "pwd: failed",0
msg_rmdir_usage:     .TEXT "usage: rmdir <path>     e.g. rmdir B:STUFF\n",0
msg_rmdir_failed:    .TEXT "rmdir: failed",0

; --- wildcard glob (Part 37) -----------------------------------------------
msg_glob_nomatch:    .TEXT "no matches\n",0
msg_glob_toomany:    .TEXT "too many matches; refine pattern\n",0
msg_glob_removed:    .TEXT " removed\n",0
msg_glob_destwild:   .TEXT "destination cannot contain wildcards\n",0
; Part 64 step 2: two strings deleted with the rules they enforced.
;   msg_glob_multidest ("multiple sources need a drive target") went with
;     the bare-"X:" destination requirement - any directory is valid now.
;   msg_glob_drivewild ("drive letter cannot be a wildcard") was reachable
;     only from the four .*_glob_baddrv arms. A bad drive now comes back
;     from sys_resolve as a real ERR_BADDRIVE and prints through
;     msg_glob_srcdir with the code attached, which says more.
; Both verified to have zero live references before removal, per the
; Part 37 string-cleanup practice recorded in the r22 note above.
; NOT deleted: msg_mv_unlink_err and msg_run_waiterr. Neither is dead
; weight - each names a real outcome that its handler currently reports as
; something else. See the Part 64 handover; wiring them is a behaviour
; change, not a sweep.
msg_glob_dstnotdir:  .TEXT "destination is not a directory\n",0
msg_glob_dstnotfound: .TEXT "destination directory not found",0
msg_glob_srcdir:     .TEXT "bad source directory",0
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
msg_load_short_copy:    .TEXT "load: short copy - wrote ",0
msg_load_of:            .TEXT " of ",0
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
cmd_mkdir_str:    .TEXT  "mkdir",0
cmd_cd_str:       .TEXT  "cd",0
cmd_pwd_str:      .TEXT  "pwd",0
cmd_rmdir_str:    .TEXT  "rmdir",0
cmd_assign_str:   .TEXT  "assign",0
msg_assign_arrow: .TEXT  "-> ",0
msg_asn_pad:      .TEXT  "            ",0
msg_assign_deleted: .TEXT "[deleted]\n",0
msg_assign_ok:    .TEXT  "OK\n",0
msg_assign_fail:  .TEXT  "assign: failed",0
msg_assign_nl:    .TEXT  "\n",0
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
; _KoshEmitDec32 - append decimal text of D1:D0 (unsigned 32) at the cursor.
;
;   In:       D0 = value low, D1 = value high
;             XY1 = cursor
;   Out:      digits stored at [XY1]; XY1 advanced past them; KLIB_UTOA32
;             writes a nul at the new position (harmless - overwritten by
;             the next emit, or kept if you nul-terminate as part of build)
;   Clobbers: D0, D1, D2, D3
;   Preserves: XY0, XY2, XY3
;
;   Twin of _KoshEmitDec for values above 64 KB (Part 26 - file sizes).
;   Same XY1<->XY0 bridge, two LEAs. Unlike _KoshEmitDec this CANNOT
;   preserve D1/D2/D3: D1 is an input and KLIB_UTOA32 clobbers D1..D3.
;   Callers needing a value across this call must stash it in a page-$00
;   slot, not a register.
; ----------------------------------------------------------------------------
_KoshEmitDec32:
                PUSH    XY0, XY3

                LEA     XY0, XY1                ; XY0 = cursor
                CALL24  KLIB_UTOA32             ; advances XY0, writes nul
                LEA     XY1, XY0                ; XY1 = advanced cursor

                POP     XY0, XY3
                RET

; ----------------------------------------------------------------------------
; _KoshEmitDecL - emit unsigned D0 as decimal at the ROW_BUF cursor XY1,
;   LEFT-aligned in a field of width D2 (padded on the RIGHT with spaces).
;   A number wider than D2 overflows the field (no clipping). Advances XY1.
;   Clobbers D0, D1, D2, D3.
; ----------------------------------------------------------------------------
_KoshEmitDecL:
                MOVE    D3, D2                  ; D3 = field width
                MOVE    D1, X1                  ; D1 = cursor offset before emit
                CALL16  _KoshEmitDec            ; emit digits (preserves D1/D2/D3)
                MOVE    D0, X1
                SUB     D0, D1                  ; D0 = digits emitted
                MOVE    D2, D3
                SUB     D2, D0                  ; D2 = pad = width - digits (C=0 if wider)
                BCC     .kdl_done               ; number wider than field -> no pad
.kdl_pad:
                CMP     D2, #0
                BEQ     .kdl_done
                LOADI   D0, #CH_SPACE
                CALL16  _KoshEmitByte           ; preserves D2/D3, advances XY1
                SUB     D2, #1
                BRA     .kdl_pad
.kdl_done:
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
                LOADB   D0, [XY0]+
                CMP     D0, #0
                BEQ     .es_done
                STOREB  D0, [XY1]+
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
                LOADB   D0, [XY0]+
                CMP     D0, #0
                BEQ     .enp_pad
                STOREB  D0, [XY1]+
                SUB     D1, #1
                BRA     .enp_copy_loop
.enp_pad:
                ; Source ended; pad remaining cols with spaces.
                CMP     D1, #0
                BEQ     .enp_done
                LOADI   D0, #' '
                STOREB  D0, [XY1]+
                SUB     D1, #1
                BRA     .enp_pad
.enp_done:
                POP     D1, XY3
                POP     XY0, XY3
                RET


; ----------------------------------------------------------------------------
; _KoshEmitNameLong - emit a zstring at XY0 in FULL (no truncation), then
;   space-pad to a MINIMUM of D2 columns. Unlike _KoshEmitNamePadded, a source
;   longer than D2 is emitted whole and overflows the field. Used by `ls` so
;   VFAT long names (up to 31 chars) display in full while short 8.3 names
;   still align to the 12-column field.
;
;   In:       XY0 = source zstring (in caller's page)
;             XY1 = cursor
;             D2  = minimum field width (1..255)
;   Out:      Source bytes up to its nul, then spaces to reach >= D2 columns.
;             XY1 advanced by max(strlen, D2).
;   Clobbers: D0
;   Preserves: D1, D2, D3, XY0, XY2, XY3
; ----------------------------------------------------------------------------
_KoshEmitNameLong:
                PUSH    XY0, XY3
                PUSH    D1, XY3

                MOVE    D1, D2                  ; D1 = columns still owed to width
.enl_copy_loop:
                LOADB   D0, [XY0]+
                CMP     D0, #0
                BEQ     .enl_pad
                STOREB  D0, [XY1]+
                CMP     D1, #0
                BEQ     .enl_copy_loop          ; width met; keep emitting overflow
                SUB     D1, #1
                BRA     .enl_copy_loop
.enl_pad:
                CMP     D1, #0
                BEQ     .enl_done
                LOADI   D0, #' '
                STOREB  D0, [XY1]+
                SUB     D1, #1
                BRA     .enl_pad
.enl_done:
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
;        VOL_FREE / VOL_TOTAL / VOL_CLSZ).
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
                ; Stash drive index in DISK_DRIVE - needed across multiple
                ; CALL24s below.
                STOREP  D0, Y3, [#DISK_DRIVE]

                ; Build line cursor in ROW_BUF.
                MOVE    Y1, Y3
                LOADI   X1, #ROW_BUF

                ; --- col0 Drive: "X:     " (7 chars) ----------------------
                LOADP   D0, Y3, [#DISK_DRIVE]
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
                LOADP   D0, Y3, [#DISK_DRIVE]
                TRAP    #TRAP_DISKFREE
                BCS     .pvl_unmounted
                ; D0=free, D1=total, D2=cluster_sz.
                STOREP  D0, Y3, [#VOL_FREE]
                STOREP  D1, Y3, [#VOL_TOTAL]
                STOREP  D2, Y3, [#VOL_CLSZ]

                ; --- col1 Label: 11-byte VOL_LABEL + 1 space (12 chars) --
                ; Compute slot offset = drive x 64 + VOL_TABLE_BASE.
                ; x64 = x16 (SHL4) + x2 + x2: 3 instructions vs 6.
                LOADP   D2, Y3, [#DISK_DRIVE]
                SHL4    D2                      ; x16
                SHL     D2                      ; x32
                SHL     D2                      ; x64
                ADD     D2, #VOL_TABLE_BASE

                LOADI   Y0, #$00
                MOVE    X0, D2
                ADD     X0, #VOL_LABEL
                LOADI   D1, #11
.pvl_lbl_loop:
                LOADB   D0, [XY0]+
                STOREB  D0, [XY1]+
                SUB     D1, #1
                BNE     .pvl_lbl_loop
                ; One separator space -> col1 total width 12
                LOADI   D0, #' '
                CALL16  _KoshEmitByte

                ; --- Name: "NAME:" padded to 9 (blank if no volume) -------
                LOADP   D0, Y3, [#DISK_DRIVE]
                LOADI   D2, #9
                CALL16  _KoshEmitVolName

                ; --- col2 Total: total_clusters * cluster_sz, 9-wide -----
                ; Part 26: cell is 9 with NO trailing separator, was 8+1.
                ; KB gained two decimals, and the KB unit's whole part runs
                ; to 1023, so "1023.99KB" is 9 chars -- an 8-wide cell clips
                ; it from the right to "1023.99K". Reachable on any volume of
                ; 1,047,552..1,048,575 bytes, i.e. a 1 MB RAM disk. Row length
                ; and the header literal are unchanged.
                LOADP   D0, Y3, [#VOL_TOTAL]
                LOADP   D1, Y3, [#VOL_CLSZ]
                CALL24  KLIB_MUL16x16_32        ; D1:D0 = total bytes
                LOADI   D2, #9                  ; col2 = 9 chars

                ; --- col3 Used: (total-free)*cluster_sz, 9-wide ---------
                LOADP   D0, Y3, [#VOL_TOTAL]
                LOADP   D1, Y3, [#VOL_FREE]
                SUB     D0, D1                  ; D0 = used clusters
                LOADP   D1, Y3, [#VOL_CLSZ]
                CALL24  KLIB_MUL16x16_32        ; D1:D0 = used bytes
                LOADI   D2, #9
                CALL16  _KoshEmitSize

                ; --- col4 Free: free * cluster_sz, 9-wide ---------------
                LOADP   D0, Y3, [#VOL_FREE]
                LOADP   D1, Y3, [#VOL_CLSZ]
                CALL24  KLIB_MUL16x16_32        ; D1:D0 = free bytes
                LOADI   D2, #9
                CALL16  _KoshEmitSize

                ; --- col5 Use%: (used*100) / total, 4-wide value + '%' --
                ; Compute used = total - free.
                LOADP   D0, Y3, [#VOL_TOTAL]
                LOADP   D1, Y3, [#VOL_FREE]
                SUB     D0, D1                  ; D0 = used clusters
                ; D1:D0 = used * 100 (32-bit)
                LOADI   D1, #100
                CALL24  KLIB_MUL16x16_32        ; D1:D0 = used*100
                ; Divide by total clusters.
                LOADP   D2, Y3, [#VOL_TOTAL]
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
                STOREB  D0, [XY1]+
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
                LOADB   D0, [XY0]+
                STOREB  D0, [XY1]+
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
                LOADP   D0, Y3, [#DISK_DRIVE]
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


; ----------------------------------------------------------------------------
; _KoshEmitVolName - append " NAME:" for a drive's named volume, if any.
;   Scans the kernel assign table (page $00) for a RootClu-0 entry whose
;   AS_DRIVE == D0; on a hit, emits a separator space, the name, and ':'
;   into the ROW_BUF cursor. Display-only - no resolution effect. Emits
;   nothing if the drive has no named volume (path-mounts, RootClu<>0, are
;   not volumes and are skipped).
;
;   In:    D0  = drive index
;          XY1 = ROW_BUF cursor (X1=offset, Y1=Y3)
;   Out:   XY1 advanced past any emitted text
;   Clobbers: D0, D1, D2, D3, X0, Y0, flags
;   Preserves: Y1, XY2, XY3
; ----------------------------------------------------------------------------
; ----------------------------------------------------------------------------
; _KoshEmitVolName - emit the drive's volume name "NAME:" as a fixed-width
;   column at the ROW_BUF cursor, space-padded to D2 columns. Blank (D2 spaces)
;   if the drive has no RootClu-0 named volume. A name+colon wider than D2
;   overflows (no truncation).
;   In:    D0 = drive index, XY1 = cursor, D2 = field width
;   Out:   XY1 advanced by >= D2
;   Clobbers: D0, D1, D2, D3, X0, Y0
; ----------------------------------------------------------------------------
_KoshEmitVolName:
                PUSH    D2, XY3                 ; save field width
                MOVE    D3, D0                  ; D3 = target drive
                LOADI   D2, #AS_MAX             ; entries to scan
                LOADI   X0, #AS_TABLE_BASE
                LOADI   Y0, #$00                ; assign table = kernel page $00
.kevn_loop:
                LOADB   D0, [XY0]               ; AS_NAME[0]
                AND     D0, #$FF
                BEQ     .kevn_next              ; empty entry
                LOADD   D1, [XY0+#AS_ROOTCLU]   ; 0 = named volume
                CMP     D1, #0
                BNE     .kevn_next              ; path-mount -> skip
                LOADB   D1, [XY0+#AS_DRIVE]
                AND     D1, #$FF
                CMP     D1, D3
                BEQ     .kevn_hit
.kevn_next:
                ADD     X0, #AS_ENTRY_SIZE
                SUB     D2, #1
                BNE     .kevn_loop
                ; no named volume -> emit a blank field
                POP     D1, XY3                 ; D1 = field width
.kevn_padonly:
                CMP     D1, #0
                BEQ     .kevn_done
                LOADI   D0, #' '
                STOREB  D0, [XY1]+
                SUB     D1, #1
                BRA     .kevn_padonly
.kevn_done:
                RET
.kevn_hit:
                ; X0 = AS_NAME (Y0=0). Emit "NAME:" (name cap 11) then pad.
                POP     D1, XY3                 ; D1 = field width
                LOADI   D2, #0                  ; D2 = chars emitted
                LOADI   D3, #11                 ; name char cap
.kevn_cpy:
                LOADB   D0, [XY0]+
                AND     D0, #$FF
                BEQ     .kevn_colon
                STOREB  D0, [XY1]+
                ADD     D2, #1
                SUB     D3, #1
                BNE     .kevn_cpy
.kevn_colon:
                LOADI   D0, #':'
                STOREB  D0, [XY1]+
                ADD     D2, #1
.kevn_pad:
                CMP     D2, D1
                BHS     .kevn_done              ; emitted >= width -> stop
                LOADI   D0, #' '
                STOREB  D0, [XY1]+
                ADD     D2, #1
                BRA     .kevn_pad


; ============================================================================
; End of kosh_cmds_fs.asm
; ============================================================================
