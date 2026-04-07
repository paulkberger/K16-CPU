# K16 Reference Manual

Version 3.3 — 7 April 2026

---

## 1. Overview

The K16 is a 16-bit CPU with a 24-bit address space, designed around ROM-based lookup tables for both ALU operations and instruction decoding. This reference manual covers the instruction set architecture, assembly syntax, and programming guidelines.

Designed and implemented in discrete TTL logic by **Paul Berger**.

GitHub: https://github.com/paulkberger/K16-CPU

### 1.1 Architecture Summary

| Feature | Specification |
|---------|---------------|
| Data width | 16 bits |
| Address space | 24 bits (16MB) |
| Registers | D0-D3 (data), X0-X3/Y0-Y3 (index), XY0-XY3 (24-bit pairs) |
| Stack pointer | XY3 (hardcoded for CALL/RET/PUSH/POP) |
| Status flags | C (Carry), Z (Zero), N (Negative), V (Overflow) |
| Interrupt levels | 8 (IRQ0-IRQ7, priority encoded) |
| Endianness | Little-endian |

### 1.2 Memory Map

| Address Range | Size | Description |
|---------------|------|-------------|
| $00_0000 - $00_FFFF | 64KB | Page 00: Zero Page & Stack |
| $01_0000 - $1F_FFFF | ~2MB | RAM (currently installed) |
| $20_0000 - $BF_FFFF | 10MB | RAM (expansion space) |
| $C0_0000 - $DF_FFFF | 2MB | I/O Space |
| $E0_0000 - $EF_FFFF | 1MB | ROM: Lookup Tables (Bank 1) |
| $F0_0000 - $FB_FFFF | 768KB | ROM: Lookup Tables (Bank 2) |
| $FC_0000 - $FE_FFFF | 192KB | ROM: Program Code |
| $FF_0000 - $FF_FFFF | 64KB | ROM: Boot Code & Reset Vector |

**Reset Vector:** CPU starts execution at $FF_0000 after reset.

**I/O Addresses:**
- $C0_0000: Keyboard input (word)
- $D0_0000: Terminal output (byte)

### 1.3 Opcode Map

