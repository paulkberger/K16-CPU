unit cpu_thread;
{
  K16 Emulator IDE -- CPU Worker Thread
  Runs the K16 CPU on a background thread so the UI stays responsive.
  Part of the K16 homebrew CPU project.

  Timing strategy (throttled mode):
    - Execute instructions in batches of BATCH_CYCLES K16 cycles.
    - After each batch, compute the wall-clock deadline using QPC (nanosecond
      resolution).  Sleep coarsely until ~1 ms before deadline, then spin-wait
      for the remaining microseconds.
    - This gives sub-1% speed error at all target frequencies from 1 MHz up.

  Why not GetTickCount64?
    GetTickCount64 has ~15 ms granularity without timeBeginPeriod, and ~1 ms
    with it.  At 10 MHz a 1 ms error is 10,000 cycles (0.1%) -- acceptable,
    but the sawtooth pattern (overshoot then immediate next batch) causes
    visible stutter in demos.  QPC eliminates this.
}
{$mode Delphi}
{$H+}
interface

uses
  Classes, SyncObjs, SysUtils,
  emu_types, emu_cpu, emu_decode, emu_opcodes, emu_debug, emu_timing;

type
  TCPUThread = class(TThread)
  private
    FStepping           : Boolean;
    FStepEvent          : TEvent;
    FJustHitBreakpoint  : Boolean;
    FBreakpointHit      : Boolean;  { set by thread, cleared by UI timer }
    procedure DoUpdatePanels;
    procedure DoOnHalt;
  protected
    procedure Execute; override;
  public
    { Callbacks — set by main form before starting thread }
    OnPanelUpdate : TNotifyEvent;
    OnHalt        : TNotifyEvent;
    HaltTick      : QWord;
    DebugOut      : procedure(const s: string) of object;  { wired to TermWrite }

    constructor Create;
    destructor  Destroy; override;

    procedure DoStep;          { signal one step (UI thread) }
    procedure DoRun;           { switch to continuous run }
    procedure DoStop;          { pause execution }

    property Stepping      : Boolean read FStepping;
    property BreakpointHit : Boolean read FBreakpointHit;
    procedure ClearBreakpointHit;
  end;

implementation

uses Windows;

{ ── inline sleep helper ────────────────────────────────────────────────────── }

{ Sleep until DeadlineNs (from GetNowNs).
  Strategy: coarse OS sleep to within SPIN_NS of deadline, then busy-spin.
  SPIN_NS = 1,500,000 (1.5 ms) keeps spin time short while covering ~1ms
  Sleep() overshoot. }
procedure SleepUntilNs(DeadlineNs: Int64);
const
  SPIN_NS = 1500000;  { 1.5 ms spin threshold }
var
  Remaining: Int64;
  SleepMs  : Integer;
begin
  repeat
    Remaining := DeadlineNs - GetNowNs;
    if Remaining <= 0 then Exit;
    if Remaining > SPIN_NS then
    begin
      { Coarse sleep: sleep for (remaining - SPIN_NS), rounded to ms }
      SleepMs := Integer((Remaining - SPIN_NS) div 1000000);
      if SleepMs > 0 then Sleep(SleepMs);
    end;
    { else: spin for the last 1.5 ms }
  until GetNowNs >= DeadlineNs;
end;

{ ── thread boilerplate ─────────────────────────────────────────────────────── }

constructor TCPUThread.Create;
begin
  inherited Create(True);   { suspended }
  FreeOnTerminate := False;
  FStepping  := True;       { start paused }
  FStepEvent := TEvent.Create(nil, False, False, '');
end;

destructor TCPUThread.Destroy;
begin
  FStepEvent.Free;
  inherited;
end;

procedure TCPUThread.DoStep;
begin
  FStepEvent.SetEvent;
end;

procedure TCPUThread.DoRun;
begin
  FStepping := False;
  FStepEvent.SetEvent;   { unblock if currently waiting }
end;

procedure TCPUThread.DoStop;
begin
  FStepping := True;
end;

procedure TCPUThread.ClearBreakpointHit;
begin
  FBreakpointHit := False;
end;

procedure TCPUThread.DoUpdatePanels;
begin
  if Assigned(OnPanelUpdate) then OnPanelUpdate(Self);
end;

procedure TCPUThread.DoOnHalt;
begin
  if Assigned(OnHalt) then OnHalt(Self);
end;

