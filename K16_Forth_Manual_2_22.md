# K/OS Forth v2.22 Manual

**Version:** 2.22  
**Date:** January 2026  
**Platform:** K16 CPU Architecture

---

## Overview

K/OS Forth is a complete Forth implementation for the K16 CPU architecture, featuring:
- 24-bit address space (16MB)
- Indirect Threaded Code (ITC) interpreter
- 105 built-in words
- Optimized inner interpreter (17 cycles) with sentinel-based execution
- Zero page variables for fast access (3 cycles vs 7 cycles)
- MULB-based fast multiplication
- Full signed comparison branch set (BLT, BGT, BGE, BLE)
- Interrupt support with EINT/DINT/TICKS words
- Automatic RAM detection at startup

### Startup

On power-up or reset, K/OS Forth displays:

```
K/OS - Forth v2.22
Page 00 Memory Map
Interrupts Disabled
RAM: 128KB
> 
```

The system:
1. Disables interrupts (DINT)
2. Initializes stacks and zero page variables
3. Sets up interrupt vector at $000000
4. Detects installed RAM (tests pages $01-$BF)
5. Displays banner and RAM size
6. Enters the interpreter loop (QUIT)

Use `EINT` to enable interrupts if timer functionality is needed.

---

## Architecture

### CPU Registers

The K16 CPU has four 24-bit register pairs (XY0-XY3), each consisting of:
- **Xn** - 16-bit offset register
- **Yn** - 8-bit page register

Forth uses these registers as follows:

| Register | Purpose |
|----------|---------|
| XY0 | Scratch / CFA carrier from NEXT |
| XY1 | IP (Instruction Pointer) - points to next thread cell |
| XY2 | Data Stack Pointer (DSP) - grows downward |
| XY3 | Return Stack Pointer (RSP) - grows downward, Y3=$00 enables zero page |

**Important:** XY1 (IP) must be preserved by all primitives except those that legitimately manipulate the instruction pointer (DOCOL, EXIT, LIT, BRANCH, etc.).

### Memory Map

```
Page $00: RAM (Zero Page / Stack segment)
  $00:0000 - Interrupt vector (4 bytes)
  $00:0100 - Zero page variables (Forth system)
  $00:0800 - TIB (Terminal Input Buffer, 128 bytes)
  $00:0880 - Word parse buffer (128 bytes)
  $00:EFFE - Return stack top (grows downward, ~56K)
  $00:FFFE - Data stack top (grows downward, ~4K)

Page $01+: RAM (User area)
  $01:0000 - User dictionary area (grows upward)

Page $C0: I/O
  $C0:0000 - Keyboard input

Page $D0: I/O
  $D0:0000 - Terminal output

Page $E0-$FB: Lookup tables (ROM)

Page $FC-$FE: Program ROM

Page $FF: Boot ROM
  $FF:0000 - Reset vector, Forth kernel, built-in dictionary
```

### Zero Page Variables

System variables are accessed via `LOADP/STOREP` with Y3, saving 4 cycles per access.

