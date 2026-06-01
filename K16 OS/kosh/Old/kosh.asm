; ============================================================================
; kosh.asm - kosh interactive shell (k/OS Phase 16.7+)
; ============================================================================
; Date:    29 May 2026
; Status:  Part 38 - cleanup: READEOF.COM boot scaffolding removed
; Revision: r38 - 29 May 2026 - Part 38: removed dead Phase-19 READ_EOF.COM
;             boot scaffolding (8 May 2026 sys_read post-EOF diagnostic,
;             long since resolved). Deletions:
;               - .pop_re_create / .pop_re_done populate block (was creating
;                 B:READEOF.COM on every boot if missing).
;               - boot_readeof_path string ("B:READEOF.COM",0).
;               - read_eof_com_image 118-byte blob + read_eof_com_image_end
;                 label (Test_min_inter.hex image).
;             No live references; ~150 bytes of ROM reclaimed and the stray
;             READEOF.COM no longer appears on B: (wildcard ls/rm would have
;             listed/matched it).
;
; Revision: r37 - 18 May 2026 - Part 34: page-$00 scratch additions:
;               VOL_FREE_TMP   ($45FA) - free clusters per row
;               VOL_TOTAL_TMP  ($45FC) - total clusters per row
;               SIZE_FMT_BUF   ($45FE..$460D) - 16-byte work area used by
;                                   _KoshEmitSize (kosh_helpers.asm r3) to
;                                   build human-readable size strings
;                                   before right-aligning into ROW_BUF.
;               VOL_CLSZ_TMP   ($460E) - cluster size in bytes
;               LOAD_WRITTEN_LO/HI ($4610/$4612) - 32-bit cumulative for the
;                                   load command's partial-write report
;                                   (Part 34 sys_write returns D1=partial
;                                   on error; combining with this counter
;                                   gives the real on-disk size).
;             No code change in this file; just slot declarations.
;
; Revision: r36 - 14 May 2026 - k/OS Part 30 hygiene: removed dead
;             msg_prompt string ("$ " from before the dynamic "B:$ "
;             CWD prompt landed). Zero call sites in the codebase.
;
; Revision: r35 - 14 May 2026 - k/OS Part 30 cleanup: OS splash relocated
;             from kernel into kosh.
;             - kosh_entry: replaced the two-line "k/OS shell" /
;               "kosh v0.8 - type 'help'" emission with CALL24 _OSSplash
;               followed by the existing two-line banner. _OSSplash
;               (kosh_splash.asm r1) clears the screen, paints the
;               4-line logo + 6 info lines (Host/Kernel/Heap/Pages/
;               Tasks/Boot) + closing rule. All via TRAP_PUTS/PUTDEC/
;               PUTCHAR/CLEAR so output routes through the shell
;               back-buffer and survives foreground switching.
;             - _P2Main: removed the "k/OS Phase 16.7 - kosh" boot
;               banner emission (the content now lives implicitly in
;               kosh's own splash). Added "Loading k/OS shell ..."
;               trace line via _RawPuts just before JMP24 _RestoreIdle.
;               Auto-format step retained verbatim - _FormatVolume must
;               run in kernel context (Y3=$00) so this stays in _P2Main.
;             - boot_banner string removed; boot_shell_ok added.
;             - New .INCLUDE "../kosh/kosh_splash.asm".
;             Requires kos_boot.asm r44+, kosh_splash.asm r1+,
;             kos_rawio.asm r8+. kos_splash.asm deleted from the
;             kernel.
;
; Revision: r34 - 13 May 2026 - Phase B Step 1: register as shell.
;             Added TRAP #TRAP_REGISTER_SHELL call at the top of
;             kosh_entry, before banner emission. This allocates a
;             2400-byte back-buffer, sets TF_HAS_BACKBUF in kosh's TCB,
;             links kosh into the shell ring (singleton self-loop), and
;             makes kosh's TID the value of FOREGROUND_TCB. No
;             observable behaviour change yet - output routing arrives
;             in Phase B Step 3. Defensive halt on failure (cannot
;             happen at boot: heap is empty, plenty of space).
;             Requires kos_defs.inc r34+ and kos_switcher.asm r1+.
;
; Revision: r33 - 12 May 2026 - Part 28: TF_SYSCRITICAL on self.
;             At the kosh build site, the TCB_FLAGS write now sets both
;             TF_PRIV (existing) and TF_SYSCRITICAL (new). No other task
;             can sys_kill kosh, even a future privileged peer. The
;             existing victim==caller refusal in sys_kill still prevents
;             kosh from killing itself via `kill 1`. Requires
;             kos_defs.inc r32+ for the TF_SYSCRITICAL constant.
;
; Revision: r32 - 12 May 2026 - Part 20: kosh `kill` command.
;             Added dispatch entry (tag 31, .do_kill) and cmd_kill_str
;             into cmd_table. Body lives in kosh_cmds_sys.asm r6+.
;             Also added err_name_perm and err_name_busy strings plus
;             their entries in err_name_table for nicer error printing
;             on TRAP_KILL failures (ERR_PERM, ERR_BUSY, ERR_INVALID,
;             ERR_NOTFOUND).
;
; Revision: r31 - 12 May 2026 - Part 20 sys_kill plumbing.
;             After _BuildTask returns kosh's TCB ptr, set TF_PRIV in
;             TCB_FLAGS so sys_kill can recognise kosh as privileged
;             (may kill any task; non-privileged tasks may kill only
;             their own children). Done at the kosh build site -
;             no other task is currently privileged. Requires
;             kos_defs.inc r29+ for the TF_PRIV constant.
;
; Revision: r30 - 12 May 2026 - Part 20 syscall renumber.
;             HELLO.COM image (hello_com_image) had two hardcoded TRAP
;             instruction words that encode the TRAP number directly
;             ($F000 | (n*2)). These can't reference TRAP_* symbols
;             because the encoded word IS the data being emitted.
;             Updated:
;                 $F018 -> $F01A   (PUTLN: TRAP #12 -> TRAP #13)
;                 $F020 -> $F036   (EXIT:  TRAP #16 -> TRAP #27)
;             Plus updated comments. Requires kos_defs.inc r28+.
;             No other source change in this file - every other TRAP
;             usage goes through TRAP_* symbolic names.
;
; Revision: r29 - 11 May 2026 - Part 25 r6: load command.
;             • cmd_table tag 30 (load) added; sentinel pushed down.
;             • Handler in kosh_cmds_fs.asm r14 - ingests a file from
;               the EMU's host-side load/ folder into the current
;               drive, via the new HOST_CMD_FOPEN/FREAD/FCLOSE MMIO
;               surface. No ImDisk, no UAC, no dismount-remount dance.
;             • Four new scratch slots in page $00 ($45F0..$45F7) for
;               state carried across CALL24/TRAP boundaries.
;
;           r28 - 11 May 2026 - Part 25 r5: cmd_table tag 29 (remount).
;             • New dispatch ladder entry; sentinel pushed down.
;             • Handler in kosh_cmds_disk.asm r4 - re-mounts a host bay
;               so external modifications (kos_inject etc.) become
;               visible without rebooting kosh.
;
;           r27 - 11 May 2026 - Part 25 r4: current working drive (CWD).
;             • KOSH_CWD byte at $43BA holds the current drive letter
;               ($'B' at boot). Initialised at kosh_entry: top.
;             • Prompt is now "<CWD>:$ " - built fresh each prompt
;               cycle in ROW_BUF, then PUTS.
;             • Bare drive-letter "B:" / "C:" / etc. is now a special
;               first-token command in the dispatch path: switches
;               KOSH_CWD if the target is mounted, refuses with
;               "?: cannot switch [ERR_BADDRIVE $FFDF]" otherwise.
;             • Stale-CWD check at top of .repl_loop: if KOSH_CWD's
;               drive is no longer mounted (e.g. user unmounted it),
;               silently snap back to 'B' before showing the prompt.
;             • New helper _KoshNormPath in kosh_helpers.asm: copies a
;               path, prepending "<CWD>:" if the input lacks the
;               "X:" prefix. Called by every kosh fs cmd that takes a
;               path: cat, cp (x2), rm, mv (x2), run.
;             • ls without arg now defaults to CWD instead of hardcoded B:.
;             • format still requires explicit drive arg (too destructive
;               to default).
;             • No kernel changes - kernel _ParsePath still requires
;               explicit X: prefix. CWD is pure kosh presentation.
;
;           r26 - 11 May 2026 - Part 25 r3: human-readable error names.
;             • Added err_name_table at end of kosh page mapping each
;               known ERR_* code to its name string (e.g. $FFE4 ->
;               "ERR_NOTFOUND"). Lookup is via new _KoshErrName helper
;               in kosh_helpers.asm; output via new _KoshPrintErr helper.
;             • Format: "cp: cannot create destination [ERR_READONLY $FFE2]\n"
;             • Unknown err codes get "ERR_UNKNOWN" with the hex code.
;             • All five err-printing call sites in kosh_cmds_fs.asm
;               (format/cp/rm/mv/run) refactored to use _KoshPrintErr -
;               net ~60 lines saved across the file. cat's open/read err
;               messages also extended to include the err code (previously
;               static "cat: cannot open file" with no code).
;             • No changes to kernel or other kosh-cmd files this session.
;
;           r25 - 11 May 2026 - Part 25: cmd_table tags 27 (rm), 28 (mv).
;             • Two new dispatch ladder entries; sentinel pushed down.
;             • No new scratch (rm/mv reuse cp's CP_BUF for cross-drive
;               synthesised moves; same-drive mv is a single TRAP_RENAME).
;
;           r24 - 11 May 2026 - Part 25: cmd_table tag 26 (cp).
;             • New scratch slots CP_BUF ($43B8, 512 B), CP_SRC_FD_TMP,
;               CP_DST_FD_TMP, CP_SRC_PATH_TMP, CP_DST_PATH_TMP. Sit
;               above DISK_WALK_TMP and below LINE_BUF_OFF ($5000).
;             • Dispatch ladder gains CMP #26 / BEQ .do_cp.
;             • cmd_table sentinel pushed down by one entry.
;
;           r23 - 11 May 2026 - Part 24: cmd_table tag 25 (rename).
;             • New `rename <drive> <newname>` command renames the host
;               file bound to a drive. Used standalone or implicitly by
;               `format <drive> <label>`. Handler lives in kosh_cmds_disk.asm.
;             • No other dispatch / scratch changes.
;
;           r22 - 10 May 2026 - Part 23 r2 simplification.
;             • Pool/catalogue layer ripped out; disk\*.KOS files are
;               the catalogue. Persistent bay assignments live in INI
;               [Disks] as plain `C=name.kos`.
;             • Scratch layout updated: LIST_BUF (256 B kosh-page) at
;               $42B0; DISK_DRIVE_TMP / DISK_SECTORS_TMP / DISK_WALK_TMP
;               at $43B2..$43B6 in page $00. Old DISK_SLOT_TMP /
;               DISK_COUNT_TMP / DISK_FLAGS_TMP gone (no slots in the
;               new model).
;             • kosh_cmds_disk.asm rewritten against new HOST_CMD_*
;               surface. cmd_table tags 20..24 unchanged.
;             • help text untouched (commands and names didn't change).
;
;           r21 - 10 May 2026 - Part 23 r1 (pool-based; replaced).
;
;           r20 - 8 May 2026 - Phase 19 diagnostic: added READ_EOF.COM
;             populate. Tests sys_read post-EOF behaviour (bug: returns
;             ERR_BADFD instead of D0=0/CLC at exact EOF). 206-byte image
;             from Test_read_eof.asm. Run with: run B:READEOF.COM.
;
;           r19 - 7 May 2026 - Phase 19 polish: stripped diagnostic from
;             populate block (HELLO-first ordering restored), and noted
;             that ls had a long-standing bug clobbering D2/D3 across
;             _KoshEmitDec / _KoshEmitNamePadded. Fixed in
;             kosh_cmds_fs.asm by stashing drive/index in zero-page
;             slots LS_DRIVE_TMP / LS_INDEX_TMP. Symptom was: ls
;             always stopped after the first file (returned ERR_BADDRIVE
;             from sys_dirent on iter 2 due to bogus drive byte). Bug
;             was hidden because (a) until r17 there was only ever one
;             file on B:, and (b) ls treated any error as "end of dir".
;
;           r18 - 7 May 2026 - Phase 19: disk populate moved to kosh
;             task body (was in _P2Main, broke FD_TABLE which aliases
;             onto vector table when Y3=$00).
;             - Removed populate block from _P2Main (and instrumentation).
;             - Added new block at start of kosh_entry: existence-checks
;               B:HELLO.COM and B:NOTES.TXT, writes either if missing.
;             - Idempotent: subsequent kosh boots that find files extant
;               (e.g. if save/load of RAM disk lands later) skip writes.
;             - Image data + path strings stay kernel-side in ROM; kosh
;               passes the full 24-bit pointers to sys_open/sys_write.
;
;           r17 - 7 May 2026 - Phase 19 testing aid: pre-populate B:
;             at boot with HELLO.COM (assembled from Test_hello.asm)
;             and NOTES.TXT (welcome + cheat-sheet). Both written
;             after auto-format succeeds. Calls sys_open/write/close
;             directly (CALL24, not TRAP) because we're in BOOT state.
;             Open failures fall through silently - kosh still launches,
;             user just sees an empty B:.
;             Phase 19 shim until kosh `cp` and host save/load arrive.
;
;           r16 - 7 May 2026 - Phase 19: format and run commands.
;             - Two new dispatch tags: 18 (format), 19 (run).
;             - Implementation in kosh_cmds_fs.asm (alongside vol/ls/cat).
;             - format <drive>: thin TRAP_FORMAT (TRAP #32) wrapper. Drive
;               must be B: (the only writable volume). Re-mounts after
;               format so subsequent ls/cat see the empty new layout.
;             - run <path>: TRAP_EXEC + TRAP_WAIT pair. Loads child .COM
;               and blocks until it exits, then prints "[exit N]\n".
;             - Help text in kosh_help.asm bumped with the two new lines.
;             - Banner unchanged (kosh v0.8 still reflects current shell).
;
;           r15 - 7 May 2026 - Phase 19 source split.
;             - Moved help text + handler to kosh_help.asm.
;             - Moved exit/echo/clear/halt/reboot to kosh_cmds_util.asm.
;             - Moved peek/dump to kosh_cmds_mem.asm.
;             - Moved ver/ps/mem/uptime/info/tcb to kosh_cmds_sys.asm.
;             - kosh.asm now retains: header, _P2Main, _BootFail,
;               kosh_entry: (banner + REPL + dispatch ladder), four
;               command-group .INCLUDEs + helpers .INCLUDE, cmd_table,
;               base strings (banner/prompt/unknown/version), and
;               kernel-side strings.
;             - File shrinks 1756 -> ~470 lines. No functional change;
;               the split is purely organisational. Each command-group
;               file owns its handler bodies, its message strings, and
;               its command-name strings (the cmd_*_str entries the
;               cmd_table references), matching the existing pattern
;               from kosh_cmds_fs.asm.
;             - Tag numbering preserved unchanged across the split so
;               tag values remain stable (no reordering of dispatch
;               ladder needed).
;             - .INCLUDE order matters because each file emits handler
;               bodies followed by its strings into the kosh_entry
;               address space. Order chosen for readability:
;                 help -> util -> sys -> mem -> fs -> helpers
;
;             Carries forward the r14 .INCLUDE workaround: nested INCLUDE
;             prepends the outer's directory a second time, so we use
;             "../kosh/<file>" to cancel the duplicate prepend. When the
;             assembler bug is fixed, all six .INCLUDE lines below revert
;             to plain "<file>".
;
;           r14 - 7 May 2026 - Phase 16.7 kosh FS commands.
;             [history retained in r14-and-earlier sections at the bottom
;              of this header for reference; truncated here for brevity]
;
;   Design (unchanged from r14):
;     * banner + version line on entry
;     * prompt -> sys_gets line
;     * trim leading whitespace, isolate first word
;     * dispatch via cmd_table CMP-ladder (tag-based, not function ptrs:
;       K16 has no JMP [XY] indirect through memory)
;     * unknown   -> "?" line
;     * blank     -> reprompt
;     * loop forever
;
;   Pattern follows kos_p14_kheap_user_smoke.asm: kosh body sits in
;   ROM, kernel side _P2Main copies it to a freshly-allocated user
;   page, builds the task with _BuildTask, then JMP24 _RestoreIdle.
;   No sys_spawn dependency.
; ============================================================================

LINE_BUF_OFF    .EQU    $5000               ; line buffer offset within page
                                            ; (r14: was $1000, but the kosh body
                                            ; has grown past $1000 - msg_help
                                            ; overlapped LINE_BUF and the user's
                                            ; typed "help\0" was overwriting
                                            ; msg_help bytes at runtime, causing
                                            ; sys_puts to truncate when it hit
                                            ; the embedded nul. Moved to $5000
                                            ; - clear of the body and clear of
                                            ; the scratch area at $4000..$42A7.)
LINE_BUF_MAX    .EQU    79                  ; sys_gets max length (excl. nul)

; Precomputed open-flags for the boot-time disk populate (r17). The
; assembler evaluates expressions left-to-right but does not accept '|'
; inside a LOADI immediate; we OR the constants here at .EQU time.
;   FOPEN_CREATE ($4) | FOPEN_WRITE ($2) | FOPEN_TRUNC ($8) = $E
OPEN_FLAGS_NEW  .EQU    FOPEN_CREATE+FOPEN_WRITE+FOPEN_TRUNC

; --- kosh-owned scratch in user page ----------------------------------------
;
; History: r12 placed scratch at $1100. r14 added FS-command scratch and the
; kosh body grew past $1100, causing scratch to overlap msg_help and other
; trailing strings. Symptom was sys_puts truncating msg_help at offset ~290.
;
; r14 moves all scratch to $4000 - plenty of room above the body (which is
; now ~$1B00 bytes), plenty of room below the stack at $FFFE. Same convention
; as before; just relocated.
;
; Layout from $4000:
;   $4000..$4005   DUMP_PAGE / DUMP_OFFS / DUMP_LEN
;   $4006..$4015   DUMP_ROW (16 B)
;   $4020..$407F   ROW_BUF (96 B)
;   $4080..$409F   LS_DIRENT_BUF (32 B)
;   $40A0..$40AB   LS_FILE_COUNT / LS_TOTAL_LO / LS_TOTAL_HI / LS_SIZE_TMP /
;                  LS_DRIVE_TMP / LS_INDEX_TMP (six words; Part 22 added
;                  LS_TOTAL_HI for 32-bit accumulation)
;   $40A6..$42A6   CAT_BUF (513 B)
;   $42B0..$43AF   LIST_BUF (256 B)
;   $43B2..$43B7   DISK_*_TMP (3 words)
;   $43B8..$45B7   CP_BUF (512 B)            -- Part 25
;   $45B8..$45BF   CP_*_TMP (4 words)        -- Part 25
;   $45C0..$45C1   KOSH_CWD (byte+pad)       -- Part 25 r4
;   $45D0..$45EF   KOSH_NORM_A/B (2x16 B)    -- Part 25 r4
;   $45F0..$45F7   LOAD_*_TMP (4 words)      -- Part 25 r6
;   $45F8          RUN_BG_TMP (1 word)       -- Part 25 r7

DUMP_PAGE       .EQU    $4000               ; word - current dump page byte
DUMP_OFFS       .EQU    $4002               ; word - current dump offset
DUMP_LEN        .EQU    $4004               ; word - bytes remaining
DUMP_ROW        .EQU    $4006               ; 16 bytes - row source staging

ROW_BUF         .EQU    $4020               ; 96 bytes - formatted output staging

; --- Phase 16.7 FS-command scratch ------------------------------------------
LS_DIRENT_BUF   .EQU    $4080               ; 32 B - sys_dirent destination
LS_FILE_COUNT   .EQU    $40A0               ; word - files seen so far
LS_TOTAL_LO     .EQU    $40A2               ; word - sum of file sizes (low 16 bits)
LS_TOTAL_HI     .EQU    $40A4               ; word - sum of file sizes (high 16 bits)
                                            ; Part 22: widened from a single
                                            ; 16-bit LS_TOTAL_BYTES at $40A2;
                                            ; LS_SIZE_TMP was at $40A4 and has
                                            ; moved to $40A6.
LS_SIZE_TMP     .EQU    $40A6               ; word - saved size across _KoshEmitDec
LS_DRIVE_TMP    .EQU    $40A8               ; word - drive across _KoshEmit* calls
LS_INDEX_TMP    .EQU    $40AA               ; word - index across _KoshEmit* calls

CAT_BUF         .EQU    $40AC               ; 513 B - sys_read destination
                                            ; (Part 22: bumped from $40AA to
                                            ; $40AC to make room for new
                                            ; LS_TOTAL_HI word.)
CAT_BUF_SIZE    .EQU    512                 ; max bytes per sys_read

; --- Part 23 disk-command scratch -------------------------------------------
; LIST_BUF lives in the kosh task page (CAT_BUF range continues to $42AC,
; LIST_BUF immediately above it). HOST_CMD_LIST writes <=256 bytes into it.
; DISK_*_TMP slots use LOADZ/STOREZ to page $00 - those addresses are
; outside any kernel allocation (the static map ends at $0480..$04CB and
; TCB pool at $0800..$277F; $42xx in page $00 is free).
LIST_BUF        .EQU    $42B0               ; 256 B - HOST_CMD_LIST output buffer
LIST_BUF_END    .EQU    $43B0               ; one past last byte

DISK_DRIVE_TMP   .EQU   $43B2               ; word - drive index across CALL24s
DISK_SECTORS_TMP .EQU   $43B4               ; word - sector count for mkdisk
DISK_WALK_TMP    .EQU   $43B6               ; word - LIST_BUF walk offset

; --- Part 25 cp-command scratch ---------------------------------------------
; Sits above the disk-command scratch, below LINE_BUF_OFF ($5000).
; CP_BUF is the read/write staging buffer; one cluster = 512 bytes matches
; sys_read's natural unit on the cluster=1 disks we use.
CP_BUF          .EQU    $43B8               ; 512 B - read/write staging
CP_BUF_SIZE     .EQU    512
CP_SRC_FD_TMP   .EQU    $45B8               ; word - source fd across CALL24s
CP_DST_FD_TMP   .EQU    $45BA               ; word - destination fd
CP_SRC_PATH_TMP .EQU    $45BC               ; word - pointer to src path
CP_DST_PATH_TMP .EQU    $45BE               ; word - pointer to dst path
CP_DSTDRV_TMP   .EQU    $4650               ; word - glob cp dest drive index
CP_NAME_TMP     .EQU    $4652               ; word - glob cp current name offset

; cp worker error sentinels (returned in D0 with C=1). Chosen to avoid
; collision with both the kernel ERR_* range (>= $FF00) and short-write
; byte counts (0..512): $8000-range is in neither.
CP_ERR_SAMEPATH .EQU    $8001               ; src == dst
CP_ERR_EXISTS   .EQU    $8002               ; dst already exists
MV_WARN_ROSRC   .EQU    $8003               ; mv: copied OK, source on r/o vol (not removed)

; --- Part 25 r4 CWD scratch (in kosh task page; Y3-relative) ---------------
; KOSH_CWD is the current-drive letter ('B' at boot). Path-taking commands
; prepend "<KOSH_CWD>:" via _KoshNormPath when the user supplies a bare
; filename. Two scratch buffers because cp/mv carry two paths in flight.
; A 16-byte buffer easily fits "X:NNNNNNNN.EEE\0" (14 chars max).
KOSH_CWD        .EQU    $45C0               ; byte - current drive letter
                                            ; (allocate word for alignment)
KOSH_NORM_A     .EQU    $45D0               ; 16 B - normalised path A
KOSH_NORM_B     .EQU    $45E0               ; 16 B - normalised path B
KOSH_NORM_LEN   .EQU    16                  ; max bytes per buffer

; --- Part 25 r6 load-command scratch (page-$00 words) ----------------------
; The load command holds these across CALL24 boundaries (_HostFOpen,
; _KoshNormPath, _HostFRead, _HostFClose, _KoshPrintErr). Same page-$00
; convention as the CP_*_TMP slots.
LOAD_NAME_TMP   .EQU    $45F0               ; word - page-offset of name in LINE_BUF
LOAD_FORCE_TMP  .EQU    $45F2               ; word - 0 = refuse on exists, 1 = -f
LOAD_DST_FD_TMP .EQU    $45F4               ; word - dest fd across host calls
LOAD_SIZE_TMP   .EQU    $45F6               ; word - file size for success msg

; --- Part 25 r7 run-command scratch ----------------------------------------
; RUN_BG_TMP stashes the background flag across TRAP_EXEC, since the kernel
; clobbers data registers and PUSH/POP D is too coarse (would also clobber
; the TID returned in D0/D2). One word in kosh's task page.
RUN_BG_TMP      .EQU    $45F8               ; word - 0 = foreground, 1 = background

; --- Part 34 vol-command scratch (Part 34 disk-free table refit) -----------
; vol now calls sys_diskfree per drive and renders a multi-column table.
; The per-drive return values (free, total clusters) are held in page-$00
; across the size-formatting helpers _KoshEmitSize, _KoshEmitNamePadded,
; etc. SIZE_FMT_BUF is the work area where _KoshEmitSize builds the size
; string ("1.00MB", "979KB", "0") before right-aligning it into ROW_BUF.
VOL_FREE_TMP    .EQU    $45FA               ; word - free clusters
VOL_TOTAL_TMP   .EQU    $45FC               ; word - total clusters
SIZE_FMT_BUF    .EQU    $45FE               ; 16 bytes - size-string work area
                                            ; (max content "1024.99GB\0" = 10 B;
                                            ;  rounded up for alignment headroom)
VOL_CLSZ_TMP    .EQU    $460E               ; word - cluster size in bytes (from sys_diskfree)

; --- Part 34 load-command cumulative write counter -------------------------
; Tracks bytes actually written across the load-copy loop so .load_write_err
; can report "wrote N before disk full" with a real cumulative. Initialised
; to 0 at .load_open_dest_for_write; each successful sys_write iteration adds
; D0 (chunk bytes written). On error, this total + sys_write's D1 (partial
; bytes of the failed chunk) = real on-disk size.
; 32-bit because load can pull files up to the bay size (~1MB).
LOAD_WRITTEN_LO  .EQU   $4610               ; word - low 16 bits of cumulative
LOAD_WRITTEN_HI  .EQU   $4612               ; word - high 16 bits of cumulative
LOAD_ERR_TMP     .EQU   $4614               ; word - stashed err code across the
                                            ; .load_write_err preamble build.
                                            ; D3 isn't safe because _KoshEmitSize
                                            ; doesn't preserve D3 (its KLIB
                                            ; callees clobber it).

; --- Part 37 wildcard-glob expander scratch --------------------------------
; State for _KoshGlobExpand's directory walk. Held in memory (not registers)
; because the walk calls sys_dirent and _KoshFnMatch, both of which clobber
; most D/XY registers. Same discipline as .do_ls (LS_DRIVE_TMP etc.).
GLOB_DRIVE       .EQU   $4620               ; word - drive index being walked
GLOB_INDEX       .EQU   $4622               ; word - current dirent index
GLOB_COUNT       .EQU   $4624               ; word - matches collected so far
GLOB_MAX         .EQU   $4626               ; word - table capacity (root_entries)
GLOB_TABLE       .EQU   $4628               ; word - table base offset (stack region)
GLOB_PATPTR      .EQU   $462A               ; word - pattern offset (task page)
GLOB_DIRENT_BUF  .EQU   $462C               ; 32 B - sys_dirent destination
                                            ;        ($462C..$464B)
GLOB_RSVSIZE     .EQU   $464C               ; word - reserved stack table size
                                            ;        (root_entries*14) for release
LS_PAT_PTR       .EQU   $464E               ; word - ls wildcard pattern offset
                                            ;        (task page); points at "*" for
                                            ;        the match-all cases
GLOB_ENTRY_SIZE  .EQU   14                  ; bytes per table entry (13 name + pad)


; ============================================================================
; _P2Main - entry from kos_boot.asm
;   1. Print boot banner.
;   2. Install _INTDispatch at VEC_INT (per-smoke convention; gotcha 7.7).
;   3. Auto-format B: if not mounted (production kosh, no smoke harness).
;   4. Allocate user page; copy kosh body; build the task.
;   5. JMP24 _RestoreIdle - scheduler picks up kosh.
; ============================================================================
_P2Main:
                LOADI   Y3, #$00
                LOADI   X3, #KERNEL_STACK_TOP

                ; Part 30 cleanup: the "k/OS Phase 16.7 - kosh" banner that
                ; used to live here has moved into kosh's _OSSplash. Kernel
                ; boot trace is now just kos_boot's "Booting k/OS", this
                ; file's "Formatting B: ..." (when needed), and the final
                ; "Loading k/OS shell ..." emitted just before we hand
                ; off to the scheduler. Everything else paints from inside
                ; kosh, where it lands in the shell back-buffer.

                ; -- Install _INTDispatch at VEC_INT ------------------------
                LOADI   Y0, #$00
                LOADI   X0, #VEC_INT
                LOADI   D0, #>_INTDispatch
                STORED  D0, [XY0]
                LOADI   D0, #<_INTDispatch
                STORED  D0, [XY0+#2]

                ; -- Auto-format B: if not mounted --------------------------
                ; r14: production kosh (no smoke harness). _InitFS has already
                ; run from _InitKernel; if the RAM disk wasn't pre-formatted
                ; by an earlier session (or a save/load round trip when that
                ; lands), VOL_PRESENT[B:] will be 0 and the user has nothing
                ; to operate on.
                ;
                ; Auto-format makes B: usable from first boot. Harmless when
                ; B: is already mounted (we skip in that case).
                LOADI   Y0, #$00
                LOADI   X0, #VOL_SLOT_B
                LOADB   D0, [XY0+#VOL_PRESENT]
                CMP     D0, #0
                BNE     .skip_format

                LOADI   Y0, #>boot_format_msg
                LOADI   X0, #<boot_format_msg
                CALL24  _RawPuts

                ; _FormatVolume(D0=drive, XY0=11-byte label).
                LOADI   D0, #FS_DRIVE_B
                LOADI   Y0, #>boot_ramdisk_label
                LOADI   X0, #<boot_ramdisk_label
                CALL24  _FormatVolume
                BCS     .format_failed

                LOADI   Y0, #>boot_format_ok
                LOADI   X0, #<boot_format_ok
                CALL24  _RawPuts
                BRA     .skip_format

                ; -- Disk population moved to kosh task body (r18) --------
                ; Calling sys_* from boot context corrupts page-$00 vector
                ; table because _AllocFd reads FD_TABLE at Y3:$000C - which
                ; in kernel page is a vector slot. Populate now runs from
                ; kosh_entry, where Y3 = task page and FD_TABLE is task-
                ; local zeroed memory. See `_PopulateB` inside kosh_entry.


.format_failed:
                LOADI   Y0, #>boot_format_err
                LOADI   X0, #<boot_format_err
                CALL24  _RawPuts
                ; Fall through - kosh still runs, B: just stays unmounted.

.skip_format:

                ; -- Allocate a user page for kosh --------------------------
                CALL24  _AllocPage
                BCS     _BootFail
                STOREZ  D0, [#BT_PRIMARY]
                STOREZ  D0, [#BT_ENTRY_PG]

                ; -- Copy kosh body: Y0:X0 (ROM) -> Y1:X1 (page:$0200) ------
                LOADI   Y0, #>kosh_entry
                LOADI   X0, #<kosh_entry
                LOADZ   D0, [#BT_PRIMARY]
                MOVE    Y1, D0
                LOADI   X1, #SPAWN_ENTRY_OFFSET

                LOADI   D1, #kosh_entry_end-kosh_entry
.copy_loop:
                LOADB   D0, [XY0]
                STOREB  D0, [XY1]
                ADD     X0, #1
                ADD     X1, #1
                SUB     D1, #1
                BNE     .copy_loop

                ; -- Stage remaining BT_* slots -----------------------------
                LOADI   D0, #SPAWN_ENTRY_OFFSET
                STOREZ  D0, [#BT_ENTRY_LO]
                LOADI   D0, #1
                STOREZ  D0, [#BT_PCOUNT]
                LOADI   D0, #0
                STOREZ  D0, [#BT_PARENT_ID]

                ; -- Stage BT_NAME = "kosh\0" (r20 / r3) --------------------
                ; Five bytes into $00:$0240. Y3 already = $00.
                LOADI   Y0, #$00
                LOADI   X0, #BT_NAME
                LOADI   D0, #'k'
                STOREB  D0, [XY0]
                ADD     X0, #1
                LOADI   D0, #'o'
                STOREB  D0, [XY0]
                ADD     X0, #1
                LOADI   D0, #'s'
                STOREB  D0, [XY0]
                ADD     X0, #1
                LOADI   D0, #'h'
                STOREB  D0, [XY0]
                ADD     X0, #1
                LOADI   D0, #0
                STOREB  D0, [XY0]

                ; -- Build the task -----------------------------------------
                CALL24  _BuildTask
                BCS     _BootFail

                ; -- Promote to privileged + syscritical (r33, 12 May 2026) --
                ; D0 = kosh's TCB ptr (low word; page is always $00).
                ; Set TF_PRIV (may kill any task) and TF_SYSCRITICAL
                ; (may not be killed) - pre-combined as TF_KOSH_FLAGS
                ; in kos_defs.inc since the K16 assembler doesn't accept
                ; expression operators in immediates. _BuildTask already
                ; zeroed the field so a plain STORE is safe.
                LOADI   Y1, #$00
                MOVE    X1, D0
                LOADI   D2, #TF_KOSH_FLAGS
                STORED  D2, [XY1+#TCB_FLAGS]

                ; -- Final kernel boot trace --------------------------------
                ; "Loading k/OS shell ..." - the last line printed via
                ; _RawPuts before kosh takes the screen. kosh's _OSSplash
                ; clears the screen on first paint, so this trace is
                ; ephemeral; it exists only to confirm the boot chain
                ; reached this point on the underlying terminal in case
                ; kosh never paints (e.g. if the scheduler hands off to
                ; the idle task and kosh hangs before TRAP_REGISTER_SHELL).
                LOADI   Y0, #>boot_shell_ok
                LOADI   X0, #<boot_shell_ok
                CALL24  _RawPuts

                ; -- Hand off to scheduler ----------------------------------
                JMP24   _RestoreIdle

_BootFail:
                LOADI   Y0, #>boot_fail
                LOADI   X0, #<boot_fail
                CALL24  _RawPuts
                JMP24   _RestoreIdle


; ============================================================================
; kosh_entry - the kosh user task body.
; ============================================================================
;   At entry:
;     Y3  = task's primary page byte (set by _BuildTask via fake INT frame)
;     XY3 = task stack near top of page
;     IE  = 1 (we got here via RTI from _Schedule)
;
;   Discipline: kosh never RETs to anyone. All exits via sys_exit.
;   D0..D3 and XY0..XY2 are scratch - clobbered freely. XY3 is the
;   K16 stack pointer, never touched outside CALL/RET/PUSH/POP.
;
;   Layout inside the task page (after copy to primary:$0200):
;     $0200..       code + tables + strings (this body, including
;                   the .INCLUDEd command-group files)
;     $5000..$504F  LINE_BUF (sys_gets target, 80 bytes)
;     $4000..$42A6  scratch (DUMP_*, ROW_BUF, LS_*, CAT_BUF)
;     $FFF0         task stack top (provided by _BuildTask)
;
;   String addressing: every string is referenced as
;     Y0 = Y3
;     X0 = #SPAWN_ENTRY_OFFSET + (msg_xxx - kosh_entry)
;   The (msg_xxx - kosh_entry) is a compile-time constant (assembler
;   computes it during the second pass); SPAWN_ENTRY_OFFSET ($0200) is
;   added because the task body is copied to that offset within its page.
; ============================================================================
kosh_entry:
                ; -- Phase B Step 1: register as shell ----------------------
                ; First instruction in user-mode kosh. Allocates a
                ; 2400-byte back-buffer, sets TF_HAS_BACKBUF, links us into
                ; the (currently singleton) shell ring, and makes us the
                ; foreground task. Must happen before any output so that
                ; once Step 3's output routing lands, every byte kosh ever
                ; emits flows through the back-buffer.
                ;
                ; At boot the only possible failure is ERR_NOMEM (heap
                ; full), which cannot happen - heap is fresh and 2400
                ; bytes is well within the first region. Halt loudly if
                ; it ever does, rather than silently boot a half-broken
                ; system.
                TRAP    #TRAP_REGISTER_SHELL
                BCC.S   .reg_ok
.reg_fail:
                BRA     .reg_fail           ; halt - should never happen
.reg_ok:

                ; -- Init CWD to 'B' (Part 25 r4) --------------------------
                ; KOSH_CWD lives in kosh task page; init here because Y3
                ; only points at the task page once we're inside the task.
                ; (At _P2Main time Y3 = kernel page $00.)
                LOADI   D0, #'B'
                MOVE    Y0, Y3
                LOADI   X0, #KOSH_CWD
                STOREB  D0, [XY0]

                ; -- OS sign-on splash --------------------------------------
                ; Clears screen and paints the k/OS sign-on (logo + live
                ; system info from page $00 + closing rule). Lives in
                ; kosh_splash.asm. All output routes through TRAP_PUTS so
                ; it lands in the shell back-buffer and survives foreground
                ; switches.
                CALL24  _OSSplash

                ; -- Kosh banner --------------------------------------------
                MOVE    Y0, Y3
                LOADI   X0, #SPAWN_ENTRY_OFFSET + (msg_banner - kosh_entry)
                TRAP    #TRAP_PUTS

                MOVE    Y0, Y3
                LOADI   X0, #SPAWN_ENTRY_OFFSET + (msg_version - kosh_entry)
                TRAP    #TRAP_PUTS

                ; -- Populate B: with HELLO.COM and NOTES.TXT (r18) ----------
                ; Runs from kosh task context, so sys_* TRAPs work normally
                ; (FD_TABLE is in kosh's primary page, zeroed by _BuildTask;
                ; CURRENT_TCB points to kosh's TCB; KERNEL_STATE = RUN).
                ;
                ; Idempotent: tries sys_open(..., READ) first; if it succeeds
                ; the file already exists and we close + skip. If it returns
                ; ERR_NOTFOUND we sys_open(..., CREATE|WRITE|TRUNC) and write.
                ;
                ; Path strings + image data live in kernel ROM (outside the
                ; kosh page). Passing 24-bit ROM addresses to sys_open /
                ; sys_write works because the FS reads source data byte-by-
                ; byte regardless of which page.
                ;
                ; D2 holds fd across the open/write/close trio (TRAP epilogue
                ; runs in our task context - D2 is preserved across TRAPs in
                ; the standard syscall ABI).

                ; --- HELLO.COM ----------------------------------------------
                LOADI   Y0, #>boot_hello_path
                LOADI   X0, #<boot_hello_path
                LOADI   D0, #FOPEN_READ
                TRAP    #TRAP_OPEN
                BCS     .pop_h_create           ; not found -> create
                ; Already exists. Close and skip.
                MOVE    D2, D0
                TRAP    #TRAP_CLOSE
                BRA     .pop_h_done

.pop_h_create:
                LOADI   Y0, #>boot_hello_path
                LOADI   X0, #<boot_hello_path
                LOADI   D0, #OPEN_FLAGS_NEW
                TRAP    #TRAP_OPEN
                BCS     .pop_h_done             ; create failed -> silently skip
                MOVE    D2, D0                  ; D2 = fd

                LOADI   Y0, #>hello_com_image
                LOADI   X0, #<hello_com_image
                LOADI   D1, #hello_com_image_end-hello_com_image
                MOVE    D0, D2
                TRAP    #TRAP_WRITE
                ; ignore write result - close anyway

                MOVE    D0, D2
                TRAP    #TRAP_CLOSE
.pop_h_done:

                ; --- NOTES.TXT ----------------------------------------------
                LOADI   Y0, #>boot_notes_path
                LOADI   X0, #<boot_notes_path
                LOADI   D0, #FOPEN_READ
                TRAP    #TRAP_OPEN
                BCS     .pop_n_create
                MOVE    D2, D0
                TRAP    #TRAP_CLOSE
                BRA     .pop_n_done

.pop_n_create:
                LOADI   Y0, #>boot_notes_path
                LOADI   X0, #<boot_notes_path
                LOADI   D0, #OPEN_FLAGS_NEW
                TRAP    #TRAP_OPEN
                BCS     .pop_n_done
                MOVE    D2, D0

                LOADI   Y0, #>notes_txt_image
                LOADI   X0, #<notes_txt_image
                LOADI   D1, #notes_txt_image_end-notes_txt_image
                MOVE    D0, D2
                TRAP    #TRAP_WRITE

                MOVE    D0, D2
                TRAP    #TRAP_CLOSE
.pop_n_done:

; ----------------------------------------------------------------------------
; Read-eval-print loop
; ----------------------------------------------------------------------------
.repl_loop:
                ; -- Prompt (Part 25 r4: builds "<CWD>:$ " + stale check) ---
                CALL24  _KoshPrintPrompt

                ; -- Read line into LINE_BUF --------------------------------
                ;   sys_gets:  XY0 = buffer ptr, D0 = max len
                ;   returns:   D0 = actual length, C=0
                MOVE    Y0, Y3
                LOADI   X0, #LINE_BUF_OFF
                LOADI   D0, #LINE_BUF_MAX
                TRAP    #TRAP_GETS

                ; -- Skip leading whitespace --------------------------------
                ;   XY1 walks the buffer; D1 = remaining chars.
                MOVE    Y1, Y3
                LOADI   X1, #LINE_BUF_OFF
                MOVE    D1, D0
.skip_ws:
                CMP     D1, #0
                BEQ     .blank_line
                LOADB   D2, [XY1]
                CMP     D2, #CH_SPACE
                BNE.S   .have_word
                INC     XY1, #1
                SUB     D1, #1
                BRA     .skip_ws

.blank_line:
                ; Empty / whitespace-only - just reprompt.
                BRA     .repl_loop

.have_word:
                ; XY1 = start of first non-space char. Walk forward to the
                ; next space or nul; overwrite a trailing space with nul so
                ; the word is its own zstring. XY2 saves the start.
                LEA     XY2, XY1
.find_end:
                LOADB   D2, [XY1]
                CMP     D2, #0
                BEQ.S   .term_done          ; already nul
                CMP     D2, #CH_SPACE
                BEQ.S   .term_here
                INC     XY1, #1
                BRA     .find_end

.term_here:
                LOADI   D2, #0
                STOREB  D2, [XY1]
                BRA.S   .term_done_common

.term_done:
                ; Word already nul-terminated (line ended at the word).
                ; Write a sentinel nul one byte past it, so handlers that
                ; step past the word's terminator find a clean "no args"
                ; signal instead of stale buffer contents.
                INC     XY1, #1
                LOADI   D2, #0
                STOREB  D2, [XY1]
.term_done_common:
                ; XY2 = nul-terminated single-word command.
                ; If the parser took .term_here, byte at XY2+strlen+1 is
                ; the original next char (possibly more args). If it took
                ; .term_done, byte at XY2+strlen+1 is a guaranteed nul.

                ; -- Lowercase the command word (in place) -----------------
                ; r19: case-insensitive command dispatch. cmd_*_str entries
                ; are all lowercase; we lowercase A..Z in the user's typed
                ; word before walking the table. Only touches the command
                ; word (XY2..nul) - args past the nul are left untouched
                ; so e.g. "ECHO Hello" still echoes "Hello".
                LEA     XY0, XY2
.lc_loop:
                LOADB   D0, [XY0]
                CMP     D0, #0
                BEQ     .lc_done
                ; A..Z?
                CMP     D0, #'A'
                BLO.S   .lc_skip
                CMP     D0, #$5B            ; 'Z'+1
                BHS.S   .lc_skip
                ADD     D0, #$20            ; -> lowercase
                STOREB  D0, [XY0]
.lc_skip:
                INC     XY0, #1
                BRA     .lc_loop
.lc_done:

                ; -- Drive-switch special case (Part 25 r4) -----------------
                ; Recognise bare "<a..z>:" as a CWD change attempt. Must be
                ; exactly 3 bytes: letter, colon, nul. Anything else falls
                ; through to the normal cmd_table dispatch.
                ;
                ; We accept the full a..z range here (not just a..f) so
                ; that e.g. "z:" gets the friendly ERR_BADDRIVE message
                ; via _KoshPrintErr, rather than the bare "?" that the
                ; cmd_table miss would produce.
                LEA     XY0, XY2
                LOADB   D0, [XY0]               ; byte 0
                CMP     D0, #'a'
                BLO     .not_drive_switch
                CMP     D0, #$7B                ; 'z'+1
                BHS     .not_drive_switch
                INC     XY0, #1
                LOADB   D1, [XY0]               ; byte 1
                CMP     D1, #':'
                BNE     .not_drive_switch
                INC     XY0, #1
                LOADB   D1, [XY0]               ; byte 2 must be nul
                CMP     D1, #0
                BNE     .not_drive_switch

                ; Matched. D0 = letter ('a'..'z'). Stash *uppercase* letter
                ; in D3 (_SlotForDrive preserves D3), since XY2 gets
                ; clobbered by _SlotForDrive's slot-pointer return.
                MOVE    D3, D0
                SUB     D3, #$20                ; D3 = 'A'..'Z'
                SUB     D0, #'a'                ; D0 = drive index (0..25)
                CALL24  _SlotForDrive
                BCS     .drive_switch_bad       ; D0 = ERR_BADDRIVE

                ; Slot is mounted. Update KOSH_CWD from D3.
                MOVE    Y0, Y3
                LOADI   X0, #KOSH_CWD
                STOREB  D3, [XY0]
                BRA     .repl_loop

.drive_switch_bad:
                ; D0 = ERR_BADDRIVE. Use _KoshPrintErr to report.
                MOVE    Y0, Y3
                LOADI   X0, #SPAWN_ENTRY_OFFSET + (msg_cwd_bad - kosh_entry)
                CALL24  _KoshPrintErr
                BRA     .repl_loop

.not_drive_switch:

                ; -- Dispatch via cmd_table ---------------------------------
                ;   cmd_table entries are 4 bytes each:
                ;     word 0: page-local offset of command zstring (0 = end)
                ;     word 1: handler tag (1 = help, 2 = exit)
                ;
                ;   Why tags not code pointers: K16 has no JMP [XY] indirect
                ;   through memory and assembler word relocation for
                ;   page-local code addresses isn't a clean idiom.
                ;   CMP-ladder dispatch is two extra instructions per entry
                ;   and reads naturally.
                ;
                ;   D3 holds table cursor (page-local byte offset).
                ;   XY1 will hold user word; XY0 will hold candidate cmd.

                LEA     XY1, XY2            ; XY1 = user word (preserved by KLIB_STRCMP)

                LOADI   D3, #SPAWN_ENTRY_OFFSET + (cmd_table - kosh_entry)

.cmd_loop:
                ; Read the cmd-string offset at [Y3:D3].
                MOVE    Y0, Y3
                MOVE    X0, D3
                LOADD   D0, [XY0]
                CMP     D0, #0
                BEQ     .unknown            ; sentinel - no match

                ; XY0 = candidate cmd zstring address.
                MOVE    Y0, Y3
                MOVE    X0, D0
                ; XY1 still = user word (KLIB_STRCMP preserves XY0/XY1).
                CALL24  KLIB_STRCMP
                CMP     D0, #0
                BEQ.S   .matched

                ; No match - advance D3 by 4 bytes (next entry).
                ADD     D3, #4
                BRA     .cmd_loop

.matched:
                ; Read handler tag from table_entry+2.
                MOVE    Y0, Y3
                MOVE    X0, D3
                ADD     X0, #2
                LOADD   D0, [XY0]

                CMP     D0, #1
                BEQ     .do_help
                CMP     D0, #2
                BEQ     .do_exit
                CMP     D0, #3
                BEQ     .do_ps
                ; tags 4 (mem) and 5 (ver) removed in Part 23 - folded
                ; into info (tag 13). Numeric gaps preserved to avoid
                ; renumbering the rest of the table.
                CMP     D0, #6
                BEQ     .do_echo
                CMP     D0, #7
                BEQ     .do_clear
                CMP     D0, #8
                BEQ     .do_halt
                CMP     D0, #9
                BEQ     .do_reboot
                ; tag 10 (uptime) removed in Part 23 - folded into info.
                CMP     D0, #11
                BEQ     .do_peek
                CMP     D0, #12
                BEQ     .do_dump
                CMP     D0, #13
                BEQ     .do_info
                CMP     D0, #14
                BEQ     .do_task
                CMP     D0, #15
                BEQ     .do_vol
                CMP     D0, #16
                BEQ     .do_ls
                CMP     D0, #17
                BEQ     .do_cat
                CMP     D0, #18
                BEQ     .do_format
                CMP     D0, #19
                BEQ     .do_run
                CMP     D0, #20
                BEQ     .do_disks
                CMP     D0, #21
                BEQ     .do_mount
                CMP     D0, #22
                BEQ     .do_unmount
                CMP     D0, #23
                BEQ     .do_mkdisk
                CMP     D0, #24
                BEQ     .do_rmdisk
                CMP     D0, #25
                BEQ     .do_rename
                CMP     D0, #26
                BEQ     .do_cp
                CMP     D0, #27
                BEQ     .do_rm
                CMP     D0, #28
                BEQ     .do_mv
                CMP     D0, #29
                BEQ     .do_remount
                CMP     D0, #30
                BEQ     .do_load
                CMP     D0, #31
                BEQ     .do_kill
                ; Unknown tag - fall through.

.unknown:
                MOVE    Y0, Y3
                LOADI   X0, #SPAWN_ENTRY_OFFSET + (msg_unknown - kosh_entry)
                TRAP    #TRAP_PUTS
                BRA     .repl_loop


; ============================================================================
; Command handlers - split across per-group includes.
;
;   Each .INCLUDEd file contributes:
;     - one or more .do_xxx local labels (scoped under kosh_entry, so
;       reachable from the dispatch CMP/BEQ ladder above)
;     - the message strings used by its handlers
;     - the cmd_<name>_str command-name strings referenced from cmd_table
;     - any CALL24-callable helpers specific to that group
;
;   Tag numbers are allocated globally in this file's cmd_table. When
;   adding a new command, allocate the next tag, add the BEQ in the
;   ladder above, the cmd_table entry below, and put the handler+strings
;   in the appropriate group file (or a new group file).
;
;   ASSEMBLER BUG WORKAROUND: nested INCLUDE prepends the outer's
;   directory a second time. Given "kosh_xxx.asm", the assembler tries
;   "kosh/kosh/kosh_xxx.asm". The "../kosh/" prefix walks back up and
;   into kosh/ once, cancelling the duplicate prepend.
;
;   If/when the assembler is fixed, change all six paths back to plain
;   "<file>.asm".
; ============================================================================

                .INCLUDE "../kosh/kosh_help.asm"
                .INCLUDE "../kosh/kosh_cmds_util.asm"
                .INCLUDE "../kosh/kosh_cmds_sys.asm"
                .INCLUDE "../kosh/kosh_cmds_mem.asm"
                .INCLUDE "../kosh/kosh_cmds_fs.asm"
                .INCLUDE "../kosh/kosh_cmds_disk.asm"
                .INCLUDE "../kosh/kosh_splash.asm"   ; Part 30 - OS sign-on (moved from kernel)

; ============================================================================
; Kosh-internal helper subroutines (CALL24-callable).
;
;   Common helpers shared by multiple command groups:
;     _KoshEmitByte / _KoshEmitByteHex / _KoshEmitWordHex - cursor-style
;       write at XY1, advancing past the output (used by peek/dump/tcb).
;     _KoshParseAddr - parse "[$]pp:[$]oooo" or "[$]oooo" into D0/D1.
;
;   Group-specific helpers (e.g. _KoshEmitDec, _KoshPrintVolLine) live
;   inside their own group's include file (currently kosh_cmds_fs.asm).
; ============================================================================
                .INCLUDE "../kosh/kosh_helpers.asm"


; ============================================================================
; Command dispatch table.
;   Each entry: { cmd_str_offset, handler_tag }, both 16-bit words.
;   Sentinel: cmd_str_offset = 0 ends the table.
;
;   The cmd_<name>_str labels are defined in the appropriate group
;   include file. They resolve at link time as page-local addresses.
; ============================================================================
cmd_table:
                .WORD   SPAWN_ENTRY_OFFSET + (cmd_help_str - kosh_entry)
                .WORD   1                       ; tag: help        (kosh_help.asm)
                .WORD   SPAWN_ENTRY_OFFSET + (cmd_exit_str - kosh_entry)
                .WORD   2                       ; tag: exit        (kosh_cmds_util.asm)
                .WORD   SPAWN_ENTRY_OFFSET + (cmd_ps_str - kosh_entry)
                .WORD   3                       ; tag: ps          (kosh_cmds_sys.asm)
                ; tags 4 (mem), 5 (ver), 10 (uptime) removed in Part 23 -
                ; folded into info (tag 13).
                .WORD   SPAWN_ENTRY_OFFSET + (cmd_echo_str - kosh_entry)
                .WORD   6                       ; tag: echo        (kosh_cmds_util.asm)
                .WORD   SPAWN_ENTRY_OFFSET + (cmd_clear_str - kosh_entry)
                .WORD   7                       ; tag: clear       (kosh_cmds_util.asm)
                .WORD   SPAWN_ENTRY_OFFSET + (cmd_halt_str - kosh_entry)
                .WORD   8                       ; tag: halt        (kosh_cmds_util.asm)
                .WORD   SPAWN_ENTRY_OFFSET + (cmd_reboot_str - kosh_entry)
                .WORD   9                       ; tag: reboot      (kosh_cmds_util.asm)
                .WORD   SPAWN_ENTRY_OFFSET + (cmd_peek_str - kosh_entry)
                .WORD   11                      ; tag: peek        (kosh_cmds_mem.asm)
                .WORD   SPAWN_ENTRY_OFFSET + (cmd_dump_str - kosh_entry)
                .WORD   12                      ; tag: dump        (kosh_cmds_mem.asm)
                .WORD   SPAWN_ENTRY_OFFSET + (cmd_info_str - kosh_entry)
                .WORD   13                      ; tag: info        (kosh_cmds_sys.asm)
                .WORD   SPAWN_ENTRY_OFFSET + (cmd_task_str - kosh_entry)
                .WORD   14                      ; tag: task        (kosh_cmds_sys.asm)
                .WORD   SPAWN_ENTRY_OFFSET + (cmd_vol_str - kosh_entry)
                .WORD   15                      ; tag: vol         (kosh_cmds_fs.asm)
                .WORD   SPAWN_ENTRY_OFFSET + (cmd_ls_str - kosh_entry)
                .WORD   16                      ; tag: ls          (kosh_cmds_fs.asm)
                .WORD   SPAWN_ENTRY_OFFSET + (cmd_cat_str - kosh_entry)
                .WORD   17                      ; tag: cat         (kosh_cmds_fs.asm)
                .WORD   SPAWN_ENTRY_OFFSET + (cmd_format_str - kosh_entry)
                .WORD   18                      ; tag: format      (kosh_cmds_fs.asm)
                .WORD   SPAWN_ENTRY_OFFSET + (cmd_run_str - kosh_entry)
                .WORD   19                      ; tag: run         (kosh_cmds_fs.asm)
                .WORD   SPAWN_ENTRY_OFFSET + (cmd_disks_str - kosh_entry)
                .WORD   20                      ; tag: disks       (kosh_cmds_disk.asm)
                .WORD   SPAWN_ENTRY_OFFSET + (cmd_mount_str - kosh_entry)
                .WORD   21                      ; tag: mount       (kosh_cmds_disk.asm)
                .WORD   SPAWN_ENTRY_OFFSET + (cmd_unmount_str - kosh_entry)
                .WORD   22                      ; tag: unmount     (kosh_cmds_disk.asm)
                .WORD   SPAWN_ENTRY_OFFSET + (cmd_mkdisk_str - kosh_entry)
                .WORD   23                      ; tag: mkdisk      (kosh_cmds_disk.asm)
                .WORD   SPAWN_ENTRY_OFFSET + (cmd_rmdisk_str - kosh_entry)
                .WORD   24                      ; tag: rmdisk      (kosh_cmds_disk.asm)
                .WORD   SPAWN_ENTRY_OFFSET + (cmd_rename_str - kosh_entry)
                .WORD   25                      ; tag: rename      (kosh_cmds_disk.asm)
                .WORD   SPAWN_ENTRY_OFFSET + (cmd_cp_str - kosh_entry)
                .WORD   26                      ; tag: cp          (kosh_cmds_fs.asm)
                .WORD   SPAWN_ENTRY_OFFSET + (cmd_rm_str - kosh_entry)
                .WORD   27                      ; tag: rm          (kosh_cmds_fs.asm)
                .WORD   SPAWN_ENTRY_OFFSET + (cmd_mv_str - kosh_entry)
                .WORD   28                      ; tag: mv          (kosh_cmds_fs.asm)
                .WORD   SPAWN_ENTRY_OFFSET + (cmd_remount_str - kosh_entry)
                .WORD   29                      ; tag: remount     (kosh_cmds_disk.asm)
                .WORD   SPAWN_ENTRY_OFFSET + (cmd_load_str - kosh_entry)
                .WORD   30                      ; tag: load        (kosh_cmds_fs.asm)
                .WORD   SPAWN_ENTRY_OFFSET + (cmd_kill_str - kosh_entry)
                .WORD   31                      ; tag: kill        (kosh_cmds_sys.asm)
                .WORD   0                       ; sentinel
                .WORD   0


; ============================================================================
; Base strings (page-local - addressed via Y3 + page-offset).
;
;   Only the strings the REPL itself needs sit here. All command-specific
;   strings live in their group's include file.
; ============================================================================
msg_banner:    .TEXT   "k/OS shell\n",0
msg_version:   .TEXT   "kosh v0.8 - type 'help'\n\n",0
; (Part 30 r37: msg_prompt removed - was "$ " from before the dynamic
;  "B:$ " CWD prompt landed. No call sites.)
msg_unknown:   .TEXT   "?\n",0
msg_cwd_bad:   .TEXT   "cd: cannot switch",0    ; Part 25 r4 (used by _KoshPrintErr)


; ============================================================================
; Error-name lookup table (Part 25 r3)
;
;   Maps each known ERR_* code to its mnemonic string, for use by
;   _KoshPrintErr (kosh_helpers.asm). Sorted by code descending (which is
;   also numerically ascending if you treat the codes as signed-negative)
;   for readability - linear scan, no binary search, so order is just
;   convention.
;
;   Table entry: 2 words = { err_code, name_offset_within_page }.
;   Sentinel: code = $0000 (ERR_OK is never printed as an error, so this
;   value is safe to use as terminator).
;
;   When _KoshPrintErr can't find the code, it falls back to err_name_unk
;   ("ERR_UNKNOWN").
; ============================================================================

err_name_table:
                .WORD   $FFFF,  SPAWN_ENTRY_OFFSET + (err_name_badcall   - kosh_entry)
                .WORD   $FFFE,  SPAWN_ENTRY_OFFSET + (err_name_buffull   - kosh_entry)
                .WORD   $FFFD,  SPAWN_ENTRY_OFFSET + (err_name_invalid   - kosh_entry)
                .WORD   $FFFC,  SPAWN_ENTRY_OFFSET + (err_name_nomem     - kosh_entry)
                .WORD   $FFFB,  SPAWN_ENTRY_OFFSET + (err_name_noslots   - kosh_entry)
                .WORD   $FFFA,  SPAWN_ENTRY_OFFSET + (err_name_toobig    - kosh_entry)
                .WORD   $FFF9,  SPAWN_ENTRY_OFFSET + (err_name_badarg    - kosh_entry)
                .WORD   $FFF8,  SPAWN_ENTRY_OFFSET + (err_name_notchild  - kosh_entry)
                .WORD   $FFF7,  SPAWN_ENTRY_OFFSET + (err_name_deadlock  - kosh_entry)
                .WORD   $FFF6,  SPAWN_ENTRY_OFFSET + (err_name_perm      - kosh_entry)
                .WORD   $FFF5,  SPAWN_ENTRY_OFFSET + (err_name_busy      - kosh_entry)
                .WORD   $FFE7,  SPAWN_ENTRY_OFFSET + (err_name_nofd      - kosh_entry)
                .WORD   $FFE6,  SPAWN_ENTRY_OFFSET + (err_name_badfd     - kosh_entry)
                .WORD   $FFE5,  SPAWN_ENTRY_OFFSET + (err_name_badpath   - kosh_entry)
                .WORD   $FFE4,  SPAWN_ENTRY_OFFSET + (err_name_notfound  - kosh_entry)
                .WORD   $FFE3,  SPAWN_ENTRY_OFFSET + (err_name_exists    - kosh_entry)
                .WORD   $FFE2,  SPAWN_ENTRY_OFFSET + (err_name_readonly  - kosh_entry)
                .WORD   $FFE1,  SPAWN_ENTRY_OFFSET + (err_name_nospace   - kosh_entry)
                .WORD   $FFE0,  SPAWN_ENTRY_OFFSET + (err_name_io        - kosh_entry)
                .WORD   $FFDF,  SPAWN_ENTRY_OFFSET + (err_name_baddrive  - kosh_entry)
                .WORD   $FFDE,  SPAWN_ENTRY_OFFSET + (err_name_nomore    - kosh_entry)
                .WORD   $FFDD,  SPAWN_ENTRY_OFFSET + (err_name_notexec   - kosh_entry)
                .WORD   $0000,  0                                   ; sentinel

err_name_badcall:   .TEXT "ERR_BADCALL",0
err_name_buffull:   .TEXT "ERR_BUFFER_FULL",0
err_name_invalid:   .TEXT "ERR_INVALID",0
err_name_nomem:     .TEXT "ERR_NOMEM",0
err_name_noslots:   .TEXT "ERR_NOSLOTS",0
err_name_toobig:    .TEXT "ERR_TOOBIG",0
err_name_badarg:    .TEXT "ERR_BADARG",0
err_name_notchild:  .TEXT "ERR_NOTCHILD",0
err_name_deadlock:  .TEXT "ERR_DEADLOCK",0
err_name_perm:      .TEXT "ERR_PERM",0
err_name_busy:      .TEXT "ERR_BUSY",0
err_name_nofd:      .TEXT "ERR_NOFD",0
err_name_badfd:     .TEXT "ERR_BADFD",0
err_name_badpath:   .TEXT "ERR_BADPATH",0
err_name_notfound:  .TEXT "ERR_NOTFOUND",0
err_name_exists:    .TEXT "ERR_EXISTS",0
err_name_readonly:  .TEXT "ERR_READONLY",0
err_name_nospace:   .TEXT "ERR_NOSPACE",0
err_name_io:        .TEXT "ERR_IO",0
err_name_baddrive:  .TEXT "ERR_BADDRIVE",0
err_name_nomore:    .TEXT "ERR_NOMORE",0
err_name_notexec:   .TEXT "ERR_NOTEXEC",0
err_name_unk:       .TEXT "ERR_UNKNOWN",0
                    .ALIGN 2


kosh_entry_end:

; ============================================================================
; Kernel-side strings
; ============================================================================
boot_shell_ok:      .TEXT   "Loading k/OS shell ...", $0A, 0
boot_fail:          .TEXT   "BOOT FAIL: could not build kosh task\n",0
boot_format_msg:    .TEXT   "Formatting B: ... ",0
boot_format_ok:     .TEXT   "OK\n",0
boot_format_err:    .TEXT   "FAILED\n",0

; 11-byte FAT16 volume label, space-padded. Standard FAT16 pads with
; 0x20 on the right; "RAMDISK    " = 7 chars + 4 spaces.
; (Renamed from "KOS-RAM" 28 May 2026 - cosmetic, matches the user-
; facing terminology used by `vol` and the kosh `format` command.)
boot_ramdisk_label: .TEXT   "RAMDISK    "

; ============================================================================
; Embedded disk content for fresh-boot population (r17, Phase 19)
; ============================================================================
; HELLO.COM + NOTES.TXT are written to the freshly-formatted RAM disk so
; the user has something to `cat` and `run` immediately on first boot.
; Phase 19 shim until kosh `cp` (and host save/load of the RAM disk image)
; provide proper population.

; Path strings for sys_open. Note 11-char "8.3" form: drive + "FILENAME.EXT".
boot_hello_path:  .TEXT   "B:HELLO.COM",0
boot_notes_path:  .TEXT   "B:NOTES.TXT",0

; --- HELLO.COM image -------------------------------------------------------
; 36-byte assembled output of Test/Test_hello.asm (built 7 May 2026).
; Position-independent: uses LEA + page-zero TRAPs only.
; Listing reference:
;   $0200  1C 00 00 0A   LEA   XY0, hello_msg
;   $0204  F0 18         TRAP  #TRAP_PUTLN  (#12)
;   $0206  C0 00         LOADI D0, #0
;   $0208  F0 20         TRAP  #TRAP_EXIT   (#16)
;   $020A  8E 00 FF FC   BRA.L .hang  (-4, infinite loop guard)
;   $020E..$0223         "Hello from sys_exec!" + nul + word-pad
;
; To rebuild: assemble Test/Test_hello.asm with `.INCLUDE "../kos_defs.inc"`,
; copy bytes from the assembler listing's "Address  Code" columns. Total
; 36 bytes (18 words). Ends at $0223 inclusive.
;
; r2 (8 May 2026): switched code blob from .BYTE pairs to .WORD per
; userMemories byte-order rule. The previous .BYTE form transcribed the
; listing word column directly (e.g. `$1C, $00` for word $1C00) - but
; K16 is little-endian, so the actual stored bytes for word $1C00 are
; low byte $00 first then high byte $1C. The wrong order caused HELLO
; to fetch $001C as the first instruction (not LEA), executing garbage
; and eventually hanging. .WORD does the byte-order conversion at
; assemble time so the listing word value can be transcribed verbatim.
hello_com_image:
                .WORD   $1C00, $000A                ; LEA XY0, hello_msg
                .WORD   $F01A                       ; TRAP #13 (PUTLN, was #12 pre-Part 20)
                .WORD   $C000                       ; LOADI D0, #0
                .WORD   $F036                       ; TRAP #27 (EXIT, was #16 pre-Part 20)
                .WORD   $8E00, $FFFC                ; BRA.L .hang (-4)
                .BYTE   "Hello from sys_exec!", 0, 0   ; msg + nul + word pad
hello_com_image_end:
                .ALIGN

; --- NOTES.TXT image -------------------------------------------------------
; Plain text greeting + cheat-sheet for `cat`. Length determined by the
; (end - start) computation in the writer; no trailing nul needed (this
; is a text file, not a zstring).
;
; Use .BYTE (not .TEXT) so the assembler doesn't round-pad each line -
; that would inject $00 bytes mid-content. .BYTE advances PC by exact
; byte count.
;
; ALIGNMENT NOTE:  the .ALIGN goes AFTER the _end label, not before. We
; want (end - start) to equal the exact text length sys_write should
; emit; an .ALIGN before _end would inflate that count by 1 if total
; text bytes are odd, causing one stray pad byte to be written into the
; file. The "label at odd address - may cause misalignment if used as
; code target" warning the assembler emits for _end is benign here:
; we only use _end in arithmetic (end-start), never branch to it.
notes_txt_image:
                .BYTE   "Welcome to k/OS!\n"
                .BYTE   "\n"
                .BYTE   "Try these commands:\n"
                .BYTE   "  vol         - list mounted volumes\n"
                .BYTE   "  ls          - list files on B:\n"
                .BYTE   "  cat B:NOTES.TXT  - re-read this file\n"
                .BYTE   "  run B:HELLO.COM  - execute the demo\n"
                .BYTE   "  help        - all kosh commands\n"
                .ALIGN
notes_txt_image_end:

; ============================================================================
; End of kosh.asm
; ============================================================================
