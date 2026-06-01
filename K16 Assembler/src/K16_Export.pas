{
  K16_Export.pas — K16 ROM Image Generator

  Builds split high/low byte ROM images from assembled machine code,
  optionally patching in pre-generated lookup tables. Output is in
  Digital v2.0 raw format for direct use with the Digital circuit simulator.

  Also exports:
    - Intel HEX for the emulator
    - Flat binary (.bin) for any byte-level consumer
    - k/OS .COM executable (flat binary with $0200 origin validation)

  Part of the K16 homebrew CPU project.
  https://github.com/paulkberger/K16-CPU

  License: MIT
}
unit K16_Export;

{$mode Delphi}

interface
uses
  SysUtils, Classes,
  K16_Assembler,
  K16_Encoder_Base;

procedure AppendBytes(var Target: TArray<Byte>; const Data: TArray<Byte>);
procedure SplitHighLow(const Source: TArray<Byte>; out HighBytes, LowBytes: TArray<Byte>);

function  GenerateROMs(Ass: TK16Assembler; OutputPath: String; AddLookups: Boolean;
                       const ROMDiskFile: string = ''): string;
function  GenerateBin(Ass: TK16Assembler; const FileName: string): string;
function  GenerateCom(Ass: TK16Assembler; const FileName: string): string;
function  GenerateIntelHex(Ass: TK16Assembler; const FileName: string): string;

procedure SaveAsIntelHex(const FileName: string; const Data: TArray<Byte>; BaseAddr: LongWord);
function  LoadIntelHex(const FileName: string; out LoadAddr: LongWord): TArray<Byte>;

procedure SaveAsDigitalRawV2(const FileName: string; const Data: TArray<Byte>);
procedure SaveAsBinaryFile(const FileName: string; const Data: TArray<Byte>);

implementation

procedure AppendBytes(var Target: TArray<Byte>; const Data: TArray<Byte>);
var
  OldLen, NewLen, I: Integer;
begin
  OldLen := Length(Target);
  NewLen := OldLen + Length(Data);
  SetLength(Target, NewLen);
  for I := 0 to High(Data) do
    Target[OldLen + I] := Data[I];
end;

procedure SplitHighLow(const Source: TArray<Byte>; out HighBytes, LowBytes: TArray<Byte>);
var
  I, WordCount: Integer;
begin
  HighBytes := nil;
  LowBytes  := nil;
  // Source is little-endian (GetBytes convention since the .BYTE odd-address fix):
  //   byte 0 = low byte  (D0-D7 ROM)
  //   byte 1 = high byte (D8-D15 ROM)

  if Length(Source) mod 2 <> 0 then
    raise Exception.Create('Source byte array length must be even for 16-bit word splitting');

  WordCount := Length(Source) div 2;
  SetLength(HighBytes, WordCount);
  SetLength(LowBytes, WordCount);
  for I := 0 to WordCount - 1 do
  begin
    // Little-endian: first byte is low, second byte is high
    LowBytes[I]  := Source[I * 2];      // D0-D7 (low byte)
    HighBytes[I] := Source[I * 2 + 1];  // D8-D15 (high byte)
  end;
end;

function GenerateROMs(Ass: TK16Assembler; OutputPath: String; AddLookups: Boolean;
                      const ROMDiskFile: string = ''): string;
const
  // k/OS ROM disk lives at pages $FC..$FD = absolute $FC0000..$FDFFFF.
  // Exactly 256 sectors × 512 B = 131072 bytes; format is FAT16 (one
  // disk image file produced under EMU and baked into program ROM here).
  ROMDISK_BASE_ABS = $FC0000;
  ROMDISK_SIZE     = 131072;
