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
  StartTick     : QWord;
  GuiTick       : QWord;     { last GUI update tick }
  TargetMs      : Double;
  ActualMs      : Double;
  SleepMs       : Integer;
  CheckCycles   : QWord;
  DbgCount      : Integer;
const
  THROTTLE_INTERVAL = 50000;
  GUI_INTERVAL_MS   = 100;   { update panels ~10 times/sec }

  procedure TermStr(const s: string);
  var i: Integer;
  begin
    if not Assigned(IO) then Exit;
    for i := 1 to Length(s) do IO^.WriteByte(TERM_ADDR, Byte(s[i]));
    IO^.WriteByte(TERM_ADDR, 10);
  end;

begin
  StartTick   := GetTickCount64;
  GuiTick     := GetTickCount64;
  CheckCycles := CPU.CycleCount + THROTTLE_INTERVAL;
  DbgCount    := 0;

  repeat
    if FStepping then
    begin
      FStepEvent.WaitFor(INFINITE);
      FStepEvent.ResetEvent;
      if Terminated then Break;
      StartTick   := GetTickCount64;
      GuiTick     := GetTickCount64;
      CheckCycles := CPU.CycleCount + THROTTLE_INTERVAL;
      DbgCount    := 0;
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
      TargetMs := THROTTLE_INTERVAL / (TargetMHz + 0.0) / 1000.0;
      ActualMs := GetTickCount64 - StartTick;   { time to execute this chunk }

      Inc(DbgCount);
      if DbgCount <= 3 then
        TermStr(Format('[THR#%d] execMs=%.1f targetMs=%.1f sleepMs=%.1f',
          [DbgCount, ActualMs, TargetMs, TargetMs - ActualMs]));

      { Sleep the deficit — don't reset StartTick until after sleep }
      if TargetMs > ActualMs then
      begin
        SleepMs := Trunc(TargetMs - ActualMs);
        if SleepMs > 2 then Sleep(SleepMs - 1);
        while (GetTickCount64 - StartTick) < QWord(Trunc(TargetMs)) do ;
      end;

      { Baseline for next chunk starts NOW (after sleep) }
      StartTick   := GetTickCount64;
      CheckCycles := CPU.CycleCount + THROTTLE_INTERVAL;
    end;

    { GUI update at ~10Hz — absorb into throttle baseline after Synchronize }
    if FStepping then
      Synchronize(DoUpdatePanels)
    else if (GetTickCount64 - GuiTick) >= GUI_INTERVAL_MS then
    begin
      GuiTick   := GetTickCount64;
      Synchronize(DoUpdatePanels);
      { GUI update consumed real time — treat it as if it were execution time
        by NOT resetting StartTick here; the next throttle check will see
        the extra ms and sleep less to compensate }
    end;

  until CPU.Halted or Terminated;

  if not Terminated then
    Synchronize(DoOnHalt);
end;

end.
