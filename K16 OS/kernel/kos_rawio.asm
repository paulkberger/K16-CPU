; ============================================================================
; kos_rawio.asm — k/OS kernel raw terminal output
; ============================================================================
; Date:    4 May 2026
; Status:  Phase 1 implementation; renamed Phase 3 Part 6
; Revision: r8 - 14 May 2026 — Absorbed _RawPutDec and _RawPutHexByte
;             verbatim from the deleted kos_splash.asm. The boot splash
;             itself moved to kosh (see kosh_splash.asm); kos_boot now
;             emits only "Booting k/OS..." via _RawPuts. These two
;             helpers stay in the kernel as boot/ISR-safe diagnostic
;             primitives (no TRAP recursion, no DINT requirement).
;             Dependency note: _RawPutDec calls _KDiv10 (KLIB slot 01)
;             and uses scratch buffer at PUTDEC_BUF/PUTDEC_BUF_END.
;
;           r7 - 4 May 2026 — Branch .S polish.
;             1 unsuffixed branches converted to .S form
;             where target distance is ≤10 instructions.
;             FORWARD ONLY (assembler imm5 is unsigned 0..+31).
;             Per
;             K16 Manual Amendment 2026-05-04 E.5/E.6, default
;             auto-select picks long form; explicit .S saves
;             one word per branch. Saves 1 words.
;
; Revision: r6 - 4 May 2026 — _RawPuts source-ptr setup uses LEA Mode 00
;             (1 instr) instead of MOVE X1,X0 / MOVE Y1,Y0 pair (2
;             instr). Validated by test_lea_mode00_v2.asm (T1 + T2 PASS).
;
;           r5 - 4 May 2026 — header note only (LEA attempt reverted).
;
;           r4 - 2 May 2026 — renamed from kos_kprintf.asm. The original
;             name suggested formatted printf-style output but the file
;             only contains raw byte/string writers (_RawPuts, _RawPutByte).
;             A real kprintf with %d/%x/%s would warrant a separate file
;             with its own name; that's deferred until Phase 4+ if needed.
;           r3 - 30 April 2026 — initial.
; Purpose: Direct-write helpers for kernel terminal output. These do NOT
;          go through the TRAP path — they're for use during boot (before
;          the vector table is trusted) and from inside ISRs/handlers
;          that must not recurse into syscalls.
;
;          Ships _RawPuts, _RawPutByte, _RawPutDec, _RawPutHexByte. A
;          formatted output helper (with %d, %x, %s) is a Phase 4+
;          addition when richer kernel diagnostics become useful; that
;          should live in a separate file (kos_kprintf.asm) at that point.
;
; Note: included from kos_boot.asm; constants come from kos_defs.inc.
; ============================================================================

; ============================================================================
; _RawPuts — write zstring to terminal without TRAP
;   Input:   XY0 = pointer to zstring (24-bit)
;   Output:  D0 = byte count written
;   Clobbers: D0, XY0
;   Preserves: D1, D2, D3, XY1, XY2, XY3
;
;   Used by:
;     - boot banner (vectors not yet installed when first called)
;     - any ISR or handler that needs to debug-print
;     - bootstrap test programs that bypass TRAP
; ============================================================================
_RawPuts:
                PUSH    D1, XY3
                PUSH    XY1, XY3

                LEA     XY1, XY0            ; XY1 = source ptr
                LOADI   D1, #0              ; D1 = count

                LOADI   Y0, #TERMINAL_PAGE
                LOADI   X0, #$0000          ; XY0 = terminal
.loop:
                LOADB   D0, [XY1]+
                CMP     D0, #0
                BEQ.S     .done
                STOREB  D0, [XY0]
                ADD     D1, #1
                BRA     .loop
.done:
                MOVE    D0, D1
                POP     XY1, XY3
                POP     D1, XY3
                RET

