; ============================================================================
; kosh_boot.asm - kernel-side kosh boot scaffolding
; ============================================================================
; Date:    29 May 2026
; Status:  Part 39 - kosh.com migration (Steps 4 & 5 complete).
;
; Revision: r2 - 29 May 2026 - Part 39 Steps 4+5: _SpawnShell now does
;             the heavy lifting that used to be inline in _P2Main.
;             The forward references to kosh_entry / kosh_entry_end
;             are gone, replaced by .INCBIN "kosh/kosh.com" bracketed
;             by local labels kosh_image_start / kosh_image_end.
;
;             What _P2Main now does:
;               1. Set up Y3=$00, X3=KERNEL_STACK_TOP.
;               2. Install _INTDispatch at VEC_INT.
;               3. Auto-format B: if not mounted.
;               4. CALL24 _SpawnShell with:
;                    Y0:X0 = kosh_image_start
;                    D2    = kosh_image_end - kosh_image_start
;                    XY1   = kosh_task_name ("kosh\0")
;                  On C=1, JMP to _BootFail.
;               5. Print "Loading k/OS shell ..." trace.
;               6. JMP24 _RestoreIdle.
;
;             Lines saved: ~70 (page-alloc, copy-loop, BT_* staging,
;             BT_NAME inline byte stores, _BuildTask, TF_KOSH_FLAGS
;             apply — all moved into _SpawnShell in kos_spawn.asm r8+).
;
;             Kernel build is functional again at this revision: kosh_boot.asm
;             no longer references symbols from kosh.asm. Build flow:
;               - kos_boot.asm .INCLUDEs kosh/kosh_boot.asm
;               - kosh_boot.asm .INCBINs kosh/kosh.com
;               - kosh.com is a separate assembly product of kosh/kosh.asm
;             Two separate assembler invocations: first kosh/kosh.asm
;             (produces kosh.com), then the full kernel build (consumes
;             kosh.com via .INCBIN).
;
;             Requires kos_spawn.asm r8+ (_SpawnShell).
;             Requires kos_defs.inc r42+ (no changes for this revision —
;             TF_KOSH_FLAGS unchanged).
;
;           r1 - 29 May 2026 - Part 39 Step 2: extracted from kosh.asm. Contained
;             _P2Main (kernel boot entry, auto-format B:, allocate user
;             page, copy kosh body, build task) and _BootFail, plus the
;             kernel-side strings these routines reference. Bridge-state
;             revision: still referenced kosh_entry / kosh_entry_end as
;             forward symbols defined inside the (now standalone)
;             kosh.asm. Required both files in the same assembly unit,
;             which broke the standalone kosh.com property. r2 removes
;             this dependency via _SpawnShell + .INCBIN.
;
;   .INCLUDEd from kos_boot.asm. Runs in kernel context (Y3 = $00).
;   Calls _RawPuts / _FormatVolume / _SpawnShell (kos_spawn.asm r8+)
;   — all kernel-side, addressed via CALL24.
; ============================================================================


