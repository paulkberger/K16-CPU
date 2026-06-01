; ============================================================================
; kos_emulib.inc — k/OS emulator-only library jump-table public symbols
; ============================================================================
; Date:    29 May 2026
; Status:  EMULIB v1.0 — initial introduction (Part 39).
; Revision: r1 - 29 May 2026 — Part 39 (kosh.com migration). EMULIB
;             introduced to give kosh's emulator-only host-disk shim
;             functions a published address space without polluting
;             KLIB (which is meant to be portable across emulator,
;             FPGA, and discrete TTL builds).
;
;             On the emulator, EMULIB is populated by _InitEmulib (in
;             kos_emulib_template.asm) the same way KLIB is by
;             _InitKLib. On real hardware (FPGA, discrete TTL), the
;             EMULIB region is either left unpopulated (calls land in
;             ROM as $00 bytes that won't decode as JMP24, behaviour
;             undefined) or — preferred — _InitEmulib stays in the
;             build but every slot resolves to _BadEmulibCall, so any
;             kosh command that depends on the host bridge fails with
;             a clean diagnostic instead of silent corruption.
;
;             Functions currently published:
;               00 EMULIB_HOST_LIST       _HostList
;               01 EMULIB_HOST_MOUNT      _HostMount
;               02 EMULIB_HOST_UNMOUNT    _HostUnmount
;               03 EMULIB_HOST_CREATE     _HostCreate
;               04 EMULIB_HOST_DELETE     _HostDelete
;               05 EMULIB_HOST_RENAME     _HostRename
;               06 EMULIB_HOST_BAYNAME    _HostBayName
;               07 EMULIB_HOST_FOPEN     _HostFOpen
;               08 EMULIB_HOST_FCLOSE    _HostFClose
;               09 EMULIB_HOST_FREAD     _HostFRead
;               10-62 reserved
;               63 EMULIB_VERSION
;
;             Functions intentionally NOT in EMULIB:
;               _TryMount, _SlotForDrive — these are portable FS code
;                 (no host-OS dependency); promoted to KLIB v1.1 slots
;                 06 and 07 instead.
;
;             Implementations of all _Host* functions live in
;             kfs/kos_fs_host_mgr.asm (existing code, no changes
;             required for this rev — the template simply JMP24s to
;             those symbols).
;
;   Layout in RAM:
;     EMULIB_BASE  ($A200)  64 JMP24 instructions, 4 bytes each, 256 bytes
;                           total. Populated by _InitEmulib at boot.
;
;   ABI stability rule (same as KLIB): once a slot is published here,
;   its address never moves. New functions take the next free RESERVED
;   slot. The VERSION slot at offset $FC is the published "version
;   probe" — call it to retrieve EMULIB_VERSION_VALUE.
; ============================================================================


EMULIB_BASE     .EQU    $A200               ; EMULIB jump table base ($A200..$A2FF)
                                            ; (KLIB sits at $A000..$A0FF and
                                            ; $A100..$A1FF is reserved for the future
                                            ; GLIB graphics library — see kos_defs.inc
                                            ; page-$00 layout map.)

;-----------------------------------------------------------------------------
; Version constants
;-----------------------------------------------------------------------------
EMULIB_VERSION_VALUE .EQU $0100             ; v1.0 (high byte = major, low byte = minor)


;-----------------------------------------------------------------------------
; Host-disk operations (slots 00-09) — emulator-only
;-----------------------------------------------------------------------------
EMULIB_HOST_LIST       .EQU EMULIB_BASE+$00 ; enumerate disk\*.KOS images (LIVE)
EMULIB_HOST_MOUNT      .EQU EMULIB_BASE+$04 ; mount disk\NAME.KOS on a bay (LIVE)
EMULIB_HOST_UNMOUNT    .EQU EMULIB_BASE+$08 ; unmount a bay (LIVE)
EMULIB_HOST_CREATE     .EQU EMULIB_BASE+$0C ; create blank disk\NAME.KOS (LIVE)
EMULIB_HOST_DELETE     .EQU EMULIB_BASE+$10 ; delete disk\NAME.KOS (LIVE)
EMULIB_HOST_RENAME     .EQU EMULIB_BASE+$14 ; rename disk\NAME.KOS (LIVE)
EMULIB_HOST_BAYNAME    .EQU EMULIB_BASE+$18 ; bay → ASCIIZ name (LIVE)
EMULIB_HOST_FOPEN      .EQU EMULIB_BASE+$1C ; open host file for read (LIVE)
EMULIB_HOST_FCLOSE     .EQU EMULIB_BASE+$20 ; close host file (LIVE)
EMULIB_HOST_FREAD      .EQU EMULIB_BASE+$24 ; read from host file (LIVE)

