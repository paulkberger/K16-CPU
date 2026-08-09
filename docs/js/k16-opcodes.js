// k16-opcodes.js — instruction dispatch table + Exec handlers.
//
// Hand-port of emu_opcodes.pas. Single unit: one 128-slot dispatch table built
// by initDispatch(), handlers as methods taking the decoded record `d`. Holds
// refs to cpu, mem, alu (the FPC globals CPU / Mem* / Alu* become injected deps).
//
// Built in passes; unwired slots stay execIllegal. This file is PASS 1:
//   structure + faults + shared helpers (evalCond, rf4 read/write) +
//   $00 MISC, $03 LEA, $05 MOVE, $06 PUSH, $07 POP.
//
// Two faithful deviations from the Pascal (confirmed): the dead, never-wired
// ExecPUSH_Imm is omitted ($06 m3 routes to pushSingle, per the source's own
// "was PUSH_Imm -- WRONG" note); and the ExecSTOREEB typo is cleaned to storeb
// (lands in Pass 2).

(function (root) {
  'use strict';

  const T = (typeof require === 'function') ? require('./k16-types.js') : root.K16Types;
  const { ADDR_MASK, TERM_ADDR } = T;

  const K16ALU = (typeof require === 'function') ? require('./k16-alu.js') : root.K16ALU;
  const AOP = K16ALU.AOP;

  const hex = (v, n) => (v >>> 0).toString(16).toUpperCase().padStart(n, '0');

  class K16Opcodes {
    constructor(cpu, mem, alu) {
      this.cpu = cpu;
      this.mem = mem;
      this.alu = alu;
      this.dispatch = new Array(128);
      this.initDispatch();
    }

    // Dispatch one decoded instruction (used by tests + the eventual step loop).
    exec(d) { this.dispatch[(d.opcode << 2) | d.mode](d); }

    // ---- Diagnostics / faults --------------------------------------------
    _termStr(s) {
      const io = this.mem.io;
      if (!io) return;
      io.writeByte(TERM_ADDR, 10);
      for (let i = 0; i < s.length; i++) io.writeByte(TERM_ADDR, s.charCodeAt(i) & 0xFF);
      io.writeByte(TERM_ADDR, 10);
    }

    execIllegal(d) {
      this._termStr('ILLEGAL op=$' + hex(d.opcode, 2) + ' mode=' + d.mode +
                    ' PC=$' + hex((this.cpu.PC - 2) & ADDR_MASK, 6));
      this.cpu.Halted = true;
      this.cpu.HaltCode = 0xFE;          // illegal opcode sentinel
    }

    // Wired into mem as data/code fault hooks. One-shot: do nothing if halted.
    raiseDataFault(addr) {
      if (this.cpu.Halted) return;
      this._termStr('DATA FAULT odd-addr word access $' + hex(addr, 6) +
                    ' PC=$' + hex(this.cpu.PC & ADDR_MASK, 6));
      this.cpu.Halted = true; this.cpu.HaltCode = 0xFD;
    }

    raiseCodeFault(addr) {
      if (this.cpu.Halted) return;
      this._termStr('CODE FAULT odd-addr fetch PC=$' + hex(addr, 6));
      this.cpu.Halted = true; this.cpu.HaltCode = 0xFC;
    }

    // ---- Shared helpers ---------------------------------------------------
    // Condition evaluator (Scc + Bcc). N xor V == (N !== V).
    evalCond(cond) {
      const c = this.cpu;
      switch (cond) {
        case 0: return c.Z;                       // EQ/Z
        case 1: return !c.Z;                      // NE/NZ
        case 2: return c.C;                       // CS/HS
        case 3: return !c.C;                      // CC/LO
        case 4: return c.N !== c.V;               // LT
        case 5: return !c.Z && (c.N === c.V);     // GT
        case 6: return c.N === c.V;               // GE
        case 7: return c.Z || (c.N !== c.V);      // LE
        default: return false;
      }
    }

    // rf4 read — full map (D/X/Y/ORDB/SR/PCH/PCL). Shared by MOVE-read and PUSH.
    rf4Read(r) {
      const c = this.cpu;
      switch (r) {
        case 0: case 1: case 2: case 3:     return c.D[r];
        case 4: case 5: case 6: case 7:     return c.X[r - 4];
        case 8: case 9: case 10: case 11:   return c.Y[r - 8];
        case 12: return c.ORDB;
        case 13: return c.srToWord();
        case 14: return c.PC >>> 16;        // PCH
        case 15: return c.PC & 0xFFFF;      // PCL
        default: return 0;
      }
    }

    // rf4 write — MOVE's full map (writes SR flags-only; reassembles PC halves).
    rf4WriteMove(r, v) {
      const c = this.cpu;
      switch (r) {
        case 0: case 1: case 2: case 3:     c.D[r] = v; break;
        case 4: case 5: case 6: case 7:     c.X[r - 4] = v; break;
        case 8: case 9: case 10: case 11:   c.Y[r - 8] = v & 0xFF; break;
        case 12: c.ORDB = v & 0xFFFF; break;
        case 13: c.srFromWordFlagsOnly(v); break;
        case 14: c.PC = ((c.PC & 0xFFFF)   | ((v & 0xFF) << 16)) >>> 0; break;  // PCH
        case 15: c.PC = ((c.PC & 0xFF0000) | (v & 0xFFFF))       >>> 0; break;  // PCL
      }
    }

    // ====================================================================
    // $00 MISC
    // ====================================================================
    execNOP(d) { /* no-op */ }

    execHALT(d) {
      this.cpu.HaltCode = d.operand & 0xFF;   // IR[7:0]
      this.cpu.Halted = true;
    }

    // INC XYn,#imm5 — 24-bit add with carry into Y. Flag-transparent.
    execINC_Word(d) {
      const c = this.cpu;
      const n = (d.operand >> 5) & 3;
      const imm = d.operand & 0x1F;
      const newX = c.X[n] + imm;                                  // <= 0xFFFF+0x1F
      let newXY = ((c.Y[n] << 16) | (newX & 0xFFFF)) >>> 0;
      if (newX > 0xFFFF) newXY = (newXY + 0x010000) & ADDR_MASK;  // carry into Y
      c.xySet(n, newXY);
    }

    // DEC XYn,#imm5 — 24-bit subtract with borrow from Y. Flag-transparent.
    execDEC_Word(d) {
      const c = this.cpu;
      const n = (d.operand >> 5) & 3;
      const imm = d.operand & 0x1F;
      const newX = (c.X[n] - imm) >>> 0;                          // unsigned wrap = borrow
      let newXY = ((c.Y[n] << 16) | (newX & 0xFFFF)) >>> 0;
      if (newX > 0xFFFF) newXY = (newXY - 0x010000) & ADDR_MASK;  // borrow from Y
      c.xySet(n, newXY);
    }

    // ====================================================================
    // $03 LEA
    // ====================================================================
    execLEA_XYImm(d) {        // mode 0: plain copy, or +Dn when IR[4:3] set
      const c = this.cpu;
      const Xd = (d.operand >> 7) & 3, Xs = (d.operand >> 5) & 3, Dn = (d.operand >> 3) & 3;
      if ((d.operand & 0x18) === 0) c.xySet(Xd, c.xyGet(Xs));
      else c.xySet(Xd, (c.xyGet(Xs) + c.D[Dn]) & ADDR_MASK);
    }

    execLEA_XYReg(d) {        // mode 1: XYs + Dn
      const c = this.cpu;
      const Xd = (d.operand >> 7) & 3, Xs = (d.operand >> 5) & 3, Dn = (d.operand >> 3) & 3;
      c.xySet(Xd, (c.xyGet(Xs) + c.D[Dn]) & ADDR_MASK);
    }

    execLEA_PCRel(d) {        // mode 2: PC + signed imm16, PAGE-LOCAL (low word wraps)
      const c = this.cpu;
      const Xd = (d.operand >> 7) & 3;
      const off = (d.imm16 << 16) >> 16;                          // sign-extend
      c.xySet(Xd, (c.PC & 0xFF0000) | ((c.PC + off) & 0xFFFF));
    }

    execLEA_Copy(d) {         // mode 3: XYs + imm5
      const c = this.cpu;
      const Xd = (d.operand >> 7) & 3, Xs = (d.operand >> 5) & 3, imm5 = d.operand & 0x1F;
      c.xySet(Xd, (c.xyGet(Xs) + imm5) & ADDR_MASK);
    }

    // ====================================================================
    // $05 MOVE / SWAP
    // ====================================================================
    execMOVE(d) {
      const dst = (d.operand >> 5) & 0x0F;
      const src = (d.operand >> 1) & 0x0F;
      if (d.mode === 0 || d.mode === 1) {
        this.rf4WriteMove(dst, this.rf4Read(src));               // MOVE
      } else {
        const tmp = this.rf4Read(dst);                           // SWAP
        this.rf4WriteMove(dst, this.rf4Read(src));
        this.rf4WriteMove(src, tmp);
      }
    }

    // ====================================================================
    // $06 PUSH  (descending stack: pre-decrement, then write)
    // ====================================================================
    execPUSH_Single(d) {
      const c = this.cpu;
      const rf4 = (d.operand >> 5) & 0x0F, sp = (d.operand >> 1) & 3;
      const v = this.rf4Read(rf4);
      c.xySet(sp, (c.xyGet(sp) - 2) & ADDR_MASK);
      this.mem.writeWord(c.xyGet(sp), v);
    }

    execPUSH_Group(d) {       // push D1, D2, D3 (D0 untouched); D3 ends lowest
      const c = this.cpu;
      const sp = (d.operand >> 1) & 3;
      for (let i = 1; i <= 3; i++) {
        c.xySet(sp, (c.xyGet(sp) - 2) & ADDR_MASK);
        this.mem.writeWord(c.xyGet(sp), c.D[i]);
      }
    }

    execPUSH_XY(d) {          // X first (higher addr), then Y (lower)
      const c = this.cpu;
      const n = (d.operand >> 7) & 3, sp = (d.operand >> 1) & 3;
      c.xySet(sp, (c.xyGet(sp) - 2) & ADDR_MASK); this.mem.writeWord(c.xyGet(sp), c.X[n]);
      c.xySet(sp, (c.xyGet(sp) - 2) & ADDR_MASK); this.mem.writeWord(c.xyGet(sp), c.Y[n]);
    }

    // ====================================================================
    // $07 POP  (post-increment)
    // ====================================================================
    execPOP_Single(d) {
      const c = this.cpu;
      const rf4 = (d.operand >> 5) & 0x0F, sp = (d.operand >> 1) & 3;
      const v = this.mem.readWord(c.xyGet(sp));
      c.xySet(sp, (c.xyGet(sp) + 2) & ADDR_MASK);
      if (rf4 <= 3)        c.D[rf4] = v;
      else if (rf4 <= 7)   c.X[rf4 - 4] = v;
      else if (rf4 <= 11)  c.Y[rf4 - 8] = v & 0xFF;
      else if (rf4 === 13) c.srFromWordFlagsOnly(v);
      // rf4 12/14/15 intentionally unhandled (matches Pascal POP_Single)
    }

    execPOP_Group(d) {        // mem -> D3, D2, D1 (from lowest addr up)
      const c = this.cpu;
      const sp = (d.operand >> 1) & 3;
      for (let i = 3; i >= 1; i--) {
        c.D[i] = this.mem.readWord(c.xyGet(sp));
        c.xySet(sp, (c.xyGet(sp) + 2) & ADDR_MASK);
      }
    }

    execPOP_XY(d) {           // Y (lower) popped first, then X
      const c = this.cpu;
      const n = (d.operand >> 7) & 3, sp = (d.operand >> 1) & 3;
      c.Y[n] = this.mem.readWord(c.xyGet(sp)) & 0xFF;
      c.xySet(sp, (c.xyGet(sp) + 2) & ADDR_MASK);
      c.X[n] = this.mem.readWord(c.xyGet(sp));
      c.xySet(sp, (c.xyGet(sp) + 2) & ADDR_MASK);
    }

    execPOPD(d) {             // discard one word
      const c = this.cpu;
      const sp = (d.operand >> 1) & 3;
      c.xySet(sp, (c.xyGet(sp) + 2) & ADDR_MASK);
    }

    // ====================================================================
    // Address calculation helpers ($14–$1C)
    // ====================================================================
    calcAddr_Ind(d)   { return this.cpu.xyGet((d.operand >> 5) & 3); }            // [XYn]
    calcAddr_Idx(d)   {                                                            // [XYn + Dd]
      const c = this.cpu;
      return (c.xyGet((d.operand >> 5) & 3) + c.D[(d.operand >> 3) & 3]) & ADDR_MASK;
    }
    calcAddr_PCRel(d) {                                                            // [PC + sign(imm16)]
      return (this.cpu.PC + ((d.imm16 << 16) >> 16)) & ADDR_MASK;
    }
    calcAddr_Off5(d)  {                                                            // [XYn + imm5]
      return (this.cpu.xyGet((d.operand >> 5) & 3) + (d.operand & 0x1F)) & ADDR_MASK;
    }

    // ====================================================================
    // $14 LOADD  (dest D = IR[8:7])
    // ====================================================================
    execLOADD_Ind(d)   { this.cpu.D[(d.operand >> 7) & 3] = this.mem.readWord(this.calcAddr_Ind(d)); }
    execLOADD_Idx(d)   { this.cpu.D[(d.operand >> 7) & 3] = this.mem.readWord(this.calcAddr_Idx(d)); }
    execLOADD_PCRel(d) { this.cpu.D[(d.operand >> 7) & 3] = this.mem.readWord(this.calcAddr_PCRel(d)); }
    execLOADD_Off5(d)  { this.cpu.D[(d.operand >> 7) & 3] = this.mem.readWord(this.calcAddr_Off5(d)); }

    // $15 LOADB — zero-extended byte into D
    execLOADB_Ind(d)   { this.cpu.D[(d.operand >> 7) & 3] = this.mem.readByte(this.calcAddr_Ind(d)); }
    execLOADB_Idx(d)   { this.cpu.D[(d.operand >> 7) & 3] = this.mem.readByte(this.calcAddr_Idx(d)); }
    execLOADB_PCRel(d) { this.cpu.D[(d.operand >> 7) & 3] = this.mem.readByte(this.calcAddr_PCRel(d)); }
    execLOADB_Off5(d)  { this.cpu.D[(d.operand >> 7) & 3] = this.mem.readByte(this.calcAddr_Off5(d)); }

    // $16 LOADX  (mode 1 = LOADI Xn,#imm16)
    execLOADX_Ind(d)   { this.cpu.X[(d.operand >> 7) & 3] = this.mem.readWord(this.calcAddr_Ind(d)); }
    execLOADX_Imm16(d) { this.cpu.X[(d.operand >> 7) & 3] = d.imm16; }
    execLOADX_PCRel(d) { this.cpu.X[(d.operand >> 7) & 3] = this.mem.readWord(this.calcAddr_PCRel(d)); }
    execLOADX_Off5(d)  { this.cpu.X[(d.operand >> 7) & 3] = this.mem.readWord(this.calcAddr_Off5(d)); }

    // $17 LOADY — byte register  (mode 1 = LOADI Yn,#imm8)
    execLOADY_Ind(d)   { this.cpu.Y[(d.operand >> 7) & 3] = this.mem.readByte(this.calcAddr_Ind(d)); }
    execLOADY_Imm8(d)  { this.cpu.Y[(d.operand >> 7) & 3] = d.imm16 & 0xFF; }
    execLOADY_PCRel(d) { this.cpu.Y[(d.operand >> 7) & 3] = this.mem.readByte(this.calcAddr_PCRel(d)); }
    execLOADY_Off5(d)  { this.cpu.Y[(d.operand >> 7) & 3] = this.mem.readByte(this.calcAddr_Off5(d)); }

    // ====================================================================
    // $02 STREAM — access then post-increment (advance reuses INC_Word)
    // ====================================================================
    execLOADD_Post(d) { this.cpu.D[(d.operand >> 7) & 3] = this.mem.readWord(this.calcAddr_Ind(d)); this.execINC_Word(d); }
    execLOADB_Post(d) { this.cpu.D[(d.operand >> 7) & 3] = this.mem.readByte(this.calcAddr_Ind(d)); this.execINC_Word(d); }
    execSTORED_Post(d){ this.mem.writeWord(this.calcAddr_Ind(d), this.cpu.D[(d.operand >> 7) & 3]);        this.execINC_Word(d); }
    execSTOREB_Post(d){ this.mem.writeByte(this.calcAddr_Ind(d), this.cpu.D[(d.operand >> 7) & 3] & 0xFF); this.execINC_Word(d); }

    // ====================================================================
    // $18 LOADI / LOADXY / LOADP
    // ====================================================================
    execLOADI_Imm5(d) {
      const c = this.cpu, rf = (d.operand >> 5) & 0x0F, imm = d.operand & 0x1F;
      if (rf <= 3)        c.D[rf] = imm;
      else if (rf <= 7)   c.X[rf - 4] = imm;
      else if (rf <= 11)  c.Y[rf - 8] = imm;
      else if (rf === 13) c.srFromWordFlagsOnly(imm);
    }

    execLOADI_Imm16(d) {
      const c = this.cpu, rf = (d.operand >> 5) & 0x0F;
      if (rf <= 3)        c.D[rf] = d.imm16;
      else if (rf <= 7)   c.X[rf - 4] = d.imm16;
      else if (rf <= 11)  c.Y[rf - 8] = d.imm16 & 0xFF;
      else if (rf === 13) c.srFromWordFlagsOnly(d.imm16);
    }

    execLOADXY(d) {           // 1 word, memory source: Y at [XYm+0], X at [XYm+2]
      const c = this.cpu, n = (d.operand >> 7) & 3, m = (d.operand >> 5) & 3;
      const addr = c.xyGet(m);
      c.Y[n] = this.mem.readByte(addr);
      c.X[n] = this.mem.readWord((addr + 2) & ADDR_MASK);
    }

    execLOADP(d) {            // paged/zero-page load; bit4=ZOA, bit3=byte/word, bits2:1=Yn
      const c = this.cpu, rf4 = (d.operand >> 5) & 0x0F;
      const isZOA = ((d.operand >> 4) & 1) === 1;
      let addr;
      if (isZOA) addr = d.imm16;                                   // page $00
      else addr = ((c.Y[(d.operand >> 1) & 3] << 16) | d.imm16) >>> 0;
      const v = ((d.operand >> 3) & 1) === 1 ? this.mem.readByte(addr) : this.mem.readWord(addr);
      if (rf4 <= 3)       c.D[rf4] = v;
      else if (rf4 <= 7)  c.X[rf4 - 4] = v;
      else if (rf4 <= 11) c.Y[rf4 - 8] = v & 0xFF;
    }

    // ====================================================================
    // $19 STORED / $1A STOREB / $1B STOREX / $1C STOREY
    // ====================================================================
    execSTORED_Ind(d)   { this.mem.writeWord(this.calcAddr_Ind(d),   this.cpu.D[(d.operand >> 7) & 3]); }
    execSTORED_Idx(d)   { this.mem.writeWord(this.calcAddr_Idx(d),   this.cpu.D[(d.operand >> 7) & 3]); }
    execSTORED_PCRel(d) { this.mem.writeWord(this.calcAddr_PCRel(d), this.cpu.D[(d.operand >> 7) & 3]); }
    execSTORED_Off5(d)  { this.mem.writeWord(this.calcAddr_Off5(d),  this.cpu.D[(d.operand >> 7) & 3]); }

    // STOREB — low byte only (Pascal ExecSTOREEB typo cleaned to storeb)
    execSTOREB_Ind(d)   { this.mem.writeByte(this.calcAddr_Ind(d),   this.cpu.D[(d.operand >> 7) & 3] & 0xFF); }
    execSTOREB_Idx(d)   { this.mem.writeByte(this.calcAddr_Idx(d),   this.cpu.D[(d.operand >> 7) & 3] & 0xFF); }
    execSTOREB_PCRel(d) { this.mem.writeByte(this.calcAddr_PCRel(d), this.cpu.D[(d.operand >> 7) & 3] & 0xFF); }
    execSTOREB_Off5(d)  { this.mem.writeByte(this.calcAddr_Off5(d),  this.cpu.D[(d.operand >> 7) & 3] & 0xFF); }

    execSTOREX_Ind(d)   { this.mem.writeWord(this.calcAddr_Ind(d),   this.cpu.X[(d.operand >> 7) & 3]); }
    execSTOREX_Idx(d)   { this.mem.writeWord(this.calcAddr_Idx(d),   this.cpu.X[(d.operand >> 7) & 3]); }
    execSTOREX_PCRel(d) { this.mem.writeWord(this.calcAddr_PCRel(d), this.cpu.X[(d.operand >> 7) & 3]); }
    execSTOREX_Off5(d)  { this.mem.writeWord(this.calcAddr_Off5(d),  this.cpu.X[(d.operand >> 7) & 3]); }

    // STOREY — byte register
    execSTOREY_Ind(d)   { this.mem.writeByte(this.calcAddr_Ind(d),   this.cpu.Y[(d.operand >> 7) & 3]); }
    execSTOREY_Idx(d)   { this.mem.writeByte(this.calcAddr_Idx(d),   this.cpu.Y[(d.operand >> 7) & 3]); }
    execSTOREY_PCRel(d) { this.mem.writeByte(this.calcAddr_PCRel(d), this.cpu.Y[(d.operand >> 7) & 3]); }
    execSTOREY_Off5(d)  { this.mem.writeByte(this.calcAddr_Off5(d),  this.cpu.Y[(d.operand >> 7) & 3]); }

    // ====================================================================
    // $1D STOREI / STOREXY / STOREP
    // ====================================================================
    execSTOREI_Off5(d)  { this.mem.writeWord(this.cpu.xyGet((d.operand >> 5) & 3), d.operand & 0x1F); }
    execSTOREI_Imm16(d) { this.mem.writeWord(this.cpu.xyGet((d.operand >> 5) & 3), d.imm16); }

    execSTOREXY(d) {          // Y at lower addr (+0), X at higher (+2)
      const c = this.cpu, Xd = (d.operand >> 7) & 3, Xs = (d.operand >> 5) & 3;
      this.mem.writeWord(c.xyGet(Xd),     c.Y[Xs]);
      this.mem.writeWord(c.xyGet(Xd) + 2, c.X[Xs]);
    }

    execSTOREP(d) {           // paged/zero-page store; bit4=ZOA, bit3=byte/word, bits2:1=Yn
      const c = this.cpu, rf4 = (d.operand >> 5) & 0x0F;
      const isZOA = ((d.operand >> 4) & 1) === 1;
      let addr;
      if (isZOA) addr = d.imm16;
      else addr = ((c.Y[(d.operand >> 1) & 3] << 16) | d.imm16) >>> 0;
      let v;
      if (rf4 <= 3)       v = c.D[rf4];
      else if (rf4 <= 7)  v = c.X[rf4 - 4];
      else if (rf4 <= 11) v = c.Y[rf4 - 8];
      else                v = 0;
      if (((d.operand >> 3) & 1) === 1) this.mem.writeByte(addr, v & 0xFF);
      else                              this.mem.writeWord(addr, v);
    }

    // ====================================================================
    // ALU operand routing ($08–$10)
    // ====================================================================
    // RR forms include reg 12 (ORDB); imm/XReg forms do not (faithful to FPC).
    _aluReadRR(r) {
      const c = this.cpu;
      if (r <= 3)  return c.D[r];
      if (r <= 7)  return c.X[r - 4];
      if (r <= 11) return c.Y[r - 8];
      if (r === 12) return c.ORDB;
      return 0;
    }
    _aluWriteRR(r, v) {
      const c = this.cpu;
      if (r <= 3)       c.D[r] = v;
      else if (r <= 7)  c.X[r - 4] = v;
      else if (r <= 11) c.Y[r - 8] = v & 0xFF;
      else if (r === 12) c.ORDB = v & 0xFFFF;
    }
    _aluRead(r) {                                   // 0..11 else 0 (no ORDB)
      const c = this.cpu;
      if (r <= 3)  return c.D[r];
      if (r <= 7)  return c.X[r - 4];
      if (r <= 11) return c.Y[r - 8];
      return 0;
    }
    _aluWrite(r, v) {                               // 0..11 only
      const c = this.cpu;
      if (r <= 3)       c.D[r] = v;
      else if (r <= 7)  c.X[r - 4] = v;
      else if (r <= 11) c.Y[r - 8] = v & 0xFF;
    }

    _alu_RR(op, d) {
      const Dd = (d.operand >> 5) & 0x0F, Ds = (d.operand >> 1) & 0x0F;
      const res = this.alu.doAluOp(op, this._aluReadRR(Dd), this._aluReadRR(Ds));
      this._aluWriteRR(Dd, res);
    }
    _alu_XReg(op, d) {
      const Dd = (d.operand >> 5) & 0x0F, Xs = (d.operand >> 1) & 3;
      const res = this.alu.doAluOp(op, this._aluRead(Dd), this.mem.readWord(this.cpu.xyGet(Xs)));
      this._aluWrite(Dd, res);
    }
    _alu_Imm5(op, d) {                               // per-branch: dst >= 12 is a no-op
      const c = this.cpu, rf4 = (d.operand >> 5) & 0x0F, imm5 = d.operand & 0x1F;
      if (rf4 <= 3)       c.D[rf4]     = this.alu.doAluOp(op, c.D[rf4], imm5);
      else if (rf4 <= 7)  c.X[rf4 - 4] = this.alu.doAluOp(op, c.X[rf4 - 4], imm5);
      else if (rf4 <= 11) c.Y[rf4 - 8] = this.alu.doAluOp(op, c.Y[rf4 - 8], imm5) & 0xFF;
    }
    _alu_Imm16(op, d) {
      const c = this.cpu, rf4 = (d.operand >> 5) & 0x0F;
      if (rf4 <= 3)       c.D[rf4]     = this.alu.doAluOp(op, c.D[rf4], d.imm16);
      else if (rf4 <= 7)  c.X[rf4 - 4] = this.alu.doAluOp(op, c.X[rf4 - 4], d.imm16);
      else if (rf4 <= 11) c.Y[rf4 - 8] = this.alu.doAluOp(op, c.Y[rf4 - 8], d.imm16) & 0xFF;
    }

    // ====================================================================
    // $0F NOT  (ExecNOT_Imm5 was defined but never wired — dropped)
    // ====================================================================
    execNOT_RR(d) {                                  // mode 0: dest, src (incl ORDB)
      const Dd = (d.operand >> 5) & 0x0F, Ds = (d.operand >> 1) & 0x0F;
      this._aluWriteRR(Dd, this.alu.not(this._aluReadRR(Ds)));
    }
    execNOT_XReg(d) {                                // mode 1: dest, [XY]
      const Dd = (d.operand >> 5) & 0x0F, Xs = (d.operand >> 1) & 3;
      this._aluWrite(Dd, this.alu.not(this.mem.readWord(this.cpu.xyGet(Xs))));
    }
    execNOT_InPlace(d) {                             // mode 2: dest = NOT dest
      const rf4 = (d.operand >> 5) & 0x0F;
      this._aluWrite(rf4, this.alu.not(this._aluRead(rf4)));
    }
    execNOT_Imm16(d) {                               // mode 3: dest = NOT imm16
      const rf4 = (d.operand >> 5) & 0x0F;
      this._aluWrite(rf4, this.alu.not(d.imm16));
    }

    // ====================================================================
    // $10 CMP  (imm/XReg/imm16 forms compare D registers only — FPC limitation)
    // ====================================================================
    execCMP_RR(d) {
      const Dd = (d.operand >> 5) & 0x0F, Ds = (d.operand >> 1) & 0x0F;
      this.alu.cmp(this._aluReadRR(Dd), this._aluReadRR(Ds));
    }
    execCMP_Imm5(d)  { this.alu.cmp(this._aluReadRR((d.operand >> 5) & 0x0F), d.operand & 0x1F); }
    execCMP_XReg(d)  { this.alu.cmp(this._aluReadRR((d.operand >> 5) & 0x0F), this.mem.readWord(this.cpu.xyGet((d.operand >> 1) & 3))); }
    execCMP_Imm16(d) { this.alu.cmp(this._aluReadRR((d.operand >> 5) & 0x0F), d.imm16); }

    // ====================================================================
    // $1E mode 01: NEG dst, src
    // ====================================================================
    execNEG(d) {
      const Dd = (d.operand >> 5) & 0x0F, Ds = (d.operand >> 1) & 0x0F;
      this._aluWrite(Dd, this.alu.neg(this._aluRead(Ds)));
    }

    // ====================================================================
    // $04 Scc — cond IR[7:5], dst rf4 IR[4:1]; true = all-ones, false = 0
    // ====================================================================
    execScc(d) {
      const c = this.cpu;
      const cond = (d.operand >> 5) & 7, Dd = (d.operand >> 1) & 0x0F;
      if (this.evalCond(cond)) {
        if (Dd <= 3)       c.D[Dd] = 0xFFFF;
        else if (Dd <= 7)  c.X[Dd - 4] = 0xFFFF;
        else if (Dd <= 11) c.Y[Dd - 8] = 0xFF;
      } else {
        if (Dd <= 3)       c.D[Dd] = 0;
        else if (Dd <= 7)  c.X[Dd - 4] = 0;
        else if (Dd <= 11) c.Y[Dd - 8] = 0;
      }
    }

    // ====================================================================
    // $01 LOOKUP — dest D = mode field; page = operand[7:0]. Flag-transparent.
    // ====================================================================
    execLOOKUP(d) {
      const c = this.cpu, a = this.alu;
      const Dn = d.mode & 3, pg = d.operand & 0xFF, v = c.D[Dn];
      switch (pg) {
        case 0xE0: c.D[Dn] = a.shl(v);   break;
        case 0xE2: c.D[Dn] = a.shr(v);   break;
        case 0xE4: c.D[Dn] = a.asr(v);   break;
        case 0xE6: c.D[Dn] = a.rol(v);   break;
        case 0xE8: c.D[Dn] = a.ror(v);   break;
        case 0xEA: c.D[Dn] = a.swapb(v); break;
        case 0xEC: c.D[Dn] = a.high(v);  break;
        case 0xEE: c.D[Dn] = a.low(v);   break;
        case 0xF0: c.D[Dn] = a.shr4(v);  break;
        case 0xF2: c.D[Dn] = a.shl4(v);  break;
        case 0xF4: c.D[Dn] = a.asr4(v);  break;
        case 0xF6: c.D[Dn] = a.asr8(v);  break;
        case 0xF8: c.D[Dn] = a.mulb(v);  break;
        case 0xFA: c.D[Dn] = a.recip(v); break;
        // unknown page: NOP (custom user table not emulated)
      }
    }

    // ====================================================================
    // $11 Bcc  (modes 2/3 are unconditional BRA — must NOT call evalCond)
    // ====================================================================
    execBcc_Short(d) {        // mode 0: cond IR[7:5], unsigned fwd offset IR[4:0]
      const cond = (d.operand >> 5) & 7, off = d.operand & 0x1F;
      if (this.evalCond(cond)) this.cpu.PC = (this.cpu.PC + off) & ADDR_MASK;
    }
    execBcc_Long(d) {         // mode 1: cond IR[7:5], signed imm16
      const cond = (d.operand >> 5) & 7, off = (d.imm16 << 16) >> 16;
      if (this.evalCond(cond)) this.cpu.PC = (this.cpu.PC + off) & ADDR_MASK;
    }
    execBRA_Short(d) {        // mode 2: unconditional, unsigned 5-bit offset
      this.cpu.PC = (this.cpu.PC + (d.operand & 0x1F)) & ADDR_MASK;
    }
    execBcc_LongMode3(d) {    // mode 3: unconditional long, signed imm16
      this.cpu.PC = (this.cpu.PC + ((d.imm16 << 16) >> 16)) & ADDR_MASK;
    }

    // ====================================================================
    // $12 JMP
    // ====================================================================
    execJMP24(d) {            // bank IR[7:0], low word imm16
      this.cpu.PC = (((d.operand & 0xFF) << 16) | d.imm16) & ADDR_MASK;
    }
    execJMP16(d) {            // stay in current bank
      this.cpu.PC = ((this.cpu.PC & 0xFF0000) | d.imm16) >>> 0;
    }
    execJMPT(d) {             // indexed indirect: EA = Xn + Dm; PC = Yn : mem[Yn:EA]
      const c = this.cpu;
      const n = (d.operand >> 5) & 3, m = (d.operand >> 7) & 3;
      const EA = (c.X[n] + c.D[m]) & 0xFFFF;
      const base = ((c.Y[n] << 16) | EA) >>> 0;
      c.PC = ((c.Y[n] << 16) | this.mem.readWord(base)) >>> 0;
    }
    execJMPXY(d) {            // PC = XYn
      this.cpu.PC = this.cpu.xyGet((d.operand >> 5) & 3);
    }

    // ====================================================================
    // $13 CALL  (Push24 then set PC — push order lives in k16-cpu)
    // ====================================================================
    execCALL24(d) {
      const c = this.cpu;
      c.stackPush24(c.PC);
      c.PC = (((d.operand & 0xFF) << 16) | d.imm16) & ADDR_MASK;
    }
    execCALL16(d) {
      const c = this.cpu;
      c.stackPush24(c.PC);
      c.PC = ((c.PC & 0xFF0000) | d.imm16) >>> 0;
    }
    execCALLR(d) {            // PC-relative signed imm16
      const c = this.cpu;
      const off = (d.imm16 << 16) >> 16;
      c.stackPush24(c.PC);
      c.PC = (c.PC + off) & ADDR_MASK;
    }
    execCALLXY(d) {
      const c = this.cpu;
      const n = (d.operand >> 5) & 3;
      c.stackPush24(c.PC);
      c.PC = c.xyGet(n);
    }

    // ====================================================================
    // $1E mode 00/10/11: TRAP / RETCC-RETCS / RET  (mode 01 NEG in Pass 3)
    // ====================================================================
    execTRAP(d) {             // vector at physical [$00:n*4] via ZOA; IR[7:1] = n
      const c = this.cpu;
      const n = (d.operand & 0xFE) >> 1;
      const vecBase = n * 4;
      const pageWord = this.mem.readWord(vecBase);       // low byte = PC[23:16]
      const addrWord = this.mem.readWord(vecBase + 2);   // PC[15:0]
      c.stackPush24(c.PC);
      c.PC = (((pageWord & 0xFF) << 16) | addrWord) >>> 0;
    }

    execRET(d) {              // pop return addr; IMM5 = 4 + cleanup bytes
      const c = this.cpu;
      c.PC = c.stackPop24();
      const imm5 = d.operand & 0x1F;
      if (imm5 > 4) c.xySet(3, (c.xyGet(3) + (imm5 - 4)) & ADDR_MASK);
    }

    execRETCC_RETCS(d) {      // RET + deterministic SR; sel IR[8:7]: 1 = RETCS (C=1)
      const c = this.cpu;
      c.PC = c.stackPop24();
      const imm5 = d.operand & 0x1F;
      if (imm5 > 4) c.xySet(3, (c.xyGet(3) + (imm5 - 4)) & ADDR_MASK);
      const sel = (d.operand >> 7) & 3;
      c.Z = false; c.N = false; c.V = false; c.C = (sel === 1);
    }

    // ====================================================================
    // $1F INT  (DINT / EINT / RTI / INT)
    // ====================================================================
    execDINT(d) { this.cpu.IE = false; }
    execEINT(d) { this.cpu.IE = true; }

    execRTI(d) {              // SR popped first (lowest addr), then PC24
      const c = this.cpu;
      c.srFromWord(c.stackPopWord());
      c.PC = c.stackPop24();
    }

    execINT(d) {              // push PC then SR; vector at physical $000000 (ZOA)
      const c = this.cpu;
      c.stackPush24(c.PC);
      c.stackPushWord(c.srToWord());
      c.IE = false;
      c.T8 = this.mem.readWord(0x000000) & 0xFF;          // page byte
      c.PC = ((c.T8 << 16) | this.mem.readWord(0x000002)) >>> 0;
    }

    // ====================================================================
    // Dispatch table
    // ====================================================================
    initDispatch() {
      // Wire fault hooks into mem (was DataFaultHook/CodeFaultHook in emu_mem).
      this.mem.dataFaultHook = (a) => this.raiseDataFault(a);
      this.mem.codeFaultHook = (a) => this.raiseCodeFault(a);

      const ill = (d) => this.execIllegal(d);
      for (let i = 0; i < 128; i++) this.dispatch[i] = ill;

      const set = (op, md, fn) => { this.dispatch[(op << 2) | md] = (d) => fn.call(this, d); };

      // $00 MISC
      set(0x00, 0, this.execNOP);
      set(0x00, 1, this.execHALT);
      set(0x00, 2, this.execINC_Word);   // INC XY (relocated from $02)
      set(0x00, 3, this.execDEC_Word);   // DEC XY

      // $03 LEA
      set(0x03, 0, this.execLEA_XYImm);
      set(0x03, 1, this.execLEA_XYReg);
      set(0x03, 2, this.execLEA_PCRel);
      set(0x03, 3, this.execLEA_Copy);

      // $05 MOVE
      set(0x05, 0, this.execMOVE);
      set(0x05, 1, this.execMOVE);
      set(0x05, 2, this.execMOVE);
      set(0x05, 3, this.execMOVE);

      // $06 PUSH  (mode 3 -> Single; ExecPUSH_Imm was wrong and is dropped)
      set(0x06, 0, this.execPUSH_Single);
      set(0x06, 1, this.execPUSH_Group);
      set(0x06, 2, this.execPUSH_XY);
      set(0x06, 3, this.execPUSH_Single);

      // $07 POP
      set(0x07, 0, this.execPOP_Single);
      set(0x07, 1, this.execPOP_Group);
      set(0x07, 2, this.execPOP_XY);
      set(0x07, 3, this.execPOPD);

      // $02 STREAM
      set(0x02, 0, this.execLOADD_Post);
      set(0x02, 1, this.execLOADB_Post);
      set(0x02, 2, this.execSTORED_Post);
      set(0x02, 3, this.execSTOREB_Post);

      // $14 LOADD
      set(0x14, 0, this.execLOADD_Ind);
      set(0x14, 1, this.execLOADD_Idx);
      set(0x14, 2, this.execLOADD_PCRel);
      set(0x14, 3, this.execLOADD_Off5);

      // $15 LOADB
      set(0x15, 0, this.execLOADB_Ind);
      set(0x15, 1, this.execLOADB_Idx);
      set(0x15, 2, this.execLOADB_PCRel);
      set(0x15, 3, this.execLOADB_Off5);

      // $16 LOADX
      set(0x16, 0, this.execLOADX_Ind);
      set(0x16, 1, this.execLOADX_Imm16);
      set(0x16, 2, this.execLOADX_PCRel);
      set(0x16, 3, this.execLOADX_Off5);

      // $17 LOADY
      set(0x17, 0, this.execLOADY_Ind);
      set(0x17, 1, this.execLOADY_Imm8);
      set(0x17, 2, this.execLOADY_PCRel);
      set(0x17, 3, this.execLOADY_Off5);

      // $18 LOADI / LOADXY / LOADP
      set(0x18, 0, this.execLOADI_Imm5);
      set(0x18, 1, this.execLOADI_Imm16);
      set(0x18, 2, this.execLOADXY);
      set(0x18, 3, this.execLOADP);

      // $19 STORED
      set(0x19, 0, this.execSTORED_Ind);
      set(0x19, 1, this.execSTORED_Idx);
      set(0x19, 2, this.execSTORED_PCRel);
      set(0x19, 3, this.execSTORED_Off5);

      // $1A STOREB
      set(0x1A, 0, this.execSTOREB_Ind);
      set(0x1A, 1, this.execSTOREB_Idx);
      set(0x1A, 2, this.execSTOREB_PCRel);
      set(0x1A, 3, this.execSTOREB_Off5);

      // $1B STOREX
      set(0x1B, 0, this.execSTOREX_Ind);
      set(0x1B, 1, this.execSTOREX_Idx);
      set(0x1B, 2, this.execSTOREX_PCRel);
      set(0x1B, 3, this.execSTOREX_Off5);

      // $1C STOREY
      set(0x1C, 0, this.execSTOREY_Ind);
      set(0x1C, 1, this.execSTOREY_Idx);
      set(0x1C, 2, this.execSTOREY_PCRel);
      set(0x1C, 3, this.execSTOREY_Off5);

      // $1D STOREI / STOREXY / STOREP
      set(0x1D, 0, this.execSTOREI_Off5);
      set(0x1D, 1, this.execSTOREI_Imm16);
      set(0x1D, 2, this.execSTOREXY);
      set(0x1D, 3, this.execSTOREP);

      // $01 LOOKUP (all modes select dest D0–D3)
      set(0x01, 0, this.execLOOKUP);
      set(0x01, 1, this.execLOOKUP);
      set(0x01, 2, this.execLOOKUP);
      set(0x01, 3, this.execLOOKUP);

      // $04 Scc
      set(0x04, 0, this.execScc);
      set(0x04, 1, this.execScc);
      set(0x04, 2, this.execScc);
      set(0x04, 3, this.execScc);

      // $08–$0E ALU: mode 0=RR, 1=XReg, 2=Imm5, 3=Imm16
      const aluRows = [
        [0x08, AOP.ADD], [0x09, AOP.ADC], [0x0A, AOP.SUB], [0x0B, AOP.SBC],
        [0x0C, AOP.AND], [0x0D, AOP.OR],  [0x0E, AOP.XOR]
      ];
      for (const [op, sel] of aluRows) {
        this.dispatch[(op << 2) | 0] = (d) => this._alu_RR(sel, d);
        this.dispatch[(op << 2) | 1] = (d) => this._alu_XReg(sel, d);
        this.dispatch[(op << 2) | 2] = (d) => this._alu_Imm5(sel, d);
        this.dispatch[(op << 2) | 3] = (d) => this._alu_Imm16(sel, d);
      }

      // $0F NOT
      set(0x0F, 0, this.execNOT_RR);
      set(0x0F, 1, this.execNOT_XReg);
      set(0x0F, 2, this.execNOT_InPlace);
      set(0x0F, 3, this.execNOT_Imm16);

      // $10 CMP
      set(0x10, 0, this.execCMP_RR);
      set(0x10, 1, this.execCMP_XReg);
      set(0x10, 2, this.execCMP_Imm5);
      set(0x10, 3, this.execCMP_Imm16);

      // $1E mode 01 = NEG (TRAP/RETCC/RET wired in Pass 4)
      set(0x1E, 1, this.execNEG);

      // $11 Bcc (mode 2 = BRA short, mode 3 = BRA.L — unconditional)
      set(0x11, 0, this.execBcc_Short);
      set(0x11, 1, this.execBcc_Long);
      set(0x11, 2, this.execBRA_Short);
      set(0x11, 3, this.execBcc_LongMode3);

      // $12 JMP
      set(0x12, 0, this.execJMP24);
      set(0x12, 1, this.execJMP16);
      set(0x12, 2, this.execJMPT);
      set(0x12, 3, this.execJMPXY);

      // $13 CALL
      set(0x13, 0, this.execCALL24);
      set(0x13, 1, this.execCALL16);
      set(0x13, 2, this.execCALLR);
      set(0x13, 3, this.execCALLXY);

      // $1E TRAP / NEG (Pass 3) / RETCC-RETCS / RET
      set(0x1E, 0, this.execTRAP);
      set(0x1E, 2, this.execRETCC_RETCS);
      set(0x1E, 3, this.execRET);

      // $1F INT
      set(0x1F, 0, this.execDINT);
      set(0x1F, 1, this.execEINT);
      set(0x1F, 2, this.execRTI);
      set(0x1F, 3, this.execINT);

      // All 128 slots now wired (matches Pascal InitDispatch — no slot stays illegal).
    }
  }

  root.K16Opcodes = K16Opcodes;
  if (typeof module !== 'undefined' && module.exports) module.exports = K16Opcodes;

})(typeof window !== 'undefined' ? window : globalThis);
