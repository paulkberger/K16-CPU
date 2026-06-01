; ============================================================================
; kosh_helpers.asm - kosh CALL24-callable helper subroutines
; ============================================================================
; Date:    18 May 2026
; Status:  r4 - Part 34 _KoshEmitSize carry-sense fix
; Revision: r4 - 18 May 2026 - Part 34: fix inverted carry test in
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
;   .INCLUDEd from kosh.asm between kosh_entry: and kosh_entry_end: so the
;   helpers sit in the kosh ROM page alongside the command handlers. They
;   are CALL24-callable via absolute ROM addresses.
;
;   These are pure-compute helpers: they don't reference any kosh-local
;   data beyond their inputs. The assembler resolves the absolute address
;   to the ROM copy of these routines, but the ROM copy is identical to
;   the in-RAM copy of kosh, so it doesn't matter which one actually
;   executes. (Same idiom as KLIB_*.)
;
;   Helpers in this file:
;     _KoshEmitByte       - append literal byte at XY1 cursor
;     _KoshEmitByteHex    - append 2 hex digits at XY1 cursor
;     _KoshEmitWordHex    - append 4 hex digits at XY1 cursor
;     _KoshParseAddr      - parse "[$]page:[$]offset" or "[$]offset"
;     _KoshErrName        - err code -> name offset (Part 25 r3)
;     _KoshPrintErr       - emit "prefix [ERR_NAME $HHHH]\n" (Part 25 r3)
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
                STOREB  D0, [XY1]
                INC     XY1, #1
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
                STOREB  D0, [XY1]
                INC     XY1, #1
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
                CALL24  _KoshEmitByteHex        ; emit high byte, advances XY1
                MOVE    D0, D2                  ; restore full word
                CALL24  _KoshEmitByteHex        ; emit low byte, advances XY1
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
                STOREB  D0, [XY1]
                INC     XY1, #1
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
                LOADI   X0, #SPAWN_ENTRY_OFFSET + (err_name_table - kosh_entry)

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
                CALL24  _KoshErrName
                MOVE    D3, X0                  ; D3 = name offset (0 = not found)

                ; Build " [ERR_NAME $HHHH]\n\0" in ROW_BUF.
                MOVE    Y1, Y3
                LOADI   X1, #ROW_BUF

                LOADI   D0, #CH_SPACE
                CALL24  _KoshEmitByte
                LOADI   D0, #'['
                CALL24  _KoshEmitByte

                CMP     D3, #0
                BEQ.S   .pe_unknown
                MOVE    Y0, Y3
                MOVE    X0, D3
                CALL24  _KoshEmitStrZ
                BRA.S   .pe_name_done
.pe_unknown:
                MOVE    Y0, Y3
                LOADI   X0, #SPAWN_ENTRY_OFFSET + (err_name_unk - kosh_entry)
                CALL24  _KoshEmitStrZ
.pe_name_done:

                LOADI   D0, #CH_SPACE
                CALL24  _KoshEmitByte
                LOADI   D0, #'$'
                CALL24  _KoshEmitByte
                MOVE    D0, D2
                CALL24  _KoshEmitWordHex
                LOADI   D0, #']'
                CALL24  _KoshEmitByte
                LOADI   D0, #CH_LF
                CALL24  _KoshEmitByte
                LOADI   D0, #0
                CALL24  _KoshEmitByte

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
                CALL24  _SlotForDrive
                BCC.S   .kpp_cwd_ok             ; mounted - proceed

.kpp_snap_b:
                ; Stale or invalid - reset to 'B'.
                LOADI   D0, #'B'
                MOVE    Y0, Y3
                LOADI   X0, #KOSH_CWD
                STOREB  D0, [XY0]
                ; Fall through.

