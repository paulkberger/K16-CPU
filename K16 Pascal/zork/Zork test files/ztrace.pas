program ZTrace;

(* ---------------------------------------------------------------------------
   ztrace.pas -- run a story with an instruction trace            K16 Pascal, Part 26

       K> zork zork1
       K> zork zork1.z3

   Everything below the surface is the five modules: zmem (residency and
   addressing), ztext (Z-string decode, encode and the word-wrap sink), zobj
   (the object tree), zdict (dictionary and tokeniser), zdis (instruction
   decode) and zexec (execution).

   The checksum is verified before anything runs. It is the only check that
   reads every byte of the story, and a story that loaded wrongly produces
   an interpreter fault hundreds of instructions later with nothing pointing
   at the load -- which is exactly the afternoon Part 26 spent on a wrapped
   file position. One second here is cheap.

   Save and restore are not implemented in this part; both branch false, so
   the game reports the failure in its own words rather than crashing.
   --------------------------------------------------------------------------- *)

{$PAGES 4}
{$HEAP 0}

{$I files.pas}
{$I console.pas}
{$I memory.pas}
{$I zmem.pas}
{$I ztext.pas}
{$I zobj.pas}
{$I zdict.pas}
{$I zdis.pas}
{$I zexec.pas}

var
  Args: String;

function HasExt(var S: String): Boolean;
var
  i: Integer;
begin
  HasExt := False;
  for i := Length(S) downto 1 do
  begin
    if (S[i] = '\') or (S[i] = ':') then Exit;
    if S[i] = '.' then
    begin
      HasExt := True;
      Exit;
    end;
  end;
end;

begin
  InitFiles;
  ZTrace := False;
  GetArgs(Args);

  if Length(Args) = 0 then
  begin
    WriteLn('usage: zork <story.z3>');
    Halt(1);
  end;

  if not HasExt(Args) then Args := Args + '.Z3';

  if not ZMemInit(Args) then
  begin
    Write('zork: ');
    ZErrMsg(ZErr);
    WriteLn;
    Halt(1);
  end;

  Write('Verifying...');
  if not ZVerify then
  begin
    WriteLn(' FAILED');
    WriteLn('zork: the story file is damaged; refusing to run it.');
    Halt(1);
  end;
  WriteLn(' ok');
  WriteLn;

  ZExecInit;
  ZTraceMax := 200;        (* Zork I reaches its first sread in 407
                              instructions; 200 covers the whole banner. *)
  ZRun;

  if ZFault then Halt(1);
end.
