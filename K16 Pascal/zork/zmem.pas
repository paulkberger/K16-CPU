{ ---------------------------------------------------------------------------
  zmem.pas -- Z-machine story image: residency, header, addressing
                                                      K16 Pascal, Part 25 / 27

  Include AFTER memory.pas and files.pas. No $L of its own -- every body here
  is Pascal; the assembler half is memory.asm's.

  Directive names appear bare in these comments on purpose. A braced directive
  written inside a braced comment ends that comment at the INNER brace, and the
  rest of the prose is then parsed as code -- Part 24 s5.5.

  ---- Why almost nothing here carries a page -------------------------------

  Every address in the v3 header is a 16-bit BYTE address, so dynamic memory,
  static memory, the object table, the dictionary and the globals all live
  below $10000 by construction: story page 0, offset only.

  The second page is reached only by PACKED addresses (routines and strings,
  x2 in v3) and by the abbreviation table's WORD addresses (also x2). Hence
  ZSeekPacked and ZSeekWordAddr are the only routines here that compute a
  page, and every other entry point takes a plain Word.

  ---- What is deliberately NOT wrapped -------------------------------------

  MemNextByte / MemNextWordBE / MemTellOfs / MemTellPage are called directly
  by ztext and zexec. A ZNext that only forwarded to MemNextByte would cost
  a CALL16 and a RET on the interpreter's hottest path to buy a synonym.
  zmem owns ADDRESSING, which is genuinely different work; it does not own a
  renaming layer.

  ---- Endianness -----------------------------------------------------------

  Z words are big-endian at arbitrary offsets, so ZWord is MemGetWordBE and
  ZPutWord is TWO byte writes. MemPutWord is native little-endian and must
  never appear in this engine.
  --------------------------------------------------------------------------- }

const
  { ---- v3 header offsets (Standard 1.1 s11) ---- }
  ZH_VERSION  = $00;  ZH_FLAGS1   = $01;  ZH_RELEASE  = $02;
  ZH_HIMEM    = $04;  ZH_INITPC   = $06;  ZH_DICT     = $08;
  ZH_OBJECTS  = $0A;  ZH_GLOBALS  = $0C;  ZH_STATIC   = $0E;
  ZH_FLAGS2   = $10;  ZH_SERIAL   = $12;  ZH_ABBREV   = $18;
  ZH_LENGTH   = $1A;  ZH_CHECKSUM = $1C;

  ZHDR_SIZE   = $40;

  { Largest dynamic memory this build will save or restore.

    The Z-machine permits nearly 64 KB; every real v3 story uses a small
    fraction of it (Zork I: 11,282 bytes). The cap is what keeps every
    Quetzal chunk length inside 16 bits: CMem's worst case is 1.5 bytes out
    per byte in -- alternating zero and non-zero deltas, each zero costing a
    two-byte run -- so 32 KB in cannot exceed 48 KB out, and the whole FORM
    stays under 64 KB with room to spare.

    A story above this still LOADS and PLAYS; only save and restore refuse,
    and they say so. Restart is unaffected: ZPgOrig holds the full ZStatic
    bytes whatever their number. }
  ZDYN_MAX    = $8000;

  { MemRead's count is a Word and a v3 story reaches 128 KB, so the load is a
    loop. Well under $FFFF so that "a short read means EOF" cannot collide
    with MemRead's own $FFFF hard-error return.

    8 KB rather than the 32 KB it was: the chunk boundary is where the
    progress dot goes, and under Digital -- where a load runs for tens of
    minutes -- three dots is not the difference between "working" and "hung".
    Eleven is. The extra syscalls are nothing against 8,192 bytes of copying
    apiece. }
  ZLOAD_CHUNK = $2000;

  { Bytes per MemSum call and per MemCopyTo call. Same reasoning: the chunk
    exists to make a dot, not because either routine needs one. }
  ZSUM_CHUNK  = $2000;
  ZCOPY_CHUNK = $0800;

  { ---- ZErr ---- }
  ZE_OK       = 0;   ZE_NOFILE  = 1;   ZE_EMPTY = 2;
  ZE_TOOBIG   = 3;   ZE_VERSION = 4;   ZE_TRUNC = 5;   ZE_CKSUM = 6;

