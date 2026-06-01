# K16 Disk Controller — Host-File Backend

**Date:** 8 May 2026
**Status:** Emu side complete and compiled. k/OS side not yet started.
**Scope:** Adds a third FS backend to k/OS for accessing host-OS files as block-addressable disks.

---

## 1. Overview

This document covers the design and use of the K16 disk controller, which presents host-OS files as sector-addressable block devices to k/OS. Together with the existing FAT16 driver and the RAM/ROM backends, it provides a complete file-transfer path between k/OS and the host operating system.

The controller is purely an emulator concept — Digital simulation has no equivalent and uses the existing RAM/ROM disks. On real K16 hardware (FPGA), the same MMIO interface will eventually be backed by an SD card controller; the k/OS-side driver will be reusable with minor changes.

### 1.1 Two-level model

The controller models disk management at two levels:

**Pool** — library of disk images the emulator knows about. Loaded from `K16EmuIDE.ini` at startup. Each pool entry has a name (k/OS-visible), a host filename, a read-only flag, and an `AutoMountSlot` field indicating which drive bay to mount it in at boot (or `-1` for "available, but unmounted"). Up to 16 entries.

**Drives** — four active bays, slots 0..3. At most one pool entry may be mounted in each bay at any time. Sector commands (READ, WRITE, FORMAT, IDENT) operate on the bay selected by the `DSK_DRIVE` register.

### 1.2 Drive letters

Drive letters (`A:`, `B:`, etc.) are *k/OS state*, not emu state. The controller never sees a letter; it only knows numeric slots 0..3. k/OS maintains its own letter→slot mapping, persisted in a config file on the boot disk (proposed: `/etc/drives`).

This separation matters: a k/OS image is portable across host machines. A given .KOS image always mounts at the same letter as long as the boot disk's `/etc/drives` file is preserved, regardless of what slot the emu binds it to.

### 1.3 Three persistence stores

| Owner | State | Persisted in |
|---|---|---|
| Emu | Pool list (name, file, RO) | `K16EmuIDE.ini` `[Pool<N>]` sections — manually edited |
| Emu | Pool→slot mapping (`AutoMountSlot`) | `K16EmuIDE.ini` — auto-updated on every mount/unmount |
| k/OS | Letter→slot mapping | `/etc/drives` on boot disk — written by kosh |

No overlap, no synchronisation problem.

---

## 2. MMIO map

Range: `$DA0000..$DA001F` (16 word-aligned register slots).

Sits in the existing I/O range (`$D80000..$DFFFFF`) alongside video (`$DC`,`$DD`), keyboard (`$DE`), terminal (`$DF`).

### 2.1 Sector-IO registers

| Address | Name | Access | Purpose |
|---|---|---|---|
| `$DA0000` | `DSK_CMD` | W | Sector command — write triggers operation |
| `$DA0002` | `DSK_STATUS` | R | bit 0 = busy (always 0 — synchronous) |
| `$DA0004` | `DSK_DRIVE` | R/W | Drive bay 0..3, target for next CMD |
| `$DA0006` | `DSK_LBA_LO` | R/W | Sector # bits 15..0 |
| `$DA0008` | `DSK_LBA_HI` | R/W | Sector # bits 23..16 (24-bit LBA) |
| `$DA000A` | `DSK_BUF_LO` | R/W | K16 RAM buffer addr bits 15..0 |
| `$DA000C` | `DSK_BUF_HI` | R/W | K16 RAM buffer addr bits 23..16 |
| `$DA000E` | `DSK_SECCOUNT` | R/W | Sector count for transfer; reflects drive size after IDENT |
| `$DA0010` | `DSK_RESULT` | R | Result code of last command |
| `$DA0012` | `DSK_FLAGS` | R/W | bit 0 present, bit 1 RO, bit 2 media-changed (W: bit 1 used by CREATE) |

### 2.2 Pool/management registers

| Address | Name | Access | Purpose |
|---|---|---|---|
| `$DA0014` | `DSK_POOL_SLOT` | R/W | Selected pool entry index 0..POOL_COUNT-1 |
| `$DA0016` | `DSK_POOL_CMD` | W | Pool command — write triggers operation |
| `$DA0018` | `DSK_POOL_FLAGS` | R | bit 0 valid, bit 1 RO, bit 2 currently-mounted |
| `$DA001A` | `DSK_POOL_COUNT` | R | Total active pool entries |

