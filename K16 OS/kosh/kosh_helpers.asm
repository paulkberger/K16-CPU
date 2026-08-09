; ============================================================================
; kosh_helpers.asm - kosh CALL24-callable helper subroutines
; ============================================================================
; Date:    29 May 2026
; Status:  Part 64 - glob carries long names and subdirectories.
;
; Revision: r11 - 9 August 2026 - Part 64: a failed sys_wait no longer
;             prints "run: cannot exec". .xf_fail was the shared exit for
;             BOTH exec failure and wait failure, and both callers print
;             msg_run_execerr on C=1 - so a scheduler-side fault pointed
;             the reader at the path and the loader. Near-unreachable (the
;             TID is the one we just spawned, and ERR_DETACHED is already
;             split out) which is exactly why it would have cost a session:
;             a message that cannot be true is worse than no message.
;             New .xf_waitfail reports through msg_run_waiterr - defined
;             since Part 34 and never wired - and returns C=0, which is the
;             documented "ran & reported" contract and also the truth: the
;             child DID start, only the wait failed.
;           r10 - 9 August 2026 - Part 64 step 2: glob understands a
;             directory part.
;             _KoshSplitDrivePat splits on "X:" and nothing else, so a
;             pattern with a directory component ("cp sub/*.com b:") made
;             the WHOLE string the basename pattern and silently matched
;             nothing. New _KoshSplitDirPat splits at the last '/' (else
;             the ':') and hands the prefix to sys_resolve, which already
;             knows about "X:", "NAME:" assigns, a leading '/', '..' and a
;             trailing '/' - so no path syntax is reimplemented here, and
;             "cp *.com gfx:" starts working as a side effect. A prefix
;             that does not resolve, or resolves to a file, is now a HARD
;             ERROR rather than an empty match.
;             New _KoshCopyCounted: the counted sibling of
;             _KoshCopyBounded, same always-terminate contract, used to lay
;             a directory prefix into a KOSH_NORM buffer.
;             _KoshSplitDrivePat is REMOVED - the four glob sites were its
;             only callers. It is not unsafe the way _KoshNormPath was, but
;             it IS a trap: it folds a directory component into the
;             basename pattern and returns a plausible answer, so the
;             failure is a silent no-match. Tombstoned in place rather
;             than deleted outright, since the "X: means cluster 0"
;             convention was documented on it and is cited elsewhere.
;             _KoshFoldChar survives - `ls` calls it directly for the
;             drive-letter fold in its wildcard arm.
;           r9 - 9 August 2026 - Part 64 step 1: glob is no longer 8.3-only.
;             _KoshGlobExpand read the name from GLOB_DIRENT_BUF+$00 and
;             never +$20 where the VFAT long name lives, so cp/mv baked the
;             tilde name into a NEW file at the destination and lowercase
;             was lost - "Mandelbrot.com" arrived as "MANDEL~1.COM", which
;             then WAS the real filename there. Three parts:
;               - _KoshDirentDisplay picks +$20 or +$00 the way ls does;
;               - _KoshDirentMatch matches the display name and falls back
;                 to the 8.3 name, so `cp Mandel*` and `cp MANDEL~1.COM`
;                 both find the file, but the DISPLAY name is what gets
;                 stored, opened and created;
;               - the copy into the table splits by which field was read:
;                 a long name stops at nul only (spaces are legal in one),
;                 an 8.3 name keeps the nul-or-space rule.
;             GLOB_ENTRY_SIZE widened 14 -> 32 to hold LFN_MAX + nul; see
;             kosh_defs.inc for the stack arithmetic behind that number.
;             New _KoshGlobEntryPtr replaces the six-instruction *14 shift
;             chain that four call sites in kosh_cmds_fs.asm open-coded.
;           r8 - 9 August 2026 - Part 62: _KoshGlobExpand now skips any
;             dirent carrying GLOB_SKIP_ATTR (directory or volume
;             label). It matched on NAME alone, so globbing inside a
;             subdirectory collected the "." and ".." entries - "*.*"
;             matches both - and handed them to _KoshCpOne, which
;             opened a directory and reported nonsense
;             ("cp: write error [ERR_UNKNOWN $253A]"). Invisible until
;             Part 44 made glob subdirectory-aware, because a FAT root
;             has no "." / ".." entries. ls already filtered on the
;             attr byte at DIRENT_INFO+$0C; this brings glob into line.
;           r7 - 9 August 2026 - Part 62: KOSH_NORM_A/B raised 16 -> 80
;             bytes (KOSH_NORM_LEN) and the copies into them bounded.
;             New _KoshCopyBounded does a capacity-checked ASCIIZ copy
;             and ALWAYS nul-terminates, including on the overflow
;             return, so a caller that prints the buffer in its error
;             path cannot run away. _KoshResolveDstPath now checks
;             capacity at each of its three write phases (dst copy,
;             separator, basename copy) and returns C=1 with
;             D0 = CP_ERR_TOOLONG - its contract is no longer "C=0
;             always". Policy is hard error, not truncation: a
;             silently shortened path opens or creates the WRONG file.
;           r6 - 9 August 2026 - Part 62: _KoshNormPath REMOVED. Part 44
;             moved cat/rm/run/cp/mv onto raw paths + CWD context in
;             D1/D2, leaving `load` as the sole caller; Part 62 moved
;             .do_load across too, dropping the count to zero. The
;             helper is not merely unused - it is unsafe: prepending
;             "<KOSH_CWD>:" makes the path drive-absolute, and per the
;             _KoshSplitDrivePat convention an explicit "X:" prefix
;             means start cluster 0, so qualifying a path this way
;             silently discards the current directory. Deleted rather
;             than left dead so it cannot be reached for again; see the
;             tombstone below for the replacement pattern.
;           r5 - 29 May 2026 - Part 39: kosh.com migration. 15 CALL24
;             _Kosh* helper calls converted to CALL16, and 2 string
;             references switched from
;                 #SPAWN_ENTRY_OFFSET + (label - kosh_entry)
;             to bare
;                 #label
;             because kosh.asm now assembles with .ORG $0200 and labels
;             resolve directly to their in-page addresses. Additionally,
;             one CALL24 _SlotForDrive was redirected to
;             CALL24 KLIB_SLOT_FOR_DRIVE (KLIB v1.1 slot 07) so the
;             kosh.com image can reach it without depending on a
;             kernel-internal symbol. No behaviour change. Requires
;             kosh.asm r39+, kos_klib.inc r8+.
;
;           r4 - 18 May 2026 - Part 34: fix inverted carry test in
;             _KoshEmitSize's pad/clip block. K16 follows 6502-style
;             carry semantics: SUB sets C=1 when there's NO borrow
;             (result non-negative). The r3 code used BCC to branch
;             into the no-borrow path, which is exactly backwards -
;             the normal case (field_width > content_length) fell
;             into the overflow-clip block, zeroing the pad count and
;             stretching the copy length to the field width. Result:
;             every right-aligned cell wrote the content with stale
;             trailing bytes (often nuls) into ROW_BUF, killing
;             everything downstream once TRAP_PUTS hit the stale nul.
;             One-character fix: BCC.S -> BCS.S.
;
;           r4 - 2 August 2026 - Part 26: _KoshEmitSize now renders two
;             decimals for the KB unit as well as MB/GB. KLIB_BYTES_SPLIT
;             has always computed the KB fraction (see _KBytesSplit's KB
;             arm in kos_klib_impl.asm); only the KLIB Reference's summary
;             table claimed otherwise, and this helper believed it. Note
;             the KB unit's whole part runs to 1023, so the longest KB
;             rendering is "1023.99KB" -- 9 chars. Any caller passing a
;             field width of 8 will clip it.
;           r3 - 18 May 2026 - Part 34: added _KoshEmitSize. Renders a
;             32-bit byte count as a right-aligned size cell ("1.00MB",
;             "45KB", "979KB", "0") inside ROW_BUF. Built atop
;             KLIB_BYTES_SPLIT (slot 46) for the unit selection + frac
;             math; this helper handles the kosh-specific formatting
;             policy (suffix style, decimal-elision at KB, padding).
;             Uses SIZE_FMT_BUF (16 B in kosh task page, declared in
;             kosh.asm r37) as the content work area.
;
;             D2 = field width semantics:
;               > 0  -> right-align content in that width (used by vol)
;               = 0  -> raw (no padding, no clipping; used by ls totals
;                      line where the size flows inline after a label)
;             The two modes share all rendering logic up to the post-
;             content emit step.
;
;           r2 - 11 May 2026 - Part 25 r3: added _KoshErrName (table lookup
;             into err_name_table in kosh.asm) and _KoshPrintErr (emit
;             "<prefix> [ERR_NAME $HHHH]\n"). Net effect: every kosh
;             command now reports errors with both the mnemonic and the
;             hex code, in one line. Unknown codes fall back to
;             ERR_UNKNOWN. See kosh_cmds_fs.asm r12 for call sites.
;
;           r1 - extracted from kosh.asm during r14 split
;
;   .INCLUDEd from kosh.asm after kosh_entry: so the helpers sit inside
;   the kosh.com image alongside the command handlers. With kosh.asm at
;   .ORG $0200 they are CALL16-callable from the same in-page code.
;
;   These are pure-compute helpers: they don't reference any kosh-local
;   data beyond their inputs.
;
;   Helpers in this file:
;     _KoshEmitByte       - append literal byte at XY1 cursor
;     _KoshEmitByteHex    - append 2 hex digits at XY1 cursor
;     _KoshEmitWordHex    - append 4 hex digits at XY1 cursor
;     _KoshParseAddr      - parse "[$]page:[$]offset" or "[$]offset"
;     _KoshErrName        - err code -> name offset (Part 25 r3)
;     _KoshPrintErr       - emit "prefix [ERR_NAME $HHHH]\n" (Part 25 r3)
;     _KoshDirentDisplay  - DIRENT_INFO -> display-name offset (Part 64)
;     _KoshDirentMatch    - pattern vs display name, 8.3 fallback (Part 64)
;     _KoshGlobEntryPtr   - glob table index -> entry offset (Part 64)
;     _KoshCopyCounted    - counted, capacity-checked copy (Part 64)
;     _KoshSplitDirPat    - arg -> resolved dir + basename pattern (Part 64)
;     (_KoshSplitDrivePat - REMOVED Part 64; see the tombstone)
;
;   Note on additional emit helpers:
;     _KoshEmitDec, _KoshEmitStrZ, _KoshEmitNamePadded, _KoshPrintVolLine
;     live in kosh_cmds_fs.asm (where they were introduced for the FS
;     commands). They're CALL24-callable from anywhere just like the
;     helpers here. If they grow into a wider role, move here.
; ============================================================================

; ----------------------------------------------------------------------------
; _KoshEmitByteHex - append 2 hex digits to ROW_BUF cursor.
;
;   In:       D0  byte value (low 8 bits)
;             XY1 = cursor (where to write)
;   Out:      2 ASCII hex digits stored at [XY1]; XY1 += 2
;   Clobbers: D0
;   Preserves: D1, D2, D3, XY0, XY2, XY3
;
;   Buffer-and-blast helper. Caller builds a full row (or line) by
;   chaining _KoshEmitByte / _KoshEmitByteHex / _KoshEmitWordHex calls,
;   then nul-terminates and sys_puts's once. Avoids ~1 TRAP-per-char
;   overhead which was making `dump` slow on Digital.
; ----------------------------------------------------------------------------
_KoshEmitByteHex:
                PUSH    D1, XY3
                MOVE    D1, D0                  ; D1 = byte
                ; High nibble
                SHR4    D0
                AND     D0, #$0F
                CMP     D0, #10
                BLO.S   .ebh_hi_dec
                ADD     D0, #$37                ; 'A' - 10
                BRA.S   .ebh_hi_emit
.ebh_hi_dec:
                ADD     D0, #'0'
.ebh_hi_emit:
                STOREB  D0, [XY1]+
                ; Low nibble
                MOVE    D0, D1
                AND     D0, #$0F
                CMP     D0, #10
                BLO.S   .ebh_lo_dec
                ADD     D0, #$37
                BRA.S   .ebh_lo_emit
.ebh_lo_dec:
                ADD     D0, #'0'
.ebh_lo_emit:
                STOREB  D0, [XY1]+
                POP     D1, XY3
                RET

; ----------------------------------------------------------------------------
; _KoshEmitWordHex - append 4 hex digits (high byte first) at ROW_BUF cursor.
;
;   In:       D0  16-bit value
;             XY1 = cursor
;   Out:      4 ASCII hex digits stored at [XY1]; XY1 += 4
;   Clobbers: D0
;   Preserves: D1, D3, XY0, XY2, XY3
; ----------------------------------------------------------------------------
_KoshEmitWordHex:
                PUSH    D2, XY3
                MOVE    D2, D0                  ; D2 = full word
                SWAPB   D0                      ; high byte now in low position
                CALL16  _KoshEmitByteHex        ; emit high byte, advances XY1
                MOVE    D0, D2                  ; restore full word
                CALL16  _KoshEmitByteHex        ; emit low byte, advances XY1
                POP     D2, XY3
                RET

