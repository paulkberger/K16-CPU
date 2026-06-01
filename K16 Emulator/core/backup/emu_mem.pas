unit emu_mem;
{
  K16 Emulator — Memory Subsystem
  Flat 16MB little-endian RAM/ROM model.
  All data memory accesses are little-endian (low byte at lower address).
  I/O range $D80000..$DFFFFF is routed through the IO^ handler.
  Part of the K16 homebrew CPU project.
}

{$mode Delphi}
{$H+}

interface

uses
  SysUtils, Classes, emu_types;

var
  Mem      : array[0..MEM_SIZE-1] of TByte;
  VideoMode  : TWord    = 0;   { current video mode: 0=off 1=1bpp 1280x720 2=8bpp VGA 640x480 3=8bpp grey 640x480 }
  FrameDirty : Boolean  = False; { set when FB written or mode changed; cleared by UI timer }

// ---------------------------------------------------------------------------
// Core memory primitives — all addresses masked to 24 bits
// ---------------------------------------------------------------------------

function  MemReadByte(addr: TAddr): TByte; inline;
procedure MemWriteByte(addr: TAddr; v: TByte); inline;
function  MemReadWord(addr: TAddr): TWord; inline;
procedure MemWriteWord(addr: TAddr; v: TWord); inline;

// ---------------------------------------------------------------------------
// Binary loader
// ---------------------------------------------------------------------------

procedure MemLoadBin(const FileName: string; BaseAddr: TAddr);
procedure MemLoadBinBE(const FileName: string; BaseAddr: TAddr);
procedure MemLoadHex(const FileName: string; out LoadAddr: TAddr);
{ Loads an Intel HEX file. LoadAddr receives the lowest address in the file. }

// ---------------------------------------------------------------------------
// I/O write callback (GUI sets this; CLI leaves nil)
// ---------------------------------------------------------------------------

type
  TIOWriteCallback = procedure(addr: TAddr; value: TWord);

var
  IOWriteHook : TIOWriteCallback = nil;

// ---------------------------------------------------------------------------
// Alignment-fault hook — set by the CPU module so emu_mem can raise data
// faults on odd-address word access without a circular unit dependency.
// Must be one-shot safe (early-exit if already halted).
// ---------------------------------------------------------------------------

type
  TFaultProc = procedure(addr: TAddr);

var
  DataFaultHook : TFaultProc = nil;   { wired by emu_opcodes init }
  CodeFaultHook : TFaultProc = nil;   { wired by emu_opcodes init }
  SuppressFaults : Boolean = False;   { set by disassembler/UI when probing memory }

implementation

// ---------------------------------------------------------------------------
// Byte access
// ---------------------------------------------------------------------------

function MemReadByte(addr: TAddr): TByte;
begin
  Result := Mem[addr and ADDR_MASK];
end;

procedure MemWriteByte(addr: TAddr; v: TByte);
var
  a: TAddr;
begin
  a := addr and ADDR_MASK;
  if (a >= IO_BASE) and (a <= IO_TOP) then
  begin
    if Assigned(IO) then IO^.WriteByte(a, v);
    Exit;
  end;
  Mem[a] := v;
  if (a >= FB_BASE) and (a < FB_BASE + $4B000) then  { $4B000 = 307200 = 640x480 (largest mode) }
    FrameDirty := True;
end;

// ---------------------------------------------------------------------------
// Word access — little-endian
// ---------------------------------------------------------------------------

function MemReadWord(addr: TAddr): TWord;
var
  a: TAddr;
