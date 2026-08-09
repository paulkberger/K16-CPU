program Zork;

(* ---------------------------------------------------------------------------
   zork.pas -- run a version 3 story file            K16 Pascal, Part 26

       K> zork zork1
       K> zork zork1.z3

   Everything below the surface is the five modules: zmem (residency and
   addressing), ztext (Z-string decode, encode and the word-wrap sink), zobj
   (the object tree), zdict (dictionary and tokeniser), zdis (instruction
   decode) and zexec (execution).

   The checksum is verified before anything runs. It is the only check that
   reads every byte of the story, and a story that loaded wrongly produces
   an interpreter fault hundreds of instructions later with nothing pointing
   at the load -- which is exactly the afternoon Part 26 spent on a wrapped
   file position. One second here is cheap.

   Save, restore and restart landed in Part 27. Saves are Quetzal 1.4, so a
   save written here restores under Frotz and vice versa.

   FIVE pages, not four. The task page, up to two for a v3 story image, and
   two more taken by zsave: one holding dynamic memory as it came off disk
   (the XOR baseline Quetzal is defined against, and what restart copies
   back) and one used to assemble a restore before any of it is committed.
   --------------------------------------------------------------------------- *)

{$PAGES 5}
{$HEAP 0}

{$I files.pas}
{$I console.pas}
{$I memory.pas}
{$I zmem.pas}
{$I ztext.pas}
{$I zobj.pas}
{$I zdict.pas}
{$I zdis.pas}
{$I zstate.pas}
{$I zsave.pas}
{$I zexec.pas}

var
  Args: String;

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
  (* Diagnose BEFORE registering as a shell; do the WORK after.

     sys_register_shell allocates a back-buffer, splices this task into the
     shell ring after kosh, and leaves it BACKGROUNDED. From that moment our
     console output is recorded only in OUR back-buffer -- and if we then
     Halt, _ReapDeadTask unsplices us, FREES that buffer, and repaints the
     screen from the incoming foreground shell's buffer instead. A startup
     message written after RegisterShell is therefore destroyed in the same
     instant the task exits: the usage line below was invisible for exactly
     this reason.

     Before registration we are an ordinary task with no back-buffer, so
     WriteLn goes straight to the terminal and kosh -- still FOREGROUND_TCB,
     blocked in sys_wait -- never repaints over it. The message survives, the
     way any plain .COM's output does.

     That argues for registering late, and for a while the whole load sat in
     front of it. The cost showed up under `zork zork1 &': kosh prints [bg N],
     returns to its REPL and paints its prompt, and then the load's Loading
     and Preparing lines arrive on top of it from a task that is supposed to
     be in the background. They reach the terminal precisely BECAUSE we have
     not registered yet -- output from a task with no back-buffer takes the
     fast path to the terminal MMIO whether it is foreground or not.

     So the line is not drawn at the load, it is drawn at DIAGNOSIS. ZMemProbe
     answers everything a user can get wrong -- no such file, not a v3 story,
     too big for our pages -- from 64 bytes and in silence. Those reports stay
     out here where they can be read. Registration follows. The load, the
     checksum and the banner all happen inside our back-buffer, and `&' is
     silent as it should be.

     What is left over is the read loop's own two failures, a MemRead hard
     error and a header longer than the file. They are I/O faults, not typing
     mistakes, they cannot be seen from the header, and by then we are a
     background shell whose dying words get freed. Halt(2) says it instead,
     via kosh's [exit N]; there is no unregister, and no amount of grabbing
     the foreground helps, since the reap repaints from our successor.

     (kedit23 does InitFiles then RegisterShell immediately; it has nothing
     to validate, so the question never arises there.) *)
  InitFiles;

  ZTrace := False;
  GetArgs(Args);

  if Length(Args) = 0 then
  begin
    WriteLn('usage: zork <story.z3>');
    Halt(1);
  end;

  if not HasExt(Args) then Args := Args + '.Z3';

  if not ZMemProbe(Args) then
  begin
    Write('zork: ');
    ZErrMsg(ZErr);
    WriteLn;
    Halt(1);
  end;

  (* Committed to running now: take the terminal.  The load, the banner and
     the slow checksum below land in our back-buffer and are waiting when you
     switch to us (Ctrl-N); the first sread blocks until then.

     Failure is ignored on purpose: on ERR_NOMEM the task runs as a plain
     foreground child, exactly as it did before. *)
  RegisterShell;

  (* Probed clean, so the only way this fails now is the read loop itself.
     ZErrMsg would be written into a buffer nobody will ever see; the exit
     code is the whole message. *)
  if not ZMemInit(Args) then Halt(2);

  (* The checksum is skipped under Digital, and that is not a shortcut taken
     against the "always test on Digital" rule -- it is outside it. This
     verifies the STORY FILE, not the CPU: it catches a bad load through
     k/OS's file layer, which is already smoked on EMU. Nothing about summing
     87,000 bytes exercises a gate the rest of Zork will not.

     Measured, it is by far the longest thing the program does on gates. Left
     in, it is hours; the game itself then runs perfectly well. *)
  if SysIsDigital then
    WriteLn('Digital detected -- skipping checksum.')
  else
  begin
    Write('Verifying');
    if not ZVerify then
    begin
      WriteLn(' FAILED');
      WriteLn('zork: the story file is damaged; refusing to run it.');
      Halt(1);
    end;
    WriteLn(' ok');
  end;
  WriteLn;

  (* The default save name, derived from the story argument so a save lands
     beside its story and inherits whatever drive or path was typed. After
     the first save it holds the file just written, so `save' then `restore'
     needs one keystroke. *)
  ZQSetDefaultName(Args);

  ZExecInit;

  (* Wrap to the real terminal, not a hardcoded 78. ZExecInit called
     ZOutInit, so this must come after it. One column is left in hand so a
     full-width line cannot trigger the terminal's own wrap on top of ours,
     which would double-space every paragraph. *)
  if TermCols > 20 then ZOutWidth := TermCols - 1;
  ZRun;

  if ZFault then Halt(1);
end.
