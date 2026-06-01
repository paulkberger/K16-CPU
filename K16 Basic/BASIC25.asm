; ============================================================================
; K16 BASIC v2.5 - .COM build for k/OS  (16 May 2026)
; ============================================================================
; v2.5: K16 manual v3.12 + v3.11 instruction-set adoption (Part 33 sweep).
;       Eliminates legacy `PUSH D` / `POP D` (4-register group form removed
;       in v3.12) and adopts the new RETCC / RETCS / PUSH D123 / POP D123
;       instructions where safe. Net: -9 cycles, -5 words across the
;       interpreter image. Functional behaviour unchanged.
;         • L756 `PUSH D, XY3` (program-insert save) -> `PUSH D0 / PUSH D123`
;         • L794 `POP  D, XY3`                         -> `POP  D123 / POP D0`
;           (stack layout byte-for-byte identical to the legacy form)
;         • 2x `CLC / RET` -> `RETCC`
;         • 1x `SEC / RET` -> `RETCS`
;         • 2x `BCS skip / RET` fall-through       -> `RETCC` (divide_16, umod_16)
;         • 1x `BCC skip / RET` fall-through       -> `RETCS` (LEFT$ length test)
;         • 1x single-entry BCS-only label epilogue -> `RETCS` (.sgc_done in
;           string-vars garbage-collect loop)
;       One candidate was flagged and deliberately REJECTED: .l6_rnd_done
;       (RND function) has both a BCS fall-through path (C=0) and a BEQ
;       entry path (C undefined), so the RET stays plain to forward whichever
;       C the BEQ path produces.
;       No call-convention changes; v2.5 .COM is drop-in for v2.4 callers.
;       Requires assembler with v3.12 PUSH/POP encoder + v3.11 RETCC/RETCS.
;
; v2.4: registers as a Phase B shell at startup. First call in MAIN is now
;       TRAP #TRAP_REGISTER_SHELL — allocates a 2400-byte back-buffer, sets
;       TF_HAS_BACKBUF, splices into the shell ring after kosh. All
;       subsequent BASIC output then routes through Phase B's shell-aware
;       syscalls into the back-buffer. Lets the user run BASIC alongside
;       kosh and switch between them with Ctrl-N/Ctrl-P or
;       sys_setforeground. Requires k/OS kos_console.asm r14+ and
;       kos_switcher.asm r4+ (Phase B Steps 3 & 5).
;
; v2.3: adds SAVE / LOAD / DIR / DRIVE commands and per-task current drive.
;       Built on the v2.2 .COM port; ROM build of v2.2 unchanged.
;
; Ports K16 BASIC v2.2 (the standalone ROM-based interpreter) to run as a
; user task .COM file under k/OS. Per BASIC_COM_port_spec_v2.md.
;
; Origin/entry:
;   .ORG $0200 — the .COM convention. sys_exec copies the file verbatim
;   into a freshly allocated user page starting at user_page:$0200, then
;   jumps to it. X3 = $FFF0 and Y3 = task page byte at entry.
;
; Port-relative changes vs ROM build:
;   * Single-page memory model (was two: page-$00 RAM + page-$01 PROG).
;   * I/O via TRAP (sys_putchar #10, sys_getchar #11, sys_exit #27).
;   * Math/string/conversion helpers via KLIB jump table at $00:$A000:
;       memcpy -> KLIB_MEMCPY, mul -> KLIB_MUL16x16_32, div10 -> KLIB_DIV10,
;       /,MOD -> KLIB_DIVMOD16, int_to_str -> KLIB_ITOA, int_to_hex -> KLIB_ITOH,
;       print_unsigned digits -> KLIB_DIV10, RND -> KLIB_RAND16,
;       RANDOMIZE seed -> KLIB_SRAND.
;     ~330 lines of hand-rolled math removed in favour of shared kernel code.
;   * PC-relative label loads (LEA XY?, label) replace LOADI X #< / LOADI Y #>
;     for INTERNAL labels per .COM position-independence rules
;     (kOS_Reference_Manual §11.9). Kernel-fixed addresses (KEYBOARD, TERMINAL)
;     vanish entirely along with the I/O routines that referenced them.
;   * New BYE command — clean task exit via TRAP #TRAP_EXIT.
;   * STR_RANDERR added for KLIB_DELAY_MS-style precondition reporting (unused
;     in this port but reserved).
;
; Memory map (within the user page; Y3 supplies the page byte at runtime):
;   $0000..$01FF   k/OS-reserved task-local kernel area (FD_TABLE, TLS)
;   $0200..$48FF   BASIC code + rodata (interpreter image)
;   $4100..$430B   BASIC scalar vars, descriptors, stacks (was $0100..$030B)
;   $4600..$46FF   TIB (input buffer)
;   $4700..$47FF   TMPSTR_BUF
;   $4800..$48FF   TMPSTR2_BUF
;   $4900..$9FFF   Program-line storage (~22 KB)
;   $A000..$EBFF   Array storage (~19 KB)
;   $EC00..$FDFF   String pool (grows down from $FDFE; ~4.5 KB)
;   $FE00..$FFEF   Headroom
;   $FFF0..$FFFE   Initial stack region (X3 = $FFF0 at entry, grows down)
;
; Features retained from v2.2:
;   Tokenized interpreter ($80+ keywords, JMPT statement dispatch, detokenizer
;   for LIST). Integer vars A-Z, string vars A$-Z$, arrays A()-Z(). DATA/READ/
;   RESTORE. IF/THEN/ELSE. ON GOTO/GOSUB. FOR/NEXT/STEP. PRINT/INPUT/LET.
;   PEEK/POKE/DEEK/DOKE. CHR$/STR$/HEX$/LEFT$/RIGHT$/MID$/LEN/VAL/ASC.
;   ABS, RND, SGN, NOT, MOD. Operators + - * / = <> < > <= >= AND OR XOR.
;
; New in port: BYE — exit BASIC and return to kosh.
;
; ============================================================================

.ORG $0200

; --- k/OS includes for .COM build ----------------------------------------
; Hardcoded paths because the assembler resolves includes relative to the
; source file, not via a search path. BASIC lives at C:\K16 CPU\K16 Basic;
; the k/OS sources are at C:\K16 CPU\K16 OS.
.INCLUDE "C:\K16 CPU\K16 OS\kos_defs.inc"
.INCLUDE "C:\K16 CPU\K16 OS\klib\kos_klib.inc"

; Entry point at $0200. Use JMP16 (page-relative 16-bit) to MAIN.
; JMP24 would encode an absolute 24-bit address embedding the assembler's
; page byte ($00), which would land us in kernel space at runtime since
; .COM page byte is set by the kernel, not known at assembly time.
; JMP16 stays in the current code page — exactly what we need.
                JMP16       MAIN

; ============================================================================
; CONFIGURATION
; ============================================================================

; --- Kernel-fixed addresses removed: I/O now via TRAPs ----------------------
; TERMINAL    .EQU    $DF0000             ; (port: replaced by sys_putchar)
; KEYBOARD    .EQU    $DE0000             ; (port: replaced by sys_getchar)
; RAM_PAGE    .EQU    $00    ; (port: superseded by Y3-based addressing)
; PROG_PAGE   .EQU    $01    ; (port: superseded by Y3-based addressing)

SSTACK_TOP  .EQU    $FFF0    ; .COM stack region top (kernel-supplied)
TIB_OFFSET  .EQU    $4600
TIB_SIZE    .EQU    250
TMPSTR_BUF  .EQU    $4700
TMPSTR2_BUF .EQU    $4800               ; second temp buf for concat safety
ARRAY_BASE  .EQU    $A000               ; (port: was $C000; gave more room to vars/strings)
STRPOOL_TOP .EQU    $FDFE
PROG_BASE   .EQU    $4900               ; BASIC program text start (was PROG_PAGE:$0000)
COM_STACK_TOP .EQU  $FFF0               ; .COM stack top (k/OS entry value of X3)

; ============================================================================
; ZERO PAGE VARIABLES
; ============================================================================

ZP_RUNNING  .EQU    $4100
ZP_CURLINE  .EQU    $4102
ZP_TXTPOS   .EQU    $4104
ZP_PROGEND  .EQU    $4106
ZP_LINENUM  .EQU    $4108
ZP_RNDSEED  .EQU    $410A
ZP_RUNSP    .EQU    $410C
ZP_GOSUBSP  .EQU    $410E
GOSUB_MAX   .EQU    16
ZP_GOSUBSTK .EQU    $4200               ; 16 entries x 4 bytes -> $0200-$023F
ZP_FORSP    .EQU    $4110
FOR_MAX     .EQU    8
ZP_FORSTK   .EQU    $4240               ; 8 entries x 10 bytes -> $0240-$028F
FOR_ENTRY   .EQU    10
ZP_VARS     .EQU    $4150               ; A-Z integers (52 bytes -> $0150-$0183)

; New in v2.0
ZP_STRVARS  .EQU    $4190               ; A$-Z$ descriptors (26x4=104 -> $0190-$01F7)
ZP_ARRAYS   .EQU    $4290               ; A()-Z() descriptors (26x4=104 -> $0290-$02F7)
ZP_STRPOOL  .EQU    $4300               ; String pool bottom pointer
ZP_ARRTOP   .EQU    $4302               ; Array storage top pointer
ZP_DATALINE .EQU    $4304               ; DATA line offset
ZP_DATAPOS  .EQU    $4306               ; DATA position within line
ZP_TMPLEN   .EQU    $4308               ; Temp string length
ZP_TMPPTR   .EQU    $430A               ; Temp string pointer
ZP_DRIVE    .EQU    $430C               ; current drive letter ('A'..'F')  -- port
INT_VECTOR  .EQU    $0000

; --- Port scratch ----------------------------------------------------------
; FILENAME_BUF holds a normalised path ready for sys_open:
;     "<drive>:<NAME>.BAS\0"  (max ~16 chars)
; Lives at $4400, well clear of the var/descriptor/stack block at $4100..$430C
; and below TIB at $4600.
FILENAME_BUF .EQU   $4400               ; 64 bytes — assembled path for FS calls
FILENAME_MAX .EQU   60                  ; usable length cap (leaves headroom)

; DIR scratch — 32-byte dirent staging buffer + drive byte holder.
DIR_DIRENT_BUF .EQU $4440               ; 32 B — sys_dirent destination
DIR_DRIVE_TMP  .EQU $4462               ; word — drive index across dirent calls
DIR_INDEX_TMP  .EQU $4464               ; word — index across dirent calls

; ============================================================================
; STRING CONSTANTS
; ============================================================================

BANNER:     .TEXT   "K16 BASIC v2.5", $0A, 0
STR_READY:  .TEXT   "Ready.", $0A, 0
STR_PROMPT: .TEXT   "> ", 0
STR_SYNERR: .TEXT   "Syntax error", 0
STR_DIVERR: .TEXT   "Division by zero", 0
STR_GOSERR: .TEXT   "GOSUB stack", 0
STR_FORERR: .TEXT   "FOR stack", 0
STR_LINERR: .TEXT   "Line not found", 0
STR_RETERR: .TEXT   "RETURN without GOSUB", 0
STR_NXTERR: .TEXT   "NEXT without FOR", 0
STR_MEMERR: .TEXT   "Out of memory", 0
STR_INLN:   .TEXT   " in line ", 0
STR_BREAK:  .TEXT   "Break", 0
STR_QUEST:  .TEXT   "? ", 0
STR_DIMERR: .TEXT   "Bad DIM", 0
STR_SUBERR: .TEXT   "Subscript error", 0
STR_DATERR: .TEXT   "Out of DATA", 0
STR_TYPERR: .TEXT   "Type mismatch", 0
STR_BYTES:  .TEXT   " bytes free", $0A, 0

; --- Port: SAVE/LOAD/DIR/DRIVE strings -------------------------------------
STR_FILERR: .TEXT   "File error", 0
STR_DRVERR: .TEXT   "Bad drive", 0
STR_NAMERR: .TEXT   "Bad name", 0
STR_SAVED:  .TEXT   "Saved", $0A, 0
STR_LOADED: .TEXT   "Loaded", $0A, 0
STR_NOFILE: .TEXT   "Not found", 0
STR_TOOBIG: .TEXT   "Program too big", 0
STR_DRVPRE: .TEXT   "Drive: ", 0
STR_DRVCOL: .TEXT   ":", $0A, 0
STR_BAS:    .TEXT   ".BAS", 0
STR_NOPROG: .TEXT   "No program", 0
STR_DIRHDR: .TEXT   "Directory of ", 0
STR_DIREMPTY: .TEXT "(empty)", $0A, 0

; ============================================================================
; TOKEN DEFINITIONS
; Byte tokens $80+ replace keyword strings. Saves memory, enables JMPT dispatch.
; ============================================================================

; --- Statement tokens (dispatchable via JMPT) ---
TOK_PRINT   .EQU    $80
TOK_INPUT   .EQU    $81
TOK_RESTORE .EQU    $82
TOK_RETURN  .EQU    $83
TOK_GOSUB   .EQU    $84
TOK_GOTO    .EQU    $85
TOK_FOR     .EQU    $86
TOK_NEXT    .EQU    $87
TOK_READ    .EQU    $88
TOK_DATA    .EQU    $89
TOK_DIM     .EQU    $8A
TOK_DOKE    .EQU    $8B
TOK_POKE    .EQU    $8C
TOK_LIST    .EQU    $8D
TOK_LET     .EQU    $8E
TOK_IF      .EQU    $8F
TOK_ON      .EQU    $90
TOK_END     .EQU    $91
TOK_STOP    .EQU    $92
TOK_CLR     .EQU    $93
TOK_REM     .EQU    $94
TOK_NEW     .EQU    $95
TOK_RUN     .EQU    $96
TOK_LAST_STMT .EQU  $96             ; last dispatchable statement token

; --- Secondary keywords (matched inline, not dispatched) ---
TOK_THEN    .EQU    $97
TOK_TO      .EQU    $98
TOK_STEP    .EQU    $99
TOK_ELSE    .EQU    $9A

; --- Operators ---
TOK_AND     .EQU    $9B
TOK_OR      .EQU    $9C
TOK_XOR     .EQU    $9D
TOK_NOT     .EQU    $9E
TOK_MOD     .EQU    $9F

; --- Comparison operators ---
TOK_LE      .EQU    $A0             ; <=
TOK_GE      .EQU    $A1             ; >=
TOK_NE      .EQU    $A2             ; <>

; --- Numeric functions ---
TOK_ABS     .EQU    $A3
TOK_ASC     .EQU    $A4
TOK_RND     .EQU    $A5
TOK_SGN     .EQU    $A6
TOK_PEEK    .EQU    $A7
TOK_DEEK    .EQU    $A8
TOK_LEN     .EQU    $A9
TOK_VAL     .EQU    $AA

; --- String functions ---
TOK_CHRS    .EQU    $AB             ; CHR$
TOK_STRS    .EQU    $AC             ; STR$
TOK_HEXS    .EQU    $AD             ; HEX$
TOK_LEFTS   .EQU    $AE             ; LEFT$
TOK_RIGHTS  .EQU    $AF             ; RIGHT$
TOK_MIDS    .EQU    $B0             ; MID$

; --- Port additions ---
TOK_BYE     .EQU    $B1             ; BYE — exit BASIC, return to kosh
TOK_SAVE    .EQU    $B2             ; SAVE "name" — write program to disk
TOK_LOAD    .EQU    $B3             ; LOAD "name" — read program from disk
TOK_DIR     .EQU    $B4             ; DIR [D:] — list files
TOK_DRIVE   .EQU    $B5             ; DRIVE D: — change current drive

TOK_COUNT   .EQU    $36             ; $B5 - $80 + 1 = 54 tokens

; ============================================================================
; TOKEN STRING TABLE (for tokenizer matching and LIST detokenization)
; Longer keywords MUST come first to avoid prefix ambiguity.
; Format: .TEXT $token, "KEYWORD", 0  ... .TEXT 0 = end
; ============================================================================

TOK_TABLE:
                ; Statement keywords (longer matches first)
                .TEXT   $82, "RESTORE", 0
                .TEXT   $83, "RETURN", 0
                .TEXT   $80, "PRINT", 0
                .TEXT   $81, "INPUT", 0
                .TEXT   $84, "GOSUB", 0
                .TEXT   $85, "GOTO", 0
                .TEXT   $87, "NEXT", 0
                .TEXT   $88, "READ", 0
                .TEXT   $89, "DATA", 0
                .TEXT   $8B, "DOKE", 0
                .TEXT   $8C, "POKE", 0
                .TEXT   $8D, "LIST", 0
                .TEXT   $99, "STEP", 0
                .TEXT   $92, "STOP", 0
                .TEXT   $97, "THEN", 0
                .TEXT   $9A, "ELSE", 0
                .TEXT   $86, "FOR", 0
                .TEXT   $8A, "DIM", 0
                .TEXT   $8E, "LET", 0
                .TEXT   $95, "NEW", 0
                .TEXT   $96, "RUN", 0
                .TEXT   $93, "CLR", 0
                .TEXT   $94, "REM", 0
                .TEXT   $91, "END", 0
                .TEXT   $B1, "BYE", 0           ; port: exit BASIC
                .TEXT   $B5, "DRIVE", 0         ; port: change drive
                .TEXT   $B2, "SAVE", 0          ; port: save program
                .TEXT   $B3, "LOAD", 0          ; port: load program
                .TEXT   $B4, "DIR", 0           ; port: directory
                .TEXT   $9E, "NOT", 0
                .TEXT   $9B, "AND", 0
                .TEXT   $9D, "XOR", 0
                .TEXT   $9F, "MOD", 0
                .TEXT   $8F, "IF", 0
                .TEXT   $90, "ON", 0
                .TEXT   $9C, "OR", 0
                .TEXT   $98, "TO", 0
                ; Numeric functions
                .TEXT   $A7, "PEEK", 0
                .TEXT   $A8, "DEEK", 0
                .TEXT   $A3, "ABS", 0
                .TEXT   $A4, "ASC", 0
                .TEXT   $A5, "RND", 0
                .TEXT   $A6, "SGN", 0
                .TEXT   $A9, "LEN", 0
                .TEXT   $AA, "VAL", 0
                ; String functions (with $)
                .TEXT   $AE, "LEFT$", 0
                .TEXT   $AF, "RIGHT$", 0
                .TEXT   $B0, "MID$", 0
                .TEXT   $AB, "CHR$", 0
                .TEXT   $AC, "STR$", 0
                .TEXT   $AD, "HEX$", 0
                ; Single-char aliases
                .TEXT   $80, "?", 0
                ; End marker
                .TEXT   $FF

; ============================================================================
; DETOKENIZE STRING TABLE (indexed by token - $80)
; Each entry is a pointer to the keyword string for LIST output.
; ============================================================================

DETOK_TABLE:
                .WORD   DS_PRINT            ; $80
                .WORD   DS_INPUT            ; $81
                .WORD   DS_RESTORE          ; $82
                .WORD   DS_RETURN           ; $83
                .WORD   DS_GOSUB            ; $84
                .WORD   DS_GOTO             ; $85
                .WORD   DS_FOR              ; $86
                .WORD   DS_NEXT             ; $87
                .WORD   DS_READ             ; $88
                .WORD   DS_DATA             ; $89
                .WORD   DS_DIM              ; $8A
                .WORD   DS_DOKE             ; $8B
                .WORD   DS_POKE             ; $8C
                .WORD   DS_LIST             ; $8D
                .WORD   DS_LET              ; $8E
                .WORD   DS_IF               ; $8F
                .WORD   DS_ON               ; $90
                .WORD   DS_END              ; $91
                .WORD   DS_STOP             ; $92
                .WORD   DS_CLR              ; $93
                .WORD   DS_REM              ; $94
                .WORD   DS_NEW              ; $95
                .WORD   DS_RUN              ; $96
                .WORD   DS_THEN             ; $97
                .WORD   DS_TO               ; $98
                .WORD   DS_STEP             ; $99
                .WORD   DS_ELSE             ; $9A
                .WORD   DS_AND              ; $9B
                .WORD   DS_OR               ; $9C
                .WORD   DS_XOR              ; $9D
                .WORD   DS_NOT              ; $9E
                .WORD   DS_MOD              ; $9F
                .WORD   DS_LE               ; $A0
                .WORD   DS_GE               ; $A1
                .WORD   DS_NE               ; $A2
                .WORD   DS_ABS              ; $A3
                .WORD   DS_ASC              ; $A4
                .WORD   DS_RND              ; $A5
                .WORD   DS_SGN              ; $A6
                .WORD   DS_PEEK             ; $A7
                .WORD   DS_DEEK             ; $A8
                .WORD   DS_LEN              ; $A9
                .WORD   DS_VAL              ; $AA
                .WORD   DS_CHRS             ; $AB
                .WORD   DS_STRS             ; $AC
                .WORD   DS_HEXS             ; $AD
                .WORD   DS_LEFTS            ; $AE
                .WORD   DS_RIGHTS           ; $AF
                .WORD   DS_MIDS             ; $B0
                .WORD   DS_BYE              ; $B1  (port: exit BASIC)
                .WORD   DS_SAVE             ; $B2  (port: save)
                .WORD   DS_LOAD             ; $B3  (port: load)
                .WORD   DS_DIR              ; $B4  (port: dir)
                .WORD   DS_DRIVE            ; $B5  (port: drive)

DS_PRINT:   .TEXT   "PRINT", 0
DS_INPUT:   .TEXT   "INPUT", 0
DS_RESTORE: .TEXT   "RESTORE", 0
DS_RETURN:  .TEXT   "RETURN", 0
DS_GOSUB:   .TEXT   "GOSUB", 0
DS_GOTO:    .TEXT   "GOTO", 0
DS_FOR:     .TEXT   "FOR", 0
DS_NEXT:    .TEXT   "NEXT", 0
DS_READ:    .TEXT   "READ", 0
DS_DATA:    .TEXT   "DATA", 0
DS_DIM:     .TEXT   "DIM", 0
DS_DOKE:    .TEXT   "DOKE", 0
DS_POKE:    .TEXT   "POKE", 0
DS_LIST:    .TEXT   "LIST", 0
DS_LET:     .TEXT   "LET", 0
DS_IF:      .TEXT   "IF", 0
DS_ON:      .TEXT   "ON", 0
DS_END:     .TEXT   "END", 0
DS_STOP:    .TEXT   "STOP", 0
DS_CLR:     .TEXT   "CLR", 0
DS_REM:     .TEXT   "REM", 0
DS_NEW:     .TEXT   "NEW", 0
DS_RUN:     .TEXT   "RUN", 0
DS_THEN:    .TEXT   "THEN", 0
DS_TO:      .TEXT   "TO", 0
DS_STEP:    .TEXT   "STEP", 0
DS_ELSE:    .TEXT   "ELSE", 0
DS_AND:     .TEXT   " AND ", 0
DS_OR:      .TEXT   " OR ", 0
DS_XOR:     .TEXT   " XOR ", 0
DS_NOT:     .TEXT   "NOT ", 0
DS_MOD:     .TEXT   " MOD ", 0
DS_LE:      .TEXT   "<=", 0
DS_GE:      .TEXT   ">=", 0
DS_NE:      .TEXT   "<>", 0
DS_ABS:     .TEXT   "ABS", 0
DS_ASC:     .TEXT   "ASC", 0
DS_RND:     .TEXT   "RND", 0
DS_SGN:     .TEXT   "SGN", 0
DS_PEEK:    .TEXT   "PEEK", 0
DS_DEEK:    .TEXT   "DEEK", 0
DS_LEN:     .TEXT   "LEN", 0
DS_VAL:     .TEXT   "VAL", 0
DS_CHRS:    .TEXT   "CHR$", 0
DS_STRS:    .TEXT   "STR$", 0
DS_HEXS:    .TEXT   "HEX$", 0
DS_LEFTS:   .TEXT   "LEFT$", 0
DS_RIGHTS:  .TEXT   "RIGHT$", 0
DS_MIDS:    .TEXT   "MID$", 0
DS_BYE:     .TEXT   "BYE", 0        ; port: exit BASIC
DS_SAVE:    .TEXT   "SAVE", 0       ; port
DS_LOAD:    .TEXT   "LOAD", 0       ; port
DS_DIR:     .TEXT   "DIR", 0        ; port
DS_DRIVE:   .TEXT   "DRIVE", 0      ; port

; ============================================================================
; STATEMENT DISPATCH TABLE (for JMPT via token offset)
; Index = (token - $80) * 2.  JMPT XY1, D0 reads address from here.
; ============================================================================

STMT_DISPATCH:
                .WORD   CMD_PRINT           ; $80
                .WORD   CMD_INPUT           ; $81
                .WORD   CMD_RESTORE         ; $82
                .WORD   CMD_RETURN          ; $83
                .WORD   CMD_GOSUB           ; $84
                .WORD   CMD_GOTO            ; $85
                .WORD   CMD_FOR             ; $86
                .WORD   CMD_NEXT            ; $87
                .WORD   CMD_READ            ; $88
                .WORD   CMD_DATA            ; $89
                .WORD   CMD_DIM             ; $8A
                .WORD   CMD_DOKE            ; $8B
                .WORD   CMD_POKE            ; $8C
                .WORD   CMD_LIST            ; $8D
                .WORD   CMD_LET             ; $8E
                .WORD   CMD_IF              ; $8F
                .WORD   CMD_ON              ; $90
                .WORD   CMD_END             ; $91
                .WORD   CMD_STOP            ; $92
                .WORD   CMD_CLR             ; $93
                .WORD   CMD_REM             ; $94
                .WORD   CMD_NEW             ; $95
                .WORD   CMD_RUN             ; $96

; ============================================================================
; MAIN
; ============================================================================

MAIN:
                ; On entry under k/OS sys_exec:
                ;   Y3 = our task page byte (set by scheduler — do NOT touch)
                ;   X3 = $FFF0 (kernel-supplied initial stack pointer)
                ;   IE  = 1, KERN_STATE = RUN
                ; We re-anchor X3 explicitly so cmd_loop reset uses the same
                ; value. Y3 is left alone.
                LOADI       X3, #COM_STACK_TOP

                ; -- Register as a shell (Phase B; 13 May 2026) --------------
                ; Allocates a 2400-byte back-buffer, sets TF_HAS_BACKBUF,
                ; links into the shell ring. Must happen BEFORE any output
                ; so the banner and all subsequent BASIC output flows through
                ; Phase B routing into our back-buffer.
                ;
                ; If kosh is the only existing shell, we splice in after kosh
                ; and become its `.next`. FOREGROUND_TCB stays as kosh, so
                ; BASIC starts as a background shell — its banner emits to
                ; its back-buffer only. Press Ctrl-N (Phase B Step 6) or
                ; call sys_setforeground to switch and reveal it.
                ;
                ; Failure is ERR_NOMEM (heap exhausted), unlikely at task
                ; start. Exit cleanly with error code if it happens.
                TRAP        #TRAP_REGISTER_SHELL
                BCC.S       .reg_ok
                LOADI       D0, #99             ; arbitrary non-zero exit code
                TRAP        #TRAP_EXIT
.reg_ok:

                LOADI       D0, #0
                STOREP      D0, Y3, [#ZP_RUNNING]
                STOREP      D0, Y3, [#ZP_GOSUBSP]
                STOREP      D0, Y3, [#ZP_FORSP]
                STOREP      D0, Y3, [#ZP_PROGEND]
                STOREP      D0, Y3, [#ZP_DATALINE]
                STOREP      D0, Y3, [#ZP_DATAPOS]

                ; Seed KLIB's PRNG (KLIB owns the seed; ZP_RNDSEED is unused
                ; in the port but kept allocated for future tasks that may
                ; want their own deterministic RNG).
                LOADI       D0, #12345
                STOREP      D0, Y3, [#ZP_RNDSEED]
                CALL24      KLIB_SRAND          ; KLIB_SRAND: D0 = seed
                LOADI       D0, #STRPOOL_TOP
                STOREP      D0, Y3, [#ZP_STRPOOL]
                LOADI       D0, #ARRAY_BASE
                STOREP      D0, Y3, [#ZP_ARRTOP]

                CALL16        clear_vars

                LOADI       X0, #PROG_BASE
                MOVE        Y0, Y3
                LOADI       D0, #0
                STORED      D0, [XY0]

                LEA         XY0, BANNER
                CALL16        print_string

                ; Port: initialise current drive to 'B' (the user-writable
                ; volume; A: is read-only ROM). Print "Drive: B:" line.
                LOADI       D0, #'B'
                STOREP      D0, Y3, [#ZP_DRIVE]
                LEA         XY0, STR_DRVPRE
                CALL16        print_string
                LOADP       D0, Y3, [#ZP_DRIVE]
                TRAP        #TRAP_PUTCHAR
                LEA         XY0, STR_DRVCOL
                CALL16        print_string

                ; Display free memory
                LOADI       D0, #STRPOOL_TOP
                SUB         D0, #ARRAY_BASE
                CALL16        print_unsigned
                LEA         XY0, STR_BYTES
                CALL16        print_string

                LEA         XY0, STR_READY
                CALL16        print_string

                BRA         cmd_loop

; ============================================================================
; COMMAND LOOP
; ============================================================================

cmd_loop:
                LOADI       X3, #COM_STACK_TOP  ; reset stack on each prompt
                LOADI       D0, #0
                STOREP      D0, Y3, [#ZP_RUNNING]
                STOREP      D0, Y3, [#ZP_GOSUBSP]
                STOREP      D0, Y3, [#ZP_FORSP]

                LEA         XY0, STR_PROMPT
                CALL16        print_string
                CALL16        accept_line

                ; Tokenize the input line in-place
                CALL16        tokenize_line

                LOADI       X0, #TIB_OFFSET
                MOVE        Y0, Y3
                LOADB       D0, [XY0]

.cmd_skip:      CMP         D0, #$20
                BNE         .cmd_chk
                ADD         X0, #1
                LOADB       D0, [XY0]
                BRA         .cmd_skip

.cmd_chk:       CMP         D0, #0
                BEQ         cmd_loop
                CMP         D0, #$30
                BCC         .cmd_direct
                CMP         D0, #$3A
                BCS         .cmd_direct

                CALL16        parse_linenum
                CMP         D0, #0
                BEQ         .cmd_direct

                PUSH        D0, XY3
                LOADB       D1, [XY0]
.cmd_skp2:      CMP         D1, #$20
                BNE         .cmd_chktxt
                ADD         X0, #1
                LOADB       D1, [XY0]
                BRA         .cmd_skp2

.cmd_chktxt:    CMP         D1, #0
                BEQ         .cmd_delline
                MOVE        D2, X0
                POP         D0, XY3
                CALL16        store_line
                BRA         cmd_loop

.cmd_delline:   POP         D0, XY3
                CALL16        delete_line_v2
                BRA         cmd_loop

.cmd_direct:    MOVE        D0, X0
                STOREP      D0, Y3, [#ZP_TXTPOS]
                LOADI       D0, #0
                STOREP      D0, Y3, [#ZP_RUNNING]
                CALL16        exec_statement
                BRA         cmd_loop

; ============================================================================
; ACCEPT_LINE - Read line from keyboard into TIB
; Returns D0 = character count
; ============================================================================

accept_line:
                ; D2 = byte count, D3 = TIB write offset (within our page)
                LOADI       D2, #0
                LOADI       D3, #TIB_OFFSET

.al_loop:       TRAP        #TRAP_GETCHAR       ; D0 = byte (blocks)
                AND         D0, #$FF
                CMP         D0, #$0D
                BEQ         .al_done
                CMP         D0, #$0A
                BEQ         .al_done
                CMP         D0, #$08
                BEQ         .al_back
                CMP         D0, #$7F
                BEQ         .al_back
                CMP         D2, #TIB_SIZE
                BCS         .al_loop            ; full — silently discard

                ; Store in TIB
                PUSH        D0, XY3
                PUSH        D2, XY3
                MOVE        X0, D3
                MOVE        Y0, Y3
                STOREB      D0, [XY0]
                POP         D2, XY3
                POP         D0, XY3
                ADD         D3, #1
                ADD         D2, #1
                ; Echo
                TRAP        #TRAP_PUTCHAR
                BRA         .al_loop

.al_back:       CMP         D2, #0
                BEQ         .al_loop
                SUB         D3, #1
                SUB         D2, #1
                LOADI       D0, #$08
                TRAP        #TRAP_PUTCHAR
                LOADI       D0, #$20
                TRAP        #TRAP_PUTCHAR
                LOADI       D0, #$08
                TRAP        #TRAP_PUTCHAR
                BRA         .al_loop

.al_done:       PUSH        D2, XY3
                MOVE        X0, D3
                MOVE        Y0, Y3
                LOADI       D0, #0
                STOREB      D0, [XY0]              ; nul-terminate
                POP         D2, XY3
                LOADI       D0, #$0A
                TRAP        #TRAP_PUTCHAR          ; echo newline
                MOVE        D0, D2
                RET

; ============================================================================
; PARSE_LINENUM - Parse decimal line number from [XY0]
; ============================================================================

parse_linenum:
                LOADI       D0, #0
.pln_loop:      LOADB       D1, [XY0]
                CMP         D1, #$30
                BCC         .pln_done
                CMP         D1, #$3A
                BCS         .pln_done
                MOVE        D2, D0
                SHL         D0
                SHL         D0
                ADD         D0, D2
                SHL         D0
                SUB         D1, #$30
                ADD         D0, D1
                ADD         X0, #1
                BRA         .pln_loop
.pln_done:      RET

; ============================================================================
; STORE_LINE - Insert/replace program line
; Input: D0=line number, D2=text offset in page $00
; ============================================================================

store_line:
                PUSH        D0, XY3
                PUSH        D2, XY3

                ; Measure text length
                MOVE        X0, D2
                MOVE        Y0, Y3
                LOADI       D1, #0
.sl_meas:       LOADB       D0, [XY0]
                CMP         D0, #0
                BEQ         .sl_meas_done
                ADD         D1, #1
                ADD         X0, #1
                BRA         .sl_meas
.sl_meas_done:  ADD         D1, #4              ; +2 line#, +1 NUL, +1 align
                AND         D1, #$FFFE
                PUSH        D1, XY3

                ; Delete existing line if present
                ; Stack: [D1=size, D2=text, D0=linenum]
                LOADD       D0, [XY3+#2w]       ; peek line number (3rd word)
                CALL16        delete_line_v2

                ; Find insertion point
                ; Stack unchanged - read D0 again
                LOADD       D0, [XY3+#2w]       ; line number (3rd word)
                LOADI       X0, #PROG_BASE
                MOVE        Y0, Y3
.sl_find:       LOADD       D2, [XY0]
                CMP         D2, #0
                BEQ         .sl_insert
                CMP         D2, D0
                BCS         .sl_insert
                ADD         X0, #2
.sl_skip:       LOADB       D3, [XY0]
                ADD         X0, #1
                CMP         D3, #0
                BNE         .sl_skip
                ADD         X0, #1
                AND         X0, #$FFFE
                BRA         .sl_find

.sl_insert:     POP         D1, XY3             ; record size
                POP         D2, XY3             ; text offset
                POP         D0, XY3             ; line number
                MOVE        D3, X0              ; insert offset
                PUSH        D0, XY3             ; save D0
                PUSH        D123, XY3           ; save D1, D2, D3 (was: PUSH D)

                ; Find end of program
                LOADI       X1, #PROG_BASE
                MOVE        Y1, Y3
                MOVE        X1, D3
.sl_fend:       LOADD       D0, [XY1]
                CMP         D0, #0
                BEQ         .sl_fend2
                ADD         X1, #2
.sl_fe2:        LOADB       D0, [XY1]
                ADD         X1, #1
                CMP         D0, #0
                BNE         .sl_fe2
                ADD         X1, #1
                AND         X1, #$FFFE
                BRA         .sl_fend
.sl_fend2:      ADD         X1, #2

                ; Shift data up by D1 bytes
                MOVE        D2, X1
                SUB         D2, D3              ; bytes to move
                SUB         X1, #1
                MOVE        Y1, Y3
                MOVE        D0, X1
                ADD         D0, D1
                MOVE        X0, D0
                MOVE        Y0, Y3

.sl_shift:      CMP         D2, #0
                BEQ         .sl_shifted
                LOADB       D0, [XY1]
                STOREB      D0, [XY0]
                SUB         X1, #1
                SUB         X0, #1
                SUB         D2, #1
                BRA         .sl_shift

.sl_shifted:    POP         D123, XY3           ; restore D1, D2, D3
                POP         D0, XY3             ; restore D0 (D0=linenum, D1=size, D2=text, D3=insert)

                ; Write line record
                MOVE        X0, D3
                MOVE        Y0, Y3
                STORED      D0, [XY0]
                ADD         X0, #2
                MOVE        X1, D2
                MOVE        Y1, Y3
.sl_copy:       LOADB       D0, [XY1]
                STOREB      D0, [XY0]
                ADD         X0, #1
                ADD         X1, #1
                CMP         D0, #0
                BNE         .sl_copy
                RET

; ============================================================================
; DELETE_LINE
; ============================================================================

delete_line_v2:
                PUSH        D0, XY3
                LOADI       X0, #PROG_BASE
                MOVE        Y0, Y3

.dl2_find:      LOADD       D1, [XY0]
                CMP         D1, #0
                BEQ         .dl2_nf
                LOADD       D2, [XY3]
                CMP         D1, D2
                BEQ         .dl2_found
                BCS         .dl2_nf
                ADD         X0, #2
.dl2_skip:      LOADB       D1, [XY0]
                ADD         X0, #1
                CMP         D1, #0
                BNE         .dl2_skip
                ADD         X0, #1
                AND         X0, #$FFFE
                BRA         .dl2_find

.dl2_nf:        POP         D0, XY3
                RET

.dl2_found:     POP         D2, XY3
                MOVE        D2, X0              ; start of line record

                ; Find end of this line
                ADD         X0, #2
.dl2_fend:      LOADB       D1, [XY0]
                ADD         X0, #1
                CMP         D1, #0
                BNE         .dl2_fend
                ADD         X0, #1
                AND         X0, #$FFFE
                MOVE        D3, X0              ; start of next record

                ; Find end of program
                MOVE        X1, D3
                MOVE        Y1, Y3
.dl2_pend:      LOADD       D0, [XY1]
                CMP         D0, #0
                BEQ         .dl2_gotend
                ADD         X1, #2
.dl2_pe2:       LOADB       D0, [XY1]
                ADD         X1, #1
                CMP         D0, #0
                BNE         .dl2_pe2
                ADD         X1, #1
                AND         X1, #$FFFE
                BRA         .dl2_pend
.dl2_gotend:    ADD         X1, #2

                ; Shift down
                MOVE        D0, X1
                SUB         D0, D3              ; bytes to copy
                MOVE        X1, D3
                MOVE        Y1, Y3
                MOVE        X0, D2
                MOVE        Y0, Y3

.dl2_copy:      CMP         D0, #0
                BEQ         .dl2_done
                LOADB       D1, [XY1]
                STOREB      D1, [XY0]
                ADD         X1, #1
                ADD         X0, #1
                SUB         D0, #1
                BRA         .dl2_copy
.dl2_done:      RET

; ============================================================================
; RUN / RUN_LOOP / EXEC_STATEMENT
; ============================================================================

CMD_RUN:
                LOADI       D0, #0
                STOREP      D0, Y3, [#ZP_GOSUBSP]
                STOREP      D0, Y3, [#ZP_FORSP]
                STOREP      D0, Y3, [#ZP_DATALINE]
                STOREP      D0, Y3, [#ZP_DATAPOS]
                LOADI       D0, #STRPOOL_TOP
                STOREP      D0, Y3, [#ZP_STRPOOL]
                LOADI       D0, #ARRAY_BASE
                STOREP      D0, Y3, [#ZP_ARRTOP]
                CALL16        clear_vars
                ; Port: ZP_CURLINE holds an offset within the task page that
                ; points at the current line record. Original v2.2 ROM used
                ; page-$01 with offset $0000 = first line; in the .COM port
                ; the program text lives at PROG_BASE within our single page.
                LOADI       D0, #PROG_BASE
                STOREP      D0, Y3, [#ZP_CURLINE]
                LOADI       D0, #1
                STOREP      D0, Y3, [#ZP_RUNNING]

run_loop:
                STOREP      X3, Y3, [#ZP_RUNSP]
                LOADP       D0, Y3, [#ZP_CURLINE]
                MOVE        X0, D0
                MOVE        Y0, Y3
                LOADD       D0, [XY0]
                CMP         D0, #0
                BEQ         .run_end

                STOREP      D0, Y3, [#ZP_LINENUM]
                MOVE        D0, X0
                ADD         D0, #2
                STOREP      D0, Y3, [#ZP_TXTPOS]
                CALL16        exec_statement

                LOADP       D0, Y3, [#ZP_RUNNING]
                CMP         D0, #0
                BEQ         cmd_loop

                ; Advance to next line
                LOADP       D0, Y3, [#ZP_CURLINE]
                MOVE        X0, D0
                MOVE        Y0, Y3
                ADD         X0, #2
.rl_skip:       LOADB       D0, [XY0]
                ADD         X0, #1
                CMP         D0, #0
                BNE         .rl_skip
                ADD         X0, #1
                AND         X0, #$FFFE
                MOVE        D0, X0
                STOREP      D0, Y3, [#ZP_CURLINE]
                BRA         run_loop

.run_end:       LOADI       D0, #0
                STOREP      D0, Y3, [#ZP_RUNNING]
                BRA         cmd_loop

; --- Statement dispatcher (token-based JMPT dispatch) ---
exec_statement:
                CALL16        skip_spaces
                CALL16        peek_char
                CMP         D0, #0
                BEQ         .es_done
                CMP         D0, #$3A
                BEQ         .es_next_stmt

                ; Is it a statement token ($80-$96)?
                CMP         D0, #TOK_PRINT
                BCC         .es_not_token
                CMP         D0, #TOK_LAST_STMT+1
                BCS         .es_not_token

                ; --- Token dispatch via JMPT ---
                CALL16        get_char             ; consume token, D0 = token
                SUB         D0, #TOK_PRINT       ; zero-base offset
                ADD         D0, D0               ; word offset for table
                LEA         XY1, STMT_DISPATCH
                CALL16        .es_dispatch         ; push return, then JMPT

.es_post_dispatch:
                CALL16        skip_spaces
                CALL16        peek_char
                CMP         D0, #$3A
                BEQ         .es_next_stmt
.es_done:       RET

.es_dispatch:   JMPT        XY1, D0              ; PC ? mem[XY1 + D0]

.es_not_token:
                ; Port: BYE/SAVE/LOAD/DIR/DRIVE — tokens out of JMPT range
                ; handled inline (extension of the BYE pattern).
                CMP         D0, #TOK_BYE
                BEQ         .es_bye
                CMP         D0, #TOK_SAVE
                BEQ         .es_save
                CMP         D0, #TOK_LOAD
                BEQ         .es_load
                CMP         D0, #TOK_DIR
                BEQ         .es_dir
                CMP         D0, #TOK_DRIVE
                BEQ         .es_drive

                ; Not a token - implicit LET (variable name A-Z/a-z)
                CMP         D0, #$41
                BCC         .es_syntax_err
                CMP         D0, #$5B
                BCC         .es_implicit_let
                CMP         D0, #$61
                BCC         .es_syntax_err
                CMP         D0, #$7B
                BCS         .es_syntax_err

.es_implicit_let:
                CALL16        CMD_LET
                CALL16        skip_spaces
                CALL16        peek_char
                CMP         D0, #$3A
                BEQ         .es_next_stmt
                RET

.es_bye:        ; Exit BASIC cleanly via sys_exit.
                LOADI       D0, #0              ; exit code 0 = normal
                TRAP        #TRAP_EXIT
                ; sys_exit does not return; no RET needed.

.es_save:       CALL16        get_char             ; consume SAVE token
                CALL16        CMD_SAVE
                BRA         .es_post_dispatch

.es_load:       CALL16        get_char             ; consume LOAD token
                CALL16        CMD_LOAD
                BRA         .es_post_dispatch

.es_dir:        CALL16        get_char             ; consume DIR token
                CALL16        CMD_DIR
                BRA         .es_post_dispatch

.es_drive:      CALL16        get_char             ; consume DRIVE token
                CALL16        CMD_DRIVE
                BRA         .es_post_dispatch

.es_next_stmt:  CALL16        get_char
                BRA         exec_statement

.es_syntax_err:
                LEA         XY0, STR_SYNERR
                BRA         error_msg

; ============================================================================
; ERROR HANDLING
; ============================================================================

error_msg:
                CALL16        print_string
                LOADP       D0, Y3, [#ZP_RUNNING]
                CMP         D0, #0
                BEQ         .err_nl
                PUSH        XY0, XY3
                LEA         XY0, STR_INLN
                CALL16        print_string
                LOADP       D0, Y3, [#ZP_LINENUM]
                CALL16        print_unsigned
                POP         XY0, XY3
.err_nl:        CALL16        print_newline
                BRA         cmd_loop

; ============================================================================
; TEXT HELPERS
; ============================================================================

get_text_page:
                LOADP       D0, Y3, [#ZP_RUNNING]
                CMP         D0, #0
                BEQ         .gtp_direct
                MOVE        Y0, Y3
                RET
.gtp_direct:    MOVE        Y0, Y3
                RET

peek_char:
                LOADP       D0, Y3, [#ZP_TXTPOS]
                MOVE        X0, D0
                CALL16        get_text_page
                LOADB       D0, [XY0]
                RET

get_char:
                LOADP       D0, Y3, [#ZP_TXTPOS]
                MOVE        X0, D0
                CALL16        get_text_page
                LOADB       D0, [XY0]
                CMP         D0, #0
                BEQ         .gc_done
                ADD         X0, #1
                MOVE        D0, X0
                STOREP      D0, Y3, [#ZP_TXTPOS]
                SUB         X0, #1
                LOADB       D0, [XY0]
.gc_done:       RET

skip_spaces:
                LOADP       D0, Y3, [#ZP_TXTPOS]
                MOVE        X0, D0
                CALL16        get_text_page
.ss_loop:       LOADB       D0, [XY0]
                CMP         D0, #$20
                BNE         .ss_done
                ADD         X0, #1
                BRA         .ss_loop
.ss_done:       MOVE        D0, X0
                STOREP      D0, Y3, [#ZP_TXTPOS]
                RET

; ============================================================================
; TOKENIZER - converts raw ASCII line to tokenized form (in-place in TIB)
; Tokens are always shorter than keywords, so in-place write is safe.
; Call after read_line, before parse_linenum.
; Uses: XY0=read, XY2=write (both in TIB, RAM_PAGE)
; ============================================================================

tokenize_line:
                LOADI       X0, #TIB_OFFSET
                MOVE        Y0, Y3
                MOVE        X2, X0
                MOVE        Y2, Y3

.tok_loop:      LOADB       D0, [XY0]
                CMP         D0, #0
                BEQ         .tok_done

                ; --- Inside a quoted string: copy verbatim ---
                CMP         D0, #$22            ; double-quote
                BEQ         .tok_string

                ; --- Alphabetic? potential keyword ---
                CALL16        .tok_is_alpha
                CMP         D0, #0
                BNE         .tok_try_kw

                ; --- Check for compound operators <= >= <> ---
                LOADB       D0, [XY0]
                CMP         D0, #$3C            ; '<'
                BEQ         .tok_lt
                CMP         D0, #$3E            ; '>'
                BEQ         .tok_gt

                ; --- Copy single byte ---
.tok_copy1:     LOADB       D0, [XY0]
                STOREB      D0, [XY2]
                ADD         X0, #1
                ADD         X2, #1
                BRA         .tok_loop

                ; --- '<' followed by '=' or '>' ---
.tok_lt:        ADD         X0, #1
                LOADB       D1, [XY0]
                CMP         D1, #$3D            ; '='
                BEQ         .tok_emit_le
                CMP         D1, #$3E            ; '>'
                BEQ         .tok_emit_ne
                SUB         X0, #1              ; put back, copy '<' as-is
                BRA         .tok_copy1
.tok_emit_le:   LOADI       D0, #TOK_LE
                BRA         .tok_emit2
.tok_emit_ne:   LOADI       D0, #TOK_NE
                BRA         .tok_emit2

                ; --- '>' followed by '=' ---
.tok_gt:        ADD         X0, #1
                LOADB       D1, [XY0]
                CMP         D1, #$3D            ; '='
                BEQ         .tok_emit_ge
                SUB         X0, #1              ; put back, copy '>' as-is
                BRA         .tok_copy1
.tok_emit_ge:   LOADI       D0, #TOK_GE

.tok_emit2:     STOREB      D0, [XY2]          ; emit token
                ADD         X0, #1              ; skip 2nd char
                ADD         X2, #1
                BRA         .tok_loop

                ; --- Copy quoted string verbatim ---
.tok_string:    STOREB      D0, [XY2]          ; copy opening quote
                ADD         X0, #1
                ADD         X2, #1
.tok_str_lp:    LOADB       D0, [XY0]
                CMP         D0, #0
                BEQ         .tok_done           ; unterminated string
                STOREB      D0, [XY2]
                ADD         X0, #1
                ADD         X2, #1
                CMP         D0, #$22
                BNE         .tok_str_lp         ; keep until closing quote
                BRA         .tok_loop

                ; --- Try keyword match ---
.tok_try_kw:    PUSH        XY0, XY3            ; save read pos
                LEA         XY1, TOK_TABLE

.tok_kw_entry:  LOADB       D3, [XY1]          ; token value
                CMP         D3, #$FF
                BEQ         .tok_kw_fail        ; $FF = end of table
                CMP         D3, #0
                BEQ         .tok_kw_pad         ; $00 = alignment padding, skip

                ADD         X1, #1              ; skip token byte
                ; Save table pos after token byte
                MOVE        D2, X1

                ; Compare keyword string at XY1 with source at XY0
                ; (XY0 already correct from entry or POP/PUSH in .tok_kw_skip)

.tok_kw_cmp:    LOADB       D0, [XY1]          ; table char
                CMP         D0, #0
                BEQ         .tok_kw_hit         ; end of keyword = match

                LOADB       D1, [XY0]           ; source char
                ; To uppercase for comparison
                CMP         D1, #$61
                BCC         .tok_kw_c1
                CMP         D1, #$7B
                BCS         .tok_kw_c1
                AND         D1, #$DF            ; to uppercase
.tok_kw_c1:     CMP         D0, D1
                BNE         .tok_kw_skip        ; mismatch, try next keyword
                ADD         X0, #1
                ADD         X1, #1
                BRA         .tok_kw_cmp

.tok_kw_hit:    ; Keyword matched! Check next char isn't alphanumeric
                ; (avoid matching "FOR" in "FORMAT")
                LOADB       D1, [XY0]
                CALL16        .tok_is_alnum_d1
                CMP         D0, #0
                BNE         .tok_kw_skip        ; next char is alnum, not a match

                ; Emit token byte, advance read pointer past keyword
                MOVE        D1, X0              ; save X0 (past matched keyword)
                POP         XY0, XY3            ; discard saved read pos (overwrites X0!)
                MOVE        X0, D1              ; restore advanced position
                STOREB      D3, [XY2]
                ADD         X2, #1
                ; XY0 is now past the matched keyword
                ; Check for REM - copy rest of line verbatim
                CMP         D3, #TOK_REM
                BEQ         .tok_rem
                ; Check for DATA - also copy rest verbatim
                CMP         D3, #TOK_DATA
                BEQ         .tok_rem
                BRA         .tok_loop

                ; --- REM/DATA: copy rest of line as-is ---
.tok_rem:       LOADB       D0, [XY0]
                CMP         D0, #0
                BEQ         .tok_done
                STOREB      D0, [XY2]
                ADD         X0, #1
                ADD         X2, #1
                BRA         .tok_rem

                ; --- Skip to next keyword table entry ---
.tok_kw_skip:   MOVE        X1, D2              ; restore to after token byte
                MOVE        Y1, Y3              ; (port: TOK_TABLE lives in our page)
.tok_kw_sk2:    LOADB       D0, [XY1]          ; skip keyword string
                ADD         X1, #1
                CMP         D0, #0
                BNE         .tok_kw_sk2
                ; XY1 now at next entry's token byte
                ; Restore XY0 read position
                POP         XY0, XY3
                PUSH        XY0, XY3            ; re-push for next try
                BRA         .tok_kw_entry

.tok_kw_pad:    ADD         X1, #1              ; skip padding byte
                BRA         .tok_kw_entry

.tok_kw_fail:   POP         XY0, XY3            ; restore read pos
                ; No keyword matched - copy single byte
                BRA         .tok_copy1

.tok_done:      STOREB      D0, [XY2]          ; null terminate (D0=0)
                RET

; --- Helper: check if byte at [XY0] is alphabetic ---
; Returns D0=1 if alpha, D0=0 if not
.tok_is_alpha:  LOADB       D0, [XY0]
                CMP         D0, #$41            ; 'A'
                BCC         .tok_not_alpha
                CMP         D0, #$5B            ; 'Z'+1
                BCC         .tok_yes_alpha
                CMP         D0, #$61            ; 'a'
                BCC         .tok_not_alpha
                CMP         D0, #$7B            ; 'z'+1
                BCC         .tok_yes_alpha
.tok_not_alpha: LOADI       D0, #0
                RET
.tok_yes_alpha: LOADI       D0, #1
                RET

; --- Helper: check if D1 is alphanumeric ---
; Returns D0=1 if alnum, D0=0 if not. Preserves D1.
.tok_is_alnum_d1:
                CMP         D1, #$30            ; '0'
                BCC         .tok_not_alnum
                CMP         D1, #$3A            ; '9'+1
                BCC         .tok_yes_alnum
                CMP         D1, #$41
                BCC         .tok_not_alnum
                CMP         D1, #$5B
                BCC         .tok_yes_alnum
                CMP         D1, #$61
                BCC         .tok_not_alnum
                CMP         D1, #$7B
                BCC         .tok_yes_alnum
.tok_not_alnum: LOADI       D0, #0
                RET
.tok_yes_alnum: LOADI       D0, #1
                RET

; ============================================================================
; DETOKENIZE BYTE - expand token to keyword string for LIST output
; Input: D0 = byte to print. If $80+, look up and print keyword string.
; Uses: XY1 scratch
; ============================================================================

detok_print:
                CMP         D0, #$80
                BCC         .dp_raw             ; < $80 = normal ASCII
                ; Token byte: look up in DETOK_TABLE
                PUSH        XY0, XY3
                SUB         D0, #$80            ; zero-base index
                ADD         D0, D0              ; word offset
                LEA         XY1, DETOK_TABLE
                LOADD       D0, [XY1+D0]       ; Mode 01: string pointer
                MOVE        X0, D0
                MOVE        Y0, Y3              ; (port: strings live in our page)
                CALL16        print_string
                POP         XY0, XY3
                RET
.dp_raw:        ; Print single ASCII char (port: was a duplicate of emit_char
                ; targeting TERMINAL MMIO; now just defers to emit_char/TRAP).
                BRA         emit_char

; ============================================================================
; COMMAND HANDLERS - Simple commands
; ============================================================================

; --- NEW ---
CMD_NEW:
                LOADI       X0, #PROG_BASE
                MOVE        Y0, Y3
                LOADI       D0, #0
                STORED      D0, [XY0]
                STOREP      D0, Y3, [#ZP_PROGEND]
                ; fall through to CLR

; --- CLR ---
CMD_CLR:
                CALL16        clear_vars
                LOADI       D0, #STRPOOL_TOP
                STOREP      D0, Y3, [#ZP_STRPOOL]
                LOADI       D0, #ARRAY_BASE
                STOREP      D0, Y3, [#ZP_ARRTOP]
                LOADI       D0, #0
                STOREP      D0, Y3, [#ZP_DATALINE]
                STOREP      D0, Y3, [#ZP_DATAPOS]
                RET

clear_vars:
                LOADI       D1, #26
                LOADI       D0, #0
                LOADI       X0, #ZP_VARS
                MOVE        Y0, Y3
.cv_int:        STORED      D0, [XY0]
                ADD         X0, #2
                SUB         D1, #1
                BNE         .cv_int
                LOADI       D1, #52             ; 26 descriptors x 2 words
                LOADI       X0, #ZP_STRVARS
.cv_str:        STORED      D0, [XY0]
                ADD         X0, #2
                SUB         D1, #1
                BNE         .cv_str
                LOADI       D1, #52
                LOADI       X0, #ZP_ARRAYS
.cv_arr:        STORED      D0, [XY0]
                ADD         X0, #2
                SUB         D1, #1
                BNE         .cv_arr
                RET

; --- LIST ---
CMD_LIST:
                LOADI       X0, #PROG_BASE
                MOVE        Y0, Y3
.list_loop:     LOADD       D0, [XY0]
                CMP         D0, #0
                BEQ         .list_done
                STOREP      X0, Y3, [#ZP_TMPLEN] ; save position in ZP
                CALL16        print_unsigned
                LOADI       D0, #$20
                CALL16        emit_char
                LOADP       X0, Y3, [#ZP_TMPLEN] ; restore position
                MOVE        Y0, Y3
                ADD         X0, #2
.list_text:     LOADB       D0, [XY0]
                CMP         D0, #0
                BEQ         .list_nl
                STOREP      X0, Y3, [#ZP_TMPLEN]
                CALL16        detok_print          ; expand tokens to keywords
                LOADP       X0, Y3, [#ZP_TMPLEN]
                MOVE        Y0, Y3
                ADD         X0, #1
                BRA         .list_text
.list_nl:       ADD         X0, #1
                ADD         X0, #1
                AND         X0, #$FFFE
                STOREP      X0, Y3, [#ZP_TMPLEN]
                CALL16        print_newline
                LOADP       X0, Y3, [#ZP_TMPLEN]
                MOVE        Y0, Y3
                BRA         .list_loop
.list_done:     RET

; --- REM / DATA (skip rest of line at execution time) ---
CMD_REM:
CMD_DATA:
                LOADP       D0, Y3, [#ZP_TXTPOS]
                MOVE        X0, D0
                CALL16        get_text_page
.rem_skip:      LOADB       D0, [XY0]
                CMP         D0, #0
                BEQ         .rem_done
                ADD         X0, #1
                BRA         .rem_skip
.rem_done:      MOVE        D0, X0
                STOREP      D0, Y3, [#ZP_TXTPOS]
                RET

; --- END ---
CMD_END:
                LOADI       D0, #0
                STOREP      D0, Y3, [#ZP_RUNNING]
                RET

; --- STOP ---
CMD_STOP:
                LEA         XY0, STR_BREAK
                CALL16        print_string
                LEA         XY0, STR_INLN
                CALL16        print_string
                LOADP       D0, Y3, [#ZP_LINENUM]
                CALL16        print_unsigned
                CALL16        print_newline
                LOADI       D0, #0
                STOREP      D0, Y3, [#ZP_RUNNING]
                RET

; --- GOTO ---
CMD_GOTO:
                CALL16        skip_spaces
                CALL16        expr
                CALL16        find_line
                CMP         D0, #$FFFF
                BEQ         .goto_err
                STOREP      D0, Y3, [#ZP_CURLINE]
                LOADP       D0, Y3, [#ZP_RUNNING]
                CMP         D0, #0
                BEQ         .goto_direct_err
                LOADP       X3, Y3, [#ZP_RUNSP]
                BRA         run_loop
.goto_err:
                LEA         XY0, STR_LINERR
                BRA         error_msg
.goto_direct_err:
                LEA         XY0, STR_SYNERR
                BRA         error_msg

; --- GOSUB ---
CMD_GOSUB:
                LOADP       D0, Y3, [#ZP_GOSUBSP]
                CMP         D0, #GOSUB_MAX
                BCS         .gosub_err

                MOVE        D1, D0
                SHL         D1
                SHL         D1
                ADD         D1, #ZP_GOSUBSTK

                LOADP       D2, Y3, [#ZP_CURLINE]
                PUSH        XY0, XY3
                MOVE        X0, D1
                MOVE        Y0, Y3
                STORED      D2, [XY0]
                ADD         X0, #2
                LOADP       D2, Y3, [#ZP_TXTPOS]
                STORED      D2, [XY0]
                POP         XY0, XY3

                ADD         D0, #1
                STOREP      D0, Y3, [#ZP_GOSUBSP]
                BRA         CMD_GOTO

.gosub_err:
                LEA         XY0, STR_GOSERR
                BRA         error_msg

; --- RETURN ---
CMD_RETURN:
                LOADP       D0, Y3, [#ZP_GOSUBSP]
                CMP         D0, #0
                BEQ         .ret_err
                SUB         D0, #1
                STOREP      D0, Y3, [#ZP_GOSUBSP]

                MOVE        D1, D0
                SHL         D1
                SHL         D1
                ADD         D1, #ZP_GOSUBSTK
                MOVE        X0, D1
                MOVE        Y0, Y3
                LOADD       D2, [XY0]
                STOREP      D2, Y3, [#ZP_CURLINE]
                ADD         X0, #2
                LOADD       D2, [XY0]
                STOREP      D2, Y3, [#ZP_TXTPOS]
                RET

.ret_err:
                LEA         XY0, STR_RETERR
                BRA         error_msg

; ============================================================================

CMD_LET:
                CALL16        skip_spaces
                CALL16        get_char
                CMP         D0, #$61
                BCC         .let_c1
                AND         D0, #$DF
.let_c1:        CMP         D0, #$41
                BCC         .let_err
                CMP         D0, #$5B
                BCS         .let_err
                SUB         D0, #$41
                PUSH        D0, XY3             ; save var index

                CALL16        peek_char
                CMP         D0, #$24             ; '$'
                BEQ         .let_string
                CMP         D0, #$28             ; '('
                BEQ         .let_array

                ; Integer assignment
                POP         D0, XY3
                SHL         D0
                ADD         D0, #ZP_VARS
                PUSH        D0, XY3
                CALL16        skip_spaces
                CALL16        get_char
                CMP         D0, #$3D
                BNE         .let_err2
                CALL16        expr
                POP         D1, XY3
                MOVE        X0, D1
                MOVE        Y0, Y3
                STORED      D0, [XY0]
                RET

.let_string:
                CALL16        get_char             ; consume '$'
                POP         D0, XY3
                SHL         D0
                SHL         D0
                ADD         D0, #ZP_STRVARS
                PUSH        D0, XY3             ; descriptor addr
                CALL16        skip_spaces
                CALL16        get_char
                CMP         D0, #$3D
                BNE         .let_err2

                CALL16        str_expr             ; result in ZP_TMPLEN/ZP_TMPPTR

                ; Allocate in string pool
                LOADP       D0, Y3, [#ZP_TMPLEN]
                CALL16        str_pool_alloc       ; D2 = pool ptr, D0 = status
                CMP         D0, #0
                BNE         .let_mem_err

                ; Copy string to pool
                MOVE        X0, D2
                MOVE        Y0, Y3
                LOADP       D0, Y3, [#ZP_TMPPTR]
                MOVE        X1, D0
                MOVE        Y1, Y3
                LOADP       D0, Y3, [#ZP_TMPLEN]
                CALL16        memcpy

                ; Update descriptor
                LOADP       D0, Y3, [#ZP_TMPLEN]
                POP         D1, XY3             ; descriptor addr
                MOVE        X0, D1
                MOVE        Y0, Y3
                STORED      D0, [XY0]           ; length
                ADD         X0, #2
                STORED      D2, [XY0]           ; pointer
                RET

.let_array:
                CALL16        get_char             ; consume '('
                LOADD       D0, [XY3]             ; var index
                CALL16        expr                 ; subscript
                MOVE        D2, D0
                PUSH        D2, XY3
                CALL16        skip_spaces
                CALL16        get_char             ; consume ')'
                POP         D2, XY3             ; subscript
                POP         D0, XY3             ; var index
                CALL16        array_addr           ; D0 = element address
                PUSH        D0, XY3
                CALL16        skip_spaces
                CALL16        get_char
                CMP         D0, #$3D
                BNE         .let_err2
                CALL16        expr
                POP         D1, XY3
                MOVE        X0, D1
                MOVE        Y0, Y3
                STORED      D0, [XY0]
                RET

.let_mem_err:   POP         D0, XY3
                LEA         XY0, STR_MEMERR
                BRA         error_msg
.let_err2:      POP         D0, XY3
.let_err:
                LEA         XY0, STR_SYNERR
                BRA         error_msg

; ============================================================================

CMD_PRINT:
                CALL16        skip_spaces
                CALL16        peek_char
                CMP         D0, #0
                BEQ         .pr_nl
                CMP         D0, #$3A
                BEQ         .pr_nl

.pr_loop:       CALL16        skip_spaces
                CALL16        peek_char
                CMP         D0, #0
                BEQ         .pr_nl
                CMP         D0, #$3A
                BEQ         .pr_nl

                ; String literal?
                CMP         D0, #$22
                BEQ         .pr_strlit

                ; Check if string expression
                CALL16        is_string_expr
                CMP         D0, #1
                BEQ         .pr_strexpr

                ; Numeric expression
                CALL16        expr
                CALL16        print_signed
                BRA         .pr_sep

.pr_strlit:     CALL16        get_char
                CALL16        print_str_literal
                BRA         .pr_sep

.pr_strexpr:    CALL16        str_expr
                LOADP       D2, Y3, [#ZP_TMPLEN]
                LOADP       D3, Y3, [#ZP_TMPPTR]
                CMP         D2, #0
                BEQ         .pr_sep
                MOVE        X0, D3
                MOVE        Y0, Y3
.pr_sloop:      LOADB       D0, [XY0]
                PUSH        XY0, XY3
                PUSH        D2, XY3
                CALL16        emit_char
                POP         D2, XY3
                POP         XY0, XY3
                ADD         X0, #1
                SUB         D2, #1
                BNE         .pr_sloop
                BRA         .pr_sep

.pr_sep:        CALL16        skip_spaces
                CALL16        peek_char
                CMP         D0, #$3B             ; ';'
                BEQ         .pr_semi
                CMP         D0, #$2C             ; ','
                BEQ         .pr_comma
                BRA         .pr_nl

.pr_semi:       CALL16        get_char
                CALL16        peek_char
                CMP         D0, #0
                BEQ         .pr_done
                CMP         D0, #$3A
                BEQ         .pr_done
                BRA         .pr_loop

.pr_comma:      CALL16        get_char
                LOADI       D0, #$09
                CALL16        emit_char
                BRA         .pr_loop

.pr_nl:         CALL16        print_newline
.pr_done:       RET

print_str_literal:
                LOADP       D0, Y3, [#ZP_TXTPOS]
                MOVE        X0, D0
                CALL16        get_text_page
.psl_loop:      LOADB       D0, [XY0]
                CMP         D0, #0
                BEQ         .psl_done
                CMP         D0, #$22
                BEQ         .psl_end
                PUSH        XY0, XY3
                CALL16        emit_char
                POP         XY0, XY3
                ADD         X0, #1
                BRA         .psl_loop
.psl_end:       ADD         X0, #1
.psl_done:      MOVE        D0, X0
                STOREP      D0, Y3, [#ZP_TXTPOS]
                RET

; ============================================================================
; INPUT - integer and string
; ============================================================================

CMD_INPUT:
                CALL16        skip_spaces
                CALL16        peek_char
                CMP         D0, #$22
                BNE         .inp_defprompt
                CALL16        get_char
                CALL16        print_str_literal
                CALL16        skip_spaces
                CALL16        get_char             ; skip separator
                BRA         .inp_getvar
.inp_defprompt:
                LEA         XY0, STR_QUEST
                CALL16        print_string

.inp_getvar:    CALL16        skip_spaces
                CALL16        get_char
                CMP         D0, #$61
                BCC         .inp_c1
                AND         D0, #$DF
.inp_c1:        CMP         D0, #$41
                BCC         .inp_err
                CMP         D0, #$5B
                BCS         .inp_err
                SUB         D0, #$41
                PUSH        D0, XY3

                ; Check for '$'
                CALL16        peek_char
                CMP         D0, #$24
                BEQ         .inp_str

                ; Integer input
                POP         D0, XY3
                SHL         D0
                ADD         D0, #ZP_VARS
                PUSH        D0, XY3
                CALL16        accept_line
                LOADI       X0, #TIB_OFFSET
                MOVE        Y0, Y3
                CALL16        parse_input_number
                POP         D1, XY3
                MOVE        X0, D1
                MOVE        Y0, Y3
                STORED      D0, [XY0]
                RET

.inp_str:       CALL16        get_char             ; consume '$'
                POP         D0, XY3
                SHL         D0
                SHL         D0
                ADD         D0, #ZP_STRVARS
                PUSH        D0, XY3

                CALL16        accept_line          ; D0 = length
                PUSH        D0, XY3             ; save length

                ; Allocate in string pool
                CALL16        str_pool_alloc       ; D2 = pool ptr, D0 = status
                CMP         D0, #0
                BNE         .inp_mem_err2

                ; Copy TIB to pool
                MOVE        X0, D2
                MOVE        Y0, Y3
                LOADI       X1, #TIB_OFFSET
                MOVE        Y1, Y3
                LOADD       D0, [XY3]             ; length
                CALL16        memcpy

                ; Update descriptor
                POP         D3, XY3             ; length
                POP         D0, XY3             ; descriptor addr
                MOVE        X0, D0
                MOVE        Y0, Y3
                STORED      D3, [XY0]           ; length
                ADD         X0, #2
                STORED      D2, [XY0]           ; pointer
                RET

.inp_mem_err2:  POP         D0, XY3             ; discard length
                LEA         XY0, STR_MEMERR
                BRA         error_msg

.inp_err:
                LEA         XY0, STR_SYNERR
                BRA         error_msg

parse_input_number:
                LOADI       D2, #0
                LOADI       D3, #0
                LOADB       D0, [XY0]
                CMP         D0, #$24
                BEQ         .pin_hex
                CMP         D0, #$2D
                BNE         .pin_loop
                LOADI       D3, #1
                ADD         X0, #1
.pin_loop:      LOADB       D0, [XY0]
                CMP         D0, #$30
                BCC         .pin_done
                CMP         D0, #$3A
                BCS         .pin_done
                MOVE        D1, D2
                SHL         D2
                SHL         D2
                ADD         D2, D1
                SHL         D2
                SUB         D0, #$30
                ADD         D2, D0
                ADD         X0, #1
                BRA         .pin_loop
.pin_done:      CMP         D3, #0
                BEQ         .pin_pos
                LOADI       D0, #0
                SUB         D0, D2
                MOVE        D2, D0
.pin_pos:       MOVE        D0, D2
                RET
.pin_hex:       ADD         X0, #1
.pin_hloop:     LOADB       D0, [XY0]
                CMP         D0, #$30
                BCC         .pin_hdone
                CMP         D0, #$3A
                BCC         .pin_hdigit
                AND         D0, #$DF
                CMP         D0, #$41
                BCC         .pin_hdone
                CMP         D0, #$47
                BCS         .pin_hdone
                SUB         D0, #$37
                BRA         .pin_haccum
.pin_hdigit:    SUB         D0, #$30
.pin_haccum:    SHL4        D2
                OR          D2, D0
                ADD         X0, #1
                BRA         .pin_hloop
.pin_hdone:     MOVE        D0, D2
                RET

; ============================================================================

CMD_IF:
                CALL16        expr
                CMP         D0, #0
                BEQ         .if_false
                CALL16        skip_spaces
                CALL16        match_then
                BRA         exec_statement

.if_false:      CALL16        skip_to_else
                CMP         D0, #0
                BEQ         .if_done
                BRA         exec_statement
.if_done:       RET

; Skip to ELSE at nesting depth 0, or end of line.
; D0=1 if ELSE found, 0 if EOL.
; Tracks nested IF/ELSE so inner ELSE is skipped.
skip_to_else:
                LOADP       D0, Y3, [#ZP_TXTPOS]
                MOVE        X0, D0
                CALL16        get_text_page
                LOADI       D2, #0               ; nesting depth

.ste_loop:      LOADB       D0, [XY0]
                CMP         D0, #0
                BEQ         .ste_nf
                CMP         D0, #$22              ; skip quoted strings
                BEQ         .ste_skipstr
                CMP         D0, #TOK_IF
                BEQ         .ste_nest
                CMP         D0, #TOK_ELSE
                BEQ         .ste_else
                ADD         X0, #1
                BRA         .ste_loop

.ste_skipstr:   ADD         X0, #1
.ste_ss2:       LOADB       D0, [XY0]
                CMP         D0, #0
                BEQ         .ste_nf
                CMP         D0, #$22
                BEQ         .ste_ss3
                ADD         X0, #1
                BRA         .ste_ss2
.ste_ss3:       ADD         X0, #1
                BRA         .ste_loop

.ste_nest:      ADD         D2, #1               ; increase nesting depth
                ADD         X0, #1
                BRA         .ste_loop

.ste_else:      ADD         X0, #1               ; skip past ELSE token
                CMP         D2, #0
                BEQ         .ste_found           ; at depth 0 = our ELSE
                SUB         D2, #1               ; nested ELSE
                BRA         .ste_loop

.ste_found:     MOVE        D0, X0
                STOREP      D0, Y3, [#ZP_TXTPOS]
                LOADI       D0, #1
                RET

.ste_nf:        MOVE        D0, X0
                STOREP      D0, Y3, [#ZP_TXTPOS]
                LOADI       D0, #0
                RET

match_then:
                CALL16        peek_char
                CMP         D0, #TOK_THEN
                BNE         .mt_done
                CALL16        get_char             ; consume THEN token
.mt_done:       RET

; ============================================================================
; FOR / NEXT
; ============================================================================

CMD_FOR:
                LOADP       D0, Y3, [#ZP_FORSP]
                CMP         D0, #FOR_MAX
                BCS         .for_err
                PUSH        D0, XY3

                CALL16        skip_spaces
                CALL16        get_char
                CMP         D0, #$61
                BCC         .for_c1
                AND         D0, #$DF
.for_c1:        SUB         D0, #$41
                PUSH        D0, XY3

                CALL16        skip_spaces
                CALL16        get_char
                CMP         D0, #$3D
                BNE         .for_syn_err

                CALL16        expr
                PUSH        D0, XY3             ; start

                CALL16        skip_spaces
                CALL16        match_to
                CMP         D0, #0
                BEQ         .for_syn_err2

                CALL16        expr
                PUSH        D0, XY3             ; limit

                CALL16        skip_spaces
                CALL16        match_step
                CMP         D0, #0
                BEQ         .for_step1
                CALL16        expr
                BRA         .for_save
.for_step1:     LOADI       D0, #1

.for_save:      MOVE        D3, D0              ; step
                POP         D2, XY3             ; limit
                POP         D1, XY3             ; start
                POP         D0, XY3             ; var index

                ; Set variable = start
                PUSH        D0, XY3
                SHL         D0
                ADD         D0, #ZP_VARS
                PUSH        XY0, XY3
                MOVE        X0, D0
                MOVE        Y0, Y3
                STORED      D1, [XY0]
                POP         XY0, XY3

                ; Build FOR stack entry
                POP         D0, XY3             ; var index
                POP         D1, XY3             ; FOR SP

                PUSH        D1, XY3
                PUSH        D0, XY3

                ; Entry addr = ZP_FORSTK + index*10
                MOVE        X0, D1
                SHL         D1
                SHL         D1
                ADD         D1, X0
                SHL         D1
                ADD         D1, #ZP_FORSTK

                MOVE        X0, D1
                MOVE        Y0, Y3
                POP         D0, XY3             ; var index
                STORED      D0, [XY0]
                ADD         X0, #2
                STORED      D2, [XY0]           ; limit
                ADD         X0, #2
                STORED      D3, [XY0]           ; step
                ADD         X0, #2
                LOADP       D0, Y3, [#ZP_CURLINE]
                STORED      D0, [XY0]
                ADD         X0, #2
                LOADP       D0, Y3, [#ZP_TXTPOS]
                STORED      D0, [XY0]

                POP         D0, XY3             ; old FOR SP
                ADD         D0, #1
                STOREP      D0, Y3, [#ZP_FORSP]
                RET

.for_err:
                LEA         XY0, STR_FORERR
                BRA         error_msg
.for_syn_err2:  POP         D0, XY3
.for_syn_err:   POP         D0, XY3
                POP         D0, XY3
                LEA         XY0, STR_SYNERR
                BRA         error_msg

match_to:
                CALL16        peek_char
                CMP         D0, #TOK_TO
                BNE         .mto_fail
                CALL16        get_char             ; consume TO token
                LOADI       D0, #1
                RET
.mto_fail:      LOADI       D0, #0
                RET

match_step:
                CALL16        peek_char
                CMP         D0, #TOK_STEP
                BNE         .mst_fail
                CALL16        get_char             ; consume STEP token
                LOADI       D0, #1
                RET
.mst_fail:      LOADI       D0, #0
                RET

; --- NEXT ---
CMD_NEXT:
                LOADP       D0, Y3, [#ZP_FORSP]
                CMP         D0, #0
                BEQ         .next_err

                CALL16        skip_spaces
                CALL16        peek_char
                LOADI       D3, #$FFFF

                CMP         D0, #$41
                BCC         .next_find
                CMP         D0, #$5B
                BCC         .next_hasvar
                CMP         D0, #$61
                BCC         .next_find
                CMP         D0, #$7B
                BCS         .next_find

.next_hasvar:   CALL16        get_char
                AND         D0, #$DF
                SUB         D0, #$41
                MOVE        D3, D0

.next_find:     LOADP       D0, Y3, [#ZP_FORSP]
                SUB         D0, #1

.next_search:   CMP         D0, #$FFFF
                BEQ         .next_err

                PUSH        D0, XY3
                MOVE        D1, D0
                SHL         D0
                SHL         D0
                ADD         D0, D1
                SHL         D0
                ADD         D0, #ZP_FORSTK

                MOVE        X0, D0
                MOVE        Y0, Y3
                LOADD       D1, [XY0]           ; var index

                CMP         D3, #$FFFF
                BEQ         .next_found
                CMP         D1, D3
                BEQ         .next_found

                POP         D0, XY3
                SUB         D0, #1
                BRA         .next_search

.next_found:    ADD         X0, #2
                LOADD       D2, [XY0]           ; limit
                ADD         X0, #2
                LOADD       D3, [XY0]           ; step

                ; Get/increment variable
                MOVE        D0, D1
                SHL         D0
                ADD         D0, #ZP_VARS
                PUSH        X0, XY3
                MOVE        X0, D0
                MOVE        Y0, Y3
                LOADD       D0, [XY0]
                ADD         D0, D3
                STORED      D0, [XY0]

                POP         X0, XY3
                CMP         D3, #0
                BLT         .next_neg
                CMP         D0, D2
                BGT         .next_done
                BRA         .next_loop
.next_neg:      CMP         D0, D2
                BLT         .next_done

.next_loop:     ADD         X0, #2
                MOVE        Y0, Y3
                LOADD       D0, [XY0]           ; saved curline

                MOVE        X0, D0
                MOVE        Y0, Y3
                ADD         X0, #2
.next_skipln:   LOADB       D0, [XY0]
                ADD         X0, #1
                CMP         D0, #0
                BNE         .next_skipln
                ADD         X0, #1
                AND         X0, #$FFFE
                MOVE        D0, X0
                STOREP      D0, Y3, [#ZP_CURLINE]

                POP         D0, XY3
                LOADP       X3, Y3, [#ZP_RUNSP]
                BRA         run_loop

.next_done:     POP         D0, XY3
                STOREP      D0, Y3, [#ZP_FORSP]
                RET

.next_err:
                LEA         XY0, STR_NXTERR
                BRA         error_msg

; ============================================================================
; POKE / DOKE
; ============================================================================

CMD_POKE:
                CALL16        expr
                PUSH        D0, XY3
                CALL16        skip_spaces
                CALL16        get_char
                CMP         D0, #$2C
                BNE         .poke_err
                CALL16        expr
                POP         D1, XY3
                MOVE        X0, D1
                MOVE        Y0, Y3
                STOREB      D0, [XY0]
                RET
.poke_err:      POP         D0, XY3
                LEA         XY0, STR_SYNERR
                BRA         error_msg

CMD_DOKE:
                CALL16        expr
                PUSH        D0, XY3
                CALL16        skip_spaces
                CALL16        get_char
                CMP         D0, #$2C
                BNE         .doke_err
                CALL16        expr
                POP         D1, XY3
                MOVE        X0, D1
                MOVE        Y0, Y3
                STORED      D0, [XY0]
                RET
.doke_err:      POP         D0, XY3
                LEA         XY0, STR_SYNERR
                BRA         error_msg

; ============================================================================
; DIM
; ============================================================================

CMD_DIM:
.dim_loop:      CALL16        skip_spaces
                CALL16        get_char
                CMP         D0, #$61
                BCC         .dim_c1
                AND         D0, #$DF
.dim_c1:        CMP         D0, #$41
                BCC         .dim_err
                CMP         D0, #$5B
                BCS         .dim_err
                SUB         D0, #$41
                PUSH        D0, XY3             ; var index

                CALL16        skip_spaces
                CALL16        get_char
                CMP         D0, #$28
                BNE         .dim_err2

                CALL16        expr                 ; dimension size
                CMP         D0, #0
                BEQ         .dim_bad
                PUSH        D0, XY3             ; dimension

                CALL16        skip_spaces
                CALL16        get_char
                CMP         D0, #$29
                BNE         .dim_err3

                POP         D0, XY3             ; dimension
                POP         D1, XY3             ; var index

                ; Check not already DIMmed
                MOVE        D2, D1
                SHL         D2
                SHL         D2
                ADD         D2, #ZP_ARRAYS
                PUSH        D1, XY3
                PUSH        D0, XY3
                PUSH        D2, XY3
                MOVE        X0, D2
                MOVE        Y0, Y3
                LOADD       D3, [XY0]
                CMP         D3, #0
                BNE         .dim_redef

                ; Allocate: (dim+1) * 2 bytes
                POP         D2, XY3             ; descriptor addr
                POP         D0, XY3             ; dimension
                ADD         D0, #1
                PUSH        D0, XY3             ; dim+1
                PUSH        D2, XY3

                MOVE        D1, D0
                SHL         D1                  ; bytes needed
                LOADP       D2, Y3, [#ZP_ARRTOP]
                PUSH        D2, XY3             ; base address
                ADD         D2, D1
                LOADP       D3, Y3, [#ZP_STRPOOL]
                CMP         D2, D3
                BCS         .dim_mem_err
                STOREP      D2, Y3, [#ZP_ARRTOP]

                POP         D2, XY3             ; base
                POP         D3, XY3             ; descriptor addr
                POP         D0, XY3             ; dim+1
                POP         D1, XY3             ; discard var index

                ; Store descriptor
                MOVE        X0, D3
                MOVE        Y0, Y3
                STORED      D0, [XY0]           ; dimension
                ADD         X0, #2
                STORED      D2, [XY0]           ; base

                ; Zero-fill
                MOVE        X0, D2
                MOVE        Y0, Y3
                MOVE        D1, D0
                LOADI       D0, #0
.dim_fill:      STORED      D0, [XY0]
                ADD         X0, #2
                SUB         D1, #1
                BNE         .dim_fill

                ; Check for more arrays
                CALL16        skip_spaces
                CALL16        peek_char
                CMP         D0, #$2C
                BNE         .dim_done
                CALL16        get_char
                BRA         .dim_loop
.dim_done:      RET

.dim_mem_err:   POP         D2, XY3
                POP         D3, XY3
                POP         D0, XY3
                POP         D1, XY3
                LEA         XY0, STR_MEMERR
                BRA         error_msg
.dim_redef:     POP         D2, XY3
                POP         D0, XY3
                POP         D1, XY3
.dim_bad:       POP         D0, XY3
                LEA         XY0, STR_DIMERR
                BRA         error_msg
.dim_err3:      POP         D0, XY3
.dim_err2:      POP         D0, XY3
.dim_err:
                LEA         XY0, STR_SYNERR
                BRA         error_msg

; ============================================================================
; ON expr GOTO/GOSUB line1,line2,...
; ============================================================================

CMD_ON:
                CALL16        expr                 ; selector (1-based)
                PUSH        D0, XY3

                CALL16        skip_spaces
                CALL16        peek_char
                CMP         D0, #TOK_GOTO
                BEQ         .on_got_kw
                CMP         D0, #TOK_GOSUB
                BNE         .on_err
.on_got_kw:     CALL16        get_char             ; consume GOTO/GOSUB token
                PUSH        D0, XY3             ; save token

                ; Count to target
                POP         D1, XY3             ; token
                POP         D0, XY3             ; selector
                PUSH        D1, XY3
                CMP         D0, #0
                BEQ         .on_err2
                MOVE        D2, D0

.on_count:      SUB         D2, #1
                BEQ         .on_found
                ; Skip digits
                CALL16        skip_spaces
.on_skip:       CALL16        peek_char
                CMP         D0, #$30
                BCC         .on_skip_d
                CMP         D0, #$3A
                BCS         .on_skip_d
                CALL16        get_char
                BRA         .on_skip
.on_skip_d:     CALL16        skip_spaces
                CALL16        peek_char
                CMP         D0, #$2C
                BNE         .on_over
                CALL16        get_char
                BRA         .on_count

.on_found:      CALL16        expr                 ; target line number
                CALL16        find_line
                CMP         D0, #$FFFF
                BEQ         .on_line_err

                POP         D1, XY3             ; token
                CMP         D1, #TOK_GOSUB
                BEQ         .on_gosub

                ; GOTO path
                STOREP      D0, Y3, [#ZP_CURLINE]
                LOADP       X3, Y3, [#ZP_RUNSP]
                BRA         run_loop

.on_gosub:      PUSH        D0, XY3             ; save target
                LOADP       D0, Y3, [#ZP_GOSUBSP]
                CMP         D0, #GOSUB_MAX
                BCS         .on_gos_err
                MOVE        D1, D0
                SHL         D1
                SHL         D1
                ADD         D1, #ZP_GOSUBSTK
                LOADP       D2, Y3, [#ZP_CURLINE]
                PUSH        XY0, XY3
                MOVE        X0, D1
                MOVE        Y0, Y3
                STORED      D2, [XY0]
                ADD         X0, #2
                LOADP       D2, Y3, [#ZP_TXTPOS]
                STORED      D2, [XY0]
                POP         XY0, XY3
                ADD         D0, #1
                STOREP      D0, Y3, [#ZP_GOSUBSP]
                POP         D0, XY3             ; target
                STOREP      D0, Y3, [#ZP_CURLINE]
                LOADP       X3, Y3, [#ZP_RUNSP]
                BRA         run_loop

.on_over:       POP         D0, XY3
                RET
.on_line_err:   POP         D0, XY3
                LEA         XY0, STR_LINERR
                BRA         error_msg
.on_gos_err:    POP         D0, XY3
                LEA         XY0, STR_GOSERR
                BRA         error_msg
.on_err2:       POP         D0, XY3
.on_err:
                LEA         XY0, STR_SYNERR
                BRA         error_msg

; ============================================================================
; READ / RESTORE / DATA helpers
; ============================================================================

CMD_READ:
.read_loop:     CALL16        skip_spaces
                CALL16        get_char
                CMP         D0, #$61
                BCC         .read_c1
                AND         D0, #$DF
.read_c1:       CMP         D0, #$41
                BCC         .read_err
                CMP         D0, #$5B
                BCS         .read_err
                SUB         D0, #$41
                PUSH        D0, XY3

                ; Check for string read
                CALL16        peek_char
                CMP         D0, #$24
                BEQ         .read_str

                ; Integer read
                POP         D0, XY3
                SHL         D0
                ADD         D0, #ZP_VARS
                PUSH        D0, XY3
                CALL16        get_data_item
                POP         D1, XY3
                MOVE        X0, D1
                MOVE        Y0, Y3
                STORED      D0, [XY0]
                BRA         .read_more

.read_str:      CALL16        get_char             ; consume '$'
                POP         D0, XY3
                SHL         D0
                SHL         D0
                ADD         D0, #ZP_STRVARS
                PUSH        D0, XY3

                CALL16        get_data_str         ; result in TMPLEN/TMPPTR

                ; Allocate in pool
                LOADP       D0, Y3, [#ZP_TMPLEN]
                CALL16        str_pool_alloc       ; D2 = ptr, D0 = status
                CMP         D0, #0
                BNE         .read_mem_err

                ; Copy from temp to pool
                MOVE        X0, D2
                MOVE        Y0, Y3
                LOADP       D0, Y3, [#ZP_TMPPTR]
                MOVE        X1, D0
                MOVE        Y1, Y3
                LOADP       D0, Y3, [#ZP_TMPLEN]
                CALL16        memcpy

                ; Update descriptor
                LOADP       D0, Y3, [#ZP_TMPLEN]
                POP         D1, XY3             ; descriptor
                MOVE        X0, D1
                MOVE        Y0, Y3
                STORED      D0, [XY0]
                ADD         X0, #2
                STORED      D2, [XY0]
                BRA         .read_more

.read_mem_err:  POP         D0, XY3
                LEA         XY0, STR_MEMERR
                BRA         error_msg

.read_more:     CALL16        skip_spaces
                CALL16        peek_char
                CMP         D0, #$2C
                BNE         .read_done
                CALL16        get_char
                BRA         .read_loop
.read_done:     RET
.read_err:
                LEA         XY0, STR_SYNERR
                BRA         error_msg

CMD_RESTORE:
                LOADI       D0, #0
                STOREP      D0, Y3, [#ZP_DATALINE]
                STOREP      D0, Y3, [#ZP_DATAPOS]
                RET

; Get next integer DATA item -> D0
get_data_item:
                CALL16        find_data_pos
                LOADP       D0, Y3, [#ZP_DATAPOS]
                MOVE        X0, D0
                MOVE        Y0, Y3

                ; Skip spaces
.gdi_skip:      LOADB       D0, [XY0]
                CMP         D0, #$20
                BNE         .gdi_parse
                ADD         X0, #1
                BRA         .gdi_skip

.gdi_parse:     LOADI       D2, #0
                LOADI       D3, #0
                CMP         D0, #$2D
                BNE         .gdi_chex
                LOADI       D3, #1
                ADD         X0, #1
                LOADB       D0, [XY0]
.gdi_chex:      CMP         D0, #$24
                BEQ         .gdi_hex

.gdi_num:       LOADB       D0, [XY0]
                CMP         D0, #$30
                BCC         .gdi_done
                CMP         D0, #$3A
                BCS         .gdi_done
                MOVE        D1, D2
                SHL         D2
                SHL         D2
                ADD         D2, D1
                SHL         D2
                SUB         D0, #$30
                ADD         D2, D0
                ADD         X0, #1
                BRA         .gdi_num

.gdi_hex:       ADD         X0, #1
.gdi_hl:        LOADB       D0, [XY0]
                CMP         D0, #$30
                BCC         .gdi_done
                CMP         D0, #$3A
                BCC         .gdi_hd
                AND         D0, #$DF
                CMP         D0, #$41
                BCC         .gdi_done
                CMP         D0, #$47
                BCS         .gdi_done
                SUB         D0, #$37
                BRA         .gdi_ha
.gdi_hd:        SUB         D0, #$30
.gdi_ha:        SHL4        D2
                OR          D2, D0
                ADD         X0, #1
                BRA         .gdi_hl

.gdi_done:      CMP         D3, #0
                BEQ         .gdi_pos
                LOADI       D0, #0
                SUB         D0, D2
                MOVE        D2, D0
.gdi_pos:       LOADB       D0, [XY0]
                CMP         D0, #$2C
                BNE         .gdi_eod
                ADD         X0, #1
                MOVE        D0, X0
                STOREP      D0, Y3, [#ZP_DATAPOS]
                MOVE        D0, D2
                RET
.gdi_eod:       LOADI       D0, #0
                STOREP      D0, Y3, [#ZP_DATAPOS]
                CALL16        advance_dataline
                MOVE        D0, D2
                RET

; Get next string DATA item -> TMPLEN/TMPPTR
get_data_str:
                CALL16        find_data_pos
                LOADP       D0, Y3, [#ZP_DATAPOS]
                MOVE        X0, D0
                MOVE        Y0, Y3

.gds_skip:      LOADB       D0, [XY0]
                CMP         D0, #$20
                BNE         .gds_start
                ADD         X0, #1
                BRA         .gds_skip

.gds_start:     CMP         D0, #$22
                BEQ         .gds_quoted

                ; Unquoted
                LOADI       X1, #TMPSTR_BUF
                MOVE        Y1, Y3
                LOADI       D2, #0
.gds_copy:      LOADB       D0, [XY0]
                CMP         D0, #0
                BEQ         .gds_done
                CMP         D0, #$2C
                BEQ         .gds_done
                STOREB      D0, [XY1]
                ADD         X0, #1
                ADD         X1, #1
                ADD         D2, #1
                BRA         .gds_copy

.gds_quoted:    ADD         X0, #1
                LOADI       X1, #TMPSTR_BUF
                MOVE        Y1, Y3
                LOADI       D2, #0
.gds_qcopy:     LOADB       D0, [XY0]
                CMP         D0, #0
                BEQ         .gds_done
                CMP         D0, #$22
                BEQ         .gds_qend
                STOREB      D0, [XY1]
                ADD         X0, #1
                ADD         X1, #1
                ADD         D2, #1
                BRA         .gds_qcopy
.gds_qend:      ADD         X0, #1

.gds_done:      LOADI       D0, #TMPSTR_BUF
                STOREP      D0, Y3, [#ZP_TMPPTR]
                STOREP      D2, Y3, [#ZP_TMPLEN]

                LOADB       D0, [XY0]
                CMP         D0, #$2C
                BNE         .gds_eod
                ADD         X0, #1
                MOVE        D0, X0
                STOREP      D0, Y3, [#ZP_DATAPOS]
                RET
.gds_eod:       LOADI       D0, #0
                STOREP      D0, Y3, [#ZP_DATAPOS]
                CALL16        advance_dataline
                RET

; Advance DATALINE past current line
advance_dataline:
                LOADP       D0, Y3, [#ZP_DATALINE]
                MOVE        X0, D0
                MOVE        Y0, Y3
                ADD         X0, #2
.adl_sk:        LOADB       D0, [XY0]
                ADD         X0, #1
                CMP         D0, #0
                BNE         .adl_sk
                ADD         X0, #1
                AND         X0, #$FFFE
                MOVE        D0, X0
                STOREP      D0, Y3, [#ZP_DATALINE]
                RET

; Scan for next DATA statement
find_data_pos:
                LOADP       D0, Y3, [#ZP_DATAPOS]
                CMP         D0, #0
                BNE         .fdp_done
                LOADP       D0, Y3, [#ZP_DATALINE]
                ; Port: DATALINE is initialized to 0 as a "no scan in progress"
                ; sentinel by MAIN/CMD_RUN/CMD_NEW/CMD_RESTORE. In the original
                ; ROM build, 0 was also the page-$01 offset of the program text
                ; start, so this doubled as "start scan from program top". In
                ; the .COM port, program text lives at PROG_BASE within the
                ; task page. Upgrade the sentinel here so the original four
                ; init sites can stay as-is.
                CMP         D0, #0
                BNE         .fdp_have
                LOADI       D0, #PROG_BASE
.fdp_have:      MOVE        X0, D0
                MOVE        Y0, Y3

.fdp_scan:      LOADD       D0, [XY0]
                CMP         D0, #0
                BEQ         .fdp_ood
                MOVE        D1, X0
                ADD         X0, #2
.fdp_sp:        LOADB       D0, [XY0]
                CMP         D0, #$20
                BNE         .fdp_chk
                ADD         X0, #1
                BRA         .fdp_sp
.fdp_chk:       CMP         D0, #TOK_DATA        ; DATA token byte
                BNE         .fdp_next
                ADD         X0, #1               ; skip past token byte
                ; Found DATA
                STOREP      D1, Y3, [#ZP_DATALINE]
                MOVE        D0, X0
                STOREP      D0, Y3, [#ZP_DATAPOS]
.fdp_done:      RET

.fdp_next:      MOVE        X0, D1
                ADD         X0, #2
.fdp_sk:        LOADB       D0, [XY0]
                ADD         X0, #1
                CMP         D0, #0
                BNE         .fdp_sk
                ADD         X0, #1
                AND         X0, #$FFFE
                BRA         .fdp_scan

.fdp_ood:
                LEA         XY0, STR_DATERR
                BRA         error_msg

; ============================================================================
; FIND_LINE - Find program line by number
; Input: D0 = line number
; Output: D0 = offset into PROG_PAGE, or $FFFF if not found
; ============================================================================

find_line:
                MOVE        D1, D0
                LOADI       X0, #PROG_BASE
                MOVE        Y0, Y3
.fl_loop:       LOADD       D0, [XY0]
                CMP         D0, #0
                BEQ         .fl_nf
                CMP         D0, D1
                BEQ         .fl_found
                BCS         .fl_nf
                ADD         X0, #2
.fl_skip:       LOADB       D0, [XY0]
                ADD         X0, #1
                CMP         D0, #0
                BNE         .fl_skip
                ADD         X0, #1
                AND         X0, #$FFFE
                BRA         .fl_loop
.fl_found:      MOVE        D0, X0
                RET
.fl_nf:         LOADI       D0, #$FFFF
                RET

; ============================================================================
; ARRAY_ADDR - Get address of array element
; Input: D0 = var index (0-25), D2 = subscript
; Output: D0 = address in page $00
; ============================================================================

array_addr:
                PUSH        D2, XY3
                MOVE        D1, D0
                SHL         D1
                SHL         D1
                ADD         D1, #ZP_ARRAYS
                MOVE        X0, D1
                MOVE        Y0, Y3
                LOADD       D0, [XY0]           ; dimension
                CMP         D0, #0
                BEQ         .aa_undim
                ADD         X0, #2
                LOADD       D1, [XY0]           ; base
                POP         D2, XY3
                CMP         D2, D0
                BCS         .aa_range
                SHL         D2
                ADD         D2, D1
                MOVE        D0, D2
                RET
.aa_undim:      POP         D2, XY3
                LEA         XY0, STR_DIMERR
                BRA         error_msg
.aa_range:
                LEA         XY0, STR_SUBERR
                BRA         error_msg

; ============================================================================
; IS_STRING_EXPR - Check if next token is a string expression
; Returns D0=1 if string, D0=0 if not
; ============================================================================

is_string_expr:
                LOADP       D0, Y3, [#ZP_TXTPOS]
                MOVE        X0, D0
                CALL16        get_text_page

                ; String literal?
                LOADB       D0, [XY0]
                CMP         D0, #$22             ; '"'
                BEQ         .ise_yes

                ; String function token? ($AB-$B0)
                CMP         D0, #TOK_CHRS
                BCC         .ise_chkvar
                CMP         D0, #TOK_MIDS+1
                BCC         .ise_yes

.ise_chkvar:    ; Check for A$..Z$ variable pattern
                CMP         D0, #$61
                BCC         .ise_c1
                AND         D0, #$DF
.ise_c1:        CMP         D0, #$41
                BCC         .ise_no
                CMP         D0, #$5B
                BCS         .ise_no
                ADD         X0, #1
                LOADB       D0, [XY0]
                CMP         D0, #$24             ; '$'
                BEQ         .ise_yes

.ise_no:        LOADI       D0, #0
                RET
.ise_yes:       LOADI       D0, #1
                RET

; ============================================================================
; NUMERIC EXPRESSION EVALUATOR
; Recursive descent with precedence levels:
;   Level 0: OR
;   Level 1: AND
;   Level 2: Comparison (= <> < > <= >=)
;   Level 3: Addition (+, -)
;   Level 4: Multiplication (*, /, MOD)
;   Level 5: Unary (-, NOT)
;   Level 6: Atom (number, variable, function, array, parenthesized)
; ============================================================================

expr:           BRA         expr_l0

expr_l0:        ; OR
                CALL16        expr_l1
.l0_loop:       PUSH        D0, XY3             ; save left operand
                CALL16        skip_spaces
                CALL16        peek_char
                CMP         D0, #TOK_OR
                BNE         .l0_done
                CALL16        get_char             ; consume OR token
                CALL16        expr_l1
                POP         D1, XY3
                OR          D0, D1
                BRA         .l0_loop
.l0_done:       POP         D0, XY3
                RET

expr_l1:        ; AND / XOR
                CALL16        expr_l2
.l1_loop:       PUSH        D0, XY3             ; save left operand
                CALL16        skip_spaces
                CALL16        peek_char
                CMP         D0, #TOK_AND
                BEQ         .l1_and
                CMP         D0, #TOK_XOR
                BEQ         .l1_xor
                BRA         .l1_done
.l1_and:        CALL16        get_char             ; consume AND token
                CALL16        expr_l2
                POP         D1, XY3
                AND         D0, D1
                BRA         .l1_loop
.l1_xor:        CALL16        get_char             ; consume XOR token
                CALL16        expr_l2
                POP         D1, XY3
                XOR         D0, D1
                BRA         .l1_loop
.l1_done:       POP         D0, XY3
                RET

expr_l2:        ; Comparison - string or numeric
                ; Check if left side is a string expression
                CALL16        skip_spaces
                CALL16        is_string_expr
                CMP         D0, #1
                BEQ         .l2_strcmp

                ; Numeric comparison
                CALL16        expr_l3
.l2_loop:       PUSH        D0, XY3             ; save left operand
                CALL16        skip_spaces
                CALL16        peek_char
                CMP         D0, #$3D
                BEQ         .l2_eq
                CMP         D0, #$3C
                BEQ         .l2_lt
                CMP         D0, #$3E
                BEQ         .l2_gt
                CMP         D0, #TOK_LE
                BEQ         .l2_le
                CMP         D0, #TOK_GE
                BEQ         .l2_ge
                CMP         D0, #TOK_NE
                BEQ         .l2_ne
                POP         D0, XY3
                RET

.l2_eq:         CALL16        get_char
                CALL16        expr_l3
                POP         D1, XY3
                CMP         D1, D0
                SEQ         D0                  ; D0 = $FFFF if equal, else $0000
                BRA         .l2_loop

.l2_lt:         CALL16        get_char
                CALL16        expr_l3
                POP         D1, XY3
                CMP         D1, D0
                SLT         D0                  ; D0 = $FFFF if D1 < D0
                BRA         .l2_loop

.l2_ne:         CALL16        get_char
                CALL16        expr_l3
                POP         D1, XY3
                CMP         D1, D0
                SNE         D0                  ; D0 = $FFFF if not equal
                BRA         .l2_loop

.l2_le:         CALL16        get_char
                CALL16        expr_l3
                POP         D1, XY3
                CMP         D1, D0
                SLE         D0                  ; D0 = $FFFF if D1 <= D0
                BRA         .l2_loop

.l2_gt:         CALL16        get_char
                CALL16        expr_l3
                POP         D1, XY3
                CMP         D1, D0
                SGT         D0                  ; D0 = $FFFF if D1 > D0
                BRA         .l2_loop

.l2_ge:         CALL16        get_char
                CALL16        expr_l3
                POP         D1, XY3
                CMP         D1, D0
                SGE         D0                  ; D0 = $FFFF if D1 >= D0
                BRA         .l2_loop

; --- String comparison handler ---
; Evaluates: str_expr OP str_expr  where OP is =, <>, <, >, <=, >=
; Returns -1 (true) or 0 (false) as numeric

.l2_strcmp:
                CALL16        str_expr             ; left -> TMPLEN/TMPPTR
                ; Save left string to TMPSTR2_BUF
                LOADP       D2, Y3, [#ZP_TMPLEN]
                LOADP       D3, Y3, [#ZP_TMPPTR]
                PUSH        D2, XY3              ; save len1
                LOADI       X0, #TMPSTR2_BUF
                MOVE        Y0, Y3
                MOVE        X1, D3
                MOVE        Y1, Y3
                MOVE        D0, D2
                CALL16        memcpy
                ; Parse and encode operator as 0-5
                CALL16        skip_spaces
                CALL16        get_char
                CMP         D0, #$3D             ; '='
                BEQ         .l2sc_enc_eq
                CMP         D0, #$3C             ; '<'
                BEQ         .l2sc_enc_lt
                CMP         D0, #$3E             ; '>'
                BEQ         .l2sc_enc_gt
                CMP         D0, #TOK_NE
                BEQ         .l2sc_enc_ne
                CMP         D0, #TOK_LE
                BEQ         .l2sc_enc_le
                CMP         D0, #TOK_GE
                BEQ         .l2sc_enc_ge
                ; Shouldn't reach here - syntax error
                POP         D0, XY3
                LOADI       D0, #0
                BRA         .l2_loop

.l2sc_enc_eq:   LOADI       D0, #0               ; 0 = EQ
                BRA         .l2sc_go
.l2sc_enc_lt:   LOADI       D0, #2               ; 2 = LT (just '<')
                BRA         .l2sc_go
.l2sc_enc_ne:   LOADI       D0, #1               ; 1 = NE
                BRA         .l2sc_go
.l2sc_enc_le:   LOADI       D0, #4               ; 4 = LE
                BRA         .l2sc_go
.l2sc_enc_gt:   LOADI       D0, #3               ; 3 = GT (just '>')
                BRA         .l2sc_go
.l2sc_enc_ge:   LOADI       D0, #5               ; 5 = GE

.l2sc_go:       PUSH        D0, XY3              ; save op code

                ; Evaluate right string
                CALL16        skip_spaces
                CALL16        str_expr             ; right -> TMPLEN/TMPPTR

                ; Compare TMPSTR2_BUF(len1) vs TMPPTR(TMPLEN)
                ; str_compare: left=TMPSTR2_BUF, D2=len1, right=TMPPTR, D3=TMPLEN
                POP         D1, XY3              ; D1 = op code
                POP         D2, XY3              ; D2 = len1
                CALL16        str_compare          ; D0 = -1, 0, or 1

                ; Apply operator
                CMP         D1, #0               ; EQ
                BEQ         .l2sc_op_eq
                CMP         D1, #1               ; NE
                BEQ         .l2sc_op_ne
                CMP         D1, #2               ; LT
                BEQ         .l2sc_op_lt
                CMP         D1, #3               ; GT
                BEQ         .l2sc_op_gt
                CMP         D1, #4               ; LE
                BEQ         .l2sc_op_le
                                                 ; 5 = GE (fall through)
.l2sc_op_ge:    CMP         D0, #0
                SGE         D0
                BRA         .l2_loop
.l2sc_op_eq:    CMP         D0, #0
                SEQ         D0
                BRA         .l2_loop
.l2sc_op_ne:    CMP         D0, #0
                SNE         D0
                BRA         .l2_loop
.l2sc_op_lt:    CMP         D0, #0
                SLT         D0
                BRA         .l2_loop
.l2sc_op_gt:    CMP         D0, #0
                SGT         D0
                BRA         .l2_loop
.l2sc_op_le:    CMP         D0, #0
                SLE         D0
                BRA         .l2_loop

expr_l3:        ; Addition
                CALL16        expr_l4
.l3_loop:       PUSH        D0, XY3             ; save left operand
                CALL16        skip_spaces
                CALL16        peek_char
                CMP         D0, #$2B
                BEQ         .l3_add
                CMP         D0, #$2D
                BEQ         .l3_sub
                POP         D0, XY3
                RET

.l3_add:        CALL16        get_char
                CALL16        expr_l4
                POP         D1, XY3
                ADD         D0, D1
                BRA         .l3_loop
.l3_sub:        CALL16        get_char
                CALL16        expr_l4
                MOVE        D1, D0
                POP         D0, XY3
                SUB         D0, D1
                BRA         .l3_loop

expr_l4:        ; Multiplication, Division, MOD
                CALL16        expr_l5
.l4_loop:       PUSH        D0, XY3             ; save left operand
                CALL16        skip_spaces
                CALL16        peek_char
                CMP         D0, #$2A
                BEQ         .l4_mul
                CMP         D0, #$2F
                BEQ         .l4_div
                CMP         D0, #TOK_MOD
                BEQ         .l4_mod
                POP         D0, XY3
                RET

.l4_mul:        CALL16        get_char
                CALL16        expr_l5
                POP         D1, XY3
                CALL16        mul_16x16
                BRA         .l4_loop

.l4_div:        CALL16        get_char
                CALL16        expr_l5
                MOVE        D1, D0
                POP         D0, XY3
                CMP         D1, #0
                BEQ         .l4_div0
                CALL16        divide_16
                BRA         .l4_loop

.l4_mod:        CALL16        get_char             ; consume MOD token
                CALL16        expr_l5
                MOVE        D1, D0
                POP         D0, XY3
                CMP         D1, #0
                BEQ         .l4_div0
                CALL16        umod_16
                BRA         .l4_loop

.l4_div0:
                LEA         XY0, STR_DIVERR
                BRA         error_msg

expr_l5:        ; Unary
                CALL16        skip_spaces
                CALL16        peek_char
                CMP         D0, #$2D
                BEQ         .l5_neg
                CMP         D0, #TOK_NOT
                BEQ         .l5_not
                BRA         expr_l6

.l5_neg:        CALL16        get_char
                CALL16        expr_l6
                LOADI       D1, #0
                SUB         D1, D0
                MOVE        D0, D1
                RET

.l5_not:        CALL16        get_char             ; consume NOT token
                CALL16        expr_l6
                NOT         D0
                RET

expr_l6:        ; Atom
                CALL16        skip_spaces
                CALL16        peek_char

                ; Parenthesized
                CMP         D0, #$28
                BEQ         .l6_paren

                ; Hex literal
                CMP         D0, #$24
                BEQ         .l6_hex

                ; Decimal number
                CMP         D0, #$30
                BCC         .l6_nonum
                CMP         D0, #$3A
                BCC         .l6_decimal

.l6_nonum:      ; Function token, variable, or array

                ; Check for function tokens ($A3-$B0)
                CMP         D0, #TOK_ABS
                BCC         .l6_not_fn
                CMP         D0, #TOK_VAL+1
                BCC         .l6_fn_dispatch

.l6_not_fn:     ; Variable or array (A-Z, a-z)
                CMP         D0, #$61
                BCC         .l6_uc
                AND         D0, #$DF
.l6_uc:         CMP         D0, #$41
                BCC         .l6_syntax
                CMP         D0, #$5B
                BCS         .l6_syntax

                ; Variable or array
                CALL16        get_char
                AND         D0, #$DF
                SUB         D0, #$41

                ; Check for array access
                PUSH        D0, XY3
                CALL16        peek_char
                CMP         D0, #$28
                BEQ         .l6_array
                POP         D0, XY3
                SHL         D0
                ADD         D0, #ZP_VARS
                MOVE        X0, D0
                MOVE        Y0, Y3
                LOADD       D0, [XY0]
                RET

.l6_array:      CALL16        get_char             ; consume '('
                LOADD       D0, [XY3]             ; var index
                CALL16        expr                 ; subscript
                MOVE        D2, D0
                CALL16        skip_spaces
                CALL16        get_char             ; consume ')'
                POP         D0, XY3
                CALL16        array_addr
                MOVE        X0, D0
                MOVE        Y0, Y3
                LOADD       D0, [XY0]
                RET

.l6_paren:      CALL16        get_char
                CALL16        expr
                PUSH        D0, XY3
                CALL16        skip_spaces
                CALL16        get_char
                POP         D0, XY3
                RET

.l6_decimal:    CALL16        get_char
                SUB         D0, #$30
                MOVE        D2, D0
.l6_dloop:      CALL16        peek_char
                CMP         D0, #$30
                BCC         .l6_ddone
                CMP         D0, #$3A
                BCS         .l6_ddone
                CALL16        get_char
                SUB         D0, #$30
                MOVE        D1, D2
                SHL         D2
                SHL         D2
                ADD         D2, D1
                SHL         D2
                ADD         D2, D0
                BRA         .l6_dloop
.l6_ddone:      MOVE        D0, D2
                RET

.l6_hex:        CALL16        get_char
                LOADI       D2, #0
.l6_hloop:      CALL16        peek_char
                CMP         D0, #$30
                BCC         .l6_hdone
                CMP         D0, #$3A
                BCC         .l6_hdigit
                AND         D0, #$DF
                CMP         D0, #$41
                BCC         .l6_hdone
                CMP         D0, #$47
                BCS         .l6_hdone
                CALL16        get_char
                AND         D0, #$DF
                SUB         D0, #$37
                BRA         .l6_haccum
.l6_hdigit:     CALL16        get_char
                SUB         D0, #$30
.l6_haccum:     SHL4        D2
                OR          D2, D0
                BRA         .l6_hloop
.l6_hdone:      MOVE        D0, D2
                RET

.l6_syntax:
                LEA         XY0, STR_SYNERR
                BRA         error_msg


; --- Function token dispatch ---
.l6_fn_dispatch:
                CALL16        get_char             ; consume function token
                CMP         D0, #TOK_ABS
                BEQ         .l6_abs
                CMP         D0, #TOK_ASC
                BEQ         .l6_asc
                CMP         D0, #TOK_RND
                BEQ         .l6_rnd
                CMP         D0, #TOK_SGN
                BEQ         .l6_sgn
                CMP         D0, #TOK_PEEK
                BEQ         .l6_peek
                CMP         D0, #TOK_DEEK
                BEQ         .l6_deek
                CMP         D0, #TOK_LEN
                BEQ         .l6_len
                CMP         D0, #TOK_VAL
                BEQ         .l6_val
                BRA         .l6_syntax           ; unknown function token

.l6_abs:        CALL16        .l6_fn_paren
                CMP         D0, #0
                BGE         .l6_abs_pos
                LOADI       D1, #0
                SUB         D1, D0
                MOVE        D0, D1
.l6_abs_pos:    RET

.l6_asc:        CALL16        skip_spaces
                CALL16        get_char             ; '('
                CALL16        str_expr
                CALL16        skip_spaces
                CALL16        get_char             ; ')'
                LOADP       D0, Y3, [#ZP_TMPLEN]
                CMP         D0, #0
                BEQ         .l6_asc_zero
                LOADP       D0, Y3, [#ZP_TMPPTR]
                MOVE        X0, D0
                MOVE        Y0, Y3
                LOADB       D0, [XY0]
                RET
.l6_asc_zero:   LOADI       D0, #0
                RET

.l6_rnd:        CALL16        .l6_fn_paren        ; D0 = argument n
                PUSH        D0, XY3             ; save n
                CALL24      KLIB_RAND16         ; D0 = pseudo-random (never 0)
                POP         D1, XY3             ; D1 = n
                CMP         D1, #0
                BEQ         .l6_rnd_done
                ; D0 = RAND, D1 = n. Want unsigned (RAND mod n) — clamp to
                ; positive via masking, then UDIVMOD.
                AND         D0, #$7FFF
                CALL24      KLIB_UDIVMOD16      ; D0=quot, D1=rem; SEC on /0
                BCS         .l6_rnd_zero        ; (shouldn't happen — n != 0 checked)
                MOVE        D0, D1              ; result = rem
.l6_rnd_done:   RET
.l6_rnd_zero:   LOADI       D0, #0
                RET

.l6_sgn:        CALL16        .l6_fn_paren
                CMP         D0, #0
                BEQ         .l6_sgn_z
                BGT         .l6_sgn_p
                LOADI       D0, #$FFFF
                RET
.l6_sgn_z:      LOADI       D0, #0
                RET
.l6_sgn_p:      LOADI       D0, #1
                RET

.l6_peek:       CALL16        .l6_fn_paren
                MOVE        X0, D0
                MOVE        Y0, Y3
                LOADB       D0, [XY0]
                RET

.l6_deek:       CALL16        .l6_fn_paren
                MOVE        X0, D0
                MOVE        Y0, Y3
                LOADD       D0, [XY0]
                RET

.l6_len:        CALL16        skip_spaces
                CALL16        get_char             ; '('
                CALL16        str_expr
                CALL16        skip_spaces
                CALL16        get_char             ; ')'
                LOADP       D0, Y3, [#ZP_TMPLEN]
                RET

.l6_val:        CALL16        skip_spaces
                CALL16        get_char             ; '('
                CALL16        str_expr
                CALL16        skip_spaces
                CALL16        get_char             ; ')'
                LOADP       D0, Y3, [#ZP_TMPPTR]
                MOVE        X0, D0
                MOVE        Y0, Y3
                CALL16        parse_input_number
                RET
.l6_var_fallback:
                CALL16        get_char
                AND         D0, #$DF
                SUB         D0, #$41
                SHL         D0
                ADD         D0, #ZP_VARS
                MOVE        X0, D0
                MOVE        Y0, Y3
                LOADD       D0, [XY0]
                RET

; Helper: parse expression in parens - consumes '(' expr ')'
.l6_fn_paren:   CALL16        skip_spaces
                CALL16        get_char             ; consume '('
                CALL16        expr
                PUSH        D0, XY3
                CALL16        skip_spaces
                CALL16        get_char             ; consume ')'
                POP         D0, XY3
                RET

; ============================================================================
; STRING EXPRESSION EVALUATOR
; Result returned in ZP_TMPLEN / ZP_TMPPTR (page $00)
; Supports: A$, string literals, CHR$, STR$, HEX$, LEFT$, RIGHT$, MID$
; String concatenation via +
; ============================================================================

str_expr:
                CALL16        skip_spaces
                CALL16        str_atom

                ; Check for concatenation
.se_loop:       CALL16        skip_spaces
                CALL16        peek_char
                CMP         D0, #$2B
                BNE         .se_done

                ; Save str1 to TMPSTR2_BUF so str_atom can safely use TMPSTR_BUF
                LOADP       D2, Y3, [#ZP_TMPLEN]
                LOADP       D3, Y3, [#ZP_TMPPTR]
                LOADI       X0, #TMPSTR2_BUF
                MOVE        Y0, Y3
                MOVE        X1, D3
                MOVE        Y1, Y3
                MOVE        D0, D2
                CALL16        memcpy
                PUSH        D2, XY3             ; len1

                CALL16        get_char             ; consume '+'
                CALL16        skip_spaces
                CALL16        str_atom             ; str2 -> TMPLEN/TMPPTR (may use TMPSTR_BUF)

                ; Concatenate: TMPSTR2_BUF(str1) + TMPPTR(str2) -> TMPSTR_BUF
                POP         D2, XY3             ; len1
                LOADP       D3, Y3, [#ZP_TMPLEN] ; len2

                ; Port fix: stage str2 into TMPSTR2_BUF[D2..] (just past str1)
                ; FIRST, before touching TMPSTR_BUF. This prevents the aliasing
                ; bug where str2 is a literal whose TMPPTR points into
                ; TMPSTR_BUF — the subsequent str1 copy would otherwise
                ; clobber the literal source bytes before they were read.
                ; TMPSTR2_BUF is 256 bytes; the BASIC tokeniser caps line
                ; length at 250, so str1+str2 always fits.
                LOADI       X0, #TMPSTR2_BUF
                ADD         X0, D2              ; X0 = TMPSTR2_BUF + len1
                MOVE        Y0, Y3
                LOADP       D0, Y3, [#ZP_TMPPTR]
                MOVE        X1, D0              ; X1 = source (may be TMPSTR_BUF)
                MOVE        Y1, Y3
                MOVE        D0, D3              ; len2
                PUSH        D2, XY3
                PUSH        D3, XY3
                CALL16      memcpy
                POP         D3, XY3
                POP         D2, XY3

                ; Now both operands live in TMPSTR2_BUF:
                ;   TMPSTR2_BUF[0..len1-1]       = str1
                ;   TMPSTR2_BUF[len1..len1+len2-1] = str2
                ; Copy the whole thing to TMPSTR_BUF in one shot.
                LOADI       X0, #TMPSTR_BUF
                MOVE        Y0, Y3
                LOADI       X1, #TMPSTR2_BUF
                MOVE        Y1, Y3
                MOVE        D0, D2
                ADD         D0, D3              ; total length
                PUSH        D2, XY3
                PUSH        D3, XY3
                CALL16      memcpy
                POP         D3, XY3
                POP         D2, XY3

                ADD         D2, D3
                LOADI       D0, #TMPSTR_BUF
                STOREP      D0, Y3, [#ZP_TMPPTR]
                STOREP      D2, Y3, [#ZP_TMPLEN]
                BRA         .se_loop

.se_done:       RET

str_atom:
                CALL16        skip_spaces
                CALL16        peek_char

                ; String literal
                CMP         D0, #$22
                BEQ         .sa_literal

                ; String function tokens ($AB-$B0)
                CMP         D0, #TOK_CHRS
                BEQ         .sa_chr
                CMP         D0, #TOK_STRS
                BEQ         .sa_str
                CMP         D0, #TOK_HEXS
                BEQ         .sa_hex
                CMP         D0, #TOK_LEFTS
                BEQ         .sa_left
                CMP         D0, #TOK_RIGHTS
                BEQ         .sa_right
                CMP         D0, #TOK_MIDS
                BEQ         .sa_mid

                ; Variable A$ (letter followed by $)
                AND         D0, #$DF
                CMP         D0, #$41
                BCC         .sa_err
                CMP         D0, #$5B
                BCS         .sa_err
                CALL16        get_char
                AND         D0, #$DF
                SUB         D0, #$41
                PUSH        D0, XY3
                CALL16        get_char             ; consume '$'
                POP         D0, XY3
                SHL         D0
                SHL         D0
                ADD         D0, #ZP_STRVARS
                MOVE        X0, D0
                MOVE        Y0, Y3
                LOADD       D1, [XY0]           ; length
                ADD         X0, #2
                LOADD       D2, [XY0]           ; pointer
                STOREP      D1, Y3, [#ZP_TMPLEN]
                STOREP      D2, Y3, [#ZP_TMPPTR]
                RET

.sa_literal:    CALL16        get_char             ; consume '"'
                LOADP       D0, Y3, [#ZP_TXTPOS]
                MOVE        X0, D0
                CALL16        get_text_page

                LOADI       X1, #TMPSTR_BUF
                MOVE        Y1, Y3
                LOADI       D2, #0

.sa_lit_loop:   LOADB       D0, [XY0]
                CMP         D0, #0
                BEQ         .sa_lit_done
                CMP         D0, #$22
                BEQ         .sa_lit_end
                STOREB      D0, [XY1]
                ADD         X0, #1
                ADD         X1, #1
                ADD         D2, #1
                BRA         .sa_lit_loop

.sa_lit_end:    ADD         X0, #1
.sa_lit_done:   MOVE        D0, X0
                STOREP      D0, Y3, [#ZP_TXTPOS]
                LOADI       D0, #TMPSTR_BUF
                STOREP      D0, Y3, [#ZP_TMPPTR]
                STOREP      D2, Y3, [#ZP_TMPLEN]
                RET

.sa_err:        LEA         XY0, STR_TYPERR
                BRA         error_msg

; --- CHR$(n) ---
.sa_chr:        CALL16        get_char             ; consume CHR$ token
                CALL16        skip_spaces
                CALL16        get_char             ; '('
                CALL16        expr
                PUSH        D0, XY3
                CALL16        skip_spaces
                CALL16        get_char             ; ')'
                POP         D0, XY3

                LOADI       X0, #TMPSTR_BUF
                MOVE        Y0, Y3
                STOREB      D0, [XY0]
                LOADI       D0, #TMPSTR_BUF
                STOREP      D0, Y3, [#ZP_TMPPTR]
                LOADI       D0, #1
                STOREP      D0, Y3, [#ZP_TMPLEN]
                RET

; --- STR$(n) ---
.sa_str:        CALL16        get_char             ; consume STR$ token
                CALL16        skip_spaces
                CALL16        get_char             ; '('
                CALL16        expr
                PUSH        D0, XY3
                CALL16        skip_spaces
                CALL16        get_char             ; ')'
                POP         D0, XY3
                CALL16        int_to_str
                RET

; --- HEX$(n) ---
.sa_hex:        CALL16        get_char             ; consume HEX$ token
                CALL16        skip_spaces
                CALL16        get_char             ; '('
                CALL16        expr
                PUSH        D0, XY3
                CALL16        skip_spaces
                CALL16        get_char             ; ')'
                POP         D0, XY3
                CALL16        int_to_hex
                RET

; --- LEFT$(s$, n) ---
.sa_left:       CALL16        get_char             ; consume LEFT$ token
                CALL16        skip_spaces
                CALL16        get_char             ; '('
                CALL16        str_expr
                CALL16        skip_spaces
                CALL16        get_char             ; ','
                CALL16        expr                 ; n
                PUSH        D0, XY3
                CALL16        skip_spaces
                CALL16        get_char             ; ')'
                POP         D0, XY3

                LOADP       D1, Y3, [#ZP_TMPLEN]
                CMP         D0, D1
                BCC         .left_trunc
                RETCS                            ; already <= n
.left_trunc:    STOREP      D0, Y3, [#ZP_TMPLEN]
                RET

; --- RIGHT$(s$, n) ---
.sa_right:      CALL16        get_char             ; consume RIGHT$ token
                CALL16        skip_spaces
                CALL16        get_char             ; '('
                CALL16        str_expr
                CALL16        skip_spaces
                CALL16        get_char             ; ','
                CALL16        expr                 ; n
                PUSH        D0, XY3
                CALL16        skip_spaces
                CALL16        get_char             ; ')'
                POP         D0, XY3

                LOADP       D1, Y3, [#ZP_TMPLEN]
                CMP         D0, D1
                BCS         .right_all
                MOVE        D2, D1
                SUB         D2, D0
                LOADP       D1, Y3, [#ZP_TMPPTR]
                ADD         D1, D2
                STOREP      D1, Y3, [#ZP_TMPPTR]
                STOREP      D0, Y3, [#ZP_TMPLEN]
.right_all:     RET

; --- MID$(s$, start [, len]) ---
.sa_mid:        CALL16        get_char             ; consume MID$ token
                CALL16        skip_spaces
                CALL16        get_char             ; '('
                CALL16        str_expr
                CALL16        skip_spaces
                CALL16        get_char             ; ','
                CALL16        expr                 ; start (1-based)
                SUB         D0, #1
                PUSH        D0, XY3             ; 0-based start

                ; Check for optional length
                CALL16        skip_spaces
                CALL16        peek_char
                CMP         D0, #$2C
                BEQ         .mid_haslen

                ; No length - take from start to end
                CALL16        get_char             ; ')'
                POP         D0, XY3             ; start
                LOADP       D1, Y3, [#ZP_TMPLEN]
                CMP         D0, D1
                BCS         .mid_empty
                SUB         D1, D0
                LOADP       D2, Y3, [#ZP_TMPPTR]
                ADD         D2, D0
                STOREP      D2, Y3, [#ZP_TMPPTR]
                STOREP      D1, Y3, [#ZP_TMPLEN]
                RET

.mid_haslen:    CALL16        get_char             ; ','
                CALL16        expr                 ; length
                PUSH        D0, XY3
                CALL16        skip_spaces
                CALL16        get_char             ; ')'
                POP         D0, XY3             ; length
                POP         D1, XY3             ; start

                LOADP       D2, Y3, [#ZP_TMPLEN]
                CMP         D1, D2
                BCS         .mid_empty
                SUB         D2, D1
                CMP         D0, D2
                BCC         .mid_ok
                MOVE        D0, D2
.mid_ok:        LOADP       D2, Y3, [#ZP_TMPPTR]
                ADD         D2, D1
                STOREP      D2, Y3, [#ZP_TMPPTR]
                STOREP      D0, Y3, [#ZP_TMPLEN]
                RET

.mid_empty:     LOADI       D0, #0
                STOREP      D0, Y3, [#ZP_TMPLEN]
                RET

; ============================================================================
; INT_TO_STR - Convert signed D0 to string in TMPSTR_BUF
; Sets ZP_TMPLEN, ZP_TMPPTR.
; Port: wrapper around KLIB_ITOA.
; ============================================================================

int_to_str:
                LOADI       X0, #TMPSTR_BUF
                MOVE        Y0, Y3
                CALL24      KLIB_ITOA           ; writes digits + nul, advances XY0,
                                                ; returns D0 = digit count
                STOREP      D0, Y3, [#ZP_TMPLEN]
                LOADI       D0, #TMPSTR_BUF
                STOREP      D0, Y3, [#ZP_TMPPTR]
                RET

; ============================================================================
; INT_TO_HEX - Convert D0 to 4-digit hex string in TMPSTR_BUF
; Sets ZP_TMPLEN, ZP_TMPPTR.
; Port: wrapper around KLIB_ITOH.
; ============================================================================

int_to_hex:
                LOADI       X0, #TMPSTR_BUF
                MOVE        Y0, Y3
                CALL24      KLIB_ITOH           ; always 4 digits + nul; D0=4
                STOREP      D0, Y3, [#ZP_TMPLEN]
                LOADI       D0, #TMPSTR_BUF
                STOREP      D0, Y3, [#ZP_TMPPTR]
                RET

; ============================================================================
; MEMCPY - Copy D0 bytes from XY1 to XY0 (pages pre-set by caller)
; Port: wrapper around KLIB_MEMCPY (identical ABI).
; ============================================================================

memcpy:
                CALL24      KLIB_MEMCPY
                RET

; ============================================================================
; STR_POOL_ALLOC - Allocate D0 bytes in string pool with GC retry
; Input:  D0 = bytes needed
; Output: D2 = pointer to allocated space
;         D0 = 0 success, D0 = -1 ($FFFF) out of memory
; Clobbers D1
; ============================================================================

str_pool_alloc:
                LOADP       D2, Y3, [#ZP_STRPOOL]
                SUB         D2, D0
                LOADP       D1, Y3, [#ZP_ARRTOP]
                CMP         D2, D1
                BCS         .spa_ok
                ; GC and retry
                PUSH        D0, XY3
                CALL16        str_gc
                POP         D0, XY3
                LOADP       D2, Y3, [#ZP_STRPOOL]
                SUB         D2, D0
                LOADP       D1, Y3, [#ZP_ARRTOP]
                CMP         D2, D1
                BCC         .spa_fail
.spa_ok:        STOREP      D2, Y3, [#ZP_STRPOOL]
                LOADI       D0, #0
                RET
.spa_fail:      LOADI       D0, #$FFFF
                RET

; ============================================================================
; STR_COMPARE - Lexicographic string comparison
; Left:  TMPSTR2_BUF, length in D2
; Right: ZP_TMPPTR, length in ZP_TMPLEN
; Returns D0: -1 if left<right, 0 if equal, 1 if left>right
; ============================================================================

str_compare:
                LOADP       D3, Y3, [#ZP_TMPLEN] ; len2
                LOADI       X0, #TMPSTR2_BUF
                MOVE        Y0, Y3
                LOADP       D0, Y3, [#ZP_TMPPTR]
                MOVE        X1, D0
                MOVE        Y1, Y3

                ; Compare min(len1, len2) bytes
                MOVE        D0, D2
                CMP         D3, D0
                BCS         .scmp_loop
                MOVE        D0, D3               ; D0 = min length
.scmp_loop:     CMP         D0, #0
                BEQ         .scmp_lenck
                PUSH        D0, XY3
                LOADB       D0, [XY0]
                LOADB       D1, [XY1]
                CMP         D0, D1
                BNE         .scmp_diff
                POP         D0, XY3
                ADD         X0, #1
                ADD         X1, #1
                SUB         D0, #1
                BRA         .scmp_loop

.scmp_diff:     POP         D1, XY3              ; discard counter
                BCC         .scmp_lt             ; unsigned: left byte < right byte
                BRA         .scmp_gt

.scmp_lenck:    ; All compared bytes equal, compare lengths
                CMP         D2, D3
                BEQ         .scmp_eq
                BCC         .scmp_lt             ; len1 < len2 (unsigned)

.scmp_gt:       LOADI       D0, #1
                RET
.scmp_lt:       LOADI       D0, #$FFFF
                RET
.scmp_eq:       LOADI       D0, #0
                RET

; ============================================================================
; STR_GC - String pool garbage collection (compaction)
; Walks all 26 string variables and compacts live strings to top of pool.
; Call when allocation fails; retry allocation after return.
; Clobbers D0-D3, XY0, XY1
; ============================================================================

str_gc:
                ; Reset pool to top
                LOADI       D0, #STRPOOL_TOP
                STOREP      D0, Y3, [#ZP_STRPOOL]

                ; Walk A$..Z$ (26 descriptors, 4 bytes each at ZP_STRVARS)
                LOADI       D3, #0               ; var index 0..25

.sgc_loop:      CMP         D3, #26
                BCS         .sgc_done

                ; Descriptor address: ZP_STRVARS + index*4
                MOVE        D0, D3
                SHL         D0
                SHL         D0
                ADD         D0, #ZP_STRVARS
                PUSH        D0, XY3              ; [stack: desc_addr]
                MOVE        X0, D0
                MOVE        Y0, Y3

                ; Read length
                LOADD       D1, [XY0]           ; D1 = length
                CMP         D1, #0
                BEQ         .sgc_skip            ; empty string, skip

                ; Read old pointer
                ADD         X0, #2
                LOADD       D2, [XY0]           ; D2 = old pointer

                ; Allocate: new_ptr = STRPOOL - length
                LOADP       D0, Y3, [#ZP_STRPOOL]
                SUB         D0, D1               ; D0 = new_ptr
                STOREP      D0, Y3, [#ZP_STRPOOL]

                ; Same position? Skip copy
                CMP         D0, D2
                BEQ         .sgc_update

                ; Copy D1 bytes, direction-aware for overlap safety
                PUSH        D3, XY3              ; save var index
                PUSH        D1, XY3              ; save length
                CMP         D0, D2
                BCS         .sgc_cpbk            ; new > old: copy backward

                ; Forward copy (new < old): safe low-to-high
                MOVE        X0, D0
                MOVE        Y0, Y3
                MOVE        X1, D2
                MOVE        Y1, Y3
                MOVE        D3, D1
.sgc_cpf:       LOADB       D0, [XY1]
                STOREB      D0, [XY0]
                ADD         X0, #1
                ADD         X1, #1
                SUB         D3, #1
                BNE         .sgc_cpf
                BRA         .sgc_cpdn

                ; Backward copy (new > old): safe high-to-low
.sgc_cpbk:      ADD         D0, D1
                SUB         D0, #1
                MOVE        X0, D0               ; dest end
                MOVE        Y0, Y3
                MOVE        D0, D2
                ADD         D0, D1
                SUB         D0, #1
                MOVE        X1, D0               ; src end
                MOVE        Y1, Y3
                MOVE        D3, D1
.sgc_cpb:       LOADB       D0, [XY1]
                STOREB      D0, [XY0]
                SUB         X0, #1
                SUB         X1, #1
                SUB         D3, #1
                BNE         .sgc_cpb

.sgc_cpdn:      POP         D1, XY3              ; restore length
                POP         D3, XY3              ; restore var index

                ; Update descriptor pointer
.sgc_update:    POP         D0, XY3              ; desc addr
                ADD         D0, #2
                MOVE        X0, D0
                MOVE        Y0, Y3
                LOADP       D0, Y3, [#ZP_STRPOOL]
                STORED      D0, [XY0]           ; new pointer
                ADD         D3, #1
                BRA         .sgc_loop

.sgc_skip:      POP         D0, XY3              ; discard desc addr
                ADD         D3, #1
                BRA         .sgc_loop

.sgc_done:      RETCS

; ============================================================================
; MATH HELPERS — KLIB-based for .COM port
; ============================================================================
; All math now defers to the KLIB jump table at $00:$A000. The wrappers
; preserve the original BASIC entry-point names and input/output ABIs so
; callers don't change. KLIB owns the algorithms; KLIB is shared with kosh
; and any future user program.
;
; KLIB note: KLIB_MUL16x16_32 and KLIB_DIV10 clobber D2 and D3. KLIB_DIVMOD16
; preserves D2/D3 per the v1.2 ABI.

; mul_16x16: D0 = D0 * D1 (low 16 bits of product).
; ABI: clobbers D1, D2, D3 (same as original).
mul_16x16:
                CALL24      KLIB_MUL16x16_32    ; D0=lo16, D1=hi16; discard hi
                RET

; mul_16x16_32: D0:D1 = D0 * D1 as 32 bits (D0=lo16, D1=hi16).
; ABI: clobbers D2, D3 (same as original).
mul_16x16_32:
                CALL24      KLIB_MUL16x16_32
                RET

; divide_16: signed D0 = D0 / D1.
; Original silently discarded the remainder. Uses KLIB_DIVMOD16 which sets
; C=1 + D0=ERR_INVALID on divisor=0. Callers in expr_l5 already pre-check;
; we still BCS the error path for any other caller.
divide_16:
                CALL24      KLIB_DIVMOD16       ; D0=quot, D1=rem; SEC on /0
                BCS         .dv_zero
                RETCC
.dv_zero:
                LEA         XY0, STR_DIVERR
                BRA         error_msg

; umod_16: unsigned-style D0 = D0 MOD D1 (in original — actually used signed
; divide_16 internally then computed N - (Q*D), which happens to give the
; signed-truncated-division remainder. KLIB_DIVMOD16's D1 result is exactly
; that remainder with the same sign convention. Direct.)
umod_16:
                CALL24      KLIB_DIVMOD16       ; D0=quot, D1=rem; SEC on /0
                BCS         .um_zero
                MOVE        D0, D1              ; original returns remainder in D0
                RETCC
.um_zero:
                LEA         XY0, STR_DIVERR
                BRA         error_msg

; div10: D0 = D0 / 10 (unsigned). D0=quotient, D1=remainder (0..9).
; Identical ABI to KLIB_DIV10 (magic-multiply reciprocal).
div10:
                CALL24      KLIB_DIV10
                RET


; ============================================================================
; I/O HELPERS — TRAP-based for .COM port
; ============================================================================

; emit_char: D0 (low byte) -> terminal.
; Same ABI as before (no other registers touched in caller code).
emit_char:
                TRAP        #TRAP_PUTCHAR
                RET

print_newline:
                PUSH        D0, XY3
                LOADI       D0, #$0A
                TRAP        #TRAP_PUTCHAR
                POP         D0, XY3
                RET

; print_string: write nul-terminated string at XY0. Preserves nothing
; in particular (callers don't depend on XY0 across the call).
print_string:
                LOADB       D0, [XY0]
                CMP         D0, #0
                BEQ         .ps_done
                PUSH        XY0, XY3
                TRAP        #TRAP_PUTCHAR
                POP         XY0, XY3
                ADD         X0, #1
                BRA         print_string
.ps_done:       RET

; print_signed: print signed D0 in decimal.
print_signed:
                CMP         D0, #0
                BGE         print_unsigned
                PUSH        D0, XY3
                LOADI       D0, #$2D
                TRAP        #TRAP_PUTCHAR
                POP         D0, XY3
                LOADI       D1, #0
                SUB         D1, D0
                MOVE        D0, D1
                ; fall through

; print_unsigned: print unsigned D0 in decimal.
; Recursive divide-by-10. Uses KLIB_DIV10 (faster than BASIC's hand-rolled
; div10 was: ~80 cycles via magic-multiply reciprocal).
print_unsigned:
                CMP         D0, #10
                BCC         .pu_single
                CALL24      KLIB_DIV10           ; D0=quotient, D1=remainder (0..9)
                PUSH        D1, XY3              ; save remainder digit
                CALL16        print_unsigned       ; recurse with quotient
                POP         D0, XY3              ; get remainder
.pu_single:     ADD         D0, #$30
                TRAP        #TRAP_PUTCHAR
                RET

; ============================================================================
; PORT: SAVE / LOAD / DIR / DRIVE
; ============================================================================
;
; Filename handling:
;   - All four commands share parse_filename_arg, which collects a quoted
;     string literal from the BASIC source text into FILENAME_BUF, then
;     normalises:
;       * If no ':' in the user's name → prepend "<ZP_DRIVE>:".
;       * If no '.' after the drive prefix → append ".BAS".
;     Resulting buffer is nul-terminated and ready for sys_open.
;
;   - Drive specs (DIR B:, DRIVE B:) are NOT filenames — they're parsed
;     as a single letter followed by ':', no quotes.
;
; FS I/O via TRAPs (kos_defs.inc):
;   TRAP_OPEN(flags=D0, path=XY0) → fd in D0, C=1 on error
;   TRAP_READ(fd=D0, count=D1, buf=XY0) → bytes in D0, C=1 on error
;   TRAP_WRITE(fd=D0, count=D1, buf=XY0) → bytes in D0, C=1 on error
;   TRAP_CLOSE(fd=D0)
;   TRAP_DIRENT(drive=D0, index=D1, buf=XY0) → C=1 when no more entries
;
; FOPEN_READ = $1, OPEN_FLAGS_NEW = WRITE|CREATE|TRUNC (kosh.asm convention).
; ============================================================================

; --- Local FOPEN flag aliases (we don't include kosh.asm; rebuild here) ----
; kos_defs.inc doesn't export the FOPEN_* constants — they live in an FS
; include we don't pull in. Values mirror kosh's OPEN_FLAGS_NEW = $E.
FOPEN_READ      .EQU    $1
FOPEN_WRITE     .EQU    $2
FOPEN_CREATE    .EQU    $4
FOPEN_TRUNC     .EQU    $8
SAVE_OPEN_FLAGS .EQU    FOPEN_CREATE+FOPEN_WRITE+FOPEN_TRUNC    ; = $E

; ----------------------------------------------------------------------------
; parse_filename_arg — collect quoted string from BASIC source, normalise.
;
;   In:    ZP_TXTPOS points at current parse position in TIB.
;   Out:   FILENAME_BUF holds nul-terminated normalised path
;          (e.g. user typed  "HELLO"  → "B:HELLO.BAS")
;          C=0 on success, C=1 on error (D0 = err msg pointer-low for STR_*)
;   Uses:  D0, D1, D2, D3, XY0, XY1
;
; Walks the source byte-by-byte (we are after tokenisation, but string
; literals are not tokenised — see str_atom for the precedent). Accepts
; either '"' delimiters or a bare identifier (next whitespace/EOL ends it).
; ----------------------------------------------------------------------------
parse_filename_arg:
                CALL16        skip_spaces

                ; XY0 = TIB cursor.
                LOADP       D0, Y3, [#ZP_TXTPOS]
                MOVE        X0, D0
                MOVE        Y0, Y3

                ; XY1 = FILENAME_BUF write cursor.
                LOADI       X1, #FILENAME_BUF
                MOVE        Y1, Y3

                ; D3 = length-so-far (cap at FILENAME_MAX).
                LOADI       D3, #0

                ; Check first char: '"' (quoted) or letter (bare).
                LOADB       D0, [XY0]
                CMP         D0, #$22                 ; '"'
                BEQ         .pfa_quoted

                ; Bare-identifier mode: read until whitespace, ':' or EOL.
                ; ':' is allowed mid-name (it's the drive separator).
                CMP         D0, #0
                BEQ         .pfa_err_name
.pfa_bare_loop:
                LOADB       D0, [XY0]
                CMP         D0, #0
                BEQ         .pfa_done
                CMP         D0, #$20                 ; space
                BEQ         .pfa_done
                CMP         D0, #$3A                 ; ':' — fine, keep going
                BNE         .pfa_bare_chk_term
                STOREB      D0, [XY1]
                ADD         X1, #1
                ADD         X0, #1
                ADD         D3, #1
                CMP         D3, #FILENAME_MAX
                BHS         .pfa_err_name
                BRA         .pfa_bare_loop
.pfa_bare_chk_term:
                CMP         D0, #$3B                 ; ';' (statement?) — stop
                BEQ         .pfa_done
                STOREB      D0, [XY1]
                ADD         X1, #1
                ADD         X0, #1
                ADD         D3, #1
                CMP         D3, #FILENAME_MAX
                BHS         .pfa_err_name
                BRA         .pfa_bare_loop

.pfa_quoted:
                ADD         X0, #1                   ; consume opening '"'
.pfa_quot_loop:
                LOADB       D0, [XY0]
                CMP         D0, #0
                BEQ         .pfa_err_name            ; unterminated
                CMP         D0, #$22                 ; closing '"'
                BEQ         .pfa_quot_done
                STOREB      D0, [XY1]
                ADD         X1, #1
                ADD         X0, #1
                ADD         D3, #1
                CMP         D3, #FILENAME_MAX
                BHS         .pfa_err_name
                BRA         .pfa_quot_loop
.pfa_quot_done:
                ADD         X0, #1                   ; consume closing '"'

.pfa_done:
                ; Update ZP_TXTPOS so the caller's next skip_spaces lands
                ; after the filename arg.
                MOVE        D0, X0
                STOREP      D0, Y3, [#ZP_TXTPOS]

                ; D3 = length written. Must be at least 1 char.
                CMP         D3, #0
                BEQ         .pfa_err_name

                ; --- Normalise: prepend drive if no ':' in name -----------
                ; Scan FILENAME_BUF for ':'. If absent, shift right and
                ; insert "<DRIVE>:" at the front.
                LOADI       X0, #FILENAME_BUF
                MOVE        Y0, Y3
                MOVE        D1, D3                   ; D1 = remaining
                LOADI       D2, #0                   ; D2 = found-colon flag
.pfa_scan_colon:
                CMP         D1, #0
                BEQ         .pfa_colon_done
                LOADB       D0, [XY0]
                CMP         D0, #$3A
                BNE         .pfa_no_match
                LOADI       D2, #1
                BRA         .pfa_colon_done
.pfa_no_match:
                ADD         X0, #1
                SUB         D1, #1
                BRA         .pfa_scan_colon
.pfa_colon_done:
                CMP         D2, #0
                BNE         .pfa_check_ext           ; colon present, skip prepend

                ; --- Shift FILENAME_BUF right by 2 bytes, insert "X:" ----
                ; Move from end backwards: dst[i+2] = src[i] for i = D3-1..0.
                MOVE        D1, D3                   ; D1 = bytes to move
                MOVE        D0, D3
                SUB         D0, #1                   ; D0 = highest source index
.pfa_shift:
                CMP         D1, #0
                BEQ         .pfa_shift_done
                LOADI       X0, #FILENAME_BUF
                ADD         X0, D0
                MOVE        Y0, Y3
                LOADB       D2, [XY0]
                LOADI       X0, #FILENAME_BUF+2
                ADD         X0, D0
                STOREB      D2, [XY0]
                SUB         D0, #1
                SUB         D1, #1
                BRA         .pfa_shift
.pfa_shift_done:
                ; Write drive letter and ':' at the front.
                LOADP       D0, Y3, [#ZP_DRIVE]
                LOADI       X0, #FILENAME_BUF
                MOVE        Y0, Y3
                STOREB      D0, [XY0]
                LOADI       D0, #$3A
                LOADI       X0, #FILENAME_BUF+1
                STOREB      D0, [XY0]
                ADD         D3, #2                   ; D3 now total length

.pfa_check_ext:
                ; --- Auto-append ".BAS" if no '.' in the basename --------
                ; Scan the part AFTER any ':' for a '.'. If none, append.
                LOADI       X0, #FILENAME_BUF
                MOVE        Y0, Y3
                MOVE        D1, D3                   ; remaining
                LOADI       D2, #0                   ; found-dot flag
                ; First, skip past 'X:' if present.
                CMP         D1, #2
                BLO         .pfa_dot_scan
                LOADI       X0, #FILENAME_BUF+1
                LOADB       D0, [XY0]
                CMP         D0, #$3A
                BNE         .pfa_dot_reset
                ; Drive prefix detected; skip it.
                LOADI       X0, #FILENAME_BUF+2
                SUB         D1, #2
                BRA         .pfa_dot_scan
.pfa_dot_reset:
                LOADI       X0, #FILENAME_BUF        ; no drive prefix
.pfa_dot_scan:
                CMP         D1, #0
                BEQ         .pfa_dot_done
                LOADB       D0, [XY0]
                CMP         D0, #$2E                 ; '.'
                BNE         .pfa_dot_next
                LOADI       D2, #1
                BRA         .pfa_dot_done
.pfa_dot_next:
                ADD         X0, #1
                SUB         D1, #1
                BRA         .pfa_dot_scan
.pfa_dot_done:
                CMP         D2, #0
                BNE         .pfa_nul_term            ; already has extension

                ; Append ".BAS".
                LOADI       X0, #FILENAME_BUF
                ADD         X0, D3
                MOVE        Y0, Y3
                LOADI       D0, #$2E
                STOREB      D0, [XY0]
                ADD         X0, #1
                LOADI       D0, #'B'
                STOREB      D0, [XY0]
                ADD         X0, #1
                LOADI       D0, #'A'
                STOREB      D0, [XY0]
                ADD         X0, #1
                LOADI       D0, #'S'
                STOREB      D0, [XY0]
                ADD         X0, #1
                ADD         D3, #4

.pfa_nul_term:
                ; Final nul terminator.
                LOADI       X0, #FILENAME_BUF
                ADD         X0, D3
                MOVE        Y0, Y3
                LOADI       D0, #0
                STOREB      D0, [XY0]
                RETCC

.pfa_err_name:
                RETCS


; ----------------------------------------------------------------------------
; parse_drive_letter — read "<X>:" after a DRIVE / DIR token.
;
;   Tokenizer wouldn't have lowercased; we normalise here.
;   In:    ZP_TXTPOS at current parse position.
;   Out:   D0 = drive letter ('A'..'F'), C=0 on success.
;          C=1 if no drive or malformed (caller decides what to do —
;          DIR with no arg uses ZP_DRIVE; DRIVE without arg is an error).
;   Uses:  D0, D1, X0
; ----------------------------------------------------------------------------
parse_drive_letter:
                CALL16        skip_spaces
                LOADP       D0, Y3, [#ZP_TXTPOS]
                MOVE        X0, D0
                MOVE        Y0, Y3
                LOADB       D0, [XY0]

                ; EOL/colon-separator → no drive arg.
                CMP         D0, #0
                BEQ         .pdl_none
                CMP         D0, #$3A                 ; ':' (BASIC stmt sep)
                BEQ         .pdl_none

                ; Lowercase → uppercase.
                CMP         D0, #'a'
                BLO         .pdl_no_lc
                CMP         D0, #$67                 ; 'f'+1
                BHS         .pdl_no_lc
                SUB         D0, #$20
.pdl_no_lc:
                ; Must be 'A'..'F'.
                CMP         D0, #'A'
                BLO         .pdl_err
                CMP         D0, #$47                 ; 'F'+1
                BHS         .pdl_err

                ; D0 = drive letter. Consume it.
                MOVE        D1, D0                   ; D1 = letter
                ADD         X0, #1
                ; Optional ':'.
                LOADB       D0, [XY0]
                CMP         D0, #$3A
                BNE         .pdl_no_colon
                ADD         X0, #1
.pdl_no_colon:
                ; Update ZP_TXTPOS.
                MOVE        D0, X0
                STOREP      D0, Y3, [#ZP_TXTPOS]
                MOVE        D0, D1
                RETCC

.pdl_none:
                SEC                                  ; C=1 → no drive (not an error per se)
                LOADI       D0, #0
                RET

.pdl_err:
                SEC
                LOADI       D0, #$FF                 ; sentinel — malformed
                RET


; ============================================================================
; CMD_DRIVE — change current drive
;
; Syntax:  DRIVE X:        (X = A..F)
; ============================================================================
CMD_DRIVE:
                CALL16        parse_drive_letter
                BCS         .drv_err
                ; D0 = drive letter ('A'..'F')
                STOREP      D0, Y3, [#ZP_DRIVE]
                ; Echo: "Drive: X:\n"
                LEA         XY0, STR_DRVPRE
                CALL16        print_string
                LOADP       D0, Y3, [#ZP_DRIVE]
                TRAP        #TRAP_PUTCHAR
                LEA         XY0, STR_DRVCOL
                CALL16        print_string
                RET
.drv_err:
                LEA         XY0, STR_DRVERR
                BRA         error_msg


; ============================================================================
; CMD_DIR — list directory
;
; Syntax:  DIR             list current drive (ZP_DRIVE)
;          DIR X:          list drive X (X = A..F)
;
; Walks via TRAP_DIRENT. Buffer layout: name (zstring) at offset 0,
; 32-bit size at offset $10 (low) / $12 (high). Matches kosh's ls.
; ============================================================================
CMD_DIR:
                CALL16        parse_drive_letter
                BCS         .dir_use_cwd
                ; D0 = drive letter from user arg
                BRA         .dir_have_drv
.dir_use_cwd:
                LOADP       D0, Y3, [#ZP_DRIVE]
.dir_have_drv:
                ; D0 = letter — convert to drive index (0..5) for sys_dirent.
                SUB         D0, #'A'
                ; Stash drive index in DIR_DRIVE_TMP for the loop.
                STOREP      D0, Y3, [#DIR_DRIVE_TMP]

                ; --- Header: "Directory of X:" ---------------------------
                LEA         XY0, STR_DIRHDR
                CALL16        print_string
                LOADP       D0, Y3, [#DIR_DRIVE_TMP]
                ADD         D0, #'A'
                TRAP        #TRAP_PUTCHAR
                LOADI       D0, #$3A                 ; ':'
                TRAP        #TRAP_PUTCHAR
                LOADI       D0, #$0A
                TRAP        #TRAP_PUTCHAR

                ; --- Walk dirents ---------------------------------------
                LOADI       D0, #0
                STOREP      D0, Y3, [#DIR_INDEX_TMP]

.dir_loop:
                LOADP       D0, Y3, [#DIR_DRIVE_TMP]
                LOADP       D1, Y3, [#DIR_INDEX_TMP]
                LOADI       X0, #DIR_DIRENT_BUF
                MOVE        Y0, Y3
                TRAP        #TRAP_DIRENT
                BCS         .dir_done

                ; Print "  " indent.
                LOADI       D0, #$20
                TRAP        #TRAP_PUTCHAR
                LOADI       D0, #$20
                TRAP        #TRAP_PUTCHAR

                ; Print name (zstring at offset 0).
                LOADI       X0, #DIR_DIRENT_BUF
                MOVE        Y0, Y3
                CALL16        print_string

                ; Pad to column 16 — count chars printed, emit spaces.
                ; Simple approach: load name length and emit (16 - len)
                ; spaces, clamped at 1.
                LOADI       X0, #DIR_DIRENT_BUF
                MOVE        Y0, Y3
                LOADI       D2, #0
.dir_len:       LOADB       D0, [XY0]
                CMP         D0, #0
                BEQ         .dir_len_done
                ADD         X0, #1
                ADD         D2, #1
                CMP         D2, #16
                BHS         .dir_len_done
                BRA         .dir_len
.dir_len_done:
                ; Emit padding spaces: 16 - D2 (minimum 1).
                LOADI       D1, #16
                SUB         D1, D2
                CMP         D1, #1
                BHS         .dir_pad
                LOADI       D1, #1
.dir_pad:
                CMP         D1, #0
                BEQ         .dir_pad_done
                LOADI       D0, #$20
                TRAP        #TRAP_PUTCHAR
                SUB         D1, #1
                BRA         .dir_pad
.dir_pad_done:

                ; Print size (low 16 bits; "BIG" if high word non-zero).
                LOADI       X0, #DIR_DIRENT_BUF+$12  ; high word
                MOVE        Y0, Y3
                LOADD       D0, [XY0]
                CMP         D0, #0
                BNE         .dir_big

                LOADI       X0, #DIR_DIRENT_BUF+$10  ; low word
                LOADD       D0, [XY0]
                CALL16        print_unsigned
                BRA         .dir_eol

.dir_big:
                LOADI       D0, #'B'
                TRAP        #TRAP_PUTCHAR
                LOADI       D0, #'I'
                TRAP        #TRAP_PUTCHAR
                LOADI       D0, #'G'
                TRAP        #TRAP_PUTCHAR

.dir_eol:
                LOADI       D0, #$0A
                TRAP        #TRAP_PUTCHAR

                ; Advance index.
                LOADP       D0, Y3, [#DIR_INDEX_TMP]
                ADD         D0, #1
                STOREP      D0, Y3, [#DIR_INDEX_TMP]
                BRA         .dir_loop

.dir_done:
                ; If we never got a single dirent, print "(empty)".
                LOADP       D0, Y3, [#DIR_INDEX_TMP]
                CMP         D0, #0
                BNE         .dir_ret
                LEA         XY0, STR_DIREMPTY
                CALL16        print_string
.dir_ret:
                RET


; ============================================================================
; CMD_SAVE — write program text to disk
;
; Syntax:  SAVE "<name>"
;          SAVE <name>
;
; Walks PROG_BASE forward until a record with linenum=0 is hit. The byte
; count INCLUDES the terminating $0000 word, so a subsequent LOAD restores
; the same sentinel. Refuses if there is no program (PROG_BASE is already
; a $0000 sentinel — i.e. empty).
; ============================================================================
CMD_SAVE:
                CALL16        parse_filename_arg
                BCS         .sav_namerr

                ; Find end of program — first linenum==0 record at offset N.
                ; Byte count = N - PROG_BASE + 2 (include the sentinel word).
                LOADI       X0, #PROG_BASE
                MOVE        Y0, Y3
.sav_walk:
                LOADD       D0, [XY0]
                CMP         D0, #0
                BEQ         .sav_walk_done
                ; Skip past 2-byte linenum + zstring (text) + alignment pad.
                ADD         X0, #2
.sav_skip:      LOADB       D0, [XY0]
                ADD         X0, #1
                CMP         D0, #0
                BNE         .sav_skip
                ADD         X0, #1
                AND         X0, #$FFFE
                BRA         .sav_walk
.sav_walk_done:
                ; X0 points at the $0000 sentinel word.
                ; If X0 == PROG_BASE, program is empty.
                MOVE        D0, X0
                CMP         D0, #PROG_BASE
                BEQ         .sav_nothing

                ; Include the sentinel word in the saved data.
                ADD         X0, #2
                MOVE        D2, X0
                SUB         D2, #PROG_BASE           ; D2 = byte count

                ; --- Open file (CREATE|WRITE|TRUNC) ---------------------
                LEA         XY0, FILENAME_BUF
                LOADI       D0, #SAVE_OPEN_FLAGS
                TRAP        #TRAP_OPEN
                BCS         .sav_fileerr

                MOVE        D3, D0                   ; D3 = fd (preserved
                                                     ;        across TRAP_WRITE)

                ; --- Write whole program in one syscall -----------------
                ; D2 = byte count, D3 = fd.
                MOVE        D0, D3
                MOVE        D1, D2
                LOADI       X0, #PROG_BASE
                MOVE        Y0, Y3
                TRAP        #TRAP_WRITE
                BCS         .sav_wrerr

                ; Verify short-write didn't happen.
                CMP         D0, D2
                BNE         .sav_wrerr

                ; Close.
                MOVE        D0, D3
                TRAP        #TRAP_CLOSE

                LEA         XY0, STR_SAVED
                CALL16        print_string
                RET

.sav_wrerr:
                ; Close fd before reporting (best effort).
                MOVE        D0, D3
                TRAP        #TRAP_CLOSE
                LEA         XY0, STR_FILERR
                BRA         error_msg

.sav_fileerr:
                LEA         XY0, STR_FILERR
                BRA         error_msg

.sav_namerr:
                LEA         XY0, STR_NAMERR
                BRA         error_msg

.sav_nothing:
                LEA         XY0, STR_NOPROG
                BRA         error_msg


; ============================================================================
; CMD_LOAD — read program text from disk
;
; Syntax:  LOAD "<name>"
;          LOAD <name>
;
; Reads up to (ARRAY_BASE - PROG_BASE) bytes into PROG_BASE. The file is
; expected to be a SAVE'd program — its trailing $0000 sentinel is the
; program-end marker on disk and we keep it. Issues CMD_CLR after load to
; clear vars / reset string pool / reset arrays / reset DATA pointer.
; ============================================================================
CMD_LOAD:
                CALL16        parse_filename_arg
                BCS         .lod_namerr

                ; Open for read.
                LEA         XY0, FILENAME_BUF
                LOADI       D0, #FOPEN_READ
                TRAP        #TRAP_OPEN
                BCS         .lod_notfound

                MOVE        D3, D0                   ; D3 = fd

                ; Clear current program first (in case read fails partway,
                ; we leave a coherent empty state rather than half a program).
                LOADI       X0, #PROG_BASE
                MOVE        Y0, Y3
                LOADI       D0, #0
                STORED      D0, [XY0]

                ; Loop: read up to 512 bytes at a time into PROG_BASE+offset.
                ; D2 = bytes-so-far (offset into PROG_BASE region).
                LOADI       D2, #0
.lod_loop:
                ; Compute remaining capacity = (ARRAY_BASE - PROG_BASE) - D2.
                LOADI       D0, #(ARRAY_BASE - PROG_BASE)
                SUB         D0, D2
                CMP         D0, #0
                BEQ         .lod_toobig              ; out of room

                ; Cap each read at 512 bytes.
                ; Original intent: BLS .lod_use_remain (D0 <= 512 → use D0).
                ; BLS unimplemented — use inverse: D0 >= 513 → cap.
                CMP         D0, #513
                BHS         .lod_cap_512
                BRA         .lod_use_remain
.lod_cap_512:
                LOADI       D0, #512
.lod_use_remain:
                MOVE        D1, D0                   ; D1 = read count

                ; XY0 = PROG_BASE + D2
                LOADI       X0, #PROG_BASE
                ADD         X0, D2
                MOVE        Y0, Y3

                MOVE        D0, D3                   ; fd
                TRAP        #TRAP_READ
                BCS         .lod_readerr

                ; D0 = bytes read. 0 = EOF.
                CMP         D0, #0
                BEQ         .lod_eof

                ADD         D2, D0
                BRA         .lod_loop

.lod_eof:
                ; Close.
                MOVE        D0, D3
                TRAP        #TRAP_CLOSE

                ; Ensure a $0000 sentinel exists at the end. (A correctly
                ; SAVE'd file already ends in $0000, but stamp one to be
                ; safe — at PROG_BASE+D2 if room, else PROG_BASE+D2-2.)
                LOADI       D0, #(ARRAY_BASE - PROG_BASE - 2)
                ; Original intent: BLS .lod_stamp_end (D2 <= D0 → no truncate).
                ; BLS unimplemented — reverse CMP and BLO: D0 < D2 → truncate.
                CMP         D0, D2
                BLO         .lod_truncate
                BRA         .lod_stamp_end
.lod_truncate:
                MOVE        D2, D0
.lod_stamp_end:
                LOADI       X0, #PROG_BASE
                ADD         X0, D2
                MOVE        Y0, Y3
                LOADI       D0, #0
                STORED      D0, [XY0]

                ; Reset variables, string pool, arrays, DATA pointer.
                CALL16        CMD_CLR

                LEA         XY0, STR_LOADED
                CALL16        print_string
                RET

.lod_readerr:
                MOVE        D0, D3
                TRAP        #TRAP_CLOSE
                LEA         XY0, STR_FILERR
                BRA         error_msg

.lod_toobig:
                MOVE        D0, D3
                TRAP        #TRAP_CLOSE
                ; Reset to empty — we don't have a half-loaded program.
                LOADI       X0, #PROG_BASE
                MOVE        Y0, Y3
                LOADI       D0, #0
                STORED      D0, [XY0]
                CALL16        CMD_CLR
                LEA         XY0, STR_TOOBIG
                BRA         error_msg

.lod_notfound:
                LEA         XY0, STR_NOFILE
                BRA         error_msg

.lod_namerr:
                LEA         XY0, STR_NAMERR
                BRA         error_msg


; ============================================================================
; END OF K16 BASIC (.COM port)
; ============================================================================
