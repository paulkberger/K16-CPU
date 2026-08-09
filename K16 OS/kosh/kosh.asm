; ============================================================================
; kosh.asm - kosh interactive shell (k/OS Phase 16.7+)
; ============================================================================
; Date:    8 August 2026
; Status:  Part 61 - RAM disk populated from the host, not from kosh.
; Revision: r45 - 8 August 2026 - Part 61: drive-qualified bare execution.
;             .nds_switch now sets CD_BARE=1 before routing a colon token to
;             .cd_resolve, so a token that resolves to a file (or to nothing)
;             returns to .nds_nocolon and runs instead of reporting
;             "cd: not a directory". Makes `ram:boot.ksh`, `b:hello.com` and
;             `ram:hello` work; `cd ram:boot.ksh` still errors, as it should.
;             kosh_ver_str bumped v1.01 -> v1.02. Requires kosh_defs.inc
;             (CD_BARE) and kosh_cmds_fs.asm r27.
; Revision: r44 - 8 August 2026 - Part 61: boot seeder removed. kosh no
;             longer writes B:HELLO.COM and B:NOTES.TXT into the freshly
;             formatted RAM disk. Deleted the .pop_h_* / .pop_n_* block from
;             the entry path and the boot_hello_path / boot_notes_path /
;             hello_com_image / notes_txt_image data block. Population now
;             comes from A:STARTUP.KSH via the Part 57 boot cascade, using
;             `load ramdisk/<name>` against the host's system/ramdisk folder
;             (kosh_cmds_fs.asm r26 + kosh_defs.inc). That path is EMU-only:
;             on Digital the host bridge is absent, so B: now comes up empty
;             rather than carrying the two demo files.
; Revision: r43 - 28 June 2026 - Part 50: `fg` command added — cmd_table tag 36
;             + dispatch ladder entry -> .do_fg (body in kosh_cmds_sys.asm).
;             Brings a task to the foreground by TID via TRAP_SETFOREGROUND.
; Revision: r42 - 28 June 2026 - Part 49: msg_version bumped "kosh v1.0" ->
;             "kosh v1.01" (the entry banner's own version line). The splash
;             logo's "v1.01 Phase 49+" comes separately from the kernel
;             identity slots (kos_boot.asm r54 / kosh_splash.asm r9).
; Revision: r41 - 1 June 2026 - Part 41: multi-shell re-entrancy fix.
;             The ~34 per-shell working slots (LS_*, DISK_*, CP_*, LOAD_*,
;             VOL_*_TMP, GLOB_*, including the stray LS_SIZE) were
;             historically in kernel page $00 at $40xx-$46xx, accessed via
;             LOADZ/STOREZ. That was a singleton hangover from when kosh was
;             embedded in the kernel: every kosh task shared one copy, so a
;             second shell mid-cp would clobber the first shell's ls/glob
;             state. Moved all of them into THIS task's page at $7000-$76FF
;             (OLD + $3000), accessed via LOADP/STOREP Y3. 232 access sites
;             converted across kosh_cmds_disk/_fs and kosh_helpers; 34 EQUs
;             bumped. kosh_entry now zero-fills $7000-$76FF (896 words) on
;             each new task so a fresh shell never inherits stale state.
;             Mount table (VOL_TABLE $0260, kernel page) and open-file
;             descriptors (FD_TABLE, per-task page-zero) were already
;             correctly scoped; FS kernel scratch ($0480) is DINT-protected,
;             so no kernel change was needed. Genuine page-$00 accesses
;             (kernel API addresses, KOS_VERSION) stay as LOADZ/STOREZ.
; Revision: r40 - 29 May 2026 - Part 40: fix wildcard crash caused by
;             scratch-buffer / code overlap. After the Part 39 kosh.com
;             migration plus accumulated growth (splash, glob, cp, mv,
;             rm, load, kill, plus richer help text), the kosh.com code
;             section now extends to ~$4480 in the task page (~17 KB
;             from .ORG $0200). The original scratch base at $4020
;             (ROW_BUF) sits INSIDE that code region.
;
;             Symptom: any command that returned via
;             _KoshSplitDrivePat.sdp_no_prefix after a prior `ls` (or
;             any command that wrote ROW_BUF) crashed at the `POP XY0,
;             XY3` inside .sdp_no_prefix. The POP read from $02:$5003
;             instead of the stack because XY0 had been restored from
;             stack data — but the code itself at $4020-$402D had been
;             overwritten earlier by ROW_BUF text ("B:$ \0file(s), 256"
;             from `ls` output), so the bytes at $4020 decoded as
;             `POP D123, XY1` (encoding $3A42 = ":B" little-endian)
;             instead of `POP XY0, XY3` (encoding $3C06). XY1 had been
;             left at $02:$5003 (the typed pattern) by
;             _KoshSplitDrivePat earlier, so the bogus POP-from-XY1
;             tried a word access at $5003 — odd-address fault.
;
;             Diagnosis was made possible by NOP #$FF (emulator
;             breakpoint) inserted at .sdp_no_prefix entry; the
;             register dump showed XY0 = $02:$5003 and the disasm
;             of the surrounding bytes spelled out ROW_BUF text.
;             Caught on both EMU and Digital (identical symptom).
;
;             Fix: bumped every TASK-LOCAL scratch EQU by +$2000.
;             Task-local slots (those addressed via the kosh task
;             page using `LOADI X0,#SLOT / MOVE Y0,Y3`) now live at
;             $6000-$65FF. Page-$00 slots (addressed via LOADZ/STOREZ,
;             which targets kernel page $00 and does not see task-page
;             code) remain at their original $4xxx-$46xx addresses;
;             no conflict because they're in a different page.
;
;             Slots moved (+$2000): DUMP_PAGE/OFFS/LEN/ROW, ROW_BUF,
;             LS_DIRENT_BUF, CAT_BUF, LIST_BUF, LIST_BUF_END, CP_BUF,
;             KOSH_CWD, KOSH_NORM_A, KOSH_NORM_B, RUN_BG,
;             SIZE_FMT_BUF.
;
;             Slots unchanged (page-$00, multi-shell race risk to fix
;             later): LS_FILE_COUNT, LS_TOTAL_LO/HI, LS_*_TMP,
;             DISK_*_TMP, CP_*_TMP, LOAD_*_TMP, VOL_*_TMP, GLOB_*,
;             LS_PAT_PTR.
;
;             Code references only refer to the symbols, never the
;             numeric addresses, so this is a single-file change — no
;             edits required in kosh_cmds_*.asm or kosh_helpers.asm.
;
;           r39 - 29 May 2026 - Part 39: kosh.com migration. kosh.asm
;             now assembles standalone with .ORG $0200, producing a
;             relocatable kosh.com image. Changes in this file:
;               - 2 CALL24 _Kosh* converted to CALL16; 56 string and
;                 .WORD references switched from
;                     #SPAWN_ENTRY_OFFSET + (label - kosh_entry)
;                 to bare
;                     #label
;                 because the .ORG $0200 directive lets the assembler
;                 resolve in-page offsets directly.
;               - _P2Main and _BootFail extracted to a new file
;                 kosh_boot.asm (kernel-side; .INCLUDEd from kos_boot.asm
;                 in place of kosh/kosh.asm). All kernel-side strings
;                 (boot_shell_ok, boot_fail, boot_format_msg / _ok /
;                 _err, boot_ramdisk_label) and the kosh_entry_end:
;                 label moved there too.
;               - _PopulateB inside kosh_entry: the 6 instruction pairs
;                 that addressed path strings + image blobs via
;                     LOADI Y0, #>label / LOADI X0, #<label
;                 (the kernel-ROM addressing idiom from r17/r18) now
;                 use the kosh-task idiom
;                     MOVE  Y0, Y3 / LOADI X0, #label
;                 because the labels live inside the kosh.com image,
;                 reachable via the task's primary page byte (Y3).
;               - The "String addressing" header comment block rewritten
;                 to drop the (label - kosh_entry) + SPAWN_ENTRY_OFFSET
;                 description.
;               - .INCLUDE directives added near the top to pull in
;                 ../kos_defs.inc, ../klib/kos_klib.inc,
;                 ../emulib/kos_emulib.inc, and ../kfs/kos_fs_defs.inc
;                 so kosh.asm assembles standalone.
;               - One CALL24 _SlotForDrive converted to
;                 CALL24 KLIB_SLOT_FOR_DRIVE — _SlotForDrive is now
;                 published via KLIB v1.1 slot 07 (was RESERVED_07) so
;                 the .com image can reach it without referencing a
;                 kernel-internal symbol.
;               - Late fix (post-first-boot): CALL24 _OSSplash at
;                 kosh_entry converted to CALL16. _OSSplash and
;                 _OSSplashHexByte live inside the kosh.com image so
;                 their address depends on the runtime task page,
;                 which only CALL16 (page-implicit via Y3) resolves
;                 correctly. CALL24 was hardcoded to the assembly-time
;                 page byte ($00) and jumped into the kernel at boot,
;                 silently corrupting state. The Step 2 sweep filter
;                 (CALL24 _Kosh*) missed _OSSplash* because of the
;                 naming. Symptom: kosh booted to a working prompt but
;                 no splash banner appeared. See also kosh_splash.asm
;                 r4 and kosh_cmds_sys.asm r10 for the partner fixes.
;               - msg_version bumped from "kosh v0.8" to "kosh v1.0"
;                 to match the k/OS 1.0 milestone (Part 39 closed the
;                 standalone .com shell design).
;             Counterpart files: kosh_boot.asm r1, kosh_help.asm r15,
;             kosh_cmds_util.asm r2, kosh_cmds_mem.asm r2,
;             kosh_cmds_sys.asm r9, kosh_cmds_disk.asm r5,
;             kosh_cmds_fs.asm r23, kosh_helpers.asm r5,
;             kosh_splash.asm r3, kos_klib.inc r8,
;             kos_klib_template.asm r8, kos_klib_impl.asm r11,
;             kos_emulib.inc r1 (NEW), kos_emulib_template.asm r1 (NEW),
;             kos_defs.inc r42 (all bumped together).
;
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
;               VOL_FREE   ($45FA) - free clusters per row
;               VOL_TOTAL  ($45FC) - total clusters per row
;               SIZE_FMT_BUF   ($45FE..$460D) - 16-byte work area used by
;                                   _KoshEmitSize (kosh_helpers.asm r3) to
;                                   build human-readable size strings
;                                   before right-aligning into ROW_BUF.
;               VOL_CLSZ   ($460E) - cluster size in bytes
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
;             • New scratch slots CP_BUF ($43B8, 512 B), CP_SRC_FD,
;               CP_DST_FD, CP_SRC_PATH, CP_DST_PATH. Sit
;               above DISK_WALK and below LINE_BUF ($5000).
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
;               $42B0; DISK_DRIVE / DISK_SECTORS / DISK_WALK
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
;             slots LS_DRIVE / LS_INDEX. Symptom was: ls
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
;   Pattern (Part 39+): kosh.asm assembles standalone with .ORG $0200
;   to produce kosh.com - a relocatable .com image embedded in the
;   kernel ROM via .INCBIN. _SpawnShell (kos_spawn.asm) allocates a
;   user page, copies the .com image to <page>:$0200, builds the
;   task, then JMP24 _RestoreIdle.
;   No sys_spawn dependency.
; ============================================================================