.kpp_cwd_ok:
                ; --- Build "<CWD>:$ \0" in ROW_BUF -------------------------
                MOVE    Y0, Y3
                LOADI   X0, #KOSH_CWD
                LOADB   D0, [XY0]               ; D0 = CWD letter

                MOVE    Y1, Y3
                LOADI   X1, #ROW_BUF

                STOREB  D0, [XY1]               ; CWD letter
                INC     XY1, #1
                LOADI   D0, #':'
                STOREB  D0, [XY1]
                INC     XY1, #1
                LOADI   D0, #'$'
                STOREB  D0, [XY1]
                INC     XY1, #1
                LOADI   D0, #CH_SPACE
                STOREB  D0, [XY1]
                INC     XY1, #1
                LOADI   D0, #0
                STOREB  D0, [XY1]

                ; --- Emit ---------------------------------------------------
                MOVE    Y0, Y3
                LOADI   X0, #ROW_BUF
                TRAP    #TRAP_PUTS
                RET


; ============================================================================
; _KoshNormPath - normalise a user-supplied path (Part 25 r4)
;
;   Copies the source path to the destination buffer, prepending
;   "<KOSH_CWD>:" if the source has no "X:" prefix.
;
;   "Has prefix" = byte at offset 1 is ':' AND byte at offset 0 is
;   alphabetic. Anything else gets the prepend (including malformed
;   stuff like "::" - the kernel will reject it with ERR_BADPATH later).
;
;   The destination buffer should be >= 16 bytes (max FAT path is
;   "X:NNNNNNNN.EEE\0" = 14 chars). Caller supplies the buffer via XY1.
;
;   In:    XY0 = source nul-terminated path (in kosh task page)
;          XY1 = destination buffer (in kosh task page; >=16 B)
;   Out:   destination contains normalised path (nul-terminated)
;          XY1 unchanged (still points at start of normalised path -
;            ready to pass as the path argument to a TRAP)
;   Clobbers: D0, D1, X0, X1 (actually XY1 preserved; XY0 advanced)
;   Preserves: D2, D3, Y1, XY2, XY3
;
;   This helper does NOT validate the path content. It just ensures
;   the path starts with "X:" so kernel _ParsePath can do its job.
;   Bad paths (too long, bad chars, etc.) get rejected downstream.
;
;   r4 nuance: if the source ALREADY has X: prefix, we still copy it
;   into the destination so the caller can use one consistent pointer.
;   The copy is small (<=14 bytes) - not worth optimising away.
; ----------------------------------------------------------------------------
_KoshNormPath:
                PUSH    XY1, XY3                ; preserve dest base

                ; --- Detect "X:" prefix at source -------------------------
                LOADB   D0, [XY0]               ; first char
                ; Need first char alphabetic (A..Z or a..z); else prepend.
                ; Uppercase A..Z?
                CMP     D0, #'A'
                BLO     .knp_prepend
                CMP     D0, #$5B                ; 'Z'+1
                BLO.S   .knp_alpha_check_colon
                ; Lowercase a..z?
                CMP     D0, #'a'
                BLO     .knp_prepend
                CMP     D0, #$7B                ; 'z'+1
                BHS     .knp_prepend

.knp_alpha_check_colon:
                ; First char alphabetic. Second char must be ':'.
                INC     XY0, #1
                LOADB   D0, [XY0]
                CMP     D0, #':'
                BNE.S   .knp_no_colon

                ; Has "X:" prefix. Back up XY0 one to point at the X again.
                DEC     XY0, #1
                BRA     .knp_copy_loop

.knp_no_colon:
                ; First was alpha but second isn't ':' - bare name like "AB".
                ; Step XY0 back and prepend.
                DEC     XY0, #1
                ; Fall through to .knp_prepend.

.knp_prepend:
                ; XY0 still points at start of source. Emit "<CWD>:" first.
                MOVE    Y0, Y3
                ; Save XY0 source pointer.
                MOVE    D1, X0
                ; Get CWD letter.
                LOADI   X0, #KOSH_CWD
                LOADB   D0, [XY0]               ; D0 = CWD letter

                ; Restore source pointer (Y already = Y3).
                MOVE    X0, D1

                ; Write CWD letter to dest.
                STOREB  D0, [XY1]
                INC     XY1, #1

                ; Write ':' to dest.
                LOADI   D0, #':'
                STOREB  D0, [XY1]
                INC     XY1, #1
                ; Fall through to copy_loop.

