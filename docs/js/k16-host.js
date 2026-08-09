// k16-host.js — host adapter: wraps a K16Core and presents the front-end's
// expected `Core` surface (reset/step/tty/state/disasm/mem/drawGfx/events/
// loadHex/BASE), plus the I/O seam (disk + keyboard + terminal) and the
// framebuffer renderer and boot loader.
//
// This is the JS equivalent of the parts of frm_main.pas / emu_io_gui.pas /
// emu_disk.pas that the FPC GUI provides around the core. The seven Part-3
// core files stay untouched; this is the only new unit.
//
// Load order: types, cpu, mem, alu, decode, opcodes, core, debug, THEN this file.
//
// Boot mirrors frm_main.LoadAndReset order:
//   1. ROM disk (A:) bytes -> RAM at $FC0000   (read directly by k/OS _BlockReadROM)
//  1b. system/ramdisk set  -> host memory      (Part 61; served to `load ramdisk/x`)
//   2. kernel ROM .hex      -> $FE/$FF          (entry forced to $FF0000)
//   3. reset; caller auto-runs
// A clean public boot is ROM + RAM only: bays C..F start empty (no media).
//
// CARRY/WIDTH discipline lives in the core units; this adapter only moves bytes.

(function (root) {
  'use strict';

  const req       = (typeof require === 'function');
  const K16Core   = req ? require('./k16-core.js')   : root.K16Core;
  const K16Debug  = req ? require('./k16-debug.js')  : root.K16Debug;
  const T         = req ? require('./k16-types.js')  : root.K16Types;

  const {
    ADDR_MASK, RESET_VEC, FB_BASE_DEFAULT,
    KBD_ADDR, TERM_ADDR, TERM_SIZE
  } = T;

  // ---- Disk MMIO (port of emu_disk.pas constants) -------------------------
  const DSK_BASE     = 0xDA0000, DSK_TOP = 0xDA001F;
  const DSK_CMD      = 0xDA0000, DSK_STATUS = 0xDA0002, DSK_DRIVE = 0xDA0004;
  const DSK_LBA_LO   = 0xDA0006, DSK_LBA_HI = 0xDA0008;
  const DSK_BUF_LO   = 0xDA000A, DSK_BUF_HI = 0xDA000C;
  const DSK_SECCOUNT = 0xDA000E, DSK_RESULT = 0xDA0010, DSK_FLAGS = 0xDA0012;
  const DSK_SIZE_HI  = 0xDA0014;   // FOPEN file-size high word (Part 26)
  const DSK_HOST_CMD = 0xDA0016;

  const CMD_NONE=0, CMD_READ=1, CMD_WRITE=2, CMD_IDENT=3,
        CMD_FLUSH=4, CMD_FORMAT=5, CMD_MEDIA=6;

  // Host management commands (port of emu_disk HOST_CMD_*).
  const HOST_CMD_MOUNT=0x0001, HOST_CMD_UNMOUNT=0x0002, HOST_CMD_LIST=0x0003,
        HOST_CMD_CREATE=0x0004, HOST_CMD_DELETE=0x0005, HOST_CMD_RENAME=0x0006,
        HOST_CMD_BAYNAME=0x0007,
        // Part 25 r6 host-file load surface (port of emu_disk). One file open at
        // a time; `load` reads from the web's uploads/ folder (== FPC LoadFolder).
        HOST_CMD_FOPEN=0x0008, HOST_CMD_FREAD=0x0009, HOST_CMD_FCLOSE=0x000A;
  // 16 MB — matches k/OS's 24-bit FD_POSITION. This is a sanity bound, not a
  // transfer limit: FREAD streams to EOF regardless. It was 0x10000 until
  // Part 26, because the k/OS fd layer wrapped its position silently above
  // 64 KB and this cap was the only thing turning that into a clean refusal.
  const HOST_FILE_MAX = 0x1000000;

  const RES_OK=0x0000, RES_NO_MEDIA=0x0001, RES_BAD_LBA=0x0002,
        RES_RO=0x0003, RES_IO_ERR=0x0004, RES_BUSY=0x0005, RES_FULL=0x0006,
        RES_EXISTS=0x0007, RES_NOT_FOUND=0x0008, RES_BAD_NAME=0x0009,
        RES_BAD_SIZE=0x000A, RES_BAD_CMD=0x00FF;

  const SECTOR_SIZE = 512, MAX_DRIVES = 4;
  const MAX_NAME_LEN = 15, MIN_DISK_SECTORS = 64, LIST_BUF_BYTES = 256;

  // FOPEN accepts an optional folder prefix, so its wire name is longer than a
  // bare filename. SEPARATE constant on purpose: MAX_NAME_LEN also clamps
  // _writeStr, and HOST_CMD_BAYNAME writes that back into a kernel buffer the
  // ABI only guarantees as 16 bytes — raising MAX_NAME_LEN would overrun it.
  // The filename AFTER the prefix is still checked against MAX_NAME_LEN.
  const MAX_LOADPATH_LEN = 63;
  const RAMDISK_PREFIX   = 'ramdisk/';    // lower-case; match is case-folded

  // ---- ROM-disk preload (A:) ----------------------------------------------
  const ROMDISK_BASE = 0xFC0000, ROMDISK_SIZE = 131072;

  // Default served paths (Caddy: case-sensitive).
  const SYS_HEX     = 'system/kos_boot.hex';
  const SYS_ROMDISK = 'system/ROMDISK.KOS';

  // Part 61: site-bundled files served to `load ramdisk/<name>`.
  //
  // boot.ksh IS the manifest. A:STARTUP.KSH is a frozen three-line bootstrap
  // that loads and runs it; boot.ksh then names every file in its own
  // `load ramdisk/<name>` lines. Deriving the fetch set from those lines keeps
  // one host-side source of truth — adding a file means one new line in
  // boot.ksh and nothing else. (A separate index would have to be kept in
  // step with it by hand, and would silently rot when it wasn't.)
  const SYS_RAMDISK_DIR  = 'system/ramdisk/';
  const SYS_RAMDISK_BOOT = 'boot.ksh';

  // ---- Keyboard ring (port of emu_io_gui FKbdBuf) -------------------------
  const KBD_BUF_SIZE = 16384, KBD_BUF_MASK = KBD_BUF_SIZE - 1;

  // ---- Framebuffer palette (port of frm_main.VGAColour) -------------------
  // Build a 256-entry RGBA-packed (little-endian: A<<24|B<<16|G<<8|R) table
  // for the standard 16 EGA + 6x6x6 cube + 24-grey VGA palette (modes 2),
  // and a 3-phase-sine rainbow table for mode 3.
  function packRGBA(r, g, b) { return ((0xFF << 24) | (b << 16) | (g << 8) | r) >>> 0; }

  function buildVgaPalette() {
    const EGA = [
      0x000000,0x0000AA,0x00AA00,0x00AAAA, 0xAA0000,0xAA00AA,0xAA5500,0xAAAAAA,
      0x555555,0x5555FF,0x55FF55,0x55FFFF, 0xFF5555,0xFF55FF,0xFFFF55,0xFFFFFF
    ];
    const pal = new Uint32Array(256);
    for (let i = 0; i < 256; i++) {
      let r, g, b;
      if (i < 16) { const c = EGA[i]; r = (c>>16)&0xFF; g = (c>>8)&0xFF; b = c&0xFF; }
      else if (i < 232) { const j = i - 16; r = ((j/36)|0)*51; g = (((j/6)|0)%6)*51; b = (j%6)*51; }
      else { const v = 8 + (i - 232) * 10; r = v; g = v; b = v; }
      pal[i] = packRGBA(r, g, b);
    }
    return pal;
  }

  function buildRainbowPalette() {
    const pal = new Uint32Array(256), TwoPi = 2 * Math.PI;
    for (let i = 0; i < 256; i++) {
      const ph = TwoPi * i / 256.0;
      const r  = Math.round(127.5 + 127.5 * Math.sin(ph));
      const g  = Math.round(127.5 + 127.5 * Math.sin(ph + TwoPi / 3));
      const b  = Math.round(127.5 + 127.5 * Math.sin(ph + 2 * TwoPi / 3));
      pal[i] = packRGBA(r & 0xFF, g & 0xFF, b & 0xFF);
    }
    return pal;
  }

  // ---- Disassembler ------------------------------------------------------
  // Operand decode + text-state formatters live in k16-debug.js (port of
  // emu_debug.pas). _decodeAt below is a thin wrapper over K16Debug.disassemble.

  class K16Host {
    constructor() {
      this.core = new K16Core();
      this._m   = this.core.mem;          // memory object (alias)

      // Terminal output FIFO (filled by writeByte(TERM_ADDR), drained by tty()).
      this._ttyq = [];

      // Keyboard ring.
      this._kbd = new Uint16Array(KBD_BUF_SIZE);
      this._kbdHead = 0; this._kbdTail = 0;

      // Host log (drainEvents()).
      this._evq = [];

      // Disk controller register file (port of emu_disk var block).
      this._dsk = {
        drive: 0, lbaLo: 0, lbaHi: 0, bufLo: 0, bufHi: 0,
        seccount: 1, sizeHi: 0, result: RES_OK, flags: 0
      };
      // Bays: each null (empty) or { name, data:Uint8Array, ro, changed, dirty }.
      this._bays = [null, null, null, null];

      // Drive-activity events for the UI lights: {bay, kind:'read'|'write'}.
      this._diskAct = [];

      // Host disk catalogue (the web's equivalent of emu_disk's disk\ folder):
      // [{ name:UPPERCASE-basename, data:Uint8Array, ro:bool }]. The UI loads
      // this from OPFS and binds bays before boot. Bays share the catalogue
      // entry's `data`, so sector writes mutate the catalogue image in place.
      this._catalogue = [];
      // Fired after any catalogue/bay mutation (mount/unmount/create/delete/
      // rename) so the UI can persist to OPFS and re-render. (sector writes
      // fire onBayDirty.)
      this.onDiskChange = null;

      // Host-file load surface (port of emu_disk LoadFolder). The UI mirrors the
      // Files-tab uploads/ folder in here via loadFilesSet(); `load` reads them
      // through HOST_CMD_FOPEN/FREAD/FCLOSE. Names kept verbatim (extension and
      // case preserved); FOPEN matches case-insensitively. Singleton: one file
      // open at a time, _loadOpen = { name, data, pos } or null.
      this._loadFiles = [];
      this._loadOpen  = null;

      // Part 61: second load set, fetched from the site in boot() and reached
      // via the "ramdisk/" FOPEN prefix. Same element shape as _loadFiles.
      this._ramdiskFiles = [];

      // Framebuffer palettes + offscreen scratch.
      this._palVga     = buildVgaPalette();
      this._palRainbow = buildRainbowPalette();
      this._off = null; this._offW = 0; this._offH = 0;

      // Per-write OPFS flush hook (set by the drive manager; null = no persist).
      this.onBayDirty = null;

      // Install ourselves as the memory I/O handler.
      this._m.io = this;

      this.BASE = RESET_VEC;

      // Terminal geometry provider (Part 15): webemu sets this to return the
      // live vt100 size as (cols<<8)|rows for the TERM_SIZE MMIO read. Null
      // until wired -> readIO falls back to an 80x25 default.
      this.termGeomProvider = null;
    }

    // ======================================================================
    //  Memory I/O seam — readIO / writeIO / writeByte (emu_io_gui contract)
    // ======================================================================
    readIO(addr) {
      if (addr >= DSK_BASE && addr <= DSK_TOP) return this._diskReadIO(addr);
      if (addr === KBD_ADDR) return this._kbdPoll();
      if (addr === TERM_SIZE)                          // Part 15: live term geometry
        return this.termGeomProvider ? (this.termGeomProvider() & 0xFFFF) : ((80 << 8) | 25);
      return 0;
    }

    writeIO(addr, v) {
      if (addr >= DSK_BASE && addr <= DSK_TOP) { this._diskWriteIO(addr, v & 0xFFFF); return; }
      // VID_MODE / VID_PAGE are handled in k16-mem before this is called.
      // TERM is byte-write only (see writeByte) — word writes to TERM are
      // dropped here exactly as in emu_io_gui.WriteIO.
    }

    writeByte(addr, v) {
      if (addr === TERM_ADDR) { this._ttyq.push(v & 0xFF); return; }
      // Disk MMIO is word-addressed; byte writes into the range are ignored,
      // matching emu_io_gui (no WriteByte case for the disk range).
    }

    // ======================================================================
    //  Keyboard — emu_io_gui QueueKey / KbdPoll
    // ======================================================================
    queueKey(code) {
      code &= 0xFFFF;
      if (code === 0) return;                 // NUL is the empty sentinel
      if (((this._kbdTail + 1) & KBD_BUF_MASK) === this._kbdHead) return; // full: drop newest
      this._kbd[this._kbdTail] = code;
      this._kbdTail = (this._kbdTail + 1) & KBD_BUF_MASK;
    }

    enqueueString(s) {
      for (let i = 0; i < s.length; i++) {
        const ch = s.charCodeAt(i);
        if (ch === 10 || ch === 13) this.queueKey(13);       // LF/CR -> CR
        else if (ch === 9) this.queueKey(9);                 // Tab
        else if (ch >= 32 && ch <= 126) this.queueKey(ch);   // printable
      }
    }

    _kbdPoll() {
      if (this._kbdHead === this._kbdTail) return 0;
      const r = (0x8000 | this._kbd[this._kbdHead]) & 0xFFFF;  // bit15 = data-present
      this._kbdHead = (this._kbdHead + 1) & KBD_BUF_MASK;
      return r;
    }

    // Map a DOM keydown event to the byte sequence k/OS expects (1:1 port of
    // emu_terminal.DoKeyDown + DoKeyPress). Returns an array of byte codes to
    // queue (handled — caller should preventDefault), or null (let the browser
    // keep the combo, e.g. Ctrl-A/C/V for select/copy/paste).
    //
    // Foreground-switcher hot keys (k/OS Phase B):
    //   next shell  $0E : Ctrl-N  or Ctrl-Right
    //   prev shell  $10 : Ctrl-P, Ctrl-Shift-N, or Ctrl-Left
    //   shell 1..10 $81..$89,$8A : Ctrl-1..9, Ctrl-0
    // NOTE: in a browser Ctrl-N / Ctrl-Shift-N (new/incognito window) and
    // Ctrl-digit (tab switch) are often hijacked by the host; Ctrl-Left/Right
    // are the dependable switchers.
    keyEventToBytes(e) {
      const k = e.key, ctrl = !!e.ctrlKey, shift = !!e.shiftKey,
            alt = !!e.altKey, meta = !!e.metaKey;

      switch (k) {
        case 'ArrowRight': return ctrl ? [0x0E] : [27, 0x5B, 0x43];  // next / ESC[C
        case 'ArrowLeft':  return ctrl ? [0x10] : [27, 0x5B, 0x44];  // prev / ESC[D
        case 'ArrowUp':    return [27, 0x5B, 0x41];                  // ESC[A
        case 'ArrowDown':  return [27, 0x5B, 0x42];                  // ESC[B
        case 'Enter':      return [13];
        case 'Backspace':  return [8];
        case 'Escape':     return [27];
        case 'Tab':        return [9];
      }

      if (ctrl && !alt && !meta) {
        if (k === ' ' || k === 'Spacebar') return [0x0E];  // Ctrl-Space = cycle next shell
        const u = (k.length === 1) ? k.toUpperCase() : k;
        if (u === 'N') return [shift ? 0x10 : 0x0E];       // Ctrl-N / Ctrl-Shift-N
        if (u === 'P') return [0x10];                       // Ctrl-P = prev
        if (u >= '1' && u <= '9') return [0x80 + (u.charCodeAt(0) - 0x30)];
        if (u === '0') return [0x8A];
        // Any other Ctrl-letter -> its control byte (Ctrl-A=1 .. Ctrl-Z=26), so
        // k/OS programs (e.g. the text editor) can bind Ctrl keys. feedKeyToCore
        // preventDefaults, suppressing the browser's own Ctrl-S/O/F/... while the
        // emulator has focus. Ctrl-A and Ctrl-C/X/V (with a selection) are taken
        // by the terminal's clipboard handler upstream, so they don't reach here.
        // Browser-reserved combos (Ctrl-W close tab, Ctrl-T new tab, Ctrl-N new
        // window) can't be suppressed and won't arrive — don't bind commands to them.
        if (u.length === 1 && u >= 'A' && u <= 'Z') return [u.charCodeAt(0) & 0x1F];
        return null;   // non-letter Ctrl-combos: leave to the browser
      }

      if (!ctrl && !alt && !meta && k.length === 1) {
        const c = k.charCodeAt(0);
        if (c >= 32 && c <= 126) return [c];                // printable (DoKeyPress)
      }
      return null;
    }

    // ======================================================================
    //  Disk controller (port of emu_disk DiskReadIO/DiskWriteIO + ops)
    // ======================================================================
    _curLBA()     { return ((this._dsk.lbaHi << 16) | this._dsk.lbaLo) >>> 0; }
    _curBufAddr() { return (((this._dsk.bufHi << 16) | this._dsk.bufLo) & ADDR_MASK) >>> 0; }

    _diskReadIO(addr) {
      const d = this._dsk;
      switch (addr) {
        case DSK_CMD:      return 0;
        case DSK_STATUS:   return 0;                 // never busy (sync)
        case DSK_DRIVE:    return d.drive;
        case DSK_LBA_LO:   return d.lbaLo;
        case DSK_LBA_HI:   return d.lbaHi;
        case DSK_BUF_LO:   return d.bufLo;
        case DSK_BUF_HI:   return d.bufHi;
        case DSK_SECCOUNT: return d.seccount;
        case DSK_SIZE_HI:  return d.sizeHi;
        case DSK_RESULT:   return d.result;
        case DSK_FLAGS:    return d.flags;
        default:           return 0;
      }
    }

    _diskWriteIO(addr, v) {
      const d = this._dsk;
      switch (addr) {
        case DSK_DRIVE:    d.drive = v & 0x0003; break;
        case DSK_LBA_LO:   d.lbaLo = v; break;
        case DSK_LBA_HI:   d.lbaHi = v & 0x00FF; break;
        case DSK_BUF_LO:   d.bufLo = v; break;
        case DSK_BUF_HI:   d.bufHi = v & 0x00FF; break;
        case DSK_SECCOUNT: d.seccount = v; break;
        case DSK_FLAGS:    d.flags = v; break;
        case DSK_CMD:
          switch (v) {
            case CMD_READ:   this._doRead();   break;
            case CMD_WRITE:  this._doWrite();  break;
            case CMD_IDENT:  this._doIdent();  break;
            case CMD_FLUSH:  d.result = RES_OK; break;
            case CMD_FORMAT: this._doFormat(); break;
            case CMD_MEDIA:  this._doMedia();  break;
            case CMD_NONE:   break;
            default:         d.result = RES_BAD_CMD; break;
          }
          break;
        case DSK_HOST_CMD:
          switch (v) {
            case HOST_CMD_MOUNT:   this._doHostMount();   break;
            case HOST_CMD_UNMOUNT: this._doHostUnmount(); break;
            case HOST_CMD_LIST:    this._doHostList();    break;
            case HOST_CMD_CREATE:  this._doHostCreate();  break;
            case HOST_CMD_DELETE:  this._doHostDelete();  break;
            case HOST_CMD_RENAME:  this._doHostRename();  break;
            case HOST_CMD_BAYNAME: this._doHostBayName(); break;
            case HOST_CMD_FOPEN:   this._doHostFOpen();   break;
            case HOST_CMD_FREAD:   this._doHostFRead();   break;
            case HOST_CMD_FCLOSE:  this._doHostFClose();  break;
            default:               this._dsk.result = RES_BAD_CMD; break;
          }
          break;
      }
    }

    _validBay() {
      const d = this._dsk;
      if (d.drive >= MAX_DRIVES) { d.result = RES_NO_MEDIA; return null; }
      const bay = this._bays[d.drive];
      if (!bay) { d.result = RES_NO_MEDIA; return null; }
      return bay;
    }

    _doRead() {
      const d = this._dsk, bay = this._validBay(); if (!bay) return;
      const lba = this._curLBA(), buf = this._curBufAddr();
      const sz = (bay.data.length / SECTOR_SIZE) | 0;
      if (lba + d.seccount > sz) { d.result = RES_BAD_LBA; return; }
      const M = this._m.mem, src = bay.data;
      const srcBase = lba * SECTOR_SIZE, n = d.seccount * SECTOR_SIZE;
      for (let i = 0; i < n; i++) M[(buf + i) & ADDR_MASK] = src[srcBase + i];
      d.result = RES_OK;
      this._diskAct.push({ bay: d.drive, kind: 'read' });
    }

    _doWrite() {
      const d = this._dsk, bay = this._validBay(); if (!bay) return;
      if (bay.ro) { d.result = RES_RO; return; }
      const lba = this._curLBA(), buf = this._curBufAddr();
      const sz = (bay.data.length / SECTOR_SIZE) | 0;
      if (lba + d.seccount > sz) { d.result = RES_BAD_LBA; return; }
      const M = this._m.mem, dst = bay.data;
      const dstBase = lba * SECTOR_SIZE, n = d.seccount * SECTOR_SIZE;
      for (let i = 0; i < n; i++) dst[dstBase + i] = M[(buf + i) & ADDR_MASK];
      bay.dirty = true;
      d.result = RES_OK;
      this._diskAct.push({ bay: d.drive, kind: 'write' });
      if (this.onBayDirty) this.onBayDirty(d.drive, bay);   // debounced OPFS flush
    }

    _doIdent() {
      const d = this._dsk, bay = this._validBay();
      if (!bay) { d.seccount = 0; d.flags = 0; return; }
      const sz = (bay.data.length / SECTOR_SIZE) | 0;
      d.seccount = sz > 0xFFFF ? 0xFFFF : sz;
      d.flags = 0x0001 | (bay.ro ? 0x0002 : 0);
      bay.changed = false;
      d.result = RES_OK;
    }

    _doFormat() {
      const d = this._dsk, bay = this._validBay(); if (!bay) return;
      if (bay.ro) { d.result = RES_RO; return; }
      bay.data.fill(0);
      bay.dirty = true;
      d.result = RES_OK;
      this._diskAct.push({ bay: d.drive, kind: 'write' });
      if (this.onBayDirty) this.onBayDirty(d.drive, bay);
    }

    _doMedia() {
      const d = this._dsk;
      if (d.drive >= MAX_DRIVES) { d.result = RES_NO_MEDIA; return; }
      const bay = this._bays[d.drive];
      d.flags = 0;
      if (bay) {
        d.flags |= 0x0001;
        if (bay.ro) d.flags |= 0x0002;
        if (bay.changed) d.flags |= 0x0004;
        bay.changed = false;
      }
      d.result = RES_OK;
    }

    // ---- Host catalogue + bay-management (port of emu_disk Host*) ----------
    // String marshalling against K16 RAM (ASCIIZ, MAX_NAME_LEN cap).
    _readStr(addr, maxLen) {
      const M = this._m.mem; let s = '';
      for (let i = 0; i < maxLen; i++) {
        const ch = M[(addr + i) & ADDR_MASK];
        if (ch === 0) break;
        s += String.fromCharCode(ch);
      }
      return s;
    }
    _writeStr(addr, s) {
      const M = this._m.mem, n = Math.min(s.length, MAX_NAME_LEN);
      for (let i = 0; i < n; i++) M[(addr + i) & ADDR_MASK] = s.charCodeAt(i) & 0xFF;
      M[(addr + n) & ADDR_MASK] = 0;
    }
    // NormaliseName: uppercase, strip a trailing .KOS. ValidName: A-Z 0-9 _, 1..15.
    _normaliseName(s) {
      s = (s || '').trim().toUpperCase();
      if (s.length > 4 && s.slice(-4) === '.KOS') s = s.slice(0, -4);
      return s;
    }
    _validName(s) {
      if (!s || s.length > MAX_NAME_LEN) return false;
      return /^[A-Z0-9_]+$/.test(s);
    }
    _catFind(name) { return this._catalogue.find(e => e.name === name) || null; }
    _bayOfName(name) {
      for (let i = 0; i < MAX_DRIVES; i++) if (this._bays[i] && this._bays[i].name === name) return i;
      return -1;
    }
    _changed() { if (this.onDiskChange) this.onDiskChange(this.getDiskState()); }

    // Public catalogue API (UI calls these; both UI buttons and kosh commands
    // converge on hostMount/hostUnmount/... below).
    diskCatalogueSet(list) {
      this._catalogue = (list || []).map(e => ({
        name: this._normaliseName(e.name), data: e.data, ro: !!e.ro
      })).filter(e => this._validName(e.name) && e.data);
    }
    getDiskState() {
      return {
        catalogue: this._catalogue.map(e => ({ name: e.name, size: e.data.length, ro: e.ro })),
        bays: this._bays.map(b => b ? b.name : null)
      };
    }
    // Live catalogue with shared data refs (UI uses this to render + persist OPFS).
    catalogueImages() {
      return this._catalogue.map(e => ({ name: e.name, data: e.data, ro: e.ro }));
    }

    // ---- Host-file load surface (port of emu_disk HostFOpen/FRead/FClose) ---
    // Public: UI mirrors the uploads/ folder in here. `data` is a Uint8Array.
    // Names kept verbatim. Replacing the set does NOT disturb an open file
    // (kosh always FCLOSEs); a stale handle simply keeps serving its snapshot.
    loadFilesSet(list) {
      this._loadFiles = (list || [])
        .filter(e => e && e.name && e.data)
        .map(e => ({ name: String(e.name), data: e.data }));
    }
    loadFiles() {
      return this._loadFiles.map(e => ({ name: e.name, size: e.data.length }));
    }

    // Part 61: the site-bundled ramdisk set. Normally filled by boot(); exposed
    // so a front-end can override or inspect it.
    ramdiskFilesSet(list) {
      this._ramdiskFiles = (list || [])
        .filter(e => e && e.name && e.data)
        .map(e => ({ name: String(e.name), data: e.data }));
    }
    ramdiskFiles() {
      return this._ramdiskFiles.map(e => ({ name: e.name, size: e.data.length }));
    }

    // FOPEN: case-insensitive basename lookup in a load set. Returns a result
    // code; on RES_OK, size = file length (up to HOST_FILE_MAX).
    //
    // Part 61 — an optional single "ramdisk/" prefix selects the site-bundled
    // set instead of the uploads set:
    //     load zork.com           -> uploads folder
    //     load ramdisk/zork.com   -> system/ramdisk folder
    // The prefix is stripped FIRST and what remains is validated exactly as a
    // bare filename — still no '/', '\', ':' or '..', still capped at
    // MAX_NAME_LEN. One fixed prefix, no path walking, so traversal stays
    // impossible without any path-normalisation logic.
    //
    // RES_BUSY (already open) / RES_BAD_NAME (empty / >15 / path chars) /
    // RES_NOT_FOUND / RES_FULL (> 16 MB).
    hostFOpen(name) {
      if (this._loadOpen) return { res: RES_BUSY, size: 0 };
      name = (name || '').trim();

      let set = this._loadFiles, where = '';
      if (name.slice(0, RAMDISK_PREFIX.length).toLowerCase() === RAMDISK_PREFIX) {
        name = name.slice(RAMDISK_PREFIX.length);
        set  = this._ramdiskFiles;
        where = RAMDISK_PREFIX;
      }

      if (name === '' || name.length > MAX_NAME_LEN) return { res: RES_BAD_NAME, size: 0 };
      if (name.indexOf('/') >= 0 || name.indexOf('\\') >= 0 ||
          name.indexOf(':') >= 0 || name.indexOf('..') >= 0)
        return { res: RES_BAD_NAME, size: 0 };
      const key = name.toUpperCase();
      const e = set.find(f => f.name.toUpperCase() === key);
      if (!e) return { res: RES_NOT_FOUND, size: 0 };
      if (e.data.length > HOST_FILE_MAX) return { res: RES_FULL, size: 0 };
      this._loadOpen = { name: e.name, data: e.data, pos: 0 };
      this._log('[disk] FOPEN ' + where + e.name + ' (' + e.data.length + ' bytes)');
      return { res: RES_OK, size: e.data.length };
    }
    // FREAD: copy up to maxBytes from the open cursor into K16 RAM at dest.
    // Returns { res, got }; got = 0 means EOF. RES_NO_MEDIA if nothing open.
    hostFRead(dest, maxBytes) {
      if (!this._loadOpen) return { res: RES_NO_MEDIA, got: 0 };
      if (maxBytes <= 0) return { res: RES_OK, got: 0 };       // valid no-op
      const o = this._loadOpen, M = this._m.mem;
      const got = Math.min(maxBytes, o.data.length - o.pos);
      for (let i = 0; i < got; i++) M[(dest + i) & ADDR_MASK] = o.data[o.pos + i];
      o.pos += got;
      return { res: RES_OK, got };
    }
    hostFClose() {
      if (!this._loadOpen) return RES_NO_MEDIA;
      this._log('[disk] FCLOSE ' + this._loadOpen.name);
      this._loadOpen = null;
      return RES_OK;
    }

    hostMount(name, bay) {
      name = this._normaliseName(name);
      if (bay < 0 || bay >= MAX_DRIVES) return RES_NO_MEDIA;
      if (this._bays[bay]) return RES_BUSY;
      const e = this._catFind(name);
      if (!e) return RES_NOT_FOUND;
      this._bays[bay] = { name: e.name, data: e.data, ro: e.ro, changed: true, dirty: false };
      this._log('[disk] mounted ' + 'CDEF'[bay] + ': ' + e.name + '.KOS  ' +
                ((e.data.length / SECTOR_SIZE) | 0) + ' sectors');
      this._changed();
      return RES_OK;
    }
    hostUnmount(bay) {
      if (bay < 0 || bay >= MAX_DRIVES || !this._bays[bay]) return RES_NO_MEDIA;
      this._log('[disk] unmounted ' + 'CDEF'[bay] + ': ' + this._bays[bay].name);
      this._bays[bay] = null;
      this._changed();
      return RES_OK;
    }
    hostCreate(name, sectors) {
      name = this._normaliseName(name);
      if (!this._validName(name)) return RES_BAD_NAME;
      if (sectors < MIN_DISK_SECTORS) return RES_BAD_SIZE;
      if (this._catFind(name)) return RES_EXISTS;
      this._catalogue.push({ name, data: new Uint8Array(sectors * SECTOR_SIZE), ro: false });
      this._log('[disk] created ' + name + '.KOS  ' + sectors + ' sectors');
      this._changed();
      return RES_OK;
    }
    hostDelete(name) {
      name = this._normaliseName(name);
      if (!this._validName(name)) return RES_BAD_NAME;
      if (this._bayOfName(name) >= 0) return RES_BUSY;
      const i = this._catalogue.findIndex(e => e.name === name);
      if (i < 0) return RES_NOT_FOUND;
      this._catalogue.splice(i, 1);
      this._log('[disk] deleted ' + name + '.KOS');
      this._changed();
      return RES_OK;
    }
    hostRename(bay, newName) {
      newName = this._normaliseName(newName);
      if (bay < 0 || bay >= MAX_DRIVES || !this._bays[bay]) return RES_NO_MEDIA;
      if (!this._validName(newName)) return RES_BAD_NAME;
      const old = this._bays[bay].name;
      if (old === newName) return RES_OK;
      if (this._catFind(newName)) return RES_EXISTS;
      const e = this._catFind(old);
      if (e) e.name = newName;
      this._bays[bay].name = newName;
      this._log('[disk] renamed ' + 'CDEF'[bay] + ': ' + old + '.KOS -> ' + newName + '.KOS');
      this._changed();
      return RES_OK;
    }

    // MMIO wrappers (port of emu_disk DoHost*).
    _doHostMount()   { const d=this._dsk; d.result = this.hostMount(this._readStr(this._curBufAddr(), MAX_NAME_LEN), d.drive); }
    _doHostUnmount() { const d=this._dsk; d.result = this.hostUnmount(d.drive); }
    _doHostCreate()  { const d=this._dsk; d.result = this.hostCreate(this._readStr(this._curBufAddr(), MAX_NAME_LEN), d.seccount); }
    _doHostDelete()  { const d=this._dsk; d.result = this.hostDelete(this._readStr(this._curBufAddr(), MAX_NAME_LEN)); }
    _doHostRename()  { const d=this._dsk; d.result = this.hostRename(d.drive, this._readStr(this._curBufAddr(), MAX_NAME_LEN)); }

    _doHostBayName() {
      const d = this._dsk, buf = this._curBufAddr(), M = this._m.mem;
      if (d.drive < 0 || d.drive >= MAX_DRIVES || !this._bays[d.drive]) {
        M[buf & ADDR_MASK] = 0; d.result = RES_NO_MEDIA; return;
      }
      this._writeStr(buf, this._bays[d.drive].name);
      d.result = RES_OK;
    }

    // FOPEN: filename in BUF (verbatim, extension kept — no _normaliseName).
    // On RES_OK, SECCOUNT = size low word and DSK_SIZE_HI = size high word.
    // Both are written together and only on RES_OK, so a stale high word from
    // a previous open can never pair with a fresh low one.
    _doHostFOpen() {
      const d = this._dsk;
      // MAX_LOADPATH_LEN, not MAX_NAME_LEN: the wire name may carry a folder
      // prefix, and _readStr truncates silently at its cap.
      const r = this.hostFOpen(this._readStr(this._curBufAddr(), MAX_LOADPATH_LEN));
      d.result = r.res;
      if (r.res === RES_OK) {
        d.seccount = r.size & 0xFFFF;
        d.sizeHi   = (r.size >>> 16) & 0xFFFF;
      }
    }
    // FREAD: up to SECCOUNT bytes -> BUF; SECCOUNT updated to bytes read (0=EOF).
    _doHostFRead() {
      const d = this._dsk;
      const r = this.hostFRead(this._curBufAddr(), d.seccount);
      d.result = r.res;
      d.seccount = r.got & 0xFFFF;
    }
    _doHostFClose() { this._dsk.result = this.hostFClose(); }

    // LIST: name\0bay\0name\0bay\0...\0\0 into BUF; bay byte = 0..3 or $FF;
    // names sorted case-insensitively. Capped at LIST_BUF_BYTES.
    _doHostList() {
      const buf = this._curBufAddr(), M = this._m.mem;
      const names = this._catalogue.map(e => e.name).sort();
      let used = 0;
      const fits = (extra) => (used + extra + 1) <= LIST_BUF_BYTES;
      for (const name of names) {
        if (!fits(name.length + 2)) break;
        for (let k = 0; k < name.length; k++) M[(buf + used++) & ADDR_MASK] = name.charCodeAt(k) & 0xFF;
        M[(buf + used++) & ADDR_MASK] = 0;
        const bay = this._bayOfName(name);
        M[(buf + used++) & ADDR_MASK] = (bay < 0) ? 0xFF : bay;
        M[(buf + used++) & ADDR_MASK] = 0;
      }
      if (used < LIST_BUF_BYTES) M[(buf + used++) & ADDR_MASK] = 0;   // final \0\0 sentinel
      this._dsk.result = RES_OK;
    }

    // Host-side bay management (called by the drive manager, NOT k/OS).
    // `data` is a resident Uint8Array image (the OPFS read happens in the UI).
    mountBay(bay, name, data, readOnly) {
      if (bay < 0 || bay >= MAX_DRIVES) return false;
      this._bays[bay] = {
        name: name || '', data, ro: !!readOnly, changed: true, dirty: false
      };
      this._log('[disk] mounted bay ' + bay + ': ' + (name || '?') +
                '  ' + ((data.length / SECTOR_SIZE) | 0) + ' sectors');
      return true;
    }

    unmountBay(bay) {
      if (bay < 0 || bay >= MAX_DRIVES || !this._bays[bay]) return false;
      this._log('[disk] unmounted bay ' + bay + ': ' + this._bays[bay].name);
      this._bays[bay] = null;
      return true;
    }

    // ======================================================================
    //  Boot loader (frm_main.LoadAndReset order)
    // ======================================================================
    // Stage the A: ROM-disk image into RAM at $FC0000. Accepts a Uint8Array.
    loadRomDisk(bytes) {
      if (bytes.length !== ROMDISK_SIZE) {
        this._log('[disk] A: image is ' + bytes.length + ' bytes (expected ' +
                  ROMDISK_SIZE + ') — A: left unmapped');
        return false;
      }
      this._m.mem.set(bytes, ROMDISK_BASE);
      this._log('[disk] A: ROM disk staged at $FC0000 (' +
                (ROMDISK_SIZE / 1024) + ' KB)');
      return true;
    }

    // Fetch the site-bundled system/ramdisk set (Part 61).
    //
    // boot.ksh is fetched first and doubles as the manifest: every
    // `load ramdisk/<name>` line in it names a file to prefetch. boot.ksh
    // itself is in the set too, because A:STARTUP.KSH loads it the same way.
    //
    // The set has to be complete before the CPU starts — FOPEN is synchronous
    // MMIO and cannot await — which is why this is a boot-time prefetch rather
    // than a lazy fetch on first open.
    //
    // Parsing is deliberately loose. Comment lines, `b:`, and anything else in
    // the script simply don't match and are skipped. A line the regex misses is
    // not prefetched and its `load` reports ERR_NOTFOUND at run time — the same
    // failure a genuinely absent file gives, so nothing fails silently wrong.
    //
    // Failure is non-fatal and per-file: a missing entry just isn't in the set.
    // r.ok is checked explicitly because fetch() only rejects on network
    // failure — an unchecked 404 would hand the server's error page to
    // arrayBuffer() and stage HTML as file content.
    async loadRamdiskBundle(bootName, dirUrl) {
      bootName = bootName || SYS_RAMDISK_BOOT;
      dirUrl   = dirUrl   || SYS_RAMDISK_DIR;

      const fetchOne = async (nm) => {
        const rf = await fetch(dirUrl + nm, { cache: 'no-cache' });
        if (!rf.ok) throw new Error('HTTP ' + rf.status);
        return new Uint8Array(await rf.arrayBuffer());
      };

      try {
        const boot = await fetchOne(bootName);
        const out = [{ name: bootName, data: boot }];
        let total = boot.length;

        // Derive the rest from boot.ksh's own load lines. The capture stops at
        // the first whitespace, so a trailing `-f` parses fine.
        const text = new TextDecoder('latin1').decode(boot);
        const seen = new Set([bootName.toUpperCase()]);
        for (const line of text.split(/\r?\n/)) {
          const m = /^\s*load\s+ramdisk\/(\S+)/i.exec(line);
          if (!m) continue;
          const nm = m[1];
          if (seen.has(nm.toUpperCase())) continue;   // dedupe repeated lines
          seen.add(nm.toUpperCase());
          try {
            const b = await fetchOne(nm);
            out.push({ name: nm, data: b });
            total += b.length;
          } catch (e) {
            this._log('[disk] ramdisk/' + nm + ' fetch failed: ' + e.message);
          }
        }

        this._ramdiskFiles = out;
        this._log('[disk] ramdisk bundle: ' + out.length +
                  (out.length === 1 ? ' file, ' : ' files, ') +
                  (total / 1024).toFixed(1) + ' KB');
      } catch (e) {
        this._ramdiskFiles = [];
        this._log('[disk] ramdisk bundle unavailable: ' + e.message);
      }
    }

    // Fetch + stage both system images, then reset. Browser-only (uses fetch).
    // Returns the loadHex info object. Caller decides whether to auto-run.
    async boot(opts) {
      opts = opts || {};
      const hexUrl     = opts.hexUrl     || SYS_HEX;
      const romdiskUrl = opts.romdiskUrl || SYS_ROMDISK;

      // 0. Cold boot: wipe RAM before staging ROM. loadHex/loadRomDisk only
      //    write their own byte ranges, and core.reset() clears CPU regs only,
      //    so without this the 16 MB image survives across a Boot — page-$00
      //    kernel globals, the TCB pool, user pages and the RAM disk all carry
      //    over. That warm-boot state surfaces stale-global bugs (e.g. a leftover
      //    FOREGROUND_TCB hanging shell bring-up). Zeroing here makes "cold boot"
      //    honest and the dev loop deterministic; b-reset stays a warm reset
      //    (RAM preserved) for testing reset-line robustness.
      this._m.mem.fill(0);

      // 1. ROM disk (A:) — staged before the kernel, matching frm_main.
      try {
        const rd = new Uint8Array(await (await fetch(romdiskUrl)).arrayBuffer());
        this.loadRomDisk(rd);
      } catch (e) {
        this._log('[disk] A: fetch failed: ' + e.message);
      }

      // 1b. Site-bundled system/ramdisk set (Part 61). Fetched here, inside
      //     boot(), so it is staged before reset() and long before kosh's boot
      //     cascade runs A:STARTUP.KSH — FOPEN is synchronous MMIO and cannot
      //     await, so the set has to be complete before the CPU starts.
      await this.loadRamdiskBundle(opts.ramdiskBootName, opts.ramdiskDirUrl);

      // 2. Kernel ROM .hex -> $FE/$FF.
      let info = { ok: false, bytes: 0, records: 0, eof: false, minA: 0, maxA: 0 };
      try {
        const text = await (await fetch(hexUrl)).text();
        info = this.loadHex(text);
        this._log('[rom] ' + hexUrl + ' — ' + info.records + ' recs, ' +
                  info.bytes + ' bytes, entry $FF0000');
      } catch (e) {
        this._log('[rom] kernel fetch failed: ' + e.message);
      }

      // 3. Reset (PC <- $FF0000). Caller auto-runs.
      this.reset();
      return info;
    }

    // ======================================================================
    //  Front-end Core surface
    // ======================================================================
    get state() { return this.core.getState(); }

    reset() {
      this.core.reset();
      this._ttyq.length = 0;
      this._kbdHead = this._kbdTail = 0;
      this._m.videoMode = 0;   // back to text view; k/OS sets the real mode at boot
    }

    // No-op: the real run loop drives execution via step() each frame. Kept so
    // the existing Run button handler (which calls startDemo) stays unchanged.
    startDemo() {}

    step(budget) { return this.core.step(budget); }
    stepInstruction() { return this.core.stepInstruction(); }
    requestIRQ() { this.core.requestIRQ(); }    // vblank scheduler tick (per frame)
    get breakpointHit() { return this.core.breakpointHit; }   // pause requested (BP or magic-NOP)
    get magicNopHit()   { return this.core.magicNopHit; }
    setTrace(on)        { this.core.traceOn = !!on; }          // gate before-PC history recording

    tty(n) { return this._ttyq.splice(0, (n == null) ? this._ttyq.length : n); }

    drainEvents() { const e = this._evq; this._evq = []; return e; }
    _log(m) { this._evq.push(m); }

    // Drive-activity events since last call, for the UI lights.
    drainDiskActivity() {
      const f = this._m.drainDiskMem();                 // ROM/RAM memory-disk hits
      if (f.romR)      this._diskAct.push({ bay: "ROM", kind: "read"  });
      if (f.ramW)      this._diskAct.push({ bay: "RAM", kind: "write" });  // write wins
      else if (f.ramR) this._diskAct.push({ bay: "RAM", kind: "read"  });
      const a = this._diskAct; this._diskAct = []; return a;
    }

    // Current video mode: 0 = text/terminal, 1/2/3 = graphics. The UI follows
    // this to auto-switch between the terminal and graphics views.
    get videoMode() { return this._m.videoMode & 0xFFFF; }

    // loadHex -> richer info shape the front-end formats. Wraps the core
    // loader (which does the actual write + range) and adds record/byte counts.
    loadHex(text) {
      const lines = String(text || '').split(/\r\n|\n|\r/);
      let recs = 0, bytes = 0, eof = false, ok = true;
      for (const raw of lines) {
        const l = raw.trim();
        if (!l) continue;
        if (l[0] !== ':' || l.length < 11) { ok = false; continue; }
        const len  = parseInt(l.slice(1, 3), 16);
        const type = parseInt(l.slice(7, 9), 16);
        recs++;
        if (type === 1) eof = true;
        else if (type === 0) bytes += len;
      }
      const r = this._m.loadHex(text);   // performs the load; {loadAddr,maxAddr}
      return {
        ok, bytes, records: recs, eof,
        minA: bytes ? r.loadAddr : 0,
        maxA: r.maxAddr + 1                 // host formats (maxA-1) as last byte
      };
    }

    // Disassemble one instruction at address a -> { addr, bytes, text, len }.
    // Delegates to k16-debug.js (port of emu_debug.Disassemble): full operand
    // decode in K16 assembler syntax, targets as page:offset.
    _decodeAt(a) {
      return K16Debug.disassemble(this._m.mem, a);
    }

    disasm(n) {
      const out = [];
      let a = this.core.cpu.PC & ADDR_MASK;
      for (let j = 0; j < n; j++) {
        const r = this._decodeAt(a);
        out.push({ addr: r.addr, bytes: r.bytes, text: r.text, cur: j === 0 });
        a = (a + r.len) & ADDR_MASK;
      }
      return out;
    }

    // Trace view: the last n retired instruction addresses (oldest -> newest),
    // decoded from current memory. The newest row (where the CPU is) gets cur.
    traceRows(n) {
      const pcs = this.core.getTrace(n), out = [];
      for (let i = 0; i < pcs.length; i++) {
        const r = this._decodeAt(pcs[i]);
        out.push({ addr: r.addr, bytes: r.bytes, text: r.text, cur: i === pcs.length - 1 });
      }
      return out;
    }

    mem(base, rows, cols) {
      const out = [], M = this._m.mem;
      for (let r = 0; r < rows; r++) {
        const ad = (base + r * cols) & ADDR_MASK;
        const hx = [], as = [];
        for (let c = 0; c < cols; c++) {
          const v = M[(ad + c) & ADDR_MASK];
          hx.push(v.toString(16).toUpperCase().padStart(2, '0'));
          as.push((v >= 32 && v < 127) ? String.fromCharCode(v) : '.');
        }
        out.push({ addr: ad, hex: hx.join(' '), ascii: as.join('') });
      }
      return out;
    }

    // ======================================================================
    //  Framebuffer (port of frm_main.UpdateVideoBmp)
    // ======================================================================
    // Renders the current video mode into an offscreen canvas at native source
    // resolution, then blits (nearest-neighbour) to the visible canvas.
    drawGfx(ctx, _t) {
      const canvas = ctx.canvas;
      const mode = this._m.videoMode & 0xFFFF;

      // Device-pixel backing: size the drawing buffer to the element's on-screen
      // device pixels (CSS size x dpr) so the browser blits backing->screen 1:1
      // and WE own the nearest-neighbour upscale from native res. Keeps 1bpp art
      // pixel-perfect at integer dpr (and as even as the panel allows at
      // fractional dpr) with no browser-side filtering on top. Guarded because
      // assigning width/height clears the canvas — only touch it on a change.
      const rect = canvas.getBoundingClientRect();
      if (!rect.width || !rect.height) return;            // not laid out / hidden
      const dpr  = (typeof window !== 'undefined' && window.devicePixelRatio) || 1;
      // Backing = CSS size x dpr, read from the FRACTIONAL bounding rect (not the
      // integer clientWidth) so device-scale mode lands on an exact whole-number
      // multiple of native at any dpr. Clamped: guards against any state where the
      // measured width tracks the backing (a x dpr feedback loop to the 16M cap).
      const CAP = 8192;
      const devW = Math.min(CAP, Math.max(1, Math.round(rect.width  * dpr)));
      const devH = Math.min(CAP, Math.max(1, Math.round(rect.height * dpr)));
      if (canvas.width  !== devW) canvas.width  = devW;
      if (canvas.height !== devH) canvas.height = devH;
      const W = canvas.width, H = canvas.height;

      if (mode === 0 || mode > 3) {
        ctx.fillStyle = '#000'; ctx.fillRect(0, 0, W, H);
        return;
      }

      let sw, sh;
      if (mode === 1) { sw = 1280; sh = 720; }     // 1bpp
      else            { sw = 640;  sh = 480; }     // 8bpp (modes 2,3)

      const off = this._ensureOff(sw, sh);
      const octx = off.getContext('2d');
      const img = octx.createImageData(sw, sh);
      const px = new Uint32Array(img.data.buffer);
      const M = this._m.mem, fb = this._m.fbBase >>> 0;

      if (mode === 1) {
        const WHITE = 0xFFFFFFFF, BLACK = 0xFF000000, STRIDE = 160;
        let di = 0;
        for (let y = 0; y < sh; y++) {
          const row = fb + y * STRIDE;
          for (let x = 0; x < sw; x++) {
            const b = M[(row + (x >> 3)) & ADDR_MASK];
            px[di++] = ((b >> (7 - (x & 7))) & 1) ? WHITE : BLACK;
          }
        }
      } else {
        const pal = (mode === 3) ? this._palRainbow : this._palVga;
        let di = 0;
        for (let y = 0; y < sh; y++) {
          const row = fb + y * sw;
          for (let x = 0; x < sw; x++) px[di++] = pal[M[(row + x) & ADDR_MASK]];
        }
      }

      octx.putImageData(img, 0, 0);
      // Native -> device backing. Aspect is preserved: the CSS size sizeGfx set
      // is sw*k by sh*k, so devW/devH carry the same ratio as sw/sh and the blit
      // never stretches.
      this._blitScaled(ctx, off, sw, sh, W, H);
    }

    // Native -> backing blit, picking the path that keeps source pixels most even.
    //   whole-number upscale : nearest. Every source pixel becomes an exact
    //     k x k block -> pixel-perfect. Device scale mode always lands here by
    //     construction, and integer mode does too at whole-number dpr.
    //   fractional upscale   : nearest-prescale to the NEXT whole multiple, then
    //     filter down. A direct nearest blit at (say) 1.5 gives source pixels
    //     alternating 1 and 2 device px wide -- sharp but visibly uneven, which
    //     is what small 1bpp text shows as fuzz. Going 1280 -> 2560 nearest ->
    //     1920 filtered gives every source pixel a uniform 1.5 device px with
    //     only a thin blend seam. Costs one extra drawImage; the per-pixel decode
    //     loop above is unchanged.
    //   downscale            : filtered. Nearest here DROPS whole source rows and
    //     columns, which is worse than a soft image.
    _blitScaled(ctx, off, sw, sh, W, H) {
      const CAP = 8192, EPS = 1e-6;
      const ratio = W / sw;
      const whole = ratio >= 1 - EPS && Math.abs(ratio - Math.round(ratio)) < EPS;
      if (whole) {
        ctx.imageSmoothingEnabled = false;
        ctx.drawImage(off, 0, 0, sw, sh, 0, 0, W, H);
        return 'nearest';
      }
      if (ratio > 1) {
        const k = Math.ceil(ratio - EPS), pw = sw * k, ph = sh * k;
        if (pw <= CAP && ph <= CAP) {
          const pre = this._ensurePre(pw, ph);
          const pctx = pre.getContext('2d');
          if (pctx) {
            pctx.imageSmoothingEnabled = false;
            pctx.drawImage(off, 0, 0, sw, sh, 0, 0, pw, ph);
            ctx.imageSmoothingEnabled = true;
            ctx.drawImage(pre, 0, 0, pw, ph, 0, 0, W, H);
            return 'prescale' + k;
          }
        }
        ctx.imageSmoothingEnabled = false;                  // no prescale surface
        ctx.drawImage(off, 0, 0, sw, sh, 0, 0, W, H);
        return 'nearest';
      }
      ctx.imageSmoothingEnabled = true;
      ctx.drawImage(off, 0, 0, sw, sh, 0, 0, W, H);
      return 'filtered';
    }

    // Prescale surface for the fractional-upscale path. Deliberately NOT sharing
    // _off's fields: _off holds native res, this holds a whole multiple of it, and
    // one cache would thrash between the two every frame.
    _ensurePre(w, h) {
      if (this._pre && this._preW === w && this._preH === h) return this._pre;
      const c = (typeof document !== 'undefined' && document.createElement)
        ? document.createElement('canvas')
        : { width: w, height: h, getContext() { return null; } };
      c.width = w; c.height = h;
      this._pre = c; this._preW = w; this._preH = h;
      return c;
    }

    _ensureOff(w, h) {
      if (this._off && this._offW === w && this._offH === h) return this._off;
      const c = (typeof document !== 'undefined' && document.createElement)
        ? document.createElement('canvas')
        : { width: w, height: h, getContext() { return null; } };
      c.width = w; c.height = h;
      this._off = c; this._offW = w; this._offH = h;
      return c;
    }
  }

  K16Host.DSK_BASE = DSK_BASE;
  K16Host.ROMDISK_BASE = ROMDISK_BASE;
  K16Host.ROMDISK_SIZE = ROMDISK_SIZE;

  root.K16Host = K16Host;
  if (typeof module !== 'undefined' && module.exports) module.exports = K16Host;

})(typeof window !== 'undefined' ? window : globalThis);
