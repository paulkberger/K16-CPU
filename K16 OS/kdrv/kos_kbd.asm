; ============================================================================
; kos_kbd.asm — k/OS keyboard ring driver
; ============================================================================
; Date:    14 May 2026
; Status:  Part 30 r37 hygiene + Phase A keyboard ring + Phase B Step 6 + 6b.
; Revision: r4 — 14 May 2026. k/OS Part 30 hygiene: Ctrl-digit range
;               check now uses KEY_CTRL_DIGIT_FIRST/LAST from kos_defs.inc
;               instead of literal $81/$8B. Same encoded value, named
;               constants bring the defs entries into actual use.
;               Also: rewrote the _KbdDispatch header comment block —
;               the "TODO Step 6b" / "no shell switch happens" notes
;               were stale (Step 6b landed in r3, direct-index switch
;               via _SwitchForegroundByIndex is live).
;               Requires kos_defs.inc r37+.
;
;           r3 — 13 May 2026. Phase B Step 6b — Ctrl-digit direct-index.
;               $81..$8A (Ctrl-1..0 on EMU) now call _SwitchForegroundByIndex
;               in kos_switcher.asm r5+. Index = key - $80, so $81 → 1
;               (first registered shell, normally kosh), $8A → 10.
;               Out-of-range indices and missing anchor are silent no-ops.
;               $0E (Ctrl-N) and $10 (Ctrl-P) handling unchanged from r2.
;
;           r2 — 13 May 2026. Phase B Step 6 hot-key filter.
;               _KbdDispatch's previously empty body now intercepts
;               Ctrl-N ($0E) → _SwitchForegroundNext and Ctrl-P ($10) →
;               _SwitchForegroundPrev before they reach the ring. Also
;               swallows Ctrl-digit range $81..$8A so EMU-only direct-
;               index keys don't pollute the ring; direct-index switch
;               itself is a Step 6b TODO.  All other bytes fall through
;               to _RingPush unchanged.
;
;           r1 — 13 May 2026. Initial.
;               Four routines:
;                 _KbdDispatch  — policy seam (Phase A: empty, falls through
;                                 to _RingPush; Phase B: prepended hot-key
;                                 filter goes here)
;                 _RingPush     — mechanism: SPSC producer
;                 _RingPop      — mechanism: SPSC consumer (C=1 if empty)
;                 _RingWaitPop  — convenience: spin-pop wrapper
;
; Architecture:
;
;     MMIO @ $DE_0000 (read-clear)
;             |
;             v
;       _KbdTick (inline in _TimerIRQ; reads MMIO; CALL24s _KbdDispatch
;                 on non-zero)
;             |
;             v
;       _KbdDispatch  ◄── policy (Phase A: fall-through; Phase B: hot-key filter)
;             |
;             v
;       _RingPush     ◄── mechanism (unconditional push; silent drop if full)
;             |
;          [ring at KBD_RING_BUF, 64 bytes]
;             |
;             v
;       _RingPop      ◄── mechanism (C=1 on empty)
;             ^
;             |
;       _RingWaitPop  ◄── used by sys_getchar
;
; Ring invariants:
;   Empty: KBD_HEAD == KBD_TAIL
;   Full:  ((KBD_HEAD + 1) AND KBD_RING_MASK) == KBD_TAIL
;   Capacity: 63 bytes
;
; Return convention (kernel-internal flag ABI):
;   _RingPop:     C=0 → D0 holds the popped byte
;                 C=1 → ring was empty; D0 unspecified
;   _RingPush:    no flag return (silent overrun drop)
;   _RingWaitPop: C=0, D0 = byte (always — spins until non-empty)
;
; SPSC safety:
;   Producer (_RingPush) writes KBD_HEAD only, reads KBD_TAIL only.
;   Consumer (_RingPop) writes KBD_TAIL only, reads KBD_HEAD only.
;   LOADZ/STOREZ are atomic per CPU contract.
;   Hardware DINT in the ISR means the producer is non-reentrant.
;   No locks needed.
;
; Note: included from kos_boot.asm after kdrv/kos_console.asm.
;       Constants come from kos_defs.inc.
; ============================================================================


