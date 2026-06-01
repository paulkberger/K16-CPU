; ============================================================================
; kos_fs_host.asm — k/OS Part 22: host-disk block-layer backend
; ============================================================================
; Date:    12 May 2026
; Status:  Part 22 + Part 20 cleanup. Host-disk backend wrapping the
;          EMU-side disk controller MMIO at page $DA.
;
; Revision: r2 — 12 May 2026 — Part 20 cleanup: HOST_DISK_SEM moved.
;             The HOST_DISK_SEM .EQU $0234 declaration moved into
;             kos_defs.inc (r31) so all page-$00 sysvar slots live in
;             one registry. This file's declaration replaced with a
;             cross-reference comment. No functional change.
;
;           r1 — 9 May 2026 — initial.
;             • _BlockReadHost / _BlockWriteHost — leaf-style backends
;               called via the volume table's BLOCKREAD/BLOCKWRITE
;               function pointers, exactly like _BlockReadRAM / _BlockReadROM.
;             • _InitHostDisk — creates the disk-mutex semaphore at boot
;               (count=1) and stashes the handle in HOST_DISK_SEM.
;             • Disk-mutex is taken via _SemTakeBlocking; today's callers
;               run with DINT in effect across the whole syscall, so
;               contention is impossible and the take always falls
;               through the fast path. The sem is correctly placed for
;               when kernel preemption mid-syscall lands (Phase 4+).
;
; Purpose: Translate sector/buffer requests into MMIO command sequences
;            against the host-disk controller. Drive index 2..5 (FS_DRIVE_C
;            through FS_DRIVE_F) maps to controller bay 0..3.
;
; --- ABI -------------------------------------------------------------------
;
; _BlockReadHost / _BlockWriteHost:
;   In:   D0  = sector number (word; high byte of LBA always 0 for now)
;         XY0 = buffer address (24-bit), 512 bytes
;         XY2 = volume slot pointer ($00:slot_offset; one of VOL_SLOT_C..F)
;   Out:  C   = 0 on success, D0 = ERR_OK
;         C   = 1 on failure, D0 = ERR_IO
;   Clobbers: D0, D1, D2, X0, X1, Y0, Y1, flags
;   Preserves: D3, XY2, XY3
;
; The dispatcher (_VolBlockRead in kos_fs.asm) passes D0/XY0/XY2 to all
; backends. RAM and ROM backends ignore XY2 (they're tied to specific
; drives), but the host backend uses XY2 to derive the bay number:
;
;   bay = (X2 - VOL_SLOT_C) / 64
;
; The slot pointer's high byte is always $00 (page $00) so we only look
; at X2's low word. Slot bases are at offsets $02E0, $0320, $0360, $03A0
; — a constant 64-byte stride from $02E0.
;
; --- Disk-mutex semaphore ---------------------------------------------------
;
; HOST_DISK_SEM (page $00 word) — semaphore handle protecting the
; controller MMIO registers. Initialised at boot to count=1 (mutex).
;
; Today: take always succeeds immediately (single-task, DINT). The
; block path is dead code in practice but lands correctly for future
; preemptive kernels (Phase 4+).
;
; --- 24-bit LBA ------------------------------------------------------------
;
; The controller's DSK_LBA_LO/HI form a 24-bit LBA. K16 sector numbers
; come in as 16-bit words, so DSK_LBA_HI is always written as 0. The
; high-LBA path is reserved for future SD/large-disk support.
;
; ============================================================================


; ============================================================================
; HOST_DISK_SEM — kernel-page-zero word holding the disk semaphore handle
;
; Declared in kos_defs.inc (Part 20 r31 — moved from here to colocate all
; page-$00 sysvar slot allocations). _InitHostDisk fills it at boot with
; the result of _SemCreate(1). All MMIO-touching code takes/gives the sem.
; ============================================================================


