# k/OS Reference Manual

Version 0.22 -- 18 May 2026

Changes since v0.21:
- §2.2 page-$00 layout: FD scratch upper bound corrected from `$04CB` to
  `$04D6` (stale since Part 25 added FD_NAMEBUF2). New FE-scratch row
  added at `$04D8..$04E3` (Part 36 relocation, Gotcha 4.47). Reserved-
  for-kernel-growth region updated to `$04E4..$07FF`.
- §2.2 trailing prose: notes Part 36 consolidation of FD_* and FE_*
  declarations into `kos_fs_defs.inc`, and points to the new
  "ZERO PAGE MAP — RULES FOR ADDING ALLOCATIONS" section in
  `kos_defs.inc` as the canonical layout authority.
- §2.4 page-$00 prose listing: added FE scratch row, corrected FD range.

Changes in v0.21:
- §5 (V2 ABI): "audit-pending" caveat removed — all 37 TRAP handlers
  brought into compliance with the expanded D1/XY1 preservation contract
  (Part 36). Added the **input-arg/return clarification**: a callee-
  preserved register may be legitimately consumed or produced when
  documented as an input arg or return register for that specific
  syscall (e.g. `sys_read`/`sys_write` D1 = count, `sys_rename` XY1
  = new-path pointer, `sys_diskfree` D1 = total clusters).
- §5.6 `sys_kill` and §5.7 `sys_setvidmode`: Preserves rows updated to
  reflect expanded V2 ABI (`D1, D2, D3, XY1, XY2`).

Changes in v0.20:
- §5 (V2 ABI): expanded callee-preserved set to `D1, D2, D3, XY1, XY2, XY3`
  (was `D2, D3, XY2`). Compliance status: sys_diskfree built to the new
  contract; older handlers pending audit.