### 2.3 Sector commands (`DSK_CMD`)

| Code | Name | Description |
|---|---|---|
| `$0000` | `CMD_NONE` | No-op |
| `$0001` | `CMD_READ` | Read SECCOUNT sectors from DRIVE:LBA into buffer at BUF |
| `$0002` | `CMD_WRITE` | Write SECCOUNT sectors from buffer at BUF to DRIVE:LBA |
| `$0003` | `CMD_IDENT` | Populate SECCOUNT (size in sectors) and FLAGS for selected DRIVE |
| `$0004` | `CMD_FLUSH` | Sync host file (no-op on emu — TFileStream auto-flushes) |
| `$0005` | `CMD_FORMAT` | Zero-fill all sectors of selected DRIVE |
| `$0006` | `CMD_MEDIA` | Refresh FLAGS, clear media-changed bit |

### 2.4 Pool commands (`DSK_POOL_CMD`)

| Code | Name | Inputs | Description |
|---|---|---|---|
| `$0000` | `POOL_CMD_NONE` | — | No-op |
| `$0001` | `POOL_CMD_NAME` | POOL_SLOT, BUF | Write entry's name (ASCIIZ, 16 bytes) to BUF |
| `$0002` | `POOL_CMD_MOUNT` | POOL_SLOT, DRIVE | Bind pool entry to drive bay |
| `$0003` | `POOL_CMD_UNMOUNT` | DRIVE | Release drive bay (POOL_SLOT ignored) |
| `$0004` | `POOL_CMD_CREATE` | BUF (name), SECCOUNT (size), FLAGS | Create new image and pool entry |
| `$0005` | `POOL_CMD_DESTROY` | POOL_SLOT | Delete pool entry (must be unmounted first) |

### 2.5 Result codes (`DSK_RESULT`)

| Code | Name | Meaning |
|---|---|---|
| `$0000` | `RES_OK` | Success |
| `$0001` | `RES_NO_MEDIA` | Drive bay empty / drive index out of range |
| `$0002` | `RES_BAD_LBA` | LBA + SECCOUNT exceeds drive size |
| `$0003` | `RES_RO` | Write attempted on read-only drive |
| `$0004` | `RES_IO_ERR` | Host-side I/O error |
| `$0005` | `RES_BUSY` | Pool entry already mounted / drive bay occupied |
| `$0006` | `RES_FULL` | No free drive bay or pool slot |
| `$0007` | `RES_EXISTS` | CREATE: name or host file already exists |
| `$0008` | `RES_NOT_FOUND` | Pool slot empty or invalid |
| `$0009` | `RES_BAD_NAME` | CREATE: invalid name (non-alphanumeric) |
| `$000A` | `RES_BAD_SIZE` | CREATE: size below FAT-viable floor |
| `$00FF` | `RES_BAD_CMD` | Unrecognised command |

---

## 3. k/OS-side driver

### 3.1 Source layout

| File | Purpose |
|---|---|
| `kos_fs_host.asm` | Host-disk backend — implements `_BlockRead`/`_BlockWrite` against the MMIO controller |
| `kos_disk_pool.asm` | Pool-management helpers used by kosh — name lookup, mount/unmount, create/destroy |

The block-layer integration is identical to `kos_fs_ram.asm` and `kos_fs_rom.asm`. The FS layer above does not change.

### 3.2 The block-read sequence

```
_BlockRead(drive, lba, buf):
    SemTake disk_mutex          ; serialise across tasks

    write DSK_DRIVE,    drive   ; 0..3
    write DSK_LBA_LO,   lba & $FFFF
    write DSK_LBA_HI,   lba >> 16
    write DSK_BUF_LO,   buf & $FFFF
    write DSK_BUF_HI,   buf >> 16
    write DSK_SECCOUNT, 1
    write DSK_CMD,      CMD_READ    ; emu services synchronously

    read  DSK_RESULT
    SemGive disk_mutex

    return result                ; RES_OK or error code
```

`_BlockWrite` is identical with `CMD_WRITE`. Both are leaf-style w.r.t. the disk; they hold the disk semaphore across the register sequence (a handful of stores) and release when DSK_CMD has completed.

