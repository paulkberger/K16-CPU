; ============================================================================
; kos_klib_impl.asm — k/OS KLIB implementations
; ============================================================================
; Date:    29 May 2026
; Status:  KLIB v1.1 — sync rev bump (no impl changes)
; Revision: r11 - 29 May 2026 — Part 39 (kosh.com migration). No
;             implementation body changes in this file. Slots 06 and
;             07 promoted from RESERVED to LIVE in kos_klib_template
;             r8; both target symbols (_TryMount, _SlotForDrive) live
;             in kfs/kos_fs.asm — already implemented, no new code.
;             This rev marker just tracks the KLIB v1.1 ABI change
;             alongside kos_klib.inc r8 and kos_klib_template r8.
;
; Revision: r10 - 18 May 2026 — Added _KBytesSplit (slot 46). Pure math
;             primitive: takes a 32-bit byte count and returns
;             (whole, hundredths, unit) where unit ∈ {0=B, 1=KB, 2=MB,
;             3=GB}. Cascade of ÷1024 via _KDivmod32 chooses the unit;
;             frac = (sub_unit_remainder × 100) / 1024 gives two-decimal
;             precision. Cost: 1 divmod for KB output, 2 for MB, 3 for GB,
;             plus one for the frac calc (and one mul). All sub-millisecond.
;             Driven by Part 34 disk-free reporting; reusable for any
;             "human-readable size" presentation.
;
; Revision: r9 - 13 May 2026 — Added _KDivmod32 (slot 04) and _KUtoa32
;             (slot 45). _KDivmod32: unsigned 32/16 → 32 quotient + 16
;             remainder, shift-subtract over 32-iteration loop, divisor
;             and counter on stack to free a D-register for R. 33-bit
;             shift via ADD/ADC chain (SHL/ROL don't propagate carry on
;             K16). _KUtoa32: uint32 → decimal at XY0, cursor-style
;             matching KLIB_UTOA's convention. Recursive divide-by-10
;             via _KDivmod32; max recursion depth 10 for "4294967295".
;             Driven by k/OS Phase B's promotion of TCB_PREEMPT_COUNT
;             to 32-bit (~4 years at 30Hz before wrap).
;             Promotes slots 04 and 45 from stub/reserved to LIVE.
;
; Revision: r8 - 12 May 2026 — Added _KDivmod16 (slot 02) and _KUDivmod16
;             (slot 03). Adapted from K16 BASIC v2.2's divide_16 + umod_16,
;             with KLIB-compliant error handling: divisor=0 returns SEC +
;             D0=ERR_INVALID rather than calling a host-specific error
;             handler. Standard shift-subtract algorithm, ~200-250 cycles
;             worst case vs ~6500 for repeated-subtraction.
;             Sign convention: quotient = sign(dividend) XOR sign(divisor);
;             remainder = sign(dividend). C99 truncated-division semantics.
;             Preserves D2/D3/XY2 per KLIB ABI.
;             Promotes slots 02 and 03 from stub to LIVE. Required by
;             K16 BASIC port (BASIC_COM_port_spec_v2.md). Also useful for
;             kosh and future Forth port.
;
; Revision: r7 - 7 May 2026 — Conversion functions (KLIB_UTOA, KLIB_ITOA,
;             KLIB_ITOH) made cursor-style + nul-terminating. The new
;             contract:
;               - XY0 is advanced past the digits (was: preserved).
;               - A nul terminator is written at the advanced XY0 (i.e.
;                 [XY0] = 0). XY0 itself is NOT advanced past the nul.
;               - D0 = digit count, NOT counting the nul.
;
;             This is a "best-of-both" API:
;               - Cursor-chain users (kosh buffer-and-blast) read the
;                 advanced XY0 and continue emitting; the next byte
;                 written overwrites the harmless nul. No extra work.
;               - String-result users save XY0 before calling; the saved
;                 ptr addresses a valid nul-terminated string of length
;                 D0. No extra work.
;
;             The previous contract was "buffer + nul + XY0 unchanged".
;             No callers of the old form existed in the codebase, so
;             this is a clean spec change rather than a breaking change.
;
;             Implementation simplifications:
;               - _KUtoa: drops the PUSH XY1 / PUSH XY0 saves; uses XY0
;                 directly as the cursor. Writes nul at end before
;                 return (XY0 not bumped past nul).
;               - _KItoh: same; _KItoh_Nibble now writes [XY0] not [XY1].
;                 Nul write at end matches.
;               - _KItoa: drops the "save and restore original XY0"
;                 dance. Writes '-' (if any) and INC XY0; calls
;                 cursor-style _KUtoa which both advances XY0 and writes
;                 the nul. Total count = sign byte + UTOA's digit count.
;
;             KLIB_Reference bumped to v1.1 with new spec.
;
;           r6 - 5 May 2026 — _KDelayMs now checks KERNEL_STATE first
;             (must be KERN_STATE_RUN), then IE bit. The KERNEL_STATE
;             check is the principled answer to "is the scheduler live
;             enough to safely deliver timer IRQs"; the IE check
;             remains as a secondary safeguard for atomic-section
;             callers. Together they cleanly cover boot-time and
;             interrupt-masked failure modes.
;
;           r5 - 5 May 2026 — refactor: _KAtoi and _KAtoh now share a
;             single parser body (_KAtoi_Common). Previously two
;             near-identical copies (~80 lines duplicated). The two
;             public entries are now thin stubs that load the default
;             base in D3, then dispatch to the common body. _KAtoi
;             does explicit BRA; _KAtoh falls through directly. The
;             '$' prefix logic is unified — for _KAtoh it's a harmless
;             redundant assignment, for _KAtoi it switches base 10→16.
;             Net 107 lines removed. Behaviour unchanged: re-runs the
;             full Phase 12 ATOI tests (T8-T11, T20) and Phase 13 ATOH
;             tests (T4-T7) of the smoke suite.
;
;           r4 - 5 May 2026 — Tier 4 added.
;             - KLIB_STRCAT  (slot 35) — _KStrCat
;             - KLIB_ATOH    (slot 44) — _KAtoh
;             - KLIB_RAND16  (slot 48) — _KRand16
;             - KLIB_SRAND   (slot 49) — _KSRand
;             - KLIB_DELAY_MS (slot 51) — _KDelayMs
;             20/64 LIVE.
;             ATOH and ATOI now share _KAtoi_Base parser.
;             RAND16/SRAND state at $00:$9FFE, initialised by _InitKLib.
;
;           r3 - 5 May 2026 — Tier 2+3 entries:
;             KLIB_STRCPY (33), KLIB_STRCMP (34), KLIB_STRCHR (36),
;             KLIB_MEMCMP (39), KLIB_ITOA (40), KLIB_UTOA (41),
;             KLIB_ITOH (42), KLIB_ATOI (43). 15/64 LIVE.
;             ITOA/UTOA/ITOH adapted from BASIC int_to_str / int_to_hex.
;             ATOI adapted from Forth parse_number.
;             STRCMP adapted from BASIC str_compare.
;
;           r3.1 fix - 5 May 2026 — _KAtoi PUSH/POP D3 across
;             _KMul16x16_32 (which trashes D2/D3). Without this fix,
;             multi-digit parses returned garbage on the second iteration.
;
;           r2 - 5 May 2026 — Tier 1 entries added:
;             KLIB_STRLEN (32), KLIB_MEMCPY (37), KLIB_MEMSET (38),
;             KLIB_TICKS (50).
;
;           r1 - 5 May 2026 — initial. Math helpers moved out of
;             kos_console.asm.
;
;   See klib/kos_klib_design_v3.md for the full slot map and stability
;   rules.
; ============================================================================

