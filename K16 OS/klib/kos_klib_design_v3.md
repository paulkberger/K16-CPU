# k/OS Shared Libraries — Design Note (rev 3)

**Date:** 5 May 2026
**Status:** Phase 10 — KLIB infrastructure landing
**Companion to:** NEW_CHAT_CONTEXT_kOS_Phase10.md
**Supersedes:** kos_klib_design_v2.md (rev 2, single 64-slot library)

---

## Summary of changes from rev 2

- **Two libraries** (KLIB + GLIB) instead of one combined.
- **Float format committed**: Motorola FFP (Fast Floating Point), 32-bit.
- **Slot maps published** for both KLIB and GLIB v1.0 — full ABI even
  for unimplemented slots.
- **GLIB address space reserved** at `$00:$A100` but no init/template
  in Phase 10.

---

## Two libraries, separate address ranges

| Range | Library | Size | Status |
|---|---|---|---|
| `$00:$A000-$A0FF` | KLIB — math, strings, formatting, time | 64 slots | Phase 10 |
| `$00:$A100-$A1FF` | GLIB — graphics primitives (QuickDraw-style) | 64 slots | Reserved |

Each entry is one `JMP24` instruction (4 bytes). Both libraries use the
same patchable-RAM-template mechanism.

Why split: KLIB and GLIB have different audiences. Most user tasks
(kosh, utilities, text apps) never touch GLIB. Graphics is also the
subsystem most likely to need backwards-incompatible revisions, and
isolating it keeps that churn out of the core ABI.

Future libraries can claim `$A200`, `$A300`, etc.

---

## Float format — Motorola FFP

The 32-bit Motorola Fast Floating Point format, ported from the
MotoFFP project (bayerf42/MotoFFP on GitHub — port of the original
Motorola 68343 FFP library, originally for Sirichote 68008).

```
 31    24 23                                  0
+--------+------------------------------------+
| sExp   | M M M M M M M M ... M M M M M M M |
| sEEEEEEE| 24-bit normalised mantissa        |
+--------+------------------------------------+
   byte 0          bytes 1-3
```

- 1 sign bit (bit 7 of byte 0)
- 7-bit excess-64 exponent (bits 6:0 of byte 0)
- 24-bit normalised mantissa (bytes 1-3)

**Format choice rationale**:

- Faster than IEEE 754 single (no NaN/Inf/denormal handling)
- Simpler to port to K16 (cleaner exception model)
- Range ±9.2e18 down to ±5.4e-20 — adequate for any realistic K16 use
- Precision ~1 bit less than IEEE single — irrelevant in practice
- **No impact on QuickDraw port**: original QuickDraw is integer-only
  (signed 16-bit pixel coordinates). Float-aware graphics didn't
  appear until QuickDraw GX / Quartz, both well after K16's design
  era. GLIB integer coordinates align with original Atkinson design.

**Pre-implementation audit deferred**: K16 BASIC v2.2 already has a
working float library — its format may already be FFP-compatible or
close, in which case porting becomes refactoring. Forth v2.24 has
several integer math primitives that map to KLIB slots (UM*, UM/MOD,
pictured numeric output). Audit scheduled before float-implementation
phase.

---

## KLIB v1.0 slot map (64 slots)