;-----------------------------------------------------------------------------
; Reserved for growth (slots 10-62)
;-----------------------------------------------------------------------------
EMULIB_RESERVED_10     .EQU EMULIB_BASE+$28
EMULIB_RESERVED_11     .EQU EMULIB_BASE+$2C
EMULIB_RESERVED_12     .EQU EMULIB_BASE+$30
EMULIB_RESERVED_13     .EQU EMULIB_BASE+$34
EMULIB_RESERVED_14     .EQU EMULIB_BASE+$38
EMULIB_RESERVED_15     .EQU EMULIB_BASE+$3C
EMULIB_RESERVED_16     .EQU EMULIB_BASE+$40
EMULIB_RESERVED_17     .EQU EMULIB_BASE+$44
EMULIB_RESERVED_18     .EQU EMULIB_BASE+$48
EMULIB_RESERVED_19     .EQU EMULIB_BASE+$4C
EMULIB_RESERVED_20     .EQU EMULIB_BASE+$50
EMULIB_RESERVED_21     .EQU EMULIB_BASE+$54
EMULIB_RESERVED_22     .EQU EMULIB_BASE+$58
EMULIB_RESERVED_23     .EQU EMULIB_BASE+$5C
EMULIB_RESERVED_24     .EQU EMULIB_BASE+$60
EMULIB_RESERVED_25     .EQU EMULIB_BASE+$64
EMULIB_RESERVED_26     .EQU EMULIB_BASE+$68
EMULIB_RESERVED_27     .EQU EMULIB_BASE+$6C
EMULIB_RESERVED_28     .EQU EMULIB_BASE+$70
EMULIB_RESERVED_29     .EQU EMULIB_BASE+$74
EMULIB_RESERVED_30     .EQU EMULIB_BASE+$78
EMULIB_RESERVED_31     .EQU EMULIB_BASE+$7C
EMULIB_RESERVED_32     .EQU EMULIB_BASE+$80
EMULIB_RESERVED_33     .EQU EMULIB_BASE+$84
EMULIB_RESERVED_34     .EQU EMULIB_BASE+$88
EMULIB_RESERVED_35     .EQU EMULIB_BASE+$8C
EMULIB_RESERVED_36     .EQU EMULIB_BASE+$90
EMULIB_RESERVED_37     .EQU EMULIB_BASE+$94
EMULIB_RESERVED_38     .EQU EMULIB_BASE+$98
EMULIB_RESERVED_39     .EQU EMULIB_BASE+$9C
EMULIB_RESERVED_40     .EQU EMULIB_BASE+$A0
EMULIB_RESERVED_41     .EQU EMULIB_BASE+$A4
EMULIB_RESERVED_42     .EQU EMULIB_BASE+$A8
EMULIB_RESERVED_43     .EQU EMULIB_BASE+$AC
EMULIB_RESERVED_44     .EQU EMULIB_BASE+$B0
EMULIB_RESERVED_45     .EQU EMULIB_BASE+$B4
EMULIB_RESERVED_46     .EQU EMULIB_BASE+$B8
EMULIB_RESERVED_47     .EQU EMULIB_BASE+$BC
EMULIB_RESERVED_48     .EQU EMULIB_BASE+$C0
EMULIB_RESERVED_49     .EQU EMULIB_BASE+$C4
EMULIB_RESERVED_50     .EQU EMULIB_BASE+$C8
EMULIB_RESERVED_51     .EQU EMULIB_BASE+$CC
EMULIB_RESERVED_52     .EQU EMULIB_BASE+$D0
EMULIB_RESERVED_53     .EQU EMULIB_BASE+$D4
EMULIB_RESERVED_54     .EQU EMULIB_BASE+$D8
EMULIB_RESERVED_55     .EQU EMULIB_BASE+$DC
EMULIB_RESERVED_56     .EQU EMULIB_BASE+$E0
EMULIB_RESERVED_57     .EQU EMULIB_BASE+$E4
EMULIB_RESERVED_58     .EQU EMULIB_BASE+$E8
EMULIB_RESERVED_59     .EQU EMULIB_BASE+$EC
EMULIB_RESERVED_60     .EQU EMULIB_BASE+$F0
EMULIB_RESERVED_61     .EQU EMULIB_BASE+$F4
EMULIB_RESERVED_62     .EQU EMULIB_BASE+$F8

;-----------------------------------------------------------------------------
; Version slot (slot 63) — LIVE
;-----------------------------------------------------------------------------
EMULIB_VERSION         .EQU EMULIB_BASE+$FC ; D0 = EMULIB_VERSION_VALUE (LIVE)

; ============================================================================
; End of kos_emulib.inc
; ============================================================================
