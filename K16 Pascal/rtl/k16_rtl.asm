; =============================================================
; k16_rtl.asm  -  K16 CPU Runtime Library  BUILD 5
; Pascal/PASTA-80 runtime for K16 CPU.
; V2 ABI: XY2 = frame pointer cache (X2 saved/restored by all RTL functions)
;
; Stack convention: Full Descending, XY3 (Y3=$00 always)
; Calling convention: CALL24 / RET
;   Arguments pushed by caller, caller cleans up (stdcall).
;   Return value in D0.
;
; Kernel dependency:
;   .INCLUDE "k16_kernel.asm" provides:
;     TERMINAL, KEYBOARD, KRN_HEAP_PTR, KRN_HEAP_BASE
;     __putc, __newline, __putn, __putsz
;     __mul16, __mul16_32, __sdiv16, __div10, __shl16, __shr16
;     __heap_init, __getmem, __freemem
;     __getline_buf  (D0=buf, D1=maxlen -- general line reader)
;     and all other kernel primitives
;
; RTL provides (Pascal-specific, not in kernel):
;     __getline    -- fill TIB_BASE from keyboard, reset TIB_PTR
;     __puts, __putsrom, __loadstr
;     __getc, __getn, __gets, __getc_raw
;     __movestr/__storestr, __strappend, __char2str
;     __streq, __strlt, __strleq, __strn, __strc, __strs
;     __val_int, __strn1, __strc1
;     __putn_fmt, __putc_fmt, __puts_fmt
;
; NOT supported on this target (k/OS only -- build with --kos):
;     console.pas  -- GotoXY/ClrScr/GetKey/WhereX/...  (VT100 via k/OS traps)
;     files.pas    -- Assign/Reset/Rewrite/...         (needs a filesystem)
;   Including either unit in a --bare build fails at assembly time with an
;   undefined symbol. That is the intended diagnostic.
;
; Part 22 (4.2) notes:
;   __stradd retired -- dead since Part 19, when the compiler moved to
;     folding every concatenation through __strappend.
;   Heap is the kernel's. k16_kernel.asm __getmem already grows UP and
;     returns the old break, so Part 21's direction fix does not apply
;     here. It has no ceiling test: unchecked, but bounded -- heap runs up
;     from $3000 against a stack descending from $BFF0. Left alone because
;     k16_kernel.asm is shared with BASIC, Forth and k/OS.
;   Deliberately NOT ported from the k/OS RTL: the LOADI Yn,#$00 ->
;     MOVE Yn,Y3 idiom and the [XY]+ post-increment pass. Both are
;     target-neutral wins, but __loadstr's LOADI Y0,#CODEBANK looks like
;     the same idiom and is not -- literals live in ROM bank $FF on this
;     target. A blind sweep would break string constants.
; =============================================================

                .INCLUDE "k16_kernel.asm"

; code bank for string literals (ROM at $FFxxxx)
.EQU CODEBANK, $FF

; =============================================================
; Terminal Input Buffer
;   TIB_BASE  $2000  128-byte line buffer
;   TIB_PTR   $2080  word: current read position (reset by __getline)
; =============================================================
.EQU TIB_BASE, $2000
.EQU TIB_PTR, $2080
.EQU STR_CONCAT_LEFT,  $2082  ; 2-byte scratch: left addr during concat
.EQU STR_CONCAT_RIGHT, $2084  ; 2-byte scratch: right addr during concat
; Phase 6: STR_TEMP1-4, STR_CONCAT, STR_TMPIDX removed.
; String temporaries on caller stack; string arg-position literals at $3500+slot*256.
.EQU STRN_DIGITS, $2100   ; 8-byte scratch for __strn digit extraction
.EQU STRN_SCRATCH, $2110   ; 256-byte scratch for __strn1 / __putn_fmt internal use

__initheap:
InitHeap:
                JMP     __heap_init

; -------------------------------------------------------------
; __puts
; Write Pascal-style length-prefixed string from RAM (page $00).
; D0 = 16-bit RAM address of string. Format: [length_byte][chars...]
; -------------------------------------------------------------
__puts:
                PUSH    D1, XY3
                MOVE    X0, D0
                LOADI   Y0, #$00
                LOADI   X1, #<TERMINAL
                LOADI   Y1, #>TERMINAL
                LOADB   D1, [XY0]              ; D1 = length
                ADD     X0, #1
                CMP     D1, #0
                BEQ.L   __puts_done
__puts_loop:
                LOADB   D0, [XY0]
                STOREB  D0, [XY1]
                ADD     X0, #1
                SUB     D1, #1
                BNE.L   __puts_loop
__puts_done:
                POP     D1, XY3
                RET

; -------------------------------------------------------------
; __putsrom
; Write Pascal-style string from ROM (CODEBANK).
; D0 = 16-bit ROM offset.
; -------------------------------------------------------------
__putsrom:
                PUSH    D1, XY3
                LOADI   X1, #<TERMINAL
                LOADI   Y1, #>TERMINAL
                MOVE    X0, D0
                LOADI   Y0, #CODEBANK
                LOADB   D1, [XY0]
                ADD     X0, #1
                CMP     D1, #0
                BEQ.L   __putsrom_done
__putsrom_loop:
                LOADB   D0, [XY0]
                STOREB  D0, [XY1]
                ADD     X0, #1
                SUB     D1, #1
                BNE.L   __putsrom_loop
__putsrom_done:
                LOADI   Y0, #$00
                POP     D1, XY3
                RET

; -------------------------------------------------------------
; __loadstr  (Phase 6: pass-by-destination ABI)
; D0 = dest RAM address (caller-supplied, 256-byte buffer)
; D1 = ROM offset of string literal in CODEBANK
; Copies literal from ROM to dest. Returns D0 = dest (unchanged).
; -------------------------------------------------------------
__loadstr:
                PUSH    D1, XY3
                PUSH    D2, XY3
                PUSH    D3, XY3
                SUB     X3, #2            ; save frame pointer (V2: XY2=frame base)
                STOREX  X2, [XY3]
                MOVE    X0, D1              ; XY0 = ROM source
                LOADI   Y0, #CODEBANK
                MOVE    X2, D0              ; XY2 = dest (temporary use)
                LOADI   Y2, #$00
                MOVE    D3, D0              ; save dest base for return
                LOADB   D1, [XY0]           ; D1 = length
                STOREB  D1, [XY2]           ; write length byte to dest[0]
                ADD     X0, #1
                ADD     X2, #1
                CMP     D1, #0
                BEQ.L   .ls_done
.ls_loop:
                LOADB   D2, [XY0]
                STOREB  D2, [XY2]
                ADD     X0, #1
                ADD     X2, #1
                SUB     D1, #1
                BNE.L   .ls_loop
.ls_done:
                MOVE    D0, D3              ; D0 = dest
                LOADI   Y0, #$00
                LOADX   X2, [XY3]            ; restore frame pointer (V2)
                ADD     X3, #2
                POP     D3, XY3
                POP     D2, XY3
                POP     D1, XY3
                RET

; __loadstr_from_ram eliminated in Phase 6.
; String function results are written directly to caller-supplied dest.
; (This label kept as a RET stub to catch any stray old references.)


; Fill TIB_BASE from keyboard. Echo chars, handle BS/DEL.
; Null-terminates TIB and resets TIB_PTR to TIB_BASE on return.
; No args. Preserves all registers.
; (Pascal codegen calls this directly via CALL24 __getline)
__getline:
                PUSH    D0, XY3
                PUSH    D1, XY3
                PUSH    D2, XY3
                PUSH    D3, XY3
                SUB     X3, #2            ; save frame pointer (V2: XY2=frame base)
                STOREX  X2, [XY3]
                LOADI   X0, #<KEYBOARD
                LOADI   Y0, #>KEYBOARD
                LOADI   X1, #<TERMINAL
                LOADI   Y1, #>TERMINAL
                LOADI   D2, #0              ; char count
                LOADI   D3, #<TIB_BASE     ; TIB write ptr (X reg)
.gl_loop:
                LOADD   D0, [XY0]           ; read keyboard word
                CMP     D0, #0              ; no key yet?
                BEQ.L   .gl_loop
                AND     D0, #$FF            ; mask to low byte
                CMP     D0, #13             ; CR?
                BEQ.L   .gl_done
                CMP     D0, #10             ; LF?
                BEQ.L   .gl_done
                CMP     D0, #8              ; BS?
                BEQ.L   .gl_bs
                CMP     D0, #127            ; DEL?
                BEQ.L   .gl_bs
                ; store char in TIB
                MOVE    X2, D3
                LOADI   Y2, #$00
                STOREB  D0, [XY2]
                ADD     D3, #1
                ADD     D2, #1
                STOREB  D0, [XY1]           ; echo
                JMP     .gl_loop
.gl_bs:
                CMP     D2, #0
                BEQ.L   .gl_loop
                SUB     D3, #1
                SUB     D2, #1
                LOADI   D1, #8
                STOREB  D1, [XY1]
                LOADI   D1, #32
                STOREB  D1, [XY1]
                LOADI   D1, #8
                STOREB  D1, [XY1]
                JMP     .gl_loop
.gl_done:
                ; null-terminate TIB
                MOVE    X2, D3
                LOADI   Y2, #$00
                LOADI   D1, #0
                STOREB  D1, [XY2]
                ; echo LF
                LOADI   D1, #10
                STOREB  D1, [XY1]
                ; reset TIB read pointer
                LOADI   D1, #<TIB_BASE
                LOADI   X2, #<TIB_PTR
                STORED  D1, [XY2]
                ; restore Y regs to RAM bank
                LOADI   Y0, #$00
                LOADI   Y1, #$00
                LOADI   Y2, #$00
                LOADX   X2, [XY3]            ; restore frame pointer (V2)
                ADD     X3, #2
                POP     D3, XY3
                POP     D2, XY3
                POP     D1, XY3
                POP     D0, XY3
                RET

