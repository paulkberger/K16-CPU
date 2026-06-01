# K16 Forth v3.0 — Reference Manual

**Version:** v3.0
**Date:** 14 May 2026
**Target:** K16 CPU, k/OS .COM application
**Source:** `K16_Forth_v3_0_skeleton.asm` (~3640 lines, ~100 primitives)
**Baseline:** v2.25 (ROM-style port), full functional parity

---

## Revision history

| Date | Version | Notes |
|---|---|---|
| 14 May 2026 | v3.0 | Initial release. Single-page native rewrite of v2.25. 2-byte threaded cells, 16-bit page-relative dictionary links, Y-mirror invariant, no boot-time link patcher. Surfaced and fixed K16 emulator `Scc` bug (latent since EMU inception). |

---

## 1. Overview

K16 Forth is an indirect-threaded Forth-83-subset interpreter and compiler running as a k/OS `.COM` application. v3.0 is a functional reimplementation of v2.25 with redesigned internal data structures that exploit the .COM single-page environment.

### 1.1 What v3.0 inherits from v2.25

- Forth-83-subset dialect, same word list
- Outer interpreter using TIB, `>IN`, WORD_BUF
- Threaded inner interpreter (DOCOL / NEXT / EXIT)
- All k/OS V2 ABI syscall integration (`sys_putchar`, `sys_getchar`, `sys_clear`, etc.)
- Decimal and hex number parsing (`$` prefix or `HEX`/`DECIMAL` base switch)
- Case-insensitive dictionary search (upper-case fold at compare time)

### 1.2 What v3.0 changes

| Aspect | v2.25 | v3.0 | Saving |
|---|---|---|---|
| Threaded cell size | 4 bytes | **2 bytes** | 50% on every CFA reference |
| Dict link size | 24-bit (Y+X) | **16-bit (X only)** | 2 bytes per entry |
| Branch cell size | 4 bytes (Y=0, X=offset) | **2 bytes (offset)** | 2 bytes per IF / ELSE / DO / LOOP / BEGIN / UNTIL etc. |
| Inner interpreter NEXT | 5 instructions | **4 instructions** | 1 fetch per dispatch |
| TRAP IP save/restore | `PUSH XY1` (8 cyc) | **`PUSH X1` (5 cyc)** | 3 cyc per TRAP |
| Boot-time link patcher | required | **deleted** | 0 boot-time work |
| Y-mirror discipline | per-primitive | **invariant** | dozens of `MOVE Y0,Y3` removed |
| Dict header overhead | 8 bytes | 6 bytes | 2 bytes per entry |

### 1.3 What is out of scope

- Cached-TOS optimisation (deferred to v3.1)
- New words beyond the v2.25 set
- Floating-point
- Anything requiring more than a single 64 KB task page

---

## 2. Architectural invariants

### 2.1 Single-page execution

A v3.0 Forth instance runs entirely inside its own 64 KB task page (the page byte is in `Y3`, set by the k/OS task loader). Code, data stack, return stack, dictionary, and all I/O buffers live in this page. Multiple Forth shells coexist in k/OS as independent tasks, each in its own page.

### 2.2 The Y-mirror rule

**At MAIN, after `TRAP_REGISTER_SHELL` returns, Forth executes:**

```asm
        MOVE    Y0, Y3
        MOVE    Y1, Y3
        MOVE    Y2, Y3
```

**This establishes the invariant: between TRAPs, `Y0 = Y1 = Y2 = Y3` = current task page.**

The invariant has one consumer rule and one preservation rule:

1. **Any code that needs the current page in any Y register can use any of `Y0/Y1/Y2/Y3` without first copying from Y3.** No `MOVE Y0, Y3` instructions inside primitives.

2. **Every TRAP clobbers Y0 and Y1** (the k/OS V2 ABI does not preserve them). Therefore, every primitive that issues a TRAP must restore the mirror before returning to NEXT:

```asm
        PUSH    X1, XY3             ; save IP (V2 ABI doesn't preserve X1)
        TRAP    #TRAP_PUTCHAR
        POP     X1, XY3
        MOVE    Y0, Y3              ; mirror restore
        MOVE    Y1, Y3
```

X2 (data stack pointer) and X3 (return stack pointer) are preserved by ABI; Y3 is restored by the syscall machinery.