; ============================================================================
; Kernel-wide constants. Pulled in so kosh.asm assembles standalone for
; the .com build.
;   kos_defs.inc      - TRAP_*, TCB/TS_* offsets, KERNEL_*, VOL_*, VEC_*,
;                       RESET_VECTOR, ...
;   kos_klib.inc      - KLIB_* jump-table entry points (CALL24 targets)
;   kos_emulib.inc    - EMULIB_* jump-table entry points (emulator-only
;                       host-disk shim — used by host/mount/mkdisk/cp etc.)
;   kos_fs_defs.inc   - FOPEN_*, FS_DRIVE_*, ERR_*, dirent / FAT constants
; ============================================================================
                .INCLUDE "../kos_defs.inc"
                .INCLUDE "../klib/kos_klib.inc"
                .INCLUDE "../emulib/kos_emulib.inc"
                .INCLUDE "../kfs/kos_fs_defs.inc"


                .INCLUDE "../kosh/kosh_defs.inc"   ; Part 42: kosh task-page map + constants (was inline)


; ============================================================================
; .ORG $0200 - start of the kosh.com image.
; ============================================================================
; The K16 .com format places code at offset $0200 within a user page.
; _SpawnShell (kos_spawn.asm, Step 4 of the Part 39 migration) allocates
; a fresh page, copies this image to <page>:$0200, then builds the task
; with that entry point.
;
; Every label below resolves to its in-page address at assembly time, so
; the standard "Y0 = Y3 (task page); X0 = #label" reference idiom works
; throughout the .com body.
; ============================================================================
                .ORG    $0200

                JMP16   kosh_entry              ; $0200 - universal entry
