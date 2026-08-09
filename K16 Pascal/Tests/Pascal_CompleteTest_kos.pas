program PasTest;

{ K16 Pascal Compiler - Complete Test Suite  (k/OS .COM build)
  ------------------------------------------------------------------
  Build:  k16pascal --kos "Pascal_CompleteTest_kos.pas"   ->  PASTEST.COM
  Run:    run PASTEST.COM        (from kosh)

  Self-contained: uses only write/writeln, which are magic builtins backed
  by k16_rtl_kos.asm. No files.pas / console.pas include needed, and no
  RegisterShell -- it runs as a plain foreground child so its output goes
  straight to the terminal.

  k/OS notes (differences from the bare-metal build):
    - Output is QUIET by default: only FAILs and a per-section tally print,
      so ~30 lines total instead of ~500. A failure can't scroll off the
      screen and the summary stays visible. Set VERBOSE = 1 for the old
      print-every-PASS behaviour.
    - Halt() is NOT used: it emits HALT #0, which stops the whole machine
      rather than exiting the task. The program ends via normal 'end.'.
    - Assert() is NOT used: the k/OS RTL has no __assert.

  Coverage added for Part 17 (see sections 28-30):
    28  string concat stress -- the regression gate for the concat fold
    29  SizeOf / High / Low / Val / FillChar
    30  Break / Continue / Exit

  Expected final line: 'All done. All tests passed.' }

{ ================================================================
  Types used across tests
  ================================================================ }

type
  TPoint = record
    x: Integer;
    y: Integer;
  end;

  TNode = record
    value: Integer;
    next:  Integer;   { would be ^TNode but pointer-to-record not needed here }
  end;

  TColor = (Red, Green, Blue, Yellow, Cyan);

  TByteArr  = array[0..7]  of Byte;
  TIntArr   = array[1..10] of Integer;
  TStrArr   = array[0..3]  of String;

  TFlags = set of 0..15;    { 16-element set for set tests }

{ ================================================================
  Global counters
  ================================================================ }

const
  { 1 = print a PASS line for every check (bare-metal style).
    0 = print only failures + a per-section tally (fits a k/OS screen). }
  VERBOSE = 0;

var
  pass, fail: Integer;
  section_pass, section_fail: Integer;

  { Section 31 scratch. A GLOBAL on purpose: the parameter-indexed store bug
    only appears when the INDEX is frame-addressed, and this compiler
    allocates var-section locals statically, so a local index would take the
    generic path and prove nothing. }
  PIS_A: array[0..63] of Integer;

procedure StartSection;
begin
  section_pass := 0;
  section_fail := 0;
end;

procedure EndSection;
begin
  write('    ');
  write(section_pass);
  write(' ok');
  if section_fail > 0 then
  begin
    write(', ');
    write(section_fail);
    write(' FAILED');
  end;
  writeln('');
end;

{ ================================================================
  Helpers: Check / CheckStr / CheckBool / CheckChar
  ================================================================ }

procedure Check(name: String; got, expected: Integer);
begin
  if got = expected then
  begin
    if VERBOSE = 1 then writeln('PASS: ' + name);
    Inc(pass);
    Inc(section_pass);
  end
  else
  begin
    write('FAIL: '); write(name);
    write(' got='); write(got);
    write(' exp='); writeln(expected);
    Inc(fail);
    Inc(section_fail);
  end;
end;

procedure CheckStr(name: String; got, expected: String);
begin
  if got = expected then
  begin
    if VERBOSE = 1 then writeln('PASS: ' + name);
    Inc(pass);
    Inc(section_pass);
  end
  else
  begin
    write('FAIL: '); write(name);
    write(' got=['); write(got);
    write('] exp=['); write(expected);
    writeln(']');
    Inc(fail);
    Inc(section_fail);
  end;
end;

procedure CheckBool(name: String; got, expected: Boolean);
begin
  if got = expected then
  begin
    if VERBOSE = 1 then writeln('PASS: ' + name);
    Inc(pass);
    Inc(section_pass);
  end
  else
  begin
    write('FAIL: '); write(name);
    if got then write(' got=TRUE') else write(' got=FALSE');
    if expected then writeln(' exp=TRUE') else writeln(' exp=FALSE');
    Inc(fail);
    Inc(section_fail);
  end;
end;

procedure CheckChar(name: String; got, expected: Char);
begin
  if got = expected then
  begin
    if VERBOSE = 1 then writeln('PASS: ' + name);
    Inc(pass);
    Inc(section_pass);
  end
  else
  begin
    write('FAIL: '); write(name);
    write(' got='); write(got);
    write(' exp='); writeln(expected);
    Inc(fail);
    Inc(section_fail);
  end;
end;

{ ================================================================
  Section 1 -- FOR loops
  ================================================================ }

procedure TestFor;
var
  i, j, sum, product: Integer;
begin
  writeln('--- 1: For loops ---');
  StartSection;

  sum := 0;
  for i := 1 to 10 do sum := sum + i;
  Check('for to 1..10', sum, 55);

  sum := 0;
  for i := 10 downto 1 do sum := sum + i;
  Check('for downto 10..1', sum, 55);

  sum := 99;
  for i := 5 to 1 do sum := 0;
  Check('for zero-iter', sum, 99);

  sum := 0;
  for i := 7 to 7 do sum := i;
  Check('for single-iter', sum, 7);

  product := 1;
  for i := 1 to 5 do product := product * i;
  Check('for factorial 5', product, 120);

  { nested for }
  sum := 0;
  for i := 1 to 4 do
  begin
    for j := 1 to i do sum := sum + 1;
  end;
  Check('for nested count', sum, 10);   { 1+2+3+4 }
  EndSection;
end;

{ ================================================================
  Section 2 -- WHILE
  ================================================================ }

procedure TestWhile;
var
  i, j, sum: Integer;
begin
  writeln('--- 2: While ---');
  StartSection;

  sum := 0; i := 1;
  while i <= 10 do begin sum := sum + i; Inc(i); end;
  Check('while 1..10', sum, 55);

  sum := 42; i := 99;
  while i < 5 do sum := 0;
  Check('while zero-iter', sum, 42);

  { nested while }
  sum := 0; i := 1;
  while i <= 3 do
  begin
    j := 1;
    while j <= i do begin sum := sum + 1; Inc(j); end;
    Inc(i);
  end;
  Check('while nested', sum, 6);
  EndSection;
