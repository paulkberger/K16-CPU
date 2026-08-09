{ ---------------------------------------------------------------------------
  zdis.pas -- Z-machine v3 instruction decoder                K16 Pascal, Part 26

  Include AFTER zmem.pas and ztext.pas.

  Decodes the instruction at the cursor and leaves the cursor immediately past
  it -- past the operands, the store byte, the branch bytes and any inline
  string. Nothing is executed and nothing is written to story memory.

  ---- THE CURSOR IS THE PC -------------------------------------------------

  This is the whole reason the module is this small. A branch target is
  `where the cursor is now, plus offset, minus 2', evaluated at the point the
  branch data has just been consumed. There is no instruction-length
  arithmetic anywhere, and instruction length is the single most error-prone
  quantity in this format -- operands are 1 or 2 bytes depending on a type
  field, the store byte is present for some opcodes only, the branch is 1 or 2
  bytes depending on a bit inside itself, and print/print_ret carry an inline
  string of unbounded length.

  ---- The three forms (Standard 1.1 s4.3) ----------------------------------

    b >= $C0    VARIABLE form. Bit 5 selects the operand COUNT, not the form:
                clear -> 2OP, set -> VAR. Opcode number is b and $1F. A type
                byte follows, four 2-bit fields, high pair first, and the
                first $03 (omitted) ends the list.

    $80..$BF    SHORT form. (b shr 4) and 3 is the operand type; $03 means no
                operand at all, so the instruction is 0OP. Opcode is b and $0F.

    b < $80     LONG form, always 2OP. Opcode is b and $1F. Bit 6 gives the
                type of the first operand and bit 5 the second, but only as
                one bit each: clear = small constant, set = variable. A long
                form can never carry a large constant.

  Operand types: 0 large constant (2 bytes), 1 small constant (1 byte),
  2 variable (1 byte), 3 omitted.

  ---- Branches -------------------------------------------------------------

  One byte, or two. Bit 7 is the POLARITY -- branch when the condition
  matches this bit, so `branch on false' is an encoding, not a separate
  opcode. Bit 6 set means the offset is the remaining 6 bits, unsigned, 0..63.
  Bit 6 CLEAR means a 14-bit SIGNED offset spanning both bytes, and it must be
  sign-extended from bit 13 -- the commonest way to get this wrong is to treat
  it as unsigned and silently never branch backwards.

  Offsets 0 and 1 are not offsets. They mean `return false' and `return true'.

  ---- What still needs a table ---------------------------------------------

  Which opcodes store a result, and which branch, cannot be derived from the
  encoding -- they are properties of the opcode. Both are case statements
  below rather than data tables, because the compiler has no procedure
  pointers and a case is what it generates well.
  --------------------------------------------------------------------------- }

const
  { Operand counts }
  ZC_0OP = 0;  ZC_1OP = 1;  ZC_2OP = 2;  ZC_VAR = 3;

  { Operand types }
  ZOT_LARGE = 0;  ZOT_SMALL = 1;  ZOT_VAR = 2;  ZOT_OMIT = 3;

  ZD_OPTOP = 3;           { at most 4 operands in v3 }

  { Instruction flags, held in ZDFlags and indexed (cls shl 5) or op. }
  ZDF_BRANCH = $01;
  ZDF_STORE  = $02;

  { Branch dispositions }
  ZBR_OFFSET = 0;         { normal: jump by ZIBrOfs }
  ZBR_RFALSE = 1;
  ZBR_RTRUE  = 2;

