program ZTrace;

(* ---------------------------------------------------------------------------
   ztrace.pas -- run a story with an instruction trace            K16 Pascal, Part 26

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
  (* Order matches kedit23: InitFiles, then RegisterShell.

     sys_register_shell allocates a back-buffer and splices this task into
     the shell ring after kosh. It leaves the task BACKGROUNDED -- kedit23's
     own note: "the edit loop's first ReadKey is what blocks until we are
     switched to (Ctrl-N)". Same here: the banner and any load error go into
     this task's back-buffer and are waiting when you switch to it, and the
     first sread blocks until then.

     Failure is ignored on purpose: on ERR_NOMEM the task runs as a plain
     foreground child, exactly as it did before. *)
  InitFiles;
  RegisterShell;

  ZTrace := False;
  GetArgs(Args);

  if Length(Args) = 0 then
  begin
    WriteLn('usage: zork <story.z3>');
    Halt(1);
  end;

  if not HasExt(Args) then Args := Args + '.Z3';

  if not ZMemInit(Args) then
  begin
    Write('zork: ');
    ZErrMsg(ZErr);
    WriteLn;
    Halt(1);
  end;

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
  ZTraceMax := 200;        (* Zork I reaches its first sread in 407
                              instructions; 200 covers the whole banner. *)
  ZRun;

  if ZFault then Halt(1);
end.