### 2.3 Threaded cells are 2 bytes

Every cell in a compiled Forth word is one 16-bit word. The threaded interpreter follows them at IP = X1, with the page implicit in Y3.

```
Compiled word body example  : SQ DUP * ;

  +0    DUP_CFA              16-bit CFA address of DUP
  +2    STAR_CFA             16-bit CFA address of *
  +4    EXIT_WORD            16-bit CFA address of EXIT_WORD
```

The literal carrier uses two cells: a `LIT` CFA followed by an inline 16-bit value.

```
Compiled word body example  : ANSWER 42 . ;

  +0    LIT_CFA
  +2    0x002A               inline literal 42
  +4    DOT_CFA              CFA of .
  +6    EXIT_WORD
```

Branch carriers use a 16-bit signed offset:

```
Compiled IF / ELSE / THEN example  : T IF 1 ELSE 2 THEN ;

  +0    ZBRANCH_CFA
  +2    <forward offset to ELSE clause>
  +4    LIT_CFA
  +6    0x0001
  +8    BRANCH_CFA
  +10   <forward offset past ELSE>
  +12   LIT_CFA
  +14   0x0002
  +16   EXIT_WORD
```

**Branch offset semantics.** After the offset cell is consumed, the runtime executes `X1 += offset`. Forward branches use `offset = target_HERE − placeholder_addr − 2`. Backward branches (BEGIN…UNTIL) use `offset = begin_addr − placeholder_addr − 2` (negative).

---

## 3. Register conventions

| Register | Role |
|---|---|
| `X1` (IP) | Threaded-interpreter instruction pointer |
| `Y1` | Always = Y3 (mirror) |
| `X2` (DSP) | Data stack pointer; grows down from `$FFFE` |
| `X3` (RSP) | Return stack pointer; grows down from `$EFFE` |
| `Y3` | Task page byte (never modified) |
| `Y0/Y2` | Mirror Y3 by invariant |
| `X0` | CFA scratch; clobbered freely between primitives |
| `D0` | Top-of-result, scratch |
| `D1` | Second arg, scratch |
| `D2`, `D3` | Callee-saved across TRAPs (V2 ABI) |
| `PC` | Hardware program counter |
| `SR` | Status register (C, Z, N, V; interrupt fields read-only) |

---

## 4. Memory map (within the task page)

| Range | Use |
|---|---|
| `$0000`..`$01FF` | k/OS reserved (TCB pointer at $0000, task-local slots) |
| `$0200`..`$3FFF` | .COM image (Forth code & data, ~16 KB) |
| `$4000`..`$401F` | Forth zero-page variables (see §5) |
| `$4100`..`$417F` | TIB (terminal input buffer, 128 bytes) |
| `$4180`..`$41FF` | WORD_BUF (parsed-word scratch, 128 bytes) |
| `$4200`..`$DFFF` | User dictionary (~47 KB, grows up) |
| `$E000`..`$EFFE` | Return stack (grows down from `$EFFE`) |
| `$F000`..`$FFFE` | Data stack (grows down from `$FFFE`) |

The .COM stack at `$FFF0` is used only briefly before MAIN switches to the Forth stacks.

---

## 5. Zero-page variables

All Forth state lives in a small zone at `$4000`. Accessed via `LOADP`/`STOREP` with Y3 = task page.

| Symbol | Addr | Size | Meaning |
|---|---|---|---|
| `ZP_LATEST` | `$4000` | word | Head of dictionary chain (16-bit page-relative address of newest entry) |
| `ZP_HERE` | `$4002` | word | User-dict compile pointer (next free byte) |
| `ZP_STATE` | `$4004` | word | 0 = interpret, 1 = compile |
| `ZP_TOIN` | `$4006` | word | `>IN`: parse position within TIB |
| `ZP_NUMTIB` | `$4008` | word | `#TIB`: number of valid bytes in TIB |
| `ZP_BASE` | `$400A` | word | Number base (10 or 16) |
| `ZP_SAVED_LATEST` | `$400C` | word | Snapshot of LATEST for error recovery |
| `ZP_DUMPPAGE` | `$400E` | word | Page byte used by DUMP / ? / FILL / CMOVE (stored as word for convenience) |
| `ZP_CALL_BUF` | `$4010` | 4 bytes | exec_prim mini-thread: `[word_CFA][STOP_CFA]` |
| `ZP_EXEC_RET` | `$4014` | word | IP save slot for CALL-mode primitives that consume the return stack (DUMP, WORDS, `.S`, FORGET) |
| free | `$4016`..`$40FF` | — | Reserved for future use |

