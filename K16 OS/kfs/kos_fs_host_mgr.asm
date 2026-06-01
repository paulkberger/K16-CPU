; ============================================================================
; kos_fs_host_mgr.asm — k/OS Parts 23–24: host-disk management helpers
; ============================================================================
; Date:    11 May 2026
; Status:  Part 25 r6 — host file load helpers added.
;
; Revision: r4 — 11 May 2026 — Part 25 r6: three new helpers wrapping
;             the file-load MMIO surface ($0008..$000A):
;               _HostFOpen   — open file in LoadFolder, returns size
;               _HostFRead   — read up to N bytes from current cursor
;               _HostFClose  — close current load file
;             Singleton state in the EMU (one file open at a time).
;             64 KB hard cap on file size. Used by kosh's `load` cmd
;             to ingest .COM files from host without unmounting the
;             destination .KOS.
;
;           r3 — 11 May 2026 — Part 24 r2: _HostBayName helper. Wraps
;             HOST_CMD_BAYNAME ($0007). Lets `format <drive>` (no
;             label) default the FAT16 label to the host filename.
;
;           r2 — 11 May 2026 — Part 24: _HostRename helper. Wraps
;             HOST_CMD_RENAME ($0006). Lets `format C: LABEL` keep the
;             host filename matching the FAT16 volume label.
;
;           r1 — 10 May 2026 — initial.
;             Five helpers wrapping the new HOST_CMD_* MMIO surface:
;               _HostMount   — open disk\<name>.KOS on a bay
;               _HostUnmount — close a bay
;               _HostList    — dump folder listing into caller's buffer
;               _HostCreate  — create disk\<name>.KOS
;               _HostDelete  — delete disk\<name>.KOS
;
; --- Why this file exists ---------------------------------------------------
; Part 22's kos_fs_disk_pool.asm wrapped a pool/catalogue layer in the EMU.
; Part 23 ripped that out: the disk\ folder IS the catalogue, and the four
; bays are the only persistent state the controller tracks. The old
; slot-vs-bay double-indexing problem (which actually bit us during Part 22
; testing as the "pool 12 invalid" bug) is gone because there's only one
; ID now: bay 0..3.
;
; --- ABI summary ------------------------------------------------------------
;
; All routines return:
;   C=0 with D0 = result data (or ERR_OK) on success
;   C=1 with D0 = ERR_IO / ERR_INVALID / ERR_NOTFOUND / ERR_EXISTS on failure
;
; Caller's k/OS drive index (FS_DRIVE_C..F) is converted to bay (0..3)
; by subtracting FS_DRIVE_C (= DSK_HOST_BAY_FIRST_DRV).
;
; --- Digital safety ---------------------------------------------------------
;
; All routines check KOS_HOST and return ERR_INVALID on Digital. The
; controller doesn't exist there; touching $DA0000 would be undefined.
;
; --- Mutex ------------------------------------------------------------------
;
; All MMIO sequences take HOST_DISK_SEM (the same mutex _BlockReadHost
; uses) so concurrent FS reads can't tear MMIO state.
;
; ============================================================================


