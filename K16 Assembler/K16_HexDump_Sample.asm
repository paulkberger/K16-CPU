;===============================================================
; K16 HexDump - Sample Program
; 
; Demonstrates:
;   - Stack-based parameter passing (C calling convention)
;   - 24-bit address arithmetic
;   - Memory-mapped I/O
;   - Byte-level memory access
;   - Subroutine calls with callee cleanup
; 
; Version: 3.0 (January 2026)
; Updated for new memory map:
;   - Reset vector at $FF0000
;   - Stack/ZP at page $00
;   - Terminal I/O at $D00000
;===============================================================

;---------------------------------------------------------------
; Memory Map Constants
;---------------------------------------------------------------
                .EQU        TERMINAL, $D00000   ; Terminal output

;---------------------------------------------------------------
; Stack Setup
; Stack at page $00, initialized to $FFF0
; Y3 = $00 (page), X3 = $FFF0 (offset)
;---------------------------------------------------------------

;---------------------------------------------------------------
; Program Code - ROM at $FF0000 (reset vector)
;---------------------------------------------------------------
                .ORG        $FF0000

;---------------------------------------------------------------
; Entry point (reset vector)
;---------------------------------------------------------------
Start:
                ; Initialize stack pointer
                LOADI       X3, #$FFF0
                LOADI       Y3, #$00

                ; Call HexDump(start_low, start_high, end_low, end_high)
                ; Push right-to-left: param4 first, param1 last
                
                PUSH        #>DumpEnd, XY3      ; param4: end_high
                PUSH        #<DumpEnd, XY3      ; param3: end_low
                PUSH        #>DumpStart, XY3    ; param2: start_high
                PUSH        #<DumpStart, XY3    ; param1: start_low
                CALL        HexDump
                
                HALT        #$00

