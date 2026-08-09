(* -------------------------------------------------------------------------- *)
(* --- Scanner ------------------------------------------------------------- *)
(* -------------------------------------------------------------------------- *)
(*                                                                            *)
(* Lexer: TToken enumeration, TScanner record, NextToken, Expect, Error.     *)
(* Depends on: nothing (reads from Source^ via GetChar/UngetChar in main).   *)
(* -------------------------------------------------------------------------- *)

type
  (**
   * An enumeration type containing all possible tokens. The order is
   * significant and must not be changed without changing the TokenStr array
   * accordingly. Also all tokens representing keywords are in one large,
   * alphabetically sorted block.
   *)
  TToken = (toNone,
            toIdent, toNumber, toString, toFloat, toAdd, toSub, toMul, toDiv,
            toEq, toNeq, toLt, toLeq, toGt, toGeq, toLParen, toRParen, toLBrack, toRBrack,
            toBecomes, toComma, toColon, toSemicolon, toPeriod, toCaret, toAt, toRange,
            toAbsolute, toAnd, toArray, toBegin, toCase, toConst, toDivKw, toDo, toDownto, toElse, toEnd,
            toExternal, toFile, toFor, toForward, toFunction, toGoto, toIf, toIn, toInline, toLabel, toMod,
            toNil, toNot, toOf, toOr, toOverlay, toPacked, toProcedure, toProgram, toRecord, toRepeat, toSet,
            toShl, toShr, toStringKw, toThen, toTo, toType, toUntil, toVar, toWhile, toWith, toXor,
            toEof);

  (**
   * Describes the state of our scanner, basically the last generated token.
   * TODO Eliminate this type. We only ever need a single one.
   *)
  TScanner = record
    Token:    TToken;
    StrValue: String;
    NumValue: Integer;
  end;

const
  (**
   * An array containing textual representations of all possible tokens. The
   * order is significant and must not be changed without changing the TToken
   * type accordingly. Also all tokens representing keywords are in one large,
   * alphabetically sorted block.
   *)
  TokenStr: array[TToken] of String =
           ('<nul>',
            'Identifier', 'Number', 'String', 'Real', '+', '-', '*', '/',
            '=', '#', '<', '<=', '>', '>=', '(', ')', '[', ']',
            ':=', ',', ':', ';', '.', '^', '@', '..',
            'absolute', 'and', 'array', 'begin', 'case', 'const', 'div', 'do', 'downto', 'else', 'end',
            'external', 'file', 'for', 'forward', 'function', 'goto', 'if', 'in', 'inline', 'label', 'mod',
            'nil', 'not', 'of', 'or', 'overlay', 'packed', 'procedure', 'program', 'record', 'repeat', 'set',
            'shl', 'shr', 'string', 'then', 'to', 'type', 'until', 'var', 'while', 'with', 'xor',
            '<eof>');

  (**
   * Indices of the first and last keywords. Required for keyword detection.
   *)
  FirstKeyword = toAbsolute;
  LastKeyword = toXor;

var
  (**
   * The state of our scanner. Basically the lookahead token, i.e. the next
   * token to process.
   *)
  Scanner: TScanner;

  (**
   * The line and column of the current token.
   *)
  TokenLine, TokenColumn: Integer;

(* AbsCode: set by {$A+} directive -- promotes small-type vars to global level *)
const
  AbsCode: Boolean = False;

var
  GlobalRAMOffset: Integer = $000200;  { Next free global RAM address (app zero page) }

(**
 * Returns True if the given character is a valid Pascal identifier head.
 *)
function IsIdentHead(C: Char): Boolean;
begin
  IsIdentHead := (C >= 'A') and (C <= 'Z') or (C >= 'a') and (C <= 'z') or (C = '_');
end;

(**
 * Returns True if the given character is a valid Pascal identifier tail.
 *)
function IsIdentTail(C: Char): Boolean;
begin
  IsIdentTail := IsIdentHead(C) or (C >= '0') and (C <= '9');
end;

(**
 * Returns True if the given character is a decimal digit.
 *)
function IsDecDigit(C: Char): Boolean;
begin
  IsDecDigit := (C >= '0') and (C <= '9');
end;

(**
 * Returns True if the given character is a valid hexadecimal digit.
 *)
function IsHexDigit(C: Char): Boolean;
begin
  IsHexDigit := IsDecDigit(C) or (C >= 'A') and (C <= 'F') or (C >= 'a') and (C <= 'f');
end;

(**
 * Returns True if the given character is a valid binary digit.
 *)
function IsBinDigit(C: Char): Boolean;
begin
  IsBinDigit := (C = '0') or (C = '1');
end;

(**
 * Looks up a keyword and returns its token. Returns toIdent if the string is
 * an ordinary identifier.
 *
 * TODO Make this a binary search or use hashing.
 *)
function LookupKeyword(Ident: String): TToken;
var
  T: TToken;
