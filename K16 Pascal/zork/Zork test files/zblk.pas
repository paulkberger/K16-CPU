program ZBlk;

(* ---------------------------------------------------------------------------
   zblk.pas -- per-4KB block checksums of a loaded story image
                                                          K16 Pascal, Part 26

   Diagnostic for the `zhdr big.z3' checksum mismatch. ZChecksum answers one
   yes/no over 91,402 bytes, which localises nothing. This walks the same
   bytes with the same mechanism -- MemSeek once, then MemNextByte -- but
   reports a running sum every 4096 bytes, so a mismatch names the block.

   Testing loader and reader TOGETHER is deliberate. The suspect list has
   candidates on both sides (sys_read's 32-bit position, __mread's page
   clamping, __mnextb's cursor write-back), and the PATTERN of which blocks
   disagree separates them where a single total cannot:

     all 23 match            -> image is fine; the bug is inside ZChecksum
                                (its (hi,lo) countdown, or the borrow at
                                lo < ZHDR_SIZE)
     0..15 ok, 16+ wrong     -> the page boundary; look at the second
                                MemRead and the cursor carry into page 5
     16+ repeat 0..6's sums  -> page 5 is serving page 4's content: a
                                position or page failure in sys_read
     scattered mismatches    -> chunk-size arithmetic
                                (_FdComputeReadChunk)
     one block inside page 4 -> nothing to do with 64 KB at all

       K> zblk big.z3

   Requires PAGES 3, same as zhdr. Output is deliberately plain -- it is
   meant to be diffed against a table, not read for pleasure.

   Hex via Write rather than a String-returning helper: a String temp costs
   a 256-byte frame block per call site (Part 24 s5.2), and this only prints.
   --------------------------------------------------------------------------- *)

{$PAGES 3}
{$HEAP 0}

{$I files.pas}
{$I console.pas}
{$I memory.pas}
{$I zmem.pas}

const
  HexDigits: array[0..15] of Char =
    ('0','1','2','3','4','5','6','7','8','9','a','b','c','d','e','f');

var
  Args: String;
  nblk, rem, b, i, s, pg, ofs: Word;

procedure WHex2(v: Word);
begin
  Write(HexDigits[(v shr 4) and $0F], HexDigits[v and $0F]);
end;

procedure WHex4(v: Word);
begin
  WHex2(v shr 8);
  WHex2(v and $FF);
end;

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
    WriteLn('usage: zblk <story.z3>');
    Halt(1);
  end;

  if not HasExt(Args) then Args := Args + '.Z3';

  if not ZMemInit(Args) then
  begin
    Write('zblk: ');
    ZErrMsg(ZErr);
    WriteLn;
    Halt(1);
  end;

  (* Block count from the 17-bit length. 16 blocks of 4096 per 64 KB page. *)
  nblk := ZLenHi * 16 + (ZLenLo shr 12);
  rem  := ZLenLo and $0FFF;

  WriteLn;
  WriteLn('blk  page  ofs   sum');

  MemSeek(0, ZPg0);

  (* Guarded, not decorative: nblk = 0 for a story under 4 KB, and
     `for b := 0 to nblk - 1' on an unsigned counter would run 0..$FFFF --
     the same 16-bit zero trap ZChecksum guards against. *)
  if nblk > 0 then
  begin
    for b := 0 to nblk - 1 do
    begin
      s := 0;
      for i := 1 to 4096 do s := s + MemNextByte;

      pg  := ZPg0 + (b shr 4);
      ofs := (b and 15) shl 12;

      Write(b);
      Write('    ');   Write(pg);
      Write('   ');    WHex4(ofs);
      Write('  ');     WHex4(s);
      WriteLn;
    end;
  end;

  if rem > 0 then
  begin
    s := 0;
    for i := 1 to rem do s := s + MemNextByte;
    Write(nblk);
    Write('    tail  ');
    WHex4(s);
    Write('   (');
    Write(rem);
    WriteLn(' bytes)');
  end;

  WriteLn;
end.
