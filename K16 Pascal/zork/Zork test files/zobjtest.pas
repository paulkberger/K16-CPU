program ZObjTest;
{$PAGES 3}
{$HEAP 0}
{$I files.pas}
{$I console.pas}
{$I memory.pas}
{$I zmem.pas}
{$I ztext.pas}
{$I zobj.pas}
var
  Args, S: String;
  n, cnt: Word;
begin
  InitFiles;
  GetArgs(Args);
  if not ZMemInit(Args) then
  begin
    Write('zobjtest: '); ZErrMsg(ZErr); WriteLn;
    Halt(1);
  end;
  cnt := ZObjCount;
  Write('objects: '); WriteLn(cnt);
  WriteLn;
  for n := 1 to cnt do
  begin
    ZObjName(n, S);
    Write(n); Write('. '); Write(S);
    Write('  [p='); Write(ZObjParent(n));
    Write(' s='); Write(ZObjSibling(n));
    Write(' c='); Write(ZObjChild(n));
    WriteLn(']');
  end;
end.
