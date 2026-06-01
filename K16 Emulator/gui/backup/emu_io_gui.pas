unit emu_io_gui;
{
  K16 Emulator IDE -- GUI I/O Handler
  Keyboard: LCL key event queue polled by K16 code reading $DE0000.
  Terminal: output routed to a callback (main form wires it to TMemo).
  Video mode: handled via IOWriteHook in emu_mem.
  Part of the K16 homebrew CPU project.
}
{$mode Delphi}
{$H+}
interface

uses
  SysUtils, SyncObjs,
  emu_types;

type
  TTermOutputCallback = procedure(ch: Byte) of object;

  TGUIIOHandler = object(TIOHandler)
    { Terminal output callback — set by main form }
    TermOutput : TTermOutputCallback;

    constructor Init;
    function  ReadIO(addr: TAddr): TWord; virtual;
    procedure WriteIO(addr: TAddr; v: TWord); virtual;
    procedure WriteByte(addr: TAddr; v: TByte); virtual;
    procedure QueueKey(code: Word);        { called from MemoTerminal OnKeyPress/Down — UI thread }
    procedure EnqueueString(const S: string);  { paste support — UI thread }

  private
    FLock    : TCriticalSection;
    FKbdBuf  : array[0..255] of Word;
    FKbdHead : Integer;
    FKbdTail : Integer;
    function  KbdPoll: TWord;
  end;

implementation

constructor TGUIIOHandler.Init;
begin
  FLock    := TCriticalSection.Create;
  FKbdHead := 0;
  FKbdTail := 0;
  TermOutput := nil;
end;

procedure TGUIIOHandler.QueueKey(code: Word);
begin
  if code = 0 then Exit;   { NUL is the empty sentinel -- never buffer it }
  FLock.Enter;
  try
    { Drop oldest on overflow }
    if (FKbdTail + 1) and 255 = FKbdHead then
      FKbdHead := (FKbdHead + 1) and 255;
    FKbdBuf[FKbdTail] := code;
    FKbdTail := (FKbdTail + 1) and 255;
  finally
    FLock.Leave;
  end;
end;

procedure TGUIIOHandler.EnqueueString(const S: string);
var
  I : Integer;
  Ch: Byte;
begin
  for I := 1 to Length(S) do
  begin
    Ch := Ord(S[I]);
    case Ch of
      10      : QueueKey(13);   { LF -> CR }
      13      : QueueKey(13);
      9       : QueueKey(9);    { Tab }
      32..126 : QueueKey(Ch);   { printable ASCII }
      { everything else dropped }
    end;
  end;
end;

function TGUIIOHandler.KbdPoll: TWord;
begin
  FLock.Enter;
  try
    if FKbdHead = FKbdTail then
      Result := 0
    else
    begin
      Result   := $8000 or FKbdBuf[FKbdHead];
      FKbdHead := (FKbdHead + 1) and 255;
    end;
  finally
    FLock.Leave;
  end;
end;

function TGUIIOHandler.ReadIO(addr: TAddr): TWord;
begin
  Result := 0;
  case addr of
    KBD_ADDR: Result := KbdPoll;
  end;
end;

procedure TGUIIOHandler.WriteIO(addr: TAddr; v: TWord);
begin
  { VID_MODE handled via IOWriteHook in emu_mem }
end;

procedure TGUIIOHandler.WriteByte(addr: TAddr; v: TByte);
begin
  case addr of
    TERM_ADDR:
      if Assigned(TermOutput) then TermOutput(v);
  end;
end;

end.
