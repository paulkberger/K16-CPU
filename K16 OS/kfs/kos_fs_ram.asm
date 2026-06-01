; ============================================================================
; kos_fs_ram.asm — k/OS Phase 16: RAM disk block-layer backend
; ============================================================================
; Date:    6 May 2026
; Status:  Phase 16 Part 1 — block layer + format
; Revision: r3 — 6 May 2026 — tightened up after ISA review:
;             • ADD X0,#2 / ADD X1,#2 instead of INC XYn,#1w. Within a
;               single 512-byte sector we never cross a page boundary,
;               so the X-half-only update is safe and saves 1 cyc/iter.
;               (3 cyc ADD vs 5 cyc INC XY).
;             • Dropped PUSH/POP D3 and XY2 — neither is touched in this
;               file. Honest ABI is "clobbers D0..D2, X0, X1, flags;
;               preserves Y0, Y1 (within sector), D3, XY2, XY3."
;             • CALLR for _RAMSectorToAddr (1 word smaller than CALL24,
;               same 11 cyc effective).
;             • Word-aligned LOADD/STORED loop, 256 iterations.
;
;           r2 — 6 May 2026 — converted byte loops to word loops, switched
;             to CALLR.
;
;           r1 — 6 May 2026 — initial. _BlockReadRAM, _BlockWriteRAM.
;
; Purpose: Translate sector/buffer requests into word copies between the
;            caller's buffer and the RAM disk pages.
;
; Sector → page/offset math:
;   sector  = 0..(RAMDISK_SECTORS - 1)
;   page    = RAMDISK_BASE + (sector >> 7)        ; sector / 128
;   offset  = (sector & $7F) << 9                  ; (sector % 128) * 512
;
; Multi-bit shifts use cheapest available K16 idioms:
;   sector >> 7   :  SHL D, HIGH D                 (2 insns, 6 cyc)
;                    (sector << 1 fits in word; HIGH grabs hi byte = >>7)
;   v << 9        :  SWAPB D, SHL D                (2 insns, 6 cyc)
;                    (assumes hi byte zero on entry — valid after AND #$7F)
;
; The RAMDISK_BASE differs by host (KOS_HOST):
;   HOST_DIGITAL → $1C  (4 pages, 512 sectors)
;   HOST_EMU     → $30  (16 pages, 2048 sectors)
;
; Word-aligned access:
;   Sector boundaries are 512-byte multiples — always word-aligned. Caller
;   buffers must also be word-aligned (FS-internal, controlled by us).
;   We use LOADD/STORED with ADD X,#2 — the X-only stride works because
;   a 512-byte sector occupies offsets [0..$1FE] within whichever 64KB
;   page Y selects, never crossing into the next page.
;
; Both routines are kernel-context functions on the kernel stack. They
; do NOT touch IRQ state — the FAT16 layer is responsible for any
; DINT/EINT envelopes around groups of block ops.
;
; --- ABI -------------------------------------------------------------------
;
; _BlockReadRAM:
;   In:   D0  = sector number (word)
;         XY0 = destination buffer (24-bit), 512 bytes will be written
;   Out:  C   = 0 on success
;         C   = 1 with D0 = ERR_IO if sector out of range
;   Clobbers: D0, D1, D2, X0, X1, flags
;   Preserves: D3, Y0, Y1 (after the call), XY2, XY3
;
; _BlockWriteRAM:  same shape, XY0 is source.
;
; ============================================================================

;-----------------------------------------------------------------------------
; _RAMSectorToAddr — internal helper
;
;   In:   D0  = sector number (word)
;   Out:  C=0: XY1 = (page : byte_offset_within_page)
;              D0  = ERR_OK
;         C=1: D0  = ERR_IO (sector out of range)
;   Clobbers: D0, D1, D2, XY1, flags
;-----------------------------------------------------------------------------
_RAMSectorToAddr:
                ; --- Bounds check by host -------------------------------
                LOADZ   D1, [#KOS_HOST]
                CMP     D1, #HOST_DIGITAL
                BEQ.S   .digital_bounds

                ; EMU path: sector must be < 2048
                CMP     D0, #RAMDISK_SECTORS_EMU
                BHS     .out_of_range
                LOADI   D2, #RAMDISK_PAGE_BASE_EMU
                BRA.S   .compute_addr

.digital_bounds:
                CMP     D0, #RAMDISK_SECTORS_DIGITAL
                BHS     .out_of_range
                LOADI   D2, #RAMDISK_PAGE_BASE_DIGITAL
                ; fall through

.compute_addr:
                ; D0 = sector, D2 = base page byte.
                ; Need: Y1 = D2 + (sector >> 7), X1 = (sector & $7F) << 9.

                ; --- Page byte: D1 = (sector >> 7) + base ---------------
                MOVE    D1, D0                  ; D1 = sector copy
                SHL     D1                      ; D1 = sector << 1
                HIGH    D1                      ; D1 = sector >> 7
                ADD     D1, D2                  ; D1 = base + (sector >> 7)
                MOVE    Y1, D1                  ; Y1 = absolute page byte

                ; --- Byte offset: X1 = (sector & $7F) << 9 --------------
                AND     D0, #$7F                ; D0 = sector mod 128 (0..127)
                SWAPB   D0                      ; D0 = (sector mod 128) << 8
                SHL     D0                      ; D0 = (sector mod 128) << 9
                MOVE    X1, D0                  ; X1 = byte offset within page

                LOADI   D0, #ERR_OK
                RETCC

.out_of_range:
                LOADI   D0, #ERR_IO
                RETCS


;-----------------------------------------------------------------------------
; _BlockReadRAM
;
; Read one 512-byte sector from the RAM disk into the caller's buffer.
;-----------------------------------------------------------------------------
_BlockReadRAM:
                ; Translate sector → XY1 = source RAM-disk address.
                ; XY0 already holds the destination from caller.
                CALLR   _RAMSectorToAddr
                BCS     .read_err

                ; --- Copy 256 words: [XY1] → [XY0] ----------------------
                LOADI   D2, #256                ; word counter

.read_loop:
                LOADD   D0, [XY1]               ; 2 cyc
                STORED  D0, [XY0]               ; 2 cyc
                ADD     X1, #2                  ; 3 cyc — never crosses page
                ADD     X0, #2                  ; 3 cyc
                SUB     D2, #1                  ; 3 cyc — sets Z for branch
                BNE     .read_loop              ; 3 cyc taken / 4 fall-through

                ; Success
                LOADI   D0, #ERR_OK
                CLC
.read_err:
                ; D0 = ERR_IO, C=1 from _RAMSectorToAddr — fall through.
                RET


;-----------------------------------------------------------------------------
; _BlockWriteRAM
;
; Write one 512-byte sector from the caller's buffer to the RAM disk.
;-----------------------------------------------------------------------------
_BlockWriteRAM:
                ; Translate sector → XY1 = destination RAM-disk address.
                ; XY0 already holds the source from caller.
                CALLR   _RAMSectorToAddr
                BCS     .write_err

                ; --- Copy 256 words: [XY0] → [XY1] ----------------------
                LOADI   D2, #256

.write_loop:
                LOADD   D0, [XY0]
                STORED  D0, [XY1]
                ADD     X0, #2
                ADD     X1, #2
                SUB     D2, #1
                BNE     .write_loop

                LOADI   D0, #ERR_OK
                CLC
.write_err:
                RET

; ============================================================================
; End of kos_fs_ram.asm
; ============================================================================