var
  ZIClass  : Word;                        { ZC_* }
  ZIOpcode : Word;                        { opcode number within its class }
  ZINOps   : Word;
  ZIOpT    : array[0..ZD_OPTOP] of Word;
  ZIOpV    : array[0..ZD_OPTOP] of Word;

  ZIStore  : Boolean;
  ZIStoreV : Word;

  ZIBranch : Boolean;
  ZIBrOn   : Boolean;                     { branch when the test equals this }
  ZIBrWhat : Word;                        { ZBR_* }
  ZIBrOfs  : Word;                        { signed 14-bit, held as a Word }

  ZIText   : Boolean;                     { an inline string was consumed }

  { Inline strings are always CONSUMED -- the cursor must end up past them
    either way -- but whether they are also PRINTED depends on the caller.
    zdistest decodes without executing and wants silence; zexec is running
    print/print_ret and wants the text. Decoding to the buffer and printing
    that afterwards is not an option: ZTBuf caps at 255 characters and Zork's
    room descriptions are longer. }
  ZDPrintText : Boolean;

  { Byte address of the instruction just decoded, as (page-relative, offset).
    Captured before anything is consumed so a caller can report it. }
  ZIAtOfs  : Word;
  ZIAtPage : Word;

  { Byte address of the BRANCH DATA of the instruction just decoded, captured
    the same way. Meaningful only when ZIBranch.

    This exists for `save'. Quetzal s5.8.1 requires a v3 save file to record
    the address of the save instruction's branch bytes -- not the instruction,
    and not what follows it -- because that is where a restore resumes: it
    seeks there, decodes the branch it finds, and takes it as though the save
    had succeeded. Since the cursor IS the PC and the decoder has already run
    past the branch data by the time zexec sees the opcode, the address has to
    be captured on the way through. }
  ZIBrAtOfs  : Word;
  ZIBrAtPage : Word;

  { Flag byte of the instruction just decoded, read once from ZDFlags so the
    store and branch tests below share a single table access. }
  ZIFlags    : Word;

  { Does this opcode store, does it branch: a function of (class, opcode)
    only, so a table rather than a search. Built by ZDisInit, which
    ZExecInit calls. 128 bytes -- classes are 0..3 and no class exceeds 32
    opcodes, so (cls shl 5) or op cannot collide. }
  ZDFlags    : array[0..127] of Byte;

{ ---- Opcode properties --------------------------------------------------- }

{ ---- Instruction flags ---------------------------------------------------

  Whether an opcode stores a result and whether it branches depends only on
  (class, opcode), so it is a table lookup, not a search.

  It used to be two functions, each a chain of up to twelve or-ed
  comparisons, both called on every decode -- roughly two dozen comparisons
  and two calls per Z-instruction to answer two static questions. Unless the
  compiler short-circuits `or', every one of those comparisons evaluated
  every time, including for the opcode that matched first.

  Index is (cls shl 5) or op. Classes are 0..3 and no class has more than 32
  opcodes, so the two never collide and the table is 128 bytes.

  ZDisInit MUST be called before the first ZDecode. ZExecInit does it. Any
  other program that decodes -- zdistest -- has to call it too, and a table
  left at zero does not fault: it decodes every instruction as neither
  storing nor branching, which desynchronises the stream and produces
  confident nonsense. }

procedure ZDMark(cls, op, f: Word);
var
  i: Word;
begin
  i := (cls shl 5) or op;
  ZDFlags[i] := ZDFlags[i] or f;
end;

procedure ZDisInit;
var
  i: Word;
