unit cpu_thread;
{
  K16 Emulator IDE -- CPU Worker Thread
  Runs the K16 CPU on a background thread so the UI stays responsive.
  Part of the K16 homebrew CPU project.
}
{$mode Delphi}
{$H+}
interface

uses
  Classes, SyncObjs, SysUtils,
  emu_types, emu_mem, emu_cpu, emu_decode, emu_opcodes, emu_debug;

type
  TCPUThread = class(TThread)
  private
    FStepping  : Boolean;
    FStepEvent : TEvent;
    FRunMode   : TRunMode;
    procedure DoUpdatePanels;
    procedure DoOnHalt;
  protected
    procedure Execute; override;
  public
    { Callbacks — set by main form before starting thread }
    OnPanelUpdate : TNotifyEvent;
    OnHalt        : TNotifyEvent;
    HaltTick      : QWord;   { GetTickCount64 captured at halt }

    constructor Create;
    destructor  Destroy; override;

    procedure DoStep;          { signal one step (UI thread) }
    procedure DoRun;           { switch to continuous run }
    procedure DoStop;          { pause execution }

    property Stepping : Boolean read FStepping;
  end;

implementation

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

procedure TCPUThread.DoUpdatePanels;
begin
  if Assigned(OnPanelUpdate) then OnPanelUpdate(Self);
end;

procedure TCPUThread.DoOnHalt;
begin
  if Assigned(OnHalt) then OnHalt(Self);
end;

procedure TCPUThread.Execute;
var
  D             : TDecodedInstr;
  StartTime     : TDateTime;
  StartCycles   : QWord;      { CycleCount snapshot when timing began }
  TargetSec     : Double;
  ActualSec     : Double;
  SleepMs       : Integer;
  CheckCycles   : QWord;      { next cycle count to check throttle }
const
  THROTTLE_INTERVAL = 1000;   { check throttle every N cycles }
begin
  StartTime   := Now;
  StartCycles := CPU.CycleCount;
  CheckCycles := CPU.CycleCount + THROTTLE_INTERVAL;

  repeat
    if FStepping then
    begin
      FStepEvent.WaitFor(INFINITE);
      FStepEvent.ResetEvent;
      if Terminated then Break;
      { Reset timing baseline so throttle is correct from this moment }
      StartTime   := Now;
      StartCycles := CPU.CycleCount;
      CheckCycles := CPU.CycleCount + THROTTLE_INTERVAL;
    end;

    if CPU.Halted or Terminated then Break;

    Fetch(D);
    DispatchTable[D.Opcode, D.Mode](D);
    Inc(CPU.CycleCount, D.Cycles);

    if MaxCyclesEnabled and (CPU.CycleCount >= MaxCycles) then
    begin
      CPU.Halted := True;
      Break;
    end;

    if BreakEnabled and (CPU.PC = BreakAddr) then
    begin
      FStepping := True;
      Synchronize(DoUpdatePanels);
      Continue;
    end;

    { Throttle to TargetMHz in rmTimed mode }
    if (RunMode = rmTimed) and (CPU.CycleCount >= CheckCycles) then
    begin
      CheckCycles := CPU.CycleCount + THROTTLE_INTERVAL;
      { Elapsed cycles since timing baseline }
      TargetSec := Double(CPU.CycleCount - StartCycles) / (TargetMHz * 1000000.0);
      ActualSec := (Now - StartTime) * 86400.0;
      if TargetSec > ActualSec then
      begin
        SleepMs := Trunc((TargetSec - ActualSec) * 1000) - 1;
        if SleepMs > 1 then Sleep(SleepMs);
        { spin for the remaining sub-ms }
        while ((Now - StartTime) * 86400.0) < TargetSec do ;
      end;
    end;

    if FStepping then
      Synchronize(DoUpdatePanels)
    else if (CPU.CycleCount mod 50000) = 0 then
      Synchronize(DoUpdatePanels);

  until CPU.Halted or Terminated;

  if not Terminated then
    Synchronize(DoOnHalt);
end;

end.
