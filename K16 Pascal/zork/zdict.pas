{ ---------------------------------------------------------------------------
  zdict.pas -- Z-machine v3 dictionary and input tokeniser
                                                           K16 Pascal, Part 26

  Include AFTER zmem.pas and ztext.pas. The ENCODER lives in ztext.pas, not
  here, so that the alphabet table has one definition -- see the note there.

  Directive names appear bare in these comments on purpose (Part 24 s5.5).

  ---- Layout (Standard 1.1 s13) --------------------------------------------

    ZDict + 0        byte    n = number of word separators
    ZDict + 1        n bytes ZSCII codes of the separators
    ZDict + 1 + n    byte    entry length in bytes (>= 4 in v3)
    ZDict + 2 + n    word    entry count, SIGNED
    ZDict + 4 + n    the entries

  Each v3 entry is four bytes of encoded text -- two words, bit 15 set on the
  second -- followed by (entry_length - 4) bytes the game owns and the
  interpreter never reads.

  ---- The count is signed, and it matters ----------------------------------

  A NEGATIVE count means the dictionary is UNSORTED and must be searched
  linearly; the magnitude is the entry count. Infocom and Inform both emit
  sorted dictionaries in practice (Zork I release 119 is sorted, verified),
  so a binary search on an unsorted table would work almost always and fail
  on somebody's homebrew story with no symptom but a word that will not parse.
  Both paths are here.

  ---- Separators are WORDS, not just delimiters ----------------------------

  Zork I's separators are '.', ',' and '"' -- and those are dictionary
  entries 2, 3 and 8. So a separator terminates the token before it AND is
  emitted as a one-character token of its own. Discarding them, which is what
  a plain "split on delimiters" tokeniser does, loses `say "hello"' and the
  multi-command period.
  --------------------------------------------------------------------------- }

const
  { Inclusive upper bounds -- array bounds must be constant identifiers. }
  ZD_SEPTOP = 15;         { at most 16 separators; v3 stories use 3 }

  { Parse-buffer entry layout, 4 bytes per word. }
  ZD_PE_ADDR = 0;         { word: dictionary byte address, 0 = not found }
  ZD_PE_LEN  = 2;         { byte: letters in the token }
  ZD_PE_POS  = 3;         { byte: position of the token in the text buffer }
  ZD_PE_SIZE = 4;

var
  ZDSepCount : Word;
  ZDSeps     : array[0..ZD_SEPTOP] of Word;
  ZDEntLen   : Word;
  ZDEntCount : Word;      { magnitude; see ZDSorted }
  ZDSorted   : Boolean;
  ZDBase     : Word;      { byte address of entry 0 }

  { Token scratch. Module-level: a String local would take a 256-byte frame
    block at every call site (Part 24 s5.2), and the tokeniser is called once
    per input line with a fresh token per word. }
  ZDWord     : String;

{ ---- Header -------------------------------------------------------------- }

procedure ZDictInit;
var
  a, i, c: Word;
begin
  a := ZDict;

  ZDSepCount := ZByte(a);
  a := a + 1;

  { `while i < count' rather than `for i := 0 to count - 1'. A story with no
    separators is legal, and on an unsigned counter the for-form would run
    0..$FFFF -- the 16-bit zero trap. }
  i := 0;
  while i < ZDSepCount do
  begin
    if i <= ZD_SEPTOP then ZDSeps[i] := ZByte(a + i);
    i := i + 1;
  end;
  a := a + ZDSepCount;

  ZDEntLen := ZByte(a);
  a := a + 1;
  c := ZWord(a);
  a := a + 2;
  ZDBase := a;

  if c >= $8000 then
  begin
    ZDSorted   := False;
    ZDEntCount := (not c) + 1;        { two's complement magnitude }
  end
  else
  begin
    ZDSorted   := True;
    ZDEntCount := c;
  end;
end;

{ Byte address of entry n. Every v3 dictionary lives below $10000 because the
  header field is a byte address, so this stays in one word. }
function ZDEntryAddr(n: Word): Word;
begin
  ZDEntryAddr := ZDBase + (n * ZDEntLen);
end;

function ZDIsSep(c: Word): Boolean;
var
  i: Word;
begin
  ZDIsSep := False;
  i := 0;
  while i < ZDSepCount do
  begin
    if (i <= ZD_SEPTOP) and (ZDSeps[i] = c) then
    begin
      ZDIsSep := True;
      Exit;
    end;
    i := i + 1;
  end;
end;

{ ---- Lookup -------------------------------------------------------------- }

{ Byte address of S's dictionary entry, or 0. S is encoded, then matched on
  the full four-byte key.

  The binary search is a LOWER BOUND with an exclusive high, not the textbook
  form. `hi := mid - 1' underflows to $FFFF when mid is 0 on an unsigned
  index, and this project has now been bitten by that exact shape three
  times. lo/hi as [inclusive, exclusive) cannot underflow. }
function ZDictLookup(var S: String): Word;
var
  w1, w2, lo, hi, mid, a, k1, k2: Word;
begin
  ZDictLookup := 0;
  if ZDEntCount = 0 then Exit;

  ZTEncode(S, w1, w2);

  if ZDSorted then
  begin
    lo := 0;
    hi := ZDEntCount;
    while lo < hi do
    begin
      mid := lo + ((hi - lo) shr 1);
      a   := ZDEntryAddr(mid);
      k1  := ZWord(a);
      k2  := ZWord(a + 2);
      if (k1 < w1) or ((k1 = w1) and (k2 < w2)) then lo := mid + 1
      else hi := mid;
    end;
    if lo < ZDEntCount then
    begin
      a := ZDEntryAddr(lo);
      if (ZWord(a) = w1) and (ZWord(a + 2) = w2) then ZDictLookup := a;
    end;
  end
  else
  begin
    lo := 0;
    while lo < ZDEntCount do
    begin
      a := ZDEntryAddr(lo);
      if (ZWord(a) = w1) and (ZWord(a + 2) = w2) then
      begin
        ZDictLookup := a;
        Exit;
      end;
      lo := lo + 1;
    end;
  end;
end;

{ The text of entry n, decoded. Diagnostics and the encoder round-trip test;
  nothing in the interpreter needs it. The entry's z-chars sit at the entry
  address with bit 15 set on the second word, so this is a seek and a decode.
  Trailing pad (z-char 5) sets the shift state and emits nothing, which is
  exactly what ZTDecode already does at end-of-string. }
procedure ZDictText(n: Word; var S: String);
begin
  S := '';
  if n >= ZDEntCount then Exit;
  ZSeek(ZDEntryAddr(n));
  ZTextHere(S);
end;

{ ---- Tokeniser ----------------------------------------------------------- }

{ Split the text buffer at taddr and fill the parse buffer at paddr.

  Text buffer (v1-4): byte 0 is the maximum length; the text itself starts at
  byte 1 and is nul-terminated, lowercased by whoever filled it.

  Parse buffer: byte 0 is the maximum number of words the game will accept,
  byte 1 receives the number actually parsed, then ZD_PE_SIZE bytes each.

  POSITION is 1-based from the START of the text buffer, so the first
  character of the input reports 1. The Standard's wording is loose here and
  v5 moves the text, so it is worth stating: this matches what v1-4
  interpreters do, and the game uses it to re-read the raw word for things
  the dictionary cannot hold -- `answer' and the like. }
procedure ZDictTokenise(taddr, paddr: Word);
var
  maxw, nw, pos, tlen, start, n, c, k, a: Word;
begin
  maxw := ZByte(paddr);
  nw   := 0;

  { Find the terminator. Capped at 255 so a buffer with no nul cannot spin. }
  tlen := 1;
  while (tlen < 255) and (ZByte(taddr + tlen) <> 0) do tlen := tlen + 1;

  pos := 1;
  while (pos < tlen) and (nw < maxw) do
  begin
    c := ZByte(taddr + pos);

    { Spaces separate and are discarded. Separators separate and are kept. }
    if c = 32 then
    begin
      pos := pos + 1;
      Continue;
    end;

    start := pos;

    if ZDIsSep(c) then
    begin
      n   := 1;
      pos := pos + 1;
    end
    else
    begin
      n := 0;
      while pos < tlen do
      begin
        c := ZByte(taddr + pos);
        if (c = 32) or ZDIsSep(c) then Break;
        n   := n + 1;
        pos := pos + 1;
      end;
    end;

    { Build the token. Written through the length byte rather than by concat:
      ZDWord := ZDWord + c calls __storestr per character and copies 255
      bytes each time (the ZTBuf argument, ztext.pas). }
    ZDWord[0] := Chr(0);
    k := 0;
    while k < n do
    begin
      ZDWord[k + 1] := Chr(ZByte(taddr + start + k));
      k := k + 1;
    end;
    ZDWord[0] := Chr(n);

    a := paddr + 2 + (nw * ZD_PE_SIZE);
    ZPutWord(a + ZD_PE_ADDR, ZDictLookup(ZDWord));
    ZPutByte(a + ZD_PE_LEN,  n);
    ZPutByte(a + ZD_PE_POS,  start);

    nw := nw + 1;
  end;

  ZPutByte(paddr + 1, nw);
end;
