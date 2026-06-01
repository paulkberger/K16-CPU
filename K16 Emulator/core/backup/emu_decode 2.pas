unit emu_decode;
{
  K16 Emulator — Instruction Fetch and Decode
  Fetch reads from Mem[] at CPU.PC (little-endian), advances PC.
  Decode extracts opcode, mode, operand fields from IR.
  NeedsImm determines whether a second word follows the instruction word.
  Part of the K16 homebrew CPU project.
}

{$mode Delphi}
{$H+}

interface

uses
  emu_types, emu_mem, emu_cpu;

// ---------------------------------------------------------------------------
// Decoded instruction record
// ---------------------------------------------------------------------------

type
  TDecodedInstr = record
    Opcode  : Byte;    { IR[15:11] — 5 bits }
    Mode    : Byte;    { IR[10:9]  — 2 bits }
    Operand : Word;    { IR[8:0]   — 9 bits (raw) }
    HasImm  : Boolean;
    Imm16   : TWord;   { second word if HasImm }
    Cycles  : Byte;
  end;

// ---------------------------------------------------------------------------
// Cycle table — indexed [Opcode, Mode]; 0 = illegal
// ---------------------------------------------------------------------------

const
  CycleTable : array[0..$1F, 0..3] of Byte = (
  { op   m00 m01 m10 m11 }
  { $00 MISC   } ( 2,  2,  0,  3),
  { $01 LOOKUP } ( 3,  3,  3,  3),
  { $02 INC/DEC} ( 5,  6,  0,  0),
  { $03 LEA    } ( 4,  4,  4,  3),
  { $04 Scc    } ( 2,  2,  2,  2),
  { $05 MOVE   } ( 2,  2,  2,  2),
  { $06 PUSH   } ( 3,  8,  5,  3),
  { $07 POP    } ( 3,  9,  6,  3),
  { $08 ADD    } ( 3,  3,  3,  4),
  { $09 ADC    } ( 3,  3,  3,  4),
  { $0A SUB    } ( 3,  3,  3,  4),
  { $0B SBC    } ( 3,  3,  3,  4),
  { $0C AND    } ( 3,  3,  3,  4),
  { $0D OR     } ( 3,  3,  3,  4),
  { $0E XOR    } ( 3,  3,  3,  4),
  { $0F NOT    } ( 3,  3,  3,  4),
  { $10 CMP    } ( 3,  3,  3,  4),
  { $11 Bcc    } ( 3,  4,  3,  4),
  { $12 JMP    } ( 4,  3,  4,  3),
  { $13 CALL   } (11, 11, 12,  9),
  { $14 LOADD  } ( 2,  3,  4,  3),
  { $15 LOADB  } ( 2,  3,  4,  3),
  { $16 LOADX  } ( 2,  3,  4,  3),
  { $17 LOADY  } ( 2,  3,  4,  3),
  { $18 LOADI  } ( 2,  2,  4,  3),
  { $19 STORED } ( 3,  4,  4,  4),
  { $1A STOREB } ( 3,  4,  4,  4),
  { $1B STOREX } ( 3,  4,  4,  4),
  { $1C STOREY } ( 3,  4,  4,  4),
  { $1D STOREI } ( 3,  4,  4,  4),
  { $1E TRAP/R } ( 5,  0,  0,  4),
  { $1F INT    } ( 2,  2,  4,  2)
  );

// ---------------------------------------------------------------------------
// Fetch + Decode
// ---------------------------------------------------------------------------

function  NeedsImm(opcode, mode: Byte): Boolean;
procedure Fetch(out D: TDecodedInstr);

implementation

// ---------------------------------------------------------------------------
// NeedsImm — returns true when the instruction has a second word
//
// LOADXY ($18 mode 10) reads a full 24-bit XY literal:
//   word 1 = Y byte (in low byte) + padding
//   word 2 = X word
// Both words are consumed here; Imm16 = word 2 (X), Operand low byte = Y.
// ---------------------------------------------------------------------------

function NeedsImm(opcode, mode: Byte): Boolean;
begin
  Result := False;
  case opcode of
    $08..$10:              { ALU + CMP: mode 10=IMM5, mode 11=IMM16 }
      Result := mode = 3;

    $11:                   { Bcc: mode 01 = long (16-bit offset); mode 11 = BRA.L }
      Result := mode in [1, 3];

    $12:                   { JMP: modes 00 (JMP24) and 01 (JMP16) have imm }
      Result := mode in [0, 1];

    $13:                   { CALL: modes 00,01,10 have imm; 11 (CALLXY) does not }
      Result := mode in [0, 1, 2];

    $14,$15:               { LOADD, LOADB: mode 10 = [PC+imm16] }
      Result := mode = 2;

    $16,$17:               { LOADX, LOADY: mode 01 = imm16; mode 10 = [PC+imm16] }
      Result := mode in [1, 2];

    $18:                   { LOADI }
      { mode 01 = IMM16; mode 10 = LOADXY (reads two extra words total)  }
      { For LOADXY we treat both extra words as imm; see note in Fetch    }
      Result := mode in [1, 2];

    $19..$1C:              { STORE: mode 10 = [PC+imm16] }
      Result := mode = 2;

    $1D:                   { STOREI: mode 01 = IMM16 write }
      Result := mode = 1;

    { TRAP ($1E mode 00): vector in IR, no extra word }
    { RET  ($1E mode 11): no extra word }
  end;
end;

// ---------------------------------------------------------------------------
// Fetch
// ---------------------------------------------------------------------------

procedure Fetch(out D: TDecodedInstr);
begin
  CPU.IR   := MemReadWord(CPU.PC);
  Inc(CPU.PC, 2);
  CPU.PC   := CPU.PC and ADDR_MASK;

  D.Opcode  := (CPU.IR shr 11) and $1F;
  D.Mode    := (CPU.IR shr 9)  and $03;
  D.Operand := CPU.IR and $01FF;
  D.HasImm  := NeedsImm(D.Opcode, D.Mode);
  D.Imm16   := 0;
  D.Cycles  := CycleTable[D.Opcode, D.Mode];

  if D.HasImm then
  begin
    D.Imm16 := MemReadWord(CPU.PC);
    Inc(CPU.PC, 2);
    CPU.PC  := CPU.PC and ADDR_MASK;
  end;
end;

end.
