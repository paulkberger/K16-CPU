# KGFX Graphics Library — Reference & Status

**Version 0.9 — 10 June 2026**
*Folds the **speed arc** onto v0.7: the new STREAM opcodes (`$02`: `LOADx/STOREx [XYn]+`), fast flag-transparent `INC/DEC XY`, and `MULB` are now used throughout. Depth inner loops stream and word-blast; the scale-1 text renderer was restructured (**B-lite**) to compute the framebuffer row address once per glyph and advance by stride; `vtext_1`'s sub-byte shift collapsed to one `MULB`; `_topbits` became a table; and `gfx_byte1`/`gfx_addr8` traded their shift loops for `MULB`. **v0.9** extends streaming to the Tier-2 blit walks — `vblit_1` source `[XY2]+`, `vblit_8` dest `[XY0]+`/`INC XY`, and `rgn_copy` dual-stream — the groundwork for the live cursor / back-buffer arc.*

A framebuffer graphics library for the K16 / k/OS, written in K16 assembly. Depth-blind geometry over per-surface poke methods dispatched by `CALLXY`. Targets the Pascal emulator (K16EmuIDE) and Digital; runs as ordinary k/OS `.COM` tasks. It is the foundation for the future BeOS-style display server / windowing GUI — pixel framebuffers live outside any user page and will be owned solely by a privileged display-server task; this library is its rendering core.

**Status in one line:** primitives (8bpp + 1bpp, depth-blind geometry, streaming word-blast spans both depths), regions (R1 query + clip, R2 subtract/intersect/union with coalescing), font layer (F3 per-depth row-blit + integer scaling + F4 proportional, region-clipped, full ASCII ModernDOS 8×16 CC0; scale-1 path B-lite + `MULB`), pattern fill (Mac-style 8×8 1bpp, screen-aligned, word-blast), bitmap blit (1bpp mask, Or/Copy/Xor), and double-buffering all complete and EMU-verified on both depths. **The speed arc is EMU-verified functionally but cycle-model only — nothing is cycle-measured; Digital hardware smoke is pending throughout (now including the STREAM/`INC-DEC XY`/`MULB` ISA dependencies).**

---

## 1. Layer architecture

Three layers, strictly separated so pixel depth (bpp) is isolated to the smallest one.

- **Descriptor** — the per-surface record (§3). Holds framebuffer page, geometry, pitch, depth, clip, font, scale, and the poke-method offsets. The only thing that knows a surface's shape.
- **Geometry (depth-independent, written once)** — clipping, Bresenham line, rect→span decomposition, pattern/blit drivers, coordinate validation. Produces spans/rows in (x, y); never computes an address, never knows bpp. Emits only through the descriptor's method vectors.
- **Poke (depth-specific, one set per depth)** — `vspan`, `vclear`, `vtext`, `vpat`, `vblit`. The only layer that turns (x, y) into a 24-bit address via pitch, and the only layer touched when adding a depth. Now physically split into `gfx_1bpp.asm` / `gfx_8bpp.asm` (§2).

**Invariant: pitch and bpp never leak above the poke layer.** Adding a depth is one new `gfx_<depth>.asm` plus one `gfx_open` branch; geometry is untouched. This is the core design property and the reason the same `gfx_line`/`gfx_fillrect`/`gfx_fillpat`/`gfx_blit1`/font draw correctly in 8bpp colour and 1bpp mono with no change.

---

## 2. Files and include order

Naming convention: **`.inc` = definitions/EQUs only, `.asm` = routine code**, `gfx_` prefix.

| File | Contents | Include point |
|------|----------|---------------|
| `gfx_defs.inc` | Descriptor layout, offsets, poke/pattern/blit scratch, param blocks, low-page map (EQUs only) | before `.ORG` |
| `gfx_regions_defs.inc` | Region block/band offsets, `RGN_BSS` work scratch (EQUs only) | before `.ORG` |
| `gfx_font_defs.inc` | Font descriptor offsets, `FNT_BSS` render scratch (EQUs only) | before `.ORG` (after `gfx_defs.inc`) |
| `gfx.asm` | Depth-blind front end: `gfx_open`, dispatch, `setpixel`, `fillrect`/`fillpat`/`fillrow_clipped`/`emitrow`/`patspan`, `line`/`rect`, `blit1` driver | after the program body and data |
| `gfx_1bpp.asm` | 1bpp (mode 1) back end: `vspan_1`, `gfx_rmw1`, `gfx_rmwp`, `gfx_byte1`, `vclear_1`, `vtext_1`, `vpat_1`, `gfx_blitop`, `vblit_1` | after `gfx.asm` |
| `gfx_8bpp.asm` | 8bpp (mode 2) back end: `vspan_8`, `gfx_addr8`, `vclear_8`, `vtext_8`, `vpat_8`, `vblit_8` | after `gfx.asm` |
| `gfx_regions.asm` | Region build/query/algebra | after the program body and data |
| `gfx_font.asm` | Font layer: `gfx_setfont`/`gfx_setfontscale`/`gfx_draw_char`/`gfx_draw_string` (§11) | after the program body and data |

**The depth split (v0.7).** `gfx.asm` grew past 1500 lines, so the per-depth poke routines were lifted out into `gfx_1bpp.asm` / `gfx_8bpp.asm`. The seam is architectural, not arbitrary: the front end is depth-blind and reaches the depth routines *only* via the `LEA` lines in `gfx_open` (the method-vector setup); each depth file is self-contained (calls only its own helpers). Pure relocation — no logic changed.

Because `gfx_open` `LEA`s **both** depths' labels (both mode branches are assembled in), **every gfx harness must include both `gfx_1bpp.asm` and `gfx_8bpp.asm`** regardless of which mode it opens. And because `gfx.asm`'s clip path references region symbols (`rgn_band_at`, `rgn_pt_in`, `BND_*`), any gfx harness must also include both region files. The two-pass assembler resolves the cross-include forward references.

Canonical gfx harness include tail (text harnesses add the two font lines):

```asm
                .INCLUDE "../gfx.asm"
                .INCLUDE "../gfx_1bpp.asm"
                .INCLUDE "../gfx_8bpp.asm"
                .INCLUDE "../gfx_regions.asm"
                .INCLUDE "../gfx_font.asm"        ; text harnesses only
```