; ----------------------------------------------------------------------------
; _KbdDispatch — keystroke policy filter
;   Input:    D0 low = received key byte (high byte already zero from MMIO)
;   Output:   none
;   Clobbers: D0, D1, XY0, XY1
;   Preserves: D2, D3, XY2, XY3
;   Context:  kernel stack (Y3=$00), called from _TimerIRQ via CALL24.
;
;   Phase A: no filter — fell straight through into _RingPush.
;
;   Phase B Step 6: hot-key filter. Recognised switcher keys are consumed
;   (not pushed to the ring); they trigger a foreground switch directly.
;   All other keys fall through to _RingPush unchanged.
;
;   Recognised (Step 6 + 6b — all live):
;     $0E (Ctrl-N / Ctrl-RightArrow on EMU)   → _SwitchForegroundNext
;     $10 (Ctrl-P / Ctrl-LeftArrow on EMU)    → _SwitchForegroundPrev
;     $81..$8A (Ctrl-1..0 on EMU, EMU-only)   → _SwitchForegroundByIndex
;                                                 (index = key - $80,
;                                                  1..10; out-of-range
;                                                  silently no-ops in
;                                                  the switcher helper)
;
;   The _SwitchForeground{Next,Prev,ByIndex} helpers themselves clobber
;   D0..D3, XY0..XY2 — wider than _KbdDispatch's contract. We save the
;   contract regs around the call.
; ----------------------------------------------------------------------------
_KbdDispatch:
                ; --- Hot-key dispatch ------------------------------------
                ; Mask any junk in the high byte. The MMIO read uses LOADD
                ; (16-bit) into D0 even though the keyboard register is
                ; 8-bit; the upper byte is unspecified on some hosts.
                ; Without this LOW, a non-zero high byte would prevent the
                ; CMP/BEQ chain from matching the low-byte key code.
                LOW     D0

                CMP     D0, #KEY_CTRL_N
                BEQ     .kd_next
                CMP     D0, #KEY_CTRL_P
                BEQ     .kd_prev

                ; Ctrl-digit range KEY_CTRL_1 ($81) .. KEY_CTRL_0 ($8A)
                ; → switch by index (1..10). Part 30 r37 hygiene: was
                ; literals $81/$8B; now uses the named constants from
                ; kos_defs.inc.
                CMP     D0, #KEY_CTRL_DIGIT_FIRST
                BLO     _RingPush               ; below range → fall through
                CMP     D0, #KEY_CTRL_DIGIT_LAST+1
                BHS     _RingPush               ; above range → fall through

                ; Index = key - $80.  D0 holds key.
                SUB     D0, #$80
                PUSH    D2, XY3
                PUSH    D3, XY3
                PUSH    XY2, XY3
                CALL24  _SwitchForegroundByIndex
                POP     XY2, XY3
                POP     D3, XY3
                POP     D2, XY3
                RET

.kd_next:
                ; Save callee-preserve regs (per _KbdDispatch's contract)
                ; that _SwitchForegroundNext will clobber.
                PUSH    D2, XY3
                PUSH    D3, XY3
                PUSH    XY2, XY3
                CALL24  _SwitchForegroundNext
                POP     XY2, XY3
                POP     D3, XY3
                POP     D2, XY3
                RET

.kd_prev:
                PUSH    D2, XY3
                PUSH    D3, XY3
                PUSH    XY2, XY3
                CALL24  _SwitchForegroundPrev
                POP     XY2, XY3
                POP     D3, XY3
                POP     D2, XY3
                RET

; ----------------------------------------------------------------------------
; _RingPush — unconditional producer
;   Input:    D0 low = byte to push (high byte zero by convention)
;   Output:   none — no flag return; overrun is silent
;   Clobbers: D0, D1, XY0, XY1
;   Preserves: D2, D3, XY2, XY3
;   Context:  kernel stack (Y3=$00).
; ----------------------------------------------------------------------------
_RingPush:
                LOW     D0                  ; ensure key byte in low only

                ; Compute next head; check against tail for full
                LOADZ   D1, [#KBD_HEAD]
                ADD     D1, #1
                AND     D1, #KBD_RING_MASK  ; D1 = next head
                LOADZ   X0, [#KBD_TAIL]
                CMP     D1, X0
                BEQ.S   .full               ; next == tail → ring full

                ; Store byte at current head: XY1 = $00:KBD_RING_BUF + head
                LOADZ   X1, [#KBD_HEAD]
                LOADI   Y1, #$00
                ADD     X1, #KBD_RING_BUF
                STOREB  D0, [XY1]

                ; Commit new head (already in D1)
                STOREZ  D1, [#KBD_HEAD]
.full:
                RET


; ----------------------------------------------------------------------------
; _RingPop — non-blocking consumer
;   Input:    none
;   Output:   if non-empty: D0 = byte (zero-extended), C = 0
;             if empty:     D0 unspecified,            C = 1
;   Clobbers: D0, D1, XY0 (only on the non-empty path)
;   Preserves: D2, D3, XY1, XY2, XY3
;
;   Used by _RingWaitPop and by any future non-blocking reader.
; ----------------------------------------------------------------------------
_RingPop:
                LOADZ   D0, [#KBD_HEAD]
                LOADZ   D1, [#KBD_TAIL]
                CMP     D0, D1
                BEQ.S   .empty              ; HEAD == TAIL → empty

                ; Non-empty: D0 ← ring[TAIL]. Build XY0 = $00:KBD_RING_BUF,
                ; index by D1 (the tail) using LOADB Mode 01 [XYn+Dm].
                LOADI   Y0, #$00
                LOADI   X0, #KBD_RING_BUF
                LOADB   D0, [XY0+D1]        ; D0 = byte (zero-extended)

                ; Advance tail (in D1) and commit
                ADD     D1, #1
                AND     D1, #KBD_RING_MASK
                STOREZ  D1, [#KBD_TAIL]

                RETCC
.empty:
                RETCS


; ----------------------------------------------------------------------------
; _RingWaitPop — blocking consumer
;   Input:    none
;   Output:   D0 = byte (zero-extended), C = 0
;   Clobbers: D0, D1, XY0
;
;   Spins on _RingPop until a byte is available. Timer ISR drains MMIO
;   into the ring underneath; worst-case keystroke→return latency is
;   one tick (~33 ms at 30 Hz).
;
;   Leaf — no DINT, no IRQ-state manipulation. SPSC-safe.
; ----------------------------------------------------------------------------
_RingWaitPop:
                CALL24  _RingPop
                BCS     _RingWaitPop        ; empty → keep spinning
                RETCC                       ; D0 = byte, C=0


; ============================================================================
; End of kos_kbd.asm
; ============================================================================