```
Slot  Symbol                       Status   Notes
----  ---------------------------  -------  -------------------------------------
00    KLIB_MUL16x16_32             LIVE     D0,D1 → D1:D0 (existing _KMul16x16_32)
01    KLIB_DIV10                   LIVE     D0/10 → D0 quot, D1 rem (existing _KDiv10)
02    KLIB_DIVMOD16                stub     signed 16/16 → quot, rem
03    KLIB_UDIVMOD16               stub     unsigned variant
04    KLIB_DIVMOD32                stub     32/16 → quot, rem
05    KLIB_MUL32x32_32             stub     low-half 32×32 multiply
06    KLIB_RESERVED_06             stub
07    KLIB_RESERVED_07             stub

08    KLIB_FADD                    stub     FFP add — D1:D0 + D3:D2 → D1:D0
09    KLIB_FSUB                    stub     FFP subtract
10    KLIB_FMUL                    stub     FFP multiply
11    KLIB_FDIV                    stub     FFP divide
12    KLIB_FNEG                    stub     FFP negate
13    KLIB_FCMP                    stub     FFP compare → flags + D0
14    KLIB_FTOI                    stub     FFP → int32 (D1:D0)
15    KLIB_ITOF                    stub     int32 → FFP
16    KLIB_FTOA                    stub     FFP → ASCII
17    KLIB_ATOF                    stub     ASCII → FFP
18    KLIB_FSQRT                   stub     square root
19    KLIB_FABS                    stub     absolute value
20    KLIB_RESERVED_20             stub
21    KLIB_RESERVED_21             stub
22    KLIB_RESERVED_22             stub
23    KLIB_RESERVED_23             stub

24    KLIB_FSIN                    stub     transcendental — sine
25    KLIB_FCOS                    stub     cosine
26    KLIB_FTAN                    stub     tangent
27    KLIB_FATAN                   stub     arctangent
28    KLIB_FLN                     stub     natural log
29    KLIB_FEXP                    stub     exponential
30    KLIB_FPOW                    stub     power (x^y)
31    KLIB_RESERVED_31             stub

32    KLIB_STRLEN                  stub     XY0 → D0
33    KLIB_STRCPY                  stub     XY0 ← XY1
34    KLIB_STRCMP                  stub     XY0 vs XY1 → flags + D0
35    KLIB_STRCAT                  stub     XY0 += XY1
36    KLIB_STRCHR                  stub     find byte in string
37    KLIB_MEMCPY                  stub     XY0 ← XY1, D0 bytes
38    KLIB_MEMSET                  stub     XY0, D0 bytes, D1 byte value
39    KLIB_MEMCMP                  stub     XY0 vs XY1, D0 bytes

40    KLIB_ITOA                    stub     int16 → ASCII decimal
41    KLIB_UTOA                    stub     uint16 → ASCII decimal
42    KLIB_ITOH                    stub     int16 → ASCII hex
43    KLIB_ATOI                    stub     ASCII → int16
44    KLIB_ATOH                    stub     ASCII hex → int16
45    KLIB_RESERVED_45             stub
46    KLIB_RESERVED_46             stub
47    KLIB_RESERVED_47             stub

48    KLIB_RAND16                  stub     pseudo-random 16-bit
49    KLIB_SRAND                   stub     seed PRNG
50    KLIB_TICKS                   stub     get SYS_TICKS counter
51    KLIB_DELAY_MS                stub     busy-wait delay
52    KLIB_RESERVED_52             stub
53    KLIB_RESERVED_53             stub
54    KLIB_RESERVED_54             stub
55    KLIB_RESERVED_55             stub

56    KLIB_RESERVED_56             stub     growth space
57    KLIB_RESERVED_57             stub
58    KLIB_RESERVED_58             stub
59    KLIB_RESERVED_59             stub
60    KLIB_RESERVED_60             stub
61    KLIB_RESERVED_61             stub
62    KLIB_RESERVED_62             stub

63    KLIB_VERSION                 LIVE     returns D0 = $0100 (v1.0)
```

**Phase 10 live**: slots 00, 01, 63 (3 entries). Everything else
points to `_BadKlibCall` and halts the system loudly if invoked.

---

## GLIB v1.0 slot map (64 slots) — RESERVED, NOT IMPLEMENTED

Documented for future planning; address space reserved.

```
00-15   Geometry           pixel, line, rect, oval, arc, polygon
16-23   Bitmap / blit       CopyBits, ScrollRect, InvertRect, FrameRect
24-31   Pen / state         colour, pen size, pattern, mode, clip
32-39   Text               drawChar, drawString, font, size
40-47   Regions            Atkinson regions — new, dispose, union, diff, frame, fill
48-51   Cursor / mouse     show, hide, set, get position
52-62   Reserved
63      GLIB_VERSION
```

Full slot map will appear in `kos_glib_design.md` when GLIB phase
begins.

---

## Calling convention (unchanged from rev 2)

```asm
; In user code:
LOADI   D0, #1234
LOADI   D1, #5678
CALL24  KLIB_MUL16x16_32        ; resolves to $00:$A000
; D0 = lo16, D1 = hi16
```

CALL24 (11 cycles) → JMP24 in RAM table (2 cycles) → routine.
**13 cycles** per library call.

**Flag contract**: all flags clobbered. Hardest to break by accident.

**Register preservation**: each entry follows the kernel ABI —
callee preserves D2/D3/XY2/XY3, args in D0/D1, results in D0 (or
D1:D0 for 32-bit results).

---

## Boot wiring

```
_InitKernel sequence (kos_boot.asm r22):
    1. _InitTCBPool
    2. _DetectHost
    3. _InitMemConfig
    4. _InitHeap
    5. _InitKLib          ← NEW
```

KLIB doesn't depend on the heap, but installing after `_InitHeap`
means the heap is available if a future KLIB entry wants to allocate
on first call.

---

## Phase 10 deliverables

| File | Status |
|---|---|
| `kos_klib.inc` | NEW — public symbols |
| `kos_klib_template.asm` | NEW — ROM template + `_InitKLib` + `_BadKlibCall` + `_KLibVersion` |
| `kos_klib_impl.asm` | NEW — `_KMul16x16_32`, `_KDiv10` (moved from kos_console.asm) |
| `kos_console.asm` r11 | MODIFIED — math helpers removed; references resolve via assembler symbol resolution |
| `kos_boot.asm` r22 | MODIFIED — `_InitKLib` wired into `_InitKernel` |
| `kos_p10_klib_smoke.asm` | NEW — user-task smoke exercising 3 live slots + 1 bad-call |

---

## Open items deferred

- **`_KLibPatch`** (runtime repointing API) — Phase 11+
- **Forth/BASIC audit** — before float implementation phase
- **GLIB design** — separate phase, far future