var
  i, j: Integer;
  MachCode: TMachineCode;
  Bytes: TArray<Byte>;
  ROMImage: TArray<Byte>;
  ROMHigh, ROMLow: TArray<Byte>;
  LookupLow, LookupHigh: TArray<Byte>;
  MinAddr, MaxAddr: UInt32;
  BaseAddr: UInt32;
  ROMOffset: Integer;
  RequiredSize: Integer;
  LookupBytes: Integer;
  ActualPath: string;
  ROMDiskBytes: TArray<Byte>;
  ROMDiskOffset: Integer;
  ROMDiskSizeEnd: Integer;
  ROMDiskUsed: Boolean;

  function LoadBinaryFile(const FileName: string): TArray<Byte>;
  var
    FS: TFileStream;
  begin
    Result := nil;
    if not FileExists(FileName) then
    begin
      SetLength(Result, 0);
      Exit;
    end;
    FS := TFileStream.Create(FileName, fmOpenRead);
    try
      SetLength(Result, FS.Size);
      if FS.Size > 0 then
        FS.ReadBuffer(Result[0], FS.Size);
    finally
      FS.Free;
    end;
  end;

begin
  ROMImage    := nil;
  ROMHigh     := nil;
  ROMLow      := nil;
  LookupLow   := nil;
  LookupHigh  := nil;
  ROMDiskUsed := False;

  if Ass = nil then
  begin
    Result := 'Error: assembler reference is nil (assembly not completed?)';
    Exit;
  end;

  // Validate output path
  ActualPath := Trim(OutputPath);
  if ActualPath = '' then
    ActualPath := '.\'
  else if not ActualPath.EndsWith('\') and not ActualPath.EndsWith('/') then
    ActualPath := ActualPath + '\';

  // Check if path exists
  if not DirectoryExists(ExtractFilePath(ActualPath)) then
  begin
    // Try to get parent directory for paths ending with backslash
    if (ActualPath <> '.\') and not DirectoryExists(Copy(ActualPath, 1, Length(ActualPath) - 1)) then
    begin
      Result := Format('Error: Output path not found: "%s"', [OutputPath]);
      Exit;
    end;
  end;

  BaseAddr := Ass.BaseAddress;  // e.g., $F00000
  MinAddr := $FFFFFF;
  MaxAddr := 0;

  try
    // 1. Load pre-generated lookup tables (only if needed)
    if AddLookups then
    begin
      LookupLow  := LoadBinaryFile(ActualPath + 'Lookup_LO_00.bin');
      LookupHigh := LoadBinaryFile(ActualPath + 'Lookup_HI_00.bin');
      LookupBytes := Length(LookupLow) + Length(LookupHigh);
    end
    else
    begin
      SetLength(LookupLow, 0);
      SetLength(LookupHigh, 0);
      LookupBytes := 0;
    end;

    // 2. Calculate required ROM size - find address range of program code
    for i := 0 to Ass.MachineCode.Count - 1 do
    begin
      MachCode := Ass.MachineCode[i];
      Bytes := MachCode.GetBytes;

      if MachCode.Address < MinAddr then
        MinAddr := MachCode.Address;
      if MachCode.Address + UInt32(Length(Bytes)) > MaxAddr then
        MaxAddr := MachCode.Address + UInt32(Length(Bytes));
    end;

    // Handle empty program
    if MinAddr > MaxAddr then
    begin
      MinAddr := BaseAddr;
      MaxAddr := BaseAddr;
    end;

    // Calculate ROM size needed:
    // ROM offset = CPU address - BaseAddr (direct mapping)
    // Lookups and code share the same address space
    RequiredSize := Integer(MaxAddr - BaseAddr);

    // Ensure even size and minimum of 2 bytes
    if RequiredSize < 2 then
      RequiredSize := 2;
    if RequiredSize mod 2 <> 0 then
      Inc(RequiredSize);

    // 3. Create ROM image
    SetLength(ROMImage, RequiredSize);
    FillChar(ROMImage[0], RequiredSize, 0);

    // 4. Place program code (direct mapping: ROM offset = CPU addr - BaseAddr)
    for i := 0 to Ass.MachineCode.Count - 1 do
    begin
      MachCode := Ass.MachineCode[i];
      Bytes := MachCode.GetBytes;

      // Calculate ROM offset: direct mapping from CPU address
      ROMOffset := Integer(MachCode.Address) - Integer(BaseAddr);

      // Validate offset
      if ROMOffset < 0 then
      begin
        Result := Format('Error: Code at $%06X is below base address $%06X',
                        [MachCode.Address, BaseAddr]);
        Exit;
      end;

      // Place bytes in ROM image
      for j := 0 to High(Bytes) do
      begin
        if (ROMOffset + j) < Length(ROMImage) then
          ROMImage[ROMOffset + j] := Bytes[j];
      end;
    end;

    // 4b. ROM disk overlay (optional). The k/OS A: drive lives at absolute
    //     $FC0000..$FDFFFF on Digital — exactly 256 sectors × 512 B. If the
    //     user has specified a ROM-disk image file in Settings, validate it
    //     and overlay its bytes here. The image is a FAT16 disk produced
    //     under EMU; bytes go straight in, no byte-swapping (SplitHighLow
    //     below handles the high/low ROM split using the K16's natural
    //     little-endian word-pair format).
    if Trim(ROMDiskFile) <> '' then
    begin
      if not FileExists(ROMDiskFile) then
      begin
        Result := Format('Error: ROM disk file not found: "%s"', [ROMDiskFile]);
        Exit;
      end;

      ROMDiskBytes := LoadBinaryFile(ROMDiskFile);
      if Length(ROMDiskBytes) <> ROMDISK_SIZE then
      begin
        Result := Format('Error: ROM disk "%s" is %d bytes; expected %d (%d sectors of 512 bytes)',
                         [ROMDiskFile, Length(ROMDiskBytes), ROMDISK_SIZE, ROMDISK_SIZE div 512]);
        Exit;
      end;

      if ROMDISK_BASE_ABS < BaseAddr then
      begin
        Result := Format('Error: ROM disk base $%06X is below program base $%06X',
                         [ROMDISK_BASE_ABS, BaseAddr]);
        Exit;
      end;

      ROMDiskOffset  := Integer(ROMDISK_BASE_ABS - BaseAddr);
      ROMDiskSizeEnd := ROMDiskOffset + ROMDISK_SIZE;

      // Grow ROMImage if program code didn't extend to / past $FDFFFF.
      if ROMDiskSizeEnd > Length(ROMImage) then
      begin
        i := Length(ROMImage);
        SetLength(ROMImage, ROMDiskSizeEnd);
        FillChar(ROMImage[i], ROMDiskSizeEnd - i, 0);
        MaxAddr := BaseAddr + UInt32(ROMDiskSizeEnd);   // keep stats honest
      end;

      Move(ROMDiskBytes[0], ROMImage[ROMDiskOffset], ROMDISK_SIZE);
      ROMDiskUsed := True;
    end;

    // 5. Split into high/low byte arrays
    SplitHighLow(ROMImage, ROMHigh, ROMLow);

    // 6. Insert lookup tables at ROM start (already split into high/low)
    //    Lookups map to CPU $F00000-$FBFFFF = ROM $000000-$0BFFFF
    //    In split files: word $000000-$05FFFF = byte $000000-$05FFFF
    if (Length(LookupLow) > 0) and AddLookups then
    begin
      for i := 0 to High(LookupLow) do
      begin
        if i < Length(ROMLow) then
          ROMLow[i] := LookupLow[i];
        if i < Length(ROMHigh) then
          ROMHigh[i] := LookupHigh[i];
      end;
    end;

    // 7. Save ROM files with error checking
    try
      SaveAsDigitalRawV2(ActualPath + 'ProgramHIGH.hex', ROMHigh);
    except
      on E: Exception do
      begin
        Result := Format('Error saving ProgramHIGH.hex to "%s": %s', [ActualPath, E.Message]);
        Exit;
      end;
    end;

    try
      SaveAsDigitalRawV2(ActualPath + 'ProgramLOW.hex', ROMLow);
    except
      on E: Exception do
      begin
        Result := Format('Error saving ProgramLOW.hex to "%s": %s', [ActualPath, E.Message]);
        Exit;
      end;
    end;

    // Output statistics
    Result := sLineBreak +
              'Generate ROMs...' +
              sLineBreak +
              Format('Base address: $%06X', [BaseAddr]) +
              sLineBreak +
              Format('Program: %d words (%d bytes)', [(MaxAddr - MinAddr) div 2, MaxAddr - MinAddr]) +
              sLineBreak +
              Format('Program address range: $%06X to $%06X', [MinAddr, MaxAddr - 1]) +
              sLineBreak +
              Format('Code ROM offset: $%06X', [MinAddr - BaseAddr]) +
              sLineBreak +
              Format('Lookup tables: %d bytes at ROM start', [LookupBytes]) +
              sLineBreak +
              Format('ROM High: %d bytes (D8-D15)', [Length(ROMHigh)]) +
              sLineBreak +
              Format('ROM Low:  %d bytes (D0-D7)', [Length(ROMLow)]) +
              sLineBreak +
              Format('Output path: %s', [ActualPath]);

    if ROMDiskUsed then
      Result := Result + sLineBreak +
                Format('ROM disk: %s (%d sectors) at $%06X',
                       [ExtractFileName(ROMDiskFile), ROMDISK_SIZE div 512, ROMDISK_BASE_ABS])
    else
      Result := Result + sLineBreak +
                'Warning: No ROM disk file specified — A: will be unmounted on Digital';

  except
    on E: Exception do
      Result := 'ROM generation error: ' + E.Message;
  end;
end;

procedure SaveAsDigitalRawV2(const FileName: string; const Data: TArray<Byte>);
var
  Lines: TStringList;
  I, Count, RunLength, J: Integer;
  Current: Byte;
  Dir: string;
begin
  // Validate directory exists
  Dir := ExtractFilePath(FileName);
  if (Dir <> '') and not DirectoryExists(Dir) then
    raise Exception.CreateFmt('Output directory not found: "%s"', [Dir]);

  Lines := TStringList.Create;
  try
    Lines.Add('v2.0 raw');

    Count := Length(Data);
    I := 0;

    while I < Count do
    begin
      Current := Data[I];
      RunLength := 1;

      while (RunLength < 255)
        and (I + RunLength < Count)
        and (Data[I + RunLength] = Current) do
        Inc(RunLength);

      if RunLength >= 4 then
        Lines.Add(Format('%d*0x%2.2X', [RunLength, Current]))
      else
        for J := 0 to RunLength - 1 do
          Lines.Add(Format('0x%2.2X', [Current]));

      Inc(I, RunLength);
    end;

    try
      Lines.SaveToFile(FileName);
    except
      on E: Exception do
        raise Exception.CreateFmt('Cannot create file "%s": %s', [FileName, E.Message]);
    end;
  finally
    Lines.Free;
  end;
end;

procedure SaveAsBinaryFile(const FileName: string; const Data: TArray<Byte>);
var
  FS: TFileStream;
  Dir: string;
begin
  // Validate directory exists
  Dir := ExtractFilePath(FileName);
  if (Dir <> '') and not DirectoryExists(Dir) then
    raise Exception.CreateFmt('Output directory not found: "%s"', [Dir]);

  try
    FS := TFileStream.Create(FileName, fmCreate);
  except
    on E: Exception do
      raise Exception.CreateFmt('Cannot create file "%s": %s', [FileName, E.Message]);
  end;

  try
    if Length(Data) > 0 then
      FS.WriteBuffer(Data[0], Length(Data));
  finally
    FS.Free;
  end;
end;

function GenerateBin(Ass: TK16Assembler; const FileName: string): string;
{ Exports a flat little-endian binary image suitable for the K16 emulator.
  File byte 0 corresponds to the lowest assembled address (MinAddr).
  .BASE is intentionally ignored — the emulator loads at the assembled address.
  Emulator usage: MemLoadBin(FileName, MinAddr) }
var
  i, j      : Integer;
  MachCode  : TMachineCode;
  Bytes     : TArray<Byte>;
  BinImage  : TArray<Byte>;
  MinAddr   : UInt32;
  MaxAddr   : UInt32;
  ROMOffset : Integer;
begin
  if Ass = nil then
  begin
    Result := 'Error: assembler reference is nil (assembly not completed?)';
    Exit;
  end;

  MinAddr := $FFFFFF;
  MaxAddr := 0;

  { Find the address range of all assembled code/data }
  for i := 0 to Ass.MachineCode.Count - 1 do
  begin
    MachCode := Ass.MachineCode[i];
    Bytes    := MachCode.GetBytes;
    if MachCode.Address < MinAddr then
      MinAddr := MachCode.Address;
    if MachCode.Address + UInt32(Length(Bytes)) > MaxAddr then
      MaxAddr := MachCode.Address + UInt32(Length(Bytes));
  end;

  if MinAddr > MaxAddr then
  begin
    Result := 'Error: no assembled code to export';
    Exit;
  end;

  { Ensure even size (K16 is word-aligned) }
  if (MaxAddr - MinAddr) mod 2 <> 0 then
    Inc(MaxAddr);

  { Build flat image — file offset 0 = MinAddr }
  SetLength(BinImage, MaxAddr - MinAddr);
  FillChar(BinImage[0], Length(BinImage), 0);

  for i := 0 to Ass.MachineCode.Count - 1 do
  begin
    MachCode  := Ass.MachineCode[i];
    Bytes     := MachCode.GetBytes;
    ROMOffset := Integer(MachCode.Address) - Integer(MinAddr);
    for j := 0 to High(Bytes) do
      if (ROMOffset + j) < Length(BinImage) then
        BinImage[ROMOffset + j] := Bytes[j];
  end;

  try
    SaveAsBinaryFile(FileName, BinImage);
  except
    on E: Exception do
    begin
      Result := 'Error saving .bin: ' + E.Message;
      Exit;
    end;
  end;

  Result := Format('Saved %d bytes, load at $%06X', [Length(BinImage), MinAddr]);
end;

function GenerateCom(Ass: TK16Assembler; const FileName: string): string;
{ Exports a k/OS .COM executable. Identical to GenerateBin but validates
  that the source assembled starting at $0200 — the convention enforced
  by the k/OS sys_exec loader, which copies the file's bytes verbatim
  to <new_task_page>:$0200.

  A .COM source should typically look like:
    .ORG    $0200
            ; (program code from here on)

  Output file format: raw little-endian binary. Byte 0 of the file
  corresponds to memory address $0200 in the target task page.

  If the source's MinAddr is not exactly $0200, an error is returned
  rather than producing a silently-wrong .com (e.g. if the user forgot
  .ORG $0200, the bin would contain hundreds of leading zero bytes
  and the entry point would be misaligned). }
const
  COM_LOAD_ADDR = $0200;
var
  i          : Integer;
  MachCode   : TMachineCode;
  Bytes      : TArray<Byte>;
  MinAddr    : UInt32;
begin
  if Ass = nil then
  begin
    Result := 'Error: assembler reference is nil (assembly not completed?)';
    Exit;
  end;

  { Quick scan for MinAddr only — we don't need the full range here,
    GenerateBin will redo the work. We just want to validate the
    starting address before doing anything. }
  MinAddr := $FFFFFF;
  for i := 0 to Ass.MachineCode.Count - 1 do
  begin
    MachCode := Ass.MachineCode[i];
    Bytes    := MachCode.GetBytes;
    if MachCode.Address < MinAddr then
      MinAddr := MachCode.Address;
  end;

  if MinAddr = $FFFFFF then
  begin
    Result := 'Error: no assembled code to export';
    Exit;
  end;

  if MinAddr <> COM_LOAD_ADDR then
  begin
    Result := Format(
      'Error: .COM source must start at $%4.4X (got $%6.6X)' + sLineBreak +
      'Add "    .ORG    $%4.4X" before the program code.',
      [COM_LOAD_ADDR, MinAddr, COM_LOAD_ADDR]);
    Exit;
  end;

  { Delegate to GenerateBin — same flat-image semantics. }
  Result := GenerateBin(Ass, FileName);

  { Reword the success message for clarity. }
  if not Result.StartsWith('Error') then
    Result := Format(
      'Generate .COM...' + sLineBreak +
      '%s' + sLineBreak +
      'Loads to <new_task_page>:$%4.4X via k/OS sys_exec.',
      [Result, COM_LOAD_ADDR]);
end;

function GenerateIntelHex(Ass: TK16Assembler; const FileName: string): string;
{ Exports assembled code as Intel HEX (I32HEX with extended linear address records).
  Each assembled region is written at its exact assembled address.
  The emulator reads the address from the file — no hardcoded load address. }
var
  i, j      : Integer;
  MachCode  : TMachineCode;
  Bytes     : TArray<Byte>;
  BinImage  : TArray<Byte>;
  MinAddr   : UInt32;
  MaxAddr   : UInt32;
  ROMOffset : Integer;
begin
  if Ass = nil then
  begin
    Result := 'Error: assembler reference is nil (assembly not completed?)';
    Exit;
  end;

  MinAddr := $FFFFFF;
  MaxAddr := 0;

  for i := 0 to Ass.MachineCode.Count - 1 do
  begin
    MachCode := Ass.MachineCode[i];
    Bytes    := MachCode.GetBytes;
    if MachCode.Address < MinAddr then MinAddr := MachCode.Address;
    if MachCode.Address + UInt32(Length(Bytes)) > MaxAddr then
      MaxAddr := MachCode.Address + UInt32(Length(Bytes));
  end;

  if MinAddr > MaxAddr then
  begin
    Result := 'Error: no assembled code to export';
    Exit;
  end;

  if (MaxAddr - MinAddr) mod 2 <> 0 then Inc(MaxAddr);

  SetLength(BinImage, MaxAddr - MinAddr);
  FillChar(BinImage[0], Length(BinImage), 0);

  for i := 0 to Ass.MachineCode.Count - 1 do
  begin
    MachCode  := Ass.MachineCode[i];
    Bytes     := MachCode.GetBytes;
    ROMOffset := Integer(MachCode.Address) - Integer(MinAddr);
    for j := 0 to High(Bytes) do
      if (ROMOffset + j) < Length(BinImage) then
        BinImage[ROMOffset + j] := Bytes[j];
  end;

  { GetBytes already returns little-endian; no post-swap needed.
    (Prior versions big-endian-stored and swapped here, which corrupted
    .BYTE data at odd starting addresses — the swap ran in 2-byte chunks
    starting from image offset 0 and didn't account for overlap between
    records at adjacent odd/even addresses.) }

  try
    SaveAsIntelHex(FileName, BinImage, MinAddr);
  except
    on E: Exception do
    begin
      Result := 'Error saving .hex: ' + E.Message;
      Exit;
    end;
  end;

  Result := sLineBreak +
            'Generate Hex...' +
            sLineBreak +
            Filename +
            sLineBreak +
            Format('Saved %d bytes at $%06X as Intel HEX', [Length(BinImage), MinAddr]);
end;

procedure SaveAsIntelHex(const FileName: string; const Data: TArray<Byte>; BaseAddr: LongWord);
{ Intel HEX I32HEX format:
    :LLAAAATT[DD...]CC
    LL   = byte count
    AAAA = address (low 16 bits)
    TT   = record type
    DD   = data bytes
    CC   = two's complement checksum of LL+AAAA+TT+DD
  Record types used:
    00 = data
    01 = end-of-file
    04 = extended linear address (upper 16 bits of 32-bit address)
  K16 uses 24-bit addresses — we emit type 04 whenever the upper word changes. }
const
  BYTES_PER_RECORD = 16;
var
  Lines       : TStringList;
  i, n        : Integer;
  Offset      : LongWord;
  RecAddr     : Word;
  ExtAddr     : Word;
  LastExtAddr : Word;
  Count       : Integer;
  Checksum    : Byte;
  RecLine     : string;
  b           : Byte;

  procedure EmitExtLinear(Upper: Word);
  var s: string; ck: Byte;
  begin
    { :02 0000 04 UUUU CC }
    ck := Byte(-(2 + 0 + 0 + 4 + Hi(Upper) + Lo(Upper)));
    s  := Format(':02000004%4.4X%2.2X', [Upper, ck]);
    Lines.Add(s);
  end;

begin
  Lines := TStringList.Create;
  try
    LastExtAddr := $FFFF;   { force emit on first record }

    i := 0;
    while i < Length(Data) do
    begin
      Offset  := BaseAddr + LongWord(i);
      ExtAddr := Word(Offset shr 16);

      { Emit extended linear address record if upper word changed }
      if ExtAddr <> LastExtAddr then
      begin
        EmitExtLinear(ExtAddr);
        LastExtAddr := ExtAddr;
      end;

      { How many bytes in this data record? }
      Count   := Length(Data) - i;
      if Count > BYTES_PER_RECORD then Count := BYTES_PER_RECORD;

      { Don't cross a 64KB boundary in one record }
      RecAddr := Word(Offset and $FFFF);
      if LongWord(RecAddr) + LongWord(Count) > $10000 then
        Count := Integer($10000 - LongWord(RecAddr));

      { Build record }
      Checksum := Byte(Count) + Hi(RecAddr) + Lo(RecAddr);  { LL + AAAA }
      { type 00 = 0, doesn't affect checksum }
      RecLine := Format(':%2.2X%4.4X00', [Count, RecAddr]);

      for n := 0 to Count - 1 do
      begin
        b        := Data[i + n];
        Checksum := Checksum + b;
        RecLine  := RecLine + Format('%2.2X', [b]);
      end;

      Checksum := Byte(-Integer(Checksum));   { two's complement }
      RecLine  := RecLine + Format('%2.2X', [Checksum]);
      Lines.Add(RecLine);

      Inc(i, Count);
    end;

    { End-of-file record }
    Lines.Add(':00000001FF');

    Lines.SaveToFile(FileName);
  finally
    Lines.Free;
  end;
end;

function LoadIntelHex(const FileName: string; out LoadAddr: LongWord): TArray<Byte>;
{ Loads an Intel HEX file into a byte array.
  LoadAddr is set to the lowest address found in the file.
  Returns a contiguous byte array from LoadAddr to the highest address.
  Gaps between records are zero-filled. }
var
  Lines     : TStringList;
  Line      : string;
  RecType   : Byte;
  ByteCount : Integer;
  RecAddr   : LongWord;
  ExtLinear : LongWord;
  FullAddr  : LongWord;
  MinAddr   : LongWord;
  MaxAddr   : LongWord;
  DataBytes : array of Byte;
  i, n      : Integer;
  b         : Byte;

  function HexByte(const s: string; pos: Integer): Byte;
  begin
    Result := StrToInt('$' + Copy(s, pos, 2));
  end;

begin
  Result    := nil;
  LoadAddr  := 0;
  MinAddr   := $FFFFFF;
  MaxAddr   := 0;
  ExtLinear := 0;

  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(FileName);

    { First pass: find address range }
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
            FullAddr := ExtLinear or RecAddr;
            if FullAddr < MinAddr then MinAddr := FullAddr;
            if FullAddr + LongWord(ByteCount) > MaxAddr then
              MaxAddr := FullAddr + LongWord(ByteCount);
          end;
        $01: Break;   { end of file }
      end;
    end;

    if MinAddr > MaxAddr then Exit;   { empty file }

    LoadAddr := MinAddr;
    SetLength(Result, MaxAddr - MinAddr);
    FillChar(Result[0], Length(Result), 0);

    { Second pass: load data }
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
            FullAddr := ExtLinear or RecAddr;
            for n := 0 to ByteCount - 1 do
            begin
              b := HexByte(Line, 10 + n * 2);
              Result[FullAddr - MinAddr + LongWord(n)] := b;
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
