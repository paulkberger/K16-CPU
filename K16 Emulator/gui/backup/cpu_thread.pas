unit cpu_thread;
{
  K16 Emulator IDE -- CPU Worker Thread
  Runs the K16 CPU on a background thread so the UI stays responsive.
  Part of the K16 homebrew CPU project.

  Throttle strategy:
    Execute chunks of K16 cycles (~10ms worth), then Sleep(1) until the
    wall-clock deadline.  GetTickCount64 with timeBeginPeriod(1) gives
    ~1ms resolution -- plenty for a 1-2% speed tolerance at 10 MHz.
    QPC (GetNowNs) is used only by frm_main for the MHz display.
}
{$mode Delphi}
{$H+}
interface

uses
  Classes, SyncObjs, SysUtils,
  emu_types, emu_cpu, emu_mem, emu_decode, emu_opcodes, emu_debug;

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
    { Callbacks -- set by main form before starting thread }
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

procedure TCPUThread.Execute;
var
  D            : TDecodedInstr;
  BatchCount   : Integer;
  CheckCycles  : QWord;   { CycleCount threshold for next throttle check }
  DeadlineTick : QWord;   { GetTickCount64 target after executing one chunk }
  ChunkCycles  : QWord;   { K16 cycles per CHUNK_MS of wall time }
const
  CHUNK_MS = 10;          { throttle granularity in milliseconds }
  BATCH    = 500;         { instructions between overhead checks }

begin
  ChunkCycles  := QWord(TargetMHz) * 10000;   { cycles in CHUNK_MS at target MHz }
  CheckCycles  := CPU.CycleCount + ChunkCycles;
  DeadlineTick := GetTickCount64 + CHUNK_MS;
  BatchCount   := 0;

  repeat

    { -- paused / single-step }
    if FStepping then
    begin
      Synchronize(DoUpdatePanels);
      FStepEvent.WaitFor(INFINITE);
      FStepEvent.ResetEvent;
      if Terminated then Break;
      CheckCycles  := CPU.CycleCount + ChunkCycles;
      DeadlineTick := GetTickCount64 + CHUNK_MS;
      BatchCount   := 0;
    end;

    if CPU.Halted or Terminated then Break;

    { -- breakpoint }
    if BreakEnabled and (not FJustHitBreakpoint) and (CPU.PC = BreakAddr) then
    begin
      FStepping          := True;
      FJustHitBreakpoint := True;
      FBreakpointHit     := True;
      Continue;
    end;

    { -- execute one instruction }
    Fetch(D);

    { -- magic NOP $00FF — software-portable breakpoint.
      Hardware ignores the operand and executes a normal NOP, so leaving
      these in production code is safe. In the emulator we drop to step
      mode so the user can inspect state at this exact PC.
      Detected post-Fetch (CPU.IR is the just-fetched word) to avoid an
      extra MemReadWord every loop iteration; PC is rewound so the NOP
      has not yet executed when stepping resumes. }
    if (CPU.IR = $00FF) and (not FJustHitBreakpoint) then
    begin
      CPU.PC := (CPU.PC - 2) and ADDR_MASK;
      FStepping          := True;
      FJustHitBreakpoint := True;
      FBreakpointHit     := True;
      Continue;
    end;

    DispatchTable[D.Opcode, D.Mode](D);
    Inc(CPU.CycleCount, D.Cycles);
    Inc(BatchCount);
    FJustHitBreakpoint := False;

    { -- hardware interrupt check
      IRQPending is written by the main thread (vblank timer) and read here.
      Single-byte access is atomic on x86 — no critical section needed.
      We reuse the dispatch table path: fabricate a decoded INT instruction
      and call DispatchTable[$1F,3] directly, exactly as hardware does by
      forcing $FFFF onto the IR bus. }
    if CPU.SR.IE and (CPU.IRQPending <> 0) then
    begin
      CPU.IRQPending := 0;
      D.Opcode := $1F;
      D.Mode   := 3;
      D.Cycles := 16;
      DispatchTable[$1F, 3](D);
      Inc(CPU.CycleCount, 16);
    end;

    { -- periodic checks every BATCH instructions }
    if BatchCount >= BATCH then
    begin
      BatchCount := 0;

      if MaxCyclesEnabled and (CPU.CycleCount >= MaxCycles) then
      begin
        CPU.Halted := True;
        Break;
      end;

      if (RunMode = rmTimed) and (CPU.CycleCount >= CheckCycles) then
      begin
        { Sleep until deadline.  Sleep(1) with timeBeginPeriod(1) active
          wakes in approx 1-2ms.  Check Terminated each pass. }
        while (GetTickCount64 < DeadlineTick) and not Terminated do
          Sleep(1);

        { Advance deadline by one chunk.
          If more than one chunk behind (OS pause, debugger), reset. }
        Inc(DeadlineTick, CHUNK_MS);
        if GetTickCount64 > DeadlineTick + CHUNK_MS then
          DeadlineTick := GetTickCount64 + CHUNK_MS;

        CheckCycles := CPU.CycleCount + ChunkCycles;
      end;

    end;

  until CPU.Halted or Terminated;

  if not Terminated then
    Synchronize(DoOnHalt);
end;

end.
