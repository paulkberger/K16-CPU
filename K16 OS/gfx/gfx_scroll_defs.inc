; ============================================================================
; gfx_scroll_defs.inc -- KGFX vertical-scroll private scratch (GSC_BSS)
; ============================================================================
; Sibling of gfx_font_defs.inc / gfx_regions_defs.inc. .INCLUDE it alongside
; them. All fields are transient within a single gfx_scroll call.
;
; The row-width split (iters/rem/odd) and the per-row advance are computed ONCE
; in setup and consumed by the shared copy_row / the two direction loops; dof/
; dpg and sof/spg are the dst/src row-start corners (page:offset). gsc_h is the
; height clamped to the surface -- kept local so the caller's gr_h is untouched.
;
; Lives in high BSS after GB_BSS (top ~$6138), clear of FNT_BSS ($6200).
;
; NOTE: pitch and bpp are NOT descriptor offsets -- gfx_scroll reads them from
; the task-page scratch GS_PITCH ($0106) / GS_BPP ($0108) that gfx_open sets,
; exactly as the depth back ends do. Nothing to add to gfx_defs.inc.
; ============================================================================

GSC_BSS         .EQU    $6150
gsc_dir         .EQU    GSC_BSS+0       ; 0 = up (forward rows), 1 = down (reverse)
gsc_n           .EQU    GSC_BSS+2       ; |dv| rows to shift
gsc_rows        .EQU    GSC_BSS+4       ; rows to copy = h - n
gsc_iters       .EQU    GSC_BSS+6       ; 8-word blocks per row (words >> 3)
gsc_rem         .EQU    GSC_BSS+8       ; remainder whole words (words & 7)
gsc_odd         .EQU    GSC_BSS+10      ; trailing odd byte? (wb & 1)
gsc_adv         .EQU    GSC_BSS+12      ; per-row pointer step magnitude (bytes)
gsc_h           .EQU    GSC_BSS+14      ; height clamped to surface (local; gr_h untouched)
gsc_dof         .EQU    GSC_BSS+16      ; dst row pointer  offset
gsc_dpg         .EQU    GSC_BSS+18      ; dst row pointer  page
gsc_sof         .EQU    GSC_BSS+20      ; src row pointer  offset
gsc_spg         .EQU    GSC_BSS+22      ; src row pointer  page
; GSC_BSS top = $6168  (clear of FNT_BSS $6200)
