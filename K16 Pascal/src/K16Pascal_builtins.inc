(* -------------------------------------------------------------------------- *)
(* --- Built-in Functions and Procedures ----------------------------------- *)
(* -------------------------------------------------------------------------- *)
(*                                                                            *)
(* Implements all Pascal built-in functions and procedures:                  *)
(*   ParseBuiltInVarRead, ParseBuiltInVarWrite                               *)
(*   ParseBuiltInFunction (Ord, Chr, Abs, Length, SizeOf, Ptr, ...)          *)
(*   ParseFormat                                                              *)
(*   ParseBuiltInProcedure (Write, WriteLn, Read, Inc, Dec, New, ...)        *)
(*                                                                            *)
(* Depends on: scanner, symbols, codegen (all included before this).         *)
(* -------------------------------------------------------------------------- *)

(**
 * Parses read access to a "magic" built-in variable. Currently only used for
 * Mem[] and Port[].
 *)
function ParseBuiltInVarRead(Sym: PSymbol): PSymbol;
begin
  (* Part 24: Port[] retired.  K16 has no port space -- everything is MMIO by
   * address -- and the emitted code was a Z80 leftover that silently did
   * nothing on read (push the index straight back) and emitted `out (c),l` on
   * write.  A built-in that quietly does nothing is worse than no built-in;
   * the identifier is now simply undeclared, which says so.
   *
   * Mem[i] stays, and is honest about what it is: a BYTE window over the
   * CURRENT DATA PAGE -- Y3 (the task page) on k/OS, bank $00 bare-metal --
   * indexed 0..65535.  There is no page selector, which is precisely the
   * limitation memory.pas exists to lift:  Mem[x]  ==  MemGetByte(x, SysMyPage).
   *)
  if Sym = MemArray then
  begin
    ParseToken(toLBrack);
    TypeCheck(dtInteger, ParseExpression, tcAssign);
    ParseToken(toRBrack);

    EmitI('POP    D0, XY3');
    EmitI('MOVE   X0, D0');
    EmitI('LOADI  Y0, #$00');      { -> MOVE Y0, Y3 on k/OS (KosPatchInstr) }
    EmitI('LOADB  D0, [XY0]');     { zero-extended }
    EmitI('PUSH   D0, XY3');
  end
  else Error('Invalid magic var: ' + Sym^.Name);

  ParseBuiltInVarRead := dtByte;
end;

(**
 * Parses write access to a "magic" built-in variable. Currently only used for
 * Mem[] and Port[].
 *)
procedure ParseBuiltInVarWrite(Sym: PSymbol);
begin
  (* Part 24: this was never ported from PASTA/80 -- it emitted the Z80
   * `ld (hl),e`, so `Mem[x] := v` has never assembled.  Loud rather than
   * silent (the K16 assembler rejects the mnemonic), which is the only reason
   * it survived this long unnoticed.
   *
   * Operand order: the index is pushed first and the value second, so the
   * value pops into D1 and the index into D0. *)
  if Sym = MemArray then
  begin
    ParseToken(toLBrack);
    TypeCheck(dtInteger, ParseExpression, tcAssign);
    ParseToken(toRBrack);
    ParseToken(toBecomes);
    TypeCheck(dtByte, ParseExpression, tcAssign);

    EmitI('POP    D1, XY3');       { value }
    EmitI('POP    D0, XY3');       { index }
    EmitI('MOVE   X0, D0');
    EmitI('LOADI  Y0, #$00');      { -> MOVE Y0, Y3 on k/OS }
    EmitI('STOREB D1, [XY0]');
  end
  else Error('Invalid magic var: ' + Sym^.Name);
end;

(**
 * Parses a built-in function, which is basically every pre-defined function
 * that does not have a fixed syntax (variable parameters, for instance).
 *
 * TODO Split this into multiple procedures?
 *)
function ParseBuiltInFunction(Func: PSymbol): PSymbol;
var
  T, Sym: PSymbol;
  Old: PCode;
  S1, S2: String;
  RightTemps, DepthBeforeRight, DepthLeft: Integer;
  MyConcatDest: Integer;   { Part 17: see ParseSimpleExpression -- re-entrancy }