; -------------------------------------------------------------
; __getc_raw  (internal helper)
; Return next char from TIB in D0 (0 = end of line).
; Advances TIB_PTR.  Clobbers X0, X1 only.
; -------------------------------------------------------------
__getc_raw:
                PUSH    D1, XY3
                LOADI   X0, #<TIB_PTR
                LOADI   Y0, #$00
                LOADD   D1, [XY0]           ; D1 = current TIB read ptr
                MOVE    X1, D1
                LOADI   Y1, #$00
                LOADB   D0, [XY1]           ; D0 = char at ptr
                CMP     D0, #0              ; end of TIB?
                BEQ.L   .gcr_eol
                ADD     D1, #1
                STORED  D1, [XY0]           ; advance ptr
                JMP     .gcr_ret
.gcr_eol:
                LOADI   D0, #0
.gcr_ret:
                LOADI   Y0, #$00
                LOADI   Y1, #$00
                POP     D1, XY3
                RET

; -------------------------------------------------------------
; __getc
; D0 = address of char variable.
; Reads next char from TIB, stores byte to [D0].
; -------------------------------------------------------------
__getc:
                SUB     X3, #2            ; save frame pointer (V2: XY2=frame base)
                STOREX  X2, [XY3]
                MOVE    X2, D0              ; X2 = destination
                CALL24  __getc_raw          ; D0 = char
                STOREB  D0, [XY2]           ; store byte  (Y2=$00)
                LOADX   X2, [XY3]            ; restore frame pointer (V2)
                ADD     X3, #2
                RET

; -------------------------------------------------------------
; __getn
; D0 = address of integer variable.
; Parses signed decimal integer from TIB, stores word to [D0].
; Skips leading spaces.  Stops at first non-digit.
; -------------------------------------------------------------
__getn:
                SUB     X3, #2            ; save frame pointer (V2: XY2=frame base)
                STOREX  X2, [XY3]
                MOVE    X2, D0              ; X2 = destination
                PUSH    D1, XY3
                PUSH    D2, XY3
                PUSH    D3, XY3
                LOADI   D3, #0              ; accumulator
.getn_skip:
                CALL24  __getc_raw
                CMP     D0, #32             ; space?
                BEQ.L   .getn_skip
                LOADI   D2, #0              ; sign: 0=positive
                CMP     D0, #45             ; '-'?
                BNE.L   .getn_loop
                LOADI   D2, #1
                LOADI   D3, #0
                CALL24  __getc_raw          ; consume '-', get next char
.getn_loop:
                CMP     D0, #48             ; < '0'?
                BLT.L   .getn_done
                CMP     D0, #58             ; >= ':' (i.e. > '9')?
                BGE.L   .getn_done
                PUSH    D2, XY3             ; save sign across call
                PUSH    D0, XY3             ; save digit char
                MOVE    D0, D3
                LOADI   D1, #10
                CALL24  __mul16             ; D0 = D3 * 10
                MOVE    D3, D0
                POP     D0, XY3             ; restore digit char
                SUB     D0, #48             ; digit value
                ADD     D3, D0
                POP     D2, XY3
                CALL24  __getc_raw
                JMP     .getn_loop
.getn_done:
                MOVE    D0, D3
                CMP     D2, #1              ; negative?
                BNE.L   .getn_store
                LOADI   D1, #0
                SUB     D1, D0
                MOVE    D0, D1
.getn_store:
                POP     D3, XY3
                POP     D2, XY3
                POP     D1, XY3
                STORED  D0, [XY2]           ; store result  (Y2=$00)
                LOADX   X2, [XY3]            ; restore frame pointer (V2)
                ADD     X3, #2
                RET

; -------------------------------------------------------------
; __gets
; D0 = address of Pascal string variable, D2 = max length.
; Reads chars from TIB up to max, stores length-prefixed string.
; -------------------------------------------------------------
__gets:
                ; D0 = dest RAM addr, D2 = max length
                SUB     X3, #2            ; save frame pointer (V2: XY2=frame base)
                STOREX  X2, [XY3]
                MOVE    X2, D0             ; X2 = dest base (length byte slot)
                LOADI   Y2, #$00
                PUSH    D1, XY3
                PUSH    D2, XY3
                PUSH    D3, XY3
                MOVE    D1, D2             ; D1 = max length
                LOADI   D3, #0             ; D3 = char count
                ADD     X2, #1             ; X2 -> first char slot (past length)
                MOVE    X1, X2             ; X1 = char write ptr (same start)
                LOADI   Y1, #$00
.gets_loop:
                CMP     D3, D1             ; hit max?
                BGE.L   .gets_done
                MOVE    D2, X1             ; save write ptr (X1 clobbered by __getc_raw)
                CALL24  __getc_raw         ; D0 = next char (0 = EOL)
                MOVE    X1, D2             ; restore write ptr
                CMP     D0, #0
                BEQ.L   .gets_done
                STOREB  D0, [XY1]
                ADD     X1, #1
                ADD     D3, #1
                JMP     .gets_loop
.gets_done:
                ; X2 still = dest+1; write length to dest base (X2-1)
                SUB     X2, #1
                STOREB  D3, [XY2]          ; write length byte
                ADD     X2, #1             ; restore (not needed but tidy)
                POP     D3, XY3
                POP     D2, XY3
                POP     D1, XY3
                LOADX   X2, [XY3]            ; restore frame pointer (V2)
                ADD     X3, #2
                RET

; =============================================================
; STRING OPERATIONS
; All string values in the expression system are RAM addresses
; (page $00) pointing to length-prefixed Pascal strings:
;   [byte length][char_0][char_1]...[char_N-1]
; =============================================================

; -------------------------------------------------------------
; Part 27: [XYn]+ sweep over the string primitives.
;
; The two-pointer loops below were written before the STREAM addressing mode
; and advanced their pointers by hand:
;
;       LOADB   D2, [XY0]              LOADB   D2, [XY0]+
;       STOREB  D2, [XY1]      -->     STOREB  D2, [XY1]+
;       ADD     X0, #1                 SUB     D3, #1
;       ADD     X1, #1                 BNE.L   .ss_loop
;       SUB     D3, #1
;       BNE.L   .ss_loop
;
; Six instructions per byte become four.  The post-increment is free -- part of
; the access, not an extra operation -- and STREAM opcodes are flag-transparent,
; so the SUB is still the only thing the BNE can be reading.
;
; __movestr matters most of the five.  It is not merely a string builtin: the
; prologue of every routine taking a by-value String parameter calls it to make
; the frame-private copy (codegen Part 18 Phase 1b(A)), so this loop runs
; program-wide, not just where someone wrote Copy().
;
; It is also a latent correctness fix.  ADD X0,#1 does NOT carry into Y0, so a
; string near the top of a page wrapped to offset 0 and scribbled whatever lived
; there.  [XY0]+ is 24-bit and carries.  Strings are <= 256 bytes and normally
; sit well inside the task page, which is why this never bit -- but "has not
; bitten" and "cannot bite" are different properties.
;
; ---- What was deliberately NOT done ----
;
; 1. The count-up-from-negative trick used in memory.asm's __mcopyto and
;    __msum, where ADD IMM5 (3 cycles) replaces SUB IMM5 (4).  It costs two
;    instructions of setup to save one cycle per iteration: that pays over
;    87,000 bytes of story file and does not pay over a five-character string.
;    Same instruction set, opposite answer, because the trip counts are three
;    orders of magnitude apart.
;
; 2. The set operations (__setadd / __setsub / __setmul and friends).  They
;    look identical but are not:
;
;       LOADB   D0, [XY0]
;       LOADB   D1, [XY1]
;       OR      D1, D0
;       STOREB  D1, [XY1]        <-- writes back to the address just READ
;
;    Folding [XY1] naively puts the store one byte past the load.  It CAN be
;    done -- load plain, store with + -- but that is a judgement per site, in
;    routines nothing currently calls.  A mechanical sweep applied to a
;    non-mechanical case is how cold code acquires latent bugs.
;
; 3. The standalone ADD Xn,#1 that steps past a length byte.  No access to fold
;    into; a dummy load would be slower, not faster.
;
; 4. __strpos.  Its inner loop uses [XY+D] indexed addressing and never
;    advances a pointer at all.  __strappend already used the + form.
;
; Sites folded: .ss_loop (__movestr/__storestr), .seq_loop (__streq),
; .slt_loop (__strlt), .sleq_loop (__strleq), .sc_loop (__strcopy).
; -------------------------------------------------------------

; -------------------------------------------------------------
; __storestr / __movestr
; Copy string from src (RAM) to dest (RAM), capped at maxlen.
; Stack on entry: [..., dest_addr, src_addr]   (src on TOS)
; D2 = max length (chars, not counting length byte)
; -------------------------------------------------------------
__movestr:
__storestr:
                ; D0=dest addr, D1=src addr, D2=max length (register args)
                PUSH    D3, XY3
                MOVE    X0, D1
                LOADI   Y0, #$00
                LOADB   D3, [XY0]          ; D3 = src length
                ; copy_len = min(D3, D2)
                CMP     D3, D2
                BLE.L   .ss_usesl
                MOVE    D3, D2
.ss_usesl:
                MOVE    X1, D0
                LOADI   Y1, #$00
                STOREB  D3, [XY1]          ; write length to dest
                ADD     X0, #1              ; step past the length byte
                ADD     X1, #1
                CMP     D3, #0
                BEQ.L   .ss_done
.ss_loop:
                LOADB   D2, [XY0]+          ; post-increment folds the two
                STOREB  D2, [XY1]+          ; pointer ADDs into the accesses
                SUB     D3, #1
                BNE.L   .ss_loop
.ss_done:
                POP     D3, XY3
                RET

