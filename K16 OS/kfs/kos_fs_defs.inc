; ============================================================================
; kos_fs_defs.inc — k/OS Phase 16: filesystem-internal constants
; ============================================================================
; Date:    18 May 2026
; Status:  Part 34 polish — DISKFREE_LIMIT slot for loop-bound hoist
; Revision: r14 — 18 May 2026 — Part 34 polish: added DISKFREE_LIMIT at
;               $03F8 to cache _VolFreeClusters' loop bound. See kos_fs.asm
;               r12 for the matching code change.
;
;           r13 — 18 May 2026 — Part 34: DISKFREE_CLUSTER / DISKFREE_COUNT
;               at $03F4 / $03F6. Used by _VolFreeClusters to count free
;               clusters across the FAT (sys_diskfree). Also refreshed the
;               stale "$03F0..$03FF reserved free-space" comment — that
;               range was partially claimed by Part 33 (HEAP_TID_QUERY /
;               HEAP_RBT_REGION at $03F0/$03F2). Manual is the authoritative
;               page-$00 map; this file's comments now match.
;
;           r12 — 11 May 2026 — Part 24 r2: HOST_CMD_BAYNAME ($0007).
;               Queries bay's basename for `format <drive>` default-label
;               sourcing.
;
;           r11 — 11 May 2026 — Part 24: HOST_CMD_RENAME ($0006).
;               Renames bay's bound file in-place — closes stream, renames
;               on disk, reopens at new path, updates INI. Used by `format
;               C: LABEL` to keep host filename and FAT16 label in sync.
;
;           r10 — 10 May 2026 — Part 23 simplification.
;               The host-disk pool/catalogue is gone. The disk\ folder
;               IS the catalogue; persistent bay assignments live in the
;               INI's [Disks] section as plain `C=name.kos`. Changes:
;               • DSK_POOL_SLOT / DSK_POOL_FLAGS / DSK_POOL_COUNT removed.
;               • DSK_HOST_CMD replaces DSK_POOL_CMD at the same offset.
;               • POOL_CMD_* removed; HOST_CMD_MOUNT/UNMOUNT/LIST/CREATE/
;                 DELETE replace them.
;               • POOL_NAME_BUF / POOL_NAME_BUF_END removed (no longer
;                 needed — name lookup is now caller-buffer based).
;               • DSK_POOL_NAME_LEN renamed DSK_NAME_MAX_LEN.
;               • DSK_POOL_VALID / DSK_POOL_RO / DSK_POOL_MOUNTED bits gone.
;               • DSK_LIST_BUF_BYTES (= 256) added — caller-supplied buf
;                 size for HOST_CMD_LIST output.
;
;           r9 — 9 May 2026 — Part 22: host-disk controller wired in.
;               • FS_DRIVE_C..FS_DRIVE_F redefined as the four host-disk
;                 bays (0..3 of the controller). Drive C: was previously
;                 a "reserved (SD, future)" placeholder and was never
;                 actually referenced anywhere in code, so we reuse the
;                 letter rather than gap to D:.
;               • FS_MAX_DRIVES bumped from 3 to 6 (A: B: C: D: E: F:).
;               • Volume table expanded from 3 slots ($0260..$031F) to
;                 6 slots ($0260..$03DF). VOL_SLOT_C..VOL_SLOT_F added.
;               • FAT cache moved from $0320..$032F to $03E0..$03EF.
;               • Sem pool moves from $03C8..$0447 to $0400..$047F —
;                 single-symbol change in kos_sem.asm.
;               • New section: disk-controller MMIO map at $DA0000.
;                 DSK_CMD / DSK_STATUS / DSK_DRIVE / DSK_LBA_LO/HI /
;                 DSK_BUF_LO/HI / DSK_SECCOUNT / DSK_RESULT / DSK_FLAGS
;                 plus the pool registers (DSK_POOL_*).
;               • Sector commands (CMD_NONE..CMD_MEDIA), pool commands
;                 (POOL_CMD_*), and result codes (RES_*).
;               • DSK_HOST_BAY_COUNT (= 4) — number of bays on the
;                 controller. Used by _InitFS to install host-disk
;                 backend pointers in slots C..F.
;
;           r8 — 6 May 2026 — Phase 16 Piece 5 cosmetic addition.
;               Added FD_DIR_COOKIE alias for FD_RESERVED ($06 within
;               an fd slot). The "reserved" word is now used by Piece 5
;               (kos_fs_fd.asm) to cache the dirent cookie of the open
;               file, so sys_close can flush size+first-cluster back to
;               the on-disk directory entry without having to walk the
;               root by name. Both names refer to the same offset; the
;               semantic name is preferred in new code.
;
;           r7 — 6 May 2026 — FS_BUF_SECTOR / FS_BUF_FAT moved from
;               $C000/$C200 to $BC00/$BE00. The buffers now sit just
;               below the kernel stack region (which starts at $C000
;               and grows down from $FFFE per kos_defs.inc r23). Both
;               buffers remain 512-byte aligned. No code change required
;               — all references are symbolic.
;
;           r6 — 6 May 2026 — added FAT cache state at $0320..$032F.
;               Single-sector FAT cache backing _FATGetEntry / _FATSetEntry
;               in kos_fs.asm Piece 3.
;
;           r5 — 6 May 2026 — VOL_SEC_PER_CLUSTER moved from byte to word
;               for consistency with surrounding word fields. The original
;               BPB byte is zero-extended on cache.
;
;           r4 — 6 May 2026 — added FS_BUF_SECTOR ($C000) and FS_BUF_FAT
;               ($C200). Two 512-byte kernel scratch buffers in page $00,
;               taken from the unused $C000..$FFFF region.
;
;           r3 — 6 May 2026 — ROM disk grown to 2 pages ($FC..$FD = 128 KB
;               = 256 sectors). Kernel code now confined to single page $FE.
;               Boot/reset in $FF. ROM disk has ~125 KB usable (251 clusters).
;
;           r2 — 6 May 2026 — ROM disk pinned to page $FC (lowest of the
;               three program-code ROM pages $FC..$FE; kernel code at $FD..$FE,
;               boot/reset at $FF). Replaces provisional $E2 placeholder.
;
;           r1 — 6 May 2026 — initial. FAT16 wire format, volume table,
;               fd table, BPB field offsets, error codes for FS layer.
;
; Purpose: All FS-internal constants live here. Top-level kos_defs.inc
;            adds only the new TRAP numbers (26..31), vector slots, FS
;            error codes, and the volume-table base address.
;
; Spec:    See kOS_FS_Reference_v1_1.md for the design rationale and the
;            full wire format. This file is the implementation-side
;            condensation.
;
; Naming convention:
;   FS_*       — high-level FS constants (block size, drive count, etc.)
;   BPB_*      — boot-sector / BIOS Parameter Block field offsets
;   DIR_*      — directory-entry field offsets and attribute bits
;   FAT_*      — FAT entry sentinel values
;   VOL_*      — volume-table slot field offsets (in page $00)
;   FD_*       — task-local file-descriptor field offsets (in task pageZ)
;   FOPEN_*    — sys_open flag bits
;
; ============================================================================