begin
  if Func^.Kind <> scFunc then
    Error('Not a built-in function: ' + Func^.Name);

  NextToken; Expect(toLParen); NextToken;

  if Func = AbsFunc then
  begin
    Sym := ParseExpression;

    if Sym = dtWord then
    begin
      { Part 24: Abs of an unsigned value is the value. No code, no branch. }
      ParseBuiltInFunction := dtWord;
    end
    else if (Sym = dtInteger) or (Sym = dtByte) then
    begin
      { Abs(x): inline -- negate if negative using two's complement }
      S1 := GetLabel('abs');
      EmitI('POP    D0, XY3');
      EmitI('CMP    D0, #0');
      EmitI('BGE.L  ' + S1);
      EmitI('NOT    D0');
      EmitI('ADD    D0, #1');
      Emit(S1, '', '');
      EmitI('PUSH   D0, XY3');
      ParseBuiltInFunction := dtInteger;
    end
    else if Sym = dtReal then
    begin
      EmitI('popfp');
      EmitI('res 7,b');
      EmitI('pushfp');

      ParseBuiltInFunction := dtReal;
    end
    else Error('Integer or Real expected');
  end
  else if Func = AddrFunc then
  begin
    Expect(toIdent);
    Sym := LookupGlobalOrFail(Scanner.StrValue);
    NextToken;
    ParseVariableAccess(Sym);
    ParseBuiltInFunction := dtInteger;
  end
  else if Func = PtrFunc then
  begin
    TypeCheck(dtInteger, ParseExpression, tcAssign);
    ParseBuiltInFunction := dtPointer;
  end
  else if Func = SizeFunc then
  begin
    Expect(toIdent);
    Sym := LookupGlobalOrFail(Scanner.StrValue);
    NextToken;

    if Sym^.Kind = scVar then
    begin
      Old := Code;
      Sym := ParseVariableAccess(Sym);
      while Code <> Old do RemoveCode;
    end;

    if Sym^.Kind = scSubrangeType then Sym := Sym^.DataType;

    if Sym^.Kind in [scType, scArrayType, scRecordType, scEnumType, scStringType, scFileType] then
      EmitLiteral(Sym^.Value)
    else
      Error('Cannot apply SizeOf to ' + Sym^.Name);

    ParseBuiltInFunction := dtInteger;
  end
  else if Func = OrdFunc then
  begin
    ParseExpression; // TODO TypeCheck for Scalar needed
    ParseBuiltInFunction := dtInteger;
  end
  else if Func = ChrFunc then
  begin
    { Chr(n): value already on stack as integer; result type is Char. No codegen needed. }
    ParseExpression;
    ParseBuiltInFunction := dtChar;
  end
  else if Func = OddFunc then
  begin
    ParseExpression;
    Emit('', 'POP    D0, XY3', 'Odd');
    EmitI('AND    D0, #1');
    EmitI('PUSH   D0, XY3');
    ParseBuiltInFunction := dtBoolean;
  end
  else if Func = EvenFunc then
  begin
    ParseExpression;
    Emit('', 'POP    D0, XY3', 'Even');
    EmitI('AND    D0, #1');
    EmitI('XOR    D0, #1');
    EmitI('PUSH   D0, XY3');
    ParseBuiltInFunction := dtBoolean;
  end
  else if Func = PredFunc then
  begin
    ParseBuiltInFunction := ParseExpression;
    Emit('', 'POP    D0, XY3', 'Pred');
    EmitI('SUB    D0, #1');
    EmitI('PUSH   D0, XY3');
  end
  else if Func = SuccFunc then
  begin
    ParseBuiltInFunction := ParseExpression;
    Emit('', 'POP    D0, XY3', 'Succ');
    EmitI('ADD    D0, #1');
    EmitI('PUSH   D0, XY3');
  end
  else if Func = LengthFunc then
  begin
    { Length(s): inline -- load length byte from string buffer header.
      ParseExpression pushes the string address (and may allocate a 256-byte
      stack temp for literals). We read the length byte then free any temp. }
    TypeCheck(dtString, ParseExpression, tcExact);
    Emit('', 'POP    D0, XY3', 'Length str addr');
    EmitI('MOVE   X0, D0');
    EmitI('LOADI  Y0, #$00');       { set bank BEFORE read (KOS: Emit0 -> MOVE Y0,Y3) }
    EmitI('LOADB  D0, [XY0]');      { D0 = length byte (byte 0 of string) }
    EmitI('LOADI  Y0, #$00');       { restore Y0 convention }
    { Free any 256-byte stack temp allocated for a string literal }
    while StringTempDepth > 0 do
      EmitFreeStringTemp;
    EmitI('PUSH   D0, XY3');        { push integer result }
    ParseBuiltInFunction := dtInteger;
  end
  else if Func = AssignedFunc then
  begin
    { Assigned(p): inline -- True if pointer <> nil (0) }
    ParseExpression;
    Emit('', 'POP    D0, XY3', 'Assigned ptr');
    EmitI('CMP    D0, #0');
    EmitI('SNE    D0');
    EmitI('AND    D0, #1');
    EmitI('PUSH   D0, XY3');
    ParseBuiltInFunction := dtBoolean;
  end
  else if (Func = HighFunc) or (Func = LowFunc) then
  begin
    Expect(toIdent);
    Sym := LookupGlobalOrFail(Scanner.StrValue);
    NextToken;
    if Sym^.Kind = scVar then
    begin
      Old := Code;
      Sym := ParseVariableAccess(Sym);
      while Code <> Old do RemoveCode;
    end;
    if Sym^.Kind = scArrayType then Sym := Sym^.IndexType;
    if Sym^.Kind = scSetType then Sym := Sym^.DataType;
    if Sym = nil then Error('Eeek!');
    if Func = HighFunc then EmitLiteral(Sym^.High) else EmitLiteral(Sym^.Low);

    if Sym^.Kind = scSubrangeType then Sym := Sym^.DataType;

    ParseBuiltInFunction := Sym;
  end
  else if Func = ConcatFunc then
  begin
    TypeCheck(dtString, ParseExpression, tcExact);   { first operand -> addr on TOS }
    if Scanner.Token = toComma then
    begin
      { Part 17: accumulate into ONE static dest, appending each operand. }
      EmitAllocConcatDest;
      MyConcatDest := ConcatDestAddr;   { latch BEFORE any operand can re-enter }
      DepthLeft := StringTempDepth;
      EmitI('POP    D1, XY3');                        { D1 = first operand addr }
      EmitConcatDestAddr(MyConcatDest, 'concat dest (frame)');
      Emit('', 'LOADI  D2, #255', 'max');
      EmitI('CALL24 __storestr');                     { dest := first }
      if DepthLeft > 0 then
      begin
        Emit('', 'ADD    X3, #' + IntToStr(DepthLeft * 256), 'free first temp blocks');
        Dec(StringTempDepth, DepthLeft);
      end;
      while Scanner.Token = toComma do
      begin
        NextToken;
        DepthBeforeRight := StringTempDepth;
        TypeCheck(dtString, ParseExpression, tcExact);
        RightTemps := StringTempDepth - DepthBeforeRight;
        EmitI('POP    D1, XY3');                      { D1 = next operand addr }
        EmitConcatDestAddr(MyConcatDest, 'concat dest');
        EmitI('CALL24 __strappend');                  { dest := dest + next }
        if RightTemps > 0 then
        begin
          Emit('', 'ADD    X3, #' + IntToStr(RightTemps * 256), 'free operand temp blocks');
          Dec(StringTempDepth, RightTemps);
        end;
      end;
      EmitConcatDestAddr(MyConcatDest, 'concat result');
      EmitI('PUSH   D0, XY3');                        { result addr = TOS }
      EmitCloseConcatDest;                            { Part 18: chain done }
    end;

    ParseBuiltInFunction := dtString;
  end
  else if (Func = FilePosFunc) or (Func = FileSizeFunc) or (Func = EolFunc) or (Func = EofFunc) then
  begin
    EmitI('PUSH   D1, XY3');

    T := ParseVariableRef;
    if T^.Kind <> scFileType then Error('File type expected');

    if (T = dtFile) or (T^.DataType = dtFile) then
      Sym := LookupBuiltInOrFail('Block' + Func^.Name)
    else if T = dtText then
      Sym := LookupBuiltInOrFail('Text' + Func^.Name)
    else
      Sym := LookupBuiltInOrFail('File' + Func^.Name);

    EmitCall(Sym);
    ParseBuiltInFunction := Sym^.DataType;
  end
  else
    Error('Cannot handle: ' + Func^.Name);

    Expect(toRParen); NextToken;
end;

(**
 * Parses a format specifier (used in Write, WriteLn and Str statements)
 * and puts the results on the stack.
 *)
function ParseFormat: Integer;
begin
  if Scanner.Token = toColon then
  begin
    NextToken;
    TypeCheck(dtInteger, ParseExpression, tcExpr);
    if Scanner.Token = toColon then
    begin
      NextToken;
      TypeCheck(dtInteger, ParseExpression, tcExpr);
      ParseFormat := 2;
    end
    else ParseFormat := 1;
  end
  else ParseFormat := 0;
end;

(**
 * Parses a built-in procedure, which is basically every pre-defined procedure
 * that does not have a fixed syntax (variable parameters, for instance).
 *
 * TODO Split this into multiple procedures?
 *)
procedure ParseBuiltInProcedure(Proc: PSymbol; BreakTarget, ContTarget: String);
var
  Sym, T, TT, V, U: PSymbol;
  F: Integer;
  SavedDest2: Boolean;
  SavedDestOfs2: Integer;
begin
  if Proc^.Kind <> scProc then
    Error('Not a built-in procedure: ' + Proc^.Name);

  if Proc = AssertProc then
  begin
    NextToken; Expect(toLParen); NextToken;

    TypeCheck(dtBoolean, ParseExpression, tcExact);

    Emit('', 'POP    D0, XY3', '');
    Emit('', 'LOADI  D0, # ' + AddString(Source^.Name), '');
    Emit('', 'LOADI  D1, # ' + IntToStr(Source^.Line), '');
    Emit('', 'CALL24 __assert', '');

    Expect(toRParen); NextToken;
  end
  else if Proc = BreakProc then
  begin
    if BreakTarget = '' then Error('Not in loop');
    Emit('', 'JMP ' + BreakTarget, 'Break');
    NextToken;
  end
  else if Proc = ContProc then
  begin
    if ContTarget = '' then Error('Not in loop');
    Emit('', 'JMP ' + ContTarget, 'Continue');
    NextToken;
  end
  else if Proc = ExitProc then
  begin
    NextToken;
    if Scanner.Token = toLParen then
    begin
      (* Find the result variable (tagged 'RESULT') in the symbol table *)
      Sym := SymbolTable;
      while (Sym <> nil) and ((Sym^.Kind <> scVar) or (Sym^.Tag <> 'RESULT')) do
        Sym := Sym^.Prev;
      if Sym = nil then Error('Exit with value only allowed in functions');

      NextToken;
      EmitAddress(Sym);
      SavedDest2    := DestIsXY2;
      SavedDestOfs2 := DestXY2Offset;
      T := TypeCheck(Sym^.DataType, ParseExpression, tcAssign);
      DestIsXY2     := SavedDest2;
      DestXY2Offset := SavedDestOfs2;
      EmitStore(T);
      Expect(toRParen);
      NextToken;
    end;
    Emit('', 'JMP ' + ExitTarget, 'Exit');
  end
  else if Proc = HaltProc then
    begin
    NextToken;
    if Scanner.Token = toLParen then
    begin
      NextToken;
      TypeCheck(dtByte, ParseExpression, tcExpr);
      (* Part 25: the code is NOT discarded any more -- TRAP_EXIT takes its
         status in D0 and ParseExpression has just left the value there, so
         Halt(1) now reports 1 to kosh. *)
      Expect(toRParen);
      NextToken;
    end
    else if TargetKOS then
      EmitI('LOADI  D0, #0');

    (* Part 25: HALT #0 is the CPU instruction -- under k/OS it stops the
       MACHINE, not the task, so a Halt in a .COM hung the emulator.  Both
       other places codegen ends a program (EmitHeader's entry stub and
       EmitFooter) already branch on TargetKOS; only this one was missed,
       which fits -- bare metal was the default until Part 24 flipped it. *)
    if TargetKOS then
      EmitI('TRAP   #TRAP_EXIT')
    else
      EmitI('HALT   #0')
  end
  else if (Proc = IncludeProc) or (Proc = ExcludeProc) then
  begin
    NextToken;
    Expect(toLParen);
    NextToken;

    V := ParseVariableRef;

    if V^.Kind <> scSetType then Error('Set variable expected');

    Expect(toComma);
    NextToken;

    T := ParseExpression;
(*    if T <> V^.DataType^.DataType then Error('Does not match set type'); *)

    Expect(toRParen);
    NextToken;

    EmitI('POP    D1, XY3');
    EmitI('POP    D0, XY3');

    if Proc = IncludeProc then
      EmitI('CALL24 __setinclude')
    else
      EmitI('CALL24 __setexclude');
  end
  else if (Proc = ReadProc) or (Proc = ReadLnProc) then
  begin
    NextToken;

    if Scanner.Token = toLParen then
    begin
      NextToken;
      T := ParseVariableRef();

      if T = dtText then
      begin
        EmitI('POP    D0, XY3');
        EmitI('STOREP D0, #__cur_file');

        while Scanner.Token = toComma do
        begin
          NextToken;

          EmitI('LOADI  D0, #(__cur_file)');
          EmitI('PUSH   D0, XY3');

          T := ParseVariableRef;

          if T^.Kind = scStringType then
            EmitCall(LookupBuiltInOrFail('TextReadStr'))
          else if T = dtChar then
            EmitCall(LookupBuiltInOrFail('TextReadChar'))
          else if T = dtInteger then
            EmitCall(LookupBuiltInOrFail('TextReadInt'))
          else if T = dtReal then
            EmitCall(LookupBuiltInOrFail('TextReadFloat'))
          else
            Error('Unreadable type');
        end;

        if (Proc = ReadLnProc) and (T^.Kind <> scStringType) then
        begin
          EmitI('LOADI  D0, #(__cur_file)');
          EmitI('PUSH   D0, XY3');
          EmitCall(LookupBuiltInOrFail('TextSeekEoln'));
        end;
      end
      else if T^.Kind = scFileType then
      begin
        EmitI('POP    D0, XY3');
        EmitI('STOREP D0, #__cur_file');

        while Scanner.Token = toComma do
        begin
          NextToken;

          EmitI('LOADI  D0, #(__cur_file)');
          EmitI('PUSH   D0, XY3');

          TT := ParseVariableRef;
          if TT <> T^.DataType then Error('Type mismatch');

          EmitCall(LookupBuiltInOrFail('FileRead'));
        end;
      end
      else
      begin
        EmitI('CALL24 __getline');

        EmitI('POP    D0, XY3');
        EmitReadConsole(T);
        while Scanner.Token = toComma do
        begin
          NextToken;
          T := ParseVariableRef();
          EmitI('POP    D0, XY3');
          EmitReadConsole(T);
        end;
      end;

      Expect(toRParen);
      NextToken;
    end
    else EmitI('CALL24 __getline');
  end
  else if (Proc = WriteProc) or (Proc = WriteLnProc) then
  begin
    NextToken;

    if Scanner.Token = toLParen then
    begin
      NextToken;

      T := ParseExpression();

      if T = dtText then
      begin
        EmitI('POP    D0, XY3');

        EmitI('STOREP D0, #__cur_file');
        EmitSpace(256);
        EmitI('LOADI  D0, #0');
        EmitI('MOVE   D0, X3');
        EmitI('STOREP D0, #__text_buf');

        while Scanner.Token = toComma do
        begin
          NextToken;

          T := ParseExpression;
          F := ParseFormat;

          EmitI('LOADI  D0, #(__text_buf)');
          EmitI('PUSH   D0, XY3');

          V := dtString;

          case F of
            0: EmitStr(T, V);
            1: EmitStr1(T, V); (* Broken? *)
            2: EmitStr2(T, V); (* Broken? *)
          end;

          EmitI('LOADI  D0, #(__cur_file)');
          EmitI('PUSH   D0, XY3');
          EmitI('LOADI  D0, #(__text_buf)');
          EmitI('CALL24 __loadstr');
          EmitCall(LookupBuiltInOrFail('TextWriteStr'));
        end;

        EmitClear(256);

        if Proc = WriteLnProc then
        begin
          EmitI('LOADI  D0, #(__cur_file)');
          EmitI('PUSH   D0, XY3');
          EmitCall(LookupBuiltInOrFail('TextWriteEoln'));
        end;
      end
      else if T^.Kind = scFileType then
      begin
        EmitI('POP    D0, XY3');
        EmitI('STOREP D0, #__cur_file');

        while Scanner.Token = toComma do
        begin
          NextToken;

          EmitI('LOADI  D0, #(__cur_file)');
          EmitI('PUSH   D0, XY3');

          TT := ParseVariableRef;
          if TT <> T^.DataType then Error('Type mismatch');

          EmitCall(LookupBuiltInOrFail('FileWrite'));
        end;

      end
      else
      begin
        case ParseFormat of
          0: EmitWrite(T);
          1: EmitWrite1(T);
          2: EmitWrite2(T);
        end;

        while Scanner.Token = toComma do
        begin
          NextToken;
          T := ParseExpression();
          case ParseFormat of
            0: EmitWrite(T);
            1: EmitWrite1(T);
            2: EmitWrite2(T);
          end;
        end;

        if Proc = WriteLnProc then EmitI('CALL24 __newline');
      end;

      Expect(toRParen);
      NextToken;
    end
    else if Proc = WriteLnProc then EmitI('CALL24 __newline');
  end
  else if Proc = IncProc then
  begin
    NextToken;
    Expect(toLParen);
    NextToken;
    V := ParseVariableRef;
    if (V = dtInteger) or (V = dtWord) then    { Part 24: Word is 16-bit too }
    begin
      if Scanner.Token = toComma then
      begin
        NextToken;
        TypeCheck(dtInteger, ParseExpression, tcExpr);
        EmitI('POP    D2, XY3');
        EmitI('POP    D0, XY3');
        { inline __inc16by: D0=addr, D2=delta.  ADD is sign-agnostic, so the
          same three instructions serve Word -- it simply wraps at 65535. }
        EmitI('MOVE   X0, D0');
        EmitI('LOADI  Y0, #$00');
        EmitI('LOADD  D1, [XY0]');
        EmitI('ADD    D1, D2');
        EmitI('STORED D1, [XY0]');
      end
      else EmitInc(V);
    end
    else if (V = dtByte) or (V = dtChar) or (V^.Kind = scEnumType) then
    begin
      if Scanner.Token = toComma then
      begin
        NextToken;
        TypeCheck(dtInteger, ParseExpression, tcExpr);
        EmitI('POP    D2, XY3');        { D2 = delta }
        EmitI('POP    D0, XY3');        { D0 = var address }
        EmitI('MOVE   X0, D0');
        EmitI('LOADI  Y0, #$00');
        EmitI('LOADB  D1, [XY0]');      { D1 = current byte value }
        EmitI('ADD    D1, D2');
        EmitI('STOREB D1, [XY0]');      { store back }
      end
      else EmitInc(V);
    end
    else Error('Invalid type, need Integer, Word or Byte');

    Expect(toRParen);
    NextToken;
  end
  else if Proc = DecProc then
  begin
    NextToken;
    Expect(toLParen);
    NextToken;
    V := ParseVariableRef;
    if (V = dtInteger) or (V = dtWord) then    { Part 24: Word is 16-bit too }
    begin
      if Scanner.Token = toComma then
      begin
        NextToken;
        TypeCheck(dtInteger, ParseExpression, tcExpr);
        EmitI('POP    D2, XY3');
        EmitI('POP    D0, XY3');
        { inline __dec16by: D0=addr, D2=delta.  SUB is sign-agnostic; Word
          wraps at 0 rather than at -32768. }
        EmitI('MOVE   X0, D0');
        EmitI('LOADI  Y0, #$00');
        EmitI('LOADD  D1, [XY0]');
        EmitI('SUB    D1, D2');
        EmitI('STORED D1, [XY0]');
      end
      else EmitDec(V);
    end
    else if (V = dtByte) or (V = dtChar) or (V^.Kind = scEnumType) then
    begin
      if Scanner.Token = toComma then
      begin
        NextToken;
        TypeCheck(dtInteger, ParseExpression, tcExpr);
        EmitI('POP    D2, XY3');        { D2 = delta }
        EmitI('POP    D0, XY3');        { D0 = var address }
        EmitI('MOVE   X0, D0');
        EmitI('LOADI  Y0, #$00');
        EmitI('LOADB  D1, [XY0]');      { D1 = current byte value }
        EmitI('SUB    D1, D2');
        EmitI('STOREB D1, [XY0]');      { store back }
      end
      else EmitDec(V);
    end
    else Error('Invalid type, need Integer or Byte');

    Expect(toRParen);
    NextToken;
  end
  else if Proc = StrProc then
  begin
    NextToken;
    Expect(toLParen);
    NextToken;

    T := ParseExpression;
    F := ParseFormat;

    Expect(toComma);
    NextToken;

    V := ParseVariableRef;

    case F of
      0: EmitStr(T, V);
      1: EmitStr1(T, V);
      2: EmitStr2(T, V);
    end;

    Expect(toRParen);
    NextToken;
  end
  else if Proc = ValProc then
  begin
    NextToken;
    Expect(toLParen);
    NextToken;

    if ParseExpression^.Kind <> scStringType then Error('String expected');

    Expect(toComma);
    NextToken;

    T := ParseVariableRef;
    if (T <> dtInteger) and (T <> dtReal) and (T^.Kind <> scEnumType) then Error('Numeric variable expected');

    Expect(toComma);
    NextToken;

    U := ParseVariableRef;
    if U <> dtInteger then Error('Integer variable expected');

    { Args were pushed (string, @value, @code) but never loaded into
      registers -- __val_* takes D0=string, D1=@value, D2=@code, so the
      call ran on stale registers and wrote to a wild address. Pop them
      in reverse push order, exactly as FillChar does. }
    EmitI('POP    D2, XY3');       { @code  }
    EmitI('POP    D1, XY3');       { @value }
    EmitI('POP    D0, XY3');       { string }

    if T = dtInteger then
      EmitI('CALL24 __val_int')
    else if T^.Kind = scEnumType then
    begin
      EmitI('LOADI  D1, #' + T^.Tag);   { D1 = enum type tag (count) }
      EmitI('CALL24 __val_enum');
    end
    else
      EmitI('CALL24 __val_float');

    Expect(toRParen);
    NextToken;
  end
  else if Proc = NewProc then
  begin
    NextToken; Expect(toLParen); NextToken;

    Expect(toIdent);
    Sym := LookupGlobalOrFail(Scanner.StrValue);
    NextToken;
    T := ParseVariableAccess(Sym);   { TOS = address of pointer variable }

    { Allocate T^.DataType^.Value bytes; __getmem takes size in D0, returns addr in D0 }
    Emit('', 'LOADI  D0, #' + IntToStr(T^.DataType^.Value), 'New: alloc size');
    EmitI('CALL24 __getmem');        { D0 = allocated address }
    EmitNewStoreBack;                { pop var addr from stack, store D0 into *var }

    Expect(toRParen); NextToken;
  end
  else if Proc = DisposeProc then
  begin
    NextToken; Expect(toLParen); NextToken;

    T := ParseExpression;
    if T^.Kind <> scPointerType then Error('Pointer type needed');

    { __freemem is a no-op bump allocator; pass addr in D0 for future free-list impl }
    EmitI('POP    D0, XY3');
    EmitI('CALL24 __freemem');

    Expect(toRParen); NextToken;
  end
  else if Proc = FillProc then
  begin
    NextToken;
    Expect(toLParen);
    NextToken;

    T := ParseVariableRef;

    Expect(toComma);
    NextToken;

    T := ParseExpression;
    if T <> dtInteger then Error('Integer expr expected');

    Expect(toComma);
    NextToken;

    T := ParseExpression;
    if not ((T = dtInteger) or (T = dtByte) or (T = dtChar) or (T = dtBoolean) or (T^.Kind <> scEnumType)) then Error('Ordinal expr expected');

    Expect(toRParen);
    NextToken;

    EmitI('POP    D2, XY3');
    EmitI('POP    D1, XY3');
    EmitI('POP    D0, XY3');
    EmitI('CALL24 __fillchar');
  end
  else if Proc = AssignProc then
  begin
    NextToken;
    Expect(toLParen);
    NextToken;
    T := ParseVariableRef;
    if T^.Kind <> scFileType then Error('File type expected');
    Expect(toComma);
    NextToken;
    if ParseExpression^.Kind <> scStringType then Error('String expected');
    Expect(toRParen);
    NextToken;

    if (T = dtFile) or (T^.DataType = dtFile) then
      EmitCall(LookupBuiltInOrFail('BlockAssign'))
    else if T = dtText then
      EmitCall(LookupBuiltInOrFail('TextAssign'))
    else
    begin
      EmitLiteral(T^.DataType^.Value);
      EmitCall(LookupBuiltInOrFail('FileAssign'));
    end;
  end
  else if  (Proc = EraseProc) or  (Proc = RenameProc) or (Proc = ResetProc) or (Proc = RewriteProc) or (Proc = AppendProc) or (Proc = CloseProc) or (Proc = FlushProc) or (Proc = SeekEofProc) or (Proc = SeekEolnProc) then
  begin
    NextToken;
    Expect(toLParen);
    NextToken;
    T := ParseVariableRef;
    if T^.Kind <> scFileType then Error('File type expected');
    Expect(toRParen);
    NextToken;

    if (T = dtFile) or (T^.DataType = dtFile) or (Proc = EraseProc) or (Proc = RenameProc) then
      Sym := LookupBuiltInOrFail('Block' + Proc^.Name)
    else if T = dtText then
      Sym := LookupBuiltInOrFail('Text' + Proc^.Name)
    else
      Sym := LookupBuiltInOrFail('File' + Proc^.Name);

    EmitCall(Sym);
  end
  else if Proc = SeekProc then
  begin
    NextToken;
    Expect(toLParen);
    NextToken;
    T := ParseVariableRef;
    if T^.Kind <> scFileType then Error('File type expected');

    Expect(toComma);
    NextToken;

    ParseExpression; // ^.DataType <> dtByte and dtInteger then Error('Integer expected');

    Expect(toRParen);
    NextToken;

    if (T = dtFile) or (T^.DataType = dtFile) then
      EmitCall(LookupBuiltInOrFail('BlockSeek'))
    else if T <> dtText then
      EmitCall(LookupBuiltInOrFail('FileSeek'))
    else
      Error('Not allowed.');
  end
  else if (Proc = BlockReadProc) or (Proc = BlockWriteProc) then
  begin
    NextToken;

    Expect(toLParen);
    NextToken;

    T := ParseVariableRef;
    if T^.Kind <> scFileType then Error('File type expected');

    Expect(toComma);
    NextToken;

    ParseVariableRef; (* Src or dest *)

    Expect(toComma);
    NextToken;

    TypeCheck(dtInteger, ParseExpression, tcExpr);

    if Scanner.Token = toComma then
    begin
      NextToken;
      ParseVariableRef; (* Actual bytes, check for integer!? *)
    end
    else EmitLiteral(0);

    Expect(toRParen);
    NextToken;

    EmitCall(LookupBuiltInOrFail('Block' + Proc^.Name));

    // By Name umlenken auf Implementierung.
  end
  else
    Error('Cannot handle: ' + Proc^.Name);
end;
