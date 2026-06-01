; ============================================================================
; kos_klib_template.asm — k/OS KLIB ROM template + init routine
; ============================================================================
; Date:    29 May 2026
; Status:  KLIB v1.1 — slots 06 and 07 wired
; Revision: r8 - 29 May 2026 — Part 39 (kosh.com migration). Two slots
;             promoted to LIVE:
;               slot 06 → _TryMount      (kfs/kos_fs.asm)
;               slot 07 → _SlotForDrive  (kfs/kos_fs.asm)
;             KLIB_VERSION (slot 63) now returns $0101 (v1.1).
;             No other slot positions changed; this is a pure-fill of
;             two RESERVED entries in the Integer-math tail.
;             Requires kos_klib.inc r8+.
;
;           r7 - 18 May 2026 — Slot 46 (KLIB_BYTES_SPLIT) wired to
;             _KBytesSplit in kos_klib_impl.asm r10. 25/64 LIVE.
;
;           r6 - 13 May 2026 — Slots 04 (KLIB_DIVMOD32) and 45 (KLIB_UTOA32)
;             wired to _KDivmod32 and _KUtoa32 in kos_klib_impl.asm r9.
;             24/64 LIVE.
;
;           r5 - 12 May 2026 — Slots 02 (KLIB_DIVMOD16) and 03
;             (KLIB_UDIVMOD16) wired to _KDivmod16 and _KUDivmod16 in
;             kos_klib_impl.asm r8. 22/64 LIVE.
;
;           r4 - 5 May 2026 — Tier 4 entries wired:
;             slot 35 → _KStrCat, slot 44 → _KAtoh, slot 48 → _KRand16,
;             slot 49 → _KSRand, slot 51 → _KDelayMs.
;             20/64 LIVE.
;             _InitKLib now also seeds KLIB_SEED at $00:$9FFE to
;             $ACE1 (non-zero default for xorshift PRNG).
;
;           r3 - 5 May 2026 — Tier 2+3 entries wired:
;             slot 33 → _KStrCpy, slot 34 → _KStrCmp, slot 36 → _KStrChr,
;             slot 39 → _KMemCmp, slot 40 → _KItoa, slot 41 → _KUtoa,
;             slot 42 → _KItoh, slot 43 → _KAtoi.
;             15/64 slots LIVE.
;
;           r2 - 5 May 2026 — Tier 1 entries wired:
;             slot 32 → _KStrLen, slot 37 → _KMemCpy, slot 38 → _KMemSet,
;             slot 50 → _KTicks. Implementations in kos_klib_impl.asm r2.
;
;           r1 - 5 May 2026 — initial
;
;   Provides the patchable RAM jump table mechanism for KLIB:
;
;     _KLibTemplate     ROM-resident block of 64 JMP24 instructions.
;                       Copied byte-for-byte to $00:$A000 at boot.
;
;     _InitKLib         Boot-time copy from ROM template to RAM table.
;                       Wired into _InitKernel after _InitHeap.
;
;     _BadKlibCall      Diagnostic + system halt for any unimplemented
;                       slot. Prints a message to terminal then HALT #$1B.
;
;     _KLibVersion      KLIB_VERSION (slot 63) implementation.
;                       Returns D0 = $0101 (v1.1), C=0.
;
;   Implementation symbols referenced (must be resolvable at link time):
;     _KMul16x16_32     in kos_klib_impl.asm (moved from kos_console.asm)
;     _KDiv10           in kos_klib_impl.asm (moved from kos_console.asm)
;
;   The ROM template is the source of truth for the table. To add a new
;   live entry: replace the corresponding `JMP24 _BadKlibCall` line below
;   with `JMP24 <impl_symbol>` and add the impl. Slot positions are
;   fixed by ABI — never reorder.
; ============================================================================

