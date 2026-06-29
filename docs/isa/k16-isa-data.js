/* K16 opcode decode data - factual layer (generated from the in-grid data).
   Keyed by opcode hex 00-1F. Per mode: mnem, syntax, cycles, flags (C Z N V as * - 0 1 w),
   optional note, optional per-cell family override. reserved:true = unused mode slot.
   Source of truth: K16 CPU ISA.xlsx "K16 Opcode Mapping" tab + Ref Manual 15.2 / 15.3. */
window.K16_OPCODES = {
  "00": {
    "family": "sys",
    "name": "MISC",
    "modes": {
      "00": {
        "mnem": "NOP",
        "syntax": "NOP",
        "cycles": "2",
        "flags": "----",
        "note": "No operation."
      },
      "01": {
        "mnem": "HALT",
        "syntax": "HALT #imm8",
        "cycles": "2",
        "flags": "----",
        "note": "Stop processor. D0 is shown on ALUA."
      },
      "10": {
        "family": "incdec",
        "mnem": "INC XY",
        "syntax": "INC XYn, #step",
        "cycles": "3/5",
        "flags": "----",
        "note": "24-bit pointer increment, flag-transparent. 5 cyc on page-cross. Explicit #step required."
      },
      "11": {
        "family": "incdec",
        "mnem": "DEC XY",
        "syntax": "DEC XYn, #step",
        "cycles": "4/6",
        "flags": "----",
        "note": "24-bit pointer decrement, flag-transparent. 6 cyc on page-cross. Explicit #step required."
      }
    }
  },
  "01": {
    "family": "lookup",
    "name": "LOOKUP",
    "modes": {
      "00": {
        "mnem": "SHL SHR ASR ROL",
        "syntax": "SHL Dn · SHR Dn · ASR Dn · ROL Dn",
        "cycles": "3",
        "flags": "----",
        "note": ""
      },
      "01": {
        "mnem": "ROR SWAPB HIGH LOW",
        "syntax": "ROR Dn · SWAPB Dn · HIGH Dn · LOW Dn",
        "cycles": "3",
        "flags": "----",
        "note": ""
      },
      "10": {
        "mnem": "SHR4 SHL4 ASR4 ASR8",
        "syntax": "SHR4 Dn · SHL4 Dn · ASR4 Dn · ASR8 Dn",
        "cycles": "3",
        "flags": "----",
        "note": ""
      },
      "11": {
        "mnem": "MULB RECIP LOOKUP",
        "syntax": "MULB Dn · RECIP Dn · LOOKUP Dn,#page",
        "cycles": "3",
        "flags": "----",
        "note": ""
      }
    },
    "variants": ["SHL", "SHR", "ASR", "ROL", "ROR", "SWAPB", "HIGH", "LOW", "SHL4", "SHR4", "ASR4", "ASR8", "MULB", "RECIP", "LOOKUP"]
  },
  "02": {
    "family": "stream",
    "name": "STREAM",
    "modes": {
      "00": {
        "mnem": "LOADD [XY]+",
        "syntax": "LOADD Dn, [XYm]+",
        "cycles": "4/6",
        "flags": "----",
        "note": "Auto-increment load (word). Flag-transparent. Stride 2 default, imm5 ceiling 31."
      },
      "01": {
        "mnem": "LOADB [XY]+",
        "syntax": "LOADB Dn, [XYm]+",
        "cycles": "4/6",
        "flags": "----",
        "note": "Auto-increment byte load. Stride 1 default."
      },
      "10": {
        "mnem": "STORED [XY]+",
        "syntax": "STORED Dn, [XYm]+",
        "cycles": "5/7",
        "flags": "----",
        "note": "Auto-increment store (word). Flag-transparent."
      },
      "11": {
        "mnem": "STOREB [XY]+",
        "syntax": "STOREB Dn, [XYm]+",
        "cycles": "5/7",
        "flags": "----",
        "note": "Auto-increment byte store."
      }
    }
  },
  "03": {
    "family": "addr",
    "name": "LEA",
    "modes": {
      "00": {
        "mnem": "LEA copy",
        "syntax": "LEA XYn, XYm",
        "cycles": "3",
        "flags": "----",
        "note": "Copy XY pair (mode 00)."
      },
      "01": {
        "mnem": "LEA +D",
        "syntax": "LEA XYn, XYm+Do",
        "cycles": "4/6",
        "flags": "----",
        "note": "Base + D-register index. Do unsigned. 6 cyc on page-cross."
      },
      "10": {
        "mnem": "LEA PC+lbl",
        "syntax": "LEA XYn, PC+label",
        "cycles": "5",
        "flags": "----",
        "note": "PC-relative, page-local. Signed disp, reaches fwd + back within the page."
      },
      "11": {
        "mnem": "LEA +imm5",
        "syntax": "LEA XYn, XYm+#imm5",
        "cycles": "4/6",
        "flags": "----",
        "note": "Base + unsigned 0-31 offset. 6 cyc on page-cross."
      }
    }
  },
  "04": {
    "family": "cond",
    "name": "Scc",
    "modes": {
      "00": {
        "mnem": "Scc",
        "syntax": "Scc Dn\nScc Dn, #imm16",
        "cycles": "4",
        "flags": "----",
        "note": "Conditional set: dst becomes $FFFF if condition true, else $0000 (or a false-value #imm16). Same condition codes as branches."
      },
      "01": {
        "reserved": true
      },
      "10": {
        "reserved": true
      },
      "11": {
        "reserved": true
      }
    },
    "variants": ["SEQ", "SNE", "SCS/SHS", "SCC/SLO", "SLT", "SGT", "SGE", "SLE"]
  },
  "05": {
    "family": "move",
    "name": "MOVE/SWAP",
    "modes": {
      "00": {
        "mnem": "MOVE (D src)",
        "syntax": "MOVE Dd, Ds",
        "cycles": "3",
        "flags": "----",
        "note": "Mode 00: D-register source to any destination (incl PC-lo)."
      },
      "01": {
        "mnem": "MOVE (XY src)",
        "syntax": "MOVE Dd, XYs",
        "cycles": "4",
        "flags": "----",
        "note": "Mode 01: X/Y source to any destination, routed via T16 - that hop is the extra cycle vs mode 00."
      },
      "10": {
        "mnem": "SWAP D-XY",
        "syntax": "SWAP Dn, XYm",
        "cycles": "4",
        "flags": "----",
        "note": "Mode 10: exchange D with X/Y. D must be one operand."
      },
      "11": {
        "mnem": "SWAP XY-XY",
        "syntax": "SWAP XYn, XYm",
        "cycles": "5",
        "flags": "----",
        "note": "Mode 11: exchange X/Y with X/Y - both operands X/Y, two T16 hops (+1 cycle vs mode 10)."
      }
    }
  },
  "06": {
    "family": "stack",
    "name": "PUSH",
    "modes": {
      "00": {
        "mnem": "PUSH Dn",
        "syntax": "PUSH Dn, XYsp",
        "cycles": "5",
        "flags": "----",
        "note": "Push single D register (D0-D3 only). X / Y / FLAGS / PC push via mode 11."
      },
      "01": {
        "mnem": "PUSH D123",
        "syntax": "PUSH D123, XYsp",
        "cycles": "11",
        "flags": "----",
        "note": "Push group D1,D2,D3 (D0 untouched)."
      },
      "10": {
        "mnem": "PUSH XY",
        "syntax": "PUSH XYn, XYsp",
        "cycles": "8",
        "flags": "----",
        "note": "Push XY pair."
      },
      "11": {
        "mnem": "PUSH reg",
        "syntax": "PUSH Xn/Yn/SR, XYsp",
        "cycles": "5",
        "flags": "----",
        "note": "Push single X / Y / ORDB / FLAGS / PCH / PCL (FLAGS = SR). D pushes via mode 00."
      }
    }
  },
  "07": {
    "family": "stack",
    "name": "POP",
    "modes": {
      "00": {
        "mnem": "POP reg",
        "syntax": "POP reg, XYsp",
        "cycles": "4",
        "flags": "----",
        "note": "Pop single register - any of D / X / Y / ORDB / FLAGS / PCH / PCL. POP FLAGS writes SR."
      },
      "01": {
        "mnem": "POP D123",
        "syntax": "POP D123, XYsp",
        "cycles": "8",
        "flags": "----",
        "note": "Pop group D1,D2,D3."
      },
      "10": {
        "mnem": "POP XY",
        "syntax": "POP XYn, XYsp",
        "cycles": "6",
        "flags": "----",
        "note": "Pop XY pair."
      },
      "11": {
        "mnem": "PUSH #imm16",
        "syntax": "PUSH #imm16, XYsp",
        "cycles": "5",
        "flags": "----",
        "note": "Push a 16-bit immediate (PUSHI, 2 words). Encoded in POP because $06 mode 11 is the single X/Y/FLAGS form."
      }
    }
  },
  "08": {
    "family": "alu",
    "name": "ADD",
    "modes": {
      "00": {
        "mnem": "ADD",
        "syntax": "ADD Dn, Dm",
        "cycles": "4",
        "flags": "****",
        "note": "dst = dst + src."
      },
      "01": {
        "mnem": "ADD [XY]",
        "syntax": "ADD Dn, [XYm]",
        "cycles": "4",
        "flags": "****",
        "note": "Add memory operand."
      },
      "10": {
        "mnem": "ADD #imm5",
        "syntax": "ADD Dn, #imm5",
        "cycles": "3",
        "flags": "****",
        "note": "Add 0-31 immediate."
      },
      "11": {
        "mnem": "ADD #imm16",
        "syntax": "ADD Dn, #imm16",
        "cycles": "4",
        "flags": "****",
        "note": "Add 16-bit immediate."
      }
    }
  },
  "09": {
    "family": "alu",
    "name": "ADC",
    "modes": {
      "00": {
        "mnem": "ADC",
        "syntax": "ADC Dn, Dm",
        "cycles": "4",
        "flags": "****",
        "note": "dst = dst + src + Carry."
      },
      "01": {
        "mnem": "ADC [XY]",
        "syntax": "ADC Dn, [XYm]",
        "cycles": "4",
        "flags": "****",
        "note": "Add-with-carry, memory operand."
      },
      "10": {
        "mnem": "ADC #imm5",
        "syntax": "ADC Dn, #imm5",
        "cycles": "3",
        "flags": "****",
        "note": "Add-with-carry 0-31 immediate."
      },
      "11": {
        "mnem": "ADC #imm16",
        "syntax": "ADC Dn, #imm16",
        "cycles": "4",
        "flags": "****",
        "note": "Add-with-carry 16-bit immediate."
      }
    }
  },
  "0A": {
    "family": "alu",
    "name": "SUB",
    "modes": {
      "00": {
        "mnem": "SUB",
        "syntax": "SUB Dn, Dm",
        "cycles": "4",
        "flags": "****",
        "note": "dst = dst - src. C=1 means no borrow (dst >= src)."
      },
      "01": {
        "mnem": "SUB [XY]",
        "syntax": "SUB Dn, [XYm]",
        "cycles": "4",
        "flags": "****",
        "note": "Subtract memory operand."
      },
      "10": {
        "mnem": "SUB #imm5",
        "syntax": "SUB Dn, #imm5",
        "cycles": "4",
        "flags": "****",
        "note": "Subtract 0-31 immediate."
      },
      "11": {
        "mnem": "SUB #imm16",
        "syntax": "SUB Dn, #imm16",
        "cycles": "4",
        "flags": "****",
        "note": "Subtract 16-bit immediate."
      }
    }
  },
  "0B": {
    "family": "alu",
    "name": "SBC",
    "modes": {
      "00": {
        "mnem": "SBC",
        "syntax": "SBC Dn, Dm",
        "cycles": "4",
        "flags": "****",
        "note": "dst = dst - src - (1-Carry). Chain after SUB for multi-word."
      },
      "01": {
        "mnem": "SBC [XY]",
        "syntax": "SBC Dn, [XYm]",
        "cycles": "4",
        "flags": "****",
        "note": "Subtract-with-borrow, memory operand."
      },
      "10": {
        "mnem": "SBC #imm5",
        "syntax": "SBC Dn, #imm5",
        "cycles": "4",
        "flags": "****",
        "note": "Subtract-with-borrow 0-31 immediate."
      },
      "11": {
        "mnem": "SBC #imm16",
        "syntax": "SBC Dn, #imm16",
        "cycles": "4",
        "flags": "****",
        "note": "Subtract-with-borrow 16-bit immediate."
      }
    }
  },
  "0C": {
    "family": "alu",
    "name": "AND",
    "modes": {
      "00": {
        "mnem": "AND",
        "syntax": "AND Dn, Dm",
        "cycles": "4",
        "flags": "0**-",
        "note": "dst = dst & src. C is cleared."
      },
      "01": {
        "mnem": "AND [XY]",
        "syntax": "AND Dn, [XYm]",
        "cycles": "4",
        "flags": "0**-",
        "note": "Bitwise AND, memory operand."
      },
      "10": {
        "mnem": "AND #imm5",
        "syntax": "AND Dn, #imm5",
        "cycles": "3",
        "flags": "0**-",
        "note": "AND 0-31 immediate."
      },
      "11": {
        "mnem": "AND #imm16",
        "syntax": "AND Dn, #imm16",
        "cycles": "4",
        "flags": "0**-",
        "note": "AND 16-bit mask (negative immediate permitted here)."
      }
    }
  },
  "0D": {
    "family": "alu",
    "name": "OR",
    "modes": {
      "00": {
        "mnem": "OR",
        "syntax": "OR Dn, Dm",
        "cycles": "4",
        "flags": "0**-",
        "note": "dst = dst | src. C is cleared."
      },
      "01": {
        "mnem": "OR [XY]",
        "syntax": "OR Dn, [XYm]",
        "cycles": "4",
        "flags": "0**-",
        "note": "Bitwise OR, memory operand."
      },
      "10": {
        "mnem": "OR #imm5",
        "syntax": "OR Dn, #imm5",
        "cycles": "3",
        "flags": "0**-",
        "note": "OR 0-31 immediate."
      },
      "11": {
        "mnem": "OR #imm16",
        "syntax": "OR Dn, #imm16",
        "cycles": "4",
        "flags": "0**-",
        "note": "OR 16-bit mask (negative immediate permitted here)."
      }
    }
  },
  "0E": {
    "family": "alu",
    "name": "XOR",
    "modes": {
      "00": {
        "mnem": "XOR",
        "syntax": "XOR Dn, Dm",
        "cycles": "4",
        "flags": "0**-",
        "note": "dst = dst ^ src. C is cleared."
      },
      "01": {
        "mnem": "XOR [XY]",
        "syntax": "XOR Dn, [XYm]",
        "cycles": "4",
        "flags": "0**-",
        "note": "Bitwise XOR, memory operand."
      },
      "10": {
        "mnem": "XOR #imm5",
        "syntax": "XOR Dn, #imm5",
        "cycles": "3",
        "flags": "0**-",
        "note": "XOR 0-31 immediate."
      },
      "11": {
        "mnem": "XOR #imm16",
        "syntax": "XOR Dn, #imm16",
        "cycles": "4",
        "flags": "0**-",
        "note": "XOR 16-bit mask (negative immediate permitted here)."
      }
    }
  },
  "0F": {
    "family": "alu",
    "name": "NOT",
    "modes": {
      "00": {
        "mnem": "NOT",
        "syntax": "NOT Dn, Dm",
        "cycles": "4",
        "flags": "0**-",
        "note": "dst = ~src (two-operand copy-and-invert). C cleared."
      },
      "01": {
        "mnem": "NOT [XY]",
        "syntax": "NOT Dn, [XYm]",
        "cycles": "4",
        "flags": "0**-",
        "note": "Ones-complement, memory operand."
      },
      "10": {
        "mnem": "NOT",
        "syntax": "NOT Dn",
        "cycles": "4",
        "flags": "0**-",
        "note": "Ones-complement."
      },
      "11": {
        "mnem": "NOT #imm16",
        "syntax": "NOT Dn, #imm16",
        "cycles": "4",
        "flags": "0**-",
        "note": "Ones-complement with mask (negative immediate permitted here)."
      }
    }
  },
  "10": {
    "family": "cmp",
    "name": "CMP",
    "modes": {
      "00": {
        "mnem": "CMP",
        "syntax": "CMP Dn, Dm",
        "cycles": "3",
        "flags": "****",
        "note": "Compare (dst - src, result discarded). C=1 means dst >= src unsigned."
      },
      "01": {
        "mnem": "CMP [XY]",
        "syntax": "CMP Dn, [XYm]",
        "cycles": "3",
        "flags": "****",
        "note": "Compare against memory operand."
      },
      "10": {
        "mnem": "CMP #imm5",
        "syntax": "CMP Dn, #imm5",
        "cycles": "3",
        "flags": "****",
        "note": "Compare with 0-31 immediate."
      },
      "11": {
        "mnem": "CMP #imm16",
        "syntax": "CMP Dn, #imm16",
        "cycles": "3",
        "flags": "****",
        "note": "Compare with 16-bit immediate."
      }
    }
  },
  "11": {
    "family": "branch",
    "name": "Bcc",
    "modes": {
      "00": {
        "mnem": "Bcc.S",
        "syntax": "Bcc.S target",
        "cycles": "3",
        "flags": "----",
        "note": "Short conditional, forward 0-31 bytes. cc = EQ NE CS/HS CC/LO LT GT GE LE."
      },
      "01": {
        "mnem": "Bcc.L",
        "syntax": "Bcc.L target",
        "cycles": "4",
        "flags": "----",
        "note": "Long conditional, +-imm16."
      },
      "10": {
        "mnem": "BRA.S",
        "syntax": "BRA.S target",
        "cycles": "3",
        "flags": "----",
        "note": "Short unconditional, forward 0-31 bytes."
      },
      "11": {
        "mnem": "BRA.L",
        "syntax": "BRA.L target",
        "cycles": "4",
        "flags": "----",
        "note": "Long unconditional, +-imm16."
      }
    },
    "variants": ["BEQ", "BNE", "BCS/BHS", "BCC/BLO", "BLT", "BGT", "BGE", "BLE", "BRA", "(BHI/BLS pseudo)"]
  },
  "12": {
    "family": "flow",
    "name": "JMP",
    "modes": {
      "00": {
        "mnem": "JMP24",
        "syntax": "JMP24 #addr24",
        "cycles": "2",
        "flags": "----",
        "note": "24-bit absolute jump."
      },
      "01": {
        "mnem": "JMP16",
        "syntax": "JMP16 #addr16",
        "cycles": "2",
        "flags": "----",
        "note": "16-bit jump within current page."
      },
      "10": {
        "mnem": "JMPT",
        "syntax": "JMPT XYn, Dm",
        "cycles": "4",
        "flags": "----",
        "note": "Jump table (indexed indirect)."
      },
      "11": {
        "mnem": "JMPXY",
        "syntax": "JMPXY XYn",
        "cycles": "3",
        "flags": "----",
        "note": "Indirect jump via XY register."
      }
    }
  },
  "13": {
    "family": "flow",
    "name": "CALL",
    "modes": {
      "00": {
        "mnem": "CALL24",
        "syntax": "CALL24 #addr24",
        "cycles": "11",
        "flags": "----",
        "note": "24-bit subroutine call (cross-page / cross-file)."
      },
      "01": {
        "mnem": "CALL16",
        "syntax": "CALL16 #addr16",
        "cycles": "11",
        "flags": "----",
        "note": "16-bit call within current page."
      },
      "10": {
        "mnem": "CALLR",
        "syntax": "CALLR #label",
        "cycles": "12",
        "flags": "----",
        "note": "PC-relative call (intra-.COM)."
      },
      "11": {
        "mnem": "CALLXY",
        "syntax": "CALLXY XYn",
        "cycles": "10",
        "flags": "----",
        "note": "Indirect call via XY register."
      }
    }
  },
  "14": {
    "family": "load",
    "name": "LOADD",
    "modes": {
      "00": {
        "mnem": "LOADD [XY]",
        "syntax": "LOADD Dn, [XYm]",
        "cycles": "2",
        "flags": "----",
        "note": "Load word, indirect. Flag-transparent: CMP before branching on the value."
      },
      "01": {
        "mnem": "LOADD [XY+D]",
        "syntax": "LOADD Dn, [XYm+Do]",
        "cycles": "3",
        "flags": "----",
        "note": "Indexed by D register."
      },
      "10": {
        "mnem": "LOADD [PC+i16]",
        "syntax": "LOADD Dn, [PC+imm16]",
        "cycles": "4",
        "flags": "----",
        "note": "PC-relative, signed 16-bit offset."
      },
      "11": {
        "mnem": "LOADD [XY+i5]",
        "syntax": "LOADD Dn, [XYm+imm5]",
        "cycles": "3",
        "flags": "----",
        "note": "Unsigned 0-31 offset."
      }
    }
  },
  "15": {
    "family": "load",
    "name": "LOADX",
    "modes": {
      "00": {
        "mnem": "LOADX [XY]",
        "syntax": "LOADX Xn, [XYm]",
        "cycles": "2",
        "flags": "----",
        "note": "Load into X register. Flag-transparent."
      },
      "01": {
        "mnem": "LOADX [XY+D]",
        "syntax": "LOADX Xn, [XYm+Do]",
        "cycles": "3",
        "flags": "----",
        "note": "Indexed by D register."
      },
      "10": {
        "mnem": "LOADX [PC+i16]",
        "syntax": "LOADX Xn, [PC+imm16]",
        "cycles": "4",
        "flags": "----",
        "note": "PC-relative."
      },
      "11": {
        "mnem": "LOADX [XY+i5]",
        "syntax": "LOADX Xn, [XYm+imm5]",
        "cycles": "3",
        "flags": "----",
        "note": "Unsigned 0-31 offset."
      }
    }
  },
  "16": {
    "family": "load",
    "name": "LOADY",
    "modes": {
      "00": {
        "mnem": "LOADY [XY]",
        "syntax": "LOADY Yn, [XYm]",
        "cycles": "2",
        "flags": "----",
        "note": "Load into Y register. Flag-transparent."
      },
      "01": {
        "mnem": "LOADY [XY+D]",
        "syntax": "LOADY Yn, [XYm+Do]",
        "cycles": "3",
        "flags": "----",
        "note": "Indexed by D register."
      },
      "10": {
        "mnem": "LOADY [PC+i16]",
        "syntax": "LOADY Yn, [PC+imm16]",
        "cycles": "4",
        "flags": "----",
        "note": "PC-relative."
      },
      "11": {
        "mnem": "LOADY [XY+i5]",
        "syntax": "LOADY Yn, [XYm+imm5]",
        "cycles": "3",
        "flags": "----",
        "note": "Unsigned 0-31 offset."
      }
    }
  },
  "17": {
    "family": "load",
    "name": "LOADB",
    "modes": {
      "00": {
        "mnem": "LOADB [XY]",
        "syntax": "LOADB Dn, [XYm]",
        "cycles": "2",
        "flags": "----",
        "note": "Byte load (low byte, zero-extended). Flag-transparent."
      },
      "01": {
        "mnem": "LOADB [XY+D]",
        "syntax": "LOADB Dn, [XYm+Do]",
        "cycles": "3",
        "flags": "----",
        "note": "Indexed byte load."
      },
      "10": {
        "mnem": "LOADB [PC+i16]",
        "syntax": "LOADB Dn, [PC+imm16]",
        "cycles": "4",
        "flags": "----",
        "note": "PC-relative byte load."
      },
      "11": {
        "mnem": "LOADB [XY+i5]",
        "syntax": "LOADB Dn, [XYm+imm5]",
        "cycles": "3",
        "flags": "----",
        "note": "Offset byte load."
      }
    }
  },
  "18": {
    "family": "load",
    "name": "LOADI / +",
    "modes": {
      "00": {
        "mnem": "LOADI #imm5",
        "syntax": "LOADI Dn, #imm5",
        "cycles": "2",
        "flags": "----",
        "note": "Load 0-31 immediate."
      },
      "01": {
        "mnem": "LOADI #imm16",
        "syntax": "LOADI Dn, #imm16",
        "cycles": "2",
        "flags": "----",
        "note": "Load 16-bit immediate."
      },
      "10": {
        "mnem": "LOADXY",
        "syntax": "LOADXY XYn, [XYm]",
        "cycles": "4",
        "flags": "----",
        "note": "Load full 24-bit XY pair (Forth-friendly)."
      },
      "11": {
        "mnem": "LOADP / LOADZ",
        "syntax": "LOADP Dn,Ym,[#imm16]\nLOADZ Dn,[#imm16]",
        "cycles": "3",
        "flags": "----",
        "note": "Paged load, or page-$00 (ZOA) load. Byte variants LOADPB / LOADZB."
      }
    },
    "variants": ["LOADI", "LOADXY", "LOADP", "LOADPB", "LOADZ", "LOADZB"]
  },
  "19": {
    "family": "store",
    "name": "STORED",
    "modes": {
      "00": {
        "mnem": "STORED [XY]",
        "syntax": "STORED Dn, [XYm]",
        "cycles": "3",
        "flags": "----",
        "note": "Store word, indirect."
      },
      "01": {
        "mnem": "STORED [XY+D]",
        "syntax": "STORED Dn, [XYm+Do]",
        "cycles": "4",
        "flags": "----",
        "note": "Indexed by D register."
      },
      "10": {
        "mnem": "STORED [PC+i16]",
        "syntax": "STORED Dn, [PC+imm16]",
        "cycles": "4",
        "flags": "----",
        "note": "PC-relative."
      },
      "11": {
        "mnem": "STORED [XY+i5]",
        "syntax": "STORED Dn, [XYm+imm5]",
        "cycles": "4",
        "flags": "----",
        "note": "Unsigned 0-31 offset."
      }
    }
  },
  "1A": {
    "family": "store",
    "name": "STOREB",
    "modes": {
      "00": {
        "mnem": "STOREB [XY]",
        "syntax": "STOREB Dn, [XYm]",
        "cycles": "3",
        "flags": "----",
        "note": "Byte store, indirect."
      },
      "01": {
        "mnem": "STOREB [XY+D]",
        "syntax": "STOREB Dn, [XYm+Do]",
        "cycles": "4",
        "flags": "----",
        "note": "Indexed byte store."
      },
      "10": {
        "mnem": "STOREB [PC+i16]",
        "syntax": "STOREB Dn, [PC+imm16]",
        "cycles": "4",
        "flags": "----",
        "note": "PC-relative byte store."
      },
      "11": {
        "mnem": "STOREB [XY+i5]",
        "syntax": "STOREB Dn, [XYm+imm5]",
        "cycles": "4",
        "flags": "----",
        "note": "Offset byte store."
      }
    }
  },
  "1B": {
    "family": "store",
    "name": "STOREX",
    "modes": {
      "00": {
        "mnem": "STOREX [XY]",
        "syntax": "STOREX Xn, [XYm]",
        "cycles": "3",
        "flags": "----",
        "note": "Store X register."
      },
      "01": {
        "mnem": "STOREX [XY+D]",
        "syntax": "STOREX Xn, [XYm+Do]",
        "cycles": "4",
        "flags": "----",
        "note": "Indexed."
      },
      "10": {
        "mnem": "STOREX [PC+i16]",
        "syntax": "STOREX Xn, [PC+imm16]",
        "cycles": "4",
        "flags": "----",
        "note": "PC-relative."
      },
      "11": {
        "mnem": "STOREX [XY+i5]",
        "syntax": "STOREX Xn, [XYm+imm5]",
        "cycles": "4",
        "flags": "----",
        "note": "Offset."
      }
    }
  },
  "1C": {
    "family": "store",
    "name": "STOREY",
    "modes": {
      "00": {
        "mnem": "STOREY [XY]",
        "syntax": "STOREY Yn, [XYm]",
        "cycles": "3",
        "flags": "----",
        "note": "Store Y register."
      },
      "01": {
        "mnem": "STOREY [XY+D]",
        "syntax": "STOREY Yn, [XYm+Do]",
        "cycles": "4",
        "flags": "----",
        "note": "Indexed."
      },
      "10": {
        "mnem": "STOREY [PC+i16]",
        "syntax": "STOREY Yn, [PC+imm16]",
        "cycles": "4",
        "flags": "----",
        "note": "PC-relative."
      },
      "11": {
        "mnem": "STOREY [XY+i5]",
        "syntax": "STOREY Yn, [XYm+imm5]",
        "cycles": "4",
        "flags": "----",
        "note": "Offset."
      }
    }
  },
  "1D": {
    "family": "store",
    "name": "STOREI / +",
    "modes": {
      "00": {
        "mnem": "STOREI #imm5",
        "syntax": "STOREI #imm5, [XYm]",
        "cycles": "2",
        "flags": "----",
        "note": "Store 0-31 immediate to memory."
      },
      "01": {
        "mnem": "STOREI #imm16",
        "syntax": "STOREI #imm16, [XYm]",
        "cycles": "3",
        "flags": "----",
        "note": "Store 16-bit immediate."
      },
      "10": {
        "mnem": "STOREXY",
        "syntax": "STOREXY XYn, [XYm]",
        "cycles": "6",
        "flags": "----",
        "note": "Store full 24-bit XY pair."
      },
      "11": {
        "mnem": "STOREP / STOREZ",
        "syntax": "STOREP Dn,Ym,[#imm16]\nSTOREZ Dn,[#imm16]",
        "cycles": "5",
        "flags": "----",
        "note": "Paged store, or page-$00 (ZOA) store. Byte variants STOREPB / STOREZB."
      }
    },
    "variants": ["STOREI", "STOREXY", "STOREP", "STOREPB", "STOREZ", "STOREZB"]
  },
  "1E": {
    "family": "trap",
    "name": "TRAP / RET",
    "modes": {
      "00": {
        "mnem": "TRAP",
        "syntax": "TRAP #n",
        "cycles": "12",
        "flags": "----",
        "note": "Software syscall. Leaf pattern: C=0 OK, C=1 error with D0=code."
      },
      "01": {
        "family": "alu",
        "mnem": "NEG",
        "syntax": "NEG Dn",
        "cycles": "3",
        "flags": "****",
        "note": "Two’s-complement negate (0 - src) - an arithmetic op: sets full C Z N V. V set if src = $8000. Encoded at $1E m01 but belongs to the ALU group."
      },
      "10": {
        "mnem": "RETCC / RETCS",
        "syntax": "RETCC\nRETCS",
        "cycles": "6",
        "flags": "w000",
        "note": "Return + set carry: RETCC writes SR=$00 (success), RETCS writes SR=$01 (error). Both in mode 10."
      },
      "11": {
        "mnem": "RET",
        "syntax": "RET  (+ #Nw cleanup)",
        "cycles": "6",
        "flags": "----",
        "note": "Plain return, optional stack cleanup."
      }
    }
  },
  "1F": {
    "family": "sys",
    "name": "INT / SYS",
    "modes": {
      "00": {
        "mnem": "DINT",
        "syntax": "DINT",
        "cycles": "2",
        "flags": "----",
        "note": "Disable interrupts. Critical before _Schedule in non-leaf syscalls."
      },
      "01": {
        "mnem": "EINT",
        "syntax": "EINT",
        "cycles": "2",
        "flags": "----",
        "note": "Enable interrupts."
      },
      "10": {
        "mnem": "RTI",
        "syntax": "RTI",
        "cycles": "8",
        "flags": "----",
        "note": "Return from interrupt."
      },
      "11": {
        "mnem": "INT",
        "syntax": "INT",
        "cycles": "16",
        "flags": "----",
        "note": "Hardware interrupt entry overhead (forces vector)."
      }
    }
  }
};
