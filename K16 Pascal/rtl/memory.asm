;==============================================================================
; memory.asm  -  paged memory access              K16 Pascal, Part 24 / 25
;==============================================================================
; Bodies for memory.pas.  k/OS .COM target only: a .COM is loaded into RAM, so
; the cursor words below sit in the code stream and are writable.  On bare
; metal the image is ROM at $FF0000 and these stores would fail silently --
; hence no bare-metal sibling.  (kOS Gotchas: ROM data in Digital.)
;
; V2 ABI: the last three arguments arrive in D0/D1/D2, in order.  For the
; two-argument entries that is D0 = ofs, D1 = page; for the three-argument
; ones D0 = ofs, D1 = page, D2 = value.  Result returns in D0.
;
; MOVE Yn, Dm is documented 8-bit truncation (RM Appendix B.9), so the page
; argument needs no masking -- the hardware discards the high byte on load.
;
; Nothing here is a leaf-with-frame: no PUSHes, no X3 movement, plain RET.
;==============================================================================

; ---- __mgetb : D0 = ofs, D1 = page  ->  D0 = byte (zero-extended) ----
__mgetb:
                MOVE    X0, D0
                MOVE    Y0, D1
                LOADB   D0, [XY0]
                RET

; ---- __mgetw : D0 = ofs, D1 = page  ->  D0 = word, LITTLE-endian ----
; ofs must be EVEN.  An odd address here is DATA FAULT odd-addr word access,
; which is the correct outcome -- it is a bug at the call site, not something
; to paper over.  If the data is big-endian and unaligned, the caller wanted
; __mgetwbe.
__mgetw:
                MOVE    X0, D0
                MOVE    Y0, D1
                LOADD   D0, [XY0]
                RET

; ---- __mgetwbe : D0 = ofs, D1 = page  ->  D0 = word, BIG-endian ----
; Two byte reads, so any alignment is legal.  This is the Z-machine's word.
__mgetwbe:
                MOVE    X0, D0
                MOVE    Y0, D1
                LOADB   D0, [XY0]+          ; D0 = high byte, X0 -> low byte
                LOADB   D1, [XY0]           ; D1 = low byte
                SHL     D0, #8
                OR      D0, D1
                RET

; ---- __mputb : D0 = ofs, D1 = page, D2 = value (low byte) ----
__mputb:
                MOVE    X0, D0
                MOVE    Y0, D1
                STOREB  D2, [XY0]
                RET

; ---- __mputw : D0 = ofs, D1 = page, D2 = value.  ofs must be EVEN. ----
__mputw:
                MOVE    X0, D0
                MOVE    Y0, D1
                STORED  D2, [XY0]
                RET

;------------------------------------------------------------------------------
; Sequential cursor
;------------------------------------------------------------------------------
; Held as two words in this module's own storage rather than in the RTLVARS
; region: RTLVARS is emitted by the compiler (EmitTaskPageRegions) and an
; $L-included file cannot add fields to it.
;
; Advanced only with [XY0]+, never with ADD X0,#n -- post-increment carries
; into the page byte and ADD does not (k/OS Part 60 s4.6, PAGETEST checks 8
; and 10).  That is the whole reason __mnextwbe reads two single bytes rather
; than adding 2.

                .ALIGN  2
__mem_cx:       .WORD   0                   ; cursor offset
__mem_cy:       .WORD   0                   ; cursor page (low byte used)

; ---- __mseek : D0 = ofs, D1 = page ----
__mseek:
                LOADI   X0, #__mem_cx
                MOVE    Y0, Y3
                STORED  D0, [XY0]+          ; offset, X0 -> __mem_cy
                STORED  D1, [XY0]           ; page
                RET