; ============================================================================
; _RawPutByte — write a single character to terminal without TRAP
;   Input:   D0 = character (low byte)
;   Output:  none
;   Clobbers: XY0 only (D0 preserved)
; ============================================================================
_RawPutByte:
                LOADI   Y0, #TERMINAL_PAGE
                LOADI   X0, #$0000
                STOREB  D0, [XY0]
                RET

; ============================================================================
; _RawPutDec — write D0 (0..65535) as unsigned decimal, no leading zeros
;
; Boot-time helper, no DINT (we're pre-task). Uses div-by-repeated-subtraction.
; Clobbers: D0, D1, D2, XY0, flags
; ============================================================================
_RawPutDec:
                PUSH    D1, XY3
                PUSH    D2, XY3

                MOVE    D1, D0                  ; D1 = working value
                LOADI   D2, #0                  ; D2 = digit count

                LOADI   Y0, #$00
                LOADI   X0, #PUTDEC_BUF_END     ; build digits backward

                CMP     D1, #0
                BNE.S     .div_loop

                ; Special case: D0 was 0
                DEC     XY0, #1
                LOADI   D0, #'0'
                STOREB  D0, [XY0]
                ADD     D2, #1
                BRA     .emit

.div_loop:
                CMP     D1, #0
                BEQ     .emit

                ; D0 = D1 / 10, D1 = D1 mod 10 (after call: D0 quot, D1 rem)
                ; Stash D2 (count) and XY0 (buf ptr) — _KDiv10 trashes D2/D3.
                MOVE    D0, D1
                PUSH    D2, XY3
                PUSH    XY0, XY3
                CALL24  _KDiv10
                POP     XY0, XY3
                POP     D2, XY3
                ; D1 = remainder, D0 = quotient
                ADD     D1, #'0'
                DEC     XY0, #1
                STOREB  D1, [XY0]
                ADD     D2, #1
                MOVE    D1, D0                  ; quotient -> next iter
                BRA     .div_loop

.emit:
                ; XY0 -> first digit, D2 = count
                LEA     XY1, XY0
                LOADI   Y0, #TERMINAL_PAGE
                LOADI   X0, #$0000
.emit_loop:
                CMP     D2, #0
                BEQ.S     .emit_done
                LOADB   D0, [XY1]+
                STOREB  D0, [XY0]
                SUB     D2, #1
                BRA     .emit_loop
.emit_done:

                POP     D2, XY3
                POP     D1, XY3
                RET

; ============================================================================
; _RawPutHexByte — emit low byte of D0 as 2 hex digits, no prefix
;
; Boot-time helper, no DINT. Inlines digit emission twice (no recursion).
; Clobbers: D0, D1, D2, XY0, flags
; ============================================================================
_RawPutHexByte:
                PUSH    D1, XY3
                PUSH    D2, XY3

                MOVE    D2, D0                  ; D2 = byte to emit

                ; --- High nibble ------------------------------------------
                MOVE    D1, D2
                SHR     D1, #4
                AND     D1, #$000F
                CMP     D1, #10
                BLO.S     .hi_digit
                ADD     D1, #$37                ; 'A' - 10 (literal — assembler doesn't eval expr)
                BRA.S     .hi_emit
.hi_digit:
                ADD     D1, #'0'
.hi_emit:
                LOADI   Y0, #TERMINAL_PAGE
                LOADI   X0, #$0000
                STOREB  D1, [XY0]

                ; --- Low nibble -------------------------------------------
                MOVE    D1, D2
                AND     D1, #$000F
                CMP     D1, #10
                BLO.S     .lo_digit
                ADD     D1, #$37
                BRA.S     .lo_emit
.lo_digit:
                ADD     D1, #'0'
.lo_emit:
                LOADI   Y0, #TERMINAL_PAGE
                LOADI   X0, #$0000
                STOREB  D1, [XY0]

                POP     D2, XY3
                POP     D1, XY3
                RET

; ============================================================================
; End of kos_rawio.asm
; ============================================================================