; ============================================================================
; _InitKLib — copy KLIB template into RAM jump table
;   Input:    none
;   Output:   $00:$A000..$A0FF populated with 64 JMP24 instructions
;   Clobbers: D0, XY0, XY1
;   Preserves: D1, D2, D3, XY2, XY3
; ============================================================================
_InitKLib:
                PUSH    D1, XY3
                PUSH    XY1, XY3

                ; Source: ROM template (24-bit pointer in XY1)
                LOADI   Y1, #>_KLibTemplate
                LOADI   X1, #<_KLibTemplate

                ; Destination: $00:$A000 (24-bit pointer in XY0)
                LOADI   Y0, #$00
                LOADI   X0, #KLIB_BASE

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

                ; Initialise PRNG seed (Tier 4). Non-zero — xorshift
                ; cannot escape zero. $ACE1 is arbitrary but memorable.
                LOADI   D0, #$ACE1
                STOREZ  D0, [#KLIB_SEED]

                POP     XY1, XY3
                POP     D1, XY3
                RET

; ============================================================================
; _BadKlibCall — diagnostic + halt for any unimplemented KLIB slot
;
;   Reached when user code calls a stub entry. Prints a one-line
;   diagnostic to the terminal then halts the system.
;
;   We can't recover the slot number from here — by the time we run,
;   the JMP24 has already discarded the entry address. A future
;   enhancement could push the slot number before JMP24 in each stub
;   entry; for Phase 10 we just identify the failure mode.
;
;   HALT code $1B = "bad lib call".
; ============================================================================
_BadKlibCall:
                LOADI   Y0, #>_KLibBadMsg
                LOADI   X0, #<_KLibBadMsg
                CALL24  _RawPuts
                HALT    #$1B

_KLibBadMsg:
                .TEXT   "*** KLIB: bad call (unimplemented slot) ***\n\0"

; ============================================================================
; _KLibVersion — slot 63 implementation
;   Output:   D0 = $0100 (v1.0)
;   Flags:    C = 0
;   Clobbers: nothing else
; ============================================================================
_KLibVersion:
                LOADI   D0, #KLIB_VERSION_VALUE
                RETCC

; ============================================================================
; _KLibTemplate — ROM-resident template copied to $00:$A000 at boot
;
;   Each entry is one JMP24 to its implementation. JMP24 is 4 bytes
;   (instruction word + 24-bit target padded to 2 words). 64 entries
;   = 256 bytes of ROM, identical to the runtime RAM table.
;
;   ABI: slot positions are fixed. Never reorder. New live entries
;   replace `JMP24 _BadKlibCall` with `JMP24 <impl>`. The
;   KLIB_RESERVED_xx slots are intentionally unallocated — they exist
;   so the ABI has growth room without disturbing existing offsets.
; ============================================================================
_KLibTemplate:
                ; --- Integer math (slots 00-07) ---------------------------
                JMP24   _KMul16x16_32           ; 00 KLIB_MUL16x16_32   LIVE
                JMP24   _KDiv10                 ; 01 KLIB_DIV10         LIVE
                JMP24   _KDivmod16              ; 02 KLIB_DIVMOD16      LIVE
                JMP24   _KUDivmod16             ; 03 KLIB_UDIVMOD16     LIVE
                JMP24   _KDivmod32              ; 04 KLIB_DIVMOD32      LIVE
                JMP24   _BadKlibCall            ; 05 KLIB_MUL32x32_32
                JMP24   _TryMount               ; 06 KLIB_TRY_MOUNT     LIVE (v1.1)
                JMP24   _SlotForDrive           ; 07 KLIB_SLOT_FOR_DRIVE LIVE (v1.1)

                ; --- Float basic (slots 08-23) ---------------------------
                JMP24   _BadKlibCall            ; 08 KLIB_FADD
                JMP24   _BadKlibCall            ; 09 KLIB_FSUB
                JMP24   _BadKlibCall            ; 10 KLIB_FMUL
                JMP24   _BadKlibCall            ; 11 KLIB_FDIV
                JMP24   _BadKlibCall            ; 12 KLIB_FNEG
                JMP24   _BadKlibCall            ; 13 KLIB_FCMP
                JMP24   _BadKlibCall            ; 14 KLIB_FTOI
                JMP24   _BadKlibCall            ; 15 KLIB_ITOF
                JMP24   _BadKlibCall            ; 16 KLIB_FTOA
                JMP24   _BadKlibCall            ; 17 KLIB_ATOF
                JMP24   _BadKlibCall            ; 18 KLIB_FSQRT
                JMP24   _BadKlibCall            ; 19 KLIB_FABS
                JMP24   _BadKlibCall            ; 20 KLIB_RESERVED_20
                JMP24   _BadKlibCall            ; 21 KLIB_RESERVED_21
                JMP24   _BadKlibCall            ; 22 KLIB_RESERVED_22
                JMP24   _BadKlibCall            ; 23 KLIB_RESERVED_23

                ; --- Float transcendental (slots 24-31) ------------------
                JMP24   _BadKlibCall            ; 24 KLIB_FSIN
                JMP24   _BadKlibCall            ; 25 KLIB_FCOS
                JMP24   _BadKlibCall            ; 26 KLIB_FTAN
                JMP24   _BadKlibCall            ; 27 KLIB_FATAN
                JMP24   _BadKlibCall            ; 28 KLIB_FLN
                JMP24   _BadKlibCall            ; 29 KLIB_FEXP
                JMP24   _BadKlibCall            ; 30 KLIB_FPOW
                JMP24   _BadKlibCall            ; 31 KLIB_RESERVED_31

                ; --- Strings (slots 32-39) -------------------------------
                JMP24   _KStrLen                ; 32 KLIB_STRLEN        LIVE
                JMP24   _KStrCpy                ; 33 KLIB_STRCPY        LIVE
                JMP24   _KStrCmp                ; 34 KLIB_STRCMP        LIVE
                JMP24   _KStrCat                ; 35 KLIB_STRCAT        LIVE
                JMP24   _KStrChr                ; 36 KLIB_STRCHR        LIVE
                JMP24   _KMemCpy                ; 37 KLIB_MEMCPY        LIVE
                JMP24   _KMemSet                ; 38 KLIB_MEMSET        LIVE
                JMP24   _KMemCmp                ; 39 KLIB_MEMCMP        LIVE

                ; --- Number conversion (slots 40-47) ---------------------
                JMP24   _KItoa                  ; 40 KLIB_ITOA          LIVE
                JMP24   _KUtoa                  ; 41 KLIB_UTOA          LIVE
                JMP24   _KItoh                  ; 42 KLIB_ITOH          LIVE
                JMP24   _KAtoi                  ; 43 KLIB_ATOI          LIVE
                JMP24   _KAtoh                  ; 44 KLIB_ATOH          LIVE
                JMP24   _KUtoa32                ; 45 KLIB_UTOA32        LIVE
                JMP24   _KBytesSplit            ; 46 KLIB_BYTES_SPLIT   LIVE
                JMP24   _BadKlibCall            ; 47 KLIB_RESERVED_47

                ; --- Random / time (slots 48-55) -------------------------
                JMP24   _KRand16                ; 48 KLIB_RAND16        LIVE
                JMP24   _KSRand                 ; 49 KLIB_SRAND         LIVE
                JMP24   _KTicks                 ; 50 KLIB_TICKS         LIVE
                JMP24   _KDelayMs               ; 51 KLIB_DELAY_MS      LIVE
                JMP24   _BadKlibCall            ; 52 KLIB_RESERVED_52
                JMP24   _BadKlibCall            ; 53 KLIB_RESERVED_53
                JMP24   _BadKlibCall            ; 54 KLIB_RESERVED_54
                JMP24   _BadKlibCall            ; 55 KLIB_RESERVED_55

                ; --- Reserved (slots 56-62) ------------------------------
                JMP24   _BadKlibCall            ; 56 KLIB_RESERVED_56
                JMP24   _BadKlibCall            ; 57 KLIB_RESERVED_57
                JMP24   _BadKlibCall            ; 58 KLIB_RESERVED_58
                JMP24   _BadKlibCall            ; 59 KLIB_RESERVED_59
                JMP24   _BadKlibCall            ; 60 KLIB_RESERVED_60
                JMP24   _BadKlibCall            ; 61 KLIB_RESERVED_61
                JMP24   _BadKlibCall            ; 62 KLIB_RESERVED_62

                ; --- Version (slot 63) -----------------------------------
                JMP24   _KLibVersion            ; 63 KLIB_VERSION       LIVE

_KLibTemplateEnd:

; ============================================================================
; End of kos_klib_template.asm
; ============================================================================