;-----------------------------------------------------------------------------
; FAT16 fundamentals
;-----------------------------------------------------------------------------
FS_BYTES_PER_SECTOR     .EQU    512             ; one block / one sector
FS_DIR_ENTRY_SIZE       .EQU    32              ; bytes per FAT16 dir entry
FS_DIR_ENTRIES_PER_SECTOR .EQU  16              ; 512 / 32
; DIRENT_INFO is the sanitised struct sys_dirent returns — DISTINCT from the
; raw FAT entry above. Part 45 grows it 32 -> 64 (8.3 fields frozen at $00..$1F,
; long name appended at $20). Forward-declared here; the zeroing loop in
; _FatEntryToInfo and the kosh ls buffer flip to this in lockstep (Phase 45.2).
DIRENT_INFO_SIZE        .EQU    64              ; bytes in the sys_dirent struct
FS_FAT_BYTES_PER_ENTRY  .EQU    2               ; FAT16: 16 bits per cluster
FS_FAT_ENTRIES_PER_SECTOR .EQU  256             ; 512 / 2

FS_MAX_DRIVES           .EQU    6               ; A: B: C: D: E: F:
FS_DRIVE_A              .EQU    0               ; ROM disk
FS_DRIVE_B              .EQU    1               ; RAM disk
FS_DRIVE_C              .EQU    2               ; host bay 0
FS_DRIVE_D              .EQU    3               ; host bay 1
FS_DRIVE_E              .EQU    4               ; host bay 2
FS_DRIVE_F              .EQU    5               ; host bay 3

FS_BOOT_SIG             .EQU    $AA55           ; boot sector signature at $1FE
FS_MEDIA_FIXED          .EQU    $F8             ; "fixed disk" media descriptor
FS_FAT0_VALUE           .EQU    $FFF8           ; FAT[0] = $FF00 | media
FS_FAT1_VALUE           .EQU    $FFFF           ; FAT[1] = end-of-chain marker

