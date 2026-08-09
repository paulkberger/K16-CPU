(* -------------------------------------------------------------------------- *)
(* --- Parser -------------------------------------------------------------- *)
(* -------------------------------------------------------------------------- *)
(*                                                                            *)
(* Expression parser: ParseSetConstant, ParseFactor, ParseTerm,              *)
(*   ParseSimpleExpression, ParseExpression, ParseVariableAccess              *)
(* Inline asm: ParseInlineTerm, ParseInlineExpr, ParseInline                 *)
(* Statement parser: ParseStatement, ParseStatementList, ParseWith,          *)
(*   ParseCaseStatement                                                       *)
(* Declaration parser: ParseTypeDef, ParseRecord, ParseArray, ParseVar,      *)
(*   ParseVarList, ParseParamList, ParseProcFunc, ParseDeclarations           *)
(* Block parser: ParseBlock                                                   *)
(*                                                                            *)
(* Depends on: scanner, symbols, codegen, builtins (all included before).    *)
(* -------------------------------------------------------------------------- *)

(* --- Type checker --------------------------------------------------------- *)
(* -------------------------------------------------------------------------- *)

(**
 * Performs assignment type check. Might promote either type to the other
 * depending on the kind of check.
 *)
function TypeCheck(Left, Right: PSymbol; Check: TTypeCheck): PSymbol;
begin
  if Left = nil then Error('Error in TypeCheck: Left = nil');
  if Right = nil then Error('Error in TypeCheck: Right = nil');

  if Left^.Kind = scSubrangeType then Left := Left^.DataType;
  if Right^.Kind = scSubrangeType then Right := Right^.DataType;

  if Left = Right then
  begin
    TypeCheck := Left;
    Exit;
  end;

  if (Left^.Kind = scPointerType) and (Right^.Kind = scPointerType) then
  begin
    if (Left^.DataType <> nil) and (Right^.DataType <> nil) and (Left^.DataType <> Right^.DataType) then
      Error('Incompatible pointer types');

    TypeCheck := Left;
    Exit;
  end;

  if (Left = dtReal) and ((Right = dtInteger) or (Right = dtByte) or (Right = dtWord)) then
  begin
    EmitI('POP    D0, XY3');
    EmitI('CALL24 FLOAT');
    EmitI('pushfp');
    TypeCheck := dtReal;
    Exit;
  end;

  if ((Left = dtInteger) or (Left = dtByte)) and (Right = dtReal) and (Check <> tcAssign) then
  begin
    EmitI('popfp');
    EmitI('exx');
    EmitI('POP    D0, XY3');
    EmitI('exx');
    EmitI('pushfp');
    EmitI('exx');
    EmitI('CALL24 FLOAT');
    EmitI('exx');
    EmitI('popfp');
    EmitI('exx');
    EmitI('pushfp');
    EmitI('exx');
    EmitI('pushfp');
    TypeCheck := dtReal;
    Exit;
  end;

  if Check = tcExpr then
  begin
    if (Left^.Kind = scStringType) and (Right^.Kind = scStringType) then
    begin
      TypeCheck := dtString;
      Exit;
    end;

    if (Left = dtInteger) and (Right = dtByte) or (Left = dtByte) and (Right = dtInteger) then
    begin
      TypeCheck := dtInteger;
      Exit;
    end;

    (* Part 24: Word wins in a mixed expression, so the comparison goes
     * UNSIGNED.  This is the arm that makes `if addr < 40000` work: a number
     * literal is typed Integer at ParseFactor, and if the pair resolved to
     * Integer the compare would be signed and would take the wrong branch
     * above $7FFF -- which is exactly where the Z-machine lives.
     *
     * Delphi widens Word + Integer to a 32-bit Integer instead.  K16 has no
     * wider type to widen to, so `w < i` between two variables is unsigned
     * here where Delphi would make it signed.  Deliberate, and the reason
     * mixing the two in one comparison is worth avoiding in new code. *)
    if ((Left = dtWord) and ((Right = dtInteger) or (Right = dtByte))) or
       (((Left = dtInteger) or (Left = dtByte)) and (Right = dtWord)) then
    begin
      TypeCheck := dtWord;
      Exit;
    end;
  end
  else if Check = tcAssign then
  begin
    if (Left^.Kind = scStringType) and (Right^.Kind = scStringType) then
    begin
      TypeCheck := Left;
      Exit;
    end;

    if (Left^.Kind = scSetType) and (Right^.Kind = scSetType) then
    begin
(*      if (Right^.DataType <> nil) and (Left^.DataType <> Right^.DataType) then
        Error('Sets not compatible'); *)

      TypeCheck := Left;
      Exit;
    end;

    if (Left = dtInteger) and (Right = dtByte) then
    begin
      TypeCheck := dtInteger;
      Exit;
    end
    else if (Left = dtByte) and (Right = dtInteger) then
    begin
      TypeCheck := dtByte;
      Exit;
    end
    (* Part 24: Word <-> Integer assignment is a bit reinterpretation in both
     * directions, matching Delphi with range checks off.  Anything stricter
     * needs a cast on every line of the Z-machine memory layer. *)
    else if (Left = dtWord) and ((Right = dtInteger) or (Right = dtByte)) then
    begin
      TypeCheck := dtWord;
      Exit;
    end
    else if ((Left = dtInteger) or (Left = dtByte)) and (Right = dtWord) then
    begin
      TypeCheck := Left;
      Exit;
    end
  end;

  if (Left^.Kind = scStringType) and (Right = dtChar) then
  begin
    EmitCharToString;
    TypeCheck := dtString;
    Exit;
  end;

  if Check = tcExact then
  begin
    if (Left^.Kind = scStringType) and (Right^.Kind = scStringType) then
    begin
      TypeCheck := dtString;
      Exit;
    end;
  end;

  Error('Type error, expected ' + Left^.Name + ', got ' + Right^.Name);
end;

(* -------------------------------------------------------------------------- *)
(* --- Parser --------------------------------------------------------------- *)
(* -------------------------------------------------------------------------- *)

(**
 * Expects a certain token then consumes it. Shorthand for a very frequent
 * statement sequence. Saves a line of code here and there.
 *)
procedure ParseToken(T: TToken);
begin
  Expect(T);
  NextToken;
end;

(**
 * Parses access to a variable, result in the final address being on the stack.
 * This includes potentially multiple stages of array indexing, record field
 * selection or following pointers. We try to delay the emitting of the address
 * as long as possible in order to avoid additions at runtime when could let
 * the assembler do them at compile-time.
 *)
function ParseVariableAccess(Symbol: PSymbol): PSymbol;
var
  Variable, DataType: PSymbol;
  Size: Integer;
  Offset: Integer;
  Mark: PCode;                 { retract point for a speculative subscript }
  CanFold, IdxKnown: Boolean;
  IdxValue: Integer;

  procedure DelayedEmitAddr;
  begin
    if Offset >= 0 then
    begin
      if Offset = 0 then
        Emit('', 'LOADI  D0, #' + Variable^.Tag, '')
      else
        Emit('', 'LOADI  D0, #' + Variable^.Tag + ' + ' + IntToStr(Offset), '');
      EmitI('PUSH   D0, XY3');
      Offset := -1;
    end;
  end;

begin
  Variable := Symbol;

  if (Symbol^.Tag <> '') and (Symbol^.Tag <> 'RESULT') then
    Offset := 0
  else
  begin
    EmitAddress(Symbol);
    Offset := -1;
  end;

  DataType := Symbol^.DataType;

  while Scanner.Token in [toLBrack, toPeriod, toCaret] do
  begin
    if Scanner.Token = toLBrack then
    begin
      (* Part 23 (2): constant subscripts fold into the deferred address.
       *
       * The Offset accumulator above already does this for record fields --
       * "r.f" costs nothing because the field offset joins the address
       * literal. Arrays used to opt out by calling DelayedEmitAddr as their
       * first act, which forced the address into a register and left a
       * compile-time constant to be recomputed at runtime: W[7] emitted
       * LOADI #7 / ADD D0,D0 / MOVE / POP / ADD to arrive at a number the
       * assembler could have written down.
       *
       * DelayedEmitAddr therefore moves to AFTER the subscript, so constness
       * is known before the base is committed. The base is a compile-time
       * literal on that path and ADD is commutative, so evaluating the index
       * first is order-neutral -- the non-folding path pushes index then
       * base instead of base then index and adds them just the same.
       *
       * Mixed subscripts fall out correctly: A[3,i] folds the 3 and emits
       * LOADI #g_A+3*inner before adding i; A[i,3] takes the runtime path on
       * the first index, which sets Offset to -1, so the second behaves
       * exactly as it did before. A[3].f now folds both stages. *)
      repeat
        NextToken;
        if DataType^.Kind = scArrayType then
        begin
          { Fold only while the address is still deferred, and only with the
            optimizer on -- without it there is no code list to retract. }
          Mark    := Code;
          CanFold := EnableConstSubscript and Optimize and (Offset >= 0);

          TypeCheck(DataType^.IndexType, ParseExpression(), tcExpr);

          { Capture constness NOW: the scale and lower-bound adjust below
            both push, and Emit clears the tracker on any push. }
          IdxKnown := LastLiteralKnown;
          IdxValue := LastLiteralValue;

          Size := DataType^.DataType^.Value;

          if CanFold and IdxKnown and CodeReachable(Mark) then
          begin
            while Code <> Mark do RemoveCode;

            { The evaluation stack is back to what it was, so the tracker no
              longer describes anything this routine emitted. Clear rather
              than restore: over-clearing costs a fold, under-clearing
              miscompiles (Part 22 lesson). }
            LastLiteralKnown := False;

            Inc(Offset, (IdxValue - DataType^.IndexType^.Low) * Size);
            DataType := DataType^.DataType;
          end
          else
          begin
            if DataType^.IndexType^.Low <> 0 then
            begin
              EmitLiteral(DataType^.IndexType^.Low);
              EmitBinOp(toSub, dtInteger);
            end;

            DataType := DataType^.DataType;

            if Size > 1 then
            begin
              case Size of
                2: EmitShl;
                4: begin EmitShl; EmitShl; end;
                else begin
                  EmitLiteral(Size);
                  EmitBinOp(toMul, dtInteger);
                end;
              end;
            end;

            DelayedEmitAddr;
            EmitBinOp(toAdd, dtInteger);
          end;
        end
        else if DataType^.Kind = scStringType then
        begin
          { Same fold as the array case, minus the arithmetic: a string
            element is one byte and the index is already the byte offset
            from the base (byte 0 is the length), so there is no lower
            bound to subtract and no size to scale by. S[0] therefore
            still addresses the length byte, exactly as at runtime. }
          Mark    := Code;
          CanFold := EnableConstSubscript and Optimize and (Offset >= 0);

          TypeCheck(dtInteger, ParseExpression(), tcExpr);

          IdxKnown := LastLiteralKnown;
          IdxValue := LastLiteralValue;

          DataType := dtChar;

          if CanFold and IdxKnown and CodeReachable(Mark) then
          begin
            while Code <> Mark do RemoveCode;
            LastLiteralKnown := False;
            Inc(Offset, IdxValue);
          end
          else
          begin
            DelayedEmitAddr;
            EmitBinOp(toAdd, dtInteger);
          end;
        end
        else Error('Not an array or a string');
      until Scanner.Token <> toComma;

      Expect(toRBrack);

      NextToken;
    end
    else if Scanner.Token = toPeriod then
    begin
      if DataType^.Kind <> scRecordType then
        Error('Not a record');

      NextToken;
      Expect(toIdent);
      Symbol := Lookup(Scanner.StrValue, DataType^.DataType, nil);
      if Symbol = nil  then Error('Unknown field "' + Scanner.StrValue + '"');

      DataType := Symbol^.DataType;

      if Offset >= 0 then
        Inc(Offset, Symbol^.Value)
      else
      begin
      if Symbol^.Value <> 0 then
      begin
        EmitLiteral(Symbol^.Value);
        EmitBinOp(toAdd, dtInteger);
        end;
      end;

      NextToken;
    end
    else
    begin
      DelayedEmitAddr;

      if DataType^.Kind <> scPointerType then
        Error('Not a pointer');

      if DataType = dtPointer then
        Error('Cannot deref generic pointer');

      NextToken;

      EmitI('POP    D0, XY3');
      EmitI('MOVE   X0, D0');
      EmitI('LOADI  Y0, #$00');
      EmitI('LOADD  D0, [XY0]');
      EmitI('PUSH   D0, XY3');

      DataType := DataType^.DataType;
    end;

  end;

  DelayedEmitAddr;

  ParseVariableAccess := DataType;