begin
  a := addr and ADDR_MASK;
  if (a and 1) <> 0 then
  begin
    if (not SuppressFaults) and Assigned(DataFaultHook) then DataFaultHook(a);
    { Return a benign value; if hook halted CPU the dispatcher won't dispatch. }
    Result := 0;
    Exit;
  end;
  if (a >= IO_BASE) and (a <= IO_TOP) then
  begin
    if Assigned(IO) then Result := IO^.ReadIO(a)
    else Result := 0;
    Exit;
  end;
  Result := TWord(Mem[a]) or (TWord(Mem[(a + 1) and ADDR_MASK]) shl 8);
end;

procedure MemWriteWord(addr: TAddr; v: TWord);
var
  a: TAddr;
begin
  a := addr and ADDR_MASK;
  if (a and 1) <> 0 then
  begin
    if (not SuppressFaults) and Assigned(DataFaultHook) then DataFaultHook(a);
    Exit;
  end;
  if (a >= IO_BASE) and (a <= IO_TOP) then
  begin
    { VID_MODE handled specially }
    if a = VID_MODE then
    begin
      VideoMode  := v;
      FrameDirty := True;
      if Assigned(IOWriteHook) then IOWriteHook(a, v);
    end;
    { VID_PAGE — FB base page register, zero-extended from 16-bit write.
      Default page $00B0. Write e.g. $00B4 to move FB base by 256KB. }
    if a = VID_PAGE then
    begin
      FB_BASE := (TAddr(v) and $FFFF) shl 16;
      FrameDirty := True;
    end;
    if Assigned(IO) then IO^.WriteIO(a, v);
    Exit;
  end;
  Mem[a]                        := v and $FF;
  Mem[(a + 1) and ADDR_MASK]    := v shr 8;
end;

// ---------------------------------------------------------------------------
// Binary loader
// Assembler .bin format: little-endian words, one word per instruction word.
// Bytes are copied verbatim into Mem[] starting at BaseAddr.
// ---------------------------------------------------------------------------

procedure MemLoadBin(const FileName: string; BaseAddr: TAddr);
var
  F    : TFileStream;
  Size : Int64;
begin
  F := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    Size := F.Size;
    if (BaseAddr + TAddr(Size)) > MEM_SIZE then
      raise Exception.CreateFmt(
        'MemLoadBin: file "%s" (%d bytes) at $%06X overflows 16MB address space',
        [FileName, Size, BaseAddr]);
    if Size > 0 then
      F.ReadBuffer(Mem[BaseAddr], Size);
  finally
    F.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Big-endian loader -- byte-swaps each word pair on load
// Use when assembler emits big-endian (high byte first) binary files.
// ---------------------------------------------------------------------------

procedure MemLoadBinBE(const FileName: string; BaseAddr: TAddr);
var
  F    : TFileStream;
  Size : Int64;
  i    : TAddr;
  tmp  : TByte;
begin
  MemLoadBin(FileName, BaseAddr);
  { swap each byte pair in the loaded region }
  F := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    Size := F.Size;
  finally
    F.Free;
  end;
  i := 0;
  while i + 1 < TAddr(Size) do
  begin
    tmp := Mem[BaseAddr + i];
    Mem[BaseAddr + i]     := Mem[BaseAddr + i + 1];
    Mem[BaseAddr + i + 1] := tmp;
    Inc(i, 2);
  end;
end;

procedure MemLoadHex(const FileName: string; out LoadAddr: TAddr);
{ Intel HEX I32HEX loader. Writes bytes directly into Mem[] at their
  assembled addresses. LoadAddr = lowest address seen in the file. }
var
  Lines     : TStringList;
  Line      : string;
  i, n      : Integer;
  ByteCount : Integer;
  RecAddr   : LongWord;
  RecType   : Byte;
  ExtLinear : LongWord;
  FullAddr  : LongWord;
  MinAddr   : LongWord;
  b         : Byte;

  function HexByte(const s: string; Pos: Integer): Byte;
  begin
    Result := Byte(StrToInt('$' + Copy(s, Pos, 2)));
  end;

begin
  LoadAddr  := RESET_VEC;
  MinAddr   := TAddr($FFFFFF);
  ExtLinear := 0;

  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(FileName);

    { First pass — find lowest address for LoadAddr }
    for i := 0 to Lines.Count - 1 do
    begin
      Line := Trim(Lines[i]);
      if (Length(Line) < 11) or (Line[1] <> ':') then Continue;
      ByteCount := HexByte(Line, 2);
      RecAddr   := (LongWord(HexByte(Line, 4)) shl 8) or HexByte(Line, 6);
      RecType   := HexByte(Line, 8);
      case RecType of
        $04: ExtLinear := (LongWord(HexByte(Line, 10)) shl 8 or HexByte(Line, 12)) shl 16;
        $00:
          begin
            FullAddr := (ExtLinear or RecAddr) and ADDR_MASK;
            if FullAddr < MinAddr then MinAddr := FullAddr;
          end;
        $01: Break;
      end;
    end;

    if MinAddr <= ADDR_MASK then
      LoadAddr := MinAddr;

    { Second pass — load bytes into Mem[] }
    ExtLinear := 0;
    for i := 0 to Lines.Count - 1 do
    begin
      Line := Trim(Lines[i]);
      if (Length(Line) < 11) or (Line[1] <> ':') then Continue;
      ByteCount := HexByte(Line, 2);
      RecAddr   := (LongWord(HexByte(Line, 4)) shl 8) or HexByte(Line, 6);
      RecType   := HexByte(Line, 8);
      case RecType of
        $04: ExtLinear := (LongWord(HexByte(Line, 10)) shl 8 or HexByte(Line, 12)) shl 16;
        $00:
          begin
            FullAddr := (ExtLinear or RecAddr) and ADDR_MASK;
            for n := 0 to ByteCount - 1 do
            begin
              b := HexByte(Line, 10 + n * 2);
              Mem[(FullAddr + LongWord(n)) and ADDR_MASK] := b;
            end;
          end;
        $01: Break;
      end;
    end;

  finally
    Lines.Free;
  end;
end;

end.