; FAT entry sentinel ranges (cluster value)
FAT_FREE                .EQU    $0000           ; cluster is free
FAT_RESERVED            .EQU    $0001           ; reserved (not used as cluster #)
FAT_BAD                 .EQU    $FFF7           ; bad cluster, do not use
FAT_EOC_MIN             .EQU    $FFF8           ; values $FFF8..$FFFF = end-of-chain

;-----------------------------------------------------------------------------
; BPB field offsets (within the boot sector buffer)
;-----------------------------------------------------------------------------
BPB_JUMP                .EQU    $00             ; 3 B  jump instruction (EB 3C 90)
BPB_OEM_NAME            .EQU    $03             ; 8 B  OEM name ("K16-KOS ")
BPB_BYTES_PER_SECTOR    .EQU    $0B             ; word
BPB_SEC_PER_CLUSTER     .EQU    $0D             ; byte
BPB_RESERVED_SECTORS    .EQU    $0E             ; word
BPB_NUM_FATS            .EQU    $10             ; byte
BPB_ROOT_ENTRIES        .EQU    $11             ; word
BPB_TOTAL_SECTORS_16    .EQU    $13             ; word (0 if total > 65535)
BPB_MEDIA               .EQU    $15             ; byte
BPB_SEC_PER_FAT         .EQU    $16             ; word
BPB_SEC_PER_TRACK       .EQU    $18             ; word (unused)
BPB_NUM_HEADS           .EQU    $1A             ; word (unused)
BPB_HIDDEN_SECTORS      .EQU    $1C             ; long
BPB_TOTAL_SECTORS_32    .EQU    $20             ; long (used if BPB_TOTAL_SECTORS_16 = 0)
BPB_DRIVE_NUM           .EQU    $24             ; byte
BPB_KOS_FLAGS           .EQU    $25             ; byte — k/OS-specific (bit 0 = read-only)
BPB_EXT_BOOT_SIG        .EQU    $26             ; byte ($29)
BPB_VOLUME_ID           .EQU    $27             ; long — random at format
BPB_VOLUME_LABEL        .EQU    $2B             ; 11 B
BPB_FS_TYPE             .EQU    $36             ; 8 B  ("FAT16   ")
BPB_BOOT_CODE           .EQU    $3E             ; 448 B  (zero-filled)
BPB_SIGNATURE           .EQU    $1FE            ; word ($AA55)

; k/OS extension: BPB_KOS_FLAGS bits
BPB_KOS_RDONLY          .EQU    $01             ; volume is read-only (ROM disk)

;-----------------------------------------------------------------------------
; Directory entry field offsets (within a 32-byte entry)
;-----------------------------------------------------------------------------
DIR_NAME                .EQU    $00             ; 11 B  8.3 name, space-padded
DIR_ATTR                .EQU    $0B             ; byte  attribute bits
DIR_NT_RESERVED         .EQU    $0C             ; byte  Windows NT case flags
DIR_CREATE_TENTHS       .EQU    $0D             ; byte
DIR_CREATE_TIME         .EQU    $0E             ; word
DIR_CREATE_DATE         .EQU    $10             ; word
DIR_ACCESS_DATE         .EQU    $12             ; word
DIR_FIRST_CLUSTER_HI    .EQU    $14             ; word — always 0 for FAT16
DIR_WRITE_TIME          .EQU    $16             ; word
DIR_WRITE_DATE          .EQU    $18             ; word
DIR_FIRST_CLUSTER_LO    .EQU    $1A             ; word — first cluster (FAT16 uses this)
DIR_FILE_SIZE           .EQU    $1C             ; long — size in bytes

; First-byte status sentinels (DIR_NAME[0])
DIR_FREE_END            .EQU    $00             ; never used; scan can stop here
DIR_FREE_REUSABLE       .EQU    $E5             ; deleted; can be reused
DIR_NAME_E5_ESCAPE      .EQU    $05             ; actual first byte is $E5

; Attribute bits (DIR_ATTR)
DIR_ATTR_READONLY       .EQU    $01
DIR_ATTR_HIDDEN         .EQU    $02
DIR_ATTR_SYSTEM         .EQU    $04
DIR_ATTR_VOLUME_LABEL   .EQU    $08
DIR_ATTR_DIRECTORY      .EQU    $10
DIR_ATTR_ARCHIVE        .EQU    $20
DIR_ATTR_LFN            .EQU    $0F             ; long-filename sentinel (= RO|HID|SYS|VOL)

; --- VFAT long-filename support (Part 45) -----------------------------------
; LFN fragments are attr-$0F entries chained physically ahead of the short
; entry, highest sequence first. See kOS_LFN_Spec for the wire format.
LFN_LAST_FLAG           .EQU    $40             ; sequence byte: last logical entry
LFN_SEQ_MASK            .EQU    $1F             ; sequence byte: ordinal bits (1..N)
LFN_MAX                 .EQU    31              ; max usable long-name chars (+ nul)
LFN_CHARS_PER_ENT       .EQU    13              ; 5 + 6 + 2 UTF-16LE chars per fragment

; Composite mask: skip-in-iteration if any of these bits set
DIR_ATTR_SKIP_MASK      .EQU    $08             ; volume label only (LFN tested via ==$0F)

;-----------------------------------------------------------------------------
; sys_open flags (D0 input)
;-----------------------------------------------------------------------------
FOPEN_READ              .EQU    $0001           ; bit 0
FOPEN_WRITE             .EQU    $0002           ; bit 1
FOPEN_CREATE            .EQU    $0004           ; bit 2
FOPEN_TRUNC             .EQU    $0008           ; bit 3
FOPEN_APPEND            .EQU    $0010           ; bit 4
FOPEN_EXCL              .EQU    $0020           ; bit 5 — reserved

;-----------------------------------------------------------------------------
; Volume table — lives in page $00, six 64-byte slots
;-----------------------------------------------------------------------------
; Six 64-byte slots = 384 bytes, $0260..$03DF.
;
; Slot layout:
;   $0260..$029F    A: (drive 0)  ROM disk
;   $02A0..$02DF    B: (drive 1)  RAM disk
;   $02E0..$031F    C: (drive 2)  host bay 0
;   $0320..$035F    D: (drive 3)  host bay 1
;   $0360..$039F    E: (drive 4)  host bay 2
;   $03A0..$03DF    F: (drive 5)  host bay 3
;
; FAT cache follows at $03E0..$03EF.
; Sem pool follows at $0400..$047F (see kos_sem.asm).
;-----------------------------------------------------------------------------
VOL_SLOT_SIZE           .EQU    64              ; bytes per slot (value)

; Six 64-byte volume slots (base + drive * VOL_SLOT_SIZE). Slot bases are
; region fields; the VS_* field offsets stay .EQU (0-based, used as
; SLOT + offset). Region gives collision + overlap (incl. cross-file vs the
; heap scratch that historically collided here - Gotcha 4.43).
; --- Address space (.SPACE): this file's regions are 'kernel'-owned ---
.SPACE kernel

VOLTABLE                .REGION $0260
  VOL_SLOT_A              .RS VOL_SLOT_SIZE   ; $0260  drive A
  VOL_SLOT_B              .RS VOL_SLOT_SIZE   ; $02A0  drive B
  VOL_SLOT_C              .RS VOL_SLOT_SIZE   ; $02E0  drive C
  VOL_SLOT_D              .RS VOL_SLOT_SIZE   ; $0320  drive D
  VOL_SLOT_E              .RS VOL_SLOT_SIZE   ; $0360  drive E
  VOL_SLOT_F              .RS VOL_SLOT_SIZE   ; $03A0  drive F
                .ENDREGION  ; VOLTABLE_END=$03E0  VOLTABLE_SIZE=$180

VOL_TABLE_BASE          .EQU    VOLTABLE_START  ; $0260 (compat; == VOL_SLOT_A)
VOL_TABLE_END           .EQU    VOLTABLE_END    ; $03E0 (compat; one past last)

; Volume-slot field offsets (relative to slot base)
VOL_PRESENT             .EQU    $00             ; byte — 1 = mounted, 0 = empty
VOL_READONLY            .EQU    $01             ; byte — cached from BPB_KOS_FLAGS
VOL_BYTES_PER_SECTOR    .EQU    $02             ; word — cached BPB
VOL_SEC_PER_CLUSTER     .EQU    $04             ; word (BPB byte zero-extended on cache)
VOL_RESERVED_SECTORS    .EQU    $06             ; word — typically 1
VOL_FAT_START           .EQU    $08             ; word — first FAT sector
VOL_SEC_PER_FAT         .EQU    $0A             ; word
VOL_ROOT_START          .EQU    $0C             ; word — first root-dir sector
VOL_ROOT_ENTRIES        .EQU    $0E             ; word — usually 32
VOL_DATA_START          .EQU    $10             ; word — first data sector
VOL_TOTAL_SECTORS       .EQU    $12             ; long
VOL_TOTAL_CLUSTERS      .EQU    $16             ; long — computed at mount
VOL_BLOCKREAD_PTR       .EQU    $1A             ; long — _BlockRead handler (24-bit + pad)
VOL_BLOCKWRITE_PTR      .EQU    $1E             ; long — _BlockWrite handler (0 if r/o)
VOL_LABEL               .EQU    $22             ; 11 B — cached volume label
VOL_RESERVED_2          .EQU    $2D             ; 3 B  (reserved)
VOL_FREE_CLUSTERS       .EQU    $30             ; word — cached free count (live only when VOL_FREE_VALID<>0)
VOL_FREE_VALID          .EQU    $32             ; word — 0=stale/unknown, 1=cache live (low byte; word for mode-01 access)
VOL_RESERVED_3          .EQU    $34             ; 12 B (reserved/scratch)

;-----------------------------------------------------------------------------
; Per-task file descriptor table — task page-zero
;-----------------------------------------------------------------------------
; FD_TABLE lives at $000C..$007B in each task's page-zero. 8 fds × 14 bytes.
; Fields are private to each task.
; Part 44 (16 June 2026): slot grew 12 -> 14 bytes. Added FD_DIR_CLUSTER so
; close-time _FdFlushDirent can re-establish DIR_WALK_CLU and convert the
; dirent cookie's sec_off -> absolute sector via _DirSecToAbs (the cookie is
; directory-relative; the old VOL_ROOT_START+sec_off was root-only and wrote
; a subdir file's size/first-cluster to the wrong sector). Task page is clear
; from $006C upward (kosh task slots start $6000; the $006C-range VEC_* are
; kernel-page, a different page), so the table may grow to $007C safely.
;-----------------------------------------------------------------------------
FD_TABLE                .EQU    $000C           ; first byte of fd table (task pageZ)
FD_COUNT                .EQU    8               ; max open files per task
FD_ENTRY_SIZE           .EQU    14              ; bytes per fd entry (Part 44: was 12)
FD_TABLE_END            .EQU    $007C           ; one past last byte (Part 44: was $006C)

; FD entry field offsets (relative to FD_TABLE + fd*FD_ENTRY_SIZE)
FD_FLAGS                .EQU    $00             ; byte
FD_DRIVE                .EQU    $01             ; byte (0..2)
FD_FIRST_CLUSTER        .EQU    $02             ; word
FD_CURR_CLUSTER         .EQU    $04             ; word — cached for sequential I/O
FD_RESERVED             .EQU    $06             ; word
FD_DIR_COOKIE           .EQU    $06             ; word (Piece 5 alias for FD_RESERVED;
                                                ;       caches dirent cookie for close-time flush)
FD_POSITION             .EQU    $08             ; long — current byte offset (ends $0B)
FD_DIR_CLUSTER          .EQU    $0C             ; word (Part 44) — cluster of the directory
                                                ;       holding this file's dirent (0 = root).
                                                ;       Restores DIR_WALK_CLU at flush time so
                                                ;       the cookie resolves in the right dir.

; FD_FLAGS bits
FD_FLAG_OPEN            .EQU    $01             ; entry is in use
FD_FLAG_READ            .EQU    $02             ; readable
FD_FLAG_WRITE           .EQU    $04             ; writable
FD_FLAG_DIRTY           .EQU    $08             ; metadata needs flushing on close
FD_FLAG_ROM             .EQU    $80             ; backing volume is read-only

;-----------------------------------------------------------------------------
; Cluster numbering rules
;-----------------------------------------------------------------------------
; FAT16 reserves cluster numbers 0 and 1. Real data clusters start at 2.
; Cluster N's first data sector = data_start + (N - 2) * sec_per_cluster.
;-----------------------------------------------------------------------------
CLUSTER_FIRST_VALID     .EQU    2

;-----------------------------------------------------------------------------
; Path-parser limits
;-----------------------------------------------------------------------------
PATH_MAX_LEN            .EQU    15              ; "X:NNNNNNNN.EEE" + nul
NAME_MAX_BASE           .EQU    8               ; 8.3 base
NAME_MAX_EXT            .EQU    3               ; 8.3 extension
NAME_BUF_LEN            .EQU    11              ; raw 11-byte FAT name field

;-----------------------------------------------------------------------------
; sys_exec specifics
;-----------------------------------------------------------------------------
; Phase 16 recognises only ".COM" as an executable extension. Match is
; case-insensitive (filenames are uppercased on dir lookup anyway).
;-----------------------------------------------------------------------------
EXEC_EXT_COM_C          .EQU    $43             ; 'C'
EXEC_EXT_COM_O          .EQU    $4F             ; 'O'
EXEC_EXT_COM_M          .EQU    $4D             ; 'M'

;-----------------------------------------------------------------------------
; RAM-disk and ROM-disk physical layout (page bytes)
;-----------------------------------------------------------------------------
; RAM disk B: occupies a fixed range of pages at the top of user-page space.
; Sliding window per host:
;   Digital — RAM disk uses pages $1C..$1F (4 pages = 256 KB = 512 sectors)
;   EMU     — RAM disk uses pages $30..$3F (16 pages = 1 MB = 2048 sectors)
;
; ROM disk A: lives in the K16 program-code ROM region. Pages $FC..$FD are
; dedicated to the ROM disk; kernel program code lives in $FE (single 64 KB
; page); boot/reset in $FF. ROM disk = 2 pages = 128 KB = 256 sectors.
; Built at compile time by an external tool (mkromdisk); FS code only reads
; from it.
;-----------------------------------------------------------------------------
RAMDISK_PAGE_BASE_DIGITAL .EQU $1C
RAMDISK_PAGE_END_DIGITAL  .EQU $1F             ; inclusive
RAMDISK_PAGES_DIGITAL     .EQU 4
RAMDISK_SECTORS_DIGITAL   .EQU 512             ; 4 pages × 128 sectors

RAMDISK_PAGE_BASE_EMU     .EQU $30
RAMDISK_PAGE_END_EMU      .EQU $3F             ; inclusive
RAMDISK_PAGES_EMU         .EQU 16
RAMDISK_SECTORS_EMU       .EQU 2048            ; 16 pages × 128 sectors

ROMDISK_PAGE_BASE         .EQU $FC             ; first ROM page hosting A:
ROMDISK_PAGE_END          .EQU $FD             ; inclusive — last ROM page
ROMDISK_PAGES             .EQU 2
ROMDISK_SECTORS           .EQU 256             ; 2 pages × 128 sectors

; Convenience: sectors per page = 64KB / 512 = 128
SECTORS_PER_PAGE          .EQU 128

;-----------------------------------------------------------------------------
; FS scratch buffers — kernel work area
;-----------------------------------------------------------------------------
; Two 512-byte buffers in page $00, sitting just below the kernel stack
; region. Kernel-only — used by mount, format, and the FAT/dir layers as
; scratch space for one sector at a time. Always accessed via LOADZ /
; STOREZ or with Y=$00 explicitly. Both 512-byte aligned (sector boundary).
;
;   FS_BUF_SECTOR : 512 B at $BC00  — generic sector buffer (BPB read,
;                                     directory sector, data scratch)
;   FS_BUF_FAT    : 512 B at $BE00  — FAT sector cache (Phase 16.3)
;
; The kernel stack region begins at $C000 and grows down from $FFFE, so
; these buffers are safely separated from stack growth.
;-----------------------------------------------------------------------------
FSBUFS                    .REGION $BC00
  FS_BUF_SECTOR             .RS 256w  ; $BC00 512 B sector buffer
  FS_BUF_FAT                .RS 256w  ; $BE00 512 B FAT sector cache
                .ENDREGION  ; FSBUFS_END=$C000  FSBUFS_SIZE=$400
FS_BUF_SECTOR_END         .EQU FS_BUF_FAT   ; $BE00 (compat; == FS_BUF_FAT)
FS_BUF_FAT_END            .EQU FSBUFS_END   ; $C000 (compat; kernel stack base)

;-----------------------------------------------------------------------------
; FAT cache state — page $00
;-----------------------------------------------------------------------------
; A single-sector cache for the FAT region. _FATGetEntry / _FATSetEntry
; populate it on first access; subsequent access to the same FAT sector
; (typical during a scan or chain walk) hits the cache.
;
;   FAT_CACHE_SECTOR : word — absolute sector number currently cached
;                             ($FFFF = no sector cached / cache invalid)
;   FAT_CACHE_DIRTY  : byte — non-zero if the cache must be flushed
;                             back before being replaced
;   FAT_CACHE_DRIVE  : byte — drive index (0..2) the cache holds.
;                             A different drive forces a flush + reload.
;-----------------------------------------------------------------------------
FSCACHE                   .REGION $03E0
FAT_CACHE_SECTOR          .RS 1w                ; $03E0 word - cached sector # ($FFFF=none)
FAT_CACHE_DIRTY           .RS 1                 ; $03E2 byte - flush needed
FAT_CACHE_DRIVE           .RS 1                 ; $03E3 byte - drive index

; --- Dir cache (Part 22) ----------------------------------------------------
; Tracks what's currently in FS_BUF_SECTOR for root-directory reads. _DirNextRaw
; checks (DIR_CACHE_SECTOR, DIR_CACHE_DRIVE) before re-reading. If the next
; raw call needs the same sector on the same drive, the read is skipped — the
; data is already in FS_BUF_SECTOR.
;
; Invariant: if any code other than _DirNextRaw / _DirNext writes to
; FS_BUF_SECTOR (e.g. _TryMount reading a BPB, _DirLookup, sys_read on a file,
; _DirInsert, _DirDelete), it MUST invalidate the dir cache by calling
; _DirCacheInvalidate (or storing $FFFF to DIR_CACHE_SECTOR directly).
;
; This is a read-only cache — there's no dirty flag because _DirNextRaw never
; writes through FS_BUF_SECTOR. Modifying writes (_DirInsert, _DirDelete) read
; the sector themselves and write back via _VolBlockWrite, then explicitly
; invalidate the cache.
DIR_CACHE_SECTOR          .RS 1w                ; $03E4 word - root sector # (or $FFFF)
DIR_CACHE_DRIVE           .RS 1                 ; $03E6 byte - drive index
DIR_CACHE_PAD             .RS 1                 ; $03E7 pad (1 byte)

; --- Dirent iteration cache (Part 22) ---------------------------------------
; Used by sys_dirent. See kos_fs_fd.asm for full design notes.
;
; TODO Phase 4+: relocate to per-task TCB state when multi-task lands.
DIRENT_LAST_COOKIE        .RS 1w                ; $03E8 word - $FFFF = empty
DIRENT_LAST_INDEX         .RS 1w                ; $03EA word
DIRENT_LAST_DRIVE         .RS 1                 ; $03EC byte

; --- Subdir iteration start cluster (cluster-aware dir walk) ----------------
; Set by the caller before _DirOpen/_DirNext/_DirNextRaw/_DirLookup; read once
; per directory-sector resolve. 0 = root region (back-compat default — the
; root-only callers never touch it, and _InitFS clears it to 0). Same
; serialisation assumption as DIR_CACHE_* / DIRENT_LAST_* : kernel FS critical
; section only. Carved from the former FAT_CACHE_RESERVED 3-byte tail; $03ED
; is a 1-byte pad to keep the word at the even address $03EE.
DIR_WALK_PAD              .RS 1                 ; $03ED pad (odd address)
DIR_WALK_CLU              .RS 1w                ; $03EE word - dir start cluster; 0 = root
                          .ENDREGION  ; FSCACHE_END=$03F0  FSCACHE_SIZE=$10

; Range $03F0..$03FF page-$00 allocation:
;   $03F0..$03F3   HEAP_TID_QUERY / HEAP_RBT_REGION   (kos_defs.inc, Part 33)
;   $03F4..$03F7   DISKFREE_CLUSTER / DISKFREE_COUNT  (Part 34)
;   $03F8..$03FF   reserved free-space
;
; (Pre-Part 33 this range was POOL_NAME_BUF; removed in Part 23 with the
;  rest of the pool layer. See kOS_Reference_Manual §2.2 for the canonical
;  page-$00 map — source comments here can drift behind the manual.)

; --- Disk-free walker scratch (Part 34) -------------------------------------
; Used by _VolFreeClusters. Lets the walker call _FATGetEntry (which
; clobbers D0/D1/D2/X0/X1) without losing its cluster# / running count.
; DISKFREE_LIMIT caches the loop's upper bound (first invalid cluster #)
; so we don't reload+ADD VOL_TOTAL_CLUSTERS every iteration.
DISKFREE                  .REGION $03F4
DISKFREE_CLUSTER          .RS 1w                ; $03F4 word - current cluster #
DISKFREE_COUNT            .RS 1w                ; $03F6 word - running free count
DISKFREE_LIMIT            .RS 1w                ; $03F8 word - first invalid cluster # (cached)
                          .ENDREGION  ; DISKFREE_END=$03FA  DISKFREE_SIZE=$06

; ============================================================================
; FS Scratch slots — relocated from `.asm` source files into the defs file
; in Part 36 (18 May 2026). See kos_defs.inc "ZERO PAGE MAP — RULES" for
; the rationale. Previously declared inside kos_fs_fd.asm and kos_fs_exec.asm
; respectively, where they were easy to lose track of when the volume table
; layout changed.
; ============================================================================

; --- FD_* scratch (Part 22 — sys_open/close/read/write/dirent/etc.) ---------
; Page-$00 scratch used by Piece 5 FD-layer syscalls. Lives at $0480..$04D6.
;
; History: originally placed at $0370..$039F per a Phase 16 layout that
; predated the Part 22 volume-table expansion. The expansion grew the
; volume table from 3 slots ($0260..$031F) to 6 slots ($0260..$03DF),
; consuming the address range that FD_DIRENT_RAW had been quietly
; squatting in. Conflict surfaced as a CODE FAULT during host-disk
; mounting (Gotcha 4.25).
;
; The new range $0480..$04D6 sits in the gap between the sem pool
; ($0400..$047F) and the start of the TCB pool ($0800). Part 25 added
; FD_NAMEBUF2 ($04CC..$04D6) — extended the upper bound from $04CB.
FDSCRATCH        .REGION $0480
FD_OPEN_FLAGS    .RS 1w    ; $0480 word
FD_DRIVE_TMP     .RS 1     ; $0482 byte (packed)
FD_RESULT_TMP    .RS 1     ; $0483 byte (fd, cross-call)
FD_COOKIE_TMP    .RS 1w    ; $0484 word
FD_DIR_FIRST_CL  .RS 1w    ; $0486 word
FD_DIR_SIZE_LO   .RS 1w    ; $0488 word
FD_DIR_SIZE_HI   .RS 1w    ; $048A word
FD_COUNT_TMP     .RS 1w    ; $048C word
FD_BYTES_DONE    .RS 1w    ; $048E word
FD_USERBUF_X     .RS 1w    ; $0490 word
FD_USERBUF_Y     .RS 1w    ; $0492 word slot (low byte used)
FD_CHUNK_TMP     .RS 1w    ; $0494 word
FD_INDEX_TMP     .RS 1w    ; $0496 word
FD_PD_ABS_SEC    .RS 1w    ; $0498 word
FD_PARENT_CL     .RS 1w    ; $049A word (Part 44) - parent dir cluster from the
                              ;   resolver, carried sys_open -> _PopulateFd ->
                              ;   FD_DIR_CLUSTER. (was-free $049A..$049F gap.)

; 11-byte FAT-format name buffer (output of _ParsePath).
FD_PARENT_PAD    .RS 2w    ; $049C 4-byte was-free gap
FD_NAMEBUF       .RS 6w    ; $04A0 12 bytes (11-char FAT name + align)

; Alignment pad: FD_NAMEBUF ends at odd $04AA; $04AB unused.
; FD_DIRENT_RAW must be even-aligned because _FatEntryToInfo reads
; word fields from it (offsets $1A, $1C, $1E, $16, $18). Per Gotcha
; #30 (8 May 2026): Digital silently drops A0 on word reads at odd
; addresses; EMU permits them. Buffer at odd base would silently
; return garbage on Digital — surfaced as "BIG" file sizes in `ls`.

; 32-byte raw FAT directory-entry scratch (target of _DirNext in sys_dirent).
FD_DIRENT_RAW    .RS 16w   ; $04AC 32 bytes

; Part 25 — second 11-byte FAT-format name buffer for sys_rename.
; Holds the new name while we still need FD_NAMEBUF for the old name's
; _DirLookup. Same buffer also serves as scratch for sys_unlink's
; first-cluster save (only 2 bytes used in that case).
FD_NAMEBUF2      .RS 6w    ; $04CC 12 bytes (11-char FAT name + align)
                              ; (also: low word holds first_cluster
                              ;  during sys_unlink's chain-free step)

                 .ENDREGION  ; FDSCRATCH_END=$04D8  FDSCRATCH_SIZE=$58
FD_SCRATCH_END   .EQU FDSCRATCH_END  ; $04D8 (compat marker; unused in code)

; --- FE_* scratch (Part 22 / relocated Part 36 — sys_exec) -------------------
; Page-$00 scratch used by Piece 6 sys_exec. Lives at $04D8..$04E3.
;
; History (Gotcha 4.47, 18 May 2026): Previously placed at $03BC..$03C7,
; inside the VOL_SLOT_F range ($03A0..$03DF, established Part 22).
; FE_NEW_PAGE at $03BC was exactly slot+$1C — the page byte of F:'s
; 24-bit VOL_BLOCKREAD_PTR. Every sys_exec corrupted F:'s function
; pointer. Surfaced when `vol` (Part 34) walked F: after a `run`,
; producing CODE FAULT odd-addr fetch on the smashed pointer.
;
; This is the same root cause as Gotcha 4.25 (FD slots) and 4.43
; (HEAP slots): scratch declared in a `.asm` with a "looks free" comment,
; missed when the volume table grew.
;
; The new range $04D8..$04E3 sits immediately after FD scratch ($04D7),
; well clear of the volume table. Even-aligned for word stores.
FESCRATCH        .REGION $04D8
FE_NEW_PAGE      .RS 1w    ; $04D8 word slot (low byte = allocated user page)
                              ; $04D9 — pad (preserves even alignment of next word)
FE_FLAGS         .RS 1w    ; $04DA word - sys_exec input flags
FE_DEST_OFF      .RS 1w    ; $04DC word - current copy destination offset
FE_BYTES_LEFT    .RS 1w    ; $04DE word - bytes still to copy
FE_CURR_CL       .RS 1w    ; $04E0 word - cluster currently being copied
FE_CHUNK_TMP     .RS 1w    ; $04E2 word - chunk size scratch

                 .ENDREGION  ; FESCRATCH_END=$04E4  FESCRATCH_SIZE=$0C
FE_SCRATCH_END   .EQU FESCRATCH_END  ; $04E4 (compat marker)

; --- Path resolver scratch (Phase 1 path resolution) ------------------------
; Used by _Resolve / _ResolveParent / _BuildPath / _ScanForCluster and the
; sys_resolve / sys_pwd / sys_mkdir(option-b) syscalls. Kernel page-$00,
; sits above the FE block in the previously-free $04E4..$07FF region.
; Not reentrant — resolver runs inside a single DINT'd syscall.
RVSCRATCH        .REGION $04E4
RV_PATH_X        .RS 1w    ; $04E4 word - user-page path pointer, X (offset)
RV_PATH_Y        .RS 1     ; byte - user-page path pointer, Y (page)
RV_DRIVE         .RS 1     ; byte - working drive index
RV_CLU           .RS 1w    ; word - working directory cluster (0 = root)
RV_ATTR          .RS 1w    ; word - attr of the current cluster's entry
RV_MODE          .RS 1w    ; word - 0 = full, 1 = parent (leaf -> RV_FATNAME)
RV_COMP          .RS 16w   ; 32 B - one extracted path component (ASCIIZ)   (ends $050D)
RV_FATNAME       .RS 6w    ; 12 B - component as 11-byte FAT name (+pad)
RV_SAVE_DRIVE    .RS 1     ; byte - caller drive saved across subcalls
RV_SAVE_PAD      .RS 1     ; pad
; pwd reconstruction:
RV_CHAIN         .RS 16w   ; 32 B - up to 16 ancestor clusters (words)
RV_CHAIN_DEPTH   .RS 1w    ; word - number of clusters collected
RV_TARGET        .RS 1w    ; word - cluster being name-searched
RV_PWD_X         .RS 1w    ; word - pwd dest pointer X
RV_PWD_Y         .RS 1     ; byte - pwd dest pointer Y
RV_PWD_PAD       .RS 1     ; pad
RV_PWD_FIRST     .EQU RV_PWD_PAD  ; $0543 alias - byte - _BuildPath: 0 until a path component is emitted
RV_NAMEBUF       .RS 7w    ; 14 B - a recovered 8.3 name (ASCIIZ, +pad)
RV_DIRENT_RAW    .RS 16w   ; 32 B - _DirNextRaw dest for _ScanForCluster
MKD_PARENT_CL    .RS 1w    ; word - sys_mkdir parent cluster (own slot)
DIRENT_LAST_CLU  .RS 1w    ; word - dirent iteration cache: last start cluster
                 .ENDREGION  ; RVSCRATCH_END=$0576  RVSCRATCH_SIZE=$92
RV_SCRATCH_END   .EQU RVSCRATCH_END  ; $0576 (compat; unused in code)

; --- sys_rename scratch (Part 44) -------------------------------------------
; _RenameFile resolves BOTH path parents and must hold the shared CWD context
; across the two _ResolveParent calls (which clobber D0/D1/D2), plus the
; old-path's parent cluster to compare against the new-path's parent (rename
; is an in-place name overwrite, so both must live in the same directory).
RNMSCRATCH       .REGION $0576
RNM_CWD_CLU      .RS 1w    ; $0576 word - CWD start cluster (both resolves)
RNM_CWD_DRV      .RS 1w    ; $0578 word - CWD start drive index (both resolves)
RNM_PARENT_CL    .RS 1w    ; $057A word - old-path parent cluster (compare vs new)
                 .ENDREGION  ; RNMSCRATCH_END=$057C  RNMSCRATCH_SIZE=$06
RNM_SCRATCH_END  .EQU RNMSCRATCH_END  ; $057C (compat)

; --- VFAT long-filename scratch (Part 45) -----------------------------------
; FS-critical-section serialised, same single-task assumption as DIR_CACHE_* /
; DIRENT_LAST_*. Read side: LFN_ASM/LEN/EXP_* assemble + validate a long name
; during a directory walk. Write side: LFN_SHORT stages the generated 8.3 name,
; LFN_FRAG formats one on-disk fragment before the sector RMW.
LFNSCRATCH       .REGION $057C
LFN_ASM          .RS 16w   ; $057C 32 B - long-name assembly buffer
LFN_ASM_LEN      .RS 1w    ; $059C word - assembled length; 0 = none this run
LFN_EXP_SEQ      .RS 1w    ; $059E word - expected next sequence ordinal
LFN_EXP_SUM      .RS 1w    ; $05A0 word - checksum captured from fragments
LFN_SHORT        .RS 6w    ; $05A2 12 B slot - generated 8.3 short name (11 + align)
;                  $059D pad  (odd-align filler)
LFN_FRAG         .RS 16w   ; $05AE 32 B - one on-disk fragment formatted
                 .ENDREGION  ; LFNSCRATCH_END=$05CE  LFNSCRATCH_SIZE=$52
LFN_SCRATCH_END  .EQU LFNSCRATCH_END  ; $05CE (compat)

; --- Short-name generator scratch (Phase 45.5) ------------------------------
; _GenShortName / _GenShortDerive / _GenShortTilde overlay the fragment buffer:
; the short name is fully generated (into LFN_SHORT) BEFORE _DirCreate formats
; any on-disk fragment, so LFN_FRAG is free during generation. GENSN_SRC holds
; the derived lossy 8.3 (base+ext) that the ~N loop re-tilde's each iteration;
; GENSN_DRV stashes the drive across derive/tilde (both clobber D3).
GENSN_SRC        .EQU LFN_FRAG+0   ; 11 B derived base+ext (FAT fmt)      ($05AE)
GENSN_LOSSY      .EQU LFN_FRAG+11  ; byte  derive-local lossy flag        ($05B9)
GENSN_LASTDOT    .EQU LFN_FRAG+12  ; word  ext-separator offset / $FFFF   ($05BA)
GENSN_LEN        .EQU LFN_FRAG+14  ; word  stripped source length         ($05BC)
TILDE_DIG        .EQU LFN_FRAG+16  ; 3 B   decimal digits of N            ($05BE)
GENSN_DRV        .EQU LFN_FRAG+20  ; byte  drive stash across derive/tilde ($05C2)

; --- Named-volume / assign table (named drives v2) --------------------------
; Unified assign table: 32 entries x 16 B, kernel page-$00 ($05CE..$07CD).
; A "named volume" (ROM:/RAM:) = entry with AS_ROOTCLU = 0 (aliases a backend
; root). A "path-mount/assign" (FONTS:) = AS_ROOTCLU <> 0 (into a subdir).
; Same struct, same resolution: an entry supplies (drive, start-cluster) to
; _ResolveCore exactly as an "X:" prefix does — no sys_resolve ABI change.
; Names >= 2 chars, UPPER; drive letters are exactly 1 char, so the two
; namespaces never overlap. Cold path (scanned only on a NAME: prefix) ->
; plain LOADZ/STOREZ, no LOADP plumbing.
AS_MAX           .EQU 32      ; entries (2 locked seeds ROM:/RAM: + user assigns)
AS_ENTRY_SIZE    .EQU 16      ; bytes per entry (AS_MAX*16 = 512 -> ends $07CE)
ASSIGNTABLE      .REGION $05CE
  AS_TABLE_BASE    .RS AS_MAX * AS_ENTRY_SIZE  ; $05CE  32 entries x 16 B = 512
                 .ENDREGION  ; ASSIGNTABLE_END=$07CE  ASSIGNTABLE_SIZE=$200
; entry fields (relative to entry base; base always even)
AS_NAME          .EQU $00     ; 11 B ASCIIZ, UPPER (VOL_LABEL-width mirror)
;                $0B  pad (name ends $0A)
AS_DRVFLAGS      .EQU $0C     ; word — low byte = drive, high byte = flags
AS_DRIVE         .EQU $0C     ; byte alias (low)  — backing drive index
AS_FLAGS         .EQU $0D     ; byte alias (high) — see AS_FLAG_* bits
AS_ROOTCLU       .EQU $0E     ; word — 0 = alias backend root; else mount cluster
AS_TABLE_END     .EQU ASSIGNTABLE_END  ; $07CE (compat; one past last)

; AS_FLAGS bits
AS_FLAG_LOCKED   .EQU $01     ; system seed (ROM:/RAM:) — assign/relabel refuse
AS_FLAG_READONLY .EQU $02     ; backing volume is read-only (cached)
AS_FLAG_DIRTY    .EQU $04     ; backing dir was deleted/formatted -> resolve fails

; assign-resolution scratch
ASGNSCRATCH      .REGION $07CE
AS_CAND          .RS 6w    ; $07CE 12 B - NAME: prefix candidate (ASCIIZ scan buf)

; sys_assign argument stash (page-$00; survives _SlotForName's clobbers)
ASGN_OP          .RS 1     ; $07DA byte (packed) - 0 = set, 1 = clear
ASGN_DRV         .RS 1     ; $07DB byte (packed) - backing drive
ASGN_FLAGS       .RS 1w    ; $07DC word slot (low byte = AS_FLAGS; $07DD pad)
ASGN_CLU         .RS 1w    ; $07DE word - backing cluster (0 = volume alias)
                 .ENDREGION  ; ASGNSCRATCH_END=$07E0  ASGNSCRATCH_SIZE=$12

; --- sys_exec argv-tail offset (Part 15) ------------------------------------
; One word carrying the caller-page offset of the command tail from sys_exec
; entry (captured before helpers clobber XY1) to the post-_AllocPage stamp
; into child:$0100. Placed at the old free-growth base $07E0 - zero drift, no
; shift of RVSCRATCH or any prior region.
EXARGSCRATCH     .REGION $07E0
FE_ARGV_OFF      .RS 1w    ; $07E0 word - caller-page arg-tail offset (0 = none)
FE_CWD_DRIVE     .RS 1w    ; $07E2 word - sys_exec inherited CWD drive (Part 16)
FE_CWD_CLU       .RS 1w    ; $07E4 word - sys_exec inherited CWD cluster (Part 16)
                 .ENDREGION  ; EXARGSCRATCH_END=$07E6  EXARGSCRATCH_SIZE=$06

; --- .COM header staging (Part 60) ------------------------------------------
; sys_exec must know the page count BEFORE it allocates, and allocation
; precedes the copy - so it cannot read the header back from the loaded page.
; It reads the image's first sector into FS_BUF_SECTOR and parses the header
; up front (_ExecReadHeader); these two words carry the parsed values across
; _AllocPageRun to the BT_* staging block.
;
; Placed at the old free-growth base $07E6 - zero drift, no shift of
; EXARGSCRATCH or any prior region.
COMHDRSCRATCH    .REGION $07E6
FE_PAGES         .RS 1w    ; $07E6 word - total pages declared by the header
FE_HEAPPG        .RS 1w    ; $07E8 word - heap pages (a partition of FE_PAGES)
                 .ENDREGION  ; COMHDRSCRATCH_END=$07EA  COMHDRSCRATCH_SIZE=$04

; --- Next free byte in kernel page-$00 --------------------------------------
; Bump this when adding a new allocation block. Update the layout map in
; kos_defs.inc in the same commit.
KERNEL_ZP_NEXT_FREE   .EQU $07EA   ; assign table $05CE..$07CD, AS_CAND $07CE..$07D9, ASGN_* $07DA..$07DF, FE_ARGV_OFF $07E0..$07E1, FE_CWD_* $07E2..$07E5, FE_PAGES/FE_HEAPPG $07E6..$07E9
KERNEL_ZP_RESERVED_END .EQU $0800  ; TCB pool starts here

FAT_CACHE_INVALID         .EQU $FFFF             ; sentinel for "no sector"

;-----------------------------------------------------------------------------
; Pre-baked BPB constants for default formats
;-----------------------------------------------------------------------------
; A "blank" RAM disk after format. Values match Section 2.1 of the FS spec.
;-----------------------------------------------------------------------------
; EMU RAM disk (1 MB):
EMU_RAM_TOTAL_SECTORS   .EQU 2048
EMU_RAM_FAT_SECTORS     .EQU 8                  ; 2048 entries × 2 B / 512 = 8
EMU_RAM_ROOT_SECTORS    .EQU 2                  ; 32 entries × 32 B / 512 = 2
EMU_RAM_DATA_START      .EQU 11                 ; 1 (boot) + 8 (FAT) + 2 (root)
EMU_RAM_DATA_CLUSTERS   .EQU 2037               ; 2048 - 11

; Digital RAM disk (256 KB):
DIG_RAM_TOTAL_SECTORS   .EQU 512
DIG_RAM_FAT_SECTORS     .EQU 2
DIG_RAM_ROOT_SECTORS    .EQU 2
DIG_RAM_DATA_START      .EQU 5                  ; 1 + 2 + 2
DIG_RAM_DATA_CLUSTERS   .EQU 507                ; 512 - 5

; ROM disk (128 KB, generated by external tool):
ROM_TOTAL_SECTORS       .EQU 256
ROM_FAT_SECTORS         .EQU 2                 ; 256 entries fit in 1 sec; 2 for headroom
ROM_ROOT_SECTORS        .EQU 2
ROM_DATA_START          .EQU 5
ROM_DATA_CLUSTERS       .EQU 251               ; 256 - 5

;-----------------------------------------------------------------------------
; Disk controller — MMIO map (Part 22)
;-----------------------------------------------------------------------------
; Sits in the existing I/O range $D80000..$DFFFFF alongside video, keyboard,
; terminal. 24-bit absolute addresses; access via two-stage LOADI (page byte
; into Y, offset into X).
;
;   Page byte: $DA   (DSK_PAGE)
;   Offsets : $0000..$001F   (16 word-aligned register slots)
;
; The controller is a host-file backend in the EMU; on Digital it does not
; exist (RAM/ROM only). Synchronous — DSK_STATUS busy bit is always 0
; on EMU; reads of DSK_RESULT after a CMD write are immediately valid.
;-----------------------------------------------------------------------------
DSK_PAGE                .EQU    $DA             ; page byte (24-bit hi byte)

; Sector-IO registers (offsets within page $DA)
DSK_CMD                 .EQU    $0000           ; W  — sector command trigger
DSK_STATUS              .EQU    $0002           ; R  — bit 0 = busy
DSK_DRIVE               .EQU    $0004           ; RW — bay 0..3
DSK_LBA_LO              .EQU    $0006           ; RW — sector # bits 15..0
DSK_LBA_HI              .EQU    $0008           ; RW — sector # bits 23..16
DSK_BUF_LO              .EQU    $000A           ; RW — buffer addr bits 15..0
DSK_BUF_HI              .EQU    $000C           ; RW — buffer addr bits 23..16
DSK_SECCOUNT            .EQU    $000E           ; RW — sector count
DSK_RESULT              .EQU    $0010           ; R  — last command's result
DSK_FLAGS               .EQU    $0012           ; RW — present/RO/media-changed

; Host management register (Part 23 — replaces DSK_POOL_CMD).
; The MMIO offset is the same as the old DSK_POOL_CMD; the surrounding
; pool registers ($0014/$0018/$001A) are gone (read as 0). Disk metadata
; lives in the host filesystem (disk\*.KOS), not in a controller catalogue.
DSK_HOST_CMD            .EQU    $0016           ; W  — host management command

; Sector commands
CMD_NONE                .EQU    $0000
CMD_READ                .EQU    $0001
CMD_WRITE               .EQU    $0002
CMD_IDENT               .EQU    $0003
CMD_FLUSH               .EQU    $0004
CMD_FORMAT              .EQU    $0005
CMD_MEDIA               .EQU    $0006

; Host management commands (Part 23 — replace POOL_CMD_*)
HOST_CMD_NONE           .EQU    $0000
HOST_CMD_MOUNT          .EQU    $0001           ; in: BUF=name, DRIVE=bay
HOST_CMD_UNMOUNT        .EQU    $0002           ; in: DRIVE=bay
HOST_CMD_LIST           .EQU    $0003           ; in: BUF=output buffer (>=256B)
                                                ;  out: name\0bay\0name\0bay\0...\0
                                                ;       bay = $FF if not mounted
HOST_CMD_CREATE         .EQU    $0004           ; in: BUF=name, SECCOUNT=sectors
HOST_CMD_DELETE         .EQU    $0005           ; in: BUF=name
HOST_CMD_RENAME         .EQU    $0006           ; Part 24 — in: DRIVE=bay, BUF=new name
                                                ;   Renames bay's bound file; keeps mount.
HOST_CMD_BAYNAME        .EQU    $0007           ; Part 24 — in: DRIVE=bay, BUF=>=16B
                                                ;   Writes ASCIIZ basename (no .KOS).
HOST_CMD_FOPEN          .EQU    $0008           ; Part 25 r6 — in: BUF=ASCIIZ filename
                                                ;   out: SECCOUNT=size in bytes
                                                ;        RES_OK / RES_NOT_FOUND / RES_BAD_NAME
                                                ;        RES_BUSY (already open) / RES_FULL
HOST_CMD_FREAD          .EQU    $0009           ; Part 25 r6 — in: BUF=k16 dest, SECCOUNT=max
                                                ;   out: SECCOUNT=bytes read (0 = EOF)
                                                ;        RES_OK / RES_NO_MEDIA / RES_IO_ERR
HOST_CMD_FCLOSE         .EQU    $000A           ; Part 25 r6 — closes current load file
                                                ;   out: RES_OK / RES_NO_MEDIA

; Result codes (DSK_RESULT)
RES_OK                  .EQU    $0000
RES_NO_MEDIA            .EQU    $0001
RES_BAD_LBA             .EQU    $0002
RES_RO                  .EQU    $0003
RES_IO_ERR              .EQU    $0004
RES_BUSY                .EQU    $0005
RES_FULL                .EQU    $0006
RES_EXISTS              .EQU    $0007
RES_NOT_FOUND           .EQU    $0008
RES_BAD_NAME            .EQU    $0009
RES_BAD_SIZE            .EQU    $000A
RES_BAD_CMD             .EQU    $00FF

; DSK_FLAGS bits (read)
DSK_FLAG_PRESENT        .EQU    $0001
DSK_FLAG_RO             .EQU    $0002
DSK_FLAG_MEDIA_CHANGED  .EQU    $0004

; Configuration
DSK_HOST_BAY_COUNT      .EQU    4               ; bays 0..3 — slots C..F
DSK_HOST_BAY_FIRST_DRV  .EQU    2               ; first k/OS drive that maps
                                                ; to a host bay (= FS_DRIVE_C)
DSK_NAME_MAX_LEN        .EQU    16              ; basename buffer (15 + nul)
DSK_LIST_BUF_BYTES      .EQU    256             ; HOST_CMD_LIST output buf size

; ============================================================================
; End of kos_fs_defs.inc
; ============================================================================
