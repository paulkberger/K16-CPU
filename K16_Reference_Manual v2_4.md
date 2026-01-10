# K16 Reference Manual

Version 2.4 — January 10, 2026

---

## 1. Overview

The K16 is a 16-bit CPU with a 24-bit address space, designed around ROM-based lookup tables for both ALU operations and instruction decoding. This reference manual covers the instruction set architecture, assembly syntax, and programming guidelines.

### 1.1 Architecture Summary

| Feature | Specification |
|---------|---------------|
| Data width | 16 bits |
| Address space | 24 bits (16MB) |
| Registers | D0-D3 (data), X0-X3/Y0-Y3 (index), XY0-XY3 (24-bit pairs) |
| Stack pointer | XY3 (hardcoded for CALL/RET/PUSH/POP) |
| Status flags | C (Carry), Z (Zero), N (Negative), V (Overflow) |
| Interrupt levels | 8 (IRQ0-IRQ7, priority encoded) |

### 1.2 Memory Map

| Address Range | Size | Description |
|---------------|------|-------------|
| $00_0000 - $0F_FFFF | 1MB | ROM Bank 0 (Program ROM) |
| $10_0000 - $1F_FFFF | 1MB | ROM Bank 1 (Lookup Tables) |
| $20_0000 - $7F_FFFF | 6MB | RAM Banks 0-5 |
| $80_0000 - $EF_FFFF | 7MB | Reserved/Expansion |
| $FF_0000 - $FF_FFFF | 64KB | Memory-Mapped I/O |

### 1.3 Opcode Map

| Opcode | Hex | Mnemonic | Description |
|--------|-----|----------|-------------|
| 00000 | $00 | MISC | NOP, HALT |
| 00001 | $01 | LOOKUP | SHL, SHR, ASR, ROL, ROR, SWAPB, HIGH, LOW, SHL4, SHR4, ASR4, ASR8, MULB, RECIP |
| 00010 | $02 | INC/DEC | Increment/Decrement XY pair (24-bit) |
| 00011 | $03 | LEA | Load Effective Address |
| 00100 | $04 | Scc | Conditional Set (SEQ, SNE, SCS, SCC, SMI, SPL, SAL) |
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
| 10011 | $13 | CALL/RET | Subroutine (CALL24, CALL16, CALLR, RET) |
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
| 11110 | $1E | — | *spare* |
| 11111 | $1F | INT | Interrupt control (DINT, EINT, RTI, INT) |

### 1.4 Instruction Encoding

Most instructions use a common 16-bit format:

```
15  14  13  12  11  10   9   8   7   6   5   4   3   2   1   0
├───────────────┼───────┼───────────────────────────────────────┤
│    OPCODE     │ MODE  │           Operand Fields              │
│    (5 bits)   │(2 bits)│              (9 bits)                │
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

### 4.2 .EQU — Define Constant

Defines a symbolic constant. Supports expressions and 24-bit values ($000000-$FFFFFF).

```asm
.EQU BUFFER_SIZE, 256
.EQU HEADER, 16
.EQU TOTAL, BUFFER_SIZE + HEADER    ; Expression
.EQU WORDS, 8w                      ; Word suffix (= 16)
.EQU VIDEO_RAM, $0F0000             ; 24-bit address
```

### 4.3 .WORD — Define Data Word

Emits one or more 16-bit data words. Supports expressions and symbols.

```asm
.WORD $1234              ; Single word
.WORD $0000, $FFFF       ; Multiple words
.WORD LABEL + 4          ; Expression
```

### 4.4 .TEXT — Define String

Emits ASCII text as packed words (2 characters per word), null-terminated. If the string has odd length, it is padded with a null byte to maintain word alignment.

```asm
.TEXT "Hello"            ; 3 words: "He", "ll", "o\0"
.TEXT "Hi"               ; 2 words: "Hi", "\0\0" (padded)
```

**Escape Sequences:**

| Escape | Character |
|--------|-----------|
| `\n` | Newline (LF) |
| `\r` | Carriage Return (CR) |
| `\t` | Tab |
| `\\` | Backslash |
| `\"` | Double Quote |

