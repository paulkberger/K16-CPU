; ============================================================================
; boot.ksh - host-side ramdisk manifest (Part 61)
; ============================================================================
; Served from system/ramdisk/ and copied onto B: by A:STARTUP.KSH.
;
; This file IS the manifest: WebEMU fetches it first and derives its prefetch
; set from the `load ramdisk/<n>` lines below, so one new line here is all
; it takes to add a file. Keep the form `load ramdisk/NAME [-f]` - that is
; what the parser matches.
;
; NAMES ARE CASE-SENSITIVE over HTTP. GitHub Pages will 404 a name whose case
; does not match the file on disk, even though the local Windows copy works.
; Match the on-disk filename exactly.
;
; -f throughout so a warm reboot re-populates instead of refusing on exists.
; ----------------------------------------------------------------------------

load ramdisk/zork.com -f
load ramdisk/zork1.z3 -f
load ramdisk/BASIC26.com -f
load ramdisk/FORTH31.com -f
load ramdisk/kedit23.com -f
mkdir gfx
cd gfx
load ramdisk/GUI128F.com -f
load ramdisk/Mandelbrot.com -f
load ramdisk/CUBE6.com -f
cd ..
assign gfx ram:gfx


