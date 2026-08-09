{ ---------------------------------------------------------------------------
  ztext.pas -- Z-string decoding                           K16 Pascal, Part 25

  Include AFTER zmem.pas.

  ---- Where the output goes ------------------------------------------------

  One decoder serves both "print this" and "give me this as a String", chosen
  by ZTToBuf. Two copies of the decoder would be the alternative, and the
  alphabet tables in the two copies would disagree within six months.

  ZTBuf appends through its length byte -- ZTBuf[0] := Chr(n) -- rather than
  ZTBuf := ZTBuf + c. The concat form calls __storestr per character, copying
  255 bytes each time; a sixty-character name would move 15 KB to build.

  ---- Why this loop is flat and not recursive ------------------------------

  An abbreviation is a jump out of the current string and back, so the obvious
  decoder recurses. It cannot here: this compiler allocates locals STATICALLY
  (they appear as l_Routine_name in the GLOBALS region, FRAMESPACE is 0), so a
  recursive call overwrites its own caller's locals.

  v3 abbreviations cannot themselves contain abbreviations, so the nesting is
  exactly one level deep and an explicit save of the decode state covers it.
  The loop below therefore has a depth flag rather than a call.

  ---- The parts of the format that are easy to get wrong -------------------

  SHIFTS ARE ONE CHARACTER ONLY in v3. z-chars 4 and 5 select A1 or A2 for the
  single character that follows. v1/v2 had shift LOCKS at 2 and 3; v3 does not.
  Getting this wrong produces text that reads correctly for a few words and
  then stays uppercase forever.

  A2 SLOT 6 IS NOT A CHARACTER. It introduces a 10-bit ZSCII escape assembled
  from the NEXT TWO z-chars (high 5 bits then low 5). Slot 7 is newline. Both
  are handled before the table is indexed.
  --------------------------------------------------------------------------- }

