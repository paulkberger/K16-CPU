# K16 Reference Manual

Version 3.21 — 8 August 2026

---

The K16 is a 16-bit CPU with a 24-bit address space, built from discrete TTL logic and organized around ROM-based lookup tables for both its ALU and instruction decoding. This manual is the complete reference for the architecture: the instruction set, assembly syntax and directives, addressing modes, memory layout, calling convention, and the assembler toolchain — with hardware- and microcode-verified detail throughout.

---

## Table of Contents

- [1. Overview](#1-overview)
  - [1.1 Architecture Summary](#11-architecture-summary)
  - [1.2 Memory Map](#12-memory-map)
  - [1.3 Opcode Map](#13-opcode-map)
  - [1.4 Instruction Encoding](#14-instruction-encoding)
  - [1.5 A Note on Cycle Counts](#15-a-note-on-cycle-counts)
- [2. Assembly Syntax](#2-assembly-syntax)
  - [2.1 Line Format](#21-line-format)
  - [2.2 Labels](#22-labels)
  - [2.3 Comments](#23-comments)
  - [2.4 Numbers](#24-numbers)
- [3. Registers](#3-registers)
  - [3.1 Register Overview](#31-register-overview)
  - [3.2 Typical Register Conventions](#32-typical-register-conventions)
  - [3.3 Status Register (SR)](#33-status-register-sr)
- [4. Assembler Directives](#4-assembler-directives)
  - [4.1 .ORG — Set Origin](#41-org--set-origin)
  - [4.2 .BASE — Set Image Base Address](#42-base--set-image-base-address)
  - [4.3 .EQU — Define Constant](#43-equ--define-constant)
  - [4.4 .WORD — Define Data Word](#44-word--define-data-word)
  - [4.5 .TEXT — Define String](#45-text--define-string)
  - [4.6 .BYTE — Define Byte Data](#46-byte--define-byte-data)
  - [4.7 .ALIGN — Align to Boundary](#47-align--align-to-boundary)
  - [4.8 .DS — Define Storage](#48-ds--define-storage)
  - [4.9 .INCLUDE — Include Source File](#49-include--include-source-file)
  - [4.10 .IF / .ENDIF — Conditional Assembly](#410-if--endif--conditional-assembly)
  - [4.11 .INCBIN — Include Binary File](#411-incbin--include-binary-file)
  - [4.12 .REGION / .RS / .ENDREGION — Region Reservation](#412-region--rs--endregion--region-reservation)
  - [4.13 .SPACE — Address Space Tagging](#413-space--address-space-tagging)
- [5. Addressing Modes](#5-addressing-modes)
  - [5.1 Register Direct](#51-register-direct)
  - [5.2 Immediate](#52-immediate)
  - [5.3 Memory Indirect (Mode 00)](#53-memory-indirect-mode-00)
  - [5.4 Indexed with D Register (Mode 01)](#54-indexed-with-d-register-mode-01)
  - [5.5 PC-Relative (Mode 10)](#55-pc-relative-mode-10)
  - [5.6 Indexed with Immediate (Mode 11)](#56-indexed-with-immediate-mode-11)
- [6. Instruction Set](#6-instruction-set)
  - [6.0 Instruction Set at a Glance](#60-instruction-set-at-a-glance)
  - [6.1 Data Movement](#61-data-movement)
  - [6.2 Load Effective Address (LEA)](#62-load-effective-address-lea)
  - [6.3 Arithmetic Operations](#63-arithmetic-operations)
  - [6.4 Logical Operations](#64-logical-operations)
  - [6.5 Shift and Rotate (LOOKUP)](#65-shift-and-rotate-lookup)
  - [6.6 Compare](#66-compare)
  - [6.7 Conditional Set (Scc)](#67-conditional-set-scc)
  - [6.8 Branch Instructions](#68-branch-instructions)
  - [6.9 Jump](#69-jump)
  - [6.10 Subroutine Call and Return](#610-subroutine-call-and-return)
  - [6.11 TRAP and RET-family Instructions](#611-trap-and-ret-family-instructions)
  - [6.12 Stack Operations](#612-stack-operations)
  - [6.13 Control](#613-control)
  - [6.14 Interrupts](#614-interrupts)
  - [6.15 Pseudo-Instructions](#615-pseudo-instructions)
- [7. Byte Operations](#7-byte-operations)
  - [7.1 Byte Load/Store Instructions](#71-byte-loadstore-instructions)
  - [7.2 Byte Manipulation via LOOKUP](#72-byte-manipulation-via-lookup)
  - [7.3 Byte Masking with AND](#73-byte-masking-with-and)
  - [7.4 Common Byte Patterns](#74-common-byte-patterns)
- [8. Memory Layout and Endianness](#8-memory-layout-and-endianness)
  - [8.1 Definition](#81-definition)
  - [8.2 Word Operations — STORED / LOADD / STOREX / LOADX](#82-word-operations--stored--loadd--storex--loadx)
  - [8.3 Byte Operations — STOREB / LOADB / STOREY / LOADY](#83-byte-operations--storeb--loadb--storey--loady)
  - [8.4 XY Pair Operations — STOREXY / LOADXY](#84-xy-pair-operations--storexy--loadxy)
  - [8.5 Stack Layout — CALL24 / RET](#85-stack-layout--call24--ret)
  - [8.6 Stack Layout — PUSH XY / POP XY](#86-stack-layout--push-xy--pop-xy)
  - [8.7 PUSH / POP — Single Register](#87-push--pop--single-register)
  - [8.8 TRAP — Push Return Address](#88-trap--push-return-address)
  - [8.9 String and Byte Data](#89-string-and-byte-data)
  - [8.10 Instruction ROM Encoding](#810-instruction-rom-encoding)
  - [8.11 Complete Memory Layout Reference](#811-complete-memory-layout-reference)
  - [8.12 Toolchain Summary](#812-toolchain-summary)
- [9. Page $00 Programming](#9-page-00-programming)
  - [9.1 Concept](#91-concept)
  - [9.2 Memory Map (Page $00)](#92-memory-map-page-00)
  - [9.3 Stack Layout](#93-stack-layout)
  - [9.4 Accessing Page $00 Variables](#94-accessing-page-00-variables)
  - [9.5 Y3 as the Current Task Page (k/OS Convention)](#95-y3-as-the-current-task-page-kos-convention)
  - [9.6 Reserved Allocations](#96-reserved-allocations)
  - [9.7 Application Variables ($0400-$0FFF)](#97-application-variables-0400-0fff)
  - [9.8 Example: Complete Program](#98-example-complete-program)
  - [9.9 Best Practices](#99-best-practices)
- [10. Special Features](#10-special-features)
  - [10.1 Word Suffix (w)](#101-word-suffix-w)
  - [10.2 Byte Suffix (b)](#102-byte-suffix-b)
  - [10.3 Character Literals](#103-character-literals)
  - [10.4 Derivative Operators (24-bit Address Handling)](#104-derivative-operators-24-bit-address-handling)
- [11. Expression Evaluation](#11-expression-evaluation)
  - [11.1 Operators](#111-operators)
  - [11.2 Examples](#112-examples)
- [12. Calling Convention (V2 ABI)](#12-calling-convention-v2-abi)
  - [12.1 Register Roles](#121-register-roles)
  - [12.2 Argument Passing](#122-argument-passing)
  - [12.3 Return Value](#123-return-value)
  - [12.4 Stack Frame Layout](#124-stack-frame-layout)
  - [12.5 Callee Responsibilities](#125-callee-responsibilities)
  - [12.6 TRAP Convention — Syscall ABI (Carry-on-Error Return)](#126-trap-convention--syscall-abi-carry-on-error-return)
  - [12.7 Forth Runtime](#127-forth-runtime)
- [13. Warnings and Errors](#13-warnings-and-errors)
  - [13.1 Word Alignment Warning](#131-word-alignment-warning)
  - [13.2 Common Errors](#132-common-errors)
- [14. Output](#14-output)
  - [14.1 Listing File](#141-listing-file)
  - [14.2 Symbol Table](#142-symbol-table)
  - [14.3 Region Map](#143-region-map)
- [15. Quick Reference](#15-quick-reference)
  - [15.1 Instruction Summary](#151-instruction-summary)
  - [15.2 Cycle Count Reference](#152-cycle-count-reference)
  - [15.3 Flags Affected](#153-flags-affected)
  - [15.4 Directive Summary](#154-directive-summary)
- [Appendix A: Sample Program — Hex Dump Routine](#appendix-a-sample-program--hex-dump-routine)
- [Appendix B: Common Pitfalls](#appendix-b-common-pitfalls)
  - [B.1 `[XY+D]` and `[XY+#imm5]` — Page-Local, Not 24-Bit](#b1-xyd-and-xyimm5--page-local-not-24-bit)
  - [B.2 ALU Instructions Do Not Accept `[XY+offset]` Source](#b2-alu-instructions-do-not-accept-xyoffset-source)
  - [B.3 STORE Operand Order — Register First, Address Second](#b3-store-operand-order--register-first-address-second)
  - [B.4 `STOREI` — Bare `[XYn]` Only; No Offset Form](#b4-storei--bare-xyn-only-no-offset-form)
  - [B.5 `INC XYn` / `DEC XYn` — Flag Behaviour (Updated v3.13)](#b5-inc-xyn--dec-xyn--flag-behaviour-updated-v313)
  - [B.6 Y3 — The Current Task Page Register](#b6-y3--the-current-task-page-register)
  - [B.7 `PUSH D123` / `POP D123` — Callee-Saved D Registers Only](#b7-push-d123--pop-d123--callee-saved-d-registers-only)
  - [B.8 `JMPT` — Fetches Target from Memory](#b8-jmpt--fetches-target-from-memory)
  - [B.9 `MOVE Yn, Dn` / `MOVE Dn, Yn` — 8-Bit Truncation](#b9-move-yn-dn--move-dn-yn--8-bit-truncation)
  - [B.10 SR Write Ordering in Handlers (Withdrawn)](#b10-sr-write-ordering-in-handlers-withdrawn)
  - [B.11 RETRACTED — `SHL4 / SHL4` Does Pack a Byte into the High Half](#b11-retracted--shl4--shl4-does-pack-a-byte-into-the-high-half)
  - [B.12 `LEA XYn, label` (Mode 10) is Page-Local](#b12-lea-xyn-label-mode-10-is-page-local)
- [Appendix C: Design Notes](#appendix-c-design-notes)
  - [C.1 Why ROM-Based Lookup Tables?](#c1-why-rom-based-lookup-tables)
  - [C.2 Why 6502-Style Carry?](#c2-why-6502-style-carry)
  - [C.3 Why XY2 Is the Pascal Frame Pointer](#c3-why-xy2-is-the-pascal-frame-pointer)
  - [C.4 Why TRAP Doesn't Push SR (But INT Does)](#c4-why-trap-doesnt-push-sr-but-int-does)
  - [C.5 Why Page $00 Is Special](#c5-why-page-00-is-special)
  - [C.6 Why No Byte-Wide ALU Operations](#c6-why-no-byte-wide-alu-operations)
  - [C.7 FLAGSX — Internal Flag Register for Opcodes $00–$03](#c7-flagsx--internal-flag-register-for-opcodes-0003)
- [Revision History](#revision-history)

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
| Status flags | C (Carry), Z (Zero), N (Negative), V (Overflow); held in SR for opcodes $04+, and in an internal SRX register for opcodes $00–$03 (see §3.3, Appendix C.7) |
| Interrupt levels | 8 (IRQ0-IRQ7, priority encoded) |
| Endianness | Little-endian |

### 1.2 Memory Map

| Address Range | Size | Description |
|---------------|------|-------------|
| $00_0000 - $00_FFFF | 64KB | Page $00: OS Page & Stack |
| $01_0000 - $1F_FFFF | ~2MB | RAM (currently installed) |
| $20_0000 - $AF_FFFF | 9MB | RAM (expansion space) |
| $B0_0000 - $CF_FFFF | 2MB | Video RAM (fits 1920×1080×8bpp) |
| $D0_0000 - $D7_FFFF | 512KB | Reserved |
| $D8_0000 - $DB_FFFF | 4×64KB | I/O expansion (future) |
| $DC_0000 - $DC_FFFF | 64KB | Video Page — framebuffer base selector |
| $DD_0000 - $DD_FFFF | 64KB | Video Mode Register |
| $DE_0000 - $DE_FFFF | 64KB | Keyboard Input |
| $DF_0000 - $DF_FFFF | 64KB | Terminal Output |
| $E0_0000 - $EF_FFFF | 1MB | ROM: Lookup Tables (Bank 1) |
| $F0_0000 - $FB_FFFF | 768KB | ROM: Lookup Tables (Bank 2) |
| $FC_0000 - $FE_FFFF | 192KB | ROM: Program Code |
| $FF_0000 - $FF_FFFF | 64KB | ROM: Boot Code & Reset Vector |

**Reset Vector:** CPU starts execution at $FF_0000 after reset.

**I/O Addresses:**
- $B0_0000: Video RAM base (framebuffer) — default; relocatable via Video Page
- $DC_0000: Video Page framebuffer base selector (word, write-only, default $00B0)
- $DD_0000: Video mode register (byte)
- $DE_0000: Keyboard input (word)
- $DF_0000: Terminal output (byte)

**Address Decoding:** The I/O region uses one 74LS138 sub-decoder on the
`MEM-D0-CS` line, with A19 driving the active-high `G` enable to restrict
decoding to the upper 512KB (`$D8_0000-$DF_FFFF`) in 64KB slots. Video RAM
spans two 1MB CS regions (`MEM-B0-CS` + `MEM-C0-CS`) combined through a
single OR gate.

### 1.3 Opcode Map

| Opcode | Hex | Mnemonic | Description |
|--------|-----|----------|-------------|
| 00000 | $00 | MISC | NOP (m00), HALT (m01), INC XYn (m10), DEC XYn (m11) — 24-bit XY pair |
| 00001 | $01 | LOOKUP | SHL, SHR, ASR, ROL, ROR, SWAPB, HIGH, LOW, SHL4, SHR4, ASR4, ASR8, MULB, RECIP |
| 00010 | $02 | STREAM | Post-increment load/store: LOADD/LOADB/STORED/STOREB `[XYn]+` |
| 00011 | $03 | LEA | Load Effective Address |
| 00100 | $04 | Scc | Conditional Set (SEQ, SNE, SCS/SHS, SCC/SLO, SLT, SGT, SGE, SLE) |
| 00101 | $05 | MOVE/SWAP | Register move and exchange |
| 00110 | $06 | PUSH | Push to stack (PUSHD, PUSHDG, PUSHXY, PUSH reg) |
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
| 11000 | $18 | LOADI | Load Immediate; LOADXY; LOADP/LOADPB (paged); LOADZ/LOADZB (page $00) |
| 11001 | $19 | STORED | Store D register to memory |
| 11010 | $1A | STOREB | Store byte to memory |
| 11011 | $1B | STOREX | Store X register to memory |
| 11100 | $1C | STOREY | Store Y register to memory |
| 11101 | $1D | STOREI | Store Immediate; STOREXY; STOREP/STOREPB (paged); STOREZ/STOREZB (page $00) |
| 11110 | $1E | TRAP/RET/NEG | Software trap/syscall (TRAP #n); two's complement negate (NEG, mode 01); Return from subroutine (RET, RETCC, RETCS, all with optional #nw cleanup) |
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

### 1.5 A Note on Cycle Counts

Cycle counts quoted throughout this manual are **CPU clock cycles** —
each cycle is one tick of the K16 main clock. At the target hardware
clock of 10 MHz, one cycle is 100 ns.

Each instruction consumes a fixed number of cycles per mode, driven by
the microcode ROM. There are no pipelining stalls, no cache misses, and
no branch prediction — execution time is fully deterministic. A 4-cycle
ADD at 10 MHz takes exactly 400 ns, every time.

Memory access follows the same clock: one word read or write per cycle,
assuming 70 ns ROM and RAM. The cycle counts in Section 15.2 already include
all memory accesses the instruction performs (fetch, operand read,
result write).

**Exceptions to determinism:**

- **Hardware interrupts (INT)** add 16 cycles to enter the ISR (Section 6.14).
- **Bus wait states** for slow I/O devices (if fitted) extend the
  relevant memory-access cycle until the device asserts READY.

Neither affects the published cycle counts for the instruction itself —
they are separate costs incurred at well-defined points.

On the Pascal emulator, cycle counts are simulated accurately but the
host clock is much faster; emulator "cycles" are used for cycle-budget
analysis, not wall-clock timing.

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

**Programmer-visible registers:**

| Register | Type | Description |
|----------|------|-------------|
| D0-D3 | Data | 16-bit general purpose data registers |
| X0-X3 | Index | 16-bit index registers (low word of XY pair) |
| Y0-Y3 | Index | 8-bit index registers (high byte of XY pair, zero-extended to 16) |
| XY0-XY3 | Address | Combined 24-bit address registers (XY3 = stack pointer) |
| PC | Program Counter | 24-bit program counter |
| PCL | PC Low | Low 16 bits of program counter |
| PCH | PC High | High 8 bits (bank) of program counter |
| SR | Status | Status register (flags: C, Z, N, V) — visible to opcodes $04+ |

**Internal architectural state (not programmer-addressable):**

| Register | Width | Description |
|----------|-------|-------------|
| T8 | 8 bits | Loaded from IR[7:0] at instruction fetch (step 0); reaches ALU-B via the T8 → AB-Hi → data bus path |
| T8-5 | 5 bits | IR[4:0] zero-extended to 16; the IMM5 fast-path immediate; available on both ALU-A and ALU-B (via the data bus) |
| T16 | 16 bits | Holds the immediate word for IMM16 instructions (2-word forms); available on ALU-A bus only |
| ORDB | 16 bits | Output Register Data Bus — captures ALU results for routing to registers or memory |
| ORAB | 16 bits | Output Register Address Bus — captures ALU results destined for the address bus; used as a temporary stack pointer in JSR microcode (avoids intermediate X3 updates) |
| SRX | 4 bits | Internal flag register used only by opcodes $00–$03 (LOOKUP, INC/DEC XY, LEA); preserves user-visible SR across these instructions (see §3.3, Appendix C.7) |

These registers cannot be named in assembler source — no mnemonic reads or
writes them. They exist as internal microcode state and appear in the manual
only where their behaviour is observable (e.g. §6.3 NEG encoding fields,
§8 endianness step-by-step walk-throughs, Appendix C design notes).

### 3.2 Typical Register Conventions

| Register | Common Usage |
|----------|--------------|
| D0 | Return value, primary accumulator |
| D1-D3 | Temporary values, loop counters |
| XY0-XY2 | General purpose pointers |
| XY3 | Stack pointer (hardcoded for CALL/RET/PUSH/POP) |

### 3.3 Status Register (SR)

The status register contains flags and interrupt status information.

| Bit | Name | R/W | Description |
|-----|------|-----|-------------|
| 7 | IE | R | Interrupt Enable (1=enabled, 0=disabled) |
| 6:4 | LVL | R | Current interrupt priority level (0-7) |
| 3 | V | R/W | Overflow - set on signed overflow |
| 2 | N | R/W | Negative - set when result bit 15 is set |
| 1 | Z | R/W | Zero - set when result is zero |
| 0 | C | R/W | Carry — see Section 6.3 Carry Convention; set on ADD overflow, *cleared* on SUB/CMP borrow |

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

**Internal flag register SRX (v3.13+).** Opcodes $00–$03 (IR[15:13] = 000
— LOOKUP, STREAM ($02), LEA, and NOP/HALT/INC XY/DEC XY at $00) do not write
the user-visible SR. Their flag side effects go to an internal 4-bit
register **SRX**, used solely for carry propagation between microcode
steps of the same instruction. SRX is not programmer-addressable: no
mnemonic reads or writes it, it does not appear in any instruction
encoding, and no software construct can observe it. From the
programmer's point of view, opcodes $00–$03 are simply **flag-transparent**
— SR is preserved across them. See Appendix C.7 for the design rationale
and CR-2026-001 v1.2 for the hardware specification.

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

> **The alignment pad is a `$00`, and a `$00` terminates a string.** An
> odd-length `.TEXT` followed by another data directive therefore gains a
> nul between them. That is harmless when each directive is a separate
> string with its own terminator, but it **silently truncates one logical
> string split across several `.TEXT` directives** — `sys_puts` stops at
> the pad and everything after it is unreachable, with no error anywhere.
>
> ```asm
> ; BROKEN — first chunk is 11 bytes, so a $00 pad lands before the second
>         .TEXT   10, "expected:", 10
>         .TEXT   "  1  both readings agree", 10, 0
>
> ; CORRECT — one directive, no seam for a pad to land in
>         .TEXT   10, "expected:", 10, "  1  both readings agree", 10, 0
>
> ; ALSO CORRECT — .BYTE advances by exact byte count and never pads (4.6)
>         .BYTE   "expected:\n"
>         .BYTE   "  1  both readings agree\n", 0
> ```
>
> Use `.BYTE` for multi-line text built from several directives; that is
> why `kosh_help.asm` is written that way.

```asm
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

Emits one or more bytes. Values can be numeric literals, string literals, escape sequences, or any mix. Unlike `.TEXT`, the program counter advances by the **exact byte count** — it is not rounded to a word boundary. Use `.ALIGN` (see Section 4.7) after `.BYTE` if subsequent code or data must be word-aligned.

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


### 4.11 .INCBIN — Include Binary File

Inserts the contents of a binary file at the point of the directive, emitted verbatim as data words. Useful for embedding pre-assembled `.COM` images, lookup tables, font data, or any pre-built binary blob into the assembled output.

```asm
.INCBIN     "kosh.com"              ; relative to current file's directory
.INCBIN     "fonts/8x8.bin"         ; subdirectory
.INCBIN     "/path/to/blob.dat"     ; absolute path
```

**Path resolution:** identical to `.INCLUDE` (§4.9). Relative paths are resolved from the directory of the **file containing the `.INCBIN`**, not the working directory. Absolute paths (Windows drive letter, leading `/` or `\`) pass through unchanged.

**Byte order:** bytes are emitted in file order, packed little-endian into K16 words. The first byte of the file becomes the low byte of the first emitted word, the second byte becomes the high byte. This matches the K16's little-endian memory model and the byte ordering of `.TEXT` data.

**Even-length requirement:** the file must be an even number of bytes. Odd-length files produce a clean assembler error pointing at the source line:

```
.INCBIN file has odd length (N bytes): /path/to/file.bin — pad source to even length
```

For a binary built by the K16 assembler itself, ending the source with `.ALIGN` guarantees even length.

**Alignment:** `.INCBIN` itself must be word-aligned at the time it's emitted, same as `.WORD`. Place an explicit `.ALIGN 2` before `.INCBIN` if any preceding `.BYTE` data may have left an odd byte count.

**Typical use — embedding a `.COM` image:**

```asm
                ; In the kernel: embed kosh.com verbatim so the boot
                ; path can copy it into a fresh user page.
kosh_image_start:
                .INCBIN  "kosh.com"
kosh_image_end:
KOSH_IMAGE_SIZE .EQU     kosh_image_end - kosh_image_start
```

The kernel can then copy `KOSH_IMAGE_SIZE` bytes from `kosh_image_start` to the destination page using normal `LOADB` / `STOREB` loops.

### 4.12 .REGION / .RS / .ENDREGION — Region Reservation

Reserves and names page-`$00` (or any RAM) storage by letting the **assembler**
assign the addresses. You give a region its start once; each `.RS` binds the next
symbol and advances the region cursor. No field address is ever typed, so an
intra-region overlap is structurally impossible, and strict collision detection
turns any accidental redefinition — region-vs-region or region-vs-`.EQU` — into a
build error rather than a silent stomp.

**Reservation is not emission.** `.REGION` and `.RS` produce **no bytes** and never
advance the emit PC — they map names onto storage that already exists (RAM). `.COM`
or kernel code following a region block begins exactly where it would have without
it. For in-image reserved space that *does* advance the PC, use `.DS` (§4.8).

| Directive | Form | Role |
|-----------|------|------|
| `.REGION` | `NAME .REGION [start] [, cap]` | Open region `NAME`. Explicit `start`, or omit to auto-chain off the previous region's `_END`. Optional exclusive `cap`. |
| `.RS` | `SYMBOL .RS count[w]` | Bind `SYMBOL` to the region cursor; advance `count` bytes (`w` = words ×2). Emits nothing. |
| `.ENDREGION` | `.ENDREGION` | Close the open region. |

Openers are **symbol-first** (`NAME` in the label column), matching `SYMBOL .EQU`.
`.ENDREGION` is bare — the opener already named the region.

**Auto-defined symbols.** On `.ENDREGION` the assembler defines:

| Symbol | Value |
|--------|-------|
| `NAME_START` | the start address |
| `NAME_END` | first free address after the last `.RS` (exclusive, one-past) |
| `NAME_SIZE` | `NAME_END − NAME_START` |
| `NAME_CAP` | the `cap`, only if the capped form was used |

**Placement.** The **first** region must state an explicit start — there is no
auto-zero, because a region silently based at `$0000` would stomp the fixed page-`$00`
ABI zones (vector table, `FD_TABLE`). Any later region may **auto-chain** by omitting
its start, in which case it begins at the previous region's `_END`. Adding or removing
a `.RS` re-flows every downstream auto-chained base and field automatically — no hand
arithmetic.

**`@` scoping.** Each `.RS` field is reachable two ways: unqualified (`SV_TICKS`, global
visibility) and qualified (`SYSV@SV_TICKS`, same address, self-documenting). `@` is used
because it is unused elsewhere in K16/k/OS syntax — unlike `.` (clashes with
`GLOBAL.LOCAL` local labels) and `:` (clashes with named-drive and `page:offset` syntax).
It reads as "at": `SYSV@SV_TICKS` = "SV_TICKS at SYSV". A qualified `NAME@FIELD` is always
defined; the plain `FIELD` alias is defined only when it does not collide (see below).
Auto symbols (`_START`/`_END`/`_SIZE`/`_CAP`) stay plain — no `@` alias.

**Checks (all hard errors):**

- **Collision.** Any symbol redefinition — a field name already in the symbol table, a
  region name clashing with an existing symbol, or two regions declaring the same
  unqualified field. On a field-name clash the plain alias is withheld (both regions keep
  their `@` forms); resolve at the use site with `NAME@FIELD`.
- **Overlap.** A region whose **explicit** start lands inside an already-placed span.
  Auto-chained regions cannot overlap by construction, so the check runs on explicit
  starts only, and works across `.INCLUDE`d files (every closed span is tracked, per address
  space — see §4.13).
- **Emit inside a region.** `.DS` / `.WORD` / `.BYTE` / `.TEXT` / `.INCBIN` inside an open
  region are rejected — they would emit into an image the region does not own. `.RS` is the
  region-context equivalent of `.DS`.
- **Code grown into a region (clobber guard).** After assembly, every emitted code/data
  word is checked against every placed region span **in the code's own address space (§4.13)**.
  If code has grown upward into a
  reserved high-memory block, it is reported as a build error naming the region — the
  historical growth-clobber becomes an assemble-time error instead of silent runtime
  corruption. Works in either declaration order (spans are closed in the first pass,
  before any code is emitted).

**Region map.** All placed regions are written to a region map artifact (§14.3) — a
region table plus a fields-by-address listing.

**Example** — two chained page-`$00` scratch regions:

```asm
COM_TLS_BASE  .EQU  $006C               ; first byte past FD_TABLE

SYSV    .REGION COM_TLS_BASE, $00A0     ; explicit start (first region), capped
  SV_TICKS  .RS 1w                      ; $006C   SYSV@SV_TICKS
  SV_HEAD   .RS 1w                      ; $006E
  SV_TAIL   .RS 1w                      ; $0070
        .ENDREGION                      ; SYSV_END=$0072  SYSV_SIZE=6

WORK    .REGION                         ; auto-chain — starts at SYSV_END = $0072
  W_FLAGS   .RS 1w                      ; $0072
  W_COUNT   .RS 1w                      ; $0074
        .ENDREGION                      ; WORK_END=$0076

Start:
        LOADI   D0, #1
        STOREZ  D0, [#SYSV@SV_TICKS]     ; write page $00:$006C
```

Adding `SV_STATE .RS 1w` to `SYSV` re-flows `SYSV_END`, `WORK`'s auto-chained base, and
every `W_*` address automatically; the `STOREZ` still resolves with no edit.

---

### 4.13 .SPACE — Address Space Tagging

`.SPACE` tags the `.REGION` declarations that follow it — and the current binary's
emitted code — with a named **address space**. A K16 build produces one binary image
that occupies one physical page; `.SPACE` names that page. The region overlap check and
the code-in-region clobber guard (§4.12) then compare only things that share a space.
This lets one source file `.INCLUDE` another purely for its `.EQU` **constants** without
the included file's `.REGION`s — which live in a *different* page — colliding against the
includer's emitted code.

**Syntax.**

```asm
.SPACE name
```

Directive-first, exactly one operand, mirroring `.ORG`. `name` is a bare identifier
(surrounding whitespace trimmed) and is compared **case-insensitively** — `kosh` and
`KOSH` are the same space. There is no label form (`SYMBOL .SPACE …` is not used).

**Semantics.**

- **Sticky.** `.SPACE` sets the current declaration space and stays in effect until the
  next `.SPACE`. Every `.REGION` opened afterwards is stamped with the current space, so
  one `.SPACE` at the top of a defs file tags every region in it.
- **Default sentinel.** Before any `.SPACE`, the current space is `default`. A build that
  never uses `.SPACE` places everything in `default` and behaves exactly as it did before
  the directive existed — fully backward compatible. Untagged is still checked; there is
  no "untagged = skip".
- **Code space pinned at `.ORG`.** When `.ORG` is processed, the current space is captured
  as the binary's **code space**. The clobber guard tests emitted code only against
  regions of that space.
- **Travels across `.INCLUDE`.** Space stamps ride with their regions, so a kernel defs
  file tagged `.SPACE kernel` keeps its regions in `kernel` space even when pulled into a
  `kosh`-space build.
- **Non-emitting.** Like the other region directives, `.SPACE` emits no bytes and never
  advances the emit PC.

**Guard scoping.** Both region guards from §4.12 are **same-space only** once spaces are
in use:

- **Overlap** compares a new region's explicit start against existing regions of the
  **same** space. Two binaries legitimately reusing the same numeric address in their own
  pages do not false-collide.
- **Code-in-region** tests each emitted word against regions of the **code's** space
  (pinned at `.ORG`); regions in other spaces are ignored.

**Fail-loud.** If a binary that reuses low addresses for code (e.g. a `.COM` at
`.ORG $0200`) omits its `.SPACE` tag, its code stays in the ambient space and the guard
hard-errors against the regions it overlaps — the omission surfaces at assemble time, not
as silent runtime corruption.

**Errors (hard errors):**

| Condition | Message |
|-----------|---------|
| Wrong operand count | `.SPACE directive requires exactly 1 operand: .SPACE name` |
| Used inside an open region | `.SPACE cannot appear inside region '<name>' - close it with .ENDREGION first.` |

**Example** — `kosh.asm` includes the kernel defs for their constants, then declares its
own task-page regions:

```asm
.SPACE   kernel
.INCLUDE "kos_defs.inc"        ; SYSVARS $0200, TCBPOOL $0800, … (kernel space)
.INCLUDE "kos_fs_defs.inc"     ; VOLTABLE $0260, …              (kernel space)
.INCLUDE "kos_klib.inc"        ; KLIBTABLE $A000                (kernel space)

.SPACE   kosh
.INCLUDE "kosh_defs.inc"       ; LINEBUF/TASKBUF/…              (kosh space)

.ORG     $0200                 ; code space pinned = kosh
         ; … kosh.com emits $0200.. in its own task page …
```

The kernel regions at `$0200`/`$0800`/… are `kernel` space; kosh's code and its `$5FB0+`
buffers are `kosh` space. kosh code at `$0800` does **not** trip `TCBPOOL` (different
space). If kosh code ever grows into its own `LINEBUF`/`TASKBUF` (same space), the guard
fires. Delete the `.SPACE kosh` line and the code drops to `kernel` space — it then
hard-errors on `SYSVARS $0200`.

**Reserved.** One space per region — a region belongs to exactly one page; there is no
multi-space tag. A genuine shared-memory region visible to two binaries would be modelled
as a third named space (e.g. `shared`) checked against all code spaces. No such region
exists today, so this is reserved in the model, not implemented.

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

K16 has 32 opcodes ($00-$1F), each encoding 1-4 instructions via a
2-bit mode field. The table below is a one-screen index of the entire
ISA; detailed descriptions follow in Sections 6.1-6.14.

### 6.0 Instruction Set at a Glance

| Opcode | Instructions | Category | Section |
|--------|--------------|----------|---------|
| $00 | NOP, HALT, INC XYn, DEC XYn | Control / Increment / Decrement | 6.13, 6.3 |
| $01 | SHL, SHR, ASR, ROL, ROR, SWAPB, HIGH, LOW, SHL4, SHR4, ASR4, ASR8, MULB, RECIP, LOOKUP | Shift / Rotate / Table | 6.5 |
| $02 | LOADD, LOADB, STORED, STOREB (`[XYn]+` post-increment) | Data Movement (STREAM) | 6.1 |
| $03 | LEA | Load Effective Address | 6.2 |
| $04 | SEQ, SNE, SCS/SHS, SCC/SLO, SLT, SGT, SGE, SLE, SAL | Conditional Set | 6.7 |
| $05 | MOVE, SWAP | Register Transfer | 6.1 |
| $06 | PUSH (D, X, Y, XY, D123 group, SR) | Stack Push | 6.12 |
| $07 | POP (D, X, Y, XY, D123 group, SR); PUSH #imm (PUSHI, mode 11) | Stack Pop | 6.12 |
| $08 | ADD | Arithmetic | 6.3 |
| $09 | ADC | Arithmetic (with carry) | 6.3 |
| $0A | SUB | Arithmetic | 6.3 |
| $0B | SBC | Arithmetic (with borrow) | 6.3 |
| $0C | AND | Logical | 6.4 |
| $0D | OR | Logical | 6.4 |
| $0E | XOR | Logical | 6.4 |
| $0F | NOT | Logical | 6.4 |
| $10 | CMP | Compare | 6.6 |
| $11 | BEQ, BNE, BCS/BHS, BCC/BLO, BLT, BGT, BGE, BLE, BRA | Branch | 6.8 |
| $12 | JMP, JMP24, JMP16, JMPT, JMPXY | Jump | 6.9 |
| $13 | CALL, CALL24, CALL16, CALLR, CALLXY | Subroutine Call | 6.10 |
| $14 | LOADD | Load word (D register) | 6.1 |
| $15 | LOADB | Load byte (D register) | 6.1 |
| $16 | LOADX | Load word (X register) | 6.1 |
| $17 | LOADY | Load word (Y register) | 6.1 |
| $18 | LOADI, LOADXY, LOADP/LOADPB, LOADZ/LOADZB | Load Immediate / XY pair / Paged / Page $00 | 6.1 |
| $19 | STORED | Store word (D register) | 6.1 |
| $1A | STOREB | Store byte (D register) | 6.1 |
| $1B | STOREX | Store word (X register) | 6.1 |
| $1C | STOREY | Store word (Y register) | 6.1 |
| $1D | STOREI, STOREXY, STOREP/STOREPB, STOREZ/STOREZB | Store Immediate / XY pair / Paged / Page $00 | 6.1 |
| $1E | TRAP, NEG, RET, RETCC, RETCS | Syscall / Subroutine return / Negate | 6.11, 6.3 |
| $1F | DINT, EINT, RTI, INT | Interrupt control | 6.14 |

**Assembler-level aliases and pseudo-instructions** (Level-2 syntactic sugar, no new opcodes):

| Alias | Expands to | Purpose | Section |
|-------|------------|---------|---------|
| `JMP` | `JMP24` | 24-bit absolute jump (default form) | 6.9 |
| `CALL` | `CALL24` | 24-bit absolute call (default form) | 6.10 |
| `SEC` | `LOADI SR, #$01` | Set carry | 6.14 |
| `CLC` | `LOADI SR, #$00` | Clear carry | 6.14 |
| `BHS` | `BCS` | Branch if higher-or-same (unsigned) | 6.8 |
| `BLO` | `BCC` | Branch if lower (unsigned) | 6.8 |
| `SHS` | `SCS` | Set if higher-or-same (unsigned) | 6.7 |
| `SLO` | `SCC` | Set if lower (unsigned) | 6.7 |
| `INC Dn` | `ADD Dn, #1` | Increment D register | 6.3 |
| `DEC Dn` | `SUB Dn, #1` | Decrement D register | 6.3 |
| `BHI` | `BEQ.S .skip / BHS target / .skip:` | Branch if higher (unsigned strict) — pseudo-instruction | 6.15 |
| `BLS` | `BEQ target / BLO target` | Branch if lower-or-same (unsigned) — pseudo-instruction | 6.15 |
| `SHL Dn, #n` | (see §6.15) | Multi-bit logical shift left by constant | 6.15 |
| `SHR Dn, #n` | (see §6.15) | Multi-bit logical shift right by constant | 6.15 |
| `ASR Dn, #n` | (see §6.15) | Multi-bit arithmetic shift right by constant | 6.15 |

The quick-reference tables in Section 15 give cycle counts (Section 15.2), flags
affected (Section 15.3), and a compact instruction summary (Section 15.1).

### 6.1 Data Movement

Data movement instructions transfer values between registers and memory.

#### LOADI — Load Immediate

Loads a constant value directly into a register.

**Opcode:** $18

| Mode | Syntax | Operation | Cycles | Words |
|------|--------|-----------|--------|-------|
| 00 | `LOADI reg, #imm5` | reg ← imm5 (0-31) | 2 | 1 |
| 01 | `LOADI reg, #imm16` | reg ← imm16 | 2 | 2 |

The assembler automatically selects IMM5 mode for values 0-31, or IMM16
mode for larger values.

**Destination registers:**

| Field | Register | Width | Notes |
|-------|----------|-------|-------|
| 0-3 | D0-D3 | 16-bit | |
| 4-7 | X0-X3 | 16-bit | |
| 8-11 | Y0-Y3 | 8-bit | IMM16 value truncated to low byte |
| 13 | SR | 4 bits writable | Writes C/Z/N/V only — see below |

```asm
LOADI D0, #$1F          ; Mode 00: D0 ← $1F (IMM5)
LOADI D0, #$1234        ; Mode 01: D0 ← $1234 (IMM16)
LOADI X0, #$1234        ; X0 ← $1234
LOADI Y0, #$56          ; Y0 ← $56
LOADI SR, #$01          ; SR flags: C=1, Z=N=V=0 (see below)
```

#### LOADI SR — Direct Flag Write

The SR flags (C/Z/N/V) occupy bits 3:0 of SR. `LOADI SR, #imm5` writes
those four bits (C/Z/N/V); bits 7:4 (IE and
LVL) are **software-read-only** — they change only through `EINT`/`DINT`
and hardware INT/RTI. IMM5 values above $0F are effectively masked to
the low nibble at the hardware level, but the assembler only emits IMM5
mode for 0-31 values.

```asm
LOADI SR, #$01          ; C=1, Z=N=V=0   (see also SEC alias)
LOADI SR, #$00          ; all flags clear (see also CLC alias)
LOADI SR, #$0F          ; set all four flag bits
LOADI SR, #$04          ; N=1, others clear
```

**Flag transparency:** `LOADI Dn, #imm` (and all other LOADI destinations
that are not SR) do **not** touch flags. This enables the handler pattern:

```asm
    ; handler success exit
    LOADI   D0, #result
    LOADI   SR, #$00        ; C=0, Z=N=V=0
    RET

    ; handler error exit
    LOADI   D0, #ERR_CODE
    LOADI   SR, #$01        ; C=1 (error)
    RET
```

See Section 6.11 (TRAP/RET) for the carry-on-error syscall ABI.

**SR is 4-bit writable, 16-bit readable (8-bit value zero-extended to 16).**
`MOVE Dn, SR`, `PUSH SR`, and
`PUSH SR.IE / PUSH SR.LVL` paths return the full 8-bit SR value (bit 7 =
IE, bits 6:4 = LVL, bits 3:0 = flags). Software writes to SR affect only
the low nibble.

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
LOADB D1, [XY1+D0]      ; D1 ← byte at XY1+D0
```

**Table index masking:** D registers are 16-bit. Arithmetic on 8-bit values can leave the high byte non-zero, causing out-of-range table reads with no error or diagnostic. Always mask before using a D register as a byte table index:

```asm
ADD     D0, D1          ; result may be > $FF
AND     D0, #$FF        ; mask to 8-bit BEFORE using as index
LOADB   D0, [XY1+D0]   ; safe: index is 0..255
```

**Register aliasing:** when destination and index register are the same (`LOADB D0, [XY1+D0]`), the hardware uses the *old* D0 value to compute the address before writing the result. This is intentional and correct — commonly used for in-place table lookups. Use a different destination register if you need the old value for further work after the load.

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

#### LOADZ/LOADZB — Load from Page $00 (Y-Independent)

Loads from page `$00` regardless of any Y register. Used for kernel data,
the vector table, and fixed low-memory I/O — anywhere the access must
survive a context switch where Y3 (the per-task page) may be anything.

**Opcode:** $18 (Mode 11), with IR bit 4 (ZOA flag) = 1

| Mode | Syntax | Operation | Cycles | Words |
|------|--------|-----------|--------|-------|
| 11 | `LOADZ  reg, [#imm16]` | reg ← mem[$00:imm16] (word) | 3 | 2 |
| 11 | `LOADZB reg, [#imm16]` | reg ← mem[$00:imm16] (byte) | 3 | 2 |

No Y register field — the address-bus high byte is hardwired to `$00`
by the ZOA (Zero-on-Address-Hi) AB sub-write.

```asm
SYS_TICKS   .EQU    $011A
LOADZ   D0, [#SYS_TICKS]      ; D0 ← word from $00:011A, any Y3
LOADZB  D1, [#$0123]          ; D1 ← byte from $00:0123, zero-extended
```

See Section 9.5 for the kernel zero-page use case.

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

**Operand order:** the source register comes **first**, the destination address **second** — `STORED D0, [XY0]`, not `STORED [XY0], D0`. This is the opposite of natural English ("store D0 to XY0") and is the most common STORE operand error. The assembler will reject the reversed form.

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

**Restriction:** `STOREI` supports only bare `[XYn]` addressing. There is no offset form — `STOREI #val, [XYn+D]` and `STOREI #val, [XYn+#imm5]` are not valid and will be rejected by the assembler. Use `LOADI Dn + STORED` for immediate stores to an offset address:

```asm
STOREI  #42, [XY2+#4]   ; ASSEMBLER ERROR — offset form not available
LOADI   D0, #42         ; correct workaround
STORED  D0, [XY2+#4]    ;   works for any address form
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

#### STOREZ/STOREZB — Store to Page $00 (Y-Independent)

Stores to page `$00` regardless of any Y register. Companion to LOADZ
for kernel data and ISR-safe access where Y3 may be any task page.

**Opcode:** $1D (Mode 11), with IR bit 4 (ZOA flag) = 1

| Mode | Syntax | Operation | Cycles | Words |
|------|--------|-----------|--------|-------|
| 11 | `STOREZ  reg, [#imm16]` | mem[$00:imm16] ← reg (word) | 5 | 2 |
| 11 | `STOREZB reg, [#imm16]` | mem[$00:imm16] ← reg (byte) | 5 | 2 |

No Y register field — the address-bus high byte is hardwired to `$00`
by ZOA. Useful inside ISRs that may preempt an arbitrary task without
needing to save/restore Y3.

```asm
SYS_TICKS   .EQU    $011A
LOADZ   D0, [#SYS_TICKS]
ADD     D0, D0, #1
STOREZ  D0, [#SYS_TICKS]      ; Increments correctly under any Y3
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

#### STREAM — Post-Increment Load/Store (`$02`)

Fuses "access then advance the pointer" into a single instruction, replacing
the `LOAD/STORE [XYn]` + `INC XYn, #n` pair. The pointer advance uses the
24-bit carry-skip mechanism, so it crosses 64 KB page boundaries correctly.

**Opcode:** $02

| Mode | Syntax | Operation | Cycles | Words |
|------|--------|-----------|--------|-------|
| 00 | `LOADD Dn, [XYn]+ [, #stride]`  | Dn ← mem[XYn] (word); XYn += stride | 4 / 6¹ | 1 |
| 01 | `LOADB Dn, [XYn]+ [, #stride]`  | Dn ← mem[XYn] (byte, zero-ext); XYn += stride | 4 / 6¹ | 1 |
| 10 | `STORED Dn, [XYn]+ [, #stride]` | mem[XYn] ← Dn (word); XYn += stride | 5 / 7¹ | 1 |
| 11 | `STOREB Dn, [XYn]+ [, #stride]` | mem[XYn] ← Dn (byte); XYn += stride | 5 / 7¹ | 1 |

¹ Higher figure applies on a runtime page-cross. The K16EmuIDE cycle model
uses the common (no-cross) figures only.

**Stride:**
- Default **2** for word ops (`LOADD`/`STORED`), **1** for byte ops (`LOADB`/`STOREB`).
- Explicit `#stride` is a raw byte delta, range **0–31** (IMM5). `#Nw` is scaled ×2 by the assembler (word count).
- Word ops require an **even** stride; the assembler errors on odd.

**Encoding:**

```
IR:  15 .. 11 | 10  9 | 8  7 | 6  5 | 4 3 2 1 0
     00010      mode    Dn     XYn    stride (IMM5)

mode: 00 LOADD   01 LOADB   10 STORED   11 STOREB
```

Examples: `LOADD D0,[XY0]+` = `$1002`, `LOADB D0,[XY1]+` = `$1201`,
`STORED D0,[XY1]+` = `$1422`, `STOREB D0,[XY1]+` = `$1621`.

**Flags:** flag-transparent. Neither the data access nor the pointer advance
disturbs the user `SR` — the advance carry is routed to the internal `SRX`
(FLAGSX; see §3.3, Appendix C.7). Always `CMP Dn, #0` before a conditional
branch on a freshly-loaded value; never `LOADB / BEQ`.

The bare `[XYn]` form (no `+`) still selects the non-advancing `$14`/`$19`
encodings. Post-increment takes no offset — it cannot be combined with
`[XYn+Dm]` or `[XYn+#imm5]`.

```asm
; copy a null-terminated string MSG -> BUF
copy:   LOADB  D0, [XY0]+    ; read + advance src
        STOREB D0, [XY1]+    ; write + advance dst
        CMP    D0, #0        ; flag-transparent: must CMP
        BNE    copy
```

### 6.2 Load Effective Address (LEA)

LEA calculates a 24-bit effective address and stores the result in an XY register pair without performing a memory access. This enables efficient pointer arithmetic, array indexing, and address calculations.

**Opcode:** $03

| Mode | Syntax | Operation | Cycles | Words |
|------|--------|-----------|--------|-------|
| 00 | `LEA XYn, XYm` | XYn = XYm (copy) | 3 | 1 |
| 01 | `LEA XYn, XYm+Do` | XYn = XYm + Do | 4 / 6 | 1 |
| 10 | `LEA XYn, label` | XYn = PC + offset (page-local) | 5 | 2 |
| 11 | `LEA XYn, XYm+#imm5` | XYn = XYm + imm5 | 4 / 6 | 1 |

Cycle counts include the instruction fetch (step 0). For Modes 01 and 11 the two figures are **no-page-cross / page-cross**: the operation terminates early via the carry-skip gate when the low-word add produces no carry into the page byte (the common case), and runs the extra Y-fixup steps only when a carry must propagate. See "Timing and carry-skip" below.

#### Direction and Page Safety (all modes)

LEA is **forward-only and page-safe** in every mode. "Page-safe" means a carry out of the low 16-bit (X) add propagates correctly into the 8-bit page byte (Y) — except Mode 10, which is deliberately page-*local* (see below). "Forward-only" means no mode can decrement the page byte:

- **Mode 11** — `imm5` is unsigned 0–31 (T8-5, zero-extended). It cannot represent a negative offset; the Y-fixup adds `$0000 + Ym + carry`, so Y can only ever be incremented by the carry, never decremented.
- **Mode 01** — `Do` is added as an unsigned 16-bit value, zero-extended into the 24-bit space. `Do = $FFFF` yields a 24-bit result of `+$FFFF` (i.e. low word −1 with +1 into the page byte), **not** a 24-bit −1. Do not use Mode 01 expecting a signed/backward index.
- **Mode 00** — a pure copy; no offset, nothing to propagate.
- **Mode 10** — page-local; carry is discarded (see Mode 10 below).

To move an address *backward* across a page boundary, note that no LEA form subtracts from the page byte. Use explicit `DEC XY` (which borrows into Y) or `LOADI`/`MOVE` for arbitrary 24-bit pointer construction.

**Bracket-free syntax:** LEA uses no brackets, to distinguish it from LOAD/STORE memory operations:

```asm
LEA  XY0, XY1+D2      ; Calculate address (no memory access)
LOAD D0, [XY1+D2]     ; Access memory at address
```

#### Mode 00: Copy XY Pair — 3 cycles

```asm
LEA XY0, XY1          ; XY0 ← XY1 (copy 24-bit pointer)
LEA XY2, XY3          ; XY2 ← XY3 (copy stack pointer)
```

A straight 24-bit dual copy: `Xm → Xn`, then `Ym → Yn`. No ALU operation, no carry, no flag write — strictly flag-transparent. Destination and source may be the same pair (`LEA XY2, XY2` is a harmless no-op). This is the cheapest pointer copy available: a single instruction (1 word) versus the two-instruction `MOVE Xn,Xm / MOVE Yn,Ym` alternative.

#### Mode 01: Dynamic Index (XY + D Register) — 4 / 6 cycles

```asm
LEA XY0, XY1+D0       ; XY0 ← XY1 + D0 (array indexing)
LEA XY2, XY2+D3       ; XY2 ← XY2 + D3 (advance by variable)
```

24-bit arithmetic with carry from X to Y enables correct bank crossing:

```asm
; XY1 = $05:FF00, D2 = $0200
LEA XY0, XY1+D2       ; XY0 = $06:0100 (crossed into bank 6)
```

`Do` is unsigned; see "Direction and Page Safety" above. Because the page-cross frequency depends on the runtime value of `Do` (unlike Mode 11's bounded imm5), the 6-cycle path is taken whenever `Xm + Do` overflows 16 bits. For small indices into in-page structures the 4-cycle path dominates.

#### Mode 10: PC-Relative (Label) — Page-Local — 5 cycles

```asm
LEA XY0, DataTable    ; XY0 ← address of DataTable (same page as LEA)
LEA XY1, MyString     ; XY1 ← address of MyString (same page as LEA)
```

**Page-local:** Mode 10 computes the low word as `PC + offset` (16-bit add, carry discarded) and sets `Yn` directly from the LEA's own `PCH`. The label must therefore live in the same 64KB page as the LEA instruction itself. The displacement is a signed 16-bit value, so Mode 10 reaches both forward and backward labels within the page (backward references — strings placed before MAIN — are the common case). The assembler emits a warning if the LEA and its target label are in different assembly-time pages.

For cross-page address loading, use explicit LOADI:

```asm
; Within current task page (under k/OS):
LOADI X0, #<DataTable
MOVE  Y0, Y3                ; Y3 holds the running task's page byte

; Bare-metal, page known at assembly time:
LOADI X0, #<DataTable
LOADI Y0, #>DataTable
```

More efficient than the LOADI form when the data is in the same page (common case — string tables, jump tables, scratch data):

```asm
; LEA version (same-page): 2 words, 5 cycles
LEA XY0, SineTable

; LOADI version (any page): 4 words, 4 cycles
LOADI X0, #<SineTable
LOADI Y0, #>SineTable
```

> **History:** Mode 10 was documented as full 24-bit PC-relative through v3.14, but the original microcode only handled forward overflow into `PCH` (the `+1` case), never backward underflow (the `−1` case). Every backward LEA silently produced `PCH + 1` instead of `PCH`, putting the address in the next page. The 24-bit form's carry/borrow bookkeeping needs sign-extension of the 16-bit displacement, which the current ALU bus constants can't drive cheaply. The v3.15 microcode is page-local: `Yn ← PCH` directly, no carry math. Mode 10 is 4 microcode steps (5 cycles), matches how BRANCH already works (also page-local), and is correct for every existing Mode 10 LEA in the codebase. See Appendix B.12 and Gotchas #34.

#### Mode 11: Immediate Offset (XY + IMM5) — 4 / 6 cycles

```asm
LEA XY0, XY3+#2       ; XY0 ← stack pointer + 2
LEA XY1, XY0+#8       ; XY1 ← XY0 + 8 (structure field)
LEA XY2, XY3+#20      ; XY2 ← XY3 + 20 (local variable)
```

IMM5 range: 0–31, unsigned. Because the offset is at most 31, a page cross occurs only when `Xm` is within 31 of a 64KB boundary (`$xx:FFE1`–`$xx:FFFF`); the 4-cycle no-cross path dominates in practice.

#### Timing and Carry-Skip (Modes 01 and 11)

Modes 01 and 11 use the **copy-Y-first carry-skip** sequence (cycle counts include fetch):

1. `Ym → Yn` — copy the source page byte into the destination first.
2. `Xm + offset → Xn`, saving carry.
3. Write `Xn`; **arm the carry-skip gate**. If the low-word add produced **no carry**, the operation terminates here — `Yn` already holds the correct page byte from step 1 (**4 cycles**, no-cross path).
4. (carry only) `$0000 + Ym + carry → Yn` — propagate the carry into the page byte (**6 cycles**, page-cross path).

Copying `Ym → Yn` *before* the add is essential: because LEA's destination (`XYn`) differs from its source (`XYm`), the carry-skip cannot simply "leave Yn untouched" the way `INC`/`DEC` do (which are in-place, src = dst). The no-carry path must still deliver `Yn = Ym`, so the copy happens up front and the early termination is then safe.

> The carry-skip gate is mode-agnostic and shared with `INC`/`DEC` (see Appendix C.8). The Y-propagation path on a carry/borrow is exercised by Mode 11/01 page-cross, `INC XY` wrap, and `DEC XY` borrow alike.

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
| Constant offset 1–31 | ✓ INC 3 / DEC 4 cyc in-place (5 / 6 on page cross) | ✓ Mode 11, 4 cyc (6 on page cross) |
| Variable offset | ✗ | ✓ Mode 01, 4 / 6 cyc |
| Copy XY pair | ✗ | ✓ Mode 00, 3 cyc |
| PC-relative label | ✗ | ✓ Mode 10, 5 cyc |
| Different src/dst | ✗ (in-place only) | ✓ All modes |

`INC` is the cheapest constant adjust (3 cycles) because it adds in place with no leading step. `DEC` and `LEA` Mode 11 both cost 4 cycles on the no-cross path — `DEC` carries a leading `Xn→T16` step, `LEA` a leading `Ym→Yn` copy. Use **INC/DEC** for in-place adjustments; use **LEA** for a different destination, copies, variable offsets, or PC-relative labels.

### 6.3 Arithmetic Operations

Arithmetic operations perform addition, subtraction, and increment/decrement with flag updates.

#### Carry Convention (read this before ADD/ADC/SUB/SBC/CMP)

The K16 carry flag follows **6502/65816 convention**, not x86/Z80/ARM. The
meaning of C after an arithmetic operation depends on the operation class:

| After... | C = 1 means | C = 0 means |
|----------|-------------|-------------|
| ADD / ADC | **Unsigned overflow** (result > 16 bits) | No overflow |
| SUB / SBC / CMP | **No borrow** — dst ≥ src (unsigned) | Borrow — dst < src (unsigned) |
| AND / OR / XOR / NOT | (always clears C to 0) | — |

**Note on shifts and rotates.** Unlike 6502, x86, and most other
architectures, K16 SHL/SHR/ROL/ROR do **not** set the carry flag from
the shifted-out bit. The entire LOOKUP family (opcode $01) is
flag-transparent — see §15.3. To capture the shifted-out bit, test it
explicitly before the shift (`MOVE Dt, Dn / AND Dt, #$8000 / Bcc …`)
or use ADD/ADC for shift-and-capture (`ADD Dn, Dn` shifts left by 1
through the ALU and sets C from the carry-out).

The SUB/SBC/CMP convention is the opposite of x86. Programmers coming from
x86 should note that on K16:

- `C = 1` after CMP means "greater-or-equal unsigned" — this is why `BCS`
  is aliased to `BHS` (branch if higher-or-same)
- `C = 0` after CMP means "less than unsigned" — aliased to `BLO`
- `SBC` reads the *inverted* carry as borrow-in (`dst - src - ~C`); after
  a SUB that produced no borrow (C=1), the subsequent SBC subtracts
  nothing extra (`~C = 0`)

**Multi-word subtract example:**

```asm
; 32-bit: (D1:D0) ← (D1:D0) - (D3:D2)
    SUB     D0, D2          ; low word; C=1 if D0 >= D2 (no borrow)
    SBC     D1, D3          ; high word - D3 - borrow_in;
                            ; SBC uses ~C so no borrow means ~C=0
```

**Multi-word compare example:**

```asm
; Compare 32-bit (D1:D0) vs (D3:D2), branch if first > second unsigned
    CMP     D1, D3
    BHI     .greater        ; high word strictly greater → done
    BLO     .less_or_equal  ; high word strictly less → done
    CMP     D0, D2          ; high words equal, compare low
    BHI     .greater
.less_or_equal:
    ; ...
```

**Pitfall:** `SUB D0, #1` from `D0 = 0` sets `C = 0` (borrow occurred,
result = $FFFF). Tests that want C=1 should use `SEC`, or arrange a
no-borrow subtract explicitly. Do not assume "subtract from zero sets
carry" — that's x86 semantics, not K16.

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

**Opcode:** $00 mode 10 (XY pairs) or syntax sugar for ADD (D/X/Y)

| Operand | Syntax | Operation | Cycles | Words |
|---------|--------|-----------|--------|-------|
| Dn/Xn/Yn | `INC reg` | reg ← reg + 1 | 3 | 1 |
| Dn/Xn/Yn | `INC reg, #imm` | reg ← reg + imm | 3 | 1-2 |
| XYn | `INC XYn, #imm5` | XYn ← XYn + imm5 | 3 | 1 |

**Flags:** D/X/Y sets flags via ADD. **XY version is flag-transparent** (FLAGSX, CR-2026-001 v1.2; see §15.3 and Appendix C.7).

```asm
INC D0                  ; D0 ← D0 + 1 (→ ADD D0, #1)
INC XY0, #1             ; XY0 ← XY0 + 1 (byte step)
INC XY0, #1w            ; XY0 ← XY0 + 2 (word step)
INC XY0                 ; ASSEMBLER ERROR: explicit step required
```

**XY encoding:** `00000 | 10 | 00 | XYn | imm5`. Example: `INC XY0, #6` = `$0406`.
`imm5` range 0–31; advances the full 24-bit pointer via carry-skip (3 cycles common, +2 on a page-cross).

#### DEC — Decrement

Decrements a register or XY pair.

**Opcode:** $00 mode 11 (XY pairs) or syntax sugar for SUB (D/X/Y)

| Operand | Syntax | Operation | Cycles | Words |
|---------|--------|-----------|--------|-------|
| Dn/Xn/Yn | `DEC reg` | reg ← reg - 1 | 3-4 | 1 |
| Dn/Xn/Yn | `DEC reg, #imm` | reg ← reg - imm | 3-4 | 1-2 |
| XYn | `DEC XYn, #imm5` | XYn ← XYn - imm5 | 4 | 1 |

**Flags:** D/X/Y sets flags via SUB. **XY version is flag-transparent** (FLAGSX, CR-2026-001 v1.2; see §15.3 and Appendix C.7).

```asm
DEC D0                  ; D0 ← D0 - 1 (→ SUB D0, #1)
DEC XY0, #1             ; XY0 ← XY0 - 1 (byte step)
DEC XY0, #1w            ; XY0 ← XY0 - 2 (word step)
DEC XY0                 ; ASSEMBLER ERROR: explicit step required
```

**XY encoding:** `00000 | 11 | 00 | XYn | imm5`. Example: `DEC XY0, #6` = `$0606`.
`imm5` range 0–31; advances the full 24-bit pointer via carry-skip (4 cycles common, +2 on a page-cross).

**Note:** `INC XYn` and `DEC XYn` without an explicit step are **assembler errors**. Always specify the step size to make intent clear:

```asm
INC     XY0, #1         ; byte step (+1)
INC     XY0, #1w        ; word step (+2)
INC     XY0             ; ASSEMBLER ERROR: INC XYn requires explicit step
```

#### NEG — Two's Complement Negate

Negates a register (two's complement). Equivalent to `0 - src`.

**Opcode:** $1E, **Mode:** 01

| Mode | Syntax | Operation | Cycles | Words |
|------|--------|-----------|--------|-------|
| 01 | `NEG dst, src` | dst ← -src | 3 | 1 |
| 01 | `NEG dst` | dst ← -dst (in-place, src=dst) | 3 | 1 |

**Flags:** C, Z, N, V

| Flag | Condition |
|------|-----------|
| Z | Set if result = 0 |
| N | Set if result bit 15 = 1 |
| C | Clear if src ≠ 0 (borrow); Set if src = 0 |
| V | Set if src = $8000 (overflow: -(-32768) unrepresentable) |

**Encoding:** Base word `$F200`. Operand fields: IR[8:5]=dst, IR[4:1]=src,
IR[0]=0 (preserved from the pre-CR-2026-001 layout).

| Instruction | Encoding |
|---|---|
| `NEG D0` | `$F200` |
| `NEG D1` | `$F222` |
| `NEG D0, D1` | `$F202` |
| `NEG X0` | `$F280` |
| `NEG Y0` | `$F300` |

```asm
NEG     D0              ; D0 ← -D0  (in-place)
NEG     D0, D1          ; D0 ← -D1
NEG     D0, D2          ; D0 ← -D2
```

**Note:** Equivalent to `NOT dst; ADD dst, #1` but in a single instruction.

**Note:** NEG was relocated from opcode $00 mode 11 to $1E mode 01 by
CR-2026-001 v1.2 (FLAGSX change). At $00, NEG's flag writes would have
been suppressed by the FLAGSX hardware (which routes opcode $00–$03
flag-bus writes to the internal SRX register), breaking its arithmetic
contract. The new location at $1E mode 01 has FLAGSX=0 and writes
user-visible SR as required. Source-level mnemonic is unchanged; only
the encoding differs.

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
| 11 | `NOT dst, #imm16` | dst ← NOT imm16 | 4 | 2 |

**Flags:** C (cleared), Z, N

```asm
NOT D0, D1              ; D0 ← NOT D1
NOT D0, [XY1]           ; D0 ← NOT memory[XY1]
NOT D0                  ; D0 ← NOT D0 (in-place)
NOT D0, #$1234          ; D0 ← NOT $1234 = $EDCB
```

### 6.5 Shift and Rotate (LOOKUP)

Shift, rotate, and byte manipulation operations implemented via ROM lookup tables.

**Opcode:** $01

| Mode | Syntax | Operation | Cycles | Words |
|------|--------|-----------|--------|-------|
| — | `SHL Dn` | Dn ← Dn << 1 | 3 | 1 |
| — | `SHR Dn` | Dn ← Dn >> 1 (logical) | 3 | 1 |
| — | `ASR Dn` | Dn ← Dn >> 1 (arithmetic) | 3 | 1 |
| — | `ROL Dn` | Dn ← rotate left (bit 15 → bit 0) | 3 | 1 |
| — | `ROR Dn` | Dn ← rotate right (bit 0 → bit 15) | 3 | 1 |
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

**Note:** K16 ROL/ROR are **pure rotates** — the bit shifted out of one
end wraps directly to the other end. They do not rotate through C and
they do not read or write any flag. To rotate a multi-word value through
carry, use the ADC-based idiom (see Programming Tips, §11).

**Lookup Table Pages:**

| Mnemonic | Page | Address Range | Operation |
|----------|------|---------------|-----------|
| SHL | $E0 | $E0_0000-$E1_FFFF | Shift left 1 bit (×2) |
| SHR | $E2 | $E2_0000-$E3_FFFF | Shift right 1 bit (÷2 unsigned) |
| ASR | $E4 | $E4_0000-$E5_FFFF | Arithmetic shift right 1 (÷2 signed) |
| ROL | $E6 | $E6_0000-$E7_FFFF | Rotate left (pure, no carry) |
| ROR | $E8 | $E8_0000-$E9_FFFF | Rotate right (pure, no carry) |
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

**MULB packing patterns:** `MULB` operates on both bytes of the destination register, so operands must be packed in first. The canonical idiom uses `SWAPB`:

```asm
; Basic: multiply byte_a (D0 low) × byte_b (D1 low)
; Precondition: both operands' high bytes are zero (e.g. just produced
; by LOADB, or AND-masked with #$FF).
SWAPB   D1              ; D1 = byte_b << 8  (into high byte; one instruction)
OR      D0, D1          ; D0 = (byte_b << 8) | byte_a
MULB    D0              ; D0 = byte_a × byte_b

; Survive-the-multiply variant: when byte_b (scale factor) must be
; reused after the MULB, recover it from the high byte with HIGH.
; D1 = scale (low byte); D0 = magnitude (low byte)
SWAPB   D1              ; D1 = scale << 8  (into high byte)
OR      D0, D1          ; D0 = (scale << 8) | magnitude
MULB    D0              ; D0 = scale × magnitude  (D1 still holds scale<<8)
HIGH    D1              ; D1 = scale restored from high byte — no memory reload
; D1 can now be reused as scale factor for a second MULB
```

> **Prefer `SWAPB Dn` to `SHL4 / SHL4` when packing a clean low byte into
> the high half** — one instruction instead of two, and it states the
> intent. Both are correct: the claim that the two-`SHL4` form corrupts
> bytes above `$0F` was **false and is retracted** (Appendix B.11).

**Multi-bit shifts.** The assembler accepts `SHL Dn, #count`,
`SHR Dn, #count`, and `ASR Dn, #count` as pseudo-instructions that
expand to the shortest known sequence of native LOOKUP shifts. See
§6.15.

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

Sets a register based on flags: `$FFFF` if condition true, else a specified value.

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

**Result encoding:** Scc instructions produce **`$FFFF`** when the
condition is true (all-ones, a valid signed `-1` and the conventional
boolean-true representation for bit-mask use) and **`$0000`** (or the
optional `#imm16`) when false. The `$FFFF` result is deliberate so it
can be ANDed against another value as a conditional mask without an
intermediate sign-extend or compare. Prior emulator versions (pre-14
May 2026) produced `1`/`0` instead of `$FFFF`/`$0000`; this was a
historical emulator bug since fixed. Hardware (Digital simulator and
the discrete TTL build) has always produced `$FFFF`/`$0000` correctly.

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

**Pseudo-branches.** `BHI` (branch if higher unsigned) and `BLS`
(branch if lower-or-same unsigned) are recognised by the assembler and
expand to short native sequences using BEQ/BHS and BEQ/BLO respectively.
See §6.15.

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

**JMPT is an indexed indirect jump — it fetches the target from memory**, it does not jump to XYn directly. The full operation is:

```
EA  = Xn + Dm           (16-bit add, page-local — see Appendix B item 1)
PC  = Yn : mem[Yn:EA]   (target word read from memory)
```

Both operands are required: `JMPT XY1, D0`. Dm must contain a **word offset** (index × 2) into the jump table. Typical use:

```asm
; XY1 = base of dispatch table; D0 = (token - base) * 2
JMPT    XY1, D0         ; PC = mem[$FF : X1+D0]
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

**Note:** All CALL variants push a 24-bit return address to XY3 and return with `RET` (opcode $1E mode 11). See Section 6.11.

### 6.11 TRAP and RET-family Instructions

Software syscall and return from subroutine. The RET family comprises three
instructions sharing opcode `$1E`: plain `RET` (flag-transparent), `RETCC`
(return + clear carry, syscall-success exit), and `RETCS` (return + set
carry, syscall-error exit).

**Opcode:** $1E (TRAP/RET family)

| Mode | Syntax | Operation | Cycles | Words |
|------|--------|-----------|--------|-------|
| 00 | `TRAP #n` | push PC; PC ← vector[n] | 12 | 1 |
| 01 | `NEG dst[, src]` | dst ← -src (see Section 6.3) | 3 | 1 |
| 10 | `RETCC [#nw]` | PC ← pop; SP += 4 + (n×2); SR ← $00 | 6 | 1 |
| 10 | `RETCS [#nw]` | PC ← pop; SP += 4 + (n×2); SR ← $01 | 6 | 1 |
| 11 | `RET [#nw]` | PC ← pop; SP += 4 + (n×2) | 6 | 1 |

The three RET-family instructions execute in 6 cycles (1 fetch + 5
execution). NEG (mode 01) is documented in Section 6.3 — it shares
opcode $1E because the FLAGSX hardware (CR-2026-001 v1.2) reserves
opcodes $00–$03 for flag-transparent operations, and NEG must write
user-visible flags.

**Flags:**
- `TRAP`, `RET` — not affected (flag-transparent).
- `RETCC` — C ← 0, Z ← 0, N ← 0, V ← 0 (SR ← $00).
- `RETCS` — C ← 1, Z ← 0, N ← 0, V ← 0 (SR ← $01).

#### TRAP Encoding

IR[7:0] = n×2, n in Section 0..127. Instruction word = `$F000 or (n*2)`.

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

#### RETCC / RETCS Encoding

Opcode `$1E` mode `10`. The control ROM in step 5 reads IR[8:7] to select
the carry value written to SR — IR[8:7]=00 selects RETCC, IR[8:7]=01
selects RETCS. IMM5 = 4 + (cleanup_words × 2), identical to RET.

| Bits 15-11 | Bits 10-9 | Bit 8 | Bit 7 | Bits 6-5 | Bits 4-0 |
|------------|-----------|-------|-------|----------|----------|
| `11110` ($1E) | `10` (mode 10) | `0` | `0` (RETCC) / `1` (RETCS) | `00` | `4 + cleanup_bytes` |

Base words: `RETCC = $F404`, `RETCS = $F484`. Cleanup adds 2 per word.

| Instruction | Encoding | Stack adjustment |
|-------------|----------|------------------|
| `RETCC` | `$F404` | SP += 4 |
| `RETCC #1w` | `$F406` | SP += 6 |
| `RETCC #2w` | `$F408` | SP += 8 |
| `RETCC #4w` | `$F40C` | SP += 12 |
| `RETCS` | `$F484` | SP += 4 |
| `RETCS #1w` | `$F486` | SP += 6 |
| `RETCS #2w` | `$F488` | SP += 8 |
| `RETCS #4w` | `$F48C` | SP += 12 |

**Cleanup-byte range.** The IMM5 field encodes `4 + cleanup_bytes` with
IMM5 in the range 0..31, so valid `#nw` operands are `#0w` through `#13w`
(0..26 bytes of cleanup). Cleanup bytes must be even; the assembler
enforces this and reports an error for odd values. Byte-count operands
(without the `w` suffix) are accepted but generate a warning suggesting
word-count form for clarity.

**Reserved combinations.** Mode 01 in opcode $1E holds `NEG` (relocated here from $00 mode 11 by the FLAGSX change — see §6.3 and the $1E encoding table above). Within
mode 10, IR[8]=1 is reserved as a second selector bit; future variants
(e.g. return-and-toggle-carry) could be added at IR[8:7]=10 or 11
without consuming a new opcode/mode slot. Currently reserved encodings
in mode 10 fall through to RETCC behaviour via the microcode's `else`
clause — they decode safely as RETCC rather than as undefined behaviour.

**Encoding summary table.** The complete assignment for opcode $1E:

| Opcode | Mode | IR[8] | IR[7] | Mnemonic | Base word |
|--------|------|-------|-------|----------|-----------|
| `$1E` | `00` | x | x | `TRAP #n` | `$F000` |
| `$1E` | `01` | — | — | `NEG dst[, src]` | `$F200` |
| `$1E` | `10` | `0` | `0` | `RETCC [#nw]` | `$F404` |
| `$1E` | `10` | `0` | `1` | `RETCS [#nw]` | `$F484` |
| `$1E` | `10` | `1` | x | (reserved, falls through to RETCC) | — |
| `$1E` | `11` | x | x | `RET [#nw]` | `$F66C` |

#### Vector Table

The vector table lives at fixed physical address `$00_0000-$00_01FC`,
independent of Y3. Each entry is 4 bytes: page byte at offset+0
(word-aligned, high byte unused), address word at offset+2. The vector
for TRAP #n is at `$00:n×4`. TRAP and INT microcode reach the table via
the ZOA AB sub-write (Section 6.14, Section 9.5).

```
$00:0000  TRAP #0    INT dispatcher (microcode also jumps here on hardware INT)
$00:0004  TRAP #1    IRQ0 handler (lowest priority)
$00:0008  TRAP #2    IRQ1 handler
$00:000C  TRAP #3    IRQ2 handler
$00:0010  TRAP #4    IRQ3 handler
$00:0014  TRAP #5    IRQ4 handler
$00:0018  TRAP #6    IRQ5 handler
$00:001C  TRAP #7    IRQ6 handler
$00:0020  TRAP #8    IRQ7 handler (highest priority, typically timer)
$00:0024  TRAP #9    first syscall
...
$00:01FC  TRAP #127  last syscall
```

Handler bodies themselves can live anywhere in the 24-bit address space.

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

#### Flag Behaviour of TRAP and the RET Family

TRAP does **not** push SR. Plain `RET` does **not** pop or write SR — it
is fully flag-transparent. A handler that exits via `RET` returns the
flags it last set to the caller. This enables the K16 syscall convention
of returning error status in C:

- **C = 0 on return**: success; D0 holds the result (value, count, handle).
- **C = 1 on return**: error; D0 holds an error code.

The caller tests with a single `BCS error` after the TRAP — no sentinel
compare needed.

`RETCC` and `RETCS` are the canonical syscall-exit instructions. They
write the **entire SR low nibble** deterministically: `RETCC` writes
SR ← $00 (C=0, Z=0, N=0, V=0) and `RETCS` writes SR ← $01 (C=1,
Z=0, N=0, V=0). They are behaviourally identical to the legacy
`LOADI SR, #$00 / RET` and `LOADI SR, #$01 / RET` idioms — same caller-
observed SR state, with only the C flag differing between the two
variants — but bake the flag-write into the return itself, saving one
instruction and ~2 cycles per call site.

Contrast with `INT` (hardware interrupt) and `RTI` (return from interrupt),
which **do** push and pop SR. Asynchronous interrupts must not disturb the
interrupted program's flags; synchronous TRAPs are a deliberate message-
passing primitive, and flag-return is part of the protocol.

**Canonical handler exit pattern (RETCC / RETCS):**

```asm
handler:
    ; ... do work ...
    LOADI   D0, #result     ; LOADI Dn is flag-transparent
    RETCC                   ; return + SR=$00 (C=0 = success)

.error:
    LOADI   D0, #ERR_INVAL
    RETCS                   ; return + SR=$01 (C=1 = error)
```

If a handler needs to forward a specific Z/N/V value to the caller
(rare — the C-only convention is the norm), it must use plain `RET`
with the flags pre-set by the handler body. RETCC/RETCS force
Z=N=V=0 and so cannot forward arbitrary Z/N/V.

If a handler needs to preserve the **caller's** flags (rather than
overwrite them with its own result), it must explicitly save and
restore SR and use plain `RET`:

```asm
handler_no_flag_clobber:
    PUSH    SR, XY3         ; save caller's SR
    ; ... work that may touch flags ...
    POP     D0, XY3         ; D0 gets saved SR value
    MOVE    SR, D0          ; restore
    RET
```

*Note:* `MOVE SR, Dn` writes only the low nibble (same semantics as
`LOADI SR, #imm`); IE/LVL are unaffected. For full SR restore across an
interrupt boundary, use RTI.

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
        RETCC                       ; return + C=0 (success)
```

### 6.12 Stack Operations

Push and pop operations for saving/restoring registers.

**Opcodes:** $06 (PUSH), $07 (POP)

| Op Mode | Syntax | Operation | Cycles | Words |
|---------|--------|-----------|--------|-------|
| $06 00 | `PUSH Dn, XYs` | SP -= 2; mem[SP] ← Dn (single D register) | 5 | 1 |
| $06 01 | `PUSH D123, XYs` | Push D1/D2/D3 (3 words) — D0 untouched | 11 | 1 |
| $06 10 | `PUSH XYn, XYs` | Push XY pair (2 words) | 8 | 1 |
| $06 11 | `PUSH reg, XYs` | Push single X/Y/ORDB/SR/PCH/PCL register | 5 | 1 |
| $07 00 | `POP reg, XYs` | reg ← mem[SP]; SP += 2 (any register) | 4 | 1 |
| $07 01 | `POP D123, XYs` | Pop D3/D2/D1 (3 words, reverse) — D0 untouched | 8 | 1 |
| $07 10 | `POP XYn, XYs` | Pop XY pair (2 words) | 6 | 1 |
| $07 11 | `PUSH #imm, XYs` | Push immediate (PUSHI) | 5 | 1-2 |

**Flags:** Not affected (except POP SR)

**Register split.** `PUSH` of a **D** register uses `$06` mode 00; `PUSH` of an **X/Y/ORDB/SR/PCH/PCL** register uses `$06` mode 11. `POP` of *any* single register is unified at `$07` mode 00. `$07` mode 11 is not a POP — it is `PUSH #imm` (PUSHI), since POP has no immediate form.

```asm
PUSH D0, XY3            ; Push single D register ($06 mode 00)
PUSH D123, XY3          ; Push D1, D2, D3 (V2 ABI callee-saved set)
PUSH XY0, XY3           ; Push XY pair
PUSH SR, XY3            ; Push X/Y/SR-class register ($06 mode 11)
PUSH #$1234, XY3        ; Push immediate ($07 mode 11 / PUSHI)
PUSH D0                 ; Default stack XY3
POP  D0, XY3            ; Pop single register
POP  D123, XY3          ; Pop D3, D2, D1 (reverse order)
POP  XY0, XY3           ; Pop XY pair
```

**`PUSH D123` / `POP D123` group behaviour.** The group push/pop operates
on **D1, D2, D3** — the V2 ABI callee-preserved set. **D0 is deliberately
not touched**, because D0 is the V2 result/error register and must
survive a callee-side save/restore unchanged. This makes `PUSH D123` /
`POP D123` safe in any handler that returns a value in D0.

Push order (D1 → highest address):
```
[X[XYs] + 0]:  D3   (written last, lowest address)
[X[XYs] + 2]:  D2
[X[XYs] + 4]:  D1   (written first, highest address)
```

Pop order is the reverse — D3 read first from the lowest address, then
D2, then D1. The pair is fully symmetric and correctly restores all
three callee-saved D registers.

If a routine genuinely needs to save D0 as well (e.g. an interrupt
handler that clobbers D0 before its result is finalised), use four
individual `PUSH D0..D3` instructions — there is no group form that
includes D0.

> **Breaking change in v3.12.** The legacy `PUSH D` / `POP D` group
> instructions (which operated on all four D registers, D0-D3) have
> been **removed**. Opcode $06/$07 mode 01 is reassigned to `PUSH D123`
> / `POP D123`. The assembler rejects `PUSH D` / `POP D` with a hard
> error pointing at the new mnemonic. See Appendix B.7 for migration
> guidance.

### 6.13 Control

Processor control instructions.

**Opcode:** $00

| Mode | Syntax | Operation | Cycles | Words |
|------|--------|-----------|--------|-------|
| 00 | `NOP` | No operation | 2 | 1 |
| 01 | `HALT` | Stop processor | 2 | 1 |
| 01 | `HALT #n` | Stop with code n | 2 | 1 |

**Flags:** Not affected.

```asm
NOP                     ; Do nothing
HALT                    ; Stop execution
HALT #$FF               ; Stop with debug code
```

**Debug:** HALT displays D0 on ALU-A bus for debugging.

**Note:** NEG was previously at $00 mode 11; it moved to $1E mode 01 in
v3.13 (CR-2026-001 v1.2 — FLAGSX). See Section 6.3 and Appendix C.7.
Modes 10 and 11 of opcode $00 are reserved for future flag-transparent
operations only (per the FLAGSX architectural invariant).

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
| 3:0 | SR flags (N, Z, C, V) |

**INT and the TRAP #0 vector:**

Hardware interrupts (INT) and `TRAP #0` both dispatch through the vector
at fixed physical address `$00:0000`. The microcode reaches it via the
ZOA AB sub-write, so dispatch works regardless of the running task's Y3
(see Section 9.5 — Y3 is reserved by k/OS as the per-task page).
The OS installs the dispatcher at boot:

```asm
; Install INT dispatcher at TRAP #0 vector ($00:0000)
        LOADI   D0, #>isr_entry
        STOREZ  D0, [#$0000]         ; page byte (Y-independent)
        LOADI   D0, #<isr_entry
        STOREZ  D0, [#$0002]         ; address word
        EINT                         ; enable interrupts

; INT dispatcher — reaches the per-IRQ vectors via $00 page.
; Runs with the interrupted task's Y3 still loaded; uses a scratch
; XY pair pointing at $00 to read the handler address.
isr_entry:
        PUSH    D0, XY3
        PUSH    XY0, XY3
        MOVE    D0, SR              ; D0 = SR (level in bits 6:4)
        SHR4    D0                  ; bits 6:4 → bits 2:0
        AND     D0, #$0007          ; D0 = IRQ level 0-7
        ADD     D0, #1              ; D0 = TRAP# 1-8
        SHL     D0
        SHL     D0                  ; D0 = vector offset $04..$20
        LOADI   Y0, #$00            ; XY0 = $00:offset
        MOVE    X0, D0
        JMPT    XY0, #0             ; PC ← [$00:offset+2]
        ; IRQ handlers live at the TRAP #1..#8 slots, return with RTI
```

**Note:** TRAP handlers return with `RET`; IRQ handlers invoked via the INT dispatcher return with `RTI` (which also restores SR and re-enables interrupts).

#### SEC and CLC — Carry Flag Manipulation

`SEC` and `CLC` are assembler-level Level-2 aliases for the two most common
LOADI-SR patterns used by the syscall ABI:

| Alias | Expands to | Encoding | Operation |
|-------|------------|----------|-----------|
| `SEC` | `LOADI SR, #$01` | `$C1A1` | Set carry (C=1, Z=N=V=0) |
| `CLC` | `LOADI SR, #$00` | `$C1A0` | Clear carry (all flags clear) |

Both aliases clear Z, N, and V — they are full flag-nibble writes, not
read-modify-write. Use them for syscall success/error exits and for pre-
positioning C before `ADC` / `SBC`.

```asm
    ; Syscall exit
    LOADI   D0, #result
    SEC                     ; or CLC
    RET

    ; Set up for multi-word add
    LOADI   D2, #0          ; dummy
    CLC                     ; C=0 before first ADD
    ADD     D0, [XY0]       ; low word
    ADC     D1, [XY0+#2]    ; high word, ADC uses C from low-word ADD
```

No `SEZ`/`CLZ`/`SEN`/etc. aliases exist — use the general `LOADI SR, #imm5`
form for any flag combination other than C-only.

### 6.15 Pseudo-Instructions

The K16 assembler accepts certain mnemonics that do not correspond to
single native opcodes. These **pseudo-instructions** are recognised at
assembly time and expanded into fixed sequences of native instructions
before encoding. They exist to:

- Provide readable mnemonics for common idioms that would otherwise
  require multi-instruction synthesis (e.g. `BHI` for "branch if higher
  unsigned").
- Let the assembler pick the optimal native instruction sequence for
  cost-sensitive operations (e.g. `SHL Dn, #n` selecting between
  single-bit shifts, 4-bit shifts, and byte-level operations based on
  the constant count).

Pseudo-instructions do not consume native opcode encodings and require
no hardware support. The decomposition is mechanical and is documented
below so that authors can predict the assembled output.

#### 6.15.1 BHI — Branch if Higher (unsigned)

After `CMP A, B`, `BHI target` branches if `A > B` strictly (unsigned).

| Syntax | Expansion | Cycles | Words |
|---|---|---|---|
| `BHI target` | `BEQ.S .__skip` / `BHS target` / `.__skip:` | 6–7 | 2–3 |

The `.__skip` label is a synthetic local label generated uniquely per
invocation. Authors must not use identifiers starting with `__`.

The one-operand form `BHI target` and the two-operand documentary form
`BHI Dn, target` are both accepted. The `Dn` operand is documentation
only — it carries no encoding information. Optional `.S` / `.L` suffix
forces the underlying BHS to short or long encoding; auto otherwise.

**Example:**

```asm
                CMP     D0, #LIMIT
                BHI     .reject             ; D0 > LIMIT → reject
                ; ... in-range processing ...
```

Equivalent native code:

```asm
                CMP     D0, #LIMIT
                BEQ.S   .__bhi_0            ; equal → don't branch
                BHS     .reject             ; ≥ but not = → strictly greater
.__bhi_0:
```

#### 6.15.2 BLS — Branch if Lower or Same (unsigned)

After `CMP A, B`, `BLS target` branches if `A ≤ B` (unsigned).

| Syntax | Expansion | Cycles | Words |
|---|---|---|---|
| `BLS target` | `BEQ target` / `BLO target` | 6–8 | 2–3 |

No synthetic label is generated; both internal branches target the
user-supplied label. Operand and suffix conventions match BHI.

**Example:**

```asm
                CMP     D0, D1
                BLS     .skip               ; D0 ≤ D1 → skip update
                MOVE    D1, D0              ; update max
.skip:
```

#### 6.15.3 SHL Dn, #n — Shift Left by constant n

Shifts `Dn` left by `n` bits (logical). Flags not affected.

The assembler emits the shortest known sequence of native shifts for
each count, drawing from `SHL`, `SHL4`, `LOW`, `SWAPB`, and `LOADI #0`:

| `n` | Expansion | Cycles | Words |
|---|---|---|---|
| 0  | (nothing) | 0 | 0 |
| 1  | `SHL`  | 3 | 1 |
| 2  | `SHL × 2`  | 6 | 2 |
| 3  | `SHL × 3`  | 9 | 3 |
| 4  | `SHL4` | 3 | 1 |
| 5  | `SHL4 / SHL` | 6 | 2 |
| 6  | `SHL4 / SHL × 2` | 9 | 3 |
| 7  | `SHL4 / SHL × 3` | 12 | 4 |
| 8  | `LOW / SWAPB` | 6 | 2 |
| 9  | `LOW / SWAPB / SHL` | 9 | 3 |
| 10 | `LOW / SWAPB / SHL × 2` | 12 | 4 |
| 11 | `LOW / SWAPB / SHL × 3` | 15 | 5 |
| 12 | `SHL4 × 3` | 9 | 3 |
| 13 | `SHL4 × 3 / SHL` | 12 | 4 |
| 14 | `SHL4 × 3 / SHL × 2` | 15 | 5 |
| 15 | `SHL4 × 3 / SHL × 3` | 18 | 6 |
| 16 | `LOADI Dn, #0` (IMM5) | 2 | 1 |
| ≥17 | `LOADI Dn, #0` (with warning) | 2 | 1 |

**Example:**

```asm
                ; X2 = drive << 6 = drive × 64
                SHL     D0, #6
                MOVE    X2, D0
```

Equivalent native code:

```asm
                SHL4    D0
                SHL     D0
                SHL     D0
                MOVE    X2, D0
```

9 cycles instead of the 18 cycles a naive `SHL × 6` chain would take.

#### 6.15.4 SHR Dn, #n — Shift Right by constant n (logical)

Shifts `Dn` right by `n` bits (logical — zeros fill from the top).
Flags not affected. `HIGH` provides the unsigned `>> 8` shortcut:

| `n` | Expansion | Cycles | Words |
|---|---|---|---|
| 0  | (nothing) | 0 | 0 |
| 1  | `SHR`  | 3 | 1 |
| 2  | `SHR × 2`  | 6 | 2 |
| 3  | `SHR × 3`  | 9 | 3 |
| 4  | `SHR4` | 3 | 1 |
| 5  | `SHR4 / SHR` | 6 | 2 |
| 6  | `SHR4 / SHR × 2` | 9 | 3 |
| 7  | `SHR4 / SHR × 3` | 12 | 4 |
| 8  | `HIGH` | 3 | 1 |
| 9  | `HIGH / SHR` | 6 | 2 |
| 10 | `HIGH / SHR × 2` | 9 | 3 |
| 11 | `HIGH / SHR × 3` | 12 | 4 |
| 12 | `HIGH / SHR4` | 6 | 2 |
| 13 | `HIGH / SHR4 / SHR` | 9 | 3 |
| 14 | `HIGH / SHR4 / SHR × 2` | 12 | 4 |
| 15 | `HIGH / SHR4 / SHR × 3` | 15 | 5 |
| 16 | `LOADI Dn, #0` (IMM5) | 2 | 1 |
| ≥17 | `LOADI Dn, #0` (with warning) | 2 | 1 |

**Example:**

```asm
                ; PRNG step: x ^= x >> 9
                MOVE    D1, D0
                SHR     D1, #9
                XOR     D0, D1
```

Equivalent native code:

```asm
                MOVE    D1, D0
                HIGH    D1
                SHR     D1
                XOR     D0, D1
```

6 cycles instead of the 27 cycles a naive `SHR × 9` chain would take —
a 78 % reduction.

#### 6.15.5 ASR Dn, #n — Arithmetic Shift Right by constant n (signed)

Shifts `Dn` right by `n` bits (arithmetic — the sign bit fills the high
positions). Flags not affected. `ASR8` provides the signed `>> 8`
shortcut:

| `n` | Expansion | Cycles | Words |
|---|---|---|---|
| 0  | (nothing) | 0 | 0 |
| 1  | `ASR`  | 3 | 1 |
| 2  | `ASR × 2`  | 6 | 2 |
| 3  | `ASR × 3`  | 9 | 3 |
| 4  | `ASR4` | 3 | 1 |
| 5  | `ASR4 / ASR` | 6 | 2 |
| 6  | `ASR4 / ASR × 2` | 9 | 3 |
| 7  | `ASR4 / ASR × 3` | 12 | 4 |
| 8  | `ASR8` | 3 | 1 |
| 9  | `ASR8 / ASR` | 6 | 2 |
| 10 | `ASR8 / ASR × 2` | 9 | 3 |
| 11 | `ASR8 / ASR × 3` | 12 | 4 |
| 12 | `ASR8 / ASR4` | 6 | 2 |
| 13 | `ASR8 / ASR4 / ASR` | 9 | 3 |
| 14 | `ASR8 / ASR4 / ASR × 2` | 12 | 4 |
| 15 | `ASR8 / ASR4 / ASR × 3` | 15 | 5 |
| ≥16 | `ASR × 16` (saturates at sign bit; warning) | 48 | 16 |

**Asymmetry with SHR:** arithmetic right-shift by 16 or more does NOT
zero the register — a negative value saturates at `$FFFF`, a positive
at `$0000`. The assembler emits a warning suggesting `SHR` if
zero-fill is intended.

**Example:**

```asm
                ; Signed (D0 / 256), rounded toward -∞
                ASR     D0, #8
```

Equivalent native code:

```asm
                ASR8    D0
```

3 cycles instead of the 24 cycles a naive `ASR × 8` chain would take.

#### 6.15.6 Listing behaviour

Pseudo-instructions appear in listings with their expansion visible.
The listing emits an auto-generated summary banner as a comment line
*before* the first emitted instruction, and shows the disassembled
mnemonic on every line of the expansion. Trailing comments on the
original pseudo line attach to the first emitted instruction.

A typical listing for `SHL D0, #6 ; test comment`:

```
                                              ; SHL D0, #6  ->  SHL4 / SHL / SHL  (9c, 3w)
F0 0002      08F2     ----       1.0.2     SHL4     D0         ; test comment
F0 0004      08E0     ----       1.0.2     SHL      D0
F0 0006      08E0     ----       1.0.2     SHL      D0
```

The banner format is `<pseudo as written>  ->  <native mnemonics>  (Nc, Nw)`,
where the trailing parenthesis shows total cycles and words. For
BHI/BLS the parenthesis is omitted because the actually-encoded size
depends on short/long forward-ref resolution.

#### 6.15.7 Reserved identifier prefix

Identifiers starting with `__` are reserved for assembler-generated
synthetic labels. User-defined identifiers matching this pattern are
rejected with a parse error:

```
Identifier "__myvar" starts with reserved prefix "__"
(reserved for the assembler)
```

The check also applies to local labels (`.__foo`).

#### 6.15.8 Errors and warnings

| Condition | Diagnostic |
|---|---|
| `SHL Dn, #-3` | **Error**: "negative shift count" |
| `SHL Dn, #17` | **Warning**: "shift count clamped to 16; result is zero" |
| `SHL Dn, #0` / `SHR Dn, #0` / `ASR Dn, #0` | **Warning**: "X Dn, #0 emits no code; remove the line or check the count expression" |
| `ASR Dn, #20` | **Warning**: "ASR by 16 or more saturates at sign bit; consider SHR if zero-fill is intended" |
| `SHL Dn, #14` / `SHL Dn, #15` | **Hint**: AND+ROR alternative is cheaper if flags don't matter (see §6.15.9) |
| `SHR Dn, #14` / `SHR Dn, #15` | **Hint**: ROL+AND alternative is cheaper if flags don't matter (see §6.15.9) |
| `BHI` with no operand | **Error**: "BHI requires 1 or 2 operands: BHI [Dn,] target" |
| `SHL Dn, Dm` (register count) | **Error**: SHL with 2 operands and register source — encoder rejects (variable-count shifts require a runtime loop) |
| Label starts with `__` or `.__` | **Error**: "Identifier starts with reserved prefix" |

#### 6.15.9 Optimisation hints

`SHL Dn, #n` and `SHR Dn, #n` use only LOOKUP-class native instructions
which **preserve all flags** (FLAGSX hardware, see Appendix C.7). This
makes the multi-instruction expansions safe to insert between a CMP and
a conditional branch:

```asm
                CMP     D2, #LIMIT
                SHL     D0, #15         ; safe — flags survive
                BEQ     .equal          ; reads CMP's flags
```

The flag-preservation guarantee costs cycles and words for counts
where a mask-and-rotate alternative exists. When the user can afford
to clobber C/Z/N, four counts have substantially cheaper sequences:

| Pseudo | Current expansion | AND/ROL alternative | Saving |
|---|---|---|---|
| `SHL Dn, #14` | SHL4 ×3 / SHL ×2 (15c, 5w) | `AND Dn, #3 / ROR Dn / ROR Dn` (9c, 3w) | 6c, 2w |
| `SHL Dn, #15` | SHL4 ×3 / SHL ×3 (18c, 6w) | `AND Dn, #1 / ROR Dn` (6c, 2w) | **12c, 4w** |
| `SHR Dn, #14` | HIGH / SHR4 / SHR ×2 (12c, 4w) | `ROL Dn / ROL Dn / AND Dn, #3` (9c, 3w) | 3c, 1w |
| `SHR Dn, #15` | HIGH / SHR4 / SHR ×3 (15c, 5w) | `ROL Dn / AND Dn, #1` (6c, 2w) | **9c, 3w** |

The alternative clobbers **C, Z, N** (AND clears C and sets Z/N from
the masked result). V is preserved.

When the assembler sees `SHL Dn, #14`, `SHL Dn, #15`, `SHR Dn, #14`,
or `SHR Dn, #15`, it emits a hint pointing at the alternative. The
hint is informational — no behaviour change, and the safe expansion is
used unless the user hand-codes the alternative.

ASR has no corresponding shortcut at these counts: the sign-fill
semantics can't be reproduced by a simple mask-and-rotate.

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
| LOADZB | Load byte from page `$00` (Y-independent, zero-extended to 16 bits) |
| STOREZB | Store low byte to page `$00` (Y-independent) |

```asm
; Byte access via XY pair
LOADB   D0, [XY0]           ; D0 ← zero-extended byte from memory[XY0]
STOREB  D0, [XY0]           ; memory[XY0] ← low byte of D0

; Byte access via paged memory
LOADI   Y0, #$20
LOADPB  D0, Y0, [#$0400]    ; D0 ← zero-extended byte from $20:0400
STOREPB D0, Y0, [#$0401]    ; $20:0401 ← low byte of D0

; Byte access to page $00 (any Y3)
LOADZB  D0, [#$0123]        ; D0 ← zero-extended byte from $00:0123
STOREZB D0, [#$0123]        ; $00:0123 ← low byte of D0
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

**Preference:** `SWAPB` is the one-instruction `<< 8` for byte packing and
is preferred over two consecutive `SHL4` on size and clarity grounds. The
former claim that the two-`SHL4` form corrupts bytes above `$0F` was false
and is retracted — see Appendix B.11.

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

## 8. Memory Layout and Endianness

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

The interrupt/TRAP vector table entry is a single 16-bit word at
fixed physical address `$00:offset+2` — read as a little-endian word,
no special handling. Microcode reaches it via the ZOA AB sub-write
(Section 9.5).

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
        STOREB  D0, [XY1]       ; write to terminal ($DF0000)
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

## 9. Page $00 Programming

The K16 provides efficient direct access to frequently-used variables
in Page $00 (the first 64KB of address space) using the LOADP/STOREP
instructions. This technique saves significant cycles compared to
indexed addressing.

### 9.1 Concept

Page $00 refers to the first 64KB of the K16 address space, accessed
via the **LOADZ/STOREZ** instruction family (Section 6.1) which use
the ZOA AB sub-write to force the address-bus high byte to `$00`
regardless of any Y register. This region holds the vector table,
kernel data, and shared OS structures that must be reachable from
any task context.

LOADZ/STOREZ are Y-independent. They are the correct primitive for
zero-page access under k/OS, where Y3 is reserved as the **current
task page** and is generally not `$00` (Section 9.5).

> **Terminology note:** The name "zero page" is sometimes used
> informally for this region, and the revision history preserves that
> usage. It has no relation to the 6502's single-byte zero-page
> addressing mode — K16 does not have that mode. "Page $00" is the
> canonical term.

> **Historical note:** Earlier K16 manuals (≤ v3.9) accessed page $00
> through `LOADP/STOREP` with Y3 = $00. That convention is replaced
> by LOADZ/STOREZ. See Section 9.5 for details.

**Performance comparison:**

| Method | Instructions | Cycles | XY Register |
|--------|--------------|--------|-------------|
| Indexed access | LOADI X0 + LOADI Y0 + LOADD | 6 | XY0 consumed |
| Page $00 direct (LOADZ) | LOADZ | 3 | None (Y-independent) |

**Savings:** 3 cycles per load (50% faster), plus all XY registers remain free.

### 9.2 Memory Map (Page $00)

The stack segment at page $00 is organized for both stack operations and Page $00 variables:

| Address Range | Offset | Size | Purpose |
|---------------|--------|------|---------|
| $00_0000-$00_01FF | $0000 | 512 bytes | TRAP/INT vector table (128 entries × 4 bytes) |
| $00_0200-$00_02FF | $0200 | 256 bytes | System variables |
| $00_0300-$00_037F | $0300 | 128 bytes | Forth interpreter reserved |
| $00_0380-$00_03FF | $0380 | 128 bytes | Pascal/compiler reserved |
| $00_0400-$00_0FFF | $0400 | ~3KB | Application Page $00 |
| $00_1000-$00_FFFF | $1000 | ~60KB | Stack space (grows down) |

**Vector table layout:** Each entry is 4 bytes — page byte at offset+0, address word at offset+2. TRAP #n vector is at offset n×4. Microcode reads vectors via ZOA, so the addresses below are physical and Y-independent.

```
$00:0000  TRAP #0    INT dispatcher (also hardware INT entry point)
$00:0004  TRAP #1    IRQ0 handler (lowest priority)
$00:0008  TRAP #2    IRQ1 handler
$00:000C  TRAP #3    IRQ2 handler
$00:0010  TRAP #4    IRQ3 handler
$00:0014  TRAP #5    IRQ4 handler
$00:0018  TRAP #6    IRQ5 handler
$00:001C  TRAP #7    IRQ6 handler
$00:0020  TRAP #8    IRQ7 handler (highest priority, typically timer)
$00:0024  TRAP #9    first syscall
...
$00:01FC  TRAP #127  last syscall
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

### 9.4 Accessing Page $00 Variables

Use **LOADZ/STOREZ** (Y-independent) for kernel and shared data:

```asm
; Define Page $00 variable locations
ZP_COUNTER   .EQU    $0400
ZP_FLAGS     .EQU    $0402
ZP_TEMP      .EQU    $0404

; Load from Page $00 (3 cycles)
LOADZ   D0, [#ZP_COUNTER]       ; D0 ← [$00:0400], any Y3
LOADZ   D1, [#ZP_FLAGS]         ; D1 ← [$00:0402]

; Store to Page $00 (5 cycles)
STOREZ  D0, [#ZP_TEMP]          ; [$00:0404] ← D0

; Byte access (3 cycles load, 5 cycles store)
LOADZB  D0, [#ZP_FLAGS]         ; Load byte, zero-extended
STOREZB D0, [#ZP_FLAGS]         ; Store low byte only
```

### 9.5 Y3 as the Current Task Page (k/OS Convention)

Under k/OS, Y3 is reserved as the **current task page**. Each running
task is given its own 64KB page in physical memory; the scheduler
loads Y3 with that page number on context-switch entry, so all
existing Y-banked addressing modes (`[XYn]`, `[XYn+#imm5]`, etc., when
the XY pair has Y=Y3) reach the task's local memory transparently.

| Register | Old role (≤ v3.9)         | New role (v3.10+)                 |
|----------|---------------------------|-----------------------------------|
| Y3       | Page $00 base (always 00) | Current task page (per-task)      |

This change has two consequences:

1. **Application code must not modify Y3** except through k/OS
   task-switch primitives.
2. **Kernel data on page $00 — vectors, system variables, ISR-shared
   structures — must be accessed with LOADZ/STOREZ**, never with
   `LOADP/STOREP, Y3`. ZOA dispatch in TRAP and INT microcode means
   vector lookup also works under any task's Y3.

`LOADP/STOREP` with an explicit Y register remain available for
reaching arbitrary banked memory (e.g. another task's page from kernel
mode, or memory-mapped device pages).

### 9.6 Reserved Allocations

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

### 9.7 Application Variables ($0400-$0FFF)

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

### 9.8 Example: Complete Program

```asm
;=====================================================
; Page $00 Definitions
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
        ; Initialize stack — bare-metal demo: stack lives in page $00
        LOADI   X3, #$FFF0
        LOADI   Y3, #$00            ; (under k/OS, Y3 is set per task)

        ; Setup interrupt vector at $00:0000 — Y-independent
        LOADI   D0, #>ISR
        STOREZ  D0, [#$0000]
        LOADI   D0, #<ISR
        STOREZ  D0, [#$0002]

        ; Initialize Page $00 variables
        LOADI   D0, #0
        STOREZ  D0, [#ZP_COUNT]
        STOREZ  D0, [#ZP_SUM]

        EINT

LOOP:
        LOADZ   D0, [#ZP_COUNT]
        ADD     D0, #1
        STOREZ  D0, [#ZP_COUNT]
        CMP     D0, #100
        BNE     LOOP

        HALT    #0

ISR:
        PUSH    D0
        LOADZ   D0, [#SYS_TICKS]    ; Y-independent — works under any task's Y3
        ADD     D0, #1
        STOREZ  D0, [#SYS_TICKS]
        POP     D0
        RTI
```

### 9.9 Best Practices

1. **Reserve $0000-$01FF for the vector table** — TRAP/INT vectors; do not use for variables
2. **Reserve $0200-$03FF for system/runtime use** — OS variables, Forth, Pascal runtime
3. **Allocate application variables from $0400** — keep hot variables at lower addresses within this range
4. **Use `.REGION` / `.RS` for page $00 allocation blocks** — the assembler assigns addresses, so fields can't silently overlap and any collision is a build error (§4.12); reserve `.EQU` for ABI-fixed and externally-baked addresses (vector slots, I/O), values, and struct offsets
5. **Group related variables** — improves code readability
6. **Document variable usage** — Page $00 is a shared resource across all tasks
7. **Use LOADZ/STOREZ for page $00** — Y-independent, 3 cycles vs 6 for indexed load (50% faster), and safe under any task's Y3
8. **Reserve LOADP/STOREP for non-zero pages** — banked memory with an explicit Y register
9. **Never write to Y3 outside k/OS** — it is the per-task page register (Section 9.5, Appendix B.6)
10. **Always specify step size for `INC/DEC XYn`** — bare `INC XYn` is an assembler error; use `INC XYn, #1` (byte) or `INC XYn, #2` (word)

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

### 10.2 Byte Suffix (b)

The 'b' suffix is accepted as an explicit byte-count marker (identity —
no multiplier). Parallel to `w`, it documents intent when the context
is ambiguous about whether a value is bytes or words. Most useful on
`INC XYn` / `DEC XYn` where bare-form is an assembler error and explicit
step size is required:

```asm
INC XY0, #1b            ; +1 byte  (same as #1, with intent marker)
INC XY0, #1w            ; +2 bytes (1 word)
INC XY0, #4b            ; +4 bytes
```

Only applies to plain decimal literals. For hex literals, `b`/`B` is a
digit (value 11), so `#$1B` means 27, not "1 with byte suffix".

### 10.3 Character Literals

Immediate values may be written as character literals. The literal
evaluates to the ASCII code of the character.

```asm
LOADI D0, #'A'          ; D0 = 65
LOADI D0, #'0'          ; D0 = 48
LOADI D0, #' '          ; D0 = 32
```

Escape sequences match those used in `.TEXT` / `.BYTE` string literals:

| Escape | Value | Meaning |
|--------|-------|---------|
| `#'\n'` | 10 | Line feed |
| `#'\r'` | 13 | Carriage return |
| `#'\t'` | 9  | Tab |
| `#'\0'` | 0  | Null |
| `#'\\'` | 92 | Backslash |
| `#'\''` | 39 | Single quote |
| `#'\"'` | 34 | Double quote |
| `#'\xHH'` | 0–255 | Hex byte (2 hex digits) |

```asm
LOADI D0, #'\n'         ; D0 = 10 (LF)
LOADI D0, #'\x41'       ; D0 = 65 ('A')
STOREB D0, [XY1]        ; write to terminal
```

### 10.4 Derivative Operators (24-bit Address Handling)

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
| @ | Region field reference (`REGION@FIELD`, §4.12) | Identifier |

`REGION@FIELD` resolves to the same address as the plain field name; it is an identifier form (§4.12), not an arithmetic operator, and binds before expression evaluation.

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

### 12.6 TRAP Convention — Syscall ABI (Carry-on-Error Return)

TRAP-dispatched syscalls follow V2 argument passing and add a flag-based
return status:

| Register | Role |
|----------|------|
| D0 | Arg 1 / Result or error code |
| D1 | Arg 2 |
| D2 | Arg 3 |
| XY0, XY1 | Pointer args (24-bit) |
| `[X3+4]` onwards | 4th+ word args |
| C flag | Return status: 0 = success, 1 = error |

**Callee-preserved** (handler must restore): D1, D2, D3, XY1, XY2, XY3
**Clobbered** (caller assumes trashed): D0, XY0, flags

The handler must not touch XY2 on any path — it is the Pascal V2 frame
pointer cache and must survive syscalls unchanged.

The TRAP instruction pushes 4 bytes to XY3, so stack-passed arguments (if
any) are at `[X3+4]` on entry to the handler. Handlers exit with `RETCC`
on success or `RETCS` on error — these fold the SR write into the return
atomically, producing SR = $00 (success) or SR = $01 (error). Plain
`RET` is only needed in the rare case that a handler must forward a
specific non-zero Z/N/V value to the caller; RETCC/RETCS force
Z=N=V=0. See §6.11 for the flag-behaviour details.

**Caller pattern:**

```asm
    LOADI   D0, #arg1
    LOADI   D1, #arg2
    TRAP    #9
    BCS     .error          ; C=1 on error
    ; D0 = result, continue...
.error:
    ; D0 = error code
```

**Bad-trap handler:** at boot, the OS should install a default
`bad_trap` handler at every uninitialised vector slot that loads D0
with `ERR_BADCALL` and exits with `RETCS` (setting C=1). Uninitialised
vectors then fail safely instead of jumping into garbage.

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
| Region overlap | A region's explicit start lands inside an already-placed region span |
| Symbol already defined (region) | Field/region name collides with an existing symbol — qualify as `REGION@FIELD` or rename |
| Emitting directive inside region | `.DS`/`.WORD`/`.BYTE`/`.TEXT`/`.INCBIN` used inside an open `.REGION` — use `.RS` |
| Code grown into reserved region | Emitted code/data overlaps a placed region span (§4.12 clobber guard) |
| .SPACE wrong operand count | `.SPACE` given other than exactly one operand |
| .SPACE inside open region | `.SPACE` used before the current `.REGION` is closed with `.ENDREGION` |

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

### 14.3 Region Map

When any `.REGION` blocks are present, the assembler emits a **region map** — a
companion artifact to the listing and symbol table that documents every placed region
and its fields. It has two sections: a region table (name, range, size, field count,
cap) and a fields-by-address listing (`REGION@FIELD`, address, size). Regions are shown
in address order, so gaps between them are visible at a glance.

When the build uses `.SPACE` (§4.13), the map is **filtered to the build's own code
space** and prints a `Space :` header naming it; only regions, fields, and gaps in that
space are listed, so a `.COM`'s map is a true picture of its own page and hides the
kernel regions it borrows only for constants. An untagged build reports `Space : default`
(an internal unfiltered request reports `all`).

```
Space     : default

Regions:
  Region      Start   End     Size  Fields  Cap
  SYSV        $006C   $0072      6       3   $00A0
  WORK        $0072   $0076      4       2   —

Fields (by address):
  Region@Field           Addr    Size  Decimal
  SYSV@SV_TICKS          $006C     $2        2
  SYSV@SV_HEAD           $006E     $2        2
  SYSV@SV_TAIL           $0070     $2        2
  WORK@W_FLAGS           $0072     $2        2
  WORK@W_COUNT           $0074     $2        2
```

The map makes the whole page-`$00` layout auditable in one place and is the artifact
used to verify zero address drift when converting hand-`.EQU`'d blocks to regions.

---

## 15. Quick Reference

### 15.1 Instruction Summary

| Category | Instructions |
|----------|--------------|
| Load | LOADI, LOADD, LOADX, LOADY, LOADB, LOADXY, LOADP, LOADPB, LOADZ, LOADZB, LOADD/LOADB `[XYn]+` (STREAM) |
| Store | STORED, STOREX, STOREY, STOREB, STOREXY, STOREP, STOREPB, STOREZ, STOREZB, STORED/STOREB `[XYn]+` (STREAM) |
| Move | MOVE, SWAP |
| Arithmetic | ADD, ADC, SUB, SBC, NEG, INC, DEC |
| Logical | AND, OR, XOR, NOT |
| Shift/Rotate | SHL, SHR, ASR, ROL, ROR, SWAPB, HIGH, LOW, SHL4, SHR4, ASR4, ASR8, MULB, RECIP, LOOKUP |
| Address | LEA |
| Compare | CMP |
| Conditional Set | SEQ, SNE, SCS, SCC, SMI, SPL, SAL |
| Branch | BEQ, BNE, BCS/BHS, BCC/BLO, BLT, BGT, BGE, BLE, BRA |
| Jump | JMP, JMP24, JMP16, JMPT, JMPXY |
| Subroutine | CALL, CALL24, CALL16, CALLR, CALLXY, TRAP, RET, RETCC, RETCS |
| Stack | PUSH, POP (supports D, X, Y, XY, D123 group, SR, immediate) |
| Flag | SEC, CLC (aliases for `LOADI SR, #$01` / `#$00`) |
| Control | NOP, HALT, DINT, EINT, RTI |

### 15.2 Cycle Count Reference

| Instruction | Mode 00 | Mode 01 | Mode 10 | Mode 11 | Notes |
|-------------|---------|---------|---------|---------|-------|
| **Control ($00)** |
| NOP | 2 | — | — | — | No operation |
| HALT | — | 2 | — | — | Stop processor |
| INC XYn | — | — | 3/5 | — | 24-bit increment (mode 10); 3/5 = no-cross / page-cross; flag-transparent |
| DEC XYn | — | — | — | 4/6 | 24-bit decrement (mode 11); 4/6 = no-cross / page-cross; flag-transparent |
| **LOOKUP ($01)** |
| SHL/SHR/ASR/ROL/ROR | 3 | 3 | 3 | 3 | Mode selects operation |
| SWAPB/HIGH/LOW | 3 | 3 | 3 | 3 | Mode selects operation |
| SHL4/SHR4/ASR4/ASR8 | 3 | 3 | 3 | 3 | Extended shifts |
| MULB/RECIP | 3 | 3 | — | — | Multiply/Reciprocal |
| **STREAM ($02)** |
| LOADD/LOADB `[XYn]+` | 4/6 | 4/6 | — | — | 4/6 = no-cross / page-cross; flag-transparent |
| STORED/STOREB `[XYn]+` | — | — | 5/7 | 5/7 | 5/7 = no-cross / page-cross; flag-transparent |
| **LEA ($03)** |
| LEA | 3 | 4/6 | 5 | 4/6 | copy / +D / PC-rel (page-local) / +imm5; 4/6 = no-cross / page-cross |
| **Conditional ($04)** |
| Scc | 4 | — | — | — | Conditional set |
| **Move ($05)** |
| MOVE | 3 | 3 | — | — | Register to register |
| SWAP | — | — | 4 | 4 | Register exchange |
| **Stack ($06-$07)** |
| PUSH reg | 5 | — | — | — | Single D/X/Y |
| PUSH D123 | — | 11 | — | — | D123 group (D1, D2, D3 — D0 untouched) |
| PUSH XY | — | — | 8 | — | XY pair |
| PUSH #imm | — | — | — | 5 | Immediate (via PUSHI encoding) |
| POP reg | 4 | — | — | — | Single D/X/Y |
| POP D123 | — | 8 | — | — | D123 group (D1, D2, D3 — D0 untouched) |
| POP XY | — | — | 6 | — | XY pair |
| PUSHI | — | — | — | 5 | Push immediate |
| **ALU ($08-$0F)** |
| ADD/ADC | 4 | 4 | 3 | 4 | reg / [XY] / imm5 / imm16 |
| SUB/SBC | 4 | 4 | 4 | 4 | Non-commutative |
| AND/OR/XOR | 4 | 4 | 3 | 4 | Logical ops |
| NOT | 4 | 4 | 4 | 4 | All modes: bitwise complement |
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
| LOADZ/LOADZB | — | — | — | 3 | Page $00 (Y-independent, ZOA) |
| **Store ($19-$1D)** |
| STORED/X/Y | 3 | 4 | 4 | 4 | [XY] / [XY+D] / [PC+imm16] / [XY+imm5] |
| STOREB | 3 | 4 | 4 | 4 | Byte store (same as STORED) |
| STOREI | 2 | 3 | — | — | IMM5 / IMM16 |
| STOREXY | — | — | 6 | — | Store XY pair |
| STOREP | — | — | — | 5 | Paged memory |
| STOREZ/STOREZB | — | — | — | 5 | Page $00 (Y-independent, ZOA) |
| **TRAP/RET/NEG ($1E)** |
| TRAP | 12 | — | — | — | Software syscall |
| NEG | — | 3 | — | — | Two's complement negate (was $00 mode 11) |
| RETCC | — | — | 6 | — | Return + C=0 (success exit)* |
| RETCS | — | — | 6 | — | Return + C=1 (error exit)* |
| RET | — | — | — | 6 | Plain return (+ optional cleanup) |
| **Interrupt ($1F)** |
| DINT | 2 | — | — | — | Disable interrupts |
| EINT | — | 2 | — | — | Enable interrupts |
| RTI | — | — | 8 | — | Return from interrupt |
| INT | — | — | — | 16 | Hardware interrupt |

*RETCC and RETCS live in mode 10 (not mode 11) — listed in the mode-11
column above purely for readability alongside RET.

### 15.3 Flags Affected

| Category | Instructions | C | Z | N | V |
|----------|--------------|---|---|---|---|
| Arithmetic | ADD, ADC, SUB, SBC | ✓ | ✓ | ✓ | ✓ |
| Negate | NEG | ✓ | ✓ | ✓ | ✓ |
| Compare | CMP | ✓ | ✓ | ✓ | ✓ |
| Logical | AND, OR, XOR, NOT | ✓* | ✓ | ✓ | — |
| INC/DEC XY | INC, DEC (XY pairs) | — | — | — | — |
| INC/DEC D/X/Y | (syntax sugar for ADD/SUB) | ✓ | ✓ | ✓ | ✓ |
| LEA | All modes | — | — | — | — |
| LOOKUP | All (SHL, SHR, SWAPB, etc.) | — | — | — | — |
| Move/Load/Store | All | — | — | — | — |
| STREAM `[XYn]+` | LOADD, LOADB, STORED, STOREB | — | — | — | — |
| Branch/Jump | All | — | — | — | — |
| Scc | SEQ, SNE, etc. | — | — | — | — |
| Return + clear C | RETCC | 0 | 0 | 0 | 0 |
| Return + set C | RETCS | 1 | 0 | 0 | 0 |

✓ = Set meaningfully based on result  
✗ = Trashed (undefined/corrupted)  
— = Not affected (preserved)  
0 / 1 = Written to a fixed constant value by the instruction

*Logical ops: C is cleared (not set based on result).

**RETCC writes SR ← $00 (C=0, Z=0, N=0, V=0); RETCS writes SR ← $01
(C=1, Z=0, N=0, V=0).** Behaviourally identical to the legacy
`LOADI SR, #$00 / RET` and `LOADI SR, #$01 / RET` idioms, but folded
into a single instruction. Handlers that must forward a specific
non-zero Z/N/V to the caller (rare) must use plain `RET`.

**SR-writing instructions:**

| Instruction | C | Z | N | V | Notes |
|-------------|---|---|---|---|-------|
| `LOADI SR, #imm5` | w | w | w | w | Low nibble of imm5 directly loaded into flags |
| `SEC` | 1 | 0 | 0 | 0 | Alias for `LOADI SR, #$01` |
| `CLC` | 0 | 0 | 0 | 0 | Alias for `LOADI SR, #$00` |
| `MOVE Dn, SR` | — | — | — | — | Read only; no flag change |
| `PUSH SR, XYn` | — | — | — | — | Read only |
| `POP SR, XYn` | w | w | w | w | Low nibble of popped word loaded to flags |

w = written directly (from immediate or popped value), not derived from a result.

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
| `.INCBIN` | `.INCBIN "filename"` | Insert binary file verbatim as data words |
| `.REGION` | `NAME .REGION [start][,cap]` | Open a non-emitting reservation region (§4.12) |
| `.RS` | `SYMBOL .RS count[w]` | Reserve/name space in the open region; advance count bytes |
| `.ENDREGION` | `.ENDREGION` | Close the open region; define `_START`/`_END`/`_SIZE`/`_CAP` |
| `.SPACE` | `.SPACE name` | Tag following regions + the code space with address space `name` (§4.13) |
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
; Version: 3.8 (21 April 2026)
; Updated for memory map v4:
;   - Reset vector at $FF0000
;   - Stack/ZP at page $00
;   - Video RAM at $B00000 (2MB)
;   - Video mode register at $DD0000
;   - Keyboard at $DE0000
;   - Terminal I/O at $DF0000
;===============================================================

;---------------------------------------------------------------
; Memory Map Constants
;---------------------------------------------------------------
TERMINAL     .EQU        $DF0000             ; Terminal output (byte)

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
- Stack initialization at page $00 (bare-metal: Y3=$00, X3=$FFF0; under k/OS, Y3 is per-task — see §9.5)
- C-style calling convention (parameters pushed right-to-left)
- Callee cleanup with `RET #4w` (8 bytes = 4 parameters)
- Local labels with `.` prefix for scope
- Register preservation (push/pop D2, D3)
- 24-bit address comparison using Y then X registers
- LOOKUP operations (`HIGH`, `SHR4`) for byte/nibble extraction
- Byte-level memory access with `LOADB`/`STOREB`
- Memory-mapped I/O (terminal output via `STOREB D0, [XY1]`)

---

## Appendix B: Common Pitfalls

This appendix documents behaviours that are architecturally correct but counter-intuitive, silent, or likely to cause hard-to-diagnose bugs. Every item here has been encountered in real K16 code.

---

### B.1 `[XY+D]` and `[XY+#imm5]` — Page-Local, Not 24-Bit

**Affected instructions:** All LOAD/STORE mode 01 (`[XY+D]`) and mode 11 (`[XY+#imm5]`)

The effective address is computed as:

```
effective address = Y : (X + offset)    ← 16-bit add only
```

Y is **never modified**. There is no carry from the 16-bit X+offset result into Y (the adder is 16-bit; propagating carry into Y would require an extra microcode step). This means `[XY+D]` and `[XY+#N]` are **page-local**: if X+offset wraps past $FFFF the result stays within the 64KB page defined by Y.

```asm
; XY0 = $01FF80, D0 = $0100
LOADD D1, [XY0+D0]     ; address = $01:(FF80+0100) = $01:$0080 = $010080
                        ; NOT $020080 — no carry into Y
```

**Convention:** keep X well below $FFFF when using indexed addressing. For arrays or structures that might cross a page boundary, manage Y manually.

---

### B.2 ALU Instructions Do Not Accept `[XY+offset]` Source

**Affected instructions:** ADD, ADC, SUB, SBC, AND, OR, XOR, NOT, CMP

The `[XY+D]` and `[XY+#imm5]` offset addressing forms are **only valid for LOAD/STORE instructions**. ALU instructions use different mode encodings:

| Mode | ADD | LOADD |
|------|-----|-------|
| 00 | `ADD dst, src` | `LOADD dst, [XY]` |
| 01 | `ADD dst, [XY]` | `LOADD dst, [XY+D]` |
| 10 | `ADD dst, #imm5` | `LOADD dst, [PC+imm16]` |
| 11 | `ADD dst, #imm16` | `LOADD dst, [XY+#imm5]` |

The assembler rejects `ADD D0, [XY2+#4]` with an error. The correct pattern is a separate load:

```asm
ADD     D0, [XY2+#4]    ; ASSEMBLER ERROR

; Correct:
LOADD   D1, [XY2+#4]
ADD     D0, D1
```

---

### B.3 STORE Operand Order — Register First, Address Second

All STORE instructions place the **source register first** and the **destination address second**:

```asm
STORED  D0, [XY0]       ; correct: D0 → memory[XY0]
STORED  [XY0], D0       ; ASSEMBLER ERROR
```

This applies to `STORED`, `STOREB`, `STOREX`, `STOREY`, `STOREXY`. The order is the opposite of natural English ("store [value] to [address]") and is the most common operand-order mistake. The assembler error message may refer to the address expression being parsed as an invalid source register, which can be confusing.

---

### B.4 `STOREI` — Bare `[XYn]` Only; No Offset Form

`STOREI` supports only bare `[XYn]` addressing. The offset forms `[XYn+D]` and `[XYn+#imm5]` are not available and will be rejected by the assembler:

```asm
STOREI  #$0002, [XY0]   ; OK
STOREI  #0, [XY2+#4]    ; ASSEMBLER ERROR — offset form not available
```

**Workaround:** use `LOADI Dn` + `STORED`:

```asm
LOADI   D0, #0
STORED  D0, [XY2+#4]    ; works for any address form
```

---

### B.5 `INC XYn` / `DEC XYn` — Flag Behaviour (Updated v3.13)

Earlier manual versions (v3.12 and prior) documented `INC XYn` and `DEC XYn`
as trashing all four flags as a side effect of the 24-bit microcode sequence.
This was true on pre-CR-2026-001 hardware.

From v3.13 onwards (FLAGSX hardware change v1.2), opcodes $00–$03 — including
INC/DEC XY — are **flag-transparent**: their internal carry propagation
writes to an internal flag register (SRX) that is invisible to user code,
and user-visible SR is preserved across the instruction. The CMP / INC XY /
Bcc pattern is now safe. See Appendix C.7 for the FLAGSX design note.

**Opcode (v3.17):** `INC`/`DEC XY` were relocated from `$02` to `$00`
mode 10/11 on 9 June 2026, freeing `$02` for the STREAM family. The flag
behaviour above is unchanged; only the encoding moved. See §6.3 for the
current encoding and Appendix B.13 for the STREAM relocation note.

---

### B.6 Y3 — The Current Task Page Register

Y3 is reserved by k/OS as the **current task page** register. Each task
runs with Y3 set to its own 64KB physical page; the scheduler writes Y3
on context switch, and existing Y-banked addressing modes (`[XYn]`,
`[XYn+#imm5]`, `LOADP/STOREP, Y3`) reach the task's local memory through it.

**Rule:** application code must never write to Y3. Only the k/OS
context-switch primitives modify it.

**Page $00 access from any context:** because Y3 is per-task, kernel
data, the vector table, and any structure that must be reachable
during an ISR or syscall must use the **LOADZ/STOREZ** family
(Section 6.1, Section 9.5), which forces the address-bus high byte to
`$00` independent of any Y register. TRAP and INT microcode also use
this ZOA path for vector dispatch.

> **Historical note (≤ v3.9):** earlier manuals fixed Y3 = `$00` at
> reset and used `LOADP/STOREP, Y3` for page $00 access. The
> convention changed in v3.10 with the introduction of ZOA and
> LOADZ/STOREZ.

**Bare-metal / standalone demos:** programs running without k/OS that
choose to keep their stack in page $00 may still set `Y3 = $00` at
startup; this works because k/OS isn't there to demand otherwise.
LOADZ/STOREZ remain preferable for page-$00 access because they
document intent and survive any future migration to k/OS:

```asm
    LOADI   X3, #$FFF0
    LOADI   Y3, #$00    ; bare-metal only — k/OS owns Y3 otherwise
```

---

### B.7 `PUSH D123` / `POP D123` — Callee-Saved D Registers Only

The group push/pop operates on **D1, D2, D3** — the V2 ABI
callee-preserved D registers. D0 is the V2 result/error register and is
deliberately not touched, so `PUSH D123` / `POP D123` is safe in any
handler that returns a value in D0.

**Push order:** D1 to the highest address (written first), D3 to the
lowest (written last). After `PUSH D123, XY3`, X3 points at D3; D1 is at
`[X3+4]`.

**Pop order:** the reverse. D3 is read first from `[X3+0]`, then D2,
then D1. The pair is fully symmetric and correctly restores all three
registers.

If a routine genuinely needs to save D0 as well (e.g. a complex
interrupt handler that clobbers D0 before saving it), use four
individual `PUSH D0..D3` instructions — there is no group form that
includes D0.

**Migration from pre-v3.12 code:** the legacy `PUSH D` / `POP D`
(operating on D0-D3) has been removed. Sites that genuinely relied on
saving D0 across the call must be rewritten with individual pushes;
sites that didn't care about D0 (the overwhelming majority) just swap
the mnemonic.

See Section 6.12 for the encoding and full memory layout, and Section
12.6 for the syscall ABI.

---

### B.8 `JMPT` — Fetches Target from Memory

`JMPT XYn, Dm` is an **indexed indirect jump** — it reads the jump target *from memory*, it does not jump to XYn directly. The operation is:

```
EA  = Xn + Dm           (16-bit add, page-local — see B.1)
PC  = Yn : mem[Yn:EA]
```

Both operands are required. Dm must be a **word offset** (index × 2) into the dispatch table. See Section 6.9 for full details and an example.

---

### B.9 `MOVE Yn, Dn` / `MOVE Dn, Yn` — 8-Bit Truncation

Y registers are 8-bit. `MOVE Yn, Dn` silently discards the high byte of Dn. `MOVE Dn, Yn` zero-extends Y to 16 bits.

```asm
LOADI   D0, #$FFA5
MOVE    Y0, D0          ; Y0 = $A5  — high byte $FF silently discarded

LOADI   Y0, #$A5
MOVE    D0, Y0          ; D0 = $00A5  — zero-extended
```

The same truncation applies to `LOADI Yn, #value` with a value that does not fit in 8 bits; the high byte is silently dropped.

**Never write to Y3** — see B.6.

---

### B.10 SR Write Ordering in Handlers (Withdrawn)

Earlier manual versions (v3.6 through v3.11) documented a pitfall in
which any flag-affecting instruction between `LOADI SR` (or `SEC` /
`CLC`) and `RET` would trash the carry value just set up for the
syscall return. The pitfall was real for handlers using the legacy
`LOADI SR / RET` exit idiom.

From v3.12 onward, handlers should exit via `RETCC` (success) or
`RETCS` (error) — see Section 6.11. These instructions fold the SR
write into the return atomically, so no intervening instruction can
corrupt the exit flags. The ordering rule no longer applies to new
code. Maintainers of pre-v3.12 code can find the original guidance in
the manual's git history.

---

### B.11 RETRACTED — `SHL4 / SHL4` Does Pack a Byte into the High Half

> **This appendix was wrong from its introduction in v3.13 (26 May 2026)
> until its retraction here (8 August 2026). It is kept rather than
> deleted so that code commented "per B.11" can be traced.**

**The claim.** B.11 asserted that `SHL4 / SHL4` "silently corrupts any
byte > `$0F`", and gave `$00FF` → `$F000` as the worked example.

**The measurement.** `SHL4` is exactly what §15.1 says it is:
`Dn ← Dn << 4`, a full 16-bit nibble shift with no byte-width
truncation. Run on EMU, 8 August 2026:

```
$00FF SHL4        = $0FF0      single shift, as documented
$00FF SHL4 SHL4   = $FF00      NOT $F000 — nothing is lost
$000F SHL4 SHL4   = $0F00
$0010 SHL4 SHL4   = $1000      no corruption above $0F
$FF00 SHR4        = $0FF0
$FF00 SHR4 SHR4   = $00FF      unpack direction equally clean
$00FF SWAPB       = $FF00      reference
```

The reasoning in the original entry — "the first `SHL4` has already
moved bits into nibble 2 and the second shifts them out the top" —
describes a shift that discards above nibble 2. Nothing in the hardware
does that; the LOOKUP shift is 16-bit throughout.

**How it survived.** §2.10 of `kOS_Gotchas` has documented
`SHL Dn, #15 → SHL4 / SHL4 / SHL4 / SHL × 3` since v1.19, and the
assembler emits that expansion for every multi-bit shift in the tree.
That decomposition is only correct if `SHL4` is a true nibble shift, so
the contradiction was in daily use and load-bearing for months. Neither
document referenced the other.

**What still stands.** `SWAPB Dn` remains the better way to shift a
clean low byte into the high half — **one instruction instead of two**,
and it reads as intent rather than as arithmetic. That is an efficiency
and clarity argument, not a correctness one. Both forms produce the same
result, and `SWAPB` additionally requires the high byte to be zero,
where `SHL4 / SHL4` does not care (it shifts the high nibbles out
legitimately).

If the high byte may be non-zero and you want a true `<< 8`, mask first:
`LOW Dn` (or `AND Dn, #$FF`), then `SWAPB Dn`.

**Lesson.** A wrong gotcha is worse than a missing one: it makes correct
code look suspect, and a reader who finds two sections of the same
manual contradicting each other has no way to tell which to believe.
Entries asserting a hardware behaviour should carry the measurement that
established it. `SHL4Test.asm` is retained for this one.

**The original entry follows, for reference only. Do not act on it.**

```asm
; WRONG — fails for any byte > $0F
        LOADI   D0, #$0042
        SHL4    D0              ; D0 = $0420
        SHL4    D0              ; D0 = $4200 ← bit 6 of original shifted out the top
                                ;        for $0042 this happens to be correct,
                                ;        but $00FF would become $F000 (not $FF00)

; CORRECT — one instruction
        LOADI   D0, #$0042
        SWAPB   D0              ; D0 = $4200

; CORRECT when high byte may be non-zero
        LOADI   D0, #$AB42
        LOW     D0              ; D0 = $0042 (mask down to byte)
        SWAPB   D0              ; D0 = $4200
```

See also §7.2 (Byte Manipulation via LOOKUP) for the full byte-packing
idiom set.

---

### B.12 `LEA XYn, label` (Mode 10) is Page-Local

**`LEA XYn, label` only works when `label` is in the same 64KB page as
the LEA instruction itself.** The Y register receives the LEA's own
PC page byte, regardless of whether the displacement crosses a page
boundary. The assembler emits a warning when a cross-page Mode 10
reference is detected.

The X register is computed as `(PC + offset) AND $FFFF` — a 16-bit
add with carry discarded. So within a page, both forward and backward
references work correctly. Across a page boundary, the X register
gets the right offset but the Y register gets the wrong page.

```asm
        .ORG    $030000             ; assume code at page $03
MAIN:
        LEA     XY0, MSG_LOCAL      ; ✓ same page — XY0 = $03:0010
        LEA     XY1, MSG_BACK       ; ✓ same page (backward) — XY1 = $03:0008
        LEA     XY2, MSG_FAR        ; ✗ different page — assembler warns;
                                    ;     Y2 ← $03 (LEA's page), not $04
        HALT    #$00

MSG_BACK:    .TEXT "back\0"

        .ORG    $030010
MSG_LOCAL:   .TEXT "local\0"

        .ORG    $040000
MSG_FAR:     .TEXT "far\0"
```

For a cross-page address, build the XY pair explicitly:

```asm
; Under k/OS — Y3 holds the running task's page byte
        LOADI   X0, #<TARGET
        MOVE    Y0, Y3                  ; current task's page

; Bare-metal — page known at assembly time
        LOADI   X0, #<TARGET
        LOADI   Y0, #>TARGET
```

**Why page-local?** The full 24-bit `LEA XYn, label` needs to add a
sign-extended 16-bit displacement to the 24-bit PC, propagating
borrow into the page byte for backward references that don't cross
a page (`PCH` stays) and forward references that do (`PCH + 1`),
plus the symmetric backward-cross cases. The microcode through v3.14
implemented only the forward-overflow half of this (`$0000 + PCH +
carry`), so every backward reference incorrectly produced `PCH + 1`.
The proper fix requires either a hardware path for sign-extending
T16 onto ALU-A or a multi-step latch-and-decode sequence; neither
fits cleanly in the current 5-cycle Mode 10 budget. Page-locality
is the simpler invariant, matches how BRANCH already works, and
is correct for every existing Mode 10 LEA in the codebase.

See also §6.2 Mode 10, Gotchas #34.

### B.13 STREAM `[XYn]+` — Post-Increment Load/Store Pitfalls

The `$02` STREAM family (§6.1) fuses access + pointer advance. Five things
catch people out:

- **Loads are flag-transparent.** `LOADB D0, [XYn]+ / BEQ` is wrong — the
  load never touches user `SR`. Insert `CMP D0, #0` before any conditional
  branch on the loaded value.
- **Word stride must be even.** `LOADD`/`STORED [XYn]+, #odd` is an assembler
  error; word access stays aligned. The default word stride is 2; byte
  stride is 1.
- **`[XYn]+` takes no offset.** Post-increment cannot combine with
  `[XYn+Dm]` or `[XYn+#imm5]` — not encodable.
- **Stride ceiling is 31** (IMM5). For a larger step, follow with a separate
  `INC XYn, #n` or use multiple advances.
- **Bare `[XYn]` ≠ `[XYn]+`.** Without the `+`, LOAD/STORE use the
  non-advancing `$14`/`$19` encodings. The `+` is the only thing that
  selects the `$02` STREAM opcode.

**Relocation note:** `INC`/`DEC XY` now live at `$00` mode 10/11, not `$02`.
Any hand-assembled or disassembled code that referenced the old `$02`
INC/DEC encoding must be updated; `$02` is now the STREAM family.

---

## Appendix C: Design Notes

This appendix collects design rationales that don't fit in a reference
but matter when extending K16, porting software, or understanding why
the architecture looks the way it does. These notes are discursive,
not normative — for definitive behaviour see Section 6 and Appendix B.

---

### C.1 Why ROM-Based Lookup Tables?

The K16 ALU is a pair of ROMs indexed by {opcode, mode, A operand, B
operand}. Every arithmetic and logical result, flag output, and shift
variant is precomputed at ROM-build time.

This choice was driven by two goals. First, TTL-level simplicity: a
lookup replaces dozens of gates with one addressable memory. The 93-chip
total for the whole CPU is only possible because the ALU is a ROM.
Second, extensibility: adding a new single-operand operation (a new
LOOKUP function, for example) means regenerating the ROM image, not
rewiring the board. MULB, RECIP, and the SHL4/SHR4 extended shifts were
all added this way with no hardware changes.

The trade-off is that every ALU op pays the ROM access time — nominally
one cycle at 70 ns — and that 2-operand ops require two ROM passes
(high nibble, low nibble) for 16-bit results. The K16 absorbs this as
3-4 cycle ALU timing, acceptable at 10 MHz.

The FPGA port (Tang Console 138K) implements the ALU as a combinational
`case` statement rather than instantiating block RAM. The semantics are
identical; only the physical realisation differs.

---

### C.2 Why 6502-Style Carry?

The K16 carry convention (Section 6.3) matches the 6502/65816: carry is
*cleared* on subtract borrow, *set* on add overflow. This is opposite
to x86/Z80/ARM, which clear carry on "no borrow".

Two reasons:

1. **Multi-word subtract chains are simpler without an extra NOT.** On
   6502 convention, `SUB` followed by `SBC` just works: the SBC reads
   `~C` as the borrow-in, and "no borrow from SUB" means `C=1` means
   `~C=0` means "don't subtract anything extra". On x86 convention, a
   `CMC` or equivalent is needed between the operations.

2. **Historical precedent for small machines.** The 6502 carry semantics
   are the dominant convention in Section 8- and 16-bit hobbyist / retrocomputer
   ecosystems (6502, 6800, 65816, MSP430). Programmers coming from those
   environments get the expected behaviour for free.

The cost is programmers coming from x86 or Z80 writing bugs on their
first K16 subtract. Appendix B's explicit multi-word examples and the
Section 6.3 Carry Convention subsection exist to warn about this.

---

### C.3 Why XY2 Is the Pascal Frame Pointer

The K16 V2 ABI (12) pins XY2 as the Pascal frame-pointer cache. It is
callee-preserved: every non-trivial Pascal procedure and every syscall
handler must leave XY2 unchanged.

This matters because Pascal procedures use XY2 to access locals and
parameters via `[XY2+#N]` indexed addressing (Section 5.6). If XY2 is clobbered
mid-procedure, every subsequent local access references garbage.
Pinning XY2 for this role — rather than, say, computing it from XY3 on
each access — saves 2-3 cycles per variable reference and makes generated
Pascal code notably tighter.

The trade-off is one fewer general-purpose XY register for hand-written
assembly. K16 has four XY pairs (XY0-XY3); with XY3 as SP and XY2 as
FP, only XY0 and XY1 remain free. This was judged acceptable because
most ALU ops accept `[XY+D]` and `[XY+#imm5]` addressing, so a single
XY can serve many array or struct accesses without needing a second
pointer register.

Forth (Section 12.7) uses a completely different register convention and does
not observe this pinning — Forth code and Pascal code cannot share a
stack frame.

---

### C.4 Why TRAP Doesn't Push SR (But INT Does)

TRAP (Section 6.11) is a synchronous syscall dispatch. The program calling a
TRAP is making a deliberate transition into a handler and expects a
defined return protocol — specifically, the carry-on-error ABI (Section 12.6).
Pushing and popping SR around the TRAP would obliterate the handler's
ability to return status in C.

INT (Section 6.14) is an asynchronous hardware interrupt. The interrupted
program made no decision to transition and must not have its flags
disturbed by the interruption. Push/pop of SR around the ISR is
mandatory.

The result is two instructions that look superficially similar (both
vector through a handler table in page $00) but have opposite semantic
contracts. RET pairs with TRAP; RTI pairs with INT. Mixing them breaks
things quickly.

---

### C.5 Why Page $00 Is Special

The first 64KB of address space holds the vector table and the
shared kernel data structures referenced from any task context.
There is no hardware distinction between page $00 and any other page;
its specialness is purely conventional.

The convention rests on two mechanisms working together:

1. **ZOA microcode dispatch.** Both TRAP (opcode `$1E` mode `00`) and
   INT (opcode `$1F` mode `11`) fetch their handler vector via the
   ZOA AB sub-write, which forces the address-bus high byte to `$00`
   regardless of any Y register. Vectors live at fixed physical
   addresses `$00:0000–$00:01FC`.

2. **LOADZ/STOREZ for software access.** Kernel data on page $00
   (system tick counter, OS variables, ISR-shared state) is read and
   written with the LOADZ/STOREZ family, which uses the same ZOA
   path. This works correctly even when Y3 holds the current task
   page rather than `$00`.

This decoupling is what makes preemptive multitasking practical on
the K16. An ISR can preempt any task, fire the dispatcher through a
fixed vector, and update kernel counters — none of which depend on
the interrupted task's Y3. Y3 itself is reserved as the **current
task page** (Sections 9.5, B.6), so per-task data falls naturally out
of the existing Y-banked addressing modes without any special-cased
"OS register".

> **Historical note:** ≤ v3.9 used `LOADP/STOREP, Y3` for page $00
> access and required Y3 = `$00` at all times. ZOA and LOADZ/STOREZ
> (v3.10) replace that convention with one that supports task-private
> Y3 values.

---

### C.6 Why No Byte-Wide ALU Operations

The K16 ALU is 16-bit only. ADD, SUB, AND, etc. operate on full words.
Byte operations are confined to:

- **LOADB / STOREB** — memory access, zero-extending loads, low-byte
  stores
- **LOOKUP patterns** — SWAPB, HIGH, LOW for byte-within-word moves
- **MULB** — the one explicitly byte-wide arithmetic op, producing a
  16-bit result from 8×8 multiply

No native `ADDB` or `ANDB` exists. Byte arithmetic is done with word
ops plus a mask:

```asm
        AND     D0, #$00FF      ; mask to low byte
        ADD     D0, D1          ; add (result may exceed byte)
        AND     D0, #$00FF      ; re-mask if byte truncation needed
```

The design reason is cost: a second ALU path for byte ops would roughly
double the ALU ROM size and add a byte/word mode bit to every
instruction encoding. MULB is the single exception because 8×8 multiply
is small enough to fit in the existing ROM as a special LOOKUP variant.

---

### C.7 FLAGSX — Internal Flag Register for Opcodes $00–$03

Introduced in CR-2026-001 v1.2 (25 May 2026).

Opcodes $00–$03 (IR[15:13] = 000) write their flag side effects to an
internal register **SRX** rather than the user-visible **SR**. This
protects SR across LOOKUP, INC/DEC XY, and LEA execution, allowing
these instructions to be placed freely in flag-sensitive sequences
without spilling SR.

The decode is one combinational signal:

```
FLAGSX = NOR(IR[15], IR[14], IR[13])
```

When FLAGSX = 1, the executing opcode is $00, $01, $02, or $03 and any
FLAGSLoad assertion writes SRX. When FLAGSX = 0, the executing opcode is
$04 or higher and FLAGSLoad writes SR as before. The flag bus is gated
symmetrically: opcode $00–$03 instructions reading flags see SRX;
opcode $04+ instructions see SR.

This allows the existing microcode for LOOKUP, INC/DEC XY, and LEA to
keep using `FLAGSLoad := true` for internal carry propagation between
microcode steps of the same instruction — the carry chain still
functions correctly because the producer step writes SRX and the
consumer step (within the same instruction, FLAGSX still 1) reads SRX.

The mechanism is fully transparent to assembly programmers: SRX is not
addressable, cannot be read or written by any instruction, and exists
solely as a private carry-propagation register for opcode $00–$03
microcode.

**Architectural invariant:** no future instruction added at opcode $00,
$01, $02, or $03 can write user-visible flags. Any genuinely
flag-affecting operation must live at opcode $04 or higher. NEG was
relocated from $00 mode 11 to $1E mode 01 for this reason. Modes 10
and 11 of opcode $00 now hold the flag-transparent `INC XYn` / `DEC XYn`
(relocated from $02 on 9 June 2026 to free $02 for the STREAM family);
any further additions there must likewise be flag-transparent.

**Hardware implementation:** two 74LS173 registers (SR and SRX, replacing
the original single 74LS574), gated-clock topology using a 74LS10 NAND3
and a 74LS27 NOR3 for the FLAGSX decode and inversion. +2 chips net.
See the CR-2026-001 v1.2 specification document §5 for the schematic
details.

---

### C.8 Mode-Agnostic Carry-Skip Gate

The 24-bit `XY` pointer advance used by `INC`/`DEC XY` (`$00` m10/m11) and
the STREAM family (`$02`) terminates early on the common no-wrap path. The
gate that detects "no further carry to propagate" reads **CarryMode** off
the ALU ROM output — not an instruction-register bit — so it is independent
of where the operation sits in the opcode/mode space.

```
~uReset = NAND( uReset , NAND(FLAGSX, CarryMode1, x) )
x       = XOR( CarryMode0 , FlagCARRY )
```

- `CarryMode1 = 1` marks a carry-skip arm step (a firewall against all other
  `uReset` terminals).
- `CarryMode0` selects direction: `0` = skip-on-no-carry (increment),
  `1` = skip-on-no-borrow (decrement).
- The increment family emits `cmCarrySkipADD` (CM = `10`); the decrement
  family emits `cmCarrySkipSUB` (CM = `11`).

Because the gate keys on CarryMode rather than `IR9`, relocating `INC`/`DEC`
from `$02` to `$00` and adding the STREAM advances at `$02` required **no**
change to the skip logic. Net hardware cost over the pre-existing `INC`/`DEC`
gate is **zero**: the `74x86` XOR input moved from `IR9` to `CarryMode0`,
and the mask NAND dropped from 4 inputs to 3.

---

*Further design notes may be added here as they arise.*

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
| 3.4 | 17 April 2026 | Added NOT mode 11 (immediate `#imm16`) to section 6.4; updated cycle count table to show all 4 NOT modes as 4 cycles; added `NOT dst, [XYn]` example to section 6.4; added Appendix B (Common Pitfalls): page-local indexed addressing, ALU offset restriction, STORE operand order, STOREI no-offset restriction, INC/DEC XY flag corruption, Y3 convention, PUSH D group behaviour, JMPT indirect semantics, MOVE Y truncation; added inline callouts to LOADB (table index masking, register aliasing), STORED (operand order), STOREI (offset restriction), JMPT (indirect semantics), PUSH D (group order), LOOKUP/MULB (packing patterns) |
| 3.5 | 17 April 2026 | Bare `INC XYn` / `DEC XYn` now documented as assembler errors (explicit step required); updated INC/DEC tables, examples, warning block, and programming tips accordingly |
| 3.6 | 20 April 2026 | Clarified 6502-style carry convention for SUB/SBC/CMP (§3.3 and new §6.3 subsection): C=1 = no borrow, C=0 = borrow, opposite of x86; added multi-word subtract and compare examples. Added LOADI SR destination (§6.1): direct 4-bit flag write via IMM5, SR is 4-bit writable / 16-bit readable (8-bit value zero-extended); added flag-transparency note to TRAP/RET (§6.11): syscall carry-on-error ABI explained; added SEC/CLC aliases (§6.14): Level-2 syntactic sugar for the two most common LOADI SR patterns; updated §15.1 instruction summary and §15.3 flags-affected table; expanded §12.6 TRAP Convention into full syscall ABI (carry-on-error return, callee-preserved register list, bad-trap handler recommendation); added Appendix B.10 (SR write ordering in handlers); all SR paths (LOADI SR, MOVE Dn SR, PUSH SR, POP SR, SEC, CLC) verified end-to-end on both Digital and the Pascal emulator. |
| 3.7 | 20 April 2026 | Added §1.5 (A Note on Cycle Counts): CPU clock cycles, 10 MHz target, deterministic execution, INT/wait-state exceptions. Added §6.0 (Instruction Set at a Glance): one-screen index of all 32 opcodes with category and section links, plus Level-2 alias table (SEC/CLC/BHS/BLO/INC/DEC). Terminology pass: "FLAGS register" / "CPU flags" → "SR flags" throughout; "Zero Page" → "Page $00" in §9 heading and body, with historical note retaining the old name in revision history; memory-map entry for $00_0000 updated. Added Appendix C (Design Notes): six rationales covering ROM-based ALU, 6502-style carry, XY2 as Pascal FP, TRAP-vs-INT SR handling, Page $00 conventions, and no byte-wide ALU. |
| 3.8 | 21 April 2026 | Memory map v4: reorganised I/O region for minimal hardware decode. Video RAM relocated to `$B0_0000-$CF_FFFF` (2MB, fits 1920×1080×8bpp). I/O compacted into 64KB slots at top of `$Dx_xxxx`: video mode register at `$DD_0000`, keyboard at `$DE_0000`, terminal at `$DF_0000`. `$D0_0000-$D7_FFFF` reserved (no CS); `$D8_0000-$DC_FFFF` reserved for future I/O expansion (timer, IRQ, SPI, SD). Hardware: one 74LS138 sub-decoder on `MEM-D0-CS` using the `G`/`~GA` enable cascade (A19 on active-high `G`) to decode 64KB slots in the upper 512KB; one OR gate combining `MEM-B0-CS` + `MEM-C0-CS` for video RAM. Updated §1.2 memory map table and I/O addresses, Appendix A sample program header and `TERMINAL` constant, inline terminal-write comment. |
| 3.9 | 22 April 2026 | **I/O:** Added Video Page register at `$DC_0000` (word, write-only): selects the 64KB page that is the current framebuffer base. Value is the high 16 bits of FB_BASE (i.e. `FB_BASE = value << 16`). Default `$00B0` preserves prior fixed-base behaviour. Enables double-buffered video by allocating two non-overlapping framebuffer regions and flipping Video Page between them. Writes set FrameDirty; no byte access, no reserved bits. I/O expansion range in §1.2 memory map narrowed to `$D8_0000-$DB_FFFF` (4×64KB) to reflect the new slot allocation. Emulator implemented; hardware (Tang Console / TTL) requires write-latched register feeding the video DMA address counter high bits — not yet implemented. **Assembler syntax:** §10.2 added — `b` byte suffix on immediates (identity; parallel to `w`; most useful on `INC/DEC XYn` for intent clarity). §10.3 added — character literals `#'X'` with full escape vocabulary (`\n \r \t \0 \\ \' \" \xHH`) matching `.TEXT` / `.BYTE` strings. Former §10.2 Derivative Operators renumbered to §10.4. |
| 3.10 | 28 April 2026 | **Y3 reserved as the current task page** for k/OS preemptive multitasking (§9.5, B.6, C.5). **ZOA AB sub-write** (`ABWriter=ORAB, ABSubWrite=11`) added: forces address-bus high byte to `$00` independent of any Y register. Decouples kernel data and vector dispatch from the running task's Y3. **TRAP (opcode `$1E` mode `00`) and INT (opcode `$1F` mode `11`) microcode** updated to use ZOA on the two vector-fetch steps; cycle counts unchanged (TRAP=12, INT=16). **Vector table relocated** to fixed physical address `$00:0000–$00:01FC`; handler bodies may live anywhere in 24-bit space. **New instructions:** LOADZ, LOADZB, STOREZ, STOREZB — opcode `$18`/`$1D` mode `11` with IR bit 4 (ZOA flag) = 1; same cycle counts as LOADP/STOREP family (LOADZ=3, STOREZ=5). Two-operand syntax (no Y register field). Section 9 (Page $00 Programming) rewritten: §9.4 now uses LOADZ/STOREZ; new §9.5 documents Y3-as-task-page convention; subsections renumbered (old 9.6→9.7, 9.7→9.8, 9.8→9.9). Appendix B.6 rewritten as "Y3 — The Current Task Page Register"; Appendix C.5 rewritten to explain ZOA-based page $00 specialness. Opcode summary tables (§1.3, §6.0, §15.1, §15.2) and example dispatchers updated. |
| 3.11 | 15 May 2026 | **New instructions:** `RETCC` and `RETCS` added to opcode $1E (mode 10, discriminated by IR[8:7]). RETCC writes SR ← $00 (C=0, Z=0, N=0, V=0); RETCS writes SR ← $01 (C=1, Z=0, N=0, V=0) — both behaviourally equivalent to the legacy `LOADI SR,#imm / RET` idiom but folded into one instruction. Both 6 cycles, 1 word, support optional `#nw` cleanup operand identical to RET. Mode 01 in opcode $1E reserved as a spare slot; IR[8]=1 within mode 10 also reserved (two-bit selector leaves room for two future variants — reserved patterns fall through to RETCC behaviour via microcode `else` clause). Section 6.11 renamed "TRAP and RET-family Instructions"; new "RETCC / RETCS Encoding" subsection added with full encoding table. "Flag Transparency of TRAP and RET" subsection renamed "Flag Behaviour of TRAP and the RET Family" and rewritten. Syscall convention chapter (§12.6) updated: canonical handler exit is now `RETCC` / `RETCS`; the legacy `LOADI SR / RET` idiom remains supported and produces identical SR state. Bad-trap handler recommendation updated to use RETCS. Example handler in §6.11 updated. Quick-reference tables (§15.1 instruction summary, §15.2 cycle counts, §15.3 flags affected) updated. **Erratum corrected:** RET cycle count was misdocumented as 5 in v3.10 and earlier; actual hardware behaviour is 1 fetch + 5 execution = 6 cycles, unchanged. All three RET-family instructions are now correctly shown as 6 cycles. |
| 3.12 | 16 May 2026 | **Breaking:** `PUSH D` / `POP D` (all four D registers, D0-D3) **removed**. Opcode $06/$07 mode 01 reassigned to `PUSH D123` / `POP D123` — pushes/pops D1, D2, D3 only (the V2 ABI callee-preserved D registers); D0 is deliberately not touched, making the group instructions safe in any handler that returns a value in D0. Cycle counts: `PUSH D123` = 11 (was 14 for `PUSH D`); `POP D123` = 8 (was 10 for `POP D`). Push order: D1 → highest address (written first), D3 → lowest (written last); pop order reversed. Assembler rejects legacy `PUSH D` / `POP D` with a hard error pointing at the new mnemonic. If D0 needs saving (e.g. complex interrupt handlers), use four individual `PUSH D0..D3` instructions — there is no group form that includes D0. Section 6.12 mode table, push/pop-order diagrams, and asm examples updated. Appendix B.7 rewritten as "PUSH D123 / POP D123 — Callee-Saved D Registers Only" with migration guidance. Quick-reference tables (§15.1, §15.2) updated. Latent destination-register bug in old `Generate_POP_Group_D` microcode (DBRead per `xy_sel` override that silently corrupted POP D into stacks other than XY3) eliminated by the rewrite — see microcode appendix in the v3.12 update document for details. Audit item flagged: `Generate_POP_XY_Pair` step 1 not yet reviewed for the same pattern. |
| 3.13 | 26 May 2026 | **CR-2026-001 v1.2 (FLAGSX).** NEG relocated from opcode $00 mode 11 to $1E mode 01: at $00, NEG's flag writes would have been suppressed by the FLAGSX hardware (which routes opcode $00–$03 flag-bus writes to the internal SRX register), breaking the arithmetic contract. Source-level mnemonic unchanged; new base word $F200 (was $0600); operand fields IR[8:0] preserved bit-for-bit. §6.3 NEG subsection updated with new opcode/mode/encoding; §6.11 RET-family table gains NEG row at mode 01; §6.13 control table loses NEG rows; opcode-map and at-a-glance tables (§1.3, §6.0) updated; cycle count table (§15.2) moves NEG row from $00 to $1E. **Flag-transparency rewrite.** §15.3 INC/DEC XY changes from `✗ ✗ ✗ ✗` to `— — — —`; new LEA row at `— — — —`; LOOKUP row stays `— — — —` (now accurate). "⚠ WARNING: INC/DEC XY Trashes Flags" block removed from §6.3; closing-paragraph warning removed from §15.3. §6.3 INC and DEC subsections' "XY version trashes all flags" claim corrected to flag-transparent. Appendix B.5 amended to point at FLAGSX. New Appendix C.7 documenting the FLAGSX architectural invariant. **SRX register documented.** §1.1 architecture summary "Status flags" row mentions SRX; §3.1 Register Overview rewritten as two tables (programmer-visible / internal architectural state) — the internal table covers T8, T8-5, T16, ORDB, ORAB, and SRX, all flagged not programmer-addressable; §3.3 Status Register gains a trailing "Internal flag register SRX" paragraph cross-referencing C.7. Also: §6.5 ROL/ROR descriptions corrected to pure rotates (bit out wraps directly to bit in, no carry involvement) — long-standing manual error inherited from 6502-family conventions, not a behaviour change. §6.3 carry-convention table loses the spurious SHL/SHR/ROL/ROR row that contradicted §15.3 — LOOKUP-family is flag-transparent. §6.11 RET-family mode table updated to show full SR post-state (`SR ← $00` / `SR ← $01`) instead of just the C bit. **New Appendix B.11** documenting the `SHL4 / SHL4` byte-packing pitfall — `SWAPB` is the correct one-instruction `<< 8`; the two-shift idiom silently corrupts any byte > `$0F` because the first `SHL4` already moves bits into nibble 2. Cross-reference added from §7.2. |
| 3.14 | 26 May 2026 | **New §6.15 Pseudo-Instructions.** Five assembler-level pseudo-instructions documented: `BHI` (branch if higher unsigned strict, expands to `BEQ.S .__skip / BHS target`), `BLS` (branch if lower-or-same unsigned, expands to `BEQ target / BLO target`), and the multi-bit shifts `SHL Dn, #n` / `SHR Dn, #n` / `ASR Dn, #n` (count 0–16, assembler picks the shortest native sequence drawing from `SHL`, `SHL4`, `SHR`, `SHR4`, `ASR`, `ASR4`, `ASR8`, `LOW`, `HIGH`, `SWAPB`, and `LOADI #0`). Full decomposition tables, cycle/word costs, listing format, and error/warning matrix included. §6.15.9 documents an AND+ROL/ROR optimisation hint for `SHL/SHR Dn, #14` and `#15` where flag-clobber is acceptable — saves up to 12c/4w on the worst case. `__`-prefixed identifiers are now reserved for assembler-generated synthetic labels (e.g. `.__bhi_0` from BHI expansion); user labels matching this pattern are rejected. **No hardware change**, no new opcodes consumed. §6.0 Level-2 alias table extended (heading renamed "Assembler-level aliases and pseudo-instructions") with five new rows; §6.5 gains a multi-bit-shift cross-reference to §6.15; §6.8 gains a pseudo-branch cross-reference to §6.15. The pre-existing §6.3 32-bit multi-word compare example, which already used `BHI` informally, is now formally backed by the §6.15.1 specification. |
| 3.15 | 27 May 2026 | **LEA Mode 10 (PC-relative to label) is now page-local.** The previous 24-bit cross-page form was broken on Digital for negative displacements: Step 4 of the microcode added `$0000 + PCH + carry → Yn` which only handled forward overflow (`+1`), never backward underflow (`-1`). Every backward label reference (the dominant case in `.COM` programs whose code follows their string tables) silently produced `PCH + 1` instead of `PCH`, putting the address in the wrong page. The proper 24-bit fix requires sign-extension of the 16-bit displacement onto ALU-A; the current ALU bus constants (`$0000, $0002, $FFFE, $FFFF`) cannot drive this cheaply without new hardware. **Decision: make Mode 10 page-local**, matching how BRANCH already works. New microcode (`ALU_Opcode_x03_LEA.pas` Step 4): `PCH → Yn` directly via AB-Hi → DB, no ALU involvement. **Mode 10 drops from 5 to 4 microcode steps; documented cycle count drops from 6 to 5.** §6.2 LEA intro paragraph updated to note Mode 10's page-locality; §6.2 Mode 10 subsection rewritten with full history note and cross-page idioms (`LOADI X / MOVE Y, Y3` under k/OS, `LOADI X / LOADI Y` bare-metal); §15.2 cycle table updated. **Assembler warning added** (`K16_Encoder_LEA.pas`): `LEA XYn, label` with `(label_addr >> 16) ≠ (lea_addr >> 16)` emits a warning identifying the cross-page reference and the workaround. **Gotchas #34** new — "LEA Mode 10 is page-local". Every existing Mode 10 LEA in the codebase (kernel, kosh, BASIC, Forth — all within-page) works correctly under the new microcode. |
| 3.16 | 29 May 2026 | **New directive `.INCBIN` (§4.11).** Inserts a binary file verbatim as data words at the point of the directive — for embedding pre-assembled `.COM` images, lookup tables, font data, or any pre-built blob. Path resolution identical to `.INCLUDE` (relative to the containing file's directory, absolute pass-through). Bytes packed little-endian (first byte → low byte of first word), matching the K16 memory model and `.TEXT` ordering. Even-length files required; odd length is a clean error. Must be word-aligned (use `.ALIGN 2` if preceding `.BYTE` data left an odd count). Directive summary table updated. No hardware change. |
| 3.17 | 9 June 2026 | Added `$02` STREAM post-increment load/store family (`LOADD`/`LOADB`/`STORED`/`STOREB [XYn]+`); relocated `INC`/`DEC XY` to `$00` m10/m11; documented mode-agnostic carry-skip gate. New §6.1 STREAM subsection (syntax, stride rules, encoding, timing, flag-transparency, string-copy idiom); §6.3 INC/DEC opcode updated from $02 to $00 m10/m11 with new encodings (`$0406`/`$0606`); opcode map (§1.3) and at-a-glance (§6.0) updated; cycle table (§15.2) gains STREAM group and moves INC/DEC into the $00 group; flags table (§15.3) and instruction summary (§15.1) gain STREAM rows; new Appendix B.13 (STREAM pitfalls + relocation note); new Appendix C.8 (mode-agnostic carry-skip gate); Appendix B.5 and C.7 amended for the relocation. Verified 9 June 2026 on both run targets (Digital silicon + K16EmuIDE). |
| 3.18 | 11 June 2026 | **LEA timing optimised; Modes 00/01/11 microcode revised (`ALU_Opcode_x03_LEA.pas`).** Mode 00 (copy) reduced 5→3 cycles: the prior microcode cloned Mode 11's add-with-carry chain to add an always-zero imm5; replaced with a straight dual copy (`Xm→Xn`, `Ym→Yn`), no ALU/ORDB/flag write (strictly more flag-transparent). Modes 01 and 11 fitted with the shared carry-skip gate, 5→4 cycles on the no-page-cross path / 6 on cross. Because LEA's destination differs from its source (unlike in-place INC/DEC), the sequence copies `Ym→Yn` first and arms the skip on the X-writeback, so the no-carry path terminates with `Yn` already correct; the carry path runs `$0000+Ym+carry→Yn`. Both modes are forward-only by construction (imm5 unsigned; Do zero-extended) — only the ADD skip arm is used, no borrow arm. Mode 10 unchanged (page-local, 5 cycles). All cycle counts include the instruction fetch (step 0). §6.2 rewritten: cycle column updated (00=3, 01/11=4/6, 10=5), new "Direction and Page Safety" and "Timing and Carry-Skip" subsections, LEA-vs-INC/DEC table corrected; §15.2 LEA cycle row updated to match. **Hardware note:** bring-up of the carry-skip Y-propagation at arm-position 3 (5-step ops) surfaced a wiring fault on the gate that suppressed the carry/borrow into Y for `DEC XY` borrow, `INC XY` wrap, and LEA Mode 01/11 page-cross; corrected in the Digital schematic. No opcode or encoding change. Verified 11 June 2026 on both run targets (Digital silicon + K16EmuIDE) via `test_lea_all` (17 sub-tests, all modes + both carry paths + INC/DEC carry-path controls). |
| 3.19 | 9 July 2026 | Added the `.REGION` / `.RS` / `.ENDREGION` region-reservation system (new §4.12): the assembler assigns page-`$00` (or any RAM) addresses, making intra-region overlap structurally impossible and turning any symbol redefinition — region-vs-region or region-vs-`.EQU` — into a build error. Non-emitting (never advances the emit PC); explicit start required on the first region, auto-chain off the previous `_END` thereafter; optional exclusive `cap`; auto-defined `_START`/`_END`/`_SIZE`/`_CAP`; `@` field scoping (`REGION@FIELD`); strict collision, overlap (explicit-start, cross-file), no-emit-inside-region, and code-grown-into-region clobber guards. Added `@` region-field reference to §11.1; §9.9 best-practice #4 now recommends `.REGION`/`.RS` for page-`$00` allocation blocks with `.EQU` reserved for ABI-fixed/externally-baked addresses; four region errors added to §13.2; new §14.3 (Region Map output); three region rows added to the §15.4 directive summary. Assembler implementation: new `K16_Regions.pas` state machine + map builder; `.EQU` with a bare-symbol RHS now routes through the expression evaluator (enables `_END .EQU REGION_END` compat aliases). No hardware, opcode, or encoding change. Also folded in documentation corrections surfaced during the WebEMU opcode-reference build (`K16_ISA_Doc_Corrections.md`): §6.11 "Mode 01 in opcode $1E is unassigned" corrected — mode 01 holds `NEG` (FLAGSX relocation); §6.12 / §1.3 / §6.0 PUSH/POP tables corrected — `PUSH #imm` moved from $06 mode 11 to its actual home at $07 mode 11 (PUSHI), and $06 mode 11 documented as PUSH of a single X/Y/ORDB/SR/PCH/PCL register (cycle counts were already correct). Corresponding `K16 CPU ISA etc.xlsx` fixes tracked separately (spreadsheet-only; not part of this manual pass). |
| 3.20 | 11 July 2026 | Added the `.SPACE` directive (new §4.13) — per-binary address-space tagging. A build produces one binary image occupying one physical page; `.SPACE name` names that page and stamps every following `.REGION` — and, pinned at `.ORG`, the emitted code — with that space. The §4.12 region-overlap and code-in-region clobber guards are now **same-space only**, so a source file may `.INCLUDE` another purely for its `.EQU` constants without the borrowed regions false-colliding against emitted code that reuses the same numeric addresses in its own page. Directive-first (like `.ORG`), sticky until the next `.SPACE`, case-insensitive, rejected inside an open region; untagged builds default to space `default` and behave identically to pre-`.SPACE` (fully backward compatible). §4.12 overlap/clobber wording updated for per-space scoping; §14.3 region map now space-filtered with a `Space :` header (build's own code space; per-space gaps); two `.SPACE` errors added to §13.2; `.SPACE` row added to the §15.4 directive summary. Assembler implementation: `K16_Regions.pas` gains per-span space stamping + same-space guard/map filtering; `K16_Assembler.pas` gains `FCodeSpace` (pinned at `.ORG`) + the `.SPACE` directive; also fixes the INCBIN merge from O(n²) to O(n log n). No hardware, opcode, or encoding change. |
| 3.21 | 8 August 2026 | **Appendix B.11 retracted — the `SHL4 / SHL4` corruption claim was false.** B.11 (added v3.13) asserted that packing a byte into the high half with two `SHL4`s "silently corrupts any byte > `$0F`", with `$00FF` → `$F000` as the worked example. Measured on EMU 8 August 2026: `$00FF SHL4 SHL4 = $FF00`, `$0010 SHL4 SHL4 = $1000`, `$FF00 SHR4 SHR4 = $00FF`. `SHL4` is exactly the 16-bit nibble shift §15.1 documents, in both directions, with no truncation. The appendix is **kept and marked RETRACTED** rather than deleted, so code commented "per B.11" can be traced; the original text is retained beneath the retraction. The two cross-references (§6.5 quote block, §7.2 pitfall note) are reworded from a correctness warning to a preference: `SWAPB` is still the better choice for a clean low byte, on size and clarity grounds — one instruction rather than two — but both forms are correct. Note the contradiction was load-bearing and visible: `kOS_Gotchas` §2.10 has documented `SHL Dn, #15 → SHL4 / SHL4 / SHL4 / SHL × 3` since v1.19, an expansion that is only valid if `SHL4` is a true nibble shift, and the assembler emits it for every multi-bit shift in the tree. Evidence retained as `SHL4Test.asm`. **§4.5 gains a `.TEXT` padding warning.** The word-alignment pad emitted after an odd-length `.TEXT` is a `$00`, which terminates a string: one logical string split across several `.TEXT` directives is silently truncated at the first odd-length chunk, with no diagnostic. Documents the single-directive and `.BYTE` alternatives (`.BYTE` advances by exact byte count and never pads, §4.6 — which is why `kosh_help.asm` uses it for multi-line help text). |

---

*— End of Document —*
