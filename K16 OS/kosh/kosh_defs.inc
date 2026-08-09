; ============================================================================
; kosh_defs.inc - kosh task-page layout and constants (canonical map)
; ============================================================================
; Date:    11 July 2026
; Status:  Part 57 - full task-page refactor. The scattered Part-42..56 layout
;          (LINEBUF/TASKBUF/DIRENTBUFS/PERSHELL, riddled with hand-computed
;          TB_PAD*/PS_PAD* fillers and an 896-word blanket zero-fill that was
;          almost entirely pad) was rebuilt from scratch into three tight,
;          single-purpose regions on a high fixed base. All slots repacked;
;          no address preserved from prior parts (a deliberate re-layout, not
;          a zero-drift move). Every slot is Y3-relative and reached by symbol
;          only - there are no hardcoded task-page addresses anywhere in kosh,
;          so this repack propagates through the whole codebase automatically.
;
; Why the high base ($8000):
;   kosh.com is one upward-growing image from .ORG $0200. Successive parts kept
;   colliding code into buffers parked just above it (Part 40 @ $4020, Part 56
;   LINEBUF @ $5000 inside the $529E image). Parking every buffer at $8000+
;   gives ~32 KB of code runway ($0200..$7FFF) and ends the whack-a-mole. The
;   assembler's '.SPACE kosh' code-in-region guard hard-errors the instant code
;   ever grows into one of these regions, so the headroom is self-policing.
;
; The three regions:
;   KCORE   $8000  persistent shell state (survives across commands; explicitly
;                  initialised at kosh_entry, NOT zeroed).
;   KBUFS   $8100  staging buffers (each written-before-read within a single
;                  command; no init required).
;   KSTATE  $8800  per-command scratch state, grouped by command family;
;                  zero-filled by kosh_entry on each new task (KSTATE_START /
;                  KSTATE_WORDS) so a fresh task page never inherits stale
;                  values. Now ~55 words instead of the old 896.
;
;   $8870-$FDFF  free / kosh stack (grows down from ~$FE00; glob's stack table
;                is SP-relative and stays high, well clear of the regions above)
;   $FFDC-$FFFF  initial fake INT frame + stack region
;
; Include order: pulled in by kosh.asm AFTER kos_fs_defs.inc, because
;   OPEN_FLAGS_NEW depends on FOPEN_* (defined there).
; ============================================================================

.SPACE kosh