; ============================================================================
; _P2Main - entry from kos_boot.asm
;   1. Set up kernel page byte (Y3=$00) and stack (X3=KERNEL_STACK_TOP).
;   2. Install _INTDispatch at VEC_INT (per-smoke convention; gotcha 7.7).
;   3. Auto-format B: if not mounted (production kosh, no smoke harness).
;   4. Spawn kosh via _SpawnShell from the .INCBIN'd kosh.com image.
;   5. JMP24 _RestoreIdle - scheduler picks up kosh.
; ============================================================================
_P2Main:
                LOADI   Y3, #$00
                LOADI   X3, #KERNEL_STACK_TOP

                ; Part 30 cleanup: the "k/OS Phase 16.7 - kosh" banner that
                ; used to live here has moved into kosh's _OSSplash. Kernel
                ; boot trace is now just kos_boot's "Booting k/OS", this
                ; file's "Formatting B: ..." (when needed), and the final
                ; "Loading k/OS shell ..." emitted just before we hand
                ; off to the scheduler. Everything else paints from inside
                ; kosh, where it lands in the shell back-buffer.

                ; -- Install _INTDispatch at VEC_INT ------------------------
                LOADI   Y0, #$00
                LOADI   X0, #VEC_INT
                LOADI   D0, #>_INTDispatch
                STORED  D0, [XY0]
                LOADI   D0, #<_INTDispatch
                STORED  D0, [XY0+#2]

                ; -- RAM disk (B:) auto-format moved to _InitFS -------------
                ; Formatting an unmounted B: now happens inside _InitFS (part
                ; of FS init), BEFORE _SeedAssigns, so RAM: seeds on a cold
                ; boot. Was here in _P2Main, which ran too late (after the
                ; seed). See kos_fs.asm _InitFS .initfs_b_ready.

                ; -- Spawn kosh --------------------------------------------
                ; _SpawnShell does the heavy lifting that used to be
                ; inline here (page alloc, copy, BT_* staging including
                ; BT_NAME, _BuildTask, TF_KOSH_FLAGS). See kos_spawn.asm
                ; r8+ for the API.
                ;
                ; Source: the .INCBIN'd "kosh.com" image bracketed by
                ; kosh_image_start/kosh_image_end labels at the bottom
                ; of this file.
                LOADI   Y0, #>kosh_image_start
                LOADI   X0, #<kosh_image_start
                LOADI   D2, #kosh_image_end-kosh_image_start
                LOADI   Y1, #>kosh_task_name
                LOADI   X1, #<kosh_task_name
                CALL24  _SpawnShell
                BCS     _BootFail

                ; -- Final kernel boot trace --------------------------------
                ; "Loading k/OS shell ..." - the last line printed via
                ; _RawPuts before kosh takes the screen. kosh's _OSSplash
                ; clears the screen on first paint, so this trace is
                ; ephemeral; it exists only to confirm the boot chain
                ; reached this point on the underlying terminal in case
                ; kosh never paints (e.g. if the scheduler hands off to
                ; the idle task and kosh hangs before TRAP_REGISTER_SHELL).
                LOADI   Y0, #>boot_shell_ok
                LOADI   X0, #<boot_shell_ok
                CALL24  _RawPuts

                ; -- Hand off to scheduler ----------------------------------
                JMP24   _RestoreIdle

_BootFail:
                LOADI   Y0, #>boot_fail
                LOADI   X0, #<boot_fail
                CALL24  _RawPuts
                JMP24   _RestoreIdle


; ============================================================================
; Kernel-side strings
; ============================================================================
boot_shell_ok:      .TEXT   "Loading k/OS shell ...", $0A, 0
boot_fail:          .TEXT   "BOOT FAIL: could not build kosh task\n",0
boot_format_msg:    .TEXT   "Formatting B: ... ",0
boot_format_ok:     .TEXT   "OK\n",0
boot_format_err:    .TEXT   "FAILED\n",0

; 11-byte FAT16 volume label, space-padded. Standard FAT16 pads with
; 0x20 on the right; "RAMDISK    " = 7 chars + 4 spaces.
; (Renamed from "KOS-RAM" 28 May 2026 - cosmetic, matches the user-
; facing terminology used by `vol` and the kosh `format` command.)
boot_ramdisk_label: .TEXT   "RAMDISK    "

; Task name for kosh — staged into BT_NAME by _SpawnShell. Max 15 chars
; + NUL fits BT_NAME's 16-byte slot.
kosh_task_name:     .TEXT   "kosh", 0

                    .ALIGN 2
; ============================================================================
; kosh.com image — embedded as a binary blob
; ============================================================================
; Assembled separately from kosh/kosh.asm with .ORG $0200. The image is
; word-aligned by assembler convention (.com files always have even
; length, enforced by the .ALIGN at the end of kosh.asm). _SpawnShell's
; word-at-a-time copy depends on this.
;
; To rebuild kosh.com: assemble kosh/kosh.asm standalone (it pulls in
; ../kos_defs.inc, ../klib/kos_klib.inc, ../emulib/kos_emulib.inc,
; ../kfs/kos_fs_defs.inc) and emit binary output as kosh.com.
; ============================================================================
kosh_image_start:
                .INCBIN "kosh/kosh.com"
kosh_image_end:

; ============================================================================
; End of kosh_boot.asm
; ============================================================================
