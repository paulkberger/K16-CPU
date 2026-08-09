// k16-cpu.js — K16 CPU register file, stack, status register.
//
// 1:1 hand-port of emu_cpu.pas (TCPU). Decode-and-execute model; this unit
// holds architectural state only — fetch/decode lives in k16-decode.js and the
// Exec* handlers in k16-opcodes.js, exactly as in the FPC split.
//
// Classic linked script: attaches window.K16CPU (browser) and module.exports
// (Node differential tests), same pattern as K16emu-vt100.js.
//
// Width discipline — the reason this reads clean:
//   D[] and X[] are Uint16Array, Y[] is Uint8Array. Storing into a typed array
//   truncates to the element width, so `cpu.D[n] = x` IS Pascal's TWord mask and
//   `cpu.Y[n] = x` IS the TByte mask — no scattered `& 0xFFFF`. Only 24-bit
//   addresses (plain Numbers) are masked by hand, with ADDR_MASK.
//   Shift/or chains that could touch bit 31 end in `>>> 0` to stay unsigned.

(function (root) {
  'use strict';

  const W8        = 0xFF;        // TByte
  const W16       = 0xFFFF;      // TWord
  const ADDR_MASK = 0xFFFFFF;    // 24-bit address space
  const RESET_VEC = 0xFF0000;    // emu_types.RESET_VEC

  // Memory seam. The stack ops are the only state methods that touch memory;
  // they call mem.readWord / mem.writeWord. mem is supplied by k16-mem.js once
  // ported (mirrors `emu_cpu uses emu_mem`). Until then, attach any object with
  // readWord(addr)->word and writeWord(addr, word).
  class K16CPU {
    constructor(mem) {
      this.mem = mem || null;

      this.D = new Uint16Array(4);   // D0..D3
      this.X = new Uint16Array(4);   // XYn low 16 bits
      this.Y = new Uint8Array(4);    // XYn high 8 bits  (XYn = Y<<16 | X)

      this.reset();
    }

    // ---- Reset ------------------------------------------------------------
    // FPC does FillChar(Self,0) then fixes up PC. Here: zero the register
    // arrays and scalars, then set PC to the reset vector.
    reset() {
      this.D.fill(0);
      this.X.fill(0);
      this.Y.fill(0);

      this.PC   = RESET_VEC;
      this.IR   = 0;     // instruction register
      this.T8   = 0;     // 8-bit temp
      this.T16  = 0;     // second word of 2-word instructions
      this.ORAB = 0;     // address output register
      this.ORDB = 0;     // data output register

      // Status register, held as discrete fields like emu_types.TSR.
      this.C = false; this.Z = false; this.N = false; this.V = false;
      this.IE = false; this.Level = 0;

      this.Halted   = false;
      this.HaltCode = 0;

      // QWord in FPC; a JS Number is exact to 2^53 ≈ 11 years at 300 MHz.
      this.CycleCount = 0;

      this.IRQPending = 0;   // phase-2 interrupt latch
    }

    // ---- XY index pair helpers -------------------------------------------
    xyGet(n) {
      return ((this.Y[n] << 16) | this.X[n]) >>> 0;
    }

    xySet(n, v) {
      this.Y[n] = v >>> 16;   // Uint8Array store masks to the high byte
      this.X[n] = v;          // Uint16Array store masks to the low word
    }

    // XY3 doubles as the stack pointer.
    spGet()  { return this.xyGet(3); }
    spSet(v) { this.xySet(3, v); }

    // ---- Stack: descending, pre-decrement push, post-increment pop -------
    stackPushWord(v) {
      this.spSet((this.spGet() - 2) & ADDR_MASK);
      this.mem.writeWord(this.spGet(), v);
    }

    stackPopWord() {
      const v = this.mem.readWord(this.spGet());
      this.spSet((this.spGet() + 2) & ADDR_MASK);
      return v;
    }

    // CALL24 push order: PC[15:0] first (lands at higher addr, SP-2), then
    // PC[23:16] (lands at lower addr, SP-4). After push, XY3 points at the
    // PC[23:16] word. RET pops the mirror. Asymmetry is load-bearing.
    stackPush24(v) {
      this.stackPushWord(v & W16);           // PC[15:0]  → higher addr
      this.stackPushWord((v >>> 16) & W8);   // PC[23:16] → lower addr
    }

    stackPop24() {
      const hi = this.stackPopWord() & W8;   // PC[23:16] at lower addr, first
      const lo = this.stackPopWord();        // PC[15:0]  at higher addr, second
      return ((hi << 16) | lo) >>> 0;
    }

    // ---- SR serialisation (TRAP / RTI) -----------------------------------
    // bit0=C bit1=Z bit2=N bit3=V bits6:4=Level bit7=IE
    srToWord() {
      let r = 0;
      if (this.C) r |= 0x0001;
      if (this.Z) r |= 0x0002;
      if (this.N) r |= 0x0004;
      if (this.V) r |= 0x0008;
      r |= (this.Level & 0x07) << 4;
      if (this.IE) r |= 0x0080;
      return r & W16;
    }

    srFromWord(w) {
      this.C     = (w & 0x0001) !== 0;
      this.Z     = (w & 0x0002) !== 0;
      this.N     = (w & 0x0004) !== 0;
      this.V     = (w & 0x0008) !== 0;
      this.Level = (w >>> 4) & 0x07;
      this.IE    = (w & 0x0080) !== 0;
    }

    // Writes only C/Z/N/V; IE/Level are read-only from software (hardware
    // FLAGS is a 4-bit 74x670). Mirrors emu_cpu.SRFromWordFlagsOnly.
    srFromWordFlagsOnly(w) {
      this.C = (w & 0x0001) !== 0;
      this.Z = (w & 0x0002) !== 0;
      this.N = (w & 0x0004) !== 0;
      this.V = (w & 0x0008) !== 0;
    }
  }

  K16CPU.W8        = W8;
  K16CPU.W16       = W16;
  K16CPU.ADDR_MASK = ADDR_MASK;
  K16CPU.RESET_VEC = RESET_VEC;

  root.K16CPU = K16CPU;
  if (typeof module !== 'undefined' && module.exports) module.exports = K16CPU;

})(typeof window !== 'undefined' ? window : globalThis);
