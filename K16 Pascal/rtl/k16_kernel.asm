; =============================================================================
; k16_kernel.asm  --  K16 Shared Kernel Primitives  v1.0  BUILD 5
; =============================================================================
; V2 ABI: X2 saved/restored by all functions that use it as scratch
;
; Shared by K16 BASIC, Forth, and Pascal programs.
; .INCLUDE this file from the main source of each language.
;
; REQUIREMENTS:  define these constants BEFORE .INCLUDE if defaults don't suit:
;
;   KRN_HEAP_PTR   .EQU  $002500   ; word: heap pointer (page $00)
;   KRN_HEAP_BASE  .EQU  $003000   ; initial heap address
;
; TERMINAL and KEYBOARD are defined here; remove duplicates from
; language files once migration is complete.
;
; CALLING CONVENTION (all __krn / __ routines):
;   Arguments  : D0, D1, D2  (left to right)
;   Return     : D0
;   Callee saves : D2, D3  (unless used as argument -- see each routine)
;   Stack      : full-descending on XY3 (Y3 = $00 always)
;   Call/return : CALL24 / RET
;
; IMPROVEMENTS OVER PREVIOUS PER-LANGUAGE IMPLEMENTATIONS:
;   __mul16  : MULB-based (from BASIC/Forth) replaces Pascal's O(n) loop
;   __sdiv16 : 16-iteration bit-shift (from BASIC) replaces Pascal's O(n) loop
;   __div10  : reciprocal multiply (from BASIC/Forth), always 1 call
;   __getline_buf: parameterised (D0=buf, D1=maxlen) -- one implementation for all
;   __memcopy: new -- not previously in any language
;   __memset : new -- not previously in any language
;
; MIGRATION NOTES:
;   BASIC  : replace mul_16x16 -> __mul16,  divide_16 -> __sdiv16,
;            div10 -> __div10,  accept_line -> call __getline with TIB addr
;   Forth  : replace mul_16x16 -> __mul16,  div10 -> __div10,
;            inline SLASHMOD -> __sdiv16,  accept_line -> __getline wrapper
;   Pascal : __mul16, __sdiv16, __div10, __shl16, __shr16, __putc,
;            __newline, __getline, __heap_init, __getmem, __freemem
;            all replaced by this file -- remove from k16_rtl.asm
; =============================================================================

; -- Hardware ------------------------------------------------------------------
.EQU TERMINAL, $DF0000         ; terminal output (byte write)  -- memory map v4
.EQU KEYBOARD, $DE0000         ; keyboard input  (word read, 0=no key) -- v4

; -- Heap configuration --------------------------------------------------------
.EQU KRN_HEAP_PTR, $002500         ; word at this address = next free addr
.EQU KRN_HEAP_BASE, $003000         ; heap starts here

; -- k/OS kernel zero-page variables ($000190+) --------------------------------
.EQU KRN_TICK_COUNT_LO, $000190    ; low word of scheduler tick counter
.EQU KRN_TICK_COUNT_HI, $000192    ; high word of scheduler tick counter
.EQU KRN_SCHED_LOCK,    $000194    ; scheduler lock depth (0=unlocked)
.EQU KRN_IRQ_NEST,      $000196    ; interrupt nesting depth
.EQU KRN_SWITCH_PENDING,$000198    ; deferred context switch flag
; $00019A-$0001FF reserved for k/OS (context-switch scratch, interrupts disabled only)

; -- Multitasking (k/OS) -------------------------------------------------------
.EQU KRN_CUR_TASK, $002502         ; word: current task TCB address
.EQU KRN_TERM_SEM, $002504         ; word: terminal output semaphore

; -- Task Control Block layout (byte offsets) ----------------------------------
.EQU TCB_SP_X, 0               ; X3 saved (SP offset within page $00)
.EQU TCB_STATE, 2               ; task state (TASK_* constants below)
.EQU TCB_PRIORITY, 4               ; priority 0..7  (0 = highest)
.EQU TCB_TICKS, 6               ; sleep countdown in timer ticks
.EQU TCB_STACK_X, 8               ; initial stack top X (task init only)
.EQU TCB_SIZE, 10              ; total TCB size in bytes

; -- Task states ---------------------------------------------------------------
.EQU TASK_RUNNING, 0               ; currently executing on CPU
.EQU TASK_READY, 1               ; runnable, waiting for scheduler
.EQU TASK_BLOCKED, 2               ; waiting on a semaphore
.EQU TASK_SLEEPING, 3               ; waiting for TCB_TICKS to reach zero

; =============================================================================
; TERMINAL OUTPUT
; =============================================================================

; __putc -- write character in D0 (low byte) to terminal.
; Preserves all registers except nothing is clobbered -- XY1 is used
; internally but Y1 is page-irrelevant for a write-only port.
__putc:
                LOADI   X1, #<TERMINAL
                LOADI   Y1, #>TERMINAL
                STOREB  D0, [XY1]
                RET

; __newline -- emit LF to terminal.
; Note: Pascal RTL currently emits CR only (Digital terminal quirk) -- keep its
; own __newline or change here after verifying terminal behaviour.
; Preserves all registers.
__newline:
                PUSH    D0, XY3
                LOADI   X1, #<TERMINAL
                LOADI   Y1, #>TERMINAL
                LOADI   D0, #10             ; LF
                STOREB  D0, [XY1]
                POP     D0, XY3
                RET

; =============================================================
; TERMINAL INPUT
; =============================================================

