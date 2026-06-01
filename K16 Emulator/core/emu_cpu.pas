unit emu_cpu;
{
  K16 Emulator — CPU State and Core Methods
  TCPU is an FPC object (stack/global-allocatable, zero heap overhead).
  Global instance CPU accessed directly by all Exec* handlers.
  Part of the K16 homebrew CPU project.
}

{$mode Delphi}
{$H+}

interface

uses
  emu_types, emu_mem;

type
  TCPU = object
  public
    { Data registers }
    D : array[0..3] of TWord;

    { Index registers — XYn = (Y[n] shl 16) or X[n] }
    X : array[0..3] of TWord;   { low 16 bits of XY pair }
    Y : array[0..3] of TByte;   { high 8 bits of XY pair }

    { Program counter }
    PC : TAddr;

    { Internal / architectural registers }
    IR   : TWord;   { Instruction Register }
    T8   : TByte;   { 8-bit temp }
    T16  : TWord;   { 16-bit immediate (second word of 2-word instructions) }
    ORAB : TWord;   { Address output register }
    ORDB : TWord;   { Data output register }

    { Status }
    SR : TSR;

    { Execution state }
    Halted     : Boolean;
    HaltCode   : TByte;
    CycleCount : QWord;

    { Interrupt pending bits (phase 2 — declared now, unused until section 15) }
    IRQPending : Byte;

    // -----------------------------------------------------------------------
    procedure Reset;

    function  XYGet(n: Byte): TAddr; inline;
    procedure XYSet(n: Byte; v: TAddr); inline;

    function  SPGet: TAddr; inline;   { convenience — XY3 as stack pointer }
    procedure SPSet(v: TAddr); inline;

    procedure StackPushWord(v: TWord);
    function  StackPopWord: TWord;
    procedure StackPush24(v: TAddr);
    function  StackPop24: TAddr;

    function  SRToWord: TWord;
    procedure SRFromWord(w: TWord);
    procedure SRFromWordFlagsOnly(w: TWord);  { writes only bits 3:0 (C/Z/N/V); preserves IE/LVL }
  end;

var
  CPU : TCPU;   { single global instance }

implementation

// ---------------------------------------------------------------------------

procedure TCPU.Reset;
begin
  FillChar(Self, SizeOf(Self), 0);
  PC         := RESET_VEC;   { $FF0000 }
  SR.IE      := False;
  SR.Level   := 0;
  Halted     := False;
  HaltCode   := 0;
  CycleCount := 0;
  IRQPending := 0;
end;

// ---------------------------------------------------------------------------
// XY pair helpers
// ---------------------------------------------------------------------------

function TCPU.XYGet(n: Byte): TAddr;
begin
  Result := (TAddr(Y[n]) shl 16) or X[n];
end;

procedure TCPU.XYSet(n: Byte; v: TAddr);
begin
  Y[n] := (v shr 16) and $FF;
  X[n] := v and $FFFF;
end;

function TCPU.SPGet: TAddr;
begin
  Result := XYGet(3);
end;

procedure TCPU.SPSet(v: TAddr);
begin
  XYSet(3, v);
end;

// ---------------------------------------------------------------------------
// Stack — descending, pre-decrement push, post-increment pop
// ---------------------------------------------------------------------------

procedure TCPU.StackPushWord(v: TWord);
begin
  SPSet(SPGet - 2);
  MemWriteWord(SPGet, v);
end;

function TCPU.StackPopWord: TWord;
begin
  Result := MemReadWord(SPGet);
  SPSet(SPGet + 2);
end;

// ---------------------------------------------------------------------------
// StackPush24 / StackPop24
//
// Matches CALL24 hardware microcode:
//   Push PC[15:0] first  → lands at higher address (SP-2)
//   Push PC[23:16] second → lands at lower address  (SP-4)
// After push X3 points to PC[23:16] word.
//
// RET pops in reverse (SP points to PC[23:16] word):
//   Pop PC[23:16] from [SP]   (lower address)
//   Pop PC[15:0]  from [SP+2] (higher address)
// ---------------------------------------------------------------------------

procedure TCPU.StackPush24(v: TAddr);
begin
  StackPushWord(v and $FFFF);              { PC[15:0]  pushed first → higher addr }
  StackPushWord((v shr 16) and $FF);       { PC[23:16] pushed second → lower addr  }
end;

function TCPU.StackPop24: TAddr;
var
  Hi, Lo: TWord;
begin
  Hi := StackPopWord and $FF;    { PC[23:16] at lower address — popped first  }
  Lo := StackPopWord;            { PC[15:0]  at higher address — popped second }
  Result := (TAddr(Hi) shl 16) or Lo;
end;

// ---------------------------------------------------------------------------
// SR serialisation (for TRAP / RTI)
//   Bit  0 = C
//   Bit  1 = Z
//   Bit  2 = N
//   Bit  3 = V
//   Bits 6:4 = Level (3 bits)
//   Bit  7 = IE
// ---------------------------------------------------------------------------

function TCPU.SRToWord: TWord;
begin
  Result := 0;
  if SR.Flags.C then Result := Result or $0001;
  if SR.Flags.Z then Result := Result or $0002;
  if SR.Flags.N then Result := Result or $0004;
  if SR.Flags.V then Result := Result or $0008;
  Result := Result or ((TWord(SR.Level) and $07) shl 4);
  if SR.IE then Result := Result or $0080;
end;

procedure TCPU.SRFromWord(w: TWord);
begin
  SR.Flags.C := (w and $0001) <> 0;
  SR.Flags.Z := (w and $0002) <> 0;
  SR.Flags.N := (w and $0004) <> 0;
  SR.Flags.V := (w and $0008) <> 0;
  SR.Level   := (w shr 4) and $07;
  SR.IE      := (w and $0080) <> 0;
end;

procedure TCPU.SRFromWordFlagsOnly(w: TWord);
{ Writes only C/Z/N/V (SR bits 3:0). IE/LVL are read-only from software
  (hardware FLAGS register is a 4-bit 74x670); mirror that behaviour here. }
begin
  SR.Flags.C := (w and $0001) <> 0;
  SR.Flags.Z := (w and $0002) <> 0;
  SR.Flags.N := (w and $0004) <> 0;
  SR.Flags.V := (w and $0008) <> 0;
end;

end.
