# Implementing BASIC on the K16 CPU

## Overview

K16 BASIC is a complete integer BASIC interpreter written in K16 assembly language, running on a custom 16-bit CPU built from discrete TTL logic. The interpreter weighs in at just over 4,000 lines of assembly and provides a feature set comparable to classic 8-bit BASICs like MS BASIC and EhBASIC, with some modern enhancements made possible by the K16's 24-bit addressing and paged memory architecture.

The current version (v2.1t) implements tokenized input for performance, supporting 23 statement keywords, 4 secondary keywords, 5 word-operators, 3 compound comparison tokens, 8 numeric functions, and 6 string functions — 49 tokens in total.

## Language Features

**Statements:** PRINT, INPUT, LET, IF/THEN/ELSE, GOTO, GOSUB/RETURN, FOR/NEXT/STEP, READ/DATA/RESTORE, DIM, POKE, DOKE, ON expr GOTO/GOSUB, REM, END, STOP, CLR, NEW, LIST, RUN

**Operators:** `+ - * / MOD AND OR XOR NOT = <> < > <= >=`

**Functions:** ABS(), ASC(), RND(), SGN(), PEEK(), DEEK(), LEN(), VAL(), CHR$(), STR$(), HEX$(), LEFT$(), RIGHT$(), MID$()

**Data types:** 16-bit signed integers (-32768 to 32767), strings (up to 255 bytes), integer arrays with DIM

**Variables:** A–Z (integers), A$–Z$ (strings), A()–Z() (arrays)

## Memory Architecture

The interpreter takes advantage of the K16's paged memory to separate concerns cleanly:

```
Page $00 (RAM):
  $0000-$00FF   Vectors, zero page
  $0100-$03FF   System variables, GOSUB stack, FOR stack,
                variable storage, array/string descriptors
  $0400-$04FF   Text Input Buffer (TIB) — 256 bytes
  $0500-$05FF   Temp string buffers (2 × 128 bytes)
  $0600-$7FFF   Array storage (grows upward)
  $8000-$FEFE   String pool (grows downward)
  $FF00-$FFFE   System stack

Page $01 (Program):
  $0000-$FFFF   BASIC program storage (64K available)
```

This two-page layout means BASIC programs can be up to 64K without encroaching on variables, arrays, or the string pool. The string pool and array storage grow toward each other in page $00, with the allocator checking for collision.

## K16 ISA Features Exploited

### Paged Memory (LOADP/STOREP) — The Workhorse

The single most-used ISA feature in the interpreter. With 76 LOADPs and 89 STOREPs, paged memory access is the backbone of the entire system.

The K16's LOADP/STOREP instructions access memory at `Yn:address` — a page register (Y) combined with a 16-bit address. This maps perfectly to the interpreter's needs: Y3 stays fixed at $00 throughout execution, giving single-instruction access to all zero-page variables:

```asm
LOADP   D0, Y3, [#ZP_TXTPOS]    ; load text cursor position
STOREP  D0, Y3, [#ZP_RUNNING]   ; store run flag
LOADP   D0, Y3, [#ZP_LINENUM]   ; load current line number
```

Without LOADP, every zero-page access would require loading an address into an XY pair first — two LOADI instructions plus the load. LOADP collapses this to a single instruction. Given that the interpreter accesses zero-page variables roughly 165 times, this saves approximately 330 instructions and significant cycle time.

The program storage lives in page $01, accessed through `LOADI Y0, #PROG_PAGE` followed by LOADB/LOADD operations with XY0. The `get_text_page` helper dynamically selects page $00 (direct mode) or $01 (running a program) so the same parsing code works in both contexts.

### JMPT — Jump Table Dispatch

The K16's `JMPT XYn, Dm` instruction reads an address from a jump table at `[XYn + Dm]` and loads it directly into the PC. This is the key to tokenized statement dispatch:

```asm
exec_statement:
    ; D0 = token byte ($80–$96)
    SUB     D0, #TOK_PRINT       ; zero-base offset
    ADD     D0, D0               ; word offset (×2)
    LOADI   X1, #<STMT_DISPATCH
    LOADI   Y1, #>STMT_DISPATCH
    CALL    .es_dispatch         ; push return address
    ...
.es_dispatch:
    JMPT    XY1, D0              ; PC ← mem[XY1 + D0]
```

