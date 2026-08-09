; ============================================================================
; gfx_regions_defs.inc -- KGFX regions: block layout + harness scratch.
; ----------------------------------------------------------------------------
; Include BEFORE .ORG. Region blocks live on the kernel heap (sys_kmalloc),
; one page each; a region "stays within page since payloads are bounded", so
; all field access is X-offset arithmetic within that page (Y never changes).
; Region handle = 24-bit ptr in XY0 (Y0 = heap page byte, X0 = offset).
; Pairs with gfx_regions.asm (routine code, included after the program body).
; ============================================================================

; ----- region block field offsets (relative to region ptr) -----------------
RGN_SIZE        .EQU    0       ; word: capacity bytes (set by rgn_new)
RGN_NBANDS      .EQU    2       ; word: bands in use (0 = empty)
RGN_TOP         .EQU    4       ; word: bbox top
RGN_LEFT        .EQU    6       ; word: bbox left
RGN_BOTTOM      .EQU    8       ; word: bbox bottom (exclusive)
RGN_RIGHT       .EQU    10      ; word: bbox right (exclusive)
RGN_BANDS       .EQU    12      ; first band

; ----- band-relative offsets ------------------------------------------------
BND_YTOP        .EQU    0       ; word: band top (inclusive)
BND_YBOT        .EQU    2       ; word: band bottom (exclusive)
BND_NX          .EQU    4       ; word: x-coord count (even; sorted L,R pairs)
BND_X0          .EQU    6       ; first x-coord; pairs follow
BND_HDR         .EQU    6       ; band header size (ytop,ybot,nx)

; ----- harness scratch (task page, above gfx's $0120-$015A block) -----------
rg_pg           .EQU    $0160   ; saved region page
rg_of           .EQU    $0162   ; saved region offset
; $0164-$01FF is free for per-harness/test scratch (RGW_* moved to $6000).

; ----- region scratch: high BSS, past .com code, below stack ----------------
; Large/working scratch lives here (not in the cramped $0100-$01FF page, which
; holds the gfx descriptor + small vars). $6000 is clear of gfx .com code and
; below the task stack (same zone kosh uses). Relocate via RGN_BSS alone.
RGN_BSS         .EQU    $6000

; Three 1-D interval buffers (A, B, R): count word + CAPN coord words each.
; CAPN = 16 coords = 8 intervals/band. ERR on overflow.
RGW_CAPN        .EQU    16
RGW_A_N         .EQU    RGN_BSS+0     ; A buffer: coord count
RGW_A_X         .EQU    RGN_BSS+2     ; A coords (16 words)
RGW_B_N         .EQU    RGN_BSS+34    ; B buffer: coord count
RGW_B_X         .EQU    RGN_BSS+36    ; B coords (16 words)
RGW_R_N         .EQU    RGN_BSS+68    ; R buffer: coord count (result)
RGW_R_X         .EQU    RGN_BSS+70    ; R coords (16 words)
; 1-D op loop state
RGW_AREM        .EQU    RGN_BSS+102   ; A coords remaining
RGW_BREM        .EQU    RGN_BSS+104   ; B coords remaining
RGW_CUR         .EQU    RGN_BSS+106   ; subtract: current x cursor
RGW_AR          .EQU    RGN_BSS+108   ; subtract: current A-interval right
RGW_OLO         .EQU    RGN_BSS+110   ; union: running interval lo
RGW_OHI         .EQU    RGN_BSS+112   ; union: running interval hi
RGW_OHAVE       .EQU    RGN_BSS+114   ; union: running interval present?

; R2.2 sweep-driver state
RGM_OP          .EQU    RGN_BSS+116   ; op selector: 0=sub 1=isect 2=union
RGM_A_PG        .EQU    RGN_BSS+118   ; A region page / base offset
RGM_A_OF        .EQU    RGN_BSS+120
RGM_B_PG        .EQU    RGN_BSS+122   ; B region
RGM_B_OF        .EQU    RGN_BSS+124
RGM_DST_PG      .EQU    RGN_BSS+126   ; dst region
RGM_DST_OF      .EQU    RGN_BSS+128
RGM_Y           .EQU    RGN_BSS+130   ; current strip top
RGM_YNEXT       .EQU    RGN_BSS+132   ; current strip bottom
RGM_ANEXT       .EQU    RGN_BSS+134   ; A next y-edge > y
RGM_BNEXT       .EQU    RGN_BSS+136   ; B next y-edge > y
RGM_AACT        .EQU    RGN_BSS+138   ; A active band offset ($FFFF = none)
RGM_BACT        .EQU    RGN_BSS+140   ; B active band offset
RGM_WPTR        .EQU    RGN_BSS+142   ; dst next-band write offset
RGM_NB          .EQU    RGN_BSS+144   ; dst band count
RGM_PREV        .EQU    RGN_BSS+146   ; prev emitted band offset ($FFFF = none)
RGM_BB_T        .EQU    RGN_BSS+148   ; dst bbox accumulators
RGM_BB_L        .EQU    RGN_BSS+150
RGM_BB_B        .EQU    RGN_BSS+152
RGM_BB_R        .EQU    RGN_BSS+154
RGM_INF         .EQU    $7FFF         ; +INF sentinel for y-edges