begin
  Ident := LowerStr(Ident);

  for T := FirstKeyword to LastKeyword do
    if TokenStr[T] = Ident then
    begin
      LookupKeyword := T;
      Exit;
    end;

  LookupKeyword := toIdent;
end;

var
  (**
   * The lookahead character, i.e. the next character to process.
   *)
  C: Char;

(**
 * Scans the input and generates the next token. A bit lengthy, but it does the
 * job.
 *
 * TODO Pull a couple of longer blocks into their own procedures.
 *)
procedure NextToken();
var
  S: String;
  I: Integer;
begin
  // Ignore whitespace
  while (C <= ' ') do
  begin
    C := GetChar;
  end;

  with Scanner do
  begin
    // Start a new token
    Token := toNone;
    StrValue := '';
    NumValue := 0;
    TokenLine := Source^.Line;
    TokenColumn := Source^.Column - 1;

    if IsIdentHead(C) then
    begin
      // Identifier
      StrValue := C;
      C := GetChar;
      while IsIdentTail(C) do
      begin
        StrValue := StrValue + C;
        C := GetChar;
      end;
      Token := LookupKeyword(StrValue);
    end
    else if IsDecDigit(C) then
    begin
      // Let's start with an integer number
      Token := toNumber;
      StrValue := C;
      NumValue := Ord(C) - Ord('0');
      C := GetChar;
      while IsDecDigit(C) do
      begin
        StrValue := StrValue + C;
        NumValue := 10 * NumValue + (Ord(C) - Ord('0'));
        C := GetChar;
      end;

      // Might turn out to be floating point
      if C = '.' then
      begin
        C := GetChar;
        if C = '.' then
        begin
          UngetChar;
          Exit;
        end;

        Token := toFloat;
        StrValue := StrValue + '.';

        while IsDecDigit(C) do
        begin
          StrValue := StrValue + C;
          C := GetChar;
        end;
      end;

      // And even have an exponential part
      if (C = 'E') or (C = 'e') then
      begin
        Token := toFloat;

        StrValue := StrValue + C;
        C := GetChar;

        if (C = '+') or (C = '-') then
        begin
          StrValue := StrValue + C;
          C := GetChar;
        end;

        if not IsDecDigit(C) then Error('Digit expected');

        while IsDecDigit(C) do
        begin
          StrValue := StrValue + C;
          C := GetChar;
        end;
      end;

    end
    else if C = '$' then
    begin
      // Hex numbers are numbers, too.
      Token := toNumber;
      StrValue := '$';
      C := GetChar;

      if not IsHexDigit(C) then Error('Hex digit expected');

      repeat
        StrValue := StrValue + C;
        NumValue := (NumValue shl 4);
        if (C >= '0') and (C <= '9') then
          NumValue := NumValue + Ord(C) - Ord('0')
        else if (C >= 'A') and (C <= 'F') then
          NumValue := NumValue + Ord(C) - Ord('A') + 10
        else
          NumValue := NumValue + Ord(C) - Ord('a') + 10;

        C := GetChar;
      until not IsHexDigit(C);
    end
    else if C = '%' then
    begin
      // Binary numbers are numbers, too.
      Token := toNumber;
      StrValue := '%';
      C := GetChar;

      if not IsBinDigit(C) then Error('Binary digit expected');

      repeat
        StrValue := StrValue + C;
        NumValue := (NumValue shl 1);
        if C = '1' then NumValue := NumValue + 1;
        C := GetChar;
      until not IsBinDigit(C);
    end
    else if (C = '''') or (C = '#') then
    begin
      // Strings come in various forms
      Token := toString;

      repeat
        if C = '''' then
        begin
          // Standard string delimited by apostrophes
          C := GetChar;
          while True do
          begin
            while (C <> '''') and (C <> #26) do
            begin
              StrValue := StrValue + C;
              C := GetChar;
            end;

            if C = #26 then Error('Unterminated String') else C := GetChar; (* ??? *)

            if C = '''' then
            begin
              StrValue := StrValue + '''';
              C := GetChar;
            end
            else Break;
          end;
        end
        else
        begin
          // Hash sign followed by an ASCII code
          I := 0;
          C := GetChar;
          if not IsDecDigit(C) then Error('Dec digit expected');
          repeat
            I := I * 10 + Ord(C) - Ord('0');
            C := GetChar;
          until not IsDecDigit(C);
          StrValue := StrValue + Char(I);
        end;
      until (C <> '''') and (C <> '#');
    end
    else if C = '{' then
    begin
      // Standard Pascal comments
      S := '{';
      repeat
        C := GetChar;
        S := S + C;
      until C = '}';
      C := GetChar;

      // Might turn out to be compiler directives
      if LowerStr(Copy(S, 2, 3)) = '$i ' then
        OpenInput(NativeToPosix(TrimStr(Copy(S, 4, Length(S) - 4))))
      else if LowerStr(Copy(S, 2, 3)) = '$a ' then
        EmitI(TrimStr(Copy(S, 4, Length(S) - 4)))
      else if LowerStr(Copy(S, 2, 2)) = '$a' then
        AbsCode := S[4] = '+'
      else if LowerStr(Copy(S, 2, 2)) = '$l' then
        SetLibrary(NativeToPosix(TrimStr(Copy(S, 4, Length(S) - 4))))
      else if LowerStr(Copy(S, 2, 6)) = '$pages' then
        SetComPages(Copy(S, 8, Length(S) - 8))
      else if LowerStr(Copy(S, 2, 5)) = '$heap' then
        SetComHeap(Copy(S, 7, Length(S) - 7));

      NextToken;
      Exit;
    end
    else
    begin
      // Various Single-character tokens
      case C of
        '+': Token := toAdd;
        '-': Token := toSub;
        '*': Token := toMul;
        '/': Token := toDiv;
        '=': Token := toEq;
        '<': Token := toLt;
        '>': Token := toGt;
        '(': Token := toLParen;
        ')': Token := toRParen;
        '[': Token := toLBrack;
        ']': Token := toRBrack;
        ':': Token := toColon;
        ',': Token := toComma;
        ';': Token := toSemicolon;
        '.': Token := toPeriod;
        '^': Token := toCaret;
        '@': Token := toAt;
        else Error('Invalid character "' + C + '"');
      end;

      C := GetChar;

      // These might turn out to be multi-character tokens
      case Token of
        toDiv:
          if C = '/' then               // C-style one-line comment
          begin
            Source^.Column := Length(Source^.Buffer) + 1;
            C := GetChar;
            NextToken; (* TODO Eliminate recursion??? *)
          end;
        toLt:
          if C = '>' then               // Not equal
          begin
            Token := toNeq;
            C := GetChar;
          end
          else if C = '=' then          // Less than or equal
          begin
            Token := toLeq;
            C := GetChar;
          end;

        toGt:
          if C = '=' then               // Greater than or equal
          begin
            Token := toGeq;
            C := GetChar;
          end;

        toLParen:
          if C = '.' then               // Alternative notation for [
          begin
            Token := toLBrack;
            C := GetChar;
          end
          else if C = '*' then          // Alternative notation for comments
          begin
            C := GetChar;
            S := '(*' + C;
            repeat
              while C <> '*' do
              begin
                C := GetChar;
                S := S + C;
              end;
              C := GetChar;
              S := S + C;
            until C = ')';
            C := GetChar;

            // TODO Do we really need to support directives for both comment types?
            if LowerStr(Copy(S, 3, 2)) = '$i' then
              OpenInput(NativeToPosix(TrimStr(Copy(S, 5, Length(S) - 6))));

            NextToken;
            Exit;
          end;

        toColon:
          if C = '=' then               // Assignment operator
          begin
            Token := toBecomes;
            C := GetChar;
          end;

        toPeriod:
          if C = ')' then               // Alternative notation for ]
          begin
            Token := toRBrack;
            C := GetChar;
          end
          else if C = '.' then          // Double dot for ranges
          begin
            Token := toRange;
            C := GetChar;
          end;
      end;
    end;
  end;
end;

(**
 * Returns a control character. Called if the previous character was a '^'.
 *)
function GetCtrlChar: Integer;
begin
  if not (C in ['@'..'_']) then Error('Invalid control character ^' + C);
  GetCtrlChar := Ord(C) - 64;
  C := GetChar;
end;

(**
 * Throws an error if the current (lookahead) token type is not the expected
 * one.
 *)
procedure Expect(Token: TToken);
begin
  if Scanner.Token <> Token then
    Error('Expected "' + TokenStr[Token] + '", but got "' + TokenStr[Scanner.Token] + '"');
end;

(* -------------------------------------------------------------------------- *)
(* --- Error handling ------------------------------------------------------- *)
(* -------------------------------------------------------------------------- *)

var
  (**
   * The line and column where an error occurred.
   *)
  ErrorLine, ErrorColumn: Integer;

  (**
   * The stored execution state to LongJmp to after an error.
   *)
  StoredState: Jmp_Buf;

(**
   * Whether we have assigned a stored state we can jump to.
   *)
  HasStoredState: Boolean;

(**
 * Reports an error and performs a LongJmp back to the point where parsing was
 * started.
 *)
procedure Error(Message: String);
var
  I: Integer;
begin
  WriteLn;

  if Source <> nil then
  begin
    WriteLn(Source^.Buffer);
    for I := 1 to TokenColumn - 1 do Write(' ');
    WriteLn('^');
    WriteLn('*** Error at ', TokenLine, ',', TokenColumn, ': ', Message);
    ErrorLine := TokenLine;
    ErrorColumn := TokenColumn;
  end
  else
  begin
    WriteLn('*** Error: ', Message);
    ErrorLine := 0;
    ErrorColumn := 0;
  end;

  WriteLn();

  // TODO Get rid of need for LongJmp by making "IDE" a separate program?
  if HasStoredState then
    LongJmp(StoredState, 1)
  else
    Halt(1);
end;

