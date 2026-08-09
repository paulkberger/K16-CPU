; ============================================================================
; kos_fs_dir_path.asm — k/OS path resolver + pwd reconstruction (split)
; ============================================================================
; Part 47 (17 June 2026): extracted verbatim from kos_fs_dir.asm. The path
; resolver (_ResolveCore/_Resolve/_ResolveParent + _Rv* string helpers) and
; the pwd/path-builder (_ScanForCluster/_BuildPath + _ReadParentCluster).
;
; NOT standalone — same assembly unit as kos_fs_dir.asm. Must be .INCLUDEd
; immediately AFTER kos_fs_dir_lfn.asm in kos_boot.asm. Inter-file calls are
; CALLR (PC-relative). _ScanForCluster uses _DirNext (LFN-aware) and recovers
; long names via LFN_ASM (see kos_fs_dir_lfn.asm).
;
; Calls into kos_fs_dir.asm: _DirNext, _DirNameFromFat, _DirSecToAbs.
; Calls into kos_fs_fd.asm: _SlotForDrive.
; ============================================================================


; ============================================================================
; _DirCacheInvalidate — drop the dir-buffer cache (Part 22)
;
;   Used by anything that writes to FS_BUF_SECTOR with sector data that's
;   NOT a root-directory sector (or a different drive's root). Examples:
;   _TryMount reading a BPB, _DirLookup reading directory entries on a
;   different drive, sys_read reading file data, _DirInsert / _DirDelete
;   after their sector-write.
;
;   In:    none
;   Out:   DIR_CACHE_SECTOR = $FFFF
;   Clobbers: D0
; ============================================================================
; ============================================================================
; _ReadParentCluster — return the parent cluster of a directory
;
;   '..' is always entry index 1 of a directory cluster (mkdir writes
;   '.'=entry0, '..'=entry1; FAT invariant). Read the new dir's first
;   sector and pull DIR_FIRST_CLUSTER_LO from entry 1.
;
;   Caller must only call this for a real subdir (clu >= 2); the root
;   region (clu = 0) has no '..' and is handled by the resolver's clamp.
;
;   In:    D1  = directory cluster (>= 2)
;          XY2 = volume slot ptr
;          D3  = drive index
;   Out:   C=0 with D1 = parent cluster (0 = parent is the root region)
;          C=1 with D0 = ERR_IO / ERR_INVALID
;   Clobbers: D0, D2, X0, X1, flags
;   Preserves: D3, XY2, XY3   (D1 is updated to the parent)
; ============================================================================
_ReadParentCluster:
                ; Sector of this dir's cluster.
                MOVE    D0, D1
                CALLR   _ClusterToSector         ; D0 = abs sector; preserves D2,D3,XY*
                BCS     .rpc_err                 ; ERR_INVALID

                LOADI   Y0, #$00
                LOADI   X0, #FS_BUF_SECTOR
                CALLR   _VolBlockRead
                BCS     .rpc_err                 ; ERR_IO
                ; This sector is NOT a root-dir sector; drop the dir cache so
                ; a later _DirNextRaw/_DirLookup doesn't trust FS_BUF_SECTOR.
                CALLR   _DirCacheInvalidate

                ; Entry 1 (the '..' entry) at FS_BUF_SECTOR + 32.
                ; Parent cluster at +DIR_FIRST_CLUSTER_LO ($1A).
                LOADI   Y0, #$00
                LOADI   X0, #FS_BUF_SECTOR + 32 + DIR_FIRST_CLUSTER_LO
                LOADD   D1, [XY0]                ; D1 = parent cluster
                CLC
                RET

.rpc_err:
                ; D0 already set, C=1.
                SEC
                RET


; ============================================================================
; _ResolveCore — walk a path to a directory/file cluster
;
;   The heart of the path resolver. Handles a prefix ("X:"), a leading "/"
;   (mount-relative to the current drive root), or a relative path, then
;   walks "/"-delimited components: "." (skip), ".." (parent, root-clamped),
;   or a name (LookupChild). DIR_WALK_CLU is used to make _DirLookup walk
;   the current directory cluster; it is reset to 0 on every exit.
;
;   Two modes:
;     RV_MODE = 0 (FULL)   — resolve every component; return the final
;                            (drive, cluster, attr).
;     RV_MODE = 1 (PARENT) — resolve all but the LAST component; return the
;                            parent (drive, cluster) and leave the last
;                            component as an 11-byte FAT name in RV_FATNAME.
;                            Used by create paths (mkdir): "resolve parent,
;                            then operate on leaf".
;
;   In:    XY0 = nul-terminated path (in caller's task page)
;          D0  = start drive index   (for relative / rooted)
;          D1  = start cluster       (for relative; 0 = root)
;          RV_MODE preset by the wrapper (0 or 1)
;   Out:   C=0:
;            FULL   — D0 = drive, D1 = cluster, D2 = attr of final entry
;            PARENT — D0 = drive, D1 = parent cluster; RV_FATNAME = leaf
;          C=1 with D0 = ERR_BADPATH / ERR_BADDRIVE / ERR_NOTFOUND /
;                        ERR_NOTDIR / ERR_INVALID / ERR_IO
;   Clobbers: D0, D1, D2, D3, X0, X1, Y0, Y1, flags
;   Preserves: XY2 (loaded internally), XY3
; ============================================================================
_ResolveCore:
                ; --- Stash the path pointer (user page) -------------------
                MOVE    D2, X0
                STOREZ  D2, [#RV_PATH_X]
                MOVE    D2, Y0
                STOREZB D2, [#RV_PATH_Y]

                ; --- Working drive/cluster/attr ---------------------------
                STOREZB D0, [#RV_DRIVE]          ; default: start drive
                STOREZ  D1, [#RV_CLU]            ; default: start cluster
                LOADI   D2, #DIR_ATTR_DIRECTORY  ; current cluster is a dir
                STOREZ  D2, [#RV_ATTR]

                ; --- Prefix / rooted / relative detection -----------------
                ; Re-read path[0] and path[1] from the user page.
                CALLR   _RvLoadPathPtr           ; XY0 = path ptr
                LOADB   D0, [XY0]                ; path[0]
                AND     D0, #$FF
                ; alphabetic?  A..Z or a..z
                CALLR   _RvIsAlpha               ; C=0 if alpha (D0 preserved)
                BCS     .rv_check_slash
                ; could be "X:" — check path[1] == ':'
                INC     XY0, #1
                LOADB   D1, [XY0]
                AND     D1, #$FF
                CMP     D1, #':'
                BNE     .rv_try_name             ; alpha, not ':' -> maybe NAME: volume
                ; prefix "X:" — set drive, root, advance ptr by 2.
                ; uppercase letter -> index.
                CALLR   _RvUpper                 ; D0 = uppercased path[0]
                SUB     D0, #'A'
                STOREZB D0, [#RV_DRIVE]
                LOADI   D2, #0
                STOREZ  D2, [#RV_CLU]            ; prefixed -> that drive's root
                ; advance path ptr by 2 (past "X:")
                LOADZ   D2, [#RV_PATH_X]
                ADD     D2, #2
                STOREZ  D2, [#RV_PATH_X]
                BRA     .rv_have_start

.rv_try_name:
                ; Leading alpha run not immediately "X:" — could be "NAME:"
                ; (a named volume / assign, >= 2 chars). Copy the run into the
                ; page-$00 candidate buffer, stop at ':' / '/' / nul. On ':'
                ; with 2..11 chars, look it up; a hit supplies (drive, cluster)
                ; exactly as the "X:" branch does. Anything else -> relative.
                CALLR   _RvLoadPathPtr           ; XY0 = path[0] (user page)
                LOADI   D0, #AS_CAND
                MOVE    X1, D0                   ; dest = candidate buffer
                LOADI   D0, #0
                MOVE    Y1, D0                   ; dest page = $00
                LOADI   D3, #0                   ; run length
.rtn_scan:
                LOADB   D0, [XY0]
                AND     D0, #$FF
                CMP     D0, #':'
                BEQ     .rtn_colon
                CMP     D0, #'/'
                BEQ     .rtn_notname             ; '/' first -> not a prefix
                CMP     D0, #0
                BEQ     .rtn_notname             ; nul first -> not a prefix
                CMP     D3, #11
                BHS     .rtn_notname             ; > 11 chars -> too long
                STOREB  D0, [XY1]+               ; candidate[len++] = ch
                INC     XY0, #1
                ADD     D3, #1
                BRA     .rtn_scan
.rtn_colon:
                CMP     D3, #2
                BLO     .rtn_notname             ; < 2 chars is a drive, not a name
                LOADI   D0, #0
                STOREB  D0, [XY1]+               ; nul-terminate candidate
                LOADI   D0, #AS_CAND
                MOVE    X0, D0                   ; candidate ptr for _SlotForName
                PUSH    D3, XY3                  ; save len across the scan
                CALLR   _SlotForName             ; C=0: X1=entry,D0=drive,D1=rootclu
                BCS     .rtn_miss                ; unknown volume
                LOADB   D2, [XY1+#AS_FLAGS]      ; deleted backing? (dirty)
                AND     D2, #AS_FLAG_DIRTY
                BNE     .rtn_dirty
                STOREZB D0, [#RV_DRIVE]          ; backing drive
                STOREZ  D1, [#RV_CLU]            ; mount cluster (0 = backend root)
                POP     D3, XY3                  ; restore len
                LOADZ   D2, [#RV_PATH_X]
                ADD     D2, D3                   ; skip NAME
                ADD     D2, #1                   ; skip ':'
                STOREZ  D2, [#RV_PATH_X]
                BRA     .rv_have_start
.rtn_miss:
                POP     D3, XY3                  ; balance stack (D0=ERR_BADDRIVE)
                BRA     .rv_baddrive
.rtn_dirty:
                POP     D3, XY3                  ; balance stack
                LOADI   D0, #ERR_NOTFOUND        ; backing dir was deleted
                BRA     .rv_err
.rtn_notname:
                BRA     .rv_no_prefix

.rv_check_slash:
                ; not alpha; is it leading '/'?
                CMP     D0, #'/'
                BNE     .rv_no_prefix
                ; rooted: current drive, root cluster, advance ptr by 1.
                LOADI   D2, #0
                STOREZ  D2, [#RV_CLU]
                LOADZ   D2, [#RV_PATH_X]
                ADD     D2, #1
                STOREZ  D2, [#RV_PATH_X]
                BRA     .rv_have_start

.rv_no_prefix:
                ; relative: drive/cluster already = start; ptr unchanged.
.rv_have_start:
                ; --- Resolve the working drive -> XY2 slot ----------------
                LOADZB  D0, [#RV_DRIVE]
                AND     D0, #$FF
                CALLR   _SlotForDrive            ; D0=drive -> XY2 ; clobbers D0,X2
                BCS     .rv_baddrive
                LOADZB  D3, [#RV_DRIVE]
                AND     D3, #$FF                 ; D3 = drive (for dir routines)

                ; ============ component loop ==============================
.rv_loop:
                ; Skip any run of '/' separators.
                CALLR   _RvSkipSlashes           ; advances RV_PATH_X past '/'

                ; End of path?
                CALLR   _RvLoadPathPtr
                LOADB   D0, [XY0]
                AND     D0, #$FF
                CMP     D0, #0
                BEQ     .rv_done                 ; no more components

                ; Extract one component into RV_COMP (ASCIIZ); leaves
                ; RV_PATH_X just past it (at '/' or nul). Returns D2 = length.
                CALLR   _RvExtractComponent
                BCS     .rv_badpath              ; illegal char in component
                ; D2 = component length (>0 here).

                ; --- PARENT mode: is this the LAST component? -------------
                LOADZ   D0, [#RV_MODE]
                CMP     D0, #1
                BNE     .rv_not_parent_last
                ; Peek: after skipping trailing '/', is it end of path?
                CALLR   _RvAtEnd                 ; C=0 if at end (last comp)
                BCS     .rv_not_parent_last      ; more components follow
                ; This is the last component and we're in PARENT mode:
                ; return parent = RV_CLU; the leaf stays in RV_COMP. Convert to
                ; FAT-11 for the 8.3 case — a long leaf is NOT a bad path here
                ; (LFN create needs it). RV_SAVE_PAD records whether RV_FATNAME
                ; holds a usable 8.3 form (1) or the leaf is long-only (0).
                LOADI   Y0, #$00
                LOADI   X0, #RV_COMP
                LOADI   Y1, #$00
                LOADI   X1, #RV_FATNAME
                CALLR   _DirNameToFat            ; preserves D3
                BCS     .rv_parent_no83
                LOADI   D0, #1
                STOREZB D0, [#RV_SAVE_PAD]
                BRA     .rv_parent_leaf_ok
.rv_parent_no83:
                LOADI   D0, #0
                STOREZB D0, [#RV_SAVE_PAD]
.rv_parent_leaf_ok:
                LOADZB  D0, [#RV_DRIVE]
                AND     D0, #$FF
                LOADZ   D1, [#RV_CLU]
                BRA     .rv_ok                   ; D0=drive, D1=parent clu

.rv_not_parent_last:
                ; --- "." -> skip ------------------------------------------
                LOADI   Y0, #$00
                LOADI   X0, #RV_COMP
                LOADB   D0, [XY0]
                AND     D0, #$FF
                CMP     D0, #'.'
                BNE     .rv_name                 ; not dot-prefixed -> a name
                ; first char is '.'; check for "." (len 1) or ".." (len 2).
                INC     XY0, #1
                LOADB   D1, [XY0]
                AND     D1, #$FF
                CMP     D1, #0
                BEQ     .rv_loop                 ; "." -> no-op, next component
                CMP     D1, #'.'
                BNE     .rv_name                 ; ".x" -> treat as a name
                INC     XY0, #1
                LOADB   D1, [XY0]
                AND     D1, #$FF
                CMP     D1, #0
                BNE     .rv_name                 ; "..x" -> a name
                ; --- ".." -> parent, root-clamped -------------------------
                LOADZ   D1, [#RV_CLU]
                CMP     D1, #0
                BEQ     .rv_loop                 ; at root: '..' clamps (no-op)
                CALLR   _ReadParentCluster       ; D1 = parent; needs XY2,D3
                BCS     .rv_err                  ; ERR_IO / ERR_INVALID
                STOREZ  D1, [#RV_CLU]
                LOADI   D0, #DIR_ATTR_DIRECTORY
                STOREZ  D0, [#RV_ATTR]
                BRA     .rv_loop

.rv_name:
                ; --- a real name: must be able to descend (cur is a dir) --
                LOADZ   D0, [#RV_ATTR]
                AND     D0, #DIR_ATTR_DIRECTORY
                BEQ     .rv_notdir               ; previous component was a file

                ; Convert component -> FAT-11. A long name (spaces / >8.3) is
                ; NOT a bad path here: _DirNameToFat rejects it, but we still
                ; want a long-name lookup. RV_SAVE_PAD records whether RV_FATNAME
                ; holds a usable 8.3 form (1) for the fallback compare, or not (0).
                LOADI   Y0, #$00
                LOADI   X0, #RV_COMP
                LOADI   Y1, #$00
                LOADI   X1, #RV_FATNAME
                CALLR   _DirNameToFat            ; preserves D3
                BCS     .rv_name_no83
                LOADI   D0, #1
                STOREZB D0, [#RV_SAVE_PAD]       ; RV_FATNAME valid for 8.3 fallback
                BRA     .rv_name_lookup
.rv_name_no83:
                LOADI   D0, #0
                STOREZB D0, [#RV_SAVE_PAD]       ; long-name match only

.rv_name_lookup:
                ; Long-aware lookup in the current cluster: match by long name
                ; (vs RV_COMP), else by 8.3 (vs RV_FATNAME) when RV_SAVE_PAD=1.
                LOADZ   D0, [#RV_CLU]
                STOREZ  D0, [#DIR_WALK_CLU]
                CALLR   _DirLookupLong           ; XY2 slot, D3 drive; reads RV_COMP/RV_FATNAME
                BCS     .rv_notfound_or_io       ; ERR_NOTFOUND / ERR_IO
                ; D0 = cookie. Entry addr = FS_BUF_SECTOR + (cookie&$0F)*32.
                MOVE    D1, D0
                AND     D1, #$0F
                SHL4    D1
                SHL     D1
                ADD     D1, #FS_BUF_SECTOR
                LOADI   Y0, #$00
                MOVE    X0, D1
                ; child cluster + attr
                LOADD   D0, [XY0+#DIR_FIRST_CLUSTER_LO]
                STOREZ  D0, [#RV_CLU]
                LOADB   D0, [XY0+#DIR_ATTR]
                AND     D0, #$FF
                STOREZ  D0, [#RV_ATTR]
                BRA     .rv_loop

.rv_done:
                ; FULL mode (PARENT returns via .rv_ok inside the loop):
                ; (RV_DRIVE, RV_CLU, RV_ATTR) is the answer.
                LOADZB  D0, [#RV_DRIVE]
                AND     D0, #$FF
                LOADZ   D1, [#RV_CLU]
                LOADZ   D2, [#RV_ATTR]
                ; fall into .rv_ok

.rv_ok:
                LOADI   D3, #0
                STOREZ  D3, [#DIR_WALK_CLU]      ; reset to root-region default
                CLC
                RET

.rv_notfound_or_io:
                ; D0 already = ERR_NOTFOUND or ERR_IO, C=1.
                BRA     .rv_err
.rv_baddrive:
                LOADI   D0, #ERR_BADDRIVE
                BRA     .rv_err
.rv_badpath:
                LOADI   D0, #ERR_BADPATH
                BRA     .rv_err
.rv_notdir:
                LOADI   D0, #ERR_NOTDIR
                ; fall through
.rv_err:
                ; Reset DIR_WALK_CLU and return with carry set, D0 = err.
                PUSH    D0, XY3
                LOADI   D0, #0
                STOREZ  D0, [#DIR_WALK_CLU]
                POP     D0, XY3
                SEC
                RET


; ============================================================================
; _Resolve / _ResolveParent — thin mode-setting wrappers over _ResolveCore
; ============================================================================
_Resolve:                               ; FULL
                LOADI   D2, #0
                STOREZ  D2, [#RV_MODE]
                CALLR   _ResolveCore
                RET

_ResolveParent:                         ; PARENT (leaf -> RV_FATNAME)
                LOADI   D2, #1
                STOREZ  D2, [#RV_MODE]
                CALLR   _ResolveCore
                RET


; ============================================================================
; --- resolver string helpers ----------------------------------------------
; ============================================================================

; _RvLoadPathPtr — load XY0 with the current path pointer from RV_PATH_X/Y
;   Out: XY0 = path ptr (page from RV_PATH_Y, offset from RV_PATH_X)
;   Clobbers: D0, X0, Y0
_RvLoadPathPtr:
                LOADZB  D0, [#RV_PATH_Y]
                MOVE    Y0, D0
                LOADZ   D0, [#RV_PATH_X]
                MOVE    X0, D0
                RET

; _RvIsAlpha — C=0 if D0 is A..Z or a..z, else C=1. D0 preserved.
_RvIsAlpha:
                CMP     D0, #'A'
                BLO.S   .ria_no
                CMP     D0, #$5B                ; 'Z'+1
                BLO.S   .ria_yes
                CMP     D0, #'a'
                BLO.S   .ria_no
                CMP     D0, #$7B                ; 'z'+1
                BHS.S   .ria_no
.ria_yes:
                CLC
                RET
.ria_no:
                SEC
                RET

; _RvUpper — D0 = uppercase of D0 (if a..z); else unchanged.
_RvUpper:
                CMP     D0, #'a'
                BLO.S   .ru_done
                CMP     D0, #$7B
                BHS.S   .ru_done
                SUB     D0, #$20
.ru_done:
                RET

; _RvSkipSlashes — advance RV_PATH_X past a run of '/'.
;   Clobbers: D0, D1, X0, Y0
_RvSkipSlashes:
                CALLR   _RvLoadPathPtr
.rss_loop:
                LOADB   D0, [XY0]
                AND     D0, #$FF
                CMP     D0, #'/'
                BNE.S   .rss_done
                INC     XY0, #1
                BRA     .rss_loop
.rss_done:
                ; write advanced offset back.
                MOVE    D0, X0
                STOREZ  D0, [#RV_PATH_X]
                RET

; _RvExtractComponent — copy bytes from path into RV_COMP until '/' or nul.
;   Advances RV_PATH_X to the terminator. Nul-terminates RV_COMP.
;   Out: C=0: D2 = component length (0..LFN_MAX, clipped).
;        C=1: D0 = ERR_BADPATH (an illegal filename char in the component).
;   Clobbers: D0, D1, D2, X0, X1, Y0, Y1
_RvExtractComponent:
                CALLR   _RvLoadPathPtr           ; XY0 = src
                LOADI   Y1, #$00
                LOADI   X1, #RV_COMP             ; XY1 = dest
                LOADI   D2, #0                   ; length
.rec_loop:
                LOADB   D0, [XY0]
                AND     D0, #$FF
                CMP     D0, #0
                BEQ.S   .rec_done
                CMP     D0, #'/'
                BEQ.S   .rec_done
                ; clip at LFN_MAX chars (leave room for nul in 32-byte RV_COMP)
                CMP     D2, #LFN_MAX
                BHS.S   .rec_skip_store
                STOREB  D0, [XY1]+
.rec_skip_store:
                ADD     D2, #1
                INC     XY0, #1
                BRA     .rec_loop
.rec_done:
                ; nul-terminate dest
                LOADI   D0, #0
                STOREB  D0, [XY1]
                ; write advanced source offset back to RV_PATH_X
                MOVE    D0, X0
                STOREZ  D0, [#RV_PATH_X]
                ; clamp returned length to <= LFN_MAX
                CMP     D2, #LFN_MAX
                BLO.S   .rec_lenok
                LOADI   D2, #LFN_MAX
.rec_lenok:
                ; --- reject illegal filename chars in the component -------
                ; FAT long-name illegal set: " * : < > ? | \ and controls.
                ; '/' already terminated the component; the drive ':' was
                ; consumed by _ResolveCore before this loop, so any ':' here
                ; is malformed. Globbing is shell-side, so '*'/'?' never
                ; legitimately reach the resolver. Space ($20) is legal - the
                ; whole point of long names. XY0/X0 are free now (the RV_PATH_X
                ; writeback above already consumed the source ptr); D2 (the
                ; return length) is preserved by the scan.
                LOADI   Y0, #$00
                LOADI   X0, #RV_COMP
.rec_chk:
                LOADB   D0, [XY0]+               ; read + advance (STREAM, byte stride 1)
                AND     D0, #$FF
                CMP     D0, #0
                BEQ     .rec_chk_ok
                CALLR   _RvBadChar               ; C=1 if illegal (preserves XY0)
                BCS     .rec_bad
                BRA     .rec_chk
.rec_bad:
                LOADI   D0, #ERR_BADPATH
                SEC
                RET
.rec_chk_ok:
                CLC
                RET

; _RvBadChar - C=1 if D0 is a FAT-illegal filename char, else C=0.
;   D0 preserved. Plain branches only (no .S). Illegal set (hex to dodge
;   char-literal quoting): $22 " , $2A * , $3A : , $3C < , $3E > , $3F ? ,
;   $5C \ , $7C | , plus all control chars below $20. Space ($20) is legal.
_RvBadChar:
                CMP     D0, #$20
                BLO     .rbc_bad                 ; control char
                CMP     D0, #$22
                BEQ     .rbc_bad
                CMP     D0, #$2A
                BEQ     .rbc_bad
                CMP     D0, #$3A
                BEQ     .rbc_bad
                CMP     D0, #$3C
                BEQ     .rbc_bad
                CMP     D0, #$3E
                BEQ     .rbc_bad
                CMP     D0, #$3F
                BEQ     .rbc_bad
                CMP     D0, #$5C
                BEQ     .rbc_bad
                CMP     D0, #$7C
                BEQ     .rbc_bad
                CLC
                RET
.rbc_bad:
                SEC
                RET

; _RvAtEnd — peek: after skipping trailing '/', is path at nul?
;   Does NOT advance RV_PATH_X (peek only).
;   Out: C=0 if at end (this was the last component); C=1 if more follow.
;   Clobbers: D0, X0, Y0
_RvAtEnd:
                CALLR   _RvLoadPathPtr
.rae_loop:
                LOADB   D0, [XY0]
                AND     D0, #$FF
                CMP     D0, #'/'
                BNE.S   .rae_check
                INC     XY0, #1
                BRA     .rae_loop
.rae_check:
                CMP     D0, #0
                BEQ.S   .rae_end
                SEC                              ; more components
                RET
.rae_end:
                CLC                              ; at end
                RET


; ============================================================================
; _ScanForCluster — find the name of a child cluster within a parent dir
;
;   Walks the parent directory (LFN-aware via _DirNext) looking for the
;   visible entry whose first cluster equals the target. Skips '.' / '..'.
;   Part 47: recovers the LONG name when the matched entry has an LFN run —
;   _DirNext leaves it assembled in LFN_ASM (up to 31 chars), which is too
;   big for the 14-byte RV_NAMEBUF, so the long name is returned in place in
;   LFN_ASM and signalled by D0=1. An 8.3-only match is converted into
;   RV_NAMEBUF and signalled by D0=0.
;
;   In:    D0  = parent cluster (0 = root region)
;          D1  = target child cluster
;          XY2 = volume slot ptr
;          D3  = drive index
;   Out:   C=0 with D0 = 0  -> 8.3 name in RV_NAMEBUF ("NAME.EXT"\0)
;              C=0 with D0 = 1  -> long name in LFN_ASM (ASCIIZ)
;          C=1 with D0 = ERR_NOTFOUND / ERR_IO
;   Clobbers: D0, D1, D2, X0, X1, Y0, Y1, flags
;   Preserves: D3, XY2, XY3
; ============================================================================
_ScanForCluster:
                STOREZ  D1, [#RV_TARGET]         ; target cluster
                ; DIR_WALK_CLU = parent for the iteration.
                STOREZ  D0, [#DIR_WALK_CLU]
                LOADI   D0, #0                   ; cookie = 0
.sfc_loop:
                ; Part 47: _DirNext (not _DirNextRaw) — LFN-aware. It returns
                ; only visible short entries (skips $E5/$0F/volume), leaves the
                ; 32-byte entry in RV_DIRENT_RAW and any assembled long name in
                ; LFN_ASM/LFN_ASM_LEN. D0=cookie in, next cookie out.
                LOADI   Y1, #$00
                LOADI   X1, #RV_DIRENT_RAW
                CALLR   _DirNext
                BCS     .sfc_nomore              ; ERR_NOMORE / ERR_IO
                PUSH    D0, XY3                  ; save next cookie
                LOADI   Y0, #$00
                LOADI   X0, #RV_DIRENT_RAW
                ; skip '.' and '..' (names starting with '.').
                LOADB   D1, [XY0]
                AND     D1, #$FF
                CMP     D1, #'.'
                BEQ     .sfc_next
                ; compare first cluster to target.
                LOADD   D1, [XY0+#DIR_FIRST_CLUSTER_LO]
                LOADZ   D2, [#RV_TARGET]
                CMP     D1, D2
                BNE     .sfc_next                ; no match -> next entry
                ; --- match: long name in LFN_ASM, or 8.3 in RV_NAMEBUF ---
                POP     D0, XY3                  ; discard saved cookie
                LOADZ   D0, [#LFN_ASM_LEN]
                CMP     D0, #0
                BEQ     .sfc_short
                ; long name already assembled in LFN_ASM; signal D0=1.
                LOADI   D0, #1
                CLC
                RET
.sfc_short:
                LOADI   Y0, #$00
                LOADI   X0, #RV_DIRENT_RAW       ; 11-byte FAT name at +0
                LOADI   Y1, #$00
                LOADI   X1, #RV_NAMEBUF
                CALLR   _DirNameFromFat
                LOADI   D0, #0                   ; signal 8.3 in RV_NAMEBUF
                CLC
                RET
.sfc_next:
                POP     D0, XY3                  ; D0 = next cookie
                BRA     .sfc_loop
.sfc_nomore:
                ; D0 = ERR_NOMORE or ERR_IO. Map NOMORE -> NOTFOUND.
                CMP     D0, #ERR_NOMORE
                BNE.S   .sfc_io
                LOADI   D0, #ERR_NOTFOUND
.sfc_io:
                SEC
                RET


; ============================================================================
; _BuildPath — reconstruct a path string from (drive, cluster)  (spec §9)
;
;   Walks '..' upward collecting ancestor clusters, then emits
;   "X:/name1/name2/..." forward. At each level the name is recovered by
;   scanning the parent for the child whose first cluster matches.
;
;   In:    D0  = drive index
;          D1  = cluster (0 = root)
;          XY0 = dest buffer (caller page; >= ~80 bytes)
;   Out:   C=0 with dest = "X:/..."\0
;          C=1 with D0 = ERR_IO / ERR_INVALID / ERR_BADDRIVE
;   Clobbers: D0..D3, X0, X1, Y0, Y1, flags
;   Preserves: XY2 (loaded internally), XY3
; ============================================================================
_BuildPath:
                ; Stash dest pointer + drive + start cluster.
                MOVE    D2, X0
                STOREZ  D2, [#RV_PWD_X]
                MOVE    D2, Y0
                STOREZB D2, [#RV_PWD_Y]
                STOREZB D0, [#RV_DRIVE]
                STOREZ  D1, [#RV_CLU]

                ; Resolve slot for drive -> XY2, D3.
                CALLR   _SlotForDrive            ; D0=drive -> XY2
                BCS     .bp_baddrive
                LOADZB  D3, [#RV_DRIVE]
                AND     D3, #$FF

                ; Emit "X:" into dest.
                CALLR   _BpLoadDest              ; XY1 = dest
                LOADZB  D0, [#RV_DRIVE]
                AND     D0, #$FF
                ADD     D0, #'A'
                STOREB  D0, [XY1]+
                LOADI   D0, #':'
                STOREB  D0, [XY1]+
                CALLR   _BpSaveDest

                ; --- Collect ancestor chain (clu -> parent -> ... -> 0) ---
                LOADI   D0, #0
                STOREZ  D0, [#RV_CHAIN_DEPTH]
                STOREZB D0, [#RV_PWD_FIRST]      ; no path component emitted yet
                LOADZ   D1, [#RV_CLU]
.bp_collect:
                CMP     D1, #0
                BEQ     .bp_collected            ; reached root
                ; push D1 into RV_CHAIN[depth], depth++
                LOADZ   D0, [#RV_CHAIN_DEPTH]
                CMP     D0, #16
                BHS     .bp_toodeep              ; clamp absurd depth
                MOVE    D2, D0
                SHL     D2                       ; depth*2 (word index)
                LOADI   Y0, #$00
                LOADI   X0, #RV_CHAIN
                ADD     X0, D2
                STORED  D1, [XY0]                ; RV_CHAIN[depth] = cluster
                ADD     D0, #1
                STOREZ  D0, [#RV_CHAIN_DEPTH]
                ; D1 = parent of D1
                CALLR   _ReadParentCluster       ; D1 -> parent; needs XY2,D3
                BCS     .bp_err
                BRA     .bp_collect

.bp_collected:
                ; depth==0 -> at root; the drive prefix "X:" stands alone
                ; (Amiga form, no slash after the colon).
                LOADZ   D0, [#RV_CHAIN_DEPTH]
                CMP     D0, #0
                BEQ     .bp_terminate

.bp_emit:
                ; Emit from shallowest (index depth-1) to deepest (index 0).
                ; For RV_CHAIN[i], parent = RV_CHAIN[i+1], or 0 if i==depth-1.
                LOADZ   D0, [#RV_CHAIN_DEPTH]
                ; D0 = depth; iterate i = depth-1 down to 0.
.bp_emit_loop:
                CMP     D0, #0
                BEQ     .bp_terminate
                SUB     D0, #1                   ; i = D0
                PUSH    D0, XY3                  ; [i] save index
                ; child = RV_CHAIN[i]
                MOVE    D2, D0
                SHL     D2
                LOADI   Y0, #$00
                LOADI   X0, #RV_CHAIN
                ADD     X0, D2
                LOADD   D1, [XY0]                ; D1 = child cluster (target)
                ; parent = (i == depth-1) ? 0 : RV_CHAIN[i+1]
                LOADZ   D2, [#RV_CHAIN_DEPTH]
                SUB     D2, #1                   ; depth-1
                CMP     D0, D2
                BNE.S   .bp_parent_inner
                LOADI   D0, #0                   ; parent = root
                BRA.S   .bp_have_parent
.bp_parent_inner:
                ; parent = RV_CHAIN[i+1]
                MOVE    D2, D0
                ADD     D2, #1
                SHL     D2
                LOADI   Y0, #$00
                LOADI   X0, #RV_CHAIN
                ADD     X0, D2
                LOADD   D0, [XY0]                ; D0 = parent cluster
.bp_have_parent:
                ; _ScanForCluster(parent=D0, target=D1) -> RV_NAMEBUF
                CALLR   _ScanForCluster
                BCS     .bp_err_pop              ; ERR_NOTFOUND/IO
                ; Part 47: D0 = name source (0 = RV_NAMEBUF 8.3, 1 = LFN_ASM
                ; long). _BpLoadDest clobbers D0, so stash it across the call.
                PUSH    D0, XY3                  ; [F] name-source flag
                ; emit '/' before the name, except for the first component
                CALLR   _BpLoadDest
                LOADZB  D0, [#RV_PWD_FIRST]
                AND     D0, #$FF
                BEQ     .bp_firstcomp            ; first component -> no '/'
                LOADI   D0, #'/'
                STOREB  D0, [XY1]+
.bp_firstcomp:
                LOADI   D0, #1
                STOREZB D0, [#RV_PWD_FIRST]      ; later components get a '/'
                POP     D0, XY3                  ; [F]
                CMP     D0, #0
                BEQ.S   .bp_src83
                LOADI   Y0, #$00
                LOADI   X0, #LFN_ASM             ; long name
                BRA.S   .bp_copy
.bp_src83:
                LOADI   Y0, #$00
                LOADI   X0, #RV_NAMEBUF          ; 8.3 name
.bp_copy:
                LOADB   D0, [XY0]+
                AND     D0, #$FF
                CMP     D0, #0
                BEQ     .bp_copydone
                STOREB  D0, [XY1]+
                BRA     .bp_copy
.bp_copydone:
                CALLR   _BpSaveDest
                POP     D0, XY3                  ; [i] restore index
                ; loop with D0 = i (will SUB 1 at top)
                BRA     .bp_emit_loop

.bp_terminate:
                CALLR   _BpLoadDest
                LOADI   D0, #0
                STOREB  D0, [XY1]                ; nul-terminate
                ; reset DIR_WALK_CLU (scan set it)
                LOADI   D0, #0
                STOREZ  D0, [#DIR_WALK_CLU]
                CLC
                RET

.bp_toodeep:
                LOADI   D0, #ERR_INVALID
                BRA.S   .bp_err
.bp_baddrive:
                LOADI   D0, #ERR_BADDRIVE
                BRA.S   .bp_err
.bp_err_pop:
                POP     D1, XY3                  ; discard saved index
                ; fall through
.bp_err:
                PUSH    D0, XY3
                LOADI   D0, #0
                STOREZ  D0, [#DIR_WALK_CLU]
                POP     D0, XY3
                SEC
                RET

; _BpLoadDest / _BpSaveDest — load/store the pwd dest pointer (XY1).
_BpLoadDest:
                LOADZB  D0, [#RV_PWD_Y]
                MOVE    Y1, D0
                LOADZ   D0, [#RV_PWD_X]
                MOVE    X1, D0
                RET
_BpSaveDest:
                MOVE    D0, X1
                STOREZ  D0, [#RV_PWD_X]
                RET


; ============================================================================
; Named-volume / assign-table primitives (named drives v2 — Step 2)
;
;   Pure additive routines: NOTHING calls these yet. Wiring into _ResolveCore
;   happens in Step 3. Kept in this file so that call is an intra-unit CALLR.
;   The assign table lives at AS_TABLE_BASE ($05CE) in kernel page-$00; see
;   kos_fs_defs.inc for the AS_* field layout.
; ============================================================================

; ----------------------------------------------------------------------------
; _AsNameEq — case-insensitive compare: candidate name vs a stored AS_NAME.
;
;   Candidate is ASCIIZ (any case). Stored AS_NAME is 11-byte ASCIIZ (UPPER).
;   Equal iff, with the candidate folded to upper, the two agree byte-for-byte
;   up to and including a shared nul, or across all 11 bytes with no nul (an
;   exactly-11-char name). Both name spaces are page-$00.
;
;   In:    X0 = candidate ASCIIZ offset  (page-$00; Y0 forced $00)
;          X1 = stored AS_NAME offset     (page-$00; Y1 forced $00)
;   Out:   C=0 equal ; C=1 not equal        (6502 sense: CLC=equal, SEC=differ)
;   Clobbers: D0, D1, D2, X0, X1, Y0, Y1, flags
;   Preserves: D3, XY2, XY3
; ----------------------------------------------------------------------------
_AsNameEq:
                LOADI   D0, #$00
                MOVE    Y0, D0                   ; candidate page = $00
                MOVE    Y1, D0                   ; stored    page = $00
                LOADI   D2, #11                  ; field width
.ane_loop:
                LOADB   D0, [XY0]                ; candidate byte
                AND     D0, #$FF
                CALLR   _RvUpper                 ; fold to upper (D0 only)
                LOADB   D1, [XY1]                ; stored byte (already UPPER)
                AND     D1, #$FF
                CMP     D0, D1
                BNE.S   .ane_ne
                CMP     D0, #0                   ; equal — was it a shared nul?
                BEQ.S   .ane_eq                  ;   yes -> full match
                INC     XY0, #1
                INC     XY1, #1
                SUB     D2, #1
                BNE     .ane_loop                ; ran 11 with no nul -> match
.ane_eq:
                CLC
                RET
.ane_ne:
                SEC
                RET

; ----------------------------------------------------------------------------
; _SlotForName — find the assign-table entry matching a candidate name.
;
;   Scans all AS_MAX entries; an entry is occupied iff AS_NAME[0] <> 0, empty
;   ones are skipped. Case-insensitive via _AsNameEq. This is the named-volume
;   analogue of _SlotForDrive and — mirroring that routine's hard lesson — it
;   returns the entry POINTER, never a register-encoded index. (_SlotForDrive
;   leaves D0 = VOL_PRESENT, not the drive; a name probe must not repeat that
;   trap, so the handle here is X1.)
;
;   In:    X0 = candidate ASCIIZ offset (page-$00; any case)
;   Out:   C=0 with X1 = matching entry base offset (page-$00)
;                    D0 = backing drive  (AS_DRIVE, byte)
;                    D1 = mount cluster  (AS_ROOTCLU, word; 0 = backend root)
;          C=1 with D0 = ERR_BADDRIVE   (no match)
;   Clobbers: D0, D1, D2, D3, X0, X1, X2, Y0, Y1, flags
;   Preserves: XY3
; ----------------------------------------------------------------------------
_SlotForName:
                MOVE    D0, X0                   ; stash candidate offset...
                MOVE    X2, D0                   ; ...in X2 (survives _AsNameEq)
                LOADI   D3, #0                   ; entry index
.sfn_loop:
                MOVE    D0, D3                   ; entry base = TABLE + index*16
                SHL     D0, #4
                ADD     D0, #AS_TABLE_BASE
                MOVE    X1, D0
                LOADI   D0, #$00
                MOVE    Y1, D0                   ; page $00
                LOADB   D1, [XY1]                ; AS_NAME[0]
                AND     D1, #$FF
                BEQ.S   .sfn_next                ; empty entry -> skip
                MOVE    D0, X2                   ; restore candidate...
                MOVE    X0, D0                   ; ...into X0 for the compare
                CALLR   _AsNameEq                ; C=0 equal (clobbers X0,X1,D0-D2)
                BCC.S   .sfn_hit                 ; carry clear -> matched
.sfn_next:
                ADD     D3, #1
                CMP     D3, #AS_MAX
                BLO     .sfn_loop                ; index < AS_MAX -> continue
                LOADI   D0, #ERR_BADDRIVE        ; exhausted -> no match
                SEC
                RET
.sfn_hit:
                MOVE    D0, D3                   ; rebuild entry base (X1 clobbered)
                SHL     D0, #4
                ADD     D0, #AS_TABLE_BASE
                MOVE    X1, D0
                LOADI   D0, #$00
                MOVE    Y1, D0                   ; page $00
                LOADB   D0, [XY1+#AS_DRIVE]      ; backing drive (byte)
                AND     D0, #$FF
                LOADD   D1, [XY1+#AS_ROOTCLU]    ; mount cluster (word)
                CLC
                RET


; ============================================================================
; sys_assign — TRAP #78 — create / update / clear a named-volume assign.
;
;   The target path is resolved by the CALLER (kosh, via TRAP_RESOLVE); this
;   syscall only mutates the assign table. Set upserts by name; clear removes
;   by name. Locked entries (ROM:/RAM: system seeds) refuse both.
;
;   In:    XY0 = name (caller page, ASCIIZ; any case)
;          D0  = backing drive index
;          D1  = backing cluster (0 = volume alias / RootClu-0)
;          D2  = AS_FLAGS to store
;          D3  = op: 0 = set, 1 = clear
;   Out:   C=0 ok
;          C=1 with D0 = ERR_INVALID  (name length not 2..11)
;                        ERR_LOCKED   (target entry is a locked seed)
;                        ERR_NOTFOUND (clear of a non-existent assign)
;                        ERR_NOSPACE  (table full on set)
;   Clobbers: D0, D1, D2, D3, X0, X1, X2, Y0, Y1
;   Preserves: XY2, XY3.  DINT / EINT-gated exit (mirrors sys_resolve).
; ============================================================================
sys_assign:
                DINT
                PUSH    XY1, XY3
                PUSH    XY2, XY3
                ; --- stash args to page-$00 (survive copy + _SlotForName) --
                STOREZB D0, [#ASGN_DRV]
                STOREZ  D1, [#ASGN_CLU]
                STOREZB D2, [#ASGN_FLAGS]
                STOREZB D3, [#ASGN_OP]
                ; --- copy name (caller page) -> AS_CAND, UPPER, len 2..11 --
                LOADI   X1, #AS_CAND
                LOADI   Y1, #$00
                LOADI   D2, #0                  ; length
.sa_cpy:
                LOADB   D0, [XY0]               ; src char (caller page)
                AND     D0, #$FF
                BEQ     .sa_cpy_done            ; nul -> end of name
                CMP     D0, #':'                ; trailing ':' also ends the name
                BEQ     .sa_cpy_done
                CALLR   _RvUpper                ; fold to upper (D0)
                CMP     D2, #11
                BHS     .sa_badname             ; > 11 chars -> invalid
                STOREB  D0, [XY1]+              ; AS_CAND[len++]
                INC     XY0, #1
                ADD     D2, #1
                BRA     .sa_cpy
.sa_cpy_done:
                LOADI   D0, #0
                STOREB  D0, [XY1]               ; nul-terminate AS_CAND
                CMP     D2, #2
                BLO     .sa_badname             ; < 2 chars -> invalid
                ; --- look up existing entry by name -----------------------
                LOADI   X0, #AS_CAND
                CALLR   _SlotForName            ; C=0 -> X1=entry (Y1=0)
                BCS     .sa_nomatch
                ; existing entry — refuse if locked.
                LOADB   D0, [XY1+#AS_FLAGS]
                AND     D0, #AS_FLAG_LOCKED
                BNE     .sa_locked
                LOADZB  D0, [#ASGN_OP]
                AND     D0, #$FF
                BNE     .sa_clear_entry         ; op=1 -> clear this entry
                BRA     .sa_write               ; op=0 -> overwrite it
.sa_nomatch:
                LOADZB  D0, [#ASGN_OP]
                AND     D0, #$FF
                BNE     .sa_notfound            ; clear of non-existent -> err
                CALLR   _FirstFreeAssign        ; C=0 -> X1=free entry
                BCS     .sa_nospace
                ; fall through to write
.sa_write:
                ; X1 = target entry (Y1=0). Write name, drive, flags, cluster.
                MOVE    D3, X1                  ; save entry base
                LOADI   X0, #AS_CAND
                LOADI   Y0, #$00
                LOADI   D2, #12                 ; <= 11 chars + nul
.sa_ncpy:
                LOADB   D0, [XY0]+
                AND     D0, #$FF
                STOREB  D0, [XY1]+
                CMP     D0, #0
                BEQ     .sa_nwr
                SUB     D2, #1
                BNE     .sa_ncpy
.sa_nwr:
                MOVE    X1, D3                  ; restore entry base
                LOADI   Y1, #$00
                LOADZB  D0, [#ASGN_DRV]
                STOREB  D0, [XY1+#AS_DRIVE]
                LOADZB  D0, [#ASGN_FLAGS]
                STOREB  D0, [XY1+#AS_FLAGS]
                LOADZ   D0, [#ASGN_CLU]
                STORED  D0, [XY1+#AS_ROOTCLU]
                CLC
                BRA     .sa_ret
.sa_clear_entry:
                LOADI   D0, #0
                STOREB  D0, [XY1]               ; AS_NAME[0] = 0 -> empty
                CLC
                BRA     .sa_ret
.sa_notfound:
                LOADI   D0, #ERR_NOTFOUND
                SEC
                BRA     .sa_ret
.sa_locked:
                LOADI   D0, #ERR_LOCKED
                SEC
                BRA     .sa_ret
.sa_nospace:
                LOADI   D0, #ERR_NOSPACE
                SEC
                BRA     .sa_ret
.sa_badname:
                LOADI   D0, #ERR_INVALID
                SEC
.sa_ret:
                POP     XY2, XY3
                POP     XY1, XY3
                PUSH    SR, XY3
                PUSH    D0, XY3
                LOADZ   D0, [#KERNEL_STATE]
                LOW     D0
                CMP     D0, #KERN_STATE_RUN
                POP     D0, XY3
                BNE.S   .sa_skip_eint
                EINT
.sa_skip_eint:
                POP     SR, XY3
                RET

; ============================================================================
; _FirstFreeAssign — first empty assign entry (AS_NAME[0] == 0).
;   Out: C=0 with X1 = entry base (Y1=$00) ; C=1 if table full.
;   Clobbers: D0, D2, X1, Y1
; ============================================================================
_FirstFreeAssign:
                LOADI   D2, #AS_MAX
                LOADI   X1, #AS_TABLE_BASE
                LOADI   Y1, #$00
.ffa_loop:
                LOADB   D0, [XY1]
                AND     D0, #$FF
                BEQ     .ffa_free
                ADD     X1, #AS_ENTRY_SIZE
                SUB     D2, #1
                BNE     .ffa_loop
                SEC
                RET
.ffa_free:
                CLC
                RET

; ============================================================================
; _AssignInvalidate — mark assigns pointing at (drive, cluster) as dirty.
;   Called when a directory cluster is freed (rmdir). A later NAME: resolve
;   then fails cleanly (ERR_NOTFOUND) instead of landing on the freed cluster.
;   Rootclu-0 volume aliases never match (their cluster is 0, never freed).
;   In:    D0 = drive index, D1 = cluster (freed)
;   Clobbers: D2, D3, X1, Y1, flags
;   Preserves: D0, D1, XY2, XY3
; ============================================================================
_AssignInvalidate:
                LOADI   D3, #AS_MAX
                LOADI   X1, #AS_TABLE_BASE
                LOADI   Y1, #$00
.ainv_loop:
                LOADB   D2, [XY1]               ; AS_NAME[0]
                AND     D2, #$FF
                BEQ     .ainv_next              ; empty entry
                LOADB   D2, [XY1+#AS_DRIVE]
                AND     D2, #$FF
                CMP     D2, D0
                BNE     .ainv_next              ; different drive
                LOADD   D2, [XY1+#AS_ROOTCLU]
                CMP     D2, D1
                BNE     .ainv_next              ; different cluster
                LOADB   D2, [XY1+#AS_FLAGS]
                AND     D2, #$FF
                OR      D2, #AS_FLAG_DIRTY
                STOREB  D2, [XY1+#AS_FLAGS]
.ainv_next:
                ADD     X1, #AS_ENTRY_SIZE
                SUB     D3, #1
                BNE     .ainv_loop
                RET

; ============================================================================
; _AssignInvalidateDrive — mark all path-mount assigns on a drive dirty.
;   Called on format. Volume aliases (AS_ROOTCLU == 0) are kept valid — the
;   drive root survives a format.
;   In:    D0 = drive index
;   Clobbers: D1, D2, D3, X1, Y1, flags
;   Preserves: D0, XY2, XY3
; ============================================================================
_AssignInvalidateDrive:
                LOADI   D3, #AS_MAX
                LOADI   X1, #AS_TABLE_BASE
                LOADI   Y1, #$00
.aivd_loop:
                LOADB   D2, [XY1]
                AND     D2, #$FF
                BEQ     .aivd_next              ; empty entry
                LOADB   D2, [XY1+#AS_DRIVE]
                AND     D2, #$FF
                CMP     D2, D0
                BNE     .aivd_next              ; different drive
                LOADD   D1, [XY1+#AS_ROOTCLU]
                CMP     D1, #0
                BEQ     .aivd_next              ; volume alias -> keep valid
                LOADB   D2, [XY1+#AS_FLAGS]
                AND     D2, #$FF
                OR      D2, #AS_FLAG_DIRTY
                STOREB  D2, [XY1+#AS_FLAGS]
.aivd_next:
                ADD     X1, #AS_ENTRY_SIZE
                SUB     D3, #1
                BNE     .aivd_loop
                RET


; ============================================================================
; End of kos_fs_dir_path.asm
; ============================================================================