```asm
.TEXT "Line 1\nLine 2"   ; String with embedded newline
.TEXT "Tab:\tValue"      ; String with tab
.TEXT "Say \"Hi\""       ; String with embedded quotes
.TEXT "C:\\PATH\\FILE"   ; String with backslashes
```

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

| Mnemonic | Page | Operation |
|----------|------|-----------|
| SHL4 | $04 | Shift left 4 bits (×16) |
| SHR4 | $06 | Shift right 4 bits (÷16 unsigned) |
| ASR4 | $08 | Arithmetic shift right 4 (÷16 signed) |
| ASR8 | $0A | Arithmetic shift right 8 (÷256 signed) |
| MULB | $0C | Multiply hi byte × lo byte |
| RECIP | $0E | Reciprocal (65536 ÷ D) |
| SHL | $10 | Shift left 1 bit (×2) |
| SHR | $12 | Shift right 1 bit (÷2 unsigned) |
| ASR | $14 | Arithmetic shift right 1 (÷2 signed) |
| ROL | $16 | Rotate left through carry |
| ROR | $18 | Rotate right through carry |
| SWAPB | $1A | Byte swap ($1234 → $3412) |
| HIGH | $1C | Extract high byte (D >> 8) |
| LOW | $1E | Extract low byte (D AND $00FF) |

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
LOOKUP D0, #$20         ; Custom table at page $20 (RAM)
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

**Opcode:** $13

| Mode | Syntax | Operation | Cycles | Words |
|------|--------|-----------|--------|-------|
| 00 | `CALL24 addr` | push PC; PC ← addr24 | 11 | 3 |
| 01 | `CALL16 addr` | push PC; PC[15:0] ← addr16 | 11 | 2 |
| 10 | `CALLR addr` | push PC; PC ← PC + offset | 12 | 2 |
| 11 | `RET` | PC ← pop; SP += imm5 | 5 | 1 |
| 11 | `RET #n` | PC ← pop; SP += n (cleanup) | 5 | 1 |

**Flags:** Not affected

```asm
CALL    subroutine      ; 24-bit absolute (alias for CALL24)
CALL24  subroutine      ; 24-bit absolute address
CALL16  subroutine      ; 16-bit, current codepage
CALLR   subroutine      ; PC-relative
RET                     ; Return, no cleanup
RET     #4              ; Return, pop 4 extra bytes
```

### 6.11 Stack Operations

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

### 6.12 Control

Processor control instructions.

**Opcode:** $00

| Mode | Syntax | Operation | Cycles | Words |
|------|--------|-----------|--------|-------|
| 00 | `NOP` | No operation | 2 | 1 |
| 01 | `HALT` | Stop processor | 2 | 1 |
| 01 | `HALT #n` | Stop with code n | 2 | 1 |

**Flags:** Not affected

```asm
NOP                     ; Do nothing
HALT                    ; Stop execution
HALT #$FF               ; Stop with debug code
```

**Debug:** HALT displays D0 on ALU-A bus for debugging.

### 6.13 Interrupts

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

## 8. Zero Page Programming

The K16 provides efficient "zero page" style access to frequently-used variables using the LOADP/STOREP instructions. This technique saves significant cycles compared to indexed addressing.

### 8.1 Concept

Traditional indexed access requires loading a base address into an XY pair before accessing memory. Zero page access uses Y3 (the stack page register) as an implicit base, allowing direct access to any location in the stack segment with a single instruction.

**Performance comparison:**

| Method | Instructions | Cycles | XY Register |
|--------|--------------|--------|-------------|
| Indexed access | LOADI X0 + LOADI Y0 + LOADD | 6 | XY0 consumed |
| Zero page | LOADP | 3 | None (uses Y3) |

