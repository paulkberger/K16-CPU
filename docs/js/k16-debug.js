// k16-debug.js — debug utilities: disassembler + register/flag/memory formatters.
//
// 1:1 hand-port of emu_debug.pas (the FPC `emu_debug` unit), adapted to the web:
//   Disassemble(addr; out BytesUsed)  -> disassemble(memBytes, addr) -> {addr,bytes,text,len}
//   FormatFlags / FormatRegs / FormatMem  -> formatFlags / formatRegs / formatMem
// The Pascal versions read the global CPU/Mem; here state is passed in explicitly
// (no global CPU in JS), so the front-end's structured DOM rendering of regs/mem is
// untouched — these string formatters are parity/text-dump utilities.
//
// Field extraction mirrors the live executor (k16-opcodes.js K16Opcodes.exec) 1:1:
// whatever bits `exec` pulls from operand/imm16 to RUN an instruction are exactly
// what we render. Mnemonics/operand syntax follow emu_debug.Disassemble (the form
// the assembler accepts). Two deliberate deviations from the Pascal, both agreed:
//   1. Address targets resolve to page:offset (PP:OOOO) — Pascal shows raw offsets
//      (`BEQ +6`, `[PC+$0123]`, `JMP24 $AB1234`); resolved targets are more useful in
//      the live debugger and the disasm has the address to compute them. Resolution is
//      masked per form: page-local forms (LEA m2, JMP16, CALL16) wrap in-page; full
//      24-bit forms (Bcc.L, CALLR, [PC+imm]) can legitimately cross a page.
//   2. NEG ($1E mode 01) is rendered (`NEG dst, src`); the Pascal $1E case falls through
//      to 'TRAP/RET???' for mode 01 — a gap, since the executor implements NEG there.
//
// Encoding notes verified against K16 Reference Manual v3.18 §6.11:
//   TRAP — IR[7:0] = n*2, so n = (operand & $FF) >> 1 (TRAP #0 = $F000, #1 = $F002).
//   RET/RETCC/RETCS — IMM5 = 4 + cleanup_bytes (base 4 = the popped PC); bare at imm5<=4,
//     else #<words>w. (The RM's RET *hex* column $F66C.. is a transcription error — its
//     SP column and the RETCC column are correct and follow this rule.)
//
// Load order: types, decode (both required here), then this file BEFORE host.
// Classic linked script: window.K16Debug + module.exports.