{ ── main execution loop ────────────────────────────────────────────────────── }

procedure TCPUThread.Execute;
var
  D            : TDecodedInstr;
  BatchCount   : Integer;      { instructions executed in current batch }
  BatchCycles  : Int64;        { K16 cycles accumulated in current batch }
  CheckCycles  : QWord;        { CycleCount target for next throttle check }
  DeadlineNs   : Int64;        { wall-clock deadline for current chunk }
  NsPerCycle   : Int64;        { nanoseconds per K16 cycle at TargetMHz }
  ChunkCycles  : QWord;        { K16 cycles per throttle chunk }
const
  { Run this many K16 cycles between throttle checks.
    At 10 MHz: 10,000 cycles = 1 ms of K16 time -- fine granularity.
    At 100 MHz: still 10,000 cycles = 100 µs -- acceptable.
    Keep it fixed so the spin-wait never has to cover more than ~1 ms. }
  CHUNK_CYCLES = 10000;
  BATCH        = 200;   { instructions between cheap loop-overhead checks }

begin
  { Compute per-cycle nanoseconds once.  TargetMHz is integer >= 1. }
  if TargetMHz > 0 then
    NsPerCycle := 1000000000 div TargetMHz   { e.g. 100 ns at 10 MHz }
  else
    NsPerCycle := 1000;   { fallback: 1 µs/cycle }

  ChunkCycles  := CHUNK_CYCLES;
  CheckCycles  := CPU.CycleCount + ChunkCycles;
  DeadlineNs   := GetNowNs + Int64(ChunkCycles) * NsPerCycle;
  BatchCount   := 0;
  BatchCycles  := 0;

  repeat
    { ── paused / stepping ────────────────────────────────────────────── }
    if FStepping then
    begin
      Synchronize(DoUpdatePanels);
      FStepEvent.WaitFor(INFINITE);
      FStepEvent.ResetEvent;
      if Terminated then Break;
      { Reset throttle baseline when resuming }
      CheckCycles := CPU.CycleCount + ChunkCycles;
      DeadlineNs  := GetNowNs + Int64(ChunkCycles) * NsPerCycle;
      BatchCount  := 0;
      BatchCycles := 0;
    end;

    if CPU.Halted or Terminated then Break;

    { ── breakpoint check ─────────────────────────────────────────────── }
    if BreakEnabled and (not FJustHitBreakpoint) and (CPU.PC = BreakAddr) then
    begin
      FStepping          := True;
      FJustHitBreakpoint := True;
      FBreakpointHit     := True;
      Continue;
    end;

    { ── execute one instruction ──────────────────────────────────────── }
    Fetch(D);
    DispatchTable[D.Opcode, D.Mode](D);
    Inc(CPU.CycleCount, D.Cycles);
    Inc(BatchCycles, D.Cycles);
    Inc(BatchCount);
    FJustHitBreakpoint := False;

    { ── periodic checks (every BATCH instructions) ───────────────────── }
    if BatchCount >= BATCH then
    begin
      BatchCount := 0;

      { MaxCycles limit }
      if MaxCyclesEnabled and (CPU.CycleCount >= MaxCycles) then
      begin
        CPU.Halted := True;
        Break;
      end;

      { Throttle: once we have consumed the target chunk of K16 cycles,
        sleep until the wall-clock deadline for that chunk. }
      if (RunMode = rmTimed) and (CPU.CycleCount >= CheckCycles) then
      begin
        SleepUntilNs(DeadlineNs);

        { Advance deadline by exactly ChunkCycles worth of nanoseconds.
          Do NOT re-sample GetNowNs here -- that would let accumulated
          sleep overshoot silently eat into the next chunk budget. }
        Inc(DeadlineNs, Int64(ChunkCycles) * NsPerCycle);
        CheckCycles := CPU.CycleCount + ChunkCycles;
        BatchCycles := 0;

        { Safety: if we are more than 2 chunks behind wall-clock (e.g.
          after a debugger break or OS scheduling hiccup), reset the
          deadline so we don't try to "catch up" by running flat-out. }
        if GetNowNs > DeadlineNs + Int64(2 * ChunkCycles) * NsPerCycle then
          DeadlineNs := GetNowNs + Int64(ChunkCycles) * NsPerCycle;
      end;

    end; { BatchCount >= BATCH }

  until CPU.Halted or Terminated;

  if not Terminated then
    Synchronize(DoOnHalt);
end;

end.
