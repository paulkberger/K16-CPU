# k/OS Reference Manual

Version 0.37 -- Sunday, 9 August 2026

For the full change history, see Appendix A (Revision History) at the end of this manual.

---

## 1. Overview

k/OS is a small preemptive multitasking operating system for the K16 CPU. It runs from ROM at reset, occupies kernel page `$00`, provides paged memory protection between user tasks, and offers a TRAP-based syscall interface. This document describes its architecture, memory layout, process model and kernel APIs.

k/OS is a small, complete, hand-written operating system targeted at hobbyist machines -- preemptive multitasking, page-protected memory, byte-granular kernel heap, all in roughly 47 KB of ROM (including the kosh shell, which is copied into a RAM task page at boot).

GitHub: https://github.com/paulkberger/K16-CPU

### 1.1 At a glance

| Aspect | Value |
|---|---|
| CPU | K16 (16-bit CPU, 24-bit address space) |
| Kernel size | ~47 KB ROM image (48078 bytes), including the kosh shell (~19 KB) copied to a RAM task page at boot |
| Multitasking model | Preemptive, 30 Hz timer-driven |
| Maximum tasks | 1 idle + 30 user (Digital) / 62 user (EMU) |
| Memory protection | A run of N contiguous 64 KB pages per task, base = `Y3`, N declared in the `.COM` header (Part 60). N = 1 is the common case. |
| Syscall mechanism | `TRAP #n` |
| Kernel heap | First-fit + bidirectional coalesce, multi-region |
| Filesystem | FAT16 on ROM disk (A:), RAM disk (B:), and host disks (C:..F:, EMU-only). Pieces 1-6 complete; Parts 22-25 (host backend, name-based mount, filename rename, unlink/rename, kosh CWD, `load`), Part 26 (ROM-disk authoring), **Phase 2a (subdirectories: path resolver, `mkdir`/`rmdir`/`resolve`/`pwd`, `sys_dirent` start-cluster)**, and **Phase 2b / Part 44 (CWD-relative + subdirectory-aware fs commands)** all shipped. Detail in `kOS_FS_Reference` v1.15. |
| Multi-shell | Phase B (13 May 2026): preemptive foreground switching between shell tasks, per-shell back-buffers (80×80 = 6400 bytes), ANSI repaint, foreground-gated input. Hot keys: Ctrl-N/P/Shift-N/Left/Right/1..0. Three shells in production (kosh, BASIC v2.6, Forth v3.1). Shell death cleanup consolidated into `_ReapDeadTask` (Part 31, 14 May 2026). |
| Shared library | KLIB at `$00:$A000` -- 25/64 slots LIVE (see `kOS_KLIB_Reference.md` v1.6) |

### 1.2 Design principles

**Small surface.** k/OS targets a hand-built machine with limited RAM and no virtual memory. Every kernel data structure has a fixed or bounded size. The TCB pool is statically sized at boot. The syscall vector table has 128 fixed slots.

**Paged tasks.** Each user task owns a run of one or more contiguous 64 KB pages, the first of which holds its code, globals and stack. The K16's page-byte index register (`Y3`) is what makes this a protection boundary in practice: a task whose `Y3` is its base page cannot read or write any other page through ordinary indexed addressing, and crossing pages requires an explicit page-byte update. Note this is a *convention*, not hardware enforcement — the K16 has no MMU, and a task that deliberately loads another page byte into `Y0` will reach it. The kernel's job is to ensure the allocator never hands the same page to two tasks, not to prevent a task from misbehaving. Before Part 60 every task had exactly one page; a task now declares what it needs in its `.COM` header (§11.9) and is granted a contiguous run or refused (§7).

**One kernel context.** k/OS does not have re-entrant kernel code. Syscalls run with a single fixed kernel stack (`KERNEL_STACK_TOP` at `$FFFE`). Most syscalls disable interrupts during their critical sections. The scheduler is itself single-instance.

**Cooperative + preemptive.** Tasks cooperate via `sys_yield` / `sys_sleep` and are also preempted by the 30 Hz timer IRQ. There is no fairness or priority logic in the current scheduler -- tasks take turns in round-robin order.

### 1.3 Source layout

The source tree has two top-level entry-point files at the root, with the rest organised under six subdirectories: `kernel/` (core kernel internals), `kdrv/` (device drivers), `kfs/` (filesystem), `klib/` (utility library), `emulib/` (emulator-only host bridge), and `kosh/` (interactive shell).

#### Project root

| File | Purpose |
|---|---|
| `kos_boot.asm` | Reset vector, `_InitKernel`, `_P2Main` dispatch |
| `kos_defs.inc` | All shared constants -- memory map (page-$00 `.REGION` reservations), TCB layout, syscall numbers, error codes |

#### `kernel/` — core kernel