---

## 6. The inner interpreter

### 6.1 NEXT

Four instructions, single-cell dispatch.

```asm
NEXT:
        LOADX   X0, [XY1]           ; X0 ← CFA at IP (Y1 = Y3 → our page)
        INC     XY1, #2             ; IP += 2 (one cell)
        LOADD   D0, [XY0]           ; D0 ← code addr at CFA (Y0 = Y3)
        MOVE    PC, D0              ; jump to primitive
```

The CFA loaded at `[XY1]` is a 16-bit value. The code address loaded at `[XY0]` is also 16-bit — every primitive lives within the .COM image at `$0200`..`$3FFF`. The `MOVE PC, D0` zero-extends D0 into the 24-bit PC, keeping execution within the .COM image (k/OS guarantees `PC[23:16] = Y3` at task entry, and the .COM never modifies it).

### 6.2 DOCOL — colon-word entry

```asm
DOCOL:
        PUSH    X1, XY3             ; save IP (return frame is 2 bytes)
        MOVE    X1, X0              ; X1 = CFA
        ADD     X1, #2              ; X1 = body start (skip CFA word)
        BRA     NEXT
```

Compared to v2.25's 6-byte return frame, v3.0's frame is 2 bytes — only X1 is saved.

### 6.3 EXIT_WORD — colon-word return

```asm
EXIT_WORD:
        POP     X1, XY3             ; restore IP
        BRA     NEXT
```

### 6.4 LIT — push inline literal

```asm
LIT:
        LOADD   D0, [XY1]           ; D0 = inline value
        INC     XY1, #2             ; advance IP past literal
        PUSH    D0, XY2             ; push to data stack
        BRA     NEXT
```

### 6.5 DOVAR / DOCON — variable / constant handlers

After NEXT dispatches to one of these, X0 holds the CFA address and the body word lives at CFA+2.

```asm
DOVAR:
        ADD     X0, #2              ; X0 = body address
        PUSH    X0, XY2             ; push address (so @ and ! can act on it)
        BRA     NEXT

DOCON:
        ADD     X0, #2
        LOADD   D0, [XY0]           ; load value at body
        PUSH    D0, XY2
        BRA     NEXT
```

---

## 7. Dictionary

### 7.1 Header layout

Each entry: link (2) + flags+len (2) + name (padded to word boundary) + CFA (2).

```
+0  word   Link            16-bit page-relative; 0 terminates the chain
+2  word   Flags+Len       bit 7 = IMMEDIATE; low 6 bits = name length
+4  bytes  Name            unpadded if even length; one zero byte if odd
+N  word   CFA             primitive code address, OR the address of DOCOL,
                           DOVAR, DOCON for compiled / variable / constant entries
```

After the CFA, a colon definition's body follows: a sequence of 16-bit CFA cells, possibly with inline literals (LIT + value) or branch offsets (BRANCH/ZBRANCH + offset). The body ends with the CFA of `EXIT_WORD`.

### 7.2 Built-in vs user-defined entries

The built-in dictionary is assembled into the .COM image. All links are resolved at assembly time — there is no boot-time patcher in v3.0. The first user-defined entry's link points back into the built-in chain head (head = newest entry, so `LATEST` is updated to point at the new entry as it's built).

### 7.3 Dictionary chain head

At boot, `MAIN` initialises `ZP_LATEST = DICT_DOTQUOTE`. The chain walks newest-first through every entry, terminating at `DICT_SPACE` whose link is zero. New user definitions become the new head.

---

## 8. The outer interpreter

### 8.1 Top-level loop (`QUIT` / `accept_line`)

```
QUIT → accept_line → interpret_loop → QUIT (cycle)
```

`accept_line` reads characters into TIB at $4100 via repeated `sys_getchar` (`TRAP #4`), echoing each (with backspace handling), terminating on CR (`$0A`). `#TIB` is set to the final character count, `>IN` is reset to 0.

`interpret` runs the parse-execute loop until `>IN >= #TIB`. For each token:

1. `parse_word` extracts the next whitespace-delimited token into WORD_BUF, returning addr/len in D2/D3.
2. `find_word` walks the LATEST chain comparing names (case-insensitive). On match it returns CFA in D1, the IMMEDIATE flag in D0[15], and overall success in D0[0] = 1.
3. If found and (interpret mode or IMMEDIATE flag set): call `exec_prim` to execute the word.
4. If found but compile mode and not IMMEDIATE: compile its CFA into HERE via `compile_cfa`.
5. If not found, try `parse_number`. On success, push (interpret mode) or compile as LIT (compile mode).
6. On parse failure, emit `?` and jump to `QUIT_ERROR` which resets STATE and re-prompts.

### 8.2 `exec_prim` — calling a word from outside the threaded interpreter

```
ZP_CALL_BUF: [word_CFA][STOP_CFA]    (4 bytes)
```

Sets IP to point at this mini-thread, then `BRA NEXT`. The NEXT machinery dispatches `word_CFA`, which when it eventually exits, lands on `STOP_CFA`. `STOP` is a special primitive that doesn't `BRA NEXT` — instead it cleans the leaked CALL16 frame and unwinds back into the interpreter's C-style loop.

### 8.3 `compile_cfa` — write a CFA cell to HERE

Two-byte store, two-byte HERE advance. Used by COLON, `;`, `IF`, `ELSE`, `DO`, `LOOP`, etc., and by interpret's number-as-literal compile path.

---

## 9. k/OS integration

### 9.1 .COM launch

The k/OS loader places the Forth .COM at `$0200` in the task page, sets Y3 to the task page byte, sets the .COM stack at `$FFF0`, and jumps to MAIN.

### 9.2 MAIN sequence

```
1. Establish Y-mirror:                MOVE Y0,Y3 / MOVE Y1,Y3 / MOVE Y2,Y3
2. Initialise zero-page variables:    HERE = HERE_BASE, BASE = 10, etc.
3. Initialise Forth stacks:           X2 = DSTACK_TOP, X3 = RSTACK_TOP
4. Register as shell:                 TRAP_REGISTER_SHELL  (so Ctrl-N etc. work)
5. Print banner via sys_puts
6. Jump to QUIT (outer interpreter)
```

### 9.3 Syscalls used

| TRAP # | Name | Class | Used by |
|---|---|---|---|
| 4 | `sys_getchar` | non-leaf | `accept_line`, KEY |
| 5 | `sys_putchar` | leaf | EMIT, CR, SPACE, all printing |
| 17 | `sys_clear` | non-leaf | CLS |
| 18 | `sys_setcursor` | non-leaf | (not used in v3.0) |
| — | `TRAP_REGISTER_SHELL` | non-leaf | MAIN once |

Every TRAP follows the V2 ABI contract: D2, D3, X2 are preserved; D0, D1, XY0, XY1, Y0, Y1 are caller-saved. Y0/Y1 are restored via the Y-mirror; X1 (IP) is `PUSH X1 / POP X1` around every TRAP; X0 is preserved by callers that hold pointers in it.

### 9.4 KLIB calls

`TICKS` uses `CALL24 KLIB_TICKS`, which follows the standard KLIB calling convention (24-bit CALL, returns 16-bit tick count in D0).

---

## 10. Compilation strategy

### 10.1 COLON `:` (interpret-mode word)

1. Parse name into WORD_BUF.
2. Snapshot LATEST into `ZP_SAVED_LATEST` (for error recovery).
3. Set LATEST = HERE (the new entry starts here).
4. At HERE: store link word (old LATEST), store flags+len = name length, copy name bytes, pad to even, store DOCOL as the CFA.
5. Advance HERE past the CFA. Set STATE = 1.

The next words typed go through `interpret`'s compile-mode branch, which calls `compile_cfa` for each. Numbers are compiled as `LIT` + value.

### 10.2 SEMICOLON `;` (IMMEDIATE)

Compile `CFA_EXIT` to terminate the body. Set STATE = 0.

### 10.3 Conditionals — IF / ELSE / THEN (all IMMEDIATE)

```
IF:    compile ZBRANCH_CFA, push current HERE (placeholder slot addr),
       compile a zero placeholder, advance HERE.

ELSE:  compile BRANCH_CFA, push new HERE as ELSE's slot, compile zero
       placeholder, patch IF's slot with (HERE − if_slot − 2),
       leave ELSE's slot on the stack.

THEN:  patch slot at TOS with (HERE − slot − 2).
```

