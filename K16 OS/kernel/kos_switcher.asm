; ============================================================================
; kos_switcher.asm — k/OS Phase B foreground-switcher kernel module
; ============================================================================
; Date:    27 May 2026
; Status:  Phase B complete (all steps shipped) + 80×80 geometry +
;          auto-trim repaint + ESC[3J integration + auto-wrap row-advance.
;
; Revision: r7 — 27 May 2026. _RepaintFromBackbuf: host-conditional row
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
;                                       (0 = not in ring; self = lone shell)
;       TCB_BACKBUF_CRSR ($52)  word  packed cursor: hi=row, lo=col
;
;     TCB_FLAGS bit 3:  TF_HAS_BACKBUF ($0008)  task registered as shell
;
;     Back-buffer: 2400 bytes per shell (80 cols x 30 rows, chars only;
;     attribute plane deferred to Phase B v2). Allocated via _kmalloc.
;
; Shell ring (singly-linked, circular):
;     Each registered shell's TCB_SHELL_NEXT points at the next shell's
;     TCB low-word offset (page implicit $00). The first shell to register
;     forms a self-loop. When a second shell registers it splices itself
;     in after the current foreground.
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
;   - caller's TCB_SHELL_NEXT links to next shell in the ring (or to self
;     if singleton)
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
                LOADI   D0, #BACKBUF_SIZE
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
                LOADI   D0, #0
                LOADI   D3, #3200               ; BACKBUF_SIZE / 2 (word count)
