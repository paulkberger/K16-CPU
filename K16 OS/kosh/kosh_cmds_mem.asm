; ============================================================================
; kosh_cmds_mem.asm — kosh memory-inspection commands
; ============================================================================
; Date:    29 May 2026
; Status:  Part 39 - kosh.com migration.
;
; Revision: r2 - 29 May 2026 - Part 39: kosh.com migration. 28 CALL24
;             _Kosh* helper calls converted to CALL16, and 5 string
;             references switched from
;                 #SPAWN_ENTRY_OFFSET + (label - kosh_entry)
;             to bare
;                 #label
;             because kosh.asm now assembles with .ORG $0200 and labels
;             resolve directly to their in-page addresses. No behaviour
;             change. Requires kosh.asm r39+.
;
;           r1 - 7 May 2026 - Phase 16.7 — extracted from kosh.asm during
;             Phase 19 split.
;
;   .INCLUDEd from kosh.asm after kosh_entry: so the strings declared here
;   live inside the kosh.com image. kosh.asm assembles with .ORG $0200, so
;   labels resolve directly to their in-page addresses (no manual rebase).
;
;   Commands (dispatch tags in parens, defined in kosh.asm cmd_table):
;     peek A      (11) - read byte at A=[$]pp:[$]oooo or A=oooo
;     dump A [N]  (12) - hex+ASCII dump (N bytes, default 64, capped $1000)
;
;   Both use buffer-and-blast: build the formatted line in ROW_BUF, then
;   one sys_puts per row. Major speedup on Digital vs per-char TRAPs.
;
;   Helpers used (live in kosh_helpers.asm):
;     _KoshEmitByte / _KoshEmitByteHex / _KoshEmitWordHex / _KoshParseAddr
;
;   Kosh-page scratch consumed:
;     ROW_BUF    96 bytes formatted output buffer
;     DUMP_ROW   16 bytes source-byte snapshot (dump's two-pass row build)
;     DUMP_PAGE  2 bytes (parsed page byte)
;     DUMP_OFFS  2 bytes (current row offset)
;     DUMP_LEN   2 bytes (remaining length)
; ============================================================================


; ----------------------------------------------------------------------------
; .do_peek — read one byte from <page>:<offset> or <offset> (current page).
;
;   Args: "[$]page:[$]offset"  or  "[$]offset"
;   Output: "$pp:oooo  bb  'c'\n"  where bb is hex byte, c is printable
;           ASCII or '.' for non-printable.
;
;   Uses _KoshParseAddr (CALL24) to parse the address. _KoshParseAddr
;   runs from the ROM copy of kosh — that's safe because the helper is
;   pure compute (no kosh-data references) and the ROM image is
;   identical to the RAM copy.
; ----------------------------------------------------------------------------
.do_peek:
                ; Find args via KLIB_STRLEN: XY0 lands at the word's nul.
                LEA     XY0, XY2
                CALL24  KLIB_STRLEN
                INC     XY0, #1                 ; step past nul
                LOADB   D0, [XY0]
                CMP     D0, #0
                BNE.S   .peek_have_args
                ; No args → usage line.
                MOVE    Y0, Y3
                LOADI   X0, #msg_peek_usage
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.peek_have_args:
                ; Parse address. XY0 already = args, set D3 default-page.
                MOVE    D3, Y3
                CALL16  _KoshParseAddr
                BCS     .peek_bad

                ; D0 = page byte, D1 = offset.
                ; Stash page in D2, offset in D3 — we need D0/D1 below.
                MOVE    D2, D0                  ; D2 = page byte
                MOVE    D3, D1                  ; D3 = offset

                ; Read the byte at [D2:D3].
                MOVE    Y0, D2
                MOVE    X0, D3
                LOADB   D0, [XY0]
                ; Save byte in D1 (preserved across all the helper CALL24s).
                MOVE    D1, D0

                ; --- Build line in ROW_BUF, then sys_puts once. -----------
                ; Cursor in XY1 = (Y3:ROW_BUF). Each helper writes and
                ; advances XY1.
                MOVE    Y1, Y3
                LOADI   X1, #ROW_BUF

                LOADI   D0, #'$'
                CALL16  _KoshEmitByte
                MOVE    D0, D2
                CALL16  _KoshEmitByteHex        ; page 2 hex digits
                LOADI   D0, #':'
                CALL16  _KoshEmitByte
                MOVE    D0, D3
                CALL16  _KoshEmitWordHex        ; offset 4 hex digits
                LOADI   D0, #CH_SPACE
                CALL16  _KoshEmitByte
                CALL16  _KoshEmitByte           ; (D0 still SP)
                MOVE    D0, D1
                CALL16  _KoshEmitByteHex        ; byte 2 hex digits
                LOADI   D0, #CH_SPACE
                CALL16  _KoshEmitByte
                CALL16  _KoshEmitByte
                LOADI   D0, #$27                ; '
                CALL16  _KoshEmitByte
                ; Printable check (32..126).
                MOVE    D0, D1
                CMP     D0, #32
                BLO.S   .peek_dot
                CMP     D0, #127
                BHS.S   .peek_dot
                BRA.S   .peek_emit_chr
.peek_dot:
                LOADI   D0, #'.'
.peek_emit_chr:
                CALL16  _KoshEmitByte
                LOADI   D0, #$27
                CALL16  _KoshEmitByte
                LOADI   D0, #CH_LF
                CALL16  _KoshEmitByte
                LOADI   D0, #0                  ; nul terminator
                CALL16  _KoshEmitByte

                ; sys_puts(ROW_BUF)
                MOVE    Y0, Y3
                LOADI   X0, #ROW_BUF
                TRAP    #TRAP_PUTS
                CALL16  _KoshBlankLine
                BRA     .repl_loop

.peek_bad:
                MOVE    Y0, Y3
                LOADI   X0, #msg_peek_usage
                TRAP    #TRAP_PUTS
                BRA     .repl_loop


; ----------------------------------------------------------------------------
; .do_dump — hex+ASCII dump.
;
;   Args: "[$]page:[$]offset [length]"   or   "[$]offset [length]"
;   length is optional, defaults to 64. Always 16 bytes per row.
;
;   Each row:
;     $pp:oooo  bb bb bb bb bb bb bb bb bb bb bb bb bb bb bb bb  cccccccccccccccc
;
;   ASCII column shows printable chars; non-printable rendered as '.'.
; ----------------------------------------------------------------------------
.do_dump:
                ; Find args via KLIB_STRLEN.
                LEA     XY0, XY2
                CALL24  KLIB_STRLEN
                INC     XY0, #1                 ; step past nul
                LOADB   D0, [XY0]
                CMP     D0, #0
                BNE.S   .dump_have_args
                MOVE    Y0, Y3
                LOADI   X0, #msg_dump_usage
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.dump_have_args:
                ; Parse address. XY0 already = args.
                MOVE    D3, Y3
                CALL16  _KoshParseAddr
                BCS     .dump_bad

                ; Stash page in DUMP_PAGE, offset in DUMP_OFFS, length in
                ; DUMP_LEN — kosh-owned scratch slots in our user page.
                STOREP  D0, Y3, [#DUMP_PAGE]    ; page (low byte used)
                STOREP  D1, Y3, [#DUMP_OFFS]    ; offset

                ; XY0 was advanced by _KoshParseAddr. Skip whitespace
                ; and try to parse a length. If nothing there, default 64.
                LEA     XY1, XY0
.dump_skip_ws:
                LOADB   D0, [XY1]
                CMP     D0, #CH_SPACE
                BNE.S   .dump_after_ws
                INC     XY1, #1
                BRA     .dump_skip_ws
.dump_after_ws:
                CMP     D0, #0
                BEQ.S   .dump_default_len
                ; Parse length via KLIB_ATOH (caller can write hex like
                ; "100" for 256 bytes; that's the K16 idiom).
                LEA     XY0, XY1
                CALL24  KLIB_ATOH
                BCS     .dump_default_len
                ; D0 = length. Cap to a sensible max ($1000 = 4KB) so a
                ; typo can't dump forever.
                CMP     D0, #$1000
                BLO.S   .dump_len_ok
                LOADI   D0, #$1000
.dump_len_ok:
                BRA.S   .dump_len_set

.dump_default_len:
                LOADI   D0, #64
.dump_len_set:
                STOREP  D0, Y3, [#DUMP_LEN]

                ; --- Row loop ---------------------------------------------
                ; Each row is built into ROW_BUF, then a single sys_puts
                ; flushes it. This replaces ~80 per-char TRAPs (each one
                ; a TRAP/dispatch round-trip) with one TRAP per row.
                ; Major speed improvement on Digital.
.dump_row:
                LOADP   D0, Y3, [#DUMP_LEN]
                CMP     D0, #0
                BEQ     .dump_done

                ; --- Pass 1: read 16 source bytes into DUMP_ROW. ----------
                ; This snapshots the row so the hex pass and ASCII pass
                ; can read from a stable buffer (and the source bytes
                ; can't change between the two passes if they're MMIO).
                LOADP   D0, Y3, [#DUMP_PAGE]
                MOVE    Y0, D0
                LOADP   D0, Y3, [#DUMP_OFFS]
                MOVE    X0, D0                  ; XY0 = source ptr
                MOVE    Y1, Y3
                LOADI   X1, #DUMP_ROW           ; XY1 = stash buffer
                LOADI   D3, #16
.dump_snap_loop:
                LOADB   D0, [XY0]+
                STOREB  D0, [XY1]+
                SUB     D3, #1
                BNE     .dump_snap_loop

                ; --- Pass 2: build the formatted row in ROW_BUF. ----------
                ; XY1 = cursor; helpers advance it.
                MOVE    Y1, Y3
                LOADI   X1, #ROW_BUF

                ; Address gutter "$pp:oooo  "
                LOADI   D0, #'$'
                CALL16  _KoshEmitByte
                LOADP   D0, Y3, [#DUMP_PAGE]
                LOW     D0
                CALL16  _KoshEmitByteHex
                LOADI   D0, #':'
                CALL16  _KoshEmitByte
                LOADP   D0, Y3, [#DUMP_OFFS]
                CALL16  _KoshEmitWordHex
                LOADI   D0, #CH_SPACE
                CALL16  _KoshEmitByte
                CALL16  _KoshEmitByte

                ; Hex bytes: 16 of them, each followed by a space.
                ; D3 = byte index 0..15.
                LOADI   D3, #0
.dump_hex_loop:
                ; Read DUMP_ROW[D3].
                MOVE    Y0, Y3
                LOADI   X0, #DUMP_ROW
                ADD     X0, D3
                LOADB   D0, [XY0]
                CALL16  _KoshEmitByteHex
                LOADI   D0, #CH_SPACE
                CALL16  _KoshEmitByte
                ADD     D3, #1
                CMP     D3, #16
                BLO     .dump_hex_loop

                ; Extra space before ASCII column.
                LOADI   D0, #CH_SPACE
                CALL16  _KoshEmitByte

                ; ASCII column.
                LOADI   D3, #0
.dump_asc_loop:
                MOVE    Y0, Y3
                LOADI   X0, #DUMP_ROW
                ADD     X0, D3
                LOADB   D0, [XY0]
                CMP     D0, #32
                BLO.S   .dump_asc_dot
                CMP     D0, #127
                BHS.S   .dump_asc_dot
                BRA.S   .dump_asc_emit
.dump_asc_dot:
                LOADI   D0, #'.'
.dump_asc_emit:
                CALL16  _KoshEmitByte
                ADD     D3, #1
                CMP     D3, #16
                BLO     .dump_asc_loop

                ; LF and nul terminator.
                LOADI   D0, #CH_LF
                CALL16  _KoshEmitByte
                LOADI   D0, #0
                CALL16  _KoshEmitByte

                ; Flush: sys_puts(ROW_BUF).
                MOVE    Y0, Y3
                LOADI   X0, #ROW_BUF
                TRAP    #TRAP_PUTS

                ; Advance offset by 16, decrement remaining length by 16.
                LOADP   D0, Y3, [#DUMP_OFFS]
                ADD     D0, #16
                STOREP  D0, Y3, [#DUMP_OFFS]
                LOADP   D0, Y3, [#DUMP_LEN]
                CMP     D0, #16
                BLO.S   .dump_done              ; partial last row already done
                SUB     D0, #16
                STOREP  D0, Y3, [#DUMP_LEN]
                BRA     .dump_row

.dump_done:
                CALL16  _KoshBlankLine
                BRA     .repl_loop

.dump_bad:
                MOVE    Y0, Y3
                LOADI   X0, #msg_dump_usage
                TRAP    #TRAP_PUTS
                BRA     .repl_loop


; ============================================================================
; Mem-command strings (page-local, addressed via Y3 + page-offset).
; ============================================================================

msg_peek_usage: .TEXT  "usage: peek [$]pp:[$]oooo  or  peek [$]oooo\n",0
msg_dump_usage: .TEXT  "usage: dump [$]pp:[$]oooo [length]\n",0

; Command name strings (for cmd_table)
cmd_peek_str:   .TEXT   "peek",0
cmd_dump_str:   .TEXT   "dump",0
