unit emu_types;
{
  K16 Emulator — Shared Types, Constants, I/O Handler Abstraction
  Part of the K16 homebrew CPU project.
  https://github.com/paulkberger/K16-CPU
}

{$mode Delphi}
{$H+}

interface

// ---------------------------------------------------------------------------
// Base types
// ---------------------------------------------------------------------------

type
  TWord  = Word;       { 16-bit unsigned }
  TByte  = Byte;       { 8-bit unsigned  }
  TAddr  = LongWord;   { 24-bit address — always mask with $FFFFFF }
  TSWord = SmallInt;   { 16-bit signed, for signed arithmetic }

// ---------------------------------------------------------------------------
// Flags and Status Register
// ---------------------------------------------------------------------------

type
  TFlags = record
    C : Boolean;   { Carry    — unsigned overflow/borrow }
    Z : Boolean;   { Zero     — result = 0 }
    N : Boolean;   { Negative — result bit 15 set }
    V : Boolean;   { Overflow — signed overflow }
  end;

  TSR = record
    Flags : TFlags;
    IE    : Boolean;  { Interrupt Enable }
    Level : Byte;     { Current interrupt priority 0-7 }
  end;

// ---------------------------------------------------------------------------
// Memory map constants
// ---------------------------------------------------------------------------

const
  MEM_SIZE   = $1000000;    { 16MB }
  ADDR_MASK  = $FFFFFF;

  RAM_BASE   = $000000;
  RAM_TOP    = $BFFFFF;

  FB_BASE    = $A00000;   { framebuffer — 1bpp and 8bpp share same base }

  IO_BASE    = $C00000;
  IO_TOP     = $DFFFFF;
  KBD_ADDR   = $C00000;   { keyboard input — word read }
  TERM_ADDR  = $D00000;   { terminal output — byte write }
  VID_MODE   = $C00010;   { video mode register — word write }

  ROM_LUT1   = $E00000;
  ROM_LUT2   = $F00000;
  ROM_TOP    = $FBFFFF;
  PROG_ROM   = $FC0000;
  BOOT_ROM   = $FF0000;

  RESET_VEC  = $FF0000;

// ---------------------------------------------------------------------------
// Opcode constants
// ---------------------------------------------------------------------------

const
  OP_MISC    = $00;
  OP_LOOKUP  = $01;
  OP_INCDEC  = $02;
  OP_LEA     = $03;
  OP_SCC     = $04;
  OP_MOVE    = $05;
  OP_PUSH    = $06;
  OP_POP     = $07;
  OP_ADD     = $08;
  OP_ADC     = $09;
  OP_SUB     = $0A;
  OP_SBC     = $0B;
  OP_AND     = $0C;
  OP_OR      = $0D;
  OP_XOR     = $0E;
  OP_NOT     = $0F;
  OP_CMP     = $10;
  OP_BCC     = $11;
  OP_JMP     = $12;
  OP_CALL    = $13;
  OP_LOADD   = $14;
  OP_LOADB   = $15;
  OP_LOADX   = $16;
  OP_LOADY   = $17;
  OP_LOADI   = $18;
  OP_STORED  = $19;
  OP_STOREB  = $1A;
  OP_STOREX  = $1B;
  OP_STOREY  = $1C;
  OP_STOREI  = $1D;
  OP_TRAP_RET = $1E;   { TRAP (mode 00), RET (mode 11) }
  OP_INT     = $1F;

// ---------------------------------------------------------------------------
// Run mode
// ---------------------------------------------------------------------------

type
  TRunMode = (
    rmFast,     { flat out — report effective MHz on exit }
    rmTimed,    { throttle to TargetMHz }
    rmStep,     { interactive text REPL }
    rmDigital   { stdin/stdout I/O, no video — default for K16EmuCLI }
  );

var
  RunMode          : TRunMode   = rmDigital;
  TargetMHz        : Integer    = 10;
  TraceEnabled     : Boolean    = False;
  TraceRegs        : Boolean    = False;
  MaxCyclesEnabled : Boolean    = False;
  MaxCycles        : QWord      = 0;
  BreakEnabled     : Boolean    = False;
  BreakAddr        : TAddr      = 0;
  FrameDirty       : Boolean    = False;  { set by CPU thread when FB written }
  VideoMode        : Word       = 0;      { current video mode (0=off,1=1bpp,2=8bpp) }

// ---------------------------------------------------------------------------
// I/O handler abstraction
// ---------------------------------------------------------------------------

type
  TIOHandler = object
    constructor Init;
    function  ReadIO(addr: TAddr): TWord; virtual;
    procedure WriteIO(addr: TAddr; v: TWord); virtual;
    procedure WriteByte(addr: TAddr; v: TByte); virtual;
  end;
  PIOHandler = ^TIOHandler;

var
  IO : PIOHandler = nil;   { installed at startup by CLI or GUI }

implementation

constructor TIOHandler.Init;
begin
  { nothing }
end;

function TIOHandler.ReadIO(addr: TAddr): TWord;
begin
  Result := 0;
end;

procedure TIOHandler.WriteIO(addr: TAddr; v: TWord);
begin
  { default: ignore }
end;

procedure TIOHandler.WriteByte(addr: TAddr; v: TByte);
begin
  { default: ignore }
end;

end.
