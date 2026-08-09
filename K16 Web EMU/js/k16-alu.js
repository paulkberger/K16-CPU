// k16-alu.js — ALU operations + LOOKUP-table ops.
//
// 1:1 hand-port of emu_alu.pas. Every arithmetic/logic op updates the CPU
// status flags as a side effect (the LOOKUP ops are flag-transparent — the
// interface comment in the Pascal claiming "SHL/SHR set C" is stale; the
// actual implementations touch no flags, and that is what's ported here).
//
// Constructed with a cpu ref so flag writes land on cpu.C/Z/N/V and carry-in
// for ADC/SBC reads cpu.C. Classic linked script: window.K16ALU + module.exports.
//
// CARRY SENSE — 6502-style, the opposite of x86. On SUB/SBC/CMP:
//   C = 1 means NO borrow (a >= b unsigned);  C = 0 means borrow (a < b).
// Stated here so it's read before any flag line below.
//
// SIGNED-32 DISCIPLINE — JS bitwise ops are signed-32. The two places it bites:
//   * SUB borrow detection: a - b goes negative, so the unsigned 32-bit wrap is
//     forced with `>>> 0` BEFORE the <= 0xFFFF borrow test.
//   * Arithmetic shifts: sign-extend 16->32 with `(v << 16 >> 16)` before `>>`.

(function (root) {
  'use strict';

  // TAluOp order, matching the Pascal enum.
  const AOP = { ADD: 0, ADC: 1, SUB: 2, SBC: 3, AND: 4, OR: 5, XOR: 6, NOT: 7, CMP: 8 };

  class K16ALU {
    constructor(cpu) { this.cpu = cpu; }

    // ---- Flag helpers -----------------------------------------------------
    setFlagsZN(r) {
      r &= 0xFFFF;
      this.cpu.Z = r === 0;
      this.cpu.N = (r & 0x8000) !== 0;
    }

    // result32 is the UNSIGNED 32-bit result (callers force >>> 0 for SUB).
    setFlagsArith(a, b, result32, isSub) {
      const r = result32 & 0xFFFF;
      this.cpu.Z = r === 0;
      this.cpu.N = (r & 0x8000) !== 0;
      // Carry — 6502 sense: SUB C = no-borrow (result fits 16 bits unsigned).
      this.cpu.C = isSub ? (result32 <= 0xFFFF) : (result32 > 0xFFFF);
      // Signed overflow: same-sign operands give a different-sign result (ADD);
      // different-sign operands give a result whose sign differs from a (SUB).
      if (isSub)
        this.cpu.V = ((a ^ b) & 0x8000) !== 0 && ((a ^ r) & 0x8000) !== 0;
      else
        this.cpu.V = (~(a ^ b) & 0x8000) !== 0 && ((a ^ r) & 0x8000) !== 0;
    }

    // ---- Arithmetic -------------------------------------------------------
    add(a, b, cin) {
      a &= 0xFFFF; b &= 0xFFFF;
      const r32 = a + b + (cin ? 1 : 0);          // <= 0x1FFFF, stays positive
      this.setFlagsArith(a, b, r32, false);
      return r32 & 0xFFFF;
    }

    sub(a, b, bin) {
      a &= 0xFFFF; b &= 0xFFFF;
      const r32 = (a - b - (bin ? 1 : 0)) >>> 0;  // unsigned 32-bit wrap = borrow
      this.setFlagsArith(a, b, r32, true);
      return r32 & 0xFFFF;
    }

    and(a, b) {
      a &= 0xFFFF; b &= 0xFFFF;
      const r = a & b;
      this.setFlagsZN(r);
      this.cpu.C = false;                          // V unchanged
      return r;
    }

    or(a, b) {
      a &= 0xFFFF; b &= 0xFFFF;
      const r = a | b;
      this.setFlagsZN(r);
      this.cpu.C = false;
      return r;
    }

    xor(a, b) {
      a &= 0xFFFF; b &= 0xFFFF;
      const r = a ^ b;
      this.setFlagsZN(r);
      this.cpu.C = false;
      return r;
    }

    not(a) {
      const r = (~a) & 0xFFFF;
      this.setFlagsZN(r);
      this.cpu.C = false;
      return r;
    }

    // NEG: result = 0 - a (two's complement). Flags per Reference Manual 6.3:
    //   C = src was zero (no borrow only then); V = src was $8000 (sole overflow).
    neg(a) {
      a &= 0xFFFF;
      const r = (0 - a) & 0xFFFF;
      this.cpu.Z = r === 0;
      this.cpu.N = (r & 0x8000) !== 0;
      this.cpu.C = a === 0;
      this.cpu.V = a === 0x8000;
      return r;
    }

    cmp(a, b) { return this.sub(a, b, false); }    // result discarded by caller

    doAluOp(op, a, b) {
      switch (op) {
        case AOP.ADD: return this.add(a, b, false);
        case AOP.ADC: return this.add(a, b, this.cpu.C);
        case AOP.SUB: return this.sub(a, b, false);
        case AOP.SBC: return this.sub(a, b, !this.cpu.C);  // dst - src - ~C
        case AOP.AND: return this.and(a, b);
        case AOP.OR:  return this.or(a, b);
        case AOP.XOR: return this.xor(a, b);
        case AOP.NOT: return this.not(b);                  // NOT uses 2nd operand
        case AOP.CMP: return this.cmp(a, b);
        default:      return 0;
      }
    }

    // ---- LOOKUP ops — flag-transparent ------------------------------------
    shl  (v) { return (v << 1) & 0xFFFF; }
    shr  (v) { return (v & 0xFFFF) >>> 1; }                    // logical
    asr  (v) { return ((v << 16 >> 16) >> 1) & 0xFFFF; }       // arithmetic
    rol  (v) { v &= 0xFFFF; return ((v << 1) & 0xFFFF) | ((v >> 15) & 1); }
    ror  (v) { v &= 0xFFFF; return (v >>> 1) | ((v & 1) << 15); }
    swapb(v) { v &= 0xFFFF; return ((v << 8) & 0xFF00) | (v >>> 8); }
    high (v) { return (v & 0xFFFF) >>> 8; }
    low  (v) { return v & 0x00FF; }
    shl4 (v) { return (v << 4) & 0xFFFF; }
    shr4 (v) { return (v & 0xFFFF) >>> 4; }
    asr4 (v) { return ((v << 16 >> 16) >> 4) & 0xFFFF; }
    asr8 (v) { return ((v << 16 >> 16) >> 8) & 0xFFFF; }
    mulb (v) { v &= 0xFFFF; return ((v & 0xFF) * ((v >>> 8) & 0xFF)) & 0xFFFF; }
    recip(v) { v &= 0xFFFF; return v === 0 ? 0xFFFF : (Math.round(65536 / v) & 0xFFFF); }
  }

  K16ALU.AOP = AOP;

  root.K16ALU = K16ALU;
  if (typeof module !== 'undefined' && module.exports) module.exports = K16ALU;

})(typeof window !== 'undefined' ? window : globalThis);