; --- .COM header (Part 60) -------------------------------------------------
; $0200 is a JMP16 so the image stays directly executable with no loader at
; all; the header follows at $0204 and is parsed separately, so a bad header
; can never endanger control flow.  The loader REFUSES a bad magic - there is
; no headerless fallback.  See kos_defs.inc for the full field description.
;
; Every field is a full WORD, and the block is emitted with .WORD only.  RM
; 4.6 lists what .BYTE accepts - numeric literals, string literals, escape
; sequences - and symbols are not among them, so `.BYTE COM_VERSION` is an
; undefined-symbol error (RM 11: only immediates, .EQU and .WORD evaluate
; expressions).  An all-.WORD block also cannot leave an odd byte count, so
; it can never desynchronise the alignment of what follows.
;
; To change the page allocation, edit COM_PAGES / COM_HEAPPG - nothing else in
; this file needs to know.
COM_PAGES       .EQU    1       ; TOTAL contiguous pages, including heap
COM_HEAPPG      .EQU    0       ; how many of those are heap (0 = task page)

                .WORD   COM_MAGIC       ; $0204 - dumps as 52 42 "RB"
                .WORD   COM_VERSION     ; $0206 - header version
                .WORD   COM_PAGES       ; $0208 - total pages
                .WORD   COM_HEAPPG      ; $020A - heap pages (partition of pages)
