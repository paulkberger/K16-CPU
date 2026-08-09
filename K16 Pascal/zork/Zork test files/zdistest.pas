program ZDisTest;

(* ---------------------------------------------------------------------------
   zdistest.pas -- decode every instruction in a story and emit a stream that
                   can be diffed against ztools' txd    K16 Pascal, Part 26

       K> zdistest zork1

   Reads TWO files: <name>.Z3, the story, and <name>.RTS, a list of routine
   start addresses as PACKED words, little-endian, ascending, with one extra
   entry past the last routine acting as the end sentinel. Generated from txd
   on the host.

   ---- Why a routine list, and why packed ----------------------------------

   Nothing in a story file says where routines are. txd finds them by
   analysis; doing that here would mean debugging a routine finder and a
   decoder at the same time, and a decoder desynchronised by one byte
   produces plausible-looking rubbish for a long way. With the list, each
   routine is decoded from a known start for a known number of bytes and any
   desync is contained to the routine that caused it -- so one bad
   instruction reports as one bad routine, not as everything after it.

   Every routine address is even and below $20000, so PACKED (address / 2)
   fits a single word and the whole list is two bytes per entry.

   ---- Output ---------------------------------------------------------------

   One line per instruction:

       paddr class opnum

   and nothing else. Rendering operands the way txd does (L00, (SP)+, branch
   targets) is a great deal of formatting that proves nothing extra: what a
   decoder gets wrong is instruction BOUNDARIES and FORM classification, and
   an address stream that matches txd's proves both at once. Operand values
   are checked later, by running.
   --------------------------------------------------------------------------- *)

{$PAGES 4}
{$HEAP 0}

{$I files.pas}
{$I console.pas}
{$I memory.pas}
{$I zmem.pas}
{$I ztext.pas}
{$I zdis.pas}

const
  HexDigits: array[0..15] of Char =
    ('0','1','2','3','4','5','6','7','8','9','a','b','c','d','e','f');

  RT_MAXBYTES = 2048;         (* 1024 routines; Zork III has 468 *)

var
  Args, Fn: String;
  RtPage, RtCount, i, n, start, stop, nbytes, guard: Word;
  dmy: Word;                  (* sink: a function result must be CONSUMED --
                                 this compiler will not accept a call as a
                                 statement (Part 24 s5.4, same as FileWrite) *)
  fd: Integer;
  bad, total: Word;

procedure WHex2(v: Word);
begin
  Write(HexDigits[(v shr 4) and $0F], HexDigits[v and $0F]);
end;

procedure WHex4(v: Word);
begin
  WHex2(v shr 8);
  WHex2(v and $FF);
end;

(* Packed routine address i, from the scratch page. Two byte reads rather than
   a word read: the list is written little-endian by the generator and
   MemGetWordBE is the big-endian Z reader, which would swap it. *)
function Rt(k: Word): Word;
begin
  Rt := MemGetByte(k * 2, RtPage) or (MemGetByte(k * 2 + 1, RtPage) shl 8);
end;

begin
  InitFiles;
  ZTrace := False;
  GetArgs(Args);

  if Length(Args) = 0 then
  begin
    WriteLn('usage: zdistest <name>   reads <name>.Z3 and <name>.RTS');
    Halt(1);
  end;

  (* ---- Routine list into its own page, BEFORE the story loads ----
     ZMemInit puts the story at SysMyPage+1 upward, so the last page this
     task owns is free. Loading the list first also means a missing .RTS is
     reported before the slow part. *)
  if SysMyPageCount < 4 then
  begin
    WriteLn('zdistest: needs PAGES 4');
    Halt(1);
  end;
  RtPage := SysMyPage + 3;

  Fn := Args + '.RTS';
  fd := FileOpen(Fn, FOPEN_READ);
  if fd < 0 then
  begin
    Write('zdistest: cannot open '); WriteLn(Fn);
    Halt(1);
  end;
  MemSeek(0, RtPage);
  nbytes := MemRead(fd, RT_MAXBYTES);
  FileClose(fd);
  if (nbytes = $FFFF) or (nbytes < 4) then
  begin
    WriteLn('zdistest: routine list is empty or unreadable');
    Halt(1);
  end;
  RtCount := (nbytes shr 1) - 1;        (* last entry is the end sentinel *)

  Fn := Args + '.Z3';
  if not ZMemInit(Fn) then
  begin
    Write('zdistest: ');
    ZErrMsg(ZErr);
    WriteLn;
    Halt(1);
  end;

  Write('; '); Write(RtCount); WriteLn(' routines');

  bad   := 0;
  total := 0;
  i     := 0;
  while i < RtCount do
  begin
    start := Rt(i);
    stop  := Rt(i + 1);

    (* Byte length of this routine. Packed addresses are ascending, so this
       cannot borrow -- but a malformed list would make it wrap to ~128 KB
       and decode the rest of the story as one routine, so it is checked. *)
    if stop <= start then
    begin
      Write('; BAD ROUTINE ORDER at index '); WriteLn(i);
      bad := bad + 1;
      i := i + 1;
      Continue;
    end;
    nbytes := (stop - start) * 2;

    ZSeekPacked(start);

    (* Routine header: local count, then that many WORDS of initial values in
       v3. v5 dropped the initial values; reading them there is a classic way
       to decode a v5 story into nonsense. *)
    n := MemNextByte;
    nbytes := nbytes - 1;
    while n > 0 do
    begin
      dmy := MemNextByte;
      dmy := MemNextByte;
      nbytes := nbytes - 2;
      n := n - 1;
    end;

    (* Decode until the routine's bytes are used up. The guard is not
       decoration: a decoder that miscounts can consume fewer bytes per
       instruction than it should and spin here for a very long time. *)
    guard := 0;
    while (nbytes > 0) and (nbytes < $8000) and (guard < 4000) do
    begin
      (* Inter-routine padding. Routines are packed-addressed, so each starts
         on an even byte and up to one zero byte can sit between the last
         instruction of one and the header of the next -- 190 of Zork I's 440
         routines have one. $00 is long form, 2OP, opcode 0, which does not
         exist in v3, so a zero here is unambiguously padding and never an
         instruction. Peeked rather than consumed. *)
      if MemGetByte(MemTellOfs, MemTellPage) = 0 then Break;

      ZDecode;

      Write(HexDigits[(ZIAtPage - ZPg0) and $0F]);
      WHex4(ZIAtOfs);
      Write(' '); Write(ZIClass);
      Write(' ');  WHex2(ZIOpcode);
      WriteLn;

      total := total + 1;
      guard := guard + 1;

      (* Bytes consumed, from the cursor. Subtracting offsets is correct
         across a page boundary too: the difference of the two 16-bit
         offsets wraps to the true count for anything under 64 KB. *)
      n := (MemTellOfs - ZIAtOfs) and $FFFF;
      if n = 0 then
      begin
        Write('; ZERO-LENGTH DECODE at '); WHex4(ZIAtOfs); WriteLn;
        bad := bad + 1;
        Break;
      end;
      nbytes := nbytes - n;
    end;

    if nbytes >= $8000 then
    begin
      Write('; OVERRUN in routine '); WHex4(start); WriteLn;
      bad := bad + 1;
    end;

    i := i + 1;
  end;

  Write('; '); Write(total); Write(' instructions, ');
  Write(bad); WriteLn(' routines flagged');
end.