end;

{ ================================================================
  Section 3 -- REPEAT..UNTIL
  ================================================================ }

procedure TestRepeat;
var
  i, sum: Integer;
begin
  writeln('--- 3: Repeat..Until ---');
  StartSection;

  sum := 0; i := 1;
  repeat sum := sum + i; Inc(i); until i > 5;
  Check('repeat sum', sum, 15);

  sum := 0;
  repeat sum := 1; until True;
  Check('repeat once', sum, 1);

  { repeat with compound condition }
  i := 10; sum := 0;
  repeat sum := sum + i; Dec(i); until (i < 7) or (sum > 25);
  Check('repeat compound', sum, 27);  { 10+9+8 = 27, then 7 makes i=7, i<7 false, sum=27>25 true }
  EndSection;
end;

{ ================================================================
  Section 4 -- CASE
  ================================================================ }

procedure TestCase;
var
  i, r: Integer;
  c: TColor;
begin
  writeln('--- 4: Case ---');
  StartSection;

  for i := 0 to 5 do
  begin
    r := -1;
    case i of
      0:    r := 100;
      1:    r := 200;
      2, 3: r := 300;
      4:    r := 400;
      else  r := 999;
    end;
    case i of
      0: Check('case 0',    r, 100);
      1: Check('case 1',    r, 200);
      2: Check('case 2',    r, 300);
      3: Check('case 3',    r, 300);
      4: Check('case 4',    r, 400);
      5: Check('case else', r, 999);
    end;
  end;

  { case on enum }
  c := Green;
  r := -1;
  case c of
    Red:    r := 1;
    Green:  r := 2;
    Blue:   r := 3;
    else    r := 0;
  end;
  Check('case enum', r, 2);
  EndSection;
end;

{ ================================================================
  Section 5 -- CHR / ORD  (Chr is now a magic function -- Phase 7 fix)
  ================================================================ }

procedure TestChrOrd;
var
  c: Char;
  i: Integer;
begin
  writeln('--- 5: Chr/Ord ---');
  StartSection;

  { Chr() -- previously broken, now registered as magic }
  c := Chr(65);
  CheckChar('Chr(65)', c, 'A');

  c := Chr(90);
  CheckChar('Chr(90)', c, 'Z');

  c := Chr(48);
  CheckChar('Chr(48)', c, '0');

  { Ord() }
  Check('Ord(A)', Ord('A'), 65);
  Check('Ord(Z)', Ord('Z'), 90);
  Check('Ord(0)', Ord('0'), 48);
  Check('Ord(space)', Ord(' '), 32);

  { round-trip }
  i := 72;
  c := Chr(i);
  Check('Chr/Ord roundtrip', Ord(c), 72);

  { Char() cast (pre-existing workaround) }
  c := Char(77);
  CheckChar('Char(77)', c, 'M');
  EndSection;
end;

{ ================================================================
  Section 6 -- INC / DEC
  ================================================================ }

procedure TestIncDec;
var
  i: Integer;
  b: Byte;
begin
  writeln('--- 6: Inc/Dec ---');
  StartSection;

  i := 0;
  Inc(i);         Check('inc 0->1',   i, 1);
  Inc(i);         Check('inc 1->2',   i, 2);
  Dec(i);         Check('dec 2->1',   i, 1);
  Dec(i);         Check('dec 1->0',   i, 0);
  Inc(i, 10);     Check('inc+10',     i, 10);
  Dec(i, 3);      Check('dec-3',      i, 7);
  Inc(i, 100);    Check('inc+100',    i, 107);
  Dec(i, 107);    Check('dec-107',    i, 0);

  b := 200;
  Inc(b);         Check('inc byte',   b, 201);
  Dec(b, 50);     Check('dec byte',   b, 151);
  EndSection;
end;

{ ================================================================
  Section 7 -- ARRAYS
  ================================================================ }

procedure TestArrays;
var
  a: TIntArr;
  b: TByteArr;
  i, sum, max: Integer;
begin
  writeln('--- 7: Arrays ---');
  StartSection;

  { integer array 1..10 }
  for i := 1 to 10 do a[i] := i * i;
  sum := 0;
  for i := 1 to 10 do sum := sum + a[i];
  Check('int array sum of squares', sum, 385);
  Check('a[7]', a[7], 49);

  { byte array }
  for i := 0 to 7 do b[i] := i * 3;
  sum := 0;
  for i := 0 to 7 do sum := sum + b[i];
  Check('byte array sum', sum, 84);   { 0+3+6+9+12+15+18+21 = 84 }
  Check('b[5]', b[5], 15);

  { find max in array }
  for i := 1 to 10 do a[i] := (i * 37) mod 100;
  max := a[1];
  for i := 2 to 10 do
    if a[i] > max then max := a[i];
  Check('array max', max, 96);   { (7*37)mod100=59, (9*37)mod100=33 -- check: values are
                                    37,74,11,48,85,22,59,96,33,70 -> max=96 at i=8 }

  { 2D simulation: flat array as 2x5 matrix }
  for i := 1 to 10 do a[i] := 0;
  a[1] := 1; a[2] := 2; a[6] := 5; a[7] := 6;   { "row 0": [1,2,0,0,0]  "row 1": [5,6,0,0,0] }
  Check('2d sim [0,0]', a[1], 1);
  Check('2d sim [1,1]', a[7], 6);
  EndSection;
end;

{ ================================================================
  Section 8 -- RECORDS
  ================================================================ }

procedure TestRecords;
var
  p1, p2: TPoint;
  n:      TNode;
begin
  writeln('--- 8: Records ---');
  StartSection;

  p1.x := 3; p1.y := 4;
  Check('rec.x',   p1.x, 3);
  Check('rec.y',   p1.y, 4);

  { record assignment }
  p2 := p1;
  p2.x := 99;
  Check('rec copy indep x', p2.x, 99);
  Check('rec orig unchanged', p1.x, 3);

  { nested-field arithmetic }
  p1.x := p1.x * 10 + p1.y;
  Check('rec field expr', p1.x, 34);

  { multi-field record }
  n.value := 42;
  n.next  := 1000;
  Check('rec multi value', n.value, 42);
  Check('rec multi next',  n.next,  1000);
  n.value := n.value + n.next;
  Check('rec cross-field', n.value, 1042);
  EndSection;
