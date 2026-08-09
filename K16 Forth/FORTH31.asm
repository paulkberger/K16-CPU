; ============================================================================
; K16 Forth v3.1 - .COM build for k/OS  (Saturday, 1 August 2026)
; ============================================================================
; v3.1: Part 60 - .COM header. The image now opens with the universal
;       12-byte header: JMP16 MAIN at $0200, magic 'RB' at $0204, version,
;       page count and heap-page count. MAIN moves from $0200 to $020C.
;       Declares pages = 1, heapPages = 0 - single-page, heap in the task
;       page - which is byte-for-byte the old behaviour.
;
;       No code change. Every internal reference is either PC-relative or
;       assembler-resolved, so the 12-byte shift costs nothing. But the
;       loader now REFUSES a headerless image: v3.0 .COM files will not
;       run under a Part 60 kernel, and this image will not run under an
;       older one. Flag day, no grace period.
;
; v3.0: Single-page native rewrite of v2.25.
;
;   Key architectural changes:
;     * 16-bit page-relative dict links (was 24-bit).  All Link fields are
;       now single .WORD values resolved by the assembler.  init_dict_pages
;       is DELETED.
;     * 2-byte threaded cells (was 4-byte).  Inner loop fetches one word
;       per cell; LOADX not LOADXY.
;     * Y-mirror rule: Y0 = Y1 = Y2 = Y3 set ONCE at MAIN, never touched
;       by any primitive.  This means [XY0], [XY1], [XY2] all index into
;       our task page automatically.  No more `MOVE Y0, Y3` dotted through
;       every primitive.
;     * Return stack frames are 2 bytes (X only) — DOCOL pushes X1, EXIT
;       pops X1.  v2.25 pushed/popped XY1 (6 bytes incl. alignment).
;     * Around TRAPs: `PUSH X1` / `POP X1` (5 cycles each).  v2.25 used
;       `PUSH XY1` / `POP XY1` (8 cycles each).  ~6 cycles saved per
;       TRAP-using primitive.
;     * ZP variables LATEST and HERE are now 2 bytes each (was 4).
;
;   What stays the same:
;     * .COM entry, shell registration, single-page memory map (mostly).
;     * Forth word list and dialect (Forth-83 subset).
;     * I/O via TRAPs, ticks via KLIB_TICKS, BYE via TRAP_EXIT.
;     * Compile/interpret model, IMMEDIATE handling, error recovery.
;
; .COM ABI on entry (kOS_Reference_Manual sec 11.9):
;   Y3 = our task page byte (set by sys_exec; do NOT touch)
;   X3 = $FFF0 (kernel-supplied initial stack pointer)
;   IE = 1, KERN_STATE = RUN
;   PC = task_page:$0200 (this file's first instruction)
;
; Memory map (within the user page; Y3 supplies the page byte at runtime):
;   $0000..$01FF   k/OS-reserved task-local kernel area
;   $0200..$3FFF   Forth .COM image (code + rodata + built-in dict)
;   $4000..$40FF   Forth ZP variables (LATEST and HERE now 2 bytes each)
;   $4100..$417F   TIB
;   $4180..$41FF   Word buffer
;   $4200..$DFFF   User dictionary (HERE grows up from $4200)
;   $E000..$EFFE   Return stack (grows down from $EFFE)
;   $F000..$FFEE   Data stack (grows down from $FFFE)
;   $FFF0..$FFFE   Kernel entry stack region
;
; Register conventions:
;   X1     - IP (16-bit page-relative; saved as X1 alone across TRAPs)
;   Y0/Y1/Y2 - all mirror Y3 (set at MAIN, NEVER touched after)
;   XY0    - CFA scratch after NEXT (X0 carries CFA, Y0 = task page)
;   XY2    - Data stack pointer (callee-saved across syscalls per V2 ABI)
;   XY3    - Return stack pointer (Y3 = our task page byte)
;   D2, D3 - callee-saved across syscalls per V2 ABI
;   D0, D1 - scratch / syscall args / returns
;
; Thread cell format: 16-bit page-relative CFA address (2 bytes).
; ============================================================================

.ORG $0200

.INCLUDE "..\K16 OS\kos_defs.inc"
.INCLUDE "..\K16 OS\klib\kos_klib.inc"

                JMP16       MAIN                    ; $0200 - universal entry
; --- .COM header (Part 60) -------------------------------------------------
; $0200 is a JMP16 so the image stays directly executable with no loader at
; all; the header follows at $0204 and is parsed separately, so a bad header
; can never endanger control flow.  The loader REFUSES a bad magic - there is
; no headerless fallback.  See kos_defs.inc for the full field description.
;
; Every field is a full WORD, and the block is emitted with .WORD only.  RM
; 4.6 lists what .BYTE accepts - numeric literals, string literals, escape
; sequences - and symbols are not among them, so `.BYTE COM_VERSION` is an
; undefined-symbol error (RM 11: only immediates, .EQU and .WORD evaluate
; expressions).  An all-.WORD block also cannot leave an odd byte count, so
; it can never desynchronise the alignment of what follows.
;
; To change the page allocation, edit COM_PAGES / COM_HEAPPG - nothing else in
; this file needs to know.
COM_PAGES       .EQU    1       ; TOTAL contiguous pages, including heap
COM_HEAPPG      .EQU    0       ; how many of those are heap (0 = task page)

                .WORD   COM_MAGIC       ; $0204 - dumps as 52 42 "RB"
                .WORD   COM_VERSION     ; $0206 - header version
                .WORD   COM_PAGES       ; $0208 - total pages
                .WORD   COM_HEAPPG      ; $020A - heap pages (partition of pages)
; --- end of header; MAIN follows at $020C

; ============================================================================
; CONFIGURATION
; ============================================================================

.EQU TRUE,          $FFFF
.EQU FALSE,         $0000

; Memory map (single-page; Y3 supplies the page byte)
.EQU TIB_OFFSET,    $4100
.EQU WORD_BUF_OFF,  $4180
.EQU DSTACK_TOP,    $FFFE
.EQU RSTACK_TOP,    $EFFE
.EQU COM_STACK_TOP, $FFF0
.EQU HERE_BASE,     $4200

; ============================================================================
; ZERO PAGE VARIABLES (accessed via LOADP/STOREP with Y3 = task page)
; All entries now 2 bytes (16-bit page-relative addresses where applicable).
; ============================================================================

.EQU ZP_LATEST,       $4000           ; word: head of dict chain (CFA addr)
.EQU ZP_HERE,         $4002           ; word: user-dict compile pointer
.EQU ZP_STATE,        $4004           ; 0=interp, 1=compile
.EQU ZP_TOIN,         $4006           ; >IN parse position
.EQU ZP_NUMTIB,       $4008           ; #TIB character count
.EQU ZP_BASE,         $400A           ; number base
.EQU ZP_SAVED_LATEST, $400C           ; saved LATEST for error recovery
.EQU ZP_DUMPPAGE,     $400E           ; current page for DUMP (8-bit, stored as word)
.EQU ZP_CALL_BUF,     $4010           ; exec_prim mini-thread: [word-CFA][STOP-CFA]
                                      ;   4 bytes (was 8 in v2.25)
.EQU ZP_EXEC_RET,     $4014           ; IP save slot for CALL-mode primitives that
                                      ;   use rstack heavily (DUMP, WORDS, .S, FORGET)
; $4016..$40FF free for future use

; ============================================================================
; STRING CONSTANTS
; ============================================================================

BANNER:         .TEXT       "K16 Forth v3.1 (.COM under k/OS, single-page native)\nType BYE to exit.\n\0"
STR_PROMPT:     .TEXT       "> \0"
STR_OK:         .TEXT       " ok\n\0"
STR_ERROR:      .TEXT       " ?\n\0"

; ============================================================================
; INNER INTERPRETER
; ============================================================================
; NEXT:  4 instructions, exploits Y-mirror invariant.
;        After NEXT, X0 holds the consumed CFA (for DOCOL/DOVAR/DOCON);
;        X1 has advanced past the cell just consumed.
;        Y0/Y1 are NOT touched — they already = Y3 from boot.
; ============================================================================

NEXT:
                LOADX       X0, [XY1]           ; X0 = CFA at IP (Y1=Y3 → our page)
                INC         XY1, #2             ; IP += 2 (one cell)
                LOADD       D0, [XY0]           ; D0 = code addr at CFA (Y0=Y3)
                MOVE        PC, D0              ; jump to primitive

; ============================================================================
; DOCOL / EXIT — Colon-word entry / return
; ============================================================================
; Return stack frame is 2 bytes (X1 only).  Y is constant = Y3 throughout
; so there's no point storing it.

DOCOL:
                PUSH        X1, XY3             ; save IP (2 bytes)
                MOVE        X1, X0              ; X1 = CFA
                ADD         X1, #2              ; X1 = body start (skip CFA word)
                BRA         NEXT

EXIT_WORD:
                POP         X1, XY3             ; restore IP
                BRA         NEXT

; ============================================================================
; LIT — Push inline literal onto data stack
; ============================================================================
; Thread layout: [LIT_CFA][value][next_CFA]
;                          ^X1 (after this primitive reads value)

LIT:
                LOADD       D0, [XY1]           ; D0 = inline literal value
                INC         XY1, #2             ; advance IP past literal
                PUSH        D0, XY2             ; push value onto data stack
                BRA         NEXT

; ============================================================================
; DOVAR / DOCON — Variable / Constant handlers
; ============================================================================
; After NEXT, X0 = CFA, body word follows at CFA+2.
;   DOVAR: push body address itself (so user code can fetch/store via @ and !)
;   DOCON: push value stored at body

DOVAR:
                ADD         X0, #2              ; X0 = body address
                PUSH        X0, XY2             ; push 16-bit address
                BRA         NEXT

DOCON:
                ADD         X0, #2              ; X0 = body address
                LOADD       D0, [XY0]           ; D0 = constant value at body
                PUSH        D0, XY2
                BRA         NEXT

; ============================================================================
; STACK PRIMITIVES — smoke-test core
; ============================================================================

DUP:            ; ( x -- x x )
                LOADD       D0, [XY2]
                PUSH        D0, XY2
                BRA         NEXT

DROP:           ; ( x -- )
                ADD         X2, #2
                BRA         NEXT

SWAP_PRIM:      ; ( a b -- b a )
                LOADD       D0, [XY2]           ; b (TOS)
                LOADD       D1, [XY2 + #2]      ; a (under)
                STORED      D1, [XY2]
                STORED      D0, [XY2 + #2]
                BRA         NEXT

OVER:           ; ( a b -- a b a )
                LOADD       D0, [XY2 + #2]      ; D0 = a
                PUSH        D0, XY2
                BRA         NEXT

; ============================================================================
; ARITHMETIC — smoke-test core
; ============================================================================

PLUS:           ; ( a b -- a+b )
                POP         D0, XY2             ; b
                LOADD       D1, [XY2]           ; a (in place)
                ADD         D1, D0
                STORED      D1, [XY2]
                BRA         NEXT

MINUS:          ; ( a b -- a-b )
                POP         D0, XY2             ; b
                LOADD       D1, [XY2]           ; a
                SUB         D1, D0
                STORED      D1, [XY2]
                BRA         NEXT

; ============================================================================
; STACK PRIMITIVES — batch 1
; ============================================================================
; All Y-management deleted: Y0/Y1/Y2 = Y3 throughout these (no TRAPs).

ROT:            ; ( a b c -- b c a )
                LOADD       D0, [XY2]           ; c
                LOADD       D1, [XY2 + #2]      ; b
                LOADD       D2, [XY2 + #4]      ; a
                STORED      D1, [XY2 + #4]      ; b → bottom
                STORED      D0, [XY2 + #2]      ; c → middle
                STORED      D2, [XY2]           ; a → top
                BRA         NEXT

MINUSROT:       ; -ROT ( a b c -- c a b )
                LOADD       D0, [XY2]           ; c
                LOADD       D1, [XY2 + #2]      ; b
                LOADD       D2, [XY2 + #4]      ; a
                STORED      D0, [XY2 + #4]      ; c → bottom
                STORED      D2, [XY2 + #2]      ; a → middle
                STORED      D1, [XY2]           ; b → top
                BRA         NEXT

NIP:            ; ( a b -- b )
                LOADD       D0, [XY2]           ; b
                STORED      D0, [XY2 + #2]
                ADD         X2, #2
                BRA         NEXT

TUCK:           ; ( a b -- b a b )
                LOADD       D0, [XY2]           ; b
                LOADD       D1, [XY2 + #2]      ; a
                STORED      D0, [XY2 + #2]      ; b overwrites a's slot
                STORED      D1, [XY2]           ; a at TOS (mid)
                PUSH        D0, XY2             ; b at new TOS
                BRA         NEXT

QDUP:           ; ?DUP ( x -- x x | 0 )
                LOADD       D0, [XY2]
                CMP         D0, #0
                BEQ         .qdup_done
                PUSH        D0, XY2
.qdup_done:     BRA         NEXT

TWODUP:         ; 2DUP ( a b -- a b a b )
                LOADD       D0, [XY2]
                LOADD       D1, [XY2 + #2]
                PUSH        D1, XY2
                PUSH        D0, XY2
                BRA         NEXT

TWODROP:        ; 2DROP ( a b -- )
                ADD         X2, #4
                BRA         NEXT

TWOSWAP:        ; 2SWAP ( a b c d -- c d a b )
                LOADD       D0, [XY2]           ; d
                LOADD       D1, [XY2 + #2]      ; c
                LOADD       D2, [XY2 + #4]      ; b
                LOADD       D3, [XY2 + #6]      ; a
                STORED      D2, [XY2]           ; b → TOS
                STORED      D3, [XY2 + #2]      ; a
                STORED      D0, [XY2 + #4]      ; d
                STORED      D1, [XY2 + #6]      ; c → bottom
                BRA         NEXT

TWOOVER:        ; 2OVER ( a b c d -- a b c d a b )
                LOADD       D0, [XY2 + #6]      ; a
                LOADD       D1, [XY2 + #4]      ; b
                PUSH        D0, XY2
                PUSH        D1, XY2
                BRA         NEXT

PICK:           ; ( xu...x0 u -- xu...x0 xu )
                POP         D0, XY2             ; u
                SHL         D0                  ; u*2
                ADD         D0, X2              ; addr = X2 + offset
                MOVE        X0, D0              ; Y0 = Y3 already
                LOADD       D0, [XY0]
                PUSH        D0, XY2
                BRA         NEXT

DEPTH:          ; ( -- n )
                LOADI       D0, #DSTACK_TOP
                SUB         D0, X2
                SHR         D0                  ; bytes → words
                PUSH        D0, XY2
                BRA         NEXT

; --- Return Stack ---

TOR:            ; >R ( x -- ) R:( -- x )
                POP         D0, XY2
                PUSH        D0, XY3
                BRA         NEXT

RFROM:          ; R> ( -- x ) R:( x -- )
                POP         D0, XY3
                PUSH        D0, XY2
                BRA         NEXT

RFETCH:         ; R@ ( -- x )
                LOADD       D0, [XY3]
                PUSH        D0, XY2
                BRA         NEXT

; ============================================================================
; ARITHMETIC — batch 1
; ============================================================================

STAR:           ; * ( n1 n2 -- product )
                POP         D1, XY2             ; n2
                POP         D0, XY2             ; n1
                CALL16      mul_16x16
                PUSH        D0, XY2
                BRA         NEXT

ONEPLUS:        ; 1+ ( n -- n+1 )
                LOADD       D0, [XY2]
                ADD         D0, #1
                STORED      D0, [XY2]
                BRA         NEXT

ONEMINUS:       ; 1- ( n -- n-1 )
                LOADD       D0, [XY2]
                SUB         D0, #1
                STORED      D0, [XY2]
                BRA         NEXT

TWOSTAR:        ; 2* ( n -- n*2 )
                LOADD       D0, [XY2]
                SHL         D0
                STORED      D0, [XY2]
                BRA         NEXT

TWOSLASH:       ; 2/ ( n -- n/2 )  arithmetic
                LOADD       D0, [XY2]
                ASR         D0
                STORED      D0, [XY2]
                BRA         NEXT

NEGATE:         ; ( n -- -n )
                LOADD       D0, [XY2]
                NOT         D0
                ADD         D0, #1
                STORED      D0, [XY2]
                BRA         NEXT

ABSS:           ; ABS ( n -- |n| )
                LOADD       D0, [XY2]
                CMP         D0, #$8000
                BCC         .abs_done
                NOT         D0
                ADD         D0, #1
                STORED      D0, [XY2]
.abs_done:      BRA         NEXT

MIN:            ; ( n1 n2 -- min )  signed
                POP         D0, XY2
                LOADD       D1, [XY2]
                CMP         D1, D0
                BGE         .min_use_d0
                BRA         NEXT
.min_use_d0:    STORED      D0, [XY2]
                BRA         NEXT

MAX:            ; ( n1 n2 -- max )  signed
                POP         D0, XY2
                LOADD       D1, [XY2]
                CMP         D1, D0
                BGE         NEXT
                STORED      D0, [XY2]
                BRA         NEXT

; ============================================================================
; DIVISION — /, MOD, /MOD (signed, repeated-subtraction)
; ============================================================================

SLASHMOD_WORD:  ; /MOD ( n1 n2 -- rem quot ) signed
                POP         D1, XY2             ; divisor
                POP         D0, XY2             ; dividend

                LOADI       D2, #0              ; D2 = result sign (0=pos, 1=neg)

                CMP         D0, #0
                BGE         .sm_div_pos
                NOT         D0
                ADD         D0, #1              ; |D0|
                XOR         D2, #1
.sm_div_pos:
                CMP         D1, #0
                BGE         .sm_sor_pos
                NOT         D1
                ADD         D1, #1              ; |D1|
                XOR         D2, #1
.sm_sor_pos:
                CMP         D1, #0
                BEQ         .sm_div_zero

                LOADI       D3, #0              ; quotient
.sm_loop:
                CMP         D0, D1
                BLT         .sm_done
                SUB         D0, D1
                ADD         D3, #1
                BRA         .sm_loop
.sm_done:
                CMP         D2, #0
                BEQ         .sm_push
                NOT         D3
                ADD         D3, #1              ; negate quotient
.sm_push:
                PUSH        D0, XY2             ; remainder
                PUSH        D3, XY2             ; quotient
                BRA         NEXT
.sm_div_zero:
                LOADI       D0, #0
                PUSH        D0, XY2
                PUSH        D0, XY2
                BRA         NEXT

SLASH_WORD:     ; / ( n1 n2 -- quot ) signed
                POP         D1, XY2
                POP         D0, XY2
                LOADI       D2, #0
                CMP         D0, #0
                BGE         .sl_div_pos
                NOT         D0
                ADD         D0, #1
                XOR         D2, #1
.sl_div_pos:
                CMP         D1, #0
                BGE         .sl_sor_pos
                NOT         D1
                ADD         D1, #1
                XOR         D2, #1
.sl_sor_pos:
                CMP         D1, #0
                BEQ         .sl_zero
                LOADI       D3, #0
.sl_loop:
                CMP         D0, D1
                BLT         .sl_done
                SUB         D0, D1
                ADD         D3, #1
                BRA         .sl_loop
.sl_done:
                CMP         D2, #0
                BEQ         .sl_push
                NOT         D3
                ADD         D3, #1
.sl_push:
                PUSH        D3, XY2
                BRA         NEXT
.sl_zero:
                LOADI       D0, #0
                PUSH        D0, XY2
                BRA         NEXT

MOD_WORD:       ; MOD ( n1 n2 -- rem ) signed; rem has sign of dividend
                POP         D1, XY2
                POP         D0, XY2
                LOADI       D2, #0              ; dividend sign
                CMP         D0, #0
                BGE         .mod_div_pos
                NOT         D0
                ADD         D0, #1
                LOADI       D2, #1
.mod_div_pos:
                CMP         D1, #0
                BGE         .mod_sor_pos
                NOT         D1
                ADD         D1, #1
.mod_sor_pos:
                CMP         D1, #0
                BEQ         .mod_zero
.mod_loop:
                CMP         D0, D1
                BLT         .mod_done
                SUB         D0, D1
                BRA         .mod_loop
.mod_done:
                CMP         D2, #0
                BEQ         .mod_push
                NOT         D0
                ADD         D0, #1
.mod_push:
                PUSH        D0, XY2
                BRA         NEXT
.mod_zero:
                LOADI       D0, #0
                PUSH        D0, XY2
                BRA         NEXT

; ============================================================================
; LOGIC — batch 1
; ============================================================================

ANDD:           ; AND ( n1 n2 -- n1&n2 )
                POP         D0, XY2
                LOADD       D1, [XY2]
                AND         D1, D0
                STORED      D1, [XY2]
                BRA         NEXT

ORR:            ; OR ( n1 n2 -- n1|n2 )
                POP         D0, XY2
                LOADD       D1, [XY2]
                OR          D1, D0
                STORED      D1, [XY2]
                BRA         NEXT

XORR:           ; XOR ( n1 n2 -- n1^n2 )
                POP         D0, XY2
                LOADD       D1, [XY2]
                XOR         D1, D0
                STORED      D1, [XY2]
                BRA         NEXT

INVERT:         ; INVERT ( n -- ~n )
                LOADD       D0, [XY2]
                NOT         D0
                STORED      D0, [XY2]
                BRA         NEXT

; ============================================================================
; COMPARISON — batch 1 (all Scc-branchless)
; ============================================================================

ZEQU:           ; 0= ( n -- flag )
                LOADD       D0, [XY2]
                CMP         D0, #0
                SEQ         D0
                STORED      D0, [XY2]
                BRA         NEXT

ZLESS:          ; 0< ( n -- flag )
                LOADD       D0, [XY2]
                CMP         D0, #0
                SLT         D0
                STORED      D0, [XY2]
                BRA         NEXT

ZGREAT:         ; 0> ( n -- flag )
                LOADD       D0, [XY2]
                CMP         D0, #0
                SGT         D0
                STORED      D0, [XY2]
                BRA         NEXT

EQU:            ; = ( n1 n2 -- flag )
                POP         D0, XY2
                LOADD       D1, [XY2]
                CMP         D1, D0
                SEQ         D0
                STORED      D0, [XY2]
                BRA         NEXT

NOTEQ:          ; <> ( n1 n2 -- flag )
                POP         D0, XY2
                LOADD       D1, [XY2]
                CMP         D1, D0
                SNE         D0
                STORED      D0, [XY2]
                BRA         NEXT

LESS:           ; < ( n1 n2 -- flag ) signed
                POP         D0, XY2
                LOADD       D1, [XY2]
                CMP         D1, D0
                SLT         D0
                STORED      D0, [XY2]
                BRA         NEXT

GREATER:        ; > ( n1 n2 -- flag ) signed
                POP         D0, XY2
                LOADD       D1, [XY2]
                CMP         D1, D0
                SGT         D0
                STORED      D0, [XY2]
                BRA         NEXT

LESSEQ:         ; <= ( n1 n2 -- flag ) signed
                POP         D0, XY2
                LOADD       D1, [XY2]
                CMP         D1, D0
                SLE         D0
                STORED      D0, [XY2]
                BRA         NEXT

GREATEQ:        ; >= ( n1 n2 -- flag ) signed
                POP         D0, XY2
                LOADD       D1, [XY2]
                CMP         D1, D0
                SGE         D0
                STORED      D0, [XY2]
                BRA         NEXT

ULESS:          ; U< ( u1 u2 -- flag ) unsigned
                POP         D0, XY2
                LOADD       D1, [XY2]
                CMP         D1, D0
                SCC         D0                  ; carry clear ⇒ u1 < u2
                STORED      D0, [XY2]
                BRA         NEXT

UGREAT:         ; U> ( u1 u2 -- flag ) unsigned
                POP         D0, XY2             ; u2
                LOADD       D1, [XY2]           ; u1
                CMP         D0, D1              ; compare u2-u1 (swapped)
                SCC         D0
                STORED      D0, [XY2]
                BRA         NEXT

; ============================================================================
; MEMORY — batch 1.  Y0 already = Y3, no MOVE needed.
; ============================================================================

FETCH:          ; @ ( addr -- n )
                POP         D0, XY2
                MOVE        X0, D0
                LOADD       D0, [XY0]
                PUSH        D0, XY2
                BRA         NEXT

STORE:          ; ! ( n addr -- )
                POP         D0, XY2             ; addr
                POP         D1, XY2             ; n
                MOVE        X0, D0
                STORED      D1, [XY0]
                BRA         NEXT

CFETCH:         ; C@ ( addr -- c )
                POP         D0, XY2
                MOVE        X0, D0
                LOADB       D0, [XY0]
                PUSH        D0, XY2
                BRA         NEXT

CSTORE:         ; C! ( c addr -- )
                POP         D0, XY2             ; addr
                POP         D1, XY2             ; c
                MOVE        X0, D0
                STOREB      D1, [XY0]
                BRA         NEXT

PLUSSTORE:      ; +! ( n addr -- )
                POP         D0, XY2             ; addr
                POP         D1, XY2             ; n
                MOVE        X0, D0
                LOADD       D2, [XY0]
                ADD         D2, D1
                STORED      D2, [XY0]
                BRA         NEXT

; ============================================================================
; BATCH 2 — Number printing helpers and DOT
; ============================================================================
; mul_16x16, mul_16x16_32, div10, print_number, print_decimal, print_hex
; DOT primitive.
;
; These run in CALL-mode (called via CALL16 from primitives) and use the
; return stack heavily for partial-product layout.  None of them touches
; Y registers (Y0/Y1/Y2 stay = Y3 throughout), so no Y-mirror discipline
; needed inside the helpers.  TRAPs ARE issued (sys_putchar) — the
; mirror restore is done in the CALLING primitive (DOT) after the helper
; returns.

; --- mul_16x16: 16x16 → low 16 multiply via MULB
; In:  D0 = n1, D1 = n2
; Out: D0 = product (low 16 bits)
; Trashes: D1, D2, D3

mul_16x16:
                ; Extract bytes (HIGH Dn = Dn >> 8, so n1H lands in low half)
                MOVE        D2, D0
                HIGH        D2                  ; D2 = n1H (as $00xx)
                AND         D0, #$FF            ; D0 = n1L
                MOVE        D3, D1
                HIGH        D3                  ; D3 = n2H
                AND         D1, #$FF            ; D1 = n2L

                ; Stash operands for second use
                PUSH        D0, XY3             ; save n1L
                PUSH        D1, XY3             ; save n2L
                PUSH        D2, XY3             ; save n1H
                ; Stack: [0]=n1H, [2]=n2L, [4]=n1L

                ; PP0 = n1L * n2L
                SHL4        D1
                SHL4        D1                  ; D1 = n2L << 8
                OR          D0, D1              ; D0 = (n2L<<8) | n1L
                MULB        D0                  ; D0 = PP0
                PUSH        D0, XY3
                ; Stack: [0]=PP0, [2]=n1H, [4]=n2L, [6]=n1L

                ; PP1 = n1H * n2L
                LOADD       D0, [XY3 + #2]      ; n1H
                LOADD       D1, [XY3 + #4]      ; n2L
                SHL4        D1
                SHL4        D1
                OR          D0, D1
                MULB        D0                  ; D0 = PP1
                MOVE        D2, D0              ; D2 = PP1

                ; PP2 = n1L * n2H (D3 still has n2H)
                LOADD       D0, [XY3 + #6]      ; n1L
                SHL4        D3
                SHL4        D3                  ; D3 = n2H << 8
                OR          D0, D3
                MULB        D0                  ; D0 = PP2

                ; middle = PP1 + PP2
                ADD         D0, D2
                SHL4        D0
                SHL4        D0                  ; D0 = middle << 8

                ; result = PP0 + (middle << 8)
                POP         D1, XY3             ; D1 = PP0
                ADD         D0, D1              ; D0 = final 16-bit product

                ADD         X3, #6              ; discard n1H, n2L, n1L
                RET

; --- mul_16x16_32: 16x16 → 32-bit full product
; In:  D0 = n1, D1 = n2
; Out: D0 = lo16, D1 = hi16
; Trashes: D2, D3

mul_16x16_32:
                MOVE        D2, D0
                HIGH        D2                  ; D2 = n1H (as $00xx)
                AND         D0, #$FF            ; D0 = n1L
                MOVE        D3, D1
                HIGH        D3                  ; D3 = n2H
                AND         D1, #$FF            ; D1 = n2L

                PUSH        D3, XY3             ; [SP+0]=n2H
                PUSH        D2, XY3             ; [SP+0]=n1H, [SP+2]=n2H
                PUSH        D1, XY3             ; [SP+0]=n2L, [SP+2]=n1H, [SP+4]=n2H
                PUSH        D0, XY3             ; [SP+0]=n1L, [SP+2]=n2L, [SP+4]=n1H, [SP+6]=n2H

                ; PP0 = n1L * n2L
                SHL4        D1
                SHL4        D1
                OR          D0, D1
                MULB        D0
                PUSH        D0, XY3             ; [SP+0]=PP0, rest shifts by 2

                ; PP1 = n1H * n2L
                LOADD       D0, [XY3 + #6]      ; n1H
                LOADD       D1, [XY3 + #4]      ; n2L
                SHL4        D1
                SHL4        D1
                OR          D0, D1
                MULB        D0
                MOVE        D2, D0              ; D2 = PP1

                ; PP2 = n1L * n2H
                LOADD       D0, [XY3 + #2]      ; n1L
                LOADD       D1, [XY3 + #8]      ; n2H
                SHL4        D1
                SHL4        D1
                OR          D0, D1
                MULB        D0                  ; D0 = PP2

                ; middle = PP1 + PP2
                ADD         D0, D2
                SCS         D1                  ; D1 = carry ($FFFF or 0)
                AND         D1, #1              ; D1 = middle_carry (0 or 1)
                MOVE        D2, D0              ; D2 = middle

                ; PP3 = n1H * n2H
                LOADD       D0, [XY3 + #6]      ; n1H
                LOADD       D3, [XY3 + #8]      ; n2H
                SHL4        D3
                SHL4        D3
                OR          D0, D3
                MULB        D0                  ; D0 = PP3

                ; Split middle
                MOVE        D3, D2
                AND         D3, #$FF            ; D3 = middle_lo
                HIGH        D2                  ; D2 = middle_hi

                ; hi16 = PP3 + middle_hi + (carry << 8)
                ADD         D0, D2
                SHL4        D1
                SHL4        D1                  ; D1 = carry << 8
                ADD         D0, D1
                MOVE        D1, D0              ; D1 = hi16 (save)

                ; lo16 = PP0 + (middle_lo << 8)
                SHL4        D3
                SHL4        D3
                POP         D0, XY3             ; D0 = PP0
                ADD         D0, D3              ; D0 = lo16
                SCS         D2
                AND         D2, #1
                ADD         D1, D2              ; hi16 += lo_carry

                ADD         X3, #8              ; discard 4 saved bytes
                RET

; --- div10: divide-by-10 via reciprocal multiply
; In:  D0 = dividend (unsigned 0..65535)
; Out: D0 = quotient, D1 = remainder
; Trashes: D2, D3

div10:
                PUSH        D0, XY3             ; save n
                LOADI       D1, #52429          ; $CCCD magic multiplier
                CALL16      mul_16x16_32        ; D0=lo16, D1=hi16

                ; quotient = hi16 >> 3
                MOVE        D0, D1
                SHR         D0
                SHR         D0
                SHR         D0                  ; D0 = quotient

                ; remainder = n - quotient*10
                MOVE        D2, D0              ; D2 = quotient (save)
                MOVE        D1, D0
                SHL         D1                  ; D1 = q*2
                SHL         D0
                SHL         D0
                SHL         D0                  ; D0 = q*8
                ADD         D0, D1              ; D0 = q*10

                POP         D1, XY3             ; D1 = original n
                SUB         D1, D0              ; D1 = remainder
                MOVE        D0, D2              ; D0 = quotient
                RET

; --- print_decimal: print signed D0 in decimal via sys_putchar
; Clobbers: D0, D1, D2, D3, X0 (via div10).  Caller saves Forth IP if needed.
; TRAPs: yes — caller's responsibility to restore Y0/Y1 after returning.

print_decimal:
                CMP         D0, #$8000
                BCC         .pd_positive

                ; Negative — emit '-', negate
                PUSH        D0, XY3
                LOADI       D0, #$2D            ; '-'
                TRAP        #TRAP_PUTCHAR
                POP         D0, XY3
                NOT         D0
                ADD         D0, #1              ; |D0|

.pd_positive:
                CMP         D0, #0
                BNE         .pd_nonzero
                LOADI       D0, #$30            ; '0'
                TRAP        #TRAP_PUTCHAR
                RET

.pd_nonzero:
                LOADI       D1, #0
                PUSH        D1, XY3             ; sentinel
.pd_loop:       CMP         D0, #0
                BEQ         .pd_emit
                CALL16      div10               ; D0=quot, D1=rem
                ADD         D1, #$30
                PUSH        D1, XY3
                BRA         .pd_loop
.pd_emit:
.pd_eloop:      POP         D0, XY3
                CMP         D0, #0
                BEQ         .pd_done
                TRAP        #TRAP_PUTCHAR
                BRA         .pd_eloop
.pd_done:       RET

; --- print_hex: print D0 as 4 hex digits via sys_putchar
; Clobbers: D0, D1, X0.  TRAPs.

print_hex:
                PUSH        D0, XY3
                HIGH        D0                  ; high byte in low half
                SHR4        D0                  ; digit 0 (bits 15:12)
                CALL16      .pn
                POP         D0, XY3
                PUSH        D0, XY3
                HIGH        D0
                AND         D0, #$0F            ; digit 1 (bits 11:8)
                CALL16      .pn
                POP         D0, XY3
                PUSH        D0, XY3
                SHR4        D0
                AND         D0, #$0F            ; digit 2 (bits 7:4)
                CALL16      .pn
                POP         D0, XY3
                AND         D0, #$0F            ; digit 3 (bits 3:0)
                CALL16      .pn
                RET
.pn:            CMP         D0, #10
                BCS         .pn_l
                ADD         D0, #$30            ; '0'-'9'
                BRA         .pn_o
.pn_l:          SUB         D0, #10
                ADD         D0, #$41            ; 'A'-'F'
.pn_o:          TRAP        #TRAP_PUTCHAR
                RET

; --- print_number: dispatch on BASE
print_number:
                PUSH        D0, XY3
                LOADP       D1, Y3, [#ZP_BASE]
                POP         D0, XY3
                CMP         D1, #16
                BEQ         print_hex
                BRA         print_decimal

; --- DOT primitive: ( n -- ) print as signed decimal then a space
DOT:            ; ( n -- )
                POP         D0, XY2
                PUSH        X1, XY3             ; save IP across print_number + TRAP
                CALL16      print_number
                LOADI       D0, #$20            ; trailing space
                TRAP        #TRAP_PUTCHAR
                POP         X1, XY3
                MOVE        Y0, Y3              ; restore mirror — many TRAPs above
                MOVE        Y1, Y3
                BRA         NEXT

; --- HEX / DECIMAL — switch number base
HEX_WORD:
                LOADI       D0, #16
                STOREP      D0, Y3, [#ZP_BASE]
                BRA         NEXT

DECIMAL_WORD:
                LOADI       D0, #10
                STOREP      D0, Y3, [#ZP_BASE]
                BRA         NEXT

; ============================================================================
; I/O — all primitives route through k/OS syscalls.
; Around every TRAP: PUSH X1 / TRAP / POP X1 (X1 is our IP; V2 ABI does not
; preserve it).  We save X1 alone — 5 cycles each way — not XY1 (8 cycles).
;
; *** Y-MIRROR RESTORATION ***
; k/OS TRAPs preserve only D2, D3, XY2 (V2 ABI).  Y0 and Y1 are CLOBBERED
; across every TRAP.  Any primitive that issues a TRAP must restore the
; Y-mirror with:
;     MOVE Y0, Y3
;     MOVE Y1, Y3
; before returning to NEXT.  (Y2 is part of XY2 → callee-saved, but we
; re-set it at MAIN once.)
; ============================================================================

EMIT:           ; ( c -- )
                POP         D0, XY2             ; D0 = char
                PUSH        X1, XY3             ; save IP (TRAP clobbers X1)
                TRAP        #TRAP_PUTCHAR
                POP         X1, XY3
                MOVE        Y0, Y3              ; re-mirror — TRAP clobbers Y0/Y1
                MOVE        Y1, Y3
                BRA         NEXT

KEY:            ; ( -- c )
                PUSH        X1, XY3
                TRAP        #TRAP_GETCHAR       ; D0 = byte (blocks)
                POP         X1, XY3
                MOVE        Y0, Y3
                MOVE        Y1, Y3
                AND         D0, #$FF            ; mask defensively
                PUSH        D0, XY2
                BRA         NEXT

CR:             ; ( -- )
                LOADI       D0, #$0A
                PUSH        X1, XY3
                TRAP        #TRAP_PUTCHAR
                POP         X1, XY3
                MOVE        Y0, Y3
                MOVE        Y1, Y3
                BRA         NEXT

SPACE:          ; ( -- )
                LOADI       D0, #$20
                PUSH        X1, XY3
                TRAP        #TRAP_PUTCHAR
                POP         X1, XY3
                MOVE        Y0, Y3
                MOVE        Y1, Y3
                BRA         NEXT

BYE_WORD:       ; BYE ( -- ) clean task exit; does not return
                LOADI       D0, #0              ; exit code 0
                TRAP        #TRAP_EXIT
                BRA         NEXT                ; safety; sys_exit won't return

; ============================================================================
; BUILT-IN DICTIONARY (smoke-test subset)
; ============================================================================
; Chain head:  DICT_COLON
; Chain tail:  Link = 0 (DICT_SPACE)
; ============================================================================

; Layout per entry:
;   +0  word    Link        (16-bit page-relative; 0 = end of chain)
;   +2  word    Length+flags (low 6 bits = name length; bit 7 = IMMEDIATE)
;   +4  bytes   Name        (.TEXT, zero-padded to word boundary; for odd
;                            lengths add explicit ", 0" to keep alignment)
;   +N  word    CFA         (primitive code address)

; --- Colon-definition core ---

; --- Batches 4-10: new dict head ---

DICT_DOTQUOTE:  .WORD       DICT_PAREN
                .WORD       $82                 ; len=2, IMMEDIATE
                .TEXT       ".", $22            ; ."  (period + quote, 2 bytes, no pad)
CFA_DOTQUOTE_DICT: .WORD    DOTQUOTE_COMP

DICT_PAREN:     .WORD       DICT_BACKSLASH
                .WORD       $81                 ; len=1, IMMEDIATE
                .TEXT       "(", 0
CFA_PAREN:      .WORD       PAREN_COMMENT

DICT_BACKSLASH: .WORD       DICT_VARIABLE
                .WORD       $81                 ; len=1, IMMEDIATE
                .TEXT       $5C, 0              ; '\' (backslash)
CFA_BACKSLASH:  .WORD       BACKSLASH_COMMENT

DICT_VARIABLE:  .WORD       DICT_CONSTANT
                .WORD       8
                .TEXT       "VARIABLE"
CFA_VARIABLE:   .WORD       VARIABLE_WORD

DICT_CONSTANT:  .WORD       DICT_WORDS
                .WORD       8
                .TEXT       "CONSTANT"
CFA_CONSTANT:   .WORD       CONSTANT_WORD

DICT_WORDS:     .WORD       DICT_DOTS
                .WORD       5
                .TEXT       "WORDS", 0
CFA_WORDS:      .WORD       WORDS_WORD

DICT_DOTS:      .WORD       DICT_FIND
                .WORD       2
                .TEXT       ".S"
CFA_DOTS:       .WORD       DOTS_WORD

DICT_FIND:      .WORD       DICT_DUMP
                .WORD       4
                .TEXT       "FIND"
CFA_FIND_DICT:  .WORD       FIND_PRIM

DICT_DUMP:      .WORD       DICT_QUESTION
                .WORD       4
                .TEXT       "DUMP"
CFA_DUMP:       .WORD       DUMP_WORD

DICT_QUESTION:  .WORD       DICT_FILL
                .WORD       1
                .TEXT       "?", 0
CFA_QUESTION:   .WORD       QUESTION_WORD

DICT_FILL:      .WORD       DICT_CMOVE
                .WORD       4
                .TEXT       "FILL"
CFA_FILL:       .WORD       FILL_WORD

DICT_CMOVE:     .WORD       DICT_DUMPPAGE
                .WORD       5
                .TEXT       "CMOVE", 0
CFA_CMOVE:      .WORD       CMOVE_WORD

DICT_DUMPPAGE:  .WORD       DICT_FORGET
                .WORD       8
                .TEXT       "DUMPPAGE"
CFA_DUMPPAGE:   .WORD       DUMPPAGE_WORD

DICT_FORGET:    .WORD       DICT_TYPE
                .WORD       6
                .TEXT       "FORGET"
CFA_FORGET:     .WORD       FORGET_WORD

DICT_TYPE:      .WORD       DICT_SPACES
                .WORD       4
                .TEXT       "TYPE"
CFA_TYPE:       .WORD       TYPE_WORD

DICT_SPACES:    .WORD       DICT_CLS
                .WORD       6
                .TEXT       "SPACES"
CFA_SPACES:     .WORD       SPACES

DICT_CLS:       .WORD       DICT_TICKS
                .WORD       3
                .TEXT       "CLS", 0
CFA_CLS:        .WORD       CLS_WORD

DICT_TICKS:     .WORD       DICT_COLON
                .WORD       5
                .TEXT       "TICKS", 0
CFA_TICKS:      .WORD       TICKS_WORD

; --- Existing chain follows (DICT_COLON onward) ---

DICT_COLON:     .WORD       DICT_SEMI
                .WORD       1
                .TEXT       ":", 0
CFA_COLON:      .WORD       COLON

DICT_SEMI:      .WORD       DICT_IF
                .WORD       $81             ; IMMEDIATE
                .TEXT       ";", 0
CFA_SEMI:       .WORD       SEMICOLON

; --- Conditionals ---

DICT_IF:        .WORD       DICT_ELSE
                .WORD       $82             ; IMMEDIATE
                .TEXT       "IF"
CFA_IF:         .WORD       IF_COMP

DICT_ELSE:      .WORD       DICT_THEN
                .WORD       $84
                .TEXT       "ELSE"
CFA_ELSE:       .WORD       ELSE_COMP

DICT_THEN:      .WORD       DICT_BEGIN
                .WORD       $84
                .TEXT       "THEN"
CFA_THEN:       .WORD       THEN_COMP

; --- Loops (indefinite) ---

DICT_BEGIN:     .WORD       DICT_UNTIL
                .WORD       $85
                .TEXT       "BEGIN", 0
CFA_BEGIN:      .WORD       BEGIN_COMP

DICT_UNTIL:     .WORD       DICT_WHILE
                .WORD       $85
                .TEXT       "UNTIL", 0
CFA_UNTIL:      .WORD       UNTIL_COMP

DICT_WHILE:     .WORD       DICT_REPEAT
                .WORD       $85
                .TEXT       "WHILE", 0
CFA_WHILE:      .WORD       WHILE_COMP

DICT_REPEAT:    .WORD       DICT_AGAIN
                .WORD       $86
                .TEXT       "REPEAT"
CFA_REPEAT:     .WORD       REPEAT_COMP

DICT_AGAIN:     .WORD       DICT_DO
                .WORD       $85
                .TEXT       "AGAIN", 0
CFA_AGAIN:      .WORD       AGAIN_COMP

; --- Loops (counted) ---

DICT_DO:        .WORD       DICT_LOOP
                .WORD       $82
                .TEXT       "DO"
CFA_DO_DICT:    .WORD       DO_COMP

DICT_LOOP:      .WORD       DICT_PLOOP
                .WORD       $84
                .TEXT       "LOOP"
CFA_LOOP_DICT:  .WORD       LOOP_COMP

DICT_PLOOP:     .WORD       DICT_I
                .WORD       $85
                .TEXT       "+LOOP", 0
CFA_PLOOP_DICT: .WORD       PLOOP_COMP

DICT_I:         .WORD       DICT_J
                .WORD       1
                .TEXT       "I", 0
CFA_I:          .WORD       I_WORD

DICT_J:         .WORD       DICT_LBRACKET
                .WORD       1
                .TEXT       "J", 0
CFA_J:          .WORD       J_WORD

; --- Mode switches ---

DICT_LBRACKET:  .WORD       DICT_RBRACKET
                .WORD       $81
                .TEXT       "[", 0
CFA_LBRACKET:   .WORD       LBRACKET_COMP

DICT_RBRACKET:  .WORD       DICT_LITERAL
                .WORD       1
                .TEXT       "]", 0
CFA_RBRACKET:   .WORD       RBRACKET_WORD

DICT_LITERAL:   .WORD       DICT_TICK
                .WORD       $87
                .TEXT       "LITERAL", 0
CFA_LITERAL:    .WORD       LITERAL_COMP

; --- Word-as-data ---

DICT_TICK:      .WORD       DICT_BTICK
                .WORD       1
                .TEXT       "'", 0
CFA_TICK:       .WORD       TICK_WORD

DICT_BTICK:     .WORD       DICT_EXECUTE
                .WORD       $83
                .TEXT       "[']", 0
CFA_BTICK:      .WORD       BTICK_COMP

DICT_EXECUTE:   .WORD       DICT_RECURSE
                .WORD       7
                .TEXT       "EXECUTE", 0
CFA_EXECUTE:    .WORD       EXECUTE_WORD

DICT_RECURSE:   .WORD       DICT_IMMEDIATE
                .WORD       $87
                .TEXT       "RECURSE", 0
CFA_RECURSE:    .WORD       RECURSE_COMP

DICT_IMMEDIATE: .WORD       DICT_HERE
                .WORD       9
                .TEXT       "IMMEDIATE", 0
CFA_IMMEDIATE:  .WORD       IMMEDIATE_WORD

; --- Dictionary inspection / building ---

DICT_HERE:      .WORD       DICT_ALLOT
                .WORD       4
                .TEXT       "HERE"
CFA_HERE:       .WORD       HERE_WORD

DICT_ALLOT:     .WORD       DICT_COMMA
                .WORD       5
                .TEXT       "ALLOT", 0
CFA_ALLOT:      .WORD       ALLOT_WORD

DICT_COMMA:     .WORD       DICT_CCOMMA
                .WORD       1
                .TEXT       ",", 0
CFA_COMMA:      .WORD       COMMA_WORD

DICT_CCOMMA:    .WORD       DICT_BYE
                .WORD       2
                .TEXT       "C,"
CFA_CCOMMA:     .WORD       CCOMMA_WORD

; --- Existing chain follows ---

DICT_BYE:       .WORD       DICT_DOT
                .WORD       3                   ; len=3
                .TEXT       "BYE", 0
CFA_BYE:        .WORD       BYE_WORD

DICT_DOT:       .WORD       DICT_HEX
                .WORD       1
                .TEXT       ".", 0
CFA_DOT:        .WORD       DOT

DICT_HEX:       .WORD       DICT_DECIMAL
                .WORD       3
                .TEXT       "HEX", 0
CFA_HEX:        .WORD       HEX_WORD

DICT_DECIMAL:   .WORD       DICT_DUP
                .WORD       7
                .TEXT       "DECIMAL", 0
CFA_DECIMAL:    .WORD       DECIMAL_WORD

DICT_DUP:       .WORD       DICT_DROP
                .WORD       3
                .TEXT       "DUP", 0
CFA_DUP:        .WORD       DUP

DICT_DROP:      .WORD       DICT_SWAP
                .WORD       4
                .TEXT       "DROP"
CFA_DROP:       .WORD       DROP

DICT_SWAP:      .WORD       DICT_OVER
                .WORD       4
                .TEXT       "SWAP"
CFA_SWAP:       .WORD       SWAP_PRIM

DICT_OVER:      .WORD       DICT_ROT
                .WORD       4
                .TEXT       "OVER"
CFA_OVER:       .WORD       OVER

DICT_ROT:       .WORD       DICT_MINUSROT
                .WORD       3
                .TEXT       "ROT", 0
CFA_ROT:        .WORD       ROT

DICT_MINUSROT:  .WORD       DICT_NIP
                .WORD       4
                .TEXT       "-ROT"
CFA_MINUSROT:   .WORD       MINUSROT

DICT_NIP:       .WORD       DICT_TUCK
                .WORD       3
                .TEXT       "NIP", 0
CFA_NIP:        .WORD       NIP

DICT_TUCK:      .WORD       DICT_QDUP
                .WORD       4
                .TEXT       "TUCK"
CFA_TUCK:       .WORD       TUCK

DICT_QDUP:      .WORD       DICT_TWODUP
                .WORD       4
                .TEXT       "?DUP"
CFA_QDUP:       .WORD       QDUP

DICT_TWODUP:    .WORD       DICT_TWODROP
                .WORD       4
                .TEXT       "2DUP"
CFA_TWODUP:     .WORD       TWODUP

DICT_TWODROP:   .WORD       DICT_TWOSWAP
                .WORD       5
                .TEXT       "2DROP", 0
CFA_TWODROP:    .WORD       TWODROP

DICT_TWOSWAP:   .WORD       DICT_TWOOVER
                .WORD       5
                .TEXT       "2SWAP", 0
CFA_TWOSWAP:    .WORD       TWOSWAP

DICT_TWOOVER:   .WORD       DICT_PICK
                .WORD       5
                .TEXT       "2OVER", 0
CFA_TWOOVER:    .WORD       TWOOVER

DICT_PICK:      .WORD       DICT_DEPTH
                .WORD       4
                .TEXT       "PICK"
CFA_PICK:       .WORD       PICK

DICT_DEPTH:     .WORD       DICT_TOR
                .WORD       5
                .TEXT       "DEPTH", 0
CFA_DEPTH:      .WORD       DEPTH

DICT_TOR:       .WORD       DICT_RFROM
                .WORD       2
                .TEXT       ">R"
CFA_TOR:        .WORD       TOR

DICT_RFROM:     .WORD       DICT_RFETCH
                .WORD       2
                .TEXT       "R>"
CFA_RFROM:      .WORD       RFROM

DICT_RFETCH:    .WORD       DICT_PLUS
                .WORD       2
                .TEXT       "R@"
CFA_RFETCH:     .WORD       RFETCH

DICT_PLUS:      .WORD       DICT_MINUS
                .WORD       1
                .TEXT       "+", 0
CFA_PLUS:       .WORD       PLUS

DICT_MINUS:     .WORD       DICT_STAR
                .WORD       1
                .TEXT       "-", 0
CFA_MINUS:      .WORD       MINUS

DICT_STAR:      .WORD       DICT_SLASH
                .WORD       1
                .TEXT       "*", 0
CFA_STAR:       .WORD       STAR

DICT_SLASH:     .WORD       DICT_MOD
                .WORD       1
                .TEXT       "/", 0
CFA_SLASH:      .WORD       SLASH_WORD

DICT_MOD:       .WORD       DICT_SLASHMOD
                .WORD       3
                .TEXT       "MOD", 0
CFA_MOD:        .WORD       MOD_WORD

DICT_SLASHMOD:  .WORD       DICT_ONEPLUS
                .WORD       4
                .TEXT       "/MOD"
CFA_SLASHMOD:   .WORD       SLASHMOD_WORD

DICT_ONEPLUS:   .WORD       DICT_ONEMINUS
                .WORD       2
                .TEXT       "1+"
CFA_ONEPLUS:    .WORD       ONEPLUS

DICT_ONEMINUS:  .WORD       DICT_TWOSTAR
                .WORD       2
                .TEXT       "1-"
CFA_ONEMINUS:   .WORD       ONEMINUS

DICT_TWOSTAR:   .WORD       DICT_TWOSLASH
                .WORD       2
                .TEXT       "2*"
CFA_TWOSTAR:    .WORD       TWOSTAR

DICT_TWOSLASH:  .WORD       DICT_NEGATE
                .WORD       2
                .TEXT       "2/"
CFA_TWOSLASH:   .WORD       TWOSLASH

DICT_NEGATE:    .WORD       DICT_ABS
                .WORD       6
                .TEXT       "NEGATE"
CFA_NEGATE:     .WORD       NEGATE

DICT_ABS:       .WORD       DICT_MIN
                .WORD       3
                .TEXT       "ABS", 0
CFA_ABS:        .WORD       ABSS

DICT_MIN:       .WORD       DICT_MAX
                .WORD       3
                .TEXT       "MIN", 0
CFA_MIN:        .WORD       MIN

DICT_MAX:       .WORD       DICT_AND
                .WORD       3
                .TEXT       "MAX", 0
CFA_MAX:        .WORD       MAX

DICT_AND:       .WORD       DICT_OR
                .WORD       3
                .TEXT       "AND", 0
CFA_AND:        .WORD       ANDD

DICT_OR:        .WORD       DICT_XOR
                .WORD       2
                .TEXT       "OR"
CFA_OR:         .WORD       ORR

DICT_XOR:       .WORD       DICT_INVERT
                .WORD       3
                .TEXT       "XOR", 0
CFA_XOR:        .WORD       XORR

DICT_INVERT:    .WORD       DICT_ZEQU
                .WORD       6
                .TEXT       "INVERT"
CFA_INVERT:     .WORD       INVERT

DICT_ZEQU:      .WORD       DICT_ZLESS
                .WORD       2
                .TEXT       "0="
CFA_ZEQU:       .WORD       ZEQU

DICT_ZLESS:     .WORD       DICT_ZGREAT
                .WORD       2
                .TEXT       "0<"
CFA_ZLESS:      .WORD       ZLESS

DICT_ZGREAT:    .WORD       DICT_EQU
                .WORD       2
                .TEXT       "0>"
CFA_ZGREAT:     .WORD       ZGREAT

DICT_EQU:       .WORD       DICT_NOTEQ
                .WORD       1
                .TEXT       "=", 0
CFA_EQU:        .WORD       EQU

DICT_NOTEQ:     .WORD       DICT_LESS
                .WORD       2
                .TEXT       "<>"
CFA_NOTEQ:      .WORD       NOTEQ

DICT_LESS:      .WORD       DICT_GREATER
                .WORD       1
                .TEXT       "<", 0
CFA_LESS:       .WORD       LESS

DICT_GREATER:   .WORD       DICT_LESSEQ
                .WORD       1
                .TEXT       ">", 0
CFA_GREATER:    .WORD       GREATER

DICT_LESSEQ:    .WORD       DICT_GREATEQ
                .WORD       2
                .TEXT       "<="
CFA_LESSEQ:     .WORD       LESSEQ

DICT_GREATEQ:   .WORD       DICT_ULESS
                .WORD       2
                .TEXT       ">="
CFA_GREATEQ:    .WORD       GREATEQ

DICT_ULESS:     .WORD       DICT_UGREAT
                .WORD       2
                .TEXT       "U<"
CFA_ULESS:      .WORD       ULESS

DICT_UGREAT:    .WORD       DICT_FETCH
                .WORD       2
                .TEXT       "U>"
CFA_UGREAT:     .WORD       UGREAT

DICT_FETCH:     .WORD       DICT_STORE
                .WORD       1
                .TEXT       "@", 0
CFA_FETCH:      .WORD       FETCH

DICT_STORE:     .WORD       DICT_CFETCH
                .WORD       1
                .TEXT       "!", 0
CFA_STORE:      .WORD       STORE

DICT_CFETCH:    .WORD       DICT_CSTORE
                .WORD       2
                .TEXT       "C@"
CFA_CFETCH:     .WORD       CFETCH

DICT_CSTORE:    .WORD       DICT_PLUSSTORE
                .WORD       2
                .TEXT       "C!"
CFA_CSTORE:     .WORD       CSTORE

DICT_PLUSSTORE: .WORD       DICT_EMIT
                .WORD       2
                .TEXT       "+!"
CFA_PLUSSTORE:  .WORD       PLUSSTORE

DICT_EMIT:      .WORD       DICT_KEY
                .WORD       4
                .TEXT       "EMIT"
CFA_EMIT:       .WORD       EMIT

DICT_KEY:       .WORD       DICT_CR
                .WORD       3
                .TEXT       "KEY", 0
CFA_KEY:        .WORD       KEY

DICT_CR:        .WORD       DICT_SPACE
                .WORD       2
                .TEXT       "CR"
CFA_CR:         .WORD       CR

DICT_SPACE:     .WORD       0                   ; END OF CHAIN
                .WORD       5
                .TEXT       "SPACE", 0
CFA_SPACE:      .WORD       SPACE

; ============================================================================
; MAIN — Entry point
; ============================================================================

MAIN:
                ; Anchor X3 at kernel-supplied entry stack first.
                LOADI       X3, #COM_STACK_TOP

                ; ---- Y-MIRROR RULE ----
                ; Y3 holds our task page (kernel-set, do NOT touch).
                ; Mirror Y3 into Y0, Y1, Y2 so all [XY0..XY2] addressing
                ; reaches our page automatically.  After this point NO
                ; primitive touches any Y register.
                MOVE        Y0, Y3
                MOVE        Y1, Y3
                MOVE        Y2, Y3

                ; Register as a Phase B shell (alloc back-buffer, splice
                ; into shell ring after kosh).  Must precede any output.
                TRAP        #TRAP_REGISTER_SHELL
                BCC.S       .reg_ok
                LOADI       D0, #99
                TRAP        #TRAP_EXIT
.reg_ok:
                ; Re-mirror Y0/Y1/Y2 — TRAPs clobber Y0/Y1 (V2 ABI only
                ; preserves D2, D3, XY2).  Y2 survives because XY2 is
                ; callee-saved, but re-set it for safety/clarity.
                MOVE        Y0, Y3
                MOVE        Y1, Y3
                MOVE        Y2, Y3

                ; Init Forth stacks (Y2 already mirrors Y3 from above).
                LOADI       X2, #DSTACK_TOP
                LOADI       X3, #RSTACK_TOP

                ; Init ZP variables — all now 16-bit, single STOREP each.
                LOADI       D0, #DICT_DOTQUOTE  ; LATEST = head of built-in dict
                STOREP      D0, Y3, [#ZP_LATEST]
                LOADI       D0, #HERE_BASE
                STOREP      D0, Y3, [#ZP_HERE]
                LOADI       D0, #0
                STOREP      D0, Y3, [#ZP_STATE]
                LOADI       D0, #10
                STOREP      D0, Y3, [#ZP_BASE]
                LOADI       D0, #0
                STOREP      D0, Y3, [#ZP_TOIN]
                MOVE        D0, Y3              ; DUMPPAGE defaults to our own
                STOREP      D0, Y3, [#ZP_DUMPPAGE]

                ; --- NOTE: init_dict_pages DELETED.  No boot-time patching
                ;     is needed; assembler resolved all dict links as
                ;     16-bit page-relative at assembly time. ---

                ; Print banner.  sys_puts wants XY0 = pointer.
                LOADI       X0, #BANNER
                TRAP        #TRAP_PUTS
                MOVE        Y0, Y3              ; re-mirror after TRAP
                MOVE        Y1, Y3

                ; Fall through to QUIT (outer interpreter — TBD in next phase).
                JMP16       QUIT

; ============================================================================
; QUIT — Outer interpreter loop
; ============================================================================
; Reads a line, runs interpret, prints " ok" if interpreting succeeded.
; On error: jumps to QUIT_ERROR which prints " ?" and restarts.

QUIT:
                ; Reset stacks within our page (X2 only — Y2 unchanged
                ; because XY2 is callee-saved across TRAPs).
                LOADI       X2, #DSTACK_TOP
                LOADI       X3, #RSTACK_TOP

.quit_loop:
                ; Print prompt
                LOADI       X0, #STR_PROMPT
                TRAP        #TRAP_PUTS
                MOVE        Y0, Y3
                MOVE        Y1, Y3

                ; Read a line into TIB
                CALL16      accept_line

                ; Reset >IN for parsing
                LOADI       D0, #0
                STOREP      D0, Y3, [#ZP_TOIN]

                ; Run the interpreter
                CALL16      interpret

                ; Print " ok" only if in interpret mode (STATE=0)
                LOADP       D0, Y3, [#ZP_STATE]
                CMP         D0, #0
                BNE         .quit_loop          ; still compiling — skip ok

                LOADI       X0, #STR_OK
                TRAP        #TRAP_PUTS
                MOVE        Y0, Y3
                MOVE        Y1, Y3

                BRA         .quit_loop

; Error entry — prints " ?" and restarts
QUIT_ERROR:
                LOADI       X0, #STR_ERROR
                TRAP        #TRAP_PUTS
                MOVE        Y0, Y3
                MOVE        Y1, Y3
                ; Reset STATE in case we were compiling
                LOADI       D0, #0
                STOREP      D0, Y3, [#ZP_STATE]
                BRA         QUIT

; ============================================================================
; accept_line — Read a line from keyboard into TIB
; ============================================================================
; Reads until CR/LF. Stores nul-terminated string at task_page:TIB_OFFSET.
; Stores count (excluding nul) at ZP_NUMTIB.
; Echoes each character via sys_putchar.
;
; Register usage:
;   D2 = char count
;   D3 = TIB write offset within page
;   D2/D3 callee-saved across TRAPs by V2 ABI, so they survive each loop.
;
; Y-mirror discipline: after every TRAP, MOVE Y0,Y3 (Y1 doesn't matter
; here since we don't return to NEXT — this is CALL-mode).

accept_line:
                LOADI       D2, #0              ; count
                LOADI       D3, #TIB_OFFSET     ; current TIB position

.acc_loop:
                TRAP        #TRAP_GETCHAR       ; D0 = byte (blocks)
                MOVE        Y0, Y3              ; restore Y0 (TRAP clobbered)
                AND         D0, #$FF            ; defensive mask

                ; Check for Enter (CR or LF)
                CMP         D0, #$0D
                BEQ         .acc_done
                CMP         D0, #$0A
                BEQ         .acc_done

                ; Check for backspace / DEL
                CMP         D0, #$08
                BEQ         .acc_back
                CMP         D0, #$7F
                BEQ         .acc_back

                ; Buffer-full check (cap at ~80 chars)
                CMP         D2, #80
                BCS         .acc_loop           ; silently discard

                ; Store char in TIB at [Y3:D3]. Y0 already = Y3.
                MOVE        X0, D3
                STOREB      D0, [XY0]

                ADD         D3, #1
                ADD         D2, #1

                ; Echo character
                TRAP        #TRAP_PUTCHAR
                MOVE        Y0, Y3              ; restore after TRAP
                BRA         .acc_loop

.acc_back:
                CMP         D2, #0
                BEQ         .acc_loop           ; nothing to delete

                SUB         D3, #1
                SUB         D2, #1

                ; Echo BS-SPACE-BS
                LOADI       D0, #$08
                TRAP        #TRAP_PUTCHAR
                MOVE        Y0, Y3
                LOADI       D0, #$20
                TRAP        #TRAP_PUTCHAR
                MOVE        Y0, Y3
                LOADI       D0, #$08
                TRAP        #TRAP_PUTCHAR
                MOVE        Y0, Y3
                BRA         .acc_loop

.acc_done:
                ; Null-terminate at TIB[count]
                MOVE        X0, D3
                LOADI       D0, #0
                STOREB      D0, [XY0]

                ; Save count
                STOREP      D2, Y3, [#ZP_NUMTIB]

                ; Echo newline
                LOADI       D0, #$0A
                TRAP        #TRAP_PUTCHAR
                MOVE        Y0, Y3
                RET

; ============================================================================
; parse_word — Pull next whitespace-delimited token from TIB
; ============================================================================
; Reads from TIB starting at >IN, skips leading spaces, copies word
; to WORD_BUF, nul-terminates, advances >IN past the word.
;
; Returns: D2 = WORD_BUF_OFF (addr), D3 = length (0 if end of input).
;
; No TRAPs in this routine — so Y0 only needs to be set once at entry
; and never restored.

parse_word:
                ; Get >IN
                LOADP       D0, Y3, [#ZP_TOIN]

                ; Setup TIB pointer (Y0 already = Y3 from caller, but be
                ; explicit since parse_word is called after CALL16 which
                ; doesn't touch Y0 anyway).
                LOADI       X0, #TIB_OFFSET
                ADD         X0, D0              ; X0 = TIB + >IN

                ; Skip leading spaces
.pw_skip:       LOADB       D0, [XY0]
                CMP         D0, #0
                BEQ         .pw_empty
                CMP         D0, #$20
                BNE         .pw_start
                ADD         X0, #1
                BRA         .pw_skip

.pw_start:
                MOVE        D2, X0              ; D2 = word start in TIB
                LOADI       D3, #0              ; length = 0
                LOADI       D1, #WORD_BUF_OFF   ; D1 = word buffer write pos

.pw_copy:       LOADB       D0, [XY0]
                CMP         D0, #0
                BEQ         .pw_done
                CMP         D0, #$20
                BEQ         .pw_done

                ; Copy char to WORD_BUF[D1]
                ; Stash X0 because we need to use it for the buffer write
                PUSH        X0, XY3
                MOVE        X0, D1
                STOREB      D0, [XY0]
                POP         X0, XY3

                ADD         X0, #1              ; advance TIB ptr
                ADD         D1, #1              ; advance buffer write pos
                ADD         D3, #1              ; len++

                CMP         D3, #31
                BCS         .pw_done            ; cap word length
                BRA         .pw_copy

.pw_done:
                ; Nul-terminate WORD_BUF
                PUSH        X0, XY3
                MOVE        X0, D1
                LOADI       D0, #0
                STOREB      D0, [XY0]
                POP         X0, XY3

                ; Update >IN
                MOVE        D0, X0
                SUB         D0, #TIB_OFFSET
                STOREP      D0, Y3, [#ZP_TOIN]

                LOADI       D2, #WORD_BUF_OFF   ; D2 = addr of parsed word
                RET

.pw_empty:
                LOADI       D2, #0
                LOADI       D3, #0
                RET

; ============================================================================
; parse_number — Try to parse D2/D3 as a number
; ============================================================================
; In:  D2 = addr (within our page), D3 = length
; Out: D0 = parsed number (if success), D1 = TRUE/FALSE
;
; Supports negative sign and $-hex prefix.
;
; Register usage during parse:
;   X0  = byte ptr (Y0 = Y3)
;   D3  = remaining length
;   D1  = negative flag (1 = negate, 0 = positive)
;   D2  = success indicator returned by sub-parser (1 = ok, 0 = bad)
;        and accumulator inside sub-parsers
;
; The sub-parsers .pn_parse_dec / .pn_parse_hex return:
;   D0 = parsed value
;   D2 = success ($FFFF) or fail (0)
;
; We use D2 (not D1) for parser success so that D1 stays free to hold
; the negative flag across the call without needing a stack save (which
; was the source of a latent bug earlier).

parse_number:
                CMP         D3, #0
                BEQ         .pn_fail

                MOVE        X0, D2              ; X0 = byte ptr; Y0 = Y3

                LOADI       D1, #0              ; D1 = negative flag (0 = positive)
                LOADB       D0, [XY0]
                CMP         D0, #$2D            ; '-' ?
                BNE         .pn_chk_hex
                LOADI       D1, #1              ; negative = true
                ADD         X0, #1
                SUB         D3, #1
                CMP         D3, #0
                BEQ         .pn_fail            ; lone '-' is not a number
                LOADB       D0, [XY0]

.pn_chk_hex:
                CMP         D0, #$24            ; '$' ?
                BNE         .pn_dec_path
                ADD         X0, #1
                SUB         D3, #1
                CMP         D3, #0
                BEQ         .pn_fail            ; lone '$' is not a number
                CALL16      .pn_parse_hex
                BRA         .pn_check_success

.pn_dec_path:
                CALL16      .pn_parse_dec
                ; fall through

.pn_check_success:
                ; D0 = value, D2 = success flag from sub-parser
                CMP         D2, #0
                BEQ         .pn_fail

                ; Apply sign
                CMP         D1, #0
                BEQ         .pn_ok              ; positive — done
                LOADI       D2, #0
                SUB         D2, D0              ; D2 = -D0
                MOVE        D0, D2

.pn_ok:
                LOADI       D1, #$FFFF          ; success
                RET

.pn_fail:
                LOADI       D0, #0
                LOADI       D1, #0              ; failure
                RET

; --- Hex parser sub-routine
; In:  X0 = ptr, D3 = remaining length, Y0 = Y3
; Out: D0 = value, D2 = $FFFF on success, 0 on bad digit
; Clobbers D0, D2, X0, D3

.pn_parse_hex:
                LOADI       D2, #0              ; accumulator
.pnh_loop:      CMP         D3, #0
                BEQ         .pnh_ok
                LOADB       D0, [XY0]

                ; Hex digit?
                CMP         D0, #$30
                BCC         .pnh_fail           ; < '0'
                CMP         D0, #$3A
                BCS         .pnh_alpha          ; >= ':' — try letter
                SUB         D0, #$30            ; 0-9
                BRA         .pnh_acc

.pnh_alpha:     ; uppercase letter
                CMP         D0, #$61            ; 'a'?
                BCC         .pnh_uc
                CMP         D0, #$7B            ; > 'z'?
                BCS         .pnh_uc
                AND         D0, #$DF            ; lowercase → upper
.pnh_uc:        CMP         D0, #$41            ; < 'A'?
                BCC         .pnh_fail
                CMP         D0, #$47            ; >= 'G'?
                BCS         .pnh_fail
                SUB         D0, #$37            ; 'A'($41) → 10

.pnh_acc:       ; D2 = D2 * 16 + D0
                ADD         D2, D2              ; *2
                ADD         D2, D2              ; *4
                ADD         D2, D2              ; *8
                ADD         D2, D2              ; *16
                ADD         D2, D0
                ADD         X0, #1
                SUB         D3, #1
                BRA         .pnh_loop

.pnh_ok:        MOVE        D0, D2
                LOADI       D2, #$FFFF          ; success
                RET
.pnh_fail:
                LOADI       D0, #0
                LOADI       D2, #0              ; failure
                RET

; --- Decimal parser sub-routine
; In:  X0 = ptr, D3 = remaining length, Y0 = Y3
; Out: D0 = value, D2 = $FFFF on success, 0 on bad digit

.pn_parse_dec:
                LOADI       D2, #0              ; accumulator
.pnd_loop:      CMP         D3, #0
                BEQ         .pnd_ok
                LOADB       D0, [XY0]
                CMP         D0, #$30
                BCC         .pnd_fail
                CMP         D0, #$3A
                BCS         .pnd_fail
                SUB         D0, #$30

                ; D2 = D2 * 10 + D0
                ; D2*10 = D2*5 doubled = (D2*4 + D2) doubled.
                ; We need a scratch register for the "+D2" step.
                ;
                ; *** D1 is NOT free here — parse_number's outer scope uses
                ; *** D1 as the negative-sign flag.  Clobbering it caused
                ; *** every multi-digit decimal to be negated.  Save/restore.
                PUSH        D1, XY3             ; preserve outer D1 (sign flag)
                PUSH        X0, XY3
                MOVE        D1, D2              ; D1 = D2 (scratch)
                ADD         D2, D2              ; D2 = D2*2
                ADD         D2, D2              ; D2 = D2*4
                ADD         D2, D1              ; D2 = D2*5
                ADD         D2, D2              ; D2 = D2*10
                ADD         D2, D0              ; D2 += digit
                POP         X0, XY3
                POP         D1, XY3             ; restore outer D1 (sign flag)

                ADD         X0, #1
                SUB         D3, #1
                BRA         .pnd_loop

.pnd_ok:        MOVE        D0, D2
                LOADI       D2, #$FFFF
                RET
.pnd_fail:
                LOADI       D0, #0
                LOADI       D2, #0
                RET

; ============================================================================
; find_word — Search dict for the named word
; ============================================================================
; In:  data stack:  addr (word ptr), len  (pushed in that order)
;      pops both.
; Out: D0 = found flag ($FFFF found, 0 not found)
;      D1 = CFA address (16-bit, page-relative)
;      D2 = flags+len word from dict (for IMMEDIATE check)
;
; Walks the chain via 16-bit Link words. Y0 = Y3 throughout (no TRAPs).

find_word:
                POP         D3, XY2             ; D3 = len
                POP         D2, XY2             ; D2 = word ptr in our page

                ; Load LATEST → X0
                LOADP       D0, Y3, [#ZP_LATEST]
                MOVE        X0, D0              ; Y0 = Y3 already

.fw_loop:
                ; End-of-chain test: X0 = 0 means we walked off the end.
                MOVE        D0, X0
                CMP         D0, #0
                BEQ         .fw_notfound

                ; Save D2/D3 (word ptr + len) and entry start so we can
                ; restore them per-iteration if the name compare mismatches.
                ; D2 gets advanced by the inner compare loop; without
                ; restoring it we'd start the next entry's compare from
                ; partway into WORD_BUF.
                PUSH        X0, XY3             ; entry start
                PUSH        D2, XY3             ; word buffer ptr
                PUSH        D3, XY3             ; word length

                ; Read flags+len at entry+2 ; compare lengths
                ADD         X0, #2
                LOADD       D1, [XY0]
                AND         D1, #$3F            ; mask out flag bits
                SUB         X0, #2

                CMP         D1, D3
                BNE         .fw_next            ; length mismatch → next

                ; Length matches — set up name compare.
                ADD         X0, #4              ; X0 → dict name
                MOVE        D1, D3              ; D1 = char counter

.fw_cmp:        CMP         D1, #0
                BEQ         .fw_match

                ; Dict char (X0 points into dict name)
                LOADB       D0, [XY0]
                ADD         X0, #1

                ; Word char (D2 points into WORD_BUF)
                PUSH        X0, XY3             ; stash dict ptr
                MOVE        X0, D2
                LOADB       D3, [XY0]
                ADD         D2, #1
                POP         X0, XY3             ; restore dict ptr

                ; Uppercase both for case-insensitive compare
                CMP         D0, #$61
                BCC         .fw_uc1
                CMP         D0, #$7B
                BCS         .fw_uc1
                AND         D0, #$DF
.fw_uc1:        CMP         D3, #$61
                BCC         .fw_uc2
                CMP         D3, #$7B
                BCS         .fw_uc2
                AND         D3, #$DF
.fw_uc2:        CMP         D0, D3
                BNE         .fw_next            ; mismatch → next entry

                SUB         D1, #1
                BRA         .fw_cmp

.fw_match:
                ; Pop per-iteration saves.  We don't need them on the
                ; match path, but they're on the stack.
                POP         D3, XY3             ; (discard saved len)
                POP         D2, XY3             ; (discard saved word ptr)
                POP         X0, XY3             ; X0 = entry start (restored)

                ; Reload flags+len for return
                ADD         X0, #2
                LOADD       D2, [XY0]           ; D2 = flags+len
                SUB         X0, #2

                ; Compute CFA address: CFA = entry + 4 + len, word-aligned
                MOVE        D1, D2
                AND         D1, #$3F            ; D1 = name length
                MOVE        D0, X0              ; D0 = entry start
                ADD         D0, #4              ; past Link + flags+len
                ADD         D0, D1              ; past name
                ADD         D0, #1
                AND         D0, #$FFFE          ; word-align
                MOVE        D1, D0              ; D1 = CFA address (return)

                LOADI       D0, #$FFFF          ; found = true
                RET

.fw_next:
                ; Restore D2/D3/X0 from per-iteration saves
                POP         D3, XY3             ; len
                POP         D2, XY3             ; word ptr
                POP         X0, XY3             ; entry start

                ; Follow Link (16-bit word at entry+0)
                LOADD       D0, [XY0]           ; D0 = next entry addr
                MOVE        X0, D0
                BRA         .fw_loop

.fw_notfound:
                LOADI       D0, #0              ; not found
                RET

; ============================================================================
; exec_prim — Execute a primitive (or colon word) from CALL-mode interpreter
; ============================================================================
; In:  D1 = CFA address (16-bit, in our page)
;
; Builds a 2-cell thread [word-CFA][STOP-CFA] in ZP_CALL_BUF, points IP at
; it, jumps to NEXT.  The word runs; when it returns control via NEXT, it
; hits the STOP cell, which BRA's back to int_loop.
;
; Y0/Y1 must equal Y3 before entry (they always do here — called from
; interpret via CALL16, no TRAP between).  exec_prim never returns
; conventionally — STOP transfers via BRA, not RET.

exec_prim:
                ; Store word's CFA at ZP_CALL_BUF
                STOREP      D1, Y3, [#ZP_CALL_BUF]

                ; Store STOP CFA at ZP_CALL_BUF + 2
                LOADI       D0, #CFA_STOP
                STOREP      D0, Y3, [#ZP_CALL_BUF+2]

                ; Set IP = ZP_CALL_BUF.  Y1 = Y3 already.
                LOADI       X1, #ZP_CALL_BUF

                ; Drop into the threaded interpreter
                BRA         NEXT

; STOP — sentinel CFA that returns control to int_loop.
;
; When interpret does `CALL16 exec_prim`, K16 pushes a 24-bit return
; address (4 bytes) on XY3.  exec_prim never RETs — it BRAs into NEXT,
; the word runs, and eventually STOP fires.  At this point the exec_prim
; return frame is still on the stack and needs cleanup; otherwise N words
; = 4N bytes of slow stack growth until QUIT_ERROR resets X3.
;
; Discard the leaked return frame before BRA'ing back into int_loop.
CFA_STOP:       .WORD       STOP
STOP:
                ADD         X3, #4              ; discard exec_prim's CALL16 frame
                BRA         int_loop

; ============================================================================
; interpret — Main classify-and-dispatch loop
; ============================================================================
; Reads words from TIB one at a time.  For each:
;   - if found in dict: execute it (interpret mode) or compile it (compile
;     mode, unless IMMEDIATE).
;   - else try as number: push it (interpret) or compile LIT+value (compile)
;   - else: jump to QUIT_ERROR.

interpret:
int_loop:
                CALL16      parse_word
                CMP         D3, #0
                BEQ         .int_done

                ; Save addr/len on return stack for the parse_number
                ; fallback path (find_word will pop the data stack copy
                ; and clobber D2/D3 anyway).
                PUSH        D2, XY3             ; addr
                PUSH        D3, XY3             ; len

                ; Push addr/len to data stack for find_word
                PUSH        D2, XY2
                PUSH        D3, XY2
                CALL16      find_word

                ; D0 = found flag, D1 = CFA (if found), D2 = flags+len
                CMP         D0, #0
                BEQ         .int_try_number

                ; Found.  Discard the rstack-saved addr/len.
                ADD         X3, #4

                ; Decide execute vs compile based on STATE + IMMEDIATE
                LOADP       D0, Y3, [#ZP_STATE]
                CMP         D0, #0
                BEQ         .int_exec           ; interpret mode

                ; Compile mode.  IMMEDIATE words execute anyway.
                AND         D2, #$80            ; IMMEDIATE bit
                BNE         .int_exec
                CALL16      compile_cfa
                BRA         int_loop

.int_exec:
                CALL16      exec_prim
                ; exec_prim does NOT return — STOP routes back to int_loop

.int_try_number:
                ; find_word didn't match.  Restore addr/len.
                POP         D3, XY3             ; len
                POP         D2, XY3             ; addr
                CALL16      parse_number
                CMP         D1, #0
                BEQ         .int_error

                ; Number parsed in D0.  Push or compile depending on STATE.
                PUSH        D0, XY3             ; preserve across STATE load
                LOADP       D1, Y3, [#ZP_STATE]
                POP         D0, XY3
                CMP         D1, #0
                BEQ         .int_push_num

                ; Compile mode: emit [CFA_LIT][value].  D0 = value.
                PUSH        D0, XY3             ; stash value
                LOADI       D1, #CFA_LIT
                CALL16      compile_cfa
                LOADP       D1, Y3, [#ZP_HERE]
                MOVE        X0, D1
                POP         D0, XY3             ; recover value
                STORED      D0, [XY0]
                ADD         D1, #2
                STOREP      D1, Y3, [#ZP_HERE]
                BRA         int_loop

.int_push_num:
                PUSH        D0, XY2
                BRA         int_loop

.int_error:
                ; Reset STATE if compiling, jump to QUIT_ERROR.
                LOADI       D0, #0
                STOREP      D0, Y3, [#ZP_STATE]
                BRA         QUIT_ERROR

.int_done:
                RET

; ============================================================================
; BATCH 3 — Runtime threading: LIT, BRANCH, ZBRANCH, EXIT_WORD already exists
; ============================================================================
; v3.0 thread cells are 2 bytes (16-bit page-relative).  Branch offsets
; are 16-bit signed deltas applied to X1 AFTER the offset cell is consumed.
;
; LIT thread layout:    [LIT_CFA][value]                  4 bytes
; IF/UNTIL layout:      [ZBRANCH_CFA][offset]             4 bytes
; ELSE/AGAIN/REPEAT:    [BRANCH_CFA][offset]              4 bytes
;
; Offset semantics: after the offset is consumed, X1 += offset.  Forward
; branches use offset = target_HERE - placeholder_addr - 2.  Backward
; (BEGIN..UNTIL etc.) use offset = target_addr - HERE_after_offset.
;
; NOTE: v2.25 used 4-byte cells with separate Y/X words.  v3.0 halves them.

; --- compile_cfa: write a single 2-byte cell at HERE, advance HERE
; In:  D1 = CFA address (16-bit)
; Out: HERE += 2.  Clobbers D0, X0.
compile_cfa:
                LOADP       D0, Y3, [#ZP_HERE]
                MOVE        X0, D0
                STORED      D1, [XY0]
                ADD         D0, #2
                STOREP      D0, Y3, [#ZP_HERE]
                RET

; LIT is already defined in the inner interpreter section above.
; CFA_LIT is defined here so the compiler/interpreter can reference it.

CFA_LIT:        .WORD       LIT

; --- BRANCH: unconditional branch.  Inline cell = signed 16-bit offset.
BRANCH:
                LOADD       D0, [XY1]           ; D0 = offset
                ADD         X1, #2              ; consume offset cell
                ADD         X1, D0              ; IP += offset
                BRA         NEXT

CFA_BRANCH:     .WORD       BRANCH

; --- ZBRANCH: branch if popped value is zero.  Inline cell = offset.
ZBRANCH:
                POP         D0, XY2             ; flag
                LOADD       D1, [XY1]           ; offset (always read)
                ADD         X1, #2              ; consume offset cell
                CMP         D0, #0
                BNE         .zb_skip
                ADD         X1, D1              ; IP += offset (branch taken)
.zb_skip:       BRA         NEXT

CFA_ZBRANCH:    .WORD       ZBRANCH

; --- CFA_EXIT (referenced by SEMICOLON when compiling)
CFA_EXIT:       .WORD       EXIT_WORD

; ============================================================================
; DO / LOOP / +LOOP — runtime words.  Return stack frame: limit, then index.
; ============================================================================
; v3.0 frames are 4 bytes (2 words: limit + index).  v2.25 was 6 bytes.

; Runtime DO ( limit index -- ) R:( -- limit index )
DO_RT:
                POP         D0, XY2             ; index
                POP         D1, XY2             ; limit
                PUSH        D1, XY3             ; push limit
                PUSH        D0, XY3             ; push index (TOS of rstack)
                BRA         NEXT

CFA_DO:         .WORD       DO_RT

; Runtime LOOP: index++, branch back if index < limit
LOOP_RT:
                LOADD       D0, [XY3]           ; index
                LOADD       D1, [XY3 + #2]      ; limit
                ADD         D0, #1              ; index++
                STORED      D0, [XY3]
                CMP         D0, D1
                BGE         .loop_done
                ; Branch back: offset cell follows
                LOADD       D0, [XY1]
                ADD         X1, #2              ; consume offset cell
                ADD         X1, D0              ; IP += offset (negative)
                BRA         NEXT
.loop_done:     ADD         X3, #4              ; drop limit+index from rstack
                ADD         X1, #2              ; skip offset cell
                BRA         NEXT

CFA_LOOP:       .WORD       LOOP_RT

; Runtime +LOOP ( n -- ): index += n, branch back if index < limit
PLOOP_RT:
                POP         D2, XY2             ; increment
                LOADD       D0, [XY3]           ; index
                LOADD       D1, [XY3 + #2]      ; limit
                ADD         D0, D2              ; index += n
                STORED      D0, [XY3]
                CMP         D0, D1
                BGE         .ploop_done
                LOADD       D0, [XY1]
                ADD         X1, #2
                ADD         X1, D0
                BRA         NEXT
.ploop_done:    ADD         X3, #4
                ADD         X1, #2
                BRA         NEXT

CFA_PLOOP:      .WORD       PLOOP_RT

; I: copy loop index to dstack
I_WORD:         LOADD       D0, [XY3]
                PUSH        D0, XY2
                BRA         NEXT

; J: outer loop index (nested loop — frame above ours: skip 4 bytes)
J_WORD:         LOADD       D0, [XY3 + #4]
                PUSH        D0, XY2
                BRA         NEXT

; ============================================================================
; COLON — start a definition
; ============================================================================
; v3.0 dict entry: Link(2) + flags+len(2) + name(padded) + CFA(2)
; vs v2.25's 8-byte fixed-overhead + variable name.
;
; Saved 2 bytes per entry, and the build process gets much simpler:
; no 24-bit pointer reconstruction, just 16-bit stores.

COLON:
                CALL16      parse_word
                CMP         D3, #0
                BEQ         .colon_err

                ; D2 = WORD_BUF addr, D3 = name length.  Save for name copy.
                PUSH        D2, XY3
                PUSH        D3, XY3

                ; Snapshot LATEST for error recovery.
                LOADP       D0, Y3, [#ZP_LATEST]
                STOREP      D0, Y3, [#ZP_SAVED_LATEST]

                ; HERE will be the new entry start.  Use it as new LATEST.
                LOADP       D2, Y3, [#ZP_HERE]
                STOREP      D2, Y3, [#ZP_LATEST]    ; LATEST = HERE

                ; Build header at HERE
                MOVE        X0, D2              ; X0 = HERE; Y0 = Y3

                ; Link: old LATEST (D0 still has it)
                STORED      D0, [XY0]
                ADD         X0, #2

                ; Flags+len: just len for now (caller adds IMMEDIATE later via IMMEDIATE word)
                POP         D3, XY3             ; restore len
                POP         D2, XY3             ; restore WORD_BUF addr
                STORED      D3, [XY0]
                ADD         X0, #2

                ; Copy name bytes from WORD_BUF (D2) to dict (X0)
                MOVE        D1, D3              ; counter
.col_copy:
                CMP         D1, #0
                BEQ         .col_copy_done
                PUSH        X0, XY3             ; stash dict ptr
                MOVE        X0, D2
                LOADB       D0, [XY0]
                POP         X0, XY3             ; restore dict ptr
                STOREB      D0, [XY0]
                ADD         D2, #1
                ADD         X0, #1
                SUB         D1, #1
                BRA         .col_copy
.col_copy_done:

                ; Pad to even (word align for CFA that follows)
                ADD         X0, #1
                AND         X0, #$FFFE

                ; Store CFA = DOCOL
                LOADI       D0, #DOCOL
                STORED      D0, [XY0]
                ADD         X0, #2

                ; Update HERE
                MOVE        D0, X0
                STOREP      D0, Y3, [#ZP_HERE]

                ; STATE = 1 (compile)
                LOADI       D0, #1
                STOREP      D0, Y3, [#ZP_STATE]

                BRA         NEXT

.colon_err:
                ; No name after ':'.  Print ?, return to NEXT.
                PUSH        X1, XY3
                LOADI       D0, #$3F            ; '?'
                TRAP        #TRAP_PUTCHAR
                LOADI       D0, #$0A            ; '\n'
                TRAP        #TRAP_PUTCHAR
                POP         X1, XY3
                MOVE        Y0, Y3
                MOVE        Y1, Y3
                BRA         NEXT

; ============================================================================
; SEMICOLON — end a definition (IMMEDIATE)
; ============================================================================

SEMICOLON:
                ; Compile CFA_EXIT to terminate the colon body
                LOADI       D1, #CFA_EXIT
                CALL16      compile_cfa

                ; STATE = 0 (interpret)
                LOADI       D0, #0
                STOREP      D0, Y3, [#ZP_STATE]
                BRA         NEXT

; ============================================================================
; IF / ELSE / THEN  (all IMMEDIATE)
; ============================================================================
; v3.0 branch cells: just a 16-bit offset.  Compile-time IF leaves the
; placeholder's address on data stack; THEN/ELSE patch it.

IF_COMP:        ; IF ( -- placeholder-addr )  compile-time
                ; Compile ZBRANCH CFA
                LOADI       D1, #CFA_ZBRANCH
                CALL16      compile_cfa

                ; HERE is where the offset placeholder will go.  Push it.
                LOADP       D0, Y3, [#ZP_HERE]
                PUSH        D0, XY2

                ; Compile placeholder (a single 2-byte cell of zero)
                MOVE        X0, D0
                LOADI       D1, #0
                STORED      D1, [XY0]
                ADD         D0, #2
                STOREP      D0, Y3, [#ZP_HERE]

                BRA         NEXT

ELSE_COMP:      ; ELSE ( if-addr -- else-addr )  compile-time
                ; Compile BRANCH CFA (to skip the else clause)
                LOADI       D1, #CFA_BRANCH
                CALL16      compile_cfa

                ; HERE = address for ELSE's offset placeholder.  Save it.
                LOADP       D0, Y3, [#ZP_HERE]
                PUSH        D0, XY3             ; rstack: save ELSE's slot addr

                ; Compile ELSE's offset placeholder
                MOVE        X0, D0
                LOADI       D1, #0
                STORED      D1, [XY0]
                ADD         D0, #2
                STOREP      D0, Y3, [#ZP_HERE]   ; D0 = new HERE (target for IF)

                ; Patch IF's offset: IF branches HERE.  Offset = HERE - if_slot - 2.
                POP         D1, XY2             ; D1 = IF's placeholder addr
                SUB         D0, D1              ; D0 = HERE - if_slot
                SUB         D0, #2              ; - 2 (post-consume IP correction)
                MOVE        X0, D1
                STORED      D0, [XY0]

                ; Leave ELSE's slot addr on dstack for THEN
                POP         D0, XY3             ; from rstack
                PUSH        D0, XY2
                BRA         NEXT

THEN_COMP:      ; THEN ( placeholder-addr -- )  compile-time
                LOADP       D0, Y3, [#ZP_HERE]
                POP         D1, XY2             ; placeholder addr
                SUB         D0, D1              ; offset = HERE - placeholder
                SUB         D0, #2              ; - 2
                MOVE        X0, D1
                STORED      D0, [XY0]
                BRA         NEXT

; ============================================================================
; BEGIN / UNTIL / WHILE / REPEAT / AGAIN  (all IMMEDIATE)
; ============================================================================

BEGIN_COMP:     ; BEGIN ( -- here )  push HERE for back-references
                LOADP       D0, Y3, [#ZP_HERE]
                PUSH        D0, XY2
                BRA         NEXT

UNTIL_COMP:     ; UNTIL ( begin-addr -- )  compile ZBRANCH back to begin
                LOADI       D1, #CFA_ZBRANCH
                CALL16      compile_cfa

                ; Compile offset cell pointing back to begin
                LOADP       D0, Y3, [#ZP_HERE]   ; D0 = address of offset cell
                POP         D1, XY2              ; D1 = begin addr
                ; Offset such that after consume: X1 += offset → X1 = begin
                ; X1 after consume = D0 + 2.  We want X1 += offset = begin.
                ; offset = begin - (D0 + 2) = D1 - D0 - 2.
                SUB         D1, D0
                SUB         D1, #2               ; D1 = signed offset (negative)
                MOVE        X0, D0
                STORED      D1, [XY0]
                ADD         D0, #2
                STOREP      D0, Y3, [#ZP_HERE]
                BRA         NEXT

AGAIN_COMP:     ; AGAIN ( begin-addr -- )  compile BRANCH back (infinite loop)
                LOADI       D1, #CFA_BRANCH
                CALL16      compile_cfa

                LOADP       D0, Y3, [#ZP_HERE]
                POP         D1, XY2
                SUB         D1, D0
                SUB         D1, #2
                MOVE        X0, D0
                STORED      D1, [XY0]
                ADD         D0, #2
                STOREP      D0, Y3, [#ZP_HERE]
                BRA         NEXT

WHILE_COMP:     ; WHILE ( begin-addr -- begin-addr while-slot )
                ; Compile ZBRANCH + placeholder
                LOADI       D1, #CFA_ZBRANCH
                CALL16      compile_cfa

                LOADP       D0, Y3, [#ZP_HERE]
                PUSH        D0, XY2              ; push WHILE's slot addr
                ; (begin-addr remains underneath)
                MOVE        X0, D0
                LOADI       D1, #0
                STORED      D1, [XY0]
                ADD         D0, #2
                STOREP      D0, Y3, [#ZP_HERE]
                ; Dstack now has (begin while-slot) — reorder so begin stays
                ; under while-slot.  Already correct (begin pushed first by BEGIN).
                BRA         NEXT

REPEAT_COMP:    ; REPEAT ( begin-addr while-slot -- )
                ; Compile BRANCH back to begin, then patch WHILE's slot to HERE
                LOADI       D1, #CFA_BRANCH
                CALL16      compile_cfa

                ; Pop WHILE-slot first (TOS), then begin
                POP         D2, XY2              ; D2 = while-slot
                POP         D3, XY2              ; D3 = begin-addr

                LOADP       D0, Y3, [#ZP_HERE]   ; D0 = address of back-offset cell
                MOVE        D1, D3
                SUB         D1, D0
                SUB         D1, #2               ; offset back to begin
                MOVE        X0, D0
                STORED      D1, [XY0]
                ADD         D0, #2
                STOREP      D0, Y3, [#ZP_HERE]   ; D0 = HERE after back-branch

                ; Patch WHILE's slot: branch forward past back-branch to HERE
                MOVE        D1, D0
                SUB         D1, D2
                SUB         D1, #2
                MOVE        X0, D2
                STORED      D1, [XY0]
                BRA         NEXT

; ============================================================================
; DO / LOOP / +LOOP  (compile-time IMMEDIATE)
; ============================================================================

DO_COMP:        ; DO ( -- here )  compile DO_RT, push HERE for LOOP back-ref
                LOADI       D1, #CFA_DO
                CALL16      compile_cfa
                LOADP       D0, Y3, [#ZP_HERE]
                PUSH        D0, XY2
                BRA         NEXT

LOOP_COMP:      ; LOOP ( here -- )  compile LOOP_RT + back-offset
                LOADI       D1, #CFA_LOOP
                CALL16      compile_cfa

                LOADP       D0, Y3, [#ZP_HERE]   ; offset cell goes here
                POP         D1, XY2              ; D1 = DO-here
                SUB         D1, D0
                SUB         D1, #2               ; signed offset back to DO body
                MOVE        X0, D0
                STORED      D1, [XY0]
                ADD         D0, #2
                STOREP      D0, Y3, [#ZP_HERE]
                BRA         NEXT

PLOOP_COMP:     ; +LOOP ( here -- )  compile PLOOP_RT + back-offset
                LOADI       D1, #CFA_PLOOP
                CALL16      compile_cfa

                LOADP       D0, Y3, [#ZP_HERE]
                POP         D1, XY2
                SUB         D1, D0
                SUB         D1, #2
                MOVE        X0, D0
                STORED      D1, [XY0]
                ADD         D0, #2
                STOREP      D0, Y3, [#ZP_HERE]
                BRA         NEXT

; ============================================================================
; [ and ] — mode switch (IMMEDIATE)
; ============================================================================

LBRACKET_COMP:  ; [ — switch to interpret
                LOADI       D0, #0
                STOREP      D0, Y3, [#ZP_STATE]
                BRA         NEXT

RBRACKET_WORD:  ; ] — switch to compile
                LOADI       D0, #1
                STOREP      D0, Y3, [#ZP_STATE]
                BRA         NEXT

; ============================================================================
; LITERAL — compile a number as inline literal (IMMEDIATE)
; ============================================================================
; ( n -- )  emits [CFA_LIT][n] = 4 bytes total.

LITERAL_COMP:
                POP         D0, XY2              ; value to compile
                PUSH        D0, XY3              ; stash across compile_cfa

                LOADI       D1, #CFA_LIT
                CALL16      compile_cfa

                ; Emit the value as the inline data cell
                LOADP       D1, Y3, [#ZP_HERE]
                MOVE        X0, D1
                POP         D0, XY3              ; recover value
                STORED      D0, [XY0]
                ADD         D1, #2
                STOREP      D1, Y3, [#ZP_HERE]
                BRA         NEXT

; ============================================================================
; ' (tick) and ['] (bracket-tick) — get CFA of word
; ============================================================================

TICK_WORD:      ; ' ( -- cfa )  parse next word, push its CFA
                CALL16      parse_word
                CMP         D3, #0
                BEQ         .tick_err

                PUSH        D2, XY2              ; addr
                PUSH        D3, XY2              ; len
                CALL16      find_word            ; D0=flag, D1=CFA
                CMP         D0, #0
                BEQ         .tick_err

                PUSH        D1, XY2
                BRA         NEXT

.tick_err:      PUSH        X1, XY3
                LOADI       D0, #$3F             ; '?'
                TRAP        #TRAP_PUTCHAR
                POP         X1, XY3
                MOVE        Y0, Y3
                MOVE        Y1, Y3
                LOADI       D0, #0
                PUSH        D0, XY2              ; push 0 to indicate failure
                BRA         NEXT

BTICK_COMP:     ; ['] ( -- )  parse next word, compile its CFA as literal
                CALL16      parse_word
                CMP         D3, #0
                BEQ         .btick_err

                PUSH        D2, XY2
                PUSH        D3, XY2
                CALL16      find_word
                CMP         D0, #0
                BEQ         .btick_err

                PUSH        D1, XY3              ; stash CFA

                LOADI       D1, #CFA_LIT
                CALL16      compile_cfa

                LOADP       D1, Y3, [#ZP_HERE]
                MOVE        X0, D1
                POP         D0, XY3              ; CFA back
                STORED      D0, [XY0]
                ADD         D1, #2
                STOREP      D1, Y3, [#ZP_HERE]
                BRA         NEXT

.btick_err:     PUSH        X1, XY3
                LOADI       D0, #$3F
                TRAP        #TRAP_PUTCHAR
                POP         X1, XY3
                MOVE        Y0, Y3
                MOVE        Y1, Y3
                BRA         NEXT

; ============================================================================
; EXECUTE — run CFA from data stack
; ============================================================================

EXECUTE_WORD:   ; ( cfa -- )
                POP         D0, XY2              ; CFA address
                MOVE        X0, D0
                LOADD       D0, [XY0]            ; code address at CFA
                MOVE        PC, D0               ; jump (will BRA NEXT when done)

; ============================================================================
; RECURSE — compile call to word currently being defined (IMMEDIATE)
; ============================================================================
; LATEST points at the entry being built.  Find its CFA and compile it.

RECURSE_COMP:
                LOADP       D0, Y3, [#ZP_LATEST] ; D0 = entry start
                MOVE        X0, D0

                ; Read flags+len at entry+2
                ADD         X0, #2
                LOADD       D2, [XY0]
                AND         D2, #$3F             ; name length

                ; CFA = entry + 4 + len, word-aligned
                MOVE        D1, D0               ; D1 = entry start
                ADD         D1, #4
                ADD         D1, D2
                ADD         D1, #1
                AND         D1, #$FFFE           ; D1 = CFA address

                CALL16      compile_cfa
                BRA         NEXT

; ============================================================================
; IMMEDIATE — mark most recent definition as immediate
; ============================================================================
; Sets bit 7 (the IMMEDIATE flag) in the flags+len word of LATEST.

IMMEDIATE_WORD:
                LOADP       D0, Y3, [#ZP_LATEST]
                MOVE        X0, D0
                ADD         X0, #2               ; → flags+len
                LOADD       D1, [XY0]
                OR          D1, #$80             ; set IMMEDIATE bit
                STORED      D1, [XY0]
                BRA         NEXT

; ============================================================================
; HERE / ALLOT / , / C, — dict-building helpers
; ============================================================================

HERE_WORD:      ; HERE ( -- addr )
                LOADP       D0, Y3, [#ZP_HERE]
                PUSH        D0, XY2
                BRA         NEXT

ALLOT_WORD:     ; ALLOT ( n -- ) reserve n bytes
                POP         D0, XY2
                LOADP       D1, Y3, [#ZP_HERE]
                ADD         D1, D0
                STOREP      D1, Y3, [#ZP_HERE]
                BRA         NEXT

COMMA_WORD:     ; , ( n -- ) compile word
                POP         D0, XY2
                LOADP       D1, Y3, [#ZP_HERE]
                MOVE        X0, D1
                STORED      D0, [XY0]
                ADD         D1, #2
                STOREP      D1, Y3, [#ZP_HERE]
                BRA         NEXT

CCOMMA_WORD:    ; C, ( c -- ) compile byte
                POP         D0, XY2
                LOADP       D1, Y3, [#ZP_HERE]
                MOVE        X0, D1
                STOREB      D0, [XY0]
                ADD         D1, #1
                STOREP      D1, Y3, [#ZP_HERE]
                BRA         NEXT

; ============================================================================
; BATCHES 4-10 — Remaining v2.25 parity
; ============================================================================
; Y-mirror discipline applies to every TRAP-using primitive:
;     PUSH X1 / TRAP / POP X1 / MOVE Y0,Y3 / MOVE Y1,Y3
; Non-TRAP primitives leave Y registers alone.
;
; Inside CALL-mode helpers (DUMP, WORDS), the IP is saved to ZP_EXEC_RET
; so the rstack stays free for partial-product / loop scratch.

; ============================================================================
; SPACES / TYPE / CLS — basic output
; ============================================================================

SPACES:         ; ( n -- )  print n spaces
                POP         D2, XY2             ; D2 = count (callee-saved)
.spaces_loop:
                CMP         D2, #0
                BGT         .spaces_emit
                BRA         NEXT
.spaces_emit:
                LOADI       D0, #$20
                PUSH        X1, XY3
                TRAP        #TRAP_PUTCHAR
                POP         X1, XY3
                MOVE        Y0, Y3
                MOVE        Y1, Y3
                SUB         D2, #1
                BRA         .spaces_loop

TYPE_WORD:      ; ( addr n -- )  print n bytes from addr in our page
                POP         D2, XY2             ; count
                POP         D3, XY2             ; addr (page-relative)
.type_loop:
                CMP         D2, #0
                BGT         .type_emit
                BRA         NEXT
.type_emit:
                MOVE        X0, D3              ; Y0 already = Y3
                LOADB       D0, [XY0]
                PUSH        X1, XY3
                TRAP        #TRAP_PUTCHAR
                POP         X1, XY3
                MOVE        Y0, Y3
                MOVE        Y1, Y3
                ADD         D3, #1
                SUB         D2, #1
                BRA         .type_loop

CLS_WORD:       ; ( -- )  clear screen via sys_clear
                PUSH        X1, XY3
                TRAP        #TRAP_CLEAR
                POP         X1, XY3
                MOVE        Y0, Y3
                MOVE        Y1, Y3
                BRA         NEXT

; ============================================================================
; TICKS — system tick count
; ============================================================================

TICKS_WORD:     ; ( -- n )  low 16 bits of kernel SYS_TICKS
                PUSH        X1, XY3             ; KLIB_TICKS goes via CALL24
                CALL24      KLIB_TICKS          ; D0 = ticks (low 16)
                POP         X1, XY3
                MOVE        Y0, Y3
                MOVE        Y1, Y3
                PUSH        D0, XY2
                BRA         NEXT

; ============================================================================
; DUMPPAGE — push address of DUMPPAGE variable (for @ / !)
; ============================================================================

DUMPPAGE_WORD:  ; ( -- addr )
                LOADI       D0, #ZP_DUMPPAGE
                PUSH        D0, XY2
                BRA         NEXT

; ============================================================================
; ( and \  comments (IMMEDIATE)
; ============================================================================

PAREN_COMMENT:  ; ( ... )  skip until ')' or end-of-line in TIB
                LOADP       D0, Y3, [#ZP_TOIN]
.paren_loop:
                MOVE        X0, D0
                ADD         X0, #TIB_OFFSET
                LOADB       D1, [XY0]
                CMP         D1, #$29            ; ')'
                BEQ         .paren_done
                CMP         D1, #0
                BEQ         .paren_eol
                ADD         D0, #1
                BRA         .paren_loop
.paren_done:    ADD         D0, #1              ; skip past ')'
.paren_eol:     STOREP      D0, Y3, [#ZP_TOIN]
                BRA         NEXT

BACKSLASH_COMMENT: ; \\ skip rest of line
                LOADP       D0, Y3, [#ZP_NUMTIB]
                STOREP      D0, Y3, [#ZP_TOIN]
                BRA         NEXT

; ============================================================================
; ." — print inline string  (IMMEDIATE compile, runtime emits)
; ============================================================================
; Thread layout at runtime: [DOTQUOTE_RT_CFA][len_word][bytes...]
;   After DOTQUOTE_RT runs, IP is realigned past the (possibly odd-byte) name.

DOTQUOTE_RT:    ; runtime
                LOADD       D2, [XY1]           ; D2 = length (callee-saved)
                ADD         X1, #2              ; skip length word
.dq_loop:
                CMP         D2, #0
                BEQ         .dq_done
                LOADB       D0, [XY1]
                ADD         X1, #1
                PUSH        X1, XY3
                TRAP        #TRAP_PUTCHAR
                POP         X1, XY3
                MOVE        Y0, Y3
                MOVE        Y1, Y3
                SUB         D2, #1
                BRA         .dq_loop
.dq_done:
                ; Align IP back to even
                ADD         X1, #1
                AND         X1, #$FFFE
                BRA         NEXT

CFA_DOTQUOTE:   .WORD       DOTQUOTE_RT

DOTQUOTE_COMP:  ; compile-time (IMMEDIATE)
                ; Emit DOTQUOTE_RT CFA, then length word, then string bytes.
                LOADI       D1, #CFA_DOTQUOTE
                CALL16      compile_cfa

                ; Skip leading space after ."
                LOADP       D0, Y3, [#ZP_TOIN]
.dqc_skip:      MOVE        X0, D0
                ADD         X0, #TIB_OFFSET
                LOADB       D3, [XY0]
                CMP         D3, #$20
                BNE         .dqc_start
                ADD         D0, #1
                BRA         .dqc_skip

.dqc_start:
                ; Reserve length word, remember its address.
                LOADP       D1, Y3, [#ZP_HERE]
                PUSH        D1, XY3             ; save length-slot addr
                ADD         D1, #2              ; skip length, start string here

                LOADI       D2, #0              ; D2 = char count

.dqc_loop:
                MOVE        X0, D0
                ADD         X0, #TIB_OFFSET
                LOADB       D3, [XY0]
                CMP         D3, #$22            ; '"'
                BEQ         .dqc_end
                CMP         D3, #0
                BEQ         .dqc_end

                ; Store char at dest (D1)
                PUSH        X0, XY3
                MOVE        X0, D1
                STOREB      D3, [XY0]
                POP         X0, XY3

                ADD         D0, #1
                ADD         D1, #1
                ADD         D2, #1
                BRA         .dqc_loop

.dqc_end:
                ADD         D0, #1              ; skip closing '"'
                STOREP      D0, Y3, [#ZP_TOIN]

                ; Patch the length word
                POP         D0, XY3             ; D0 = length-slot addr
                MOVE        X0, D0
                STORED      D2, [XY0]

                ; Align HERE to even past the string
                ADD         D1, #1
                AND         D1, #$FFFE
                STOREP      D1, Y3, [#ZP_HERE]
                BRA         NEXT

; ============================================================================
; VARIABLE / CONSTANT
; ============================================================================
; Same dict-header building as COLON, but CFA = DOVAR/DOCON, with body word.

CFA_DOVAR:      .WORD       DOVAR
CFA_DOCON:      .WORD       DOCON

VARIABLE_WORD:  ; VARIABLE name  ( -- )
                CALL16      parse_word
                CMP         D3, #0
                BEQ         .var_err
                ; D2 = name addr, D3 = len
                CALL16      _build_header        ; clobbers D0..D3, X0 — returns nothing
                ; Now HERE points at CFA position.  Write DOVAR + zero body.
                LOADP       D1, Y3, [#ZP_HERE]
                MOVE        X0, D1
                LOADI       D0, #DOVAR
                STORED      D0, [XY0]
                ADD         X0, #2
                LOADI       D0, #0
                STORED      D0, [XY0]           ; initial body value
                ADD         D1, #4
                STOREP      D1, Y3, [#ZP_HERE]
                BRA         NEXT
.var_err:       BRA         NEXT

CONSTANT_WORD:  ; CONSTANT name  ( n -- )
                POP         D0, XY2             ; value
                PUSH        D0, XY3             ; save to rstack across parse_word
                CALL16      parse_word
                CMP         D3, #0
                BEQ         .con_err
                CALL16      _build_header
                LOADP       D1, Y3, [#ZP_HERE]
                MOVE        X0, D1
                LOADI       D0, #DOCON
                STORED      D0, [XY0]
                ADD         X0, #2
                POP         D0, XY3             ; recover value
                STORED      D0, [XY0]
                ADD         D1, #4
                STOREP      D1, Y3, [#ZP_HERE]
                BRA         NEXT
.con_err:       POP         D0, XY3             ; discard saved value
                BRA         NEXT

; --- _build_header: shared dict-header builder
; In:  D2 = name addr in our page, D3 = name length
; Out: HERE advanced past name (CFA goes next; caller writes CFA + body)
;      LATEST updated.  Clobbers D0..D3, X0.
_build_header:
                ; Snapshot LATEST.
                LOADP       D0, Y3, [#ZP_LATEST]

                ; New LATEST = current HERE.
                LOADP       D1, Y3, [#ZP_HERE]
                STOREP      D1, Y3, [#ZP_LATEST]

                ; Build at HERE.
                MOVE        X0, D1              ; Y0 = Y3 already
                STORED      D0, [XY0]           ; Link = old LATEST
                ADD         X0, #2
                STORED      D3, [XY0]           ; flags+len = len (no flags)
                ADD         X0, #2

                ; Copy name from WORD_BUF[D2..D2+D3] to dict[X0..]
                MOVE        D1, D3              ; counter
.bh_copy:
                CMP         D1, #0
                BEQ         .bh_done
                PUSH        X0, XY3
                MOVE        X0, D2
                LOADB       D0, [XY0]
                POP         X0, XY3
                STOREB      D0, [XY0]
                ADD         D2, #1
                ADD         X0, #1
                SUB         D1, #1
                BRA         .bh_copy
.bh_done:
                ; Pad to even (word align for CFA)
                ADD         X0, #1
                AND         X0, #$FFFE

                ; Save new HERE position (CFA will be written next by caller)
                MOVE        D0, X0
                STOREP      D0, Y3, [#ZP_HERE]
                RET

; ============================================================================
; WORDS — list dictionary, wrap at 72 chars
; ============================================================================

WORDS_WORD:
                STOREP      X1, Y3, [#ZP_EXEC_RET]    ; save IP
                LOADI       D2, #0                    ; D2 = column counter
                LOADP       D0, Y3, [#ZP_LATEST]
                MOVE        X0, D0

.w_loop:
                MOVE        D0, X0
                CMP         D0, #0
                BEQ         .w_done

                ; Read length (mask out flags)
                PUSH        X0, XY3
                ADD         X0, #2
                LOADD       D3, [XY0]
                AND         D3, #$3F            ; length only
                POP         X0, XY3

                ; Wrap check: col + len + 1 > 72 → newline
                MOVE        D0, D2
                ADD         D0, D3
                ADD         D0, #1
                CMP         D0, #72
                BCC         .w_print
                LOADI       D0, #$0A
                PUSH        X0, XY3             ; X0 (entry start) not preserved by TRAP
                PUSH        X1, XY3
                TRAP        #TRAP_PUTCHAR
                POP         X1, XY3
                POP         X0, XY3
                MOVE        Y0, Y3
                MOVE        Y1, Y3
                LOADI       D2, #0

.w_print:
                ADD         D2, D3              ; col += len
                ADD         D2, #1              ; + 1 for space

                ; Print name bytes
                PUSH        X0, XY3             ; save entry start
                ADD         X0, #4              ; → name
.w_pname:
                CMP         D3, #0
                BEQ         .w_space
                LOADB       D0, [XY0]
                ADD         X0, #1
                PUSH        D3, XY3
                PUSH        X0, XY3
                PUSH        D2, XY3
                PUSH        X1, XY3
                TRAP        #TRAP_PUTCHAR
                POP         X1, XY3
                MOVE        Y0, Y3
                MOVE        Y1, Y3
                POP         D2, XY3
                POP         X0, XY3
                POP         D3, XY3
                SUB         D3, #1
                BRA         .w_pname

.w_space:
                LOADI       D0, #$20
                PUSH        D2, XY3
                PUSH        X1, XY3
                TRAP        #TRAP_PUTCHAR
                POP         X1, XY3
                MOVE        Y0, Y3
                MOVE        Y1, Y3
                POP         D2, XY3

                ; Follow link
                POP         X0, XY3             ; restore entry start
                LOADD       D0, [XY0]
                MOVE        X0, D0
                BRA         .w_loop

.w_done:
                LOADI       D0, #$0A
                PUSH        X1, XY3
                TRAP        #TRAP_PUTCHAR
                POP         X1, XY3
                MOVE        Y0, Y3
                MOVE        Y1, Y3
                LOADP       D0, Y3, [#ZP_EXEC_RET]
                MOVE        X1, D0
                BRA         NEXT

; ============================================================================
; .S — non-destructive stack print
; ============================================================================

DOTS_WORD:
                STOREP      X1, Y3, [#ZP_EXEC_RET]
                ; depth = (DSTACK_TOP - X2) / 2
                LOADI       D0, #DSTACK_TOP
                SUB         D0, X2
                SHR         D0
                MOVE        D2, D0              ; D2 = depth (callee-saved)

                ; print '<'
                LOADI       D0, #$3C
                PUSH        X1, XY3
                TRAP        #TRAP_PUTCHAR
                POP         X1, XY3
                MOVE        Y0, Y3
                MOVE        Y1, Y3

                ; print depth in decimal
                MOVE        D0, D2
                PUSH        X1, XY3
                CALL16      print_decimal
                POP         X1, XY3
                MOVE        Y0, Y3
                MOVE        Y1, Y3

                ; print "> "
                LOADI       D0, #$3E
                PUSH        X1, XY3
                TRAP        #TRAP_PUTCHAR
                POP         X1, XY3
                MOVE        Y0, Y3
                MOVE        Y1, Y3
                LOADI       D0, #$20
                PUSH        X1, XY3
                TRAP        #TRAP_PUTCHAR
                POP         X1, XY3
                MOVE        Y0, Y3
                MOVE        Y1, Y3

                ; Walk stack from bottom (DSTACK_TOP - 2*depth) upward
                ; D3 = current offset; counts down to 0
                MOVE        D3, D2              ; D3 = remaining items
.dots_loop:
                CMP         D3, #0
                BEQ         .dots_done

                ; address = X2 + (D3-1)*2
                MOVE        D0, D3
                SUB         D0, #1
                SHL         D0                  ; *2
                MOVE        X0, D0
                ADD         X0, X2              ; X0 = slot address
                LOADD       D0, [XY0]

                PUSH        D3, XY3
                PUSH        X1, XY3
                CALL16      print_decimal
                POP         X1, XY3
                MOVE        Y0, Y3
                MOVE        Y1, Y3
                LOADI       D0, #$20
                PUSH        X1, XY3
                TRAP        #TRAP_PUTCHAR
                POP         X1, XY3
                MOVE        Y0, Y3
                MOVE        Y1, Y3
                POP         D3, XY3
                SUB         D3, #1
                BRA         .dots_loop

.dots_done:
                LOADP       D0, Y3, [#ZP_EXEC_RET]
                MOVE        X1, D0
                BRA         NEXT

; ============================================================================
; FIND — in-Forth dict search wrapper
; ============================================================================
; ( c-addr len -- cfa true | c-addr false )

FIND_PRIM:
                ; Duplicate addr in case we need to push it back on failure
                LOADD       D2, [XY2 + #2]      ; addr (under TOS)
                ; Stack already has [addr][len] from caller's POV.
                CALL16      find_word            ; pops both, returns D0=flag,D1=CFA
                CMP         D0, #0
                BEQ         .find_notfound
                PUSH        D1, XY2              ; CFA
                LOADI       D0, #$FFFF
                PUSH        D0, XY2              ; true
                BRA         NEXT
.find_notfound:
                PUSH        D2, XY2              ; original addr
                LOADI       D0, #0
                PUSH        D0, XY2              ; false
                BRA         NEXT

; ============================================================================
; DUMP / ? / FILL / CMOVE — monitor utilities
; ============================================================================
; DUMP uses DUMPPAGE (low byte) for the page Y register.  In v3.0 under
; .COM, the natural default is our own task page (Y3), which init sets.
;
; We use ZP_EXEC_RET to save Forth IP since rstack is heavily used.

; --- Helper: print_hex_byte ( D0 = byte ) via sys_putchar
print_hex_byte:
                PUSH        D0, XY3
                MOVE        D1, D0
                SHR4        D1
                AND         D1, #$0F
                CMP         D1, #10
                BCC         .phb_hi_dig
                ADD         D1, #$37
                BRA         .phb_hi_out
.phb_hi_dig:    ADD         D1, #$30
.phb_hi_out:    MOVE        D0, D1
                TRAP        #TRAP_PUTCHAR
                POP         D0, XY3
                AND         D0, #$0F
                CMP         D0, #10
                BCC         .phb_lo_dig
                ADD         D0, #$37
                BRA         .phb_lo_out
.phb_lo_dig:    ADD         D0, #$30
.phb_lo_out:    TRAP        #TRAP_PUTCHAR
                RET

; --- Helper: print_hex_word ( D0 = word )
print_hex_word:
                PUSH        D0, XY3
                HIGH        D0                  ; D0 = high byte (as $00xx)
                CALL16      print_hex_byte
                POP         D0, XY3
                CALL16      print_hex_byte
                RET

; --- Helper: print_space
print_space:
                LOADI       D0, #$20
                TRAP        #TRAP_PUTCHAR
                RET

; --- Helper: load Y0 with DUMPPAGE
get_page:
                LOADP       D0, Y3, [#ZP_DUMPPAGE]
                MOVE        Y0, D0
                RET

; --- DUMP ( addr n -- )  hex+ASCII dump, 16 bytes/line
DUMP_WORD:
                STOREP      X1, Y3, [#ZP_EXEC_RET]
                POP         D3, XY2             ; n
                POP         D2, XY2             ; addr
                AND         D2, #$FFF0          ; align addr down

.dump_line:
                CMP         D3, #0
                BEQ         .dump_done

                PUSH        D2, XY3             ; [0] line start
                PUSH        D3, XY3             ; [2] remaining
                MOVE        D1, D3
                CMP         D1, #16
                BCC         .d_cnt
                LOADI       D1, #16
.d_cnt:         PUSH        D1, XY3             ; [4] bytes this line

                ; Print "PP:AAAA  "
                CALL16      get_page
                MOVE        D0, Y0
                CALL16      print_hex_byte
                LOADI       D0, #$3A            ; ':'
                TRAP        #TRAP_PUTCHAR
                LOADD       D2, [XY3 + #4]      ; line start addr
                MOVE        D0, D2
                CALL16      print_hex_word
                CALL16      print_space
                CALL16      print_space

                ; Print 16 hex bytes
                LOADD       D1, [XY3]           ; bytes this line
                LOADD       D2, [XY3 + #4]
                LOADI       D0, #0              ; byte 0..15
.d_hex:
                CMP         D0, #16
                BEQ         .d_asc
                CMP         D0, #8
                BNE         .d_hex2
                PUSH        D0, XY3
                PUSH        D1, XY3
                PUSH        D2, XY3
                CALL16      print_space
                POP         D2, XY3
                POP         D1, XY3
                POP         D0, XY3
.d_hex2:
                CMP         D1, #0
                BEQ         .d_pad
                PUSH        D0, XY3
                PUSH        D1, XY3
                PUSH        D2, XY3
                MOVE        X0, D2
                CALL16      get_page
                LOADB       D0, [XY0]
                CALL16      print_hex_byte
                CALL16      print_space
                POP         D2, XY3
                POP         D1, XY3
                POP         D0, XY3
                ADD         D2, #1
                SUB         D1, #1
                ADD         D0, #1
                BRA         .d_hex
.d_pad:
                PUSH        D0, XY3
                CALL16      print_space
                CALL16      print_space
                CALL16      print_space
                POP         D0, XY3
                ADD         D0, #1
                BRA         .d_hex

.d_asc:
                CALL16      print_space
                LOADD       D1, [XY3]
                LOADD       D2, [XY3 + #4]
.d_ascl:
                CMP         D1, #0
                BEQ         .d_nl
                MOVE        X0, D2
                CALL16      get_page
                LOADB       D0, [XY0]
                CMP         D0, #32
                BCC         .d_dot
                CMP         D0, #127
                BCC         .d_chr
.d_dot:         LOADI       D0, #$2E            ; '.'
.d_chr:         TRAP        #TRAP_PUTCHAR
                ADD         D2, #1
                SUB         D1, #1
                BRA         .d_ascl
.d_nl:          LOADI       D0, #$0A
                TRAP        #TRAP_PUTCHAR

                POP         D1, XY3             ; bytes this line
                POP         D3, XY3             ; remaining
                POP         D2, XY3             ; line start
                ADD         D2, D1
                SUB         D3, D1
                BRA         .dump_line

.dump_done:
                MOVE        Y0, Y3              ; restore mirror after many TRAPs
                MOVE        Y1, Y3
                LOADP       D0, Y3, [#ZP_EXEC_RET]
                MOVE        X1, D0
                BRA         NEXT

; --- ? ( addr -- )  peek 16-bit word, print as decimal
QUESTION_WORD:
                POP         D0, XY2
                MOVE        X0, D0
                CALL16      get_page
                LOADD       D0, [XY0]
                PUSH        D0, XY2
                BRA         DOT                 ; tail-call DOT (it BRA's NEXT)

; --- FILL ( addr n byte -- )
FILL_WORD:
                POP         D2, XY2             ; byte
                POP         D1, XY2             ; n
                POP         D0, XY2             ; addr
                MOVE        X0, D0
                CALL16      get_page
.fill_loop:     CMP         D1, #0
                BEQ         .fill_done
                STOREB      D2, [XY0]
                ADD         X0, #1
                SUB         D1, #1
                BRA         .fill_loop
.fill_done:
                MOVE        Y0, Y3              ; restore mirror (DUMPPAGE may differ)
                BRA         NEXT

; --- CMOVE ( src dst n -- )
CMOVE_WORD:
                POP         D2, XY2             ; n
                POP         D1, XY2             ; dst
                POP         D0, XY2             ; src
.cmove_loop:    CMP         D2, #0
                BEQ         .cmove_done
                MOVE        X0, D0
                CALL16      get_page
                LOADB       D3, [XY0]
                MOVE        X0, D1
                CALL16      get_page
                STOREB      D3, [XY0]
                ADD         D0, #1
                ADD         D1, #1
                SUB         D2, #1
                BRA         .cmove_loop
.cmove_done:
                MOVE        Y0, Y3
                BRA         NEXT

; ============================================================================
; FORGET — remove word and everything compiled after it
; ============================================================================
; FORGET name: parse, find, set LATEST = entry's Link, HERE = entry start

FORGET_WORD:
                CALL16      parse_word
                CMP         D3, #0
                BEQ         .forget_err

                ; Push for find_word
                PUSH        D2, XY2
                PUSH        D3, XY2
                ; Save addr/len on rstack too for the find_word "found entry start" we need
                PUSH        D2, XY3
                PUSH        D3, XY3

                ; find_word returns CFA address but we need the entry start
                ; address.  Easier: re-walk the chain ourselves.

                ; Drop find_word's data-stack args (we'll do our own walk).
                ADD         X2, #4

                ; Restore name addr/len.
                POP         D3, XY3
                POP         D2, XY3

                ; Walk LATEST chain comparing names.
                LOADP       D0, Y3, [#ZP_LATEST]
                MOVE        X0, D0

.fg_loop:
                MOVE        D0, X0
                CMP         D0, #0
                BEQ         .forget_notfound

                ; Save iteration state (entry start + word ptr + len)
                PUSH        X0, XY3
                PUSH        D2, XY3
                PUSH        D3, XY3

                ; Read length
                ADD         X0, #2
                LOADD       D1, [XY0]
                AND         D1, #$3F
                SUB         X0, #2

                CMP         D1, D3
                BNE         .fg_next

                ; Compare names
                ADD         X0, #4              ; → dict name
                MOVE        D1, D3
.fg_cmp:
                CMP         D1, #0
                BEQ         .fg_match
                LOADB       D0, [XY0]
                ADD         X0, #1
                PUSH        X0, XY3
                MOVE        X0, D2
                LOADB       D3, [XY0]
                ADD         D2, #1
                POP         X0, XY3
                ; Uppercase
                CMP         D0, #$61
                BCC         .fg_uc1
                CMP         D0, #$7B
                BCS         .fg_uc1
                AND         D0, #$DF
.fg_uc1:        CMP         D3, #$61
                BCC         .fg_uc2
                CMP         D3, #$7B
                BCS         .fg_uc2
                AND         D3, #$DF
.fg_uc2:        CMP         D0, D3
                BNE         .fg_next
                SUB         D1, #1
                BRA         .fg_cmp

.fg_match:
                ; Drop iteration state, recover entry start.
                POP         D3, XY3             ; (discard saved len)
                POP         D2, XY3             ; (discard saved word ptr)
                POP         X0, XY3             ; X0 = entry start

                ; HERE = entry start
                MOVE        D0, X0
                STOREP      D0, Y3, [#ZP_HERE]

                ; LATEST = entry's Link (word at entry+0)
                LOADD       D0, [XY0]
                STOREP      D0, Y3, [#ZP_LATEST]

                BRA         NEXT

.fg_next:
                POP         D3, XY3
                POP         D2, XY3
                POP         X0, XY3
                LOADD       D0, [XY0]           ; Link
                MOVE        X0, D0
                BRA         .fg_loop

.forget_notfound:
                ; Iteration state already popped on the last .fg_next.
                ; Fall through to error.
.forget_err:
                PUSH        X1, XY3
                LOADI       D0, #$3F
                TRAP        #TRAP_PUTCHAR
                POP         X1, XY3
                MOVE        Y0, Y3
                MOVE        Y1, Y3
                BRA         NEXT

; ============================================================================
; END OF NEW PRIMITIVES (batches 4-10)
; ============================================================================



; ============================================================================
; END OF FILE
; ============================================================================
