; ============================================================================
; kos_switcher.asm — k/OS Phase B foreground-switcher kernel module
; ============================================================================
; Date:    28 June 2026
; Status:  Part 50 — lone-foreground ring close + reap sub-pool guard (DATA FAULT fix).
;
; Revision: r10 — 28 June 2026. Part 50: two changes.
;             • _SpliceAfterForeground closes the ring back to a lone foreground
;               (SHELL_NEXT = 0) instead of copying the 0 — fixes graphics-task
;               / 2nd-shell splice producing a dangling next that crashed the
;               reap walk (DATA FAULT $00014F).
;             • .first_shell no longer writes a self-loop (the store never took
;               effect and disagreed with the readers). SHELL_NEXT is already 0
;               from _BuildTask; 0 = lone shell is now the single convention.
;             • Doc fix: sys_setforeground's ERR_INVALID note said TF_HAS_BACKBUF;
;               the code has accepted TF_FOCUSABLE since Part 49. Comment only.
; Revision: r8 — 28 June 2026. Part 49: graphics tasks join the foreground ring.
;             • Added _CommitForeground — the single commit tail now shared by
;               _SwitchForegroundNext / _Prev / _ByIndex and sys_setforeground.
;               It writes VID_MODE on every switch (saved mode for a graphics
;               target, 0 for a shell), which is what makes the WebEMU host
;               follow the foreground to the graphics / terminal tab. Shell
;               targets are additionally repainted from their back-buffer.
;             • Added _SpliceAfterForeground (factored out of sys_register_shell;
;               register_shell now calls it) and _UnspliceFromRing (alive-task
;               ring removal, used by sys_setvidmode release).
;             • Focusable guards in the three walkers + sys_setforeground's
;               validation broadened TF_HAS_BACKBUF -> TF_FOCUSABLE so a graphics
;               task can be cycled to / set as foreground.
;             Requires kos_defs.inc r45+ and kos_video.asm r2+ (_VideoSetModeRaw).
;
;           r7 — 27 May 2026. _RepaintFromBackbuf: host-conditional row
;             terminator.
;             • Digital: relies on dumb-TTY auto-wrap to advance row.
;               Emitting exactly 80 chars puts cursor at col 80, which
;               auto-wraps to col 0 of next row. Explicit CR/LF (as in
;               r6) advanced a SECOND time, producing one blank row
;               between every content row.
;             • EMU: emits explicit CR/LF as before (VT100 does not
;               auto-wrap reliably in this build — chars past col 80
;               stream onto the same row).
;             • Path selected at row-loop bottom via KOS_HOST test;
;               one extra LOADZ+CMP+BEQ per row (~6 cycles × 80 rows
;               = negligible).
;             • Trailing-blank trim approach was considered for UART
;               savings but rejected after the trim version had a row
;               -merge bug under blank-row transitions.
;
; Revision: r6 — 13 May 2026. Repaint auto-trim + ANSI compliance.
;             • _RepaintFromBackbuf now pre-scans the back-buffer to
;               find the last non-blank row and paints only up to
;               there. Avoids scrolling content off the top of small
;               terminals when the back-buffer is sparsely written.
;             • Clear sequence now emits ESC[3J first (clear scrollback
;               — xterm extension; the EMU was patched to support it
;               in this same release) then ESC[2J then ESC[H, which
;               eliminates the scrollback-leak path where bottom-row
;               scrolls during paint pulled stale content from above.
;
; Revision: r5 — 13 May 2026. Phase B Step 6b + geometry bump.
;             • Added _SwitchForegroundByIndex — walks N-1 hops from
;               FIRST_SHELL_TID anchor for the Ctrl-1..Ctrl-0 keys.
;               Defensive: stale anchor / dropped flag / ring corruption
;               all become silent no-ops.
;             • sys_register_shell's first-shell path now also writes
;               FIRST_SHELL_TID (the anchor for direct-index switching).
;             • Geometry bumped to 80 rows × 80 cols (BACKBUF_SIZE=6400)
;               to match modern terminal heights. _BackbufScroll memmove
;               count and clamp constants updated accordingly.
;
; Revision: r4 — 13 May 2026. Phase B Step 5.
;             • _RepaintFromBackbuf body implemented. On a foreground
;               switch, clears the terminal, then walks all 30×80 cells
;               of the new shell's back-buffer and emits each (with
;               space substitution for zero/unwritten cells) to the
;               terminal. Inserts CR+LF between rows (omits final, to
;               avoid scrolling past row 29). On EMU, repositions the
;               terminal cursor at the stored back-buffer cursor via
;               ESC[r;cH (using _PutDecSmall from kos_console.asm).
;               Skipped on Digital — no cursor-control sequence.
;             • Cost ~24K cycles (2.4 ms at 10 MHz); runs once per Ctrl-N.
;             • Bytes emitted directly to terminal MMIO; back-buffer is
;               READ-FROM only — _BackbufPutChar is NOT in the loop.
;
; Revision: r3 — 13 May 2026. Phase B Step 3.
;             • Added _BackbufPutChar — write one byte into the caller's
;               back-buffer at the cursor, advance cursor, handle CR/LF/
;               BS and wrap, scroll the back-buffer when the cursor falls
;               off the bottom.
;             • Called from the shell-body of each of the 7 output
;               syscalls in kos_console.asm r14+.
;             • _BackbufScroll internal helper does the 29-row memmove
;               and clears the new bottom row. ~7K cycles per scroll;
;               only runs when a shell's back-buffer overflows.
;
; Revision: r2 — 13 May 2026. Phase B Step 2.
;             • Added _RepaintFromBackbuf stub (RET only — Step 5).
;             • Added _SwitchForegroundNext internal helper. Walks the
;               shell ring one hop forward via TCB_SHELL_NEXT, updates
;               FOREGROUND_TCB to the new shell's TID, calls
;               _RepaintFromBackbuf. ISR-callable (no DINT, leaf).
;             • Added _SwitchForegroundPrev internal helper. Singly-
;               linked ring means "previous" = walk forward N-1 times.
;               Capped at MAX_SHELL_RING_LEN iterations as a defensive
;               loop bound against ring corruption.
;             • Added sys_setforeground (TRAP #76). Privileged leaf
;               syscall — caller must have TF_PRIV. Validates the
;               target TID exists and has TF_HAS_BACKBUF. Same
;               commit path as the ring-walk helpers.
;             None of the new code is exercised yet — _KbdDispatch
;             still has its empty Phase A body (Step 6), and `fg`
;             command lands in Step 9.
;
; Revision: r1 — 13 May 2026. Initial. sys_register_shell only.
;
; Architecture (target end-state, partial in Step 1):
;
;     Page-$00 sysvars:
;       FOREGROUND_TCB ($0238)  word  TID of foreground shell (0 = none)
;
;     TCB fields (within TCB_RESERVED zone $22..$5F):
;       TCB_BACKBUF_OFFS ($4C)  word  offset of back-buffer in its page
;       TCB_BACKBUF_PAGE ($4E)  word  page byte of back-buffer (low byte used)
;       TCB_SHELL_NEXT   ($50)  word  page-$00 offset of next shell TCB
;                                       (0 = lone shell / not in ring;
;                                        non-zero = next shell's offset)
;       TCB_BACKBUF_CRSR ($52)  word  packed cursor: hi=row, lo=col
;
;     TCB_FLAGS bit 3:  TF_HAS_BACKBUF ($0008)  task registered as shell
;
;     Back-buffer: 2400 bytes per shell (80 cols x 30 rows, chars only;
;     attribute plane deferred to Phase B v2). Allocated via _kmalloc.
;
; Shell ring (singly-linked, circular):
;     Each registered shell's TCB_SHELL_NEXT points at the next shell's
;     TCB low-word offset (page implicit $00). A lone shell carries next = 0
;     (not a self-loop). When a second shell registers it splices itself in
;     after the current foreground, and _SpliceAfterForeground closes the ring
;     back to the (formerly lone) foreground so both nodes have valid links.
;
; Note: included from kos_boot.asm AFTER kos_kmalloc.asm (we need _kmalloc
;       and _kfree) and AFTER kos_spawn.asm (we need _TidToTcb).
;       Constants come from kos_defs.inc.
; ============================================================================


; ----------------------------------------------------------------------------
; sys_register_shell — TRAP #77   [LEAF, DINT envelope]
;
; Register the calling task as a shell. Allocates a 2400-byte back-buffer
; from the kernel heap, sets TF_HAS_BACKBUF, links the caller into the
; shell ring. If the caller is the first shell, also sets FOREGROUND_TCB.
;
; Input:    none
; Output:   C=0  success.
;           C=1  D0 = ERR_PERM   caller already has TF_HAS_BACKBUF
;                D0 = ERR_NOMEM  back-buffer allocation failed
;
; Side effects on success:
;   - caller's TCB_BACKBUF_OFFS / TCB_BACKBUF_PAGE point at a zeroed buffer
;   - caller's TCB_FLAGS gains TF_HAS_BACKBUF
;   - caller's TCB_BACKBUF_CRSR = 0 (row 0, col 0)
;   - caller's TCB_SHELL_NEXT links to next shell in the ring (or stays 0
;     if this is the lone shell)
;   - if FOREGROUND_TCB was 0, it now holds caller's TID
;   - if other shells exist, the foreground shell's TCB_SHELL_NEXT is
;     updated to point at us
;
; Idempotency: caller already TF_HAS_BACKBUF → ERR_PERM. Catches
; double-register bugs; never silently re-allocates.
;
; IE handling: matches sys_kmalloc — DINT unconditionally, EINT only if
; KERNEL_STATE = RUN. Allows safe call from boot-context init code
; (KERNEL_STATE = BOOT) before the scheduler is up.
;
; Clobbers: D0, D1, D2, D3, XY0, XY1, XY2  (preserves XY3)
; ----------------------------------------------------------------------------
sys_register_shell:
                PUSH    D123, XY3
                PUSH    XY1, XY3
                PUSH    XY2, XY3

                DINT

                ; --- Get caller's TCB pointer ----------------------------
                ; MY_TCB_PTR is the task-local page-zero slot populated by
                ; _BuildTask. All TCBs live in page $00.
                LOADP   X1, Y3, [#MY_TCB_PTR]   ; X1 = caller TCB offset
                LOADI   Y1, #$00                ; TCBs always in page $00

                ; --- Idempotency: already a shell? -----------------------
                LOADD   D1, [XY1+#TCB_FLAGS]
                AND     D1, #TF_HAS_BACKBUF
                CMP     D1, #0
                BNE     .err_perm

                ; --- Allocate back-buffer --------------------------------
                ; _kmalloc(D0=size) -> XY0 = payload, C=0
                ;                      D0 = ERR_NOMEM, C=1 on failure.
                ; _kmalloc clobbers XY1 — reload from MY_TCB_PTR after.
                LOADI   D0, #SURFACE_SIZE
                CALL24  _kmalloc
                BCS     .err_nomem

                ; Stash back-buffer ptr in XY2 (Y2 = page, X2 = offset).
                LEA     XY2, XY0

                ; Reload caller TCB ptr — _kmalloc clobbered XY1.
                LOADP   X1, Y3, [#MY_TCB_PTR]
                LOADI   Y1, #$00

                ; --- Zero-fill the back-buffer ---------------------------
                ; 6400 bytes = 3200 words. Walk via XY0 (working copy of
                ; XY2); preserve XY2 for the TCB-store step below.
                ;
                ; CRITICAL: must use 24-bit INC XY0 (not 16-bit ADD X0)
                ; so the walk carries from X-low into Y-page at end-of-page.
                ; A 16-bit ADD wraps within the page and silently corrupts
                ; data at the start of that page — e.g. another shell's
                ; back-buffer if it happens to live near offset 0.
                LEA     XY0, XY2
                LOADI   D0, #CELL_BLANK         ; blank = space + default attr
                LOADI   D3, #SURFACE_WORDS      ; 8000 word-cells
.zero_loop:
                STORED  D0, [XY0]+              ; word stride 2, 24-bit (handles page carry)
                SUB     D3, #1
                BNE     .zero_loop

                ; --- Store back-buffer pointer into caller's TCB ---------
                ; STORED takes a D-register source, so move X2 / Y2 via D0.
                ;   TCB_BACKBUF_OFFS = X2 (offset within page)
                ;   TCB_BACKBUF_PAGE = Y2 (low byte = page byte)
                ; Offsets $4C / $4E are outside imm5 range (0..31), so use
                ; mode-01 [XY+D] addressing — pattern from kos_sem.asm.
                MOVE    D0, X2
                LOADI   D1, #TCB_BACKBUF_OFFS
                STORED  D0, [XY1+D1]
                MOVE    D0, Y2
                LOADI   D1, #TCB_BACKBUF_PAGE
                STORED  D0, [XY1+D1]

                ; --- Set TF_HAS_BACKBUF ----------------------------------
                ; TCB_FLAGS at $12 is within imm5 range, so mode-11 OK.
                LOADD   D1, [XY1+#TCB_FLAGS]
                OR      D1, #TF_HAS_BACKBUF
                STORED  D1, [XY1+#TCB_FLAGS]

                ; --- Initialise cursor at (0,0) --------------------------
                ; TCB_BACKBUF_CRSR at $52 — mode-01.
                LOADI   D0, #0
                LOADI   D1, #TCB_BACKBUF_CRSR
                STORED  D0, [XY1+D1]

                ; --- Init surface control block (Step 1) -----------------
                LOADI   D0, #1
                LOADI   D1, #TCB_CURSOR_VIS
                STORED  D0, [XY1+D1]
                LOADI   D0, #ATTR_DEFAULT
                LOADI   D1, #TCB_CUR_ATTR
                STORED  D0, [XY1+D1]
                LOADI   D0, #0
                LOADI   D1, #TCB_TOP_ROW
                STORED  D0, [XY1+D1]
                ; VIS_ROWS := live terminal rows (EMU MMIO) or default.
                LOADZ   D0, [#KOS_HOST]
                CMP     D0, #HOST_EMU
                BNE.S   .rs_vdef
                LOADI   Y0, #TERM_SIZE_PAGE
                LOADP   D0, Y0, [#$0000]
                LOW     D0                      ; rows = low byte
                CMP     D0, #0
                BNE.S   .rs_vset
.rs_vdef:
                LOADI   D0, #KOS_TERM_ROWS      ; default visible rows
.rs_vset:
                LOADI   D1, #TCB_VIS_ROWS
                STORED  D0, [XY1+D1]

                ; --- Splice into shell ring ------------------------------
                ; If FOREGROUND_TCB == 0 we are the first shell:
                ;   leave next = 0 (lone) and become foreground.
                ; Else splice in via _SpliceAfterForeground (which closes the
                ;   ring back to a lone foreground; see Part 50).
                LOADZ   D0, [#FOREGROUND_TCB]
                CMP     D0, #0
                BEQ     .first_shell

                ; --- Insert after current foreground --------------------
                ; Shared with sys_setvidmode's graphics acquire. The helper
                ; preserves D2 (= our offset) and XY2 (= our back-buffer ptr),
                ; which .err_perm_unwind below relies on. On return XY1 is back
                ; at our own TCB.
                CALL24  _SpliceAfterForeground  ; C=1 if foreground vanished
                BCS     .err_perm_unwind        ; foreground vanished (defensive)
                BRA     .commit

.first_shell:
                ; Lone shell: TCB_SHELL_NEXT stays 0 — the lone-shell convention
                ; _SwitchForegroundNext/_Prev and the Part 50 splice/reap all
                ; honour (0 = lone/first shell; non-zero = next-in-ring).
                ; _BuildTask zero-fills $20..$7F, so SHELL_NEXT is already 0
                ; here; no self-loop write is needed (and a self-loop would not
                ; match what the readers expect — see Part 50 notes).
                ; FOREGROUND_TCB = our TID;  FIRST_SHELL_TID = our TID
                LOADD   D0, [XY1+#TCB_ID]
                STOREZ  D0, [#FOREGROUND_TCB]
                STOREZ  D0, [#FIRST_SHELL_TID]

.commit:
                ; Part 51: auto-foreground a shell launched without '&'.
                ; TF_AUTOFG (set by sys_exec) means "switch to me on register".
                ; First-shell/kosh never carries it, so this is a no-op there.
                ; XY1 = our TCB on both arrival paths (first-shell fall-through
                ; and _SpliceAfterForeground return).
                LOADD   D0, [XY1+#TCB_FLAGS]
                AND     D0, #TF_AUTOFG
                BEQ     .commit_x
                ; Clear the one-shot flag.
                LOADD   D0, [XY1+#TCB_FLAGS]
                AND     D0, #$FFDF              ; ~TF_AUTOFG
                STORED  D0, [XY1+#TCB_FLAGS]
                ; Wake the launcher early: it is blocked in sys_wait on our
                ; TID. Deliver ERR_DETACHED (C=1) so it returns to its REPL as
                ; a live background shell instead of waiting for our exit.
                LOADD   D0, [XY1+#TCB_ID]       ; our TID
                CALL24  _FindWaiterFor          ; XY1 := waiter, C=1 if none
                BCC.S   .commit_wake            ; found it -> deliver now

                ; Race lost: the launcher has not reached sys_wait yet, so
                ; there is nobody to poke. Leave the note on OUR OWN TCB and
                ; let sys_wait consume it on arrival (Part 26). Previously
                ; this arm just fell through to .commit_fg and the launcher
                ; blocked forever on a child that never exits.
                ;
                ; _FindWaiterFor clobbered XY1 -- reload ourselves.
                LOADP   X1, Y3, [#MY_TCB_PTR]
                LOADI   Y1, #$00
                LOADD   D0, [XY1+#TCB_FLAGS]
                OR      D0, #TF_DETACH_PENDING
                STORED  D0, [XY1+#TCB_FLAGS]
                BRA.S   .commit_fg

.commit_wake:
                CALL24  _DeliverWaitDetached    ; poke ERR_DETACHED + C=1
                LOADI   D0, #TS_READY
                STORED  D0, [XY1+#TCB_STATE]    ; unblock the launcher
.commit_fg:
                LOADP   X1, Y3, [#MY_TCB_PTR]   ; reload XY1 = us
                LOADI   Y1, #$00
                CALL24  _CommitForeground       ; we take the foreground
.commit_x:
                CLC
                BRA     .done

.err_perm_unwind:
                ; _TidToTcb failed on a non-zero FOREGROUND_TCB — the
                ; foreground task disappeared between our LOADZ and the
                ; lookup, OR FOREGROUND_TCB held a stale TID. Undo what
                ; we already wrote: free the back-buffer, clear our flag,
                ; zero the back-buffer pointer fields, then return ERR_PERM.
                ;
                ; State at this point:
                ;   XY2 = back-buffer ptr (still valid)
                ;   TF_HAS_BACKBUF was set on our TCB
                ;   TCB_BACKBUF_OFFS/PAGE/CRSR populated
                ;   D2 = our TCB offset (was saved before _TidToTcb call)
                ;   X1 = clobbered by _TidToTcb; reload via D2

                MOVE    X1, D2
                LOADI   Y1, #$00

                ; Clear TF_HAS_BACKBUF.
                ; ~TF_HAS_BACKBUF & $FFFF = $FFF7 = mask to clear bit 3.
                LOADD   D1, [XY1+#TCB_FLAGS]
                AND     D1, #$FFF7
                STORED  D1, [XY1+#TCB_FLAGS]

                ; Zero back-buffer pointer fields.
                ; Offsets $4C / $4E — mode-01 [XY+D].
                LOADI   D0, #0
                LOADI   D1, #TCB_BACKBUF_OFFS
                STORED  D0, [XY1+D1]
                LOADI   D1, #TCB_BACKBUF_PAGE
                STORED  D0, [XY1+D1]

                ; Free the back-buffer (XY2 = payload ptr).
                LEA     XY0, XY2
                CALL24  _kfree                  ; result ignored
                BRA     .err_perm

.err_nomem:
                LOADI   D0, #ERR_NOMEM
                BRA     .err

.err_perm:
                LOADI   D0, #ERR_PERM
.err:
                SEC
.done:
                ; EINT only if scheduler is RUNning (matches sys_kmalloc).
                ; Preserve C across the gate.
                PUSH    SR, XY3
                LOADZ   D1, [#KERNEL_STATE]
                LOW     D1
                CMP     D1, #KERN_STATE_RUN
                BNE.S   .skip_eint
                EINT
.skip_eint:
                POP     SR, XY3

                POP     XY2, XY3
                POP     XY1, XY3
                POP     D123, XY3
                RET


; ----------------------------------------------------------------------------
; _RepaintFromBackbuf — repaint terminal from a shell's back-buffer
;
; Phase B Step 5: paint the new foreground shell's back-buffer contents
; onto the terminal. Run after FOREGROUND_TCB has been updated by the
; switcher.
;
; Implementation strategy:
;   1. Clear/home the terminal (ESC[2J + ESC[H on EMU, FF on Digital).
;   2. Walk all 30 rows × 80 cols. Emit each cell; substitute space ($20)
;      for zero (unwritten) cells. Insert CR+LF between rows. Skip the
;      final CR+LF so the terminal cursor doesn't scroll past row 29.
;   3. On EMU, position the terminal cursor at TCB_BACKBUF_CRSR's stored
;      row/col so subsequent emits land correctly. On Digital, this step
;      is skipped — Digital has no cursor-control sequence, and the
;      terminal cursor will be at end-of-screen after step 2.
;
; Cost: ~24K cycles (2.4 ms at 10 MHz). Acceptable for once-per-Ctrl-N.
;
; Bytes are emitted directly to terminal MMIO; the back-buffer itself is
; READ FROM (not routed through _BackbufPutChar — we're painting from
; the buffer, not to it).
;
; In:        XY1 = TCB ptr of the new foreground shell (page $00)
; Out:       terminal contents = back-buffer contents; cursor positioned
; Clobbers:  D0..D3, XY0, XY2
; Preserves: XY1, XY3
; ----------------------------------------------------------------------------
_RepaintFromBackbuf:
                ; Step 1 (grid-is-master): re-render the VISIBLE rows of the
                ; ring surface as a CLEAN escape stream. Cells are word
                ; (attr<<8)|char; no stored byte is replayed to the VT100 --
                ; this is what retires the escape-corruption bug.
                ; Renderer seam: the ring-walk + per-cell emit below is the
                ; shared shape a framebuffer (kanvas) back-end clones, swapping
                ; the per-cell action (emit char -> blit glyph). Per-cell
                ; attr->SGR is deferred with SetAttr (#20); step 1 emits one
                ; default reset and paints the char (low) byte only.
                ; In: XY1 = shell TCB. Clobbers D0..D3, XY0, XY2. Preserves XY1, XY3.
                LOADI   Y0, #TERMINAL_PAGE
                LOADI   X0, #$0000
                LOADZ   D0, [#KOS_HOST]
                CMP     D0, #HOST_DIGITAL
                BEQ     .rb_clear_digital
                ; EMU: ESC[3J ESC[2J ESC[H
                LOADI   D0, #$1B
                STOREB  D0, [XY0]
                LOADI   D0, #'['
                STOREB  D0, [XY0]
                LOADI   D0, #'3'
                STOREB  D0, [XY0]
                LOADI   D0, #'J'
                STOREB  D0, [XY0]
                LOADI   D0, #$1B
                STOREB  D0, [XY0]
                LOADI   D0, #'['
                STOREB  D0, [XY0]
                LOADI   D0, #'2'
                STOREB  D0, [XY0]
                LOADI   D0, #'J'
                STOREB  D0, [XY0]
                LOADI   D0, #$1B
                STOREB  D0, [XY0]
                LOADI   D0, #'['
                STOREB  D0, [XY0]
                LOADI   D0, #'H'
                STOREB  D0, [XY0]
                ; default attribute reset (ESC[0m)
                LOADI   D0, #$1B
                STOREB  D0, [XY0]
                LOADI   D0, #'['
                STOREB  D0, [XY0]
                LOADI   D0, #'0'
                STOREB  D0, [XY0]
                LOADI   D0, #'m'
                STOREB  D0, [XY0]
                BRA     .rb_paint
.rb_clear_digital:
                LOADI   D0, #$0C
                STOREB  D0, [XY0]
.rb_paint:
                ; init run-length SGR tracker = default (matches ESC[0m above)
                LOADI   D0, #TCB_RENDER_ATTR
                LOADI   D1, #ATTR_DEFAULT
                STORED  D1, [XY1+D0]
                ; XY2 = surface base + TOP_ROW*160
                LOADI   D0, #TCB_TOP_ROW
                LOADD   D2, [XY1+D0]            ; D2 = TOP_ROW
                MOVE    D0, D2
                SHL4    D0
                SHL     D0                      ; TOP*32 = t
                MOVE    D1, D0
                SHL     D0
                SHL     D0                      ; t*4
                ADD     D0, D1                  ; t*5 = TOP*160 (row byte offset)
                LOADI   D1, #TCB_BACKBUF_OFFS
                LOADD   D1, [XY1+D1]
                ADD     D1, D0
                MOVE    X2, D1
                LOADI   D1, #TCB_BACKBUF_PAGE
                LOADD   D1, [XY1+D1]
                MOVE    Y2, D1
                ; rows_left_total = VIS (D2, zero-guarded)
                LOADI   D0, #TCB_VIS_ROWS
                LOADD   D2, [XY1+D0]
                CMP     D2, #0
                BNE.S   .rb_vok
                LOADI   D2, #KOS_TERM_ROWS
.rb_vok:
                ; Digital dumb-TTY has no cursor addressing: trailing blank rows
                ; below the cursor would flood the terminal. Cap the repaint at
                ; the cursor row (content ends at the prompt).
                LOADZ   D0, [#KOS_HOST]
                CMP     D0, #HOST_DIGITAL
                BNE.S   .rb_rows_ready
                LOADI   D0, #TCB_BACKBUF_CRSR
                LOADD   D0, [XY1+D0]
                HIGH    D0                      ; cursor row (0-based)
                ADD     D0, #1                  ; rows = cursorRow + 1
                CMP     D0, D2                  ; cursorRow+1 >= VIS ?
                BHS.S   .rb_rows_ready          ; yes -> keep VIS
                MOVE    D2, D0                  ; no  -> use cursorRow+1
.rb_rows_ready:
                LOADZ   D0, [#KOS_HOST]
                CMP     D0, #HOST_DIGITAL
                BEQ     .rb_paint_dig
.rb_row:
                LOADI   D3, #0
.rb_cell:
                LOADD   D0, [XY2]+              ; cell word (attr<<8)|char; walk +2
                PUSH    D0, XY3                 ; save cell
                HIGH    D0                      ; D0 = attr
                MOVE    D1, D0                  ; keep attr in D1
                LOADI   D0, #TCB_RENDER_ATTR
                LOADD   D0, [XY1+D0]            ; D0 = last attr
                CMP     D1, D0
                BEQ.S   .rb_emit_char           ; unchanged -> no SGR
                LOADI   D0, #TCB_RENDER_ATTR
                STORED  D1, [XY1+D0]            ; last := attr
                LOADZ   D0, [#KOS_HOST]
                CMP     D0, #HOST_DIGITAL
                BEQ.S   .rb_emit_char           ; Digital dumb-TTY: no SGR
                PUSH    D2, XY3                 ; save rows_left across _AttrToSGR
                PUSH    D3, XY3                 ; save col
                MOVE    D0, D1                  ; attr -> arg
                CALL24  _AttrToSGR
                POP     D3, XY3
                POP     D2, XY3
.rb_emit_char:
                POP     D0, XY3                 ; cell
                LOW     D0                      ; char
                STOREB  D0, [XY0]
                ADD     D3, #1
                CMP     D3, #KOS_TERM_COLS
                BLO     .rb_cell
                SUB     D2, #1                  ; rows_left_total--
                CMP     D2, #0
                BEQ     .rb_paint_done          ; last row: no trailing CR/LF
                ; ring wrap: if walk reached surface end, reset to base
                MOVE    D0, X2                  ; current low-word offset
                LOADI   D1, #TCB_BACKBUF_OFFS
                LOADD   D1, [XY1+D1]            ; base offset
                LOADI   D3, #SURFACE_SIZE
                ADD     D1, D3                  ; end offset = base + 16000
                CMP     D0, D1                  ; X2 >= end ?
                BLO.S   .rb_noreset
                LOADI   D0, #TCB_BACKBUF_OFFS
                LOADD   D0, [XY1+D0]
                MOVE    X2, D0                  ; reset to base (Y2 same page)
.rb_noreset:
                ; row terminator: Digital none (auto-wrap), EMU CR LF
                LOADZ   D0, [#KOS_HOST]
                CMP     D0, #HOST_DIGITAL
                BEQ     .rb_row
                LOADI   D0, #$0D
                STOREB  D0, [XY0]
                LOADI   D0, #$0A
                STOREB  D0, [XY0]
                BRA     .rb_row
; ---- Digital dumb-TTY paint: trim trailing spaces; LF-advance short rows; ----
; ---- last row stops at its final char so the cursor lands after the prompt. --
.rb_paint_dig:
.rbd_row:
                LOADI   D3, #0                  ; col
                LOADI   D1, #0                  ; pending (deferred) spaces
.rbd_cell:
                LOADD   D0, [XY2]+              ; cell word; walk +2
                LOW     D0                      ; char (attr ignored on Digital)
                CMP     D0, #$20
                BNE.S   .rbd_nonspace
                ADD     D1, #1                  ; space -> defer
                BRA     .rbd_next
.rbd_nonspace:
                PUSH    D0, XY3                 ; save char
.rbd_flush:
                CMP     D1, #0
                BEQ.S   .rbd_flushed
                LOADI   D0, #$20
                STOREB  D0, [XY0]               ; flush one held space
                SUB     D1, #1
                BRA     .rbd_flush
.rbd_flushed:
                POP     D0, XY3
                STOREB  D0, [XY0]               ; emit the non-space char
.rbd_next:
                ADD     D3, #1
                CMP     D3, #KOS_TERM_COLS
                BLO     .rbd_cell
                ; row done; D1 = trailing spaces (dropped).
                SUB     D2, #1
                CMP     D2, #0
                BEQ     .rb_paint_done          ; last row: cursor stays after last char
                ; LF unless the row filled col 80 (pending==0 -> auto-wrap advanced)
                CMP     D1, #0
                BEQ.S   .rbd_wrap
                LOADI   D0, #CH_LF
                STOREB  D0, [XY0]
.rbd_wrap:
                ; ring wrap: reset walk to base at surface end
                MOVE    D0, X2
                LOADI   D1, #TCB_BACKBUF_OFFS
                LOADD   D1, [XY1+D1]
                LOADI   D3, #SURFACE_SIZE
                ADD     D1, D3                  ; end = base + 16000
                CMP     D0, D1
                BHS.S   .rbd_reset
                BRA     .rbd_row
.rbd_reset:
                LOADI   D0, #TCB_BACKBUF_OFFS
                LOADD   D0, [XY1+D0]
                MOVE    X2, D0                  ; reset to base (Y2 same page)
                BRA     .rbd_row
.rb_paint_done:
                ; --- Position terminal cursor (EMU only) ---
                LOADZ   D0, [#KOS_HOST]
                CMP     D0, #HOST_DIGITAL
                BEQ     .rb_return
                LOADI   D2, #TCB_BACKBUF_CRSR
                LOADD   D3, [XY1+D2]            ; D3 = (row<<8)|col
                MOVE    D2, D3
                HIGH    D2
                ADD     D2, #1                  ; 1-based row
                MOVE    D0, D3
                LOW     D0
                ADD     D0, #1                  ; 1-based col
                PUSH    D0, XY3                 ; save col
                LOADI   D1, #$1B
                STOREB  D1, [XY0]
                LOADI   D1, #'['
                STOREB  D1, [XY0]
                MOVE    D0, D2
                CALL24  _PutDecSmall
                LOADI   D1, #';'
                STOREB  D1, [XY0]
                POP     D0, XY3
                CALL24  _PutDecSmall
                LOADI   D1, #'H'
                STOREB  D1, [XY0]
                ; --- Cursor visibility from header flag ---
                LOADI   D1, #TCB_CURSOR_VIS
                LOADD   D0, [XY1+D1]
                LOADI   D1, #$1B
                STOREB  D1, [XY0]
                LOADI   D1, #'['
                STOREB  D1, [XY0]
                LOADI   D1, #'?'
                STOREB  D1, [XY0]
                LOADI   D1, #'2'
                STOREB  D1, [XY0]
                LOADI   D1, #'5'
                STOREB  D1, [XY0]
                CMP     D0, #0
                BEQ.S   .rb_curhide
                LOADI   D1, #'h'
                BRA.S   .rb_curemit
.rb_curhide:
                LOADI   D1, #'l'
.rb_curemit:
                STOREB  D1, [XY0]
.rb_return:
                RET


; ----------------------------------------------------------------------------
; _SwitchForegroundNext — advance foreground one hop in the shell ring
;
; Internal helper. Used by sys_setforeground's hot-key counterpart in Step 6
; (_KbdDispatch's filter on KEY_CTRL_N). ISR-callable: no DINT, no syscall
; tail. Safe to call from kernel context with IRQs already off.
;
; Input:    none — uses FOREGROUND_TCB to find current foreground
; Output:   FOREGROUND_TCB updated to new shell's TID; _RepaintFromBackbuf
;           called with XY1 = new foreground TCB. C unspecified.
;           If FOREGROUND_TCB is 0 (no shells registered) or the TID is
;           stale (defensive), the call is silently a no-op.
;
; Clobbers: D0, D1, D2, D3, XY0, XY1, XY2  (preserves XY3)
; ----------------------------------------------------------------------------
_SwitchForegroundNext:
                LOADZ   D0, [#FOREGROUND_TCB]
                CMP     D0, #0
                BEQ     .none                   ; no shells registered → no-op

                ; D0 = current foreground TID. Resolve to TCB.
                CALL24  _TidToTcb               ; D0 → XY1, C=1 if not found
                BCS     .none                   ; stale TID → no-op

                ; XY1 = current foreground TCB. Follow TCB_SHELL_NEXT.
                ; TCB_SHELL_NEXT at $50 is outside imm5 — use mode-01.
                LOADI   D1, #TCB_SHELL_NEXT
                LOADD   D0, [XY1+D1]            ; D0 = next-shell offset
                CMP     D0, #0
                BEQ     .none                   ; not in shell ring → no-op

                ; XY1 = next-shell TCB (offset D0, page $00)
                MOVE    X1, D0
                LOADI   Y1, #$00

                ; Defensive: confirm successor is still focusable (a shell or a
                ; graphics task). A killed member should be unlinked by reap,
                ; but if we ever land here mid-cleanup, don't install a plain
                ; task as foreground.
                LOADD   D1, [XY1+#TCB_FLAGS]
                AND     D1, #TF_FOCUSABLE
                CMP     D1, #0
                BEQ     .none                   ; not focusable anymore → no-op

                ; Commit foreground + drive screen/keyboard. XY1 = new fg TCB.
                CALL24  _CommitForeground
.none:
                RET


; ----------------------------------------------------------------------------
; _SwitchForegroundPrev — step foreground one hop backwards in the shell ring
;
; Singly-linked ring: "previous" means walking forward until we find the TCB
; whose TCB_SHELL_NEXT points back at the current foreground. With N shells,
; that's N-1 hops. For the realistic 2..4-shell case this is microseconds.
;
; The walk is bounded by MAX_SHELL_RING_LEN to defend against ring
; corruption (a broken next-chain that doesn't return to the start would
; otherwise loop forever).
;
; Input:    none
; Output:   FOREGROUND_TCB updated, _RepaintFromBackbuf called. No-op if
;           no shells, stale TID, or ring corrupted (loop limit reached).
;
; Clobbers: D0, D1, D2, D3, XY0, XY1, XY2  (preserves XY3)
; ----------------------------------------------------------------------------
_SwitchForegroundPrev:
                LOADZ   D0, [#FOREGROUND_TCB]
                CMP     D0, #0
                BEQ     .none

                ; Save the current foreground TID — we'll compare each
                ; candidate-next TID against this to find the predecessor
                ; (the node whose .next points back at the foreground).
                MOVE    D3, D0                  ; D3 = target TID (current fg)

                ; Resolve current foreground to a TCB — that's our walk
                ; starting point. A lone shell has fg.next == 0, so the walk
                ; bails immediately (.none below) — there is no predecessor to
                ; step back to. With two or more shells the walk finds the node
                ; whose .next points back at the foreground.
                CALL24  _TidToTcb               ; D0 → XY1, C=1 if not found
                BCS     .none

                ; D2 = walk counter (cap at MAX_SHELL_RING_LEN).
                LOADI   D2, #MAX_SHELL_RING_LEN

.walk:
                ; XY1 = current walk cursor. Read its .next, then check
                ; the NEXT node's TID against the foreground TID. If
                ; equal, XY1 is the predecessor we want — do NOT advance.
                ; Otherwise advance and loop.
                ;
                ; This is the critical ordering: the previous version
                ; advanced XY1 before the TID check, which made it
                ; commit XY1 = next (= fg itself in a 2-ring) instead of
                ; the predecessor.
                LOADI   D1, #TCB_SHELL_NEXT
                LOADD   D0, [XY1+D1]            ; D0 = candidate next offset
                CMP     D0, #0
                BEQ     .none                   ; broken chain → bail

                ; Look up next's TID via XY2 (we need to peek without
                ; committing XY1 yet).
                MOVE    X2, D0
                LOADI   Y2, #$00
                LOADD   D0, [XY2+#TCB_ID]
                CMP     D0, D3
                BEQ     .found                  ; XY1 IS the predecessor

                ; Not yet — advance cursor to the next node and loop.
                MOVE    X1, X2
                MOVE    Y1, Y2
                SUB     D2, #1
                BEQ     .none                   ; ring corruption — bail
                BRA     .walk

.found:
                ; XY1 is the predecessor TCB. Defensive: confirm it is still
                ; focusable (shell or graphics task), per the same reasoning
                ; as _SwitchForegroundNext.
                LOADD   D1, [XY1+#TCB_FLAGS]
                AND     D1, #TF_FOCUSABLE
                CMP     D1, #0
                BEQ     .none

                ; Commit foreground + drive screen/keyboard. XY1 = new fg TCB.
                CALL24  _CommitForeground
.none:
                RET


; ----------------------------------------------------------------------------
; sys_setforeground — TRAP #76   [LEAF, DINT envelope]
;
; Direct foreground switch by TID. Privileged — only callers with TF_PRIV
; may invoke. Used by kosh's `fg <tid>` command (Step 9). Same commit path
; as _SwitchForegroundNext/Prev.
;
; Input:    D0 = target TID
; Output:   C=0   success, foreground switched
;           C=1   D0 = ERR_PERM     — caller lacks TF_PRIV
;                 D0 = ERR_NOTFOUND — TID doesn't exist or slot is TS_UNUSED
;                 D0 = ERR_INVALID  — target lacks TF_FOCUSABLE
;                                     (not a shell and not a graphics task)
;
; Leaf: returns to the same caller. The repaint walks 2400 chars
; synchronously (when Step 5 lands) but doesn't yield.
;
; IE handling: matches sys_kmalloc — DINT unconditionally, EINT only if
; KERNEL_STATE = RUN. (At Step 2 this is theoretical — sys_setforeground
; isn't reachable from boot context. The gate costs nothing.)
;
; Clobbers: D0, D1, D2, D3, XY0, XY1, XY2  (preserves XY3)
; ----------------------------------------------------------------------------
sys_setforeground:
                PUSH    D123, XY3
                PUSH    XY1, XY3
                PUSH    XY2, XY3

                DINT

                ; Save the target TID — _TidToTcb will consume D0.
                MOVE    D2, D0                  ; D2 = target TID

                ; --- Privilege check: caller must be TF_PRIV ---
                LOADP   X1, Y3, [#MY_TCB_PTR]
                LOADI   Y1, #$00
                LOADD   D1, [XY1+#TCB_FLAGS]
                AND     D1, #TF_PRIV
                CMP     D1, #0
                BEQ     .err_perm

                ; --- Look up target TCB ---
                MOVE    D0, D2                  ; restore TID for _TidToTcb
                CALL24  _TidToTcb               ; D0 → XY1, C=1 if not found
                BCS     .err_notfound

                ; --- Validate target is focusable (shell or graphics task) ---
                LOADD   D1, [XY1+#TCB_FLAGS]
                AND     D1, #TF_FOCUSABLE
                CMP     D1, #0
                BEQ     .err_invalid

                ; --- Commit foreground + drive screen/keyboard. XY1 = target.
                CALL24  _CommitForeground

                CLC
                BRA     .sf_done

.err_perm:
                LOADI   D0, #ERR_PERM
                BRA     .sf_err
.err_notfound:
                LOADI   D0, #ERR_NOTFOUND
                BRA     .sf_err
.err_invalid:
                LOADI   D0, #ERR_INVALID
.sf_err:
                SEC
.sf_done:
                ; EINT only if scheduler is RUNning. Preserve C across gate.
                PUSH    SR, XY3
                LOADZ   D1, [#KERNEL_STATE]
                LOW     D1
                CMP     D1, #KERN_STATE_RUN
                BNE.S   .sf_skip_eint
                EINT
.sf_skip_eint:
                POP     SR, XY3

                POP     XY2, XY3
                POP     XY1, XY3
                POP     D123, XY3
                RET


; ----------------------------------------------------------------------------
; _SwitchForegroundByIndex — step foreground to the Nth shell in the ring
;
; Anchored at FIRST_SHELL_TID. Walks N-1 hops via TCB_SHELL_NEXT. Used by
; the Ctrl-digit hot-key path: index 1 = first registered shell (kosh by
; convention), 2 = second, etc.
;
; Defensive against a stale FIRST_SHELL_TID (the first shell may have
; exited — though Step 10's death cleanup hasn't shipped yet) and against
; ring corruption (capped at MAX_SHELL_RING_LEN hops). Silent no-op on
; failure rather than reporting an error, since this is invoked from IRQ
; context.
;
; If the index walks back to the current foreground (e.g. Ctrl-1 while
; already on shell 1), this becomes an expensive but harmless full repaint.
;
; Input:    D0 = 1-based shell index (1..10 typical, but any 1..ring-length
;                works; values >= ring length silently no-op)
; Output:   FOREGROUND_TCB updated, _RepaintFromBackbuf called. No-op on
;           any defensive trigger.
; Clobbers: D0, D1, D2, D3, XY0, XY1, XY2  (preserves XY3)
;
; Context:  ISR-callable. Caller is responsible for IRQs already being off
;           or for accepting a brief window during the walk.
; ----------------------------------------------------------------------------
_SwitchForegroundByIndex:
                ; D0 = index. Bail on index 0 or negative.
                CMP     D0, #1
                BLO     .sfi_none

                ; D2 = remaining hops to walk = D0 - 1.
                MOVE    D2, D0
                SUB     D2, #1

                ; Look up FIRST_SHELL_TID → XY1.
                LOADZ   D0, [#FIRST_SHELL_TID]
                CMP     D0, #0
                BEQ     .sfi_none                   ; no shells registered

                ; Stash anchor TID in D1 for cycle detection during the
                ; walk. _TidToTcb clobbers D0 but preserves D1.
                MOVE    D1, D0

                CALL24  _TidToTcb                   ; D0 → XY1, C=1 if not found
                BCS     .sfi_none                   ; stale anchor

                ; Defensive: confirm anchor still has TF_HAS_BACKBUF.
                ; (Uses D0 as scratch — D1 still holds anchor TID.)
                LOADD   D0, [XY1+#TCB_FLAGS]
                AND     D0, #TF_HAS_BACKBUF
                CMP     D0, #0
                BEQ     .sfi_none

                ; Walk D2 hops via TCB_SHELL_NEXT.
                ; Cycle detection: if we follow .next and land back on the
                ; anchor TID before reaching the target hop count, the
                ; index is beyond the actual ring size — silent no-op.
                ; This way Ctrl-3 in a 2-shell ring (which would walk 2
                ; hops back to anchor) doesn't silently wrap to a valid
                ; shell. D3 = MAX_SHELL_RING_LEN as belt-and-braces safety
                ; against ring corruption.
                LOADI   D3, #MAX_SHELL_RING_LEN     ; safety bound
.sfi_walk:
                CMP     D2, #0
                BEQ     .sfi_arrived
                CMP     D3, #0
                BEQ     .sfi_none                   ; ring corruption — bail

                LOADI   D0, #TCB_SHELL_NEXT
                LOADD   D0, [XY1+D0]                ; D0 = next offset
                CMP     D0, #0
                BEQ     .sfi_none                   ; broken chain — bail
                MOVE    X1, D0
                LOADI   Y1, #$00

                ; Did we cycle back to the anchor? If so, index > ring size.
                LOADD   D0, [XY1+#TCB_ID]
                CMP     D0, D1
                BEQ     .sfi_none

                SUB     D2, #1
                SUB     D3, #1
                BRA     .sfi_walk

.sfi_arrived:
                ; XY1 = target TCB. Defensive: still focusable (shell or gfx)?
                LOADD   D0, [XY1+#TCB_FLAGS]
                AND     D0, #TF_FOCUSABLE
                CMP     D0, #0
                BEQ     .sfi_none

                ; Commit foreground + drive screen/keyboard. XY1 = target TCB.
                CALL24  _CommitForeground
.sfi_none:
                RET


; ----------------------------------------------------------------------------
; _BackbufPutChar — write one byte into caller's back-buffer at the cursor
;
; Maintains TCB_BACKBUF_CRSR (high byte = row, low byte = col). Handles the
; standard control characters:
;
;     $0D (CR) → col := 0
;     $0A (LF) → row += 1 (scroll if row would exceed KOS_TERM_ROWS-1)
;     $08 (BS) → if col > 0: col -= 1 (cursor only; does NOT erase prior cell)
;     other    → write byte at row*KOS_TERM_COLS + col
;                col += 1
;                if col == KOS_TERM_COLS: col := 0; row += 1; scroll if needed
;
; The scroll path runs _BackbufScroll which shifts rows 1..ROWS-1 up by one
; and blanks the new bottom row. ~7K cycles; only on overflow.
;
; Bytes not handled here (no special interpretation):
;     - $09 (TAB) → treated as a plain visible char (most apps don't use it)
;     - $07 (BEL) → ignored at the back-buffer; treat as no-op
;     - ESC, CSI sequences → currently written byte-by-byte into the buffer.
;       Phase B v1 does not parse escapes; sys_clear and sys_setcursor's
;       shell bodies bypass _BackbufPutChar for their own emission and
;       manipulate the cursor / buffer state directly.
;
; The caller's foreground status is NOT checked here. _BackbufPutChar always
; writes to the back-buffer; the caller decides separately whether to also
; emit to the terminal.
;
; In:        D0  = byte to write (low byte only; high byte ignored)
;            XY1 = caller's TCB pointer (page $00)
; Out:       none
; Clobbers:  D0, D1, D2, D3, XY0, XY2
; Preserves: XY1, XY3
; ----------------------------------------------------------------------------
; ----------------------------------------------------------------------------
; _BackbufPutChar — write one byte into caller's back-buffer at the cursor
;
; Maintains TCB_BACKBUF_CRSR (high byte = row, low byte = col). Handles the
; standard control characters:
;
;     $0D (CR) → col := 0
;     $0A (LF) → col := 0; row += 1 (scroll if row would exceed KOS_TERM_ROWS-1)
;                — Unix newline semantics: a bare '\n' both lands at column 0
;                  and advances the row, matching how the terminal interprets
;                  LF in NL mode. CR before LF is therefore optional.
;     $08 (BS) → if col > 0: col -= 1  (cursor only; no cell erase)
;     $07 (BEL)→ no-op
;     other    → write byte at row*KOS_TERM_COLS + col
;                col += 1
;                if col == KOS_TERM_COLS: col := 0; row += 1; scroll if needed
;
; The scroll path runs _BackbufScroll which shifts rows 1..ROWS-1 up and
; blanks the new bottom row. ~7K cycles; only on overflow.
;
; Phase B v1 does NOT parse VT100 escape sequences — ESC and CSI bytes go
; into the back-buffer as opaque visible bytes (and look strange when
; repainted). sys_clear and sys_setcursor's shell bodies bypass this
; helper for their own emission and manipulate cursor/buffer state
; directly.
;
; Caller foreground status is NOT checked here. _BackbufPutChar always
; writes to the back-buffer; the caller decides separately whether to
; also emit to the terminal.
;
; In:        D0  = byte to write (low byte; high byte ignored)
;            XY1 = caller's TCB pointer (page $00)
; Out:       none
; Clobbers:  D0, D1, D2, D3, XY0, XY2
; Preserves: XY1, XY3
; ----------------------------------------------------------------------------
_BackbufPutChar:
                PUSH    XY1, XY3                ; preserve caller's TCB ptr
                LOW     D0                      ; byte in low byte only
                LOADI   D1, #TCB_BACKBUF_CRSR
                LOADD   D3, [XY1+D1]            ; D3 = (row<<8)|col
                CMP     D0, #$0D
                BEQ     .do_cr
                CMP     D0, #$0A
                BEQ     .do_lf
                CMP     D0, #$08
                BEQ     .do_bs
                CMP     D0, #$07
                BEQ     .bbpc_done
                ; -------- plain visible character (word cell + attr) -----
                ; Ring: pr = (TOP_ROW + row) mod 100; off = pr*160 + col*2.
                ; Stamp (CUR_ATTR<<8)|char. D3 (cursor) preserved for advance.
                PUSH    D0, XY3                 ; save char
                MOVE    D2, D3
                HIGH    D2                      ; D2 = visible row
                MOVE    D1, D3
                LOW     D1                      ; D1 = col
                LOADI   D0, #TCB_TOP_ROW
                LOADD   D0, [XY1+D0]            ; TOP_ROW
                ADD     D2, D0                  ; pr = TOP + row
                CMP     D2, #KOS_GRID_ROWS
                BLO.S   .pc_nowrap
                SUB     D2, #KOS_GRID_ROWS      ; mod 100
.pc_nowrap:
                MOVE    D0, D2
                SHL4    D0
                SHL     D0                      ; pr*32 = t
                MOVE    D2, D0                  ; t
                SHL     D0
                SHL     D0                      ; t*4
                ADD     D0, D2                  ; t*5 = pr*160
                ADD     D0, D1                  ; + col
                ADD     D0, D1                  ; + col (= col*2)
                LOADI   D1, #TCB_BACKBUF_OFFS
                LOADD   D1, [XY1+D1]
                ADD     D1, D0
                MOVE    X2, D1
                LOADI   D1, #TCB_BACKBUF_PAGE
                LOADD   D1, [XY1+D1]
                MOVE    Y2, D1
                ; word = (CUR_ATTR<<8)|char
                LOADI   D1, #TCB_CUR_ATTR
                LOADD   D1, [XY1+D1]
                LOW     D1
                SHL4    D1
                SHL4    D1                      ; attr<<8
                POP     D0, XY3                 ; char back
                LOW     D0
                OR      D0, D1
                STORED  D0, [XY2]               ; write word cell
                ; --- advance cursor (D3) ---
                MOVE    D0, D3
                LOW     D0
                ADD     D0, #1                  ; candidate col
                CMP     D0, #KOS_TERM_COLS
                BLO     .pack_col_only
                ; col wrapped -> col=0, row+=1, maybe scroll
                LOADI   D0, #0
                MOVE    D2, D3
                HIGH    D2
                ADD     D2, #1                  ; row+1
                LOADI   D1, #TCB_VIS_ROWS
                LOADD   D1, [XY1+D1]
                CMP     D2, D1                  ; row+1 < VIS ?
                BLO.S   .pack_row_col
                ; past visible bottom -> ring scroll; row := VIS-1; col := 0
                CALL24  _BackbufScroll
                LOADI   D1, #TCB_VIS_ROWS
                LOADD   D1, [XY1+D1]
                SUB     D1, #1
                MOVE    D2, D1
                LOADI   D0, #0                  ; col re-established (scroll clobbers D0)
.pack_row_col:
                MOVE    D3, D2
                SHL4    D3
                SHL4    D3                      ; row<<8
                OR      D3, D0
                BRA     .bbpc_done
.pack_col_only:
                AND     D3, #$FF00
                OR      D3, D0
                BRA     .bbpc_done
.do_cr:
                AND     D3, #$FF00              ; col := 0
                BRA     .bbpc_done
.do_lf:
                MOVE    D2, D3
                HIGH    D2
                ADD     D2, #1                  ; row+1
                LOADI   D1, #TCB_VIS_ROWS
                LOADD   D1, [XY1+D1]
                CMP     D2, D1
                BLO.S   .lf_pack
                CALL24  _BackbufScroll
                LOADI   D1, #TCB_VIS_ROWS
                LOADD   D1, [XY1+D1]
                SUB     D1, #1
                MOVE    D2, D1
.lf_pack:
                MOVE    D3, D2
                SHL4    D3
                SHL4    D3                      ; row<<8, col:=0
                BRA     .bbpc_done
.do_bs:
                MOVE    D0, D3
                LOW     D0
                CMP     D0, #0
                BEQ.S   .bbpc_done
                SUB     D3, #1                  ; col--
.bbpc_done:
                LOADI   D1, #TCB_BACKBUF_CRSR
                STORED  D3, [XY1+D1]
                POP     XY1, XY3
                RET


; ----------------------------------------------------------------------------
; _BackbufScroll - ring-scroll (Step 1): O(1) TOP_ROW bump + blank new bottom
;
; Replaces the physical memmove. Bumps TCB_TOP_ROW (mod 100) and blanks the
; row scrolling in at visible bottom = (TOP_ROW + VIS_ROWS - 1) mod 100.
; Assumes VIS_ROWS >= 1 (guaranteed by register-time init + repaint guard).
;
; In:        XY1 = caller's TCB pointer
; Clobbers:  D0, D1, D2, D3, XY0, XY2   Preserves: XY1, XY3
; ----------------------------------------------------------------------------
_BackbufScroll:
                LOADI   D1, #TCB_TOP_ROW
                LOADD   D0, [XY1+D1]            ; TOP_ROW
                ADD     D0, #1
                CMP     D0, #KOS_GRID_ROWS
                BLO.S   .bs_notop
                LOADI   D0, #0
.bs_notop:
                STORED  D0, [XY1+D1]            ; TOP_ROW := new
                ; pr = (TOP_ROW + VIS - 1) mod 100
                LOADI   D1, #TCB_VIS_ROWS
                LOADD   D1, [XY1+D1]
                ADD     D0, D1
                SUB     D0, #1
                CMP     D0, #KOS_GRID_ROWS
                BLO.S   .bs_norow
                SUB     D0, #KOS_GRID_ROWS
.bs_norow:
                ; byte offset = pr*160 -> D2
                MOVE    D2, D0
                SHL4    D2
                SHL     D2                      ; pr*32 = t
                MOVE    D1, D2
                SHL     D2
                SHL     D2                      ; t*4
                ADD     D2, D1                  ; t*5 = pr*160
                LOADI   D1, #TCB_BACKBUF_OFFS
                LOADD   D1, [XY1+D1]
                ADD     D1, D2
                MOVE    X2, D1
                LOADI   D1, #TCB_BACKBUF_PAGE
                LOADD   D1, [XY1+D1]
                MOVE    Y2, D1
                ; blank 80 word-cells with CELL_BLANK
                LOADI   D0, #CELL_BLANK
                LOADI   D3, #KOS_TERM_COLS
.bs_blank:
                STORED  D0, [XY2]+
                SUB     D3, #1
                BNE     .bs_blank
                RET


; ============================================================================
; Part 49 — graphics-task foreground helpers (28 June 2026)
; ============================================================================
; These let a graphics task (TF_GRAPHICS, no back-buffer) live in the same
; foreground ring as the shells. _CommitForeground is the single commit tail
; for ALL foreground switches; it is what writes VID_MODE on every switch, so
; the WebEMU host follows the foreground to the graphics / terminal tab.
; ============================================================================

; ----------------------------------------------------------------------------
; _CommitForeground — install XY1's task as the foreground; drive the screen
;                     and keyboard accordingly.
;
; In:        XY1 = new foreground TCB (page $00)
; Out:       FOREGROUND_TCB = new TID; VID_MODE set for the target; keyboard
;            handed off; a shell target additionally repainted.
; Clobbers:  D0, D1, D2, D3, XY0, XY2  (preserves XY1, XY3)
;
; Branch:
;   graphics target (TF_GRAPHICS) → VID_MODE := TCB_GFX_MODE (host shows the
;       graphics tab; the live framebuffer is already current — the task kept
;       drawing while backgrounded). No repaint (no back-buffer).
;   shell target → VID_MODE := 0 (host shows the terminal tab) + repaint the
;       shell's back-buffer.
; ----------------------------------------------------------------------------
_CommitForeground:
                LOADD   D0, [XY1+#TCB_ID]
                STOREZ  D0, [#FOREGROUND_TCB]
                CALL24  _KbdReleaseWaiter           ; hand off the keyboard
                LOADD   D0, [XY1+#TCB_FLAGS]
                AND     D0, #TF_GRAPHICS
                BNE.S   .cf_gfx
                ; --- shell target ---
                LOADI   D0, #0
                CALL24  _VideoSetModeRaw            ; VID_MODE := 0 (host → terminal)
                CALL24  _RepaintFromBackbuf         ; XY1 = shell TCB
                RET
.cf_gfx:
                ; --- graphics target ---
                LOADI   D1, #TCB_GFX_MODE
                LOADD   D0, [XY1+D1]                ; D0 = saved mode
                CALL24  _VideoSetModeRaw            ; VID_MODE := mode (host → graphics)
                RET


; ----------------------------------------------------------------------------
; _SpliceAfterForeground — insert XY1's task into the ring immediately after
;                          the current foreground.
;
; In:        XY1 = TCB to insert (page $00)
; Out:       C=0 spliced OK; C=1 the foreground TID was stale (nothing linked).
;            XY1 is restored to the inserted task either way.
; Clobbers:  D0, D2, D3, XY1  (preserves D1, XY0, XY2, XY3)
;
; Factored from sys_register_shell's insert-after block and reused by
; sys_setvidmode's graphics acquire. Preserves D2 (= our offset) and XY2 so
; register_shell's unwind path still has what it needs on the C=1 return.
; ----------------------------------------------------------------------------
_SpliceAfterForeground:
                MOVE    D2, X1                      ; D2 = our TCB offset
                LOADZ   D0, [#FOREGROUND_TCB]
                CALL24  _TidToTcb                   ; XY1 := fg TCB, C=1 if not found
                BCS     .saf_fail
                LOADI   D3, #TCB_SHELL_NEXT
                LOADD   D0, [XY1+D3]                ; D0 = fg.next (0 = fg is lone)
                ; Part 50 fix: a lone foreground carries SHELL_NEXT = 0 — the
                ; "lone shell" convention _SwitchForegroundNext already honours.
                ; Copying that 0 into our.next would leave us dangling and send
                ; the reap ring-walk into the page-$00 vectors (DATA FAULT).
                ; Close the ring back to the foreground instead, forming a
                ; valid 2-ring fg <-> us.
                CMP     D0, #0
                BNE.S   .saf_link
                MOVE    D0, X1                      ; lone fg: our.next := fg offset
.saf_link:
                STORED  D2, [XY1+D3]                ; fg.next := us
                MOVE    X1, D2                      ; XY1 := our TCB
                LOADI   Y1, #$00
                STORED  D0, [XY1+D3]                ; our.next := fg.next (or fg if lone)
                CLC
                RET
.saf_fail:
                MOVE    X1, D2                      ; restore XY1 := our TCB
                LOADI   Y1, #$00
                SEC
                RET


; ----------------------------------------------------------------------------
; _UnspliceFromRing — remove XY1's task from the ring.
;
; Walks forward (bounded by MAX_SHELL_RING_LEN) to the predecessor P whose
; TCB_SHELL_NEXT points at us, sets P.next := our.next, then clears our.next.
; Used by sys_setvidmode's release path (a live task leaving the ring). Reap
; has its own equivalent unlink inline; this is the alive-task counterpart.
;
; In:        XY1 = victim TCB (page $00)
; Out:       victim removed; victim.TCB_SHELL_NEXT = 0
; Clobbers:  D0, D2, D3, XY2  (preserves D1, XY0, XY1, XY3)
; ----------------------------------------------------------------------------
_UnspliceFromRing:
                LOADI   D3, #TCB_SHELL_NEXT
                LOADD   D0, [XY1+D3]                ; D0 = our.next
                CMP     D0, #0
                BEQ     .ufr_done                   ; not in ring → nothing to do
                CMP     D0, X1
                BNE.S   .ufr_multi
                ; Lone self-loop (defensive — a graphics task is never the lone
                ; member while kosh exists). Clear the global anchors.
                LOADI   D0, #0
                STOREZ  D0, [#FOREGROUND_TCB]
                STOREZ  D0, [#FIRST_SHELL_TID]
                BRA     .ufr_clear
.ufr_multi:
                MOVE    X2, D0
                LOADI   Y2, #$00
                LOADI   D2, #MAX_SHELL_RING_LEN
.ufr_find:
                LOADD   D0, [XY2+D3]                ; walker.next
                CMP     D0, X1
                BEQ.S   .ufr_found
                MOVE    X2, D0
                SUB     D2, #1
                BNE     .ufr_find
                BRA     .ufr_clear                  ; corrupt ring → skip the splice
.ufr_found:
                LOADD   D0, [XY1+D3]                ; our.next
                STORED  D0, [XY2+D3]                ; pred.next := our.next
.ufr_clear:
                LOADI   D0, #0
                STORED  D0, [XY1+D3]                ; our.next := 0
.ufr_done:
                RET


; ============================================================================
; End of kos_switcher.asm (r8)
; ============================================================================
