(* -------------------------------------------------------------------------- *)
(* K16 Pascal Compiler                                                        *)
(* K16 CPU port by Paul Berger, 2026                                              *)
(* https://github.com/paulkberger/K16-CPU                                     *)
(*                                                                            *)
(* Based on PASTA/80 Pascal System                                            *)
(* Copyright (C) 2020-2026 Joerg Pleumann                                     *)
(* https://github.com/pleumann/pasta80                                        *)
(*                                                                            *)
(* This program is free software: you can redistribute it and/or modify it    *)
(* under the terms of the GNU General Public License v3 as published by the   *)
(* Free Software Foundation.                                                  *)
(* -------------------------------------------------------------------------- *)

program K16Pascal;

{$mode delphi}

uses
  {$ifdef darwin} BaseUnix, {$endif} Keyboard, Dos, Math, Process;

const
  Version = '1.24';

(* -------------------------------------------------------------------------- *)
(* --- Utility functions ---------------------------------------------------- *)
(* -------------------------------------------------------------------------- *)

{$I K16Pascal_utils.inc}

(* -------------------------------------------------------------------------- *)
(* --- Config handling ------------------------------------------------------ *)
(* -------------------------------------------------------------------------- *)

var
  HomeDir: String;
  KosDir:  String;   { the k/OS source tree -- kos_defs.inc, klib/kos_klib.inc.
                       NOT under HomeDir, so it gets its own config key rather
                       than a path derived from the compiler's location. }
  SrcFile, AsmFile, BinFile: String;
  TargetKOS: Boolean = True;    { target: k/OS user-task .COM. --bare selects the
                                  ROM image instead. Part 22 (4.2) made k/OS the
                                  default; --kos is still accepted as a no-op. }
  ComPages:     Integer = 1;    { .COM header $0208 -- total contiguous pages,
                                  including heap.  Set by the $PAGES directive. }
  ComHeapPages: Integer = 0;    { .COM header $020A -- how many of those pages
                                  are heap.  Set by the $HEAP directive. }

(**
 * Tries to setup the compiler's home directory and the paths to various tools,
 * first by "guessing" via "which", then by loading a config file.
 *)
procedure LoadConfig;
var
  T: Text;
  UserDir, S, Key, Value: String;
  P: Integer;
begin
  HomeDir := GetHomeDir;
  UserDir := GetUserDir;

  { Default assumes the conventional side-by-side layout:
        C:\K16 CPU\K16 Pascal   (HomeDir)
        C:\K16 CPU\K16 OS       (KosDir)
    so an unconfigured install still builds.  Override with `kos=` in
    ~/.k16pascal.cfg.  Was three absolute C:\... literals in EmitHeader, which
    meant the compiler only worked on one machine at one drive letter. }
  KosDir := ParentDir(HomeDir) + '/K16 OS';

  {$I-}
  Assign(T, UserDir + '/.k16pascal.cfg');
  Reset(T);
  if IOResult = 0 then
  begin
    while not Eof(T) do
    begin
      ReadLn(T, S);
      if not StartsWith(S, '#') and (Length(S) <> 0) then
      begin
        P := Pos('=', S);
        if P <> 0 then
        begin
          Key := LowerStr(TrimStr(Copy(S, 1, P - 1)));
          Value := NativeToPosix(TrimStr(Copy(S, P + 1, 255)));
          if StartsWith(Value, '~') then
            Value := UserDir + Copy(Value, 2, 255);
          if Key = 'home' then
            HomeDir := Value
          else if Key = 'kos' then
            KosDir := Value
          else
          begin
            WriteLn('Invalid config key: ' + Key);
            Halt;
          end;
        end;
      end;
    end;
    Close(T);
  end;
  {$I+}
end;

procedure Emit(Tag, Instruction, Comment: String); forward;
procedure EmitI(S: String); forward;
procedure Error(Message: String); forward;
procedure SetLibrary(FileName: String); forward;

(* -------------------------------------------------------------------------- *)
(* --- Input ---------------------------------------------------------------- *)
(* -------------------------------------------------------------------------- *)

type
  (**
   * Represents a source file being processed. We maintain a linked list of such
   * sources that we treat like a stack to deal with (potentially nested)
   * includes.
   *)
  PSource = ^TSource;
  TSource = record
    Name: String;
    Input:  Text;
    Buffer: String;
    Line:   Integer;
    Column: Integer;
    Next: PSource;
  end;

var
  (**
   * The pointer to the current source file.
   *)
  Source: PSource;

(**
 * Open the given input file. The same procedure is called for the initial
 * input file and for all nested includes.
 *)
(* Resolve an $I / $L include operand.
 *
 * Beside the including file first -- unchanged, so nothing that worked before
 * changes meaning -- then HomeDir/rtl.  Without the fallback every program has
 * to spell the hop to the library out itself ($I ..\rtl\console.pas), and
 * that string breaks the moment the program moves one directory deeper.  With
 * it, $I console.pas works from anywhere, which is what $I does in TP
 * once the unit directories are set.
 *
 * Deliberately NOT a general search path: two entries, source-first, so a file
 * sitting next to the program always wins over one of the same name in rtl.
 * That way a local experimental copy shadows the library rather than silently
 * losing to it. *)
function ResolveInclude(FileName: String): String;
var
  Local: String;
begin
  ResolveInclude := FileName;
  if not IsRelative(FileName) then Exit;

  if Source <> nil then
  begin
    Local := ParentDir(FAbsolute(Source^.Name)) + '/' + FileName;
    if FSize(Local) >= 0 then
    begin
      ResolveInclude := Local;
      Exit;
    end;
  end;

  Local := HomeDir + '/rtl/' + FileName;
  if FSize(Local) >= 0 then
  begin
    ResolveInclude := Local;
    Exit;
  end;

  { Neither exists. Return the source-relative form so the error message names
    the path the programmer actually wrote next to, not the library. }
  if Source <> nil then
    ResolveInclude := ParentDir(FAbsolute(Source^.Name)) + '/' + FileName;
end;

procedure OpenInput(FileName: String);
var
  Tmp: PSource;
begin
  FileName := ResolveInclude(FileName);

  Tmp := Source;
  while Tmp <> nil do
  begin
    if Tmp^.Name = FileName then Error('Cyclic include');
    Tmp := Tmp^.Next;
  end;

  New(Tmp);

  with Tmp^ do
  begin
    Name := FileName;
    {$I-}
    Assign(Input, FileName);
    Reset(Input);
    if IOResult <> 0 then
    begin
      Dispose(Tmp);
      Error('File "' + PosixToNative(FileName) + '" not found');
    end;
    {$I+}
    Buffer := '';
    Line := 0;
    Column := 1;
    Next := Source;
  end;

  Source := Tmp;
end;

(**
 * Closes the current input file and resumes scanning/parsing of the enclosing
 * input file (if one exists).
 *)
procedure CloseInput();
var
  Tmp: PSource;
begin
  Tmp := Source;
  Source := Tmp^.Next;
  Close(Tmp^.Input);
  Dispose(Tmp);
end;

procedure EmitC(S: String); forward;

(**
 * Returns (and consumes) the next input character. This function is called
 * routinely by the scanner.
 *)
function GetChar(): Char;
begin
  with Source^ do
  begin
    if Column > Length(Buffer) then
    begin
      if Eof(Input) then
      begin
        if Next <> nil then
        begin
          CloseInput;
          GetChar := ' ';
          Exit;
        end
        else Error('Unexpected end of source');
      end;

      ReadLn(Input, Buffer);
      EmitC('[' + IntToStr(Line) + '] ' + Buffer); // TODO Make this configurable?
      Buffer := Buffer + #13;
      Line := Line + 1;
      Column := 1;
    end;

    GetChar := Buffer[Column];
    Inc(Column);
  end;
end;

(**
 * Pushes back a single character. This - admittedly slightly ugly - procedure
 * is called by the scanner. It must not be called at the beginning of a line
 * or source code file, but this never happens.
 *)
procedure UngetChar();
begin
  Source^.Column := Source^.Column - 1;
end;

(* -------------------------------------------------------------------------- *)
(* --- String table --------------------------------------------------------- *)
(* -------------------------------------------------------------------------- *)

function GetLabel(Prefix: String): String; forward;


(* ---- .COM header page declaration -- $PAGES n / $HEAP n ----------------
 * Part 24 / k/OS Part 60.  A .COM declares its page run in its 12-byte header,
 * and the count is a property of the PROGRAM rather than of an invocation -- so
 * it is a source directive and not a switch: a build script cannot lose it and
 * a manual recompile cannot get it wrong.
 *
 * EmitHeader runs before the source is scanned, so the header emits the SYMBOLS
 * PASCAL_PAGES / PASCAL_HEAPPAGES and EmitFooter emits their .EQUs once the
 * directives have been seen.  A forward .EQU referenced by .WORD and by an
 * immediate is verified assembler behaviour (Part 24 probe: $0208 = 0003,
 * LOADI D0,#PASCAL_PAGES = C003).
 *
 * No upper bound is enforced here.  The host's free page range is the kernel's
 * business -- it differs between EMU ($02..$3F) and Digital -- and
 * _AllocPageRun reports ERR_NOMEM to the parent at load time.
 *)
function DirectiveNum(const S, What: String): Integer;
var
  V, Code: Integer;
begin
  Val(TrimStr(S), V, Code);
  if (Code <> 0) or (V < 0) then Error('Invalid ' + What + ' value: ' + TrimStr(S));
  DirectiveNum := V;
end;

procedure SetComPages(const S: String);
begin
  if not TargetKOS then Error('{$PAGES} has no meaning on a bare-metal target');
  ComPages := DirectiveNum(S, '{$PAGES}');
  if ComPages < 1 then Error('{$PAGES} must be at least 1');
end;

procedure SetComHeap(const S: String);
begin
  if not TargetKOS then Error('{$HEAP} has no meaning on a bare-metal target');
  ComHeapPages := DirectiveNum(S, '{$HEAP}');
end;

{ The heap < pages test is deliberately NOT here: the two directives may appear
  in either order, so it belongs where both values are final -- EmitFooter. }

{$I K16Pascal_scanner.inc}

{$I K16Pascal_symbols.inc}

(* -------------------------------------------------------------------------- *)
(* --- Call graph (Part 18) ------------------------------------------------- *)
(* -------------------------------------------------------------------------- *)

{$I K16Pascal_callgraph.inc}

(* -------------------------------------------------------------------------- *)
(* --- Emitter -------------------------------------------------------------- *)
(* -------------------------------------------------------------------------- *)

var
  (**
   * The text file we are writing assembly code to.
   *)
  Target: Text;

  (**
   * The index of the next label we will generate.
   *)
  NextLabel: Integer;

  (**
   * Reflects whether the optimizer is enabled.
   *
   * TODO Move this into a central place together with other compiler switches.
   *)
  Optimize: Boolean = True;

  (**
   * Contains the current jump target for the Exit statement.
   *
   * TODO Should this be elsewhere, maybe together with Break/Continue?
   *)
  ExitTarget: String;

procedure OpenTarget(Filename: String);
begin
  {$I-}
  Assign(Target, PosixToNative(Filename));
  Rewrite(Target);
  {$I+}
  if IOResult <> 0 then
    Error('Cannot create output file: ' + Filename);
end;

(**
 * Generates a new, unique label with the given prefix.
 *
 * TODO Is this in the right place?
 *)
function GetLabel(Prefix: String): String;
begin
  GetLabel := Prefix + IntToStr(NextLabel);
  NextLabel := NextLabel + 1;
end;

procedure Emit0(Tag, Instruction, Comment: String); forward;

{$I K16Pascal_optimizer.inc}
{$I K16Pascal_codegen.inc}


type
  TTypeCheck = (tcExact, tcAssign, tcExpr);

function  TypeCheck(Left, Right: PSymbol; Check: TTypeCheck): PSymbol; forward;
function  ParseExpression: PSymbol; forward;
function  ParseVariableAccess(Symbol: PSymbol): PSymbol; forward;
function  ParseVariableRef: PSymbol; forward;
function  ParseFormat: Integer; forward;
procedure ParseArguments(Sym: PSymbol); forward;
function  ParseBuiltInVarRead(Sym: PSymbol): PSymbol; forward;
procedure ParseBuiltInVarWrite(Sym: PSymbol); forward;
function  ParseBuiltInFunction(Func: PSymbol): PSymbol; forward;
procedure ParseToken(T: TToken); forward;

{$I K16Pascal_builtins.inc}


{$I K16Pascal_parser.inc}


(**
 * Parses the main program. This includes automatic inclusion of the correct
 * system library (which needs its own "end." so we know when exactly the actual
 * program code starts).
 *)
procedure ParseProgram;
begin
  OpenScope(False);
  RegisterAllBuiltIns;
  if TargetKOS then
    GlobalRAMOffset := $008210   { k/OS: origin for the bss SIZE only -- actual addresses
                                   come from the GLOBALS .REGION (assembler-placed) }
  else
    GlobalRAMOffset := $000200;  { bare-metal: zero-page globals; reset for each compilation }

  OpenInput(HomeDir + '/rtl/k16_system.pas');

  NextToken;
  ParseDeclarations(nil);

  Expect(toEnd);
  NextToken;
  Expect(toPeriod);
  NextToken;

  LastBuiltIn := SymbolTable;

  OpenScope(False);
  if Scanner.Token = toProgram then
  begin
    NextToken;
    Expect(toIdent);
    NextToken;
    Expect(toSemicolon);
    NextToken;
  end;
  parseBlock(nil);
  Expect(toPeriod);
(*
  EmitC('');
  Emit('globals', '.DS    ' + IntToStr(Offset), 'Globals');
*)
  EmitC('');
  EmitStrings();
  EmitC('');
  { Pascal/compiler reserved area }
  { k/OS: 'display' is now a DISPLAY .REGION field (see EmitTaskPageRegions). }
  if not TargetKOS then
    Emit('display', '.EQU $000180', 'Display frame pointer area (Pascal reserved RAM)');
  EmitC('');
  Emit('eof', '', 'End of file');

  CloseScope(False);
  CloseScope(False);
end;

(**
 * Performs a build. All relevant information is assumed to be in the respective
 * global variables. The procedure does everything up to and including a
 * possible conversion to a specialized file format.
 *)
function Build: Integer;
begin
  AsmFile := ChangeExt(SrcFile, '.asm');

  if SetJmp(StoredState) = 0 then
  begin
    HasStoredState := True;
    Build := 1;

    WriteLn('Compiling...');
    WriteLn('  ', PosixToNative(FRelative(SrcFile)),
            ' -> ', PosixToNative(FRelative(AsmFile)));

    ErrorLine   := 0;
    ErrorColumn := 0;
    Level       := 0;
    Offset      := 0;
    Scanner.Token := toNone;
    while Source <> nil do CloseInput;
    C := #0;
    while SymbolTable <> nil do CloseScope(True);
    CGReset;
    CurrentScope  := nil;
    LastBuiltIn   := nil;
    ClearStrings;
    Source := nil;
    Code   := nil;

    AbsCode    := True;


    OpenInput(SrcFile);
    OpenTarget(AsmFile);
    EmitHeader(HomeDir, SrcFile);

    ParseProgram;

    if DumpCalls then CGDump;

    CGCheckRecursion;   { Part 18 Phase 1a }

    EmitFooter(AsmFile);
    CloseTarget;
    CloseInput;

    WriteLn('Done.');
    WriteLn('  ', PosixToNative(FRelative(AsmFile)));
    WriteLn;

    Build := 0;
  end;

  HasStoredState := False;
end;


(* -------------------------------------------------------------------------- *)
(* --- Main program --------------------------------------------------------- *)
(* -------------------------------------------------------------------------- *)

procedure Copyright;
begin
  WriteLn('----------------------------------------');
  WriteLn('K16 Pascal v' + Version);
  WriteLn('K16 port by Paul Berger');
  WriteLn;
  WriteLn('Based on PASTA/80 Pascal System');
  WriteLn('Copyright (C) 2020-2026 Joerg Pleumann');
  WriteLn('----------------------------------------');
  WriteLn;
end;

procedure Parameters;
var
  I: Integer;
begin
  if ParamCount = 0 then
  begin
    Copyright;
    WriteLn('Usage:');
    WriteLn('  k16pascal { <option> } <input.pas>');
    WriteLn;
    WriteLn('Options:');
    WriteLn('  --opt          Enable peephole optimizations');
    WriteLn('  --dep          Enable smart linking');
    WriteLn('  --kos          Target a k/OS user-task .COM (this is the default)');
    WriteLn('  --bare         Target a bare-metal ROM image instead');
    WriteLn('  --calls        Dump the call graph after parsing');
    WriteLn('  --version      Show version number');
    WriteLn;
    Halt(1);
  end;

  I := 1;
  SrcFile := ParamStr(I);
  while Copy(SrcFile, 1, 2) = '--' do
  begin
    if SrcFile = '--opt' then
      Optimize := True
    else if SrcFile = '--dep' then
      SmartLink := True
    else if SrcFile = '--kos' then
      TargetKOS := True          { default since Part 22; kept so existing
                                   invocations and scripts keep working }
    else if SrcFile = '--bare' then
      TargetKOS := False
    else if SrcFile = '--calls' then
      DumpCalls := True
    else
      Error('Invalid option: ' + SrcFile);
    I := I + 1;
    SrcFile := ParamStr(I);
  end;

  if SrcFile = '' then Error('No input file');

  SrcFile := FAbsolute(NativeToPosix(SrcFile));
  if Pos('.', NameOnly(SrcFile)) = 0 then SrcFile := SrcFile + '.pas';
  AsmFile := ChangeExt(SrcFile, '.asm');

  Copyright;
  Halt(Build);
end;

begin
  if ParamStr(1) = '--version' then
  begin
    WriteLn(Version);
    Halt;
  end;

  LoadConfig;
  Parameters;
end.

(*
TODO
- Record typed constants
- Too many arguments
- var X absolute $1234
- var X absolute Y;
- Complex types on the stack (parameters, locals), what does Turbo 3 allow?
- Enums as array indices
- Alternative array syntax
- Subrange types
- Pointers & heap management
- Allow assignment from Byte to Integer (TypeCheck probably needs to return type)
*)