**Savings:** 3 cycles per load (50% faster), plus XY registers remain free for other work.

### 8.2 Memory Map (Page $20)

The stack segment at page $20 is organized for both stack operations and zero page variables:

| Address Range | Offset | Size | Purpose |
|---------------|--------|------|---------|
| $20_0000-$20_0003 | $0000 | 4 bytes | Interrupt vector |
| $20_0004-$20_00FF | $0004 | 252 bytes | System variables |
| $20_0100-$20_017F | $0100 | 128 bytes | Forth interpreter reserved |
| $20_0180-$20_01FF | $0180 | 128 bytes | Pascal/compiler reserved |
| $20_0200-$20_0FFF | $0200 | ~3.5KB | Application zero page |
| $20_1000-$20_7FFF | $1000 | ~28KB | User dictionary / heap |
| $20_8000-$20_EFFF | $8000 | ~28KB | Free / expansion |
| $20_F000-$20_FFFF | $F000 | 4KB | Stack space (grows down) |

### 8.3 Stack Layout

```
$20FFFE ─┬─ Data stack top (XY2)
         │  Data stack grows DOWN
$20F000 ─┼─ 
         │
$20EFFE ─┬─ Return stack top (XY3)
         │  Return stack grows DOWN
$20E000 ─┼─
         │  
$208000 ─┼─ User dictionary (HERE)
         │  Dictionary grows UP (~24KB)
$201000 ─┼─
         │
$200FFF ─┼─ Application ZP top
         │  Application variables (~3.5KB)
$200200 ─┼─ Application ZP base
         │
$2001FF ─┼─ Pascal/compiler (128 bytes)
$200180 ─┼─
         │
$20017F ─┼─ Forth reserved (128 bytes)
$200100 ─┼─
         │
$2000FF ─┼─ System variables (~252 bytes)
$200004 ─┼─
         │
$200000 ─┴─ Interrupt vector (4 bytes)
```

### 8.4 Accessing Zero Page Variables

Use LOADP/STOREP with Y3 as the page register:

```asm
; Define zero page variable locations
.EQU ZP_COUNTER,    $0200
.EQU ZP_FLAGS,      $0202
.EQU ZP_TEMP,       $0204

; Load from zero page (3 cycles)
LOADP   D0, Y3, [#ZP_COUNTER]   ; D0 ← [$20:0200]
LOADP   D1, Y3, [#ZP_FLAGS]     ; D1 ← [$20:0202]

; Store to zero page (5 cycles)
STOREP  D0, Y3, [#ZP_TEMP]      ; [$20:0204] ← D0

; Byte access (3 cycles load, 5 cycles store)
LOADPB  D0, Y3, [#ZP_FLAGS]     ; Load byte, zero-extended
STOREPB D0, Y3, [#ZP_FLAGS]     ; Store low byte only
```

### 8.5 Reserved Allocations

#### System Variables ($0000-$00FF)

```asm
.EQU INT_VECTOR_PAGE,  $0000    ; ISR page (required)
.EQU INT_VECTOR_ADDR,  $0002    ; ISR address (required)
.EQU SYS_TICKS,        $0004    ; System tick counter
.EQU SYS_FLAGS,        $0006    ; System status flags
```

#### Forth Interpreter ($0100-$017F)

```asm
.EQU ZP_LATEST,        $0100    ; Dictionary head (Y)
.EQU ZP_LATEST_X,      $0102    ; Dictionary head (X)
.EQU ZP_HERE,          $0104    ; Next free byte (Y)
.EQU ZP_HERE_X,        $0106    ; Next free byte (X)
.EQU ZP_STATE,         $0108    ; Compile state (0=interpret)
.EQU ZP_TOIN,          $010A    ; >IN parse position
.EQU ZP_NUMTIB,        $010C    ; #TIB character count
.EQU ZP_BASE,          $010E    ; Number base (default 10)
```

