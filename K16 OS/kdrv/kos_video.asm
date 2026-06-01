; ============================================================================
; kos_video.asm — k/OS video-mode driver (Part 20)
; ============================================================================
; Date:    12 May 2026
; Status:  Part 20 — sys_setvidmode, _VideoForceReset, _InitVideo.
; Revision: r1 — 12 May 2026 — initial.
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
                BEQ.S   .svm_write_mode             ; we own → just rewrite

                ; Owned by someone else
                BRA     .svm_busy

.svm_take:
                STOREZ  D3, [#VIDEO_OWNER_TID]

.svm_write_mode:
                ; Write D0 (mode) to VID_MODE_ADDR via XY0
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

                ; Caller owns the video. Clear owner, write VID_MODE = 0.
                LOADI   D0, #0
                STOREZ  D0, [#VIDEO_OWNER_TID]
                LOADI   X0, #<VID_MODE_ADDR
                LOADI   Y0, #>VID_MODE_ADDR
                STORED  D0, [XY0]

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
