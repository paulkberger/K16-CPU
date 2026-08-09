{ ---------------------------------------------------------------------------
  memory.pas -- paged memory access                     K16 Pascal, Part 24 / 25
  Bodies in memory.asm.  k/OS target only.

  Mem[x] reads a byte from the CURRENT data page (Y3) and has no page
  selector.  This module is that same access with the page supplied
  explicitly, so a task can reach the extra pages of a multi-page run
  (a $PAGES declaration) rather than only the one it executes in.

      Mem[x]  ==  MemGetByte(x, SysMyPage)

  ---- Why the arguments are separate Words and not a record ----------------

  Passing a two-word record by value costs a __memcopy call at every call
  site (measured, Part 24 s3.3).  The V2 ABI puts the last three scalar
  arguments in D0/D1/D2, so every entry point here takes three or fewer and
  none of them touches the stack.  Keep it that way when adding to it.

  ---- Endianness: read this before using MemGetWord ------------------------

  K16 is little-endian and word access faults on an odd address.  Z-machine
  words are BIG-endian and sit at arbitrary byte offsets.  Those are two
  different things and they get two different routines:

    MemGetWord     native.  Little-endian, ofs MUST be even.  For structures
                   you lay out yourself.
    MemGetWordBE   two byte reads, hi*256+lo.  Any alignment.  For a Z-machine
                   story image, and anything else that arrived big-endian.

  A single routine that quietly did the big-endian thing would be wrong for
  every non-Z caller that came later, so the call site has to say which.

  ---- The cursor -----------------------------------------------------------

  MemSeek / MemNextByte / MemNextWordBE / MemTell* are the sequential fast path:
  MemNextByte is a post-increment load and a return, against MemGetByte's
  argument marshalling and address rebuild.  Z-text decoding is almost
  entirely sequential, so this is the hot path.

  ONE cursor, shared by every routine that uses it.  It advances with
  [XY0]+, which carries into the page byte, so walking off the end of a page
  lands correctly on the next one (verified gate-level by PAGETEST, k/OS
  Part 60).  Note that ADD X0,#2 does NOT carry -- it wraps within the page --
  which is why nothing here advances a pointer by more than one at a time.
  --------------------------------------------------------------------------- }

{ The bodies. Resolved by the same probe as $I: the including file is
  rtl\memory.pas, so the source-directory arm finds rtl\memory.asm with no
  path needed. Kept here rather than in every caller, so a program writes one
  line -- the $I -- and gets both halves. }
{$L memory.asm}

{ ---- Random access ---- }
function  MemGetByte  (ofs, page: Word): Byte;  external '__mgetb';
function  MemGetWord  (ofs, page: Word): Word;  external '__mgetw';
function  MemGetWordBE(ofs, page: Word): Word;  external '__mgetwbe';
procedure MemPutByte  (ofs, page, v: Word);     external '__mputb';
procedure MemPutWord  (ofs, page, v: Word);     external '__mputw';

{ ---- Sequential cursor ---- }
procedure MemSeek     (ofs, page: Word);        external '__mseek';
function  MemNextByte : Byte;                   external '__mnextb';
function  MemNextWordBE: Word;                  external '__mnextwbe';

{ Read the cursor back, so a reader can leave it and return -- restore with
  MemSeek. Two entries because the ABI has one result register. Use these
  rather than shadowing the position in the caller: one position tracked by
  two mechanisms that must agree about carry is the sys_read hazard. }
function  MemTellOfs  : Word;                   external '__mtellofs';
function  MemTellPage : Word;                   external '__mtellpage';

{ ---- Bulk ----

  MemRead reads into the cursor and advances it, so loading a story image is
  MemSeek to the run's second page and one call.

  It chunks internally, and that is a correctness requirement rather than
  tuning: sys_read honours the destination page byte, but between sectors it
  advances only the OFFSET, with no carry.  A single kernel call whose buffer
  crossed $FFFF would wrap to offset 0 in the same page and overwrite the
  start of it -- silently, since the straddling sector itself copies
  correctly.  MemRead therefore never hands the kernel a request that reaches
  a page boundary.

  A short return means EOF.  $FFFF means a hard error, matching FileRead's -1. }
function  MemRead(fd, n: Word): Word;           external '__mread';
procedure MemSkip(n: Word);                     external '__mskip';

{ MemCopyTo copies n bytes from the cursor to (dstOfs, dstPage) and advances
  the cursor by n.  Roughly four instructions per byte against twenty-five for
  the equivalent Pascal loop, which is the difference between a page copy
  being unnoticeable and being the longest phase of a program's startup.

  From the cursor, rather than taking a source pair, because the ABI holds
  three arguments and a five-argument form would spill to the stack -- see the
  note at the top of this file.

  No page-boundary chunking, and unlike MemRead that is deliberate: both
  pointers are [XYn]+, which carries into the page byte in hardware, so source
  and destination cross pages on their own.  MemRead's clamping exists only
  because sys_read will not carry.

  Forward copy, so overlapping regions are safe only when dst is below src.

  MemSum adds n bytes from the cursor as a 16-bit sum and advances the cursor.
  n is a Word, so a caller summing more than 65535 bytes calls it repeatedly
  and adds the results -- partial sums of a mod-65536 total add correctly, and
  the chunk boundary is a natural place to show progress. }
procedure MemCopyTo(dstOfs, dstPage, n: Word);  external '__mcopyto';
function  MemSum(n: Word): Word;                external '__msum';

{ ---- Self-discovery.  No kernel support needed: Y3 is the run base, and the
  page count is a word in the task's own .COM header at $0208. ---- }
function  SysMyPage:      Word;                 external '__mypage';
function  SysMyPageCount: Word;                 external '__mypagecount';

{ True under the Digital gate-level simulator, False under EMU.

  The same probe _DetectHost uses at boot: the SHL lookup ROM at $E0:$2468
  holds $2468 on Digital -- the address is the input $1234 doubled, and the
  value is $1234 shifted left, which happen to be the same number -- while EMU
  computes its lookups instead of storing them and reads back $00.

  Deliberately NOT read from the kernel's KOS_HOST, which is the better source
  in principle.  That is a page-$00 sysvar address hardcoded into a user
  program, and page $00 is being regionised: a stale literal would not fail
  loudly, it would read some other word and choose a target.  This probes a
  hardware property, which cannot move.

  $2468 is even, as MemGetWord requires. }
function SysIsDigital: Boolean;
begin
  SysIsDigital := (MemGetWord($2468, $E0) = $2468);
end;
