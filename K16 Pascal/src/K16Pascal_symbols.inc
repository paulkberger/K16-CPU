(* -------------------------------------------------------------------------- *)
(* --- Symbol Table and Type System ---------------------------------------- *)
(* -------------------------------------------------------------------------- *)
(*                                                                            *)
(* String literal table: AddString, ClearStrings                             *)
(* Symbol table: TSymbolClass, TSymbol, OpenScope, CloseScope,               *)
(*   Lookup, LookupGlobalOrFail, LookupBuiltInOrFail, CreateSymbol,          *)
(*   SetDataType, RegisterType, RegisterMagic, RegisterAllBuiltIns           *)
(*                                                                            *)
(* Depends on: scanner (Error, GetLabel via forward decls in main).          *)
(* -------------------------------------------------------------------------- *)

type
  (**
   * A linked list of string constants used in the program. No duplicates. The
   * strings are written at the end of parsing.
   *
   * TODO Make this a hash table in case we want to run on 8 bit.
   * TODO Add something similar for Real constants and maybe for set constants.
   *)
  PStringLiteral = ^TStringLiteral;
  TStringLiteral = record
    Tag: String;
    Value: String;
    Next: PStringLiteral;
  end;

var
  (**
   * The head of our list.
   *)
  Strings: PStringLiteral;

(**
 * Adds a string to the list and returns a label under which it is accessible
 * for assembly code. If the string is already part of the list the existing
 * label will be returned.
 *)
function AddString(S: String): String;
var
  Temp: PStringLiteral;
begin
  if Strings = nil then
  begin
    New(Strings);
    Strings^.Tag := GetLabel('string');
    Strings^.Value := S;
    Strings^.Next := nil;
    AddString := Strings^.Tag;
  end
  else
  begin
    Temp := Strings;
    while Temp <> nil do
    begin
      if Temp^.Value = S then
      begin
        AddString := Temp^.Tag;
        Exit;
      end;

      if Temp^.Next = nil then
      begin
        New(Temp^.Next);
        Temp^.Next^.Tag := GetLabel('string');
        Temp^.Next^.Value := S;
        Temp^.Next^.Next := nil;
        AddString := Temp^.Next^.Tag;
        Exit;
      end;

      Temp := Temp^.Next;
    end;
  end;
end;

procedure ClearStrings;
var
  Tmp: PStringLiteral;
begin
  while Strings <> nil do
  begin
    Tmp := Strings;
    Strings := Tmp^.Next;
    Dispose(Tmp);
  end;
end;

(* -------------------------------------------------------------------------- *)
(* --- Symbol table --------------------------------------------------------- *)
(* -------------------------------------------------------------------------- *)

type
  TSymbolClass = (scConst, scType, scArrayType, scRecordType, scEnumType,
                  scStringType, scSetType, scSubrangeType, scPointerType,
                  scFileType, scAliasType, scVar, scLabel, scProc, scFunc,
                  scScope);

  // Flags: Forward, External, Register, Magic, Reference, Writable, Relative, Sizable, Addressable

  (**
   * Represents an entry in our symbol table. The symbol table is a linked list
   * that operates a bit like a stack: New identifiers are put at the front and
   * may shadow existing ones. Identifiers are removed in reverse order once
   * they fall out of scope. Not all fields are used by all kinds of symbols,
   * some have a different meaning depending on the symbol they are used for.
   * "Value", for instance, can be the integer value of a constant, but also the
   * size of a type. This, although working, is slightly ugly and maybe worth a
   * clean-up.
   *)
  PSymbol = ^TSymbol;
  TSymbol = record
    Name: String;                       // Name of the symbol
    Kind: TSymbolClass;                 // Kind of the symbol
    DataType: PSymbol;                  // Data type, array type or return type
    ArgTypes: array[0..15] of PSymbol;  // Procedure/function parameter types
    ArgIsRef: array[0..15] of Boolean;  // Procedure/function "var" parameters
    Level: Integer;                     // Level of procedure/function, 0=global
    Value, Value2: Integer;             // Value(s) or size(s) of symbol
    Tag: String;                        // External label or address of symbol
    IndexType: PSymbol;                 // Index type of arrays
    Low, High: Integer;                 // Values of a range or an array index
    Prev, Next: PSymbol;                // Previous and next in linked list
    IsMagic: Boolean;                   // Magics are built into the compiler
    IsRef: Boolean;                     // Symbol is a reference (var param)
    IsStdCall: Boolean;                 // Procedure/function calling convention
    IsForward: Boolean;                 // Forward-declared procedure/function
    IsExternal: Boolean;                // External, to be resolved by assembler
    SavedParams: PSymbol;               // Original parameters, forward-case only
    IsAlive: Boolean;
    Deps: array[0..127] of PSymbol;
    DepCount: Integer;
    { Part 19 item 7.6: cached call-graph node index PLUS ONE, so that the
      FillChar-zeroed default (0) naturally means "not yet resolved". Storing
      the bare index would make 0 ambiguous with node 0. }
    CGNodeCache: Integer;
  end;

