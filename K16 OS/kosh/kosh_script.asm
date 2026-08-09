; ============================================================================
; kosh_script.asm - kosh script runner (.KSH batch execution)  [Part 57+]
; ============================================================================
; A kosh script is a plain text file of kosh command lines, one per line,
; run through the exact same dispatch a typed line gets (Amiga Execute /
; DOS .BAT model). No new command semantics: anything you can type, a
; script can do - including `assign`, which is the whole point (recreate the
; named-drive namespace each boot from a STARTUP.KSH).
;
; Design (strategy A - "line-source indirection"):
;   The REPL loop, instead of always prompting + sys_gets, first asks
;   _KoshScriptNextLine for a line. If a script is active it hands back the
;   next executable line (already echoed) in LINE_BUF; the whole downstream
;   dispatch runs unchanged. A script is simply "the REPL reading its lines
;   from a file instead of the keyboard."
;
;   Reads are byte-at-a-time via sys_read(1). The kernel keeps each fd's
;   position, so every nesting level needs only its fd - no per-level line
;   buffer. Nesting is a small LIFO fd stack (SCRIPT_FDS, SCRIPT_MAX_DEPTH).
;
;   Error policy (v1): continue-and-echo. A failing line prints its error
;   (via the normal dispatch path) and the script carries on. `failat on/off`
;   is a v2 addition (handled centrally here, not per command).
;
; Entry points:
;   _KoshRunScript      - open a .KSH and push it (called from _KoshExecFile
;                         when a name ends ".ksh"). The REPL then drains it.
;   _KoshScriptNextLine - REPL line source (returns next line or C=1).
;   _KoshNameIsKsh      - tail test: does an ASCIIZ name end ".ksh"?
;
; Internal:
;   _KoshScriptCurFd / _KoshScriptReadByte / _KoshScriptPop
;
; State (kosh_defs.inc, KSTATE - zero-filled at kosh_entry, so SCRIPT_DEPTH
; starts 0 = inactive):
;   SCRIPT_DEPTH  nesting depth (0 = no script active)
;   SCRIPT_CHAR   1-byte sys_read landing slot
;   SCRIPT_FDS    fd stack (SCRIPT_MAX_DEPTH words)
;   SCRIPT_FLAGS  per-level presentation flags (Part 61), parallel to FDS
; Value constants: SCRIPT_MAX_DEPTH, SCRIPT_FLAG_BRIEF, and ".ksh" is tested
; char-by-char here.
;
; Brief mode (Part 61) - `NAME.ksh -b`:
;   Normally each line echoes as "<prompt><line>\n" and the command's output
;   follows on the next line. With -b the echo ends " -> " instead of a
;   newline, so the command's own output completes the line:
;       RAM:$ load ramdisk/zork.com -> loaded 36560 bytes
;   A command that prints nothing would leave the cursor mid-line; the
;   column guard in _KoshPrintPrompt (sys_wherexy) breaks the line before the
;   next prompt, so that case degrades to an ordinary blank-result line.
;   The flag is per-level: a script invoked from a -b script is NOT brief
;   unless it too was given -b. DOS `echo off` is the nearest relative, but
;   this is a presentation mode, not an echo switch - the line still echoes.
;
;   In-script directive (Part 61) - `echo -b` / `echo -v`:
;     A script can set its own mode instead of relying on the invoking line.
;     This is the ONLY way for a boot-cascade STARTUP.KSH to be brief, since
;     _KoshCascadeAdvance invokes it with flags = 0 and there is no argument
;     to pass. It also removes the need for a two-line stub that exists only
;     to chain to a second script with -b on it.
;
;     The directive is INTERCEPTED here, next to the ';' comment filter, and
;     swallowed: it is neither echoed nor dispatched, so it leaves no trace in
;     the output. .do_echo is untouched, and at the interactive prompt (no
;     script level to configure) `echo -b` still just prints "-b".
;
;     Flag form, not DOS's bare `echo off`, so only the exact text "-b"/"-v"
;     is shadowed - `echo off` still prints "off", which under DOS it cannot.
;     Matching is case-insensitive and tolerant of runs of whitespace.
;       echo -b   brief   (SCRIPT_FLAG_BRIEF)
;       echo -v   verbose (flags = 0; the default)
;     Applies from the NEXT line on, which is invisible because the directive
;     line never prints.
;
; All calls are CALL16 (kosh.com internal); KLIB_* are CALL24 (jump table).
; ============================================================================