; ----------------------------------------------------------------------------
; _KoshEmitByte - append one literal byte at ROW_BUF cursor.
;
;   In:       D0  byte (low 8 bits)
;             XY1 = cursor
;   Out:      byte stored at [XY1]; XY1 += 1
;   Clobbers: nothing visibly (just XY1 advance)
;   Preserves: D0..D3, XY0, XY2, XY3
;
;   Single instruction's worth of work, but makes call sites readable.
; ----------------------------------------------------------------------------
_KoshEmitByte:
                STOREB  D0, [XY1]+
                RET

; ----------------------------------------------------------------------------
; _KoshParseAddr - parse "[$]page:[$]offset" or "[$]offset".
;
;   In:   XY0 = pointer to args zstring
;         D3  = default page byte (used if no ':' in address)
;   Out:  D0  = page byte (0..255)
;         D1  = offset (0..65535)
;         XY0 advanced past the parsed address
;         C=0 OK, C=1 parse failed (no digits at all)
;   Clobbers: D2
;   Preserves: D3 (input), XY1, XY2, XY3
;
;   Skips leading whitespace before parsing. KLIB_ATOH accepts an
;   optional leading '$' and is unsigned - fine for page bytes and
;   16-bit offsets up to $FFFF.
; ----------------------------------------------------------------------------
_KoshParseAddr:
                PUSH    XY1, XY3
                ; Skip leading whitespace.
                LEA     XY1, XY0
.pa_skip_ws:
                LOADB   D2, [XY1]
                CMP     D2, #CH_SPACE
                BNE.S   .pa_after_ws
                INC     XY1, #1
                BRA     .pa_skip_ws
.pa_after_ws:
                LEA     XY0, XY1
                CALL24  KLIB_ATOH
                BCS     .pa_fail
                ; D0 = first value, D1 = bytes consumed.
                ; Advance XY1 by D1.
                ADD     X1, D1                  ; only need low half (offsets <64KB)
                ; Check next char: ':' means page:offset, else lone offset.
                LOADB   D2, [XY1]
                CMP     D2, #':'
                BEQ.S   .pa_have_colon

                ; Lone offset form. D0 already holds offset.
                MOVE    D1, D0                  ; D1 = offset
                MOVE    D0, D3                  ; D0 = default page byte
                LOW     D0
                LEA     XY0, XY1                ; advance caller
                CLC
                BRA     .pa_done

.pa_have_colon:
                ; Skip ':' and parse second value.
                INC     XY1, #1
                LEA     XY0, XY1
                PUSH    D0, XY3                 ; save first value (page)
                CALL24  KLIB_ATOH
                BCS     .pa_fail_pop
                ; D0 = second value (offset), D1 = bytes consumed.
                ADD     X1, D1
                MOVE    D1, D0                  ; D1 = offset
                POP     D0, XY3                 ; restore first value (page)
                LOW     D0
                LEA     XY0, XY1
                CLC
                BRA     .pa_done

.pa_fail_pop:
                POP     D2, XY3                 ; discard saved
.pa_fail:
                SEC

.pa_done:
                POP     XY1, XY3
                RET

; ============================================================================
; _KoshErrName - look up an error code's mnemonic name (Part 25 r3)
;
;   Scans err_name_table (in kosh.asm) for an exact match.
;
;   In:    D0 = err code (16-bit)
;   Out:   X0 = page-local offset of the name string (suitable for
;              MOVE Y0, Y3 / use as XY0), or 0 if code not in table.
;          Caller must compare X0 to 0 to detect not-found.
;   Clobbers: D0, D1, X0, Y0
;   Preserves: D2, D3, XY1, XY2, XY3
;
;   Table format: 2 words per entry { code, name_offset }; sentinel
;   code = $0000 (never used as a real error so safe).
; ----------------------------------------------------------------------------
_KoshErrName:
                MOVE    D1, D0                  ; D1 = target code
                MOVE    Y0, Y3
                LOADI   X0, #err_name_table

.en_loop:
                LOADD   D0, [XY0]               ; D0 = entry's code
                CMP     D0, #0
                BEQ.S   .en_notfound
                CMP     D0, D1
                BEQ.S   .en_found
                INC     XY0, #4                 ; next entry (2 words)
                BRA     .en_loop