var
  (**
   * The head (aka newest entry) of our symbol table. Searches for an identifier
   * usually start from here.
   *)
  SymbolTable: PSymbol = nil;

  (**
   * The most recent scope marker.
   *)
  CurrentScope: PSymbol = nil;

  (**
   * The last built-in identifier.
   *)
  LastBuiltIn: PSymbol = nil;

  CurrentBlock: PSymbol = nil;

  (**
   * Nesting level and variable offset. Maintained by compiler.
   *)
  Level, Offset: Integer;

  (**
   * Pointers to several important built-in base types.
   *)
  dtInteger, dtBoolean, dtChar, dtByte, dtString, dtReal, dtPointer, dtFile,
  dtText, dtWord: PSymbol;

  (**
   * Pointers to the built-in Mem[] and Port[] pseudo-arrays.
   *)
  MemArray: PSymbol;

  (**
   * Pointers to a whole lot of built-in procedures and functions that are
   * considered "magic" and cannot be defined in Pascal. This is mostly because
   * their number or type of parameters is not fixed.
   *)
  AssertProc, BreakProc, ContProc, ExitProc, HaltProc, StrProc, ReadProc,
  ReadLnProc, WriteProc, WriteLnProc, EraseProc, RenameProc, AssignProc,
  ResetProc, RewriteProc, AppendProc, FlushProc, CloseProc, SeekProc,
  SeekEofProc, SeekEolnProc, BlockReadProc, BlockWriteProc, FilePosFunc,
  FileSizeFunc, EolFunc, EofFunc, AbsFunc, AddrFunc, DisposeProc, EvenFunc,
  HighFunc, LowFunc, NewProc, OddFunc, OrdFunc, PredFunc, FillProc, IncProc,
  DecProc, ConcatFunc, ValProc, IncludeProc, ExcludeProc, PtrFunc, SizeFunc,
  SuccFunc, ChrFunc, LengthFunc, AssignedFunc: PSymbol;

  SmartLink: Boolean; (* TODO Move elsewhere *)

(**
 * Opens a scope, which mainly adds a new scope marker at the front of the
 * symbol table. If AdjustLevel is true (which is the case for procedures and
 * functions, especially nested ones) level and variable offset are affected,
 * too.
 *)
procedure OpenScope(AdjustLevel: Boolean);
var
  Sym: PSymbol;
begin
  New(Sym);
  FillChar(Sym^, SizeOf(TSymbol), 0);

  Sym^.Kind := scScope;
  Sym^.Prev := SymbolTable;
  Sym^.DataType := CurrentScope;
  if SymbolTable <> nil then SymbolTable^.Next := Sym;
  Sym^.Value := Offset;
  SymbolTable := Sym;
  CurrentScope := Sym;

  if AdjustLevel then
  begin
    if Level = 7 then Error('Nesting too deep.');

    Level := Level + 1;
    Offset := 0;
  end;
end;

(**
 * Closes a scope, removing all symbols up to and including the most recent
 * scope marker. Adjusts level, if requested. Will also detect unimplemented
 * forward procedures/functions in that scope and raise errors if any are
 * found.
 *)
procedure CloseScope(AdjustLevel: Boolean);
var
  Sym: PSymbol;
  Kind: TSymbolClass;
  I: Integer;
begin
  while SymbolTable <> CurrentScope do
  begin
    Kind := SymbolTable^.Kind;

    if ((Kind = scProc) or (Kind = scFunc)) then with SymbolTable^ do
    begin
      if IsForward then
        Error('Unresolved forward declaration "' + SymbolTable^.Name + '"');

      if SmartLink and (Level = 0) and IsStdCall and not IsExternal then
      begin
        if IsAlive then
        begin
          Emit('__USE' + Tag, '.EQU 1', '');
//          for I := 0 to DepCount - 1 do
//            Deps[I]^.IsAlive := True;
        end
        else
          Emit('__USE' + Tag, '.EQU 0', '');
      end;
    end;

    Sym := SymbolTable^.Prev;
    Dispose(SymbolTable);
    SymbolTable := Sym;
  end;

  CurrentScope := SymbolTable^.DataType;

  if AdjustLevel then
  begin
    Level := Level - 1;
    Offset := SymbolTable^.Value;
  end;

  Sym := SymbolTable^.Prev;
  Dispose(SymbolTable);
  SymbolTable := Sym;
