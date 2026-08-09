; ============================================================================
; kos_video.asm — k/OS video-mode driver (Part 20)
; ============================================================================
; Date:    12 May 2026
; Status:  Part 20 — sys_setvidmode, _VideoForceReset, _InitVideo.
; Date:    28 June 2026
; Status:  Part 49 — graphics tasks join the foreground ring.
; Date:    8 August 2026
; Status:  Part 61 — acquire detaches a sys_wait-blocked launcher.
; Revision: r3 — 8 August 2026 — Part 61: fresh acquire now releases a
;             sys_wait-blocked launcher with ERR_DETACHED, mirroring
;             sys_register_shell's Part 51 auto-foreground wake
;             (_FindWaiterFor / _DeliverWaitDetached / TS_READY, with the
;             TF_DETACH_PENDING lost-race arm).  Closes the "ran cube6
;             without & and now there is no way out" hole: the launching
;             shell survives as a live background shell, reachable by
;             Ctrl-N, and can kill the graphics task as its parent.
;             Skipped when the caller is already a registered shell
;             (TF_HAS_BACKBUF) - that path detached at register time.
;             Requires kos_spawn.asm (Part 51+) and kos_defs.inc r45+.
;           r2 — 28 June 2026 — Part 49: graphics-task foreground integration.
;             sys_setvidmode acquire now marks the caller TF_GRAPHICS, saves
;             the mode in TCB_GFX_MODE, splices it into the foreground ring
;             (via _SpliceAfterForeground) and makes it foreground (via
;             _KbdReleaseWaiter) so it receives the keyboard and the host
;             follows VID_MODE to the graphics tab. Release now clears the
;             flag/mode, hands the foreground to the next ring member
;             (_SwitchForegroundNext) and unsplices (_UnspliceFromRing).
;             Added _VideoSetModeRaw (bare VID_MODE poke) for the switcher's
;             _CommitForeground. Busy path unchanged: still returns ERR_BUSY,
;             which the graphics apps already handle by printing and exiting.
;             Requires kos_defs.inc r45+ and kos_switcher.asm r8+.
;           r1 — 12 May 2026 — initial.
;
; Purpose: Mediate access to the VID_MODE MMIO register ($DD0000).
;          Single-owner ownership model: at any time at most one task
;          "owns" the video mode. Acquire is via sys_setvidmode with a
;          non-zero mode; release is via sys_setvidmode(0). The kernel
;          auto-releases on owner death (sys_exit / sys_kill via
;          _HandleDeadTCB).
;
;          The hardware VID_MODE register is not access-controlled —
;          a task can bash $DD0000 directly without going through this
;          driver. Doing so bypasses ownership tracking and the kernel
;          won't auto-restore text mode when that task dies. Enforcement
;          would require hardware traps we don't have. The driver is a
;          convention layer; well-behaved tasks use it, badly-behaved
;          tasks render the graphics panel orphaned until someone else
;          acquires the mode and (later) releases it.
;
;          VID_PAGE ($DC0000) is NOT yet mediated by this driver — the
;          owner of VID_MODE is implicitly allowed to bash VID_PAGE
;          directly for framebuffer flipping. A future sys_setvidpage
;          could be added if multi-task graphics ever becomes a thing.
;
; Hardware reality (from emu_mem.pas):
;          0 = text mode (graphics panel collapsed)
;          1 = 1bpp mono 1280x720
;          2 = 8bpp VGA-palette 640x480
;          3 = 8bpp rainbow-palette 640x480 (smooth 3-phase sine RGB)
;          anything > 3 is treated as 0 by the emulator; we reject it
;          here as ERR_INVALID for cleanliness.
;
; Routines:
;     sys_setvidmode  TRAP #75              — acquire/release/change mode
;     _VideoForceReset (D0 = dying TID)     — internal cleanup helper
;     _InitVideo                            — once-only init, called from boot
; ============================================================================

; --- MMIO addresses ---------------------------------------------------------
VID_MODE_ADDR    .EQU   $DD0000
VID_PAGE_ADDR    .EQU   $DC0000