.zero_loop:
                STORED  D0, [XY0]
                INC     XY0, #2                 ; 24-bit step (handles page carry)
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

                ; --- Splice into shell ring ------------------------------
                ; If FOREGROUND_TCB == 0 we are the first shell:
                ;   self-loop and become foreground.
                ; Else insert after current foreground:
                ;   new.next = fg.next; fg.next = new.
                LOADZ   D0, [#FOREGROUND_TCB]
                CMP     D0, #0
                BEQ     .first_shell

                ; --- Insert after current foreground --------------------
                ; D0 = foreground TID. _TidToTcb returns XY1 = its TCB,
                ; clobbering X1; save our offset in D2 first.
                MOVE    D2, X1                  ; D2 = our TCB offset
                CALL24  _TidToTcb               ; D0 → XY1, C=1 if not found
                BCS     .err_perm_unwind        ; foreground vanished (defensive)

                ; XY1 = foreground's TCB. Splice in:
                ;   new.next = fg.next; fg.next = new
                ; "new" = our TCB at offset D2 in page $00.
                ; TCB_SHELL_NEXT at $50 — mode-01 [XY+D].
                LOADI   D3, #TCB_SHELL_NEXT     ; D3 = field offset (constant)
                LOADD   D0, [XY1+D3]            ; D0 = fg's current next
                STORED  D2, [XY1+D3]            ; fg.next = us (= D2 = our offset)
                ; Now point XY1 back at our own TCB and write new.next.
                MOVE    X1, D2
                LOADI   Y1, #$00
                STORED  D0, [XY1+D3]            ; new.next = saved fg.next
                BRA     .commit

.first_shell:
                ; new.next = self (singleton ring), FOREGROUND_TCB = our TID,
                ; FIRST_SHELL_TID = our TID (anchor for Ctrl-digit switch).
                ; X1 still holds our TCB offset.
                ; TCB_SHELL_NEXT at $50 — mode-01.
                MOVE    D0, X1
                LOADI   D1, #TCB_SHELL_NEXT
                STORED  D0, [XY1+D1]
                ; FOREGROUND_TCB = our TID;  FIRST_SHELL_TID = our TID
                LOADD   D0, [XY1+#TCB_ID]
                STOREZ  D0, [#FOREGROUND_TCB]
                STOREZ  D0, [#FIRST_SHELL_TID]

.commit:
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
                ; --- 1. Clear/home terminal -------------------------------
                LOADI   Y0, #TERMINAL_PAGE
                LOADI   X0, #$0000

                LOADZ   D0, [#KOS_HOST]
                CMP     D0, #HOST_DIGITAL
                BEQ     .rb_clear_digital

                ; EMU path: emit ESC[3J then ESC[2J then ESC[H.
                ;   ESC[3J — clear scrollback (xterm extension). Prevents
                ;           old scrollback content from re-entering the
                ;           visible region when our paint exceeds the
                ;           terminal's row count (which causes scrolls).
                ;   ESC[2J — clear visible region. Per spec, leaves cursor
                ;           in place.
                ;   ESC[H  — home cursor to (1,1).
                LOADI   D0, #$1B                ; ESC
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
                BRA     .rb_paint

.rb_clear_digital:
                ; Digital path: Form Feed clears and homes in one byte.
                LOADI   D0, #$0C
                STOREB  D0, [XY0]

.rb_paint:
                ; --- 2. Paint back-buffer -------------------------------
                ; XY2 = walking back-buffer pointer. Resolve from TCB.
                LOADI   D0, #TCB_BACKBUF_OFFS
                LOADD   D0, [XY1+D0]
                MOVE    X2, D0
                LOADI   D0, #TCB_BACKBUF_PAGE
                LOADD   D0, [XY1+D0]
                MOVE    Y2, D0

                ; --- 2a. Pre-scan: find row count to paint --------------
                ; Walk the entire 6400-byte back-buffer once, tracking the
                ; highest byte index where a non-zero cell sits. Then
                ; compute its row (offset / KOS_TERM_COLS) and paint that
                ; many rows + 1.
                ;
                ; This avoids painting trailing blank rows. With a 63-row
                ; terminal and an 80-row back-buffer, painting 80 rows
                ; would scroll the top 17 rows off the visible window
                ; (banner included). By painting only what's actually
                ; written, content stays on-screen.
                ;
                ; Cost: ~6400 byte reads (~30K cycles), trivial vs the
                ; paint itself.
                ;
                ; Registers used here:
                ;   XY0 = terminal MMIO ptr (preserved)
                ;   XY1 = caller TCB ptr (preserved — needed to re-resolve XY2)
                ;   XY2 = scan pointer (walks through buffer)
                ;   D1  = byte index 0..6399
                ;   D3  = highest non-blank byte index, or $FFFF if none
                ;   D0  = scratch
                ;
                ; XY2 is re-resolved from TCB after the scan, so we don't
                ; need to save it here.
                LOADI   D1, #0                  ; byte index
                LOADI   D3, #$FFFF              ; max_byte_idx = none

.rb_scan_loop:
                LOADB   D0, [XY2]
                INC     XY2, #1
                CMP     D0, #0
                BEQ.S   .rb_scan_step
                MOVE    D3, D1                  ; remember highest
.rb_scan_step:
                ADD     D1, #1
                CMP     D1, #6400               ; BACKBUF_SIZE
                BLO     .rb_scan_loop

                ; Re-resolve XY2 = back-buffer base from TCB. (The scan
                ; walked XY2 forward 6400 bytes via INC XY2, which carries
                ; into Y2 if X2 wraps — defensively re-load both.)
                LOADI   D0, #TCB_BACKBUF_OFFS
                LOADD   D0, [XY1+D0]
                MOVE    X2, D0
                LOADI   D0, #TCB_BACKBUF_PAGE
                LOADD   D0, [XY1+D0]
                MOVE    Y2, D0

                ; Compute row count from D3.
                ;   If D3 == $FFFF, no content → paint zero rows (just
                ;   the clear screen leaves a blank).
                ;   Else: row_count = (D3 / 80) + 1
                CMP     D3, #$FFFF
                BEQ     .rb_paint_done

                ; Division by 80 via repeated subtraction. Max 80 iters.
                ; D3 = remaining byte index, D2 = row quotient.
                LOADI   D2, #0
.rb_div_loop:
                CMP     D3, #80
                BLO.S   .rb_div_done
                SUB     D3, #80
                ADD     D2, #1
                BRA     .rb_div_loop
.rb_div_done:
                ADD     D2, #1                  ; rows are 1-based (saw row R → paint R+1 rows)

                ; D2 now = number of rows to paint (1..KOS_TERM_ROWS).
                ; Move to D1 so we don't lose it inside the row loop.
                MOVE    D1, D2

                ; D2 = current row index (0..D1-1).
                LOADI   D2, #0

.rb_row_loop:
                ; D3 = column counter (0..79).
                LOADI   D3, #0

.rb_col_loop:
                LOADB   D0, [XY2]
                INC     XY2, #1
                ; Substitute space for zero (unwritten cell).
                CMP     D0, #0
                BNE.S   .rb_emit
                LOADI   D0, #$20                ; ' '
.rb_emit:
                STOREB  D0, [XY0]
                ADD     D3, #1
                CMP     D3, #KOS_TERM_COLS
                BLO     .rb_col_loop

                ; End of row.
                ;
                ; Digital: rely on dumb-TTY auto-wrap to advance row.
                ;   Emitting 80 chars puts the cursor at col 80, which
                ;   wraps to col 0 of the next row. Explicit CR/LF here
                ;   would advance a SECOND time and double-space.
                ;
                ; EMU: VT100 does NOT auto-wrap reliably in this build —
                ;   the 80th char sits at col 79 and subsequent chars
                ;   stream onto the same row. Need explicit CR/LF.
                ;
                ; If we just painted the last row, skip the terminator.
                ADD     D2, #1
                CMP     D2, D1
                BHS.S   .rb_paint_done

                LOADZ   D0, [#KOS_HOST]
                CMP     D0, #HOST_DIGITAL
                BEQ     .rb_row_loop            ; Digital: no CR/LF; loop

                ; EMU: explicit CR + LF.
                LOADI   D0, #$0D
                STOREB  D0, [XY0]
                LOADI   D0, #$0A
                STOREB  D0, [XY0]
                BRA     .rb_row_loop

.rb_paint_done:
                ; --- 3. Position terminal cursor (EMU only) -------------
                LOADZ   D0, [#KOS_HOST]
                CMP     D0, #HOST_DIGITAL
                BEQ     .rb_return

                ; Emit ESC [ <row+1> ; <col+1> H.  Stored cursor is
                ; 0-based; VT100 is 1-based.
                LOADI   D2, #TCB_BACKBUF_CRSR
                LOADD   D3, [XY1+D2]            ; D3 = (row<<8) | col

                MOVE    D2, D3
                HIGH    D2                      ; D2 = row (0-based)
                ADD     D2, #1                  ; → 1-based
                MOVE    D0, D3
                LOW     D0                      ; D0 = col (0-based)
                ADD     D0, #1                  ; → 1-based

                ; Save D0 (col 1-based) for after the row emit.
                PUSH    D0, XY3

                ; Emit ESC [
                LOADI   D1, #$1B
                STOREB  D1, [XY0]
                LOADI   D1, #'['
                STOREB  D1, [XY0]

                ; Emit row digits.  D0 = row for _PutDecSmall.
                MOVE    D0, D2
                CALL24  _PutDecSmall            ; clobbers D0, D2, D3

                ; Emit ';'
                LOADI   D1, #';'
                STOREB  D1, [XY0]

                ; Emit col digits.
                POP     D0, XY3
                CALL24  _PutDecSmall

                ; Emit 'H'
                LOADI   D1, #'H'
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

                ; Defensive: confirm successor still has TF_HAS_BACKBUF.
                ; A killed shell should be unlinked by Step 10's death
                ; cleanup, but if we ever land here mid-cleanup, don't
                ; install a non-shell as foreground.
                LOADD   D1, [XY1+#TCB_FLAGS]
                AND     D1, #TF_HAS_BACKBUF
                CMP     D1, #0
                BEQ     .none                   ; not a shell anymore → no-op

                ; Commit: FOREGROUND_TCB := new.TCB_ID
                LOADD   D0, [XY1+#TCB_ID]
                STOREZ  D0, [#FOREGROUND_TCB]

                ; Repaint screen from new foreground's back-buffer.
                ; XY1 already points at the new TCB.
                CALL24  _RepaintFromBackbuf
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
                ; starting point. The predecessor in a singleton ring is
                ; the foreground itself (self-loop): the very first
                ; iteration sees fg.next.TID == fg.TID and accepts fg as
                ; its own predecessor.
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
                ; XY1 is the predecessor TCB. Defensive: confirm it
                ; still has TF_HAS_BACKBUF (paranoia, per the same
                ; reasoning as _SwitchForegroundNext).
                LOADD   D1, [XY1+#TCB_FLAGS]
                AND     D1, #TF_HAS_BACKBUF
                CMP     D1, #0
                BEQ     .none

                ; Commit: FOREGROUND_TCB := predecessor.TCB_ID
                LOADD   D0, [XY1+#TCB_ID]
                STOREZ  D0, [#FOREGROUND_TCB]

                ; Repaint from the new foreground's back-buffer.
                CALL24  _RepaintFromBackbuf
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
;                 D0 = ERR_INVALID  — target lacks TF_HAS_BACKBUF
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

                ; --- Validate target has TF_HAS_BACKBUF ---
                LOADD   D1, [XY1+#TCB_FLAGS]
                AND     D1, #TF_HAS_BACKBUF
                CMP     D1, #0
                BEQ     .err_invalid

                ; --- Commit: FOREGROUND_TCB := target.TCB_ID ---
                LOADD   D0, [XY1+#TCB_ID]
                STOREZ  D0, [#FOREGROUND_TCB]

                ; Repaint screen from target's back-buffer. XY1 = target TCB.
                CALL24  _RepaintFromBackbuf

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
                ; XY1 = target TCB. Defensive: still a shell?
                LOADD   D0, [XY1+#TCB_FLAGS]
                AND     D0, #TF_HAS_BACKBUF
                CMP     D0, #0
                BEQ     .sfi_none

                ; Commit: FOREGROUND_TCB := target.TCB_ID
                LOADD   D0, [XY1+#TCB_ID]
                STOREZ  D0, [#FOREGROUND_TCB]

                ; Repaint screen from target's back-buffer.
                CALL24  _RepaintFromBackbuf
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

                ; Load cursor word into D3 (high byte = row, low byte = col).
                ; D1 holds the field offset throughout — reused at the
                ; single commit point at the end.
                LOADI   D1, #TCB_BACKBUF_CRSR
                LOADD   D3, [XY1+D1]

                ; Dispatch.
                CMP     D0, #$0D                ; CR
                BEQ     .do_cr
                CMP     D0, #$0A                ; LF
                BEQ     .do_lf
                CMP     D0, #$08                ; BS
                BEQ     .do_bs
                CMP     D0, #$07                ; BEL — no-op
                BEQ     .bbpc_done

                ; -------- plain visible character --------
                ; D3 = (row<<8) | col. Compute cell address and STOREB.
                ; Stash byte on stack; D-regs become free scratch.
                PUSH    D0, XY3

                ; Extract row → D2, col → D0.
                MOVE    D2, D3
                HIGH    D2                      ; D2 = row
                MOVE    D0, D3
                LOW     D0                      ; D0 = col (preserved for ADD below)

                ; D2 = row*80 = (row<<6) + (row<<4).
                SHL4    D2                      ; D2 = row << 4
                MOVE    D1, D2                  ; D1 = row << 4 (save copy)
                SHL     D2                      ; D2 = row << 5
                SHL     D2                      ; D2 = row << 6
                ADD     D2, D1                  ; D2 = row<<6 + row<<4 = row*80

                ; D2 += col → linear cell offset within back-buffer.
                ADD     D2, D0                  ; D2 = row*80 + col

                ; XY2 := back-buffer base + cell offset.
                LOADI   D1, #TCB_BACKBUF_OFFS
                LOADD   D1, [XY1+D1]
                ADD     D1, D2
                MOVE    X2, D1
                LOADI   D1, #TCB_BACKBUF_PAGE
                LOADD   D1, [XY1+D1]
                MOVE    Y2, D1

                ; Retrieve byte and write to cell.
                POP     D0, XY3
                STOREB  D0, [XY2]

                ; --- Advance cursor in D3 ---
                ; col += 1. If col wraps to KOS_TERM_COLS, reset col, bump row.
                MOVE    D0, D3
                LOW     D0
                ADD     D0, #1                  ; D0 = candidate new col
                CMP     D0, #KOS_TERM_COLS
                BLO     .pack_col_only

                ; col wrapped → col = 0; row += 1; maybe scroll.
                LOADI   D0, #0                  ; new col
                MOVE    D2, D3
                HIGH    D2                      ; D2 = old row
                ADD     D2, #1                  ; row += 1
                CMP     D2, #KOS_TERM_ROWS
                BLO.S   .pack_row_col

                ; Row overflow → scroll, row := ROWS-1.
                CALL24  _BackbufScroll
                LOADI   D2, #79                 ; ROWS - 1 (literal — no arith in imm)
.pack_row_col:
                ; D3 = (D2 << 8) | D0.
                MOVE    D3, D2
                SHL4    D3
                SHL4    D3                      ; D3 = row << 8
                OR      D3, D0                  ; D3 |= col
                BRA     .bbpc_done

.pack_col_only:
                ; D3 high byte unchanged; replace low byte with new col (D0).
                AND     D3, #$FF00
                OR      D3, D0
                BRA     .bbpc_done

.do_cr:
                ; col := 0; row unchanged.
                AND     D3, #$FF00
                BRA     .bbpc_done

.do_lf:
                ; row += 1, col := 0  (Unix newline semantics — most callers
                ; emit bare '\n' expecting it to do both CR and LF, matching
                ; how the terminal itself interprets LF in NL mode).
                MOVE    D2, D3
                HIGH    D2
                ADD     D2, #1
                CMP     D2, #KOS_TERM_ROWS
                BLO.S   .lf_pack
                CALL24  _BackbufScroll
                LOADI   D2, #79
.lf_pack:
                ; Drop both old row and old col; D3 := (D2 << 8) | 0.
                MOVE    D3, D2
                SHL4    D3
                SHL4    D3
                BRA     .bbpc_done

.do_bs:
                ; if col > 0: col -= 1.  Row unaffected because col >= 1 here.
                MOVE    D0, D3
                LOW     D0
                CMP     D0, #0
                BEQ.S   .bbpc_done
                SUB     D3, #1

.bbpc_done:
                ; Single commit: write D3 back to TCB_BACKBUF_CRSR.
                LOADI   D1, #TCB_BACKBUF_CRSR
                STORED  D3, [XY1+D1]
                POP     XY1, XY3
                RET


; ----------------------------------------------------------------------------
; _BackbufScroll — shift rows 1..ROWS-1 up by one; blank new bottom row
;
; Used internally by _BackbufPutChar when an LF or wrap pushes the cursor
; past the last row. Cost is ~7K cycles (2320-byte memmove + 80-byte blank).
;
; In:        XY1 = caller's TCB pointer
; Out:       back-buffer rows shifted up; bottom row blanked
; Clobbers:  D0, D1, D2, D3, XY0, XY2
; Preserves: XY1, XY3
; ----------------------------------------------------------------------------
_BackbufScroll:
                ; Resolve back-buffer base into XY2 (Y2:X2).
                ; LOADD targets a D register; build X2 via D->X MOVE.
                LOADI   D1, #TCB_BACKBUF_OFFS
                LOADD   D0, [XY1+D1]
                MOVE    X2, D0
                LOADI   D1, #TCB_BACKBUF_PAGE
                LOADD   D0, [XY1+D1]
                MOVE    Y2, D0

                ; XY0 = dest (row 0), XY2 = source (row 1). Walk forward
                ; (ROWS-1)*COLS = 79*80 = 6320 bytes.
                LEA     XY0, XY2            ; XY0 = base (row 0)
                ; Bump XY2 by 80 bytes using 24-bit INC (handles page carry
                ; if the back-buffer base sits near end-of-page).
                ; INC XY only accepts #imm5 (0..31), so split into 3 INCs.
                INC     XY2, #31
                INC     XY2, #31
                INC     XY2, #18            ; total = 80

                LOADI   D3, #6320           ; (KOS_TERM_ROWS-1) * KOS_TERM_COLS
                                            ; = 79 * 80; literal because the
                                            ; assembler doesn't evaluate
                                            ; arithmetic in immediates.
.scroll_loop:
                LOADB   D0, [XY2]
                STOREB  D0, [XY0]
                INC     XY0, #1
                INC     XY2, #1
                SUB     D3, #1
                BNE     .scroll_loop

                ; XY0 now points at start of the new bottom row.
                ; Blank 80 bytes.
                LOADI   D0, #0
                LOADI   D3, #KOS_TERM_COLS  ; 80
.blank_loop:
                STOREB  D0, [XY0]
                INC     XY0, #1
                SUB     D3, #1
                BNE     .blank_loop

                RET


; ============================================================================
; End of kos_switcher.asm (r6)
; ============================================================================
