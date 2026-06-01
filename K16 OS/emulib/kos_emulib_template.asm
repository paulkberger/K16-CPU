; ============================================================================
; kos_emulib_template.asm — k/OS EMULIB ROM template + init routine
; ============================================================================
; Date:    29 May 2026
; Status:  EMULIB v1.0 — initial introduction (Part 39).
; Revision: r1 - 29 May 2026 — Part 39 (kosh.com migration). New file.
;             Mirrors the kos_klib_template.asm mechanism but populates
;             the EMULIB region ($A200..$A2FF) with JMP24 entries for
;             the emulator-only host-disk shim functions.
;
;             _InitEmulib must be called from _InitKernel sometime
;             after _InitKLib. (Order isn't critical — neither table
;             depends on the other at init time.)
;
;             On real hardware (FPGA / discrete TTL builds), the
;             intent is that the kfs/kos_fs_host_mgr.asm module is
;             excluded from the build (or the host symbols are
;             stub-defined as JMP24 _BadEmulibCall). Both options
;             produce graceful diagnostic failure rather than silent
;             corruption when kosh tries to call a host function.
;
;   Provides the patchable RAM jump table mechanism for EMULIB:
;
;     _EmulibTemplate   ROM-resident block of 64 JMP24 instructions.
;                       Copied byte-for-byte to $00:$A200 at boot.
;
;     _InitEmulib       Boot-time copy from ROM template to RAM table.
;                       Wired into _InitKernel after _InitKLib.
;
;     _BadEmulibCall    Diagnostic + system halt for any unimplemented
;                       slot. Prints a message to terminal then HALT #$1C.
;
;     _EmulibVersion    EMULIB_VERSION (slot 63) implementation.
;                       Returns D0 = $0100 (v1.0), C=0.
;
;   Implementation symbols referenced (must be resolvable at link time):
;     _HostList, _HostMount, _HostUnmount, _HostCreate, _HostDelete,
;     _HostRename, _HostBayName, _HostFOpen, _HostFClose, _HostFRead
;         in kfs/kos_fs_host_mgr.asm
;
;   The ROM template is the source of truth for the table. To add a new
;   live entry: replace the corresponding `JMP24 _BadEmulibCall` line
;   below with `JMP24 <impl_symbol>` and add the impl. Slot positions
;   are fixed by ABI — never reorder.
; ============================================================================


; ============================================================================
; _InitEmulib — copy EMULIB template into RAM jump table
;   Input:    none
;   Output:   $00:$A200..$A2FF populated with 64 JMP24 instructions
;   Clobbers: D0, XY0, XY1
;   Preserves: D1, D2, D3, XY2, XY3
; ============================================================================
_InitEmulib:
                PUSH    D1, XY3
                PUSH    XY1, XY3

                ; Source: ROM template (24-bit pointer in XY1)
                LOADI   Y1, #>_EmulibTemplate
                LOADI   X1, #<_EmulibTemplate

                ; Destination: $00:$A200 (24-bit pointer in XY0)
                LOADI   Y0, #$00
                LOADI   X0, #EMULIB_BASE

                ; Word count = 256 bytes / 2 = 128 words
                ; (64 entries × 4 bytes each)
                LOADI   D1, #128
.copy:
                LOADD   D0, [XY1]
                STORED  D0, [XY0]
                INC     XY1, #1w            ; word step (+2)
                INC     XY0, #1w            ; word step (+2)
                DEC     D1, #1
                BNE     .copy

                POP     XY1, XY3
                POP     D1, XY3
                RET

; ============================================================================
; _BadEmulibCall — diagnostic + halt for any unimplemented EMULIB slot
;
;   Reached when user code calls a stub entry. Prints a one-line
;   diagnostic to the terminal then halts the system.
;
;   HALT code $1C = "bad emulib call" (KLIB uses $1B).
; ============================================================================
_BadEmulibCall:
                LOADI   Y0, #>_EmulibBadMsg
                LOADI   X0, #<_EmulibBadMsg
                CALL24  _RawPuts
                HALT    #$1C

_EmulibBadMsg:
                .TEXT   "*** EMULIB: bad call (unimplemented slot) ***\n\0"

; ============================================================================
; _EmulibVersion — slot 63 implementation
;   Output:   D0 = $0100 (v1.0)
;   Flags:    C = 0
;   Clobbers: nothing else
; ============================================================================
_EmulibVersion:
                LOADI   D0, #EMULIB_VERSION_VALUE
                RETCC

