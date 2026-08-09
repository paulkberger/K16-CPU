; ============================================================================
; kos_klib.inc — k/OS shared library jump-table public symbols
; ============================================================================
; Date:    29 May 2026
; Status:  KLIB v1.1 — slots 06 (TRY_MOUNT) and 07 (SLOT_FOR_DRIVE) published
; Revision: r8 - 29 May 2026 — Part 39 (kosh.com migration). Two
;             RESERVED slots promoted to LIVE in the Integer-math
;             reserved tail:
;               - Slot 06: KLIB_TRY_MOUNT (was KLIB_RESERVED_06)
;                          Verifies and caches the FAT16 BPB on a drive.
;                          Implementation: _TryMount in kfs/kos_fs.asm.
;               - Slot 07: KLIB_SLOT_FOR_DRIVE (was KLIB_RESERVED_07)
;                          Drive index (A/B/C/D) → vol-slot offset.
;                          Implementation: _SlotForDrive in kfs/kos_fs.asm.
;             These are pure-portable FS helpers (no emulator dependency);
;             they were promoted to KLIB so the kosh.com standalone build
;             can reach them via the published ABI rather than depending
;             on kernel-internal symbol resolution.
;
;             All other slots unchanged — random/time stays at 48–51,
;             float transcendentals stay at 24–31, no addresses moved.
;             Filling RESERVED slots is a minor-version bump (v1.0 → v1.1),
;             so KLIB_VERSION_VALUE goes from $0100 to $0101 but existing
;             callers don't need reassembly.
;
;             Emulator-only host-disk operations (_HostList, _HostMount,
;             _HostUnmount, _HostCreate, _HostDelete, _HostRename,
;             _HostBayName, _HostFOpen, _HostFClose, _HostFRead) are
;             NOT in KLIB — they live in EMULIB (kos_emulib.inc, base
;             $A100), introduced alongside this revision.
;
;           r7 - 18 May 2026 — Slot 46 (KLIB_BYTES_SPLIT) LIVE. Takes a
;             32-bit byte count in D1:D0 and returns (whole, hundredths,
;             unit) where unit ∈ {0=B, 1=KB, 2=MB, 3=GB}. Caller picks
;             its own formatting (suffix strings, padding, decimal style).
;             Math primitive, not a formatter — keeps KLIB policy-free.
;             Implementation: cascade of ÷1024 via KLIB_DIVMOD32, then
;             frac = (remainder × 100) / 1024 via KLIB_MUL16x16_32 +
;             KLIB_DIVMOD32. 25/64 slots LIVE.
;
;           r6 - 13 May 2026 — Slots 04 (DIVMOD32) and 45 (UTOA32) LIVE.
;             DIVMOD32: unsigned 32/16 → 32 quotient + 16 remainder,
;             shift-subtract algorithm (33-bit ADC chain). UTOA32:
;             uint32 → decimal at XY0, cursor-style matching UTOA's
;             convention, recursive divide-by-10 via DIVMOD32. Net:
;             user programs can now format 32-bit values directly,
;             needed for TCB_PREEMPT_COUNT (32-bit ticks) display in
;             kosh's ps command. 24/64 slots LIVE.
;
;           r5 - 12 May 2026 — Slots 02 (DIVMOD16) and 03 (UDIVMOD16) LIVE.
;             Adapted from K16 BASIC v2.2's divide_16 + umod_16, with
;             KLIB error model (SEC + D0=ERR_INVALID on divisor=0).
;             22/64 slots LIVE.
;
;           r4 - 5 May 2026 — Tier 4 LIVE: STRCAT (35), ATOH (44),
;             RAND16 (48), SRAND (49), DELAY_MS (51).
;             20/64 slots LIVE.
;             Added KLIB_SEED RAM slot at $00:$9FFE for the PRNG state.
;             Initialised by _InitKLib to $ACE1 (non-zero default).
;           r3 - 5 May 2026 — Tier 2+3 LIVE: STRCPY (33), STRCMP (34),
;             STRCHR (36), MEMCMP (39), ITOA (40), UTOA (41), ITOH (42),
;             ATOI (43). 15/64 slots LIVE.
;           r2 - 5 May 2026 — Tier 1 LIVE: KLIB_STRLEN (32),
;             KLIB_MEMCPY (37), KLIB_MEMSET (38), KLIB_TICKS (50).
;             7/64 slots LIVE, 57 stubbed.
;           r1 - 5 May 2026 — initial
;
;   Defines the published ABI for the k/OS standard library (KLIB).
;   The library lives as a 64-entry RAM jump table at $00:$A000-$A0FF.
;   Each entry is one JMP24 instruction (4 bytes) forwarding to the
;   ROM-resident implementation.
;
;   Entries are LIVE, stub, or RESERVED:
;     LIVE     — implemented and callable (slots 00, 01, 63 in Phase 10)
;     stub     — published symbol; calls land in _BadKlibCall (system halt)
;     RESERVED — slot intentionally unallocated for future growth
;
;   Stub slots have published names so user code can be written today
;   against the planned ABI; calling an unimplemented stub halts the
;   system loudly with HALT #$1B at runtime, making missing
;   implementations impossible to miss.
;
;   ABI stability rule: once a slot is published here, its address
;   never moves. New functions take the next free RESERVED slot.
;
;   See kos_klib_design_v3.md for the full design rationale.
; ============================================================================

