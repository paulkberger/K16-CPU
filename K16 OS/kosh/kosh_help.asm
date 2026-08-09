; ============================================================================
; kosh_help.asm - kosh `help` command (text + handler)
; ============================================================================
; Date:    17 June 2026
; Status:  Part 44 - subdirectory-aware filesystem commands.
;
; Revision: r19 - 8 August 2026 - Part 61: script + run help refreshed.
;             `run` now documents .ksh as well as .com (it always worked -
;             _KoshExecFile routes a ".ksh" tail to _KoshRunScript - but the
;             help only mentioned .com). Bare-name line notes the
;             drive-qualified X:NAME form that Part 61 unblocked, and that a
;             bare name may be a .ksh script as well as a .com. New lines
;             for `NAME.ksh -b` and the in-script `echo -b / -v` directive,
;             and the "';' comments / and blank lines are skipped" sentence
;             is whole again - the first -b line had been inserted between
;             its two halves.
; Revision: r18 - 30 June 2026 - Part 51: run line reworded for the VC
;             auto-switch model (a shell launch now switches to it; & launches
;             in the background) and ".com" auto-append; new paths: note that a
;             bare NAME runs NAME[.com] (implicit exec - "run" is optional).
; Revision: r17 - 28 June 2026 - Part 50: added "fg TID - bring task TID to
;             foreground" to the system: group, beneath kill.
; Revision: r16 - 17 June 2026 - Part 44 (Phase 2b): added the directory
;             commands that were never listed - rmdir, cd, pwd - to the
;             files: group, and a new paths: note explaining that bare names
;             are current-directory-relative, sub/name walks a subdirectory,
;             an "X:" prefix selects a drive root, and cp/mv into a directory
;             keep the source basename. Documents the CWD/subdir path handling
;             added across kosh_cmds_fs.asm / kosh_helpers.asm in Part 44.
;
; Revision: r15 - 29 May 2026 - Part 39: kosh.com migration. The string
;             reference at .do_help changed from
;                 LOADI   X0, #SPAWN_ENTRY_OFFSET + (msg_help - kosh_entry)
;             to bare
;                 LOADI   X0, #msg_help
;             because kosh.asm now assembles with .ORG $0200 and msg_help
;             resolves to its in-page address directly. No behaviour change.
;             Doc comment block describing the old offset scheme rewritten
;             to reflect the .ORG $0200 model. Requires kosh.asm r39+.
;
;           r14 - 28 May 2026 - Part 37: ls/cat/rm help lines reworded to
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
;   .INCLUDEd from kosh.asm after kosh_entry: so the strings declared here
;   live inside the kosh.com image. kosh.asm assembles with .ORG $0200, so
;   labels resolve directly to their in-page addresses (no manual rebase).
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
                LOADI   X0, #msg_help
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
               .BYTE   "          fg TID         - bring task TID to foreground\n"
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
               .BYTE   "          mkdir path     - create directory\n"
               .BYTE   "          rmdir path     - remove empty directory\n"
               .BYTE   "          cd [path]      - change current directory (no arg = root)\n"
               .BYTE   "          pwd            - print current directory\n"
               .BYTE   "          assign         - list, set (NM PATH), or clear (NM) a named volume\n"
               .BYTE   "          mv SRC DST     - rename or move file [*? -> drive]\n"
               .BYTE   "          format D [LBL] - format drive D (B..F) with optional label\n"
               .BYTE   "          run NAME [&]   - run NAME[.com] or a NAME.ksh script; a shell\n"
               .BYTE   "                           launch switches to it, & launches in the\n"
               .BYTE   "                           background (you stay in kosh)\n"
               .BYTE   "\n"
               .BYTE   "paths:    relative to current dir; sub/name = subdir; X: = drive root;\n"
               .BYTE   "          cp/mv into a directory keeps the source name\n"
               .BYTE   "          a bare NAME or X:NAME runs NAME[.com] or NAME.ksh - 'run' is optional\n"
               .BYTE   "\n"
               .BYTE   "scripts:  NAME.ksh runs as a script (one command per line); ';' comments\n"
               .BYTE   "          and blank lines are skipped; STARTUP.KSH on A:/B:/C: runs at boot\n"
               .BYTE   "          NAME.ksh -b    - brief: echo and command output share one line\n"
               .BYTE   "          echo -b / -v   - set brief/normal from inside a script\n"
               .BYTE   0
               .ALIGN

; Command name string (for cmd_table)
cmd_help_str:  .TEXT   "help",0