; -------------------------------------------------------------
; __strappend   (append in place:  dest := dest + src, clamp 255)
;   D0 = dest addr   (task page, Y3)
;   D1 = src  addr   (task page, Y3)
;   Returns D0 = dest (unchanged).
;   Byte copy via [XY]+ post-increment; even X3; plain RET.
;   src must be disjoint from dest (fold caller guarantees: dest is a
;   distinct accumulator buffer, src is an operand).
; -------------------------------------------------------------
__strappend:
                PUSH    D2, XY3
                PUSH    D3, XY3
                SUB     X3, #2              ; save frame ptr (V2: XY2=frame base)
                STOREX  X2, [XY3]
                MOVE    D3, D0              ; D3 = dest base (constant)
                MOVE    X2, D0
                MOVE    Y2, Y3
                LOADB   D0, [XY2]           ; D0 = current dest length (running total)
                CMP     D0, #255
                BGE.L   .sap_done           ; dest already full -> nothing to add
                ADD     X2, #1              ; X2 -> dest[1]
                ADD     X2, D0              ; X2 -> dest[len+1]  (append point)
                MOVE    X0, D1
                MOVE    Y0, Y3
                LOADB   D2, [XY0]+          ; D2 = src length, X0 -> src[1]
                CMP     D2, #0
                BEQ.L   .sap_done           ; empty src
.sap_loop:
                LOADB   D1, [XY0]+          ; D1 = src char, X0++
                STOREB  D1, [XY2]+          ; dest[..] = char, X2++
                ADD     D0, #1              ; running total++
                CMP     D0, #255
                BGE.L   .sap_done           ; hit cap
                SUB     D2, #1              ; remaining src--
                BNE.L   .sap_loop
.sap_done:
                MOVE    X2, D3              ; X2 = dest base
                STOREB  D0, [XY2]           ; dest[0] = new total length
                MOVE    D0, D3              ; return dest
                LOADX   X2, [XY3]           ; restore frame ptr (V2)
                ADD     X3, #2
                POP     D3, XY3
                POP     D2, XY3
                RET

; -------------------------------------------------------------
; __char2str  (Phase 6: pass-by-destination ABI)
; Convert char to a 1-char Pascal string in caller-supplied dest.
; D0 = dest addr, D1 = char
; Returns D0 = dest (unchanged).
; -------------------------------------------------------------
__char2str:
                MOVE    X0, D0
                LOADI   Y0, #$00
                LOADI   D0, #1
                STOREB  D0, [XY0]           ; dest[0] = length 1
                ADD     X0, #1
                STOREB  D1, [XY0]           ; dest[1] = char
                SUB     X0, #1
                MOVE    D0, X0              ; D0 = dest
                RET

; -------------------------------------------------------------
; __streq
; Compare two RAM strings for equality.
; Stack: [..., left_addr, right_addr]   (right on TOS)
; Pops both. Returns D0 = 1 if equal, 0 if not.
; -------------------------------------------------------------
__streq:
                ; D0=left addr, D1=right addr (register args) -> D0=1/0
                PUSH    D2, XY3
                PUSH    D3, XY3
                MOVE    X0, D0
                LOADI   Y0, #$00
                LOADB   D2, [XY0]          ; D2 = left length
                MOVE    X1, D1
                LOADI   Y1, #$00
                LOADB   D3, [XY1]          ; D3 = right length
                CMP     D2, D3
                BNE.L   .seq_false         ; different lengths => not equal
                ADD     X0, #1             ; step past the length byte
                ADD     X1, #1
                CMP     D2, #0
                BEQ.L   .seq_true          ; both empty => equal
.seq_loop:
                LOADB   D0, [XY0]+
                LOADB   D3, [XY1]+
                CMP     D0, D3             ; the loads are flag-transparent,
                BNE.L   .seq_false         ; so this CMP is what BNE reads
                SUB     D2, #1
                BNE.L   .seq_loop
.seq_true:
                LOADI   D0, #1
                JMP   .seq_done
.seq_false:
                LOADI   D0, #0
.seq_done:
                POP     D3, XY3
                POP     D2, XY3
                RET

; -------------------------------------------------------------
; __strlt
; Compare two RAM strings: left < right (lexicographic, unsigned).
; Stack: [..., left_addr, right_addr]   (right on TOS)
; Pops both. Returns D0 = 1 if left < right, 0 otherwise.
; Carry convention: BCC = unsigned less than (borrow set).
; -------------------------------------------------------------
__strlt:
                ; D0=left addr, D1=right addr (register args) -> D0=1/0
                PUSH    D2, XY3
                PUSH    D3, XY3
                MOVE    X0, D0
                LOADI   Y0, #$00
                LOADB   D2, [XY0]          ; D2 = left length
                ADD     X0, #1
                MOVE    X1, D1
                LOADI   Y1, #$00
                LOADB   D3, [XY1]          ; D3 = right length
                ADD     X1, #1
.slt_loop:
                CMP     D2, #0
                BEQ.L   .slt_left_end
                CMP     D3, #0
                BEQ.L   .slt_right_end
                LOADB   D0, [XY0]+         ; left char
                LOADB   D1, [XY1]+         ; right char (D1 free: right addr in X1)
                CMP     D0, D1
                BCC.L   .slt_true          ; left < right (unsigned)
                BNE.L   .slt_false         ; left > right
                ; equal: both pointers already advanced by the loads
                SUB     D2, #1
                SUB     D3, #1
                JMP     .slt_loop
.slt_left_end:
                ; left exhausted: left < right iff right still has chars
                CMP     D3, #0
                BNE.L   .slt_true
                JMP   .slt_false
.slt_right_end:
                ; right exhausted, left not: left >= right
                JMP   .slt_false
.slt_true:
                LOADI   D0, #1
                JMP   .slt_done
.slt_false:
                LOADI   D0, #0
.slt_done:
                POP     D3, XY3
                POP     D2, XY3
                RET

; -------------------------------------------------------------
; __strleq
; Compare: left <= right. Stack same as __strlt.
; Pops both. Returns D0 = 1 if left <= right, 0 otherwise.
; -------------------------------------------------------------
__strleq:
                ; D0=left addr, D1=right addr (register args) -> D0=1/0
                PUSH    D2, XY3
                PUSH    D3, XY3
                MOVE    X0, D0
                LOADI   Y0, #$00
                LOADB   D2, [XY0]
                ADD     X0, #1
                MOVE    X1, D1
                LOADI   Y1, #$00
                LOADB   D3, [XY1]
                ADD     X1, #1
.sleq_loop:
                CMP     D2, #0
                BEQ.L   .sleq_left_end
                CMP     D3, #0
                BEQ.L   .sleq_right_end
                LOADB   D0, [XY0]+         ; left char
                LOADB   D1, [XY1]+         ; right char (D1 free: right addr in X1)
                CMP     D0, D1
                BCC.L   .sleq_true
                BNE.L   .sleq_false
                ; equal: both pointers already advanced by the loads
                SUB     D2, #1
                SUB     D3, #1
                JMP     .sleq_loop
.sleq_left_end:
                JMP   .sleq_true         ; left shorter or equal => left <= right
.sleq_right_end:
                JMP   .sleq_false
.sleq_true:
                LOADI   D0, #1
                JMP   .sleq_done
.sleq_false:
                LOADI   D0, #0
.sleq_done:
                POP     D3, XY3
                POP     D2, XY3
                RET

; -------------------------------------------------------------
; __strn
; Convert integer to decimal string.
; D0 = dest RAM addr, D1 = integer value, D2 = max length.
; Writes length-prefixed string to [D0]. Preserves nothing.
; Uses STRN_DIGITS scratch buffer.
; __sdiv16 preserves D2 and D3 internally.
; -------------------------------------------------------------
__strn:
                PUSH    D2, XY3            ; save (used as digit count by __sdiv16 guard)
                PUSH    D3, XY3
                PUSH    D0, XY3            ; save dest base (written at .sn_done)
                SUB     X3, #2            ; save frame pointer (V2: XY2=frame base)
                STOREX  X2, [XY3]
                LOADI   D3, #0             ; D3 = total chars written (preserved by __sdiv16)
                MOVE    X1, D0
                LOADI   Y1, #$00
                ADD     X1, #1             ; X1 -> first char slot
                ; Handle sign
                CMP     D1, #0
                BGE.L   .sn_pos
                LOADI   D2, #45            ; '-'
                STOREB  D2, [XY1]
                ADD     X1, #1
                ADD     D3, #1
                NOT     D1                 ; negate: D1 = ~D1 + 1 = -D1
                ADD     D1, #1
.sn_pos:
                ; Extract digits into STRN_DIGITS (reversed)
                LOADI   X2, #<STRN_DIGITS
                LOADI   Y2, #$00
                LOADI   D2, #0             ; D2 = digit count (preserved by __sdiv16)
                CMP     D1, #0
                BNE.L   .sn_dig_loop
                ; value is 0: write single '0'
                LOADI   D0, #48            ; '0'
                STOREB  D0, [XY2]
                ADD     X2, #1
                ADD     D2, #1
                JMP   .sn_reverse
.sn_dig_loop:
                CMP     D1, #0
                BEQ.L   .sn_reverse
                MOVE    D0, D1
                LOADI   D1, #10
                CALL24  __sdiv16           ; D0=quotient, D1=remainder; D2,D3 preserved
                ADD     D1, #48            ; ASCII digit
                STOREB  D1, [XY2]
                ADD     X2, #1
                ADD     D2, #1
                MOVE    D1, D0             ; quotient is next value
                JMP     .sn_dig_loop
.sn_reverse:
                ; D2 = digit count; X2 = STRN_DIGITS + D2 (one past last)
                CMP     D2, #0
                BEQ.L   .sn_done
.sn_rev_loop:
                SUB     X2, #1
                LOADB   D1, [XY2]
                STOREB  D1, [XY1]
                ADD     X1, #1
                ADD     D3, #1
                SUB     D2, #1
                BNE.L   .sn_rev_loop