.knp_copy_loop:
                LOADB   D0, [XY0]
                STOREB  D0, [XY1]
                CMP     D0, #0
                BEQ.S   .knp_done
                INC     XY0, #1
                INC     XY1, #1
                BRA     .knp_copy_loop

.knp_done:
                POP     XY1, XY3                ; restore dest base
                RET


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
;                       7 covers "999.99MB".
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
;     unit 1 (KB): "<whole>KB"       e.g. "45KB", "979KB"
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

                ; --- If unit >= 2 (MB/GB), emit ".NN" before the suffix ---
                CMP     D2, #2
                BLO     .kes_skip_decimals      ; KB -> skip decimals

                ; Emit '.' then two decimal digits.
                LOADI   D0, #'.'
                STOREB  D0, [XY0]
                INC     XY0, #1

                ; Two digits of hundredths: tens = D1 / 10, ones = D1 mod 10.
                ; Use KLIB_DIV10 (D0 in -> D0 quot, D1 rem). Save D1 (hundredths)
                ; and D2 (unit) across the call.
                PUSH    D2, XY3
                MOVE    D0, D1
                CALL24  KLIB_DIV10              ; D0=tens, D1=ones; clobbers D2,D3
                ; Tens digit.
                ADD     D0, #'0'
                STOREB  D0, [XY0]
                INC     XY0, #1
                ; Ones digit.
                ADD     D1, #'0'
                STOREB  D1, [XY0]
                INC     XY0, #1
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
                STOREB  D0, [XY0]
                INC     XY0, #1
                LOADI   D0, #'B'
                STOREB  D0, [XY0]
                INC     XY0, #1

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
                STOREB  D2, [XY1]
                INC     XY1, #1
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
                LOADB   D2, [XY0]
                STOREB  D2, [XY1]
                INC     XY0, #1
                INC     XY1, #1
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