; ============================================================================
; _KMul16x16_32 — unsigned 16×16 → 32-bit multiply (KLIB slot 00)
; ============================================================================
;   Input:  D0, D1 = 16-bit unsigned multiplicands
;   Output: D0 = lo16, D1 = hi16
;   Trashes: D2, D3
;
;   Method: byte-wise partial products via MULB lookup.
;     lo16 = PP0 + (middle_lo << 8)
;     hi16 = PP3 + middle_hi + carry-from-middle + carry-from-lo
;   where:
;     PP0 = n1L * n2L  PP1 = n1H * n2L
;     PP2 = n1L * n2H  PP3 = n1H * n2H
;     middle = PP1 + PP2
;
;   Adapted from Forth v2.24 mul_16x16_32. Uses CALL24 ABI (no Forth NEXT).
;
;   NOTE: callee-pushed scratch — uses ADD X3,#8 / RET, NOT RET #4w.
;   See K16_Manual_Amendment_2026-05-04.md G.2.
; ============================================================================
_KMul16x16_32:
                ; Extract bytes
                MOVE    D2, D0
                HIGH    D2                  ; D2 = n1H
                LOW     D0                  ; D0 = n1L
                MOVE    D3, D1
                HIGH    D3                  ; D3 = n2H
                LOW     D1                  ; D1 = n2L

                ; Stash all 4 byte operands
                PUSH    D3, XY3             ; [SP+6] = n2H
                PUSH    D2, XY3             ; [SP+4] = n1H
                PUSH    D1, XY3             ; [SP+2] = n2L
                PUSH    D0, XY3             ; [SP+0] = n1L

                ; PP0 = n1L * n2L (D0=n1L, D1=n2L still valid)
                SWAPB   D1
                OR      D0, D1
                MULB    D0                  ; D0 = PP0
                PUSH    D0, XY3             ; [SP+0] = PP0
                ; Stack: PP0=0, n1L=2, n2L=4, n1H=6, n2H=8

                ; PP1 = n1H * n2L
                LOADD   D0, [XY3+#6]        ; n1H
                LOADD   D1, [XY3+#4]        ; n2L
                SWAPB   D1
                OR      D0, D1
                MULB    D0                  ; D0 = PP1
                MOVE    D2, D0              ; D2 = PP1

                ; PP2 = n1L * n2H
                LOADD   D0, [XY3+#2]        ; n1L
                LOADD   D1, [XY3+#8]        ; n2H
                SWAPB   D1
                OR      D0, D1
                MULB    D0                  ; D0 = PP2

                ; middle = PP1 + PP2
                ADD     D0, D2              ; D0 = middle
                SCS     D1                  ; D1 = carry (0 or $FFFF)
                AND     D1, #1              ; D1 = middle_carry
                MOVE    D2, D0              ; D2 = middle

                ; PP3 = n1H * n2H
                LOADD   D0, [XY3+#6]        ; n1H
                LOADD   D3, [XY3+#8]        ; n2H
                SWAPB   D3
                OR      D0, D3
                MULB    D0                  ; D0 = PP3

                ; Combine: D0=PP3, D1=middle_carry, D2=middle
                ; Split middle into hi/lo bytes
                MOVE    D3, D2
                LOW     D3                  ; D3 = middle_lo
                HIGH    D2                  ; D2 = middle_hi

                ; hi16 = PP3 + middle_hi + (middle_carry << 8)
                ADD     D0, D2
                SWAPB   D1
                ADD     D0, D1              ; D0 = partial hi16
                MOVE    D1, D0              ; D1 = hi16 (save)

                ; lo16 = PP0 + (middle_lo << 8)
                SWAPB   D3
                POP     D0, XY3             ; D0 = PP0
                ADD     D0, D3              ; D0 = lo16
                SCS     D2                  ; D2 = lo_carry
                AND     D2, #1
                ADD     D1, D2              ; hi16 += lo_carry

                ; D0 = lo16, D1 = hi16
                ; Drop the 4 stashed byte operands (8 bytes)
                ADD     X3, #8
                RET

; ============================================================================
; _KDiv10 — divide D0 by 10 using reciprocal multiply (KLIB slot 01)
; ============================================================================
;   Input:  D0 = dividend (0..65535)
;   Output: D0 = quotient, D1 = remainder
;   Trashes: D2, D3
;
;   Method: q = hi16(n × 52429) >> 3; r = n - q × 10
;     (52429 = $CCCD, the standard reciprocal-of-10 magic for 16-bit / Q16.16.)
;
;   Worst-case ~80 cycles vs ~6500 cycles for repeated-subtraction at n=65535.
;   ~80× speedup.
;
;   Adapted from Forth v2.24 div10.
; ============================================================================
_KDiv10:
                PUSH    D0, XY3             ; save n
                LOADI   D1, #52429          ; magic = $CCCD
                CALL24  _KMul16x16_32       ; D0=lo16, D1=hi16

                ; quotient = hi16 >> 3
                MOVE    D0, D1
                SHR     D0
                SHR     D0
                SHR     D0                  ; D0 = quotient

                ; remainder = n - quotient * 10
                ; q*10 = q*8 + q*2 = (q<<3) + (q<<1)
                MOVE    D2, D0              ; D2 = quotient (save)
                MOVE    D1, D0
                SHL     D1                  ; D1 = q*2
                SHL     D0
                SHL     D0
                SHL     D0                  ; D0 = q*8
                ADD     D0, D1              ; D0 = q*10

                POP     D1, XY3             ; D1 = original n
                SUB     D1, D0              ; D1 = remainder
                MOVE    D0, D2              ; D0 = quotient
                RET

; ============================================================================
; _KStrLen — count bytes in nul-terminated string (KLIB slot 32)
; ============================================================================
;   Input:    XY0 = pointer to nul-terminated string
;   Output:   D0  = byte count (excluding nul)
;   Flags:    C = 0
;   Clobbers: D0, XY0
;
;   Walks XY0 forward incrementing a counter until it hits a $00 byte.
;   Returns 0 for empty string. The nul itself is not counted.
;
;   Adapted from Forth v2.24 print_string (line 2892), with the STOREB
;   replaced by counter increment.
; ============================================================================
_KStrLen:
                PUSH    D1, XY3

                LOADI   D1, #0              ; D1 = count
.loop:
                LOADB   D0, [XY0]
                CMP     D0, #0
                BEQ.S   .done
                ADD     D1, #1
                INC     XY0, #1
                BRA     .loop
.done:
                MOVE    D0, D1              ; return count in D0
                CLC
                POP     D1, XY3
                RET

; ============================================================================
; _KMemCpy — copy D0 bytes from XY1 to XY0 (KLIB slot 37)
; ============================================================================
;   Input:    XY0 = destination (24-bit)
;             XY1 = source      (24-bit)
;             D0  = byte count
;   Output:   D0  unchanged (the count, for chaining)
;             XY0 advanced past last destination byte
;             XY1 advanced past last source byte
;   Flags:    C = 0
;   Clobbers: D1, XY0, XY1 advanced
;   Preserves: D0, D2, D3, XY2, XY3
;
;   No overlap detection — caller's responsibility. For overlapping
;   regions where dst > src, walk backwards (a future _KMemMove might
;   handle this).
;
;   Adapted from Forth v2.24 CMOVE_WORD (line 2021). Forth pulls args
;   from the data stack via XY2; KLIB takes them in registers and uses
;   24-bit XY pointers natively (no per-byte get_page indirection).
; ============================================================================
_KMemCpy:
                PUSH    D0, XY3             ; save count for return
                PUSH    D1, XY3

                CMP     D0, #0
                BEQ.S   .done

                MOVE    D1, D0              ; D1 = working count
.loop:
                LOADB   D0, [XY1]
                STOREB  D0, [XY0]
                INC     XY0, #1
                INC     XY1, #1
                DEC     D1, #1
                BNE     .loop
.done:
                CLC
                POP     D1, XY3
                POP     D0, XY3             ; restore original count
                RET

; ============================================================================
; _KMemSet — fill D0 bytes at XY0 with value D1 (KLIB slot 38)
; ============================================================================
;   Input:    XY0 = destination (24-bit)
;             D0  = byte count
;             D1  = byte value (low 8 bits used)
;   Output:   D0  unchanged (the count)
;             XY0 advanced past last byte
;   Flags:    C = 0
;   Clobbers: XY0 advanced
;   Preserves: D1, D2, D3, XY1, XY2, XY3
;
;   D0=0 is a no-op (immediate return).
;
;   Adapted from Forth v2.24 FILL_WORD (line 2004).
; ============================================================================
_KMemSet:
                PUSH    D0, XY3             ; save count for return
                PUSH    D2, XY3

                CMP     D0, #0
                BEQ.S   .done

                MOVE    D2, D0              ; D2 = working count
.loop:
                STOREB  D1, [XY0]
                INC     XY0, #1
                DEC     D2, #1
                BNE     .loop
.done:
                CLC
                POP     D2, XY3
                POP     D0, XY3             ; restore original count
                RET

; ============================================================================
; _KTicks — return current SYS_TICKS counter (KLIB slot 50)
; ============================================================================
;   Input:    none
;   Output:   D0 = SYS_TICKS (16-bit, wraps every ~36 minutes at 30Hz)
;   Flags:    C = 0
;   Clobbers: D0 only
;
;   Reads $00:SYS_TICKS via LOADZ (zero-page load). The ticks counter
;   is incremented by _TimerIRQ at 30Hz and wraps naturally at $FFFF.
;
;   No DINT envelope — single LOADZ is atomic (one bus cycle), and a
;   timer IRQ between LOADZ and RET would just increment SYS_TICKS
;   after we've sampled it; the caller sees a slightly stale value
;   which is no different to any other point in time.
; ============================================================================
_KTicks:
                LOADZ   D0, [#SYS_TICKS]
                RETCC

; ============================================================================
; ============================================================================
; TIER 2 — number formatting
; ============================================================================
; ============================================================================

; ============================================================================
; _KItoh — int16 to ASCII hex (KLIB slot 42) — CURSOR-STYLE
; ============================================================================
;   Input:    D0  = 16-bit value (interpreted bitwise)
;             XY0 = cursor (where to write)
;   Output:   D0  = 4 (digits written; not counting the nul)
;             XY0 = ADVANCED past the 4 hex digits, pointing AT the nul
;             buffer contains 4 hex digits + nul terminator at [XY0]
;   Flags:    C = 0
;   Clobbers: D1, D2, D3 (XY0 modified by design)
;
;   Best-of-both API:
;     - Cursor chain users: continue emitting at advanced XY0; the next
;       byte you write overwrites the nul. No extra work needed.
;     - String result users: save XY0 before the call; afterwards XY0
;       points at the nul, [saved_XY0] is a valid nul-terminated string,
;       D0 = digit count.
;
;   Made cursor-style 7 May 2026 — see KLIB Reference v1.1.
; ============================================================================
_KItoh:
                PUSH    D123, XY3

                MOVE    D2, D0                  ; D2 = original value (preserved)

                ; Digit 0 (bits 15:12)
                MOVE    D1, D2
                HIGH    D1                      ; D1 = bits 15:8
                SHR4    D1                      ; D1 = bits 15:12 in low nibble
                AND     D1, #$0F
                CALL24  _KItoh_Nibble

                ; Digit 1 (bits 11:8)
                MOVE    D1, D2
                HIGH    D1                      ; D1 = bits 15:8
                AND     D1, #$0F                ; D1 = bits 11:8
                CALL24  _KItoh_Nibble

                ; Digit 2 (bits 7:4)
                MOVE    D1, D2
                LOW     D1                      ; D1 = bits 7:0
                SHR4    D1
                AND     D1, #$0F
                CALL24  _KItoh_Nibble

                ; Digit 3 (bits 3:0)
                MOVE    D1, D2
                AND     D1, #$0F
                CALL24  _KItoh_Nibble

                ; Write nul at advanced cursor (XY0 NOT advanced past it).
                LOADI   D1, #0
                STOREB  D1, [XY0]

                LOADI   D0, #4                  ; bytes written (digits only)
                CLC
                POP     D123, XY3
                RET

; Helper: emit nibble (low 4 bits of D1) as ASCII at [XY0], advance XY0.
; (Was previously [XY1]; XY1 has been retired in favour of cursor-style XY0.)
_KItoh_Nibble:
                CMP     D1, #10
                BLO.S   .digit
                ADD     D1, #$37                ; 'A'-10
                BRA.S   .emit
.digit:
                ADD     D1, #$30                ; '0'
.emit:
                STOREB  D1, [XY0]
                INC     XY0, #1
                RET

; ============================================================================
; _KUtoa — uint16 to ASCII decimal (KLIB slot 41) — CURSOR-STYLE
; ============================================================================
;   Input:    D0  = unsigned value (0..65535)
;             XY0 = cursor (where to write)
;   Output:   D0  = digits written (1..5; not counting the nul)
;             XY0 = ADVANCED past the digits, pointing AT the nul
;             buffer contains decimal digits + nul terminator at [XY0]
;   Flags:    C = 0
;   Clobbers: D1, D2, D3 (XY0 modified by design)
;
;   Best-of-both API:
;     - Cursor chain users: continue emitting at advanced XY0; the next
;       byte you write overwrites the nul. No extra work needed.
;     - String result users: save XY0 before the call; afterwards XY0
;       points at the nul, [saved_XY0] is a valid nul-terminated string,
;       D0 = digit count.
;
;   Method: recursive divide-by-10 — call stack handles digit reversal
;   naturally. The recursion advances XY0 as digits are written.
;
;   Adapted from BASIC v2.2 int_to_str (line 3544).
;   Made cursor-style 7 May 2026 — see KLIB Reference v1.1.
; ============================================================================
_KUtoa:
                PUSH    D123, XY3

                CALL24  _KUtoa_Recur            ; → D2 = digit count, XY0 advanced

                ; Write nul at advanced cursor (XY0 NOT advanced past it).
                LOADI   D1, #0
                STOREB  D1, [XY0]

                MOVE    D0, D2                  ; D0 = digit count
                CLC
                POP     D123, XY3
                RET

; Recursive helper. In: D0 = value; XY0 = cursor.
; Out: D2 = digits written; XY0 advanced past them.
; Side effect: writes ASCII digits to [XY0].
_KUtoa_Recur:
                CMP     D0, #10
                BLO.S   .single                 ; 0..9 → emit and return

                CALL24  _KDiv10                 ; D0=quot, D1=rem
                PUSH    D1, XY3                 ; save our digit
                CALL24  _KUtoa_Recur            ; recurse (writes higher digits, sets D2)
                POP     D1, XY3                 ; restore our digit

                ADD     D1, #$30
                STOREB  D1, [XY0]
                INC     XY0, #1
                ADD     D2, #1
                RET

.single:
                ADD     D0, #$30
                STOREB  D0, [XY0]
                INC     XY0, #1
                LOADI   D2, #1
                RET

; ============================================================================
; _KItoa — int16 to ASCII decimal, signed (KLIB slot 40) — CURSOR-STYLE
; ============================================================================
;   Input:    D0  = signed value (-32768..32767)
;             XY0 = cursor (where to write)
;   Output:   D0  = bytes written (1..6; not counting the nul)
;             XY0 = ADVANCED past optional '-' + digits, pointing AT the nul
;             buffer contains optional '-' + decimal digits + nul terminator
;   Flags:    C = 0
;   Clobbers: D1, D2, D3 (XY0 modified by design)
;
;   Best-of-both API: see _KUtoa. The nul is written by the inner
;   _KUtoa call at the final advanced cursor.
;
;   Method: if negative, write '-' at cursor and INC XY0; negate value;
;   call cursor-style _KUtoa for the magnitude (which advances XY0
;   further and writes the nul). Total written = sign byte (0 or 1) +
;   UTOA's digit count.
;
;   Made cursor-style 7 May 2026 — see KLIB Reference v1.1.
; ============================================================================
_KItoa:
                PUSH    D1, XY3
                PUSH    D2, XY3

                LOADI   D2, #0                  ; D2 = sign byte count (0 or 1)

                CMP     D0, #0
                BGE.S   .non_negative

                ; Negative: write '-' and advance XY0
                LOADI   D1, #$2D                ; '-'
                STOREB  D1, [XY0]
                INC     XY0, #1
                LOADI   D2, #1                  ; one sign byte

                ; Negate D0
                NOT     D0
                ADD     D0, #1

.non_negative:
                ; D0 = magnitude, XY0 = cursor (past '-' if any).
                ; Save D2 across UTOA (which clobbers D1/D2/D3).
                PUSH    D2, XY3
                CALL24  _KUtoa                  ; advances XY0, returns D0 = digit count
                POP     D2, XY3

                ; Total = sign bytes + digit bytes. XY0 already correctly advanced.
                ADD     D0, D2

                CLC
                POP     D2, XY3
                POP     D1, XY3
                RET

; ============================================================================
; _KAtoi — ASCII to int16, signed; supports $-prefix hex (KLIB slot 43)
; _KAtoh — ASCII hex to int16, signed (KLIB slot 44)
; ============================================================================
;   _KAtoi:
;     Input:    XY0 = pointer to nul-terminated source string
;     Format:   [-] [$] digits
;               default base 10; '$' switches to base 16
;     Output:   D0  = parsed value (signed 16-bit)
;               D1  = bytes consumed (0 if parse failed)
;               C   = 0 OK (D0 valid), C = 1 if no digits parsed
;
;   _KAtoh:
;     Input:    XY0 = pointer to nul-terminated source string
;     Format:   [-] [$] hex-digits
;               base is always 16; leading '$' is accepted but optional
;     Output:   same as _KAtoi
;
;   Both routines share a common parser body (_KAtoi_Common). The two
;   public entry points differ only in their default base. _KAtoi
;   defaults to 10 and switches to 16 on '$'. _KAtoh starts in 16 and
;   leaves base unchanged on '$' (the prefix is silently consumed).
;
;   Sign tracked on stack so it survives the digit loop's register reuse.
;
;   Adapted from Forth v2.24 parse_number (line 3272). Forth version
;   takes ptr+len; KLIB version uses nul-terminated convention.
;
;   Refactored 5 May 2026 — previously two near-identical copies of the
;   parser body. Now one body, two thin entry stubs.
; ============================================================================
_KAtoi:
                LOADI   D3, #10                 ; default base = decimal
                BRA     _KAtoi_Common

_KAtoh:
                LOADI   D3, #16                 ; forced base = hex
                ; fall through to common body

_KAtoi_Common:
                PUSH    D2, XY3
                PUSH    D3, XY3
                PUSH    XY1, XY3

                LEA     XY1, XY0                ; XY1 = original ptr

                ; Optional leading '-'
                LOADI   D2, #0                  ; sign flag
                LOADB   D0, [XY0]
                CMP     D0, #$2D
                BNE.S   .ai_chk_dollar
                LOADI   D2, #1
                INC     XY0, #1

.ai_chk_dollar:
                PUSH    D2, XY3                 ; persist sign flag

                ; Optional leading '$' — switches base to 16. (For _KAtoh,
                ; D3 is already 16; the assignment is a harmless no-op.)
                LOADB   D0, [XY0]
                CMP     D0, #$24
                BNE.S   .ai_acc_init
                LOADI   D3, #16
                INC     XY0, #1

.ai_acc_init:
                LOADI   D0, #0                  ; accumulator
                LOADI   D2, #0                  ; digits-seen flag

.ai_acc_loop:
                LOADB   D1, [XY0]

                CMP     D1, #0
                BEQ     .ai_acc_done

                ; 0..9 ?
                CMP     D1, #$30
                BLO     .ai_acc_done
                CMP     D1, #$3A
                BHS.S   .ai_try_alpha
                SUB     D1, #$30
                BRA     .ai_digit_ok

.ai_try_alpha:
                ; Alpha hex digits valid only in base 16
                CMP     D3, #16
                BNE     .ai_acc_done

                CMP     D1, #$41                ; 'A'
                BLO     .ai_acc_done
                CMP     D1, #$47                ; 'F'+1
                BHS.S   .ai_try_lower
                SUB     D1, #$37                ; 'A'-10
                BRA     .ai_digit_ok

.ai_try_lower:
                CMP     D1, #$61                ; 'a'
                BLO     .ai_acc_done
                CMP     D1, #$67                ; 'f'+1
                BHS     .ai_acc_done
                SUB     D1, #$57                ; 'a'-10

.ai_digit_ok:
                ; D0 = D0 * base + D1
                ; _KMul16x16_32 trashes D2 AND D3; save D3 (base) across.
                ; D2 (digits-seen) is rewritten below regardless, no save.
                PUSH    D3, XY3                 ; save base
                PUSH    D1, XY3                 ; save digit
                MOVE    D1, D3                  ; D1 = base
                CALL24  _KMul16x16_32           ; D0 = lo16(D0 * base)
                POP     D1, XY3                 ; restore digit
                POP     D3, XY3                 ; restore base
                ADD     D0, D1
                LOADI   D2, #1                  ; mark digits seen
                INC     XY0, #1
                BRA     .ai_acc_loop

.ai_acc_done:
                ; D0 = magnitude, D2 = digits-seen flag
                POP     D3, XY3                 ; D3 = sign flag (0=pos, 1=neg)

                CMP     D2, #0
                BEQ.S   .ai_no_digits

                ; Apply sign
                CMP     D3, #0
                BEQ.S   .ai_compute
                NOT     D0
                ADD     D0, #1                  ; negate

.ai_compute:
                ; D1 = bytes consumed = current X0 - original X1
                ; (within same page assumption — strings are page-local)
                MOVE    D1, X0
                SUB     D1, X1
                CLC
                POP     XY1, XY3
                POP     D3, XY3
                POP     D2, XY3
                RET

.ai_no_digits:
                LOADI   D1, #0
                SEC
                POP     XY1, XY3
                POP     D3, XY3
                POP     D2, XY3
                RET

; ============================================================================
; ============================================================================
; TIER 3 — string manipulation
; ============================================================================
; ============================================================================

; ============================================================================
; _KStrCpy — copy nul-terminated string from XY1 to XY0 (KLIB slot 33)
; ============================================================================
;   Input:    XY0 = destination buffer (must be ≥ strlen(src)+1)
;             XY1 = source string (nul-terminated)
;   Output:   D0  = bytes copied (including the nul)
;             XY0 = unchanged (points to start of dest)
;             XY1 = unchanged (points to start of src)
;   Flags:    C = 0
;   Clobbers: D1, XY0/XY1 internal scratch (restored)
; ============================================================================
_KStrCpy:
                PUSH    D1, XY3
                PUSH    XY0, XY3                ; preserve dest ptr
                PUSH    XY1, XY3                ; preserve src ptr

                LOADI   D0, #0                  ; D0 = byte count

.loop:
                LOADB   D1, [XY1]
                STOREB  D1, [XY0]
                ADD     D0, #1
                INC     XY0, #1
                INC     XY1, #1
                CMP     D1, #0
                BNE     .loop

                CLC
                POP     XY1, XY3                ; restore
                POP     XY0, XY3
                POP     D1, XY3
                RET

; ============================================================================
; _KStrCmp — lexicographic compare of two nul-terminated strings (slot 34)
; ============================================================================
;   Input:    XY0 = first string
;             XY1 = second string
;   Output:   D0  = -1 / 0 / +1  (signed)
;                   -1 if XY0 < XY1
;                    0 if equal
;                   +1 if XY0 > XY1
;   Flags:    Z = 1 if equal, else Z = 0
;             C reflects unsigned comparison of the differing byte
;   Clobbers: D1, D2, XY0/XY1 internal scratch (restored)
;
;   Compares byte-by-byte. If a difference is found, returns ordering
;   based on that byte. If one string ends (nul) before the other,
;   the shorter string sorts before.
;
;   Adapted from BASIC v2.2 str_compare (line 3685), refactored from
;   length-prefixed strings to nul-terminated.
; ============================================================================
_KStrCmp:
                PUSH    D1, XY3
                PUSH    D2, XY3
                PUSH    XY0, XY3
                PUSH    XY1, XY3

.loop:
                LOADB   D1, [XY0]
                LOADB   D2, [XY1]

                CMP     D1, D2
                BNE.S   .differ

                ; Bytes equal — but if both are nul, strings are equal
                CMP     D1, #0
                BEQ.S   .equal

                INC     XY0, #1
                INC     XY1, #1
                BRA     .loop

.differ:
                ; D1 < D2 → return -1, D1 > D2 → return +1
                BLO.S   .lt
                LOADI   D0, #1
                BRA.S   .done
.lt:
                LOADI   D0, #$FFFF              ; -1 in two's complement
                BRA.S   .done

.equal:
                LOADI   D0, #0

.done:
                ; Set Z flag for caller convenience: CMP D0,#0 leaves
                ; Z=1 iff D0=0. C reflects last byte comparison.
                ; Re-do CMP D0,#0 to ensure Z is right (BRA above
                ; doesn't set flags but earlier ops may have).
                CMP     D0, #0
                POP     XY1, XY3
                POP     XY0, XY3
                POP     D2, XY3
                POP     D1, XY3
                RET

; ============================================================================
; _KStrChr — find first occurrence of byte in nul-terminated string (slot 36)
; ============================================================================
;   Input:    XY0 = string to search
;             D0  = byte to find (low 8 bits)
;   Output:   if found: XY0 = pointer to first occurrence, D0 = position
;                       index, C = 0
;             if not found: XY0 advanced to nul position, D0 = $FFFF, C = 1
;   Clobbers: D1
;
;   Walks XY0 until it finds the target byte or hits nul. The
;   target byte itself can be nul ($00) — in that case the pointer
;   to the terminating nul is returned with C=0.
; ============================================================================
_KStrChr:
                PUSH    D1, XY3
                PUSH    XY1, XY3

                LEA     XY1, XY0                ; XY1 = original ptr (for index calc)

.loop:
                LOADB   D1, [XY0]
                CMP     D1, D0
                BEQ.S   .found

                CMP     D1, #0
                BEQ.S   .not_found

                INC     XY0, #1
                BRA     .loop

.found:
                ; D0 = current X0 - original X1 (position index)
                MOVE    D0, X0
                SUB     D0, X1
                CLC
                POP     XY1, XY3
                POP     D1, XY3
                RET

.not_found:
                LOADI   D0, #$FFFF
                SEC
                POP     XY1, XY3
                POP     D1, XY3
                RET

; ============================================================================
; _KMemCmp — compare D0 bytes at XY0 and XY1 (KLIB slot 39)
; ============================================================================
;   Input:    XY0 = first buffer
;             XY1 = second buffer
;             D0  = byte count
;   Output:   D0  = -1 / 0 / +1
;             Z = 1 if equal, else Z = 0
;   Clobbers: D1, D2, D3, XY0/XY1 advanced
;
;   D0 = 0 returns equal (D0 = 0, Z = 1) immediately.
; ============================================================================
_KMemCmp:
                PUSH    D123, XY3

                CMP     D0, #0
                BEQ     .equal_zero_count

                MOVE    D3, D0                  ; D3 = remaining count

.loop:
                LOADB   D1, [XY0]
                LOADB   D2, [XY1]
                CMP     D1, D2
                BNE.S   .differ

                INC     XY0, #1
                INC     XY1, #1
                DEC     D3, #1
                BNE     .loop

                ; All bytes equal
                LOADI   D0, #0
                BRA.S   .done

.differ:
                BLO.S   .lt
                LOADI   D0, #1
                BRA.S   .done
.lt:
                LOADI   D0, #$FFFF              ; -1
                BRA.S   .done

.equal_zero_count:
                LOADI   D0, #0

.done:
                CMP     D0, #0                  ; set Z for caller
                POP     D123, XY3
                RET

; ============================================================================
; ============================================================================
; TIER 4 — string append, hex parse, PRNG, delay
; ============================================================================
; ============================================================================

; ============================================================================
; _KStrCat — append nul-terminated string XY1 to nul-terminated XY0 (slot 35)
; ============================================================================
;   Input:    XY0 = destination string (already nul-terminated; must have
;                   room for at least strlen(src)+1 more bytes after nul)
;             XY1 = source string (nul-terminated)
;   Output:   D0  = total length of resulting dst (excluding final nul)
;             XY0 = unchanged (still points to start of dst)
;             XY1 = unchanged (still points to start of src)
;   Flags:    C = 0
;   Clobbers: D1, D2 internally
;
;   Implementation: walk dst forward to find its nul, then copy src
;   bytes (including nul) starting at that point. Counters track total
;   bytes for return value.
; ============================================================================
_KStrCat:
                PUSH    D1, XY3
                PUSH    D2, XY3
                PUSH    XY0, XY3                ; preserve dst start
                PUSH    XY1, XY3                ; preserve src start

                LOADI   D2, #0                  ; D2 = total length

                ; Walk dst forward to its nul
.find_end:
                LOADB   D1, [XY0]
                CMP     D1, #0
                BEQ.S   .copy_src
                INC     XY0, #1
                ADD     D2, #1
                BRA     .find_end

.copy_src:
                ; XY0 now points at dst's nul terminator. Overwrite it
                ; (and advance) with bytes from src, including src's nul.
                LOADB   D1, [XY1]
                STOREB  D1, [XY0]
                INC     XY0, #1
                INC     XY1, #1
                CMP     D1, #0
                BEQ.S   .done                   ; we just copied the nul
                ADD     D2, #1                  ; count this byte (not the nul)
                BRA     .copy_src

.done:
                MOVE    D0, D2                  ; D0 = total length excl nul
                CLC
                POP     XY1, XY3
                POP     XY0, XY3
                POP     D2, XY3
                POP     D1, XY3
                RET

; ============================================================================
; _KRand16 — pseudo-random 16-bit value (KLIB slot 48)
; ============================================================================
;   Input:    none
;   Output:   D0 = next pseudo-random word (never zero)
;             C  = 0
;   Clobbers: D0 only
;
;   Algorithm: Marsaglia xorshift-16. Period 65535 (visits every non-
;   zero 16-bit value exactly once). Does not produce zero. Seed must
;   never be zero (xorshift can't escape it); if user calls SRAND with
;   D0=0, SRAND substitutes $0001.
;
;     x ^= x << 7
;     x ^= x >> 9
;     x ^= x << 8
;
;   Implementation uses the SHL/SHR Dn, #imm pseudos for the shift
;   chains; the << 8 step uses LOW + SWAPB (single instruction) since
;   its high-byte-zero precondition is established by the LOW.
; ============================================================================
_KRand16:
                PUSH    D1, XY3

                ; Load current seed from $00:$9FFE
                LOADZ   D0, [#KLIB_SEED]

                ; x ^= x << 7
                MOVE    D1, D0
                SHL     D1, #7
                XOR     D0, D1

                ; x ^= x >> 9
                MOVE    D1, D0
                SHR     D1, #9
                XOR     D0, D1

                ; x ^= x << 8
                ; Efficient: LOW (mask high byte) then SWAPB (move low→high)
                ; gives the same result as 8 successive SHLs.
                MOVE    D1, D0
                LOW     D1                      ; D1 = original low byte (high byte zero)
                SWAPB   D1                      ; D1 = (D0 & $FF) << 8
                XOR     D0, D1

                ; Store new seed and return it
                STOREZ  D0, [#KLIB_SEED]

                CLC
                POP     D1, XY3
                RET

; ============================================================================
; _KSRand — seed the PRNG (KLIB slot 49)
; ============================================================================
;   Input:    D0 = seed
;             (if D0 = 0, uses $0001 instead — xorshift cannot escape 0)
;   Output:   none meaningful; C = 0
;   Clobbers: nothing else
; ============================================================================
_KSRand:
                CMP     D0, #0
                BNE.S   .s_ok
                LOADI   D0, #1                  ; force non-zero seed
.s_ok:
                STOREZ  D0, [#KLIB_SEED]
                RETCC

; ============================================================================
; _KDelayMs — busy-wait delay (KLIB slot 51)
; ============================================================================
;   Input:    D0 = approximate milliseconds (0..65535)
;   Output:   on success: C = 0
;             on failure: C = 1, D0 = ERR_INVALID
;   Clobbers: D0, D1, D2
;
;   Polls SYS_TICKS until the requested number of milliseconds has
;   elapsed. Tick rate is 30Hz, so 1 tick ≈ 33.33ms.
;   ticks_to_wait = D0 / 32  (>> 5 approximation; slightly long, ~3% over).
;
;   Failure conditions (return C=1 / D0=ERR_INVALID):
;     1. KERNEL_STATE != KERN_STATE_RUN — scheduler isn't live yet
;        (kernel is still in boot / pre-_IdleLoop). Timer IRQs cannot
;        safely return to the caller; the routine refuses cleanly.
;     2. IE bit (SR.7) is clear — caller has masked interrupts. Even
;        with the scheduler running, ticks won't advance until IE=1.
;        Common in atomic kernel sections; the caller must EINT and
;        retry, or use a different sleep mechanism.
;
;   Tasks should prefer sys_sleep (TRAP) for accuracy and to avoid
;   busy-waiting; this routine is for non-task code or quick spins
;   where sys_sleep isn't available or worth the overhead.
; ============================================================================
_KDelayMs:
                PUSH    D1, XY3
                PUSH    D2, XY3

                ; Check 1: KERNEL_STATE must be RUN. The scheduler must
                ; be live — otherwise a timer IRQ would corrupt our
                ; bare-kernel context and never return.
                LOADZ   D1, [#KERNEL_STATE]
                CMP     D1, #KERN_STATE_RUN
                BNE     .d_invalid

                ; Check 2: IE must be set. Otherwise SYS_TICKS won't
                ; advance during our poll loop.
                MOVE    D1, SR
                AND     D1, #$0080
                BEQ     .d_invalid

                CMP     D0, #0
                BEQ     .d_done

                ; Compute ticks = D0 >> 5 (approx /32)
                SHR     D0, #5
                ; If result is 0 but original D0 > 0, force 1 tick
                CMP     D0, #0
                BNE.S   .d_have_count
                LOADI   D0, #1

.d_have_count:
                ; D0 = ticks remaining
                LOADZ   D1, [#SYS_TICKS]        ; D1 = start tick

.d_loop:
                LOADZ   D2, [#SYS_TICKS]        ; D2 = current tick
                SUB     D2, D1                  ; D2 = elapsed
                CMP     D2, D0                  ; elapsed vs target
                BHS.S   .d_done                 ; elapsed >= target → done
                BRA     .d_loop

.d_done:
                CLC
                POP     D2, XY3
                POP     D1, XY3
                RET

.d_invalid:
                LOADI   D0, #ERR_INVALID
                SEC
                POP     D2, XY3
                POP     D1, XY3
                RET

; ============================================================================
; _KDivmod16 — signed 16/16 → quotient, remainder (KLIB slot 02)
; ============================================================================
;   Input:  D0 = dividend (signed 16-bit, -32768..32767)
;           D1 = divisor  (signed 16-bit, -32768..32767)
;   Output: D0 = quotient, D1 = remainder
;           C  = 0 success, 1 error (divisor=0; D0 = ERR_INVALID)
;   Preserves: D2, D3, XY2 (KLIB ABI)
;
;   Algorithm: standard shift-subtract restoring division. Take absolute
;   values, run unsigned division, then negate quotient/remainder
;   according to operand signs.
;
;   Sign conventions (matching C99 truncated division):
;     quotient sign  = sign(dividend) XOR sign(divisor)
;     remainder sign = sign(dividend)
;
;   The most-negative case ($8000) cannot be negated to a positive 16-bit
;   value. To keep the routine simple, we accept that $8000 / 1 produces
;   $8000 (correct), $8000 / -1 produces $8000 (overflow, returned silently),
;   and $8000 in unsigned-stage works because the loop is mod-2^16.
;
;   Adapted from K16 BASIC v2.2's divide_16 + umod_16, with KLIB-compliant
;   error handling (SEC + ERR_INVALID on divisor=0).
;
;   Worst case ~250 cycles vs ~6500 cycles for repeated-subtraction.
; ============================================================================
_KDivmod16:
                PUSH    D2, XY3                     ; KLIB ABI: preserve D2
                PUSH    D3, XY3                     ; preserve D3

                ; -- Divisor zero check --------------------------------------
                CMP     D1, #0
                BEQ     .km_divzero

                ; -- Stash sign info in D3 -----------------------------------
                ; Bit 0 = quotient sign (XOR of operand signs)
                ; Bit 1 = remainder sign (= sign of dividend)
                LOADI   D3, #0

                ; Dividend sign
                CMP     D0, #0
                BGE.S   .km_pos_n
                LOADI   D2, #0
                SUB     D2, D0
                MOVE    D0, D2                      ; D0 = |dividend|
                XOR     D3, #1                      ; flip quot sign
                OR      D3, #2                      ; set rem sign
.km_pos_n:
                ; Divisor sign
                CMP     D1, #0
                BGE.S   .km_pos_d
                LOADI   D2, #0
                SUB     D2, D1
                MOVE    D1, D2                      ; D1 = |divisor|
                XOR     D3, #1                      ; flip quot sign
.km_pos_d:
                ; -- Unsigned 16/16 shift-subtract -----------------------------
                ; D0 = quotient (initially = numerator; bits OR'd in)
                ; D1 = divisor (unsigned)
                ; D2 = remainder accumulator
                LOADI   D2, #0
                PUSH    D3, XY3                     ; stash sign info
                LOADI   D3, #16                     ; bit counter
.km_loop:
                ADD     D0, D0                      ; shift dividend left, MSB → C
                ADC     D2, D2                      ; shift carry into remainder
                CMP     D2, D1
                BCC.S   .km_no
                SUB     D2, D1
                OR      D0, #1                      ; quotient bit
.km_no:
                SUB     D3, #1
                BNE     .km_loop

                POP     D3, XY3                     ; restore sign info
                MOVE    D1, D2                      ; D1 = unsigned remainder

                ; -- Apply quotient sign -------------------------------------
                MOVE    D2, D3
                AND     D2, #1
                BEQ.S   .km_qpos
                LOADI   D2, #0
                SUB     D2, D0
                MOVE    D0, D2
.km_qpos:
                ; -- Apply remainder sign ------------------------------------
                MOVE    D2, D3
                AND     D2, #2
                BEQ.S   .km_done
                LOADI   D2, #0
                SUB     D2, D1
                MOVE    D1, D2
.km_done:
                CLC
                POP     D3, XY3
                POP     D2, XY3
                RET

.km_divzero:
                LOADI   D0, #ERR_INVALID
                SEC
                POP     D3, XY3
                POP     D2, XY3
                RET

; ============================================================================
; _KUDivmod16 — unsigned 16/16 → quotient, remainder (KLIB slot 03)
; ============================================================================
;   Input:  D0 = dividend (unsigned 16-bit, 0..65535)
;           D1 = divisor  (unsigned 16-bit, 0..65535)
;   Output: D0 = quotient, D1 = remainder
;           C  = 0 success, 1 error (divisor=0; D0 = ERR_INVALID)
;   Preserves: D2, D3, XY2 (KLIB ABI)
;
;   Same algorithm as _KDivmod16 but without sign handling. Faster.
;   ~200 cycles worst case.
; ============================================================================
_KUDivmod16:
                ; -- Divisor zero check --------------------------------------
                CMP     D1, #0
                BEQ     .ku_divzero

                PUSH    D2, XY3
                PUSH    D3, XY3

                ; -- Unsigned 16/16 shift-subtract -----------------------------
                ; D0 = quotient (initially = numerator)
                ; D1 = divisor
                ; D2 = remainder accumulator
                LOADI   D2, #0
                LOADI   D3, #16
.ku_loop:
                ADD     D0, D0                      ; shift dividend left, MSB → C
                ADC     D2, D2                      ; shift carry into remainder
                CMP     D2, D1
                BCC.S   .ku_no
                SUB     D2, D1
                OR      D0, #1                      ; quotient bit
.ku_no:
                SUB     D3, #1
                BNE     .ku_loop

                MOVE    D1, D2                      ; D1 = remainder

                CLC
                POP     D3, XY3
                POP     D2, XY3
                RET

.ku_divzero:
                LOADI   D0, #ERR_INVALID
                RETCS

; ============================================================================
; _KDivmod32 — unsigned 32 / 16 → 32 quotient + 16 remainder (KLIB slot 04)
; ============================================================================
;   Input:    D1:D0   = 32-bit unsigned dividend (D1 = high word, D0 = low)
;             D2      = 16-bit unsigned divisor
;   Output:   D1:D0   = 32-bit unsigned quotient
;             D2      = 16-bit unsigned remainder (always < divisor)
;             C = 0   on success
;             C = 1   D0 = ERR_INVALID if divisor was 0
;   Clobbers: D0, D1, D2, D3
;   Preserves: XY0, XY1, XY2, XY3 (apart from XY3 stack motion)
;
;   Algorithm: 32-iteration shift-subtract on the 33-bit register
;       (R : HI : LO)
;   In each iteration: left-shift the whole 33-bit register by 1, then
;   if R >= divisor subtract and set the freshly-vacated low bit of LO
;   as a quotient bit. Dividend shifts out the top of HI; quotient bits
;   shift into the bottom of LO. Net effect: D1:D0 is rewritten in place
;   to the quotient.
;
;   Register pressure: 4 D-registers (LO, HI, R, scratch) plus the
;   divisor and counter. The divisor and counter live on the stack
;   so D3 can be the scratch (used to reload either of them each pass).
;
;   Note on shifts: K16's SHL/ROL are LOOKUP-based and don't set carry.
;   Multi-word left-shift must use ADD/ADC chains, which DO propagate
;   carry (Reference Manual §6.3 vs §6.5).
;
;   Stack frame across the inner loop (XY3 = sp, grows down):
;     [XY3+#0] = bit counter (32 → 0)
;     [XY3+#2] = divisor (constant)
;     [XY3+#4] = caller's saved D3
; ============================================================================
_KDivmod32:
                CMP     D2, #0
                BEQ     .kd32_divzero

                PUSH    D3, XY3                     ; save caller's D3
                ; Now push divisor then counter. After both pushes,
                ; [XY3+#0]=counter, [XY3+#2]=divisor, [XY3+#4]=saved D3.
                PUSH    D2, XY3                     ; stack divisor
                LOADI   D3, #32
                PUSH    D3, XY3                     ; stack counter

                ; D2 = R = 0.
                LOADI   D2, #0

.kd32_loop:
                ; (R:HI:LO) <<= 1
                ADD     D0, D0                      ; LO<<=1, C = old hi(LO)
                ADC     D1, D1                      ; HI = HI<<1 | C
                ADC     D2, D2                      ; R  = R<<1  | C

                ; Trial subtract: D3 = divisor from stack.
                LOADD   D3, [XY3+#2]
                CMP     D2, D3
                BLO.S   .kd32_no
                SUB     D2, D3
                OR      D0, #1                      ; quotient bit
.kd32_no:
                ; Decrement counter (in stack slot 0).
                LOADD   D3, [XY3+#0]
                SUB     D3, #1
                STORED  D3, [XY3+#0]
                BNE     .kd32_loop

                ; Done. Pop counter (discard) and divisor.
                POP     D3, XY3                     ; counter (==0)
                POP     D3, XY3                     ; divisor (discard; clobbered)
                POP     D3, XY3                     ; restore caller's D3

                RETCC

.kd32_divzero:
                LOADI   D0, #ERR_INVALID
                RETCS


; ============================================================================
; _KUtoa32 — uint32 to ASCII decimal, cursor-style (KLIB slot 45)
; ============================================================================
;   Input:    D1:D0   = 32-bit unsigned value (D1 = high word, D0 = low)
;             XY0     = cursor (where to write)
;   Output:   D0      = digit count written (1..10, NOT counting the nul)
;             XY0     = ADVANCED past digits, pointing AT the nul
;             C = 0
;   Clobbers: D1, D2, D3 (XY0 modified by design)
;   Preserves: XY1, XY2, XY3
;   Buffer:   needs at least 11 bytes ("4294967295\0")
;
;   Same best-of-both contract as _KUtoa: cursor advanced, nul written
;   at the final position. Caller can either save the start (LEA XY2,XY0
;   before the call) or treat the original cursor as a normal nul-
;   terminated C string after the call.
;
;   Method: recursive divide-by-10 using _KDivmod32. The recursion
;   writes digits in correct (most-significant-first) order via natural
;   unwinding. Max recursion depth = 10 (for "4294967295").
; ============================================================================
_KUtoa32:
                PUSH    D123, XY3                   ; preserve high word for caller

                CALL24  _KUtoa32_Recur              ; → D2 = digit count, XY0 advanced

                ; Write nul at advanced cursor (XY0 NOT advanced past it).
                LOADI   D1, #0
                STOREB  D1, [XY0]

                MOVE    D0, D2                      ; D0 = digit count
                CLC
                POP     D123, XY3
                RET

; Recursive helper. In: D1:D0 = value, XY0 = cursor.
; Out: D2 = digits written; XY0 advanced past them; D0, D1, D3 clobbered.
; Side effect: writes ASCII digits to [XY0].
_KUtoa32_Recur:
                ; Base test: is value < 10?  Equivalent to (D1 == 0) AND (D0 < 10).
                CMP     D1, #0
                BNE.S   .ku32_recur
                CMP     D0, #10
                BHS.S   .ku32_recur

                ; Base case: D0 holds the single digit (0..9).
                ADD     D0, #$30
                STOREB  D0, [XY0]
                INC     XY0, #1
                LOADI   D2, #1
                RET

.ku32_recur:
                ; Divmod10: D1:D0 / 10 → D1:D0 = quotient, D2 = remainder.
                LOADI   D2, #10
                CALL24  _KDivmod32

                ; D2 = our digit. Save, recurse on (D1:D0)=quotient,
                ; retrieve digit, emit it, bump count.
                PUSH    D2, XY3
                CALL24  _KUtoa32_Recur              ; returns D2 = digit count so far
                POP     D3, XY3                     ; D3 = our digit (rescued from stack)

                ADD     D3, #$30
                STOREB  D3, [XY0]
                INC     XY0, #1
                ADD     D2, #1                      ; bump total digit count
                RET


; ============================================================================
; _KBytesSplit — bytes (32-bit) → (whole, hundredths, unit) for human-readable
;                                  size formatting (KLIB slot 46)
; ============================================================================
;   Input:    D1:D0   = 32-bit unsigned byte count
;   Output:   D0      = whole part of the value in the chosen unit
;                       (0..1023 typically; can exceed 1023 only when the
;                       value tops the GB unit, i.e. > 1024 GB — irrelevant
;                       on K16 today)
;             D1      = hundredths (0..99) — the two-decimal fraction
;             D2      = unit index:
;                         0 = B   (bytes)
;                         1 = KB  (1024 bytes)
;                         2 = MB  (1024 KB)
;                         3 = GB  (1024 MB)
;             C = 0   always
;   Clobbers: D3 (and the input registers are repurposed for output)
;   Preserves: XY0, XY1, XY2, XY3
;
;   Policy: choose the smallest unit U such that bytes < (U+1's threshold),
;   so the integer part is in 0..1023. The exception is GB — anything
;   ≥ 1 GB stops at the GB unit and whole can grow past 1023.
;
;   Fraction model: hundredths = (sub_unit_remainder × 100) / 1024.
;   At the B unit the fraction is always 0 (bytes are exact).
;
;   Examples:
;       _KBytesSplit(0)        → (0,  0,  0)   "0"        (B)
;       _KBytesSplit(1023)     → (1023, 0, 0)  "1023"     (B)
;       _KBytesSplit(1024)     → (1,  0,  1)   "1.00 KB"
;       _KBytesSplit(45000)    → (43, 94, 1)   "43.94 KB"
;       _KBytesSplit(1048576)  → (1,  0,  2)   "1.00 MB"
;       _KBytesSplit($00FFFFFF)→ (15, 99, 2)   "15.99 MB" (16MB - 1)
;
;   Implementation: cascade of ÷1024 divides via _KDivmod32. Each stage
;   leaves the next-smaller unit's count in D1:D0 and the remainder (in
;   the previous unit) in D2. We save remainders to the stack as we
;   descend so the final stage's frac calc can pick up the right one.
;
;   Stack frame across the longest path (GB):
;     [SP+#0] = D2 from MB→GB divide (= MB_remainder, 0..1023)
;     [SP+#2] = caller's saved (none — we use SP only for local stash)
;
;   For shorter paths (KB or MB), only one remainder is parked.
; ============================================================================
_KBytesSplit:
                ; -------- (0) Quick check: bytes < 1024 → unit B -----------
                ; D1 must be zero AND D0 < 1024.
                CMP     D1, #0
                BNE.S   .kbs_at_least_kb
                CMP     D0, #1024
                BHS.S   .kbs_at_least_kb

                ; Bytes-only result. D0 already holds the value.
                LOADI   D1, #0                  ; hundredths = 0
                LOADI   D2, #0                  ; unit = B
                RETCC

.kbs_at_least_kb:
                ; -------- (1) Divide bytes by 1024 → kilobytes -------------
                ; D1:D0 = bytes (≥ 1024), D2 = 1024
                ; After: D1:D0 = KB count, D2 = byte_remainder (0..1023)
                LOADI   D2, #1024
                CALL24  KLIB_DIVMOD32

                ; Decide: stay at KB or escalate to MB?
                ; ≥1MB means D1:D0 ≥ 1024 (kilobytes). Branch targets are
                ; past the KB-result block, beyond short-branch range.
                CMP     D1, #0
                BNE     .kbs_at_least_mb
                CMP     D0, #1024
                BHS     .kbs_at_least_mb

                ; ---- Result is in KB. D0 = whole, D2 = byte_rem (0..1023).
                ; Compute frac = (byte_rem × 100) / 1024.
                ; D2 × 100 fits in 17 bits → use D1:D0 as 32-bit dividend.
                ;
                ; Sequence:
                ;   - save the whole (D0) on stack
                ;   - build D1:D0 = D2 × 100 (32-bit)
                ;   - divide by 1024
                ;   - retrieve whole, set unit=1
                PUSH    D0, XY3                 ; stash whole (KB count, 0..1023)

                ; D1:D0 = D2 × 100
                ;   D0 = D2 (low), D1 = D2 (high args) → MUL16x16_32 ABI
                MOVE    D0, D2
                LOADI   D1, #100
                CALL24  KLIB_MUL16x16_32        ; D1:D0 = D0 × D1 (32-bit product)

                ; Divide D1:D0 by 1024 → D1:D0 = frac (0..99), D2 = rem (ignored).
                LOADI   D2, #1024
                CALL24  KLIB_DIVMOD32

                ; D0 = frac (0..99). Promote to output D1.
                MOVE    D1, D0

                ; Retrieve whole into D0; set unit.
                POP     D0, XY3                 ; D0 = whole (KB)
                LOADI   D2, #1                  ; unit = KB
                RETCC

.kbs_at_least_mb:
                ; -------- (2) D1:D0 = KB count (≥ 1024); D2 = byte_rem ---
                ; Byte_rem is irrelevant beyond KB precision; discard.
                ; Divide D1:D0 (KB) by 1024 → MB.
                LOADI   D2, #1024
                CALL24  KLIB_DIVMOD32           ; D1:D0=MB, D2=KB_rem (0..1023)

                ; Decide: stay at MB or escalate to GB? Branch targets are
                ; past the MB-result block, beyond short-branch range.
                CMP     D1, #0
                BNE     .kbs_at_least_gb
                CMP     D0, #1024
                BHS     .kbs_at_least_gb

                ; ---- Result is in MB. D0 = whole, D2 = KB_rem.
                ; Compute frac = (KB_rem × 100) / 1024.
                PUSH    D0, XY3                 ; stash whole (MB, 0..1023)

                MOVE    D0, D2
                LOADI   D1, #100
                CALL24  KLIB_MUL16x16_32        ; D1:D0 = KB_rem × 100

                LOADI   D2, #1024
                CALL24  KLIB_DIVMOD32           ; D0 = frac (0..99)
                MOVE    D1, D0

                POP     D0, XY3                 ; whole (MB)
                LOADI   D2, #2                  ; unit = MB
                RETCC

.kbs_at_least_gb:
                ; -------- (3) D1:D0 = MB count (≥ 1024); D2 = KB_rem -----
                ; Divide D1:D0 (MB) by 1024 → GB.
                ; KB_rem in D2 is discarded; we'll use MB_rem from this
                ; divide for the GB fraction.
                LOADI   D2, #1024
                CALL24  KLIB_DIVMOD32           ; D1:D0=GB, D2=MB_rem (0..1023)

                ; ---- Result is in GB. D0 = whole (may exceed 1023 if the
                ; volume is > 1024 GB, but K16 will never see that).
                ; D2 = MB_rem.
                PUSH    D0, XY3

                MOVE    D0, D2
                LOADI   D1, #100
                CALL24  KLIB_MUL16x16_32        ; D1:D0 = MB_rem × 100

                LOADI   D2, #1024
                CALL24  KLIB_DIVMOD32           ; D0 = frac (0..99)
                MOVE    D1, D0

                POP     D0, XY3                 ; whole (GB)
                LOADI   D2, #3                  ; unit = GB
                RETCC

; ============================================================================
; End of kos_klib_impl.asm
; ============================================================================