.sn_done:
                LOADX   X2, [XY3]            ; restore frame pointer (V2) first
                ADD     X3, #2               ; move past X2 save slot
                POP     D0, XY3            ; D0 = dest base (now correct)
                MOVE    X1, D0
                STOREB  D3, [XY1]          ; write length byte
                POP     D3, XY3
                POP     D2, XY3
                RET

; -------------------------------------------------------------
; __udiv16                                       (Part 24, Word)
; Unsigned 16/16 divide.  In: D0 = dividend, D1 = divisor.
;                        Out: D0 = quotient, D1 = remainder.
; Preserves D2, D3.
;
; This is the kernel __sdiv16's own core loop with the sign normalisation in
; front and the negate behind it removed -- i.e. the algorithm was always
; unsigned and the signed routine wraps it.  Kept here in the Pascal RTL
; rather than added to k16_kernel.asm, which is shared with BASIC and Forth.
;
; Carry sense, stated before the branch: after CMP D2,D1 the BCC (= BLO) is
; taken when C = 0, which on K16 means BORROW, i.e. remainder < divisor.
; The x86 reading is backwards.
;
; ADC is load-bearing here.  It needed no probe: the kernel divider has been
; running on this exact instruction pair since it was written.
; -------------------------------------------------------------
__udiv16:
                PUSH    D2, XY3
                PUSH    D3, XY3
                PUSH    D1, XY3             ; divisor, peeked in the loop
                LOADI   D2, #0              ; D2 = running remainder
                LOADI   D3, #16             ; D3 = bit counter
.ud_loop:
                ADD     D0, D0              ; dividend MSB -> carry
                ADC     D2, D2              ; remainder = (remainder<<1) | carry
                LOADD   D1, [XY3]           ; peek divisor (SP points at it)
                CMP     D2, D1
                BCC.L   .ud_no              ; C=0 = borrow = remainder < divisor
                SUB     D2, D1
                OR      D0, #1              ; set quotient LSB
.ud_no:
                SUB     D3, #1
                BNE.L   .ud_loop
                MOVE    D1, D2              ; D1 = remainder
                ADD     X3, #2              ; discard saved divisor
                POP     D3, XY3
                POP     D2, XY3
                RET

; -------------------------------------------------------------
; __putu                                         (Part 24, Word)
; Print UNSIGNED 16-bit D0 to the terminal as decimal.
; Trashes D1, D2.
;
; __putn with the sign test removed.  __div10 is a magic-multiply reciprocal
; ((n * $CCCD) >> 19) and is exact over the whole 0..65535 range, so nothing
; else in the digit loop needs to change.  __div10 trashes D2 and D3, which
; is why the sentinel lives on the stack rather than in a register -- the
; same reason __putn does it that way.
; -------------------------------------------------------------
__putu:
                PUSH    D2, XY3
                LOADI   X1, #<TERMINAL
                LOADI   Y1, #>TERMINAL
                CMP     D0, #0
                BNE.L   .pu_nonzero
                LOADI   D1, #48             ; value 0 -> single '0'
                STOREB  D1, [XY1]
                POP     D2, XY3
                RET
.pu_nonzero:
                LOADI   D2, #0              ; sentinel
                PUSH    D2, XY3
.pu_push:
                CMP     D0, #0
                BEQ.L   .pu_print
                CALL24  __div10             ; D0=quot, D1=remainder
                ADD     D1, #48             ; digit -> ASCII
                PUSH    D1, XY3
                JMP     .pu_push
.pu_print:
                POP     D1, XY3
                CMP     D1, #0              ; sentinel?
                BEQ.L   .pu_done
                STOREB  D1, [XY1]
                JMP     .pu_print
.pu_done:
                POP     D2, XY3
                RET

; -------------------------------------------------------------
; __strnu                                        (Part 24, Word)
; Convert an UNSIGNED integer to a decimal string.
; D0 = dest RAM addr, D1 = unsigned value, D2 = max length.
; Writes length-prefixed string to [D0]. Preserves nothing.
; Uses STRN_DIGITS scratch buffer.  __udiv16 preserves D2 and D3 internally.
;
; __strn without the sign block, and calling __udiv16 rather than __sdiv16 --
; with a signed divide, every value above $7FFF would come out negative and
; the digits would be wrong rather than merely unsigned.  The k/OS RTL does
; this in ten lines via KLIB_UTOA; bare metal has no KLIB, so the structure
; of __strn is mirrored instead.
; -------------------------------------------------------------
__strnu:
                PUSH    D2, XY3            ; save
                PUSH    D3, XY3
                PUSH    D0, XY3            ; save dest base (written at .snu_done)
                SUB     X3, #2             ; save frame pointer (V2: XY2=frame base)
                STOREX  X2, [XY3]
                LOADI   D3, #0             ; D3 = total chars written
                MOVE    X1, D0
                LOADI   Y1, #$00
                ADD     X1, #1             ; X1 -> first char slot
                ; no sign handling: the value is unsigned
                LOADI   X2, #<STRN_DIGITS
                LOADI   Y2, #$00
                LOADI   D2, #0             ; D2 = digit count
                CMP     D1, #0
                BNE.L   .snu_dig_loop
                ; value is 0: write single '0'
                LOADI   D0, #48
                STOREB  D0, [XY2]
                ADD     X2, #1
                ADD     D2, #1
                JMP     .snu_reverse
.snu_dig_loop:
                CMP     D1, #0
                BEQ.L   .snu_reverse
                MOVE    D0, D1
                LOADI   D1, #10
                CALL24  __udiv16           ; D0=quot, D1=rem; D2,D3 preserved
                ADD     D1, #48            ; ASCII digit
                STOREB  D1, [XY2]
                ADD     X2, #1
                ADD     D2, #1
                MOVE    D1, D0             ; quotient is next value
                JMP     .snu_dig_loop
.snu_reverse:
                CMP     D2, #0
                BEQ.L   .snu_done
.snu_rev_loop:
                SUB     X2, #1
                LOADB   D1, [XY2]
                STOREB  D1, [XY1]
                ADD     X1, #1
                ADD     D3, #1
                SUB     D2, #1
                BNE.L   .snu_rev_loop
.snu_done:
                LOADX   X2, [XY3]          ; restore frame pointer (V2) first
                ADD     X3, #2             ; move past X2 save slot
                POP     D0, XY3            ; D0 = dest base
                MOVE    X1, D0
                STOREB  D3, [XY1]          ; write length byte
                POP     D3, XY3
                POP     D2, XY3
                RET

; -------------------------------------------------------------
; __strc
; Convert char to 1-char string at D0. D1=char, D2=maxlen.
; -------------------------------------------------------------
__strc:
                CMP     D2, #0
                BEQ.L   .sc_done
                MOVE    X0, D0
                LOADI   Y0, #$00
                LOADI   D2, #1
                STOREB  D2, [XY0]          ; length = 1
                ADD     X0, #1
                STOREB  D1, [XY0]          ; char
.sc_done:
                RET

; -------------------------------------------------------------
; __strs
; Copy string from src to dest.  D0=dest addr, D1=src addr, D2=maxlen.
; (Used by str(stringvar, destvar).)
; -------------------------------------------------------------
__strs:
                JMP     __storestr         ; args already in D0/D1/D2

; -------------------------------------------------------------
; __val_int
; Parse signed decimal integer from length-prefixed string.
; D0 = string RAM addr, D1 = dest integer addr, D2 = errcode addr
; On return: [D1] = parsed value (0 on error)
;            [D2] = 0 OK, else 1-based position of first bad char.
; Clobbers D0-D3, XY0, XY1.
; Stack on exit clean (3 words pushed and popped).
; -------------------------------------------------------------
__val_int:
                PUSH    D3, XY3            ; save D3
                PUSH    D1, XY3            ; save dest addr
                PUSH    D2, XY3            ; save errcode addr
                ; Stack: [errcode_addr, dest_addr, D3_orig]
                MOVE    X0, D0
                LOADI   Y0, #$00
                LOADB   D3, [XY0]          ; D3 = string length
                ADD     X0, #1             ; X0 -> chars[0]
                LOADI   D1, #0             ; D1 = pos (0-based)
                ; skip leading spaces
.vi_skip:
                CMP     D1, D3
                BGE.L   .vi_err_pos        ; empty / all-spaces
                LOADB   D0, [XY0]
                CMP     D0, #32
                BNE.L   .vi_sign
                ADD     X0, #1
                ADD     D1, #1
                JMP     .vi_skip
                ; check sign
.vi_sign:
                LOADI   D2, #0             ; D2 = sign (0=positive)
                CMP     D0, #45            ; '-'?
                BNE.L   .vi_chk_plus
                LOADI   D2, #1
                ADD     X0, #1
                ADD     D1, #1
                JMP     .vi_need_dig
.vi_chk_plus:
                CMP     D0, #43            ; '+'?
                BNE.L   .vi_need_dig
                ADD     X0, #1
                ADD     D1, #1
                ; first digit must exist
.vi_need_dig:
                CMP     D1, D3
                BGE.L   .vi_err_pos        ; sign only = error
                LOADB   D0, [XY0]
                CMP     D0, #48
                BLT.L   .vi_err_pos
                CMP     D0, #57
                BGT.L   .vi_err_pos
                ; enter digit loop: push sign, use D2 as accumulator
                PUSH    D2, XY3            ; push sign
                ; Stack: [sign, errcode_addr, dest_addr, D3_orig]
                LOADI   D2, #0             ; D2 = accumulator
