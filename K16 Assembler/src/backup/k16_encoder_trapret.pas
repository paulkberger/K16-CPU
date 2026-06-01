unit K16_Encoder_TrapRet;

{$mode Delphi}

{
  K16_Encoder_TrapRet.pas — Encoder for TRAP, RET, RETCC, RETCS instructions.

  All four use opcode $1E. RETCC and RETCS share mode 10 to economise
  on opcode/mode slots; they are discriminated by IR[8:7] (read by the
  control ROM in step 5). Mode 01 is free for future use.

    Mode 00                TRAP #n             Software trap / syscall
    Mode 01                (spare)             — reserved for future use
    Mode 10, IR[8:7]=00    RETCC / RETCC #n    Return + clear carry (C=0)
    Mode 10, IR[8:7]=01    RETCS / RETCS #n    Return + set carry   (C=1)
    Mode 10, IR[8:7]=10    (reserved)          — currently behaves as RETCC
    Mode 10, IR[8:7]=11    (reserved)          — currently behaves as RETCC
    Mode 11                RET   / RET   #n    Plain return (no flag write)

  Mode bits live at IR[10:9], so the mode contributes to the base opcode
  word as (mode shl 9). Combined with opcode $1E (= $1E shl 11 = $F000)
  the base words are:

    Mode 00 → $F000  (TRAP)
    Mode 10 → $F400  (RETCC / RETCS — RETCS adds $0080 for IR[7]=1)
    Mode 11 → $F600  (RET)

  RET / RETCC / RETCS encoding:
    IR[4:0] = IMM5 = 4 + cleanup_bytes  (max 26 bytes / 13 words)
    IR[7]   = 0 for RETCC, 1 for RETCS (RET ignores IR[7])
    IR[8]   = 0 (reserved for future use; non-zero values currently
              decode as RETCC behaviour per microcode default case)

  TRAP encoding:
    IR[7:0] = n * 2 for n in 0..127
}

interface

uses
  SysUtils, StrUtils,
  K16_Parser, K16_Encoder_Base;

const
  TRAP_BASE      = $F000;   // opcode $1E, mode 00
  RETCC_BASE     = $F400;   // opcode $1E, mode 10, IR[8:7]=00
  RETCS_BASE     = $F480;   // opcode $1E, mode 10, IR[8:7]=01  ($F400 + $80)
  RET_BASE       = $F600;   // opcode $1E, mode 11
  RET_IMM5_MASK  = $001F;

type
  TK16TrapRetEncoder = class(TK16EncoderBase, IK16Encoder)
  private
    // Parse the optional #n / #nw cleanup operand common to RET/RETCC/RETCS.
    // Returns the resolved IMM5 value (= 4 + cleanup_bytes). On error, calls
    // ErrorReporter and returns 4 (no cleanup) so encoding can continue.
    function ParseCleanupOperand(const Instr: TInstructionRecord;
                                  const Mnemonic: string;
                                  SymbolResolver: TSymbolResolver;
                                  ErrorReporter: TErrorReporter;
                                  WarningReporter: TWarningReporter): Integer;
  public
    function Encode(const Instr: TInstructionRecord;
                    SymbolResolver: TSymbolResolver;
                    ErrorReporter: TErrorReporter;
                    WarningReporter: TWarningReporter): TMachineCode;
    function GetSupportedMnemonics: TArray<string>;
    function SupportsInstruction(const Mnemonic: string): Boolean;
  end;

implementation

{ TK16TrapRetEncoder }

function TK16TrapRetEncoder.GetSupportedMnemonics: TArray<string>;
begin
  Result := ['TRAP', 'RET', 'RETCC', 'RETCS'];
end;

function TK16TrapRetEncoder.SupportsInstruction(const Mnemonic: string): Boolean;
var
  S: string;
begin
  for S in GetSupportedMnemonics do
    if SameText(Mnemonic, S) then
      Exit(True);
  Result := False;
end;

function TK16TrapRetEncoder.ParseCleanupOperand(const Instr: TInstructionRecord;
                                                 const Mnemonic: string;
                                                 SymbolResolver: TSymbolResolver;
                                                 ErrorReporter: TErrorReporter;
                                                 WarningReporter: TWarningReporter): Integer;
var
  ImmValue: TImmediateValue;
  OperandStr: string;
  IsWordCount: Boolean;
  CleanupBytes: Integer;