- §5.1: new "Output routing (summary)" subsection at head of Console I/O.
- §5.4: new `sys_diskfree` (TRAP #68) in FS group; `sys_write` row notes
  partial-write D1 semantics; per-group reserve updated.
- §11.6: new "Partial-progress reporting" subsection (sys_write canonical,
  sys_read/sys_puts reserved for future); preservation summary updated.
- §2.2: three new page-$00 slots — `DISKFREE_CLUSTER` ($03F4),
  `DISKFREE_COUNT` ($03F6), `DISKFREE_LIMIT` ($03F8).
- §14 (new): "kosh commands" section; `vol` and `ls` documented.
- §15: Glossary (renumbered from §14); six new entries (Carry-sense,
  Cluster, Disk-free, FAT free list, Human-readable size,
  Partial-progress reporting); Leaf/Non-leaf syscall entries refreshed.

---

## 1. Overview

k/OS is a small preemptive multitasking operating system for the K16 CPU. It runs from ROM at reset, occupies kernel page `$00`, provides paged memory protection between user tasks, and offers a TRAP-based syscall interface. This document describes its architecture, memory layout, process model and kernel APIs.

k/OS is a small, complete, hand-written operating system targeted at hobbyist machines -- preemptive multitasking, page-protected memory, byte-granular kernel heap, all in roughly 7K of ROM.

GitHub: https://github.com/paulkberger/K16-CPU

### 1.1 At a glance

| Aspect | Value |
|---|---|
| CPU | K16 (16-bit CPU, 24-bit address space) |
| Kernel size | ~7K of ROM |
| Multitasking model | Preemptive, 30 Hz timer-driven |
| Maximum tasks | 1 idle + 30 user (Digital) / 62 user (EMU) |
| Memory protection | One 64 KB page per task (page byte = `Y3`) |
| Syscall mechanism | `TRAP #n` |
| Kernel heap | First-fit + bidirectional coalesce, multi-region |
| Filesystem | FAT16 on ROM disk (A:), RAM disk (B:), and host disks (C:..F:, EMU-only). Pieces 1-6 complete; Parts 22 (host backend), 23 (name-based mount), 24 (host filename rename, two-phase mount), and 25 (sys_unlink/sys_rename, kosh CWD, host file ingestion via `load`) all shipped. |
| Multi-shell | Phase B (13 May 2026): preemptive foreground switching between shell tasks, per-shell back-buffers (80×80 = 6400 bytes), ANSI repaint, foreground-gated input. Hot keys: Ctrl-N/P/Shift-N/Left/Right/1..0. Three shells in production (kosh, BASIC v2.5, Forth v3.0). Shell death cleanup consolidated into `_ReapDeadTask` (Part 31, 14 May 2026). |
| Shared library | KLIB at `$00:$A000` -- 24/64 slots LIVE (see `kOS_KLIB_Reference.md` v1.3) |

### 1.2 Design principles

**Small surface.** k/OS targets a hand-built machine with limited RAM and no virtual memory. Every kernel data structure has a fixed or bounded size. The TCB pool is statically sized at boot. The syscall vector table has 128 fixed slots.

**Single-page tasks.** Each user task lives in one 64 KB page. This is enforced architecturally by the K16's page-byte index register (`Y3`): a task whose `Y3` is its primary page byte cannot read or write any other page through ordinary indexed addressing. Crossing pages requires explicit page-byte updates, which user code is structurally not expected to do.

**One kernel context.** k/OS does not have re-entrant kernel code. Syscalls run with a single fixed kernel stack (`KERNEL_STACK_TOP` at `$FFFE`). Most syscalls disable interrupts during their critical sections. The scheduler is itself single-instance.

**Cooperative + preemptive.** Tasks cooperate via `sys_yield` / `sys_sleep` and are also preempted by the 30 Hz timer IRQ. There is no fairness or priority logic in the current scheduler -- tasks take turns in round-robin order.

### 1.3 Source layout

The source tree has two top-level entry-point files at the root, with the rest organised under four subdirectories: `kernel/` (core kernel internals), `kfs/` (filesystem), `klib/` (utility library), and `kosh/` (interactive shell).

#### Project root

| File | Purpose |
|---|---|
| `kos_boot.asm` | Reset vector, `_InitKernel`, `_P2Main` dispatch |
| `kos_defs.inc` | All shared constants -- memory map, TCB layout, syscall numbers, error codes |

#### `kernel/` — core kernel

| File | Purpose |
|---|---|
| `kos_bad_trap.asm` | Default vector handler (uninitialised TRAPs) |
| `kos_console.asm` | Terminal I/O syscalls (`sys_putchar`, `sys_puts`, etc.) |
| `kos_ctxsw.asm` | `_TimerIRQ`, `_INTDispatch`, `_RestoreIdle`, `_IdleLoop` |
| `kos_heap.asm` | `sys_kmalloc`, `sys_kfree` user-facing TRAP wrappers (Phase 14) |
| `kos_kmalloc.asm` | `_kmalloc`, `_kfree`, `_HeapStats` |
| `kos_rawio.asm` | `_RawPutByte`, `_RawPuts`, `_RawPutDec`, `_RawPutHexByte` (used before scheduler is up) |
| `kos_sched.asm` | `_Schedule`, `_WakeSleepers` |
| `kos_sem.asm` | Counting semaphore primitives (Part 20b) |
| `kos_spawn.asm` | `sys_spawn`, `sys_wait` |
| `kos_switcher.asm` | Phase B foreground switcher (`sys_register_shell`, `sys_setforeground`, `_BackbufPutChar`, `_RepaintFromBackbuf`, `_SwitchForegroundNext/Prev/ByIndex`) |
| `kos_task.asm` | `sys_getpid`, `sys_yield`, `sys_exit`, `sys_sleep` |
| `kos_tcb.asm` | TCB pool, `_AllocPage`, `_BuildTask`, `_InitTCBPool` |

(Part 30 r37, 14 May 2026: `kos_splash.asm` deleted; boot banner moved to kosh; its `_RawPutDec` and `_RawPutHexByte` helpers absorbed into `kos_rawio.asm`. See `kosh_splash.asm` in the kosh sources for the live OS sign-on.)

#### `kfs/` — filesystem (Phase 16, Parts 22-25)

Filesystem source covered in detail in a separate document (`kOS_FS_Reference`). Provides FAT16 mount/format, FAT walk and cluster operations, directory operations, per-task file descriptors, the file-syscall layer (TRAPs 26..32, plus 37 unlink and 38 rename), and three pluggable block backends — ROM disk (A:), RAM disk (B:), and host disk (C..F:, EMU-only via the K16 disk controller). The host backend supports both per-sector data flow (Part 22 `_BlockReadHost`/`_BlockWriteHost`) and a streaming file-ingestion surface (Part 25 r6 `_HostFOpen`/`_HostFRead`/`_HostFClose`) used by kosh's `load` command.

| File | Purpose |
|---|---|
| `kos_fs.asm` | Top layer: mount, format, FAT walk, cluster ops, `_FATFreeChain` (Part 25 r2) |
| `kos_fs_defs.inc` | FS-internal constants -- BPB layout, volume slot fields, error codes, disk-controller MMIO (10 `HOST_CMD_*` codes through Part 25 r6) |
| `kos_fs_dir.asm` | Directory operations: 8.3 name conversion, iteration, create/delete (Piece 4) |
| `kos_fs_exec.asm` | `sys_exec` implementation (Piece 6) |
| `kos_fs_fd.asm` | Per-task fd table and file syscalls (`sys_open`, `sys_close`, `sys_read`, `sys_write`, `sys_dirent`, plus Part 25 r2 `sys_unlink` and `sys_rename`) |
| `kos_fs_host.asm` | Host disk block backend (C..F:) — Part 22 |
| `kos_fs_host_mgr.asm` | Host disk management helpers — Parts 23+24+25 (10 helpers covering mount/unmount/list/create/delete/rename/bayname/fopen/fread/fclose) |
| `kos_fs_ram.asm` | RAM disk block backend (B:) |
| `kos_fs_rom.asm` | ROM disk read-only block backend (A:) |

#### `klib/` — utility library

KLIB source covered in detail in a separate document (`kOS_KLIB_Reference`). Provides cursor-style string formatting, integer parsing, memory utilities, RNG, and timing primitives. Accessed via the KLIB jump table at `$00:$A000..$A0FF`.

| File | Purpose |
|---|---|
| `kos_klib.inc` | KLIB jump-table addresses and constants (included by callers) |
| `kos_klib_impl.asm` | KLIB routine implementations |
| `kos_klib_template.asm` | Template / scaffold for new KLIB routines |

#### `kosh/` — interactive shell (Phase 16.7+)

kosh is k/OS's production interactive shell — a small command-line task spawned at boot that provides the user-facing REPL. Built-in commands cover task and system inspection, memory peek/dump, filesystem operations (vol/ls/cat/cp/rm/mv/format/run), host-disk management (disks/mount/unmount/mkdisk/rmdisk/rename/remount), and host file ingestion (`load`). The shell maintains a current working drive (CWD, Part 25 r4) that lets users elide drive-letter prefixes; switching is by bare drive-letter line (`C:`).

The shell is split per command group so individual command bodies can be added or removed without disturbing the dispatch core. kosh also acts as the canonical user task: anything it can do via syscalls, an arbitrary user `.COM` file can do too.

| File | Purpose |
|---|---|
| `kosh.asm` | Shell core: REPL loop, command dispatch (30+ commands), CWD state, `_P2Main` entry |
| `kosh_helpers.asm` | CALL24-callable helpers: emit byte/hex/word/dec, `_KoshParseAddr`, `_KoshNormPath` (CWD path normalisation, Part 25 r4), `_KoshPrintErr` (human-readable error names, Part 25 r3), `_SlotForDrive` |
| `kosh_help.asm` | `help` command text + handler |
| `kosh_cmds_util.asm` | exit, echo, clear, halt, reboot |
| `kosh_cmds_sys.asm` | ver, ps, mem, uptime, info, tcb |
| `kosh_cmds_mem.asm` | peek, dump |
| `kosh_cmds_fs.asm` | vol, ls, cat, format, run, cp (Part 25 r1), rm + mv (Part 25 r2), load (Part 25 r6) |
| `kosh_cmds_disk.asm` | disks, mount, unmount, mkdisk, rmdisk (Part 23), rename (Part 24), remount (Part 25 r5) |

---

## 2. Memory Map

### 2.1 Page allocation

k/OS divides the K16's 24-bit address space into 256 64-KB pages (`$00`..`$FF`). The kernel uses the lowest pages and reserves the top of RAM for kernel-owned use. ROM occupies the top of the 24-bit space and is shared with the K16 firmware.

| Page | Use | Notes |
|---|---|---|
| `$00` | Kernel | Vectors, sysvars, TCB pool, KLIB table, stack, work area |
| `$01` | Kernel heap region #1 | Always present, 64 KB |
| `$02..$1F` | User task pages (Digital) | 30 slots |
| `$02..$3F` | User task pages (EMU) | 62 slots |
| `$40..$FF` | Kernel heap growth pool (EMU only) | 192 pages = up to 12 MB |
| `$B0..$CF` | Video RAM | Hardware-mapped |
| `$DD..$DF` | I/O peripherals | Video mode, keyboard, terminal |
| `$E0..$FF` | ROM | Lookup tables, K16 firmware, k/OS code |

The runtime user-page ceiling is held in `KOS_USER_PAGE_END` and selected by the host detection code in `_InitKernel` based on the value of `KOS_HOST`.

### 2.2 Page `$00` layout

| Range | Size | Contents |
|---|---|---|
| `$0000..$01FF` | 512 B | TRAP/INT vector table (128 slots x 4 bytes) |
| `$0200..$023F` | 64 B | Kernel sysvars and scheduler globals |
| `$0240..$025F` | 32 B | `BT_NAME` task-name staging buffer |
| `$0260..$03DF` | 384 B | Volume table (Phase 16 + Part 22; 6 x 64-byte slots A..F) |
| `$03E0..$03EF` | 16 B | FAT cache state and dir/dirent caches (Phase 16, Part 22) |
| `$03F0..$03F3` | 4 B | `HEAP_TID_QUERY` and `HEAP_RBT_REGION` (Phase 14 Part 3, kos_defs.inc r40) -- scratch for `_HeapStatsByTid` / `_ReapByTid` walks. Relocated 17 May 2026 from `$0330..$0333` after the page-$00 audit revealed `$033x` was inside the live volume table (Gotcha 4.26). |
| `$03F4..$03F5` | 2 B | `DISKFREE_CLUSTER` -- Part 34 scratch for `_VolFreeClusters`: current cluster # being inspected, survives the `_FATGetEntry` call that clobbers D0/D1/D2/X0/X1. |
| `$03F6..$03F7` | 2 B | `DISKFREE_COUNT` -- Part 34 scratch for `_VolFreeClusters`: running tally of free clusters during the FAT scan. |
| `$03F8..$03F9` | 2 B | `DISKFREE_LIMIT` -- Part 34 scratch for `sys_diskfree`: caches the FAT scan's upper bound (first invalid cluster #) so `_VolFreeClusters` doesn't reload `VOL_TOTAL_CLUSTERS` and add the base each iteration. ~8K-cycle saving per call on a 1MB volume. |
| `$03FA..$03FF` | 6 B | Reserved (was part of `POOL_NAME_BUF` in Part 22; freed in Part 23) |
| `$0400..$047F` | 128 B | Counting-semaphore pool (Part 20b) |
| `$0480..$04D6` | 87 B | FD scratch (Part 22 — relocated from `$0370` after volume-table expansion overlap; see Gotcha 4.25). Declarations live in `kos_fs_defs.inc` as of Part 36 (previously in `kos_fs_fd.asm`). |
| `$04D8..$04E3` | 12 B | FE scratch — `sys_exec` page-byte / chain-state slots (Part 36 — relocated from `$03BC` after the slot was found to overlap VOL_SLOT_F+$1C, smashing F:'s `VOL_BLOCKREAD_PTR` on every `sys_exec`; see Gotcha 4.47). Declarations live in `kos_fs_defs.inc`. |
| `$04E4..$07FF` | 796 B | Reserved (kernel growth). `KERNEL_ZP_NEXT_FREE` marks the start of this region. |
| `$0800..$277F` | 7.5 KB | TCB pool (63 x 128 bytes) |
| `$2780..$27BF` | 64 B | `KBD_RING_BUF` -- keyboard ring storage (Phase A) |
| `$27C0..$9FFD` | 30.4 KB | Kernel work area |
| `$9FFE..$9FFF` | 2 B | KLIB internal state (xorshift seed) |
| `$A000..$A0FF` | 256 B | KLIB jump table (64 entries x 4 bytes) |
| `$A100..$A1FF` | 256 B | Reserved (GLIB jump table -- future) |
| `$A200..$BBFF` | 7.5 KB | Kernel work area (continued) |
| `$BC00..$BDFF` | 512 B | `FS_BUF_SECTOR` -- kernel sector scratch (Phase 16) |
| `$BE00..$BFFF` | 512 B | `FS_BUF_FAT` -- FAT cache backing store (Phase 16) |
| `$C000..$FFFD` | 16 KB | Kernel stack region (stack grows down from $FFFE) |
| `$FFFE` | -- | `KERNEL_STACK_TOP` -- initial X3 |

The reorganisation in v0.5 (kos_defs.inc r23) moved `KERNEL_STACK_TOP`
from `$BFF0` to `$FFFE`, reclaiming the upper-half-of-page-$00 region
that previous revisions left unused. The Phase 16 filesystem scratch
buffers now sit immediately below the stack region, both 512-byte
aligned at sector boundaries. Part 22 grew the volume table from
3 to 6 slots (host bays C..F); Part 22 r9 also relocated FD scratch
out of the table's expanded range after a silent-collision bug
(Gotcha 4.25). Part 36 (18 May 2026) relocated FE scratch for the
same reason (Gotcha 4.47) and consolidated all FD_* and FE_*
declarations into `kos_fs_defs.inc` — the kernel `.asm` files no
longer declare absolute page-$00 addresses. See the "ZERO PAGE MAP
— RULES FOR ADDING ALLOCATIONS" section in `kos_defs.inc` for the
canonical layout and the prevention rules for the recurring
collision-bug pattern.

### 2.3 Vector table (`$0000..$01FF`)

The first 128 dwords of page `$00` are dispatch slots for both TRAP calls and IRQs. Each slot holds a 24-bit jump target (`Y` byte at offset 0, `X` low/high at offset 2/3). The hardware jumps through the appropriate slot on TRAP or INT entry.

Slots `$0000..$0023` are reserved for IRQs and the INT dispatcher; slots `$0024..$0083` hold the syscall handlers (currently TRAPs 9..32). See section 5 for the full syscall list.

### 2.4 Kernel system variables (`$0200..$025F`)

| Address | Size | Symbol | Purpose |
|---|---|---|---|
| `$0200` | word | `SYS_TICKS` | 30 Hz tick counter, low word of a 32-bit value. Together with `SYS_TICKS_HI` at `$0202` wraps every ~4.5 years. (Part 30 r34-r36: promoted from 16-bit on 14 May 2026; `_TimerIRQ` now does ADD low / ADC hi.) |
| `$0202` | word | `SYS_TICKS_HI` | High word of the 32-bit system tick counter. (Was `SYS_FLAGS`, renamed in Part 30 r36/r37, 14 May 2026 — slot was written once at boot and never read, so it was repurposed.) |
| `$0204` | word | `KBD_HEAD` | Keyboard ring buffer head (write index; producer-only) |
| `$0206` | word | `KBD_TAIL` | Keyboard ring buffer tail (read index; consumer-only) |
| `$0208` | word | `CURRENT_TCB` | Pointer to running TCB (low word) |
| `$020C` | word | `READY_HEAD` | Head of the ready queue (TCB low word) |
| `$0210` | word | `TASK_COUNT` | Number of active tasks |
| `$0212..$021A` | 5 words | `BT_*` | Scratch slots used by `_BuildTask` |
| `$021C` | word | `KOS_HOST` | Host type: `HOST_DIGITAL` or `HOST_EMU` |
| `$021E..$0223` | 6 B | `PUTDEC_BUF` | Scratch for `sys_putdec` |
| `$0224..$022F` | 6 words | `KOS_PAGE_*` / `HEAP_*` | Heap configuration and statistics |
| `$0230` | word | `KOS_USER_PAGE_END` | Runtime user-page ceiling (host-dependent) |
| `$0232` | word | `KERNEL_STATE` | Scheduler liveness flag (see section 4.3) |
| `$0238` | word | `FOREGROUND_TCB` | Phase B: TID of the foreground shell (the one currently visible). 0 = no foreground (no shells registered). Updated by `sys_setforeground` and the `_SwitchForeground*` helpers. |
| `$023A` | word | `FIRST_SHELL_TID` | Phase B: TID of the first-registered shell, used as the anchor for `_SwitchForegroundByIndex` (Ctrl-1..0 direct-index switching). Set on the first `sys_register_shell` call; left unchanged when subsequent shells register. |
| `$0240..$025F` | 32 B | `BT_NAME` | Caller-staged task name buffer (Phase 15) |

Slots from `$0260` upward hold the filesystem state:

- `$0260..$03DF` -- volume table (6 × 64-byte slots: A:, B:, C:, D:, E:, F:)
- `$03E0..$03EF` -- FAT cache identity (sector, drive, dirty flag) and dir/dirent caches
- `$03F0..$03F3` -- heap-helper scratch (`HEAP_TID_QUERY`, `HEAP_RBT_REGION`)
- `$03F4..$03F9` -- `sys_diskfree` scratch (Part 34: `DISKFREE_CLUSTER`, `DISKFREE_COUNT`, `DISKFREE_LIMIT`)
- `$03FA..$03FF` -- reserved (kernel growth)
- `$0400..$047F` -- counting-semaphore pool (Part 20b)
- `$0480..$04D6` -- FD scratch (relocated in Part 22 after volume-table expansion; declarations in `kos_fs_defs.inc` as of Part 36)
- `$04D8..$04E3` -- FE scratch (`sys_exec` page-byte / chain-state slots; relocated in Part 36 after collision with VOL_SLOT_F surfaced, Gotcha 4.47)
- `$04E4..$07FF` -- reserved (kernel growth)

See section 5 for the filesystem syscall layer overview, and section 11 for the disk-controller MMIO surface (Part 22+23).

`BT_NAME` is an inline buffer used by `_BuildTask`: if its first byte is non-zero on entry, `_BuildTask` copies up to 31 bytes from it into the new TCB's `TCB_NAME` field, providing the task's human-readable name. Empty (or unset) `BT_NAME` leaves the name field zero-filled. Idle's name (`"idle"`) is written directly into `IDLE_TCB+TCB_NAME` by `_InitTCBPool`, bypassing `BT_NAME`.

### 2.5 Task page layout

Each user task lives in its own 64 KB page. Within that page:

| Range | Size | Contents |
|---|---|---|
| `$0000..$01FF` | 512 B | Task-local scratch (TCB ptr, TLS, syscall scratch) |
| `$0200..$FFEF` | 64 KB - 528 B | Task code + data |
| `$FFF0..$FFFF` | 16 B | Task stack |

Task-local page-zero slots:

| Offset | Symbol | Purpose |
|---|---|---|
| `$0000` | `MY_TCB_PTR` | Word -- TCB low word, set by `_BuildTask` |
| `$0004` | `TASK_ID` | Word -- TCB ID (1..62) |
| `$0006` | `TLS_ERRNO` | Word -- reserved for Phase 4+ |
| `$0008` | `TLS_FLAGS` | Word -- reserved for Phase 4+ |
| `$000A` | `TLS_SCRATCH0` | Word -- syscall scratch |

The stack starts at `$FFF0` (top of task page, leaving 16 bytes for the optional argv block) and grows downward. Task code execution starts at `SPAWN_ENTRY_OFFSET = $0200`.

---

## 3. Process Model

### 3.1 The Task Control Block

Each task is described by a 128-byte TCB allocated from a static pool at `$00:$0800..$00:$277F`. The pool holds 63 TCBs:

- TCB #0 at `$0800` is reserved for the idle task (`IDLE_TCB`).
- TCBs #1..#62 at `$0880..$2700` are user task slots.

A TCB is referenced by its low-word address (e.g. `$0880` for the first user TCB). The high page byte is always `$00`.

### 3.2 TCB layout

| Offset | Size | Field | Meaning |
|---|---|---|---|
| `$00` | word | `TCB_SAVED_X` | Saved `X3` (task's stack pointer when not running) |
| `$02` | word | `TCB_SAVED_Y` | Saved `Y3` (low byte = task's primary page) |
| `$04` | word | `TCB_PAGE_COUNT` | Number of pages owned (low byte used) |
| `$06` | word | `TCB_NEXT_TCB` | Next TCB in ready queue (low word) |
| `$08` | word | `TCB_WAKE_TICK` | `SYS_TICKS` value at which to wake (sleep) |
| `$0A` | word | `TCB_STATE` | One of `TS_*` values |
| `$0C` | word | `TCB_PRIORITY` | Reserved (Phase 2: always 0) |
| `$0E` | word | `TCB_ID` | Task ID 1..62 (monotonic since boot, never recycled) |
| `$10` | word | `TCB_QUANTUM` | Remaining time slice |
| `$12` | word | `TCB_FLAGS` | Task flags. Bit 0 = `TF_PRIV` (privileged); bit 3 = `TF_HAS_BACKBUF` ($0008) -- task is a registered shell with a back-buffer (Phase B). Other bits reserved. |
| `$14` | word | `TCB_EVENT_MASK` | Pending events bitmap |
| `$16` | word | `TCB_PARENT_ID` | Parent's TCB ID (0 = kernel) |
| `$18` | word | `TCB_EXIT_CODE` | Exit code (valid in `TS_DEAD`) |
| `$1A` | word | `TCB_WAIT_ID` | Child TID this task is waiting on |
| `$1C` | word | `TCB_YIELD_COUNT` | Voluntary `sys_yield` count |
| `$1E` | word | `TCB_PREEMPT_COUNT` | Involuntary preemptions (timer) -- low word of a 32-bit counter |
| `$20` | word | `TCB_SEM_NEXT` | Next-waiter ptr in semaphore wait queue (Part 20b) |
| `$22` | word | `TCB_PREEMPT_COUNT_HI` | High word of 32-bit preempt counter (Phase B, 13 May 2026). Wraps at ~4 years @ 30 Hz. Offset $22 is outside imm5 range so accesses use mode-01 `[XY+D]`. |
| `$24..$4B` | 40 B | `TCB_RESERVED` | Growth space |
| `$4C` | word | `TCB_BACKBUF_PTR` | Phase B: 24-bit pointer (offset+page) to this shell's back-buffer in heap. Valid iff `TF_HAS_BACKBUF` set. |
| `$4E` | word | `TCB_BACKBUF_OFFS` | Phase B: write cursor offset within back-buffer (0..6399) |
| `$50` | word | `TCB_SHELL_NEXT` | Phase B: next shell in the singly-linked ring (TCB low word). Used by `_SwitchForegroundNext/Prev`. |
| `$52` | word | `TCB_SHELL_GEOM` | Phase B: encoded geometry (rows in high byte, cols in low byte). Currently always $5050 for 80×80. |
| `$60..$7F` | 32 B | `TCB_NAME` | Null-padded task name |

**Phase B field semantics.** When `TF_HAS_BACKBUF` is set, all four shell fields ($4C/$4E/$50/$52) are valid. The output syscalls test `TF_HAS_BACKBUF` at entry: if clear, they emit directly to the terminal MMIO; if set, they route via `_BackbufPutChar`, which writes to the back-buffer and also emits to the terminal only when this task is the foreground shell. See section 9 (Foreground switcher).

### 3.3 Task states

| Value | Symbol | Meaning |
|---|---|---|
| 0 | `TS_READY` | On the ready queue, eligible to run |
| 1 | `TS_BLOCKED` | Sleeping until `TCB_WAKE_TICK` <= `SYS_TICKS` |
| 2 | `TS_DEAD` | Has exited; TCB and pages await reclamation |
| 3 | `TS_UNUSED` | Slot is free in the pool |
| 4 | `TS_WAITING` | Blocked in `sys_wait` until child exits |
| 5 | `TS_SEMWAIT` | Blocked on a counting semaphore (Part 20b) |

### 3.4 Task lifecycle

A task progresses through these states:

```
   _BuildTask                           sys_exit
       |                                    |
       v                                    v
   TS_READY <----- _Schedule ---------> TS_DEAD
       |            ^                       |
       |            |                       v
       v            |              _ReapDeadTask
   TS_BLOCKED ------+              (via sys_wait)
   TS_WAITING                              |
                                           v
                                       TS_UNUSED
```

`_BuildTask` (in `kos_tcb.asm`) constructs a fresh TCB, allocates its primary page, prepares a fake INT frame at the top of the task's stack, and links it into the ready queue. The "fake INT frame" trick lets the task be activated by the same `RTI` mechanism the timer IRQ uses for context restore, so the very first run looks identical to any subsequent resume.

When a task transitions out of `TS_DEAD` into `TS_UNUSED`, `_ReapDeadTask` (kos_tcb.asm r22+) runs the full teardown:

1. If the dying task is a registered shell, unlink it from the shell ring, retarget the foreground if necessary, repaint from the new foreground's back-buffer, and free that shell's back-buffer allocation.
2. **Phase 14 Part 3b reap hook (May 2026):** call `_ReapByTid(victim.TID)` to free every kernel-heap block stamped with the dying task's TID (`BH_OWNER_TID`). TID 0 (`OWNER_KERNEL`) is skipped via early `BEQ`. This step protects against user `.COM`s that leak; their allocations are reclaimed automatically when they exit cleanly or are killed externally. See §6.5.
3. Unlink the TCB from the ready ring.
4. Release the task's primary page back to the page pool.
5. Mark `TCB_STATE = TS_UNUSED`.

The reap is bracketed with `PUSH XY1 / POP XY1` since `_ReapByTid` uses XY1 internally as its region-descriptor scratch and the surrounding ring-unlink code needs XY1 = victim TCB ptr.

### 3.5 The scheduler

`_Schedule` (in `kos_sched.asm`) is the round-robin scheduler. It walks the ready queue starting from `READY_HEAD` and picks the first task in `TS_READY`. If there are none -- every task is sleeping or waiting -- it picks `IDLE_TCB`.

The scheduler is called from:

- **`_TimerIRQ`** (timer preemption): every 30 Hz tick.
- **`sys_yield`**: voluntary yield.
- **`sys_sleep`**: task transitions to `TS_BLOCKED`.
- **`sys_exit`**: task transitions to `TS_DEAD`.
- **`sys_wait`**: task transitions to `TS_WAITING`.
- **`sys_semtake`**: task transitions to `TS_SEMWAIT` when count would
  go negative (Part 20b).
- **`sys_spawn`**: returns to scheduler so the new child can be
  scheduled in.

`_Schedule` does NOT save outgoing register state -- that's the caller's responsibility. The caller sets up an INT frame on the stack (with `PUSH SR`, etc.) before calling `_Schedule`, and `_Schedule` returns by writing a new `CURRENT_TCB` and falling through to a context-restore that ends in `RTI`. See section 4 for the full context-switch dance.

### 3.6 Idle task

`IDLE_TCB` at `$0800` represents a special "no real task" state. Idle has no code and no useful saved state -- instead, when `_Schedule` selects `IDLE_TCB`, the restore site detects this and jumps to `_RestoreIdle` instead of doing a normal `RTI`. This re-establishes `X3 = KERNEL_STACK_TOP`, `Y3 = $00`, sets `KERNEL_STATE = KERN_STATE_RUN`, enables interrupts, and falls into `_IdleLoop`, which is just `BRA _IdleLoop`. The next timer IRQ preempts the idle and re-runs `_Schedule`.

This design fixes a subtle bug from earlier revisions: `IDLE_TCB` saved-state could become stale because `_Schedule` itself uses the kernel stack in a way that overwrites idle's "saved" frame. By treating idle as a fresh-start entry rather than a normal restore, the bug is structurally avoided.

---

## 4. Boot and Runtime Lifecycle

### 4.1 Boot sequence

The K16 starts execution at `$FF:$0000` (the reset vector). k/OS's boot path is:

```
1. Start (in kos_boot.asm)
       +- Sets X3 = KERNEL_STACK_TOP, Y3 = $00
       +- CALL24 _InitVectors      ; install syscall handlers first
       +- CALL24 _InitKernel       ; bring up sysvars, TCBs, heap, KLIB
       +- _RawPuts boot_msg        ; "Booting k/OS\n" (Part 30 r44)
       +- JMP24  _P2Main           ; smoke test or first user task

2. _InitKernel
       +- Zero kernel sysvars (SYS_TICKS, SYS_TICKS_HI, KOS_HOST,
       |  KERNEL_STATE -> BOOT, etc.)
       +- CALL24 _InitTCBPool      ; mark all TCBs TS_UNUSED, build idle
       +- CALL24 _DetectHost       ; probe $E0:$2468
       +- CALL24 _InitMemConfig    ; set page count and ceilings
       +- CALL24 _InitHeap         ; build first heap region in page $01
       +- CALL24 _InitKLib         ; copy ROM template to $A000, seed PRNG
       +- CALL24 _InitFS           ; zero volume table, install backends,
       |                            ; probe-mount A: and B: (Phase 16)
       +- RET

3. _P2Main runs the active user task. As of Phase 16.7, kosh
   (the k/OS shell) is the primary user task — built and handed
   off here as the system's interactive entry point. kosh lives
   in `kosh/kosh.asm`, replacing the earlier
   `Test/kos_p15_kosh_smoke.asm` smoke harness.

4. _IdleLoop is entered when no tasks are runnable, or as the
   final destination of any boot path that needs the scheduler
   running. _RestoreIdle promotes KERNEL_STATE = RUN and EINTs.

5. The first timer IRQ fires _TimerIRQ which advances SYS_TICKS,
   wakes any sleepers, and calls _Schedule. From here on, normal
   preemptive scheduling runs.
```

`_InitVectors` runs BEFORE `_InitKernel` so that any TRAP triggered during initialisation has a real vector to dispatch through. The default vectors all point at `bad_trap` (in `kos_bad_trap.asm`), which prints a diagnostic and halts.

### 4.2 Host detection

`_DetectHost` distinguishes EMU from Digital by probing for the SHL lookup ROM at `$E0:$2468`:

- On Digital, this address holds `$2468` (the SHL of `$1234`).
- On EMU, the lookup ROM region is unmapped and reads back as `$00`
  (or is otherwise invalid).

The result is stored in `KOS_HOST`. `_InitMemConfig` then uses this to set:

- `KOS_PAGE_COUNT`: 32 (Digital) or 64 (EMU).
- `KOS_USER_PAGE_END`: `$1F` or `$3F`.
- `HEAP_BYTES_FREE` and other heap initial values.

This is the only point in k/OS where Digital and EMU differ at runtime; everywhere else, the kernel operates identically.

### 4.3 The KERNEL_STATE flag

`KERNEL_STATE` at `$00:$0232` tracks whether the scheduler is ready to deliver timer IRQs and route them through context- switch machinery. Two values:

| Constant | Value | Meaning |
|---|---|---|
| `KERN_STATE_BOOT` | 0 | Pre-scheduler. Bare kernel on kernel stack. Timer IRQs unsafe. |
| `KERN_STATE_RUN` | 1 | Scheduler live. Tasks running. Timer IRQs OK. |

Set to `BOOT` in `_InitKernel`. Promoted to `RUN` by `_RestoreIdle` immediately before its `EINT`. Once promoted, never demoted.

The flag is consulted by `KLIB_DELAY_MS` (which would otherwise hang at boot time) and is intended to be consulted by future syscalls that need a real task context. It also has diagnostic value -- knowing whether the scheduler is up is useful in panic dumps and debug output.

### 4.4 Atomic kernel sections

Most syscalls run with interrupts disabled during their critical sections, then re-enable them at exit. The pattern is:

```asm
sys_thing:
                PUSH    SR, XY3         ; capture caller's IE state
                DINT                    ; atomic from here
                ; ... kernel work ...
                RTI                     ; restores caller's IE
```

This is called the **non-leaf** syscall pattern. It's used by `sys_yield`, `sys_exit`, `sys_sleep`, `sys_spawn`, `sys_wait`, and the I/O syscalls that pump multi-byte data.

The simpler **leaf** syscall pattern is used by syscalls that neither sleep nor switch context -- they just read or write a small piece of state. They use plain `RET` and don't touch IE:

```asm
sys_thing:
                LOADP   D0, Y3, [#TASK_ID]
                CLC
                RET
```

`sys_getpid`, `sys_putchar`, `sys_getchar` are leaf syscalls.

The distinction matters because non-leaf syscalls fake an INT frame (via `PUSH SR / DINT`) so they can join the scheduler's restore machinery. Leaf syscalls don't need this -- they always return to the same task that called them.

---

## 5. Syscall Reference

All syscalls are invoked with `TRAP #n`. The TRAP number selects a vector slot in the table at `$00:$0000`, which holds the 24-bit jump target of the handler.

The general syscall ABI is:

| Aspect | Convention |
|---|---|
| Mechanism | `TRAP #n` |
| Argument 1 | `D0` |
| Argument 2 | `D1` |
| Argument 3 | `D2` |
| Pointer args | `XY0`, `XY1`, `XY2` |
| Result | `D0` |
| Error flag | `C` -- `C=0` OK, `C=1` failure |
| Error code | `D0` set to one of `ERR_*` |

Error codes (defined in `kos_defs.inc`):

| Constant | Value | Meaning |
|---|---|---|
| `ERR_OK` | `$0000` | Success (`C=0` always; this is the "no-error" code) |
| `ERR_BADCALL` | `$FFFF` | Vector not initialised |
| `ERR_BUFFER_FULL` | `$FFFE` | Line buffer full |
| `ERR_INVALID` | `$FFFD` | Invalid argument |
| `ERR_NOMEM` | `$FFFC` | Page allocation failed |
| `ERR_NOSLOTS` | `$FFFB` | TCB pool full (or sem pool full, Part 20b) |
| `ERR_TOOBIG` | `$FFFA` | `sys_spawn` length out of range |
| `ERR_BADARG` | `$FFF9` | Bad argument |
| `ERR_NOTCHILD` | `$FFF8` | `sys_wait` on non-child TID |
| `ERR_DEADLOCK` | `$FFF7` | `sys_wait` would deadlock |

**Register preservation (V2 ABI; expanded Part 34, 18 May 2026).** Every
syscall, regardless of class (leaf or non-leaf), must preserve the
following caller registers across the `TRAP`:

| Register | Class | Across syscall? |
|---|---|---|
| `D0` | result / first arg | **NOT preserved** — holds result |
| `D1` | second arg / partial-progress return | **PRESERVED** (Part 34 expansion) |
| `D2`, `D3` | callee-saved | **PRESERVED** |
| `XY0` | pointer arg / scratch | **NOT preserved** — caller-saved |
| `XY1` | pointer arg / callee-saved | **PRESERVED** (Part 34 expansion) |
| `XY2` | callee-saved | **PRESERVED** |
| `X3` | stack pointer | restored by syscall machinery |
| `Y3` | task primary page | restored by syscall machinery |
| `SR` | flags | `C` conveys success/failure; other flags undefined |

**Compliance status.** As of Part 36 (18 May 2026), the V2 ABI is
fully audited and enforced across all 37 syscall handlers. The original
D2/D3/XY2 preservation rule was audited in Part 20a (8 May 2026; see
Gotcha 4.23 and `Syscall_ABI_Audit_2026-05-08.md`). The expanded D1 and
XY1 preservation requirement was established in Part 34 (18 May 2026)
when sys_diskfree shipped as the first handler built to the new
contract, and was rolled out across the remaining 14 violators in
Part 36 (see `Syscall_ABI_Audit_2026-05-18.md` for the violator list
and fix strategy). Callers may now rely on the contract for every
syscall.

**Input-arg / return-register clarification.** A callee-preserved
register may be legitimately *consumed* or *produced* by a specific
syscall when that syscall's own contract documents it as an input
argument or a return register. The handler's documented signature
overrides the default preservation rule for those registers only.
Examples:

- `sys_read` / `sys_write` / `sys_dirent`: `D1` is the input count
  or index; the handler consumes it. `sys_write` additionally returns
  the bytes-written count in `D1`.
- `sys_rename`: `XY1` is the input pointer to the new path; the
  handler consumes it.
- `sys_diskfree`: `D1` is a return register (total clusters); preserved
  across the handler's own EINT gate via internal PUSH/POP, but
  the *caller's* incoming D1 is overwritten by definition since
  D1 is the return.
- `sys_heapstats`: `D0`/`D1`/`D2`/`D3` are all return registers.

All registers not documented as input or return for the specific
syscall remain unconditionally preserved.

**Why D1 and XY1 were added.** Two motivating cases. (a) sys_write
(Part 34) returns `D1` = bytes-written-before-failure when `C=1` —
the partial-progress reporting pattern (§11.6). For this to be useful
the caller needs to assume `D1` survives the TRAP, which means every
handler now needs to preserve it. (b) FAT-walking syscalls like
sys_diskfree internally call `_FATGetEntry` (which clobbers X1) but
are called by code that legitimately holds row-cursor or buffer
pointers in XY1; without explicit preservation, every such caller
needed paranoid PUSH/POP around every FS syscall.

**Application code** relies on this contract: kosh and other user
code stash state in D1/D2/D3/XY1/XY2 across `TRAP` boundaries. A
syscall that violates this rule is a silent corruption bug; see
K16 ISA Gotchas #31 (clobbered D2/D3 in sys_read) and Gotcha 4.45
(TRAP handlers must explicitly preserve XY1) for examples.

For non-leaf syscalls (which yield to the scheduler), preservation
is automatic — the standard `PUSH SR / DINT / PUSH D / PUSH XY0 /
PUSH XY1 / PUSH XY2 / ... / RTI` shape saves and restores everything.
For leaf syscalls, the implementation must `PUSH D2, XY3` (and `D1`,
`D3`, `XY1`, or `XY2` if used) at entry and `POP` them after the
SR-gated EINT block at exit — `POP Dn` does not modify flags, so the
carry-bit result survives the restore. A leaf syscall that returns a
value in `D1` (e.g. sys_write's partial-progress D1) must PUSH/POP D1
around the EINT gate as well, because the gate itself uses D1 as
scratch to read `KERNEL_STATE`.

### 5.1 Console I/O

**Output routing (summary; full mechanism in §13.2).** The seven output
syscalls (`sys_putchar`, `sys_puts`, `sys_putln`, `sys_putdec`,
`sys_puthex`, `sys_clear`, `sys_setcursor`) check `TF_HAS_BACKBUF` on the
calling task's TCB and route accordingly:

| Caller class | TF_HAS_BACKBUF | Terminal MMIO | Back-buffer |
|---|---|---|---|
| Non-shell task | clear | yes | n/a (no back-buffer) |
| Foreground shell | set, `TCB_ID == FOREGROUND_TCB` | yes | yes (dual emit) |
| Background shell | set, `TCB_ID != FOREGROUND_TCB` | no (silent) | yes |

`sys_clear` and `sys_setcursor` carry ANSI escape sequences that bypass
`_BackbufPutChar` — they only affect the terminal, never the back-buffer.

**Why this matters for syscall callers.** From the calling task's
perspective every output syscall behaves identically — the routing is
transparent, the return value is the same, and the only observable
difference for a background shell is that nothing appears on the terminal
until that shell becomes foreground (at which point the back-buffer is
repainted). Application code does not need to know whether it is currently
foreground or background.

**Kernel-side smokes** that run before any shell has registered must
**not** call these output TRAPs — `FOREGROUND_TCB` is meaningless at
that point and dereferencing it crashes deep inside the handler. Use
`CALL24 _RawPuts` / `_RawPutDec` from `kos_rawio.asm` instead. See
Gotcha 4.44.

#### `sys_putchar` -- TRAP #10 [LEAF]

Write one byte to the terminal.

```
In:       D0       byte to emit (low 8 bits)
Out:      C = 0
```

#### `sys_getchar` -- TRAP #11 [LEAF]

Read one byte from the keyboard. Blocks until a key is available.

```
In:       (none)
Out:      D0       received byte (low 8 bits)
          C = 0
```

**Mechanism (Phase A, 13 May 2026; updated Part 30 r33, 14 May 2026).** The MMIO keyboard register at
`$DE_0000` is drained by `_KbdTick` (inline in `_TimerIRQ`) on every
30 Hz tick and pushed into a 64-byte SPSC ring buffer in page `$00`
(`KBD_RING_BUF` at `$2780`, indexed by `KBD_HEAD`/`KBD_TAIL`).
`sys_getchar` is a thin wrapper around `_RingWaitPop` (in
`kdrv/kos_kbd.asm`), which spins on the ring until non-empty.

The Part 30 r33 (14 May 2026) revision changed `_KbdTick` from
"read once per tick" to a **backpressure-aware drain loop**:
each iteration first checks `(KBD_HEAD+1) & MASK == KBD_TAIL`
(ring full); if so it exits without reading MMIO, leaving the
byte in the producer (the emulator's FKeyQueue, or the host
keyboard buffer on real silicon). Otherwise it reads MMIO and
dispatches; on non-zero it loops, on zero it exits. This lifted
the 30 cps paste cap to whatever the consumer (`sys_gets` echo
loop) can absorb, without overflowing the kernel ring.

This means type-ahead works: keystrokes that arrive while no task is
in `sys_getchar` are buffered until consumed, instead of being lost
to the read-and-clear MMIO. Worst-case latency from keystroke to
return is one tick (~33 ms).

Effective ring capacity is 63 bytes. Overrun is now back-pressured
to the producer rather than silently dropped at `_RingPush`.

**Invariant.** No code outside `_KbdTick` may read `$DE_0000` directly.
Doing so races with the ring producer (see Gotchas 4.37).

#### `sys_puts` -- TRAP #12 [NON-LEAF]

Write a nul-terminated string. Atomic against other writers via `DINT`/`EINT`.

```
In:       XY0      nul-terminated string
Out:      D0       byte count emitted (excluding nul)
          C = 0
```

#### `sys_putln` -- TRAP #13 [NON-LEAF]

Write a nul-terminated string followed by a CR/LF. Atomic.

```
In:       XY0      nul-terminated string
Out:      D0       byte count (string length + 2 for CR/LF)
          C = 0
```

#### `sys_gets` -- TRAP #14 [NON-LEAF]

Line-buffered keyboard read with simple editing (BS to erase, CR to terminate). Blocks until CR. Drains the keyboard ring one byte at a time via `_RingWaitPop`, so the type-ahead semantics described for `sys_getchar` apply here too.

```
In:       XY0      buffer
          D0       buffer size
Out:      D0       byte count (excluding nul terminator)
          C = 0    on success
          C = 1    D0 = ERR_BUFFER_FULL -- if line exceeded buffer
```

#### `sys_putdec` -- TRAP #15 [NON-LEAF]

Write a 16-bit value as decimal. Atomic.

```
In:       D0       value (0..65535)
Out:      D0       byte count emitted (1..5)
          C = 0
```

#### `sys_puthex` -- TRAP #16 [NON-LEAF]

Write a 16-bit value as 4 hex digits. Atomic.

```
In:       D0       value
Out:      D0       always 4
          C = 0
```

#### `sys_clear` -- TRAP #17 [NON-LEAF]

Clear the terminal (VT100 escape on EMU; line-feed flood on Digital).

```
In:       (none)
Out:      C = 0
```

#### `sys_setcursor` -- TRAP #18 [NON-LEAF]

Position the cursor (VT100 escape on EMU; ignored on Digital).

```
In:       D0       row (1-indexed)
          D1       column (1-indexed)
Out:      C = 0
```

### 5.2 Task control

#### `sys_getpid` -- TRAP #25 [LEAF]

Return the calling task's TCB ID.

```
In:       (none)
Out:      D0       task ID (1..62 for user tasks, 0 for idle)
          C = 0
```

Reads `TASK_ID` from the task's own page-zero slot -- single `LOADP` instruction, no kernel stack involvement.

#### `sys_yield` -- TRAP #26 [NON-LEAF]

Voluntarily release the CPU. The scheduler picks another runnable task. The caller remains `TS_READY` and will be scheduled in again on a future round.

```
In:       (none)
Out:      (when this task is rescheduled, control resumes after TRAP)
Clobbers: nothing -- full register and flag state preserved
```

This is the canonical non-leaf syscall: `PUSH SR / DINT / kernel work / Schedule / restore-incoming / RTI`. The `PUSH SR / DINT` prologue completes the fake INT frame so the routine can join the same restore machinery as the timer IRQ.

#### `sys_exit` -- TRAP #27 [NON-LEAF]

Terminate the calling task with the given exit code. Frees the task's pages, marks the TCB `TS_DEAD`, wakes any parent waiting on this task, and reschedules.

```
In:       D0       exit code (caller's choice)
Out:      Does not return.
```

If the parent is in `sys_wait`, it is woken with the child's exit code and the child's TCB is eagerly reaped (via `_ReapDeadTask`).

If there is no waiter, behaviour splits on whether the task is a registered shell:

- **Shell-mode task** (`TF_HAS_BACKBUF` set): eager-reap path. `_ReapDeadTask` runs, which unlinks the shell ring, retargets `FOREGROUND_TCB` and `FIRST_SHELL_TID` if the dying task was one of them, calls `_RepaintFromBackbuf` on the new foreground, frees the back-buffer, and clears the shell-related TCB fields. This is what makes a shell's `bye` / `BYE` command drop the user back to the next live shell (typically kosh) without manual `Ctrl-N`.
- **Non-shell task**: lazy-reap. The TCB stays in `TS_DEAD` until reaped by a future `sys_wait` or `sys_kill`. The lingering TCB preserves the exit code for a parent that may not yet have called `sys_wait`.

Children of an exiting task are orphaned -- their `TCB_PARENT_ID` is set to 0 (kernel). This avoids the parent being unable to reap children that outlive it.

**Single source of truth (Part 31, 14 May 2026).** All consequences of a registered shell dying — shell-ring unlink, foreground hand-back, repaint, back-buffer free, ready-ring unlink, slot recycle — are implemented inside `_ReapDeadTask` only. `sys_exit` and `_HandleDeadTCB` (the path used by `sys_kill`) just decide *when* to invoke it. This invariant means there is exactly one place to look when asking "what happens when a shell dies".

#### `sys_sleep` -- TRAP #28 [NON-LEAF]

Block the caller for at least `D0` ticks (~ 33 ms each).

```
In:       D0       tick count
Out:      C = 0
```

Sets `TCB_WAKE_TICK = SYS_TICKS + D0` and transitions to `TS_BLOCKED`. `_WakeSleepers` (called from `_TimerIRQ`) restores the task to `TS_READY` once the wake tick is reached.

`D0 = 0` is treated as `sys_yield`.

#### `sys_spawn` -- TRAP #29 [NON-LEAF]

Create a new user task. Allocates a primary page, copies the code image into it, builds a TCB, links it into the ready queue.

```
In:       XY0      source code image (in current task's page or kernel)
          D0       length in bytes (0..SPAWN_MAX_LEN = $FE00)
          XY2      pointer to a 32-byte name (nul-padded)
Out:      D0       child's task ID (1..62)
          C = 0    on success
          C = 1    D0 = ERR_NOMEM    no free pages
                   D0 = ERR_NOSLOTS -- no free TCBs
                   D0 = ERR_TOOBIG   length out of range
```

The child's PC starts at `primary:$0200`. Its stack is initialised to `primary:$FFF0`. The first `RTI` from the scheduler hands the child its first quantum.

#### `sys_wait` -- TRAP #30 [NON-LEAF]

Block until a child task exits, then reap its TCB and return its exit code.

```
In:       D0       child task ID, or 0 = "any child"
Out:      D0       exit code from child
          D1       child's task ID (useful when D0=0)
          C = 0    on success
          C = 1    D0 = ERR_NOTCHILD -- the given TID isn't a child
                   D0 = ERR_DEADLOCK -- the child is itself in sys_wait on us
```

If the named child is already `TS_DEAD`, returns immediately with the cached exit code. Otherwise transitions to `TS_WAITING` and yields. `sys_exit` of the child wakes the parent.

### 5.3 Heap

User tasks request memory from the kernel heap via five TRAPs that wrap the kernel-side `_kmalloc` / `_kfree` / `_krealloc` / `_HeapStatsFull` / `_HeapStatsByTid` routines (see section 6 for heap internals).

Every allocation is stamped with the running task's `TID` in the block header's `BH_OWNER_TID` field (Phase 14 Part 3a). When the task exits or is killed, the scheduler's `_ReapDeadTask` automatically frees every block tagged with that TID -- a leaky user program cannot indefinitely deplete the kernel heap.

#### `sys_kmalloc` -- TRAP #40 [LEAF]

Allocate a block from the kernel heap.

```
In:       D0       requested size in bytes (1..$FFDC)
Out:      XY0      24-bit pointer to payload (allocated block)
          C = 0    success
          C = 1    D0 = ERR_NOMEM -- no fit in any region
                   D0 = ERR_INVALID -- size out of range
```

The allocator rounds the request up to even bytes, then searches the free list first-fit. Splits the block if the leftover would form a usable free block (>= `BH_MIN_BLOCK = 10` bytes total -- 6-byte header + 4-byte minimum payload). Multiple regions are walked in order via `HR_NEXT_PAGE`. The wrapper is a leaf-with-DINT/EINT pattern (see gotcha 4.6) -- the EINT is gated on `KERNEL_STATE` so it's safe to call from boot context.

Each new allocation has `BH_OWNER_TID` set to `CURRENT_TCB`'s `TCB_ID`. If `CURRENT_TCB == 0` (boot context, no task yet running) the stamp is `OWNER_KERNEL = 0`.

#### `sys_kfree` -- TRAP #41 [LEAF]

Release a previously-allocated heap block.

```
In:       XY0      24-bit pointer (must match a sys_kmalloc return)
Out:      C = 0    success
          C = 1    D0 = ERR_INVALID -- bad pointer (out of heap range,
                                       not block-aligned, etc)
```

After freeing, attempts bidirectional coalesce with neighbouring free blocks. As with `sys_kmalloc`, the wrapper gates EINT on `KERNEL_STATE`.

#### `sys_krealloc` -- TRAP #42 [LEAF]

Resize an allocation. Equivalent to C's `realloc`.

```
In:       XY0      existing payload pointer, or zero
          D0       new size in bytes (1..$FFDC)
Out:      XY0      (possibly moved) payload pointer
          C = 0    success
          C = 1    D0 = ERR_NOMEM -- grow failed (original block preserved)
                   D0 = ERR_INVALID -- new size is zero, or pointer invalid
```

If the existing block has room for the new size, the same pointer is returned (in-place; no shrink-split yet). Otherwise the routine does malloc-copy-free: allocate a new block, byte-copy the old contents, free the old block. The new block's `BH_OWNER_TID` is stamped from `CURRENT_TCB`'s `TCB_ID` as for any fresh `sys_kmalloc`.

Edge cases:

- `realloc(NULL, n)` is equivalent to `malloc(n)`.
- `realloc(p, 0)` returns `ERR_INVALID` rather than acting as free (footgun guard -- ambiguous semantics in C).
- On `ERR_NOMEM` the original pointer is preserved per C realloc contract.

#### `sys_heapstats` -- TRAP #43 [LEAF]

Global heap statistics.

```
In:       (none)
Out:      D0       total free bytes across all regions (capped $FFFF)
          D1       total bytes currently allocated (capped $FFFF)
          D2       largest free block (capped $FFFF)
          D3       active region count
          C = 0
```

Walks the free lists across all regions; O(free-blocks). Used by kosh's `info` command and as the baseline reference for leak-detection tests.

#### `sys_heapstats_by_tid` -- TRAP #44 [LEAF]

Per-task heap usage.

```
In:       D0       target TID (0 = OWNER_KERNEL)
Out:      D0       preserved input TID (convenience for output formatting)
          D1       blocks owned by TID
          D2       total payload bytes owned (no headers)
          C = 0
```

Walks every region's blocks in physical block order. For each block with `BH_FLAG_USED` set AND `BH_OWNER_TID == query`, accumulates count and bytes. Skips free blocks. O(total-blocks) -- typically a few hundred blocks on a live system.

Used by kosh's `ps` command to populate the `BLOCKS` and `BYTES` columns. Querying TID 0 returns the kernel-owned allocations (boot-time work that survives task death).

### 5.4 Syscall summary

Part 20 (12 May 2026) reorganised the TRAP table into domain groups with per-group reserve. The previous flat-sequential layout grew by accretion and ended up with `sys_exec` semantically misclassified (sitting in the FS block) and `sys_format` having jumped over the sem-* reservation. The new grouping makes future syscall placement obvious.

**Group layout:**

```
TRAP  10..24   Console     (15 slots)   $0028..$0063
TRAP  25..39   Task        (15 slots)   $0064..$009F
TRAP  40..49   Memory      (10 slots)   $00A0..$00C7
TRAP  50..59   Sync        (10 slots)   $00C8..$00EF
TRAP  60..74   FS          (15 slots)   $00F0..$012B
TRAP  75..84   Device      (10 slots)   $012C..$0153
TRAP  85..127  Reserved    (43 slots)   $0154..$01FF
```

After Part 20, TRAP numbers are stable. New syscalls consume per-group reserve; if a domain's reserve fills, overflow comes from the Reserved tail.

**Full table:**

| TRAP | Name | Class | Notes |
|---|---|---|---|
| **— Console** | | | |
| 10 | `sys_putchar` | leaf | clobbers XY0 |
| 11 | `sys_getchar` | leaf | blocks |
| 12 | `sys_puts` | non-leaf | atomic |
| 13 | `sys_putln` | non-leaf | atomic |
| 14 | `sys_gets` | non-leaf | line-buffered, blocks |
| 15 | `sys_putdec` | non-leaf | atomic |
| 16 | `sys_puthex` | non-leaf | atomic |
| 17 | `sys_clear` | non-leaf | |
| 18 | `sys_setcursor` | non-leaf | |
| **— Task** | | | |
| 25 | `sys_getpid` | leaf | |
| 26 | `sys_yield` | non-leaf | |
| 27 | `sys_exit` | non-leaf | does not return |
| 28 | `sys_sleep` | non-leaf | |
| 29 | `sys_spawn` | non-leaf | |
| 30 | `sys_wait` | non-leaf | blocks |
| 31 | `sys_exec` | non-leaf | loads `.COM` from disk, spawns as new task; D0 = TID |
| 32 | `sys_kill` | DINT-leaf | Part 20: terminate by TID; ERR_PERM unless privileged or parent-of-victim; sweeps all TS_DEAD corpses on success |
| **— Memory** | | | |
| 40 | `sys_kmalloc` | leaf | EINT gated on KERNEL_STATE; stamps `BH_OWNER_TID` from `CURRENT_TCB` |
| 41 | `sys_kfree` | leaf | EINT gated on KERNEL_STATE |
| 42 | `sys_krealloc` | leaf | resize allocation; malloc-copy-free or in-place; preserves orig on ERR_NOMEM |
| 43 | `sys_heapstats` | leaf | global free/used/largest/regions |
| 44 | `sys_heapstats_by_tid` | leaf | per-TID block count + bytes; powers `ps`'s BLOCKS/BYTES columns |
| **— Sync** | | | |
| 50 | `sys_semcreate` | leaf | allocate a counting semaphore; D0 = handle |
| 51 | `sys_semtake` | non-leaf | P() / wait / down — blocks if count ≤ 0 |
| 52 | `sys_semgive` | leaf | V() / signal / up — wakes head waiter if any |
| 53 | `sys_semdestroy` | leaf | release a semaphore back to the pool |
| **— FS** | | | |
| 60 | `sys_open` | non-leaf | path → fd; CREATE/TRUNC/APPEND flags |
| 61 | `sys_close` | non-leaf | flushes dirent + FAT on dirty fd |
| 62 | `sys_read` | non-leaf | reads up to count bytes; D0 = bytes read or 0 at EOF |
| 63 | `sys_write` | non-leaf | writes up to count bytes; allocates clusters as needed. On failure (C=1), D1 = bytes-written-before-failure — see §11.6 partial-progress reporting |
| 64 | `sys_dirent` | non-leaf | iterates a volume's directory by index |
| 65 | `sys_format` | non-leaf | reformats a writable volume; writes fresh BPB+FAT+root, sets label, re-mounts |
| 66 | `sys_unlink` | non-leaf | delete a file; refuses if file is open in any fd table |
| 67 | `sys_rename` | non-leaf | rename file in place within a volume; cross-drive moves are kosh-side cp+unlink |
| 68 | `sys_diskfree` | non-leaf | scan FAT free list; D0 = free clusters, D1 = total clusters, D2 = cluster size (bytes). Part 34 |
| **— Device** | | | |
| 75 | `sys_setvidmode` | DINT-leaf | Part 20: acquire/release/change VID_MODE with single-owner ownership; auto-released on owner death |
| 76 | `sys_setforeground` | leaf | Phase B: set FOREGROUND_TCB to a specific TID. Privileged (TF_PRIV required). Used by kosh's `fg <tid>` command. |
| 77 | `sys_register_shell` | non-leaf | Phase B: allocate back-buffer, set TF_HAS_BACKBUF, insert into shell ring. First caller becomes foreground; subsequent callers register as background shells. C=1 / ERR_NOMEM if heap exhausted. |

Slots in per-group reserve (19..24, 33..39, 42..49, 54..59, 69..74, 78..84) and the Reserved tail (85..127) are uninitialised at boot and resolve to the bad-trap handler, which prints a diagnostic and halts.

**New Part 20 entries (sys_kill, sys_setvidmode):** see §5.6 and §5.7 below.

**Phase B entries (sys_setforeground, sys_register_shell):** see §13 (Foreground Switcher).

### 5.5 Semaphores (Part 20b)

k/OS provides counting semaphores for inter-task synchronisation.
The implementation lives in `kos_sem.asm`. A semaphore is a small
piece of kernel state representing a counter and a FIFO wait queue;
tasks coordinate by atomically decrementing (taking) and incrementing
(giving) the counter, blocking when the counter would go negative.

#### 5.5.1 Pool layout

A static pool of 16 semaphores lives at `$00:$03C8..$00:$0447`
(8 bytes per slot). The slot layout is:

| Offset | Size | Field | Meaning |
|---|---|---|---|
| `$00` | word | `SEM_COUNT` | Current count (signed; ≤ 0 implies waiters) |
| `$02` | word | `SEM_HEAD` | First waiter's TCB ptr (0 = no waiters) |
| `$04` | word | `SEM_TAIL` | Last waiter's TCB ptr (FIFO insertion) |
| `$06` | word | `SEM_FLAGS` | bit 0 = in-use; other bits reserved |

A semaphore **handle** is the absolute address of its slot
(low word; page is always `$00`). Handles are validated on every
operation against three criteria: in-range, 8-aligned, and in-use.

#### 5.5.2 Wait queue linkage

Each TCB has a `TCB_SEM_NEXT` field at offset `$20`. When a task is
parked on a sem wait queue, its `TCB_SEM_NEXT` points at the next
waiter (0 at tail). The task's `TCB_NEXT_TCB` still points at its
position in the ready ring; `_Schedule`'s state-skip scan handles
non-`TS_READY` entries, so the waiter is invisible to the scheduler
without ever being unlinked from the ready ring. This is symmetric
with how `TS_BLOCKED` (sys_sleep) and `TS_WAITING` (sys_wait) work.

#### 5.5.3 `sys_semcreate` -- TRAP #50 [LEAF]

Allocate a fresh semaphore from the pool.

```
In:       D0       initial count (signed; typically 0 or 1)
Out:      C = 0    D0 = handle (low word; page = $00)
          C = 1    D0 = ERR_NOSLOTS (pool full)
```

#### 5.5.4 `sys_semtake` -- TRAP #51 [NON-LEAF]

P() / wait / down. Decrement the counter; if the result would be
negative, block the calling task in `TS_SEMWAIT` and place it on the
sem's FIFO wait queue. The task resumes (with `D0 = ERR_OK`, `C = 0`)
when another task calls `sys_semgive` and selects this task as the
head of the queue.

```
In:       D0       handle (from sys_semcreate)
Out:      C = 0    D0 = ERR_OK (granted; possibly after blocking)
          C = 1    D0 = ERR_INVALID (bad handle)
```

#### 5.5.5 `sys_semgive` -- TRAP #52 [LEAF]

V() / signal / up. Increment the counter; if a waiter is queued, wake
the head waiter (transition to `TS_READY`, deliver `ERR_OK` into the
waiter's saved-D0 slot, clear C in the waiter's saved SR slot). Does
not block the caller -- control stays with the giver.

```
In:       D0       handle
Out:      C = 0    D0 = ERR_OK
          C = 1    D0 = ERR_INVALID (bad handle)
```

#### 5.5.6 `sys_semdestroy` -- TRAP #53 [LEAF]

Release a semaphore back to the pool. Refused if waiters are queued
(returns `ERR_BADARG`); the caller must drain the queue first.

```
In:       D0       handle
Out:      C = 0    D0 = ERR_OK
          C = 1    D0 = ERR_INVALID (bad handle)
                   D0 = ERR_BADARG (waiters queued -- drain first)
```

#### 5.5.7 Idiomatic uses

**Mutex (binary semaphore).** Initial count 1. The first task to take
proceeds; later tasks block until the holder gives. Used to serialise
access to a shared resource:

```asm
; setup
LOADI   D0, #1
TRAP    #TRAP_SEMCREATE             ; D0 = handle
STOREZ  D0, [#disk_mutex]

; critical section
LOADZ   D0, [#disk_mutex]
TRAP    #TRAP_SEMTAKE
... touch shared registers ...
LOADZ   D0, [#disk_mutex]
TRAP    #TRAP_SEMGIVE
```

**Counting semaphore for resource pools.** Initial count = N (number of
copies). Each take consumes one copy; each give returns one. Tasks
block when all copies are in use.

**Producer/consumer.** Two semaphores:

- `empty_slots` initial = N (free slots in the queue)
- `full_slots`  initial = 0 (filled slots)

Producer: `take(empty_slots) -- enqueue -- give(full_slots)`.
Consumer: `take(full_slots)  -- dequeue -- give(empty_slots)`.

#### 5.5.8 Implementation notes

The `sys_semtake` slow path uses a "decide + inline-block" split:
`_SemTakeTry` is a leaf helper that validates the handle, decides
whether to block, and (if so) enqueues the caller and decrements the
count. The actual block-and-schedule dance is inlined into
`sys_semtake`'s TRAP wrapper. This split is mandatory because a
subroutine that called `_Schedule` from inside its own PUSH/POP frame
would corrupt the resumed task's stack; see K16 ISA Gotcha #32 for
the full rationale. Future blockable kernel users (e.g. the disk
driver in `kos_fs_host.asm`) follow the same pattern.

---

### 5.6 sys_kill (Part 20; Part 31 update: reaps TS_DEAD corpses)

`sys_kill(tid)` at TRAP #32 terminates another task by TID. Unlike `sys_exit`, it does not context-switch — the caller resumes after the TRAP.

- **Live victim (TS_READY / TS_BLOCKED):** marks TS_DEAD, sets `TCB_EXIT_CODE` to `$FFFF` (the kill-sentinel), runs `_HandleDeadTCB` to finalise.
- **Already-dead victim (TS_DEAD; new in Part 31):** runs the same permission checks, then routes straight to `_HandleDeadTCB`. The original `TCB_EXIT_CODE` is preserved (not overwritten with `$FFFF`), so the cause of death stays informative.

Either path is followed by a TCB-pool sweep that reaps any other TS_DEAD corpses.

**ABI:**

| Reg | Role |
|---|---|
| D0 (in) | victim TID |
| D0 (out) | 0 on success, ERR_* on failure |
| C (out) | 0 success, 1 error |
| Preserves | D1, D2, D3, XY1, XY2 (V2 ABI; Part 36) |

**Errors:**

- `ERR_INVALID` — victim TID is 0 (idle), or victim == caller (use sys_exit for self).
- `ERR_NOTFOUND` — no task with that TID at all (TS_UNUSED slot).
- `ERR_PERM` — caller is not privileged and victim is not caller's child, OR victim is `TF_SYSCRITICAL`.
- `ERR_BUSY` — victim is TS_SEMWAIT (sem-queue unlink not yet implemented).

Pre-Part-31, an already-TS_DEAD victim returned `ERR_NOTFOUND`. The change was made because the user's natural mental model of `kill N` is "make TID N go away" — refusing because "it's already mostly gone" surprised users who launched a shell with `&` and watched it self-exit but linger as a corpse.

**Permission model.** `TCB_FLAGS` bit 1 (`TF_PRIV`) marks a task as privileged. A privileged task may kill any other task; a non-privileged task may only kill its own children (those whose `TCB_PARENT_ID` equals the caller's TID). The same rule applies to reaping a TS_DEAD corpse. kosh sets `TF_PRIV` on itself in `_P2Main` immediately after `_BuildTask` returns its TCB.

**Reaper sweep.** On every successful kill, sys_kill walks the user TCB pool and runs `_HandleDeadTCB` on every TS_DEAD slot. This catches the case "task self-exited via `run X &` without a parent waiter; corpse piled up on the ring". The cost (~600 cycles for the sweep) is invisible on a single-user system. The alternative (periodic sweep in `_TimerIRQ`) is held in reserve.

**Why no context switch.** The victim is never the running task (sys_kill rejects self-kill). Flipping its `TCB_STATE` to TS_DEAD makes the scheduler's state-skip walk skip it on the next scheduling decision, without needing an immediate reschedule.

**Auto-release of video mode.** `_HandleDeadTCB` calls `_VideoForceReset(victim_tid)` before anything else, so if the victim owned VID_MODE, the kernel forces it back to text mode and clears `VIDEO_OWNER_TID`. See §5.7.

**Shell death cleanup (Part 31).** When the victim is a registered shell (`TF_HAS_BACKBUF` set), `_HandleDeadTCB` → `_ReapDeadTask` handles the shell-ring unlink, foreground hand-back to the next shell in the ring (with `_RepaintFromBackbuf`), and back-buffer free. The caller of `sys_kill` does nothing special — the same cleanup applies whether the shell died via `bye` (sys_exit) or `kill` (sys_kill).

**Limitations (v1).**

- TS_SEMWAIT victims are refused with ERR_BUSY. The sem wait-queue uses TCB-internal linkage (`TCB_SEM_NEXT`) with no back-reference to which sem the task is waiting on. Killing the task without unlinking would leave a dangling pointer in the sem's queue. Adding the back-link plus the unlink path is mechanical; deferred until a real use case appears.
- Killing kosh itself (TID 1) is refused via `TF_SYSCRITICAL` (Part 28, r16) — kosh sets this flag at boot and sys_kill rejects any TF_SYSCRITICAL victim with `ERR_PERM`, regardless of caller privilege.

### 5.7 sys_setvidmode (Part 20)

`sys_setvidmode(mode)` at TRAP #75 mediates access to the VID_MODE MMIO register (`$DD0000`). Single-owner ownership model with acquire/release semantics.

**ABI:**

| Reg | Role |
|---|---|
| D0 (in) | requested mode (0..3) |
| D0 (out) | 0 on success, ERR_* on failure |
| C (out) | 0 success, 1 error |
| Preserves | D1, D2, D3, XY1, XY2 (V2 ABI; Part 36) |

**Errors:**

- `ERR_INVALID` — mode > 3.
- `ERR_BUSY` — caller wants mode != 0 but another task owns VID_MODE.
- `ERR_PERM` — caller wants to release (mode=0) but doesn't own VID_MODE.

**Mode values.** Defined in `kdrv/kos_video.asm`:

| Constant | Value | Meaning |
|---|---|---|
| `VID_MODE_TEXT` | 0 | text mode (graphics panel collapsed) |
| `VID_MODE_1280x720_MONO` | 1 | 1bpp 1280×720 |
| `VID_MODE_640x480_VGA` | 2 | 8bpp VGA palette 640×480 |
| `VID_MODE_640x480_RGB` | 3 | 8bpp rainbow palette 640×480 |

**Semantics by call form:**

- `sys_setvidmode(mode != 0)` — acquire / change.
  - Unowned: set `VIDEO_OWNER_TID := caller_TID`, write `VID_MODE := mode`, success.
  - Owned by caller: just write `VID_MODE := mode` (mode change), success.
  - Owned by other: `ERR_BUSY`.

- `sys_setvidmode(0)` — release.
  - Owned by caller: clear `VIDEO_OWNER_TID`, write `VID_MODE := 0`, success.
  - Already unowned: idempotent success.
  - Owned by other: `ERR_PERM`.

**Auto-release on death.** Both `sys_exit` and `_HandleDeadTCB` (used by sys_kill) call `_VideoForceReset(dying_TID)`. If the dying task owns VID_MODE, the kernel writes `VID_MODE = 0` and clears `VIDEO_OWNER_TID`. The screen returns to text mode automatically — no task action required.

**Enforcement model.** The driver is a **convention layer**, not enforcement. The hardware MMIO at $DD0000 is accessible to any task that knows the address; well-behaved tasks go through `sys_setvidmode`, ill-behaved tasks can bash it directly. A direct bash bypasses ownership tracking, so the kernel won't auto-restore text mode when the bashing task dies. Hardware enforcement (microcode trap or page-level write protection) would close the hole; not worth doing for the single-user system today.

**VID_PAGE not mediated.** The framebuffer page register at $DC0000 is still task-bashable. The implicit policy is "the VID_MODE owner is also entitled to bash VID_PAGE for framebuffer flipping". Future multi-task graphics would need a `sys_setvidpage` syscall.

**Example.** Cube4's startup (`Gfx-Cube.asm`):

```asm
                LOADI   D0, #2                  ; VID_MODE_640x480_VGA
                TRAP    #TRAP_SETVIDMODE
                BCS     .vid_busy               ; ERR_BUSY → bail
                ; ... initialise framebuffer ...
                BRA     frame                   ; main loop

.vid_busy:
                LEA     XY0, msg_vid_busy
                TRAP    #TRAP_PUTLN
                LOADI   D0, #1
                TRAP    #TRAP_EXIT
```

---

## 6. Kernel Heap

The kernel heap provides byte-granular dynamic allocation. Kernel code calls `_kmalloc` / `_kfree` directly (24-bit pointer ABI). User tasks reach the same allocator through `sys_kmalloc` (TRAP #40) and `sys_kfree` (TRAP #41), described in section 5.3.

### 6.1 Layout

The heap occupies dedicated 64 KB **regions**, one per page. The first region is at page `$01` (always present). On EMU, additional regions can be allocated from the growth pool at pages `$40..$FF`.

Each region has a 16-byte descriptor at offset `$0000`:

| Offset | Size | Field | Purpose |
|---|---|---|---|
| `$00` | word | `HR_SIZE` | Usable byte count (`$FFE0`) |
| `$02` | word | `HR_FLAGS` | Bit 0 = `INITIALISED`, rest reserved |
| `$04` | word | `HR_FREE_HEAD` | First free block offset, or 0 |
| `$06` | word | `HR_NEXT_PAGE` | Next region's page byte, or 0 |
| `$08` | word | `HR_BYTES_FREE` | Cached free byte count |
| `$0A..$0D` | 4 B | reserved | |
| `$0E` | word | `HR_MAGIC` | `$4B16` ("K6"  kernel heap v6) |

The block area runs from `$0010` to `$FFEF`. The last 16 bytes (`$FFF0..$FFFF`) are reserved as an end-of-page sentinel.

### 6.2 Block headers

Every block (free or used) is preceded by a 6-byte header (Phase 14 Part 3a, May 2026):

| Offset | Size | Field | Purpose |
|---|---|---|---|
| `$00` | word | `BH_SIZE` | Payload size in bytes (even, >= 4) |
| `$02` | word | `BH_FLAGS` | Bit 0 = `USED`, bit 1 = `LAST` |
| `$04` | word | `BH_OWNER_TID` | Owning task's TID; 0 = `OWNER_KERNEL` (allocations made when `CURRENT_TCB == 0`) |

Free blocks store a 24-bit `next_free` pointer in the first 4 bytes of payload (Y byte, then X word -- the natural K16 LOADXY ordering).

Allocations are rounded up to even and floored to 4 bytes. `BH_MIN_BLOCK = 10` (6 header + 4 minimum payload).

The header grew from 4 to 6 bytes in Part 3a to support per-task ownership tracking. Existing call sites used symbolic offsets (`BH_NEXT_Y`, `BH_NEXT_X`, etc.) so the layout change required no code changes outside `kos_defs.inc`. The 2-byte cost per allocation is paid once per block lifetime; coalescing recovers it on free.

### 6.3 Algorithm

`_kmalloc` does first-fit search of the free list. If the chosen block is large enough that the leftover would form a usable free block (>= `BH_MIN_BLOCK = 10` bytes total), the block is split. Otherwise the entire block is handed out.

Once a block is selected, `_kmalloc` reads `CURRENT_TCB` (page-$00 sysvar at `$0208`). If non-zero, it dereferences to read `TCB_ID` and stamps that into `BH_OWNER_TID`. If `CURRENT_TCB == 0` (boot context, scheduler not yet running) the stamp is `OWNER_KERNEL = 0`. This means every USED block in the heap carries a record of which task allocated it, queryable via `_HeapStatsByTid` / `sys_heapstats_by_tid`.

`_kfree` looks up the block's header, marks it free, then attempts bidirectional coalesce with neighbouring free blocks. Coalescing keeps fragmentation manageable. The block's `BH_OWNER_TID` value is left unchanged on free; consumers must filter on `BH_FLAG_USED` before reading owner.

`_krealloc` resizes an allocation. In-place if the existing block is large enough (no shrink-split yet); otherwise malloc-copy-free. `realloc(NULL, n)` acts as `malloc(n)`; `realloc(p, 0)` returns `ERR_INVALID` (footgun guard, not free). On `ERR_NOMEM` the original pointer is preserved per C realloc contract.

`_HeapStatsByTid` walks every region in physical block order. For each block with `BH_FLAG_USED` set AND `BH_OWNER_TID == query`, accumulates count and bytes. O(total-blocks); typically a few hundred blocks on a live system.

`_ReapByTid` walks the same way but calls `_kfree` on each match. After each `_kfree` it restarts the current region's walk from `HR_BLOCK_BASE` since `_kfree` may have coalesced the freed block with neighbours. O(N²) worst case per region but reap is one-shot at task death and N is small.

When the current region has no fit, `_kmalloc` walks `HR_NEXT_PAGE` to the next region. If no region fits, on EMU the allocator can grow by allocating a new region from the growth pool.

### 6.4 Heap API

| Function | In | Out |
|---|---|---|
| `_kmalloc` | `D0` = size | `XY0` = payload pointer (24-bit), `C=0`; `D0=ERR_NOMEM, C=1` on failure. Clobbers XY2. |
| `_kfree` | `XY0` = payload pointer | `C=0`; `D0=ERR_INVALID, C=1` on bad pointer. Clobbers XY2. |
| `_krealloc` | `XY0` = payload (or null), `D0` = new size | `XY0` = (possibly moved) payload, `C=0`; `D0=ERR_NOMEM, C=1` on grow failure (orig preserved); `D0=ERR_INVALID, C=1` if new size = 0. |
| `_HeapStats` | (none) | `D0` = total free bytes, `D1` = active region count, `C=0`. |
| `_HeapStatsFull` | (none) | `D0` = free, `D1` = used, `D2` = largest free block, `D3` = region count, `C=0`. |
| `_HeapStatsByTid` | `D0` = target TID | `D1` = blocks owned, `D2` = total bytes (payload, no headers), `C=0`. Clobbers D3, X1/Y1, X2/Y2. |
| `_ReapByTid` | `D0` = TID to reap | (none); frees every USED block owned by TID. Clobbers D0..D3, X0/Y0, X1/Y1, X2/Y2. |

**ABI note (added Part 3b debugging, May 2026):** `_kmalloc`, `_kfree`, and `_krealloc` all clobber `XY2`. The header comments historically said "Clobbers: D0, XY0" but the K16 caller-saved convention means anything not explicitly preserved is fair game. `_FindFit`, `_SplitBlock`, and other internal helpers use XY2 as scratch and do not save it. Callers must `PUSH XY2` if they need it across these calls.

These are the kernel-side entry points. User-task access is via:

- `sys_kmalloc` (TRAP #40), `sys_kfree` (TRAP #41) -- since Phase 14 Part 1
- `sys_krealloc` (TRAP #42), `sys_heapstats` (TRAP #43) -- since Phase 14 Part 2
- `sys_heapstats_by_tid` (TRAP #44) -- since Phase 14 Part 3b

All implemented as DINT-bracketed wrappers in `kos_heap.asm`.

### 6.5 Per-task ownership and automatic reap (Phase 14 Part 3, May 2026)

Each USED block in the kernel heap carries the TID of its allocating task in `BH_OWNER_TID`. This enables two operations:

1. **Per-TID introspection.** `sys_heapstats_by_tid(tid)` returns block count and byte total. Used by `kosh ps` to populate the BLOCKS and BYTES columns.

2. **Automatic reclamation on task death.** When a task exits (cleanly via `sys_exit` or externally via `sys_kill`), `_ReapDeadTask` is called by the scheduler. As of `kos_tcb.asm` r22, this routine calls `_ReapByTid(victim.tid)` near the end (at `.rdt_not_shell`, after any shell-specific cleanup, before the ready-ring unlink). Every block owned by the dying task is freed automatically. Coalescing during the reap recovers header overhead too.

A leaky user `.COM` therefore cannot indefinitely deplete the kernel heap -- its allocations are reclaimed when it exits (cleanly or otherwise). The byte-exact recovery observed during htest_loop validation (1880 bytes of payload+headers + 30 bytes of coalesce bonus = 1910 bytes reclaimed for a 5-block allocator that gets killed) confirms the pipeline is leak-free at the accounting level.

**TID 0 (`OWNER_KERNEL`) is never reaped.** Allocations made during `_InitKernel` (before any task exists) get stamped with TID 0 and survive task death by convention. The reap hook explicitly skips TID 0 via `BEQ .rdt_skip_heap_reap`. This protects kernel-internal data structures (volume table FAT cache scratch, etc.) from being torn down when idle "dies" (which shouldn't happen, but the guard is cheap insurance).



---

## 7. Page Allocation

The page allocator manages the user-task page region (`$02..$KOS_USER_PAGE_END`). It is a pair of routines in `kos_tcb.asm`: `_AllocPage` and `_PageInUse`.

### 7.1 No bitmap -- the TCB pool is the truth

There is no separate ownership bitmap. The set of pages currently in use is derived directly from the TCB pool: a page is owned if and only if some TCB in state `!= TS_UNUSED` has its `TCB_SAVED_Y` low byte equal to that page byte.

This is cheaper than maintaining a bitmap (no synchronisation, no consistency-update on every state change) at the cost of slightly more work per allocation. With a 62-slot TCB pool and pages allocated rarely (only on `sys_spawn`), the cost is negligible -- under a millisecond at 10 MHz in the worst case.

### 7.2 `_PageInUse`

```
In:       D0       candidate page byte ($02..ceiling)
Out:      C = 0    page is free (no live TCB owns it)
          C = 1    page is owned
          D0       preserved
Clobbers: flags only
```

Walks the user TCB pool (`USER_TCB_BASE` for `USER_TCB_COUNT` TCBs) and checks each non-`TS_UNUSED` slot. Early exit on first match. Cost ~ 160 cycles worst case.

`TS_DEAD` slots still count as owning their page. The page is released only when the TCB is reaped to `TS_UNUSED` (by `sys_wait`).

### 7.3 `_AllocPage`

```
In:       (none)
Out:      D0       lowest free page byte ($02..ceiling), C = 0
          D0       0, C = 1                if all pages exhausted (ERR_NOMEM)
Clobbers: D0
```

Scans candidate pages from `USER_PAGE_BASE = $02` upward, calling `_PageInUse` on each. Returns the first free page. Walks at most to `KOS_USER_PAGE_END` (host-dependent: `$1F` on Digital, `$3F` on EMU) before declaring exhaustion. Deterministic across boots.

### 7.4 Page release

There is no `_FreePage` routine. Pages are released implicitly when a TCB transitions to `TS_UNUSED`:

- `sys_exit` moves the TCB to `TS_DEAD`. The page is still
  considered owned (a future `_AllocPage` will skip it).
- `sys_wait` (or the kernel's cleanup path) reaps a `TS_DEAD`
  TCB to `TS_UNUSED`. From this point, `_PageInUse` no longer sees the page as owned, and the next `_AllocPage` call may return it.

This means a task whose parent never reaps it will hold its page forever. Future kernel work may include a "no-parent" reaper that collects orphaned dead tasks automatically.

### 7.5 Single-page tasks

The kernel does not currently support tasks owning multiple pages. The TCB's `TCB_PAGE_COUNT` field exists for future use (Phase 4+). Until then, every task's `TCB_PAGE_COUNT` is 1 and its single page is the one stored in `TCB_SAVED_Y`.

---

## 8. Interrupt Handling

### 8.1 IRQ routing

The K16 hardware delivers interrupts via the priority encoder (`74LS148`). IRQ7 is highest priority (timer); IRQ0 is lowest. On INT entry, the CPU pushes the return PC and a frame containing SR, jumps through `VEC_INT` (`$00:$0000`), which points at `_INTDispatch`.

### 8.2 `_INTDispatch`

`_INTDispatch` reads the priority from SR's LVL field (bits 6:4), indexes into a per-level handler table (`_IRQHandlerTable`), and jumps to the appropriate handler via `JMPT`.

Currently only the timer (level 0 = IRQ7) has a real handler; all other levels point at the same `_TimerIRQ` to keep the table trivial. Future devices (keyboard etc.) can populate other slots.

### 8.3 `_TimerIRQ`

The timer handler does the following on every tick:

1. Re-balance the kernel-stack frame from the `_INTDispatch`
   prologue.
2. Save the outgoing task's volatile registers and pivot to the
   kernel stack.
3. Save outgoing `X3` and `Y3` to the outgoing TCB.
4. Increment `SYS_TICKS` (32-bit since Part 30 r34 — low word ADD,
   high word ADC, both flag-transparent so the carry survives).
5. **Run `_KbdTick`** (Phase A, 13 May 2026; r33 drain loop, 14 May 2026):
   loop reading `$DE_0000` (read-clear MMIO) and dispatching non-zero
   bytes via `_KbdDispatch` → `_RingPush`. Each iteration first checks
   if the ring is full; if so it exits without reading MMIO, leaving
   the byte in the producer queue. Hot-path cost (no key): ~12 cycles.
   Worst-case (full drain to ring saturation): ~600 cycles at 10 MHz,
   trivial vs the 33 ms tick budget.
6. Call `_WakeSleepers` to move any expired sleepers from
   `TS_BLOCKED` back to `TS_READY`.
7. Call `_Schedule` to pick the next task.
8. If the chosen task is `IDLE_TCB`, jump to `_RestoreIdle`.
9. Otherwise restore from the new TCB's saved frame and `RTI`.

This is the same restore machinery that non-leaf syscalls reuse via their `PUSH SR / DINT` prologue.

`_KbdDispatch` is a **policy seam** for Phase B (foreground switcher).
In Phase A its body is empty — it falls through to `_RingPush`,
pushing every byte to the ring. Phase B will prepend a hot-key filter
(F1/F2/Ctrl-Tab) that consumes switcher keys before they hit the ring.
The `_TimerIRQ` `_KbdTick` block itself is unchanged between phases —
only `_KbdDispatch`'s body grows.

### 8.4 Atomic kernel sections

When kernel code needs to be uninterruptible -- typically while manipulating shared state like `READY_HEAD` or a TCB field -- it disables interrupts with `DINT` and re-enables with `EINT` (or implicitly via `RTI`). The longest atomic section is in `_TimerIRQ` itself, between the initial save and the final restore.

User tasks are expected NOT to disable interrupts. Doing so would delay the scheduler and is considered a programming error. `KLIB_DELAY_MS` checks for the IE bit and refuses with `ERR_INVALID` if the caller has masked interrupts.

---

## 9. The Boot Smoke Tests

k/OS includes a series of smoke tests that exercise different parts of the kernel. They are conditionally compiled into `kos_boot.asm` via `.INCLUDE`. Only one smoke is active at a time.

| File | Phase | Coverage |
|---|---|---|
| `kos_p3_console_smoke.asm` | Part 8 | Console syscalls, idle preemption |
| `kos_p3_spawn_smoke.asm` | Part 7 | `sys_spawn` and `sys_wait` |
| `kos_p9_heap_smoke.asm` | Part 9 | `_kmalloc` / `_kfree` |
| `kos_p10_klib_smoke.asm` | Phase 10 | KLIB jump table infra |
| `kos_p11_klib_tier1_smoke.asm` | Phase 11 | KLIB Tier 1 (strings, memory, ticks) |
| `kos_p12_klib_tier23_smoke.asm` | Phase 12 | KLIB Tier 2+3 (formatting, conversion) |
| `kos_p13_klib_tier4_smoke.asm` | Phase 13 | KLIB Tier 4 (PRNG, time, IE check) |
| `kos_p14_kheap_syscall_smoke_2.asm` | Phase 14 | `sys_kmalloc` / `sys_kfree` user syscalls |
| `kos_p14_kheap_user_smoke.asm` | Phase 14 | Kernel heap from user task context |
| `kos_p16_fs_smoke.asm` | Phase 16 | FAT16 mount, format, FAT walk, cluster ops |
| `kos_p16_fs_dir_smoke.asm` | Phase 16 | Directory operations |
| `kos_p16_fs_rw_smoke.asm` | Phase 16 | File read/write syscalls |
| `kos_p16_fs_exec_smoke.asm` | Phase 16 | `sys_exec` |
| `kos_sem_smoke.asm` | Part 20b | Semaphore primitives (non-blocking paths only) |

Note: the former `kos_p15_kosh_smoke.asm` was promoted to production at Phase 16.7 and now lives at `kosh/kosh.asm`. It's no longer a smoke test — it's the primary user task.

A smoke runs as `_P2Main` in the kernel context (no TCB, no task page). It typically prints test labels and PASS/FAIL counters, then jumps to `_IdleLoop` to hand off to the scheduler.

Smokes that don't need the scheduler can run entirely in `BOOT` state. Smokes that depend on real task context (preemption, sleep, scheduler) need to proceed via `_IdleLoop` and let the first idle entry promote `KERNEL_STATE` to `RUN`.

---

## 10. EMU vs Digital

k/OS runs on two targets:

- **Digital** is the hardware-accurate Hneemann simulator. It
  models the real K16's lookup ROMs, peripheral I/O, IRQ delivery, and address decoding. Treated as ground truth.
- **EMU** is a Free Pascal / Lazarus emulator that runs much
  faster but models some subsystems more loosely.

### 10.1 Differences

| Aspect | Digital | EMU |
|---|---|---|
| RAM | 2 MB (32 pages) | 16 MB (64 logical user-page slots) |
| User pages | 30 (`$02..$1F`) | 62 (`$02..$3F`) |
| Heap growth pool | None (single region) | 192 pages (`$40..$FF`) |
| RAM disk (B:) | 256 KB / 512 sectors (4 pages, `$1C..$1F`) | 1 MB / 2048 sectors (16 pages, `$30..$3F`) |
| ROM disk (A:) | 128 KB / 256 sectors (pages `$FC..$FD`) | 128 KB / 256 sectors (pages `$FC..$FD`) |
| Lookup tables | Real ROMs at `$E0..$F4` | Computed dynamically |
| Terminal | Dumb TTY (raw byte sink) | VT100 with cursor / colour |
| IRQ delivery | Hardware-accurate, fires on every cycle window | Looser timing; may not fire from boot context |
| Charset | ASCII-only safe | Tolerates UTF-8 in some paths |

### 10.2 Implications for testing

- **Always test on Digital.** EMU may pass tests that fail on real
  hardware. Digital is the reference.
- **Use only ASCII in `.TEXT` strings.** Multi-byte characters
  (em-dash, arrow, etc.) render as garbage on Digital.
- **EINT during smoke tests is risky.** From boot context, EMU
  may not deliver an IRQ at all; Digital will, and the IRQ routes through `_TimerIRQ` against a non-task context. This bit `KLIB_DELAY_MS` testing during Phase 13 -- use the `KERNEL_STATE` flag to detect and refuse cleanly instead.

---

## 11. Filesystem (Phase 16, Parts 22-25)

The filesystem layer adds FAT16 support to k/OS. Phase 16 introduced the core FAT16 implementation across `kos_fs.asm` (top-level mount, format, FAT operations, cluster allocation), `kos_fs_dir.asm` (8.3 name conversion, directory iteration, entry create/delete), `kos_fs_fd.asm` (per-task fd table and the file syscalls TRAPs 26..30), `kos_fs_exec.asm` (Piece 6 — `sys_exec`), `kos_fs_ram.asm` (RAM disk block backend), and `kos_fs_rom.asm` (ROM disk block backend). Filesystem-internal constants live in `kos_fs_defs.inc`.

Parts 22 and 23 added a host-disk subsystem: `kos_fs_host.asm` (block-layer backend serving drives C..F via the K16 disk-controller MMIO at `$DA0000`) and `kos_fs_host_mgr.asm` (kernel-side wrappers for the controller's management commands).

Part 24 extended host-disk management with `_HostRename` (renames a bay's bound file in place, keeping the mount intact) and `_HostBayName` (reads a bay's bound filename — used to default the FAT16 label when formatting a host disk). Part 24 also simplified mount semantics: bay-bind and FS-mount are now independent two-phase operations (see §11.6 of the FS Reference), removing the previous auto-rollback when FS-mount failed.

Part 25 added two filesystem syscalls — `sys_unlink` (TRAP #66) and `sys_rename` (TRAP #67) — plus three new host-management helpers — `_HostFOpen` / `_HostFRead` / `_HostFClose` — that implement a streaming file-load surface used by kosh's `load` command. The kosh layer also gained a current working drive (CWD) model with bare drive-letter switching, a `cp`/`rm`/`mv` command family, the `load` command for ingesting host files, and human-readable error names via `_KoshPrintErr`.

Implementation status: all of Pieces 1–6 plus Parts 22, 23, 24, and 25 are complete and verified. See `kOS_FS_Reference v1.13` for the design specification.

### 11.1 Volume model

Six drive slots are reserved at boot:

| Drive | Slot address | Backend | Status |
|-------|--------------|---------|--------|
| A: | `$0260` | ROM disk (read-only) | Mounted at boot if ROM image valid |
| B: | `$02A0` | RAM disk (read/write) | Mounted on `_FormatVolume(B:)`; auto-format at boot |
| C: | `$02E0` | Host disk, bay 0 | EMU-only; mounted at boot per INI `[Disks] C=` |
| D: | `$0320` | Host disk, bay 1 | EMU-only; mounted at boot per INI `[Disks] D=` |
| E: | `$0360` | Host disk, bay 2 | EMU-only; mounted at boot per INI `[Disks] E=` |
| F: | `$03A0` | Host disk, bay 3 | EMU-only; mounted at boot per INI `[Disks] F=` |

Each slot is 64 bytes. The block backend is selected by function pointers (`VOL_BLOCKREAD_PTR`, `VOL_BLOCKWRITE_PTR`) installed at `_InitFS` time. This abstracts the FS layer from the underlying storage.

Volume slot layout (selected fields, see `kos_fs_defs.inc` for full):

| Offset | Width | Field | Notes |
|--------|-------|-------|-------|
| `$00` | byte | `VOL_PRESENT` | 1 if mounted |
| `$01` | byte | `VOL_READONLY` | 1 if read-only (ROM disk) |
| `$02` | word | `VOL_BYTES_PER_SECTOR` | cached BPB |
| `$04` | word | `VOL_SEC_PER_CLUSTER` | cached BPB (byte zero-extended) |
| `$06` | word | `VOL_RESERVED_SECTORS` | typically 1 |
| `$0A` | word | `VOL_FAT_START` | absolute sector of first FAT |
| `$0E` | word | `VOL_DATA_START` | absolute sector of cluster 2 |
| `$10` | byte | `VOL_NUM_FATS` | typically 1 for k/OS, 2 for Windows-formatted host disks |
| `$12` | dword | `VOL_TOTAL_SECTORS` | full volume sector count |
| `$16` | word | `VOL_BLOCKREAD_PTR` low | function pointer X half |
| `$18` | byte | `VOL_BLOCKREAD_PTR` high | function pointer Y half |
| `$1A` | word | `VOL_BLOCKWRITE_PTR` low | (matches BlockRead structure) |
| `$22` | 11 B | `VOL_LABEL` | cached BPB volume label |

### 11.2 Block backends

Each backend exposes `_BlockReadXxx(D0=sector, XY0=buffer)` and `_BlockWriteXxx(D0=sector, XY0=buffer)`. Both return C=0 on success, C=1 with `D0=ERR_IO` on failure.

| Backend | EMU sectors | Digital sectors | Notes |
|---------|-------------|-----------------|-------|
| RAM | 2048 (1 MB) | 512 (256 KB) | Pages `$30..$3F` (EMU) or `$1C..$1F` (Digital) |
| ROM | 256 (128 KB) | 256 (128 KB) | Pages `$FC..$FD`, fixed |
| Host | varies per file | (n/a) | EMU-only; backed by `disk\*.KOS` files via MMIO controller (Part 22) |

The host-specific RAM disk sizing is determined at format time via `KOS_HOST`. Host-disk size is whatever the underlying `.KOS` file is (`mkdisk` from kosh defaults to ≥64 sectors / 32 KB).

The host backend serialises its MMIO sequence via the `HOST_DISK_SEM` counting semaphore (Part 20b primitive) — see `kOS_FS_Reference v1.12` §11.4 for details.

### 11.3 FAT cache

A single-sector FAT cache lives at `FS_BUF_FAT` (`$BE00..$BFFF`). Cache state is tracked in three globals:

| Address | Width | Symbol | Purpose |
|---------|-------|--------|---------|
| `$03E0` | word | `FAT_CACHE_SECTOR` | absolute sector currently cached, or `$FFFF` if invalid |
| `$03E2` | byte | `FAT_CACHE_DIRTY` | 1 if cache contents differ from disk |
| `$03E3` | byte | `FAT_CACHE_DRIVE` | drive index of cached sector |

Cache rules:

- At any moment the cache holds zero or one FAT sector for one drive.
- On a cache miss (different sector or different drive), if the cache is dirty we flush it before loading the new sector.
- `_InitFS` invalidates the cache at boot.
- `_FormatVolume` invalidates the cache before re-mounting the volume.

The cache structure is sufficient for the linear scans that `_AllocCluster` performs and for the chain-walks that file I/O will need (Pieces 5+).

### 11.5 File descriptors

Each task has a private 8-entry file descriptor table at `user_page:$000C..$006B` (96 bytes, 12 bytes per entry). File descriptors are integer indices `0..7` returned by `sys_open` and consumed by `sys_close`, `sys_read`, `sys_write`. They are valid only within the task that opened them; passing an fd to another task is undefined.

The fd table physically lives in the running task's primary page, addressed via `Y3` (the per-task page register). Each entry layout:

| Offset | Width | Field | Notes |
|--------|-------|-------|-------|
| `$00` | byte | `FD_FLAGS` | OPEN, READ, WRITE, DIRTY, ROM bits |
| `$01` | byte | `FD_DRIVE` | 0=A:, 1=B:, 2=C: |
| `$02` | word | `FD_FIRST_CLUSTER` | first data cluster (0 if empty file) |
| `$04` | word | `FD_CURR_CLUSTER` | cached: current cluster for sequential I/O |
| `$06` | word | `FD_DIR_COOKIE` | dirent location for flush on close |
| `$08` | dword | `FD_POSITION` | byte offset within file |

Multi-cluster files maintain `FD_CURR_CLUSTER` as a cache: it advances by walking the FAT chain on read, and by allocating new clusters and chaining them on write. The full FAT walk happens only when crossing cluster boundaries.

### 11.6 File-syscall ABI

The Phase 16 file syscalls plus Part 25's sys_unlink/sys_rename and
Part 34's sys_diskfree all follow the carry-on-error convention common
to the rest of k/OS:

- `C = 0` on success; `D0` carries the meaningful return value (fd, byte count, TID, ERR_OK)
- `C = 1` on failure; `D0` carries an error code (`ERR_BADFD`, `ERR_NOTFOUND`, `ERR_IO`, etc.)

The caller pattern is:

```asm
                TRAP    #TRAP_READ
                BCS     .read_failed
                ; D0 = bytes read; 0 = EOF
.read_failed:
                ; D0 = ERR_*
```

`BCS` after the TRAP is mandatory before interpreting `D0`. On success, `D0` carries an unrelated value (the byte count, fd, or TID), so testing `D0` against a specific error code without first checking carry will misread.

The FS syscalls preserve **D1, D2, D3, XY1, XY2, XY3** across the call
per the expanded V2 ABI (§5). They clobber **D0, XY0, Y0** and all flags
except for the documented C return. sys_diskfree (Part 34) is the first
handler explicitly built to the expanded contract; older FS handlers
are pending audit (see §5 compliance note).

#### Partial-progress reporting

A bulk-I/O syscall that can fail partway through its work may report
how much work it completed before failing, by returning `C=1` with
`D0` = error code AND `D1` = bytes-completed-before-failure. This is
an extension of the basic C=0/C=1 convention, not a replacement: the
basic shape (C=0 success / C=1 error in D0) still holds, and callers
that ignore D1 on the error path remain correct.

**Currently in use:**

- `sys_write` (TRAP #63) — returns `D1` = bytes-written-before-failure
  on any C=1 mid-stream failure (e.g. `ERR_NOSPACE` after partial
  cluster fills, `ERR_IO` on a sector-write fault). Pre-flight failures
  (`ERR_BADFD`, `ERR_BADARG`) return with `D1=0`, which is correct by
  construction. Used by kosh's `load` command for the `wrote NKB then
  failed` user message on disk-full.

**Reserved for future adoption:**

- `sys_read` — natural fit for `D1` = bytes-read-before-failure on
  mid-buffer I/O errors. Not yet retrofitted (no bad-sector injection
  in the host backend; would ship as untested code path).
- `sys_puts` — natural fit once stdout becomes redirectable to a file
  (Phase 11). Currently can't fail in any way (terminal-only output).

The pattern is declared here so that future bulk-I/O syscalls have a
canonical shape, and so that current callers can adopt the richer
contract for `sys_write` without waiting for the others.

**Caller pattern for partial-progress-aware syscalls:**

```asm
                LOADI   D1, #N                  ; count
                MOVE    Y0, Y3                  ; buffer
                LOADI   X0, #buf_offset
                TRAP    #TRAP_WRITE
                BCS     .write_failed
                ; D0 = bytes written (== D1 input on full success)
                BRA     .write_ok
.write_failed:
                ; D0 = ERR_*
                ; D1 = bytes-written-before-failure (0 if pre-flight error)
                ; ... use D1 if reporting partial progress to user ...
```

The pre-flight-error case (`D1=0`) is intentionally indistinguishable
from "the failure happened on the very first byte". Callers that want
to report partial progress should phrase the message accordingly
(e.g. `"wrote 0KB then failed"` is the consistent shape, even if it
reads awkwardly — clients typically display `"failed"` alone when
D1=0).

### 11.7 Buffer-pointer convention

Syscalls that accept or return a data buffer (`sys_open` for the path string, `sys_read` / `sys_write` for the data buffer, `sys_dirent` for the destination DIRENT_INFO struct) read the 24-bit address from **`Y0` (page byte) + `X0` (offset word)**. The kernel saves both at TRAP entry and uses them verbatim.

The kernel does no page translation or validation. A caller that passes `Y0=#$00` directs the kernel to read from or write to *page `$00`* — which is the kernel's data page, containing the TCB pool, scheduler state, vector table, and FS buffers. This will not fault; it will silently corrupt kernel state.

The canonical user-side calling convention is:

```asm
                MOVE    Y0, Y3                  ; high byte = my task page
                LOADI   X0, #MY_BUFFER          ; offset within page
                LOADI   D1, #count
                TRAP    #TRAP_READ              ; (or WRITE / OPEN / DIRENT)
```

`Y3` holds the running task's page byte by k/OS convention (see §9.5 of the K16 Reference Manual). `MOVE Y0, Y3` is the only correct way to express "a buffer in *my* page". `LOADI Y0, #$00` is a frequent novice mistake; see `kOS_Gotchas` v1.5 entry 4.18.

**Where to place buffers.** The user-page memory map for Phase 16:

| Range | Use |
|---|---|
| `$0000..$00FF` | Page-zero per-task slots (FD_TABLE, MY_TCB_PTR, TLS) |
| `$0100..$01FF` | Reserved / unused |
| `$0200..` | User task code (copied here at task creation) |
| `..$FFEC` | Free for user data |
| `$FFEE..$FFFE` | User stack base (X3 = $FFEE at task entry) |

For data buffers larger than ~256 bytes, allocate well above the code body and below the stack — `$E000..$FEFF` is the recommended safe zone. **Do not place buffers in `$0200..$08FF`** unless certain that the task's code does not extend that far.

### 11.8 Filesystem error codes

Eleven error codes specific to FS operations (defined in `kos_defs.inc`):

| Constant | Value | Meaning |
|----------|-------|---------|
| `ERR_IO` | `$FFE7` | block read/write failed |
| `ERR_NOSPACE` | `$FFE6` | no free cluster |
| `ERR_NOTPRESENT` | `$FFE5` | no volume mounted in slot |
| `ERR_BADDRIVE` | `$FFE4` | drive index out of range |
| `ERR_READONLY` | `$FFE3` | write attempted on read-only volume |
| `ERR_INVALID_BPB` | `$FFE2` | volume present but BPB malformed |
| `ERR_NOFD` | `$FFE1` | per-task fd table full |
| `ERR_BADFD` | `$FFE0` | fd not open or wrong access mode |
| `ERR_NOTFOUND` | `$FFDF` | filename not found |
| `ERR_EXISTS` | `$FFDE` | filename already exists |
| `ERR_NOTEXEC` | `$FFDD` | file is not a valid `.COM` executable (Piece 6) |

`sys_dirent` returns `ERR_NOMORE` when called with an index past the end of the directory; it shares the carry-on-error convention.

`sys_exec` returns `ERR_NOMEM` when `_AllocPage` cannot find a free user page, and `ERR_NOSLOTS` when `_BuildTask` cannot allocate a TCB. Both are spec-defined and distinct from the FS-level codes above.

### 11.9 The `.COM` executable format

A k/OS `.COM` file is a **raw binary image** of a user task's primary code, exactly as it would appear in memory at offset `$0200` of the loaded task's page. There is no header, no relocation table, no symbol information. `sys_exec` copies the file's bytes verbatim from disk into a freshly allocated user page, starting at `user_page:$0200`, then enters the freshly built TCB at that entry point.

#### Assembly origin

`.COM` source files **must use `.ORG $0200`** at the top. This tells the assembler to resolve all internal labels to their final runtime offsets within the user page, so that page-relative absolute references (CALL16, JMP16, page-zero `LOADP`/`STOREP`) encode the correct values. Without `.ORG $0200`, internal labels resolve to wherever the assembler's section happens to start (typically inside ROM), and any 16-bit absolute reference will jump to the wrong place after the .COM is loaded into a user page.

#### Position-independence rules

Because the load address (`user_page` byte) is not known at assembly time, the **page byte** can never be hard-coded into a .COM. The K16 ISA gives several ways to express references that survive relocation:

| Construct | Page byte source | Safe in .COM? |
|---|---|---|
| `LEA XYn, label` | PC-relative — adopts current PC's page | ✓ |
| `BRA target`, `Bcc target` | PC-relative — same page guaranteed | ✓ |
| `CALLR subroutine` | PC-relative — same page guaranteed | ✓ |
| `CALL16 subroutine` (internal label) | PC's page (current code page) | ✓ *with `.ORG $0200`* |
| `JMP16 target` (internal label) | PC's page | ✓ *with `.ORG $0200`* |
| `LOADP D, Y3, [#addr]` | `Y3` (= user_page) | ✓ — addresses anywhere in the task's own page |
| `STOREP D, Y3, [#addr]` | `Y3` (= user_page) | ✓ |
| `TRAP #N` | Vector at `$00:VEC_*` — page-independent | ✓ |
| `CALL24 KLIB_xxx` | Fixed address in $00:$A000 jump table | ✓ — recommended for klib helpers |
| `CALL24 kernel_symbol` | 24-bit absolute (kernel ROM, fixed address) | ✓ but discouraged — couples .COM to kernel layout |
| `JMP24 kernel_symbol` | 24-bit absolute (kernel ROM, fixed address) | ✓ but discouraged — same coupling concern |
| `CALL24 internal_label` | 24-bit absolute, resolved at assembly time | ✗ — encodes ROM address, broken after relocation |
| `JMP24 internal_label` | 24-bit absolute, resolved at assembly time | ✗ — same problem |
| Any `LOADI Y, #>label` for an internal label | High byte of source-time address | ✗ — encodes ROM page byte |

The general rule is straightforward: any reference to an **internal** .COM label must be PC-relative (LEA, BRA, Bcc, CALLR) or page-relative (CALL16, JMP16, LOADP/STOREP). Any reference to a **kernel ROM** symbol can use absolute (CALL24, JMP24) because the kernel sits at a fixed ROM address. The `LOADI Y, #>label` pattern works only for kernel ROM labels (`#>label` becomes the ROM page byte $FE/$FF) — using it on an internal label would encode the assembler's source page rather than the runtime page.

#### Calls into kernel klib

KLIB is k/OS's shared kernel library — strings, memory, integer arithmetic, conversion, PRNG, time — exposed to .COM code through a **fixed-address jump table at `$00:$A000`** (see `kOS_KLIB_Reference`). Each `KLIB_xxx` symbol resolves to a stable page-zero address; the table contains a `JMP24` into the live implementation in kernel ROM.

```asm
                CALL24  KLIB_STRLEN             ; XY0 = string ptr; D0 = length
```

This is the **recommended** way for .COM code to reach kernel helpers:

- The encoded 24-bit address sits in page `$00` and is fixed at boot. It does not depend on the .COM's load location.
- The ABI is stable across kernel revisions. A future kernel can move `_KStrLen`'s implementation to a different ROM address; only the table entry changes, .COM binaries continue to work.
- No TRAP overhead — KLIB is essentially a function call, just one indirection slower than a direct CALL24 to ROM.

Klib helpers can also be reached as syscalls when one is exposed (TRAPs `sys_kmalloc`, `sys_kfree`, etc.). Use the TRAP form when the operation needs scheduler involvement, kernel-state gating, or any privileged action; use KLIB for pure library calls. Direct `CALL24` to a kernel ROM symbol that is *not* in the KLIB table is also legal but discouraged — it couples the .COM to kernel symbol layout and breaks if the kernel is rebuilt.

#### Forbidden patterns

Beyond the table above, .COM code must not:

- Reference data in its own page by absolute 24-bit address. (Use `LEA` for compile-time-known offsets, or `MOVE Yn, Y3` for the page byte and a `LOADI Xn, #offset`.)
- Modify `Y3`. The k/OS convention is that `Y3` permanently holds the running task's primary page byte; changing it disconnects the task from its own data.
- Assume `D0..D3` or `XY0..XY2` carry meaningful state at entry. They are zero-initialised by the fake INT frame in `_BuildTask`.

#### Memory map at entry

```
user_page:$0000..$00FF   per-task page-zero slots
                           $0000..$000B  reserved
                           $000C..$006B  FD_TABLE (8 fds × 12 bytes)
                           $006C..$00FF  TLS / future use
user_page:$0100..$01FF    reserved (Phase 17 argv area, currently unused)
user_page:$0200           .COM entry point — first instruction
                           ...
                           .COM body: code, then strings/data
                           ...
user_page:$xxxx..$FFEF    free for runtime data / heap / large buffers
user_page:$FFF0..$FFFE    initial stack region (X3 = $FFF0 at entry, grows down)
```

A .COM that opens files must zero its `FD_TABLE` before the first `sys_open` (because `_AllocPage` does not clear page memory). A future `mkcom` tool will auto-prepend a small `crt0`-style preamble that does this.

#### Size limit

The .COM file format itself imposes no maximum size. `sys_exec` rejects files larger than `SPAWN_MAX_LEN` ($FE00 = 65,024 bytes) — the largest body that fits below the user stack ($FFEE) when loaded at $0200. Files larger than this return `ERR_NOTEXEC`. Empty files (size 0) and files whose extension is not `.COM` (uppercase) also return `ERR_NOTEXEC`.

### 11.10 Implementation status (Phase 16)

| Piece | Status | Verifies |
|-------|--------|----------|
| 1: Volume table, mount probe | Complete | `_InitFS`, `_TryMount` |
| 2: Block layer, format | Complete | `_FormatVolume`, `_VolBlockRead`, `_VolBlockWrite`, `_ZeroBuffer` |
| 3: FAT cache, cluster ops | Complete | `_FATInvalidate`, `_FATFlush`, `_FATLoad`, `_FATGetEntry`, `_FATSetEntry`, `_AllocCluster`, `_FreeCluster`, `_ClusterToSector` |
| 4: Directory ops | Complete | `_DirNameToFat`, `_DirNameFromFat`, `_DirOpen`, `_DirRewind`, `_DirNext`, `_DirNextRaw`, `_DirLookup`, `_DirCreate`, `_DirDelete` |
| 5: File descriptors and syscalls | Complete | `sys_open`, `sys_close`, `sys_read`, `sys_write`, `sys_dirent` (TRAPs 60..64) plus 22 internal helpers |
| 6: sys_exec | Complete | `sys_exec` (TRAP 31) plus 4 internal helpers: `_ExecCheckExt`, `_ExecCopyChain`, `_ExecCopyOneSector`, `_ExecStageName` |

Four smoke tests cover the implementation: 13-test `kos_p16_fs_smoke.asm` (Pieces 1+2+3), 13-test `kos_p16_fs_dir_smoke.asm` (Piece 4), 14-test `kos_p16_fs_rw_smoke.asm` (Piece 5), and 7-test `kos_p16_fs_exec_smoke.asm` (Piece 6). The Piece 5 smoke includes a 600-byte multi-cluster RW test (T11) that exercises `_FdEnsureCluster` case (5) chain extension, `_AllocCluster` + `_FATSetEntry` chaining, and `_FdAdvancePosition` cluster walk on read — the most architecturally demanding code path in the FS.

T12 of the Piece 1+2+3 smoke (alloc until ERR_NOSPACE) is `O(N²)` on volume size and takes ~17 minutes on Digital due to simulator clock rate; Phase 17 will add a next-free-cluster hint to make this `O(N)`.

Phase 16 follow-on work remaining: kosh integration (`ls`, `cat`, `cp`, `rm`, `format`, `vol`, `run`), EMU-only RAM-disk save/load menu items, the external `mkromdisk` tool (build A: ROM image from a directory tree), and the external `mkcom` tool (assemble a single .asm file into a position-independent .COM). All deferred to Phase 17 boundary.

---

## 12. Coding Conventions

### 12.1 File-naming

| Pattern | Use |
|---|---|
| `kos_*.asm` | Kernel implementation modules |
| `kos_*.inc` | Shared constants and macros |
| `klib/kos_klib_*` | KLIB submodule files |
| `Test/kos_p*_smoke.asm` | Smoke tests |

### 12.2 Symbols

- **Public kernel symbols**: `_PascalCase` (e.g. `_Schedule`,
  `_TimerIRQ`).
- **Syscalls**: `sys_lower_case` (e.g. `sys_yield`).
- **KLIB internal**: `_KFunctionName` (e.g. `_KMul16x16_32`).
- **KLIB public**: `KLIB_UPPER_CASE` (e.g. `KLIB_STRLEN`).
- **Constants**: `UPPER_CASE` with type-grouped prefixes
  (`TCB_*`, `HR_*`, `BH_*`, `TS_*`, `ERR_*`, `TRAP_*`).

### 12.3 Local labels

Within a routine, labels start with `.` (e.g. `.loop`, `.done`). The K16 assembler scopes these to the parent label. Use descriptive names -- `.found` and `.not_found` are better than `.l1` and `.l2`.

### 12.4 Branch sizing

K16's short-branch form (`.S` suffix) is forward-only with a range of 0..+31 bytes. Use it for tight skips like skipping a single instruction. Anything that jumps over a multi-instruction block needs the long form (no `.S`). The assembler will reject out-of-range short branches at assembly time, but it's worth forming the habit.

### 12.5 Strings

Use `.TEXT` (not `.BYTE`) for string literals. `.TEXT` auto-pads to word boundary, which `.BYTE` does not -- odd-length `.BYTE` strings silently corrupt subsequent ROM contents.

Keep string literals ASCII-only. UTF-8 punctuation works on EMU but renders as garbled bytes on Digital.

Use `\n` only, never `\r\n` -- Digital interprets `\r\n` as two linebreaks and produces double-spacing.

### 12.6 Register-clobber discipline

Routines should document their input, output, and clobber sets at the top. A caller looking at the documented clobber set should be able to know exactly which of its own registers need PUSH/POP across the call.

When a routine uses `_KMul16x16_32` or `_KDiv10` internally, it must save and restore `D2` and `D3` if they hold caller-relevant data. This is the most common clobber-related bug source. See `kOS_Gotchas.md`.

---

## 13. Foreground Switcher (Phase B)

Phase B (13 May 2026) added a preemptive foreground-switcher to k/OS, allowing multiple shell tasks to share one terminal. The user can hop between shells with a hot-key; the foreground shell's output appears on screen in real time while background shells continue to run, with their output captured into per-task back-buffers. Pressing a switch key repaints the new foreground's back-buffer onto the terminal.

The design accepts two compromises in v1:

- **Background shells busy-spin.** They sit in `_GetGatedKey` polling `FOREGROUND_TCB` rather than blocking on a wait condition. Idle gets almost no time on multi-shell systems. A future revision should have `_GetGatedKey` call `sys_yield` instead of spin.
- **No scrollback restoration on switch.** The repaint draws the current state of the back-buffer; scrollback history within a buffer is not preserved beyond the 80×80 grid. ESC[3J is emitted before each repaint to clear the terminal's own scrollback so the new foreground starts clean.

### 13.1 What makes a task a shell

A task becomes a shell by calling `sys_register_shell` (TRAP #77). The syscall:

1. Allocates a 6400-byte back-buffer from the kernel heap (80 rows × 80 cols).
2. Stores the heap pointer in `TCB_BACKBUF_PTR` ($4C) and zeroes `TCB_BACKBUF_OFFS` ($4E).
3. Encodes 80×80 into `TCB_SHELL_GEOM` ($52).
4. Sets `TF_HAS_BACKBUF` (bit 3, value $0008) in `TCB_FLAGS`.
5. Inserts the calling TCB into the shell ring via `TCB_SHELL_NEXT` ($50).
6. If this is the first shell to register, sets `FOREGROUND_TCB` to the caller's TID and stores the TID in `FIRST_SHELL_TID` as the Ctrl-digit anchor.

On success returns C=0; on heap failure C=1 with `D0 = ERR_NOMEM`. The expected idiom from a shell program (e.g. BASIC v2.4):

```asm
TRAP    #TRAP_REGISTER_SHELL
BCC.S   .reg_ok
LOADI   D0, #99                 ; arbitrary non-zero exit code
TRAP    #TRAP_EXIT
.reg_ok:
; ... continue with shell main loop ...
```

### 13.2 Output routing

All seven output syscalls (`sys_putchar`, `sys_puts`, `sys_putln`, `sys_putdec`, `sys_clear`, `sys_setcursor`, `sys_putln`) test `TF_HAS_BACKBUF` at entry:

- **Not a shell** (`TF_HAS_BACKBUF` clear): fast path -- emit byte to terminal MMIO and return. Bit-identical to pre-Phase-B behaviour.
- **Shell + foreground** (`TCB_ID == FOREGROUND_TCB`): dual emit. Write to terminal MMIO AND call `_BackbufPutChar` to keep the back-buffer in sync.
- **Shell + background**: silent. Call `_BackbufPutChar` only; nothing reaches the terminal.

`sys_clear` and `sys_setcursor` bypass `_BackbufPutChar` -- they emit ANSI escape sequences which are not character-stream content.

### 13.3 `_BackbufPutChar` clobber discipline

`_BackbufPutChar` is called many times per output syscall, so it's written as a small fast routine rather than a full callee-preserves-everything function. Its clobber set:

| Register | Status |
|---|---|
| D0..D3 | Clobbered |
| XY0 | Clobbered (used to address the back-buffer) |
| XY1 | **Preserved** |
| XY2 | Clobbered (used to address the TCB) |
| XY3 | **Preserved** (stack) |
| Y3 | **Preserved** (task page anchor) |

**Shell byte loops that walk a buffer with XY1 (the common pattern) MUST PUSH/POP D0..D3 and XY2 around the call.** This is the most common Phase B bug source. See `kOS_Gotchas.md` 4.37.

### 13.4 LF semantics in the back-buffer

LF ($0A) in the back-buffer means Unix newline: advance row AND reset column to 0. Without the column reset, output prints in a staircase pattern. This was a polish-phase fix during Phase B development.

### 13.5 Foreground-gated input

`sys_getchar` and `sys_gets` route through `_GetGatedKey`:

1. Read `MY_TCB_PTR` from page-zero, fetch `TCB_FLAGS`.
2. If `TF_HAS_BACKBUF` is clear -- task is not a shell, drain straight from the keyboard ring (`_RingWaitPop`).
3. Otherwise compare `TCB_ID` with `FOREGROUND_TCB`. If not equal, spin (busy-wait until this shell becomes foreground).
4. When foreground, attempt `_RingPop`. On empty, loop back to step 3 (foreground status may have changed).

This gating is what makes background shells "pause" -- they spin without doing useful work, never seeing a keystroke.

Echoes within `sys_gets` are routed via `sys_putchar`, NOT via direct STOREB to the terminal MMIO -- this ensures the back-buffer captures echoed input, keeping it in sync with the terminal state at all times.

### 13.6 Repaint

`_RepaintFromBackbuf` is called whenever the foreground task changes. It:

1. Pre-scans the entire 6400-byte back-buffer to find the last non-blank byte; computes the row count needed for that content via repeated /80 subtraction.
2. Emits `ESC[3J` (scrollback clear) + `ESC[2J` (visible clear) + `ESC[H` (home cursor).
3. Walks the back-buffer for `row_count` rows, emitting each character with `ESC[r;cH` positioning where appropriate.

The pre-scan trimming avoids painting trailing blank rows, which would otherwise scroll the boot banner off the visible region of small terminals.

### 13.7 Hot keys

Hot-key dispatch happens in `_KbdDispatch` (`kos_kbd.asm`), which intercepts keystrokes BEFORE they reach the ring buffer. Recognised codes:

| Code | Source | Action |
|---|---|---|
| `$0E` | Ctrl-N, Ctrl-RightArrow | `_SwitchForegroundNext` -- one hop forward in the ring |
| `$10` | Ctrl-P, Ctrl-Shift-N, Ctrl-LeftArrow | `_SwitchForegroundPrev` -- one hop backward (Ctrl-Shift-N is a fallback for hosts that eat Ctrl-P) |
| `$81..$8A` | Ctrl-1..Ctrl-0 | `_SwitchForegroundByIndex` -- jump to the N-th shell starting from `FIRST_SHELL_TID`. Cycle-detection avoids wrap-around (Ctrl-3 in a 2-shell ring is silent no-op). |

Before any CMP, `_KbdDispatch` masks the high byte of the MMIO read with `LOW D0` -- the keyboard register is byte-wide but `LOADD` is 16-bit, so the upper byte is unspecified.

### 13.8 The shell ring

Shells form a singly-linked ring via `TCB_SHELL_NEXT` ($50). Each shell's `next` points to the next shell to be registered; the last-registered shell's `next` wraps back to the first. `_SwitchForegroundNext` follows one hop; `_SwitchForegroundPrev` walks the ring until it finds the TCB whose `next` matches the current foreground (the predecessor). In a 2-shell ring both end up at the other shell, which is correct.

### 13.9 Output: `ps` reflects shell status

The kosh `ps` command shows a per-task `FG` column:

- `*` -- this task is the foreground shell
- `s` -- this task is a registered shell but currently in the background
- `-` -- this task is not a registered shell (e.g. idle, or a non-shell .COM)

The `TICKS` column shows `TCB_PREEMPT_COUNT` as a 32-bit decimal (wraps at ~4 years @ 30 Hz). Use `TICKS` to spot tasks that aren't getting scheduled or to compute cumulative CPU share (per task / sum of all).

### 13.10 Shell death (Part 31)

When a registered shell task dies — whether via `sys_exit` (the shell calls `bye`/`BYE`), `sys_kill`, or a future reaper — `_ReapDeadTask` is the single point that handles all the cleanup. It is the **single source of truth** for what happens when a shell dies.

Inputs to `_ReapDeadTask` are unchanged: `X1:Y1` = victim TCB pointer. If the victim has `TF_HAS_BACKBUF` set:

1. **Shell-ring unlink.** Walk the singly-linked ring forward from the victim to find its predecessor. The walk is bounded by `MAX_SHELL_RING_LEN` (16) as a defence against corrupted next-chains. On corruption the unlink is skipped (better than infinite-looping in the kernel) but the back-buffer free and flag clear still run.
2. **Lone-shell case.** If `victim.TCB_SHELL_NEXT == victim` (victim was the only shell), `FOREGROUND_TCB` and `FIRST_SHELL_TID` are cleared. No retargeting or repaint.
3. **Multi-shell case.** Predecessor's `TCB_SHELL_NEXT` is set to victim's successor. If victim was the foreground:
   - `FOREGROUND_TCB := successor.TCB_ID`
   - `_RepaintFromBackbuf(successor)` paints the new foreground's back-buffer.
4. **Anchor retarget.** If `FIRST_SHELL_TID == victim.TCB_ID`, same retarget to successor.
5. **Back-buffer free.** `_kfree` releases ~2400 bytes back to the heap.
6. **Shell-field clear.** `TF_HAS_BACKBUF`, `TCB_SHELL_NEXT`, `TCB_BACKBUF_OFFS`, and `TCB_BACKBUF_PAGE` are zeroed on the victim TCB.

Then the routine falls through to the existing ready-ring unlink and `TS_UNUSED` mark.

**Callers do not handle any of this directly.** `sys_exit` decides between eager-reap (shells) and lazy-reap (non-shells) based on `TF_HAS_BACKBUF`. `_HandleDeadTCB` (the path used by `sys_kill`) just calls `_ReapDeadTask` at its tail. Neither has its own foreground-hand-back or shell-ring-unlink logic. This invariant is what makes the lifecycle understandable: when something goes wrong with shell death, the trail leads to one routine.

**Register clobber contract (Part 31 r21+).** `_ReapDeadTask` is now register-clean: it saves and restores `D0..D3`, `XY0`, `XY2` at entry/exit via `PUSH`/`POP`. Callers can rely on these registers surviving the call. `XY1` (the victim TCB pointer) is temporarily redirected to the new foreground TCB across the `_RepaintFromBackbuf` call but restored to the victim before return. `XY3` (kernel stack pointer) is unchanged.

---

## 14. kosh commands

This section documents the user-facing behaviour of kosh's built-in
commands. kosh's implementation is split across `kosh_cmds_*.asm`
files (§1.3); this section describes the contract from the user's
perspective — syntax, behaviour, output format — not the
implementation.

**Coverage.** This is a living section. Part 35 (18 May 2026)
documents `vol` and `ls`. The remaining commands — `cat`, `cp`, `rm`,
`mv`, `format`, `run`, `load`, `disks`, `mount`, `unmount`, `mkdisk`,
`rmdisk`, `rename`, `remount`, `ps`, `mem`, `info`, `uptime`, `ver`,
`tcb`, `peek`, `dump`, `help`, `exit`, `echo`, `clear`, `halt`,
`reboot`, plus bare drive-letter switching — will be filled in over
subsequent revisions.

### 14.1 `vol` — show volume disk usage

Displays a table of all six drive slots (A: through F:), showing
mount status, label, capacity, used and free space, and usage
percentage.

**Syntax:**

```
vol
```

No arguments. Reads from all six drive slots regardless of mount
state; unmounted slots show only the drive letter and `(not mounted)`.

**Sample output:**

```
Drive  Label          Total     Used     Free Use%
A:     (not mounted)
B:     KOS-RAM       1018KB      1KB   1017KB   0%
C:     FOO             30KB     22KB      8KB  73%
D:     TEST         15.85MB    333KB  15.53MB   2%
E:     WORKAREA       508KB        0    508KB   0%
F:     BIGDATA       1.98MB        0   1.98MB   0%
```

**Column layout:**

| Column | Width | Format |
|---|---|---|
| Drive | 2 + 5 pad | Drive letter + colon, left-aligned |
| Label | 13 + 1 pad | Volume label, left-aligned (max 11 chars + padding) |
| Total | 8 right-aligned | Human-readable size — see §15 *Human-readable size* |
| Used | 8 right-aligned | Same format |
| Free | 8 right-aligned | Same format |
| Use% | 4 right-aligned | Integer percentage 0..100, suffixed `%`. `0` (no `%`) shown for zero-byte values that aren't valid percentages |

Sizes are displayed in `<whole>.<fraction><unit>` form where the
fraction is shown only when the unit is MB or GB (cluster-sized
volumes always render whole KB without a decimal). Units cascade
through B → KB → MB → GB so the whole part fits 0..1023; values
under one KB show as raw bytes (`0`, `1`, etc.).

**Mechanism.** `vol` calls `sys_diskfree` (TRAP #68) on each drive
slot in turn, taking the cluster counts and size to compute totals
via `KLIB_BYTES_SPLIT` (slot 46) and `_KoshEmitSize`. The use
percentage is `Used × 100 / Total`, computed in cluster units
rather than bytes to avoid 32-bit division.

**Notes.**
- Drive letters in column 1 are shown for unmounted slots too —
  the user can see at a glance which bays are bound but not
  mounted.
- The `Use%` column shows `0%` for a freshly mounted empty volume;
  for an unmounted drive the column is suppressed entirely (no
  cell, since `Total` is unknown).
- Unmounted-slot rendering uses raw `_KoshEmitStrZ` rather than
  the column-aligned `_KoshEmitSize`, hence the visual difference.

### 14.2 `ls` — list files in current working drive

Lists files on the current working drive (CWD; see §15 *CWD*), one
per line, followed by a totals line showing file count, total used
space, and total free space.

**Syntax:**

```
ls
```

No arguments. Always lists CWD; `ls D:` is not yet supported (Part 35
backlog). Output shows files only — directories are not displayed
since k/OS does not yet support subdirectories (Phase 17 backlog).

**Sample output:**

```
HELLO.COM           36
NOTES.TXT          511
README.MD         7864
CONFIG.SYS         128
INVOICE.PDF       5120
DAILY.LOG         4096
TEST.DAT          1024

  7 file(s), 19KB used, 8KB free
```

**Column layout per row:**

| Column | Width | Format |
|---|---|---|
| Filename | 12 + 1 pad | 8.3 name, left-aligned in 11 columns |
| Size | 8 right-aligned | Raw byte count (no human-readable conversion) |

**Totals line format:**

```
  N file(s), <used> used, <free> free
```

- **N** is the count of regular file entries (excludes the volume-label
  entry that lives in slot 0 of the FAT16 root directory).
- **`<used>`** is the sum of file sizes shown as a human-readable size
  via `_KoshEmitSize` width=0 (raw mode — no padding; see Gotcha 4.46
  in `kOS_Gotchas`).
- **`<free>`** is the free space from `sys_diskfree`, same format.

**Mechanism.** `ls` iterates the root directory via `sys_dirent`
(TRAP #64), accumulating file sizes for the `used` total. After the
last dirent, it calls `sys_diskfree` to fetch the free-space figure.
Both totals are formatted via `_KoshEmitSize` with `D2=0` (raw mode)
so they flow inline within the labelled text rather than in fixed
columns.

**Notes.**
- The totals line gives users a quick "how much room is left" answer
  without needing to type `vol` afterwards. Prior to Part 34, `ls`
  showed only the file count.
- The `used` figure is computed by summing file sizes from dirent
  records (clean, accurate). The `free` figure is computed from the
  FAT free list (the canonical authority). These two need not sum
  to total volume size — FAT16's per-cluster allocation granularity
  means small files round up to one cluster each, so the FAT-reported
  used clusters typically slightly exceed the directory-summed file
  bytes.

---

## 15. Glossary

**ABI**  Application Binary Interface. The contract between caller and callee about register usage, stack discipline, etc.

**Atomic section**  A region of kernel code that runs with interrupts disabled, so it cannot be preempted halfway through.

**Carry-sense (K16 convention)**  K16 follows the 6502 convention for carry after `SUB` and `CMP`: **C=1 means no borrow** (the unsigned subtract did not underflow — the normal case for `Dn >= Dm`), and **C=0 means borrow** (underflow — `Dn < Dm`). Consequently `BCS` after `SUB`/`CMP` branches on "no underflow / normal", and `BCC` branches on "underflow / error". This is the opposite of the x86/ARM convention and is a durable trap when writing arithmetic and bounds-check code; see Gotcha 2.8 in `kOS_Gotchas`. The kernel's syscall return convention re-uses the same flag with different semantics (C=0 success, C=1 error), distinct from any subtract that preceded the `RET`/`RETCC`/`RETCS`.

**Cluster**  The FAT16 allocation unit. A cluster is one or more contiguous 512-byte sectors (volume-specific via `VOL_SEC_PER_CLUSTER` in the BPB) and is the granularity at which the filesystem allocates and frees data space. Cluster numbers start at 2 (cluster 0 and 1 are reserved by the FAT16 spec); the FAT entry for cluster `N` lives at FAT offset `N×2` and is either the next cluster in a chain, `$FFFF` (chain terminator), or `$0000` (free). See `kOS_FS_Reference` §3.

**CWD (kosh current working drive)**  A single drive letter held in kosh's task page (`KOSH_CWD` at `$45C0`, default `'B'`). Paths typed without a `X:` prefix are normalised to `<CWD>:<rest>` by `_KoshNormPath` before being passed to the kernel. Switched by typing a bare drive letter at the prompt (`C:`). Lives entirely in kosh — the kernel still receives fully-qualified paths.

**Disk-free**  The count of unused clusters on a mounted volume. Reported by `sys_diskfree` (TRAP #68), which scans the FAT entries (see *FAT free list*) and returns `D0`=free-cluster count, `D1`=total-cluster count, `D2`=cluster-size-in-bytes. Surfaced to users via the kosh `vol` and `ls` commands as a human-readable size (see *Human-readable size*).

**FAT free list**  Conceptual term: the set of FAT entries holding `$0000` (free) on a given volume, identified by linear scan of the FAT. k/OS does not maintain an explicit list — `sys_diskfree` and `_AllocCluster` both scan; a Phase 17 work item adds a "next-free-cluster hint" to make `_AllocCluster` O(N) instead of O(N²) on a near-full volume.

**Host bay**  One of four physical mount points (`bay 0..3`) on the K16 disk controller, mapped to k/OS drives C: through F:. Distinct from a *volume*: a bay can be bound (a host `.KOS` file is open on it) without being a valid FS-mounted volume. See FS Reference §11.6.

**Human-readable size**  A byte count rendered as `<whole>.<fraction><unit>` with unit chosen so the whole part stays in 0..1023: `1018KB`, `15.85MB`, `1.98GB`. Computed by `KLIB_BYTES_SPLIT` (slot 46) and rendered by kosh's `_KoshEmitSize`. Used by `vol`, `ls`, and `load`'s error path. The width parameter (D2) selects column-padded rendering (`D2 > 0`) or raw inline rendering (`D2 = 0`); see Gotcha 4.46.

**KLIB**  Kernel Library. The shared library at `$00:$A000` that exposes commonly-needed helpers to user tasks. See `kOS_KLIB_Reference.md`.

**Leaf syscall**  A syscall that doesn't sleep, switch context, or call into the scheduler. It returns to the same task that invoked it. Uses plain `RET` (or `RETCC` / `RETCS` for explicit success/error exit) and doesn't manipulate IE outside an optional `DINT`-gated critical section. Result is returned in `D0` with carry: `C=0` = success, `C=1` = error code in `D0`. Examples: `sys_getpid`, `sys_putchar`, `sys_kmalloc`. See also *Non-leaf syscall*; the C=0/C=1 contract is identical between the two — only the return mechanism (`RET`/`RETCC`/`RETCS` vs `RTI`) differs.

**load**  Both the kosh command and the underlying mechanism (Part 25 r6): three new MMIO commands (`HOST_CMD_FOPEN` / `FREAD` / `FCLOSE`) that let k/OS read files from the EMU's host-side `load/` folder. Used to ingest newly-built `.COM` files from the IDE without unmounting the destination disk image. The streaming model (small buffer, multiple FREAD calls) avoids needing a 64 KB scratch in the calling task.

**Non-leaf syscall**  A syscall that may switch context (sleep, yield, exit, wait, spawn) or call `_Schedule`. It must use the canonical `PUSH SR / DINT / body / RTI` shape: the `DINT` is critical — it prevents the 30 Hz timer IRQ from firing inside `_Schedule` after `CURRENT_TCB` has been updated but before the new task's registers are committed, which would otherwise corrupt the resumed task's stack. The matching `RTI` atomically restores SR (including IE) and the return PC. Returns the same C=0/C=1 contract as a leaf syscall, encoded in the SR value pushed before the body runs. See Gotcha 4.28 for the canonical body shape. Examples: `sys_yield`, `sys_exit`, `sys_open`, `sys_read`, `sys_write`, `sys_unlink`, `sys_diskfree`.

**Page**  A 64 KB region of address space. The K16 has 256 pages (`$00..$FF`). Pages are the unit of memory protection: a task's `Y3` register holds its primary page byte and ordinary indexed memory access is constrained to that page.

**Partial-progress reporting**  An optional extension of the C=0/C=1 syscall convention: where a bulk-I/O syscall can fail partway through its work, it returns `C=1` with `D0` = error code AND `D1` = bytes-completed-before-failure. Currently `sys_write` is the only syscall using this convention (Part 34, 18 May 2026); `sys_read` and `sys_puts` will adopt it in future revisions as a strict addition (callers that inspect only D0 remain correct). The motivating use case is kosh's `load` command on `ERR_NOSPACE`, where the user gets `load: wrote 8KB then failed:` instead of `load: failed`.

**Primary page**  The 64 KB page in which a user task's code, data, and stack all live. Each task has exactly one primary page.

**Quantum**  A task's time slice. (Currently unused -- the scheduler is round-robin without quantum tracking, but the field exists for future use.)

**Reap**  Reclaim a `TS_DEAD` TCB and its pages, returning the slot to `TS_UNUSED` and the pages to the free pool. Done by `sys_wait`.

**Region**  A 64 KB heap page with a region descriptor at offset 0 and block area from `$0010..$FFEF`. The kernel heap is built from one or more regions chained via `HR_NEXT_PAGE`.

**Sleeper**  A task in `TS_BLOCKED` waiting for `SYS_TICKS` to reach its `TCB_WAKE_TICK`. `_WakeSleepers` (run from `_TimerIRQ`) moves expired sleepers back to `TS_READY`.

**TCB**  Task Control Block. A 128-byte structure describing one task: saved register state, scheduler links, parent / child relationships, exit code, name, etc. The TCB pool is statically sized at boot.

**Tick**  One increment of `SYS_TICKS`, fired by the timer IRQ at 30 Hz (~ 33.33 ms).

**TRAP**  Software interrupt. The K16's `TRAP #n` instruction jumps through vector slot `n` of the table at `$00:$0000`. k/OS uses TRAPs as the syscall mechanism.

---

## Appendix A. Revision History

| Version | Date | Notes |
|---|---|---|
| 0.3 | 5 May 2026 | Initial release. Covers Phase 13 state -- kernel through `KERNEL_STATE`, TCB pool of 63, 20 LIVE KLIB entries, single heap region (Digital) / multi-region (EMU). |
| 0.4 | 5 May 2026 | Phase 14 + 15 update. New: 5.3 user-facing heap syscalls (`sys_kmalloc` TRAP #24, `sys_kfree` TRAP #25); `BT_NAME` ($0240) for human-readable task names (used by `_BuildTask`/`_InitTCBPool`); 5.4 syscall summary extended; 6 heap intro reflects user-facing TRAPs landed; `kos_heap.asm` listed in source layout; vector slot range extended to `$0024..$0067`; system variable map extended past `$0240`; boot sequence acknowledges kosh as the Phase 15 interactive entry point. |
| 0.5 | 6 May 2026 | Phase 16 update (Pieces 1+2+3 complete). Page-$00 layout reorganised: `KERNEL_STACK_TOP` moved from `$BFF0` to `$FFFE`, FS scratch buffers placed at `$BC00..$BFFF` (512-byte aligned). Sysvar map extended: volume table at `$0260..$031F`, FAT cache state at `$0320..$032F`. Six FS syscall slots reserved (TRAPs 26..31). New section 11 (Filesystem) covers volume model, block backends, FAT cache, error codes, and implementation status. Sections 11/12 (Coding Conventions / Glossary) renumbered to 12/13. Section 1 At-a-glance table gains a Filesystem row; source layout adds the four new FS files (`kos_fs.asm`, `kos_fs_defs.inc`, `kos_fs_ram.asm`, `kos_fs_rom.asm`). Section 4 boot sequence shows `_InitFS` after `_InitKLib`. Section 9 smoke-test list extended with Phases 14, 15, 16. Section 10 EMU vs Digital table gains RAM disk and ROM disk sizing rows. |
| 0.6 | 6 May 2026 | Phase 16 Pieces 4+5 complete and verified on EMU and Digital. Section 5 syscall summary table: TRAPs 26..30 (sys_open / sys_close / sys_read / sys_write / sys_dirent) wired and described as non-leaf; TRAP 31 (sys_exec) remains reserved pending Piece 6. Section 11 expanded with new subsections 11.5 "File descriptors" (per-task fd table layout, slot fields, multi-cluster I/O caching), 11.6 "File-syscall ABI" (carry-on-error convention, callee-preserved registers), and 11.7 "Buffer-pointer convention" (the `MOVE Y0, Y3` calling convention, user-page memory map, recommended buffer placement zone `$E000..$FEFF`). Section 11.8 (error codes) and 11.9 (implementation status) renumbered; status table reflects Pieces 4 and 5 complete with three smoke tests passing on both hosts. Source layout (§1) gains `kos_fs_dir.asm` and `kos_fs_fd.asm`. At-a-glance Filesystem row updated to reflect Pieces 1-5 complete. |
| 0.7 | 6 May 2026 | Phase 16 Piece 6 complete and verified on both EMU and Digital (7/7 tests pass on both hosts). Section 5.4 syscall table: TRAP 31 (`sys_exec`) wired and described as non-leaf with TID return. Section 11.6 updated to "six Phase 16 file syscalls". New section 11.9 "The `.COM` executable format" documents the position-independent code requirement: `LEA` PC-relative, page-zero TRAP indirection, and PC-relative branches are safe; `CALL24`/`JMP24` to .COM-internal labels are not. SPAWN_MAX_LEN ($FE00) ceiling and rejection of empty/wrong-extension files documented. Section 11.10 (implementation status, formerly 11.9): Piece 6 marked Complete, table now lists `_ExecCheckExt` / `_ExecCopyChain` / `_ExecCopyOneSector` / `_ExecStageName` helpers; smoke test count rises from three to four with the new 7-test `kos_p16_fs_exec_smoke.asm`; phrasing on remaining work updated to focus on kosh integration, EMU save/load, mkromdisk, and a new mkcom tool. Cross-references kOS_FS_Reference v1.8. |
| 0.8 | 7 May 2026 | Phase 16.7 — kosh FS commands. **kosh promoted from smoke-test to production user task**: source moved from `Test/kos_p15_kosh_smoke.asm` to `kosh/kosh.asm`, with split into `kosh/kosh_helpers.asm` (CALL24-callable helpers) and `kosh/kosh_cmds_fs.asm` (FS commands). Future split convention: `kosh_cmds_<group>.asm`. Three new commands: `vol`, `ls`, `cat`. **Auto-format B: at boot** if not mounted, removing the need for the user to run `format` on first boot. **`_TryMount` now computes `VOL_TOTAL_CLUSTERS`** at mount time (was reserved-but-unfilled before; `vol` was reading zero). **KLIB v1.1 dependency**: `KLIB_UTOA`/`KLIB_ITOA`/`KLIB_ITOH` are now cursor-style (advance XY0 past digits, write nul at advanced position) — best-of-both API for buffer-and-blast formatting. New kosh-page scratch convention: `$4000..$42A7` for output buffers (DUMP/ROW_BUF/LS_*/CAT_BUF), `$5000` for LINE_BUF (was `$1000`, moved due to body-growth overlap with `msg_help` — see Gotchas v1.6 entry 4.19). Cross-references KLIB Reference v1.1, Gotchas v1.6. |
| 0.9 | 7 May 2026 | Phase 19 — kosh extensions: `format` and `run` commands shipped, plus boot-time disk populate. **Section 5.4 syscall summary**: TRAP 32 (`sys_format`) added as non-leaf (formerly internal-only `_FormatVolume`; now first-class via VEC_FORMAT $0080). Slot range in §2.3 extended to `$0024..$0083`. **kosh source split** further per group: `kosh_help.asm` / `kosh_cmds_util.asm` / `kosh_cmds_sys.asm` / `kosh_cmds_mem.asm` / `kosh_cmds_fs.asm`, each owning handler bodies and per-command strings. **Case-insensitive command dispatch**: kosh now lowercases the command word before walking `cmd_table`. **Disk populate**: kosh task body, after auto-format, writes `HELLO.COM` (36 B) and `NOTES.TXT` from kernel-side ROM data; idempotent existence-check via `sys_open(path, FOPEN_READ)`. New zp slots in kosh page: `LS_DRIVE_TMP`/`LS_INDEX_TMP` (around the `_KoshEmitDec` D2/D3 clobber); `CAT_BUF` moved to `$40AA`. **Long-standing bug fixes** (all Phase 16.7 r1 lurkers, hidden until multi-file disk landed): ls's drive/index clobbered across loop iterations (sys_dirent iter 2 returned ERR_BADDRIVE on bogus drive); cat used `FD_FLAG_READ` ($02) where `FOPEN_READ` ($01) was meant (sys_read returned ERR_BADFD). **Open issues**: `run B:HELLO.COM` crashes with PC at $00:0002 (suspect `_ExecCopyChain` or `_BuildTask` fake-INT-frame PC); `sys_read` returns ERR_BADFD on a post-EOF call (cat works around it via short-read=EOF). Cross-references `kOS_FS_Reference v1.10` (sys_format §9.7), `kOS_Gotchas v1.7` (entries 4.20/4.21/4.22). |
| 0.10 | 8 May 2026 | **Part 20a** — Syscall ABI audit and fixes: `sys_format` (r4) and `sys_exec` (r3) now preserve D2/D3/XY2 per V2 ABI. The audit established the rule explicitly in §5: every syscall, leaf or non-leaf, preserves D2, D3, XY2 across the TRAP. Cross-references K16 ISA Gotcha #31 (the FD-layer find that triggered the audit) and `Syscall_ABI_Audit_2026-05-08.md`. **Part 20b** — Counting semaphores: new `kos_sem.asm` provides 16-entry pool at `$00:$03C8..$0447` with FIFO wait queues. New TCB field `TCB_SEM_NEXT` at `$20`; new state `TS_SEMWAIT = 5`; four new TRAPs `sys_semcreate` (#33) / `sys_semtake` (#34) / `sys_semgive` (#35) / `sys_semdestroy` (#36). New §5.5 "Semaphores" documents the pool, primitives, and idiomatic uses (mutex, resource pool, producer/consumer). The `sys_semtake` non-leaf inlines its block-and-schedule dance because a subroutine that called `_Schedule` from inside its own PUSH/POP frame would corrupt the resumed task's stack; see K16 ISA Gotcha #32. Boot smoke `kos_sem_smoke.asm` exercises the non-blocking paths and passes on both EMU and Digital. Vector slot range extended to `$0024..$0093`. **Boot housekeeping**: HELLO.COM byte-order bug fixed (was using `.BYTE` with high-byte-first listing transcription; now uses `.WORD`). Splash banner updated to "v0.6 Phase 16+", boot date "8 May 2026". Cross-references `K16_ISA_Gotchas v6` (entries #31, #32). |
| 0.11 | 10 May 2026 | **Parts 22 and 23** — host-disk subsystem. §1.1 Filesystem row updated to reflect six drives (A: ROM, B: RAM, C..F: host). §1.3 source layout adds `kos_fs_host.asm` (Part 22 — block-layer backend, `_BlockReadHost`/`_BlockWriteHost`), `kos_fs_host_mgr.asm` (Part 23 — management helpers `_HostMount`/`_HostUnmount`/`_HostList`/`_HostCreate`/`_HostDelete`), `kos_sem.asm`, plus the kosh source split into `kosh_help.asm` / `kosh_cmds_util.asm` / `kosh_cmds_sys.asm` / `kosh_cmds_mem.asm` / `kosh_cmds_fs.asm` / `kosh_cmds_disk.asm`. **§2.2 Page $00 layout updated** for Parts 22+23: volume table grew from 3×64 ($0260..$031F) to 6×64 ($0260..$03DF); FAT cache and dir/dirent caches now occupy `$03E0..$03EF`; freed `$03F0..$03FF` (was Part 22's `POOL_NAME_BUF`, removed in Part 23); semaphore pool at `$0400..$047F` (Part 20b); FD scratch relocated to `$0480..$04CB` after Part 22 silent-collision fix (Gotcha 4.25). §2.4 prose rewritten to match. **§11 reorganised** for the three-backend model: §11.1 lists six drive slots; §11.2 block backends table replaces SD row with Host row (EMU-only); §11.3 FAT cache addresses moved to `$03E0..$03E3`. **§11 head** notes that Pieces 1–6 plus Parts 22+23 are all complete and verified, with cross-reference to `kOS_FS_Reference v1.12`. **kosh commands shipped via Part 23**: `disks`, `mount`, `unmount`, `mkdisk`, `rmdisk`. Cross-references `kOS_Gotchas v1.9` (entries 4.25 memory-map collisions, 4.26 odd-address LOADZ on Digital, 4.27 slot-vs-bay double-indexing as design footgun) and `kOS_FS_Reference v1.12` (§11.4 host backend, §11.5 host management). |
| 0.12 | 11 May 2026 | **Parts 24 and 25** — host filename rename, sys_unlink/sys_rename, kosh CWD, and host file ingestion via `load`. **§1.1** Filesystem row now reads "Pieces 1-6 complete; Parts 22-25 shipped." **§1.3 source layout updates**: `kos_fs.asm` adds `_FATFreeChain`; `kos_fs_fd.asm` adds `sys_unlink` and `sys_rename` (TRAPs 37/38); `kos_fs_host_mgr.asm` grows to 10 helpers (added `_HostRename`/`_HostBayName` Part 24, plus `_HostFOpen`/`_HostFRead`/`_HostFClose` Part 25 r6); kosh source layout adds Part 25 helper functions (`_KoshNormPath`, `_KoshPrintErr`, `_SlotForDrive`) and new commands (cp/rm/mv/load/rename/remount/drive-switch). **§5.4 syscall table**: added TRAP 37 (`sys_unlink`) and TRAP 38 (`sys_rename`), both non-leaf. Slot range note updated: thirteen syscalls now wired (slots 0..38 with gaps). **§11 head reworked**: Parts 24 and 25 listed as shipped, with bullet-point summaries; cross-reference bumped to `kOS_FS_Reference v1.13`. **§13 Glossary** added entries: CWD, host bay, load, with refreshed leaf/non-leaf entries cross-referencing gotcha 4.28. Cross-references `kOS_Gotchas v1.10` new entries 3.8 (.BYTE PC misalign), 4.28 (non-leaf syscall canonical shape), 4.29 (helper-clobbers list authority), 4.30 (_SlotForDrive clobbers XY2), 4.31 (_KoshEmitStrZ needs full XY0), 4.32 (path strings in caller task page), 4.33 (mount-without-BPB rollback removed), 7.9 (ImDisk/UAC inject dead end), 7.10 (volume-name path deferral). |
| 0.13 | 12 May 2026 | **Part 20** — syscall renumber to domain-grouped layout, plus sys_kill and sys_setvidmode. **§5.4 syscall summary** rewritten as a grouped table: Console (10..24), Task (25..39), Memory (40..49), Sync (50..59), FS (60..74), Device (75..84), Reserved (85..127). All per-syscall headers in §5.1, §5.2, §5.3, §5.5 updated to new TRAP numbers; in-text references (§6 heap intro, §11.10 Phase 16 status) updated. After Part 20, TRAP numbers are stable; new syscalls consume per-group reserve. **§5.6** new: `sys_kill` (TRAP #32) — DINT-gated leaf, terminates by TID, permission via `TF_PRIV` flag (kosh-privileged) or parent-of relationship, sweeps all TS_DEAD corpses on success. **§5.7** new: `sys_setvidmode` (TRAP #75) — single-owner ownership of VID_MODE MMIO with acquire/release/change semantics, auto-released on owner death via `_VideoForceReset`. **`_TidToTcb` rewritten as linear scan over `TCB_ID`** (kos_spawn.asm r6) — the old address-arithmetic lookup assumed slot index == TID, which broke once sys_kill's eager-reap + sweep let slot recycling diverge from `TASK_COUNT`'s monotonic TID assignment. Monotonic TIDs retained as the correct design (Unix PID semantics, prevents kill-wrong-task races). Cross-references `kOS_Gotchas v1.11` new entries 4.34 (FS_BUF_SECTOR / dir-cache coherence violation), 4.35 (page-$00 sysvar slot allocation collision — `HOST_DISK_SEM` vs `VIDEO_OWNER_TID`), and 4.36 (`_TidToTcb` arithmetic-lookup invariant broken by eager-reap). New device-driver subdirectory `kdrv/` introduced: `kos_console.asm` relocated from `kernel/`; `kos_video.asm` (new) defines mode constants and the syscall body. Cube programs ported to `TRAP #TRAP_SETVIDMODE` with `ERR_BUSY` graceful exit. Also doc cleanup: the revision history table was broken since v0.10 (orphan rows after a stray `---` had stopped rendering as a table) — restitched in this revision. |
| 0.15 | 13 May 2026 | **Phase B** — preemptive foreground switcher (multi-shell). New section 13 documents the subsystem end-to-end: shell registration (`sys_register_shell` TRAP #77, `sys_setforeground` TRAP #76), per-shell 80×80 back-buffers (`TCB_BACKBUF_PTR`/`TCB_BACKBUF_OFFS`/`TCB_SHELL_NEXT`/`TCB_SHELL_GEOM` at $4C/$4E/$50/$52), output routing on `TF_HAS_BACKBUF` (bit 3, $0008), `_BackbufPutChar` clobber discipline (clobbers D0..D3/XY0/XY2; preserves XY1/XY3 -- shell byte loops MUST PUSH/POP), foreground-gated input via `_GetGatedKey` (background shells busy-spin), `_RepaintFromBackbuf` with pre-scan trimming and ESC[3J/ESC[2J/ESC[H sequence, hot-key dispatch in `_KbdDispatch` (Ctrl-N/P/Shift-N/LeftArrow/RightArrow/1..0), and the shell ring with cycle detection. **TCB layout extended** in §3.2: `TCB_PREEMPT_COUNT` promoted to 32-bit via new `TCB_PREEMPT_COUNT_HI` at $22 (wraps at ~4 years @ 30 Hz); four shell fields at $4C..$53; `TF_HAS_BACKBUF` formally documented as TCB_FLAGS bit 3. `_TimerIRQ` does ADD low / ADC hi #0 to propagate carry (offset $22 needs mode-01 [XY+D] since outside imm5). **§2.4 sysvars**: `FOREGROUND_TCB` at $0238 and `FIRST_SHELL_TID` at $023A. **§1.3 source layout** adds `kos_switcher.asm`. **§1.1 at-a-glance** adds Multi-shell row, KLIB row now shows 24/64 slots LIVE. **Glossary** renumbered 13 → 14 to make room for new §13 Foreground Switcher. **KLIB additions** (paired with this release in `kOS_KLIB_Reference v1.3`): slot 04 `KLIB_DIVMOD32` LIVE (unsigned 32/16 → 32 quotient + 16 remainder, 33-bit ADD/ADC shift-subtract chain), slot 45 `KLIB_UTOA32` LIVE (uint32 → decimal cursor-style, recursive divide-by-10 via KLIB_DIVMOD32). kosh `ps` rewritten with FG and TICKS columns using KLIB_UTOA32; `_KoshPutDec32` retired. **emu_terminal.pas** patched: ESC[2J no longer moves cursor (VT100 compliance), new ESC[3J for scrollback clear, Ctrl-Shift-N as fallback for Ctrl-P. **Bug fix**: `_SwitchForegroundPrev` was committing foreground as its own predecessor (checked TID AFTER advancing cursor); fixed by peeking next-TID before advancing. |
| 0.16 | 14 May 2026 | **Part 30** — splash relocation, 32-bit ticks, keyboard paste fix, info overhaul, hygiene pass. **Boot splash relocated to kosh**: `kos_splash.asm` deleted; full sign-on (logo + 6 info lines + rule) now emitted by `_OSSplash` in new `kosh_splash.asm`, painted via TRAPs so it lands in the back-buffer and survives foreground switching. Kernel boot trace is now ephemeral 3-liner via `_RawPuts` ("Booting k/OS" / "Formatting B: ... OK" / "Loading k/OS shell ..."). `_RawPutDec` and `_RawPutHexByte` absorbed into `kos_rawio.asm`. **SYS_TICKS promoted to 32 bits**: `SYS_FLAGS` at `$0202` (unused) renamed `SYS_TICKS_HI`. `_TimerIRQ` adds ADC chain on the high word. Wraps at ~4.5 years @ 30 Hz instead of ~36 minutes. **Keyboard paste fix**: `_KbdTick` r33 now drains MMIO until empty or ring-full at each tick, lifting the 30 cps paste cap. Ring-full check at top of loop applies backpressure to the producer (emu FKeyQueue / host buffer) rather than dropping bytes at `_RingPush`. **`info` command overhaul**: shares string symbols with `kosh_splash.asm` for label consistency; shows 32-bit raw ticks and uptime via `KLIB_UTOA32` and `KLIB_DIVMOD32`; pages line shows "N free of M user pages ($02..$XX)" matching splash. **Hygiene pass**: removed dead constants `TERMINAL`/`KEYBOARD` (24-bit aliases), `USER_PAGE_END`/`USER_PAGE_COUNT`, `TASK_PAGE_BASE`/`TASK_PAGE_END`/`TASK_A_PAGE`/`TASK_B_PAGE`/`TASK_C_PAGE`/`TASK_STACK_TOP` (legacy static-task era), `BT_NAME_LEN`, plus dead `msg_prompt` string in kosh and dead `_UnhandledIRQ` stub in `kos_ctxsw.asm`. `KEY_CTRL_DIGIT_FIRST`/`LAST` and `USER_PAGE_END_EMU` brought into actual use as named constants. Stale `_KbdDispatch` header comment rewritten (Step 6b direct-index switch is live, no longer TODO). **Known issue carried forward**: background shells in `_GetGatedKey` still busy-spin instead of yielding — deferred to Part 31 (see Session_Handover_2026-05-14). |
| 0.17 | 14 May 2026 | **Part 31** — Forth v2.25 .COM port and shell-death kernel fixes. **Forth v2.25** ships as the second shell-mode .COM after BASIC v2.4 (Phase B integration full: registers via `TRAP_REGISTER_SHELL` at MAIN, banner via `sys_puts`, all I/O via TRAPs, `BYE` exits via `sys_exit`). **Three layered kernel bugs found and fixed** (`kos_task.asm` r17→r18, `kos_tcb.asm` r19→r21), then refactored into a single source-of-truth design. **§5.1 `sys_exit` description rewritten** to document the eager-reap (shell) vs lazy-reap (non-shell) split and to name `_ReapDeadTask` as the single source of truth. **§5.6 `sys_kill` description updated**: TS_DEAD victims are now reapable rather than refused with `ERR_NOTFOUND` (the user mental model is "make TID N go away" regardless of state); permission checks still apply and the original `TCB_EXIT_CODE` is preserved. **New §13.10 "Shell death"** documents the lifecycle: shell-ring unlink, foreground hand-back, repaint, back-buffer free, ring unlink, slot recycle — all inside `_ReapDeadTask`. `_ReapDeadTask` register clobber contract tightened: now preserves `D0..D3/XY0/XY1/XY2/XY3` via PUSH/POP. **Cross-references** `Session_Handover_2026-05-14_Part31_complete.md` and `kOS_Gotchas v1.15` new entries 4.41 (TCB-pool scanners clobber XY1) and 4.42 (TCB fields offset ≥ 32 require mode-01 [XY+Dn] addressing). |
| 0.18 | 16 May 2026 | **Inventory refresh.** No kernel-interface changes since v0.17. §1.1 at-a-glance updated to reflect current shell versions: **Forth v2.25 → v3.0** (Part 32, 14 May 2026 — single-page native rewrite with 16-bit page-relative dict links and 2-byte threaded cells; full ~100-primitive functional parity with v2.25, plus Forth v3.1 `FREE` primitive) and **BASIC v2.4 → v2.5**. **K16 ISA evolution noted for cross-reference** (no k/OS interface impact, but kernel may rebuild against new opcodes): Part 33 (16 May 2026) added **RETCC / RETCS** at `$1E` mode 10 (return setting C flag to 0 or 1) and **PUSH D123 / POP D123** at `$04` modes 10/11 (group push/pop of D1-D3 excluding D0, matching V2 ABI callee-save set). K16 Reference Manual went v3.10 → v3.11 → v3.12 across this work; v3.13 BHI/BLS spec drafted. See `K16_Reference_Manual_v3_12.md` for opcode details. **kosh cosmetic updates** (16 May 2026): `ps` gained PTID/PAGE columns; `info` gained a Tasks line; `task` usage message spelling unified with `kill` (uses TID throughout). |
| 0.19 | 17 May 2026 | **Phase 14 Parts 2 + 3a + 3b — kernel heap completion** (rev-history row added retroactively in v0.20). **§2.2**: heap-helper scratch slots at `$03F0..$03F3` documented (`HEAP_TID_QUERY`, `HEAP_RBT_REGION`); relocated from $0330..$0333 after page-$00 audit revealed they were inside the live volume table (Gotcha 4.26 / 4.43). **§3.4**: task-death reap hook mentioned in lifecycle description. **§5.3 + §5.4**: three new heap TRAPs — `sys_krealloc` (#42), `sys_heapstats` (#43), `sys_heapstats_by_tid` (#44). Memory group now uses 5 of 10 slots. **§6.2**: block header grew 4 → 6 bytes; `BH_OWNER_TID` field documented. **§6.4**: API expanded with `_krealloc`, `_HeapStatsFull`, `_HeapStatsByTid`, `_ReapByTid`; ABI note added about `XY2` clobber convention. **§6.5 (new)**: per-task ownership and automatic reclamation on task death. Cross-references `kOS_Gotchas v1.16` entries 4.43 (page-$00 layout comment is not authoritative) and 4.44 (kernel-side smokes use `_RawPuts`, not output TRAPs). |
| 0.20 | 18 May 2026 | **Part 34** — disk-free reporting, sys_write partial-write semantics, expanded V2 ABI, kosh commands section. **§5 V2 ABI table** expanded to declare `D1` and `XY1` as callee-preserved (was `D2/D3/XY2` only); compliance note flags that the audit of older handlers is pending (sys_diskfree is the first handler explicitly built to the new contract). Motivation paragraph documents the two driving cases: sys_write's partial-progress D1 return, and FAT-walking syscalls held by callers with row cursors in XY1. **§5.1** new "Output routing (summary)" subsection at head of Console I/O — table-summarises TF_HAS_BACKBUF dispatch, forward-refs to §13.2 for the full mechanism, warns kernel-side smokes off the output TRAPs (Gotcha 4.44). **§5.4** syscall table: new `sys_diskfree` (TRAP #68) in FS group; `sys_write` row notes partial-write D1 semantics; per-group reserve updated from 68..74 to 69..74. **§11.6** rewritten: head sentence corrected (no longer "six Phase 16 syscalls"); preservation summary updated to expanded ABI (`D1/D2/D3/XY1/XY2/XY3` preserved, `D0/XY0/Y0` clobbered); new "Partial-progress reporting" subsection documents the pattern with sys_write as canonical example, sys_read and sys_puts reserved for future adoption. **§2.2** three new page-$00 slots: `DISKFREE_CLUSTER` ($03F4), `DISKFREE_COUNT` ($03F6), `DISKFREE_LIMIT` ($03F8); prose mirror updated to match. **New §14 "kosh commands"**: framed as a living section, `vol` and `ls` documented with column layouts, sample output, and mechanism notes; remaining commands listed by name as pending coverage. **§15 Glossary** (renumbered from §14): six new entries — Carry-sense, Cluster, Disk-free, FAT free list, Human-readable size, Partial-progress reporting. Leaf and Non-leaf syscall entries refreshed (Leaf gets explicit C=0/C=1 contract + RETCC/RETCS exit; Non-leaf gets the DINT-critical explanation). Cross-references `kOS_Gotchas v1.17` entries 2.8 (K16 carry-sense — 6502 convention), 2.9 (CALLR is PC-relative), 2.10 (SHL × N vs SHL4 idiom), 4.45 (TRAP handlers preserve XY1 per expanded V2 ABI), 4.46 (`_KoshEmitSize` D3 clobber and width=0 raw mode); and `kOS_KLIB_Reference v1.5` slot 46 `KLIB_BYTES_SPLIT`. **Open work parked for follow-up**: full audit of older syscall handlers for D1/XY1 preservation compliance; sys_read and sys_puts partial-progress retrofits deferred (sys_read pending bad-sector test infrastructure; sys_puts pending Phase 11 redirectable stdout). |
| 0.22 | 18 May 2026 | **Part 36 testing + Gotcha 4.47 fix.** Smoke test verification surfaced three additional issues beyond the Part 35 audit's scope: (1) `_SemCreate`/`_SemDestroy`/`_SemGive` declare `Clobbers: D1` in their headers, so the Bucket 1 TRAP wrappers needed `PUSH D1`/`POP D1` around the `CALLR` as well as the EINT-gate fix; (2) the same pattern applied to the FS handlers — `_DirLookup`, `_FATGetEntry`, `_FdFlushDirent`, `_FormatVolume` all clobber D1 on deep paths, requiring `PUSH D1`/`POP D1` in `sys_open`/`close`/`format`/`unlink`/`rename`/`exec` prologues; (3) **latent collision bug discovered**: `FE_NEW_PAGE` declared inside `kos_fs_exec.asm` at `$03BC` had overlapped `VOL_SLOT_F + $1C` (the page byte of F:'s `VOL_BLOCKREAD_PTR`) since Part 22's volume-table expansion. Every `sys_exec` corrupted F:'s block-read function pointer, surfaced as `CODE FAULT odd-addr fetch PC=$FF2803` when `vol` walked F: post-`run`. **§2.2 page-$00 table** updated: FD upper bound corrected from `$04CB` to `$04D6` (was stale since Part 25); new FE-scratch row at `$04D8..$04E3` (Gotcha 4.47 relocation); Reserved-for-kernel-growth region adjusted to `$04E4..$07FF`. **§2.2 trailing prose + §2.4 page-$00 listing** updated to reflect Part 36 consolidation: FD_* and FE_* declarations relocated from their `.asm` source files into `kos_fs_defs.inc`, with a new "ZERO PAGE MAP — RULES FOR ADDING ALLOCATIONS" section in `kos_defs.inc` documenting the recurring collision-bug pattern (Gotchas 4.25, 4.43, 4.47 — three instances of the same root cause) and five prevention rules. Cross-references `kOS_Gotchas v1.18` (entries 4.47 page-$00 collision, 4.48 helper Clobbers don't propagate through TRAP boundary, 4.49 bad-path smoke tests exit too early). Final test state: 21/21 ABI smoke pass on EMU, `vol`/`run`/`vol` sequence clean. |

*End of k/OS Reference Manual v0.22*