.en_found:
                LOADD   D0, [XY0+#2]            ; D0 = name offset
                MOVE    X0, D0                  ; return in X0
                RET

.en_notfound:
                LOADI   X0, #0
                RET


; ============================================================================
; _KoshPrintErr - emit "<prefix> [ERR_NAME $HHHH]\n" (Part 25 r3)
;
;   Standard error-line printer. Caller provides a Y3-relative prefix
;   string (e.g. "cp: cannot create destination") and the err code; we
;   look up the mnemonic, format the line into ROW_BUF, and PUTS.
;
;   In:    D0      = err code
;          Y0:X0   = prefix zstring (Y0 typically = Y3)
;   Out:   "prefix [ERR_NAME $HHHH]\n" emitted via TRAP_PUTS
;   Clobbers: D0, D1, X0, X1, Y0, Y1
;   Preserves: D2, D3, XY2, XY3
;
;   Unknown err codes fall back to "ERR_UNKNOWN" (still printed with the
;   numeric code so debugging isn't lost).
; ----------------------------------------------------------------------------
_KoshPrintErr:
                PUSH    D2, XY3                 ; D2 = err code stash
                PUSH    D3, XY3                 ; D3 = name offset stash
                MOVE    D2, D0                  ; D2 = err code

                ; Print the prefix string (XY0 already set by caller).
                TRAP    #TRAP_PUTS

                ; Look up the err name.
                MOVE    D0, D2
                CALL16  _KoshErrName
                MOVE    D3, X0                  ; D3 = name offset (0 = not found)

                ; Build " [ERR_NAME $HHHH]\n\0" in ROW_BUF.
                MOVE    Y1, Y3
                LOADI   X1, #ROW_BUF

                LOADI   D0, #CH_SPACE
                CALL16  _KoshEmitByte
                LOADI   D0, #'['
                CALL16  _KoshEmitByte

                CMP     D3, #0
                BEQ.S   .pe_unknown
                MOVE    Y0, Y3
                MOVE    X0, D3
                CALL16  _KoshEmitStrZ
                BRA.S   .pe_name_done
.pe_unknown:
                MOVE    Y0, Y3
                LOADI   X0, #err_name_unk
                CALL16  _KoshEmitStrZ
.pe_name_done:

                LOADI   D0, #CH_SPACE
                CALL16  _KoshEmitByte
                LOADI   D0, #'$'
                CALL16  _KoshEmitByte
                MOVE    D0, D2
                CALL16  _KoshEmitWordHex
                LOADI   D0, #']'
                CALL16  _KoshEmitByte
                LOADI   D0, #CH_LF
                CALL16  _KoshEmitByte
                LOADI   D0, #0
                CALL16  _KoshEmitByte

                ; Emit the line.
                MOVE    Y0, Y3
                LOADI   X0, #ROW_BUF
                TRAP    #TRAP_PUTS

                POP     D3, XY3
                POP     D2, XY3
                RET


; ============================================================================
; _KoshPrintPrompt - emit "<CWD>:$ " after refreshing CWD validity (Part 25 r4)
;
;   Stale-CWD check: if KOSH_CWD's drive isn't mounted (e.g. user
;   unmounted it), silently snap CWD back to 'B'.
;
;   Output format: "X:$ " where X is the current drive letter.
;
;   In:    (none)
;   Out:   prompt emitted via TRAP_PUTS
;   Clobbers: D0, D1, X0, X1, Y0, Y1, XY2
;   Preserves: D2, D3, XY3
;
;   XY2 is documented as clobbered because _SlotForDrive (used in the
;   stale check) returns the slot pointer there. We don't actually need
;   it, but the K16 V2 ABI doesn't have an "ignore output reg" convention.
; ----------------------------------------------------------------------------
_KoshPrintPrompt:
                ; --- Column guard (Part 61) --------------------------------
                ; Never start a prompt mid-line. sys_wherexy (TRAP #23, leaf -
                ; preserves D2/D3/XY1-3) returns the back-buffer cursor column;
                ; a non-zero column means the previous line never ended, so
                ; break it first.
                ;
                ; Introduced for brief (-b) scripts, where the echo ends
                ; " -> " and relies on the command's own newline to close the
                ; line - a command that prints nothing would otherwise run the
                ; next prompt onto the same line. It fixes the general case
                ; too: any .COM that exits without a trailing newline.
                TRAP    #TRAP_WHEREXY           ; D0 = col, D1 = row
                CMP     D0, #0
                BEQ     .kpp_col0

                ; Mid-line. If the cursor is exactly where a brief-mode " -> "
                ; left it, the command printed nothing at all - erase the arrow
                ; so the line reads as an ordinary echo rather than trailing an
                ; orphaned marker. Any other column means real output that just
                ; lacked a newline: break the line, touch nothing.
                LOADP   D1, Y3, [#SCRIPT_ARROW_COL]
                CMP     D0, D1
                BNE     .kpp_break

                ; BS / space / BS per character - the same erase idiom the
                ; console driver uses for line editing, honoured by the VT100,
                ; the back-buffer grid and Digital's dumb TTY alike.
                PUSH    D2, XY3                 ; this routine preserves D2
                LOADI   D2, #SCRIPT_ARROW_LEN
.kpp_retract:
                LOADI   D0, #CH_BS
                TRAP    #TRAP_PUTCHAR
                LOADI   D0, #CH_SPACE
                TRAP    #TRAP_PUTCHAR
                LOADI   D0, #CH_BS
                TRAP    #TRAP_PUTCHAR
                SUB     D2, #1
                BNE     .kpp_retract
                POP     D2, XY3

.kpp_break:
                LOADI   D0, #0                  ; consume the pending arrow
                STOREP  D0, Y3, [#SCRIPT_ARROW_COL]
                LOADI   D0, #CH_LF
                TRAP    #TRAP_PUTCHAR
.kpp_col0:

                ; --- Stale-CWD check ---------------------------------------
                ; KOSH_CWD is a single byte in the kosh task page.
                MOVE    Y0, Y3
                LOADI   X0, #KOSH_CWD
                LOADB   D0, [XY0]               ; D0 = CWD letter ('A'..'F')

                ; Convert letter to drive index: D0 -= 'A'.
                ; (Bounds-check: if D0 < 'A' or > 'F', something corrupt
                ; the byte; snap to 'B'. Catches uninitialised state too.)
                CMP     D0, #'A'
                BLO     .kpp_snap_b
                CMP     D0, #$47                ; 'F'+1
                BHS     .kpp_snap_b

                SUB     D0, #'A'
                CALL24  KLIB_SLOT_FOR_DRIVE
                BCC.S   .kpp_cwd_ok             ; mounted - proceed

.kpp_snap_b:
                ; Stale or invalid - reset to 'B'.
                LOADI   D0, #'B'
                MOVE    Y0, Y3
                LOADI   X0, #KOSH_CWD
                STOREB  D0, [XY0]
                ; Fall through.

.kpp_cwd_ok:
                ; --- Build "<full path>$ \0" in ROW_BUF --------------------
                ; sys_pwd reconstructs "X:/a/b/c" from (CWD drive, cluster)
                ; into ROW_BUF; we then append "$ ". If sys_pwd fails for any
                ; reason, fall back to the bare "<CWD>:$ " form so the shell
                ; always has a usable prompt.
                MOVE    Y0, Y3
                LOADI   X0, #KOSH_CWD
                LOADB   D0, [XY0]               ; D0 = CWD letter
                SUB     D0, #'A'                ; -> drive index
                MOVE    Y1, Y3
                LOADI   X1, #KOSH_CWD_CLU
                LOADD   D1, [XY1]               ; D1 = CWD cluster
                MOVE    Y0, Y3
                LOADI   X0, #ROW_BUF            ; XY0 = dest
                TRAP    #TRAP_PWD
                BCS     .kpp_fallback

                ; ROW_BUF = "X:/..."\0. Find the nul, append "$ \0".
                MOVE    Y0, Y3
                LOADI   X0, #ROW_BUF
                CALL24  KLIB_STRLEN             ; XY0 -> nul
                LOADI   D0, #'$'
                STOREB  D0, [XY0]+
                LOADI   D0, #CH_SPACE
                STOREB  D0, [XY0]+
                LOADI   D0, #0
                STOREB  D0, [XY0]
                ; Named-volume prompt: substitute the drive letter with the
                ; drive's named volume (RootClu-0 assign), if any.
                MOVE    Y0, Y3
                LOADI   X0, #ROW_BUF
                CALL16  _KoshEmitPwdNamed
                RET

.kpp_fallback:
                ; Bare "<CWD>:$ \0" — original behaviour.
                MOVE    Y0, Y3
                LOADI   X0, #KOSH_CWD
                LOADB   D0, [XY0]               ; D0 = CWD letter

                MOVE    Y1, Y3
                LOADI   X1, #ROW_BUF

                STOREB  D0, [XY1]+               ; CWD letter
                LOADI   D0, #':'
                STOREB  D0, [XY1]+
                LOADI   D0, #'$'
                STOREB  D0, [XY1]+
                LOADI   D0, #CH_SPACE
                STOREB  D0, [XY1]+
                LOADI   D0, #0
                STOREB  D0, [XY1]

.kpp_emit:
                ; --- Emit ---------------------------------------------------
                MOVE    Y0, Y3
                LOADI   X0, #ROW_BUF
                TRAP    #TRAP_PUTS
                RET


; ----------------------------------------------------------------------------
; _KoshEmitPwdNamed - emit a "X:/...\0" pwd string in Amiga display style:
;   no slash after the colon, and the drive letter replaced by the drive's
;   named volume (a RootClu-0 assign) when one exists.
;
;     "X:/"          -> "X:"        / "RAM:"
;     "X:/system"    -> "X:system"  / "RAM:system"
;     "X:/a/b"       -> "X:a/b"     / "RAM:a/b"
;
;   The drive is taken from the buffer's FIRST byte (not KOSH_CWD), so
;   `ls A:` is handled correctly while the CWD is elsewhere. Shared by the
;   prompt, the `pwd` command, and the `ls` header. The buffer is edited in
;   place (throwaway staging).
;
;   In:    XY0 = "X:/...\0" (task page; drive letter at [0])
;   Clobbers: D0, D1, D2, D3, X0, X1, Y0, Y1, flags
; ----------------------------------------------------------------------------
_KoshEmitPwdNamed:
                ; --- Full-depth assign match (path-mounts) ------------------
                ; If the CWD path lies at or below a path-mount assign's backing
                ; dir, render "NAME:remainder" (mount-relative). Longest backing
                ; prefix wins. Display-only - cd/.. still walk the real tree.
                ; RootClu-0 volumes (ROM:/RAM:) are skipped here and handled by
                ; the volume/letter fallback below.
                MOVE    D0, X0
                STOREP  D0, Y3, [#PWDNM_BUF]    ; save CWD buffer offset
                LOADI   D0, #$FFFF
                STOREP  D0, Y3, [#PWDNM_BIDX]   ; best = none
                LOADI   D0, #0
                STOREP  D0, Y3, [#PWDNM_BLEN]
                STOREP  D0, Y3, [#PWDNM_IDX]
.kepn_am:
                LOADP   D3, Y3, [#PWDNM_IDX]
                CMP     D3, #AS_MAX
                BHS     .kepn_amdone
                MOVE    D0, D3                  ; entry base = TABLE + idx*16
                SHL4    D0
                ADD     D0, #AS_TABLE_BASE
                MOVE    X1, D0
                LOADI   Y1, #$00
                LOADB   D0, [XY1]               ; AS_NAME[0]
                AND     D0, #$FF
                BEQ     .kepn_amnext            ; empty entry
                LOADD   D0, [XY1+#AS_ROOTCLU]
                CMP     D0, #0
                BEQ     .kepn_amnext            ; RootClu-0 volume -> fallback
                ; sys_pwd(AS_DRIVE, AS_ROOTCLU) -> CAT_BUF (backing path)
                LOADB   D0, [XY1+#AS_DRIVE]
                AND     D0, #$FF
                LOADD   D1, [XY1+#AS_ROOTCLU]
                MOVE    Y0, Y3
                LOADI   X0, #CAT_BUF
                TRAP    #TRAP_PWD               ; CAT_BUF = "Y:/backing"
                BCS     .kepn_amnext
                ; compare backing (CAT_BUF) as a prefix of the CWD buffer
                LOADI   X0, #CAT_BUF
                MOVE    Y0, Y3
                LOADP   D0, Y3, [#PWDNM_BUF]
                MOVE    X2, D0
                MOVE    Y2, Y3
                LOADI   D2, #0                  ; matched length
.kepn_amcmp:
                LOADB   D0, [XY0]               ; backing char
                AND     D0, #$FF
                BEQ     .kepn_ambound           ; backing exhausted -> prefix
                LOADB   D1, [XY2]               ; CWD char
                AND     D1, #$FF
                CMP     D0, D1
                BNE     .kepn_amnext            ; mismatch -> not a prefix
                INC     XY0, #1
                INC     XY2, #1
                ADD     D2, #1
                BRA     .kepn_amcmp
.kepn_ambound:
                ; CWD[matched] must be '/' or a terminator (< '.') for a
                ; component boundary (reject "system" vs backing "sys").
                LOADB   D1, [XY2]
                AND     D1, #$FF
                CMP     D1, #'/'
                BEQ     .kepn_ambetter
                CMP     D1, #'.'
                BHS     .kepn_amnext            ; filename char -> no boundary
.kepn_ambetter:
                LOADP   D0, Y3, [#PWDNM_BLEN]
                CMP     D0, D2
                BHS     .kepn_amnext            ; best >= matched -> keep best
                STOREP  D2, Y3, [#PWDNM_BLEN]
                LOADP   D3, Y3, [#PWDNM_IDX]
                STOREP  D3, Y3, [#PWDNM_BIDX]
.kepn_amnext:
                LOADP   D3, Y3, [#PWDNM_IDX]
                ADD     D3, #1
                STOREP  D3, Y3, [#PWDNM_IDX]
                BRA     .kepn_am
.kepn_amdone:
                LOADP   D0, Y3, [#PWDNM_BIDX]
                CMP     D0, #$FFFF
                BEQ     .kepn_novol             ; no path-mount match -> fallback
                ; --- emit "NAME:remainder" --------------------------------
                SHL4    D0                      ; best entry base
                ADD     D0, #AS_TABLE_BASE
                MOVE    X0, D0
                LOADI   Y0, #$00
                TRAP    #TRAP_PUTS              ; "NAME" (AS_NAME, page $00)
                MOVE    Y0, Y3
                LOADI   X0, #msg_colon
                TRAP    #TRAP_PUTS              ; ":"
                LOADP   D0, Y3, [#PWDNM_BUF]
                LOADP   D1, Y3, [#PWDNM_BLEN]
                ADD     D0, D1                  ; remainder = buffer + matched
                MOVE    X0, D0
                MOVE    Y0, Y3
                LOADB   D1, [XY0]
                AND     D1, #$FF
                CMP     D1, #'/'
                BNE     .kepn_amrem
                INC     XY0, #1                 ; drop the leading '/'
.kepn_amrem:
                TRAP    #TRAP_PUTS
                RET

.kepn_novol:
                ; volume/letter fallback. The kernel now emits Amiga form
                ; ("X:tail", no slash after the colon), so no fix-up is needed.
                LOADP   D0, Y3, [#PWDNM_BUF]
                MOVE    X0, D0
                MOVE    Y0, Y3

                ; --- drive index from buffer[0] ----------------------------
                LOADB   D0, [XY0]
                AND     D0, #$FF
                SUB     D0, #'A'
                MOVE    D3, D0                  ; D3 = target drive
                PUSH    XY0, XY3                ; save base across scan + puts

                ; --- find RootClu-0 assign for this drive ------------------
                LOADI   D2, #AS_MAX
                LOADI   X1, #AS_TABLE_BASE
                LOADI   Y1, #$00                ; assign table = kernel page $00
.kepn_find:
                LOADB   D0, [XY1]               ; AS_NAME[0]
                AND     D0, #$FF
                BEQ     .kepn_next              ; empty entry
                LOADD   D1, [XY1+#AS_ROOTCLU]
                CMP     D1, #0
                BNE     .kepn_next              ; path-mount -> skip
                LOADB   D1, [XY1+#AS_DRIVE]
                AND     D1, #$FF
                CMP     D1, D3
                BEQ     .kepn_named
.kepn_next:
                ADD     X1, #AS_ENTRY_SIZE
                SUB     D2, #1
                BNE     .kepn_find
                ; bare: emit "X:tail" as-is
                POP     XY0, XY3
                TRAP    #TRAP_PUTS
                RET
.kepn_named:
                ; X1 (Y1=$00) -> AS_NAME. Emit the name from kernel page $00,
                ; then buffer+1 (":tail") -> "NAME:tail".
                LOADI   D0, #$00
                MOVE    Y0, D0
                MOVE    D0, X1
                MOVE    X0, D0
                TRAP    #TRAP_PUTS              ; "NAME"
                POP     XY0, XY3
                INC     XY0, #1                 ; buffer+1 = ":tail"
                TRAP    #TRAP_PUTS
                RET

msg_colon:      .TEXT   ":",0
msg_nl:         .TEXT   "\n",0

; ----------------------------------------------------------------------------
; _KoshBlankLine - emit one newline. Block commands (vol/ls/cat/pwd/assign/
;   disks/info/ps/task/peek/dump/format) call this at the end of their output
;   so a blank line separates the block from the next prompt. Single-line and
;   no-output commands (cd, bare Enter) don't call it, so they get no gap.
;   Clobbers: D0, X0, Y0 (and whatever TRAP_PUTS touches)
; ----------------------------------------------------------------------------
_KoshBlankLine:
                MOVE    Y0, Y3
                LOADI   X0, #msg_nl
                TRAP    #TRAP_PUTS
                RET


; ============================================================================
; _KoshNormPath - REMOVED, Part 62 (9 August 2026).
;
;   Copied a path to a caller buffer, prepending "<KOSH_CWD>:" when it
;   had no "X:" prefix. Do NOT reintroduce it.
;
;   Qualifying a path that way is exactly what breaks CWD-relative
;   resolution: per the convention documented on _KoshSplitDrivePat, an
;   explicit "X:" prefix tells the resolver to start at cluster 0, so
;   the prepend forces every open into the drive root. That was the
;   Part 62 `load` bug - `cd gfx` then `load ramdisk/CUBE6.com` wrote
;   B:/CUBE6.com.
;
;   Replacement pattern: pass the RAW path and supply CWD context in
;   the syscall registers (D1 = start cluster, D2 = start drive index):
;
;       MOVE    Y1, Y3
;       LOADI   X1, #KOSH_CWD
;       LOADB   D2, [XY1]
;       SUB     D2, #'A'                ; -> drive index 0..5
;       LOADI   X1, #KOSH_CWD_CLU
;       LOADD   D1, [XY1]               ; CWD cluster (0 = root)
;
;   Worked examples: .do_cat (literal arm) and .do_load in
;   kosh_cmds_fs.asm; _KoshSplitDrivePat below for the glob equivalent.
;   For display-side qualification use _KoshEmitPwdNamed, which also
;   handles named volumes.
;
;   Secondary reason for removal: its doc contract assumed an 8.3
;   world ("dest buffer >= 16 bytes, max FAT path X:NNNNNNNN.EEE"),
;   which `load` already violated - "B:Mandelbrot.com" is 17 bytes.
; ============================================================================


; ============================================================================
; _KoshCopyBounded - capacity-checked ASCIIZ copy (Part 62)
;
;   Copies a nul-terminated string, refusing rather than overrunning when
;   it will not fit. Replaces the open-ended
;       LOADB D0,[XY0]+ / STOREB D0,[XY1]+ / CMP D0,#0 / BEQ / BRA
;   idiom that every KOSH_NORM writer used to open-code.
;
;   In:    XY0 = source (ASCIIZ, task page)
;          XY1 = destination cursor (task page)
;          D1  = capacity in BYTES REMAINING at XY1, INCLUDING the nul.
;                Pass KOSH_NORM_LEN for a whole buffer, or
;                KOSH_NORM_LEN - n when n bytes are already written.
;   Out:   C = 0  copied; XY1 points AT the nul (not past it), so a
;                 caller can keep appending from there.
;          C = 1  would not fit; D0 = CP_ERR_TOOLONG.
;                 The destination is STILL nul-terminated (truncated),
;                 so an error path may safely TRAP_PUTS it.
;   Clobbers: D0, D1, X0, X1, Y0, Y1
;   Preserves: D2, D3, XY2, XY3
;
;   The loop reserves one byte for the terminator: it needs D1 >= 2 to
;   store a character, since that character must still leave room for a
;   nul. D1 = 1 copies the empty string; D1 = 0 fails.
;
;   Carry note: CMP on the K16 sets C=0 on borrow, so BLO after
;   CMP D1,#2 is "D1 < 2" - i.e. no room for a char plus its nul.
; ----------------------------------------------------------------------------
_KoshCopyBounded:
.kcb_loop:
                CMP     D1, #2
                BLO     .kcb_over               ; < 2 left: no room for char+nul
                LOADB   D0, [XY0]+              ; STREAM: flag-transparent
                CMP     D0, #0
                BEQ.S   .kcb_ok                 ; source exhausted
                STOREB  D0, [XY1]+
                SUB     D1, #1
                BRA     .kcb_loop

.kcb_ok:
                LOADI   D0, #0
                STOREB  D0, [XY1]               ; terminate; XY1 left AT the nul
                CLC
                RET

.kcb_over:
                ; Always terminate before returning - callers print the
                ; buffer in their error arms.
                LOADI   D0, #0
                STOREB  D0, [XY1]
                LOADI   D0, #CP_ERR_TOOLONG
                SEC
                RET
; ============================================================================


; ============================================================================
; _KoshCopyCounted - counted, capacity-checked copy (Part 64)
;
;   The counted sibling of _KoshCopyBounded. Copies exactly D0 bytes -
;   the source need NOT be nul-terminated at that point - and terminates
;   the destination itself. Used to lay a directory prefix (which ends at a
;   '/' or ':' in the middle of the user's argument) into a KOSH_NORM
;   buffer, after which _KoshCopyBounded appends each name.
;
;   In:    XY0 = source (task page; not required to be ASCIIZ)
;          XY1 = destination cursor (task page)
;          D0  = number of bytes to copy
;          D1  = capacity in BYTES REMAINING at XY1, INCLUDING the nul
;   Out:   C = 0  copied; XY1 points AT the nul, D1 = capacity still left
;                 (including that nul), so the pair can be handed straight
;                 to _KoshCopyBounded to append.
;          C = 1  would not fit; D0 = CP_ERR_TOOLONG. The destination is
;                 STILL nul-terminated, as in _KoshCopyBounded, so an error
;                 arm may safely TRAP_PUTS it.
;   Clobbers: D0, D1, X0, X1, Y0, Y1
;   Preserves: D2, D3, XY2, XY3
;
;   D2 is the byte counter internally and is saved across the call. CLC/SEC
;   are issued AFTER the POP on both exits: RM 15.3 lists POP Dn as
;   flag-transparent but POP SR as a flag write, and no routine here rests
;   on that distinction.
; ============================================================================
_KoshCopyCounted:
                PUSH    D2, XY3
                MOVE    D2, D0                  ; D2 = bytes left to copy
.kcc_loop:
                CMP     D2, #0
                BEQ.S   .kcc_ok
                CMP     D1, #2                  ; room for a byte + its nul?
                BLO     .kcc_over
                LOADB   D0, [XY0]+              ; STREAM: flag-transparent
                STOREB  D0, [XY1]+
                SUB     D2, #1
                SUB     D1, #1
                BRA     .kcc_loop

.kcc_ok:
                LOADI   D0, #0
                STOREB  D0, [XY1]               ; terminate; XY1 left AT the nul
                POP     D2, XY3
                CLC
                RET

.kcc_over:
                LOADI   D0, #0
                STOREB  D0, [XY1]
                POP     D2, XY3
                LOADI   D0, #CP_ERR_TOOLONG
                SEC
                RET
; ============================================================================


; ============================================================================
; _KoshEmitSize - render a 32-bit byte count as a human-readable size,
;                 right-aligned in a fixed-width field (Part 34).
;
;   In:       D1:D0   = byte count (32-bit unsigned)
;             XY1     = ROW_BUF cursor
;             D2      = field width in characters, OR 0 for raw (no padding,
;                       no clipping; just emits the content verbatim).
;                       Right-aligned when > 0. Width must hold longest
;                       expected rendering: 9 covers "1024.99GB",
;                       8 covers "999.99KB" (Part 26: KB gained decimals,
;                       so 7 is no longer enough for the KB unit).
;   Out:      D2 > 0: exactly D2 bytes written at [XY1], right-aligned;
;                     XY1 advanced by D2.
;             D2 = 0: content_length bytes written; XY1 advanced by that.
;   Clobbers: D0, D1, D2, D3   ← NOTE: D3 IS clobbered (KLIB callees do)
;   Preserves: XY0, XY2, XY3
;
;   ⚠ Callers that need to stash a value across this call MUST NOT use D3.
;     Use a page-$00 scratch slot, or PUSH/POP across the call.
;
;   Rendering rules (match Part 34 vol output):
;     unit 0 (B):  "<whole>"         e.g. "0", "1023"
;     unit 1 (KB): "<whole>.<NN>KB"  e.g. "45.00KB", "89.50KB"   (Part 26)
;     unit 2 (MB): "<whole>.<NN>MB"  e.g. "1.00MB", "43.94MB"
;     unit 3 (GB): "<whole>.<NN>GB"  e.g. "1.00GB"
;
;   Implementation:
;     1. Call KLIB_BYTES_SPLIT -> D0=whole, D1=hundredths, D2=unit.
;     2. Build the content into SIZE_FMT_BUF (kosh task-page scratch).
;        Track length as we go.
;     3. Emit (field_width - content_length) leading spaces into ROW_BUF.
;     4. Copy SIZE_FMT_BUF content into ROW_BUF.
;
;   If content is longer than the field (shouldn't happen with sensible
;   widths, but defensively), we emit exactly field_width characters by
;   truncating from the right - caller's responsibility to pick a wide
;   enough field.
; ----------------------------------------------------------------------------
_KoshEmitSize:
                PUSH    D2, XY3                 ; save field width

                ; ---- 1. Split ---------------------------------------------
                CALL24  KLIB_BYTES_SPLIT
                ; D0=whole, D1=hundredths, D2=unit

                ; ---- 2. Build content in SIZE_FMT_BUF ---------------------
                ; XY0 = cursor into SIZE_FMT_BUF (kosh page; Y0=Y3).
                PUSH    XY0, XY3                ; save caller's XY0
                MOVE    Y0, Y3
                LOADI   X0, #SIZE_FMT_BUF

                ; --- Emit whole (decimal) ---
                ; KLIB_UTOA takes uint16 in D0; we have whole in D0.
                ; (Whole is <= 1023 normally; only the GB unit's whole can
                ; exceed that, and even then well under $FFFF for our sizes.)
                ;
                ; Save D1 (hundredths) and D2 (unit) across the UTOA call -
                ; UTOA clobbers D1..D3 per its V2 contract.
                PUSH    D1, XY3                 ; save hundredths
                PUSH    D2, XY3                 ; save unit
                CALL24  KLIB_UTOA               ; XY0 advanced; nul at [XY0]
                                                ; (we'll overwrite that nul)
                POP     D2, XY3
                POP     D1, XY3

                ; --- If unit == 0 (B), done with content (no suffix) ---
                CMP     D2, #0
                BEQ     .kes_content_done

                ; --- If unit >= 1 (KB/MB/GB), emit ".NN" before the suffix ---
                ; Part 26: KB used to be excluded here on the belief that
                ; KLIB_BYTES_SPLIT returns frac=0 for it. It does not -- the
                ; KB arm of _KBytesSplit computes frac = (byte_rem * 100)/1024
                ; exactly like the MB/GB arms, and its own examples give
                ; _KBytesSplit(45000) -> (43, 94, 1). The KLIB Reference v1.7
                ; §7.7 sentence "frac always 0 in our use" is stale; validate
                ; against kos_klib_impl.asm, not that table.
                ;
                ; Unit 0 (B) never reaches here -- handled above.
                CMP     D2, #1
                BLO     .kes_skip_decimals

                ; Emit '.' then two decimal digits.
                LOADI   D0, #'.'
                STOREB  D0, [XY0]+

                ; Two digits of hundredths: tens = D1 / 10, ones = D1 mod 10.
                ; Use KLIB_DIV10 (D0 in -> D0 quot, D1 rem). Save D1 (hundredths)
                ; and D2 (unit) across the call.
                PUSH    D2, XY3
                MOVE    D0, D1
                CALL24  KLIB_DIV10              ; D0=tens, D1=ones; clobbers D2,D3
                ; Tens digit.
                ADD     D0, #'0'
                STOREB  D0, [XY0]+
                ; Ones digit.
                ADD     D1, #'0'
                STOREB  D1, [XY0]+
                POP     D2, XY3

.kes_skip_decimals:
                ; --- Emit suffix: "KB", "MB", or "GB" ---
                ; D2 ∈ {1, 2, 3}. First char by table: K, M, G.
                ; (We already handled unit==0 above.)
                CMP     D2, #1
                BEQ.S   .kes_suffix_K
                CMP     D2, #2
                BEQ.S   .kes_suffix_M
                ; GB
                LOADI   D0, #'G'
                BRA.S   .kes_suffix_emit
.kes_suffix_K:
                LOADI   D0, #'K'
                BRA.S   .kes_suffix_emit
.kes_suffix_M:
                LOADI   D0, #'M'
.kes_suffix_emit:
                STOREB  D0, [XY0]+
                LOADI   D0, #'B'
                STOREB  D0, [XY0]+

.kes_content_done:
                ; XY0 now points just past the last content byte.
                ; Compute content length: XY0 - SIZE_FMT_BUF (low word).
                MOVE    D0, X0
                SUB     D0, #SIZE_FMT_BUF
                ; D0 = content length (in low byte; max ~10).

                ; Restore caller's XY0.
                POP     XY0, XY3

                ; ---- 3. Emit padding spaces -------------------------------
                POP     D2, XY3                 ; recover field width
                ; Width=0 means "raw" - no padding, no clipping. Used by
                ; ls (sizes flow inline after the filename, no column).
                CMP     D2, #0
                BEQ.S   .kes_no_pad

                ; D3 = pad_count = max(0, field_width - content_length).
                MOVE    D3, D2
                SUB     D3, D0
                ; K16 carry convention (6502-style):
                ;   C=1 means NO borrow (result non-negative) - normal case.
                ;   C=0 means borrow occurred (content > field, underflow).
                ; Branch over the clip block on the no-borrow path.
                BCS.S   .kes_pad_ok
                ; Borrow path: content was longer than the field. Clip pad to
                ; 0 AND clip the content copy length to the field width so
                ; downstream columns stay aligned even on overrun.
                LOADI   D3, #0
                MOVE    D0, D2                  ; clip content len = field width
.kes_pad_ok:
                ; Emit D3 spaces.
                LOADI   D2, #' '
.kes_pad_loop:
                CMP     D3, #0
                BEQ.S   .kes_pad_done
                STOREB  D2, [XY1]+
                SUB     D3, #1
                BRA     .kes_pad_loop
.kes_pad_done:
                BRA.S   .kes_copy
.kes_no_pad:
                ; No padding. D0 still = content length; fall into copy.
.kes_copy:

                ; ---- 4. Copy content from SIZE_FMT_BUF -------------------
                ; D0 still = content length. Source: SIZE_FMT_BUF.
                PUSH    XY0, XY3
                MOVE    Y0, Y3
                LOADI   X0, #SIZE_FMT_BUF
.kes_cpy_loop:
                CMP     D0, #0
                BEQ.S   .kes_cpy_done
                LOADB   D2, [XY0]+
                STOREB  D2, [XY1]+
                SUB     D0, #1
                BRA     .kes_cpy_loop
.kes_cpy_done:
                POP     XY0, XY3
                RET


; ============================================================================
; Wildcard / glob helpers (Part 37 - 28 May 2026)
; ============================================================================
;
; _KoshFnMatch    - match one filename against a wildcard pattern
; _KoshHasWildcard - does a string contain '*' or '?'
;
; Both operate on ASCIIZ strings in the current task page (Y3). Pointers
; are passed as full XY but only the X (offset) half varies - the Y half
; is always Y3 - so internally we track 16-bit offsets and reconstruct
; the dereference pointer with Y3 each time. This is the same task-page
; convention used throughout kosh.
; ----------------------------------------------------------------------------

; ----------------------------------------------------------------------------
; _KoshFoldChar - uppercase-fold one character (internal).
;
;   In:       D0 = char (low 8 bits)
;   Out:      D0 = uppercased if it was 'a'..'z', else unchanged
;   Clobbers: nothing else
;   Preserves: D1, D2, D3, all XY
;
;   FAT16 names are case-insensitive; we fold both pattern and name chars
;   so "*.txt" matches "HELLO.TXT".
; ----------------------------------------------------------------------------
_KoshFoldChar:
                AND     D0, #$FF
                CMP     D0, #'a'
                BLO.S   .fc_done
                CMP     D0, #$7B                ; 'z'+1
                BHS.S   .fc_done
                SUB     D0, #$20                ; -> uppercase
.fc_done:
                RET

; ----------------------------------------------------------------------------
; _KoshFnMatch - match a filename against a wildcard pattern.
;
;   In:   XY0 = pattern  (ASCIIZ; '*' = any run, '?' = any one char)
;         XY1 = name     (ASCIIZ; the display name, e.g. "HELLO.TXT")
;         Both in the current task page (Y0/Y1 expected = Y3).
;   Out:  C = 0  match
;         C = 1  no match
;   Clobbers: D0, D1, D2, D3, XY0, XY1
;   Preserves: XY2, XY3
;
;   Algorithm: classic iterative single-star backtrack (Kernighan/Sedgewick
;   "globbing" match). No recursion -> no stack growth. Handles '*', '?',
;   multiple stars, leading/trailing stars. '.' is an ordinary literal, so
;   "*.TXT" works because '*' spans the basename and '.TXT' matches literally.
;
;   Register map (offsets within the task page):
;     X0 = pattern cursor      X1 = name cursor
;     D2 = star pattern-offset ($FFFF = no star seen yet)
;     D3 = name-offset captured when the star was seen (backtrack resume)
;     D0/D1 = scratch char compares
;   Y0/Y1 held at Y3 throughout for dereferences.
; ----------------------------------------------------------------------------
_KoshFnMatch:
                MOVE    Y0, Y3                  ; pattern page
                MOVE    Y1, Y3                  ; name page
                LOADI   D2, #$FFFF              ; star_p = none (no '*' seen)
                ; D3 (name-resume offset) is only valid once star_p is set.

.fm_loop:
                ; Read current name char into D1.
                LOADB   D1, [XY1]
                AND     D1, #$FF
                CMP     D1, #0
                BEQ     .fm_name_end            ; name exhausted

                ; Name still has chars. Read pattern char into D0.
                LOADB   D0, [XY0]
                AND     D0, #$FF

                ; '?' -> matches any single name char.
                CMP     D0, #'?'
                BNE.S   .fm_try_star
                INC     XY0, #1
                INC     XY1, #1
                BRA     .fm_loop

.fm_try_star:
                ; '*' -> remember the position just PAST the star, and the
                ; current name offset as the backtrack resume point. Consume
                ; zero name chars for now.
                CMP     D0, #'*'
                BNE.S   .fm_literal
                INC     XY0, #1                 ; advance past the '*'
                MOVE    D2, X0                  ; star_p = offset just past '*'
                MOVE    D3, X1                  ; name-resume = current name offset
                BRA     .fm_loop

.fm_literal:
                ; DIAGNOSTIC VARIANT: inline fold (no CALL24) but KEEP the
                ; PUSH D2 / POP D2 around it. If this breaks -> push/pop is the
                ; culprit. If it works -> the CALL24 was clobbering something.
                PUSH    D2, XY3                 ; (diagnostic) save star_p
                ; Fold D0 (pattern) to upper.
                CMP     D0, #'a'
                BLO.S   .fm_d0_up
                CMP     D0, #$7B                ; 'z'+1
                BHS.S   .fm_d0_up
                SUB     D0, #$20
.fm_d0_up:
                ; Fold D1 (name) to upper.
                CMP     D1, #'a'
                BLO.S   .fm_d1_up
                CMP     D1, #$7B
                BHS.S   .fm_d1_up
                SUB     D1, #$20
.fm_d1_up:
                POP     D2, XY3                 ; (diagnostic) restore star_p
                CMP     D0, D1                  ; folded pattern == folded name?
                BNE.S   .fm_mismatch

                ; Matched this char - advance both cursors.
                INC     XY0, #1
                INC     XY1, #1
                BRA     .fm_loop

.fm_mismatch:
                ; Literal mismatch. If a star was seen, backtrack: the star
                ; absorbs one more name char. Pattern resumes just past '*',
                ; name resumes at (resume+1).
                CMP     D2, #$FFFF
                BEQ     .fm_no_match            ; no star -> dead end

                MOVE    X0, D2                  ; pattern -> just past '*'
                MOVE    Y0, Y3
                INC     D3, #1                  ; star eats one more name char
                MOVE    X1, D3                  ; name -> resume+1
                MOVE    Y1, Y3
                BRA     .fm_loop

.fm_name_end:
                ; Name exhausted. Skip any trailing '*' in the pattern.
.fm_skip_stars:
                LOADB   D0, [XY0]
                AND     D0, #$FF
                CMP     D0, #'*'
                BNE.S   .fm_check_pat_end
                INC     XY0, #1
                BRA     .fm_skip_stars
.fm_check_pat_end:
                ; If pattern is also exhausted -> match.
                CMP     D0, #0
                BEQ.S   .fm_match
                BRA.S   .fm_no_match

.fm_match:
                CLC
                RET

.fm_no_match:
                SEC
                RET

; ----------------------------------------------------------------------------
; _KoshHasWildcard - does a string contain '*' or '?'.
;
;   In:   XY0 = ASCIIZ string (task page; may include "X:" prefix)
;   Out:  C = 0  contains a wildcard char
;         C = 1  no wildcard
;   Clobbers: D0
;   Preserves: D1, D2, D3, XY1, XY2, XY3 (XY0 advanced to the match or nul)
; ----------------------------------------------------------------------------
_KoshHasWildcard:
                MOVE    Y0, Y3
.hw_loop:
                LOADB   D0, [XY0]
                AND     D0, #$FF
                CMP     D0, #0
                BEQ.S   .hw_none
                CMP     D0, #'*'
                BEQ.S   .hw_found
                CMP     D0, #'?'
                BEQ.S   .hw_found
                INC     XY0, #1
                BRA     .hw_loop
.hw_found:
                CLC
                RET
.hw_none:
                SEC
                RET

; ============================================================================
; _KoshSplitDrivePat - REMOVED, Part 64 step 2 (9 August 2026).
;
;   Split "X:pattern" or "pattern" into a drive index, a start cluster and
;   a basename pattern pointer. Superseded by _KoshSplitDirPat. Do NOT
;   reintroduce it.
;
;   It split on "X:" and NOTHING else, so any directory component landed
;   inside the basename pattern: "sub/*.com" became the pattern
;   "sub/*.com", which _KoshFnMatch then compared against bare filenames
;   and never matched. No error, no message, no matches - it read as an
;   unimplemented feature for as long as it survived, which is why it was
;   never chased. That silence is the whole reason it is gone rather than
;   merely unused: a helper that returns a plausible answer for input it
;   cannot handle will be reached for again.
;
;   Replacement: _KoshSplitDirPat, below the tombstone. It finds the last
;   '/' (else the ':'), copies the prefix out and hands it to sys_resolve
;   rather than parsing path syntax itself - so "X:", "NAME:" assigns, a
;   leading '/', '.', '..' and a trailing '/' all work by construction,
;   and a prefix that does not resolve, or resolves to a file, is a hard
;   error. Its extra outputs (D2 = prefix length, plus GLOB_PFXPTR /
;   GLOB_PFXLEN) let a caller rebuild "<prefix><name>" per match, which is
;   what cp/mv need to keep both sides of a copy in the same frame.
;
;   Note for anyone reading old comments: the "an explicit X: prefix means
;   start cluster 0" convention was documented HERE and is referenced from
;   the _KoshNormPath tombstone above and from Gotchas 4.69. The rule is
;   unchanged and still enforced - by _ResolveCore, which is where it
;   always actually lived.
; ============================================================================

; ----------------------------------------------------------------------------
; _KoshSplitDirPat - split an argument into a resolved DIRECTORY and a
;                    basename pattern (Part 64).
;
;   In:   XY0 = arg (ASCIIZ, task page), e.g. "*.com", "b:*.com",
;               "sub/*.com", "b:/a/b/*.com", "gfx:*.com"
;   Out:  C = 0  D0  = drive index of the directory to glob
;                D1  = cluster of that directory (0 = root)
;                D2  = prefix length in bytes (0 when there is no directory
;                      part) - the pattern starts at arg + D2
;                XY1 = basename pattern pointer
;                GLOB_PFXPTR / GLOB_PFXLEN also hold arg and D2, so a caller
;                can rebuild "<prefix><name>" per match.
;         C = 1  D0 = ERR_* from sys_resolve, ERR_NOTDIR if the prefix names
;                a file, or CP_ERR_TOOLONG if the prefix will not fit in a
;                KOSH_NORM buffer.
;   Clobbers: D0, D1, D2, D3, XY0, XY1
;   Preserves: XY2, XY3
;   Uses KOSH_NORM_B as scratch - safe at every call site, which splits
;   before any per-item work begins.
;
;   Supersedes _KoshSplitDrivePat at the glob call sites. That routine
;   splits on "X:" and NOTHING else, so "sub/*.com" became the pattern
;   "sub/*.com" and matched nothing at all - silently, which is why it went
;   unnoticed. _KoshSplitDrivePat itself is unchanged and still used by the
;   literal (non-glob) paths.
;
;   Deliberately parses NO path syntax beyond finding the split point. The
;   prefix is copied out and handed to sys_resolve, which already handles
;   "X:", "NAME:" assigns, a leading '/', '.', '..' and a trailing '/'
;   (_ResolveCore's component loop skips separator runs, then sees the nul
;   and returns). Reimplementing any of that here would be a second, worse
;   copy of the resolver.
;
;   Both '/' and ':' update the split point as the scan runs, so the LAST
;   one wins: "b:/sub/x" splits after the second '/'. A ':' can only
;   legally appear in the prefix anyway.
;
;   An unresolvable or non-directory prefix is a hard error. The previous
;   behaviour - no matches, no message - is the failure mode this routine
;   exists to end.
; ----------------------------------------------------------------------------
_KoshSplitDirPat:
                MOVE    D2, X0                  ; D2 = arg start offset
                STOREP  D2, Y3, [#GLOB_PFXPTR]
                MOVE    Y0, Y3
                LOADI   D3, #0                  ; D3 = prefix length (0 = none)
.sdirp_scan:
                LOADB   D0, [XY0]
                AND     D0, #$FF
                CMP     D0, #0
                BEQ     .sdirp_scanned
                CMP     D0, #'/'
                BEQ.S   .sdirp_sep
                CMP     D0, #':'
                BNE.S   .sdirp_step
.sdirp_sep:
                MOVE    D3, X0
                SUB     D3, D2                  ; offset within the arg
                ADD     D3, #1                  ; prefix INCLUDES the separator
.sdirp_step:
                INC     XY0, #1                 ; flag-transparent (Part 49+)
                BRA     .sdirp_scan

.sdirp_scanned:
                STOREP  D3, Y3, [#GLOB_PFXLEN]
                CMP     D3, #0
                BEQ     .sdirp_nopfx

                ; --- Copy the prefix out and resolve it -------------------
                ; Copied rather than nul-terminated in place: the arg lives in
                ; LINE_BUF and is mutable, but a save/terminate/resolve/restore
                ; sequence would have to carry the saved byte AND the arg
                ; offset across a TRAP that returns three values, and every
                ; error arm would need its own restore. A copy costs one
                ; buffer that is free at this point.
                LOADP   D0, Y3, [#GLOB_PFXPTR]
                MOVE    Y0, Y3
                MOVE    X0, D0
                MOVE    Y1, Y3
                LOADI   X1, #KOSH_NORM_B
                MOVE    D0, D3                  ; count = prefix length
                LOADI   D1, #KOSH_NORM_LEN
                CALL16  _KoshCopyCounted
                BCS     .sdirp_ret              ; D0 = CP_ERR_TOOLONG already

                MOVE    Y1, Y3
                LOADI   X1, #KOSH_CWD
                LOADB   D0, [XY1]
                AND     D0, #$FF
                SUB     D0, #'A'                ; D0 = shell CWD drive index
                LOADP   D1, Y3, [#KOSH_CWD_CLU] ; D1 = shell CWD cluster
                MOVE    Y0, Y3
                LOADI   X0, #KOSH_NORM_B        ; XY0 = the prefix, ASCIIZ
                TRAP    #TRAP_RESOLVE           ; -> D0=drive, D1=clu, D2=attr
                BCS     .sdirp_ret              ; D0 = ERR_* from the resolver

                ; Must be a directory. A file here means something like
                ; "notes.txt/*.com", which cannot match anything.
                AND     D2, #DIR_ATTR_DIRECTORY
                BEQ     .sdirp_notdir
                BRA     .sdirp_out

.sdirp_nopfx:
                ; No directory part: glob the shell's current directory, the
                ; same default _KoshSplitDrivePat applied for a bare pattern.
                MOVE    Y1, Y3
                LOADI   X1, #KOSH_CWD
                LOADB   D0, [XY1]
                AND     D0, #$FF
                SUB     D0, #'A'
                LOADP   D1, Y3, [#KOSH_CWD_CLU]

.sdirp_out:
                ; D0 = drive, D1 = cluster. Rebuild D2 / XY1 from the slots.
                LOADP   D2, Y3, [#GLOB_PFXLEN]
                LOADP   D3, Y3, [#GLOB_PFXPTR]
                ADD     D3, D2                  ; pattern = arg + prefix length
                MOVE    Y1, Y3
                MOVE    X1, D3
                CLC
                RET

.sdirp_notdir:
                LOADI   D0, #ERR_NOTDIR
.sdirp_ret:
                SEC
                RET

; ----------------------------------------------------------------------------
; _KoshDirentDisplay - pick the display-name offset out of a DIRENT_INFO buffer.
;
;   In:   D0 = offset of a DIRENT_INFO buffer in the task page
;   Out:  D0 = offset of the name to show the user:
;              buf+$20 when a VFAT long name was assembled for this entry,
;              else buf+$00 (the 8.3 "NAME.EXT" form)
;   Clobbers: D0, XY0, flags
;   Preserves: D1, D2, D3, XY1, XY2, XY3
;
;   _FatEntryToInfo zero-fills all 64 bytes before it writes anything and
;   only fills +$20 when LFN_ASM_LEN > 0, so a nul first byte there is a
;   reliable "no long name". Both fields are ASCIIZ: +$00 is "NAME.EXT"
;   with the dot inserted and NO space padding (_DirNameFromFat strips it),
;   +$20 is LFN_ASM_LEN bytes plus a nul, at most LFN_MAX + 1 = 32, which
;   is exactly the room left in a 64-byte DIRENT_INFO.
;
;   LOADB is flag-transparent, hence the explicit CMP before the branch.
; ----------------------------------------------------------------------------
_KoshDirentDisplay:
                MOVE    Y0, Y3
                MOVE    X0, D0
                ADD     X0, #$20                ; XY0 -> long-name field
                LOADB   D0, [XY0]
                AND     D0, #$FF
                CMP     D0, #0
                BEQ.S   .kdd_short
                MOVE    D0, X0                  ; long name present
                RET
.kdd_short:
                MOVE    D0, X0
                SUB     D0, #$20                ; back to the 8.3 field
                RET

; ----------------------------------------------------------------------------
; _KoshDirentMatch - match a wildcard pattern against a dirent, display name
;                    first and the 8.3 name as a fallback (Part 64).
;
;   In:   D0 = pattern offset      (ASCIIZ, task page)
;         D1 = DIRENT_INFO offset  (the 8.3 name lives at +$00)
;         D2 = display-name offset (from _KoshDirentDisplay)
;   Out:  C = 0  matched (by either name)
;         C = 1  no match
;   Clobbers: D0, D1, D2, D3, XY0, XY1
;   Preserves: XY2, XY3
;
;   The fallback exists so that a name the user copied off an older listing
;   still works: "cp MANDEL~1.COM b:" has no wildcard and never reaches
;   here, but "rm *~1.com" does. When D2 == D1 there IS no long name and the
;   second attempt would repeat the first, so it is skipped.
;
;   _KoshFnMatch clobbers D0..D3, so the pattern offset is stacked across
;   the first attempt. Nothing here adjusts X3, so Gotchas 4.70 (never PUSH
;   across a stack-pointer adjustment) does not bite.
; ----------------------------------------------------------------------------
_KoshDirentMatch:
                PUSH    D0, XY3                 ; pattern offset
                PUSH    D1, XY3                 ; 8.3 name offset
                PUSH    D2, XY3                 ; display name offset
                MOVE    Y0, Y3
                MOVE    X0, D0                  ; XY0 = pattern
                MOVE    Y1, Y3
                MOVE    X1, D2                  ; XY1 = display name
                CALL16  _KoshFnMatch
                ; Branch on the carry BEFORE unwinding. RM 15.3 puts POP Dn
                ; in the flag-transparent Move/Load/Store row, but POP SR is
                ; explicitly a flag WRITE, so the two forms sit one operand
                ; apart in the encoding and this routine will not rest on
                ; that distinction. Each arm unwinds its own three slots.
                BCC.S   .kdm_hit

                ; Display name missed. If it WAS the 8.3 name, we are done.
                POP     D2, XY3
                POP     D1, XY3
                POP     D0, XY3
                CMP     D1, D2
                BEQ.S   .kdm_miss
                MOVE    Y0, Y3
                MOVE    X0, D0                  ; XY0 = pattern (restored)
                MOVE    Y1, Y3
                MOVE    X1, D1                  ; XY1 = 8.3 name
                CALL16  _KoshFnMatch
                RET                             ; propagate its carry

.kdm_hit:
                POP     D2, XY3
                POP     D1, XY3
                POP     D0, XY3
                CLC
                RET

.kdm_miss:
                SEC
                RET

; ----------------------------------------------------------------------------
; _KoshGlobEntryPtr - glob table index -> task-page offset of that entry.
;
;   In:   D0 = entry index (0 .. GLOB_MAX-1)
;         GLOB_TABLE = table base offset
;   Out:  D3 = GLOB_TABLE + index * GLOB_ENTRY_SIZE
;   Clobbers: D0, D3, flags
;   Preserves: D1, D2, XY0, XY1, XY2, XY3
;
;   Part 64: four call sites in kosh_cmds_fs.asm plus the collector below
;   open-coded this. At GLOB_ENTRY_SIZE 14 it was a six-instruction
;   shift-and-add chain repeated five times; at 32 it is SHL4 + SHL, and
;   there is now one copy of it. The shift count IS GLOB_ENTRY_SHIFT - the
;   symbol cannot be spelled in the operand, so the two must be kept in step
;   by hand.
; ----------------------------------------------------------------------------
_KoshGlobEntryPtr:
                SHL4    D0                      ; *16
                SHL     D0                      ; *32 = GLOB_ENTRY_SIZE
                MOVE    D3, D0
                LOADP   D0, Y3, [#GLOB_TABLE]
                ADD     D3, D0
                RET

; ----------------------------------------------------------------------------
; _KoshGlobExpand - walk a drive's directory, collect names matching a pattern.
;
;   In:   D0  = drive index (0..5)
;         XY1 = pattern (ASCIIZ basename pattern, e.g. "*.TXT"; task page)
;         D2  = max entries the table can hold (= root_entries for the drive)
;         GLOB_TABLE (scratch) = table base offset in the task page (caller
;               has already reserved the stack region and written its base
;               offset here)
;   Out:  D0  = match count (0..max)
;         C = 0  OK (D0 = count, may be 0)
;         C = 1  table full - more matches than max (D0 = max; truncated)
;   Clobbers: D0, D1, D2, D3, XY0, XY1
;   Preserves: XY2, XY3
;
;   Each table entry is GLOB_ENTRY_SIZE (32) bytes holding the ASCIIZ
;   DISPLAY name: the VFAT long name when the entry has one (up to LFN_MAX
;   = 31 chars + nul, hence 32), else the 8.3 "NAME.EXT" form. Part 64:
;   this was 14 and 8.3-only, which made cp/mv lossy - they create a new
;   file from whatever name the table carries, so a copied "Mandelbrot.com"
;   became a real "MANDEL~1.COM" at the destination.
;
;   Walk uses sys_dirent with a monotonically increasing index; sys_dirent's
;   internal iteration cache (Part 22) makes each sequential step cheap.
; ----------------------------------------------------------------------------
_KoshGlobExpand:
                ; Stash inputs into scratch state.
                STOREP  D0, Y3, [#GLOB_DRIVE]
                MOVE    D0, X1
                STOREP  D0, Y3, [#GLOB_PATPTR]      ; pattern offset (page = Y3)
                STOREP  D2, Y3, [#GLOB_MAX]
                LOADI   D0, #0
                STOREP  D0, Y3, [#GLOB_INDEX]
                STOREP  D0, Y3, [#GLOB_COUNT]

.ge_loop:
                ; sys_dirent(drive, index, cluster=GLOB_CLU, buf=GLOB_DIRENT_BUF).
                ; Part 44 step 4: GLOB_CLU is the directory being globbed — the
                ; CWD cluster for a bare pattern, or 0 (root) for an "X:"-prefixed
                ; one (set by the caller from _KoshSplitDrivePat's D1).
                LOADP   D0, Y3, [#GLOB_DRIVE]
                LOADP   D1, Y3, [#GLOB_INDEX]
                LOADP   D2, Y3, [#GLOB_CLU]     ; start cluster (0 = root)
                MOVE    Y0, Y3
                LOADI   X0, #GLOB_DIRENT_BUF
                TRAP    #TRAP_DIRENT
                BCS     .ge_done                ; end of directory (or error)

                ; --- Files only (Part 62) --------------------------------
                ; Attr byte lives at DIRENT_INFO+$0C (same offset ls reads).
                ; Skip directories - including the "." and ".." entries that
                ; "*.*" matches in every subdirectory - and the volume label,
                ; which "*.*" would otherwise match in a root. AND sets the
                ; flags; the LOADB above it is flag-transparent, which is why
                ; the test cannot be a bare branch on the load.
                MOVE    Y0, Y3
                LOADI   X0, #GLOB_DIRENT_BUF+$0C
                LOADB   D0, [XY0]
                AND     D0, #GLOB_SKIP_ATTR
                BNE     .ge_next

                ; --- Display name (Part 64) ------------------------------
                ; Pick +$20 (long) or +$00 (8.3) exactly as ls does, and
                ; remember it: the same offset drives BOTH the match below
                ; and the copy into the table, so the name we matched is
                ; always the name we store.
                LOADI   D0, #GLOB_DIRENT_BUF
                CALL16  _KoshDirentDisplay
                STOREP  D0, Y3, [#GLOB_NAMEPTR]

                ; Match: display name first, 8.3 as a fallback.
                MOVE    D2, D0                  ; D2 = display name offset
                LOADI   D1, #GLOB_DIRENT_BUF    ; D1 = 8.3 name offset
                LOADP   D0, Y3, [#GLOB_PATPTR]  ; D0 = pattern offset
                CALL16  _KoshDirentMatch
                BCS     .ge_next                ; no match - skip

                ; Match. Check capacity.
                LOADP   D0, Y3, [#GLOB_COUNT]
                LOADP   D1, Y3, [#GLOB_MAX]
                CMP     D0, D1
                BHS     .ge_full                ; count >= max -> truncated

                ; Copy the display name into table[count].
                ; dest = GLOB_TABLE + count*GLOB_ENTRY_SIZE.
                CALL16  _KoshGlobEntryPtr       ; D0 = count -> D3 = dest offset

                ; Source = the display name chosen above.
                LOADP   D0, Y3, [#GLOB_NAMEPTR]
                MOVE    Y0, Y3
                MOVE    X0, D0
                MOVE    Y1, Y3
                MOVE    X1, D3                  ; XY1 = dest

                ; Part 64: the stop rule depends on WHICH field was read, so
                ; it is decided once here rather than tested per byte.
                ;   long (+$20): nul only, up to LFN_MAX bytes. A long name
                ;       legitimately contains spaces ("my notes.txt"), so the
                ;       old space rule would truncate it at the first one.
                ;   8.3 (+$00): nul or space, up to 13 bytes. _DirNameFromFat
                ;       already strips the FAT pad, so the space arm is belt
                ;       and braces - but a space reaching _ParsePath is an
                ;       illegal filename char (ERR_BADPATH), so it stays.
                ; Both budgets leave room for the terminator inside a
                ; GLOB_ENTRY_SIZE slot: 31+1 and 13+1.
                ; D0 still holds the display offset; compare it against the
                ; 8.3 field to tell the two apart.
                CMP     D0, #GLOB_DIRENT_BUF
                BEQ.S   .ge_copy_short

                ; Both exits are FULL branches, not .S: they have to clear
                ; the whole .ge_copy_short block below to reach
                ; .ge_terminate, which is past the 31-byte forward-only
                ; short-branch window.
                LOADI   D2, #LFN_MAX            ; 31 chars + nul = 32
.ge_copy_long:
                LOADB   D0, [XY0]+
                CMP     D0, #0
                BEQ     .ge_terminate           ; nul -> terminate
                STOREB  D0, [XY1]+
                SUB     D2, #1
                BNE     .ge_copy_long
                BRA     .ge_terminate           ; budget exhausted at LFN_MAX

.ge_copy_short:
                LOADI   D2, #13                 ; max bytes to copy
.ge_copy_loop:
                LOADB   D0, [XY0]+
                CMP     D0, #0
                BEQ.S   .ge_terminate           ; nul -> terminate
                CMP     D0, #CH_SPACE
                BEQ.S   .ge_terminate           ; space -> terminate (strip)
                STOREB  D0, [XY1]+
                SUB     D2, #1
                BNE     .ge_copy_loop
.ge_terminate:
                LOADI   D0, #0
                STOREB  D0, [XY1]               ; write terminator
.ge_copied:
                ; count++.
                LOADP   D0, Y3, [#GLOB_COUNT]
                ADD     D0, #1
                STOREP  D0, Y3, [#GLOB_COUNT]

.ge_next:
                LOADP   D0, Y3, [#GLOB_INDEX]
                ADD     D0, #1
                STOREP  D0, Y3, [#GLOB_INDEX]
                BRA     .ge_loop

.ge_done:
                LOADP   D0, Y3, [#GLOB_COUNT]
                CLC
                RET

.ge_full:
                ; Table full. Return count = max, C=1 (truncated).
                LOADP   D0, Y3, [#GLOB_MAX]
                SEC
                RET

; ============================================================================
; _KoshStashCwd - capture the shell CWD into CP_CWD_DRV / CP_CWD_CLU so the
;                 cp/mv workers can pass CWD context to each open / rename /
;                 unlink (Part 44).
;
;   In:    (reads KOSH_CWD drive letter + KOSH_CWD_CLU in the task page)
;   Out:   CP_CWD_DRV = drive index, CP_CWD_CLU = cluster
;   Clobbers: D0, X1, Y1, flags
;   Preserves: D2, D3, XY0, XY2, XY3
; ----------------------------------------------------------------------------
_KoshStashCwd:
                MOVE    Y1, Y3
                LOADI   X1, #KOSH_CWD
                LOADB   D0, [XY1]
                SUB     D0, #'A'                 ; CWD drive index
                STOREP  D0, Y3, [#CP_CWD_DRV]
                LOADI   X1, #KOSH_CWD_CLU
                LOADD   D0, [XY1]
                STOREP  D0, Y3, [#CP_CWD_CLU]
                RET

; ============================================================================
; _KoshResolveDstPath - if the dst path names an existing DIRECTORY, rewrite
;                       it to "<dst>[/]<src-basename>" so "cp f b:/foo" lands
;                       as "b:/foo/F". Subsumes the old bare-drive case
;                       ("b:" resolves to the root directory).
;
;   Part 44 (17 June 2026): replaces _KoshExpandBareDst. Uses sys_resolve
;   (TRAP_RESOLVE) to ask the kernel whether the dst is a directory, rather
;   than string-sniffing a "X:" prefix — so it works for raw/relative paths
;   and for any subdirectory, not just a bare drive. Self-contained so it can
;   be lifted into a KLIB slot (basename / path-join) if a second consumer
;   appears.
;
;   In:    CP_SRC_PATH = ptr to src path (task page)
;          CP_DST_PATH = ptr to dst path (task page)
;          CP_CWD_CLU / CP_CWD_DRV = CWD context for resolution
;   Out:   C = 0  If dst resolves to a directory: KOSH_NORM_B holds the
;                 joined path and CP_DST_PATH is repointed to it.
;                 Otherwise unchanged.
;          C = 1  Part 62: the join would exceed KOSH_NORM_LEN.
;                 D0 = CP_ERR_TOOLONG; CP_DST_PATH is left alone, so the
;                 caller reports and aborts. Truncating instead would
;                 quietly target a different file.
;   Clobbers: D0, D1, D2, D3, X0, X1, Y0, Y1, flags
;   Preserves: XY2, XY3
;
;   basename(src) = the run after the last '/' or ':' (whole string if none).
;   A '/' separator is inserted unless dst already ends in '/' or ':'.
; ----------------------------------------------------------------------------
_KoshResolveDstPath:
                ; --- Resolve dst: existing directory? ---------------------
                LOADP   D0, Y3, [#CP_DST_PATH]
                MOVE    X0, D0
                MOVE    Y0, Y3                   ; XY0 = dst path
                LOADP   D0, Y3, [#CP_CWD_DRV]    ; D0 = CWD drive index
                LOADP   D1, Y3, [#CP_CWD_CLU]    ; D1 = CWD cluster
                TRAP    #TRAP_RESOLVE            ; -> D0=drive, D1=clu, D2=attr
                BCS     .rdp_done                ; not found -> new file, dst as-is
                AND     D2, #DIR_ATTR_DIRECTORY
                BEQ     .rdp_done                ; exists but is a file -> as-is
                                                 ;   (cp's existence check rejects)

                ; --- Copy dst into KOSH_NORM_B, tracking the last char ----
                ; Part 62: D1 carries the remaining capacity through all
                ; three write phases below. It is free here - the resolve
                ; TRAP above returned in it, and that value is dead once
                ; the directory test on D2 has been made.
                MOVE    Y0, Y3
                LOADP   D0, Y3, [#CP_DST_PATH]
                MOVE    X0, D0                   ; XY0 = dst source
                MOVE    Y1, Y3
                LOADI   X1, #KOSH_NORM_B         ; XY1 = dest buffer
                LOADI   D3, #0                   ; D3 = last char copied
                LOADI   D1, #KOSH_NORM_LEN       ; D1 = bytes left (incl nul)
.rdp_dcopy:
                CMP     D1, #2                   ; room for a char + its nul?
                BLO     .rdp_toolong
                LOADB   D0, [XY0]+
                CMP     D0, #0
                BEQ.S   .rdp_dcopied
                STOREB  D0, [XY1]+
                MOVE    D3, D0
                SUB     D1, #1
                BRA     .rdp_dcopy
.rdp_dcopied:
                ; XY1 -> slot after dst. Insert '/' unless dst ended '/' or ':'.
                CMP     D3, #'/'
                BEQ.S   .rdp_sep_done
                CMP     D3, #':'
                BEQ.S   .rdp_sep_done
                CMP     D1, #2                   ; Part 62: room for sep + nul?
                BLO     .rdp_toolong
                LOADI   D0, #'/'
                STOREB  D0, [XY1]+
                SUB     D1, #1
.rdp_sep_done:
                ; --- Find src basename offset (after last '/' or ':') -----
                LOADP   D0, Y3, [#CP_SRC_PATH]
                MOVE    D2, D0                   ; D2 = basename offset (default start)
                MOVE    X0, D0
                MOVE    Y0, Y3                   ; XY0 = src walk
.rdp_bscan:
                LOADB   D0, [XY0]
                CMP     D0, #0
                BEQ.S   .rdp_bappend
                CMP     D0, #'/'
                BEQ.S   .rdp_bsep
                CMP     D0, #':'
                BEQ.S   .rdp_bsep
                BRA.S   .rdp_bstep
.rdp_bsep:
                MOVE    D2, X0
                ADD     D2, #1                   ; basename starts after the sep
.rdp_bstep:
                INC     XY0, #1
                BRA     .rdp_bscan
.rdp_bappend:
                ; XY0 = src basename ptr (Y3 : D2)
                MOVE    Y0, Y3
                MOVE    X0, D2
                ; Part 62: bounded basename append. XY1/D1 carry over from
                ; the phases above; _KoshCopyBounded terminates either way.
                CALL16  _KoshCopyBounded
                BCS     .rdp_toolong_termed
                LOADI   D0, #KOSH_NORM_B
                STOREP  D0, Y3, [#CP_DST_PATH]
.rdp_done:
                CLC
                RET

.rdp_toolong:
                ; Ran out mid-copy. Terminate what is there so an error arm
                ; can print it, then fail. CP_DST_PATH is deliberately NOT
                ; repointed - the caller aborts with the original dst.
                LOADI   D0, #0
                STOREB  D0, [XY1]
.rdp_toolong_termed:
                LOADI   D0, #CP_ERR_TOOLONG
                SEC
                RET

; ----------------------------------------------------------------------------
; _KoshNextToken - quote-aware tokeniser for the kosh command line.
;
;   Pulls the next whitespace-delimited token out of the argument region,
;   nul-terminating it in place. A token wrapped in double quotes keeps its
;   interior spaces, so a spaced long filename survives intact:
;       cp notes.txt "test test.txt"   -> two tokens
;
;   In:   XY0 = cursor into the line (Y0 = Y3 task page). May sit on leading
;               whitespace; the routine skips it.
;   Out:  C = 0  token found:
;               XY1 = token start, nul-terminated in place (Y1 = Y3)
;               XY0 = cursor advanced past the token terminator, ready for
;                     the next call
;               D0  = token length (excluding the nul)
;         C = 1  no more tokens (end of line). XY0 left at the nul.
;
;   Whitespace = CH_SPACE or CH_TAB; a leading run of either is skipped.
;   Quote handling: a token whose first char is CH_QUOTE runs to the closing
;   CH_QUOTE (overwritten with nul; cursor left just past it). XY1 points at
;   the body (the opening quote is simply skipped - no shift needed, the body
;   is already contiguous ASCIIZ once the closing quote becomes the nul). An
;   unterminated quote runs to the line nul - lenient, no error here; illegal
;   filename chars are rejected later at the resolver (_RvExtractComponent).
;
;   Clobbers: D0, D2.  Preserves: D1, D3, XY2, XY3.
; ----------------------------------------------------------------------------
_KoshNextToken:
                MOVE    Y1, Y3                   ; result page = task page
                ; --- skip leading whitespace (space / tab) -----------------
.knt_skip:
                LOADB   D0, [XY0]
                AND     D0, #$FF
                CMP     D0, #0
                BEQ     .knt_none                ; end of line -> no token
                CMP     D0, #CH_SPACE
                BEQ     .knt_ws
                CMP     D0, #CH_TAB
                BNE     .knt_have                ; non-ws, non-nul -> token
.knt_ws:
                INC     XY0, #1
                BRA     .knt_skip

.knt_none:
                SEC
                RET

.knt_have:
                CMP     D0, #CH_QUOTE
                BEQ     .knt_quoted

                ; --- unquoted token: run to next ws / nul ------------------
                LEA     XY1, XY0                 ; token start
                MOVE    D2, X0                   ; remember start offset (len calc)
.knt_uq_scan:
                LOADB   D0, [XY0]
                AND     D0, #$FF
                CMP     D0, #0
                BEQ     .knt_uq_endnul
                CMP     D0, #CH_SPACE
                BEQ     .knt_uq_endws
                CMP     D0, #CH_TAB
                BEQ     .knt_uq_endws
                INC     XY0, #1
                BRA     .knt_uq_scan
.knt_uq_endws:
                LOADI   D0, #0
                STOREB  D0, [XY0]                ; nul over the ws
                MOVE    D0, X0
                SUB     D0, D2                   ; D0 = token length
                INC     XY0, #1                  ; cursor past the terminator
                CLC
                RET
.knt_uq_endnul:
                MOVE    D0, X0
                SUB     D0, D2                   ; D0 = token length
                CLC                              ; cursor left at the nul
                RET

                ; --- quoted token: run to closing quote / nul -------------
.knt_quoted:
                INC     XY0, #1                  ; skip the opening quote
                LEA     XY1, XY0                 ; body start (contiguous ASCIIZ)
                MOVE    D2, X0                   ; start offset
.knt_q_scan:
                LOADB   D0, [XY0]
                AND     D0, #$FF
                CMP     D0, #0
                BEQ     .knt_q_endnul            ; unterminated -> lenient
                CMP     D0, #CH_QUOTE
                BEQ     .knt_q_endq
                INC     XY0, #1
                BRA     .knt_q_scan
.knt_q_endq:
                LOADI   D0, #0
                STOREB  D0, [XY0]                ; nul over the closing quote
                MOVE    D0, X0
                SUB     D0, D2                   ; D0 = body length
                INC     XY0, #1                  ; cursor past the closing quote
                CLC
                RET
.knt_q_endnul:
                MOVE    D0, X0
                SUB     D0, D2                   ; D0 = body length
                CLC                              ; cursor left at the nul
                RET


; ============================================================================
; _KoshExecFile - resolve + run a .COM, with auto-".com" fallback (CALL16)
; ============================================================================
;   Input:    XY0 = nul-terminated executable name / path (e.g. "hello",
;                   "hello.com", "B:HELLO.COM"). Read-only; copied into
;                   ROW_BUF so the retry can append ".com" in place.
;             D3  = background flag (0 = foreground, 1 = background).
;
;   Behaviour:
;     1. Copy name -> ROW_BUF (working buffer; survives both TRAPs).
;     2. sys_exec it as-typed. _ParsePath honours an "X:" prefix, a
;        leading "/", or resolves CWD-relative. On success -> run it.
;     3. On ERR_NOTFOUND only: if the name does not already end ".com"
;        (case-insensitive) and we have not retried, append ".com" and
;        try once more. Any other error, or a second not-found, fails.
;     4. Foreground: sys_wait, print "[exit N]\n".
;        Background:  print "[bg N]\n" and return at once.
;
;   Output:   C = 0  child ran; result already reported ([exit N]/[bg N]).
;             C = 1  exec failed; D0 = ERR_*, NOT reported (caller decides).
;
;   Carry note: TRAP_EXEC / TRAP_WAIT use the syscall ABI - C=1 = ERROR -
;   NOT the 6502 SUB/CMP sense. The ERR_NOTFOUND / ".com" tests below are
;   Z-flag compares, not carry tests.
;
;   Clobbers: D0-D3, XY0/XY1. Uses ROW_BUF + RUN_BG (task-local).
; ----------------------------------------------------------------------------
_KoshExecFile:
                ; Stash bg flag - survives TRAP_EXEC D-register clobber.
                MOVE    Y1, Y3
                LOADI   X1, #RUN_BG
                STORED  D3, [XY1]

                ; Part 15: split "prog args" -> nul-terminate the program name
                ; in place, stash the trimmed arg-tail offset in RUN_ARG_PTR
                ; (0 = none). XY0 = caller cmdline (in LINE_BUF; persists to
                ; TRAP_EXEC). Leading spaces skipped, trailing trimmed, interior
                ; preserved. In-place edit is safe: both callers (.do_run /
                ; .unknown) BRA .repl_loop after. XY0 preserved for the copy below.
                LOADI   D0, #0
                MOVE    Y1, Y3
                LOADI   X1, #RUN_ARG_PTR
                STORED  D0, [XY1]                ; default: no args
                LEA     XY1, XY0                 ; XY1 = scan cursor (Y1 = Y3)
.xf_sp_scan:
                LOADB   D0, [XY1]
                AND     D0, #$FF
                CMP     D0, #0
                BEQ     .xf_sp_done              ; no space -> no args
                CMP     D0, #CH_SPACE
                BEQ     .xf_sp_hit
                INC     XY1, #1
                BRA     .xf_sp_scan
.xf_sp_hit:
                LOADI   D0, #0
                STOREB  D0, [XY1]                ; nul the space -> end prog name
                INC     XY1, #1
.xf_sp_skip:
                LOADB   D0, [XY1]                ; skip further leading spaces
                AND     D0, #$FF
                CMP     D0, #CH_SPACE
                BNE     .xf_sp_arg
                INC     XY1, #1
                BRA     .xf_sp_skip
.xf_sp_arg:
                CMP     D0, #0
                BEQ     .xf_sp_done              ; only trailing spaces -> no args
                MOVE    D1, X1                   ; D1 = arg-tail start offset (keep)
.xf_sp_end:
                LOADB   D0, [XY1]                ; walk to the terminating nul
                AND     D0, #$FF
                CMP     D0, #0
                BEQ     .xf_sp_bk
                INC     XY1, #1
                BRA     .xf_sp_end
.xf_sp_bk:
                DEC     XY1, #1                  ; last char of the tail
                MOVE    D0, X1
                CMP     D0, D1                   ; 6502 carry: BLO = X1 < start
                BLO     .xf_sp_put               ; backed past start -> stop
                LOADB   D0, [XY1]
                AND     D0, #$FF
                CMP     D0, #CH_SPACE
                BNE     .xf_sp_put               ; last char not a space -> done
                LOADI   D0, #0
                STOREB  D0, [XY1]                ; strip a trailing space
                BRA     .xf_sp_bk
.xf_sp_put:
                MOVE    D0, D1                   ; D0 = arg-tail start offset
                MOVE    Y1, Y3
                LOADI   X1, #RUN_ARG_PTR
                STORED  D0, [XY1]
.xf_sp_done:

                ; Copy caller name into ROW_BUF. KLIB_STRCPY: XY0=dst, XY1=src.
                LEA     XY1, XY0                 ; src = caller name (set first)
                MOVE    Y0, Y3
                LOADI   X0, #ROW_BUF             ; dst
                CALL24  KLIB_STRCPY

                ; --- kosh script? Route ".ksh" to the runner ---------------
                ; If the name ends ".ksh" (case-folded), open it as a script
                ; rather than exec a .COM. CWD (drive + cluster) is the open
                ; start point (same convention as _KoshCatOne). _KoshRunScript
                ; pushes it; the REPL loop runs it line-by-line. Nothing is
                ; printed on success - it hasn't "exited". (kosh scripts.)
                MOVE    Y0, Y3
                LOADI   X0, #ROW_BUF
                CALL16  _KoshNameIsKsh           ; C=0 -> ends ".ksh"
                BCS     .xf_not_script
                ; --- Part 61: scan the arg tail for -b (brief) ------------
                ; RUN_ARG_PTR was set above (0 = no args) and points into the
                ; caller's LINE_BUF, which is still intact - only the word/arg
                ; boundary space was nulled. D3 carries the result into
                ; _KoshRunScript, which preserves it through to the push.
                ; D3 held the bg flag on entry but that was stashed in RUN_BG,
                ; and the script path RETs without consulting it again.
                LOADI   D3, #0                   ; flags = normal echo
                MOVE    Y1, Y3
                LOADI   X1, #RUN_ARG_PTR
                LOADD   D0, [XY1]
                CMP     D0, #0
                BEQ     .xf_ksh_flags_done       ; no args
                MOVE    Y1, Y3
                MOVE    X1, D0                   ; XY1 = arg tail cursor
.xf_ksh_scan:
                LOADB   D0, [XY1]
                AND     D0, #$FF
                CMP     D0, #0
                BEQ     .xf_ksh_flags_done
                INC     XY1, #1                  ; always advance - no re-read
                CMP     D0, #'-'
                BNE     .xf_ksh_scan
                LOADB   D0, [XY1]                ; char after '-'
                AND     D0, #$FF
                CMP     D0, #'b'
                BEQ     .xf_ksh_brief
                CMP     D0, #'B'
                BNE     .xf_ksh_scan             ; unknown switch - ignore
.xf_ksh_brief:
                LOADI   D3, #SCRIPT_FLAG_BRIEF
.xf_ksh_flags_done:

                MOVE    Y1, Y3
                LOADI   X1, #KOSH_CWD
                LOADB   D2, [XY1]
                SUB     D2, #'A'                 ; D2 = CWD drive index
                LOADI   X1, #KOSH_CWD_CLU
                LOADD   D1, [XY1]                ; D1 = CWD cluster
                MOVE    Y0, Y3
                LOADI   X0, #ROW_BUF             ; XY0 = path
                CALL16  _KoshRunScript           ; C=0 queued / C=1 err (D0)
                RET
.xf_not_script:

                LOADI   D3, #0                   ; D3 = retried? (0 = not yet)

.xf_try:
                ; XY0 = ROW_BUF. Reload CWD each attempt (TRAP clobbers D1/D2).
                MOVE    Y0, Y3
                LOADI   X0, #ROW_BUF
                MOVE    Y1, Y3
                LOADI   X1, #KOSH_CWD
                LOADB   D2, [XY1]                ; CWD drive letter
                SUB     D2, #'A'                 ; -> drive index 0..5
                LOADI   X1, #KOSH_CWD_CLU
                LOADD   D1, [XY1]                ; CWD cluster
                ; flags: a foreground (non-'&') launch sets EXEC_FOREGROUND so
                ; the child auto-foregrounds when it registers as a shell. The
                ; bg flag was stashed in RUN_BG at entry (0=fg, 1=bg).
                MOVE    Y1, Y3
                LOADI   X1, #RUN_BG
                LOADD   D0, [XY1]                ; D0 = bg flag
                CMP     D0, #0
                BNE.S   .xf_flags_bg
                LOADI   D0, #EXEC_FOREGROUND
                BRA.S   .xf_flags_go
.xf_flags_bg:
                LOADI   D0, #0
.xf_flags_go:
                ; Part 15: attach argv tail if present. RUN_ARG_PTR = tail offset in
                ; this page (0 = none). D3 is the live ".com"-retry flag - save it and
                ; borrow it as scratch; D0/D1/D2/XY0 hold sys_exec inputs.
                PUSH    D3, XY3                  ; preserve .com-retry flag
                MOVE    Y1, Y3
                LOADI   X1, #RUN_ARG_PTR
                LOADD   D3, [XY1]                ; D3 = tail offset (0 = none)
                CMP     D3, #0
                BEQ     .xf_no_args
                OR      D0, #EXEC_HAS_ARGS
                MOVE    Y1, Y3
                MOVE    X1, D3                   ; XY1 = Y3:tail (ASCIIZ arg ptr)
.xf_no_args:
                POP     D3, XY3                  ; restore .com-retry flag
                TRAP    #TRAP_EXEC               ; *** C=1 = ERROR (syscall ABI)
                BCC     .xf_ran                  ; C=0 -> launched

                ; exec failed: D0 = ERR_*. Only NOT_FOUND earns a retry.
                CMP     D0, #ERR_NOTFOUND        ; Z-flag test
                BNE     .xf_fail
                CMP     D3, #0                   ; already retried?
                BNE     .xf_fail                 ; yes -> give up (D0=NOTFOUND)

                ; Guard: skip retry if ROW_BUF already ends ".com"
                ; (case-folded via OR #$20 on the three letters).
                MOVE    Y0, Y3
                LOADI   X0, #ROW_BUF
                CALL24  KLIB_STRLEN              ; D0 = length (excl nul)
                CMP     D0, #4
                BLO     .xf_append               ; too short to end ".com"
                SUB     D0, #4
                MOVE    Y1, Y3
                LOADI   X1, #ROW_BUF
                ADD     X1, D0                   ; XY1 -> last 4 bytes
                LOADB   D1, [XY1]
                CMP     D1, #'.'
                BNE     .xf_append
                INC     XY1, #1
                LOADB   D1, [XY1]
                OR      D1, #$20
                CMP     D1, #'c'
                BNE     .xf_append
                INC     XY1, #1
                LOADB   D1, [XY1]
                OR      D1, #$20
                CMP     D1, #'o'
                BNE     .xf_append
                INC     XY1, #1
                LOADB   D1, [XY1]
                OR      D1, #$20
                CMP     D1, #'m'
                BNE     .xf_append
                BRA     .xf_fail                 ; already ".com" & not found

.xf_append:
                ; Append ".com". KLIB_STRCAT: XY0=dst, XY1=src.
                MOVE    Y0, Y3
                LOADI   X0, #ROW_BUF
                MOVE    Y1, Y3
                LOADI   X1, #xf_com_str
                CALL24  KLIB_STRCAT
                LOADI   D3, #1                   ; mark retried
                BRA     .xf_try

.xf_fail:
                SEC                              ; C=1 = failed (D0 = ERR_*)
                RET

.xf_waitfail:
                ; Part 64: NOT .xf_fail. That label is the exec-failure exit,
                ; and both callers answer C=1 with "run: cannot exec" - which
                ; would send anyone debugging this at the path and the loader
                ; instead of the scheduler. The exec succeeded here; the
                ; child ran. Report it ourselves and return C=0, matching the
                ; documented "C=0 -> ran & reported" contract, so the caller
                ; does not print a second, wrong message on top.
                ;
                ; ERR_NOTCHILD / ERR_DEADLOCK should not be reachable - the
                ; TID is the one we just spawned and nobody else can have
                ; waited on it. Kept because an impossible event that
                ; announces itself correctly costs six instructions, and one
                ; that lies costs a session.
                MOVE    Y0, Y3
                LOADI   X0, #msg_run_waiterr
                CALL16  _KoshPrintErr
                CLC
                RET

.xf_detached:
                ; Child registered as a shell and took the foreground; the
                ; kernel woke us early with ERR_DETACHED instead of an exit
                ; code. Not an error and not an exit — return silently. kosh is
                ; now a live background shell (Switch toggles to the child).
                CLC
                RET

.xf_ran:
                ; D0 = child TID. Stash in D2 (safe - no PUSH/POP coming).
                MOVE    D2, D0
                ; Re-read bg flag.
                MOVE    Y1, Y3
                LOADI   X1, #RUN_BG
                LOADD   D3, [XY1]
                CMP     D3, #0
                BNE     .xf_bg_report

                ; --- Foreground: wait for child, print "[exit N]\n" --------
                MOVE    D0, D2                   ; D0 = TID for sys_wait
                TRAP    #TRAP_WAIT               ; *** C=1 = ERROR
                BCC.S   .xf_exited               ; C=0 -> child exited normally
                CMP     D0, #ERR_DETACHED        ; child went interactive?
                BEQ     .xf_detached             ; yes -> silent return to REPL
                BRA     .xf_waitfail             ; genuine wait error
.xf_exited:
                MOVE    D2, D0                   ; D2 = exit code
                MOVE    Y1, Y3
                LOADI   X1, #ROW_BUF
                LOADI   D0, #'['
                CALL16  _KoshEmitByte
                MOVE    Y0, Y3
                LOADI   X0, #msg_run_exit_lbl
                CALL16  _KoshEmitStrZ
                ; A graphics .COM that cannot start exits with the ERR_*
                ; code it received rather than printing - its own console
                ; output would be wiped by the reap repaint (see the note
                ; below).  Render such codes symbolically.  _KoshErrName
                ; returns XY0 pointing at the name (Y0 already = Y3) or
                ; X0 = 0 if the code is not a known error, in which case
                ; it is an ordinary small exit status - print it decimal.
                MOVE    D0, D2
                CALL16  _KoshErrName            ; XY0 -> name, or X0 = 0
                MOVE    D0, X0
                CMP     D0, #0
                BEQ     .xf_exit_dec
                CALL16  _KoshEmitStrZ           ; "[exit ERR_BUSY"
                BRA     .xf_exit_close
.xf_exit_dec:
                MOVE    D0, D2
                CALL16  _KoshEmitDec            ; "[exit 0"
.xf_exit_close:
                LOADI   D0, #']'
                CALL16  _KoshEmitByte
                LOADI   D0, #CH_LF
                CALL16  _KoshEmitByte
                LOADI   D0, #0
                CALL16  _KoshEmitByte
                MOVE    Y0, Y3
                LOADI   X0, #ROW_BUF
                TRAP    #TRAP_PUTS

                ; No per-code hint text here.  kosh cannot know WHY a child
                ; exited ERR_BUSY - it sees a number, not a context - so any
                ; explanation it printed would be a guess that goes stale the
                ; moment a second subsystem exits the same code.  The app
                ; knows, and can say so itself: a failure detected BEFORE it
                ; registers as a shell or acquires video happens while it is
                ; still a plain task, so its output is not repainted away by
                ; _ReapDeadTask.  Same discipline zork uses for its usage
                ; line.  kosh's job is just to render the code.
.xf_exit_done:
                CLC
                RET

.xf_bg_report:
                ; D2 = TID. Print "[bg N]\n".
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
                CLC
                RET

xf_com_str:       .TEXT  ".com",0


; ============================================================================
; End of kosh_helpers.asm
; ============================================================================