| Offset | Name | Description |
|--------|------|-------------|
| $0000 | INT_VECTOR | Interrupt vector (24-bit: Y at $0000, X at $0002) |
| $0100 | ZP_LATEST | Dictionary head (24-bit: Y at $0100, X at $0102) |
| $0104 | ZP_HERE | Next free byte (24-bit: Y at $0104, X at $0106) |
| $0108 | ZP_STATE | 0 = interpreting, 1 = compiling |
| $010A | ZP_TOIN | Current parse position in TIB (>IN) |
| $010C | ZP_NUMTIB | Number of characters in TIB (#TIB) |
| $010E | ZP_BASE | Number base (default 10) |
| $0110 | ZP_SAVED_LATEST | Error recovery (24-bit) |
| $0116 | ZP_DUMPPAGE | Memory page for DUMP/FILL/CMOVE |
| $0118 | ZP_EXEC_RET | Interpreter return address |
| $011A | ZP_TICKS | System tick counter (60Hz, IRQ7) |
| $0120 | ZP_CALL_BUF | Call buffer (8 bytes) |

---

## Threading Model

K/OS Forth uses **Indirect Threaded Code (ITC)**:

```
Thread:     [CFA1][CFA2][CFA3]...
             |
             v
CFA1:       [code_addr]  (2 bytes)
             |
             v
Code:       actual machine code
```

Each thread cell is 4 bytes: `[Y page : X offset]` pointing to a CFA.

### NEXT - Inner Interpreter (17 cycles)

```asm
NEXT:   LOADXY  XY0, [XY1]      ; 6 cycles - Load CFA from IP
        INC     XY1, #4         ; 5 cycles - IP += 4
        LOADD   D0, [XY0]       ; 3 cycles - Dereference CFA
        MOVE    PC, D0          ; 3 cycles - Jump (XY0 preserved)
```

### Sentinel-Based Execution

When the interpreter executes a word, it builds a mini-thread:

```
ZP_CALL_BUF:  [word-CFA][STOP-CFA]
                    ^
                    IP starts here
```

The STOP word returns control to the interpreter without needing a per-NEXT flag check.

### DOCOL - Enter Colon Definition

```asm
DOCOL:  PUSH    XY1, XY3        ; Save IP to return stack
        LEA     XY1, XY0+#2     ; IP = CFA + 2 (body)
        BRA     NEXT
```

### EXIT - Leave Colon Definition

```asm
EXIT:   POP     XY1, XY3        ; Restore IP from return stack
        BRA     NEXT
```

---

## Dictionary Structure

Each dictionary entry has the format:

```
+0: Link Y    (page of previous entry, 2 bytes)
+2: Link X    (offset of previous entry, 2 bytes)
+4: Flags/Len (1 byte flags + length)
    Bit 6 ($40): IMMEDIATE flag
    Bits 0-5: Name length (1-63)
+6: Name      (variable length, padded to word boundary)
+N: CFA       (Code Field Address, 2 bytes)
+N+2: Body    (for colon definitions, parameter field)
```

---

## Word Reference

### Stack Manipulation

| Word | Stack Effect | Description |
|------|--------------|-------------|
| `DUP` | ( x -- x x ) | Duplicate top of stack |
| `DROP` | ( x -- ) | Discard top of stack |
| `SWAP` | ( x y -- y x ) | Exchange top two items |
| `OVER` | ( x y -- x y x ) | Copy second item to top |
| `ROT` | ( x y z -- y z x ) | Rotate third item to top |
| `-ROT` | ( x y z -- z x y ) | Reverse rotate |
| `NIP` | ( x y -- y ) | Drop second item |
| `TUCK` | ( x y -- y x y ) | Copy top below second |
| `?DUP` | ( x -- x x \| 0 ) | Duplicate if non-zero |
| `2DUP` | ( x y -- x y x y ) | Duplicate pair |
| `2DROP` | ( x y -- ) | Drop pair |
| `2SWAP` | ( a b c d -- c d a b ) | Swap pairs |
| `2OVER` | ( a b c d -- a b c d a b ) | Copy second pair |
| `PICK` | ( xn..x0 n -- xn..x0 xn ) | Copy nth item (0 = top) |
| `DEPTH` | ( -- n ) | Number of items on stack |
| `>R` | ( x -- ) R:( -- x ) | Move to return stack |
| `R>` | ( -- x ) R:( x -- ) | Move from return stack |
| `R@` | ( -- x ) R:( x -- x ) | Copy from return stack |

### Arithmetic

| Word | Stack Effect | Description |
|------|--------------|-------------|
| `+` | ( n1 n2 -- sum ) | Addition |
| `-` | ( n1 n2 -- diff ) | Subtraction (n1 - n2) |
| `*` | ( n1 n2 -- prod ) | Multiplication (MULB-based, ~50 cycles) |
| `/` | ( n1 n2 -- quot ) | Signed division |
| `MOD` | ( n1 n2 -- rem ) | Signed modulo (remainder sign matches dividend) |
| `/MOD` | ( n1 n2 -- rem quot ) | Division with remainder |
| `1+` | ( n -- n+1 ) | Increment |
| `1-` | ( n -- n-1 ) | Decrement |
| `2*` | ( n -- n*2 ) | Double (arithmetic shift left) |
| `2/` | ( n -- n/2 ) | Halve (arithmetic shift right) |
| `NEGATE` | ( n -- -n ) | Two's complement negation |
| `ABS` | ( n -- \|n\| ) | Absolute value |
| `MIN` | ( n1 n2 -- min ) | Signed minimum |
| `MAX` | ( n1 n2 -- max ) | Signed maximum |
| `+!` | ( n addr -- ) | Add n to value at addr |

### Logic

| Word | Stack Effect | Description |
|------|--------------|-------------|
| `AND` | ( n1 n2 -- n ) | Bitwise AND |
| `OR` | ( n1 n2 -- n ) | Bitwise OR |
| `XOR` | ( n1 n2 -- n ) | Bitwise XOR |
| `INVERT` | ( n -- ~n ) | Bitwise NOT (one's complement) |

### Comparison

All comparison words return a flag: TRUE = $FFFF (-1), FALSE = $0000

| Word | Stack Effect | Description |
|------|--------------|-------------|
| `=` | ( n1 n2 -- flag ) | Equal |
| `<>` | ( n1 n2 -- flag ) | Not equal |
| `<` | ( n1 n2 -- flag ) | Less than (signed) |
| `>` | ( n1 n2 -- flag ) | Greater than (signed) |
| `<=` | ( n1 n2 -- flag ) | Less than or equal (signed) |
| `>=` | ( n1 n2 -- flag ) | Greater than or equal (signed) |
| `0=` | ( n -- flag ) | Equal to zero |
| `0<` | ( n -- flag ) | Less than zero (negative) |
| `0>` | ( n -- flag ) | Greater than zero (positive) |
| `U<` | ( u1 u2 -- flag ) | Less than (unsigned) |
| `U>` | ( u1 u2 -- flag ) | Greater than (unsigned) |

### Memory Access

| Word | Stack Effect | Description |
|------|--------------|-------------|
| `@` | ( addr -- n ) | Fetch 16-bit value from RAM page |
| `!` | ( n addr -- ) | Store 16-bit value to RAM page |
| `C@` | ( addr -- c ) | Fetch byte from RAM page |
| `C!` | ( c addr -- ) | Store byte to RAM page |
| `+!` | ( n addr -- ) | Add n to value at addr |
| `HERE` | ( -- addr ) | Next free dictionary address |
| `ALLOT` | ( n -- ) | Reserve n bytes in dictionary |
| `,` | ( n -- ) | Compile 16-bit value to dictionary |
| `C,` | ( c -- ) | Compile byte to dictionary |

**Note:** Memory words `@`, `!`, `C@`, `C!` operate on RAM page (default $00 for zero page, $01+ for user data). Use `DUMPPAGE` to set the page for `DUMP`, `FILL`, and `CMOVE`.

### Input/Output

| Word | Stack Effect | Description |
|------|--------------|-------------|
| `EMIT` | ( c -- ) | Output character |
| `KEY` | ( -- c ) | Wait for and read keypress |
| `CR` | ( -- ) | Output newline ($0A) |
| `SPACE` | ( -- ) | Output single space |
| `SPACES` | ( n -- ) | Output n spaces |
| `.` | ( n -- ) | Print signed number + space |
| `.S` | ( -- ) | Print stack non-destructively |
| `."` | Compile: `." text"` | Print string (compile-only, immediate) |
| `TYPE` | ( addr n -- ) | Print n characters from addr |
| `WORDS` | ( -- ) | List dictionary (80-col wrapped) |
| `PAGE` | ( -- ) | Clear screen (ANSI standard) |
| `CLS` | ( -- ) | Clear screen (alias) |

### Interrupts

| Word | Stack Effect | Description |
|------|--------------|-------------|
| `EINT` | ( -- ) | Enable interrupts |
| `DINT` | ( -- ) | Disable interrupts |
| `TICKS` | ( -- n ) | Get system tick counter (60Hz) |

**Note:** Interrupts are disabled by default at startup. Use `EINT` to enable the timer interrupt (IRQ7) which increments TICKS at 60Hz.

### Number Base

| Word | Stack Effect | Description |
|------|--------------|-------------|
| `HEX` | ( -- ) | Set BASE to 16 |
| `DECIMAL` | ( -- ) | Set BASE to 10 |

Numbers can use `$` prefix for hex regardless of BASE:
```forth
$BEEF .    \ prints 48879 in decimal mode
$FF .      \ prints 255
```

Negative numbers use `-` prefix:
```forth
-5 .       \ prints -5
```

### Control Flow

#### Conditionals

```forth
: test ( n -- )
    0= IF
        ." zero"
    ELSE
        ." non-zero"
    THEN ;
```

| Word | Compile-time | Description |
|------|--------------|-------------|
| `IF` | ( -- addr ) | Begin conditional, consume flag at runtime |
| `ELSE` | ( addr1 -- addr2 ) | Optional false branch |
| `THEN` | ( addr -- ) | End conditional |

#### Definite Loops (DO...LOOP)

```forth
: countdown ( -- )
    10 0 DO
        I .
    LOOP ;
\ prints: 0 1 2 3 4 5 6 7 8 9

: by-twos ( -- )
    10 0 DO
        I .
    2 +LOOP ;
\ prints: 0 2 4 6 8
```

| Word | Stack Effect | Description |
|------|--------------|-------------|
| `DO` | ( limit start -- ) | Begin counted loop |
| `LOOP` | ( -- ) | Increment index, test against limit |
| `+LOOP` | ( n -- ) | Add n to index, test against limit |
| `I` | ( -- n ) | Current loop index |
| `J` | ( -- n ) | Outer loop index (nested loops) |

Loop runs while index < limit. Index and limit are on return stack.

#### Indefinite Loops

```forth
: countdown ( n -- )
    BEGIN
        DUP . 1-
        DUP 0=
    UNTIL DROP ;

: while-demo ( n -- )
    BEGIN
        DUP
    WHILE
        DUP . 1-
    REPEAT DROP ;

: forever ( -- )
    BEGIN
        ." Loop "
    AGAIN ;           \ infinite loop
```

| Word | Description |
|------|-------------|
| `BEGIN` | Mark loop start |
| `UNTIL` | ( flag -- ) Loop back to BEGIN if flag is false |
| `AGAIN` | Unconditional loop back to BEGIN |
| `WHILE` | ( flag -- ) If false, exit to after REPEAT |
| `REPEAT` | Unconditional branch back to BEGIN |

### Defining Words

#### Colon Definitions

```forth
: square ( n -- n^2 ) DUP * ;
: cube ( n -- n^3 ) DUP square * ;

5 square .    \ prints 25
3 cube .      \ prints 27
```

| Word | Description |
|------|-------------|
| `:` | Begin colon definition, parse name |
| `;` | End definition (immediate) |
| `RECURSE` | Compile recursive call to current word (immediate) |

**Multi-line definitions** are supported. The `ok` prompt is suppressed while compiling:

```forth
> : factorial ( n -- n! )
>   DUP 1 > IF
>     DUP 1- RECURSE *
>   THEN ;
 ok
> 5 factorial .
120  ok
```

#### Variables

```forth
VARIABLE counter
0 counter !           \ initialize to 0
counter @ .           \ read: prints 0
counter @ 1+ counter ! \ increment
5 counter +!          \ add 5 to counter
counter @ .           \ prints 6
```

| Word | Stack Effect | Description |
|------|--------------|-------------|
| `VARIABLE` | ( -- ) | Create variable, parse name |
| *name* | ( -- addr ) | Push address of variable |

#### Constants

```forth
42 CONSTANT answer
answer .              \ prints 42
```

| Word | Stack Effect | Description |
|------|--------------|-------------|
| `CONSTANT` | ( n -- ) | Create constant with value n |
| *name* | ( -- n ) | Push value of constant |

#### Dictionary Management

| Word | Stack Effect | Description |
|------|--------------|-------------|
| `FORGET` | ( -- ) | Remove word and all after it |

### Compiler and Interpreter Control

| Word | Stack Effect | Description |
|------|--------------|-------------|
| `[` | ( -- ) | Switch to interpret mode (immediate) |
| `]` | ( -- ) | Switch to compile mode |
| `LITERAL` | ( n -- ) | Compile n as literal (immediate) |
| `'` | ( -- cfa ) | Get CFA of next word (tick) |
| `[']` | ( -- ) | Compile CFA as literal (immediate) |
| `EXECUTE` | ( cfa -- ) | Execute word at CFA |

#### Compile-time Evaluation

Use `[` and `]` with `LITERAL` to compute values at compile time:

```forth
: circle-area ( r -- area )
    DUP *                    \ r^2
    [ 314 100 / ] LITERAL    \ compile 3 (integer pi approximation)
    * ;
```

#### Getting and Using CFAs

```forth
' DUP .                      \ prints CFA of DUP
' DUP EXECUTE                \ same as calling DUP

: apply ( n cfa -- result )
    EXECUTE ;
5 ' DUP apply . .            \ prints 5 5

: use-dup ( n -- n n )
    ['] DUP EXECUTE ;        \ compiles CFA of DUP
```

### Comments

```forth
( This is a stack comment )
\ This is a line comment

: documented ( n -- n*2 )   \ doubles a number
    2* ;                    ( using shift )
```

| Word | Description |
|------|-------------|
| `(` | Begin comment, ends at `)` (immediate) |
| `\` | Comment to end of line (immediate) |

### Memory Tools / Monitor Commands

```forth
HEX
$20 DUMPPAGE !           \ Set memory page to RAM ($20)
$8000 80 DUMP            \ Hex dump 128 bytes at $20:8000
$100 ?                   \ Quick peek at $20:0100 (ZP area)
$1000 100 $FF FILL       \ Fill 256 bytes with $FF
$1000 $2000 80 CMOVE     \ Copy 128 bytes
0 DUMPPAGE !             \ Set to ROM page for viewing code
0 80 DUMP                \ Dump ROM
```

| Word | Stack Effect | Description |
|------|--------------|-------------|
| `DUMPPAGE` | ( -- addr ) | Variable: page for memory commands |
| `DUMP` | ( addr n -- ) | Hex dump n bytes |
| `?` | ( addr -- ) | Display 16-bit value at address |
| `FILL` | ( addr n byte -- ) | Fill n bytes with value |
| `CMOVE` | ( src dst n -- ) | Copy n bytes from src to dst |

DUMP output format (16 bytes per line, with ASCII):
```
20:8000  48 45 4C 4C 4F 00 00 00  00 00 00 00 00 00 00 00  HELLO...........
```

---

## Examples

### Factorial (Iterative)

```forth
: factorial ( n -- n! )
    1 SWAP          \ accumulator under n
    1+ 1 DO
        I *
    LOOP ;

5 factorial .       \ prints 120
10 factorial .      \ prints 3628800
```

### Factorial (Recursive)

```forth
: fact ( n -- n! )
    DUP 1 > IF
        DUP 1- RECURSE *
    THEN ;

5 fact .            \ prints 120
```

### Fibonacci

```forth
: fib ( n -- fib[n] )
    0 1 ROT 0 DO
        TUCK +
    LOOP DROP ;

10 fib .            \ prints 55
20 fib .            \ prints 6765
```

### Division Examples

```forth
: div-test ( -- )
    ." 10 / 3 = " 10 3 / . CR
    ." 10 MOD 3 = " 10 3 MOD . CR
    ." -10 / 3 = " -10 3 / . CR
    ." -10 MOD 3 = " -10 3 MOD . CR ;

div-test
```
Output:
```
10 / 3 = 3
10 MOD 3 = 1
-10 / 3 = -3
-10 MOD 3 = -1
```

### Compile-time Computation

```forth
: seconds-per-day ( -- n )
    [ 24 60 * 60 * ] LITERAL ;  \ computes 86400 at compile time

seconds-per-day .     \ prints 86400
```

### Using EXECUTE for Dispatch

```forth
: double ( n -- n*2 ) 2* ;
: triple ( n -- n*3 ) DUP 2* + ;

: apply ( n cfa -- result ) EXECUTE ;

10 ' double apply .   \ prints 20
10 ' triple apply .   \ prints 30
```

### Stack Printer

```forth
: .stack ( -- )
    DEPTH ?DUP IF
        0 DO
            DEPTH I - 1- PICK .
        LOOP
    THEN ;

1 2 3 .stack        \ prints 1 2 3
```

Or just use the built-in `.S`:
```forth
1 2 3 .S            \ prints <3> 1 2 3
```

### Memory Fill Pattern

```forth
: pattern ( addr n -- )
    0 DO
        I $FF AND OVER I + C!
    LOOP DROP ;

HEX
1 DUMPPAGE !           \ Set to page $01 (user RAM)
$0000 100 pattern
$0000 100 DUMP
```

### Star Pattern

```forth
: stars ( n -- )
    0 DO
        42 EMIT
    LOOP ;

: triangle ( n -- )
    1+ 1 DO
        I stars CR
    LOOP ;

5 triangle
```
Output:
```
*
**
***
****
*****
```

### Multiplication Test

```forth
: mul-test ( -- )
    ." 6 * 7 = " 6 7 * . CR
    ." 100 * 100 = " 100 100 * . CR
    ." -5 * 3 = " -5 3 * . CR ;

mul-test
```
Output:
```
6 * 7 = 42
100 * 100 = 10000
-5 * 3 = -15
```

---

## Error Handling

- **Unknown word:** Prints `?` and aborts the line
- **Compile error:** Restores LATEST and HERE (partial definition cleanup)
- **Stack underflow:** No runtime checking; may show garbage values
- **Division by zero:** Returns 0

On error, the system returns to the interpreter prompt `>`.

---

## Implementation Notes

### ISA Optimizations

K/OS Forth v2.22 uses several K16 ISA features:

| Feature | Benefit |
|---------|---------|
| `MOVE PC, D0` | Direct jump for NEXT inner loop |
| `LOADP/STOREP Dn, Y3, [#imm]` | Zero page access: 7 → 3 cycles |
| `STOREXY` | 24-bit pointer store: 6 → 2 instructions |
| `LEA XY, XY+#imm` | 24-bit pointer arithmetic |
| `INC XY, #imm` | 24-bit increment with page crossing |
| `MULB` | 8×16→24 bit multiply for fast `*` |
| Full signed branches | BLT, BGT, BGE, BLE for clean comparisons |
| Conditional set | SEQ, SLT, etc. for branchless comparisons |

### Zero Page Variables

System variables use Y3=$00 as implicit page register:

```asm
; Old method (7 cycles, burns Y0)
LOADI   Y0, #$00
LOADP   D0, Y0, [#$0108]

; New method (3 cycles, Y0 free)
LOADP   D0, Y3, [#ZP_STATE]
```

This saves 4 cycles per variable access across 112 accesses in the interpreter.

### Multiplication Implementation

The `*` word uses MULB-based 16×16→16 multiplication via partial products:

```
Result = (AL × BL) + ((AH × BL) << 8) + ((AL × BH) << 8)
```

This achieves ~50 cycles vs ~200+ cycles for shift-and-add.

### Division Implementation

Division uses repeated subtraction with proper sign handling:

```forth
-10 3 /     \ returns -3
10 -3 /     \ returns -3  
-10 -3 /    \ returns 3
```

MOD returns remainder with same sign as dividend (Forth standard).

### Number Printing

The `.` word uses reciprocal-based division by 10 and correctly handles negative numbers:

```forth
-123 .      \ prints -123
```

### Stack-as-Memory Addressing

Primitives use offset addressing `[XY2 + #offset]` for efficient stack manipulation without push/pop:

```asm
; SWAP without moving stack pointer
LOADD   D0, [XY2]           ; TOS
LOADD   D1, [XY2 + #2]      ; Second
STORED  D0, [XY2 + #2]
STORED  D1, [XY2]
```

### Sentinel-Based Interpreter

Instead of checking a flag in every NEXT call, v2.17+ uses a sentinel word (STOP) at the end of interpreter-constructed threads. This removes 10 cycles from every NEXT execution.

### Limitations

- 16-bit cells (0-65535 unsigned, -32768 to 32767 signed)
- No floating point
- No file I/O
- No `DOES>` (defining words limited)
- Single-tasking
- `."` is compile-only (use inside definitions)
- Division is slow (repeated subtraction)

---

## Quick Reference Card

```
STACK:    DUP DROP SWAP OVER ROT -ROT NIP TUCK ?DUP
          2DUP 2DROP 2SWAP 2OVER PICK DEPTH
          >R R> R@

MATH:     + - * / MOD /MOD
          1+ 1- 2* 2/ NEGATE ABS MIN MAX +!

LOGIC:    AND OR XOR INVERT

COMPARE:  = <> < > <= >= 0= 0< 0> U< U>

MEMORY:   @ ! C@ C! HERE ALLOT , C,

I/O:      EMIT KEY CR SPACE SPACES . .S ." TYPE
          WORDS PAGE CLS HEX DECIMAL

INTERRUPT: EINT DINT TICKS

CONTROL:  IF ELSE THEN
          DO LOOP +LOOP I J
          BEGIN UNTIL AGAIN WHILE REPEAT

DEFINE:   : ; VARIABLE CONSTANT RECURSE FORGET

COMPILE:  [ ] LITERAL ' ['] EXECUTE

COMMENT:  ( ) \

MONITOR:  DUMP ? FILL CMOVE DUMPPAGE
```

---

## Statistics

| Metric | Value |
|--------|-------|
| Version | 2.22 |
| Dictionary words | 105 |
| Code size | ~4500 lines |
| NEXT cycles | 17 |
| Variable access | 3 cycles (zero page) |
| Multiply cycles | ~50 |
| Data stack | ~4K (at $00FFFE, grows down) |
| Return stack | ~56K (at $00EFFE, grows down) |
| TIB | 128 bytes |
| User dictionary | Page $01+ (12MB available) |

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 2.0 | Dec 2025 | Initial release |
| 2.1 | Dec 2025 | MOVE PC optimization, LOADP/STOREP, STOREXY |
| 2.11 | Dec 2025 | Added 18 words to dictionary |
| 2.12 | Dec 24, 2025 | Full signed branch set, BLE support, 86 words |
| 2.13 | Dec 24, 2025 | Suppress `ok` during compilation (multi-line support) |
| 2.14 | Dec 2025 | Stable base version |
| 2.15 | Jan 2026 | MULB-based mul_16x16 |
| 2.16 | Jan 2026 | Fast div10, mul_16x16_32, optimized print_decimal |
| 2.17 | Jan 9, 2026 | Sentinel-based NEXT (37% faster inner interpreter) |
| 2.18 | Jan 2026 | Division (`/` `MOD` `/MOD`), dictionary words, `EXECUTE` (94 words) |
| 2.19 | Jan 2026 | `RECURSE` `[` `]` `LITERAL` `'` `[']` `FORGET` `AGAIN` (102 words) |
| 2.20 | Jan 2026 | Zero page variables, new stack layout ($20FFFE/$20EFFE) |
| 2.21 | Jan 2026 | Timer interrupt support (IRQ7), EINT/DINT/TICKS words |
| 2.22 | Jan 2026 | New memory map (Page $00), RAM detection, interrupts disabled by default |

### v2.22 Changes in Detail

**Startup:**
- Interrupts disabled by default (use `EINT` to enable)
- Automatic RAM detection displays installed memory
- Banner shows "Interrupts Disabled"

**Memory Layout (Page $00):**
- Zero page/stacks moved from $20xxxx to $00xxxx
- Y3 = $00 (was $20)
- Data stack: $00FFFE (was $20FFFE)
- Return stack: $00EFFE (was $20EFFE)
- User dictionary: $010000+ (page $01, was $208000)
- Interrupt vector at $000000

**I/O Changes:**
- Terminal output: $D00000 (was $E00000)
- Keyboard input: $C00000 (unchanged)

**ROM Location:**
- Forth kernel and dictionary at page $FF
- Reset vector at $FF0000

### v2.21 Changes in Detail

**Interrupt Support:**
- IRQ7 timer interrupt at 60Hz increments ZP_TICKS
- `EINT` word enables interrupts
- `DINT` word disables interrupts
- `TICKS` word reads system tick counter

### v2.20 Changes in Detail

**Performance:**
- Zero page variable access: 7 → 3 cycles (4 cycles saved per access)
- Y3=$20 used as implicit page register for LOADP/STOREP
- Y0 register now free for other uses

**Memory Layout:**
- Data stack: $20FFFE (was $207F00) - ~4K space
- Return stack: $20EFFE (was $207E00) - ~4K space  
- System variables: $200100-$20017F (zero page)
- User dictionary: $208000+ (grows up)

**Implementation:**
- All system variables moved to zero page offsets
- 112 LOADP/STOREP calls use Y3 directly

---

*K/OS Forth v2.22 - A Forth for the K16 CPU Architecture*  
*January 2026*