end;

{ ================================================================
  Section 9 -- STRING operations
  ================================================================ }

procedure TestStrings;
var
  s, t: String;
  i: Integer;
begin
  writeln('--- 9: Strings ---');
  StartSection;

  { assignment and equality }
  s := 'Hello';
  CheckStr('str assign', s, 'Hello');

  { concatenation }
  t := s + ', World!';
  CheckStr('str concat', t, 'Hello, World!');

  { length }
  Check('str length', Length(s), 5);
  Check('str length2', Length(''), 0);
  Check('str length3', Length('abc'), 3);

  { indexing read }
  s := 'ABCDE';
  Check('s[1]', Ord(s[1]), Ord('A'));
  Check('s[3]', Ord(s[3]), Ord('C'));
  Check('s[5]', Ord(s[5]), Ord('E'));

  { indexing write }
  s[3] := 'X';
  CheckStr('s[3]:=X', s, 'ABXDE');

  { copy }
  s := 'Hello World';
  t := Copy(s, 1, 5);
  CheckStr('copy 1,5', t, 'Hello');
  t := Copy(s, 7, 5);
  CheckStr('copy 7,5', t, 'World');

  { pos }
  s := 'Hello World';
  Check('pos World',  Pos('World', s), 7);
  Check('pos Hello',  Pos('Hello', s), 1);
  Check('pos absent', Pos('xyz', s),   0);

  { comparisons }
  CheckBool('str eq',  'abc' = 'abc',  True);
  CheckBool('str neq', 'abc' = 'xyz',  False);
  CheckBool('str lt',  'abc' < 'abd',  True);
  CheckBool('str gt',  'b'   > 'a',    True);

  { string + integer via Str }
  i := 42;
  Str(i, s);
  CheckStr('str(42)', s, '42');
  Str(-7, s);
  CheckStr('str(-7)', s, '-7');

  { multi-concat }
  s := 'a' + 'b' + 'c' + 'd';
  CheckStr('multi concat', s, 'abcd');
  EndSection;
end;

{ ================================================================
  Section 10 -- STRING INDEX on Char
  ================================================================ }

procedure TestStringIndex;
var
  s: String;
  c: Char;
begin
  writeln('--- 10: String index/Char ---');
  StartSection;

  s := 'Pascal';
  c := s[1]; CheckChar('s[1]', c, 'P');
  c := s[6]; CheckChar('s[6]', c, 'l');

  { write via Chr -- tests Chr in a non-trivial context }
  s[1] := Chr(Ord('p'));   { lowercase p }
  CheckStr('s[1]:=chr', s, 'pascal');
  EndSection;
end;

{ ================================================================
  Section 11 -- NESTED PROCEDURES (display array)
  ================================================================ }

procedure TestNested;
var
  outerA, outerB: Integer;

  procedure Inc1;
  begin
    outerA := outerA + 1;
  end;

  procedure AddToA(n: Integer);
  begin
    outerA := outerA + n;
  end;

  procedure Level1;
  var
    v1: Integer;

    procedure Level2;
    var
      v2: Integer;
    begin
      v2    := v1 * 2;
      outerB := outerB + v2;
    end;

    procedure Level2b;
    begin
      outerA := outerA + v1;
    end;

  begin
    v1 := 5;
    Level2;
    Level2b;
  end;

begin
  writeln('--- 11: Nested procedures ---');
  StartSection;

  outerA := 10;
  Inc1;
  Check('nested inc', outerA, 11);

  AddToA(7);
  Check('nested addto', outerA, 18);

  outerA := 0; outerB := 0;
  Level1;
  Check('nested L2 outerB', outerB, 10);   { v1=5, v2=10, outerB=0+10 }
  Check('nested L2b outerA', outerA, 5);   { outerA=0+v1=5 }
  EndSection;
end;

{ ================================================================
  Section 12 -- VAR PARAMETERS
  ================================================================ }

procedure Swap(var a, b: Integer);
var tmp: Integer;
begin
  tmp := a; a := b; b := tmp;
end;

procedure AddN(var x: Integer; n: Integer);
begin
  x := x + n;
end;

procedure StrAppend(var s: String; suffix: String);
begin
  s := s + suffix;
end;

procedure TestVarParams;
var
  x, y: Integer;
  s:    String;
begin
  writeln('--- 12: Var params ---');
  StartSection;

  x := 10; y := 20;
  Swap(x, y);
  Check('swap x', x, 20);
  Check('swap y', y, 10);

  AddN(x, 5);
  Check('addN', x, 25);

  { var string param }
  s := 'Hello';
  StrAppend(s, ' World');
  CheckStr('var str append', s, 'Hello World');

  { multiple swaps }
  x := 1; y := 2;
  Swap(x, y); Swap(x, y);
  Check('double swap x', x, 1);
  Check('double swap y', y, 2);
  EndSection;
end;

{ ================================================================
  Section 13 -- POINTERS / NEW / DISPOSE  (Phase 7 -- now fixed)
  ================================================================ }

type
  PInt = ^Integer;

var
  gp: PInt;   { global pointer - simpler addressing for New test }

procedure TestPointers;
var
  i: Integer;
begin
  writeln('--- 13: Pointers/New/Dispose ---');
  StartSection;

  { Use global pointer variable to avoid local frame-offset complications }
  New(gp);
  gp^ := 42;
  Check('new/deref', gp^, 42);

  gp^ := gp^ * 2;
  Check('ptr arith', gp^, 84);

  i := gp^;
  Check('ptr to local', i, 84);

  gp^ := 0;
  Check('ptr zero', gp^, 0);

  Dispose(gp);
  Check('dispose ok', 1, 1);
  EndSection;
end;

{ ================================================================
  Section 14 -- FUNCTIONS (integer + string return)
  ================================================================ }

function Square(n: Integer): Integer;
begin
  Square := n * n;
end;

function Cube(n: Integer): Integer;
begin
  Cube := n * n * n;
end;

function MaxOf(a, b: Integer): Integer;
begin
  if a > b then MaxOf := a else MaxOf := b;
end;

function MinOf(a, b: Integer): Integer;
begin
  if a < b then MinOf := a else MinOf := b;
end;

function Abs2(n: Integer): Integer;
begin
  if n < 0 then Abs2 := -n else Abs2 := n;
