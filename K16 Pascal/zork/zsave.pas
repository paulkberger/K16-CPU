{ ---------------------------------------------------------------------------
  zsave.pas -- Quetzal save, restore and restart             K16 Pascal, Part 27

  Include AFTER zmem, ztext, zdis and zstate, and BEFORE zexec.

  Writes and reads the Quetzal 1.4 save format (Martin Frost, 03-Nov-97), so
  a save written here restores under Frotz and a save written by Frotz
  restores here. That interoperability is not a courtesy: a round trip
  through our own code is equally happy if the frames are written wrongly and
  read back wrongly in the same way, and only a second implementation can
  tell the difference.

  ---- What a saved game actually is ----------------------------------------

  Three things, and nothing else:

    1. dynamic memory     bytes 0 .. ZStatic-1   (11,282 in Zork I)
    2. the stacks         call frames and the evaluation stack
    3. the PC

  Everything above ZStatic is read-only for the lifetime of the story and is
  reconstructed from the story file, never stored. Infocom's own interpreters
  saved the same three things in private layouts; Quetzal is that content in
  an IFF wrapper, with a story-identity check and optional compression.

  ---- The two extra pages --------------------------------------------------

  ZPgOrig holds dynamic memory exactly as it came off disk, captured before
  ZSetHeaderFlags stamps the interpreter's own bits. It is the XOR baseline
  CMem is defined against (s3.2) and the source `restart' copies back.

  ZPgStage is where a restore is assembled. Nothing a restore reads touches
  the running game until every chunk has been read and checked, so a
  truncated or corrupt save file is a clean refusal rather than a half-loaded
  machine. Dynamic memory stages at offset 0; the Stks chunk stages at
  ZSTK_STAGE, above ZDYN_MAX, so the two cannot collide.

  ---- Lengths are counted, never backpatched -------------------------------

  files.pas has no FileSeek, so a chunk length cannot be written as zero and
  fixed up afterwards. Every length is therefore computed before it is
  written: IFhd is a constant 13, Stks is arithmetic over the frames, and
  CMem runs its encoder twice through ZQCMem -- once with emit False to
  count, once with emit True to write. Two passes over the same deterministic
  loop cannot disagree; a backpatch that silently failed could.

  ---- Signedness -----------------------------------------------------------

  ZQBN and ZQBI are Integer, not Word, and deliberately so. FileRead returns
  -1 on error, and a buffer count that has to be compared against -1 and
  against 512 in the same routine must be signed throughout or one of the two
  comparisons picks the wrong branch (Part 24 s5.1).
  --------------------------------------------------------------------------- }

const
  ZQ_BUFTOP  = 511;       { I/O buffer, inclusive upper bound }
  ZQ_BUFN    = 512;

  { Where the Stks chunk stages inside ZPgStage. Above ZDYN_MAX, so dynamic
    memory (staged at offset 0) can never reach it. }
  ZSTK_STAGE = $8000;

  { Largest Stks chunk this build can hold:
      (ZF_TOP+1) * 8            frame headers        512
      (ZLOC_TOP+1) * 2          locals              1920
      (ZS_TOP+1) * 2            evaluation stack    2048
                                                    ---- 4480 }
  ZSTK_MAX   = 4480;

  { IFF identifiers, as the two big-endian words they are on the wire.
    Compared numerically rather than as strings: four bytes in, two CMPs,
    and no string machinery on a path that runs before anything is trusted. }
  ZQ_FORM_HI = $464F;  ZQ_FORM_LO = $524D;        { 'FORM' }
  ZQ_IFZS_HI = $4946;  ZQ_IFZS_LO = $5A53;        { 'IFZS' }
  ZQ_IFHD_HI = $4946;  ZQ_IFHD_LO = $6864;        { 'IFhd' }
  ZQ_CMEM_HI = $434D;  ZQ_CMEM_LO = $656D;        { 'CMem' }
  ZQ_UMEM_HI = $554D;  ZQ_UMEM_LO = $656D;        { 'UMem' }
  ZQ_STKS_HI = $5374;  ZQ_STKS_LO = $6B73;        { 'Stks' }

  ZQ_IFHD_LEN = 13;     { s5.4.2 -- odd, so it carries a pad byte (s5.7) }

  { Quetzal frame flags byte, 000pvvvv (s4.3.2) }
  ZQ_FLAG_DISCARD = $10;
  ZQ_FLAG_NLOC    = $0F;

  { ---- ZQErr ---- }
  ZQE_OK      = 0;
  ZQE_OPEN    = 2;
  ZQE_IO      = 3;      { short read or short write }
  ZQE_FORM    = 4;      { not an IFF FORM of type IFZS }
  ZQE_HDR     = 5;      { IFhd missing, late, or for a different story }
  ZQE_MEM     = 6;      { CMem/UMem malformed or the wrong size }
  ZQE_STKS    = 7;      { Stks malformed or too big for this build }
  ZQE_PARTIAL = 8;      { a required chunk never appeared }
  ZQE_TOOBIG  = 9;      { this story's dynamic memory exceeds ZDYN_MAX }

var
  ZQFd    : Integer;
  ZQBuf   : array[0..ZQ_BUFTOP] of Byte;
  ZQBN    : Integer;                      { bytes live in the buffer }
  ZQBI    : Integer;                      { read cursor within the buffer }
  ZQIOErr : Boolean;
  ZQEof   : Boolean;
  ZQErr   : Word;

  ZQName  : String;                       { default / last used save file }
  ZQIn    : String;                       { the prompt's input line }

  ZQLenHi : Word;                         { high word of the last chunk length }
  ZQDisc  : Word;                         { sink for results that must be
                                            consumed but not used }
  ZQStkLen: Word;                         { bytes of Stks staged }

  { The PC read from IFhd, held until the commit. Not applied as it is read:
    a file that fails later must leave the cursor where it was. }
  ZQPCOfs : Word;
  ZQPCPage: Word;

{ ---- Buffered output ----------------------------------------------------- }

procedure ZQFlush;
var
  n: Integer;
begin
  if ZQBN = 0 then Exit;
  n := FileWrite(ZQFd, @ZQBuf, ZQBN);
  if n <> ZQBN then ZQIOErr := True;
  ZQBN := 0;
end;

procedure ZQPut(v: Word);
begin
  if ZQBN >= ZQ_BUFN then ZQFlush;
  ZQBuf[ZQBN] := v and $FF;
  ZQBN := ZQBN + 1;
end;

procedure ZQPutW(v: Word);
begin
  ZQPut(v shr 8);
  ZQPut(v and $FF);
end;

{ A 32-bit big-endian length. The high word is always zero here and that is a
  guaranteed property, not an assumption: ZDYN_MAX caps dynamic memory at
  32 KB, the worst case CMem expansion is 1.5x (alternating zero and non-zero
  bytes), Stks caps at ZSTK_MAX, and the total therefore cannot reach 64 KB. }
procedure ZQPutL(v: Word);
begin
  ZQPut(0);
  ZQPut(0);
  ZQPut(v shr 8);
  ZQPut(v and $FF);
end;

procedure ZQPutID(hi, lo: Word);
begin
  ZQPutW(hi);
  ZQPutW(lo);
end;

{ s8.4.1: a chunk of odd length is followed by a zero byte which is NOT
  counted in the length. Omitting it is the classic way to produce a file
  that this interpreter reads back perfectly and every other one rejects. }
procedure ZQPad(n: Word);
begin
  if (n and 1) <> 0 then ZQPut(0);
end;

{ ---- Buffered input ------------------------------------------------------ }

function ZQGet: Word;
begin
  ZQGet := 0;
  if ZQBI >= ZQBN then
  begin
    ZQBN := FileRead(ZQFd, @ZQBuf, ZQ_BUFN);
    ZQBI := 0;
    if ZQBN < 0 then
    begin
      ZQBN   := 0;
      ZQIOErr := True;
      ZQEof   := True;
      Exit;
    end;
    if ZQBN = 0 then
    begin
      ZQEof := True;
      Exit;
    end;
  end;
  ZQGet := ZQBuf[ZQBI];
  ZQBI  := ZQBI + 1;
end;

function ZQGetW: Word;
var
  hi: Word;
begin
  hi := ZQGet;
  ZQGetW := (hi shl 8) or ZQGet;
end;

{ Reads four bytes, returns the low word and leaves the high word in ZQLenHi.
  A caller that ignores ZQLenHi accepts a length it cannot represent, so
  every caller tests it. }
function ZQGetL: Word;
var
  hi: Word;
begin
  hi      := ZQGetW;
  ZQLenHi := hi;
  ZQGetL  := ZQGetW;
end;

procedure ZQSkip(n: Word);
var
  i: Word;
begin
  i := 0;
  while (i < n) and not ZQEof do
  begin
    ZQDisc := ZQGet;
    i := i + 1;
  end;
end;

procedure ZQSkipPad(n: Word);
begin
  if (n and 1) <> 0 then ZQDisc := ZQGet;
end;

{ ---- The staging page ---------------------------------------------------- }

function ZQStkB(o: Word): Word;
begin
  ZQStkB := MemGetByte(ZSTK_STAGE + o, ZPgStage);
end;

function ZQStkW(o: Word): Word;
var
  hi: Word;
begin
  hi := ZQStkB(o);
  ZQStkW := (hi shl 8) or ZQStkB(o + 1);
end;

{ ---- Frame geometry ------------------------------------------------------

  Frame f's evaluation stack runs from ZFFloor[f] up to the floor of the
  frame above it, or to ZSP for the topmost frame. This is the only place
  that relationship is written down, so both the length pass and the write
  pass go through it rather than each open-coding the same conditional. }

function ZQFrameTop(f: Word): Word;
begin
  if f >= ZFP then ZQFrameTop := ZSP
  else ZQFrameTop := ZFFloor[f + 1];
end;

function ZQStksLen: Word;
var
  f, n: Word;
begin
  n := 0;
  f := 0;
  while f <= ZFP do
  begin
    n := n + 8 + (ZFNLoc[f] shl 1);
    n := n + ((ZQFrameTop(f) - ZFFloor[f]) shl 1);
    f := f + 1;
  end;
  ZQStksLen := n;
end;

{ ---- CMem ----------------------------------------------------------------

  s3.2: XOR the current contents of dynamic memory against the original, then
  run-length encode the result. A non-zero byte stands for itself; a zero byte
  is followed by a length byte n and the pair means n+1 zeros. The cap is
  therefore 256 zeros per pair, and a longer run becomes several pairs.

  Called twice per save: emit False counts, emit True writes. }

function ZQCMem(emit: Boolean): Word;
var
  a, d, run, n: Word;
begin
  n   := 0;
  run := 0;
  a   := 0;
  while a < ZStatic do
  begin
    d := ZByte(a) xor MemGetByte(a, ZPgOrig);
    if d = 0 then
    begin
      run := run + 1;
      if run = 256 then
      begin
        n := n + 2;
        if emit then
        begin
          ZQPut(0);
          ZQPut(255);
        end;
        run := 0;
      end;
    end
    else
    begin
      if run > 0 then
      begin
        n := n + 2;
        if emit then
        begin
          ZQPut(0);
          ZQPut(run - 1);
        end;
        run := 0;
      end;
      n := n + 1;
      if emit then ZQPut(d);
    end;
    a := a + 1;
  end;

  { s3.4 permits trailing zero runs to be dropped, since a short CMem means
    "the rest is unchanged". Not done: the saving is a handful of bytes and
    emitting the run keeps this a single unconditional pass. Readers must
    handle the short form regardless, and ZQReadCMem does. }
  if run > 0 then
  begin
    n := n + 2;
    if emit then
    begin
      ZQPut(0);
      ZQPut(run - 1);
    end;
  end;

  ZQCMem := n;
end;

{ ---- Stks ----------------------------------------------------------------

  s4.3, one frame:

      3 bytes   return PC, a byte offset from story byte 0
      1 byte    000pvvvv   p = result discarded, vvvv = number of locals
      1 byte    result variable, 0 when p is set
      1 byte    0gfedcba   arguments supplied
      1 word    n, words of evaluation stack this frame owns
      v words   locals
      n words   evaluation stack

  Oldest first (s4.2), and frame 0 is the dummy frame (s4.11) which holds
  whatever was pushed before the first call. It is written all-zero except n,
  regardless of what ZFRetVar[0] happens to hold internally -- the spec is
  explicit, and an interpreter that reads a non-zero variable number there
  may well act on it. }

procedure ZQWriteFrame(f: Word);
var
  i, n, base, top, flags, args: Word;
begin
  top := ZQFrameTop(f);
  n   := top - ZFFloor[f];

  if f = 0 then
  begin
    ZQPut(0); ZQPut(0); ZQPut(0);         { PC }
    ZQPut(0);                             { flags }
    ZQPut(0);                             { result variable }
    ZQPut(0);                             { arguments supplied }
  end
  else
  begin
    ZQPut(ZFPCPage[f] - ZPg0);
    ZQPut(ZFPCOfs[f] shr 8);
    ZQPut(ZFPCOfs[f] and $FF);

    flags := ZFNLoc[f] and ZQ_FLAG_NLOC;
    if ZFRetVar[f] = ZRETVAR_NONE then flags := flags or ZQ_FLAG_DISCARD;
    ZQPut(flags);

    if ZFRetVar[f] = ZRETVAR_NONE then ZQPut(0)
    else ZQPut(ZFRetVar[f]);

    { s4.7: one bit per supplied argument, a is the first. v3 calls carry at
      most three, so this never exceeds $07. }
    args := 0;
    i := 0;
    while i < ZFArgs[f] do
    begin
      args := args or (1 shl i);
      i := i + 1;
    end;
    ZQPut(args);
  end;

  ZQPutW(n);

  base := f * ZL_COUNT;
  i := 0;
  while i < ZFNLoc[f] do
  begin
    ZQPutW(ZLocals[base + i]);
    i := i + 1;
  end;

  i := ZFFloor[f];
  while i < top do
  begin
    ZQPutW(ZStack[i]);
    i := i + 1;
  end;
end;

procedure ZQWriteStks;
var
  f: Word;
begin
  f := 0;
  while f <= ZFP do
  begin
    ZQWriteFrame(f);
    f := f + 1;
  end;
end;

{ ---- The save file name --------------------------------------------------

  Derived from the story argument with its extension replaced, so a save
  lands beside the story it belongs to and inherits whatever drive or path
  qualification was typed. `.SAV' rather than `.QZL': the Quetzal spec names
  no extension at all, and `.SAV' is what Frotz writes and therefore what is
  most likely to be recognised at the far end. }

procedure ZQSetDefaultName(var fn: String);
var
  i, cut: Word;
  stop  : Boolean;
begin
  cut  := Length(fn);
  i    := Length(fn);
  stop := False;
  while (i > 0) and not stop do
  begin
    if (fn[i] = '\') or (fn[i] = ':') then stop := True
    else if fn[i] = '.' then
    begin
      cut  := i - 1;
      stop := True;
    end;
    i := i - 1;
  end;

  { Length byte first, then the characters. Writing through the index before
    the length is set addresses storage the string does not yet claim. }
  ZQName[0] := Chr(cut);
  i := 1;
  while i <= cut do
  begin
    ZQName[i] := fn[i];
    i := i + 1;
  end;
  ZQName := ZQName + '.SAV';
end;

function ZQHasDot(var s: String): Boolean;
var
  i   : Word;
  stop: Boolean;
begin
  ZQHasDot := False;
  i    := Length(s);
  stop := False;
  while (i > 0) and not stop do
  begin
    if (s[i] = '\') or (s[i] = ':') then stop := True
    else if s[i] = '.' then
    begin
      ZQHasDot := True;
      stop := True;
    end;
    i := i - 1;
  end;
end;

{ Prompt, and leave the answer in ZQName. Blank keeps the current default,
  which after a save is the file just written -- so `save' then `restore'
  needs one keystroke.

  There is deliberately no overwrite confirmation. Saving is frequent enough
  that a prompt on every one trains the player to answer it without reading,
  which is worse than not asking. }