end;

(**
 * Parses a single actual argument for a procedure or function call.
 *)
procedure ParseArgument(Sym: PSymbol; I: Integer);
var
  Sym2, T: PSymbol;
begin
  if Sym^.ArgIsRef[I] then
  begin
    Expect(toIdent);
    Sym2 := LookupGlobalOrFail(Scanner.StrValue);
    if Sym2^.Kind <> scVar then
      Error('Not a variable: ' + Scanner.StrValue);

    NextToken;

    T := ParseVariableAccess(Sym2);

    if Sym^.ArgTypes[I] <> nil then
      TypeCheck(Sym^.ArgTypes[I], T, tcAssign);
  end
  else
    TypeCheck(Sym^.ArgTypes[I], ParseExpression, tcAssign);
end;

(**
 * Parses the list of actual arguments for a procedure or function call.
 *)
procedure ParseArguments(Sym: PSymbol);
var
  I, J: Integer;
  SavedInArgContext: Boolean;
begin
  I := 0;
  J := Sym^.Value;

  if J <> 0 then
  begin
    Expect(toLParen);
    NextToken;

    SavedInArgContext := InArgContext;
    { Phase 6: enter arg context }
    InArgContext := True;

    I := 0;
    ParseArgument(Sym, I);
    I := I + 1;

    while I < Sym^.Value do
    begin
      Expect(toComma);
      NextToken;
      ParseArgument(Sym, I);
      I := I + 1;
    end;

    InArgContext := SavedInArgContext;

    Expect(toRParen);
    NextToken;
  end
  else if Scanner.Token = toLParen then Error('Arguments not allowed here')
end;

(**
 * Parses a reference to a variable.
 *)
function ParseVariableRef: PSymbol;
var
  Sym: PSymbol;
begin
  Expect(toIdent);
  Sym := LookupGlobalOrFail(Scanner.StrValue);
  if Sym^.Kind <> scVar then Error('Variable expected');
  NextToken;
  ParseVariableRef := ParseVariableAccess(Sym);
end;

(**
 * Parses a set constant and generates a 32 byte block containing the proper
 * bits.
 *
 * TODO Can we keep set constants in a table similar to strings, ensure
 * uniqueness and write them later in one go?
 *)
function ParseSetConstant: PSymbol;
var
  I, J, K: Integer;
  Sym, T: PSymbol;
  S3: string;
  BA: array[0..31] of Byte;
begin
  for I := 0 to 31 do BA[I] := 0;

  T := nil;
  while Scanner.Token <> toRBrack do
  begin
    if Scanner.Token = toNumber then
    begin
      if (T <> nil) and (T <> dtInteger) then Error('Integer expected');

      T := dtInteger;

      I := Scanner.NumValue;
      J := I;
      NextToken;
      if Scanner.Token = toRange then
      begin
        NextToken;
        Expect(toNumber);
        J := Scanner.NumValue;
        NextToken;
      end
    end
    else if (Scanner.Token = toString) or (Scanner.Token = toCaret) then
    begin
      if (T <> nil) and (T <> dtChar) then Error('Char expected');
      if (Length(Scanner.StrValue) <> 1) and (Scanner.Token <> toCaret) then Error('Char expected');

      T := dtChar;

      if Scanner.Token = toCaret then
        I := GetCtrlChar
      else
      I := Ord(Scanner.StrValue[1]);

      J := I;
      NextToken;
      if Scanner.Token = toRange then
      begin
        NextToken;

        if (Scanner.Token <> toString) and (Scanner.Token <> toCaret) then
          Error('Char expected');
        if (Length(Scanner.StrValue) <> 1) and (Scanner.Token <> toCaret) then Error('Char expected');

        if Scanner.Token = toCaret then
          J := GetCtrlChar
        else
        J := Ord(Scanner.StrValue[1]);
        NextToken;
      end
    end
    else if Scanner.Token = toIdent then
    begin
      Sym := LookupGlobalOrFail(Scanner.StrValue);
      if (Sym^.Kind <> scConst) or (Sym^.DataType^.Kind <> scEnumType) then Error('Not an enum const');

      if (T <> nil) and (T <> Sym^.DataType) then Error('Wrong type');
      T := Sym^.DataType;

      I := Sym^.Value;
      J := I;
      NextToken;
      if Scanner.Token = toRange then
      begin
        NextToken;
        Expect(toIdent);
        Sym := LookupGlobalOrFail(Scanner.StrValue);
        if (Sym^.Kind <> scConst) or (Sym^.DataType^.Kind <> scEnumType) then Error('Not an enum const');
        if (T <> nil) and (T <> Sym^.DataType) then Error('Wrong type');

        J := Sym^.Value;
        NextToken;
      end
    end
    else Error('Scalar expected');

    for K := I to J do
    begin
      BA[K shr 3] := BA[K shr 3] or (1 shl (K and 7));
    end;
    if Scanner.Token = toComma then NextToken;
  end;

  S3 := '$' + IntToHex(BA[0], 2);;
  for K := 1 to 31 do S3 := S3 + ',$' + IntToHex(BA[K], 2);
  EmitI('.BYTE ' + S3);

  Sym := CreateSymbol(scSetType, '');
  Sym^.Value := 32;
  Sym^.DataType := T;
  T := Sym;

  ParseSetConstant := T;
end;

(**
 * Parses a factor, which is the smallest building block of an expression. A
 * factor can be a constant, a variable, a function call or a literal number,
 * string, set or pointer. We also handle unary operators on this level.
 *)
function ParseFactor: PSymbol;
var
  Sym: PSymbol; T: PSymbol;
  Op: TToken;
  S1, S2, Tag: String;
  OldCtx: Boolean;