Tree layout: library code/defs at the project root (`gfx/`), harnesses in `gfx/Test/`, docs in `gfx/docs/`. Include paths are forward-slash, relative to the file: from `Test/`, `../../kos_defs.inc` (project root), `../gfx_*.inc`/`../gfx_*.asm` (up to `gfx/`). Library routines are reached by forward `CALLR`; the two-pass assembler resolves them and `CALLR` is PC-relative, so placement after the data is fine.

---

## 3. The surface descriptor

A single global record at `GS_BASE` (`$0100`) in the task page. `fb_base` is page-aligned, stored as its high word (`FB_PAGE`). The descriptor is the per-context state (the BView-state idea); it is also what makes double-buffering trivial — flip which descriptor's `fb_page` the renderer reads, no primitive changes.

| Offset | Field | `[XY1+#imm5]` | Meaning |
|--------|-------|---------------|---------|
| `+0` | `GS_FB_PAGE` | 0 | high 16 bits of framebuffer base (e.g. `$00B0`) |
| `+2` | `GS_WIDTH` | `GSO_WIDTH=2` | width in pixels |
| `+4` | `GS_HEIGHT` | `GSO_HEIGHT=4` | height in pixels |
| `+6` | `GS_PITCH` | — | bytes per row |
| `+8` | `GS_BPP` | — | bits per pixel (1, 2, 8) |
| `+10` | `GS_MODE` | — | VID_MODE value |
| `+12` | `GS_VSPAN` | `GSO_VSPAN=12` | `vspan` routine page-offset |
| `+14` | `GS_VCLEAR` | `GSO_VCLEAR=14` | `vclear` routine page-offset |
| `+16` | `GS_CLIP_PG` | `GSO_CLIP_PG=16` | clip region page; `0` = clip to bounds (no region) |
| `+18` | `GS_CLIP_OF` | `GSO_CLIP_OF=18` | clip region offset (valid when `GS_CLIP_PG ≠ 0`) |
| `+20` | `GS_FONT_PG` | `GSO_FONT_PG=20` | current font descriptor page; `0` = no font |
| `+22` | `GS_FONT_OF` | `GSO_FONT_OF=22` | current font descriptor offset |
| `+24` | `GS_VTEXT` | `GSO_VTEXT=24` | `vtext` routine page-offset (font row-blit, §11) |
| `+26` | `GS_FSCALE` | — | integer font scale (1 = 1×, 2 = 2× …); `gfx_open` defaults 1 |
| `+28` | `GS_VPAT` | `GSO_VPAT=28` | `vpat` routine page-offset (pattern fill, §12) |
| `+30` | `GS_VBLIT` | `GSO_VBLIT=30` | `vblit` routine page-offset (bitmap blit, §13) |

`gfx_open` populates the five method vectors (`VSPAN/VCLEAR/VTEXT/VPAT/VBLIT`) per mode via `LEA → MOVE D0,X0 → STOREP`, and zeroes `GS_CLIP_*`/`GS_FONT_*`, defaults `GS_FSCALE=1`.

**`GS_ADDR` (v0.8, `$015E`)** — a sixth row-address method vector (page-offset, page = `Y3`), wired by `gfx_open` to `gfx_byte1` (mode 1) / `gfx_addr8` (mode 2). It lives *outside* the `$0100` descriptor block (so it is reached absolute via `LOADP`, not `[XY1+#imm5]`) because the descriptor's `[XY1+#imm5]` window is full at `+30`. Used once per glyph by the B-lite text path (§11.3) to seed the framebuffer row pointer; the per-row stride is just `GS_PITCH`.

---

## 4. Coordinate system & addressing

Origin top-left, row-major, top-down. All pixel modes are linear within the framebuffer page region at `$B0_0000`.

| | 8bpp (mode 2) | 1bpp (mode 1) |
|---|---|---|
| byte address | `fb_page:0 + y*640 + x` | `fb_page:0 + y*160 + (x>>3)` |
| bit within byte | whole byte | **MSB = leftmost** (`bit 7 of byte 0 = x0`) |
| pitch | 640 | 160 |

**The address multiply (v0.8 — `MULB`).** `y*pitch` is now computed with the byte×byte→16-bit `MULB` instead of a shift-add loop. `y*160` (1bpp) = `MULB(y_lo,160) + (MULB(y_hi,160)<<8)`; `y*640` (8bpp) = `(y*160)<<2` (same `MULB` block + two `ADD/ADC` doublings). A 16-bit `y*pitch` **overflows** (mode-2 row 479 = 306 560), so the product is still built 24-bit and assembled into an XY pair (`Y` = page byte + offset-high, `X` = 16-bit low); the page-crossing carry rides the `ADC` into the high word. `gfx_byte1`/`gfx_addr8` are the only sites that multiply, and the only callers of `MULB`. (Before v0.8 these were `(y<<7)+(y<<5)` / `(y<<9)+(y<<7)` shift-add loops — ~110/130 cyc; the `MULB` form is ~56 and benefits every fill row, every blit, and every text glyph-start.)

---

## 5. Mode table

| Mode | W×H | bpp | pitch | FB bytes | display | poke file | status |
|------|-----|-----|-------|----------|---------|-----------|--------|
| 0 | text | — | — | — | panel collapsed | — | live |
| 1 | 1280×720 | 1 | 160 | 115 200 | 1:1 | `gfx_1bpp.asm` | live |
| 2 | 640×480 | 8 | 640 | 307 200 | 2× → 1280×960 | `gfx_8bpp.asm` | live, **primary** |
| 4 | 1280×720 | 2 | 320 | 230 400 | TBD | (`gfx_2bpp.asm`) | **pending emulator** |

FB base `$B0_0000`, relocatable by VID_PAGE (`$DC_0000`). VID_MODE at `$DD_0000`, mediated by `sys_setvidmode` (TRAP) single-owner model. Mode 4 (2bpp) and a writable CLUT are pending emulator work (§16, §21).

---

## 6. Method vectors (CALLXY dispatch)

Each surface stores the 16-bit **page-offset** of its poke routines. Routines, descriptor, and stack all live in the task page `Y3`, so a method pointer is just an offset; the page byte is always `Y3`. There are **five** in-descriptor vectors: `VSPAN` (solid run), `VCLEAR` (whole-surface fill), `VTEXT` (font glyph row), `VPAT` (pattern run), `VBLIT` (bitmap mask row). (A sixth, `GS_ADDR` — depth row-address, used once per glyph by the B-lite text path — sits outside the descriptor block; §3.)

```asm
                LOADX   X0, [XY1+#GSO_VSPAN]    ; routine page-offset
                MOVE    Y0, Y3                  ; code page
                CALLXY  XY0                     ; -> vspan_<depth>
```

