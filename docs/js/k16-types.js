// k16-types.js — shared K16 architectural constants (port of emu_types.pas data block).
//
// Single source of truth for the memory map and opcode numbers used across
// k16-mem.js, k16-decode.js and k16-opcodes.js. (k16-cpu.js deliberately
// self-contains its four universal width/address invariants so it carries no
// load-order dependency; everything map-level lives here.)
//
// Classic linked script: window.K16Types (browser) + module.exports (Node).

(function (root) {
  'use strict';

  const T = {
    // Widths
    W8: 0xFF, W16: 0xFFFF,
    MEM_SIZE: 0x1000000, ADDR_MASK: 0xFFFFFF,

    // RAM / video
    RAM_BASE: 0x000000, RAM_TOP: 0xAFFFFF,
    FB_BASE_DEFAULT: 0xB00000, VRAM_TOP: 0xCFFFFF,

    // I/O range $D80000..$DFFFFF
    IO_BASE: 0xD80000, IO_TOP: 0xDFFFFF,
    VID_PAGE: 0xDC0000,   // FB base page register (word, zero-extended)
    VID_MODE: 0xDD0000,   // video mode register (word)
    KBD_ADDR: 0xDE0000,   // keyboard input (word read)
    TERM_ADDR: 0xDF0000,  // terminal output (byte write)

    // ROM
    ROM_LUT1: 0xE00000, ROM_LUT2: 0xF00000, ROM_TOP: 0xFBFFFF,
    PROG_ROM: 0xFC0000, BOOT_ROM: 0xFF0000, RESET_VEC: 0xFF0000,

    // Opcodes — IR[15:11]
    OP_MISC: 0x00, OP_LOOKUP: 0x01, OP_STREAM: 0x02, OP_LEA: 0x03, OP_SCC: 0x04,
    OP_MOVE: 0x05, OP_PUSH: 0x06, OP_POP: 0x07, OP_ADD: 0x08, OP_ADC: 0x09,
    OP_SUB: 0x0A, OP_SBC: 0x0B, OP_AND: 0x0C, OP_OR: 0x0D, OP_XOR: 0x0E, OP_NOT: 0x0F,
    OP_CMP: 0x10, OP_BCC: 0x11, OP_JMP: 0x12, OP_CALL: 0x13, OP_LOADD: 0x14,
    OP_LOADB: 0x15, OP_LOADX: 0x16, OP_LOADY: 0x17, OP_LOADI: 0x18, OP_STORED: 0x19,
    OP_STOREB: 0x1A, OP_STOREX: 0x1B, OP_STOREY: 0x1C, OP_STOREI: 0x1D,
    OP_TRAP_RET: 0x1E, OP_INT: 0x1F
  };

  root.K16Types = T;
  if (typeof module !== 'undefined' && module.exports) module.exports = T;

})(typeof window !== 'undefined' ? window : globalThis);
