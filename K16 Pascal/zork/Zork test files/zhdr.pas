program ZHdr;

(* ---------------------------------------------------------------------------
   zhdr.pas -- load a v3 story and print its header       K16 Pascal, Part 25

   Milestone 1a: proves the load, the page arithmetic and the big-endian word
   reads before a single Z-opcode exists. The oracle is ztools' infodump, and
   the field names and hex widths below are chosen to match its output so the
   two can be read side by side.

   The checksum is the real test here. It is a sum over every byte from $40 to
   the end of the file, so it walks the whole image, crosses the page boundary
   on a large story, and disagrees with the header the moment any part of the
   load went to the wrong place. A header dump on its own would still look
   perfectly correct with page 1 entirely blank.

       K> zhdr hello.z3
       K> zhdr zork1.z3

   Requires PAGES 3 -- see zmem.pas. One binary covers every v3 story.

   Hex output is Write-based rather than through String-returning helpers, and
   the column padding is baked into each literal rather than done by a Field
   routine. Both for the same reason: a String temp or a by-value String
   parameter takes a 256-byte frame block per call site (Part 24 s5.2), which
   is a great deal of frame for something that only ever prints.
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

procedure WHex2(v: Word);
begin
  Write(HexDigits[(v shr 4) and $0F], HexDigits[v and $0F]);
end;

procedure WHex4(v: Word);
begin
  WHex2(v shr 8);
  WHex2(v and $FF);
end;

{ 17-bit value as five hex digits, matching infodump's file-size field. }
procedure WHex5(hi, lo: Word);
begin
  Write(HexDigits[hi and $0F]);
  WHex4(lo);
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

procedure Report;
begin
  WriteLn;
  WriteLn('    **** Story file header ****');
  WriteLn;
  Write('Z-code version:           '); WriteLn(ZVersion);
  Write('Release number:           '); WriteLn(ZRelease);
  Write('Serial number:            '); WriteLn(ZSerial);
  Write('Size of resident memory:  '); WHex4(ZHiMem);   WriteLn;
  Write('Start PC:                 '); WHex4(ZInitPC);  WriteLn;
  Write('Dictionary address:       '); WHex4(ZDict);    WriteLn;
  Write('Object table address:     '); WHex4(ZObjTab);  WriteLn;
  Write('Global variables address: '); WHex4(ZGlobals); WriteLn;
  Write('Size of dynamic memory:   '); WHex4(ZStatic);  WriteLn;
  Write('Abbreviations address:    '); WHex4(ZAbbrev);  WriteLn;
  Write('File size:                '); WHex5(ZLenHi, ZLenLo); WriteLn;
  Write('Checksum:                 '); WHex4(ZCkHdr);   WriteLn;
  WriteLn;
  WriteLn('    **** As loaded ****');
  WriteLn;
  Write('Story base page:          '); WriteLn(ZPg0);
  Write('Story top page:           '); WriteLn(ZPgTop);
  WriteLn;
end;

begin
  InitFiles;
  (* Startup markers, off by default. They stay in the source because startup
     is the one part of this engine with no output of its own: with them off a
     hang anywhere before the header dump is indistinguishable from any other,
     and turning them on cost one recompile rather than a bisect. *)
  ZTrace := False;
  GetArgs(Args);

  if Length(Args) = 0 then
  begin
    WriteLn('usage: zhdr <story.z3>');
    Halt(1);
  end;

  if not HasExt(Args) then Args := Args + '.Z3';

  if not ZMemInit(Args) then
  begin
    Write('zhdr: ');
    ZErrMsg(ZErr);
    WriteLn;

    (* A checksum failure has already parsed a plausible header, so print it:
       what the fields look like IS the diagnosis. *)
    Halt(1);
  end;

  (* The dump comes BEFORE the checksum on purpose. Everything above this
     point is bounded work; the checksum walks the whole image. If the header
     prints and then nothing follows, the fault is in ZChecksum and nowhere
     else -- which is a great deal more than "it loops". *)
  Report;

  Write('Verifying...');
  if ZVerify then
  begin
    Write(' checksum '); WHex4(ZCkCalc); WriteLn(' ok');
  end
  else
  begin
    Write(' MISMATCH: header '); WHex4(ZCkHdr);
    Write(', computed ');        WHex4(ZCkCalc); WriteLn;
    Halt(1);
  end;
end.