### 3.3 The disk semaphore is mandatory

The disk controller has shared registers. Without a semaphore, this race is possible:

```
Task A: write DSK_DRIVE 0
Task A: write DSK_LBA_LO 100
        ... preempted ...
Task B: write DSK_DRIVE 1
Task B: write DSK_LBA_LO 200
Task B: write DSK_CMD READ        ; reads from drive 1, LBA 200
Task A: <resumes>
Task A: write DSK_CMD READ        ; thinks it's reading drive 0 LBA 100 — gets B's setup
```

The fix: `SemTake` on entry, `SemGive` on exit. Critical section is short (handful of register writes) so contention is minimal. Do not use DINT/EINT for this — it would suppress IRQs across all tasks unnecessarily.

### 3.4 No interrupts

Synchronous-only design. By the time the K16 STORE to `DSK_CMD` completes, the data is already in the buffer (or the buffer's been flushed to the host file). The driver does not need IRQ handlers, completion callbacks, or wait queues.

This trades hardware realism for simplicity and is the right call for the host-file backend. A future SD-card backend may revisit this if SD reads turn out to be slow enough to benefit, but it would be a separate driver, not a modification of this one.

### 3.5 FS-layer locking

Per-volume FS mutex on top of the disk mutex. Two-level locking, inner lock taken later, outer lock taken first → no deadlock:

```
sys_write(fd, buf, len):
    SemTake fs_mutex[fd.drive]      ; outer — per-volume
        walk FAT, allocate clusters, update dir entry
        for each sector to write:
            SemTake disk_mutex      ; inner — single controller
                program registers, trigger CMD
            SemGive disk_mutex
    SemGive fs_mutex
```

The per-volume FS mutex serialises FS operations on the same drive. Tasks reading different drives never contend on each other's FS mutex.

### 3.6 Required prerequisites

The disk driver requires k/OS-side primitives that don't yet exist:

- `_SemCreate`, `_SemTake`, `_SemGive` — counting semaphores
- Per-task FD table — likely 8 entries in TCB page-zero slots
- Cleanup-on-exit — `sys_exit` walks the dying task's FD table and closes each entry

These should be built before the disk driver. They're useful in their own right (any future shared resource needs semaphores), and the disk driver becomes ~80 lines of straightforward assembly once they exist.

---

## 4. kosh commands

The kosh user-facing interface for disk management.

### 4.1 `mount <letter>: <name>`

```
> mount E: SOURCES
```

1. kosh queries `DSK_POOL_COUNT`, then walks pool entries 0..N-1 issuing `POOL_CMD_NAME` to find `SOURCES` by name.
2. Read `DSK_POOL_FLAGS` for the matching entry. If bit 2 (mounted) set, find which slot via existing letter table; bind letter to that slot, done.
3. Otherwise pick a free drive bay (0..3), program `DSK_POOL_SLOT` and `DSK_DRIVE`, issue `POOL_CMD_MOUNT`. Read `DSK_RESULT`.
4. On `RES_OK`, append `E:=SOURCES` to `/etc/drives`.

### 4.2 `unmount <letter>:`

```
> unmount E:
```

1. Look up `E:` in letter table → drive bay N.
2. If any other letter still maps to bay N, just remove the letter binding. Don't touch the controller.
3. Otherwise issue `POOL_CMD_UNMOUNT` with `DSK_DRIVE = N`. Emu releases the host file.
4. Remove `E:=...` from `/etc/drives`.

### 4.3 `mkdisk <name> <sectors>`

```
> mkdisk SCRATCH 4096
```

1. Write `name` ASCIIZ to a kernel buffer.
2. Program `DSK_BUF_LO`/`DSK_BUF_HI` to point at it.
3. Set `DSK_SECCOUNT` to size in sectors (≥ 64).
4. Set `DSK_FLAGS` to `$0002` if read-only, else `0`.
5. Issue `POOL_CMD_CREATE`. Emu allocates the host file (zero-filled), creates pool entry, persists INI.
6. On success, `DSK_POOL_SLOT` reflects the new entry's index.

Does *not* mount or format. Compose with `mount` and `format` for a full bring-up.

### 4.4 `rmdisk <name>`

```
> rmdisk SCRATCH
```

1. Find pool index by name (loop with `POOL_CMD_NAME`).
2. If `DSK_POOL_FLAGS` shows mounted, refuse and tell user to unmount first.
3. Issue `POOL_CMD_DESTROY`. Emu deletes the host file and the pool entry.

Should be confirmation-gated in kosh — destructive.

### 4.5 `format <letter>:`

Already exists or close to it (`_FormatVolume`). No new MMIO commands needed — operates entirely through the existing block layer. The host-file backend looks just like the RAM backend to `_FormatVolume`.

### 4.6 Typical bring-up of a fresh drive

```
> mkdisk SCRATCH 4096
created SCRATCH (4096 sectors, 2 MB)
> mount D: SCRATCH
mounted SCRATCH at D:
> format D:
formatting D: as FAT16... done.
> ls D:
D:\>
```

---

## 5. INI format

The emulator's `K16EmuIDE.ini` gains a `[Disks]` section plus one `[Pool<N>]` section per pool entry.

### 5.1 Example

```ini
[Disks]
PoolCount=3
Path=C:\K16\Disks

[Pool0]
Name=BOOT
File=C:\K16\Disks\BOOT.KOS
ReadOnly=False
AutoMountSlot=0

[Pool1]
Name=HOME
File=C:\K16\Disks\HOME.KOS
ReadOnly=False
AutoMountSlot=1

[Pool2]
Name=SOURCES
File=C:\K16\Disks\SOURCES.KOS
ReadOnly=True
AutoMountSlot=-1
```

### 5.2 Field reference

| Field | Type | Description |
|---|---|---|
| `[Disks]` `PoolCount` | int | Number of valid pool entries (Pool0..PoolN-1) |
| `[Disks]` `Path` | string | Default directory for new images created via `POOL_CMD_CREATE` |
| `[PoolN]` `Name` | string | Pool entry name, ≤ 15 chars, alphanumeric + underscore |
| `[PoolN]` `File` | string | Host filename — absolute path or relative to emu cwd |
| `[PoolN]` `ReadOnly` | bool | True opens with `fmOpenRead`, refuses WRITE/FORMAT |
| `[PoolN]` `AutoMountSlot` | int | -1 = unmounted at boot, else 0..3 = drive bay |

### 5.3 Persistence behaviour

The emu writes the INI on every successful pool operation that mutates state — `POOL_CMD_MOUNT`, `POOL_CMD_UNMOUNT`, `POOL_CMD_CREATE`, `POOL_CMD_DESTROY`. The INI is always current; emu crashes don't lose mount state. Manual edits to the file are picked up at next launch.

When INI is rewritten, all `[Pool<N>]` sections are erased first to handle compaction after `POOL_CMD_DESTROY` cleanly. Field order may change but the active pool entries are preserved.

---

## 6. File transfer Windows ↔ k/OS

Because the host file is a standard FAT16 image, file transfer is a host-OS operation — no special tooling.

### 6.1 Workflow

1. In kosh: `unmount D:` (or quit emu) — releases the file lock.
2. In Windows: mount `MYDISK.KOS` as a drive (e.g. `imdisk -a -f MYDISK.KOS -m X:`) or use `mtools` / WSL's loop-mount. Drag files in.
3. Dismount in Windows.
4. In kosh: `mount D: MYDISK` — k/OS reads the new state.

### 6.2 Why locked-while-mounted

The emu opens host files with `fmShareDenyWrite`. While k/OS has the disk mounted, Windows can read but not modify the image. This avoids:

- Torn writes — Windows updates a FAT entry mid-way through a k/OS read
- Cache incoherency — k/OS thinks cluster 100 is free, Windows just allocated it
- Concurrent FAT mutation — neither OS knows about the other's view

Locking is the right answer because Windows itself, when mounting a small image as a drive letter, caches the entire image in its filesystem cache and only writes back on dismount/eject. The lock model matches Windows' actual behaviour: image changes happen at dismount, not continuously.

A "shared mode" with mtime polling on the emu side and IRQ-based cache invalidation on the k/OS side is conceivable but unsolvable in general — Windows doesn't know about k/OS's FS mutex. Locked mode is correct by construction.

---

## 7. Emu side architecture

### 7.1 File layout

Single unit `gui/emu_disk.pas` containing the controller. Lives alongside `emu_io_gui.pas` and `emu_terminal.pas` — peripherals with host-OS dependencies belong in the GUI layer.

The core (`emu_mem`, `emu_cpu`, etc.) is unchanged. The disk controller is reachable via the existing `IO^.ReadIO`/`IO^.WriteIO` indirection in `emu_mem`'s I/O dispatch, and `TGUIIOHandler` routes the `$DA0000..$DA001F` range to `DiskReadIO`/`DiskWriteIO`.

### 7.2 Lifecycle

| Form callback | Calls |
|---|---|
| `FormCreate` (after `LoadSettings`) | `DiskInit` → `LoadDiskPool(IniPath)` → `AutoMountAll` |
| `FormDestroy` | `DiskShutdown` (closes any open file streams) |

### 7.3 INI integration

The disk controller's `LoadDiskPool` and `SaveDiskPool` operate on the same INI file used by `LoadSettings`/`SaveSettings` — sections are namespaced (`[Disks]`, `[Pool<N>]`) so there's no overlap. The emu retains the path at `DiskIniPath` so `SaveDiskPool` can be called from inside `POOL_CMD_*` handlers without going back through the form.

### 7.4 Host-file open mode

```pascal
fmOpenRead      or fmShareDenyWrite     // read-only pool entries
fmOpenReadWrite or fmShareDenyWrite     // writeable pool entries
```

Other Windows processes can read but not write while the emu is running. This is the locking model from §6.2.

---

## 8. Multi-tasking considerations

When two k/OS tasks both hit the disk:

1. **Device-level race** — both program registers, last writer wins. Solved by the disk semaphore in §3.3.
2. **Filesystem-level race** — both walk the FAT, both grab the same free cluster. Solved by per-volume FS mutex in §3.5.

Drive-letter table needs locking too if multiple tasks can mount/unmount, but only kosh does that today, and kosh is single-threaded. If background tasks ever gain the ability to mount, add a kosh-side mutex around `/etc/drives` updates.

Per-task FD tables are owned by the TCB and require no locking (each task accesses only its own). Cleanup on `sys_exit` walks the dying task's FD table outside of any lock — by definition the task is no longer running, no other task references its FDs.

---

## 9. Future considerations

### 9.1 Real hardware

The MMIO interface is designed to be portable. On real K16 hardware:

- The disk controller becomes an FPGA-side SD card interface
- `DSK_DRIVE` selects from physical SD slots (or partitions on a single card)
- `DSK_BUF_LO/HI` becomes a real DMA descriptor — same semantics, different backing
- `kos_fs_host.asm` works unchanged provided register addresses match
- The `POOL_CMD_*` extension may not exist on hardware (no host filesystem to enumerate); kosh would fall back to direct slot mounting

The pool model is purely an emu convenience and doesn't survive to hardware. That's fine — by the time you're running on hardware, you have one or two SD slots and direct slot management is fine.

### 9.2 Async / interrupt-driven I/O

If a future controller (real SD, real spinning disk emulation) introduces real latency:

- Add a `DSK_STATUS` busy bit that actually means something
- Optional: an IRQ source raised when a long operation completes
- k/OS-side: switch from sync `_BlockRead` to a `_BlockReadAsync` + completion callback

Not needed today. Don't pre-build it.

### 9.3 Larger disks

24-bit LBA gives 16 M sectors × 512 = 8 GB ceiling. FAT16 caps at 2 GB regardless. Going beyond that means FAT32 or a different FS, plus a 32-bit LBA register pair (one more word).

### 9.4 Multiple controllers

If true parallel I/O across drives ever matters, model it as multiple controllers at non-overlapping MMIO ranges (e.g. `$DA0000`, `$DA1000`, ...). Each has its own mutex; tasks targeting different controllers don't contend. Not worth doing today.

---

## 10. References

- `K16 Reference Manual v3.10` — base ISA and existing MMIO peripherals
- `kOS_FS_Reference_v1_10.md` — FAT16 driver and existing RAM/ROM backends
- `K16_Revised_Memory_Map_IO_Top.txt` — historical memory map (current emu uses `$D80000..$DFFFFF` for I/O)
- `gui/emu_disk.pas` — emu-side controller implementation
- `gui/emu_io_gui.pas` — MMIO routing
- `frm_main.pas` — lifecycle integration

---

*End of document.*