procedure ZQAskName(saving: Boolean);
begin
  if (ZOutCol > 0) or (ZOutWLen > 0) then ZOutNewLine;
  ZOutFlushWord;

  if saving then Write('[Save to (') else Write('[Restore from (');
  Write(ZQName);
  Write('): ');
  ReadLn(ZQIn);
  ZOutCol := 0;

  if Length(ZQIn) > 0 then
  begin
    if not ZQHasDot(ZQIn) then ZQIn := ZQIn + '.SAV';
    ZQName := ZQIn;
  end;
end;

procedure ZQErrMsg;
begin
  case ZQErr of
    ZQE_OK      : Write('ok');
    ZQE_OPEN    : Write('cannot open ');
    ZQE_IO      : Write('read/write error');
    ZQE_FORM    : Write('not a Quetzal save file');
    ZQE_HDR     : Write('that save belongs to a different story');
    ZQE_MEM     : Write('the memory chunk is damaged');
    ZQE_STKS    : Write('the stack chunk is damaged or too large');
    ZQE_PARTIAL : Write('the save file is incomplete');
    ZQE_TOOBIG  : Write('this story has too much dynamic memory to save');
  else
    Write('unknown error');
  end;
  if ZQErr = ZQE_OPEN then Write(ZQName);
end;

