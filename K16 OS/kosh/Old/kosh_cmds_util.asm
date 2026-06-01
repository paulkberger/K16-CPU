; ============================================================================
; kosh_cmds_util.asm — kosh utility commands
; ============================================================================
; Date:    7 May 2026
; Status:  Phase 16.7 — extracted from kosh.asm during Phase 19 split.
;
;   .INCLUDEd from kosh.asm between kosh_entry: and kosh_entry_end: so the
;   page-relative addressing convention
;       SPAWN_ENTRY_OFFSET + (label - kosh_entry)
;   works for strings declared inside this file.
;
;   Commands (dispatch tags in parens, defined in kosh.asm cmd_table):
;     exit        (2)  - leave the shell (sys_exit 0)
;     echo TEXT   (6)  - echo arguments to stdout
;     clear       (7)  - clear the screen via TRAP_CLEAR
;     halt        (8)  - stop the CPU via HALT #0
;     reboot      (9)  - jump to the reset vector at $FF0000
;
;   No CALL24 helpers needed — these all use direct TRAPs.
; ============================================================================


; ----------------------------------------------------------------------------
; .do_exit — leave the shell cleanly.
; ----------------------------------------------------------------------------
.do_exit:
                MOVE    Y0, Y3
                LOADI   X0, #SPAWN_ENTRY_OFFSET + (msg_bye - kosh_entry)
                TRAP    #TRAP_PUTS
                LOADI   D0, #0
                TRAP    #TRAP_EXIT
                ; Does not return.


; ----------------------------------------------------------------------------
; .do_echo — echo the rest of the line.
;
;   On entry XY2 still points at the command-word start (a page-local
;   nul-terminated zstring "echo"). The byte immediately after that nul
;   is either:
;     * another nul     -> the line was just "echo" with no args
;     * the next char   -> args start there (with whatever original
;                          inter-word spacing the user typed past the
;                          first space we overwrote during parsing)
;
;   Walk XY1 = XY2 forward to the nul, step one, then sys_puts what's
;   left.
; ----------------------------------------------------------------------------
.do_echo:
                ; Find end of the command word using KLIB_STRLEN.
                ; XY0 ends pointing AT the nul (per KLIB_STRLEN ABI).
                LEA     XY0, XY2
                CALL24  KLIB_STRLEN
                INC     XY0, #1                 ; step past the nul
                ; If the next byte is also nul, no args -> just newline.
                LOADB   D0, [XY0]
                CMP     D0, #0
                BEQ.S   .echo_no_args
                ; Args present — sys_puts(XY0) directly.
                TRAP    #TRAP_PUTS
.echo_no_args:
                LOADI   D0, #CH_LF
                TRAP    #TRAP_PUTCHAR
                BRA     .repl_loop


; ----------------------------------------------------------------------------
; .do_clear — clear the screen.
; ----------------------------------------------------------------------------
.do_clear:
                TRAP    #TRAP_CLEAR
                BRA     .repl_loop


; ----------------------------------------------------------------------------
; .do_halt — stop the CPU.
;
;   Emits HALT #0. The ISA expects a literal imm5 operand; we use 0
;   to mean "user-initiated clean halt" (distinct from bad_trap codes
;   which use $10..$2F).
; ----------------------------------------------------------------------------
.do_halt:
                MOVE    Y0, Y3
                LOADI   X0, #SPAWN_ENTRY_OFFSET + (msg_halt - kosh_entry)
                TRAP    #TRAP_PUTS
                HALT    #0
                ; Does not return.


; ----------------------------------------------------------------------------
; .do_reboot — jump to the K16 reset vector.
;
;   Start: is the boot entry at $FF0000 (kos_boot.asm). Jumping there
;   from a user task is fine — Start re-initialises everything (vectors,
;   kernel state, heap, KLIB, TCB pool, ...), so the dirty state we
;   leave behind is irrelevant.
;
;   IMPORTANT: must DINT before jumping. Hardware reset starts with
;   IE=0; we're a running task with IE=1. Without DINT the timer can
;   fire during early init — most damagingly inside _InitVectors Pass
;   1a, which transiently fills $0000..$0023 with bad_int. An IRQ
;   landing there hits HALT #$10. EMU is permissive about boot-time
;   IRQ delivery so the bug stays dormant; Digital fires immediately.
; ----------------------------------------------------------------------------
.do_reboot:
                MOVE    Y0, Y3
                LOADI   X0, #SPAWN_ENTRY_OFFSET + (msg_reboot - kosh_entry)
                TRAP    #TRAP_PUTS
                DINT
                JMP24   Start
                ; Does not return.


; ============================================================================
; Util-command strings (page-local, addressed via Y3 + page-offset).
; ============================================================================

msg_bye:       .TEXT   "bye\n",0
msg_halt:      .TEXT   "halted.\n",0
msg_reboot:    .TEXT   "rebooting...\n",0

; Command name strings (for cmd_table)
cmd_exit_str:   .TEXT   "exit",0
cmd_echo_str:   .TEXT   "echo",0
cmd_clear_str:  .TEXT   "clear",0
cmd_halt_str:   .TEXT   "halt",0
cmd_reboot_str: .TEXT   "reboot",0
