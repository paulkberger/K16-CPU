; ============================================================================
; kos_fs_dir_lfn.asm — k/OS VFAT long-filename family (split from kos_fs_dir)
; ============================================================================
; Part 47 (17 June 2026): extracted verbatim from kos_fs_dir.asm. The LFN
; read/write machinery, the 8.3 short-name generator, and the LFN-run
; create/delete/long-lookup routines.
;
; NOT standalone — same assembly unit as kos_fs_dir.asm. Must be .INCLUDEd
; immediately AFTER kos_fs_dir.asm and BEFORE kos_fs_dir_path.asm in
; kos_boot.asm. All inter-file calls are CALLR (PC-relative); page-$00
; scratch (LFN_*/RV_*/FD_*) lives in kos_fs_defs.inc.
;
; Calls into kos_fs_dir.asm: _DicFormatShortEntry, _DcrEntryAddr, _DirSecToAbs,
; _DirLookup, _DirNameToFat. Calls into kos_fs.asm: _VolBlockRead,
; _VolBlockWrite. Calls into kos_fs_fd.asm: (none).
;
; 8 August 2026 - _DirFindRun end-of-directory sentinel fix.
;   A multi-slot create whose run did not fit in the tail of one sector was
;   placed in the next sector while the tail's $00 entries were left alone.
;   $00 is the end-of-directory marker, so _DirNext stopped there and the
;   entry - though correctly written - was invisible to ls and to the
;   _DirLookupLong re-lookup in _CreateEmptyEntry, which surfaced as
;   ERR_NOTFOUND from a create that had succeeded.  Repeat attempts each
;   left another orphan.  _DirFindRun now stamps those trailing $00 first
;   bytes to $E5 and writes the sector back before advancing.
;
;   Not LFN-specific: it needs only a directory whose used-slot count leaves
;   a tail gap smaller than the next run.  With 7 two-slot entries filling
;   entries 0..13, a 3-slot run (a 14+ char name) was the first to trip it.
; ============================================================================


