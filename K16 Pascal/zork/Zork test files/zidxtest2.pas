program ZIdxTest2;

(* ---------------------------------------------------------------------------
   zidxtest2.pas -- narrow the array-store bug, round 2   K16 Pascal, Part 26

   COMPILER BUG REPRO.

   Round 1 (zidxtest.pas) passed all ten index shapes -- including
   A[(f * K) + (g - 1)] := x -- so the compound index is NOT the trigger on
   its own. Every operand there was a program-level global.

   The failing case in zvartest.pas differed in one way: the index used a
   PROCEDURE PARAMETER.

       procedure T1Set(v, x: Word);
       begin
         ZLocals[(ZFP * ZL_COUNT) + (v - 1)] := x;    { stored nothing }
       end;

   Parameters arrive in D0/D1/D2 and are reached through the XY2 frame
   pointer, so the suspicion is a register clobber: the index is computed,
   then fetching the right-hand side reloads through XY2 and destroys it --
   or the multiply helper clobbers something the index calculation still
   needs. That predicts the fault depends on WHERE the parameter appears,
   not on the shape of the expression, and these cases separate those.

   Every case targets A[32]. Each scans the WHOLE array afterwards, because
   a store that lands in the wrong slot is far worse than one that vanishes
   and round 1 never checked for it.

       K> zidxtest2

   Expected on a correct compiler: 0 failures, no strays.
   --------------------------------------------------------------------------- *)

{$PAGES 1}
{$HEAP 0}

{$I files.pas}
{$I console.pas}

const
  K    = 15;
  ATOP = 63;

var
  A     : array[0..ATOP] of Word;
  f, g  : Word;
  b     : Word;
  fails : Word;
  S     : String;

procedure Clear;
var
  j: Word;
begin
  for j := 0 to ATOP do A[j] := 0;
end;

procedure Check(var name: String; want: Word);
var
  j, stray: Word;
begin
  stray := $FFFF;
  for j := 0 to ATOP do
    if (A[j] = want) and (j <> 32) then stray := j;

  Write('  ');
  Write(name);
  Write(' A[32] = ');
  Write(A[32]);
  if A[32] = want then Write('   ok')
  else
  begin
    Write('   *** FAIL');
    fails := fails + 1;
  end;
  if stray <> $FFFF then
  begin
    Write('   *** STRAY WRITE AT A[');
    Write(stray);
    Write(']');
  end;
  WriteLn;
end;

(* --- the parameter appears in the INDEX, right-hand side constant --- *)
procedure P1(v: Word);
begin
  A[(f * K) + (v - 1)] := 2001;
end;

(* --- parameter in the index AND as the right-hand side --- *)
procedure P2(v, x: Word);
begin
  A[(f * K) + (v - 1)] := x;
end;

(* --- index all globals, only the right-hand side is a parameter --- *)
procedure P3(x: Word);
begin
  A[(f * K) + (g - 1)] := x;
end;

(* --- parameter alone as the index --- *)
procedure P4(v: Word);
begin
  A[v] := 2004;
end;

(* --- parameter plus a global, no multiply --- *)
procedure P5(v: Word);
begin
  A[b + v] := 2005;
end;

(* --- parameter with one subtraction --- *)
procedure P6(v: Word);
begin
  A[v - 1] := 2006;
end;

(* --- the multiply itself uses the parameter --- *)
procedure P7(v: Word);
begin
  A[(v * K) + 2] := 2007;
end;

(* --- the zvartest T2 workaround: index into a local first --- *)
procedure P8(v, x: Word);
var
  idx: Word;
begin
  idx := (f * K) + (v - 1);
  A[idx] := x;
end;

(* --- same as P2 but as a FUNCTION, in case the shapes differ --- *)
function P9(v, x: Word): Word;
begin
  A[(f * K) + (v - 1)] := x;
  P9 := 0;
end;

var
  dmy: Word;

begin
  InitFiles;
  fails := 0;
  f := 2;                     (* f * K = 30 *)
  g := 3;
  b := 30;

  WriteLn;
  WriteLn('Round 1 passed every shape using globals only.');
  WriteLn('These differ only in where a PARAMETER appears.');
  WriteLn;

  Clear;  P1(3);
  S := '1 param in index, const rhs  ';  Check(S, 2001);

  Clear;  P2(3, 2002);
  S := '2 param in index, param rhs  ';  Check(S, 2002);

  Clear;  P3(2003);
  S := '3 global index, param rhs    ';  Check(S, 2003);

  Clear;  P4(32);
  S := '4 A[v]                       ';  Check(S, 2004);

  Clear;  P5(2);
  S := '5 A[b + v]                   ';  Check(S, 2005);

  Clear;  P6(33);
  S := '6 A[v - 1]                   ';  Check(S, 2006);

  Clear;  P7(2);
  S := '7 A[(v * K) + 2]             ';  Check(S, 2007);

  Clear;  P8(3, 2008);
  S := '8 index via local first      ';  Check(S, 2008);

  Clear;  dmy := P9(3, 2009);
  S := '9 same as 2, in a function   ';  Check(S, 2009);

  WriteLn;
  Write('failures: ');
  WriteLn(fails);
  WriteLn;
  WriteLn('Reading: 3 ok + 1,2 fail -> the parameter in the INDEX is the');
  WriteLn('trigger. 4,5,6 ok + 1,2,7 fail -> it needs the multiply too.');
  WriteLn('Any STRAY line means the store went somewhere it should not,');
  WriteLn('which is worse than losing it and needs fixing first.');
end.
