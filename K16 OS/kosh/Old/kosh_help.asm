; ============================================================================
; kosh_help.asm - kosh `help` command (text + handler)
; ============================================================================
; Date:    28 May 2026
; Status:  Part 37 - files: section documents wildcard (glob) support.
;
; Revision: r14 - 28 May 2026 - Part 37: ls/cat/rm help lines reworded to
;             note * and ? pattern support; added cp/mv "PAT DRIVE:" lines
;             describing wildcard copy/move to a destination drive (matches
;             keep their basenames). Companion to kosh_cmds_fs.asm /
;             kosh_helpers.asm wildcard expansion work.
;
;           r13 - 18 May 2026 - Part 34: vol line updated to mention the
;             new disk-usage columns (label, total, used, free, use%).
;
;           r12 - 16 May 2026 - Part 31: "task N" -> "task TID" in help.
;             ps now shows TID/PTID columns and kill help already used
;             TID; `task N` was the lone holdout calling its argument
;             N. Cosmetic only - `task` accepts the same decimal as
;             before. Companion change in kosh_cmds_sys.asm r7 updates
;             the usage error message to match ("usage: task TID  ...").
;
;           r11 - 12 May 2026 - Part 20: "kill TID  - terminate task by TID"
;             added to the system: section, beneath `task N`.
;
;           r10 - 11 May 2026 - Part 25 r7: run help updated to mention
;             the new `&` background suffix.
;
;           r9 - 11 May 2026 - Part 25 r6: load command line added.
;
;           r8 - 11 May 2026 - Part 25 r5: remount command line added.
;
;           r7 - 11 May 2026 - Part 25 r4: bare drive-letter switch line
;             added; ls help text updated to mention "default = current".
;
;           r6 - 11 May 2026 - Part 25 r2: rm and mv command lines added.
;
;           r5 - 11 May 2026 - Part 25: cp command line added to files: section.
;
;           r4 - 11 May 2026 - Part 24 r2: rename command line added to
;             help under disks: section.
;
;           r3 - 11 May 2026 - Part 24: format help text updated to
;             "format D [LBL]  - format drive D (B..F) with optional label".
;             Reflects _FormatVolume's r8 widening to host disks.
;
;           r2 - 10 May 2026 - Part 23 reorganisation. Grouped command
;             list mirrors the kosh_cmds_*.asm source-file split:
;             shell / system / memory / files / disks. Five new disk
;             commands listed under "disks:". Blank lines between
;             groups for readability. All entries pre-indented two
;             spaces, with the group label at the same indent and
;             commands indented four spaces.
;
;           r1 - 7 May 2026 - extracted from kosh.asm during Phase 19 split.
;
;   .INCLUDEd from kosh.asm between kosh_entry: and kosh_entry_end: so the
;   page-relative addressing convention
;       SPAWN_ENTRY_OFFSET + (label - kosh_entry)
;   works for strings declared inside this file.
;
;   Why its own file: msg_help is the largest single string in kosh
;   (~750 bytes after Part 23) and is high-churn - every new command
;   adds a line. Splitting it out keeps command-group files self-
;   contained without any of them owning the master help text, and
;   means edits to help layout never touch a file owning dispatch logic.
;
;   Dispatch tag: 1 (defined in kosh.asm cmd_table).
; ============================================================================


; ----------------------------------------------------------------------------
; .do_help - print the master help text.
; ----------------------------------------------------------------------------
.do_help:
                MOVE    Y0, Y3
                LOADI   X0, #SPAWN_ENTRY_OFFSET + (msg_help - kosh_entry)
                TRAP    #TRAP_PUTS
                BRA     .repl_loop


; ============================================================================
; Help-command strings (page-local, addressed via Y3 + page-offset).
; ============================================================================

; r14 (kosh.asm history): switched from single .TEXT (which was truncating
; at ~298 bytes - actually a scratch-overlap symptom, not an assembler cap)
; to multi-line .BYTE. .BYTE allows any length, supports string literals +
; escapes, and (gotcha 28 fixed 22 April 2026) handles odd-count multi-line
; correctly. Final ,0 is the sys_puts terminator. .ALIGN restores word
; alignment before the next directive.
msg_help:      .BYTE   "shell:    help           - this list\n"
               .BYTE   "          exit           - leave shell\n"
               .BYTE   "          clear          - clear screen\n"
               .BYTE   "          echo TEXT      - print TEXT\n"
               .BYTE   "          halt           - stop the CPU\n"
               .BYTE   "          reboot         - restart the system\n"
               .BYTE   "          B:  C:  ...    - switch current drive\n"
               .BYTE   "\n"
               .BYTE   "system:   info           - version + system state\n"
               .BYTE   "          ps             - list active tasks\n"
               .BYTE   "          task TID       - show task details\n"
               .BYTE   "          kill TID       - terminate task by TID\n"
               .BYTE   "\n"
               .BYTE   "memory:   peek A         - read byte at A=[$]pp:[$]oooo or A=oooo\n"
               .BYTE   "          dump A [N]     - hex+ASCII dump (N bytes, default 64)\n"
               .BYTE   "\n"
               .BYTE   "disks:    disks          - list host disk images\n"
               .BYTE   "          mount NAME D   - mount NAME.KOS on drive D (C..F)\n"
               .BYTE   "          unmount D      - unmount drive D\n"
               .BYTE   "          mkdisk NAME N  - create blank N-sector image\n"
               .BYTE   "          rmdisk NAME    - delete image (must be unmounted)\n"
               .BYTE   "          rename D NAME  - rename mounted drive D's host file\n"
               .BYTE   "          remount D      - reload drive D from disk (for external edits)\n"
               .BYTE   "          load NAME [-f] - copy host load/NAME to current drive\n"
               .BYTE   "\n"
               .BYTE   "files:    vol            - disk usage (label, total, used, free, use%)\n"
               .BYTE   "          ls [path]      - list directory (default = current) [*?]\n"
               .BYTE   "          cat path       - print file contents [*?]\n"
               .BYTE   "          cp SRC DST     - copy file (refuses if DST exists) [*? -> drive]\n"
               .BYTE   "          rm path        - delete file [*?]\n"
               .BYTE   "          mv SRC DST     - rename or move file [*? -> drive]\n"
               .BYTE   "          format D [LBL] - format drive D (B..F) with optional label\n"
               .BYTE   "          run path [&]   - run a .COM (& = background)\n"
               .BYTE   0
               .ALIGN

; Command name string (for cmd_table)
cmd_help_str:  .TEXT   "help",0