.vi_dig_loop:
                CMP     D1, D3
                BGE.L   .vi_trail
                LOADB   D0, [XY0]
                CMP     D0, #48
                BLT.L   .vi_trail
                CMP     D0, #57
                BGT.L   .vi_trail
                SUB     D0, #48            ; digit 0-9
                ; D2 = D2*10 + D0  (use D3 as tmp; save/restore length)
                PUSH    D3, XY3
                MOVE    D3, D2
                ADD     D2, D2             ; *2
                ADD     D2, D2             ; *4
                ADD     D2, D3             ; *5
                ADD     D2, D2             ; *10
                ADD     D2, D0             ; +digit
                POP     D3, XY3
                ADD     X0, #1
                ADD     D1, #1
                JMP     .vi_dig_loop
                ; check trailing chars (spaces OK, anything else = error)
.vi_trail:
                PUSH    D2, XY3            ; save accumulator
                ; Stack: [acc, sign, errcode_addr, dest_addr, D3_orig]
.vi_trail_loop:
                CMP     D1, D3
                BGE.L   .vi_ok
                LOADB   D0, [XY0]
                CMP     D0, #32
                BNE.L   .vi_trail_err
                ADD     X0, #1
                ADD     D1, #1
                JMP     .vi_trail_loop
.vi_ok:
                POP     D2, XY3            ; acc
                POP     D0, XY3            ; sign
                CMP     D0, #0
                BEQ.L   .vi_store
                LOADI   D0, #0             ; negate: D2 = 0 - D2
                SUB     D0, D2
                MOVE    D2, D0
.vi_store:
                POP     D3, XY3            ; errcode addr (use D3 as temp)
                POP     D0, XY3            ; dest addr
                MOVE    X1, D0
                LOADI   Y1, #$00
                STORED  D2, [XY1]          ; store result
                MOVE    X1, D3
                LOADI   D0, #0
                STORED  D0, [XY1]          ; errcode = 0
                POP     D3, XY3
                RET
.vi_trail_err:
                ; [acc, sign, errcode_addr, dest_addr, D3_orig]
                POP     D2, XY3            ; discard acc
                POP     D2, XY3            ; discard sign
                ; fall into .vi_err_pos -- D1 = bad pos (0-based)
                JMP     .vi_err_store
                ; error before digit loop: Stack: [errcode_addr, dest_addr, D3_orig]
.vi_err_pos:
                ; D1 = 0-based error position
.vi_err_store:
                ADD     D1, #1             ; make 1-based
                POP     D3, XY3            ; errcode addr
                POP     D0, XY3            ; dest addr
                MOVE    X1, D0
                LOADI   Y1, #$00
                LOADI   D0, #0
                STORED  D0, [XY1]          ; result = 0
                MOVE    X1, D3
                STORED  D1, [XY1]          ; errcode = position
                POP     D3, XY3
                RET

; -------------------------------------------------------------
; Remaining stubs (floating point, file I/O, heap)
; -------------------------------------------------------------
; -------------------------------------------------------------
; __strn1
; str(n:width, s) -- integer to right-justified string.
; D0=dest, D1=value, D2=maxlen, D3=width.
; Converts to STR_TEMP1, then writes (width-len) spaces + digits to dest.
; Uses STR_TEMP1 as scratch (safe -- not nested with __loadstr).
; -------------------------------------------------------------
__strn1:
                PUSH    D0, XY3            ; save dest
                PUSH    D2, XY3            ; save maxlen
                PUSH    D3, XY3            ; save width
                SUB     X3, #2            ; save frame pointer (V2: XY2=frame base)
                STOREX  X2, [XY3]
                LOADI   D0, #<STRN_SCRATCH    ; temp dest
                LOADI   D2, #255           ; uncapped
                CALL24  __strn             ; write plain number to STRN_SCRATCH
                POP     D3, XY3            ; width
                POP     D2, XY3            ; maxlen
                POP     D0, XY3            ; dest
                MOVE    X0, D0             ; X0 = dest base (preserved hereafter)
                LOADI   Y0, #$00
                LOADI   X1, #<STRN_SCRATCH
                LOADI   Y1, #$00
                LOADB   D1, [XY1]          ; D1 = actual_len
                ; new_len = min(width, maxlen) -> D3
                CMP     D3, D2
                BLE.L   .s1_w_ok
                MOVE    D3, D2
.s1_w_ok:
                ; pad = new_len - actual_len -> D2; if negative, 0
                MOVE    D2, D3
                SUB     D2, D1
                BGE.L   .s1_do_pad
                LOADI   D2, #0
.s1_do_pad:
                ; X2 = dest+1 (write ptr)
                MOVE    X2, X0
                LOADI   Y2, #$00
                ADD     X2, #1
                ; write D2 spaces
                CMP     D2, #0
                BEQ.L   .s1_copy
.s1_pad_loop:
                LOADI   D0, #32
                STOREB  D0, [XY2]
                ADD     X2, #1
                SUB     D2, #1
                BNE.L   .s1_pad_loop
.s1_copy:
                ; copy D1 chars from STR_TEMP1+1 to [X2]
                ADD     X1, #1
                CMP     D1, #0
                BEQ.L   .s1_write_len
.s1_copy_loop:
                LOADB   D0, [XY1]
                STOREB  D0, [XY2]
                ADD     X1, #1
                ADD     X2, #1
                SUB     D1, #1
                BNE.L   .s1_copy_loop
.s1_write_len:
                STOREB  D3, [XY0]          ; dest[0] = new_len
                LOADX   X2, [XY3]            ; restore frame pointer (V2)
                ADD     X3, #2
                RET

; -------------------------------------------------------------
; __strc1
; str(c:width, s) -- char to right-justified string.
; D0=dest, D1=char, D2=maxlen, D3=width.
; Writes min(width,maxlen)-1 spaces then char.
; -------------------------------------------------------------
__strc1:
                SUB     X3, #2            ; save frame pointer (V2: XY2=frame base)
                STOREX  X2, [XY3]
                MOVE    X0, D0
                LOADI   Y0, #$00
                ; new_len = min(width, maxlen) -> D3
                CMP     D3, D2
                BLE.L   .sc1_w_ok
                MOVE    D3, D2
.sc1_w_ok:
                CMP     D3, #0
                BEQ.L   .sc1_done
                ; pad = new_len - 1 -> D2
                MOVE    D2, D3
                SUB     D2, #1
                ; X2 = dest+1
                MOVE    X2, X0
                LOADI   Y2, #$00
                ADD     X2, #1
                CMP     D2, #0
                BEQ.L   .sc1_char
.sc1_pad_loop:
                LOADI   D0, #32
                STOREB  D0, [XY2]
                ADD     X2, #1
                SUB     D2, #1
                BNE.L   .sc1_pad_loop
.sc1_char:
                STOREB  D1, [XY2]          ; write char
                STOREB  D3, [XY0]          ; dest[0] = new_len
.sc1_done:
                LOADX   X2, [XY3]            ; restore frame pointer (V2)
                ADD     X3, #2
                RET

; -------------------------------------------------------------
; __putn_fmt
; writeln(n:width) -- print integer right-justified in width field.
; D0=value, D2=width.
; -------------------------------------------------------------
__putn_fmt:
                PUSH    D2, XY3            ; save width
                MOVE    D1, D0             ; D1 = value
                LOADI   D0, #<STRN_SCRATCH    ; temp dest
                LOADI   D2, #255
                CALL24  __strn             ; write to STRN_SCRATCH
                POP     D2, XY3            ; width
                LOADI   X0, #<STRN_SCRATCH
                LOADI   Y0, #$00
                LOADB   D1, [XY0]          ; D1 = actual_len
                ; padding = width - actual_len
                SUB     D2, D1
                BLE.L   .pf_print
                LOADI   X1, #<TERMINAL
                LOADI   Y1, #>TERMINAL
.pf_pad_loop:
                LOADI   D0, #32
                STOREB  D0, [XY1]
                SUB     D2, #1
                BNE.L   .pf_pad_loop
.pf_print:
                LOADI   D0, #<STRN_SCRATCH
                CALL24  __puts
                RET

; -------------------------------------------------------------
; __putu_fmt                                     (Part 24, Word)
; write(w:width) -- print an unsigned value right-justified in a width field.
; D0=value, D2=width.  __putn_fmt with __strn swapped for __strnu.
; -------------------------------------------------------------
__putu_fmt:
                PUSH    D2, XY3            ; save width
                MOVE    D1, D0             ; D1 = value
                LOADI   D0, #<STRN_SCRATCH    ; temp dest
                LOADI   D2, #255
                CALL24  __strnu            ; write to STRN_SCRATCH
                POP     D2, XY3            ; width
                LOADI   X0, #<STRN_SCRATCH
                LOADI   Y0, #$00
                LOADB   D1, [XY0]          ; D1 = actual_len
                ; padding = width - actual_len
                SUB     D2, D1
                BLE.L   .puf_print
                LOADI   X1, #<TERMINAL
                LOADI   Y1, #>TERMINAL
.puf_pad_loop:
                LOADI   D0, #32
                STOREB  D0, [XY1]
                SUB     D2, #1
                BNE.L   .puf_pad_loop
.puf_print:
                LOADI   D0, #<STRN_SCRATCH
                CALL24  __puts
                RET

; -------------------------------------------------------------
; __putc_fmt
; writeln(c:width) -- print char right-justified in width field.
; D0=char, D2=width.
; -------------------------------------------------------------
__putc_fmt:
                PUSH    D0, XY3            ; save char
                LOADI   X1, #<TERMINAL
                LOADI   Y1, #>TERMINAL
                SUB     D2, #1             ; pad = width - 1
                BLE.L   .pcf_char
.pcf_pad_loop:
                LOADI   D0, #32
                STOREB  D0, [XY1]
                SUB     D2, #1
                BNE.L   .pcf_pad_loop
.pcf_char:
                POP     D0, XY3
                STOREB  D0, [XY1]
                RET

; -------------------------------------------------------------
; __puts_fmt
; writeln(s:width) -- print string right-justified in width field.
; D0=string_addr, D2=width.
; -------------------------------------------------------------
__puts_fmt:
                PUSH    D0, XY3            ; save string addr
                MOVE    X0, D0
                LOADI   Y0, #$00
                LOADB   D1, [XY0]          ; D1 = actual_len
                SUB     D2, D1             ; padding = width - len
                BLE.L   .psf_print
                LOADI   X1, #<TERMINAL
                LOADI   Y1, #>TERMINAL
