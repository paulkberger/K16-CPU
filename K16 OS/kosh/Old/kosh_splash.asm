; ============================================================================
; kosh_splash.asm — k/OS sign-on splash, painted from kosh task context
; ============================================================================
; Date:    16 May 2026
; Status:  k/OS Part 31 — Tasks line shows active/capacity (matches info r6)
;
; Revision: r2 - 16 May 2026 — Tasks line: "N of M user (+ 1 idle)".
;             Splash and info (kosh_cmds_sys.asm r6) share strings, so
;             both changed together. New layout walks USER_TCB_BASE..
;             TCB_POOL_END counting non-UNUSED slots (D1 = active count),
;             emits N, then " of " (new splash_tasks_mid), then capacity,
;             then " user (+ 1 idle)\n" (was " user slots\n").
;
;             splash_tasks_lbl: was "Tasks:    1 idle + " -> "Tasks:    "
;             splash_tasks_mid: new -> " of "
;             splash_tasks_tail: was " user slots\n" -> " user (+ 1 idle)\n"
;
;             At boot, kosh has just spawned (it's the task painting
;             this splash), so the count is 1 — splash renders "1 of 62
;             user (+ 1 idle)". Accurate, not aspirational.
;
;             The active-count walk is a near-duplicate of the existing
;             free-page walk above (just BEQ instead of BNE on the
;             TS_UNUSED check). Could be factored into a helper later
;             but the two loops are 12 instructions each — clearer to
;             keep them inline.
;
;           r1 - 14 May 2026 — Initial port from kernel/kos_splash.asm r12.
;             The kernel boot path now emits an ephemeral 3-line trace
;             ("Loading k/OS" / "Formatting B: ... OK" / "Loading k/OS
;             shell... OK") via _RawPuts; once kosh is running, its
;             first act after TRAP_REGISTER_SHELL is CALL24 _OSSplash,
;             which clears the screen and paints the full sign-on. This
;             means:
;               (1) the splash lands in the shell back-buffer and
;                   survives foreground switching (Phase B), and
;               (2) the splash content reads live from kernel page $00
;                   (KOS_HOST, HEAP_BYTES_FREE, HEAP_REGIONS,
;                   KOS_USER_PAGE_END) rather than being baked into ROM
;                   at the moment the kernel was assembled.
;
; Purpose: _OSSplash — clear the screen and paint the k/OS sign-on:
;            - 4-line ASCII k/OS logo with tagline
;            - 6 info lines (Host, Kernel, Heap, Pages, Tasks, Boot)
;            - 58-dash horizontal rule
;
;          All output is via TRAP_CLEAR / TRAP_PUTS / TRAP_PUTDEC /
;          TRAP_PUTCHAR, so the output routing in kos_console.asm
;          captures every byte into the back-buffer. _RawPuts is NOT
;          used.
;
;          Page-$00 globals are read with LOADZ (Y3 = kosh task page,
;          not kernel page).
;
; Note: included from kosh.asm via .INCLUDE "../kosh/kosh_splash.asm".
;       _OSSplash sits inside the kosh_entry body so SPAWN_ENTRY_OFFSET +
;       (string - kosh_entry) offsets resolve at assembly time, the same
;       way every other kosh string reference works.
; ============================================================================

; ============================================================================
; _OSSplash — clear screen and paint the k/OS sign-on
;
; In:        none
; Out:       none
; Clobbers:  D0, D1, D2, XY0, flags
; Preserves: D3, XY1, XY2, XY3
; ============================================================================
_OSSplash:
                PUSH    D1, XY3
                PUSH    D2, XY3

                ;-- Clear screen + home cursor ------------------------------
                TRAP    #TRAP_CLEAR

                ;-- Logo (4 lines) -----------------------------------------
                MOVE    Y0, Y3
                LOADI   X0, #SPAWN_ENTRY_OFFSET + (splash_logo1 - kosh_entry)
                TRAP    #TRAP_PUTS

                MOVE    Y0, Y3
                LOADI   X0, #SPAWN_ENTRY_OFFSET + (splash_logo2 - kosh_entry)
                TRAP    #TRAP_PUTS

                MOVE    Y0, Y3
                LOADI   X0, #SPAWN_ENTRY_OFFSET + (splash_logo3 - kosh_entry)
                TRAP    #TRAP_PUTS

                MOVE    Y0, Y3
                LOADI   X0, #SPAWN_ENTRY_OFFSET + (splash_logo4 - kosh_entry)
                TRAP    #TRAP_PUTS

                ;-- Blank line separator -----------------------------------
                LOADI   D0, #$0A
                TRAP    #TRAP_PUTCHAR

                ;-- Host line ----------------------------------------------
                MOVE    Y0, Y3
                LOADI   X0, #SPAWN_ENTRY_OFFSET + (splash_host_lbl - kosh_entry)
                TRAP    #TRAP_PUTS

                LOADZ   D0, [#KOS_HOST]
                LOW     D0
                CMP     D0, #HOST_DIGITAL
                BEQ.S   .host_dig
                MOVE    Y0, Y3
                LOADI   X0, #SPAWN_ENTRY_OFFSET + (splash_host_emu - kosh_entry)
                BRA.S   .host_emit
.host_dig:
                MOVE    Y0, Y3
                LOADI   X0, #SPAWN_ENTRY_OFFSET + (splash_host_dig - kosh_entry)
.host_emit:
                TRAP    #TRAP_PUTS

                ;-- Kernel line --------------------------------------------
                MOVE    Y0, Y3
                LOADI   X0, #SPAWN_ENTRY_OFFSET + (splash_kernel - kosh_entry)
                TRAP    #TRAP_PUTS

                ;-- Heap line ----------------------------------------------
                MOVE    Y0, Y3
                LOADI   X0, #SPAWN_ENTRY_OFFSET + (splash_heap_lbl - kosh_entry)
                TRAP    #TRAP_PUTS

                LOADZ   D0, [#HEAP_BYTES_FREE]
                TRAP    #TRAP_PUTDEC

                MOVE    Y0, Y3
                LOADI   X0, #SPAWN_ENTRY_OFFSET + (splash_heap_mid - kosh_entry)
                TRAP    #TRAP_PUTS

                LOADZ   D0, [#HEAP_REGIONS]
                TRAP    #TRAP_PUTDEC

                MOVE    Y0, Y3
                LOADI   X0, #SPAWN_ENTRY_OFFSET + (splash_heap_tail - kosh_entry)
                TRAP    #TRAP_PUTS

                ;-- Pages line — "N free of M user pages ($02..$XX)" ------
                MOVE    Y0, Y3
                LOADI   X0, #SPAWN_ENTRY_OFFSET + (splash_pages_lbl - kosh_entry)
                TRAP    #TRAP_PUTS

                ; Free = walk USER_TCB_BASE..TCB_POOL_END counting UNUSED.
                LOADI   D2, #USER_TCB_BASE
                LOADI   D1, #0
.count_loop:
                CMP     D2, #TCB_POOL_END
                BHS     .count_done
                LOADI   Y0, #$00
                MOVE    X0, D2
                LOADD   D0, [XY0+#TCB_STATE]
                LOW     D0
                CMP     D0, #TS_UNUSED
                BNE.S   .count_skip
                ADD     D1, #1
.count_skip:
                ADD     D2, #TCB_SIZE
                BRA     .count_loop
.count_done:
                MOVE    D0, D1
                TRAP    #TRAP_PUTDEC

                MOVE    Y0, Y3
                LOADI   X0, #SPAWN_ENTRY_OFFSET + (splash_pages_mid - kosh_entry)
                TRAP    #TRAP_PUTS

                ; Total user pages = KOS_USER_PAGE_END - USER_PAGE_BASE + 1
                LOADZ   D0, [#KOS_USER_PAGE_END]
                LOW     D0
                SUB     D0, #USER_PAGE_BASE
                ADD     D0, #1
                TRAP    #TRAP_PUTDEC

                MOVE    Y0, Y3
                LOADI   X0, #SPAWN_ENTRY_OFFSET + (splash_pages_range - kosh_entry)
                TRAP    #TRAP_PUTS

                ; Page range upper bound as 2 hex digits.
                LOADZ   D0, [#KOS_USER_PAGE_END]
                LOW     D0
                CALL24  _OSSplashHexByte

                MOVE    Y0, Y3
                LOADI   X0, #SPAWN_ENTRY_OFFSET + (splash_pages_tail - kosh_entry)
                TRAP    #TRAP_PUTS

                ;-- Tasks line — "N of M user (+ 1 idle)" ------------------
                ; r2 (16 May 2026): was "1 idle + N user slots" (capacity
                ; only). Now shows live active-user-task count / capacity.
                ; At boot kosh is the only active user task (it's painting
                ; this splash), so N=1. Walk inverse of pages free walk.
                MOVE    Y0, Y3
                LOADI   X0, #SPAWN_ENTRY_OFFSET + (splash_tasks_lbl - kosh_entry)
                TRAP    #TRAP_PUTS

                ; Active count: walk USER_TCB_BASE..TCB_POOL_END counting
                ; non-UNUSED (BEQ skips, vs BNE skips in the pages walk).
                LOADI   D2, #USER_TCB_BASE
                LOADI   D1, #0
.active_loop:
                CMP     D2, #TCB_POOL_END
                BHS     .active_done
                LOADI   Y0, #$00
                MOVE    X0, D2
                LOADD   D0, [XY0+#TCB_STATE]
                LOW     D0
                CMP     D0, #TS_UNUSED
                BEQ.S   .active_skip
                ADD     D1, #1
.active_skip:
                ADD     D2, #TCB_SIZE
                BRA     .active_loop
.active_done:
                MOVE    D0, D1
                TRAP    #TRAP_PUTDEC

                MOVE    Y0, Y3
                LOADI   X0, #SPAWN_ENTRY_OFFSET + (splash_tasks_mid - kosh_entry)
                TRAP    #TRAP_PUTS

                ; Capacity = KOS_USER_PAGE_END - USER_PAGE_BASE + 1
                LOADZ   D0, [#KOS_USER_PAGE_END]
                LOW     D0
                SUB     D0, #USER_PAGE_BASE
                ADD     D0, #1
                TRAP    #TRAP_PUTDEC

                MOVE    Y0, Y3
                LOADI   X0, #SPAWN_ENTRY_OFFSET + (splash_tasks_tail - kosh_entry)
                TRAP    #TRAP_PUTS

                ;-- Boot date ----------------------------------------------
                MOVE    Y0, Y3
                LOADI   X0, #SPAWN_ENTRY_OFFSET + (splash_boot - kosh_entry)
                TRAP    #TRAP_PUTS

                ;-- Closing rule -------------------------------------------
                MOVE    Y0, Y3
                LOADI   X0, #SPAWN_ENTRY_OFFSET + (splash_rule - kosh_entry)
                TRAP    #TRAP_PUTS

                POP     D2, XY3
                POP     D1, XY3
                RET

; ============================================================================
; _OSSplashHexByte — emit low byte of D0 as 2 hex digits via TRAP_PUTCHAR
;
; Helper local to the splash. The kernel-side _RawPutHexByte exists in
; kos_rawio.asm for boot/ISR contexts but bypasses the back-buffer;
; from kosh task context we route through TRAP_PUTCHAR so the digits
; land in the shell back-buffer.
;
; In:        D0 = byte
; Out:       none
; Clobbers:  D0, D1, flags
; Preserves: D2, D3, XY0, XY1, XY2, XY3
; ============================================================================
_OSSplashHexByte:
                PUSH    D1, XY3
                PUSH    D2, XY3

                MOVE    D2, D0                  ; D2 = byte

                ; --- High nibble ------------------------------------------
                MOVE    D1, D2
                SHR     D1, #4
                AND     D1, #$000F
                CMP     D1, #10
                BLO.S   .hi_digit
                ADD     D1, #$37                ; 'A' - 10
                BRA.S   .hi_emit
.hi_digit:
                ADD     D1, #'0'
.hi_emit:
                MOVE    D0, D1
                TRAP    #TRAP_PUTCHAR

                ; --- Low nibble -------------------------------------------
                MOVE    D1, D2
                AND     D1, #$000F
                CMP     D1, #10
                BLO.S   .lo_digit
                ADD     D1, #$37
                BRA.S   .lo_emit
.lo_digit:
                ADD     D1, #'0'
.lo_emit:
                MOVE    D0, D1
                TRAP    #TRAP_PUTCHAR

                POP     D2, XY3
                POP     D1, XY3
                RET

; ============================================================================
; Splash strings
;   Strings live inside the kosh_entry body so the assembler can resolve
;   (label - kosh_entry) as a compile-time constant; SPAWN_ENTRY_OFFSET
;   is added at runtime to reach the in-page copy.
; ============================================================================
splash_logo1:   .TEXT   " _      _____  ___", $0A, 0
splash_logo2:   .TEXT   "| |__  / / _ \\/ __|   k/OS  v0.6  Phase 16+", $0A, 0
splash_logo3:   .TEXT   "| / / / / (_) \\__ \\   Multitasking Operating System", $0A, 0
splash_logo4:   .TEXT   "|_\\_\\/_/ \\___/|___/   K16 CPU Project (c) 2026 Paul Berger", $0A, 0

splash_host_lbl:    .TEXT   "Host:     ", 0
splash_host_dig:    .TEXT   "Digital (dumb-TTY, 2MB)", $0A, 0
splash_host_emu:    .TEXT   "EMU (VT100, 16MB)", $0A, 0

splash_kernel:      .TEXT   "Kernel:   Page $00, stack $FFFE", $0A, 0

splash_heap_lbl:    .TEXT   "Heap:     Page $01, ", 0
splash_heap_mid:    .TEXT   " bytes free in ", 0
splash_heap_tail:   .TEXT   " region(s)", $0A, 0

splash_pages_lbl:   .TEXT   "Pages:    ", 0
splash_pages_mid:   .TEXT   " free of ", 0
splash_pages_range: .TEXT   " user pages ($02..$", 0
splash_pages_tail:  .TEXT   ")", $0A, 0

; Tasks line strings (r2 16 May 2026):
;   "Tasks:    " <N active> " of " <M capacity> " user (+ 1 idle)\n"
splash_tasks_lbl:   .TEXT   "Tasks:    ", 0
splash_tasks_mid:   .TEXT   " of ", 0
splash_tasks_tail:  .TEXT   " user (+ 1 idle)", $0A, 0

splash_boot:        .TEXT   "Boot:     16 May 2026", $0A, 0

splash_rule:        .TEXT   "----------------------------------------------------------", $0A, 0

; ============================================================================
; End of kosh_splash.asm
; ============================================================================
