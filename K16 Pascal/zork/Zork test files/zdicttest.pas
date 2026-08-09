program ZDictTest;

(* ---------------------------------------------------------------------------
   zdicttest.pas -- dictionary header, encoder round-trip, tokeniser
                                                          K16 Pascal, Part 26

   Three tests, in increasing order of what they prove:

   1. HEADER. Separators, entry length, entry count, sorted flag. Compare
      against `infodump -d story.z3'.

   2. ROUND-TRIP. Decode every entry to text, re-encode it, compare the two
      words to what is stored -- then look the text up and require its own
      address back. Exhaustive, not a sample: on Zork I that is 684 words
      including `$ve' (reachable only through the 10-bit ZSCII escape), `.'
      and `,' (bare A2 punctuation, which are also the separators), `air-p'
      (a hyphen, truncated mid-word) and `zzmgck' (exactly six z-chars, no
      padding). Mismatches are printed, so the case is named, not counted.

   3. TOKENISER. A canned line, with the parse buffer dumped. The line
      exercises separators-as-words, truncation past six letters, and a word
      the dictionary does not hold.

       K> zdicttest zork1.z3

   ---- Where the scratch buffers go -----------------------------------------

   At the TOP of dynamic memory, computed from ZStatic, NOT at a fixed low
   address. The abbreviation table lives low and moves per story -- $01F0 in
   Zork I, $0042 in big.z3 -- so any fixed choice lands on one of them. The
   dictionary is in STATIC memory in both (and by convention generally), so
   writing below ZStatic cannot disturb what tests 2 and 3 read.

   Nothing else runs afterwards, so clobbering game state here is free.
   --------------------------------------------------------------------------- *)

{$PAGES 3}
{$HEAP 0}

{$I files.pas}
{$I console.pas}
{$I memory.pas}
{$I zmem.pas}
{$I ztext.pas}
{$I zdict.pas}

const
  HexDigits: array[0..15] of Char =
    ('0','1','2','3','4','5','6','7','8','9','a','b','c','d','e','f');

  MAXW = 12;                  (* parse-buffer capacity for the canned line *)

var
  Args, S: String;
  i, w1, w2, k1, k2, a, bad, n, nw, pe: Word;
  TBuf, PBuf: Word;

procedure WHex2(v: Word);
begin
  Write(HexDigits[(v shr 4) and $0F], HexDigits[v and $0F]);
end;

procedure WHex4(v: Word);
begin
  WHex2(v shr 8);
  WHex2(v and $FF);
end;

(* Fill the text buffer the way sys_gets would: byte 0 is the maximum length,
   the text starts at byte 1, nul-terminated. *)
procedure SetText(var T: String);
var
  j: Word;
begin
  ZPutByte(TBuf, 200);
  j := 1;
  while j <= Length(T) do
  begin
    ZPutByte(TBuf + j, Ord(T[j]));
    j := j + 1;
  end;
  ZPutByte(TBuf + Length(T) + 1, 0);
end;

begin
  InitFiles;
  ZTrace := False;
  GetArgs(Args);

  if Length(Args) = 0 then
  begin
    WriteLn('usage: zdicttest <story.z3>');
    Halt(1);
  end;

  if not ZMemInit(Args) then
  begin
    Write('zdicttest: ');
    ZErrMsg(ZErr);
    WriteLn;
    Halt(1);
  end;

  ZDictInit;

  (* ---- 1. Header ---- *)
  WriteLn;
  WriteLn('    **** Dictionary ****');
  WriteLn;
  Write('Dictionary address:  '); WHex4(ZDict); WriteLn;
  Write('Word separators   =  ');
  i := 0;
  while i < ZDSepCount do
  begin
    if i <= ZD_SEPTOP then Write(Chr(ZDSeps[i]));
    i := i + 1;
  end;
  WriteLn;
  Write('Word count        =  '); WriteLn(ZDEntCount);
  Write('Entry length      =  '); WriteLn(ZDEntLen);
  Write('Sorted            =  ');
  if ZDSorted then WriteLn('yes (binary search)')
  else WriteLn('no (linear scan)');
  WriteLn;

  (* ---- 2. Round-trip every entry ----
     `while i < count', never `for i := 0 to count - 1'. An empty dictionary
     is legal and the for-form would run 0..$FFFF on an unsigned counter --
     the same 16-bit zero trap ZChecksum and zblk both guard against. *)
  Write('Round-tripping '); Write(ZDEntCount); WriteLn(' entries...');
  bad := 0;
  i   := 0;
  while i < ZDEntCount do
  begin
    a  := ZDEntryAddr(i);
    k1 := ZWord(a);
    k2 := ZWord(a + 2);

    ZDictText(i, S);
    ZTEncode(S, w1, w2);

    if (w1 <> k1) or (w2 <> k2) then
    begin
      bad := bad + 1;
      if bad <= 8 then
      begin
        Write('  ['); Write(i + 1); Write('] '); Write(S);
        Write('  stored ');  WHex4(k1); Write(' '); WHex4(k2);
        Write('  encoded '); WHex4(w1); Write(' '); WHex4(w2);
        WriteLn;
      end;
    end
    else
    begin
      n := ZDictLookup(S);
      if n <> a then
      begin
        bad := bad + 1;
        if bad <= 8 then
        begin
          Write('  ['); Write(i + 1); Write('] '); Write(S);
          Write('  encodes, but lookup gave '); WHex4(n);
          Write(' not ');                       WHex4(a);
          WriteLn;
        end;
      end;
    end;

    i := i + 1;
  end;
  Write('  '); Write(ZDEntCount); Write(' entries, ');
  Write(bad); WriteLn(' mismatches');
  WriteLn;

  (* ---- 3. Tokeniser ---- *)
  if ZStatic < 512 then
  begin
    WriteLn('dynamic memory too small for the tokeniser test; skipped.');
    Halt(0);
  end;

  TBuf := ZStatic - 256;
  PBuf := ZStatic - 64;

  S := 'open the mailbox. take leaflet, read it';
  Write('Tokenising: '); WriteLn(S);
  SetText(S);
  ZPutByte(PBuf, MAXW);
  ZDictTokenise(TBuf, PBuf);

  nw := ZByte(PBuf + 1);
  Write('  words parsed: '); WriteLn(nw);

  i := 0;
  while i < nw do
  begin
    pe := PBuf + 2 + (i * ZD_PE_SIZE);
    a  := ZWord(pe + ZD_PE_ADDR);
    n  := ZByte(pe + ZD_PE_LEN);

    Write('  pos ');  Write(ZByte(pe + ZD_PE_POS));
    Write('  len ');  Write(n);
    Write('  dict ');
    if a = 0 then Write('----  (not in dictionary)')
    else
    begin
      WHex4(a);
      Write('  ');
      ZSeek(a);
      ZTextHere(S);
      Write(S);
    end;
    WriteLn;

    i := i + 1;
  end;
  WriteLn;
end.