; ============================================================================
; _HostMount — open disk\<name>.KOS on a bay
;
;   In:    XY0 = ASCIIZ name (basename, ≤ 15 chars; controller appends .KOS)
;          D0  = bay (0..3)
;   Out:   C=0 with D0 = ERR_OK on RES_OK
;          C=1 with D0 = ERR_IO on any failure
;          C=1 with D0 = ERR_INVALID on Digital
;   Clobbers: D0, D1, D2, X1, Y1, flags
;   Preserves: D3, XY0, XY2, XY3
; ============================================================================
_HostMount:
                ; Save caller's regs.
                PUSH    D3, XY3
                PUSH    XY0, XY3                ; preserve name pointer
                PUSH    D0, XY3                 ; preserve bay

                ; Digital check.
                LOADZ   D0, [#KOS_HOST]
                LOW     D0
                CMP     D0, #HOST_EMU
                BNE     .hm_nodisk

                ; Take mutex.
                LOADZ   D0, [#HOST_DISK_SEM]
                CALLR   _SemTakeBlocking
                BCS     .hm_nodisk

                ; Restore regs needed for MMIO programming.
                POP     D0, XY3                 ; D0 = bay
                POP     XY0, XY3                ; XY0 = name pointer
                ; Re-stack for cleanup at end.
                PUSH    XY0, XY3
                PUSH    D0, XY3

                LOADI   Y1, #DSK_PAGE

                ; DSK_DRIVE := bay
                LOADI   X1, #DSK_DRIVE
                STORED  D0, [XY1]

                ; DSK_BUF_LO := X0 (low 16 of name pointer)
                MOVE    D1, X0
                LOADI   X1, #DSK_BUF_LO
                STORED  D1, [XY1]

                ; DSK_BUF_HI := Y0 (page byte of name pointer)
                MOVE    D1, Y0
                LOADI   X1, #DSK_BUF_HI
                STORED  D1, [XY1]

                ; DSK_HOST_CMD := HOST_CMD_MOUNT (triggers)
                LOADI   D1, #HOST_CMD_MOUNT
                LOADI   X1, #DSK_HOST_CMD
                STORED  D1, [XY1]

                ; Read DSK_RESULT.
                LOADI   X1, #DSK_RESULT
                LOADD   D2, [XY1]               ; D2 = result code

                ; Give mutex.
                PUSH    D2, XY3                 ; preserve result across give
                LOADZ   D0, [#HOST_DISK_SEM]
                CALLR   _SemGive
                POP     D2, XY3

                ; Pop the saved bay+name (no longer needed).
                POP     D0, XY3                 ; discard saved bay
                POP     XY0, XY3                ; restore caller's XY0
                POP     D3, XY3                 ; restore caller's D3

                ; Translate result.
                CMP     D2, #RES_OK
                BNE.S   .hm_io
                LOADI   D0, #ERR_OK
                RETCC

.hm_io:
                LOADI   D0, #ERR_IO
                RETCS

.hm_nodisk:
                ; Pop pushes to balance stack. The first PUSH was D3 (still
                ; safely on stack); the second pair was XY0+D0; we may have
                ; just-failed before the second pair was popped+repushed.
                ; Easiest: discard 2 words for D0/bay, 4 bytes for XY0,
                ; 2 for D3, then reset.
                POP     D0, XY3                 ; saved bay
                POP     XY0, XY3                ; saved name
                POP     D3, XY3                 ; saved D3
                LOADI   D0, #ERR_INVALID
                RETCS


; ============================================================================
; _HostUnmount — release a bay
;
;   In:    D0  = bay (0..3)
;   Out:   C=0 with D0 = ERR_OK on RES_OK
;          C=1 with D0 = ERR_IO  on RES_NO_MEDIA (bay was empty) or other
;          C=1 with D0 = ERR_INVALID on Digital
;   Clobbers: D0, D1, D2, X1, Y1, flags
;   Preserves: D3, XY0, XY2, XY3
; ============================================================================
_HostUnmount:
                PUSH    D0, XY3                 ; saved bay

                LOADZ   D0, [#KOS_HOST]
                LOW     D0
                CMP     D0, #HOST_EMU
                BNE     .hu_nodisk

                LOADZ   D0, [#HOST_DISK_SEM]
                CALLR   _SemTakeBlocking
                BCS     .hu_nodisk

                POP     D0, XY3                 ; bay
                PUSH    D0, XY3                 ; re-stack for cleanup

                LOADI   Y1, #DSK_PAGE

                ; DSK_DRIVE := bay
                LOADI   X1, #DSK_DRIVE
                STORED  D0, [XY1]

                ; DSK_HOST_CMD := HOST_CMD_UNMOUNT
                LOADI   D1, #HOST_CMD_UNMOUNT
                LOADI   X1, #DSK_HOST_CMD
                STORED  D1, [XY1]

                ; Read DSK_RESULT.
                LOADI   X1, #DSK_RESULT
                LOADD   D2, [XY1]

                PUSH    D2, XY3
                LOADZ   D0, [#HOST_DISK_SEM]
                CALLR   _SemGive
                POP     D2, XY3

                POP     D0, XY3                 ; discard saved bay

                CMP     D2, #RES_OK
                BNE.S   .hu_io
                LOADI   D0, #ERR_OK
                RETCC

.hu_io:
                LOADI   D0, #ERR_IO
                RETCS

.hu_nodisk:
                POP     D0, XY3                 ; discard saved bay
                LOADI   D0, #ERR_INVALID
                RETCS


; ============================================================================
; _HostList — dump folder listing into caller's buffer
;
;   In:    XY0 = output buffer pointer (caller must reserve DSK_LIST_BUF_BYTES,
;                = 256 bytes)
;   Out:   C=0 with D0 = ERR_OK on RES_OK
;          Buffer filled with: name\0bay\0name\0bay\0...\0
;          where bay byte = 0..3 if mounted on that bay, else $FF.
;          Two consecutive nul bytes mark end-of-list.
;          C=1 with D0 = ERR_INVALID on Digital
;   Clobbers: D0, D1, D2, X1, Y1, flags
;   Preserves: D3, XY0, XY2, XY3
; ============================================================================
_HostList:
                PUSH    XY0, XY3                ; save buffer pointer

                LOADZ   D0, [#KOS_HOST]
                LOW     D0
                CMP     D0, #HOST_EMU
                BNE     .hl_nodisk

                LOADZ   D0, [#HOST_DISK_SEM]
                CALLR   _SemTakeBlocking
                BCS     .hl_nodisk

                POP     XY0, XY3                ; restore buffer pointer
                PUSH    XY0, XY3                ; re-stack for cleanup

                LOADI   Y1, #DSK_PAGE

                ; DSK_BUF_LO := X0
                MOVE    D1, X0
                LOADI   X1, #DSK_BUF_LO
                STORED  D1, [XY1]

                ; DSK_BUF_HI := Y0
                MOVE    D1, Y0
                LOADI   X1, #DSK_BUF_HI
                STORED  D1, [XY1]

                ; DSK_HOST_CMD := HOST_CMD_LIST
                LOADI   D1, #HOST_CMD_LIST
                LOADI   X1, #DSK_HOST_CMD
                STORED  D1, [XY1]

                ; Read DSK_RESULT.
                LOADI   X1, #DSK_RESULT
                LOADD   D2, [XY1]

                PUSH    D2, XY3
                LOADZ   D0, [#HOST_DISK_SEM]
                CALLR   _SemGive
                POP     D2, XY3

                POP     XY0, XY3                ; restore caller's XY0

                CMP     D2, #RES_OK
                BNE.S   .hl_io
                LOADI   D0, #ERR_OK
                RETCC

.hl_io:
                LOADI   D0, #ERR_IO
                RETCS

.hl_nodisk:
                POP     XY0, XY3
                LOADI   D0, #ERR_INVALID
                RETCS


; ============================================================================
; _HostCreate — create a new disk\<name>.KOS image
;
;   In:    XY0 = ASCIIZ basename (≤ 15 chars; controller appends .KOS)
;          D0  = sector count (≥ 64)
;   Out:   C=0 with D0 = ERR_OK on RES_OK
;          C=1 with D0 = ERR_IO on failure (bad name, exists, IO, etc.)
;          C=1 with D0 = ERR_INVALID on Digital
;   Clobbers: D0, D1, D2, X1, Y1, flags
;   Preserves: D3, XY0, XY2, XY3
; ============================================================================
_HostCreate:
                PUSH    D0, XY3                 ; saved sector count
                PUSH    XY0, XY3                ; saved name

                LOADZ   D0, [#KOS_HOST]
                LOW     D0
                CMP     D0, #HOST_EMU
                BNE     .hc_nodisk

                LOADZ   D0, [#HOST_DISK_SEM]
                CALLR   _SemTakeBlocking
                BCS     .hc_nodisk

                POP     XY0, XY3                ; XY0 = name
                POP     D0, XY3                 ; D0 = sectors
                ; Re-stack for cleanup.
                PUSH    D0, XY3
                PUSH    XY0, XY3

                LOADI   Y1, #DSK_PAGE

                ; DSK_BUF_LO := X0
                MOVE    D1, X0
                LOADI   X1, #DSK_BUF_LO
                STORED  D1, [XY1]

                ; DSK_BUF_HI := Y0
                MOVE    D1, Y0
                LOADI   X1, #DSK_BUF_HI
                STORED  D1, [XY1]

                ; DSK_SECCOUNT := D0 (sectors)
                LOADI   X1, #DSK_SECCOUNT
                STORED  D0, [XY1]

                ; DSK_HOST_CMD := HOST_CMD_CREATE
                LOADI   D1, #HOST_CMD_CREATE
                LOADI   X1, #DSK_HOST_CMD
                STORED  D1, [XY1]

                ; Read DSK_RESULT.
                LOADI   X1, #DSK_RESULT
                LOADD   D2, [XY1]

                PUSH    D2, XY3
                LOADZ   D0, [#HOST_DISK_SEM]
                CALLR   _SemGive
                POP     D2, XY3

                POP     XY0, XY3                ; restore caller's XY0
                POP     D0, XY3                 ; discard saved sectors

                CMP     D2, #RES_OK
                BNE.S   .hc_io
                LOADI   D0, #ERR_OK
                RETCC

.hc_io:
                LOADI   D0, #ERR_IO
                RETCS

.hc_nodisk:
                POP     XY0, XY3
                POP     D0, XY3
                LOADI   D0, #ERR_INVALID
                RETCS


; ============================================================================
; _HostDelete — delete a disk\<name>.KOS image (must not be mounted)
;
;   In:    XY0 = ASCIIZ basename (≤ 15 chars)
;   Out:   C=0 with D0 = ERR_OK on RES_OK
;          C=1 with D0 = ERR_IO on failure (still mounted, missing, etc.)
;          C=1 with D0 = ERR_INVALID on Digital
;   Clobbers: D0, D1, D2, X1, Y1, flags
;   Preserves: D3, XY0, XY2, XY3
; ============================================================================
_HostDelete:
                PUSH    XY0, XY3                ; saved name

                LOADZ   D0, [#KOS_HOST]
                LOW     D0
                CMP     D0, #HOST_EMU
                BNE     .hd_nodisk

                LOADZ   D0, [#HOST_DISK_SEM]
                CALLR   _SemTakeBlocking
                BCS     .hd_nodisk

                POP     XY0, XY3                ; XY0 = name
                PUSH    XY0, XY3

                LOADI   Y1, #DSK_PAGE

                MOVE    D1, X0
                LOADI   X1, #DSK_BUF_LO
                STORED  D1, [XY1]

                MOVE    D1, Y0
                LOADI   X1, #DSK_BUF_HI
                STORED  D1, [XY1]

                LOADI   D1, #HOST_CMD_DELETE
                LOADI   X1, #DSK_HOST_CMD
                STORED  D1, [XY1]

                LOADI   X1, #DSK_RESULT
                LOADD   D2, [XY1]

                PUSH    D2, XY3
                LOADZ   D0, [#HOST_DISK_SEM]
                CALLR   _SemGive
                POP     D2, XY3

                POP     XY0, XY3

                CMP     D2, #RES_OK
                BNE.S   .hd_io
                LOADI   D0, #ERR_OK
                RETCC

.hd_io:
                LOADI   D0, #ERR_IO
                RETCS

.hd_nodisk:
                POP     XY0, XY3
                LOADI   D0, #ERR_INVALID
                RETCS


; ============================================================================
; _HostRename — rename the file currently bound on a bay (Part 24)
;
;   The bay's stream is closed, the file is renamed on disk, then reopened.
;   The bay stays mounted with the same FAT16 state — only the host
;   filename changes. INI is updated.
;
;   In:    D0  = bay (0..3)
;          XY0 = ASCIIZ new basename (≤ 15 chars; controller appends .KOS)
;   Out:   C=0 with D0 = ERR_OK on RES_OK
;          C=1 with D0 = ERR_IO on failure (name conflict, bay empty,
;                                          OS rename denied, etc.)
;          C=1 with D0 = ERR_INVALID on Digital
;   Clobbers: D0, D1, D2, X1, Y1, flags
;   Preserves: D3, XY0, XY2, XY3
;
;   Notes:
;     • Bay must already be mounted (HostMount or boot-time INI). New
;       name must not collide with any existing disk\*.KOS file (even
;       one mounted elsewhere).
;     • Same-name no-op returns RES_OK; the caller can rely on idempotence.
;     • On failure mid-rename the EMU tries to keep the bay state sane
;       — see HostRename in emu_disk.pas for the exact recovery rules.
; ============================================================================
_HostRename:
                PUSH    D0, XY3                 ; saved bay
                PUSH    XY0, XY3                ; saved name

                LOADZ   D0, [#KOS_HOST]
                LOW     D0
                CMP     D0, #HOST_EMU
                BNE     .hr_nodisk

                LOADZ   D0, [#HOST_DISK_SEM]
                CALLR   _SemTakeBlocking
                BCS     .hr_nodisk

                POP     XY0, XY3                ; XY0 = name
                POP     D0, XY3                 ; D0 = bay
                ; Re-stack for cleanup.
                PUSH    D0, XY3
                PUSH    XY0, XY3

                LOADI   Y1, #DSK_PAGE

                ; DSK_DRIVE := bay
                LOADI   X1, #DSK_DRIVE
                STORED  D0, [XY1]

                ; DSK_BUF_LO := X0
                MOVE    D1, X0
                LOADI   X1, #DSK_BUF_LO
                STORED  D1, [XY1]

                ; DSK_BUF_HI := Y0
                MOVE    D1, Y0
                LOADI   X1, #DSK_BUF_HI
                STORED  D1, [XY1]

                ; DSK_HOST_CMD := HOST_CMD_RENAME
                LOADI   D1, #HOST_CMD_RENAME
                LOADI   X1, #DSK_HOST_CMD
                STORED  D1, [XY1]

                ; Read DSK_RESULT.
                LOADI   X1, #DSK_RESULT
                LOADD   D2, [XY1]

                PUSH    D2, XY3
                LOADZ   D0, [#HOST_DISK_SEM]
                CALLR   _SemGive
                POP     D2, XY3

                POP     XY0, XY3                ; restore caller's XY0
                POP     D0, XY3                 ; discard saved bay

                CMP     D2, #RES_OK
                BNE.S   .hr_io
                LOADI   D0, #ERR_OK
                RETCC

.hr_io:
                LOADI   D0, #ERR_IO
                RETCS

.hr_nodisk:
                POP     XY0, XY3
                POP     D0, XY3
                LOADI   D0, #ERR_INVALID
                RETCS


; ============================================================================
; _HostBayName — query the basename of the file bound to a bay (Part 24)
;
;   Writes the bay's bound filename (no extension) into the caller's
;   buffer as ASCIIZ. Used by kosh's `format <drive>` (no label) to
;   default the FAT16 label to the host filename so the two stay in sync.
;
;   In:    D0  = bay (0..3)
;          XY0 = output buffer pointer (must reserve ≥ 16 bytes)
;   Out:   C=0 with D0 = ERR_OK on RES_OK; buffer holds ASCIIZ basename
;          C=1 with D0 = ERR_IO when bay empty (buffer[0] = nul)
;          C=1 with D0 = ERR_INVALID on Digital
;   Clobbers: D0, D1, D2, X1, Y1, flags
;   Preserves: D3, XY0, XY2, XY3
; ============================================================================
_HostBayName:
                PUSH    D0, XY3                 ; saved bay
                PUSH    XY0, XY3                ; saved buf ptr

                LOADZ   D0, [#KOS_HOST]
                LOW     D0
                CMP     D0, #HOST_EMU
                BNE     .hbn_nodisk

                LOADZ   D0, [#HOST_DISK_SEM]
                CALLR   _SemTakeBlocking
                BCS     .hbn_nodisk

                POP     XY0, XY3                ; XY0 = buf ptr
                POP     D0, XY3                 ; D0 = bay
                PUSH    D0, XY3
                PUSH    XY0, XY3

                LOADI   Y1, #DSK_PAGE

                ; DSK_DRIVE := bay
                LOADI   X1, #DSK_DRIVE
                STORED  D0, [XY1]

                ; DSK_BUF_LO := X0
                MOVE    D1, X0
                LOADI   X1, #DSK_BUF_LO
                STORED  D1, [XY1]

                ; DSK_BUF_HI := Y0
                MOVE    D1, Y0
                LOADI   X1, #DSK_BUF_HI
                STORED  D1, [XY1]

                ; DSK_HOST_CMD := HOST_CMD_BAYNAME
                LOADI   D1, #HOST_CMD_BAYNAME
                LOADI   X1, #DSK_HOST_CMD
                STORED  D1, [XY1]

                ; Read DSK_RESULT.
                LOADI   X1, #DSK_RESULT
                LOADD   D2, [XY1]

                PUSH    D2, XY3
                LOADZ   D0, [#HOST_DISK_SEM]
                CALLR   _SemGive
                POP     D2, XY3

                POP     XY0, XY3
                POP     D0, XY3

                CMP     D2, #RES_OK
                BNE.S   .hbn_io
                LOADI   D0, #ERR_OK
                RETCC

.hbn_io:
                LOADI   D0, #ERR_IO
                RETCS

.hbn_nodisk:
                POP     XY0, XY3
                POP     D0, XY3
                LOADI   D0, #ERR_INVALID
                RETCS


; ============================================================================
; _HostFOpen — open a host file from LoadFolder for reading (Part 25 r6)
;
;   In:    XY0 = ASCIIZ filename (in caller's task page; no path components)
;   Out:   C=0 with D0 = file size in bytes (0..65535)
;          C=1 with D0 = ERR_NOTFOUND (file doesn't exist in LoadFolder)
;          C=1 with D0 = ERR_INVALID  (bad name, or Digital target)
;          C=1 with D0 = ERR_IO       (already open / too large / other)
;   Clobbers: D0, D1, D2, X1, Y1, flags
;   Preserves: D3, XY0, XY2, XY3
;
;   At most one file can be open at a time across the whole controller
;   (singleton state in the EMU). Caller MUST call _HostFClose before
;   another _HostFOpen, or this returns ERR_IO.
;
;   The 64 KB file-size cap is enforced EMU-side; files larger than that
;   are rejected with ERR_IO at open time.
; ============================================================================
_HostFOpen:
                PUSH    D3, XY3
                PUSH    XY0, XY3                ; preserve name pointer

                LOADZ   D0, [#KOS_HOST]
                LOW     D0
                CMP     D0, #HOST_EMU
                BNE     .hfo_nodisk

                LOADZ   D0, [#HOST_DISK_SEM]
                CALLR   _SemTakeBlocking
                BCS     .hfo_nodisk

                POP     XY0, XY3                ; XY0 = name pointer
                PUSH    XY0, XY3

                LOADI   Y1, #DSK_PAGE

                ; DSK_BUF_LO := X0
                MOVE    D1, X0
                LOADI   X1, #DSK_BUF_LO
                STORED  D1, [XY1]

                ; DSK_BUF_HI := Y0
                MOVE    D1, Y0
                LOADI   X1, #DSK_BUF_HI
                STORED  D1, [XY1]

                ; DSK_HOST_CMD := HOST_CMD_FOPEN
                LOADI   D1, #HOST_CMD_FOPEN
                LOADI   X1, #DSK_HOST_CMD
                STORED  D1, [XY1]

                ; Read SECCOUNT (= file size) before RESULT, since result
                ; translation may overwrite D2.
                LOADI   X1, #DSK_SECCOUNT
                LOADD   D1, [XY1]               ; D1 = file size

                ; Read DSK_RESULT.
                LOADI   X1, #DSK_RESULT
                LOADD   D2, [XY1]               ; D2 = result code

                ; Release mutex; preserve size + result across the call.
                PUSH    D1, XY3
                PUSH    D2, XY3
                LOADZ   D0, [#HOST_DISK_SEM]
                CALLR   _SemGive
                POP     D2, XY3
                POP     D1, XY3

                ; Discard saved name pointer + restore caller's D3.
                POP     XY0, XY3
                POP     D3, XY3

                ; Translate result code.
                CMP     D2, #RES_OK
                BNE     .hfo_check_err
                MOVE    D0, D1                  ; D0 = file size
                RETCC

.hfo_check_err:
                CMP     D2, #RES_NOT_FOUND
                BNE.S   .hfo_check_badname
                LOADI   D0, #ERR_NOTFOUND
                RETCS
.hfo_check_badname:
                CMP     D2, #RES_BAD_NAME
                BNE.S   .hfo_io
                LOADI   D0, #ERR_INVALID
                RETCS
.hfo_io:
                ; RES_BUSY / RES_FULL / RES_IO_ERR / anything else → ERR_IO.
                LOADI   D0, #ERR_IO
                RETCS

.hfo_nodisk:
                POP     XY0, XY3
                POP     D3, XY3
                LOADI   D0, #ERR_INVALID
                RETCS


; ============================================================================
; _HostFRead — read up to D0 bytes from the open load file (Part 25 r6)
;
;   In:    XY0 = destination buffer (in caller's task page)
;          D0  = max bytes to read (caller's buffer size; 0 valid no-op)
;   Out:   C=0 with D0 = bytes actually read (0 = EOF)
;          C=1 with D0 = ERR_INVALID (Digital)
;          C=1 with D0 = ERR_IO      (no file open / read error)
;   Clobbers: D0, D1, D2, X1, Y1, flags
;   Preserves: D3, XY0, XY2, XY3
; ============================================================================
_HostFRead:
                PUSH    D3, XY3
                PUSH    XY0, XY3                ; preserve dest pointer
                PUSH    D0, XY3                 ; preserve max bytes

                LOADZ   D0, [#KOS_HOST]
                LOW     D0
                CMP     D0, #HOST_EMU
                BNE     .hfr_nodisk

                LOADZ   D0, [#HOST_DISK_SEM]
                CALLR   _SemTakeBlocking
                BCS     .hfr_nodisk

                POP     D0, XY3                 ; D0 = max bytes
                POP     XY0, XY3                ; XY0 = dest pointer
                PUSH    XY0, XY3
                PUSH    D0, XY3

                LOADI   Y1, #DSK_PAGE

                ; DSK_BUF_LO := X0
                MOVE    D1, X0
                LOADI   X1, #DSK_BUF_LO
                STORED  D1, [XY1]

                ; DSK_BUF_HI := Y0
                MOVE    D1, Y0
                LOADI   X1, #DSK_BUF_HI
                STORED  D1, [XY1]

                ; DSK_SECCOUNT := max bytes
                LOADI   X1, #DSK_SECCOUNT
                STORED  D0, [XY1]

                ; DSK_HOST_CMD := HOST_CMD_FREAD
                LOADI   D1, #HOST_CMD_FREAD
                LOADI   X1, #DSK_HOST_CMD
                STORED  D1, [XY1]

                ; Read SECCOUNT (= bytes actually read) before RESULT.
                LOADI   X1, #DSK_SECCOUNT
                LOADD   D1, [XY1]               ; D1 = bytes read

                ; Read DSK_RESULT.
                LOADI   X1, #DSK_RESULT
                LOADD   D2, [XY1]

                PUSH    D1, XY3
                PUSH    D2, XY3
                LOADZ   D0, [#HOST_DISK_SEM]
                CALLR   _SemGive
                POP     D2, XY3
                POP     D1, XY3

                POP     D0, XY3                 ; discard saved max
                POP     XY0, XY3                ; restore caller's XY0
                POP     D3, XY3

                CMP     D2, #RES_OK
                BNE.S   .hfr_io
                MOVE    D0, D1                  ; D0 = bytes read
                RETCC

.hfr_io:
                LOADI   D0, #ERR_IO
                RETCS

.hfr_nodisk:
                POP     D0, XY3
                POP     XY0, XY3
                POP     D3, XY3
                LOADI   D0, #ERR_INVALID
                RETCS


; ============================================================================
; _HostFClose — close the open load file (Part 25 r6)
;
;   In:    (none)
;   Out:   C=0 with D0 = ERR_OK
;          C=1 with D0 = ERR_INVALID (Digital)
;          C=1 with D0 = ERR_IO      (no file was open)
;   Clobbers: D0, D1, D2, X1, Y1, flags
;   Preserves: D3, XY0, XY2, XY3
; ============================================================================
_HostFClose:
                PUSH    D3, XY3

                LOADZ   D0, [#KOS_HOST]
                LOW     D0
                CMP     D0, #HOST_EMU
                BNE     .hfc_nodisk

                LOADZ   D0, [#HOST_DISK_SEM]
                CALLR   _SemTakeBlocking
                BCS     .hfc_nodisk

                LOADI   Y1, #DSK_PAGE

                ; DSK_HOST_CMD := HOST_CMD_FCLOSE
                LOADI   D1, #HOST_CMD_FCLOSE
                LOADI   X1, #DSK_HOST_CMD
                STORED  D1, [XY1]

                LOADI   X1, #DSK_RESULT
                LOADD   D2, [XY1]

                PUSH    D2, XY3
                LOADZ   D0, [#HOST_DISK_SEM]
                CALLR   _SemGive
                POP     D2, XY3

                POP     D3, XY3

                CMP     D2, #RES_OK
                BNE.S   .hfc_io
                LOADI   D0, #ERR_OK
                RETCC

.hfc_io:
                LOADI   D0, #ERR_IO
                RETCS

.hfc_nodisk:
                POP     D3, XY3
                LOADI   D0, #ERR_INVALID
                RETCS


; ============================================================================
; End of kos_fs_host_mgr.asm
; ============================================================================
