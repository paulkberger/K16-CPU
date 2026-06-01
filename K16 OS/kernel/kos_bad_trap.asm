; ============================================================================
; kos_bad_trap.asm — k/OS instrumented version
; ============================================================================
; Date:    30 April 2026
; Revision: r6 - 4 May 2026 — Branch .S polish.
;             8 unsuffixed branches converted to .S form
;             where target distance is ≤10 instructions.
;             FORWARD ONLY (assembler imm5 is unsigned 0..+31).
;             Per
;             K16 Manual Amendment 2026-05-04 E.5/E.6, default
;             auto-select picks long form; explicit .S saves
;             one word per branch. Saves 8 words.
;
; Revision: r5 - 30 April 2026 (instrumented bad_int — HALT with IRQ level)
;
; bad_int reads pushed SR.LVL and HALTs with code:
;   $10 = level 0 (IRQ7 timer)
;   $11 = level 1 (IRQ6)
;   ... up to $17 = level 7 (IRQ0)
;
; This way if any unexpected INT fires, we see exactly which IRQ.
; ============================================================================

bad_trap:
                LOADI   D0, #ERR_BADCALL
                RETCS

bad_int:
                ; Read pushed SR — at [XY3+0] (no PUSH yet)
                LOADD   D0, [XY3]
                AND     D0, #$0070              ; isolate LVL bits 6:4
                SHR4    D0                      ; → 0..7 in low 3 bits
                ADD     D0, #$10                ; → $10..$17
                
                ; HALT instruction expects a literal imm5 — we can't put
                ; D0 in there directly. Use a small JMPT-style dispatch:
                ; just compare and HALT each.
                
                CMP     D0, #$10
                BNE.S     .not0
                HALT    #$10
.not0:
                CMP     D0, #$11
                BNE.S     .not1
                HALT    #$11
.not1:
                CMP     D0, #$12
                BNE.S     .not2
                HALT    #$12
.not2:
                CMP     D0, #$13
                BNE.S     .not3
                HALT    #$13
.not3:
                CMP     D0, #$14
                BNE.S     .not4
                HALT    #$14
.not4:
                CMP     D0, #$15
                BNE.S     .not5
                HALT    #$15
.not5:
                CMP     D0, #$16
                BNE.S     .not6
                HALT    #$16
.not6:
                CMP     D0, #$17
                BNE.S     .not7
                HALT    #$17
.not7:
                ; Should be unreachable — D0 came from 3-bit field +$10
                HALT    #$1F