### 10.4 Indefinite loops — BEGIN / UNTIL / WHILE / REPEAT / AGAIN (IMMEDIATE)

`BEGIN` pushes HERE. `UNTIL` and `AGAIN` compile a ZBRANCH/BRANCH plus a back-offset to the saved address. `WHILE` compiles a forward ZBRANCH and leaves its slot on the stack alongside BEGIN's. `REPEAT` compiles the BRANCH back to BEGIN, then patches WHILE's forward slot.

### 10.5 Counted loops — DO / LOOP / +LOOP (IMMEDIATE)

`DO` compiles `DO_RT_CFA` and pushes HERE. `LOOP` compiles `LOOP_RT_CFA` followed by the back-offset to DO's body. `+LOOP` is identical but compiles `PLOOP_RT_CFA`.

At runtime: `DO_RT` moves limit and index from data stack to return stack (limit underneath). `LOOP_RT` increments the index in place on the return stack, branches back if index < limit, otherwise drops both and skips the offset cell.

### 10.6 Leaf vs non-leaf primitive style (asm-level)

This distinction is about the **k/OS syscall pattern**, not Forth's compile-time semantics:

- **Leaf primitive (no TRAP):** stack op, arithmetic, comparison, memory @/!. Runs entirely on data; ends in `BRA NEXT`.
- **TRAP-using primitive:** must `PUSH X1 / TRAP / POP X1 / MOVE Y0,Y3 / MOVE Y1,Y3` around every TRAP. Also save X0 if used to hold state across the TRAP.

---

## 11. Word index

### 11.1 Stack

`DUP DROP SWAP OVER ROT -ROT NIP TUCK ?DUP 2DUP 2DROP 2SWAP 2OVER PICK DEPTH >R R> R@`

### 11.2 Arithmetic

`+ - * / MOD /MOD 1+ 1- 2* 2/ NEGATE ABS MIN MAX`

`*` uses the `mul_16x16` helper (MULB-based partial-product method, ~30 cycles). `/`, `MOD`, `/MOD` use repeated subtraction (simple and correct; not fast). The `div10` helper for number printing uses reciprocal multiplication via `mul_16x16_32`.

### 11.3 Logic & comparison

`AND OR XOR INVERT`
`0= 0< 0> = <> < > <= >= U< U>`

Comparisons use the `Scc` instructions for branchless flag generation. **True = $FFFF**, **false = $0000** (Forth-83 / standards-compliant).

### 11.4 Memory

`@ ! C@ C! +!`

All accesses are within the task page (Y0 = Y3 by invariant).

### 11.5 I/O

`EMIT KEY CR SPACE SPACES TYPE CLS`

### 11.6 Dictionary

`HERE ALLOT , C, WORDS FIND FORGET ' [']`

### 11.7 Compile-time (all IMMEDIATE)

`: ; IF ELSE THEN BEGIN UNTIL WHILE REPEAT AGAIN DO LOOP +LOOP I J [ LITERAL ['] RECURSE ( \ ."`

### 11.8 Mode & definition

`] EXECUTE IMMEDIATE VARIABLE CONSTANT`

### 11.9 Number base & I/O

`. .S HEX DECIMAL TICKS`

### 11.10 Monitor

`DUMP ? FILL CMOVE DUMPPAGE`

### 11.11 Exit

`BYE`

---

## 12. Building and running

### 12.1 Source files

- `K16_Forth_v3_0_skeleton.asm` — main source (~3640 lines)
- `..\K16 OS\kos_defs.inc` — k/OS constants (TRAP numbers, ZP slots)
- `..\K16 OS\klib\kos_klib.inc` — KLIB slot constants

### 12.2 Assemble

The K16 assembler produces a `.COM` image. The .COM must be placed on a k/OS-bootable disk (B: in current setups) under the name `FORTH.COM`.

### 12.3 Run

From the k/OS shell `kosh`:

```
run b:forth.com
```

This spawns Forth as a new shell task. Use `Ctrl-N` / `Ctrl-P` to cycle between shells; `bye` from Forth returns control to kosh.

---

## 13. Implementation notes

### 13.1 Why 2-byte cells?

