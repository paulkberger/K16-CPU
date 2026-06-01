; ============================================================================
; kosh_defs.inc - kosh task-page layout and constants (canonical map)
; ============================================================================
; Date:    1 June 2026
; Status:  Part 42 (prep) - extracted verbatim from kosh.asm r41. All kosh
;          task-page EQUs and constants now live here, mirroring how
;          kos_defs.inc holds the kernel's page-$00 map. No address or value
;          changed in the extraction; this is a pure relocation of the
;          declarations out of the middle of kosh.asm.
;
; Why this file exists:
;   Part 40 was a TASK-PAGE collision bug - kosh.com code grew past the
;   scratch base ($4020) and every `ls` silently clobbered code. The kernel
;   prevents this class in page $00 via a single canonical ZERO PAGE MAP
;   (kos_defs.inc) with all declarations in one include. kosh now has real
;   structured per-task state (esp. the Part 41 $7000-$76FF per-shell
;   region), so it deserves the same discipline: one canonical map, all
;   EQUs in one place.
;
; Include order: pulled in by kosh.asm AFTER kos_fs_defs.inc, because
;   OPEN_FLAGS_NEW depends on FOPEN_* (defined there).
;
; ----------------------------------------------------------------------------
; CANONICAL TASK-PAGE MAP (kosh.com runs at .ORG $0200 in its own task page;
;   all slots below are Y3-relative - Y3 = this task's page register)
; ----------------------------------------------------------------------------
;   $0000-$01FF   OS-reserved task-local slots (kernel-owned):
;                   $0000 MY_TCB_PTR, $0004 TASK_ID  (see kos_defs.inc)
;                 A .com MUST NOT use $0000-$01FF for its own scratch.
;   $0200-~$4480  kosh.com code + data + embedded HELLO.COM / NOTES.TXT
;                   (~17 KB; grows upward - this is the value that collided
;                   with scratch in Part 40)
;   $5000-$504F   LINE_BUF (80 B; LINE_BUF_OFF / LINE_BUF_MAX)
;   $6000-$660D   task-local buffers (foreground-stable, written then read
;                 within one command):
;                   $6000 DUMP_PAGE/OFFS/LEN/ROW, $6020 ROW_BUF,
;                   $6080 LS_DIRENT_BUF, $60AC CAT_BUF, $62B0 LIST_BUF,
;                   $63B8 CP_BUF, $65C0 KOSH_CWD, $65D0 KOSH_NORM_A/B,
;                   $65F8 RUN_BG_TMP, $65FE SIZE_FMT_BUF
;   $7000-$76FF   PER-SHELL working state (Part 41; zero-filled by
;                 kosh_entry on each new task). Each kosh has a private copy,
;                 so concurrent shells cannot corrupt each other. Slots:
;                   $70A0 LS_*, $73B2 DISK_*, $75B8 CP_*_TMP,
;                   $75F0 LOAD_*, $75FA VOL_*_TMP, $760E VOL_CLSZ_TMP,
;                   $7610 LOAD_WRITTEN_*/ERR, $7620 GLOB_*, $764E LS_PAT_PTR
;   $6700-$6FFF   free (buffer growth headroom)
;   $7700-$FDFF   free / kosh stack (grows down from ~$FE00)
;   $FFDC-$FFFF   initial fake INT frame + stack region
;
; TODO (Gotcha #35 mitigation): once the assembler's .IF/.ERROR support and a
;   `kosh_code_end` symbol are confirmed available, add a build-time overlap
;   assertion here, e.g.:
;       .IF (ROW_BUF < kosh_code_end + 256)
;           .ERROR "kosh task-local scratch overlaps kosh.com code"
;       .ENDIF
;   This would have caught the Part 40 collision at assembly time. Left as a
;   comment until the assembler features are verified (do not enable blind).
; ============================================================================


LINE_BUF_OFF    .EQU    $5000               ; line buffer offset within page
                                            ; (r14: was $1000, but the kosh body
                                            ; has grown past $1000 - msg_help
                                            ; overlapped LINE_BUF and the user's
                                            ; typed "help\0" was overwriting
                                            ; msg_help bytes at runtime, causing
                                            ; sys_puts to truncate when it hit
                                            ; the embedded nul. Moved to $5000
                                            ; - clear of the body and clear of
                                            ; the scratch area at $4000..$42A7.)
LINE_BUF_MAX    .EQU    79                  ; sys_gets max length (excl. nul)

; Precomputed open-flags for the boot-time disk populate (r17). The
; assembler evaluates expressions left-to-right but does not accept '|'
; inside a LOADI immediate; we OR the constants here at .EQU time.
;   FOPEN_CREATE ($4) | FOPEN_WRITE ($2) | FOPEN_TRUNC ($8) = $E
OPEN_FLAGS_NEW  .EQU    FOPEN_CREATE+FOPEN_WRITE+FOPEN_TRUNC

; --- kosh-owned scratch in user page ----------------------------------------
;
; History:
;   r12 - placed scratch at $1100. r14 added FS-command scratch and the
;         kosh body grew past $1100, causing scratch to overlap msg_help
;         and other trailing strings. Symptom was sys_puts truncating
;         msg_help at offset ~290.
;
;   r14 - moved all scratch to $4000. Plenty of room above the body
;         (then ~$1B00 bytes); plenty of room below the stack at $FFFE.
;
;   r40 - Part 40: kosh.com migration (Part 39) plus accumulated growth
;         pushed the kosh.com code+data end to ~$4480 (17 KB total).
;         Task-local scratch slots starting at $4020 (ROW_BUF) now
;         OVERLAP THE CODE. Symptom: any command that returned via
;         _KoshSplitDrivePat.sdp_no_prefix after a prior `ls` had its
;         POP-XY0 read garbage because ROW_BUF (written by ls) had
;         overwritten the .sdp_no_prefix code at $4020. The kosh.com
;         layout had grown past the scratch base.
;
;         Fix: bumped all *task-local* scratch slots by +$2000. New
;         base is $6000 — comfortably above the current code end
;         ($~4480) and above LINE_BUF ($5000..$504F). The page-$00
;         (LOADZ/STOREZ) slots stayed at $4xxx in r40 since they lived
;         in kernel page $00, not the task page. (r41 note: those slots
;         have since moved to the task page at $7xxx — see the r41 entry
;         and the $7xxx layout block below. They are no longer page-$00.)
;
; Layout from $6000 (task-local; bytes live in task page):
;   $6000..$6005   DUMP_PAGE / DUMP_OFFS / DUMP_LEN     (was $4000..$4005)
;   $6006..$6015   DUMP_ROW (16 B)                       (was $4006..$4015)
;   $6020..$607F   ROW_BUF (96 B)                        (was $4020..$407F)
;   $6080..$609F   LS_DIRENT_BUF (32 B)                  (was $4080..$409F)
;   $60AC..$62AC   CAT_BUF (513 B)                       (was $40AC..$42AC)
;   $62B0..$63AF   LIST_BUF (256 B)                      (was $42B0..$43AF)
;   $63B8..$65B7   CP_BUF (512 B)                        (was $43B8..$45B7)
;   $65C0..$65C1   KOSH_CWD (byte+pad)                   (was $45C0..$45C1)
;   $65D0..$65EF   KOSH_NORM_A/B (2x16 B)                (was $45D0..$45EF)
;   $65F8          RUN_BG_TMP (1 word)                   (was $45F8)
;   $65FE..$660D   SIZE_FMT_BUF (16 B)                   (was $45FE..$460D)
;
; Per-shell working state at $7xxx (Part 41; task page, addressed via
;                  LOADP/STOREP Y3 — each kosh task has its own private copy.
;                  Zero-filled by kosh_entry on every new task. Old addresses
;                  shown for diff against r40; mapping is OLD + $3000):
;   $70A0..$70AB   LS_FILE_COUNT / LS_TOTAL_LO / LS_TOTAL_HI /
;                  LS_SIZE_TMP / LS_DRIVE_TMP / LS_INDEX_TMP
;   $73B2..$73B7   DISK_DRIVE_TMP / DISK_SECTORS_TMP / DISK_WALK_TMP
;   $75B8..$75BF   CP_SRC_FD_TMP / CP_DST_FD_TMP / CP_SRC_PATH_TMP /
;                  CP_DST_PATH_TMP
;   $75F0..$75F7   LOAD_NAME_TMP / LOAD_FORCE_TMP / LOAD_DST_FD_TMP /
;                  LOAD_SIZE_TMP
;   $75FA..$75FD   VOL_FREE_TMP / VOL_TOTAL_TMP
;   $760E..$7615   VOL_CLSZ_TMP / LOAD_WRITTEN_LO / LOAD_WRITTEN_HI /
;                  LOAD_ERR_TMP
;   $7620..$764F   GLOB_DRIVE / GLOB_INDEX / GLOB_COUNT / GLOB_MAX /
;                  GLOB_TABLE / GLOB_PATPTR / GLOB_DIRENT_BUF (32 B)
;   $7650..$7655   CP_DSTDRV_TMP / CP_NAME_TMP / GLOB_RSVSIZE (= $764C)
;   $764E          LS_PAT_PTR
;
; These were the "multi-shell race risk" set: until r41 they lived in
; kernel page $00 ($40xx-$46xx) as a singleton, so a second kosh task
; would clobber the first's state. r41 moved them into the per-task page
; ($7000-$76FF), making kosh re-entrant. Genuine page-$00 accesses
; elsewhere (kernel API vectors, KOS_VERSION) legitimately remain
; LOADZ/STOREZ and are NOT part of this set.
; ----------------------------------------------------------------------------

; --- Task-local scratch (lives in kosh task page, above kosh.com code) -----

DUMP_PAGE       .EQU    $6000               ; word - current dump page byte
DUMP_OFFS       .EQU    $6002               ; word - current dump offset
DUMP_LEN        .EQU    $6004               ; word - bytes remaining
DUMP_ROW        .EQU    $6006               ; 16 bytes - row source staging

ROW_BUF         .EQU    $6020               ; 96 bytes - formatted output staging

; --- Phase 16.7 FS-command scratch ------------------------------------------
; LS_DIRENT_BUF is task-local (Y3-relative, $6080). The LS_* working set is
; per-shell task-page state at $70xx (r41), accessed via LOADP/STOREP Y3.
LS_DIRENT_BUF   .EQU    $6080               ; 32 B - sys_dirent destination (task-local)
LS_FILE_COUNT   .EQU    $70A0               ; word - files seen so far          (task page, Y3-rel)
LS_TOTAL_LO     .EQU    $70A2               ; word - sum of file sizes (low 16) (task page, Y3-rel)
LS_TOTAL_HI     .EQU    $70A4               ; word - sum of file sizes (high 16)(task page, Y3-rel)
                                            ; Part 22: widened from a single
                                            ; 16-bit LS_TOTAL_BYTES at $40A2;
                                            ; LS_SIZE_TMP was at $40A4 and has
                                            ; moved to $40A6.
LS_SIZE_TMP     .EQU    $70A6               ; word - saved size across _KoshEmitDec (task page, Y3-rel)
LS_DRIVE_TMP    .EQU    $70A8               ; word - drive across _KoshEmit* calls (task page, Y3-rel)
LS_INDEX_TMP    .EQU    $70AA               ; word - index across _KoshEmit* calls (task page, Y3-rel)

CAT_BUF         .EQU    $60AC               ; 513 B - sys_read destination (task-local)
                                            ; (Part 22: bumped from $40AA to
                                            ; $40AC to make room for new
                                            ; LS_TOTAL_HI word.)
                                            ; (Part 40: bumped by +$2000 to
                                            ; clear kosh.com code.)
CAT_BUF_SIZE    .EQU    512                 ; max bytes per sys_read

; --- Part 23 disk-command scratch -------------------------------------------
; LIST_BUF is task-local: HOST_CMD_LIST writes <=256 bytes into the kosh
; task page. DISK_*_TMP slots are per-shell task-page state at $73xx (r41),
; accessed via LOADP/STOREP Y3.
LIST_BUF        .EQU    $62B0               ; 256 B - HOST_CMD_LIST output (task-local)
LIST_BUF_END    .EQU    $63B0               ; one past last byte           (task-local)

DISK_DRIVE_TMP   .EQU   $73B2               ; word - drive index across CALL24s (task page, Y3-rel)
DISK_SECTORS_TMP .EQU   $73B4               ; word - sector count for mkdisk     (task page, Y3-rel)
DISK_WALK_TMP    .EQU   $73B6               ; word - LIST_BUF walk offset        (task page, Y3-rel)

; --- Part 25 cp-command scratch ---------------------------------------------
; CP_BUF is task-local; CP_*_TMP slots are per-shell task-page state at
; $75xx/$76xx (r41), via LOADP/STOREP Y3. CP_BUF read/write staging is one
; cluster (512 B), matching sys_read's natural unit on the
; cluster=1 disks we use.
CP_BUF          .EQU    $63B8               ; 512 B - read/write staging (task-local)
CP_BUF_SIZE     .EQU    512
CP_SRC_FD_TMP   .EQU    $75B8               ; word - source fd across CALL24s    (task page, Y3-rel)
CP_DST_FD_TMP   .EQU    $75BA               ; word - destination fd              (task page, Y3-rel)
CP_SRC_PATH_TMP .EQU    $75BC               ; word - pointer to src path         (task page, Y3-rel)
CP_DST_PATH_TMP .EQU    $75BE               ; word - pointer to dst path         (task page, Y3-rel)
CP_DSTDRV_TMP   .EQU    $7650               ; word - glob cp dest drive index    (task page, Y3-rel)
CP_NAME_TMP     .EQU    $7652               ; word - glob cp current name offset (task page, Y3-rel)

; cp worker error sentinels (returned in D0 with C=1). Chosen to avoid
; collision with both the kernel ERR_* range (>= $FF00) and short-write
; byte counts (0..512): $8000-range is in neither.
CP_ERR_SAMEPATH .EQU    $8001               ; src == dst
CP_ERR_EXISTS   .EQU    $8002               ; dst already exists
MV_WARN_ROSRC   .EQU    $8003               ; mv: copied OK, source on r/o vol (not removed)

; --- Part 25 r4 CWD scratch (task-local, Y3-relative) ----------------------
; KOSH_CWD is the current-drive letter ('B' at boot). Path-taking commands
; prepend "<KOSH_CWD>:" via _KoshNormPath when the user supplies a bare
; filename. Two scratch buffers because cp/mv carry two paths in flight.
; A 16-byte buffer easily fits "X:NNNNNNNN.EEE\0" (14 chars max).
KOSH_CWD        .EQU    $65C0               ; byte - current drive letter
                                            ; (allocate word for alignment)
KOSH_NORM_A     .EQU    $65D0               ; 16 B - normalised path A
KOSH_NORM_B     .EQU    $65E0               ; 16 B - normalised path B
KOSH_NORM_LEN   .EQU    16                  ; max bytes per buffer

; --- Part 25 r6 load-command scratch (per-shell task-page words) -----------
; The load command holds these across CALL24 boundaries (_HostFOpen,
; _KoshNormPath, _HostFRead, _HostFClose, _KoshPrintErr). Per-shell
; task-page state at $75xx (r41), via LOADP/STOREP Y3 — same convention
; as the CP_*_TMP slots.
LOAD_NAME_TMP   .EQU    $75F0               ; word - page-offset of name in LINE_BUF
LOAD_FORCE_TMP  .EQU    $75F2               ; word - 0 = refuse on exists, 1 = -f
LOAD_DST_FD_TMP .EQU    $75F4               ; word - dest fd across host calls
LOAD_SIZE_TMP   .EQU    $75F6               ; word - file size for success msg

; --- Part 25 r7 run-command scratch ----------------------------------------
; RUN_BG_TMP stashes the background flag across TRAP_EXEC. Task-local
; (was page-$00 in earlier wording, but actually used via LOADI X0,#... +
; MOVE Y0,Y3 = task page; the access pattern, not the comment, is what
; matters).
RUN_BG_TMP      .EQU    $65F8               ; word - 0 = foreground, 1 = background (task-local)

; --- Part 34 vol-command scratch (Part 34 disk-free table refit) -----------
; vol now calls sys_diskfree per drive and renders a multi-column table.
; VOL_*_TMP slots are per-shell task-page state at $75xx/$76xx (r41), via
; LOADP/STOREP Y3. SIZE_FMT_BUF is task-local (Y3-relative
; in _KoshEmitSize's build loop).
VOL_FREE_TMP    .EQU    $75FA               ; word - free clusters  (task page, Y3-rel)
VOL_TOTAL_TMP   .EQU    $75FC               ; word - total clusters (task page, Y3-rel)
SIZE_FMT_BUF    .EQU    $65FE               ; 16 B - size-string work area (task-local)
                                            ; (max content "1024.99GB\0" = 10 B;
                                            ;  rounded up for alignment headroom)
VOL_CLSZ_TMP    .EQU    $760E               ; word - cluster size in bytes (task page, Y3-rel)

; --- Part 34 load-command cumulative write counter -------------------------
; Tracks bytes actually written across the load-copy loop so .load_write_err
; can report "wrote N before disk full" with a real cumulative. Initialised
; to 0 at .load_open_dest_for_write; each successful sys_write iteration adds
; D0 (chunk bytes written). On error, this total + sys_write's D1 (partial
; bytes of the failed chunk) = real on-disk size.
; 32-bit because load can pull files up to the bay size (~1MB).
LOAD_WRITTEN_LO  .EQU   $7610               ; word - low 16 bits of cumulative
LOAD_WRITTEN_HI  .EQU   $7612               ; word - high 16 bits of cumulative
LOAD_ERR_TMP     .EQU   $7614               ; word - stashed err code across the
                                            ; .load_write_err preamble build.
                                            ; D3 isn't safe because _KoshEmitSize
                                            ; doesn't preserve D3 (its KLIB
                                            ; callees clobber it).

; --- Part 37 wildcard-glob expander scratch --------------------------------
; State for _KoshGlobExpand's directory walk. Held in memory (not registers)
; because the walk calls sys_dirent and _KoshFnMatch, both of which clobber
; most D/XY registers. Same discipline as .do_ls (LS_DRIVE_TMP etc.).
GLOB_DRIVE       .EQU   $7620               ; word - drive index being walked
GLOB_INDEX       .EQU   $7622               ; word - current dirent index
GLOB_COUNT       .EQU   $7624               ; word - matches collected so far
GLOB_MAX         .EQU   $7626               ; word - table capacity (root_entries)
GLOB_TABLE       .EQU   $7628               ; word - table base offset (stack region)
GLOB_PATPTR      .EQU   $762A               ; word - pattern offset (task page)
GLOB_DIRENT_BUF  .EQU   $762C               ; 32 B - sys_dirent destination
                                            ;        ($462C..$464B)
GLOB_RSVSIZE     .EQU   $764C               ; word - reserved stack table size
                                            ;        (root_entries*14) for release
LS_PAT_PTR       .EQU   $764E               ; word - ls wildcard pattern offset
                                            ;        (task page); points at "*" for
                                            ;        the match-all cases
GLOB_ENTRY_SIZE  .EQU   14                  ; bytes per table entry (13 name + pad)