; --- end of header; kosh_entry follows at $020C


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
;   Layout inside the task page:
;     $0200..       code + tables + strings (this body, including
;                   the .INCLUDEd command-group files); ~32 KB runway
;     $8000..       KCORE (persistent) / KBUFS (buffers) / KSTATE
;                   (per-command scratch) - see kosh_defs.inc
;     $FFF0         task stack top (provided by _BuildTask)
;
;   String addressing: every string is referenced as
;     Y0 = Y3            (the task's primary page byte)
;     X0 = #label        (the assembler resolves to the in-page
;                         offset directly because the file is at
;                         .ORG $0200)
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

                ; -- Zero per-command scratch (KSTATE) ----------------------
                ; The kosh working slots (LS_*/DISK_*/CP_*/LOAD_*/VOL_*/GLOB_*
                ; etc.) live in THIS task's page in the KSTATE region, accessed
                ; via LOADP/STOREP Y3. Each kosh has a private copy, so a second
                ; shell cannot corrupt the first. A fresh task page inherits
                ; whatever was previously resident, so clear KSTATE before first
                ; use. KSTATE_START/KSTATE_WORDS track the region automatically.
                ; (Clobbers D0/D1/X0/Y0 - all reloaded by CWD init below.)
                LOADI   X0, #KSTATE_START
                MOVE    Y0, Y3
                LOADI   D0, #0
                LOADI   D1, #KSTATE_WORDS  ; = KSTATE_SIZE/2 (region-driven)