; ============================================================================
; _GenShortDerive  -  long name -> lossy 8.3 in GENSN_SRC, D0 = lossy flag.
;
;   In:        XY0 = ASCIIZ long name (full pointer, Y0 = page)
;   Out:       GENSN_SRC[0..10] = space-padded base(8)+ext(3), uppercased,
;              illegal chars -> '_'.  D0 = 0 clean / 1 lossy.
;   Clobbers:  D0, D1, D2, D3, XY0, XY1, flags + GENSN_* page-$00 scratch.
;   Preserves: XY2, XY3.
; ============================================================================
_GenShortDerive:
                ; lossy = 0
                LOADI   D0, #0
                STOREZB D0, [#GENSN_LOSSY]

                ; space-fill GENSN_SRC[0..10]
                LOADI   D1, #0
.gsd_fill:
                CMP     D1, #11
                BHS     .gsd_strip
                LOADI   D0, #' '
                LOADI   Y1, #$00
                LOADI   X1, #GENSN_SRC
                ADD     X1, D1
                STOREB  D0, [XY1]
                ADD     D1, #1
                BRA     .gsd_fill

                ; strip leading '.' / ' '
.gsd_strip:
                LOADB   D0, [XY0]
                AND     D0, #$FF
                CMP     D0, #' '
                BEQ     .gsd_strip1
                CMP     D0, #'.'
                BEQ     .gsd_strip1
                BRA     .gsd_scan
.gsd_strip1:
                LOADI   D0, #1
                STOREZB D0, [#GENSN_LOSSY]       ; dropped a leading char
                ADD     X0, #1
                BRA     .gsd_strip

                ; scan: GENSN_LEN = length, GENSN_LASTDOT = last-dot offset
.gsd_scan:
                LOADI   D0, #$FFFF
                STOREZ  D0, [#GENSN_LASTDOT]
                LOADI   D1, #0
.gsd_scan_lp:
                LOADB   D0, [XY0+D1]
                AND     D0, #$FF
                CMP     D0, #0
                BEQ     .gsd_scan_end
                CMP     D0, #'.'
                BNE     .gsd_scan_nx
                STOREZ  D1, [#GENSN_LASTDOT]
.gsd_scan_nx:
                ADD     D1, #1
                BRA     .gsd_scan_lp
.gsd_scan_end:
                STOREZ  D1, [#GENSN_LEN]

                ; build base into GENSN_SRC[0..7]
                ; D1 = src index, D2 = base limit, D3 = dest count (0..8)
                LOADZ   D2, [#GENSN_LASTDOT]
                CMP     D2, #$FFFF
                BNE     .gsd_base
                LOADZ   D2, [#GENSN_LEN]        ; no dot: base = whole name
.gsd_base:
                LOADI   D1, #0
                LOADI   D3, #0
.gsd_base_lp:
                CMP     D1, D2
                BHS     .gsd_base_end
                LOADB   D0, [XY0+D1]
                AND     D0, #$FF
                ADD     D1, #1
                CMP     D0, #' '
                BEQ     .gsd_base_lossy
                CMP     D0, #'.'
                BEQ     .gsd_base_lossy         ; embedded dot dropped
                CALLR   _MapChar                ; D0 -> upper/_, sets LOSSY; keeps D1/D2/D3
                CMP     D3, #8
                BHS     .gsd_base_trunc
                LOADI   Y1, #$00
                LOADI   X1, #GENSN_SRC
                ADD     X1, D3
                STOREB  D0, [XY1]
                ADD     D3, #1
                BRA     .gsd_base_lp
.gsd_base_trunc:
                LOADI   D0, #1
                STOREZB D0, [#GENSN_LOSSY]       ; >8 base chars
                BRA     .gsd_base_lp
.gsd_base_lossy:
                LOADI   D0, #1
                STOREZB D0, [#GENSN_LOSSY]
                BRA     .gsd_base_lp
.gsd_base_end:
                ; empty base -> '_' (lossy)
                CMP     D3, #0
                BNE     .gsd_ext
                LOADI   D0, #'_'
                LOADI   Y1, #$00
                LOADI   X1, #GENSN_SRC
                STOREB  D0, [XY1]
                LOADI   D0, #1
                STOREZB D0, [#GENSN_LOSSY]

                ; build ext into GENSN_SRC[8..10]
.gsd_ext:
                LOADZ   D0, [#GENSN_LASTDOT]
                CMP     D0, #$FFFF
                BEQ     .gsd_done               ; no extension
                MOVE    D1, D0
                ADD     D1, #1                  ; i = lastdot+1
                LOADZ   D2, [#GENSN_LEN]        ; limit = len
                LOADI   D3, #8                  ; dest pos 8..11
.gsd_ext_lp:
                CMP     D1, D2
                BHS     .gsd_done
                LOADB   D0, [XY0+D1]
                AND     D0, #$FF
                ADD     D1, #1
                CMP     D0, #' '
                BEQ     .gsd_ext_lossy
                CALLR   _MapChar
                CMP     D3, #11
                BHS     .gsd_ext_trunc
                LOADI   Y1, #$00
                LOADI   X1, #GENSN_SRC
                ADD     X1, D3
                STOREB  D0, [XY1]
                ADD     D3, #1
                BRA     .gsd_ext_lp
.gsd_ext_trunc:
                LOADI   D0, #1
                STOREZB D0, [#GENSN_LOSSY]       ; >3 ext chars
                BRA     .gsd_ext_lp
.gsd_ext_lossy:
                LOADI   D0, #1
                STOREZB D0, [#GENSN_LOSSY]
                BRA     .gsd_ext_lp

.gsd_done:
                LOADZB  D0, [#GENSN_LOSSY]
                AND     D0, #$FF
                CLC
                RET


; ============================================================================
; _MapChar  -  map one (non-space, non-dot) name char to its 8.3 form.
;   In:  D0 = char.  Out: D0 = uppercased valid char, or '_' if illegal.
;        Sets GENSN_LOSSY=1 if it folded a lowercase letter or mapped to '_'.
;   Preserves D1, D2, D3, XY0, XY1, XY2, XY3.
; ============================================================================
_MapChar:
                CMP     D0, #'a'
                BLO     .mc_chk
                CMP     D0, #$7B                ; 'z' + 1
                BHS     .mc_chk
                ; lowercase: lossy, fold to uppercase
                PUSH    D0, XY3
                LOADI   D0, #1
                STOREZB D0, [#GENSN_LOSSY]
                POP     D0, XY3
                SUB     D0, #$20
                RET
.mc_chk:
                CALLR   _DirCharNormalise               ; C=0 valid, C=1 illegal
                BCC     .mc_ok
                LOADI   D0, #1
                STOREZB D0, [#GENSN_LOSSY]
                LOADI   D0, #'_'
.mc_ok:
                RET


; ============================================================================
; _GenShortTilde  -  build "BASE~N" 11-byte FAT name into LFN_SHORT.
;   In:  GENSN_SRC[0..10] = derived base+ext (space-padded); D2 = N (1..999).
;   Out: LFN_SHORT[0..10] = base-truncated + '~' + decimal(N) + ext.
;   Clobbers D0,D1,D2,D3,XY0,XY1. Preserves XY2,XY3.
; ============================================================================
_GenShortTilde:
                ; space-fill LFN_SHORT[0..10]
                LOADI   D1, #0
.gt_fill:
                CMP     D1, #11
                BHS     .gt_blen
                LOADI   D0, #' '
                LOADI   Y1, #$00
                LOADI   X1, #LFN_SHORT
                ADD     X1, D1
                STOREB  D0, [XY1]
                ADD     D1, #1
                BRA     .gt_fill

                ; blen = base length (stop at first space in GENSN_SRC[0..7])
.gt_blen:
                LOADI   D1, #0                  ; D1 = blen
.gt_blen_lp:
                CMP     D1, #8
                BHS     .gt_digits
                LOADI   Y0, #$00
                LOADI   X0, #GENSN_SRC
                ADD     X0, D1
                LOADB   D0, [XY0]
                AND     D0, #$FF
                CMP     D0, #' '
                BEQ     .gt_digits
                ADD     D1, #1
                BRA     .gt_blen_lp

                ; decimal digits of N (D2) -> TILDE_DIG, count in D3 (ndig)
.gt_digits:
                PUSH    D1, XY3                 ; save blen
                ; hundreds
                LOADI   D3, #0                  ; ndig
                ; h = N/100
                LOADI   D0, #0                  ; h
.gt_h:
                CMP     D2, #100
                BLO     .gt_h_done
                SUB     D2, #100
                ADD     D0, #1
                BRA     .gt_h
.gt_h_done:
                CMP     D0, #0
                BEQ     .gt_tens
                ADD     D0, #'0'
                LOADI   Y1, #$00
                LOADI   X1, #TILDE_DIG
                STOREB  D0, [XY1]
                ADD     D3, #1
.gt_tens:
                LOADI   D0, #0                  ; t
.gt_t:
                CMP     D2, #10
                BLO     .gt_t_done
                SUB     D2, #10
                ADD     D0, #1
                BRA     .gt_t
.gt_t_done:
                ; emit tens if t>0 OR we already have a digit
                CMP     D0, #0
                BNE     .gt_t_emit
                CMP     D3, #0
                BEQ     .gt_units               ; suppress leading zero
.gt_t_emit:
                PUSH    D0, XY3
                ADD     D0, #'0'
                LOADI   Y1, #$00
                LOADI   X1, #TILDE_DIG
                ADD     X1, D3
                STOREB  D0, [XY1]
                ADD     D3, #1
                POP     D0, XY3
.gt_units:
                ; units = remaining D2 (0..9), always emit
                MOVE    D0, D2
                ADD     D0, #'0'
                LOADI   Y1, #$00
                LOADI   X1, #TILDE_DIG
                ADD     X1, D3
                STOREB  D0, [XY1]
                ADD     D3, #1                  ; D3 = ndig

                ; keep = min(blen, 8 - (1 + ndig))
                POP     D1, XY3                 ; blen
                MOVE    D2, D3
                ADD     D2, #1                  ; tlen = 1 + ndig
                LOADI   D0, #8
                SUB     D0, D2                  ; avail = 8 - tlen
                ; keep = min(blen, avail) -> D1
                CMP     D1, D0
                BLO     .gt_keep_ok
                MOVE    D1, D0                  ; blen > avail -> keep = avail
.gt_keep_ok:
                ; copy base[0..keep-1] -> LFN_SHORT[0..keep-1]
                LOADI   D2, #0                  ; dest pos
.gt_copy_base:
                CMP     D2, D1
                BHS     .gt_tilde
                LOADI   Y0, #$00
                LOADI   X0, #GENSN_SRC
                ADD     X0, D2
                LOADB   D0, [XY0]
                LOADI   Y1, #$00
                LOADI   X1, #LFN_SHORT
                ADD     X1, D2
                STOREB  D0, [XY1]
                ADD     D2, #1
                BRA     .gt_copy_base
.gt_tilde:
                ; write '~' at LFN_SHORT[keep]
                LOADI   D0, #'~'
                LOADI   Y1, #$00
                LOADI   X1, #LFN_SHORT
                ADD     X1, D2
                STOREB  D0, [XY1]
                ADD     D2, #1                  ; dest pos now after '~'
                ; copy ndig digits
                LOADI   D1, #0                  ; digit index
.gt_copy_dig:
                CMP     D1, D3
                BHS     .gt_ext
                LOADI   Y0, #$00
                LOADI   X0, #TILDE_DIG
                ADD     X0, D1
                LOADB   D0, [XY0]
                LOADI   Y1, #$00
                LOADI   X1, #LFN_SHORT
                ADD     X1, D2
                STOREB  D0, [XY1]
                ADD     D1, #1
                ADD     D2, #1
                BRA     .gt_copy_dig
.gt_ext:
                ; copy ext GENSN_SRC[8..10] -> LFN_SHORT[8..10]
                LOADI   D1, #8
.gt_copy_ext:
                CMP     D1, #11
                BHS     .gt_done
                LOADI   Y0, #$00
                LOADI   X0, #GENSN_SRC
                ADD     X0, D1
                LOADB   D0, [XY0]
                LOADI   Y1, #$00
                LOADI   X1, #LFN_SHORT
                ADD     X1, D1
                STOREB  D0, [XY1]
                ADD     D1, #1
                BRA     .gt_copy_ext
.gt_done:
                RET


; ============================================================================
; _LfnChecksum  -  VFAT 8-bit checksum over an 11-byte short name.
;   In:  XY0 = 11-byte name (full pointer).   Out: D0 = checksum byte.
;   Clobbers D1,D2,D3. Preserves XY0,XY1,XY2,XY3.
; ============================================================================
_LfnChecksum:
                PUSH    XY0, XY3
                LOADI   D0, #0                  ; sum
                LOADI   D1, #0                  ; i
.lc_lp:
                CMP     D1, #11
                BHS     .lc_done
                MOVE    D2, D0
                SHR     D2                      ; sum >> 1
                MOVE    D3, D0
                AND     D3, #$01
                CMP     D3, #0
                BEQ     .lc_norot
                OR      D2, #$80
.lc_norot:
                MOVE    D3, D1
                LOADB   D3, [XY0+D3]
                AND     D3, #$FF
                ADD     D2, D3
                AND     D2, #$FF
                MOVE    D0, D2
                ADD     D1, #1
                BRA     .lc_lp
.lc_done:
                POP     XY0, XY3
                RET




; ============================================================================
; _GenShortName — generate a unique 11-byte short name for a path component.
;
;   In:    XY0 = component (ASCIIZ, full pointer)
;          XY2 = volume slot, D3 = drive, DIR_WALK_CLU = target directory
;   Out:   C=0: LFN_SHORT[0..10] = the chosen 11-byte FAT short name.
;               D0 = needs_lfn: 0 = faithful uppercase 8.3 (emit a plain short
;                    entry), 1 = an LFN run is required to preserve the name.
;          C=1: D0 = ERR_IO (probe failed) / ERR_NOSPACE (~1..~999 exhausted).
;   Clobbers: D0,D1,D2,X0,X1,flags.   Preserves: D3, XY2, XY3.
;
;   Clean path: a component that is already a valid 8.3 (modulo case) is used
;   verbatim, uppercased, with no numeric tail; needs_lfn is set only when the
;   original differs from pure upper. No collision probe — the caller's dup
;   check has already proved the name unique. Lossy path: derive a lossy 8.3,
;   then try BASE~1, BASE~2 … probing each with the 8.3-only _DirLookup until a
;   free slot turns up. Derive/tilde clobber D2 (=N) and D3 (=drive), so N is
;   stacked across each iteration and the drive is stashed in GENSN_DRV.
; ============================================================================
_GenShortName:
                STOREZB D3, [#GENSN_DRV]         ; stash drive (derive/tilde clobber D3)
                PUSH    XY0, XY3                ; keep component ptr
                LOADI   Y1, #$00
                LOADI   X1, #LFN_SHORT
                CALLR   _DirNameToFat            ; clean-8.3 test; uppercases into LFN_SHORT
                BCS     .gsn_lossy

                ; CLEAN 8.3: short = LFN_SHORT; needs_lfn = component has lowercase
                POP     XY0, XY3
                CALLR   _HasLower                ; D0 = 0/1 ; preserves D3
                LOADZB  D3, [#GENSN_DRV]
                AND     D3, #$FF
                CLC
                RET

.gsn_lossy:
                POP     XY0, XY3
                CALLR   _GenShortDerive          ; XY0 -> GENSN_SRC (lossy 8.3); clobbers D3
                LOADI   D2, #1                   ; N
.gsn_tl_loop:
                PUSH    D2, XY3                  ; save N (tilde clobbers D2 and D3)
                CALLR   _GenShortTilde           ; GENSN_SRC + D2 -> LFN_SHORT
                LOADZB  D3, [#GENSN_DRV]         ; restore drive for the probe
                AND     D3, #$FF
                LOADI   Y0, #$00
                LOADI   X0, #LFN_SHORT
                CALLR   _DirLookup               ; XY2 slot, D3 drive, DIR_WALK_CLU dir
                BCC     .gsn_collide             ; C=0 found -> collision, try next N
                CMP     D0, #ERR_IO
                BEQ     .gsn_io
                ; C=1 ERR_NOTFOUND -> candidate is free
                POP     D2, XY3
                LOADZB  D3, [#GENSN_DRV]
                AND     D3, #$FF
                LOADI   D0, #1                   ; a lossy name always needs an LFN run
                CLC
                RET
.gsn_collide:
                POP     D2, XY3
                ADD     D2, #1
                CMP     D2, #1000                ; cap at ~999
                BLO     .gsn_tl_loop
                LOADZB  D3, [#GENSN_DRV]
                AND     D3, #$FF
                LOADI   D0, #ERR_NOSPACE
                SEC
                RET
.gsn_io:
                POP     D2, XY3
                LOADZB  D3, [#GENSN_DRV]
                AND     D3, #$FF
                LOADI   D0, #ERR_IO
                SEC
                RET


; ============================================================================
; _HasLower — D0 = 1 if the ASCIIZ string at XY0 contains any a..z, else 0.
;   Clobbers: D0, flags.   Preserves: D1, D2, D3, XY1, XY2, XY3 (and XY0).
; ============================================================================
_HasLower:
                PUSH    XY0, XY3
.hl_loop:
                LOADB   D0, [XY0]+
                AND     D0, #$FF
                CMP     D0, #0
                BEQ     .hl_no
                CMP     D0, #'a'
                BLO     .hl_next
                CMP     D0, #$7B                 ; 'z' + 1
                BHS     .hl_next
                POP     XY0, XY3
                LOADI   D0, #1
                RET
.hl_next:
                BRA     .hl_loop
.hl_no:
                POP     XY0, XY3
                LOADI   D0, #0
                RET


; ============================================================================
; _LfnAccum — fold one VFAT LFN fragment at [XY1] into the LFN_ASM buffer.
;
;   LFN fragments are visited in on-disk order (highest sequence first, with
;   the $40 LAST flag), descending to ordinal 1, immediately before the short
;   entry. We place each fragment's 13 UTF-16LE chars at LFN_ASM[(ord-1)*13].
;   Run state lives in page $00: LFN_EXP_SEQ ($0000 idle / $FFFF broken /
;   $8000 complete-pending-short / 1..N next expected ordinal) and LFN_EXP_SUM.
;
;   Rejection (→ run marked broken → 8.3 fallback): ordinal 0 or >3, wrong
;   ordinal, checksum disagreement between fragments, a non-ASCII (high byte
;   != 0) char, or a char index that would exceed LFN_MAX.
;
;   In:    XY1 = raw 32-byte LFN entry (attr already confirmed = $0F)
;   Preserves: D0, D3, XY1, XY2, XY3.   Clobbers: D1, D2, XY0, flags.
; ============================================================================
_LfnAccum:
                PUSH    D0, XY3                 ; save cookie (D0 free as scratch)
                PUSH    D3, XY3                 ; D3 = running dest index

                LOADB   D1, [XY1]               ; sequence byte
                AND     D1, #$FF

                MOVE    D2, D1
                AND     D2, #LFN_LAST_FLAG
                CMP     D2, #0
                BEQ     .acc_seq_check          ; not a $40 (run-start) fragment

                ; ---- $40 fragment: start a fresh run --------------------
                MOVE    D2, D1
                AND     D2, #LFN_SEQ_MASK       ; ordinal
                CMP     D2, #0
                BEQ     .acc_break              ; ordinal 0 illegal
                CMP     D2, #3
                BHI     .acc_break              ; >3 fragments => > LFN_MAX
                STOREZ  D2, [#LFN_EXP_SEQ]      ; expected = this ordinal
                LOADI   D2, #$0D
                LOADB   D2, [XY1+D2]            ; checksum byte
                AND     D2, #$FF
                STOREZ  D2, [#LFN_EXP_SUM]
                ; zero-fill LFN_ASM (32 bytes) for a clean assembly
                LOADI   Y0, #$00
                LOADI   X0, #LFN_ASM
                LOADI   D2, #32
.acc_zero:
                LOADI   D1, #0
                STOREB  D1, [XY0]+
                SUB     D2, #1
                BNE     .acc_zero
                BRA     .acc_place

.acc_seq_check:
                ; Non-$40 fragment. Run must be active and ordinal must match.
                LOADZ   D2, [#LFN_EXP_SEQ]
                CMP     D2, #$8000
                BHS     .acc_break              ; $8000 complete / $FFFF broken
                ; D2 = expected (1..N, or $0000 idle). Compare to this ordinal.
                MOVE    D0, D1
                AND     D0, #LFN_SEQ_MASK
                CMP     D0, D2
                BNE     .acc_break              ; wrong/orphan ordinal (idle => 0)
                ; checksum must agree with the captured run checksum
                LOADI   D0, #$0D
                LOADB   D0, [XY1+D0]
                AND     D0, #$FF
                LOADZ   D2, [#LFN_EXP_SUM]
                AND     D2, #$FF
                CMP     D0, D2
                BNE     .acc_break
                ; fall through to placement

.acc_place:
                ; base = (ordinal-1)*13  -> D1, then dest ptr XY0 + idx D3.
                LOADB   D1, [XY1]
                AND     D1, #LFN_SEQ_MASK
                SUB     D1, #1                  ; ordinal-1 (0..2)
                MOVE    D0, D1                  ; t
                SHL     D1                      ; *2
                SHL     D1                      ; *4
                MOVE    D2, D1                  ; *4
                SHL     D1                      ; *8
                ADD     D1, D2                  ; *12
                ADD     D1, D0                  ; *13 = base
                MOVE    D3, D1                  ; dest index = base
                LOADI   Y0, #$00
                LOADI   X0, #LFN_ASM
                ADD     X0, D1                  ; XY0 = LFN_ASM + base
                LOADI   D1, #0                  ; k = 0
.acc_loop:
                CMP     D1, #13
                BHS     .acc_advance            ; all 13 char slots done
                ; source byte offset for char k -> D2 (5 / 6 / 2 split)
                CMP     D1, #5
                BLO     .acc_r1
                CMP     D1, #11
                BLO     .acc_r2
                MOVE    D2, D1                  ; region 3: off = 28 + (k-11)*2
                SUB     D2, #11
                SHL     D2
                ADD     D2, #28
                BRA     .acc_read
.acc_r1:
                MOVE    D2, D1                  ; region 1: off = 1 + k*2
                SHL     D2
                ADD     D2, #1
                BRA     .acc_read
.acc_r2:
                MOVE    D2, D1                  ; region 2: off = 14 + (k-5)*2
                SUB     D2, #5
                SHL     D2
                ADD     D2, #14
.acc_read:
                LOADB   D0, [XY1+D2]            ; lo byte
                AND     D0, #$FF
                ADD     D2, #1
                PUSH    D0, XY3                 ; stash lo
                LOADB   D2, [XY1+D2]            ; hi byte
                AND     D2, #$FF
                CMP     D2, #0
                BNE     .acc_hi_nonzero
                POP     D0, XY3                 ; lo back
                CMP     D0, #0
                BEQ     .acc_advance            ; lo==0 & hi==0 => terminator
                BRA     .acc_store
.acc_hi_nonzero:
                POP     D0, XY3                 ; drop lo
                BRA     .acc_break              ; non-ASCII => reject run
.acc_store:
                CMP     D3, #LFN_MAX
                BHS     .acc_break              ; would exceed 31 chars => reject
                STOREB  D0, [XY0]+
                ADD     D3, #1                  ; dest index++
                ADD     D1, #1                  ; k++
                BRA     .acc_loop

.acc_advance:
                ; Placed this fragment. Advance the expected-ordinal state.
                LOADB   D1, [XY1]
                AND     D1, #LFN_SEQ_MASK
                CMP     D1, #1
                BNE     .acc_dec
                LOADI   D1, #$8000              ; reached ordinal 1 => complete
                STOREZ  D1, [#LFN_EXP_SEQ]
                BRA     .acc_ret
.acc_dec:
                SUB     D1, #1                  ; expect ordinal-1 next
                STOREZ  D1, [#LFN_EXP_SEQ]
.acc_ret:
                POP     D3, XY3
                POP     D0, XY3
                RET
.acc_break:
                LOADI   D1, #$FFFF
                STOREZ  D1, [#LFN_EXP_SEQ]      ; mark run broken
                POP     D3, XY3
                POP     D0, XY3
                RET


; ============================================================================
; _LfnFinal — validate the accumulated run against the short entry at [XY1].
;
;   If a complete run is pending ($8000) and the VFAT checksum recomputed over
;   the short entry's 11-byte name matches the captured run checksum, set
;   LFN_ASM_LEN = strlen(LFN_ASM) (capped at LFN_MAX). Otherwise leave
;   LFN_ASM_LEN = 0 (caller falls back to the 8.3 name).
;
;   In:    XY1 = short directory entry (11-byte name at +$00)
;   Preserves: D0, D3, XY1, XY2, XY3.   Clobbers: D1, D2, XY0, flags.
; ============================================================================
_LfnFinal:
                PUSH    D0, XY3
                PUSH    D3, XY3

                LOADI   D1, #0
                STOREZ  D1, [#LFN_ASM_LEN]      ; default: no long name

                LOADZ   D2, [#LFN_EXP_SEQ]
                CMP     D2, #$8000
                BNE     .fin_done               ; not a completed run

                ; checksum over the 11-byte short name (8-bit rotate-right add)
                LOADI   D0, #0                  ; sum
                LOADI   D1, #0                  ; i
.fin_csum:
                CMP     D1, #11
                BHS     .fin_csum_done
                MOVE    D2, D0
                SHR     D2                      ; sum >> 1 (logical)
                MOVE    D3, D0
                AND     D3, #$01
                CMP     D3, #0
                BEQ     .fin_norot
                OR      D2, #$80                ; rotate low bit into bit7
.fin_norot:
                MOVE    D3, D1                  ; i -> offset
                LOADB   D3, [XY1+D3]            ; name[i]
                AND     D3, #$FF
                ADD     D2, D3
                AND     D2, #$FF
                MOVE    D0, D2                  ; sum = (rot + name[i]) & $FF
                ADD     D1, #1
                BRA     .fin_csum
.fin_csum_done:
                LOADZ   D2, [#LFN_EXP_SUM]
                AND     D2, #$FF
                CMP     D0, D2
                BNE     .fin_done               ; checksum mismatch => 8.3

                ; length = strlen(LFN_ASM), capped at LFN_MAX
                LOADI   Y0, #$00
                LOADI   X0, #LFN_ASM
                LOADI   D1, #0
.fin_len:
                CMP     D1, #LFN_MAX
                BHS     .fin_len_done
                LOADB   D0, [XY0]+
                AND     D0, #$FF
                CMP     D0, #0
                BEQ     .fin_len_done
                ADD     D1, #1
                BRA     .fin_len
.fin_len_done:
                STOREZ  D1, [#LFN_ASM_LEN]
.fin_done:
                POP     D3, XY3
                POP     D0, XY3
                RET




; ============================================================================
; _FormatLfnFragment — build one 32-byte on-disk VFAT LFN entry in LFN_FRAG.
;
;   The exact inverse of _LfnAccum: it places 13 characters taken from
;   LFN_ASM[(ordinal-1)*13 ..] across the same 5/6/2 byte-offset split, writes
;   the attr=$0F / type=0 / checksum / zero-cluster fixed fields, and terminates
;   the name with a $0000 word followed by $FFFF padding for the remaining char
;   slots of the fragment. (When the name exactly fills the fragment there is no
;   in-fragment terminator, matching _LfnAccum's zero-fill-derived strlen.)
;
;   In:    D0 = ordinal (1..N)   D1 = is_last (0/1)   D2 = checksum byte
;          LFN_ASM = long name (ASCIIZ), LFN_ASM_LEN = length
;   Out:   LFN_FRAG[0..31] = the on-disk LFN entry, ready to write
;   Clobbers: D0, D1, D2, D3, X0, X1, flags.   Preserves: XY2, XY3.
;
;   NOTE: LFN_FRAG overlays the short-name generator scratch (GENSN_*), so this
;   must run AFTER _GenShortName has finished (the short name is already staged
;   in LFN_SHORT before any fragment is formatted).
; ============================================================================
_FormatLfnFragment:
                ; --- sequence byte at $00 = ordinal | (is_last ? $40 : 0) ---
                PUSH    D0, XY3                 ; save ordinal for the base calc
                CMP     D1, #0
                BEQ     .ff_noflag
                OR      D0, #LFN_LAST_FLAG
.ff_noflag:
                LOADI   Y1, #$00
                LOADI   X1, #LFN_FRAG
                STOREB  D0, [XY1]               ; [$00] sequence

                ; --- fixed fields -----------------------------------------
                LOADI   D0, #$0F
                LOADI   X1, #LFN_FRAG+11        ; [$0B] attr = $0F (LFN)
                STOREB  D0, [XY1]
                LOADI   D0, #$00
                LOADI   X1, #LFN_FRAG+12        ; [$0C] type = 0
                STOREB  D0, [XY1]
                MOVE    D0, D2
                LOADI   X1, #LFN_FRAG+13        ; [$0D] checksum
                STOREB  D0, [XY1]
                LOADI   D0, #$00
                LOADI   X1, #LFN_FRAG+26        ; [$1A] first-cluster lo = 0
                STOREB  D0, [XY1]
                LOADI   X1, #LFN_FRAG+27        ; [$1B] first-cluster hi = 0
                STOREB  D0, [XY1]

                ; --- base = (ordinal - 1) * 13  -> D3 ----------------------
                POP     D0, XY3                 ; ordinal
                SUB     D0, #1
                MOVE    D3, D0
                SHL     D3
                SHL     D3                      ; *4
                MOVE    D2, D3                  ; *4
                SHL     D3                      ; *8
                ADD     D3, D2                  ; *12
                ADD     D3, D0                  ; *13 = base

                ; --- place 13 chars (k = 0..12) ---------------------------
                LOADI   D1, #0                  ; k
.ff_loop:
                CMP     D1, #13
                BHS     .ff_done
                ; dest byte offset for char k -> D2  (5 / 6 / 2 region split,
                ; identical to _LfnAccum's source offsets)
                CMP     D1, #5
                BLO     .ff_o1
                CMP     D1, #11
                BLO     .ff_o2
                MOVE    D2, D1                  ; region 3: 28 + (k-11)*2
                SUB     D2, #11
                SHL     D2
                ADD     D2, #28
                BRA     .ff_dest
.ff_o1:
                MOVE    D2, D1                  ; region 1: 1 + k*2
                SHL     D2
                ADD     D2, #1
                BRA     .ff_dest
.ff_o2:
                MOVE    D2, D1                  ; region 2: 14 + (k-5)*2
                SUB     D2, #5
                SHL     D2
                ADD     D2, #14
.ff_dest:
                LOADI   Y1, #$00
                LOADI   X1, #LFN_FRAG
                ADD     X1, D2                  ; XY1 = dest (lo byte slot)
                ; g = base + k
                MOVE    D0, D3
                ADD     D0, D1                  ; D0 = g
                LOADZ   D2, [#LFN_ASM_LEN]
                CMP     D0, D2
                BLO     .ff_real
                BEQ     .ff_term
                ; g > len -> $FFFF padding
                LOADI   D0, #$FF
                STOREB  D0, [XY1]
                ADD     X1, #1
                LOADI   D0, #$FF
                STOREB  D0, [XY1]
                BRA     .ff_next
.ff_real:
                ; lo = LFN_ASM[g], hi = 0
                LOADI   Y0, #$00
                LOADI   X0, #LFN_ASM
                ADD     X0, D0
                LOADB   D0, [XY0]
                AND     D0, #$FF
                STOREB  D0, [XY1]
                ADD     X1, #1
                LOADI   D0, #$00
                STOREB  D0, [XY1]
                BRA     .ff_next
.ff_term:
                ; $0000 terminator word
                LOADI   D0, #$00
                STOREB  D0, [XY1]
                ADD     X1, #1
                STOREB  D0, [XY1]
.ff_next:
                ADD     D1, #1
                BRA     .ff_loop
.ff_done:
                RET


; ============================================================================
; _LongMatchCI — case-insensitive compare of RV_COMP vs LFN_ASM (both ASCIIZ).
;
;   Folds a..z -> A..Z on both sides; a match requires equality up to a mutual
;   nul terminator. Used by _DirLookupLong once a valid long name has been
;   assembled for the current short entry.
;
;   In:    reads page-$00 RV_COMP (target) and LFN_ASM (assembled long name)
;   Out:   C=0 match / C=1 no match
;   Clobbers: D0, X0, Y0, X1, Y1, flags.   Preserves: D1, D2, D3, XY1, XY2, XY3.
; ============================================================================
_LongMatchCI:
                PUSH    D1, XY3
                PUSH    D2, XY3
                PUSH    XY1, XY3                ; caller's entry ptr — restored at exit
                LOADI   D2, #0                  ; i
.lm_loop:
                ; a = fold(RV_COMP[i])
                LOADI   Y0, #$00
                LOADI   X0, #RV_COMP
                ADD     X0, D2
                LOADB   D0, [XY0]
                AND     D0, #$FF
                CMP     D0, #'a'
                BLO     .lm_a_done
                CMP     D0, #$7B                ; 'z' + 1
                BHS     .lm_a_done
                SUB     D0, #$20
.lm_a_done:
                ; b = fold(LFN_ASM[i])
                LOADI   Y1, #$00
                LOADI   X1, #LFN_ASM
                ADD     X1, D2
                LOADB   D1, [XY1]
                AND     D1, #$FF
                CMP     D1, #'a'
                BLO     .lm_b_done
                CMP     D1, #$7B
                BHS     .lm_b_done
                SUB     D1, #$20
.lm_b_done:
                CMP     D0, D1
                BNE     .lm_no
                CMP     D0, #0
                BEQ     .lm_yes                 ; both nul -> full match
                ADD     D2, #1
                BRA     .lm_loop
.lm_yes:
                POP     XY1, XY3
                POP     D2, XY3
                POP     D1, XY3
                CLC
                RET
.lm_no:
                POP     XY1, XY3
                POP     D2, XY3
                POP     D1, XY3
                SEC
                RET


; ============================================================================
; _DirLookupLong — find a directory entry by LONG name (with 8.3 fallback).
;
;   Mirrors _DirLookup's sector/entry scan, but instead of skipping LFN ($0F)
;   entries it accumulates them (via _LfnAccum); on each short entry it runs
;   _LfnFinal and, if a valid long name assembled, compares it case-insensitively
;   against RV_COMP. Falling back, when RV_SAVE_PAD=1, it compares the entry's
;   11-byte 8.3 name against RV_FATNAME. The 8.3-only _DirLookup is left intact
;   for _DirDelete and the (45.5) short-name collision scan.
;
;   In:    XY2 = volume slot ptr
;          D3  = drive index
;          DIR_WALK_CLU = directory cluster (0 = root region)
;          RV_COMP      = target component (ASCIIZ)
;          RV_FATNAME   = its 8.3 form (only read when RV_SAVE_PAD = 1)
;          RV_SAVE_PAD  = 1 if RV_FATNAME holds a usable 8.3 form, else 0
;   Out:   C=0 with D0 = cookie at the matched short entry; FS_BUF_SECTOR holds
;            that sector. C=1 with D0 = ERR_NOTFOUND / ERR_IO.
;   Clobbers: D0, D1, D2, X0, X1, flags.   Preserves: D3, XY2, XY3.
; ============================================================================
_DirLookupLong:
                PUSH    D3, XY3                 ; preserve drive for caller
                ; reset LFN run state for a fresh scan
                LOADI   D0, #0
                STOREZ  D0, [#LFN_EXP_SEQ]
                STOREZ  D0, [#LFN_ASM_LEN]

                LOADI   D1, #0                  ; sec_off = 0
.dll_sec_loop:
                LOADZ   D0, [#DIR_WALK_CLU]
                CMP     D0, #0
                BNE     .dll_subdir_sector

                ; ===== ROOT REGION =====
                LOADD   D0, [XY2+#VOL_ROOT_ENTRIES]
                ADD     D0, #15
                SHR4    D0
                CMP     D1, D0
                BHS     .dll_notfound
                LOADD   D0, [XY2+#VOL_ROOT_START]
                ADD     D0, D1
                BRA     .dll_have_sector

                ; ===== SUBDIR: walk chain sec_off links =====
.dll_subdir_sector:
                PUSH    D1, XY3                 ; [W] sec_off
                LOADZ   D2, [#DIR_WALK_CLU]
.dll_walk:
                CMP     D1, #0
                BEQ     .dll_walk_done
                PUSH    D1, XY3                 ; [V] counter across call
                MOVE    D0, D2
                CALLR   _FATGetEntry
                POP     D1, XY3                 ; [V]
                BCS     .dll_walk_io
                CMP     D0, #FAT_BAD
                BEQ     .dll_walk_io
                CMP     D0, #FAT_EOC_MIN
                BHS     .dll_walk_eoc
                MOVE    D2, D0
                SUB     D1, #1
                BRA     .dll_walk
.dll_walk_done:
                MOVE    D0, D2
                CALLR   _ClusterToSector
                BCS     .dll_walk_io
                POP     D1, XY3                 ; [W] restore sec_off

.dll_have_sector:
                PUSH    D1, XY3                 ; sec_off across the I/O
                LOADZ   D2, [#DIR_CACHE_SECTOR]
                CMP     D2, D0
                BNE     .dll_must_read
                LOADZB  D2, [#DIR_CACHE_DRIVE]
                CMP     D2, D3
                BEQ     .dll_cache_hit
.dll_must_read:
                STOREZ  D0, [#DIR_CACHE_SECTOR]
                STOREZB D3, [#DIR_CACHE_DRIVE]
                LOADI   Y0, #$00
                LOADI   X0, #FS_BUF_SECTOR
                CALLR   _VolBlockRead
                BCS     .dll_io_err
.dll_cache_hit:
                POP     D1, XY3                 ; restore sec_off

                LOADI   D2, #0                  ; ent_idx
.dll_ent_loop:
                MOVE    D0, D2
                SHL4    D0
                SHL     D0
                ADD     D0, #FS_BUF_SECTOR
                LOADI   Y1, #$00
                MOVE    X1, D0                  ; XY1 = entry address

                LOADB   D0, [XY1]
                AND     D0, #$FF
                CMP     D0, #DIR_FREE_END
                BEQ     .dll_notfound           ; $00 sentinel -> done
                CMP     D0, #DIR_FREE_REUSABLE
                BEQ     .dll_break_skip         ; deleted -> break run + skip

                LOADI   D0, #DIR_ATTR
                LOADB   D0, [XY1+D0]
                AND     D0, #$FF
                CMP     D0, #DIR_ATTR_LFN
                BEQ     .dll_lfn
                AND     D0, #DIR_ATTR_VOLUME_LABEL
                BNE     .dll_break_skip         ; volume label -> break run + skip

                ; ---- short entry: finalize the run, try long then 8.3 ----
                PUSH    D1, XY3                 ; save sec_off
                PUSH    D2, XY3                 ; save ent_idx
                CALLR   _LfnFinal               ; XY1=entry; sets LFN_ASM_LEN; preserves XY1
                POP     D2, XY3
                POP     D1, XY3

                LOADZ   D0, [#LFN_ASM_LEN]
                CMP     D0, #0
                BEQ     .dll_try83              ; no long name -> 8.3 only
                CALLR   _LongMatchCI            ; preserves D1, D2, XY1
                BCC     .dll_found              ; long name matched
.dll_try83:
                LOADZB  D0, [#RV_SAVE_PAD]
                AND     D0, #$FF
                CMP     D0, #0
                BEQ     .dll_short_done         ; no 8.3 form to compare
                ; compare 11 bytes: RV_FATNAME vs entry name at [XY1]
                LOADI   Y0, #$00
                LOADI   X0, #RV_FATNAME
                PUSH    D1, XY3                 ; save sec_off
                PUSH    D2, XY3                 ; save ent_idx
                LOADI   D1, #11
.dll_cmp83:
                LOADB   D0, [XY0]+
                AND     D0, #$FF
                LOADB   D2, [XY1]+
                AND     D2, #$FF
                CMP     D0, D2
                BNE     .dll_cmp83_no
                SUB     D1, #1
                BNE     .dll_cmp83
                POP     D2, XY3                 ; 8.3 match
                POP     D1, XY3
                BRA     .dll_found
.dll_cmp83_no:
                POP     D2, XY3
                POP     D1, XY3
                ; fall through to short_done

.dll_short_done:
                ; run belongs to this short entry only — reset before continuing
                LOADI   D0, #0
                STOREZ  D0, [#LFN_EXP_SEQ]
                STOREZ  D0, [#LFN_ASM_LEN]
                BRA     .dll_skip

.dll_lfn:
                PUSH    D1, XY3                 ; save sec_off
                PUSH    D2, XY3                 ; save ent_idx
                CALLR   _LfnAccum               ; XY1=entry; preserves XY1
                POP     D2, XY3
                POP     D1, XY3
                BRA     .dll_skip

.dll_break_skip:
                LOADI   D0, #0
                STOREZ  D0, [#LFN_EXP_SEQ]
                STOREZ  D0, [#LFN_ASM_LEN]
                ; fall through

.dll_skip:
                ADD     D2, #1
                CMP     D2, #16
                BLO     .dll_ent_loop
                ADD     D1, #1
                BRA     .dll_sec_loop

.dll_found:
                ; cookie = (sec_off << 4) | ent_idx ; D1 = sec_off, D2 = ent_idx
                MOVE    D0, D1
                SHL4    D0
                OR      D0, D2
                POP     D3, XY3
                RETCC

.dll_notfound:
                POP     D3, XY3
                LOADI   D0, #ERR_NOTFOUND
                SEC
                RET

.dll_io_err:
                LOADI   D0, #FAT_CACHE_INVALID
                STOREZ  D0, [#DIR_CACHE_SECTOR]
                POP     D1, XY3                 ; discard sec_off
                POP     D3, XY3
                LOADI   D0, #ERR_IO
                SEC
                RET

.dll_walk_io:
                POP     D1, XY3                 ; discard sec_off [W]
                POP     D3, XY3
                LOADI   D0, #ERR_IO
                SEC
                RET

.dll_walk_eoc:
                POP     D1, XY3                 ; discard sec_off [W]
                POP     D3, XY3
                LOADI   D0, #ERR_NOTFOUND
                SEC
                RET


; ============================================================================
; _CopyCompToLfnAsm — stage the resolved long leaf for the LFN writer.
;
;   Copies RV_COMP (ASCIIZ) -> LFN_ASM and sets LFN_ASM_LEN = char count
;   (excluding the nul). _RvExtractComponent caps RV_COMP at 31 chars, so the
;   31-char + nul result always fits LFN_ASM's 32 bytes.
;
;   In:    (RV_COMP holds the leaf component)
;   Out:   LFN_ASM = nul-terminated copy; LFN_ASM_LEN = length.
;   Clobbers: D0, D1, X0, X1, flags.   Preserves: D2, D3, XY2, XY3.
; ============================================================================
_CopyCompToLfnAsm:
                LOADI   Y0, #$00
                LOADI   X0, #RV_COMP
                LOADI   Y1, #$00
                LOADI   X1, #LFN_ASM
                LOADI   D1, #0                   ; char count
.ccla_loop:
                LOADB   D0, [XY0]
                AND     D0, #$FF
                STOREB  D0, [XY1]                ; copy (incl. the nul)
                CMP     D0, #0
                BEQ     .ccla_done
                ADD     X0, #1
                ADD     X1, #1
                ADD     D1, #1
                BRA     .ccla_loop
.ccla_done:
                STOREZ  D1, [#LFN_ASM_LEN]
                RET


; ============================================================================
; _DirFindRun — find `needed` contiguous free slots within ONE directory sector.
;
;   Single-sector placement: an LFN run is at most 4 entries (<=3 fragments + 1
;   short), so it is kept inside one 16-entry sector and written with a single
;   read-modify-write. Free slots are $E5 (deleted) or $00 (end-of-dir tail);
;   the run must satisfy ent_idx + needed <= 16. (A non-straddling run is still
;   a valid, Windows-readable directory.)
;
;   In:    D0 = needed (1..16)   XY2 = slot   D3 = drive
;          DIR_WALK_CLU = directory cluster (0 = root region)
;   Out:   C=0 with D1 = sec_off, D2 = ent_idx of the run start; the run's
;            sector is left in FS_BUF_SECTOR.
;          C=1 with D0 = ERR_NOSPACE (no run fits) / ERR_IO.
;   Clobbers: D0, D1, D2, X0, X1, flags.   Preserves: D3, XY2, XY3.
;
;   Slot scratch: $36 = needed (byte), $38 = sec_off (word). Does NOT touch the
;   $30..$35 meta stash, so a _DirCreateRun caller's metadata survives.
; ============================================================================
_DirFindRun:
                MOVE    X1, X2                  ; stash needed at slot+$36
                ADD     X1, #$36
                MOVE    Y1, Y2
                STOREB  D0, [XY1]

                LOADI   D1, #0                  ; sec_off
.dfr_sec:
                MOVE    X1, X2                  ; stash sec_off at slot+$38
                ADD     X1, #$38
                MOVE    Y1, Y2
                STORED  D1, [XY1]

                CALLR   _DirSecToAbs            ; D1=sec_off -> D0=abs; preserves D1,D3
                BCS     .dfr_nospace            ; ERR_NOMORE/ERR_IO past end -> no room
                PUSH    D1, XY3                 ; sec_off across the read
                LOADI   Y0, #$00
                LOADI   X0, #FS_BUF_SECTOR
                CALLR   _VolBlockRead
                BCS     .dfr_io_pop1
                POP     D1, XY3

                ; scan 16 entries for `needed` consecutive free
                LOADI   D1, #0                  ; e (entry index 0..15)
                LOADI   D2, #0                  ; run_len
.dfr_ent:
                MOVE    D0, D1                  ; entry addr = FS_BUF_SECTOR + e*32
                SHL4    D0
                SHL     D0
                ADD     D0, #FS_BUF_SECTOR
                LOADI   Y1, #$00
                MOVE    X1, D0
                LOADB   D0, [XY1]
                AND     D0, #$FF
                CMP     D0, #DIR_FREE_REUSABLE
                BEQ     .dfr_free
                CMP     D0, #DIR_FREE_END
                BEQ     .dfr_free
                LOADI   D2, #0                  ; used -> reset run
                BRA     .dfr_next
.dfr_free:
                ADD     D2, #1                  ; run_len++
                MOVE    X1, X2                  ; reload needed
                ADD     X1, #$36
                MOVE    Y1, Y2
                LOADB   D0, [XY1]
                AND     D0, #$FF
                CMP     D2, D0
                BLO     .dfr_next               ; run not long enough yet
                ; found: ent_idx = e - (needed-1) = D1 - (D0-1)
                SUB     D0, #1                  ; needed-1
                MOVE    D2, D1                  ; e
                SUB     D2, D0                  ; ent_idx = e-(needed-1)
                MOVE    X1, X2                  ; sec_off from slot+$38 -> D1
                ADD     X1, #$38
                MOVE    Y1, Y2
                LOADD   D1, [XY1]
                CLC
                RET
.dfr_next:
                ADD     D1, #1                  ; e++
                CMP     D1, #16
                BLO     .dfr_ent

                ; --- seal the abandoned tail run --------------------------
                ; This sector did not hold `needed` consecutive free slots,
                ; so we are about to place the run in a LATER sector.  D2 =
                ; the length of the free run that ends at entry 15 (a run can
                ; only be cut short here by the sector boundary).  Any entry
                ; in that tail whose first byte is $00 is the end-of-directory
                ; sentinel: leaving it in place strands everything written
                ; beyond it - _DirNext stops dead at the first $00, so the new
                ; entry is invisible to ls AND to the _DirLookupLong that
                ; _CreateEmptyEntry runs to recover the cookie, which then
                ; reports ERR_NOTFOUND for a create that actually succeeded.
                ; Stamp $00 -> $E5 (deleted-but-reusable, which _DirNext walks
                ; through) and write the sector back.  Same invariant
                ; _DirGrowChain preserves when it links a new cluster.
                CMP     D2, #0
                BEQ     .dfr_adv                ; tail not free - nothing to seal
                LOADI   D0, #16
                SUB     D0, D2                  ; D0 = e, first entry of the tail run
                LOADI   D2, #0                  ; D2 = dirty flag
.dfr_seal_loop:
                CMP     D0, #16
                BHS     .dfr_seal_wb
                PUSH    D0, XY3                 ; save e across the probe
                SHL4    D0
                SHL     D0                      ; e*32
                ADD     D0, #FS_BUF_SECTOR
                LOADI   Y1, #$00
                MOVE    X1, D0
                LOADB   D0, [XY1]
                AND     D0, #$FF
                CMP     D0, #DIR_FREE_END
                BNE     .dfr_seal_next          ; already $E5 - leave it
                LOADI   D0, #DIR_FREE_REUSABLE
                STOREB  D0, [XY1]
                LOADI   D2, #1                  ; sector modified
.dfr_seal_next:
                POP     D0, XY3                 ; e
                ADD     D0, #1
                BRA     .dfr_seal_loop
.dfr_seal_wb:
                CMP     D2, #0
                BEQ     .dfr_adv                ; no $00 found - no write needed
                ; Write this sector back before moving on.  sec_off is still
                ; at slot+$38; _DirSecToAbs preserves D1 and D3.
                MOVE    X1, X2
                ADD     X1, #$38
                MOVE    Y1, Y2
                LOADD   D1, [XY1]               ; D1 = sec_off (this sector)
                CALLR   _DirSecToAbs            ; D0 = abs sector
                BCS     .dfr_seal_err
                LOADI   Y0, #$00
                LOADI   X0, #FS_BUF_SECTOR
                CALLR   _VolBlockWrite          ; D0=sector, XY0=buf, XY2=slot
                BCS     .dfr_seal_err

.dfr_adv:
                ; next sector
                MOVE    X1, X2                  ; reload sec_off, ++ 
                ADD     X1, #$38
                MOVE    Y1, Y2
                LOADD   D1, [XY1]
                ADD     D1, #1
                BRA     .dfr_sec

.dfr_seal_err:
                ; D0 = ERR_* from _DirSecToAbs / _VolBlockWrite.
                SEC
                RET
.dfr_nospace:
                ; Ran off the end of the directory. For a SUBDIR whose chain
                ; simply ended (ERR_NOMORE, not a real ERR_IO), grow it by one
                ; cluster and retry the same sec_off — the fresh cluster has a
                ; full sector of free slots, so the run fits.
                CMP     D0, #ERR_NOMORE
                BNE     .dfr_nospace_final
                LOADZ   D0, [#DIR_WALK_CLU]
                CMP     D0, #0
                BEQ     .dfr_nospace_final       ; root region cannot grow
                CALLR   _DirGrowChain
                BCS     .dfr_grow_fail           ; D0 = ERR_NOSPACE/IO/READONLY
                MOVE    X1, X2                   ; reload sec_off (slot+$38) and rescan
                ADD     X1, #$38
                MOVE    Y1, Y2
                LOADD   D1, [XY1]
                BRA     .dfr_sec
.dfr_grow_fail:
                SEC
                RET
.dfr_nospace_final:
                LOADI   D0, #ERR_NOSPACE
                SEC
                RET
.dfr_io_pop1:
                POP     D1, XY3                 ; discard sec_off; D0 = ERR_IO
                SEC
                RET


; ============================================================================
; _DirCreateRun — create a directory entry with an LFN run (>=1 fragment).
;
;   Writes nfrags LFN fragments (highest ordinal first) immediately followed by
;   the short entry, all within one sector. The single-entry _DirCreate is used
;   for the no-LFN case; this routine handles needs_lfn == 1.
;
;   In:    D0 = attr   D1 = first cluster   D2 = size-low word
;          XY2 = slot   D3 = drive   DIR_WALK_CLU = target directory
;          LFN_SHORT = 11-byte short name (from _GenShortName)
;          LFN_ASM   = the long name (ASCIIZ), LFN_ASM_LEN = its length
;   Out:   C=0 success; C=1 with D0 = ERR_NOSPACE / ERR_IO / ERR_READONLY.
;   Clobbers: D0, D1, D2, X0, X1, flags.   Preserves: D3, XY2, XY3.
;
;   Slot scratch: $30..$35 meta (for _DicFormatShortEntry), $37 drive,
;   $3A csum, $3B nfrags, $3C sec_off (word), $3E ent_idx, $3F k.
;   (_DirFindRun's $36/$38 scratch is dead by the time we reuse the slot.)
; ============================================================================
_DirCreateRun:
                ; --- stash meta at slot+$30..$35 + drive at slot+$37 -------
                MOVE    X1, X2
                ADD     X1, #$30
                MOVE    Y1, Y2
                STORED  D0, [XY1+#0]            ; attr
                STORED  D1, [XY1+#2]            ; first cluster
                STORED  D2, [XY1+#4]            ; size low
                MOVE    X1, X2
                ADD     X1, #$37
                MOVE    Y1, Y2
                STOREB  D3, [XY1]               ; drive (format calls clobber D3)

                ; --- checksum over LFN_SHORT -> slot+$3A -------------------
                LOADI   Y0, #$00
                LOADI   X0, #LFN_SHORT
                CALLR   _LfnChecksum            ; D0 = checksum; preserves XY2,XY3
                AND     D0, #$FF
                MOVE    X1, X2
                ADD     X1, #$3A
                MOVE    Y1, Y2
                STOREB  D0, [XY1]

                ; --- nfrags = ceil(LFN_ASM_LEN / 13) -> slot+$3B -----------
                LOADZ   D0, [#LFN_ASM_LEN]
                ADD     D0, #12
                LOADI   D1, #0
.dcr_nf:
                CMP     D0, #13
                BLO     .dcr_nfd
                SUB     D0, #13
                ADD     D1, #1
                BRA     .dcr_nf
.dcr_nfd:
                MOVE    X1, X2
                ADD     X1, #$3B
                MOVE    Y1, Y2
                STOREB  D1, [XY1]               ; nfrags
                ; needed = nfrags + 1
                MOVE    D0, D1
                ADD     D0, #1

                ; --- find a single-sector run -----------------------------
                MOVE    X1, X2                  ; reload drive into D3
                ADD     X1, #$37
                MOVE    Y1, Y2
                LOADB   D3, [XY1]
                AND     D3, #$FF
                CALLR   _DirFindRun             ; D0=needed -> D1=sec_off, D2=ent_idx
                BCS     .dcr_err                ; ERR_NOSPACE / ERR_IO
                ; stash sec_off (word) at $3C, ent_idx (byte) at $3E
                MOVE    X1, X2
                ADD     X1, #$3C
                MOVE    Y1, Y2
                STORED  D1, [XY1]
                MOVE    X1, X2
                ADD     X1, #$3E
                MOVE    Y1, Y2
                STOREB  D2, [XY1]
                ; FS_BUF_SECTOR now holds the run's sector (loaded by _DirFindRun).

                ; --- write entries k = 0..nfrags --------------------------
                LOADI   D0, #0
                MOVE    X1, X2
                ADD     X1, #$3F
                MOVE    Y1, Y2
                STOREB  D0, [XY1]               ; k = 0
.dcr_loop:
                ; load k -> D0, nfrags -> D1
                MOVE    X0, X2
                ADD     X0, #$3F
                MOVE    Y0, Y2
                LOADB   D0, [XY0]
                AND     D0, #$FF                ; k
                MOVE    X0, X2
                ADD     X0, #$3B
                MOVE    Y0, Y2
                LOADB   D1, [XY0]
                AND     D1, #$FF                ; nfrags
                CMP     D0, D1
                BHI     .dcr_writeback          ; k > nfrags -> all entries done
                BEQ     .dcr_short              ; k == nfrags -> short entry

                ; --- fragment: ordinal = nfrags - k, is_last = (k==0) -----
                ; D0=k, D1=nfrags
                PUSH    D0, XY3                 ; save k
                MOVE    D2, D1
                SUB     D2, D0                  ; ordinal = nfrags - k  -> D2
                LOADI   D1, #0                  ; is_last
                CMP     D0, #0
                BNE     .dcr_notlast
                LOADI   D1, #1
.dcr_notlast:
                MOVE    D0, D2                  ; D0 = ordinal
                ; csum -> D2
                MOVE    X1, X2
                ADD     X1, #$3A
                MOVE    Y1, Y2
                LOADB   D2, [XY1]
                AND     D2, #$FF
                CALLR   _FormatLfnFragment      ; D0=ord,D1=is_last,D2=csum -> LFN_FRAG
                POP     D0, XY3                 ; k
                ; copy LFN_FRAG (32 B, page 0) -> entry (ent_idx + k)*32 in FS_BUF
                CALLR   _DcrEntryAddr           ; D0=k -> XY1 = entry addr
                LOADI   Y0, #$00
                LOADI   X0, #LFN_FRAG
                LOADI   D2, #32
.dcr_cp:
                LOADB   D1, [XY0]+
                STOREB  D1, [XY1]+
                SUB     D2, #1
                BNE     .dcr_cp
                BRA     .dcr_kinc

.dcr_short:
                ; --- short entry at slot (ent_idx + nfrags) ---------------
                ; D0 = k (= nfrags)
                CALLR   _DcrEntryAddr           ; D0=k -> XY1 = entry addr
                LOADI   Y0, #$00
                LOADI   X0, #LFN_SHORT          ; XY0 = 11-byte short name
                CALLR   _DicFormatShortEntry    ; fills 32 B at [XY1]; meta from slot+$30
                ; fall through to k++

.dcr_kinc:
                MOVE    X0, X2
                ADD     X0, #$3F
                MOVE    Y0, Y2
                LOADB   D0, [XY0]
                AND     D0, #$FF
                ADD     D0, #1
                MOVE    X1, X2
                ADD     X1, #$3F
                MOVE    Y1, Y2
                STOREB  D0, [XY1]
                BRA     .dcr_loop

.dcr_writeback:
                ; --- write FS_BUF_SECTOR back -----------------------------
                MOVE    X1, X2                  ; reload drive -> D3
                ADD     X1, #$37
                MOVE    Y1, Y2
                LOADB   D3, [XY1]
                AND     D3, #$FF
                MOVE    X0, X2                  ; sec_off (word) -> D1
                ADD     X0, #$3C
                MOVE    Y0, Y2
                LOADD   D1, [XY0]
                CALLR   _DirSecToAbs            ; D0 = abs sector
                BCS     .dcr_err
                PUSH    D0, XY3                 ; [S] abs sector
                LOADI   Y0, #$00
                LOADI   X0, #FS_BUF_SECTOR
                CALLR   _VolBlockWrite
                BCS     .dcr_err_pops           ; D0 = ERR_IO / ERR_READONLY
                POP     D0, XY3                 ; [S] abs
                STOREZ  D0, [#DIR_CACHE_SECTOR]
                MOVE    X1, X2                  ; drive -> D3 for cache id
                ADD     X1, #$37
                MOVE    Y1, Y2
                LOADB   D3, [XY1]
                AND     D3, #$FF
                STOREZB D3, [#DIR_CACHE_DRIVE]
                LOADI   D0, #$FFFF              ; invalidate dirent iter cache
                STOREZ  D0, [#DIRENT_LAST_COOKIE]
                ; restore D3 = drive for the caller, return success
                MOVE    X1, X2
                ADD     X1, #$37
                MOVE    Y1, Y2
                LOADB   D3, [XY1]
                AND     D3, #$FF
                LOADI   D0, #ERR_OK
                CLC
                RET

.dcr_err_pops:
                POP     D1, XY3                 ; discard [S]; D0 keeps error code
.dcr_err:
                ; restore D3 = drive for the caller (C=1, D0 = error already set)
                PUSH    D0, XY3                 ; save error code
                MOVE    X1, X2
                ADD     X1, #$37
                MOVE    Y1, Y2
                LOADB   D3, [XY1]
                AND     D3, #$FF
                POP     D0, XY3
                SEC
                RET


; ============================================================================
; _DirDeleteRun — delete a file's WHOLE VFAT run (LFN fragments + short entry)
;                 — Part 46 (45.5.3a, 17 June 2026)
;
;   The LFN-aware delete. Where _DirDelete (8.3) marks only the short entry,
;   this also $E5s the contiguous LFN fragment entries that precede it.
;
;   On-disk run layout written by _DirCreateRun (single sector, guaranteed):
;       [frag ord=N | $40] [frag ord=N-1] ... [frag ord=1] [short]
;   i.e. fragments physically precede the short entry, ascending ent_idx,
;   topmost fragment carries LFN_LAST_FLAG ($40). All in ONE sector, so the
;   teardown is a single-sector RMW — no cross-sector walk.
;
;   Caller MUST have already freed the cluster chain (as for _DirDelete);
;   this routine does not touch the FAT.
;
;   In:    XY2 = volume slot ptr
;          D3  = drive index
;          DIR_WALK_CLU = directory cluster (0 = root region)
;          RV_COMP / RV_FATNAME / RV_SAVE_PAD = leaf (as left by _ResolveParent)
;   Out:   C=0 success
;          C=1 with D0 = ERR_NOTFOUND  name not present
;                       ERR_IO         read/write failure
;                       ERR_READONLY   volume is read-only
;   Clobbers: D0, D1, D2, X0, X1, flags
;   Preserves: D3, XY2, XY3
;
;   Teardown stop conditions (belt-and-suspenders, standard VFAT):
;     backward from ent_idx-1, $E5 a candidate only while
;       attr ($0B) == $0F   AND   checksum ($0D) == short-name checksum,
;     and STOP after $E5ing one whose sequence byte had $40 (the run's top).
;   An 8.3 file (no fragments) marks only the short entry — byte-identical to
;   _DirDelete.
; ============================================================================
_DirDeleteRun:
                PUSH    D3, XY3                 ; [drv] preserve caller drive

                ; --- 1. long-aware lookup -> short-entry cookie ----------
                ; FS_BUF_SECTOR left holding the matched sector.
                CALLR   _DirLookupLong          ; D0=cookie; preserves D3,XY2,XY3
                BCS     .ddr_lookup_err         ; ERR_NOTFOUND / ERR_IO

                ; --- 2. decompose cookie ---------------------------------
                MOVE    D2, D0
                AND     D2, #$0F                ; D2 = ent_idx (short entry)
                SHR4    D0                      ; D0 = sec_off
                PUSH    D0, XY3                 ; [sec_off] for write-back

                ; --- 3. checksum over the short entry's 11-byte name -----
                ; entry_addr = FS_BUF_SECTOR + ent_idx * 32  -> XY0
                MOVE    D0, D2
                SHL4    D0
                SHL     D0
                ADD     D0, #FS_BUF_SECTOR
                LOADI   Y0, #$00
                MOVE    X0, D0                  ; XY0 = short entry addr
                PUSH    D2, XY3                 ; [ent_idx] (_LfnChecksum clobbers D2)
                CALLR   _LfnChecksum            ; D0 = checksum; preserves XY0..XY3
                AND     D0, #$FF
                MOVE    D3, D0                  ; D3 = checksum, held across the walk
                POP     D2, XY3                 ; [ent_idx] -> D2 = walk start

                ; --- 4. $E5 the short entry's first byte -----------------
                LOADI   D0, #DIR_FREE_REUSABLE
                STOREB  D0, [XY0]               ; XY0 = short entry (preserved above)

                ; --- 5. walk fragments backward (single sector) ----------
                ; D2 = i (starts at ent_idx); D3 = checksum.
.ddr_walk:
                CMP     D2, #0
                BEQ     .ddr_writeback          ; no entry below the short one
                SUB     D2, #1                  ; i = i - 1 (candidate fragment)
                MOVE    D0, D2
                SHL4    D0
                SHL     D0
                ADD     D0, #FS_BUF_SECTOR
                LOADI   Y1, #$00
                MOVE    X1, D0                  ; XY1 = candidate entry addr

                ; attr == $0F ?
                LOADI   D0, #DIR_ATTR           ; $0B
                LOADB   D0, [XY1+D0]
                AND     D0, #$FF
                CMP     D0, #DIR_ATTR_LFN
                BNE     .ddr_writeback          ; not an LFN fragment -> stop

                ; checksum ($0D) matches this short name ?
                LOADI   D0, #$0D
                LOADB   D0, [XY1+D0]
                AND     D0, #$FF
                CMP     D0, D3
                BNE     .ddr_writeback          ; different file's fragment -> stop

                ; capture sequence byte BEFORE overwrite, then $E5 it
                LOADB   D0, [XY1]
                AND     D0, #$FF                ; D0 = sequence byte
                LOADI   D1, #DIR_FREE_REUSABLE
                STOREB  D1, [XY1]               ; mark fragment deleted

                ; was this the topmost (last logical) fragment of the run ?
                AND     D0, #LFN_LAST_FLAG
                CMP     D0, #0
                BNE     .ddr_writeback          ; run fully torn down -> done
                BRA     .ddr_walk

.ddr_writeback:
                ; --- 6. write FS_BUF_SECTOR back -------------------------
                POP     D1, XY3                 ; [sec_off] -> D1
                POP     D3, XY3                 ; [drv]     -> D3 (drive restored)
                CALLR   _DirSecToAbs            ; D1=sec_off,D3=drive -> D0=abs
                BCS     .ddr_abs_err            ; (won't fail: sector just read)
                PUSH    D0, XY3                 ; [abs] absolute sector
                LOADI   Y0, #$00
                LOADI   X0, #FS_BUF_SECTOR
                CALLR   _VolBlockWrite          ; clobbers D0,D1,D2; preserves D3
                BCS     .ddr_io_pops            ; ERR_IO / ERR_READONLY

                ; --- 7. refresh dir cache identity + invalidate iter cache
                POP     D0, XY3                 ; [abs]
                STOREZ  D0, [#DIR_CACHE_SECTOR]
                STOREZB D3, [#DIR_CACHE_DRIVE]
                LOADI   D0, #$FFFF
                STOREZ  D0, [#DIRENT_LAST_COOKIE]
                LOADI   D0, #ERR_OK
                CLC
                RET

.ddr_io_pops:
                POP     D1, XY3                 ; discard [abs]; D0 keeps error
                SEC
                RET

.ddr_abs_err:
                ; _DirSecToAbs failed; [drv] and [sec_off] already popped.
                ; D0/C set by _DirSecToAbs.
                SEC
                RET

.ddr_lookup_err:
                ; [drv] still on stack; D0/C set by _DirLookupLong.
                ; (POP is flag-transparent — C survives.)
                POP     D3, XY3
                SEC
                RET


; ============================================================================
; End of kos_fs_dir_lfn.asm
; ============================================================================