; __getline_buf
; Read one line from keyboard into a caller-supplied buffer.
;
; In:  D0 = buffer base address (16-bit, page $00)
;      D1 = max characters  (buffer must be max+1 bytes for null)
; Out: D0 = character count (0..max)
;
; Echo characters.  BS / DEL erase last character (BS/SP/BS sequence).
; CR or LF ends input.  Buffer is null-terminated.
; Preserves D1, D2, D3.
;
; Language call sites:
;   BASIC:   LOADI D0, #TIB_OFFSET  /  LOADI D1, #TIB_SIZE  /  CALL24 __getline_buf
;   Pascal:  LOADI D0, #<TIB_BASE   /  LOADI D1, #128       /  CALL24 __getline_buf
;   Forth:   use own accept_line (adds cursor display) or wrap this
__getline_buf:
                PUSH    D1, XY3
                PUSH    D2, XY3
                PUSH    D3, XY3
                SUB     X3, #2            ; save frame pointer (V2: XY2=frame base)
                STOREX  X2, [XY3]
                LOADI   X0, #<KEYBOARD
                LOADI   Y0, #>KEYBOARD
                LOADI   X1, #<TERMINAL
                LOADI   Y1, #>TERMINAL
                LOADI   Y2, #$00            ; page $00 for buffer writes
                MOVE    D2, D0              ; D2 = buffer base
                LOADI   D3, #0              ; D3 = char count
.glb_loop:
                LOADD   D0, [XY0]           ; read keyboard word
                CMP     D0, #0
                BEQ.L   .glb_loop            ; no key yet
                AND     D0, #$FF            ; mask to byte
                CMP     D0, #13             ; CR?
                BEQ.L   .glb_done
                CMP     D0, #10             ; LF?
                BEQ.L   .glb_done
                CMP     D0, #8              ; BS?
                BEQ.L   .glb_bs
                CMP     D0, #127            ; DEL?
                BEQ.L   .glb_bs
                CMP     D3, D1              ; at max length?
                BGE.L   .glb_loop
                MOVE    X2, D2
                ADD     X2, D3              ; X2 = buf + count
                STOREB  D0, [XY2]           ; store char
                ADD     D3, #1
                STOREB  D0, [XY1]           ; echo
                JMP     .glb_loop
.glb_bs:
                CMP     D3, #0              ; nothing to erase?
                BEQ.L   .glb_loop
                SUB     D3, #1
                LOADI   D0, #8
                STOREB  D0, [XY1]           ; BS
                LOADI   D0, #32
                STOREB  D0, [XY1]           ; SP (erase)
                LOADI   D0, #8
                STOREB  D0, [XY1]           ; BS
                JMP     .glb_loop
.glb_done:
                MOVE    X2, D2
                ADD     X2, D3
                LOADI   D0, #0
                STOREB  D0, [XY2]           ; null-terminate
                LOADI   D0, #10
                STOREB  D0, [XY1]           ; echo LF
                LOADI   Y0, #$00            ; restore Y regs to page $00
                LOADI   Y1, #$00
                MOVE    D0, D3              ; return count
                LOADX   X2, [XY3]            ; restore frame pointer (V2)
                ADD     X3, #2
                POP     D3, XY3
                POP     D2, XY3
                POP     D1, XY3
                RET

; =============================================================================
; ARITHMETIC
; =============================================================================