procedure ZQReport(saving: Boolean);
begin
  Write('[');
  if saving then Write('Save failed: ') else Write('Restore failed: ');
  ZQErrMsg;
  WriteLn(']');
  ZOutCol := 0;
end;

{ ---- Save ----------------------------------------------------------------

  pcofs/pcpage are the address of the save instruction's BRANCH BYTES, not
  the address of the instruction. s5.8.1 is explicit for v3, and it is what
  makes restore work: the restoring interpreter seeks there, decodes the
  branch it finds, and takes it as though the save had succeeded. Any other
  convention produces a file only this interpreter can read. }

function ZQSave(pcofs, pcpage: Word): Boolean;
var
  cmemlen, stkslen, formlen, i: Word;
begin
  ZQSave := False;
  ZQErr  := ZQE_OK;

  if ZStatic > ZDYN_MAX then
  begin
    ZQErr := ZQE_TOOBIG;
    ZQReport(True);
    Exit;
  end;

  ZQAskName(True);

  ZQFd := FileOpen(ZQName, FOPEN_WRITE + FOPEN_CREATE + FOPEN_TRUNC);
  if ZQFd < 0 then
  begin
    ZQErr := ZQE_OPEN;
    ZQReport(True);
    Exit;
  end;

  ZQBN    := 0;
  ZQIOErr := False;

  cmemlen := ZQCMem(False);               { counting pass }
  stkslen := ZQStksLen;

  formlen := 4;                                     { the IFZS sub-identifier }
  formlen := formlen + 8 + ZQ_IFHD_LEN + 1;         { IFhd, always odd + pad }
  formlen := formlen + 8 + cmemlen;
  if (cmemlen and 1) <> 0 then formlen := formlen + 1;
  formlen := formlen + 8 + stkslen;
  if (stkslen and 1) <> 0 then formlen := formlen + 1;

  ZQPutID(ZQ_FORM_HI, ZQ_FORM_LO);
  ZQPutL(formlen);
  ZQPutID(ZQ_IFZS_HI, ZQ_IFZS_LO);

  { ---- IFhd (s5.4) ---- }
  ZQPutID(ZQ_IFHD_HI, ZQ_IFHD_LO);
  ZQPutL(ZQ_IFHD_LEN);
  ZQPutW(ZRelease);
  i := 1;
  while i <= 6 do
  begin
    ZQPut(Ord(ZSerial[i]));
    i := i + 1;
  end;
  ZQPutW(ZCkHdr);
  ZQPut(pcpage - ZPg0);
  ZQPut(pcofs shr 8);
  ZQPut(pcofs and $FF);
  ZQPad(ZQ_IFHD_LEN);

  { ---- CMem (s3.7) ---- }
  ZQPutID(ZQ_CMEM_HI, ZQ_CMEM_LO);
  ZQPutL(cmemlen);
  ZQDisc := ZQCMem(True);                 { emitting pass }
  ZQPad(cmemlen);

  { ---- Stks (s4.10) ---- }
  ZQPutID(ZQ_STKS_HI, ZQ_STKS_LO);
  ZQPutL(stkslen);
  ZQWriteStks;
  ZQPad(stkslen);

  ZQFlush;
  FileClose(ZQFd);

  if ZQIOErr then
  begin
    ZQErr := ZQE_IO;
    ZQReport(True);
    Exit;
  end;

  ZQSave := True;