In a single-page environment, every CFA, every link, every branch target fits in 16 bits — the high byte is always Y3. v2.25 carried the 24-bit overhead because it was originally targeted at multi-page operation. With that constraint dropped, halving all cells was the obvious win.

A 1 KB user dictionary in v2.25 was room for roughly 100 cells of compiled code (plus headers). The same space in v3.0 holds 200 cells. Compile-time efficiency follows: a 5-level IF/ELSE/THEN nest goes from 40 bytes to 20.

### 13.2 Why no boot-time patcher?

v2.25 needed `init_dict_pages` because every Y-byte in every dictionary link had to be filled in with the runtime task page. v3.0 carries no Y-bytes in links — the page is implicit in Y3 — so the assembler resolves everything and boot is instant.

### 13.3 Why save X1 instead of XY1?

XY1 push/pop is 8 cycles; X1 alone is 5. Y1 is reconstructed via `MOVE Y1, Y3` (3 cycles) after the TRAP. Net saving per TRAP: 3 cycles in the typical path, 0 in error paths. Forth I/O is TRAP-heavy (every EMIT, every char of every string, every WORDS entry letter), so this aggregates.

### 13.4 Why a Y-mirror at all?

The K16's `LOADD [XYn]` instruction requires both X and Y components. Inside a single page, the Y component is always Y3. Rather than emit `MOVE Y0, Y3` everywhere a memory access happens, v3.0 maintains the invariant globally and pays for it only at TRAP boundaries.

The cost: 2 instructions per TRAP-using primitive (`MOVE Y0,Y3 / MOVE Y1,Y3`) = 6 cycles. The benefit: zero instructions per non-TRAP primitive. For a stack op like `DUP` (no TRAPs), v3.0 is `LOADD / PUSH / BRA NEXT` — 3 instructions where v2.25 had 4.

### 13.5 `exec_prim` and the STOP sentinel

When the outer interpreter wants to execute a word, it doesn't simulate a body — it sets up a 4-byte mini-thread `[word_CFA][STOP_CFA]` in zero-page, points IP at it, and falls into NEXT. The word runs; on completion (whether the word is a primitive or a colon definition) NEXT dispatches `STOP_CFA`. STOP cleans the CALL16 frame leaked by exec_prim's call (4 bytes on the return stack) and `BRA`s back to the interpreter loop.

v2.25 also leaked this frame — v3.0's STOP carries `ADD X3, #4` to clean it explicitly.

---

## 14. Validated test cases

These were exercised against v3.0 on the K16 emulator on 14 May 2026.

| Test | Expected | Result |
|---|---|---|
| `3 5 < .` | `-1` | ✓ |
| `5 3 < .` | `0` | ✓ |
| `: SQ DUP * ;  5 SQ .` | `25` | ✓ |
| `: TEST IF 11 ELSE 22 THEN . ;  1 TEST` | `11` | ✓ |
| `: STARS 0 DO 42 EMIT LOOP ;  5 STARS` | `*****` | ✓ |
| `: COUNT 0 BEGIN DUP 5 < WHILE DUP . 1+ REPEAT DROP ;  COUNT` | `0 1 2 3 4` | ✓ |
| `: FACT DUP 1 > IF DUP 1- RECURSE * THEN ;  5 FACT .` | `120` | ✓ |
| `3 ' SQ EXECUTE .` | `9` | ✓ |
| `: USE-SQ ['] SQ EXECUTE ;  6 USE-SQ .` | `36` | ✓ |
| `VARIABLE FOO  42 FOO !  FOO @ .` | `42` | ✓ |
| `17 CONSTANT BAR  BAR .` | `17` | ✓ |
| `: HELLO ." Hello, world!" CR ;  HELLO` | `Hello, world!\n` | ✓ |
| `WORDS` | full ~80-name list, wrapped at 72 cols | ✓ |
| `1 2 3 .S` | `<3>` (depth 3) | ✓ |
| `FORGET TESTME` (after `: TESTME ;`) | HERE rewinds 14 bytes | ✓ |
| `HERE 32 DUMP` | hex+ASCII dump of dictionary | ✓ |

---

## 15. Caveats and known issues

### 15.1 K16 emulator `Scc` bug — fixed 14 May 2026

