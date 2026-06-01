program K16EmuCLI;
{
  K16 Emulator — Headless CLI Binary
  Usage: K16EmuCLI <file.bin> [options]
  Part of the K16 homebrew CPU project.
  https://github.com/paulkberger/K16-CPU
}

{$mode Delphi}
{$H+}

uses
  SysUtils,
  emu_types,
  emu_mem,
  emu_cpu,
  emu_alu,
  emu_decode,
  emu_opcodes,
  emu_io_digital,
  emu_debug;

// ---------------------------------------------------------------------------
// Command-line parsing
// ---------------------------------------------------------------------------

var
  BinFile    : string = '';
  LoadAddr   : TAddr  = BOOT_ROM;  { default: load at $FF0000 }
  KbdBlock   : Boolean = False;

procedure ParseArgs;
var
  i  : Integer;
  arg: string;
begin
  if ParamCount = 0 then
  begin
    WriteLn('K16 Emulator CLI');
    WriteLn('Usage: K16EmuCLI <file.bin> [options]');
    WriteLn('Options:');
    WriteLn('  --addr $XXXXXX   load address (default: $FF0000)');
    WriteLn('  --digital        digital mode I/O (default, can be omitted)');
    WriteLn('  --kbd-block      blocking keyboard input');
    WriteLn('  --trace          print disasm each instruction');
    WriteLn('  --trace-regs     full register dump each instruction');
    WriteLn('  --fast           maximum speed (default)');
    WriteLn('  --mhz N          throttle to N MHz');
    WriteLn('  --maxcycles N    stop after N cycles');
    WriteLn('  --break $ADDR    break at address');
    Halt(0);
  end;

  i := 1;
  while i <= ParamCount do
  begin
    arg := ParamStr(i);
    if (arg = '--digital') then
      { default — no-op }
    else if (arg = '--kbd-block') then
      KbdBlock := True
    else if (arg = '--trace') then
      TraceEnabled := True
    else if (arg = '--trace-regs') then
      TraceRegs := True
    else if (arg = '--fast') then
      RunMode := rmFast
    else if (arg = '--mhz') and (i < ParamCount) then
    begin
      Inc(i);
      TargetMHz := StrToIntDef(ParamStr(i), 10);
      RunMode   := rmTimed;
    end
    else if (arg = '--maxcycles') and (i < ParamCount) then
    begin
      Inc(i);
      MaxCycles        := StrToQWordDef(ParamStr(i), 0);
      MaxCyclesEnabled := MaxCycles > 0;
    end
    else if (arg = '--break') and (i < ParamCount) then
    begin
      Inc(i);
      BreakAddr    := StrToInt64Def('$' + ParamStr(i).TrimLeft(['$']), 0) and ADDR_MASK;
      BreakEnabled := True;
    end
    else if (arg = '--addr') and (i < ParamCount) then
    begin
      Inc(i);
      LoadAddr := StrToInt64Def('$' + ParamStr(i).TrimLeft(['$']), BOOT_ROM) and ADDR_MASK;
    end
    else if arg[1] <> '-' then
    begin
      if BinFile = '' then BinFile := arg
      else
      begin
        WriteLn(ErrOutput, 'Unknown argument: ', arg);
        Halt(1);
      end;
    end
    else
    begin
      WriteLn(ErrOutput, 'Unknown option: ', arg);
      Halt(1);
    end;
    Inc(i);
  end;

  if BinFile = '' then
  begin
    WriteLn(ErrOutput, 'Error: no .bin file specified');
    Halt(1);
  end;
end;

// ---------------------------------------------------------------------------
// Run loop
// ---------------------------------------------------------------------------

var
  DigIO : TDigitalIOHandler;

procedure RunCPU;
var
  D  : TDecodedInstr;
  Bu : Integer;
begin
  while not CPU.Halted do
  begin
    if TraceEnabled then
      WriteLn(Disassemble(CPU.PC, Bu));
    if TraceRegs then
      WriteLn(FormatRegs);
    Fetch(D);
    DispatchTable[D.Opcode, D.Mode](D);
    Inc(CPU.CycleCount, D.Cycles);

    if MaxCyclesEnabled and (CPU.CycleCount >= MaxCycles) then
    begin
      WriteLn(ErrOutput, Format('MaxCycles %d reached at PC=$%6.6X',
                                [MaxCycles, CPU.PC]));
      Break;
    end;

    if BreakEnabled and (CPU.PC = BreakAddr) then
    begin
      WriteLn(ErrOutput, Format('Breakpoint at $%6.6X', [BreakAddr]));
      Break;
    end;
  end;
end;

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

begin
  ParseArgs;

  { Install Digital I/O handler }
  DigIO.Init(KbdBlock);
  IO := @DigIO;

  { Initialise dispatch table }
  InitDispatch;

  { Clear memory and load binary }
  FillChar(Mem, SizeOf(Mem), 0);
  try
    MemLoadBin(BinFile, LoadAddr);
  except
    on E: Exception do
    begin
      WriteLn(ErrOutput, 'Load error: ', E.Message);
      Halt(1);
    end;
  end;

  { Reset CPU — PC := $FF0000 }
  CPU.Reset;

  { Run }
  RunCPU;

  { Exit code = HALT code }
  ExitCode := CPU.HaltCode;
end.
