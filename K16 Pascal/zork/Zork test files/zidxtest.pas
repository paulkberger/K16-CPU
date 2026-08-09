program ZIdxTest;

(* ---------------------------------------------------------------------------
   zidxtest.pas -- narrow the array-index store bug     K16 Pascal, Part 26

   COMPILER BUG REPRO, not an interpreter test.

   zvartest.pas established that

       ZLocals[(ZFP * ZL_COUNT) + (v - 1)] := x

   stores nothing, while the identical expression READS correctly and

       idx := (ZFP * ZL_COUNT) + (v - 1);
       ZLocals[idx] := x;

   stores correctly. `base + i' also stores correctly, so the trigger is
   narrower than "any expression on the left of :=".

   Each case below writes through one index shape and reads back through a
   CONSTANT index, so only the store is under test -- a read that used the
   same expression could mask the fault by failing in the same direction.

   Every case targets element 32 and every case is preceded by clearing the
   whole neighbourhood, so a store that lands in the WRONG slot shows up as
   a stray as well as a miss. That matters: a write that silently goes
   somewhere else is far more dangerous than one that vanishes, and we do
   not yet know which this is.

       K> zidxtest

   No story file needed. Expected on a correct compiler: 0 failures.
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
  f, g  : Word;               (* stand-ins for ZFP and the variable number *)
  b     : Word;               (* stand-in for `base'                        *)
  i     : Word;
  fails : Word;
  stray : Word;
  S     : String;

procedure Clear;
var
  j: Word;
begin
  for j := 0 to ATOP do A[j] := 0;
end;

(* Read back through a CONSTANT index, and look for the value landing
   anywhere it should not. *)
procedure Check(var name: String; want: Word);
var
  j: Word;
begin
  stray := $FFFF;
  for j := 0 to ATOP do
    if (A[j] = want) and (j <> 32) then stray := j;

  Write('  ');
  Write(name);
  Write('  A[32] = ');
  Write(A[32]);
  if A[32] = want then Write('   ok')
  else
  begin
    Write('   *** FAIL');
    fails := fails + 1;
  end;
  if stray <> $FFFF then
  begin
    Write('   *** ALSO WROTE A[');
    Write(stray);
    Write(']');
  end;
  WriteLn;
end;

begin
  InitFiles;
  fails := 0;

  f := 2;                     (* f * K = 30 *)
  g := 3;                     (* g - 1 = 2  -> 30 + 2 = 32 *)
  b := 30;
  i := 2;

  WriteLn;
  WriteLn('Store through each index shape; read back at a constant index.');
  WriteLn('Target is always A[32].');
  WriteLn;

  Clear;  A[32] := 0;  A[32] := 0;
  Clear;  A[b + i] := 1001;
  S := '1  A[b + i]                ';  Check(S, 1001);

  Clear;  A[b - i] := 1002;            (* 30 - 2 = 28, deliberately NOT 32 *)
  Write('  2  A[b - i]                A[28] = ');  WriteLn(A[28]);

  Clear;  A[f * K] := 1003;            (* 30 *)
  Write('  3  A[f * K]               A[30] = ');  WriteLn(A[30]);

  Clear;  A[(f * K) + i] := 1004;
  S := '4  A[(f * K) + i]          ';  Check(S, 1004);

  Clear;  A[(f * K) + (g - 1)] := 1005;
  S := '5  A[(f * K) + (g - 1)]    ';  Check(S, 1005);

  Clear;  A[f * K + g - 1] := 1006;
  S := '6  A[f * K + g - 1]        ';  Check(S, 1006);

  Clear;  A[b + (g - 1)] := 1007;
  S := '7  A[b + (g - 1)]          ';  Check(S, 1007);

  Clear;  A[(b) + i] := 1008;
  S := '8  A[(b) + i]              ';  Check(S, 1008);

  Clear;  A[b + i + 0] := 1009;
  S := '9  A[b + i + 0]            ';  Check(S, 1009);

  Clear;  A[30 + 2] := 1010;
  S := '10 A[30 + 2]  (constants)  ';  Check(S, 1010);

  WriteLn;
  Write('failures: ');
  WriteLn(fails);
  WriteLn;
  WriteLn('Cases 2 and 3 have no expected value -- they are there to show');
  WriteLn('that a single operator alone does or does not survive.');
end.