; ============================================================================
; _EmulibTemplate — ROM-resident template copied to $00:$A200 at boot
;
;   Each entry is one JMP24 to its implementation. JMP24 is 4 bytes
;   (instruction word + 24-bit target padded to 2 words). 64 entries
;   = 256 bytes of ROM, identical to the runtime RAM table.
;
;   ABI: slot positions are fixed. Never reorder. New live entries
;   replace `JMP24 _BadEmulibCall` with `JMP24 <impl>`. The
;   EMULIB_RESERVED_xx slots are intentionally unallocated — they
;   exist so the ABI has growth room without disturbing existing
;   offsets.
; ============================================================================
_EmulibTemplate:
                ; --- Host-disk operations (slots 00-09) ------------------
                JMP24   _HostList               ; 00 EMULIB_HOST_LIST       LIVE
                JMP24   _HostMount              ; 01 EMULIB_HOST_MOUNT      LIVE
                JMP24   _HostUnmount            ; 02 EMULIB_HOST_UNMOUNT    LIVE
                JMP24   _HostCreate             ; 03 EMULIB_HOST_CREATE     LIVE
                JMP24   _HostDelete             ; 04 EMULIB_HOST_DELETE     LIVE
                JMP24   _HostRename             ; 05 EMULIB_HOST_RENAME     LIVE
                JMP24   _HostBayName            ; 06 EMULIB_HOST_BAYNAME    LIVE
                JMP24   _HostFOpen              ; 07 EMULIB_HOST_FOPEN      LIVE
                JMP24   _HostFClose             ; 08 EMULIB_HOST_FCLOSE     LIVE
                JMP24   _HostFRead              ; 09 EMULIB_HOST_FREAD      LIVE

                ; --- Reserved for growth (slots 10-62) -------------------
                JMP24   _BadEmulibCall          ; 10 EMULIB_RESERVED_10
                JMP24   _BadEmulibCall          ; 11 EMULIB_RESERVED_11
                JMP24   _BadEmulibCall          ; 12 EMULIB_RESERVED_12
                JMP24   _BadEmulibCall          ; 13 EMULIB_RESERVED_13
                JMP24   _BadEmulibCall          ; 14 EMULIB_RESERVED_14
                JMP24   _BadEmulibCall          ; 15 EMULIB_RESERVED_15
                JMP24   _BadEmulibCall          ; 16 EMULIB_RESERVED_16
                JMP24   _BadEmulibCall          ; 17 EMULIB_RESERVED_17
                JMP24   _BadEmulibCall          ; 18 EMULIB_RESERVED_18
                JMP24   _BadEmulibCall          ; 19 EMULIB_RESERVED_19
                JMP24   _BadEmulibCall          ; 20 EMULIB_RESERVED_20
                JMP24   _BadEmulibCall          ; 21 EMULIB_RESERVED_21
                JMP24   _BadEmulibCall          ; 22 EMULIB_RESERVED_22
                JMP24   _BadEmulibCall          ; 23 EMULIB_RESERVED_23
                JMP24   _BadEmulibCall          ; 24 EMULIB_RESERVED_24
                JMP24   _BadEmulibCall          ; 25 EMULIB_RESERVED_25
                JMP24   _BadEmulibCall          ; 26 EMULIB_RESERVED_26
                JMP24   _BadEmulibCall          ; 27 EMULIB_RESERVED_27
                JMP24   _BadEmulibCall          ; 28 EMULIB_RESERVED_28
                JMP24   _BadEmulibCall          ; 29 EMULIB_RESERVED_29
                JMP24   _BadEmulibCall          ; 30 EMULIB_RESERVED_30
                JMP24   _BadEmulibCall          ; 31 EMULIB_RESERVED_31
                JMP24   _BadEmulibCall          ; 32 EMULIB_RESERVED_32
                JMP24   _BadEmulibCall          ; 33 EMULIB_RESERVED_33
                JMP24   _BadEmulibCall          ; 34 EMULIB_RESERVED_34
                JMP24   _BadEmulibCall          ; 35 EMULIB_RESERVED_35
                JMP24   _BadEmulibCall          ; 36 EMULIB_RESERVED_36
                JMP24   _BadEmulibCall          ; 37 EMULIB_RESERVED_37
                JMP24   _BadEmulibCall          ; 38 EMULIB_RESERVED_38
                JMP24   _BadEmulibCall          ; 39 EMULIB_RESERVED_39
                JMP24   _BadEmulibCall          ; 40 EMULIB_RESERVED_40
                JMP24   _BadEmulibCall          ; 41 EMULIB_RESERVED_41
                JMP24   _BadEmulibCall          ; 42 EMULIB_RESERVED_42
                JMP24   _BadEmulibCall          ; 43 EMULIB_RESERVED_43
                JMP24   _BadEmulibCall          ; 44 EMULIB_RESERVED_44
                JMP24   _BadEmulibCall          ; 45 EMULIB_RESERVED_45
                JMP24   _BadEmulibCall          ; 46 EMULIB_RESERVED_46
                JMP24   _BadEmulibCall          ; 47 EMULIB_RESERVED_47
                JMP24   _BadEmulibCall          ; 48 EMULIB_RESERVED_48
                JMP24   _BadEmulibCall          ; 49 EMULIB_RESERVED_49
                JMP24   _BadEmulibCall          ; 50 EMULIB_RESERVED_50
                JMP24   _BadEmulibCall          ; 51 EMULIB_RESERVED_51
                JMP24   _BadEmulibCall          ; 52 EMULIB_RESERVED_52
                JMP24   _BadEmulibCall          ; 53 EMULIB_RESERVED_53
                JMP24   _BadEmulibCall          ; 54 EMULIB_RESERVED_54
                JMP24   _BadEmulibCall          ; 55 EMULIB_RESERVED_55
                JMP24   _BadEmulibCall          ; 56 EMULIB_RESERVED_56
                JMP24   _BadEmulibCall          ; 57 EMULIB_RESERVED_57
                JMP24   _BadEmulibCall          ; 58 EMULIB_RESERVED_58
                JMP24   _BadEmulibCall          ; 59 EMULIB_RESERVED_59
                JMP24   _BadEmulibCall          ; 60 EMULIB_RESERVED_60
                JMP24   _BadEmulibCall          ; 61 EMULIB_RESERVED_61
                JMP24   _BadEmulibCall          ; 62 EMULIB_RESERVED_62

                ; --- Version (slot 63) -----------------------------------
                JMP24   _EmulibVersion          ; 63 EMULIB_VERSION         LIVE

_EmulibTemplateEnd:

; ============================================================================
; End of kos_emulib_template.asm
; ============================================================================
