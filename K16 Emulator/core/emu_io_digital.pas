unit emu_io_digital;
{
  K16 Emulator — Digital Mode I/O Handler
  stdin/stdout I/O; no video. Default handler for K16EmuCLI.
  Part of the K16 homebrew CPU project.
}

{$mode Delphi}
{$H+}

interface

uses
  emu_types;

type
  TDigitalIOHandler = object(TIOHandler)
    BlockingKbd : Boolean;
    constructor Init(ABlocking: Boolean);
    function  ReadIO(addr: TAddr): TWord; virtual;
    procedure WriteIO(addr: TAddr; v: TWord); virtual;
    procedure WriteByte(addr: TAddr; v: TByte); virtual;
  end;

implementation

uses
  {$IFDEF UNIX} BaseUnix, termio, {$ENDIF}
  Crt, SysUtils;

constructor TDigitalIOHandler.Init(ABlocking: Boolean);
begin
  BlockingKbd := ABlocking;
end;

function TDigitalIOHandler.ReadIO(addr: TAddr): TWord;
begin
  Result := 0;
  case addr of
    KBD_ADDR:
    begin
      if BlockingKbd then
      begin
        { Block until a character is available }
        Result := $8000 or Ord(ReadKey);
      end else
      begin
        if KeyPressed then
          Result := $8000 or Ord(ReadKey)
        else
          Result := $0000;
      end;
    end;
    VID_MODE: Result := $0000;   { ignored in digital mode }
  end;
end;

procedure TDigitalIOHandler.WriteIO(addr: TAddr; v: TWord);
begin
  { Word writes — silently ignored in digital mode }
end;

procedure TDigitalIOHandler.WriteByte(addr: TAddr; v: TByte);
begin
  case addr of
    TERM_ADDR:
    begin
      Write(Chr(v));
      Flush(Output);
    end;
  end;
end;

end.
