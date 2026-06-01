; ============================================================================
; kosh_cmds_sys.asm — kosh system-introspection commands
; ============================================================================
; Date:    29 May 2026
; Status:  Part 40 - dynamic version/phase in info banner.
;
; Revision: r12 — 29 May 2026 — Part 40: comments only — the version/phase
;             separator (shared splash_logo2b) tightened from two spaces
;             to one in kosh_splash.asm r8, so info's k/OS line now renders
;             "v1.0 Phase 39+". No code change here.
;
;           r11 — 29 May 2026 — Part 40: `info` now leads with a dynamic
;             "k/OS:     v<major>.<minor>  <phase>" line read live from
;             the page-$00 identity slots via the shared _OSSplashVer /
;             _OSSplashPhase helpers (kosh_splash.asm r5). The k/OS
;             version/phase were removed from msg_ver_full, which is now
;             a shell-only line ("Shell:    kosh v1.0") — kosh's own
;             version stays hardcoded since it is independent of the
;             kernel. New string info_kos_lbl ("k/OS:     v"); the
;             2-space separator reuses splash_logo2b. Requires
;             kosh_splash.asm r5+ and kos_boot.asm r51+.
;
;           r10 — 29 May 2026 — Part 39 post-first-boot fix: CALL24
;             _OSSplashHexByte at .do_info (line 671) converted to
;             CALL16. _OSSplashHexByte lives inside the kosh.com image
;             so its address depends on the runtime task page; CALL24
;             jumped to the assembly-time address (kernel page).
;             Symptom: `info` command broken. CALL16 uses Y3 implicitly,
;             which is the task's runtime page. Requires kosh.asm r39
;             (latest), kosh_splash.asm r4.
;
;             Also: bumped msg_ver_full from
;                 "Shell:    kosh v0.8 (k/OS Phase 16.7)"
;             to
;                 "Shell:    kosh v1.0 (k/OS v1.0, Phase 39+)"
;             to match the 1.0 milestone.
;
;           r9 — 29 May 2026 — Part 39: kosh.com migration. 12 CALL24
;             _Kosh* helper calls converted to CALL16, and 36 string
;             references switched from
;                 #SPAWN_ENTRY_OFFSET + (label - kosh_entry)
;             to bare
;                 #label
;             because kosh.asm now assembles with .ORG $0200 and labels
;             resolve directly to their in-page addresses. No behaviour
;             change. Requires kosh.asm r39+.
;
;           r8 — 17 May 2026 — Phase 14 Part 3b: BLOCKS+BYTES columns
;             added to .do_ps between PAGE and TICKS.
;             - msg_ps_hdr: "  TID PTID NAME     ST FG PAGE BLOCKS BYTES  TICKS"
;             - Per-row emit: one sys_heapstats_by_tid (TRAP #44) call
;               returns blocks (D1) and bytes (D2). Each column width 7,
;               left-aligned (digits + padding-spaces).
;             - sys_putdec returns D0 = digits emitted (1..5); the pad
;               loop emits (7 - D0) trailing spaces per field.
;             - Stack discipline: PUSH D2 (cursor) before the TRAP, PUSH
;               D2 (bytes return) after; POP between BLOCKS and BYTES
;               emit, final POP restores cursor at end.
;             - Idle/TID 0 row absorbs kernel-owned allocations (anything
;               stamped OWNER_KERNEL = 0 by _kmalloc when CURRENT_TCB == 0
;               during boot). Semantically a slight stretch (idle didn't
;               allocate them) but consistent with TCB_ID == 0 = idle.
;             Requires kos_kmalloc.asm r14+, kos_heap.asm r3+,
;             kos_defs.inc r39+ (TRAP_HEAPSTATS_BY_TID).
;
; Revision: r7 — 16 May 2026 — Part 31 follow-up: task usage uses TID.
;             msg_tcb_usage: "usage: task <id>  (decimal id 0..62)"
;             becomes "usage: task TID  (decimal 0..62)" — matches the
;             help text and the kill usage spelling. Cosmetic only.
;             Companion change in kosh_help.asm r12.
;
; Revision: r6 — 16 May 2026 — Part 31 follow-up: info Tasks line.
;             - Tasks line changed from "1 idle + N user slots" (boot-
;               splash capacity-only string) to "N of M user (+ 1 idle)"
;               where N is the live active-user-task count and M is
;               capacity. Walks USER_TCB_BASE..TCB_POOL_END counting
;               non-UNUSED slots — inverse of the free-page walk that
;               already feeds the Pages line.
;             - New splash_tasks_mid string (" of "). splash_tasks_lbl
;               changes from "Tasks:    1 idle + " to "Tasks:    "
;               (label only). splash_tasks_tail changes from " user
;               slots\n" to " user (+ 1 idle)\n".
;             - kosh_splash.asm updated in lockstep so boot splash and
;               info still share strings (Part 30 invariant). At boot
;               kosh has just spawned, so splash renders "1 of 62 user
;               (+ 1 idle)" — accurate, not aspirational.
;
;           r5 — 16 May 2026 — Part 31: ps column overhaul.
;             - Renamed ID column to TID (consistent with k/OS "Task ID"
;               terminology — there are no processes, only tasks).
;             - Added PTID column (Parent Task ID, from TCB_PARENT_ID
;               at TCB+$16). Width 4, left-aligned. Idle and kosh both
;               show 0 (built by kernel at boot). Children spawned via
;               sys_spawn show the spawner's TID. Orphans (parent died,
;               _OrphanChildren ran) revert to 0.
;             - PTID pad logic uses 3/2/1/0 trailing spaces (one wider
;               than TID's 2/1/0 to fill the 4-wide field). The TID
;               column kept width 3 because TIDs cap at 62 (2 digits)
;               and the header word "TID" is exactly 3 chars.
;             - Renamed "PG" column to "PAGE" and changed semantics
;               from page-count (always 1 today, useless) to primary-
;               page-byte (the actual page the task lives in, e.g. $02,
;               $03, ...). Read from TCB_SAVED_Y low byte. Rendered as
;               "$nn" via _KoshEmitByteHex into ROW_BUF — same idiom as
;               .do_task. Width 5 ("$nn" + 2 sep spaces).
;             - Header has one space between "PAGE" and "TICKS" (not
;               two) so the TICKS column starts at the same absolute
;               position in header and data rows.
;             - PAGE emits ROW_BUF, then TICKS rebuilds ROW_BUF for its
;               own KLIB_UTOA32 render. The two uses are serial within
;               the row, so no conflict.
;             - msg_ps_hdr updated: "TID  PTID NAME     ST FG PAGE TICKS".
;             Requires kos_defs.inc r36+ (TCB_PARENT_ID, TCB_SAVED_Y).
;
;           r4 — 14 May 2026 — k/OS Part 30: .do_info overhaul.
;             - Labels capitalised to match kosh_splash.asm exactly
;               (Host/Kernel/Heap/Pages/Tasks vs old lowercase).
;             - All info line labels except Ticks now share string
;               symbols with kosh_splash.asm (splash_host_lbl,
;               splash_kernel, splash_heap_*, splash_pages_*,
;               splash_tasks_*). Pages line gains the "($02..$XX)"
;               range hex; tasks line shows capacity "1 idle + N user
;               slots" matching splash.
;             - All page-$00 reads now use LOADZ (was LOADD with explicit
;               Y0=$00 setup; LOADZ is the convention since v3.10).
;             - Free-page count flipped from "non-UNUSED" (used) to
;               "UNUSED" (free) to match splash framing.
;             - Ticks line: 32-bit raw + 32-bit uptime in seconds.
;               Uses KLIB_UTOA32 for digits (rendered into ROW_BUF) and
;               KLIB_DIVMOD32 for /30 conversion. Replaces the prior
;               repeated-subtraction loop, which was a 16-bit-only hack.
;               Reads SYS_TICKS (low) and SYS_TICKS_HI (high, was
;               SYS_FLAGS) — both updated in _TimerIRQ since
;               kos_ctxsw.asm r34.
;             - Twelve orphan info strings deleted (msg_info_host,
;               msg_host_emu/digital, msg_info_kernel, msg_info_heap*,
;               msg_info_pages*, msg_info_tasks*). ROM saving ~190 bytes.
;             Requires kos_defs.inc r36+, kos_ctxsw.asm r34+,
;             kos_boot.asm r45+, kosh_splash.asm r1+.
;
; Revision: r3 — 12 May 2026 — Part 20: kosh `kill` command.
;             Added .do_kill handler (tag 31 in cmd_table). Parses
;             decimal TID via KLIB_ATOH, calls TRAP_KILL, prints
;             "kill: …" prefix + ERR_NAME on failure. Success silent.
;             Added cmd_kill_str, msg_kill_usage/badarg/err_pfx.
;             Also extended state_chars from "RBDUW" to "RBDUWS" so
;             `ps` correctly displays TS_SEMWAIT victims as 'S' instead
;             of indexing past the table.
;             Requires kosh.asm r32+ (dispatch entry + err name table
;             entries) and kos_defs.inc r29+ (TRAP_KILL, ERR_PERM, ERR_BUSY).
;
; Revision: r2 — 10 May 2026 — Part 23: info absorbs ver, mem, and
;             uptime. ver and mem were redundant once info shipped;
;             uptime was a strict subset of info's ticks line.
;             Removed: handlers .do_ver/.do_mem/.do_uptime, command
;             strings cmd_ver_str/cmd_mem_str/cmd_uptime_str, dead
;             msg_mem_* strings (~60 bytes ROM). Cmd_table tags 4, 5,
;             10 are now numeric gaps in kosh.asm — preserved rather
;             than renumbered to keep the rest of the table stable.
;             info now prepends msg_ver_full and ends with
;             "ticks: N (Ms)".
;
;           r1 — 7 May 2026 — extracted from kosh.asm during Phase 19 split.
;
;   .INCLUDEd from kosh.asm after kosh_entry: so the strings declared here
;   live inside the kosh.com image. kosh.asm assembles with .ORG $0200, so
;   labels resolve directly to their in-page addresses (no manual rebase).
;
;   Commands (dispatch tags in parens, defined in kosh.asm cmd_table):
;     info        (13) - canonical: version banner + host/kernel/heap/
;                        pages/tasks/ticks (with seconds) dashboard
;     ps          (3)  - list active tasks (TID/PTID/NAME/ST/FG/PAGE/TICKS)
;     task N      (14) - show task N details (renamed from `tcb` in Part 23)
;
;   These commands read kernel page $00 directly (no protection model
;   yet). When a real protection model arrives, ps/mem/info/tcb become
;   sys_* TRAPs.
;
;   Most output uses raw TRAP_PUTDEC/PUTCHAR per row. They were the
;   first commands written; can be refactored to buffer-and-blast later
;   with KLIB_UTOA (cursor-style as of v1.1).
; ============================================================================


; ----------------------------------------------------------------------------
; .do_ps — list active tasks.
;
;   Walks the TCB pool (kernel page $00, $0800..$2780, step 128). Skips
;   TS_UNUSED slots. For each active slot prints:
;
;       TID PTID NAME     ST FG PAGE TICKS
;
;   Columns:
;     TID   width 3, left-aligned, decimal task id
;     PTID  width 4, left-aligned, decimal parent task id (0 = kernel)
;     NAME  width 8, left-aligned, NUL-padded with spaces
;     ST    width 2, single letter from state_chars
;     FG    width 2, single letter: '*' fg shell, 's' bg shell, '-' other
;     PAGE  width 5, "$nn" (primary page byte from TCB_SAVED_Y low byte)
;     TICKS variable, left-aligned, 32-bit preempt counter, last column
;
;   State letters: R=ready, B=blocked, D=dead, U=unused (skipped),
;   W=waiting (sleep), S=sem-waiting.
;
;   Reads kernel page $00 directly (LOADI Y0, #$00). The K16 has no
;   hardware page protection — reading kernel state from a user task is
;   convention-breaking but harmless for read-only introspection.
;   When a real protection model arrives, this becomes a sys_ps TRAP.
;
;   D2 = TCB cursor (16-bit byte offset within page $00).
; ----------------------------------------------------------------------------
.do_ps:
                ; Header
                MOVE    Y0, Y3
                LOADI   X0, #msg_ps_hdr
                TRAP    #TRAP_PUTS

                LOADI   D2, #TCB_POOL_BASE
.ps_loop:
                ; Done?
                CMP     D2, #TCB_POOL_END
                BHS     .ps_done

                ; Read TCB_STATE (kernel page).
                LOADI   Y0, #$00
                MOVE    X0, D2
                LOADD   D0, [XY0+#TCB_STATE]
                LOW     D0
                CMP     D0, #TS_UNUSED
                BEQ     .ps_next

                ; --- Active slot: emit one row -------------------------

                ; --- Row indent ---------------------------------------
                MOVE    Y0, Y3
                LOADI   X0, #msg_ps_indent
                TRAP    #TRAP_PUTS

                ; --- TID column (3 wide, left-aligned) -----------------
                LOADI   Y0, #$00
                MOVE    X0, D2
                LOADD   D0, [XY0+#TCB_ID]
                TRAP    #TRAP_PUTDEC
                ; Pad to width 3:
                ;   value < 10  -> 2 trailing spaces
                ;   value < 100 -> 1 trailing space
                ;   else        -> 0 trailing spaces
                LOADI   Y0, #$00
                MOVE    X0, D2
                LOADD   D0, [XY0+#TCB_ID]
                CMP     D0, #100
                BHS.S   .tid_pad_done
                LOADI   D0, #CH_SPACE
                TRAP    #TRAP_PUTCHAR
                LOADI   Y0, #$00
                MOVE    X0, D2
                LOADD   D0, [XY0+#TCB_ID]
                CMP     D0, #10
                BHS.S   .tid_pad_done
                LOADI   D0, #CH_SPACE
                TRAP    #TRAP_PUTCHAR
.tid_pad_done:
                LOADI   D0, #CH_SPACE
                TRAP    #TRAP_PUTCHAR

                ; --- PTID column (4 wide, left-aligned) ----------------
                ; Parent task ID. Value range 0..62 today.
                ; Pad: <10 → 3 spaces; <100 → 2 spaces; else 1 space.
                ; (Pad branches mirror TID logic, one wider.)
                LOADI   Y0, #$00
                MOVE    X0, D2
                LOADD   D0, [XY0+#TCB_PARENT_ID]
                TRAP    #TRAP_PUTDEC
                ; Pad space #1 (always — value 100..999 still needs one).
                LOADI   D0, #CH_SPACE
                TRAP    #TRAP_PUTCHAR
                ; Pad space #2 (if value < 100).
                LOADI   Y0, #$00
                MOVE    X0, D2
                LOADD   D0, [XY0+#TCB_PARENT_ID]
                CMP     D0, #100
                BHS.S   .ptid_pad_done
                LOADI   D0, #CH_SPACE
                TRAP    #TRAP_PUTCHAR
                ; Pad space #3 (if value < 10).
                LOADI   Y0, #$00
                MOVE    X0, D2
                LOADD   D0, [XY0+#TCB_PARENT_ID]
                CMP     D0, #10
                BHS.S   .ptid_pad_done
                LOADI   D0, #CH_SPACE
                TRAP    #TRAP_PUTCHAR
.ptid_pad_done:
                LOADI   D0, #CH_SPACE
                TRAP    #TRAP_PUTCHAR

                ; --- NAME column (8 wide, left-aligned) ----------------
                ; sys_putchar clobbers XY0, so we keep the source byte
                ; address in D1 (kernel-page offset) and rebuild XY0
                ; each iteration. D3 = remaining char budget (also tracks
                ; how many pad spaces we need afterwards: pad = D3 after
                ; the name-emit loop terminates).
                MOVE    D1, D2
                ADD     D1, #TCB_NAME           ; D1 = TCB+TCB_NAME byte offset
                LOADI   D3, #8
.ps_name_loop:
                LOADI   Y0, #$00
                MOVE    X0, D1
                LOADB   D0, [XY0]
                CMP     D0, #0
                BEQ.S   .ps_name_pad            ; stop at NUL, pad remainder
                TRAP    #TRAP_PUTCHAR
                ADD     D1, #1
                SUB     D3, #1
                BNE     .ps_name_loop
.ps_name_pad:
                ; D3 = spaces still needed to reach width 8.
                CMP     D3, #0
                BEQ.S   .ps_name_done
.ps_name_pad_loop:
                LOADI   D0, #CH_SPACE
                TRAP    #TRAP_PUTCHAR
                SUB     D3, #1
                BNE     .ps_name_pad_loop
.ps_name_done:
                ; Column separator
                LOADI   D0, #CH_SPACE
                TRAP    #TRAP_PUTCHAR

                ; --- ST column (2 wide, left-aligned single letter) ----
                LOADI   Y0, #$00
                MOVE    X0, D2
                LOADD   D0, [XY0+#TCB_STATE]
                LOW     D0
                MOVE    Y0, Y3
                LOADI   X0, #state_chars
                ADD     X0, D0
                LOADB   D0, [XY0]
                TRAP    #TRAP_PUTCHAR
                LOADI   D0, #CH_SPACE
                TRAP    #TRAP_PUTCHAR
                LOADI   D0, #CH_SPACE
                TRAP    #TRAP_PUTCHAR

                ; --- FG column (Phase B) — single char + pad + sep ------
                ;   '*' if this task is the foreground shell
                ;   's' if registered as a shell but background
                ;   '-' if not a registered shell
                LOADI   Y0, #$00
                MOVE    X0, D2
                LOADD   D0, [XY0+#TCB_FLAGS]
                AND     D0, #TF_HAS_BACKBUF
                CMP     D0, #0
                BEQ.S   .ps_fg_dash             ; not a shell

                ; It's a shell. Foreground?
                LOADI   Y0, #$00
                MOVE    X0, D2
                LOADD   D0, [XY0+#TCB_ID]       ; D0 = our TID
                LOADZ   D1, [#FOREGROUND_TCB]   ; D1 = fg TID
                CMP     D0, D1
                BNE.S   .ps_fg_bg
                LOADI   D0, #'*'
                BRA.S   .ps_fg_emit
.ps_fg_bg:
                LOADI   D0, #'s'
                BRA.S   .ps_fg_emit
.ps_fg_dash:
                LOADI   D0, #'-'
.ps_fg_emit:
                TRAP    #TRAP_PUTCHAR
                LOADI   D0, #CH_SPACE
                TRAP    #TRAP_PUTCHAR
                LOADI   D0, #CH_SPACE
                TRAP    #TRAP_PUTCHAR

                ; --- PAGE column (5 wide, left-aligned "$nn"+2 spaces) --
                ; Primary page byte = low byte of TCB_SAVED_Y.
                ; Render "$nn" into ROW_BUF via _KoshEmitByteHex (same
                ; idiom as .do_task), emit via TRAP_PUTS, then 2 spaces.
                LOADI   Y0, #$00
                MOVE    X0, D2
                LOADD   D0, [XY0+#TCB_SAVED_Y]
                LOW     D0

                ; Build "$nn\0" in ROW_BUF.
                MOVE    Y1, Y3
                LOADI   X1, #ROW_BUF
                MOVE    D3, D0                  ; D3 = page byte (D2 is TCB cursor!)
                LOADI   D0, #'$'
                CALL16  _KoshEmitByte
                MOVE    D0, D3
                CALL16  _KoshEmitByteHex
                LOADI   D0, #0
                CALL16  _KoshEmitByte

                ; Emit it.
                MOVE    Y0, Y3
                LOADI   X0, #ROW_BUF
                TRAP    #TRAP_PUTS

                ; 2 separator spaces after PAGE.
                LOADI   D0, #CH_SPACE
                TRAP    #TRAP_PUTCHAR
                LOADI   D0, #CH_SPACE
                TRAP    #TRAP_PUTCHAR

                ; --- BLOCKS column (7 wide, left-aligned) ----------------
                ; --- BYTES  column (7 wide, left-aligned) ----------------
                ; Both columns come from one sys_heapstats_by_tid call.
                ; The wrapper preserves XY1/XY2 and returns D0 = input TID,
                ; D1 = block count, D2 = byte total. We need to print these
                ; in order while saving D2 (the ps loop's TCB cursor) AND
                ; the bytes value (also D2 after the TRAP).
                ;
                ; Plan:
                ;   PUSH D2 (cursor)
                ;   Load TCB_ID into D0
                ;   TRAP #TRAP_HEAPSTATS_BY_TID  -> D1=blocks, D2=bytes
                ;   PUSH D2 (bytes)
                ;   Print blocks (D1) via TRAP_PUTDEC; pad to width 7
                ;   POP D0 (bytes) -> D0
                ;   Print bytes via TRAP_PUTDEC; pad to width 7
                ;   POP D2 (cursor)
                PUSH    D2, XY3                         ; save cursor

                LOADI   Y0, #$00
                MOVE    X0, D2
                LOADD   D0, [XY0+#TCB_ID]
                TRAP    #TRAP_HEAPSTATS_BY_TID          ; D1=blocks, D2=bytes
                PUSH    D2, XY3                         ; save bytes

                ; Emit BLOCKS. sys_putdec returns D0 = digits emitted (1..5);
                ; pad with (7 - D0) spaces.
                MOVE    D0, D1
                TRAP    #TRAP_PUTDEC                    ; D0 = digit count
                LOADI   D1, #7
                SUB     D1, D0
.ps_blocks_pad:
                CMP     D1, #0
                BEQ.S   .ps_blocks_pad_done
                LOADI   D0, #CH_SPACE
                TRAP    #TRAP_PUTCHAR
                SUB     D1, #1
                BRA     .ps_blocks_pad
.ps_blocks_pad_done:

                ; Emit BYTES.
                POP     D0, XY3                         ; D0 = bytes
                TRAP    #TRAP_PUTDEC                    ; D0 = digit count
                LOADI   D1, #7
                SUB     D1, D0
.ps_bytes_pad:
                CMP     D1, #0
                BEQ.S   .ps_bytes_pad_done
                LOADI   D0, #CH_SPACE
                TRAP    #TRAP_PUTCHAR
                SUB     D1, #1
                BRA     .ps_bytes_pad
.ps_bytes_pad_done:

                POP     D2, XY3                         ; D2 = cursor (restored)

                ; --- TICKS column (last column, left-aligned) -----------
                ; 32-bit preempt counter: low word at TCB_PREEMPT_COUNT
                ; ($1E, within imm5), high word at TCB_PREEMPT_COUNT_HI
                ; ($22, needs mode-01 [XY+D]).
                ; Wraps at ~4 years @ 30Hz. KLIB_UTOA32 builds the
                ; decimal string into ROW_BUF (cursor-style), then we
                ; walk the buffer emitting bytes via TRAP_PUTCHAR.
                ; KLIB_UTOA32 clobbers D1..D3 and XY0; D2 is the ps loop's
                ; TCB cursor, so save it across the call.
                LOADI   Y0, #$00
                MOVE    X0, D2
                LOADD   D0, [XY0+#TCB_PREEMPT_COUNT]    ; D0 = low word
                LOADI   D1, #TCB_PREEMPT_COUNT_HI
                LOADD   D1, [XY0+D1]                    ; D1 = high word

                ; Build into ROW_BUF.
                MOVE    Y0, Y3
                LOADI   X0, #ROW_BUF                    ; XY0 = buffer start

                PUSH    D2, XY3                         ; preserve TCB cursor
                CALL24  KLIB_UTOA32
                POP     D2, XY3
                ; XY0 now points AT the nul. D0 = digit count.

                ; Emit digits from ROW_BUF. Use D1 = cursor offset, walk
                ; until we hit the nul. sys_putchar clobbers XY0, so we
                ; rebuild it each iteration from D1.
                LOADI   D1, #ROW_BUF
.ps_ticks_emit:
                MOVE    Y0, Y3
                MOVE    X0, D1
                LOADB   D0, [XY0]
                CMP     D0, #0
                BEQ.S   .ps_ticks_done
                TRAP    #TRAP_PUTCHAR
                ADD     D1, #1
                BRA     .ps_ticks_emit
.ps_ticks_done:

                ;   "\n"
                LOADI   D0, #CH_LF
                TRAP    #TRAP_PUTCHAR

.ps_next:
                ADD     D2, #TCB_SIZE
                BRA     .ps_loop

.ps_done:
                BRA     .repl_loop


; ----------------------------------------------------------------------------
; .do_kill — terminate a task by TID (Part 20).
;
;   Syntax: kill <tid>
;
;   Parses the decimal TID after "kill ", calls TRAP_KILL, and on
;   failure prints "kill: <msg> [ERR_NAME $HHHH]\n". Success is silent
;   (Unix idiom).
;
;   Permission is enforced by sys_kill: kosh has TF_PRIV, so it can
;   kill any task. ERR_PERM here would indicate a kernel bug (kosh's
;   TCB_FLAGS didn't get TF_PRIV at boot).
;
;   Quick errors:
;     no arg           → "kill: usage: kill <tid>"
;     non-numeric arg  → "kill: bad TID (need decimal number)"
;     TID == kosh's    → ERR_INVALID  ("can't kill self")
;     TID 0            → ERR_INVALID  (idle is not killable)
;     unknown TID      → ERR_NOTFOUND
;     TS_SEMWAIT victim→ ERR_BUSY     (v1 sem-queue unlink limitation)
; ----------------------------------------------------------------------------
.do_kill:
                ; -- Locate args zstring (after "kill\0" in LINE_BUF) ---------
                LEA     XY0, XY2
                CALL24  KLIB_STRLEN
                INC     XY0, #1                 ; step past nul

                ; Skip leading whitespace.
.kill_skip_ws:
                LOADB   D0, [XY0]
                CMP     D0, #CH_SPACE
                BNE.S   .kill_check_arg
                INC     XY0, #1
                BRA     .kill_skip_ws

.kill_check_arg:
                CMP     D0, #0
                BEQ     .kill_usage

                ; -- Parse the TID via KLIB_ATOI ------------------------------
                ; KLIB_ATOI: decimal default, optional '$' prefix accepts hex.
                ; Returns D0 = value, D1 = digits consumed, C=0 on success.
                CALL24  KLIB_ATOI
                BCS     .kill_bad_arg
                ; D0 = TID. Range 0..62 expected; sys_kill validates further.

                ; -- Call sys_kill --------------------------------------------
                TRAP    #TRAP_KILL
                BCS     .kill_err

                ; Success — silent return to prompt.
                BRA     .repl_loop

.kill_usage:
                MOVE    Y0, Y3
                LOADI   X0, #msg_kill_usage
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.kill_bad_arg:
                MOVE    Y0, Y3
                LOADI   X0, #msg_kill_badarg
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.kill_err:
                ; D0 = ERR_* code from sys_kill.
                MOVE    Y0, Y3
                LOADI   X0, #msg_kill_err_pfx
                CALL16  _KoshPrintErr
                BRA     .repl_loop


; ----------------------------------------------------------------------------
; .do_info — current system state dashboard.
;
;   Part 30 r2 (14 May 2026): rewritten to share string symbols with
;   kosh_splash.asm so info and the boot splash render identical labels.
;   Reads live values from kernel page $00. The only line not in the
;   splash is the trailing "Ticks: N (Ms)" — 32-bit since kos_ctxsw.asm
;   r34 / kos_defs.inc r36 promoted SYS_TICKS to 32 bits.
;
;   Layout (matches splash exactly except final Ticks line):
;     k/OS:     v1.0  Phase 39+        (live from identity slots)
;     Shell:    kosh v1.0              (kosh's own, static)
;     Host:     EMU (VT100, 16MB)
;     Kernel:   Page $00, stack $FFFE
;     Heap:     Page $01, 65500 bytes free in 1 region(s)
;     Pages:    61 free of 62 user pages ($02..$3F)
;     Tasks:    1 of 62 user (+ 1 idle)
;     Ticks:    1234567 (41152s)
;
;   32-bit values rendered via KLIB_UTOA32 → ROW_BUF → sys_puts.
;   Uptime computed via KLIB_DIVMOD32 ÷ 30 (replaces the prior
;   repeated-subtraction loop, which only worked for 16-bit ticks).
; ----------------------------------------------------------------------------
.do_info:
                ; --- k/OS: live version + phase (Part 40) ------------------
                MOVE    Y0, Y3
                LOADI   X0, #info_kos_lbl       ; "k/OS:     v"
                TRAP    #TRAP_PUTS
                CALL16  _OSSplashVer            ; "1.0"
                MOVE    Y0, Y3
                LOADI   X0, #splash_logo2b      ; " " (shared 1-space sep)
                TRAP    #TRAP_PUTS
                CALL16  _OSSplashPhase          ; "Phase 39+"
                LOADI   D0, #$0A
                TRAP    #TRAP_PUTCHAR

                ; --- Shell: kosh's own version (static) --------------------
                MOVE    Y0, Y3
                LOADI   X0, #msg_ver_full
                TRAP    #TRAP_PUTS

                ; --- Host: -------------------------------------------------
                MOVE    Y0, Y3
                LOADI   X0, #splash_host_lbl
                TRAP    #TRAP_PUTS

                LOADZ   D0, [#KOS_HOST]
                LOW     D0
                CMP     D0, #HOST_DIGITAL
                BEQ.S   .info_host_dig
                MOVE    Y0, Y3
                LOADI   X0, #splash_host_emu
                BRA.S   .info_host_emit
.info_host_dig:
                MOVE    Y0, Y3
                LOADI   X0, #splash_host_dig
.info_host_emit:
                TRAP    #TRAP_PUTS

                ; --- Kernel: -----------------------------------------------
                MOVE    Y0, Y3
                LOADI   X0, #splash_kernel
                TRAP    #TRAP_PUTS

                ; --- Heap: -------------------------------------------------
                MOVE    Y0, Y3
                LOADI   X0, #splash_heap_lbl
                TRAP    #TRAP_PUTS

                LOADZ   D0, [#HEAP_BYTES_FREE]
                TRAP    #TRAP_PUTDEC

                MOVE    Y0, Y3
                LOADI   X0, #splash_heap_mid
                TRAP    #TRAP_PUTS

                LOADZ   D0, [#HEAP_REGIONS]
                TRAP    #TRAP_PUTDEC

                MOVE    Y0, Y3
                LOADI   X0, #splash_heap_tail
                TRAP    #TRAP_PUTS

                ; --- Pages: "N free of M user pages ($02..$XX)" -------------
                MOVE    Y0, Y3
                LOADI   X0, #splash_pages_lbl
                TRAP    #TRAP_PUTS

                ; Free count: walk USER_TCB_BASE..TCB_POOL_END counting UNUSED.
                LOADI   D2, #USER_TCB_BASE
                LOADI   D3, #0
.info_free_loop:
                CMP     D2, #TCB_POOL_END
                BHS     .info_free_done
                LOADI   Y0, #$00
                MOVE    X0, D2
                LOADD   D0, [XY0+#TCB_STATE]
                LOW     D0
                CMP     D0, #TS_UNUSED
                BNE.S   .info_free_skip
                ADD     D3, #1
.info_free_skip:
                ADD     D2, #TCB_SIZE
                BRA     .info_free_loop
.info_free_done:
                MOVE    D0, D3
                TRAP    #TRAP_PUTDEC

                MOVE    Y0, Y3
                LOADI   X0, #splash_pages_mid
                TRAP    #TRAP_PUTS

                ; Total user pages = KOS_USER_PAGE_END - USER_PAGE_BASE + 1
                LOADZ   D0, [#KOS_USER_PAGE_END]
                LOW     D0
                SUB     D0, #USER_PAGE_BASE
                ADD     D0, #1
                TRAP    #TRAP_PUTDEC

                MOVE    Y0, Y3
                LOADI   X0, #splash_pages_range
                TRAP    #TRAP_PUTS

                ; Range upper bound as 2 hex digits via _OSSplashHexByte
                ; (lives in kosh_splash.asm, CALL24-callable from here).
                LOADZ   D0, [#KOS_USER_PAGE_END]
                LOW     D0
                CALL16  _OSSplashHexByte

                MOVE    Y0, Y3
                LOADI   X0, #splash_pages_tail
                TRAP    #TRAP_PUTS

                ; --- Tasks: "N of M user (+ 1 idle)" -----------------------
                ; Part 31 r6 (16 May 2026): show live active count (N) /
                ; capacity (M). At boot N=1 (kosh just spawned, no other
                ; user tasks yet); thereafter N counts every non-UNUSED
                ; user slot.
                MOVE    Y0, Y3
                LOADI   X0, #splash_tasks_lbl
                TRAP    #TRAP_PUTS

                ; Active count: walk USER_TCB_BASE..TCB_POOL_END counting
                ; non-UNUSED. Inverse of the free-page walk above.
                LOADI   D2, #USER_TCB_BASE
                LOADI   D3, #0
.info_active_loop:
                CMP     D2, #TCB_POOL_END
                BHS     .info_active_done
                LOADI   Y0, #$00
                MOVE    X0, D2
                LOADD   D0, [XY0+#TCB_STATE]
                LOW     D0
                CMP     D0, #TS_UNUSED
                BEQ.S   .info_active_skip
                ADD     D3, #1
.info_active_skip:
                ADD     D2, #TCB_SIZE
                BRA     .info_active_loop
.info_active_done:
                MOVE    D0, D3
                TRAP    #TRAP_PUTDEC

                MOVE    Y0, Y3
                LOADI   X0, #splash_tasks_mid
                TRAP    #TRAP_PUTS

                ; Capacity = KOS_USER_PAGE_END - USER_PAGE_BASE + 1
                LOADZ   D0, [#KOS_USER_PAGE_END]
                LOW     D0
                SUB     D0, #USER_PAGE_BASE
                ADD     D0, #1
                TRAP    #TRAP_PUTDEC

                MOVE    Y0, Y3
                LOADI   X0, #splash_tasks_tail
                TRAP    #TRAP_PUTS

                ; --- Ticks: 32-bit raw + uptime in seconds -----------------
                MOVE    Y0, Y3
                LOADI   X0, #msg_info_ticks
                TRAP    #TRAP_PUTS

                ; Load 32-bit ticks: D0 = low, D1 = high. KLIB_UTOA32
                ; renders to ROW_BUF, advancing XY0 and writing nul.
                LOADZ   D0, [#SYS_TICKS]
                LOADZ   D1, [#SYS_TICKS_HI]

                ; Preserve D1:D0 (we need them again for the divide).
                PUSH    D0, XY3
                PUSH    D1, XY3

                MOVE    Y0, Y3
                LOADI   X0, #ROW_BUF
                CALL24  KLIB_UTOA32

                ; Emit the rendered string.
                MOVE    Y0, Y3
                LOADI   X0, #ROW_BUF
                TRAP    #TRAP_PUTS

                ; " (" prefix for uptime
                LOADI   D0, #CH_SPACE
                TRAP    #TRAP_PUTCHAR
                LOADI   D0, #'('
                TRAP    #TRAP_PUTCHAR

                ; Compute ticks / 30 via _KDivmod32. D1:D0 = dividend,
                ; D2 = divisor (30) → D1:D0 = quotient (seconds).
                POP     D1, XY3
                POP     D0, XY3
                LOADI   D2, #30
                CALL24  KLIB_DIVMOD32

                ; Emit seconds via UTOA32 into ROW_BUF.
                MOVE    Y0, Y3
                LOADI   X0, #ROW_BUF
                CALL24  KLIB_UTOA32

                MOVE    Y0, Y3
                LOADI   X0, #ROW_BUF
                TRAP    #TRAP_PUTS

                ; "s)\n" suffix
                LOADI   D0, #'s'
                TRAP    #TRAP_PUTCHAR
                LOADI   D0, #')'
                TRAP    #TRAP_PUTCHAR
                LOADI   D0, #CH_LF
                TRAP    #TRAP_PUTCHAR

                BRA     .repl_loop


; ----------------------------------------------------------------------------
; .do_task — show details of one task.
;
;   Args: a single decimal task ID (0..62). Looks up the corresponding
;   slot in the TCB pool and prints the named fields.
;
;   Reads kernel page $00 directly. Same convention-breaking approach as
;   ps — fine until there's a real protection model.
;
;   Output (one task per call):
;     task 1:
;       state:    R
;       page:     $02
;       saved x:  $FFDC
;       parent:   0
;       yields:   0
;       preempts: 17
;       name:     kosh
;
;   Renamed from .do_tcb in Part 23 — "tcb" was kernel jargon leaking
;   into the user surface. "task" matches the user's mental model and
;   the `task N:` row label in the output. Internal local labels still
;   carry the .tcb_ prefix; they're scope-local and not user-visible.
;
;   NOTE: reuses DUMP_PAGE scratch slot as a 16-bit TCB pointer stash.
;   That's safe because dump and task are mutually exclusive (one cmd
;   at a time), but if either ever becomes re-entrant or we add a
;   command that runs concurrently, we'll need a dedicated TCB_PTR slot.
; ----------------------------------------------------------------------------
.do_task:
                ; Find args via KLIB_STRLEN.
                LEA     XY0, XY2
                CALL24  KLIB_STRLEN
                INC     XY0, #1
                LOADB   D0, [XY0]
                CMP     D0, #0
                BNE.S   .tcb_have_args
                MOVE    Y0, Y3
                LOADI   X0, #msg_tcb_usage
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.tcb_have_args:
                ; Skip leading whitespace.
.tcb_skip_ws:
                LOADB   D0, [XY0]
                CMP     D0, #CH_SPACE
                BNE.S   .tcb_after_ws
                INC     XY0, #1
                BRA     .tcb_skip_ws
.tcb_after_ws:
                ; Parse the id as decimal (KLIB_ATOI).
                CALL24  KLIB_ATOI
                BCS     .tcb_bad

                ; D0 = task id (0..62). Validate.
                CMP     D0, #USER_TCB_COUNT+1   ; allow 0..62 (63 = idle+62 user)
                BHS     .tcb_bad

                ; Compute TCB address: TCB_POOL_BASE + id*128.
                ; id*128 = id<<7. Use SHL (no SHL7 single-instruction; do
                ; SHL4 + SHL twice). Or just additive: D2 = id; D3 = TCB ptr.
                MOVE    D2, D0
                LOADI   D3, #TCB_POOL_BASE
                ; D3 += D2*128. id is small (0..62) so 7-bit shift fine.
                ; Use a tight loop: count down D2, add 128 each step.
                ; Or compute via: shift D2 left 7, add to D3.
                ; SHL/SHR4 etc — let me just use the loop, it's clear.
.tcb_addr_loop:
                CMP     D2, #0
                BEQ.S   .tcb_addr_done
                ADD     D3, #TCB_SIZE
                SUB     D2, #1
                BRA     .tcb_addr_loop
.tcb_addr_done:
                ; D3 = TCB address (low 16 bits, page is $00).
                ; Stash in DUMP_PAGE/DUMP_OFFS slots (free during tcb).
                ; Use DUMP_PAGE just as a 16-bit slot for the TCB ptr.
                STOREP  D3, Y3, [#DUMP_PAGE]    ; reuse: TCB ptr
                ; Also need to check the slot is in use (state != UNUSED).
                LOADI   Y0, #$00
                MOVE    X0, D3
                LOADD   D0, [XY0+#TCB_STATE]
                LOW     D0
                CMP     D0, #TS_UNUSED
                BNE.S   .tcb_in_use
                ; Slot is free.
                MOVE    Y0, Y3
                LOADI   X0, #msg_tcb_unused
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.tcb_in_use:
                ; --- "tcb N:" header ---------------------------------------
                MOVE    Y0, Y3
                LOADI   X0, #msg_tcb_hdr
                TRAP    #TRAP_PUTS
                LOADI   Y0, #$00
                LOADP   D0, Y3, [#DUMP_PAGE]
                MOVE    X0, D0
                LOADD   D0, [XY0+#TCB_ID]
                TRAP    #TRAP_PUTDEC
                MOVE    Y0, Y3
                LOADI   X0, #msg_tcb_colon
                TRAP    #TRAP_PUTS

                ; --- state -------------------------------------------------
                MOVE    Y0, Y3
                LOADI   X0, #msg_tcb_state
                TRAP    #TRAP_PUTS
                LOADI   Y0, #$00
                LOADP   D0, Y3, [#DUMP_PAGE]
                MOVE    X0, D0
                LOADD   D0, [XY0+#TCB_STATE]
                LOW     D0
                ; Letter from state_chars
                MOVE    Y0, Y3
                LOADI   X0, #state_chars
                ADD     X0, D0
                LOADB   D0, [XY0]
                TRAP    #TRAP_PUTCHAR
                LOADI   D0, #CH_LF
                TRAP    #TRAP_PUTCHAR

                ; --- page (saved Y) + page count ---------------------------
                MOVE    Y0, Y3
                LOADI   X0, #msg_tcb_page
                TRAP    #TRAP_PUTS
                LOADI   Y0, #$00
                LOADP   D0, Y3, [#DUMP_PAGE]
                MOVE    X0, D0
                LOADD   D0, [XY0+#TCB_SAVED_Y]
                LOW     D0
                ; Build "$pp" in ROW_BUF and emit.
                MOVE    Y1, Y3
                LOADI   X1, #ROW_BUF
                MOVE    D2, D0
                LOADI   D0, #'$'
                CALL16  _KoshEmitByte
                MOVE    D0, D2
                CALL16  _KoshEmitByteHex
                LOADI   D0, #CH_LF
                CALL16  _KoshEmitByte
                LOADI   D0, #0
                CALL16  _KoshEmitByte
                MOVE    Y0, Y3
                LOADI   X0, #ROW_BUF
                TRAP    #TRAP_PUTS

                ; --- saved x (stack ptr) -----------------------------------
                MOVE    Y0, Y3
                LOADI   X0, #msg_tcb_savedx
                TRAP    #TRAP_PUTS
                LOADI   Y0, #$00
                LOADP   D0, Y3, [#DUMP_PAGE]
                MOVE    X0, D0
                LOADD   D0, [XY0+#TCB_SAVED_X]
                ; Build "$xxxx\n" in ROW_BUF.
                MOVE    Y1, Y3
                LOADI   X1, #ROW_BUF
                MOVE    D2, D0
                LOADI   D0, #'$'
                CALL16  _KoshEmitByte
                MOVE    D0, D2
                CALL16  _KoshEmitWordHex
                LOADI   D0, #CH_LF
                CALL16  _KoshEmitByte
                LOADI   D0, #0
                CALL16  _KoshEmitByte
                MOVE    Y0, Y3
                LOADI   X0, #ROW_BUF
                TRAP    #TRAP_PUTS

                ; --- parent ------------------------------------------------
                MOVE    Y0, Y3
                LOADI   X0, #msg_tcb_parent
                TRAP    #TRAP_PUTS
                LOADI   Y0, #$00
                LOADP   D0, Y3, [#DUMP_PAGE]
                MOVE    X0, D0
                LOADD   D0, [XY0+#TCB_PARENT_ID]
                TRAP    #TRAP_PUTDEC
                LOADI   D0, #CH_LF
                TRAP    #TRAP_PUTCHAR

                ; --- yields ------------------------------------------------
                MOVE    Y0, Y3
                LOADI   X0, #msg_tcb_yields
                TRAP    #TRAP_PUTS
                LOADI   Y0, #$00
                LOADP   D0, Y3, [#DUMP_PAGE]
                MOVE    X0, D0
                LOADD   D0, [XY0+#TCB_YIELD_COUNT]
                TRAP    #TRAP_PUTDEC
                LOADI   D0, #CH_LF
                TRAP    #TRAP_PUTCHAR

                ; --- preempts ----------------------------------------------
                MOVE    Y0, Y3
                LOADI   X0, #msg_tcb_preempts
                TRAP    #TRAP_PUTS
                LOADI   Y0, #$00
                LOADP   D0, Y3, [#DUMP_PAGE]
                MOVE    X0, D0
                LOADD   D0, [XY0+#TCB_PREEMPT_COUNT]
                TRAP    #TRAP_PUTDEC
                LOADI   D0, #CH_LF
                TRAP    #TRAP_PUTCHAR

                ; --- name --------------------------------------------------
                MOVE    Y0, Y3
                LOADI   X0, #msg_tcb_name
                TRAP    #TRAP_PUTS
                ; TCB_NAME is at TCB+$60. Out of IMM5 reach; build a
                ; full 16-bit address and sys_puts the zstring directly.
                LOADP   D0, Y3, [#DUMP_PAGE]
                ADD     D0, #TCB_NAME
                LOADI   Y0, #$00
                MOVE    X0, D0
                TRAP    #TRAP_PUTS
                LOADI   D0, #CH_LF
                TRAP    #TRAP_PUTCHAR

                BRA     .repl_loop

.tcb_bad:
                MOVE    Y0, Y3
                LOADI   X0, #msg_tcb_usage
                TRAP    #TRAP_PUTS
                BRA     .repl_loop


; ============================================================================
; Sys-command strings (page-local, addressed via Y3 + page-offset).
; ============================================================================

; --- ver --------------------------------------------------------------------
; k/OS version + phase are now emitted dynamically by .do_info from the
; page-$00 identity slots (Part 40). msg_ver_full carries only kosh's own
; (static) version. info_kos_lbl is the dynamic line's label; the 1-space
; separator reuses splash_logo2b from kosh_splash.asm.
info_kos_lbl:  .TEXT   "k/OS:     v", 0
msg_ver_full:  .TEXT   "Shell:    kosh v1.0\n",0

; --- ps ---------------------------------------------------------------------
; Header column widths (must match .do_ps emit code):
;   "  TID PTID NAME     ST FG PAGE BLOCKS BYTES   TICKS\n"
;     ^^^  ^^^^ ^^^^^^^^ ^^ ^^ ^^^^^ ^^^^^^^ ^^^^^^^ <var>
;     |    |    |        |  |  |     |       |
;     |    |    |        |  |  |     |       7 chars (digits + pad spaces)
;     |    |    |        |  |  |     7 chars (digits + pad spaces)
;     |    |    |        |  |  "$nn" + 2 sep spaces = 5 chars
;     |    |    |        |  single char + 2 sep spaces = 3 chars
;     |    |    |        single char + 2 sep spaces = 3 chars
;     |    |    8 chars (NUL-padded) + 1 sep = 9 chars
;     |    1-3 digits + pad to 4 + 1 sep = 5 chars
;     1-3 digits + pad to 3 + 1 sep = 4 chars
; Header uses "BLOCKS " / "BYTES  " (each 7 chars) so data columns line up
; with their headers. TICKS sits to the right of BYTES with no extra
; separator since both BYTES data and "BYTES  " header end in pad spaces.
msg_ps_hdr:    .TEXT   "  TID PTID NAME     ST FG PAGE BLOCKS BYTES  TICKS\n",0
msg_ps_indent: .TEXT   "  ",0

; --- kill -------------------------------------------------------------------
msg_kill_usage:    .TEXT  "kill: usage: kill <tid>\n",0
msg_kill_badarg:   .TEXT  "kill: bad TID (need decimal number)\n",0
msg_kill_err_pfx:  .TEXT  "kill:",0

; State letters indexed by TS_xxx (TS_READY=0, TS_BLOCKED=1, TS_DEAD=2,
; TS_UNUSED=3 (skipped, but indexable), TS_WAITING=4, TS_SEMWAIT=5).
state_chars:   .TEXT   "RBDUWS"

; --- info -------------------------------------------------------------------
; Part 30 r2 (14 May 2026): per-string labels collapsed to a single
; ticks-line label. All other info lines now share strings with
; kosh_splash.asm (splash_host_lbl, splash_kernel, splash_heap_*,
; splash_pages_*, splash_tasks_*). Old msg_info_host, msg_host_emu,
; msg_host_digital, msg_info_kernel, msg_info_heap*, msg_info_pages*,
; msg_info_tasks* removed.
msg_info_ticks:       .TEXT  "Ticks:    ",0

; --- tcb --------------------------------------------------------------------
msg_tcb_usage:        .TEXT  "usage: task TID  (decimal 0..62)\n",0
msg_tcb_unused:       .TEXT  "  (slot is unused)\n",0
msg_tcb_hdr:          .TEXT  "  task ID:  ",0
msg_tcb_colon:        .TEXT  "\n",0
msg_tcb_state:        .TEXT  "  state:    ",0
msg_tcb_page:         .TEXT  "  page:     ",0
msg_tcb_savedx:       .TEXT  "  saved x:  ",0
msg_tcb_parent:       .TEXT  "  parent:   ",0
msg_tcb_yields:       .TEXT  "  yields:   ",0
msg_tcb_preempts:     .TEXT  "  preempts: ",0
msg_tcb_name:         .TEXT  "  name:     ",0

; Command name strings (for cmd_table)
cmd_ps_str:     .TEXT   "ps",0
cmd_info_str:   .TEXT   "info",0
cmd_task_str:   .TEXT   "task",0
cmd_kill_str:   .TEXT   "kill",0
