{ ---------------------------------------------------------------------------
  zobj.pas -- Z-machine v3 object table                    K16 Pascal, Part 25

  Include AFTER zmem.pas and ztext.pas.

  ---- Layout (Standard 1.1 s12), all of it inside story page 0 -------------

    ZObjTab + 0            31 words of property defaults, for properties 1..31
    ZObjTab + 62           object 1, then 2, ... each 9 bytes:

        byte 0..3          32 attribute flags, attribute 0 = bit 7 of byte 0
        byte 4             parent object number
        byte 5             sibling
        byte 6             child
        byte 7..8          byte address of this object's property table

  A property table is:

        byte 0             short name length, in WORDS
        the short name     that many words of Z-string
        properties         descending by number, each a size byte then data
        byte 0             terminator

  and a v3 size byte is 32*(len-1) + number, so a property holds 1..8 bytes and
  the number is 1..31. v4+ uses a two-byte form; this module is v3 only and
  will produce nonsense on a v4 story rather than pretend otherwise, which is
  what ZMemInit's version check is there to prevent.

  ---- Object 0 -------------------------------------------------------------

  Object 0 is not an object. It is the value meaning "nothing" in the parent,
  sibling and child fields, and the Standard says a program may not use it.
  Every accessor here returns 0 for it rather than reading nine bytes from
  ZObjTab + 62 - 9, which lands inside the property defaults.
  --------------------------------------------------------------------------- }

const
  ZO_DEFAULTS  = 62;      { 31 words of property defaults ahead of object 1 }
  ZO_ENTRY     = 9;       { bytes per object entry in v3 }
  ZO_ATTRBYTES = 4;
  ZO_PARENT    = 4;       { offsets within an entry }
  ZO_SIBLING   = 5;
  ZO_CHILD     = 6;
  ZO_PROPS     = 7;       { word: byte address of the property table }
  ZO_MAXOBJ    = 255;     { v3 object numbers are a single byte }
  ZO_MAXPROP   = 31;

{ ---- Addressing ---------------------------------------------------------- }

