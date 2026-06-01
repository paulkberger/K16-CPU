; ============================================================================
; kosh_splash.asm — k/OS sign-on splash, painted from kosh task context
; ============================================================================
; Date:    29 May 2026
; Status:  Part 40 - dynamic version/date from kernel identity slots.
;
; Revision: r8 - 29 May 2026 — Part 40: tightened the version/phase
;             separator from two spaces to one (splash_logo2b "  " → " ").
;             Affects both the splash logo line and info's k/OS line,
;             which share this string. Now renders "v1.0 Phase 39+".
;
;           r7 - 29 May 2026 — Part 40: correct root-cause fix for the
;             empty phase tag (supersedes the r6 byte-loop, which treated
;             a non-existent problem). The phase-tag string is kernel ROM
;             at page $FF (kos_boot.asm .ORG $FF0000) — both r5 and r6
;             wrongly used page $00 (kernel zero-page RAM), so the read
;             missed the string entirely. sys_puts was never at fault; it
;             honours the Y0 page byte (kos_console.asm copies the full
;             pointer via LEA). Fix: the kernel now publishes the ROM page
;             byte in KOS_PHASE_TAG_PAGE; _OSSplashPhase reads page+offset
;             and does a single plain sys_puts. Byte-loop removed.
;             Requires kos_defs.inc r44+ and kos_boot.asm r52+.
;
;           r6 - 29 May 2026 — Part 40 first-boot fix attempt: byte-loop
;             via sys_putchar (MISDIAGNOSED — page byte was the real
;             issue; see r7). Retained in history for the audit trail.
;
;           r5 - 29 May 2026 — Part 40: splash version + boot date now
;             read live from the page-$00 kernel-identity slots
;             (KOS_VERSION, KOS_BUILD_DAY/MONTH/YEAR, KOS_PHASE_TAG_PTR)
;             instead of being baked into ROM strings. Two new in-image
;             helpers added: _OSSplashVer (emits "major.minor" via
;             HIGH/LOW + TRAP_PUTDEC) and _OSSplashPhase (emits the
;             kernel phase-tag string, which lives in kernel ROM page
;             $00 — so Y0 is forced to $00, not Y3). splash_logo2 split
;             into splash_logo2a (prefix "...k/OS  v") + splash_logo2b
;             (2-space separator); the version digits and phase tag are
;             emitted inline between them. splash_boot replaced by
;             splash_boot_lbl ("Boot:     ") + inline day / month-name /
;             year emission, with a 12-entry fixed-4-byte-stride
;             month_names table indexed (KOS_BUILD_MONTH-1)*4.
;             TRAP_PUTDEC emits the full unsigned value so v1.10 / v10.0
;             and 1-or-2-digit days render correctly with no per-digit
;             code. Bonus: fixes the stale "16 May" boot string (build
;             day is 29). Bumping the kernel version is now a single
;             edit at the top of kos_boot.asm — kosh.com still needs a
;             rebuild to pick up the new render code, but no string
;             edits. Requires kos_defs.inc r43+ (identity slots) and
;             kos_boot.asm r51+ (slots populated by _InitKernel).
;
;           r4 - 29 May 2026 — Part 39 post-first-boot fix: internal
;             CALL24 _OSSplashHexByte converted to CALL16 (line 193).
;             _OSSplashHexByte lives inside the kosh.com image so its
;             address depends on the runtime task page; CALL24 was
;             hardcoded to assembly-time page $00 (kernel page) and
;             jumped to wrong code. CALL16 uses Y3 implicitly, which
;             is the task's runtime page. Symptom: heap-line emission
;             during _OSSplash would silently scribble or HALT.
;             Requires kosh.asm r39 (latest).
;
;             Also: bumped k/OS version in splash_logo2 from
;                 "k/OS  v0.6  Phase 16+"
;             to
;                 "k/OS  v1.0  Phase 39+"
;             to reflect the 1.0 milestone (Part 39 closed the
;             standalone .com shell design; the OS is now feature-
;             complete by 1.0 standards).
;
; Revision: r3 - 29 May 2026 — Part 39: kosh.com migration. 20 string
;             references switched from
;                 #SPAWN_ENTRY_OFFSET + (label - kosh_entry)
;             to bare
;                 #label
;             because kosh.asm now assembles with .ORG $0200 and labels
;             resolve directly to their in-page addresses. No behaviour
;             change. Doc comments at the top of the file and above the
;             Splash strings rewritten to reflect the .ORG $0200 model.
;             Requires kosh.asm r39+.
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
;       _OSSplash sits inside the kosh.com image; kosh.asm assembles with
;       .ORG $0200, so string labels resolve directly to their in-page
;       addresses, the same way every other kosh string reference works.
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
                LOADI   X0, #splash_logo1
                TRAP    #TRAP_PUTS

                ; Logo line 2 carries the live k/OS version + phase tag,
                ; read from the page-$00 identity slots (Part 40).
                MOVE    Y0, Y3
                LOADI   X0, #splash_logo2a      ; "...k/OS  v"
                TRAP    #TRAP_PUTS
                CALL16  _OSSplashVer            ; "1.0"
                MOVE    Y0, Y3
                LOADI   X0, #splash_logo2b      ; " " (1-space sep)
                TRAP    #TRAP_PUTS
                CALL16  _OSSplashPhase          ; "Phase 39+"
                LOADI   D0, #$0A
                TRAP    #TRAP_PUTCHAR

                MOVE    Y0, Y3
                LOADI   X0, #splash_logo3
                TRAP    #TRAP_PUTS

                MOVE    Y0, Y3
                LOADI   X0, #splash_logo4
                TRAP    #TRAP_PUTS

                ;-- Blank line separator -----------------------------------
                LOADI   D0, #$0A
                TRAP    #TRAP_PUTCHAR

                ;-- Host line ----------------------------------------------
                MOVE    Y0, Y3
                LOADI   X0, #splash_host_lbl
                TRAP    #TRAP_PUTS

                LOADZ   D0, [#KOS_HOST]
                LOW     D0
                CMP     D0, #HOST_DIGITAL
                BEQ.S   .host_dig
                MOVE    Y0, Y3
                LOADI   X0, #splash_host_emu
                BRA.S   .host_emit
.host_dig:
                MOVE    Y0, Y3
                LOADI   X0, #splash_host_dig
.host_emit:
                TRAP    #TRAP_PUTS

                ;-- Kernel line --------------------------------------------
                MOVE    Y0, Y3
                LOADI   X0, #splash_kernel
                TRAP    #TRAP_PUTS

                ;-- Heap line ----------------------------------------------
                MOVE    Y0, Y3
                LOADI   X0, #splash_heap_lbl
                TRAP    #TRAP_PUTS

                LOADZ   D0, [#HEAP_BYTES_FREE]
                TRAP    #TRAP_PUTDEC

                MOVE    Y0, Y3
                LOADI   X0, #splash_heap_mid
                TRAP    #TRAP_PUTS

                LOADZ   D0, [#HEAP_REGIONS]
                TRAP    #TRAP_PUTDEC

                MOVE    Y0, Y3
                LOADI   X0, #splash_heap_tail
                TRAP    #TRAP_PUTS

                ;-- Pages line — "N free of M user pages ($02..$XX)" ------
                MOVE    Y0, Y3
                LOADI   X0, #splash_pages_lbl
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
                LOADI   X0, #splash_pages_mid
                TRAP    #TRAP_PUTS

                ; Total user pages = KOS_USER_PAGE_END - USER_PAGE_BASE + 1
                LOADZ   D0, [#KOS_USER_PAGE_END]
                LOW     D0
                SUB     D0, #USER_PAGE_BASE
                ADD     D0, #1
                TRAP    #TRAP_PUTDEC

                MOVE    Y0, Y3
                LOADI   X0, #splash_pages_range
                TRAP    #TRAP_PUTS

                ; Page range upper bound as 2 hex digits.
                LOADZ   D0, [#KOS_USER_PAGE_END]
                LOW     D0
                CALL16  _OSSplashHexByte

                MOVE    Y0, Y3
                LOADI   X0, #splash_pages_tail
                TRAP    #TRAP_PUTS

                ;-- Tasks line — "N of M user (+ 1 idle)" ------------------
                ; r2 (16 May 2026): was "1 idle + N user slots" (capacity
                ; only). Now shows live active-user-task count / capacity.
                ; At boot kosh is the only active user task (it's painting
                ; this splash), so N=1. Walk inverse of pages free walk.
                MOVE    Y0, Y3
                LOADI   X0, #splash_tasks_lbl
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
                LOADI   X0, #splash_tasks_mid
                TRAP    #TRAP_PUTS

                ; Capacity = KOS_USER_PAGE_END - USER_PAGE_BASE + 1
                LOADZ   D0, [#KOS_USER_PAGE_END]
                LOW     D0
                SUB     D0, #USER_PAGE_BASE
                ADD     D0, #1
                TRAP    #TRAP_PUTDEC

                MOVE    Y0, Y3
                LOADI   X0, #splash_tasks_tail
                TRAP    #TRAP_PUTS

                ;-- Boot date — "Boot:     <day> <Mon> <year>" -------------
                ; All three fields read live from page-$00 identity slots.
                MOVE    Y0, Y3
                LOADI   X0, #splash_boot_lbl    ; "Boot:     "
                TRAP    #TRAP_PUTS

                LOADZ   D0, [#KOS_BUILD_DAY]
                LOW     D0
                TRAP    #TRAP_PUTDEC            ; day (no leading zero)

                LOADI   D0, #' '
                TRAP    #TRAP_PUTCHAR

                ; Month name: month_names + (KOS_BUILD_MONTH-1)*4 (4-byte stride).
                LOADZ   D0, [#KOS_BUILD_MONTH]
                LOW     D0
                SUB     D0, #1
                SHL     D0, #2                  ; *4
                ADD     D0, #month_names
                MOVE    X0, D0
                MOVE    Y0, Y3                  ; table is in kosh page
                TRAP    #TRAP_PUTS

                LOADI   D0, #' '
                TRAP    #TRAP_PUTCHAR

                LOADZ   D0, [#KOS_BUILD_YEAR]
                TRAP    #TRAP_PUTDEC            ; year (full value, e.g. 2026)

                LOADI   D0, #$0A
                TRAP    #TRAP_PUTCHAR

                ;-- Closing rule -------------------------------------------
                MOVE    Y0, Y3
                LOADI   X0, #splash_rule
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
; _OSSplashVer — emit live k/OS version as "major.minor" decimal
;
; Reads KOS_VERSION ($XXYY, X=major Y=minor) from the page-$00 identity
; slot. TRAP_PUTDEC emits the full unsigned value, so v1.10 / v10.0 etc.
; render correctly without per-digit handling.
;
; In:        none
; Out:       none (digits emitted via TRAP_PUTDEC / TRAP_PUTCHAR)
; Clobbers:  D0, flags (+ whatever PUTDEC/PUTCHAR clobber)
; ============================================================================
_OSSplashVer:
                LOADZ   D0, [#KOS_VERSION]
                HIGH    D0                      ; major (bits 15:8)
                TRAP    #TRAP_PUTDEC
                LOADI   D0, #'.'
                TRAP    #TRAP_PUTCHAR
                LOADZ   D0, [#KOS_VERSION]
                LOW     D0                      ; minor (bits 7:0)
                TRAP    #TRAP_PUTDEC
                RET

; ============================================================================
; _OSSplashPhase — emit the kernel phase-tag string (e.g. "Phase 39+")
;
; The phase-tag string lives in kernel ROM, which is at page $FF
; (kos_boot.asm is .ORG $FF0000) — NOT page $00 (that's kernel zero-page
; RAM). The kernel publishes the full address across two page-$00 slots:
; KOS_PHASE_TAG_PAGE ($FF) and KOS_PHASE_TAG_PTR (16-bit offset). We load
; both and hand the complete pointer to sys_puts, which honours the Y0
; page byte (kos_console.asm copies the full XY0 via LEA), so a plain
; one-shot puts works — no per-byte loop, no page assumptions.
;
; In:        none
; Out:       none (string emitted via TRAP_PUTS)
; Clobbers:  D0, XY0, flags
; ============================================================================
_OSSplashPhase:
                LOADZ   D0, [#KOS_PHASE_TAG_PAGE] ; ROM page byte ($FF)
                MOVE    Y0, D0
                LOADZ   D0, [#KOS_PHASE_TAG_PTR]  ; 16-bit offset within page $FF
                MOVE    X0, D0
                TRAP    #TRAP_PUTS
                RET
;   Strings live inside the kosh.com image; kosh.asm assembles with
;   .ORG $0200, so each label resolves directly to its in-page address.
; ============================================================================
splash_logo1:   .TEXT   " _      _____  ___", $0A, 0
; Logo line 2 is rendered in three parts (Part 40): prefix string, live
; version digits (_OSSplashVer), 1-space separator, live phase tag
; (_OSSplashPhase), then a newline emitted inline. The trailing "v" of
; the prefix immediately precedes the version digits.
splash_logo2a:  .TEXT   "| |__  / / _ \\/ __|   k/OS  v", 0
splash_logo2b:  .TEXT   " ", 0
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

; Boot date rendered as label + live day / month-name / year (Part 40).
splash_boot_lbl:    .TEXT   "Boot:     ", 0

; Month-name table — 12 entries at a fixed 4-byte stride ("Xxx" + NUL).
; Indexed by (KOS_BUILD_MONTH - 1) * 4. Each .TEXT entry is exactly 4
; bytes (even), so the stride is constant and word-aligned — no odd-count
; .BYTE hazard.
month_names:        .TEXT   "Jan", 0
                    .TEXT   "Feb", 0
                    .TEXT   "Mar", 0
                    .TEXT   "Apr", 0
                    .TEXT   "May", 0
                    .TEXT   "Jun", 0
                    .TEXT   "Jul", 0
                    .TEXT   "Aug", 0
                    .TEXT   "Sep", 0
                    .TEXT   "Oct", 0
                    .TEXT   "Nov", 0
                    .TEXT   "Dec", 0

splash_rule:        .TEXT   "----------------------------------------------------------", $0A, 0

; ============================================================================
; End of kosh_splash.asm
; ============================================================================