; ----------------------------------------------------------------------------
; Value constants (not allocations)
; ----------------------------------------------------------------------------
LINE_BUF_MAX    .EQU    79                  ; sys_gets max length (excl. nul)
; FOPEN_CREATE ($4) | FOPEN_WRITE ($2) | FOPEN_TRUNC ($8) = $E (OR'd at .EQU time)
OPEN_FLAGS_NEW  .EQU    FOPEN_CREATE+FOPEN_WRITE+FOPEN_TRUNC
CAT_BUF_SIZE    .EQU    512                 ; max bytes per sys_read
CP_BUF_SIZE     .EQU    512                 ; cp read/write staging unit
; Part 62: 80, not 16. Derivation - a command line is capped at
; LINE_BUF_MAX (79), so for "cp <src> <dst>" src+dst <= 75; the longest
; thing ever built in a NORM buffer is _KoshResolveDstPath's join,
; dst + "/" + basename(src) + nul, and basename(src) <= src, so the
; join is <= 77 bytes. 80 covers it with the nul and a little slack.
; This is a bound, not a guess - do not shrink it without redoing the
; arithmetic against LINE_BUF_MAX. Enforced by _KoshCopyBounded and by
; the explicit capacity checks in _KoshResolveDstPath.
KOSH_NORM_LEN   .EQU    80                  ; max bytes per KOSH_NORM buffer
KOSH_NORM_LEN_P .EQU    78                  ; = KOSH_NORM_LEN - 2, capacity left
                                            ;   after a 2-byte "X:" drive prefix
; Part 64: 32, not 14. The table now carries the DISPLAY name, which is the
; VFAT long name whenever one exists - LFN_MAX (31) chars + nul = 32. The old
; 14 was 8.3-shaped (12 chars + nul + pad); it was never undersized for that
; purpose, so this is a deliberate widening, not a bug fix.
;
; 32 is also the cheap number: entry offset = index << GLOB_ENTRY_SHIFT is
; SHL4 + SHL - two instructions - against the six-instruction shift/add chain
; that *14 needed at all eight arithmetic sites in kosh_cmds_fs.asm.
;
; Stack cost: the worst-case reservation is GLOB_MAX * GLOB_ENTRY_SIZE, and
; GLOB_MAX is the drive's root_entries, which _ComputeFAT16Layout pins at 32
; (volumes of 1024 sectors or fewer) or 256 (larger) - so the ceiling is
; 256*32 = 8192 bytes against a free stack region of roughly 30 KB
; ($FFF0 task stack top down to the end of KSTATE). One glob is live at a
; time; the reservations never nest.
;
; GLOB_ENTRY_SHIFT and GLOB_ENTRY_SIZE must move together. The code uses the
; SHIFT, spelled as literal SHL4/SHL pairs; the SIZE never appears in an
; instruction operand, because immediate-operand arithmetic on a symbol is
; not attested anywhere in this tree - only .EQU-time folding is.
GLOB_ENTRY_SIZE .EQU    32                  ; bytes per glob table entry (LFN_MAX + nul)
GLOB_ENTRY_SHIFT .EQU   5                   ; log2(GLOB_ENTRY_SIZE) - see above
; Part 62: dirent attrs that _KoshGlobExpand refuses to collect. The glob
; helper feeds cat/rm/cp/mv only - all file operations - so a directory or
; a volume label in the table is always a bug waiting to happen. Named
; because the assembler is only proven to fold arithmetic in .EQU, not in
; an immediate operand.
GLOB_SKIP_ATTR  .EQU    DIR_ATTR_DIRECTORY+DIR_ATTR_VOLUME_LABEL
SCRIPT_MAX_DEPTH .EQU   4                   ; kosh script nesting cap (fd stack size)
; Part 61: per-level script presentation flags (SCRIPT_FLAGS stack).
SCRIPT_FLAG_BRIEF .EQU  $0001               ; -b: join echo + output on one line
SCRIPT_ARROW_LEN  .EQU  4                   ; visible width of msg_brief_arrow
                                            ;   (" -> ") - keep in step with the
                                            ;   string in kosh_script.asm
; cp worker sentinels (D0 with C=1); $8000-range avoids ERR_* (>=$FF00) and
; short-write byte counts (0..512).
CP_ERR_SAMEPATH .EQU    $8001               ; src == dst
CP_ERR_EXISTS   .EQU    $8002               ; dst already exists
MV_WARN_ROSRC   .EQU    $8003               ; mv: copied OK, source r/o (not removed)
CP_ERR_TOOLONG  .EQU    $8004               ; Part 62: joined path exceeds KOSH_NORM_LEN
; Part 64: the HARD counterpart to MV_WARN_ROSRC. Cross-drive mv is
; copy-then-unlink; if the unlink fails for any reason other than a
; read-only source, the copy has already landed and THE FILE NOW EXISTS AT
; BOTH ENDS. That is a different volume state from "the move did not
; happen", and reporting it as a generic mv failure invites the user to
; re-run the mv or delete the wrong copy. The raw kernel code is kept in
; MV_UNLINK_ERR so the report can still name it.
MV_ERR_UNLINK   .EQU    $8005               ; copied OK, source unlink failed

; ----------------------------------------------------------------------------
; KCORE - persistent shell state (survives across commands; not zero-filled).
;   Initialised explicitly at kosh_entry (CWD = 'B', cluster = root).
; ----------------------------------------------------------------------------
KCORE           .REGION $8000
KOSH_CWD         .RS 1w       ; current drive letter (byte; word slot for alignment)
KOSH_CWD_CLU     .RS 1w       ; current directory cluster (0 = root)
CD_BARE          .RS 1w       ; Part 61: how .cd_resolve was entered.
                              ;   0 = explicit `cd <path>` - a non-directory
                              ;       target is an error, report it.
                              ;   1 = bare colon token (ram:boot.ksh) - a
                              ;       non-directory target is an executable,
                              ;       fall through to the exec path.
.ENDREGION

; ----------------------------------------------------------------------------
; KBUFS - staging buffers, each written-before-read within one command.
;   No init required; deliberately NOT part of the zero-fill span.
; ----------------------------------------------------------------------------
KBUFS           .REGION $8100
LINE_BUF         .RS 40w      ; 80 B sys_gets line buffer (LINE_BUF_MAX = 79 excl nul)
ROW_BUF          .RS 48w      ; 96 B shared formatted-output staging
DUMP_ROW         .RS 8w       ; 16 B dump: row source staging
SIZE_FMT_BUF     .RS 8w       ; 16 B size-string work area
KOSH_NORM_A      .RS 40w      ; 80 B path buffer A (= KOSH_NORM_LEN)
KOSH_NORM_B      .RS 40w      ; 80 B path buffer B (= KOSH_NORM_LEN)
CAT_BUF          .RS 257w     ; 513 B sys_read destination (CAT_BUF_SIZE = 512 + nul)
LIST_BUF         .RS 128w     ; 256 B HOST_CMD_LIST output
CP_BUF           .RS 256w     ; 512 B cp read/write staging (CP_BUF_SIZE = 512)
LS_DIRENT_BUF    .RS 32w      ; 64 B ls sys_dirent destination (DIRENT_INFO)
GLOB_DIRENT_BUF  .RS 32w      ; 64 B glob sys_dirent destination (DIRENT_INFO)
.ENDREGION

; ----------------------------------------------------------------------------
; KSTATE - per-command scratch state, grouped by command family.
;   Zero-filled by kosh_entry on each new task (KSTATE_START / KSTATE_WORDS),
;   so a fresh task page never starts on a stale value.
; ----------------------------------------------------------------------------
KSTATE          .REGION $8800
; -- dump (mem) --
DUMP_PAGE        .RS 1w       ; current dump page byte
DUMP_OFFS        .RS 1w       ; current dump offset
DUMP_LEN         .RS 1w       ; bytes remaining
; -- run --
RUN_BG           .RS 1w       ; 0 = foreground, 1 = background
; -- assign --
ASN_NAME_OFF     .RS 1w       ; saved name-token offset
ASN_LIST_IDX     .RS 1w       ; list iteration index
; -- pwd-name (reverse assign map) --
PWDNM_BUF        .RS 1w       ; saved CWD buffer offset
PWDNM_BLEN       .RS 1w       ; best backing-prefix length
PWDNM_BIDX       .RS 1w       ; best assign index ($FFFF = none)
PWDNM_IDX        .RS 1w       ; scan index
; -- ls --
LS_FILE_COUNT    .RS 1w       ; files seen so far
LS_TOTAL_LO      .RS 1w       ; sum of file sizes (low 16)
LS_TOTAL_HI      .RS 1w       ; sum of file sizes (high 16)
LS_SIZE          .RS 1w       ; saved size across _KoshEmitDec
LS_DRIVE         .RS 1w       ; drive across _KoshEmit* calls
LS_INDEX         .RS 1w       ; index across _KoshEmit* calls
LS_CLU           .RS 1w       ; directory cluster to list (0 = root)
LS_ARG_PTR       .RS 1w       ; ls arg offset during parse
LS_RD_ARG        .RS 1w       ; _KoshLsResolveDir: path ptr
LS_RD_OFF        .RS 1w       ; _KoshLsResolveDir: term offset ($FFFF = none)
LS_RD_BYTE       .RS 1w       ; _KoshLsResolveDir: saved byte
LS_RD_DRV        .RS 1w       ; _KoshLsResolveDir: resolved drive
LS_RD_CLU        .RS 1w       ; _KoshLsResolveDir: resolved cluster
LS_RD_ATTR       .RS 1w       ; _KoshLsResolveDir: resolved attr
LS_DIR_COUNT     .RS 1w       ; dirs seen incl . and ..
LS_PAT_PTR       .RS 1w       ; ls wildcard pattern offset ('*' = match-all)
LS_NAMEPTR       .RS 1w       ; Part 64: offset of the display name within
                              ;   LS_DIRENT_BUF - +$20 when a long name is
                              ;   present, else the buffer base (8.3 at +$00).
                              ;   Computed once per entry by _KoshDirentDisplay
                              ;   and used for BOTH the wildcard filter and the
                              ;   row emit. Those two previously disagreed: the
                              ;   filter matched +$00 while the row printed
                              ;   +$20, so `ls Mandel*` found nothing it would
                              ;   then have displayed.
; -- disk (mkdisk) --
DISK_DRIVE       .RS 1w       ; drive index across CALL24s
DISK_SECTORS     .RS 1w       ; sector count for mkdisk
DISK_WALK        .RS 1w       ; LIST_BUF walk offset
; -- cp / mv --
CP_SRC_FD        .RS 1w       ; source fd across CALL24s
CP_DST_FD        .RS 1w       ; destination fd
CP_SRC_PATH      .RS 1w       ; pointer to src path
CP_DST_PATH      .RS 1w       ; pointer to dst path
CP_DSTDRV        .RS 1w       ; glob cp dest drive index (literal paths only
                              ;   from Part 64 step 2 - the glob path no
                              ;   longer builds "<drive>:<name>" by hand)
CP_GDST          .RS 1w       ; Part 64 step 2: the destination token as the
                              ;   user typed it. _KoshResolveDstPath repoints
                              ;   CP_DST_PATH at KOSH_NORM_B for each match,
                              ;   so the original has to be restored at the
                              ;   top of every iteration.
CP_NAME          .RS 1w       ; glob cp current name offset
CP_CWD_CLU       .RS 1w       ; CWD cluster for cp/mv opens
CP_CWD_DRV       .RS 1w       ; CWD drive index for cp/mv
MV_UNLINK_ERR    .RS 1w       ; Part 64: the real ERR_* behind MV_ERR_UNLINK.
                              ;   The sentinel says WHICH outcome occurred;
                              ;   this says why, so the report can carry
                              ;   both. Written only on that one path.
; -- load --
LOAD_NAME        .RS 1w       ; page-offset of name in LINE_BUF (full token,
                              ;   host-folder prefix included)
LOAD_BASENAME    .RS 1w       ; Part 61: offset of the last '/'-separated
                              ;   component of LOAD_NAME - the K16-side
                              ;   destination name, opened with CWD context
                              ;   (Part 62); equals LOAD_NAME when there is
                              ;   no host-folder prefix.
LOAD_FORCE       .RS 1w       ; 0 = refuse on exists, 1 = -f
LOAD_DST_FD      .RS 1w       ; dest fd across host calls
LOAD_SIZE_LO     .RS 1w       ; host file size low  (from _HostFOpen, Part 26)
LOAD_SIZE_HI     .RS 1w       ; host file size high
LOAD_WRITTEN_LO  .RS 1w       ; low 16 of cumulative bytes written
LOAD_WRITTEN_HI  .RS 1w       ; high 16 of cumulative bytes written
LOAD_ERR         .RS 1w       ; stashed err code (D3 unsafe: KLIB clobbers)
; -- vol --
VOL_FREE         .RS 1w       ; free clusters
VOL_TOTAL        .RS 1w       ; total clusters
VOL_CLSZ         .RS 1w       ; cluster size in bytes
; -- glob --
GLOB_DRIVE       .RS 1w       ; drive index being walked
GLOB_INDEX       .RS 1w       ; current dirent index
GLOB_COUNT       .RS 1w       ; matches collected so far
GLOB_MAX         .RS 1w       ; table capacity (root_entries)
GLOB_TABLE       .RS 1w       ; table base offset (stack region)
GLOB_PATPTR      .RS 1w       ; pattern offset (task page)
GLOB_RSVSIZE     .RS 1w       ; reserved stack table size (root_entries*32)
GLOB_CLU         .RS 1w       ; directory cluster being globbed (0 = root)
GLOB_PFXPTR      .RS 1w       ; Part 64 step 2: offset of the glob argument
                              ;   itself, so "<prefix><name>" can be rebuilt
                              ;   per match. Written by _KoshSplitDirPat.
GLOB_PFXLEN      .RS 1w       ; Part 64 step 2: length of the directory part
                              ;   of that argument, INCLUDING its trailing
                              ;   '/' or ':'. 0 when there is none, in which
                              ;   case the shell CWD is the globbed dir.
GLOB_NAMEOFF     .RS 1w       ; Part 64 step 2: offset inside KOSH_NORM_A at
                              ;   which each match's name is appended - i.e.
                              ;   just past the directory prefix, which cp/mv
                              ;   lay down ONCE before the iteration starts.
GLOB_NAMECAP     .RS 1w       ; Part 64 step 2: bytes still free at
                              ;   GLOB_NAMEOFF, including the nul. Passed
                              ;   straight to _KoshCopyBounded, so a long
                              ;   prefix plus a long name fails loudly with
                              ;   CP_ERR_TOOLONG instead of overrunning.
GLOB_NAMEPTR     .RS 1w       ; Part 64: display-name offset within
                              ;   GLOB_DIRENT_BUF (same rule as LS_NAMEPTR).
                              ;   The table always stores the DISPLAY name,
                              ;   even when the pattern only matched via the
                              ;   8.3 fallback - the display name is the one
                              ;   that gets opened, copied and created.
; -- script runner (Part 57+) --
SCRIPT_DEPTH     .RS 1w       ; nesting depth (0 = no script active)
SCRIPT_CHAR      .RS 1w       ; 1-byte sys_read landing slot
SCRIPT_BOOT_DRV  .RS 1w       ; boot cascade cursor (0=inactive, 1=A,2=B,3=C)
SCRIPT_FDS       .RS 4w       ; fd stack (SCRIPT_MAX_DEPTH entries)
SCRIPT_ARROW_COL .RS 1w       ; Part 61: column just after a brief-mode " -> ",
                              ;   or 0 for none pending. _KoshPrintPrompt erases
                              ;   the arrow when the cursor is still sitting on
                              ;   it, i.e. the command printed nothing. 0 is a
                              ;   safe "none" because the guard only consults
                              ;   this when the column is non-zero, so the
                              ;   zero-filled initial state can never match.
SCRIPT_FLAGS     .RS 4w       ; Part 61: per-level presentation flags, parallel
                              ;   to SCRIPT_FDS. Set at push from the invoking
                              ;   line's switches; NOT inherited by nested
                              ;   scripts, which get their own (0 unless they
                              ;   were themselves invoked with a flag).
; -- run args (Part 15) --
RUN_ARG_PTR      .RS 1w       ; cmdline arg-tail offset for sys_exec (0 = none)
.ENDREGION
KSTATE_WORDS    .EQU    KSTATE_SIZE/2       ; words for kosh_entry zero-fill