; --- Mode constants (matches emulator's VideoMode field) --------------------
VID_MODE_TEXT          .EQU 0      ; graphics panel collapsed
VID_MODE_1280x720_MONO .EQU 1      ; 1bpp 1280x720
VID_MODE_640x480_VGA   .EQU 2      ; 8bpp VGA palette 640x480
VID_MODE_640x480_RGB   .EQU 3      ; 8bpp rainbow palette 640x480
VID_MODE_MAX           .EQU 3      ; range guard

; ============================================================================
; sys_setvidmode — TRAP #75                                    [DINT-gated]
;
; Acquire, change, or release the video mode. Single-owner model.
;
;   Input:    D0 = requested mode (0..VID_MODE_MAX)
;
;   Output:   D0 = 0 on success, ERR_* on failure
;             C  = 0 success, 1 error
;
;   Errors:
;     ERR_INVALID   mode > VID_MODE_MAX
;     ERR_BUSY      caller wants a non-zero mode but another task
;                    owns the video mode
;     ERR_PERM      caller wants to release (mode=0) but doesn't own
;                    the video mode (and it's not unowned)
;
;   Preserves: D2, D3, XY2 (V2 ABI)
;
; Semantics by call form:
;
;   sys_setvidmode(mode != 0) — acquire / change:
;     - VIDEO_OWNER_TID == 0 (unowned):
;         set owner := caller; write VID_MODE := mode; success
;     - VIDEO_OWNER_TID == caller:
;         write VID_MODE := mode (mode change by current owner); success
;     - else (owned by other):
;         ERR_BUSY
;
;   sys_setvidmode(0) — release:
;     - VIDEO_OWNER_TID == caller:
;         clear owner; write VID_MODE := 0; success
;     - VIDEO_OWNER_TID == 0:
;         idempotent no-op; success
;     - else (owned by other):
;         ERR_PERM
;
; Structurally: DINT-gated leaf syscall. Same exit-EINT template as
; sys_kill / sys_exec / sys_format (gated on KERNEL_STATE == RUN).
; ============================================================================
sys_setvidmode:
                DINT

                ; Part 36 (expanded V2 ABI): XY1 now callee-preserved.
                ; The body uses XY1 transiently to read CURRENT_TCB's
                ; TCB_ID; save caller's XY1 at entry, restore at exit.
                PUSH    D2, XY3
                PUSH    D3, XY3
                PUSH    XY1, XY3                    ; Part 36: V2 ABI
                PUSH    XY2, XY3

                ; -- Validate mode in range -----------------------------------
                CMP     D0, #VID_MODE_MAX+1
                BHS     .svm_invalid

                ; -- Read caller's TID into D3 --------------------------------
                LOADZ   D2, [#CURRENT_TCB]
                MOVE    X1, D2
                LOADI   Y1, #$00
                LOADD   D3, [XY1+#TCB_ID]           ; D3 = caller TID

                ; -- Read current owner into D2 -------------------------------
                LOADZ   D2, [#VIDEO_OWNER_TID]

                ; -- Branch: release (mode=0) vs acquire/change (mode!=0) -----
                CMP     D0, #0
                BEQ     .svm_release

                ; ============= ACQUIRE / CHANGE =============================
                CMP     D2, #0
                BEQ.S   .svm_take                   ; unowned → take
                CMP     D2, D3
                BEQ     .svm_write_mode             ; we own → just rewrite
                                                    ; (long form: .svm_write_mode is
                                                    ;  now past the Part 49 acquire block)

                ; Owned by someone else
                BRA     .svm_busy

.svm_take:
                ; Fresh acquire (Part 49). D0 = mode, D3 = caller TID,
                ; XY1 = caller TCB (set at entry, untouched). Record the owner,
                ; mark the task TF_GRAPHICS, splice it into the foreground ring
                ; after the current foreground, and make it foreground so it
                ; receives keystrokes immediately. The VID_MODE write below then
                ; flips the host to the graphics tab.
                STOREZ  D3, [#VIDEO_OWNER_TID]

                LOADD   D1, [XY1+#TCB_FLAGS]
                OR      D1, #TF_GRAPHICS
                STORED  D1, [XY1+#TCB_FLAGS]

                ; --- Part 61: release the launcher -------------------------
                ; A graphics task launched without '&' leaves its parent
                ; blocked in sys_wait forever - it never exits on its own, and
                ; the parent is the only task permitted to kill it (sys_kill
                ; wants privileged-or-parent).  Mirror sys_register_shell's
                ; Part 51 auto-foreground wake: hand the launcher ERR_DETACHED
                ; so it returns to its REPL as a live background shell.
                ;
                ; Skip if we are already a registered shell - that path did its
                ; own detach at register time, and repeating it here would strand
                ; a spurious one-shot TF_DETACH_PENDING on our TCB.
                LOADD   D1, [XY1+#TCB_FLAGS]
                AND     D1, #TF_HAS_BACKBUF
                BNE     .svm_detach_skip

                PUSH    D0, XY3                     ; stash mode across the calls
                MOVE    D0, D3                      ; D0 = our TID
                CALL24  _FindWaiterFor              ; XY1 := waiter, C=1 if none
                BCS     .svm_detach_pending         ; C=1 = no waiter

                CALL24  _DeliverWaitDetached        ; XY1 kept; clobbers D0-D3
                LOADI   D0, #TS_READY
                STORED  D0, [XY1+#TCB_STATE]        ; unblock the launcher
                BRA     .svm_detach_reload

.svm_detach_pending:
                ; Race lost - the launcher has not reached sys_wait yet, so
                ; there is nobody to poke.  Leave the note on our own TCB and
                ; let sys_wait consume it on arrival (kos_spawn.asm, the
                ; .no_detach_pending test).  _FindWaiterFor clobbered XY1 on
                ; this arm too - reload self.
                LOADZ   D0, [#CURRENT_TCB]
                MOVE    X1, D0
                LOADI   Y1, #$00
                LOADD   D0, [XY1+#TCB_FLAGS]
                OR      D0, #TF_DETACH_PENDING
                STORED  D0, [XY1+#TCB_FLAGS]

.svm_detach_reload:
                ; Both arms left XY1 pointing somewhere else; the splice below
                ; requires XY1 = self.  D3 (caller TID) is dead from here on -
                ; _DeliverWaitDetached clobbered it.
                LOADZ   D0, [#CURRENT_TCB]
                MOVE    X1, D0
                LOADI   Y1, #$00
                POP     D0, XY3                     ; D0 = mode again
.svm_detach_skip:
                ; --- end Part 61 -------------------------------------------

                ; Splice after the current foreground. _SpliceAfterForeground
                ; (kos_switcher.asm) clobbers D0 — stash the mode across it.
                PUSH    D0, XY3
                CALL24  _SpliceAfterForeground       ; XY1 preserved; C=1 if fg vanished
                POP     D0, XY3
                BCS.S   .svm_write_mode              ; no foreground to insert after

                ; Become foreground + hand off the keyboard. _KbdReleaseWaiter
                ; preserves D0 (the mode), so it survives to the write below.
                LOADD   D1, [XY1+#TCB_ID]
                STOREZ  D1, [#FOREGROUND_TCB]
                CALL24  _KbdReleaseWaiter

.svm_write_mode:
                ; D0 = mode. Save it in the owner's TCB (so a later switch-in
                ; can restore it), then poke VID_MODE. XY1 = owner TCB on both
                ; the fresh-acquire and owner-rewrite paths. TCB_GFX_MODE at $24
                ; is outside imm5 — mode-01 [XY+D].
                LOADI   D1, #TCB_GFX_MODE
                STORED  D0, [XY1+D1]
                LOADI   X0, #<VID_MODE_ADDR
                LOADI   Y0, #>VID_MODE_ADDR
                STORED  D0, [XY0]

                LOADI   D0, #0
                CLC
                BRA     .svm_done

                ; ============= RELEASE =====================================
.svm_release:
                CMP     D2, #0
                BEQ     .svm_release_idem           ; already unowned → OK
                CMP     D2, D3
                BNE     .svm_perm                   ; not our lock

                ; Caller owns the video (Part 49). Full release: clear the
                ; graphics flag + saved mode, drop ownership, hand the
                ; foreground to the next ring member (a shell), and unsplice
                ; ourselves from the ring. XY1 = caller TCB on entry here.
                LOADD   D1, [XY1+#TCB_FLAGS]
                AND     D1, #$FFEF                  ; clear TF_GRAPHICS ($0010)
                STORED  D1, [XY1+#TCB_FLAGS]
                LOADI   D1, #TCB_GFX_MODE
                LOADI   D0, #0
                STORED  D0, [XY1+D1]                ; clear saved mode
                STOREZ  D0, [#VIDEO_OWNER_TID]      ; drop ownership (D0 = 0)

                ; Foreground hand-off. If we are the foreground, switch to the
                ; next ring member — _SwitchForegroundNext's commit writes
                ; VID_MODE := 0 (host → terminal) and repaints the shell. We
                ; are still linked here, so the walk can find our successor.
                ; Otherwise the panel is already collapsed; force it anyway.
                LOADD   D0, [XY1+#TCB_ID]
                LOADZ   D1, [#FOREGROUND_TCB]
                CMP     D0, D1
                BNE.S   .svm_rel_bg
                CALL24  _SwitchForegroundNext       ; clobbers XY1 — reload below
                BRA     .svm_rel_unsplice
.svm_rel_bg:
                LOADI   D0, #0
                CALL24  _VideoSetModeRaw            ; VID_MODE := 0

.svm_rel_unsplice:
                ; Reload XY1 = self (CURRENT_TCB) — _SwitchForegroundNext may
                ; have clobbered it — then unsplice from the ring.
                LOADZ   D0, [#CURRENT_TCB]
                MOVE    X1, D0
                LOADI   Y1, #$00
                CALL24  _UnspliceFromRing

.svm_release_idem:
                LOADI   D0, #0
                CLC
                BRA     .svm_done

                ; ============= ERROR RETURNS ================================
.svm_invalid:   LOADI   D0, #ERR_INVALID
                SEC
                BRA     .svm_done
.svm_busy:      LOADI   D0, #ERR_BUSY
                SEC
                BRA     .svm_done
.svm_perm:      LOADI   D0, #ERR_PERM
                SEC

.svm_done:
                ; -- Gated EINT (scheduler-live only) -------------------------
                PUSH    SR, XY3
                LOADZ   D2, [#KERNEL_STATE]
                LOW     D2
                CMP     D2, #KERN_STATE_RUN
                BNE.S   .svm_skip_eint
                EINT
.svm_skip_eint:
                POP     SR, XY3

                POP     XY2, XY3
                POP     XY1, XY3                    ; Part 36: V2 ABI
                POP     D3, XY3
                POP     D2, XY3
                RET


; ============================================================================
; _VideoForceReset — release video mode if dying task owns it.
;
;   Input:    D0 = dying TID
;   Output:   none; D0 preserved
;   Clobbers: D1, XY0
;
;   If VIDEO_OWNER_TID == D0:
;     write VID_MODE = 0
;     clear VIDEO_OWNER_TID
;   Otherwise no-op.
;
;   Called from:
;     - _HandleDeadTCB (sys_kill path) — victim TID
;     - sys_exit (both with-waiter and no-waiter paths) — self TID
;
;   Must be called with DINT in effect (touches kernel shared state).
;   The callers are all already DINT'd.
; ============================================================================
_VideoForceReset:
                PUSH    D1, XY3
                PUSH    XY0, XY3

                LOADZ   D1, [#VIDEO_OWNER_TID]
                CMP     D1, D0
                BNE.S   .vfr_done

                ; Dying task owns the screen. Reset to text mode.
                LOADI   D1, #0
                STOREZ  D1, [#VIDEO_OWNER_TID]
                LOADI   X0, #<VID_MODE_ADDR
                LOADI   Y0, #>VID_MODE_ADDR
                STORED  D1, [XY0]

.vfr_done:
                POP     XY0, XY3
                POP     D1, XY3
                RET


; ============================================================================
; _VideoSetModeRaw — poke VID_MODE with no ownership / flag side effects.
;
;   Input:    D0 = mode value to write
;   Output:   none; D0 preserved
;   Clobbers: XY0
;
;   Used by _CommitForeground (kos_switcher.asm) on a foreground switch to
;   set the screen for the incoming task: the saved mode for a graphics
;   task, or 0 for a shell. Ownership tracking is unchanged — that's the
;   job of sys_setvidmode; this is the bare MMIO write only.
; ============================================================================
_VideoSetModeRaw:
                LOADI   X0, #<VID_MODE_ADDR
                LOADI   Y0, #>VID_MODE_ADDR
                STORED  D0, [XY0]
                RET


; ============================================================================
; _InitVideo — one-time init at boot.
;
;   Effect: VIDEO_OWNER_TID := 0; VID_MODE := 0.
;   Called from _InitKernel before any user task runs.
;   Clobbers: D0, XY0.
; ============================================================================
_InitVideo:
                LOADI   D0, #0
                STOREZ  D0, [#VIDEO_OWNER_TID]
                LOADI   X0, #<VID_MODE_ADDR
                LOADI   Y0, #>VID_MODE_ADDR
                STORED  D0, [XY0]
                RET

; ============================================================================
; End of kos_video.asm
; ============================================================================
