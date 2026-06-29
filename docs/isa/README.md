# K16 ISA — Opcode Decode Grid (WebEMU module)

Self-contained interactive opcode reference. Drops into WebEMU as an "Opcodes"
tab, and also runs standalone via `k16-isa.html`.

## Files (this folder)

| File | Role | Edit? |
|------|------|-------|
| `k16-isa-data.js` | factual layer - `window.K16_OPCODES`, keyed by opcode hex 00-1F | edit to change an instruction |
| `k16-isa-detail.js` | curated layer - `window.K16_OPCODE_DETAIL`, deep popups (CMP so far) | hand-author depth here |
| `k16-isa-grid.js` | renderer - builds the whole UI under a scoped `.isa` root, auto-mounts into any `[data-isa]` element | leave alone |
| `k16-isa.css` | grid styles, all scoped under `.isa`; owns only the `--f-*` family colours; inherits WebEMU base tokens | leave alone |

`../k16-isa.html` is the standalone shell (supplies base tokens, then includes the three JS files).

## How it mounts

`k16-isa-grid.js` exposes `window.K16ISA` and, on load, auto-mounts into every
element carrying `data-isa`. Both hosts just provide an empty container; no host
JS calls are needed beyond showing/hiding the tab. Element IDs are not used - all
DOM is built and queried scoped to the mount, so nothing collides with WebEMU.

## WebEMU integration - four edits

### 1. index.html - stylesheet (after the existing css link, ~line 13)

```html
<link rel="stylesheet" href="css/k16-webemu.css">
<link rel="stylesheet" href="isa/k16-isa.css">
```

### 2. index.html - tab strip (after the `tab-ref` span)

```html
    <span class="tab" id="tab-isa" role="tab" aria-selected="false">
      <svg class="ic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M4 5h16v14H4zM4 9h16M9 9v10"/></svg>Opcodes</span>
```

### 3. index.html - panel (inside `#screenwrap`, after the `refwrap` div closes)

```html
      <div class="isawrap isa" id="isawrap" data-isa style="display:none"></div>
```

### 4. index.html - scripts (after `js/k16-webemu.js`, ~line 272)

```html
<script src="isa/k16-isa-data.js"></script>
<script src="isa/k16-isa-detail.js"></script>
<script src="isa/k16-isa-grid.js"></script>
```

### 5. k16-webemu.js - `selectTab(which)` (~line 460)

Add the aria line beside the other tabs:

```js
  $("tab-isa").setAttribute("aria-selected",String(which==="isa"));
```

Add the display line beside the other panels:

```js
  $("isawrap").style.display = which==="isa" ? "block":"none";
```

And the click handler, beside the other `onclick`s (~line 546):

```js
$("tab-isa").onclick=()=>selectTab("isa");
```

That's the whole seam: a tab, a panel, three includes, three lines of wiring.
The grid mounts itself; `selectTab` only shows and hides it.

## Maintenance

- Change a cycle count / note / mnemonic -> edit `k16-isa-data.js` (one field).
- Add deep detail to an opcode (e.g. SUB) -> append a `"0A": { ... }` block to
  `k16-isa-detail.js`. It renders only where present; everything else stays lean.
- The HTML/CSS/renderer never need touching for content changes.