;-----------------------------------------------------------------------------
; Library base addresses (Page $00 RAM)
;-----------------------------------------------------------------------------
; --- Address space (.SPACE): this file's regions are 'kernel'-owned ---
.SPACE kernel

KLIBTABLE       .REGION $A000
  KLIB_BASE       .RS $100            ; $A000  64 slots x 4 B = 256 B jump table
                .ENDREGION  ; KLIBTABLE_END=$A100  KLIBTABLE_SIZE=$100
GLIB_BASE       .EQU    $A100               ; GLIB jump table base (RESERVED - Phase 10 does not init)

KLIB_VERSION_VALUE .EQU $0101               ; v1.1 (high byte = major, low byte = minor)
                                            ; v1.1 (Part 39): slots 06 (TRY_MOUNT) and 07
                                            ; (SLOT_FOR_DRIVE) promoted from RESERVED.

;-----------------------------------------------------------------------------
; KLIB internal state (Page $00 RAM, just below jump table)
;-----------------------------------------------------------------------------
KLIBSTATE       .REGION $9FFE
  KLIB_SEED       .RS 1w              ; $9FFE  xorshift16 RNG state for RAND16/SRAND
                .ENDREGION  ; KLIBSTATE_END=$A000  KLIBSTATE_SIZE=$02

;-----------------------------------------------------------------------------
; Integer math (slots 00-07)
;-----------------------------------------------------------------------------
KLIB_MUL16x16_32   .EQU KLIB_BASE+$00       ; D0,D1 → D1:D0 (LIVE)
KLIB_DIV10         .EQU KLIB_BASE+$04       ; D0/10 → D0,D1 (LIVE)
KLIB_DIVMOD16      .EQU KLIB_BASE+$08       ; signed 16/16 → D0=quot, D1=rem (LIVE; SEC on /0)
KLIB_UDIVMOD16     .EQU KLIB_BASE+$0C       ; unsigned 16/16 → D0=quot, D1=rem (LIVE; SEC on /0)
KLIB_DIVMOD32      .EQU KLIB_BASE+$10       ; unsigned 32/16 → D1:D0=quot, D2=rem (LIVE; SEC on /0)
KLIB_MUL32x32_32   .EQU KLIB_BASE+$14       ; 32×32→32 low half (stub)
KLIB_TRY_MOUNT     .EQU KLIB_BASE+$18       ; verify+cache FAT16 BPB on a drive (LIVE; v1.1)
KLIB_SLOT_FOR_DRIVE .EQU KLIB_BASE+$1C      ; drive index → vol-slot offset (LIVE; v1.1)

;-----------------------------------------------------------------------------
; Float — basic (slots 08-23) — Motorola FFP format
;-----------------------------------------------------------------------------
KLIB_FADD          .EQU KLIB_BASE+$20       ; FFP add (stub)
KLIB_FSUB          .EQU KLIB_BASE+$24       ; FFP sub (stub)
KLIB_FMUL          .EQU KLIB_BASE+$28       ; FFP mul (stub)
KLIB_FDIV          .EQU KLIB_BASE+$2C       ; FFP div (stub)
KLIB_FNEG          .EQU KLIB_BASE+$30       ; FFP negate (stub)
KLIB_FCMP          .EQU KLIB_BASE+$34       ; FFP compare (stub)
KLIB_FTOI          .EQU KLIB_BASE+$38       ; FFP → int32 (stub)
KLIB_ITOF          .EQU KLIB_BASE+$3C       ; int32 → FFP (stub)
KLIB_FTOA          .EQU KLIB_BASE+$40       ; FFP → ASCII (stub)
KLIB_ATOF          .EQU KLIB_BASE+$44       ; ASCII → FFP (stub)
KLIB_FSQRT         .EQU KLIB_BASE+$48       ; square root (stub)
KLIB_FABS          .EQU KLIB_BASE+$4C       ; absolute value (stub)
KLIB_RESERVED_20   .EQU KLIB_BASE+$50       ; reserved
KLIB_RESERVED_21   .EQU KLIB_BASE+$54       ; reserved
KLIB_RESERVED_22   .EQU KLIB_BASE+$58       ; reserved
KLIB_RESERVED_23   .EQU KLIB_BASE+$5C       ; reserved