begin
  i := 0;
  while i <= 127 do
  begin
    ZDFlags[i] := 0;
    i := i + 1;
  end;

  { 2OP branch: je, jl, jg, dec_chk, inc_chk, jin, test, test_attr }
  ZDMark(ZC_2OP, $01, ZDF_BRANCH);  ZDMark(ZC_2OP, $02, ZDF_BRANCH);
  ZDMark(ZC_2OP, $03, ZDF_BRANCH);  ZDMark(ZC_2OP, $04, ZDF_BRANCH);
  ZDMark(ZC_2OP, $05, ZDF_BRANCH);  ZDMark(ZC_2OP, $06, ZDF_BRANCH);
  ZDMark(ZC_2OP, $07, ZDF_BRANCH);  ZDMark(ZC_2OP, $0A, ZDF_BRANCH);

  { 1OP branch: jz, get_sibling, get_child -- the latter two ALSO store }
  ZDMark(ZC_1OP, $00, ZDF_BRANCH);  ZDMark(ZC_1OP, $01, ZDF_BRANCH);
  ZDMark(ZC_1OP, $02, ZDF_BRANCH);

  { 0OP branch: save, restore, verify. In v3 these BRANCH; v4 makes
    save/restore store instead, which is a classic way to break a v4 port
    quietly. }
  ZDMark(ZC_0OP, $05, ZDF_BRANCH);  ZDMark(ZC_0OP, $06, ZDF_BRANCH);
  ZDMark(ZC_0OP, $0D, ZDF_BRANCH);

  { 2OP store: or, and, loadw, loadb, get_prop, get_prop_addr,
    get_next_prop, add, sub, mul, div, mod }
  ZDMark(ZC_2OP, $08, ZDF_STORE);   ZDMark(ZC_2OP, $09, ZDF_STORE);
  ZDMark(ZC_2OP, $0F, ZDF_STORE);   ZDMark(ZC_2OP, $10, ZDF_STORE);
  ZDMark(ZC_2OP, $11, ZDF_STORE);   ZDMark(ZC_2OP, $12, ZDF_STORE);
  ZDMark(ZC_2OP, $13, ZDF_STORE);   ZDMark(ZC_2OP, $14, ZDF_STORE);
  ZDMark(ZC_2OP, $15, ZDF_STORE);   ZDMark(ZC_2OP, $16, ZDF_STORE);
  ZDMark(ZC_2OP, $17, ZDF_STORE);   ZDMark(ZC_2OP, $18, ZDF_STORE);

  { 1OP store: get_sibling, get_child, get_parent, get_prop_len, load, not }
  ZDMark(ZC_1OP, $01, ZDF_STORE);   ZDMark(ZC_1OP, $02, ZDF_STORE);
  ZDMark(ZC_1OP, $03, ZDF_STORE);   ZDMark(ZC_1OP, $04, ZDF_STORE);
  ZDMark(ZC_1OP, $0E, ZDF_STORE);   ZDMark(ZC_1OP, $0F, ZDF_STORE);

  { VAR store: call, random. Nothing in VAR branches in v3, and nothing in
    0OP stores. }
  ZDMark(ZC_VAR, $00, ZDF_STORE);   ZDMark(ZC_VAR, $07, ZDF_STORE);
end;

function ZDBranches(cls, op: Word): Boolean;
begin
  ZDBranches := (ZDFlags[(cls shl 5) or op] and ZDF_BRANCH) <> 0;
end;

function ZDStores(cls, op: Word): Boolean;
begin
  ZDStores := (ZDFlags[(cls shl 5) or op] and ZDF_STORE) <> 0;
end;

function ZDHasText(cls, op: Word): Boolean;
begin
  ZDHasText := (cls = ZC_0OP) and ((op = $02) or (op = $03));
end;

{ ---- Operand fetch ------------------------------------------------------- }

procedure ZDFetchOperand(t: Word);
var
  hi: Word;
begin
  ZIOpT[ZINOps] := t;
  if t = ZOT_LARGE then
  begin
    hi := MemNextByte;
    ZIOpV[ZINOps] := (hi shl 8) or MemNextByte;
  end
  else ZIOpV[ZINOps] := MemNextByte;      { small constant or variable number }
  ZINOps := ZINOps + 1;
end;

