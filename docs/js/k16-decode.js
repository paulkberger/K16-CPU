// k16-decode.js — instruction fetch + decode.
//
// 1:1 hand-port of emu_decode.pas. Reads cpu.IR from mem at cpu.PC (little-
// endian), advances PC, extracts opcode/mode/operand, and pulls the imm word
// when NeedsImm. Cycle cost is the flat CycleTable value (decode-and-execute
// model — see the Part 3 decision; no microcode).
//
// The decoded record is caller-owned and refilled in place, mirroring FPC's
// `procedure Fetch(out D: TDecodedInstr)` — no per-instruction allocation in
// the execute loop. Build one with newDecoded(), pass it to fetch() each step.

(function (root) {
  'use strict';

  const T = (typeof require === 'function') ? require('./k16-types.js') : root.K16Types;
  const { ADDR_MASK } = T;

  // ---- Cycle table — indexed [opcode*4 + mode]; 0 = illegal -----------------
  // Flat Uint8Array for speed; row comments mirror emu_decode.CycleTable.
  // Values are the cost CHARGED (FPC charges these flat at retire — "no page
  // cross" is the actual cost, not a typical-case caveat).
  const CYCLE_TABLE = Uint8Array.of(
    /* $00 MISC   */  2,  2,  3,  4,   // NOP, HALT, INC XY, DEC XY
    /* $01 LOOKUP */  3,  3,  3,  3,
    /* $02 STREAM */  4,  4,  5,  5,   // LOADD+/LOADB+ (4), STORED+/STOREB+ (5)
    /* $03 LEA    */  3,  4,  5,  4,   // copy / +D / PC-rel (imm) / +imm5
    /* $04 Scc    */  4,  0,  0,  0,   // always mode 00
    /* $05 MOVE   */  3,  3,  4,  4,   // MOVE=3, SWAP=4
    /* $06 PUSH   */  5, 14,  8,  5,
    /* $07 POP    */  4, 10,  6,  5,   // POP=4, POPgrp=10, PUSHI=5
    /* $08 ADD    */  4,  4,  3,  4,
    /* $09 ADC    */  4,  4,  3,  4,
    /* $0A SUB    */  4,  4,  4,  4,
    /* $0B SBC    */  4,  4,  4,  4,
    /* $0C AND    */  4,  4,  3,  4,
    /* $0D OR     */  4,  4,  3,  4,
    /* $0E XOR    */  4,  4,  3,  4,
    /* $0F NOT    */  4,  4,  4,  4,
    /* $10 CMP    */  3,  3,  3,  3,
    /* $11 Bcc    */  3,  4,  3,  4,
    /* $12 JMP    */  2,  2,  4,  3,   // JMP24, JMP16, JMPT, JMPXY
    /* $13 CALL   */ 11, 11, 12, 10,   // CALL24, CALL16, CALLR, CALLXY
    /* $14 LOADD  */  2,  3,  4,  3,
    /* $15 LOADB  */  2,  3,  4,  3,
    /* $16 LOADX  */  2,  3,  4,  3,
    /* $17 LOADY  */  2,  3,  4,  3,
    /* $18 LOADI  */  2,  2,  4,  3,
    /* $19 STORED */  3,  4,  4,  4,
    /* $1A STOREB */  3,  4,  4,  4,
    /* $1B STOREX */  3,  4,  4,  4,
    /* $1C STOREY */  3,  4,  4,  4,
    /* $1D STOREI */  2,  3,  6,  5,   // imm5=2, imm16=3, STOREXY=6, STOREP=5
    /* $1E TRAP/R */ 12,  3,  6,  5,   // TRAP=12, NEG=3, RETCC/RETCS=6, RET=5
    /* $1F INT    */  2,  2,  8, 16    // RTI=8, INT=16
  );

  // ---- NeedsImm — true when a second (imm16) word follows -------------------
  // Ported from the FPC code, not the stale LOADXY header comment: $18 mode 10
  // (LOADXY [XYm]) is a memory source and takes NO imm word.
  function needsImm(opcode, mode) {
    switch (opcode) {
      case 0x08: case 0x09: case 0x0A: case 0x0B:
      case 0x0C: case 0x0D: case 0x0E: case 0x0F: case 0x10:
        return mode === 3;                              // ALU + CMP: mode 11 = IMM16
      case 0x11: return mode === 1 || mode === 3;        // Bcc long / BRA.L
      case 0x12: return mode === 0 || mode === 1;        // JMP24 / JMP16
      case 0x13: return mode === 0 || mode === 1 || mode === 2; // CALL 24/16/R
      case 0x07: return mode === 3;                      // PUSHI: PUSH #imm16, XYs
      case 0x03: return mode === 2;                      // LEA PC-relative
      case 0x14: case 0x15: return mode === 2;           // LOADD/LOADB [PC+imm16]
      case 0x16: case 0x17: return mode === 1 || mode === 2; // LOADX/LOADY imm16 / [PC+imm16]
      case 0x18: return mode === 1 || mode === 3;        // LOADI IMM16 / LOADP
      case 0x19: case 0x1A: case 0x1B: case 0x1C:
        return mode === 2;                               // STORE [PC+imm16]
      case 0x1D: return mode === 1 || mode === 3;        // STOREI IMM16 / STOREP
      default: return false;                             // TRAP/RET/INT etc: single-word
    }
  }

  function newDecoded() {
    return { opcode: 0, mode: 0, operand: 0, hasImm: false, imm16: 0, cycles: 0 };
  }

  // ---- Fetch ----------------------------------------------------------------
  function fetch(cpu, mem, d) {
    // Code alignment fault — odd PC. Raise the fault and hand back a benign
    // NOP-shaped decode (PC NOT advanced); the outer loop sees cpu.Halted and
    // exits before the next fetch.
    if (cpu.PC & 1) {
      if (mem.codeFaultHook) mem.codeFaultHook(cpu.PC);
      d.opcode = 0; d.mode = 0; d.operand = 0;
      d.hasImm = false; d.imm16 = 0; d.cycles = 2;
      cpu.IR = 0;
      return d;
    }

    cpu.IR = mem.readWord(cpu.PC);
    cpu.PC = (cpu.PC + 2) & ADDR_MASK;

    d.opcode  = (cpu.IR >> 11) & 0x1F;
    d.mode    = (cpu.IR >> 9)  & 0x03;
    d.operand = cpu.IR & 0x01FF;
    d.hasImm  = needsImm(d.opcode, d.mode);
    d.imm16   = 0;
    d.cycles  = CYCLE_TABLE[(d.opcode << 2) | d.mode];

    if (d.hasImm) {
      d.imm16 = mem.readWord(cpu.PC);
      cpu.PC  = (cpu.PC + 2) & ADDR_MASK;
    }
    return d;
  }

  const K16Decode = { CYCLE_TABLE, needsImm, newDecoded, fetch };

  root.K16Decode = K16Decode;
  if (typeof module !== 'undefined' && module.exports) module.exports = K16Decode;

})(typeof window !== 'undefined' ? window : globalThis);