The CALL pushes the return address, then JMPT redirects execution to the handler. When the handler executes RET, control returns to the instruction after the CALL. This is cleaner and faster than a LOADD + MOVE PC trampoline.

The dispatch table is simply:
```asm
STMT_DISPATCH:
    .WORD   CMD_PRINT             ; $80
    .WORD   CMD_INPUT             ; $81
    .WORD   CMD_RESTORE           ; $82
    ...
    .WORD   CMD_RUN               ; $96
```

Before tokenization, statement dispatch required scanning through 23 keywords with string comparisons — approximately 280 cycles in the worst case. The indexed lookup takes roughly 31 cycles regardless of which statement is being executed. This is a 9× speedup on the interpreter's hottest path.

The same pattern is used for the detokenizer's string lookup during LIST output.

### PUSH/POP — The Expression Evaluator's Backbone

The recursive descent expression evaluator relies heavily on the stack. With 89 PUSHes and 120 POPs across the codebase, the K16's flexible PUSH/POP instructions are essential.

The K16 PUSH/POP syntax allows pushing any register to any XY-pair-based stack:

```asm
PUSH    D0, XY3       ; push D0 to system stack
POP     D1, XY3       ; pop into D1
PUSH    XY0, XY3      ; push XY pair (2 words)
POP     XY0, XY3      ; restore XY pair
```

A typical expression evaluator level looks like:

```asm
expr_l3:        ; Addition / Subtraction
    CALL    expr_l4              ; evaluate left operand
.l3_loop:
    PUSH    D0, XY3              ; save left value
    CALL    skip_spaces
    CALL    peek_char
    CMP     D0, #$2B            ; '+'?
    BEQ     .l3_add
    CMP     D0, #$2D            ; '-'?
    BEQ     .l3_sub
    POP     D0, XY3              ; no operator, restore and return
    RET

.l3_add:
    CALL    get_char             ; consume '+'
    CALL    expr_l4              ; right operand → D0
    POP     D1, XY3              ; left operand → D1
    ADD     D0, D1
    BRA     .l3_loop             ; check for more terms
```

The GOSUB stack and FOR/NEXT stack are also managed manually using XY3-relative addressing, with LOADP/STOREP for the stack pointers and calculated offsets for entry fields.

### Branching — The Instruction Set's Breadth Pays Off

The K16 provides a full set of conditional branches: BEQ, BNE, BCS, BCC, BLT, BGT, BLE, BGE, plus unconditional BRA. The interpreter uses all of them:

| Branch | Count | Primary Use |
|--------|-------|-------------|
| BEQ | 162 | Token matching, null terminator checks, comparison results |
| BNE | 65 | Loop continuation, mismatch detection |
| BCC | 65 | Range checks (unsigned less-than), character class testing |
| BCS | 37 | Unsigned greater-or-equal checks |
| BRA | 152 | Loop backs, dispatch jumps, fall-through avoidance |
| BGE | 7 | Signed comparisons in division, FOR/NEXT |
| BLT | 4 | Signed less-than in user expressions |
| BGT | 4 | Signed greater-than in user expressions |
| BLE | 2 | FOR/NEXT step direction |

Character classification is a frequent pattern — testing whether a byte is a digit, letter, or token. The K16's unsigned branch instructions (BCC/BCS) make range checks compact:

```asm
; Is D0 a decimal digit?
CMP     D0, #$30         ; '0'
BCC     .not_digit        ; below '0'
CMP     D0, #$3A         ; '9' + 1
BCS     .not_digit        ; above '9'
; It's a digit
```

### LOADB/STOREB — Byte-Level Text Processing

A BASIC interpreter is fundamentally a text processor. The K16's LOADB instruction loads a byte from memory zero-extended to 16 bits, which is exactly what's needed for processing ASCII characters and token bytes:

```asm
LOADB   D0, [XY0]       ; load character/token
CMP     D0, #TOK_PRINT  ; compare with token ($80)
```