;---------------------------------------------------------------
; HexDump - Output hex dump of memory range
;---------------------------------------------------------------
; void HexDump(uint16 start_low, uint8 start_high, 
;              uint16 end_low, uint8 end_high)
;
; Output format (16 bytes per line, 16-byte aligned):
;   AAAAAA: XX XX XX XX XX XX XX XX  XX XX XX XX XX XX XX XX  ................
;
; Stack frame at entry:
;   [X3+0]  = return address high
;   [X3+2]  = return address low
;   [X3+4]  = param1: start_low
;   [X3+6]  = param2: start_high
;   [X3+8]  = param3: end_low
;   [X3+10] = param4: end_high
;
; Clobbers: D0, D1, X0-X1, Y0-Y1
; Preserves: D2, D3 (saved/restored)
;---------------------------------------------------------------
HexDump:
                ; Save callee-save registers
                PUSH        D2, XY3
                PUSH        D3, XY3

                ; Setup terminal pointer in XY1
                LOADI       X1, #<TERMINAL
                LOADI       Y1, #>TERMINAL

                ; Load start address into XY0 (current pointer)
                LOADX       X0, [XY3 + #8]      ; start_low
                LOADY       Y0, [XY3 + #10]     ; start_high
                
                ; Align X0 down to 16-byte boundary
                AND         X0, #$FFF0
                
                ; Load end address into D2/D3 (can't use XY2 easily)
                LOADD       D2, [XY3 + #12]     ; end_low
                LOADD       D3, [XY3 + #14]     ; end_high

.line_loop:
                ; Check if done (Y0:X0 >= D3:D2)
                CMP         Y0, D3
                BCC         .do_line            ; Y0 < D3, continue
                BNE         .exit               ; Y0 > D3, done
                CMP         X0, D2
                BCS         .exit               ; X0 >= D2, done

.do_line:
                ; Save current address for ASCII column
                PUSH        X0, XY3
                PUSH        Y0, XY3
                
                ; Print address "AAAAAA: "
                PUSH        Y0, XY3
                CALL        PrintHexByte
                PUSH        X0, XY3
                CALL        PrintHexWord
                
                LOADI       D0, #$3A            ; ':'
                STOREB      D0, [XY1]
                LOADI       D0, #$20            ; ' '
                STOREB      D0, [XY1]

                ; Use stack to track byte count (push initial 0)
                PUSH        #0, XY3             ; byte counter

.byte_loop:
                ; Check if at end address
                CMP         Y0, D3
                BCC         .print_byte         ; Y0 < D3, continue
                BNE         .finish_line        ; Y0 > D3, done with data
                CMP         X0, D2
                BCS         .finish_line        ; X0 >= D2, done with data

.print_byte:
                ; Get byte from memory
                LOADB       D0, [XY0]
                
                ; Print byte as hex
                PUSH        D0, XY3
                CALL        PrintHexByte
                
                ; Print space
                LOADI       D0, #$20
                STOREB      D0, [XY1]
                
                ; Check byte counter for middle separator (after byte 7)
                LOADD       D0, [XY3]           ; get counter from stack top
                CMP         D0, #7
                BNE         .no_mid_space
                LOADI       D1, #$20
                STOREB      D1, [XY1]
.no_mid_space:
                
                ; Increment current address (24-bit)
                ADD         X0, #1
                ADC         Y0, #0
                
                ; Increment byte counter on stack
                LOADD       D0, [XY3]
                ADD         D0, #1
                STORED      D0, [XY3]
                
                CMP         D0, #16             ; 16 bytes per line
                BCC         .byte_loop

.finish_line:
                ; Get bytes printed from stack (don't pop yet - need for ASCII)
                LOADD       D0, [XY3]           ; D0 = bytes printed
                
                ; Pad remaining positions with spaces if line incomplete
.pad_loop:
                CMP         D0, #16
                BCS         .print_ascii
                ; Print "   " (3 spaces for missing "XX ")
                LOADI       D1, #$20
                STOREB      D1, [XY1]
                STOREB      D1, [XY1]
                STOREB      D1, [XY1]
                ; Extra space at position 7 for middle separator
                CMP         D0, #7
                BNE         .no_pad_mid
                STOREB      D1, [XY1]
.no_pad_mid:
                ADD         D0, #1
                BRA         .pad_loop

.print_ascii:
                ; Print "  " separator between hex and ASCII
                LOADI       D0, #$20
                STOREB      D0, [XY1]
                STOREB      D0, [XY1]
                
                ; Get byte count, then restore line start address
                POP         D0, XY3             ; byte count -> D0
                POP         Y0, XY3             ; restore Y0
                POP         X0, XY3             ; restore X0
                
                ; D0 = number of ASCII characters to print
                LOADI       D1, #0              ; D1 = ASCII counter
                
.ascii_loop:
                CMP         D1, D0
                BCS         .print_newline
                
                ; Get byte from memory
                PUSH        D0, XY3             ; save byte count
                PUSH        D1, XY3             ; save counter
                LOADB       D0, [XY0]
                ADD         X0, #1
                ADC         Y0, #0
                
                ; Check if printable ($20-$7E)
                CMP         D0, #$20
                BCC         .not_printable      ; < $20, not printable
                CMP         D0, #$7F
                BCC         .print_char         ; < $7F, printable
                
.not_printable:
                LOADI       D0, #$2E            ; '.'
                
.print_char:
                STOREB      D0, [XY1]
                POP         D1, XY3             ; restore counter
                POP         D0, XY3             ; restore byte count
                ADD         D1, #1
                BRA         .ascii_loop

.print_newline:
                LOADI       D0, #$0A
                STOREB      D0, [XY1]
                BRA         .line_loop

.exit:
                POP         D3, XY3
                POP         D2, XY3
                RET         #4w                 ; cleanup 8 bytes (4 params)

;---------------------------------------------------------------
; PrintHexWord - Print 16-bit value as 4 hex digits
;---------------------------------------------------------------
; void PrintHexWord(uint16 value)
; Stack: [X3+4] = value
;---------------------------------------------------------------
PrintHexWord:
                LOADD       D0, [XY3 + #4]
                
                ; Use HIGH lookup to get high byte
                PUSH        D0, XY3             ; save original
                HIGH        D0                  ; D0 = high byte
                PUSH        D0, XY3
                CALL        PrintHexByte
                
                ; Get low byte
                POP         D0, XY3             ; restore original
                AND         D0, #$FF            ; mask to low byte
                PUSH        D0, XY3
                CALL        PrintHexByte
                
                RET         #1w                 ; cleanup 2 bytes

;---------------------------------------------------------------
; PrintHexByte - Print byte value as 2 hex digits
;---------------------------------------------------------------
; void PrintHexByte(uint8 value)
; Stack: [X3+4] = value (only low 8 bits used)
;---------------------------------------------------------------
PrintHexByte:
                LOADD       D0, [XY3 + #4]
                AND         D0, #$FF
                
                ; Use SHR4 lookup for high nibble
                PUSH        D0, XY3             ; save original
                SHR4        D0                  ; D0 = high nibble
                CALL        NibbleToAscii
                STOREB      D0, [XY1]
                
                ; Get low nibble
                POP         D0, XY3
                AND         D0, #$0F
                CALL        NibbleToAscii
                STOREB      D0, [XY1]
                
                RET         #1w                 ; cleanup 2 bytes

;---------------------------------------------------------------
; NibbleToAscii - Convert 0-15 in D0 to ASCII '0'-'F'
;---------------------------------------------------------------
; Input: D0 = nibble (0-15)
; Output: D0 = ASCII character ('0'-'9' or 'A'-'F')
;---------------------------------------------------------------
NibbleToAscii:
                CMP         D0, #10
                BCS         .is_letter
                ADD         D0, #$30            ; '0'-'9'
                RET
.is_letter:
                SUB         D0, #10
                ADD         D0, #$41            ; 'A'-'F'
                RET

;---------------------------------------------------------------
; Test data to dump
;---------------------------------------------------------------
DumpStart:
                .TEXT       "Hello, World!\n"
                .TEXT       "K16 HexDump v3.0"
                .WORD       $0000, $1234, $5678, $9ABC
                .WORD       $DEF0, $FFFF, $CAFE, $BABE
DumpEnd:

;===============================================================
; End of K16 HexDump Sample
;===============================================================
