{
  K16_Export.pas — K16 ROM Image Generator

  Builds split high/low byte ROM images from assembled machine code,
  optionally patching in pre-generated lookup tables. Output is in
  Digital v2.0 raw format for direct use with the Digital circuit simulator.

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

function  GenerateROMs(Ass: TK16Assembler; OutputPath: String; AddLookups: Boolean): string;

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
  // Source should contain pairs of bytes (16-bit words)
  // For big-endian: byte 0 = high byte, byte 1 = low byte

  if Length(Source) mod 2 <> 0 then
    raise Exception.Create('Source byte array length must be even for 16-bit word splitting');

  WordCount := Length(Source) div 2;
  SetLength(HighBytes, WordCount);
  SetLength(LowBytes, WordCount);
  for I := 0 to WordCount - 1 do
  begin
    // Big-endian: first byte is high, second byte is low
    HighBytes[I] := Source[I * 2];     // D8-D15 (high byte)
    LowBytes[I] := Source[I * 2 + 1];  // D0-D7 (low byte)
  end;
end;

function GenerateROMs(Ass: TK16Assembler; OutputPath: String; AddLookups: Boolean): string;
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
  ROMImage   := nil;
  ROMHigh    := nil;
  ROMLow     := nil;
  LookupLow  := nil;
  LookupHigh := nil;

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

end.