The offset goes into `X0` (an address register), not a `D` register, so all four `D` args reach the poke untouched. `CALLXY` pushes a 24-bit return; the poke returns with plain `RET`. Every poke **preserves `XY1`**.

---

## 7. ABI & register conventions

- **Descriptor in `XY1`** for the whole geometry layer. Every public routine and every poke **preserves `XY1`**.
- **Scalar args in `D0`/`D1`/`D2`** (V2 ABI). Routines with more args use a **task-page param block** (`gr_*` rect/fillrect/pattern, `gl_*` line, `gb_*` blit) — set the slots, then `CALLR`.
- C-flag error return where fallible (6502-style carry: C=1 = no borrow = ≥; state the sense at each call site).
- Single global surface + task-page scratch ⇒ **not re-entrant** (one drawing context per task).

---

## 8. Public API

All take the descriptor in `XY1`.

| Routine | Args | Notes |
|---------|------|-------|
| `gfx_open` | `D0` = mode (1 or 2) | acquires video, populates descriptor + 5 method vectors, inits clip/font off, scale 1; `C=1` on busy |
| `gfx_setclip` | `XY0` = region ptr (`Y0=0` to disable) | sets/clears the clip region; preserves `XY1` |
| `gfx_clear` | `D0` = idx | whole-surface fill (fast word-blast via `vclear`) |
| `gfx_setpixel` | `D0`=x, `D1`=y, `D2`=idx | bounds- and region-clipped |
| `gfx_fillrect` | `gr_x,gr_y,gr_w,gr_h,gr_idx` | per-row emit; one span per visible clip sub-span |
| `gfx_fillpat` | `gr_x..gr_h` + `XY0`=pattern; 8bpp `gp_fg`/`gp_bg` | Mac-style 8×8 pattern fill, clip-aware (§12) |
| `gfx_line` | `gl_x0,gl_y0,gl_x1,gl_y1,gl_idx` | Bresenham; clipped per-pixel via `gfx_setpixel` |
| `gfx_rect` | `gr_x,gr_y,gr_w,gr_h,gr_idx` | outline (4 `gfx_line`) |
| `gfx_blit1` | `XY0`=bitmap; `gb_x..gb_bg` | 1bpp mask blit, modes Or/Copy/Xor, bounds-clipped (§13) |

Text rendering is the **font layer** (`gfx_setfont`/`gfx_setfontscale`/`gfx_draw_char`/`_opaque`/`gfx_draw_string`/`_opaque`) — §11.

### Poke method contracts (depth-specific)

| Method | Args | Contract |
|--------|------|----------|
| `vspan_<d>` | `XY1`, `D0`=x, `D1`=y, `D2`=count, `D3`=idx | solid run; in-bounds assumed (geometry clips) |
| `vclear_<d>` | `XY1`, `D0`=idx | whole-surface fast word-blast |
| `vtext_<d>` | `XY1`, `XY2`=leftmost FB byte, `gs_x`=`fn_dx`, `D2`=rowbits(masked), `D3`=fg | one glyph row; pure poke, all visibility pre-folded; **address preset by caller** (v0.8 B-lite, §11.3) — copies `XY2`→`XY0` internally, preserves `XY2` |
| `vpat_<d>` | `XY1`, `D0`=x, `D1`=y, `D2`=count, `D3`=patrow | patterned run (§12) |
| `vblit_<d>` | `XY1`, `D0`=x, `D1`=py, `D2`=visw; src row in `gb_row_*` | one mask row, mode/fg/bg from `gb_*` (§13) |

---

## 9. The fast 1bpp span (`vspan_1`)

`vspan_1` computes the start byte once (`gfx_byte1`), then: leading partial byte via masked RMW (`gfx_rmw1`); **middle whole bytes word-blast** — build `idx:idx` (`SWAPB`+`OR`), even-align `XY0` with one leading byte (K16 `STORED` needs an even address), then `STORED idx:idx, [XY0]+` for `count/2` words (24-bit auto-carry, register down-counter), then a leftover byte; trailing partial byte via masked RMW. `vspan_8` is the same shape (leading byte if `x` odd, `STORED idx:idx, [XY0]+` middle, trailing byte). The middle is now ~5 cyc / 2 bytes; the streaming `[XY0]+` folds the pointer advance into the store and carries the page boundary in hardware (v0.8 — depends on STREAM `$02`, §21).

---

## 10. Regions & clipping *(R1 + R2, EMU-verified)*

