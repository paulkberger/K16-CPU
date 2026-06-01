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
  emu_types, emu_cpu, emu_decode, emu_opcodes, emu_debug;

type
  TCPUThread = class(TThread)
  private
    FStepping  : Boolean;
    FStepEvent : TEvent;
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
  D           : TDecodedInstr;
  StartTick   : QWord;
  TargetMs    : Double;
  ActualMs    : Double;
  SleepMs     : Integer;
  CheckCycles : QWord;
const
  THROTTLE_INTERVAL = 10000;   { smaller chunks = more accurate throttle }

begin
  StartTick   := GetTickCount64;
  CheckCycles := CPU.CycleCount + QWord(Trunc(TargetMHz * 10000.0));

  repeat
    if FStepping then
    begin
      Synchronize(DoUpdatePanels);
      FStepEvent.WaitFor(INFINITE);
      FStepEvent.ResetEvent;
      if Terminated then Break;
      StartTick   := GetTickCount64;
      CheckCycles := CPU.CycleCount + QWord(Trunc(TargetMHz * 10000.0));
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
      Continue;
    end;

    if (RunMode = rmTimed) and (CPU.CycleCount >= CheckCycles) then
    begin
      TargetMs := THROTTLE_INTERVAL / (TargetMHz + 0.0) / 1000.0;
      ActualMs := GetTickCount64 - StartTick;

      if TargetMs > ActualMs then
      begin
        SleepMs := Trunc(TargetMs - ActualMs) - 1;
        if SleepMs > 0 then Sleep(SleepMs);
      end;

      StartTick   := GetTickCount64;
      { Scale interval: aim for ~10ms sleep chunks regardless of MHz }
      CheckCycles := CPU.CycleCount + QWord(Trunc(TargetMHz * 10000.0));
    end;

  until CPU.Halted or Terminated;

  if not Terminated then
    Synchronize(DoOnHalt);
end;

end.