var
  ZPg0     : Word;        { page holding story byte 0 }
  ZPgTop   : Word;        { highest page the image occupies }

  { The two pages at the top of the run, taken by Part 27.

    ZPgOrig holds dynamic memory as it came off disk. It is captured BEFORE
    ZSetHeaderFlags, so it matches the story file byte for byte rather than
    our flag-stamped copy of it -- Quetzal's CMem is defined as an XOR
    against the ORIGINAL (s3.2), and a baseline that differed by even the two
    header flag bytes would hand every other interpreter two wrong bytes.

    ZPgStage is scratch: a restore is assembled here and copied over the live
    story only once every chunk has been read and checked. }
  ZPgOrig  : Word;
  ZPgStage : Word;
  ZVersion : Word;
  ZRelease : Word;
  ZHiMem   : Word;
  ZInitPC  : Word;
  ZDict    : Word;
  ZObjTab  : Word;
  ZGlobals : Word;
  ZStatic  : Word;
  ZAbbrev  : Word;
  ZLenHi   : Word;        { file length in bytes, 17-bit as (hi,lo) }
  ZLenLo   : Word;
  ZCkHdr   : Word;        { checksum claimed by the header }
  ZCkCalc  : Word;        { checksum computed over the loaded image }
  ZSerial  : String[6];
  ZErr     : Word;

  { Set by the caller. Startup is the one part of this engine with no output
    of its own, so a hang anywhere in it looks identical from outside. These
    markers are the difference between "it loops" and a line number. }
  ZTrace   : Boolean;

{ ---- Random access, story page 0 ----------------------------------------- }

function ZByte(a: Word): Byte;
begin
  ZByte := MemGetByte(a, ZPg0);
end;

function ZWord(a: Word): Word;
begin
  ZWord := MemGetWordBE(a, ZPg0);
end;

procedure ZPutByte(a, v: Word);
begin
  MemPutByte(a, ZPg0, v and $FF);
end;

{ Two byte writes, not MemPutWord: big-endian, and a Z word may sit at an odd
  address where the native word store would fault. }
procedure ZPutWord(a, v: Word);
begin
  MemPutByte(a,     ZPg0, v shr 8);
  MemPutByte(a + 1, ZPg0, v and $FF);
end;

{ ---- Cursor positioning -------------------------------------------------- }

{ A plain byte address. Page 0 always -- see the header comment. }
procedure ZSeek(a: Word);
begin
  MemSeek(a, ZPg0);
end;

{ A packed address: routines and strings, x2 in v3. This and ZSeekWordAddr are
  the only places a page is computed. p shl 1 wraps mod 65536, which IS the
  offset, and p shr 15 is the page -- the decomposition is free because the
  story is page-aligned (Part 24 s5.1). }
procedure ZSeekPacked(p: Word);
begin
  MemSeek(p shl 1, ZPg0 + (p shr 15));
end;

{ A word address: abbreviation table entries only. Identical arithmetic to
  ZSeekPacked in v3 and NOT the same concept -- packed scales by 4 in v5+,
  word addresses never do. Two names so a v5 port breaks loudly. }
procedure ZSeekWordAddr(p: Word);
begin
  MemSeek(p shl 1, ZPg0 + (p shr 15));
end;

{ ---- Globals ------------------------------------------------------------- }
{ Variable numbers $10..$FF are globals 0..239. }

function ZGlobal(n: Word): Word;
begin
  ZGlobal := ZWord(ZGlobals + (n shl 1));
end;

procedure ZSetGlobal(n, v: Word);
begin
  ZPutWord(ZGlobals + (n shl 1), v);
end;