.zero_pss_loop:
                STORED  D0, [XY0]+
                SUB     D1, #1
                BNE     .zero_pss_loop

                ; -- Init CWD to 'B' (Part 25 r4) --------------------------
                ; KOSH_CWD lives in kosh task page; init here because Y3
                ; only points at the task page once we're inside the task.
                ; (At _P2Main time Y3 = kernel page $00.)
                LOADI   D0, #'B'
                MOVE    Y0, Y3
                LOADI   X0, #KOSH_CWD
                STOREB  D0, [XY0]
                ; CWD directory cluster = 0 (root) at boot.
                LOADI   D0, #0
                LOADI   X0, #KOSH_CWD_CLU
                STORED  D0, [XY0]

                ; -- OS sign-on splash --------------------------------------
                ; Clears screen and paints the k/OS sign-on (logo + live
                ; system info from page $00 + closing rule). Lives in
                ; kosh_splash.asm. All output routes through TRAP_PUTS so
                ; it lands in the shell back-buffer and survives foreground
                ; switches.
                CALL16  _OSSplash

                ; -- Kosh banner --------------------------------------------
                MOVE    Y0, Y3
                LOADI   X0, #msg_banner
                TRAP    #TRAP_PUTS

                MOVE    Y0, Y3
                LOADI   X0, #kosh_ver_str       ; shared version token
                TRAP    #TRAP_PUTS

                MOVE    Y0, Y3
                LOADI   X0, #msg_ver_tail       ; " - type 'help'" + blank line
                TRAP    #TRAP_PUTS