{ ---- Branch data ---------------------------------------------------------

  Split out of ZDecode in Part 27 because `restore' has to decode a branch on
  its own: Quetzal hands back a PC pointing at the branch bytes of the SAVE
  instruction that wrote the file, and the restoring interpreter must decode
  what it finds there and take it as true (s5.8.1). That is a branch decode
  with no instruction in front of it.

  Duplicating these twenty lines in zsave was the alternative, and the
  sign-extension below is exactly the kind of detail that would have been
  copied once and then fixed in only one of the two places. }

procedure ZDDecodeBranch;
var
  b1, b2: Word;
begin
  ZIBrAtOfs  := MemTellOfs;
  ZIBrAtPage := MemTellPage;

  ZIBranch := True;
  b1 := MemNextByte;
  ZIBrOn := (b1 and $80) <> 0;

  if (b1 and $40) <> 0 then ZIBrOfs := b1 and $3F     { 6-bit, unsigned }
  else
  begin
    b2 := MemNextByte;
    ZIBrOfs := ((b1 and $3F) shl 8) or b2;
    { Sign-extend from bit 13. Without this a backward branch reads as a
      large positive offset and the interpreter walks off into data. }
    if (ZIBrOfs and $2000) <> 0 then ZIBrOfs := ZIBrOfs or $C000;
  end;

  { 0 and 1 are not offsets. }
  if ZIBrOfs = 0 then ZIBrWhat := ZBR_RFALSE
  else if ZIBrOfs = 1 then ZIBrWhat := ZBR_RTRUE
  else ZIBrWhat := ZBR_OFFSET;
end;

{ ---- The decoder --------------------------------------------------------- }

procedure ZDecode;
var
  b, tb, t, i: Word;
begin
  ZIAtOfs  := MemTellOfs;
  ZIAtPage := MemTellPage;

  ZINOps   := 0;
  ZIStore  := False;
  ZIStoreV := 0;
  ZIBranch := False;
  ZIBrOn   := False;
  ZIBrWhat := ZBR_OFFSET;
  ZIBrOfs  := 0;
  ZIText   := False;

  b := MemNextByte;

  if b >= $C0 then
  begin
    { VARIABLE form. Bit 5 selects the COUNT: clear = 2OP, set = VAR. }
    ZIOpcode := b and $1F;
    if (b and $20) = 0 then ZIClass := ZC_2OP else ZIClass := ZC_VAR;

    tb := MemNextByte;
    i  := 0;
    while i <= ZD_OPTOP do
    begin
      t := (tb shr (6 - (i * 2))) and 3;
      if t = ZOT_OMIT then Break;         { the first omitted ends the list }
      ZDFetchOperand(t);
      i := i + 1;
    end;
  end
  else if b >= $80 then
  begin
    { SHORT form. The type field doubles as the operand count. }
    ZIOpcode := b and $0F;
    t := (b shr 4) and 3;
    if t = ZOT_OMIT then ZIClass := ZC_0OP
    else
    begin
      ZIClass := ZC_1OP;
      ZDFetchOperand(t);
    end;
  end
  else
  begin
    { LONG form, always 2OP. One bit per operand: clear = small constant,
      set = variable. A large constant cannot be encoded in long form. }
    ZIClass  := ZC_2OP;
    ZIOpcode := b and $1F;
    if (b and $40) = 0 then ZDFetchOperand(ZOT_SMALL)
    else ZDFetchOperand(ZOT_VAR);
    if (b and $20) = 0 then ZDFetchOperand(ZOT_SMALL)
    else ZDFetchOperand(ZOT_VAR);
  end;

  { Inline text comes BEFORE the branch would, and neither print nor
    print_ret branches, so the ordering is not observable -- but it must come
    before the store test or the string's first byte is eaten as a store
    variable. Decoded into the buffer and discarded: ZTDecode is what knows
    where a Z-string ends, and duplicating that here is how the two would
    drift apart. }
  if ZDHasText(ZIClass, ZIOpcode) then
  begin
    ZIText  := True;
    if ZDPrintText then ZTToBuf := False
    else
    begin
      ZTToBuf := True;
      ZTReset;
    end;
    ZTDecode;
    ZTToBuf := False;
  end;

  ZIFlags := ZDFlags[(ZIClass shl 5) or ZIOpcode];   { one lookup, both tests }

  if (ZIFlags and ZDF_STORE) <> 0 then
  begin
    ZIStore  := True;
    ZIStoreV := MemNextByte;
  end;

  if (ZIFlags and ZDF_BRANCH) <> 0 then ZDDecodeBranch;
end;