; ----------------------------------------------------------------------------
; _KoshRunScript - open a script file and push it onto the run stack.
;
;   In:   XY0 = path (ASCIIZ, task page) - "X:NAME.KSH" or CWD-relative
;         D1  = start cluster (CWD cluster, 0 = root)   - open start point
;         D2  = start drive index                       - open start point
;         D3  = presentation flags for this level (Part 61; 0 = normal,
;               SCRIPT_FLAG_BRIEF = -b). Callers that don't care pass 0.
;   Out:  C = 0  script opened and pushed; the REPL loop will run it. Nothing
;                is printed here (it hasn't "exited"; it's queued).
;         C = 1  D0 = err code, NOT reported (caller decides). ERR_NOMEM is
;                reused for "nesting too deep" (SCRIPT_MAX_DEPTH reached).
;   Clobbers: D0, D1, D2, X0, Y0.  Preserves: D3, XY1, XY2, XY3.
; ----------------------------------------------------------------------------
_KoshRunScript:
                ; --- depth cap -------------------------------------------
                LOADP   D0, Y3, [#SCRIPT_DEPTH]
                CMP     D0, #SCRIPT_MAX_DEPTH
                BLO     .krs_open
                LOADI   D0, #ERR_NOMEM          ; no room for another level
                SEC
                RET
.krs_open:
                ; sys_open(path=XY0, READ, D1=start clu, D2=start drive).
                ; D1/D2 flow untouched into the TRAP; only D0 (flags) is set.
                LOADI   D0, #FOPEN_READ
                TRAP    #TRAP_OPEN
                BCS     .krs_err                ; D0 = err (syscall ABI: C=1)

                ; push: SCRIPT_FDS[depth] = fd, then depth += 1
                MOVE    D2, D0                  ; D2 = fd (open returned it in D0)
                LOADP   D0, Y3, [#SCRIPT_DEPTH] ; D0 = depth (0-based slot index)
                ADD     D0, D0                  ; *2 (word slot -> byte offset)
                MOVE    Y0, Y3
                LOADI   X0, #SCRIPT_FDS
                ADD     X0, D0
                STORED  D2, [XY0]               ; SCRIPT_FDS[depth] = fd

                ; Part 61: SCRIPT_FLAGS[depth] = D3. Same index arithmetic;
                ; D0 was consumed by the fd store, so recompute it.
                LOADP   D0, Y3, [#SCRIPT_DEPTH]
                ADD     D0, D0                  ; *2 (word slot -> byte offset)
                MOVE    Y0, Y3
                LOADI   X0, #SCRIPT_FLAGS
                ADD     X0, D0
                STORED  D3, [XY0]               ; SCRIPT_FLAGS[depth] = flags

                LOADP   D0, Y3, [#SCRIPT_DEPTH]
                INC     D0, #1
                STOREP  D0, Y3, [#SCRIPT_DEPTH]
                CLC
                RET
.krs_err:
                SEC
                RET


; ----------------------------------------------------------------------------
; _KoshScriptNextLine - REPL line source. Pull the next executable line from
;   the active script into LINE_BUF. Skips blank and ';'-comment lines, strips
;   CR, echoes the line, and pops finished scripts (LIFO) until one yields a
;   line or all are drained.
;
;   In:   (none) - reads SCRIPT_DEPTH / SCRIPT_FDS (task page).
;   Out:  C = 0  a line is in LINE_BUF (nul-terminated), D0 = length, already
;                echoed (prompt + line). Ready for the dispatch ladder.
;         C = 1  no script line available (depth 0 / all drained). LINE_BUF
;                left as-is; caller does prompt + sys_gets.
;   Clobbers: D0, D1, D2, D3, X0, X1, Y0, Y1, XY2 (via _KoshPrintPrompt).
;   Preserves: XY3.
; ----------------------------------------------------------------------------
_KoshScriptNextLine:
.snl_top:
                LOADP   D0, Y3, [#SCRIPT_DEPTH]
                CMP     D0, #0
                BEQ     .snl_none               ; no active script

                ; --- assemble one raw line into LINE_BUF ------------------
                MOVE    Y1, Y3
                LOADI   X1, #LINE_BUF           ; XY1 = write cursor
                LOADI   D3, #0                  ; D3 = char count
.snl_char:
                CALL16  _KoshScriptReadByte     ; C=0: D0=byte; C=1: EOF
                BCS     .snl_eof
                CMP     D0, #$0D                ; CR -> drop (CRLF handling)
                BEQ     .snl_char
                CMP     D0, #CH_LF              ; LF -> end of line
                BEQ     .snl_eol
                CMP     D3, #LINE_BUF_MAX       ; buffer full?
                BHS     .snl_char               ; swallow the rest of the line
                STOREB  D0, [XY1]+
                INC     D3, #1
                BRA     .snl_char

.snl_eof:
                ; EOF on this fd. If chars were accumulated it's a final line
                ; with no trailing newline - process it; else pop and retry.
                CMP     D3, #0
                BNE     .snl_eol
                CALL16  _KoshScriptPop          ; depth--
                LOADP   D0, Y3, [#SCRIPT_DEPTH]
                CMP     D0, #0
                BNE     .snl_top                ; still nested -> resume parent
                CALL16  _KoshCascadeAdvance     ; stack empty: next boot script
                BRA     .snl_top                ;   (no-op if cascade inactive)

.snl_eol:
                LOADI   D0, #0
                STOREB  D0, [XY1]               ; nul-terminate

                ; --- skip blank / ';' comment lines ----------------------
                MOVE    Y0, Y3
                LOADI   X0, #LINE_BUF
.snl_skipws:
                LOADB   D0, [XY0]
                AND     D0, #$FF
                CMP     D0, #CH_SPACE
                BEQ     .snl_skadv
                CMP     D0, #CH_TAB
                BNE     .snl_check
.snl_skadv:
                INC     XY0, #1
                BRA     .snl_skipws
.snl_check:
                CMP     D0, #0                  ; blank line?
                BEQ     .snl_top                ; -> fetch next
                CMP     D0, #';'                ; comment leader?
                BEQ     .snl_top                ; -> fetch next

                ; --- `echo -b` / `echo -v` directive (Part 61) -----------
                ; Scan with XY1 so XY0 keeps pointing at the line start for
                ; the echo below; on any mismatch we simply fall through with
                ; XY0 untouched. D3 (char count) is not disturbed.
                MOVE    Y1, Y0
                MOVE    X1, X0                  ; XY1 = scan cursor
                LOADB   D1, [XY1]
                AND     D1, #$FF
                OR      D1, #$20                ; fold case ('E' -> 'e')
                CMP     D1, #'e'
                BNE     .snl_notdir
                INC     XY1, #1
                LOADB   D1, [XY1]
                AND     D1, #$FF
                OR      D1, #$20
                CMP     D1, #'c'
                BNE     .snl_notdir
                INC     XY1, #1
                LOADB   D1, [XY1]
                AND     D1, #$FF
                OR      D1, #$20
                CMP     D1, #'h'
                BNE     .snl_notdir
                INC     XY1, #1
                LOADB   D1, [XY1]
                AND     D1, #$FF
                OR      D1, #$20
                CMP     D1, #'o'
                BNE     .snl_notdir
                INC     XY1, #1

                ; "echo" must be a whole word - reject "echoes", "echo-b".
                LOADB   D1, [XY1]
                AND     D1, #$FF
                CMP     D1, #CH_SPACE
                BEQ     .snl_dir_ws
                CMP     D1, #CH_TAB
                BNE     .snl_notdir
.snl_dir_ws:
                INC     XY1, #1                 ; skip the whitespace run
                LOADB   D1, [XY1]
                AND     D1, #$FF
                CMP     D1, #CH_SPACE
                BEQ     .snl_dir_ws
                CMP     D1, #CH_TAB
                BEQ     .snl_dir_ws

                CMP     D1, #'-'                ; flag introducer
                BNE     .snl_notdir
                INC     XY1, #1
                LOADB   D1, [XY1]
                AND     D1, #$FF
                OR      D1, #$20
                CMP     D1, #'b'
                BEQ     .snl_dir_brief
                CMP     D1, #'v'
                BNE     .snl_notdir             ; unknown switch -> real echo
                LOADI   D1, #0                  ; -v: default presentation
                BRA     .snl_dir_set
.snl_dir_brief:
                LOADI   D1, #SCRIPT_FLAG_BRIEF
.snl_dir_set:
                ; SCRIPT_FLAGS[depth-1] = D1. Depth is >= 1 on this path.
                LOADP   D0, Y3, [#SCRIPT_DEPTH]
                SUB     D0, #1
                ADD     D0, D0                  ; *2 (word slot -> byte offset)
                MOVE    Y0, Y3
                LOADI   X0, #SCRIPT_FLAGS
                ADD     X0, D0
                STORED  D1, [XY0]
                BRA     .snl_top                ; swallowed: no echo, no dispatch
.snl_notdir:

                ; --- echo (prompt + line) so the session shows it --------
                CALL16  _KoshPrintPrompt        ; keeps D3/XY3; clobbers D0/D1/XY0-2
                MOVE    Y0, Y3
                LOADI   X0, #LINE_BUF
                TRAP    #TRAP_PUTS              ; line (nul-terminated)

                ; Part 61: -b ends the echo with " -> " and no newline, so the
                ; command's own output finishes the line. Its trailing newline
                ; is what terminates it.
                ;
                ; A command that prints NOTHING would leave a dangling arrow
                ; (`ram:` and a script push both print nothing on success), so
                ; record the column the arrow ends at. _KoshPrintPrompt erases
                ; the arrow if the cursor is still there when the next prompt
                ; comes round. Recording the column rather than guessing is
                ; what stops the erase from eating real output that merely
                ; lacked a trailing newline.
                CALL16  _KoshScriptCurFlags     ; D0 = SCRIPT_FLAGS[depth-1]
                AND     D0, #SCRIPT_FLAG_BRIEF  ; sets Z
                BEQ     .snl_echo_nl
                MOVE    Y0, Y3
                LOADI   X0, #msg_brief_arrow
                TRAP    #TRAP_PUTS
                TRAP    #TRAP_WHEREXY           ; D0 = col (leaf; keeps D2/D3)
                STOREP  D0, Y3, [#SCRIPT_ARROW_COL]
                BRA     .snl_echo_done
.snl_echo_nl:
                LOADI   D0, #0                  ; no arrow pending on this line
                STOREP  D0, Y3, [#SCRIPT_ARROW_COL]
                LOADI   D0, #CH_LF
                TRAP    #TRAP_PUTCHAR           ; + newline (putln retired -> putlp)
.snl_echo_done:

                ; --- return length (re-derived; robust to PUTLN clobbers) -
                MOVE    Y0, Y3
                LOADI   X0, #LINE_BUF
                CALL24  KLIB_STRLEN             ; D0 = length (excl nul)
                CLC
                RET

.snl_none:
                SEC
                RET


; ----------------------------------------------------------------------------
; _KoshScriptCurFd - fd of the current (top) script level.
;   Out: D2 = SCRIPT_FDS[SCRIPT_DEPTH-1].  Clobbers: D0, X0, Y0. (Assumes
;        SCRIPT_DEPTH >= 1 - only called on the active path.)
; ----------------------------------------------------------------------------
_KoshScriptCurFd:
                LOADP   D0, Y3, [#SCRIPT_DEPTH]
                SUB     D0, #1
                ADD     D0, D0                  ; *2 (word slot -> byte offset)
                MOVE    Y0, Y3
                LOADI   X0, #SCRIPT_FDS
                ADD     X0, D0
                LOADD   D2, [XY0]               ; D2 = current fd
                RET


; ----------------------------------------------------------------------------
; _KoshScriptCurFlags - presentation flags of the current (top) script level.
;   Out: D0 = SCRIPT_FLAGS[SCRIPT_DEPTH-1].  Clobbers: D0, X0, Y0.
;   (Assumes SCRIPT_DEPTH >= 1 - only called on the active echo path, which
;   has already established a line exists.)
; ----------------------------------------------------------------------------
_KoshScriptCurFlags:
                LOADP   D0, Y3, [#SCRIPT_DEPTH]
                SUB     D0, #1
                ADD     D0, D0                  ; *2 (word slot -> byte offset)
                MOVE    Y0, Y3
                LOADI   X0, #SCRIPT_FLAGS
                ADD     X0, D0
                LOADD   D0, [XY0]               ; D0 = current level's flags
                RET


; ----------------------------------------------------------------------------
; _KoshScriptReadByte - read one byte from the current script fd.
;   Out: C = 0  D0 = byte (0..255)
;        C = 1  EOF or read error (treated the same - end this level)
;   Clobbers: D0, D1, D2, X0, Y0.  Preserves: D3, XY1, XY2, XY3.
; ----------------------------------------------------------------------------
_KoshScriptReadByte:
                CALL16  _KoshScriptCurFd        ; D2 = fd
                MOVE    D0, D2                  ; sys_read: D0 = fd
                LOADI   D1, #1                  ;           D1 = count
                MOVE    Y0, Y3
                LOADI   X0, #SCRIPT_CHAR        ;           XY0 = 1-byte buf
                TRAP    #TRAP_READ
                BCS     .srb_eof                ; read error -> EOF
                CMP     D0, #0
                BEQ     .srb_eof                ; 0 bytes -> EOF
                MOVE    Y0, Y3
                LOADI   X0, #SCRIPT_CHAR
                LOADB   D0, [XY0]
                AND     D0, #$FF
                CLC
                RET
.srb_eof:
                SEC
                RET


; ----------------------------------------------------------------------------
; _KoshScriptPop - close the current script fd and drop one nesting level.
;   Clobbers: D0, D2, X0, Y0.  Preserves: D3, XY1, XY2, XY3.
; ----------------------------------------------------------------------------
_KoshScriptPop:
                CALL16  _KoshScriptCurFd        ; D2 = fd
                MOVE    D0, D2
                TRAP    #TRAP_CLOSE
                LOADP   D0, Y3, [#SCRIPT_DEPTH]
                SUB     D0, #1
                STOREP  D0, Y3, [#SCRIPT_DEPTH]
                RET


; ----------------------------------------------------------------------------
; _KoshNameIsKsh - does an ASCIIZ name end ".ksh" (case-insensitive)?
;   In:  XY0 = name (ASCIIZ, task page).
;   Out: C = 0  ends ".ksh"       C = 1  does not.
;   Clobbers: D0, D1, X0, X1, Y1.  Preserves: D2, D3, XY0(page), XY2, XY3.
;   (Mirrors the ".com" tail test in _KoshExecFile.)
; ----------------------------------------------------------------------------
_KoshNameIsKsh:
                ; scan to the nul, keeping the base offset in X0.
                LEA     XY1, XY0                ; XY1 = scan cursor (Y = Y3)
.nik_scan:
                LOADB   D1, [XY1]
                AND     D1, #$FF
                CMP     D1, #0
                BEQ     .nik_end
                INC     XY1, #1
                BRA     .nik_scan
.nik_end:
                MOVE    D1, X1                  ; D1 = nul offset
                MOVE    D0, X0                  ; D0 = base offset
                SUB     D1, D0                  ; D1 = length
                CMP     D1, #4
                BLO     .nik_no                 ; too short to end ".ksh"
                SUB     D1, #4                  ; D1 = length - 4
                LEA     XY1, XY0                ; XY1 = base
                ADD     X1, D1                  ; XY1 -> last 4 bytes
                LOADB   D1, [XY1]
                CMP     D1, #'.'
                BNE     .nik_no
                INC     XY1, #1
                LOADB   D1, [XY1]
                OR      D1, #$20                ; case-fold
                CMP     D1, #'k'
                BNE     .nik_no
                INC     XY1, #1
                LOADB   D1, [XY1]
                OR      D1, #$20
                CMP     D1, #'s'
                BNE     .nik_no
                INC     XY1, #1
                LOADB   D1, [XY1]
                OR      D1, #$20
                CMP     D1, #'h'
                BNE     .nik_no
                CLC
                RET
.nik_no:
                SEC
                RET


; ----------------------------------------------------------------------------
; _KoshCascadeAdvance - open the next boot-cascade STARTUP.KSH, if any.
;
;   Walks SCRIPT_BOOT_DRV (1=A, 2=B, 3=C; 0 = inactive/finished), skipping any
;   drive whose STARTUP.KSH can't be opened (unmounted or absent - the open
;   simply fails). On the first that opens, pushes it via _KoshRunScript (the
;   REPL then runs it) and leaves SCRIPT_BOOT_DRV pointing at the next drive.
;   When the drives are exhausted (or a push fails on the depth cap),
;   SCRIPT_BOOT_DRV is cleared to 0.
;
;   Part 61: announces each leg that actually runs, as "[A:STARTUP.KSH]".
;   Without it the cascade is invisible - the boot log shows the echoed lines
;   but nothing says which drive produced them, and a leg that is absent or
;   whose drive isn't mounted is skipped in total silence. Only successful
;   pushes are announced: the retry loop walks every drive, so reporting the
;   misses would print [A:] and [B:] on every boot where only C: has a script.
;
;   No-op when SCRIPT_BOOT_DRV is already 0, so the stack-empty path can call
;   it unconditionally: post-boot `run` completions fall straight through.
;
;   In:   (none).   Out: (none - caller re-checks SCRIPT_DEPTH).
;   Clobbers: D0, D1, D2, D3, X0, Y0 (via _KoshRunScript).  Preserves: XY3.
;   (Part 61: D3 joined the clobber list - it now carries _KoshRunScript's
;   flags argument, set to 0 here since a boot STARTUP.KSH takes no switches.
;   Both callers - kosh_entry's arm and .snl_eof - reload D3 before reuse.)
; ----------------------------------------------------------------------------
_KoshCascadeAdvance:
.ca_loop:
                LOADP   D0, Y3, [#SCRIPT_BOOT_DRV]
                CMP     D0, #0
                BEQ     .ca_done                ; inactive / finished
                CMP     D0, #4                  ; past C (3)?
                BHS     .ca_finish
                ; advance the cursor FIRST so a failed open still moves on
                MOVE    D2, D0                  ; D2 = this attempt (1..3)
                INC     D0, #1
                STOREP  D0, Y3, [#SCRIPT_BOOT_DRV]
                SUB     D2, #1                  ; D2 = drive index 0..2 (A/B/C)
                MOVE    Y0, Y3
                LOADI   X0, #startup_ksh_name   ; bare name -> root of drive D2
                LOADI   D1, #0                  ; root cluster
                LOADI   D3, #0                  ; Part 61: normal echo, no -b
                CALL16  _KoshRunScript          ; C=0 pushed / C=1 skip
                BCS     .ca_loop                ; couldn't open -> next drive

                ; --- Announce the leg (Part 61) --------------------------
                ; D2 held the drive index but _KoshRunScript clobbers it, so
                ; recover the letter from the cursor rather than burn a
                ; scratch slot saving it. SCRIPT_BOOT_DRV was advanced to
                ; (this_attempt + 1) BEFORE the call, and this_attempt is
                ; 1..3 for A..C, so this leg's index is SCRIPT_BOOT_DRV - 2.
                LOADI   D0, #'['
                TRAP    #TRAP_PUTCHAR
                LOADP   D0, Y3, [#SCRIPT_BOOT_DRV]
                SUB     D0, #2                  ; -> 0..2 (A/B/C)
                ADD     D0, #'A'                ; -> 'A'..'C'
                TRAP    #TRAP_PUTCHAR
                MOVE    Y0, Y3
                LOADI   X0, #msg_cascade_tail
                TRAP    #TRAP_PUTS
                RET                             ; pushed; REPL runs it
.ca_finish:
                LOADI   D0, #0
                STOREP  D0, Y3, [#SCRIPT_BOOT_DRV]
.ca_done:
                RET


; ----------------------------------------------------------------------------
; Boot-cascade script name, opened at the root of each drive. Lives in the
; kosh.com image (= the Y3 task page), so #startup_ksh_name is a valid
; task-page path pointer for sys_open (same as the msg_* strings).
; ----------------------------------------------------------------------------
startup_ksh_name: .TEXT   "STARTUP.KSH",0

; Part 61: brief-mode echo tail. Trailing spaces are deliberate - the command's
; output butts straight up against it.
msg_brief_arrow:  .TEXT   " -> ",0

; Part 61: boot-cascade leg announcement. Emitted as '[' + letter + this.
msg_cascade_tail: .TEXT   ":STARTUP.KSH]\n",0
