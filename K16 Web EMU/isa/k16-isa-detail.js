/* K16 opcode decode data - curated editorial layer (hand-authored).
   Deep detail rendered only where present. The generator never overwrites this.
   Keys:
     "NN"     opcode-level  (all four modes are one instruction, e.g. CMP)  -> hex opcode
     "NN.mm"  mode-specific (modes are different instructions, e.g. $00)    -> hex opcode + mode bits
   Fields (all optional): oper, enc, forms, debug, flagsDetail, branches, branchNote, gotchas, seeAlso. */
window.K16_OPCODE_DETAIL = {
  "00.00": {
    "oper": "No operation. Optional #imm8 rides in the low byte and is ignored by the CPU.",
    "enc": [
      ["NOP", "0000 0000 iiii iiii", "$00 nn  (nn = imm8)"]
    ],
    "forms": [
      ["NOP", "m00", "2", "1"],
      ["NOP #imm8", "m00", "2", "1"]
    ],
    "gotchas": [
      "Magic NOP: NOP #$FF ($00FF) pauses the emulator - an EMU-only breakpoint. Hardware and Digital run it as an ordinary NOP.",
      "imm8 is otherwise ignored; NOP and NOP #imm8 are identical to the CPU."
    ],
    "seeAlso": [
      ["HALT", "stop the processor, with optional code"]
    ]
  },
  "00.01": {
    "oper": "Stop the processor. Optional #imm8 is a halt / debug code in the low byte.",
    "enc": [
      ["HALT", "0000 0010 iiii iiii", "$02 nn  (nn = code)"]
    ],
    "forms": [
      ["HALT", "m01", "2", "1"],
      ["HALT #imm8", "m01", "2", "1"]
    ],
    "debug": "On HALT the CPU drives D0 onto the ALU-A bus - read it on Digital to inspect D0 at the stop point.",
    "gotchas": [
      "imm8 is a software code only (e.g. exit status); the CPU stops regardless of its value."
    ],
    "seeAlso": [
      ["NOP", "no-op, or Magic NOP pause (#$FF)"]
    ]
  },
  "00.10": {
    "oper": "XYn = XYn + step   (24-bit pointer). Flag-transparent.",
    "enc": [
      ["INC XYn, #step", "0000 0100 0yyi iiii", "yy = XYn (0-3), i = step (1-31)"]
    ],
    "forms": [
      ["INC XYn, #step", "m10", "3 / 5", "1"]
    ],
    "gotchas": [
      "Flag-transparent: INC / DEC XYn never touch C Z N V (FLAGSX hardware). The old 'INC corrupts flags' workarounds are obsolete.",
      "5 cycles when the add crosses a page; carries propagate 6502-style across the 24-bit pointer.",
      "#step is mandatory - there is no implied +1."
    ],
    "seeAlso": [
      ["DEC XYn", "decrement the same pointer"],
      ["LEA", "form an address without a running counter"]
    ]
  },
  "00.11": {
    "oper": "XYn = XYn - step   (24-bit pointer). Flag-transparent.",
    "enc": [
      ["DEC XYn, #step", "0000 0110 0yyi iiii", "yy = XYn (0-3), i = step (1-31)"]
    ],
    "forms": [
      ["DEC XYn, #step", "m11", "4 / 6", "1"]
    ],
    "gotchas": [
      "Flag-transparent: INC / DEC XYn never touch C Z N V (FLAGSX hardware).",
      "6 cycles when the subtract crosses a page boundary.",
      "#step is mandatory - there is no implied -1."
    ],
    "seeAlso": [
      ["INC XYn", "increment the same pointer"]
    ]
  },
  "01": {
    "oper": "Dn = page[Dn].   The 16-bit value in Dn indexes a 64K-entry table at #page; the looked-up word replaces Dn. Flag-transparent.",
    "forms": [
      ["LOOKUP Dn, #page", "mode = Dn", "3", "1"]
    ],
    "enc": [
      ["LOOKUP Dn, #page", "00001 dd 0 pppppppp", "dd = Dn (the mode field selects D0-D3), pppppppp = page = high byte of the table's 24-bit address"]
    ],
    "pages": [
      ["SHL", "$E0", "Dn << 1   (x2)"],
      ["SHR", "$E2", "Dn >> 1   (/2 unsigned)"],
      ["ASR", "$E4", "Dn >> 1   (/2 signed)"],
      ["ROL", "$E6", "rotate left   (pure, no carry)"],
      ["ROR", "$E8", "rotate right   (pure, no carry)"],
      ["SWAPB", "$EA", "byte swap   ($1234 -> $3412)"],
      ["HIGH", "$EC", "high byte   (Dn >> 8)"],
      ["LOW", "$EE", "low byte   (Dn AND $00FF)"],
      ["SHR4", "$F0", "Dn >> 4   (/16 unsigned)"],
      ["SHL4", "$F2", "Dn << 4   (x16)"],
      ["ASR4", "$F4", "Dn >> 4   (/16 signed)"],
      ["ASR8", "$F6", "Dn >> 8   (/256 signed)"],
      ["MULB", "$F8", "hi byte x lo byte"],
      ["RECIP", "$FA", "65536 / Dn"]
    ],
    "gotchas": [
      "The mode field is the D-register selector (00 = D0 ... 11 = D3), NOT an addressing mode - every $01 op is a LOOKUP on one of D0-D3.",
      "Roll your own: point #page at a RAM page and you get an arbitrary 16 -> 16-bit function in 3 cycles. e.g. LOOKUP D0, #$10 reads table[D0] from RAM page $10.",
      "Flag-transparent - even ROL/ROR are PURE rotates: the out-bit wraps straight to the other end, it does not pass through C. For rotate-through-carry use the ADC idiom (section 11).",
      "MULB multiplies the two bytes of Dn - pack the operands first (SWAPB + OR idiom). RECIP gives 65536 / Dn."
    ],
    "seeAlso": [
      ["AND", "mask as an alternative to LOW"],
      ["ADC", "build rotate-through-carry"]
    ]
  },
  "02.00": {
    "oper": "Dn = word at [XYm], then XYm += stride.   Flag-transparent.",
    "enc": [
      ["LOADD Dn, [XYm]+", "00010 00 dd yy iiiii", "dd = Dn (0-3), yy = XYm (0-3), iiiii = stride (default 2, max 31)"]
    ],
    "forms": [
      ["Dn, [XYm]+ [, #stride]", "m00", "4 / 6", "1"]
    ],
    "gotchas": [
      "iiiii is a post-increment STRIDE, not an offset - the load uses [XYm] as-is, then advances XYm. Word stride defaults to 2 and must be even (the assembler errors on odd); #Nw is the word-count form (x2). Ceiling 31.",
      "Flag-transparent (FLAGSX): no C Z N V change. CMP the loaded value before branching.",
      "6 cycles when the access crosses a page. No offset form - for an indexed read use a plain LOADD Dn, [XYm+imm5]."
    ],
    "seeAlso": [
      ["LOADB", "byte version, stride default 1"],
      ["STORED", "store a word and advance"]
    ]
  },
  "02.01": {
    "oper": "Dn = byte at [XYm], then XYm += stride.   Flag-transparent.",
    "enc": [
      ["LOADB Dn, [XYm]+", "00010 01 dd yy iiiii", "dd = Dn, yy = XYm, iiiii = stride (default 1, max 31)"]
    ],
    "forms": [
      ["Dn, [XYm]+ [, #stride]", "m01", "4 / 6", "1"]
    ],
    "gotchas": [
      "Byte load; stride defaults to 1. iiiii is the post-increment, not an offset.",
      "Flag-transparent: CMP the value before branching."
    ],
    "seeAlso": [
      ["LOADD", "word version, stride default 2"],
      ["STOREB", "store a byte and advance"]
    ]
  },
  "02.10": {
    "oper": "word at [XYm] = Dn, then XYm += stride.   Flag-transparent.",
    "enc": [
      ["STORED Dn, [XYm]+", "00010 10 dd yy iiiii", "dd = Dn, yy = XYm, iiiii = stride (default 2, max 31)"]
    ],
    "forms": [
      ["Dn, [XYm]+ [, #stride]", "m10", "5 / 7", "1"]
    ],
    "gotchas": [
      "Stores Dn as a word, then advances XYm by stride (default 2, must be even; #Nw is the word-count form, x2; ceiling 31).",
      "Flag-transparent; 7 cycles on a page-cross."
    ],
    "seeAlso": [
      ["STOREB", "byte version, stride default 1"],
      ["LOADD", "load a word and advance"]
    ]
  },
  "02.11": {
    "oper": "byte at [XYm] = Dn (low 8 bits), then XYm += stride.   Flag-transparent.",
    "enc": [
      ["STOREB Dn, [XYm]+", "00010 11 dd yy iiiii", "dd = Dn, yy = XYm, iiiii = stride (default 1, max 31)"]
    ],
    "forms": [
      ["Dn, [XYm]+ [, #stride]", "m11", "5 / 7", "1"]
    ],
    "gotchas": [
      "Writes the low byte of Dn, then advances XYm by stride (default 1).",
      "Flag-transparent; 7 cycles on a page-cross."
    ],
    "seeAlso": [
      ["STORED", "word version, stride default 2"],
      ["LOADB", "load a byte and advance"]
    ]
  },
  "03": {
    "oper": "XYn = effective address.   Forward-only and page-safe; flag-transparent.",
    "forms": [
      ["XYn, XYm", "m00", "3", "1"],
      ["XYn, XYm+Do", "m01", "4 / 6", "1"],
      ["XYn, label", "m10", "5", "2"],
      ["XYn, XYm+#imm5", "m11", "4 / 6", "1"]
    ],
    "enc": [
      ["LEA XYn, XYm", "00011 00 nn mm 00000", "nn = XYn dest, mm = XYm src"],
      ["LEA XYn, XYm+Do", "00011 01 nn mm dd 000", "dd = Do index (unsigned)"],
      ["LEA XYn, label", "00011 10 nn 0000000", "+ signed imm16 in next word (PC-relative)"],
      ["LEA XYn, XYm+#imm5", "00011 11 nn mm iiiii", "iiiii = unsigned 0-31 offset"]
    ],
    "gotchas": [
      "Forward-only: no LEA mode can decrement the page byte (Y). To move an address backward across a page, use DEC XY or build it with MOVE.",
      "Mode 10 (label) is page-LOCAL: low word = PC + signed imm16 (carry discarded), Yn = PCH directly. The label must sit in the same 64KB page - the assembler warns if not. It reaches both forward and backward within that page.",
      "Modes 00 / 01 / 11 are page-safe (a carry out of X propagates into Y). Only mode 10 is page-local.",
      "For an in-place +/- on the same XYn, INC/DEC XY is cheaper (3-4 cyc). Use LEA for a different destination, a copy, a variable index, or a PC-relative label."
    ],
    "seeAlso": [
      ["INC XYn", "cheapest in-place pointer bump"],
      ["DEC XYn", "in-place decrement (can cross a page backward)"],
      ["MOVE", "arbitrary 24-bit pointer construction"]
    ]
  },
  "04": {
    "oper": "dst = $FFFF when the condition is true, else $0000 (or the optional false-value #imm16).   Flags not affected.",
    "enc": [
      ["Scc dst", "00100 00 1 sss dddd 0", "sss = condition (IR7-5, same codes as Bcc); dddd = dst; followed by a false-value word (imm16, $0000 if omitted)"]
    ],
    "forms": [
      ["Scc dst", "set", "4", "2"],
      ["Scc dst, #imm16", "set", "4", "2"]
    ],
    "condTable": {
      "head": "condition (sss = IR7-5, identical to Bcc)",
      "cols": ["cond", "code", "true when", "meaning"],
      "rows": [
        ["SEQ", "000", "Z=1", "equal / zero"],
        ["SNE", "001", "Z=0", "not equal"],
        ["SCS/SHS", "010", "C=1", "carry set / unsigned >="],
        ["SCC/SLO", "011", "C=0", "carry clear / unsigned <"],
        ["SLT", "100", "N != V", "less than (signed)"],
        ["SGT", "101", "Z=0 and N=V", "greater than (signed)"],
        ["SGE", "110", "N = V", "greater or equal (signed)"],
        ["SLE", "111", "Z=1 or N!=V", "less or equal (signed)"]
      ]
    },
    "gotchas": [
      "Result is $FFFF (true) / $0000 (false), NOT 1/0 - deliberately all-ones so it can be ANDed straight against a value as a conditional mask with no sign-extend. A pre-14-May-2026 EMU build wrongly produced 1/0; Digital and the TTL hardware always gave $FFFF/$0000.",
      "Always a 2-word instruction - the second word is the false value. Scc dst writes $0000 there; Scc dst, #imm16 chooses it (true always forces $FFFF).",
      "Reads flags, writes none. Set them with CMP / SUB / a logic op first, exactly like Bcc. SLT/SGT/SGE/SLE depend on V, so they only mean anything after a signed CMP.",
      "Same condition codes as Bcc (sss = ccc): if you know the branch mnemonic you know the set mnemonic."
    ],
    "seeAlso": [
      ["Bcc", "same conditions, branches instead of setting"],
      ["CMP", "sets the flags Scc tests"]
    ]
  },
  "05.00": {
    "oper": "dst = Dn.   Source is a D register (D0-D3); dst is D / X / Y / PC. Flag-transparent.",
    "forms": [["dst, Dn", "m00", "3", "1"]],
    "enc": [["MOVE dst, Dn", "00101 00 dddd ssss 0", "dddd dst: 0-3 D, 4-7 X, 8-B Y, F PC.   ssss = source D (0-3)"]],
    "gotchas": [
      "Destination can be X, Y or PC as well as D - e.g. MOVE PC, D0 jumps to the address in D0.",
      "MOVE to Y truncates the source to 8 bits (Y is the page byte). See B.9.",
      "Flag-transparent: MOVE never sets C Z N V - CMP before branching on a moved value."
    ],
    "seeAlso": [["MOVE dst, src", "source from X/Y/SR/PC (mode 01)"], ["SWAP", "exchange two registers"]]
  },
  "05.01": {
    "oper": "dst = src,  src in { X / Y / SR / PC }, routed via T16.   dst is D / X / Y / PC. Flag-transparent.",
    "forms": [["dst, src", "m01", "4", "1"]],
    "enc": [["MOVE dst, src", "00101 01 dddd ssss 0", "ssss src: 4-7 X, 8-B Y, C/D SR, E/F PC (via T16).   dddd dst: 0-3 D, 4-7 X, 8-B Y, F PC"]],
    "gotchas": [
      "Source is X, Y, SR or PC (not D); it is routed through the T16 temp - that is the extra cycle over mode 00.",
      "MOVE D0, X0 copies the 16-bit X; MOVE D0, Yn reads the 8-bit page byte; MOVE Dn, SR reads the status register.",
      "SR is read-only here - there is no SR destination in either MOVE mode.",
      "Flag-transparent."
    ],
    "seeAlso": [["MOVE dst, Dn", "source from a D register (mode 00)"], ["SWAP Dn, Xn/Yn", "exchange D with X or Y"]]
  },
  "05.10": {
    "oper": "Dn <-> Xn/Yn   (exchange a D register with a single X or Y register). Flag-transparent.",
    "forms": [["Dn, Xn/Yn", "m10", "4", "1"]],
    "enc": [["SWAP Dn, Xn/Yn", "00101 10 dddd ssss 0", "one operand is D (0-3), the other an X (4-7) or Y (8-B) register"]],
    "gotchas": [
      "One operand is a D register, the other a single X or Y register - NOT the full 24-bit XY pair.",
      "Flag-transparent."
    ],
    "seeAlso": [["SWAP Xn/Yn, Xn/Yn", "exchange two X/Y registers"], ["MOVE", "one-way copy"]]
  },
  "05.11": {
    "oper": "Xn/Yn <-> Xn/Yn   (exchange two X or Y registers). Flag-transparent.",
    "forms": [["Xn/Yn, Xn/Yn", "m11", "5", "1"]],
    "enc": [["SWAP Xn/Yn, Xn/Yn", "00101 11 dddd ssss 0", "both operands X (4-7) or Y (8-B) registers; two T16 passes"]],
    "gotchas": [
      "Both operands are single X or Y registers, not 24-bit XY pairs; the exchange needs two T16 passes, hence 5 cycles.",
      "Flag-transparent."
    ],
    "seeAlso": [["SWAP Dn, Xn/Yn", "exchange D with an X or Y register"]]
  },
  "06.00": {
    "oper": "XYsp -= 2, then word at [XYsp] = Dn (D0-D3).   Full-descending word stack. Flag-transparent.",
    "enc": [
      ["PUSH Dn, XYsp", "00110 00 00dd 00 yy 0", "dd = D register (0-3 only); yy = XYsp (XY0-3)"]
    ],
    "forms": [
      ["Dn, XYsp", "m00", "5", "1"]
    ],
    "gotchas": [
      "Pre-decrement: XYsp drops by 2 FIRST, then the word is stored. Two bytes per element, full-descending.",
      "D-only. The register field accepts just D0-D3 here - single X / Y / FLAGS / PC push through mode 11 (PUSH splits the single forms by ALU pass-through path: D via ALU-A, the rest via ALU-B).",
      "yy picks which XY register is the stack pointer - any of XY0-XY3, so several independent stacks can run at once.",
      "Flag-transparent: PUSH never touches C Z N V."
    ],
    "seeAlso": [
      ["POP reg, XYsp", "POP m00 takes any register in one mode"],
      ["PUSH reg, XYsp", "single X / Y / FLAGS / PC (m11)"],
      ["PUSH XYn, XYsp", "push a 24-bit pair instead"]
    ]
  },
  "06.01": {
    "oper": "Push D1, D2, D3 (D0 untouched).   Each: XYsp -= 2, [XYsp] = Dn.   Flag-transparent.",
    "enc": [
      ["PUSH D123, XYsp", "00110 01 0000 00 yy 0", "fixed group D1/D2/D3, REG field unused; yy = XYsp"]
    ],
    "forms": [
      ["D123, XYsp", "m01", "11", "1"]
    ],
    "gotchas": [
      "Saves exactly D1, D2, D3 - D0 is NOT pushed. Push order D1 -> D2 -> D3, so D3 ends up on top.",
      "Pair with POP D123, XYsp which restores in reverse (D3 -> D2 -> D1). D0 survives the save/restore pair untouched - handy for keeping a scratch or result register live across a call.",
      "Flag-transparent."
    ],
    "seeAlso": [
      ["POP D123, XYsp", "restore the group (reverse order)"]
    ]
  },
  "06.10": {
    "oper": "Push the 24-bit XYn pair onto XYsp as two words (X first, then Y).   Flag-transparent.",
    "enc": [
      ["PUSH XYn, XYsp", "00110 10 pp00 00 yy 0", "pp (IR8-7) = pair to push (XY0-3); yy = XYsp"]
    ],
    "forms": [
      ["XYn, XYsp", "m10", "8", "1"]
    ],
    "gotchas": [
      "Pushes X first, then Y (two words). POP XYn restores Y then X (reverse). Pre-decrement per word.",
      "pp lives in IR8-7. Use a different register for XYn and XYsp - a pair pushing onto itself is not meaningful.",
      "Flag-transparent."
    ],
    "seeAlso": [
      ["POP XYn, XYsp", "restore the pair"]
    ]
  },
  "06.11": {
    "oper": "Push a single non-D register (X / Y / ORDB / FLAGS / PCH / PCL) onto XYsp.   XYsp -= 2, then store.   Flag-transparent.",
    "enc": [
      ["PUSH reg, XYsp", "00110 11 rrrr 00 yy 0", "rrrr: 4-7 X0-X3, 8-B Y0-Y3, C ORDB, D FLAGS (= SR), E PCH, F PCL; yy = XYsp"]
    ],
    "forms": [
      ["Xn/Yn, XYsp", "m11", "5", "1"],
      ["SR, XYsp", "m11", "5", "1"]
    ],
    "gotchas": [
      "Covers every single register EXCEPT D - X, Y, ORDB, FLAGS (= SR), PCH, PCL. Single D registers push through mode 00; the split is because D drives ALU-A and the rest drive ALU-B.",
      "This is the flag-save path: PUSH SR, XYsp on entry (reg code FLAGS), POP SR, XYsp on exit (POP rewrites C Z N V). Reading FLAGS to push it is flag-transparent.",
      "PCH and PCL can be pushed individually - useful for hand-building a return address.",
      "Pre-decrement; full-descending word stack."
    ],
    "seeAlso": [
      ["POP reg, XYsp", "POP SR restores the flags (m00)"],
      ["PUSH Dn, XYsp", "single D register via m00"]
    ]
  },
  "07.00": {
    "oper": "reg = word at [XYsp], then XYsp += 2.   reg may be any of D / X / Y / ORDB / FLAGS / PCH / PCL. POP FLAGS rewrites flags; other targets flag-transparent.",
    "enc": [
      ["POP reg, XYsp", "00111 00 rrrr 00 yy 0", "rrrr: 0-3 D, 4-7 X, 8-B Y, C ORDB, D FLAGS (= SR), E PCH, F PCL; yy = XYsp"]
    ],
    "forms": [
      ["reg, XYsp", "m00", "4", "1"]
    ],
    "gotchas": [
      "Post-increment: the word is READ from [XYsp] first, then XYsp rises by 2.",
      "Unlike PUSH (which splits single D into m00 and X/Y/FLAGS/PC into m11), POP handles every single register in this one mode - the destination write path is uniform.",
      "POP FLAGS (= SR) is the one variant that writes C Z N V (it restores saved flags). Popping into D/X/Y is flag-transparent - CMP before branching on a popped value.",
      "yy selects which XY is the stack pointer."
    ],
    "seeAlso": [
      ["PUSH Dn, XYsp", "push a single D (m00)"],
      ["PUSH reg, XYsp", "push single X/Y/FLAGS/PC (m11)"],
      ["POP D123, XYsp", "pop the data-register group"]
    ]
  },
  "07.01": {
    "oper": "Pop D3, D2, D1 (reverse of push); D0 untouched.   Flag-transparent.",
    "enc": [
      ["POP D123, XYsp", "00111 01 0000 00 yy 0", "fixed group D1/D2/D3; yy = XYsp"]
    ],
    "forms": [
      ["D123, XYsp", "m01", "8", "1"]
    ],
    "gotchas": [
      "Restores D3 -> D2 -> D1, the reverse of PUSH D123's D1 -> D2 -> D3. D0 is left untouched.",
      "Flag-transparent."
    ],
    "seeAlso": [
      ["PUSH D123, XYsp", "save the group"]
    ]
  },
  "07.10": {
    "oper": "Pop the XYn pair (Y first, then X - reverse of push).   Flag-transparent.",
    "enc": [
      ["POP XYn, XYsp", "00111 10 pp00 00 yy 0", "pp (IR8-7) = pair; yy = XYsp"]
    ],
    "forms": [
      ["XYn, XYsp", "m10", "6", "1"]
    ],
    "gotchas": [
      "Restores in reverse of the push: Y first, then X. Post-increment per word.",
      "Flag-transparent."
    ],
    "seeAlso": [
      ["PUSH XYn, XYsp", "save the pair"]
    ]
  },
  "07.11": {
    "oper": "Push a 16-bit immediate: XYsp -= 2, then word at [XYsp] = #imm16.   Flag-transparent.",
    "enc": [
      ["PUSH #imm16, XYsp", "00111 11 0000 00 yy 0", "+ imm16 in the next word; yy = XYsp"]
    ],
    "forms": [
      ["#imm16, XYsp", "m11", "5", "2"]
    ],
    "gotchas": [
      "The odd one out: $07 (POP) mode 11 is actually a PUSH - it pushes a 16-bit immediate. Two-word instruction (opcode word + imm16 word); PC steps over the imm16 on completion.",
      "Pre-decrement like any push; flag-transparent. Handy for pushing a return tag, constant, or argument without first loading a register.",
      "It lives under POP because PUSH ($06) mode 11 is already taken by the single X/Y/FLAGS/PC form - the assembler hides this, you just write PUSH #imm16, XYsp."
    ],
    "seeAlso": [
      ["PUSH Dn, XYsp", "push a register instead"],
      ["PUSH reg, XYsp", "push single X/Y/FLAGS/PC"]
    ]
  },
  "08": {
    "oper": "dst = dst + src.   Carry is carry-OUT (standard), not a borrow.",
    "enc": [
      ["ADD dr, sr | [XYsr]", "01000 0m dddd ssss 0", "m: 0 = Dsr (reg) &middot; 1 = [XYsr] (indirect)"],
      ["ADD dr, #imm", "01000 1m dddd iiiii", "m: 0 = #imm5 &middot; 1 = #imm16 (in next word, field = 00000)"]
    ],
    "forms": [
      ["Dn, Dm", "m00", "4", "1"],
      ["Dn, [XYm]", "m01", "4", "1"],
      ["Dn, #imm5", "m10", "3", "1"],
      ["Dn, #imm16", "m11", "4", "2"]
    ],
    "flagsDetail": [
      ["C = 1", "carry out - unsigned result &gt; $FFFF"],
      ["C = 0", "no carry out"],
      ["V = 1", "signed overflow"],
      ["Z = 1", "result = 0"],
      ["N = 1", "result bit 15 set"]
    ],
    "gotchas": [
      "Carry here is carry-OUT - the opposite role to SUB/CMP, where C = 1 means no borrow. Don't read ADD's carry with borrow logic.",
      "ADD takes no carry-in. For multi-word sums, ADD the low word then ADC each higher word."
    ],
    "seeAlso": [
      ["ADC", "add the next word with carry-in"],
      ["SUB", "subtract (6502 borrow sense)"]
    ]
  },
  "09": {
    "oper": "dst = dst + src + C.   Add-with-carry for multi-word sums.",
    "enc": [
      ["ADC dr, sr | [XYsr]", "01001 0m dddd ssss 0", "m: 0 = Dsr (reg) &middot; 1 = [XYsr]"],
      ["ADC dr, #imm", "01001 1m dddd iiiii", "m: 0 = #imm5 &middot; 1 = #imm16 (next word)"]
    ],
    "forms": [
      ["Dn, Dm", "m00", "4", "1"],
      ["Dn, [XYm]", "m01", "4", "1"],
      ["Dn, #imm5", "m10", "3", "1"],
      ["Dn, #imm16", "m11", "4", "2"]
    ],
    "flagsDetail": [
      ["C = 1", "carry out of this word - feeds the next ADC"],
      ["V = 1", "signed overflow"],
      ["Z = 1", "result = 0"],
      ["N = 1", "result bit 15 set"]
    ],
    "gotchas": [
      "ADC adds carry-IN. Start a multi-word add with ADD (low word, no carry-in), then ADC for each higher word.",
      "Carry here is the standard carry-out / carry-in, never the borrow sense of SUB/SBC."
    ],
    "seeAlso": [
      ["ADD", "add the low word (no carry-in)"],
      ["SBC", "the subtract-side counterpart"]
    ]
  },
  "0A": {
    "oper": "dst = dst - src.   6502 borrow: C = 1 means no borrow (dst &ge; src).",
    "enc": [
      ["SUB dr, sr | [XYsr]", "01010 0m dddd ssss 0", "m: 0 = Dsr (reg) &middot; 1 = [XYsr] (indirect)"],
      ["SUB dr, #imm", "01010 1m dddd iiiii", "m: 0 = #imm5 &middot; 1 = #imm16 (next word, field = 00000)"]
    ],
    "forms": [
      ["Dn, Dm", "m00", "4", "1"],
      ["Dn, [XYm]", "m01", "4", "1"],
      ["Dn, #imm5", "m10", "4", "1"],
      ["Dn, #imm16", "m11", "4", "2"]
    ],
    "flagsDetail": [
      ["Z = 1", "result = 0  (dst = src)"],
      ["C = 1", "no borrow  (dst &ge; src unsigned)"],
      ["C = 0", "borrow  (dst &lt; src unsigned)"],
      ["N = V", "dst &ge; src  signed"],
      ["N &ne; V", "dst &lt; src  signed"]
    ],
    "branches": [
      ["A &lt; B", "BCC / BLO", "BLT"],
      ["A &le; B", "BLS *", "BLE"],
      ["A = B", "BEQ", "BEQ"],
      ["A &ne; B", "BNE", "BNE"],
      ["A &gt; B", "BHI *", "BGT"],
      ["A &ge; B", "BCS / BHS", "BGE"]
    ],
    "branchHead": "after SUB A,B",
    "branchNote": "* BHI / BLS are assembler pseudo-branches.",
    "gotchas": [
      "6502 carry sense: after SUB, C = 1 means no borrow (dst &ge; src) - the opposite of x86/ARM. BCS = &ge;, BCC = underflow.",
      "SUB keeps the result in dst; use CMP when you only want the flags.",
      "SUB D0, #1 from D0 = 0 sets C = 0 (a borrow did occur) - 0 - 1 wraps to $FFFF.",
      "For multi-word subtract, SUB the low word then SBC the rest."
    ],
    "seeAlso": [
      ["CMP", "same flags, discards the result"],
      ["SBC", "subtract the next word with borrow-in"],
      ["Bcc", "branch on the result"]
    ]
  },
  "0B": {
    "oper": "dst = dst - src - ~C.   Subtract-with-borrow; borrow-in = inverted carry.",
    "enc": [
      ["SBC dr, sr | [XYsr]", "01011 0m dddd ssss 0", "m: 0 = Dsr (reg) &middot; 1 = [XYsr]"],
      ["SBC dr, #imm", "01011 1m dddd iiiii", "m: 0 = #imm5 &middot; 1 = #imm16 (next word)"]
    ],
    "forms": [
      ["Dn, Dm", "m00", "4", "1"],
      ["Dn, [XYm]", "m01", "4", "1"],
      ["Dn, #imm5", "m10", "4", "1"],
      ["Dn, #imm16", "m11", "4", "2"]
    ],
    "flagsDetail": [
      ["C = 1", "no borrow out - feeds the next SBC"],
      ["C = 0", "borrow out"],
      ["Z = 1", "result = 0"],
      ["N = V", "result &ge; 0  signed"]
    ],
    "gotchas": [
      "SBC reads the inverted carry as borrow-in (dst - src - ~C). After a SUB with no borrow (C = 1), ~C = 0 so SBC subtracts nothing extra.",
      "Set C = 1 (no borrow) before the first SBC of a chain - the low-word SUB does this for you.",
      "Same 6502 sense as SUB: C = 1 means no borrow."
    ],
    "seeAlso": [
      ["SUB", "subtract the low word (sets the initial borrow)"],
      ["ADC", "the add-side counterpart"]
    ]
  },
  "0C": {
    "oper": "dst = dst AND src.   C cleared; Z, N from result; V unaffected.",
    "enc": [
      ["AND dst, src", "01100 0m dddd ssss 0", "m=0 reg (ssss = src D), m=1 mem (ssss = [XYn])"],
      ["AND dst, #imm", "01100 1m dddd iiiii", "m=0 imm5 (iiiii, 0-31), m=1 imm16 (next word; iiiii = 00000)"]
    ],
    "forms": [
      ["dst, src", "m00", "4", "1"],
      ["dst, [XYn]", "m01", "4", "1"],
      ["dst, #imm5", "m10", "3", "1"],
      ["dst, #imm16", "m11", "4", "2"]
    ],
    "flagsDetail": [
      ["C", "cleared to 0 (every logic op clears carry)"],
      ["Z", "set if result = 0"],
      ["N", "set if result bit 15 = 1"],
      ["V", "unaffected"]
    ],
    "gotchas": [
      "C is always CLEARED - never assume carry survives a logic op. (It is a reliable way to clear carry, though.)",
      "Flags follow the result, so AND D0, D0 is a free zero/sign test - sets Z/N without changing D0, no CMP needed.",
      "#imm16 (m11) accepts a negative immediate as an idiomatic mask, e.g. AND D0, #-2 clears bit 0. imm5 (m10) is unsigned 0-31."
    ],
    "seeAlso": [
      ["OR", "bitwise OR"],
      ["XOR", "bitwise XOR"],
      ["NOT", "ones-complement"]
    ]
  },
  "0D": {
    "oper": "dst = dst OR src.   C cleared; Z, N from result; V unaffected.",
    "enc": [
      ["OR dst, src", "01101 0m dddd ssss 0", "m=0 reg (ssss = src D), m=1 mem (ssss = [XYn])"],
      ["OR dst, #imm", "01101 1m dddd iiiii", "m=0 imm5 (iiiii, 0-31), m=1 imm16 (next word; iiiii = 00000)"]
    ],
    "forms": [
      ["dst, src", "m00", "4", "1"],
      ["dst, [XYn]", "m01", "4", "1"],
      ["dst, #imm5", "m10", "3", "1"],
      ["dst, #imm16", "m11", "4", "2"]
    ],
    "flagsDetail": [
      ["C", "cleared to 0 (every logic op clears carry)"],
      ["Z", "set if result = 0"],
      ["N", "set if result bit 15 = 1"],
      ["V", "unaffected"]
    ],
    "gotchas": [
      "C is always CLEARED - logic ops never preserve carry.",
      "OR D0, D0 sets Z/N from D0 untouched - a free zero/sign test, same trick as AND.",
      "OR D0, #imm5 sets low bits cheaply (1 word, 3 cyc); OR D0, #$8000 sets bit 15 via the imm16 form."
    ],
    "seeAlso": [
      ["AND", "bitwise AND"],
      ["XOR", "bitwise XOR"],
      ["NOT", "ones-complement"]
    ]
  },
  "0E": {
    "oper": "dst = dst XOR src.   C cleared; Z, N from result; V unaffected.",
    "enc": [
      ["XOR dst, src", "01110 0m dddd ssss 0", "m=0 reg (ssss = src D), m=1 mem (ssss = [XYn])"],
      ["XOR dst, #imm", "01110 1m dddd iiiii", "m=0 imm5 (iiiii, 0-31), m=1 imm16 (next word; iiiii = 00000)"]
    ],
    "forms": [
      ["dst, src", "m00", "4", "1"],
      ["dst, [XYn]", "m01", "4", "1"],
      ["dst, #imm5", "m10", "3", "1"],
      ["dst, #imm16", "m11", "4", "2"]
    ],
    "flagsDetail": [
      ["C", "cleared to 0 (every logic op clears carry)"],
      ["Z", "set if result = 0"],
      ["N", "set if result bit 15 = 1"],
      ["V", "unaffected"]
    ],
    "gotchas": [
      "XOR D0, D0 is the idiomatic fast register clear - 1 word, 4 cyc, and it leaves Z=1.",
      "XOR D0, #$FFFF complements every bit - same result as NOT D0 (the imm16 form is 2 words vs NOT's 1).",
      "C is always CLEARED."
    ],
    "seeAlso": [
      ["NOT", "dedicated ones-complement (1 word in-place)"],
      ["AND", "bitwise AND"],
      ["OR", "bitwise OR"]
    ]
  },
  "0F": {
    "oper": "dst = NOT src (ones-complement).   C cleared; Z, N from result; V unaffected.",
    "enc": [
      ["NOT dst, src", "01111 00 dddd ssss 0", "m00 two-operand: dst = ~src (ssss = src D)"],
      ["NOT dst, [XYn]", "01111 01 dddd ssss 0", "m01: dst = ~mem[XYn]"],
      ["NOT dst", "01111 10 dddd 00000", "m10 in-place: dst = ~dst (no src field)"],
      ["NOT dst, #imm16", "01111 11 dddd 00000", "m11: dst = ~imm16 (next word)"]
    ],
    "forms": [
      ["dst, src", "m00", "4", "1"],
      ["dst, [XYn]", "m01", "4", "1"],
      ["dst", "m10", "4", "1"],
      ["dst, #imm16", "m11", "4", "2"]
    ],
    "flagsDetail": [
      ["C", "cleared to 0 (every logic op clears carry)"],
      ["Z", "set if result = 0"],
      ["N", "set if result bit 15 = 1"],
      ["V", "unaffected"]
    ],
    "gotchas": [
      "Two ways to complement: NOT dst, src (m00) copies-and-inverts into a different register; NOT dst (m10) inverts in place. Different modes - the in-place form carries no src field.",
      "C is cleared like the other logic ops. For a two's-complement negate, NOT dst then ADD dst, #1.",
      "NOT dst, #imm16 just loads the complement of a constant (2 words) - equivalent to a LOADI of ~imm16."
    ],
    "seeAlso": [
      ["XOR", "XOR dst, #$FFFF is an equivalent complement"],
      ["AND", "bitwise AND"],
      ["OR", "bitwise OR"]
    ]
  },
  "10": {
    "oper": "dst - src  ->  flags only (result discarded)",
    "forms": [
      ["Dn, Dm", "m00", "3", "1"],
      ["Dn, [XYm]", "m01", "3", "1"],
      ["Dn, #imm5", "m10", "3", "1"],
      ["Dn, #imm16", "m11", "3", "2"]
    ],
    "flagsDetail": [
      ["Z = 1", "A = B"],
      ["Z = 0", "A != B"],
      ["C = 1", "A >= B   unsigned (no borrow)"],
      ["C = 0", "A < B   unsigned (borrow)"],
      ["N = V", "A >= B   signed"],
      ["N != V", "A < B   signed"]
    ],
    "branches": [
      ["A &lt; B", "BCC / BLO", "BLT"],
      ["A &le; B", "BLS *", "BLE"],
      ["A = B", "BEQ", "BEQ"],
      ["A &ne; B", "BNE", "BNE"],
      ["A &gt; B", "BHI *", "BGT"],
      ["A &ge; B", "BCS / BHS", "BGE"]
    ],
    "branchNote": "* BHI / BLS are assembler pseudo-branches.",
    "gotchas": ["6502 carry sense: after CMP, C = 1 means A &ge; B (no borrow). It is NOT an error flag - do not read BCS as \"failed\".", "CMP changes flags only; both operands are left untouched (unlike SUB).", "Loads are flag-transparent, so CMP Dn, #0 is the idiom to set Z / N on a freshly loaded value before branching."],
    "seeAlso": [
      ["SUB", "same flags, keeps the result"],
      ["Scc", "set a register on the same condition"],
      ["Bcc", "branch on the result"]
    ]
  },
  "11": {
    "oper": "If the condition holds, PC = PC + offset.   Flags are not affected.",
    "enc": [
      ["Bcc.S target", "10001 00 0 ccc iiiii", "ccc = cond: BEQ 000 &middot; BNE 001 &middot; BCS/BHS 010 &middot; BCC/BLO 011 &middot; BLT 100 &middot; BGT 101 &middot; BGE 110 &middot; BLE 111.   iiiii = imm5"],
      ["Bcc.L target", "10001 01 0 ccc 00000", "+ imm16 in the next word"],
      ["BRA.S target", "10001 10 0 000 iiiii", "unconditional (cond = 000), imm5"],
      ["BRA.L target", "10001 11 0 000 00000", "+ imm16 in the next word"]
    ],
    "forms": [
      ["Bcc.S target", "m00", "3", "1"],
      ["Bcc.L target", "m01", "4", "2"],
      ["BRA.S target", "m10", "3", "1"],
      ["BRA.L target", "m11", "4", "2"]
    ],
    "branches": [
      ["A &lt; B", "BCC / BLO", "BLT"],
      ["A &le; B", "BLS *", "BLE"],
      ["A = B", "BEQ", "BEQ"],
      ["A &ne; B", "BNE", "BNE"],
      ["A &gt; B", "BHI *", "BGT"],
      ["A &ge; B", "BCS / BHS", "BGE"]
    ],
    "branchHead": "after CMP / SUB A,B",
    "branchNote": "* BHI / BLS are assembler pseudo-branches (&sect;6.15).",
    "gotchas": [
      "6502 carry sense: BCS/BHS = C=1 = &ge; (no borrow); BCC/BLO = C=0 = &lt; (borrow). BCS is not \"branch on error\".",
      ".S short form reaches forward only, 0-31 bytes; use the .L form for longer or backward targets.",
      "Branches are flag-transparent, and so is LOAD/MOVE - put a CMP or SUB just before the branch to set flags on a freshly loaded value.",
      "BGT / BLE are compound (Z with N/V); BHI / BLS are pseudo-branches expanding to BEQ + BHS/BLO."
    ],
    "seeAlso": [
      ["CMP", "set flags without keeping a result"],
      ["SUB", "set the same flags, keep the result"],
      ["Scc", "set a register on the condition instead of branching"]
    ]
  },
  "12.00": {
    "oper": "PC <- addr24.   Unconditional 24-bit absolute jump (anywhere in the 16MB space). Flag-transparent.",
    "enc": [
      ["JMP24 #addr24", "10010 00 0 hhhhhhhh", "IR7-0 = high byte (addr 23-16); next word = low 16 bits (15-0)"]
    ],
    "forms": [
      ["#addr24", "m00", "2", "2"]
    ],
    "gotchas": [
      "JMP is the assembler alias for JMP24 - the default jump form.",
      "Packed into 2 words: the high byte (23-16) rides in the opcode word's low 8 bits, the low 16 bits follow as one IMM16 word. (Manual 6.9 lists 3 words; the actual encoding is 2.)",
      "Flag-transparent - JMP never touches C Z N V."
    ],
    "seeAlso": [
      ["JMP16", "in-page 16-bit jump"],
      ["JMPXY", "indirect jump via XY"],
      ["CALL24", "the call-and-return version"]
    ]
  },
  "12.01": {
    "oper": "PC[15:0] <- addr16; page (PC[23:16]) unchanged.   In-page jump. Flag-transparent.",
    "enc": [
      ["JMP16 #addr16", "10010 01 0 00000000", "+ imm16 (low 16 bits); page bits stay put"]
    ],
    "forms": [
      ["#addr16", "m01", "2", "2"]
    ],
    "gotchas": [
      "Only the low 16 bits of PC change - the current 64KB page is preserved. Cross pages with JMP24.",
      "Same 2 words / 2 cycles as JMP24, just less reach.",
      "Flag-transparent."
    ],
    "seeAlso": [
      ["JMP24", "full 24-bit jump"]
    ]
  },
  "12.10": {
    "oper": "Indexed indirect (jump table): EA = Xn + Dm; PC <- Yn : mem[Yn:EA].   Page-local. Flag-transparent.",
    "enc": [
      ["JMPT XYn, Dm", "10010 10 dd yy 00000", "dd = Dm (IR8-7), yy = XYn (IR6-5)"]
    ],
    "forms": [
      ["XYn, Dm", "m10", "4", "1"]
    ],
    "gotchas": [
      "NOT a jump to XYn - it reads the target word FROM memory. EA = Xn + Dm (16-bit add, page-local), then PC = Yn : mem[Yn:EA]. Both operands are required.",
      "Dm must be a WORD offset into the table - index * 2 (each entry is a 16-bit target). The table is page-local (lives in page Yn).",
      "Classic dispatch: XY1 = table base, D0 = (token - base) * 2, then JMPT XY1, D0. Flag-transparent."
    ],
    "seeAlso": [
      ["JMPXY", "direct indirect (no memory read)"],
      ["JMP24", "absolute jump"]
    ]
  },
  "12.11": {
    "oper": "PC <- XYn (the full 24-bit value Yn:Xn in the register).   Direct indirect jump. Flag-transparent.",
    "enc": [
      ["JMPXY XYn", "10010 11 00 yy 00000", "yy = XYn (IR6-5)"]
    ],
    "forms": [
      ["XYn", "m11", "3", "1"]
    ],
    "gotchas": [
      "Jumps straight to the address held in XYn - no memory read, unlike JMPT.",
      "Computed-goto building block: LEA or MOVE a target into XYn, then JMPXY.",
      "Flag-transparent."
    ],
    "seeAlso": [
      ["JMPT", "table lookup version"],
      ["CALLXY", "call through XY instead of jump"]
    ]
  },
  "13.00": {
    "oper": "Push 24-bit return address to XY3, then PC <- addr24.   Return with RET. Flag-transparent.",
    "enc": [
      ["CALL24 #addr24", "10011 00 0 hhhhhhhh", "IR7-0 = high byte (23-16); next word = low 16 bits"]
    ],
    "forms": [
      ["#addr24", "m00", "11", "2"]
    ],
    "gotchas": [
      "CALL is the assembler alias for CALL24 - the default call.",
      "The stack pointer is HARDCODED to XY3 for every CALL/RET (unlike PUSH/POP, which take any XYsp). A full 24-bit return address is pushed; RET ($1E mode 11) pops it.",
      "Use CALL24 for cross-page / cross-file (kernel) calls. Same 2-word high-byte-in-opcode packing as JMP24 (manual lists 3 words; it is 2). Flag-transparent."
    ],
    "seeAlso": [
      ["RET", "the matching return ($1E m11)"],
      ["CALLR", "PC-relative call (intra-.COM)"],
      ["CALL16", "in-page call"]
    ]
  },
  "13.01": {
    "oper": "Push 24-bit return to XY3, then PC[15:0] <- addr16 (page unchanged).   Flag-transparent.",
    "enc": [
      ["CALL16 #addr16", "10011 01 0 00000000", "+ imm16 (low 16 bits); page stays put"]
    ],
    "forms": [
      ["#addr16", "m01", "11", "2"]
    ],
    "gotchas": [
      "Target stays in the current 64KB page (only low 16 bits of PC change), but the pushed return is still a full 24-bit address, so RET works normally.",
      "Stack pointer hardcoded to XY3.",
      "Flag-transparent."
    ],
    "seeAlso": [
      ["CALL24", "cross-page / cross-file call"],
      ["RET", "the matching return"]
    ]
  },
  "13.10": {
    "oper": "Push 24-bit return to XY3, then PC <- PC + offset (signed 16-bit, PC-relative).   Flag-transparent.",
    "enc": [
      ["CALLR #label", "10011 10 0 00000000", "+ imm16 = signed PC-relative offset"]
    ],
    "forms": [
      ["#label", "m10", "12", "2"]
    ],
    "gotchas": [
      "Position-independent: the target is a signed 16-bit offset from PC, so the call works wherever the code is loaded. Use CALLR for intra-.COM calls, CALL24 for cross-file.",
      "One cycle slower than CALL24/16 (12 vs 11) for the relative add. Stack pointer hardcoded XY3.",
      "Flag-transparent."
    ],
    "seeAlso": [
      ["CALL24", "absolute cross-file call"],
      ["RET", "the matching return"]
    ]
  },
  "13.11": {
    "oper": "Push 24-bit return to XY3, then PC <- XYn.   Indirect call. Flag-transparent.",
    "enc": [
      ["CALLXY XYn", "10011 11 00 yy 00000", "yy = XYn (IR6-5)"]
    ],
    "forms": [
      ["XYn", "m11", "10", "1"]
    ],
    "gotchas": [
      "Calls the address held in XYn (24-bit Yn:Xn) - the call-through-pointer / vtable / function-pointer primitive.",
      "Cheapest call and the only single-word one (10 cyc, 1 word). Stack pointer hardcoded XY3.",
      "Flag-transparent."
    ],
    "seeAlso": [
      ["JMPXY", "jump (no return push) via XY"],
      ["RET", "the matching return"]
    ]
  },
  "14": {
    "oper": "LOADD Dn, [addr].   Loads a 16-bit word into a D register. Flag-transparent.",
    "enc": [
      ["LOADD Dn, [XYm]", "10100 00 rr yy 00000", "rr = reg (IR8-7), yy = XYm (IR6-5)"],
      ["LOADD Dn, [XYm+Do]", "10100 01 rr yy dd 000", "dd = D offset (IR4-3); page-local add"],
      ["LOADD Dn, [PC+imm16]", "10100 10 rr 00 00000", "+ imm16 (signed); PC-relative"],
      ["LOADD Dn, [XYm+imm5]", "10100 11 rr yy iiiii", "iiiii = unsigned offset 0-31"]
    ],
    "forms": [
      ["Dn, [XYm]", "m00", "2", "1"],
      ["Dn, [XYm+Do]", "m01", "3", "1"],
      ["Dn, [PC+imm16]", "m10", "4", "2"],
      ["Dn, [XYm+imm5]", "m11", "3", "1"]
    ],
    "gotchas": [
      "Flag-transparent (FLAGSX): a load never sets C Z N V. CMP the loaded value before branching on it.",
      "[XYm+Do] (m01) and [XYm+imm5] (m11) are PAGE-LOCAL - the add is 16-bit within the current page, not a full 24-bit address (Appendix B.1). imm5 is unsigned 0-31.",
      "[PC+imm16] (m10) uses a SIGNED 16-bit offset and is the only 2-word form."
    ],
    "seeAlso": [
      ["STORED", "the store counterpart"],
      ["LOADI", "load an immediate (no memory)"]
    ]
  },
  "15": {
    "oper": "LOADX Xn, [addr].   Loads a 16-bit word into an X index register. Flag-transparent.",
    "enc": [
      ["LOADX Xn, [XYm]", "10101 00 rr yy 00000", "rr = reg (IR8-7), yy = XYm (IR6-5)"],
      ["LOADX Xn, [XYm+Do]", "10101 01 rr yy dd 000", "dd = D offset (IR4-3); page-local add"],
      ["LOADX Xn, [PC+imm16]", "10101 10 rr 00 00000", "+ imm16 (signed); PC-relative"],
      ["LOADX Xn, [XYm+imm5]", "10101 11 rr yy iiiii", "iiiii = unsigned offset 0-31"]
    ],
    "forms": [
      ["Xn, [XYm]", "m00", "2", "1"],
      ["Xn, [XYm+Do]", "m01", "3", "1"],
      ["Xn, [PC+imm16]", "m10", "4", "2"],
      ["Xn, [XYm+imm5]", "m11", "3", "1"]
    ],
    "gotchas": [
      "Flag-transparent (FLAGSX): a load never sets C Z N V. CMP the loaded value before branching on it.",
      "[XYm+Do] (m01) and [XYm+imm5] (m11) are PAGE-LOCAL - the add is 16-bit within the current page, not a full 24-bit address (Appendix B.1). imm5 is unsigned 0-31.",
      "[PC+imm16] (m10) uses a SIGNED 16-bit offset and is the only 2-word form."
    ],
    "seeAlso": [
      ["STOREX", "the store counterpart"],
      ["LOADI", "load an immediate (no memory)"]
    ]
  },
  "16": {
    "oper": "LOADY Yn, [addr].   Loads a Y index register (Y is the 8-bit high half of an XY pair). Flag-transparent.",
    "enc": [
      ["LOADY Yn, [XYm]", "10110 00 rr yy 00000", "rr = reg (IR8-7), yy = XYm (IR6-5)"],
      ["LOADY Yn, [XYm+Do]", "10110 01 rr yy dd 000", "dd = D offset (IR4-3); page-local add"],
      ["LOADY Yn, [PC+imm16]", "10110 10 rr 00 00000", "+ imm16 (signed); PC-relative"],
      ["LOADY Yn, [XYm+imm5]", "10110 11 rr yy iiiii", "iiiii = unsigned offset 0-31"]
    ],
    "forms": [
      ["Yn, [XYm]", "m00", "2", "1"],
      ["Yn, [XYm+Do]", "m01", "3", "1"],
      ["Yn, [PC+imm16]", "m10", "4", "2"],
      ["Yn, [XYm+imm5]", "m11", "3", "1"]
    ],
    "gotchas": [
      "Flag-transparent (FLAGSX): a load never sets C Z N V. CMP the loaded value before branching on it.",
      "[XYm+Do] (m01) and [XYm+imm5] (m11) are PAGE-LOCAL - the add is 16-bit within the current page, not a full 24-bit address (Appendix B.1). imm5 is unsigned 0-31.",
      "[PC+imm16] (m10) uses a SIGNED 16-bit offset and is the only 2-word form."
    ],
    "seeAlso": [
      ["STOREY", "the store counterpart"],
      ["LOADI", "load an immediate (no memory)"]
    ]
  },
  "17": {
    "oper": "LOADB Dn, [addr].   Byte load: the low byte is read and zero-extended to 16 bits (high byte = 0). Flag-transparent.",
    "enc": [
      ["LOADB Dn, [XYm]", "10111 00 rr yy 00000", "rr = reg (IR8-7), yy = XYm (IR6-5)"],
      ["LOADB Dn, [XYm+Do]", "10111 01 rr yy dd 000", "dd = D offset (IR4-3); page-local add"],
      ["LOADB Dn, [PC+imm16]", "10111 10 rr 00 00000", "+ imm16 (signed); PC-relative"],
      ["LOADB Dn, [XYm+imm5]", "10111 11 rr yy iiiii", "iiiii = unsigned offset 0-31"]
    ],
    "forms": [
      ["Dn, [XYm]", "m00", "2", "1"],
      ["Dn, [XYm+Do]", "m01", "3", "1"],
      ["Dn, [PC+imm16]", "m10", "4", "2"],
      ["Dn, [XYm+imm5]", "m11", "3", "1"]
    ],
    "gotchas": [
      "Flag-transparent (FLAGSX): a load never sets C Z N V. CMP the loaded value before branching on it.",
      "[XYm+Do] (m01) and [XYm+imm5] (m11) are PAGE-LOCAL - the add is 16-bit within the current page, not a full 24-bit address (Appendix B.1). imm5 is unsigned 0-31.",
      "[PC+imm16] (m10) uses a SIGNED 16-bit offset and is the only 2-word form.",
      "Pairs with LOADD - use the word load when you need all 16 bits."
    ],
    "seeAlso": [
      ["STOREB", "the store counterpart"],
      ["LOADI", "load an immediate (no memory)"]
    ]
  },
  "18.00": {
    "oper": "reg <- imm5 (0-31).   Load a small immediate, no memory access. Flag-transparent.",
    "enc": [
      ["LOADI reg, #imm5", "11000 00 dddd iiiii", "dddd = dest (class-encoded D/X/Y), iiiii = 0-31"]
    ],
    "forms": [
      ["reg, #imm5", "m00", "2", "1"]
    ],
    "gotchas": [
      "Fast 1-word immediate load for constants 0-31. dddd is class-encoded, so the target can be D, X or Y.",
      "Flag-transparent. For larger constants use the imm16 form.",
      "Negatives are not allowed here - use #imm16 (where a negative is accepted as a bit pattern)."
    ],
    "seeAlso": [
      ["LOADI #imm16", "16-bit immediate"],
      ["LOADD", "load from memory"]
    ]
  },
  "18.01": {
    "oper": "reg <- imm16.   Load a full 16-bit immediate. Flag-transparent.",
    "enc": [
      ["LOADI reg, #imm16", "11000 01 dddd 00000", "+ imm16 in next word; dddd = dest (D/X/Y)"]
    ],
    "forms": [
      ["reg, #imm16", "m01", "2", "2"]
    ],
    "gotchas": [
      "2-word load of any 16-bit constant into D, X or Y.",
      "Flag-transparent. A negative immediate is accepted as a bit pattern.",
      "Same 2 cycles as the imm5 form - the extra word is essentially free."
    ],
    "seeAlso": [
      ["LOADI #imm5", "small 1-word immediate"],
      ["LOADXY", "load a 24-bit pair"]
    ]
  },
  "18.10": {
    "oper": "XYn <- mem[XYm] (full 24-bit pair).   Flag-transparent.",
    "enc": [
      ["LOADXY XYn, [XYm]", "11000 10 nn mm 00000", "nn = dest XY (IR8-7), mm = source pointer XY (IR6-5)"]
    ],
    "forms": [
      ["XYn, [XYm]", "m10", "4", "1"]
    ],
    "gotchas": [
      "Loads a complete 24-bit pointer (X word + Y byte) in one instruction - Forth-friendly for fetching cells/addresses.",
      "Flag-transparent.",
      "Use different XY registers for dest and source pointer."
    ],
    "seeAlso": [
      ["STOREXY", "store the 24-bit pair"],
      ["LEA", "compute a pointer instead of loading one"]
    ]
  },
  "18.11": {
    "oper": "Paged / page-$00 load: LOADP reg, Yn, [#imm16] reads mem[Yn:imm16]; LOADZ reg, [#imm16] reads mem[$00:imm16].   Flag-transparent.",
    "enc": [
      ["LOADP reg, Yn, [#imm16]", "11000 11 dddd 0 0 yy 0", "IR4=0 paged, IR3=0 word; yy = Yn page reg; + imm16"],
      ["LOADPB reg, Yn, [#imm16]", "11000 11 dddd 0 1 yy 0", "IR3=1 byte (zero-extended)"],
      ["LOADZ reg, [#imm16]", "11000 11 dddd 1 0 00 0", "IR4=1 ZOA (page $00), word; + imm16"],
      ["LOADZB reg, [#imm16]", "11000 11 dddd 1 1 00 0", "IR4=1 ZOA, IR3=1 byte"]
    ],
    "forms": [
      ["reg, Yn, [#imm16]   (LOADP)", "m11", "3", "2"],
      ["reg, Yn, [#imm16]   (LOADPB)", "m11", "3", "2"],
      ["reg, [#imm16]   (LOADZ)", "m11", "3", "2"],
      ["reg, [#imm16]   (LOADZB)", "m11", "3", "2"]
    ],
    "gotchas": [
      "LOADP uses the Y register as the PAGE (high 8 bits) and imm16 as the offset: reg <- mem[Yn:imm16]. Reaches any page without building a full XY pointer.",
      "LOADZ forces the page to $00 regardless of Y (ZOA = Zero-on-Address-Hi) - this is how page-$00 OS/system variables are read: reg <- mem[$00:imm16].",
      "IR bit 4 = ZOA (1 = page $00, LOADZ); IR bit 3 = byte (1 = LOADPB/LOADZB, zero-extended). Flag-transparent; 2 words."
    ],
    "seeAlso": [
      ["STOREP / STOREZ", "the paged / page-$00 stores"],
      ["LOADD", "plain indirect load"]
    ]
  },
  "19": {
    "oper": "STORED Dn, [addr].   Stores the 16-bit word in a D register. Flag-transparent.",
    "enc": [
      ["STORED Dn, [XYm]", "11001 00 rr yy 00000", "rr = reg (IR8-7), yy = XYm (IR6-5)"],
      ["STORED Dn, [XYm+Do]", "11001 01 rr yy dd 000", "dd = D offset (IR4-3); page-local add"],
      ["STORED Dn, [PC+imm16]", "11001 10 rr 00 00000", "+ imm16 (signed); PC-relative"],
      ["STORED Dn, [XYm+imm5]", "11001 11 rr yy iiiii", "iiiii = unsigned offset 0-31"]
    ],
    "forms": [
      ["Dn, [XYm]", "m00", "3", "1"],
      ["Dn, [XYm+Do]", "m01", "4", "1"],
      ["Dn, [PC+imm16]", "m10", "4", "2"],
      ["Dn, [XYm+imm5]", "m11", "4", "1"]
    ],
    "gotchas": [
      "Flag-transparent: a store never sets C Z N V.",
      "[XYm+Do] (m01) and [XYm+imm5] (m11) are PAGE-LOCAL - the add is 16-bit within the current page, not a full 24-bit address (Appendix B.1). imm5 is unsigned 0-31.",
      "[PC+imm16] (m10) uses a SIGNED 16-bit offset and is the only 2-word form."
    ],
    "seeAlso": [
      ["LOADD", "the load counterpart"],
      ["STOREI", "store an immediate"]
    ]
  },
  "1A": {
    "oper": "STOREB Dn, [addr].   Byte store: only the low 8 bits of the D register are written. Flag-transparent.",
    "enc": [
      ["STOREB Dn, [XYm]", "11010 00 rr yy 00000", "rr = reg (IR8-7), yy = XYm (IR6-5)"],
      ["STOREB Dn, [XYm+Do]", "11010 01 rr yy dd 000", "dd = D offset (IR4-3); page-local add"],
      ["STOREB Dn, [PC+imm16]", "11010 10 rr 00 00000", "+ imm16 (signed); PC-relative"],
      ["STOREB Dn, [XYm+imm5]", "11010 11 rr yy iiiii", "iiiii = unsigned offset 0-31"]
    ],
    "forms": [
      ["Dn, [XYm]", "m00", "3", "1"],
      ["Dn, [XYm+Do]", "m01", "4", "1"],
      ["Dn, [PC+imm16]", "m10", "4", "2"],
      ["Dn, [XYm+imm5]", "m11", "4", "1"]
    ],
    "gotchas": [
      "Flag-transparent: a store never sets C Z N V.",
      "[XYm+Do] (m01) and [XYm+imm5] (m11) are PAGE-LOCAL - the add is 16-bit within the current page, not a full 24-bit address (Appendix B.1). imm5 is unsigned 0-31.",
      "[PC+imm16] (m10) uses a SIGNED 16-bit offset and is the only 2-word form.",
      "Pairs with STORED - the word store writes 16 bits."
    ],
    "seeAlso": [
      ["LOADB", "the load counterpart"],
      ["STOREI", "store an immediate"]
    ]
  },
  "1B": {
    "oper": "STOREX Xn, [addr].   Stores the 16-bit X index register. Flag-transparent.",
    "enc": [
      ["STOREX Xn, [XYm]", "11011 00 rr yy 00000", "rr = reg (IR8-7), yy = XYm (IR6-5)"],
      ["STOREX Xn, [XYm+Do]", "11011 01 rr yy dd 000", "dd = D offset (IR4-3); page-local add"],
      ["STOREX Xn, [PC+imm16]", "11011 10 rr 00 00000", "+ imm16 (signed); PC-relative"],
      ["STOREX Xn, [XYm+imm5]", "11011 11 rr yy iiiii", "iiiii = unsigned offset 0-31"]
    ],
    "forms": [
      ["Xn, [XYm]", "m00", "3", "1"],
      ["Xn, [XYm+Do]", "m01", "4", "1"],
      ["Xn, [PC+imm16]", "m10", "4", "2"],
      ["Xn, [XYm+imm5]", "m11", "4", "1"]
    ],
    "gotchas": [
      "Flag-transparent: a store never sets C Z N V.",
      "[XYm+Do] (m01) and [XYm+imm5] (m11) are PAGE-LOCAL - the add is 16-bit within the current page, not a full 24-bit address (Appendix B.1). imm5 is unsigned 0-31.",
      "[PC+imm16] (m10) uses a SIGNED 16-bit offset and is the only 2-word form."
    ],
    "seeAlso": [
      ["LOADX", "the load counterpart"],
      ["STOREI", "store an immediate"]
    ]
  },
  "1C": {
    "oper": "STOREY Yn, [addr].   Stores the 8-bit Y index register. Flag-transparent.",
    "enc": [
      ["STOREY Yn, [XYm]", "11100 00 rr yy 00000", "rr = reg (IR8-7), yy = XYm (IR6-5)"],
      ["STOREY Yn, [XYm+Do]", "11100 01 rr yy dd 000", "dd = D offset (IR4-3); page-local add"],
      ["STOREY Yn, [PC+imm16]", "11100 10 rr 00 00000", "+ imm16 (signed); PC-relative"],
      ["STOREY Yn, [XYm+imm5]", "11100 11 rr yy iiiii", "iiiii = unsigned offset 0-31"]
    ],
    "forms": [
      ["Yn, [XYm]", "m00", "3", "1"],
      ["Yn, [XYm+Do]", "m01", "4", "1"],
      ["Yn, [PC+imm16]", "m10", "4", "2"],
      ["Yn, [XYm+imm5]", "m11", "4", "1"]
    ],
    "gotchas": [
      "Flag-transparent: a store never sets C Z N V.",
      "[XYm+Do] (m01) and [XYm+imm5] (m11) are PAGE-LOCAL - the add is 16-bit within the current page, not a full 24-bit address (Appendix B.1). imm5 is unsigned 0-31.",
      "[PC+imm16] (m10) uses a SIGNED 16-bit offset and is the only 2-word form."
    ],
    "seeAlso": [
      ["LOADY", "the load counterpart"],
      ["STOREI", "store an immediate"]
    ]
  },
  "1D.00": {
    "oper": "mem[XYm] <- imm5 (0-31).   Store a small immediate straight to memory. Flag-transparent.",
    "enc": [
      ["STOREI #imm5, [XYm]", "11101 00 00 yy iiiii", "yy = XYm (IR6-5), iiiii = 0-31"]
    ],
    "forms": [
      ["#imm5, [XYm]", "m00", "2", "1"]
    ],
    "gotchas": [
      "Writes a 0-31 constant to memory with no register - handy for zeroing or small inits.",
      "Flag-transparent. For larger values use the imm16 form."
    ],
    "seeAlso": [
      ["STOREI #imm16", "16-bit immediate store"],
      ["STORED", "store a register"]
    ]
  },
  "1D.01": {
    "oper": "mem[XYm] <- imm16.   Store a 16-bit immediate to memory. Flag-transparent.",
    "enc": [
      ["STOREI #imm16, [XYm]", "11101 01 00 yy 00000", "+ imm16 in next word; yy = XYm"]
    ],
    "forms": [
      ["#imm16, [XYm]", "m01", "3", "2"]
    ],
    "gotchas": [
      "2-word store of any 16-bit constant to [XYm], no register needed.",
      "Flag-transparent."
    ],
    "seeAlso": [
      ["STOREI #imm5", "small 1-word immediate"],
      ["STOREXY", "store a 24-bit pair"]
    ]
  },
  "1D.10": {
    "oper": "mem[XYm] <- XYn (full 24-bit pair).   Flag-transparent.",
    "enc": [
      ["STOREXY XYn, [XYm]", "11101 10 nn mm 00000", "nn = source XY (IR8-7), mm = dest pointer XY (IR6-5)"]
    ],
    "forms": [
      ["XYn, [XYm]", "m10", "6", "1"]
    ],
    "gotchas": [
      "Writes a complete 24-bit pointer (X word + Y byte) in one instruction. 6 cycles - the priciest store.",
      "Flag-transparent. Mirror of LOADXY."
    ],
    "seeAlso": [
      ["LOADXY", "load the 24-bit pair"]
    ]
  },
  "1D.11": {
    "oper": "Paged / page-$00 store: STOREP reg, Yn, [#imm16] writes mem[Yn:imm16]; STOREZ reg, [#imm16] writes mem[$00:imm16].   Flag-transparent.",
    "enc": [
      ["STOREP reg, Yn, [#imm16]", "11101 11 ssss 0 0 yy 0", "IR4=0 paged, IR3=0 word; yy = Yn page; + imm16"],
      ["STOREPB reg, Yn, [#imm16]", "11101 11 ssss 0 1 yy 0", "IR3=1 byte"],
      ["STOREZ reg, [#imm16]", "11101 11 ssss 1 0 00 0", "IR4=1 ZOA (page $00), word; + imm16"],
      ["STOREZB reg, [#imm16]", "11101 11 ssss 1 1 00 0", "IR4=1 ZOA, IR3=1 byte"]
    ],
    "forms": [
      ["reg, Yn, [#imm16]   (STOREP)", "m11", "5", "2"],
      ["reg, Yn, [#imm16]   (STOREPB)", "m11", "5", "2"],
      ["reg, [#imm16]   (STOREZ)", "m11", "5", "2"],
      ["reg, [#imm16]   (STOREZB)", "m11", "5", "2"]
    ],
    "gotchas": [
      "STOREP uses the Y register as the PAGE and imm16 as the offset: mem[Yn:imm16] <- reg. Reaches any page without a full XY pointer.",
      "STOREZ forces page $00 regardless of Y (ZOA) - the way page-$00 OS/system variables are written.",
      "IR bit 4 = ZOA (1 = page $00); IR bit 3 = byte. Source field ssss is 4-bit class-encoded. Flag-transparent; 2 words; 5 cycles."
    ],
    "seeAlso": [
      ["LOADP / LOADZ", "the paged / page-$00 loads"],
      ["STORED", "plain indirect store"]
    ]
  },
  "1E.00": {
    "oper": "Push PC (24-bit return to XY3), then PC <- vector[n].   Software syscall. Flag-transparent (TRAP does not push SR).",
    "enc": [
      ["TRAP #n", "11110 00 nnnnnnnn", "IR7-0 = n*2 (n = 0..127); word = $F000 | n*2"]
    ],
    "forms": [
      ["#n", "m00", "12", "1"]
    ],
    "gotchas": [
      "Pushes a 24-bit return to XY3 (same sequence as CALL24), then vectors to vector[n]. n is 0..127, encoded as n*2 in the low byte: word = $F000 | n*2.",
      "Flag-transparent: TRAP does NOT push SR. The handler returns via RETCC (success, C=0) or RETCS (error, C=1) - the carry the caller tests.",
      "Leaf syscall ABI: after the call returns, C=0 = OK, C=1 = error with the code in D0. (Spreadsheet lists 13 cycles; manual and grid say 12.)"
    ],
    "seeAlso": [
      ["RETCC / RETCS", "syscall return that sets carry"],
      ["RET", "plain return"],
      ["CALL24", "same return-push sequence"]
    ]
  },
  "1E.01": {
    "oper": "dst <- -src (0 - src), two's-complement negate.   Arithmetic - sets C Z N V (6502 borrow sense).",
    "enc": [
      ["NEG dst, src", "11110 01 dddd ssss 0", "dddd = dst (IR8-5), ssss = src (IR4-1); class-encoded 0-3 D, 4-7 X, 8-B Y"],
      ["NEG dst", "11110 01 dddd dddd 0", "in-place: src = dst (e.g. NEG D0 = $F200)"]
    ],
    "forms": [
      ["dst, src", "m01", "3", "1"],
      ["dst", "m01", "3", "1"]
    ],
    "flagsDetail": [
      ["Z", "set if result = 0"],
      ["N", "set if result bit 15 = 1"],
      ["C", "CLEAR if src != 0 (a borrow occurred); SET if src = 0"],
      ["V", "set if src = $8000 (negating -32768 overflows)"]
    ],
    "gotchas": [
      "Carry is 6502 borrow-sense: NEG is 0 - src, so any non-zero src borrows and CLEARS C; only NEG of 0 leaves C set. State the sense before branching.",
      "The only $1E mode that writes flags. It lives here (not in $00-$03) because FLAGSX reserves opcodes $00-$03 for flag-transparent ops, and NEG must update user-visible flags.",
      "Two forms: NEG dst, src (copy-and-negate) and NEG dst (in-place). dst/src are class-encoded, so D, X or Y can be negated.",
      "V catches the single unrepresentable case: -(-32768)."
    ],
    "seeAlso": [
      ["SUB", "0 - src the long way; same borrow sense"],
      ["NOT", "ones-complement (NOT then +1 equals NEG)"]
    ]
  },
  "1E.10": {
    "oper": "Return + set carry: PC <- pop; SP += 4 + (n*2); then SR <- $00 (RETCC, success) or $01 (RETCS, error).",
    "enc": [
      ["RETCC [#nw]", "11110 10 0 0 00 iiiii", "IR8-7 = 00; IMM5 = 4 + cleanup*2; base $F404"],
      ["RETCS [#nw]", "11110 10 0 1 00 iiiii", "IR8-7 = 01; base $F484"]
    ],
    "forms": [
      ["RETCC [#nw]", "m10", "6", "1"],
      ["RETCS [#nw]", "m10", "6", "1"]
    ],
    "flagsDetail": [
      ["C", "RETCC clears it (0 = success); RETCS sets it (1 = error)"],
      ["Z", "cleared to 0 (the whole SR is overwritten)"],
      ["N", "cleared to 0"],
      ["V", "cleared to 0"]
    ],
    "gotchas": [
      "The syscall-exit returns: RETCC clears carry (C=0 = success), RETCS sets carry (C=1 = error). Both also clear Z/N/V (SR = $00 or $01).",
      "Pops the 24-bit return (SP += 4) plus optional caller cleanup: #nw pops n extra words (IMM5 = 4 + n*2). Even-only, #0w..#13w; the assembler enforces even.",
      "IR8-7 selects the variant (00 RETCC, 01 RETCS); IR8=1 is reserved and decodes safely as RETCC.",
      "Hardcoded XY3 stack, same as CALL/RET."
    ],
    "seeAlso": [
      ["RET", "plain return, leaves flags alone"],
      ["TRAP", "the syscall these return from"]
    ]
  },
  "1E.11": {
    "oper": "PC <- pop; SP += 4 + (n*2).   Plain subroutine return. Flag-transparent (does not pop or write SR).",
    "enc": [
      ["RET [#nw]", "11110 11 00 00 iiiii", "IMM5 = 4 + cleanup*2; base $F66C"]
    ],
    "forms": [
      ["RET [#nw]", "m11", "6", "1"]
    ],
    "gotchas": [
      "Pops the 24-bit return pushed by CALL (SP += 4), plus optional #nw caller-cleanup (IMM5 = 4 + n*2, even-only, #0w..#13w).",
      "Flag-transparent - plain RET does NOT touch SR. Use RETCC/RETCS to return AND set the carry (syscall exits).",
      "Hardcoded XY3 stack. The matching call is any CALL variant ($13)."
    ],
    "seeAlso": [
      ["CALL24", "the call this returns from"],
      ["RETCC / RETCS", "return + set carry"]
    ]
  },
  "1F.00": {
    "oper": "IE <- 0 - disable interrupts (clear the Interrupt Enable bit, SR.7).   Flag-transparent (N Z C V unchanged).",
    "enc": [
      ["DINT", "11111 00 000000000", "= $F800"]
    ],
    "forms": [
      ["DINT", "m00", "2", "1"]
    ],
    "gotchas": [
      "Clears SR bit 7 (IE). The arithmetic flags (N Z C V) are untouched - only the interrupt-enable bit changes.",
      "Critical in non-leaf syscalls: the canonical pattern is PUSH SR / DINT / body / RTI. DINT stops a timer IRQ firing inside _Schedule after CURRENT_TCB is updated.",
      "IE is otherwise software-read-only - you cannot MOVE into it; DINT/EINT (and the hardware INT/RTI) are the only ways it changes."
    ],
    "seeAlso": [
      ["EINT", "re-enable interrupts"],
      ["RTI", "restores SR incl IE on ISR exit"]
    ]
  },
  "1F.01": {
    "oper": "IE <- 1 - enable interrupts (set the Interrupt Enable bit, SR.7).   Flag-transparent.",
    "enc": [
      ["EINT", "11111 01 000000000", "= $FA00"]
    ],
    "forms": [
      ["EINT", "m01", "2", "1"]
    ],
    "gotchas": [
      "Sets SR bit 7 (IE). Arithmetic flags untouched.",
      "Pair with DINT around critical sections. At boot the OS issues EINT once the INT dispatcher is installed at the $00:0000 vector.",
      "IE is read-only to ordinary software otherwise."
    ],
    "seeAlso": [
      ["DINT", "disable interrupts"],
      ["INT", "the hardware entry EINT permits"]
    ]
  },
  "1F.10": {
    "oper": "pop SR, then pop PC - return from an interrupt handler.   Restores flags AND re-enables interrupts (SR.IE).",
    "enc": [
      ["RTI", "11111 10 000000000", "pops SR then the 24-bit PC from the XY3 stack"]
    ],
    "forms": [
      ["RTI", "m10", "8", "1"]
    ],
    "gotchas": [
      "Unlike RET, RTI POPS SR - it restores N Z C V, the priority level, AND IE (re-enabling interrupts) in one step.",
      "IRQ handlers (reached via the INT dispatcher) exit with RTI; plain subroutines and TRAP handlers exit with RET.",
      "Pops from the XY3 stack: the SR word, then the 24-bit return address that INT pushed.  (Spreadsheet spells it RINT.)"
    ],
    "seeAlso": [
      ["INT", "the hardware entry RTI unwinds"],
      ["RET", "subroutine return (leaves SR alone)"],
      ["TRAP", "syscall entry (returns via RET / RETCC / RETCS)"]
    ]
  },
  "1F.11": {
    "oper": "(hardware) push PC and SR, then jump to the ISR via the $00:0000 vector.   16-cycle IRQ entry overhead.",
    "enc": [
      ["INT", "11111 11 000000000", "= $FE00; hardware-triggered IRQ entry"]
    ],
    "forms": [
      ["INT", "m11", "16", "1"]
    ],
    "gotchas": [
      "This is the hardware interrupt-entry sequence, not something you usually write: when an enabled IRQ fires it pushes the 24-bit PC and SR to XY3 and vectors through $00:0000 (the same vector as TRAP #0, reached Y3-independently via ZOA).",
      "16 cycles of entry overhead. The OS dispatcher at $00:0000 reads the IRQ level from SR bits 6:4, maps it to TRAP #1..#8, and JMPTs to the per-IRQ handler.",
      "Because INT pushes SR (and TRAP does not), IRQ handlers must exit with RTI to restore it. Eight priority levels, IRQ0-7, 74LS148-encoded."
    ],
    "seeAlso": [
      ["RTI", "the matching return"],
      ["TRAP", "software syscall - shares the $00:0000 vector but does not push SR"],
      ["EINT", "must be set for INT to fire"]
    ]
  }
};
