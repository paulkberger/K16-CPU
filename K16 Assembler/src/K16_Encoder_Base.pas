unit K16_Encoder_Base;

{$mode Delphi}

interface

uses
  SysUtils,
  K16_Parser;

type
  // Forward declaration for symbol resolution
  TSymbolResolver = function(const SymName: string; LineNumber: Integer): UInt32 of object;
  TErrorReporter = procedure(const Msg: string; LineNumber: Integer) of object;
  TWarningReporter = procedure(const Msg: string; LineNumber: Integer) of object;

  // Generated machine code (moved from assembler)
  //
  // BYTE ORDER CONVENTION (established 22 April 2026, BUG 1 fix):
  //   GetBytes returns bytes in LITTLE-ENDIAN order — Lo(OpCode) first,
  //   Hi(OpCode) second, same for Immediate. This is the order the
  //   emulator wants in memory and the order the Intel HEX writer streams
  //   directly to disk without further swapping.
  //
  //   Do NOT re-introduce the previous big-endian + post-swap pipeline.
  //   That combination algebraically cancelled out for word-aligned code
  //   but scrambled .BYTE data at odd addresses (the swap ran in
  //   word-aligned pairs that didn't respect odd-address record
  //   boundaries). See K16_Export.GenerateIntelHex and SplitHighLow —
  //   both consume this LE layout directly.
  TMachineCode = record
    Address:  UInt32;
    OpCode:   Word;
    HasImmediate: Boolean;
    Immediate:  Word;
    SourceLine: Integer;
    CanonicalMnemonic: string;
    IsDataWord: Boolean;

    function GetTotalWords: Integer;
    function GetBytes: TArray<Byte>;
  end;

  // Base encoder interface
  IK16Encoder = interface
    ['{12345678-1234-5678-9012-123456789012}']
    function Encode(const Instr: TInstructionRecord;
                   SymbolResolver: TSymbolResolver;
                   ErrorReporter: TErrorReporter;
                   WarningReporter: TWarningReporter): TMachineCode;
    function GetSupportedMnemonics: TArray<string>;
    function SupportsInstruction(const Mnemonic: string): Boolean;
  end;

  // Base encoder implementation
  TK16EncoderBase = class(TInterfacedObject)
  protected
    function ResolveImmediate(const ImmValue: TImmediateValue;
                             SymbolResolver: TSymbolResolver;
                             LineNumber: Integer): UInt32;
    function GetXYRegisterNumber(const MemRef: TMemoryRef): Byte;
    function EncodeDestinationRegister(const Reg: TRegister): Byte;
  end;

implementation

{ TMachineCode }

function TMachineCode.GetTotalWords: Integer;
begin
  Result := 1;
  if HasImmediate then
    Inc(Result);
end;

function TMachineCode.GetBytes: TArray<Byte>;
// Returns bytes in little-endian order — the same order in which they land
// in emulator memory after load. Callers (K16_Export.GenerateIntelHex,
// GenerateBin, GenerateROMs) stream these bytes directly without any
// further byte-swap.
//
// This convention is critical for .BYTE/.TEXT records at odd addresses:
// when two records overlap at one byte (odd-boundary case), the byte
// positions produced by this function match the byte positions the user
// wrote in the source. Earlier big-endian + post-swap pipeline scrambled
// those bytes because the swap only operated on word-aligned pairs and
// didn't know about odd-address overlap.
begin
  if HasImmediate then
  begin
    SetLength(Result, 4);
    Result[0] := Lo(OpCode);
    Result[1] := Hi(OpCode);
    Result[2] := Lo(Immediate);
    Result[3] := Hi(Immediate);
  end else
  begin
    SetLength(Result, 2);
    Result[0] := Lo(OpCode);
    Result[1] := Hi(OpCode);
  end;
end;

{ TK16EncoderBase }

function TK16EncoderBase.ResolveImmediate(const ImmValue: TImmediateValue;
                                         SymbolResolver: TSymbolResolver;
                                         LineNumber: Integer): UInt32;
var
  SymRef: string;
begin
  if ImmValue.IsSymbol then
  begin
    // Reconstruct full symbol reference with # and derivative operator
    SymRef := '#';
    if ImmValue.HasDerivative then
      SymRef := SymRef + ImmValue.DerivativeOp;
    SymRef := SymRef + ImmValue.SymbolName;
    Result := SymbolResolver(SymRef, LineNumber);
  end
  else
    Result := ImmValue.Value;
end;

function TK16EncoderBase.GetXYRegisterNumber(const MemRef: TMemoryRef): Byte;
begin
  if MemRef.BaseReg = 'XY0' then Result := 0
  else if MemRef.BaseReg = 'XY1' then Result := 1
  else if MemRef.BaseReg = 'XY2' then Result := 2
  else if MemRef.BaseReg = 'XY3' then Result := 3
  else Result := 0; // Default to XY0
end;

function TK16EncoderBase.EncodeDestinationRegister(const Reg: TRegister): Byte;
begin
  case Reg.RegType of
    rtData:   Result := Reg.Number;                    // D0-D3: 0000-0011
    rtIndexX: Result := Reg.Number + 4;                // X0-X3: 0100-0111
    rtIndexY: Result := Reg.Number + 8;                // Y0-Y3: 1000-1011
    rtPC:     Result := 12;                            // PC:    1100 ($0C)
    rtSR:     Result := 13;                            // SR:    1101 ($0D)
    else      Result := 0;                             // Invalid - default to D0
  end;
end;

end.