Since LOADB zero-extends, token bytes in the $80–$B0 range compare correctly against 16-bit immediate values without masking. This is important — a sign-extending byte load would have produced $FF80 for token $80, breaking all token comparisons.

### JMPT XYn, Dm — Purpose-Built for Dispatch

The `JMPT XY1, D0` instruction was designed exactly for this use case — jump tables. It reads a 16-bit address from memory at `[XY1 + D0]` and loads it into the PC in a single 4-cycle instruction. Combined with CALL to push a return address first, it provides an efficient indirect call mechanism. The handler executes RET and returns to the caller of exec_statement — no trampoline code needed.

### SHL — Fast Multiplication

The SHL instruction appears 50 times, primarily for address calculations and the multiply-by-10 pattern in number parsing:

```asm
; D2 = D2 * 10 + D0 (new digit)
MOVE    D1, D2
SHL     D2              ; ×2
SHL     D2              ; ×4
ADD     D2, D1          ; ×5
SHL     D2              ; ×10
ADD     D2, D0          ; + digit
```

This pattern is used in both `parse_linenum` and `expr_l6` (decimal literal parsing). It's faster than calling the general multiply routine.

Variable access uses `SHL D0` to convert a variable index (0–25) to a byte offset (0–50) into the variable table. Array descriptor lookup uses double SHL for 4-byte descriptor entries.

### ADC — Multi-Word Arithmetic

The divide routine uses `ADC D2, D2` (add-with-carry) to shift the carry bit from a left-shift of the dividend into the remainder register — the classic shift-subtract division algorithm:

```asm
.dv_loop:
    ADD     D0, D0       ; shift dividend left, MSB → carry
    ADC     D2, D2       ; shift carry into remainder
    CMP     D2, D1       ; remainder ≥ divisor?
    BCC     .dv_no
    SUB     D2, D1       ; subtract divisor
    OR      D0, #1       ; set quotient bit
.dv_no:
    SUB     D3, #1
    BNE     .dv_loop
```

This is a textbook non-restoring division that executes in exactly 16 iterations.

### MULB — ROM-Based Byte Multiply

The K16's LOOKUP ROM provides `MULB Dn` which multiplies the high byte by the low byte of a register, returning a 16-bit result in 3 cycles. This enables a fast 16×16 multiply using partial products:

```asm
; result = (n1L×n2L) + ((n1H×n2L + n1L×n2H) << 8)
SHL4    D1
SHL4    D1              ; pack n2L into high byte
OR      D0, D1          ; D0 = (n2L<<8) | n1L
MULB    D0              ; D0 = n2L × n1L in 3 cycles
```

Three MULB calls replace a 16-iteration shift-and-add loop. The same technique extends to 32-bit results (four MULBs with carry propagation via SCS), used by `div10` for reciprocal multiplication.

### SCS / Scc — Conditional Set (Branchless Comparisons)

The Scc instructions set a register to $FFFF (true) or $0000 (false) based on condition flags, without branching. The expression evaluator uses these for all six comparison operators:

```asm
; Before (branching):
CMP     D1, D0
BGT     .l2_true         ; branch if greater
BRA     .l2_false        ; always branch
...
.l2_true:  LOADI D0, #$FFFF
.l2_false: LOADI D0, #0

; After (branchless):
CMP     D1, D0
SGT     D0               ; D0 = $FFFF if D1 > D0, else $0000
```

Each comparison handler collapses from 4+ instructions with two branches to 2 instructions with no branches. The full set is used: SEQ, SNE, SLT, SGT, SLE, SGE for numeric comparisons, and the same set for string comparison results.

SCS (Set if Carry Set) also serves a different role in the 32-bit multiply — capturing the carry flag as a 0/1 value after addition, avoiding a branch-based carry propagation pattern.

### AND with Immediate — Case Folding and Masking

The pattern `AND D0, #$DF` converts lowercase ASCII to uppercase by clearing bit 5. This appears throughout the interpreter for case-insensitive variable names and keyword matching:

```asm
CMP     D1, #$61       ; 'a'
BCC     .already_upper
CMP     D1, #$7B       ; 'z' + 1
BCS     .already_upper
AND     D1, #$DF       ; to uppercase
```

The K16's ability to AND with a 16-bit immediate makes this a single instruction. On architectures requiring an AND register, this would need a load-then-AND sequence.

## Tokenization System

### Design

Input tokenization replaces keyword strings with single-byte tokens at input time. When the user types `PRINT "HELLO"`, the tokenizer converts it to `$80 $20 $22 $48 $45 $4C $4C $4F $22` — the PRINT keyword becomes a single $80 byte.

The token encoding uses the range $80–$B0 (49 tokens), leaving $00–$7F for raw ASCII. This means tokens are trivially distinguished from regular characters by testing bit 7.

### Token Table Format

The token table stores entries as `.TEXT $xx, "KEYWORD", 0` — a token byte followed by the keyword string and a null terminator. The assembler's `.TEXT` directive word-aligns each entry, inserting padding bytes. The tokenizer handles this by treating $00 bytes at entry positions as padding (skip) and using $FF as the end-of-table sentinel.

Longer keywords appear first in the table to prevent prefix ambiguity — "RESTORE" before "RETURN" before "REM", "GOSUB" before "GOTO" before "GO".

### Tokenizer Operation

The tokenizer runs in-place on the Text Input Buffer (TIB). Since every token (1 byte) is shorter than its keyword (2–7 bytes), the write pointer never overtakes the read pointer, making in-place conversion safe.

