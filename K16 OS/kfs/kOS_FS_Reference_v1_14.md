# k/OS Filesystem Reference

Version 1.14 -- 27 May 2026

Phase 16 design specification. Wire format, mount procedures, syscall ABI.
Implementation status reflects Pieces 1+2+3+4+5+6 verified, Part 20a
ABI audit fixes, Phase 19 follow-up bug closures, Parts 22+23 (host-disk
backend and name-based mount management), Part 24 (host filename rename,
mount semantics simplification), Part 25 (FS surface: unlink/rename
syscalls, host-file ingestion via the load command, kosh CWD model), and
Part 26 (ROM-disk authoring pipeline: EMU `[Disks] A=` preload, assembler
`.INCBIN`-equivalent overlay at ROM generation, end-to-end Forth + BASIC
on Digital from A:).

---

## 1. Overview

k/OS Phase 16 introduces a filesystem layer based on a clean-slate implementation of **Microsoft FAT16**, with a swappable storage backend.

The choice of FAT16 (rather than a custom format) is deliberate. FAT16 is widely documented, mountable from any modern operating system without custom drivers, and well-suited to the volume sizes k/OS will work with for the foreseeable future. RAM-disk image files produced by k/OS are bit-identical to FAT16 images produced by `mkfs.fat`, and round-trip cleanly through Windows, Linux, or macOS without translation.

### 1.1 At a glance

| Aspect | Value |
|---|---|
| Format | FAT16 (Microsoft, with one FAT copy) |
| Sector size | 512 bytes |
| Cluster size | 512 bytes (RAM disk), variable on SD |
| Maximum volume size | 2 GB (FAT16 ceiling, sector size 512) |
| Filename format | 8.3 (Phase 16); LFN planned for Phase 18+ |
| Subdirectories | Format-supported, not implemented in Phase 16 |
| Backends | ROM disk (`A:`), RAM disk (`B:`), host disk (`C:`–`F:`, EMU-only) |
| Syscalls | 9 TRAPs (open, close, read, write, dirent, exec, format, unlink, rename) |

### 1.2 Design principles

**Standard format, swappable backend.** Every FS operation goes through a thin block-layer abstraction (`_BlockRead`, `_BlockWrite`). RAM, ROM, and host-file backends are interchangeable behind that interface.