end;

function Repeat3(s: String): String;
begin
  Repeat3 := s + s + s;
end;

function Pad(s: String; width: Integer): String;
var
  i: Integer;
  result2: String;
begin
  result2 := s;
  i := Length(s);
  while i < width do
  begin
    result2 := result2 + ' ';
    Inc(i);
  end;
  Pad := result2;
end;

function Wrap(s: String): String;
begin
  Wrap := '[' + s + ']';
end;

procedure TestFunctions;
begin
  writeln('--- 14: Functions ---');
  StartSection;

  Check('square 0',  Square(0),  0);
  Check('square 5',  Square(5),  25);
  Check('square -3', Square(-3), 9);
  Check('cube 3',    Cube(3),    27);
  Check('maxof 3 8', MaxOf(3, 8), 8);
  Check('maxof 8 3', MaxOf(8, 3), 8);
  Check('minof 3 8', MinOf(3, 8), 3);
  Check('abs pos',   Abs2(5),    5);
  Check('abs neg',   Abs2(-7),   7);
  Check('abs zero',  Abs2(0),    0);

  CheckStr('repeat3 ab',  Repeat3('ab'),  'ababab');
  CheckStr('repeat3 x',   Repeat3('x'),   'xxx');
  CheckStr('repeat3 ""',  Repeat3(''),    '');
  CheckStr('pad hello 8', Pad('Hello', 8), 'Hello   ');
  CheckStr('wrap test',   Wrap('test'),    '[test]');
  EndSection;
end;

{ ================================================================
  Section 15 -- USER-DEFINED STRING FUNCS AS CALL ARGUMENTS
  (Phase 7 fix -- previously showed 'PASS: de' instead of 'PASS: repeat3')
  ================================================================ }