const
  ZT_A0 = 0;
  ZT_A1 = 1;
  ZT_A2 = 2;

  { Inclusive upper bounds, not counts. Array bounds in this compiler must be
    constant IDENTIFIERS -- array[0..N-1] is an expression and errors. }
  ZT_A2TOP  = 25;         { last index of ZT_A2TAB }
  ZT_ENCTOP = 5;          { 6 z-chars per v3 dictionary word }

  { A2, z-chars 6..31, indexed as z-6. Entries 0 and 1 are placeholders: slot 6
    is the ZSCII escape and slot 7 is newline, both intercepted above. They are
    kept so the index arithmetic stays z-6 with no special case. }
  ZT_A2TAB: array[0..ZT_A2TOP] of Char =
    ('^', ' ', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9',
     '.', ',', '!', '?', '_', '#', '''', '?', '/', '?', '-', ':', '(', ')');

  { Slots 19 and 21 are placeholders, and NOT because Pascal minds. The
    compiler emits one .BYTE per Char element, and the assembler's .BYTE
    string form has no escape mechanism -- a double quote and a backslash
    each produce an unterminated string literal. Those two are emitted from
    code below instead. Fix the assembler and they can go back in the table. }
  ZT_QUOTE     = 34;      { A2 slot 25 }
  ZT_BACKSLASH = 92;      { A2 slot 27 }

var
  ZTToBuf : Boolean;      { False -> Write, True -> append to ZTBuf }
  ZTBuf   : String;
  ZTLen   : Word;

  { Word-wrap sink. The Z-machine emits text as an unbroken character stream
    and expects the INTERPRETER to break lines -- a room description arrives
    as one long run with no newlines in it at all. Without this the output is
    a single ragged column and Zork is unreadable.

    It lives here rather than in zexec because ZTEmit is the sink every
    printing opcode ends up in, directly or through the decoder. }
  ZOutWidth : Word;
  ZOutCol   : Word;
  ZOutWord  : String;     { the word being accumulated }
  ZOutWLen  : Word;

  { Encoder scratch. Module-level rather than local to ZTEncode because the
    push helper below needs to share it, and this compiler has no nested
    procedures worth relying on. }
  ZTEncZ  : array[0..ZT_ENCTOP] of Word;
  ZTEncN  : Word;

{ ---- Output sink --------------------------------------------------------- }

procedure ZOutInit;
begin
  ZOutWidth := 78;
  ZOutCol   := 0;
  ZOutWLen  := 0;
  ZOutWord[0] := Chr(0);
end;

{ Emit the pending word, breaking the line first if it will not fit. A word
  longer than the whole width is emitted anyway rather than split: splitting
  an over-long word is worse than overrunning, and the case only arises for
  input echoes and object names nobody wraps. }
procedure ZOutFlushWord;
begin
  if ZOutWLen = 0 then Exit;
  if (ZOutCol + ZOutWLen) > ZOutWidth then
  begin
    WriteLn;
    ZOutCol := 0;
  end;
  Write(ZOutWord);
  ZOutCol  := ZOutCol + ZOutWLen;
  ZOutWLen := 0;
  ZOutWord[0] := Chr(0);
end;

procedure ZOutNewLine;
begin
  ZOutFlushWord;
  WriteLn;
  ZOutCol := 0;
end;

procedure ZOutChar(c: Char);
begin
  if c = Chr(10) then ZOutNewLine
  else if c = ' ' then
  begin
    ZOutFlushWord;
    { A space that would sit past the margin becomes the line break itself,
      and a space never starts a line -- otherwise every wrapped paragraph
      is indented by one column. }
    if ZOutCol > 0 then
    begin
      if ZOutCol >= ZOutWidth then
      begin
        WriteLn;
        ZOutCol := 0;
      end
      else
      begin
        Write(' ');
        ZOutCol := ZOutCol + 1;
      end;
    end;
  end
  else
  begin
    if ZOutWLen < 250 then
    begin
      ZOutWLen := ZOutWLen + 1;
      ZOutWord[ZOutWLen] := c;
      ZOutWord[0] := Chr(ZOutWLen);
    end;
  end;
end;

{ Write a Pascal string through the wrap sink. Not Write(S): that bypasses
  the column tracking and the next wrap lands in the wrong place. }
procedure ZTextWrite(var S: String);
var
  i: Word;
begin
  i := 1;
  while i <= Length(S) do
  begin
    ZOutChar(S[i]);
    i := i + 1;
  end;
end;

{ Unsigned decimal through the sink. Digits are produced least-significant
  first, so they are stacked in a buffer and emitted in reverse. }
procedure ZTextWriteNum(v: Word);
var
  d: array[0..5] of Word;
  n: Word;
begin
  if v = 0 then
  begin
    ZOutChar('0');
    Exit;
  end;
  n := 0;
  while (v > 0) and (n <= 5) do
  begin
    d[n] := v mod 10;
    v := v div 10;
    n := n + 1;
  end;
  while n > 0 do
  begin
    n := n - 1;
    ZOutChar(Chr(48 + d[n]));
  end;
end;

procedure ZTReset;
begin
  ZTLen := 0;
  ZTBuf[0] := Chr(0);
end;

procedure ZTEmit(c: Char);
begin
  if ZTToBuf then
  begin
    if ZTLen < 255 then
    begin
      ZTLen := ZTLen + 1;
      ZTBuf[ZTLen] := c;
      ZTBuf[0] := Chr(ZTLen);      { keep the length byte live as we go }
    end;
  end
  else ZOutChar(c);
end;

{ A ZSCII code from a 10-bit escape. 13 is newline; 32..126 are ASCII. Anything
  else is a character this interpreter has no glyph for, and the Standard says
  to ignore rather than substitute -- a wrong glyph in a room description is
  harder to diagnose than a missing one. }
procedure ZTZscii(z: Word);
begin
  if z = 13 then ZTEmit(Chr(10))
  else if (z >= 32) and (z <= 126) then ZTEmit(Chr(z));
end;

{ ---- The decoder --------------------------------------------------------- }
{ Decodes from the cursor, stopping after the word whose top bit is set. Leaves
  the cursor just past the string. }

procedure ZTDecode;
var
  w, z, i        : Word;
  alpha, nxt     : Word;
  pend           : Word;   { 0 none, 1 abbrev index, 2 zscii hi, 3 zscii lo }
  abbr, zhi, ent : Word;
  fin            : Boolean;
  depth          : Word;
  { one-level save, for abbreviation expansion }
  sOfs, sPg, sAlpha, sNxt, sW, sI : Word;
  sFin           : Boolean;
begin
  alpha := ZT_A0;
  nxt   := ZT_A0;
  pend  := 0;
  depth := 0;
  fin   := False;
  i     := 3;                      { forces the first word fetch }

  while True do
  begin
    if i > 2 then
    begin
      if fin then
      begin
        if depth = 0 then Break;   { end of the string proper }

        { end of an abbreviation: restore the interrupted string }
        MemSeek(sOfs, sPg);
        alpha := sAlpha;  nxt := sNxt;  w := sW;  i := sI;  fin := sFin;
        depth := 0;
        Continue;
      end;
      w := MemNextWordBE;
      if w >= $8000 then fin := True;
      i := 0;
    end;

    case i of
      0: z := (w shr 10) and 31;
      1: z := (w shr 5) and 31;
    else
      z := w and 31;
    end;
    i := i + 1;

    if pend = 1 then
    begin
      pend := 0;
      { Abbreviation 32*(a-1) + z. The table entry is a WORD address, so an
        abbreviation string may live above 64 KB -- which is the whole reason
        MemTellOfs/MemTellPage exist. }
      if depth = 0 then
      begin
        sOfs := MemTellOfs;  sPg := MemTellPage;
        sAlpha := alpha;  sNxt := nxt;  sW := w;  sI := i;  sFin := fin;
        ent := ZWord(ZAbbrev + ((32 * (abbr - 1) + z) shl 1));
        depth := 1;
        ZSeekWordAddr(ent);
        alpha := ZT_A0;  nxt := ZT_A0;  fin := False;  i := 3;
      end;
      { depth = 1 means a malformed story nested one; drop it rather than
        recurse into a structure this decoder cannot represent. }
    end
    else if pend = 2 then
    begin
      zhi := z;
      pend := 3;
    end
    else if pend = 3 then
    begin
      pend := 0;
      ZTZscii((zhi shl 5) or z);
    end
    else if z = 0 then ZTEmit(' ')
    else if z < 4 then
    begin
      abbr := z;
      pend := 1;
    end
    else if z < 6 then nxt := z - 3        { 4 -> A1, 5 -> A2, next char only }
    else
    begin
      alpha := nxt;
      nxt   := ZT_A0;                      { the shift is spent }
      if alpha = ZT_A0 then ZTEmit(Chr(z - 6 + 97))
      else if alpha = ZT_A1 then ZTEmit(Chr(z - 6 + 65))
      else
      begin
        if z = 6 then pend := 2            { 10-bit ZSCII escape follows }
        else if z = 7 then ZTEmit(Chr(10))
        else if z = 25 then ZTEmit(Chr(ZT_QUOTE))
        else if z = 27 then ZTEmit(Chr(ZT_BACKSLASH))
        else ZTEmit(ZT_A2TAB[z - 6]);
      end;
    end;
  end;
end;

{ ---- Entry points -------------------------------------------------------- }

{ Print the string at a plain byte address (print_addr). }
procedure ZTextPrintAt(a: Word);
begin
  ZTToBuf := False;
  ZSeek(a);
  ZTDecode;
end;

{ Print the string at a packed address (print_paddr). }
procedure ZTextPrintPacked(p: Word);
begin
  ZTToBuf := False;
  ZSeekPacked(p);
  ZTDecode;
end;

{ Decode the string at a byte address into S. }
procedure ZTextAt(a: Word; var S: String);
begin
  ZTToBuf := True;
  ZTReset;
  ZSeek(a);
  ZTDecode;
  ZTToBuf := False;
  S := ZTBuf;
end;

{ Decode the string the cursor is already sitting on into S. Used where the
  caller has just walked a structure and does not want to recompute the
  address -- an object's short name, for instance. }
procedure ZTextHere(var S: String);
begin
  ZTToBuf := True;
  ZTReset;
  ZTDecode;
  ZTToBuf := False;
  S := ZTBuf;
end;

{ ---- The encoder ---------------------------------------------------------

  The inverse of ZTDecode, and it lives here rather than in zdict so that the
  alphabet table has exactly one definition. Two copies would disagree inside
  six months, which is the same argument that keeps one decoder serving both
  output sinks.

  A v3 dictionary word is SIX z-chars in two words, the second with bit 15
  set, padded with z-char 5. Verified against all 684 entries of Zork I
  release 119: every one re-encodes byte-exact, including `$ve' (the ZSCII
  escape), `.' (bare A2 punctuation) and `air-p' (truncated mid-word).

  TRUNCATION CAN CUT AN ESCAPE IN HALF. A 10-bit ZSCII escape is four z-chars;
  if only two slots remain, two of them are simply dropped. That is legal and
  Infocom relied on it, which is why z-chars are pushed ONE AT A TIME through
  a bounds-checked helper instead of being assembled in groups and appended.
  --------------------------------------------------------------------------- }

procedure ZTPushZ(v: Word);
begin
  if ZTEncN <= ZT_ENCTOP then
  begin
    ZTEncZ[ZTEncN] := v;
    ZTEncN := ZTEncN + 1;
  end;
end;

{ Encode S into the two words of a v3 dictionary key. }
procedure ZTEncode(var S: String; var w1, w2: Word);
var
  i, c, k, tc, slot: Word;
begin
  for i := 0 to ZT_ENCTOP do ZTEncZ[i] := 5;     { pad }
  ZTEncN := 0;

  i := 1;
  while (i <= Length(S)) and (ZTEncN <= ZT_ENCTOP) do
  begin
    c := Ord(S[i]);

    { Lowercase inline: UpCase and its inverse are NOT builtins here, and a v3
      dictionary is lowercase throughout -- a capitalised input would miss
      every lookup silently. }
    if (c >= 65) and (c <= 90) then c := c + 32;

    if c = 32 then ZTPushZ(0)                    { space is z-char 0 in ANY
                                                   alphabet, not an A2 entry }
    else if (c >= 97) and (c <= 122) then ZTPushZ(c - 97 + 6)
    else
    begin
      { A2 search. Start at 2: index 0 is the escape slot and index 1 the
        newline slot, neither of which is a character. }
      slot := 0;
      k := 2;
      while k <= ZT_A2TOP do
      begin
        if k = 19 then tc := ZT_QUOTE            { the two characters lifted }
        else if k = 21 then tc := ZT_BACKSLASH   { out of the table }
        else tc := Ord(ZT_A2TAB[k]);
        if tc = c then
        begin
          slot := k + 6;
          Break;
        end;
        k := k + 1;
      end;

      if slot <> 0 then
      begin
        ZTPushZ(5);
        ZTPushZ(slot);
      end
      else
      begin
        { Not in any alphabet: 10-bit ZSCII escape, high 5 bits then low 5. }
        ZTPushZ(5);
        ZTPushZ(6);
        ZTPushZ((c shr 5) and 31);
        ZTPushZ(c and 31);
      end;
    end;

    i := i + 1;
  end;

  w1 := (ZTEncZ[0] shl 10) or (ZTEncZ[1] shl 5) or ZTEncZ[2];
  w2 := (ZTEncZ[3] shl 10) or (ZTEncZ[4] shl 5) or ZTEncZ[5] or $8000;
end;