.psf_pad_loop:
                LOADI   D0, #32
                STOREB  D0, [XY1]
                SUB     D2, #1
                BNE.L   .psf_pad_loop
.psf_print:
                POP     D0, XY3
                CALL24  __puts
                RET
__putf_fix:
__putf_exp:

; -------------------------------------------------------------
; __load16 -- block load: D0=src_addr, D1=size_bytes
; No-op: src address stays in D0 for the immediately following
; __store16 call.  D1 (size) is ignored here; caller passes
; size again in D2 to __store16.
; -------------------------------------------------------------
__load16:
                RET

; -------------------------------------------------------------
; __store16 -- block copy D2 bytes from D0 to dest
; D0 = source address (from preceding __load16 call)
; D2 = byte count
; [X3+4] = destination address (pushed by caller before __load16)
; Returns via RET #1w to pop the dest word from stack.
; Trashes D1, D3, XY0, XY1.
; -------------------------------------------------------------
__store16:
                LOADD   D1, [XY3+#4]        ; D1 = dest address
                MOVE    X0, D0              ; XY0 = src (bank $00)
                LOADI   Y0, #$00
                MOVE    X1, D1              ; XY1 = dest (bank $00)
                LOADI   Y1, #$00
                CMP     D2, #0
                BEQ.L   .s16_done
.s16_loop:
                LOADB   D3, [XY0]
                STOREB  D3, [XY1]
                ADD     X0, #1
                ADD     X1, #1
                SUB     D2, #1
                BNE.L   .s16_loop
.s16_done:
                RET     #1w                 ; pop dest_addr (1 word = 2 bytes)

__inc16:
__dec16:
__mkstr:
__rmstr:
__loadfp:
__storefp:
__strf:
__stre:
__strf2:
; ------------------------------------------------------------------
; __setmember -- element IN set test
; CALL24 pushes 4-byte return addr, so on entry:
;   [X3+0..3]   = return address
;   [X3+4..35]  = set (32 bytes, pushed last = TOS before CALL)
;   [X3+36..37] = element (2 bytes, pushed first)
; Returns D0=1 if member, D0=0 otherwise.
; Caller: EmitClear(34) pops 34 bytes (set+element) after.
; Trashes D0, D1, D2, XY0.
; ------------------------------------------------------------------
__setmember:
                LOADI   D0, #36
                LOADD   D0, [XY3+D0]        ; D0 = element (at X3+36)
                LOADI   D1, #4
                MOVE    X0, X3
                ADD     X0, D1              ; XY0 = X3+4 = set base
                LOADI   Y0, #$00
                MOVE    D1, D0
                SHR     D1
                SHR     D1
                SHR     D1                  ; D1 = byte index (element shr 3)
                ADD     X0, D1              ; XY0 = &set[byte_index]
                AND     D0, #7             ; D0 = bit index (element and 7)
                LOADB   D1, [XY0]           ; D1 = byte with the bit
                CMP     D0, #0
                BEQ.L   .sm_test
.sm_shift:      SHR     D1
                SUB     D0, #1
                BNE.L   .sm_shift
.sm_test:       AND     D1, #1
                MOVE    D0, D1
                RET

__setinclude:
; Add element to set (in place).
; D0 = set address, D1 = element value
; Trashes D2, D3, XY0.
                MOVE    X0, D0
                LOADI   Y0, #$00
                MOVE    D2, D1
                AND     D2, #7             ; D2 = bit index
                SHR     D1
                SHR     D1
                SHR     D1                  ; D1 = byte index
                ADD     X0, D1
                LOADB   D3, [XY0]           ; D3 = current byte
                LOADI   D1, #1
.si_shift:      CMP     D2, #0
                BEQ.L   .si_done
                ADD     D1, D1              ; D1 = 1 shl bit_index
                SUB     D2, #1
                BRA.L   .si_shift
.si_done:       OR      D3, D1
                STOREB  D3, [XY0]
                RET

__setexclude:
; Remove element from set (in place).
; D0 = set address, D1 = element value
; Trashes D2, D3, XY0.
                MOVE    X0, D0
                LOADI   Y0, #$00
                MOVE    D2, D1
                AND     D2, #7
                SHR     D1
                SHR     D1
                SHR     D1
                ADD     X0, D1
                LOADB   D3, [XY0]
                LOADI   D1, #1
.se_shift:      CMP     D2, #0
                BEQ.L   .se_done
                ADD     D1, D1
                SUB     D2, #1
                BRA.L   .se_shift
.se_done:       NOT     D1, D1              ; invert mask
                AND     D3, D1
                STOREB  D3, [XY0]
                RET

__setadd:
; Set union: left |= right.
; CALL24: [X3+0..3]=retaddr, [X3+4..35]=right, [X3+36..67]=left
; Result in left. Caller pops right (32b) after.
; Trashes D0, D1, D2, XY0, XY1.
                LOADI   D0, #4
                MOVE    X0, X3
                ADD     X0, D0              ; XY0 = right (X3+4)
                LOADI   Y0, #$00
                LOADI   D0, #36
                MOVE    X1, X3
                ADD     X1, D0              ; XY1 = left (X3+36)
                LOADI   Y1, #$00
                LOADI   D2, #32
.sa_loop:       LOADB   D0, [XY0]
                LOADB   D1, [XY1]
                OR      D1, D0
                STOREB  D1, [XY1]
                ADD     X0, #1
                ADD     X1, #1
                SUB     D2, #1
                BNE.L   .sa_loop
                RET

__setsub:
; Set difference: left &= ~right.
; CALL24: [X3+0..3]=retaddr, [X3+4..35]=right, [X3+36..67]=left
; Trashes D0, D1, D2, XY0, XY1.
                LOADI   D0, #4
                MOVE    X0, X3
                ADD     X0, D0
                LOADI   Y0, #$00
                LOADI   D0, #36
                MOVE    X1, X3
                ADD     X1, D0
                LOADI   Y1, #$00
                LOADI   D2, #32
.ssub_loop:     LOADB   D0, [XY0]
                NOT     D0, D0
                LOADB   D1, [XY1]
                AND     D1, D0
                STOREB  D1, [XY1]
                ADD     X0, #1
                ADD     X1, #1
                SUB     D2, #1
                BNE.L   .ssub_loop
                RET

__setmul:
; Set intersection: left &= right.
; CALL24: [X3+0..3]=retaddr, [X3+4..35]=right, [X3+36..67]=left
; Trashes D0, D1, D2, XY0, XY1.
                LOADI   D0, #4
                MOVE    X0, X3
                ADD     X0, D0
                LOADI   Y0, #$00
                LOADI   D0, #36
                MOVE    X1, X3
                ADD     X1, D0
                LOADI   Y1, #$00
                LOADI   D2, #32
.sm2_loop:      LOADB   D0, [XY0]
                LOADB   D1, [XY1]
                AND     D1, D0
                STOREB  D1, [XY1]
                ADD     X0, #1
                ADD     X1, #1
                SUB     D2, #1
                BNE.L   .sm2_loop
                RET

__seteq:
; Set equality: D0 = (left == right) ? 1 : 0
; CALL24: [X3+0..3]=retaddr, [X3+4..35]=right, [X3+36..67]=left
; Capture addresses BEFORE pushing D3 (which moves X3).
; Caller does EmitClear(64) then PUSH D0.
; Trashes D1, D2, D3, XY0, XY1.
                LOADI   D0, #4
                MOVE    X0, X3
                ADD     X0, D0              ; XY0 = right (X3+4)
                LOADI   Y0, #$00
                LOADI   D0, #36
                MOVE    X1, X3
                ADD     X1, D0              ; XY1 = left (X3+36)
                LOADI   Y1, #$00
                PUSH    D3, XY3             ; save D3 AFTER capturing X0/X1
                LOADI   D3, #32
                LOADI   D0, #1
.seq_loop:      LOADB   D1, [XY0]
                LOADB   D2, [XY1]
                CMP     D1, D2
                BEQ.L   .seq_next
                LOADI   D0, #0
                POP     D3, XY3
                RET
.seq_next:      ADD     X0, #1
                ADD     X1, #1
                SUB     D3, #1
                BNE.L   .seq_loop
                POP     D3, XY3
                RET

__setleq:
; Subset: D0 = (left <= right) ? 1 : 0
; CALL24: [X3+0..3]=retaddr, [X3+4..35]=right, [X3+36..67]=left
; Trashes D1, D2, D3, XY0, XY1.
                LOADI   D0, #4
                MOVE    X0, X3
                ADD     X0, D0              ; XY0 = right
                LOADI   Y0, #$00
                LOADI   D0, #36
                MOVE    X1, X3
                ADD     X1, D0              ; XY1 = left
                LOADI   Y1, #$00
                PUSH    D3, XY3
                LOADI   D3, #32
                LOADI   D0, #1
.sleq_loop:     LOADB   D1, [XY1]           ; D1 = left byte
                LOADB   D2, [XY0]           ; D2 = right byte
                AND     D2, D1              ; D2 = left & right
                CMP     D2, D1              ; must equal left
                BEQ.L   .sleq_next
                LOADI   D0, #0
                POP     D3, XY3
                RET
.sleq_next:     ADD     X0, #1
                ADD     X1, #1
                SUB     D3, #1
                BNE.L   .sleq_loop
                POP     D3, XY3
                RET

__setgeq:
; Superset: D0 = (left >= right) ? 1 : 0
; CALL24: [X3+0..3]=retaddr, [X3+4..35]=right, [X3+36..67]=left
; Trashes D1, D2, D3, XY0, XY1.
                LOADI   D0, #4
                MOVE    X0, X3
                ADD     X0, D0              ; XY0 = right
                LOADI   Y0, #$00
                LOADI   D0, #36
                MOVE    X1, X3
                ADD     X1, D0              ; XY1 = left
                LOADI   Y1, #$00
                PUSH    D3, XY3
                LOADI   D3, #32
                LOADI   D0, #1
.sgeq_loop:     LOADB   D1, [XY1]           ; D1 = left byte
                LOADB   D2, [XY0]           ; D2 = right byte
                MOVE    D0, D2              ; save right byte
                AND     D0, D1              ; D0 = left & right
                CMP     D0, D2             ; must equal right
                BEQ.L   .sgeq_next
                LOADI   D0, #0
                POP     D3, XY3
                RET
.sgeq_next:     ADD     X0, #1
                ADD     X1, #1
                SUB     D3, #1
                BNE.L   .sgeq_loop
                LOADI   D0, #1
                POP     D3, XY3
                RET



__fpadd:
__fpsub:
__fpmul:
__fpdiv:
__fpmod:
__fpneg:
__flteq:
__fltlt:
__fltleq:
CheckStack:
                RET

; =============================================================
; String built-in routines
; =============================================================
; Pascal string format: byte[0]=length, byte[1..len]=chars
; All addresses are 16-bit offsets in bank $00 (RAM).
; STR_CONCAT ($2300) used as scratch output buffer.
; Routines are NOT reentrant (STRN_SCRATCH is shared).
; =============================================================

; =============================================================
; Pascal string built-in entry points
; Wrappers that fix arg order after EmitCall's POP sequence
; (args POPped D0=last, D1=middle, D2=first).
; =============================================================

; =============================================================
; String built-in wrappers  --  true stdcall convention
;
; CALL24 pushes a 4-byte return address (2 words: PC[15:0] then
; PC[23:16]) before jumping.  So on function entry:
;   [X3+0..3] = return address  (untouched by wrapper)
;   [X3+4]    = last arg pushed (first to arrive at callee)
;   [X3+6]    = next arg ...
;   etc.
;
; For functions, the caller pre-allocates a result slot (SUB X3,#N)
; BEFORE pushing args, so it sits above the args on the stack.
;
; RET #n : return AND advance SP by n (bytes) extra, cleaning args.
;   imm5 range = 0..31.  For __copy the cleanup is 260 bytes so
;   ADD X3, #260 is done manually before a plain RET.
;
; Arg access uses [XY3+Dn] indexed addressing:
;   LOADI  D1, #offset
;   LOADD  D0, [XY3+D1]   -- D0 = mem[X3 + offset]
; Or D0 can serve as its own offset:
;   LOADI  D0, #offset
;   LOADD  D0, [XY3+D0]   -- address computed before D0 is written
; =============================================================

; ------------------------------------------------------------------
; __memcopy_ff -- copy D2 bytes from ROM bank $FF src to RAM dest
; In:  D0 = dest address (16-bit, bank $00)
;      D1 = src address (16-bit, bank $FF)
;      D2 = byte count
; Out: D0, D1, D2 preserved.
; Used for set literal copies (literal data lives in ROM).
; ------------------------------------------------------------------
__memcopy_ff:
                PUSH    D0, XY3
                PUSH    D1, XY3
                PUSH    D2, XY3
                CMP     D2, #0
                BEQ.L   .mcff_done
                MOVE    X0, D0
                MOVE    X1, D1
                LOADI   Y0, #$00            ; dest bank = RAM $00
                LOADI   Y1, #$FF            ; src bank  = ROM $FF
.mcff_loop:     LOADB   D0, [XY1]
                STOREB  D0, [XY0]
                ADD     X0, #1
                ADD     X1, #1
                SUB     D2, #1
                BNE.L   .mcff_loop
.mcff_done:     LOADI   Y0, #$00
                LOADI   Y1, #$00
                POP     D2, XY3
                POP     D1, XY3
                POP     D0, XY3
                RET


; D0 = buf address, D1 = count (bytes), D2 = fill value
; Trashes XY0.
; ------------------------------------------------------------------
__fillchar:
                CMP     D1, #0
                BEQ.L   .fc_done
                MOVE    X0, D0
                LOADI   Y0, #$00
.fc_loop:       STOREB  D2, [XY0]
                ADD     X0, #1
                SUB     D1, #1
                BNE.L   .fc_loop
.fc_done:       RET

; ------------------------------------------------------------------
; __length  --  Length(s): Integer  [V2 ABI]
; D0 = s_addr
; Returns D0 = length byte
; ------------------------------------------------------------------
__length:
                MOVE    X0, D0
                LOADI   Y0, #$00
                LOADB   D0, [XY0]           ; D0 = length byte
                RET

; ------------------------------------------------------------------
; __pos  --  Pos(needle, haystack): Integer  [V2 ABI]
; D0=needle_addr, D1=haystack_addr
; Returns D0 = 1-based position or 0
; ------------------------------------------------------------------
__pos:
                ; D0=needle, D1=haystack -- matches __strpos convention
                CALL24  __strpos            ; D0 = result
                RET

; ------------------------------------------------------------------
; __copy  --  Copy(s, from, count): String  [V2 ABI]
; D0=dest_addr, D1=from(1-based), D2=count, [X3+4]=s_addr
; Returns D0=dest_addr
; ------------------------------------------------------------------
__copy:
                PUSH    D0, XY3             ; save dest
                LOADI   D3, #6
                LOADD   D0, [XY3+D3]        ; D0 = s_addr (at [X3+6] after push)
                POP     D3, XY3             ; D3 = dest, X3 restored
                ; D0=src, D1=from, D2=count, D3=dest
                CALL24  __strcopy           ; D0=dest
                RET     #1w                 ; return + clean up s_addr (1 word = 2 bytes)

; ------------------------------------------------------------------
; __delete  --  Delete(var s, from, count): procedure  [V2 ABI]
; D0=s_addr, D1=from, D2=count
; ------------------------------------------------------------------
__delete:
                ; D0=s_addr, D1=from, D2=count
                CALL24  __strdelete         ; mutates string in place
                RET

; ------------------------------------------------------------------
; __insert  --  Insert(src, var dest, pos): procedure  [V2 ABI]
; D0=src_addr, D1=dest_addr, D2=pos
; ------------------------------------------------------------------
__insert:
                ; D0=src_addr, D1=dest_addr, D2=pos
                CALL24  __strinsert         ; mutates dest in place
                RET

; -------------------------------------------------------------
; __strcopy
; Copy(src, from, count) -> result written to dest
; D0=src addr, D1=from(1-based), D2=count, D3=dest addr
; Returns D0=dest addr
; -------------------------------------------------------------
__strcopy:
                PUSH    D2, XY3
                PUSH    D3, XY3

                MOVE    X1, D0              ; X1 = src base
                LOADI   Y1, #$00
                LOADB   D0, [XY1]           ; D0 = srclen (reuse D0 as temp)

                ; Clamp from: if from < 1 then from = 1
                CMP     D1, #1
                BGE.L   .sc_from_ok
                LOADI   D1, #1
.sc_from_ok:
                ; if from > srclen: empty result
                CMP     D1, D0
                BGT.L   .sc_empty

                ; available = srclen - from + 1
                SUB     D0, D1
                ADD     D0, #1              ; D0 = available
                ; actual = min(count, available)
                CMP     D2, D0
                BLE.L   .sc_count_ok
                MOVE    D2, D0              ; D2 = actual
.sc_count_ok:
                ; Advance src ptr to src[from]: X1 += from (direct)
                ADD     X1, D1              ; X1 -> src[from]
                JMP     .sc_write

.sc_empty:
                LOADI   D2, #0              ; actual = 0
.sc_write:
                ; Write to dest (D3): [0]=actual, [1..actual]=chars
                MOVE    X0, D3
                LOADI   Y0, #$00
                STOREB  D2, [XY0]           ; length byte
                ADD     X0, #1              ; step past it
                CMP     D2, #0
                BEQ.L   .sc_done
.sc_loop:
                LOADB   D0, [XY1]+
                STOREB  D0, [XY0]+
                SUB     D2, #1
                BNE.L   .sc_loop
.sc_done:
                MOVE    D0, D3              ; D0 = dest
                POP     D3, XY3
                POP     D2, XY3
                RET

; -------------------------------------------------------------
; __strpos
; Pos(needle, haystack) -> 1-based position, or 0 if not found
; D0=needle addr, D1=haystack addr
; Returns D0=position
; Uses [XY+D] indexed addressing for inner loop -- no pointer advance.
; -------------------------------------------------------------
__strpos:
                PUSH    D2, XY3
                PUSH    D3, XY3
                SUB     X3, #2            ; save frame pointer (V2: XY2=frame base)
                STOREX  X2, [XY3]

                MOVE    X2, D0              ; X2 = needle base (constant)
                LOADI   Y2, #$00
                MOVE    X1, D1              ; X1 = haystack base (constant)
                LOADI   Y1, #$00

                LOADB   D2, [XY2]           ; D2 = needle length
                LOADB   D3, [XY1]           ; D3 = haystack length

                ; Edge: empty needle -> return 1
                CMP     D2, #0
                BNE.L   .sp_notempty
                LOADI   D0, #1
                JMP     .sp_done

.sp_notempty:
                ; Edge: needle > haystack -> not found
                CMP     D2, D3
                BGT.L   .sp_notfound

                LOADI   D0, #1              ; D0 = i (outer position, 1-based)

.sp_outer:
                ; Boundary: i + needle_len - 1 <= haystack_len
                ; i.e., D0 + D2 - 1 <= D3
                MOVE    D1, D0
                ADD     D1, D2
                SUB     D1, #1              ; D1 = i + needle_len - 1
                CMP     D1, D3
                BGT.L   .sp_notfound        ; past end of haystack

                ; X0 = haystack_base + i - 1  (LEA: XY0 = XY1 + D0, then -1)
                LEA     XY0, XY1+D0         ; X0 = haystack_base + i
                SUB     X0, #1              ; X0 = haystack_base + i - 1

                ; Inner loop: compare needle[D1] vs haystack[i+D1-1] for D1=1..D2
                LOADI   D1, #1              ; D1 = inner index
                PUSH    D0, XY3             ; save i (D0 needed for char loads)

.sp_inner:
                LOADB   D0, [XY0+D1]        ; haystack char at i+D1-1
                LOADB   D3, [XY2+D1]        ; needle char at D1
                CMP     D0, D3
                BNE.L   .sp_mismatch        ; differ -> try next position
                ADD     D1, #1
                CMP     D1, D2
                BLE.L   .sp_inner           ; continue while D1 <= needle_len
                ; D1 > needle_len: full match
                POP     D0, XY3             ; D0 = i (result)
                JMP     .sp_done

.sp_mismatch:
                POP     D0, XY3             ; restore i
                ADD     D0, #1              ; i++
                LOADB   D3, [XY1]           ; reload haystack_len (D3 was clobbered)
                JMP     .sp_outer

.sp_notfound:
                LOADI   D0, #0

.sp_done:
                LOADX   X2, [XY3]            ; restore frame pointer (V2)
                ADD     X3, #2
                POP     D3, XY3
                POP     D2, XY3
                RET

; -------------------------------------------------------------
; __strdelete
; Delete(var s, from, count): remove count chars at from(1-based)
; D0=str addr, D1=from(1-based), D2=count -> mutates str in place
; Built via STRN_SCRATCH to simplify logic, then copied back.
; -------------------------------------------------------------
__strdelete:
                PUSH    D2, XY3
                PUSH    D3, XY3
                SUB     X3, #2            ; save frame pointer (V2: XY2=frame base)
                STOREX  X2, [XY3]

                MOVE    X0, D0              ; X0 = str base (constant)
                LOADI   Y0, #$00
                LOADB   D3, [XY0]           ; D3 = strlen

                ; Clamp from >= 1
                CMP     D1, #1
                BGE.L   .sde_from_ok
                LOADI   D1, #1
.sde_from_ok:
                ; from > len or count <= 0: nothing to do
                CMP     D1, D3
                BGT.L   .sde_done
                CMP     D2, #0
                BLE.L   .sde_done

                ; available = strlen - from + 1
                MOVE    D0, D3
                SUB     D0, D1
                ADD     D0, #1              ; D0 = available
                ; actual = min(count, available)
                CMP     D2, D0
                BLE.L   .sde_actual_ok
                MOVE    D2, D0
.sde_actual_ok:
                ; D2 = actual (chars to delete)
                ; Build result in STRN_SCRATCH:
                ;   [1..from-1]        = str[1..from-1]
                ;   [from..newlen]     = str[from+actual..strlen]
                ;   [0]                = strlen - actual

                LOADI   X1, #<STRN_SCRATCH
                LOADI   Y1, #$00
                ADD     X1, #1              ; X1 = STRN_SCRATCH[1]

                ; Phase 1: copy str[1..from-1]
                ; X2 = str_base + 1  (all strings in bank 0, LEA safe)
                LEA     XY2, XY0+#1         ; X2 = str[1] read ptr

                MOVE    D0, D1
                SUB     D0, #1              ; D0 = from-1 = phase1 count
                CMP     D0, #0
                BEQ.L   .sde_phase2
.sde_p1_loop:
                LOADB   D3, [XY2]
                STOREB  D3, [XY1]
                ADD     X2, #1
                ADD     X1, #1
                SUB     D0, #1
                BNE.L   .sde_p1_loop

.sde_phase2:
                ; Phase 2: copy str[from+actual..strlen]
                ; X2 = str_base + D1 + D2  (LEA then direct ADD on X)
                LEA     XY2, XY0+D1         ; X2 = str_base + from
                ADD     X2, D2              ; X2 = str_base + from + actual

                ; phase2 count = strlen - from - actual + 1
                LOADB   D3, [XY0]           ; D3 = strlen (reload, X0=str_base)
                MOVE    D0, D3
                SUB     D0, D1              ; D0 = strlen - from
                SUB     D0, D2              ; D0 = strlen - from - actual
                ADD     D0, #1              ; D0 = phase2 count
                CMP     D0, #0
                BLE.L   .sde_write_len
.sde_p2_loop:
                LOADB   D3, [XY2]
                STOREB  D3, [XY1]
                ADD     X2, #1
                ADD     X1, #1
                SUB     D0, #1
                BNE.L   .sde_p2_loop

.sde_write_len:
                ; Write new length to STRN_SCRATCH[0]
                LOADB   D3, [XY0]           ; D3 = strlen
                SUB     D3, D2              ; D3 = strlen - actual = new length
                LOADI   X1, #<STRN_SCRATCH
                LOADI   Y1, #$00
                STOREB  D3, [XY1]           ; STRN_SCRATCH[0] = new length

                ; Copy STR_CONCAT back to str (X0 = str base)
                MOVE    D0, X0              ; D0 = str_base
                LOADI   D1, #<STRN_SCRATCH
                LOADI   D2, #255
                CALL24  __storestr

.sde_done:
                LOADX   X2, [XY3]            ; restore frame pointer (V2)
                ADD     X3, #2
                POP     D3, XY3
                POP     D2, XY3
                RET

; -------------------------------------------------------------
; __strinsert
; Insert(src, var dest, pos): insert src into dest at pos(1-based)
; D0=src addr, D1=dest addr, D2=pos(1-based) -> mutates dest
; Uses [XY+D] indexed addressing. X1=dest_base, X2=src_base kept constant.
; -------------------------------------------------------------
__strinsert:
                PUSH    D2, XY3             ; save pos (callee-save)
                PUSH    D3, XY3             ; callee-save
                SUB     X3, #2            ; save frame pointer (V2: XY2=frame base)
                STOREX  X2, [XY3]

                MOVE    X1, D1              ; X1 = dest base (CONSTANT throughout)
                LOADI   Y1, #$00
                MOVE    X2, D0              ; X2 = src base (CONSTANT throughout)
                LOADI   Y2, #$00

                LOADB   D3, [XY1]           ; D3 = destlen
                LOADB   D0, [XY2]           ; D0 = srclen

                ; Clamp pos (D2): 1 <= pos <= destlen+1
                CMP     D2, #1
                BGE.L   .si_ge1
                LOADI   D2, #1
.si_ge1:
                MOVE    D1, D3
                ADD     D1, #1              ; D1 = destlen+1
                CMP     D2, D1
                BLE.L   .si_pos_ok
                MOVE    D2, D1              ; pos = destlen+1 (append)
.si_pos_ok:
                ; actual = min(srclen, 255-destlen)
                LOADI   D1, #255
                SUB     D1, D3              ; D1 = available = 255 - destlen
                CMP     D0, D1
                BLE.L   .si_actual_ok
                MOVE    D0, D1              ; D0 = actual = available
.si_actual_ok:
                CMP     D0, #0
                BEQ.L   .si_done           ; nothing to insert

                ; D0=actual, D2=pos, D3=destlen
                ; Build result in STRN_SCRATCH using [XY1+D] and [XY2+D] indexed loads.
                ; X0 = STR_CONCAT write ptr (starts at offset 1, advances).
                LOADI   X0, #<STRN_SCRATCH
                LOADI   Y0, #$00
                ADD     X0, #1              ; X0 -> STRN_SCRATCH[1]

                ; --- Phase 1: copy dest[1..pos-1] via [XY1+D1] ---
                LOADI   D1, #1              ; D1 = index (1-based)
.si_p1:
                CMP     D1, D2              ; D1 vs pos
                BGE.L   .si_p2             ; D1 >= pos -> stop (done pos-1 chars)
                LOADB   D3, [XY1+D1]        ; dest[D1]
                STOREB  D3, [XY0]
                ADD     X0, #1
                ADD     D1, #1
                JMP     .si_p1

                ; --- Phase 2: copy src[1..actual] via [XY2+D1] ---
.si_p2:
                LOADI   D1, #1
.si_p2_loop:
                CMP     D1, D0              ; D1 vs actual
                BGT.L   .si_p3             ; D1 > actual -> done
                LOADB   D3, [XY2+D1]        ; src[D1]
                STOREB  D3, [XY0]
                ADD     X0, #1
                ADD     D1, #1
                JMP     .si_p2_loop

                ; --- Phase 3: copy dest[pos..destlen] via [XY1+D1] ---
.si_p3:
                LOADB   D3, [XY1]           ; D3 = destlen (byte 0 of dest)
                MOVE    D1, D2              ; D1 = pos (start)
                PUSH    D0, XY3             ; save actual (D0 needed as byte temp)
.si_p3_loop:
                CMP     D1, D3              ; D1 vs destlen
                BGT.L   .si_p3_done        ; D1 > destlen -> done
                LOADB   D0, [XY1+D1]        ; dest[D1]
                STOREB  D0, [XY0]
                ADD     X0, #1
                ADD     D1, #1
                JMP     .si_p3_loop
.si_p3_done:
                POP     D0, XY3             ; restore actual

                ; Write length: STRN_SCRATCH[0] = destlen + actual
                ; D3 = destlen (preserved from above since not modified in p3 loop)
                ADD     D3, D0              ; D3 = destlen + actual
                LOADI   X0, #<STRN_SCRATCH
                LOADI   Y0, #$00
                STOREB  D3, [XY0]

                ; Copy STR_CONCAT back to dest
                MOVE    D0, X1              ; D0 = dest_base
                LOADI   D1, #<STRN_SCRATCH
                LOADI   D2, #255
                CALL24  __storestr

.si_done:
                LOADX   X2, [XY3]            ; restore frame pointer (V2)
                ADD     X3, #2
                POP     D3, XY3
                POP     D2, XY3
                RET