**Six drive slots.** `A:` (read-only ROM disk) holds k/OS-supplied programs; `B:` (read-write RAM disk) holds user files. `C:` through `F:` are host-disk bays — host files served by the EMU disk controller (Parts 22+23). All use the same FAT16 format. On Digital, only A: and B: are available; C..F are silently absent (the controller doesn't exist there).

**Interop first.** Image files produced by k/OS can be opened in Windows. Image files produced by Windows tools can be mounted in k/OS. No custom tooling required to author or inspect a volume.

**Per-task file descriptors.** Each task holds a small fd table in its task-local page-zero region. fd values 0..7 are private to the task and do not survive `sys_exec`.

### 1.3 Source layout

All filesystem source lives in `kfs/`:

| File | Purpose |
|---|---|
| `kos_fs.asm` | Top-level: `_InitFS`, `_FormatVolume`, FAT walk, cluster alloc |
| `kos_fs_ram.asm` | RAM disk backend (BlockRead/BlockWrite for B:) |
| `kos_fs_rom.asm` | ROM disk backend (BlockRead-only for A:) |
| `kos_fs_host.asm` | Host disk backend (BlockRead/BlockWrite for C..F:) — Part 22 |
| `kos_fs_host_mgr.asm` | Host disk management helpers (mount/unmount/list/create/delete) — Part 23 |
| `kos_fs_dir.asm` | Directory operations, name lookup, dirent iteration |
| `kos_fs_fd.asm` | Per-task fd table; sys_open/close/read/write |
| `kos_fs_exec.asm` | sys_exec implementation |
| `kos_fs_defs.inc` | FS-internal constants (BPB offsets, attribute bits, MMIO regs) |

Top-level `kos_defs.inc` adds the new TRAP numbers (26..31) and FS-related error codes.

---

## 2. Volume layout

Every k/OS FAT16 volume conforms to the standard FAT16 disk layout. The on-disk image consists of four contiguous regions:

```
+---------+--------+----------+--------------+
|  Boot   |  FAT   |   Root   |     Data     |
| sector  |        |   dir    |   clusters   |
+---------+--------+----------+--------------+
   1 sec    N sec    M sec       remainder
```

**Boot sector (sector 0).** Holds the BIOS Parameter Block (BPB), volume label, and the standard FAT16 signature `0xAA55` at offset `$1FE`. No bootstrap code (the BPB is followed by zeros).

**FAT region (sectors 1..N).** A single copy of the File Allocation Table. Each FAT entry is 16 bits; the FAT itself is sized to cover all clusters in the data region.

**Root directory (sectors N+1..M).** A fixed-size area immediately after the FAT, holding 32 directory entries (= 1024 bytes = 2 sectors). Standard FAT16 places this here rather than in the cluster chain.

**Data region (sectors M+1..end).** Cluster-aligned. Cluster 2 is the first cluster (cluster numbers 0 and 1 are reserved in FAT). Files and (eventually) subdirectories live here.

### 2.1 Standard layouts

**RAM disk B: (1 MB)**

```
Total sectors    : 2048
Sector 0         : Boot sector + BPB
Sectors 1-8      : FAT (8 sectors = 4096 bytes = 2048 entries)
Sectors 9-10     : Root directory (32 entries x 32 B = 1024 B = 2 sectors)
Sectors 11-2047  : Data (2037 clusters of 512 B = ~1018 KB usable)
```

**Digital RAM disk (256 KB)**

```
Total sectors    : 512
Sector 0         : Boot sector + BPB
Sectors 1-2      : FAT (2 sectors = 1024 entries; only 512 used)
Sectors 3-4      : Root directory (2 sectors = 32 entries)
Sectors 5-511    : Data (507 clusters of 512 B = ~253 KB usable)
```

**ROM disk A: (128 KB, read-only)**

```
Total sectors    : 256
Sector 0         : Boot sector + BPB (read-only flag set in BPB)
Sectors 1-2      : FAT (2 sectors)
Sectors 3-4      : Root directory
Sectors 5-255    : Data (251 clusters of 512 B = ~125 KB usable)
```

**Future SD card C: (32 MB, illustrative)**

```
Total sectors    : 65536
Cluster size     : 2 KB (4 sectors per cluster)
Sector 0         : Boot sector + BPB
Sectors 1-64     : FAT (64 sectors = 32768 entries)
Sectors 65-66    : Root directory
Sectors 67+      : Data (16367 clusters x 2 KB)
```

Cluster size on SD is chosen at format time to keep the FAT itself within reasonable bounds. The k/OS FAT16 driver handles any cluster size that's a power of two from 512 B to 32 KB; the rest of FAT16's specified range is supported by the wire format if not exercised today.

---

## 3. Boot sector and BPB

The boot sector is 512 bytes. Only the BPB and the trailing signature are meaningful to k/OS; all other bytes are zero.

| Offset | Size | Field | k/OS value |
|---|---|---|---|
| `$000` | 3 B | Jump instruction | `EB 3C 90` (no-op for us) |
| `$003` | 8 B | OEM name | `"K16-KOS "` (8 chars, space-padded) |
| `$00B` | 2 B | Bytes per sector | `512` |
| `$00D` | 1 B | Sectors per cluster | `1` (RAM); variable on SD |
| `$00E` | 2 B | Reserved sectors | `1` (just the boot sector) |
| `$010` | 1 B | Number of FATs | `1` |
| `$011` | 2 B | Root dir entries | `32` |
| `$013` | 2 B | Total sectors (16-bit) | `2048` for 1 MB; 0 if `$020` is used |
| `$015` | 1 B | Media descriptor | `$F8` (fixed disk) |
| `$016` | 2 B | Sectors per FAT | `8` for 1 MB |
| `$018` | 2 B | Sectors per track | `0` (unused) |
| `$01A` | 2 B | Number of heads | `0` (unused) |
| `$01C` | 4 B | Hidden sectors | `0` |
| `$020` | 4 B | Total sectors (32-bit) | Used if `$013` is 0 |
| `$024` | 1 B | Drive number | `$80` |
| `$025` | 1 B | Reserved | `0` |
| `$026` | 1 B | Extended boot signature | `$29` |
| `$027` | 4 B | Volume serial number | Random at format |
| `$02B` | 11 B | Volume label | `"NO NAME    "` or user-supplied |
| `$036` | 8 B | Filesystem type label | `"FAT16   "` |
| `$03E` | 448 B | (reserved/zero) | All zero |
| `$1FE` | 2 B | Signature | `$AA 55` |

This BPB is intentionally **fully Microsoft-compatible**. Mounting this volume in Windows displays the volume label and shows the format as `FAT16`.

The OEM name field (`"K16-KOS "`) is informational only -- Windows ignores it for mounting purposes. It serves as a marker for tools that want to recognise k/OS-authored volumes.

### 3.1 The drive bit and volume label

Field at `$02B` (volume label) is the closest FAT16 gets to "named volumes" -- 11 ASCII characters, space-padded. k/OS uses this directly.

Read-only volumes are not a standard FAT16 concept. k/OS marks ROM volumes by setting the high bit of the Media descriptor (`$015`) to `$F8 | $80 = $78`... no, that breaks FAT16. Instead, k/OS encodes "this volume is read-only" by setting **byte `$025` (reserved)** to `$01`. Standard FAT16 readers ignore this byte; k/OS treats it as "reject all writes if set". The ROM disk image has this bit set; the RAM disk does not.

This is a k/OS extension. Windows and other FAT16 readers will happily attempt to write to a ROM disk image, succeed in their own RAM, but produce no useful change because the underlying ROM cannot accept writes. The flag exists to give k/OS itself a fast reject path.

---

## 4. FAT region

The File Allocation Table is the core of FAT16's allocation and chaining mechanism. Each cluster on the volume has a corresponding 16-bit entry in the FAT.

### 4.1 Entry values

| Value | Meaning |
|---|---|
| `$0000` | Cluster is free |
| `$0001` | (Reserved -- not used as a cluster number) |
| `$0002..$FFEF` | Cluster is allocated; value is the next cluster in the chain |
| `$FFF0..$FFF6` | Reserved values |
| `$FFF7` | Bad cluster (do not use) |
| `$FFF8..$FFFF` | End-of-chain marker |

A file's cluster chain starts at the cluster number in its directory entry. Each FAT entry tells where the next cluster is. The chain terminates at any value in `$FFF8..$FFFF`.

### 4.2 Reserved entries

`FAT[0]` and `FAT[1]` are reserved.

- **`FAT[0]`** holds the media descriptor in its low 8 bits, with the upper 8 bits all `1`. For our `$F8` media: `FAT[0] = $FFF8`.
- **`FAT[1]`** holds the end-of-chain marker by convention; some implementations also use bits within it for "clean shutdown" and "no I/O errors" flags. k/OS writes `$FFFF` and ignores the soft flags.

### 4.3 Allocation

To allocate a free cluster, k/OS scans FAT entries linearly from index 2 upward, looking for the first `$0000`. When found, it is written with `$FFFF` (end-of-chain) and returned to the caller. If extending an existing file, the previous tail entry is updated to point at the newly allocated cluster.

There is no free-cluster bitmap separate from the FAT itself. The FAT *is* the bitmap.

For 1 MB volumes (2048 entries), a worst-case scan touches 4096 bytes -- well under one disk block on RAM and a handful of sectors on SD. No optimisation needed at this size.

---

## 5. Directory entries

The root directory contains 32 entries. Each entry is 32 bytes:

| Offset | Size | Field |
|---|---|---|
| `$00` | 11 B | 8.3 filename (8 base + 3 ext, both space-padded) |
| `$0B` | 1 B | Attributes |
| `$0C` | 1 B | Reserved (Windows NT case flags) |
| `$0D` | 1 B | Creation time tenths |
| `$0E` | 2 B | Creation time |
| `$10` | 2 B | Creation date |
| `$12` | 2 B | Last access date |
| `$14` | 2 B | First cluster (high word -- 0 for FAT16) |
| `$16` | 2 B | Last write time |
| `$18` | 2 B | Last write date |
| `$1A` | 2 B | First cluster (low word) |
| `$1C` | 4 B | File size in bytes |

### 5.1 Filename storage

The filename is stored as 11 bytes -- 8 for the base name, 3 for the extension, both space-padded with no separating dot. The dot that the user types is implicit in the layout.

Examples (showing the literal 11 bytes):

```
"FORTH   COM"   -- forth.com
"BASIC   COM"   -- basic.com
"NOTES   TXT"   -- notes.txt
"HELLO      "   -- hello (no extension)
"AUTOEXECBAT"   -- autoexec.bat
```

The 11 bytes are case-insensitive in FAT16 -- Microsoft tools store ASCII uppercase. k/OS follows this convention. Lookups uppercase the candidate name before comparing.

The first byte of the filename also acts as a status indicator:

| First byte | Meaning |
|---|---|
| `$00` | Entry has never been used; scan can stop here |
| `$E5` | Entry was deleted; can be reused |
| `$05` | (Special: actual first byte is `$E5`, escape hatch for filenames starting with `$E5`) |
| `$2E` | (`'.'`) Self-reference (`.` or `..`); only in subdirectories |
| any other | Entry is in use |

### 5.2 Attribute byte

| Bit | Mask | Meaning |
|---|---|---|
| 0 | `$01` | Read-only |
| 1 | `$02` | Hidden |
| 2 | `$04` | System |
| 3 | `$08` | Volume label (only one entry in root has this) |
| 4 | `$10` | Directory |
| 5 | `$20` | Archive |
| 6-7 | -- | Reserved |

**Special case: attribute `$0F`** marks a "long filename" entry. k/OS Phase 16 ignores all entries with attribute `$0F` during directory scans. Phase 18+ will consume them to assemble long names.

The volume label entry sits in the root directory, has attribute `$08`, and the 11-byte name field holds the volume label. There is at most one such entry per volume.

### 5.3 Time and date fields

FAT16 stores creation/modification times as packed 16-bit fields:

```
Date:  YYYYYYY MMMM DDDDD     (year since 1980, month 1..12, day 1..31)
Time:  HHHHH MMMMMM SSSSS     (hour 0..23, minute 0..59, seconds/2)
```

k/OS Phase 16 has no real-time clock. All time fields are written as zero. When (eventually) a clock arrives, the format is ready to use.

### 5.4 Cluster pointer

Standard FAT16 splits the first-cluster pointer across two fields (`$14` high word, `$1A` low word) for FAT32 compatibility. **For FAT16 the high word is always zero.** k/OS reads only the low word and writes zero to the high word.

A file size of zero in the directory entry, combined with a first-cluster value of zero, indicates an empty file with no allocated clusters.

### 5.5 Directory operation API

Phase 16 Piece 4 provides the kernel-internal API for working with directory entries. These routines are not syscalls — they are called directly from kernel code and from `sys_open`, `sys_dirent`, etc. (Pieces 5+).

All routines preserve `D3` (drive index), `XY2` (slot pointer), and `XY3` (stack pointer). Most preserve `XY0` as well; see individual entries.

**Iteration cookie format.** A directory iterator is a single 16-bit word:

```
bits 15..4   sector offset within root dir region (0..root_sectors-1)
bits  3..0   entry index within that sector         (0..15)
```

Initial cookie is 0 (sector 0, entry 0). Advancing past the last entry of the last sector returns `ERR_NOMORE`. The compact encoding fits in a single D-register and matches the future `sys_dirent` ABI directly.

**Name conversion (`_DirNameToFat`, `_DirNameFromFat`).** Convert between caller-friendly 8.3 strings (`"FOO.TXT"`, nul-terminated) and the 11-byte space-padded FAT-format names (`"FOO     TXT"`, no terminator). `_DirNameToFat` validates the name, uppercases it, and rejects illegal characters; first-byte `$E5` collisions are rejected (the FAT16 `$05` escape is not implemented in Phase 16). `_DirNameFromFat` is purely a re-formatter and never fails.

**Iteration (`_DirOpen`, `_DirRewind`, `_DirNext`, `_DirNextRaw`).** `_DirOpen` initialises a cookie to 0 (and verifies the slot is mounted). `_DirRewind` is identical without the mount check. `_DirNext` advances the cookie and returns the next *visible* entry, silently skipping deleted (`$E5`), LFN (`attr=$0F`), and volume-label (`attr` bit 3) entries; iteration stops on the first `$00` first-byte sentinel with `ERR_NOMORE`. `_DirNextRaw` returns every slot regardless of filter and is used by create/delete which need to see deleted slots.

**Lookup (`_DirLookup`).** Walks the root sector by sector, scanning 16 entries per sector in place in `FS_BUF_SECTOR`. Stops on the `$00` sentinel (returns `ERR_NOTFOUND`) or on the first byte-for-byte name match (returns `C=0` with the cookie pointing at the match, plus the matching sector left in `FS_BUF_SECTOR` for callers like `_DirDelete` to reuse without a re-read).

**Create (`_DirCreate`).** First-fit slot scan: claims the first slot whose first byte is `$E5` (deleted) or `$00` (never used). Caller is responsible for duplicate-name detection (call `_DirLookup` first if uniqueness is required). Writes a fresh 32-byte entry with the supplied attr, first-cluster, and size; populates the time/date fields from `_GetDate` / `_GetTime` (currently RTC stubs returning baked constants); RMW-writes the modified sector back. Returns `ERR_NOSPACE` if the directory is full.

**Delete (`_DirDelete`).** Calls `_DirLookup`, patches the first byte of the matched entry to `$E5` in the buffer, RMW-writes the sector back. Caller is responsible for freeing any cluster chain *before* calling `_DirDelete` (walk the FAT via `_FATGetEntry` and call `_FreeCluster` on each cluster). `_DirDelete` does not touch the FAT.

**Time / date stubs (`_GetDate`, `_GetTime`).** Phase 16 has no RTC; `_GetDate` returns a baked constant (currently `$5CA6` = 6 May 2026 packed in FAT16 date format), `_GetTime` returns 0. When an RTC arrives (Phase 17+), only these two routines change — every caller passes the result through unmodified.

**Phase 16 limitations:**

- Root directory only — no subdirectory traversal.
- LFN entries silently skipped (visible to `_DirNextRaw` but not iterated as a unit).
- Volume-label entries silently skipped.
- No RTC; all created entries get the same date stamp.

---

## 6. The k/OS volume table

Each mounted volume has a kernel-side descriptor in page `$00`, holding the cached BPB fields and backend function pointers. The table lives at `$0260..$031F` (newly reserved, packed immediately after `BT_NAME` which ends at `$025F`):

```
offset  size  field
$00     1 B   present (1 = mounted, 0 = empty)
$01     1 B   read-only flag (cached from BPB+1 byte 25)
$02     2 B   bytes per sector
$04     1 B   sectors per cluster
$05     1 B   reserved
$06     2 B   reserved sectors
$08     2 B   FAT start sector
$0A     2 B   sectors per FAT
$0C     2 B   root dir start sector
$0E     2 B   root dir entry count
$10     2 B   data start sector (= root + (root_entries*32 + 511)/512)
$12     4 B   total sectors
$16     4 B   total clusters (computed)
$1A     4 B   _BlockRead handler address (24-bit, padded)
$1E     4 B   _BlockWrite handler address (24-bit, padded; 0 if read-only)
$22     11 B  volume label (cached)
$2D     3 B   reserved
$30     16 B  reserved/scratch
                                                    total: 64 bytes
```

Two volume slots are reserved at `$0260..$029F` (for `A:`) and `$02A0..$02DF` (for `B:`). Slot at `$02E0..$031F` is reserved for future `C:`.

Volume identity is encoded in the slot index: `A:` is slot 0, `B:` is slot 1, etc. There is no notion of "default drive" in Phase 16 -- every path has an explicit drive prefix.

---

## 7. Per-task file descriptors

Each task has a private fd table in its task-local page-zero region.

### 7.1 Page-zero allocation update

Phase 16 reserves new task-local slots beyond what Phase 15 used:

| Offset | Symbol | Purpose |
|---|---|---|
| `$0000` | `MY_TCB_PTR` | TCB low word (set by `_BuildTask`) |
| `$0004` | `TASK_ID` | TCB ID (1..62) |
| `$0006` | `TLS_ERRNO` | Reserved |
| `$0008` | `TLS_FLAGS` | Reserved |
| `$000A` | `TLS_SCRATCH0` | Syscall scratch |
| `$000C..$006B` | `FD_TABLE` | 8 fd entries x 12 bytes = 96 bytes |
| `$006C..$01FF` | (free for future TLS use) | -- |

### 7.2 File descriptor entry layout

Each fd entry is 12 bytes:

```
offset  size  field
$00     1 B   flags (bit 0 = open, bit 1 = read, bit 2 = write,
                   bit 3 = dirty, bit 7 = ROM (read-only))
$01     1 B   drive (0 = A:, 1 = B:)
$02     2 B   first cluster of file
$04     2 B   current cluster (cached for sequential reads)
$06     2 B   reserved
$08     4 B   current byte position within file
                                                    total: 12 bytes
```

The 4-byte position field holds the absolute byte offset into the file (0..size). To convert this to a cluster-and-offset pair, the read/write code walks the cluster chain from `first_cluster`, counting clusters skipped, until it finds the cluster containing the current position. The `current_cluster` field caches the result for sequential reads, so a typical read advances by one cluster only when crossing a boundary.

For Phase 16 this is acceptable -- cluster chains are short (under 100 clusters even for the largest expected files), and most reads/writes are sequential. Random-access seeks pay one chain walk per seek.

### 7.3 fd lifetime

- fd 0..7 are private to each task. fd values are reused freely.
- fds **do not survive `sys_exec`**. The child task starts with all fds closed. This is deliberate; Phase 16 intentionally does not inherit fds. Phase 18+ may revisit when pipes and redirection are added.
- Closing a task (via `sys_exit` or kill) auto-closes all its fds.
- There is no global open-file table. Each task tracks its own fds independently. If two tasks open the same file, both see independent positions; their writes can race. Phase 16 has no file locking.

---

## 8. Path syntax

A path consists of a drive letter, colon, and 8.3 filename:

```
A:FORTH.COM
B:NOTES.TXT
```

Whitespace and lower-case are accepted on input and folded to upper-case for lookup. **The kernel requires the drive letter** -- there is no current-directory or default-drive notion at the syscall layer. The kernel sees fully-qualified paths only.

Subdirectories are not parsed in Phase 16; if a path contains a `\` separator, `sys_open` returns `ERR_BADPATH`.

Maximum path length: **15 bytes** (`X:NNNNNNNN.EEE` is 14 chars). Implementations should treat anything longer as an error.

### 8.1 kosh current working drive (CWD, Part 25 r4)

The kernel's path-syntax rule is strict, but the kosh shell adds a **current working drive** convenience for the user. The CWD is a single drive letter (`B` at boot, settable to any mounted drive). Paths typed without a `X:` prefix are normalised to `<CWD>:<rest>` by kosh's `_KoshNormPath` helper before being passed to the kernel.

```
B:$ cat NOTES.TXT             # → kernel sees "B:NOTES.TXT"
B:$ C:                        # switch CWD to C:
C:$ cat README.TXT            # → kernel sees "C:README.TXT"
C:$ cat B:NOTES.TXT           # explicit prefix wins; kernel sees "B:NOTES.TXT"
```

The CWD is **purely a kosh feature** — the kernel still rejects bare filenames with `ERR_BADPATH`. Other user programs that want similar behaviour must implement their own path normalisation. A future kernel-side convention (or even subdir / chdir support in Phase 17) may absorb this, but for now CWD lives in kosh and only kosh.

Drive-letter switching uses bare-letter syntax: typing `C:` (with no other arguments) at the prompt switches CWD to `C:` if mounted, or reports `kosh: C: not mounted` otherwise.

---

## 9. Syscall reference

Phase 16 added six TRAPs (26..31) to the existing syscall surface; Phase 19 added TRAP #32 (`sys_format`); Part 25 r2 added TRAP #37 (`sys_unlink`) and TRAP #38 (`sys_rename`). TRAPs 33..36 are semaphore syscalls (Part 20b) — not filesystem-related but worth knowing they occupy that range.

**Register preservation (V2 ABI).** Every FS syscall preserves D2, D3, and XY2 across the TRAP boundary, per the k/OS Reference Manual §5 ABI rule. D0 carries the result, D1 is scratch, XY0 / XY1 carry pointer arguments. This was made explicit and audited on 8 May 2026 (Part 20a) — `sys_format` (`kos_fs.asm` r4) and `sys_exec` (`kos_fs_exec.asm` r3) had previously documented D2/D3/XY2 as clobbered; both now save and restore correctly. See `Syscall_ABI_Audit_2026-05-08.md` and K16 ISA Gotcha #31 for the audit trail.

**Leaf vs non-leaf syscalls.** The FS syscalls are mostly *non-leaf* — they take the standard non-leaf TRAP shape (`PUSH SR / DINT / body / RTI`) because they may call `_Schedule` (during semaphore waits, IO completion polls, etc.) or hold the disk mutex across an operation. Non-leaf is the safer default; gotcha 4.28 documents the timer-IRQ-during-scheduler-hand-off corruption that the non-leaf shape prevents. Each syscall heading below tags it `[LEAF]` or `[NON-LEAF]`.

### 9.0 Buffer-pointer ABI for syscalls that accept user data

Every Phase 16 syscall that takes or returns a user buffer (`sys_read`, `sys_write`, `sys_open` for the path string, `sys_dirent` for the DIRENT_INFO destination) addresses that buffer through the caller-supplied 24-bit pointer in `Y0` (high byte = page) and `X0` (low word = offset). The kernel stashes both bytes verbatim at TRAP entry and uses them for all subsequent byte/word access.

**Calling convention from a user task:**

```asm
                MOVE    Y0, Y3                  ; high byte = MY task page
                LOADI   X0, #MY_BUFFER          ; low word = offset
                LOADI   D1, #count
                TRAP    #TRAP_READ              ; (or WRITE / OPEN / DIRENT)
```

`Y3` holds the running task's page byte by k/OS convention (see Reference Manual §9.5 / Appendix B.6). Using `MOVE Y0, Y3` is the canonical way to pass "a pointer in my page". **`LOADI Y0, #$00` does not mean "my page" — it means literal kernel page** and will read from / write to the kernel's data structures. This is a frequent novice mistake; gotcha 4.18 in `kOS_Gotchas` v1.5 documents the failure modes.

**User-page memory map (Phase 16):**

| Offset | Size | Use |
|---|---|---|
| `$0000..$00FF` | 256 B | Page-zero per-task slots: MY_TCB_PTR, TASK_ID, FD_TABLE (`$000C..$006B`), TLS scratch |
| `$0100..$01FF` | 256 B | Reserved / unused |
| `$0200..` | varies | User task code body (copied here by `_BuildTask`) |
| `..$FFEC` | tail | Free for stack-/heap-style use |
| `$FFEE..$FFFE` | ~16 B | User stack base (X3 = $FFEE at task entry; grows down) |

The safe area for user buffers is roughly `$E000..$FEFF` — well above any plausible code body, well below the stack. Smaller buffers (under ~256 bytes) can sit lower (e.g. `$0900..$0DFF`) if the task's code is known to be small. **Do not place buffers below `$0900`** — that range collides with TCB slots if accessed via `Y0=#$00`, and with FD_TABLE / TCB pointers in user_page.

The kernel's syscall handlers do not validate that the supplied buffer falls within the caller's task page. A caller passing `Y0=$00` will succeed at the TRAP boundary and silently corrupt kernel data. There is no MMU; addressing is by convention.

### 9.1 sys_open -- TRAP #26 [NON-LEAF]

Open a file by path. Returns a file descriptor.

```
In:       XY0      pointer to nul-terminated path string ("A:NAME.EXT")
          D0       open flags
                     bit 0 = read
                     bit 1 = write
                     bit 2 = create (create if not present)
                     bit 3 = truncate (truncate to zero on open)
                     bit 4 = append (seek to end on open)
Out:      D0       fd (0..7) on success
          C = 0    success
          C = 1    failure
                     D0 = ERR_BADPATH    malformed path
                     D0 = ERR_NOTFOUND   file not found, create not specified
                     D0 = ERR_EXISTS     create+excl set, file exists
                                         (excl is bit 5 of D0; reserved)
                     D0 = ERR_NOFD       per-task fd table full
                     D0 = ERR_READONLY   write requested on read-only volume
                     D0 = ERR_NOMEM      directory or FAT couldn't be read
                     D0 = ERR_NOSPACE    create requested, no free clusters
```

### 9.2 sys_close -- TRAP #27 [NON-LEAF]

Close a file descriptor and flush any pending metadata.

```
In:       D0       fd
Out:      C = 0    success
          C = 1    failure
                     D0 = ERR_BADFD      not an open fd
```

### 9.3 sys_read -- TRAP #28 [NON-LEAF]

Read up to `count` bytes from the file's current position into the supplied buffer.

```
In:       D0       fd
          D1       count (max bytes to read)
          XY0      destination buffer (in caller's task page)
Out:      D0       bytes actually read (may be < count at EOF)
          C = 0    success (D0 = 0 means EOF)
          C = 1    failure
                     D0 = ERR_BADFD      not an open fd, or fd not readable
                     D0 = ERR_IO         block-layer read failed
```

The buffer must lie in the caller's task page (offset `$0200..$FFEF`). The read advances the fd's position by the number of bytes read.

### 9.4 sys_write -- TRAP #29 [NON-LEAF]

Write up to `count` bytes from the supplied buffer to the file at the current position.

```
In:       D0       fd
          D1       count (max bytes to write)
          XY0      source buffer (in caller's task page)
Out:      D0       bytes actually written (may be < count if disk full)
          C = 0    success
          C = 1    failure
                     D0 = ERR_BADFD      not an open fd, or fd not writable
                     D0 = ERR_READONLY   volume is read-only
                     D0 = ERR_NOSPACE    out of clusters mid-write
                     D0 = ERR_IO         block-layer write failed
```

Writes may extend the file; new clusters are allocated as needed. The directory entry's size and last-cluster pointer are updated; the dirty flag is set so a later `sys_close` flushes them.

### 9.5 sys_dirent -- TRAP #30 [NON-LEAF]

Iterate a volume's directory.

```
In:       D0       drive (0 = A:, 1 = B:)
          D1       index (0-based; 0 = first entry, increment to walk)
          XY0      destination buffer for one DIRENT_INFO struct (32 bytes)
Out:      D0       (unchanged on success)
          C = 0    entry copied; valid until next call
          C = 1    failure
                     D0 = ERR_NOMORE     index past last used entry
                     D0 = ERR_BADDRIVE   no volume in slot
                     D0 = ERR_IO         block-layer read failed
```

The `DIRENT_INFO` returned to the caller is a sanitised, fixed-format view -- not the raw 32-byte FAT entry:

```
offset  size  field
$00     12 B  name as displayed ("NAME.EXT" with dot, nul-padded)
$0C     1 B   attributes (FAT16 attribute byte, masked of LFN sentinel)
$0D     1 B   reserved
$0E     2 B   first cluster
$10     4 B   size in bytes
$14     2 B   modification date (FAT16 packed; 0 if unknown)
$16     2 B   modification time (FAT16 packed; 0 if unknown)
$18     8 B   reserved
                                                    total: 32 bytes
```

The caller iterates by incrementing `D1` until `ERR_NOMORE`. Deleted entries (first byte `$E5`) are skipped automatically. LFN entries (attr `$0F`) are skipped. The volume label entry (attr `$08`) is also skipped -- it is not a file.

### 9.6 sys_exec -- TRAP #31 [NON-LEAF]

Load an executable file and spawn it as a new task. Optionally block until the child exits.

```
In:       XY0      pointer to path ("A:FORTH.COM")
          D0       flags
                     bit 0 = block (wait for child to exit)
                     bit 1 = inherit_stdio (reserved, Phase 18+)
Out:      D0       (block=1) child's exit code
                   (block=0) child's TID
          C = 0    success
          C = 1    failure
                     D0 = ERR_BADPATH    malformed path
                     D0 = ERR_NOTFOUND   file not found
                     D0 = ERR_NOTEXEC    file too small/no exec attribute
                     D0 = ERR_NOMEM      no free user page
                     D0 = ERR_NOSLOTS    TCB pool full
                     D0 = ERR_TOOBIG     file larger than `SPAWN_MAX_LEN`
                     D0 = ERR_IO         block-layer read failed
```

Implementation:

1. Open the file (internally; no fd consumed).
2. Verify file size > 0 and ≤ `SPAWN_MAX_LEN` ($FE00).
3. Verify the filename extension is `.COM` (the k/OS executable extension; see notes below).
4. Allocate a fresh user page via `_AllocPage`.
5. Walk the cluster chain, copying each cluster into the new page starting at offset `SPAWN_ENTRY_OFFSET = $0200`.
6. Set up the new task's name from the file's base name (uppercased, nul-padded).
7. Call `_BuildTask` to create the TCB and link the task into the ready queue.
8. If `block=1`: call internal `_WaitForTask`, return child's exit code in D0. If `block=0`: return child's TID immediately.

**On the `.COM` extension as executable marker.** FAT16 has no native "executable" attribute, and Windows itself uses the filename extension to identify executables (not any attribute bit). k/OS follows the same convention: files with extension `.COM` are exec-eligible; all other extensions are rejected by `sys_exec` with `ERR_NOTEXEC`. The read-only attribute is reserved for its proper purpose -- protecting files from being written -- and has no bearing on exec-ability.

Two consequences:

- A user can save data files like `NOTES.TXT` or `DATA.BIN` next to executables without those files being mistaken for programs.
- A `.COM` file copied from a Windows machine, even one that Windows has marked read-only, will be exec-eligible on k/OS. This is the desired behaviour.

`.EXE` is reserved for future use but not currently recognised as executable. k/OS does not parse PE or MZ headers; `.COM` files are treated as raw binary images loaded at offset `$0200` of a fresh task page, exactly like `sys_spawn`.

---

### 9.7 sys_format -- TRAP #32 [NON-LEAF]

Reformat a writable volume. Wipes the disk, writes a fresh BPB + FAT + empty root directory, sets the volume label, and re-mounts. Destructive and irreversible.

```
In:       D0       drive (1 = B: only; 0 = A: rejected)
          XY0      pointer to 11-byte volume label (space-padded,
                   uppercase ASCII)
Out:      C = 0    success, volume re-mounted with new label
          C = 1    failure
                     D0 = ERR_READONLY    formatting A: is forbidden
                     D0 = ERR_BADDRIVE    drive out of range
                     D0 = ERR_IO          block-layer write failed
```

Implementation: dispatches via VEC_FORMAT ($0080) to internal `_FormatVolume`. The format procedure is described in §10.2.

The shell `format` command performs no `[y/N]` confirmation as of Phase 19 — kosh prompts inline ("Formatting B: ... OK"). Callers wanting confirmation must implement it themselves.

---

### 9.8 sys_unlink -- TRAP #37 [NON-LEAF]

Delete a file. Releases the directory entry (writes the `$E5` deleted marker), frees the cluster chain. Does not zero file contents — the clusters are freed by FAT update only.

```
In:       XY0      pointer to nul-terminated path string ("B:OLD.TXT")
Out:      C = 0    success, file removed
          C = 1    failure
                     D0 = ERR_BADPATH    malformed path
                     D0 = ERR_NOTFOUND   file not found
                     D0 = ERR_READONLY   target volume is read-only (A:)
                     D0 = ERR_BUSY       file currently open in any fd table
                     D0 = ERR_IO         block-layer read or write failed
```

Implementation: dispatches via VEC_UNLINK ($0094) to `kos_fs_fd.asm` r7's `sys_unlink` body. The procedure is:

1. Validate path → drive + 11-byte FAT name.
2. Check target volume is writable; reject A: with `ERR_READONLY`.
3. Walk root directory to find the entry. `ERR_NOTFOUND` if absent.
4. Cross-check all FD tables (current and other tasks) for any open fd referencing this file's first cluster. `ERR_BUSY` if any match — better than letting an open fd dangle on freed clusters.
5. Read the cluster chain head from the dirent.
6. Mark the dirent deleted: write `$E5` at byte 0 of the entry, write the entire 32-byte dirent back, increment dir's first-cluster sector.
7. Call `_FATFreeChain(first_cluster)` to walk the chain and set each FAT entry to `$0000` (free).
8. Block-layer flush implicit on next IO.

Note: there is no recycle bin or undelete. The `$E5` marker can be salvaged in principle if no further allocations have reused the dirent slot, but k/OS provides no API for that. Treat unlink as permanent.

---

### 9.9 sys_rename -- TRAP #38 [NON-LEAF]

Rename a file within the same volume. Does not move files across volumes — that's a kosh-side `mv` synthesis (`cp` + `unlink`).

```
In:       XY0      pointer to source path ("B:OLD.TXT")
          XY1      pointer to destination path ("B:NEW.TXT")
Out:      C = 0    success, dirent renamed in place
          C = 1    failure
                     D0 = ERR_BADPATH    malformed source or dest
                     D0 = ERR_NOTFOUND   source not found
                     D0 = ERR_EXISTS     destination exists
                     D0 = ERR_READONLY   target volume is read-only (A:)
                     D0 = ERR_BUSY       source currently open in any fd table
                     D0 = ERR_INVALID    source and dest on different drives
                     D0 = ERR_IO         block-layer read or write failed
```

Implementation: dispatches via VEC_RENAME ($0098) to `kos_fs_fd.asm` r7's `sys_rename` body.

1. Parse both paths. Both must contain the same drive letter — `ERR_INVALID` if not. (Cross-volume rename is meaningless on FAT16; kosh's `mv` handles that by copying and unlinking.)
2. Validate writability; reject A:.
3. Walk root dir to find source. `ERR_NOTFOUND` if absent.
4. Walk root dir to verify destination is unused. `ERR_EXISTS` if present.
5. Cross-check FD tables for open source. `ERR_BUSY` if any match.
6. Update the source dirent in place: overwrite bytes 0..10 (the 11-byte FAT name) with the destination's name. Write the modified dirent back.
7. Cluster chain unchanged. The file's content stays where it was; only the name field is rewritten.

This is the cheapest possible rename — one dirent slot is modified, one block writeback. Compare with `mv` across drives, which is a full content copy.

`sys_rename` uses an internal `FD_NAMEBUF2` scratch slot (at `$04CC` in page $00) to hold the second 11-byte FAT name while parsing. The first name reuses the existing `FD_NAMEBUF` slot.

---

## 10. Mount and format procedures

### 10.1 Boot-time mount

`_InitFS` runs after `_InitKernel` but before user tasks start. For each volume slot:

1. Call the slot's `_BlockRead` to read sector 0 into a kernel buffer.
2. Verify the signature `$AA55` at offset `$1FE`.
3. Verify the FAT type label (`"FAT16   "` at offset `$036`).
4. Cache BPB fields into the volume table slot.
5. Mark slot as `present = 1`.

A slot that fails any check is left `present = 0`. Subsequent syscalls on that drive return `ERR_BADDRIVE`.

The ROM disk (`A:`) is built into the k/OS ROM at compile time. It occupies ROM pages `$FC..$FD` -- a 128 KB region within the K16 program-code ROM (`$FC..$FE`); kernel code occupies the remaining single page `$FE`, and boot/reset sits in `$FF`. The ROM disk is 256 sectors total, with ~125 KB usable for files (251 clusters of 512 B). Authoring is described in §10.4 below; the short version is that the image is produced under EMU using the existing host-disk backend (as a `.KOS` file in the disk folder) and then baked into the program ROM by the K16 assembler IDE at "Generate ROMs" time.

The RAM disk (`B:`) starts at the chosen RAM-disk pages on first boot. On a fresh power-up, RAM contents are undefined; `_InitFS` will detect this (no valid signature) and leave `B:` unmounted.

**As of Phase 16.7, kosh's `_P2Main` auto-formats B: at boot if it is not mounted.** The user no longer needs to run `format B:` on first boot — kosh formats it with label `KOS-RAM    ` and remounts before the shell starts. (When EMU save/load lands in Phase 16.8, persisted RAM disks will already be mounted on second and subsequent boots; the auto-format only fires when needed.)

### 10.2 sys_format procedure

As of Phase 19, `sys_format` is exposed as TRAP #32 (see §9.7). Internally it dispatches to `_FormatVolume` via VEC_FORMAT.

Format procedure:

1. Build a fresh boot sector with the BPB filled in for the target volume size.
2. Write the volume label into the BPB and into a volume-label entry in the (otherwise empty) root directory.
3. Zero the FAT region; write `FAT[0] = $FFF8` and `FAT[1] = $FFFF`.
4. Zero the root directory.
5. Write all sectors via `_BlockWrite`.
6. Re-run `_InitFS` to mount the now-valid volume.

Format is destructive and irreversible. The kosh `format` command does not currently prompt for confirmation; callers wanting confirmation must implement it themselves.

**Phase 19 disk-populate convention.** kosh's task body, after auto-format on boot, populates B: with two reference files (`HELLO.COM`, `NOTES.TXT`) drawn from kernel-side ROM data. The populate is idempotent — it tries `sys_open(path, FOPEN_READ)` first and skips creation if the file already exists. Subsequent `format B:` operations wipe these files; they reappear on next boot.

This is a Phase 19 testing-aid shim. It is expected to be removed once kosh has a working `cp` command (Phase 20+) and EMU save/load lands (Phase 16.8) — at that point users can populate B: interactively or via persisted disk images.

### 10.3 EMU host save / load (development convenience)

On EMU only, the K16EmuIDE provides "Save RAM disk" and "Load RAM disk" menu commands:

- **Save**: Dumps the RAM-disk pages to a host (Windows) file. The output is a byte-for-byte copy of the FAT16 image. Resulting file can be mounted directly in Windows or inspected with hex tools.
- **Load**: Reads a host file into the RAM-disk pages. The file size must match exactly. After loading, k/OS re-runs `_InitFS` to remount the volume.

These are EMU-only debug features. They are not part of the OS API and are not present on Digital or FPGA targets. They use no syscalls -- they manipulate emulator memory directly.

### 10.4 ROM disk authoring (Part 26)

The ROM disk image is produced under EMU using the existing host-disk backend, then baked into the program ROM by the K16 assembler IDE at "Generate ROMs" time. Both stages consume the same `.KOS` file; the bytes that land on Digital are bit-identical to the bytes the EMU sees through `_BlockReadROM`.

**Authoring workflow.** Under EMU, bind the ROM disk image to a host-disk bay (typically `E:`) and use kosh to populate it:

```
mkdisk ROMDISK.KOS 256          ; one-off, creates 128 KB blank image
mount E: ROMDISK.KOS            ; bind to bay
format E: ROMDISK               ; FAT16 format with label
load FORTH30.COM                ; ingest .COM from LoadPath
cp FORTH30.COM E:FORTH30.COM    ; copy into the ROM-disk image
load BASIC25.COM
cp BASIC25.COM E:BASIC25.COM
run E:FORTH30.COM               ; sanity-check it actually executes
```

The image is now a populated FAT16 disk on the Windows filesystem at `<DiskPath>/ROMDISK.KOS`. Because it's a real .KOS file, the same image can be mounted on any modern OS for inspection.

**EMU preload of A: from the .KOS image.** On EMU startup the disk-controller layer reads `[Disks] A=ROMDISK.KOS` from the K16EmuIDE INI and, if present, slurps the file into RAM at `$FC0000..$FDFFFF` (pages `$FC..$FD`) before the CPU starts. k/OS's existing `_BlockReadROM` then mounts A: from those bytes via `_InitFS` -- the same code path Digital uses. The file must be exactly 131072 bytes; missing or wrong-size files log a warning and leave A: unmounted, matching Digital behaviour for an unprogrammed ROM region. The same preload runs on every Reset (via `LoadAndReset`) so ROM contents are persistent across reset, matching Digital semantics.

**Dedupe rule.** If `[Disks] A=` and any of `[Disks] C=..F=` point at the same canonical file, the host-disk bay is silently skipped at startup. This lets the user leave both `A=ROMDISK.KOS` and (say) `E=ROMDISK.KOS` in the INI permanently -- A: gets the bytes via the preload path; E: would otherwise double-bind the same file as a R/W host bay and cause writes to diverge from the bytes k/OS sees through `_BlockReadROM`.

**Assembler ROM overlay.** The K16 assembler IDE has a "k/OS ROM Drive file:" field on the Settings tab, persisted to its own INI as `[ROMDrive] File=`. At "Generate ROMs" time, if that field is non-empty, `GenerateROMs` (in `K16_Export.pas`) validates the file (must exist, must be exactly 131072 bytes, must lie at or above the program `BaseAddr`), grows the in-memory ROM image to cover `$FC0000..$FDFFFF` if program code didn't reach that far, and `Move`s the 131072 bytes into offset `(ROMDISK_BASE - BaseAddr)` of the ROM image. The existing `SplitHighLow` + Digital raw v2 output flow then handles the high/low ROM file split with no special-case logic.

A stats line is emitted on success:

```
ROM disk: ROMDISK.KOS (256 sectors) at $FC0000
```

A warning is emitted when no ROM disk is specified:

```
Warning: No ROM disk file specified — A: will be unmounted on Digital
```

**Round-trip authoring loop.** Once both halves are wired up the iterative loop is:

1. Under EMU, mount the ROM-disk file as E:, edit contents with kosh (`cp`, `rm`, etc.)
2. Generate ROMs in the K16 assembler IDE -- it consumes the same `.KOS` file, bakes it into pages `$FC..$FD` of the Digital ROM output
3. Reload Digital from the new `ProgramHIGH.hex` / `ProgramLOW.hex`
4. A: now contains the updated files, read-only on Digital

Validated end-to-end on 27 May 2026: Forth v3.0 (~6 KB) and BASIC v2.5 (~10 KB) both run from A: on Digital with multitasking confirmed via `ps`. The same .KOS image gives identical `vol` / `ls` output on EMU and Digital.

---

## 11. Block layer ABI

The block layer is the swappable abstraction that keeps the FAT16 code agnostic of where the bytes physically live.

### 11.1 _BlockRead

```
In:       D0       sector number (0-based, within the volume)
          XY0      destination buffer (must hold 512 bytes)
Out:      C = 0    success
          C = 1    failure
                     D0 = ERR_IO    backend reported a read failure
```

For RAM disk: copies 512 bytes from `pages[ramdisk_base + sector/128]:[(sector%128)*512]` to `XY0`. For ROM disk: similar, but reads from ROM pages. For SD: issues SD-card read-block commands over SPI (Phase 17+).

### 11.2 _BlockWrite

```
In:       D0       sector number
          XY0      source buffer (must hold 512 bytes)
Out:      C = 0    success
          C = 1    failure
                     D0 = ERR_IO        backend reported a write failure
                     D0 = ERR_READONLY  ROM disk; never accepts writes
```

For RAM disk: copies 512 bytes from `XY0` to `pages[ramdisk_base + sector/128]:[(sector%128)*512]`. For ROM disk: returns `ERR_READONLY` immediately. For SD: SD-card write-block (Phase 17+).

### 11.3 Backend dispatch

Each volume slot in the volume table holds a 24-bit `_BlockRead` and `_BlockWrite` function pointer. The FAT16 layer never calls `_BlockRead` directly -- it calls through the per-volume function pointer. This is what makes the storage backend swappable: the FAT16 code works against any combination of RAM, ROM, or SD volumes.

In implementation (Phase 16), the FAT layer calls helper wrappers `_VolBlockRead` and `_VolBlockWrite` (in `kos_fs.asm`) that take the volume slot pointer in `XY2` and dispatch through the slot's function pointer via `CALLXY`. The actual backend functions are named `_BlockReadRAM` / `_BlockWriteRAM` (in `kos_fs_ram.asm`) and `_BlockReadROM` (in `kos_fs_rom.asm`; ROM disk has no write). `_VolBlockWrite` returns `ERR_READONLY` immediately if the slot's write pointer is null, before any dispatch.

### 11.4 Host-disk backend (Part 22)

`kos_fs_host.asm` provides `_BlockReadHost` and `_BlockWriteHost`, which serve drives `C:..F:` from real files on the host filesystem via the K16 disk controller (MMIO at `$DA0000..$DA001F`). This backend is EMU-only — on Digital the controller doesn't exist, and `_InitFS` skips the probe.

Per Part 20b, the backend protects its critical section (the DSK_DRIVE / DSK_LBA / DSK_BUF / DSK_CMD register sequence) with a counting semaphore held in `HOST_DISK_SEM`. The semaphore is created at boot by `_InitHostDisk` with initial count = 1 (binary mutex), acquired via `_SemTakeBlocking` and released via `_SemGive`. Today, all FS operations run with the kernel-side scheduler quiescent (DINT during syscalls), so the slow path of `_SemTakeBlocking` has never been exercised; it is in place for future multi-task use.

Bay derivation: each call computes the bay number as `(VOL_SLOT_x - VOL_SLOT_C) >> 6` from the per-volume slot pointer in `XY2`. So slot C: → bay 0, D: → bay 1, etc. The bay is written to `DSK_DRIVE` before each command.

### 11.5 Host-disk management (Parts 23 + 24 + 25)

`kos_fs_host_mgr.asm` provides a kernel-side wrapper layer over the host-disk controller's *management* commands. Where §11.4 covers per-sector data flow, §11.5 covers the controller's catalogue layer.

**Why a separate file.** §11.4 is small and synchronous (program registers, trigger, read result). The management ops have a more elaborate ABI — most take a name pointer, some return a buffer of variable-length data, all need the disk mutex — so they live separately. `_BlockRead/WriteHost` make no assumption about pool state; the management layer can be replaced or extended without touching the data path.

**API.** Eight entry points; all take the disk mutex, all check `KOS_HOST = HOST_EMU` and return `ERR_INVALID` on Digital.

| Helper | Part | In | Out |
|---|---|---|---|
| `_HostMount` | 23 | `XY0` = ASCIIZ basename, `D0` = bay (0..3) | C=0/`ERR_OK` or C=1/`ERR_IO`/`ERR_INVALID` |
| `_HostUnmount` | 23 | `D0` = bay (0..3) | C=0/`ERR_OK` or C=1/`ERR_IO`/`ERR_INVALID` |
| `_HostList` | 23 | `XY0` = output buffer (≥256 B) | Buffer filled `name\0bay\0\0name\0bay\0\0...\0`; bay = $FF if not mounted |
| `_HostCreate` | 23 | `XY0` = ASCIIZ basename, `D0` = sector count | Creates `disk\<name>.KOS` zero-filled |
| `_HostDelete` | 23 | `XY0` = ASCIIZ basename | Refuses if mounted |
| `_HostRename` | 24 | `D0` = bay, `XY0` = new ASCIIZ basename | Renames bay's bound file, keeps mount intact |
| `_HostBayName` | 24 | `D0` = bay, `XY0` = ≥16 B output buffer | Writes ASCIIZ basename (no `.KOS`) of bay's file |
| `_HostFOpen` | 25 r6 | `XY0` = ASCIIZ filename in `load/` | C=0/D0 = file size in bytes |
| `_HostFRead` | 25 r6 | `XY0` = k16 dest buffer, `D0` = max bytes | C=0/D0 = bytes read (0 = EOF) |
| `_HostFClose` | 25 r6 | (no inputs) | C=0/D0 = ERR_OK |

(That's actually 10 entry points now; pluralisation lagged the additions.)

The basename for `_HostMount`/`_HostCreate`/`_HostDelete`/`_HostRename` is *without* extension — the controller appends `.KOS` itself. Names are case-insensitive (uppercased on lookup) and limited to alphanumeric plus underscore, max 15 characters (so the full filename fits in 16 bytes including the nul). `_HostFOpen` is the exception: it accepts the **full filename including extension** (e.g. `HELLO.COM`) and uses it verbatim in the `load/` folder lookup.

**MMIO surface.** Management commands ride the same MMIO range as sector ops, sharing the `DSK_BUF_*` and `DSK_SECCOUNT` and `DSK_DRIVE` registers. The trigger is `DSK_HOST_CMD = $DA0016`. Ten command codes are defined:

| Command | Value | Inputs | Output |
|---|---|---|---|
| `HOST_CMD_MOUNT` | $0001 | BUF=name, DRIVE=bay | RES_* |
| `HOST_CMD_UNMOUNT` | $0002 | DRIVE=bay | RES_* |
| `HOST_CMD_LIST` | $0003 | BUF (≥256 B) | name\0bay\0\0...\0 in BUF; RES_* |
| `HOST_CMD_CREATE` | $0004 | BUF=name, SECCOUNT=sectors | RES_* |
| `HOST_CMD_DELETE` | $0005 | BUF=name | RES_* |
| `HOST_CMD_RENAME` | $0006 | DRIVE=bay, BUF=new name | RES_*; renames bay's bound file |
| `HOST_CMD_BAYNAME` | $0007 | DRIVE=bay, BUF=≥16 B output | basename in BUF; RES_* |
| `HOST_CMD_FOPEN` | $0008 | BUF=ASCIIZ filename | SECCOUNT=file size in bytes; RES_* |
| `HOST_CMD_FREAD` | $0009 | BUF=k16 dest, SECCOUNT=max bytes | SECCOUNT=bytes read; RES_* |
| `HOST_CMD_FCLOSE` | $000A | (none) | RES_* |

Result codes use the existing `RES_*` set (`RES_OK`, `RES_BUSY`, `RES_NOT_FOUND`, `RES_BAD_NAME`, `RES_BAD_SIZE`, `RES_EXISTS`, `RES_FULL`, `RES_IO_ERR`).

**Host directory layout.** The EMU exposes two host folders to k/OS, configured by INI:

| INI key | Default | Purpose |
|---|---|---|
| `[Disks] DiskPath=` | `./disk/` | Where `.KOS` disk images live for mount/unmount/create/delete |
| `[Disks] LoadPath=` | `./load/` | Where loadable host files (e.g. newly-built `.COM` files) live for `_HostFOpen` |

Part 25 r6 renamed the legacy `[Disks] Path=` key to `DiskPath=` for symmetry with the new `LoadPath=`; old INI files using `Path=` are not back-compat (hard rename — kosh will simply default to `./disk/` if neither key is present, which prompts a one-line message in the EMU log at boot).

**HOST_CMD_FOPEN semantics.** The EMU maintains a **singleton** "currently open" file slot. Only one file may be open at a time across the whole controller — `_HostFOpen` returns `RES_BUSY` (which the kernel translates to `ERR_IO`) if a previous open was not closed. 64 KB hard cap on file size: files larger than that are rejected with `RES_FULL`. Path components in the filename (`/`, `\`, `:`, `..`) are rejected with `RES_BAD_NAME` — only basenames in `LoadPath` are permitted.

The streaming model (`FOPEN` → repeated `FREAD` → `FCLOSE`) lets the caller use a small buffer (e.g. kosh's 512-byte `CP_BUF`) rather than allocating a 64 KB buffer in the task page. `_HostFRead` returns 0 bytes at EOF, still with `RES_OK`. Callers loop until they get 0 or an error.

**Important: caller must close on every error path.** Because the EMU's `HostLoadFile` slot is a singleton, an unclosed FOPEN blocks all future `load` commands until reboot. Kosh's `.do_load` has dedicated cleanup paths (`.load_fopen_err`, `.load_create_err`, `.load_fread_err`, `.load_write_err`, `.load_short_write`) — each calls `_HostFClose` before propagating the error.

### 11.6 Two-phase mount semantics (Part 24 design change)

Pre-Part 24, mounting a `.KOS` file with no valid BPB (e.g. a freshly-`mkdisk`'d blank image) succeeded at the bay-bind layer but failed at the FS-mount layer, and the bay was **rolled back to empty** automatically. The user saw an error and the bay was unbound.

Part 24 removed the rollback. The two phases are now independent:

1. **Bay-bind** (`HOST_CMD_MOUNT`): opens the host file, assigns to a bay. Succeeds for any readable file. Reported in `disks` as bound.
2. **FS-mount** (`_TryMount` reads the BPB and populates the volume table). May fail if BPB is invalid or missing. Reported in `vol`.

After a successful bay-bind with a failed FS-mount, the bay shows in `disks` as bound but in `vol` as `(not mounted)`. `format <drive>` is the correct remedy. There is no auto-rollback.

This is intentional and matches the workflow: `mkdisk NEW.KOS 1024` → `mount NEW C:` (binds C:, FS invalid) → `format C: LABEL` (writes BPB and mounts). The previous design would have made step 2 fail and step 3 unreachable.

See gotcha 4.33 in `kOS_Gotchas v1.10`.

**Persistence.** The EMU controller stores per-bay assignments in the same INI file the application uses. Section `[Disks]` holds:

```ini
[Disks]
Path=C:\path\to\disk\folder
C=TEST.KOS
D=
E=
F=
```

`Path=` is the host folder where `.KOS` files live (default `./disk/`). `C/D/E/F=` are the per-bay filenames; empty means "bay starts unmounted". Every successful mount, unmount, create, or delete through `_HostMgr*` updates the INI synchronously. So manual edits to `[Disks]` survive a save, and a clean shutdown leaves the INI in a state that boots back to the same configuration.

**Boot flow.**

```
1. EMU FormCreate → DiskInit → LoadDiskMountsAndMount(iniPath)
   - Parses [Disks] C/D/E/F entries
   - For each non-empty entry, calls HostMount(name, bay)
   - Populates DiskDrives[0..3] with TFileStream handles
2. K16 reset, kos_boot.asm runs
3. _InitFS → _TryMount(C..F) on EMU
   - For each bay with a stream attached, reads sector 0 (BPB),
     populates volume slot
4. Kernel ready; kosh launches with C..F mounted as configured
```

**Design note.** Earlier (Part 22) the controller exposed a *pool* layer — a 16-entry catalogue of all known images, separate from the four bays they could be mounted to. That double-indexing (slot vs bay) was a recurring source of confusion and bugs (see `kOS_Gotchas` 4.27). Part 23 removed it: the host directory IS the catalogue, the four bays are the only state the controller tracks, and the INI just stores their assignments. Result: simpler MMIO, half the assembly code, no class of slot/bay confusion.

**Open issues.**

- *Multi-task FD safety.* `_HostUnmount` does not currently check whether any task has open fds on the bay being released. Single-task kosh today + DINT during syscalls = no real risk, but a future multi-task kernel must scan FD tables and either refuse the unmount or quiesce the fds first.
- *Read-only flag.* The pool layer carried a per-image RO bit; Part 23 dropped it. If we want host-disk read-only support back, the simplest path is a Windows file-attribute check at mount time.
- *Host-disk format.* `_FormatVolume` is hardcoded for FS_DRIVE_B (RAM-disk sizing); host disks created with `_HostCreate` are zero-filled and must be formatted under Windows (or via a future host-aware `format` extension) before they can be mounted.

---

## 12. Shell integration

The following kosh built-in FS-related commands have shipped through Phase 19 and Parts 22 through 25:

| Command | Status | Description |
|---|---|---|
| `vol` | ✅ Phase 16.7 | Print all six volume slots A..F (label, total clusters, RO flag) |
| `ls [drive:]` | ✅ Phase 16.7 (CWD-aware Part 25 r4) | List files on the given drive; default is current working drive |
| `cat <path>` | ✅ Phase 16.7 | Print a file to the terminal; CWD-aware via `_KoshNormPath` |
| `format <drive> [label]` | ✅ Phase 19, host-disk in Part 24 | Format a drive (B..F); optional label, otherwise defaults to host filename for C..F (Part 24 `_HostBayName`) |
| `run <path>` | ✅ Phase 19 | `sys_exec` + `sys_wait`; prints exit code; CWD-aware |
| `disks` | ✅ Part 23 | List `disk\*.KOS`, mark mounted ones with `[on X:]` |
| `mount <name> <drive>` | ✅ Part 23 | Mount `disk\<name>.KOS` on drive C..F |
| `unmount <drive>` | ✅ Part 23 | Unmount drive C..F |
| `mkdisk <name> <sectors>` | ✅ Part 23 | Create `disk\<name>.KOS` (≥64 sectors) |
| `rmdisk <name>` | ✅ Part 23 | Delete `disk\<name>.KOS` (must be unmounted) |
| `rename <drive> <name>` | ✅ Part 24 | Rename mounted drive's host file (no unmount needed) |
| `remount <drive>` | ✅ Part 25 r5 | Reload drive from disk (after external file edits) |
| `cp <src> <dst>` | ✅ Part 25 r1 | Copy a file; cross-drive allowed; refuses if dst exists |
| `rm <path>` | ✅ Part 25 r2 | Delete a file (sys_unlink) |
| `mv <src> <dst>` | ✅ Part 25 r2 | Rename or move file; cross-drive synthesised as cp+unlink |
| `load <name> [-f]` | ✅ Part 25 r6 | Copy host `load/<name>` to current drive (no unmount needed) |
| `B:` `C:` `...` | ✅ Part 25 r4 | Switch current working drive (bare drive-letter line) |
| `text <path>` | ⏳ pending | Read terminal lines into a new file (line `.` ends input) |

Implementation lives across several files:
- `kosh/kosh_cmds_fs.asm` — vol, ls, cat, format, run, cp, rm, mv, load
- `kosh/kosh_cmds_disk.asm` — disks, mount, unmount, mkdisk, rmdisk, rename, remount
- `kosh/kosh_helpers.asm` — `_KoshNormPath` (CWD path normalisation), `_KoshPrintErr` (human-readable error names), `_SlotForDrive` (drive validity check)
- `kosh/kosh.asm` — REPL, command dispatch table, CWD state (`KOSH_CWD` at `$45C0`)

All commands follow the buffer-and-blast formatting pattern (build line in `ROW_BUF`, single `sys_puts` call) per gotcha 4.11.

### 12.1 Path handling: CWD (Part 25 r4)

The kosh shell maintains a **current working drive** in a single byte at `KOSH_CWD = $45C0` of its task page. Default is `'B'`. Switching is via a bare drive-letter line:

```
B:$ C:                     # switches CWD to C: (if mounted)
C:$
C:$ ls                     # → "ls C:"
C:$ B:                     # back to B:
B:$
```

Bare-letter switching invokes `_SlotForDrive` to verify the drive is mounted before updating `KOSH_CWD`; unmounted drives produce `kosh: <letter>: not mounted`.

Path-taking commands normalise their arguments via `_KoshNormPath(XY0 = src, XY1 = dest)`:

- Source already has `X:` prefix → copied verbatim to dest.
- Source is bare → prepended with `<CWD>:` and copied.

Two normalisation buffers exist in the kosh task page (`KOSH_NORM_A` at `$45D0`, `KOSH_NORM_B` at `$45E0`, 16 bytes each) so `cp` and `mv` can hold both source and destination simultaneously.

### 12.2 Human-readable errors (Part 25 r3)

Every error-printing command in kosh now goes through `_KoshPrintErr`, which appends a bracketed name + hex code to the message:

```
cp: cannot create destination [ERR_READONLY $FFE2]
load: cannot open host file [ERR_NOTFOUND $FFE4]
rm: failed [ERR_NOTFOUND $FFE4]
```

The name table (`err_name_table` in `kosh_cmds_fs.asm`) has 21 entries covering all current `ERR_*` codes. Unknown codes fall back to `[ERR_UNKNOWN $XXXX]`.

This replaces the bare numeric output (`cp: cannot create destination $FFE2`) that was used through Phase 19 and Parts 22-24. Strictly a UX improvement; no syscall surface changes.

### 12.3 The `load` workflow (Part 25 r6)

`load <name>` reads a file from the EMU's host-side `load/` folder and writes it as a file on the current drive. This is the IDE→k/OS delivery path for newly-built `.COM` files (or any other host file the user wants to ingest).

```
B:$ load HELLO.COM         # reads load/HELLO.COM → B:HELLO.COM
loaded 156 bytes
B:$ run HELLO.COM
hello world
[exit 0]
```

Internally, kosh calls `_HostFOpen(name)` to open the host file, allocates a destination fd via `sys_open(<CWD>:<name>, WRITE|CREATE|TRUNC)`, then loops reading 512-byte chunks via `_HostFRead(CP_BUF, 512)` and writing them via `sys_write`. On any error path, `_HostFClose` is always called to release the EMU's singleton load-file slot.

The `-f` flag overwrites an existing destination file. Without it, an existing file causes `load: destination exists (use -f to overwrite)` and the command aborts (without consuming the host file).

The host-side disk image (mounted on the current drive) stays mounted throughout — no unmount/remount cycle, no UAC prompt, no ImDisk. This is the workflow that superseded the Part 25 r5 "inject" attempt; see gotcha 7.9 for the cautionary tale.

### 12.4 Boot-time auto-format

The auto-format of B: at boot remains (kernel-side `_P2Main` issues `TRAP_FORMAT` if B: isn't mounted). It's idempotent — harmless if B: is already mounted.

Phase 17 adds at minimum: `mkdir`, `cd`, `rmdir` (subdirectory support). Phase 18 adds LFN support.

---

## 13. Errors added in Phase 16

The following error codes are added to `kos_defs.inc`:

| Constant | Value | Meaning |
|---|---|---|
| `ERR_NOFD` | `$FFE7` | Per-task fd table full |
| `ERR_BADFD` | `$FFE6` | fd is not open |
| `ERR_BADPATH` | `$FFE5` | Path is malformed |
| `ERR_NOTFOUND` | `$FFE4` | File does not exist |
| `ERR_EXISTS` | `$FFE3` | File already exists (create+excl) |
| `ERR_READONLY` | `$FFE2` | Write attempted on read-only volume |
| `ERR_NOSPACE` | `$FFE1` | Disk full |
| `ERR_IO` | `$FFE0` | Block-layer read or write failed |
| `ERR_BADDRIVE` | `$FFDF` | Drive letter not mounted |
| `ERR_NOMORE` | `$FFDE` | Directory iteration ended |
| `ERR_NOTEXEC` | `$FFDD` | sys_exec on non-executable file |

---

## 14. What's not in Phase 16

The format supports these; the implementation does not. Each is a future phase:

- **Subdirectories** (Phase 17). FAT16 directory entries with attribute bit 4 set are subdirectory references. Phase 16 ignores these entries on iteration.
- **Long filenames (LFN)** (Phase 18+). Entries with attribute `$0F` are silently skipped. The format supports them; the directory parser doesn't yet.
- **Multi-task FD safety on unmount** (deferred). `unmount` and `rmdisk` don't scan FD tables; harmless under single-task kosh, must be added before multi-task scenarios. `sys_unlink` and `sys_rename` (Part 25 r2) *do* scan FD tables and refuse if the file is open.
- **Pipes and I/O redirection** (Phase 18+). fd 0/1/2 are not yet wired to console; `sys_putchar` etc. still go directly to the terminal.
- **File locking** (deferred indefinitely). No multi-task write coordination beyond "last writer wins".
- **chmod / chown / permissions** (Phase 17+). No user model yet.
- **Real-time clock support** (whenever hardware permits). All time fields are zero.
- **Kernel-level CWD or volume-name paths.** The CWD model (Part 25 r4) lives entirely in kosh; the kernel still requires `X:NAME` paths. Volume-name syntax (`/USERDATA/NOTES.TXT`) is deferred to Phase 17 alongside subdirectory work — see gotcha 7.10.
- **`save` command** (kosh → host `load/` folder). The complement of `load`. Would require a new `HOST_CMD_FWRITE` MMIO surface or similar. Deferred until there's a clear use case.

**No longer applicable** (resolved since v1.12):
- ~~Host-disk format~~ — `format <C..F> [label]` now works (Part 24). The optional label, when omitted, defaults to the host filename via `_HostBayName`.

---

## 15. Boot-time program selection

The kernel itself boots from ROM at the K16 reset vector (`$FF0000`). It is not loaded from a filesystem and does not rely on a "bootable volume" mechanism. Instead, k/OS uses a CP/M-style convention: after the kernel has initialised and mounted volumes, it looks for a designated startup program on disk and executes it as the first user task.

This means kosh -- and any future shell, menu, or default environment -- can live as ordinary `.COM` files on disk, replaceable without rebuilding the kernel.

### 15.1 The STARTUP.COM lookup

After `_InitFS` completes, the kernel searches for the first available startup program in this order:

1. **`B:STARTUP.COM`** -- user override on the writable RAM disk
2. **`A:STARTUP.COM`** -- shipped default in the ROM disk
3. **ROM-resident fallback kosh** -- baked into the kernel ROM, always available

The first one found is `sys_exec`'d as task #1. This is invoked by the kernel directly via the same mechanism `sys_exec` would use, but with no parent task to wait on -- the spawned program simply becomes the system's primary task.

If a user wants to boot directly into Forth instead of kosh, they `cp B:FORTH.COM B:STARTUP.COM` and reboot. The next boot finds `B:STARTUP.COM` first and runs Forth as the primary task.

If `B:STARTUP.COM` exists but is malformed or fails to exec (`ERR_NOTEXEC`, `ERR_TOOBIG`, etc.), the kernel logs an error and falls through to `A:STARTUP.COM`. If both are missing or both fail, the ROM-resident kosh is spawned as a final fallback. **The system can never become unbootable through filesystem changes alone** -- the ROM-resident kosh is always reachable.

### 15.2 No "bootable volume" flag

FAT16 has no native "this volume is bootable" attribute. Bootability on PC hardware is determined by code in the boot sector's first three bytes (an x86 jump instruction) plus bootstrap code in the 448-byte region between the BPB and the signature.

k/OS does **not** boot from FAT16 volumes -- it boots from ROM -- so this is not relevant to k/OS itself. The boot sector's jump field (`$000..$002`) is set to `EB 3C 90`, the conventional "non-bootable but valid disk" pattern. The 448-byte boot-code region (`$03E..$1FD`) is zero-filled.

This means k/OS-authored FAT16 images are **not bootable on PC hardware** if you write them to a USB stick. They are valid and mountable as data disks; they just cannot be used to start a PC operating system. For our purposes this is correct -- the goal is data interchange, not PC-bootability.

The format reserves the space if PC-bootability ever becomes desirable. Phase 16 will not pursue it.

### 15.3 Implications

- **kosh becomes a regular file.** Phase 16 keeps kosh ROM-resident (matching Phase 15). Phase 17 ports kosh to a `.COM` file delivered on the ROM disk as `A:STARTUP.COM`. The ROM-resident copy remains as the safety-net fallback, but the on-disk copy becomes the one users normally invoke.
- **kosh updates independently of the kernel.** Once kosh lives on disk, adding features (aliases, history, scripting) doesn't require a ROM rebuild.
- **Users can replace the shell entirely.** A user-written program named `STARTUP.COM` becomes the system's primary task. This is opt-in -- absence of `STARTUP.COM` is the normal case.
- **The ROM kosh stays minimal.** The ROM-resident kosh exists only to recover the system if the on-disk environment is missing or broken. It need only support enough commands to fix things (`ls`, `cat`, `cp`, `rm`, `format`, `run`).

### 15.4 Phase 16 scope

Phase 16 does **not** implement the `STARTUP.COM` lookup. The kernel continues to spawn the ROM-resident kosh directly, as it does today. The mechanism described above is delivered in Phase 17, alongside Forth and BASIC porting.

This keeps Phase 16 focused on the filesystem itself: prove `sys_exec` works against `Test/hello.asm`, ship the six syscalls, ship the kosh built-ins for FS operations. The boot-time program selection is a small additional change for Phase 17 -- maybe 30 lines of kernel code -- once Phase 16's foundations are in place.

---

## 16. Compatibility notes

### 16.1 With Windows

A k/OS-formatted RAM disk image opened in Windows works fully:

- The volume mounts as drive `Z:` (or whatever Windows assigns).
- Files are visible with their 8.3 names.
- Files can be read, written, copied, deleted from Windows.
- The k/OS read-only-attribute-as-exec convention shows up as Windows "read-only" files, which is harmless.

The Windows-side filesystem driver may add LFN entries for files renamed to long names within Windows. k/OS Phase 16 will silently skip those LFN entries when listing the directory; the underlying 8.3 alias is still accessible.

### 16.2 With Linux / mtools

The image file is mountable via `mount -t vfat -o loop ramdisk.img /mnt/k16`. The `mtools` suite (`mdir`, `mcopy`) also works directly on the image file:

```
mdir -i ramdisk.img ::
mcopy -i ramdisk.img myfile.txt ::
```

This is the recommended way to pre-populate a RAM disk image during development.

### 16.3 With SD cards (Phase 17 onwards)

SD cards formatted on a PC as FAT16 (max 2 GB) will be read by k/OS without translation. Cards larger than 2 GB will need to be reformatted as FAT16 from a small partition (or the format choice revisited in Phase 19+ to add FAT32).

---

## Appendix A. Phase 16 implementation checklist

**Pieces 1+2+3 — complete and verified (6 May 2026):**

- [x] `kos_fs_defs.inc` -- BPB offsets, attribute bits, volume table layout, FAT cache state, FS buffers (r7)
- [x] Volume table reservation in `kos_defs.inc` (`$0260..$031F`)
- [x] FAT cache state at `$0320..$032F` in `kos_defs.inc`
- [x] FS scratch buffers at `$BC00..$BFFF` (kos_defs.inc r23, post page-$00 reorganisation)
- [x] New error codes in `kos_defs.inc` (ERR_IO, NOSPACE, NOTPRESENT, BADDRIVE, READONLY, INVALID_BPB, NOFD, BADFD, NOTFOUND, EXISTS, NOTEXEC)
- [x] New TRAP vectors 26..31 reserved in `kos_boot.asm` (handlers stubbed pending Pieces 5+6)
- [x] `kos_fs_ram.asm` -- RAM `_BlockReadRAM` / `_BlockWriteRAM`, host-aware (EMU vs Digital)
- [x] `kos_fs_rom.asm` -- ROM `_BlockReadROM` (no write)
- [x] `kos_fs.asm` -- `_InitFS`, `_TryMount`, `_FormatVolume`, FAT cache (`_FATInvalidate`, `_FATFlush`, `_FATLoad`, `_FATGetEntry`, `_FATSetEntry`), cluster ops (`_AllocCluster`, `_FreeCluster`, `_ClusterToSector`)
- [x] `kos_p16_fs_smoke.asm` (originally planned as `kos_p16_format_smoke.asm`) -- 13 tests covering all Piece 1+2+3 functionality. All pass on EMU. T01-T11 + T13 pass on Digital; T12 (alloc until ERR_NOSPACE) passes but is `O(N²)` and takes ~17 minutes due to simulator clock.

**Piece 4 — complete and verified (6 May 2026):**

- [x] `kos_fs_dir.asm` -- name conversion (`_DirNameToFat`, `_DirNameFromFat`), iteration (`_DirOpen`, `_DirRewind`, `_DirNext`, `_DirNextRaw`), lookup (`_DirLookup`), entry create/delete (`_DirCreate`, `_DirDelete`), RTC stubs (`_GetDate`, `_GetTime`)
- [x] Cookie-based iteration (16-bit packed cookie: bits 15..4 = sec_off, bits 3..0 = ent_idx)
- [x] First-fit slot reuse in `_DirCreate` (claims `$E5` before extending into `$00`)
- [x] `kos_p16_fs_dir_smoke.asm` -- 13 tests covering name conversion, empty-dir iteration, create/lookup/iterate/delete, slot reuse, fill-32-then-NOSPACE, iterate-32-after-fill. All pass on EMU and on Digital.

**Piece 5 — complete and verified (6 May 2026):**

- [x] `kos_fs_fd.asm` -- file syscalls and 22 internal helpers: `sys_open`, `sys_close`, `sys_read`, `sys_write`, `sys_dirent` (TRAPs 26..30); helpers cover fd allocation, slot/drive resolution, dirent populate / refresh / flush, cluster ensure / advance, RMW sector reads/writes, user-buffer copy, multi-cluster chain truncation
- [x] FD_TABLE moved out of kernel-vector overlap by spawning a dedicated user task in the smoke; FD_TABLE lives in `user_page:$000C..$006B` per the §7 design
- [x] `_FdEnsureCluster` handles all five cases (empty file, mid-cluster, cluster start, advance via FAT, allocate-and-chain at tail)
- [x] `_TruncateExisting` walks and frees the full cluster chain (gotcha 4.17 fix: PUSH/POP D1 around `_FATGetEntry` to preserve "current cluster")
- [x] `kos_p16_fs_rw_smoke.asm` -- 14-test smoke covering open/close/read/write/dirent across single-cluster and multi-cluster files. All pass on EMU and on Digital.
- [x] Cross-host verification: T11 (600-byte multi-cluster RW) is the headline test — exercises both the write-side cluster chain extension (`_FdEnsureCluster` case 5 → `_AllocCluster` + `_FATSetEntry` chain) and the read-side cluster walk (`_FdAdvancePosition` → `_FATGetEntry`)

**Piece 6 — complete and verified on EMU and Digital (6 May 2026):**

- [x] `kos_fs_exec.asm` -- `sys_exec` (TRAP #31) and 4 internal helpers: `_ExecCheckExt` (verify `.COM` extension), `_ExecCopyChain` (walk cluster chain into the new user page), `_ExecCopyOneSector` (byte-copy one sector worth), `_ExecStageName` (populate `BT_NAME` from the file's base name)
- [x] Position-independence relies on `LEA` PC-relative + page-zero `TRAP` indirection; `.COM` images survive byte-for-byte relocation from ROM/disk into a fresh user page at `$0200..`
- [x] Failure semantics match spec §9.6: ERR_BADPATH (parse), ERR_NOTEXEC (extension or size > SPAWN_MAX_LEN or empty file), ERR_NOTFOUND, ERR_NOMEM (page allocator), ERR_IO (block-layer read), ERR_NOSLOTS (TCB pool full)
- [x] Per-task scratch on page $00 at `$03BB..$03C5` (`FE_FLAGS`, `FE_NEW_PAGE`, `FE_DEST_OFF`, `FE_BYTES_LEFT`, `FE_CURR_CL`, `FE_CHUNK_TMP`); kernel-only, DINT-protected for the duration of the call
- [x] `kos_p16_fs_exec_smoke.asm` -- 7-test smoke: stage hello.com bytes; open/write/close `B:HELLO.COM`; sys_exec it (verify TID ≥ 1); sys_exec on non-existent path → ERR_NOTFOUND; create `B:HELLO.TXT` then sys_exec it → ERR_NOTEXEC. Position-independent hello.com inlined as a `.BYTE`-style block in the smoke source (mkcom external tool deferred to Phase 17)
- [x] `Test/hello.asm` -- standalone reference source for the .COM format; not in build pipeline yet (mkcom deferred); embedded inline in the smoke

**Phase 16 follow-on work — Phase 16.7 progress:**

- [x] kosh integration partial: `vol`, `ls`, `cat` shipped (Phase 16.7)
- [x] Auto-format B: at boot when not mounted (Phase 16.7) — removes need for first-boot manual `format`
- [x] `_TryMount` now computes `VOL_TOTAL_CLUSTERS` correctly (formerly TODO)
- [x] ROM-disk authoring pipeline (Part 26) — replaced the planned `mkromdisk` external tool with the EMU host-disk-backend authoring route (§10.4): image created under EMU using `mkdisk`/`format`/`cp`, loaded into A: at startup via INI `[Disks] A=`, baked into Digital ROM via the K16 assembler IDE's "k/OS ROM Drive file" setting. Validated end-to-end on Digital with Forth + BASIC executing from A:.
- [ ] kosh integration remaining: `format`, `cp`, `rm`, `run`, `text`
- [ ] EMU-only: Save/Load RAM disk menu items
- [ ] `mkcom` external Pascal/Delphi tool (build a standalone `.COM` file from a single `.asm` source)

**Documentation — done for current implementation state:**

- [x] `kOS_Reference_Manual` updated to v0.8 — kosh promoted from smoke to production user task; source layout includes `kosh/` directory; Phase 16.7 entry in revision history
- [x] `kOS_Gotchas` updated to v1.6 — entry 4.19 (user-page scratch overrun as task body grows)
- [x] `kOS_KLIB_Reference` updated to v1.1 — UTOA/ITOA/ITOH cursor-style refactor with best-of-both API
- [x] `K16_ISA_Gotchas` v1.1 (entry #36) referenced for the ROM-write divergence
- [x] `kOS_FS_Reference` updated to v1.9 — auto-format note in §10.1, Phase 16.7 status in §12

**Deferred to Phase 17+:**

- Real-time clock — replaces `_GetDate` / `_GetTime` stubs in `kos_fs_dir.asm` with live reads
- Next-free-cluster hint to convert `_AllocCluster` from O(N²) to O(N)
- Host-disk format from kosh (currently `format` is `B:` only)
- Multi-task FD-aware unmount (Part 22+23 unmount path is single-task safe)
- SD-card backend on Digital (would map to spare drive slot, post Part 23)
- Subdirectories
- Long filenames (LFN)
- `STARTUP.COM` boot lookup

---

## Appendix B. Revision history

| Version | Date | Notes |
|---|---|---|
| 1.0 | 6 May 2026 | Initial design after Phase 15 (kosh) complete. FAT16 chosen over custom kFS for interop. 8.3 filenames, no subdirs/LFN in Phase 16. Executable detection by `.COM` extension (matching Windows convention); read-only attribute reserved for write-protection only. fd table is single 12-byte-per-entry table at `$000C..$006B`. |
| 1.1 | 6 May 2026 | Added Section 15 "Boot-time program selection" describing the `STARTUP.COM` lookup mechanism (B: → A: → ROM-resident kosh fallback). Renumbered "Compatibility notes" to Section 16. STARTUP.COM mechanism is Phase 17 work; Phase 16 keeps ROM-resident kosh as today. Clarified that k/OS does not boot from FAT16 volumes (kernel boots from K16 ROM); FAT16 images are explicitly non-bootable on PC hardware. |
| 1.2 | 6 May 2026 | Implementation phase. Volume table base moved from `$0270` to `$0260` to pack immediately after `BT_NAME` (which ends at `$025F`); table runs `$0260..$031F`. `kos_fs_defs.inc` written; new TRAP vectors and error codes drafted as `kos_defs.inc` addendum. ROM disk pinned to ROM page `$E2` (provisional; subject to K16 firmware layout). RAM disk pages confirmed as `$1C..$1F` (Digital) and `$30..$3F` (EMU). |
| 1.3 | 6 May 2026 | ROM disk pinned to page `$FC` (was provisional `$E2`). The K16 ROM map is `$FC..$FE` for program code and `$FF` for boot/reset; `$FC` is the lowest program-code page and is dedicated to the ROM disk. Kernel code lives in `$FD..$FE`. ROM disk is one page = 64 KB = 128 sectors, generated by external `mkromdisk` tool. |
| 1.4 | 6 May 2026 | ROM disk grown to two pages (`$FC..$FD`) = 128 KB = 256 sectors. Kernel program code now confined to single page `$FE`; boot/reset stays in `$FF`. ROM disk usable space rises from ~62 KB to ~125 KB (251 clusters), enough for Forth + BASIC + kosh + ~10 small utilities without crowding. Kernel size headroom remains comfortable at ~16 KB used / 64 KB available. |
| 1.5 | 6 May 2026 | Implementation status update for Pieces 1+2+3 complete. Appendix A checklist marks 9 items done (volume table, FAT cache, error codes, vectors, both block backends, top-level FS, smoke test); 10 items pending (Pieces 4-6, kosh integration, mkromdisk tool, EMU save/load). FS scratch buffers placed at `$BC00..$BFFF` (post page-$00 reorganisation in kos_defs.inc r23; `KERNEL_STACK_TOP` moved to `$FFFE`). FAT cache state added at `$0320..$032F`. Smoke test renamed from planned `kos_p16_format_smoke.asm` to actual `kos_p16_fs_smoke.asm` (covers all Piece 1+2+3 functionality, 13 tests). Performance note: `_AllocCluster` is `O(N²)` on full-disk scan; T12 takes ~17 min on Digital. Phase 17 will add a next-free-cluster hint for ~250x speedup. |
| 1.6 | 6 May 2026 | Phase 16 Piece 4 complete and verified on both EMU and Digital. New section 5.5 "Directory operation API" documents `_DirNameToFat` / `_DirNameFromFat`, the cookie iteration format, `_DirOpen` / `_DirNext` / `_DirNextRaw` / `_DirRewind`, `_DirLookup`, `_DirCreate`, `_DirDelete`, and the `_GetDate` / `_GetTime` RTC stubs (Phase 17 seam). Appendix A: Piece 4 line items moved to "complete and verified"; 13-test `kos_p16_fs_dir_smoke.asm` added to checklist; documentation cross-references updated for kOS_Gotchas v1.4 and K16_ISA_Gotchas entry #36. RTC integration added to deferred list. Pieces 5-6 remain pending. |
| 1.7 | 6 May 2026 | Phase 16 Piece 5 complete and verified on both EMU and Digital. New section 9.0 "Buffer-pointer ABI for syscalls that accept user data" documents the `MOVE Y0, Y3` calling convention and the user-page memory map; resolves a class of buffer-placement bugs that surfaced during Piece 5 bring-up. Appendix A: Piece 5 line items moved to "complete and verified" with the 14-test `kos_p16_fs_rw_smoke.asm` highlighted; only Piece 6 (`sys_exec`) remains. Cross-references kOS_Gotchas v1.5 entries 4.16 (LOAD doesn't set flags), 4.17 (`_FATGetEntry`/`_FdValid` clobber D1), 4.18 (user-buffer page convention), and 6.6 (EMU permissiveness masks page-collision bugs). |
| 1.8 | 6 May 2026 | Phase 16 Piece 6 complete and verified on both EMU and Digital (7/7 tests pass on both hosts; "Hello from sys_exec!" prints correctly between ET05 PASS and ET06 label, confirming concurrent execution of the spawned task). `kos_fs_exec.asm` r1 implements `sys_exec` (TRAP #31) plus four helpers: extension verification, FAT cluster-chain copy into a fresh user page, single-sector copy with chunk capping for the last cluster, and BT_NAME staging from the file's 8-char base name. Path validation uses the same `_ParsePath` + `FD_NAMEBUF` pattern as Piece 5. The .COM file format is raw binary loaded at `user_page:$0200`; position-independence is achieved by restricting .COM code to PC-relative `LEA`, page-zero `TRAP` indirection, and PC-relative branches (no `CALL24`/`JMP24` to internal .COM labels). New 7-test smoke `kos_p16_fs_exec_smoke.asm` covering stage→open→write→close→exec happy path plus ERR_NOTFOUND and ERR_NOTEXEC negative paths. `Test/hello.asm` shipped as reference source for the .COM format; embedded inline in the smoke pending an mkcom tool. Appendix A: Piece 6 line items moved to "complete and verified"; only Phase 16 follow-on work (kosh FS commands, EMU save/load, mkromdisk, mkcom) remains. Bumped `kOS_Reference_Manual` cross-reference to v0.7. One alignment fix during bring-up: `FE_NEW_PAGE` (byte) moved to $03BB to absorb the odd slot left by Piece 5's FD_DIRENT_RAW; FE_FLAGS et al begin at the next even boundary $03BC. |
| 1.9 | 7 May 2026 | Phase 16.7 — kosh FS commands (partial). **`vol`, `ls`, `cat` shipped** in `kosh/kosh_cmds_fs.asm`; `format`, `cp`, `rm`, `run`, `text` deferred. **Auto-format B: at boot** — kosh's `_P2Main` now formats B: with label `KOS-RAM    ` if `_InitFS` left it unmounted, removing the need for manual `format` on first boot. §10.1 updated. **`_TryMount` r2 now computes `VOL_TOTAL_CLUSTERS`** at mount time: `total_clusters = (total_sectors - data_start) / sec_per_cluster`, with powers-of-2 sec_per_cluster handled via SHR. The field was reserved in the slot layout but never filled; the `vol` command was reading zero. Removed from deferred list. §12 (Shell integration) updated with shipped/pending status table; references `kosh/kosh_cmds_fs.asm` and the buffer-and-blast formatting pattern. Cross-references `kOS_KLIB_Reference v1.1` (cursor-style UTOA dependency), `kOS_Reference_Manual v0.8`, `kOS_Gotchas v1.6` (entry 4.19 — user-page scratch overrun as task body grows). |
| 1.10 | 7 May 2026 | Phase 19 — kosh extensions: `format` and `run` shipped; previously deferred. **§9.7 sys_format (TRAP #32)** documented as a first-class non-leaf syscall (was previously internal-only `_FormatVolume`). VEC_FORMAT = $0080. **§10.2 reworded** to reference §9.7 and add the Phase 19 disk-populate convention: kosh's task body, after auto-format on boot, idempotently writes `HELLO.COM` (36 B) and `NOTES.TXT` from kernel-side ROM data. Existence-check via `sys_open(path, FOPEN_READ)` before create. **Open issues** — `cat` currently relies on a "short-read = EOF" workaround because `sys_read` returns ERR_BADFD on a post-EOF call (read at exactly file_size, on a perfectly valid fd). Root cause unknown; flagged in the next session's NEW_CHAT_CONTEXT. **`run B:HELLO.COM` crashes** — child task starts but PC lands at $00:0002, indicating either `_ExecCopyChain` didn't load the body to `<new_page>:$0200` or `_BuildTask` baked the wrong PC into the fake INT frame. Diagnostic plan documented. Cross-references `kOS_Gotchas v1.7` entries 4.20 (FD_TABLE aliases vector table when calling sys_* from boot Y3=$00), 4.21 (FOPEN_* vs FD_FLAG_* are different bit assignments), 4.22 (helper-clobbered registers across loop iteration bodies). |
| 1.11 | 8 May 2026 | **Both open issues from v1.10 now resolved.** (1) The `sys_read` post-EOF ERR_BADFD bug was a **V2 ABI violation** — `sys_read` was clobbering caller's D2 (`MOVE D2, Y0` plus internal helpers using D2 as scratch), and kosh `cat` had stashed `fd` in D2 across the read loop. After read1 returned, D2 held the new file position (220), not the fd; the next iteration passed 220 as fd and hit ERR_BADFD. Fixed in `kos_fs_fd.asm` r3 (all five FD-layer syscalls now PUSH D2/D3 at entry, POP after EINT gate); cat's short-read-=EOF workaround removed (now does the canonical read-until-zero loop). (2) The `run B:HELLO.COM` PC-at-$00:$0002 hang was a **byte-order bug in the embedded HELLO.COM image** in `kosh.asm`: the `.BYTE` blob was transcribed from the listing word column with high byte first (e.g. `$1C, $00` for word `$1C00`), but K16 is little-endian and stores words low-byte-first. Fix: switched the code blob to `.WORD $1C00, ...` so the assembler does the byte-swap. **§9 head** now declares the V2 ABI register-preservation rule explicitly (D2/D3/XY2 callee-saved across every FS syscall); `sys_format` and `sys_exec` got the same fix (`kos_fs.asm` r4, `kos_fs_exec.asm` r3) under the **Part 20a audit** triggered by the FD-layer find. **§11.4** added: planned `kos_fs_host.asm` host-disk backend will use Part 20b counting semaphores to protect the disk MMIO critical section (mutex pattern with FIFO wait queue). Cross-references `K16_ISA_Gotchas v6` (entries #31, #32), `kOS_Gotchas v1.8` (entries 4.23, 4.24), `kOS_Reference_Manual v0.10` (§5 ABI rule, §5.5 Semaphores), `Syscall_ABI_Audit_2026-05-08.md`. |
| 1.12 | 10 May 2026 | **Parts 22 + 23 — host-disk backend and name-based mount management.** §1.1 Backends row now reads "ROM (A:), RAM (B:), host disk (C..F:, EMU-only)". §1.2 reworked for six drives. §1.3 source layout adds `kos_fs_host.asm` (Part 22 — block-layer backend) and `kos_fs_host_mgr.asm` (Part 23 — management helpers). §11.4 promoted from "future" to "implemented Part 22": `_BlockReadHost`/`_BlockWriteHost`, `HOST_DISK_SEM` mutex via `_SemTakeBlocking`/`_SemGive`, bay derivation from volume slot offset. **§11.5 added**: host-disk management API (`_HostMount`, `_HostUnmount`, `_HostList`, `_HostCreate`, `_HostDelete`), MMIO surface (`DSK_HOST_CMD = $DA0016` plus `HOST_CMD_*` codes), INI persistence model (`[Disks] Path=` + `C/D/E/F=`), boot flow, design note on the dropped Part 22 pool layer (replaced because slot-vs-bay double indexing was a recurring bug source — see `kOS_Gotchas` 4.27), and open issues (multi-task FD safety, RO flag, host-disk format). §12 Shell integration table updated: `format` and `run` shipped (Phase 19), plus five new commands `disks/mount/unmount/mkdisk/rmdisk` (Part 23) all marked shipped. §14 stale "SD card backend (slot C:)" item replaced with "Host-disk format" deferred item. |
| 1.13 | 11 May 2026 | **Parts 24 + 25 — host filename rename, FS-level unlink/rename, kosh CWD, and host file ingestion.** §1.1 Syscalls row updated to "9 TRAPs (open, close, read, write, dirent, exec, format, unlink, rename)". **§8 reworked**: kernel path syntax still requires `X:NAME` but the new **§8.1 kosh current working drive** documents the Part 25 r4 CWD model — `_KoshNormPath` prepends `<CWD>:` to bare filenames before they reach the kernel, and bare drive-letter lines (`C:`) switch CWD. **§9 intro** updated for TRAP gap (33..36 are semaphores, 37/38 are new FS). **§9.7 sys_format** updated: now supports host disks B..F (Part 24) by defaulting label to `_HostBayName`. **§9.8 sys_unlink (TRAP #37) added** — delete a file with FAT-chain free + cross-FD-table busy check; VEC_UNLINK = $0094. **§9.9 sys_rename (TRAP #38) added** — in-place dirent rename within a single volume; cross-drive moves are kosh-side cp+unlink synthesis; VEC_RENAME = $0098. **§11.5 expanded** to ten host-management commands: added `_HostRename`/`_HostBayName` (Part 24, HOST_CMD_$0006/$0007) and `_HostFOpen`/`_HostFRead`/`_HostFClose` (Part 25 r6, HOST_CMD_$0008..$000A — the streaming surface for the `load` command). Host directory layout subsection added covering INI keys `DiskPath=` (renamed from `Path=`) and `LoadPath=`. Singleton-state and 64 KB cap on FOPEN documented; close-on-error-path rule called out. **§11.6 added**: two-phase mount semantics — Part 24 removed the bay-bind/FS-mount rollback. Bay can now be bound with no valid FS (the `mkdisk → mount → format` workflow needs this). Cross-references gotcha 4.33. **§12 rewritten**: shell-integration table now lists all 17+ FS-related commands across Phases 16-19 + Parts 22-25. New subsections §12.1 (CWD model and `_KoshNormPath`), §12.2 (`_KoshPrintErr` human-readable errors — Part 25 r3), §12.3 (the `load` workflow narrative). **§14 updated**: removed stale "host-disk format pending" (now done); added "kernel-level CWD / volume-name paths" and "`save` command" as deferred. References `kOS_Gotchas v1.10` new entries 3.8, 4.28, 4.29, 4.30, 4.31, 4.32, 4.33, 7.9, 7.10. |
| 1.14 | 27 May 2026 | **Part 26 — ROM-disk authoring pipeline.** Replaces the planned `mkromdisk` external tool with a two-stage pipeline that reuses existing infrastructure. **§10.1 reworded**: dropped the `mkromdisk` reference and stale "Phase 17 extends the tool" prediction; points at §10.4 for authoring. **§10.4 added** ("ROM disk authoring (Part 26)"): documents the full workflow — image created under EMU as a `.KOS` file via existing `mkdisk`/`mount`/`format`/`cp`; preloaded into RAM at `$FC0000..$FDFFFF` on EMU startup and on every Reset via the new INI key `[Disks] A=`; dedupe rule for `A=` and `C..F=` pointing at the same file; assembler-side overlay via the new `[ROMDrive] File=` setting in the K16 assembler IDE; stats line and missing-image warning emitted by `GenerateROMs`. **Appendix A** updated: replaced the open `[ ] mkromdisk` item with a completed `[x] ROM-disk authoring pipeline (Part 26)` entry cross-referencing §10.4. **Validated end-to-end on Digital** on 27 May 2026: Forth v3.0 + BASIC v2.5 both run from A:, `vol`/`ls` output bit-identical between EMU A: and Digital A:, multitasking confirmed via `ps`. Implementation touches: `emu_disk.pas` (new `LoadRomDiskFromIni`, dedupe in `LoadDiskMountsAndMount`), `frm_main.pas` (call from `FormCreate` and `LoadAndReset`), `main.pas` (assembler IDE Settings tab `FileNameEditROMdisk` + `[ROMDrive] File=` persistence + pass-through to `GenerateROMs`), `K16_Export.pas` (`GenerateROMs` 4th param + step 4b overlay at `$FC0000 - BaseAddr` + size validation + stats line). No kernel changes — k/OS's `_BlockReadROM` and `_InitFS` paths handle both EMU-preloaded and Digital-baked images identically. |