; ----------------------------------------------------------------------------
; Boot cascade: run STARTUP.KSH on A:/B:/C: in order (Part 57+)
;   Arm the cascade (next drive = A) and open the first available STARTUP.KSH.
;   _KoshCascadeAdvance skips unmounted drives / missing files silently and
;   pushes the first it finds; the REPL below runs it, and re-arms for the next
;   drive each time the script stack empties. With no STARTUP.KSH anywhere,
;   SCRIPT_BOOT_DRV returns to 0 and we fall to the interactive prompt as before.
; ----------------------------------------------------------------------------
                LOADI   D0, #1
                STOREP  D0, Y3, [#SCRIPT_BOOT_DRV]   ; arm: next drive = A
                CALL16  _KoshCascadeAdvance          ; open first available

; ----------------------------------------------------------------------------
; Read-eval-print loop
; ----------------------------------------------------------------------------
.repl_loop:
                ; -- Line source: script (if active) or interactive ---------
                ; If a script is running, pull its next executable line into
                ; LINE_BUF (already echoed) and fall straight to dispatch;
                ; otherwise prompt + sys_gets. Either way D0 = line length on
                ; fall-through to .skip_ws. (kosh scripts, Part 57+.)
                CALL16  _KoshScriptNextLine
                BCC     .repl_have_line             ; C=0 -> script line ready
                ; -- Interactive: prompt, then read line into LINE_BUF ------
                ;   sys_gets:  XY0 = buffer ptr, D0 = max len
                ;   returns:   D0 = actual length, C=0
                CALL16  _KoshPrintPrompt
                MOVE    Y0, Y3
                LOADI   X0, #LINE_BUF
                LOADI   D0, #LINE_BUF_MAX
                TRAP    #TRAP_GETS
.repl_have_line:

                ; -- Skip leading whitespace --------------------------------
                ;   XY1 walks the buffer; D1 = remaining chars.
                MOVE    Y1, Y3
                LOADI   X1, #LINE_BUF
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
                CALL24  KLIB_SLOT_FOR_DRIVE
                BCS     .drive_switch_bad       ; D0 = ERR_BADDRIVE

                ; Slot is mounted. Update KOSH_CWD from D3.
                MOVE    Y0, Y3
                LOADI   X0, #KOSH_CWD
                STOREB  D3, [XY0]
                ; Switching drive lands at that drive's root: reset cluster.
                LOADI   D0, #0
                LOADI   X0, #KOSH_CWD_CLU
                STORED  D0, [XY0]
                BRA     .repl_loop

.drive_switch_bad:
                ; D0 = ERR_BADDRIVE. Use _KoshPrintErr to report.
                MOVE    Y0, Y3
                LOADI   X0, #msg_cwd_bad
                CALL16  _KoshPrintErr
                BRA     .repl_loop

.not_drive_switch:
                ; -- Bare "<name>:" / "path:" token (named drives v2) --------
                ; A first token containing ':' is a PATH, not a command word.
                ; Usually it is a CWD target (ram:, fonts:, fonts:bold, B:) so
                ; it goes to the cd resolver - but it may equally be a
                ; drive-qualified executable (ram:boot.ksh, b:hello.com,
                ; ram:hello). Part 61: CD_BARE=1 tells .cd_resolve that a
                ; non-directory target here is not an error; it branches back
                ; to .nds_nocolon and the token takes the ordinary
                ; cmd_table-miss -> .unknown -> _KoshExecFile path, which also
                ; gets the ".com" retry for free. Before this, `ram:boot.ksh`
                ; died with "cd: not a directory" and the only way to launch a
                ; drive-qualified name was `run`.
                LEA     XY0, XY2
.nds_scan:
                LOADB   D0, [XY0]
                AND     D0, #$FF
                BEQ     .nds_nocolon            ; nul, no ':' -> a real command
                CMP     D0, #':'
                BEQ     .nds_switch
                INC     XY0, #1
                BRA     .nds_scan
.nds_switch:
                LOADI   D0, #1                   ; Part 61: bare-token entry
                STOREP  D0, Y3, [#CD_BARE]
                LEA     XY0, XY2                 ; XY0 = whole token (path)
                BRA     .cd_resolve
.nds_nocolon:

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

                LOADI   D3, #cmd_table

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
                CMP     D0, #32
                BEQ     .do_mkdir
                CMP     D0, #33
                BEQ     .do_cd
                CMP     D0, #34
                BEQ     .do_pwd
                CMP     D0, #35
                BEQ     .do_rmdir
                CMP     D0, #36
                BEQ     .do_fg
                CMP     D0, #37
                BEQ     .do_assign
                ; Unknown tag - fall through.

.unknown:
                ; Not a built-in. Try it as an implicit executable. The
                ; command word (XY2) is the name; scan the remaining args
                ; for a trailing '&' so "name &" backgrounds, exactly like
                ; "run name.com &". _KoshExecFile appends ".com" on not-found.
                ;
                ; --- scan args region for a trailing '&' -> D3 (bg flag) ---
                LEA     XY0, XY2
                CALL24  KLIB_STRLEN              ; XY0 left on the name nul
                INC     XY0, #1                  ; -> first arg byte
                LEA     XY1, XY0                 ; XY1 walks; XY0 = args start
.unk_amp_end:
                LOADB   D0, [XY1]
                CMP     D0, #0
                BEQ.S   .unk_amp_back
                INC     XY1, #1
                BRA     .unk_amp_end
.unk_amp_back:
                ; XY1 -> nul. Step back over trailing spaces; if the last
                ; non-space byte is '&', it is a background launch.
                LOADI   D3, #0                   ; bg = 0
.unk_amp_sp:
                CMP     X1, X0
                BNE.S   .unk_amp_step
                CMP     Y1, Y0
                BEQ.S   .unk_have_bg             ; empty args -> fg
.unk_amp_step:
                DEC     XY1, #1
                LOADB   D0, [XY1]
                CMP     D0, #CH_SPACE
                BEQ     .unk_amp_sp
                CMP     D0, #'&'
                BNE.S   .unk_have_bg
                LOADI   D3, #1                   ; trailing '&' -> background

                ; Part 26: REMOVE the '&'. It is a shell operator, not an
                ; argument -- but this path only ever READ it, so it stayed in
                ; the command string and was handed to the child as part of
                ; its argv tail. `zork zork1.z3 &' reached the program as
                ; "zork1.z3 &", which it then failed to open, printing the
                ; error into a back-buffer nobody was looking at and exiting
                ; immediately. .do_run has always nulled it ("It's an '&'.
                ; Null it, set bg flag, trim preceding spaces"), so
                ; `run zork.com zork1.z3 &' worked and the bare form did not.
                ;
                ; XY1 points AT the '&' here. Nulling alone is enough:
                ; _KoshExecFile's .xf_sp_bk loop trims trailing spaces off the
                ; arg tail, so no preceding-space walk is needed. When the '&'
                ; was the only argument the tail collapses to empty and the
                ; boundary-restore below correctly leaves the word isolated.
                LOADI   D0, #0
                STOREB  D0, [XY1]                ; drop the '&'
.unk_have_bg:
                ; Part 15: if args follow the command word, restore the word/args
                ; boundary the dispatcher nul'd (first space) so the word + args are
                ; one contiguous "prog args" string - the same shape .do_run hands
                ; _KoshExecFile. XY0 = first arg byte (= word-nul + 1). If it is a nul
                ; there are no args (dispatcher's sentinel guarantees a clean nul) -
                ; leave the word isolated.
                LOADB   D0, [XY0]
                AND     D0, #$FF
                CMP     D0, #0
                BEQ     .unk_no_args             ; no args -> leave word isolated
                DEC     XY0, #1                  ; -> the nul between word and args
                LOADI   D0, #CH_SPACE
                STOREB  D0, [XY0]                ; restore the boundary space
.unk_no_args:
                LEA     XY0, XY2                 ; name = the command word (+ args)
                CALL16  _KoshExecFile
                BCC     .repl_loop               ; C=0 -> ran & reported
                ; C=1 -> failed, D0 = ERR_*.
                CMP     D0, #ERR_NOTFOUND        ; Z-flag test (not carry)
                BNE.S   .unknown_execerr
                ; Truly absent -> preserve the classic message.
                MOVE    Y0, Y3
                LOADI   X0, #msg_unknown
                TRAP    #TRAP_PUTS
                BRA     .repl_loop
.unknown_execerr:
                MOVE    Y0, Y3
                LOADI   X0, #msg_run_execerr
                CALL16  _KoshPrintErr
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
                .INCLUDE "../kosh/kosh_script.asm"   ; Part 57+ - .KSH script runner

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
                .WORD cmd_help_str
                .WORD   1                       ; tag: help        (kosh_help.asm)
                .WORD cmd_exit_str
                .WORD   2                       ; tag: exit        (kosh_cmds_util.asm)
                .WORD cmd_ps_str
                .WORD   3                       ; tag: ps          (kosh_cmds_sys.asm)
                ; tags 4 (mem), 5 (ver), 10 (uptime) removed in Part 23 -
                ; folded into info (tag 13).
                .WORD cmd_echo_str
                .WORD   6                       ; tag: echo        (kosh_cmds_util.asm)
                .WORD cmd_clear_str
                .WORD   7                       ; tag: clear       (kosh_cmds_util.asm)
                .WORD cmd_halt_str
                .WORD   8                       ; tag: halt        (kosh_cmds_util.asm)
                .WORD cmd_reboot_str
                .WORD   9                       ; tag: reboot      (kosh_cmds_util.asm)
                .WORD cmd_peek_str
                .WORD   11                      ; tag: peek        (kosh_cmds_mem.asm)
                .WORD cmd_dump_str
                .WORD   12                      ; tag: dump        (kosh_cmds_mem.asm)
                .WORD cmd_info_str
                .WORD   13                      ; tag: info        (kosh_cmds_sys.asm)
                .WORD cmd_task_str
                .WORD   14                      ; tag: task        (kosh_cmds_sys.asm)
                .WORD cmd_vol_str
                .WORD   15                      ; tag: vol         (kosh_cmds_fs.asm)
                .WORD cmd_ls_str
                .WORD   16                      ; tag: ls          (kosh_cmds_fs.asm)
                .WORD cmd_cat_str
                .WORD   17                      ; tag: cat         (kosh_cmds_fs.asm)
                .WORD cmd_format_str
                .WORD   18                      ; tag: format      (kosh_cmds_fs.asm)
                .WORD cmd_run_str
                .WORD   19                      ; tag: run         (kosh_cmds_fs.asm)
                .WORD cmd_disks_str
                .WORD   20                      ; tag: disks       (kosh_cmds_disk.asm)
                .WORD cmd_mount_str
                .WORD   21                      ; tag: mount       (kosh_cmds_disk.asm)
                .WORD cmd_unmount_str
                .WORD   22                      ; tag: unmount     (kosh_cmds_disk.asm)
                .WORD cmd_mkdisk_str
                .WORD   23                      ; tag: mkdisk      (kosh_cmds_disk.asm)
                .WORD cmd_rmdisk_str
                .WORD   24                      ; tag: rmdisk      (kosh_cmds_disk.asm)
                .WORD cmd_rename_str
                .WORD   25                      ; tag: rename      (kosh_cmds_disk.asm)
                .WORD cmd_cp_str
                .WORD   26                      ; tag: cp          (kosh_cmds_fs.asm)
                .WORD cmd_rm_str
                .WORD   27                      ; tag: rm          (kosh_cmds_fs.asm)
                .WORD cmd_mv_str
                .WORD   28                      ; tag: mv          (kosh_cmds_fs.asm)
                .WORD cmd_remount_str
                .WORD   29                      ; tag: remount     (kosh_cmds_disk.asm)
                .WORD cmd_load_str
                .WORD   30                      ; tag: load        (kosh_cmds_fs.asm)
                .WORD cmd_kill_str
                .WORD   31                      ; tag: kill        (kosh_cmds_sys.asm)
                .WORD cmd_mkdir_str
                .WORD   32                      ; tag: mkdir       (kosh_cmds_fs.asm)
                .WORD cmd_cd_str
                .WORD   33                      ; tag: cd          (kosh_cmds_fs.asm)
                .WORD cmd_pwd_str
                .WORD   34                      ; tag: pwd         (kosh_cmds_fs.asm)
                .WORD cmd_rmdir_str
                .WORD   35                      ; tag: rmdir       (kosh_cmds_fs.asm)
                .WORD cmd_fg_str
                .WORD   36                      ; tag: fg          (kosh_cmds_sys.asm)
                .WORD cmd_assign_str
                .WORD   37                      ; tag: assign      (kosh_cmds_fs.asm)
                .WORD   0                       ; sentinel
                .WORD   0


; ============================================================================
; Base strings (page-local - addressed via Y3 + page-offset).
;
;   Only the strings the REPL itself needs sit here. All command-specific
;   strings live in their group's include file.
; ============================================================================
msg_banner:    .TEXT   "k/OS shell\n",0
; kosh version - SINGLE SOURCE OF TRUTH. Emitted by the entry banner (above)
; and by the `info` command (kosh_cmds_sys.asm references kosh_ver_str). Bump
; this one line to change the version everywhere.
kosh_ver_str:  .TEXT   "kosh v1.02",0
msg_ver_tail:  .TEXT   " - type 'help'\n\n",0
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
                .WORD   $FFFF, err_name_badcall
                .WORD   $FFFE, err_name_buffull
                .WORD   $FFFD, err_name_invalid
                .WORD   $FFFC, err_name_nomem
                .WORD   $FFFB, err_name_noslots
                .WORD   $FFFA, err_name_toobig
                .WORD   $FFF9, err_name_badarg
                .WORD   $FFF8, err_name_notchild
                .WORD   $FFF7, err_name_deadlock
                .WORD   $FFF6, err_name_perm
                .WORD   $FFF5, err_name_busy
                .WORD   $FFE7, err_name_nofd
                .WORD   $FFE6, err_name_badfd
                .WORD   $FFE5, err_name_badpath
                .WORD   $FFE4, err_name_notfound
                .WORD   $FFE3, err_name_exists
                .WORD   $FFE2, err_name_readonly
                .WORD   $FFE1, err_name_nospace
                .WORD   $FFE0, err_name_io
                .WORD   $FFDF, err_name_baddrive
                .WORD   $FFDE, err_name_nomore
                .WORD   $FFDD, err_name_notexec
                .WORD   $FFDC, err_name_notdir
                .WORD   $FFDB, err_name_notempty
                .WORD   $FFD8, err_name_badheader        ; Part 60
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
err_name_notdir:    .TEXT "ERR_NOTDIR",0
err_name_notempty:  .TEXT "ERR_NOTEMPTY",0
err_name_badheader: .TEXT "ERR_BADHEADER",0
err_name_unk:       .TEXT "ERR_UNKNOWN",0
                    .ALIGN 2


; ============================================================================
; End of kosh.asm
; ============================================================================
