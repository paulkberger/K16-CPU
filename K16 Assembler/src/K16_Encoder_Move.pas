unit K16_Encoder_Move;

{$mode Delphi}

interface

uses
  SysUtils, StrUtils,
  K16_Parser, K16_Encoder_Base;

type
  TK16MoveEncoder = class(TK16EncoderBase, IK16Encoder)
  public
    function Encode(const Instr: TInstructionRecord;
                   SymbolResolver: TSymbolResolver;
                   ErrorReporter: TErrorReporter;
                   WarningReporter: TWarningReporter): TMachineCode;
    function GetSupportedMnemonics: TArray<string>;
    function SupportsInstruction(const Mnemonic: string): Boolean;
  private
    function GetRegCode(const Reg: TRegister): Byte;
    function IsDataReg(const Reg: TRegister): Boolean;
    function IsXYReg(const Reg: TRegister): Boolean;
  end;

implementation

{ TK16MoveEncoder }

function TK16MoveEncoder.GetSupportedMnemonics: TArray<string>;
begin
  Result := ['MOVE', 'SWAP'];
end;

function TK16MoveEncoder.SupportsInstruction(const Mnemonic: string): Boolean;
begin
  Result := SameText(Mnemonic, 'MOVE') or SameText(Mnemonic, 'SWAP');
end;

function TK16MoveEncoder.GetRegCode(const Reg: TRegister): Byte;
begin
  case Reg.RegType of
    rtData:   Result := Reg.Number and $03;           // D0-D3: 0-3
    rtIndexX: Result := 4 + (Reg.Number and $03);     // X0-X3: 4-7
    rtIndexY: Result := 8 + (Reg.Number and $03);     // Y0-Y3: 8-11
    rtPC:     Result := $0F;                          // PC: 15
    rtSR:     Result := $0D;                          // SR: 13 (FLAGS)
    else      Result := 0;
  end;
end;

function TK16MoveEncoder.IsDataReg(const Reg: TRegister): Boolean;
begin
  Result := (Reg.RegType = rtData);
end;

function TK16MoveEncoder.IsXYReg(const Reg: TRegister): Boolean;
begin
  Result := (Reg.RegType = rtIndexX) or (Reg.RegType = rtIndexY);
end;

function TK16MoveEncoder.Encode(const Instr: TInstructionRecord;
                                SymbolResolver: TSymbolResolver;
                                ErrorReporter: TErrorReporter;
                                WarningReporter: TWarningReporter): TMachineCode;
var
  OpCode: Word;
  DestReg, SourceReg: TRegister;
  DestCode, SourceCode: Byte;
  ModeCode: Byte;
  IsSwap: Boolean;
begin
  // MOVE/SWAP opcode = 0x05
  OpCode := $05 shl 11; // Bits 15-11: Opcode

  // Initialize result
  Result.OpCode := OpCode;
  Result.Address := Instr.Address;
  Result.SourceLine := Instr.LineNumber;
  Result.HasImmediate := False;
  Result.Immediate := 0;

  IsSwap := SameText(Instr.Mnemonic, 'SWAP');
  if IsSwap then
    Result.CanonicalMnemonic := 'SWAP'
  else
    Result.CanonicalMnemonic := 'MOVE';

  // Validate operand count
  if Length(Instr.Operands) <> 2 then
  begin
    if IsSwap then
      ErrorReporter('SWAP requires exactly 2 operands: SWAP regA, regB', Instr.LineNumber)
    else
      ErrorReporter('MOVE requires exactly 2 operands: MOVE dest, source', Instr.LineNumber);
    Result.OpCode := 0;
    Exit;
  end;

  // Parse destination and source registers
  DestReg := TRegister.Parse(Instr.Operands[0]);
  SourceReg := TRegister.Parse(Instr.Operands[1]);

  if not DestReg.IsValid then
  begin
    ErrorReporter(Result.CanonicalMnemonic + ': Invalid first register', Instr.LineNumber);
    Result.OpCode := 0;
    Exit;
  end;

  if not SourceReg.IsValid then
  begin
    ErrorReporter(Result.CanonicalMnemonic + ': Invalid second register', Instr.LineNumber);
    Result.OpCode := 0;
    Exit;
  end;

  // Get register codes
  DestCode := GetRegCode(DestReg);
  SourceCode := GetRegCode(SourceReg);

  if IsSwap then
  begin
    // SWAP mode selection:
    // Mode 10: SWAP D, reg (3 steps) - D must be one operand
    // Mode 11: SWAP X/Y, X/Y (4 steps) - both operands X/Y

    if IsDataReg(DestReg) or IsDataReg(SourceReg) then
    begin
      // Mode 10: At least one D register
      ModeCode := 2;

      // For Mode 10, microcode expects D in dest position if D is first operand
      // or in source position if D is second operand - it figures out which is D
    end
    else if IsXYReg(DestReg) and IsXYReg(SourceReg) then
    begin
      // Mode 11: Both X/Y registers
      ModeCode := 3;
    end
    else
    begin
      ErrorReporter('SWAP: Unsupported register combination (use D with X/Y, or X/Y with X/Y)', Instr.LineNumber);
      Result.OpCode := 0;
      Exit;
    end;
  end
  else
  begin
    // MOVE mode selection:
    // Mode 00: MOVE dest, D (2 steps) - D source
    // Mode 01: MOVE dest, X/Y (3 steps) - X/Y source

    if IsDataReg(SourceReg) then
      ModeCode := 0  // Mode 00: D source
    else
      ModeCode := 1; // Mode 01: X/Y/PC source
  end;

  // Build the complete opcode
  // Bits 15-11: Opcode (0x05)
  // Bits 10-9:  Mode
  // Bits 8-5:   Destination/RegA register
  // Bits 4-1:   Source/RegB register
  // Bit 0:      Reserved (0)

  OpCode := OpCode or (ModeCode shl 9);    // Mode bits 10-9
  OpCode := OpCode or (DestCode shl 5);    // Dest bits 8-5
  OpCode := OpCode or (SourceCode shl 1);  // Source bits 4-1

  Result.OpCode := OpCode;
end;

end.