Regions turn KGFX into the basis of a windowing system: an arbitrary pixel set with union/intersection/difference and a clip path so overlapping windows draw only visible pixels (QuickDraw's central idea). Code in `gfx_regions.asm` / `gfx_regions_defs.inc`.

**Representation — band rect-list.** A region is a bbox plus a top-to-bottom sequence of non-overlapping horizontal bands; each band is a y-strip with a sorted set of non-overlapping x-intervals (L,R half-open). Bands sorted ascending in y; coalesced (adjacent bands with identical x-lists merged). API: `rgn_new`, `rgn_set_rect`, `rgn_subtract`/`_intersect`/`_union` (mode-arg band-merge sweep with vertical coalescing), `rgn_copy`, `rgn_band_at`, `rgn_pt_in`, `rgn_is_empty`. `RGN_BSS = $6000` work scratch. Clip integration: `gfx_setclip` stores the region in `GS_CLIP_*`; `gfx_fillrow_clipped` walks the band at each row and emits one span per visible sub-span; `gfx_setpixel` point-tests. **Not re-entrant** (single `RGN_BSS`). Signed coords ≤ 32767 (`$7FFF`/`$8000` are INF sentinels). Rounded corners (R3) future.

---

## 11. Font layer *(F3 row-blit + integer scaling + F4 proportional, EMU-verified both depths)*

Bitmap text over any surface — **depth-blind** and **clipped for free**. Code `gfx_font.asm`, defs `gfx_font_defs.inc`. The F1 per-pixel reference renderer (one `gfx_setpixel` per lit bit) is **gone**, replaced by a per-depth row-blit; proportional (F4) and integer scaling sit on top.

### 11.1 Descriptor

An 11-word descriptor + a contiguous glyph bitmap; glyph for char `c` at `FNT_BITS + (c − FNT_FIRST)*16`, one byte/row, 16 rows, **MSB = leftmost**. Native VGA / pcface layout.

| Off | Field | Meaning |
|----:|-------|---------|
| 0 / 2 | `FNT_FIRST` / `FNT_LAST` | first / last char code (inclusive) |
| 4 / 6 | `FNT_WIDTH` / `FNT_HEIGHT` | cell px (`FNT_WIDTH` = columns scanned, ≤8) |
| 8 | `FNT_ADVANCE` | monospace pen advance |
| 10 | `FNT_ASCENT` | baseline from cell top |
| 12 | `FNT_FLAGS` | bit 0 `FNT_FL_PROP` = proportional (F4) |
| 14 / 16 | `FNT_BITS_PG` / `FNT_BITS_OF` | glyph bitmap base (patched at runtime via `LEA`) |
| 18 / 20 | `FNT_WTAB` / `FNT_OTAB` | F4 width / offset table byte-offsets **relative to the bitmap base** (`0` = mono) |

`FNT_DESC_SIZE = 22`.

### 11.2 API (all take the descriptor in `XY1` and preserve it)

| Routine | Args | Notes |
|---------|------|-------|
| `gfx_setfont` | `XY0` = font desc (`Y0=0` clears) | sets `GS_FONT`, **caches geometry + `fn_scale` + (if prop) WTAB/OTAB bases** into `FNT_BSS`; call after any descriptor edit |
| `gfx_setfontscale` | `D0` = scale (clamped ≥1) | sets `GS_FSCALE` + caches `fn_scale`; independent of `setfont`, takes effect next draw |
| `gfx_draw_char` / `_opaque` | `D0`=x `D1`=y `D2`=ch `D3`=fg / `(bg<<8)\|fg` | transparent / opaque (cell bg then fg); low byte always fg |
| `gfx_draw_string` / `_opaque` | `XY0`=str `D0`=x `D1`=y `D3`=fg / packed | NUL-terminated, single line; pen += per-char advance × scale |

Render scratch `FNT_BSS = $6200` (top `$624A`): per-char loop state, cached geometry, string cursor, F4 per-char `fn_cw`/`fn_dx` and table bases, plus (v0.8) `fn_end` (visible-row clamp end) and `fn_mult` (per-glyph `MULB` shift multiplier). **Not re-entrant.**

### 11.3 F3 — per-depth row blit

`_fn_blit` dispatches on `fn_scale`. The scale-1 path is **B-lite (v0.8)**: it clamps the visible row range once (`start = max(0,−fn_y)`, `end = min(fn_h, H−fn_y)`), pre-skips the glyph by `start`, computes the row-0 framebuffer byte address **once** via `GS_ADDR` into `XY2`, then per row advances `XY2 += GS_PITCH` — eliminating the per-row `y*pitch` recompute that used to happen inside the writer, and dropping the per-row bounds test (the clamp guarantees `py` in range). Each row: fetch `rowbits` (glyph ptr in TLS), build the visible-columns mask with `_fn_rowmask`, `AND` it in, skip if zero, else one `CALLXY [XY1+#GSO_VTEXT]` with `XY2` = the row pointer. **Clip tested once per row, not per pixel.** (The glyph source stays in TLS, reloaded per row, because `_fn_rowmask` clobbers `XY0`; a register-streamed glyph pointer was tried and dropped as net-zero.)

**Depth text pokes (`vtext_8`/`vtext_1`) are pure framebuffer pokes** — bounds- and region-blind, and (v0.8) **address-blind**: the caller presets the row pointer in `XY2`, so they no longer call `gfx_byte1`/`gfx_addr8`. They copy `XY2`→`XY0` and work on `XY0`, leaving `XY2` as the row anchor. `vtext_8` walks 8 columns MSB→LSB writing `fg` where set (set bit → `STOREB [XY0]+`, clear → `INC XY0`). `vtext_1` places the glyph row at `s=(x&7)` into ≤2 framebuffer bytes: when `s>0`, **one `MULB`** computes `V = rowbits << (8−s) = MULB(rowbits, 1<<(8−s))`, and `byte0 = HIGH(V)` (= `rowbits>>s`), `byte1 = LOW(V)` (the spill) drive two `gfx_rmw1` RMWs (`fg=1` sets / `fg=0` clears → inverse text); when `s=0` it is byte-aligned (byte0 = `rowbits`, no spill). The multiplier `fn_mult = (1<<(8−s))<<8` is precomputed once per glyph in `_fn_blit` (`s` is constant across a glyph's rows). This replaced the two O(s) bit-shift loops (~80–96 cyc when `s>0`) with a ~13-cyc constant-time sequence. (Depends on `MULB`, §21.)

`_fn_rowmask` builds `mask` (bit 7 = column 0): **bound** = `topbits(min(fn_w, width − fn_dx))`; with a clip region, intersect the band's sub-spans at `fn_py` (`topbits(col_hi) XOR topbits(col_lo)` OR'd, AND bound). `_topbits` is now (v0.8) a **9-entry `.BYTE` table** + indexed `LOADB` (`$00,$80,$C0,…,$FF`, padded to 10 bytes for word alignment), ~22 cyc constant vs the old bit-loop; it `PUSH/POP`s `XY0` because two call sites use it as the live region cursor. This is what keeps `vtext` dumb.

### 11.4 Integer scaling

`GS_FSCALE` (default 1) + `gfx_setfontscale`. At scale 1 → the F3 row-blit. At scale ≥ 2 → `_fn_blit_scaled`: each set source pixel becomes one `N×N` `gfx_fillrect`, so scaled text **inherits clip/bounds/depth for free** (no `vtext`/mask involvement). Pen advance and opaque cell scale by `N` (`_fn_mulscale`). Clip granularity for scaled text = `N` px (block-level).

### 11.5 F4 — proportional (the QuickDraw strike)

When `FNT_FL_PROP` is set, `gfx_setfont` caches the `WTAB`/`OTAB` base pointers (`bits_base + FNT_WTAB`/`OTAB`, page-carry via `ADC`). Per char, `_fn_setup` looks up advance `w[c]` (`WTAB[c−first]` → `fn_cw`) and signed left bearing `o[c]` (`OTAB[c−first]`, sign-extended). **QuickDraw split:** the *image* is drawn at `fn_dx = fn_x + o[c]` (the render path — `_fn_blit`, `_fn_rowmask`, `_fn_blit_scaled` — reads `fn_dx`); the *pen* advances by `w[c]` (the string loop and opaque cell read `fn_cw`). `fn_x` is never mutated, so pen and image stay separate. `fn_w` (columns scanned) stays the cell width; trailing blank columns cost nothing. Mono fonts (`fn_prop=0`) take a default `fn_cw=fn_adv`, `fn_dx=fn_x` → bit-identical to F3.

Tables are **parallel `.BYTE` arrays** indexed by `(c−FNT_FIRST)` (one width byte, one signed offset byte), read bytewise by `LOADB`, emitted right after the bitmap by `pcface_to_k16.py`. For the auto PC-cell conversion the converter **left-justifies** each glyph (`row << lo`) and sets `w[c]=ink_width+track`, `o[c]=0` — non-negative bearing so opaque proportional works (bg cell at the pen exactly covers the ink). Real Mac strikes can be folded in via a recreation; glyphs wider than 8 px need the (future) 16-bit rowbits path.

### 11.6 As-built decisions

- **`vtext` is a pure poke** — bounds *and* region both fold into one 8-bit mask ANDed into the glyph row.
- **Scaling via `fillrect`, not scaled `vtext`** — keeps the 1× path optimal, reuses the tested clip path.
- **Mono `fg=0` clears** (inverse text) — free through `gfx_rmw1`'s AND-NOT branch.
- **`fn_dx < 0` coarse-skips** the whole glyph (no left-edge clip yet); right/top/bottom clip cleanly.
- **F4 offset = render shift, width = pen advance** (kept separate via `fn_dx`/`fn_cw`).

### 11.7 Verification

FNTTEST3 (mode 1: `s=0`/`s=3` straddle, region cut at x=600, inverse `fg=0`, right-edge, 2× plain/clipped); FNTTEST4 (mode 1 proportional: i-vs-W advance, tight sentence, flush-left tick, region clip, right edge, opaque cells, 2× scaled ±clip); GUIDEMO/GUIPROP (mode 2 `vtext_8`); GUIPROP1280/GUI128 (mode 1, prop + opaque highlight). Digital smoke pending.

---

## 12. Pattern fill *(EMU-verified both depths)*

Mac-style **8×8 1bpp pattern** (8 bytes, one row each, MSB = leftmost), **screen-aligned** so adjacent fills tile seamlessly — the grey-stipple desktop, dotted lines, fill textures. `gfx_fillpat` shares `gfx_fillrect`'s entire clamp + clip path (`_gfx_fill_common`, a `gp_mode` flag); `gfx_fillrow_clipped` emits each row through `gfx_emitrow`, which dispatches solid (`gfx_span`) or pattern (`gfx_patspan`). So **pattern inherits clip + bounds for free**.

`gfx_patspan` looks up `patrow = pattern[y&7]` and dispatches `GS_VPAT` (`D0=x,D1=y,D2=count,D3=patrow`). Depth writers:

- **`vpat_1`** — because the pattern is screen-aligned and 8 px wide, *every full framebuffer byte equals `patrow`*; only the leading/trailing partial bytes need a masked pattern RMW (`gfx_rmwp`: `dest=(dest&~mask)|(patrow&mask)`). Structurally `vspan_1` with the solid middle replaced by `patrow` — and (v0.8) **word-blast + streamed** the same way: `STORED patrow:patrow, [XY0]+` across the even-aligned middle.
- **`vpat_8`** — walks the run pixel-by-pixel writing `gp_fg` where the pattern bit is set, else `gp_bg` (8bpp uses two indices; 1bpp uses the bits literally). Per-pixel; not the hot path.

**API:** set `gr_x/gr_y/gr_w/gr_h`, `XY0` = pattern ptr (8bpp also `gp_fg`/`gp_bg`), `CALLR gfx_fillpat`. Scratch `GP_BSS = $6100`. Verified: PATDEMO (seamless gray across an odd x=645 split → screen-aligned + partial-byte RMW; 75%/25% patterns; diagonal bounded to a clip rect), GUI128 (stipple desktop + striped title bars).

---

## 13. Bitmap blit *(1bpp mask, EMU-verified mode 1)*

A **1bpp mask source** (MSB-first rows, arbitrary W×H, caller-set stride) blitted to either dest depth via `GS_VBLIT`. Three Mac transfer modes: **Or** (transparent — `fg=1` sets / `fg=0` clears where source set), **Copy** (opaque — source set → `fg`, clear → `bg`), **Xor** (toggle where source set; draw twice = erase, the cursor primitive).

`gfx_blit1` (driver) clamps bounds — top rows with `py<0` skipped, `py≥height` stops, visible width right-clamped, `x<0` coarse-skips the whole blit — and dispatches `GS_VBLIT` once per visible row over a running source-row pointer.

- **`vblit_1`** (1bpp dest) — `vtext_1` generalized to any width: per source byte, two shifted RMWs at constant `s=(x&7)` (byte0 = `bits>>s`, byte1 = `bits<<(8−s)`), advancing one dest byte per source byte. The source byte is fetched `LOADB [XY2]+` (v0.9 — fold the per-byte source advance into the load); the dest stays masked RMW via `gfx_blitop` (boundary double-touch is harmless — complementary cover masks), so the dest is *not* streamed. The five sub-byte shift loops remain bit-at-a-time (a `MULB`/table pass like `vtext_1` is deferred).
- **`vblit_8`** (8bpp dest) — walks columns per pixel; set → `fg` (Or/Copy) or `dest^fg` (Xor); clear → `bg` (Copy) or skip. (v0.9) Each store is `STOREB [XY0]+` (fold the advance into the store); a transparent skip advances `INC XY0`; the source byte advances `INC XY2` on each 8-px wrap.

**API:** `XY0` = bitmap; `gb_x/gb_y/gb_w/gb_h/gb_stride/gb_mode/gb_fg/gb_bg`; `CALLR gfx_blit1`. Scratch `GB_BSS = $6120`. Verified: BLITDEMO (Or aligned + shifted x=205, Copy opaque box over gray, Xor on white, **Xor-twice = erased**, right-edge clip, y=−5 top clip). `vblit_8` wired but exercised only when a mode-2 harness blits.

**Scope cut (flagged):** blit is **bounds-clipped, not region-clipped** — an icon inside a region-clipped pane won't yet clip to the region (same "common case now, harden later" posture as the font left-edge). Region-clip-for-blit is the obvious follow-up.

**Future (folds the old "blits & specialisation" design intent):** an 8bpp→8bpp **copy** blit (full-colour sprites/images; word-blast); the **specialisation rule** (resolve any operation-constant flag at the call site into a branch-free routine — a per-word branch is the most expensive thing on an ~11 kHz target); and **LOOKUP** at measured hot sites (`gfx_remap_blit` earns the 128 KB table; convert-blit / fill-word replication are smaller-table candidates).

---

## 14. Double-buffering *(EMU-verified)*

Two full framebuffers in the FB band; draw into the hidden one, flip which page the controller displays. Every poke reads the FB base from `GS_FB_PAGE` each call, so **redirecting all drawing to the hidden buffer is a single descriptor-field write**. Mode-2 8bpp = `$4B000` = 4.6875 pages → a **5-page stride** (`$00B0`/`$00B5`); a 4-page `$B0`/`$B4` stride overlaps and corrupts under full-screen fills. Flip: write the drawn `GS_FB_PAGE` to `VID_PAGE` (`$DC_0000`), then toggle (`XOR #$05`). `gfx_flip` is a ~6-instruction harness routine (policy, not mechanism). **Caveat:** `$B5` is backed RAM on EMU, unconfirmed on Digital/FPGA.

---

## 15. Adding a new depth

1. Write `vspan_<d>`/`vclear_<d>`/`vtext_<d>`/`vpat_<d>`/`vblit_<d>` per the §8 contracts into a new `gfx_<d>.asm`.
2. Add a `gfx_open` branch setting `GS_WIDTH/HEIGHT/PITCH/BPP` and the five method offsets.
3. Add the new file to harness include tails. Geometry and harnesses' logic untouched.

Mode-4 2bpp (1280×720, pitch 320) is next: `vspan_2` reuses the 1bpp sub-byte structure with a 2-bit field; `vclear_2` word-blasts a replicated 2-bit pattern.

---

## 16. Palette model *(deferred — emulator dependency)*

`gfx_set_clut(i,r,g,b)` would take `$00RRGGBB`; `idx` from the poke layer stays a raw index, keeping geometry colour-agnostic. **Current reality:** the emulator's 8bpp palette is a computed function (`VGAColour`, xterm-256: 16 EGA + 6×6×6 + 24 greys), not a writable array. Until a 256-entry palette array + MMIO port (proposed `$DB_0000`) exists, `idx` is the fixed ramp and `gfx_set_clut` is a stub.

---

## 17. Performance assessment & levers

Graphics is slow, and largely **fundamental, not a code defect**: K16 is ~1–3 MIPS (16-bit, 10 MHz target), so framebuffer work is O(pixels) instructions. The v0.7 representative figures (10 MHz; Digital ~11 kHz ≈ 900× slower) were: 8bpp full clear ~92 ms; 1bpp full clear ~35 ms; 1bpp fillrect ~36 ms. **The v0.8 speed arc has cut these substantially** — but every v0.8 figure is **cycle-model estimate, not measured** (no cycle-counter run has been done; see §18). Modelled headline: the per-byte fill middle dropped from ~33 cyc to ~5 cyc/2-bytes (word-blast streaming); the text per-row cost fell with B-lite (no per-row address recompute) + the `MULB` shift + the `_topbits` table; the address routines roughly halved. A full 1280×720 GUI128 repaint models at ~3× the pre-arc time, but that number inherits a soft text-cost trace and **wants measurement to be trusted**.

**Levers, by status:**
1. **Word-optimise spans** *(done, extended in v0.8)* — `STORED idx:idx, [XY0]+` streamed middle on both depths, including 1bpp (was byte-blast). Build every new primitive blast-aware.
2. **Streaming load/store ISA** *(done — was "BlockOps v0.2")*: `LOADx/STOREx [XYn]+` (`$02`), default stride 1 byte / 2 word, 24-bit hardware carry, flag-transparent; plus fast flag-transparent `INC/DEC XY`. Applied to every depth inner loop, and (v0.9) the Tier-2 blit walks (`vblit_1` source, `vblit_8` dest, `rgn_copy` dual-stream — §13). The single biggest "fast at 10 MHz" lever, as predicted. **EMU-confirmed; Digital-pending (§21).**
3. **`MULB` for address + shift** *(done, v0.8)* — replaced the `y*pitch` shift-add loops (`gfx_byte1`/`gfx_addr8`) and the `vtext_1` sub-byte shift loops with byte×byte→16 multiplies. `_topbits` → table.
4. **Per-glyph address + stride (B-lite)** *(done, v0.8)* — compute the FB row address once per glyph via `GS_ADDR`, advance by `GS_PITCH`; the text-fill analogue (`#3a`, per-row address+stride for `gfx_fillrect`) is **deferred** (split-entry `vspan`/`vpat` + new vectors; ~6%).
5. **Hardware blitter / DMA** (the real answer): a state machine doing fills/copies/blits at memory speed; feasible on the Tang FPGA; the display server's offload engine.
6. **FPGA clock:** the 10 MHz ceiling is a TTL artefact; the GW5AST-138B can run several× faster → 5–10× for free.

**Strategic framing:** the GUI fix is not faster pixel loops — it is **not doing full-screen work often** (damage-rectangle discipline via §10 regions + a blitter). "Graphics is slow" becomes a design constraint the BeOS-style architecture already wants.

---

## 18. Verification

EMU smoke passed for every step. **Primitives:** 8bpp/1bpp scenes (identical scene, depth-blind), full-panel edges, fast 1bpp fill, word-opt `vspan_8`. **Regions:** RGNTEST1–7 (no unverified paths). **Font + GUI:** FNTTEST1/2 (F1), FNTTEST3 (F3 mode 1), FNTTEST4 (F4 proportional mode 1), GUIDEMO/GUIMOVE/GUIMOVE2 (mode 2, double-buffer), GUIPROP (mode 2 prop), GUIPROP1280/GUI128 (mode 1 prop + patterns). **Pattern:** PATDEMO, GUI128. **Blit:** BLITDEMO (mode 1). The `gfx_1bpp`/`gfx_8bpp` split is relocation-only (code lines byte-identical to pre-split); re-smoke one mode-1 + one mode-2 harness confirms the includes resolve.

**Digital hardware smoke is pending** for the whole gfx/regions/font/pattern/blit/double-buffer effort — all writes are RAM-target with no ROM-write traps, so no divergence is expected, but it is the unconfirmed half of the discipline. Emulator `DumpFramebuffer()` is the headless verification path.

**v0.8 speed arc — EMU-verified functionally, but cycle-model only.** Each step (Tier-1 streaming, word-blast spans, B-lite text, `vtext_1` `MULB`, `_topbits` table, `gfx_byte1`/`gfx_addr8` `MULB`) passed its EMU smoke ("works / tests pass") on the relevant harnesses (PATDEMO, GUI128, GUIPROP, FNTTEST4, the fill/clear harnesses). **No cycle-counter measurement has been taken** — all speed claims are §15.2 cycle-model estimates, and the `MULB` carry paths were hand-verified at page-crossing rows, not measured. The two open confirmations are therefore: **(1) a cycle-counter run** (draw GUI128 once between two counter reads, pre-arc vs current) to convert the estimates to measured fact, and **(2) Digital smoke** — now also covering the STREAM `$02` / fast `INC/DEC XY` / `MULB` instructions themselves (§21).

---

## 19. Status — done / next

**Done (EMU-verified):** 8bpp + 1bpp pokes; depth-blind geometry; 5-vector `CALLXY` dispatch + `GS_ADDR`; **streaming word-blast spans both depths**; **regions R1 + R2** + clip-aware primitives; **font F3** (per-depth row blit) **+ integer scaling + F4 proportional**, scale-1 path **B-lite** (per-glyph address + `GS_PITCH` stride) + **`MULB` sub-byte shift** + **`_topbits` table**; **pattern fill** (Mac 8×8, both depths, word-blast); **bitmap blit** (1bpp mask, Or/Copy/Xor, bounds-clipped); **double-buffering**; **`MULB` address routines** (`gfx_byte1`/`gfx_addr8`); **`gfx_1bpp`/`gfx_8bpp` split**; **Tier-2 blit streaming** (v0.9 — `vblit_1` source `[XY2]+`, `vblit_8` dest `[XY0]+`/`INC XY`, `rgn_copy` dual-stream). *(Speed arc is functional-EMU only — not cycle-measured; gfx pixel output is EMU-verified by nature, the display-less Digital target confirming only the underlying ISA, §21.)*

**Specified, not built:** `#3a` fill row-address+stride (split-entry `vspan`/`vpat`); regions R3 (rounded corners); 8bpp→8bpp copy blit; mode-4 2bpp. *(Tier-2 blit streaming landed in v0.9 — §13.)*

**Open items:**
- *Confirmation (next):* cycle-counter measurement of the speed arc (§18); **Digital hardware smoke** of the whole stack incl. the STREAM/`INC-DEC XY`/`MULB` ISA.
- *Graphics:* region-clip for blit; 8bpp copy blit + specialisation/LOOKUP (§13); generalise `gfx_rect` to the caller's descriptor; unrolled "pattern vclear"; mode-4 2bpp; writable CLUT; filled circle/ellipse, polyline; rounded-corner regions; **Digital hardware smoke** (whole effort, incl. the `$B5` back-buffer on silicon).
- *Font:* left-edge clip (`fn_dx<0` coarse-skips today); >8 px glyphs (16-bit rowbits path) for real Mac-width strikes; newline / multi-line + cursor model for a console driver; splice the F4 table-emit into `pcface_to_k16.py`.
- *ISA/hardware:* FPGA blitter as the server's offload engine. *(Streaming load/store + fast `INC/DEC XY` + `MULB` landed in v0.8, Tier-2 blit streaming in v0.9 — §17, §13.)*
- *Toward the GUI:* the mailbox / async-port IPC primitive — the pivot from primitives to windowing.

---

## 20. Gotchas

- **1bpp is MSB-first**: bit 7 of byte 0 is x=0. Glyph rows and 1bpp blit masks are MSB-first too.
- **Carry is 6502-style** (SUB/CMP: C=1 = no borrow); state the branch sense aloud. `ADD`/`ADC` are normal carry-out.
- **`y*pitch` must be 24-bit**; streamed loops (`STOREx [XY]+`) carry the page boundary in hardware, but hand-walked pointers still need `ADD X0`/`BCC`/`ADD Y0,#1`. The multiply itself is now `MULB`-based (§4), the only `MULB` callers.
- **Loads and `AND` are flag-transparent** — `CMP` before branching on a freshly loaded/ANDed value. The STREAM ops and `INC/DEC XY` are flag-transparent too.
- **`vclear` clobbers `XY2`**; `vblit_1`/`vblit_8` clobber `XY2` (source pointer). Fine where `XY2` is free. **`rgn_copy` (v0.9) clobbers `XY0`/`XY1`** — it advances both in place for the dual-stream copy (was preserve-XY before v0.9); the band-length walk still uses mode-01 `[XY+D]`.
- **`XY2` is the framebuffer row pointer in the scale-1 text path (v0.8)** — `_fn_blit` holds it across the row loop; `vtext_1`/`vtext_8` read it (copy to `XY0`, preserve `XY2`); `_fn_rowmask` and `rgn_band_at` are relied on to preserve it. Don't repurpose `XY2` inside that loop.
- **Word stores (`STORED`) need an even byte address** — the word-blast fill (`vspan`/`vpat`, both depths) emits one leading byte to align, then `STORED [XY0]+`, then a leftover byte.
- **STREAM `$02` / fast `INC/DEC XY` / `MULB` are ISA dependencies** — EMU-confirmed, **Digital-pending** (§21). Code built since v0.7 will not assemble/run on a toolchain or target without them.
- **`.BYTE` data in the code stream isn't auto-word-aligned** — `topbits_lut` is padded to an even byte count so the following routine stays word-aligned; pad any inline table the same way.
- **`.COM` must not `sys_exit`** while showing graphics — hold instead.
- **Every gfx harness includes both `gfx_1bpp.asm` and `gfx_8bpp.asm`** — `gfx_open` `LEA`s both depths' labels regardless of mode. Plus both region files (clip-path symbols).
- **`gfx_setfont` caches geometry + scale + WTAB/OTAB bases** — call after any descriptor edit. `gfx_setfontscale` updates scale alone (no re-`setfont` needed).
- **F4: offset positions the image (`fn_dx`), width drives the pen (`fn_cw`)** — kept separate; `fn_x` is never mutated. `fn_dx<0` coarse-skips the glyph. Bearing is a signed byte.
- **Pattern is screen-aligned 8×8 1bpp** — every full 1bpp byte = `pattern[y&7]`; only edges RMW. `.BYTE` tables, not `.WORD`.
- **Blit is bounds-clipped, not region-clipped** (yet); `x<0` coarse-skips the whole blit. Xor twice = erase.
- **Region pointers are page:offset, base-relative fields**; a region stays within one heap page; harness dumps of a heap region must use the region's page, not `Y3`.
- **Double-buffer stride must cover a full frame** — mode-2 uses 5-page `$B0`/`$B5`; `$B4` overlaps and corrupts.

---

## 21. Emulator dependencies

| Dep | What | Blocks |
|-----|------|--------|
| A | 256-entry palette array + MMIO index/data port (`$DB_0000`); `VGAColour` indexes it | `gfx_set_clut`/`gfx_load_palette`, fades, palette animation |
| B | mode-4 2bpp plumbing (`SetVideoMode` bound to `[0..4]`, render-loop 2bpp case) | mode 4 / `vspan_2` |

Neither blocks current work; the fixed xterm-256 palette is accepted for 8bpp.

**ISA dependencies (v0.8).** The speed arc relies on three instruction-set features: STREAM `$02` (`LOADx/STOREx [XYn]+`, default stride 1/2, 24-bit carry, flag-transparent), fast flag-transparent `INC/DEC XY` (3/4 cyc), and `MULB Dn` (`hi_byte × lo_byte → 16-bit`). All three are **confirmed present in the assembler and K16EmuIDE** and were used to build everything since v0.7. They are **not yet confirmed on the Digital target** — the two-target rule says they should behave identically (RAM-target, no ROM traps), but that is exactly what the pending Digital smoke (§18) must check. Unlike the palette/mode-4 deps above, these do not *block* further EMU work — but a build for any toolchain or target lacking them will fail.

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 0.1–0.4 | 3–4 June 2026 | Initial reference → consolidation → regions R1+R2 → font F1 + double-buffering. (See prior masters.) |
| 0.5 | 5 June 2026 | **F3 per-depth row-blit** (`GS_VTEXT` + `vtext_8`/`vtext_1` pure pokes, `_fn_rowmask` bounds∩region byte mask, `_topbits`, `_fn_blit` one `CALLXY` per row; per-pixel `gfx_setpixel` renderer removed) + **integer scaling** (`GS_FSCALE`, `gfx_setfontscale`, 1× row-blit / ≥2× `_fn_blit_scaled` fillrect blocks, `_fn_mulscale`). Mono `fg=0` = inverse. Verified FNTTEST3 (mode 1), GUIDEMO (mode 2). *(Was an unfolded delta; merged here.)* |
| 0.6 | 6 June 2026 | **F4 proportional** (QuickDraw strike): `FNT_FL_PROP`; `gfx_setfont` caches WTAB/OTAB bases; `_fn_setup` per-char advance `w[c]`→`fn_cw` + signed bearing `o[c]`→`fn_dx`; render path reads `fn_dx`, pen reads `fn_cw` (offset positions / width advances); mono unchanged. Parallel `.BYTE` tables, bits-relative; `pcface_to_k16.py` left-justifies + emits tables. Verified FNTTEST4 (mode 1), GUIPROP/GUIPROP1280/GUI128. |
| 0.7 | 6 June 2026 | **Pattern fill** (§12 — Mac 8×8 1bpp, screen-aligned; `GS_VPAT` + `vpat_1`/`vpat_8`, `gfx_fillpat` sharing the fillrect clip path via `gfx_emitrow`/`gfx_patspan`, `gfx_rmwp`; PATDEMO/GUI128). **Bitmap blit** (§13 — 1bpp mask, `GS_VBLIT` + `vblit_1`/`vblit_8`, `gfx_blit1` driver, `gfx_blitop`; Or/Copy/Xor; bounds-clipped; BLITDEMO). **Depth split** (§2 — `gfx.asm` → `gfx.asm`/`gfx_1bpp.asm`/`gfx_8bpp.asm`, relocation-only). Descriptor gains `GS_VTEXT/FSCALE/VPAT/VBLIT` (§3); five method vectors (§6); API + poke contracts updated (§8); old "blits design intent" folded into §13; sections renumbered (+2). |
| 0.8 | 9 June 2026 | **Speed arc.** STREAM `$02` (`LOADx/STOREx [XYn]+`) + fast flag-transparent `INC/DEC XY` applied to all depth inner loops; `vspan_1`/`vpat_1` middles upgraded byte-blast → **word-blast streamed** (`STORED idx:idx,[XY0]+`, even-align dance) (§9, §12). **B-lite text** (§11.3): `_fn_blit` scale-1 path computes the FB row address once per glyph via new **`GS_ADDR`** vector (§3, `$015E`), holds it in `XY2`, advances by `GS_PITCH`; visible-row range clamped once; `vtext_1`/`vtext_8` now **address-blind** (FB ptr from `XY2`, no `gfx_byte1`/`addr8` call) — poke contract updated (§8). `vtext_1` sub-byte shift → **one `MULB`** (`byte0=HIGH(V)`, `byte1=LOW(V)`; `fn_mult` precompute). **`_topbits` → 9-entry table** (§11.3). **`gfx_byte1`/`gfx_addr8` → `MULB`** `y*pitch` (§4), replacing the shift-add loops. New BSS `fn_end`/`fn_mult` (FNT_BSS top `$624A`, §11.2). Performance levers re-statused (§17 — streaming/`MULB`/B-lite now *done*). New ISA dependencies STREAM/`INC-DEC XY`/`MULB` (§21) — EMU-confirmed, Digital-pending. **All EMU-verified functionally; none cycle-measured (§18); Digital smoke pending throughout.** Verified: PATDEMO, GUI128, GUIPROP, FNTTEST4, fill/clear harnesses. |
| 0.9 | 10 June 2026 | **Tier-2 blit streaming** (§13, §17, §19, §20). `vblit_1` source byte → `LOADB [XY2]+` (source walk only; dest stays masked-RMW double-touch). `vblit_8` stores → `STOREB [XY0]+`, transparent skip → `INC XY0`, source wrap → `INC XY2`. `rgn_copy` copy loop → `LOADD [XY1]+ / STORED [XY0]+` with a `DEC` word-counter (band-length walk keeps mode-01 `[XY+D]`); **contract change — now clobbers `XY0`/`XY1`** (advanced in place; was preserve-XY), gotcha added (§20). Status lists re-cut: Tier-2 blit streaming moved *specified → done (EMU-verified)*. Deferred, noted in §13: `vblit_1`'s five sub-byte shift loops (`MULB`/table pass) and `vblit_8`'s per-pixel source re-load. BLITDEMO build fixed to include `gfx_font_defs.inc` (depth files carry `vtext_1`'s `fn_mult` ref). **EMU-verified** (BLITDEMO, RGNTEST7); gfx pixel output is EMU-verified by nature — the display-less Digital target confirms only the STREAM/`INC-DEC XY` primitives (already covered). Not cycle-measured. |