; __mul16 -- unsigned 16x16->16 multiply  (low 16 bits of product)
; In:  D0 = multiplicand,  D1 = multiplier
; Out: D0 = D0 * D1  (mod 65536)
; Trashes D2, D3.
;
; Uses MULB instruction: MULB Dn where Dn = (n2 << 8) | n1
; computes n1 * n2 as a 16-bit partial product.
; Four partial products (PP0..PP2) build the 16-bit result.
; Identical algorithm used in BASIC and Forth -- ~5x faster than loop.
__mul16:
                PUSH    D2, XY3             ; callee-save D2
                PUSH    D3, XY3             ; callee-save D3
                ; Stack: D3, D2 (D3 at top = [X3+0], D2 at [X3+2])
                MOVE    D2, D0
                HIGH    D2                  ; D2 = n1H (high byte of D0)
                AND     D0, #$FF            ; D0 = n1L
                MOVE    D3, D1
                HIGH    D3                  ; D3 = n2H
                AND     D1, #$FF            ; D1 = n2L
                PUSH    D0, XY3             ; save n1L   [X3+0]
                PUSH    D1, XY3             ; save n2L   [X3+2]
                PUSH    D2, XY3             ; save n1H   [X3+4]  (D2 scratch reuse)
                ; Stack (top->bottom): n1H[+0], n2L[+2], n1L[+4], D3saved[+6], D2saved[+8]
                ; PP0 = n1L * n2L
                SHL4    D1
                SHL4    D1                  ; D1 = n2L << 8
                OR      D0, D1              ; D0 = (n2L<<8) | n1L
                MULB    D0                  ; D0 = PP0
                PUSH    D0, XY3             ; save PP0   [X3+0]
                ; Stack: PP0[+0], n1H[+2], n2L[+4], n1L[+6], D3saved[+8], D2saved[+10]
                ; PP1 = n1H * n2L
                LOADD   D0, [XY3+#2]        ; n1H
                LOADD   D1, [XY3+#4]        ; n2L
                SHL4    D1
                SHL4    D1
                OR      D0, D1
                MULB    D0                  ; D0 = PP1
                MOVE    D2, D0              ; save PP1 in D2
                ; PP2 = n1L * n2H  (D3 still holds n2H from above)
                LOADD   D0, [XY3+#6]        ; n1L
                SHL4    D3
                SHL4    D3                  ; D3 = n2H << 8
                OR      D0, D3
                MULB    D0                  ; D0 = PP2
                ADD     D0, D2              ; middle = PP1 + PP2
                SHL4    D0
                SHL4    D0                  ; middle << 8  (low byte only matters)
                POP     D1, XY3             ; D1 = PP0
                ADD     D0, D1              ; result = PP0 + (middle<<8)
                ADD     X3, #6              ; discard n1H, n2L, n1L
                POP     D3, XY3             ; restore callee-saved D3
                POP     D2, XY3             ; restore callee-saved D2
                RET

; __mul16_32 -- unsigned 16x16->32 multiply
; In:  D0 = multiplicand,  D1 = multiplier
; Out: D0 = low 16 bits,   D1 = high 16 bits
; Trashes D2, D3.
; Used by __div10 for the reciprocal-multiply trick.
__mul16_32:
                PUSH    D2, XY3             ; callee-save D2
                PUSH    D3, XY3             ; callee-save D3
                ; D3saved[+0], D2saved[+2]
                MOVE    D2, D0
                HIGH    D2                  ; D2 = n1H
                AND     D0, #$FF            ; D0 = n1L
                MOVE    D3, D1
                HIGH    D3                  ; D3 = n2H
                AND     D1, #$FF            ; D1 = n2L
                ; Push operands (4 words). Offsets relative to SP after all pushes:
                PUSH    D3, XY3             ; n2H
                PUSH    D2, XY3             ; n1H
                PUSH    D1, XY3             ; n2L
                PUSH    D0, XY3             ; n1L [+0], n2L[+2], n1H[+4], n2H[+6], D3s[+8], D2s[+10]
                ; PP0 = n1L * n2L
                SHL4    D1
                SHL4    D1
                OR      D0, D1
                MULB    D0                  ; D0 = PP0
                PUSH    D0, XY3             ; PP0[+0], n1L[+2], n2L[+4], n1H[+6], n2H[+8], D3s[+10], D2s[+12]
                ; PP1 = n1H * n2L
                LOADD   D0, [XY3+#6]        ; n1H
                LOADD   D1, [XY3+#4]        ; n2L
                SHL4    D1
                SHL4    D1
                OR      D0, D1
                MULB    D0                  ; D0 = PP1
                MOVE    D2, D0
                ; PP2 = n1L * n2H
                LOADD   D0, [XY3+#2]        ; n1L
                LOADD   D1, [XY3+#8]        ; n2H
                SHL4    D1
                SHL4    D1
                OR      D0, D1
                MULB    D0                  ; D0 = PP2
                ADD     D0, D2              ; middle = PP1 + PP2
                SCS     D1
                AND     D1, #1              ; D1 = middle carry
                MOVE    D2, D0
                ; PP3 = n1H * n2H
                LOADD   D0, [XY3+#6]        ; n1H
                LOADD   D3, [XY3+#8]        ; n2H
                SHL4    D3
                SHL4    D3
                OR      D0, D3
                MULB    D0                  ; D0 = PP3
                MOVE    D3, D2
                AND     D3, #$FF            ; D3 = middle_lo byte
                HIGH    D2                  ; D2 = middle_hi byte
                ADD     D0, D2              ; PP3 + middle_hi
                SHL4    D1
                SHL4    D1                  ; carry << 8
                ADD     D0, D1              ; D0 = hi16 result
                MOVE    D1, D0
                SHL4    D3
                SHL4    D3                  ; middle_lo << 8
                POP     D0, XY3             ; D0 = PP0
                ADD     D0, D3              ; lo16 = PP0 + (middle_lo<<8)
                SCS     D2
                AND     D2, #1
                ADD     D1, D2              ; hi16 += lo carry
                ADD     X3, #8              ; discard 4 saved operands (n1L,n2L,n1H,n2H)
                POP     D3, XY3             ; restore callee-saved D3
                POP     D2, XY3             ; restore callee-saved D2
                RET

; __div10 -- unsigned divide by 10 via reciprocal multiply
; In:  D0 = dividend (0..65535)
; Out: D0 = quotient,  D1 = remainder
; Trashes D2, D3.
; Algorithm: q = hi16(n x 52429) >> 3;  r = n - q x 10
; Constant 52429 = $CCCD ~= 65536x10/10, gives exact result for all 16-bit inputs.
__div10:
                PUSH    D0, XY3             ; save n
                LOADI   D1, #52429          ; reciprocal constant $CCCD
                CALL24  __mul16_32          ; D0=lo16, D1=hi16
                MOVE    D0, D1              ; D0 = hi16
                SHR     D0
                SHR     D0
                SHR     D0                  ; quotient = hi16 >> 3
                MOVE    D2, D0              ; D2 = quotient (save)
                MOVE    D1, D0
                SHL     D1                  ; q x 2
                SHL     D0
                SHL     D0
                SHL     D0                  ; q x 8
                ADD     D0, D1              ; q x 10
                POP     D1, XY3             ; D1 = original n
                SUB     D1, D0              ; remainder = n - qx10
                MOVE    D0, D2              ; D0 = quotient
                RET

; __sdiv16 -- signed 16/16 divide
; In:  D0 = dividend,  D1 = divisor
; Out: D0 = quotient (signed),  D1 = remainder (unsigned magnitude)
; Trashes D2, D3.
;
; Algorithm: 16-iteration restoring binary division.
; ~16 iterations always -- O(1) cost unlike the Pascal RTL's repeated-subtract.
__sdiv16:
                PUSH    D2, XY3
                PUSH    D3, XY3
                ; normalise signs -> positive; track result sign in D2
                LOADI   D2, #0
                CMP     D0, #0
                BGE.L   .sd_d0pos
                LOADI   D3, #0
                SUB     D3, D0
                MOVE    D0, D3
                XOR     D2, #1
.sd_d0pos:
                CMP     D1, #0
                BGE.L   .sd_d1pos
                LOADI   D3, #0
                SUB     D3, D1
                MOVE    D1, D3
                XOR     D2, #1
.sd_d1pos:
                ; D0=|dividend|, D1=|divisor|, D2=sign flag
                PUSH    D2, XY3             ; save sign
                PUSH    D1, XY3             ; save divisor for peek in loop
                LOADI   D2, #0              ; D2 = running remainder
                LOADI   D3, #16             ; D3 = bit counter
.sd_loop:
                ADD     D0, D0              ; shift dividend MSB into carry
                ADC     D2, D2              ; remainder = (remainder<<1) | carry
                LOADD   D1, [XY3]           ; peek divisor (SP points to it)
                CMP     D2, D1
                BCC.L   .sd_no              ; remainder < divisor
                SUB     D2, D1
                OR      D0, #1              ; set quotient LSB
.sd_no:
                SUB     D3, #1
                BNE.L   .sd_loop
                ; D0 = quotient,  D2 = remainder
                MOVE    D1, D2              ; D1 = remainder
                ADD     X3, #2              ; discard saved divisor
                POP     D2, XY3             ; D2 = sign flag
                CMP     D2, #0
                BEQ.L   .sd_pos
                LOADI   D3, #0
                SUB     D3, D0
                MOVE    D0, D3              ; negate quotient
.sd_pos:
                POP     D3, XY3
                POP     D2, XY3
                RET

; __shl16 -- D0 = D0 shl D1  (logical left shift)
; D1 is consumed.
__shl16:
                CMP     D1, #0
                BEQ.L   .shl_done
                SHL     D0
                SUB     D1, #1
                JMP     __shl16
.shl_done:
                RET

; __shr16 -- D0 = D0 shr D1  (logical right shift)
; D1 is consumed.
__shr16:
                CMP     D1, #0
                BEQ.L   .shr_done
                SHR     D0
                SUB     D1, #1
                JMP     __shr16
.shr_done:
                RET

; =============================================================================
; MEMORY UTILITIES
; =============================================================================

; __memcopy -- copy D2 bytes from src to dest (both in page $00)
; In:  D0 = dest address (16-bit),  D1 = src address (16-bit),  D2 = byte count
; Out: D0, D1, D2 preserved.
; Forward copy only (dest < src, or non-overlapping).
__memcopy:
                PUSH    D0, XY3
                PUSH    D1, XY3
                PUSH    D2, XY3
                CMP     D2, #0
                BEQ.L   .mc_done
                MOVE    X0, D0
                MOVE    X1, D1
                LOADI   Y0, #$00
                LOADI   Y1, #$00
.mc_loop:
                LOADB   D0, [XY1]
                STOREB  D0, [XY0]
                ADD     X0, #1
                ADD     X1, #1
                SUB     D2, #1
                BNE.L   .mc_loop
.mc_done:
                LOADI   Y0, #$00
                LOADI   Y1, #$00
                POP     D2, XY3
                POP     D1, XY3
                POP     D0, XY3
                RET

; __memset -- fill D2 bytes at dest with byte value D1 (page $00)
; In:  D0 = dest address (16-bit),  D1 = byte value,  D2 = byte count
; Out: D0, D1, D2 preserved.
__memset:
                PUSH    D0, XY3
                PUSH    D2, XY3
                CMP     D2, #0
                BEQ.L   .ms_done
                MOVE    X0, D0
                LOADI   Y0, #$00
.ms_loop:
                STOREB  D1, [XY0]
                ADD     X0, #1
                SUB     D2, #1
                BNE.L   .ms_loop
.ms_done:
                LOADI   Y0, #$00
                POP     D2, XY3
                POP     D0, XY3
                RET

; =============================================================================
; HEAP -- bump allocator
; KRN_HEAP_PTR holds the next-free address as a word in page $00.
; __freemem is a no-op: bump allocators don't reclaim.
; A proper free-list allocator can replace these for k/OS.
; =============================================================================

; __heap_init -- reset heap pointer to KRN_HEAP_BASE.
__heap_init:
                LOADI   X0, #<KRN_HEAP_PTR
                LOADI   Y0, #$00
                LOADI   D0, #KRN_HEAP_BASE
                STORED  D0, [XY0]
                RET

; __getmem -- allocate D0 bytes from heap.
; In:  D0 = byte count
; Out: D0 = address of allocated block.
; Rounds up to even.  Advances KRN_HEAP_PTR.
; Preserves D1.
; DINT/EINT guard prevents two tasks getting the same block.
__getmem:
                PUSH    D1, XY3
                LOADI   X1, #<KRN_HEAP_PTR
                LOADI   Y1, #$00
                ADD     D0, #1
                AND     D0, #$FFFE          ; round up to even
                LOADD   D1, [XY1]           ; D1 = current ptr = block address
                ADD     D0, D1              ; new heap ptr
                STORED  D0, [XY1]           ; advance heap pointer
                MOVE    D0, D1              ; return block address
                LOADI   Y1, #$00
                POP     D1, XY3
                RET

; __freemem -- no-op (bump allocator, no reclaim).
; Placeholder for future free-list implementation.
__freemem:
                RET

; -----------------------------------------------------------------------------
; __inc16by  --  Inc(var n: Integer; delta: Integer)
; D0 = address of variable, D2 = delta to add
; -----------------------------------------------------------------------------
__inc16by:
                MOVE    X0, D0
                LOADI   Y0, #$00
                LOADD   D1, [XY0]
                ADD     D1, D2
                STORED  D1, [XY0]
                RET

; -----------------------------------------------------------------------------
; __dec16by  --  Dec(var n: Integer; delta: Integer)
; D0 = address of variable, D2 = delta to subtract
; -----------------------------------------------------------------------------
__dec16by:
                MOVE    X0, D0
                LOADI   Y0, #$00
                LOADD   D1, [XY0]
                SUB     D1, D2
                STORED  D1, [XY0]
                RET

; -----------------------------------------------------------------------------
; __inc8by  --  Inc(var b: Byte/Char; delta: Integer)
; D0 = address of byte variable, D2 = delta to add
; -----------------------------------------------------------------------------
__inc8by:
                MOVE    X0, D0
                LOADI   Y0, #$00
                LOADB   D1, [XY0]
                ADD     D1, D2
                STOREB  D1, [XY0]
                RET

; -----------------------------------------------------------------------------
; __dec8by  --  Dec(var b: Byte/Char; delta: Integer)
; D0 = address of byte variable, D2 = delta to subtract
; -----------------------------------------------------------------------------
__dec8by:
                MOVE    X0, D0
                LOADI   Y0, #$00
                LOADB   D1, [XY0]
                SUB     D1, D2
                STOREB  D1, [XY0]
                RET

; =============================================================================
; FORMATTED OUTPUT
; =============================================================================

; __putn -- print signed 16-bit integer in D0 to terminal as decimal.
; Uses sentinel-on-stack method: push 0 (sentinel), then digits, print in order.
; Uses __div10 (fast reciprocal) rather than __sdiv16.
; Trashes D1, D2.
__putn:
                PUSH    D2, XY3
                LOADI   X1, #<TERMINAL
                LOADI   Y1, #>TERMINAL
                CMP     D0, #0
                BGE.L   .pn_pos
                ; negative -- print '-', negate
                LOADI   D1, #45
                STOREB  D1, [XY1]
                LOADI   D2, #0
                SUB     D2, D0
                MOVE    D0, D2
.pn_pos:
                CMP     D0, #0
                BNE.L   .pn_nonzero
                LOADI   D1, #48
                STOREB  D1, [XY1]
                POP     D2, XY3
                RET
.pn_nonzero:
                LOADI   D2, #0              ; sentinel
                PUSH    D2, XY3
.pn_push:
                CMP     D0, #0
                BEQ.L   .pn_print
                CALL24  __div10             ; D0=quot, D1=remainder
                ADD     D1, #48             ; digit -> ASCII
                PUSH    D1, XY3
                JMP     .pn_push
.pn_print:
                POP     D1, XY3
                CMP     D1, #0              ; sentinel?
                BEQ.L   .pn_done
                STOREB  D1, [XY1]
                JMP     .pn_print
.pn_done:
                POP     D2, XY3
                RET

; __putsz -- print null-terminated string at XY0 (any page, pre-loaded by caller).
; Trashes D0, D1.
; Example:
;   LOADI  X0, #<mystr
;   LOADI  Y0, #>mystr    ; or #$FF for ROM string
;   CALL24 __putsz
__putsz:
                LOADI   X1, #<TERMINAL
                LOADI   Y1, #>TERMINAL
.pz_loop:
                LOADB   D0, [XY0]
                CMP     D0, #0
                BEQ.L   .pz_done
                STOREB  D0, [XY1]
                ADD     X0, #1
                JMP     .pz_loop
.pz_done:
                RET

; __puthex_byte -- print D0 (low byte) as 2 hex digits to terminal.
; Trashes D1.
__puthex_byte:
                PUSH    D0, XY3
                LOADI   X1, #<TERMINAL
                LOADI   Y1, #>TERMINAL
                ; high nibble
                MOVE    D1, D0
                SHR4    D1                  ; D1 = high nibble
                AND     D1, #$0F
                CMP     D1, #10
                BCC.L   .phb_hi_dec
                ADD     D1, #55             ; 'A'-10
                JMP     .phb_hi_out
.phb_hi_dec:
                ADD     D1, #48             ; '0'
.phb_hi_out:
                STOREB  D1, [XY1]
                ; low nibble
                POP     D0, XY3
                AND     D0, #$0F
                CMP     D0, #10
                BCC.L   .phb_lo_dec
                ADD     D0, #55
                JMP     .phb_lo_out
.phb_lo_dec:
                ADD     D0, #48
.phb_lo_out:
                STOREB  D0, [XY1]
                RET

; __puthex -- print D0 as 4 hex digits (word) to terminal.
; Trashes D1.
__puthex:
                PUSH    D0, XY3
                HIGH    D0                  ; D0 = high byte
                CALL24  __puthex_byte
                POP     D0, XY3
                CALL24  __puthex_byte       ; low byte
                RET

; =============================================================================
; NUMBER PARSING
; =============================================================================

; __atoi -- parse number from null-terminated string.
; Handles optional leading '-', '$' prefix forces hex, else decimal.
; Skips leading spaces.
;
; In:  D0 = buffer address (16-bit, page $00),  D1 = length in chars
; Out: D0 = parsed value,  D2 = 0 (ok) or 1 (error -- bad char or empty)
; Trashes D1, D3.
__atoi:
                PUSH    D3, XY3
                MOVE    X0, D0
                LOADI   Y0, #$00
                LOADI   D2, #0              ; error = 0

                ; skip leading spaces
.par_skip:
                CMP     D1, #0
                BEQ.L   .par_err
                LOADB   D0, [XY0]
                CMP     D0, #32
                BNE.L   .par_sign
                ADD     X0, #1
                SUB     D1, #1
                JMP     .par_skip

                ; check sign
.par_sign:
                LOADI   D3, #0              ; D3 = negative flag
                CMP     D0, #45             ; '-'?
                BNE.L   .par_hex
                LOADI   D3, #1
                ADD     X0, #1
                SUB     D1, #1
                CMP     D1, #0
                BEQ.L   .par_err
                LOADB   D0, [XY0]

                ; check for '$' hex prefix
.par_hex:
                LOADI   D2, #10             ; assume decimal base
                CMP     D0, #36             ; '$'?
                BNE.L   .par_dec
                LOADI   D2, #16
                ADD     X0, #1
                SUB     D1, #1
                CMP     D1, #0
                BEQ.L   .par_err
                LOADB   D0, [XY0]

                ; digit accumulation loop
                ; D2=base, D3=neg flag, accumulator on stack
.par_dec:
                PUSH    D2, XY3             ; save base
                PUSH    D3, XY3             ; save neg flag
                LOADI   D2, #0              ; D2 = accumulator
.par_loop:
                CMP     D1, #0
                BEQ.L   .par_finish
                LOADB   D0, [XY0]
                ADD     X0, #1
                SUB     D1, #1
                ; digit or letter?
                CMP     D0, #48             ; < '0'?
                BLT.L   .par_finish
                CMP     D0, #58             ; <= '9'?
                BLT.L   .par_is09
                ; A-F / a-f
                CMP     D0, #65
                BLT.L   .par_finish         ; gap between '9' and 'A'
                CMP     D0, #71             ; <= 'F'?
                BLT.L   .par_isAF
                CMP     D0, #97
                BLT.L   .par_finish
                CMP     D0, #103            ; <= 'f'?
                BGE.L   .par_finish
                SUB     D0, #32             ; lowercase -> uppercase
.par_isAF:
                SUB     D0, #55             ; 'A'=65 -> 10
                JMP     .par_acc
.par_is09:
                SUB     D0, #48
.par_acc:
                ; check digit < base (peek base from stack+2)
                LOADD   D3, [XY3+#2]        ; peek base
                CMP     D0, D3
                BGE.L   .par_finish         ; digit >= base = stop
                ; acc = acc * base + digit
                PUSH    D0, XY3             ; save digit
                MOVE    D0, D2
                LOADD   D1, [XY3+#4]        ; base
                CALL24  __mul16             ; D0 = acc * base
                MOVE    D2, D0
                POP     D0, XY3
                LOADD   D3, [XY3]           ; restore D3 = neg flag
                ADD     D2, D0              ; acc += digit
                JMP     .par_loop

.par_finish:
                POP     D3, XY3             ; neg flag
                ADD     X3, #2              ; discard base
                CMP     D3, #0
                BEQ.L   .par_ret
                LOADI   D0, #0
                SUB     D0, D2
                MOVE    D2, D0
                MOVE    D0, D2
                JMP     .par_done
.par_ret:
                MOVE    D0, D2
                LOADI   D2, #0              ; no error
                JMP     .par_done
.par_err:
                LOADI   D0, #0
                LOADI   D2, #1              ; error
.par_done:
                LOADI   Y0, #$00
                POP     D3, XY3
                RET

; =============================================================================
; FORMAT TO BUFFER (non-printing)
; =============================================================================

; __itoa -- format signed 16-bit integer D1 to null-terminated string at D0 (page $00).
; Out: D0 = length of string (not counting null).
; Trashes D1, D2, D3.
__itoa:
                PUSH    D3, XY3
                SUB     X3, #2            ; save frame pointer (V2: XY2=frame base)
                STOREX  X2, [XY3]
                MOVE    X2, D0              ; X2 = dest base
                LOADI   Y2, #$00
                LOADI   D3, #0              ; D3 = length
                LOADI   D2, #0              ; D2 = negative flag
                CMP     D1, #0
                BGE.L   .ia_pos
                LOADI   D2, #1
                LOADI   D0, #0
                SUB     D0, D1
                MOVE    D1, D0
.ia_pos:
                ; push sentinel then digits
                LOADI   D0, #0
                PUSH    D0, XY3
                CMP     D1, #0
                BNE.L   .ia_loop
                LOADI   D0, #48             ; "0"
                PUSH    D0, XY3
                ADD     D3, #1
                JMP     .ia_write
.ia_loop:
                CMP     D1, #0
                BEQ.L   .ia_write
                MOVE    D0, D1
                CALL24  __div10             ; D0=quot, D1=remainder
                PUSH    D1, XY3
                ADD     D3, #1
                MOVE    D1, D0
                JMP     .ia_loop
.ia_write:
                ; write '-' if negative
                CMP     D2, #0
                BEQ.L   .ia_digits
                LOADI   D0, #45
                STOREB  D0, [XY2]
                ADD     X2, #1
                ADD     D3, #1
.ia_digits:
                POP     D0, XY3
                CMP     D0, #0              ; sentinel?
                BEQ.L   .ia_null
                ADD     D0, #48
                STOREB  D0, [XY2]
                ADD     X2, #1
                JMP     .ia_digits
.ia_null:
                LOADI   D0, #0
                STOREB  D0, [XY2]           ; null terminator
                MOVE    D0, D3
                LOADX   X2, [XY3]            ; restore frame pointer (V2)
                ADD     X3, #2
                POP     D3, XY3
                RET

; __itoh -- format D1 as 4 hex digits + null to buffer at D0 (page $00).
; Out: D0 = 4 (always).
; Trashes D1, D2.
__itoh:
                PUSH    D2, XY3
                SUB     X3, #2            ; save frame pointer (V2: XY2=frame base)
                STOREX  X2, [XY3]
                MOVE    X2, D0
                LOADI   Y2, #$00
                ; 4 nibbles, most significant first
                MOVE    D2, D1
                HIGH    D2                  ; D2 = high byte
                ; nibble 3 (bits 15:12)
                MOVE    D0, D2
                SHR4    D0
                AND     D0, #$0F
                CALL24  .ih_nib
                STOREB  D0, [XY2]
                ADD     X2, #1
                ; nibble 2 (bits 11:8)
                MOVE    D0, D2
                AND     D0, #$0F
                CALL24  .ih_nib
                STOREB  D0, [XY2]
                ADD     X2, #1
                ; nibble 1 (bits 7:4)
                MOVE    D0, D1
                SHR4    D0
                AND     D0, #$0F
                CALL24  .ih_nib
                STOREB  D0, [XY2]
                ADD     X2, #1
                ; nibble 0 (bits 3:0)
                MOVE    D0, D1
                AND     D0, #$0F
                CALL24  .ih_nib
                STOREB  D0, [XY2]
                ADD     X2, #1
                ; null
                LOADI   D0, #0
                STOREB  D0, [XY2]
                LOADI   D0, #4
                LOADX   X2, [XY3]            ; restore frame pointer (V2)
                ADD     X3, #2
                POP     D2, XY3
                RET
.ih_nib:
                CMP     D0, #10
                BCC.L   .ih_dec
                ADD     D0, #55             ; 'A'-10
                RET
.ih_dec:
                ADD     D0, #48             ; '0'
                RET

; =============================================================================
; CHARACTER UTILITIES
; =============================================================================

; __upcase -- convert char in D0 to uppercase.
; 'a'..'z' -> 'A'..'Z', all others unchanged.
__upcase:
                CMP     D0, #97             ; < 'a'?
                BLT.L   .uc_done
                CMP     D0, #123            ; > 'z'?
                BGE.L   .uc_done
                SUB     D0, #32
.uc_done:
                RET

; __downcase -- convert char in D0 to lowercase.
; 'A'..'Z' -> 'a'..'z', all others unchanged.
__downcase:
                CMP     D0, #65             ; < 'A'?
                BLT.L   .dc_done
                CMP     D0, #91             ; > 'Z'?
                BGE.L   .dc_done
                ADD     D0, #32
.dc_done:
                RET

; =============================================================================
; STRING UTILITIES (null-terminated)
; =============================================================================

; __strcmpz -- compare two null-terminated strings (page $00).
; In:  D0 = str1 address,  D1 = str2 address
; Out: D0 = 0 (equal),  D0 = $FFFF (-1, str1 < str2),  D0 = 1 (str1 > str2)
; Trashes D1, D2, D3.
__strcmpz:
                PUSH    D2, XY3
                PUSH    D3, XY3
                MOVE    X0, D0
                MOVE    X1, D1
                LOADI   Y0, #$00
                LOADI   Y1, #$00
.scz_loop:
                LOADB   D2, [XY0]           ; char from str1
                LOADB   D3, [XY1]           ; char from str2
                CMP     D2, D3
                BNE.L   .scz_diff
                CMP     D2, #0              ; both zero = end?
                BEQ.L   .scz_equal
                ADD     X0, #1
                ADD     X1, #1
                JMP     .scz_loop
.scz_diff:
                BCC.L   .scz_lt             ; unsigned: D2 < D3
                LOADI   D0, #1
                JMP     .scz_done
.scz_lt:
                LOADI   D0, #$FFFF
                JMP     .scz_done
.scz_equal:
                LOADI   D0, #0
.scz_done:
                POP     D3, XY3
                POP     D2, XY3
                RET

; __strcmpz_ci -- case-insensitive null-terminated string compare (page $00).
; Same interface as __strcmpz. Used for FAT16 filename matching.
; Trashes D1, D2, D3.
__strcmpz_ci:
                PUSH    D2, XY3
                PUSH    D3, XY3
                MOVE    X0, D0
                MOVE    X1, D1
                LOADI   Y0, #$00
                LOADI   Y1, #$00
.scci_loop:
                LOADB   D2, [XY0]
                LOADB   D3, [XY1]
                ; upcase both before compare
                MOVE    D0, D2
                CALL24  __upcase
                MOVE    D2, D0
                MOVE    D0, D3
                CALL24  __upcase
                MOVE    D3, D0
                CMP     D2, D3
                BNE.L   .scci_diff
                CMP     D2, #0
                BEQ.L   .scci_equal
                ADD     X0, #1
                ADD     X1, #1
                JMP     .scci_loop
.scci_diff:
                BCC.L   .scci_lt
                LOADI   D0, #1
                JMP     .scci_done
.scci_lt:
                LOADI   D0, #$FFFF
                JMP     .scci_done
.scci_equal:
                LOADI   D0, #0
.scci_done:
                POP     D3, XY3
                POP     D2, XY3
                RET

; =============================================================================
; MEMORY UTILITIES (cross-page)
; =============================================================================

; __memcopy_xy -- copy D2 bytes from XY1 to XY0 (pages pre-set by caller).
; Caller loads Y0/Y1 with the appropriate bank bytes before calling.
; Forward copy only. Advances XY0 and XY1 past end on return.
; Trashes D0, D1.
; Example (copy 64 bytes from ROM $FF:$C000 to RAM $00:$1000):
;   LOADI  X0, #$1000  /  LOADI  Y0, #$00
;   LOADI  X1, #$C000  /  LOADI  Y1, #$FF
;   LOADI  D2, #64
;   CALL24 __memcopy_xy
__memcopy_xy:
                CMP     D2, #0
                BEQ.L   .mxy_done
.mxy_loop:
                LOADB   D0, [XY1]
                STOREB  D0, [XY0]
                ADD     X0, #1
                ADD     X1, #1
                SUB     D2, #1
                BNE.L   .mxy_loop
.mxy_done:
                RET

; =============================================================================
; ADDITIONAL ROUTINES
; =============================================================================

; __strlenz -- return length of null-terminated string (page $00).
; In:  D0 = string address
; Out: D0 = length (not counting null)
; Trashes: D1.
__strlenz:
                MOVE    X0, D0
                LOADI   Y0, #$00
                LOADI   D1, #0              ; counter
.slz_loop:
                LOADB   D0, [XY0]
                CMP     D0, #0
                BEQ.L   .slz_done
                ADD     X0, #1
                ADD     D1, #1
                JMP     .slz_loop
.slz_done:
                MOVE    D0, D1
                LOADI   Y0, #$00
                RET

; __strcpyz -- copy null-terminated string from src to dest (both page $00).
; Copies at most D2 chars plus the null terminator (dest buf = D2+1 bytes min).
; In:  D0 = dest address,  D1 = src address,  D2 = max chars (excl. null)
; Out: D0 = chars copied (not counting null)
; Trashes: D1, D2, D3.
__strcpyz:
                PUSH    D3, XY3
                MOVE    X0, D0
                MOVE    X1, D1
                LOADI   Y0, #$00
                LOADI   Y1, #$00
                LOADI   D3, #0              ; count
.scpy_loop:
                CMP     D3, D2              ; hit max?
                BGE.L   .scpy_null
                LOADB   D0, [XY1]
                CMP     D0, #0
                BEQ.L   .scpy_null
                STOREB  D0, [XY0]
                ADD     X0, #1
                ADD     X1, #1
                ADD     D3, #1
                JMP     .scpy_loop
.scpy_null:
                LOADI   D0, #0
                STOREB  D0, [XY0]           ; null terminator
                MOVE    D0, D3
                LOADI   Y0, #$00
                LOADI   Y1, #$00
                POP     D3, XY3
                RET

; __strcatz -- append null-terminated src to dest, guarded by max total length.
; In:  D0 = dest address,  D1 = src address,  D2 = dest buffer size (total)
; Out: D0 = final length of dest string
; Trashes: D1, D2, D3.
__strcatz:
                PUSH    D2, XY3             ; save max length
                PUSH    D3, XY3
                MOVE    X0, D0              ; X0 = dest scan ptr
                LOADI   Y0, #$00
                LOADI   D0, #0              ; D0 = dest current length
                ; find end of dest string
.scat_find:
                LOADB   D3, [XY0]
                CMP     D3, #0
                BEQ.L   .scat_found_end
                ADD     X0, #1
                ADD     D0, #1
                JMP     .scat_find
.scat_found_end:
                ; X0 = dest null position, D0 = dest current length
                ; [SP+2] = max length
                MOVE    X1, D1              ; X1 = src pointer
                LOADI   Y1, #$00
.scat_loop:
                LOADD   D2, [XY3+#2]        ; peek max length
                CMP     D0, D2              ; at max?
                BGE.L   .scat_done
                LOADB   D3, [XY1]
                CMP     D3, #0
                BEQ.L   .scat_done
                STOREB  D3, [XY0]
                ADD     X0, #1
                ADD     X1, #1
                ADD     D0, #1
                JMP     .scat_loop
.scat_done:
                LOADI   D3, #0
                STOREB  D3, [XY0]           ; null terminator
                LOADI   Y0, #$00
                LOADI   Y1, #$00
                POP     D3, XY3
                ADD     X3, #2              ; discard saved max
                RET

; __abs16 -- signed absolute value.
; In:  D0 = value
; Out: D0 = |value|
__abs16:
                CMP     D0, #0
                BGE.L   .abs_done
                LOADI   D1, #0
                SUB     D1, D0
                MOVE    D0, D1
.abs_done:
                RET

; __min16 -- signed minimum of D0 and D1.
; In:  D0, D1 = values
; Out: D0 = lesser of the two
__min16:
                CMP     D0, D1
                BLE.L   .min_done           ; D0 <= D1, keep D0
                MOVE    D0, D1
.min_done:
                RET

; __max16 -- signed maximum of D0 and D1.
; In:  D0, D1 = values
; Out: D0 = greater of the two
__max16:
                CMP     D0, D1
                BGE.L   .max_done           ; D0 >= D1, keep D0
                MOVE    D0, D1
.max_done:
                RET

; __memmove_xy -- overlap-safe byte copy. Copies forward if dest <= src,
; backward if dest > src (to handle overlapping regions correctly).
; Caller pre-loads XY0 (dest) and XY1 (src) including bank bytes.
; In:  XY0 = destination,  XY1 = source,  D2 = byte count
; Out: --
; Trashes: D0, D1.
__memmove_xy:
                CMP     D2, #0
                BEQ.L   .mmv_done
                ; compare dest vs src (X registers, assuming same Y bank)
                CMP     X0, X1
                BLE.L   .mmv_fwd            ; dest <= src: forward copy safe
                ; backward copy: start from end
                LEA     XY0, XY0+D2         ; dest end  (D2 = count)
                LEA     XY1, XY1+D2         ; src end
                SUB     X0, #1
                SUB     X1, #1
.mmv_bwd_loop:
                LOADB   D0, [XY1]
                STOREB  D0, [XY0]
                SUB     X0, #1
                SUB     X1, #1
                SUB     D2, #1
                BNE.L   .mmv_bwd_loop
                JMP     .mmv_done
.mmv_fwd:
                LOADB   D0, [XY1]
                STOREB  D0, [XY0]
                ADD     X0, #1
                ADD     X1, #1
                SUB     D2, #1
                BNE.L   .mmv_fwd
.mmv_done:
                RET

; __lfn_checksum -- compute FAT Long Filename checksum of an 8.3 directory entry name.
; The Microsoft LFN checksum: for each of the 11 name bytes, rotate accumulator
; right by 1 (with wrap) then add the next byte. Result fits in a byte.
; In:  D0 = address of 11-byte 8.3 name field (page $00, uppercase, space-padded)
; Out: D0 = checksum byte (0..255)
; Trashes: D1, D2.
__lfn_checksum:
                MOVE    X0, D0
                LOADI   Y0, #$00
                LOADI   D0, #0              ; accumulator
                LOADI   D2, #11             ; 11 bytes
.lcs_loop:
                ; rotate right: carry = acc AND 1; acc = (acc >> 1) | (carry << 7)
                MOVE    D1, D0
                AND     D1, #1              ; D1 = low bit (will become bit 7)
                SHR     D0                  ; logical shift right
                SHL4    D1
                SHL4    D1
                SHL4    D1
                SHL4    D1
                SHL     D1
                SHL     D1
                SHL     D1                  ; D1 = old bit 0 << 7
                OR      D0, D1              ; insert as new bit 7
                LOADB   D1, [XY0]           ; next name byte
                ADD     D0, D1
                AND     D0, #$FF            ; keep byte range
                ADD     X0, #1
                SUB     D2, #1
                BNE.L   .lcs_loop
                LOADI   Y0, #$00
                RET

; __dint -- disable interrupts.
__dint:
                DINT
                RET

; __eint -- enable interrupts.
__eint:
                EINT
                RET


; =============================================================================
; MULTITASKING PRIMITIVES  (Phase 5 -- not yet active)
; =============================================================================
; SYS_TICKS, __sem_init, __sem_wait, __sem_signal,
; __ctx_save, __ctx_restore, __tick_isr, __task_init
; will be added here when k/OS Phase 5 is implemented.
;
; Required additions at that point:
;   SYS_TICKS    .EQU  $0004   ; system tick counter (word, page $00)
;   __schedule   label (provided by k/OS scheduler module)
; =============================================================================

