# K16 CPU

A 16-bit discrete logic CPU with 24-bit addressing, built from approximately 60 TTL chips and 6 ROMs.

## Overview

The K16 is a homebrew CPU designed around ROM-based lookup tables for both ALU operations and instruction decoding. Rather than using traditional hardwired logic, the K16 leverages high-density flash ROMs to implement complex functionality while keeping the chip count reasonable.

**Key Specifications:**
- 16-bit data bus
- 24-bit address bus (16MB flat memory space)
- Hybrid ROM/Adder ALU architecture
- 8-level priority interrupt system (74LS148 encoder)
- Target clock speed: 5-10 MHz

## Architecture Highlights

### Hybrid ROM-Based ALU

The ALU uses 4× SST39SF040 flash ROMs (512KB each) split into nibble-wide slices. Each ROM receives:
- 4-bit ALU-A input (data bus)
- 4-bit ALU-B input (registers or PC)
- 7-bit instruction opcode
- 4-bit microcode step counter

ROM outputs feed into 4× 74x283 TTL adders for carry propagation. This hybrid approach gives the speed benefits of hardware addition while allowing arbitrary ALU functions through ROM programming—essentially a 4-bit ALU can perform any 4-input/4-output function by simply reprogramming the lookup table.

### Register Set

| Registers | Width | Description |
|-----------|-------|-------------|
| D0-D3 | 16-bit | Data registers |
| X0-X3 | 16-bit | Index registers (low address) |
| Y0-Y3 | 8-bit | Page registers (high address) |
| XY0-XY3 | 24-bit | Combined index pairs |
| PC | 24-bit | Program counter |
| SP | 24-bit | Stack pointer (XY3) |

### Memory Map

| Range | Size | Description |
|-------|------|-------------|
| $00_0000 - $0F_FFFF | 1MB | Program ROM |
| $10_0000 - $1F_FFFF | 1MB | Lookup Table ROM |
| $20_0000 - $7F_FFFF | 6MB | RAM |
| $FF_0000 - $FF_FFFF | 64KB | Memory-Mapped I/O |

### Lookup Tables

The K16 extends the ROM-based philosophy to complex operations via dedicated lookup table memory. Operations like shifts, rotates, byte swaps, and multiplication use 64K-word lookup tables accessed in 4 cycles:

```asm
SHL D0          ; Shift left via lookup (4 cycles)
MULB D1         ; 8×8 multiply via lookup
RECIP D2        ; Reciprocal approximation
```

The ALU calculates the table address (D+D for word alignment), with the carry bit selecting odd/even pages. This achieves fast complex operations without dedicated shifter or multiplier hardware.

### Interrupts

Eight priority-encoded interrupt levels (IRQ0-IRQ7) using a 74LS148 priority encoder:
- Automatic PC and Status Register save to stack
- 15-cycle interrupt entry, 7-cycle return
- Interrupt level captured in saved SR bits 6:4
- Nested interrupt support via separate flag register banks

```asm
EINT            ; Enable interrupts
DINT            ; Disable interrupts
RTI             ; Return from interrupt (restores PC + flags)
```

### Stack Operations

Four independent 24-bit stack pointers (XY0-XY3) with flexible push/pop:

```asm
PUSH D0, XY3        ; Push single register
PUSH D, XY3         ; Push all data registers (D0-D3)
PUSH XY2, XY3       ; Push 24-bit address pair
POP D, XY3          ; Pop all data registers
```

## Instruction Set

| Category | Instructions |
|----------|--------------|
| Load | LOADI, LOADD, LOADX, LOADY, LOADB, LOADXY, LOADP, LOADPB |
| Store | STORED, STOREX, STOREY, STOREB, STOREXY, STOREP, STOREPB |
| Move | MOVE, SWAP |
| Arithmetic | ADD, ADC, SUB, SBC, INC, DEC |
| Logical | AND, OR, XOR, NOT |
| Shift/Rotate | SHL, SHR, ASR, ROL, ROR, SWAPB, HIGH, LOW, SHL4, SHR4, ASR4, ASR8, MULB, RECIP, LOOKUP |
| Address | LEA (24-bit effective address calculation) |
| Compare | CMP |
| Conditional Set | SEQ, SNE, SCS, SCC, SMI, SPL, SAL (branchless conditionals) |
| Branch | BEQ, BNE, BCS/BHS, BCC/BLO, BLT, BGT, BGE, BLE, BRA |
| Jump | JMP, JMP24, JMP16, JMPT, JMPXY |
| Subroutine | CALL, CALL24, CALL16, CALLR, RET |
| Stack | PUSH, POP (supports D, X, Y, XY, D group, immediate) |
| Control | NOP, HALT, DINT, EINT, RTI |

### Cycle Counts

| Instruction | Cycles | Notes |
|-------------|--------|-------|
| NOP/HALT | 2 | Control |
| LOADI | 2 | Immediate |
| LOADD/X/Y | 2-4 | Depends on addressing mode |
| STORED/X/Y | 3-4 | Depends on addressing mode |
| ADD/SUB/AND/OR/XOR | 3-4 | ALU operations |
| CMP | 3 | All modes |
| SHL/SHR/ROL/ROR | 3 | Lookup table operations |
| MULB/RECIP | 3 | Lookup-based multiply/reciprocal |
| LEA | 5-6 | 24-bit address calculation |
| Scc | 4 | Conditional set |
| Bcc | 3-4 | Short/long branch |
| JMP | 2-4 | Various modes |
| CALL | 11-12 | Subroutine call |
| RET | 5 | Return |
| PUSH/POP | 4-14 | Single to group operations |
| INT | 15 | Interrupt entry |
| RTI | 7 | Interrupt return |

## Design Philosophy

The K16 prioritizes:
1. **Minimal chip count** (~40 TTL + 6 ROMs) without sacrificing capability
2. **Flexibility** via ROM-based microcode—personality changes without rewiring
3. **Modern amenities** like 24-bit addressing and priority interrupts
4. **Practical performance** targeting the 68000 class

## Forth Support

K/OS Forth is a complete Forth implementation running natively on the K16:
- Indirect Threaded Code (ITC) interpreter
- 17-cycle inner interpreter with sentinel-based execution
- 86+ built-in words
- Uses XY1 as IP, XY2 as data stack, XY3 as return stack
- MULB-based fast multiplication

```forth
: SQUARE DUP * ;
: CUBE DUP SQUARE * ;
10 CUBE .    \ prints 1000
```

## Current Status

- Hardware design validated in Digital simulator
- Microcode generator and assembler implemented in Pascal/Delphi
- K/OS Forth interpreter complete with 86 words
- Documentation and test suites in active development

## License

This project is open source. See LICENSE for details.