{ Byte address of object n's 9-byte entry. 0 for object 0. }
function ZObjAddr(n: Word): Word;
begin
  if (n = 0) or (n > ZO_MAXOBJ) then ZObjAddr := 0
  else ZObjAddr := ZObjTab + ZO_DEFAULTS + ((n - 1) * ZO_ENTRY);
end;

{ ---- Tree --------------------------------------------------------------- }

function ZObjParent(n: Word): Word;
var a: Word;
begin
  a := ZObjAddr(n);
  if a = 0 then ZObjParent := 0 else ZObjParent := ZByte(a + ZO_PARENT);
end;

function ZObjSibling(n: Word): Word;
var a: Word;
begin
  a := ZObjAddr(n);
  if a = 0 then ZObjSibling := 0 else ZObjSibling := ZByte(a + ZO_SIBLING);
end;

function ZObjChild(n: Word): Word;
var a: Word;
begin
  a := ZObjAddr(n);
  if a = 0 then ZObjChild := 0 else ZObjChild := ZByte(a + ZO_CHILD);
end;

procedure ZObjSetParent(n, v: Word);
var a: Word;
begin
  a := ZObjAddr(n);
  if a <> 0 then ZPutByte(a + ZO_PARENT, v);
end;

procedure ZObjSetSibling(n, v: Word);
var a: Word;
begin
  a := ZObjAddr(n);
  if a <> 0 then ZPutByte(a + ZO_SIBLING, v);
end;

procedure ZObjSetChild(n, v: Word);
var a: Word;
begin
  a := ZObjAddr(n);
  if a <> 0 then ZPutByte(a + ZO_CHILD, v);
end;

{ ---- Attributes --------------------------------------------------------- }
{ Attribute 0 is the TOP bit of the first byte, not the bottom bit. Numbering
  runs left to right across the four bytes, so the mask is 7 - (a and 7). }

function ZObjAttr(n, a: Word): Boolean;
var
  ad, b: Word;
begin
  ZObjAttr := False;
  ad := ZObjAddr(n);
  if (ad = 0) or (a > 31) then Exit;
  b := ZByte(ad + (a shr 3));
  ZObjAttr := ((b shr (7 - (a and 7))) and 1) <> 0;
end;

procedure ZObjSetAttr(n, a: Word);
var
  ad, o, b: Word;
begin
  ad := ZObjAddr(n);
  if (ad = 0) or (a > 31) then Exit;
  o := ad + (a shr 3);
  b := ZByte(o);
  ZPutByte(o, b or (1 shl (7 - (a and 7))));
end;

procedure ZObjClearAttr(n, a: Word);
var
  ad, o, b: Word;
begin
  ad := ZObjAddr(n);
  if (ad = 0) or (a > 31) then Exit;
  o := ad + (a shr 3);
  b := ZByte(o);
  ZPutByte(o, b and (not (1 shl (7 - (a and 7)))));
end;

{ ---- Property table ----------------------------------------------------- }

{ Byte address of object n's property table. }
function ZObjPropTable(n: Word): Word;
var a: Word;
begin
  a := ZObjAddr(n);
  if a = 0 then ZObjPropTable := 0 else ZObjPropTable := ZWord(a + ZO_PROPS);
end;

{ Byte address of the first property's size byte, i.e. just past the name. }
function ZObjFirstProp(n: Word): Word;
var p: Word;
begin
  p := ZObjPropTable(n);
  if p = 0 then ZObjFirstProp := 0
  else ZObjFirstProp := p + 1 + (ZByte(p) * 2);   { length byte is in WORDS }
end;

{ Address of the size byte for property p on object n, or 0 if absent.
  Properties are stored in DESCENDING number order, so the scan can stop as
  soon as it passes p -- and get_next_prop depends on that ordering too. }
function ZObjPropAddr(n, p: Word): Word;
var
  a, sz, num: Word;
begin
  ZObjPropAddr := 0;
  a := ZObjFirstProp(n);
  if a = 0 then Exit;
  while True do
  begin
    sz := ZByte(a);
    if sz = 0 then Exit;                 { terminator: not present }
    num := sz and 31;
    if num = p then
    begin
      ZObjPropAddr := a;
      Exit;
    end;
    if num < p then Exit;                { passed it, descending order }
    a := a + 1 + ((sz shr 5) + 1);       { size byte + data }
  end;
end;

{ Data length in bytes of the property whose SIZE BYTE is at a. }
function ZObjPropLen(a: Word): Word;
begin
  if a = 0 then ZObjPropLen := 0
  else ZObjPropLen := (ZByte(a) shr 5) + 1;
end;

{ The default value for property p, used when an object does not carry it. }
function ZObjPropDefault(p: Word): Word;
begin
  if (p = 0) or (p > ZO_MAXPROP) then ZObjPropDefault := 0
  else ZObjPropDefault := ZWord(ZObjTab + ((p - 1) * 2));
end;

{ get_prop. Defined only for properties of length 1 or 2; the Standard leaves
  longer ones undefined and real interpreters return the first word, so that is
  what happens here rather than a silent 0. }
function ZObjGetProp(n, p: Word): Word;
var
  a, len: Word;
begin
  a := ZObjPropAddr(n, p);
  if a = 0 then
  begin
    ZObjGetProp := ZObjPropDefault(p);
    Exit;
  end;
  len := ZObjPropLen(a);
  if len = 1 then ZObjGetProp := ZByte(a + 1)
  else ZObjGetProp := ZWord(a + 1);
end;

{ put_prop. Same length rule. Writing an absent property is a program error in
  the Standard; here it is ignored rather than allowed to scribble. }
procedure ZObjPutProp(n, p, v: Word);
var
  a, len: Word;
begin
  a := ZObjPropAddr(n, p);
  if a = 0 then Exit;
  len := ZObjPropLen(a);
  if len = 1 then ZPutByte(a + 1, v and $FF)
  else ZPutWord(a + 1, v);
end;

{ get_next_prop: 0 asks for the first property, otherwise the next one after p.
  Returns 0 at the end of the table. }
function ZObjNextProp(n, p: Word): Word;
var
  a, sz: Word;
begin
  ZObjNextProp := 0;
  if p = 0 then
  begin
    a := ZObjFirstProp(n);
    if a = 0 then Exit;
    ZObjNextProp := ZByte(a) and 31;
    Exit;
  end;
  a := ZObjPropAddr(n, p);
  if a = 0 then Exit;
  sz := ZByte(a);
  a := a + 1 + ((sz shr 5) + 1);
  ZObjNextProp := ZByte(a) and 31;
end;

{ ---- Short name --------------------------------------------------------- }

{ The name sits immediately after the property table's length byte, so this is
  a seek and a decode -- no address arithmetic beyond +1. An object with a
  zero-length name yields the empty string, which is legal and common for
  Inform's internal objects. }
procedure ZObjName(n: Word; var S: String);
var p: Word;
begin
  S := '';
  p := ZObjPropTable(n);
  if p = 0 then Exit;
  if ZByte(p) = 0 then Exit;
  ZSeek(p + 1);
  ZTextHere(S);
end;

{ ---- Tree manipulation -------------------------------------------------- }

{ remove_obj: detach n from its parent, leaving its own child list alone. }
procedure ZObjRemove(n: Word);
var
  par, c, prev: Word;
begin
  if n = 0 then Exit;
  par := ZObjParent(n);
  if par = 0 then Exit;

  c := ZObjChild(par);
  if c = n then ZObjSetChild(par, ZObjSibling(n))
  else
  begin
    { walk the sibling chain to the node before n }
    prev := 0;
    while (c <> 0) and (c <> n) do
    begin
      prev := c;
      c := ZObjSibling(c);
    end;
    if c = 0 then Exit;                  { not in its parent's list: corrupt }
    ZObjSetSibling(prev, ZObjSibling(n));
  end;

  ZObjSetParent(n, 0);
  ZObjSetSibling(n, 0);
end;

{ insert_obj: make n the FIRST child of dest, detaching it first. }
procedure ZObjInsert(n, dest: Word);
begin
  if (n = 0) or (dest = 0) then Exit;
  ZObjRemove(n);
  ZObjSetSibling(n, ZObjChild(dest));
  ZObjSetChild(dest, n);
  ZObjSetParent(n, dest);
end;

{ ---- How many objects the table holds ------------------------------------ }

{ There is no object count in the format. The usual deduction: the first
  object's property table must begin after the last object entry, so the gap
  between the end of the defaults and the lowest property-table address divides
  by 9 to give the count. Inform lays them out that way and so did Infocom.
  Used for diagnostics only -- nothing in the interpreter needs it. }
function ZObjCount: Word;
var
  n, lowest, p, entries: Word;
begin
  lowest := 0;
  n := 1;
  while n <= ZO_MAXOBJ do
  begin
    p := ZWord(ZObjTab + ZO_DEFAULTS + ((n - 1) * ZO_ENTRY) + ZO_PROPS);
    if (p = 0) or (p < ZObjTab) then Break;
    if (lowest = 0) or (p < lowest) then lowest := p;
    entries := ZObjTab + ZO_DEFAULTS + (n * ZO_ENTRY);
    if entries > lowest then Break;
    n := n + 1;
  end;
  ZObjCount := n - 1;
end;
