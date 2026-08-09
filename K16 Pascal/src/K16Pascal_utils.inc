(* -------------------------------------------------------------------------- *)
(* --- Utility Functions ---------------------------------------------------- *)
(* -------------------------------------------------------------------------- *)
(*                                                                            *)
(* String utilities: ReplaceChar, UpperStr, LowerStr, IsAlpha, IntToStr,     *)
(*   IntToHex, PadStr, TrimStr, StartsWith, EndsWith, EncodeReal             *)
(* Path utilities: NativeToPosix, PosixToNative, ParentDir, NameOnly,        *)
(*   ChangeExt, FAbsolute, FRelative, IsRelative, FSize, CopyFile,           *)
(*   ResolveLink, IsRetinaDisplay, GetHomeDir, GetUserDir                    *)
(* OS utilities: Execute, CleanDir, StrToFile                                *)
(*                                                                            *)
(* No dependencies.                                                           *)
(* -------------------------------------------------------------------------- *)

function ReplaceChar(S: String; C, D: Char): String;
var
  I: Integer;
begin
  for I := 1 to Length(S) do
    if S[I] = C then S[I] := D;

  ReplaceChar := S;
end;

(**
 * Converts the given string to upper case.
 *)
function UpperStr(S: String): String;
var
  I: Integer;
begin
  for I := 1 to Length(S) do S[I] := UpCase(S[I]);
  UpperStr := S;
end;

(**
 * Converts the given string to lower case.
 *)
function LowerStr(S: String): String;
var
  I: Integer;
begin
  for I := 1 to Length(S) do S[I] := LowerCase(S[I]);
  LowerStr := S;
end;

function IsAlpha(C: Char): Boolean;
begin
  if (C >= 'a') and (C <= 'z') then
    IsAlpha := True
  else if (C >= 'A') and (C <= 'Z') then
    IsAlpha := True
  else
    IsAlpha := False;
end;

(**
 * Converts the given integer to a string.
 *)
function IntToStr(I: Integer): String;
const
  N = 0;
var
  S: String;
begin
  Str(I, S);
  IntToStr := S;
end;

(**
 * Converts the given integer to a hex number of the given length.
 *)
function IntToHex(Value, Digits: Integer): String;
const
  Hex = '0123456789ABCDEF';
var
  S: String;
begin
  S := '';

  while (Value <> 0) or (Digits > 0) do
  begin
    S := Hex[1 + Value mod 16] + S;
    Value := Value div 16;
    Digits := Digits - 1;
  end;

  IntToHex := S;
end;

(**
 * Pads the string with spaces at the end, so it has at least the given number
 * of characters.
 *)
function PadStr(S: String; N: Integer): String;
const
  Spaces = '                ';
begin
  if Length(S) >= Abs(N) then
    PadStr := S
  else
  begin
    while Length(S) < N do
      S := S + Spaces;
    PadStr := Copy(S, 1, N);
  end
end;

(**
 * Trims the given string by removing all characters <= ' ' from left and right
 * sides.
 *)
function TrimStr(S: String): String;
var
  I, J: Integer;
begin
  I := 1;
  while ((I <= Length(S)) and (S[I] <= ' ')) do
    I := I + 1;
  J := Length(S) + 1;
  while ((J > I) and (S[J-1] <= ' ')) do
    J := J - 1;
  TrimStr := Copy(S, I, J - I);
end;

(**
 * Checks if the given string starts with the given substring.
 *)
function StartsWith(Str, SubStr: String): Boolean;
begin
  if Length(Str) < Length(SubStr) then
  begin
    StartsWith := False;
    Exit;
  end;

  SetLength(Str, Length(SubStr));
  StartsWith := Str = SubStr;
end;

(**
 * Checks if the given string starts with the given substring.
 *)
function EndsWith(Str, SubStr: String): Boolean;
begin
  if Length(Str) < Length(SubStr) then
  begin
    EndsWith := False;
    Exit;
  end;

  EndsWith := Copy(Str, Length(Str) - Length(SubStr) + 1, 255) = SubStr;
end;

(**
 * Encodes the given floating-point number (enclosed in a string) the way
 * the Real type needs it.
 *)