;-----------------------------------------------------------------------------
; Float — transcendental (slots 24-31)
;-----------------------------------------------------------------------------
KLIB_FSIN          .EQU KLIB_BASE+$60       ; sine (stub)
KLIB_FCOS          .EQU KLIB_BASE+$64       ; cosine (stub)
KLIB_FTAN          .EQU KLIB_BASE+$68       ; tangent (stub)
KLIB_FATAN         .EQU KLIB_BASE+$6C       ; arctangent (stub)
KLIB_FLN           .EQU KLIB_BASE+$70       ; natural log (stub)
KLIB_FEXP          .EQU KLIB_BASE+$74       ; exponential (stub)
KLIB_FPOW          .EQU KLIB_BASE+$78       ; power x^y (stub)
KLIB_RESERVED_31   .EQU KLIB_BASE+$7C       ; reserved

;-----------------------------------------------------------------------------
; Strings (slots 32-39)
;-----------------------------------------------------------------------------
KLIB_STRLEN        .EQU KLIB_BASE+$80       ; XY0 → D0 (LIVE)
KLIB_STRCPY        .EQU KLIB_BASE+$84       ; XY0 ← XY1 nul-term (LIVE)
KLIB_STRCMP        .EQU KLIB_BASE+$88       ; XY0 vs XY1 → flags+D0 (LIVE)
KLIB_STRCAT        .EQU KLIB_BASE+$8C       ; append (LIVE)
KLIB_STRCHR        .EQU KLIB_BASE+$90       ; find byte (LIVE)
KLIB_MEMCPY        .EQU KLIB_BASE+$94       ; XY0 ← XY1, D0 bytes (LIVE)
KLIB_MEMSET        .EQU KLIB_BASE+$98       ; XY0, D0 bytes, D1 byte value (LIVE)
KLIB_MEMCMP        .EQU KLIB_BASE+$9C       ; XY0 vs XY1, D0 bytes (LIVE)

;-----------------------------------------------------------------------------
; Number conversion (slots 40-47)
;-----------------------------------------------------------------------------
KLIB_ITOA          .EQU KLIB_BASE+$A0       ; int16 → decimal at XY0; advances + writes nul (LIVE)
KLIB_UTOA          .EQU KLIB_BASE+$A4       ; uint16 → decimal at XY0; advances + writes nul (LIVE)
KLIB_ITOH          .EQU KLIB_BASE+$A8       ; int16 → 4 hex digits at XY0; advances + writes nul (LIVE)
KLIB_ATOI          .EQU KLIB_BASE+$AC       ; ASCII → int16 (LIVE; supports $-prefix hex)
KLIB_ATOH          .EQU KLIB_BASE+$B0       ; ASCII hex → int16 (LIVE)
KLIB_UTOA32        .EQU KLIB_BASE+$B4       ; uint32 → decimal at XY0; advances + writes nul (LIVE)
KLIB_BYTES_SPLIT   .EQU KLIB_BASE+$B8       ; bytes(32) → whole, hundredths, unit (LIVE; Part 34)
KLIB_RESERVED_47   .EQU KLIB_BASE+$BC       ; reserved

;-----------------------------------------------------------------------------
; Random / time (slots 48-55)
;-----------------------------------------------------------------------------
KLIB_RAND16        .EQU KLIB_BASE+$C0       ; pseudo-random 16-bit (LIVE)
KLIB_SRAND         .EQU KLIB_BASE+$C4       ; seed PRNG (LIVE)
KLIB_TICKS         .EQU KLIB_BASE+$C8       ; get SYS_TICKS (LIVE)
KLIB_DELAY_MS      .EQU KLIB_BASE+$CC       ; busy-wait delay (LIVE)
KLIB_RESERVED_52   .EQU KLIB_BASE+$D0       ; reserved
KLIB_RESERVED_53   .EQU KLIB_BASE+$D4       ; reserved
KLIB_RESERVED_54   .EQU KLIB_BASE+$D8       ; reserved
KLIB_RESERVED_55   .EQU KLIB_BASE+$DC       ; reserved

;-----------------------------------------------------------------------------
; Reserved for growth (slots 56-62)
;-----------------------------------------------------------------------------
KLIB_RESERVED_56   .EQU KLIB_BASE+$E0       ; reserved
KLIB_RESERVED_57   .EQU KLIB_BASE+$E4       ; reserved
KLIB_RESERVED_58   .EQU KLIB_BASE+$E8       ; reserved
KLIB_RESERVED_59   .EQU KLIB_BASE+$EC       ; reserved
KLIB_RESERVED_60   .EQU KLIB_BASE+$F0       ; reserved
KLIB_RESERVED_61   .EQU KLIB_BASE+$F4       ; reserved
KLIB_RESERVED_62   .EQU KLIB_BASE+$F8       ; reserved

;-----------------------------------------------------------------------------
; Version slot (slot 63) — LIVE
;-----------------------------------------------------------------------------
KLIB_VERSION       .EQU KLIB_BASE+$FC       ; D0 = KLIB_VERSION_VALUE (LIVE)

; ============================================================================
; End of kos_klib.inc
; ============================================================================