end;

{ ---- Restore: chunk readers ----------------------------------------------

  Each returns True on success and leaves the file positioned immediately
  after the chunk's data, pad byte excluded -- the caller consumes that. }

function ZQReadIFhd(len: Word): Boolean;
var
  i, rel, ck, b0, b1, b2: Word;
  ok: Boolean;
begin
  ZQReadIFhd := False;
  if len < ZQ_IFHD_LEN then
  begin
    ZQErr := ZQE_FORM;
    Exit;
  end;

  rel := ZQGetW;

  { The serial is compared in place rather than assembled into a string:
    six byte compares against ZSerial, no allocation, and no dependence on
    string equality at a point where nothing in the file is trusted yet. }
  ok := True;
  i := 1;
  while i <= 6 do
  begin
    if ZQGet <> Ord(ZSerial[i]) then ok := False;
    i := i + 1;
  end;

  ck := ZQGetW;
  b0 := ZQGet;
  b1 := ZQGet;
  b2 := ZQGet;

  { s5.5 allows a future IFhd to be longer; the first 13 bytes are fixed. }
  ZQSkip(len - ZQ_IFHD_LEN);

  if ZQEof then
  begin
    ZQErr := ZQE_FORM;
    Exit;
  end;

  { s5.3: release, serial and checksum together identify the story. All
    three, not one: release numbers repeat across Infocom's catalogue. }
  if (rel <> ZRelease) or (ck <> ZCkHdr) or not ok then
  begin
    ZQErr := ZQE_HDR;
    Exit;
  end;

  ZQPCPage := ZPg0 + b0;
  ZQPCOfs  := (b1 shl 8) or b2;
  ZQReadIFhd := True;
end;

{ Pre-fill the staging area with the original. Every position the encoded
  data leaves alone -- a zero run, or the tail of a short CMem (s3.4) -- is
  then already correct, and the decoder only has to write where the delta is
  non-zero.

  ---- Why the cursor is saved and put back ---------------------------------

  MemCopyTo copies FROM the cursor, so it moves it. The cursor is the Z-machine
  PC. This runs mid-instruction, inside `restore', and a restore that FAILS
  must branch false and carry on executing -- from the PC it had on entry.

  ZBranch computes its target relative to wherever the cursor is, so leaving
  it parked at the end of dynamic memory would not fault: it would branch to
  a plausible-looking address in the middle of the story and execute data.
  The byte-loop version this replaced used MemGetByte/MemPutByte and never
  touched the cursor, so the hazard arrived with the optimisation.

  Saved and restored here rather than in ZQRestore because there are eight
  failure exits in that routine and this is one place. }
procedure ZQStageOriginal;
var
  o, p: Word;
begin
  o := MemTellOfs;
  p := MemTellPage;
  MemSeek(0, ZPgOrig);
  MemCopyTo(0, ZPgStage, ZStatic);
  MemSeek(o, p);
end;

function ZQReadCMem(len: Word): Boolean;
var
  i, a, b, run: Word;
begin
  ZQReadCMem := False;
  ZQStageOriginal;

  a := 0;
  i := 0;
  while i < len do
  begin
    b := ZQGet;
    i := i + 1;
    if ZQEof then
    begin
      ZQErr := ZQE_MEM;
      Exit;
    end;

    if b = 0 then
    begin
      { s3.5: a zero byte with no length byte behind it is an error, not a
        run of one. }
      if i >= len then
      begin
        ZQErr := ZQE_MEM;
        Exit;
      end;
      run := ZQGet + 1;
      i := i + 1;
      if a + run > ZStatic then
      begin
        ZQErr := ZQE_MEM;
        Exit;
      end;
      a := a + run;                       { already the original: skip }
    end
    else
    begin
      if a >= ZStatic then
      begin
        ZQErr := ZQE_MEM;
        Exit;
      end;
      MemPutByte(a, ZPgStage, MemGetByte(a, ZPgOrig) xor b);
      a := a + 1;
    end;
  end;

  ZQReadCMem := True;
end;

{ s3.6: writing UMem is optional, reading it is not. Ten lines, and it makes
  this interpreter able to read a save from anything. }
function ZQReadUMem(len: Word): Boolean;
var
  a: Word;
begin
  ZQReadUMem := False;
  if len <> ZStatic then
  begin
    ZQErr := ZQE_MEM;
    Exit;
  end;
  a := 0;
  while a < len do
  begin
    MemPutByte(a, ZPgStage, ZQGet);
    a := a + 1;
  end;
  if ZQEof then
  begin
    ZQErr := ZQE_MEM;
    Exit;
  end;
  ZQReadUMem := True;
end;

{ Stage the Stks chunk verbatim. Not parsed here: parsing straight into the
  live frame arrays is what would make a corrupt file unrecoverable, and the
  staging page was already bought for CMem and is 90% empty. }
function ZQReadStks(len: Word): Boolean;
var
  i: Word;
begin
  ZQReadStks := False;
  if len > ZSTK_MAX then
  begin
    ZQErr := ZQE_STKS;
    Exit;
  end;
  i := 0;
  while i < len do
  begin
    MemPutByte(ZSTK_STAGE + i, ZPgStage, ZQGet);
    i := i + 1;
  end;
  if ZQEof then
  begin
    ZQErr := ZQE_STKS;
    Exit;
  end;
  ZQStkLen := len;
  ZQReadStks := True;
end;

{ Walk the staged frames reading only the length fields, and prove the chunk
  is exactly consumed and fits this build, before a single live word moves. }
function ZQCheckStks: Boolean;
var
  o, nf, nloc, n, need, tot: Word;
begin
  ZQCheckStks := False;
  o   := 0;
  nf  := 0;
  tot := 0;

  while o < ZQStkLen do
  begin
    if ZQStkLen - o < 8 then Exit;

    nloc := ZQStkB(o + 3) and ZQ_FLAG_NLOC;
    n    := ZQStkW(o + 6);

    if nloc > ZL_COUNT then Exit;

    { n is bounded BEFORE it is doubled. A frame claiming $8000 words would
      otherwise make `n shl 1' wrap to 0, and `need' would then describe a
      frame far shorter than the one being claimed -- the walk would resync
      on garbage and could still land exactly on the chunk end. The running
      total below catches it a line later, but only by arithmetic that has to
      be re-derived every time this is read. This does not. }
    if n > ZS_TOP + 1 then Exit;

    need := 8 + (nloc shl 1) + (n shl 1);
    if need > ZQStkLen - o then Exit;

    tot := tot + n;
    if tot > ZS_TOP + 1 then Exit;

    nf := nf + 1;
    if nf > ZF_TOP + 1 then Exit;

    o := o + need;
  end;

  { Exact consumption, and at least the dummy frame (s4.11.2 guarantees it
    is present on every non-V6 save). }
  if o <> ZQStkLen then Exit;
  if nf = 0 then Exit;

  ZQCheckStks := True;
end;

{ Checked by ZQCheckStks; every bound below is already known to hold. }
procedure ZQCommitStks;
var
  o, f, i, nloc, n, base, flags, args: Word;
begin
  o   := 0;
  f   := 0;
  ZSP := 0;

  while o < ZQStkLen do
  begin
    ZFPCPage[f] := ZPg0 + ZQStkB(o);
    ZFPCOfs[f]  := (ZQStkB(o + 1) shl 8) or ZQStkB(o + 2);

    flags := ZQStkB(o + 3);
    nloc  := flags and ZQ_FLAG_NLOC;
    args  := ZQStkB(o + 5);
    n     := ZQStkW(o + 6);

    ZFNLoc[f] := nloc;

    if (f = 0) or ((flags and ZQ_FLAG_DISCARD) <> 0) then
      ZFRetVar[f] := ZRETVAR_NONE
    else
      ZFRetVar[f] := ZQStkB(o + 4);

    { Back from the bitmap to a count. Contiguous by construction (s4.7), so
      counting set bits from the bottom until one is clear is exact. }
    i := 0;
    while (i < 8) and ((args and (1 shl i)) <> 0) do i := i + 1;
    ZFArgs[f] := i;

    o := o + 8;

    base := f * ZL_COUNT;
    i := 0;
    while i < nloc do
    begin
      ZLocals[base + i] := ZQStkW(o);
      o := o + 2;
      i := i + 1;
    end;

    ZFFloor[f] := ZSP;
    i := 0;
    while i < n do
    begin
      ZStack[ZSP] := ZQStkW(o);
      ZSP := ZSP + 1;
      o := o + 2;
      i := i + 1;
    end;

    f := f + 1;
  end;

  ZFP := f - 1;

  { The one place the product is computed rather than carried: ZFP was
    rebuilt wholesale from the file, so there is nothing to add to. Once per
    restore. }
  ZFBase := ZFP * ZL_COUNT;
end;

{ The last irreversible step, and the smallest one: staged dynamic memory
  over the live story, then reclaim the header bits the interpreter owns.
  ZSetHeaderFlags matters -- the save file carries the header as it was on the
  machine that wrote it, and bits 4/5/6 of Flags1 describe OUR terminal, not
  theirs (Standard 1.1 s11.1). }
procedure ZQCommitMem;
var
  o, p: Word;
begin
  { Cursor-transparent for the same reason as ZQStageOriginal. Belt and
    braces here -- the only caller seeks to the restored PC immediately
    afterwards -- but a routine that silently moved the PC would be a trap
    for whoever calls it next. }
  o := MemTellOfs;
  p := MemTellPage;
  MemSeek(0, ZPgStage);
  MemCopyTo(0, ZPg0, ZStatic);
  MemSeek(o, p);
  ZSetHeaderFlags;
end;

{ ---- Restore -------------------------------------------------------------

  Nothing the running game can see changes until every chunk has been read
  and checked. A file that fails at any point leaves the machine exactly as
  it was, and the caller branches false -- the game says "Failed." in its own
  words and play continues. }

function ZQRestore: Boolean;
var
  idhi, idlo, len: Word;
  gotHdr, gotMem, gotStk, done, bad: Boolean;
begin
  ZQRestore := False;
  ZQErr     := ZQE_OK;

  if ZStatic > ZDYN_MAX then
  begin
    ZQErr := ZQE_TOOBIG;
    ZQReport(False);
    Exit;
  end;

  ZQAskName(False);

  ZQFd := FileOpen(ZQName, FOPEN_READ);
  if ZQFd < 0 then
  begin
    ZQErr := ZQE_OPEN;
    ZQReport(False);
    Exit;
  end;

  ZQBN    := 0;
  ZQBI    := 0;
  ZQEof   := False;
  ZQIOErr := False;
  ZQStkLen := 0;

  gotHdr := False;
  gotMem := False;
  gotStk := False;
  bad    := False;

  idhi := ZQGetW;
  idlo := ZQGetW;
  if (idhi <> ZQ_FORM_HI) or (idlo <> ZQ_FORM_LO) then bad := True;
  ZQDisc := ZQGetL;
  idhi := ZQGetW;
  idlo := ZQGetW;
  if (idhi <> ZQ_IFZS_HI) or (idlo <> ZQ_IFZS_LO) then bad := True;
  if ZQEof then bad := True;
  if bad then ZQErr := ZQE_FORM;

  done := bad;
  while not done do
  begin
    idhi := ZQGetW;
    if ZQEof then done := True
    else
    begin
      idlo := ZQGetW;
      len  := ZQGetL;

      if ZQEof or (ZQLenHi <> 0) then
      begin
        ZQErr := ZQE_FORM;
        bad   := True;
        done  := True;
      end
      else if (idhi = ZQ_IFHD_HI) and (idlo = ZQ_IFHD_LO) then
      begin
        { s8.8: a second IFhd is ignored, not an error. }
        if gotHdr then ZQSkip(len)
        else if ZQReadIFhd(len) then gotHdr := True
        else begin bad := True; done := True; end;
      end
      else if (idhi = ZQ_CMEM_HI) and (idlo = ZQ_CMEM_LO) then
      begin
        { s5.4: IFhd exists so that this decode never happens for the wrong
          story. Reaching a memory chunk without one means the file is
          malformed, and decoding it anyway is exactly the mistake the
          ordering rule was written to prevent. }
        if not gotHdr then
        begin
          ZQErr := ZQE_HDR;
          bad := True; done := True;
        end
        else if gotMem then ZQSkip(len)
        else if ZQReadCMem(len) then gotMem := True
        else begin bad := True; done := True; end;
      end
      else if (idhi = ZQ_UMEM_HI) and (idlo = ZQ_UMEM_LO) then
      begin
        if not gotHdr then
        begin
          ZQErr := ZQE_HDR;
          bad := True; done := True;
        end
        else if gotMem then ZQSkip(len)
        else if ZQReadUMem(len) then gotMem := True
        else begin bad := True; done := True; end;
      end
      else if (idhi = ZQ_STKS_HI) and (idlo = ZQ_STKS_LO) then
      begin
        if not gotHdr then
        begin
          ZQErr := ZQE_HDR;
          bad := True; done := True;
        end
        else if gotStk then ZQSkip(len)
        else if ZQReadStks(len) then gotStk := True
        else begin bad := True; done := True; end;
      end
      else ZQSkip(len);                   { s8.9: skip what we do not know }

      if not done then ZQSkipPad(len);
      if ZQIOErr then
      begin
        ZQErr := ZQE_IO;
        bad := True; done := True;
      end;
    end;
  end;

  FileClose(ZQFd);

  if bad then
  begin
    ZQReport(False);
    Exit;
  end;

  if not (gotHdr and gotMem and gotStk) then
  begin
    ZQErr := ZQE_PARTIAL;
    ZQReport(False);
    Exit;
  end;

  if not ZQCheckStks then
  begin
    ZQErr := ZQE_STKS;
    ZQReport(False);
    Exit;
  end;

  { ---- Commit. Past this line the old state is gone. ---- }

  ZQCommitMem;
  ZQCommitStks;
  MemSeek(ZQPCOfs, ZQPCPage);

  ZQRestore := True;
end;

{ ---- Restart -------------------------------------------------------------

  Dynamic memory is the only part of the story image that ever changes, so a
  restart is a copy from ZPgOrig plus a reset of the machine. That is the
  whole of it.

  The RNG seed is deliberately NOT reseeded. A restart that produced a
  different sequence every time would make any bug found after one
  impossible to reproduce. }

procedure ZQRestart;
begin
  { No cursor save here, and that is the difference: a restart is DEFINED to
    throw the PC away. ZSeek at the end sets it. }
  MemSeek(0, ZPgOrig);
  MemCopyTo(0, ZPg0, ZStatic);
  ZSetHeaderFlags;

  ZSP := 0;
  ZFP := 0;
  ZFBase      := 0;
  ZFFloor[0]  := 0;
  ZFNLoc[0]   := 0;
  ZFArgs[0]   := 0;
  ZFRetVar[0] := ZRETVAR_NONE;

  ZOutNewLine;
  ZSeek(ZInitPC);
end;