; ---- __mnextb : -> D0 = byte at cursor; cursor advances one byte ----
__mnextb:
                PUSH    D1, XY3
                LOADI   X1, #__mem_cx
                MOVE    Y1, Y3
                LOADD   D0, [XY1]           ; D0 = cursor offset
                MOVE    X0, D0
                LOADD   D0, [XY1+#2]        ; D0 = cursor page
                MOVE    Y0, D0
                LOADB   D0, [XY0]+          ; read, then advance (carries page)
                MOVE    D1, X0
                STORED  D1, [XY1]           ; write offset back
                MOVE    D1, Y0
                STORED  D1, [XY1+#2]        ; write page back -- may have carried
                POP     D1, XY3
                RET

; ---- __mnextwbe : -> D0 = big-endian word at cursor; cursor advances two ----
; Deliberately two calls to the byte path rather than an inlined pair: the
; cursor write-back is the subtle part (the page byte can carry between the
; two reads, at a page boundary) and it should exist once.
__mnextwbe:
                PUSH    D1, XY3
                CALL16  __mnextb            ; D0 = high byte
                MOVE    D1, D0
                SHL     D1, #8
                PUSH    D1, XY3
                CALL16  __mnextb            ; D0 = low byte
                POP     D1, XY3
                OR      D0, D1
                POP     D1, XY3
                RET


; ---- __mtellofs  : -> D0 = cursor offset ----
; ---- __mtellpage : -> D0 = cursor page   ----
; Two entries rather than one returning a pair: the V2 ABI has a single
; result register, and __termcols/__termrows is the established shape for
; a two-axis query.
;
; These exist so that a reader can LEAVE the cursor and come back -- a
; Z-string abbreviation, a routine call.  The alternative, a caller-side
; shadow position advanced in parallel with the cursor, would be a SECOND
; carry mechanism for one position, which is exactly the hazard sys_read's
; missing carry turned out to be (Part 24 s5.3).  Restore with __mseek.
;
; Leaf, no frame, no flag dependency: LOADD is flag-transparent and nothing
; here branches.
__mtellofs:
                LOADI   X0, #__mem_cx
                MOVE    Y0, Y3
                LOADD   D0, [XY0]
                RET

__mtellpage:
                LOADI   X0, #__mem_cx
                MOVE    Y0, Y3
                LOADD   D0, [XY0+#2]
                RET


;------------------------------------------------------------------------------
; __mskip : D0 = n  --  advance the cursor n bytes, carrying into the page
;------------------------------------------------------------------------------
; ADD sets carry on unsigned overflow, so the page bump is a branch on C and
; not a comparison.  This is the ONE place a bulk advance is allowed: the
; carry is handled explicitly rather than relying on ADD X0,#n, which wraps
; inside the page (k/OS Part 60 s4.6).
__mskip:
                PUSH    D1, XY3
                PUSH    D2, XY3
                LOADI   X0, #__mem_cx
                MOVE    Y0, Y3
                LOADD   D1, [XY0]           ; D1 = cursor offset
                ADD     D1, D0
                STORED  D1, [XY0]
                BCC.L   .msk_done           ; C=0: no wrap, page unchanged
                LOADD   D2, [XY0+#2]        ; C=1: offset wrapped past $FFFF
                ADD     D2, #1
                STORED  D2, [XY0+#2]
.msk_done:
                POP     D2, XY3
                POP     D1, XY3
                RET

;------------------------------------------------------------------------------
; __mread : D0 = fd, D1 = count  ->  D0 = bytes read, or $FFFF on hard error
;------------------------------------------------------------------------------
; Reads into the CURSOR and advances it, carrying across pages.  This is how a
; story image larger than one page gets loaded: seek to the run's second page
; at offset 0, then read the whole file in one call.
;
; WHY THIS CHUNKS, and it is not an optimisation -----------------------------
;
; sys_read honours the page byte in Y0 -- it stashes it in FD_USERBUF_Y and
; _FdCopyToUser loads it back into Y1 -- so a paged destination needs no
; staging buffer.  But between sectors sys_read advances only the OFFSET:
;
;       LOADZ D1, [#FD_USERBUF_X] / ADD D1, D0 / STOREZ D1, [#FD_USERBUF_X]
;
; with no carry into FD_USERBUF_Y.  So a single TRAP whose buffer would run
; past $FFFF wraps to offset 0 in the SAME page and silently overwrites the
; start of it.  (_FdCopyToUser's own blit uses [XY1]+, which does carry, so
; the straddling sector lands correctly and only the following one goes to the
; wrong place -- corruption, not a fault.)
;
; So every TRAP issued here is clamped to what remains in the current page,
; and the cursor is advanced with carry between calls.  The kernel never sees
; a boundary.
;
; Not re-entrant: the three words below are module state, like the cursor.
; Nothing in a Pascal program can re-enter it -- there are no interrupts in
; user code and no callbacks -- but it is worth saying rather than assuming.
;
; A short return means EOF.  A hard error (bad fd, I/O) returns $FFFF, matching
; __fread's -1 convention; a genuine 65535-byte read is indistinguishable from
; it, which is a reason to read in chunks well under that.

                .ALIGN  2
__mr_fd:        .WORD   0
__mr_left:      .WORD   0
__mr_total:     .WORD   0

__mread:
                PUSH    D1, XY3
                PUSH    D2, XY3
                PUSH    D3, XY3

                LOADI   X0, #__mr_fd
                MOVE    Y0, Y3
                STORED  D0, [XY0]           ; fd
                MOVE    D0, D1
                STORED  D0, [XY0+#2]        ; left = count
                LOADI   D0, #0
                STORED  D0, [XY0+#4]        ; total = 0

.mr_loop:
                LOADI   X0, #__mr_left
                MOVE    Y0, Y3
                LOADD   D1, [XY0]           ; D1 = bytes still wanted
                CMP     D1, #0
                BEQ.L   .mr_done

                ; room = bytes left in the current page = (0 - ofs) mod 65536.
                ; ofs = 0 computes 0 -- the 16-bit zero trap -- and means the
                ; whole page is free, so clamp to $FFFF and let the next
                ; iteration collect the last byte.
                LOADI   X0, #__mem_cx
                MOVE    Y0, Y3
                LOADD   D2, [XY0]           ; D2 = cursor offset
                LOADI   D0, #0
                SUB     D0, D2              ; D0 = room
                CMP     D0, #0
                BNE.L   .mr_room_ok
                LOADI   D0, #$FFFF
.mr_room_ok:
                ; chunk = min(left, room).  UNSIGNED: after CMP D1,D0 the
                ; carry is clear only on borrow, i.e. left < room.
                MOVE    D3, D0              ; D3 = room
                CMP     D1, D0
                BLO.L   .mr_have           ; left < room -> chunk = left
                MOVE    D1, D3              ; else chunk = room
.mr_have:
                ; D1 = chunk.  XY0 = cursor, D0 = fd.
                LOADI   X0, #__mem_cx
                MOVE    Y0, Y3
                LOADD   D2, [XY0]           ; offset
                LOADD   D3, [XY0+#2]        ; page
                MOVE    X0, D2
                MOVE    Y0, D3
                PUSH    D1, XY3             ; save chunk across the trap
                LOADI   X1, #__mr_fd
                MOVE    Y1, Y3
                LOADD   D0, [XY1]           ; D0 = fd
                TRAP    #TRAP_READ          ; D0 = bytes read, C=1 error
                BCS.L   .mr_err
                ADD     X3, #2              ; discard saved chunk (ADD clobbers C)

                CMP     D0, #0
                BEQ.L   .mr_done            ; 0 = EOF, stop

                ; total += n ; left -= n ; cursor += n (with carry)
                MOVE    D2, D0              ; D2 = n
                LOADI   X0, #__mr_left
                MOVE    Y0, Y3
                LOADD   D1, [XY0]
                SUB     D1, D2
                STORED  D1, [XY0]
                LOADD   D1, [XY0+#2]
                ADD     D1, D2
                STORED  D1, [XY0+#2]        ; total

                MOVE    D0, D2
                CALL16  __mskip             ; advance cursor, carrying the page
                BRA.L   .mr_loop

.mr_err:
                ADD     X3, #2              ; discard saved chunk
                LOADI   D0, #$FFFF
                POP     D3, XY3
                POP     D2, XY3
                POP     D1, XY3
                RET

.mr_done:
                LOADI   X0, #__mr_total
                MOVE    Y0, Y3
                LOADD   D0, [XY0]
                POP     D3, XY3
                POP     D2, XY3
                POP     D1, XY3
                RET

;------------------------------------------------------------------------------
; Self-discovery
;------------------------------------------------------------------------------
; Y3 is TCB_SAVED_Y: the value the scheduler restores AND the value _PageInUse
; range-tests to establish ownership.  It is therefore the DEFINITIONAL run
; base, not merely where the code happens to sit.
;
; PCH is also readable and today holds the same value.  Only one of the two is
; exposed on purpose: two names for one value cannot be validated, so every
; call site would become a coin flip with nothing to catch a wrong choice.

;------------------------------------------------------------------------------
; __mcopyto : D0 = dst ofs, D1 = dst page, D2 = n
;             copy n bytes from the CURSOR to dst; the cursor advances by n
;------------------------------------------------------------------------------
; No page-boundary chunking, and unlike __mread that is not an oversight.
; __mread must clamp because sys_read advances only FD_USERBUF_X between
; sectors and never carries into FD_USERBUF_Y.  Here both pointers are [XYn]+,
; which carries X into Y in hardware -- the same property _FdCopyToUser's own
; blit relies on -- so source and destination cross pages by themselves.
;
; STREAM opcodes are flag-transparent, so the ADD below is the only thing the
; BNE can be reading.  No CMP in the loop.
;
; The counter runs UP from -n to zero rather than down from n, because ADD
; IMM5 is 3 cycles and SUB IMM5 is 4.  That is one cycle per byte -- nothing
; on EMU, but this loop runs 11,282 times for Zork I's dynamic memory and
; Digital is around 2-3 kHz.  The negate costs two instructions, once.
;
; The zero test MUST stay ahead of the negate's use, not after it: -0 is 0, so
; an n of zero would enter the loop, ADD to 1, and run 65,535 times.
;
; Forward copy: overlapping regions are safe only when dst is below src.
; Nothing in the RTL overlaps; said because the next caller might not know.
;
; Clobbers the cursor by design -- it is the source, and it is left where the
; copy finished so consecutive copies chain.  Callers needing it elsewhere
; re-seek, which is what they would have done anyway.
;
; Four instructions per byte.  The Pascal equivalent -- MemPutByte(a, page,
; MemNextByte) in a while loop -- is nearer twenty-five, two of them calls.
__mcopyto:
                PUSH    D1, XY3
                PUSH    D2, XY3
                PUSH    D3, XY3

                MOVE    X1, D0              ; XY1 = destination
                MOVE    Y1, D1              ; MOVE Yn,Dm truncates to 8 (RM B.9)
                MOVE    D3, D2              ; D3 = bytes remaining

                LOADI   X0, #__mem_cx
                MOVE    Y0, Y3
                LOADD   D1, [XY0]           ; cursor offset
                LOADD   D2, [XY0+#2]        ; cursor page
                MOVE    X0, D1
                MOVE    Y0, D2              ; XY0 = source

                CMP     D3, #0
                BEQ.L   .mcp_done           ; n = 0 is legal and copies nothing
                NOT     D3
                ADD     D3, #1              ; D3 = -n, counting up to zero

.mcp_loop:      LOADB   D0, [XY0]+
                STOREB  D0, [XY1]+
                ADD     D3, #1
                BNE.L   .mcp_loop

.mcp_done:      LOADI   X1, #__mem_cx       ; write the advanced cursor back
                MOVE    Y1, Y3
                MOVE    D0, X0
                STORED  D0, [XY1]
                MOVE    D0, Y0
                STORED  D0, [XY1+#2]

                POP     D3, XY3
                POP     D2, XY3
                POP     D1, XY3
                RET

;------------------------------------------------------------------------------
; __msum : D0 = n  ->  D0 = 16-bit sum of n bytes from the CURSOR
;------------------------------------------------------------------------------
; The cursor advances by n, so summing a file larger than 65535 bytes is
; repeated calls with no re-seek between them.  The total is mod 65536 and
; partial sums of it add correctly, which is why the Word-sized count is not a
; limitation -- it just makes the caller do the chunking, where the progress
; indicator wants to be anyway.
;
; Carry out of ADD is discarded deliberately: a Z-machine checksum IS the low
; 16 bits of the byte sum (Standard 1.1 s11.1), not a truncation of something
; wider.
;
; Counter runs up from -n to zero for the same reason as __mcopyto: ADD IMM5
; is 3 cycles, SUB IMM5 is 4, and this loop runs once per byte of an 87 KB
; story file.
;
; Byte-wise and not LOADD, unlike a copy could be: the checksum sums BYTES,
; and a word load gives lo + 256*hi, so the halves would have to be split and
; added separately -- more instructions than just reading the two bytes.
__msum:
                PUSH    D1, XY3
                PUSH    D2, XY3
                PUSH    D3, XY3

                MOVE    D3, D0              ; D3 = bytes remaining

                LOADI   X0, #__mem_cx
                MOVE    Y0, Y3
                LOADD   D1, [XY0]
                LOADD   D2, [XY0+#2]
                MOVE    X0, D1
                MOVE    Y0, D2              ; XY0 = source

                LOADI   D1, #0              ; D1 = running sum
                CMP     D3, #0
                BEQ.L   .msm_done
                NOT     D3
                ADD     D3, #1              ; D3 = -n, counting up to zero

.msm_loop:      LOADB   D0, [XY0]+
                ADD     D1, D0
                ADD     D3, #1
                BNE.L   .msm_loop

.msm_done:      LOADI   X1, #__mem_cx       ; write the advanced cursor back
                MOVE    Y1, Y3
                MOVE    D0, X0
                STORED  D0, [XY1]
                MOVE    D0, Y0
                STORED  D0, [XY1+#2]

                MOVE    D0, D1              ; result

                POP     D3, XY3
                POP     D2, XY3
                POP     D1, XY3
                RET

; ---- __mypage : -> D0 = this task's base page ----
__mypage:
                MOVE    D0, Y3
                RET

; ---- __mypagecount : -> D0 = pages in this task's run ----
; Read from the task's own .COM header rather than a compile-time constant:
; the allocation contract is "exactly N or fail", so the header cannot
; disagree with what the loader did.  LOADP and not LOADPB -- the field is a
; full word (k/OS Part 60).
__mypagecount:
                LOADP   D0, Y3, [#COM_HDR_PAGES]
                RET