begin
  if Scanner.Token = toIdent then
  begin
    Sym := LookupGlobalOrFail(Scanner.StrValue);

    (* This is a dirty hack, but ok for now. *)
    if (Sym^.Kind = scVar) and (Sym^.Tag = 'RESULT') then
      Sym := Sym^.Prev^.Prev;

    if (Sym^.Kind = scVar) and (Sym^.IsMagic) then
    begin
      NextToken;
      T := ParseBuiltInVarRead(Sym);
    end
    else if Sym^.Kind = scVar then
    begin
      NextToken;
      T := ParseVariableAccess(Sym);

      // if not (T^.Kind in [scType, scEnumType]) then Error('" ' + Sym^.Name + '" is not a simple type.');
      (* File types are never communicated by value, only by reference. *)
      if (T^.Kind <> scFileType) and (T <> dtText) then EmitLoad(T);

      { Part 18 Phase 1b(A2): the deref for a by-value String parameter now lives
        in EmitAddress, where it also covers assignment targets and s[i]. Doing
        it here as well would dereference twice. }
    end
    else if Sym^.Kind = scConst then
    begin
      T := Sym^.DataType;
      if T = dtReal then
      begin
        EmitI('constfp ' + Sym^.Tag);
        EmitI('pushfp');
      end
      else
      begin
        if (Sym^.Tag <> '') and (T^.Kind = scStringType) then
        begin
          EmitAllocStringTemp;                { SUB X3,#256; D0=dest; TempDepth++ }
          Emit('', 'LOADI  D1, #' + Sym^.Tag, 'String const (ROM addr)');
          EmitI('CALL24 __loadstr');           { __loadstr(dest=D0, rom=D1) }
          EmitI('PUSH   D0, XY3');            { push dest addr as string value }
        end
        else
          EmitLiteral(Sym^.Value);           { int/enum const (e.g. False/True): ordinal value }
      end;
      NextToken;
    end
    else if (Sym^.Kind = scFunc) and (Sym^.IsMagic) then
    begin
      T := ParseBuiltInFunction(Sym);
    end
    else if Sym^.Kind = scFunc then
    begin
      T := Sym^.DataType;
      NextToken;
      ParseArguments(Sym);
      if T^.Kind = scStringType then
      begin
        { V2 string function ABI: D0=dest, D1=arg1, D2=arg2, stack=remaining args.
          Pop register args BEFORE dest buf allocation so SUB X3,#256 doesn't
          push them out of reach of the pops. }
        if Sym^.Value >= 2 then EmitI('POP    D2, XY3');
        if Sym^.Value >= 1 then EmitI('POP    D1, XY3');
        { Allocate dest -- use static buf to avoid SUB X3,#256 creating gap to stack args }
        OldCtx := InArgContext;
        InArgContext := True;   { force static allocation }
        EmitAllocStringTemp;    { LOADI D0, #static_addr -- no stack movement }
        InArgContext := OldCtx;
        EmitI('PUSH   D0, XY3');
      end;
      EmitCall(Sym);
    end
    else if Sym^.Kind in [scType,scEnumType] then
    begin
      NextToken;
      Expect(toLParen);
      NextToken;
      ParseExpression();
      Expect(toRParen);
      NextToken;

      T := Sym;
    end
    else
    begin
      Error('"' + Scanner.StrValue + '" cannot be used in expressions.');
    end;
  end
  else if Scanner.Token = toString then
  begin
    if Length(Scanner.StrValue)=1 then
    begin
      T := dtChar;
      EmitLiteral(Ord(Scanner.StrValue[1]));
    end
    else
    begin
      T := dtString;
      Tag := AddString(Scanner.StrValue);
      EmitAllocStringTemp;                { SUB X3,#256; D0=dest; TempDepth++ }
      Emit('', 'LOADI  D1, #' + Tag, 'String literal (ROM addr)');
      EmitI('CALL24 __loadstr');           { __loadstr(dest=D0, rom=D1) }
      EmitI('PUSH   D0, XY3');            { push dest addr as string value }
      { EmitLoad not called: address is now a RAM address, no further load needed }
    end;
    NextToken;
  end
  else if Scanner.Token = toCaret then
  begin
    T := dtChar;
    EmitLiteral(GetCtrlChar);
    NextToken;
  end
  else if Scanner.Token = toFloat then
  begin
    T := dtReal;
    //Tag := AddString(Scanner.StrValue + ' ');
    EmitI('constfp ' + EncodeReal(Scanner.StrValue));
    EmitI('pushfp');
    NextToken;
  end
  else if Scanner.Token = toNumber then
  begin
    (* Part 24: nothing used to check this at all -- 70000 reached the
     * assembler as LOADI D0, #70000.  The window is the union of Integer and
     * Word, because a literal is typed Integer here and only becomes a Word
     * through TypeCheck; 40000 must be legal, 70000 must not. *)
    if (Scanner.NumValue < -32768) or (Scanner.NumValue > 65535) then
      Error('Number out of range for a 16-bit type: ' + IntToStr(Scanner.NumValue));
    T := dtInteger;
    EmitLiteral(Scanner.NumValue);
    NextToken;
  end
  else if Scanner.Token = toNil then
  begin
    T := dtPointer;
    EmitLiteral(0);
    NextToken;
  end
  (* true false + String constants *)
  else if Scanner.Token = toLParen then
  begin
    NextToken; T := ParseExpression; Expect(toRParen); NextToken;
  end
  else if Scanner.Token = toLBrack then
  begin
    NextToken;

    S1 := GetLabel('set');
    S2 := GetLabel('set');
    EmitI('JMP    ' + S2);
    Emit(S1, '', '');

    T := ParseSetConstant();

    Emit(S2, '', '');

    if TargetKOS then
    begin
      { k/OS: set literal lives in the task page (Y3), not ROM. Task-page copy. }
      Emit('', 'LOADI  D1, #' + S1,     'Set literal src (task page)');
      Emit('', 'SUB    X3, #' + IntToStr(T^.Value), 'alloc ' + IntToStr(T^.Value) + 'b on stack');
      EmitI('MOVE   D0, X3');
      Emit('', 'LOADI  D2, #' + IntToStr(T^.Value), '');
      EmitI('CALL16 __memcopy');        { D0=dest, D1=src, D2=count (both task page) }
    end
    else
    begin
      { Set literal is in ROM (bank $FF). Copy 32 bytes to stack inline.
        Use LOADI Y1,#$FF so __memcopy reads from ROM, not RAM. }
      Emit('', 'LOADI  D1, #' + S1,     'Set literal src (ROM)');
      Emit('', 'LOADI  Y1, #$FF',        'ROM bank');
      Emit('', 'SUB    X3, #' + IntToStr(T^.Value), 'alloc ' + IntToStr(T^.Value) + 'b on stack');
      EmitI('MOVE   D0, X3');
      Emit('', 'LOADI  D2, #' + IntToStr(T^.Value), '');
      EmitI('CALL24 __memcopy_ff');      { D0=dest(RAM), D1=src(ROM $FF), D2=count }
    end;

    Expect(toRBrack);
    NextToken;
  end
  else if Scanner.Token = toAt then
  begin
    { @ address-of operator: push address of variable, return dtPointer }
    NextToken;
    Expect(toIdent);
    Sym := LookupGlobalOrFail(Scanner.StrValue);
    NextToken;
    Sym := ParseVariableAccess(Sym);  { handles field/array suffixes }
    { ParseVariableAccess leaves address on stack without loading value }
    T := dtPointer;
  end
  else if Scanner.Token in [toAdd, toSub, toNot] then
  begin
    Op := Scanner.Token;
    NextToken;
    T := ParseFactor();
    if T = dtChar then Error('not only applicable to Integer, Byte, Real or Boolean');
    case Op of
      toAdd: begin (* Nop *) end;
      toSub: EmitNeg(T);
      toNot: EmitUnOp(toNot, T);
    end;
  end
  else Error('Factor expected');

  ParseFactor := T;
end;

(**
 * Parses a term, which can be a factor or any number of factors connected by
 * multiplicative, dividing or bitshifting operators.
 *)
function ParseTerm: PSymbol;
var
  Op: TToken;
  T: PSymbol;
begin
  T := ParseFactor;

  if T^.Kind = scSubrangeType then T := T^.DataType;

  (* Part 24: Word joins the gate.  This loop is selected by the LEFT
     operand's type, so a type missing from the list does not produce a type
     error -- the loop is skipped, the operator is never consumed, and the
     failure surfaces further up as "Expected ",", but got "div"".  Same
     shape as EmitInc's `= dtInteger`: a type-identity list that Word was
     not in, failing somewhere other than where the omission is. *)
  if (T = dtInteger) or (T = dtByte) or (T = dtWord) then
    while Scanner.Token in [toMul, toDiv, toDivKW, toMod, toAnd, toShl, toShr] do
    begin
      Op := Scanner.Token;
      NextToken;
      if Op = toDiv then T := TypeCheck(dtReal, T, tcExpr);
      T := TypeCheck(T, ParseFactor, tcExpr);
      if T = dtReal then EmitFloatOp(Op) else EmitBinOp(Op, T);
    end
  else if T = dtBoolean then
    while Scanner.Token = toAnd do
    begin
      Op := Scanner.Token;
      NextToken;
      T := TypeCheck(T, ParseFactor, tcExact);
      EmitBinOp(Op, T);
    end
  else if T = dtReal then
    while Scanner.Token in [toMul, toDiv, toMod] do
    begin
      Op := Scanner.Token;
      NextToken;
      T := TypeCheck(T, ParseFactor, tcExpr);
      EmitFloatOp(Op);
    end
  else if T^.Kind = scSetType then
    while Scanner.Token in [toMul] do
    begin
      Op := Scanner.Token;
      NextToken;
      T := ParseFactor; (* TypeCheck(T, , tcExpr); *)
      EmitSetOp(Op);
    end;

  ParseTerm := T;
end;

(**
 * Parses a simple expression, which can be a term or any number of terms
 * connected by additive or subtrative operators.
 *)
function ParseSimpleExpression: PSymbol;
var
  Op: TToken;
  T: PSymbol;
  RightTemps, DepthBeforeRight, DepthLeft: Integer;
  MyConcatDest: Integer;   { Part 17: own slot -- ConcatDestAddr is global and
                             a parenthesised operand re-enters this code }
begin
  T := ParseTerm;

  if T^.Kind = scSubrangeType then T := T^.DataType;

  if (T = dtInteger) or (T = dtByte) or (T = dtWord) then    { Part 24 }
    while Scanner.Token in [toAdd, toSub, toOr, toXor] do
    begin
      Op := Scanner.Token;
      NextToken;
      T := TypeCheck(T, ParseTerm, tcExpr);
      if T = dtReal then EmitFloatOp(Op) else EmitBinOp(Op, T);
    end
  else if T = dtBoolean then
    while Scanner.Token in [toOr, toXor] do
    begin
      Op := Scanner.Token;
      NextToken;
      T := TypeCheck(T, ParseTerm, tcExact);
      EmitBinOp(Op, T);
    end
  else if (T = dtChar) or (T^.Kind = scStringType) then
  begin
    if Scanner.Token = toAdd then
    begin
      { Part 17: accumulate into ONE static dest, appending each operand.
        Removes the freed-space result / __stradd-aliasing fragility. }
      T := TypeCheck(dtString, T, tcExact);          { promote char->string }
      EmitAllocConcatDest;
      MyConcatDest := ConcatDestAddr;   { latch BEFORE any operand can re-enter }
      DepthLeft := StringTempDepth;
      EmitI('POP    D1, XY3');                        { D1 = left addr }
      EmitConcatDestAddr(MyConcatDest, 'concat dest (frame)');
      Emit('', 'LOADI  D2, #255', 'max');
      EmitI('CALL24 __storestr');                     { dest := left }
      if DepthLeft > 0 then
      begin
        Emit('', 'ADD    X3, #' + IntToStr(DepthLeft * 256), 'free left temp blocks');
        Dec(StringTempDepth, DepthLeft);
      end;
      while Scanner.Token = toAdd do
      begin
        NextToken;
        DepthBeforeRight := StringTempDepth;
        T := TypeCheck(dtString, ParseTerm, tcExact); { right addr on TOS (+temp) }
        RightTemps := StringTempDepth - DepthBeforeRight;
        EmitI('POP    D1, XY3');                      { D1 = right addr }
        EmitConcatDestAddr(MyConcatDest, 'concat dest');
        EmitI('CALL24 __strappend');                  { dest := dest + right }
        if RightTemps > 0 then
        begin
          Emit('', 'ADD    X3, #' + IntToStr(RightTemps * 256), 'free right temp blocks');
          Dec(StringTempDepth, RightTemps);
        end;
      end;
      EmitConcatDestAddr(MyConcatDest, 'concat result');
      EmitI('PUSH   D0, XY3');                        { result addr = TOS }
      EmitCloseConcatDest;                            { Part 18: chain done }
    end
  end
  else if T = dtReal then
    while Scanner.Token in [toAdd, toSub] do
    begin
      Op := Scanner.Token;
      NextToken;
      T := TypeCheck(T, ParseTerm, tcExpr);
      EmitFloatOp(Op);
    end
  else if T^.Kind = scSetType then
    while Scanner.Token in [toAdd, toSub] do
    begin
      Op := Scanner.Token;
      NextToken;
      T := ParseTerm; (* TypeCheck(T, , tcExpr); *)
      EmitSetOp(Op);
    end;


(* TODO Error case? *)

  (* WriteLn('Type of SimpleExpression is ', T); *)

  ParseSimpleExpression := T;
end;

(**
 * Parses an expression, which can be one simple expression or two simple
 * expressions connected by a relational operator.
 *)
function ParseExpression: PSymbol;
var
  Op: TToken;
  T, U: PSymbol;
  RightTemps, DepthBeforeRight: Integer;
begin
  T := ParseSimpleExpression;
  if Scanner.Token = toIn then
  begin
    if not (T^.Kind in [scType, scEnumType, scSubrangeType]) then Error('Scalar needed');
    (* if T^.Value <> 1 then Error('8 bit needed'); *) (* FIXME!!! *)

    NextToken;
    U := ParseExpression;
    if U^.Kind <> scSetType then Error('Set needed');
    (* if U^.DataType <> T then Error('Incompatible');    *) (* FIXME!!! *)

    EmitSetOp(toIn);

    T := dtBoolean;
  end
  else if (T^.Kind = scSetType) and (Scanner.Token in [toEq, toNeq, toLeq, toGeq]) then
  begin
    Op := Scanner.Token;
    NextToken;

    U := ParseExpression;
    if U^.Kind <> scSetType then Error('Set needed');
    // if U^.DataType <> T^.DataType then Error('Incompatible');  // FIXME!!!

    EmitSetOp(Op);

    T := dtBoolean;
  end
  else if (Scanner.Token >= toEq) and (Scanner.Token <= toGeq) then
  begin
    Op := Scanner.Token;
    NextToken;
    if T^.Kind = scStringType then
    begin
      { String comparison: leave left addr on stack, evaluate right,
        then retrieve left addr from stack below right's temp blocks. }
      DepthBeforeRight := StringTempDepth;
      T := TypeCheck(T, ParseSimpleExpression, tcExpr);
      EmitI('POP    D1, XY3');                       { D1 = right addr }
      RightTemps := StringTempDepth - DepthBeforeRight;
      if RightTemps > 0 then
      begin
        { Peek left addr from below right temp blocks }
        Emit('', 'LOADI  D2, #' + IntToStr(RightTemps * 256), 'offset to left addr');
        EmitI('MOVE   X0, X3');
        EmitI('LOADI  Y0, #$00');
        EmitI('LOADD  D0, [XY0+D2]');  { D0 = left addr }
        { Free right temps + left addr word BEFORE calling compare }
        Emit('', 'ADD    X3, #' + IntToStr(RightTemps * 256 + 2), 'free right temps + left addr');
        Dec(StringTempDepth, RightTemps);
      end
      else
        EmitI('POP    D0, XY3');      { D0 = left addr (no right temps) }
      { Free left's own temp blocks before call }
      if DepthBeforeRight > 0 then
      begin
        Emit('', 'ADD    X3, #' + IntToStr(DepthBeforeRight * 256), 'free left temp blocks');
        Dec(StringTempDepth, DepthBeforeRight);
      end;
      { D0=left, D1=right survive ADD X3; call compare, push result }
      case Op of
        toEq, toNeq: EmitI('CALL24 __streq');
        toLt, toGeq: EmitI('CALL24 __strlt');
        toGt, toLeq: EmitI('CALL24 __strleq');
      end;
      { AND #1 to normalise Scc-style result if needed (streq etc return 0/1 already) }
      if (Op = toNeq) or (Op = toGt) or (Op = toGeq) then
        EmitI('XOR    D0, #1');
      EmitI('AND    D0, #1');
      EmitI('PUSH   D0, XY3');
    end
    else
    begin
      T := TypeCheck(T, ParseSimpleExpression, tcExpr);
      if T = dtReal then
        EmitFloatOp(Op)
      else
        EmitRelOp(Op, IsUnsignedType(T));
    end;
    T := dtBoolean;
  end;

  (* WriteLn('Type of Expression is ', T); *)

  ParseExpression := T;
end;

(**
 * Parses an assignment.
 *)
procedure ParseAssignment(Sym: PSymbol);
var
  T: PSymbol;
  SavedDest, SavedPaged: Boolean;
  SavedDestOfs: Integer;
  SavedPagedAddr, Reg: String;
  Mark: PCode;
begin
  if Sym^.Kind <> scVar then Error('"' + Scanner.StrValue + '" not a var.');
  NextToken;

  { Reset the frame-slot dest flag so it reflects ONLY this assignment's LHS.
    A global LHS emits its address inline (not via EmitAddress) and would
    otherwise inherit a stale DestIsXY2 left True by a preceding frame access
    (e.g. loading a param in the enclosing condition), causing EmitStore to
    mis-store to [XY2+#N] instead of the global. }
  DestIsXY2 := False;

  Mark := Code;
  T := ParseVariableAccess(Sym);

  { The frame-slot fast path is valid ONLY when the [XY2+#N] address push IS
    the destination. EmitAddress sets DestIsXY2 on the first frame access it
    meets in the LHS, and for `A[v] := x' that is the INDEX v -- so EmitStore
    would store the value into v's own frame slot instead of the element.
    (Part 26. The address arithmetic was always right; only the final store
    instruction was chosen from the wrong descriptor, which is why reads
    through the same index worked and the fault was silent.)

    If anything was emitted after that push -- array base arithmetic, a field
    offset, a deref -- the push was a subexpression, not ours. Rejecting the
    flag costs three instructions: the generic path then emits
    MOVE X0,D0 / LOADI Y0,#$00 / STORED D1,[XY0], which is correct.

    This must run BEFORE the DestIsPaged block below, which calls RemoveCode
    and so moves Code. }
  if DestIsXY2 and (DestXY2Mark <> Code) then DestIsXY2 := False;

  (* Part 23 (5.4): a compile-time LHS address need not go on the stack.
   *
   * If ParseVariableAccess emitted EXACTLY
   *
   *     LOADI  Dn, #addr
   *     PUSH   Dn, XY3
   *
   * and nothing else (Code^.Prev^.Prev = Mark), the destination is a constant
   * the assembler can write down -- a global, or an element reached entirely
   * by the constant-subscript fold. Retracting the push lets EmitStore use
   * STOREP instead of popping an address back off the stack.
   *
   * The two-node test is what makes this exact rather than a guess: a runtime
   * address (M[i][k], a var parameter, a pointer deref) leaves arithmetic
   * behind and fails it, and a frame slot emits MOVE D0,X2 / ADD D0,#N /
   * PUSH, which fails the LOADI test as well.
   *
   * Restricted to 1- and 2-byte scalars. Strings and records need the address
   * on the stack: EmitStore's string path reaches past the RHS temp blocks to
   * find it, and the large-type path hands it to __memcopy.
   *
   * Retracting is free of side effects -- the address is a literal, and the
   * RHS has not been parsed yet, so nothing has been evaluated out of order. *)
  DestIsPaged := False;
  if EnablePagedDest and Optimize and (T <> nil) and (T^.Kind <> scStringType)
    and ((T^.Value = 1) or (T^.Value = 2))
    and (Code <> nil) and (Code^.Prev <> nil)
    and (Code^.Prev^.Prev = Mark)
    and (Code^.Tag = '') and (Code^.Prev^.Tag = '')
    and (Copy(Code^.Prev^.Instruction, 1, 8) = 'LOADI  D')
    and (Copy(Code^.Prev^.Instruction, 10, 3) = ', #') then
  begin
    Reg := Copy(Code^.Prev^.Instruction, 8, 2);
    if Code^.Instruction = 'PUSH   ' + Reg + ', XY3' then
    begin
      DestPagedAddr := Copy(Code^.Prev^.Instruction, 13, 255);
      RemoveCode;                        { the PUSH  }
      RemoveCode;                        { the LOADI }
      DestIsPaged := True;
    end;
  end;

  Expect(toBecomes);
  NextToken;

  { Save LHS dest info before RHS evaluation clobbers it }
  SavedDest    := DestIsXY2;
  SavedDestOfs := DestXY2Offset;
  SavedPaged     := DestIsPaged;
  SavedPagedAddr := DestPagedAddr;

  T := TypeCheck(T, ParseExpression, tcAssign);

  { Restore LHS dest info for EmitStore }
  DestIsXY2    := SavedDest;
  DestXY2Offset := SavedDestOfs;
  DestIsPaged    := SavedPaged;
  DestPagedAddr  := SavedPagedAddr;

  EmitStore(T);
end;

procedure ParseStatement(ContTarget, BreakTarget: String); forward;

(**
 * Parses a single "with" variable, which must be of a record type. Creates
 * "proxy" variables for all fields contained in the record.
 *
 * TODO Should we simply create a scope instead of this "stunt" using anonymous
 * variables?
 *)
procedure ParseWithVar;
var
  Sym, Field, FieldRef, DataType: PSymbol;
  Address: Integer;
begin
  Expect(toIdent);
  Sym := LookupGlobalOrFail(Scanner.StrValue);
  if Sym^.Kind <> scVar then Error('Variable expected');
  NextToken;

  Offset := Offset - 2;
  Address := Offset;
  DataType := ParseVariableAccess(Sym);   { leaves the record address on TOS }

  if DataType^.Kind <> scRecordType then Error('Record type expected');

  (* Part 20: put the base in a RESERVED frame slot instead of leaving it on
   * the stack.
   *
   * Field references address the base at X2+Address, and the old code simply
   * let ParseVariableAccess's PUSH land there. That silently required
   * X3 = X2 - CurrentLocalBytes right after the prologue -- true until Part 19
   * inserted the concat-dest area between them. It stayed latent because no
   * routine using `with` had a dest; Part 20 gives every routine with String
   * arguments one, and TestWith's base was then read 512 bytes above where it
   * had been pushed.
   *
   * The slot now lives in the frame, immediately below the locals and above
   * the dests, so -Address is exactly its offset and needs no symbol. The
   * dests move down by NoteWithBytes -- see EmitConcatDestAddr. Nothing is
   * left on the stack, so an early Break/Exit out of a `with` can no longer
   * unbalance it either (the TODO below is answered by this). *)
  NoteWithBytes(-Address - CurrentLocalBytes);
  EmitI('POP    D0, XY3');
  EmitI('MOVE   D1, X2');
  Emit('', 'SUB    D1, #' + IntToStr(-Address), 'with base slot');
  EmitI('MOVE   X1, D1');
  EmitI('MOVE   Y1, Y3');
  EmitI('STORED D0, [XY1]');

  Field := DataType^.DataType;
  while Field <> nil do
  begin
    FieldRef := CreateSymbol(scVar, ''); // Create anonymously so duplicate
    FieldRef^.Name := Field^.Name;       // identifiers are not a problem
    FieldRef^.DataType := Field^.DataType;
    FieldRef^.Value := Address;
    FieldRef^.Value2 := Field^.Value;
    FieldRef^.IsRef := True;
    FieldRef^.Level := Level;
    Field := Field^.Prev;
  end;
end;

(**
 * Parses a "with" statement, "opening" the scopes of a single record variable
 * or a list of such variables and making the contained fields directly
 * accessible as variables.
 *)
procedure ParseWith(ContTarget, BreakTarget: String);
var
  OldSymbols, Sym: PSymbol;
  Count, I: Integer;
begin
  OldSymbols := SymbolTable;

  ParseWithVar;
  Count := 1;

  while Scanner.Token = toComma do
  begin
    NextToken;
    ParseWithVar;
    Inc(Count);
  end;

  Expect(toDo);
  NextToken;

  // TODO Check global (not in unit tests), Local, Var, Nested, Comma
  // Optimize simple case 'with R do X := 5;' to avoid double addressing

  // TODO What happens to the stack if we exit a with statement early via
  // Break or Exit?

  ParseStatement(ContTarget, BreakTarget);

  { Part 20: the bases live in frame slots now -- no stack cleanup to do. }
  Offset := Offset + 2 * Count;

  while SymbolTable <> OldSymbols do
  begin
    Sym := SymbolTable;
    SymbolTable := SymbolTable^.Prev;
    FreeMem(Sym);
  end;
end;

(**
 * Parses an inline term, which is, in the easiest case, a number representing
 * a K16 instruction, but can also refer to identifiers such as constants, variables,
 * procedures or functions (in which case either the value or the address would
 * be inserted into the outgoing assembly code). The special symbol "*" refers
 * to the "current address" and allows PC-relative addressing (useful for
 * relative jumps).
 *)
procedure ParseInlineTerm(var S: String; var W: Boolean);
var
  Sym: PSymbol;
begin
  if Scanner.Token = toNumber then
  begin
    S := S + IntToStr(Scanner.NumValue);
    if Scanner.NumValue > 255 then W := True;
    NextToken;
  end
  else if Scanner.Token = toIdent then
  begin
    Sym := LookupGlobalOrFail(Scanner.StrValue);

    if (Sym^.Kind = scConst) and (Sym^.DataType = dtInteger) then
    begin
      S := S + IntToStr(Sym^.Value);
      if Sym^.Value > 255 then W := True;
    end
    else if (Sym^.Kind = scVar) and (Sym^.Level = 0) then
    begin
      S := S + Sym^.Tag;
      W := True;
    end
    else if (Sym^.Kind = scVar) and (Sym^.Level > 0) then
    begin
      S := S + IntToStr(Sym^.Value);
      W := True;
    end
    else if (Sym^.Kind = scProc) or (Sym^.Kind = scFunc) then
    begin
      S := S + Sym^.Tag;
      W := True;
    end
    else
      Error(S + ' not allowed here');

    NextToken;
  end
  else if Scanner.Token = toMul then
  begin
    S := S + '$';
    W := True;
    NextToken;
  end
  else if (Scanner.Token = toString) and (Length(Scanner.StrValue) = 1) then
  begin
    S := S + IntToStr(Ord(Scanner.StrValue[1]));
    NextToken;
  end
  else Error('Invalid inline code');
end;

(**
 * Parses a single expression inside an inline statement, which is mainly a list
 * of inline terms connected by additive or subtractive operators.
 *)
procedure ParseInlineExpr;
var
  S: String;
  W: Boolean;
  O: TToken;
begin
  S := '';
  W := False;
  O := toNone;

  if Scanner.Token in [toLt, toGt] then
  begin
    O := Scanner.Token;
    NextToken;
  end;

  ParseInlineTerm(S, W);
  while Scanner.Token in [toAdd, toSub] do
  begin
    W := True;
    if Scanner.Token = toAdd then S := S + '+' else S := S + '-';
    NextToken;
    ParseInlineTerm(S, W);
  end;

  if O = toLt then
    EmitI('.BYTE <' + S)
  else if (O = toGt) or W then
    EmitI('.WORD ' + S)
  else EmitI('.BYTE ' + S);
end;

(**
 * Parses an inline statement including the opening and closing parentheses. It
 * consists of a number of inline expressions separated by "/" characters.
 *)
procedure ParseInline;
begin
  Expect(toLParen);
  NextToken;

  if Scanner.Token <> toRParen then
  begin
    ParseInlineExpr;
    while Scanner.Token = toDiv do
    begin
      NextToken;
      ParseInlineExpr;
    end;
  end;

  Expect(toRParen);
  NextToken;
end;

procedure ParseCaseValue(T: PSymbol; var V: Integer);
var
  C: PSymbol;
  Neg: Boolean;
begin
  (* Part 24: a Word selector takes Integer-typed labels, exactly as Byte
     does.  Without this, `case w of 0: ...` is "Invalid type".
     Caveat worth knowing before relying on it: the label VALUES are still
     compared as written, so a label above 32767 against a Word selector is
     not covered by the unsigned work -- fine for opcode dispatch, wrong for
     dispatching on an address. *)
  if (T = dtByte) or (T = dtWord) then T := dtInteger;

  { Signed case labels. A leading '-' is toSub, which the label-group loop
    below also has to admit, or "case n of -3:" reads as an empty case. }
  Neg := False;
  if (Scanner.Token = toSub) or (Scanner.Token = toAdd) then
  begin
    if T <> dtInteger then Error('Signed case label needs an integer selector');
    Neg := Scanner.Token = toSub;
    NextToken;
    if Scanner.Token <> toNumber then Error('Number expected after sign');
  end;

  if Scanner.Token = toIdent then
  begin
    C := LookupGlobalOrFail(Scanner.StrValue);
    if C^.Kind <> scConst then Error('Const expected');
    if C^.DataType <> T then Error('Invalid type');
    V := C^.Value;
  end
  else if Scanner.Token = toNumber then
  begin
    if T <> dtInteger then Error('Invalid type');
    V := Scanner.NumValue;
  end
  else if Scanner.Token = toCaret then
  begin
    if T <> dtChar then Error('Invalid type');
    V := GetCtrlChar;
  end
  else (* toString *)
  begin
    if Length(Scanner.StrValue) <> 1 then Error('Invalid type');
    if T <> dtChar then Error('Invalid type');
    V := Ord(Scanner.StrValue[1]);
  end;

  if Neg then V := -V;

  NextToken;
end;

(* ---------------------------------------------------------------------------
 * case statement  (Part 23, section 5.5: JMPT dispatch)
 *
 * The old shape interleaved tests with bodies and kept the selector on the
 * stack, popping and re-pushing it for every label tested -- 18 cycles per
 * label, so a 16-way case averaged 144 and cost 288 at worst.
 *
 * Both dispatch forms now share one layout: bodies first, each with a label,
 * then a single dispatch at the end.
 *
 *     <selector>            pushed
 *     JMP  dispatch
 *   case1:  <body>  JMP end
 *   case2:  <body>  JMP end
 *   celse:  <else>  JMP end
 *   dispatch:
 *     ...                   JMPT, or a compare chain
 *   table:  .WORD ...       (JMPT form only; never executed -- JMPT always jumps)
 *   end:
 *
 * Emitting bodies before the dispatch is what makes the choice possible at
 * all: the label range is not known until the last label has been parsed, and
 * by then the bodies are already out. It also makes the FALLBACK faster --
 * the selector stays in D0 across the whole chain instead of being popped and
 * pushed per test, so a compare costs CMP + Bcc = 7 cycles rather than 18.
 *
 * JMPT is chosen when the label set is dense enough to be worth a table.
 * Dispatch costs, measured from the table below:
 *     chain   4 + 7N cycles for N labels tested (average N/2 on a hit)
 *     JMPT    ~34 cycles flat, plus Span words of table
 * Break-even is around five labels, hence the Span >= 5 floor.
 *
 * JMPT is an indexed INDIRECT jump (Reference Manual s6.9): the target word
 * is fetched from mem[Yn:Xn+Dm] and the new PC is Yn:that. Both the table and
 * the bodies therefore have to live in page Yn -- which is the task page (Y3)
 * on k/OS and the ROM bank on bare metal, so the page register is set
 * per-target rather than through the usual LOADI Yn,#$00 idiom.
 * --------------------------------------------------------------------------- *)

const
  MaxCaseGroups = 128;      { label groups per case statement }
  MaxCaseSpan   = 256;      { largest jump table we will build }
  MinCaseSpan   = 5;        { below this the compare chain is cheaper }

type
  TCaseEntry = record
    Lo, Hi: Integer;
    Tag: String;
  end;

procedure ParseStatementList(ContTarget, BreakTarget: String); forward;

procedure ParseCaseStatement(ContTarget, BreakTarget: String);
var
  T: PSymbol;
  Entry: array[1..MaxCaseGroups] of TCaseEntry;
  Count, I, J, Lo, Hi, MinV, MaxV, Span, Covered: Integer;
  BodyTag, ElseTarget, EndTarget, DispTarget, TableTag, SkipLbl, Row: String;
  Slot: array[0..MaxCaseSpan - 1] of String;
  UseTable, HasElse: Boolean;

  procedure AddEntry(ALo, AHi: Integer; const ATag: String);
  begin
    if Count >= MaxCaseGroups then Error('Too many case labels');
    Inc(Count);
    Entry[Count].Lo  := ALo;
    Entry[Count].Hi  := AHi;
    Entry[Count].Tag := ATag;
  end;

  { Collect one label (or Lo..Hi range) for the group currently being parsed.
    Nothing is emitted here -- that is the whole point; the dispatch cannot be
    written until every label is known. }
  procedure CollectLabel(const ATag: String);
  var
    L, H: Integer;
  begin
    ParseCaseValue(T, L);
    H := L;
    if Scanner.Token = toRange then
    begin
      NextToken;
      ParseCaseValue(T, H);
      if H < L then Error('Reversed case range');
    end;
    AddEntry(L, H, ATag);
  end;

begin
  EndTarget  := GetLabel('end');
  DispTarget := GetLabel('disp');
  ElseTarget := GetLabel('caselse');
  Count      := 0;

  NextToken;
  T := ParseExpression;

  Expect(toOf);
  NextToken;

  { Skip the bodies; the dispatch that decides between them is emitted after
    them, once the label range is known. }
  EmitI('JMP ' + DispTarget);

  while Scanner.Token in [toIdent, toNumber, toString, toCaret, toSub, toAdd] do
  begin
    BodyTag := GetLabel('case');

    CollectLabel(BodyTag);
    while Scanner.Token = toComma do
    begin
      NextToken;
      CollectLabel(BodyTag);
    end;

    Expect(toColon);
    NextToken;

    Emit(BodyTag, '', '');
    ParseStatement(ContTarget, BreakTarget);
    Expect(toSemicolon);
    NextToken;

    EmitI('JMP ' + EndTarget);
  end;

  if Count = 0 then Error('Case statement has no labels');

  { The else body is a dispatch target like any other, so it needs a label
    even when absent -- an unmatched selector has to land somewhere. }
  HasElse := Scanner.Token = toElse;
  Emit(ElseTarget, '', '');
  if HasElse then
  begin
    NextToken;
    ParseStatementList(ContTarget, BreakTarget);
  end;
  EmitI('JMP ' + EndTarget);

  { ---- decide ---- }
  MinV := Entry[1].Lo;
  MaxV := Entry[1].Hi;
  Covered := 0;
  for I := 1 to Count do
  begin
    if Entry[I].Lo < MinV then MinV := Entry[I].Lo;
    if Entry[I].Hi > MaxV then MaxV := Entry[I].Hi;
    Covered := Covered + (Entry[I].Hi - Entry[I].Lo + 1);
  end;
  Span := MaxV - MinV + 1;

  { Dense enough to be worth a table? Covered*2 >= Span is "at least half the
    slots do something"; the rest point at the else target and cost a word
    each. }
  UseTable := EnableJMPTCase and
              (Span >= MinCaseSpan) and (Span <= MaxCaseSpan) and
              (Covered * 2 >= Span);

  Emit(DispTarget, '', '');
  Emit('', 'POP    D0, XY3', 'case selector');

  if UseTable then
  begin
    TableTag := GetLabel('casetab');

    Emit('', 'CMP    D0, #' + IntToStr(MinV), 'below first label?');
    EmitI('BLT.L  ' + ElseTarget);
    Emit('', 'CMP    D0, #' + IntToStr(MaxV), 'above last label?');
    EmitI('BGT.L  ' + ElseTarget);

    { Normalise to a 0-based index. Written as an ADD when the low bound is
      negative -- SUB with a negative immediate is not worth relying on. }
    if MinV > 0 then
      Emit('', 'SUB    D0, #' + IntToStr(MinV), 'index from 0')
    else if MinV < 0 then
      Emit('', 'ADD    D0, #' + IntToStr(-MinV), 'index from 0');

    EmitI('ADD    D0, D0');                  { word offset = index * 2 }
    Emit('', 'LOADI  X0, #' + TableTag, '');

    { JMPT reads the table from page Y0 and jumps within page Y0, so Y0 has to
      be the page the CODE is in -- the task page on k/OS, the ROM bank on
      bare metal. Not the LOADI Yn,#$00 data idiom. }
    if TargetKOS then
      EmitI('MOVE   Y0, Y3')
    else
      EmitI('LOADI  Y0, #CODEBANK');

    EmitI('JMPT   XY0, D0');

    { ---- the table ---- }
    for I := 0 to Span - 1 do Slot[I] := ElseTarget;
    for I := 1 to Count do
      for J := Entry[I].Lo to Entry[I].Hi do
        Slot[J - MinV] := Entry[I].Tag;

    EmitI('.ALIGN 2');
    Emit(TableTag, '', 'case table: ' + IntToStr(MinV) + '..' + IntToStr(MaxV));
    I := 0;
    while I < Span do
    begin
      Row := '';
      J := 0;
      while (J < 8) and (I < Span) do
      begin
        if Row <> '' then Row := Row + ', ';
        Row := Row + Slot[I];
        Inc(I);
        Inc(J);
      end;
      Emit('', '.WORD ' + Row, '');
    end;
  end
  else
  begin
    { Compare chain -- selector stays in D0 throughout. }
    for I := 1 to Count do
    begin
      Lo := Entry[I].Lo;
      Hi := Entry[I].Hi;
      if Lo = Hi then
      begin
        Emit('', 'CMP    D0, #' + IntToStr(Lo), '');
        EmitI('BEQ.L  ' + Entry[I].Tag);
      end
      else
      begin
        SkipLbl := GetLabel('skipcase');
        Emit('', 'CMP    D0, #' + IntToStr(Lo), '');
        EmitI('BLT.L  ' + SkipLbl);
        Emit('', 'CMP    D0, #' + IntToStr(Hi), '');
        EmitI('BLE.L  ' + Entry[I].Tag);
        Emit(SkipLbl, '', '');
      end;
    end;
    EmitI('JMP ' + ElseTarget);
  end;

  Emit(EndTarget, '', '');

  Expect(toEnd);
  NextToken;
end;

(**
 * Parses a statement, which can be an atomic statement like a procedure call,
 * an assignment, a label or a piece of inline assembly, or a compound statement
 * like if/while/repeat/for or a begin..end block.
 *)
procedure ParseStatement(ContTarget, BreakTarget: String);
var
  Sym: PSymbol;
  Tag, Tag2, Tag3, Tag4: String;
  Delta: Integer;
  SavedDest3: Boolean;
  SavedDestOfs3: Integer;
  (*T: PSymbol;*)
begin
  StringTempDepth := 0;   { Phase 6: reset stack temp depth at each statement }

  if Scanner.Token = toNumber then
  begin
    Sym := LookupGlobalOrFail(IntToStr(Scanner.NumValue));

    if Sym^.Kind = scLabel then
    begin
      NextToken;
      Expect(toColon);
      NextToken;
      Emit(Sym^.Tag, '', '');
    end;
  end
  else if Scanner.Token = toIdent then
  begin
    Sym := LookupGlobalOrFail(Scanner.StrValue);

    if Sym^.Kind = scLabel then
    begin
      NextToken;
      Expect(toColon);
      NextToken;
      Emit(Sym^.Tag, '', '');
    end;
  end;

  if Scanner.Token = toIdent then
  begin
    Sym := LookupGlobalOrFail(Scanner.StrValue);

    if (Sym^.Kind = scProc) and (Sym^.IsMagic) then
    begin
      ParseBuiltInProcedure(Sym, BreakTarget, ContTarget);
    end
    else if Sym^.Kind = scProc then
    begin
      NextToken;
      if Scanner.Token = toBecomes then Error('"' + Sym^.Name + '" not a var.');

      ParseArguments(Sym);

      EmitCall(Sym);

      { Phase 6: free any string temps that were allocated for arguments }
      while StringTempDepth > 0 do EmitFreeStringTemp;
    end
    else if (Sym^.Kind = scVar) and (Sym^.IsMagic) then
    begin
      NextToken;
      ParseBuiltInVarWrite(Sym);
    end
    else
    begin
      ParseAssignment(Sym);
    end;
  end
  else if Scanner.Token = toBegin then
  begin
    NextToken; ParseStatement(ContTarget, BreakTarget);
    while Scanner.Token = toSemicolon do
    begin
      NextToken;
      ParseStatement(ContTarget, BreakTarget);
    end;
    Expect(toEnd); NextToken;
  end
  else if Scanner.Token = toIf then
  begin
    NextToken; TypeCheck(dtBoolean, ParseExpression, tcExact); Expect(toThen); NextToken;

    Tag := GetLabel('false');

    EmitJumpIf(False, Tag);

    ParseStatement(ContTarget, BreakTarget);

    if Scanner.Token = toElse then
    begin
      Tag2 := GetLabel('endif');
      EmitI('JMP ' + Tag2);

      Emit(Tag, '', '');

      NextToken;
      ParseStatement(ContTarget, BreakTarget);

      Emit(Tag2, '', '');
    end
    else
    begin
      Emit(Tag, '', '');
    end;

  end
  else if Scanner.Token = toWhile then
  begin
    (* Break would jump to false *)

    Tag := GetLabel('while');
    Tag2 := GetLabel('false');

    Emit(Tag, '', '');

    NextToken; TypeCheck(dtBoolean, ParseExpression, tcExact); Expect(toDo); NextToken;

    EmitJumpIf(False, Tag2);

    ParseStatement(Tag, Tag2);

    EmitI('JMP ' + Tag);         (* TODO Move this elsewhere. *)
    Emit(Tag2, '', '');
  end
  else if Scanner.Token = toRepeat then
  begin
    Tag := GetLabel('repeat');
    Tag2 := GetLabel('break');

    (* break would jump to label after until *)

    Emit(Tag, '', '');

    NextToken; ParseStatement(Tag, Tag2);
    while Scanner.Token = toSemicolon do
    begin
      NextToken;
      ParseStatement(Tag, Tag2);
    end;
    Expect(toUntil); NextToken;

    TypeCheck(dtBoolean, ParseExpression, tcExact);

    EmitJumpIf(False, Tag);
    Emit(Tag2, '', '');
  end
  else if Scanner.Token = toFor then
  begin
    (* break would jump to cleanup after for *)

    NextToken;
    Expect(toIdent);

    Sym := LookupGlobalOrFail(Scanner.StrValue);
    if Sym^.Kind <> scVar then Error('Identifier "' + Scanner.StrValue + '" not a var.');

    EmitAddress(Sym);
    NextToken; Expect(toBecomes); NextToken;
    SavedDest3    := DestIsXY2;
    SavedDestOfs3 := DestXY2Offset;
    TypeCheck(Sym^.DataType, ParseExpression, tcAssign);
    DestIsXY2     := SavedDest3;
    DestXY2Offset := SavedDestOfs3;
    EmitStore(Sym^.DataType);

    if Scanner.Token = toTo then
      Delta := 1
    else if Scanner.Token = toDownTo then
      Delta := -1
    else
      Error('"to" or "downto" expected.');

    NextToken; TypeCheck(Sym^.DataType, ParseExpression, tcAssign); Expect(toDo); (* final value on stack *)

    Tag := GetLabel('forloop');
    Tag3 := GetLabel('forbreak');
    Tag4 := GetLabel('fornext');

    Emit('', 'POP    D1, XY3','Dup and pre-check limit');
    Emit('', 'PUSH   D1, XY3', '');
    Emit('', 'PUSH   D1, XY3', '');

    Offset := Offset - 2;

    EmitAddress(Sym);
    EmitLoad(Sym^.DataType);

    if Delta = 1 then EmitRelOp(toGeq, IsUnsignedType(Sym^.DataType))
                 else EmitRelOp(toLeq, IsUnsignedType(Sym^.DataType)); (* Operands swapped! *)

    EmitJumpIf(False, Tag3);

    Emit(Tag, '', '');

    NextToken;
    ParseStatement(Tag4, Tag3);

    Emit(Tag4, '', '');

    Emit('', 'POP    D1, XY3','Dup and check limit');
    Emit('', 'PUSH   D1, XY3', '');
    Emit('', 'PUSH   D1, XY3', '');

    EmitAddress(Sym);
    EmitLoad(Sym^.DataType);

    if Delta = 1 then EmitRelOp(toGt, IsUnsignedType(Sym^.DataType))
                 else EmitRelOp(toLt, IsUnsignedType(Sym^.DataType)); (* Operands swapped! *)

    EmitJumpIf(False, Tag3);

    EmitAddress(Sym);
    if Delta = 1 then EmitInc(Sym^.DataType) else EmitDec(Sym^.DataType);

    EmitJump(Tag);

    Emit(Tag3, 'POP    D1, XY3', 'Cleanup limit');

    Offset := Offset + 2;
  end
  else if Scanner.Token = toCase then
  begin
    ParseCaseStatement(ContTarget, BreakTarget);
  end
  else if Scanner.Token = toWith then
  begin
    NextToken;
    ParseWith(ContTarget, BreakTarget);
  end
  else if Scanner.Token = toInline then
  begin
    NextToken;
    ParseInline;
  end
  else if Scanner.Token = toGoto then
  begin
    NextToken;

    if Scanner.Token = toIdent then
    begin
      Sym := LookupLocalOrFail(Scanner.StrValue);
      // ...
      EmitI('JMP ' + Sym^.Tag);
    end
    else if Scanner.Token = toNumber then
    begin
      Sym := LookupLocalOrFail(IntToStr(Scanner.NumValue));
      // ...
      EmitI('JMP ' + Sym^.Tag);
    end
    else Error('Ident or number expected');

    NextToken;
  end;
end;

function ParseTypeDef: PSymbol; forward;

(**
 * Parses a typed constant (aka an initialized variable). Typed constants are
 * always allocated statically.
 *)
procedure ParseConstValue(DataType: PSymbol);
var
  I, Sign, Value, Offset: Integer;
  Sym: PSymbol;
  Test: Boolean;
begin
  if DataType^.Kind = scArrayType then
  begin
    Expect(toLParen);
    NextToken;

    for I := DataType^.IndexType^.Low to DataType^.IndexType^.High - 1 do
    begin
      ParseConstValue(DataType^.DataType);
      Expect(toComma);
      NextToken;
    end;
    ParseConstValue(DataType^.DataType);

    Expect(toRParen);
    NextToken;
  end
  else if DataType^.Kind = scRecordType then
  begin
    Expect(toLParen);
    NextToken;

    Offset := 0;
    Test := True;
    while Test do
    begin
      Test := False;

      if Scanner.Token = toIdent then
      begin
        Sym := Lookup(Scanner.StrValue, DataType^.DataType, nil);
        if Sym = nil then Error('Unknown field "' + Scanner.StrValue + '"');

        if Sym^.Value < Offset then Error('Invalid offset');
        if Sym^.Value > Offset then
        begin
          EmitI('.DS    ' + IntToStr(Sym^.Value - Offset));
          Offset := Sym^.Value;
        end;

        NextToken;
        Expect(toColon);
        NextToken;

        ParseConstValue(Sym^.DataType);

        Offset := Offset + Sym^.DataType^.Value;
      end;

      if Scanner.Token = toSemicolon then
      begin
        Test := True;
        NextToken;
      end;
    end;

    if Offset < DataType^.Value then
      EmitI('.DS    ' + IntToStr(DataType^.Value - Offset));

    Expect(toRParen);
    NextToken;
  end
  else if DataType^.Kind = scEnumType then
  begin
    Expect(toIdent);
    Sym := LookupGlobalOrFail(Scanner.StrValue);
    if (Sym^.Kind <> scConst) or (Sym^.DataType <> DataType) then
      Error('Invalid enum constant');

    Emit('', '.BYTE ' + IntToStr(Sym^.Value), '');

    NextToken;
  end
  else
  begin
    if DataType = dtInteger then
    begin
      if Scanner.Token = toSub then
      begin
        Sign := -1;
        NextToken;
      end
      else Sign := 1;
      Expect(toNumber);

      Value := Sign * Scanner.NumValue;
      Emit('', '.WORD ' + IntToStr(Value), '');

      NextToken;
    end
    else if DataType = dtWord then
    begin
      { Part 24: no sign is accepted -- a negative Word initialiser is a
        typo, not a bit pattern someone meant. }
      Expect(toNumber);
      if (Scanner.NumValue < 0) or (Scanner.NumValue > 65535) then
        Error('Word constant out of range: ' + IntToStr(Scanner.NumValue));

      Emit('', '.WORD ' + IntToStr(Scanner.NumValue), '');

      NextToken;
    end
    else if DataType = dtByte then
    begin
      Expect(toNumber);

      Emit('', '.BYTE ' + IntToStr(Scanner.NumValue), '');

      NextToken;
    end
    else if DataType = dtReal then
    begin
      if Scanner.Token = toSub then
      begin
        Sign := -1;
        NextToken;
      end
      else Sign := 1;
      Expect(toFloat);

      Emit('', '.WORD ' + EncodeReal(Scanner.StrValue), '');

      NextToken;
    end
    else if DataType = dtChar then
    begin
      Expect(toString);
      if Length(Scanner.StrValue) <> 1 then Error('Char expected');
      Emit('', '.BYTE "' + Scanner.StrValue + '"', '');
      NextToken;
    end
    else if DataType^.Kind = scStringType then
    begin
      Expect(toString);
      // Emit('', '.BYTE ' + IntToStr(Length(Scanner.StrValue)) + ', "' +  EncodeAsmStr(Scanner.StrValue) + '"', '');
      Emit('', '.BYTE ' + EncodeAsmStr(Scanner.StrValue), '');
      Emit('', '.DS    ' + IntToStr(DataType^.Value - Length(Scanner.StrValue) - 1), '');
      NextToken;
    end
    else if DataType^.Kind = scSetType then
    begin
      Expect(toLBrack);
      NextToken;

      ParseSetConstant; (* FIXME: Type check!!! *)

      Expect(toRBrack);
      NextToken;
    end
    else
      Error('Not supported');
  end;
end;

(**
 * Parses a constant declaration, which can either be a real constant or a
 * so-called typed constant, which is basically an initialized variable.
 *)
procedure ParseConst;
var
  Name: String;
  Sym, Sym2: PSymbol;
  Sign: Integer;
begin
  Expect(toIdent);
  Name := Scanner.StrValue;
  NextToken;

  if Scanner.Token = toColon then
  begin
    NextToken;

    Sym := CreateSymbol(scVar, Name);
    Sym^.DataType := ParseTypeDef();
    Sym^.Tag := GetLabel('const');
    Sym^.Level := 0; (* Force global *)

    Emit(Sym^.Tag, '', '');

    Expect(toEq);
    NextToken;

    ParseConstValue(Sym^.DataType);
  end
  else
  begin
    Sym := CreateSymbol(scConst, Name);

    Expect(toEq);
    NextToken;

    if Scanner.Token = toString then
    begin
      Sym^.DataType := dtString;
      Sym^.Tag := AddString(Scanner.StrValue);
    end
    else if Scanner.Token = toFloat then
    begin
      Sym^.DataType := dtReal;
      Sym^.Tag := EncodeReal(Scanner.StrValue);
    end
    else if Scanner.Token = toIdent then
    begin
      Sym2 := LookupGlobalOrFail(Scanner.StrValue);
      if Sym2^.Kind <> scConst then Error('Not a constant: ' + Scanner.StrValue);

      Sym^.DataType := Sym2^.DataType;
      Sym^.Value := Sym2^.Value;
    end
    else if Scanner.Token = toCaret then
    begin
      Sym^.DataType := dtChar;
      Sym^.Value := GetCtrlChar;
    end
    else
    begin
      if Scanner.Token = toSub then
      begin
        Sign := -1;
        NextToken;
      end
      else Sign := 1;

      if Scanner.Token = toFloat then
      begin
        Sym^.DataType := dtReal;
        Sym^.Tag := EncodeReal('-' + Scanner.StrValue);
      end
      else
      begin
        Sym^.Value := Sign * Scanner.NumValue;
        Sym^.DataType := dtInteger;
      end;    end;

    NextToken;
  end;
end;

(**
 * Parses a single record field name (just the name, no type).
 *)
procedure ParseField(var Fields: PSymbol);
var
  Sym: PSymbol;
begin
  Expect(toIdent);
  if Lookup(Scanner.StrValue, Fields, nil) <> nil then Error('Duplicate field "' + Scanner.StrValue + '"');

  New(Sym);
  FillChar(Sym^, SizeOf(TSymbol), 0);
  Sym^.Kind := scVar;
  Sym^.Name := Scanner.StrValue;
  Sym^.Prev := Fields;
  Fields := Sym;

  NextToken;
end;

(**
 * Parses a field group, that is, a comma-separated list of record field names
 * with a single type specification.
 *)
procedure ParseFieldGroup(var Fields: PSymbol; var Offset: Integer);
var
  Sym, Typ: PSymbol;
  Len, I: Integer;
begin
  ParseField(Fields);
  Len := 1;

  while Scanner.Token = toComma do
  begin
    NextToken;
    ParseField(Fields);
    Len := Len + 1;
  end;

  Expect(toColon);
  NextToken;
  Typ := ParseTypeDef();

  Offset := Offset + Len * Typ^.Value;
  Sym := Fields;

  for I := 1 to Len do
  begin
    Sym^.DataType := Typ;
    Sym^.Value := Offset - I * Typ^.Value;
    Sym := Sym^.Prev;
  end;
end;

(**
 * Parses a record type definition including a potentially variant part.
 *)
procedure ParseRecord(RecSym: PSymbol);
var
  Sym, CaseType: PSymbol;
  FixedSize, VariantSize: Integer;
  Ident: String;
begin
  while Scanner.Token = toIdent do
  begin
    ParseFieldGroup(RecSym^.DataType, RecSym^.Value);
    Expect(toSemicolon);
    NextToken;
  end;

  if Scanner.Token = toCase then
  begin
    NextToken;
    Expect(toIdent);
    Ident := Scanner.StrValue;
    NextToken;
    if Scanner.Token = toColon then
    begin
      NextToken;
      Expect(toIdent);
      CaseType := LookupGlobalOrFail(Scanner.StrValue);

      New(Sym);
      FillChar(Sym^, SizeOf(TSymbol), 0);
      Sym^.Kind := scVar;
      Sym^.Name := Ident;
      Sym^.DataType := CaseType;
      Sym^.Value := RecSym^.Value;
      Sym^.Prev := RecSym^.DataType;
      RecSym^.DataType := Sym;

      RecSym^.Value := RecSym^.Value + CaseType^.Value;

      NextToken;
    end
    else
    begin
      CaseType := LookupGlobalOrFail(Ident);
    end;

    FixedSize := RecSym^.Value;
    VariantSize := FixedSize;

    Expect(toOf);
    NextToken;

    while Scanner.Token in [toIdent, toNumber] do
    begin
      NextToken; (* Type check? *)
      while Scanner.Token = toComma do
      begin
        NextToken;
        NextToken; (* Type check? *)
      end;

      Expect(toColon);
      NextToken;

      Expect(toLParen);
      NextToken;

      ParseRecord(RecSym);
      if RecSym^.Value > VariantSize then VariantSize := RecSym^.Value;
      RecSym^.Value := FixedSize;

      Expect(toRParen);
      NextToken;

      Expect(toSemicolon);
      NextToken;
    end;

    RecSym^.Value := VariantSize;
  end;
end;

(**
 * Parses an array type definition. We support the standard form (array of
 * array) and the alternative shorthand form (one pair of brackets overall,
 * comma-separated dimensions specifiers).
 *
 * TODO Allow C-style array sizes with array[n] meaning array[0..n-1]?
 *)
procedure ParseArray(DataType: PSymbol; First: Boolean);
begin
  if First then
  begin
    Expect(toLBrack);
    NextToken;
  end;

  DataType^.IndexType := ParseTypeDef;
  if not (DataType^.IndexType^.Kind in [scType, scEnumType, scSubrangeType]) then
    Error('Not an ordinal type');

  if Scanner.Token = toComma then
  begin
    NextToken;
    DataType^.DataType := CreateSymbol(scArrayType, '');
    ParseArray(DataType^.DataType, False);
  end
  else
  begin
    Expect(toRBrack);
    NextToken;

    Expect(toOf);
    NextToken;

    DataType^.DataType := ParseTypeDef();
  end;

  DataType^.Value := (DataType^.IndexType^.High - DataType^.IndexType^.Low + 1) * DataType^.DataType^.Value;
end;

(**
 * Parses a type definition, which can be an array, a string, a file, a record,
 * a pointer, a set, a range, or a reference to an existing type (and
 * potentially nested, of course).
 *)
function ParseTypeDef: PSymbol;
var
  DataType, Sym: PSymbol;
  I, EK: Integer;
  ES: PSymbol;
begin
  if Scanner.Token = toArray then
  begin
    DataType := CreateSymbol(scArrayType, '');
    NextToken;

    ParseArray(DataType, True);
  end
  else if Scanner.Token = toStringKW then
  begin
    NextToken;

    DataType := CreateSymbol(scStringType, '');

    if Scanner.Token = toLBrack then
    begin
      NextToken;
      Expect(toNumber);
      DataType^.Value := Scanner.NumValue + 1;
      NextToken;
      Expect(toRBrack);
      NextToken;
    end
    else DataType^.Value := 256;
  end
  else if Scanner.Token = toFile then
  begin
    NextToken;

    if Scanner.Token = toOf then
    begin
      DataType := CreateSymbol(scFileType, '');
      NextToken;
      DataType^.DataType := ParseTypeDef;
      DataType^.Value := 256;
    end
    else DataType := dtFile;
  end
  else if Scanner.Token = toRecord then
  begin
    DataType := CreateSymbol(scRecordType, '');
    NextToken;

    ParseRecord(DataType);
    Expect(toEnd);
    NextToken;
  end
  else if Scanner.Token = toSet then
  begin
    NextToken;
    Expect(toOf);
    NextToken;

    DataType := CreateSymbol(scSetType, '');
    DataType^.DataType := ParseTypeDef;

    if not (DataType^.DataType^.Kind in [scType, scEnumType, scSubrangeType]) then
      Error('Scalar type required');

    if DataType^.DataType^.Value > 1 then
      Error('Base type too large');

    DataType^.Value := 32;
  end
  else if Scanner.Token = toCaret then
  begin
    DataType := CreateSymbol(scPointerType, '');
    DataType^.Value := 2;
    NextToken;

    if Scanner.Token = toIdent then
    begin
      DataType^.DataType := Lookup(Scanner.StrValue, SymbolTable, nil);
      if DataType^.DataType = nil then DataType^.Tag := Scanner.StrValue;
      NextToken;
    end
    else DataType^.DataType := ParseTypeDef;
  end
  else if Scanner.Token = toLParen then
  begin
    DataType := CreateSymbol(scEnumType, '');
    DataType^.Tag := GetLabel('enumlit');
    DataType^.Value := 1;
    I := 0;

    repeat
      NextToken;
      Expect(toIdent);

      Sym := CreateSymbol(scConst, Scanner.StrValue);
      Sym^.Value := I;
      // Sym^.Value2 := AddString(Sym^.Name);

      Sym^.DataType := DataType;
      I := I + 1;
      NextToken;
    until Scanner.Token <> toComma;

    { Emit enum lookup table: count byte (now known=I) then .WORD per name in value order }
    Emit(DataType^.Tag, '', 'enum lookup table');
    Emit('', '.BYTE  ' + IntToStr(I), 'enum count');
    Emit('', '.ALIGN 2', 'realign after enum count byte');
    { Walk SymbolTable for each enum value 0..I-1 to emit .WORD entries in order }
    for EK := 0 to I - 1 do
    begin
      ES := SymbolTable;
      while (ES <> nil) and not ((ES^.Kind = scConst) and (ES^.DataType = DataType) and (ES^.Value = EK)) do
        ES := ES^.Prev;
      if ES <> nil then
        Emit('', '.WORD  ' + AddString(ES^.Name), ES^.Name);
    end;

    DataType^.Low := 0;
    DataType^.High := I - 1;

    Expect(toRParen);
    NextToken;
  end
  else if Scanner.Token = toNumber then
  begin
    DataType := CreateSymbol(scSubrangeType, '');
    DataType^.DataType := dtInteger;

    DataType^.Low := Scanner.NumValue;
    NextToken;
    Expect(toRange);
    NextToken;

    if Scanner.Token = toIdent then
    begin
      Sym := LookupGlobalOrFail(Scanner.StrValue);

      if Sym^.Kind <> scConst then Error('Not a constant');
      if (Sym^.DataType <> dtInteger) and (Sym^.DataType^.Kind <> scEnumType) then Error('Not an integer or enum');

      DataType^.High := Sym^.Value;

      if Sym^.Value < 256 then DataType^.Value := 1 else DataType^.Value := 2;
    end
    else
    begin
      Expect(toNumber);
      DataType^.High := Scanner.NumValue;

      if Scanner.NumValue < 256 then DataType^.Value := 1 else DataType^.Value := 2;
    end;

    NextToken;
  end
  else if Scanner.Token = toString then
  begin
    if Length(Scanner.StrValue) <> 1 then Error('Char expected');

    DataType := CreateSymbol(scSubrangeType, '');
    DataType^.DataType := dtChar;

    DataType^.Low := Ord(Scanner.StrValue[1]);
    NextToken;
    Expect(toRange);
    NextToken;
    Expect(toString);
    if Length(Scanner.StrValue) <> 1 then Error('Char expected');
    DataType^.High := Ord(Scanner.StrValue[1]);

    DataType^.Value := 1;

    NextToken;
  end
  else begin
    Expect(toIdent);

    Sym := LookupGlobalOrFail(Scanner.StrValue);

    if Sym^.Kind = scConst then
    begin
      DataType := CreateSymbol(scSubrangeType, '');
      DataType^.DataType := Sym^.DataType;
      DataType^.Value := 1;

      Sym := LookupGlobalOrFail(Scanner.StrValue);
      DataType^.Low := Sym^.Value;
      NextToken;
      Expect(toRange);
      NextToken;

      if Scanner.Token = toIdent then
      begin
        Sym := LookupGlobalOrFail(Scanner.StrValue);

        if Sym^.Kind <> scConst then Error('Not a constant');
        if (Sym^.DataType <> dtInteger) and (Sym^.DataType^.Kind <> scEnumType) then Error('Not an integer or enum');

        DataType^.High := Sym^.Value;

        if Sym^.Value < 256 then DataType^.Value := 1 else DataType^.Value := 2;
      end
      else
      begin
        Expect(toNumber);
        DataType^.High := Scanner.NumValue;

        if Scanner.NumValue < 256 then DataType^.Value := 1 else DataType^.Value := 2;
      end;

      NextToken;
    end
    else
    begin
      while Sym^.Kind = scAliasType do Sym := Sym^.DataType;

      if not (Sym^.Kind in [scType, scArrayType, scRecordType, scEnumType, scStringType, scSetType, scPointerType, scSubrangeType, scFileType]) then
        Error('Not a type: ' + Scanner.StrValue);

      DataType := Sym;
      NextToken;
    end;
  end;

  ParseTypeDef := DataType;
end;

(**
 * Parses a type reference, which is basically the name of a built-in or
 * user-defined type. Needed for parameters. These are not allowed to come
 * up with new (and hence anonymous) types.
 *)
function ParseTypeRef: PSymbol;
var
  DataType: PSymbol;
begin
  if Scanner.Token = toStringKW then
  begin
    DataType := dtString;
  end
  else
  begin
    Expect(toIdent);
    DataType := LookupGlobalOrFail(Scanner.StrValue);

    if not (DataType.Kind in [scType, scArrayType, scRecordType, scEnumType, scStringType, scSetType, scSubrangeType, scPointerType]) then Error('Type expected');
  end;

  NextToken;

  ParseTypeRef := DataType;
end;

(**
 * Parses a single variable or parameter name.
 *
 * TODO Is this worth its own procedure? Only used by variable and parameter lists.
 *)
procedure ParseVar;
var
  Name: String;
begin
  Expect(toIdent);
  Name := Scanner.StrValue;
  NextToken;

  CreateSymbol(scVar, Name);
  (*
  if Sym^.Level = 0 then
  begin
    Sym^.Tag := GetLabel('global');
    Emit0(Sym^.Tag, '.DS    ' + IntToStr(Sym^.Bounds * 2), 'Global ' + Sym^.Name);
  end;
  *)
end;

(**
 * Parses a variable list (actually this should probably be called a variable
 * group), that is, a comma separated list of variable identifiers followed by a
 * type name or definition.
 *)
procedure ParseVarList();
var
  Old: PSymbol;
  DataType, Sym: PSymbol;
  Multi, IsAbs: Boolean;
  Tag: String;
begin
  Multi := False;
  IsAbs := False;

  Old := SymbolTable;
  ParseVar;
  while Scanner.Token = toComma do
  begin
    Multi := True;
    NextToken; ParseVar;
  end;

  Expect(toColon);
  NextToken;

  DataType := ParseTypeDef;

    // if DataType^.Kind = scArrayType then WriteLn(' of ', DataType^.DataType^.Name);

  if Scanner.Token = toAbsolute then
  begin
    if Multi then Error('"absolute" only allowed for single variables');

    NextToken;
    if Scanner.Token = toNumber then
      Tag := IntToStr(Scanner.NumValue)
    else if Scanner.Token = toString then
      Tag := Scanner.StrValue
    else if Scanner.Token = toIdent then
    begin
      Sym := LookupGlobalOrFail(Scanner.StrValue);
      if Sym^.Tag = '' then Error('Not addressable');
      Tag := Sym^.Tag;
    end
    else Error('Address expected');

    NextToken;
    IsAbs := True;
  end;

  while Old<>SymbolTable do
  begin
    Old := Old^.Next;
    if Old^.Kind = scVar then
    begin
      if AbsCode and (DataType^.Value <= 32) then
      begin
        { Part 18: a LOCAL promoted here gets static storage, shared by every
          invocation. Harmless unless the owner can recurse -- see the warning
          in CGCheckRecursion. Level 0 already means a real global. }
        if Old^.Level > 0 then CGNoteStaticLocal;
        Old^.Level := 0;
      end;

      SetDataType(Old, DataType);

      // TODO Should this be part of SetDataType?
      if IsAbs then Old^.Tag := Tag
      else if Old^.Level = 0 then
      begin
        Old^.Tag := MakeGlobalTag(CurrentProcName, Old^.Name);   { g_<Name> / l_<Proc>_<Name> }
        { k/OS: becomes a .RS field of the GLOBALS region (assembler-placed at
          code_end). Bare-metal keeps the historical fixed .EQU address.
          GlobalRAMOffset still advances either way -- it sizes the bss clear. }
        if TargetKOS then
          AddGlobalField(Old^.Tag, Old^.DataType^.Value)
        else
          Emit(Old^.Tag, '.EQU $' + IntToHex(GlobalRAMOffset, 6),
               'Global ' + Old^.Name + ' @ $' + IntToHex(GlobalRAMOffset, 6));
        Inc(GlobalRAMOffset, Old^.DataType^.Value);
        if Odd(GlobalRAMOffset) then Inc(GlobalRAMOffset); { keep word-aligned }
      end;
    end;

//    Tmp^.DataType := DataType;
    //if High >= Low then Tmp^.Bounds := High - Low + 1;
//    Tmp := Tmp^.Prev;
    //Offset := Offset + (High - Low + 1) * 2 - 2;
  end;
end;

(**
 * Parses a parameter list (actually this should probably be called a parameter
 * group), that is, a comma-separated list of variable names followed by a
 * single type reference. Whether these are "var" parameters or not is being
 * passed as a parameter.
 *)
procedure ParseParamList(IsRef: Boolean);
var
  Old: PSymbol;
  DataType: PSymbol;
begin
  Old := SymbolTable;
  ParseVar;
  SymbolTable^.IsRef := IsRef;
  while Scanner.Token = toComma do
  begin
    NextToken; ParseVar;
    SymbolTable^.IsRef := IsRef;
  end;

  if not IsRef or (Scanner.Token = toColon) then
  begin
    Expect(toColon);
    NextToken;
    DataType := ParseTypeRef;
  end
  else DataType := nil;

  (*if (DataType^.Kind in [scArrayType, scRecordType]) and not isRef then
    Error('Structured parameters must be passed by reference');*)

  while Old<>SymbolTable do
  begin
    Old := Old^.Next;
    if Old^.Kind = scVar then
      SetDataType(Old, DataType, True);  { IsParam=True: string uses 2-byte pointer slot }
  end;
end;

(**
 * Parses a label definition, which can be numeric or alphanimeric.
 *)
procedure ParseLabelDef;
var
  S: PSymbol;
begin
  if Scanner.Token = toIdent then
  begin
    S := CreateSymbol(scLabel, Scanner.StrValue);
  end
  else if Scanner.Token = toNumber then
  begin
    S := CreateSymbol(scLabel, IntToStr(Scanner.NumValue));
  end
  else Error('Identifier or number expected');

  S^.Tag := GetLabel('label');
  NextToken;
end;

procedure ParseBlock(Sym: PSymbol); forward;

(**
 * Parses a procedure or function declaration. It can be either a forward
 * declaration or the actual implementation, in which case the corresponding
 * block is parsed, too.
 *)
procedure ParseProcFunc(Sym: PSymbol);
var
  NewSym, ResVar, FwdSym, P: PSymbol;
  Token: TToken;
  S: String;
  IsRef: Boolean;
begin
  Token := Scanner.Token;
  NextToken; Expect(toIdent);

  FwdSym := Lookup(Scanner.StrValue, SymbolTable, CurrentScope);
  if (FwdSym <> nil) and (FwdSym^.IsForward) then
  begin
    if Token = toProcedure then
      NewSym := CreateSymbol(scProc, '')
    else
      NewSym := CreateSymbol(scFunc, '');

    if NewSym^.Kind <> FwdSym^.Kind then Error('Proc/Func mismatch');

    FwdSym^.IsForward := False;

    OpenScope(True);

    NewSym^.Tag := FwdSym^.Tag;
    if FwdSym^.SavedParams <> nil then
    begin
      P := FwdSym^.SavedParams;
      while P^.Prev <> nil do
      begin
        P := P^.Prev;
      end;
      P^.Prev := SymbolTable;
      SymbolTable^.Next := P;
      SymbolTable := FwdSym^.SavedParams;
    end;

    NextToken;
    Expect(toSemicolon);
    NextToken;

    NewSym := FwdSym;
  end
  else
  begin
    if Token = toProcedure then
    begin
      NewSym := CreateSymbol(scProc, Scanner.StrValue);
      NewSym^.Tag := GetLabel('__' + NewSym^.Name);
    end
    else
    begin
      NewSym := CreateSymbol(scFunc, Scanner.StrValue);
      NewSym^.Tag := GetLabel('__' + NewSym^.Name);
    end;

    OpenScope(True);
  end;

  NewSym^.IsStdCall := True;

  if FwdSym = nil then
  begin
    if Token = toFunction then
    begin
      CreateSymbol(scVar, Scanner.StrValue)^.Tag := 'RESULT';
      //SetDataType(SymbolTable, dtInteger, 0);
      ResVar := SymbolTable;
    end;
    NextToken;

    if Scanner.Token = toLParen then
    begin
      NextToken;

      IsRef := False;
      if Scanner.Token = toVar then
      begin
        IsRef := True;
        NextToken;
      end;

      ParseParamList(IsRef);
      while Scanner.Token = toSemicolon do
      begin
        NextToken;

        IsRef := False;
        if Scanner.Token = toVar then
        begin
          IsRef := True;
          NextToken;
        end;

        ParseParamList(IsRef); (* ParamGroup *)
      end;
      Expect(toRParen);
      NextToken;
    end;

    if NewSym^.Kind = scFunc then
    begin
      Expect(toColon);
      NextToken;

      NewSym^.DataType := ParseTypeRef();
      ResVar^.DataType := NewSym^.DataType;
    end;

    AdjustOffsets;

    Expect(toSemicolon);
    NextToken;

    while Scanner.Token in [toExternal,toForward,toIdent] do
    begin
      if Scanner.Token = toExternal then
      begin
        NextToken;
        NewSym^.IsExternal := True;
        if Scanner.Token = toString then
        begin
          NewSym^.Tag := Scanner.StrValue;
          NextToken;
        end
        else
          NewSym^.Tag := '__' + LowerStr(NewSym^.Name);
      end
      else if Scanner.Token = toForward then
      begin
        NewSym^.IsForward := True;
        NextToken;
      end
      else
      begin
        S := LowerCase(Scanner.StrValue);
        if S = 'stdcall' then
          NewSym^.IsStdCall := True
        else if S = 'register' then
          NewSym^.IsStdCall := False
        else Error('Unknown modifier ' + S);

        NextToken;
      end;

      Expect(toSemicolon);
      NextToken;
    end;

    if NewSym^.IsForward then
    begin
      if SymbolTable^.Kind = scScope then
      begin
        NewSym^.SavedParams := nil
      end
      else
      begin
        NewSym^.SavedParams := SymbolTable;
        NewSym^.Next^.Next^.Prev := nil;
        NewSym^.Next^.Next := nil;
        SymbolTable := NewSym^.Next;
      end;
    end
  end;

  if not NewSym^.IsExternal and not NewSym^.IsForward then
  begin
    if (Scanner.Token = toInline) then
    begin
      Emit(NewSym.Tag, '', '');
      NextToken;
      ParseInline;
      EmitI('RET');
      Expect(toSemicolon);
      NextToken;
    end
    else
    begin
      ParseBlock(NewSym);
      Expect(toSemicolon);
      NextToken;
    end;
  end;

  CloseScope(True);

  EmitC('');
end;


(**
 * Parses a declaration part, which can contain the following elements any
 * number of times and in any order: constants, types, variables, labels,
 * procedures, and functions.
 *)
procedure ParseDeclarations(Sym: PSymbol);
var
  OldSyms, P, T: PSymbol;
  Name: String;
begin
  while Scanner.Token in [toConst, toType, toVar, toLabel, toProcedure, toFunction] do
  begin
    if Scanner.Token = toConst then
    begin
      NextToken;
      repeat
        ParseConst;
        while Scanner.Token = toComma do
        begin
          NextToken; ParseConst;
        end;
        Expect(toSemicolon);
        NextToken;
      until Scanner.Token <> toIdent;
    end

    else if Scanner.Token = toType then
    begin
      OldSyms := SymbolTable;

      NextToken;
      Expect(toIdent);

      repeat
        Name := Scanner.StrValue;

        if Lookup(Name, SymbolTable, CurrentScope) <> nil then
          Error('Duplicate identifier "' + Name + '"');

        NextToken;
        Expect(toEq);
        NextToken;

        T := ParseTypeDef;
        if T^.Name <> '' then
        begin
          P := CreateSymbol(scAliasType, Name);
          P^.DataType := T;
        end
        else T^.Name := Name;

        Expect(toSemicolon);
        NextToken;
      until Scanner.Token <> toIdent;

      P := SymbolTable;
      while P <> OldSyms do
      begin
        if (P^.Kind = scPointerType) and (P^.DataType = nil) then
        begin
          P^.DataType := Lookup(P^.Tag, SymbolTable, CurrentScope);
          if P^.DataType = nil then Error('Unresolved forward declaration "' + P^.Name + '"');
          P^.Tag := '';
        end;

        P := P^.Prev;
      end;
    end

    else if Scanner.Token = toVar then
    begin
      NextToken;
      repeat
        parseVarList();
        Expect(toSemicolon);
        NextToken;
      until Scanner.Token <> toIdent;
    end

    else if Scanner.Token = toLabel then
    begin
      NextToken;
      parseLabelDef();
      while Scanner.Token = toComma do
      begin
        NextToken;
        parseLabelDef();
      end;
      Expect(toSemicolon);
      NextToken;
    end

    else if (Scanner.Token = toProcedure) or (Scanner.Token = toFunction) then
      ParseProcFunc(Sym);
  end;
end;

(**
 * Parses a statement list, which is a (possibly empty) list of statements
 * separated by semicolons.
 *)
procedure ParseStatementList(ContTarget, BreakTarget: String);
begin
  ParseStatement(ContTarget, BreakTarget);
  FrameDestCur := 0;         { Part 19: frame concat dests reuse per statement }
  while Scanner.Token = toSemicolon do
  begin
    NextToken;
    ParseStatement(ContTarget, BreakTarget);
    FrameDestCur := 0;
  end;
end;

(**
 * Parses a block, which is a set of declarations followed by a statement list
 * enclose in "begin" and "end".
 *)
procedure ParseBlock(Sym: PSymbol);
var
  PrevBlock: PSymbol;
  PrevCGNode, MyCGNode: Integer;
  PrevSlotPrefix: String;
  PrevProcName: String;
  PrevTempPeak: Integer;
  PrevLocalBytes: Integer;
  PrevParamCopyBytes: Integer;
  FrameNote: String;
  FrameTotal: Integer;
begin
  { Part 18 Phase 0: this block's node in the persistent call graph. Registered
    before ParseDeclarations so nested routines can save/restore around it; every
    call emitted from here on is attributed to MyCGNode. }
  PrevCGNode := CGCurrent;
  MyCGNode   := CGRegisterBlock(Sym);
  CGCurrent  := MyCGNode;

  { Part 18 Phase 2: slots emitted from here on belong to this routine. Saved
    and restored, so a nested routine's declarations do not steal the stem. }
  PrevSlotPrefix    := CurrentSlotPrefix;
  CurrentSlotPrefix := CGNodes[MyCGNode].SlotPrefix;

  if SmartLink and (Sym <> nil) and (Sym^.Level = 0) then EmitI('.IF __USE' + Sym^.Tag);

  { Part 17: name statically-allocated locals after their owner, and measure
    this block's peak string-temp stack. Saved/restored for nested blocks. }
  PrevProcName := CurrentProcName;
  PrevTempPeak := StackTempPeak;
  PrevLocalBytes := CurrentLocalBytes;
  PrevParamCopyBytes := CurrentParamCopyBytes;
  if Sym <> nil then CurrentProcName := Sym^.Name else CurrentProcName := '';
  StackTempPeak := 0;
  CurrentLocalBytes := 0;   { set by EmitPrologue below }

  ParseDeclarations(Sym);

  //if Sym = nil then
  //else
  //begin
    //Writeln('Entering main block');
    //MainBlock := True;
  //end;

  ExitTarget := GetLabel('exit');
  EmitPrologue(Sym);

  Expect(toBegin);
  NextToken;

  if SmartLink and (Sym <> nil) and (Sym^.Level = 0) then
  begin
  PrevBlock := CurrentBlock;
  CurrentBlock := Sym;
  end;

  ParseStatementList('', '');

  if SmartLink and (Sym <> nil) and (Sym^.Level = 0) then
  begin
  CurrentBlock := PrevBlock;
  end;

  //if Sym <> nil then
  //else
    //Writeln('Leaving main block');

  Expect(toEnd);
  NextToken;

  EmitEpilogue(Sym);

  CGCurrent         := PrevCGNode;
  CurrentSlotPrefix := PrevSlotPrefix;

  { Part 17: report this block's stack frame -- prologue-allocated locals PLUS
    the peak concurrent 256-byte string temps. The temp figure is what silently
    overflowed the task stack before the concat fold; the locals figure is the
    fixed part it sits on top of. }
  if (CurrentLocalBytes > 0) or (StackTempPeak > 0) or (CurrentParamCopyBytes > 0) then
  begin
    { Part 19 item 7.3: omit zero-valued terms. The old form always printed all
      three, so a routine with only locals read '48 B locals + 0 B String param
      copies + 0 B peak string temps = 48 B' -- noise that buried the figure
      that mattered. Only print the total when more than one term contributes. }
    FrameNote := '';
    if CurrentLocalBytes > 0 then
      FrameNote := IntToStr(CurrentLocalBytes) + ' B locals';
    if CurrentParamCopyBytes > 0 then
    begin
      if FrameNote <> '' then FrameNote := FrameNote + ' + ';
      FrameNote := FrameNote + IntToStr(CurrentParamCopyBytes) + ' B String param copies';
    end;
    if StackTempPeak > 0 then
    begin
      if FrameNote <> '' then FrameNote := FrameNote + ' + ';
      FrameNote := FrameNote + IntToStr(StackTempPeak * 256) + ' B peak string temps';
    end;
    FrameTotal := CurrentLocalBytes + CurrentParamCopyBytes + StackTempPeak * 256;
    if Pos('+', FrameNote) > 0 then
      FrameNote := FrameNote + ' = ' + IntToStr(FrameTotal) + ' B';
    EmitC('frame: ' + FrameNote);
  end;
  CurrentProcName := PrevProcName;
  StackTempPeak := PrevTempPeak;
  CurrentLocalBytes := PrevLocalBytes;
  CurrentParamCopyBytes := PrevParamCopyBytes;

  if SmartLink and (Sym <> nil) and (Sym^.Level = 0) then EmitI('.ENDIF');
end;