| File | Purpose |
|---|---|
| `kos_bad_trap.asm` | Default vector handler (uninitialised TRAPs) |
| `kos_ctxsw.asm` | `_TimerIRQ`, `_INTDispatch`, `_RestoreIdle`, `_IdleLoop` |
| `kos_heap.asm` | Heap syscall TRAP wrappers (Phase 14): `sys_kmalloc`, `sys_kfree`, `sys_krealloc`, `sys_heapstats`, `sys_heapstats_by_tid` |
| `kos_kmalloc.asm` | Kernel heap allocator: `_kmalloc`/`_kfree`/`_krealloc`, free-list ops (`_FindFit`/`_SplitBlock`/`_InsertFreeBlock`/`_UnlinkFreeBlock`), `_GrowHeap`, stats (`_HeapStatsFull`/`_HeapStatsByTid`), per-task reclaim (`_ReapByTid`) |
| `kos_rawio.asm` | `_RawPutByte`, `_RawPuts`, `_RawPutDec`, `_RawPutHexByte` (used before scheduler is up) |
| `kos_sched.asm` | `_Schedule`, `_WakeSleepers` |
| `kos_sem.asm` | Counting semaphores (Part 20b): syscalls `sys_semcreate`/`semtake`/`semgive`/`semdestroy` + primitives (`_SemTakeTry`/`_SemGive`/`_SemTakeBlocking`/`_ValidateSem`). Pool defs now live in `kos_defs.inc` (`SEMPOOL` region, §2.2) |
| `kos_spawn.asm` | Dynamic task creation/teardown: `sys_spawn`, `sys_wait`; `_TidToTcb` (linear TID scan), `_OrphanChildren`, wait delivery (`_DeliverWaitResult`/`_DeliverWaitDetached`, Part 51), `_SpawnShell` |
| `kos_switcher.asm` | Phase B foreground switcher: `sys_register_shell`, `sys_setforeground`; back-buffer (`_BackbufPutChar`/`_BackbufScroll`/`_RepaintFromBackbuf`), ring navigation (`_SwitchForegroundNext`/`Prev`/`ByIndex`), ring splice + foreground commit (`_CommitForeground`/`_SpliceAfterForeground`/`_UnspliceFromRing`, Parts 49–51) |
| `kos_task.asm` | Task-control syscalls: `sys_getpid`, `sys_yield`, `sys_exit`, `sys_sleep`, `sys_kill` (#32); `_HandleDeadTCB` |
| `kos_tcb.asm` | TCB pool + task build: `_InitTCBPool`, `_AllocTCB`, `_AllocPage`/`_PageInUse`, `_AddToRunQueue`, `_BuildTask`, and `_ReapDeadTask` (single source of truth for shell death, Part 31) |

(Part 30 r37, 14 May 2026: `kos_splash.asm` deleted; boot banner moved to kosh; its `_RawPutDec` and `_RawPutHexByte` helpers absorbed into `kos_rawio.asm`. See `kosh_splash.asm` in the kosh sources for the live OS sign-on.)

#### `kdrv/` — device drivers

Console, keyboard, and video drivers. `kos_console.asm` was relocated here from `kernel/` (Part 20); `kos_video.asm` and `kos_kbd.asm` are the video-mode and keyboard-ring drivers.

| File | Purpose |
|---|---|
| `kos_console.asm` | Console syscall handlers: `sys_putchar`/`getchar`/`puts`/`putlp`/`gets`/`putdec`/`puthex`/`clear`/`setcursor` (TRAPs #10..18) and the Part 57/58 console-attribute verbs `sys_termsize`/`setattr`/`clreol`/`cursorvis`/`wherexy`/`clreos` (TRAPs #19..24); Phase B output routing (back-buffer / foreground gating) and `_GetGatedKey` |
| `kos_kbd.asm` | Keyboard ring driver: `_KbdDispatch`, ring push/pop/wait (`_RingPush`/`_RingPop`/`_RingWaitPop`), blocking input (`_BlockCommon`/`_WaitInput`), `_KbdReleaseWaiter`, and the Phase B hot-key foreground switch (Ctrl-N/P/digit) |
| `kos_video.asm` | Video-mode driver (Part 20/49): `sys_setvidmode` (TRAP #75), single-owner `VID_MODE` ownership (`$DD0000`), mode constants, `_VideoForceReset`/`_InitVideo`/`_VideoSetModeRaw`, and the Part 49 graphics-task foreground integration |

#### `kfs/` — filesystem (Phase 16, Parts 22-25)

Filesystem source covered in detail in a separate document (`kOS_FS_Reference`). Provides FAT16 mount/format, FAT walk and cluster operations, directory operations, VFAT long filenames, a `/`-path resolver that also resolves `NAME:` named-volume / assign prefixes, per-task file descriptors, the file-syscall layer (TRAPs 60..68: open/close/read/write/dirent/format/unlink/rename/diskfree, plus the Phase 2a subdir syscalls 69..72: mkdir/resolve/pwd/rmdir; the named-volume `sys_assign` is TRAP #78; `sys_exec` is TRAP #31 in the process group), and three pluggable block backends — ROM disk (A:), RAM disk (B:), and host disk (C..F:, EMU-only via the K16 disk controller). The host backend supports both per-sector data flow (Part 22 `_BlockReadHost`/`_BlockWriteHost`) and a streaming file-ingestion surface (Part 25 r6 `_HostFOpen`/`_HostFRead`/`_HostFClose`) used by kosh's `load` command. The directory layer is split three ways (Part 47, same assembly unit, `.INCLUDE`d adjacently): `kos_fs_dir.asm` (8.3 core), `kos_fs_dir_lfn.asm` (VFAT LFN), and `kos_fs_dir_path.asm` (path resolver + the named-volume / assign layer).

| File | Purpose |
|---|---|
| `kos_fs.asm` | Top layer: mount/format, FAT walk, cluster ops, `_FATFreeChain`; `sys_diskfree` (#68), `sys_format` (#65); the subdir syscalls `sys_mkdir` (#69) / `sys_resolve` (#70) / `sys_pwd` (#71) / `sys_rmdir` (#72); `_InitFS` seeds the locked `ROM:`/`RAM:` named volumes at boot |
| `kos_fs_defs.inc` | FS-internal constants -- BPB layout, volume-slot fields, error codes, disk-controller MMIO (`HOST_CMD_*`), LFN/VFAT constants, path-resolver (`RV_*`) / rename / LFN scratch, and the named-drive / assign table (`AS_*`, `ASSIGNTABLE`); page-$00 storage via `.REGION` |
| `kos_fs_dir.asm` | Directory core (8.3): name conversion, iteration (`_DirNext`), 8.3 lookup, `_DirSecToAbs`, create + 8.3 delete, dir-cache (Part 47 split — core only) |
| `kos_fs_dir_lfn.asm` | VFAT long filenames (Part 47 split): LFN read/write, the 8.3 short-name generator (`_GenShortName`/`_GenShortTilde`), `_LfnChecksum`, LFN-run lookup/create/delete |
| `kos_fs_dir_path.asm` | Path resolver (`_ResolveCore`/`_Resolve`/`_ResolveParent`) + pwd reconstruction (`_ScanForCluster`/`_BuildPath`), and the named-drive / assign layer: `_SlotForName`, `sys_assign` (#78), `_AssignInvalidate`/`_AssignInvalidateDrive` (Part 47 split + Parts 54–55) |
| `kos_fs_exec.asm` | `sys_exec` implementation (Piece 6) |
| `kos_fs_fd.asm` | Per-task fd table and file syscalls (`sys_open`, `sys_close`, `sys_read`, `sys_write`, `sys_dirent`, `sys_unlink`, `sys_rename`; Part 44 added CWD-cluster context + the 14-byte fd with `FD_DIR_CLUSTER`) |
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

#### `emulib/` — emulator-only host bridge

EMULIB is a KLIB-style jump table at `$00:$A200..$A2FF` (64 × 4-byte JMP24) that publishes the emulator-only host-disk shim functions without polluting KLIB (which stays portable across emulator, FPGA, and discrete-TTL builds). Introduced in Part 39. The `_Host*` implementations themselves live in `kfs/kos_fs_host_mgr.asm`; EMULIB just gives them a stable published address space. On real hardware every slot resolves to `_BadEmulibCall` (a clean diagnostic) rather than silently corrupting.

| File | Purpose |
|---|---|
| `kos_emulib.inc` | EMULIB jump-table public symbols (`EMULIB_HOST_LIST`/`MOUNT`/`UNMOUNT`/`CREATE`/`DELETE`/`RENAME`/`BAYNAME`/`FOPEN`/`FCLOSE`/`FREAD`, slot 63 `EMULIB_VERSION`); `EMULIB_BASE = $A200` |
| `kos_emulib_template.asm` | ROM template (64 JMP24 slots) + `_InitEmulib` (boot copy to RAM), `_BadEmulibCall` (diagnostic halt for unimplemented slots), `_EmulibVersion` |

#### `kosh/` — interactive shell (Phase 16.7+)

kosh is k/OS's production interactive shell — a small command-line task spawned at boot that provides the user-facing REPL. Built-in commands cover task and system inspection, memory peek/dump, filesystem operations (vol/ls/cat/cp/rm/mv/format/run plus the directory commands cd/pwd/mkdir/rmdir), host-disk management (disks/mount/unmount/mkdisk/rmdisk/rename/remount), and host file ingestion (`load`). The shell maintains a current directory (drive letter + directory cluster, `B:` root at boot) and passes that context into the file syscalls, so relative paths resolve inside subdirectories; switching drive is by a bare drive-letter line (`C:`) or a bare named-volume line (`rom:`, `fonts:`; see §14.3).

The shell is split per command group so individual command bodies can be added or removed without disturbing the dispatch core. kosh also acts as the canonical user task: anything it can do via syscalls, an arbitrary user `.COM` file can do too.

| File | Purpose |
|---|---|
| `kosh.asm` | Shell core: REPL loop, command dispatch (~33 commands via `cmd_table`), CWD state, bare drive-letter **and named-volume** switching, `fg` (Part 50), `_P2Main` entry |
| `kosh_boot.asm` | Kernel-side kosh boot scaffolding — copies the kosh image into a task page and starts it (`kosh.com` migration, Part 39) |
| `kosh_defs.inc` | kosh task-page layout and constants (canonical map; tagged `.SPACE kosh`). **Part 57** rebuilt the scattered Part-42..56 buffers into three tight, address-ordered regions on a high base — `KCORE` (`$8000`, persistent state), `KBUFS` (`$8100`, staging buffers), `KSTATE` (`$8800`, per-command scratch, zero-filled at entry). All slots symbol-addressed; see §2.6. |
| `kosh_helpers.asm` | CALL24/CALL16-callable helpers: emit byte/hex/word/dec, `_KoshParseAddr`, `_KoshSplitDrivePat` (drive + start-cluster split for glob), `_KoshStashCwd` / `_KoshResolveDstPath` (Part 44 cp/mv CWD context + dir-destination; returns `C=1` / `D0 = CP_ERR_TOOLONG` when the join exceeds `KOSH_NORM_LEN`, Part 63), `_KoshCopyBounded` (capacity-checked ASCIIZ copy, always nul-terminates, Part 63), `_KoshEmitPwdNamed` (named-volume / assign display for the prompt, `pwd`, and the `ls` header), `_KoshPrintErr` (human-readable error names), `_SlotForDrive` |
| `kosh_splash.asm` | Sign-on splash painted from kosh task context; pulls dynamic version/date from the kernel identity slots (`KOSINFO`, §2.2), Part 49 |
| `kosh_help.asm` | `help` command text + handler |
| `kosh_script.asm` | `.KSH` script runner (Part 57): `_KoshRunScript` (open + push fd), `_KoshScriptNextLine` (REPL line source — byte-at-a-time line assembly, `;`/blank skipping, echo, LIFO fd-stack pop), `_KoshCascadeAdvance` (A:→B:→C: `STARTUP.KSH` boot cascade), `_KoshNameIsKsh`. See §14.6 |
| `kosh_cmds_util.asm` | exit, echo, clear, halt, reboot |
| `kosh_cmds_sys.asm` | info, ps, task, kill, fg |
| `kosh_cmds_mem.asm` | peek, dump |
| `kosh_cmds_fs.asm` | vol, ls, cat, format, run, cp (Part 25 r1), rm + mv (Part 25 r2), load (Part 25 r6), mkdir + cd + pwd + rmdir (Part 44), assign (named drives v2, Parts 54–55) |
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

| Range | Size | Region | Contents |
|---|---|---|---|
| `$0000..$01FF` | 512 B | — | TRAP/INT vector table (128 slots x 4 bytes; ABI-fixed, not a region) |
| `$0200..$021B` | 28 B | `SYSVARS` | System + scheduler globals + `_BuildTask` scratch |
| `$021C..$0222` | 7 B | `HOSTVARS` | `KOS_HOST`, `PUTDEC_BUF` (`$0223` is a 1-byte pad) |
| `$0224..$022F` | 12 B | `HEAPGLOBALS` | Heap config + statistics (`KOS_PAGE_*` / `HEAP_*`) |
| `$0230..$023F` | 16 B | `RUNTIMESTATE` | `KOS_USER_PAGE_END`, `KERNEL_STATE`, `FOREGROUND_TCB`, `FIRST_SHELL_TID`, runtime pointers |
| `$0240..$025F` | 32 B | `BTNAME` | `BT_NAME` task-name staging buffer |
| `$0260..$03DF` | 384 B | `VOLTABLE` | Volume table (Phase 16 + Part 22; 6 x 64-byte slots A..F) |
| `$03E0..$03EF` | 16 B | `FSCACHE` | FAT cache state and dir/dirent caches (Phase 16, Part 22) |
| `$03F0..$03F3` | 4 B | `HEAPSCRATCH` | `HEAP_TID_QUERY` and `HEAP_RBT_REGION` (Phase 14 Part 3, kos_defs.inc r40) -- scratch for `_HeapStatsByTid` / `_ReapByTid` walks. Relocated 17 May 2026 from `$0330..$0333` after the page-$00 audit revealed `$033x` was inside the live volume table (Gotcha 4.26). |
| `$03F4..$03F5` | 2 B | `DISKFREE` | `DISKFREE_CLUSTER` -- Part 34 scratch for `_VolFreeClusters`: current cluster # being inspected, survives the `_FATGetEntry` call that clobbers D0/D1/D2/X0/X1. |
| `$03F6..$03F7` | 2 B | `DISKFREE` | `DISKFREE_COUNT` -- Part 34 scratch for `_VolFreeClusters`: running tally of free clusters during the FAT scan. |
| `$03F8..$03F9` | 2 B | `DISKFREE` | `DISKFREE_LIMIT` -- Part 34 scratch for `sys_diskfree`: caches the FAT scan's upper bound (first invalid cluster #) so `_VolFreeClusters` doesn't reload `VOL_TOTAL_CLUSTERS` and add the base each iteration. ~8K-cycle saving per call on a 1MB volume. |
| `$03FA..$03FF` | 6 B | — | Reserved (was part of `POOL_NAME_BUF` in Part 22; freed in Part 23) |
| `$0400..$047F` | 128 B | `SEMPOOL` | Counting-semaphore pool (Part 20b, 16 × 8-byte slots). Declarations live in `kos_defs.inc` (`SEMPOOL` region) as of Part 55 (previously in `kos_sem.asm`). |
| `$0480..$04D6` | 87 B | `FDSCRATCH` | FD scratch (Part 22 — relocated from `$0370` after volume-table expansion overlap; see Gotcha 4.25). Declarations live in `kos_fs_defs.inc` as of Part 36 (previously in `kos_fs_fd.asm`). |
| `$04D8..$04E3` | 12 B | `FESCRATCH` | FE scratch — `sys_exec` page-byte / chain-state slots (Part 36 — relocated from `$03BC` after the slot was found to overlap VOL_SLOT_F+$1C, smashing F:'s `VOL_BLOCKREAD_PTR` on every `sys_exec`; see Gotcha 4.47). Declarations live in `kos_fs_defs.inc`. |
| `$04E4..$0575` | 146 B | `RVSCRATCH` | Path/name resolver scratch (`RV_*`), incl. the PWD buffer (`RV_PWD_*`). Declared in `kos_fs_defs.inc`. |
| `$0576..$057B` | 6 B | `RNMSCRATCH` | Rename-operation scratch (`RNM_*`). Declared in `kos_fs_defs.inc`. |
| `$057C..$05CD` | 82 B | `LFNSCRATCH` | VFAT/long-filename assembly scratch (`LFN_*`, incl. `LFN_SHORT`). Declared in `kos_fs_defs.inc`. |
| `$05CE..$07CD` | 512 B | `ASSIGNTABLE` | Named-drive / assign table — 32 × 16-byte entries (`AS_*`; base `AS_TABLE_BASE`), Parts 54–55. Declared in `kos_fs_defs.inc`. |
| `$07CE..$07DF` | 18 B | `ASGNSCRATCH` | Assign resolver scratch (`ASGN_*`). Declared in `kos_fs_defs.inc`. |
| `$07E0..$07FF` | 32 B | — | Reserved (kernel growth). `KERNEL_ZP_NEXT_FREE` marks the start of this region. |
| `$0800..$277F` | 7.5 KB | `TCBPOOL` | TCB pool (63 x 128 bytes) |
| `$2780..$27BF` | 64 B | `KBDRING` | `KBD_RING_BUF` -- keyboard ring storage (Phase A) |
| `$27C0..$9FFD` | 30.4 KB | — | Kernel work area |
| `$9FFE..$9FFF` | 2 B | `KLIBSTATE` | KLIB internal state (xorshift seed) |
| `$A000..$A0FF` | 256 B | `KLIBTABLE` | KLIB jump table (64 entries x 4 bytes) |
| `$A100..$A1FF` | 256 B | — | Reserved (GLIB jump table -- future) |
| `$A200..$A2FF` | 256 B | — | EMULIB jump table — emulator-only host-disk bridge (64 × 4-byte JMP24; `.EQU`-defined in `emulib/kos_emulib.inc`, populated by `_InitEmulib` at boot). On FPGA/TTL builds slots resolve to `_BadEmulibCall` |
| `$A300..$A30B` | 12 B | `KOSINFO` | k/OS kernel identity words (version / build) |
| `$A30C..$BBFF` | ~6.2 KB | — | Kernel work area (continued) |
| `$BC00..$BDFF` | 512 B | `FSBUFS` | `FS_BUF_SECTOR` -- kernel sector scratch (Phase 16) |
| `$BE00..$BFFF` | 512 B | `FSBUFS` | `FS_BUF_FAT` -- FAT cache backing store (Phase 16) |
| `$C000..$FFFD` | 16 KB | — | Kernel stack region (stack grows down from $FFFE) |
| `$FFFE` | -- | — | `KERNEL_STACK_TOP` -- initial X3 |

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

As of Part 55 the entire page-`$00` layout is expressed with the assembler's `.REGION` / `.RS` reservation system (K16 ref §4.12): 23 collision-checked regions across `kos_defs.inc`, `kos_fs_defs.inc` and `kos_klib.inc`. Addresses are assembler-assigned, intra-region overlap is structurally impossible, and any symbol redefinition is a build error. The conversion was zero-drift — every address above is unchanged, verified by symbol-table diff. Part 55 also relocated the semaphore-pool definitions out of `kos_sem.asm` into `kos_defs.inc` (`SEMPOOL` region), so no `.asm` declares an absolute page-`$00` address any more. The `Region` column above names each block's region; the assembler's region map is the canonical layout audit.

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
- `$0400..$047F` -- counting-semaphore pool (Part 20b; defs in `kos_defs.inc` `SEMPOOL` region as of Part 55)
- `$0480..$04D6` -- FD scratch (relocated in Part 22 after volume-table expansion; declarations in `kos_fs_defs.inc` as of Part 36)
- `$04D8..$04E3` -- FE scratch (`sys_exec` page-byte / chain-state slots; relocated in Part 36 after collision with VOL_SLOT_F surfaced, Gotcha 4.47)
- `$04E4..$05CD` -- FS resolver scratch (`RVSCRATCH` / `RNMSCRATCH` / `LFNSCRATCH`; declared in `kos_fs_defs.inc`)
- `$05CE..$07DF` -- named-drive / assign table + resolver scratch (`ASSIGNTABLE` 32 × 16 B, `ASGNSCRATCH`; Parts 54–55, `kos_fs_defs.inc`)
- `$07E0..$07FF` -- reserved (kernel growth)

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

For a concrete instance of how a task lays out its own page — its buffers and scratch — see §2.6 (kosh).

### 2.6 kosh task page (KCORE / KBUFS / KSTATE)

kosh runs as an ordinary user task from `.ORG $0200` in its own page, so §2.5 applies. Above its code it declares three tight, single-purpose regions in `kosh_defs.inc` (Part 57), each tagged `.SPACE kosh`:

| Region | Range | Zeroed at entry | Contents |
|---|---|---|---|
| `KCORE` | `$8000..$8003` | no (explicit init) | persistent shell state: `KOSH_CWD` (drive letter), `KOSH_CWD_CLU` (directory cluster). Set at `kosh_entry` (`'B'` / root). |
| `KBUFS` | `$8100..$87F2` | no | staging buffers, each written-before-read within one command: `LINE_BUF` (80 B sys_gets target), `ROW_BUF` (96 B shared formatter), `DUMP_ROW` (16 B), `SIZE_FMT_BUF` (16 B), `KOSH_NORM_A` / `KOSH_NORM_B` (80 B each = `KOSH_NORM_LEN`, Part 63 — were 16 B), `CAT_BUF` (514 B), `LIST_BUF` (256 B), `CP_BUF` (512 B), `LS_DIRENT_BUF` (64 B), `GLOB_DIRENT_BUF` (64 B). 14 bytes spare before `KSTATE` at `$8800`; the assembler errors on region overflow, so the next field that does not fit fails the build rather than colliding. |
| `KSTATE` | `$8800..$887C` | **yes** | per-command scratch, grouped by command family (`DUMP_*`, `RUN_BG`, `ASN_*`, `PWDNM_*`, `LS_*`, `DISK_*`, `CP_*`, `LOAD_*`, `VOL_*`, `GLOB_*`, `CD_BARE`, `SCRIPT_*`). 69 words as of Part 61. |

**High base ($8000).** kosh.com is one upward-growing image from `$0200`. Earlier parts repeatedly collided code into buffers parked just above it (Part 40 @ `$4020`; Part 56 `LINE_BUF` @ `$5000`, which sat inside the then-`$529E` code image). Parking every region at `$8000+` gives ~32 KB of code runway (`$0200..$7FFF`) and ends that recurring bug class.

**Self-policing.** The regions are tagged `.SPACE kosh` and kosh's code space is pinned at `.ORG` (K16 ref §4.12 / `.SPACE`). The assembler's code-in-region guard hard-errors the instant emitted code grows into any of these regions, so the headroom needs no manual assertion. The kernel defs kosh `.INCLUDE`s for their constants (`kos_defs.inc` etc., `.SPACE kernel`) sit in a different space and never false-collide.

**Zero-fill.** A fresh task page inherits whatever was previously resident, so `kosh_entry` clears `KSTATE` before first use. The loop is driven by the assembler-emitted region symbols `KSTATE_START` / `KSTATE_WORDS` (`= KSTATE_SIZE/2`), so it tracks the region automatically — it does **not** need updating when fields are added. `KCORE` and `KBUFS` are deliberately outside the zero-fill (write-before-read, or explicitly initialised).

Everything below `KSTATE` up to the down-growing stack (~`$FE00`) is free; glob's match table is SP-relative and stays high, well clear of the fixed regions.

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
| `$04` | word | `TCB_PAGE_COUNT` | Number of contiguous pages owned, starting at `TCB_SAVED_Y` (low byte used). Part 60: this is the **extent** half of page ownership -- `_PageInUse` range-tests `[SAVED_Y .. SAVED_Y+PAGE_COUNT)`, so the field is load-bearing rather than reserved. Set from the `.COM` header's `pages` field via `BT_PCOUNT`. **Zeroed by `sys_exit` / `sys_kill`**, which releases the run at death while the TCB lingers in `TS_DEAD` holding only the exit status. `0` therefore means "owns nothing" and is the normal state of both the idle TCB and any unreaped corpse. |
| `$06` | word | `TCB_NEXT_TCB` | Next TCB in ready queue (low word) |
| `$08` | word | `TCB_WAKE_TICK` | `SYS_TICKS` value at which to wake (sleep) |
| `$0A` | word | `TCB_STATE` | One of `TS_*` values |
| `$0C` | word | `TCB_PRIORITY` | Reserved (Phase 2: always 0) |
| `$0E` | word | `TCB_ID` | Task ID 1..62 (monotonic since boot, never recycled) |
| `$10` | word | `TCB_QUANTUM` | Remaining time slice |
| `$12` | word | `TCB_FLAGS` | Task flags. Bit 1 = `TF_PRIV` ($0002, privileged); bit 2 = `TF_SYSCRITICAL` ($0004, may not be killed); bit 3 = `TF_HAS_BACKBUF` ($0008, registered shell with a back-buffer, Phase B); bit 4 = `TF_GRAPHICS` ($0010, owns the graphics screen, Part 49). `TF_FOCUSABLE` = `$0018` (bits 3 and 4 together, i.e. shell or graphics) -- the "may hold foreground / receive keys" predicate. Bit 5 = `TF_AUTOFG` ($0020, Part 51 — auto-foreground this task when it registers as a shell; set by `sys_exec` from the `EXEC_FOREGROUND` exec-flag, consumed and cleared by `sys_register_shell`). Bit 0 is the semaphore-internal `TF_SEM_KERNEL_WAITER`. Other bits reserved. |
| `$14` | word | `TCB_EVENT_MASK` | Pending events bitmap |
| `$16` | word | `TCB_PARENT_ID` | Parent's TCB ID (0 = kernel) |
| `$18` | word | `TCB_EXIT_CODE` | Exit code (valid in `TS_DEAD`) |
| `$1A` | word | `TCB_WAIT_ID` | Child TID this task is waiting on |
| `$1C` | word | `TCB_YIELD_COUNT` | Voluntary `sys_yield` count |
| `$1E` | word | `TCB_PREEMPT_COUNT` | Involuntary preemptions (timer) -- low word of a 32-bit counter |
| `$20` | word | `TCB_SEM_NEXT` | Next-waiter ptr in semaphore wait queue (Part 20b) |
| `$22` | word | `TCB_PREEMPT_COUNT_HI` | High word of 32-bit preempt counter (Phase B, 13 May 2026). Wraps at ~4 years @ 30 Hz. Offset $22 is outside imm5 range so accesses use mode-01 `[XY+D]`. |
| `$24` | word | `TCB_GFX_MODE` | Part 49: the graphics task's `VID_MODE` value (1..3), so the switcher can re-assert `VID_MODE` when this task regains foreground. Meaningful only when `TF_GRAPHICS` is set. |
| `$26..$4B` | 38 B | `TCB_RESERVED` | Growth space |
| `$4C` | word | `TCB_BACKBUF_OFFS` | Phase B: offset of this shell's back-buffer within its heap page. Valid iff `TF_HAS_BACKBUF` set. |
| `$4E` | word | `TCB_BACKBUF_PAGE` | Phase B: page byte of the back-buffer (low byte). With `$4C` forms the 24-bit back-buffer address. |
| `$50` | word | `TCB_SHELL_NEXT` | Phase B / Part 50: page-`$00` offset of the next shell's TCB in the ring. **`0` = lone shell / not in ring; non-zero = next shell's offset.** Used by `_SwitchForegroundNext/Prev`, `_SpliceAfterForeground`, `_ReapDeadTask`. |
| `$52` | word | `TCB_BACKBUF_CRSR` | Phase B: packed back-buffer cursor (high byte = row, low byte = col). Valid iff `TF_HAS_BACKBUF` set. (Was `TCB_SHELL_GEOM` before the back-buffer paging rework.) |
| `$60..$7F` | 32 B | `TCB_NAME` | Null-padded task name |

**Phase B / Part 49 field semantics.** When `TF_HAS_BACKBUF` is set, the back-buffer fields (`$4C`/`$4E`/`$50`/`$52`) are valid. The output syscalls test `TF_HAS_BACKBUF` at entry: if clear, they emit directly to the terminal MMIO; if set, they route via `_BackbufPutChar`, which writes to the back-buffer and also emits to the terminal only when this task is the foreground shell. A **graphics task** (`TF_GRAPHICS` set, Part 49) is also a ring member but has no back-buffer: it joins the ring through `TCB_SHELL_NEXT` and records its `VID_MODE` in `TCB_GFX_MODE`, but its `TCB_BACKBUF_*` fields stay zero. `TF_FOCUSABLE` (`$0018`) is the predicate the switcher and `sys_setforeground` test for ring membership and foreground eligibility -- it covers both shells and graphics tasks. See §13 (Foreground switcher).

### 3.3 Task states

| Value | Symbol | Meaning |
|---|---|---|
| 0 | `TS_READY` | On the ready queue, eligible to run |
| 1 | `TS_BLOCKED` | Sleeping until `TCB_WAKE_TICK` <= `SYS_TICKS` |
| 2 | `TS_DEAD` | Has exited. **Pages are already released** (Part 60: `TCB_PAGE_COUNT` is zeroed at death); the TCB lingers only to hold `TCB_EXIT_CODE` for a future `sys_wait`. |
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
4. Mark `TCB_STATE = TS_UNUSED`, freeing the TCB slot.

Note that reap no longer has anything to do with **pages**. Before Part 60 the
run was released here, as a side effect of the slot going `TS_UNUSED`; since
Part 60 `sys_exit` and `sys_kill` zero `TCB_PAGE_COUNT` at the moment of
death, so the pages are already back in the pool by the time anything reaps.
See §7.4.

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

**Compliance status.** As of Part 61 (2 August 2026) the V2 ABI is
enforced across all 49 syscall handlers. **Between Part 36 and Part 61 this
section was wrong**: it claimed a full audit while nineteen handlers did not
in fact preserve `XY2`, four of them demonstrably (`sys_open`, `sys_write`,
`sys_mkdir`, `sys_diskfree`). See the Part 61 note below. The original
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
K16 ISA Gotchas #31 (clobbered D2/D3 in sys_read), Gotcha 4.45
(TRAP handlers must explicitly preserve XY1), and Gotcha 4.59
(sys_putdec leaked XY2, corrupting K16Pascal multi-arg function
results) for examples.

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

**`XY2` and the Pascal frame pointer (Part 61, 2 August 2026).** `XY2` had
been listed as preserved since Part 20a, but nineteen handlers did not do it.
The reason it went unnoticed for so long is the shape of the failure, and it
is worth stating plainly because it will be the shape next time too.

`X2:Y2` is the K16 Pascal frame pointer. Every parameter, every spilled local
and every function RESULT is addressed as `[XY2+#N]`. A handler that returns
with `XY2` disturbed does not produce a wrong result — it corrupts the
**caller's frame**, and only for callers that touch a parameter or return a
value *after* the call. A Pascal `Boolean` function that opened a file and
then returned `True` returned `False`; one that made no syscall was fine.
Nothing fails near the syscall that caused it.

The clobber is rarely visible in the handler either. `sys_open` contained
exactly one `XY2` reference of its own; the damage came three levels down in
`_SlotForDrive`, which returns the volume-slot address in `X2` with `Y2` set
to `$00` — the kernel page. **So the requirement is unconditional.** Do not
audit a handler's body and skip the save because it appears not to use `XY2`;
one edit to a shared helper silently breaks every caller audited clean last
month.

Why the drift happened at all: each handler's own header comment restated the
contract as `D1, D2, D3, XY1 all callee-preserved across syscalls`, omitting
`XY2` and contradicting this manual. The per-handler comment is what an
implementer reads. Those restatements are now replaced by a pointer to a
single authoritative statement in `kos_defs.inc` (`SYSCALL REGISTER
CONTRACT`), and no copy of the old sentence survives in the tree.

**Three exemptions, and only these:**

1. Handlers that never return (`sys_exit`) — nothing to restore.
2. Tail calls (`sys_getchar` → `_GetGatedKey`) where the *target* documents
   `Preserves: … XY2`. A `PUSH` before a `BRA` leaks the task stack.
3. Leaves that make no calls, never name `XY2`, and exit via `RETCC`/`RETCS`
   (`sys_termsize`, `sys_cursorvis`, `sys_wherexy`, `sys_getpid`). An
   outstanding `PUSH` under a conditional return leaks on the taken arm, so
   these carry a `Preserves:` line instead of instructions.

`PUSH`/`POP` are flag-transparent (except `POP SR`), so the restore may sit
after a `POP SR` gate without disturbing the result carry.

Regression cover: `SyscallFrameTest.pas` (K16 Pascal `tests\`) calls each
syscall from inside a `Boolean` function and then checks **two** independent
frame paths — the RESULT slot, and a `var String` parameter read back with
`Length`. A test that only checked the return value would pass on a compiler
that happened to keep results in a register.

This is the second time `XY2` has done this; Gotcha 4.59 records `sys_putdec`
leaking it and corrupting K16 Pascal function results. That one was fixed
locally without generalising, which is exactly how the remaining nineteen
survived.

### 5.1 Console I/O

**Output routing (summary; full mechanism in §13.2).** The seven output
syscalls (`sys_putchar`, `sys_puts`, `sys_putlp`, `sys_putdec`,
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

#### `sys_kbhit` -- TRAP #79 [LEAF]

Non-blocking counterpart to `sys_getchar`. Consumes a key if one is
waiting; reports empty and returns immediately if not.

```
In:       (none)
Out:      key waiting    D0 = byte (zero-extended), C = 0
          none waiting   D0 unspecified,            C = 1
Clobbers: D0, D1, XY0
Preserves: D2, D3, XY1, XY2, XY3
```

**Why it exists.** An animated graphics task cannot use `sys_getchar`:
it blocks, which freezes the animation on its first frame. Polling the
ring directly is not an option either — `KBD_HEAD`/`KBD_TAIL` and
`KBD_RING_BUF` live in kernel page `$00`, unreachable from a user task
under paged protection, and the invariant above reserves the MMIO to
`_KbdTick`. Cube6 polls once per frame and exits on any key.

**Routing** is `_GetGatedKey`'s (§13.11) minus the waiting. A focusable
task — shell *or* graphics — sees keys only while it holds the
foreground; a plain task reads the ring directly. The difference is what
happens at a shut gate: `_GetGatedKey` yields and re-gates, `sys_kbhit`
reports "no key". A backgrounded caller therefore spins its own loop
without ever seeing input, which is intended — the foreground task owns
the keyboard.

Both arms tail-call `_RingPop`, so its `RETCC`/`RETCS` becomes the
syscall's return.

**No `DINT`.** `_RingPop` is the documented non-blocking consumer and
the ring is single-producer (`_RingPush`, in the timer IRQ, writes HEAD
only) / single-consumer (writes TAIL only), so a poll cannot race the
driver.

**It pops, it does not peek.** There is currently no way to inspect the
ring without consuming. A key typed before the poll — during a long
render, say — is consumed by the first `sys_kbhit` that runs, so an
"any key quits" loop can quit on a keystroke typed minutes earlier.
See §5.4a on stale input.

#### 5.4a Stale input and the global ring

There is **one** keyboard ring for the whole system. `_RingPush` is
unconditional: every non-hot-key keystroke enters it regardless of which
task is foreground. The foreground gate is entirely on the *consumer*
side (`_GetGatedKey`, `sys_kbhit`).

A task that does not read for a long time therefore accumulates input
aimed at it, and whatever it does not consume is inherited by the next
task to read. A graphics program that renders for minutes and then does
one `TRAP_GETCHAR` will consume one queued byte immediately (dismissing
its own finished image) and leave the rest to land on kosh's command
line.

A program that wants a genuine keypress should drain first:

```asm
.drain:         TRAP    #TRAP_KBHIT
                BCC     .drain          ; consumed one - keep going
                TRAP    #TRAP_GETCHAR   ; now block for a real key
```

Flushing the ring kernel-side on a foreground switch was considered and
rejected: it would also discard type-ahead across `Ctrl-N` between
shells, which is legitimate use. Per-task input queues would express the
intent properly and are not planned.
Doing so races with the ring producer (see Gotchas 4.37).

#### `sys_puts` -- TRAP #12 [NON-LEAF]

Write a nul-terminated string. Atomic against other writers via `DINT`/`EINT`.

```
In:       XY0      nul-terminated string
Out:      D0       byte count emitted (excluding nul)
          C = 0
```

#### `sys_putlp` -- TRAP #13 [NON-LEAF]

Write a length-prefixed (Pascal) string. The kernel reads the leading length
byte at `[XY0]` and emits that many characters. Atomic against other writers
via `DINT`/`EINT`. Reclaims the TRAP #13 slot vacated by `sys_putln` (Part 60);
no terminator is consulted and none is emitted.

```
In:       XY0      pointer to a length-prefixed string:
                   [XY0] = length byte (0..255); [XY0+1..] = characters
Out:      D0       byte count emitted (= length)
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

#### `sys_termsize` -- TRAP #19 [LEAF]

Return the live terminal geometry.

```
In:       none
Out:      D0       columns
          D1       rows
          C = 0
```

EMU reads `(cols<<8)|rows` from the host size MMIO (`$DB:$0000`), which tracks the vt100/browser window live. Digital has no size register and returns the fixed `KOS_TERM_COLS` × `TERM_ROWS_DIGITAL` (80 × 24). Note: a shell's `TCB_VIS_ROWS` is a *snapshot* taken at `sys_register_shell` (fallback `KOS_TERM_ROWS`) — it does not track a later window resize; `sys_termsize` is the live source.

#### `sys_setattr` -- TRAP #20 [LEAF]

Set the current text attribute — a VGA byte: foreground in bits 0..3, background in bits 4..6, bit 3 = bright/intensity. Stamped into cells written after this call; foreground shells also emit the equivalent SGR live.

```
In:       D0       attribute byte
Out:      C = 0
```

#### `sys_clreol` -- TRAP #21 [NON-LEAF]

Clear from the cursor to end-of-line, blanking with the *current* attribute (background-colour-erase). Shell: blanks grid cells `col..79` on the cursor's physical row; foreground also emits `ESC[K`.

```
In:       none
Out:      C = 0
```

#### `sys_cursorvis` -- TRAP #22 [LEAF]

Show or hide the cursor. Structural replacement for the old `__hidecursor`/`__showcursor` escape-into-stream calls: the escape is emitted from this verb against known grid state, never stored as a cell.

```
In:       D0       0 = hide, non-zero = show
Out:      C = 0
```

#### `sys_wherexy` -- TRAP #23 [LEAF]

Report the cursor position (0-based).

```
In:       none
Out:      D0       column (0-based)
          D1       row (0-based)
          C = 0
```

#### `sys_clreos` -- TRAP #24 [NON-LEAF]

Clear from the cursor to end-of-screen, blanking with the *current* attribute (background-colour-erase). Shell: blanks cursor..EOL then every visible row below (full width) up to `TCB_VIS_ROWS`; foreground also emits `ESC[J`.

```
In:       none
Out:      C = 0
```

These six verbs are the Part-57/58 console-attribute set, exposed to K16Pascal via `console.pas` as `TextAttr`/`TextColor`, `ClrEol`, `CursorVis`, `WhereX`/`WhereY`, `ClrEos` (`GotoXY` is `sys_setcursor`, Row/Col order). `Attr(f,b) = f + b*16`.

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
| 13 | `sys_putlp` | non-leaf | atomic, length-prefixed |
| 14 | `sys_gets` | non-leaf | line-buffered, blocks |
| 15 | `sys_putdec` | non-leaf | atomic |
| 16 | `sys_puthex` | non-leaf | atomic |
| 17 | `sys_clear` | non-leaf | |
| 18 | `sys_setcursor` | non-leaf | |
| 19 | `sys_termsize` | leaf | live terminal geometry (EMU MMIO / Digital 80×24) |
| 20 | `sys_setattr` | leaf | set current text attribute (VGA byte) |
| 21 | `sys_clreol` | non-leaf | clear to EOL, background-colour-erase |
| 22 | `sys_cursorvis` | leaf | show/hide cursor |
| 23 | `sys_wherexy` | leaf | report cursor col/row (0-based) |
| 24 | `sys_clreos` | non-leaf | clear to EOS, background-colour-erase |
| **— Task** | | | |
| 25 | `sys_getpid` | leaf | |
| 26 | `sys_yield` | non-leaf | |
| 27 | `sys_exit` | non-leaf | does not return |
| 28 | `sys_sleep` | non-leaf | |
| 29 | `sys_spawn` | non-leaf | |
| 30 | `sys_wait` | non-leaf | blocks |
| 31 | `sys_exec` | non-leaf | loads `.COM` from disk, spawns as new task; D0 = TID. Input `D0` = flags: bit 1 `EXEC_FOREGROUND` ($0002) tags the child `TF_AUTOFG`, so it auto-foregrounds when it registers as a shell (Part 51, §13.13). |
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
| 60 | `sys_open` | non-leaf | path → fd; CREATE/TRUNC/APPEND flags. Part 44: D1 = CWD cluster, D2 = CWD drive (resolve relative path; `X:` overrides) |
| 61 | `sys_close` | non-leaf | flushes dirent + FAT on dirty fd |
| 62 | `sys_read` | non-leaf | reads up to count bytes; D0 = bytes read or 0 at EOF |
| 63 | `sys_write` | non-leaf | writes up to count bytes; allocates clusters as needed. On failure (C=1), D1 = bytes-written-before-failure — see §11.6 partial-progress reporting |
| 64 | `sys_dirent` | non-leaf | iterates a directory by index. Phase 2a: D2 = start cluster (0 = root, ≥2 = subdir); returns `.`/`..` in subdirs |
| 65 | `sys_format` | non-leaf | reformats a writable volume; writes fresh BPB+FAT+root, sets label, re-mounts |
| 66 | `sys_unlink` | non-leaf | delete a file (resolve-aware, D1/D2 CWD context); refuses if file is open in any fd table |
| 67 | `sys_rename` | non-leaf | in-place rename within the same drive **and** parent dir (D1/D2 CWD context); other moves are kosh-side cp+unlink |
| 68 | `sys_diskfree` | non-leaf | scan FAT free list; D0 = free clusters, D1 = total clusters, D2 = cluster size (bytes). Part 34 |
| 69 | `sys_mkdir` | non-leaf | Phase 2a: create a directory (nested, e.g. `B:FOO/BAR`); inits `.`/`..`. D0/D1 = CWD drive/cluster |
| 70 | `sys_resolve` | non-leaf | Phase 2a: resolve a path to D0=drive, D1=cluster, D2=attr (stateless; D0/D1 in = CWD context) |
| 71 | `sys_pwd` | non-leaf | Phase 2a: build `X:/...` path string from D0=drive, D1=cluster into XY0 dest |
| 72 | `sys_rmdir` | non-leaf | Phase 2a: remove an empty directory (refuses `.`/`..`/root). D0/D1 = CWD drive/cluster |
| **— Device** | | | |
| 75 | `sys_setvidmode` | DINT-leaf | Part 20: acquire/release/change VID_MODE with single-owner ownership; auto-released on owner death |
| 76 | `sys_setforeground` | leaf | Phase B: set FOREGROUND_TCB to a specific TID. Privileged (TF_PRIV required). Used by kosh's `fg <tid>` command. |
| 77 | `sys_register_shell` | non-leaf | Phase B: allocate back-buffer, set TF_HAS_BACKBUF, insert into shell ring. First caller becomes foreground; subsequent callers register as background shells — unless the caller carries `TF_AUTOFG` (Part 51), in which case it takes the foreground on registration and wakes its blocked launcher with `ERR_DETACHED` (§13.13). C=1 / ERR_NOMEM if heap exhausted. |
| 79 | `sys_kbhit` | leaf | non-blocking key poll; C=1 = ring empty. Consumes. Foreground-gated for focusable tasks exactly as `sys_getchar` is. |
| 78 | `sys_assign` | non-leaf | Parts 54–55: create / clear a named-volume or path-mount entry in the assign table (`ASSIGNTABLE`, §2.2). Stores `(drive, cluster)`; the target is pre-resolved via `sys_resolve` (#70). Backs kosh's `assign` command (§14.4). |

Slots in per-group reserve (19..24, 33..39, 42..49, 54..59, 73..74, 80..84) and the Reserved tail (85..127) are uninitialised at boot and resolve to the bad-trap handler, which prints a diagnostic and halts.

**New Part 20 entries (sys_kill, sys_setvidmode):** see §5.6 and §5.7 below.

**Phase B entries (sys_setforeground, sys_register_shell):** see §13 (Foreground Switcher).

### 5.5 Semaphores (Part 20b)

k/OS provides counting semaphores for inter-task synchronisation.
The implementation lives in `kos_sem.asm`. A semaphore is a small
piece of kernel state representing a counter and a FIFO wait queue;
tasks coordinate by atomically decrementing (taking) and incrementing
(giving) the counter, blocking when the counter would go negative.

#### 5.5.1 Pool layout

A static pool of 16 semaphores lives at `$00:$0400..$00:$047F`
(8 bytes per slot; pool base and slot constants are declared in `kos_defs.inc` as the `SEMPOOL` region since Part 55, with `kos_sem.asm` retaining only the primitives). The slot layout is:

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

### 5.7 sys_setvidmode (Part 20; Part 49 graphics-foreground integration)

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

**Part 49 — graphics tasks join the foreground ring.** Acquiring graphics is no
longer just an MMIO ownership flip; the caller becomes a focusable foreground
member so it can receive keyboard input and survive shell switching. On a
successful **acquire** (unowned → owned) the kernel additionally:

1. Sets `TF_GRAPHICS` ($0010) in the caller's `TCB_FLAGS` (making it
   `TF_FOCUSABLE` if it was a shell, or focusable-as-graphics otherwise).
2. Records the requested mode in `TCB_GFX_MODE` ($24), so the switcher can
   re-assert `VID_MODE` when this task later regains foreground.
3. Splices the caller into the foreground ring immediately after the current
   foreground via `_SpliceAfterForeground` (see §13.11/§13.12), and makes it
   the new foreground.
4. The host follows the `VID_MODE` write to the graphics tab/panel; on EMU and
   WebEMU the display switches to the graphics surface.
5. **Part 61:** releases a launcher blocked in `sys_wait` on this task, by the
   same mechanism `sys_register_shell` uses for a shell (`_FindWaiterFor` →
   `_DeliverWaitDetached` → `TS_READY`, with the `TF_DETACH_PENDING` arm when
   the launcher has not reached `sys_wait` yet). Skipped when the caller
   already carries `TF_HAS_BACKBUF` — a registered shell detached its launcher
   at register time, and repeating it would strand a spurious one-shot flag.
   See §13.13.

   Without this step a graphics task launched without `&` was unkillable: it
   never exits on its own, and `sys_kill` admits only a privileged caller or
   the parent — which was the very task left blocked. `Ctrl-N` reached the
   launcher's back-buffer but the shell behind it was frozen, so the only exit
   was Reset.

On **release** (mode 0 by the owner) the kernel reverses all of the above:
clears `TF_GRAPHICS` and `TCB_GFX_MODE`, unsplices the task from the ring (via
the same reap-style hand-back used by `_ReapDeadTask`), hands foreground back to
the next ring member, and the host returns to the text terminal. A graphics task
that simply exits or is killed gets the identical cleanup through
`_VideoForceReset` + `_ReapDeadTask` — no task action required.

**Mode change while owned** (owner calls with a different non-zero mode) updates
`VID_MODE` and `TCB_GFX_MODE` but does not re-splice — the task is already a
foreground ring member.

**Auto-release on death.** Both `sys_exit` and `_HandleDeadTCB` (used by sys_kill) call `_VideoForceReset(dying_TID)`. If the dying task owns VID_MODE, the kernel writes `VID_MODE = 0` and clears `VIDEO_OWNER_TID`. The screen returns to text mode automatically — no task action required.

**Enforcement model.** The driver is a **convention layer**, not enforcement. The hardware MMIO at $DD0000 is accessible to any task that knows the address; well-behaved tasks go through `sys_setvidmode`, ill-behaved tasks can bash it directly. A direct bash bypasses ownership tracking, so the kernel won't auto-restore text mode when the bashing task dies. Hardware enforcement (microcode trap or page-level write protection) would close the hole; not worth doing for the single-user system today.

**VID_PAGE not mediated — and not initialised.** The framebuffer page register at $DC0000 is still task-bashable. The implicit policy is "the VID_MODE owner is also entitled to bash VID_PAGE for framebuffer flipping". Future multi-task graphics would need a `sys_setvidpage` syscall.

The kernel **never writes $DC0000 at all** — `_InitVideo` zeroes `VID_MODE` and nothing else. A newly acquired graphics task therefore inherits whatever page the *previous* graphics task last selected, which for a double-buffering program like Cube6 is `$B0` or `$B4` depending on which frame it died on. A task that renders into `$B0_0000` without programming VID_PAGE is correct and invisible, intermittently: it works if the register happens to hold `$B0` and shows nothing otherwise. **Every graphics task must program VID_PAGE itself after acquiring the mode.** KGFX does this in `gfx_open`; Mandelbrot was fixed to do it inline (8 August 2026). Cross-references `kOS_Gotchas` §4.61.

**Example.** Cube4's startup (`Gfx-Cube.asm`):

```asm
                LOADI   D0, #2                  ; VID_MODE_640x480_VGA
                TRAP    #TRAP_SETVIDMODE
                BCS     .vid_busy               ; ERR_BUSY → bail
                ; ... initialise framebuffer ...
                BRA     frame                   ; main loop

.vid_busy:
                LEA     XY0, msg_vid_busy
                TRAP    #TRAP_PUTS
                LOADI   D0, #CH_LF
                TRAP    #TRAP_PUTCHAR
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

The page allocator manages the user-task page region (`$02..$KOS_USER_PAGE_END`). It is a pair of routines in `kos_tcb.asm`: `_AllocPageRun` and `_PageInUse`, with `_AllocPage` retained as a single-page wrapper.

Since **Part 60** a task may own a **run** of N contiguous pages rather than exactly one. N is declared in the `.COM` header (§11.9) and granted at load time, or the task does not start at all.

### 7.1 No bitmap -- the TCB pool is the truth

There is no separate ownership bitmap. The set of pages currently in use is derived directly from the TCB pool: a page is owned if and only if some TCB in state `!= TS_UNUSED` owns a **run** covering it --

```
owned(p)  :=  exists TCB, state != TS_UNUSED, and
              p >= TCB_SAVED_Y  and  p < TCB_SAVED_Y + TCB_PAGE_COUNT
```

so base page `$04` with count 2 owns `$04` and `$05`, and `$06` is free.

This is cheaper than maintaining a bitmap (no synchronisation, no consistency-update on every state change) at the cost of slightly more work per allocation. With a 62-slot TCB pool and pages allocated rarely (only at spawn), the cost is negligible -- under a millisecond at 10 MHz in the worst case.

**Contiguity is what makes this work.** Because a run is contiguous and starts at the task's own page, a single TCB field describes the whole set. That is what keeps release free: there is no `_FreePage` and no bitmap to update, so zeroing one field (§7.4) or reaping the slot makes the *entire* run vanish from the scan at once.

A count of `0` yields an empty range -- the task owns nothing. This is the normal state of the idle TCB and of any `TS_DEAD` corpse.

### 7.2 `_PageInUse`

```
In:       D0       candidate page byte ($02..ceiling)
Out:      C = 0    page is free (no live TCB's run covers it)
          C = 1    page is inside some live TCB's run
          D0       preserved
Clobbers: flags only
```

Walks the user TCB pool (`USER_TCB_BASE` for `USER_TCB_COUNT` TCBs) and range-tests each non-`TS_UNUSED` slot. Early exit on first match. Cost ~ 320 cycles worst case.

**Carry sense.** K16 is 6502-style: after `CMP A,B`, `C = 1` means *no borrow*, i.e. `A >= B` unsigned; `C = 0` means borrow. Both bounds tests branch on `BLO` (`C = 0`), to opposite targets.

`TS_DEAD` slots are still scanned, but since Part 60 their `TCB_PAGE_COUNT` is zero, so they match nothing. See §7.4.

### 7.3 `_AllocPageRun` and `_AllocPage`

```
_AllocPageRun
In:       D0       N, pages wanted (>= 1)
Out:      D0       base page byte of the run, C = 0
          D0       0, C = 1                if no such run exists (ERR_NOMEM)
Clobbers: flags only (D1/D2/D3 preserved)
```

Scans candidates from `USER_PAGE_BASE = $02` upward, calling `_PageInUse` on each and carrying a **consecutive-free run length**; an owned probe resets the run to zero. This is one probe per candidate, not N per candidate -- the worst case is the same ~62 probes as a single-page scan, so a large N costs nothing extra. Returns the **lowest qualifying run**, deterministic across boots. Walks at most to `KOS_USER_PAGE_END` (host-dependent: `$1F` on Digital = 30 pages, `$3F` on EMU = 62 pages) before declaring exhaustion.

`_AllocPage` is a two-instruction wrapper (`LOADI D0,#1` / `JMP24 _AllocPageRun`) with an unchanged contract, so `sys_spawn`, `sys_exec` and `_SpawnShell` needed no edit at their call sites.

**Fail-fast is deliberate.** A task that cannot get its pages is dead. Failing in the loader means the *parent* handles `ERR_NOMEM` -- kosh prints it and returns to the prompt -- whereas failing part-way through initialisation would leave a half-built task with pages already consumed.

**Two limitations, recorded as choices rather than oversights:**

- **No dynamic growth.** A task cannot request more pages after it starts.
- **Fragmentation is possible.** A run of 2 can fail while 5 pages are free but scattered, because the scan requires adjacency. With allocation only at spawn, release only at death, and few concurrent tasks this is unlikely; `N = 1` is unaffected either way.

**Pages are not cleared on allocation.** A multi-page task sees the previous tenant's bytes in its extra pages, exactly as it already does below `$0200` in its own page -- which is why `sys_exec` must *stamp* `ARGV_BASE` rather than trust a zero there. Any task using its extra pages must write before it reads.

### 7.4 Page release -- at death, not at reap

There is no `_FreePage` routine. Since **Part 60** the run is released the moment the task dies:

- `sys_exit` and `sys_kill` mark the TCB `TS_DEAD`, store `TCB_EXIT_CODE`, and **zero `TCB_PAGE_COUNT`**. The range becomes empty, so `_PageInUse` stops seeing the pages immediately and the next `_AllocPageRun` may hand them out.
- The TCB itself lingers in `TS_DEAD` until reaped, preserving the exit code for a future `sys_wait`.
- `_ReapDeadTask` frees the **TCB slot** (`TS_UNUSED`). It has nothing to do with pages.

This is the Unix split: a zombie holds a *status*, not an address space. Before Part 60 both were held until reap, so a backgrounded task that exited with no waiter held its page forever. With multi-page tasks that became material -- a few such corpses could exhaust Digital's 30-page range.

`TCB_SAVED_Y` is deliberately **not** cleared: `ps` still shows where the task lived, and `_PageInUse`'s first comparison wants a base even when the extent is zero.

**TCB slots still leak** if nothing reaps. That is the Unix behaviour and is tolerable at 62 slots of 128 bytes. Candidate future work: a fallback sweep in `_AllocTCB` that reaps `TS_DEAD` TCBs whose parent is gone (those can never be waited on, so nothing is lost), plus a prompt-time reap in kosh for its own background children.

### 7.5 Multi-page tasks

A task declares its page count in the `.COM` header (§11.9). The loader reads the header **from the file**, before allocating, then either grants exactly that many contiguous pages or refuses to start the task.

```
MyPage                       code, globals, stack   (the primary page)
MyPage + 1 .. MyPage + n     the task's extra pages
```

Only the **primary** page receives the image; the extra pages are blank workspace. `SPAWN_MAX_LEN` (`$FE00`) plus `$0200` is exactly `$10000`, so an image can never cross into them.

A task discovers its own run with no syscall and no kernel support:

```asm
                MOVE    D0, Y3                          ; D0 = run base page
                LOADP   D0, Y3, [#COM_HDR_PAGES]        ; D0 = page count
```

`Y3` is the definitional base -- it is the value the scheduler restores *and* the value `_PageInUse` range-tests, not merely where the code happens to sit. The count comes from the task's own header at `$0208`, which is authoritative because the allocation contract is "exactly N or fail", so the header cannot disagree with what the loader did.

**Sequential access across a run must be 24-bit.** `ADD Xn, #k` is 16-bit and wraps silently at the page boundary; `INC XYn, #kw` and STREAM `[XYn]+` propagate the carry into the page byte. Any walk through a structure larger than 64 KB must use the latter. This is a correctness rule, not an optimisation, and it is the kind that produces a bug appearing only in data over 64 KB -- see `PAGETEST.asm`, which demonstrates both behaviours rather than asserting either.

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

`_KbdDispatch` is the **policy seam** for the foreground switcher. In Phase A its
body was empty (every byte fell through to `_RingPush`); as of Phase B it prepends a
hot-key filter that consumes switcher keys before they reach the ring — Ctrl-N (`$0E`)
→ next shell, Ctrl-P (`$10`) → previous, and Ctrl-1..0 (`$81..$8A`) → jump-by-index
(see §13.7). The `_TimerIRQ` `_KbdTick` block itself is unchanged between phases — only
`_KbdDispatch`'s body grew.

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

## 11. Filesystem (Phase 16, Parts 22-26, Phases 2a/2b)

The filesystem layer adds FAT16 support to k/OS. Phase 16 introduced the core FAT16 implementation across `kos_fs.asm` (top-level mount, format, FAT operations, cluster allocation), `kos_fs_dir.asm` (8.3 name conversion, directory iteration, entry create/delete), `kos_fs_fd.asm` (per-task fd table and the file syscalls TRAPs 26..30), `kos_fs_exec.asm` (Piece 6 — `sys_exec`), `kos_fs_ram.asm` (RAM disk block backend), and `kos_fs_rom.asm` (ROM disk block backend). Filesystem-internal constants live in `kos_fs_defs.inc`.

Parts 22 and 23 added a host-disk subsystem: `kos_fs_host.asm` (block-layer backend serving drives C..F via the K16 disk-controller MMIO at `$DA0000`) and `kos_fs_host_mgr.asm` (kernel-side wrappers for the controller's management commands).

Part 24 extended host-disk management with `_HostRename` (renames a bay's bound file in place, keeping the mount intact) and `_HostBayName` (reads a bay's bound filename — used to default the FAT16 label when formatting a host disk). Part 24 also simplified mount semantics: bay-bind and FS-mount are now independent two-phase operations (see §11.6 of the FS Reference), removing the previous auto-rollback when FS-mount failed.

Part 25 added two filesystem syscalls — `sys_unlink` (TRAP #66) and `sys_rename` (TRAP #67) — plus three new host-management helpers — `_HostFOpen` / `_HostFRead` / `_HostFClose` — that implement a streaming file-load surface used by kosh's `load` command. The kosh layer also gained a current working drive (CWD) model with bare drive-letter switching, a `cp`/`rm`/`mv` command family, the `load` command for ingesting host files, and human-readable error names via `_KoshPrintErr`.

**Phase 2a (subdirectories)** added a kernel path resolver (`_Resolve` / `_ResolveParent`, walking `/`-separated components via `DIR_WALK_CLU`) and four syscalls: `sys_mkdir` (#69), `sys_resolve` (#70), `sys_pwd` (#71), `sys_rmdir` (#72). `sys_dirent` gained a `D2` = start-cluster argument so a subdirectory (or the CWD) can be listed. **Phase 2b / Part 44** threaded CWD context (drive + cluster) through `sys_open`/`sys_unlink`/`sys_rename`/`sys_exec`, grew the fd entry to 14 bytes (`FD_DIR_CLUSTER`, so a dirent flush finds the right directory), and made the kosh `cat`/`rm`/`run`/`cp`/`mv` commands — literal and wildcard — CWD-relative and subdirectory-aware (including directory-destination `cp`/`mv` and subdirectory glob). `cd`/`pwd`/`mkdir`/`rmdir` are first-class shell commands.

Implementation status: Pieces 1–6, Parts 22–26, and Phases 2a + 2b are complete and verified. See `kOS_FS_Reference v1.15` for the design specification.

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

Each task has a private 8-entry file descriptor table at `user_page:$000C..$007B` (112 bytes, 14 bytes per entry — Part 44 grew it from 12 to add `FD_DIR_CLUSTER`). File descriptors are integer indices `0..7` returned by `sys_open` and consumed by `sys_close`, `sys_read`, `sys_write`. They are valid only within the task that opened them; passing an fd to another task is undefined.

The fd table physically lives in the running task's primary page, addressed via `Y3` (the per-task page register). Each entry layout:

| Offset | Width | Field | Notes |
|--------|-------|-------|-------|
| `$00` | byte | `FD_FLAGS` | OPEN, READ, WRITE, DIRTY, ROM bits |
| `$01` | byte | `FD_DRIVE` | drive index 0=A: … 5=F: |
| `$02` | word | `FD_FIRST_CLUSTER` | first data cluster (0 if empty file) |
| `$04` | word | `FD_CURR_CLUSTER` | cached: current cluster for sequential I/O |
| `$06` | word | `FD_DIR_COOKIE` | dirent location for flush on close |
| `$08` | dword | `FD_POSITION` | byte offset within file (ends `$0B`) |
| `$0C` | word | `FD_DIR_CLUSTER` | Part 44: cluster of the directory holding this file (dirent flush on close) |

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

The filesystem uses the `$FFE7..$FFD9` error block (defined in `kos_fs_defs.inc`), returned on the carry channel (C=1 with the code in `D0`):

| Constant | Value | Meaning |
|----------|-------|---------|
| `ERR_NOFD` | `$FFE7` | per-task fd table full |
| `ERR_BADFD` | `$FFE6` | fd is not open (or wrong access mode) |
| `ERR_BADPATH` | `$FFE5` | path is malformed |
| `ERR_NOTFOUND` | `$FFE4` | file / directory does not exist |
| `ERR_EXISTS` | `$FFE3` | file exists (CREATE + EXCL) |
| `ERR_READONLY` | `$FFE2` | write rejected on a read-only volume |
| `ERR_NOSPACE` | `$FFE1` | disk full (no free cluster) |
| `ERR_IO` | `$FFE0` | block-layer read/write failed |
| `ERR_BADDRIVE` | `$FFDF` | drive letter not mounted |
| `ERR_NOMORE` | `$FFDE` | directory iteration ended |
| `ERR_NOTEXEC` | `$FFDD` | `sys_exec` on a non-`.COM` file |
| `ERR_NOTDIR` | `$FFDC` | path component is not a directory |
| `ERR_NOTEMPTY` | `$FFDB` | `rmdir` on a non-empty directory |
| `ERR_LOCKED` | `$FFD9` | `assign` target is a locked system seed (`ROM:`/`RAM:`) |
| `ERR_BADHEADER` | `$FFD8` | `.COM` header missing or malformed -- bad magic, unknown version, image shorter than the header, or `heapPages >= pages` (Part 60, §11.9) |

`$FFDA` (`ERR_DETACHED`) sits in the same block but is a shell/exec code, not an FS error — see §13.13. `ERR_BADHEADER` is deliberately distinct from `ERR_NOTEXEC`: the latter already covers four unrelated failures (wrong extension, empty file, oversize, truncated cluster chain), so "this file is not a K16 `.COM` image" needed to be able to say so on its own. `sys_dirent` returns `ERR_NOMORE` at end-of-directory.

`sys_exec` returns `ERR_NOMEM` (`$FFFC`) when `_AllocPage` cannot find a free user page, and `ERR_NOSLOTS` (`$FFFB`) when `_BuildTask` cannot allocate a TCB — kernel-level codes distinct from the FS block above.

### 11.9 The `.COM` executable format

A k/OS `.COM` file is a binary image of a user task's primary code, exactly as it appears in memory at offset `$0200` of the loaded task's page, preceded by a **12-byte header**. There is no relocation table and no symbol information. `sys_exec` copies the file's bytes verbatim from disk into the freshly allocated primary page, starting at `user_page:$0200`, then enters the freshly built TCB at that entry point.

#### The header (Part 60)

```asm
$0200:  JMP16   __start        ; 2 words -- universal entry
$0204:  .WORD   $4252          ; magic; dumps as 52 42 = "RB"
$0206:  .WORD   1              ; header version
$0208:  .WORD   pages          ; TOTAL contiguous pages, INCLUDING heap
$020A:  .WORD   heapPages      ; how many of those are heap (0 = task page)
$020C:  __start:
```

| Offset | Symbol | Meaning |
|---|---|---|
| `$0204` | `COM_HDR_MAGIC` | `COM_MAGIC` = `$4252`. Little-endian, so a hex dump reads `52 42` = `RB`. |
| `$0206` | `COM_HDR_VER` | `COM_VERSION` = 1. |
| `$0208` | `COM_HDR_PAGES` | Total contiguous pages the task needs, including any heap pages. `>= 1`. |
| `$020A` | `COM_HDR_HEAPPG` | How many of `pages` are far heap. Must be `<= pages - 1` (the primary page always holds code and stack). Validated but otherwise unused until the far heap lands. |

Field offsets are also available relative to the image base as `COM_OFF_MAGIC` (`$04`), `COM_OFF_VER` (`$06`), `COM_OFF_PAGES` (`$08`), `COM_OFF_HEAPPG` (`$0A`), so the same parser reads a disk buffer or a loaded page. `COM_HDR_SIZE` = 12.

**Why the jump comes first and not the header.** If the header led, the loader would have to correctly parse a header field to know where to jump -- so an unrecognised version, or any parse error, would mean computing a jump target from data it has just admitted it cannot interpret. With `JMP16` at a fixed offset: `SPAWN_ENTRY_OFFSET` is unchanged and `_BuildTask` needs no edit; header parsing can fail cleanly without ever endangering control flow; a `.COM` stays **directly executable** (jump to `$0200` from a debugger or a test harness with no loader at all); and the header can grow later without touching the entry mechanism.

`JMP16` rather than `JMP24` because `JMP24` encodes an absolute 24-bit address embedding the *assembler's* page byte, which would land in kernel space at runtime -- the load page is chosen by the loader. `JMP16` stays in the current code page.

**Every field is a full word**, and the block must be emitted with `.WORD`, never `.BYTE`. Two reasons: K16 RM §4.6 lists what `.BYTE` accepts (numeric literals, string literals, escape sequences) and symbols are not among them, so `.BYTE COM_VERSION` is an undefined-symbol error; and an all-`.WORD` block cannot leave an odd byte count, so it can never desynchronise the alignment of what follows. Word fields also match k/OS's own convention -- `TCB_SAVED_Y`, `TCB_PAGE_COUNT`, `BT_PRIMARY` and `BT_PCOUNT` are all "word, low byte used" -- so `pages` never changes width between the file and the range test.

**`heapPages` is a partition of `pages`, not an addition to it.** `pages` is the allocation quantity, so the same number appears in three places: what `_AllocPageRun` allocates, what `TCB_PAGE_COUNT` records for `_PageInUse`, and what the task reads back from its own header. Splitting it into two numbers would let the header disagree with the TCB.

The canonical source form:

```asm
                .ORG    $0200
                .INCLUDE "../kos_defs.inc"

                JMP16   start                   ; $0200 - universal entry
COM_PAGES       .EQU    1
COM_HEAPPG      .EQU    0
                .WORD   COM_MAGIC               ; $0204
                .WORD   COM_VERSION             ; $0206
                .WORD   COM_PAGES               ; $0208
                .WORD   COM_HEAPPG              ; $020A
start:
```

#### Header validation -- `_ComHeaderCheck`

```
In:       Y0:X0    24-bit address of image byte 0 (the byte that lands at $0200)
          D0       image length in bytes
Out:      C = 0    D0 = pages, D1 = heapPages
          C = 1    D0 = ERR_BADHEADER
Clobbers: D0, D1, flags. XY0 restored; D2/D3/XY1/XY2/XY3 preserved.
```

One parser in `kos_spawn.asm`, three callers: `sys_exec` (via `_ExecReadHeader`), `sys_spawn`, and `_SpawnShell`. It checks length `>= 12`, magic, version, `pages >= 1` and `heapPages < pages`. The image base must be **even** -- every caller supplies one, and `sys_spawn` validates its `src_offset` explicitly.

**The magic's job is rejection, not compatibility.** Every `.COM` carries a header, so the magic exists so that `run readme.txt` produces a clean loader error instead of executing text at `$0200`. The loader **refuses** a bad magic; there is no headerless fallback and no "assume one page" default.

#### Load sequence

The loader needs `pages` *before* it can allocate, and allocation precedes the copy -- so it must read the header **from the file**, not from the loaded page:

1. Read the image's first sector into a kernel buffer (`_ExecReadHeader`).
2. Check magic and version; reject with `ERR_BADHEADER` on mismatch.
3. `_AllocPageRun(pages)` -> base, or `ERR_NOMEM` to the parent.
4. Copy the image into `base:$0200`.
5. `_BuildTask`, entry `base:$0200`, `BT_PCOUNT = pages`.

`.COM` files built before Part 60 will not load, and Part 60 images will not load on an older kernel. The changeover was a flag day with no grace period: kernel, kosh and every tool `.COM` were rebuilt together.

**Bare metal is exempt.** `--bare` builds at `.ORG $FF0000` have no k/OS loader, so header emission is keyed off the k/OS target.

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
                           $000C..$007B  FD_TABLE (8 fds × 14 bytes)
                           $006C..$00FF  TLS / future use
user_page:$0100..$01FF    ARGV_BASE — ASCIIZ command tail, always stamped
                           by sys_exec ($00 first byte = no arguments)
user_page:$0200           JMP16 __start — universal entry
user_page:$0204..$020B    .COM header (magic / version / pages / heapPages)
user_page:$020C           __start — first instruction of the program
                           ...
                           .COM body: code, then strings/data
                           ...
user_page:$xxxx..$FFEF    free for runtime data / heap / large buffers
user_page:$FFF0..$FFFE    initial stack region (X3 = $FFF0 at entry, grows down)
```

A .COM that opens files must zero its `FD_TABLE` before the first `sys_open` (because the page allocator does not clear page memory -- the same reason `sys_exec` stamps `ARGV_BASE` rather than trusting a zero there, and the same reason a multi-page task must write to its extra pages before reading them). A future `mkcom` tool will auto-prepend a small `crt0`-style preamble that does this.

#### Size limit

The .COM file format itself imposes no maximum size. `sys_exec` rejects files larger than `SPAWN_MAX_LEN` ($FE00 = 65,024 bytes) — the largest body that fits below the user stack ($FFEE) when loaded at $0200. Files larger than this return `ERR_NOTEXEC`. Empty files (size 0) and files whose extension is not `.COM` (uppercase) also return `ERR_NOTEXEC`. A file that passes those checks but carries no valid header returns `ERR_BADHEADER` -- including any file shorter than the 12-byte header.

### 11.10 Implementation status (Phase 16)

| Piece | Status | Verifies |
|-------|--------|----------|
| 1: Volume table, mount probe | Complete | `_InitFS`, `_TryMount` |
| 2: Block layer, format | Complete | `_FormatVolume`, `_VolBlockRead`, `_VolBlockWrite`, `_ZeroBuffer` |
| 3: FAT cache, cluster ops | Complete | `_FATInvalidate`, `_FATFlush`, `_FATLoad`, `_FATGetEntry`, `_FATSetEntry`, `_AllocCluster`, `_FreeCluster`, `_ClusterToSector` |
| 4: Directory ops | Complete | `_DirNameToFat`, `_DirNameFromFat`, `_DirOpen`, `_DirRewind`, `_DirNext`, `_DirNextRaw`, `_DirLookup`, `_DirCreate`, `_DirDelete` |
| 5: File descriptors and syscalls | Complete | `sys_open`, `sys_close`, `sys_read`, `sys_write`, `sys_dirent` (TRAPs 60..64), `sys_format`/`unlink`/`rename`/`diskfree` (65..68), and the Phase 2a subdir syscalls `mkdir`/`resolve`/`pwd`/`rmdir` (69..72), plus internal helpers incl. the `_Resolve` path resolver |
| 6: sys_exec | Complete | `sys_exec` (TRAP 31) plus 4 internal helpers: `_ExecCheckExt`, `_ExecCopyChain`, `_ExecCopyOneSector`, `_ExecStageName` |

Four smoke tests cover the implementation: 13-test `kos_p16_fs_smoke.asm` (Pieces 1+2+3), 13-test `kos_p16_fs_dir_smoke.asm` (Piece 4), 14-test `kos_p16_fs_rw_smoke.asm` (Piece 5), and 7-test `kos_p16_fs_exec_smoke.asm` (Piece 6). The Piece 5 smoke includes a 600-byte multi-cluster RW test (T11) that exercises `_FdEnsureCluster` case (5) chain extension, `_AllocCluster` + `_FATSetEntry` chaining, and `_FdAdvancePosition` cluster walk on read — the most architecturally demanding code path in the FS.

T12 of the Piece 1+2+3 smoke (alloc until ERR_NOSPACE) is `O(N²)` on volume size and takes ~17 minutes on Digital due to simulator clock rate; Phase 17 will add a next-free-cluster hint to make this `O(N)`.

The kosh integration once listed here as Phase 16 follow-on — `ls`, `cat`, `cp`, `rm`, `format`, `vol`, `run` and the rest — has since shipped (see §14 and `kosh/kosh_cmds_fs.asm`), along with subdirectories, long filenames, and named volumes (Parts 22–55). External tooling (`mkromdisk`, `mkcom`) and the EMU-only RAM-disk save/load menu items remain outside the kernel build.

---

## 12. Coding Conventions

### 12.1 File-naming

| Pattern | Use |
|---|---|
| `kos_*.asm` | Kernel implementation modules |
| `kos_*.inc` | Shared constants and macros |
| `klib/kos_klib_*` | KLIB submodule files |
| `emulib/kos_emulib_*` | EMULIB submodule files |
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

### 12.7 Page-$00 allocation

Page-`$00` storage is reserved with the assembler's `.REGION` / `.RS` system (K16 ref §4.12) in the defs `.inc` files (`kos_defs.inc`, `kos_fs_defs.inc`, `kos_klib.inc`) — never with a hand-`.EQU`'d absolute address in a `.asm`. The assembler assigns the addresses, so fields cannot silently overlap and any collision or growth-into-reserved space is a build error. A hand-`.EQU` allocation in a `.asm` is exactly how the recurring page-`$00` collision bugs happened (Gotchas 4.25, 4.43, 4.47). Reserve plain `.EQU` for values, struct offsets, and ABI-fixed addresses (the vector table, MMIO). The region map is the canonical layout audit.

---

## 13. Foreground Switcher (Phase B)

Phase B (13 May 2026) added a preemptive foreground-switcher to k/OS, allowing multiple shell tasks to share one terminal. The user can hop between shells with a hot-key; the foreground shell's output appears on screen in real time while background shells continue to run, with their output captured into per-task back-buffers. Pressing a switch key repaints the new foreground's back-buffer onto the terminal.

The design accepts two compromises in v1:

- **Background shells busy-spin.** They sit in `_GetGatedKey` polling `FOREGROUND_TCB` rather than blocking on a wait condition. Idle gets almost no time on multi-shell systems. A future revision should have `_GetGatedKey` call `sys_yield` instead of spin.
- **No scrollback restoration on switch.** The repaint draws the current state of the back-buffer; scrollback history within a buffer is not preserved beyond the 80×80 grid. ESC[3J is emitted before each repaint to clear the terminal's own scrollback so the new foreground starts clean.

### 13.1 What makes a task a shell

A task becomes a shell by calling `sys_register_shell` (TRAP #77). The syscall:

1. Allocates a 6400-byte back-buffer from the kernel heap (80 rows × 80 cols).
2. Stores the back-buffer offset and page in `TCB_BACKBUF_OFFS` ($4C) and `TCB_BACKBUF_PAGE` ($4E), and zeroes the cursor `TCB_BACKBUF_CRSR` ($52).
3. (Geometry is fixed at 80×80; there is no longer a separate geometry word.)
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

All seven output syscalls (`sys_putchar`, `sys_puts`, `sys_putlp`, `sys_putdec`, `sys_clear`, `sys_setcursor`, `sys_puthex`) test `TF_HAS_BACKBUF` at entry:

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

Shells (and, since Part 49, graphics tasks) form a singly-linked ring via `TCB_SHELL_NEXT` ($50). Each member's `next` is the page-`$00` offset of the next member's TCB; the last-registered member's `next` wraps back to the first. **A lone member has `TCB_SHELL_NEXT == 0`** — this is the single convention (Part 50): `0` means "not in a ring", any non-zero value is a real next-offset. (Before Part 50 a lone shell was coded as a self-loop; that store never actually took effect at runtime, and every reader already treated `0` as lone, so the self-loop was removed and `0` made canonical.) `_SwitchForegroundNext` follows one hop and treats `0` as a no-op; `_SwitchForegroundPrev` walks the ring until it finds the TCB whose `next` matches the current foreground (the predecessor). In a 2-shell ring both end up at the other shell, which is correct.

### 13.9 Output: `ps` reflects shell and graphics status

The kosh `ps` command shows a per-task `FG` column:

- `*` -- this task is the foreground shell
- `s` -- this task is a registered shell but currently in the background
- `-` -- this task is not a registered shell (e.g. idle, or a non-shell .COM)

It also shows a `GFX` column (Part 50), independent of `FG` because a task can
be both a shell and a graphics owner:

- `M<n>` -- this task holds the video handle (`VIDEO_OWNER_TID`); `n` is its
  `TCB_GFX_MODE` ($24), e.g. `M2` for VGA 8bpp.
- `-` -- this task does not own the graphics screen.

Since Part 60 the `PAGE` column is `PAGES` (width 8) and shows the whole run a
task owns, not just its base:

- `-` -- owns nothing (`TCB_PAGE_COUNT = 0`): a `TS_DEAD` corpse, which
  released its run at death (§7.4), or the idle task.
- `$nn` -- a single page.
- `$nn-mm` -- a run, where `mm = base + count - 1`.

Base comes from `TCB_SAVED_Y` and extent from `TCB_PAGE_COUNT` -- the same two
fields `_PageInUse` range-tests -- so the column shows precisely what the
allocator considers taken.

Column order is `TID PTID NAME ST FG GFX PAGES BLOCKS BYTES TICKS`. `BLOCKS` and `BYTES` are kernel **heap** statistics from `sys_heapstats_by_tid` and have nothing to do with pages.

The `TICKS` column shows `TCB_PREEMPT_COUNT` as a 32-bit decimal (wraps at ~4 years @ 30 Hz). Use `TICKS` to spot tasks that aren't getting scheduled or to compute cumulative CPU share (per task / sum of all).

### 13.10 Shell death (Part 31)

When a registered shell **or graphics task** dies — whether via `sys_exit` (the shell calls `bye`/`BYE`), `sys_kill`, or graphics release — `_ReapDeadTask` is the single point that handles all the cleanup. It is the **single source of truth** for what happens when a focusable task dies.

Inputs to `_ReapDeadTask` are unchanged: `X1:Y1` = victim TCB pointer. If the victim is focusable (`TF_HAS_BACKBUF` or `TF_GRAPHICS` set):

1. **Shell-ring unlink.** Walk the singly-linked ring forward from the victim to find its predecessor. The walk is bounded by `MAX_SHELL_RING_LEN` (16) as a defence against corrupted next-chains. On corruption the unlink is skipped (better than infinite-looping in the kernel) but the back-buffer free and flag clear still run.
2. **Lone case.** If `victim.TCB_SHELL_NEXT == 0` (the Part 50 lone convention) — or `== victim` as a defensive equivalent — the victim was the only ring member: `FOREGROUND_TCB` and `FIRST_SHELL_TID` are cleared, and the ring walk is skipped entirely. Any other sub-pool value (a `next` below `USER_TCB_BASE` $0880) is treated as "not a real ring link" and likewise refused — never walked — which is what closed the Part 49 odd-address `DATA FAULT` (a dangling `next` had been followed into the page-`$00` vector table).
3. **Multi-member case.** Predecessor's `TCB_SHELL_NEXT` is set to victim's successor. If victim was the foreground:
   - `FOREGROUND_TCB := successor.TCB_ID`
   - `_RepaintFromBackbuf(successor)` paints the new foreground's back-buffer (a graphics successor instead re-asserts its `TCB_GFX_MODE` via `VID_MODE`).
4. **Anchor retarget.** If `FIRST_SHELL_TID == victim.TCB_ID`, same retarget to successor.
5. **Back-buffer free.** For a shell, `_kfree` releases the back-buffer back to the heap. A graphics task has none, so this step is skipped.
6. **Field clear.** `TF_HAS_BACKBUF` / `TF_GRAPHICS`, `TCB_SHELL_NEXT`, `TCB_GFX_MODE`, `TCB_BACKBUF_OFFS`, and `TCB_BACKBUF_PAGE` are zeroed on the victim TCB.

Then the routine falls through to the existing ready-ring unlink and `TS_UNUSED` mark.

**Callers do not handle any of this directly.** `sys_exit` decides between eager-reap (shells) and lazy-reap (non-shells) based on `TF_HAS_BACKBUF`. `_HandleDeadTCB` (the path used by `sys_kill`) just calls `_ReapDeadTask` at its tail. Neither has its own foreground-hand-back or shell-ring-unlink logic. This invariant is what makes the lifecycle understandable: when something goes wrong with shell death, the trail leads to one routine.

**Register clobber contract (Part 31 r21+).** `_ReapDeadTask` is now register-clean: it saves and restores `D0..D3`, `XY0`, `XY2` at entry/exit via `PUSH`/`POP`. Callers can rely on these registers surviving the call. `XY1` (the victim TCB pointer) is temporarily redirected to the new foreground TCB across the `_RepaintFromBackbuf` call but restored to the victim before return. `XY3` (kernel stack pointer) is unchanged.

### 13.11 Graphics tasks as ring members (Part 49)

Before Part 49, only shells (`TF_HAS_BACKBUF`) were ring members; a graphics
program (cube, mandel, gui128f) acquired `VID_MODE` but stayed outside the
foreground ring, so it could neither hold foreground deterministically nor
receive keyboard input through the gate. Part 49 makes a graphics task a
**focusable ring member**:

- `sys_setvidmode(mode != 0)` acquire (see §5.7) sets `TF_GRAPHICS` ($0010),
  records the mode in `TCB_GFX_MODE` ($24), and splices the task into the ring
  via `_SpliceAfterForeground`, making it foreground.
- `TF_FOCUSABLE` (`$0018` = `TF_HAS_BACKBUF | TF_GRAPHICS`) is the predicate the
  switcher, `_GetGatedKey`, and `sys_setforeground` now test. Any focusable
  task — shell or graphics — can hold foreground, be cycled to with the hot
  keys, and be targeted by `fg <tid>`.
- A graphics task has **no back-buffer**: its `TCB_BACKBUF_*` fields stay zero.
  On foreground regain the switcher re-asserts `VID_MODE` from `TCB_GFX_MODE`
  instead of calling `_RepaintFromBackbuf`.
- Release / exit / kill all route through `_VideoForceReset` + `_ReapDeadTask`
  (§13.10), which unsplices the task and hands foreground back.
- **Part 61:** acquire also detaches a `sys_wait`-blocked launcher with
  `ERR_DETACHED`, exactly as `sys_register_shell` does for a shell. Becoming
  focusable and leaving the parent blocked are incompatible: the parent is
  usually the only task permitted to kill the graphics task. See §13.13.

`_SpliceAfterForeground` inserts the new member immediately after the current
foreground: `new.next := foreground.next; foreground.next := new`. The two Part
49 bugs both lived here (see §13.12).

### 13.12 The lone-shell convention and `_SpliceAfterForeground` (Part 50)

Part 49 shipped with two bugs, both rooted in how a **lone** foreground's `next`
was handled at splice time:

- **Bug 2 (`DATA FAULT $00014F`).** Killing a graphics task faulted 100% of the
  time. `_SpliceAfterForeground` had copied `new.next := foreground.next`
  unconditionally. When the foreground was the only ring member its `next` was
  `0` (the runtime lone value), so the graphics task's `next` became `0` — or a
  stray sub-pool value — and the reap walk later followed it off into the
  page-`$00` vector table, reading an odd word address.
- **Bug 1 (background graphics "corruption").** `gui128f` reads the keyboard, so
  it needs foreground; the dangling `next` kept it out of a valid ring, so it
  never became foreground and its `getchar` starved while the screen showed
  garbage. Same root cause; fixed by the same change.

The fix established a **single convention**: `TCB_SHELL_NEXT == 0` means *lone /
not in ring*, everywhere. The dead `.first_shell` self-loop store was removed
(`_BuildTask` already zero-fills `$20..$7F`, so a fresh shell's `next` is `0`).
`_SpliceAfterForeground` now special-cases a lone foreground: when
`foreground.next == 0` it closes the ring back to the foreground —
`new.next := offset(foreground)` — forming a valid 2-ring `foreground ⇄ new`
instead of propagating `0`. `_ReapDeadTask` treats `0` (and `self`) as lone and
refuses any sub-pool `next` (§13.10 step 2). With these three in agreement, the
splice/reap path that the fault lived in is closed at the root.

> Note: after a graphics task is acquired and then killed, the reap can leave a
> formerly-paired shell at a harmless self-loop (`next == offset(self)`) rather
> than `0`. Both `_SwitchForegroundNext` (redundant self-commit) and
> `_SpliceAfterForeground` (non-zero `next` handled normally) tolerate this. A
> two-instruction "restore to 0 when lone again" tidy is parked but not
> required.

### 13.13 Auto-foreground on launch (Part 51)

By default a registered shell joins the ring *behind* the current foreground and does not steal focus (§13.1 step 6 foregrounds only the very first shell). That makes `run forth30` start Forth but leave you looking at kosh — the launched shell is alive but not in front. Part 51 adds an opt-in "switch to the child on launch", built entirely from existing primitives.

**The intent rides from launcher to child.** `sys_exec`'s flags word (`D0`) gains `EXEC_FOREGROUND` ($0002). When set, `sys_exec` ORs `TF_AUTOFG` ($0020, `TCB_FLAGS` bit 5) into the freshly-built child TCB — "foreground me when I become focusable." A plain `.COM` that never registers as a shell never consumes it, so a fire-and-forget program like `hello.com` is unaffected and never grabs focus.

**Reporting failure from a task that joins the ring (v0.36).** A task
that has joined the focus ring cannot report anything to the console on
its way out: `_ReapDeadTask` repaints the incoming foreground's
back-buffer over whatever it wrote, and if the task was a shell its own
back-buffer is freed in the same step. This applies to a graphics task
(ring member via `TF_GRAPHICS`, no back-buffer at all) and to a
registered shell (ring member via `TF_HAS_BACKBUF`) alike.

Two consequences, and they pull in opposite directions:

1. **Validate before joining.** Argument checks, file opens and any
   other startup failure belong *before* `sys_register_shell` or
   `sys_setvidmode`. Up to that point the task is ordinary, its output
   goes straight to the terminal, and the launching shell — still
   `FOREGROUND_TCB`, blocked in `sys_wait` — never repaints over it. A
   failed acquire also leaves the task outside the ring, so a
   `graphics busy` message on that path is durable.
2. **After joining, report by exit code.** `sys_exit` carries a 16-bit
   code and nothing else; there is no death-message mechanism. A task
   that fails at that point should exit with the `ERR_*` code it
   received — which is already in `D0` on the `BCS` — rather than
   printing.

kosh renders the result: `.xf_exited` runs the exit code through
`_KoshErrName`, so a known error prints as `[exit ERR_BUSY]` while an
ordinary status stays decimal (`[exit 0]`, `[exit 1]`).

**Explanatory text belongs to the application, not to kosh.** kosh sees
a number with no context and cannot know which subsystem produced it, so
any hint it printed would be a guess that goes stale as soon as a second
subsystem exits the same code. A kosh-side hint for `ERR_BUSY` was built
and then removed for exactly this reason.

> **Correction (v0.34).** Earlier revisions of this paragraph named `mandel` alongside `hello.com` as a program that "never grabs focus". That has been wrong since **Part 49**: a graphics task becomes focusable through `sys_setvidmode` acquire, not through `sys_register_shell`, so it takes the foreground without ever touching `TF_AUTOFG`. `TF_AUTOFG` is indeed never consumed by such a task — but focus moves anyway, by the §13.11 route. Since Part 61 the launcher is detached as well, so `mandel` now behaves like `forth30`, not like `hello.com`.

**The child consumes it at register time.** This is the race-free hook: a task is focusable exactly when it calls `sys_register_shell`. So the register commit path checks its own `TF_AUTOFG`; if set, it clears the one-shot flag and (1) wakes the launcher (below), then (2) calls `_CommitForeground` on itself — the single switch primitive that writes `FOREGROUND_TCB`, hands off the keyboard (`_KbdReleaseWaiter`), drives `VID_MODE`, and repaints from the back-buffer.

**Waking the launcher: `ERR_DETACHED`.** A foreground launch (`forth30`, no `&`) leaves kosh blocked in `sys_wait` on the child. If the child simply took focus and kosh stayed blocked, switching back to kosh would show a frozen shell. Instead the auto-foreground path finds the waiting launcher (`_FindWaiterFor`) and delivers `ERR_DETACHED` ($FFDA) into its `sys_wait` frame with C=1 (`_DeliverWaitDetached`), then marks it `TS_READY`. kosh's `TRAP_WAIT` returns C=1 / `ERR_DETACHED`, which it reads as "child went interactive" — not an error, not an exit — and returns to its REPL as a **live background shell**. Both shells now run: Forth in front, kosh behind, and Switch / Ctrl-N toggle between them. When the child later exits, no one is waiting (correct), and the §13.10 reap hands foreground back to the ring successor.

**Launch semantics.**

| Command | exec flags | kosh waits? | Effect |
|---|---|---|---|
| `forth30` | `EXEC_FOREGROUND` | yes → early `ERR_DETACHED` | switch to Forth; kosh stays alive in the background; Switch toggles both |
| `forth30 &` | none | no | Forth joins the ring as a background shell; kosh keeps the foreground; `[bg N]` printed |
| `hello.com` | `EXEC_FOREGROUND` (ignored — never registers) | yes → real exit | runs to completion; `[exit N]`; foreground never moves |
| `mandel` (graphics) | `EXEC_FOREGROUND` (never consumed — never registers) | yes → early `ERR_DETACHED` | `sys_setvidmode` acquire takes the foreground (§13.11) and detaches the launcher (Part 61); kosh stays alive behind it and can `kill` its child |

This is the **virtual-console** model: the default verb is "go to it", `&` means "stay here", and the kernel never centralises a modal block — both shells stay schedulable throughout. Contrast Unix (a foreground job blocks the shell) and AmigaOS (foreground hand-off via the console handler; `RUN` detaches the child with its own console). k/OS reaches the same "launch and switch, both alive" result by putting focus in the scheduler (`FOREGROUND_TCB`) plus this register-time hook, rather than in a windowing layer.

> Delivered: `kos_defs.inc` (`TF_AUTOFG` / `EXEC_FOREGROUND` / `ERR_DETACHED`), `kos_fs_exec.asm` (child tag after `_BuildTask`), `kos_spawn.asm` (`_DeliverWaitDetached`), `kos_switcher.asm` (`sys_register_shell` `.commit` auto-foreground + detached wake), `kosh_helpers.asm` (`_KoshExecFile`: `EXEC_FOREGROUND` on non-`&` launch + three-way wait `.xf_exited`/`.xf_detached`/`.xf_fail`). A bare `forth30` (no `run`) reaches the same path via kosh's implicit-exec dispatch; see §14.


---

## 14. kosh commands

This section documents the user-facing behaviour of kosh's built-in
commands. kosh's implementation is split across `kosh_cmds_*.asm`
files (§1.3); this section describes the contract from the user's
perspective — syntax, behaviour, output format — not the
implementation.

**Coverage.** This is a living section. Documented in detail below: `vol`,
`ls`, drive switching / named volumes, `assign`, `fg`, and **kosh scripts**
(`.KSH`, §14.6). kosh's other
built-ins fall into the groups: filesystem (`cat`, `cp`, `rm`, `mv`, `format`,
`run`, `load` — which since Part 61 accepts a `ramdisk/` host-folder prefix,
kOS_FS_Reference §12.3), directories (`cd`, `pwd`, `mkdir`, `rmdir` — subdirectories and
long filenames are supported since v0.23), host-disk management (`disks`,
`mount`, `unmount`, `mkdisk`, `rmdisk`, `rename`, `remount`), task/foreground
(`ps`, `tcb`, `kill`, `fg`), and system (`mem`, `info`, `uptime`, `ver`, `peek`,
`dump`, `help`, `exit`, `echo`, `clear`, `halt`, `reboot`). These are filled in
over subsequent revisions.

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
RAM:$ vol
Drive  Label       Name        Total     Used     Free Use%
A:     ROMDISK     ROM:        126KB     89KB     36KB  71%
B:     RAMDISK     RAM:       1018KB      1KB   1017KB   0%
C:     DRIVEC                 1.98MB    442KB   1.55MB  21%
D:     (not mounted)
E:     (not mounted)
F:     (not mounted)
```

**Column layout:**

| Column | Width | Format |
|---|---|---|
| Drive | 2 + 5 pad | Drive letter + colon, left-aligned |
| Label | 11 + 1 pad | On-disk volume label, left-aligned (max 11 chars + padding) |
| Name | 11 + 1 pad | Named-volume / assign name + colon (e.g. `ROM:`), left-aligned; blank if the drive has no name |
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
rather than bytes to avoid 32-bit division. The `Name` column is the drive's
named-volume entry, reverse-looked-up from the assign table (§14.4); it is blank
for a drive with no assigned name.

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

No arguments — `ls` lists the current working directory (CWD; see §15 *CWD*).
k/OS has had subdirectories and long filenames since v0.23, so directory
entries appear in the listing alongside files, and long names are shown in full
(the 8.3 short name is the fallback). The sample below is a files-only
directory.

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

### 14.3 Drive switching & named volumes

kosh tracks a current working directory (CWD) — a drive plus a directory
cluster. Two ways to switch drive, both by typing a bare token at the prompt:

- **Drive letter** — `C:` switches to drive C:'s root.
- **Volume name** — `rom:`, `ram:`, `fonts:` switches to that named volume.

A named volume is an entry in the assign table (§14.4). A `NAME:` prefix — on a
switch, a `cd`, or any path — resolves to a concrete `(drive, cluster)` and the
resolver then walks the **real** directory tree from there. Resolution is
transparent: `cd fonts:` lands on the actual backing directory, not an opaque
namespace.

**Display reverse-maps the real path back onto the name.** The prompt, `pwd`,
and the `ls` header show the named form where one applies:

```
RAM:$              CWD is B: root (B: is named RAM:)
RAM:/system$       a subdirectory under RAM:
FONTS:$            CWD is at the FONTS: mount root (no trailing slash)
FONTS:bold$        a subdirectory under the FONTS: mount (mount-relative)
```

Because resolution walks the real tree, `cd ..` walks the real parent: stepping
above a path-mount's root reverts the display to the underlying drive form
(`RAM:/...`) rather than staying inside the name. Drive names are ≥ 2
characters and drive letters are exactly 1, so the two namespaces never collide
— the letter is always an unambiguous handle. `ROM:` and `RAM:` are seeded at
boot as locked entries for whichever backends actually mounted; the boot prompt
therefore shows `RAM:$`, not `B:$`.

### 14.4 `assign` — manage named volumes

Creates, lists, and clears named-volume / path-mount entries. A named volume
aliases a drive root; a path-mount is a shortcut into a subdirectory. Both are
the same table entry — a name that resolves to `(drive, cluster)`.

**Syntax:**

```
assign                 list all current assigns
assign NAME PATH       create/replace NAME, pointing at PATH (must be a directory)
assign NAME            clear (remove) NAME
```

**Sample output** (representative):

```
RAM:$ assign FONTS ram:system/thefonts
OK
RAM:$ assign
  ROM: -> A:/
  RAM: -> B:/
  FONTS: -> B:/system/thefonts
```

**Behaviour.**
- The name is typed **without** a colon (`assign FONTS …`); it is displayed
  **with** one (`FONTS:`). `PATH` is resolved with the current CWD context via
  `sys_resolve` (TRAP #70) and **must be a directory** (else `ERR_NOTDIR`); the
  resulting `(drive, cluster)` is stored via `sys_assign` (TRAP #78). A target
  that is a drive root gives a named volume (`AS_ROOTCLU = 0`); a subdirectory
  gives a path-mount (`AS_ROOTCLU <> 0`). Success prints `OK`; failure prints
  `assign: failed [ERR $HHHH]`.
- The list form reads the assign table directly and reconstructs each backing
  path via `sys_pwd`, printing one `NAME: -> <backing path>` line per entry.
- Names are ≥ 2 characters; a 1-character token is always a drive letter.
- The boot-seeded `ROM:` / `RAM:` entries are locked and refuse reassignment or
  clearing.
- Cleared or unknown names resolve to an error at the use site rather than
  silently succeeding.

The entire naming layer lives in the display / resolve path (the assign table
plus one kosh helper, `_KoshEmitPwdNamed`); the kernel's file syscalls still
receive fully-resolved `(drive, cluster)` context, never a name.

### 14.5 `fg` — switch the foreground shell

Brings a specific shell task to the foreground (the one whose output is visible
and which receives keyboard input). Equivalent to the `Ctrl-N`/`Ctrl-P` hot-key
cycle but targeted by TID.

**Syntax:**

```
fg <tid>
```

Calls `sys_setforeground` (TRAP #76), which sets `FOREGROUND_TCB` and repaints
from that shell's back-buffer. The call is privileged (`TF_PRIV`); kosh runs
privileged, so the command succeeds from the shell. Use `ps` to list shell TIDs.
See §13 (Foreground switcher) for the full model.

### 14.6 kosh scripts (`.KSH`)

A kosh script is a plain text file of kosh command lines, executed through the
same dispatch a typed line takes — the shell reads its input from a file
instead of the keyboard (the AmigaDOS `Execute` / DOS `.BAT` model). There are
no script-only commands: anything you can type, a script can run, including
`assign`, which is the point — a boot script rebuilds the named-volume
namespace (§14.4) on every start.

**Format.**

- One command per line.
- A line whose first non-blank character is `;` is a comment and is skipped;
  blank lines are skipped.
- Every executed line is echoed at the prompt as it runs, so a script session
  reads like a typed one. Part 61 added a second presentation, **brief** — see
  "Presentation" below.
- `CR` is stripped, so both LF and CRLF text files work.

**Running a script.**

```
run FOO.KSH        explicit
FOO.KSH            bare name — "run" is optional (auto-exec, §13.13 / Part 51)
RAM:FOO.KSH        drive-qualified bare name (Part 61)
FOO.KSH -b         brief presentation (Part 61)
```

A name ending `.ksh` (case-insensitive) is routed to the script runner instead
of the `.COM` loader; the file is opened relative to the current drive / CWD
like any other path.

**Drive-qualified bare names (Part 61).** Before Part 61 a first token
containing `:` was routed unconditionally to the `cd` resolver — commands were
assumed never to contain a colon — so `RAM:FOO.KSH` died with `cd: not a
directory` and the only way to launch a drive-qualified name was `run`. The
resolver now records how it was entered (`CD_BARE`, §2.6): reached from a bare
colon token, a target that resolves to a **file** (or to nothing) is handed
back to the ordinary dispatch, which falls through `cmd_table` to
`_KoshExecFile`. `ERR_NOTFOUND` takes the same route, which is what makes the
extension-less `RAM:HELLO` form work — `_KoshExecFile` retries with `.com`
appended. Reached from an explicit `cd`, behaviour is unchanged and a
non-directory target is still an error.

**Presentation (Part 61).** Each script level has its own presentation mode,
held in the `SCRIPT_FLAGS` stack (parallel to `SCRIPT_FDS`, §2.6). Two modes:

| Mode | Echo | Set by |
|---|---|---|
| verbose (default) | `<prompt><line>` + newline; command output follows below | nothing, or `-v` |
| brief | `<prompt><line> -> `; the command's own output completes the line | `-b`, or `echo -b` |

```
RAM:$ load ramdisk/zork.com -f -> loaded 36560 bytes
```

The mode is **per level**: a script invoked from a brief script is verbose
unless it too asks for brief. It can be set two ways.

*On the invocation* — `FOO.KSH -b`. Parsed in `_KoshExecFile` from the arg
tail and passed to `_KoshRunScript` in `D3`.

*Inside the script* — `echo -b` / `echo -v` on a line of its own. This is the
only way for a **boot-cascade** `STARTUP.KSH` to be brief, because the cascade
invokes it with flags = 0 and there is no argument to pass. The directive is
intercepted in `_KoshScriptNextLine` alongside the `;` comment filter and
swallowed — neither echoed nor dispatched — so it leaves no trace in the
output, and `.do_echo` is untouched. At the interactive prompt there is no
script level to configure, so `echo -b` simply prints `-b`.

Flag form rather than DOS's bare `echo off` is deliberate: only the exact text
`-b` / `-v` is shadowed, so `echo off` still prints `off`, which under DOS it
cannot.

**Dangling arrows.** A command that prints nothing (`ram:`, a script push)
would leave a brief-mode line ending in an orphaned `-> `. The column of the
arrow's end is recorded in `SCRIPT_ARROW_COL` (§2.6) via `sys_wherexy`; when
the next prompt finds the cursor still sitting exactly there, nothing was
printed, and `_KoshPrintPrompt` erases the arrow with the BS/space/BS idiom
before breaking the line. The line then reads as an ordinary verbose echo.
Recording the column, rather than assuming, is what stops the erase from
eating real output that merely lacked a trailing newline — that lands at a
different column and is left alone. `SCRIPT_ARROW_LEN` must track the width of
`msg_brief_arrow`; they live in different files.

The same guard runs on **every** prompt, interactive included, so it also
tidies after any `.COM` that exits without a trailing newline.

**Nesting.** A script may `run` another script. Scripts nest through a LIFO
fd-stack capped at `SCRIPT_MAX_DEPTH` (4): the child runs to end-of-file, then
the parent resumes at the line after the `run`. Exceeding the cap fails the
`run` rather than recursing without bound.

**Errors — continue-and-echo.** A line that fails prints its error and the
script carries on with the next line. This is deliberate: a boot script that
`assign`s directories which may not exist should not halt the boot. (A
configurable `failat` threshold is planned for scripts v2.)

**Boot cascade.** At startup — after kosh paints its splash, before the first
interactive prompt — it runs `STARTUP.KSH` from the root of `A:`, then `B:`,
then `C:`, in that order, every one present, each to completion. A drive that
is unmounted or has no `STARTUP.KSH` is skipped. Since Part 61 each leg that
actually runs announces itself as `[A:STARTUP.KSH]` before its first echoed
line, so the boot log says which drive produced what and a missing leg shows
as an absence rather than having to be inferred. Only successful pushes are
announced: the cascade walks every drive, so reporting the misses would print
`[A:]` and `[B:]` on every boot where only C: has a script. Only one boot script
is open at a time (a drive cursor, `SCRIPT_BOOT_DRV`, not three held fds), so a
boot script is free to open files of its own. This is the mechanism that
recreates the named-volume namespace on each boot.

A representative `C:STARTUP.KSH` (assign names are ≥ 2 characters — a single
letter is always a drive; see §14.4):

```
; system namespace
echo -b
assign SYS:      C:
assign FONTS:    C:system/fonts
assign WORK:     C:
echo namespace ready.
```

which renders as

```
[C:STARTUP.KSH]
RAM:$ assign SYS:      C: -> OK
RAM:$ assign FONTS:    C:system/fonts -> OK
RAM:$ assign WORK:     C: -> OK
RAM:$ echo namespace ready. -> namespace ready.
```

A trailing bare `assign` is deliberately omitted: the per-line confirmations
already report each one, and the table repeats them.

**Bootstrapping from a read-only or host-side source.** `A:` is the ROM disk
and is read-only, so its `STARTUP.KSH` cannot be edited without regenerating
the ROM image. The pattern that avoids this is to keep the ROM copy minimal
and have it fetch the real script from elsewhere — on EMU, the host-side
`system/ramdisk/` folder (kOS_FS_Reference §12.3):

```
; A:STARTUP.KSH — bootstrap only; never needs to change
ram:
load ramdisk/boot.ksh -f
boot.ksh -b
```

The loaded script then does the real work, and its contents live in a text
file on the host that can be edited freely. This is EMU-only — the host file
bridge does not exist on Digital or on hardware, where `load` is a silent
no-op and `B:` simply comes up empty.

**Implementation.** The runner is `kosh_script.asm`. The REPL calls
`_KoshScriptNextLine` as its line source: if a script is active it returns the
next executable line (blank / comment lines filtered, line echoed) in
`LINE_BUF`; otherwise the loop prompts and calls `sys_gets` as before. Files
are read one byte at a time via `sys_read`, so each nesting level needs only
its fd — the kernel keeps the position. State lives in `KSTATE` (§2.6):
`SCRIPT_DEPTH`, the `SCRIPT_FDS` stack, a one-byte read slot `SCRIPT_CHAR`,
`SCRIPT_BOOT_DRV` (the cascade cursor), and — Part 61 — the `SCRIPT_FLAGS`
stack (per-level presentation, parallel to `SCRIPT_FDS`) and
`SCRIPT_ARROW_COL` (pending brief-mode arrow column, 0 = none). The `.ksh` routing sits in
`_KoshExecFile`, so both `run NAME.KSH` and a bare `NAME.KSH` reach the runner.


---

## 15. Glossary

**ABI**  Application Binary Interface. The contract between caller and callee about register usage, stack discipline, etc.

**Atomic section**  A region of kernel code that runs with interrupts disabled, so it cannot be preempted halfway through.

**Carry-sense (K16 convention)**  K16 follows the 6502 convention for carry after `SUB` and `CMP`: **C=1 means no borrow** (the unsigned subtract did not underflow — the normal case for `Dn >= Dm`), and **C=0 means borrow** (underflow — `Dn < Dm`). Consequently `BCS` after `SUB`/`CMP` branches on "no underflow / normal", and `BCC` branches on "underflow / error". This is the opposite of the x86/ARM convention and is a durable trap when writing arithmetic and bounds-check code; see Gotcha 2.8 in `kOS_Gotchas`. The kernel's syscall return convention re-uses the same flag with different semantics (C=0 success, C=1 error), distinct from any subtract that preceded the `RET`/`RETCC`/`RETCS`.

**Cluster**  The FAT16 allocation unit. A cluster is one or more contiguous 512-byte sectors (volume-specific via `VOL_SEC_PER_CLUSTER` in the BPB) and is the granularity at which the filesystem allocates and frees data space. Cluster numbers start at 2 (cluster 0 and 1 are reserved by the FAT16 spec); the FAT entry for cluster `N` lives at FAT offset `N×2` and is either the next cluster in a chain, `$FFFF` (chain terminator), or `$0000` (free). See `kOS_FS_Reference` §3.

**CWD (kosh current working directory)**  A drive letter plus directory cluster held in kosh's task page (`KOSH_CWD` / `KOSH_CWD_CLU` at `$8000`, default `'B'` / root; see §2.6). Paths typed without an `X:` prefix resolve against this CWD inside the kernel path resolver (Part 44 — the CWD is a kernel-resolved cluster, not a string rewrite). Commands pass the raw path and supply CWD context in the syscall registers (`D1` = start cluster, `D2` = start drive index); an explicit `X:` prefix means start cluster 0, so *qualifying* a path discards the CWD. `_KoshNormPath`, which prepended `<CWD>:`, was removed in Part 63 for exactly that reason — see `kOS_Gotchas` §4.69. Switched by typing a bare drive letter (`C:`) or a bare named volume (`rom:`) at the prompt.

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
| 0.21 | 18 May 2026 | **Part 35 — V2 ABI compliance sweep.** §5 (V2 ABI): the "audit-pending" caveat removed — all 37 TRAP handlers brought into compliance with the expanded `D1`/`XY1` preservation contract. Added the **input-arg/return clarification**: a callee-preserved register may be legitimately consumed or produced when documented as an input arg or return register for that specific syscall (e.g. `sys_read`/`sys_write` D1 = count, `sys_rename` XY1 = new-path pointer, `sys_diskfree` D1 = total clusters). §5.6 `sys_kill` and §5.7 `sys_setvidmode`: Preserves rows updated to reflect the expanded V2 ABI (`D1, D2, D3, XY1, XY2`). (Revision-history row added retroactively in v0.24.) |
| 0.22 | 18 May 2026 | **Part 36 testing + Gotcha 4.47 fix.** Smoke test verification surfaced three additional issues beyond the Part 35 audit's scope: (1) `_SemCreate`/`_SemDestroy`/`_SemGive` declare `Clobbers: D1` in their headers, so the Bucket 1 TRAP wrappers needed `PUSH D1`/`POP D1` around the `CALLR` as well as the EINT-gate fix; (2) the same pattern applied to the FS handlers — `_DirLookup`, `_FATGetEntry`, `_FdFlushDirent`, `_FormatVolume` all clobber D1 on deep paths, requiring `PUSH D1`/`POP D1` in `sys_open`/`close`/`format`/`unlink`/`rename`/`exec` prologues; (3) **latent collision bug discovered**: `FE_NEW_PAGE` declared inside `kos_fs_exec.asm` at `$03BC` had overlapped `VOL_SLOT_F + $1C` (the page byte of F:'s `VOL_BLOCKREAD_PTR`) since Part 22's volume-table expansion. Every `sys_exec` corrupted F:'s block-read function pointer, surfaced as `CODE FAULT odd-addr fetch PC=$FF2803` when `vol` walked F: post-`run`. **§2.2 page-$00 table** updated: FD upper bound corrected from `$04CB` to `$04D6` (was stale since Part 25); new FE-scratch row at `$04D8..$04E3` (Gotcha 4.47 relocation); Reserved-for-kernel-growth region adjusted to `$04E4..$07FF`. **§2.2 trailing prose + §2.4 page-$00 listing** updated to reflect Part 36 consolidation: FD_* and FE_* declarations relocated from their `.asm` source files into `kos_fs_defs.inc`, with a new "ZERO PAGE MAP — RULES FOR ADDING ALLOCATIONS" section in `kos_defs.inc` documenting the recurring collision-bug pattern (Gotchas 4.25, 4.43, 4.47 — three instances of the same root cause) and five prevention rules. Cross-references `kOS_Gotchas v1.18` (entries 4.47 page-$00 collision, 4.48 helper Clobbers don't propagate through TRAP boundary, 4.49 bad-path smoke tests exit too early). Final test state: 21/21 ABI smoke pass on EMU, `vol`/`run`/`vol` sequence clean. |
| 0.23 | 17 June 2026 | **Phase 2a/2b — subdirectories + Part 44 CWD/subdir-aware FS.** §1.1 Filesystem row and §1.3 fs/kosh listings brought current. §5.4 syscall summary adds `sys_mkdir` (69), `sys_resolve` (70), `sys_pwd` (71), `sys_rmdir` (72); `open`/`dirent`/`unlink`/`rename` rows note the Part 44 CWD-context / start-cluster arguments. §2.2 / fd descriptions: fd entry grew 12 → 14 bytes (`FD_DIR_CLUSTER`), `FD_TABLE` now `$000C..$007B`, `FD_TABLE_END` = `$007C`; new Part 44 slots (`FD_PARENT_CL` $049A; rename scratch `RNM_*` $0566..$056B). §1.3 kosh command list gains `cd`/`pwd`/`mkdir`/`rmdir`; `_KoshNormPath` note updated (CWD is a kernel-resolved cluster, not a string rewrite). Full FS surface documented in `kOS_FS_Reference` v1.15. (Revision-history row added retroactively in v0.24.) |
| 0.24 | 28 June 2026 | **Parts 49–50 — graphics-foreground integration + lone-shell fix.** Graphics tasks now join the foreground/shell ring as focusable members. **§3.2 TCB layout** re-synced to live `kos_defs.inc` r46: new `$24 TCB_GFX_MODE` (Part 49); `TCB_RESERVED` narrowed to `$26..$4B`; back-buffer block corrected to `$4C TCB_BACKBUF_OFFS` / `$4E TCB_BACKBUF_PAGE` / `$52 TCB_BACKBUF_CRSR` (the v0.15 names `TCB_BACKBUF_PTR`/`_OFFS`/`TCB_SHELL_GEOM` were stale after the back-buffer paging rework); `TCB_FLAGS` bit map corrected (TF_PRIV is bit 1 not bit 0) and extended with `TF_SYSCRITICAL` (bit 2), `TF_GRAPHICS` (bit 4, $0010), `TF_FOCUSABLE` ($0018); `TCB_SHELL_NEXT` documents the single `0 = lone / not-in-ring` convention; stale "section 9" cross-ref → §13. **§5.7 sys_setvidmode** acquire now sets `TF_GRAPHICS`, records `TCB_GFX_MODE`, splices into the ring via `_SpliceAfterForeground`, becomes foreground, host follows `VID_MODE` to the graphics tab; release reverses all of it and hands foreground back. **§13**: §13.1 field names re-synced; §13.8 documents the `0 = lone` ring convention; §13.9 `ps` gains the `GFX` column (`M<n>` for the `VIDEO_OWNER_TID` holder); §13.10 reap updated to the new convention (treats `0`/`self` as lone, refuses sub-pool `next` — the fix for the Part 49 `DATA FAULT $00014F`) and to the graphics-task case; new **§13.11** (graphics tasks as focusable ring members, Part 49) and **§13.12** (the lone-shell convention + `_SpliceAfterForeground`, Part 50, with the two-bug post-mortem). `fg <tid>` kosh command (already pre-mentioned at §5.4 row 76) is now live. Delivered kernel files: `kos_switcher.asm` r10, `kos_tcb.asm` r24, `kos_defs.inc` r46, `kosh_cmds_sys.asm` r14, `kosh.asm` r43, `kosh_help.asm` r17. |
| 0.25 | 30 June 2026 | **Part 51 — virtual-console auto-switch on launch.** A shell launched without `&` now switches to the foreground and the launching shell stays alive in the background (true VC: Switch toggles both). **§3.2 TCB_FLAGS** gains `TF_AUTOFG` (bit 5, $0020). New defs in `kos_defs.inc`: `TF_AUTOFG`, `EXEC_FOREGROUND` ($0002, `sys_exec` flags bit 1), `ERR_DETACHED` ($FFDA). **§5.4**: `sys_exec` documents the `EXEC_FOREGROUND` input flag; `sys_register_shell` documents `TF_AUTOFG` consumption + the `ERR_DETACHED` launcher wake. **New §13.13** documents the model end-to-end: intent rides exec→child TCB, consumed at `register_shell` time (race-free), `_CommitForeground` does the switch, and the blocked launcher is woken early with `ERR_DETACHED` via `_DeliverWaitDetached`/`_FindWaiterFor` so it returns to its REPL as a background shell. `hello.com` and other non-shell `.COM`s are unaffected (never register, never grab focus). Delivered: `kos_defs.inc`, `kos_fs_exec.asm`, `kos_spawn.asm` (new `_DeliverWaitDetached`), `kos_switcher.asm` (`sys_register_shell`), `kosh_helpers.asm` (`_KoshExecFile`). Cross-references `kOS_Gotchas v1.24` (§4.57 syscall carry sense, §4.58 `ERR_DETACHED` on the carry channel). |
| 0.26 | 9 July 2026 | **Part 55/56 — page-$00 regionisation + doc pass.** The entire page-`$00` map is now expressed with the assembler `.REGION` / `.RS` system (K16 ref §4.12): 23 collision-checked regions across `kos_defs.inc`, `kos_fs_defs.inc`, `kos_klib.inc`; zero address drift (symbol-diff verified). Semaphore-pool defs relocated out of `kos_sem.asm` into `kos_defs.inc` (`SEMPOOL` region) — the last `.asm`-resident page-`$00` allocation. **§2.2** table gains a `Region` column, the `$04E4..$07FF` "reserved" block decomposed into its real occupants (`RVSCRATCH`/`RNMSCRATCH`/`LFNSCRATCH` FS resolver scratch + the `ASSIGNTABLE` named-drive/assign table and `ASGNSCRATCH`, Parts 54–55), the sysvars block split into its four regions, and a `KOSINFO` row added at `$A300`. **§2.4** prose mirror updated to match. **§5.5.1 erratum:** semaphore pool base corrected from the stale `$03C8..$0447` to `$0400..$047F` (moved during the Part 22/23 volume-table expansion; §5.5 was never re-synced); pool defs noted as living in `kos_defs.inc` `SEMPOOL`. **New §12.7** (page-$00 allocation convention: `.REGION`/`.RS` in the defs `.inc`, never hand-`.EQU` in a `.asm`). **§1.3** `kos_defs.inc` description notes the region reservations. **§14 kosh-command refresh:** coverage note rewritten (subdirs/LFN/`cd`/`pwd`/`mkdir`/`rmdir` no longer listed as pending); §14.1 `vol` sample and column layout updated for the `Name` column (named-volume reverse-lookup); §14.2 `ls` "no subdirectories" claim removed; new §14.3 (drive switching & named volumes), §14.4 (`assign`), §14.5 (`fg`). §1.1 notes bare named-volume switching. §5.4 gains `sys_assign` (#78) and the Device-group reserve narrows to 79..84. **§1.3 source layout reconciled** to the live tree: new `kdrv/` subsection (`kos_console.asm` moved from `kernel/`, plus `kos_kbd.asm` and `kos_video.asm`); kfs table gains `kos_fs_dir_lfn.asm` and `kos_fs_dir_path.asm` (Part 47 three-way dir split) and the stale merged resolver row removed; `kos_fs.asm` / `kos_fs_defs.inc` descriptions updated for the assign layer and LFN. **§1.3 kosh table** reconciled: new `kosh_boot.asm` / `kosh_splash.asm` / `kosh_defs.inc` rows; `kosh.asm` notes named-volume switching + `fg`; `kosh_helpers.asm` gains `_KoshEmitPwdNamed`; `kosh_cmds_fs.asm` gains `assign`. **§14.4 `assign` syntax corrected** to the shipped form `assign NAME PATH` / `assign NAME` (was the design-note `NAME:` form) with the real list output and `OK` / `ERR_NOTDIR` behaviour. **§1.3 kernel table** descriptions refreshed against the live tree (`kos_heap`, `kos_kmalloc`, `kos_sem`, `kos_spawn`, `kos_switcher`, `kos_task`, `kos_tcb` — added the syscalls/helpers accrued since Part 20: extra heap TRAPs, the four semaphore syscalls, `_TidToTcb`/`_DeliverWaitDetached`, the ring splice/commit helpers, `sys_kill`, and `_ReapDeadTask`). **Added the `emulib/` subdirectory** (sixth) to §1.3 — the emulator-only EMULIB host-disk jump table (`kos_emulib.inc`, `kos_emulib_template.asm`); §2.2 corrected: `$A200..$A2FF` was mislabelled "kernel work area" and is in fact the EMULIB jump table. §12.1 file-naming gains the `emulib/kos_emulib_*` pattern. **Verification pass:** §2.2 region bases diffed against live `kos_defs.inc` / `kos_klib.inc` / `kos_fs_defs.inc` (all match) and the §5 syscall-table TRAP numbers diffed against the `VEC_*` map (all match); fixed the `kos_console.asm` row's TRAP range (was "9..13, 20..23", correct is #10..18). **§11.8 error-code table rebuilt** from `kos_fs_defs.inc` (was entirely stale — wrong values, two non-existent names, six missing codes); **§11.5 fd table** gains the `FD_DIR_CLUSTER` (`$0C`) row and the `FD_DRIVE` range corrected to 0..5. **Audit sweep of §3–§13** against the uploaded source: verified clean — §3.2/3.3 TCB layout/states/flags, §4.3 `KERNEL_STATE` (`$0232`), §5.5 sem pool, §5.7 video modes, §6.2 heap header, §7 page alloc (`USER_PAGE_BASE=$02`), §8.3 `SYS_TICKS`/kbd MMIO, §11.6 ABI, §11.9 `.COM` rules, §13.7 hot keys; fixed §8.3's stale hot-key names ("F1/F2/Ctrl-Tab" → the shipped Ctrl-N/P/digit) and §11.10's stale "follow-on work remaining" list (those kosh commands have shipped). No behavioural or address change. |
| 0.27 | 11 July 2026 | **Part 57 — kosh task-page refactor.** kosh's scattered Part-42..56 buffer layout (4 regions riddled with hand-computed `TB_PAD*`/`PS_PAD*` fillers and an 896-word blanket zero-fill that was almost all pad) was rebuilt into three tight, single-purpose regions on a high fixed base: **`KCORE`** (`$8000`, persistent `KOSH_CWD`/`KOSH_CWD_CLU`), **`KBUFS`** (`$8100..$8771`, staging buffers), **`KSTATE`** (`$8800..$886D`, per-command scratch, zero-filled at entry). Base raised to `$8000` for ~32 KB code runway (`$0200..$7FFF`), ending the Part-40/Part-56 code-into-buffer collision class; the `.SPACE kosh` code-in-region guard now polices it at assemble time. `KSTATE` zero-fill is symbol-driven (`KSTATE_START`/`KSTATE_WORDS`), 896→55 words. Variables renamed consistently (`_TMP` suffix dropped across 22 symbols; `LINE_BUF_OFF`→`LINE_BUF`; `LIST_BUF_END` retired); all task-page access is symbol-addressed (no hardcoded addresses), so the repack propagated through all 11 kosh files automatically. **New §2.6** (kosh task page) documents the region map, the high-base rationale, the guard, and the zero-fill. **§1.3** `kosh_defs.inc` row updated. **Glossary CWD** entry corrected (`KOSH_CWD` `$45C0`→`$8000`; stale — predated even the Part-42 `$65C0`; CWD resolution re-described as kernel-side per Part 44). Delivered: `kosh_defs.inc` (rewritten), `kosh.asm`, `kosh_cmds_fs.asm`, `kosh_cmds_disk.asm`, `kosh_helpers.asm`. Build + run verified. |
| 0.28 | 12 July 2026 | **Part 57 — kosh scripts (`.KSH` batch execution).** New `kosh_script.asm`: a script is a text file of kosh command lines run through the normal dispatch (AmigaDOS `Execute` model). The REPL calls `_KoshScriptNextLine` as its line source — when a script is active it returns the next executable line (`;`/blank lines skipped, `CR` stripped, line echoed) in `LINE_BUF`, else it prompts + `sys_gets` as before; files are read one byte at a time via `sys_read`, so each nesting level needs only its fd. `.ksh` names route to `_KoshRunScript` in `_KoshExecFile`, so `run NAME.KSH` and bare `NAME.KSH` both work. Nesting is a LIFO fd-stack capped at `SCRIPT_MAX_DEPTH` (4); errors are continue-and-echo (`failat` deferred to v2). **Boot cascade** — `_KoshCascadeAdvance` runs `STARTUP.KSH` at the root of A:→B:→C: in order (each to completion, one fd open at a time via the `SCRIPT_BOOT_DRV` cursor; unmounted/missing skipped) at `kosh_entry` before the first prompt, recreating the named-volume namespace each boot. **New §14.6** documents format, running, nesting, error policy, boot cascade, and implementation. **§2.6 / KSTATE** grew 55→62 words (`$8800..$887C`) for the `SCRIPT_*` family (`SCRIPT_DEPTH`, `SCRIPT_CHAR`, `SCRIPT_BOOT_DRV`, `SCRIPT_FDS`×4). **§1.3** gains the `kosh_script.asm` row. Also this part: `kosh_help.asm` gained a `scripts:` section and its command dashes were realigned to one column; the `info`/banner kosh version was unified on a single `kosh_ver_str` source (it had drifted — `info` still read v1.0 after the Part 49 banner bump to v1.01). Delivered: `kosh_script.asm` (new), `kosh.asm`, `kosh_helpers.asm`, `kosh_defs.inc`, `kosh_help.asm`, `kosh_cmds_sys.asm`. Build + run verified — runner, nesting, cascade, and the namespace script all smoked on EMU. |
| 0.29 | 19 July 2026 | **Part 58 — console-attribute verbs documented + ABI note.** **§5.1** gains the Part-57/58 console verbs that landed in code but were never written up: `sys_termsize` (#19, live geometry via `$DB:$0000` MMIO / Digital 80×24), `sys_setattr` (#20, VGA attribute byte), `sys_clreol` (#21, BCE), `sys_cursorvis` (#22, structural hide/show), `sys_wherexy` (#23, 0-based col/row), `sys_clreos` (#24, BCE) — with the `console.pas` mapping and the `TCB_VIS_ROWS`-is-a-snapshot note under `sys_termsize`. **§5.4** summary table gains rows 19..24. **§5** ABI preservation prose adds Gotcha 4.59 to the silent-corruption examples list. Context: the colour-matrix bug (`sys_putdec` leaked `Y2`, corrupting K16Pascal 2-arg function results) is documented in `kOS_Gotchas v1.25` §4.59; the ClrEos background-erase fix (emulator BCE) in §4.60. No behavioural change to the manual's subject matter — this is doc catch-up plus the ABI cross-reference. |
| 0.30 | 25 July 2026 | **Part 60 — TRAP #13 reclaimed: `sys_putln` retired, `sys_putlp` added.** The nul-terminated + CRLF `sys_putln` (unused by the RTL, compiler, and kosh source — only an embedded `HELLO.COM` blob and one kosh script-echo referenced it) is retired; TRAP #13 now carries **`sys_putlp`**, a length-prefixed (Pascal-string) emitter — the kernel reads the leading length byte at `[XY0]` and emits that many characters, no terminator consulted or emitted. Same non-leaf / atomic / back-buffer routing as `sys_puts` (the nul-scan is replaced by a `D2` down-counter seeded from the length byte). Motivation: the Pascal RTL `__puts`/`__putsrom` collapse from a per-character `TRAP_PUTCHAR` loop to a single `TRAP_PUTLP`, cutting per-line console output from N TRAPs to one. **§5.1** `sys_putln` entry replaced by `sys_putlp`; **§5.4** row 13 relabelled; **§1.3** `kos_console.asm` handler list and **§5** output-syscall prose `putln`→`putlp`; **§13.2** routing list updated (and a pre-existing duplicate `sys_putln` corrected to `sys_puthex`); the `.vid_busy` video-mode example retargeted to `TRAP #TRAP_PUTS`. Code: `kos_defs.inc` (`TRAP_PUTLN`/`VEC_PUTLN` → `TRAP_PUTLP`/`VEC_PUTLP`, number/slot unchanged), `kos_console.asm` (`sys_putln` body replaced by `sys_putlp`), `kos_boot.asm` (vector install); kosh migrated (script echo → `sys_puts` + `CH_LF`; `HELLO.COM` blob → `$F018`). Cross-references `kOS_Gotchas v1.26` §4.44. |
| 0.31 | 25 July 2026 | **Doc corrections — console handler range and the `sys_setvidmode` example.** Two fixes found while auditing v0.30's Part 60 changes. **§1.3** `kos_console.asm` row claimed its handlers span TRAPs #10..18; the file also carries the Part 57/58 console-attribute verbs (`sys_termsize` #19, `sys_setattr` #20, `sys_clreol` #21, `sys_cursorvis` #22, `sys_wherexy` #23, `sys_clreos` #24), documented in §5.1 since v0.29 but never added to the module list — range corrected to #10..24 and the six names added. **§5.7** the `.vid_busy` example was retargeted from `sys_putln` to `sys_puts` in v0.30, which silently dropped the CR/LF the old call appended; a reader copying the idiom for ordinary output would lose the line break. Example now emits `CH_LF` via `TRAP_PUTCHAR` after the string, matching the migration kosh's script echo used. No behavioural change — documentation only. |
| 0.32 | Saturday, 1 August 2026 | **Part 60 — multi-page tasks and the `.COM` header.** A task may now own a **run** of N contiguous pages, declared in a new 12-byte `.COM` header and granted at load time or not at all. **New §11.9 header subsections**: the layout (`JMP16` at `$0200`, then magic `$4252` "RB" / version / `pages` / `heapPages`, all full words, `__start` at `$020C`), why the jump precedes the header (a loader must never compute a jump target from data it cannot parse; a `.COM` also stays directly executable with no loader), why `JMP16` and not `JMP24`, why `.WORD` and never `.BYTE` (K16 RM §4.6 does not accept symbols in `.BYTE`, and an all-`.WORD` block cannot leave an odd byte count), `heapPages` as a partition of `pages`, the `_ComHeaderCheck` contract, and the five-step load sequence. **§7 rewritten**: `_PageInUse` is now a **range** test over `[TCB_SAVED_Y .. +TCB_PAGE_COUNT)`; `_AllocPageRun(N)` replaces `_AllocPage` as the primitive (one probe per candidate carrying a consecutive-free run length, so large N costs nothing extra) with `_AllocPage` retained as a two-instruction wrapper; new §7.5 documents multi-page tasks, self-discovery via `Y3` + `COM_HDR_PAGES`, and the rule that sequential access across a run must use `INC XYn` / `[XYn]+` and never `ADD Xn` (16-bit, wraps at the page boundary). Fragmentation and no-dynamic-growth recorded as deliberate limitations; "pages are not cleared on allocation" documented. **§7.4 page release moved from reap to death**: `sys_exit` / `sys_kill` zero `TCB_PAGE_COUNT`, so the run returns to the pool immediately while the `TS_DEAD` TCB lingers holding only `TCB_EXIT_CODE` — the Unix split, where a zombie holds a status rather than an address space. Previously a backgrounded task that exited with no waiter held its pages forever, which only became material once a task could hold three. **§3.2/§3.3/§3.4** updated to match (`TCB_PAGE_COUNT` is load-bearing, not reserved; `TS_DEAD` no longer holds pages; reap frees the TCB slot only). **New error `ERR_BADHEADER` (`$FFD8`)** in §11.8, deliberately distinct from `ERR_NOTEXEC` — which already covered four unrelated failures, so a stale headerless image could not say what was wrong. **§13.9** `ps` `PAGE` → `PAGES` (width 8): `-` / `$nn` / `$nn-mm`, with a note that `BLOCKS`/`BYTES` are heap, not pages. Delivered files: `kos_defs.inc`, `kos_fs_defs.inc` (`COMHDRSCRATCH` region, `KERNEL_ZP_NEXT_FREE` → `$07EA`), `kos_tcb.asm`, `kos_spawn.asm`, `kos_fs_exec.asm`, `kos_task.asm`, `kosh.asm`, `kosh_cmds_sys.asm`; all `.COM` producers rebuilt (kosh, the embedded HELLO image, FORTH31, BASIC26, CUBE6, MANDEL). New tests `PAGETEST.asm` (16 checks: header readback, pattern integrity, inter-page aliasing, `INC XY` page-cross carry vs `ADD X` wrap — both asserted; plus a soak mode for two-task isolation) and `PAGEHOG.asm` (declares 200 pages, must never start). Verified on EMU. |
| 0.33 | Sunday, 2 August 2026 | **Part 61 — `XY2` genuinely preserved across syscalls.** §5 register preservation: the "fully audited across all 37 handlers" claim was **false** and is corrected. `XY2` had been documented as preserved since Part 20a, but nineteen of the 49 handlers did not save it — four demonstrably (`sys_open`, `sys_write`, `sys_mkdir`, `sys_diskfree`). Found from the K16 Pascal side: `XY2` is the Pascal frame pointer, so a handler returning with it disturbed corrupts the **caller's frame** rather than its own result, and only for callers that touch a parameter or return a value after the call — a `Boolean` function that opened a file returned `False`. `sys_open` showed one `XY2` reference of its own; the clobber was three levels down in `_SlotForDrive` (returns the volume slot in `X2`, sets `Y2 = $00`), so **the save requirement is unconditional** and must not be decided by auditing a handler body. Root cause of the drift: each handler restated the contract in its own header as `D1, D2, D3, XY1`, omitting `XY2` and contradicting this manual; the per-handler comment is what an implementer reads. Those four restatements are replaced by a pointer to a single authoritative `SYSCALL REGISTER CONTRACT` block in `kos_defs.inc`, and no copy of the old sentence remains. Nineteen handlers gained `PUSH XY2`/`POP XY2` in mirrored position on every exit arm (`kos_fs_fd.asm` ×7, `kos_fs.asm` ×4, `kos_console.asm` ×3 — `sys_setcursor` needs two pairs, its arms are disjoint — `kos_sem.asm` ×3, `kos_heap.asm` ×2). Five handlers are exempt and now carry `Preserves:` lines instead: `sys_exit` (never returns), `sys_getchar` (tail-calls `_GetGatedKey`, which preserves), and `sys_termsize`/`sys_cursorvis`/`sys_wherexy`/`sys_getpid` (no calls, exit via `RETCC`/`RETCS`, where an outstanding `PUSH` would leak on the taken arm). `sys_exec` already complied and documented it. Regression cover: `SyscallFrameTest.pas`. Second occurrence of this bug — Gotcha 4.59 records `sys_putdec` leaking `XY2` and corrupting K16 Pascal function results; fixed locally at the time without generalising. |
| 0.34 | Saturday, 8 August 2026 | **Part 61 — graphics tasks detach their launcher; VID_PAGE documented as uninitialised.** A graphics program run without `&` was unrecoverable: `sys_setvidmode` acquire made it foreground (Part 49) but left the launching shell blocked in `sys_wait`, and `sys_kill` admits only a privileged caller or the parent — the very task that was blocked. `Ctrl-N` reached a frozen prompt; only Reset escaped. Acquire now runs the same detach `sys_register_shell` has used since Part 51 (`_FindWaiterFor` → `_DeliverWaitDetached` → `TS_READY`, plus the `TF_DETACH_PENDING` lost-race arm), guarded by `TF_HAS_BACKBUF` so an already-registered shell does not detach twice. **§5.7** acquire list gains step 5 with the rationale; **§13.11** gains the matching bullet; **§13.13** gains a graphics row in the launch-semantics table. **§13.13 correction:** the sentence naming `mandel` as a program that "never grabs focus" has been **false since Part 49** — a graphics task becomes focusable via `sys_setvidmode`, not `sys_register_shell`, so focus moves without `TF_AUTOFG` ever being consumed; corrected in place with a marked note. **§5.7 VID_PAGE** paragraph extended: the kernel never writes `$DC0000` (`_InitVideo` touches only `VID_MODE`), so a graphics task inherits the previous task's page selection and must program VID_PAGE itself — the failure is intermittent-invisible rendering, correct pixels into an unscanned page. Delivered: `kos_video.asm` r3; `gfx.asm` (`gfx_open` now sets VID_PAGE); `Mandelbrot.asm`, `Cube6.asm`, `GUI128F.asm`. Cross-references `kOS_Gotchas v1.27` (§4.54 amended, §4.61 added). |
| 0.35 | 8 August 2026 | Part 61 — k/OS v1.02 / "Phase 61+". §14.6 substantially revised: new **Presentation** subsection (brief `-b` mode, the in-script `echo -b` / `-v` directive, and the `SCRIPT_ARROW_COL` arrow-retraction guard in `_KoshPrintPrompt`); drive-qualified bare names (`RAM:FOO.KSH`) documented along with the `CD_BARE` mechanism that unblocked them; the boot cascade no longer "skipped silently" — each running leg announces `[X:STARTUP.KSH]`; sample `STARTUP.KSH` modernised (colon-suffixed assign names, brief mode) and a second sample added for the read-only-A: bootstrap pattern; implementation state list gains `SCRIPT_FLAGS` and `SCRIPT_ARROW_COL`. §2.6 `KSTATE` 62 → 69 words, `CD_BARE` listed. §14 coverage notes `load`'s host-folder prefix. |
| 0.36 | 8 August 2026 | **`sys_kbhit` (TRAP #79) documented; the ring-membership reporting rule stated.** New **§5.1** entry for `sys_kbhit` — the non-blocking counterpart to `sys_getchar`, added because an animated graphics task cannot block without freezing on frame one, and cannot poll the ring itself (`KBD_HEAD`/`KBD_TAIL` are kernel page `$00`). Routing is `_GetGatedKey`'s minus the waiting: focusable tasks are foreground-gated, plain tasks read the ring directly, and a shut gate yields `C=1` instead of a yield-and-re-gate. Leaf, no `DINT` — the ring is single-producer/single-consumer. Noted that it **pops rather than peeks**. New **§5.4a** on stale input: `_RingPush` is unconditional and the ring is global, so a task that does not read for a long time accumulates input and passes the remainder to whoever reads next; documents the drain idiom and records that a kernel-side flush on foreground switch was rejected (it would kill type-ahead across `Ctrl-N`). §5.4 summary table gains slot 79; the reserve list corrected from `79..84` to `80..84`. **§13** gains the reporting rule: a task that has joined the focus ring cannot report to the console on exit — `_ReapDeadTask` repaints over it, and a shell's own back-buffer is freed in the same step — so validate before joining, and after joining report by exit code. kosh renders known `ERR_*` codes symbolically via `_KoshErrName`; explanatory text belongs to the application, since kosh sees a number without context. Cross-references `kOS_Gotchas v1.29` §4.67. |
| 0.37 | Sunday, 9 August 2026 | **Part 63 — kosh path handling: `load` made CWD-relative, `_KoshNormPath` removed, the `KOSH_NORM` buffers sized and enforced.** **§1.3** `kosh_helpers.asm` row: `_KoshNormPath` struck (zero callers, and its behaviour was actively wrong — prepending `<CWD>:` makes a path drive-absolute, which per the resolver convention means start cluster 0); `_KoshCopyBounded` added; `_KoshResolveDstPath` noted as returning `C=1` / `CP_ERR_TOOLONG`, a change from its previous "C = 0 always" contract. **§2.6** `KBUFS` extent corrected `$8771` → `$87F2` and per-field sizes given: `KOSH_NORM_A/B` are 80 bytes each (`KOSH_NORM_LEN`), raised from 16 because `_KoshResolveDstPath` joins `dst + "/" + basename(src)` with no cap — `cp Mandelbrot.com gfx` is 19 bytes into a 16-byte buffer, and had been overrunning silently into `CAT_BUF`. 80 is derived from `LINE_BUF_MAX`: line ≤ 79 ⇒ `src + dst ≤ 75` ⇒ join ≤ 77. **§13** glossary CWD entry rewritten: the raw-path + `D1`/`D2` context pattern is now the documented way to resolve against the CWD. Appendix A ordering repaired (0.35/0.36 had been inserted above the ascending run, 0.26/0.27 transposed, and a stray blank line split the table into two renderings); document footer corrected, it had read v0.34 since the v0.35 revision. Cross-references `kOS_Gotchas v1.30` §§4.69-4.71. |

*End of k/OS Reference Manual v0.37*
