;===============================================================================
; K16 System Definitions
; Included by compiler-generated code
;===============================================================================
TERMINAL        .EQU    $D00000         ; Memory-mapped terminal output (byte)
NULL            .EQU    0               ; String terminator
CR              .EQU    13              ; Carriage return
LF              .EQU    10              ; Line feed
MAX_LINE        .EQU    80              ; Maximum line width
BUF_SIZE        .EQU    MAX_LINE + 2    ; Buffer: line + CR/LF