function EncodeReal(S: String): String;
var
  Number, Mantissa: Extended;
  Sign: Boolean;
  Exponent, I: Integer;
  Bytes: array[0..5] of Byte;
begin
  Val(S, Number);
  Sign := False;
  Mantissa := 0;
  Exponent := 0;

  if Number = 0 then
  begin
    Result := '$0000,$0000,$0000';
    Exit;
  end;

  if Number < 0 then
  begin
    Sign := True;
    Number := -Number;
  end;

  FRExp(Number, Mantissa, Exponent);

  Bytes[0] := Exponent + 128;

  for I := 5 downto 1 do
  begin
    Mantissa := Mantissa * 256;
    Bytes[I] := Trunc(Mantissa);
    Mantissa := Frac(Mantissa);
  end;

  if not Sign then Dec(Bytes[5], 128);

  // TODO: If the 11.th. hex digit is larger than 7 the
  // number should be rounded by adding 1 to BCDEH.

  EncodeReal := '0x' + IntToHex(Bytes[1], 2) + IntToHex(Bytes[0], 2) + ',' +
                '0x' + IntToHex(Bytes[3], 2) + IntToHex(Bytes[2], 2) + ',' +
                '0x' + IntToHex(Bytes[5], 2) + IntToHex(Bytes[4], 2);
end;

