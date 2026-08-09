# k/OS KLIB Reference Manual

Version 1.7 -- 9 July 2026

---

## 1. Overview

KLIB is k/OS's shared kernel library. It provides commonly needed helpers -- integer arithmetic, string and memory primitives, ASCII conversion, pseudo-random numbers and time -- to user tasks via a fixed-address jump table at `$00:$A000`.

User code calls a KLIB entry by its symbolic address (e.g. `CALL24 KLIB_STRLEN`). The jump table lives in RAM and is populated at boot from a ROM template by `_InitKLib`. This means future versions of k/OS can update implementations without breaking binaries linked against the table -- only the addresses inside the table change, the entry points themselves remain stable.

KLIB is callable from any task page via the standard `CALL24` mechanism, and from kernel code via the same. Kernel code that predates KLIB (e.g. `_RawPutDec` in `kos_rawio.asm` — moved from the deleted `kos_splash.asm` during the Part 30 cleanup, 14 May 2026) calls the underlying implementations (`_KMul16x16_32`, `_KDiv10`) by their ROM addresses directly; user code must use the jump table.

### 1.1 Status

| Total slots | LIVE | Stubs | Reserved |
|---|---|---|---|
| 64 | 27 | 20 | 17 |

Stub slots resolve to `_BadKlibCall`, which prints a one-line diagnostic and halts the system. This is deliberately strict -- a KLIB call that's not implemented is a programming error, not a recoverable runtime condition.

### 1.2 Sources

| File | Purpose |
|---|---|
| `klib/kos_klib.inc` | Public symbol definitions for all 64 entries |
| `klib/kos_klib_template.asm` | ROM template + `_InitKLib` + `_BadKlibCall` |
| `klib/kos_klib_impl.asm` | Implementation of all LIVE entries |

---

## 2. Calling Convention

### 2.1 ABI summary

| Aspect | Convention |
|---|---|
| Call | `CALL24 KLIB_xxx` (24-bit absolute call through the jump table) |
| Argument 1 | `D0` |
| Argument 2 | `D1` |
| Argument 3 | `D2` |
| Pointer arg 1 | `XY0` |
| Pointer arg 2 | `XY1` |
| Result | `D0` (and `D1` for routines returning two values) |
| Error flag | `C` -- `C=0` means OK, `C=1` means failure |
| Error code | `D0` set to one of the `ERR_xxx` constants from `kos_defs.inc` |

### 2.2 Register preservation

KLIB routines internally save and restore any registers they use beyond the documented arguments and results. A caller can rely on the following:

| Register | Preserved across any KLIB call? |
|---|---|
| `D0` | No (always the result) |
| `D1` | Routine-specific -- read each entry's docstring |
| `D2`, `D3` | Routine-specific -- many use them as scratch |
| `XY0` | Often advanced by string/memory routines (consumed) |
| `XY1`, `XY2` | Generally preserved unless the routine takes a pointer there |
| `XY3` | Always preserved (it's the stack pointer) |

When a routine documents `Clobbers: Dn, ...`, those registers are used internally and not restored to caller's values. When a routine documents `XYn advanced`, the caller's `XYn` will have changed position by the time the call returns -- typically by the byte count of input consumed.

### 2.3 Error-return pattern

LIVE entries that can fail return `C=1` and place an error code in `D0`. Successful returns are `C=0`. The standard error codes used by KLIB are defined in `kos_defs.inc`:

| Constant | Meaning |
|---|---|
| `ERR_INVALID` | Argument out of range, environment unsuitable, or precondition violated |

Routines that cannot fail (e.g. `_KStrLen`) always return `C=0`.

### 2.4 Calling-convention example

```asm
                ; Find the length of a string at $05:$1234.
                LOADI   Y0, #$05
                LOADI   X0, #$1234
                CALL24 -- KLIB_STRLEN
                ; D0 now contains the length, C=0
```

---

## 3. Slot Map

Slots are organised in functional groups of 8. Each slot occupies 4 bytes (one `JMP24` instruction) starting from `KLIB_BASE = $A000`.

| Slot | Symbol | Status | Group |
|---|---|---|---|
| 00 | `KLIB_MUL16x16_32` | LIVE | Math |
| 01 | `KLIB_DIV10` | LIVE | Math |
| 02 | `KLIB_DIVMOD16` | LIVE | Math |
| 03 | `KLIB_UDIVMOD16` | LIVE | Math |
| 04 | `KLIB_DIVMOD32` | LIVE | Math |
| 05 | `KLIB_MUL32x32_32` | stub | Math |
| 06 | `KLIB_TRY_MOUNT` | LIVE | Math |
| 07 | `KLIB_SLOT_FOR_DRIVE` | LIVE | Math |
| 08-23 | float basic | stub | FFP |
| 24-30 | transcendentals | stub | FFP |
| 31 | reserved |  | FFP |
| 32 | `KLIB_STRLEN` | LIVE | Strings |
| 33 | `KLIB_STRCPY` | LIVE | Strings |
| 34 | `KLIB_STRCMP` | LIVE | Strings |
| 35 | `KLIB_STRCAT` | LIVE | Strings |
| 36 | `KLIB_STRCHR` | LIVE | Strings |
| 37 | `KLIB_MEMCPY` | LIVE | Memory |
| 38 | `KLIB_MEMSET` | LIVE | Memory |
| 39 | `KLIB_MEMCMP` | LIVE | Memory |
| 40 | `KLIB_ITOA` | LIVE | Conversion |
| 41 | `KLIB_UTOA` | LIVE | Conversion |
| 42 | `KLIB_ITOH` | LIVE | Conversion |
| 43 | `KLIB_ATOI` | LIVE | Conversion |
| 44 | `KLIB_ATOH` | LIVE | Conversion |
| 45 | `KLIB_UTOA32` | LIVE | Conversion |
| 46 | `KLIB_BYTES_SPLIT` | LIVE | Conversion |
| 47 | reserved |  | Conversion |
| 48 | `KLIB_RAND16` | LIVE | PRNG / time |
| 49 | `KLIB_SRAND` | LIVE | PRNG / time |
| 50 | `KLIB_TICKS` | LIVE | PRNG / time |
| 51 | `KLIB_DELAY_MS` | LIVE | PRNG / time |
| 52-62 | reserved |  |  |
| 63 | `KLIB_VERSION` | LIVE | Meta |

The current `KLIB_VERSION_VALUE` is `$0101` (v1.1; high byte = major, low byte = minor).

### 3.1 KLIB-internal RAM

| Address | Size | Symbol | Purpose |
|---|---|---|---|
| `$00:$9FFE` | word | `KLIB_SEED` | xorshift16 PRNG state. Seeded by `_InitKLib` to `$ACE1` (non-zero default). |

### 3.2 The `_BadKlibCall` halt

Every stub or reserved slot in the ROM template is wired to `_BadKlibCall`. If user code calls one, the system prints:

```
*** Bad KLIB call ***
```

...and halts. This is deliberate -- a missing implementation is a build-time bug, not something to handle gracefully at runtime.

---

## 4. Math (slots 00-07)

### 4.1 `KLIB_MUL16x16_32` (slot 00)

Unsigned 16x16 -> 32 multiply via byte-wise partial products.

```
In:       D0, D1   16-bit unsigned multiplicands
Out:      D0       low 16 bits of product
          D1       high 16 bits of product
Trashes:  D2, D3
Flags:    C = 0
```

**Method.** Splits each operand into high and low bytes, computes the four partial products (`PP0`-`PP3`) via the `MULB` byte multiply, then sums them in the right columns to assemble the 32-bit result.

**Important.** This routine clobbers `D2` and `D3`. Callers who hold live data in those registers must save and restore them across the call. This bit `_KAtoi` during early implementation -- the multiply clobbered the parser's "base" register (`D3`) and corrupted multi-digit results until a `PUSH D3 / CALL / POP D3` was added.

### 4.2 `KLIB_DIV10` (slot 01)

Unsigned 16-bit divide-by-10, returning quotient and remainder.

```
In:       D0       16-bit unsigned dividend
Out:      D0       quotient
          D1       remainder (0..9)
Trashes:  D2, D3
Flags:    C = 0
```

**Method.** Magic-multiply reciprocal. Computes `(D0 * $CCCD) >> 19`, which is exactly `D0 / 10` for the full 16-bit range. Used by `_KUtoa` to extract decimal digits.

**Important.** Same clobber hazard as `KLIB_MUL16x16_32` -- `D2` and `D3` are not preserved.

### 4.3 `KLIB_DIVMOD16` (slot 02)

Signed 16-bit division returning quotient and remainder.

```
In:       D0       16-bit signed dividend (-32768..32767)
          D1       16-bit signed divisor  (-32768..32767, != 0)
Out:      D0       quotient (signed)
          D1       remainder (signed; sign matches dividend)
Preserves: D2, D3, XY2
Flags:    C = 0 success
          C = 1 error: D0 = ERR_INVALID (divisor was zero)
```

**Method.** Standard shift-subtract restoring division. Take absolute values, run unsigned division, then negate quotient/remainder according to operand signs. Worst case ~250 cycles.

**Sign convention** (matching C99 truncated division):

- `quotient_sign = sign(dividend) XOR sign(divisor)`
- `remainder_sign = sign(dividend)`

So `-7 / 2 = -3` remainder `-1`, not `-4` remainder `+1`.

**Overflow corner case.** `$8000 / -1` overflows (the true result `+32768` is not representable in signed 16-bit). The routine returns `$8000` silently rather than flagging. Callers needing this corner case should pre-check.

**Caller pattern:**

```asm
                LOADI       D0, #-100
                LOADI       D1, #7
                CALL24      KLIB_DIVMOD16
                BCS         .div_error          ; divisor was zero
                ; D0 = -14, D1 = -2
```

### 4.4 `KLIB_UDIVMOD16` (slot 03)

Unsigned 16-bit division returning quotient and remainder.

```
In:       D0       16-bit unsigned dividend (0..65535)
          D1       16-bit unsigned divisor  (1..65535)
Out:      D0       quotient
          D1       remainder
Preserves: D2, D3, XY2
Flags:    C = 0 success
          C = 1 error: D0 = ERR_INVALID (divisor was zero)
```

**Method.** Same shift-subtract algorithm as `KLIB_DIVMOD16` but without sign handling, so a little faster (~200 cycles worst case).

**Caller pattern:**

```asm
                LOADI       D0, #50000
                LOADI       D1, #7
                CALL24      KLIB_UDIVMOD16
                BCS         .div_error
                ; D0 = 7142, D1 = 6
```

**When to choose between KLIB_DIV10 and KLIB_UDIVMOD16 with divisor=10.** Always `KLIB_DIV10` — it's the magic-multiply reciprocal, ~80 cycles, ~2.5x faster than the general routine. Use `KLIB_UDIVMOD16` for divisors not known at compile time.

### 4.5 `KLIB_DIVMOD32` (slot 04)

Unsigned 32 / 16 → 32 quotient + 16 remainder.

```
In:       D1:D0    32-bit unsigned dividend (D1 = high, D0 = low)
          D2       16-bit unsigned divisor
Out:      D1:D0    32-bit unsigned quotient
          D2       16-bit unsigned remainder (always < divisor)
          C = 0    on success
          C = 1    D0 = ERR_INVALID if divisor was 0
Clobbers: D0, D1, D2, D3
Preserves: XY0, XY1, XY2 (and XY3 apart from natural PUSH/POP motion)
```

Standard shift-subtract algorithm: 32 iterations of left-shifting a 33-bit register `(R:HI:LO)` and trial-subtracting the divisor from `R` when `R >= divisor`. Loop body uses a 3-word `ADD/ADC/ADC` chain to shift the 33-bit register left by one — `ADD Dn, Dn` shifts through the ALU and sets C from the carry-out, allowing the next `ADC` to consume that carry. The K16's `SHL` is LOOKUP-based and flag-transparent (does not set C), and `ROL` is a pure rotate (no carry involvement), so neither can be used for a multi-word shift; see Reference Manual §6.5 and Appendix C.7. Worst-case ~1500-1800 cycles. The divisor and bit counter live on the stack across the loop to free a D-register for the running remainder.

### 4.6 Other math stubs

| Slot | Symbol | Description |
|---|---|---|
| 05 | `KLIB_MUL32x32_32` | 32x32 -> low 32 multiply |

Implementations deferred until needed.

---

### 4.7 Filesystem helpers (slots 06-07)

Two filesystem routines were promoted into KLIB in v1.1; they occupy the tail of the
math octet. Their implementations live in `kfs/` (`kos_fs.asm`, `kos_fs_fd.asm`), not
`kos_klib_impl.asm`.

#### `KLIB_TRY_MOUNT` (slot 06)

Probe and mount the volume in a drive slot: read sector 0, validate the BPB, and cache
the BPB fields into the volume-table slot.

```
In:       D0       drive index (0..5)
Out:      C = 0    mounted; the slot's VOL_PRESENT is set and BPB cached
          C = 1    D0 = ERR_BADDRIVE (no backend installed in this slot)
                        ERR_IO        (BlockRead failed)
                        ERR_INVALID   (bad signature or wrong FS type)
Clobbers: D0, D1, D2, XY0, XY1
```

#### `KLIB_SLOT_FOR_DRIVE` (slot 07)

Map a drive index to its volume-table slot pointer, if mounted.

```
In:       D0       drive index (0..5)
Out:      C = 0    XY2 = slot pointer (page-$00) of the mounted slot
          C = 1    D0 = ERR_BADDRIVE (out of range or not mounted)
Clobbers:  D0, X2, flags
Preserves: D1, D2, D3, Y0, Y1, X0, X1, XY3
```

**Gotcha.** On success the result is the slot pointer in **`XY2`**, and `D0` is
**clobbered** — it does *not* return the drive index. A caller that needs the drive
index after the call must save it first.

---

## 5. Strings (slots 32-36)

All string routines use C-style nul-terminated strings. Bytes within a string are not interpreted in any way -- strings are byte arrays that happen to end at the first `$00`.

### 5.1 `KLIB_STRLEN` (slot 32)

Count bytes up to (but not including) the nul terminator.

```
In:       XY0      pointer to nul-terminated string
Out:      D0       byte count (excluding nul)
Clobbers: D1
Flags:    C = 0
```

```asm
                LOADI   Y0, #>MY_STRING
                LOADI   X0, #<MY_STRING
                CALL24 -- KLIB_STRLEN     ; D0 = length
```

### 5.2 `KLIB_STRCPY` (slot 33)

Copy a nul-terminated string from `XY1` to `XY0`. Both pointers are preserved (point to original starts on return).

```
In:       XY0      destination buffer (must have room for src+1 bytes)
          XY1      source string (nul-terminated)
Out:      D0       byte count copied (excluding nul)
          XY0, XY1 unchanged
Clobbers: D1
Flags:    C = 0
```

### 5.3 `KLIB_STRCMP` (slot 34)

Compare two nul-terminated strings byte-by-byte.

```
In:       XY0      first string
          XY1      second string
Out:      D0       0 if equal, < 0 if XY0 < XY1, > 0 if XY0 > XY1
                   (exact value is byte-difference at first mismatch)
          Z = 1    if equal
Clobbers: D1, D2
Flags:    C = 0
```

The returned magnitude is the unsigned byte difference at the first position where the strings differ. A shorter prefix-match returns the negation of the next byte in the longer string.

### 5.4 `KLIB_STRCAT` (slot 35)

Append `XY1` to the nul-terminated string at `XY0`.

```
In:       XY0      destination string (must already be nul-terminated;
                   buffer must have room for src + 1 more bytes)
          XY1      source string (nul-terminated)
Out:      D0       total length of resulting dst (excluding nul)
          XY0, XY1 unchanged
Clobbers: D1, D2
Flags:    C = 0
```

The destination buffer must have room. KLIB does not bounds-check caller buffers. Truncating `STRCAT` is left to the caller (use `STRLEN` first if needed).

### 5.5 `KLIB_STRCHR` (slot 36)

Find the first occurrence of a byte within a nul-terminated string.

```
In:       XY0      string to search (nul-terminated)
          D0       byte to find (low 8 bits)
Out:      Found:    XY0 = pointer to first occurrence
                    D0  = position (0-based)
                    C   = 0
          Not found: XY0 advanced to the nul
                    D0  = $FFFF
                    C   = 1
Clobbers: D1
```

If the search target is `$00`, the routine returns the position of the nul terminator with `C=0`. Searching for the nul is therefore equivalent to `KLIB_STRLEN` plus the pointer.

---

## 6. Memory (slots 37-39)

The memory routines operate on raw byte buffers. They do not stop at nul bytes -- the caller specifies an explicit byte count.

### 6.1 `KLIB_MEMCPY` (slot 37)

Copy a fixed number of bytes from `XY1` to `XY0`. Forward-only -- do not use for overlapping buffers where source precedes destination.

```
In:       XY0      destination
          XY1      source
          D0       byte count (0..65535; 0 is a no-op)
Out:      D0       0 (consumed); XY0, XY1 advanced past the copied region
Clobbers: D1
Flags:    C = 0
```

### 6.2 `KLIB_MEMSET` (slot 38)

Fill a buffer with a constant byte.

```
In:       XY0      destination
          D0       fill byte (low 8 bits)
          D1       byte count (0..65535; 0 is a no-op)
Out:      XY0 advanced past the filled region
Clobbers: D0
Flags:    C = 0
```

### 6.3 `KLIB_MEMCMP` (slot 39)

Compare `D0` bytes at `XY0` and `XY1`.

```
In:       XY0      first buffer
          XY1      second buffer
          D0       byte count
Out:      D0       -1 / 0 / +1
          Z = 1    if equal
Clobbers: D1, D2, D3; XY0, XY1 advanced
Flags:    C = 0
```

A byte count of zero is treated as equal (`D0 = 0, Z = 1`).

---

## 7. Number conversion (slots 40-44)

KLIB ships five conversion entries. The signed flavours use two's-complement; the unsigned flavours treat their input as a plain 16-bit value.

### 7.1 `KLIB_ITOA` (slot 40)

Signed 16-bit integer to ASCII decimal — cursor-style with nul terminator.

```
In:       D0       signed value (-32768..32767)
          XY0      cursor (where to write)
Out:      D0       digit count written (1..6, NOT counting the nul)
          XY0      ADVANCED past optional '-' + digits, pointing AT the nul
Clobbers: D1, D2, D3 (XY0 modified by design)
Flags:    C = 0
Buffer:   needs at least 7 bytes ("-32768\0")
```

Cursor-style with best-of-both API: the digits are written at the original `XY0`, `XY0` is advanced past them, and a nul is written at the new `XY0` position (but `XY0` is *not* advanced past the nul). This means:

- **Cursor-chain users** (kosh buffer-and-blast pattern) read the advanced `XY0` and continue emitting; the next byte they write overwrites the nul. No extra work.
- **String-result users** save `XY0` before the call; afterwards the saved pointer addresses a valid nul-terminated string of length `D0`. No extra work.

Always emits a leading `-` for negative values.

### 7.2 `KLIB_UTOA` (slot 41)

Unsigned 16-bit integer to ASCII decimal — cursor-style with nul terminator.

```
In:       D0       unsigned value (0..65535)
          XY0      cursor (where to write)
Out:      D0       digit count written (1..5, NOT counting the nul)
          XY0      ADVANCED past digits, pointing AT the nul
Clobbers: D1, D2, D3 (XY0 modified by design)
Flags:    C = 0
Buffer:   needs at least 6 bytes ("65535\0")
```

Same best-of-both contract as `KLIB_ITOA`. See section 7.1 for usage idioms.

Implementation uses a recursive divide-by-10 helper that writes digits in correct (most-significant first) order via the natural unwinding of recursion. Maximum recursion depth is 5 (for "65535").

### 7.3 `KLIB_ITOH` (slot 42)

Signed 16-bit integer to ASCII hex, fixed 4-digit format — cursor-style with nul terminator.

```
In:       D0       16-bit value (interpreted bitwise; sign is irrelevant)
          XY0      cursor (where to write)
Out:      D0       always 4 (digit count, NOT counting the nul)
          XY0      ADVANCED past the 4 hex digits, pointing AT the nul
Clobbers: D1, D2, D3 (XY0 modified by design)
Flags:    C = 0
Buffer:   needs at least 5 bytes ("FFFF\0")
```

Always 4 hex digits, uppercase, no `$` prefix, no leading-zero suppression. The output is purely the underlying bit pattern — for example, `-1` is written as `FFFF`. Same best-of-both contract as `KLIB_ITOA`.

### 7.3.1 Migrating from KLIB v1.0

In v1.0 the conversion functions preserved `XY0` and the buffer ended up nul-terminated at the original address. In v1.1 they advance `XY0` past the digits.

If you have v1.0 code that did this:

```asm
LOADI XY0, #BUF
CALL24 KLIB_UTOA       ; XY0 unchanged in v1.0
; ... use BUF as a string ...
```

It still works in v1.1 because `BUF` is still nul-terminated — the only difference is `XY0` ends up pointing inside the buffer rather than at the start. If your code reads `XY0` as the buffer start, save it before the call:

```asm
LOADI XY0, #BUF
LEA XY2, XY0           ; save buffer start
CALL24 KLIB_UTOA
LEA XY0, XY2           ; restore
```



### 7.4 `KLIB_ATOI` (slot 43)

Parse an ASCII string as a signed 16-bit integer.

```
In:       XY0      pointer to nul-terminated source string
Out:      OK:       D0 = parsed value
                    D1 = bytes consumed
                    C  = 0
          Failure: D0 = unspecified
                    D1 = 0
                    C  = 1
Clobbers: D2, D3; XY0 advanced past parsed input
```

**Format.** `[-] [$] digits`

- Optional unary minus.
- Optional `$` prefix switches to hex mode (default is decimal).
- Digits: `0-9` always; `A-F`, `a-f` only in hex mode.
- Parse stops at the first non-digit (nul, space, etc).

**Failure.** `C=1` is returned when no digits were parsed (the string is empty, contains only sign / prefix, or starts with a non-digit). On success, `D1` reports the total bytes consumed, including any sign and prefix characters.

### 7.5 `KLIB_ATOH` (slot 44)

Parse an ASCII hex string as a 16-bit value.

```
In:       XY0      pointer to nul-terminated source string
Out:      same as KLIB_ATOI
Clobbers: D2, D3; XY0 advanced
```

**Format.** `[-] [$] hex-digits`

- Optional unary minus.
- Optional `$` prefix is accepted and skipped (always hex).
- Hex digits: `0-9`, `A-F`, `a-f`.

`KLIB_ATOI` and `KLIB_ATOH` share a common parser body internally. The two entry points differ only in their default base (10 vs 16).

### 7.6 `KLIB_UTOA32` (slot 45)

Unsigned 32-bit integer to ASCII decimal — cursor-style with nul terminator.

```
In:       D1:D0    32-bit unsigned value (D1 = high, D0 = low)
          XY0      cursor (where to write)
Out:      D0       digit count written (1..10, NOT counting the nul)
          XY0      ADVANCED past digits, pointing AT the nul
Clobbers: D1, D2, D3 (XY0 modified by design)
Preserves: XY1, XY2, XY3
Flags:    C = 0
Buffer:   needs at least 11 bytes ("4294967295\0")
```

Same best-of-both contract as `KLIB_UTOA` — see section 7.2 for usage idioms. The 32-bit analogue: pass the full value in `D1:D0` (high word in D1, low word in D0).

Implementation: recursive divide-by-10 using `KLIB_DIVMOD32`, mirroring `KLIB_UTOA`'s structure but with 32-bit values throughout. Max recursion depth is 10 (for `"4294967295"`). Each recursion frame pushes one digit and the return address, so stack overhead is bounded.

Typical use — formatting a 32-bit tick counter for display:

```asm
        LEA     XY0, BUF                ; XY0 = output buffer (>= 11 bytes)
        LOADD   D0, ticks_lo            ; D1:D0 = 32-bit value
        LOADD   D1, ticks_hi
        CALL24  KLIB_UTOA32
        ; BUF now contains nul-terminated decimal string;
        ; XY0 points at the nul.
```

---

### 7.7 `KLIB_BYTES_SPLIT` (slot 46)

Split a 32-bit byte count into a "human-readable" `(whole, fractional, unit)` triple. Pure math primitive — no I/O, no caller buffer. Used by `_KoshEmitSize` (kosh_helpers.asm) to build `"1.00MB"` / `"45KB"` / `"0"` strings for disk-usage displays (`vol`, `ls`).

```
In:       D1:D0    32-bit unsigned byte count (D1 = high, D0 = low)
Out:      D0       whole part (0..1023; or up to ~4G for unit=B with no smaller scale)
          D1       hundredths part (0..99)
          D2       unit selector:
                     0 = bytes (B; value < 1024, frac always 0)
                     1 = KB    (1024 ≤ value < 1MB, frac always 0 in our use)
                     2 = MB    (1MB ≤ value < 1GB)
                     3 = GB    (≥ 1GB)
          C        0 (always success)
Clobbers: D0, D1, D2, D3
Preserves: XY0, XY1, XY2, XY3
```

Rendering rules (as implemented by `_KoshEmitSize` on top of this primitive):

| Unit | Format | Examples |
|---|---|---|
| 0 (B) | `<whole>` | `"0"`, `"1023"` |
| 1 (KB) | `<whole>KB` | `"45KB"`, `"979KB"` |
| 2 (MB) | `<whole>.<NN>MB` | `"1.00MB"`, `"43.94MB"` |
| 3 (GB) | `<whole>.<NN>GB` | `"1.00GB"` |

For KB the fractional part is always 0 (because we split at 1024-byte boundaries) — the rendering layer drops the `.NN`. For MB and GB the fraction matters and is computed as `(byte_remainder × 100) / 1024`, giving at-a-glance precision without needing to express the actual byte count.

**Why a primitive and not just inline math in `_KoshEmitSize`?** Three reasons:

1. **Unit decisions live in one place.** The thresholds (1024, 1MB, 1GB) and the cascade logic shouldn't be duplicated wherever sizes are displayed.
2. **It's reusable.** Anything else that wants to display sizes (a future `du`, memory-stats display, network stats) can grab this and render however it likes.
3. **It uses two heavier KLIB primitives.** `KLIB_DIVMOD32` and `KLIB_MUL16x16_32` are called multiple times; centralising the cascade keeps the call sites flat.

Implementation: cascade of `KLIB_DIVMOD32` calls. Each escalation step divides the running `D1:D0` by 1024, captures the remainder for fraction computation, then decides whether to escalate further (`D1:D0 ≥ 1024`?). At the final stop, compute `frac = (remainder × 100) / 1024` via `KLIB_MUL16x16_32` + `KLIB_DIVMOD32`. Three potential exit points — bytes, KB+frac, MB+frac, GB+frac — each setting up `D0/D1/D2` accordingly.

Typical use — rendering disk-usage:

```asm
        LOADZ   D0, [#VOL_TOTAL_TMP]    ; clusters
        LOADZ   D1, [#VOL_CLSZ_TMP]
        CALL24  KLIB_MUL16x16_32        ; D1:D0 = bytes
        CALL24  KLIB_BYTES_SPLIT        ; D0=whole, D1=frac, D2=unit
        ; ...render based on D2...
```

In practice callers don't call this directly — they call `_KoshEmitSize` which handles the formatting policy. But the primitive is exported for cases where a different rendering style is wanted (e.g. fixed-width with always-shown decimals, or different unit thresholds).

---

## 8. PRNG / Time (slots 48-51)

### 8.1 `KLIB_RAND16` (slot 48)

Return a pseudo-random 16-bit value.

```
In:       (none)
Out:      D0       next pseudo-random word (never zero)
          C        0
Clobbers: D0 only -- D1..D3 and all index registers preserved
```

**Algorithm.** Marsaglia xorshift-16. Visits every non-zero 16-bit value exactly once before repeating (period 65535). Will never return zero.

The state is held in `KLIB_SEED` at `$00:$9FFE`, initialised by `_InitKLib` to `$ACE1`.

### 8.2 `KLIB_SRAND` (slot 49)

Seed the PRNG.

```
In:       D0       new seed (non-zero recommended)
Out:      C        0
Clobbers: nothing else
```

Seeding with `D0=0` would lock the xorshift in a permanent zero state. To prevent this, `KLIB_SRAND` substitutes `$0001` if the caller passes zero. The substitution is silent (no error reported).

### 8.3 `KLIB_TICKS` (slot 50)

Return the current value of `SYS_TICKS`.

```
In:       (none)
Out:      D0       current tick count
          C        0
Clobbers: D0 only
```

`SYS_TICKS` is a 16-bit free-running counter incremented at 30 Hz by the timer IRQ. It wraps every ~36 minutes. Reading it is atomic on K16 (single `LOADZ`).

### 8.4 `KLIB_DELAY_MS` (slot 51)

Busy-wait for an approximate number of milliseconds.

```
In:       D0       milliseconds (0..65535)
Out:      OK:      C = 0
          Failure: D0 = ERR_INVALID
                   C  = 1
Clobbers: D1, D2
```

**Failure conditions.** `KLIB_DELAY_MS` checks two preconditions at entry. Both must hold for the routine to proceed:

1. `KERNEL_STATE` must equal `KERN_STATE_RUN`. The scheduler must
   be live -- otherwise a timer IRQ would corrupt the bare-kernel context and never return.
2. `IE` (SR bit 7) must be set. Otherwise `SYS_TICKS` won't advance
   while the routine polls.

Either failing returns `C=1` with `D0=ERR_INVALID`. Tasks running under the scheduler always satisfy both conditions; the failure paths exist for boot-time kernel code and atomic-section callers.

**Accuracy.** Tick rate is 30 Hz, so 1 tick ~ 33.33 ms. The routine computes `ticks = D0 / 32` (a `>> 5` shift, faster than real divide), which over-shoots by ~3%. For accurate sleeps from within tasks, prefer `sys_sleep` (TRAP) which uses the same tick counter but blocks the task instead of busy-waiting.

```asm
                LOADI   D0, #500        ; sleep ~500ms
                CALL24 -- KLIB_DELAY_MS
                BCS     .delay_failed   ; not in a real task context
```

---

## 9. Meta (slot 63)

### 9.1 `KLIB_VERSION` (slot 63)

Return the KLIB ABI version.

```
In:       (none)
Out:      D0       version word: high byte = major, low byte = minor
          C        0
```

Current value: `$0101` (v1.1).

The major number changes when the slot map or ABI changes incompatibly. The minor number changes when new entries are added or implementations improve in a backward-compatible way.

---

## 10. Stability rules

KLIB v1.x guarantees:

- The slot map (slot number -> symbol) is frozen.
- LIVE entries' input/output ABIs (registers, flags, error returns)
  are frozen.
- LIVE entries' clobber lists are frozen -- a future implementation
  may clobber *fewer* registers, but never more.
- New LIVE entries fill stub or reserved slots; they never displace
  existing entries.

KLIB v1.x does not guarantee:

- Cycle counts. Implementations may become faster.
- Exact memory layout. `KLIB_SEED`'s address is documented but its
  presence and address may change in v2.
- The behaviour of stub slots (other than that they halt the system).

A v2.0 release would be triggered only by a compelling reason -- e.g. a new calling convention for the whole table, a major restructuring, or a slot-map change. This is not anticipated.

---

## Appendix A. Gotchas

These caveats are accumulated experience from KLIB development. They are reproduced in `kOS_Gotchas.md` as part of a wider list.

**`_KMul16x16_32` and `_KDiv10` clobber `D2` and `D3`.** Any caller holding live data in those registers across these calls must save and restore them. The wrapper-style routines (`_KUtoa`, `_KItoa`) already do this in their entry/exit prologue, but mid-routine math calls -- like `_KAtoi`'s digit accumulator loop -- need explicit PUSH/POP.

**`KLIB_DELAY_MS` requires both `KERNEL_STATE = RUN` and `IE = 1`.** At boot time, `KERNEL_STATE` is `BOOT` and the routine cleanly refuses (returns `C=1`). The success path can only be exercised from a real task context.

**KLIB strings are page-local.** All string routines assume the buffer fits within a single 64KB page. Crossing pages (where the high 8 bits of the address change mid-string) is undefined behaviour. In practice user buffers always live within their task's primary page, so this is rarely a constraint.

**Buffer sizing is the caller's responsibility.** No KLIB routine bounds-checks. The conversion routines' documented "minimum buffer size" is the worst-case width plus the nul. `STRCPY`, `STRCAT`, `MEMCPY` and `MEMSET` trust the caller's count.

---

## Appendix B. Revision History

| Version | Date | Notes |
|---|---|---|
| 1.0 | 5 May 2026 | Initial release. 20/64 slots LIVE. Covers Phases 10-13 of k/OS implementation. |
| 1.1 | 7 May 2026 | Cursor-style refactor of KLIB_UTOA, KLIB_ITOA, KLIB_ITOH. Spec changed from "preserve XY0, write nul" to "advance XY0 past digits, write nul at advanced position." Best-of-both API: cursor users continue emitting (next byte overwrites the harmless nul); string users save XY0 before call (the saved pointer is the string start). No callers of the old form existed at v1.0 release time, so this is a clean spec change. Motivated by kosh's buffer-and-blast output pattern (Phase 16.7 FS commands). Implementation simplified — `_KItoa` no longer needs to save/restore the original `XY0`; helper `_KItoh_Nibble` and `_KUtoa_Recur` advance `XY0` directly instead of using a separate sliding pointer in `XY1`. See `kos_klib_impl.asm` r7. |
| 1.2 | 12 May 2026 | **Slots 02 and 03 promoted to LIVE**: `KLIB_DIVMOD16` (signed 16/16 -> 16+16) and `KLIB_UDIVMOD16` (unsigned 16/16 -> 16+16). Adapted from K16 BASIC v2.2's `divide_16` + `umod_16`, with KLIB-compliant error handling: divisor=0 returns `SEC + D0=ERR_INVALID` rather than calling a host-specific error handler. Standard shift-subtract algorithm, ~200-250 cycles worst case. Sign convention: C99 truncated division (quotient sign = `sign(N) XOR sign(D)`, remainder sign = `sign(N)`). Preserves D2/D3/XY2 per KLIB ABI. New entries 4.3 and 4.4; previous 4.3 (stubs table) renumbered to 4.5. 22/64 LIVE. Driven by the K16 BASIC port (see `BASIC_COM_port_spec_v2.md`); useful for kosh and future Forth port too. |
| 1.3 | 13 May 2026 | **Slots 04 and 45 promoted to LIVE**: `KLIB_DIVMOD32` (unsigned 32/16 -> 32-bit quotient + 16-bit remainder via 33-bit shift-subtract on the stack) and `KLIB_UTOA32` (uint32 -> decimal at XY0, recursive divide-by-10 via `_KDivmod32`). 24/64 LIVE. Driven by `ps` rewrite (32-bit TICKS column) and 32-bit uptime display in `info`. `_KoshPutDec32` retired — superseded by `KLIB_UTOA32` via `ROW_BUF`. |
| 1.4 | 14 May 2026 | Part 30 maintenance pass — no API changes. Single fix: §1 Overview's example reference to `_RawPutDec` updated from `kos_splash.asm` (file deleted in Part 30) to `kos_rawio.asm` (where the helper now lives). Slot count unchanged at 24/64 LIVE. |
| 1.5 | 18 May 2026 | **Slot 46 promoted to LIVE**: `KLIB_BYTES_SPLIT` — pure math primitive that splits a 32-bit byte count into `(whole, hundredths, unit)`, driving human-readable size displays via `_KoshEmitSize` (kosh_helpers.asm r4). Implementation is a cascade of `KLIB_DIVMOD32` calls dividing by 1024 at each step until the value is below 1024 again; final stop computes a 0..99 fractional via `KLIB_MUL16x16_32` + `KLIB_DIVMOD32`. 25/64 LIVE. Driven by Part 34 disk-free reporting (new `vol` disk-usage table + new `ls` totals line showing free space). See §7.7. |
| 1.6 | 26 May 2026 | Documentation pass aligned with Reference Manual v3.14 (CR-2026-001 FLAGSX + pseudo-instructions). No API changes, no slot promotions, no clobber-list changes — 25/64 LIVE unchanged. Single substantive edit: §4.5 KLIB_DIVMOD32 prose updated to explain *why* the `ADD/ADC/ADC` shift chain is used (rather than `SHL/ROL`) — under FLAGSX, `SHL` is LOOKUP-based and flag-transparent (does not set C), and `ROL` is a pure rotate (no carry involvement), so neither can carry between words. Cross-reference now points at Reference Manual §6.5 and Appendix C.7 (FLAGSX design note) instead of the now-removed §6.3 carry-convention row that previously claimed SHL/ROL set C from the shifted-out bit. |
| 1.7 | 9 July 2026 | **Caught up to KLIB code v1.1.** `KLIB_VERSION_VALUE` `$0100` → `$0101` (fixed in §3 and §9.1). **Slots 06–07 documented as LIVE**: `KLIB_TRY_MOUNT` and `KLIB_SLOT_FOR_DRIVE` — FS helpers promoted from `kfs/` in v1.1; §3 slot-map rows changed from "reserved", new **§4.7** gives their ABIs (including the `_SlotForDrive` XY2/D0-clobber gotcha). **§1.1 live count corrected to 27/64** (the status table had drifted to 22 while its own slot map and the v1.5/v1.6 notes said 25; +2 for slots 06–07). FP slots 08–30 confirmed still stub (`_BadKlibCall`). Verified against `kos_klib.inc` / `kos_klib_template.asm` / kfs source. |

---

*End of k/OS KLIB Reference Manual v1.7*