; ----------------------------------------------------------------------------
; _KoshSplitDrivePat - split "X:pattern" or "pattern" into drive + basename.
;
;   In:   XY0 = arg (ASCIIZ; e.g. "B:*.TXT" or "*.TXT"; task page)
;   Out:  D0  = drive index (0..5); if no "X:" prefix, uses KOSH_CWD
;         XY1 = pointer to the basename pattern (past "X:" if present, else
;               == original XY0). Page = Y3.
;         C = 0  OK
;         C = 1  bad drive letter (out of A..F range)  [D0 undefined]
;   Clobbers: D0, D1
;   Preserves: D2, D3, XY0 (unchanged), XY2, XY3
;
;   "Has prefix" = byte0 alphabetic AND byte1 == ':'. Drive letter folded to
;   upper, validated A..F, converted to index. The drive letter itself must
;   be literal - a wildcard in the drive position is rejected by the A..F
;   range check (since '*'/'?' aren't in A..F).
; ----------------------------------------------------------------------------
_KoshSplitDrivePat:
                MOVE    Y1, Y3
                LEA     XY1, XY0                ; default basename ptr = arg start

                LOADB   D0, [XY0]
                AND     D0, #$FF
                CALL24  _KoshFoldChar           ; fold for the alpha test
                CMP     D0, #'A'
                BLO     .sdp_no_prefix
                CMP     D0, #$5B                ; 'Z'+1
                BHS     .sdp_no_prefix

                ; First char alpha. Check second == ':'.
                MOVE    D1, X0
                INC     D1, #1                  ; offset of 2nd char
                PUSH    XY0, XY3
                MOVE    X0, D1
                MOVE    Y0, Y3
                LOADB   D1, [XY0]
                POP     XY0, XY3
                CMP     D1, #':'
                BNE     .sdp_no_prefix

                ; Has "X:" prefix. D0 still = folded drive letter. Validate A..F.
                CMP     D0, #'A'
                BLO     .sdp_bad
                CMP     D0, #$47                ; 'F'+1
                BHS     .sdp_bad
                SUB     D0, #'A'                ; D0 = drive index
                ; basename ptr = arg + 2.
                LEA     XY1, XY0
                INC     XY1, #2
                CLC
                RET

.sdp_no_prefix:
                ; No "X:" prefix - use CWD drive, basename = whole arg.
                MOVE    Y1, Y3
                LEA     XY1, XY0                ; basename = arg start
                PUSH    XY0, XY3
                MOVE    Y0, Y3
                LOADI   X0, #KOSH_CWD
                LOADB   D0, [XY0]
                POP     XY0, XY3
                AND     D0, #$FF
                SUB     D0, #'A'                ; CWD letter -> index
                CLC
                RET

.sdp_bad:
                SEC
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
;   Each table entry is GLOB_ENTRY_SIZE (14) bytes: up to 13-byte ASCIIZ
;   display name + 1 pad. Names longer than 12 chars can't occur (FAT 8.3),
;   so 13 incl nul is always enough.
;
;   Walk uses sys_dirent with a monotonically increasing index; sys_dirent's
;   internal iteration cache (Part 22) makes each sequential step cheap.
; ----------------------------------------------------------------------------
_KoshGlobExpand:
                ; Stash inputs into scratch state.
                STOREZ  D0, [#GLOB_DRIVE]
                MOVE    D0, X1
                STOREZ  D0, [#GLOB_PATPTR]      ; pattern offset (page = Y3)
                STOREZ  D2, [#GLOB_MAX]
                LOADI   D0, #0
                STOREZ  D0, [#GLOB_INDEX]
                STOREZ  D0, [#GLOB_COUNT]

.ge_loop:
                ; sys_dirent(drive, index, buf=GLOB_DIRENT_BUF).
                LOADZ   D0, [#GLOB_DRIVE]
                LOADZ   D1, [#GLOB_INDEX]
                MOVE    Y0, Y3
                LOADI   X0, #GLOB_DIRENT_BUF
                TRAP    #TRAP_DIRENT
                BCS     .ge_done                ; end of directory (or error)

                ; Match display name (buf+0, ASCIIZ) against pattern.
                ; _KoshFnMatch(XY0=pattern, XY1=name).
                LOADZ   D0, [#GLOB_PATPTR]
                MOVE    Y0, Y3
                MOVE    X0, D0                  ; XY0 = pattern
                MOVE    Y1, Y3
                LOADI   X1, #GLOB_DIRENT_BUF    ; XY1 = name (display name @ +0)
                CALL24  _KoshFnMatch
                BCS     .ge_next                ; no match - skip

                ; Match. Check capacity.
                LOADZ   D0, [#GLOB_COUNT]
                LOADZ   D1, [#GLOB_MAX]
                CMP     D0, D1
                BHS     .ge_full                ; count >= max -> truncated

                ; Copy display name into table[count].
                ; dest = GLOB_TABLE + count*GLOB_ENTRY_SIZE.
                ; count*14 = count*8 + count*4 + count*2.
                MOVE    D2, D0                  ; D2 = count
                SHL     D0                      ; *2
                MOVE    D3, D0                  ; D3 = count*2
                SHL     D0                      ; *4
                ADD     D3, D0                  ; D3 = count*2 + count*4 = count*6
                SHL     D0                      ; *8
                ADD     D3, D0                  ; D3 = count*6 + count*8 = count*14
                LOADZ   D0, [#GLOB_TABLE]
                ADD     D3, D0                  ; D3 = dest offset
                ; Source = GLOB_DIRENT_BUF (name), copy up to 13 bytes incl nul.
                ; Stop at nul OR space: a display name never legitimately
                ; contains a space, and stopping at one strips any trailing
                ; pad space (which _ParsePath would otherwise reject as an
                ; illegal filename char -> ERR_BADPATH).
                MOVE    Y0, Y3
                LOADI   X0, #GLOB_DIRENT_BUF
                MOVE    Y1, Y3
                MOVE    X1, D3                  ; XY1 = dest
                LOADI   D2, #13                 ; max bytes to copy
.ge_copy:
                LOADB   D0, [XY0]
                CMP     D0, #0
                BEQ.S   .ge_terminate           ; nul -> terminate
                CMP     D0, #CH_SPACE
                BEQ.S   .ge_terminate           ; space -> terminate (strip)
                STOREB  D0, [XY1]
                INC     XY0, #1
                INC     XY1, #1
                SUB     D2, #1
                BNE     .ge_copy
.ge_terminate:
                LOADI   D0, #0
                STOREB  D0, [XY1]               ; write terminator
.ge_copied:
                ; count++.
                LOADZ   D0, [#GLOB_COUNT]
                ADD     D0, #1
                STOREZ  D0, [#GLOB_COUNT]

.ge_next:
                LOADZ   D0, [#GLOB_INDEX]
                ADD     D0, #1
                STOREZ  D0, [#GLOB_INDEX]
                BRA     .ge_loop

.ge_done:
                LOADZ   D0, [#GLOB_COUNT]
                CLC
                RET

.ge_full:
                ; Table full. Return count = max, C=1 (truncated).
                LOADZ   D0, [#GLOB_MAX]
                SEC
                RET

; ============================================================================
; _KoshExpandBareDst - if the dst path is a bare drive ("X:"), append the
;                      src basename so "mv A:FORTH30.COM B:" / "cp ... B:"
;                      becomes "...B:FORTH30.COM".
;
;   Part 37 (28 May 2026): literal cp/mv with a bare-drive destination used
;   to pass "B:" straight to TRAP_RENAME / TRAP_OPEN, which _ParsePath
;   rejected as ERR_BADPATH (empty filename). The glob path already builds
;   "<dstdrive>:<name>" per match; this brings the LITERAL path to parity.
;
;   In:    CP_SRC_PATH_TMP = ptr to normalised src "X:NAME" (in task page)
;          CP_DST_PATH_TMP = ptr to normalised dst (in task page)
;   Out:   If dst was bare "X:" (alpha, ':', NUL), dst buffer now holds
;          "<dstdrive>:<src-basename>"; CP_DST_PATH_TMP unchanged (same buf).
;          If dst was not bare, nothing changes.
;          C = 0 always.
;   Clobbers: D0, D1, X0, X1, Y0, Y1, flags
;   Preserves: D2, D3, XY2, XY3
;
;   "Bare" test: byte0 alphabetic AND byte1 == ':' AND byte2 == NUL.
;   The src is guaranteed to carry an "X:" prefix here (callers run
;   _KoshNormPath first), so the basename is simply src+2.
; ----------------------------------------------------------------------------
_KoshExpandBareDst:
                ; --- Is dst exactly "X:" ? --------------------------------
                MOVE    Y1, Y3
                LOADZ   D0, [#CP_DST_PATH_TMP]
                MOVE    X1, D0                   ; XY1 = dst base

                LOADB   D0, [XY1]                ; byte0
                ; alphabetic?
                CMP     D0, #'A'
                BLO     .ebd_done
                CMP     D0, #$5B                 ; 'Z'+1
                BLO.S   .ebd_b0_ok
                CMP     D0, #'a'
                BLO     .ebd_done
                CMP     D0, #$7B                 ; 'z'+1
                BHS     .ebd_done
.ebd_b0_ok:
                INC     XY1, #1
                LOADB   D0, [XY1]                ; byte1
                CMP     D0, #':'
                BNE     .ebd_done
                INC     XY1, #1
                LOADB   D0, [XY1]                ; byte2 - must be NUL for "bare"
                CMP     D0, #0
                BNE     .ebd_done                ; dst already has a filename

                ; --- Bare drive. XY1 points at dst[2] (the NUL). Append
                ;     the src basename (src + 2, past its "X:") here. -------
                MOVE    Y0, Y3
                LOADZ   D0, [#CP_SRC_PATH_TMP]
                ADD     D0, #2                   ; skip src "X:" prefix
                MOVE    X0, D0                   ; XY0 = src basename
.ebd_copy:
                LOADB   D0, [XY0]
                STOREB  D0, [XY1]
                CMP     D0, #0
                BEQ.S   .ebd_done
                INC     XY0, #1
                INC     XY1, #1
                BRA     .ebd_copy

.ebd_done:
                CLC
                RET

; ============================================================================
; End of kosh_helpers.asm
; ============================================================================