begin
  CleanupBytes := 0;

  if Length(Instr.Operands) > 0 then
  begin
    if not Instr.Operands[0].StartsWith('#') then
    begin
      ErrorReporter(Format('%s operand must be immediate byte count: %s #bytes or %s #nw (words)',
        [Mnemonic, Mnemonic, Mnemonic]), Instr.LineNumber);
      Exit(4);  // base IMM5 = 4 (no cleanup) so encoding can continue
    end;

    OperandStr  := Instr.Operands[0];
    IsWordCount := False;

    if (Length(OperandStr) > 2) and
       ((OperandStr[Length(OperandStr)] = 'w') or (OperandStr[Length(OperandStr)] = 'W')) then
    begin
      IsWordCount := True;
      OperandStr  := Copy(OperandStr, 1, Length(OperandStr) - 1);
    end;

    ImmValue     := TImmediateValue.Parse(OperandStr);
    CleanupBytes := ResolveImmediate(ImmValue, SymbolResolver, Instr.LineNumber);

    if IsWordCount then
      CleanupBytes := CleanupBytes * 2;

    if (CleanupBytes and 1) <> 0 then
    begin
      ErrorReporter(Format('%s cleanup must be even bytes (got %d). Use #%d for %d words or #%d for %d words.',
        [Mnemonic, CleanupBytes, CleanupBytes - 1, (CleanupBytes - 1) div 2,
         CleanupBytes + 1, (CleanupBytes + 1) div 2]), Instr.LineNumber);
      CleanupBytes := 0;
    end;

    if (CleanupBytes < 0) or (CleanupBytes > 26) then
    begin
      ErrorReporter(Format('%s cleanup range is 0-26 bytes (0-13 words), got %d bytes',
        [Mnemonic, CleanupBytes]), Instr.LineNumber);
      CleanupBytes := 0;
    end;

    if (not IsWordCount) and (CleanupBytes > 0) then
      WarningReporter(Format('%s #%d cleans up %d bytes (%d word%s). Use #%dw to suppress this warning.',
        [Mnemonic, CleanupBytes, CleanupBytes, CleanupBytes div 2,
         IfThen(CleanupBytes div 2 = 1, '', 's'), CleanupBytes div 2]), Instr.LineNumber);
  end;

  Result := 4 + CleanupBytes;  // IMM5 = 4 + cleanup_bytes
end;

function TK16TrapRetEncoder.Encode(const Instr: TInstructionRecord;
                                   SymbolResolver: TSymbolResolver;
                                   ErrorReporter: TErrorReporter;
                                   WarningReporter: TWarningReporter): TMachineCode;
var
  OpCode: Word;
  ImmValue: TImmediateValue;
  IMM5Value, TrapN: Integer;
begin
  Result.Address           := Instr.Address;
  Result.SourceLine        := Instr.LineNumber;
  Result.HasImmediate      := False;
  Result.Immediate         := 0;
  Result.CanonicalMnemonic := Instr.Mnemonic;
  OpCode := 0;

  if SameText(Instr.Mnemonic, 'TRAP') then
  begin
    // TRAP #n — opcode $1E mode 00
    // Word = $F000 or (n * 2),  n in 0..127
    if Length(Instr.Operands) < 1 then
      ErrorReporter('TRAP requires an immediate operand (#0-#127)', Instr.LineNumber)
    else if not Instr.Operands[0].StartsWith('#') then
      ErrorReporter('TRAP operand must be an immediate value (#0-#127)', Instr.LineNumber)
    else
    begin
      ImmValue := TImmediateValue.Parse(Instr.Operands[0]);
      TrapN := ResolveImmediate(ImmValue, SymbolResolver, Instr.LineNumber);
      if (TrapN < 0) or (TrapN > 127) then
        ErrorReporter(Format('TRAP number out of range: %d (valid: 0-127)', [TrapN]), Instr.LineNumber)
      else
        OpCode := TRAP_BASE or (TrapN * 2);
    end;
  end

  else if SameText(Instr.Mnemonic, 'RETCC') then
  begin
    // RETCC [#nw] — opcode $1E mode 01  →  C=0 on return
    IMM5Value := ParseCleanupOperand(Instr, 'RETCC',
                                      SymbolResolver, ErrorReporter, WarningReporter);
    OpCode := RETCC_BASE or (IMM5Value and RET_IMM5_MASK);
  end

  else if SameText(Instr.Mnemonic, 'RETCS') then
  begin
    // RETCS [#nw] — opcode $1E mode 10  →  C=1 on return
    IMM5Value := ParseCleanupOperand(Instr, 'RETCS',
                                      SymbolResolver, ErrorReporter, WarningReporter);
    OpCode := RETCS_BASE or (IMM5Value and RET_IMM5_MASK);
  end

  else if SameText(Instr.Mnemonic, 'RET') then
  begin
    // RET [#nw] — opcode $1E mode 11  (plain return, no flag write)
    IMM5Value := ParseCleanupOperand(Instr, 'RET',
                                      SymbolResolver, ErrorReporter, WarningReporter);
    OpCode := RET_BASE or (IMM5Value and RET_IMM5_MASK);
  end

  else
    ErrorReporter(Format('Unknown TrapRet instruction: %s', [Instr.Mnemonic]), Instr.LineNumber);

  Result.OpCode := OpCode;
end;

end.