end;

procedure Dependencies(Sym: PSymbol);
var
  I: Integer;
begin
  with Sym^ do
  begin
    //WriteLn('*** ', Name);

    if IsAlive then Exit;

    //WriteLn(Name, ' is alive');

    IsAlive := True;

    for I := 0 to DepCount - 1 do
      Dependencies(Deps[I]);
  end;
end;

procedure AddDependency(Src, Dst: PSymbol);
var
  I: Integer;
begin
    if (Src <> nil) then
    begin
      if Dst <> Src then with Src^ do
      begin
        for I := 0 to DepCount - 1 do
          if Deps[I] = Dst then Exit;

        if DepCount = 128 then Error('Too many dependencies'); (* TODO Fix me! *)

        //WriteLn(CurrentBlock^.Name, ' depends on ', Sym^.Name);

        Deps[DepCount] := Dst;
        Inc(DepCount);
      end
    end
    else
    begin
      //WriteLn('Main program depends on ', Sym^.Name);
      Dependencies(Dst);
    end;
  end;
(**
 * Searches the symbol table for the given identifier. Returns the symbol or
 * nil if it does not exist. The search starts and stops at the given symbols,
 * so passing the current scope as the second symbol would perform a local
 * search, while passing nil would perform a global one. Runtime is O(n) due
 * to the fact that we use a linked list for the symbol table (but modern
 * machines are so fast we don't notice).
 *)
function Lookup(Name: string; Start, Stop: PSymbol): PSymbol;
var
  Sym: PSymbol;
  I: Integer;
begin
  Name := UpperStr(Name);
  Sym := Start;
  while Sym <> Stop do
  begin
    if UpperStr(Sym^.Name) = Name then
    begin
      Lookup := Sym;

      (*
      Wenn lookup in main block stattfindet, nimm Symbol als Wurzel in irgendeine
      Liste auf. Noch nicht aktivieren. Beim Schliessen des main blocks rekursive
      Durchlaeufe bei allen Wurzeln starten.
      *)


      Exit;
    end;
    Sym := Sym^.Prev;
  end;

  Lookup := nil;
end;

(**
 * Searches the local scope for the given identifier and returns the
 * corresponding symbol. Throws an error if the symbol cannot be found.
 *)
function LookupLocalOrFail(Name: String): PSymbol;
var
  Sym: PSymbol;
begin
  Sym := Lookup(Name, SymbolTable, CurrentScope);
  if Sym = nil then Error('Unknown identifier "' + Name + '"');
  LookupLocalOrFail := Sym;
end;

(**
 * Searches the global scope for the given identifier and returns the
 * corresponding symbol. Throws an error if the symbol cannot be found.
 *)
function LookupGlobalOrFail(Name: String): PSymbol;
var
  Sym: PSymbol;
begin
  Sym := Lookup(Name, SymbolTable, nil);
  if Sym = nil then Error('Unknown identifier "' + Name + '"');
  LookupGlobalOrFail := Sym;
end;

(**
 * Searches the built-ins for the given identifier and returns the
 * corresponding symbol. Throws an error if the symbol cannot be found.
 *)
function LookupBuiltInOrFail(Name: String): PSymbol;
var
  Sym: PSymbol;
begin
  Sym := Lookup(Name, LastBuiltIn, nil);
  if Sym = nil then Error('Not supported.');
  LookupBuiltInOrFail := Sym;
end;

(**
 * This procedure is called when a procedure or function header is fully
 * parsed. It calculates the final offsets of all parameters relative to the
 * base pointer according to their sizes. We cannot do this earlier because we
 * don't know in advance the number of parameters, nor their sizes.
 *)
procedure AdjustOffsets;
var
  Sym, Sym2: PSymbol;
  I: Integer;
begin
  Sym := SymbolTable;
  I := 0;
  while (Sym^.Kind<>scProc) and (Sym^.Kind<>scFunc) do
  begin
    if Sym^.Kind = scVar then
    begin
      Sym^.Value := Sym^.Value - Offset + 2;  { V2: spill slots at [frame+2..N+2], below return addr }
      I := I + 1;
    end;
    Sym := Sym^.Prev;
  end;
  if Sym^.Kind = scFunc then
    I := I - 1;
  Sym^.Value := I;

  Sym2 := SymbolTable;
  while I > 0 do
  begin
    if Sym2^.Kind = scVar then
    begin
      Sym^.ArgTypes[I-1] := Sym2^.DataType;
      Sym^.ArgIsRef[I-1] := Sym2^.IsRef;
      I := I - 1;
    end;
    Sym2 := Sym2^.Prev;
  end;

  Offset := 0;
end;

(**
 * Creates a new symbol of the given kind. Makes sure the given name (if any)
 * is unique within the local scope.
 *)
function CreateSymbol(Kind: TSymbolClass; Name: String): PSymbol;
var
  Sym: PSymbol;
begin
  if (Length(Name) <> 0) and (Lookup(Name, SymbolTable, CurrentScope) <> nil) then
    Error('Duplicate symbol "' + Name + '"');

  New(Sym);
  FillChar(Sym^, SizeOf(TSymbol), 0);
  Sym^.Kind := Kind;
  Sym^.Name := Name;
  Sym^.Level := Level;
  Sym^.Prev := SymbolTable;
  Sym^.Tag := '';

  SymbolTable^.Next := Sym;
  SymbolTable := Sym;

  CreateSymbol := Sym;
end;

(**
 * Sets the data type of a variable or parameter. This is also the moment when
 * the offset of the symbol on the stack will be assigned (although, for
 * parameters, it will be adjusted later once all parameters are known).
 *)
procedure SetDataType(Sym: PSymbol; DataType: PSymbol; IsParam: Boolean = False);
begin
  Sym^.DataType := DataType;

  if (Sym^.Level = 0) and (Sym^.Tag = '') then
  begin
    // Global variable (including AbsCode-promoted locals) - no stack allocation
    // TODO Improve this! It's an ugly way of detecting global variables.
    // TODO Move away from mixed code/data to a separate data segment.
  end
  else if Sym^.Level > 0 then
  begin
    if Sym^.IsRef then
      Offset := Offset - 2                // A var parameter requires two bytes (pointer)
    else if IsParam and (DataType^.Kind = scStringType) then
      Offset := Offset - 2                // String value param passed as 2-byte pointer
    else if DataType^.Value = 1 then
      Offset := Offset - 2                // Two bytes is also the minimum on the stack
    else
      Offset := Offset - DataType^.Value; // Everything else just uses its real size

    if Offset and 1 = 1 then Dec(Offset); { round down to even (stack is word-aligned) }
    Sym^.Value := Offset;
  end;
end;

// TODO Do we really need this?
function RegisterType(Name: String; Size: Integer): PSymbol;
var
  Sym: PSymbol;
begin
  Sym := CreateSymbol(scType, Name);
  Sym^.Value := Size;

  RegisterType := Sym;
end;

// TODO Do we really need this?
function NewEnumType(Name: String): PSymbol;
var
  Sym: PSymbol;
begin
  Sym := CreateSymbol(scEnumType, Name);
  Sym^.Value := 1;
  NewEnumType := Sym;
end;

// TODO Do we really need this?
function NewConst(Name: String; DataType: PSymbol; Value: Integer): PSymbol;
var
  Sym: PSymbol;
begin
  Sym := CreateSymbol(scConst, Name);
  Sym^.DataType := DataType;
  Sym^.Value := Value;
  NewConst := Sym;
end;

(**
 * Registers a new magic symbol of the given type and with the given name.
 * Magic symbols are those that get their own parsing, usually because
 * they have a variable parameter list.
 *)
function RegisterMagic(Kind: TSymbolClass; Name: String): PSymbol;
var
  Sym: PSymbol;
begin
  Sym := CreateSymbol(Kind, Name);
  Sym^.IsMagic := True;
  RegisterMagic := Sym;
end;

(**
 * Registers all symbols that must be baked into the compiler and cannot be
 * defined by means of Pascal source code.
 *)
procedure RegisterAllBuiltIns;
begin
  dtInteger := RegisterType('Integer', 2);
  dtInteger^.Low := -32768;
  dtInteger^.High := 32767;

  { Part 24: unsigned 16-bit.  Low/High are host Integers (FPC 32-bit), so
    65535 is representable in the compiler even though it is not in a K16
    Integer.  Same storage size as Integer -- everything size-driven
    (EmitLoad, EmitStore, array scaling) therefore needs no change; only the
    places that ask "is this signed?" do. }
  dtWord := RegisterType('Word', 2);
  dtWord^.Low := 0;
  dtWord^.High := 65535;

  dtBoolean := NewEnumType('Boolean');
  dtBoolean^.Low := 0;
  dtBoolean^.High := 1;
  dtBoolean^.Tag := '__boolean_enum';
  NewConst('False', dtBoolean, 0);
  NewConst('True', dtBoolean, 1);

  dtChar := RegisterType('Char', 1);
  dtChar^.Low := 0;
  dtChar^.High := 255;
  dtChar^.Value := 1;
  dtByte := RegisterType('Byte', 1);
  dtByte^.Low := 0;
  dtByte^.High := 255;
  dtByte^.Value := 1;

  dtString := CreateSymbol(scStringType, 'String');
  dtString^.Value := 256;

  dtFile := CreateSymbol(scFileType, 'File');
  dtFile^.Value := 256; (* FIXME *)

  dtText := CreateSymbol(scFileType, 'Text');
  dtText^.Value := 256; (* FIXME *)

  dtReal := CreateSymbol(scType, 'Real');
  dtReal^.Value := 6;

  dtPointer := CreateSymbol(scPointerType, 'Pointer');
  dtPointer^.Value := 2;

  MemArray := CreateSymbol(scVar, 'Mem');
  MemArray^.DataType := dtByte;
  MemArray^.IsMagic := True;

  { Part 24: Port[] retired -- see ParseBuiltInVarRead.  K16 is MMIO-by-address;
    there is no port space for it to name, and its codegen was Z80. }

  AssertProc := RegisterMagic(scProc, 'Assert');
  BreakProc := RegisterMagic(scProc, 'Break');
  ContProc := RegisterMagic(scProc, 'Continue');
  DisposeProc := RegisterMagic(scProc, 'Dispose');
  ExitProc := RegisterMagic(scProc, 'Exit');
  HaltProc := RegisterMagic(scProc, 'Halt');
  NewProc := RegisterMagic(scProc, 'New');
  StrProc := RegisterMagic(scProc, 'Str');
  ReadProc := RegisterMagic(scProc, 'Read');
  ReadLnProc := RegisterMagic(scProc, 'ReadLn');
  WriteProc := RegisterMagic(scProc, 'Write');
  WriteLnProc := RegisterMagic(scProc, 'WriteLn');

  EraseProc := RegisterMagic(scProc, 'Erase');
  RenameProc := RegisterMagic(scProc, 'Rename');

  AssignProc := RegisterMagic(scProc, 'Assign');
  ResetProc := RegisterMagic(scProc, 'Reset');
  RewriteProc := RegisterMagic(scProc, 'Rewrite');
  AppendProc := RegisterMagic(scProc, 'Append');
  CloseProc := RegisterMagic(scProc, 'Close');
  FlushProc := RegisterMagic(scProc, 'Flush');
  SeekProc := RegisterMagic(scProc, 'Seek');
  SeekEofProc := RegisterMagic(scProc, 'SeekEof');
  SeekEolnProc := RegisterMagic(scProc, 'SeekEoln');

  BlockReadProc := RegisterMagic(scProc, 'BlockRead');
  BlockWriteProc := RegisterMagic(scProc, 'BlockWrite');

  FilePosFunc := RegisterMagic(scFunc, 'FilePos');
  FileSizeFunc := RegisterMagic(scFunc, 'FileSize');
  EolFunc := RegisterMagic(scFunc, 'Eoln');
  EofFunc := RegisterMagic(scFunc, 'Eof');

  IncProc := RegisterMagic(scProc, 'Inc');
  DecProc := RegisterMagic(scProc, 'Dec');

  ConcatFunc := RegisterMagic(scFunc, 'Concat');
  ValProc := RegisterMagic(scProc, 'Val');

  IncludeProc := RegisterMagic(scProc, 'Include');
  ExcludeProc := RegisterMagic(scProc, 'Exclude');

  FillProc := RegisterMagic(scProc, 'FillChar');

  AbsFunc := RegisterMagic(scFunc, 'Abs');
  AddrFunc := RegisterMagic(scFunc, 'Addr');
  EvenFunc := RegisterMagic(scFunc, 'Even');
  HighFunc := RegisterMagic(scFunc, 'High');
  LowFunc := RegisterMagic(scFunc, 'Low');
  OddFunc := RegisterMagic(scFunc, 'Odd');
  OrdFunc := RegisterMagic(scFunc, 'Ord');
  ChrFunc := RegisterMagic(scFunc, 'Chr');
  PredFunc := RegisterMagic(scFunc, 'Pred');
  PtrFunc := RegisterMagic(scFunc, 'Ptr');
  SizeFunc := RegisterMagic(scFunc, 'SizeOf');
  SuccFunc := RegisterMagic(scFunc, 'Succ');
  LengthFunc := RegisterMagic(scFunc, 'Length');
  AssignedFunc := RegisterMagic(scFunc, 'Assigned');

end;


