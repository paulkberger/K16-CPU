; ============================================================================
; kosh_cmds_disk.asm — kosh host-disk commands (Parts 23–24)
; ============================================================================
; Date:    29 May 2026
; Status:  Part 39 - kosh.com migration.
;
; Revision: r5 — 29 May 2026 — Part 39: kosh.com migration. 13 CALL24
;             _Kosh* helper calls converted to CALL16, and 30 string
;             references switched from
;                 #SPAWN_ENTRY_OFFSET + (label - kosh_entry)
;             to bare
;                 #label
;             because kosh.asm now assembles with .ORG $0200 and labels
;             resolve directly to their in-page addresses. Additionally,
;             10 CALL24 calls to emulator-only host-disk helpers were
;             redirected via EMULIB v1.0 (kos_emulib.inc, base $A100):
;                 _HostList     -> EMULIB_HOST_LIST      (slot 00)
;                 _HostMount    -> EMULIB_HOST_MOUNT     (slot 01)  (×2)
;                 _HostUnmount  -> EMULIB_HOST_UNMOUNT   (slot 02)  (×2)
;                 _HostCreate   -> EMULIB_HOST_CREATE    (slot 03)
;                 _HostDelete   -> EMULIB_HOST_DELETE    (slot 04)
;                 _HostRename   -> EMULIB_HOST_RENAME    (slot 05)
;                 _HostBayName  -> EMULIB_HOST_BAYNAME   (slot 06)
;             Plus 2 calls promoted to KLIB v1.1 (portable FS helpers):
;                 _TryMount     -> KLIB_TRY_MOUNT        (slot 06)  (×2)
;             EMULIB is a new emulator-only jump table separate from
;             KLIB so the portable / host-shim distinction is clear.
;             No behaviour change. Requires kosh.asm r39+,
;             kos_klib.inc r8+, kos_emulib.inc r1+.
;
; Revision: r4 — 11 May 2026 — Part 25 r5: .do_remount handler added.
;             Unmount-then-mount cycle invalidates all kernel caches
;             (FAT cache, dir-buffer cache, dirent-iter cache,
;             FS_BUF_SECTOR identity) for the target host bay. Enables
;             the "external tool wrote to my .KOS file" workflow.
;             Reuses kosh_rename_buf (16 B) for _HostBayName output.
;             New tag 29 in cmd_table (see kosh.asm r28).
;
; Revision: r3 — 11 May 2026 — Part 24 mount/format interaction:
;             - .mount_tryerr no longer calls _HostUnmount when _TryMount
;               fails. Previously: an unformatted host image (e.g. the
;               output of `mkdisk`) couldn't be formatted from kosh because
;               `mount` would bind, _TryMount would fail (no BPB), kosh
;               would unbind via rollback — and `format` had no bay to
;               address through CMD_IDENT.
;             - New behaviour: _HostMount succeeds, _TryMount fails leaves
;               the bay bound with VOL_PRESENT=0. `format C:` can then run
;               (queries CMD_IDENT, writes fresh BPB, _TryMount succeeds
;               from inside _FormatVolume).
;             - Trade-off: `disks` shows the file as [on X:] even though
;               not really "mounted" in the FS sense; `vol` correctly
;               shows it as "not mounted". User-visible cue is the
;               updated message: "mount: image has no FAT16 BPB (use
;               'format' to initialise)".
;
; Revision: r2 — 10 May 2026 — Part 23: rewrite for new HOST_CMD_* MMIO
;             surface. The pool/catalogue layer is gone; disk\*.KOS files
;             are the catalogue. Five commands, dispatch tags 20..24:
;
;               disks                 — list disk\*.KOS, mark currently
;                                       mounted entries with [on X:]
;               mount NAME D          — mount disk\NAME.KOS on drive D (C..F)
;               unmount D             — unmount drive D
;               mkdisk NAME SECTORS   — create new disk\NAME.KOS (≥64 sec)
;               rmdisk NAME           — delete disk\NAME.KOS (must be unmounted)
;
;           r1 — pool-based version (replaced).
;
; .INCLUDEd from kosh.asm after kosh_entry: so the strings declared here
; live inside the kosh.com image. kosh.asm assembles with .ORG $0200, so
; labels resolve directly to their in-page addresses (no manual rebase).
;
; --- Scratch usage --------------------------------------------------------
; LIST_BUF (256 bytes in kosh's task page) holds HOST_CMD_LIST output.
; DISK_DRIVE_TMP / DISK_SECTORS_TMP / DISK_WALK_TMP are page-$00 slots
; (LOADZ/STOREZ access). DISK_WALK_TMP saves the LIST_BUF walk offset
; across TRAP_PUTS calls in .do_disks.
; ============================================================================


; ----------------------------------------------------------------------------
; .do_disks — list disk\*.KOS in the host folder.
;
; Output:
;   disk folder:
;     TEST.KOS         [on C:]
;     SCRATCH.KOS
;
; HOST_CMD_LIST writes a stream of name\0bay\0\0name\0bay\0\0...\0 into
; LIST_BUF. Walk: read until first nul → name, next byte → bay (0..3 mounted,
; $FF not), then a pair-separator nul. Outer terminator is a leading nul
; (empty name = end-of-list).
; ----------------------------------------------------------------------------
.do_disks:
                ; --- Issue HOST_CMD_LIST --------------------------------
                MOVE    Y0, Y3
                LOADI   X0, #LIST_BUF
                CALL24  EMULIB_HOST_LIST
                BCS     .disks_no_host

                ; Header dropped — indented row layout is self-explanatory
                ; (matches vol/ls/task style).

                ; Initialise walk offset.
                LOADI   D0, #LIST_BUF
                STOREP  D0, Y3, [#DISK_WALK_TMP]

.disks_loop:
                ; Re-load walk pointer (Y3 = task page; X = offset).
                MOVE    Y0, Y3
                LOADP   D0, Y3, [#DISK_WALK_TMP]
                MOVE    X0, D0

                ; If first byte is nul, end-of-list.
                LOADB   D0, [XY0]
                CMP     D0, #0
                BEQ     .repl_loop

                ; Build display row in ROW_BUF: 2-space indent, then
                ; name padded to 16 cols, then optional "[on X:]".
                MOVE    Y1, Y3
                LOADI   X1, #ROW_BUF
                LOADI   D0, #CH_SPACE
                CALL16  _KoshEmitByte
                LOADI   D0, #CH_SPACE
                CALL16  _KoshEmitByte

                ; Copy name from [XY0] until nul. D3 counts emitted chars
                ; so we can pad afterwards to 16-char column width.
                LOADI   D3, #0
.disks_copy_name:
                LOADB   D0, [XY0]
                CMP     D0, #0
                BEQ     .disks_name_done
                STOREB  D0, [XY1]
                INC     XY0, #1
                INC     XY1, #1
                ADD     D3, #1
                BRA     .disks_copy_name
.disks_name_done:
                INC     XY0, #1                 ; past name's nul → bay byte

                LOADB   D2, [XY0]               ; D2 = bay or $FF
                INC     XY0, #1                 ; past bay
                INC     XY0, #1                 ; past pair-separator nul

                ; Save walk offset for next iteration.
                MOVE    D0, X0
                STOREP  D0, Y3, [#DISK_WALK_TMP]

                ; Pad emitted name out to 16 chars so "[on X:]" markers
                ; line up regardless of name length. D3 = chars emitted.
.disks_pad_loop:
                CMP     D3, #16
                BHS.S   .disks_pad_done
                LOADI   D0, #CH_SPACE
                CALL16  _KoshEmitByte
                ADD     D3, #1
                BRA     .disks_pad_loop
.disks_pad_done:

                ; If bay <> $FF, append "[on X:]" marker.
                CMP     D2, #$FF
                BEQ     .disks_no_mark

                LOADI   D0, #'['
                CALL16  _KoshEmitByte
                LOADI   D0, #'o'
                CALL16  _KoshEmitByte
                LOADI   D0, #'n'
                CALL16  _KoshEmitByte
                LOADI   D0, #CH_SPACE
                CALL16  _KoshEmitByte
                MOVE    D0, D2
                ADD     D0, #'C'                ; bay → letter
                CALL16  _KoshEmitByte
                LOADI   D0, #':'
                CALL16  _KoshEmitByte
                LOADI   D0, #']'
                CALL16  _KoshEmitByte

.disks_no_mark:
                LOADI   D0, #CH_LF
                CALL16  _KoshEmitByte
                LOADI   D0, #0
                CALL16  _KoshEmitByte

                MOVE    Y0, Y3
                LOADI   X0, #ROW_BUF
                TRAP    #TRAP_PUTS

                BRA     .disks_loop

.disks_no_host:
                MOVE    Y0, Y3
                LOADI   X0, #msg_disks_unavail
                TRAP    #TRAP_PUTS
                BRA     .repl_loop


; ----------------------------------------------------------------------------
; .do_mount — mount disk\NAME.KOS on drive C..F.
;
;   Args: <name> <drive>
;
;   Steps:
;     1. Parse name (zstring; nul-terminate at trailing space).
;     2. Parse drive letter, map to bay.
;     3. _HostMount(name, bay) — controller opens file, binds bay, saves INI.
;     4. _TryMount(drive) — k/OS reads BPB, populates volume slot.
;
;   Step 4 is required: _HostMount only opens the file; _TryMount probes
;   the BPB and sets VOL_PRESENT.
; ----------------------------------------------------------------------------
.do_mount:
                LEA     XY0, XY2
                CALL24  KLIB_STRLEN
                INC     XY0, #1

.mount_skip_ws1:
                LOADB   D0, [XY0]
                CMP     D0, #CH_SPACE
                BNE.S   .mount_have_name
                INC     XY0, #1
                BRA     .mount_skip_ws1

.mount_have_name:
                CMP     D0, #0
                BEQ     .mount_usage

                LEA     XY1, XY0                ; XY1 = name start

.mount_find_end:
                LOADB   D0, [XY0]
                CMP     D0, #0
                BEQ     .mount_no_drv
                CMP     D0, #CH_SPACE
                BEQ.S   .mount_term_name
                INC     XY0, #1
                BRA     .mount_find_end

.mount_term_name:
                LOADI   D0, #0
                STOREB  D0, [XY0]
                INC     XY0, #1

.mount_skip_ws2:
                LOADB   D0, [XY0]
                CMP     D0, #CH_SPACE
                BNE.S   .mount_have_drive
                INC     XY0, #1
                BRA     .mount_skip_ws2

.mount_have_drive:
                CMP     D0, #0
                BEQ     .mount_usage

                AND     D0, #$FF
                CMP     D0, #'a'
                BLO.S   .mount_no_lc
                CMP     D0, #$67
                BHS.S   .mount_no_lc
                SUB     D0, #$20
.mount_no_lc:
                CMP     D0, #'C'
                BLO     .mount_baddrv
                CMP     D0, #$47
                BHS     .mount_baddrv

                SUB     D0, #'A'                ; D0 = drive 2..5
                STOREP  D0, Y3, [#DISK_DRIVE_TMP]

                ; --- _HostMount(name=XY1, bay=D0) -------------------------
                LEA     XY0, XY1
                LOADP   D0, Y3, [#DISK_DRIVE_TMP]
                SUB     D0, #DSK_HOST_BAY_FIRST_DRV     ; bay 0..3
                CALL24  EMULIB_HOST_MOUNT
                BCS     .mount_host_err

                ; --- _TryMount(drive) -------------------------------------
                LOADP   D0, Y3, [#DISK_DRIVE_TMP]
                CALL24  KLIB_TRY_MOUNT
                BCS     .mount_tryerr

                MOVE    Y0, Y3
                LOADI   X0, #msg_disks_ok
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.mount_no_drv:
.mount_usage:
                MOVE    Y0, Y3
                LOADI   X0, #msg_mount_usage
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.mount_baddrv:
                MOVE    Y0, Y3
                LOADI   X0, #msg_mount_baddrv
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.mount_host_err:
                MOVE    Y0, Y3
                LOADI   X0, #msg_mount_err
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.mount_tryerr:
                ; _HostMount succeeded but _TryMount failed (no FAT16 BPB).
                ; Part 24: leave the file bound on the bay anyway. The slot's
                ; VOL_PRESENT stays 0 (so `vol` will show "not mounted"), but
                ; the controller bay has the stream attached — so `format`
                ; can still query CMD_IDENT and write a fresh BPB. Without
                ; this, formatting an unformatted host image was impossible:
                ; mount rolled back the bind, so format had no bay to address.
                ; Trade-off: `disks` will show the file with [on X:] even
                ; though it's not really "mounted" in the FS sense.
                MOVE    Y0, Y3
                LOADI   X0, #msg_mount_badbpb
                TRAP    #TRAP_PUTS
                BRA     .repl_loop


; ----------------------------------------------------------------------------
; .do_unmount — unmount drive C..F.
;
;   Args: <drive>
;
;   Steps:
;     1. Parse drive letter, map to bay.
;     2. Clear VOL_PRESENT.
;     3. _HostUnmount(bay).
; ----------------------------------------------------------------------------
.do_unmount:
                LEA     XY0, XY2
                CALL24  KLIB_STRLEN
                INC     XY0, #1

.unm_skip_ws:
                LOADB   D0, [XY0]
                CMP     D0, #CH_SPACE
                BNE.S   .unm_have_drv
                INC     XY0, #1
                BRA     .unm_skip_ws

.unm_have_drv:
                CMP     D0, #0
                BEQ     .unm_usage

                AND     D0, #$FF
                CMP     D0, #'a'
                BLO.S   .unm_no_lc
                CMP     D0, #$67
                BHS.S   .unm_no_lc
                SUB     D0, #$20
.unm_no_lc:
                CMP     D0, #'C'
                BLO     .unm_baddrv
                CMP     D0, #$47
                BHS     .unm_baddrv

                SUB     D0, #'A'
                STOREP  D0, Y3, [#DISK_DRIVE_TMP]

                ; Clear VOL_PRESENT.
                MOVE    D1, D0
                SHL     D1, #6                  ; D1 = drive << 6
                ADD     D1, #VOL_TABLE_BASE
                LOADI   Y0, #$00
                MOVE    X0, D1
                LOADI   D2, #0
                STOREB  D2, [XY0+#VOL_PRESENT]

                LOADP   D0, Y3, [#DISK_DRIVE_TMP]
                SUB     D0, #DSK_HOST_BAY_FIRST_DRV
                CALL24  EMULIB_HOST_UNMOUNT
                BCS     .unm_err

                MOVE    Y0, Y3
                LOADI   X0, #msg_disks_ok
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.unm_usage:
                MOVE    Y0, Y3
                LOADI   X0, #msg_unmount_usage
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.unm_baddrv:
                MOVE    Y0, Y3
                LOADI   X0, #msg_mount_baddrv
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.unm_err:
                MOVE    Y0, Y3
                LOADI   X0, #msg_unmount_err
                TRAP    #TRAP_PUTS
                BRA     .repl_loop


; ----------------------------------------------------------------------------
; .do_mkdisk — create disk\<name>.KOS, zero-filled.
;
;   Args: <name> <sectors>
; ----------------------------------------------------------------------------
.do_mkdisk:
                LEA     XY0, XY2
                CALL24  KLIB_STRLEN
                INC     XY0, #1

.mk_skip_ws1:
                LOADB   D0, [XY0]
                CMP     D0, #CH_SPACE
                BNE.S   .mk_have_name
                INC     XY0, #1
                BRA     .mk_skip_ws1

.mk_have_name:
                CMP     D0, #0
                BEQ     .mk_usage

                LEA     XY1, XY0

.mk_find_end:
                LOADB   D0, [XY0]
                CMP     D0, #0
                BEQ     .mk_no_size
                CMP     D0, #CH_SPACE
                BEQ.S   .mk_term_name
                INC     XY0, #1
                BRA     .mk_find_end

.mk_term_name:
                LOADI   D0, #0
                STOREB  D0, [XY0]
                INC     XY0, #1

.mk_skip_ws2:
                LOADB   D0, [XY0]
                CMP     D0, #CH_SPACE
                BNE.S   .mk_have_size
                INC     XY0, #1
                BRA     .mk_skip_ws2

.mk_have_size:
                CMP     D0, #0
                BEQ     .mk_usage

                CALL24  KLIB_ATOI
                BCS     .mk_badsize

                CMP     D0, #64
                BLO     .mk_toosmall

                STOREP  D0, Y3, [#DISK_SECTORS_TMP]

                LEA     XY0, XY1
                LOADP   D0, Y3, [#DISK_SECTORS_TMP]
                CALL24  EMULIB_HOST_CREATE
                BCS     .mk_create_err

                MOVE    Y0, Y3
                LOADI   X0, #msg_disks_ok
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.mk_no_size:
.mk_usage:
                MOVE    Y0, Y3
                LOADI   X0, #msg_mkdisk_usage
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.mk_badsize:
                MOVE    Y0, Y3
                LOADI   X0, #msg_mkdisk_badsize
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.mk_toosmall:
                MOVE    Y0, Y3
                LOADI   X0, #msg_mkdisk_toosmall
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.mk_create_err:
                MOVE    Y0, Y3
                LOADI   X0, #msg_mkdisk_err
                TRAP    #TRAP_PUTS
                BRA     .repl_loop


; ----------------------------------------------------------------------------
; .do_rmdisk — delete disk\<name>.KOS (must be unmounted).
;
;   Args: <name>
; ----------------------------------------------------------------------------
.do_rmdisk:
                LEA     XY0, XY2
                CALL24  KLIB_STRLEN
                INC     XY0, #1

.rm_skip_ws:
                LOADB   D0, [XY0]
                CMP     D0, #CH_SPACE
                BNE.S   .rm_have_name
                INC     XY0, #1
                BRA     .rm_skip_ws

.rm_have_name:
                CMP     D0, #0
                BEQ     .rm_usage

                LEA     XY1, XY0

.rm_find_end:
                LOADB   D0, [XY0]
                CMP     D0, #0
                BEQ.S   .rm_terminated
                CMP     D0, #CH_SPACE
                BNE.S   .rm_advance
                LOADI   D0, #0
                STOREB  D0, [XY0]
                BRA.S   .rm_terminated
.rm_advance:
                INC     XY0, #1
                BRA     .rm_find_end
.rm_terminated:

                LEA     XY0, XY1
                CALL24  EMULIB_HOST_DELETE
                BCS     .rm_err

                MOVE    Y0, Y3
                LOADI   X0, #msg_disks_ok
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.rm_usage:
                MOVE    Y0, Y3
                LOADI   X0, #msg_rmdisk_usage
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.rm_err:
                MOVE    Y0, Y3
                LOADI   X0, #msg_rmdisk_err
                TRAP    #TRAP_PUTS
                BRA     .repl_loop


; ============================================================================
; Disk-command strings (page-local, addressed via Y3 + page-offset).
; ============================================================================

msg_disks_ok:        .TEXT  "OK\n",0
msg_disks_unavail:   .TEXT  "(host disk controller not available)\n",0

msg_mount_usage:     .TEXT  "usage: mount <name> <drive>     drive=C..F\n",0
msg_mount_baddrv:    .TEXT  "drive must be C..F\n",0
msg_mount_err:       .TEXT  "mount: failed (file missing or bay in use?)\n",0
msg_mount_badbpb:    .TEXT  "mount: bound, drive unformatted (use 'format' to initialise)\n",0

msg_unmount_usage:   .TEXT  "usage: unmount <drive>          drive=C..F\n",0
msg_unmount_err:     .TEXT  "unmount: failed (bay was empty?)\n",0

msg_mkdisk_usage:    .TEXT  "usage: mkdisk <name> <sectors>  (sectors >= 64)\n",0
msg_mkdisk_badsize:  .TEXT  "mkdisk: bad sector count\n",0
msg_mkdisk_toosmall: .TEXT  "mkdisk: minimum 64 sectors (32 KB)\n",0
msg_mkdisk_err:      .TEXT  "mkdisk: failed (name in use, bad name?)\n",0

msg_rmdisk_usage:    .TEXT  "usage: rmdisk <name>\n",0
msg_rmdisk_err:      .TEXT  "rmdisk: failed (still mounted, missing?)\n",0


; ----------------------------------------------------------------------------
; .do_rename — rename the host file bound to a drive (Part 24).
;
;   Args: <drive> <newname>
;
;   Maps drive letter → bay, copies/validates newname into a kosh-page
;   scratch buffer, calls _HostRename. The bay must currently be
;   mounted (rename is bay-based on the EMU side); if it isn't, the
;   call fails with ERR_IO and we report "rename: failed".
;
;   Output:
;     OK                                 — on success
;     usage: rename <drive> <newname>    — missing args
;     rename: bad drive (C..F only)      — drive A:/B: or out of range
;     rename: bad name (A..Z, 0..9, _)   — invalid newname character
;     rename: failed $XXXX               — EMU rejected (busy, exists, etc.)
; ----------------------------------------------------------------------------
.do_rename:
                LEA     XY0, XY2
                CALL24  KLIB_STRLEN
                INC     XY0, #1

.rn_skip_ws1:
                LOADB   D0, [XY0]
                CMP     D0, #CH_SPACE
                BNE.S   .rn_have_drv
                INC     XY0, #1
                BRA     .rn_skip_ws1

.rn_have_drv:
                CMP     D0, #0
                BEQ     .rn_usage

                ; Parse drive letter (C..F only — A:/B: have no host file).
                AND     D0, #$FF
                CMP     D0, #'a'
                BLO.S   .rn_no_lc
                CMP     D0, #$67
                BHS.S   .rn_no_lc
                SUB     D0, #$20
.rn_no_lc:
                CMP     D0, #'C'
                BLO     .rn_baddrv
                CMP     D0, #$47
                BHS     .rn_baddrv

                SUB     D0, #'A'                ; D0 = drive 2..5
                STOREP  D0, Y3, [#DISK_DRIVE_TMP]

                ; Step past drive letter; allow optional ':'.
                INC     XY0, #1
                LOADB   D0, [XY0]
                CMP     D0, #':'
                BNE.S   .rn_no_colon
                INC     XY0, #1
.rn_no_colon:

                ; Skip whitespace before name.
.rn_skip_ws2:
                LOADB   D0, [XY0]
                CMP     D0, #CH_SPACE
                BNE.S   .rn_have_name
                INC     XY0, #1
                BRA     .rn_skip_ws2

.rn_have_name:
                CMP     D0, #0
                BEQ     .rn_usage

                ; Copy newname into kosh_rename_buf (max 15 chars + nul).
                ; Uppercase a..z; validate A..Z/0..9/_; stop at space/nul.
                MOVE    Y1, Y3
                LOADI   X1, #kosh_rename_buf
                LOADI   D1, #15                 ; chars budget

.rn_copy:
                CMP     D1, #0
                BEQ     .rn_copy_full
                LOADB   D0, [XY0]
                CMP     D0, #0
                BEQ     .rn_copy_done
                CMP     D0, #CH_SPACE
                BEQ     .rn_copy_done
                ; Uppercase.
                CMP     D0, #'a'
                BLO.S   .rn_no_lc2
                CMP     D0, #$7B
                BHS.S   .rn_no_lc2
                SUB     D0, #$20
.rn_no_lc2:
                ; Validate.
                CMP     D0, #'_'
                BEQ.S   .rn_char_ok
                CMP     D0, #'0'
                BLO     .rn_badname
                CMP     D0, #$3A
                BLO.S   .rn_char_ok
                CMP     D0, #'A'
                BLO     .rn_badname
                CMP     D0, #$5B
                BHS     .rn_badname
.rn_char_ok:
                STOREB  D0, [XY1]
                INC     XY0, #1
                INC     XY1, #1
                SUB     D1, #1
                BRA     .rn_copy

.rn_copy_full:
                ; Hit 15-char limit. Treat further input as error if more
                ; non-space content follows.
                LOADB   D0, [XY0]
                CMP     D0, #0
                BEQ.S   .rn_copy_done
                CMP     D0, #CH_SPACE
                BEQ.S   .rn_copy_done
                BRA     .rn_badname

.rn_copy_done:
                ; Nul-terminate.
                LOADI   D0, #0
                STOREB  D0, [XY1]

                ; Call _HostRename(bay, kosh_rename_buf).
                LOADP   D0, Y3, [#DISK_DRIVE_TMP]
                SUB     D0, #DSK_HOST_BAY_FIRST_DRV     ; bay 0..3
                MOVE    Y0, Y3
                LOADI   X0, #kosh_rename_buf
                CALL24  EMULIB_HOST_RENAME
                BCS     .rn_failed

                MOVE    Y0, Y3
                LOADI   X0, #msg_disks_ok
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.rn_usage:
                MOVE    Y0, Y3
                LOADI   X0, #msg_rename_usage
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.rn_baddrv:
                MOVE    Y0, Y3
                LOADI   X0, #msg_rename_baddrv
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.rn_badname:
                MOVE    Y0, Y3
                LOADI   X0, #msg_rename_badname
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.rn_failed:
                MOVE    Y0, Y3
                LOADI   X0, #msg_rename_err
                TRAP    #TRAP_PUTS
                BRA     .repl_loop


; ----------------------------------------------------------------------------
; .do_remount — re-mount a host-bay drive to refresh kernel caches.
;
;   Args: <drive>   (C..F)
;
;   Use case: an external tool (kos_inject) has modified the .KOS image
;   while k/OS was running. The on-disk content is new but the kernel's
;   FAT cache, dir cache, and FS_BUF_SECTOR all hold stale data. remount
;   captures the bay's current basename, unmounts, re-mounts, and
;   re-parses the BPB — all caches are dropped as a side effect.
;
;   This is also useful if a host disk's BPB was edited externally
;   (rare) or if the file was swapped on disk without rebooting kosh.
;
;   Algorithm:
;     1. Parse + validate drive letter (must be C..F).
;     2. _HostBayName(bay, &kosh_rename_buf) — capture basename.
;     3. Clear VOL_PRESENT for the slot.
;     4. _HostUnmount(bay) — release the bay.
;     5. _HostMount(&kosh_rename_buf, bay) — re-bind.
;     6. _TryMount(drive) — re-parse BPB, re-populate caches.
;
;   Reuses kosh_rename_buf (16 B) as scratch for the basename capture.
;   No conflict — remount and rename don't run simultaneously.
;
;   Output:
;     OK
;     remount: bad drive (C..F only)
;     remount: failed (see hex code)
; ----------------------------------------------------------------------------
.do_remount:
                LEA     XY0, XY2
                CALL24  KLIB_STRLEN
                INC     XY0, #1

.rem_skip_ws:
                LOADB   D0, [XY0]
                CMP     D0, #CH_SPACE
                BNE.S   .rem_have_drv
                INC     XY0, #1
                BRA     .rem_skip_ws

.rem_have_drv:
                CMP     D0, #0
                BEQ     .rem_usage

                ; Lowercase → uppercase.
                AND     D0, #$FF
                CMP     D0, #'a'
                BLO.S   .rem_no_lc
                CMP     D0, #$67                ; 'g'
                BHS.S   .rem_no_lc
                SUB     D0, #$20
.rem_no_lc:
                ; Must be C..F.
                CMP     D0, #'C'
                BLO     .rem_baddrv
                CMP     D0, #$47                ; 'F'+1
                BHS     .rem_baddrv

                SUB     D0, #'A'                ; D0 = drive 2..5
                STOREP  D0, Y3, [#DISK_DRIVE_TMP]

                ; --- Capture current bay basename via _HostBayName --------
                LOADP   D0, Y3, [#DISK_DRIVE_TMP]
                SUB     D0, #DSK_HOST_BAY_FIRST_DRV     ; bay 0..3
                MOVE    Y0, Y3
                LOADI   X0, #kosh_rename_buf
                CALL24  EMULIB_HOST_BAYNAME
                BCS     .rem_failed                    ; bay empty / Digital

                ; --- Clear VOL_PRESENT (mirror .do_unmount) ---------------
                LOADP   D0, Y3, [#DISK_DRIVE_TMP]
                MOVE    D1, D0
                SHL     D1, #6                  ; D1 = drive << 6
                ADD     D1, #VOL_TABLE_BASE
                LOADI   Y0, #$00
                MOVE    X0, D1
                LOADI   D2, #0
                STOREB  D2, [XY0+#VOL_PRESENT]

                ; --- _HostUnmount(bay) ------------------------------------
                LOADP   D0, Y3, [#DISK_DRIVE_TMP]
                SUB     D0, #DSK_HOST_BAY_FIRST_DRV
                CALL24  EMULIB_HOST_UNMOUNT
                BCS     .rem_failed

                ; --- _HostMount(&kosh_rename_buf, bay) --------------------
                MOVE    Y0, Y3
                LOADI   X0, #kosh_rename_buf
                LOADP   D0, Y3, [#DISK_DRIVE_TMP]
                SUB     D0, #DSK_HOST_BAY_FIRST_DRV
                CALL24  EMULIB_HOST_MOUNT
                BCS     .rem_failed

                ; --- _TryMount(drive) -------------------------------------
                LOADP   D0, Y3, [#DISK_DRIVE_TMP]
                CALL24  KLIB_TRY_MOUNT
                BCS     .rem_failed

                MOVE    Y0, Y3
                LOADI   X0, #msg_disks_ok
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.rem_usage:
                MOVE    Y0, Y3
                LOADI   X0, #msg_remount_usage
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.rem_baddrv:
                MOVE    Y0, Y3
                LOADI   X0, #msg_remount_baddrv
                TRAP    #TRAP_PUTS
                BRA     .repl_loop

.rem_failed:
                ; D0 = err code. Use _KoshPrintErr for the nice format.
                MOVE    Y0, Y3
                LOADI   X0, #msg_remount_failed
                CALL16  _KoshPrintErr
                BRA     .repl_loop


; --- rename ----------------------------------------------------------------
msg_rename_usage:    .TEXT  "usage: rename <drive> <newname>   drive=C..F\n",0
msg_rename_baddrv:   .TEXT  "rename: bad drive (C..F only)\n",0
msg_rename_badname:  .TEXT  "rename: bad name (use A..Z, 0..9, _ only)\n",0
msg_rename_err:      .TEXT  "rename: failed (name in use, bay empty?)\n",0

; --- remount ---------------------------------------------------------------
msg_remount_usage:   .TEXT  "usage: remount <drive>   drive=C..F\n",0
msg_remount_baddrv:  .TEXT  "remount: bad drive (C..F only)\n",0
msg_remount_failed:  .TEXT  "remount: failed",0

; 16-byte scratch for the new basename (15 chars + nul). Page-local —
; kosh task page is writable post-spawn. Use .WORD for zero-fill since
; .BYTE confuses the assembler's PC alignment tracking.
;
; Part 25 r5: also used by .do_remount to receive _HostBayName's output.
; Same byte layout; remount and rename never run concurrently.
kosh_rename_buf:     .WORD  0, 0, 0, 0, 0, 0, 0, 0   ; 16 bytes


; --- Command name strings (for cmd_table) ---------------------------------
cmd_disks_str:       .TEXT  "disks",0
cmd_mount_str:       .TEXT  "mount",0
cmd_unmount_str:     .TEXT  "unmount",0
cmd_mkdisk_str:      .TEXT  "mkdisk",0
cmd_rmdisk_str:      .TEXT  "rmdisk",0
cmd_rename_str:      .TEXT  "rename",0
cmd_remount_str:     .TEXT  "remount",0


; ============================================================================
; End of kosh_cmds_disk.asm
; ============================================================================