Before this session, `ExecScc` in `emu_opcodes.pas` was setting destination registers to `1` (true) or `0` (false), not `$FFFF` / `$0000` as the K16 ISA specifies. Latent since the emulator's first version — never visible in v2.25 because Forth-83 `IF` / `UNTIL` only test for non-zero, so `1` worked as "true" for control flow. v3.0 surfaced it the first time a comparison flag was printed with `.` and the result came out as `1` instead of `-1`.

The fix is one block of four assignments in `ExecScc`. v3.0 assumes the patched emulator. Silicon (TTL) behaves correctly because the data-bus pull-up/down naturally produces all-bits-set on the asserted condition.

### 15.2 `TICKS .` prints as negative

`TICKS` returns the low 16 bits of the kernel tick counter, unsigned. `.` prints as signed decimal. When the counter exceeds $7FFF (≈ 18 minutes at 30 Hz), the result prints negative. Use `TICKS HEX . DECIMAL` for the unsigned hex form.

### 15.3 Division is slow

`/`, `MOD`, `/MOD` use repeated subtraction. A divide of 65535 by 1 takes ≈65000 iterations. The fast `div10` (reciprocal multiply) is used by the number printer but not exposed as a user word. v3.1 may switch the general divider to shift-subtract.

### 15.4 No double-precision

Cells are 16-bit only. The 32-bit `mul_16x16_32` helper exists for `div10`'s internal use but isn't surfaced. v3.0 is single-precision Forth.

### 15.5 EVALUATE / SOURCE / state-saving accept

Not implemented. v3.0 accepts one line at a time interactively, no file inclusion, no string-as-source.

---

## 16. Future work (v3.1 candidates)

- Cached-TOS optimisation (TOS in D0 between primitives, not on the stack)
- Shift-subtract division (replace repeated-subtraction)
- `DOES>` for custom defining words
- Double-precision arithmetic (`D+`, `D-`, `D.`, `D<`)
- `S"` and `EVALUATE`
- BLOCK / EDIT (mass-storage-backed source)
- Local variables (à la ANS Forth `LOCALS|`)

---

## Appendix A — Quick reference card

```
STACK         + - * / MOD /MOD = - 1+ 1- 2* 2/ NEGATE ABS
   DUP DROP SWAP OVER ROT     MIN MAX AND OR XOR INVERT
   NIP TUCK ?DUP DEPTH
   2DUP 2DROP 2SWAP 2OVER     COMPARE
   PICK >R R> R@                0= 0< 0> = <> < > <= >=
                                U< U>
MEMORY
   @ ! C@ C! +!               I/O
                                EMIT KEY CR SPACE SPACES
COMPILE                         TYPE CLS . HEX DECIMAL
   : ; IF ELSE THEN
   BEGIN UNTIL WHILE REPEAT   DICTIONARY
   AGAIN DO LOOP +LOOP I J     HERE ALLOT , C,
   [ ] LITERAL ['] '           WORDS FIND FORGET
   IMMEDIATE EXECUTE RECURSE
   ." ( \                     DEFINITIONS
                                VARIABLE CONSTANT
MONITOR
   DUMP ? FILL CMOVE          OTHER
   DUMPPAGE .S                  TICKS BYE
```

---

## Appendix B — Comparison cheat sheet, v2.25 vs v3.0

| Item | v2.25 | v3.0 |
|---|---|---|
| Threaded cell | 4 bytes | **2 bytes** |
| Dict link | Y + X = 4 bytes | **X = 2 bytes** |
| Branch cell | 4 bytes | **2 bytes** |
| Dict header overhead | 8 bytes | **6 bytes** |
| LIT payload | 4-byte cell (Y=0, X=value) | **2-byte value** |
| NEXT instruction count | 5 | **4** |
| Return frame (DOCOL) | 6 bytes | **2 bytes** |
| TRAP IP save | `PUSH XY1` (8 cyc) | **`PUSH X1` (5 cyc)** |
| Y management | per-primitive `MOVE Y0,Y3` | **invariant** |
| Boot-time link patcher | `init_dict_pages` | **deleted** |
| Source size | ~3500 lines | ~3640 lines |
| Compiled .COM size | ~12 KB | ~10 KB |
| Word count | ~100 | ~100 (same set) |
| Forth-83 true value | $0001 (emu bug masked) | **$FFFF (correct)** |

---

*End of K16 Forth v3.0 Reference Manual.*