function NativeToPosix(Native: String): String;
begin
  {$ifdef windows}
  NativeToPosix := ReplaceChar(Native, '\', '/');
  {$else}
  NativeToPosix := Native;
  {$endif}
end;

function PosixToNative(Posix : string): string;
begin
  {$ifdef windows}
  PosixToNative := ReplaceChar(Posix, '/', '\');
  {$else}
  PosixToNative := Posix;
  {$endif}
end;

(**
 * Returns the parent directory of the given directory.
 *)
function ParentDir(DirName: String): String;
var
  I: Integer;
begin
  I := Length(DirName);
  while (I > 0) and (DirName[I] <> '/') do
    I := I - 1;

  ParentDir := Copy(DirName, 1, I - 1);
end;

(**
 * Returns the name part of a path only.
 *)
function NameOnly(Path: String): String;
var
  I: Integer;
begin
  I := Length(Path);
  while (I > 0) and (Path[I] <> '/') do
    I := I - 1;

  NameOnly := Copy(Path, I + 1, 255);
end;

(**
 * Changes the extension of the given filename to a new one (or appends it, if
 * there is no file extension at all. The new extension is supposed to start
 * with a dot.
 *)
function ChangeExt(FileName, NewExt: String): String;
var
  I: Integer;
begin
  I := Pos('.', FileName);
  if I = 0 then
    ChangeExt := FileName + NewExt
  else
    ChangeExt := Copy(FileName, 1, I - 1) + NewExt;
end;

(**
 *
 *)
function FAbsolute(Name: String): String;
begin
  FAbsolute := NativeToPosix(FExpand(Name));
end;

(**
 * Returns a given file name as a relative file name based on the current
 * directory if that it possible (i.e. if is contained in that directory).
 * Otherwise it stays unchanged.
 *)
function FRelative(Name: String): String;
var
  Dir: String;
begin
  Dir := FAbsolute('.') + '/';
  if Copy(Name, 1, Length(Dir)) = Dir then
    FRelative := Copy(Name, Length(Dir) + 1, 255)
  else
    FRelative := Name;
end;

function IsRelative(Path: String): Boolean;
begin
  IsRelative := False;

  if Length(Path) >= 1 then
  begin
    if Path[1] = '/' then Exit;

    if Length(Path) >= 2 then
    begin
      if IsAlpha(Path[1]) and (Path[2] = ':') then
      begin
        if (Length(Path) >= 3) and (Path[3] = '/') then Exit;
        WriteLn('Warning: "', Path, '" can lead to trouble.');
      end;
    end;
  end;

  IsRelative := True;
end;

(**
 * Returns the size of the given file, or -1 if the file does not exist.
 *)
function FSize(Name: String): Integer;
var
  F: File;
  SaveMode: Integer;
begin
  SaveMode := FileMode;
  FileMode := 0;

  {$I-}
  Assign(F, PosixToNative(Name));
  Reset(F, 1);
  if IOResult = 0 then
  begin
    FSize := FileSize(F);
    Close(F);
  end
  else FSize := -1;
  {$I+}

  FileMode := SaveMode;
end;

(**
 * Copies a file, returns Boolean reflecting success or failure.
 *)
function CopyFile(SrcName, DstName: String): Boolean;
var
  Src, Dst: File;
  Buffer: array[0..511] of Byte;
  Count: Integer;
begin
  {$I-}
  Assign(Dst, DstName);
  Rewrite(Dst, 1);

  Assign(Src, SrcName);
  Reset(Src, 1);

  BlockRead(Src, Buffer, 512, Count);

  while (IOResult = 0) and (Count <> 0) do
  begin
    BlockWrite(Dst, Buffer, Count);
    BlockRead(Src, Buffer, 512, Count);
  end;

  Close(Src);
  Close(Dst);
  {$I+}

  CopyFile := IOResult = 0;
end;

{$ifdef darwin}
function ResolveLink(const APath: string): string;
var
  Buf: array[0..255] of char;
  Len: Integer;
begin
  Len := fpReadLink(PChar(APath), Buf, SizeOf(Buf));
  if Len = -1 then
    Result := APath
  else
    SetString(Result, Buf, Len);
end;
{$endif}

function IsRetinaDisplay: Boolean;
{$ifdef darwin}
var
  S: String;
begin
  RunCommand('/bin/sh', ['-c', 'system_profiler SPDisplaysDataType | grep Retina'], S);
  IsRetinaDisplay := Length(TrimStr(S)) <> 0;
end;
{$else}
begin
  IsRetinaDisplay := False;
end;
{$endif}

(**
 * Returns the compiler's home directory (where it is installed).
 *)
function GetHomeDir: String;
begin
  {$ifdef darwin}
  Result := ParentDir(ParamStr(0));
  if Result = '' then
  begin
    RunCommand('which', [ParamStr(0)], Result);
    Result := ParentDir(ResolveLink(TrimStr(Result)));
  end
  else Result := FAbsolute(Result);
  {$else}
  Result := ParentDir(FAbsolute(NativeToPosix(ParamStr(0))));
  if Result = '' then Result := FAbsolute('.');
  {$endif}
end;

(**
 * Returns the user's home directory (where we expect the config).
 *)
function GetUserDir: String;
begin
  {$ifdef windows}
  Result := NativeToPosix(GetEnv('USERPROFILE'));
  {$else}
  Result := NativeToPosix(GetEnv('HOME'));
  {$endif}
end;

(**
 * Executes the given program with the given arguments.
 *)
procedure Execute(const Path, Args: String);
begin
  {$ifndef windows}
  if EndsWith(Path, '.exe') then
    Exec('/bin/sh', '-c "mono ' + Path + ' ' + Args + '"')
  {$ifdef darwin}
  else if EndsWith(Path, '.app') then
    Exec('/bin/sh', '-c "open -a ' + Path + ' --args ' + Args + '"')
  {$endif}
  else
    Exec('/bin/sh', '-c "' + Path + ' ' + Args + '"');
  {$else}
  Exec(Path, Args);
  {$endif}

  if DosError <> 0 then
  begin
    {$ifdef windows}
    WriteLn('The program "', PosixToNative(Path), '" cannot be executed.');
    {$endif}
    WriteLn('Is it installed? If so, please check your PATH and/or your ~/.k16pascal.cfg file.');
  end;
end;

procedure CleanDir(const Dir: String);
var
  S: String;
  R: SearchRec;
  F: File;
begin
  FindFirst(Dir + '/*', Archive, R);
  while DosError = 0 do
  begin
    Assign(F, Dir + '/' + R.Name);
    Erase(F);
    FindNext(R);
  end;

  FindClose(R);
end;

procedure StrToFile(const S, FileName: string);
var
  T: Text;
begin
  Assign(T, FileName);
  Rewrite(T);
  Write(T, S);
  Close(T);
end;