{ ---- Checksum ------------------------------------------------------------ }
{ Sum of every byte from $40 to file length - 1, mod 65536. Walked with the
  cursor because it crosses the page boundary and [XY0]+ carries. This is also
  the `verify` opcode's answer, so it lives here rather than inside the loader. }

function ZChecksum: Word;
var
  hi, lo, sum, n: Word;
begin
  ZChecksum := 0;

  { Guard, not decoration. hi and lo are unsigned, so a length below $40 makes
    the subtraction below borrow and Dec(hi) wrap to $FFFF -- and the loop then
    runs about 4.3 billion times, which is a hang by any practical measure. A
    length of 0 reaches here quite easily: it passes the truncation check in
    ZMemInit trivially, since 0 is never greater than what was read. }
  if (ZLenHi = 0) and (ZLenLo < ZHDR_SIZE) then Exit;

  hi := ZLenHi;
  lo := ZLenLo;
  if lo < ZHDR_SIZE then Dec(hi);        { unsigned: C=1 means NO borrow }
  lo := lo - ZHDR_SIZE;

  MemSeek(ZHDR_SIZE, ZPg0);
  sum := 0;
  while (hi > 0) or (lo > 0) do
  begin
    { MemSum takes a Word, and the remaining count is 32-bit, so the chunk is
      whatever fits: a full one while the high word is non-zero, otherwise
      what is left. Partial sums of a mod-65536 total add correctly, so the
      chunking costs nothing but a few extra calls. }
    if hi > 0 then n := ZSUM_CHUNK
    else if lo > ZSUM_CHUNK then n := ZSUM_CHUNK
    else n := lo;

    sum := sum + MemSum(n);

    if lo < n then Dec(hi);              { unsigned borrow -- Part 24 s5.1 }
    lo := lo - n;
    Write('.');
  end;
  ZChecksum := sum;
end;

{ ---- Header -------------------------------------------------------------- }

procedure ZParseHeader;
var
  i: Word;
begin
  ZVersion := ZByte(ZH_VERSION);
  ZRelease := ZWord(ZH_RELEASE);
  ZHiMem   := ZWord(ZH_HIMEM);
  ZInitPC  := ZWord(ZH_INITPC);
  ZDict    := ZWord(ZH_DICT);
  ZObjTab  := ZWord(ZH_OBJECTS);
  ZGlobals := ZWord(ZH_GLOBALS);
  ZStatic  := ZWord(ZH_STATIC);
  ZAbbrev  := ZWord(ZH_ABBREV);
  ZCkHdr   := ZWord(ZH_CHECKSUM);

  { v3 stores the length in WORDS. }
  i      := ZWord(ZH_LENGTH);
  ZLenHi := i shr 15;
  ZLenLo := i shl 1;

  ZSerial := '      ';
  for i := 1 to 6 do ZSerial[i] := Chr(ZByte(ZH_SERIAL + i - 1));
end;

{ Flags the interpreter owns. v3 only: bits 4/5/6 of Flags1. Offsets $1E..$21
  (interpreter number, version, screen size) are v4+ and are deliberately left
  alone -- writing them on a v3 story stamps bytes the game may be using. }
procedure ZSetHeaderFlags;
var
  f: Word;
begin
  f := ZByte(ZH_FLAGS1);
  f := f and $EF;                { bit 4 clear: status line IS available }
  f := f or  $20;                { bit 5 set:   screen splitting available }
  f := f and $BF;                { bit 6 clear: fixed-pitch is not default }
  ZPutByte(ZH_FLAGS1, f);

  f := ZByte(ZH_FLAGS2);
  f := f and $FE;                { transcripting off until it is implemented }
  ZPutByte(ZH_FLAGS2, f);
end;

{ ---- Load ---------------------------------------------------------------- }

{ Everything ZMemInit can reject on the strength of the first 64 bytes, done
  separately and SILENTLY so the caller can decide whether it is going to run
  before it registers as a shell.

  The reason is k/OS's, not the Z-machine's. sys_register_shell allocates a
  back-buffer and leaves the task backgrounded; from then on our output is
  recorded, not shown, and if we Halt, _ReapDeadTask frees that buffer and
  repaints from the incoming shell. A diagnostic written after registering is
  destroyed in the same instant it becomes true. So the checks that a user can
  actually provoke -- no such file, not a v3 story, a story larger than this
  run's pages -- happen HERE, before registration, where WriteLn still reaches
  the terminal; and the load's progress output happens after it, where it
  belongs in the back-buffer and is waiting when you switch to us.

  Of ZMemInit's failures only two need the read loop -- a MemRead hard error,
  and a header claiming more bytes than the file holds. Both are I/O faults
  rather than user error, and the caller reports them by exit code alone.

  Cheap, and free of consequence: the 64 bytes land at story offset 0 on ZPg0,
  which ZMemInit's own read overwrites from byte 0 a moment later, and every
  header variable this sets ZParseHeader sets again. The file is opened twice.

  The page arithmetic is repeated rather than shared. It is three lines, it
  must be right in ZMemInit whether or not anyone probed first, and a version
  of it that only ran on one of the two paths is the kind of thing that is
  correct until the day the probe is skipped. }
function ZMemProbe(var fn: String): Boolean;
var
  fd: Integer;
  got, cap: Word;
begin
  ZMemProbe := False;
  ZErr      := ZE_NOFILE;

  ZPg0 := SysMyPage + 1;

  if SysMyPageCount < 4 then
  begin
    ZErr := ZE_TOOBIG;
    Exit;
  end;
  cap := SysMyPageCount - 3;

  ZPgStage := SysMyPage + SysMyPageCount - 1;
  ZPgOrig  := ZPgStage - 1;

  fd := FileOpen(fn, FOPEN_READ);
  if fd < 0 then Exit;

  MemSeek(0, ZPg0);
  got := MemRead(fd, ZHDR_SIZE);
  FileClose(fd);

  { A hard error and a file shorter than a header are the same answer to the
    caller: there is no story here. }
  if (got = $FFFF) or (got < ZHDR_SIZE) then
  begin
    ZErr := ZE_EMPTY;
    Exit;
  end;

  ZParseHeader;

  if ZVersion <> 3 then
  begin
    ZErr := ZE_VERSION;
    Exit;
  end;

  { The header's own length settles ZE_TOOBIG without reading 128 KB to
    discover it. Same sense as the load loop's test, which lets hi = cap. }
  if ZLenHi > cap then
  begin
    ZErr := ZE_TOOBIG;
    Exit;
  end;

  ZErr := ZE_OK;
  ZMemProbe := True;
end;

{ fd is signed -- FileOpen reports failure as a negative value.  got and cap
  are NOT: MemRead returns a Word, and ZLOAD_CHUNK has the sign bit set, so
  declaring got as Integer makes "until got < ZLOAD_CHUNK" a signed compare
  against -32768, which is never true and spins forever.  The variable's type
  picks the branch -- Word emits BHS, Integer emits BGE. }
function ZMemInit(var fn: String): Boolean;
var
  fd: Integer;
  got, cap, hi, lo, a, n: Word;
begin
  { The rejections below are also ZMemProbe's, and a caller that probed has
    already reported any of them by the time it gets here. They stay because
    this function must be correct alone: the duplication costs a few compares
    on a path that then reads 87,000 bytes.

    What the probe CANNOT reach are the two failures inside the read loop, and
    those now happen after the caller has registered as a shell -- where their
    WriteLn goes to a back-buffer that the reap frees. The exit code is the
    only channel out. See zork.pas. }
  ZMemInit := False;
  ZErr     := ZE_NOFILE;

  ZPg0 := SysMyPage + 1;

  { Four pages minimum now, not two: the task page, at least one story page,
    and the two Part 27 pages at the top of the run.

    Tested before the subtraction, not after: cap is unsigned, so a page count
    of 0 would give $FFFF and sail past any "cap < 1" check. }
  if SysMyPageCount < 4 then
  begin
    ZErr := ZE_TOOBIG;
    Exit;
  end;
  cap := SysMyPageCount - 3;           { pages available to hold the story }

  { Anchored to the TOP of the run, not to the end of the story image. A
    story-relative position would move with the story's size and put a
    91 KB game's scratch page where an 87 KB game's story ended -- correct
    both times, and one edit away from not being. }
  ZPgStage := SysMyPage + SysMyPageCount - 1;
  ZPgOrig  := ZPgStage - 1;

  if ZTrace then Write('[open]');
  fd := FileOpen(fn, FOPEN_READ);
  if fd < 0 then Exit;

  { Progress output is unconditional, not behind ZTrace. Under Digital this
    loop runs for tens of minutes with nothing on screen, and a user watching
    a dead terminal cannot tell a slow program from a hung one. The cost is
    one character per 8 KB. }
  if ZTrace then Write('[read]');
  Write('Loading');
  MemSeek(0, ZPg0);
  hi := 0;
  lo := 0;
  repeat
    got := MemRead(fd, ZLOAD_CHUNK);
    if got = $FFFF then                { hard error, distinct from a short read }
    begin
      WriteLn;
      FileClose(fd);
      ZErr := ZE_TRUNC;
      Exit;
    end;
    lo := lo + got;
    if lo < got then Inc(hi);          { unsigned carry -- Part 24 s5.1 }
    if hi > cap then                   { ran past the pages this task owns }
    begin
      WriteLn;
      FileClose(fd);
      ZErr := ZE_TOOBIG;
      Exit;
    end;
    Write('.');
  until got < ZLOAD_CHUNK;
  FileClose(fd);
  WriteLn(' ok');

  if (hi = 0) and (lo < ZHDR_SIZE) then
  begin
    ZErr := ZE_EMPTY;
    Exit;
  end;

  if ZTrace then Write('[hdr]');
  ZParseHeader;
  if ZVersion <> 3 then
  begin
    ZErr := ZE_VERSION;
    Exit;
  end;

  { The header's length is authoritative; a shorter file is a truncated one.
    A LONGER one is legal -- Infocom padded to a block boundary. }
  if (hi < ZLenHi) or ((hi = ZLenHi) and (lo < ZLenLo)) then
  begin
    ZErr := ZE_TRUNC;
    Exit;
  end;

  ZPgTop := ZPg0 + ZLenHi;

  { The pristine copy, and it MUST be taken here -- after the header has been
    parsed so ZStatic is known, and before ZSetHeaderFlags writes a single
    byte.

    MemCopyTo, not a Pascal byte loop. The loop this replaced was
    MemPutByte(a, ZPgOrig, MemNextByte) -- two external calls per byte, about
    twenty-five instructions, and measured under Digital that is roughly
    twenty-five minutes for Zork I's 11,282 bytes of dynamic memory. Silent
    minutes, in the middle of startup. The RTL routine is four instructions a
    byte and carries across pages on its own.

    Chunked only so there is somewhere to put a dot. }
  if ZTrace then Write('[orig]');
  Write('Preparing');
  MemSeek(0, ZPg0);
  a := 0;
  while a < ZStatic do
  begin
    if ZStatic - a > ZCOPY_CHUNK then n := ZCOPY_CHUNK else n := ZStatic - a;
    MemCopyTo(a, ZPgOrig, n);          { advances the cursor by n }
    a := a + n;
    Write('.');
  end;
  WriteLn(' ok');

  ZSetHeaderFlags;
  ZErr     := ZE_OK;
  ZMemInit := True;
  if ZTrace then WriteLn('[ok]');
end;

{ Deliberately NOT part of ZMemInit. The checksum is the only long-running
  step in startup, and while it sat between the load and the caller's first
  output, a hang anywhere upstream was indistinguishable from a hang inside
  it. Callers dump the header first, then verify. This is also the `verify`
  opcode's body. }
function ZVerify: Boolean;
var
  ok: Boolean;
begin
  ZCkCalc := ZChecksum;
  ok := (ZCkCalc = ZCkHdr);
  if not ok then ZErr := ZE_CKSUM;
  ZVerify := ok;
end;

{ The local `ok' is not a stylistic preference. This is standard Pascal, not
  Delphi: the function's own name in an EXPRESSION is a recursive call, and
  only an ASSIGNMENT to it sets the result. `if not ZVerify then' compiled to
  CALL16 __ZVerify156 -- unbounded recursion. Never read a function's own name
  here; keep the value in a local and assign the name once, last. }

{ ---- Diagnostics --------------------------------------------------------- }

procedure ZErrMsg(e: Word);
begin
  case e of
    ZE_OK      : Write('ok');
    ZE_NOFILE  : Write('cannot open story file');
    ZE_EMPTY   : Write('file is shorter than a header');
    ZE_TOOBIG  : Write('story is larger than the pages this run owns');
    ZE_VERSION : Write('not a version 3 story');
    ZE_TRUNC   : Write('file is truncated');
    ZE_CKSUM   : Write('checksum mismatch');
  else
    Write('unknown error');
  end;
end;