Special handling:
- **Quoted strings** are copied verbatim (keywords inside quotes are not tokenized)
- **REM and DATA** copy the rest of the line as-is after emitting the token
- **Compound operators** `<=`, `>=`, `<>` are detected as two-character sequences and replaced with single tokens
- **Word boundary check** prevents matching keywords embedded in identifiers (e.g., "FORMAT" doesn't match "FOR")

### Detokenizer

The LIST command uses a detokenizer that expands tokens back to readable text. For each byte in a program line, if bit 7 is set, it's looked up in the DETOK_TABLE — an array of .WORD pointers to null-terminated keyword strings, indexed by (token − $80) × 2.

The word operators (AND, OR, XOR, NOT, MOD) are detokenized with surrounding spaces for readability: `" AND "`, `" OR "`, etc. Compound comparison tokens expand to their two-character form: `<=`, `>=`, `<>`.

## Expression Evaluator

The expression evaluator uses recursive descent with six precedence levels:

| Level | Operators | Implementation |
|-------|-----------|----------------|
| 0 | OR | Token match on $9C |
| 1 | AND, XOR | Token match on $9B, $9D |
| 2 | = < > <> <= >= | ASCII chars + tokens $A0–$A2 |
| 3 | + − | ASCII $2B, $2D |
| 4 | * / MOD | ASCII $2A, $2F + token $9F |
| 5 | Unary − NOT | ASCII $2D, token $9E |
| 6 | Atoms | Numbers, variables, functions, arrays, parens |

Level 2 also handles string comparisons. The `is_string_expr` helper peeks at the current position to determine if the left operand is a string (quoted literal, string variable A$–Z$, or string function token $AB–$B0). If so, it takes the string comparison path, which evaluates both sides as strings, compares them lexicographically, and returns −1 (true) or 0 (false).

Comparisons return −1 ($FFFF) for true and 0 for false, following the Microsoft BASIC convention. This allows boolean expressions like `IF (A>5) AND (B<10) THEN ...` to work correctly since AND operates bitwise. All six comparison operators use branchless Scc instructions (SEQ, SNE, SLT, SGT, SLE, SGE) which produce exactly these values from the CMP flags.

## Arithmetic

All arithmetic is 16-bit signed integer. The interpreter implements:

- **Multiplication:** MULB-based partial products — splits operands into bytes, performs three 8×8→16 ROM lookups, combines with shifts. Adapted from the K16 Forth interpreter. Faster and smaller than the traditional shift-and-add loop.
- **Division:** Shift-subtract (non-restoring), 16 iterations, handles signed operands by converting to positive, dividing, then adjusting sign
- **MOD:** Computed as `A − (A/B)*B` using the existing divide and multiply
- **Fast ×10:** Shift-add sequence for number parsing (5 instructions)
- **div10:** Reciprocal multiply — `q = hi16(n × 52429) >> 3` using a full 32-bit MULB multiply (4 partial products with carry propagation via SCS). Returns both quotient and remainder, eliminating the need for a separate mul10 back-multiply in number printing.

## String System

Strings use a descriptor-based system with pool allocation:

- **Descriptors** (4 bytes each): length word + pointer word, stored at fixed addresses ($0190–$01F7 for A$–Z$)
- **String pool**: grows downward from $FEFE in page $00
- **Garbage collection**: triggered on allocation failure, compacts live strings
- **Temp buffers**: two 128-byte buffers ($0500–$057F, $0580–$05FF) for intermediate results during concatenation and comparison

String functions return results through ZP_TMPLEN/ZP_TMPPTR, and LET copies the result into the pool. This avoids premature allocation for temporary expression results.

## Control Flow

**GOSUB/RETURN** uses a 16-entry stack at $0200–$023F (4 bytes per entry: return line offset + text position). Stack overflow is checked on GOSUB; underflow on RETURN.

**FOR/NEXT** uses an 8-entry stack at $0240–$028F (10 bytes per entry: variable index, limit, step, saved line offset, text position). A matching NEXT pops or loops by comparing the variable index.

**ON expr GOTO/GOSUB** tokenizes the GOTO/GOSUB keyword, then counts through comma-separated line numbers to find the target matching the selector value.

**IF/THEN/ELSE** evaluates the condition, and if false, scans forward for a matching ELSE token (tracking THEN/ELSE nesting depth).

## Lessons Learned

**`.TEXT` word-aligns.** The assembler's .TEXT directive pads odd-length strings with a null byte for word alignment. This broke the token table when $00 was used as the end-of-table sentinel. Fixed by using $FF as the sentinel and skipping padding nulls.

**POP XY overwrites both X and Y.** `POP XY0, XY3` restores both X0 and Y0. If you need to discard a saved XY value but keep the current X0, you must save X0 to another register first. This caused a tokenizer bug where the read pointer snapped back to the start of each matched keyword.

**LOADP/STOREP is the killer feature for interpreters.** Paged access to zero-page variables eliminates the constant address-loading overhead that plagues pointer-heavy code on simpler architectures. The K16's Y3 register effectively becomes a "page register" that's set once and used hundreds of times.

**Token dispatch via JMPT is transformative.** Moving from string-matching dispatch (~280 cycles) to JMPT table dispatch (~15 cycles) was the single biggest performance win. The K16's `JMPT XYn, Dm` instruction was designed for exactly this — one instruction to index into a jump table and transfer control.

**Recursive descent works well on register machines.** The K16's PUSH/POP and CALL/RET make recursive descent natural. Each precedence level is a simple function that calls the next level, checks for its operator, and combines results. The stack handles all intermediate values.

**MULB replaces loops with lookups.** The ROM-based 8×8 byte multiply turns a 16-iteration shift-and-add loop into three table lookups with some byte shuffling. The same technique scales to 32-bit results (four lookups), enabling the reciprocal-multiply div10 that eliminates the division loop from number printing entirely.

**Scc eliminates comparison branches.** Every comparison in the expression evaluator previously required a conditional branch to a shared "true" label and an unconditional branch to "false". The Scc instructions collapse this to a single instruction that writes the result directly. Twelve handlers (six numeric, six string) each lost two branches.

## Statistics

| Metric | Value |
|--------|-------|
| Source lines | 4,115 |
| Tokens defined | 49 |
| Statement handlers | 23 |
| Numeric functions | 8 |
| String functions | 6 |
| Expression levels | 6 |
| LOADP/STOREP uses | 165 |
| PUSH/POP uses | 209 |
| CALL uses | 309 |
| Branch uses | 478 |
| MULB uses | 7 |
| Scc uses | 14 |
| RAM used (page $00) | ~1.5K system, rest dynamic |
| Program space (page $01) | 64K |