procedure TestStringFuncAsArg;
begin
  writeln('--- 15: String func as call arg (Phase 7) ---');
  StartSection;

  { The critical test: CheckStr receives Repeat3('ab') as its 'got' argument.
    Before Phase 7, the name 'repeat3' was corrupted by the 256-byte result
    buffer interleaving with the name arg words on CheckStr's stack. }
  CheckStr('repeat3 as arg', Repeat3('ab'), 'ababab');
  CheckStr('wrap as arg',    Wrap('hello'), '[hello]');
  CheckStr('pad as arg',     Pad('hi', 4),  'hi  ');

  { chained: func result as arg to another func }
  CheckStr('wrap(repeat3)',  Wrap(Repeat3('ab')), '[ababab]');
  CheckStr('repeat3(wrap)',  Repeat3(Wrap('x')),  '[x][x][x]');

  { func result in concat expression }
  CheckStr('func in concat', 'A' + Repeat3('b') + 'C', 'AbbbC');

  { multiple string func args in one call }
  CheckStr('two func args', Repeat3('a') + Repeat3('b'), 'aaabbb');
  EndSection;
end;

{ ================================================================
  Section 16 -- BOOLEAN LOGIC
  ================================================================ }

procedure TestBoolean;
var
  t, f, b: Boolean;
  i: Integer;
begin
  writeln('--- 16: Boolean ---');
  StartSection;

  t := True; f := False;

  CheckBool('true',        t,         True);
  CheckBool('false',       f,         False);
  CheckBool('and TT',      t and t,   True);
  CheckBool('and TF',      t and f,   False);
  CheckBool('and FF',      f and f,   False);
  CheckBool('or TF',       t or f,    True);
  CheckBool('or FF',       f or f,    False);
  CheckBool('not T',       not t,     False);
  CheckBool('not F',       not f,     True);
  CheckBool('xor TF',      t xor f,   True);
  CheckBool('xor TT',      t xor t,   False);

  { short-circuit AND: second operand must NOT be evaluated when first is false }
  i := 0;
  b := f and (i = 0);
  Check('short-circuit and no side effect', i, 0);

  { short-circuit OR: second operand must NOT be evaluated when first is true }
  i := 0;
  b := t or (i = 99);
  CheckBool('short-circuit or result', b, True);
  EndSection;
end;

{ ================================================================
  Section 17 -- RELATIONAL OPERATORS
  ================================================================ }

procedure TestRelOps;
begin
  writeln('--- 17: Relational ops ---');
  StartSection;

  CheckBool('int eq T',  3 = 3,    True);
  CheckBool('int eq F',  3 = 4,    False);
  CheckBool('int ne T',  3 <> 4,   True);
  CheckBool('int ne F',  3 <> 3,   False);
  CheckBool('int lt T',  3 < 4,    True);
  CheckBool('int lt F',  4 < 3,    False);
  CheckBool('int le T',  3 <= 3,   True);
  CheckBool('int le T2', 3 <= 4,   True);
  CheckBool('int le F',  4 <= 3,   False);
  CheckBool('int gt T',  4 > 3,    True);
  CheckBool('int gt F',  3 > 4,    False);
  CheckBool('int ge T',  3 >= 3,   True);
  CheckBool('int ge T2', 4 >= 3,   True);
  CheckBool('int ge F',  3 >= 4,   False);

  CheckBool('str eq T',  'abc' = 'abc',   True);
  CheckBool('str eq F',  'abc' = 'abd',   False);
  CheckBool('str ne T',  'abc' <> 'abd',  True);
  CheckBool('str lt T',  'abc' < 'abd',   True);
  CheckBool('str lt F',  'abd' < 'abc',   False);
  CheckBool('str gt T',  'z' > 'a',       True);
  CheckBool('str gt F',  'a' > 'z',       False);
  EndSection;
end;

{ ================================================================
  Section 18 -- INTEGER ARITHMETIC
  ================================================================ }

procedure TestArith;
begin
  writeln('--- 18: Integer arithmetic ---');
  StartSection;

  Check('add',     10 + 3,     13);
  Check('sub',     10 - 3,     7);
  Check('mul',     6 * 7,      42);
  Check('div',     17 div 3,   5);
  Check('mod',     17 mod 3,   2);
  Check('neg',     -(5),       -5);
  Check('neg neg', -(-7),      7);

  { operator precedence }
  Check('prec 1', 2 + 3 * 4,       14);
  Check('prec 2', (2 + 3) * 4,     20);
  Check('prec 3', 10 - 2 * 3,      4);
  Check('prec 4', 10 div 2 + 1,    6);
  Check('prec 5', 10 div (2 + 3),  2);

  { negative div/mod }
  Check('neg div', (-7) div 2, -3);
  Check('neg mod', (-7) mod 2, -1);

  { large-ish values (16-bit) }
  Check('large add', 30000 + 5000,  35000);
  Check('large sub', 40000 - 15000, 25000);
  Check('large mul', 200 * 300,     60000);
  EndSection;
end;

{ ================================================================
  Section 19 -- BITWISE OPERATIONS
  ================================================================ }

procedure TestBitwise;
begin
  writeln('--- 19: Bitwise ---');
  StartSection;

  Check('and',      $FF and $0F,   $0F);
  Check('or',       $F0 or $0F,    $FF);
  Check('xor',      $FF xor $F0,   $0F);
  Check('not mask', (not $FF00) and $FFFF, $00FF);

  { shift via lookup }
  Check('shl 1',    1 shl 3,   8);
  Check('shl 2',    $0001 shl 8, $0100);
  Check('shr 1',    $0100 shr 4, $0010);
  Check('shr 2',    $FFFF shr 1, $7FFF);

  { combined }
  Check('mask',     ($ABCD shr 8) and $FF, $AB);
  Check('set bit',  $0000 or (1 shl 5), 32);
  Check('clr bit',  $FFFF and (not (1 shl 5)), $FFDF);
  EndSection;
end;

{ ================================================================
  Section 20 -- NESTED FUNCTION + VAR PARAMS THROUGH NESTING
  ================================================================ }

procedure TestNestedVar;
var
  total: Integer;

  procedure AccN(var acc: Integer; n: Integer);
  begin
    acc := acc + n;
  end;

  procedure AccRange(var acc: Integer; lo, hi: Integer);
  var
    i: Integer;
  begin
    for i := lo to hi do AccN(acc, i);
  end;

begin
  writeln('--- 20: Nested var params ---');
  StartSection;

  total := 0;
  AccN(total, 5);
  AccN(total, 3);
  Check('nested var acc', total, 8);

  total := 0;
  AccRange(total, 1, 5);
  Check('nested var accRange 1-5', total, 15);

  total := 0;
  AccRange(total, 1, 10);
  Check('nested var accRange 1-10', total, 55);
  EndSection;
end;

{ ================================================================
  Section 21 -- RECURSION
  ================================================================ }

function Fib(n: Integer): Integer;
begin
  if n <= 1 then Fib := n
  else Fib := Fib(n - 1) + Fib(n - 2);
end;

function Factorial(n: Integer): Integer;
begin
  if n <= 1 then Factorial := 1
  else Factorial := n * Factorial(n - 1);
end;

function GCD(a, b: Integer): Integer;
begin
  if b = 0 then GCD := a
  else GCD := GCD(b, a mod b);
end;

procedure TestRecursion;
begin
  writeln('--- 21: Recursion ---');
  StartSection;

  Check('fib 0',  Fib(0),  0);
  Check('fib 1',  Fib(1),  1);
  Check('fib 5',  Fib(5),  5);
  Check('fib 8',  Fib(8),  21);
  Check('fib 10', Fib(10), 55);

  Check('fact 0',  Factorial(0),  1);
  Check('fact 1',  Factorial(1),  1);
  Check('fact 5',  Factorial(5),  120);
  Check('fact 7',  Factorial(7),  5040);

  Check('gcd 12 8',  GCD(12, 8),  4);
  Check('gcd 100 75', GCD(100, 75), 25);
  Check('gcd 7 5',   GCD(7, 5),   1);
  EndSection;
end;

{ ================================================================
  Section 22 -- ENUM TYPE
  ================================================================ }

procedure TestEnum;
var
  c: TColor;
  i: Integer;
begin
  writeln('--- 22: Enum ---');
  StartSection;

  c := Red;   Check('enum Red',    Ord(c), 0);
  c := Green; Check('enum Green',  Ord(c), 1);
  c := Blue;  Check('enum Blue',   Ord(c), 2);
  c := Yellow;Check('enum Yellow', Ord(c), 3);
  c := Cyan;  Check('enum Cyan',   Ord(c), 4);

  { enum in case }
  c := Blue;
  i := -1;
  case c of
    Red:    i := 10;
    Green:  i := 20;
    Blue:   i := 30;
    Yellow: i := 40;
    Cyan:   i := 50;
  end;
  Check('enum case', i, 30);

  { enum comparison }
  CheckBool('enum eq',  c = Blue,  True);
  CheckBool('enum neq', c = Green, False);
  CheckBool('enum lt',  Red < Blue, True);
  EndSection;
end;

{ ================================================================
  Section 23 -- STRING ARRAY
  ================================================================ }

procedure TestStringArray;
var
  a: TStrArr;
  i: Integer;
  s: String;
begin
  writeln('--- 23: String array ---');
  StartSection;

  a[0] := 'zero';
  a[1] := 'one';
  a[2] := 'two';
  a[3] := 'three';

  CheckStr('sa[0]', a[0], 'zero');
  CheckStr('sa[2]', a[2], 'two');

  { modify via index }
  a[1] := 'ONE';
  CheckStr('sa[1] modified', a[1], 'ONE');

  { concat from array }
  s := a[0] + '-' + a[2];
  CheckStr('sa concat', s, 'zero-two');

  { loop over array }
  s := '';
  for i := 0 to 3 do
  begin
    if i > 0 then s := s + ',';
    s := s + a[i];
  end;
  CheckStr('sa loop', s, 'zero,ONE,two,three');
  EndSection;
end;

{ ================================================================
  Section 24 -- COMPLEX STRING EXPRESSIONS
  ================================================================ }

function IntToHex2(n: Integer): String;
var
  hi, lo: Integer;
  s: String;
  digits: String;
begin
  digits := '0123456789ABCDEF';
  hi := (n shr 4) and $0F;
  lo := n and $0F;
  s := Copy(digits, hi + 1, 1) + Copy(digits, lo + 1, 1);
  IntToHex2 := s;
end;

procedure TestComplexStr;
begin
  writeln('--- 24: Complex string expressions ---');
  StartSection;

  CheckStr('hex 0',    IntToHex2(0),    '00');
  CheckStr('hex 255',  IntToHex2(255),  'FF');
  CheckStr('hex 171',  IntToHex2(171),  'AB');
  CheckStr('hex 16',   IntToHex2(16),   '10');

  { nested calls as args: IntToHex2 result as CheckStr arg }
  CheckStr('hex as arg',  IntToHex2(255), 'FF');

  { string building }
  CheckStr('build hex', '$' + IntToHex2(171), '$AB');
  EndSection;
end;

{ ================================================================
  Section 25 -- MAGIC BUILTINS
  Tests Odd, Even, Succ, Pred, Length, Abs, Assigned (inline magic)
  ================================================================ }

procedure TestMagic;
var
  i, n: Integer;
  b: Boolean;
  c: Char;
  s: String;
  p: ^Integer;
begin
  writeln('--- 25: Magic builtins ---');
  StartSection;

  { Odd }
  Check('Odd(1)',  Ord(Odd(1)),  1);
  Check('Odd(2)',  Ord(Odd(2)),  0);
  Check('Odd(0)',  Ord(Odd(0)),  0);
  Check('Odd(99)', Ord(Odd(99)), 1);
  Check('Odd(-3)', Ord(Odd(-3)), 1);
  Check('Odd(-4)', Ord(Odd(-4)), 0);

  { Even }
  Check('Even(2)',  Ord(Even(2)),  1);
  Check('Even(3)',  Ord(Even(3)),  0);
  Check('Even(0)',  Ord(Even(0)),  1);
  Check('Even(100)',Ord(Even(100)),1);

  { Succ }
  Check('Succ(0)',   Succ(0),   1);
  Check('Succ(41)',  Succ(41),  42);
  Check('Succ(-1)',  Succ(-1),  0);
  Check('Succ(255)', Succ(255), 256);
  i := 10;
  Check('Succ(var)', Succ(i), 11);

  { Pred }
  Check('Pred(1)',   Pred(1),   0);
  Check('Pred(42)',  Pred(42),  41);
  Check('Pred(0)',   Pred(0),  -1);
  Check('Pred(256)', Pred(256), 255);
  i := 10;
  Check('Pred(var)', Pred(i), 9);

  { Succ/Pred chained }
  Check('Succ(Pred(5))', Succ(Pred(5)), 5);
  Check('Pred(Succ(5))', Pred(Succ(5)), 5);

  { Length -- now inline magic }
  s := 'Hello';
  Check('Length Hello',   Length(s),       5);
  Check('Length empty',   Length(''),      0);
  Check('Length abc',     Length('abc'),   3);
  Check('Length 1 char',  Length('X'),     1);
  s := '';
  Check('Length var empty', Length(s),     0);
  s := 'K16';
  Check('Length var K16',   Length(s),     3);

  { Length in expression }
  s := 'abcde';
  n := Length(s) * 2;
  Check('Length * 2',  n, 10);
  n := Length(s) + Length('fg');
  Check('Length + Length', n, 7);

  { Abs -- now inline }
  Check('Abs(0)',    Abs(0),    0);
  Check('Abs(5)',    Abs(5),    5);
  Check('Abs(-5)',   Abs(-5),   5);
  Check('Abs(1)',    Abs(1),    1);
  Check('Abs(-1)',   Abs(-1),   1);
  Check('Abs(100)',  Abs(100),  100);
  Check('Abs(-100)', Abs(-100), 100);
  i := -42;
  Check('Abs(var neg)', Abs(i), 42);
  i := 42;
  Check('Abs(var pos)', Abs(i), 42);
  i := 0;
  Check('Abs(var zero)', Abs(i), 0);
  { Abs in expression }
  Check('Abs(-3)+Abs(-4)', Abs(-3) + Abs(-4), 7);

  { Assigned -- new inline magic }
  p := nil;
  Check('Assigned(nil)',  Ord(Assigned(p)), 0);
  New(p);
  Check('Assigned(new)',  Ord(Assigned(p)), 1);
  p^ := 99;
  Check('Assigned deref', p^, 99);
  Dispose(p);
  p := nil;
  Check('Assigned(nil2)', Ord(Assigned(p)), 0);

  EndSection;
end;


{ ================================================================
  Section 26 -- WITH STATEMENT
  ================================================================ }

procedure TestWith;
var
  p: TPoint;
  n: TNode;
  sum: Integer;
begin
  writeln('--- 26: With statement ---');
  StartSection;

  { Basic with - read and write fields }
  p.x := 10;
  p.y := 20;
  with p do
  begin
    Check('with read x',  x, 10);
    Check('with read y',  y, 20);
    x := 99;
    y := 88;
  end;
  Check('with write x', p.x, 99);
  Check('with write y', p.y, 88);

  { With in expression }
  p.x := 3;
  p.y := 4;
  with p do
    sum := x * x + y * y;
  Check('with expr', sum, 25);

  { Nested field write }
  with p do
  begin
    x := 0;
    y := 0;
    x := x + 7;
  end;
  Check('with compound', p.x, 7);

  { With on second record type }
  n.value := 42;
  n.next  := 1;
  with n do
  begin
    Check('with node value', value, 42);
    Check('with node next',  next,  1);
    value := value * 2;
  end;
  Check('with node write', n.value, 84);

  EndSection;
end;

{ ================================================================
  Section 27 -- SETS
  ================================================================ }

procedure TestSets;
var
  a, b, c: TFlags;
begin
  writeln('--- 27: Sets ---');
  StartSection;

  { Empty set and membership }
  a := [];
  Check('empty not in',  Ord(1 in a), 0);

  { Single element }
  a := [3];
  Check('3 in [3]',      Ord(3 in a), 1);
  Check('2 not in [3]',  Ord(2 in a), 0);

  { Multiple elements }
  a := [1, 3, 5, 7];
  Check('1 in a',   Ord(1 in a), 1);
  Check('3 in a',   Ord(3 in a), 1);
  Check('5 in a',   Ord(5 in a), 1);
  Check('7 in a',   Ord(7 in a), 1);
  Check('2 not a',  Ord(2 in a), 0);
  Check('4 not a',  Ord(4 in a), 0);

  { Set union }
  a := [1, 2];
  b := [2, 3];
  c := a + b;
  Check('union 1',  Ord(1 in c), 1);
  Check('union 2',  Ord(2 in c), 1);
  Check('union 3',  Ord(3 in c), 1);
  Check('union 4',  Ord(4 in c), 0);

  { Set intersection }
  a := [1, 2, 3];
  b := [2, 3, 4];
  c := a * b;
  Check('inter 1',  Ord(1 in c), 0);
  Check('inter 2',  Ord(2 in c), 1);
  Check('inter 3',  Ord(3 in c), 1);
  Check('inter 4',  Ord(4 in c), 0);

  { Set difference }
  a := [1, 2, 3];
  b := [2];
  c := a - b;
  Check('diff 1',   Ord(1 in c), 1);
  Check('diff 2',   Ord(2 in c), 0);
  Check('diff 3',   Ord(3 in c), 1);

  { Set equality }
  a := [1, 2, 3];
  b := [1, 2, 3];
  Check('set eq T',  Ord(a = b), 1);
  b := [1, 2];
  Check('set eq F',  Ord(a = b), 0);
  Check('set neq T', Ord(a <> b), 1);

  { Include / Exclude }
  a := [1, 2, 3];
  Include(a, 4);
  Check('include 4',  Ord(4 in a), 1);
  Exclude(a, 2);
  Check('exclude 2',  Ord(2 in a), 0);
  Check('excl 1 ok',  Ord(1 in a), 1);

  EndSection;
end;


{ ================================================================
  Section 28 -- STRING CONCAT STRESS   (Part 17 regression gate)
  ----------------------------------------------------------------
  The concat rewrite replaced per-'+' temps with an append-into-one-
  destination fold. These cases are the ones that broke the old
  scheme: long chains, two live accumulators in a single procedure,
  in-place concat on either side, and function-call operands.
  ================================================================ }

procedure TestConcatStress;
var
  a, b, c, d: String;
  s, t: String;        { two accumulators live in ONE procedure }
  i: Integer;
begin
  writeln('--- 28: Concat stress ---');
  StartSection;

  a := 'AA';  b := 'BB';  c := 'CC';  d := 'DD';

  { long chain in a single statement }
  s := a + b + c + d + a + b + c + d;
  CheckStr('chain x8', s, 'AABBCCDDAABBCCDD');

  { literals and vars interleaved }
  s := '<' + a + '|' + b + '>';
  CheckStr('chain mixed', s, '<AA|BB>');

  { in-place, dest aliases the LEFT operand }
  s := 'x';
  s := s + 'y';
  s := s + 'z';
  CheckStr('inplace tail', s, 'xyz');

  { in-place, dest aliases the RIGHT operand }
  s := 'c';
  s := 'b' + s;
  s := 'a' + s;
  CheckStr('inplace head', s, 'abc');

  { in-place on both sides at once }
  s := 'M';
  s := '<' + s + '>';
  CheckStr('inplace both', s, '<M>');

  { self concat }
  s := 'ab';
  s := s + s;
  CheckStr('self concat', s, 'abab');

  { explicit grouping, both associations }
  s := a + (b + c);
  CheckStr('nested rhs', s, 'AABBCC');
  s := (a + b) + c;
  CheckStr('nested lhs', s, 'AABBCC');

  { function-call operands inside a chain }
  s := 'Hello World';
  t := Copy(s, 1, 5) + '-' + Copy(s, 7, 5);
  CheckStr('copy in chain', t, 'Hello-World');

  { TWO accumulators built in the same procedure, then joined.
    This is the exact shape that overflowed the task stack before
    the fold -- each chain used to stack its own 256-byte temps. }
  s := '';
  t := '';
  s := s + 'L1' + 'L2' + 'L3' + 'L4';
  t := t + 'R1' + 'R2' + 'R3' + 'R4';
  s := s + '|' + t;
  CheckStr('dual accum', s, 'L1L2L3L4|R1R2R3R4');

  { repeated in-place append in a loop }
  s := '';
  for i := 1 to 20 do s := s + 'abc';
  Check('loop concat len', Length(s), 60);
  CheckStr('loop concat head', Copy(s, 1, 6), 'abcabc');
  CheckStr('loop concat tail', Copy(s, 55, 6), 'abcabc');

  { Concat() builtin -- 2 args and 5 args }
  s := Concat(a, b);
  CheckStr('Concat 2', s, 'AABB');
  s := Concat(a, b, c, d, 'ZZ');
  CheckStr('Concat 5', s, 'AABBCCDDZZ');
  s := Concat('[', Copy('Hello', 1, 3), ']');
  CheckStr('Concat expr', s, '[Hel]');

  { 255-char clamp: 30 x 10 = 300 chars requested }
  s := '';
  for i := 1 to 30 do s := s + '0123456789';
  Check('clamp at 255', Length(s), 255);

  { empty operands }
  s := '' + a + '';
  CheckStr('empty operands', s, 'AA');
  s := '' + '' + '';
  Check('all empty', Length(s), 0);

  EndSection;
end;

{ ================================================================
  Section 29 -- SizeOf / High / Low / Val / FillChar
  Builtins the original suite never exercised.
  ================================================================ }

procedure TestMoreBuiltins;
var
  ba: TByteArr;
  n, code: Integer;
begin
  writeln('--- 29: SizeOf/High/Low/Val/FillChar ---');
  StartSection;

  { SizeOf on base types and composites }
  Check('SizeOf Integer',  SizeOf(Integer),  2);
  Check('SizeOf Char',     SizeOf(Char),     1);
  Check('SizeOf TPoint',   SizeOf(TPoint),   4);
  Check('SizeOf TByteArr', SizeOf(TByteArr), 8);
  Check('SizeOf TIntArr',  SizeOf(TIntArr),  20);

  { High/Low read the array's index range }
  Check('Low TIntArr',   Low(TIntArr),   1);
  Check('High TIntArr',  High(TIntArr),  10);
  Check('Low TByteArr',  Low(TByteArr),  0);
  Check('High TByteArr', High(TByteArr), 7);

  { Val: string -> integer, code = 0 or 1-based bad-char position }
  Val('123', n, code);
  Check('Val 123',       n,    123);
  Check('Val 123 code',  code, 0);
  Val('-45', n, code);
  Check('Val -45',       n,    -45);
  Check('Val -45 code',  code, 0);
  Val('12x', n, code);
  Check('Val bad code',  code, 3);

  { FillChar over a byte array }
  FillChar(ba, 8, 0);
  Check('FillChar 0 lo',  ba[0], 0);
  Check('FillChar 0 hi',  ba[7], 0);
  FillChar(ba, 8, 65);
  Check('FillChar 65 lo', ba[0], 65);
  Check('FillChar 65 hi', ba[7], 65);

  EndSection;
end;

{ ================================================================
  Section 30 -- BREAK / CONTINUE / EXIT
  ================================================================ }

function EarlyExit(n: Integer): Integer;
begin
  EarlyExit := 0;
  if n > 10 then
  begin
    EarlyExit := 99;
    Exit;
  end;
  EarlyExit := n * 2;
end;

procedure TestControlEscape;
var
  i, n: Integer;
begin
  writeln('--- 30: Break/Continue/Exit ---');
  StartSection;

  { Break out of a for loop }
  n := 0;
  for i := 1 to 10 do
  begin
    if i > 4 then Break;
    n := n + i;
  end;
  Check('break for', n, 10);

  { Continue skips the odd iterations }
  n := 0;
  for i := 1 to 6 do
  begin
    if Odd(i) then Continue;
    n := n + i;
  end;
  Check('continue for', n, 12);

  { Break out of a while loop (bounded, so a broken Break can't hang) }
  n := 0;
  i := 0;
  while i < 100 do
  begin
    i := i + 1;
    if i > 3 then Break;
    n := n + i;
  end;
  Check('break while', n, 6);
  Check('break while i', i, 4);

  { Exit returns early from a function }
  Check('exit early',  EarlyExit(20), 99);
  Check('exit normal', EarlyExit(5),  10);

  EndSection;
end;

{ ================================================================
  31: Parameter-indexed stores        (Part 26 regression)

  `A[v] := x' where v is a PARAMETER stored nothing -- or rather, it
  stored into v's own frame slot. EmitAddress set DestIsXY2 on the first
  frame access in the LHS, which for a subscripted destination is the
  INDEX, so EmitStore's [XY2+#N] fast path fired with the index's offset.
  The element address was computed correctly and discarded.

  Nothing in the suite caught it: every array store here indexes with a
  global or a var-section local, both of which are page-addressed and take
  the generic indirect path. Seven of nine shapes were broken and the
  whole suite still passed.

  The failure was silent in the worst way -- reads through the same
  parameter index were correct, so an array written through a setter kept
  returning its old contents with no fault and no wrong value.

  `store did not hit v' below is the direct assertion: before the fix, v
  came back holding the value that should have gone into the array.
  ================================================================ }

procedure PISSetConst(v: Integer);
begin
  PIS_A[v] := 1234;                  { param index, constant RHS }
end;

procedure PISSetParam(v, x: Integer);
begin
  PIS_A[v] := x;                     { param index AND param RHS }
end;

procedure PISSetLocal(v, x: Integer);
var
  idx: Integer;
begin
  idx := v;                          { the known-good form -- control }
  PIS_A[idx] := x;
end;

function PISGet(v: Integer): Integer;
begin
  PISGet := PIS_A[v];                { param index on the READ side }
end;

procedure PISBump(v: Integer);
begin
  PIS_A[v] := PIS_A[v] + 1;          { index on both sides }
end;

procedure PISSetExpr(v, x: Integer);
begin
  PIS_A[(v * 2) + 1] := x;           { compound index built from a param }
end;

procedure PISSetVarIdx(var v: Integer; x: Integer);
begin
  PIS_A[v] := x;                     { var-param index }
end;

{ Reports the index parameter back so the test can prove the store did not
  land in the parameter's frame slot. This is the assertion that names the
  bug rather than merely detecting its side effect. }
procedure PISSetAndReport(v, x: Integer; var seen: Integer);
begin
  PIS_A[v] := x;
  seen := v;
end;

procedure TestParamIndexStore;
var
  i, k: Integer;
begin
  writeln('--- 31: Parameter-indexed stores ---');
  StartSection;

  for i := 0 to 63 do PIS_A[i] := 0;

  PISSetConst(5);
  Check('param idx, const rhs', PIS_A[5], 1234);

  PISSetParam(6, 2002);
  Check('param idx, param rhs', PIS_A[6], 2002);

  PISSetLocal(7, 2003);
  Check('local idx (control)', PIS_A[7], 2003);

  PIS_A[8] := 41;
  Check('param idx on read', PISGet(8), 41);

  PIS_A[9] := 10;
  PISBump(9);
  Check('idx on both sides', PIS_A[9], 11);

  PISSetExpr(5, 2004);               { (5 * 2) + 1 = 11 }
  Check('compound param idx', PIS_A[11], 2004);

  k := 12;
  PISSetVarIdx(k, 2005);
  Check('var-param idx', PIS_A[12], 2005);
  Check('var-param intact', k, 12);

  { The one that names the bug: the value must reach the array, and the
    index parameter must still hold the index. Before the fix, seen came
    back as 2006 and PIS_A[13] stayed 0. }
  k := 0;
  PISSetAndReport(13, 2006, k);
  Check('store reached A[13]', PIS_A[13], 2006);
  Check('store did not hit v', k, 13);

  { Neighbours untouched -- a store landing at the wrong INDEX would pass
    every check above while corrupting something else. }
  Check('neighbour lo clean', PIS_A[4], 0);
  Check('neighbour hi clean', PIS_A[14], 0);

  EndSection;
end;


begin
  writeln('=== K16 Pascal Complete Test Suite (k/OS) ===');
  writeln('');
  pass := 0;
  fail := 0;

  TestFor;
  TestWhile;
  TestRepeat;
  TestCase;
  TestChrOrd;
  TestIncDec;
  TestArrays;
  TestRecords;
  TestStrings;
  TestStringIndex;
  TestNested;
  TestVarParams;
  TestPointers;
  TestFunctions;
  TestStringFuncAsArg;
  TestBoolean;
  TestRelOps;
  TestArith;
  TestBitwise;
  TestNestedVar;
  TestRecursion;
  TestEnum;
  TestStringArray;
  TestComplexStr;
  TestMagic;
  TestWith;
  TestSets;
  TestConcatStress;
  TestMoreBuiltins;
  TestControlEscape;
  TestParamIndexStore;

  writeln('');
  writeln('=== Summary ===');
  write('PASS: '); writeln(pass);
  write('FAIL: '); writeln(fail);
  if fail = 0 then
    writeln('All done. All tests passed.')
  else
  begin
    write('All done. FAILED: '); writeln(fail);
  end;
end.
