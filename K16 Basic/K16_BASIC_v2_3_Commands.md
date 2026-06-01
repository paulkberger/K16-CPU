# K16 BASIC v2.3 — Command Reference

Quick reference for all tokens. 54 tokens total ($80–$B5). Grouped by purpose.

## I/O

| Token | Syntax | Description |
|---|---|---|
| `PRINT` | `PRINT expr [, expr]...` | Output to terminal. `,` separator emits a space; trailing `;` suppresses newline. |
| `INPUT` | `INPUT [prompt;] var [, var]...` | Read line from terminal, parse into variable(s). |
| `POKE` | `POKE addr, byte` | Write single byte to memory. |
| `DOKE` | `DOKE addr, word` | Write 16-bit word to memory (little-endian). |

## Program control flow

| Token | Syntax | Description |
|---|---|---|
| `GOTO` | `GOTO line` | Unconditional jump to line number. |
| `GOSUB` | `GOSUB line` | Call subroutine — pushes return address. |
| `RETURN` | `RETURN` | Return from `GOSUB`. |
| `IF` | `IF expr THEN stmt` / `IF expr THEN line` | Conditional. `ELSE` clause supported. |
| `ON` | `ON expr GOTO/GOSUB line[, line...]` | Computed branch — selects nth target. |
| `FOR` | `FOR var = a TO b [STEP s]` | Counted loop. Use multi-line form; same-line FOR/NEXT bug deferred. |
| `NEXT` | `NEXT [var]` | Loop back. Bare `NEXT` matches innermost. |
| `END` | `END` | Stop program cleanly. |
| `STOP` | `STOP` | Stop with message — like `END` but flags abnormal exit. |

## Variables and arrays

| Token | Syntax | Description |
|---|---|---|
| `LET` | `[LET] var = expr` | Assignment. `LET` keyword optional. |
| `DIM` | `DIM A(n)` | Allocate array (integer or string). |
| `CLR` | `CLR` | Reset all variables, string pool, arrays, DATA pointer. Does not delete program text. |

## DATA / READ

| Token | Syntax | Description |
|---|---|---|
| `DATA` | `DATA val [, val]...` | Inline constants embedded in program text. |
| `READ` | `READ var [, var]...` | Consume next `DATA` items. |
| `RESTORE` | `RESTORE [line]` | Rewind `DATA` pointer (optionally to specific line). |

## Reserved words inside statements

These appear inside expressions or other statements, not as standalone commands.

| Token | Used in |
|---|---|
| `THEN` | `IF ... THEN` |
| `TO`, `STEP` | `FOR ... TO ... STEP` |
| `ELSE` | `IF ... THEN ... ELSE ...` |
| `REM` | Comment to end of line |

## Operators (keyword form)

Logical and arithmetic operators that are spelled as words rather than punctuation.

| Token | Meaning |
|---|---|
| `AND` | Bitwise AND |
| `OR` | Bitwise OR |
| `XOR` | Bitwise XOR |
| `NOT` | Bitwise NOT (unary) |
| `MOD` | Modulo |
| `<=`, `>=`, `<>` | Relational (stored as single tokens) |

## Built-in functions

### Numeric

| Token | Syntax | Returns |
|---|---|---|
| `ABS` | `ABS(n)` | Absolute value. |
| `SGN` | `SGN(n)` | -1, 0, or 1. |
| `RND` | `RND(n)` | Random integer 0..n-1 (KLIB_RAND16). |
| `PEEK` | `PEEK(addr)` | Single byte from memory. |
| `DEEK` | `DEEK(addr)` | 16-bit word from memory. |
| `LEN` | `LEN(s$)` | Length of string. |
| `ASC` | `ASC(s$)` | ASCII code of first char. |
| `VAL` | `VAL(s$)` | Parse string to number. |

### String

| Token | Syntax | Returns |
|---|---|---|
| `CHR$` | `CHR$(n)` | One-char string with ASCII code n. |
| `STR$` | `STR$(n)` | Decimal representation of n. |
| `HEX$` | `HEX$(n)` | Hex representation (no `$` prefix). |
| `LEFT$` | `LEFT$(s$, n)` | First n chars. |
| `RIGHT$` | `RIGHT$(s$, n)` | Last n chars. |
| `MID$` | `MID$(s$, p [, n])` | Substring from position p (1-based). |

## Program management

| Token | Syntax | Description |
|---|---|---|
| `LIST` | `LIST` / `LIST a` / `LIST a-b` | Show program (range optional). |
| `RUN` | `RUN [line]` | Execute program from start (or given line). Resets vars first. |
| `NEW` | `NEW` | Erase program AND variables. |
| `REM` | `REM text` | Comment to end of line. |

## Filesystem  *(new in v2.3)*

| Token | Syntax | Description |
|---|---|---|
| `SAVE` | `SAVE "name"` / `SAVE name` | Write program to `<DRIVE>:NAME.BAS`. Drive prefix and `.BAS` auto-added if missing. |
| `LOAD` | `LOAD "name"` / `LOAD name` | Read program from disk. Issues `CLR` automatically. Refuses if file > 22 KB. |
| `DIR` | `DIR` / `DIR B:` | List files on current drive, or specified drive (A..F). |
| `DRIVE` | `DRIVE B:` | Change current drive. Stored in `ZP_DRIVE` ($430C), default `B:`. |

## Shell  *(new in v2.3 via BYE)*

| Token | Syntax | Description |
|---|---|---|
| `BYE` | `BYE` | Exit BASIC, return to kosh with exit code 0 (`TRAP_EXIT`). |

---

## Numeric ranges

- **Integers:** 16-bit signed, -32768..+32767.
- **Hex literals:** `$ABCD` syntax (e.g. `PRINT $FF`).
- **String literals:** double-quoted, max 250 chars (TIB cap).

## Memory map (per-task)

| Range | Contents |
|---|---|
| `$0000–$01FF` | k/OS-reserved (FD table, TLS) |
| `$0200–~$22FF` | BASIC code + rodata |
| `$4100–$430D` | Scalars, descriptors, stacks, **`ZP_DRIVE` at $430C** |
| `$4400–$443F` | Filename build buffer |
| `$4440–$445F` | Directory entry buffer |
| `$4600–$46FF` | TIB (terminal input buffer) |
| `$4700–$48FF` | Temp string buffers |
| `$4900–$9FFF` | **Program text (~22 KB)** |
| `$A000–$EBFF` | Array storage (~19 KB) |
| `$EC00–$FDFE` | String pool (grows down) |
| `$FE00–$FFEF` | Stack |

Free memory reported by banner: **24062 bytes** (vars + strings + arrays combined).

---

## Differences from v2.2 (ROM)

- v2.2 ROM remains unchanged — still standalone interpreter, no filesystem.
- v2.3 is a .COM build that runs under k/OS as a normal task.
- Adds: `SAVE`, `LOAD`, `DIR`, `DRIVE`, `BYE`.
- Memory ranges shifted (PROG_BASE moved from $0000 to $4900) because k/OS reserves `$0000–$01FF` for FD/TLS.

## Known limitations

- **Same-line FOR/NEXT** (`FOR I=1 TO 5: PRINT I: NEXT`) iterates once. Use multi-line form. Architectural, deferred from v2.2.
- **No floating point.** All arithmetic 16-bit signed integer.
- **No string compare with `>`/`<`.** Only `=` and `<>` work on strings.