; ============================================================================
; _InitHostDisk — boot-time initialisation
;
;   Called from _InitKernel once, after _InitSemPool. Allocates the
;   disk-mutex semaphore from the pool and stashes the handle.
;
;   On EMU: the controller is real and IDENT'able; we don't probe
;     here because _InitFS will issue _TryMount on each host-disk
;     slot, and _TryMount triggers a real CMD_READ which the EMU
;     services (returning RES_NO_MEDIA for empty bays). That's the
;     mount probe.
;
;   On Digital: the controller doesn't exist. Reads of $DA0010
;     (DSK_RESULT) return undefined data. _TryMount on slots C..F
;     will see whatever garbage the bus presents and fail the BPB
;     signature check, leaving the slot present=0. No harm done.
;     Could short-circuit the host-disk init on Digital, but that's
;     an optimisation; today's path works correctly on both hosts.
;
;   In:    (none)
;   Out:   HOST_DISK_SEM populated. C=0 on success.
;          On failure (sem pool exhausted), HOST_DISK_SEM = 0; this is
;          a configuration error — the kernel HALTs $D2 to flag it.
;   Clobbers: D0, D1, X0, X1, Y0, Y1, flags
; ============================================================================
_InitHostDisk:
                ; Skip on Digital — the controller doesn't exist there.
                ; HOST_DISK_SEM stays zero, which is harmless because
                ; _InitFS won't probe C..F slots on Digital either.
                LOADZ   D0, [#KOS_HOST]
                LOW     D0
                CMP     D0, #HOST_EMU
                BNE     .skip

                LOADI   D0, #1                  ; mutex: initial count = 1
                CALLR   _SemCreate
                BCS     .nosem

                STOREZ  D0, [#HOST_DISK_SEM]
.skip:
                RETCC

.nosem:
                ; Sem pool exhausted at boot — should be impossible with
                ; a freshly-zeroed pool. HALT diagnostically.
                HALT    #$D2


; ============================================================================
; _BlockReadHost — read one 512-byte sector via disk controller
; ============================================================================
_BlockReadHost:
                ; Stash sector in D2, save XY0 (buffer ptr) on stack.
                ; Both _SemTakeBlocking and _SemGive preserve D2 per their
                ; headers, but _SemTakeTry's slow path clobbers XY0/XY1
                ; (only the fast path leaves them intact). Save explicitly.
                MOVE    D2, D0                  ; D2 = sector
                PUSH    XY0, XY3                ; preserve caller's buffer

                ; Take disk mutex.
                LOADZ   D0, [#HOST_DISK_SEM]
                CALLR   _SemTakeBlocking
                BCS     .read_sem_err           ; impossible today

                ; Restore buffer and sector, issue READ.
                POP     XY0, XY3
                MOVE    D0, D2
                LOADI   D1, #CMD_READ
                CALLR   _DiskCmdSync
                ; D0 = ERR_OK or ERR_IO, C=0/1.

                ; Save the result+flag across the give. _SemGive preserves
                ; D2, so we use D2 + SR-push.
                MOVE    D2, D0                  ; D2 = result code
                PUSH    SR, XY3                 ; preserve C across give

                LOADZ   D0, [#HOST_DISK_SEM]
                CALLR   _SemGive
                ; _SemGive's own D0 is overwritten; we ignore it. Our
                ; result is in D2 / saved-SR.

                POP     SR, XY3                 ; restore C from _DiskCmdSync
                MOVE    D0, D2                  ; restore result code
                RET

.read_sem_err:
                ; D0 = ERR_INVALID from _SemTakeBlocking. POP the saved XY0
                ; that was pushed before the take, then translate to ERR_IO.
                POP     XY0, XY3
                LOADI   D0, #ERR_IO
                RETCS


; ============================================================================
; _BlockWriteHost — write one 512-byte sector via disk controller
; ============================================================================
_BlockWriteHost:
                MOVE    D2, D0                  ; D2 = sector
                PUSH    XY0, XY3                ; preserve caller's buffer

                LOADZ   D0, [#HOST_DISK_SEM]
                CALLR   _SemTakeBlocking
                BCS     .write_sem_err

                POP     XY0, XY3
                MOVE    D0, D2
                LOADI   D1, #CMD_WRITE
                CALLR   _DiskCmdSync

                MOVE    D2, D0                  ; D2 = result
                PUSH    SR, XY3

                LOADZ   D0, [#HOST_DISK_SEM]
                CALLR   _SemGive

                POP     SR, XY3
                MOVE    D0, D2
                RET

.write_sem_err:
                POP     XY0, XY3
                LOADI   D0, #ERR_IO
                RETCS


; ============================================================================
; _DiskCmdSync — internal helper. Programs the controller and triggers
;                a sector command synchronously.
;
;   In:    D0  = sector number (word) — LBA low; LBA hi is forced 0
;          D1  = command (CMD_READ / CMD_WRITE)
;          XY0 = buffer address (24-bit)
;          XY2 = volume slot pointer (used to derive bay 0..3)
;   Out:   D0  = ERR_OK on RES_OK; ERR_IO otherwise. C=0/1.
;   Clobbers: D0, D1, D2, X0, X1, Y0, Y1, flags
;   Preserves: D3, XY2, XY3, XY0 (caller's buffer pointer left intact)
;
; Caller MUST hold the disk-mutex semaphore.
;
; The DSK_* register addresses are page $DA, offset $00xx. Access is via
; full 24-bit pointer (Y=$DA, X=offset).
;
; Bay derivation:
;   X2 holds the slot offset (page byte is always $00). For slots
;   C..F at $02E0/$0320/$0360/$03A0, (X2 - $02E0) >> 6 = bay 0..3.
; ============================================================================
_DiskCmdSync:
                ; XY1 = $DA:0000 — controller base. We'll set X1 per-register.
                LOADI   Y1, #DSK_PAGE

                ; --- DSK_DRIVE := bay = (X2 - VOL_SLOT_C) >> 6
                MOVE    D2, X2
                SUB     D2, #VOL_SLOT_C
                ; D2 = 0, 64, 128, or 192. Need >> 6.
                SHR     D2, #6
                LOADI   X1, #DSK_DRIVE
                STORED  D2, [XY1]

                ; --- DSK_LBA_LO := sector
                LOADI   X1, #DSK_LBA_LO
                STORED  D0, [XY1]

                ; --- DSK_LBA_HI := 0
                LOADI   D2, #0
                LOADI   X1, #DSK_LBA_HI
                STORED  D2, [XY1]

                ; --- DSK_BUF_LO := X0  (caller's buffer offset)
                MOVE    D2, X0
                LOADI   X1, #DSK_BUF_LO
                STORED  D2, [XY1]

                ; --- DSK_BUF_HI := Y0  (caller's buffer page)
                MOVE    D2, Y0
                LOADI   X1, #DSK_BUF_HI
                STORED  D2, [XY1]

                ; --- DSK_SECCOUNT := 1
                LOADI   D2, #1
                LOADI   X1, #DSK_SECCOUNT
                STORED  D2, [XY1]

                ; --- DSK_CMD := command (triggers operation, services sync)
                LOADI   X1, #DSK_CMD
                STORED  D1, [XY1]

                ; --- Read DSK_RESULT
                LOADI   X1, #DSK_RESULT
                LOADD   D2, [XY1]

                CMP     D2, #RES_OK
                BNE.S   .cmd_io_err

                LOADI   D0, #ERR_OK
                RETCC

.cmd_io_err:
                LOADI   D0, #ERR_IO
                RETCS


; ============================================================================
; End of kos_fs_host.asm
; ============================================================================