#### Pascal/Compiler Runtime ($0180-$01FF)

```asm
.EQU PAS_FRAME,        $0180    ; Frame pointer backup
.EQU PAS_HEAP,         $0182    ; Heap pointer
.EQU PAS_TEMP1,        $0184    ; Expression temporary 1
.EQU PAS_TEMP2,        $0186    ; Expression temporary 2
```

### 8.6 Application Variables ($0200-$0FFF)

Organize by usage frequency — place most-used variables at lower addresses:

```asm
; High-frequency variables
.EQU APP_COUNT,        $0200    ; Loop counter
.EQU APP_TEMP_A,       $0202    ; Temporary A
.EQU APP_TEMP_B,       $0204    ; Temporary B
.EQU APP_RESULT,       $0206    ; Result

; 24-bit pointers (stored as Y at offset, X at offset+2)
.EQU APP_PTR1_Y,       $0300    ; Pointer 1 page
.EQU APP_PTR1_X,       $0302    ; Pointer 1 offset

; Application state
.EQU APP_MODE,         $0400    ; Current mode
.EQU APP_STATUS,       $0402    ; Status flags

; Buffers and arrays
.EQU APP_BUFFER,       $0500    ; 256-byte work buffer
```

### 8.7 Example: Complete Program

```asm
;=====================================================
; Zero Page Definitions
;=====================================================
.EQU ZP_COUNT,     $0200
.EQU ZP_SUM,       $0202
.EQU ZP_PTR_X,     $0204
.EQU ZP_PTR_Y,     $0206

;=====================================================
; Program Code
;=====================================================
        .ORG    $010000

START:
        ; Initialize stacks (Y3=$20 enables ZP access)
        LOADI   X2, #$FFFE
        LOADI   Y2, #$20
        LOADI   X3, #$EFFE
        LOADI   Y3, #$20
        
        ; Setup interrupt vector
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

### 8.8 Best Practices

1. **Reserve $0000-$00FF for system use** — interrupt vector and OS variables
2. **Allocate frequently-used variables first** — keep hot variables in $0100-$02FF
3. **Group related variables** — improves code readability
4. **Use .EQU for all addresses** — makes code maintainable
5. **Document variable usage** — zero page is a shared resource
6. **Use LOADP/STOREP consistently** — 3 cycles vs 6 for indexed load (50% faster)

---

## 9. Special Features

### 9.1 Word Suffix (w)

The 'w' suffix multiplies a value by 2, converting word counts to byte counts. Useful for structure field offsets and stack cleanup.

```asm
LOADI D0, #4w           ; = 8 (4 words × 2)
LOADD D0, [XY0+#3w]     ; offset = 6 bytes
RET #2w                 ; cleanup 4 bytes (2 words)
.EQU STRUCT_SIZE, 8w    ; = 16 bytes
LOADI D0, #10 + 2w      ; = 14 (10 + 4)
```

### 9.2 Derivative Operators (24-bit Address Handling)

The K16 uses 24-bit addresses but registers are 8-bit (Y) or 16-bit (X). These operators extract portions of 24-bit addresses for loading into XY register pairs.

| Operator | Description | Bits Extracted |
|----------|-------------|----------------|
| `#>` | High byte (bank) | Bits 23-16 |
| `#<` | Low word | Bits 15-0 |

**Loading a 24-bit address into an XY pair:**

```asm
.EQU BUFFER, $12AB34

LOADI Y1, #>BUFFER      ; Y1 = $12 (high byte)
LOADI X1, #<BUFFER      ; X1 = $AB34 (low word)
; XY1 now contains $12AB34

LOADD D0, [XY1]         ; Access data at BUFFER
```

**Multiple pointers:**

```asm
.EQU VIDEO_RAM, $0F0000
.EQU ROM_TABLE, $FF8000

; Load video pointer into XY0
LOADI Y0, #>VIDEO_RAM   ; Y0 = $0F
LOADI X0, #<VIDEO_RAM   ; X0 = $0000

; Load ROM pointer into XY2
LOADI Y2, #>ROM_TABLE   ; Y2 = $FF
LOADI X2, #<ROM_TABLE   ; X2 = $8000
```

**Note:** Plain `#symbol` without an operator defaults to the low word (bits 15-0).

---

## 10. Expression Evaluation

The assembler supports arithmetic expressions in immediate values, .EQU directives, and .WORD directives.

### 10.1 Operators

| Operator | Description | Precedence |
|----------|-------------|------------|
| ( ) | Parentheses (grouping) | Highest |
| - + | Unary minus/plus | High |
| * / | Multiplication, Division | Medium |
| + - | Addition, Subtraction | Low |

### 10.2 Examples

```asm
.EQU SIZE, 256
.EQU HEADER, 16
.EQU TOTAL, SIZE + HEADER           ; = 272
.EQU HALF, SIZE / 2                 ; = 128
.EQU COMPLEX, (SIZE - HEADER) / 2   ; = 120

LOADI D0, #SIZE + 4                 ; = 260
LOADI D1, #(TOTAL / 4)              ; = 68
.WORD SIZE * 2                      ; Emits 512
```

---

## 11. Warnings and Errors

### 11.1 Word Alignment Warning

Word operations (LOADD, STORED, etc.) with odd offsets generate warnings:

```asm
LOADD D0, [XY0+#3]      ; WARNING: odd offset may cause misalignment
```

The code is still assembled, but may not work correctly on hardware.

### 11.2 Common Errors

| Error | Cause |
|-------|-------|
| Undefined symbol | Label or constant not defined |
| STORE requires register source | Tried `STORED #value, [XY0]` — not supported |
| Immediate value out of range | IMM5 mode requires 0-31; use larger value for IMM16 mode |
| .ORG address is odd | K16 requires even addresses |
| Branch target out of range | Short branch (±127) exceeded; use .L suffix |
| Invalid destination register | ALU dest must be D0-D3, X0-X3, or Y0-Y3 (not ORDB/SR/PCH/PCL) |

---

## 12. Output

### 12.1 Listing File

The assembler generates a detailed listing showing address, machine code, and source:

```
Addr     OpCode   Imm     Decode    Source
00 0100  C014     ----    18.0.2    LOADI D0, #20      ; IMM5 mode (value ≤ 31)
00 0102  C620     0064    18.3.4    LOADI D1, #100     ; IMM16 mode (value > 31)
```

**Decode format:** Opcode.Mode.Words — The mode field shows which addressing mode was selected (e.g., mode 0 = IMM5, mode 3 = IMM16 for LOADI).

### 12.2 Symbol Table

Shows all defined labels and constants with their values:

```
Symbol Table:
  BUFFER_SIZE  = $0100 (Constant, line 5)
  START        = $0200 (Label, line 10)
```

---

## 13. Quick Reference

### 13.1 Instruction Summary

| Category | Instructions |
|----------|--------------|
| Load | LOADI, LOADD, LOADX, LOADY, LOADB, LOADXY, LOADP, LOADPB |
| Store | STORED, STOREX, STOREY, STOREB, STOREXY, STOREP, STOREPB |
| Move | MOVE, SWAP |
| Arithmetic | ADD, ADC, SUB, SBC, INC, DEC |
| Logical | AND, OR, XOR, NOT |
| Shift/Rotate | SHL, SHR, ASR, ROL, ROR, SWAPB, HIGH, LOW, SHL4, SHR4, ASR4, ASR8, MULB, RECIP, LOOKUP |
| Address | LEA |
| Compare | CMP |
| Conditional Set | SEQ, SNE, SCS, SCC, SMI, SPL, SAL |
| Branch | BEQ, BNE, BCS/BHS, BCC/BLO, BLT, BGT, BGE, BLE, BRA |
| Jump | JMP, JMP24, JMP16, JMPT, JMPXY |
| Subroutine | CALL, CALL24, CALL16, CALLR, RET |
| Stack | PUSH, POP (supports D, X, Y, XY, D group, immediate) |
| Control | NOP, HALT, DINT, EINT, RTI |

### 13.2 Cycle Count Reference

| Instruction | Mode 00 | Mode 01 | Mode 10 | Mode 11 | Notes |
|-------------|---------|---------|---------|---------|-------|
| **Control** |
| NOP | 2 | — | — | — | No operation |
| HALT | — | 2 | — | — | Stop processor |
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
| RET | — | — | — | 5 | Return (+ optional cleanup) |
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
| **Interrupt ($1F)** |
| DINT | 2 | — | — | — | Disable interrupts |
| EINT | — | 2 | — | — | Enable interrupts |
| RTI | — | — | 8 | — | Return from interrupt |
| INT | — | — | — | 16 | Hardware interrupt |

### 13.3 Flags Affected

| Category | Instructions | C | Z | N | V |
|----------|--------------|---|---|---|---|
| Arithmetic | ADD, ADC, SUB, SBC | ✓ | ✓ | ✓ | ✓ |
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

### 13.4 Directive Summary

| Directive | Usage |
|-----------|-------|
| .ORG | `.ORG address` — Set assembly origin |
| .EQU | `.EQU symbol, value` — Define constant |
| .WORD | `.WORD value [,value...]` — Emit data words |
| .TEXT | `.TEXT "string"` — Emit ASCII string |

---

## Appendix A: Sample Program — Hex Dump Routine

This example demonstrates C-style calling conventions, parameter passing, stack management, and typical K16 programming patterns.

```asm
;===============================================================
; K16 Hex Dump Routine - C-style calling convention
; Parameters pushed right-to-left, callee cleanup via RET #nw
; 
; Version: 2.1 (December 4, 2025)
; Status: 16 bytes per line, 16-byte aligned addresses
;===============================================================

                .ORG        $000000
                .EQU        STACK,    $220000
                .EQU        TERMINAL, $E00000

;---------------------------------------------------------------
; Entry point
;---------------------------------------------------------------
Start:
                LOADI       X3, #<STACK
                LOADI       Y3, #>STACK

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
;   AAAA00: XX XX XX XX XX XX XX XX  XX XX XX XX XX XX XX XX  ................
;
; Stack frame at entry:
;   [X3+0]  = return address high
;   [X3+2]  = return address low
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
                MOVE        D0, X0
                AND         X0, D0, #$FFF0
                
                ; Load end address into XY2
                LOADX       X2, [XY3 + #12]     ; end_low
                LOADY       Y2, [XY3 + #14]     ; end_high

.line_loop:
                ; Check if done (XY0 >= XY2)
                CMP         Y0, Y2
                BCC         .do_line            ; Y0 < Y2, continue
                BNE         .exit               ; Y0 > Y2, done
                CMP         X0, X2
                BCS         .exit               ; X0 >= X2, done

.do_line:
                ; Save X0 at start of line for ASCII column later
                PUSH        X0, XY3
                
                ; Print address "AAAAAA: "
                PUSH        Y0, XY3
                CALL        PrintHexByte
                PUSH        X0, XY3
                CALL        PrintHexWord
                
                LOADI       D0, #$3A            ; ':'
                STOREB      D0, [XY1]
                LOADI       D0, #$20            ; ' '
                STOREB      D0, [XY1]

                ; D3 = bytes printed this line (0-15)
                LOADI       D3, #0

.byte_loop:
                ; Check if at end address (XY0 >= XY2)
                CMP         Y0, Y2
                BCC         .print_byte         ; Y0 < Y2, continue
                BNE         .finish_line        ; Y0 > Y2, done
                CMP         X0, X2
                BCS         .finish_line        ; X0 >= X2, done

.print_byte:
                ; Get byte from memory
                LOADB       D0, [XY0]
                
                ; Print byte as hex
                PUSH        D0, XY3
                CALL        PrintHexByte
                
                ; Print space
                LOADI       D0, #$20
                STOREB      D0, [XY1]
                
                ; Extra space after byte 7 (middle separator)
                CMP         D3, #7
                BNE         .no_mid_space
                LOADI       D0, #$20
                STOREB      D0, [XY1]
.no_mid_space:
                
                ; Increment current address
                ADD         X0, #1
                ADC         Y0, #0
                
                ; Increment byte counter and check if line full
                ADD         D3, #1
                CMP         D3, #16             ; 16 bytes per line
                BCC         .byte_loop

.finish_line:
                ; D3 = bytes actually printed on this line (1-16)
                MOVE        D2, D3              ; Save byte count for ASCII loop
                
                ; Pad remaining positions with spaces if line incomplete
.pad_loop:
                CMP         D3, #16
                BCS         .print_ascii
                ; Print "   " (3 spaces for missing "XX ")
                LOADI       D0, #$20
                STOREB      D0, [XY1]
                STOREB      D0, [XY1]
                STOREB      D0, [XY1]
                ; Extra space at position 7 for middle separator
                CMP         D3, #7
                BNE         .no_pad_mid
                LOADI       D0, #$20
                STOREB      D0, [XY1]
.no_pad_mid:
                ADD         D3, #1
                BRA         .pad_loop

.print_ascii:
                ; Print "  " separator between hex and ASCII
                LOADI       D0, #$20
                STOREB      D0, [XY1]
                STOREB      D0, [XY1]
                
                ; Restore X0 to line start
                POP         X0, XY3
                
                ; Print D2 ASCII characters
                LOADI       D3, #0
.ascii_loop:
                CMP         D3, D2
                BCS         .print_newline
                
                ; Get byte from memory
                LOADB       D0, [XY0]
                ADD         X0, #1
                
                ; Check if printable ($20-$7E)
                CMP         D0, #$20
                BCC         .not_printable      ; < $20, not printable
                CMP         D0, #$7F
                BCC         .print_char         ; < $7F, printable
                
.not_printable:
                LOADI       D0, #$2E            ; '.'
                
.print_char:
                STOREB      D0, [XY1]
                ADD         D3, #1
                BRA         .ascii_loop

.print_newline:
                LOADI       D0, #$0A
                STOREB      D0, [XY1]
                BRA         .line_loop

.exit:
                POP         D3, XY3
                POP         D2, XY3
                RET         #4w

;---------------------------------------------------------------
; PrintHexWord - Print 16-bit value as 4 hex digits
;---------------------------------------------------------------
PrintHexWord:
                LOADD       D0, [XY3 + #4]
                
                ; D1 = D0 >> 8 (high byte via repeated subtraction)
                LOADI       D1, #0
.div256_loop:
                CMP         D0, #256
                BCC         .div256_done
                SUB         D0, #256
                ADD         D1, #1
                BRA         .div256_loop
.div256_done:
                ; D1 = high byte, D0 = low byte
                PUSH        D0, XY3
                
                PUSH        D1, XY3
                CALL        PrintHexByte
                
                POP         D0, XY3
                PUSH        D0, XY3
                CALL        PrintHexByte
                
                RET         #1w

;---------------------------------------------------------------
; PrintHexByte - Print byte value as 2 hex digits
;---------------------------------------------------------------
PrintHexByte:
                LOADD       D0, [XY3 + #4]
                AND         D0, #$FF
                
                ; D1 = high nibble, D0 = low nibble (via division by 16)
                LOADI       D1, #0
.div16_loop:
                CMP         D0, #16
                BCC         .div16_done
                SUB         D0, #16
                ADD         D1, #1
                BRA         .div16_loop
.div16_done:
                PUSH        D0, XY3
                MOVE        D0, D1
                CALL        NibbleToAscii
                STOREB      D0, [XY1]
                
                POP         D0, XY3
                CALL        NibbleToAscii
                STOREB      D0, [XY1]
                
                RET         #1w

;---------------------------------------------------------------
; NibbleToAscii - Convert 0-15 in D0 to ASCII '0'-'F'
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
                .TEXT       "Hello, World!\n"
                .TEXT       "K16 HexDump v2.1"
                .WORD       $0000, $1234, $5678, $9ABC
                .WORD       $DEF0, $FFFF, $CAFE, $BABE
DumpEnd:
```

**Key patterns demonstrated:**
- Stack initialization with 24-bit address using `#<` and `#>` operators
- C-style calling convention (parameters pushed right-to-left)
- Callee cleanup with `RET #4w` (8 bytes = 4 parameters)
- Local labels with `.` prefix for scope
- Register preservation (push/pop D2, D3)
- 24-bit address comparison using Y then X registers
- Byte-level memory access with `LOADB`/`STOREB`
- Memory-mapped I/O (terminal output via `STOREB D0, [XY1]`)

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | December 2025 | Initial release |
| 1.1 | December 17, 2025 | Updated ALU to 2-operand format; added SWAP, STOREXY, LOADXY; full JMP family (JMP16, JMPT, JMPI); updated CMP modes; clarified MOVE modes |
| 1.2 | December 22, 2025 | Added LOADP/STOREP and LOADPB/STOREPB paged memory instructions; verified MOVE PC for indirect jumps; renamed JMPI to JMPXY; renamed SWAP (lookup) to SWAPB; added byte operations section |
| 1.3 | December 24, 2025 | Updated branch instructions: added BLT, BGT, BLE, BHS/BLO aliases; removed BMI/BPL; short branch range now 0-31 bytes |
| 1.4 | January 4, 2026 | Added extended LOOKUP operations (SHL4, SHR4, ASR4, ASR8, MULB, RECIP); fixed HIGH description; LOOKUP now 3 cycles |
| 1.5 | January 4, 2026 | Added interrupt system documentation (DINT, EINT, RTI, INT); vector table dispatch example; nested interrupts; renamed to K16 Reference Manual |
| 1.6 | January 6, 2026 | Added Conditional Set (Scc) instructions: SEQ, SNE, SCS, SCC, SMI, SPL, SAL |
| 1.7 | January 6, 2026 | Added INC/DEC instructions: dedicated opcode $02 for XY pairs with 24-bit carry/borrow; D/X/Y register syntax sugar |
| 1.8 | January 6, 2026 | Added LEA instruction (opcode $03): 4 modes for address calculation with 24-bit carry propagation; expanded Section 1 with architecture summary, memory map, and opcode table |
| 1.9 | January 6, 2026 | Added cycle count quick reference (12.2) and flags affected summary (12.3) |
| 2.0 | January 7, 2026 | Updated all cycle counts from verified microcode; fixed LOADI modes (00/01 not 10/11); corrected CALL cycles (11-12), JMPT (4), JMPXY (3), branch (3-4), stack ops |
| 2.1 | January 7, 2026 | Reformatted all Section 6 instruction descriptions with consistent format: heading, brief description, opcode, mode/syntax/operation/cycles/words table, flags, examples |
| 2.2 | January 7, 2026 | Fixed Scc conditions to match Branch (SLT/SGT/SGE/SLE instead of SMI/SPL/SAL); Scc always 2 words |
| 2.3 | January 10, 2026 | Added Section 9: Zero Page Programming (memory map, stack layout, variable allocation, LOADP/STOREP usage); renumbered sections 9-12 → 10-13 |
| 2.4 | January 10, 2026 | Fixed Zero Page cycle counts (LOADP=3, not 1); reorganized sections: Byte Operations→7, Zero Page→8, Special Features→9, Expression Evaluation→10 |

---

*— End of Document —*