| Opcode | Hex | Mnemonic | Description |
|--------|-----|----------|-------------|
| 00000 | $00 | MISC | NOP, HALT, NEG |
| 00001 | $01 | LOOKUP | SHL, SHR, ASR, ROL, ROR, SWAPB, HIGH, LOW, SHL4, SHR4, ASR4, ASR8, MULB, RECIP |
| 00010 | $02 | INC/DEC | Increment/Decrement XY pair (24-bit) |
| 00011 | $03 | LEA | Load Effective Address |
| 00100 | $04 | Scc | Conditional Set (SEQ, SNE, SCS/SHS, SCC/SLO, SLT, SGT, SGE, SLE) |
| 00101 | $05 | MOVE/SWAP | Register move and exchange |
| 00110 | $06 | PUSH | Push to stack (PUSHD, PUSHDG, PUSHXY, PUSH #imm) |
| 00111 | $07 | POP | Pop from stack (POP, POPDG, POPXY, PUSHI) |
| 01000 | $08 | ADD | Addition |
| 01001 | $09 | ADC | Add with Carry |
| 01010 | $0A | SUB | Subtraction |
| 01011 | $0B | SBC | Subtract with Borrow |
| 01100 | $0C | AND | Bitwise AND |
| 01101 | $0D | OR | Bitwise OR |
| 01110 | $0E | XOR | Bitwise XOR |
| 01111 | $0F | NOT | Bitwise NOT (complement) |
| 10000 | $10 | CMP | Compare (sets flags, no store) |
| 10001 | $11 | Bcc | Conditional Branch (BEQ, BNE, BCS, BCC, BLT, BGT, BGE, BLE, BRA) |
| 10010 | $12 | JMP | Jump (JMP24, JMP16, JMPT, JMPXY) |
| 10011 | $13 | CALL/CALLXY | Subroutine (CALL24, CALL16, CALLR, CALLXY) |
| 10100 | $14 | LOADD | Load D register from memory |
| 10101 | $15 | LOADB | Load byte from memory (zero-extended) |
| 10110 | $16 | LOADX | Load X register from memory |
| 10111 | $17 | LOADY | Load Y register from memory |
| 11000 | $18 | LOADI | Load Immediate; LOADXY; LOADP/LOADPB (paged) |
| 11001 | $19 | STORED | Store D register to memory |
| 11010 | $1A | STOREB | Store byte to memory |
| 11011 | $1B | STOREX | Store X register to memory |
| 11100 | $1C | STOREY | Store Y register to memory |
| 11101 | $1D | STOREI | Store Immediate; STOREXY; STOREP/STOREPB (paged) |
| 11110 | $1E | TRAP/RET | Software trap/syscall (TRAP #n); Return from subroutine (RET, RET #nw) |
| 11111 | $1F | INT | Interrupt control (DINT, EINT, RTI, INT) |

### 1.4 Instruction Encoding

Most instructions use a common 16-bit format:

```
15  14  13  12  11  10   9   8   7   6   5   4   3   2   1   0
├───────────────┼───────┼───────────────────────────────────────┤
│    OPCODE     │ MODE  │           Operand Fields              │
│    5 bits     │ 2 bits│              9 bits                   │
└───────────────┴───────┴───────────────────────────────────────┘
```

Multi-word instructions extend with 16-bit immediate values (IMM16) or offsets.

---

## 2. Assembly Syntax

### 2.1 Line Format

```
[label:]  [mnemonic  [operands]]  [; comment]
```

All fields are optional. Blank lines and comment-only lines are permitted.

**Case Sensitivity:** Mnemonics, register names, and labels are case-insensitive. `LOADI`, `Loadi`, and `loadi` are equivalent. Labels `START`, `Start`, and `start` refer to the same symbol.

### 2.2 Labels

Labels mark memory locations and must end with a colon. They can contain letters, digits, and underscores, but must start with a letter or underscore.

```asm
start:      ; Define label 'start'
loop_1:     ; Labels can contain underscores and digits
_private:   ; Labels can start with underscore
```

#### Local Labels

Labels beginning with `.` are **local labels**, scoped to the nearest preceding global label. The same local name may be reused in every subroutine without conflict.

```asm
func_a:
        LOADI   D0, #1
        BEQ     .done       ; resolves to FUNC_A.DONE
.done:
        RET

func_b:
        LOADI   D0, #2
        BEQ     .done       ; resolves to FUNC_B.DONE — distinct from FUNC_A.DONE
.done:
        RET
```

The assembler stores qualified names in the symbol table (`FUNC_A.DONE`, `FUNC_B.DONE`) so they appear unambiguously in listings and error messages.

**Rules:**
- A local label must appear after at least one global label in the source file; defining one before any global label is an error.
- Local labels can be referenced both forward and backward within the same global scope.
- Local label references in expressions use the same `.name` syntax: `BRA .loop`, `LOADI D0, #.table`.

### 2.3 Comments

Comments begin with a semicolon and extend to end of line:

```asm
LOADI D0, #100    ; This is a comment
; This entire line is a comment
```

### 2.4 Numbers

The assembler supports decimal and hexadecimal numbers:

```asm
100       ; Decimal
$64       ; Hexadecimal (same value)
-5        ; Negative decimal
-$05      ; Negative hexadecimal
```

---

## 3. Registers

### 3.1 Register Overview

| Register | Type | Description |
|----------|------|-------------|
| D0-D3 | Data | 16-bit general purpose data registers |
| X0-X3 | Index | 16-bit index registers (low word of XY pair) |
| Y0-Y3 | Index | 8-bit index registers (high byte of XY pair, zero-extended to 16) |
| XY0-XY3 | Address | Combined 24-bit address registers (XY3 = stack pointer) |
| PC | Program Counter | 24-bit program counter |
| PCL | PC Low | Low 16 bits of program counter |
| PCH | PC High | High 8 bits (bank) of program counter |
| SR | Status | Status register (flags: C, Z, N, V) |
| ORDB | Internal | Output Register Data Bus (internal use) |

### 3.2 Typical Register Conventions

| Register | Common Usage |
|----------|--------------|
| D0 | Return value, primary accumulator |
| D1-D3 | Temporary values, loop counters |
| XY0-XY2 | General purpose pointers |
| XY3 | Stack pointer (hardcoded for CALL/RET/PUSH/POP) |

### 3.3 Status Register (SR)

The status register contains CPU flags and interrupt status information.

| Bit | Name | R/W | Description |
|-----|------|-----|-------------|
| 7 | IE | R | Interrupt Enable (1=enabled, 0=disabled) |
| 6:4 | LVL | R | Current interrupt priority level (0-7) |
| 3 | V | R/W | Overflow - set on signed overflow |
| 2 | N | R/W | Negative - set when result bit 15 is set |
| 1 | Z | R/W | Zero - set when result is zero |
| 0 | C | R/W | Carry - set on unsigned overflow/borrow |

**Interrupt fields (bits 7 and 6:4) are read-only.** Use DINT/EINT to change IE. The priority level comes directly from the 74LS148 encoder (IRQ7=0, IRQ0=7).

```asm
; Read status register
MOVE    D0, SR          ; D0 = full SR including interrupt bits

; Check if interrupts enabled
AND     D0, #$0080      ; Isolate IE bit
BNE     ints_enabled

; Get current interrupt level (0-7)
MOVE    D0, SR
AND     D0, #$0070      ; Isolate bits 6:4
SHR4    D0              ; D0 = 0-7
```

---

## 4. Assembler Directives

### 4.1 .ORG — Set Origin

Sets the assembly address. The address must be even (K16 is word-aligned). If no .ORG is specified, assembly begins at $000000.

```asm
.ORG $0100       ; Set origin to $0100
.ORG $1000       ; Continue assembly at $1000
```

### 4.2 .BASE — Set Image Base Address

Sets the base address for the output binary image. This determines how assembly addresses map to file offsets: `file_offset = assembly_address - base_address`.

Used when creating ROM images that will be loaded at a specific address. Without .BASE, the file offset equals the assembly address.

```asm
.BASE $F00000             ; ROM image base address
.ORG $FF0000              ; Reset vector - CPU starts here
```

In this example, code at $FF0000 appears at file offset $F0000 (= $FF0000 - $F00000).

**Typical ROM image setup:**
```asm
.BASE $F00000             ; 1MB ROM starts at $F00000
.ORG $FF0000              ; CPU reset vector
Start:
    LOADI D0, #0          ; First instruction at file offset $F0000
```

### 4.3 .EQU — Define Constant

Defines a symbolic constant. Supports expressions and 24-bit values ($000000-$FFFFFF).

```asm
BUFFER_SIZE  .EQU    256
HEADER       .EQU    16
TOTAL        .EQU    BUFFER_SIZE + HEADER    ; Expression
WORDS        .EQU    8w                      ; Word suffix (= 16)
VIDEO_RAM    .EQU    $0F0000                 ; 24-bit address
```

### 4.4 .WORD — Define Data Word

Emits one or more 16-bit data words. Supports expressions and symbols.

```asm
.WORD $1234              ; Single word
.WORD $0000, $FFFF       ; Multiple words
.WORD LABEL + 4          ; Expression
```

### 4.5 .TEXT — Define String

Emits ASCII text as packed words (2 characters per word). Strings are NOT automatically null-terminated. Two ways to add a null terminator:
- Use `\0` escape inside the string: `.TEXT "Hello\0"`
- Add `, 0` after the string: `.TEXT "Hello", 0`

If total byte count is odd, a null byte is added for word alignment (but this is padding, not a terminator).

```asm
.TEXT "Hello\0"           ; 3 words: "He", "ll", "o\0" (null-terminated)
.TEXT "Hello", 0          ; Same result
.TEXT "Hi", 0             ; 2 words: "Hi", "\0\0" (null + pad)
.TEXT "AB"                ; 1 word: "AB" (no terminator, word-aligned)
.TEXT "ABC"               ; 2 words: "AB", "C\0" (pad for alignment only)
```

**Escape Sequences:**

| Escape | Character |
|--------|-----------|
| `\0` | Null (NUL) |
| `\n` | Newline (LF) |
| `\r` | Carriage Return (CR) |
| `\t` | Tab |
| `\\` | Backslash |
| `\"` | Double Quote |
| `\xHH` | Hex byte |

```asm
.TEXT "Line 1\nLine 2\0"  ; String with embedded newline
.TEXT "Tab:\tValue", 0    ; String with tab
.TEXT "Say \"Hi\"\0"      ; String with embedded quotes
.TEXT "C:\\PATH\\FILE", 0 ; String with backslashes
.TEXT "\x1B[2J", 0        ; ANSI escape sequence
```

### 4.6 .BYTE — Define Byte Data

Emits one or more bytes. Values can be numeric literals, string literals, escape sequences, or any mix. Unlike `.TEXT`, the program counter advances by the **exact byte count** — it is not rounded to a word boundary. Use `.ALIGN` (see 4.7) after `.BYTE` if subsequent code or data must be word-aligned.

```asm
.BYTE   $41, $42            ; 2 bytes: 41 42
.BYTE   $41, $42, $43       ; 3 bytes: 41 42 43   (PC now odd)
.BYTE   "Hello"             ; 5 bytes: 48 65 6C 6C 6F
.BYTE   5, "Hello"          ; 6 bytes: length-prefixed Pascal string
.BYTE   "K16", 0            ; 4 bytes: null-terminated C string
.BYTE   "Line1\r\nLine2\0"  ; 13 bytes: escape sequences supported
```

**Escape sequences** are identical to `.TEXT` (see Section 4.5): `\0`, `\n`, `\r`, `\t`, `\\`, `\"`, `\xHH`.

### 4.7 .ALIGN — Align to Boundary

Advances the program counter to the next multiple of the specified boundary. If the PC is already aligned, nothing is emitted.

```asm
.ALIGN              ; align to next word boundary (default: 2 bytes)
.ALIGN  2           ; same — explicit word alignment
.ALIGN  4           ; align to 4-byte boundary
.ALIGN  16          ; align to 16-byte boundary
```

The boundary must be a power of 2. The default (no operand) is 2.

**Typical use:** after `.BYTE` directives with an odd byte count, to restore word alignment before the next instruction or `.WORD` directive.

```asm
table:  .BYTE   "ABC"       ; 3 bytes — PC now odd
        .ALIGN              ; pad 1 byte — PC now even
next:   .WORD   $1234       ; safe: word-aligned
```

### 4.8 .DS — Define Storage

Reserves a block of bytes, optionally filled with a constant value. The default fill is `$00`.

```asm
.DS     16              ; 16 zero bytes
.DS     16, $FF         ; 16 bytes of $FF
.DS     8w              ; 8 words = 16 bytes (word suffix supported)
.DS     8w, 0           ; same, explicit zero fill
.DS     0               ; valid no-op
```

`.DS` advances the PC by the exact byte count. Use `.ALIGN` afterward if word alignment is required. The fill value must be a byte (0–255).

**Typical use cases:**
```asm
LINE_BUF     .DS     80          ; 80-byte line input buffer
STACK_FRAME  .DS     8w, 0       ; 8-word (16-byte) zeroed stack frame
CHECKSUM     .DS     2, $FF      ; 2 sentinel bytes
```

### 4.9 .INCLUDE — Include Source File

Inserts the contents of another assembly source file at the point of the directive. The included file is processed exactly as if its lines appeared inline in the parent file. Includes are resolved before assembly begins.

```asm
.INCLUDE    "defs.asm"          ; relative to current file's directory
.INCLUDE    "lib/system.asm"    ; subdirectory
```

**Path resolution:** relative paths are resolved from the directory of the **file containing the `.INCLUDE`**, not the working directory. This means nested includes resolve correctly from their own file's location.

**Nesting:** includes may be nested up to 8 levels deep. Circular includes are detected and reported as errors.

**Listing:** included content is surrounded by banner comments in the listing output:
```
; === BEGIN INCLUDE "defs.asm" ===
LINE_WIDTH   .EQU   80
...
; === END INCLUDE "defs.asm" ===
```

**Error reporting:** errors within an included file are reported with the included filename and its original line number.

**Symbols:** all labels and constants defined in included files share the same symbol table as the main file. Local labels (Section 2.2) defined in an included file are scoped to the global label immediately preceding them, whether that global label is in the included file or the parent file.

### 4.10 .IF / .ENDIF — Conditional Assembly

Conditionally assembles a block of code based on the value of a previously defined constant. Used by the Pascal compiler's smart-link (`--dep`) mode to omit unreferenced procedures from the output.

```asm
FLAG    .EQU    1

        .IF FLAG
include_me:
        LOADI   D0, #42
        RET
        .ENDIF

SKIP    .EQU    0

        .IF SKIP
excluded:               ; label NOT added to symbol table
        LOADI   D0, #0  ; not assembled
        RET
        .ENDIF
```

**Syntax:**

```
        .IF  symbol
        ...
        .ENDIF
```

The operand must be a single symbol name. Expression evaluation is not supported in the condition.

**Behaviour:**

- If the symbol's value is **non-zero**, the block is assembled normally.
- If the symbol's value is **zero**, all lines between `.IF` and `.ENDIF` are skipped — no instructions are emitted and no labels are added to the symbol table.
- The symbol must be defined somewhere in the file (before or after the `.IF` — the assembler pre-scans all `.EQU` definitions before beginning the main assembly pass).
- If the symbol is not defined, it is an error in Pass 2. In Pass 1 the block is treated as included so labels are still collected.

**Nesting:** `.IF`/`.ENDIF` blocks may be nested. The assembler supports arbitrary nesting depth.

**No `ELSE`:** there is no `.ELSE` or `.ELSEIF` directive.

**Pascal compiler usage:** the compiler emits `__USE_procname .EQU 1` (or `0`) at file scope, then wraps each procedure body:

```asm
__USE_myfunc    .EQU    1

                .IF __USE_myfunc
myfunc:
                ; ... body ...
                RET
                .ENDIF
```

Setting a constant to `0` causes the entire procedure — including its entry label — to be absent from the assembled output.

---

## 5. Addressing Modes

### 5.1 Register Direct

Operand is a register.

```asm
MOVE D0, D1       ; D0 ← D1
ADD D0, X0        ; D0 ← D0 + X0
```

### 5.2 Immediate

Operand is a constant value prefixed with #.

```asm
LOADI D0, #100    ; D0 ← 100
LOADI D1, #$FF    ; D1 ← 255
ADD D0, #5        ; D0 ← D0 + 5 (IMM5, 0-31)
ADD D0, #$1234    ; D0 ← D0 + $1234 (IMM16)
```

**Automatic mode selection:** The assembler automatically chooses the smallest encoding. If an immediate value fits in 5 bits (0-31 unsigned), it uses IMM5 mode (single word). Larger values use IMM16 mode (two words). The actual mode used appears in the listing decode column.

### 5.3 Memory Indirect (Mode 00)

Operand is memory addressed by XY register pair.

```asm
LOADD D0, [XY0]         ; D0 ← memory[XY0]
STORED D0, [XY1]        ; memory[XY1] ← D0
```

### 5.4 Indexed with D Register (Mode 01)

Memory access with D register as offset.

```asm
LOADD D0, [XY0+D1]      ; D0 ← memory[XY0 + D1]
STORED D0, [XY1+D2]     ; memory[XY1 + D2] ← D0
```

### 5.5 PC-Relative (Mode 10)

Used for accessing constants and data tables relative to the program counter. Assembler calculates offset automatically when using labels.

```asm
LOADD D0, [PC+data]     ; Load from 'data' label
LOADD D1, [PC+#10]      ; Load from PC + 10 bytes
data: .WORD $1234
```

### 5.6 Indexed with Immediate (Mode 11)

Memory access with immediate constant offset.

```asm
LOADD D0, [XY0+#4]      ; D0 ← memory[XY0 + 4]
LOADD D0, [XY0+#2w]     ; D0 ← memory[XY0 + 4] (word suffix)
STORED D0, [XY1+#8]     ; memory[XY1 + 8] ← D0
```

---

## 6. Instruction Set

### 6.1 Data Movement

Data movement instructions transfer values between registers and memory.

#### LOADI — Load Immediate

Loads a constant value directly into a register.

**Opcode:** $18

| Mode | Syntax | Operation | Cycles | Words |
|------|--------|-----------|--------|-------|
| 00 | `LOADI reg, #imm5` | reg ← imm5 (0-31) | 2 | 1 |
| 01 | `LOADI reg, #imm16` | reg ← imm16 | 2 | 2 |

The assembler automatically selects IMM5 mode for values 0-31, or IMM16 mode for larger values.

```asm
LOADI D0, #$1F          ; Mode 00: D0 ← $1F (IMM5)
LOADI D0, #$1234        ; Mode 01: D0 ← $1234 (IMM16)
LOADI X0, #$1234        ; X0 ← $1234
LOADI Y0, #$56          ; Y0 ← $56
```

#### LOADD/LOADX/LOADY — Load from Memory

Loads a 16-bit word from memory into a D, X, or Y register.

**Opcodes:** $14 (LOADD), $16 (LOADX), $17 (LOADY)

| Mode | Syntax | Operation | Cycles | Words |
|------|--------|-----------|--------|-------|
| 00 | `LOADx reg, [XYn]` | reg ← mem[XYn] | 2 | 1 |
| 01 | `LOADx reg, [XYn+Dm]` | reg ← mem[XYn + Dm] | 3 | 1 |
| 10 | `LOADx reg, [PC+imm16]` | reg ← mem[PC + imm16] | 4 | 2 |
| 11 | `LOADx reg, [XYn+#imm5]` | reg ← mem[XYn + imm5] | 3 | 1 |

```asm
LOADD D0, [XY0]         ; Mode 00: D0 ← memory[XY0]
LOADD D1, [XY1+D0]      ; Mode 01: D1 ← memory[XY1 + D0]
LOADD D2, [PC+label]    ; Mode 10: D2 ← memory at label
LOADD D3, [XY3+#6]      ; Mode 11: D3 ← memory[XY3 + 6]
LOADX X0, [XY1]         ; Load to X register
LOADY Y0, [XY2]         ; Load to Y register
```

#### LOADB — Load Byte from Memory

Loads an 8-bit byte from memory, zero-extended to 16 bits.

**Opcode:** $15

| Mode | Syntax | Operation | Cycles | Words |
|------|--------|-----------|--------|-------|
| 00 | `LOADB reg, [XYn]` | reg ← mem[XYn] (byte) | 2 | 1 |
| 01 | `LOADB reg, [XYn+Dm]` | reg ← mem[XYn + Dm] (byte) | 3 | 1 |
| 10 | `LOADB reg, [PC+imm16]` | reg ← mem[PC + imm16] (byte) | 4 | 2 |
| 11 | `LOADB reg, [XYn+#imm5]` | reg ← mem[XYn + imm5] (byte) | 3 | 1 |

```asm
LOADB D0, [XY0]         ; D0 ← byte at XY0, zero-extended
LOADB D1, [XY1+D0]      ; D0 ← byte at XY1+D0
```

#### LOADXY — Load XY Pair from Memory

Loads a 24-bit XY register pair from two consecutive memory words.

**Opcode:** $18 (Mode 10)

| Mode | Syntax | Operation | Cycles | Words |
|------|--------|-----------|--------|-------|
| 10 | `LOADXY XYn, [XYm]` | XYn ← mem[XYm] (24-bit) | 4 | 1 |

Memory layout: Y at [XYm+0], X at [XYm+2].

```asm
LOADXY XY0, [XY2]       ; Load 24-bit pointer from memory
```

#### LOADP/LOADPB — Load from Paged Memory

Loads from banked memory using Y register as bank selector (bits 23-16).

**Opcode:** $18 (Mode 11)

| Mode | Syntax | Operation | Cycles | Words |
|------|--------|-----------|--------|-------|
| 11 | `LOADP reg, Yn, [#imm16]` | reg ← mem[Yn:imm16] (word) | 3 | 2 |
| 11 | `LOADPB reg, Yn, [#imm16]` | reg ← mem[Yn:imm16] (byte) | 3 | 2 |

```asm
LOADI   Y0, #$20              ; Bank $20
LOADP   D0, Y0, [#$0400]      ; D0 ← word from $20:0400
LOADPB  D1, Y0, [#$0402]      ; D1 ← byte from $20:0402
```

#### STORED/STOREX/STOREY — Store to Memory

Stores a 16-bit word from a D, X, or Y register to memory.

**Opcodes:** $19 (STORED), $1B (STOREX), $1C (STOREY)

| Mode | Syntax | Operation | Cycles | Words |
|------|--------|-----------|--------|-------|
| 00 | `STOREx reg, [XYn]` | mem[XYn] ← reg | 3 | 1 |
| 01 | `STOREx reg, [XYn+Dm]` | mem[XYn + Dm] ← reg | 4 | 1 |
| 10 | `STOREx reg, [PC+imm16]` | mem[PC + imm16] ← reg | 4 | 2 |
| 11 | `STOREx reg, [XYn+#imm5]` | mem[XYn + imm5] ← reg | 4 | 1 |

```asm
STORED D0, [XY0]        ; Mode 00: memory[XY0] ← D0
STORED D1, [XY1+D0]     ; Mode 01: memory[XY1 + D0] ← D1
STORED D2, [PC+label]   ; Mode 10: memory at label ← D2
STORED D3, [XY3+#6]     ; Mode 11: memory[XY3 + 6] ← D3
STOREX X0, [XY1]        ; Store X register
STOREY Y0, [XY2]        ; Store Y register
```

#### STOREB — Store Byte to Memory

Stores the low 8 bits of a register to memory.

**Opcode:** $1A

| Mode | Syntax | Operation | Cycles | Words |
|------|--------|-----------|--------|-------|
| 00 | `STOREB reg, [XYn]` | mem[XYn] ← reg (byte) | 3 | 1 |
| 01 | `STOREB reg, [XYn+Dm]` | mem[XYn + Dm] ← reg (byte) | 4 | 1 |
| 10 | `STOREB reg, [PC+imm16]` | mem[PC + imm16] ← reg (byte) | 4 | 2 |
| 11 | `STOREB reg, [XYn+#imm5]` | mem[XYn + imm5] ← reg (byte) | 4 | 1 |

```asm
STOREB D0, [XY0]        ; Store low byte of D0
```

#### STOREI — Store Immediate to Memory

Stores a constant value directly to memory.

**Opcode:** $1D

| Mode | Syntax | Operation | Cycles | Words |
|------|--------|-----------|--------|-------|
| 00 | `STOREI #imm5, [XYn]` | mem[XYn] ← imm5 | 2 | 1 |
| 01 | `STOREI #imm16, [XYn]` | mem[XYn] ← imm16 | 3 | 2 |

```asm
STOREI #0, [XY0]        ; Clear memory word
STOREI #$1234, [XY1]    ; Store constant to memory
```

#### STOREXY — Store XY Pair to Memory

Stores a 24-bit XY register pair to two consecutive memory words.

**Opcode:** $1D (Mode 10)

| Mode | Syntax | Operation | Cycles | Words |
|------|--------|-----------|--------|-------|
| 10 | `STOREXY XYn, [XYm]` | mem[XYm] ← XYn (24-bit) | 6 | 1 |

Memory layout: Y at [XYm+0], X at [XYm+2].

```asm
STOREXY XY0, [XY2]      ; Store 24-bit pointer to memory
```

#### STOREP/STOREPB — Store to Paged Memory

Stores to banked memory using Y register as bank selector (bits 23-16).

**Opcode:** $1D (Mode 11)

| Mode | Syntax | Operation | Cycles | Words |
|------|--------|-----------|--------|-------|
| 11 | `STOREP reg, Yn, [#imm16]` | mem[Yn:imm16] ← reg (word) | 5 | 2 |
| 11 | `STOREPB reg, Yn, [#imm16]` | mem[Yn:imm16] ← reg (byte) | 5 | 2 |

```asm
LOADI   Y0, #$20              ; Bank $20
STOREP  D0, Y0, [#$0400]      ; Word to $20:0400
STOREPB D0, Y0, [#$0402]      ; Byte to $20:0402
```

#### MOVE — Register to Register Transfer

Copies data between registers.

**Opcode:** $05

| Mode | Syntax | Operation | Cycles | Words |
|------|--------|-----------|--------|-------|
| 00 | `MOVE dst, Dn` | dst ← Dn | 3 | 1 |
| 01 | `MOVE dst, src` | dst ← src (X/Y/PC/SR) | 3 | 1 |

```asm
MOVE D1, D0             ; D1 ← D0
MOVE X0, D0             ; X0 ← D0
MOVE D0, X0             ; D0 ← X0
MOVE D0, SR             ; D0 ← Status Register
MOVE SR, D0             ; Status Register ← D0
MOVE PC, D0             ; Jump to address in D0
```

#### SWAP — Exchange Two Registers

Exchanges the contents of two registers.

**Opcode:** $05

| Mode | Syntax | Operation | Cycles | Words |
|------|--------|-----------|--------|-------|
| 10 | `SWAP Dn, Xn/Yn` | Dn ↔ Xn/Yn | 4 | 1 |
| 11 | `SWAP Xn/Yn, Xn/Yn` | Xn/Yn ↔ Xn/Yn | 4 | 1 |

```asm
SWAP D0, X0             ; D0 ↔ X0
SWAP D1, Y0             ; D1 ↔ Y0
SWAP X0, X2             ; X0 ↔ X2
SWAP X0, Y0             ; X0 ↔ Y0
```

### 6.2 Load Effective Address (LEA)

LEA calculates a 24-bit effective address and stores the result in an XY register pair without performing a memory access. This enables efficient pointer arithmetic, array indexing, and address calculations with automatic carry propagation.

**Opcode:** $03

| Mode | Syntax | Operation | Cycles | Words |
|------|--------|-----------|--------|-------|
| 00 | `LEA XYn, XYm` | XYn = XYm (copy) | 5 | 1 |
| 01 | `LEA XYn, XYm+Do` | XYn = XYm + Do | 5 | 1 |
| 10 | `LEA XYn, label` | XYn = PC + offset | 6 | 2 |
| 11 | `LEA XYn, XYm+#imm5` | XYn = XYm + imm5 | 5 | 1 |

**Bracket-free syntax:** LEA uses no brackets to distinguish it from LOAD/STORE memory operations:

```asm
LEA  XY0, XY1+D2      ; Calculate address (no memory access)
LOAD D0, [XY1+D2]     ; Access memory at address
```

#### Mode 00: Copy XY Pair

```asm
LEA XY0, XY1          ; XY0 ← XY1 (copy 24-bit pointer)
LEA XY2, XY3          ; XY2 ← XY3 (copy stack pointer)
```

#### Mode 01: Dynamic Index (XY + D Register)

```asm
LEA XY0, XY1+D0       ; XY0 ← XY1 + D0 (array indexing)
LEA XY2, XY2+D3       ; XY2 ← XY2 + D3 (advance by variable)
```

24-bit arithmetic with carry from X to Y enables correct bank crossing:

```asm
; XY1 = $05:FF00, D2 = $0200
LEA XY0, XY1+D2       ; XY0 = $06:0100 (crossed into bank 6)
```

#### Mode 10: PC-Relative (Label)

```asm
LEA XY0, DataTable    ; XY0 ← 24-bit address of DataTable
LEA XY1, MyString     ; XY1 ← 24-bit address of MyString
```

More efficient than loading address halves separately:

```asm
; LEA version: 2 words, 6 cycles
LEA XY0, SineTable

; LOADI version: 4 words, 4 cycles
LOADI X0, #<SineTable
LOADI Y0, #>SineTable
```

#### Mode 11: Immediate Offset (XY + IMM5)

```asm
LEA XY0, XY3+#2       ; XY0 ← stack pointer + 2
LEA XY1, XY0+#8       ; XY1 ← XY0 + 8 (structure field)
LEA XY2, XY3+#20      ; XY2 ← XY3 + 20 (local variable)
```

IMM5 range: 0-31

#### LEA Examples

```asm
; Array element address: &array[index]
; XY0 = array base, D1 = index * element_size
LEA XY1, XY0+D1       ; XY1 = &array[index]

; Structure field access
LEA XY1, XY0+#8       ; XY1 = &struct->field

; Stack frame local variable
LEA XY0, XY3+#4       ; XY0 = &local_var

; Forth dictionary traversal
LOADD D2, [XY0]       ; D2 = link offset
LEA XY0, XY0+D2       ; XY0 = next entry (crosses banks correctly)
```

#### LEA vs INC/DEC

| Feature | INC/DEC | LEA |
|---------|---------|-----|
| Constant offset 1-31 | ✓ INC 5 / DEC 6 cycles | ✓ 5 cycles |
| Variable offset | ✗ | ✓ Mode 01 |
| Copy XY pair | ✗ | ✓ Mode 00 |
| PC-relative label | ✗ | ✓ Mode 10 |
| Different src/dst | ✗ (in-place only) | ✓ All modes |

Use **INC/DEC** for simple in-place adjustments. Use **LEA** for calculated addresses, different destination, or PC-relative labels.

### 6.3 Arithmetic Operations

Arithmetic operations perform addition, subtraction, and increment/decrement with flag updates.

#### ADD — Addition

Adds source to destination.

**Opcode:** $08

| Mode | Syntax | Operation | Cycles | Words |
|------|--------|-----------|--------|-------|
| 00 | `ADD dst, src` | dst ← dst + src | 4 | 1 |
| 01 | `ADD dst, [XYn]` | dst ← dst + mem[XYn] | 4 | 1 |
| 10 | `ADD dst, #imm5` | dst ← dst + imm5 | 3 | 1 |
| 11 | `ADD dst, #imm16` | dst ← dst + imm16 | 4 | 2 |

**Flags:** C, Z, N, V

```asm
ADD D0, D1              ; D0 ← D0 + D1
ADD D0, [XY0]           ; D0 ← D0 + memory[XY0]
ADD D0, #5              ; D0 ← D0 + 5 (IMM5)
ADD D0, #$1234          ; D0 ← D0 + $1234 (IMM16)
```

#### ADC — Add with Carry

Adds source and carry flag to destination.

**Opcode:** $09

| Mode | Syntax | Operation | Cycles | Words |
|------|--------|-----------|--------|-------|
| 00 | `ADC dst, src` | dst ← dst + src + C | 4 | 1 |
| 01 | `ADC dst, [XYn]` | dst ← dst + mem[XYn] + C | 4 | 1 |
| 10 | `ADC dst, #imm5` | dst ← dst + imm5 + C | 3 | 1 |
| 11 | `ADC dst, #imm16` | dst ← dst + imm16 + C | 4 | 2 |

**Flags:** C, Z, N, V

```asm
ADC D0, D1              ; D0 ← D0 + D1 + Carry
ADC D0, #0              ; D0 ← D0 + Carry (propagate carry)
```

#### SUB — Subtraction

Subtracts source from destination.

**Opcode:** $0A

| Mode | Syntax | Operation | Cycles | Words |
|------|--------|-----------|--------|-------|
| 00 | `SUB dst, src` | dst ← dst - src | 4 | 1 |
| 01 | `SUB dst, [XYn]` | dst ← dst - mem[XYn] | 4 | 1 |
| 10 | `SUB dst, #imm5` | dst ← dst - imm5 | 4 | 1 |
| 11 | `SUB dst, #imm16` | dst ← dst - imm16 | 4 | 2 |

**Flags:** C, Z, N, V (C=0 indicates borrow)

```asm
SUB D0, D1              ; D0 ← D0 - D1
SUB D0, #10             ; D0 ← D0 - 10
```

#### SBC — Subtract with Borrow

Subtracts source and borrow from destination.

**Opcode:** $0B

| Mode | Syntax | Operation | Cycles | Words |
|------|--------|-----------|--------|-------|
| 00 | `SBC dst, src` | dst ← dst - src - ~C | 4 | 1 |
| 01 | `SBC dst, [XYn]` | dst ← dst - mem[XYn] - ~C | 4 | 1 |
| 10 | `SBC dst, #imm5` | dst ← dst - imm5 - ~C | 4 | 1 |
| 11 | `SBC dst, #imm16` | dst ← dst - imm16 - ~C | 4 | 2 |

**Flags:** C, Z, N, V

```asm
SBC D0, D1              ; D0 ← D0 - D1 - borrow
SBC D0, #0              ; D0 ← D0 - borrow (propagate borrow)
```

#### INC — Increment

Increments a register or XY pair.

**Opcode:** $02 (XY pairs) or syntax sugar for ADD (D/X/Y)

| Operand | Syntax | Operation | Cycles | Words |
|---------|--------|-----------|--------|-------|
| Dn/Xn/Yn | `INC reg` | reg ← reg + 1 | 3 | 1 |
| Dn/Xn/Yn | `INC reg, #imm` | reg ← reg + imm | 3 | 1-2 |
| XYn | `INC XYn` | XYn ← XYn + 2 | 5 | 1 |
| XYn | `INC XYn, #imm5` | XYn ← XYn + imm5 | 5 | 1 |

**Flags:** D/X/Y sets flags via ADD. **XY version trashes all flags.**

```asm
INC D0                  ; D0 ← D0 + 1 (→ ADD D0, #1)
INC XY0                 ; XY0 ← XY0 + 2 (24-bit, default word)
INC XY0, #1             ; XY0 ← XY0 + 1 (byte increment)
```

#### DEC — Decrement

Decrements a register or XY pair.

**Opcode:** $02 (XY pairs) or syntax sugar for SUB (D/X/Y)

| Operand | Syntax | Operation | Cycles | Words |
|---------|--------|-----------|--------|-------|
| Dn/Xn/Yn | `DEC reg` | reg ← reg - 1 | 3-4 | 1 |
| Dn/Xn/Yn | `DEC reg, #imm` | reg ← reg - imm | 3-4 | 1-2 |
| XYn | `DEC XYn` | XYn ← XYn - 2 | 6 | 1 |
| XYn | `DEC XYn, #imm5` | XYn ← XYn - imm5 | 6 | 1 |

**Flags:** D/X/Y sets flags via SUB. **XY version trashes all flags.**

```asm
DEC D0                  ; D0 ← D0 - 1 (→ SUB D0, #1)
DEC XY0                 ; XY0 ← XY0 - 2 (24-bit, default word)
DEC XY0, #1             ; XY0 ← XY0 - 1 (byte decrement)
```

**⚠ WARNING: INC/DEC XY Trashes Flags**

INC and DEC on XY pairs corrupt all CPU flags (C, Z, N, V). Do not place INC/DEC XY between a comparison and a conditional branch:

```asm
; WRONG - flags trashed!
        CMP     D0, D1
        INC     XY0             ; Trashes flags from CMP!
        BEQ     equal           ; Will not work correctly

; CORRECT - branch before pointer update
        CMP     D0, D1
        BNE     not_equal
        INC     XY0
not_equal:
```

**⚠ WARNING: INC XYn defaults to +2 (word), not +1 (byte)**

`INC XYn` without an immediate increments by 2 — the natural word step for K16. For byte array or string traversal, always use `INC XYn, #1`:

```asm
; WRONG - skips every other byte!
        LOADB   D0, [XY0]
        INC     XY0             ; advances by 2, skips a byte

; CORRECT - byte-by-byte traversal
        LOADB   D0, [XY0]
        INC     XY0, #1         ; advances by 1

; CORRECT - word-by-word traversal (explicit is clearer)
        LOADD   D0, [XY0]
        INC     XY0             ; advances by 2 (or INC XY0, #2)
```

#### NEG — Two's Complement Negate

Negates a register (two's complement). Equivalent to `0 - src`.

**Opcode:** $00, **Mode:** 11

| Mode | Syntax | Operation | Cycles | Words |
|------|--------|-----------|--------|-------|
| 11 | `NEG dst, src` | dst ← -src | 3 | 1 |
| 11 | `NEG dst` | dst ← -dst (in-place, src=dst) | 3 | 1 |

**Flags:** C, Z, N, V

| Flag | Condition |
|------|-----------|
| Z | Set if result = 0 |
| N | Set if result bit 15 = 1 |
| C | Clear if src ≠ 0 (borrow); Set if src = 0 |
| V | Set if src = $8000 (overflow: -(-32768) unrepresentable) |

```asm
NEG     D0              ; D0 ← -D0  (in-place)
NEG     D0, D1          ; D0 ← -D1
NEG     D0, D2          ; D0 ← -D2
```

**Note:** Equivalent to `NOT dst; ADD dst, #1` but in a single instruction.

---

### 6.4 Logical Operations

Bitwise logical operations on registers and memory.

#### AND — Bitwise AND

**Opcode:** $0C

| Mode | Syntax | Operation | Cycles | Words |
|------|--------|-----------|--------|-------|
| 00 | `AND dst, src` | dst ← dst AND src | 4 | 1 |
| 01 | `AND dst, [XYn]` | dst ← dst AND mem[XYn] | 4 | 1 |
| 10 | `AND dst, #imm5` | dst ← dst AND imm5 | 3 | 1 |
| 11 | `AND dst, #imm16` | dst ← dst AND imm16 | 4 | 2 |

**Flags:** C (cleared), Z, N

```asm
AND D0, D1              ; D0 ← D0 AND D1
AND D0, #$1F            ; D0 ← D0 AND $1F (mask low 5 bits)
AND D0, #$FF00          ; D0 ← D0 AND $FF00 (keep high byte)
```

#### OR — Bitwise OR

**Opcode:** $0D

| Mode | Syntax | Operation | Cycles | Words |
|------|--------|-----------|--------|-------|
| 00 | `OR dst, src` | dst ← dst OR src | 4 | 1 |
| 01 | `OR dst, [XYn]` | dst ← dst OR mem[XYn] | 4 | 1 |
| 10 | `OR dst, #imm5` | dst ← dst OR imm5 | 3 | 1 |
| 11 | `OR dst, #imm16` | dst ← dst OR imm16 | 4 | 2 |

**Flags:** C (cleared), Z, N

```asm
OR D0, D1               ; D0 ← D0 OR D1
OR D0, #$01             ; Set bit 0
OR D0, #$8000           ; Set bit 15
```

#### XOR — Bitwise Exclusive OR

**Opcode:** $0E

| Mode | Syntax | Operation | Cycles | Words |
|------|--------|-----------|--------|-------|
| 00 | `XOR dst, src` | dst ← dst XOR src | 4 | 1 |
| 01 | `XOR dst, [XYn]` | dst ← dst XOR mem[XYn] | 4 | 1 |
| 10 | `XOR dst, #imm5` | dst ← dst XOR imm5 | 3 | 1 |
| 11 | `XOR dst, #imm16` | dst ← dst XOR imm16 | 4 | 2 |

**Flags:** C (cleared), Z, N

```asm
XOR D0, D1              ; D0 ← D0 XOR D1
XOR D0, D0              ; D0 ← 0 (fast clear)
XOR D0, #$FFFF          ; D0 ← NOT D0 (complement)
```

#### NOT — Bitwise Complement

**Opcode:** $0F

| Mode | Syntax | Operation | Cycles | Words |
|------|--------|-----------|--------|-------|
| 00 | `NOT dst, src` | dst ← NOT src | 4 | 1 |
| 01 | `NOT dst, [XYn]` | dst ← NOT mem[XYn] | 4 | 1 |
| 10 | `NOT dst` | dst ← NOT dst (in-place) | 4 | 1 |

**Flags:** C (cleared), Z, N

```asm
NOT D0, D1              ; D0 ← NOT D1
NOT D0                  ; D0 ← NOT D0 (in-place)
```

### 6.5 Shift and Rotate (LOOKUP)

Shift, rotate, and byte manipulation operations implemented via ROM lookup tables.

**Opcode:** $01

| Mode | Syntax | Operation | Cycles | Words |
|------|--------|-----------|--------|-------|
| — | `SHL Dn` | Dn ← Dn << 1 | 3 | 1 |
| — | `SHR Dn` | Dn ← Dn >> 1 (logical) | 3 | 1 |
| — | `ASR Dn` | Dn ← Dn >> 1 (arithmetic) | 3 | 1 |
| — | `ROL Dn` | Dn ← rotate left through C | 3 | 1 |
| — | `ROR Dn` | Dn ← rotate right through C | 3 | 1 |
| — | `SWAPB Dn` | Dn ← byte swap | 3 | 1 |
| — | `HIGH Dn` | Dn ← Dn >> 8 | 3 | 1 |
| — | `LOW Dn` | Dn ← Dn AND $00FF | 3 | 1 |
| — | `SHL4 Dn` | Dn ← Dn << 4 | 3 | 1 |
| — | `SHR4 Dn` | Dn ← Dn >> 4 (logical) | 3 | 1 |
| — | `ASR4 Dn` | Dn ← Dn >> 4 (arithmetic) | 3 | 1 |
| — | `ASR8 Dn` | Dn ← Dn >> 8 (arithmetic) | 3 | 1 |
| — | `MULB Dn` | Dn ← hi_byte × lo_byte | 3 | 1 |
| — | `RECIP Dn` | Dn ← 65536 / Dn | 3 | 1 |
| — | `LOOKUP Dn, #page` | Dn ← table[Dn] | 3 | 1 |

**Flags:** Not affected

**Lookup Table Pages:**

| Mnemonic | Page | Address Range | Operation |
|----------|------|---------------|-----------|
| SHL | $E0 | $E0_0000-$E1_FFFF | Shift left 1 bit (×2) |
| SHR | $E2 | $E2_0000-$E3_FFFF | Shift right 1 bit (÷2 unsigned) |
| ASR | $E4 | $E4_0000-$E5_FFFF | Arithmetic shift right 1 (÷2 signed) |
| ROL | $E6 | $E6_0000-$E7_FFFF | Rotate left through carry |
| ROR | $E8 | $E8_0000-$E9_FFFF | Rotate right through carry |
| SWAPB | $EA | $EA_0000-$EB_FFFF | Byte swap ($1234 → $3412) |
| HIGH | $EC | $EC_0000-$ED_FFFF | Extract high byte (D >> 8) |
| LOW | $EE | $EE_0000-$EF_FFFF | Extract low byte (D AND $00FF) |
| SHR4 | $F0 | $F0_0000-$F1_FFFF | Shift right 4 bits (÷16 unsigned) |
| SHL4 | $F2 | $F2_0000-$F3_FFFF | Shift left 4 bits (×16) |
| ASR4 | $F4 | $F4_0000-$F5_FFFF | Arithmetic shift right 4 (÷16 signed) |
| ASR8 | $F6 | $F6_0000-$F7_FFFF | Arithmetic shift right 8 (÷256 signed) |
| MULB | $F8 | $F8_0000-$F9_FFFF | Multiply hi byte × lo byte |
| RECIP | $FA | $FA_0000-$FB_FFFF | Reciprocal (65536 ÷ D) |

```asm
SHL D0                  ; D0 ← D0 × 2
SHR D0                  ; D0 ← D0 ÷ 2 (unsigned)
ASR D0                  ; D0 ← D0 ÷ 2 (signed)
SWAPB D0                ; D0 ← byte-swapped ($1234 → $3412)
HIGH D0                 ; D0 ← high byte ($1234 → $0012)
LOW D0                  ; D0 ← low byte ($1234 → $0034)
SHL4 D0                 ; D0 ← D0 × 16
MULB D0                 ; D0 ← hi_byte(D0) × lo_byte(D0)
RECIP D0                ; D0 ← 65536 / D0
LOOKUP D0, #$E0         ; Same as SHL D0
LOOKUP D0, #$10         ; Custom table at page $10 (RAM)
```

### 6.6 Compare

Compares two values by performing subtraction and setting flags, without storing the result.

**Opcode:** $10

| Mode | Syntax | Operation | Cycles | Words |
|------|--------|-----------|--------|-------|
| 00 | `CMP dst, src` | flags ← dst - src | 3 | 1 |
| 01 | `CMP dst, [XYn]` | flags ← dst - mem[XYn] | 3 | 1 |
| 10 | `CMP dst, #imm5` | flags ← dst - imm5 | 3 | 1 |
| 11 | `CMP dst, #imm16` | flags ← dst - imm16 | 3 | 2 |

**Flags:** C, Z, N, V

```asm
CMP D0, D1              ; Compare D0 with D1
CMP D0, [XY0]           ; Compare D0 with memory
CMP D0, #0              ; Test for zero
CMP D0, #$1234          ; Compare with constant
```

### 6.7 Conditional Set (Scc)

Sets a register based on CPU flags: `$FFFF` if condition true, else a specified value.

**Opcode:** $04

| Mode | Syntax | Operation | Cycles | Words |
|------|--------|-----------|--------|-------|
| 00 | `Scc dst` | dst ← $FFFF or $0000 | 4 | 2 |
| 00 | `Scc dst, #imm16` | dst ← $FFFF or imm16 | 4 | 2 |

**Conditions:**

| Mnemonic | Code | Condition | Description |
|----------|------|-----------|-------------|
| SEQ | 000 | Z = 1 | Set if Equal / Zero |
| SNE | 001 | Z = 0 | Set if Not Equal |
| SCS/SHS | 010 | C = 1 | Set if Carry Set / Unsigned >= |
| SCC/SLO | 011 | C = 0 | Set if Carry Clear / Unsigned < |
| SLT | 100 | N ≠ V | Set if Less Than (signed) |
| SGT | 101 | Z=0 ∧ N=V | Set if Greater Than (signed) |
| SGE | 110 | N = V | Set if Greater or Equal (signed) |
| SLE | 111 | Z=1 ∨ N≠V | Set if Less or Equal (signed) |

**Flags:** Not affected

```asm
CMP     D0, D1
SEQ     D2              ; D2 = $FFFF if equal, else $0000
SNE     D2, #$0005      ; D2 = $FFFF if not equal, else 5
SLT     D0              ; D0 = $FFFF if D0 < D1 (signed)
SGT     D1              ; D1 = $FFFF if D0 > D1 (signed)
```

### 6.8 Branch Instructions

Conditional and unconditional branches with short (5-bit) and long (16-bit) offset forms.

**Opcode:** $11

| Mode | Syntax | Operation | Cycles | Words |
|------|--------|-----------|--------|-------|
| 00 | `Bcc.S target` | if cond: PC ← PC + imm5 | 3 | 1 |
| 01 | `Bcc.L target` | if cond: PC ← PC + imm16 | 4 | 2 |
| 10 | `BRA.S target` | PC ← PC + imm5 | 3 | 1 |
| 11 | `BRA.L target` | PC ← PC + imm16 | 4 | 2 |

**Conditions:**

| Mnemonic | Code | Condition | After CMP A,B |
|----------|------|-----------|---------------|
| BEQ | 000 | Z = 1 | A = B |
| BNE | 001 | Z = 0 | A ≠ B |
| BCS/BHS | 010 | C = 1 | A >= B (unsigned) |
| BCC/BLO | 011 | C = 0 | A < B (unsigned) |
| BLT | 100 | N ≠ V | A < B (signed) |
| BGT | 101 | Z=0 ∧ N=V | A > B (signed) |
| BGE | 110 | N = V | A >= B (signed) |
| BLE | 111 | Z=1 ∨ N≠V | A <= B (signed) |

**Flags:** Not affected

```asm
        CMP     D0, D1
        BEQ     equal           ; Branch if equal
        BLT     less            ; Branch if D0 < D1 (signed)
        BCS     ge_unsigned     ; Branch if D0 >= D1 (unsigned)
        BRA     always          ; Unconditional branch
```

### 6.9 Jump

Unconditional jumps to absolute, indirect, or table-based addresses.

**Opcode:** $12

| Mode | Syntax | Operation | Cycles | Words |
|------|--------|-----------|--------|-------|
| 00 | `JMP24 addr` | PC ← addr24 | 2 | 3 |
| 01 | `JMP16 addr` | PC[15:0] ← addr16 | 2 | 2 |
| 10 | `JMPT XYn, Dm` | PC ← mem[XYn + Dm] | 4 | 1 |
| 11 | `JMPXY XYn` | PC ← XYn | 3 | 1 |

**Flags:** Not affected

```asm
JMP     label           ; 24-bit absolute (alias for JMP24)
JMP24   #$123456        ; Jump anywhere in 16MB
JMP16   label           ; 16-bit, current page
JMPT    XY0, D0         ; Jump table: PC ← mem[XY0 + D0]
JMPXY   XY0             ; Indirect: PC ← XY0
```

### 6.10 Subroutine Call and Return

Subroutine call and return using XY3 as the hardcoded stack pointer.

**Opcode:** $13 (CALL/CALLXY)

| Mode | Syntax | Operation | Cycles | Words |
|------|--------|-----------|--------|-------|
| 00 | `CALL24 addr` | push PC; PC ← addr24 | 11 | 3 |
| 01 | `CALL16 addr` | push PC; PC[15:0] ← addr16 | 11 | 2 |
| 10 | `CALLR addr` | push PC; PC ← PC + offset | 12 | 2 |
| 11 | `CALLXY XYn` | push PC; PC ← XYn | 10 | 1 |

**Flags:** Not affected

```asm
CALL    subroutine      ; 24-bit absolute (alias for CALL24)
CALL24  subroutine      ; 24-bit absolute address
CALL16  subroutine      ; 16-bit, current codepage
CALLR   subroutine      ; PC-relative
CALLXY  XY0             ; Indirect call via XY register
```

**Note:** All CALL variants push a 24-bit return address to XY3 and return with `RET` (opcode $1E mode 11). See section 6.11.

### 6.11 TRAP and RET

Software syscall and return from subroutine.

**Opcode:** $1E (TRAP/RET)

| Mode | Syntax | Operation | Cycles | Words |
|------|--------|-----------|--------|-------|
| 00 | `TRAP #n` | push PC; PC ← vector[n] | 12 | 1 |
| 11 | `RET` | PC ← pop; SP += 4 | 5 | 1 |
| 11 | `RET #nw` | PC ← pop; SP += 4 + (n×2) | 5 | 1 |

**Flags:** Not affected

#### TRAP Encoding

IR[7:0] = n×2, n in 0..127. Instruction word = `$F000 or (n*2)`.

| Instruction | Encoding |
|-------------|----------|
| `TRAP #0` | `$F000` |
| `TRAP #1` | `$F002` |
| `TRAP #9` | `$F012` |
| `TRAP #127` | `$F0FE` |

#### RET Encoding

Opcode `$1E` mode `11`. IMM5 = 4 + (cleanup_words × 2). Base word = `$F66C` (no cleanup).

| Instruction | Encoding | Stack adjustment |
|-------------|----------|-----------------|
| `RET` | `$F66C` | SP += 4 |
| `RET #1w` | `$F66E` | SP += 6 |
| `RET #2w` | `$F670` | SP += 8 |
| `RET #4w` | `$F674` | SP += 12 |

#### Vector Table

Each entry is 4 bytes in the stack page [Y3]: page byte at offset+0 (word-aligned, high byte unused), address word at offset+2. Vector for TRAP #n is at [Y3: n×4].

```
[Y3:$0000]  TRAP #0    INT dispatcher (microcode also jumps here on hardware INT)
[Y3:$0004]  TRAP #1    IRQ0 handler (lowest priority)
[Y3:$0008]  TRAP #2    IRQ1 handler
[Y3:$000C]  TRAP #3    IRQ2 handler
[Y3:$0010]  TRAP #4    IRQ3 handler
[Y3:$0014]  TRAP #5    IRQ4 handler
[Y3:$0018]  TRAP #6    IRQ5 handler
[Y3:$001C]  TRAP #7    IRQ6 handler
[Y3:$0020]  TRAP #8    IRQ7 handler (highest priority, typically timer)
[Y3:$0024]  TRAP #9    first syscall
...
[Y3:$01FC]  TRAP #127  last syscall
```

#### Stack Effect

```
Before TRAP:          After TRAP:
                      [X3+0]: PC[23:16]  ← new top
                      [X3+2]: PC[15:0]
[old X3]              [old X3]
```

SP decremented by 4. No SR pushed, IE unchanged. Handler returns with `RET`.

#### Syscall Convention

TRAP handlers follow the K16 V2 calling convention:

| Register | Role |
|----------|------|
| D0 | 1st argument / return value |
| D1 | 2nd argument |
| D2 | 3rd argument |
| XY0, XY1 | Caller-saved scratch |
| XY2 | Callee-saved frame pointer cache |

4th+ arguments pushed to XY3 stack at [X3+4] after TRAP pushes return address.

#### Example — Installing and Calling a Handler

```asm
; OS boot: install TRAP #9 handler (putchar)
        LOADI   Y0, #$00
        LOADI   X0, #$0024
        LOADI   D0, #>putchar
        STORED  D0, [XY0]           ; store page byte
        LOADI   X0, #$0026
        LOADI   D0, #<putchar
        STORED  D0, [XY0]           ; store address word

; User code: call putchar via TRAP
        LOADI   D0, #'A'
        TRAP    #9                  ; putchar(D0)

; Handler
putchar:
        STOREB  D0, [XY1]           ; write to terminal
        RET
```

### 6.12 Stack Operations

Push and pop operations for saving/restoring registers.

**Opcodes:** $06 (PUSH), $07 (POP)

| Mode | Syntax | Operation | Cycles | Words |
|------|--------|-----------|--------|-------|
| 00 | `PUSH reg, XYs` | SP -= 2; mem[SP] ← reg | 5 | 1 |
| 01 | `PUSH D, XYs` | Push D0-D3 (4 words) | 14 | 1 |
| 10 | `PUSH XYn, XYs` | Push XY pair (2 words) | 8 | 1 |
| 11 | `PUSH #imm, XYs` | Push immediate | 5 | 1-2 |
| 00 | `POP reg, XYs` | reg ← mem[SP]; SP += 2 | 4 | 1 |
| 01 | `POP D, XYs` | Pop D3-D0 (4 words) | 10 | 1 |
| 10 | `POP XYn, XYs` | Pop XY pair (2 words) | 6 | 1 |

**Flags:** Not affected (except POP SR)

```asm
PUSH D0, XY3            ; Push single register
PUSH D, XY3             ; Push all D0-D3
PUSH XY0, XY3           ; Push XY pair
PUSH #$1234, XY3        ; Push immediate
PUSH D0                 ; Default stack XY3
POP  D0, XY3            ; Pop single register
POP  D, XY3             ; Pop D3-D0 (reverse order)
POP  XY0, XY3           ; Pop XY pair
```

### 6.13 Control

Processor control instructions.

**Opcode:** $00

| Mode | Syntax | Operation | Cycles | Words |
|------|--------|-----------|--------|-------|
| 00 | `NOP` | No operation | 2 | 1 |
| 01 | `HALT` | Stop processor | 2 | 1 |
| 01 | `HALT #n` | Stop with code n | 2 | 1 |
| 11 | `NEG dst, src` | dst ← -src | 3 | 1 |
| 11 | `NEG dst` | dst ← -dst (in-place) | 3 | 1 |

**Flags (NOP, HALT):** Not affected

```asm
NOP                     ; Do nothing
HALT                    ; Stop execution
HALT #$FF               ; Stop with debug code
```

**Debug:** HALT displays D0 on ALU-A bus for debugging.

**Note:** `NEG` shares opcode $00 but is documented in Section 6.3 (Arithmetic Operations).

### 6.14 Interrupts

Interrupt control instructions for the 8-level priority interrupt system.

**Opcode:** $1F

| Mode | Syntax | Operation | Cycles | Words |
|------|--------|-----------|--------|-------|
| 00 | `DINT` | IE ← 0 (disable) | 2 | 1 |
| 01 | `EINT` | IE ← 1 (enable) | 2 | 1 |
| 10 | `RTI` | pop SR, PC; return from ISR | 8 | 1 |
| 11 | `INT` | (hardware) push PC, SR; jump to ISR | 16 | 1 |

**Flags:** RTI restores flags from stack

```asm
DINT                    ; Disable interrupts
EINT                    ; Enable interrupts
RTI                     ; Return from interrupt handler
```

**Status Register (SR):**

| Bits | Description |
|------|-------------|
| 7 | IE - Interrupt Enable |
| 6:4 | Current priority level |
| 3:0 | CPU flags (N, Z, C, V) |

**INT and the TRAP #0 vector:**

Hardware interrupts (INT) jump via the TRAP #0 vector at `[Y3:$0000]`. The microcode reads the handler address from this vector entry and jumps there — the same entry point used by `TRAP #0`. The OS must install an INT dispatcher at boot:

```asm
; Install INT dispatcher at TRAP #0 vector
        LOADI   Y0, #$00
        LOADI   X0, #$0000
        LOADI   D0, #>isr_entry
        STORED  D0, [XY0]           ; page byte
        LOADI   X0, #$0002
        LOADI   D0, #<isr_entry
        STORED  D0, [XY0]           ; address word
        EINT                        ; enable interrupts

; INT dispatcher — reads IRQ level from SR, vectors to handler
isr_entry:
        PUSH    D0, XY3
        MOVE    D0, SR              ; D0 = SR (level in bits 6:4)
        SHR4    D0                  ; bits 6:4 → bits 2:0
        AND     D0, #$0007          ; D0 = IRQ level 0-7
        ADD     D0, #1              ; D0 = TRAP# 1-8
        SHL     D0                  ; × 2
        SHL     D0                  ; × 4 = vector offset $04..$20
        JMPT    XY3, D0             ; PC ← [Y3:D0]
        ; IRQ handlers are at TRAP #1-#8 vectors, return with RTI
```

**Note:** TRAP handlers return with `RET`; IRQ handlers invoked via the INT dispatcher return with `RTI` (which also restores SR and re-enables interrupts).

---

## 7. Byte Operations

The K16 is a 16-bit word-oriented architecture, but provides several instructions for byte-level access.

### 7.1 Byte Load/Store Instructions

| Instruction | Description |
|-------------|-------------|
| LOADB | Load byte from memory via XY pair (zero-extended to 16 bits) |
| STOREB | Store low byte of register to memory via XY pair |
| LOADPB | Load byte from paged memory (zero-extended to 16 bits) |
| STOREPB | Store low byte to paged memory |

```asm
; Byte access via XY pair
LOADB   D0, [XY0]           ; D0 ← zero-extended byte from memory[XY0]
STOREB  D0, [XY0]           ; memory[XY0] ← low byte of D0

; Byte access via paged memory
LOADI   Y0, #$20
LOADPB  D0, Y0, [#$0400]    ; D0 ← zero-extended byte from $20:0400
STOREPB D0, Y0, [#$0401]    ; $20:0401 ← low byte of D0
```

### 7.2 Byte Manipulation via LOOKUP

| Instruction | Description |
|-------------|-------------|
| HIGH | Extract high byte (D AND $FF00) |
| LOW | Extract low byte (D AND $00FF) |
| SWAPB | Swap high and low bytes ($1234 → $3412) |

```asm
; Extract bytes from a word
LOADI   D0, #$1234
HIGH    D0                  ; D0 = $1200 (high byte in position)
; or
LOADI   D0, #$1234
LOW     D0                  ; D0 = $0034 (low byte only)

; Extract high byte to low position
LOADI   D0, #$1234
HIGH    D0                  ; D0 = $1200
SWAPB   D0                  ; D0 = $0012

; Swap byte order (endianness conversion)
LOADI   D0, #$1234
SWAPB   D0                  ; D0 = $3412
```

### 7.3 Byte Masking with AND

```asm
; Extract low byte using AND
AND     D0, #$00FF          ; D0 = D0 AND $00FF (keep low byte)

; Extract high byte using AND
AND     D0, #$FF00          ; D0 = D0 AND $FF00 (keep high byte)

; Clear low byte
AND     D0, #$FF00          ; Low byte = 0

; Clear high byte
AND     D0, #$00FF          ; High byte = 0
```

### 7.4 Common Byte Patterns

```asm
; Build word from two bytes
LOADI   D0, #0
LOADPB  D0, Y0, [#low_byte]   ; D0 = $00xx (low byte)
LOADPB  D1, Y0, [#high_byte]  ; D1 = $00yy (high byte)
SHL     D1                    ; D1 = $00yy << 8 = partial
; ... (requires multiple shifts or SWAPB + OR)

; Easier: load word directly if aligned
LOADP   D0, Y0, [#word_addr]  ; D0 = both bytes at once

; Character processing
LOADPB  D0, Y0, [#string]     ; Load ASCII character
CMP     D0, #$20              ; Compare with space
BCC     .control_char         ; < $20 is control character
CMP     D0, #$7F
BCS     .non_printable        ; >= $7F is non-printable
; ... printable ASCII $20-$7E
```

---

## 8. Endianness

### 8.1 Definition

The K16 CPU uses **little-endian** byte ordering for all data memory
operations. When a 16-bit word is stored to or loaded from RAM:

- The **low byte (D7–D0) is placed at the lower address**
- The **high byte (D15–D8) is placed at the upper address**

```
Word $1234 stored at address $010000:

  Address    Byte     Description
  $010000    $34      low byte  (D7–D0)
  $010001    $12      high byte (D15–D8)
```

**Hardware verification** — confirmed on physical K16 hardware:

```asm
LOADI   D0, #$1234
STORED  D0, [XY0]       ; XY0 = $010000
LOADB   D1, [XY0]       ; read single byte from $010000
; D1 = $34  →  low byte at lower address  →  little-endian confirmed
```

**Microcode verification** — confirmed in ALU microcode source files.
STORED writes D[7:0] to `[XYn+0]` and D[15:8] to `[XYn+1]`.
LOADD reads D[7:0] from `[XYn+0]` and D[15:8] from `[XYn+1]`.

---

### 8.2 Word Operations — STORED / LOADD / STOREX / LOADX

All 16-bit word store and load operations are little-endian.

```
STORED D0, [XY0]   with D0 = $AABB, XY0 = $010000:

  $010000    $BB    low byte  (D7–D0)
  $010001    $AA    high byte (D15–D8)
```

```
LOADD D0, [XY0]:

  D0 = Mem[$010000] or (Mem[$010001] shl 8)
     = $BB or ($AA shl 8)
     = $AABB
```

STOREX/LOADX behave identically — X registers are 16-bit, same layout.

---

### 8.3 Byte Operations — STOREB / LOADB / STOREY / LOADY

Single-byte operations involve only one address — no endianness applies.

```
STOREB D0, [XY0]   →  Mem[XY0] := D0 and $FF   (low byte of D0 only)
LOADB  D0, [XY0]   →  D0 := Mem[XY0]           (zero-extended to 16 bits)

STOREY Y0, [XY0]   →  Mem[XY0] := Y0            (Y is 8-bit)
LOADY  Y0, [XY0]   →  Y0 := Mem[XY0] and $FF
```

---

### 8.4 XY Pair Operations — STOREXY / LOADXY

**Verified from microcode source:**
`ALU_Opcode_x1D_STOREI.pas` and `ALU_Opcode_x18_LOADI.pas`.

STOREXY and LOADXY use a specific layout where **Y is stored first**
(at the lower address) and **X is stored second** (at the higher address).
This is not natural 24-bit little-endian — it is a deliberate hardware
design reflecting the internal register structure (Y = high byte, X = low word).

#### STOREXY microcode sequence:

```
Step 1: srcY (ABHi) → ORDB
Step 2: ORDB → Memory[destXY+0]     Y stored at lower address
Step 3: srcX (ABLo) → ORDB
Step 4: destX + 2 → ORAB
Step 5: ORDB → Memory[ORAB:destY]   X stored at higher address
```

#### STOREXY memory layout:

```
STOREXY XY0, [XY1]   with XY0 = $FF1234, XY1 = $020000:

  Address    Byte    Description
  $020000    $FF     Y0 (address bits 23–16), low byte
  $020001    $00     Y0 high byte (always $00 — Y is 8-bit, zero-extended)
  $020002    $34     X0 low byte  (address bits 7–0)
  $020003    $12     X0 high byte (address bits 15–8)
```

#### LOADXY microcode sequence:

```
Step 1: Memory[srcXY+0] → destY     Y loaded from lower address
Step 2: srcX + 2 → ORAB
Step 3: Memory[ORAB:srcY] → destX   X loaded from higher address
```

#### LOADXY example:

```
LOADXY XY0, [XY1]   reading from $020000:

  Y0 := Mem[$020000] and $FF  =  $FF   (address bits 23–16)
  X0 := MemWord[$020002]      =  $1234 (address bits 15–0, little-endian)

  XY0 = $FF1234  ✓
```

**Summary — STOREXY / LOADXY layout:**

| Offset | Width | Content |
|--------|-------|---------|
| +0 | 2 bytes | Y register (8-bit value, zero-extended to word, little-endian) |
| +2 | 2 bytes | X register (16-bit value, little-endian) |

Total: 4 bytes. Y first, X second.

**Naming note — easy source of confusion:**
Y holds the *high* byte of the 24-bit address (bits 23–16), but it is
stored at the *lower* memory address. X holds the *low* 16 bits (bits 15–0)
but sits at the *higher* memory address. So "high address byte" ends up
at the "low memory address". This is consistent across STOREXY, LOADXY,
PUSH XY, and POP XY — Y is always written/pushed last, so it always
lands at the lowest address of the pair.

---

### 8.5 Stack Layout — CALL24 / RET

The XY3 stack is descending — it grows toward lower addresses.
PUSH pre-decrements SP by 2 before writing. POP reads then post-increments
SP by 2. All stack words are little-endian.

#### CALL24 push order

**Verified from JSR microcode (`K16_JSR_RTS_Complete_Specification_V4.md`):**

CALL24 pushes **PC[15:0] first** (lands at the higher address),
then **PC[23:16]** (lands at the lower address). After the call,
X3 points to the PC[23:16] word at the lowest address.

```
CALL24 $FF1234   with X3 = $BFF0:

  Step 1: X3 - 2 → ORAB = $BFEE;  Memory[$BFEE] = $1234 (PC[15:0], little-endian)
  Step 2: X3 - 4 → ORAB = $BFEC;  Memory[$BFEC] = $00FF (PC[23:16], zero-extended)
  Step 3: ORAB ($BFEC) → X3

  Memory layout after CALL:
  Address    Byte    Description
  $BFEC      $FF     PC[23:16] low byte    ← X3 points here
  $BFED      $00     PC[23:16] high byte   (always $00, zero-extended)
  $BFEE      $34     PC[15:0]  low byte
  $BFEF      $12     PC[15:0]  high byte
  $BFF0               (previous stack top)

  X3 = $BFEC
```

#### RET pop order

**Verified from RTS microcode.**

RET pops **PC[15:0] from [X3]** first, then **PC[23:16] from [X3+2]**,
then sets X3 := X3 + 4.

The CALL/RET pair is symmetric — whatever CALL24 pushes, RET pops correctly.
The internal microcode field assignments account for the push order automatically,
restoring the correct PC regardless of the swap. Use CALL24/RET as a matched pair
without needing to track internal details.

---

### 8.6 Stack Layout — PUSH XY / POP XY

**Verified from PUSH/POP pair microcode (`K16_PUSHPOP_Spec_V3.1.md`).**

PUSH XY pushes **X first** (higher address), then **Y** (lower address).
This matches STOREXY's layout — Y at the lower address, X at the higher.

```
PUSH XY0, XY3   with XY0 = $FF1234, X3 = $BFF0:

  Step 1: X3 - 2 → ORAB = $BFEE;  Memory[$BFEE] = $1234 (X0, little-endian)
  Step 2: X3 - 4 → ORAB = $BFEC;  Memory[$BFEC] = $00FF (Y0, zero-extended)
  Step 3: ORAB → X3 = $BFEC

  Memory layout:
  Address    Byte    Description
  $BFEC      $FF     Y0 low byte   ← X3 points here
  $BFED      $00     Y0 high byte  (zero-extended)
  $BFEE      $34     X0 low byte
  $BFEF      $12     X0 high byte
```

```
POP XY0, XY3   with X3 = $BFEC:

  Reads Y0 from [X3]   = $00FF → Y0 = $FF
  Reads X0 from [X3+2] = $1234 → X0 = $1234
  X3 += 4 → $BFF0

  XY0 = $FF1234  ✓
```

**PUSH XY and STOREXY produce identical memory layouts** — Y at lower
address, X at higher. This means a value saved with STOREXY can be
loaded with LOADXY, and a value pushed with PUSH XY can be popped with
POP XY, consistently.

**Reminder:** Y (the high byte of the address, bits 23–16) ends up at
the lower memory address. X (the low 16 bits, bits 15–0) ends up at
the higher memory address.

---

### 8.7 PUSH / POP — Single Register

Single register PUSH/POP stores/loads one 16-bit word, little-endian.

```
PUSH D0, XY3   with D0 = $ABCD, X3 = $BFF0:

  X3 -= 2  →  X3 = $BFEE
  Mem[$BFEE] = $CD   (low byte)
  Mem[$BFEF] = $AB   (high byte)

POP D0, XY3:

  D0 = Mem[$BFEE] or (Mem[$BFEF] shl 8) = $ABCD
  X3 += 2  →  X3 = $BFF0
```

---

### 8.8 TRAP — Push Return Address

TRAP pushes the return address using the same sequence as CALL24:
PC[15:0] first (higher address), PC[23:16] second (lower address).
RTI pops in the matching reverse order.

The interrupt/TRAP vector table entry is a single 16-bit word in the
Y3 page — read as a little-endian word, no special handling.

---

### 8.9 String and Byte Data

Strings (`.TEXT`) and raw byte arrays are stored sequentially —
one byte per address, in ascending address order. No endianness
consideration applies. Use `LOADB`/`STOREB` with `INC XYn, #1`
for byte-by-byte traversal:

```asm
PRINT_STR:
        MOVE    X0, D0          ; D0 = low word of string address
.loop:  LOADB   D0, [XY0]       ; load one character byte
        CMP     D0, #0
        BEQ     .done
        STOREB  D0, [XY1]       ; write to terminal ($D00000)
        INC     XY0, #1         ; advance pointer by one byte
        JMP     .loop
.done:  RET
```

---

### 8.10 Instruction ROM Encoding

Instruction words in the ROM are not subject to byte-level endianness
in the data sense. The K16 hardware uses two physical ROM chips simultaneously
— one supplies D15–D8, the other D7–D0. The CPU always receives a complete
16-bit word in a single memory cycle.

For the **flat binary (.bin) emulator format**, instruction words are stored
little-endian (low byte first) to match the emulator's uniform memory model.
The assembler `.bin` export swaps bytes automatically when generating this
file. The Digital simulator ROM files (ProgramHIGH.hex / ProgramLOW.hex)
are unaffected by this swap.

---

### 8.11 Complete Memory Layout Reference

All entries verified by hardware test or microcode inspection.

#### 8.11.1 Single word store/load

| Operation | Addr | Byte | Notes |
|-----------|------|------|-------|
| `STORED D0` ($AABB) at $N | $N+0 | $BB | low byte ✓ hardware |
| | $N+1 | $AA | high byte |
| `STOREX X0` ($CCDD) at $N | $N+0 | $DD | low byte ✓ microcode |
| | $N+1 | $CC | high byte |
| `STOREY Y0` ($EE) at $N | $N+0 | $EE | single byte ✓ microcode |
| `STOREB D0` ($xxBB) at $N | $N+0 | $BB | low byte only ✓ microcode |

#### 8.11.2 XY pair — STOREXY / LOADXY

| Operation | Addr | Byte | Notes |
|-----------|------|------|-------|
| `STOREXY XY0` ($FF1234) at $N | $N+0 | $FF | Y low byte ✓ microcode |
| | $N+1 | $00 | Y high byte (always $00) |
| | $N+2 | $34 | X low byte |
| | $N+3 | $12 | X high byte |

#### 8.11.3 Stack after CALL24 / PUSH XY

With SP=$BFF0, XY0=$FF1234:

| Operation | Addr | Byte | Notes |
|-----------|------|------|-------|
| `CALL24 $FF1234` or `PUSH XY0` | $BFEC | $FF | Y / PC[23:16] low ✓ microcode |
| | $BFED | $00 | Y / PC[23:16] high |
| | $BFEE | $34 | X / PC[15:0] low |
| | $BFEF | $12 | X / PC[15:0] high |
| | X3 = $BFEC | | SP after push |

---

### 8.12 Toolchain Summary

| Component | Byte order | Implementation |
|-----------|-----------|----------------|
| K16 hardware data RAM | **Little-endian** | Verified by hardware test |
| K16 instruction ROM | N/A | Parallel byte ROMs, full word presented to CPU |
| Assembler `.bin` export | **Little-endian** | Auto byte-swap from internal big-endian |
| Assembler Digital ROM files | N/A | Split ProgramHIGH/LOW.hex |
| Emulator `MemReadWord` | **Little-endian** | `Mem[a] or (TWord(Mem[a+1]) shl 8)` |
| Emulator `MemWriteWord` | **Little-endian** | `Mem[a]:=lo; Mem[a+1]:=hi` |
| Emulator `ExecSTOREXY` | Y first, X second | `WriteWord(addr, Y); WriteWord(addr+2, X)` |
| Emulator `ExecLOADXY` | Y first, X second | `Y:=ReadWord(addr) and $FF; X:=ReadWord(addr+2)` |
| Emulator `StackPush24` | PC[15:0] first | Matches CALL24 microcode |
| Emulator `StackPop24` | PC[15:0] first | Matches RET microcode |
| k/OS data structures | **Little-endian** | Must match hardware |
| K16Pascal compiler | **Little-endian** | Stack frames, heap, pointers |
| `SWAPB` lookup op | Byte reversal | `$1234 → $3412`, explicit endian conversion |

---

## 9. Zero Page Programming

The K16 provides efficient "zero page" style access to frequently-used variables using the LOADP/STOREP instructions. This technique saves significant cycles compared to indexed addressing.

### 9.1 Concept

Traditional indexed access requires loading a base address into an XY pair before accessing memory. Zero page access uses Y3 (the stack page register) as an implicit base, allowing direct access to any location in the stack segment with a single instruction.

**Performance comparison:**

| Method | Instructions | Cycles | XY Register |
|--------|--------------|--------|-------------|
| Indexed access | LOADI X0 + LOADI Y0 + LOADD | 6 | XY0 consumed |
| Zero page | LOADP | 3 | None (uses Y3) |

**Savings:** 3 cycles per load (50% faster), plus XY registers remain free for other work.

### 9.2 Memory Map (Page $00)

The stack segment at page $00 is organized for both stack operations and zero page variables:

| Address Range | Offset | Size | Purpose |
|---------------|--------|------|---------|
| $00_0000-$00_01FF | $0000 | 512 bytes | TRAP/INT vector table (128 entries × 4 bytes) |
| $00_0200-$00_02FF | $0200 | 256 bytes | System variables |
| $00_0300-$00_037F | $0300 | 128 bytes | Forth interpreter reserved |
| $00_0380-$00_03FF | $0380 | 128 bytes | Pascal/compiler reserved |
| $00_0400-$00_0FFF | $0400 | ~3KB | Application zero page |
| $00_1000-$00_FFFF | $1000 | ~60KB | Stack space (grows down) |

**Vector table layout:** Each entry is 4 bytes — page byte at offset+0, address word at offset+2. TRAP #n vector is at offset n×4.

```
[Y3:$0000]  TRAP #0    INT dispatcher (also hardware INT entry point)
[Y3:$0004]  TRAP #1    IRQ0 handler (lowest priority)
[Y3:$0008]  TRAP #2    IRQ1 handler
[Y3:$000C]  TRAP #3    IRQ2 handler
[Y3:$0010]  TRAP #4    IRQ3 handler
[Y3:$0014]  TRAP #5    IRQ4 handler
[Y3:$0018]  TRAP #6    IRQ5 handler
[Y3:$001C]  TRAP #7    IRQ6 handler
[Y3:$0020]  TRAP #8    IRQ7 handler (highest priority, typically timer)
[Y3:$0024]  TRAP #9    first syscall
...
[Y3:$01FC]  TRAP #127  last syscall
```

### 9.3 Stack Layout

```
$00FFFF ─┬─ Stack top (XY3 initialized to $00:BFF0)
         │  Stack grows DOWN
$001000 ─┼─
         │  ~60KB stack space
$000FFF ─┼─ Application ZP top
         │  Application variables (~3KB)
$000400 ─┼─ Application ZP base
         │
$0003FF ─┼─ Pascal/compiler (128 bytes)
$000380 ─┼─
         │
$00037F ─┼─ Forth reserved (128 bytes)
$000300 ─┼─
         │
$0002FF ─┼─ System variables (256 bytes)
$000200 ─┼─
         │
$0001FF ─┼─ Vector table top
         │  TRAP/INT vectors (512 bytes, 128 × 4 bytes)
$000000 ─┴─ Vector table base (TRAP #0 / INT dispatcher)
```

### 9.4 Accessing Zero Page Variables

Use LOADP/STOREP with Y3 as the page register:

```asm
; Define zero page variable locations
ZP_COUNTER   .EQU    $0400
ZP_FLAGS     .EQU    $0402
ZP_TEMP      .EQU    $0404

; Load from zero page (3 cycles)
LOADP   D0, Y3, [#ZP_COUNTER]   ; D0 ← [$00:0400]
LOADP   D1, Y3, [#ZP_FLAGS]     ; D1 ← [$00:0402]

; Store to zero page (5 cycles)
STOREP  D0, Y3, [#ZP_TEMP]      ; [$00:0404] ← D0

; Byte access (3 cycles load, 5 cycles store)
LOADPB  D0, Y3, [#ZP_FLAGS]     ; Load byte, zero-extended
STOREPB D0, Y3, [#ZP_FLAGS]     ; Store low byte only
```

### 9.5 Reserved Allocations

#### TRAP/INT Vector Table ($0000-$01FF)

```asm
TRAP0_VEC    .EQU    $0000       ; TRAP #0 / INT dispatcher page byte
             .EQU    $0002       ; TRAP #0 / INT dispatcher addr word
TRAP1_VEC    .EQU    $0004       ; TRAP #1 / IRQ0 handler
; ... entries at n*4 for TRAP #n ...
TRAP9_VEC    .EQU    $0024       ; TRAP #9 / first syscall
TRAP127_VEC  .EQU    $01FC       ; TRAP #127 / last syscall
```

#### System Variables ($0200-$02FF)

```asm
SYS_TICKS    .EQU    $0200       ; System tick counter
SYS_FLAGS    .EQU    $0202       ; System status flags
```

#### Forth Interpreter ($0300-$037F)

```asm
ZP_LATEST    .EQU    $0300       ; Dictionary head (Y)
ZP_LATEST_X  .EQU    $0302       ; Dictionary head (X)
ZP_HERE      .EQU    $0304       ; Next free byte (Y)
ZP_HERE_X    .EQU    $0306       ; Next free byte (X)
ZP_STATE     .EQU    $0308       ; Compile state (0=interpret)
ZP_TOIN      .EQU    $030A       ; >IN parse position
ZP_NUMTIB    .EQU    $030C       ; #TIB character count
ZP_BASE      .EQU    $030E       ; Number base (default 10)
```

#### Pascal/Compiler Runtime ($0380-$03FF)

```asm
PAS_FRAME    .EQU    $0380       ; Frame pointer backup
PAS_HEAP     .EQU    $0382       ; Heap pointer
PAS_TEMP1    .EQU    $0384       ; Expression temporary 1
PAS_TEMP2    .EQU    $0386       ; Expression temporary 2
```

### 9.6 Application Variables ($0400-$0FFF)

Organize by usage frequency — place most-used variables at lower addresses:

```asm
; High-frequency variables
APP_COUNT    .EQU    $0400           ; Loop counter
APP_TEMP_A   .EQU    $0402           ; Temporary A
APP_TEMP_B   .EQU    $0404           ; Temporary B
APP_RESULT   .EQU    $0406           ; Result

; 24-bit pointers (stored as Y at offset, X at offset+2)
APP_PTR1_Y   .EQU    $0500           ; Pointer 1 page
APP_PTR1_X   .EQU    $0502           ; Pointer 1 offset

; Application state
APP_MODE     .EQU    $0600           ; Current mode
APP_STATUS   .EQU    $0602           ; Status flags

; Buffers and arrays
APP_BUFFER   .EQU    $0700           ; 256-byte work buffer
```

### 9.7 Example: Complete Program

```asm
;=====================================================
; Zero Page Definitions
;=====================================================
ZP_COUNT     .EQU    $0400
ZP_SUM       .EQU    $0402
ZP_PTR_X     .EQU    $0404
ZP_PTR_Y     .EQU    $0406
SYS_TICKS    .EQU    $0200

;=====================================================
; Program Code (in ROM)
;=====================================================
             .BASE   $F00000
             .ORG    $FF0000

START:
        ; Initialize stack (Y3=$00 enables ZP access)
        LOADI   X3, #$FFF0
        LOADI   Y3, #$00
        
        ; Setup interrupt vector at $000000
        LOADI   D0, #>ISR
        STOREP  D0, Y3, [#$0000]
        LOADI   D0, #<ISR
        STOREP  D0, Y3, [#$0002]
        
        ; Initialize zero page variables
        LOADI   D0, #0
        STOREP  D0, Y3, [#ZP_COUNT]
        STOREP  D0, Y3, [#ZP_SUM]
        
        EINT

LOOP:
        LOADP   D0, Y3, [#ZP_COUNT]
        ADD     D0, #1
        STOREP  D0, Y3, [#ZP_COUNT]
        CMP     D0, #100
        BNE     LOOP
        
        HALT    #0

ISR:
        PUSH    D0
        LOADP   D0, Y3, [#SYS_TICKS]
        ADD     D0, #1
        STOREP  D0, Y3, [#SYS_TICKS]
        POP     D0
        RTI
```

### 9.8 Best Practices

1. **Reserve $0000-$01FF for the vector table** — TRAP/INT vectors; do not use for variables
2. **Reserve $0200-$03FF for system/runtime use** — OS variables, Forth, Pascal runtime
3. **Allocate application variables from $0400** — keep hot variables at lower addresses within this range
4. **Use .EQU for all addresses** — makes code maintainable and relocatable
5. **Group related variables** — improves code readability
6. **Document variable usage** — zero page is a shared resource across all tasks
7. **Use LOADP/STOREP consistently** — 3 cycles vs 6 for indexed load (50% faster)
8. **Use `INC XYn, #1` for byte/string traversal** — `INC XYn` defaults to +2 (word step); omitting the `#1` silently skips every other byte

---

## 10. Special Features

### 10.1 Word Suffix (w)

The 'w' suffix multiplies a value by 2, converting word counts to byte counts. Useful for structure field offsets and stack cleanup.

```asm
LOADI D0, #4w           ; = 8 (4 words × 2)
LOADD D0, [XY0+#3w]     ; offset = 6 bytes
RET #2w                 ; cleanup 4 bytes (2 words)
STRUCT_SIZE  .EQU   8w  ; = 16 bytes
LOADI D0, #10 + 2w      ; = 14 (10 + 4)
```

### 10.2 Derivative Operators (24-bit Address Handling)

The K16 uses 24-bit addresses but registers are 8-bit (Y) or 16-bit (X). These operators extract portions of 24-bit addresses for loading into XY register pairs.

| Operator | Description | Bits Extracted |
|----------|-------------|----------------|
| `#>` | High byte (bank) | Bits 23-16 |
| `#<` | Low word | Bits 15-0 |

**Loading a 24-bit address into an XY pair:**

```asm
BUFFER       .EQU    $12AB34

LOADI Y1, #>BUFFER      ; Y1 = $12 (high byte)
LOADI X1, #<BUFFER      ; X1 = $AB34 (low word)
; XY1 now contains $12AB34

LOADD D0, [XY1]         ; Access data at BUFFER
```

**Multiple pointers:**

```asm
VIDEO_RAM    .EQU    $0F0000
ROM_TABLE    .EQU    $FF8000

; Load video pointer into XY0
LOADI Y0, #>VIDEO_RAM   ; Y0 = $0F
LOADI X0, #<VIDEO_RAM   ; X0 = $0000

; Load ROM pointer into XY2
LOADI Y2, #>ROM_TABLE   ; Y2 = $FF
LOADI X2, #<ROM_TABLE   ; X2 = $8000
```

**Note:** Plain `#symbol` without an operator defaults to the low word (bits 15-0).

---

## 11. Expression Evaluation

The assembler supports arithmetic expressions in immediate values, .EQU directives, and .WORD directives.

### 11.1 Operators

| Operator | Description | Precedence |
|----------|-------------|------------|
| ( ) | Parentheses (grouping) | Highest |
| - + | Unary minus/plus | High |
| * / | Multiplication, Division | Medium |
| + - | Addition, Subtraction | Low |

### 11.2 Examples

```asm
SIZE         .EQU    256
HEADER       .EQU    16
TOTAL        .EQU    SIZE + HEADER           ; = 272
HALF         .EQU    SIZE / 2                ; = 128
COMPLEX      .EQU    (SIZE - HEADER) / 2     ; = 120

LOADI D0, #SIZE + 4                 ; = 260
LOADI D1, #(TOTAL / 4)              ; = 68
.WORD SIZE * 2                      ; Emits 512
```

---

## 12. Calling Convention (V2 ABI)

The K16 V2 ABI is the standard calling convention for K16 assembly and the Pascal compiler. All subroutines — whether called via CALL24, CALLXY, or TRAP — follow this convention unless otherwise noted.

### 12.1 Register Roles

| Register | Role | Saved by |
|----------|------|----------|
| D0 | 1st argument / return value | Caller |
| D1 | 2nd argument | Caller |
| D2 | 3rd argument | Caller |
| D3 | Scratch / callee-saved | Callee |
| X0, Y0 | Scratch (XY0) | Caller |
| X1, Y1 | Scratch (XY1) | Caller |
| X2, Y2 | Frame pointer cache (XY2) | Callee |
| X3, Y3 | Call stack pointer (XY3) | — (managed by CALL/RET) |

**XY2 as frame pointer cache:** XY2 is reserved for the callee to cache a frequently-used pointer (typically a frame or object base address) across calls. Callers must not assume XY2 is preserved across a call they make.

### 12.2 Argument Passing

Up to 3 arguments are passed in registers D0, D1, D2. The 4th and subsequent arguments are pushed to the XY3 stack before the call, right-to-left (last argument pushed first):

```asm
; Call with 3 register args — no stack args needed
        LOADI   D0, #arg1
        LOADI   D1, #arg2
        LOADI   D2, #arg3
        CALL24  subroutine

; Call with 5 args — args 4 and 5 on stack
        PUSH    #arg5, XY3          ; push last arg first
        PUSH    #arg4, XY3
        LOADI   D0, #arg1
        LOADI   D1, #arg2
        LOADI   D2, #arg3
        CALL24  subroutine
        ; caller does NOT clean up stack (callee uses RET #Nw)
```

### 12.3 Return Value

Returned in D0. For values larger than 16 bits, the caller pre-allocates a result slot on the stack and passes its address (or uses XY2 by convention).

### 12.4 Stack Frame Layout

CALL24 pushes a 4-byte return address. Stack-passed arguments (4th+) are pushed before the call. At entry to the callee:

```
[X3+0]   return address low   (pushed last by CALL)
[X3+2]   return address high
[X3+4]   arg4                 (if present)
[X3+6]   arg5                 (if present)
...
```

### 12.5 Callee Responsibilities

The callee must preserve D3 and XY2 if it uses them, and must clean up any stack arguments it declared using `RET #Nw`:

```asm
myfunc:                         ; args: D0=a, D1=b, stack=[X3+4]=c
        PUSH    D3, XY3         ; save D3 if used
        ; ... body ...
        POP     D3, XY3         ; restore D3
        RET     #1w             ; return + pop 1 stack arg (2 bytes)
```

**RET #Nw limit:** Due to a hardware oscillation bug, `RET #Nw` is safe up to `#4w` (8 bytes). For larger cleanups use `ADD X3, #N` followed by plain `RET`:

```asm
        ADD     X3, #10         ; pop 5 stack args (10 bytes)
        RET                     ; then return
```

### 12.6 TRAP Convention

TRAP handlers follow the same V2 ABI. D0/D1/D2 carry arguments in, D0 carries the return value out. The TRAP instruction pushes 4 bytes to XY3, so stack-passed arguments (if any) are at `[X3+4]` on entry to the handler. Handlers return with plain `RET`.

### 12.7 Forth Runtime

Forth uses an entirely separate register convention and must not be mixed with V2 ABI code:

| Register | Forth role |
|----------|-----------|
| XY1 | Interpreter pointer (IP) |
| XY2 | Data stack pointer |
| XY3 | Return stack pointer |

Forth and Pascal are separate runtime environments. Do not call between them without an explicit adapter.

---

## 13. Warnings and Errors

### 13.1 Word Alignment Warning

Word operations (LOADD, STORED, etc.) with odd offsets generate warnings:

```asm
LOADD D0, [XY0+#3]      ; WARNING: odd offset may cause misalignment
```

The code is still assembled, but may not work correctly on hardware.

The word-alignment check for labels is now a **warning** (not an error). A label at an odd address is legitimate when used to reference byte data within a `.BYTE` or `.DS` block, but would cause a bus error if used as a code branch target or word memory access.

```asm
data:   .BYTE   $41, $42, $43   ; 3 bytes
odd_label:                       ; WARNING: odd address — OK for byte access
        .ALIGN
even_label:                      ; no warning
```

### 13.2 Common Errors

| Error | Cause |
|-------|-------|
| Undefined symbol | Label or constant not defined |
| STORE requires register source | Tried `STORED #value, [XY0]` — not supported |
| Immediate value out of range | IMM5 mode requires 0-31; use larger value for IMM16 mode |
| .ORG address is odd | K16 requires even addresses |
| Branch target out of range | Short branch (±127) exceeded; use .L suffix |
| Invalid destination register | ALU dest must be D0-D3, X0-X3, or Y0-Y3 (not ORDB/SR/PCH/PCL) |
| Local label before any global label | `.done:` defined before the first global label in the file |
| .DS count must be >= 0 | Negative count passed to `.DS` |
| .ALIGN boundary must be a power of 2 | e.g. `.ALIGN 3` |
| .INCLUDE file not found | Resolved path does not exist |
| Circular include detected | File includes itself directly or indirectly |
| .INCLUDE nesting exceeds maximum depth (8) | Include chain too deep |

---

## 14. Output

### 14.1 Listing File

The assembler generates a detailed listing showing address, machine code, and source:

```
Addr     OpCode   Imm     Decode    Source
00 0100  C014     ----    18.0.2    LOADI D0, #20      ; IMM5 mode (value ≤ 31)
00 0102  C620     0064    18.3.4    LOADI D1, #100     ; IMM16 mode (value > 31)
```

**Decode format:** Opcode.Mode.Words — The mode field shows which addressing mode was selected (e.g., mode 0 = IMM5, mode 3 = IMM16 for LOADI).

### 14.2 Symbol Table

Shows all defined labels and constants with their values:

```
Symbol Table:
  BUFFER_SIZE  = $0100 (Constant, line 5)
  START        = $0200 (Label, line 10)
```

---

## 15. Quick Reference

### 15.1 Instruction Summary

| Category | Instructions |
|----------|--------------|
| Load | LOADI, LOADD, LOADX, LOADY, LOADB, LOADXY, LOADP, LOADPB |
| Store | STORED, STOREX, STOREY, STOREB, STOREXY, STOREP, STOREPB |
| Move | MOVE, SWAP |
| Arithmetic | ADD, ADC, SUB, SBC, NEG, INC, DEC |
| Logical | AND, OR, XOR, NOT |
| Shift/Rotate | SHL, SHR, ASR, ROL, ROR, SWAPB, HIGH, LOW, SHL4, SHR4, ASR4, ASR8, MULB, RECIP, LOOKUP |
| Address | LEA |
| Compare | CMP |
| Conditional Set | SEQ, SNE, SCS, SCC, SMI, SPL, SAL |
| Branch | BEQ, BNE, BCS/BHS, BCC/BLO, BLT, BGT, BGE, BLE, BRA |
| Jump | JMP, JMP24, JMP16, JMPT, JMPXY |
| Subroutine | CALL, CALL24, CALL16, CALLR, CALLXY, TRAP, RET |
| Stack | PUSH, POP (supports D, X, Y, XY, D group, immediate) |
| Control | NOP, HALT, DINT, EINT, RTI |

### 15.2 Cycle Count Reference

| Instruction | Mode 00 | Mode 01 | Mode 10 | Mode 11 | Notes |
|-------------|---------|---------|---------|---------|-------|
| **Control ($00)** |
| NOP | 2 | — | — | — | No operation |
| HALT | — | 2 | — | — | Stop processor |
| NEG | — | — | — | 3 | Two's complement negate |
| **LOOKUP ($01)** |
| SHL/SHR/ASR/ROL/ROR | 3 | 3 | 3 | 3 | Mode selects operation |
| SWAPB/HIGH/LOW | 3 | 3 | 3 | 3 | Mode selects operation |
| SHL4/SHR4/ASR4/ASR8 | 3 | 3 | 3 | 3 | Extended shifts |
| MULB/RECIP | 3 | 3 | — | — | Multiply/Reciprocal |
| **Address ($02-$03)** |
| INC XYn | 5 | — | — | — | 24-bit increment |
| DEC XYn | — | 6 | — | — | 24-bit decrement |
| LEA | 5 | 5 | 6 | 5 | copy / +D / PC-rel / +imm5 |
| **Conditional ($04)** |
| Scc | 4 | — | — | — | Conditional set |
| **Move ($05)** |
| MOVE | 3 | 3 | — | — | Register to register |
| SWAP | — | — | 4 | 4 | Register exchange |
| **Stack ($06-$07)** |
| PUSH reg | 5 | — | — | — | Single D/X/Y |
| PUSH Dg | — | 14 | — | — | D group (4 regs) |
| PUSH XY | — | — | 8 | — | XY pair |
| PUSH #imm | — | — | — | 5 | Immediate (via PUSHI encoding) |
| POP reg | 4 | — | — | — | Single D/X/Y |
| POP Dg | — | 10 | — | — | D group (4 regs) |
| POP XY | — | — | 6 | — | XY pair |
| PUSHI | — | — | — | 5 | Push immediate |
| **ALU ($08-$0F)** |
| ADD/ADC | 4 | 4 | 3 | 4 | reg / [XY] / imm5 / imm16 |
| SUB/SBC | 4 | 4 | 4 | 4 | Non-commutative |
| AND/OR/XOR | 4 | 4 | 3 | 4 | Logical ops |
| NOT | 4 | 4 | — | — | Complement |
| **Compare ($10)** |
| CMP | 3 | 3 | 3 | 3 | All modes 3 cycles |
| **Branch ($11)** |
| Bcc.S | 3 | — | — | — | Short conditional |
| Bcc.L | — | 4 | — | — | Long conditional |
| BRA.S | — | — | 3 | — | Short unconditional |
| BRA.L | — | — | — | 4 | Long unconditional |
| **Jump ($12)** |
| JMP24 | 2 | — | — | — | 24-bit absolute |
| JMP16 | — | 2 | — | — | 16-bit, current page |
| JMPT | — | — | 4 | — | Jump table |
| JMPXY | — | — | — | 3 | Indirect via XY |
| **Subroutine ($13)** |
| CALL24 | 11 | — | — | — | 24-bit absolute |
| CALL16 | — | 11 | — | — | 16-bit, current page |
| CALLR | — | — | 12 | — | PC-relative |
| CALLXY | — | — | — | 10 | Indirect via XY register |
| **Load ($14-$18)** |
| LOADD/X/Y | 2 | 3 | 4 | 3 | [XY] / [XY+D] / [PC+imm16] / [XY+imm5] |
| LOADB | 2 | 3 | 4 | 3 | Byte load (same as LOADD) |
| LOADI | 2 | 2 | — | — | IMM5 / IMM16 |
| LOADXY | — | — | 4 | — | Load XY pair |
| LOADP/LOADPB | — | — | — | 3 | Paged memory |
| **Store ($19-$1D)** |
| STORED/X/Y | 3 | 4 | 4 | 4 | [XY] / [XY+D] / [PC+imm16] / [XY+imm5] |
| STOREB | 3 | 4 | 4 | 4 | Byte store (same as STORED) |
| STOREI | 2 | 3 | — | — | IMM5 / IMM16 |
| STOREXY | — | — | 6 | — | Store XY pair |
| STOREP | — | — | — | 5 | Paged memory |
| **TRAP/RET ($1E)** |
| TRAP | 12 | — | — | — | Software syscall |
| RET | — | — | — | 5 | Return (+ optional cleanup) |
| **Interrupt ($1F)** |
| DINT | 2 | — | — | — | Disable interrupts |
| EINT | — | 2 | — | — | Enable interrupts |
| RTI | — | — | 8 | — | Return from interrupt |
| INT | — | — | — | 16 | Hardware interrupt |

### 15.3 Flags Affected

| Category | Instructions | C | Z | N | V |
|----------|--------------|---|---|---|---|
| Arithmetic | ADD, ADC, SUB, SBC | ✓ | ✓ | ✓ | ✓ |
| Negate | NEG | ✓ | ✓ | ✓ | ✓ |
| Compare | CMP | ✓ | ✓ | ✓ | ✓ |
| Logical | AND, OR, XOR, NOT | ✓* | ✓ | ✓ | — |
| INC/DEC XY | INC, DEC (XY pairs) | ✗ | ✗ | ✗ | ✗ |
| INC/DEC D/X/Y | (syntax sugar for ADD/SUB) | ✓ | ✓ | ✓ | ✓ |
| LOOKUP | All (SHL, SHR, SWAPB, etc.) | — | — | — | — |
| Move/Load/Store | All | — | — | — | — |
| Branch/Jump | All | — | — | — | — |
| Scc | SEQ, SNE, etc. | — | — | — | — |

✓ = Set meaningfully based on result  
✗ = Trashed (undefined/corrupted)  
— = Not affected (preserved)

*Logical ops: C is cleared (not set based on result).

**Warning:** INC/DEC on XY pairs trashes all flags as a side effect of internal ALU operations. Do not use INC/DEC XY between a comparison and a conditional branch.

### 15.4 Directive Summary

| Directive | Syntax | Description |
|-----------|--------|-------------|
| `.ORG` | `.ORG address` | Set assembly origin |
| `.BASE` | `.BASE address` | Set ROM image base address |
| `.EQU` | `SYMBOL .EQU value` | Define constant |
| `.WORD` | `.WORD value [,value...]` | Emit 16-bit data words |
| `.TEXT` | `.TEXT "string" [,bytes...]` | Emit ASCII string (word-aligned, use `\0` or `, 0` for null) |
| `.BYTE` | `.BYTE value [,value...]` | Emit bytes; PC advances by exact byte count |
| `.ALIGN` | `.ALIGN [boundary]` | Pad PC to boundary (default 2); boundary must be power of 2 |
| `.DS` | `.DS count [,fill]` | Reserve bytes with fill value (default `$00`) |
| `.INCLUDE` | `.INCLUDE "filename"` | Insert source file inline |
| `.IF` | `.IF symbol` | Begin conditional block (assemble if symbol ≠ 0) |
| `.ENDIF` | `.ENDIF` | End conditional block |

---

## Appendix A: Sample Program — Hex Dump Routine

This example demonstrates C-style calling conventions, parameter passing, stack management, and typical K16 programming patterns.

```asm
;===============================================================
; K16 HexDump - Sample Program
; 
; Demonstrates:
;   - Stack-based parameter passing (C calling convention)
;   - 24-bit address arithmetic
;   - Memory-mapped I/O
;   - Byte-level memory access
;   - Subroutine calls with callee cleanup
; 
; Version: 3.1 (April 2026)
; Updated for new memory map:
;   - Reset vector at $FF0000
;   - Stack/ZP at page $00
;   - Terminal I/O at $D00000
;===============================================================

;---------------------------------------------------------------
; Memory Map Constants
;---------------------------------------------------------------
TERMINAL     .EQU        $D00000             ; Terminal output

;---------------------------------------------------------------
; Program Code - ROM at $FF0000 (reset vector)
;---------------------------------------------------------------
             .BASE       $F00000             ; ROM image base address
             .ORG        $FF0000             ; Reset vector - CPU starts here

;---------------------------------------------------------------
; Entry point (reset vector)
;---------------------------------------------------------------
Start:
                ; Initialize stack pointer
                LOADI       X3, #$FFF0
                LOADI       Y3, #$00

                ; Call HexDump(start_low, start_high, end_low, end_high)
                ; Push right-to-left: param4 first, param1 last
                
                PUSH        #>DumpEnd, XY3      ; param4: end_high
                PUSH        #<DumpEnd, XY3      ; param3: end_low
                PUSH        #>DumpStart, XY3    ; param2: start_high
                PUSH        #<DumpStart, XY3    ; param1: start_low
                CALL        HexDump
                
                HALT        #$00

;---------------------------------------------------------------
; HexDump - Output hex dump of memory range
;---------------------------------------------------------------
; void HexDump(uint16 start_low, uint8 start_high, 
;              uint16 end_low, uint8 end_high)
;
; Output format (16 bytes per line, 16-byte aligned):
;   AAAAAA: XX XX XX XX XX XX XX XX  XX XX XX XX XX XX XX XX  ................
;
; Stack frame at entry:
;   [X3+0]  = return address low   (pushed last = top of stack)
;   [X3+2]  = return address high
;   [X3+4]  = param1: start_low
;   [X3+6]  = param2: start_high
;   [X3+8]  = param3: end_low
;   [X3+10] = param4: end_high
;
; Clobbers: D0, D1, X0-X1, Y0-Y1
; Preserves: D2, D3 (saved/restored)
;---------------------------------------------------------------
HexDump:
                ; Save callee-save registers
                PUSH        D2, XY3
                PUSH        D3, XY3

                ; Setup terminal pointer in XY1
                LOADI       X1, #<TERMINAL
                LOADI       Y1, #>TERMINAL

                ; Load start address into XY0 (current pointer)
                LOADX       X0, [XY3 + #8]      ; start_low
                LOADY       Y0, [XY3 + #10]     ; start_high
                
                ; Align X0 down to 16-byte boundary
                AND         X0, #$FFF0
                
                ; Load end address into D2/D3 (can't use XY2 easily)
                LOADD       D2, [XY3 + #12]     ; end_low
                LOADD       D3, [XY3 + #14]     ; end_high

.line_loop:
                ; Check if done (Y0:X0 >= D3:D2)
                CMP         Y0, D3
                BCC         .do_line            ; Y0 < D3, continue
                BNE         .exit               ; Y0 > D3, done
                CMP         X0, D2
                BCS         .exit               ; X0 >= D2, done

.do_line:
                ; Save current address for ASCII column
                PUSH        X0, XY3
                PUSH        Y0, XY3
                
                ; Print address "AAAAAA: "
                PUSH        Y0, XY3
                CALL        PrintHexByte
                PUSH        X0, XY3
                CALL        PrintHexWord
                
                LOADI       D0, #$3A            ; ':'
                STOREB      D0, [XY1]
                LOADI       D0, #$20            ; ' '
                STOREB      D0, [XY1]

                ; Use stack to track byte count (push initial 0)
                PUSH        #0, XY3             ; byte counter

.byte_loop:
                ; Check if at end address
                CMP         Y0, D3
                BCC         .print_byte         ; Y0 < D3, continue
                BNE         .finish_line        ; Y0 > D3, done with data
                CMP         X0, D2
                BCS         .finish_line        ; X0 >= D2, done with data

.print_byte:
                ; Get byte from memory
                LOADB       D0, [XY0]
                
                ; Print byte as hex
                PUSH        D0, XY3
                CALL        PrintHexByte
                
                ; Print space
                LOADI       D0, #$20
                STOREB      D0, [XY1]
                
                ; Check byte counter for middle separator (after byte 7)
                LOADD       D0, [XY3]           ; get counter from stack top
                CMP         D0, #7
                BNE         .no_mid_space
                LOADI       D1, #$20
                STOREB      D1, [XY1]
.no_mid_space:
                
                ; Increment current address (24-bit)
                ADD         X0, #1
                ADC         Y0, #0
                
                ; Increment byte counter on stack
                LOADD       D0, [XY3]
                ADD         D0, #1
                STORED      D0, [XY3]
                
                CMP         D0, #16             ; 16 bytes per line
                BCC         .byte_loop

.finish_line:
                ; Get bytes printed from stack (don't pop yet - need for ASCII)
                LOADD       D0, [XY3]           ; D0 = bytes printed
                
                ; Pad remaining positions with spaces if line incomplete
.pad_loop:
                CMP         D0, #16
                BCS         .print_ascii
                ; Print "   " (3 spaces for missing "XX ")
                LOADI       D1, #$20
                STOREB      D1, [XY1]
                STOREB      D1, [XY1]
                STOREB      D1, [XY1]
                ; Extra space at position 7 for middle separator
                CMP         D0, #7
                BNE         .no_pad_mid
                STOREB      D1, [XY1]
.no_pad_mid:
                ADD         D0, #1
                BRA         .pad_loop

.print_ascii:
                ; Print "  " separator between hex and ASCII
                LOADI       D0, #$20
                STOREB      D0, [XY1]
                STOREB      D0, [XY1]
                
                ; Get byte count, then restore line start address
                POP         D0, XY3             ; byte count -> D0
                POP         Y0, XY3             ; restore Y0
                POP         X0, XY3             ; restore X0
                
                ; D0 = number of ASCII characters to print
                LOADI       D1, #0              ; D1 = ASCII counter
                
.ascii_loop:
                CMP         D1, D0
                BCS         .print_newline
                
                ; Get byte from memory
                PUSH        D0, XY3             ; save byte count
                PUSH        D1, XY3             ; save counter
                LOADB       D0, [XY0]
                ADD         X0, #1
                ADC         Y0, #0
                
                ; Check if printable ($20-$7E)
                CMP         D0, #$20
                BCC         .not_printable      ; < $20, not printable
                CMP         D0, #$7F
                BCC         .print_char         ; < $7F, printable
                
.not_printable:
                LOADI       D0, #$2E            ; '.'
                
.print_char:
                STOREB      D0, [XY1]
                POP         D1, XY3             ; restore counter
                POP         D0, XY3             ; restore byte count
                ADD         D1, #1
                BRA         .ascii_loop

.print_newline:
                LOADI       D0, #$0A
                STOREB      D0, [XY1]
                BRA         .line_loop

.exit:
                POP         D3, XY3
                POP         D2, XY3
                RET         #4w                 ; cleanup 8 bytes (4 params)

;---------------------------------------------------------------
; PrintHexWord - Print 16-bit value as 4 hex digits
;---------------------------------------------------------------
; void PrintHexWord(uint16 value)
; Stack: [X3+4] = value
;---------------------------------------------------------------
PrintHexWord:
                LOADD       D0, [XY3 + #4]
                
                ; Use HIGH lookup to get high byte
                PUSH        D0, XY3             ; save original
                HIGH        D0                  ; D0 = high byte
                PUSH        D0, XY3
                CALL        PrintHexByte
                
                ; Get low byte
                POP         D0, XY3             ; restore original
                AND         D0, #$FF            ; mask to low byte
                PUSH        D0, XY3
                CALL        PrintHexByte
                
                RET         #1w                 ; cleanup 2 bytes

;---------------------------------------------------------------
; PrintHexByte - Print byte value as 2 hex digits
;---------------------------------------------------------------
; void PrintHexByte(uint8 value)
; Stack: [X3+4] = value (only low 8 bits used)
;---------------------------------------------------------------
PrintHexByte:
                LOADD       D0, [XY3 + #4]
                AND         D0, #$FF
                
                ; Use SHR4 lookup for high nibble
                PUSH        D0, XY3             ; save original
                SHR4        D0                  ; D0 = high nibble
                CALL        NibbleToAscii
                STOREB      D0, [XY1]
                
                ; Get low nibble
                POP         D0, XY3
                AND         D0, #$0F
                CALL        NibbleToAscii
                STOREB      D0, [XY1]
                
                RET         #1w                 ; cleanup 2 bytes

;---------------------------------------------------------------
; NibbleToAscii - Convert 0-15 in D0 to ASCII '0'-'F'
;---------------------------------------------------------------
; Input: D0 = nibble (0-15)
; Output: D0 = ASCII character ('0'-'9' or 'A'-'F')
;---------------------------------------------------------------
NibbleToAscii:
                CMP         D0, #10
                BCS         .is_letter
                ADD         D0, #$30            ; '0'-'9'
                RET
.is_letter:
                SUB         D0, #10
                ADD         D0, #$41            ; 'A'-'F'
                RET

;---------------------------------------------------------------
; Test data to dump
;---------------------------------------------------------------
DumpStart:
                .TEXT       "Hello, World!\n", 0
                .TEXT       "K16 HexDump v3.1", 0
                .WORD       $0000, $1234, $5678, $9ABC
                .WORD       $DEF0, $FFFF, $CAFE, $BABE
DumpEnd:
```

**Key patterns demonstrated:**
- `.BASE` directive for ROM image base address
- Stack initialization at page $00 (Y3=$00, X3=$FFF0)
- C-style calling convention (parameters pushed right-to-left)
- Callee cleanup with `RET #4w` (8 bytes = 4 parameters)
- Local labels with `.` prefix for scope
- Register preservation (push/pop D2, D3)
- 24-bit address comparison using Y then X registers
- LOOKUP operations (`HIGH`, `SHR4`) for byte/nibble extraction
- Byte-level memory access with `LOADB`/`STOREB`
- Memory-mapped I/O (terminal output via `STOREB D0, [XY1]`)

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | December 2025 | Initial release |
| 1.1 | 17 December 2025 | Updated ALU to 2-operand format; added SWAP, STOREXY, LOADXY; full JMP family (JMP16, JMPT, JMPI); updated CMP modes; clarified MOVE modes |
| 1.2 | 22 December 2025 | Added LOADP/STOREP and LOADPB/STOREPB paged memory instructions; verified MOVE PC for indirect jumps; renamed JMPI to JMPXY; renamed SWAP (lookup) to SWAPB; added byte operations section |
| 1.3 | 24 December 2025 | Updated branch instructions: added BLT, BGT, BLE, BHS/BLO aliases; removed BMI/BPL; short branch range now 0-31 bytes |
| 1.4 | 4 January 2026 | Added extended LOOKUP operations (SHL4, SHR4, ASR4, ASR8, MULB, RECIP); fixed HIGH description; LOOKUP now 3 cycles |
| 1.5 | 4 January 2026 | Added interrupt system documentation (DINT, EINT, RTI, INT); vector table dispatch example; nested interrupts; renamed to K16 Reference Manual |
| 1.6 | 6 January 2026 | Added Conditional Set (Scc) instructions: SEQ, SNE, SCS, SCC, SMI, SPL, SAL |
| 1.7 | 6 January 2026 | Added INC/DEC instructions: dedicated opcode $02 for XY pairs with 24-bit carry/borrow; D/X/Y register syntax sugar |
| 1.8 | 6 January 2026 | Added LEA instruction (opcode $03): 4 modes for address calculation with 24-bit carry propagation; expanded Section 1 with architecture summary, memory map, and opcode table |
| 1.9 | 6 January 2026 | Added cycle count quick reference (12.2) and flags affected summary (12.3) |
| 2.0 | 7 January 2026 | Updated all cycle counts from verified microcode; fixed LOADI modes (00/01 not 10/11); corrected CALL cycles (11-12), JMPT (4), JMPXY (3), branch (3-4), stack ops |
| 2.1 | 7 January 2026 | Reformatted all Section 6 instruction descriptions with consistent format: heading, brief description, opcode, mode/syntax/operation/cycles/words table, flags, examples |
| 2.2 | 7 January 2026 | Fixed Scc conditions to match Branch (SLT/SGT/SGE/SLE instead of SMI/SPL/SAL); Scc always 2 words |
| 2.3 | 10 January 2026 | Added Section 9: Zero Page Programming (memory map, stack layout, variable allocation, LOADP/STOREP usage); renumbered sections 9-12 → 10-13 |
| 2.4 | 10 January 2026 | Fixed Zero Page cycle counts (LOADP=3, not 1); reorganized sections: Byte Operations→7, Zero Page→8, Special Features→9, Expression Evaluation→10 |
| 2.5 | 12 January 2026 | Fixed Scc conditions in opcode map to match Branch (SLT/SGT/SGE/SLE, not SMI/SPL/SAL) |
| 2.6 | 17 January 2026 | Updated memory map: RAM at $00-$BF, I/O at $C0-$DF, ROM at $E0-$FF; reset vector $FF0000; Zero Page now page $00; LOOKUP tables at $E0-$FA |
| 2.7 | 17 January 2026 | Added .BASE directive; clarified .TEXT requires explicit `, 0` for null termination; updated Appendix A sample |
| 2.8 | 18 January 2026 | Converted all .EQU examples to symbol-first format (`SYMBOL .EQU value`) |
| 2.9 | March 2026 | Added directives: `.BYTE`, `.ALIGN`, `.DS`, `.INCLUDE`; added local labels scoped to enclosing global label; odd-address label check downgraded from error to warning |
| 3.0 | March 2026 | Added conditional assembly directives `.IF` / `.ENDIF` (Section 4.10); updated directive summary table |
| 3.1 | April 2026 | Added CALLXY (opcode $13 mode 11): indirect call via XY register, 10 cycles; added TRAP (opcode $1E mode 00): software syscall with vector table, 12 cycles; relocated RET from $13 mode 11 to $1E mode 11; updated opcode table, instruction summary, cycle count table, new section 6.11 (TRAP/RET); updated zero page memory map — vector table now $0000-$01FF (512 bytes), system variables $0200, Forth $0300, Pascal $0380, application ZP $0400; added INC XYn byte traversal warnings (section 6.3 and 8.8); added INT/TRAP #0 dispatcher note (section 6.14); added Section 11 V2 ABI calling convention; fixed Appendic A stack frame comment and version date |
| 3.2 | April 2026 | Added NEG instruction (opcode $00 mode 11): two's complement negate, 3 cycles, documented in section 6.3 (Arithmetic); cross-reference in section 6.13; updated opcode table, instruction summary, cycle count table, flags table |
| 3.3 | 7 April 2026 | Added Section 8 (Endianness): complete little-endian reference for all memory operations; covers STORED/LOADD, STOREX/LOADX, STOREB/LOADB, STOREXY/LOADXY, CALL24/RET stack layout, PUSH/POP single and XY, TRAP, string/byte data, instruction ROM encoding, and toolchain summary; all entries verified by hardware test or microcode inspection; renumbered sections 8–14 → 9–15 |

---

*— End of Document —*