(function (root) {
  'use strict';

  const req       = (typeof require === 'function');
  const T         = req ? require('./k16-types.js')  : root.K16Types;
  const K16Decode = req ? require('./k16-decode.js') : root.K16Decode;

  const { ADDR_MASK } = T;

  // ---- Name tables (mirror emu_debug const block) -------------------------
  const RF4 = ['D0','D1','D2','D3','X0','X1','X2','X3','Y0','Y1','Y2','Y3',
               'ORDB','SR','PCH','PCL'];                       // 4-bit reg field
  const CC  = ['EQ','NE','CS','CC','LT','GT','GE','LE'];       // matches evalCond
  const ALU = { 0x08:'ADD', 0x09:'ADC', 0x0A:'SUB', 0x0B:'SBC',
                0x0C:'AND', 0x0D:'OR',  0x0E:'XOR' };
  const LUT = { 0xE0:'SHL', 0xE2:'SHR', 0xE4:'ASR', 0xE6:'ROL', 0xE8:'ROR',
                0xEA:'SWAPB', 0xEC:'HIGH', 0xEE:'LOW', 0xF0:'SHR4', 0xF2:'SHL4',
                0xF4:'ASR4', 0xF6:'ASR8', 0xF8:'MULB', 0xFA:'RECIP' };

  const h2  = v => (v & 0xFF).toString(16).toUpperCase().padStart(2, '0');
  const h4  = v => (v & 0xFFFF).toString(16).toUpperCase().padStart(4, '0');
  const h6  = v => (v & ADDR_MASK).toString(16).toUpperCase().padStart(6, '0');
  const PO  = v => h2((v >> 16) & 0xFF) + ':' + h4(v & 0xFFFF);   // page:offset
  const rf4 = r => RF4[r & 0x0F];
  const xyN = n => 'XY' + (n & 3);

  // RET/RETcc cleanup: IMM5 = 4 + cleanup_bytes. bare at <=4, else #<words>w
  // (cleanup is even by assembler rule; odd falls back to a raw byte form).
  function retCleanup(i5) {
    if (i5 <= 4) return '';
    const b = i5 - 4;
    return (b & 1) ? ('  #' + b) : ('  #' + (b >> 1) + 'w');
  }

  // ---- Operand decode -> assembler text -----------------------------------
  function decodeText(op, mode, operand, imm16, a, len) {
    const base = (a + len) & ADDR_MASK;               // post-fetch PC
    const sx   = (imm16 << 16) >> 16;                 // signed imm16
    const i5   = operand & 0x1F;
    const dXY  = (operand >> 7) & 3;                  // dest XY / reg-field
    const sXY  = (operand >> 5) & 3;                  // source XY pointer
    const dIdx = (operand >> 3) & 3;                  // D index in [XYm+Dd]
    const rd   = (operand >> 5) & 0x0F;               // rf4 dest
    const rs   = (operand >> 1) & 0x0F;               // rf4 src
    const sp   = (operand >> 1) & 3;                  // stack pointer XY
    const cond = (operand >> 5) & 7;

    switch (op) {
      // $00 MISC
      case 0x00:
        if (mode === 0) return 'NOP';
        if (mode === 1) return 'HALT #$' + h2(operand);
        return (mode === 2 ? 'INC ' : 'DEC ') + xyN(sXY) + ', #' + i5;

      // $01 LOOKUP — dest D = mode field, page = operand[7:0]. Built-in pages
      // render as their mnemonic (SHL D0); custom/unknown pages as the generic
      // assembler form LOOKUP Dn, #$page (RM §6.5).
      case 0x01: {
        const pg = operand & 0xFF;
        return LUT[pg]
          ? (LUT[pg] + ' D' + (mode & 3))
          : ('LOOKUP D' + (mode & 3) + ', #$' + h2(pg));
      }

      // $02 STREAM — post-increment (stride shown, per emu_debug)
      case 0x02: {
        const mn = ['LOADD','LOADB','STORED','STOREB'][mode];
        return mn + ' D' + dXY + ', [' + xyN(sXY) + ']+, #' + i5;
      }

      // $03 LEA (bracketed forms, per emu_debug / syntax guide)
      case 0x03:
        if (mode === 0)
          return (operand & 0x18)
            ? ('LEA ' + xyN(dXY) + ', [' + xyN(sXY) + '+D' + dIdx + ']')
            : ('LEA ' + xyN(dXY) + ', [' + xyN(sXY) + ']');
        if (mode === 1) return 'LEA ' + xyN(dXY) + ', [' + xyN(sXY) + '+D' + dIdx + ']';
        if (mode === 2) return 'LEA ' + xyN(dXY) + ', [' +
                               PO((base & 0xFF0000) | ((base + sx) & 0xFFFF)) + ']';
        return 'LEA ' + xyN(dXY) + ', [' + xyN(sXY) + '+#' + i5 + ']';

      // $04 Scc
      case 0x04: return 'S' + CC[cond] + ' ' + rf4(rs);

      // $05 MOVE / SWAP
      case 0x05:
        return ((mode <= 1) ? 'MOVE ' : 'SWAP ') + rf4(rd) + ', ' + rf4(rs);

      // $06 PUSH
      case 0x06:
        if (mode === 1) return 'PUSH D123, ' + xyN(sp);
        if (mode === 2) return 'PUSH ' + xyN(dXY) + ', ' + xyN(sp);
        return 'PUSH ' + rf4(rd) + ', ' + xyN(sp);

      // $07 POP
      case 0x07:
        if (mode === 1) return 'POP D123, ' + xyN(sp);
        if (mode === 2) return 'POP ' + xyN(dXY) + ', ' + xyN(sp);
        if (mode === 3) return 'POPD ' + xyN(sp);
        return 'POP ' + rf4(rd) + ', ' + xyN(sp);

      // $08..$0E ALU
      case 0x08: case 0x09: case 0x0A: case 0x0B:
      case 0x0C: case 0x0D: case 0x0E: {
        const mn = ALU[op];
        if (mode === 0) return mn + ' ' + rf4(rd) + ', ' + rf4(rs);
        if (mode === 1) return mn + ' ' + rf4(rd) + ', [' + xyN(sp) + ']';
        if (mode === 2) return mn + ' ' + rf4(rd) + ', #' + i5;
        return mn + ' ' + rf4(rd) + ', #$' + h4(imm16);
      }

      // $0F NOT
      case 0x0F:
        if (mode === 0) return 'NOT ' + rf4(rd) + ', ' + rf4(rs);
        if (mode === 1) return 'NOT ' + rf4(rd) + ', [' + xyN(sp) + ']';
        if (mode === 2) return 'NOT ' + rf4(rd);
        return 'NOT ' + rf4(rd) + ', #$' + h4(imm16);

      // $10 CMP
      case 0x10:
        if (mode === 0) return 'CMP ' + rf4(rd) + ', ' + rf4(rs);
        if (mode === 1) return 'CMP ' + rf4(rd) + ', [' + xyN(sp) + ']';
        if (mode === 2) return 'CMP ' + rf4(rd) + ', #' + i5;
        return 'CMP ' + rf4(rd) + ', #$' + h4(imm16);

      // $11 Bcc / BRA  (targets resolved page:offset)
      case 0x11: {
        if (mode === 0) return 'B' + CC[cond] + ' ' + PO((base + i5) & ADDR_MASK);
        if (mode === 1) return 'B' + CC[cond] + ' ' + PO((base + sx) & ADDR_MASK);
        if (mode === 2) return 'BRA ' + PO((base + i5) & ADDR_MASK);
        return 'BRA ' + PO((base + sx) & ADDR_MASK);
      }

      // $12 JMP  (suffix kept, target resolved)
      case 0x12:
        if (mode === 0) return 'JMP24 ' + PO((((operand & 0xFF) << 16) | imm16) & ADDR_MASK);
        if (mode === 1) return 'JMP16 ' + PO((base & 0xFF0000) | imm16);
        if (mode === 2) return 'JMPT ' + xyN(sXY) + ', D' + dXY;
        return 'JMPXY ' + xyN(sXY);

      // $13 CALL  (suffix kept, target resolved)
      case 0x13:
        if (mode === 0) return 'CALL24 ' + PO((((operand & 0xFF) << 16) | imm16) & ADDR_MASK);
        if (mode === 1) return 'CALL16 ' + PO((base & 0xFF0000) | imm16);
        if (mode === 2) return 'CALLR ' + PO((base + sx) & ADDR_MASK);
        return 'CALLXY ' + xyN(sXY);

      // $14 LOADD / $15 LOADB / $19 STORED / $1A STOREB — D register
      case 0x14: case 0x15: case 0x19: case 0x1A: {
        const mn  = { 0x14:'LOADD', 0x15:'LOADB', 0x19:'STORED', 0x1A:'STOREB' }[op];
        const reg = 'D' + dXY;
        if (mode === 0) return mn + ' ' + reg + ', [' + xyN(sXY) + ']';
        if (mode === 1) return mn + ' ' + reg + ', [' + xyN(sXY) + '+D' + dIdx + ']';
        if (mode === 2) return mn + ' ' + reg + ', [' + PO((base + sx) & ADDR_MASK) + ']';
        return mn + ' ' + reg + ', [' + xyN(sXY) + '+#' + i5 + ']';
      }

      // $1B STOREX (X reg) / $1C STOREY (Y reg)
      case 0x1B: case 0x1C: {
        const mn  = op === 0x1B ? 'STOREX' : 'STOREY';
        const reg = (op === 0x1B ? 'X' : 'Y') + dXY;
        if (mode === 0) return mn + ' ' + reg + ', [' + xyN(sXY) + ']';
        if (mode === 1) return mn + ' ' + reg + ', [' + xyN(sXY) + '+D' + dIdx + ']';
        if (mode === 2) return mn + ' ' + reg + ', [' + PO((base + sx) & ADDR_MASK) + ']';
        return mn + ' ' + reg + ', [' + xyN(sXY) + '+#' + i5 + ']';
      }

      // $16 LOADX — mode 1 is LOADI Xn,#imm16 (per executor + emu_debug)
      case 0x16:
        if (mode === 0) return 'LOADX X' + dXY + ', [' + xyN(sXY) + ']';
        if (mode === 1) return 'LOADI X' + dXY + ', #$' + h4(imm16);
        if (mode === 2) return 'LOADX X' + dXY + ', [' + PO((base + sx) & ADDR_MASK) + ']';
        return 'LOADX X' + dXY + ', [' + xyN(sXY) + '+#' + i5 + ']';

      // $17 LOADY — mode 1 is LOADI Yn,#imm8
      case 0x17:
        if (mode === 0) return 'LOADY Y' + dXY + ', [' + xyN(sXY) + ']';
        if (mode === 1) return 'LOADI Y' + dXY + ', #$' + h2(imm16);
        if (mode === 2) return 'LOADY Y' + dXY + ', [' + PO((base + sx) & ADDR_MASK) + ']';
        return 'LOADY Y' + dXY + ', [' + xyN(sXY) + '+#' + i5 + ']';

      // $18 LOADI / LOADXY / LOADP-LOADZ
      case 0x18:
        if (mode === 0) {                              // IMM5 (SEC/CLC hint on SR)
          if (rd === 13 && i5 === 1) return 'LOADI SR, #$01 (SEC)';
          if (rd === 13 && i5 === 0) return 'LOADI SR, #$00 (CLC)';
          return 'LOADI ' + rf4(rd) + ', #' + i5;
        }
        if (mode === 1) return 'LOADI ' + rf4(rd) + ', #$' + h4(imm16);
        if (mode === 2) return 'LOADXY ' + xyN(dXY) + ', [' + xyN(sXY) + ']';
        {                                              // m3: ZOA -> LOADZ(B), else LOADP(B)
          const byte = (operand >> 3) & 1;
          if ((operand >> 4) & 1)
            return (byte ? 'LOADZB ' : 'LOADZ ') + rf4(rd) + ', [#$' + h4(imm16) + ']';
          return (byte ? 'LOADPB ' : 'LOADP ') + rf4(rd) +
                 ', Y' + ((operand >> 1) & 3) + ', [#$' + h4(imm16) + ']';
        }

      // $1D STOREI / STOREXY / STOREP-STOREZ
      case 0x1D:
        if (mode === 0) return 'STOREI #' + i5 + ', [' + xyN(sXY) + ']';
        if (mode === 1) return 'STOREI #$' + h4(imm16) + ', [' + xyN(sXY) + ']';
        if (mode === 2) return 'STOREXY [' + xyN(dXY) + '], ' + xyN(sXY);
        {                                              // m3: ZOA -> STOREZ(B), else STOREP(B)
          const byte = (operand >> 3) & 1;
          if ((operand >> 4) & 1)
            return (byte ? 'STOREZB ' : 'STOREZ ') + rf4(rd) + ', [#$' + h4(imm16) + ']';
          return (byte ? 'STOREPB ' : 'STOREP ') + rf4(rd) +
                 ', Y' + ((operand >> 1) & 3) + ', [#$' + h4(imm16) + ']';
        }

      // $1E TRAP / NEG / RETcc / RET
      case 0x1E:
        if (mode === 0) return 'TRAP #' + ((operand & 0xFF) >> 1);   // RM §6.11: IR[7:0]=n*2
        if (mode === 1) return 'NEG ' + rf4(rd) + ', ' + rf4(rs);
        if (mode === 2) return (((operand >> 7) & 3) === 1 ? 'RETCS' : 'RETCC') + retCleanup(i5);
        return 'RET' + retCleanup(i5);

      // $1F DINT / EINT / RTI / INT
      case 0x1F: return ['DINT','EINT','RTI','INT'][mode];

      default: return '???';
    }
  }

  // Mnemonic column width — STOREXY (7) is the widest mnemonic; operands align
  // one space past it (column 8). Applied only in the display path so decodeText
  // keeps emitting canonical, assembler-valid single-space text.
  const MNEM_W = 7;
  function padMnem(text) {
    const sp = text.indexOf(' ');
    return (sp < 0) ? text
                    : (text.slice(0, sp).padEnd(MNEM_W) + ' ' + text.slice(sp + 1));
  }

  // ---- Disassemble one instruction ----------------------------------------
  // memBytes: the flat Uint8Array (k16-mem's `.mem`). Reads raw bytes (no I/O
  // routing, no faults) the way the Pascal does under SuppressFaults.
  function disassemble(memBytes, a) {
    a &= ADDR_MASK;
    const rw = x => (memBytes[x & ADDR_MASK] | (memBytes[(x + 1) & ADDR_MASK] << 8)) & 0xFFFF;
    const ir = rw(a);
    const op = (ir >> 11) & 0x1F, mode = (ir >> 9) & 0x03, operand = ir & 0x01FF;
    const hasImm = K16Decode.needsImm(op, mode);
    const len = hasImm ? 4 : 2;
    const imm16 = hasImm ? rw(a + 2) : 0;
    const raw = [];
    for (let k = 0; k < len; k++) raw.push(memBytes[(a + k) & ADDR_MASK]);
    const bytes = raw.map(b => b.toString(16).toUpperCase().padStart(2, '0'))
                     .join('').replace(/(.{4})/g, '$1 ').trim();
    return { addr: a, bytes, text: padMnem(decodeText(op, mode, operand, imm16, a, len)), len };
  }

  // ---- Text-state formatters (parity with emu_debug; pass state explicitly) ----
  // sr: { C,Z,N,V, IE, Level } (e.g. core.cpu).
  function formatFlags(sr) {
    return '[' + (sr.C ? 'C' : '-') + (sr.Z ? 'Z' : '-') +
                 (sr.N ? 'N' : '-') + (sr.V ? 'V' : '-') + '] ' +
           (sr.IE ? 'IE' : '--') + ' L' + (sr.Level & 7);
  }

  // cpu: object with D[4], X[4], Y[4], PC, CycleCount, and flag fields.
  function formatRegs(cpu) {
    return 'D0=$' + h4(cpu.D[0]) + ' D1=$' + h4(cpu.D[1]) +
           ' D2=$' + h4(cpu.D[2]) + ' D3=$' + h4(cpu.D[3]) + '\n' +
           'X0=$' + h4(cpu.X[0]) + ' X1=$' + h4(cpu.X[1]) +
           ' X2=$' + h4(cpu.X[2]) + ' X3=$' + h4(cpu.X[3]) + '\n' +
           'Y0=$' + h2(cpu.Y[0]) + '   Y1=$' + h2(cpu.Y[1]) +
           '   Y2=$' + h2(cpu.Y[2]) + '   Y3=$' + h2(cpu.Y[3]) + '\n' +
           'PC=$' + h6(cpu.PC) + '  SR=' + formatFlags(cpu) + '  Cycles=' + cpu.CycleCount;
  }

  function formatMem(memBytes, addr, words) {
    const rw = x => (memBytes[x & ADDR_MASK] | (memBytes[(x + 1) & ADDR_MASK] << 8)) & 0xFFFF;
    let out = '';
    for (let i = 0; i < words; i++) {
      const a = (addr + i * 2) & ADDR_MASK;
      if (i % 8 === 0) { if (i > 0) out += '\n'; out += '$' + h6(a) + ':'; }
      out += ' ' + h4(rw(a));
    }
    return out;
  }

  const K16Debug = { disassemble, decodeText, formatFlags, formatRegs, formatMem,
                     RF4, CC, ALU, LUT };

  root.K16Debug = K16Debug;
  if (typeof module !== 'undefined' && module.exports) module.exports = K16Debug;

})(typeof window !== 'undefined' ? window : globalThis);
