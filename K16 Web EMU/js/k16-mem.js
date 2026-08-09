// k16-mem.js — flat 16MB little-endian memory + I/O routing.
//
// 1:1 hand-port of emu_mem.pas. Instance-based: the FPC global Mem[] + global
// Mem* functions become a K16Mem object injected into K16CPU as `mem` (the seam
// k16-cpu.js already calls). I/O range $D80000..$DFFFFF routes through `io`.
//
// File loaders become byte/text loaders — the web has no file paths:
//   MemLoadBin / MemLoadBinBE  -> loadBytes / loadBytesBE(Uint8Array, base)
//   MemLoadHex(file)           -> loadHex(text)
// Same logic; the source is bytes/text instead of a TFileStream.

(function (root) {
  'use strict';

  const T = (typeof require === 'function') ? require('./k16-types.js') : root.K16Types;
  const { W8, MEM_SIZE, ADDR_MASK, IO_BASE, IO_TOP,
          VID_MODE, VID_PAGE, FB_BASE_DEFAULT, RESET_VEC } = T;

  const FB_DIRTY_SPAN = 0x4B000;   // 307200 = 640x480 (largest mode) — FrameDirty window

  // Intel-HEX byte: two hex chars at a 1-based string position (matches Pascal Copy).
  function hb(line, pos1) {
    return parseInt(line.slice(pos1 - 1, pos1 + 1), 16) & W8;
  }

  class K16Mem {
    constructor() {
      this.mem = new Uint8Array(MEM_SIZE);   // 16 MB; byte stores auto-truncate

      this.videoMode  = 0;
      this.frameDirty = false;
      this.fbBase     = FB_BASE_DEFAULT;     // moved by VID_PAGE writes

      // Seams — all null in FPC until wired by the GUI/CLI/web host.
      this.io             = null;   // { readIO(a), writeIO(a,v), writeByte(a,v) }
      this.ioWriteHook    = null;   // (addr, value)  — GUI taps VID_MODE
      this.dataFaultHook  = null;   // (addr)         — odd-address word access
      this.codeFaultHook  = null;   // (addr)         — read by k16-decode
      this.suppressFaults = false;  // disassembler/UI probing memory
      this.loadMaxAddr    = 0;      // high-water of last image load

      // Drive-activity decode (EMU host). The disk-image regions live in
      // dedicated, page-aligned windows touched ONLY by the k/OS block layer
      // (kos_fs_rom.asm / kos_fs_ram.asm) — never code, stack, or task pages.
      // This models the bus address-decode a real drive LED hangs off; k/OS
      // is entirely unaware. bit0 = ROM disk ($FC-$FD, r/o), bit1 = RAM disk
      // ($30-$3F, EMU host). Flags drained by the host each UI tick.
      this.diskPage = new Uint8Array(256);
      this.diskPage[0xFC] = 1; this.diskPage[0xFD] = 1;         // ROM disk
      for (let p = 0x30; p <= 0x3F; p++) this.diskPage[p] = 2;  // RAM disk (EMU)
      this._dskRomR = 0; this._dskRamR = 0; this._dskRamW = 0;
    }

    // ---- Byte access ------------------------------------------------------
    readByte(addr) {
      return this.mem[addr & ADDR_MASK];
    }

    writeByte(addr, v) {
      const a = addr & ADDR_MASK;
      if (a >= IO_BASE && a <= IO_TOP) {
        if (this.io) this.io.writeByte(a, v);
        return;
      }
      this.mem[a] = v;                       // Uint8 store masks to byte
      if (a >= this.fbBase && a < this.fbBase + FB_DIRTY_SPAN) this.frameDirty = true;
    }

    // ---- Word access — little-endian (low byte at lower address) ----------
    readWord(addr) {
      const a = addr & ADDR_MASK;
      if (a & 1) {                           // odd-address data fault
        if (!this.suppressFaults && this.dataFaultHook) this.dataFaultHook(a);
        return 0;                            // benign; halted CPU won't dispatch
      }
      if (a >= IO_BASE && a <= IO_TOP) {
        return this.io ? this.io.readIO(a) : 0;
      }
      const t = this.diskPage[a >>> 16];
      if (t) { if (t & 1) this._dskRomR = 1; else this._dskRamR = 1; }  // disk read
      return this.mem[a] | (this.mem[(a + 1) & ADDR_MASK] << 8);
    }

    writeWord(addr, v) {
      const a = addr & ADDR_MASK;
      if (a & 1) {
        if (!this.suppressFaults && this.dataFaultHook) this.dataFaultHook(a);
        return;
      }
      if (a >= IO_BASE && a <= IO_TOP) {
        if (a === VID_MODE) {
          this.videoMode  = v & 0xFFFF;
          this.frameDirty = true;
          if (this.ioWriteHook) this.ioWriteHook(a, v);
        }
        if (a === VID_PAGE) {
          // (v & 0xFFFF) << 16 sets bit 31 when bit 15 is set; >>> 0 keeps it
          // unsigned, matching FPC's LongWord shift (the signed-32 JS trap).
          this.fbBase     = ((v & 0xFFFF) << 16) >>> 0;
          this.frameDirty = true;
        }
        if (this.io) this.io.writeIO(a, v);
        return;
      }
      this.mem[a]                   = v;        // low byte  (Uint8 truncates)
      this.mem[(a + 1) & ADDR_MASK] = v >>> 8;  // high byte
      if (a >= this.fbBase && a < this.fbBase + FB_DIRTY_SPAN) this.frameDirty = true;
      if (this.diskPage[a >>> 16] & 2) this._dskRamW = 1;   // RAM-disk write
    }

    // Drain accumulated disk-image access flags. Host polls this each UI tick
    // and converts hits into ROM:/RAM: chip blinks. Read-only ROM disk never
    // sets a write flag.
    drainDiskMem() {
      const f = { romR: this._dskRomR, ramR: this._dskRamR, ramW: this._dskRamW };
      this._dskRomR = this._dskRamR = this._dskRamW = 0;
      return f;
    }

    // ---- Loaders ----------------------------------------------------------
    // Verbatim little-endian image (was MemLoadBin: one word per instruction word).
    loadBytes(bytes, baseAddr) {
      const base = baseAddr & ADDR_MASK;
      if (base + bytes.length > MEM_SIZE)
        throw new RangeError('loadBytes: image overflows 16MB at $' + base.toString(16));
      this.mem.set(bytes, base);
      this.loadMaxAddr = bytes.length ? (base + bytes.length - 1) : base;
    }

    // Big-endian image: load verbatim, then swap each byte pair (was MemLoadBinBE).
    loadBytesBE(bytes, baseAddr) {
      this.loadBytes(bytes, baseAddr);
      const base = baseAddr & ADDR_MASK;
      for (let i = 0; i + 1 < bytes.length; i += 2) {
        const t = this.mem[base + i];
        this.mem[base + i]     = this.mem[base + i + 1];
        this.mem[base + i + 1] = t;
      }
    }

    // Intel HEX (I32HEX) text -> Mem[]. Two-pass, faithful to MemLoadHex.
    // Returns { loadAddr (lowest addr seen), maxAddr (highest) }; sets loadMaxAddr.
    loadHex(text) {
      const lines = text.split(/\r\n|\n|\r/);
      let loadAddr = RESET_VEC, minAddr = ADDR_MASK, maxAddr = 0, ext = 0;

      // pass 1 — address range
      for (let i = 0; i < lines.length; i++) {
        const line = lines[i].trim();
        if (line.length < 11 || line[0] !== ':') continue;
        const bc = hb(line, 2);
        const recAddr = (hb(line, 4) << 8) | hb(line, 6);
        const rt = hb(line, 8);
        if (rt === 0x04) {
          ext = ((hb(line, 10) << 8 | hb(line, 12)) << 16) >>> 0;
        } else if (rt === 0x00) {
          let full = (ext | recAddr) & ADDR_MASK;
          if (full < minAddr) minAddr = full;
          if (bc > 0) {
            full = (full + bc - 1) & ADDR_MASK;
            if (full > maxAddr) maxAddr = full;
          }
        } else if (rt === 0x01) break;
      }
      if (minAddr <= ADDR_MASK) loadAddr = minAddr;
      this.loadMaxAddr = maxAddr;

      // pass 2 — write bytes
      ext = 0;
      for (let i = 0; i < lines.length; i++) {
        const line = lines[i].trim();
        if (line.length < 11 || line[0] !== ':') continue;
        const bc = hb(line, 2);
        const recAddr = (hb(line, 4) << 8) | hb(line, 6);
        const rt = hb(line, 8);
        if (rt === 0x04) {
          ext = ((hb(line, 10) << 8 | hb(line, 12)) << 16) >>> 0;
        } else if (rt === 0x00) {
          const full = (ext | recAddr) & ADDR_MASK;
          for (let n = 0; n < bc; n++)
            this.mem[(full + n) & ADDR_MASK] = hb(line, 10 + n * 2);
        } else if (rt === 0x01) break;
      }
      return { loadAddr, maxAddr };
    }
  }

  root.K16Mem = K16Mem;
  if (typeof module !== 'undefined' && module.exports) module.exports = K16Mem;

})(typeof window !== 'undefined' ? window : globalThis);
